-- bench_panel.tsp -- start a soak from the front panel, with no host connected.
--
-- NOT IN tsp/. Same rule as sdg_net.tsp and bench_run.tsp: this is bench scaffolding and must never
-- ship inside the app. package_tspa.py's MODULES list is the app; this file belongs to the bench
-- package alone, and lint_vecrefs/the tspa gate would fail an archive carrying it.
--
-- WHY A SCREEN AND NOT display.input.*. The firmware's modal dialogs are documented in
-- docs/Display API Command Reference.md and used nowhere in this tree, so their behaviour here is
-- unmeasured -- and a modal that does not return costs a power cycle to escape. The options form in
-- serial_ui.tsp is the pattern that is proven on this instrument, so this is built the same way:
-- OBJ_EDIT_NUMBER and OBJ_EDIT_OPTION fields read back with display.getvalue() when Run is pressed.
--
-- WHAT THIS DOES NOT DO: draw a plan. tools/soakplan.py emits the plan and the key carries it --
-- bench_run.tsp's own header says re-deriving the draw on the instrument would be a second
-- implementation of the one thing every lap is compared against. So the panel reports the plan it
-- found and refuses to start without one; putting a plan on the key is still
-- `run_bench.py --push-plan`, once, after which laps can be started here with no host at all.
--
-- The host path is untouched. run_bench.py --start works exactly as before, and this is a second door
-- into the same brun.soak().

-- The namespace, declared with the idempotent idiom so this file states which table it owns rather
-- than inheriting one from load order. bench_run.tsp is always loaded first and brings the engine
-- these functions call; the table itself must not depend on that.
brun             = brun or {}

-- ---------------------------------------------------------------------------
-- Settings offered, and what each maps to
-- ---------------------------------------------------------------------------
-- Laps. 210 is the ceiling notes/SOAK-14DAY.md sizes the fortnight plan to, so a number past it
-- cannot describe a plan that exists. 0 would mean 'forever' to brun.soak and is deliberately not
-- offered: an unbounded run started from the panel has no operator watching the host log that would
-- otherwise say so.
brun.pn_laps_max = brun.pn_laps_max or 210

-- The generator's address, as a pick list rather than typed text. There is no string-edit display
-- object in this firmware's object set -- the app's own options form uses only NUMBER and OPTION --
-- and a pick list cannot produce a typo that costs a lap to discover. The live value is bsdg.ip, and
-- it leads the list so the field opens on whatever the module was loaded with.
brun.pn_sdg      = brun.pn_sdg or {'10.0.1.79', '10.0.1.78', '192.168.0.79'}

-- The lap shapes, as filters over the plan on the key and NOT as draws -- see brun.wanted. Each entry
-- is the filter state the shape means, so the mapping lives beside the label instead of in a branch
-- further down that a new shape could be added without.
--
-- ONE AXIS ONLY, WHICH IT WAS NOT. This field read Full / Normal / Adversarial, and those are two
-- different questions: 'Normal' filtered RATES while 'Adversarial' filtered VECTORS. A field whose
-- entries mean different kinds of thing cannot be combined with anything -- there was no way to ask
-- for adversarial vectors at standard rates. Adversarial moved to Vector Set below, where it belongs,
-- and this field is now the rate axis alone and composes with it. Operator's call, 2026-10-21.
--
--   Full           every rate the plan holds, which is what the host-driven path runs
--   Standard only  standard rates only, so no drawn interstitial or edge rate plays
brun.pn_laptypes = brun.pn_laptypes or
  {{t = 'Full',          std = nil},
   {t = 'Standard only', std = true}}

-- WHICH VECTORS PLAY, the other axis. Two of these are named for what they ask of the decoder rather
-- than for a list of ids, and both are derived rather than enumerated: 'All gaps' and 'Start gap' key
-- on the generator's own waveform NAME through barb.of, so a gap vector added later is covered without
-- editing a second list, and 'Adversarial' is barb.loud's table -- the vectors the plan drives into
-- conditions where refusing is the documented right answer.
--
--   Normal      the default: no gap vectors and nothing barb.loud excuses, which is the lap you want
--               when you are asking whether the decoder still works
--   All         every vector the plan holds
--   Start gap   a gap BEFORE the first byte -- the GapLead pair, which is the armed-start case
--   All gaps    every gap vector, lead, mid, both and the long ones
--   Adversarial only the vectors known to produce errors, so a lap spends its time where the
--               answers are
--
-- NORMAL IS FIRST, AND THAT IS NOT THE SAME CHOICE AS LAP TYPE'S. Lap Type leads with the entry that
-- filters nothing, because an unreadable field there must not narrow a lap silently. Here the
-- operator asked for Normal as the default, so Normal leads -- and that makes the fallback for an
-- unreadable field the same set the glass was showing, which is the honest answer either way.
brun.pn_vsets = brun.pn_vsets or
  {{t = 'Normal',      v = 'normal'},
   {t = 'All',         v = nil},
   {t = 'Start gap',   v = 'startgap'},
   {t = 'All gaps',    v = 'gap'},
   {t = 'Adversarial', v = 'adv'}}

-- The rate window, in Bd. Defaults span the whole ladder, so the fields open describing a lap that
-- filters nothing: 300 is the slowest rate soakplan draws and 250 000 the decoder's own ceiling.
brun.pn_baudlo    = brun.pn_baudlo or 300
brun.pn_baudhi    = brun.pn_baudhi or 250000

-- Where drawn rates start being worth the time. INTERSTITIAL_LO in tools/soakplan.py refuses to draw
-- them below 4800 for the same reason this defaults to 2400 rather than 300: at the bottom of the
-- ladder a non-standard rate costs the most seconds and tests the least, people bit-banging slowly
-- being the ones who hit a standard rate exactly. Below it only standard rates play.
brun.pn_interstit = brun.pn_interstit or 2400

-- ---------------------------------------------------------------------------
-- Geometry, taken from the app's own form rather than chosen again
-- ---------------------------------------------------------------------------
-- The options form's numbers are already fitted to this screen, and a second set of constants here
-- would drift from them silently. Read through sdec so a changed form moves this one with it.
function brun.pn_geom()
  local g = {}
  g.x     = sdec.ui_opt_x or 22
  g.x2    = sdec.ui_opt_x_c2 or 420
  g.y0    = sdec.ui_opt_y0 or 60
  g.dy    = sdec.ui_opt_dy or 54
  g.btny  = sdec.ui_opt_btn_y or 380
  -- Where the plan lines start: clear of the one button, which is 200 px wide at x=22. 24 px of gap,
  -- the same the options form leaves between its own buttons, so the two do not read as one block.
  g.pnx   = 246
  return g
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
brun.pnscr  = nil
brun.pn_obj = nil

-- Hand every object back, screen last. Switch away first, then delete: ui_destroy's rule, because a
-- delete against the screen in front leaves the panel drawing a dead object.
function brun.destroy_panel()
  if brun.pnscr == nil then return false end
  display.changescreen(display.SCREEN_HOME)
  local i
  if brun.pn_obj ~= nil then
    for i = 1, table.getn(brun.pn_obj) do sdec.del_obj(brun.pn_obj[i]) end
  end
  brun.pn_obj = nil
  sdec.del_obj(brun.pnscr)
  brun.pnscr = nil
  -- NIL'D, NOT JUST DELETED, which is the object-lifetime rule the app follows: delete, nil, then
  -- create. These were left set, so every one of them was a handle to a deleted object after a
  -- teardown -- and brun.pn_say's `if brun.pn_ptxt == nil` guard could therefore never fire, which
  -- made it settext into the void. The mock counts that as a refusal; the instrument posts nothing.
  brun.pn_laps, brun.pn_sdgf, brun.pn_lapt, brun.pn_vset = nil, nil, nil, nil
  brun.pn_lo, brun.pn_hi, brun.pn_inter = nil, nil, nil
  brun.pn_over, brun.pn_armv, brun.pn_armw = nil, nil, nil
  brun.pn_ptxt, brun.pn_ptxt2 = nil, nil
  return true
end

-- The plan on the key, as a line the operator can read before committing to a run. Opened and closed
-- here rather than left open: brun.planopen is the run's own handle and a second reader would share
-- the position. -> rows, variant or nil.
function brun.pn_plan()
  local keep    = brun.planrows
  brun.planrows = 0
  local ok      = brun.planopen()
  if not ok then
    brun.planrows = keep
    return nil
  end
  -- One row is enough: the '# rows=' header is read by nextrow on its way past, which is the only
  -- place that parses it. A plan with no header falls back to reading to EOF, so 0 here means the
  -- file is there and declares nothing, which is still a plan this can run.
  brun.nextrow()
  local n, v = brun.planrows, brun.planrsub
  brun.planclose()
  brun.planrows = keep
  return n, v
end

-- Build the settings screen. Returns the screen handle, or raises with a reason the operator can act
-- on -- the same contract as sdec.build_options, and for the same reason: a Run screen that opens
-- nothing is worse than a refusal that says why.
function brun.build_panel()
  brun.destroy_panel()
  local create = display.create
  local g      = brun.pn_geom()
  brun.pn_obj  = {}
  local function keep(h)
    if h ~= nil then brun.pn_obj[table.getn(brun.pn_obj) + 1] = h end
    return h
  end

  brun.pnscr = create(display.ROOT, display.OBJ_SCREEN, 'BENCH SOAK')
  if brun.pnscr == nil then
    error('display object pool exhausted building the soak screen -- power cycle the instrument.', 0)
  end

  -- TEN fields in two columns is five rows, and the pitch has to clear the button row: the same
  -- arithmetic build_options does, read from its constants so a changed form moves this one too.
  --
  -- A STALE FIGURE HERE DOES NOT FAIL, IT SKEWS. It said 8 while the form held six, two fields
  -- having been removed, which reserved four rows for three -- so the left column ran a slot past
  -- the right one and the last field sat alone under a hole. That is what the published docs/img/brun-panel.png showed for weeks, because the figure
  -- outlived the fields and nothing counted them. test_bench_engine counts them now.
  --
  -- The ten fit because the plan line moved out of the grid: it used to take a field slot of its own
  -- and sit above the buttons, and it now runs in two short lines BESIDE the button, which is dead
  -- space in a single-button row.
  local nf    = 10
  local nrows = math.ceil(nf / 2)
  local maxdy = math.floor((g.btny - 52 - g.y0) / nrows)
  if g.dy > maxdy then g.dy = maxdy end
  local n = 0
  local function nextpos()
    local col, rowy = g.x, g.y0 + n * g.dy
    if n >= nrows then col, rowy = g.x2, g.y0 + (n - nrows) * g.dy end
    n = n + 1
    return col, rowy
  end

  local fx, fy = nextpos()
  brun.pn_laps = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                             'Laps', 'plan passes',
                             display.NFORMAT_INTEGER, 1, 1, brun.pn_laps_max, '', 4))
  fx, fy = nextpos()
  local i
  -- The live address leads, so the field opens on what the module holds rather than on a list order.
  local st, sn = {}, 0
  if bsdg ~= nil and bsdg.ip ~= nil then sn, st[1] = 1, bsdg.ip end
  for i = 1, table.getn(brun.pn_sdg) do
    if brun.pn_sdg[i] ~= st[1] then sn = sn + 1; st[sn] = brun.pn_sdg[i] end
  end
  brun.pn_sdgf = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                             'SDG Address', 'generator', st[1], st[2], st[3]))
  fx, fy = nextpos()
  local lt = {}
  for i = 1, table.getn(brun.pn_laptypes) do lt[i] = brun.pn_laptypes[i].t end
  -- SPELLED OUT PER COUNT, not passed as lt[1]..lt[4] with the tail left nil. There were four lap
  -- types until one was removed, and passing a nil fourth option made the firmware REFUSE the
  -- create: display.create returned nil, keep() skipped it, and the Lap Type field simply was not
  -- on the screen -- while BRUN.md went on documenting it with a subsection of
  -- its own. Nothing failed, because nothing counted the fields. Seen on the glass 2026-10-21.
  --
  -- Same shape as build_options' Protocol field, and for the same reason it is not unpack()'d: the
  -- instrument's Lua 5.0.2 has a global unpack() and the offline harness's does not.
  local nlt = table.getn(lt)
  if nlt >= 4 then
    brun.pn_lapt = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Lap Type', 'rates that play', lt[1], lt[2], lt[3], lt[4]))
  elseif nlt == 3 then
    brun.pn_lapt = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Lap Type', 'rates that play', lt[1], lt[2], lt[3]))
  elseif nlt == 2 then
    brun.pn_lapt = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Lap Type', 'rates that play', lt[1], lt[2]))
  end

  -- THE VECTOR AXIS, beside the rate one. Same per-count spelling as above and for the same reason:
  -- a nil trailing option makes the firmware refuse the create, which is how Lap Type lost itself.
  fx, fy = nextpos()
  local vs, nvs = {}, table.getn(brun.pn_vsets)
  for i = 1, nvs do vs[i] = brun.pn_vsets[i].t end
  if nvs >= 5 then
    brun.pn_vset = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Vector Set', 'which ones play',
                               vs[1], vs[2], vs[3], vs[4], vs[5]))
  elseif nvs == 4 then
    brun.pn_vset = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Vector Set', 'which ones play', vs[1], vs[2], vs[3], vs[4]))
  elseif nvs == 3 then
    brun.pn_vset = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Vector Set', 'which ones play', vs[1], vs[2], vs[3]))
  elseif nvs == 2 then
    brun.pn_vset = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                               'Vector Set', 'which ones play', vs[1], vs[2]))
  end
  fx, fy = nextpos()
  -- 110 is the slowest rate the decoder accepts at all, so the field cannot be set to a floor that
  -- would exclude every row; the ceiling is the other field's own maximum.
  brun.pn_lo = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                           'Speed Low', 'slowest rate run',
                           display.NFORMAT_PREFIX, brun.pn_baudlo, 110, 250000, 'Bd', 6))
  fx, fy = nextpos()
  brun.pn_hi = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                           'Speed High', 'fastest rate run',
                           display.NFORMAT_PREFIX, brun.pn_baudhi, 110, 250000, 'Bd', 6))
  fx, fy = nextpos()
  -- 0 means 'draw them anywhere', which is the plan as pushed; any other value is a floor under the
  -- non-standard rates alone, standard ones playing at every speed inside the window above.
  brun.pn_inter = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                              'Interstitial', '0 any, else from',
                              display.NFORMAT_PREFIX, brun.pn_interstit, 0, 250000, 'Bd', 6))

  -- THE THREE CAPTURE SETTINGS A SOAK ACTUALLY TURNS, asked for from the panel on 2026-10-21. Until
  -- now they could only be set from the host -- run_bench.py --over-read, and the arm pair not at all
  -- -- so a panel-started soak ran whatever the last host run or the module default left behind. The
  -- whole point of this screen is a lap with no host, and these are the knobs that change what a
  -- cell measures rather than which cells run.
  --
  -- EVERY ARGUMENT IS THE APP'S OWN, read from sdec rather than restated, so the form here cannot
  -- offer a range the app would clamp away: the ranges come from the core, and the defaults are
  -- whatever the app currently holds -- which is what the operator is about to change.
  fx, fy = nextpos()
  -- Percent on the glass, a fraction underneath, exactly as the app's form does it: this reads 10
  -- where sdec.strm_overread holds 0.10. panel_run divides by 100.
  brun.pn_over = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                             'Over-read', '0 off, idle margin',
                             display.NFORMAT_PREFIX, (sdec.strm_overread or 0) * 100,
                             0, (sdec.overread_max or 0.5) * 100, '%', 4))
  fx, fy = nextpos()
  -- The comparator level for a line that has not started talking, and the wait that goes with it.
  -- Four significant digits for the reason the app's form states: '1.00000 V' claims a precision the
  -- setting does not have. docs/MEASUREMENTS.md, 'armlevel 1.0, floor 0.33, ceiling 6.0'.
  brun.pn_armv = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                             'Arm At', 'wake-up level',
                             display.NFORMAT_PREFIX, sdec.arm_level_v(),
                             sdec.armlevel_min, sdec.armlevel_max, 'V', 4))
  fx, fy = nextpos()
  -- Seconds, and the panel is frozen for every one of them -- which on a soak is seconds per CELL,
  -- so this is the field most able to turn a lap into an overnight run. The label carries both uses
  -- because one number serves both: the arm's wait, and the quiet-line exit once the line is up.
  brun.pn_armw = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                             'Arm Wait', 'max wait, frozen',
                             display.NFORMAT_PREFIX, sdec.arm_wait_s(),
                             sdec.armwait_min, sdec.armwait_max, 's', 4))

  -- THE PLAN, STATED BEFORE THE RUN IS COMMITTED. A soak started against a plan the operator did not
  -- expect is a lap of instrument time spent on the wrong question, and the key keeps whichever plan
  -- was pushed last -- a targeted --spec overwrites PLAN.CSV, so what is there is not necessarily the
  -- fortnight plan.
  local rows, rsub = brun.pn_plan()
  local p1, p2
  if rows == nil then
    p1 = 'PLAN: none on the key'
    p2 = 'push one: run_bench.py --push-plan'
  else
    p1 = string.format('plan: %s row(s)', brun.int(rows))
    p2 = (rsub ~= nil and rsub ~= '') and ('random-per-lap ' .. rsub) or ''
  end
  -- BESIDE THE BUTTON, NOT ABOVE IT, and NOT out of nextpos(). This used to take a field slot of its
  -- own and sit at btny - 44, which cost the grid a row for a line of furniture. A single-button row
  -- leaves most of its width empty, so the plan runs in two short lines in that space -- which is
  -- what made room for ten fields. Operator's layout, 2026-10-21.
  --
  -- Two objects rather than one wrapped string, because there is no wrapping: a 58-character clip is
  -- what the one-line form did, and 'PLAN: none on the key -- push one with run_bench.py --push-plan'
  -- is 62. The second line is where the sentence that got cut now goes.
  --
  -- The y values put both lines inside the button's own 58 px band, so nothing here can collide with
  -- the field grid however the pitch above is clamped.
  brun.pn_ptxt  = keep(create(brun.pnscr, display.OBJ_TEXT, g.pnx, g.btny + 16, p1,
                              sdec.ui_c_pgword, display.FONT_SMALL, display.JUST_LEFT))
  brun.pn_ptxt2 = keep(create(brun.pnscr, display.OBJ_TEXT, g.pnx, g.btny + 44, p2,
                              sdec.ui_c_pgword, display.FONT_SMALL, display.JUST_LEFT))

  -- ONE BUTTON. Cancel was the second, and it is gone on the operator's instruction of 2026-10-21:
  -- End App in the title bar is the way out of this screen, and it is wired below to the same
  -- teardown Cancel called. That is a complete exit here and not merely a screen change -- the bench
  -- package's entry point calls brun.panel() and never sdec.start(), so the form is the only thing
  -- this app has built and destroying it strands nothing.
  local bdef = {{x = 22,  w = 200, t = 'Run Soak', e = 'brun.panel_run'}}
  local nb = 0
  for i = 1, table.getn(bdef) do
    local b = create(brun.pnscr, display.OBJ_BUTTON, bdef[i].x, g.btny, bdef[i].t, bdef[i].w)
    if b ~= nil then
      display.setevent(b, display.EVENT_PRESS, 'sdec.guard(' .. bdef[i].e .. ')')
      keep(b)
      nb = nb + 1
    end
  end
  if nb < table.getn(bdef) then
    error(string.format('only %d of %d soak buttons could be created -- display object pool '
                        .. 'exhausted. Power cycle the instrument.', nb, table.getn(bdef)), 0)
  end

  -- End App on this screen too, for build_options' reason: exiting from the form must not strand it.
  display.setevent(brun.pnscr, display.EVENT_ENDAPP, 'sdec.guard(brun.panel_cancel)')
  return brun.pnscr
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
-- A smoke poisons the soak that follows it, and only a power cycle clears it. tools/run_bench.py's
-- refuse_smoke_poison carries the measurements -- three occurrences, the last one 705 of 705 cells
-- idle -- and that guard is host-side, so a panel start would walk straight past it. SMOKED is the
-- global bench_smoke.py sets before its first stage; a power cycle clears it and nothing else sets
-- it. -> nil when it is safe to run, or the reason it is not.
function brun.pn_poisoned()
  if SMOKED == nil then return nil end
  return 'a smoke has run on this power cycle -- power cycle the DMM before a soak, or every cell '
         .. 'will read "line is idle"'
end

-- Read the form, apply it, and start. Nothing here is applied until every field has been read: a
-- half-read form would otherwise commit a partial configuration, which is options_apply's rule.
--
-- NIL-CHECKED, NOT pcall'd. This wrapped all ten reads in one guard, and the only way a
-- display.getvalue can fail is a nil HANDLE -- the firmware returns values and posts events, it does
-- not raise. So the test is for the handle, which also says WHICH field is missing instead of
-- reporting one failure for the form. A field whose handle is gone reads as nil and the `type(x) ==
-- 'number'` tests below already treat that as "not set", which is the right answer for it.
function brun.panel_run()
  local laps, ip, lt, lo, hi, inter, vst, over, armv, armw
  local missing = nil
  local function val(h, name)
    if h == nil then missing = (missing or '') .. name .. ' '; return nil end
    return display.getvalue(h)
  end
  laps     = val(brun.pn_laps, 'Laps')
  local si = val(brun.pn_sdgf, 'SDG Address')
  if type(si) == 'number' then ip = brun.pn_sdgtxt(math.floor(si + 0.5)) end
  local li = val(brun.pn_lapt, 'Lap Type')
  if type(li) == 'number' then lt = brun.pn_laptypes[math.floor(li + 0.5)] end
  local vi = val(brun.pn_vset, 'Vector Set')
  if type(vi) == 'number' then vst = brun.pn_vsets[math.floor(vi + 0.5)] end
  lo    = val(brun.pn_lo, 'Speed Low')
  hi    = val(brun.pn_hi, 'Speed High')
  inter = val(brun.pn_inter, 'Interstitial')
  over  = val(brun.pn_over, 'Over-read')
  armv  = val(brun.pn_armv, 'Arm At')
  armw  = val(brun.pn_armw, 'Arm Wait')
  -- A MISSING FIELD REFUSES THE RUN rather than running on a default nobody chose. The form is built
  -- at once and all ten handles come back together, so a nil here means the build was short -- the
  -- state that put a soak screen on the glass without its Lap Type field.
  if missing ~= nil then
    brun.pn_say('form incomplete, not starting: no ' .. missing)
    return false
  end

  local why = brun.pn_poisoned()
  if why ~= nil then
    brun.pn_say('REFUSED: ' .. why)
    return false
  end
  local rows = brun.pn_plan()
  if rows == nil then
    brun.pn_say('REFUSED: no plan on the key -- run_bench.py --push-plan first')
    return false
  end

  if type(laps) ~= 'number' or laps < 1 then laps = 1 end
  laps = math.floor(laps + 0.5)

  -- THE FILTERS, SET TOGETHER AND NEVER PARTLY. Every one is assigned on every run, nil included, so a
  -- second soak started from this form cannot inherit the first one's narrowing -- which is the same
  -- trap brun.point's cleared rate-fit fields exist for: a stale filter is worse than an absent one,
  -- because a lap would quietly run a different cell set than the form on the glass describes.
  if lt == nil then lt = brun.pn_laptypes[1] end
  brun.filt_stdonly = lt.std
  -- The vector axis, assigned on every run for the same reason: entry 1 is the fallback, and here
  -- that is Normal -- the set the field was showing, because Normal is also its default.
  if vst == nil then vst = brun.pn_vsets[1] end
  brun.filt_vset = vst.v
  brun.nfilt = 0
  -- The window, and a reversed pair is the operator's slip rather than an empty lap: swapped so the
  -- form cannot ask for a range that excludes every row.
  if type(lo) ~= 'number' then lo = nil end
  if type(hi) ~= 'number' then hi = nil end
  if lo ~= nil and hi ~= nil and lo > hi then lo, hi = hi, lo end
  brun.filt_baudlo, brun.filt_baudhi = lo, hi
  -- Zero is 'anywhere', which is the plan as pushed, so it clears the filter rather than setting a
  -- floor of nothing.
  if type(inter) == 'number' and inter > 0 then brun.filt_interstit = inter
  else brun.filt_interstit = nil end
  if ip ~= nil and bsdg ~= nil then
    -- Closed before the address moves, or the next select talks to the old session on the new name.
    if bsdg.close ~= nil then bsdg.close() end
    bsdg.ip = ip
  end

  -- THE THREE CAPTURE SETTINGS, applied the way the app's own form applies them, because they are
  -- the app's fields and not the bench's: sdec.strm_overread, sdec.armlevel and sdec.armwait. Taken
  -- only when they read as numbers, or a nil reaches a voltage comparison deep in an armed capture.
  --
  -- The arm pair is NOT clamped here: arm_level_v() and arm_wait_s() clamp at use, so the form keeps
  -- showing what was typed rather than silently correcting it. Over-read IS clamped, because the
  -- ceiling is a field argument and a form built before overread_max moved would still offer the old
  -- one -- the same reason options_apply clamps it.
  if type(armv) == 'number' then sdec.armlevel = armv end
  if type(armw) == 'number' then sdec.armwait = armw end
  if type(over) == 'number' then
    local f = over / 100
    if f < 0 then f = 0 end
    if f > (sdec.overread_max or 0.5) then f = sdec.overread_max or 0.5 end
    sdec.strm_overread = f
  end

  -- The form goes before the run's own screen is built: both are full screens and the display pool is
  -- 463 objects, so holding this one open through a soak spends objects the status screen needs.
  brun.destroy_panel()
  brun.soak(laps, 'soak')
  return true
end

-- The address text for an option index, which is the same list build_panel assembled -- rebuilt here
-- rather than stashed, so a field and its meaning cannot drift apart across a rebuild.
function brun.pn_sdgtxt(i)
  local st, sn = {}, 0
  if bsdg ~= nil and bsdg.ip ~= nil then sn, st[1] = 1, bsdg.ip end
  local k
  for k = 1, table.getn(brun.pn_sdg) do
    if brun.pn_sdg[k] ~= st[1] then sn = sn + 1; st[sn] = brun.pn_sdg[k] end
  end
  return st[i]
end

-- Say something on the form itself. The plan line is the one text object this screen has, so a
-- message that needs a second object can fail to appear for want of one. -> false only where the
-- object was never built: display.settext posts and returns, so there is no other failure to report.
-- ACROSS BOTH LINES, breaking at a space. The one-line form clipped at 58 characters, and every
-- message worth printing here is longer than that: 'REFUSED: a smoke has run on this power cycle --
-- power cycle the DMM before a soak' lost the half that says what to do. Two lines of 46 is 92, and
-- the break walks back to a space so a word is not cut in two.
function brun.pn_say(s)
  if brun.pn_ptxt == nil then return false end
  local t = tostring(s)
  local one, two = t, ''
  if string.len(t) > 46 then
    local cut = 46
    local i
    for i = 46, 20, -1 do
      if string.sub(t, i, i) == ' ' then cut = i - 1; break end
    end
    one = string.sub(t, 1, cut)
    two = string.sub(t, cut + 1)
    while string.sub(two, 1, 1) == ' ' do two = string.sub(two, 2) end
    two = string.sub(two, 1, 46)
  end
  display.settext(brun.pn_ptxt, one)
  if brun.pn_ptxt2 ~= nil then display.settext(brun.pn_ptxt2, two) end
  return true
end

function brun.panel_cancel()
  brun.destroy_panel()
  return true
end

-- The entry point the bench package's App header calls. Builds the form and shows it; takes no
-- capture and starts nothing, so the instrument comes up waiting for a press.
function brun.panel()
  if sdec == nil or sdec.acquire == nil then
    return false, 'the app is not loaded, so there is nothing to soak'
  end
  local ok, err = pcall(brun.build_panel)
  if not ok then
    brun.destroy_panel()
    return false, tostring(err)
  end
  display.changescreen(brun.pnscr)
  return true
end

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
-- THE ADDRESS IS ONE STRING FIELD, and the route there is worth recording because three designs
-- were tried on the glass. An option list of whole addresses could only offer what somebody had
-- listed. A prefix option plus an OBJ_EDIT_NUMBER octet needed 283 px of a 130 px gap and the number
-- field cannot be narrowed -- measured, its box is a fixed ~150 px whatever `digits` and the value
-- range say, and display.create takes no width for it. An OBJ_EDIT_STRING holds the whole address in
-- ONE box of about that same width.
--
-- SFORMAT_IP_ADDRESS, WHICH IS UNDOCUMENTED AND WAS FOUND IN THE FIRMWARE IMAGE. Probing by name
-- had concluded no IP format existed -- every spelling tried was SFORMAT_IPADDRESS, and the real one
-- has an underscore between IP and ADDRESS. The display namespace is metatable-backed and
-- next(display) yields NOTHING, so a name that is not guessed cannot be discovered from the
-- instrument at all. It came out of ki_DMM6500_v1_7_18a.zip: main.zx is itself a zip, main.x inside
-- it is a Motorola S-Record, and once that hex is decoded the API names are plain strings. No
-- encryption anywhere -- the hex encoding alone was what defeated strings(1).
--
-- Confirmed on 1.7.17a: display.SFORMAT_IP_ADDRESS is userdata, the field creates, and '10.0.1.79'
-- round-trips with no event. docs/UNDOCUMENTED.md carries the census.
--
-- THE CLEANING STAYS. The format constrains the KEYBOARD, not what a script can setvalue, and this
-- field is also written from bsdg.ip -- so the value is still stripped to digits and dots and then
-- checked for four parts of 0..255 before any run uses it. display.input.string would raise the
-- firmware's keyboard too, but it BLOCKS until answered, and blocking display calls have form here:
-- display.waitevent wedged this instrument at a 1 ms timeout and cost a power cycle.
--
-- COLUMN OFFSETS OF OUR OWN, and not edits to sdec.ui_opt_x / ui_opt_x_c2. Those are the DECODE
-- app's options screen geometry, shared with this form -- moving them to suit the bench would move
-- the shipped app's own screen with it.
brun.pn_x1off    = brun.pn_x1off or -16
brun.pn_x2off    = brun.pn_x2off or 50
-- NO ROW-PITCH OFFSET HERE, and the reason is worth keeping. One was added to put a few pixels
-- between the rows, and 2, 4 and 6 all rendered IDENTICALLY -- because g.dy is not what places
-- these rows. Read off the instrument 2026-10-22: sdec.ui_opt_dy is 100 and g.y0 is 8, which at five
-- rows would put the last one at 432 in a 431 px area, while the glass shows a ~60 px pitch and a
-- tidy form. So the vertical layout comes from somewhere else, and a brun.pn_dyoff would have sat in
-- this file looking like a control while changing nothing. The COLUMN offsets below are different:
-- both were seen to move on the glass.

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
  g.x     = (sdec.ui_opt_x or 22) + brun.pn_x1off
  g.x2    = (sdec.ui_opt_x_c2 or 420) + brun.pn_x2off
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
  brun.pn_laps, brun.pn_sdgip, brun.pn_lapt, brun.pn_vset = nil, nil, nil, nil
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

-- The two plan lines, DERIVED IN ONE PLACE so the build and the refresh cannot disagree. They used to
-- be formatted inline in build_panel, which was fine while the plan could only change between
-- sessions; the app draws its own plan now, so the lines the form was built with are stale by the
-- time it is shown and a second copy of this formatting would be a second thing to keep in step.
-- -> line1, line2
function brun.pn_plantext()
  local rows, rsub = brun.pn_plan()
  if rows == nil then
    -- REACHABLE ONLY IF THE KEY WENT AWAY after startup checked it: brun.startup draws a plan when
    -- there is none, and lands on the key screen when it cannot. So this no longer advises a host
    -- push -- the app can draw one -- it reports the key.
    return 'PLAN: none readable on the key', 'check the key and restart the app'
  end
  local l2 = ''
  if rsub ~= nil and rsub ~= '' then l2 = 'random-per-lap ' .. rsub end
  return string.format('plan: %s row(s)', brun.int(rows)), l2
end

-- Rewrite the plan lines on a form that is already built. Used by startup, because a plan drawn
-- during startup is not the plan build_panel read.
function brun.pn_refresh_plan()
  if brun.pn_ptxt == nil then return false end
  local p1, p2 = brun.pn_plantext()
  display.settext(brun.pn_ptxt, p1)
  if brun.pn_ptxt2 ~= nil then display.settext(brun.pn_ptxt2, p2) end
  return true
end

-- Build the settings screen. Returns the screen handle, or raises with a reason the operator can act
-- on -- the same contract as sdec.build_options, and for the same reason: a Run screen that opens
-- nothing is worse than a refusal that says why.
function brun.build_panel()
  -- BUILT ONCE, NEVER REBUILT. Operator's rule, restated 2026-10-22: only tear down on application
  -- exit. This opened with destroy_panel(), which is the delete-then-create idiom -- right for a
  -- screen that is rebuilt per use and wrong for one that lives for the session. brun.panel calls
  -- this at launch and brun.panel_cancel is the only thing that frees it.
  if brun.pnscr ~= nil then return brun.pnscr end
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
  -- STRAIGHT BACK TO THE COVER, BEFORE THE FIRST FIELD. Creating a screen makes it the active one, so
  -- without this the operator watches thirteen objects appear one at a time -- which is both slow and
  -- the thing the operator ruled out for the app's own screens. The cover is built first by
  -- brun.panel; when there is none (an offline render, or a direct build_panel call) this is a no-op
  -- and the build behaves as it did before.
  brun.cover_show(nil)

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
  -- THE VALUE IS NOT SET HERE. display.setvalue on a string field whose screen is NOT in front
  -- leaves the firmware's keyboard PENDING, and it then appears the moment that screen is switched
  -- to -- seen on the glass 2026-10-22, a probe that set a value before its changescreen came up
  -- with the keyboard over it. This screen is built behind the cover, so the value is written by
  -- brun.pn_ipset once the form is actually in front.
  brun.pn_sdgip = keep(create(brun.pnscr, display.OBJ_EDIT_STRING, fx, fy,
                              'SDG IP', 'generator', brun.pn_ipfmt()))
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
  local p1, p2 = brun.pn_plantext()
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
-- `resume` true means: carry on after the last cell the record on the key already holds. The result
-- screen's Resume button is the only caller that passes it; Run Soak passes nothing.
--
-- ONE START PATH, NOT TWO. Everything below -- reading the form, applying the filters, the capture
-- settings, the generator address -- has to happen identically for a resumed leg, and a second copy
-- of it is a second thing to forget to change.
function brun.panel_run(resume)
  -- THE WINDOW CHANGES ON THE PRESS, BEFORE THE FORM IS EVEN READ. It used to switch after every
  -- field had been read and applied, which is fast but not instant -- and on a resume what follows
  -- is a 15 MB read of the record. The operator's rule is that the press is acknowledged first.
  --
  -- A REFUSAL GOES BACK, which is what pays for switching this early: the three refusal paths below
  -- all speak through brun.pn_say, which writes to the FORM, so each one returns the operator to it.
  brun.show_now(brun.wkscr, 'Starting the soak', 'reading the settings')
  local laps, ip, lt, lo, hi, inter, vst, over, armv, armw
  local missing = nil
  local function val(h, name)
    if h == nil then missing = (missing or '') .. name .. ' '; return nil end
    return display.getvalue(h)
  end
  laps     = val(brun.pn_laps, 'Laps')
  -- THE ADDRESS IS CLEANED AND THEN CHECKED, which is two steps for a reason: stripping is kind to
  -- a fat-fingered keyboard entry, but a string that still is not an address after stripping must
  -- REFUSE rather than be guessed at. An address that resolves to nothing costs bsdg.timeout per
  -- query for the whole run and reads as a dead generator.
  --
  -- THE CLEANED FORM IS NOT WRITTEN BACK to the field. display.setvalue on a string field whose
  -- screen is not in front leaves the firmware's keyboard pending, and by here the working screen is
  -- already up -- so showing the operator the tidied text would ambush them with a keyboard.
  local ipraw = val(brun.pn_sdgip, 'SDG IP')
  if ipraw ~= nil then
    local clean = brun.ip_clean(ipraw)
    if not brun.ip_valid(clean) then
      brun.show_now(brun.pnscr)
      brun.pn_say('REFUSED: ' .. tostring(ipraw) .. ' is not an address -- four numbers 0-255')
      return false
    end
    ip = clean
  end
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
    brun.show_now(brun.pnscr)
    brun.pn_say('form incomplete, not starting: no ' .. missing)
    return false
  end

  local why = brun.pn_poisoned()
  if why ~= nil then
    brun.show_now(brun.pnscr)
    brun.pn_say('REFUSED: ' .. why)
    return false
  end
  local rows = brun.pn_plan()
  if rows == nil then
    brun.show_now(brun.pnscr)
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

  -- THE FORM IS KEPT, NOT TORN DOWN. It used to be destroyed here on a pool argument -- both are full
  -- screens and the pool is 463 objects -- but the measured census says there is room: the app plus
  -- all five of this app's screens is well under it, and the status screen is built once now rather
  -- than per run.
  --
  -- AND KEEPING IT IS WHAT MAKES `Back` WORK. beval.back switches to brun.pnscr, so a destroyed form
  -- left it with nothing to return to and the button did nothing at all -- measured on the instrument
  -- 2026-10-22. It is also the operator's standing rule since the same day: nothing is deleted until
  -- the app exits, and panel_cancel is where that happens.
  -- SET HERE, AND SET EVERY TIME. brun.resume is a module field, so a Run Soak after a resume would
  -- inherit the flag and quietly carry on from the record instead of starting at the top.
  brun.resume = (resume == true)
  -- THE TAG ON A RESUMED LEG MUST BE 'resumed', and this is not cosmetic: judge_bench.split_runs
  -- treats 'resumed' and 'roll' as CONTINUATIONS of the previous leg, where any other tag starts a
  -- new run in the record's header -- and the judge then reads only the last one. Tagging a resume
  -- 'soak' silently halves the thing being judged. tools/run_bench.py's --resume does the same.
  local tag = 'soak'
  if brun.resume then tag = 'resumed' end
  -- The working screen is already in front -- switched at the top of this function, on the press --
  -- so this only updates what it says about where the time is now going.
  brun.wk_say('Starting the soak', 'counting the lap and building the screen')
  brun.soak(laps, tag)
  return true
end

-- The address text for an option index, which is the same list build_panel assembled -- rebuilt here
-- rather than stashed, so a field and its meaning cannot drift apart across a rebuild.
-- '10.0.1.79' -> '10.0.1', 79. nil, nil for anything that is not four dotted numbers.
--
-- string.find WITH CAPTURES, because 5.0.2 has no string.match: it returns the two indices first and
-- the captures after them. Same trap as math.fmod, and tools/lint_tsp.py refuses the name.
function brun.ip_split(ip)
  if ip == nil then return nil, nil end
  local _, _, net, host = string.find(tostring(ip), '^(%d+%.%d+%.%d+)%.(%d+)$')
  if net == nil then return nil, nil end
  return net, tonumber(host)
end

-- The string format for the address field: the firmware's own IP format where it exists, and
-- SFORMAT_ANY where it does not. -> format constant
--
-- NIL-CHECKED RATHER THAN ASSUMED. SFORMAT_IP_ADDRESS is undocumented, found by decoding the
-- firmware image rather than from any manual, so a different build could reasonably not have it --
-- and display.create ANSWERS NIL for a format it does not take, which would lose the whole form in
-- silence. SFORMAT_ANY is present on everything and the cleaning covers the difference.
function brun.pn_ipfmt()
  if display.SFORMAT_IP_ADDRESS ~= nil then return display.SFORMAT_IP_ADDRESS end
  return display.SFORMAT_ANY
end

-- Everything that cannot be part of a dotted address, removed. -> string
--
-- SFORMAT_ANY RAISES THE FULL ALPHANUMERIC KEYBOARD -- there is no digits-only string format on this
-- firmware, all 17 other SFORMAT spellings answer nil -- so letters and spaces are reachable and a
-- slip is likely. Parenthesised because string.gsub returns the count as well.
function brun.ip_clean(s)
  if s == nil then return '' end
  return (string.gsub(tostring(s), '[^0-9.]', ''))
end

-- Four dotted numbers, each 0..255? -> true/false
--
-- string.find WITH CAPTURES, because 5.0.2 has no string.match. The anchors are load-bearing: without
-- them '10.0.1.79.5' and 'x10.0.1.79' both pass, and the first is what a doubled paste looks like.
--
-- LEADING ZEROS ARE ALLOWED -- '010.000.001.079' is how the instrument's own LAN screen renders an
-- address -- but a part over 255 is not, so '1000.1.1.1' is refused by the range test rather than by
-- counting digits.
function brun.ip_valid(s)
  if s == nil then return false end
  local _, _, a, b, c, dd = string.find(tostring(s), '^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if a == nil then return false end
  local p = {tonumber(a), tonumber(b), tonumber(c), tonumber(dd)}
  local i
  for i = 1, 4 do
    if p[i] == nil or p[i] < 0 or p[i] > 255 then return false end
  end
  return true
end

-- Write the live generator address into the field. -> ok
--
-- CALLED ONCE THE FORM IS IN FRONT, never during the build: display.setvalue on a string field whose
-- screen is not active leaves the keyboard pending and it appears on the next changescreen.
function brun.pn_ipset()
  if brun.pn_sdgip == nil then return false end
  if bsdg == nil or bsdg.ip == nil then return false end
  display.setvalue(brun.pn_sdgip, tostring(bsdg.ip))
  -- AND THE SWITCH THAT DISMISSES THE KEYBOARD, which is the whole reason this is a function.
  -- display.setvalue on an OBJ_EDIT_STRING OPENS the firmware's editor over whatever is in front --
  -- measured on the glass 2026-10-22, the app launched with the keyboard up and the operator would
  -- have had to cancel it every single time. A changescreen to the screen already in front closes
  -- it and costs nothing. Doing the setvalue before the first changescreen does NOT avoid this; the
  -- editor just appears on the switch instead.
  if brun.pnscr ~= nil then display.changescreen(brun.pnscr) end
  return true
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

-- EVERY SCREEN THIS APP BUILT, not just the form. End App is wired to this on all four screens, and
-- a teardown that freed one of them would strand the other three: the firmware keeps a display object
-- alive until it is deleted, and once brun is nil'd nothing can reach the handles. That is the whole
-- reason a panel app used to need a power cycle every few loads.
function brun.destroy_startup_screens()
  local i
  if brun.key_obj ~= nil then
    for i = 1, table.getn(brun.key_obj) do sdec.del_obj(brun.key_obj[i]) end
  end
  brun.key_obj, brun.key_txt = nil, nil
  if brun.wk_t1 ~= nil then sdec.del_obj(brun.wk_t1) end
  if brun.wk_t2 ~= nil then sdec.del_obj(brun.wk_t2) end
  brun.wk_t1, brun.wk_t2 = nil, nil
  if brun.cv_txt ~= nil then sdec.del_obj(brun.cv_txt) end
  brun.cv_txt = nil
  -- SCREENS LAST, and after the switch away that destroy_panel does: deleting the screen in front
  -- leaves the panel drawing a dead object.
  if brun.keyscr ~= nil then sdec.del_obj(brun.keyscr) end
  if brun.wkscr ~= nil then sdec.del_obj(brun.wkscr) end
  if brun.cvscr ~= nil then sdec.del_obj(brun.cvscr) end
  brun.keyscr, brun.wkscr, brun.cvscr = nil, nil, nil
  return true
end

-- THE APP EXITING is the only thing that deletes a screen, and this is it: End App on any of the five
-- screens, and the key screen's Exit button. Every screen the app built has to go here, or the ones
-- missed are stranded -- the firmware keeps a display object alive until it is deleted and nothing can
-- reach a handle once brun and beval are nil'd.
--
-- THE RESULT SCREEN WAS MISSED, and the offline suite caught it the moment that screen moved from
-- being built at the end of a run to being built at launch: 13 live objects after a teardown that
-- reported success.
function brun.panel_cancel()
  brun.destroy_panel()
  brun.destroy_startup_screens()
  if beval ~= nil and beval.destroy ~= nil then beval.destroy() end
  -- THE STATUS SCREEN TOO, and it was missed for the same reason the result screen was: it used to be
  -- deleted and rebuilt per run, so nothing had to free it at exit. Now that it is built once and
  -- kept, exit is the only thing that frees its fourteen objects -- and run_bench.py's PRELUDE calls
  -- the same function for a host reload, which is the other way this app ends.
  if brun.ui_destroy ~= nil then brun.ui_destroy() end
  return true
end

-- ---------------------------------------------------------------------------
-- Startup: the cover, the key, the plan, then the form
-- ---------------------------------------------------------------------------
-- THE COVER EXISTS BECAUSE CREATING A SCREEN MAKES IT THE ACTIVE ONE. There is no way to build a
-- screen that is not in front: display.create(ROOT, OBJ_SCREEN) shows it. So the first thing built is
-- a two-object screen saying what is happening, and every screen after it switches BACK to the cover
-- the instant its own screen exists -- which leaves the children going onto a screen nobody is
-- looking at. Before this, the soak form assembled itself in front of the operator, thirteen objects
-- at a time, which is the thing the operator ruled out for the app's own screens.
--
-- AND NOTHING IS BUILT ON DEMAND. All four screens are created here, at launch, once. A screen built
-- when a button is pressed is slower, visibly assembles, and -- the reason that rule exists at all --
-- cannot fail safely: the display object pool is 463 and exhausting it mid-session returns nil from
-- create with event 1701 logged once, so the failure arrives as a screen with holes in it.
brun.cvscr  = nil
brun.cv_txt = nil
brun.keyscr = nil
brun.key_txt = nil
brun.key_obj = nil
brun.key_tries = 0
brun.wkscr  = nil
brun.wk_t1  = nil
brun.wk_t2  = nil

-- The cover. Two objects, so the flash while it builds is one screen and one line of text.
function brun.build_cover()
  brun.cvscr = display.create(display.ROOT, display.OBJ_SCREEN, 'BENCH SOAK')
  if brun.cvscr == nil then return false end
  brun.cv_txt = display.create(brun.cvscr, display.OBJ_TEXT, 22, 150,
                               'Starting the bench soak app...',
                               sdec.ui_c_pgword, display.FONT_5, display.JUST_LEFT)
  return true
end

function brun.cover_show(s)
  if brun.cvscr == nil then return false end
  if brun.cv_txt ~= nil and s ~= nil then display.settext(brun.cv_txt, s) end
  display.changescreen(brun.cvscr)
  return true
end

-- EVENTS MUTED ACROSS A WHOLE LAUNCH, as one region rather than per function.
--
-- WHY AT ALL: a plan that is absent, empty or header-less cannot be recognised without reading it,
-- this firmware's file API has no size or seek, and a read past the end posts 2201 -- WHICH THE
-- FIRMWARE PUTS ON THE GLASS AS A POPUP. So the one unavoidable event of a missing plan arrived as a
-- dialog over the screen that was already explaining the situation in words.
--
-- WHY NESTING-SAFE: the key is read in more than one place during a launch -- build_panel composes
-- the plan line through brun.pn_plan BEFORE the form exists, and startup checks and may draw. A mute
-- per function meant the inner one restored events while the outer still needed them muted, so the
-- popup simply moved. These nest: only the outermost pop restores.
brun.evmuted = false

function brun.mute_push()
  if brun.evmuted then return false end
  if sdec == nil or sdec.mute_events == nil then return false end
  brun.evmuted = true
  sdec.mute_events()
  return true
end

function brun.mute_pop(mine)
  if mine ~= true then return false end
  brun.evmuted = false
  if sdec ~= nil and sdec.unmute_events ~= nil then sdec.unmute_events() end
  return true
end

-- Is the key there? file.usbdriveexists answers 1 or 0 and never raises; ulog.keyok() reads it the
-- same way. A nil binding is treated as absent rather than present: the honest answer when the
-- firmware cannot be asked is that this app cannot know the key is there.
--
-- THE ONE file.* CALL THAT SURVIVES, deliberately, and it is not an oversight: everything else in the
-- bench reads and writes through io/os/fs because file.read posts 2201 at the end of a file. This is
-- the only SILENT way to ask whether a key is present at all -- with no key, even io.open('/usb1')
-- posts an event -- it is platform-specific to this instrument so io has no equivalent, and fs.is_dir
-- answers a different question: whether a path is a directory, which it is not when there is nothing
-- to mount.
function brun.keyok()
  if file.usbdriveexists == nil then return false end
  return file.usbdriveexists() ~= 0
end

-- THE KEY SCREEN. Retry and Exit, on the operator's instruction of 2026-10-22 -- the app writes its
-- record and reads its plan on /usb1, so with no key there is nothing it can usefully do, and the two
-- answers are 'I have put one in' and 'let me out'.
function brun.build_keyerr()
  brun.keyscr = display.create(display.ROOT, display.OBJ_SCREEN, 'BENCH SOAK')
  if brun.keyscr == nil then return false end
  -- STRAIGHT BACK TO THE COVER, before a single child: see the block comment above.
  brun.cover_show(nil)
  brun.key_obj = {}
  local function keep(h)
    if h ~= nil then brun.key_obj[table.getn(brun.key_obj) + 1] = h end
    return h
  end
  keep(display.create(brun.keyscr, display.OBJ_TEXT, 22, 70, 'No USB key',
                      sdec.ui_c_err, display.FONT_5, display.JUST_LEFT))
  keep(display.create(brun.keyscr, display.OBJ_TEXT, 22, 130,
                      'This app keeps its plan and its record on /usb1.',
                      sdec.ui_c_pgword, display.FONT_3, display.JUST_LEFT))
  brun.key_txt = keep(display.create(brun.keyscr, display.OBJ_TEXT, 22, 170,
                                     'Insert a USB key, then press Retry.',
                                     sdec.ui_c_pgword, display.FONT_3, display.JUST_LEFT))
  -- THE BUTTON ROW COMES FROM pn_geom AND IS NOT TYPED HERE. A hardcoded y of 380 put a 58 px button
  -- at 438 against a 431 px content area -- caught offline by mock_display's geometry check, which is
  -- the whole reason that check exists. The form's own row is 360, and reading it through pn_geom
  -- means a changed form moves this screen with it.
  local g = brun.pn_geom()
  local b = display.create(brun.keyscr, display.OBJ_BUTTON, 22, g.btny, 'Retry', 200)
  if b ~= nil then
    display.setevent(b, display.EVENT_PRESS, 'sdec.guard(brun.key_retry)')
    keep(b)
  end
  local x = display.create(brun.keyscr, display.OBJ_BUTTON, 246, g.btny, 'Exit', 200)
  if x ~= nil then
    display.setevent(x, display.EVENT_PRESS, 'sdec.guard(brun.key_exit)')
    keep(x)
  end
  display.setevent(brun.keyscr, display.EVENT_ENDAPP, 'sdec.guard(brun.panel_cancel)')
  return true
end

-- The working screen, for the one step that takes minutes.
function brun.build_working()
  brun.wkscr = display.create(display.ROOT, display.OBJ_SCREEN, 'BENCH SOAK')
  if brun.wkscr == nil then return false end
  brun.cover_show(nil)
  brun.wk_t1 = display.create(brun.wkscr, display.OBJ_TEXT, 22, 120, 'Working...',
                              sdec.ui_c_pgword, display.FONT_5, display.JUST_LEFT)
  brun.wk_t2 = display.create(brun.wkscr, display.OBJ_TEXT, 22, 180, '',
                              sdec.ui_c_pgword, display.FONT_3, display.JUST_LEFT)
  display.setevent(brun.wkscr, display.EVENT_ENDAPP, 'sdec.guard(brun.panel_cancel)')
  return true
end

function brun.wk_say(l1, l2)
  if l1 ~= nil then brun.wk_msg = l1 end
  if brun.wk_t1 ~= nil and l1 ~= nil then display.settext(brun.wk_t1, l1) end
  if brun.wk_t2 ~= nil and l2 ~= nil then display.settext(brun.wk_t2, l2) end
  return true
end

-- THE SPINNER, so a draw that takes minutes cannot be mistaken for a hung app. Operator's
-- instruction of 2026-10-22, and the same four glyphs and the same 4 Hz ceiling the status screen
-- uses -- brun.spin() and brun.spinmin, not a second spinner with its own rate.
--
-- ITS OWN LAST-TICK FIELD. brun.spint belongs to the status screen's spinner and a soak may be
-- running in the same session; sharing it would make each suppress the other.
--
-- THE TIMER IS READ AND NEVER CLEARED, which is this project's standing rule for it: the global timer
-- carries the cell's phase timing and a recording's absorb, and clearing it here would make an absorb
-- from minutes ago look current. A read is free and cannot do that. A cleared-under-us timer (t below
-- the last tick) lets the tick through rather than suppressing it.
brun.wk_msg  = brun.wk_msg or 'Working'
brun.wkspint = nil
brun.nwkspin = 0
-- Rows between clock reads in the plan-draw progress hook. See the hook for why this cannot loosen
-- the 4 Hz ceiling: it only declines to ASK, and the ceiling decides.
brun.progevery = brun.progevery or 8
-- TWO YIELDS, BECAUSE THEY DO DIFFERENT JOBS, and 2 ms of the first alone was measured on the
-- instrument NOT to repaint: the form stayed up for a whole draw.
--
--   drawyield  -- a slice every brun.yieldevery rows, so the firmware is never starved for long.
--                 Operator's instruction of 2026-10-22: yield once per five lines.
--   paintyield -- a LONGER slice immediately after a write, which is what actually gets the LCD to
--                 redraw. Four a second at the 4 Hz ceiling, so 80 ms a second.
--
-- NEITHER IS brun.spinyield, which stays 0: that one fires inside sdec.acq_copy between proxy reads
-- of a live capture buffer and cost real cells. No capture runs during a plan draw.
-- Rows between slices. ONE, because a row costs ~0.5 s on the instrument: anything larger puts
-- seconds between paints. Kept as a field so it can be raised if the draw ever gets fast.
brun.yieldevery = brun.yieldevery or 1
brun.drawyield  = brun.drawyield or 0.002
brun.paintyield = brun.paintyield or 0.02

function brun.wk_spin(force)
  if brun.wk_t1 == nil then return false end
  local t = nil
  if timer ~= nil and timer.gettime ~= nil then t = timer.gettime() end
  if t ~= nil and force ~= true then
    if brun.wkspint ~= nil and t >= brun.wkspint and t - brun.wkspint < brun.spinmin then
      return false
    end
  end
  if t ~= nil then brun.wkspint = t end
  display.settext(brun.wk_t1, brun.wk_msg .. '   ' .. brun.spin())
  -- COUNTED AFTER THE RATE LIMIT, so this is redraws and not calls -- the status spinner's rule, and
  -- what lets a test tell a suppressed tick from a painted one.
  brun.nwkspin = brun.nwkspin + 1
  -- THE YIELD, AND WITHOUT IT NONE OF THIS REACHES THE GLASS. This firmware repaints only when the
  -- interpreter hands control back, and a plan draw is ONE statement off the socket that runs for
  -- minutes without ever doing so -- so every changescreen and settext above lands in state and the
  -- LCD goes on showing whatever was in front when the statement began. Measured on the instrument
  -- 2026-10-22: the form stayed up for the whole draw, which reads exactly like a hung app.
  --
  -- brun.spinyield IS A DIFFERENT KNOB AND STAYS AT 0. That one fires from inside sdec.acq_copy,
  -- between proxy reads of a live capture buffer, where a delay stretches the window a capture is
  -- copied over -- it produced a large number of failing cells within minutes of a soak. There is no
  -- capture running during a plan draw, so a yield here costs nothing but the milliseconds.
  --
  -- AFTER THE WRITE, NEVER BEFORE: the point is to give the firmware a slice in which to paint what
  -- was just written. At the 4 Hz ceiling this is four 2 ms slices a second.
  if brun.paintyield ~= nil and brun.paintyield > 0 and delay ~= nil then
    delay(brun.paintyield)
  end
  return true
end

-- Retry. THE PRESS MUST BE VISIBLE EVEN WHEN NOTHING CHANGES: a Retry that silently does nothing
-- because the key is still absent is indistinguishable from a dead button, and the operator's next
-- move after a dead button is the power switch.
function brun.key_retry()
  brun.key_tries = brun.key_tries + 1
  if not brun.keyok() then
    if brun.key_txt ~= nil then
      display.settext(brun.key_txt,
                      string.format('Still no key at /usb1 -- checked %d time(s). '
                                    .. 'Insert one and press Retry.', brun.key_tries))
    end
    return false
  end
  return brun.startup()
end

function brun.key_exit()
  return brun.panel_cancel()
end

-- The plan step. CHECKED, AND DRAWN ONLY IF WHAT IS THERE CANNOT BE USED -- bplan.ensure's rule, so a
-- targeted --spec push is left alone rather than silently replaced by the full draw.
-- HOW MANY LAPS A SELF-DRAWN PLAN COVERS. Twelve, on the operator's instruction of 2026-10-22, which
-- is 12 x 1512 = 18 144 rows.
--
-- IT IS AFFORDABLE ONLY BECAUSE OF THE FAST DRAW. Measured on the instrument: 6048 rows in about 70 s
-- once the draw stopped seeding mt19937 three times a row, so ~86 rows a second and twelve laps is
-- about three and a half minutes, once, when a key has no usable plan. Under the old per-cell seeding
-- the same twelve laps would have been about two and a half HOURS.
--
-- ONE LAP WOULD HAVE BEEN WRONG AND WOULD NOT HAVE LOOKED IT. Drawing a single iteration and then
-- running several laps makes the engine WRAP -- documented behaviour -- so every lap replays iteration
-- 1: the same amplitude, the same offset and the same wait in every cell. The run would report twelve
-- laps of coverage and have one lap's worth.
brun.plan_laps = brun.plan_laps or 12

-- Switch to `scr` AND MAKE IT APPEAR, before the caller starts anything slow. -> ok
--
-- WHY A HELPER. display.changescreen lands in state and does not reach the LCD until the interpreter
-- hands control back, so a handler that switches and then works for ten seconds leaves the OLD
-- screen in front for all ten -- which the operator reads as a dead button. brun.paintyield is the
-- slice measured to actually get a repaint out; 2 ms of drawyield was measured NOT to.
--
-- The operator's instruction of 2026-10-22: switch the window first, so pressing Run Soak, Resume or
-- Back looks immediate even when what follows is not.
function brun.show_now(scr, l1, l2)
  if scr == nil then return false end
  -- THE changescreen IS THE FIRST STATEMENT, deliberately. Operator's instruction of 2026-10-22:
  -- the switch happens on the press with nothing before it, and whatever delay is needed comes
  -- AFTER the window has changed -- that way the app looks responsive even when the work is not.
  display.changescreen(scr)
  if (l1 ~= nil or l2 ~= nil) and brun.wk_say ~= nil then brun.wk_say(l1, l2) end
  delay(brun.paintyield or 0.02)
  return true
end

function brun.plan_step(force)
  -- THE FIRST INDEX OF A FOREIGN TABLE IS GUARDED, which is this project's standing lesson about
  -- failures whose signature is silence: bench/plan_gen.tsp is a separate module, and an archive or a
  -- test harness that did not load it would turn `bplan.path` into an attempt to index nil. A nil
  -- check rather than a pcall -- the firmware never raises, and this is our own structural fault.
  if bplan == nil or bplan.check == nil then
    return false, 0, 'bench/plan_gen.tsp is not loaded, so no plan can be checked or drawn'
  end
  brun.cover_show(nil)
  brun.wk_say('Checking the plan on the key', bplan.path)
  display.changescreen(brun.wkscr)
  -- A SLICE FOR THE SWITCH ITSELF. Without it the working screen does not appear until the first
  -- paint inside the draw, and a check that takes a second shows the previous screen throughout.
  brun.wk_spin(true)
  -- EVENTS ARE MUTED ACROSS THE PLAN WORK, and this is a fix rather than a convenience. A plan that
  -- is ABSENT, EMPTY or header-less cannot be recognised without reading it, there is no size or seek
  -- in this firmware's file API, and a read past the end posts 2201 -- WHICH THE FIRMWARE PUTS ON THE
  -- GLASS AS A POPUP. So the one unavoidable event of a missing plan arrived as a dialog on top of
  -- the screen that was already explaining the situation in words, before the operator had seen
  -- anything else. Measured on the instrument 2026-10-22, two or three per launch.
  --
  -- NOT A BLANKET MUTE: it is restored before this function returns, on every path, so nothing after
  -- the plan step is hidden. sdec.unmute_events restores eventlog.SEV_ERROR, which is what the app
  -- runs at.
  local mine = brun.mute_push()
  local function unmute()
    brun.mute_pop(mine)
  end
  local ok, rows, why = bplan.check(bplan.path)
  if ok and force ~= true then
    unmute()
    return true, rows, nil
  end
  if ok then why = 'redraw asked for' end
  -- WHAT IS HAPPENING AND WHY, on the glass: this step can take minutes and the operator did not ask
  -- for it -- the app decided the key had no usable plan. Saying which is what makes the wait
  -- legible rather than mysterious.
  brun.wk_say('Drawing a plan on the key', 'no usable plan: ' .. tostring(why))
  brun.wk_spin(true)
  local eok, erows, eerr = bplan.ensure(bplan.path, {
    first = 1,
    last  = brun.plan_laps,
    force = force,
    progress = function(done, total)
      -- THE SPINNER FIRST AND UNCONDITIONALLY, because it is rate-limited inside wk_spin; the row
      -- count only moves when the spinner did, so the two lines cannot disagree about how recently
      -- this was alive.
      --
      -- ROW, TOTAL AND PER CENT, on the operator's instruction of 2026-10-22: the spinner says the
      -- app is alive, and these say whether it is going to finish this minute or this hour. The
      -- percentage is computed rather than displayed from a counter so it cannot disagree with the
      -- two numbers beside it.
      -- EVERY ROW, and the measurement is why. A row costs about half a second ON THE INSTRUMENT --
      -- roughly two rows a second, measured 2026-10-22 -- so the row-count gate that looked like a
      -- sensible saving on the host put THREE SECONDS between paints, and a screen that moves every
      -- three seconds is one an operator reasonably reads as stuck. Against 500 ms of work, a
      -- timer.gettime() and a 2 ms slice are free; the saving was never worth having here.
      --
      -- THE 4 Hz CEILING STILL CAPS IT, so this asks every row and paints at most four times a
      -- second. At the measured row rate that yields about 2 Hz, which is inside the 1-to-4 Hz band
      -- the operator asked for.
      if brun.wk_spin() then
        local pct = 0
        if total ~= nil and total > 0 then pct = done * 100 / total end
        display.settext(brun.wk_t2, string.format('row %d of %d   %d%% done',
                                                  done, total, math.floor(pct)))
      end
      -- AND A SLICE EVERY ROW, whether or not the paint happened: the point is that the interpreter
      -- never holds the processor for long, which is what 'appearing stuck is as bad as being stuck'
      -- requires. 6048 slices of 2 ms is 12 s against a draw that takes far longer than that.
      if brun.drawyield ~= nil and brun.drawyield > 0 and delay ~= nil then
        delay(brun.drawyield)
      end
    end,
  })
  unmute()
  return eok, erows, eerr
end

-- The entry point the bench package's App header calls. Builds every screen, then decides which one
-- to show; takes no capture and starts nothing, so the instrument comes up waiting for a press.
function brun.panel()
  if sdec == nil or sdec.acquire == nil then
    return false, 'the app is not loaded, so there is nothing to soak'
  end
  if brun.cvscr == nil and not brun.build_cover() then
    return false, 'display object pool exhausted before anything was built -- power cycle'
  end
  brun.cover_show('Starting the bench soak app...')
  if brun.keyscr == nil and not brun.build_keyerr() then
    return false, 'display object pool exhausted building the key screen -- power cycle'
  end
  if brun.wkscr == nil and not brun.build_working() then
    return false, 'display object pool exhausted building the working screen -- power cycle'
  end
  -- build_panel calls error() on purpose when the pool runs out, which is what this pcall is for:
  -- our own error(), not a firmware call. The firmware signals by return value and by dialog and
  -- neither is catchable.
  local ok, err = pcall(brun.build_panel)
  if not ok then
    -- THE ONE DELETE THAT IS NOT AN APP EXIT, and it is not a teardown of a live screen: the build
    -- raised part way, so this frees the PARTIAL objects of a screen that never came up. Leaving them
    -- would strand them for the session with no handle able to reach them.
    brun.destroy_panel()
    return false, tostring(err)
  end
  -- THE RESULT SCREEN, AT LAUNCH AND NOT WHEN THE RUN ENDS. beval.show() would build it on first use,
  -- which is this project's rule broken in the worst available place: the end of a soak is when the
  -- display object pool is least likely to have twelve left, and a create that returns nil there
  -- loses the one screen that says what the soak found -- after the run, so there is no second
  -- chance. Built empty here and settext'd at the end.
  --
  -- A FAILURE HERE IS NOT FATAL. The run is what matters and a soak is still worth starting without
  -- its result screen, so this reports and carries on rather than refusing to launch. beval.show()
  -- answers false when there is no screen, and the record is closed either way.
  if beval ~= nil and beval.build ~= nil and beval.scr == nil then
    if not beval.build() then
      brun.cover_show('No result screen: the display object pool is full.')
    end
  end
  return brun.startup()
end

-- Which screen the operator lands on, decided after everything exists. Called again by Retry, which
-- is why it is separate from the building.
function brun.startup()
  if not brun.keyok() then
    brun.key_tries = 0
    if brun.key_txt ~= nil then
      display.settext(brun.key_txt, 'Insert a USB key, then press Retry.')
    end
    display.changescreen(brun.keyscr)
    return true
  end
  local ok, rows, why = brun.plan_step()
  if not ok then
    -- THE KEY SCREEN CARRIES THIS TOO, because every way the plan step fails is a key problem: the
    -- key went away mid-draw, /usb1/SERDEC is missing, or the write was refused. Retry is the right
    -- offer in all three.
    if brun.key_txt ~= nil then
      display.settext(brun.key_txt, string.sub('Plan: ' .. tostring(why), 1, 58))
    end
    display.changescreen(brun.keyscr)
    return true
  end
  -- THE FORM IS FILLED BEFORE IT IS SHOWN. brun.pn_say rewrites the plan lines from what is actually
  -- on the key now, which is not what build_panel read if a plan was just drawn.
  brun.pn_refresh_plan()
  display.changescreen(brun.pnscr)
  -- AFTER THE SWITCH, DELIBERATELY. See brun.pn_ipset: setting a string field while its screen is
  -- behind another leaves the firmware's keyboard pending on the one in front.
  brun.pn_ipset()
  return true
end

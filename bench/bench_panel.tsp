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
brun = brun or {}

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
brun.pn_sdg = brun.pn_sdg or {'10.0.1.79', '10.0.1.78', '192.168.0.79'}

-- Which vectors elide, as the three sets a lap is actually run with. The middle entry is the arm from
-- the 2026-10-17 laps: the only vectors whose gaps clear two detector windows at both 9600 and
-- 19200 Bd. An empty string is not nil -- brun.elidevids nil means 'every nodrop vector', so 'None'
-- has to be expressed as elision off rather than as an empty vector set.
brun.pn_vidsets = brun.pn_vidsets or
  {{v = nil,                  t = 'All nodrop'},
   {v = 'v98d,v99d,v99a',     t = 'v98d v99d v99a'},
   {v = 'v98d,v99d',          t = 'v98d v99d'}}

-- The lap shapes, as filters over the plan on the key and NOT as draws -- see brun.wanted. Each entry
-- is the filter state the shape means, so the mapping lives beside the label instead of in a branch
-- further down that a new shape could be added without.
--
--   Full          every row the plan holds, which is what the host-driven path runs
--   Normal        standard rates only, so no drawn interstitial or edge rate plays
--   Gap targeted  only vectors that declare an idle run, which is brun.elide_gapbits' own list
--   Adversarial   only vectors known to produce errors, which is barb.loud's list -- the ones the
--                 plan drives into conditions where refusing is the documented right answer -- plus
--                 the gap vectors, whose seams cost bytes until the decoder splice exists. Derived
--                 from those two tables and not a third hand-typed list, so a vector added to either
--                 is covered here without anybody remembering to.
brun.pn_laptypes = brun.pn_laptypes or
  {{t = 'Full',         std = nil,  gap = nil,  adv = nil},
   {t = 'Normal',       std = true, gap = nil,  adv = nil},
   {t = 'Gap targeted', std = nil,  gap = true, adv = nil},
   {t = 'Adversarial',  std = nil,  gap = nil,  adv = true}}

-- The rate window, in Bd. Defaults span the whole ladder, so the fields open describing a lap that
-- filters nothing: 300 is the slowest rate soakplan draws and 250 000 the decoder's own ceiling.
brun.pn_baudlo = brun.pn_baudlo or 300
brun.pn_baudhi = brun.pn_baudhi or 250000

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
  g.x    = sdec.ui_opt_x or 22
  g.x2   = sdec.ui_opt_x_c2 or 420
  g.y0   = sdec.ui_opt_y0 or 60
  g.dy   = sdec.ui_opt_dy or 54
  g.btny = sdec.ui_opt_btn_y or 380
  return g
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
brun.pnscr = nil
brun.pn_obj = nil

-- Hand every object back, screen last. Switch away first, then delete: ui_destroy's rule, because a
-- delete against the screen in front leaves the panel drawing a dead object.
function brun.destroy_panel()
  if brun.pnscr == nil then return false end
  pcall(display.changescreen, display.SCREEN_HOME)
  local i
  if brun.pn_obj ~= nil then
    for i = 1, table.getn(brun.pn_obj) do sdec.del_obj(brun.pn_obj[i]) end
  end
  brun.pn_obj = nil
  sdec.del_obj(brun.pnscr)
  brun.pnscr = nil
  return true
end

-- The plan on the key, as a line the operator can read before committing to a run. Opened and closed
-- here rather than left open: brun.planopen is the run's own handle and a second reader would share
-- the position. -> rows, variant or nil.
function brun.pn_plan()
  local keep = brun.planrows
  brun.planrows = 0
  local ok = brun.planopen()
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
  local g = brun.pn_geom()
  brun.pn_obj = {}
  local function keep(h)
    if h ~= nil then brun.pn_obj[table.getn(brun.pn_obj) + 1] = h end
    return h
  end

  brun.pnscr = create(display.ROOT, display.OBJ_SCREEN, 'BENCH SOAK')
  if brun.pnscr == nil then
    error('display object pool exhausted building the soak screen -- power cycle the instrument.', 0)
  end

  -- Eight fields in two columns is four rows, and the pitch has to clear the button row: the same
  -- arithmetic build_options does, read from its constants so a changed form moves this one too.
  local nf = 8
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
  -- Zero is off, and it is the default: elision is the feature under test rather than the normal way
  -- to run a lap, and a panel that defaults it on would quietly change what every manual soak means.
  brun.pn_elide = keep(create(brun.pnscr, display.OBJ_EDIT_NUMBER, fx, fy,
                              'Gap Elide', '0 off, cut after',
                              display.NFORMAT_PREFIX, 0, 0, sdec.gapelide_max, 's', 4))
  fx, fy = nextpos()
  local vt = {}
  local i
  for i = 1, table.getn(brun.pn_vidsets) do vt[i] = brun.pn_vidsets[i].t end
  brun.pn_vids = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                             'Elide Vectors', 'which ones elide',
                             vt[1], vt[2], vt[3]))
  fx, fy = nextpos()
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
  brun.pn_lapt = keep(create(brun.pnscr, display.OBJ_EDIT_OPTION, fx, fy,
                             'Lap Type', 'narrows the plan', lt[1], lt[2], lt[3], lt[4]))
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

  -- THE PLAN, STATED BEFORE THE RUN IS COMMITTED. A soak started against a plan the operator did not
  -- expect is a lap of instrument time spent on the wrong question, and the key keeps whichever plan
  -- was pushed last -- a targeted --spec overwrites PLAN.CSV, so what is there is not necessarily the
  -- fortnight plan.
  local rows, rsub = brun.pn_plan()
  local ptxt
  if rows == nil then
    ptxt = 'PLAN: none on the key -- push one with run_bench.py --push-plan'
  else
    ptxt = string.format('plan: %s row(s)%s', brun.int(rows),
                         (rsub ~= nil and rsub ~= '') and (', random-per-lap ' .. rsub) or '')
  end
  fx, fy = nextpos()
  brun.pn_ptxt = keep(create(brun.pnscr, display.OBJ_TEXT, g.x, g.btny - 44, ptxt))

  -- Two buttons, and Cancel is one of them for build_options' reason: a form with no way out is worse
  -- than no form.
  local bdef = {{x = 22,  w = 200, t = 'Run Soak', e = 'brun.panel_run'},
                {x = 234, w = 200, t = 'Cancel',   e = 'brun.panel_cancel'}}
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
  pcall(display.setevent, brun.pnscr, display.EVENT_ENDAPP, 'sdec.guard(brun.panel_cancel)')
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
-- raise half way would otherwise commit a partial configuration, which is options_apply's rule.
function brun.panel_run()
  local laps, elide, vids, ip, lt, lo, hi, inter
  local readok, readerr = pcall(function()
    laps = display.getvalue(brun.pn_laps)
    elide = display.getvalue(brun.pn_elide)
    local vi = display.getvalue(brun.pn_vids)
    if type(vi) == 'number' then
      local e = brun.pn_vidsets[math.floor(vi + 0.5)]
      if e ~= nil then vids = e.v end
    end
    local si = display.getvalue(brun.pn_sdgf)
    if type(si) == 'number' then ip = brun.pn_sdgtxt(math.floor(si + 0.5)) end
    local li = display.getvalue(brun.pn_lapt)
    if type(li) == 'number' then lt = brun.pn_laptypes[math.floor(li + 0.5)] end
    lo = display.getvalue(brun.pn_lo)
    hi = display.getvalue(brun.pn_hi)
    inter = display.getvalue(brun.pn_inter)
  end)
  if not readok then
    brun.pn_say('could not read the form: ' .. tostring(readerr))
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
  brun.filt_stdonly, brun.filt_gaponly, brun.filt_advonly = lt.std, lt.gap, lt.adv
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
  if type(elide) == 'number' and elide > 0 then
    brun.elide = elide
    brun.elidevids = vids
  else
    brun.elide = nil
    brun.elidevids = nil
  end
  if ip ~= nil and bsdg ~= nil then
    -- Closed before the address moves, or the next select talks to the old session on the new name.
    if bsdg.close ~= nil then pcall(bsdg.close) end
    bsdg.ip = ip
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
-- refusal replaces it: a message that needs a second object can fail to appear for want of one.
function brun.pn_say(s)
  if brun.pn_ptxt == nil then return false end
  return pcall(display.settext, brun.pn_ptxt, string.sub(tostring(s), 1, 58))
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
  pcall(display.changescreen, brun.pnscr)
  return true
end

-- soak_eval.tsp -- what the run just did, on one screen, the moment it ends.
--
-- WHY ON THE INSTRUMENT AT ALL. The verdict on a soak has always come from the host judge, and still
-- does -- tools/judge_bench.py reads the record and is the oracle. But a soak started at the panel
-- ends with nobody connected, and until now the only thing on the glass was the stop reason: an
-- operator walking up to a finished overnight run could not tell a clean lap from a bad one without
-- fetching the record. This answers that one question, in the two forms worth having: did anything
-- get WORSE than last time, and WHICH waveforms are responsible.
--
-- IT RUNS ON BOTH ENDINGS, which is the point of hooking brun.soak's single exit: a run that
-- completes its laps and a run the operator stopped with TRIGGER both arrive there, and the second is
-- the common case on a long soak.
--
-- THE PANEL IS NOT THE ORACLE, and this screen says so in as many words. The four classes here are
-- the engine's own counters, computed cell by cell on the instrument with the thresholds in
-- bench_run.tsp; the host judge weighs coverage floors and head damage that this cannot see. A green
-- headline here means 'nothing got worse by the panel's own measure', not 'passed'.
--
-- THE COMPARISON IS AGAINST RATES, NEVER COUNTS. Runs differ in length -- five laps against one, or a
-- TRIGGER press at cell 300 -- so raw totals compare two different experiments. Every class is
-- normalised by its own denominator before anything is called a regression.

beval = beval or {}

-- The previous runs' summaries, on the key beside the record. 8.3, like everything this firmware's
-- file API is given: docs/MEASUREMENTS.md records that it posts events rather than failing a long name.
beval.path = beval.path or '/usb1/SERDEC/EVAL.CSV'

beval.cols = 'when,tag,laps,cells,bad,judged,cmpb,badb,wrong,flag,unexp,exp'

-- HOW MUCH WORSE IS A REGRESSION. Two conditions, and both must hold: the rate has to rise by more
-- than `rel`, AND the class has to gain at least `absmin` occurrences over what the previous rate
-- would have predicted for this run's length. The second is what stops a short run from reporting a
-- regression off one extra bad cell -- at 40 cells, one cell is a 2.5 % rate and the previous run's
-- 0.5 % looks like a 400 % rise.
--
-- DELIBERATELY NOT A SIGNIFICANCE TEST. docs/MEASUREMENTS.md records that lap failure counts are
-- UNDER-dispersed against binomial by 3.09x, so a binomial test here would be too lenient and would
-- also be a statistical claim this screen is in no position to make. These are two thresholds an
-- operator can read off the screen and argue with, which is the honest shape for a panel light.
beval.rel    = beval.rel or 0.25
beval.absmin = beval.absmin or 3

-- ---------------------------------------------------------------------------
-- This run, as numbers
-- ---------------------------------------------------------------------------
-- -> a summary table, or nil when no run has happened in this session.
--
-- READ OFF brun's OWN COUNTERS, never recomputed: these are the figures the status screen showed
-- while the run was going, so the end screen cannot disagree with what the operator was watching.
function beval.summary()
  if brun == nil or brun.ncell == nil then return nil end
  local s = {}
  s.when   = os.time()
  s.tag    = brun.tag or 'SOAK'
  s.laps   = brun.iter or 0
  s.cells  = brun.ncell or 0
  s.bad    = brun.nbad or 0
  s.judged = brun.npayj or 0
  s.cmpb   = brun.ncmpb or 0
  s.badb   = brun.nbadb or 0
  s.wrong  = brun.nwrong or 0
  s.flag   = brun.nframe or 0
  s.unexp  = brun.nunexp or 0
  s.exp    = brun.nexp or 0
  return s
end

-- The four rates, each over its OWN denominator. -> wrong, badb, flag, unexp (all per unit, 0 when
-- the denominator is 0 -- a class with nothing to measure has not regressed).
--
-- THE DENOMINATORS ARE NOT INTERCHANGEABLE, which is the whole reason this is one function. `wrong`
-- is cells over cells that could be JUDGED -- a vector with no expected bytes is not in it. `badb` is
-- bytes over bytes COMPARED. `flag` and `unexp` are cells over cells RUN. Dividing all four by the
-- cell count would understate wrong by whatever share of the lap cannot be judged, which is how a
-- regression in the judged subset would hide behind the vectors that are not in it.
function beval.rates(s)
  local function per(n, d)
    if d == nil or d <= 0 then return 0 end
    return n / d
  end
  return per(s.wrong, s.judged), per(s.badb, s.cmpb),
         per(s.flag, s.cells), per(s.unexp, s.cells)
end

-- ---------------------------------------------------------------------------
-- The key: read the last run, then append this one
-- ---------------------------------------------------------------------------
-- The most recent summary on the key, or nil. -> table or nil
--
-- THE LAST DATA LINE WINS. The file is appended to, one line per run, so it is a short history rather
-- than a single value -- which costs nothing and means a regression can be looked at against more
-- than one predecessor later. Read before this run's line is written, never after.
function beval.prev(path)
  path = path or beval.path
  local fh = file.open(path, file.MODE_READ)
  if fh == nil then return nil end
  local last = nil
  local ln = file.read(fh, file.READ_LINE)
  while ln ~= nil and ln ~= '' do
    ln = string.gsub(ln, '[\r\n]', '')
    if ln ~= '' and string.sub(ln, 1, 1) ~= '#' and ln ~= beval.cols then last = ln end
    ln = file.read(fh, file.READ_LINE)
  end
  file.close(fh)
  if last == nil then return nil end
  -- brun.split is the engine's own CSV splitter; a second one here would be a second thing to get
  -- wrong about quoting.
  local f, nf = brun.split(last)
  if nf < 12 then return nil end
  return {when = tonumber(f[1]) or 0, tag = f[2], laps = tonumber(f[3]) or 0,
          cells = tonumber(f[4]) or 0, bad = tonumber(f[5]) or 0, judged = tonumber(f[6]) or 0,
          cmpb = tonumber(f[7]) or 0, badb = tonumber(f[8]) or 0, wrong = tonumber(f[9]) or 0,
          flag = tonumber(f[10]) or 0, unexp = tonumber(f[11]) or 0, exp = tonumber(f[12]) or 0}
end

-- Append this run. -> ok
--
-- APPEND AND NOT REWRITE, so a key pulled during the write costs the new line and not the history.
function beval.save(path, s)
  path = path or beval.path
  if s == nil then return false end
  -- THE PROBE HANDLE IS CLOSED. Written as a bare `file.open(...) == nil` first, which leaked a
  -- descriptor per finished run -- invisible on a host test and a real cost on an instrument that
  -- runs for a fortnight without a restart.
  local probe = file.open(path, file.MODE_READ)
  local fresh = (probe == nil)
  if probe ~= nil then file.close(probe) end
  local fh = file.open(path, file.MODE_APPEND)
  if fh == nil then return false end
  if fresh then
    file.write(fh, '# one line per finished soak, written by bench/soak_eval.tsp\n')
    file.write(fh, beval.cols .. '\n')
  end
  file.write(fh, string.format('%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n',
                               s.when, tostring(s.tag), s.laps, s.cells, s.bad, s.judged,
                               s.cmpb, s.badb, s.wrong, s.flag, s.unexp, s.exp))
  file.flush(fh)
  file.close(fh)
  return true
end

-- ---------------------------------------------------------------------------
-- Did anything get worse?
-- ---------------------------------------------------------------------------
-- -> n, lines   n is the number of classes that regressed; lines describes each.
--
-- NO PREVIOUS RUN IS NOT 'NO REGRESSIONS'. It is a different answer and the screen says so: there is
-- nothing to compare against, which is exactly the state a first run on a fresh key is in. Reporting
-- that as green would make the first run of any new key look like a pass.
function beval.regress(cur, prev)
  local lines, n = {}, 0
  if cur == nil or prev == nil then return 0, lines end
  local cw, cb, cf, cu = beval.rates(cur)
  local pw, pb, pf, pu = beval.rates(prev)
  local function cmp(name, crate, prate, cden, unit)
    -- A class with no denominator this run cannot be compared: nothing was measured.
    if cden == nil or cden <= 0 then return end
    if prate <= 0 and crate <= 0 then return end
    -- EXPECTED AT THE OLD RATE, which is what makes absmin mean the same thing at every run length.
    local expect = prate * cden
    local got    = crate * cden
    if crate > prate * (1 + beval.rel) and got - expect >= beval.absmin then
      n = n + 1
      lines[n] = string.format('%s %.3f%% was %.3f%% (+%d %s)',
                               name, crate * 100, prate * 100,
                               bplan ~= nil and bplan.iround(got - expect) or (got - expect), unit)
    end
  end
  cmp('wrong',  cw, pw, cur.judged, 'cell(s)')
  cmp('bad',    cb, pb, cur.cmpb,   'byte(s)')
  cmp('flag',   cf, pf, cur.cells,  'cell(s)')
  cmp('unexp',  cu, pu, cur.cells,  'cell(s)')
  return n, lines
end

-- ---------------------------------------------------------------------------
-- Which waveforms are responsible
-- ---------------------------------------------------------------------------
-- The worst n vectors. -> list of {vid=, wrong=, badb=, flag=, unexp=, score=}
--
-- ORDERED BY THE FOUR CLASSES IN THAT ORDER -- wrong, then bad bytes, then flagged, then unexpected
-- refusals -- which is the operator's ordering of 2026-10-22 and is a priority, not a sum. A vector
-- with one wrong cell outranks one with two hundred flagged frames, because wrong bytes are a decode
-- that confidently lied and flagged frames are a decode that said it was unsure. Summing them would
-- let the loudest class bury the most serious one.
--
-- ONLY VECTORS WITH SOMETHING TO REPORT. A list padded to six with clean vectors reads as six
-- problems; the screen says how many there were.
function beval.topvec(n)
  n = n or 6
  if brun == nil or brun.vwrong == nil then return {}, 0 end
  local seen, ids, ni = {}, {}, 0
  local function note(t)
    if t == nil then return end
    local k
    for k in pairs(t) do
      if seen[k] == nil then
        seen[k] = true
        ni = ni + 1
        ids[ni] = k
      end
    end
  end
  note(brun.vwrong)
  note(brun.vbadb)
  note(brun.vflag)
  note(brun.vunexp)
  local out, no = {}, 0
  local i
  for i = 1, ni do
    local v = ids[i]
    local w = brun.vwrong[v] or 0
    local b = brun.vbadb[v] or 0
    local f = brun.vflag[v] or 0
    local u = brun.vunexp[v] or 0
    if w > 0 or b > 0 or f > 0 or u > 0 then
      no = no + 1
      out[no] = {vid = v, wrong = w, badb = b, flag = f, unexp = u}
    end
  end
  -- A TOTAL ORDER, because table.sort is not stable and a tie broken by the sort's internals would
  -- put a different vector on the screen between two runs with identical counters.
  table.sort(out, function(a, b)
    if a.wrong ~= b.wrong then return a.wrong > b.wrong end
    if a.badb  ~= b.badb  then return a.badb  > b.badb  end
    if a.flag  ~= b.flag  then return a.flag  > b.flag  end
    if a.unexp ~= b.unexp then return a.unexp > b.unexp end
    return a.vid < b.vid
  end)
  local keep, nk = {}, 0
  for i = 1, no do
    if nk >= n then break end
    nk = nk + 1
    keep[nk] = out[i]
  end
  return keep, no
end

-- ---------------------------------------------------------------------------
-- The screen
-- ---------------------------------------------------------------------------
-- FONT_3 THROUGHOUT THE BODY, on the operator's instruction of 2026-10-22. It is 20 px, so a row
-- pitch of 26 fits the eleven rows below inside the 431 px content area with room at the bottom.
beval.scr    = nil
beval.obj    = nil
beval.rows   = 6
beval.y0     = 150
beval.dy     = 26

function beval.destroy()
  if beval.scr == nil then return false end
  display.changescreen(display.SCREEN_HOME)
  local i
  if beval.obj ~= nil then
    for i = 1, table.getn(beval.obj) do sdec.del_obj(beval.obj[i]) end
  end
  beval.obj = nil
  sdec.del_obj(beval.scr)
  beval.scr = nil
  beval.t_verdict, beval.t_run, beval.t_err, beval.t_cmp, beval.t_head = nil, nil, nil, nil, nil
  beval.t_row = nil
  return true
end

-- Built EMPTY and once, like every other screen in this app: nothing is created when the run ends,
-- because the display object pool is 463 and a soak that exhausts it at the finish line would lose
-- the one screen that says what the soak found.
function beval.build()
  -- BUILT ONCE AND NEVER REBUILT. Operator's rule of 2026-10-22: nothing is deleted until the app
  -- exits. This used to call beval.destroy() first, which is the delete-then-create idiom -- correct
  -- for a screen that is torn down between uses and wrong for one that is not. The eleven texts and
  -- the button are settext'd by every run instead, so a second lap costs no display object at all.
  if beval.scr ~= nil then return true end
  beval.scr = display.create(display.ROOT, display.OBJ_SCREEN, 'SOAK RESULT')
  if beval.scr == nil then return false end
  -- Back behind the cover before the first child, so this does not assemble in front of anyone.
  if brun ~= nil and brun.cover_show ~= nil then brun.cover_show(nil) end
  beval.obj = {}
  local function keep(h)
    if h ~= nil then beval.obj[table.getn(beval.obj) + 1] = h end
    return h
  end
  local dim = (sdec ~= nil and sdec.ui_c_dim) or 0xB0B0B0
  local val = (sdec ~= nil and sdec.ui_c_data) or 0xFFFFFF
  beval.t_verdict = keep(display.create(beval.scr, display.OBJ_TEXT, 22, 24, '',
                                        val, display.FONT_5, display.JUST_LEFT))
  beval.t_run = keep(display.create(beval.scr, display.OBJ_TEXT, 22, 70, '',
                                    val, display.FONT_3, display.JUST_LEFT))
  beval.t_err = keep(display.create(beval.scr, display.OBJ_TEXT, 22, 96, '',
                                    val, display.FONT_3, display.JUST_LEFT))
  beval.t_head = keep(display.create(beval.scr, display.OBJ_TEXT, 22, 124, '',
                                     dim, display.FONT_3, display.JUST_LEFT))
  beval.t_row = {}
  local i
  for i = 1, beval.rows do
    beval.t_row[i] = keep(display.create(beval.scr, display.OBJ_TEXT, 22,
                                         beval.y0 + (i - 1) * beval.dy, '',
                                         val, display.FONT_3, display.JUST_LEFT))
  end
  beval.t_cmp = keep(display.create(beval.scr, display.OBJ_TEXT, 22,
                                    beval.y0 + beval.rows * beval.dy + 10, '',
                                    dim, display.FONT_3, display.JUST_LEFT))
  -- BACK TO THE FORM, so a finished lap is not a dead end. Without it the only way to start a second
  -- lap was to relaunch the app, which on this instrument means re-entering it from Scripts -- and
  -- every relaunch rebuilds every display object out of a pool of 463 that is never reclaimed.
  --
  -- THE ROW COMES FROM pn_geom, not from a number typed here: a 58 px button at a hardcoded 380 sits
  -- at 438 against a 431 px content area, which is the mistake the key screen made and mock_display
  -- caught. 360 clears the comparison line at 316.
  local btny = 360
  if brun ~= nil and brun.pn_geom ~= nil then btny = brun.pn_geom().btny end
  local b = display.create(beval.scr, display.OBJ_BUTTON, 22, btny, 'Back', 200)
  if b ~= nil then
    display.setevent(b, display.EVENT_PRESS, 'sdec.guard(beval.back)')
    keep(b)
  end
  display.setevent(beval.scr, display.EVENT_ENDAPP, 'sdec.guard(beval.endapp)')
  return true
end

-- Back to the settings form. The result screen is LEFT STANDING rather than destroyed: it is eleven
-- texts and a button that will be settext'd again by the next run, and deleting and recreating them
-- spends pool ids that are never reclaimed. -> ok
--
-- THE PLAN LINE IS RE-READ on the way back, because the form's two plan lines were composed when the
-- form was built and the key is the thing that can have changed since -- a record was just written to
-- it, and on a long soak the key is also the thing most likely to have been swapped.
function beval.back()
  if brun == nil or brun.pnscr == nil then return false end
  if brun.pn_refresh_plan ~= nil then brun.pn_refresh_plan() end
  display.changescreen(brun.pnscr)
  return true
end

-- End App on this screen tears down everything the app built, the bench panel's own rule: the
-- firmware keeps a display object alive until it is deleted, and once brun and beval are nil'd
-- nothing can reach the handles.
function beval.endapp()
  beval.destroy()
  if brun ~= nil and brun.panel_cancel ~= nil then brun.panel_cancel() end
  return true
end

-- FILL IT, THEN SWITCH TO IT -- this project's standing display rule. -> ok
--
-- IT DOES NOT BUILD. brun.panel builds this screen at launch; a run that ends with no screen reports
-- false and leaves the record -- which is already closed by then -- as the only account. Building
-- here would put a dozen display.create calls at the one moment the pool is least likely to have
-- them, after the run, with no second chance.
function beval.show()
  if beval.scr == nil then return false end
  local cur = beval.summary()
  if cur == nil then return false end
  local prev = beval.prev(beval.path)
  local nreg, lines = beval.regress(cur, prev)

  local green = (sdec ~= nil and sdec.ui_c_sn_ok) or 0x80FF80
  local red   = (sdec ~= nil and sdec.ui_c_err) or 0xFF6060
  local amber = (sdec ~= nil and sdec.ui_c_warn) or 0xFFC000
  if prev == nil then
    -- NOT GREEN. A first run on a fresh key has nothing to compare against, and saying 'no
    -- regressions' would make that look like a pass.
    display.settext(beval.t_verdict, 'NO PREVIOUS RUN TO COMPARE')
    display.setcolor(beval.t_verdict, amber)
  elseif nreg == 0 then
    display.settext(beval.t_verdict, 'NO REGRESSIONS')
    display.setcolor(beval.t_verdict, green)
  else
    display.settext(beval.t_verdict, string.format('%d REGRESSION(S)', nreg))
    display.setcolor(beval.t_verdict, red)
  end

  display.settext(beval.t_run,
                  string.format('%s  %d lap(s)  %d cell(s)  %d no decode  %d judged',
                                tostring(cur.tag), cur.laps, cur.cells, cur.bad, cur.judged))
  -- THE SAME FOUR CLASSES THE RANKING USES, in the same order, so the totals and the table below
  -- cannot be read as describing different things.
  display.settext(beval.t_err,
                  string.format('wrong %d  bad %d/%d  flag %d  unexp %d  (allowed %d)',
                                cur.wrong, cur.badb, cur.cmpb, cur.flag, cur.unexp, cur.exp))

  local top, ntop = beval.topvec(beval.rows)
  if ntop == 0 then
    display.settext(beval.t_head, 'No vector produced an unexpected error.')
  else
    display.settext(beval.t_head,
                    string.format('Worst %d of %d vector(s) with errors -- '
                                  .. 'wrong, bad, flag, unexp:',
                                  table.getn(top), ntop))
  end
  local i
  for i = 1, beval.rows do
    local t = top[i]
    if t == nil then
      display.settext(beval.t_row[i], '')
    else
      display.settext(beval.t_row[i],
                      string.format('%d. %-5s  wrong %d  bad %d  flag %d  unexp %d',
                                    i, t.vid, t.wrong, t.badb, t.flag, t.unexp))
    end
  end

  -- WHAT IT WAS COMPARED WITH, and the reminder that this is not the verdict. A regression line with
  -- no baseline named is not actionable, and a green headline that reads as 'passed' is worse than no
  -- headline at all.
  local tail
  if prev == nil then
    tail = 'First run on this key. The host judge is the verdict: judge_bench.py'
  else
    tail = string.format('vs %s, %d cell(s). Panel measure only -- judge_bench.py is the verdict',
                         tostring(prev.tag), prev.cells)
    if nreg > 0 and lines[1] ~= nil then
      tail = lines[1]
      if nreg > 1 then tail = tail .. string.format('  (+%d more)', nreg - 1) end
    end
  end
  display.settext(beval.t_cmp, string.sub(tail, 1, 74))

  -- THE RECORD OF THIS RUN GOES DOWN LAST, after the comparison has read the previous one.
  beval.save(beval.path, cur)
  display.changescreen(beval.scr)
  return true
end

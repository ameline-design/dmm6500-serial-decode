-- bench_run.tsp -- the soak loop, running on the instrument with nobody connected.
--
-- brun.soak(n) runs n iterations of the plan; brun.soak() or brun.soak(0) runs until the power is cut.
-- Every cell is written to the USB key as it completes, because a power cycle is the stop button and
-- there is no graceful exit to save anything at.
--
-- THE MEASUREMENT SEQUENCE IS NOT INVENTED HERE. brun.point() below is the same sequence as
-- bench_point() in tools/bench_uart.py's BENCH_TSP string, which is what every bench result this
-- project has ever recorded came through: clear the event log, clear every force, set fs and trigmode,
-- acquire, decode, read the same fields off sdec. If the two drift apart then this soak stops measuring
-- what the bench measures, which is its whole justification -- so tools/test_bench_engine.lua loads
-- BOTH and compares them on one capture rather than trusting this comment.
--
-- THE PLAN IS READ, NEVER DRAWN. tools/soakplan.py emits it and the key carries it. Re-deriving the
-- draw here would mean a second implementation of the log-uniform placement, the ladder-edge
-- substitution and -- worst -- the skip-before-shuffle indexing, where the positional index keys the
-- amplitude, the offset AND the wait. That last one has already cost this project 1677 mis-driven
-- cells in a single lap, silently, and it looked exactly like a working run.
--
-- STREAMED, NOT LOADED. The plan for a long soak is tens of thousands of rows; reading it whole would
-- spend instrument memory on data used once each. It is read a line at a time and, at end of file,
-- reopened from the start -- so an indefinite run wraps around the emitted iterations and says so in
-- the status log rather than stopping or pretending the iteration number is new.

brun = brun or {}

brun.dir      = brun.dir or '/usb1/SERDEC'
brun.planpath = brun.planpath or (brun.dir .. '/PLAN.CSV')
brun.stoppath = brun.stoppath or (brun.dir .. '/STOP.TXT')
brun.listenip   = brun.listenip or nil    -- optional host listener for live progress; nil = none
brun.listenport = brun.listenport or 5099

brun.pfh      = nil      -- plan handle while streaming
brun.nwrap    = 0        -- times the plan file has been re-read from the start
brun.ncell    = 0        -- cells attempted this run
brun.nbadsdg  = 0        -- consecutive generator failures
brun.stopwhy  = nil
brun.stopbad  = false   -- did it park because something is wrong, or finish what it was asked?

-- HOW MANY GENERATOR FAILURES IN A ROW BEFORE PARKING. With nobody to power cycle the SDG, a wedged
-- generator means every remaining cell is stimulus-free -- and thousands of rows recording "no bytes"
-- against a dead wire would read, to anyone judging later, exactly like a decoder that had collapsed.
-- Better to stop with a reason on the key than to fill it with evidence for a false conclusion.
brun.maxsdgfail = brun.maxsdgfail or 20

-- A RUN ENDS WHEN SOMEBODY ENDS IT: the iteration count, the TRIGGER key, or the stop file. A FAULT IS
-- NOT ONE OF THEM. Everything that used to park -- a wedged generator, a record that will not write, a
-- plan file that has gone -- now goes red, writes the reason to the key, and keeps retrying. This
-- generator has stopped answering three times in the project's history, and parking on day 2 of a
-- fortnight throws away twelve days nobody is there to restart.
--
-- holdsecs is the retry period. HELD IN SLICES, not one delay(), so the panel keeps changing and the
-- TRIGGER key still works -- without it the only way out of a hold is the power. 0 restores parking.
brun.holdsecs = brun.holdsecs or 300      -- seconds between retries; 0 parks, and nothing asks for that
brun.holdslice = brun.holdslice or 10     -- how long a single delay() may be, so the panel stays alive
brun.holdmax = brun.holdmax or 0          -- give up after this many seconds of holding; 0 = never
brun.nhold = 0                            -- retries attempted this run
brun.heldsecs = 0                         -- seconds spent holding this run

-- CELLS MEASURED WHILE NOTHING WAS BEING WRITTEN DOWN, and how often the record came back. A run that
-- keeps going through a recording failure is the right behaviour and a silent one is not: these are what
-- turn 'the file has a gap in it' into 'the file has a gap in it and the run says how big'.
brun.recretry = brun.recretry or 50      -- cells between attempts to record again
brun.nrecfail = 0                        -- consecutive cells measured but not recorded
brun.nreclost = 0                        -- cells this run that were never written down
brun.nrecback = 0                        -- times recording recovered
brun.nsdgalive = 0                       -- cells with no stimulus while the generator answered

-- HOW OFTEN THE STOP FILE IS LOOKED FOR, in cells. Not every cell, and the reason is measured: any
-- look at a file or directory that is not readable POSTS AN EVENT -- 2201 'File read error' for the
-- directory read, 2205 'File not found' for a missing file -- and at one per cell that is 86 events in
-- a smoke and about 1.4 million across eight days. The power cycle is the documented way to end a run;
-- the stop file is a convenience, and a convenience does not get to spend an event per cell. At 200
-- cells this is roughly one look every 20 minutes.
brun.stopevery = brun.stopevery or 0     -- 0 = never look; see the note in the loop

-- A HARD CEILING ON CELLS, 0 MEANING NONE, AND IT IS FOR THE OFFLINE SUITE. An indefinite run is
-- stopped by cutting the power, which a test cannot do -- so a test drives brun.soak(0) and arranges for
-- something to end it. When the thing that was supposed to end it does not, the loop does not fail: it
-- spins, and a suite that spins until something kills it reports through a pipeline as exit 0, which
-- reads exactly like a pass. That happened here: the stop-file test drove an indefinite run after the
-- stop-file check had been switched off by default, and the suite looked green while never reaching its
-- last third. A cap turns that hang into an assertion.
brun.maxcell = brun.maxcell or 0

-- HOW MANY MEASUREMENT COLUMNS A RESULT ROW CARRIES between the plan's nine and the 'why' text: fs,
-- sa_bit, ran, read_baud, fmt, nf, ngood, nbad, nflag, headsusp, snapped, snapfirm. Named because a
-- stimulus-free cell has to write that many empty ones, and counting commas in a format string is how
-- a 22-field row got into a 23-field schema. bench_rec.tsp's header is the declaration; this is the
-- number the rows are built from, and test_bench_engine.lua checks the two against each other.
brun.nmeascol = 12

-- THE SLOWEST SAMPLE RATE A CELL MAY BE CAPTURED AT, and it exists because trusting the arithmetic cost
-- 10 % of a lap. sdec.pick_fs(baud, 8) asks for eight samples a bit, which at 300 baud is 2500 Sa/s -- a
-- rate the ladder lists and the instrument does not deliver: MEASURED, from the buffer's own
-- relativetimestamps, a cell commanding 300 baud captured at 1 000 000 Sa/s. That is 3333 samples a bit,
-- so ua_probe's 4000-sample window spans 1.2 BIT TIMES and no format can be fitted to it. Every failure
-- below 2400 baud in a 117-cell lap was this, and none above it.
--
-- serial_app.tsp already solved the same problem for the operator's own capture, and its comment is the
-- evidence: its probe ladder is {1e6, 1e5, 1e4}, dropping the rate to cover ten times as long, and it
-- stops at 10 kSa/s because 20 000 samples there is 2 s -- sixty frames at 300 baud. So the floor here is
-- that same 10 kSa/s: a rate the app uses, on hardware, at these baud rates.
--
-- WHAT THIS DOES NOT DO is model the app's two-pass probe -- the ladder sweep, then a second decode at a
-- rate chosen from sdec.baud_probe. brun.point deliberately mirrors bench_point in tools/bench_uart.py so
-- soak results stay comparable with every bench result on record, and both take one capture at one rate.
-- Modelling the two passes is the larger fidelity fix, in both places at once; this makes the single
-- capture use a rate that can actually see the line.
brun.minfs = brun.minfs or 10000

-- THE EVENT WATCHDOG, and it exists because getting this right by inspection FAILED. A single wrong
-- argument in brun.announce -- tspnet.connect's initString, nil where a string is required -- turned
-- every cell into an event 1138 on the panel, 1677 of them across a lap, on an instrument whose one
-- inviolable rule is that it never puts a message in front of anybody. Nothing detected it; a human
-- watching the front panel did.
--
-- So the loop now watches its OWN event count instead of trusting that every call it makes is quiet.
-- brun.point already clears the log and reads the count back per cell, which is exactly the measurement
-- needed: if cells keep posting events, the optional machinery is switched off in order -- the progress
-- push first, since it is a convenience -- and the reason is written to the key. A run that goes quiet
-- and says why beats a run that is right in principle.
brun.evbudget = brun.evbudget or 3      -- events per cell above which a cell counts as noisy
brun.evstreak = brun.evstreak or 5      -- consecutive noisy cells before shedding a subsystem
brun.nevstreak = 0
brun.evshed = nil                       -- what was switched off, for the record
-- THE RUN TOTAL, reported when the run ends. The per-cell count is what the watchdog acts on; this is
-- the number that answers the only question that matters for an unattended instrument -- did the run put
-- anything in front of anybody -- and it has to be a single figure, not something a reader totals by
-- hand from a thousand rows.
brun.nevtot = 0

-- ---------------------------------------------------------------------------
-- The plan file
-- ---------------------------------------------------------------------------
-- Split one CSV line on commas. No quoting is honoured, deliberately: soakplan.py emits plain numbers
-- and short ids, and a parser that pretends to handle quoting it never receives is a parser whose
-- failure mode nobody has seen.
function brun.split(s)
  local out, n, i0 = {}, 0, 1
  while true do
    local a = string.find(s, ',', i0, true)
    if a == nil then
      n = n + 1; out[n] = string.sub(s, i0)
      break
    end
    n = n + 1; out[n] = string.sub(s, i0, a - 1)
    i0 = a + 1
  end
  return out, n
end

-- THE ROW COUNT COMES OUT OF THE HEADER, so the loop never reads past the end of the file. Reading
-- past EOF posts event 2201 -- 'File read error' -- which is a popup on the panel, once per pass. It is
-- a comment line of the form '# rows=N' written by soakplan.py --emit-csv.
brun.planrows = 0
brun.planread = 0
-- WHICH LAP AND CELL THE RUN IS ON, kept on brun so that every message can name them. A soak is
-- reproducible from its iteration number alone -- every amplitude, offset, wait and vector order is keyed
-- on it -- so a log line without the lap number is a failure nobody can replay. The plan's own
-- random-per-lap setting is captured too, because a lap that played four of the twelve random vectors
-- draws differently from one that played all twelve: the subset is applied as a skip BEFORE the shuffle,
-- which moves every remaining vector's index and therefore its amplitude. Replaying lap 7 needs both
-- numbers, so both go in the record's header.
brun.iter = 0
brun.cell = 0
brun.planrsub = nil

function brun.planopen()
  brun.planclose()
  local fh = nil
  pcall(function() fh = file.open(brun.planpath, file.MODE_READ) end)
  if fh == nil then return false, 'cannot open ' .. brun.planpath end
  brun.pfh = fh
  brun.planread = 0
  return true
end

function brun.planclose()
  if brun.pfh == nil then return end
  pcall(function() file.close(brun.pfh) end)
  brun.pfh = nil
end

-- One cell, or nil at end of file. Header and blank lines are skipped here so callers never see them.
--
-- THE HANDLE IS CLOSED OUTSIDE THE pcall, matching usb_log.tsp's own note: a file.read that raises --
-- the key pulled mid-line -- must not leave the handle open, because the allocator then cannot reuse it.
function brun.nextrow()
  if brun.pfh == nil then return nil end
  -- STOP AT THE DECLARED COUNT rather than at EOF, for the event reason above. A plan with no rows=
  -- header falls back to reading until EOF, which still works and costs one event per pass.
  if brun.planrows > 0 and brun.planread >= brun.planrows then return nil end
  local ln = nil
  local ok = pcall(function() ln = file.read(brun.pfh, file.READ_LINE) end)
  if not ok then brun.planclose(); return nil end
  if ln == nil or ln == '' then return nil end
  ln = string.gsub(ln, '[\r\n]', '')
  if ln == '' then return brun.nextrow() end
  if string.sub(ln, 1, 1) == '#' then
    -- string.find WITH A CAPTURE, because 5.0.2 HAS NO string.match. It returns the two indices first
    -- and the captures after them. This is the same trap as math.fmod: the host Lua has string.match, so
    -- a module using it passes every offline suite and then dies on the instrument -- measured, '-286
    -- attempt to call field `match`' killed an 86-cell run at its first plan line. tools/lint_tsp.py
    -- now refuses both names.
    local _, _, n = string.find(ln, 'rows=(%d+)')
    if n ~= nil then brun.planrows = tonumber(n) end
    -- THE PLAN VARIANT, so the record can say what it was run against. string.find with a capture
    -- again: 5.0.2 has no string.match.
    local _, _, rs = string.find(ln, 'random%-per%-lap=(%a*%d*)')
    if rs ~= nil and rs ~= '' then brun.planrsub = rs end
    return brun.nextrow()
  end
  local f, nf = brun.split(ln)
  -- iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms -- ten fields. A row with fewer is a
  -- truncated or foreign file, and guessing at the missing ones would drive the generator from
  -- whatever happened to be in the next column.
  --
  -- `arb` IS THE GENERATOR'S OWN NAME and is not derived from `vid`. ARWV NAME takes a stored
  -- waveform's name; a local id sent instead does nothing at all and the PREVIOUS waveform keeps
  -- playing, so the cell would be measured against the wrong stimulus and recorded as this one.
  if nf < 10 then return brun.nextrow() end
  if tonumber(f[1]) == nil or tonumber(f[5]) == nil then return brun.nextrow() end
  brun.planread = brun.planread + 1
  return {iter = tonumber(f[1]), cell = tonumber(f[2]), vid = f[3], arb = f[4],
          baud = tonumber(f[5]), kind = f[6], amp = tonumber(f[7]), ofst = tonumber(f[8]),
          srate = tonumber(f[9]), wait = tonumber(f[10])}
end

-- ---------------------------------------------------------------------------
-- One measurement
-- ---------------------------------------------------------------------------
-- MIRRORS bench_point() IN tools/bench_uart.py. Changing one without the other makes this soak
-- incomparable to every bench result on record; test_bench_engine.lua compares them.
function brun.point(fs, baud, lock)
  local r = {ran = false, why = nil}
  pcall(function() eventlog.clear() end)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  if lock then sdec.force_baud = baud end
  -- fs_want, NOT JUST sdec.fs, AND THE DIFFERENCE IS EVERY UNLOCKED CAPTURE IN THIS PROJECT'S
  -- HISTORY. hw_config() consults force_baud: with nothing locked it resets sdec.fs to
  -- sdec.fs_default -- 1 MS/s -- and throws away whatever the caller asked for. serial_core.tsp:1360
  -- documents the same trap being found on the instrument, and fs_want is the one-shot that beats it;
  -- serial_app's own second pass uses it for exactly this reason.
  --
  -- MEASURED, in the soak's own record: 108 of 108 cells captured at 1000000 Sa/s whatever the plan
  -- asked for. At 1 MS/s the 20 000-sample buffer is 20 ms, which is 19 bytes at 9600 baud against 240
  -- at the rate that was requested -- so an unlocked point has been judged on a twelfth of the payload
  -- it should have had, and 'too few trusted bytes to judge' was the harness's own doing.
  sdec.fs, sdec.fs_want = fs, fs
  -- FREE-RUN, NOT EDGE-ARMED, and this is a requirement rather than a preference: the analog-trigger
  -- path goes through trigger.model, which posts 2731 'path initiated' and 2732 'path idled' on EVERY
  -- capture -- two events a cell, 3354 across a lap, on an instrument that must never put anything in
  -- front of an operator. Suppressing them is not enough because localnode.showevents governs the
  -- REMOTE interface only (serial_app.tsp says so where it declines to mute); the events must not be
  -- instigated at all. Measured with trigmode 'free': 8 cells, 0 events, no codes at all.
  --
  -- WHAT IT COSTS, stated because it is a real difference from the host bench: a free-run capture is not
  -- armed on a start-bit edge, so it opens at an arbitrary phase of the arb. For a soak that is closer
  -- to harmless than it sounds -- the plan already draws a per-cell wait precisely to randomise phase,
  -- and the offline twin samples eight phases per cell for the same reason -- but head alignment is not
  -- comparable with an edge-armed bench capture, and a judge must not read it as though it were.
  sdec.trigmode = 'free'

  local ok, why = false, nil
  local okc = pcall(function() ok, why = sdec.acquire() end)
  if not okc then r.why = 'acquire raised'; return r end
  if not ok then r.why = 'acq: ' .. tostring(why); return r end

  local okd, whyd = false, nil
  local okc2 = pcall(function() okd, whyd = sdec.decode() end)
  if not okc2 then r.why = 'decode raised'; return r end
  if not okd then
    r.why = 'dec: ' .. tostring(whyd)
    -- THE RETRACTED RATE IS STILL EVIDENCE. decode_from moves sdec.baud into sdec.baud_probe when it
    -- gives up, and 'no frame fits' with a measured bit time behind it is a different fact from a dead
    -- wire. Recording only the failure would throw that away.
    r.probe = sdec.baud_probe
    r.fs = sdec.acq_fs
    r.nread = sdec.nread
    r.nev = brun.eventcount()
    return r
  end

  local res = sdec.res
  r.ran     = true
  r.fs      = sdec.acq_fs
  r.nread   = sdec.nread
  r.baud    = sdec.baud
  r.snapped = sdec.snapped
  r.snapfirm = sdec.snapfirm
  r.nf      = (res ~= nil and res.nf) or 0
  r.ngood   = (res ~= nil and res.ngood) or 0
  r.nbad    = (res ~= nil and res.nbad) or 0
  r.headsusp = (res ~= nil and res.headsusp) or 0
  r.fmt     = brun.fmtname(res)
  r.nev     = brun.eventcount()
  r.hex     = brun.hex(res)
  r.nflag   = brun.flagcount(res)
  return r
end

-- EVENTS ARE A RESULT, not diagnostics. The app's hardest rule is that it must never put a message in
-- front of the operator, and a count of what it filed is the only way a soak can police that.
function brun.eventcount()
  local n = 0
  pcall(function() n = eventlog.getcount() or 0 end)
  return n
end

function brun.fmtname(res)
  if res == nil or res.nbits == nil then return '' end
  local p = 'N'
  if res.par == sdec.PAR_EVEN then p = 'E' elseif res.par == sdec.PAR_ODD then p = 'O' end
  return string.format('%d%s%d', res.nbits, p, res.nstop or 1)
end

function brun.flagcount(res)
  if res == nil or res.errs == nil then return 0 end
  local n, k = 0, nil
  for k = 1, (res.nf or 0) do
    if res.errs[k] ~= nil then n = n + 1 end
  end
  return n
end

-- '??' FOR A FLAGGED FRAME, and this is not cosmetic. bench_uart.py emits the same, with the reason:
-- a frame with an error still has a value, so printing that value lets a byte pass the host's substring
-- check only because the error was ignored. Writing plain hex here would silently weaken the judge --
-- which is a bug this project has already had, and fixed, in the offline twin.
function brun.hex(res)
  if res == nil or (res.nf or 0) < 1 then return '' end
  local s, k, n = {}, nil, 0
  for k = 1, res.nf do
    n = n + 1
    if res.errs[k] == nil then
      s[n] = string.format('%02X', res.vals[k] or 0)
    else
      s[n] = '??'
    end
  end
  return table.concat(s, '')
end

-- ---------------------------------------------------------------------------
-- What the front panel says
-- ---------------------------------------------------------------------------
-- SO SOMEONE WALKING PAST CAN SEE IT IS ALIVE, and how it is doing. A soak that runs headless leaves
-- the panel showing whatever was there before, which is indistinguishable from a wedged instrument --
-- and the announce push only helps someone with a listener running. Two lines, six facts:
--
--     L3#412 F12 0.7%              lap, cell, failed cells, fail rate
--     v77 9600 8N1 Fox             vector, baud, frame format, waveform
--
-- display.settext ON THE USER SWIPE SCREEN, NOT display.create. Object ids are never reclaimed on this
-- instrument, so creating a text object per cell would exhaust them; settext writes into the two lines
-- the firmware already owns, so a lap costs no objects at all. serial_app.tsp uses the same call for
-- its own progress row, at about the same rate.
--
-- THE LENGTH LIMITS ARE A POPUP, NOT A CLIP, and that is the whole reason these lines are built by
-- measurement rather than by eye. The reference manual is explicit: TEXT1 holds up to 20 characters and
-- TEXT2 up to 32, and "if you enter too many characters, the instrument displays a warning event and
-- shortens the message to fit". A warning event is a box on the panel of an instrument that must never
-- put one in front of anybody -- so an over-long line is not cosmetic, it is the failure. The first
-- version of this line was 'SOAK 1  cell 412/1677', which is 21 characters: one over, once per cell,
-- for eight days. tools/mock_display.lua now enforces both limits so the offline suite says so, and
-- test_bench_engine.lua asserts the widest possible line of each kind still fits.
--
-- AND THE PANEL CANNOT HIDE ITS OWN EVENTS. brun.point clears the log at the top of every cell, so
-- anything this posts is wiped before the run's own event count is read -- the watchdog would never see
-- it. So the count is taken around the two writes here and added to the run total directly.
brun.panellim1 = 20      -- TEXT1, characters. Firmware limit, not a style choice.
brun.panellim2 = 32      -- TEXT2
-- AND THE CUSTOM SCREEN'S OWN BUDGET, in characters at FONT_MEDIUM: ~13.4 px an advance into about 780
-- usable px. Nothing enforces this -- the firmware just draws past the edge and the far end of the line
-- is gone -- so it is a number every line here is written against and a test checks each of them at its
-- widest. The first version of the alarm lines were 66 to 90 characters, which clipped away the half
-- that said what to DO: 'GENERATOR SILENT for 5 cell(s) -- nothing is on the wire. Power cycle the SDG
-- and restart.' rendered as far as 'nothing is on the'.
brun.panelw = 58

-- THE BACKLIGHT, DIMMED FOR THE DURATION OF A RUN. An unattended soak leaves one screen lit for days,
-- and this panel's backlight has a finite life it does not need to spend on a room with nobody in it.
--
-- 25 %, BECAUSE THE FIRMWARE HAS NO 30. display.lightstate takes STATE_LCD_100, _75, _50, _25, _OFF or
-- BLACKOUT and nothing between them, so a request for 30 % lands on 25. Not restored at the end: a run
-- that finishes at four in the morning should not turn the lights back up.
--
-- nil IF THE CONSTANT IS NOT THERE. The offline mock need not carry every display constant, and a nil
-- assigned to lightstate would be an event on the panel rather than a dim screen.
brun.backlight = brun.backlight or display.STATE_LCD_25
brun.nevpanel = 0

-- CLIPPED HERE RATHER THAN BY THE FIRMWARE, because the firmware charges an event for the service.
-- Every caller below is width-checked by a test, so reaching this is already a bug; it exists so that
-- the bug is a shortened line instead of a message on the screen.
function brun.fit(s, lim)
  local t = tostring(s or '')
  if string.len(t) <= lim then return t end
  return string.sub(t, 1, lim)
end

function brun.settext(l1, l2)
  local n0 = brun.eventcount()
  pcall(function()
    display.settext(display.TEXT1, brun.fit(l1, brun.panellim1))
    display.settext(display.TEXT2, brun.fit(l2, brun.panellim2))
  end)
  local d = brun.eventcount() - n0
  if d > 0 then
    brun.nevpanel = brun.nevpanel + d
    brun.nevtot = brun.nevtot + d
  end
end

-- THE FRAME FORMAT OF THE STIMULUS, read out of the generator's own name for the waveform -- which is
-- where this project records it and the only place it exists: vector_names.py carries no format column,
-- and docs/VECTORS.md says the name is what distinguishes v44e (8N2) from v41 (8N1). It is the STIMULUS
-- format, not what the decoder read: the panel says what is being played, and whether the app agreed is
-- a question for the record. Six vectors have no format token in their name -- the three LIN frames and
-- the three jitter waveforms -- and they get an empty string rather than a guess.
function brun.fmtof(arb)
  if arb == nil then return '' end
  local _, _, f = string.find(arb, '_(%d[NEO]%d)_')
  if f == nil then return '' end
  return f
end

-- THE WAVEFORM, MINUS THE BOILERPLATE EVERY NAME CARRIES. All 41 begin 'SER_' and end '_x10' or
-- '_x100', so those characters distinguish nothing on a 32-character line; the format token is dropped
-- too because it is printed as its own field beside it. 'SER_Hello_8N1_Drift10_x10' -> 'Hello_Drift10',
-- which is 13 characters instead of 25 and is what makes the whole line fit at 153600 baud.
function brun.wave(arb)
  if arb == nil or arb == '' then return '?' end
  local s = string.gsub(arb, '^SER_', '')
  s = string.gsub(s, '_x%d+$', '')
  local f = brun.fmtof(arb)
  if f ~= '' then
    s = string.gsub(s, '_' .. f .. '_', '_')
    s = string.gsub(s, '_' .. f .. '$', '')
  end
  return s
end

-- FAILED CELLS AS A PERCENTAGE OF CELLS RUN. One decimal below 10 % and none above, so the field is
-- never wider than four characters -- '0.0%' through '9.9%', then '10%' to '100%'.
--
-- %.0f AND NOT %d, because the offline twin runs on a modern Lua where string.format('%d', 12.5) is an
-- error rather than a truncation. This is the mirror image of the math.mod trap: a construct the
-- instrument accepts and the host refuses.
function brun.pct(nbad, ncell)
  local n = ncell or 0
  if n < 1 then return '0%' end
  local p = 100.0 * (nbad or 0) / n
  if p >= 9.95 then return string.format('%.0f%%', p) end
  return string.format('%.1f%%', p)
end

-- WHAT COUNTS AS A FAILURE HERE: a cell that produced no decode -- no stimulus, a refused acquire, or
-- 'no frame fits'. It is deliberately NOT a byte-level verdict: whether the bytes were right is decided
-- by tools/judge_bench.py against the oracle, off the key, and 0.0 % on this screen does not mean every
-- byte was correct. It means every cell came back with something.
function brun.screen(c, arb)
  if brun.ui ~= nil then brun.ui_show(c, arb) end
  brun.settext(string.format('L%sC%s F%s %s',
                             brun.int(c.iter), brun.int(c.cell), brun.int(brun.nbad),
                             brun.pct(brun.nbad, brun.ncell)),
               brun.cellline(c, arb))
end

-- ---------------------------------------------------------------------------
-- The status screen
-- ---------------------------------------------------------------------------
-- WHY A SCREEN OF ITS OWN, when the USER swipe screen already carries two lines. Because those lines
-- hold 20 and 32 characters and the questions an unattended run has to answer do not fit in 52: which
-- lap of how many, how far through it, how long it has run and how much longer, what is playing, how
-- many cells have failed both overall and for THIS vector, and -- the one no character count can carry --
-- whether what has gone wrong is worth walking over to fix. display.create takes a FONT, so a screen
-- built here gets FONT_SMALL's 8 px advance and about ninety characters a line, and it gets COLOUR.
--
-- SIX OBJECTS, CREATED ONCE. Display object ids are never reclaimed on this firmware -- display.create
-- returns nil when the pool is exhausted, posts event 1701 the first time only, and is silent after
-- that -- so a text object per cell would walk the instrument into that state inside one lap. These are
-- built at the start of a run and only ever settext'd and setcolor'd afterwards, which costs nothing.
-- serial_ui.tsp's ui_build makes the same trade for the same reason and its comment explains the panic
-- this avoids.
--
-- AND THE SWIPE LINES ARE STILL WRITTEN. If the pool is exhausted, or display.create is not there at
-- all, brun.settext is the fallback and the run still says where it is. A status display is not worth
-- risking a run over.
brun.c_lab  = (sdec ~= nil and sdec.ui_c_lab) or 0xA8A8A8       -- grey: labels
brun.c_val  = (sdec ~= nil and sdec.ui_c_data) or 0xFFFFFF      -- white: values
-- THE PANEL'S OWN BLUE FOR 'NOTHING TO SEE HERE', which is what the rest of this instrument's
-- chrome uses for a live value (serial_ui.tsp's BAUD and FORMAT cells are the same constant).
-- Green would be a third signal competing with amber and red; the point of the colour here is
-- that ONLY a colour change means anything.
brun.c_ok   = (sdec ~= nil and sdec.ui_c_sb_on) or 0x00DCFF     -- the panel blue
brun.c_warn = (sdec ~= nil and sdec.ui_c_warn) or 0xFFC000      -- amber
brun.c_bad  = (sdec ~= nil and sdec.ui_c_err) or 0xFF6060       -- red
-- GREEN IS RESERVED FOR THE HEALTH HEADLINE, and only above brun.healthwarn. Nothing else on this screen
-- uses it, so green means one thing: the share of cells behaving as expected is better than a good lap
-- manages. The blue above stays the colour of 'running, nothing to report'.
brun.c_good = (sdec ~= nil and sdec.ui_c_locked) or 0x40FF40    -- green
brun.ui = nil

-- A ROLLING LOG OF THINGS WORTH KNOWING, under the prompt rather than over it. The status line used to
-- do both jobs and they conflict: an alarm replaced 'press TRIGGER to stop', so the moment something went
-- wrong the screen stopped saying how to act on it. Now the prompt is permanent and anything notable
-- scrolls beneath it, newest at the bottom, each line stamped with the time and the cell number.
--
-- ONLY STATE CHANGES ARE PUSHED, not one line per cell. A log that repeats 'generator missed 1 cell' for
-- four hundred cells has thrown away the one thing a log is for -- knowing WHEN something started.
brun.msgn = brun.msgn or 5
brun.msgs = nil          -- oldest first; the newest is at the bottom of the screen
brun.lastmsg = nil       -- so an unchanged state is not pushed again
brun.lastshape = nil     -- the same state with a different count in it, ditto
brun.lastn = 0

-- ONE CONDITION MUST NOT FILL THE RING. Dedup on exact text lets a counter push a new line every time it
-- increments: measured on hardware at 4 generator misses in 1578 cells, a fortnight's 273 000 cells is
-- ~650 of them, and five lines of 'generator missed 648 cell(s)' is a log with every one-off event --
-- a hold, a recording gap, a plan wrap -- scrolled off the top.
--
-- SO THE DIGITS COME OUT and the message is compared by SHAPE. A repeat is pushed again only when its
-- number has DOUBLED, which gives 1, 2, 4, 8 ... about ten lines over a fortnight: the early detail that
-- says when something started, and no more. Every occurrence is on the key regardless.
function brun.shape(s)
  return string.gsub(tostring(s or ''), '%d', '')
end

function brun.firstn(s)
  local _, _, d = string.find(tostring(s or ''), '(%d+)')
  if d == nil then return 0 end
  return tonumber(d) or 0
end

-- -> true if this message says something the log is not already showing.
function brun.newsworthy(msg)
  if msg == brun.lastmsg then return false end
  local sh, n = brun.shape(msg), brun.firstn(msg)
  if sh ~= brun.lastshape then
    brun.lastshape, brun.lastn = sh, n
    return true
  end
  if n >= brun.lastn * 2 then
    brun.lastn = n
    return true
  end
  return false
end

-- WHEN, AS WALL CLOCK IF THE FIRMWARE HAS IT AND ELAPSED TIME IF IT DOES NOT. After six days away
-- '03:14' answers a question that '2:41 into the run' does not, so os.date is tried first -- guarded,
-- because bench_rec.tsp's note says os.time() is the only clock this instrument agrees with itself about
-- and does not claim os.date exists at all. A nil field raises, pcall catches it, and nothing is posted.
function brun.stamp()
  local t = nil
  pcall(function() t = os.date('%H:%M') end)
  if type(t) == 'string' and string.len(t) >= 4 then return t end
  local el = 0
  if brun.t0 ~= nil then pcall(function() el = os.time() - brun.t0 end) end
  return string.format('%d:%02d', math.floor(el / 3600), math.floor(math.mod(el, 3600) / 60))
end

-- NEWEST AT THE BOTTOM, so the log reads the way a log reads and the eye follows it downward. The array
-- is oldest-first and the head is dropped when it is full.
--
-- THE CELL NUMBER AS WELL AS THE TIME, because 'the generator missed a cell' matters much less than which
-- one, and this screen is the only place a reader sees it before the key is fetched.
function brun.msg(col, txt)
  if brun.msgs == nil then brun.msgs = {} end
  local n = table.getn(brun.msgs)
  if n >= brun.msgn then
    local k
    for k = 1, brun.msgn - 1 do brun.msgs[k] = brun.msgs[k + 1] end
    brun.msgs[brun.msgn] = nil
    n = brun.msgn - 1
  end
  brun.msgs[n + 1] = {txt = brun.stamp() .. ' L' .. brun.int(brun.iter) .. 'C' .. brun.int(brun.cell)
                            .. ' ' .. tostring(txt),
                      col = col or brun.c_lab}
  brun.ui_msgs()
end

function brun.ui_msgs()
  local u = brun.ui
  if u == nil or u.msg == nil then return end
  local k
  for k = 1, brun.msgn do
    local m = (brun.msgs ~= nil and brun.msgs[k]) or nil
    if m == nil then
      brun.ui_set(u.msg[k], '', brun.c_lab)
    else
      brun.ui_set(u.msg[k], brun.fit(m.txt, brun.panelw), m.col)
    end
  end
end

-- HOW BAD IS BAD ENOUGH TO GO RED. The colour is a claim about whether someone should intervene, so
-- these are the thresholds that claim is made on, named rather than buried in the comparison.
-- THE RATE THESE APPLY TO IS THE UNEXPECTED ONE, not every refusal, and the difference is most of the
-- number: about a third of a healthy lap produces no result because the plan asks seven vectors to
-- decode signals where refusing is correct. Judging the raw rate showed 20 % on a working instrument and
-- called it amber, which is crying wolf on the one screen that must not.
--
-- WHERE THE NUMBERS COME FROM, so the next person can move them with evidence rather than taste. Two
-- measurements exist: one full lap through the offline twin gave 23 % unexpected (the offline model is
-- the pessimistic one -- issue #46 is most of it), and 41 hardware cells gave 10 %. So amber sits above
-- the hardware figure and red well above the offline one; anything under 20 % is within what both have
-- already produced while working. THESE ARE PROVISIONAL: the first complete hardware lap is what should
-- set them, and until one exists they are deliberately loose rather than falsely precise.
brun.warnrate = brun.warnrate or 20      -- % of cells refusing UNEXPECTEDLY: amber above this
brun.badrate  = brun.badrate  or 40      -- and red above this
brun.raten    = brun.raten    or 100     -- but neither before this many cells have run, and the
                                         -- health headline shows no figure at all until then
brun.badsdgwarn = brun.badsdgwarn or 3   -- consecutive generator failures that mean the stimulus is gone

function brun.ui_destroy()
  if brun.ui == nil then return end
  local u, k = brun.ui, nil
  -- IN REVERSE CREATION ORDER, children before the screen, and each handle visited EXACTLY ONCE.
  -- sdec.del_obj is not idempotent: a second delete of the same handle is refused, and a refused handle
  -- goes on sdec.orphans, where it looks like a leaked object and blocks the next rebuild.
  for k = u.n, 1, -1 do
    if sdec ~= nil and sdec.del_obj ~= nil then
      pcall(function() sdec.del_obj(u.all[k]) end)
    else
      pcall(function() display.delete(u.all[k]) end)
    end
    u.all[k] = nil
  end
  brun.ui = nil
end

function brun.ui_build()
  brun.ui_destroy()
  if display == nil or display.create == nil then return false end
  local u = {all = {}, n = 0}
  local ok = pcall(function()
    -- FONT_MEDIUM, not SMALL. FONT_SMALL advances 8 px and MEDIUM about 13.4 (both measured, see
    -- serial_ui.tsp's note on the panel grid), so a 780 px line holds ~97 characters small and ~58
    -- medium. Every line below is written to fit the 58, which is why the waveform's short form was
    -- dropped from the stimulus line -- the generator's full name is there and says the same thing.
    local create, small, left = display.create, display.FONT_MEDIUM, display.JUST_LEFT
    local function add(h)
      -- display.create RETURNS NIL ON AN EXHAUSTED POOL, silently after the first time. A nil parent
      -- then makes every child nil too and the whole screen is inert with nothing said, so it is caught
      -- at the first one.
      if h == nil then error('display object pool exhausted', 0) end
      u.n = u.n + 1
      u.all[u.n] = h
      return h
    end
    u.scr  = add(create(display.ROOT, display.OBJ_SCREEN, 'SERIAL DECODE SOAK'))
    -- THE HEADLINE FIRST, because it is the one line that answers the question from across the room.
    -- FONT_MEDIUM is the largest this firmware has -- the reference lists FONT_SMALL and FONT_MEDIUM and
    -- nothing else -- so it is emphasised by position and colour rather than by size.
    u.health = add(create(u.scr, display.OBJ_TEXT, 12, 20, 'SOAK HEALTH --', brun.c_ok, small, left))
    u.prog = add(create(u.scr, display.OBJ_TEXT, 12, 58, '--', brun.c_val, small, left))
    u.time = add(create(u.scr, display.OBJ_TEXT, 12, 92, '--', brun.c_lab, small, left))
    u.stim = add(create(u.scr, display.OBJ_TEXT, 12, 126, '--', brun.c_val, small, left))
    u.fail = add(create(u.scr, display.OBJ_TEXT, 12, 160, '--', brun.c_lab, small, left))
    u.vfail = add(create(u.scr, display.OBJ_TEXT, 12, 194, '--', brun.c_lab, small, left))
    -- THE PROMPT, WHICH NEVER CHANGES WHILE THE RUN LASTS. It is the only instruction on the screen and
    -- an alarm must not be able to take its place.
    u.note = add(create(u.scr, display.OBJ_TEXT, 12, 228, 'starting', brun.c_ok, small, left))
    -- AND THE LOG BENEATH IT. Five lines at a 34 px pitch ends at y=396, inside the 420 the firmware
    -- allows and the 431 px content area -- checked, because display.create returns nil rather than
    -- raising for a y it will not take, and a nil parent makes every later object nil in silence.
    u.msg = {}
    local mk
    for mk = 1, brun.msgn do
      u.msg[mk] = add(create(u.scr, display.OBJ_TEXT, 12, 262 + (mk - 1) * 34, '',
                             brun.c_lab, small, left))
    end
  end)
  if not ok then
    brun.ui = u                    -- so ui_destroy frees whatever did get created
    brun.ui_destroy()
    return false
  end
  brun.ui = u
  pcall(function() display.changescreen(u.scr) end)
  return true
end

function brun.ui_set(h, txt, col)
  if h == nil then return end
  pcall(function() display.settext(h, txt) end)
  if col ~= nil then pcall(function() display.setcolor(h, col) end) end
end

-- HOURS, NOT SECONDS, and '--' where it cannot be known. An indefinite run has no end to count down to,
-- and a run that has finished no cells has no rate to extrapolate from -- printing 0.0 there would be a
-- number standing in for an unknown, which is the kind of screen that gets believed.
function brun.hours(sec)
  if sec == nil or sec < 0 then return '--' end
  return string.format('%.1f h', sec / 3600.0)
end

-- THE ONE INSTRUCTION, ON ITS OWN LINE, FOR THE WHOLE RUN. Not a status: a control the operator cannot
-- guess at, since it is the physical TRIGGER key and not anything on the glass.
function brun.prompt()
  if brun.stopwhy ~= nil then return 'ended -- ' .. brun.fit(tostring(brun.stopwhy), 40) end
  if brun.keyarmed then return 'Running -- press TRIGGER to stop and flush' end
  return 'Running'
end

-- THE TRAFFIC LIGHT. It answers one question -- is this worth walking over for -- so every red is
-- something a person has to do something about, and everything self-correcting is amber at worst.
--
-- RED: the run has parked, the generator has stopped answering for several cells in a row (its waveform
-- is not on the wire, so every cell after this measures nothing), the record is no longer being written,
-- something put an event in the log (which on this instrument means a box on the panel), or the no-decode
-- rate has gone past brun.badrate over enough cells to mean it.
-- AMBER: a generator hiccup that recovered, a rate above brun.warnrate, the progress push switched off.
function brun.ui_status()
  if brun.stopwhy ~= nil then
    -- A RUN THAT FINISHED WHAT IT WAS ASKED TO DO IS NOT RED. Red is a request for someone to come and
    -- fix something, so 'iterations complete' and 'STOP.TXT found' end blue while a parked generator or a
    -- dead record end red. brun.stopbad is set at the break, where the reason is known, rather than
    -- inferred here by matching on the text of a message.
    -- THE REASON IS CLIPPED TO THE GLASS, and it is the only line here that has to be: a stop reason
    -- can be as long as the generator's own error text. The full text is on the key, in the last S row.
    if brun.stopbad then
      return brun.c_bad, brun.fit('STOPPED: ' .. tostring(brun.stopwhy), brun.panelw)
    end
    return brun.c_ok, brun.fit('finished: ' .. tostring(brun.stopwhy), brun.panelw)
  end
  if brec ~= nil and brec.stopped then
    return brun.c_bad, brun.fit('NOT RECORDING: ' .. tostring(brec.why), brun.panelw)
  end
  if brun.nbadsdg >= brun.badsdgwarn then
    return brun.c_bad, string.format('GENERATOR SILENT %d cells -- power cycle the SDG',
                                     brun.nbadsdg)
  end
  if brun.nevtot > 0 then
    return brun.c_bad, string.format('%d EVENTS POSTED -- a message reached the panel',
                                     brun.nevtot)
  end
  local rate = 0
  if brun.ncell > 0 then rate = 100.0 * brun.nunexp / brun.ncell end
  if brun.ncell >= brun.raten and rate > brun.badrate then
    return brun.c_bad, string.format('%.0f %% refused unexpectedly -- check wiring, restart', rate)
  end
  if brun.ncell >= brun.raten and rate > brun.warnrate then
    return brun.c_warn, string.format('%.0f %% refused unexpectedly -- worth watching', rate)
  end
  -- A GAP THAT HEALED IS STILL A GAP, and outranks a generator hiccup: those cells are gone, not merely
  -- unmeasured. Amber rather than red -- it needs no restart -- but it stays up for the rest of the run.
  if (brun.nreclost or 0) > 0 then
    return brun.c_warn, string.format('%d cell(s) were never recorded -- gap in the file',
                                      brun.nreclost)
  end
  if brun.nsdgtot > 0 then
    return brun.c_warn, string.format('generator missed %d cell(s) and recovered', brun.nsdgtot)
  end
  if brun.evshed ~= nil then
    return brun.c_warn, brun.fit('the ' .. tostring(brun.evshed) .. ' was switched off',
                                 brun.panelw)
  end
  -- AND THE ONE INSTRUCTION THE OPERATOR NEEDS. A stop control nobody knows about is not a stop control,
  -- and this one is not where anybody would look: it is the TRIGGER key, not a button on the screen,
  -- because a touch press cannot be read while a script runs.
  if brun.keyarmed then
    return brun.c_ok, 'Running -- press TRIGGER to stop and flush'
  end
  return brun.c_ok, 'running'
end

-- THE LAST THING THE SCREEN SAYS, and it has to keep saying it for days. The cell lines are left showing
-- whatever ran last; the two that change are the totals and the verdict, because after six days away the
-- questions are 'did it finish' and 'is anything wrong', in that order.
function brun.ui_end()
  local u = brun.ui
  if u == nil then return end
  local el = nil
  if brun.t0 ~= nil then el = os.time() - brun.t0 end
  brun.ui_set(u.time, 'ran ' .. brun.hours(el) .. '    ended    '
                      .. brun.int(brun.ncell) .. ' cell(s) done', brun.c_lab)
  -- THE BENIGN COUNT FIRST, AND ONLY ONE PERCENTAGE ON THE SCREEN. Leading with 'no result 82 of 412 =
  -- 20 %' reads as a fifth of the run being broken, and it is not: most of those cells refused because
  -- the plan asked them to decode something a correct decoder declines. Health above is the one figure
  -- meant to be read as a verdict, so these two lines are counts -- what was allowed, what was not, out
  -- of how many -- rather than a second, scarier percentage competing with it.
  brun.ui_set(u.fail, string.format('allowed refusals %s    UNEXPECTED %s    of %s cells',
                                    brun.int(brun.nexp), brun.int(brun.nunexp),
                                    brun.int(brun.ncell)), brun.c_lab)
  brun.ui_set(u.vfail, string.format('generator missed %s cell(s)', brun.int(brun.nsdgtot)),
              brun.c_lab)
  local hl, hcol = brun.healthline()
  brun.ui_set(u.health, hl, hcol)
  brun.ui_set(u.note, brun.prompt(), brun.c_ok)
  -- ANYTHING WORTH SAYING GOES TO THE LOG, ONCE. The prompt above keeps saying how to stop the run,
  -- which is what it is for; an alarm that replaced it left the operator looking at a warning with no
  -- instruction under it.
  local col, msg = brun.ui_status()
  if col ~= brun.c_ok and brun.newsworthy(msg) then
    brun.lastmsg = msg
    brun.msg(col, msg)
  end
end

-- ONE NUMBER FOR THE WHOLE RUN: the share of cells that behaved as they were supposed to. A cell counts
-- as healthy if it decoded, OR if it refused on one of the vectors the plan allows to refuse. So 100 %
-- means nothing unexpected has happened yet, and every point below it is a cell that came back empty when
-- it should not have -- or a cell the generator never played at all.
--
-- WHAT IT DOES NOT MEAN, and this matters because a single percentage invites more trust than it has
-- earned: it is not a claim that the BYTES were right. Nothing on the instrument judges bytes -- that is
-- tools/judge_bench.py's job against the oracle, and doing it here would be a second judge, which is the
-- failure this project keeps writing comments about. 100 % health means every cell produced the KIND of
-- result it should have. Whether it produced the right one is decided off the key.
function brun.health()
  if brun.ncell == nil or brun.ncell < 1 then return 100.0 end
  return 100.0 * (brun.ncell - brun.nunexp) / brun.ncell
end

-- THE TWO HEALTH BANDS, AND WHY THEY ARE NOT 100 AND 0. A healthy lap of this plan does not reach 100 %:
-- some cells refuse for reasons the per-vector allowance is too coarse to name, so a light that turns
-- amber at 99.9 % is amber for the whole week and stops carrying information.
--
-- So green above 99 means 'no worse than a good lap', amber below it means 'worse than one', and red
-- below 60 means the run is not measuring anything much. The number is on the screen either way; the
-- colour is only there to say whether the number is worth walking over for.
--
-- 99 IS MEASURED, ON HARDWARE, AFTER THE fs_want FIX, and it replaces an 85 that was measured before it.
-- The old figure came from laps reading 89.8 % to 92.2 % -- every one of which was capturing 20 ms at
-- 1 MS/s whatever rate it had asked for, so most of those refusals were the harness starving the decoder
-- rather than the decoder failing. A lap driven at the requested rate reads 1 unexpected cell in 586 and
-- 2 in the high hundreds: about 0.3 %, or 99.7 % health. So the trip sits at 1 % unexpected -- roughly
-- three times the rate a working lap produces, which is far enough out to not flicker and close enough in
-- to catch a real doubling. THIS NUMBER IS EMPIRICAL: move it with evidence from a complete lap, and note
-- that a threshold set from a starved lap is what made the last one wrong by fourteen points.
brun.healthwarn = brun.healthwarn or 99
brun.healthbad = brun.healthbad or 60

function brun.healthline()
  -- THE DETAIL LINE'S COLOUR IS READ FIRST, because the headline may never look better than it: a silent
  -- generator or an event on the panel is red down there, and a health figure above it must not disagree.
  local ncol = brun.ui_status()

  -- NO FIGURE AT ALL UNTIL THERE ARE ENOUGH CELLS TO DIVIDE BY. One unexpected refusal on cell 1 is
  -- 0.0 % health, which paints the headline red on a perfectly good instrument in the first ten seconds
  -- of a two-hour lap -- and a screen that starts by crying wolf is a screen nobody reads by Wednesday.
  -- The same brun.raten that gates the rate alarm gates this, so the two agree about when a proportion
  -- starts meaning something.
  --
  -- A HARD FAULT IS STILL RED IMMEDIATELY. This suppresses the ARITHMETIC, not the alarms: a generator
  -- that has gone quiet by cell 3 has nothing to do with sample size and says so at once.
  if brun.ncell == nil or brun.ncell < brun.raten then
    local col0 = brun.c_ok
    if ncol == brun.c_bad then col0 = brun.c_bad end
    return string.format('SOAK HEALTH -- %s of %s cells so far',
                         brun.int(brun.ncell), brun.int(brun.raten)), col0
  end

  local h = brun.health()
  local col = brun.c_good
  if h <= brun.healthwarn then col = brun.c_warn end
  if h < brun.healthbad then col = brun.c_bad end
  if ncol == brun.c_bad then col = brun.c_bad end
  return string.format('SOAK HEALTH %.1f %%', h), col
end

function brun.ui_show(c, arb)
  local u = brun.ui
  if u == nil then return end
  local vid = tostring(c.vid or '?')
  local nlap = brun.planrows
  local lap = 'lap ' .. brun.int(c.iter)
  if brun.iterwant ~= nil and brun.iterwant > 0 then
    lap = lap .. ' of ' .. brun.int(brun.iterwant)
  end
  local cell = 'cell ' .. brun.int(c.cell)
  if nlap > 0 then
    cell = cell .. ' of ' .. brun.int(nlap) .. string.format('  (%.0f %% of the lap)',
                                                             100.0 * (c.cell or 0) / nlap)
  end
  brun.ui_set(u.prog, lap .. '    ' .. cell, brun.c_val)

  -- TIME REMAINING IS EXTRAPOLATED FROM THIS RUN'S OWN CELL RATE, not from a nominal seconds-per-cell:
  -- a cell is a capture plus a plan wait plus however long the generator took, and those vary by rate.
  local el, left = nil, '--'
  if brun.t0 ~= nil then el = os.time() - brun.t0 end
  local ntot = 0
  if brun.iterwant ~= nil and brun.iterwant > 0 and nlap > 0 then ntot = brun.iterwant * nlap end
  if el ~= nil and el > 0 and brun.ncell > 0 and ntot > brun.ncell then
    left = brun.hours(el * (ntot - brun.ncell) / brun.ncell)
  end
  brun.ui_set(u.time, 'ran ' .. brun.hours(el) .. '    left ' .. left
                      .. '    ' .. brun.int(brun.ncell) .. ' cell(s) done', brun.c_lab)

  brun.ui_set(u.stim, vid .. '  ' .. brun.int(c.baud) .. ' Bd  ' .. brun.fmtof(arb)
                      .. '  ' .. tostring(arb or '?'), brun.c_val)

  -- BOTH RATES, because they answer different questions: the run's rate says whether the soak is
  -- healthy, and this vector's says whether ONE waveform is the reason it is not.
  local vn, vb = brun.vcell[vid] or 0, brun.vbad[vid] or 0
  -- EVERY PERCENTAGE SAYS WHAT IT IS A PERCENTAGE OF, and the split is the whole point of this line.
  -- A bare '20 %' reads as a fifth of the run being broken; it is not. About a third of a HEALTHY lap
  -- produces no result, because the plan drives seven vectors into conditions where refusing is the
  -- documented right answer -- and judge_bench.py scores those refusals as passes. Measured on the
  -- offline twin over one full lap: 539 of 1677 cells with no result, 151 of them exactly that.
  --
  -- So the number that means something is UNEXPECTED: a refusal on a vector that should have decoded.
  -- THE BENIGN COUNT FIRST, AND ONLY ONE PERCENTAGE ON THE SCREEN. Leading with 'no result 82 of 412 =
  -- 20 %' reads as a fifth of the run being broken, and it is not: most of those cells refused because
  -- the plan asked them to decode something a correct decoder declines. Health above is the one figure
  -- meant to be read as a verdict, so these two lines are counts -- what was allowed, what was not, out
  -- of how many -- rather than a second, scarier percentage competing with it.
  --
  -- 58 CHARACTERS IS THE BUDGET AT FONT_MEDIUM, and both are written against their own widest values --
  -- four-digit counts -- rather than the ones a screenshot happens to show.
  brun.ui_set(u.fail, string.format('allowed refusals %s    UNEXPECTED %s    of %s cells',
                                    brun.int(brun.nexp), brun.int(brun.nunexp),
                                    brun.int(brun.ncell)), brun.c_lab)
  brun.ui_set(u.vfail, string.format('this vector %s: %d of %d refused', vid, vb, vn), brun.c_lab)
  local hl, hcol = brun.healthline()
  brun.ui_set(u.health, hl, hcol)
  brun.ui_set(u.note, brun.prompt(), brun.c_ok)
  -- ANYTHING WORTH SAYING GOES TO THE LOG, ONCE. The prompt above keeps saying how to stop the run,
  -- which is what it is for; an alarm that replaced it left the operator looking at a warning with no
  -- instruction under it.
  local col, msg = brun.ui_status()
  if col ~= brun.c_ok and brun.newsworthy(msg) then
    brun.lastmsg = msg
    brun.msg(col, msg)
  end
end

function brun.cellline(c, arb)
  local s = tostring(c.vid or '?') .. ' ' .. brun.int(c.baud)
  local f = brun.fmtof(arb)
  if f ~= '' then s = s .. ' ' .. f end
  return s .. ' ' .. brun.wave(arb)
end

-- %.0f for the same reason as brun.pct, and tostring() would print 9600 as '9600' but a rate that
-- arrived as a float as '9600.0000001'.
function brun.int(n)
  if n == nil then return '0' end
  return string.format('%.0f', n)
end

-- ---------------------------------------------------------------------------
-- Live progress, when someone is listening
-- ---------------------------------------------------------------------------
-- PUSHED, NOT POLLED, and that is forced rather than chosen: while a TSP script runs it holds the
-- interpreter, so the LAN command interface cannot answer a query about the run's progress. So the run
-- announces itself instead -- one short line per cell to a listener on the host -- wrapped so that the
-- listener being absent costs a failed connect and nothing else. That is the whole mechanism behind
-- "monitorable when connected, self-completing when not".
-- THE EMPTY initString AGAIN, and it has to be here too. bsdg.open carries the same note: this
-- interpreter returns nil from tspnet.connect(ip, port) and from tspnet.connect(ip, port, nil), and only
-- a STRING third argument works. Passing nil here made every announce fail into tspnet.write(nil, ...),
-- which posts event 1138 -- 'Parameter 1, expected type number' -- once per cell. Measured: 1677 events
-- across a lap, on an instrument that must never put a message in front of anybody.
--
-- AND A FAILURE IS COUNTED, NOT JUST SWALLOWED. A pcall that hides everything cannot be distinguished
-- from a listener that is simply absent, which is exactly how the above went unnoticed: after
-- brun.maxannfail consecutive failures the announcing stops for the rest of the run, so a broken push
-- costs a bounded number of events instead of one per cell for eight days.
brun.nannfail = 0
brun.maxannfail = brun.maxannfail or 5

function brun.announce(s)
  if brun.listenip == nil then return end
  if brun.nannfail >= brun.maxannfail then return end
  local sent = false
  pcall(function()
    local id = tspnet.connect(brun.listenip, brun.listenport, '')
    if id ~= nil then
      tspnet.write(id, s .. '\n')
      tspnet.disconnect(id)
      sent = true
    end
  end)
  if sent then
    brun.nannfail = 0
  else
    brun.nannfail = brun.nannfail + 1
    if brun.nannfail == brun.maxannfail then
      brec.note(-1, -1, 0, 'progress pushes disabled after ' .. tostring(brun.maxannfail)
                           .. ' failures -- nothing is listening at ' .. tostring(brun.listenip))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Stopping on purpose
-- ---------------------------------------------------------------------------
-- A FILE, checked between cells, so a run can be ended cleanly by dropping STOP.TXT on the key without
-- a power cycle -- which matters when the alternative is losing the last unflushed rows.
--
-- FOUND BY LISTING THE DIRECTORY, NOT BY OPENING IT. file.open on a file that is not there POSTS AN
-- EVENT on this instrument, and this check runs once per cell -- 86 events in a smoke and about 1.4
-- million across eight days, every one of them a popup on the panel. Opening the directory, which does
-- exist, and searching its listing costs no event at all. usb_log.tsp's ensuredir uses the same
-- technique and its comment is why the directory is called SERDEC: only an 8.3 name can be found by one
-- string.find in the FAT table.
function brun.stopped()
  local fh = nil
  pcall(function() fh = file.open(brun.dir, file.MODE_READ) end)
  if fh == nil then return false end
  local raw = nil
  pcall(function() raw = file.read(fh, file.READ_ALL) end)
  pcall(function() file.close(fh) end)
  if raw == nil then return false end
  return string.find(raw, 'STOP', 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Resuming a run that stopped
-- ---------------------------------------------------------------------------
-- WHY THIS IS POSSIBLE AT ALL: brec.syncrows is 1, so the record's directory entry is current after every
-- cell. A crash, a wedge or a power cut therefore costs the row in flight and nothing else -- which means
-- the record itself says where to start again, and a fortnight's run can carry on from the failure point
-- instead of from the beginning.
--
-- THE LAST R ROW IS THE RESUME POINT, and it is positional: every plan row produces exactly one result
-- row, measured or SDG-failed, so the lap and cell in that row locate the plan exactly. A count of rows
-- would do the same job and be wrong quietly if anything ever wrote two rows for one cell.
--
-- BOUNDED BY THE DIRECTORY ENTRY, not by reading until nil. A read past EOF posts 2201 'File read error'
-- as a box on the panel, and this runs at the start of a run that must not put one there. The 8.3 name in
-- the FAT table carries the file's length at offset 28, which is the same trick tools/run_bench.py's
-- fetch uses -- measured: SOAK    CSV at offset 7425 of a 16384-byte table, size 76514.
function brun.keysize(n83)
  local fh = nil
  pcall(function() fh = file.open(brun.dir, file.MODE_READ) end)
  if fh == nil then return nil end
  local raw = nil
  pcall(function() raw = file.read(fh, file.READ_ALL) end)
  pcall(function() file.close(fh) end)
  if raw == nil then return nil end
  local a = string.find(raw, n83, 1, true)
  if a == nil then return nil end
  local sz = nil
  pcall(function()
    sz = string.byte(raw, a + 28) + string.byte(raw, a + 29) * 256
         + string.byte(raw, a + 30) * 65536 + string.byte(raw, a + 31) * 16777216
  end)
  return sz
end

-- -> iter, cell of the last complete result row, or nil if there is not one.
function brun.resume_scan()
  local sz = brun.keysize('SOAK    CSV')
  if sz == nil or sz <= 0 then return nil end
  local fh = nil
  pcall(function() fh = file.open(brec.path, file.MODE_READ) end)
  if fh == nil then return nil end
  local nb, it, ce = 0, nil, nil
  while nb < sz do
    local l = nil
    local ok = pcall(function() l = file.read(fh, file.READ_LINE) end)
    if not ok or l == nil then break end
    nb = nb + string.len(l)
    if string.sub(l, 1, 2) == 'R,' then
      local f, nf = brun.split(l)
      -- A TORN LAST ROW IS THE NORMAL ENDING, so a row without both numbers is ignored rather than
      -- trusted: resuming one cell early repeats a cell, resuming from a half-written number could
      -- resume anywhere.
      if nf >= 3 and tonumber(f[2]) ~= nil and tonumber(f[3]) ~= nil then
        it, ce = tonumber(f[2]), tonumber(f[3])
      end
    end
  end
  pcall(function() file.close(fh) end)
  return it, ce
end

-- Discard plan rows up to and including (iter, cell). -> true when positioned, false if it is not there.
--
-- REFUSES RATHER THAN STARTING OVER. A resume point the plan does not contain means the plan on the key is
-- not the plan that produced the record -- a different --random-per-lap, a different skip, a regenerated
-- file -- and silently starting from row one would replay days of stimulus while reporting a resume.
function brun.resume_to(iter, cell)
  if iter == nil or cell == nil then return false end
  local n = 0
  while true do
    local c = brun.nextrow()
    if c == nil then return false end
    n = n + 1
    if c.iter == iter and c.cell == cell then
      brun.nskipped = n
      return true
    end
  end
end

-- ---------------------------------------------------------------------------
-- The stop control that works: the front-panel TRIGGER key
-- ---------------------------------------------------------------------------
-- A BUTTON ON THE GLASS CANNOT DO THIS, and the reason is measured rather than assumed. serial_core.tsp
-- carries it in full: a touch press is NOT DISPATCHED while Lua runs -- presses queue until the script
-- returns -- so no OBJ_BUTTON on any screen can stop a loop that has not finished. display.waitevent()
-- is worse than useless here: it BLOCKS, reads a zero timeout as 'wait for ever', and wedging the
-- instrument that way cost a power cycle.
--
-- THE TRIGGER KEY WORKS BECAUSE IT IS FIRMWARE. The key raises trigger.EVENT_DISPLAY, an event blender
-- LATCHES it with no interpreter involved, and the latch can be read afterwards -- measured on 1.7.17a:
-- a press during a deliberate 10 s busy loop was still there when the poll came round, wait(0.001)
-- returns in 1.1 ms, and NOTHING REACHES THE EVENT LOG. That last part is what makes it usable here at
-- all; the STOP.TXT file it replaces costs an event every time it is looked for.
--
-- ONCE PER CELL, which is what was asked for: a press lands mid-capture, is latched by the firmware, and
-- is acted on when the cell finishes. So the run ends between cells, with brec.finish closing the record
-- -- and a close, not a flush, is what updates the FAT directory entry that says how long the file is.
-- The key is then safe to read.
--
-- THE APP OWNS THE BLENDER SETUP, so this borrows it rather than reimplementing it: same blender, same
-- 1 ms poll, same auto-reset-on-read semantics, and the answer is recorded rather than polled twice.
brun.stopkey = brun.stopkey or true      -- false disables the key without touching the loop

function brun.stopkey_setup()
  if not brun.stopkey then return false end
  if sdec == nil or sdec.cancel_setup == nil then return false end
  local ok = false
  pcall(function() ok = sdec.cancel_setup() end)
  if ok then pcall(function() sdec.cancel_clear() end) end
  return ok == true
end

function brun.stopkey_hit()
  if not brun.stopkey then return false end
  if sdec == nil or sdec.cancel_pressed == nil then return false end
  local hit = false
  pcall(function() hit = sdec.cancel_pressed() end)
  return hit == true
end

-- ONE HOLD, USED BY EVERY FAULT THAT WAITS. -> true to retry, false to stop -- and the only two things
-- that answer false are the TRIGGER key and brun.holdmax, which is to say: the operator, or a bound a test
-- asked for. Shared rather than copied because the interruptible-slice logic is the part that must not
-- diverge between the generator, the record and the plan; three copies of it is three chances for one of
-- them to stop honouring the key.
-- Its own name so a test can watch the hold WAIT, rather than infer it from a counter incremented
-- beside the call. delay() is also the plan's per-cell wait, so spying on delay itself cannot separate
-- the two -- measured, 24 calls and 9.05 s where the hold accounted for 4.
function brun.holddelay(secs)
  pcall(function() delay(secs) end)
end

function brun.holdwait(what)
  local waited = 0
  while waited < brun.holdsecs do
    -- AT LEAST ONE SECOND. A slice of zero or less never advances `waited`, and offline delay() is a
    -- no-op, so the loop would spin instead of wait.
    local slice = brun.holdslice
    if slice < 1 then slice = 1 end
    if slice > brun.holdsecs - waited then slice = brun.holdsecs - waited end
    brun.holddelay(slice)
    waited = waited + slice
    brun.heldsecs = brun.heldsecs + slice
    -- THE KEY STILL WORKS DURING A HOLD. The latch is firmware, so a press lands whatever the
    -- interpreter is doing, and this is the only way out that closes the record.
    if brun.keyarmed and brun.stopkey_hit() then
      brun.stopwhy = string.format('L%dC%d: the TRIGGER key was pressed while holding for %s',
                                   brun.iter, brun.cell, what)
      return false
    end
    if brun.holdmax > 0 and brun.heldsecs >= brun.holdmax then
      brun.stopwhy = string.format('L%dC%d: gave up after %d s holding for %s',
                                   brun.iter, brun.cell, brun.heldsecs, what)
      brun.stopbad = true
      return false
    end
    brun.ui_hold(what)
  end
  brun.nhold = brun.nhold + 1
  return true
end

-- Wait for the generator to come back. -> true if it answered, false to give up.
--
-- EVERY WAIT IS ACCOUNTED FOR ON THE KEY. A gap in a fortnight's record is only readable if the record
-- says it was a gap: without a note per retry, a reader sees cells stop and cells resume with nothing
-- between, which is indistinguishable from a run that was restarted by hand.
function brun.sdghold()
  if brun.holdsecs <= 0 then return false end
  -- THE GENERATOR MAY NOT BE THE PROBLEM, so its reachability is tested BEFORE anything waits on it.
  -- maxsdgfail counts cells with no stimulus, and a stale bench/arb_names.tsp produces those with the
  -- generator answering -- a static fault no amount of holding fixes, and holding 300 s per 20 cells for
  -- it would turn a 1.6 h lap into a 7 h one and call it recovery.
  local live0 = false
  pcall(function() live0 = bsdg.alive() end)
  if live0 then
    brun.nsdgalive = brun.nsdgalive + 1
    brec.note(brun.iter, brun.cell, brun.ncell,
              string.format('%d cell(s) in a row had no stimulus but the generator ANSWERS -- the fault '
                            .. 'is not the wire; carrying on', brun.nbadsdg),
              brun.nbad, brun.nbadsdg)
    -- ONCE, NOT EVERY TIME. A five-line log repeating the same sentence every twenty cells has thrown
    -- away the only thing a log is for, which is when something started.
    if brun.nsdgalive == 1 then
      brun.msg(brun.c_bad, 'no stimulus but the generator answers -- check arb names')
    end
    brun.nbadsdg = 0
    return true
  end
  brun.msg(brun.c_bad, 'generator silent -- holding, will retry')
  while true do
    if not brun.holdwait('the generator') then return false end
    bsdg.reset()
    local live, idn = bsdg.alive()
    brec.note(brun.iter, brun.cell, brun.ncell,
              string.format('holding for the generator: retry %d after %d s -- %s',
                            brun.nhold, brun.heldsecs, live and 'BACK' or tostring(idn)),
              brun.nbad, brun.nbadsdg)
    if live then
      brun.msg(brun.c_warn, string.format('generator back after %d s and %d retry(s)',
                                          brun.heldsecs, brun.nhold))
      brun.nbadsdg = 0
      return true
    end
    brun.msg(brun.c_bad, string.format('generator still silent -- retry %d, %d s held',
                                       brun.nhold, brun.heldsecs))
  end
end

-- The screen during a hold: the counters do not change, so the one thing worth refreshing is that it is
-- still waiting rather than wedged -- and WHAT it is waiting for, because 'HOLDING' alone sends an
-- operator to power cycle the generator when the fault is a key that came loose.
function brun.ui_hold(what)
  if brun.ui == nil then return end
  brun.ui_set(brun.ui.time, brun.fit(string.format('HOLDING for %s -- %d s, %d retry(s)',
                                                   tostring(what or 'the generator'),
                                                   brun.heldsecs, brun.nhold), brun.panelw),
              brun.c_bad)
end

-- ---------------------------------------------------------------------------
-- A record that stopped, and a plan that went away
-- ---------------------------------------------------------------------------
-- MEASURE ON, AND KEEP TRYING TO WRITE. brec.stopped means rows are being discarded; the cells keep
-- being measured, the screen goes red, and the record is retried every brun.recretry cells, so a key
-- that was briefly unreadable costs the cells in between rather than the rest of the fortnight.
--
-- NO HOLD HERE, deliberately: unlike a silent generator, an unwritable record still exercises the app --
-- only the transcript is missing -- so the cadence is kept and only the retry is paced. What is lost is
-- COUNTED, or the file would have a gap with nothing to say how wide.
function brun.rechold()
  local why = tostring(brec.why)
  brun.nrecfail = brun.nrecfail + 1
  brun.nreclost = brun.nreclost + 1
  if brun.nrecfail == 1 then
    brun.msg(brun.c_bad, brun.fit('NOT RECORDING: ' .. why, brun.panelw))
  end
  -- FIRST FAILURE, THEN EVERY recretry CELLS. A write that failed once should heal at once; one that
  -- needs a human should not cost a file.open per cell for six days.
  if math.mod(brun.nrecfail, brun.recretry) ~= 1 then return false end
  if not brec.reopen() then return false end
  brun.nrecback = brun.nrecback + 1
  brec.note(brun.iter, brun.cell, brun.ncell,
            string.format('recording resumed after %d unrecorded cell(s) (%d total): %s',
                          brun.nrecfail, brun.nreclost, why), brun.nbad, brun.nbadsdg)
  brun.msg(brun.c_warn, string.format('recording resumed -- %d cell(s) never written down',
                                      brun.nreclost))
  brun.nrecfail = 0
  return true
end

-- The next plan row, waiting for the plan file if it has to. -> a cell, or nil only when the run is to
-- stop -- which is to say when the operator stopped it or holdmax expired.
--
-- A PLAN THAT WILL NOT OPEN USED TO END THE RUN, and on a key written to every cell that is a plausible
-- transient. An empty plan is the same fault arriving differently -- the open succeeded, the first read
-- gave nothing -- and is paced the same way, or it spins as fast as the interpreter can reopen it.
function brun.planwait()
  local nfail = 0
  while true do
    if brun.planopen() then
      local c = brun.nextrow()
      if c ~= nil then
        if nfail > 0 then
          brec.note(brun.iter, brun.cell, brun.ncell,
                    string.format('plan file readable again after %d attempt(s)', nfail),
                    brun.nbad, brun.nbadsdg)
          brun.msg(brun.c_warn, string.format('plan file back after %d attempt(s)', nfail))
        end
        return c
      end
    end
    nfail = nfail + 1
    if nfail == 1 then brun.msg(brun.c_bad, 'PLAN FILE unreadable -- holding, will retry') end
    brec.note(brun.iter, brun.cell, brun.ncell,
              string.format('plan file %s is unreadable or empty -- attempt %d, holding',
                            tostring(brun.planpath), nfail), brun.nbad, brun.nbadsdg)
    if brun.holdsecs <= 0 then
      brun.stopwhy, brun.stopbad = 'plan file will not reopen', true
      return nil
    end
    if not brun.holdwait('the plan file') then return nil end
  end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
function brun.soak(iterations, tag)
  if sdec == nil or sdec.acquire == nil then
    return false, 'the app is not loaded, so there is nothing to soak'
  end
  local forever = (iterations == nil or iterations == 0)
  brun.ncell, brun.nwrap, brun.nbadsdg, brun.stopwhy = 0, 0, 0, nil
  brun.stopbad = false
  brun.nevtot, brun.nevstreak, brun.nevpanel = 0, 0, 0
  -- THE RUN'S OWN TALLIES, on brun rather than as locals, because the status screen reads them and a
  -- screen that has to be handed every number it draws is a screen that gets handed a stale one.
  brun.nbad, brun.nsdgtot = 0, 0
  brun.nhold, brun.heldsecs = 0, 0
  brun.nrecfail, brun.nreclost, brun.nrecback, brun.nsdgalive = 0, 0, 0, 0
  brun.nexp, brun.nunexp = 0, 0
  brun.vcell, brun.vbad = {}, {}
  brun.iterwant = 0
  if not forever then brun.iterwant = iterations end
  brun.t0 = nil
  pcall(function() brun.t0 = os.time() end)

  -- A FAULT AT STARTUP IS STILL ONLY A FAULT. Both used to return, losing a fortnight to a key that was
  -- briefly unreadable. Now brec.stopped is retried by rechold, and a closed plan handle makes nextrow
  -- answer nil, which puts the loop into planwait.
  brun.startfault = nil
  if not brec.begin(tag or 'soak', forever and 0 or iterations, brun.planpath) then
    brun.startfault = 'cannot record: ' .. tostring(brec.why)
  end
  if not brun.planopen() then
    brun.startfault = (brun.startfault and (brun.startfault .. '; ') or '')
                      .. 'no plan file at ' .. brun.planpath
  end
  -- RESUMED, IF ASKED. brun.resume = true means: find the last cell the record holds and carry on after
  -- it. The scan reads the whole record, which is minutes on a fortnight's 160 MB -- once, against days
  -- of stimulus it saves replaying.
  brun.nskipped = 0
  if brun.resume then
    local rit, rce = brun.resume_scan()
    if rit == nil then
      brec.note(0, 0, 0, 'resume asked for but the record holds no completed cell -- starting at the top')
    else
      if not brun.resume_to(rit, rce) then
        brec.finish(string.format('REFUSED to resume: the plan does not contain L%dC%d, so it is not '
                                  .. 'the plan that produced this record', rit, rce))
        return false, string.format('the plan does not contain L%dC%d', rit, rce)
      end
      brun.iter, brun.cell = rit, rce
      brec.note(rit, rce, 0, string.format('resumed after L%dC%d, skipping %d plan row(s)',
                                           rit, rce, brun.nskipped))
    end
  end

  -- NO POPUPS FOR THE DURATION. sdec.mute_events sets localnode.showevents = 0, which is the app's own
  -- tested call and deliberately leaves the LOG intact -- so brun.point's per-cell event count still
  -- polices the app's behaviour while nothing reaches the panel. An unattended week must not end with a
  -- modal box waiting for a keypress that nobody is there to give.
  pcall(function() sdec.mute_events() end)
  -- THE STATUS SCREEN, BUILT ONCE, and the USER swipe screen if it cannot be. Either way the two swipe
  -- lines are written every cell, so a run is never invisible.
  --
  -- ONCE, not per cell: changescreen is a user-visible jump and doing it repeatedly would fight
  -- anybody trying to look at another screen.
  if brun.backlight ~= nil then
    pcall(function() display.lightstate = brun.backlight end)
  end
  brun.keyarmed = brun.stopkey_setup()
  if not brun.ui_build() then
    pcall(function() display.changescreen(display.SCREEN_USER_SWIPE) end)
  end
  brun.settext('SOAK starting', 'reaching the generator')
  bsdg.reset()
  local live, idn = bsdg.alive()
  -- THE GENERATOR'S ANSWER, ON THE PANEL, BEFORE THE FIRST CELL. A soak whose stimulus never arrives
  -- records 1677 rows of nothing and parks on brun.maxsdgfail twenty cells later; seeing it here is the
  -- difference between an operator fixing it in the first minute and finding out on their return.
  brun.settext('SOAK starting', live and tostring(idn) or 'SDG UNREACHABLE')
  if brun.ui ~= nil then
    -- THE FIRST LINE IN THE LOG IS WHETHER THE GENERATOR ANSWERED, because a soak whose stimulus never
    -- arrived looks identical to a decoder that stopped working, and this is where that is cheapest to
    -- notice.
    if live then
      brun.msg(brun.c_ok, 'started -- ' .. brun.fit(tostring(idn), 34))
    else
      brun.msg(brun.c_bad, 'SDG UNREACHABLE at start')
    end
  end
  if brun.startfault ~= nil then
    brun.msg(brun.c_bad, brun.fit('AT START: ' .. brun.startfault, brun.panelw))
    brec.note(0, 0, 0, 'start fault, holding rather than refusing: ' .. brun.startfault)
  end
  brec.note(0, 0, 0, 'start: sdg ' .. (live and tostring(idn) or ('UNREACHABLE ' .. tostring(idn))))
  brun.announce(string.format('START iterations=%s sdg=%s', tostring(iterations or 'forever'),
                              tostring(live)))

  local lastiter = nil
  while true do
    local c = brun.nextrow()
    if c == nil then
      -- END OF PLAN. Wrap unless a finite iteration count says we are done.
      brun.nwrap = brun.nwrap + 1
      if not forever and lastiter ~= nil and lastiter >= iterations then
        brun.stopwhy = string.format('%d iteration(s) complete', iterations)
        break
      end
      if lastiter ~= nil then
        brec.note(lastiter, -1, 0, string.format('plan wrapped, pass %d', brun.nwrap + 1))
        brun.msg(brun.c_lab, string.format('plan wrapped -- pass %d, stimulus repeats', brun.nwrap + 1))
      else
        brun.nwrap = brun.nwrap - 1     -- nothing has been read, so nothing has wrapped
      end
      -- HOLDS RATHER THAN PARKING, for the same reason as everything else here: nil comes back only when
      -- the operator has stopped the run.
      c = brun.planwait()
      if c == nil then break end
    end
    if not forever and c.iter > iterations then
      brun.stopwhy = string.format('%d iteration(s) complete', iterations)
      break
    end
    lastiter = c.iter

    -- OFF BY DEFAULT, because looking costs an event. Any look at the key -- opening a file that is not
    -- there, or reading a directory -- posts one (2205 or 2201), and this check runs in the loop. The
    -- power cycle is the documented way to end a run, so the convenience does not get to spend events
    -- on an instrument nobody is standing at. brun.stopevery = N re-enables it for an attended run.
    if brun.stopevery > 0 and (brun.ncell == 0 or math.mod(brun.ncell, brun.stopevery) == 0) then
      if brun.stopped() then brun.stopwhy = 'STOP.TXT found'; break end
    end
    -- THE KEY, READ ONCE PER CELL. Costs about a millisecond and no event, so unlike the stop file it
    -- can be checked every time round rather than every two hundredth.
    if brun.keyarmed and brun.stopkey_hit() then
      brun.stopwhy = string.format('L%dC%d: the TRIGGER key was pressed', c.iter or 0, c.cell or 0)
      break
    end
    if brun.maxcell > 0 and brun.ncell >= brun.maxcell then
      brun.stopwhy = string.format('cell cap %d reached', brun.maxcell)
      break
    end
    -- A RECORD THAT STOPPED DOES NOT STOP THE RUN. It is red on the screen, it is counted, and it is
    -- retried; the cells carry on being measured meanwhile. brun.iter and brun.cell are set below, so
    -- this is positioned here only for the counters -- rechold names the cell it is called from.
    if brec.stopped then
      brun.iter, brun.cell = c.iter or 0, c.cell or 0
      brun.rechold()
    end

    -- THE NAME COMES FROM THE TABLE, and the plan's own column is used to CHECK it rather than as an
    -- alternative. bench/arb_names.tsp is generated from vector_names.py, so a stale copy is possible;
    -- the plan was emitted from the same source at the same moment, so the two agreeing is evidence and
    -- the two disagreeing is a reason to measure nothing. Choosing one silently is how a cell gets
    -- recorded against a waveform that never played.
    local arb = barb.of(c.vid)
    if arb == nil then
      arb = c.arb
    elseif c.arb ~= nil and c.arb ~= '' and c.arb ~= arb then
      arb = nil
    end
    -- WRITTEN AFTER THE NAME IS RESOLVED, so the panel names the waveform that is about to play rather
    -- than the one the plan asked for. A cell refused because the table and the plan disagree shows '?',
    -- which is the truth: nothing is being played.
    -- PER VECTOR, counted where the cell is attempted rather than where it succeeds, so the two
    -- numbers on the screen are 'failed' out of 'attempted' and not out of 'measured'.
    brun.iter, brun.cell = c.iter or 0, c.cell or 0
    local vk = tostring(c.vid or '?')
    brun.vcell[vk] = (brun.vcell[vk] or 0) + 1
    brun.screen(c, arb)
    -- THE GENERATOR FIRST. A cell measured against the previous cell's waveform is worse than no cell
    -- at all: it is a wrong answer that looks like a right one, which is the failure mode the whole
    -- amplitude-index bug turned out to be.
    local sok, swhy
    if arb == nil then
      sok, swhy = false, string.format('arb_names.tsp says %s for %s and the plan says %s -- '
                                       .. 'regenerate with tools/gen_arb_names.py',
                                       tostring(barb.of(c.vid)), tostring(c.vid), tostring(c.arb))
    else
      sok, swhy = bsdg.select(arb, c.amp, c.ofst, c.srate)
    end
    if not sok then
      brun.nbadsdg = brun.nbadsdg + 1
      -- A CELL WITH NO STIMULUS IS A FAILED CELL. It is separated from a decode failure in the record
      -- (the row says SDG:) and by the judge, but on the screen 'fail rate' means cells that produced no
      -- result, and a silent generator produces none.
      brun.nsdgtot = brun.nsdgtot + 1
      brun.nbad = brun.nbad + 1
      brun.vbad[vk] = (brun.vbad[vk] or 0) + 1
      -- A MISSING STIMULUS IS NEVER AN EXPECTED REFUSAL. The vector might be one that is allowed to
      -- refuse, but it was not asked: nothing was on the wire.
      brun.nunexp = brun.nunexp + 1
      -- THE EMPTY COLUMNS ARE COUNTED, NOT TYPED. A cell with no stimulus has nothing to say in the
      -- twelve measurement columns, and the first version of this row wrote eleven commas where twelve
      -- belonged -- a 22-field row in a 23-field schema. It cost nothing on the instrument and everything
      -- on the host: judge_bench.py refused the whole file, correctly, because a short row means every
      -- column after it might be the wrong one. A row you cannot count by eye should not be typed by eye.
      if not brec.row(string.format('%d,%d,%s,%d,%s,%.4f,%.4f,%.6f,%.3f',
                             c.iter, c.cell, brec.q(c.vid), c.baud, brec.q(c.kind),
                             c.amp or 0, c.ofst or 0, c.srate or 0, c.wait or 0)
               .. string.rep(',', brun.nmeascol + 1) .. 'SDG:' .. brec.q(swhy) .. ',') then
        brun.rechold()
      end
      brec.note(c.iter, c.cell, brun.ncell, 'sdg failed: ' .. tostring(swhy), brun.nbad, brun.nbadsdg)
      if brun.nbadsdg >= brun.maxsdgfail then
        -- HOLDS. brun.sdghold answers false only when the operator pressed TRIGGER or a test set
        -- holdmax, so the break below is reached by a decision rather than by a fault. holdsecs = 0
        -- restores parking and nothing sets it.
        if not brun.sdghold() then
          if brun.stopwhy == nil then
            brun.stopwhy = string.format('L%dC%d: the generator failed %d cells in a row: %s',
                                         c.iter or 0, c.cell or 0, brun.nbadsdg, tostring(swhy))
            brun.stopbad = true
          end
          break
        end
      end
      brun.ncell = brun.ncell + 1
      -- Nothing to measure, so do not spend a capture on it.
      -- luacheck: ignore
    else
      brun.nbadsdg = 0
      -- THE WAIT IS PART OF THE PLAN, not a settling delay: it moves the capture's phase within the
      -- looping arb, which is the variable that decides the answer on a periodic payload.
      if c.wait ~= nil and c.wait > 0 then delay(c.wait / 1000) end

      local fs = sdec.pick_fs(c.baud, 8)
      if fs < brun.minfs then fs = brun.minfs end
      local p = brun.point(fs, c.baud, false)
      -- RE-MUTED AFTER EVERY CAPTURE. sdec.acquire calls sdec.quiet_events(), which sets
      -- localnode.showevents = SEV_ERROR -- so the mute taken once at the top of this function is undone
      -- by the first cell, and every event after that is a popup again. One assignment per cell is
      -- nothing against a modal box on an instrument nobody is standing at.
      pcall(function() sdec.mute_events() end)
      if not p.ran then
        brun.nbad = brun.nbad + 1
        brun.vbad[vk] = (brun.vbad[vk] or 0) + 1
        -- SPLIT AT THE POINT OF FAILURE, using the same list the host judge uses. A refusal on a loud
        -- vector is the documented right answer and is counted as such; a refusal anywhere else is the
        -- number the traffic light is allowed to react to.
        if barb ~= nil and barb.loud ~= nil and barb.loud(vk) then
          brun.nexp = brun.nexp + 1
        else
          brun.nunexp = brun.nunexp + 1
        end
      end
      if not brec.row(string.format(
                             '%d,%d,%s,%d,%s,%.4f,%.4f,%.6f,%.3f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s',
                             c.iter, c.cell, brec.q(c.vid), c.baud, brec.q(c.kind),
                             c.amp or 0, c.ofst or 0, c.srate or 0, c.wait or 0,
                             brun.fsnum(p.fs), brun.num(p.fs, c.baud),
                             p.ran and 'y' or 'n', tostring(p.baud or ''), brec.q(p.fmt),
                             tostring(p.nf or ''), tostring(p.ngood or ''), tostring(p.nbad or ''),
                             tostring(p.nflag or ''), tostring(p.headsusp or ''),
                             tostring(p.snapped), tostring(p.snapfirm),
                             brec.q(p.why)) .. ',' .. (p.hex or '')) then
        -- CHECKED HERE, because the last cell of a run has no next pass to notice a failed write in:
        -- brec.stopped is tested at the TOP of a cell, so a record that died on the final row went
        -- uncounted and unretried.
        brun.rechold()
      end
      brun.ncell = brun.ncell + 1
      brun.announce(string.format('CELL %d/%d %s@%d %s nf=%s ev=%s', c.iter, c.cell,
                                  tostring(c.vid), c.baud, p.ran and 'ok' or 'FAIL',
                                  tostring(p.nf or 0), tostring(p.nev or 0)))
      -- THE CELL'S EVENT COUNT IS TAKEN HERE, AT THE END OF THE CELL, and not from brun.point -- and
      -- that gap was not hypothetical. p.nev is sampled inside brun.point, before the row is written,
      -- before the status note and before the progress push; so the one bug this watchdog exists to
      -- catch, announce posting event 1138 on every cell for a whole lap, was invisible to it. The log
      -- is cleared at the top of brun.point and nothing clears it again, so a count taken after the
      -- push covers everything the cell did. brun.settext accounts for the panel separately, because
      -- the next cell's clear wipes the panel's events before this line is reached.
      local cellev = brun.eventcount()
      if (p.nev or 0) > cellev then cellev = p.nev end
      brun.nevtot = brun.nevtot + cellev
      -- ONE STATUS LINE PER CELL. At ~6 s a cell this is a trickle, and it is the file that answers
      -- "how far did it get" after a power cycle. ev= is written ONLY when something was posted, so a
      -- clean run's status rows stay identical and a reader can find the noisy cell with one grep.
      local nt = p.ran and 'ok' or ('FAIL ' .. tostring(p.why))
      if cellev > 0 then nt = nt .. ' ev=' .. brun.int(cellev) end
      brec.note(c.iter, c.cell, brun.ncell, nt, brun.nbad, 0)
      if cellev > brun.evbudget then
        brun.nevstreak = brun.nevstreak + 1
        if brun.nevstreak >= brun.evstreak and brun.evshed == nil then
          -- THE PUSH GOES FIRST: it is the only optional thing in this loop, and it is the one that
          -- reaches the network on every cell.
          brun.evshed = 'progress push'
          brun.listenip = nil
          brec.note(c.iter, c.cell, brun.ncell,
                    string.format('%d cells in a row posted more than %d event(s) -- progress push '
                                  .. 'switched off to stop them', brun.nevstreak, brun.evbudget))
        end
      else
        brun.nevstreak = 0
      end
    end
  end

  brun.planclose()
  bsdg.output(false)
  bsdg.reset()
  -- THE VERDICT STAYS ON THE PANEL. A run that ends on its own -- iterations complete, or parked
  -- because the generator went away -- otherwise leaves the last cell's line up, which reads exactly
  -- like a run still in progress. After six days away the first question is whether it finished, and
  -- this answers it from across the room. The reason is clipped to 32 characters, so it is written in
  -- full to the key as well.
  brun.settext(string.format('DONE F%s %s', brun.int(brun.nbad), brun.pct(brun.nbad, brun.ncell)),
               tostring(brun.stopwhy or 'ended'))
  brun.ui_end()
  -- THE LAST LAP AND CELL, not -1. A run-total line whose lap column says -1 cannot be placed in the
  -- run, and 'where did it get to' is the first question a returning operator asks.
  -- THE WAITS AND THE LOSSES ARE PART OF THE TOTAL, in one line rather than reconstructed from the S
  -- rows -- and written even when they are zero, since a line that appears only on failure makes its
  -- absence something to interpret.
  brec.note(brun.iter, brun.cell, brun.ncell,
            string.format('run total: %d cell(s), %d failed, %d event(s) instigated (%d from the panel), '
                          .. 'held %d s over %d retry(s), %d cell(s) unrecorded in %d gap(s)',
                          brun.ncell, brun.nbad, brun.nevtot, brun.nevpanel,
                          brun.heldsecs, brun.nhold, brun.nreclost, brun.nrecback))
  brec.finish(string.format('L%dC%d: %s', brun.iter, brun.cell,
                            tostring(brun.stopwhy or 'ended')))
  -- RESTORED, so a run ending does not leave the instrument silently swallowing real errors for the
  -- next operator. The app's own unmute, not a literal.
  pcall(function() sdec.unmute_events() end)
  brun.announce('END ' .. tostring(brun.stopwhy))
  return true, brun.stopwhy
end

-- samples per bit, for the row. Written as a helper because a division by a plan field that arrived
-- as text would otherwise raise inside string.format and lose the whole cell.
function brun.num(fs, baud)
  if fs == nil or baud == nil or baud <= 0 then return '' end
  return string.format('%.3f', fs / baud)
end

-- THE CAPTURE RATE, ROUNDED. tostring() on a float here writes 1000000.0000000001 -- seventeen digits
-- of noise over the one fact that matters. Three of the app's ladder rates are genuinely fractional
-- (66e6/413 is 159806.295), so it is not truncated to an integer either.
function brun.fsnum(fs)
  if fs == nil then return '' end
  return string.format('%.4f', fs)
end

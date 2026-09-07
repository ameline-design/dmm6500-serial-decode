-- bench_run.tsp -- the soak loop, running on the instrument with nobody connected.
--
-- brun.soak(n) runs n iterations of the plan; brun.soak() or brun.soak(0) runs until the power is cut.
-- Every cell is written to the USB key as it completes, because a power cycle is the stop button and
-- there is no graceful exit to save anything at.
--
-- THE MEASUREMENT SEQUENCE IS NOT INVENTED HERE. brun.point() below is the same sequence as
-- bench_point() in tools/bench_uart.py's BENCH_TSP string, which every bench result on record came
-- through: clear the event log, clear every force, set fs and trigmode, acquire, decode, read the same
-- fields off sdec. If the two drift apart this soak stops measuring what the bench measures, so
-- tools/test_bench_engine.lua loads BOTH and compares them on one capture rather than trusting this
-- comment.
--
-- THE PLAN IS READ, NEVER DRAWN. tools/soakplan.py emits it and the key carries it. Re-deriving the draw
-- here would mean a second implementation of the log-uniform placement, the ladder-edge substitution
-- and -- worst -- the skip-before-shuffle indexing, where the positional index keys the amplitude, the
-- offset AND the wait. A second implementation of that mis-drives a whole lap while the run looks
-- healthy.
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

-- HOW MANY GENERATOR FAILURES IN A ROW BEFORE THE RUN HOLDS. A wedged generator leaves every remaining
-- cell stimulus-free, and thousands of rows recording "no bytes" against a dead wire read exactly like a
-- decoder that has collapsed. At this count the run stops measuring and waits for the generator instead
-- -- brun.sdghold, which retries until the operator ends the run.
brun.maxsdgfail = brun.maxsdgfail or 20

-- A RUN ENDS WHEN SOMEBODY ENDS IT: the iteration count or the TRIGGER key (the stop file is off by
-- default -- see brun.stopevery). A FAULT IS
-- NOT ONE OF THEM. A wedged generator, a record that will not write and a plan file that has gone all go
-- red, write the reason to the key, and keep retrying. Parking on day 2 of a fortnight throws away
-- twelve days nobody is there to restart.
--
-- holdsecs is the retry period. HELD IN SLICES, not one delay(), so the panel keeps changing and the
-- TRIGGER key still works -- without it the only way out of a hold is the power. 0 parks instead.
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

-- HOW MANY TIMES A CELL RE-SENDS THE WHOLE WAVEFORM SELECTION before it is recorded as stimulus-free.
-- A late switch answers C1:ARWV? with the PREVIOUS name and is recovered by sending the selection again,
-- not by asking again -- bsdg.arwvtries only re-asks about a command already sent.
--
-- FIVE, MEASURED OVER ~233 REAL SWITCHES: 19 landed late, 18 repaired inside three attempts and ONE not,
-- and a switch that fails is a stimulus-free cell counted against the app for something the generator
-- did. The extra attempts cost nothing on the 1638 cells a lap that re-select what is already playing,
-- nor on a switch that lands first time. The wedge case stays bounded by the bsdg.nfail guard below, so
-- this does not lengthen a dead generator's cell.
brun.selretry = brun.selretry or 5
brun.selwait = brun.selwait or 0.5       -- seconds between attempts
brun.nselback = 0                        -- cells whose stimulus needed more than one attempt

-- HOW OFTEN THE STOP FILE IS LOOKED FOR, in cells. Not every cell: any look at a file or directory that
-- is not readable POSTS AN EVENT -- 2201 'File read error' for the directory read, 2205 'File not found'
-- for a missing file -- and at one per cell that is 86 events in a smoke and ~120 000 across eight days.
-- The TRIGGER key and the power cycle end a run without spending one; the stop file is a convenience,
-- and a convenience does not get to spend an event per cell.
brun.stopevery = brun.stopevery or 0     -- 0 = never look; see the note in the loop
-- OFF, so the status rows a normal soak writes are unchanged. Set true for a diagnostic lap and every
-- cell's status note carries sig_idle's own inputs -- run0, run1, onebit and the ratio the polarity
-- decision turns on. See the append site in the cell loop.
brun.idlediag = brun.idlediag or false
-- OFF, for the same reason. Set true and every cell's status note carries the rate fit's own inputs --
-- the PRE-SNAP estimate, the bit time it came from, and the fit quality.
--
-- WHY THE RECORD NEEDS IT. read_baud is the rate AFTER sig_snap has pulled it to a standard value, so a
-- misreported rate is today indistinguishable between two unrelated faults: the fit was right and the snap
-- went to the wrong neighbour -- 28800/31250 and 230400/250000 are only 8.51 % apart, and snaptol is 2 % --
-- or the fit itself landed on the wrong solution. baud_raw / commanded separates them in one division, and
-- its VALUE names the mechanism: ~1.10 is the 0.91-bit-time second fixed point, ~0.5 or ~2 or ~3 an
-- odd sub-multiple. 63 % of what still fails on a realizable stimulus is a rate misfit, so this is the
-- field the remaining defect population is made of.
brun.ratediag = brun.ratediag or false

-- READ THE GENERATOR BACK ON EVERY CELL THAT PRODUCED NO STIMULUS. Off by default because it costs four
-- round trips, and on for a diagnostic lap because it is the only thing that can distinguish a decoder
-- that could not read a good signal from a generator that was not producing one. 24 % of one diagnostic
-- lap came back with no usable capture and the record could not tell those two apart.
brun.sdgverify = brun.sdgverify or false

-- TIME EACH CELL'S FOUR PHASES: select+wait, acquire, decode, record. Off by default; it takes the
-- instrument's ONE global timer, and anything that does must disarm the recording absorb first.
--
-- WHY IT IS WORTH A FLAG. A cell costs ~4 s -- 2.95 s of it on cells that never decode at all -- and
-- nothing in the record says where that goes. The only per-cell clock in the schema is os.time() at 1 s
-- resolution, which cannot resolve a 0.2 s change: every per-pair median computed from it comes out an
-- integer. Optimising instrument throughput without this is guesswork, and one round of that guesswork
-- already produced a saving too small to see on the panel. serial_core.tsp's acq_copy carries a note
-- proposing exactly this measurement for the buffer proxy read and calls it 'worth doing early'.
brun.timing = brun.timing or false

-- A HARD CEILING ON CELLS, 0 MEANING NONE, AND IT IS FOR THE OFFLINE SUITE. An indefinite run is
-- stopped by cutting the power, which a test cannot do -- so a test drives brun.soak(0) and arranges for
-- something to end it. When that something does not fire, the loop does not fail: it spins, and a suite
-- that spins until something kills it reports through a pipeline as exit 0, which reads exactly like a
-- pass. A cap turns that hang into an assertion.
brun.maxcell = brun.maxcell or 0

-- HOW MANY MEASUREMENT COLUMNS A RESULT ROW CARRIES between the plan's nine and the 'why' text: fs,
-- sa_bit, ran, read_baud, fmt, nf, ngood, nbad, nflag, headsusp, snapped, snapfirm. Named because a
-- stimulus-free cell has to write that many empty ones, and a comma miscounted in a format string is a
-- 22-field row in a 23-field schema. bench_rec.tsp's header is the declaration and this is the number the
-- rows are built from; NOTHING ON THE INSTRUMENT COMPARES THEM. judge_bench.py catches a short row on the
-- host, after the run, by refusing the whole file.
brun.nmeascol = 12

-- THE SLOWEST SAMPLE RATE A CELL MAY BE CAPTURED AT. sdec.pick_fs(baud, 8) asks for eight samples a bit,
-- which at 300 baud is 2500 Sa/s. But an UNLOCKED capture lands at 1 MS/s whatever it asked for -- see the
-- fs_want note in brun.point -- and that is 3333 samples a bit, so ua_probe's 4000-sample window spans
-- 1.2 BIT TIMES and no format fits it. Every failure below 2400 baud in a 117-cell lap was this.
--
-- 10 kSa/s IS THE APP'S OWN FLOOR: serial_app.tsp's probe ladder is {1e6, 1e5, 1e4} and stops there
-- because 20 000 samples at 10 kSa/s is 2 s -- sixty frames at 300 baud.
--
-- WHAT THIS DOES NOT DO is model the app's two-pass probe -- the ladder sweep, then a second decode at a
-- rate chosen from sdec.baud_probe. brun.point mirrors bench_point in tools/bench_uart.py so soak results
-- stay comparable with every bench result on record, and both take one capture at one rate. Modelling the
-- two passes is the larger fidelity fix, in both places at once; this makes the single capture use a rate
-- that can see the line.
brun.minfs = brun.minfs or 10000

-- THE EVENT WATCHDOG. Inspection is not enough to keep this loop quiet: one wrong argument in
-- brun.announce -- tspnet.connect's initString, nil where a string is required -- puts an event 1138 on
-- the panel for every cell, 1677 across a lap, on an instrument whose one inviolable rule is that it
-- never puts a message in front of anybody.
--
-- So the loop watches its OWN event count rather than trusting that every call it makes is quiet.
-- brun.point clears the log and reads the count back per cell, which is the measurement needed: if cells
-- keep posting events, the optional machinery is switched off in order -- the progress push first, since
-- it is a convenience -- and the reason is written to the key. A run that goes quiet and says why beats a
-- run that is right in principle.
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
-- CELLS IN ONE LAP, WHICH IS NOT brun.planrows. planrows is the '# rows=' header -- the whole FILE, so
-- 279 930 for a 210-lap plan -- and using it as the lap size pins the lap percentage at 0 % and makes
-- the hours-remaining figure 210x too large. Three sources, best first:
--   the plan's own '# cells-per-lap=' header, when it has one;
--   planrows / iterwant, when the plan holds exactly the laps that were asked for;
--   the highest cell number seen so far, which is exact from the first lap boundary onwards.
brun.percell = 0          -- cells per lap, 0 until known
-- WHY CELLS PRODUCED NOTHING, COUNTED SEPARATELY BY REASON. The single hardest thing to see on this bench
-- was that 'line is idle (no transitions)' and 'no clear logic levels' are UNRELATED failures: over one
-- 2746-cell lap the first was 457 cells of accumulated instrument state that a power cycle cleared
-- completely, and the second was 196 cells of the drift vectors legitimately refusing, unchanged by the
-- same power cycle. Both showed on the panel only as one 'failed' total, and separating them afterwards
-- took a record fetch and a host script. One line of counters answers it while the run is going.
brun.nidle, brun.nlevels, brun.nswing, brun.nwhyother = 0, 0, 0, 0
-- SPINNER REDRAWS: nspin accumulates during a cell, nspinlast is the finished cell's total. Two fields
-- because the panel draws at the TOP of a cell, so the only count it can honestly show is the previous
-- one -- and because ui_show and ui_end both read it, a single-writer swap is what stops the second
-- reader seeing a zero the first reader left behind.
brun.nspin = 0
brun.nspinlast = 0

-- A COLLECTION AT A KNOWN POINT. sdec.acq_copy builds a FRESH 20 000-entry Lua table per capture and there
-- are about five captures a cell, so a 9.5 h run makes roughly 35 000 of them. Left to Lua's own schedule
-- the pauses fall wherever the allocator happens to trip, which is usually mid-decode -- inside one of the
-- four phases brun.timing measures, where it is indistinguishable from a slow decode.
--
-- cells between collections; 0 disables. A LAP BOUNDARY ALWAYS COLLECTS whatever this says, because that is
-- the one natural seam a long run has, and comparing the figure lap to lap is what shows growth.
--
-- 500, NOT 1, AND NOT 0. A run that looked like it had 'a large number of errors' turned out to be the
-- normal 1.53 % rate seen over 1564 cells for the first time -- the 116-of-116 run before it was too small
-- a sample to mean anything, since 1.5 % of 116 is 1.7 expected failures. So there is no evidence a
-- collection harms a cell. But a collection per cell is also unmeasured, and 500 buys the thing that
-- actually matters -- a heap figure at a known point, several times a lap -- at a duty low enough that it
-- cannot plausibly be what a failure is blamed on next time.
brun.gcevery = brun.gcevery or 500
brun.memk = nil           -- heap KB after the last collection, shown on the note line
brun.cellmax = 0          -- highest cell number seen this lap
-- CELLS MEASURED IN THIS LAP, COUNTED HERE RATHER THAN READ OFF THE PLAN. `c.cell` is a LABEL the plan
-- supplies, and a plan may number cells cumulatively across the whole file instead of restarting each lap
-- -- hot1's does: lap 5 is cells 198..244 and lap 6 is 245..291. Using that label as a position inside the
-- lap made the panel read 'cell 251/244 (103%)', and withholding the figure left no way to tell how much
-- longer the run had. This counter is the position, is always right, and is what the per-lap countdown
-- divides by. The plan's own label is still shown, because the record keys its rows on it.
brun.lapcell = 0

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
    -- string.find WITH A CAPTURE, because 5.0.2 HAS NO string.match: it returns the two indices first and
    -- the captures after them. Same trap as math.fmod -- the host Lua HAS string.match, so a module using
    -- it passes every offline suite and raises '-286 attempt to call field `match`' on the instrument.
    -- tools/lint_tsp.py refuses both names.
    local _, _, n = string.find(ln, 'rows=(%d+)')
    if n ~= nil then brun.planrows = tonumber(n) end
    -- THE PLAN VARIANT, so the record can say what it was run against. string.find with a capture
    -- again: 5.0.2 has no string.match.
    local _, _, rs = string.find(ln, 'random%-per%-lap=(%a*%d*)')
    if rs ~= nil and rs ~= '' then brun.planrsub = rs end
    local _, _, cp = string.find(ln, 'cells%-per%-lap=(%d+)')
    if cp ~= nil then brun.percell = tonumber(cp) end
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
  -- THE RATE FIT'S OUTPUTS ARE CLEARED PER CELL, and this is not housekeeping. This function returns
  -- EARLY when sdec.acquire() fails -- 'line is idle (no transitions)', 24 % of a diagnostic lap -- so
  -- nothing downstream runs and these keep the PREVIOUS cell's values. The status note then records the
  -- last decoding cell's baud_raw against this cell's commanded rate, and the quotient is a plausible
  -- looking number: a reading of one such lap found 'harmonic fits' at exactly 1/16, 1/96 and 1/128
  -- which were nothing but ratios of adjacent plan rates. A stale diagnostic is worse than an absent
  -- one, because absent cannot be mistaken for a measurement.
  sdec.baud_raw, sdec.bittime, sdec.fitratio = nil, nil, nil
  sdec.fitq, sdec.snapped, sdec.snapfirm = nil, nil, nil
  -- SAME REASON, ONE LINE DOWN: this function returns early on an acquire failure, so a phase time left
  -- from the previous cell would be reported against this one.
  brun.tacq, brun.tdec = nil, nil
  if lock then sdec.force_baud = baud end
  -- fs_want, NOT JUST sdec.fs. hw_config() consults force_baud: with nothing locked it resets sdec.fs to
  -- sdec.fs_default -- 1 MS/s -- and throws away whatever the caller asked for. sdec.fs_select() in
  -- serial_core.tsp carries the same trap in full, and fs_want is the one-shot that beats it; the app's
  -- own second pass uses it for the same reason.
  --
  -- MEASURED, in the soak's own record: 108 of 108 cells captured at 1000000 Sa/s whatever the plan asked
  -- for. At 1 MS/s the 20 000-sample buffer is 20 ms, which is 19 bytes at 9600 baud against 240 at the
  -- rate requested -- so an unlocked point is judged on a twelfth of the payload it should have had.
  sdec.fs, sdec.fs_want = fs, fs
  -- FREE-RUN, NOT EDGE-ARMED, and that is a requirement rather than a preference: the analog-trigger path
  -- goes through trigger.model, which posts 2731 'path initiated' and 2732 'path idled' on EVERY capture
  -- -- two events a cell, 3354 across a lap. showevents hides the POPUP but not the LOG ENTRY, and an
  -- accumulating log raises 'Multiple errors have occurred' on its own -- which this loop's own watchdog
  -- would then count. So they must not be instigated at all. Measured with trigmode 'free': 8 cells,
  -- 0 events.
  --
  -- WHAT IT COSTS, because it is a real difference from the host bench: a free-run capture is not armed on
  -- a start-bit edge, so it opens at an arbitrary phase of the arb. The plan's per-cell wait randomises
  -- phase anyway and the offline twin samples eight phases per cell -- but head alignment is not
  -- comparable with an edge-armed bench capture, and a judge must not read it as though it were.
  sdec.trigmode = 'free'

  local ok, why = false, nil
  local okc = pcall(function() ok, why = sdec.acquire() end)
  -- READ BEFORE THE EARLY RETURNS, so a cell that failed to acquire still reports what the acquire cost.
  -- Those are the cells worth timing: a quarter of a hot lap ends here and they are not free.
  if brun.timing then pcall(function() brun.tacq = timer.gettime() end) end
  brun.spin_tick()                      -- 3 of 6: the capture is in
  if not okc then r.why = 'acquire raised'; return r end
  if not ok then r.why = 'acq: ' .. tostring(why); return r end

  local okd, whyd = false, nil
  local okc2 = pcall(function() okd, whyd = sdec.decode() end)
  if brun.timing then pcall(function() brun.tdec = timer.gettime() end) end
  brun.spin_tick()                      -- 4 of 6: the decode is done
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

-- '??' FOR A FLAGGED FRAME, and this is not cosmetic. bench_uart.py emits the same: a frame with an error
-- still has a value, so printing that value lets a byte pass the host's substring check only because the
-- error was ignored. Plain hex here silently weakens the judge.
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
-- SO SOMEONE WALKING PAST CAN SEE IT IS ALIVE, and how it is doing. A headless soak otherwise leaves the
-- panel showing whatever was there before, which is indistinguishable from a wedged instrument, and the
-- announce push only helps someone with a listener running. Two lines, eight facts:
--
--     L3C412 F12 0.3%              lap, cell, failed cells, fail rate
--     v77 9600 8N1 Fox             vector, baud, frame format, waveform
--
-- display.settext ON THE USER SWIPE SCREEN, NOT display.create. Object ids are never reclaimed on this
-- instrument, so a text object per cell would exhaust them; settext writes into the two lines the
-- firmware already owns, so a lap costs no objects at all. THE APP NEVER TOUCHES THESE TWO LINES --
-- nothing in tsp/ names display.TEXT1 or TEXT2 -- so a soak writing them collides with nothing.
--
-- THE LENGTH LIMITS ARE A POPUP, NOT A CLIP, which is why these lines are built by measurement rather
-- than by eye. The reference manual is explicit: TEXT1 holds up to 20 characters and TEXT2 up to 32, and
-- "if you enter too many characters, the instrument displays a warning event and shortens the message to
-- fit". A warning event is a box on the panel of an instrument that must never put one in front of
-- anybody, so an over-long line is not cosmetic -- it is the failure. tools/mock_display.lua enforces
-- both limits offline, and test_bench_engine.lua asserts the widest possible line of each kind fits.
--
-- AND THE PANEL CANNOT HIDE ITS OWN EVENTS. brun.point clears the log at the top of every cell, so
-- anything this posts is wiped before the run's own event count is read -- the watchdog would never see
-- it. The count is taken around the two writes here and added to the run total directly.
brun.panellim1 = 20      -- TEXT1, characters. Firmware limit, not a style choice.
brun.panellim2 = 32      -- TEXT2
-- AND THE CUSTOM SCREEN'S OWN BUDGET, in characters at FONT_MEDIUM: ~13.4 px an advance into about 780
-- usable px. Nothing enforces it -- the firmware draws past the edge and the far end of the line is gone
-- -- so every line here is written against this number and a test checks each at its widest. An alarm
-- that overruns loses the half that says what to DO, which is the half worth having.
brun.panelw = 58

-- THE BACKLIGHT, DIMMED FOR THE DURATION OF A RUN. An unattended soak leaves one screen lit for days, and
-- this panel's backlight has a finite life it need not spend on an empty room.
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
-- whether what has gone wrong is worth walking over to fix. display.create takes a FONT and a COLOUR, so
-- a screen built here gets ~58 characters a line at FONT_MEDIUM instead of 20 and 32.
--
-- THIRTEEN OBJECTS, CREATED ONCE: a screen, seven text rows and brun.msgn log lines. Display object ids
-- are never reclaimed on this firmware -- display.create
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

-- A ROLLING LOG OF THINGS WORTH KNOWING, under the prompt rather than over it. One line cannot do both
-- jobs: an alarm that replaces 'press TRIGGER to stop' leaves the screen saying what is wrong and not how
-- to act on it. So the prompt is permanent and anything notable scrolls beneath it, newest at the bottom,
-- each line stamped with the time and the cell number.
--
-- ONLY STATE CHANGES ARE PUSHED, not one line per cell. A log that repeats 'generator missed 1 cell' for
-- four hundred cells has thrown away the one thing a log is for -- knowing WHEN something started.
brun.msgn = brun.msgn or 4
brun.msgs = nil          -- oldest first; the newest is at the bottom of the screen
brun.lastmsg = nil       -- so an unchanged state is not pushed again
brun.lastshape = nil     -- the same state with a different count in it, ditto
brun.lastn = 0

-- ONE CONDITION MUST NOT FILL THE RING. Dedup on exact text lets a counter push a new line every time it
-- increments: at the measured 4 generator misses in 1578 cells, a fortnight's 273 000 cells is ~690 of
-- them, and five lines of 'generator missed 648 cell(s)' scrolls every one-off event -- a hold, a
-- recording gap, a plan wrap -- off the top.
--
-- SO THE DIGITS COME OUT and the message is compared by SHAPE. A repeat is pushed again only when its
-- number has DOUBLED, which gives 1, 2, 4, 8 ... about ten lines over a fortnight. Every occurrence is on
-- the key regardless.
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
-- number: about a third of a healthy lap produces no result because the plan asks seven vectors to decode
-- signals where refusing is correct. Judging the raw rate reads 20 % on a working instrument and calls it
-- amber, which is crying wolf on the one screen that must not.
--
-- THE AMBER TRIPS ARE 20x APART; THE RED ONES ARE ONE TRIP WRITTEN TWICE. health is 100 minus this rate,
-- so healthbad 60 and badrate 40 are the same condition on the same brun.raten gate -- while healthwarn 99
-- fires at 1 % unexpected where warnrate needs 20 %, which is what makes the headline warn first. The
-- headline can never be greener than this line either: healthline adopts a red ui_status colour outright.
-- Two measurements bound the pair here: a full offline lap gave 23 % unexpected, the offline model being
-- the pessimistic one, and 41 hardware cells gave 10 %.
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
    -- medium. Every line below is written to fit the 58, which is why the stimulus line carries the
    -- generator's full name rather than the waveform's short form -- they say the same thing.
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
    -- THE STOP INSTRUCTION LIVES IN THE TITLE, which is the one piece of the screen that never changes and
    -- never scrolls. It used to occupy 31 of the note line's 58 characters on every draw of an eight-day
    -- run to say something that is true the whole time. 'SD' rather than 'SERIAL DECODE' to make room, and
    -- 'TRIGGER TO STOP' rather than 'PRESS TRIGGER TO STOP' -- the verb is the only word a title can drop.
    u.scr  = add(create(display.ROOT, display.OBJ_SCREEN, 'SD SOAK - TRIGGER TO STOP'))
    -- THE HEADLINE FIRST, because it is the one line that answers the question from across the room.
    -- FONT_MEDIUM is the largest this firmware has -- the reference lists FONT_SMALL and FONT_MEDIUM and
    -- nothing else -- so it is emphasised by position and colour rather than by size.
    u.health = add(create(u.scr, display.OBJ_TEXT, 12, 20, 'SOAK HEALTH --', brun.c_ok, small, left))
    -- 788 mirrors the 12 px left inset of every other line. One character, redrawn six times a cell, so it
    -- gets its own object rather than making each tick rewrite the whole 58-character headline.
    u.spin = add(create(u.scr, display.OBJ_TEXT, 788, 20, '|', brun.c_good, small, display.JUST_RIGHT))
    u.prog = add(create(u.scr, display.OBJ_TEXT, 12, 58, '--', brun.c_val, small, left))
    u.time = add(create(u.scr, display.OBJ_TEXT, 12, 92, '--', brun.c_lab, small, left))
    u.stim = add(create(u.scr, display.OBJ_TEXT, 12, 126, '--', brun.c_val, small, left))
    u.fail = add(create(u.scr, display.OBJ_TEXT, 12, 160, '--', brun.c_lab, small, left))
    u.vfail = add(create(u.scr, display.OBJ_TEXT, 12, 194, '--', brun.c_lab, small, left))
    -- THE PROMPT, WHICH NEVER CHANGES WHILE THE RUN LASTS. It is the only instruction on the screen and
    -- an alarm must not be able to take its place.
    u.note = add(create(u.scr, display.OBJ_TEXT, 12, 228, 'starting', brun.c_ok, small, left))
    -- AND THE LOG BENEATH IT. Five lines at a 34 px pitch ends at y=398, inside the 420 the firmware
    -- allows and the 431 px content area -- checked, because display.create returns nil rather than
    -- raising for a y it will not take, and a nil parent makes every later object nil in silence.
    -- ERRS ON ITS OWN ROW, in the y-slot the fifth log line used to occupy: brun.msgn went 5 -> 4 so this
    -- costs no display object, and object ids are never reclaimed on this instrument. A soak that is going
    -- well writes almost nothing to the log, so a line spent on the count that matters is a better trade.
    u.errs = add(create(u.scr, display.OBJ_TEXT, 12, 262 + brun.msgn * 34, 'Errors: 0',
                        brun.c_good, small, left))
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

-- THE SAME FIGURE WITHOUT THE SPACE, for the two lines that carry four of them. At FONT_MEDIUM the
-- glass holds 58 characters and MEDIUM is the largest font this firmware has, so the four spaces this
-- saves are the difference between the layout fitting and the field at the end being clipped away.
function brun.hshort(sec)
  if sec == nil or sec < 0 then return '--' end
  return string.format('%.1fh', sec / 3600.0)
end

-- THE ONE INSTRUCTION, ON ITS OWN LINE, FOR THE WHOLE RUN. Not a status: a control the operator cannot
-- guess at, since it is the physical TRIGGER key and not anything on the glass.
function brun.prompt()
  if brun.stopwhy ~= nil then return 'ended -- ' .. brun.fit(tostring(brun.stopwhy), 40) end
  -- THE TITLE CARRIES 'PRESS TRIGGER TO STOP', so this no longer repeats it -- but the title is static and
  -- brun.keyarmed is the result of stopkey_setup(), which can fail. When it does, the title is WRONG and
  -- this line is the only thing that can say so: a panel instructing an operator to press a key that will
  -- not be read is worse than one that says nothing.
  -- AN EXPLICIT CALL TO ACTION WHEN THE RUN IS RED. brun.ui_status() is the traffic light: it goes red only
  -- for things a person has to act on -- the run parked, the generator silent for several cells in a row
  -- (its waveform is not on the wire, so every later cell measures nothing), the record no longer being
  -- written, or the no-decode rate past brun.badrate over enough cells to mean it. In every one of those the
  -- right move is to stop and look, and a soak left running is hours of instrument time spent on nothing.
  --
  -- THE HOST CANNOT PUT THIS THERE. brun.soak owns the interpreter for the whole run, so nothing from the
  -- host reaches the panel until it ends -- the run has to notice its own condition and say so.
  -- PCALLED AND GATED ON THERE BEING A RUN. brun.ui_status reads the run's tallies and raises if they are
  -- still nil, which is the state before brun.soak initialises them -- and a raise anywhere in the UI path
  -- puts a modal box on the panel of an instrument nobody is standing at. A prompt is decoration; it must
  -- never be the thing that stops a soak.
  if (brun.ncell or 0) > 0 then
    local red = false
    pcall(function() red = (brun.ui_status() == brun.c_bad) end)
    if red then
      return 'PRESS TRIGGER TO STOP NOW -- this run is not measuring anything'
    end
  end
  if brun.keyarmed then return 'Running' end
  return 'Running -- TRIGGER NOT ARMED: stop by cutting power'
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
  -- STILL MISSING, OR MISSED AND BACK: two states, two lines. A single line saying 'and recovered' covers
  -- both and is pushed while brun.nbadsdg is still non-zero, so a generator failing one or two cells at a
  -- time for ever, never reaching brun.badsdgwarn in a row, would report itself recovered throughout. The
  -- operator's decision to intervene is made from this line.
  if brun.nbadsdg > 0 then
    return brun.c_warn, string.format('no stimulus for %d cell(s) now -- retrying', brun.nbadsdg)
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
  -- THE HOOK IS THE RUN'S, not the app's: released here so a later capture from the panel does not
  -- redraw a spinner belonging to a soak that has finished.
  if sdec ~= nil then sdec.tick = nil end
  local u = brun.ui
  if u == nil then return end
  local el = nil
  if brun.t0 ~= nil then el = os.time() - brun.t0 end
  -- THE PROGRESS LINE BECOMES THE VERDICT, IN COLOUR. Until now this function left u.prog showing the last
  -- cell it drew -- 'lap 6/6  cell 251/244' -- which is indistinguishable from a run still working, and
  -- every other line it touches goes GREY. The first question from across the room is whether the thing has
  -- finished, and the answer was written only to the home screen's TEXT1, which the app's own screen covers.
  --
  -- GREEN FOR A CLEAN END, RED FOR A STOP. brun.stopbad is set where a run gives up -- a generator that
  -- went away, a record that could not be written -- so the two endings must not look alike: 'FINISHED' on
  -- a run that actually died would be the worst line on the panel.
  brun.ui_set(u.prog,
              string.format('%s  %s lap(s)  %s cell(s)  ran %s',
                            brun.stopbad and 'STOPPED' or 'FINISHED',
                            brun.int(brun.iter), brun.int(brun.ncell), brun.hours(el)),
              brun.stopbad and brun.c_bad or brun.c_good)
  brun.ui_set(u.time, 'ran ' .. brun.hours(el) .. '    ended    '
                      .. brun.int(brun.ncell) .. ' cell(s) done', brun.c_lab)
  -- THE SAME TWO COUNTS AS brun.ui_show, for the reason given there.
  brun.ui_set(u.fail, string.format('allowed refusals %s    UNEXPECTED %s    of %s cells',
                                    brun.int(brun.nexp), brun.int(brun.nunexp),
                                    brun.int(brun.ncell)), brun.c_lab)
  brun.ui_set(u.vfail, string.format('nostim %s  idle %s  lvl %s  swing %s  other %s',
                                     brun.int(brun.nsdgtot), brun.int(brun.nidle),
                                     brun.int(brun.nlevels), brun.int(brun.nswing),
                                     brun.int(brun.nwhyother)), brun.c_lab)
  local hl, hcol = brun.healthline()
  -- A RUN THAT GAVE UP SAYS SO ON THE HEADLINE, IN RED. brun.stopbad is set where the run parked -- the
  -- generator gone, the record unwritable -- as opposed to finishing the laps it was asked for. The green
  -- FINISHED on the progress line already covers the good ending; this covers the one an operator has to do
  -- something about, on the line they read first. Only when it was stopped: appending nothing on a clean
  -- finish keeps the headline meaning exactly what it means during the run.
  local sfx, scol = brun.statesuffix()
  hl = hl .. sfx
  hcol = scol
  brun.ui_set(u.health, brun.fit(hl, brun.panelw), hcol)
  local el_, ecol_ = brun.errsline()
  brun.ui_set(u.errs, el_, ecol_)
  -- RED WHEN IT IS CARRYING THE STOP INSTRUCTION, so the one line telling the operator to act is not drawn
  -- in the same colour as 'Running'.
  local ncol_ = brun.c_ok
  if brun.stopwhy == nil and (brun.ncell or 0) > 0 then
    pcall(function() if brun.ui_status() == brun.c_bad then ncol_ = brun.c_bad end end)
  end
  brun.ui_set(u.note, brun.fit(brun.prompt() .. brun.diagflags(), brun.panelw), ncol_)
  brun.ui_note()
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
-- 99 IS MEASURED ON HARDWARE. A lap driven at the requested rate reads 1 unexpected cell in 586 and 2 in
-- the high hundreds: about 0.3 %, or 99.7 % health. So the trip sits at 1 % unexpected -- roughly three
-- times what a working lap produces, far enough out not to flicker and close enough in to catch a real
-- doubling. THIS NUMBER IS EMPIRICAL: move it with evidence from a complete lap, and only from one
-- captured at the rate the plan asked for. A lap starved at 1 MS/s reads 89.8-92.2 % and would set this
-- about nine points too low.
brun.healthwarn = brun.healthwarn or 99
brun.healthbad = brun.healthbad or 60

-- THE DIAGNOSTIC FLAGS IN FORCE, as a short suffix. A run configured wrongly is silently worthless and
-- nothing on the panel said which flags were on. bsdg.arwvevery is included for a specific reason: Lua
-- treats 0 as TRUE, so `bsdg.arwvevery = bsdg.arwvevery or 50` cannot undo a 0 and a run can inherit one
-- from the run before it -- an A/B whose second arm silently repeated the first is exactly the error this
-- makes visible. Only non-default values are named, so a plain soak's headline is unchanged.
function brun.diagflags()
  -- SPELLED OUT, ON THE NOTE LINE. These were initials on the headline -- 'diag:RIST' -- and two things were
  -- wrong with that: an operator cannot read it, and the headline had no room, so it CLIPPED to 'diag:RIS'
  -- and silently claimed timing was off when it was on. A truncated flag string is worse than no flag
  -- string. Moving the stop instruction into the screen title left the note line holding 7 characters of
  -- its 58, which is where these belong.
  local f = ''
  if brun.ratediag then f = f .. ' rate' end
  if brun.idlediag then f = f .. ' idle' end
  if brun.sdgverify then f = f .. ' sdg' end
  if brun.timing then f = f .. ' timing' end
  if bsdg ~= nil and bsdg.arwvevery ~= nil and bsdg.arwvevery ~= 50 then
    f = f .. ' arwv' .. brun.int(bsdg.arwvevery)
  end
  -- ONLY ON A DIAGNOSTIC RUN, which is why this sits after the empty test: a plain soak's note line holds
  -- the prompt and nothing else, and that is the line an operator reads all week.
  --
  -- WHAT IT IS FOR. The spinner's redraw count for the cell just finished, which is the only thing that
  -- separates the two reasons a spinner can look frozen. MEASURED: 10 redraws a cell against 2 visible
  -- 45 deg steps, and 10 mod 4 = 2, so the writes land and the LCD does not repaint mid-script -- it shows
  -- the accumulated glyph at the ~2 points a cell where the interpreter yields. 10 redraws over a 4.945 s
  -- cell is one write every 0.49 s, so the write rate already meets the half-second target and the ceiling
  -- is the repaint, not the tick. Raising the tick rate cannot help; this number is the evidence.
  if f == '' then return '' end
  f = f .. ' spin' .. brun.int(brun.nspinlast or 0)
  -- AND THE HEAP AFTER THE LAST COLLECTION. On an unattended 9.5 h run a number that only ever climbs is
  -- the failure nothing else on this screen would show: the record keeps being written and the cells keep
  -- passing right up to the point the interpreter cannot allocate. Two laps' worth of this figure side by
  -- side is the whole test, which is why a lap boundary always collects.
  if brun.memk ~= nil then f = f .. ' mem' .. brun.int(brun.memk) .. 'k' end
  return '   diag:' .. f
end

-- THE RUN'S STATE AS A SUFFIX FOR THE HEADLINE, and its colour. -> text, colour
--
-- FOUR STATES, NOT TWO. 'stopped' by the TRIGGER key is an operator deciding they have enough data; it is
-- AMBER because the laps asked for were not completed, so a lap count read off this run is short -- but
-- nothing is wrong. brun.stopbad is the run PARKING -- generator gone, record unwritable -- and is red
-- because somebody has to do something. Completing the requested iterations is green, and so is running.
-- A ONE-CHARACTER LIFE SIGN at the end of the headline, advanced at each real step of a cell.
--
-- WHY IT IS WORTH A FIRMWARE CALL. A cell takes ~5.8 s and 58 % of that is inside sdec.acquire(), so for
-- most of every cell nothing on the panel changes at all. A wedged instrument and a working one both show a
-- still screen, and this bench has already lost a night to a generator that stopped driving while every
-- liveness signal stayed green. A character that stops turning says 'stuck HERE' -- and because it advances
-- at six named points, WHERE it stopped narrows which one.
--
-- THE WHOLE LINE IS REWRITTEN rather than given its own object: display objects are never reclaimed on this
-- instrument, ~4 host reloads exhaust the pool, and one more object per build is a real cost for one glyph.
-- A settext is about 1.5 ms, so six a cell is ~9 ms against 5800.
brun.spinchars = {'|', '/', '-', '\\'}
brun.spini = 0
brun.hlcol = nil

function brun.spin()
  brun.spini = math.mod(brun.spini + 1, 4)
  return brun.spinchars[brun.spini + 1]
end

-- Rewrite ONLY the headline, with the next character. Silent when the screen has not been built or the
-- headline has not been composed yet, so a call from anywhere is safe.
brun.spinmin = brun.spinmin or 0.5        -- seconds between redraws: 2 fps ceiling. The FLOOR is
                                          -- set by how often the hook is reached, not by this.
brun.spint = nil

-- THE YIELD THAT MAKES A WRITE VISIBLE, and the reason a redraw ceiling of 2 fps is now the right one.
--
-- MEASURED: 10 writes a cell arrived as 2 visible 45 deg steps, and 10 mod 4 = 2 -- so the writes were
-- landing and the LCD was only showing the accumulated glyph at the ~2 points a cell where the interpreter
-- handed control back. The tick rate was never the constraint; the repaint was.
--
-- brun.holdslice IS THE PRECEDENT. A hold is deliberately sliced into separate delay() calls rather than
-- one long one 'so the panel stays alive' -- which is the same observation from the other direction: a
-- delay() is what lets the firmware repaint. So one tiny delay after the write turns a coalesced write
-- into a visible one.
--
-- OFF BY DEFAULT, AND THE REASON IS A MEASURED FAILURE, not caution. Enabling it at 1 ms produced a large
-- number of failing cells within minutes of a soak whose immediately preceding run was 116 of 116 clean on
-- the same plan and the same freshly cycled instruments. The mechanism is that sdec.tick fires from inside
-- sdec.acq_copy, BETWEEN proxy reads of a capture buffer -- so a delay there stretches the window over
-- which one capture is copied, and a copy of a live buffer is not a thing to make slower. A spinner is
-- never worth a cell.
--
-- Set to a small number of seconds to re-test deliberately, on a short lap, never on an overnight run.
brun.spinyield = brun.spinyield or 0

function brun.spin_tick()
  if brun.ui == nil or brun.ui.spin == nil then return end
  -- READ, NEVER CLEARED. The global timer belongs to the cell's phase timing and to the recording absorb;
  -- clearing it here would make an absorb from minutes ago look current, which once made a host tool file
  -- good vectors as BAD for a whole soak. A read is free and cannot do that.
  local t = nil
  pcall(function() t = timer.gettime() end)
  if t ~= nil then
    -- t < brun.spint means the timer was cleared under us (a new cell took it), so the elapsed comparison
    -- is meaningless and the tick is allowed through rather than suppressed for a whole cell.
    if brun.spint ~= nil and t >= brun.spint and t - brun.spint < brun.spinmin then return end
    brun.spint = t
  end
  -- THE HEADLINE'S COLOUR, so an alarm turns the spinner too and the two cannot disagree about whether
  -- anything is wrong.
  brun.ui_set(brun.ui.spin, brun.spin(), brun.hlcol or brun.c_good)
  -- COUNTED AFTER THE RATE LIMIT, so this is redraws and not calls: a call the ceiling suppressed did not
  -- reach the glass and must not be claimed as if it had.
  brun.nspin = (brun.nspin or 0) + 1
  -- AFTER THE WRITE, NEVER BEFORE: the point is to give the firmware a slice in which to paint what was
  -- just written. pcall because delay() is absent in the offline harness, where the count is what matters.
  if brun.spinyield ~= nil and brun.spinyield > 0 then
    pcall(function() delay(brun.spinyield) end)
  end
end

-- THE ERROR COUNT AND ITS COLOUR. -> text, colour
--
-- GREEN AT ZERO, AMBER AT 1-5, RED ABOVE 5. Deliberately NOT a rate: a proportion needs a denominator and
-- reads 0.0 % for the first several cells of a run, which is exactly when one error matters most. The raw
-- count is the number an operator acts on, and the three bands are what make it readable from across the
-- room without doing arithmetic.
function brun.errsline()
  local n = brun.nbad or 0
  local col = brun.c_good
  if n > 5 then
    col = brun.c_bad
  elseif n > 0 then
    col = brun.c_warn
  end
  return 'Errors: ' .. brun.int(n), col
end

function brun.statesuffix()
  if brun.stopwhy == nil then return ' - RUNNING', brun.c_good end
  if brun.stopbad then return ' - STOPPED', brun.c_bad end
  if string.find(tostring(brun.stopwhy), 'TRIGGER', 1, true) ~= nil then
    return ' - STOPPED', brun.c_warn
  end
  return ' - FINISHED', brun.c_good
end

function brun.healthline()
  -- THE DETAIL LINE'S COLOUR IS READ FIRST, because the headline may never look better than it: a silent
  -- generator or an event on the panel is red down there, and a health figure above it must not disagree.
  local ncol = brun.ui_status()

  -- NO FIGURE AT ALL UNTIL THERE ARE ENOUGH CELLS TO DIVIDE BY. One unexpected refusal on cell 1 is
  -- 0.0 % health, which paints the headline red on a perfectly good instrument in the first ten seconds
  -- of a two-hour lap -- and a screen that starts by crying wolf is a screen nobody reads by day three.
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

-- THERE IS NO SOUND GUESS AT THE LAP SIZE, so this no longer makes one. It returns 0 -- 'not known yet' --
-- and the screen prints the cell number with no total until the first lap boundary sets brun.percell, or
-- until a plan header declares it.
--
-- WHAT IT USED TO DO AND WHY THAT WAS WRONG. It divided brun.planrows by brun.iterwant and offered the
-- quotient as the lap size, guarded only by divisibility. That guard is nearly vacuous: it assumes the
-- plan holds EXACTLY the laps that were asked for, and a plan is deliberately emitted with far more laps
-- than a run will reach so that it never wraps. Measured on a 4200-row / 40-lap plan run with
-- iterations = 2: 4200 % 2 == 0, so the panel announced 2100 cells a lap, 4200 cells total and
-- 5.9 HOURS REMAINING for a run that stopped 19 minutes later at 210 cells. An operator planning their
-- evening around that number is being misinformed by a factor of eighteen.
--
-- The divisibility test cannot see either failure: a plan whose laps differ in length, or -- far more
-- common -- a plan that simply holds more laps than were requested. Nothing derivable from those two
-- numbers distinguishes them, so the honest answer is that the lap size is unknown. Generators declare
-- it instead: `# cells-per-lap=N`, read at brun.nextrow, which makes the total right from cell 1.
function brun.perlap_guess()
  return 0
end

function brun.ui_show(c, arb)
  local u = brun.ui
  if u == nil then return end
  -- THE ONLY WRITER OF nspinlast, and it runs before anything reads it. This draw is at the TOP of a cell,
  -- so brun.nspin still holds the cell that just ENDED -- which is the count to publish. Swapping here
  -- rather than inside diagflags() matters because ui_end() calls diagflags() too, and a reset in the
  -- reader would hand the second caller a zero.
  brun.nspinlast = brun.nspin or 0
  brun.nspin = 0
  local vid = tostring(c.vid or '?')
  -- FOUR NUMBERS, AND NONE OF THEM IS brun.planrows. planrows is the whole FILE -- 279 930 for a 210-lap
  -- plan -- so using it here pins the lap percentage at 0 %. The lap size is brun.percell.
  local nlap = brun.percell
  if nlap <= 0 then nlap = brun.perlap_guess() end
  -- n/m RATHER THAN 'n of m', ON BOTH LINES. Four times shows what it buys: at FONT_MEDIUM the glass holds
  -- 58 characters, MEDIUM is the largest font the firmware has, and the layout with ' of ' spelled out
  -- needs 64 -- so the field at the end, which is the countdown, is the one the firmware would clip away.
  local lap = 'lap ' .. brun.int(c.iter)
  if brun.iterwant ~= nil and brun.iterwant > 0 then
    lap = lap .. '/' .. brun.int(brun.iterwant)
  end
  -- TIME REMAINING IS EXTRAPOLATED FROM THIS RUN'S OWN CELL RATE, not from a nominal seconds-per-cell:
  -- a cell is a capture plus a plan wait plus however long the generator took, and those vary by rate.
  local el, left, lapleft, lapel = nil, '--', '--', nil
  if brun.t0 ~= nil then el = os.time() - brun.t0 end
  -- MEASURED FROM THE LAP BOUNDARY, not divided out of the run's average, so a lap that ran slower than
  -- its predecessors says so instead of being smoothed away.
  if brun.tlap ~= nil then lapel = os.time() - brun.tlap end
  local ntot = 0
  if brun.iterwant ~= nil and brun.iterwant > 0 and nlap > 0 then ntot = brun.iterwant * nlap end
  local rate = nil                      -- seconds a cell, over THIS session only
  if el ~= nil and el > 0 and brun.ncell > 0 then rate = el / brun.ncell end
  -- TWO COUNTERS, AND A RESUME IS WHY. brun.ncell counts what THIS session measured, which is what the
  -- rate must be divided by; the run's POSITION in the plan is that plus everything a resume skipped. One
  -- counter would put every completed lap back on the clock -- a run resumed at lap 9 reading
  -- '500 of 279930 (0.2 %)' -- understating progress and overstating what is left for the whole run.
  local ndone = brun.ncell + (brun.nskipped or 0)
  if rate ~= nil and ntot > ndone then
    left = brun.hours(rate * (ntot - ndone))
  end
  -- TIME TO THE END OF THIS LAP, which is the question the operator actually acts on: a run is stopped
  -- with the TRIGGER key, and stopping 90 % of the way through a lap throws that lap's partial away as
  -- far as 'whole laps completed' is concerned. THE SAME RATE ANSWERS IT, and it is accurate rather than
  -- lucky: the plan sweeps rates ASCENDING within each vector's block, so the one slow cell per vector
  -- is spread evenly through the shuffled lap and the lap percentage tracks elapsed time to within 0.1
  -- points at 25/50/75/90/95 %. If a plan were ever sorted by baud this would stop being true.
  -- POSITION IN THE LAP IS COUNTED, NOT READ OFF THE PLAN. See brun.lapcell: a plan that numbers cells
  -- cumulatively makes the LABEL larger than the lap, and every per-lap figure derived from it wrong.
  --
  -- CARRIED ON THE ROW, not read from brun.lapcell here. The counter is global state and this function is
  -- called directly by tests that fabricate a row; reading the global made those tests depend on whatever
  -- the previous test had left in it, which is the same coupling that produced the stale-diagnostic and
  -- leaked-nfail bugs. `pos` absent means "the label IS the position", which is true of every plan this
  -- repo generates.
  local pos = c.pos or c.cell or 0
  local cellsleft = nil
  if nlap > 0 and pos <= nlap then cellsleft = nlap - pos end
  if rate ~= nil and cellsleft ~= nil then lapleft = brun.hshort(rate * cellsleft) end

  -- THE TOTAL IS SHOWN ONLY WHILE IT DESCRIBES THIS PLAN, which is the same condition cellsleft above
  -- already applies to 'left'. A plan whose cell numbers run CUMULATIVELY rather than restarting each lap
  -- makes brun.percell -- learned as the highest cell of the previous lap -- smaller than this lap's cell
  -- numbers, and the panel then reads 'cell 223/197  (113%)'. Observed on a plan from a scratch generator
  -- that numbered cells across the whole file; soakplan and mkplan_stim both restart per lap, and a plan
  -- can also declare 'cells-per-lap=N' in its header.
  --
  -- The cell number itself is always true, so it is always shown; only the denominator and the percentage
  -- are withheld, on the same principle as brun.perlap_guess -- do not print a figure that cannot be
  -- stood behind. A percentage over 100 makes the operator distrust every other number on the glass.
  local cell = 'cell ' .. brun.int(pos)
  if nlap > 0 and pos <= nlap then
    cell = cell .. '/' .. brun.int(nlap)
                .. string.format('  (%.0f%%)', 100.0 * pos / nlap)
  end
  -- THE PLAN'S OWN CELL LABEL, shown only when it differs from the position -- which is exactly when the
  -- plan numbers cumulatively. The record writes rows as L<iter>C<label>, so an operator reading a failure
  -- off the glass needs the label to find the row; but on a normal plan the two are equal and repeating
  -- the number would spend characters the countdown needs.
  if (c.cell or 0) ~= pos then cell = cell .. ' r' .. brun.int(c.cell) end
  -- THE LAP'S OWN TWO TIMES GO ON THE LAP'S OWN LINE, and the run's are labelled 'Total:' below, because
  -- both scopes carry an elapsed and a remaining and two of them a space apart would be four numbers with
  -- nothing saying which lap or run each belongs to.
  if nlap > 0 then
    cell = cell .. '  ran ' .. brun.hshort(lapel) .. ' left ' .. lapleft
  end
  brun.ui_set(u.prog, lap .. '  ' .. cell, brun.c_val)
  -- ELAPSED OF PROJECTED TOTAL, not a second countdown. 'left 853.8h' answers how long remains and says
  -- nothing about how long the whole thing was ever going to be, which is the figure that places a run in
  -- its plan -- and the two together are the same information twice.
  --
  -- CELLS DONE OUT OF THE WHOLE RUN, and what share of it that is -- the counterpart to the per-lap
  -- share above. '%s cell(s) done' alone could not answer 'how far through the fortnight is it'.
  local tot = '--'
  if rate ~= nil and ntot > 0 then tot = brun.hshort(rate * ntot) end
  local done = brun.int(ndone)
  if ntot > 0 then
    done = done .. ' of ' .. brun.int(ntot) .. ' cells'
                .. string.format(' (%.1f%%)', 100.0 * ndone / ntot)
  else
    done = done .. ' cell(s) done'
  end
  -- 'of --' IS LEFT OUT RATHER THAN PRINTED. Until the first cell finishes there is no rate, so the
  -- projection is unknown -- and 'Total: 0.0h of -- - 1 of 352170 cells' puts two dashes meaning different
  -- things three characters apart on the line a reader meets first.
  -- ELAPSED AT THIS SESSION'S RATE, NOT WALL CLOCK SINCE THIS SESSION STARTED, and for a run that was
  -- never resumed the two are IDENTICAL -- rate is el/ncell, so rate * ndone is el exactly when nothing
  -- was skipped. It differs only after a resume, and there it is the better number twice over: a session
  -- elapsed of 0.7 h beside '4.0 % of 412.1 h' is a line disagreeing with itself, and the wall clock
  -- since the FIRST start would count the hours the instrument spent doing something else. What this
  -- reports is soak time.
  local elshown = el
  if rate ~= nil then elshown = rate * ndone end
  local ran = 'Total: ' .. brun.hshort(elshown)
  if tot ~= '--' then ran = ran .. ' of ' .. tot end
  brun.ui_set(u.time, ran .. ' - ' .. done, brun.c_lab)

  brun.ui_set(u.stim, vid .. '  ' .. brun.int(c.baud) .. ' Bd  ' .. brun.fmtof(arb)
                      .. '  ' .. tostring(arb or '?'), brun.c_val)

  -- BOTH RATES, because they answer different questions: the run's rate says whether the soak is
  -- healthy, and this vector's says whether ONE waveform is the reason it is not.
  local vn, vb = brun.vcell[vid] or 0, brun.vbad[vid] or 0
  -- COUNTS, NOT A SECOND PERCENTAGE. About a third of a HEALTHY lap produces no result -- measured on the
  -- offline twin, 539 of 1677 cells -- because the plan drives seven vectors into conditions where
  -- refusing is the documented right answer. barb.loud excuses 151 of those, so UNEXPECTED is 388 of
  -- 1677: the number that means something, and the one the health headline is built from.
  --
  -- 58 CHARACTERS IS THE BUDGET AT FONT_MEDIUM, and both lines are written against their own widest
  -- values -- four-digit counts -- rather than the ones a screenshot happens to show.
  brun.ui_set(u.fail, string.format('allowed refusals %s    UNEXPECTED %s    of %s cells',
                                    brun.int(brun.nexp), brun.int(brun.nunexp),
                                    brun.int(brun.ncell)), brun.c_lab)
  -- AND THE RUN'S FAILURES BY REASON, on the same line. 'refused' is one number that hides two unrelated
  -- causes: a dead line and a signal the decoder legitimately would not guess at. Naming them here is what
  -- lets an operator tell 'the generator stopped driving' from 'these vectors always refuse' without
  -- fetching the record -- a distinction that took hours to make afterwards.
  brun.ui_set(u.vfail, string.format('cur vec %s: %d of %d refused   idle %s lvl %s sw %s',
                                     vid, vb, vn, brun.int(brun.nidle), brun.int(brun.nlevels),
                                     brun.int(brun.nswing)), brun.c_lab)
  local hl, hcol = brun.healthline()
  local sfx, scol = brun.statesuffix()
  hl = hl .. sfx
  if hcol == brun.c_ok then hcol = scol end
  -- KEPT SO THE SPINNER CAN REDRAW IT without recomputing the health figure six times a cell. Fitted to
  -- one character short of the budget, so appending the glyph cannot push the line over the glass.
  brun.hlcol = hcol
  brun.ui_set(u.health, brun.fit(hl, brun.panelw), hcol)
  local el_, ecol_ = brun.errsline()
  brun.ui_set(u.errs, el_, ecol_)
  -- RED WHEN IT IS CARRYING THE STOP INSTRUCTION, so the one line telling the operator to act is not drawn
  -- in the same colour as 'Running'.
  local ncol_ = brun.c_ok
  if brun.stopwhy == nil and (brun.ncell or 0) > 0 then
    pcall(function() if brun.ui_status() == brun.c_bad then ncol_ = brun.c_bad end end)
  end
  brun.ui_set(u.note, brun.fit(brun.prompt() .. brun.diagflags(), brun.panelw), ncol_)
end

-- ANYTHING WORTH SAYING GOES TO THE LOG, ONCE. The prompt above keeps saying how to stop the run, which
-- is what it is for; an alarm in its place leaves the operator looking at a warning with no instruction
-- under it.
--
-- CALLED AT THE END OF A CELL, NOT FROM ui_show. brun.msg stamps LnnnCmmm from brun.cell, and the screen
-- is drawn BEFORE the generator and the capture run -- so a fault raises its counter too late for its own
-- cell's draw and the line goes out stamped with the NEXT cell. MEASURED: a stimulus failure the record
-- puts at L1C173 reaches the screen as L1C174. The screen is the only account of a fault anybody has
-- without fetching the key, and a miss named one cell late lands on the SECOND cell of a vector's block,
-- which reads as a refutation of only-the-39-switches-can-fail. It is not enough for the key to be right.
--
-- OUTSIDE THE u == nil GUARD, so the ring is maintained whether or not the status objects exist.
function brun.ui_note()
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

-- THE HEAP IN KB, ON BOTH LUAS. -> number or nil
--
-- The instrument is Lua 5.0.2, where gcinfo() is the only way to ask and collectgarbage() takes a numeric
-- limit -- so collectgarbage('count') is not available there. The offline harness is 5.5, where gcinfo()
-- WAS REMOVED and 'count' is the only way. A single call therefore works on exactly one of the two, and the
-- pcall that keeps it safe also hides which: written as gcinfo() alone this field displayed on hardware and
-- was silently unreachable in every offline test, so nothing could check it. Probing both is what puts a
-- panel field under test, and an untested panel field is what put 'Errs' on a clipped line.
function brun.heapk()
  local k = nil
  pcall(function() k = gcinfo() end)
  if k == nil then pcall(function() k = collectgarbage('count') end) end
  return k
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
-- a STRING third argument works. nil here makes every announce fail into tspnet.write(nil, ...), which
-- posts event 1138 -- 'Parameter 1, expected type number' -- once per cell, 1677 across a lap, on an
-- instrument that must never put a message in front of anybody.
--
-- AND A FAILURE IS COUNTED, NOT JUST SWALLOWED. A pcall that hides everything cannot be distinguished
-- from a listener that is simply absent, which is how a push posting an event per cell goes unnoticed.
-- After brun.maxannfail consecutive failures the announcing stops for the rest of the run, so a broken
-- push costs a bounded number of events instead of one per cell for eight days.
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
-- LOCATED BY LISTING THE DIRECTORY, NOT BY OPENING IT. file.open on a file that is not there POSTS AN
-- EVENT on this instrument, and this check runs once per cell -- 86 events in a smoke and ~120 000 across
-- eight days, every one of them a popup on the panel. Opening the directory, which does
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
-- WHY THIS IS POSSIBLE AT ALL: the record's directory entry is committed every brec.syncrows rows, so a
-- crash, a wedge or a power cut costs at most that many cells off the end of the file. The record itself
-- therefore says where to start again, and a fortnight's run carries on from the failure point rather than
-- from the beginning -- which is also what makes an uncommitted tail cheap: those cells are measured
-- again, not lost.
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
-- returns -- so no OBJ_BUTTON on any screen can stop a loop that has not finished. display.waitevent() is
-- worse than useless here: it BLOCKS, reads a zero timeout as 'wait for ever', and the only way out of
-- that is the power.
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
brun.stopkey = brun.stopkey or true      -- assign false AFTER load to disable; a preset false is ignored

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
      -- THE BARE PHRASE, no lap/cell prefix and no 'while holding for': the panel prints this after
      -- 'STOPPED: ' and an operator stop needs no explanation. Nothing is lost -- brec.finish() adds the
      -- lap and cell itself when the reason does not carry them, and what the run was holding for is
      -- already in the run-total line as heldsecs over nhold retry(s).
      brun.stopwhy = 'TRIGGER Pressed'
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
  -- it would add ~7 h of holding to a lap that runs in under three, and call it recovery.
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
-- A PLAN THAT WILL NOT OPEN IS A PLAUSIBLE TRANSIENT on a key written to every cell, so it holds rather
-- than ends the run. An empty plan is the same fault arriving differently -- the open succeeded, the
-- first read gave nothing -- and is paced the same way, or it spins as fast as the interpreter can
-- reopen it.
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
  brun.nselback = 0
  -- BEFORE THE FIRST CELL THERE IS NO CELL, and brun.msg stamps every log line from these -- without the
  -- reset a second run in one session opens its log with the PREVIOUS run's last cell number.
  brun.iter, brun.cell = 0, 0
  -- AND NO LAP HAS BEEN SEEN YET. cellmax accumulates the highest cell number of the lap in progress and
  -- the boundary turns it into the learned lap size, so without this a second run in one session sizes its
  -- first lap from the PREVIOUS run's longest one. That is the state a resume starts in: the app is already
  -- loaded and brun.soak is simply called again.
  -- DRIVE THE SPINNER FROM INSIDE THE APP'S LONG LOOPS. sdec.tick is nil in the shipped app; the bench sets
  -- it for the duration of a run so the glyph keeps moving through sdec.acquire(), which is 58 % of a cell
  -- and the place a hang is most likely. Cleared in ui_end, so nothing outside a soak advances it.
  if sdec ~= nil then sdec.tick = brun.spin_tick end
  brun.nidle, brun.nlevels, brun.nswing, brun.nwhyother = 0, 0, 0, 0
  brun.nspin, brun.nspinlast = 0, 0
  brun.cellmax = 0
  -- SAME REASON FOR THE POSITION COUNTER: a second run in one session would otherwise start its first lap
  -- part-way through, and every per-lap figure on the screen would be offset for the whole first lap.
  brun.lapcell = 0
  brun.nexp, brun.nunexp = 0, 0
  brun.vcell, brun.vbad = {}, {}
  brun.iterwant = 0
  if not forever then brun.iterwant = iterations end
  brun.t0 = nil
  pcall(function() brun.t0 = os.time() end)
  -- THE CURRENT LAP'S OWN START, so the lap line can say how long the lap has run rather than deriving it
  -- from the run's average. Equal to t0 for lap 1; reset at every lap boundary. A --resume start lands
  -- mid-lap, so that first lap's elapsed UNDERSTATES -- the laps after it are exact.
  brun.tlap = brun.t0

  -- A FAULT AT STARTUP IS STILL ONLY A FAULT, and returning here would lose a fortnight to a key that was
  -- briefly unreadable. brec.stopped is retried by rechold, and a closed plan handle makes nextrow answer
  -- nil, which puts the loop into planwait.
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
  -- records a lap of nothing and then holds on brun.maxsdgfail, retrying for as long as nobody comes;
  -- seeing it here is the difference between an operator fixing it in the first minute and finding out
  -- on their return.
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
    -- THE PREVIOUS ROW'S ITERATION, HELD SEPARATELY. The lap-boundary test further down needs the
    -- iteration of the row BEFORE this one; from here on lastiter is this row's, so comparing c.iter
    -- against lastiter there compares a value with itself and the boundary is never seen.
    local previter = lastiter
    lastiter = c.iter

    -- OFF BY DEFAULT. brun.stopped() reads the DIRECTORY, which costs no event while the key is there --
    -- but a pulled or unreadable key makes that read post 2201, once per check, for the rest of the run.
    -- The TRIGGER key ends a run without spending anything, so the convenience does not get to.
    -- brun.stopevery = N re-enables it for an attended run.
    if brun.stopevery > 0 and (brun.ncell == 0 or math.mod(brun.ncell, brun.stopevery) == 0) then
      if brun.stopped() then brun.stopwhy = 'STOP.TXT found'; break end
    end
    -- THE KEY, READ ONCE PER CELL. Costs about a millisecond and no event, so unlike the stop file it
    -- can be checked every cell, where the stop file is off by default.
    if brun.keyarmed and brun.stopkey_hit() then
      brun.stopwhy = 'TRIGGER Pressed'
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
    -- THE LAP SIZE, LEARNED BY COUNTING THE CELLS -- not by taking the highest cell NUMBER. Those are the
    -- same thing only for a plan that restarts its numbering each lap. hot1's plan numbers cells across the
    -- whole file, so lap 5 is cells 198..244: the count is 47 and the highest number is 244. Learning 244
    -- made the panel read 'cell 251/244 (103%)' AND made the run total iterwant x 244 = 1464 against an
    -- actual 291 -- so neither the per-lap countdown nor the overall one could be believed, which is the
    -- state an operator described as making it impossible to tell how much longer the run had.
    --
    -- The comment this replaces claimed the highest cell seen "IS the lap size -- exact, without trusting
    -- any header". It is exact only for the plans this repo happens to generate.
    -- COLLECT AT THE TOP OF A CELL, which is after the previous one finished and outside every timed
    -- phase. One place rather than two: the cell tail has a decoded path and a refused path, and a hook on
    -- each would drift apart. pcall'd because neither call is guaranteed to exist on every firmware, and a
    -- missing garbage collector must not be what ends an overnight run.
    if brun.gcevery > 0
       and (math.mod(brun.ncell, brun.gcevery) == 0 or (previter ~= nil and c.iter ~= previter)) then
      pcall(function() collectgarbage() end)
      brun.memk = brun.heapk()
    end
    if previter ~= nil and c.iter ~= previter and brun.lapcell > 0 then
      -- THE HEAP AT THE LAP SEAM, INTO THE RECORD. brun.memk reached the panel as `mem NNNk` and nothing
      -- else, so a 7.74 h run's entire memory trend was unrecoverable once the run ended -- the one failure
      -- an unattended soak cannot otherwise show, since the cells keep passing and the record keeps being
      -- written right up to the point the interpreter cannot allocate. A lap boundary is the only place the
      -- figure is comparable, because the block above always collects there whatever brun.gcevery says, so
      -- every sample is post-collection. Carries the lap SIZE too: one line then says whether a growing
      -- heap tracked the work done or the time elapsed.
      pcall(function()
        brec.note(previter, brun.cell or 0, brun.ncell or 0,
                  string.format('lap %s end: heap %s kB, %d cell(s) this lap, %d in the run',
                                tostring(previter), brun.int(brun.memk), brun.lapcell, brun.ncell or 0))
      end)
      brun.percell = brun.lapcell
      brun.lapcell = 0
      brun.cellmax = 0
      -- AND THE NEW LAP'S CLOCK STARTS HERE, at the same boundary the lap size is learned at, so the two
      -- numbers on the lap line always describe the same lap.
      pcall(function() brun.tlap = os.time() end)
    end
    -- COUNTED BEFORE THE CELL RUNS, so brun.lapcell is this cell's 1-based position in its lap and the
    -- screen below can divide by it directly.
    brun.lapcell = brun.lapcell + 1
    -- HANDED TO THE SCREEN ON THE ROW rather than read back off brun, so brun.screen has no hidden
    -- dependency on global state and a caller that fabricates a row gets the obvious behaviour.
    c.pos = brun.lapcell
    if (c.cell or 0) > brun.cellmax then brun.cellmax = c.cell end
    brun.iter, brun.cell = c.iter or 0, c.cell or 0
    local vk = tostring(c.vid or '?')
    brun.vcell[vk] = (brun.vcell[vk] or 0) + 1
    brun.screen(c, arb)
    brun.spin_tick()                    -- 1 of 6: the cell has started
    -- THE CELL'S STOPWATCH STARTS HERE, when brun.timing is set. Everything after this point is charged
    -- to one of four phases and the four are written to the status note, because a cell costs ~4 s and
    -- NOTHING in the record says which part of it. os.time() is 1 s granular, so the per-cell figures
    -- derived from it cannot see a 0.2 s effect and every per-pair median comes out an integer.
    --
    -- THE ABSORB IS DISARMED FIRST, and that is mandatory rather than defensive. There is ONE timer on
    -- this instrument; strm_absorb_arm() uses it as a TIMESTAMP meaning "a recording just ended", so an
    -- unrelated cleartime() makes an arm from minutes ago look current and the next Capture press is
    -- swallowed. That exact hazard made a host tool file good vectors as BAD for a whole soak.
    -- tools/bench_matrix.py's mx_point() takes the timer the same way, in the same order.
    if brun.timing then
      sdec.strm_stopped_by_press = nil
      pcall(function() timer.cleartime() end)
    end
    -- THE GENERATOR FIRST. A cell measured against the previous cell's waveform is worse than no cell
    -- at all: it is a wrong answer that looks like a right one, which is the failure mode the whole
    -- amplitude-index bug turned out to be.
    local sok, swhy
    if arb == nil then
      sok, swhy = false, string.format('arb_names.tsp says %s for %s and the plan says %s -- '
                                       .. 'regenerate with tools/gen_arb_names.py',
                                       tostring(barb.of(c.vid)), tostring(c.vid), tostring(c.arb))
    else
      -- THE WHOLE SELECT IS RETRIED, not just the ARWV? verify inside it, and the record says why: a
      -- miss answers with the PREVIOUS waveform's name, and the next cell sending the same name gets it.
      -- Only the 39 cells a lap where the vector changes can fail this way; the rest re-select what is
      -- already playing and cost one attempt.
      local why1 = nil
      local try
      for try = 1, brun.selretry do
        sok, swhy = bsdg.select(arb, c.amp, c.ofst, c.srate)
        if sok then
          if why1 ~= nil then
            brun.nselback = brun.nselback + 1
            -- RECORDED, NOT ALARMED. A recovered switch is not worth the screen, but a phenomenon nobody
            -- counts cannot be sized afterwards, so the try and the first reason go on the key.
            brec.note(c.iter, c.cell, brun.ncell,
                      string.format('sdg select recovered on try %d: %s', try, tostring(why1)),
                      brun.nbad, brun.nbadsdg)
          end
          break
        end
        if why1 == nil then why1 = swhy end
        -- RETRIED ONLY WHILE THE GENERATOR IS STILL ANSWERING. bsdg.nfail is zeroed by every reply and
        -- raised by every timeout, so nfail > 0 is the wedge that needs a power cycle -- where two more
        -- attempts cost a minute a cell and cannot change the answer. A stale name arrives as a REPLY,
        -- so the case this retry exists for leaves nfail at 0.
        if bsdg.nfail > 0 then break end
        brun.holddelay(brun.selwait)
      end
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
      -- THE EMPTY COLUMNS ARE COUNTED, NOT TYPED. A cell with no stimulus has nothing to say in the twelve
      -- measurement columns, and a comma miscounted here is a 22-field row in a 23-field schema: nothing
      -- on the instrument, and judge_bench.py refusing the whole file on the host, correctly, because a
      -- short row means every column after it might be the wrong one.
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

      -- CHARGED TO THE SELECT, and it includes the plan's own wait: both happen before any measurement
      -- and a reader can subtract c.wait, which the row already carries.
      if brun.timing then pcall(function() brun.tsel = timer.gettime() end) end
      brun.spin_tick()                  -- 2 of 6: stimulus selected and the plan wait is over
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
        -- ASK THE GENERATOR WHAT IT WAS ACTUALLY PLAYING, on this cell, before anything else moves it.
        -- A cell that produced no decodable capture is the one case where the four round trips are worth
        -- taking, and it must happen HERE rather than at the end of the cell: the next select would
        -- overwrite the state being asked about.
        if brun.sdgverify then
          local snap = nil
          pcall(function() snap = bsdg.snapshot() end)
          brec.note(c.iter, c.cell, brun.ncell,
                    string.format('nostim %s: %s', tostring(p.why), tostring(snap)),
                    brun.nbad, brun.nbadsdg)
        end
        -- AND SPLIT BY REASON TOO, which is a different question from expected-vs-not: an allowed refusal
        -- and a dead line are both 'expected' on a loud vector and mean completely different things.
        local w = tostring(p.why or '')
        if string.find(w, 'line is idle', 1, true) ~= nil then
          brun.nidle = brun.nidle + 1
        elseif string.find(w, 'no clear logic levels', 1, true) ~= nil then
          brun.nlevels = brun.nlevels + 1
        elseif string.find(w, 'swing only', 1, true) ~= nil then
          brun.nswing = brun.nswing + 1
        else
          brun.nwhyother = brun.nwhyother + 1
        end
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
        -- brec.stopped is tested at the TOP of a cell, so a record dying on the final row would go
        -- uncounted and unretried.
        brun.rechold()
      end
      brun.spin_tick()                  -- 5 of 6: the row is on the key
      brun.ncell = brun.ncell + 1
      brun.announce(string.format('CELL %d/%d %s@%d %s nf=%s ev=%s', c.iter, c.cell,
                                  tostring(c.vid), c.baud, p.ran and 'ok' or 'FAIL',
                                  tostring(p.nf or 0), tostring(p.nev or 0)))
      -- THE CELL'S EVENT COUNT IS TAKEN HERE, AT THE END OF THE CELL, and not from brun.point. p.nev is
      -- sampled inside brun.point, before the row is written, before the status note and before the
      -- progress push -- so the very fault this watchdog exists to catch, announce posting event 1138 on
      -- every cell, is invisible to it. The log is cleared at the top of brun.point and nothing clears it
      -- again, so a count taken after the push covers everything the cell did. brun.settext accounts for
      -- the panel separately, because the next cell's clear wipes the panel's events before this line is
      -- reached.
      local cellev = brun.eventcount()
      if (p.nev or 0) > cellev then cellev = p.nev end
      brun.nevtot = brun.nevtot + cellev
      -- ONE STATUS LINE PER CELL. At ~6 s a cell this is a trickle, and it is the file that answers
      -- "how far did it get" after a power cycle. ev= is written ONLY when something was posted, so a
      -- clean run's status rows stay identical and a reader can find the noisy cell with one grep.
      local nt = p.ran and 'ok' or ('FAIL ' .. tostring(p.why))
      if cellev > 0 then nt = nt .. ' ev=' .. brun.int(cellev) end
      -- THE IDLE DECISION'S OWN INPUTS, appended only when brun.idlediag is set, so a normal soak's
      -- status rows stay byte-identical and nothing a reader greps for moves. It rides the status note
      -- that already exists rather than adding a second S row, so the record grows by characters rather
      -- than by rows and judge_bench needs no schema change to ignore it.
      --
      -- WHAT IT IS FOR: sig_idle picks its branch by comparing the longest run against 10 * onebit, and
      -- then the WEAK branch decides polarity from the two logic LEVELS -- inverted when the line
      -- straddles ground. run0, run1, onebit and ratio say which branch was taken; lo and hi say what
      -- the branch was looking at.
      --
      -- lo AND hi ARE THE ONLY WITNESS TO WHAT THE GENERATOR ACTUALLY DID. The record's amp_vpp and
      -- ofst_v are what the plan COMMANDED, bsdg.select writes BSWV without reading it back, and the
      -- SDG2122X's envelope is |OFST| + AMP/2 <= 10 V -- which soakplan's draw does not respect, because
      -- it constrains the data band rather than the nominal pair. So a cell can be recorded at an offset
      -- of -8.9 V while the wire carried a band centred near ground. These two fields are the difference
      -- between inferring that and measuring it.
      if brun.idlediag then
        local lg = sdec.run1 or 0
        if (sdec.run0 or 0) > lg then lg = sdec.run0 end
        local ob = sdec.onebit
        nt = nt .. string.format(' idle=%s weak=%s run0=%.1f run1=%.1f onebit=%s ratio=%s lo=%s hi=%s',
                                 tostring(sdec.idle), sdec.idle_weak and 'y' or 'n',
                                 sdec.run0 or -1, sdec.run1 or -1,
                                 (ob ~= nil) and string.format('%.3f', ob) or 'nil',
                                 (ob ~= nil and ob > 0) and string.format('%.3f', lg / ob) or 'nil',
                                 (sdec.lo ~= nil) and string.format('%.3f', sdec.lo) or 'nil',
                                 (sdec.hi ~= nil) and string.format('%.3f', sdec.hi) or 'nil')
      end
      -- THE RATE FIT'S OWN INPUTS, appended only when brun.ratediag is set. Three fields sdec already
      -- computes and the record already discards -- see the flag's comment for why they are the ones that
      -- matter. Cost is one string.format on a cell that spent ~6 s talking to the generator.
      --
      -- rawbaud IS THE PRE-SNAP VALUE and that is the entire point: r.read_baud is sdec.baud, which
      -- sig_snap may have moved. Recording only the post-snap rate is what makes a wrong snap and a wrong
      -- fit look identical afterwards.
      --
      -- fitratio REPLACES bittime. bittime is recoverable as fs/rawbaud and carried no independent
      -- information; fitratio is the rescaling ua_best() settled on (uart_decode.tsp), and without it a
      -- wrong WIDTH fit and a correct fit that was then rescaled are indistinguishable in the record.
      -- The exact-doubling family reads rawbaud/commanded = 2.0000 either way, so only fitratio says
      -- whether sig_bittime found the double or ua_best chose it.
      -- THE FOUR PHASES, CUMULATIVE FROM THE TOP OF THE CELL. Cumulative rather than per-phase because
      -- there is one timer and clearing it mid-cell would collide with the absorb arm; a reader
      -- subtracts. 'row' is taken last and includes the record append, which on a FAT key syncs every
      -- brec.syncrows cells and is therefore not uniform.
      if brun.timing then
        local function ts(v) if v == nil then return 'nil' end return string.format('%.3f', v) end
        local trow = nil
        pcall(function() trow = timer.gettime() end)
        nt = nt .. string.format(' t=%s/%s/%s/%s', ts(brun.tsel), ts(brun.tacq), ts(brun.tdec), ts(trow))
      end
      -- THE RUNNER-UP'S QUALITY, on cells where ua_best RESCALED the fit. uart_decode accepts a rescale on
      -- `q >= st.qmin` where `qmin = sdec.qgate * qbest` -- a threshold RELATIVE to the best candidate --
      -- and nothing in the record says what the UNRESCALED candidate scored. That is the difference between
      -- a rescale that won 0.95 to 0.60, which is the mechanism working, and one that won 0.95 to 0.94,
      -- which is a coin flip deciding the reported baud rate. The doubling family (fitratio 0.5, three
      -- vectors at 125000 and one at 312) cannot be judged without it.
      --
      -- RECOMPUTED HERE RATHER THAN PUBLISHED FROM THE APP, deliberately: tsp/ is what ships, the archive
      -- has just been handed to an outside tester, and sig_fit is a pure function of already-published
      -- state -- Tfit is sdec.bittime / sdec.fitratio, and sdec.w/sdec.nw survive the decode.
      --
      -- ONLY WHEN A RESCALE HAPPENED. At fitratio 1 the two bit times are identical and q1 would just be
      -- fitq again, so the six-pass fit costs nothing on a cell that did not rescale.
      if brun.ratediag then
        local br = sdec.baud_raw
        local q1 = nil
        if sdec.fitratio ~= nil and sdec.fitratio ~= 1 and sdec.fitratio ~= 0
            and sdec.bittime ~= nil and sdec.w ~= nil and (sdec.nw or 0) > 0 then
          pcall(function()
            local _, q = sdec.sig_fit(sdec.w, sdec.nw, sdec.bittime / sdec.fitratio)
            q1 = q
          end)
        end
        nt = nt .. string.format(' q1=%s',
                                 (q1 ~= nil) and string.format('%.4f', q1) or 'nil')
        nt = nt .. string.format(' rawbaud=%s fitratio=%s fitq=%s snap=%s/%s',
                                 (br ~= nil) and string.format('%.2f', br) or 'nil',
                                 (sdec.fitratio ~= nil) and string.format('%.4f', sdec.fitratio)
                                                        or 'nil',
                                 tostring(sdec.fitq),
                                 tostring(sdec.snapped), tostring(sdec.snapfirm))
      end
      brec.note(c.iter, c.cell, brun.ncell, nt, brun.nbad, 0)
      brun.spin_tick()                  -- 6 of 6: the status note is written
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
    -- THE LOG LINE IS PUSHED HERE, at the end of the cell, so brun.cell still names the cell that caused
    -- it. See brun.ui_note. A break above skips it and brun.ui_end pushes instead.
    brun.ui_note()
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
  -- AND THE STIMULUS RETRIES, because they are the count that says whether the late-switch retry earns its
  -- place: a cell whose waveform needed a second selection would otherwise be a stimulus failure, and
  -- nothing else on the key distinguishes 'never happened' from 'recovered'.
  -- THE FINAL LAP HAS NO BOUNDARY AFTER IT, so the lap-seam note above never samples the heap for the last
  -- lap -- which on a 1-lap run is every lap there is. Collected here so the figure is post-collection like
  -- the others and the series is comparable end to end.
  if brun.gcevery > 0 then
    pcall(function() collectgarbage() end)
    brun.memk = brun.heapk()
  end
  brec.note(brun.iter, brun.cell, brun.ncell,
            string.format('run total: %d cell(s), %d failed, %d event(s) instigated (%d from the panel), '
                          .. 'held %d s over %d retry(s), %d cell(s) unrecorded in %d gap(s), '
                          .. '%d stimulus retry(s), heap %s kB',
                          brun.ncell, brun.nbad, brun.nevtot, brun.nevpanel,
                          brun.heldsecs, brun.nhold, brun.nreclost, brun.nrecback, brun.nselback,
                          brun.int(brun.memk)))
  -- THE STOP REASON ALREADY CARRIES ITS OWN LAP AND CELL wherever one is known, so an unconditional prefix
  -- writes 'L1C247: L1C248: TRIGGER Pressed' -- two cell numbers, one line, disagreeing.
  local why = tostring(brun.stopwhy or 'ended')
  if string.find(why, '^L%d+C%d+:') == nil then
    why = string.format('L%dC%d: %s', brun.iter, brun.cell, why)
  end
  brec.finish(why)
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

-- chunk_decode.tsp -- decode a capture LONGER THAN LUA MEMORY, one window at a time.
--
-- Frame mode holds a whole capture as a plain Lua array (serial_core's acq_copy) and
-- that is what caps it at 20 000 samples, i.e. 192-500 bytes. This module removes the
-- cap without removing the array: the READING BUFFER holds the long capture -- up to
-- 6 000 000 samples, in the firmware, not in Lua -- and the decode walks it in
-- overlapping windows, appending each window's bytes to a file and reusing the same
-- one window table for the next. Memory therefore stays at exactly one window
-- whatever the capture length, and the length is bounded by the buffer instead.
--
-- The design's whole point is that IT HAS NO THROUGHPUT REQUIREMENT. The signal is
-- already captured before any Lua runs, so a window may take as long as it takes; the
-- alternative -- extracting samples in real time as they arrive -- needs a per-sample
-- read cost the instrument may not have, and no amount of double buffering fixes a
-- throughput deficit. Acquire long, then decode at leisure.
--
-- WHAT THIS MODULE DOES NOT DO: acquire. Making the long capture (does
-- buffer.make(2.8e6) succeed with defbuffer1/2 alive?) and driving the 1 Hz panel
-- counter are bench work. Everything here is pure logic over a sample source and is
-- developed and tested with no instrument attached, against the same
-- tools/gen_serial.lua waveforms as the rest of the decoder.
--
-- Lua 5.0.2: no '#', math.mod for modulo, table.getn for length.

sdec = sdec or {}

-- ---------- configuration ----------
-- The window is deliberately sdec.n, the SAME size frame mode already uses. That makes
-- the memory high-water mark of a 32 kB stream identical to the one the app is already
-- known to survive, rather than a new number to find out about on the bench.
sdec.ck_win_n = 20000

-- Overlap, in frames. Three is one for correctness and two for margin -- see
-- ck_overlap() for why one is the floor.
sdec.ck_ovframes = 3

-- How many samples the LEVEL measurement decimates the whole recording down to.
--
--     count   bins   modal   thr      sig_levels
--       982     61   0.585   3.263 V  accept   <- threshold ABOVE the high level
--      1963    122   0.325   1.651 V  accept
--      3925    245   0.176   1.647 V  accept
--      5233    327   0.235   3.295 V  accept   <- wrong again
--      7850    490   0.137   1.648 V  refuse
--     10466    512   0.146   1.645 V  refuse
--     31397    512   0.145   1.645 V  refuse
--
-- Two things follow, and they agree. sig_levels' bin count is floor(n/binocc) capped at
-- nbins, so it SATURATES at n = 8192 and every count past that measures the same thing
-- -- which is the only regime where the number is comparable to anything. And below
-- saturation the coarse bins occasionally choose the wrong pair of humps outright, so a
-- small count is not merely less consistent, it is sometimes badly wrong.
--
-- sdec.n, then: past saturation, and the same population size frame mode's final
-- measurement uses -- so chunked mode accepts and refuses a line exactly where frame
-- mode does, by construction rather than by coincidence.
sdec.ck_level_n = 20000

-- How many CONTIGUOUS windows the level fallback tries, spaced across the recording. See
-- ck_levels(): one window covered 0.7 % of the burst positions in a 2.8 M capture.
sdec.ck_probes = 8

-- Medium mode's cap. One number for every baud rate, so the UI has one expectation to
-- state and the operator has one to remember; 32 kB is still 400-500 lines of
-- 64-column debug text. 32 rather than 64 kB because the worst case then needs 2.78 M
-- samples -- under half the 6 M the instrument has for ALL buffers together -- so
-- defbuffer1/defbuffer2 almost certainly never need shrinking to make room.
sdec.ck_maxbytes = 32768

-- ============================================================================
-- Sample sources
-- ============================================================================
-- A READER is a function reader(dst, from, count, step) that fills dst[1..m] with the
-- samples at absolute 1-based positions from, from+step, from+2*step ... and returns m,
-- which is short only at the end of the data. step defaults to 1.
--
-- The step is not a convenience. It is what lets the LEVELS be measured over the whole
-- recording while the EDGES are measured window by window -- see ck_levels().
--
-- The indirection is what makes this module testable with no instrument: the decode
-- below cannot tell a reading buffer from a Lua array, so the offline suite drives the
-- SHIPPED code path rather than a stand-in for it.
--
-- dst is supplied by the caller and REUSED for every window. Nothing here clears it,
-- so entries past m are stale from the previous window -- which is safe because every
-- consumer in the chain (sig_levels, sig_edges, ua_bit) is bounded by an explicit n
-- and ua_bit returns nil rather than reading past it. Reusing the table is not a
-- micro-optimisation: allocating a fresh 20 000-entry array 143 times is 143 times the
-- garbage, on a Lua whose collector behaviour under an app is one of the things
-- suspected in this firmware's panics.

-- Over a plain Lua array. The test path, and also the way to run a chunked decode over
-- a frame-mode capture that is already in memory.
function sdec.ck_reader_table(rd, ntotal)
  return function(dst, from, count, step)
    if step == nil then step = 1 end
    local m, i = 0, 0
    for i = 1, count do
      local a = from + (i - 1) * step
      if a > ntotal then break end
      local v = rd[a]
      if v == nil then break end
      dst[i] = v
      m = i
    end
    return m
  end
end

-- Over a reading buffer. buf.readings is a firmware proxy, not a table, so each index
-- is an IPC round trip -- which is exactly why this happens once per sample per
-- capture here and not once per sample per decode pass.
function sdec.ck_reader_buffer(buf, ntotal)
  local rdp = buf.readings
  return function(dst, from, count, step)
    if step == nil then step = 1 end
    local m, i = 0, 0
    for i = 1, count do
      local a = from + (i - 1) * step
      if a > ntotal then break end
      local v = rdp[a]
      if v == nil then break end
      dst[i] = v
      m = i
    end
    return m
  end
end

-- ============================================================================
-- Window geometry
-- ============================================================================
-- HOW MUCH THE WINDOWS MUST OVERLAP, derived rather than guessed, because getting it
-- wrong loses one byte per seam and a lost byte in the middle of a log file is very
-- hard to notice.
--
-- ua_run stops when a frame runs off the end of its array ('truncated'), so a window
-- ending at W emits its last complete frame and leaves at most one PARTIAL frame
-- behind. Call that frame's start t0. Because a frame starting at t0 did not fit,
-- t0 + framebits*T > W, so t0 > W - framebits*T. The next window must contain the
-- WHOLE of it, so it must begin at or before W - framebits*T:
--
--     overlap >= framebits * T          -- one frame. This is the floor.
--
-- Two more frames of margin, plus maxback, buy two things that are cheap here and
-- awkward otherwise:
--
--   * sig_cross walks BACK up to sdec.maxback samples from a hysteresis trip to find
--     the threshold crossing, and at the leading edge of a window that walk is
--     truncated, so the window's first edge or two can be slightly mispositioned.
--     With margin those edges sit inside already-emitted territory and are discarded
--     by tmin before their position matters.
--   * the seam then falls in the middle of the overlap rather than at its rim, so the
--     de-duplication is never deciding a near-tie.
--
-- At 8.68 samples/bit and 10 bit frames that is ceil(260.4) + 64 = 325 samples, 1.6 % of a
-- 20 000-sample window: the redundant work is a rounding error against the cost of
-- getting a seam wrong.
function sdec.ck_overlap(T, framebits)
  if T == nil or framebits == nil then return nil end
  return math.ceil(sdec.ck_ovframes * framebits * T) + sdec.maxback
end

-- Window size, overlap and stride for a bit time, or nil plus a reason.
--
-- REFUSES rather than clamps when the window cannot hold enough frames. The case is
-- real: force 1200 baud while fs is still 1 MSa/s and T is 833 samples, so one 12-bit
-- frame is 10 000 samples and three of them do not fit in the window at all -- stride
-- would go to zero and the loop would never advance. Refusing names the remedy, which
-- is the sample rate, and is the same shape as every other refusal in this app.
function sdec.ck_geometry(T, framebits)
  local W = sdec.ck_win_n
  local ov = sdec.ck_overlap(T, framebits)
  if ov == nil then return nil, nil, nil, 'no bit time' end
  local need = math.ceil((sdec.ck_ovframes + 2) * framebits * T) + sdec.maxback
  if W < need then
    return nil, nil, nil,
           string.format('%.0f samples/frame needs a window of %d, not %d -- ' ..
                         'sample slower', framebits * T, need, W)
  end
  local stride = W - ov
  return W, ov, stride, nil
end

-- How many windows a capture of ntotal samples takes at this stride. Exact, because
-- the stride is CONSTANT -- the loop below advances by it unconditionally rather than
-- resuming from wherever the last frame happened to end. That costs a fraction of a
-- percent in redundant decoding and buys a window count that is known before the run
-- starts, which is what makes the progress indicator honest instead of a guess.
function sdec.ck_nwin(ntotal, W, stride)
  if ntotal == nil or W == nil or stride == nil or stride < 1 then return nil end
  if ntotal <= W then return 1 end
  return 1 + math.ceil((ntotal - W) / stride)
end

-- ============================================================================
-- Priming: measure the line ONCE
-- ============================================================================
-- LEVELS ARE AN AMPLITUDE STATISTIC; EDGES ARE A TIME STATISTIC. That distinction is
-- the whole of this function, and it is what makes a decode longer than memory
-- possible without compromise.
--
-- sig_levels never looks at a sample's neighbours: it takes vmin/vmax, bins amplitudes
-- into a histogram, walks the two densest humps and averages the samples inside them.
-- Every one of those is order-free. So the levels can legitimately be measured on a
-- DECIMATED view -- every k-th sample spanning the entire recording -- which costs one
-- window of memory and gives exactly the population a monolithic decode would have
-- seen. sig_edges cannot be treated that way, because a threshold crossing is defined
-- between adjacent samples; edges therefore stay window by window.
--
-- full drift cycles are symmetric about the true levels and a quarter of one is not.
--
-- So chunked mode measures the line BETTER than frame mode can, not worse: frame mode's
-- capture IS one window, so it has no whole recording to average over.
--
-- THE LEVELS MUST NOT BE RE-MEASURED PER WINDOW, which is the opposite error and
-- equally real. A window that happens to be all idle -- entirely normal on a bursty
-- line, and this mode exists for long recordings of bursty lines -- has only one dense
-- amplitude. It would either refuse or, worse, split that one hump and place the
-- threshold inside a logic level, and the bytes on either side of that window would
-- come from two different thresholds.
--
-- (What remains unhandled is drift large enough that no single threshold fits the whole
-- recording -- past ~0.7 V of a 3.3 V swing, where the monolithic decoder also fails.
-- The fix there is a threshold that TRACKS slowly, and it is not built: choosing a
-- tracking rate before seeing real drift on real hardware would be inventing a number.)
--
-- Returns ok, reason.
-- The decimated attempt alone, so priming can spend one press on it. Returns ok, why,
-- fatal -- fatal means the source gave nothing, so the contiguous probes cannot help
-- either and trying them would only cost time.
function sdec.ck_levels_dec(reader, ntotal, win)
  if reader == nil then return false, 'no sample source', true end
  -- NOT clamped to ck_win_n, and that is not an oversight. The window is a Lua table,
  -- not a fixed-size array, so filling ck_level_n entries of it is legal whatever
  -- ck_win_n is; the table simply grows to the larger of the two and the window loop
  -- keeps reading only its own first cnt. Clamping instead would put the window size
  -- back into the accept/refuse decision by the back door -- and would do it only in
  -- the offline suite, which runs a small window deliberately, so the tests would stop
  -- exercising the production level path.
  local N = sdec.ck_level_n
  -- ck_level_max is the LATENCY cap, set by the panel path from its budget; nil off the panel, so
  -- the one-shot callers and the offline suite keep the full decimated view. Separate from ck_win_n
  -- deliberately -- see the note above on why clamping to the window would stop the tests
  -- exercising the production level path.
  if sdec.ck_level_max ~= nil and sdec.ck_level_max < N then N = sdec.ck_level_max end
  local step = 1
  if ntotal ~= nil and ntotal > N then step = math.ceil(ntotal / N) end
  local cnt = reader(win, 1, N, step)
  if cnt == nil or cnt < 2 then return false, 'nothing captured', true end
  local ok, why = sdec.sig_levels(win, cnt)
  if ok then sdec.ck_levelsrc = 'decimated' end
  return ok, why, false
end

-- ONE contiguous level probe, k = 0..ck_probes-1, spaced evenly across the recording.
--
-- FALL BACK TO A CONTIGUOUS WINDOW when the decimated view finds nothing, because
-- decimation can ALIAS PAST A SPARSE BURST: a short message in a long recording -- exactly
-- the traffic the streaming modes exist for -- reduces to a handful of samples at the space
-- level once the step is 140, and can reduce to none at all. Refusing instead would report a
-- recording whose levels are measurable from any window containing the burst as an idle line.
--
-- SPACED ACROSS the recording, not just the head: reading only the first window covered
-- 20 000 of 2 800 000 possible burst positions, 0.7 %. The decimated view is still tried
-- FIRST, so the drift property that motivated decimation is untouched.
function sdec.ck_levels_probe(reader, ntotal, win, k)
  if reader == nil then return false end
  local W = sdec.ck_win_n
  if ntotal ~= nil and ntotal < W then W = ntotal end
  local nprobe = sdec.ck_probes or 1
  local total = ntotal or W
  local span = total - W
  if span < 0 then span = 0 end
  local from = 1
  if nprobe > 1 and span > 0 then
    from = 1 + math.floor(span * k / (nprobe - 1))
  end
  local c2 = reader(win, from, W, 1)
  if c2 == nil or c2 < 2 then return false end
  if not sdec.sig_levels(win, c2) then return false end
  sdec.ck_levelsrc, sdec.ck_levelat = 'contiguous', from
  return true
end

-- Establish the logic levels for a whole recording: decimated first, then contiguous probes.
function sdec.ck_levels(reader, ntotal, win)
  local ok, why, fatal = sdec.ck_levels_dec(reader, ntotal, win)
  if ok then return true end
  if fatal then return false, why end
  local k
  for k = 0, (sdec.ck_probes or 1) - 1 do
    if sdec.ck_levels_probe(reader, ntotal, win, k) then return true end
  end
  sdec.ck_levelsrc, sdec.ck_levelat = nil, nil
  return false, why
end

-- Format, on a CONTIGUOUS lead-in window, with the levels already established.
--
-- THE FORMAT MUST NOT BE RE-SEARCHED PER WINDOW. ua_autoformat can legitimately choose
-- between formats that are indistinguishable on the wire, and its tie-breaks are
-- statistical -- so run per window it could change its mind halfway through a file, and
-- there would be nothing in the file to say it had. Detect once, state it, apply it.
--
-- PRIMING IS PHASED, one bounded sub-operation per call, because it was the last unbounded
-- thing a front-panel press could reach. Unphased it is up to eight contiguous 20 000-sample
-- level probes plus a lead-in read plus edge extraction plus the format search -- seconds of
-- Lua in one call -- and a press is not dispatched while Lua runs, so the press that STOPS a
-- recording paid for all of it even though every decode slice after it was bounded.
--
-- Phases, in order, each one window's work or less:
--   lvd   the decimated level pass
--   lvp   one contiguous level probe (repeats, at most ck_probes times)
--   read  the contiguous lead-in window
--   edge  sig_edges and sig_idle over it
--   fmt   the format search
--
-- pr.label names the current phase for the status row, so the operator sees priming
-- advancing rather than a dead panel.
function sdec.ck_prime_new(reader, ntotal, win)
  if reader == nil then return nil, 'no sample source' end
  return {reader = reader, ntotal = ntotal, win = win, phase = 'lvd', probe = 0,
          cnt = 0, why = nil, label = 'levels'}, nil
end

-- One priming sub-operation. Returns done, fmt, err; fmt is set only on the last call.
function sdec.ck_prime_step(pr)
  if pr == nil then return true, nil, 'no priming state' end

  if pr.phase == 'lvd' then
    local ok, why, fatal = sdec.ck_levels_dec(pr.reader, pr.ntotal, pr.win)
    if ok then
      pr.phase, pr.label = 'read', 'reading'
      return false, nil, nil
    end
    if fatal then return true, nil, why end
    pr.why, pr.phase, pr.probe = why, 'lvp', 0
    pr.label = string.format('levels 1/%d', sdec.ck_probes or 1)
    return false, nil, nil
  end

  if pr.phase == 'lvp' then
    if sdec.ck_levels_probe(pr.reader, pr.ntotal, pr.win, pr.probe) then
      pr.phase, pr.label = 'read', 'reading'
      return false, nil, nil
    end
    pr.probe = pr.probe + 1
    if pr.probe >= (sdec.ck_probes or 1) then
      sdec.ck_levelsrc, sdec.ck_levelat = nil, nil
      return true, nil, pr.why or 'no clear logic levels'
    end
    pr.label = string.format('levels %d/%d', pr.probe + 1, sdec.ck_probes or 1)
    return false, nil, nil
  end

  if pr.phase == 'read' then
    local W = sdec.ck_win_n
    if pr.ntotal ~= nil and pr.ntotal < W then W = pr.ntotal end
    local cnt = pr.reader(pr.win, 1, W, 1)
    if cnt == nil or cnt < 2 then return true, nil, 'nothing captured' end
    pr.cnt, pr.phase, pr.label = cnt, 'edge', 'edges'
    return false, nil, nil
  end

  -- From here it is exactly the frame-mode chain on exactly the shipped functions, MINUS the
  -- sig_levels call, which ck_levels has already done better. The first window of a stream is
  -- otherwise a frame-mode capture in every respect, so priming is a decode of it rather than
  -- a special case -- and it leaves sdec.res, the notes and the panel summary describing the
  -- real line before the long run starts.
  if pr.phase == 'edge' then
    sdec.sig_edges(pr.win, pr.cnt)
    sdec.sig_idle(pr.win, pr.cnt)
    pr.phase, pr.label = 'fmt', 'format'
    return false, nil, nil
  end

  local ok, why = sdec.decode_from(pr.win, pr.cnt)
  if not ok then return true, nil, why end
  local r = sdec.res
  if r == nil or sdec.bittime == nil then return true, nil, 'no format' end
  local parbits = 0
  if r.par ~= sdec.PAR_NONE then parbits = 1 end
  pr.phase, pr.label = 'done', nil
  return true, {T = sdec.bittime, nbits = r.nbits, par = r.par, nstop = r.nstop,
                invert = r.invert, framebits = 1 + r.nbits + parbits + r.nstop}, nil
end

-- The one-shot form: prime to completion in one call. Returns fmt, reason.
-- The guard is a backstop on the phase machine, not on the signal: every phase either
-- advances or terminates, so exceeding it means a coding fault rather than bad data.
function sdec.ck_prime(reader, ntotal, win)
  local pr, perr = sdec.ck_prime_new(reader, ntotal, win)
  if pr == nil then return nil, perr end
  local done, fmt, err, guard = false, nil, nil, 0
  while not done do
    done, fmt, err = sdec.ck_prime_step(pr)
    guard = guard + 1
    if guard > 64 then return nil, 'priming did not converge' end
  end
  if fmt == nil then return nil, err end
  return fmt, nil
end

-- ============================================================================
-- The chunked decode
-- ============================================================================
-- Walk the capture in windows, emitting each window's new bytes to a sink.
--
-- THE SEAM IS THE WHOLE PROBLEM, and one number solves it. After each window the
-- absolute position at which the last emitted frame ended is known -- it is
-- t0 + (framebits - 0.5)*T, the same expression ua_run uses internally to stop a data
-- transition inside a byte from being read as the next start bit. Handing that to the
-- next window as tmin0 makes it do two jobs at once:
--
--   * CONTINUATION. The window does not re-anchor. Re-anchoring is not merely
--     redundant, it is wrong on the traffic this mode is for: a gapless stream has no
--     1.5-bit mark run to anchor on, so ua_run's fallback takes the first candidate
--     edge, which inside a byte is a data transition -- and the entire window after it
--     decodes misaligned. Carried phase cannot do that.
--   * DE-DUPLICATION. Frames in the overlap were already emitted by the previous
--     window and their positions are at or before tmin0, so the same test that
--     excludes an in-frame edge excludes them. There is no separate dedup pass to get
--     wrong, and no comparison of byte VALUES -- which would have been the obvious
--     approach and is unsound, because a stream of repeated bytes is common and two
--     identical bytes at different positions are two bytes.
--
-- Asynchronous framing is what makes carrying phase safe: every frame still finds its
-- own start edge, so tmin0 is a floor on where the next one may begin, not an
-- assumption about where it does. Drift between frames is absorbed exactly as it is
-- within a window.
--
-- A SINK is sink(vals, errs, m, base) -> ok. It receives one window's new frames, with
-- base = how many bytes preceded them, and returns false to stop the run (a failed
-- file write, a cap reached). It must not retain vals/errs: they belong to the window
-- and the next one overwrites them.
--
-- Returns a totals table, or nil plus a reason.
-- WHAT ONE WINDOW COSTS, so a latency budget can be spent without reading a clock.
--
-- Cost is dominated by the per-SAMPLE passes, so it scales with the window width and is near
-- enough constant for a given W.
--
-- WHY WINDOWS AND NOT SECONDS. The obvious implementation is `while timer.gettime() < budget`, and it
-- is wrong here for two reasons.
--
-- First, there is only ONE timer on this instrument -- timer.cleartime()/gettime() is global -- and a
-- budget check inside the DECODE loop would have to reset it per slice, which collides with BOTH of the
-- two things that legitimately hold it:
--
--   record_run()      clears it at the start of a flow-controlled run and reads it between windows, as
--                     the run-wide wall-clock bound (fc_maxsec). A slice clearing the timer would reset
--                     that bound every window and the run would never reach it. THE DECODE IS INSIDE
--                     the interval being measured, which is the whole point -- it is the larger half of
--                     a window.
--   strm_absorb_arm() stamps the moment a run ENDED, to decide whether a queued press is still
--                     absorbable. A slice clearing the timer after that stamp would make a press made
--                     seconds later look immediate.
--
-- WHO DOES NOT HOLD IT, stated because it is easy to assume otherwise: stream_acquire() bounds itself by
-- summing its poll period into a COUNTER and never touches the timer, so strm_maxsec is not a timer user.
-- The timer is free BETWEEN windows -- which is what lets record_run() bound a whole run -- and it is
-- never free inside this loop.
--
-- Second, a window count is DETERMINISTIC, so the offline suite can assert exactly where a slice
-- ends instead of depending on how fast the machine running the tests happens to be.
--
-- Recalibrate this from a measurement, not from a guess: it is the one number converting the
-- operator-facing budget (sdec.ui_latency_s) into work.
--
-- THE READ OUT OF THE READING BUFFER IS PART OF THE COST -- 21.73 us a sample, 0.435 s of a
-- 20 000-sample window -- so timing only sig_edges and ua_run over a window already in a Lua
-- table understates the total threefold. Timed per phase (tools/bench_priming.py), 9600 baud,
-- W = 20 000:
--
--     levels    0.958 s     the decimated pass, ck_level_n samples
--     reading   0.530 s     the contiguous lead-in read
--     edges     0.101 s     sig_edges + sig_idle
--     format    1.043 s     the format search -- the most expensive per sample
--     window    0.685 s     one decode slice, x20
--
-- Every phase is proportional to W, so ONE per-sample cost bounds all five -- which is what makes
-- the latency bound real. The format phase scales with FRAMES though, and samples-per-bit varies
-- 2:1: at W = 8653 it took 0.451 s at 9600 baud (8.33 sa/bit) against 0.634 s at 250 kBd (4.0).
-- Two points give 32.5 us/sample + 1.63 ms/frame, i.e. 52 us/sample at 8.33 sa/bit and 73 at 4.0.
-- The WORST is used: one always-safe constant beats two that must be evaluated before the format is
-- known. Costs ~30 % window width at low rates -- throughput, not correctness.
sdec.ck_smp_us = 73               -- worst-phase cost per sample, microseconds, MEASURED at 4 sa/bit
sdec.ck_win_max = 20000           -- and never wider than this, whatever the budget allows
sdec.ck_win_min = 2000            -- nor narrower: below this the per-window seam overhead dominates
sdec.ck_win_ref = 20000           -- the width the phase timings above were taken at

-- How many windows fit in `budget_s`, for windows of width W. Never less than one: a budget
-- smaller than a single window cannot be honoured by stopping sooner, and returning zero would
-- make no progress at all and spin forever.
-- Fraction of the budget available for the phase itself. The rest pays for what ck_job_step does
-- around it and what the caller does after: the sink's file writes, the progress settext and the
-- ui_refresh. Those are milliseconds, now that ck_smp_us is measured over a whole step rather than
-- over the arithmetic inside one -- so this is a small margin, not the factor-of-two fudge it was
-- when the per-window figure itself was three times optimistic.
sdec.ck_budget_frac = 0.9

-- WHAT A DECODE WINDOW COSTS PER SAMPLE, as against ck_smp_us for the worst PRIMING phase. Keeping
-- one constant for both is what pinned a slice at one window: ck_win_for sizes W so that the format
-- search alone fills the budget, so dividing that same budget by W x ck_smp_us cannot come out above
-- 1 however the margin is applied -- one Capture press per window, 101 of them for 30 s at 4800 Bd.
--
-- MEASURED 0.685 s for one 20 000-sample decode step (the `window` phase above) -- 34.25 us a
-- sample, of which 21.73 is the read out of the reading buffer and does not scale with frames.
-- Two ways to the worst case, since only the one operating point was timed: scale the whole figure
-- the way the format phase scales from 8.33 to 4 sa/bit (x 73/52) gives 48, and holding the read
-- fixed while doubling the frame-proportional remainder gives 47. The higher is used.
sdec.ck_win_us = 48
-- Decode windows one slice should aim to spend, as a bound on the WIDTH -- because the count follows
-- from the width and nothing else. THIS IS 1, AND THE ARITHMETIC FOR WHY IS WORTH KEEPING:
--
-- samples per press = W x n, and n = floor(budget / (W x ck_win_us)), so raising n by narrowing W
-- cannot buy more than budget / ck_win_us samples per press -- 9375 at 0.45 s, against 6164 today.
-- That 1.52x is the whole prize, and taking it needs W <= 4687, i.e. n = 2. Three constraints then
-- do not fit together at 0.5 s: n = 2, a W that stays a useful width (>= 5000, asserted in
-- test_serial.lua), and the 0.9 margin. Any two hold. n = 2 with W = 5000 spends 0.480 s of the
-- 0.5 s bound -- inside it, but on 4 % margin rather than 10 %.
--
-- So the width stays where the priming phases put it and a press stays one window; flipping this to
-- 2 is the whole change if the margin or the width floor is allowed to give.
sdec.ck_slice_n = 1

-- The widest window whose every phase fits `budget_s`. nil budget means the fixed maximum: the
-- one-shot callers have no panel to protect and want the fewest seams.
function sdec.ck_win_for(budget_s)
  local wmax = sdec.ck_win_max or 20000
  if budget_s == nil or budget_s <= 0 then return wmax end
  -- ck_budget_frac IS APPLIED HERE AND NOWHERE ELSE. The margin belongs to the width, because every
  -- phase's cost is proportional to it, so trimming W once covers the priming phases and the decode
  -- slices together -- and ck_slice_win divides the WHOLE budget for that reason.
  local b = budget_s * (sdec.ck_budget_frac or 1)
  local w = math.floor(b / ((sdec.ck_smp_us or 52) * 1e-6))
  -- Narrow enough that ck_slice_n DECODE windows also fit, which is the half that makes a press
  -- worth more than one window. The two bounds are different phases of the same job, so the
  -- smaller wins.
  local wd = math.floor(b / ((sdec.ck_slice_n or 1) *
                             (sdec.ck_win_us or sdec.ck_smp_us or 52) * 1e-6))
  if wd < w then w = wd end
  if w > wmax then w = wmax end
  if w < (sdec.ck_win_min or 2000) then w = sdec.ck_win_min or 2000 end
  return w
end

-- How many windows fit in a latency budget, never fewer than one. per_us defaults to the worst
-- PRIMING phase, so a caller that has not said which phase it is asking about gets the safe answer;
-- ck_decode passes ck_win_us, because a decode window is a third cheaper than the format search.
function sdec.ck_slice_win(budget_s, W, per_us)
  if budget_s == nil or budget_s <= 0 then return nil end       -- nil = unlimited
  local per = (W or sdec.ck_win_ref or 20000) * ((per_us or sdec.ck_smp_us or 52) * 1e-6)
  if per <= 0 then return nil end
  local n = math.floor(budget_s / per)
  if n < 1 then n = 1 end
  return n
end

-- Walk a capture window by window, emitting bytes to a sink; resumable via opts.resume.
function sdec.ck_decode(reader, ntotal, fmt, sink, opts)
  if reader == nil then return nil, 'no sample source' end
  if fmt == nil or fmt.T == nil then return nil, 'no format' end
  if opts == nil then opts = {} end
  local win = opts.win
  if win == nil then return nil, 'no window table' end

  local T, framebits = fmt.T, fmt.framebits
  local W, ov, stride, why = sdec.ck_geometry(T, framebits)
  if W == nil then return nil, why end

  -- `opts.nocap` EXISTS BECAUSE LUA CANNOT TELL "key absent" FROM "key = nil", and the plain
  -- `opts.maxbytes or sdec.ck_maxbytes` turned "no cap" into 32768 -- silently capping the
  -- UNLIMITED mode, which then scanned 1.7 M of the 2.8 M samples it had just acquired, threw
  -- away 31 744 decodable bytes, and told the operator the stream "may continue".
  local maxbytes = opts.maxbytes
  if maxbytes == nil and not opts.nocap then maxbytes = sdec.ck_maxbytes end
  local progress = opts.progress
  local nwin = sdec.ck_nwin(ntotal, W, stride)

  local tot = {nf = 0, ngood = 0, nbad = 0, nfalse = 0, nwin = 0, nwin_est = nwin,
               nsmp = 0, stopped = nil, W = W, overlap = ov, stride = stride}

  -- Absolute position where the last emitted frame ended, or nil while nothing has
  -- been emitted yet -- which is what tells the FIRST window to anchor normally.
  local endpos = nil
  local off = 0                 -- absolute 0-based offset of the current window

  -- RESUMING A SUSPENDED RUN. The whole of this loop's carried state is three values -- the
  -- window cursor, the seam, and the totals -- which is why chunking this is checkpointing
  -- rather than restructuring. Everything else in the body is derived per window.
  --
  -- The SINK is deliberately not part of the state: it belongs to the caller and must be the
  -- SAME closure across slices, because ck_sink_file holds an open handle and a partial row in
  -- its carry. Handing a fresh sink to a resumed run would reopen the file and lose the carry.
  if opts.resume ~= nil then
    off = opts.resume.off or 0
    endpos = opts.resume.endpos
    if opts.resume.tot ~= nil then tot = opts.resume.tot end
    tot.suspended = nil
    tot.nwin_est = nwin
  end

  -- Windows this slice may spend before handing the panel back. nil = no limit, which is what
  -- every existing caller gets and why ck_run's behaviour is unchanged.
  local slice = sdec.ck_slice_win(opts.budget_s, W, sdec.ck_win_us)
  local spent = 0

  while true do
    local cnt = reader(win, off + 1, W)
    if cnt == nil or cnt < 2 then break end

    -- Edges are per window and levels are not: sig_edges reads sdec.thr and sdec.hyst,
    -- which ck_prime set once. This is the one per-window allocation (ei and es), and
    -- it is roughly a twentieth of the window's own size -- ~900 edges against 20 000
    -- samples -- so it is left alone rather than pooled.
    sdec.sig_edges(win, cnt)

    local tmin0 = nil
    if endpos ~= nil then tmin0 = endpos - off end
    local r = sdec.ua_run(win, cnt, T, fmt.nbits, fmt.par, fmt.nstop, fmt.invert,
                          tmin0)

    tot.nwin = tot.nwin + 1
    tot.nsmp = off + cnt
    tot.nfalse = tot.nfalse + r.nfalse
    -- A MID-BYTE START IS A PROPERTY OF THE RUN, AND ONLY THE FIRST WINDOW CAN SEE IT. ua_run marks
    -- r.headsusp when the frames before the first idle gap carry errors and the frames after it do
    -- not -- a capture that began part way through a byte. It was computed per window and thrown away
    -- with the window, so a recording never reported what a frame capture reports on the same wire.
    --

    local m = r.nf
    -- CLIP AT THE CAP, mid-window if need be. Emitting the whole window and then
    -- noticing would put more bytes in the file than the mode promises, and "32 kB"
    -- has to mean 32 kB or the number is decoration.
    if m > 0 and maxbytes ~= nil and tot.nf + m > maxbytes then
      m = maxbytes - tot.nf
      if m < 0 then m = 0 end
      tot.stopped = 'cap'
    end

    if m > 0 then
      local i
      for i = 1, m do
        if r.errs[i] == nil then tot.ngood = tot.ngood + 1
        else tot.nbad = tot.nbad + 1 end
      end
      -- THE WINDOW THAT PRODUCED THE FIRST BYTES is the only one whose head can be a misaligned START,
      -- and tot.nf == 0 here -- inside the emit, before the increment -- is what identifies it.
      --
      -- NOT 'THE FIRST WINDOW'. That was the first attempt and it was wrong: with a lead-in the first
      -- window can decode NOTHING, so `tot.nf == 0` outside this block stayed true into window 2 and a
      -- later window's head overwrote the figure. A later window's head is a SEAM the overlap machinery
      -- already handles, so a head error there is not a misaligned start and claiming it is worse than
      -- saying nothing. Caught by wrapping ua_run in test_serial and watching window 2 win.
      if tot.nf == 0 and r.headsusp ~= nil and r.headsusp > 0 then
        tot.headsusp = r.headsusp
      end
      local sok = true
      if sink ~= nil then sok = sink(r.vals, r.errs, m, tot.nf) end
      tot.nf = tot.nf + m
      if sok == false then
        tot.stopped = 'sink'
        break
      end
      -- Only advance the seam over frames actually EMITTED. Clipping at the cap and
      -- then carrying the unclipped window's end position would leave the seam past
      -- bytes the file never received -- invisible in a run that stops there, and a
      -- silent hole in one that resumes.
      endpos = off + r.tpos[m] + (framebits - 0.5) * T
    end

    if tot.stopped == 'cap' then break end

    -- The WINDOW is the progress tick, and that is why no clock is needed here. A
    -- window is a few hundred milliseconds of decoding, so once per window is already
    -- about the 1 Hz the panel wants -- and one settext on one object, not
    -- ui_refresh(), which touches ~20 display objects and would spend more IPC on
    -- saying so than on the work.
    --
    -- IT IS ALSO THE STOP CHECK. Returning false aborts the run, which gives the panel
    -- an interruptible four-minute decode without a second control and without this
    -- module knowing anything about buttons. Once per window is a fine granularity for
    -- a Stop: the alternative, checking per frame, would cost a call per byte to shave
    -- a fraction of a second off a response nobody can perceive.
    if progress ~= nil then
      if progress(tot.nf, tot.nwin, nwin) == false then
        tot.stopped = 'stopped'
        break
      end
    end

    -- WHY the run ended, distinguished. 'exhausted' is not 'cap': a 32 kB run that stops at
    -- 22399 because the buffer ran out must not report the same thing as one that reached the
    -- cap, and a short read mid-stream must not read as a clean finish. tot.nsmp against ntotal
    -- already holds the fact; this puts it where ck_summary can say it.
    -- NOT 'exhausted' here: running out of samples is also how a short stream ends normally,
    -- and ck_decode cannot tell the two apart. sdec.stream() sets it, because only it knows
    -- whether the ACQUISITION filled the buffer it asked for.
    if ntotal ~= nil and off + cnt >= ntotal then break end
    if cnt < W then
      tot.stopped = 'short read'
      break
    end
    off = off + stride

    -- SUSPEND. Placed after the cursor advances and after every termination test, so a resume
    -- starts on a window that has genuinely not been decoded and a run that was ALREADY finished
    -- cannot be suspended instead of finishing -- the difference between `done` and `more to do`
    -- has to be decided by the loop's own conditions, not by whether the budget happened to run
    -- out on the last window.
    spent = spent + 1
    if slice ~= nil and spent >= slice then
      tot.suspended = {off = off, endpos = endpos, tot = tot}
      return tot, nil
    end
  end

  -- `maxbytes ~= nil` first, and not `(maxbytes or 0)`: with no cap set that reads
  -- `nf >= 0`, which is true of every run including an empty one, and every stream
  -- would report itself truncated.
  if tot.stopped == nil and maxbytes ~= nil and tot.nf >= maxbytes then
    tot.stopped = 'cap'
  end
  return tot, nil
end

-- ============================================================================
-- Sinks
-- ============================================================================
-- Accumulate into caller-supplied arrays. For a dry run, and for the offline suite,
-- where the assertion is about the bytes rather than about a file.
--
-- Positions come from `base`, not from a counter of its own. That is not a style
-- preference: base is the stream offset ck_decode has already committed to, so writing
-- at base+i makes a mis-stepped seam show up as a WRONG BYTE at a known index instead
-- of as a correctly-ordered array that is quietly one byte short.
function sdec.ck_sink_collect(vals, errs)
  return function(v, e, m, base)
    local i
    for i = 1, m do
      vals[base + i] = v[i]
      if errs ~= nil then errs[base + i] = e[i] end
    end
    return true
  end
end

-- Append to a file on the USB key, as the same hex+ASCII rows the panel and the debug
-- log use -- one format for all three, so a row can be compared across them without
-- translation.
--
-- Rows are 16 bytes and a window boundary is not a multiple of 16, so a window's
-- leftover bytes are CARRIED to the next window rather than emitted as a short row.
-- Otherwise every seam would produce a ragged row and the file's offsets would stop
-- lining up with the byte count the panel reports.
--
-- Returns the sink and a finish() that flushes the carry and closes the file.
function sdec.ck_sink_file(path, ncol)
  if ncol == nil then ncol = 16 end
  -- MODE_APPEND, not MODE_WRITE. This sink now writes to the SHARED byte log that FRAME mode
  -- also appends to, so opening for write would TRUNCATE every frame capture taken before this
  -- stream -- silently, and only visible as a byte count that went backwards.
  local fh = nil
  local ok = pcall(function() fh = file.open(path, file.MODE_APPEND) end)
  if not ok or fh == nil then return nil, nil, 'cannot append to ' .. tostring(path) end
  -- A header, so a stream's rows are distinguishable from a frame capture's in one file.
  --
  -- AND IT IS THE SINK'S FIRST WRITE, SO ITS FAILURE IS THE SINK'S FAILURE. Discarded, a header that
  -- could not be written was followed by rows that could -- appending an UNLABELLED stream into the
  -- shared byte log, indistinguishable from the frame captures around it, at whatever baud and format.
  -- That is the one thing the header exists to prevent. It also makes the sink's construction the honest
  -- place to fail: the handle is closed and the caller reports it, rather than a run that "worked" and
  -- left a file nobody can read back.
  local hok = pcall(function()
    file.write(fh, string.format('---- stream  %s %s\r\n',
               sdec.baud_text and sdec.baud_text() or '?',
               sdec.fmt_text and sdec.fmt_text() or '?'))
  end)
  if not hok then
    pcall(function() file.close(fh) end)
    return nil, nil, 'cannot write the stream header to ' .. tostring(path)
  end

  local cv, ce, cn = {}, {}, 0     -- carry: bytes not yet a full row
  local cbase = 0                  -- stream offset of cv[1]
  local dead = false

  -- nrow valid bytes across ncol columns: ua_hexrow pads the difference, so the last
  -- row of the file keeps its ASCII gutter in the same column as every other row.
  local function emit(nrow)
    local line = sdec.ua_hexrow(cv, ce, nrow, 1, ncol, cbase)
    local w = pcall(function() file.write(fh, line .. '\r\n') end)
    if not w then dead = true end
    local i
    for i = nrow + 1, cn do
      cv[i - nrow] = cv[i]
      ce[i - nrow] = ce[i]
    end
    cn = cn - nrow
    cbase = cbase + nrow
  end

  local sink = function(v, e, m, base)
    if dead then return false end
    if cn == 0 then cbase = base end
    local i
    for i = 1, m do
      cn = cn + 1
      cv[cn] = v[i]
      ce[cn] = e[i]
    end
    -- The SHARED byte-log total, so the panel's count covers streams as well as frames. Counted
    -- on ACCEPTANCE rather than on emit: a byte held in the carry is in the log's charge even
    -- though its row has not been written yet, and finish() always flushes the carry.
    sdec.flog_bytes = (sdec.flog_bytes or 0) + m
    while cn >= ncol and not dead do emit(ncol) end
    return not dead
  end

  -- IDEMPOTENT, because a chunked run has several ways to reach it and some of them can arrive
  -- twice: a job that finishes normally, a job abandoned by a Mode press, and a job whose step
  -- raised all call this, and the raise path cannot know whether the normal path already did.
  -- Closing an already-closed handle is not harmless on this firmware, and emitting the carry
  -- twice would duplicate the last row of the file.
  local finished = false
  local finish = function()
    if finished then return not dead end
    finished = true
    -- The carry flush formats through ua_hexrow, which is NOT one of the file calls guarded
    -- inside emit() -- so it can raise, and if it does the close below must still happen.
    -- AND ITS VERDICT COUNTS. Discarded, a raise formatting the LAST 1-15 bytes let finish() flush,
    -- close and return true while reporting all of tot.nf -- so the panel's byte total, which is the
    -- number backing "no decoded byte is lost", counted a row that never reached the file. emit() sets
    -- dead itself on a write failure; this catches the formatting raise the comment above describes.
    if not dead and cn > 0 then
      local eok = pcall(function() emit(cn) end)
      if not eok then dead = true end
    end
    local fok = pcall(function() file.flush(fh) end)
    pcall(function() file.close(fh) end)      -- its OWN pcall, so a flush raise cannot skip it
    fh = nil
    if not fok then dead = true end
    return not dead
  end

  return sink, finish, nil
end

-- ============================================================================
-- The TAIL of a stream, kept so the panel has something to show when it ends
-- ============================================================================
-- A streaming run's product is a FILE, and for the length of the run that is exactly
-- right: 200 kB of decoded bytes does not fit in this instrument's RAM and must not
-- try to. But the moment a run ENDS the operator is looking at a blank panel, having
-- just watched a progress percentage for twenty seconds, and the bytes are on a USB
-- key they would have to walk over to and unplug. So a BOUNDED tail is retained, in a
-- fixed-size ring whose cost is the same whether the stream was 240 bytes or 240 kB --
-- which is the property that lets this coexist with the memory argument above.
--
-- THE TAIL AND NOT THE HEAD, deliberately. A stream stopped by hand was stopped
-- because of something that had just happened; a stream that went quiet ended with the
-- device's last word; a stream that hit the cap has its most recent bytes at the cap.
-- All three put the interesting bytes at the END. (Frame mode shows the START of its
-- capture, which is not an inconsistency -- a frame capture IS its start, there is no
-- tail for it to lose.)
-- 8192 bytes = 35 pages of 240, and the whole of an 8 kB recording. It was 720 (three pages), which
-- left an 8 kB recording pageable over its last 9 % and the rest reachable only by unplugging the key.
--
-- MEASURED on the live app 2026-08-18, since the argument above rests on RAM: a Lua array of numbers
-- costs exactly 16 B per element (8192 -> 128 KiB, 16384 -> 256 KiB); the app sits at ~1470 kB of heap
-- against gcinfo()'s 2861 kB threshold; and a 256 kB array allocated and freed with the event log
-- clean. Cost here is 128 KiB for the ring plus 128 KiB for ck_tail_result()'s copy.
--
-- NOT 32768: that is 512 KiB twice over, never demonstrated allocatable. The file still holds all of it.
sdec.ck_keep = 8192

-- A fixed-size ring for the last bytes of a stream, so RAM does not grow with the run.
function sdec.ck_tail_new(cap)
  if cap == nil then cap = sdec.ck_keep end
  if cap == nil or cap < 1 then return nil end
  return {v = {}, e = {}, n = 0, w = 0, cap = cap}
end

-- Tee, not replacement: called alongside whatever sink the run already had, so the
-- file still sees every byte exactly once and a write failure still propagates.
function sdec.ck_tail_push(tl, vals, errs, m, base)
  if tl == nil or m == nil or m < 1 then return end
  -- Skip straight to the last cap bytes of an over-long batch. Without this a single
  -- window wider than the ring would write every byte and then overwrite it, which is
  -- correct but pays per-byte for bytes that cannot survive the same loop.
  --
  -- THE SKIP MUST STILL COUNT. tl.w is not a ring cursor alone -- it is the total number of
  -- bytes ever pushed, and ck_tail_result() derives the view's ABSOLUTE start from it. Skipping
  -- the loop without advancing w meant the ring held the right bytes and labelled them with the
  -- wrong offsets: cap 3 fed a batch of 5 keeps bytes 3-5 and reported first = 1. Every later
  -- push inherited the error, so a long stream's offsets drifted by however much the first
  -- oversized window skipped.
  local i = 1
  if m > tl.cap then
    i = m - tl.cap + 1
    tl.w = tl.w + (i - 1)
    tl.n = tl.cap                      -- the skipped bytes are 'seen', and the ring is now full
  end
  while i <= m do
    local j = math.mod(tl.w, tl.cap) + 1
    tl.v[j], tl.e[j] = vals[i], errs[i]
    tl.w = tl.w + 1
    if tl.n < tl.cap then tl.n = tl.n + 1 end
    i = i + 1
  end
  if base ~= nil then tl.base = base end
end

-- Linearise into the shape sdec.res has, so every existing byte-view function works on
-- it unchanged -- the hex dump, the text view, the page arithmetic. `first` is the
-- 1-based ABSOLUTE index of byte 1 of the view, which is what lets the dump label the
-- offsets truthfully instead of restarting them at zero halfway through a stream.
-- tpos is left EMPTY rather than absent: nothing in the byte views reads it, but
-- lin_decode indexes it behind a nil guard and an empty table satisfies that guard
-- while a missing key would not.
function sdec.ck_tail_result(tl, fmt, ntotal)
  if tl == nil or tl.n < 1 then return nil end
  local r = {nf = tl.n, ngood = 0, nbad = 0, nfalse = 0,
             vals = {}, errs = {}, tpos = {}}
  local start = tl.w - tl.n                 -- 0-based index of the oldest kept byte
  local i
  for i = 1, tl.n do
    local j = math.mod(start + i - 1, tl.cap) + 1
    r.vals[i], r.errs[i] = tl.v[j], tl.e[j]
    if tl.e[j] == nil then r.ngood = r.ngood + 1 else r.nbad = r.nbad + 1 end
  end
  r.first = start + 1
  r.ntotal = ntotal                         -- how many the whole run decoded
  if fmt ~= nil then
    r.nbits, r.par, r.nstop = fmt.nbits, fmt.par, fmt.nstop
    r.invert, r.framebits = fmt.invert, fmt.framebits
  end
  return r
end

-- ============================================================================
-- One call, for the app to hang a button on
-- ============================================================================
-- Prime, then decode, then finish -- with the window table allocated ONCE and shared
-- by both halves, which is the whole memory argument: prime's samples ARE the first
-- window, so nothing is held twice and there is no moment at which two 20 000-sample
-- arrays are alive.
--
-- Frame mode's capture is invalidated on the way in, not preserved. Preserving it
-- would mean holding sdec.smp alongside the window -- doubling the high-water mark
-- this whole module exists to bound -- and this mode produces a FILE, not a view, so
-- there is nothing on the panel for the previous bytes to be consistent with.
--
-- Returns totals, reason. tot.tail is the retained view (see ck_tail_result).
-- A RESUMABLE RUN, so a 37-second decode can be served 500 milliseconds at a time.
--
-- Stream mode decodes up to 32 kB, and at the measured 881 byte/s that is over half a minute
-- inside one button handler. Nothing on this instrument can interrupt that: a press is not
-- dispatched while Lua runs, presses queue, and display.waitevent() blocks indefinitely.
-- The only thing that lets a press through is the handler RETURNING -- so a long
-- decode has to be a sequence of short ones, and something has to hold the middle of it.
--
-- That something is a job. It owns the three pieces that cannot be rebuilt per slice:
--   * the SINK closure, which holds an open file handle and a partial 16-byte row in its carry.
--     Recreating it per slice would reopen the file and drop the carry.
--   * the TAIL ring, whose contents and total-pushed counter are the run's, not a slice's.
--   * the ck_decode STATE -- window cursor, seam, running totals.
-- and the format and window table, which are primed once and shared by every slice.
-- Creating a job COSTS NOTHING: priming is deferred to the first step, so the press that
-- creates one is charged for one phase rather than all of them.
function sdec.ck_job_new(reader, ntotal, path, opts)
  if opts == nil then opts = {} end
  sdec.smp, sdec.nread = nil, 0

  local win = {}
  local pr, perr = sdec.ck_prime_new(reader, ntotal, win)
  if pr == nil then return nil, perr end
  opts.win = win

  return {reader = reader, ntotal = ntotal, path = path, opts = opts,
          prime = pr, phase = pr.label, fmt = nil, sink = nil, finish = nil,
          tail = nil, state = nil, done = false, tot = nil}, nil
end

-- The sink chain, built once priming has SUCCEEDED and not before. Order matters: a recording
-- with no findable format must not have created its file first, which would leave an empty
-- numbered log on the key and spend the number on nothing.
--
-- opts.sink is an EXTRA destination, chained ahead of the file rather than replacing it. The
-- offline suite wants the bytes in an array while the shipped path writes them to the key, and
-- assigning over job.sink afterwards is not the way to get that -- it discards the tail tee
-- built below, which is fed per sink call and would then hold nothing. Both sinks see every
-- byte, and a false from EITHER stops the run.
function sdec.ck_job_sinks(job)
  local opts = job.opts
  local sink = opts.sink
  if job.path ~= nil then
    local fsink, ffin, fe = sdec.ck_sink_file(job.path, opts.ncol)
    if fsink == nil then return false, fe end
    job.finish = ffin
    if sink == nil then
      sink = fsink
    else
      local extra = sink
      sink = function(vals, errs, m, base)
        local a = extra(vals, errs, m, base)
        local b = fsink(vals, errs, m, base)
        return a ~= false and b ~= false
      end
    end
  end

  local tail = sdec.ck_tail_new(opts.keep)
  job.tail = tail
  if tail ~= nil then
    local inner = sink
    sink = function(vals, errs, m, base)
      sdec.ck_tail_push(tail, vals, errs, m, base)
      if inner == nil then return true end
      return inner(vals, errs, m, base)
    end
  end
  job.sink = sink
  return true, nil
end

-- One slice. Returns done, tot, err. `done` false means call again -- the panel should be
-- repainted and the handler returned in between, which is the entire point.
function sdec.ck_job_step(job)
  if job == nil then return true, nil, 'no job' end
  if job.done then return true, job.tot, nil end

  -- PRIMING FIRST, one phase per step. Nothing is decoded and no file is open yet, so a failure
  -- here needs none of the cleanup the decode path below does -- but it must still mark the job
  -- done, or the caller's loop would step a job with no format forever.
  if job.prime ~= nil then
    local pdone, fmt, perr = true, nil, nil
    local pok, praise = pcall(function()
      pdone, fmt, perr = sdec.ck_prime_step(job.prime)
    end)
    if not pok then pdone, fmt, perr = true, nil, tostring(praise) end
    job.phase = job.prime.label
    if not pdone then return false, nil, nil end
    job.prime = nil
    if fmt == nil then
      job.done, job.tot = true, nil
      return true, nil, tostring(perr or 'cannot prime the decode')
    end
    job.fmt = fmt
    local sok, serr = sdec.ck_job_sinks(job)
    if not sok then
      job.done, job.tot = true, nil
      return true, nil, tostring(serr or 'cannot open the log file')
    end
    job.phase = nil
    return false, nil, nil
  end

  -- THROUGH pcall, because the comment about raises closing the file was only true if something
  -- caught them. ck_decode calls out to a reader, a progress callback, an extra sink, ua_run and
  -- the tail -- any of which can raise -- and an escaping error would skip the cleanup below,
  -- leaving the USB handle open until the next power cycle and job.opts.resume pointing at a
  -- checkpoint nobody will consume.
  job.opts.resume = job.state
  local tot, terr, praise = nil, nil, nil
  local pok, perr = pcall(function()
    tot, terr = sdec.ck_decode(job.reader, job.ntotal, job.fmt, job.sink, job.opts)
  end)
  job.opts.resume = nil               -- unconditionally: a raise must not leave it set
  -- A MID-BYTE START BELONGS TO THE RUN, AND tot DOES NOT SURVIVE A STEP. ck_decode is called afresh
  -- per step with its own tot, so the headsusp it takes from the first window it emits was overwritten
  -- by every later step's first window -- the LAST step won, which is the opposite of what the figure
  -- means. job outlives the steps, so the FIRST non-nil answer is kept and handed back every time.
  if tot ~= nil then
    if job.headsusp == nil then job.headsusp = tot.headsusp end
    tot.headsusp = job.headsusp
  end
  if not pok then
    tot, praise = nil, perr
  end

  if tot == nil then
    -- A raise or refusal mid-run still has to close the file, or the handle leaks to the next
    -- power cycle and the rows already written are never flushed.
    if job.finish ~= nil then pcall(function() job.finish() end) end
    job.done, job.tot, job.state = true, nil, nil
    return true, nil, tostring(praise or terr or 'chunked decode failed')
  end

  if tot.suspended ~= nil then
    job.state = tot.suspended
    job.tot = tot                     -- partial totals, so the panel can show real progress
    return false, tot, nil
  end

  -- DONE IS SET BEFORE finish() CAN RAISE. finish() flushes the carry through ua_hexrow, which is
  -- not a guarded file call, so it can throw -- and if the job were still marked unfinished the
  -- caller's loop would step it again and re-decode windows that had already been emitted,
  -- duplicating output. The verdict is recorded after; only `done` has to be true first.
  job.done, job.tot, job.state = true, tot, nil
  tot.suspended = nil                 -- and drop the self-referential checkpoint
  if job.finish ~= nil then
    local fok = false
    local fpok = pcall(function() fok = job.finish() end)
    if not fpok or not fok then tot.stopped = 'write failed' end
  end
  tot.fmt = job.fmt
  tot.path = job.path
  tot.tail = sdec.ck_tail_result(job.tail, job.fmt, tot.nf)
  return true, tot, nil
end

-- Abandon a job that will not be finished -- a Mode press, a stop, a mode change. Closes the
-- file so the rows already decoded survive, and returns the tail so they can still be shown.
function sdec.ck_job_abandon(job)
  if job == nil then return nil end
  if job.finish ~= nil and not job.done then pcall(function() job.finish() end) end
  -- prime goes too: a job abandoned mid-priming must not be resumable, and its window table is
  -- the only thing holding 20 000 samples.
  job.done, job.state, job.prime = true, nil, nil
  local tot = job.tot
  if tot ~= nil then
    -- CLEAR THE CHECKPOINT. tot.suspended.tot IS tot, so returning it would hand back a result
    -- that both claims to be finished and carries a self-referential offer of more work -- and
    -- anything walking the table (a summary, a save, a log line) would meet the cycle.
    tot.suspended = nil
    tot.stopped = tot.stopped or 'stopped'
    tot.fmt = job.fmt
    tot.path = job.path
    tot.tail = sdec.ck_tail_result(job.tail, job.fmt, tot.nf)
  end
  return tot
end

-- The unchunked form, kept because most callers want it: run to completion in one call. Every
-- existing caller and every offline test goes through here, which is why chunking cost them
-- nothing -- with no opts.budget_s the loop runs exactly one slice.
function sdec.ck_run(reader, ntotal, path, opts)
  local job, jerr = sdec.ck_job_new(reader, ntotal, path, opts)
  if job == nil then return nil, jerr end
  local done, tot, err = false, nil, nil
  while not done do
    done, tot, err = sdec.ck_job_step(job)
  end
  if tot == nil then return nil, err end
  return tot, nil
end

-- One line for the panel and the log. Deliberately says what was CAPPED as well as
-- what was decoded: a file that stopped at the cap is a window onto a longer stream,
-- and the same reasoning that put the capture-FULL note in frame mode applies here.
function sdec.ck_summary(tot)
  if tot == nil then return 'no stream' end
  local extra = ''
  if tot.stopped == 'cap' then
    extra = string.format(' -- stopped at the %d byte cap; the stream may continue',
                          tot.nf)
  elseif tot.stopped == 'exhausted' then
    extra = ' -- the CAPTURE BUFFER ran out before the cap; sample slower for more bytes'
  elseif tot.stopped == 'short read' then
    extra = ' -- the sample source ended early; part of the capture was never scanned'
  elseif tot.stopped == 'stopped' then
    extra = ' -- STOPPED by the operator; the file holds what was decoded so far'
  elseif tot.stopped == 'sink' or tot.stopped == 'write failed' then
    extra = ' -- WRITE FAILED part-way through'
  end
  return string.format('%d bytes  %d err  %d win  %d samples%s',
                       tot.nf, tot.nbad, tot.nwin, tot.nsmp, extra)
end

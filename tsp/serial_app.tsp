-- serial_app.tsp -- lifecycle, touch handlers and capture orchestration for the
-- DMM6500 serial decoder (TSP / Lua 5.0.2).
--
-- OBJECT-LIFETIME STANDARD, applied throughout: never create over a live handle.
-- Delete -> nil -> create. Creating over a handle overwrites the only reference to
-- the old object and strands it inside the firmware until a power cycle; that
-- accumulation walks this firmware toward a PC=002F751C panic. sdec.delfails
-- counts refused deletions and is the number to watch.
--
-- There is no frame timer: decoding is single-shot -- capture, decode, show once --
-- so display writes happen only on a button press.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.delfails  = sdec.delfails or 0
sdec.fillfails = sdec.fillfails or 0
sdec.errcount  = sdec.errcount or 0
sdec.busy      = sdec.busy or false
sdec.logpath   = sdec.logpath or '/usb1/serial_decode_log.txt'
-- Prefix of THE BYTE LOG, which every mode appends to -- not just FRAME.
sdec.flogpfx   = sdec.flogpfx or '/usb1/bytes'
sdec.savepfx   = sdec.savepfx or '/usb1/serial_'
sdec.saveext   = sdec.saveext or '.txt'
-- Protocol layer sitting on top of the UART bytes: 'uart' (none), 'midi' or 'lin'.
-- Operator state, so `or` like the rest -- an App relaunch must not silently drop
-- back to raw UART on someone who selected MIDI or LIN.
sdec.proto     = sdec.proto or 'uart'
-- PRESS-DRIVEN STREAMING, AND NO LONGER WHAT THE PANEL USES. true = Capture starts a recording,
-- stops it, then steps the decode a slice per press: TWELVE PRESSES for a full buffer. false = one
-- press does the whole job.
--
-- THE ONE-PRESS PATH CANNOT BE STOPPED BY A FINGER. Both long loops poll the cancel latch -- the
-- acquisition twice a second, the decode once a window -- but a press on TRIGGER emits no blender event
-- while a panel-initiated run executes, so record_run()'s fc_maxwin/fc_maxsec bounds are the exits.
--
-- The stepped path is driven by test_cancel.lua and test_serial.lua, and is the fallback for a firmware
-- whose blender cannot latch EVENT_DISPLAY.
--
-- A NIL TEST RATHER THAN `or`, because false is meaningful here and `false or true` is true. Set it
-- before this file loads to keep it.
if sdec.strm_press == nil then sdec.strm_press = false end
-- Wall-clock ceiling on one streaming ACQUISITION, seconds; nil means no bound. A BACKSTOP, not a
-- schedule: the run normally ends at the buffer or at a quiet line, and stream_maxwait() usually bounds
-- the wait tighter than this from the sample count.
--
-- 1200 s BECAUSE THAT IS WHERE stream_maxwait ALREADY CAPS. Two bounds that disagree means the
-- smaller one is a hidden cap: at 20 s every recording slower than 9600 baud truncates, and at 600 s a
-- 300 baud run reaches 55 % of the window it promised. A full 32 kB window is 1092 s at 300 baud,
-- 273 s at 1200.
sdec.strm_maxsec = sdec.strm_maxsec or 1200
-- Seconds of signal the FALLBACK path may record when the trigger model refuses to arm. It is much
-- shorter than strm_maxsec on purpose: that path is a blocking read, so nothing can poll the cancel
-- key or the clock while it runs, and its whole length is time the panel cannot be stopped. 20 s is
-- the old uninterruptible ceiling, kept for the one case that is still uninterruptible.
sdec.strm_fallback_s = sdec.strm_fallback_s or 20
-- sdec.savedas  -- the last filename written, for the note line
-- sdec.stickyerr -- a fault that must outlive a capture (see install_cleanup)

-- Drop every trace of the previous capture, and return true.
function sdec.clear_result()
  -- CALLED AT THE TOP OF capture(), before anything can fail: acquisition can fail before
  -- decode_from() ever runs, so clearing must not depend on the decode reaching it.
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
  sdec.snapped, sdec.fitq = false, 0
  sdec.lo, sdec.hi, sdec.family = nil, nil, '?'
  sdec.vmin, sdec.vmax, sdec.wlo, sdec.whi = nil, nil, nil, nil
  sdec.thr, sdec.hyst, sdec.swing = 0, 0, 0
  sdec.ne, sdec.ei, sdec.es = 0, nil, nil
  sdec.smp, sdec.nread = nil, 0
  sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
  sdec.lasterr, sdec.savedas, sdec.probe_idle = nil, nil, nil
  -- THE MAIN EVICTION POINT FOR THE NOTE CELL. Most sources are per-capture and are cleared together
  -- here so none can latch over the others (sdec.ui_notes ranks them). The exceptions each say so:
  -- relocked below, rate_refused (retired per PRESS in capture()) and stickyerr, which must outlive a
  -- capture. Each of these three is set by a button press and must
  -- survive until the NEXT capture, then go -- a latched one puts 'auto-locked 9600' or 'left
  -- 32 kB mode' on the panel above bytes from a later capture that did no such thing.
  sdec.mode_exited, sdec.lognote, sdec.autolocknote = nil, nil, nil
  sdec.mode_exitbad = false
  -- strm_releveled IS ONE OF THEM, and it has to be evicted here for the same reason: it says THIS
  -- recording changed its own measurement basis mid-run, so latching it would put that sentence over
  -- a later capture that did no such thing. proto_why is the same: a MIDI parser that raised on one
  -- capture must not accuse the next one, which may parse perfectly.
  sdec.strm_releveled, sdec.proto_why = nil, nil
  -- relocked IS NOT EVICTED HERE, and it is the one exception in this block. clear_result() runs on
  -- every acquire(), including the RE-CAPTURE autoset() does after a rate changes -- so evicting it
  -- here wiped the note between the relock and the end of the same press, leaving correct bytes and
  -- nothing saying the operator's locked rate had been dropped. bench_break caught it as "EXACT with
  -- the forced rate silently still in force". It is cleared at the top of capture() instead: once per
  -- PRESS, which is what it describes.
  sdec.probe_note = nil                 -- set by autoset() when it had to re-capture slower
  -- The previous capture's 20 000-entry sample table has just become unreachable. Collecting it
  -- here costs 8.3 ms measured, against a 1.6 s capture, and Lua memory pressure is on the
  -- suspect list for this firmware's panics. It does NOT help the DISPLAY object pool -- those
  -- are firmware objects, which del_obj deletes explicitly.
  pcall(function() collectgarbage() end)
  return true
end

-- ============================================================================
-- Capture orchestration
-- ============================================================================
-- Pick the sample rate, capture, and decode. Returns ok, reason.
function sdec.autoset()
  local target = sdec.force_baud
  local captured = false

  -- TWO PASSES, because sample rate trades resolution against DURATION and only one of the two
  -- is knowable in advance: 1 MS/s oversamples anything up to ~125 kBd but fills the
  -- 20 000-sample buffer in 20 ms, barely 19 bytes at 9600 baud. So the first pass finds the
  -- baud at the top rate and the second re-captures at the lowest rate still giving 8 samples
  -- per bit -- 100 kS/s at 9600 baud, ten times the payload for the same buffer. A forced baud
  -- rate skips the first pass: the right rate is then known immediately.
  if target == nil then
    sdec.fs = sdec.rates[table.getn(sdec.rates)]      -- top rate: 1 MS/s
    -- THE PROBE PASS IS FREE-RUN, whatever the operator selected, and it is RETRIED.
    --
    -- Arming a trigger model here posts **4915 "attempting to store past the capacity of a
    -- reading buffer"** on the panel, ten per capture. LoopUntilEvent's pre-trigger reserve is
    -- 5 % of the buffer, which at 1 MS/s is 1.05 ms -- shorter than the wait for a falling edge
    -- on a slow line -- so the reserve wraps, and on a FILL_ONCE buffer every overwrite is a
    -- discard that posts the event. Measured at 1200 baud: 1 MS/s gives 21100 samples (the whole
    -- buffer) and 4915 x10; 10 kS/s gives 20085 (the depth asked) and none.
    --
    -- 4915 is ERROR severity and cannot be muted: localnode.showevents governs the REMOTE
    -- interface only, and the panel shows error-severity events regardless, as a modal box over
    -- the app. So the event has to not happen.
    --
    -- Raising `position` does not help either: the firmware makes post = count - count x
    -- position/100, so a reserve long enough at 1 MS/s costs two thirds of the depth.
    --
    -- Free-run has no model and no reserve, so nothing can be discarded. The cost is that a
    -- 20 ms window at 1 MS/s can land entirely inside a slow line's idle gap -- one third of
    -- the time at 300 baud -- which is what the retries are for. This pass needs only a BIT
    -- TIME, so where it starts is irrelevant; the real capture below keeps the operator's
    -- trigger setting.
    --
    -- RESTORED THROUGH pcall, so the operator's trigger setting always goes back. Restoring it
    -- only on a normal return leaves trigmode on 'free' permanently after any raise inside
    -- acquire() -- buffer.make refusing, a digitizer parameter error -- and then capture()
    -- catches the exception, the panel still says Edge, and every later capture free-runs.
    local savetrig = sdec.trigmode
    sdec.trigmode = 'free'
    local ok, why, tries = false, nil, 0
    -- EACH RETRY LOOKS FOR LONGER, by dropping the sample rate rather than repeating the same
    -- window: 20 ms, 200 ms, 2 s for the same 20 000 samples. 20 ms is less than ONE frame at
    -- 300 baud (33 ms), so identical looks at a slow line can all land in its idle stretch and
    -- the capture fails with 'line is idle (no transitions)' -- measured at 300 baud. The first
    -- look keeps the resolution a 250 kBd line needs; the slower ones only run because the
    -- faster one found nothing, which is itself evidence that the line is slow or bursty.
    local ladder = sdec.probe_fs or {1000000, 100000, 10000}
    local nlad = table.getn(ladder)
    local pok, praise = pcall(function()
      while tries < nlad do
        tries = tries + 1
        sdec.fs, sdec.fs_want = ladder[tries], ladder[tries]
        ok, why = sdec.acquire()
        if ok then
          ok, why = sdec.decode()
          if ok or sdec.baud_probe ~= nil then break end
        end
      end
    end)
    sdec.trigmode = savetrig
    if not pok then ok, why = false, tostring(praise) end
    if tries > 1 then
      sdec.probe_note = string.format(
        'probe took %d looks to catch traffic (down to %g kS/s)', tries, ladder[tries] / 1000)
    end
    if not ok then
      -- A PROBE THAT MEASURED THE BIT TIME BUT COULD NOT FRAME A BYTE IS NOT A FAILURE.
      --
      -- 20 000 samples at 1 MS/s is 20 ms: six bit times at 300 baud, sixteen at 600. The probe
      -- therefore cannot fit a ten-bit frame at the bottom of the range however clean the signal
      -- is, and passing its refusal on makes 300 and 600 baud fail with "no frame fits a 3333.5
      -- sample bit time" -- a message containing the correct answer. Measured on the instrument
      --; 1200 baud and up frame inside the window and are unaffected.
      --
      -- The retracted rate is used ONLY to choose the second pass's sample rate. That pass
      -- re-decodes from scratch and must still succeed on its own, so a bad guess here costs one
      -- capture and cannot put a wrong rate on the panel.
      if sdec.baud_probe == nil then return false, why end
      target = sdec.baud_probe
      sdec.probe_note = string.format(
        'too slow to frame at 1 MS/s -- re-captured at the rate the probe measured (%.0f Bd)',
        target)
    else
      captured = true
      target = sdec.baud
    end
    -- Only worth a second pass if a genuinely lower rate would still oversample
    -- adequately; otherwise keep the capture already in hand.
    if target == nil then return true end
  end

  local want = sdec.pick_fs(target, 8)
  -- `captured`, not `sdec.res ~= nil`. The rate already in sdec.fs is only good enough if THIS
  -- call has captured at it; with a forced baud rate the block above is skipped, so nothing has
  -- been read from the wire yet. Testing a leftover result instead lets a forced baud rate
  -- perform ZERO digitizer reads, return success, and leave the previous capture on screen.
  if captured and want >= sdec.fs then return true end

  -- fs_want, not just sdec.fs: acquire() -> hw_config() -> fs_select(), and fs_select resets the
  -- rate to fs_default when nothing is locked -- which is this path. Without fs_want every
  -- unlocked capture is 19 bytes long. See sdec.fs_select.
  sdec.fs = want
  sdec.fs_want = want
  local ok, why = sdec.acquire()
  if not ok then return false, why end
  local dok, dwhy = sdec.decode()
  if not dok then return false, dwhy end

  -- THE PROBE CAN BE AN OCTAVE OUT, AND IT COSTS HALF THE WINDOW WHEN IT IS.
  --
  -- Measured over ten identical 9600-baud captures: two fitted 19200 on the probe and so ran the
  -- real capture at 160 kS/s -- 16.6 samples/bit instead of 8.3, and 78 bytes instead of 152. The
  -- BAUD reported is 9600 either way, because this second pass re-measures it from a window ten
  -- times longer, so only the byte count shows the difference.
  --
  -- The ambiguity is inherent to the measurement: every edge interval that is a multiple of T is
  -- also a multiple of T/2, and the probe has 4 ms to work with. So the second pass's answer,
  -- better evidence by an order of magnitude, checks the rate the probe picked.
  --
  -- ONCE, AND ONLY DOWNWARD. `w2 < sdec.fs` means the correct rate needs FEWER samples per bit,
  -- i.e. a longer window: the retry can only ever increase the byte count, and a single comparison
  -- against the rate already in use cannot oscillate.
  if sdec.baud ~= nil and sdec.baud > 0 then
    local w2 = sdec.pick_fs(sdec.baud, 8)
    if w2 ~= nil and w2 < sdec.fs then
      sdec.probe_note = string.format(
        'probe fitted %.0f Bd, wire is %.0f -- re-captured at %g kS/s for the full window',
        target or 0, sdec.baud, w2 / 1000)
      sdec.fs, sdec.fs_want = w2, w2
      local ok2, why2 = sdec.acquire()
      if not ok2 then return false, why2 end
      return sdec.decode()
    end
  end
  return true
end

-- ============================================================================
-- The byte log
-- ============================================================================
-- ONE FILE, SHARED BY EVERY MODE, and SEPARATE FROM THE DEBUG LOG: ulog is a diagnostic trace
-- of notes, summaries and refusals, and interleaving the device's own messages with it makes
-- both harder to read. The name is chosen once per session, on first use, so successive
-- captures append to one file instead of scattering across numbered ones.
--
-- DECODED BYTES ONLY -- NEVER SAMPLES. That holds for every file this app writes: frame_log()
-- below, ck_sink_file()'s hex rows, and save()'s report, which records the sample RATE as
-- metadata and no sample values. A 32 kB stream is 2.8 M samples, so a text dump of them is
-- ~28 MB against 32 kB of bytes -- a thousandfold, onto a USB key, for data nothing downstream
-- can read. A waveform dump belongs behind its own control and its own filename, not in these.
-- ============================================================================
--
-- Allocate the byte log's filename. Returns the path, or nil with sdec.flog_why set.
function sdec.flog_alloc()
  if sdec.flog_path ~= nil then return sdec.flog_path end
  -- LAZY: the scan is 1000 file.open calls, and allocating at power-on would burn a filename
  -- per session whether or not anything was ever captured.
  sdec.flog_path = ulog.next_free(sdec.flogpfx, '.txt', 1000)
  if sdec.flog_path == nil then
    sdec.flog_why = 'no free ' .. sdec.flogpfx .. 'NNN.txt name -- NOT LOGGING'
    return nil
  end
  sdec.flog_n, sdec.flog_bytes = 0, 0
  return sdec.flog_path
end

-- Append one capture to the byte log: a header line, then its text lines, then its hex lines.
function sdec.frame_log()
  if sdec.res == nil or sdec.res.nf < 1 then return false end
  if sdec.flog_alloc() == nil then return false end
  local fh = nil
  local ok = pcall(function() fh = file.open(sdec.flog_path, file.MODE_APPEND) end)
  if not ok or fh == nil then
    sdec.flog_why = 'cannot append to ' .. tostring(sdec.flog_path)
    return false
  end
  -- COUNTED AFTER THE WRITE, never before. Incrementing inside the pcall lets a write that
  -- raises part-way bump flog_n and flog_bytes anyway, so the panel's "bytes in the log" counts
  -- bytes that never reached the file. The whole promise of that number is that it says what is
  -- safely on the key.
  local nfr = 0
  if sdec.res ~= nil then nfr = sdec.res.nf end
  -- The message NUMBER is needed for the header line before the write, but flog_n itself is
  -- not advanced until the write succeeds -- so a failed message does not consume a number.
  local msgno = (sdec.flog_n or 0) + 1
  local wrote = pcall(function()
    file.write(fh, string.format('---- msg %d  %s %s  %d bytes %d err\r\n',
                                 msgno, sdec.baud_text(), sdec.fmt_text(),
                                 sdec.res.nf, sdec.res.nbad))
    local i = 1
    while i <= sdec.res.nf do
      file.write(fh, sdec.ua_text_line(i, 64) .. '\r\n')
      i = i + 64
    end
    i = 1
    while i <= sdec.res.nf do
      file.write(fh, sdec.ua_hex_line(i, 16) .. '\r\n')
      i = i + 16
    end
    file.flush(fh)
  end)
  pcall(function() file.close(fh) end)
  if not wrote then
    sdec.flog_why = 'write failed part-way through ' ..
                    string.gsub(tostring(sdec.flog_path), '^.*/', '')
    return false
  end
  -- ONLY NOW do the counters move: the write returned, the file has the bytes.
  sdec.flog_n = msgno
  sdec.flog_bytes = (sdec.flog_bytes or 0) + nfr
  sdec.flog_why = nil
  return true
end

-- ============================================================================
-- Streaming capture
-- ============================================================================
-- Acquire long, then decode window by window straight to a file.
--
-- A RECORDING IS TWO PRESSES: start, then stop. stream_begin() sets everything up and arms the
-- hardware, then RETURNS; stream_stop() stops it and decodes. Between the two presses nothing of
-- ours is running, so the recording lasts as long as the operator wants and the panel stays live
-- throughout -- which is what lets the press-driven path do without a wall-clock ceiling.
--
-- WHAT THAT COSTS: the quiet-line watchdog needs Lua to be looking at the buffer, so it only
-- advances while sdec.stream() is polling. On the press-driven path a recording ends when the
-- operator ends it or when the buffer fills, never on a quiet line.
--
-- Every entry point here is guarded end to end and returns ok, reason: they are all reached from
-- a touch handler.
-- ============================================================================
--
-- Size a streaming capture, allocate its buffer, learn the levels and arm the idle watchdog.
-- Returns ok, reason, and leaves the sample count in sdec.strm_nsmp.
function sdec.stream_begin()
  local md = sdec.mode_cur()
  local why = sdec.mode_why(md)
  if why ~= nil then return false, why end
  -- Same degrade-rather-than-raise rule the protocol modules follow: chunk_decode.tsp is a
  -- separate module, so a build that omitted it must refuse with a reason rather than raise
  -- nil-index from inside a touch handler.
  if sdec.ck_run == nil then
    return false, 'this build omits chunk_decode.tsp -- the streaming modes need it'
  end

  sdec.hw_config()                      -- picks fs from the locked baud rate
  local fs = sdec.fs
  local nsmp = sdec.stream_samples(md, fs)
  if nsmp == nil then return false, 'cannot size the capture for this rate' end

  -- HEADROOM, THE SAME +100 acq_cap() ADDS AND FOR THE SAME REASON: the model can make a reading
  -- or two past `count` before abort() takes effect, and on a buffer sized exactly `count` that
  -- overshoot is a store past capacity -- **4915**, at error severity, which is a modal box over
  -- the dump that localnode.showevents cannot suppress. Measured on the armed path with no
  -- headroom: 20-30 events per capture. It costs 100 readings of the reading ceiling.
  --
  -- The capacity is the only thing that grows. SimpleLoop still asks for exactly nsmp (see
  -- stream_arm), so `have >= nsmp` remains the full-buffer ending and 100 % still means 100 %.
  local cap = nsmp + 100
  -- THE 6 000 000 READING CEILING IS FOR ALL BUFFERS TOGETHER, so buffer.make() at these sizes
  -- can need defbuffer2 shrunk first, which is what the refusal below says.
  local made = pcall(function() sdec.acq_make_buffer(cap) end)
  if not made or sdec.buf == nil then
    return false, string.format('cannot allocate %d readings -- shrink defbuffer2', cap)
  end

  -- LEARN THE LEVELS BEFORE THE LONG RECORDING: the idle watchdog needs a threshold, and
  -- capture() has just called clear_result(), which sets sdec.thr and sdec.hyst to ZERO. Same
  -- two-stage shape sdec.acquire() uses for the analog trigger, and for the same reason -- a
  -- threshold is a voltage, and the voltage is unknown until the line has been looked at. The
  -- probe reads into the buffer just allocated, so it costs no second allocation.
  sdec.ck_watch = false
  -- BOUNDED IN TIME, NOT JUST IN SAMPLES. dmm.digitize.read() blocks for pn/fs seconds and fs
  -- follows the locked baud rate: 2000 samples at 110 baud is ~1 kS/s, so an unbounded probe
  -- holds the Capture handler for about 2 s -- four times the budget, before the recording even
  -- arms. Capped at a quarter of the latency budget; the levels need only a few hundred samples
  -- of a line that is transmitting, and a probe that finds none leaves the watchdog disarmed.
  local pn = sdec.probe_n
  if pn > nsmp then pn = nsmp end
  local budget = 0.25 * (sdec.ui_latency_s or 0.5)
  local pmax = math.floor((sdec.fs or 1000) * budget)
  if pmax < 200 then pmax = 200 end
  if pn > pmax then pn = pmax end
  -- nofc: a probe must not spend a flow-control credit (see sdec.acq_free).
  local pok = pcall(function() sdec.acq_free(pn, nil, true) end)
  if pok and sdec.nread ~= nil and sdec.nread > 1 then
    local lok = sdec.sig_levels(sdec.smp, sdec.nread)
    -- ONLY ARM THE WATCHDOG IF THE LEVELS ARE REAL. An unknown threshold must never be allowed
    -- to end a recording: a capture that runs to the end of the buffer is recoverable, one
    -- truncated to five seconds of a four-minute session is not.
    if lok and sdec.thr ~= nil and (sdec.swing or 0) >= sdec.minswing then
      sdec.ck_watch = true
    end
  end
  -- THE PROBE FOUND NOTHING, WHICH IS THE NORMAL CASE FOR THE TWO RUNS THAT NEED THE WATCHDOG MOST:
  -- a device under flow control stays silent until the credit pulse leaves, and the second window
  -- of a continuous run is probed while the device waits for its next credit. So fall back to the
  -- levels the last good capture measured (sig_levels keeps them past clear_result), which exist
  -- whenever a rate was locked -- and locking a rate is already required to enter this mode.
  --
  -- Not a guess dressed as a measurement: these are measured levels, from this wire, minutes ago at
  -- most. The alternative is no watchdog, which means every window of a flow-controlled run waits
  -- out stream_maxwait instead of ending when the device stops.
  if not sdec.ck_watch and sdec.lvl_thr ~= nil and
     (sdec.lvl_swing or 0) >= sdec.minswing then
    sdec.thr, sdec.hyst, sdec.swing = sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing
    sdec.ck_watch = true
    sdec.strm_lvlreuse = true
  else
    sdec.strm_lvlreuse = nil
  end
  sdec.smp, sdec.nread = nil, 0        -- the probe's Lua copy is not needed past this point

  -- ck_stop = false HERE, on entry, is the authoritative clear -- mode_exit() can leave it set
  -- after requesting a stop the loop never got round to seeing, and no unwind path clears it.
  -- Without this line the next run aborts before its first window with 'stopped'.
  sdec.ck_running, sdec.ck_stop, sdec.ck_nbytes, sdec.ck_tot = true, false, 0, nil
  sdec.ck_endwhy = nil
  -- ck_cancel IS CLEARED HERE, not in record_run(), because EVERY run of either shape comes through this
  -- function. ck_progress() sets it on the press-driven path as well, and record_run() is not on that
  -- path -- so clearing it there would leave a cancelled run's flag set for the next press-driven
  -- recording, whose note row would then credit the TRIGGER key for a run stopped with Capture.
  -- clear_result() does not clear it either, so it would survive frame captures too.
  sdec.ck_cancel = nil
  pcall(function() sdec.progress(0) end)

  sdec.strm_nsmp = nsmp
  return true
end

-- The one-shot form: begin, poll to the end, then decode, all in one call.
function sdec.stream()
  local ok, why = sdec.stream_begin()
  if not ok then return false, why end
  local got = 0
  local aok, aerr = pcall(function() got = sdec.stream_acquire(sdec.strm_nsmp) end)
  sdec.ck_running = false
  -- FLAGGED, NOT JUST REPORTED. record_run() treats "the credited device sent nothing" as the END of
  -- a flow-controlled transmission rather than a failure, and it must not treat a write failure or a
  -- failed allocation the same way. Both arrive here as `false` plus a sentence, so the distinction
  -- has to be carried by something narrower than the return value.
  sdec.strm_empty = nil
  -- A RAISE IS NOT A QUIET LINE. `not aok or got < 2` conflated them, and strm_empty is now believed by
  -- two callers who between them turn it into a reassuring sentence: record_run() rewrites an empty
  -- window into fc_end='quiet' -- "the device stopped sending" -- and strm_exit_why() lets a cancel
  -- outrank the refusal. So a digitizer that FAULTED mid-run was reported either as the operator's
  -- device finishing tidily or, with a press latched, as "stopped with the TRIGGER key". Both are the
  -- confident wrong diagnosis this whole path exists to avoid, and the error message was discarded on
  -- top. A raise gets its own sentence and never sets the flag.
  if not aok then
    return false, 'recording failed: ' .. tostring(aerr or 'unknown')
  end
  if got < 2 then
    sdec.strm_empty = true
    return false, 'long capture returned nothing'
  end
  -- A CANCEL DURING THE RECORDING STOPS THE RECORDING, NOT THE BYTES IT COLLECTED. ck_stop is still
  -- set here, and ck_progress reads it as "abort" -- so the decode below would end at window zero
  -- and throw away everything the operator had just waited for. TRIGGER means "stop what is
  -- happening now", and what happens next is the decode of what was captured, which is exactly what
  -- the old Capture-to-stop press did.
  --
  -- NOT FOLLOWED BY A cancel_clear(). The latch auto-resets on the read that saw the press, so it is
  -- already empty -- and clearing it again would discard a SECOND press made during stream_settle(),
  -- which is exactly the operator asking to stop the decode as well. ck_cancel is deliberately left
  -- set: record_run() reads it to end a flow-controlled run, and the note row uses it to say who
  -- stopped this one.
  if sdec.ck_stop then sdec.ck_stop = false end
  return sdec.stream_decode(got)
end

-- What one press may spend under flow control. The normal ending needs no bound -- a credited window
-- that comes back quiet means the device has finished -- so THESE ARE FOR THE DEVICE THAT NEVER
-- STOPS, which would otherwise hold the panel until a power cycle.
--
-- TWO BOUNDS, BECAUSE THE WINDOW COUNT ALONE IS NOT A TIME. 32 windows is 1 MB of bytes, but each
-- window's acquisition is bounded independently at min(stream_maxwait, strm_maxsec) and the decode
-- costs more than the acquisition did -- so the count says nothing at all about the clock. Measured
-- per-window at 9600 baud: 34 s to fill the buffer, and about 109 s to decode it (bench_priming's
-- 1.6 s per 20 000-sample window over 1 365 334 samples). 32 of those is SEVENTY-SIX MINUTES, and at
-- 300 baud, where each window waits out the full 1200 s ceiling, the count alone allowed TEN AND A
-- HALF HOURS. A panel that comes back in ten hours is a power cycle in practice.
--
-- fc_maxsec IS WALL CLOCK, and it is the bound that binds. 20 minutes of it at 9600 baud is about
-- eight windows and 180 kB -- fewer bytes per press than the window count allows, deliberately.
--
-- AND UNDER FLOW CONTROL THAT COSTS NOTHING BUT A PRESS. The sender only transmits when credited, so
-- it is still waiting where the run left off: the next press picks up the same conversation and appends
-- to the same file. That is what makes a 20-minute ceiling the right trade rather than a truncation --
-- the alternative is an hour-plus hold on a panel whose operator has no idea how long is left.
--
-- THESE BOUNDS ARE THE EXIT. A press on TRIGGER emits no blender event while a panel-initiated run
-- executes, and on a firmware with no blender or no EVENT_DISPLAY cancel_pressed() answers false for
-- ever, so nothing else ends the loop. When either bound fires the note row says which.
sdec.fc_maxwin = sdec.fc_maxwin or 32
sdec.fc_maxsec = sdec.fc_maxsec or 1200

-- ONE PRESS, ONE WHOLE TRANSMISSION: record, decode and save, and under flow control keep issuing
-- credits until the device stops. Returns the run's verdict and, on a failure, its reason.
function sdec.record_run()
  -- DISCARD A LATCHED PRESS BEFORE STARTING. TRIGGER is the stop control, so the press that ended
  -- the LAST run is still sitting in the blender's latch -- nothing polls it while the panel is idle
  -- -- and without this clear it would cancel this run at its first window.
  sdec.cancel_clear()
  -- strm_empty IS CLEARED HERE TOO, not only inside stream(). stream() clears it after
  -- stream_begin() has succeeded, so a window whose begin fails early leaves the PREVIOUS run's
  -- value standing -- and the quiet test below would read a real failure as a transmission that
  -- ended tidily.
  -- ck_cancel IS ALSO CLEARED BY stream_begin(), and this line still earns its place: that clear sits
  -- past the level probe, so a first window that fails before reaching it would carry a stale flag
  -- into the exit wording.
  sdec.ck_cancel, sdec.fc_end, sdec.strm_empty = nil, nil, nil
  sdec.fc_win, sdec.fc_bytes, sdec.fc_secs = 0, 0, 0
  -- THE CLOCK IS OURS FOR THE LENGTH OF A RUN. The instrument has ONE timer, and the two other things
  -- that hold it do not overlap with a run: stream_acquire() bounds itself with a COUNTER rather than the
  -- timer, and strm_absorb_arm() stamps the moment a run ENDED, from capture(), after this function has
  -- returned. Nothing reads the timer between two windows, so the run may have it. See chunk_decode's
  -- WHY WINDOWS AND NOT SECONDS for the one place it is NOT free -- inside the decode loop.
  --
  -- fc_clock RECORDS WHETHER WE GOT IT. Offline there is no timer object at all and the pcall fails, so
  -- the counter is the whole answer -- which is what keeps the suites deterministic.
  --
  -- AND TAKING THE TIMER MEANS DISARMING THE ABSORB, because the absorb's age is stored NOWHERE ELSE.
  -- strm_stopped_by_press is only a boolean meaning "armed"; strm_absorb_arm() records WHEN by clearing
  -- this same global timer, so any unrelated reset makes an old arm look like it happened a moment ago --
  -- after which the next Capture press is swallowed as the Stop for a run that ended long before. On the
  -- panel that needs a run which re-takes the timer and then fails before re-arming, which is narrow; the
  -- same hazard bit a host tool hard, where it filed good vectors as BAD for a whole soak.
  --
  -- Safe to clear here: capture() tests the absorb at its top, so by the time this function runs the press
  -- that started it has already been offered to the absorb and declined.
  sdec.strm_stopped_by_press = nil
  sdec.fc_clock = pcall(function() timer.cleartime() end)
  -- PAINTED AFTER THE CLEAR ABOVE AND BEFORE THE FIRST WINDOW. It is the last full refresh until the
  -- run ends -- sdec.progress() repaints only the counter -- so the control cell it writes stands for
  -- the whole run, which is why it must be painted at all. That cell now reads 'no stop until it ends';
  -- it used to say 'TRIGGER key = stop', and the order mattered then because the operator must not be
  -- invited to press before a press could be seen. It invites nothing now, but the clear still belongs
  -- above it: cancel_clear() must discard the previous run's press before this run can be cancelled by
  -- anything at all.
  pcall(function() sdec.ui_refresh() end)
  local keep = nil                 -- the last window that actually decoded something
  local ok, why = false, nil
  while true do
    -- NIL'ED BEFORE THE WINDOW, NOT TESTED AFTER IT. stream_begin() nils ck_tot, but a window that
    -- fails BEFORE reaching that line leaves the PREVIOUS window's totals hanging off sdec -- and the
    -- accumulator below would then add the same bytes twice, inflating the very figure the status row
    -- publishes as the audit of "no decoded byte is lost". Nil'ed here, a non-nil ck_tot can only be
    -- this window's work. A write failure still counts its bytes: they were decoded, the note row
    -- says the file is incomplete, and the total must not quietly shrink instead of saying so.
    sdec.ck_tot = nil
    ok, why = sdec.stream()
    sdec.fc_win = sdec.fc_win + 1
    -- ACQUISITION SECONDS, accumulated across windows for the run-wide bound below. stream_acquire()
    -- publishes what it waited, including the shortened blocking fallback.
    sdec.fc_secs = sdec.fc_secs + (sdec.strm_waited or 0)
    if sdec.ck_tot ~= nil then
      sdec.fc_bytes = sdec.fc_bytes + (sdec.ck_tot.nf or 0)
      keep = sdec.ck_tot
    end
    -- ONE WINDOW UNLESS THE DEVICE IS BEING CREDITED. Without FC Out there is nothing making the
    -- sender wait, so a second window would start after the gap the decode took -- and everything
    -- sent during that gap is already gone. Looping would collect a second window of a DIFFERENT
    -- part of the conversation and file it as though it followed the first.
    if not sdec.fc_out then break end
    -- WHO ENDED THE RUN IS SETTLED BEFORE WHY THE LAST WINDOW LOOKS EMPTY, and that order is the
    -- whole point. A press lands while a window waits for credited traffic that has not arrived yet,
    -- so the window it interrupts comes back with nothing -- indistinguishable, at the return value,
    -- from the device having finished. Tested second, such a run was rewritten as 'quiet': the status
    -- row read '[quiet]' while the note row said the TRIGGER key, two cells disagreeing about who
    -- stopped it, and the [quiet] cell making exactly the confident wrong diagnosis of the operator's
    -- device that fc_credit()'s own comment says must never be made.
    --
    -- THE BYTES ALREADY FILED MAKE IT A SUCCESS, not a refusal: the operator asked it to stop and got
    -- what it had. strm_empty is what keeps that narrow -- a window that could not open its file or
    -- allocate its buffer is a failure whether or not a key was pressed, and stays one.
    if sdec.ck_cancel then
      sdec.fc_end = 'cancelled'
      if not ok and sdec.strm_empty and sdec.fc_bytes > 0 then ok, why = true, nil end
      break
    end
    if not ok then
      -- AN EMPTY WINDOW IS HOW A FLOW-CONTROLLED TRANSMISSION ENDS, not a failure. The device was
      -- credited, sent nothing, and the acquisition came back with too few samples to decode --
      -- which sdec.stream() reports as a refusal, correctly, for a single window taken on its own.
      -- Following a window that did decode, it is the end of the message.
      --
      -- strm_empty IS WHAT MAKES THAT SAFE, and fc_bytes alone would not: it would turn EVERY later
      -- failure into a success. A window that could not open its file, could not allocate its buffer, or
      -- failed a write mid-decode would be reported as a transmission that ended quietly -- with bytes
      -- counted into the total that never reached the key.
      if sdec.strm_empty and sdec.fc_bytes > 0 then
        ok, why, sdec.fc_end = true, nil, 'quiet'
      end
      break
    end
    -- CANNOT FIRE FROM THE PANEL TODAY, and kept as insurance rather than as protection. The only
    -- thing that sets ck_stop while this loop runs is cancel_asked(), which sets ck_cancel in the same
    -- call -- and that is tested above. Mode, mode_exit() and capture()'s stop branch are all touch
    -- handlers, and a touch is not dispatched while Lua runs. It costs one comparison a window and
    -- would become the exit that matters the day the firmware gains a dispatch point.
    if sdec.ck_stop then sdec.fc_end = 'stopped'; break end
    if sdec.ck_endwhy == 'quiet' then sdec.fc_end = 'quiet'; break end
    if sdec.fc_win >= (sdec.fc_maxwin or 32) then sdec.fc_end = 'bound'; break end
    -- THE BOUND THAT HOLDS. The window count is 1 MB of bytes but seventy-six minutes at 9600 baud and
    -- ten and a half HOURS at 300, so the count alone left the panel gone for most of a working day on
    -- a device that never stops -- and on a firmware without the cancel key it and this are the only
    -- exits there are.
    --
    -- THE LARGER OF THE CLOCK AND THE COUNTER, which is not belt-and-braces for its own sake. The clock
    -- is the only one that sees the DECODE, and the decode is the larger half of a window -- 109 s
    -- against 34 s of acquisition at 9600 baud, so a bound counting acquisition alone overshot by 4x.
    -- The counter is the only one that cannot be clobbered: if anything ever reads or resets the timer
    -- mid-run the reading comes back SMALL, and max() then degrades this to the acquisition sum rather
    -- than to no bound at all. Offline the clock is absent and the counter is the whole answer.
    local el = sdec.fc_secs
    if sdec.fc_clock then
      local t = nil
      pcall(function() t = timer.gettime() end)
      if t ~= nil and t > el then el = t end
    end
    if sdec.fc_maxsec ~= nil and sdec.fc_maxsec > 0 and el >= sdec.fc_maxsec then
      sdec.fc_secs = el
      sdec.fc_end = 'timebound'
      break
    end
  end
  -- THE TAIL HAS TO SURVIVE AN EMPTY LAST WINDOW. stream_begin() nils ck_tot on entry, so the
  -- window that ended the run has already wiped the totals of the window that carried the bytes --
  -- and the panel would show a finished run with nothing on it and no file named.
  if sdec.ck_tot == nil and keep ~= nil then
    sdec.ck_tot, sdec.ck_nbytes = keep, keep.nf
  end
  -- THE LOOP IS OVER, SO NOTHING IS RUNNING. capture() clears this too, but it must not be the only
  -- place: ck_running left true makes ck_status() report 'decoding...' under a finished run, and the
  -- next Capture press take the obsolete "a loop is executing" branch. A flag set by this function's
  -- callees is this function's to clear.
  sdec.ck_running = false
  return ok, why
end

-- Arm and return, for the press-driven path. The buffer fills in hardware from here.
function sdec.stream_start()
  -- THE FLOW-CONTROL COUNTERS BELONG TO A RUN, AND THIS IS THE OTHER KIND OF RUN. record_run() clears
  -- them at its entry; nothing cleared them here, so a press-driven recording inherited whatever the
  -- last one-press run left -- and since the bound wording now applies from window one rather than
  -- from window two, a normal Capture-to-stop recording would report 'reached the 20-minute limit'
  -- for a run that hit no bound at all. They cannot be cleared in stream_begin(): record_run() calls
  -- that once per WINDOW, and resetting the count there would restart it every window.
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = 0, 0, nil, 0
  local ok, why = sdec.stream_begin()
  if not ok then return false, why end
  local aok = pcall(function() sdec.stream_arm(sdec.strm_nsmp) end)
  if not aok then
    sdec.ck_running = false
    return false, 'could not arm the recording'
  end
  sdec.strm_recording = true
  return true
end

-- Stop the recording and decode what it collected.
function sdec.stream_stop()
  sdec.strm_recording = nil
  local got = 0
  local sok, serr = pcall(function() got = sdec.stream_settle() end)
  sdec.ck_running = false
  -- A SETTLE THAT RAISED IS NOT AN EMPTY RECORDING, and it must not be stamped 'stopped'. The abort or
  -- the buffer read failed, which is a fault; discarding serr and publishing the normal operator-stopped
  -- sentinel reported it as "you stopped it and it collected nothing" -- the operator blamed for a
  -- hardware failure, with the reason thrown away. Same shape as the acquisition raise in stream().
  if not sok then
    sdec.ck_endwhy = 'readfail'
    return false, 'recording failed: ' .. tostring(serr or 'unknown')
  end
  sdec.ck_endwhy = 'stopped'
  if got < 2 then return false, 'recording collected nothing' end
  return sdec.stream_decode(got)
end

-- Decode a completed recording, shared by both paths. got is the reading count it collected.
function sdec.stream_decode(got)
  local md = sdec.mode_cur()
  -- One window at a time, appended to the byte log FRAME also appends to -- not a per-run
  -- streamNN.txt. sdec.smp is released by ck_run, so the high-water mark is one window
  -- whatever the capture length.
  local path = sdec.flog_alloc()
  if path == nil then return false, tostring(sdec.flog_why) end
  -- nocap MUST BE SET EXPLICITLY, because Lua cannot tell "key absent" from "key = nil" and
  -- ck_decode reads `if maxbytes == nil and not opts.nocap then maxbytes = sdec.ck_maxbytes end`.
  -- md.cap = nil means UNLIMITED, so without nocap such a mode silently inherits the 32768
  -- default: the panel promises "no cap, until Stop or a quiet line" beforehand and reports a
  -- cap afterwards, discarding bytes already in the buffer.
  local opts = {maxbytes = md.cap, nocap = (md.cap == nil),
                progress = sdec.ck_progress}
  -- SLICED when a panel is waiting on us, whole when nothing is. budget_s is what makes each
  -- ck_job_step return inside the latency budget; the one-shot callers leave it nil and get a
  -- single call, which is what keeps the offline suite meaningful.
  if sdec.strm_press then
    -- WORK PER PRESS AND WINDOW WIDTH ARE TWO DIFFERENT BUDGETS. The width must come from
    -- ui_latency_s because every priming phase scales with it; the work per press need not.
    -- Conflating the two costs 455 presses for a full-buffer decode; ck_press_budget_s, sized at
    -- its declaration in serial_ui.tsp, brings that to 17.
    --
    -- WARNING: do not try to spend those presses inside display.waitevent(0). It reads like the
    -- answer and the instrument's own display example uses exactly that loop shape, but on
    -- 1.7.17a it BLOCKS rather than polling and WEDGES THE INSTRUMENT -- measured twice, see
    -- DMM_WAITEVENT_WEDGES_THE_INSTRUMENT in tools/instruments.py.
    opts.budget_s = sdec.ck_press_budget_s or sdec.ui_latency_s
    -- THE WINDOW IS CHOSEN FROM THE BUDGET, not fixed. Every priming phase and every decode slice
    -- is proportional to this width, so it is the one knob that makes the latency bound real --
    -- see ck_smp_us for the per-phase timings it comes from. Only the panel path narrows it: the
    -- one-shot callers have nothing to protect and want the fewest seams.
    local W = sdec.ck_win_for(sdec.ui_latency_s)
    -- KNOWN SCOPE LEAK: these two are globals and nothing restores them, so a host-driven one-shot
    -- ck_run() later in the SAME session (the else branch below) inherits the narrowed W instead of the
    -- 20000 default.
    --
    -- NOT REACHABLE FROM THE PANEL, and the reason is worth stating precisely: strm_press defaults to
    -- FALSE and nothing sets it true, so the panel takes the one-shot record_run() path and never enters
    -- this branch at all. This block, stream_start and decode_step are reachable only from a harness that
    -- sets strm_press itself -- test_cancel.lua and test_serial.lua do. The effect is decimation
    -- granularity, measured at thr 3.323 V against 3.307 V, and no wrong decode can be constructed from
    -- it. The fix is to pass W through `opts` rather than through globals, which means the three places
    -- chunk_decode reads ck_win_n.
    sdec.ck_win_n, sdec.ck_level_max = W, W
    local job, jerr = sdec.ck_job_new(sdec.ck_reader_buffer(sdec.buf, got), got, path, opts)
    if job == nil then return false, tostring(jerr or 'cannot start the decode') end
    sdec.ck_job, sdec.ck_job_md = job, md
    sdec.ck_running = true
    return sdec.decode_step()
  end
  local tot, terr = nil, nil
  local dok = pcall(function()
    tot, terr = sdec.ck_run(sdec.ck_reader_buffer(sdec.buf, got), got, path, opts)
  end)
  if not dok or tot == nil then
    return false, tostring(terr or 'chunked decode failed')
  end
  -- THE BUFFER RAN OUT BEFORE THE CAP, which is not the same as reaching the cap and must not
  -- report as [done]. '32 kB' cannot actually reach 32 kB at most rates: pick_fs snaps UP to an
  -- exact rate, so the real ratio is 8.33-16 samples/bit rather than the 8 the cap was sized on
  -- -- ~22.4 kB at 9600 baud, about 14.6 kB at MIDI's 31250.
  if tot.stopped == nil and sdec.ck_endwhy == 'full' and md.cap ~= nil and
     tot.nf < md.cap then
    tot.stopped = 'exhausted'
  end
  sdec.ck_tot = tot
  sdec.ck_nbytes = tot.nf
  -- A FILE THAT DID NOT GET WRITTEN IS NOT A SUCCESSFUL RECORDING. ck_run() returns a totals
  -- table whether or not the sink worked -- deliberately, because the bytes it decoded are still
  -- real and the tail is still worth showing -- so `tot ~= nil` is NOT the success test. Read as
  -- one, pulling the key mid-stream ends with status 'done' and a summary quoting a byte count
  -- that was never recorded anywhere. The tail stays in place either way; only the verdict moves.
  if tot.stopped == 'write failed' or tot.stopped == 'sink' then
    return false, string.format('%s -- %d bytes decoded but the file is incomplete',
                                tostring(tot.stopped), tot.nf)
  end
  return true
end

-- Decode ONE SLICE, put the progress on the status row, and hand the panel back. Returns the
-- decode's VERDICT, not its progress: true both for a slice still pending and for a clean finish,
-- false when the step raised, produced no totals, or failed its file write. Whether work REMAINS
-- is sdec.ck_job ~= nil, not this.
function sdec.decode_step()
  local job = sdec.ck_job
  if job == nil then return false end
  local done, tot, err = true, nil, nil
  local pok, perr = pcall(function() done, tot, err = sdec.ck_job_step(job) end)
  if not pok then
    done, err = true, tostring(perr)
  end

  if not done then
    sdec.ck_nbytes = (tot and tot.nf) or 0
    local est = (tot and tot.nwin_est) or 0
    -- A PRIMING PHASE HAS NO BYTE COUNT YET, and "decoding 0 bytes (window 0/0)" reads as a
    -- decode that found nothing rather than one that has not started. job.phase names the phase
    -- while priming and is nil once the format is known.
    if job.phase ~= nil then
      sdec.ui_status = string.format('preparing: %s -- press Capture', tostring(job.phase))
    else
      sdec.ui_status = string.format('decoding %d bytes (window %d/%d) -- press Capture',
                                     sdec.ck_nbytes, (tot and tot.nwin) or 0, est)
    end
    pcall(function() sdec.ui_refresh() end)
    return true
  end

  -- Finished, one way or another. From here it is the same ending the one-shot path has.
  sdec.ck_job, sdec.ck_running = nil, false
  if tot == nil then
    sdec.errcount = sdec.errcount + 1
    sdec.lasterr = tostring(err or 'decode failed')
    sdec.ui_status = 'error'
    pcall(function() ulog.line(sdec.lasterr) end)
  else
    local md = sdec.ck_job_md or sdec.mode_cur()
    if tot.stopped == nil and sdec.ck_endwhy == 'full' and md.cap ~= nil and
       tot.nf < md.cap then
      tot.stopped = 'exhausted'
    end
    sdec.ck_tot, sdec.ck_nbytes = tot, tot.nf
    if tot.tail ~= nil then sdec.res = tot.tail end
    if tot.stopped == 'write failed' or tot.stopped == 'sink' then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = string.format('%s -- %d bytes decoded but the file is incomplete',
                                   tostring(tot.stopped), tot.nf)
      sdec.ui_status = 'error'
    else
      sdec.ui_status = 'done'
    end
    pcall(function() ulog.line(sdec.ck_summary(tot)) end)
  end
  sdec.ck_job_md = nil
  -- THE VERDICT GOES WITH THE REASON, and leaving it out was a quiet defect on this path only. The
  -- one-shot caller passes ok and err; this one passed neither, so strm_exit_why's `ok == false` test
  -- could never fire here -- and a decode that returned nothing, or one whose file write failed, fell
  -- through to the acquisition's own ck_endwhy and reported 'buffer full -- the stream may continue'
  -- over a run that had just failed. lasterr holds the sentence both failure branches above wrote.
  local dok = (tot ~= nil and tot.stopped ~= 'write failed' and tot.stopped ~= 'sink')
  pcall(function()
    sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, dok, sdec.lasterr), not dok)
  end)
  pcall(function() sdec.ui_refresh() end)
  -- dok, NOT true. This is capture()'s return value, and returning true on
  -- every path made a decode that RAISED, produced no totals, or failed its file write
  -- indistinguishable from one that worked -- and from the `true` above meaning "unfinished, press
  -- again". The panel was right either way; the CALLER could not tell. Whether work remains is
  -- sdec.ck_job ~= nil, not this.
  return dok
end

-- Abandon a decode in progress -- Mode pressed, or a mode change. Closes the partial file and
-- keeps whatever was decoded, so the bytes already on the key are not lost.
function sdec.decode_abandon()
  if sdec.ck_job == nil then return false end
  local tot = nil
  pcall(function() tot = sdec.ck_job_abandon(sdec.ck_job) end)
  sdec.ck_job, sdec.ck_job_md, sdec.ck_running = nil, nil, false
  if tot ~= nil then
    sdec.ck_tot, sdec.ck_nbytes = tot, tot.nf
    if tot.tail ~= nil then sdec.res = tot.tail end
  end
  return true
end

-- Arm the trigger model and RETURN; the buffer fills in hardware from here. nsmp is the reading
-- count SimpleLoop is asked for. Returns whether the model took the configuration -- a false is
-- the caller's cue to fall back to a free-running read.
function sdec.stream_arm(nsmp)
  local buf = sdec.buf
  buf.clear()
  -- fillmode = 1 PER CAPTURE, after clear(), exactly as acq_triggered() does it: fillmode reads
  -- back 0 on a buffer that has been cleared and reused, and one FILL_ONCE capture is one burst
  -- of 4915. A recording that reaches nsmp -- its normal ending -- is precisely the case that
  -- stores at the end of the buffer.
  --
  -- NOT MUTED HERE, unlike acq_triggered(). mute_events() governs the REMOTE interface only, so
  -- it would not remove the panel's box anyway; and this call ARMS AND RETURNS, so the unmute
  -- would have to sit in stream_settle() -- which a stop press that never comes, or a mode
  -- change unwinding another way, never reaches, leaving the panel muted for every later
  -- firmware error.
  sdec.acq_fillmode(buf)
  dmm.digitize.count = 1
  local ok = pcall(function()
    trigger.model.load('SimpleLoop', nsmp, 0, buf)
    trigger.model.initiate()
  end)
  -- The pulse goes AFTER the model is armed, never before: a SimpleLoop starts filling
  -- immediately rather than waiting for an edge, so a credit sent before initiate() would have
  -- the device transmitting into a buffer that does not exist yet. One credit covers the whole
  -- capture -- from the sender's point of view a long run is a single window.
  --
  -- AFTER A SUCCESSFUL ARM, WHICH IS NOT THE SAME THING. When the load or the initiate raises there
  -- is no buffer at ANY point, so an unconditional credit tells the device to send into nothing --
  -- and stream_acquire's fallback then calls acq_free(), which issues a SECOND credit before its
  -- blocking read. Two credits spent, everything sent against the first one gone.
  if ok and sdec.fc_out then
    sdec.fc_credit()
  end
  return ok
end

-- Stop the hardware and publish what it collected. Returns the reading count.
function sdec.stream_settle()
  pcall(function() trigger.model.abort() end)
  local buf = sdec.buf
  sdec.nread = 0
  if buf ~= nil then
    sdec.nread = buf.n or 0
    sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  end
  return sdec.nread
end

-- Re-measure the levels from the newest samples in buf when the watchdog is about to end a run on
-- REUSED levels. buf holds `have` readings; iw is the window to look at. Returns true if the reused
-- threshold was wrong and a better one has been adopted, so the caller should keep going.
function sdec.strm_relevel(buf, have, iw)
  -- ONLY WHEN THE LEVELS WERE REUSED. A threshold measured from THIS capture's own probe has already
  -- seen this wire, so a quiet verdict taken with it is trustworthy and re-measuring it every second
  -- would spend the recording on second-guessing itself.
  if not sdec.strm_lvlreuse then return false end
  if buf == nil or have == nil or have < 3 then return false end
  local from = have - iw + 1
  if from < 1 then from = 1 end
  local win, m = {}, 0
  local rok = pcall(function()
    m = sdec.ck_reader_buffer(buf, have)(win, from, iw, 1)
  end)
  -- TRI-STATE, AND THE SECOND RETURN IS THE POINT. `false` from this function means "keep the reused
  -- threshold and believe the quiet verdict" -- which is right for a rejection and WRONG for a read that
  -- raised, because a failed read is ignorance, not evidence of silence. Conflated, a buffer that could
  -- not be read let the caller end the run as ck_endwhy='quiet' and report a truncated prefix as the
  -- device finishing normally. Second return true = "could not measure", and the caller must not
  -- conclude anything about the line from it.
  if not rok then return false, true end
  if m < 3 then return false, true end
  -- THE OLD THRESHOLD IS KEPT until the new levels prove it wrong, because sig_levels() overwrites
  -- sdec.thr as a side effect and a failed measurement must not leave the watchdog worse off than a
  -- reused threshold.
  --
  -- AND THE REMEMBERED LEVELS WITH IT. sig_levels() writes lvl_thr/lvl_hyst/lvl_swing on every
  -- success it makes -- deliberately, so they outlive clear_result() -- and lvl_* is the fallback
  -- stream_begin() hands the watchdog for EVERY LATER WINDOW of a flow-controlled run, because the
  -- probe is guaranteed to see an idle line while the device waits for its credit. Restoring only
  -- thr/hyst left the discarded measurement in lvl_*, so a window's quiet tail -- samples that had
  -- just been judged quiet, i.e. mostly idle -- became the threshold the NEXT window recorded
  -- against, and the accepted capture's levels were gone. That is the poisoning serial_core's own
  -- comment says the modal gate prevents; the gate covers sig_levels' refusals, not the caller's.
  local oldthr, oldhyst, oldswing = sdec.thr, sdec.hyst, sdec.swing
  local oldlo, oldhi = sdec.lo, sdec.hi
  local olvthr, olvhyst, olvswing = sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing
  local function unmeasure()
    sdec.thr, sdec.hyst, sdec.swing = oldthr, oldhyst, oldswing
    sdec.lo, sdec.hi = oldlo, oldhi
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = olvthr, olvhyst, olvswing
  end
  local lok = false
  pcall(function() lok = sdec.sig_levels(win, m) end)
  if not lok or sdec.thr == nil or (sdec.swing or 0) < sdec.minswing then
    unmeasure()
    return false
  end
  -- WRONG MEANS OUTSIDE THE SWING, not merely different. A threshold that still sits between the two
  -- levels is doing its job -- the line really has gone quiet -- and adopting a marginally different
  -- one would restart the watchdog for ever on a device that had finished. Only a threshold the
  -- current signal cannot cross explains "no activity" on a line that is transmitting.
  if oldthr ~= nil and sdec.lo ~= nil and sdec.hi ~= nil and
     oldthr > sdec.lo and oldthr < sdec.hi then
    unmeasure()
    return false
  end
  -- Adopted. Cleared so this runs ONCE per recording: the new levels came from this capture, so the
  -- next quiet verdict is judged on its own measurement rather than being deferred again.
  sdec.strm_lvlreuse = nil
  sdec.strm_releveled = string.format('threshold re-measured mid-recording: %.3f V, not the %.3f V '
                                      .. 'a previous capture measured', sdec.thr, oldthr or 0)
  pcall(function() ulog.line(sdec.strm_releveled) end)
  return true
end

-- Arm, poll until full or quiet or stopped, then settle. nsmp is the target sample count;
-- returns the reading count collected.
function sdec.stream_acquire(nsmp)
  -- POLLED, so the run can end EARLY on a quiet line. A blocking dmm.digitize.read() cannot:
  -- it returns when it has n samples, and at 1200 baud a 32 kB buffer is four and a half
  -- minutes whether the device is still talking or stopped after two seconds. So the trigger
  -- model runs the acquisition and Lua polls -- the same shape as acq_triggered(), and with the
  -- same bounded-wait discipline, because a poll loop inside a touch handler that cannot exit
  -- is an unresponsive panel needing a power cycle.
  local buf = sdec.buf
  -- WHAT THIS WINDOW SPENT, published for record_run's run-wide bound. A counter rather than a clock
  -- reading: the instrument has one timer and it is already spoken for twice (chunk_decode.tsp's WHY
  -- WINDOWS AND NOT SECONDS), so summing the poll period is the only way to bound a multi-window run
  -- without clobbering strm_maxsec or the queued-press absorb.
  sdec.strm_waited = 0
  local ok = sdec.stream_arm(nsmp)
  if not ok then
    -- FALLS BACK TO A PLAIN BLOCKING READ, which loses the early exit AND every bound with it: a
    -- blocking read cannot be polled, so neither the cancel key nor the wall-clock limit below can act
    -- while it runs. So it is SHORTENED to
    -- strm_fallback_s of signal. What is lost is length, and the note row says so; what is kept is a
    -- panel that always comes back.
    sdec.ck_endwhy = 'full'
    local fs = sdec.fs or 1000
    local cap = math.floor(fs * (sdec.strm_fallback_s or 20))
    if cap < 2000 then cap = 2000 end
    if cap > nsmp then cap = nsmp end
    if cap < nsmp then
      sdec.lasterr = string.format('trigger model unavailable; recorded %.0f s free-running '
                                   .. 'without the idle watchdog, and TRIGGER cannot stop it',
                                   cap / fs)
    else
      sdec.lasterr = 'trigger model unavailable; captured without the idle watchdog'
    end
    -- CAP THE LUA COPY TOO, separately: sdec.n bounds what is copied into Lua, because the chunked
    -- decoder reads the firmware buffer a window at a time and an unbounded copy could exhaust Lua
    -- memory. The first argument bounds the ACQUISITION; this one bounds the copy.
    --
    -- COUNTED TOWARDS THE RUN'S BOUND from the sample count, since a blocking read cannot report
    -- progress: cap/fs is what it will take, near enough, and a fallback window that went uncounted
    -- would let a run of them slip past fc_maxsec entirely.
    sdec.strm_waited = cap / fs
    return sdec.acq_free(cap, sdec.n)
  end

  local quiet, seen, step = 0, 0, sdec.ck_poll_s
  local iw = sdec.idle_window(sdec.fs)
  local waited = 0
  -- CONSECUTIVE FAILED WINDOW READS, and the reason the last one gave. Kept because a read failure must
  -- not be able to masquerade as a quiet line -- see the poll loop below.
  local rfail, rlast = 0, nil
  sdec.strm_readfail = nil
  -- BOUNDED BY WALL CLOCK AS WELL AS BY SAMPLES, and the clock is the only bound that always
  -- fires. A FRONT-PANEL PRESS IS NOT DISPATCHED WHILE A LUA SCRIPT RUNS: TSP is single-threaded
  -- and a press is delivered by the firmware EXECUTING an event string, and delay() is not a
  -- yield point at which queued events are pumped -- measured on the instrument, three presses
  -- in a row during a stream did nothing and then all arrived afterwards, each one starting
  -- ANOTHER stream. So the loop below cannot rely on sdec.ck_stop ever becoming true from the
  -- panel, and this bound is the real exit.
  --
  -- Which means every mode has to terminate BY CONSTRUCTION. A mode whose sample bound is the
  -- whole buffer (millions) and whose idle watchdog never fires on a continuously active line --
  -- a signal generator playing a looped arb is exactly that -- otherwise runs until an ABORT
  -- arrives over the LAN. With the ceiling, the run ends at the buffer, the quiet or strm_maxsec.
  local limit = sdec.stream_maxwait(nsmp, sdec.fs)
  if sdec.strm_maxsec ~= nil and sdec.strm_maxsec > 0 and limit > sdec.strm_maxsec then
    limit = sdec.strm_maxsec
  end
  -- THREE WAYS OUT, each recorded in sdec.ck_endwhy so the panel can say which:
  --   full     the buffer reached nsmp -- the cap, or as much as the instrument has
  --   quiet    no threshold crossing for sdec.idle_exit_s. The device stopped talking.
  --   stopped  the operator pressed Capture (Stop) or Mode (abort)
  while true do
    local have = buf.n or 0
    if have >= nsmp then sdec.ck_endwhy = 'full'; break end
    -- THE CANCEL LATCH IS READ HERE, twice a second against a poll costing 1.06 ms, so a blended
    -- stimulus can end the wait. A FINGER CANNOT: no blender event reaches this loop from the panel,
    -- so the bounds below remain the guarantee.
    if sdec.cancel_asked() then sdec.ck_endwhy = 'stopped'; break end
    if waited >= limit then sdec.ck_endwhy = 'full'; break end

    -- Look at the NEWEST samples only, and only once new ones exist: re-testing the same
    -- window would report the same answer and make a busy line look quiet the moment
    -- acquisition stalled for any other reason.
    if have > seen then
      local from = have - iw + 1
      if from < 1 then from = 1 end
      local win, m = {}, 0
      local rok, rerr = pcall(function()
        m = sdec.ck_reader_buffer(buf, have)(win, from, iw, 1)
      end)
      -- A READ THAT RAISED IS IGNORANCE, NOT SILENCE, so it must not advance the quiet timer. Folding it
      -- in would let idle_exit_s of failed reads produce ck_endwhy = 'quiet', and a truncated prefix would
      -- then be reported as SUCCESS with the note "the device stopped sending" -- a confident wrong
      -- diagnosis of a device that was talking the whole time. The timer may only advance on a window that
      -- was actually looked at.
      if not rok then
        rfail = rfail + 1
        rlast = rerr
        -- PERSISTENT IS DIFFERENT FROM TRANSIENT. One failed read is a blip to step over; a run of them
        -- means the buffer cannot be read at all, and continuing to the wall-clock limit would spend
        -- minutes to reach a verdict we already have. Bounded either way -- `waited >= limit` still
        -- fires -- so this only makes the failure prompt and honest instead of slow and mislabelled.
        if rfail >= 20 then
          sdec.strm_readfail = tostring(rlast or 'buffer read failed')
          sdec.ck_endwhy = 'readfail'
          break
        end
      elseif m > 1 and sdec.smp_active(win, m, sdec.thr, sdec.hyst) then
        quiet = 0
        rfail = 0
      else
        quiet = quiet + step
        rfail = 0
      end
      seen = have
    else
      quiet = quiet + step
    end

    if sdec.ck_watch and sdec.idle_exit_s ~= nil and sdec.idle_exit_s > 0 and
       quiet >= sdec.idle_exit_s then
      -- A QUIET LINE JUDGED WITH REUSED LEVELS IS CHECKED BEFORE IT IS BELIEVED. The threshold may be
      -- from a capture taken at a different probe point or before a divider went in, and a threshold
      -- outside the CURRENT swing sees no crossings at all -- so a device transmitting happily looks
      -- silent and the run ends in idle_exit_s with a confident wrong reason. sig_levels() needs no
      -- threshold to find the levels, so the samples already in the buffer can settle it.
      local adopted, unmeasurable = sdec.strm_relevel(buf, have, iw)
      if adopted then
        quiet = 0
      elseif unmeasurable then
        -- THE CHECK ITSELF COULD NOT BE MADE, so the quiet verdict is unearned. Ending the run 'quiet'
        -- here reported a device that may well have been talking as one that had finished -- and this is
        -- the LAST gate before that verdict, so it is the one that must not guess.
        sdec.strm_readfail = 'the capture buffer could not be re-measured to confirm a quiet line'
        sdec.ck_endwhy = 'readfail'
        break
      else
        sdec.ck_endwhy = 'quiet'
        break
      end
    end

    -- YIELDS AT ck_poll_s rather than busy-waiting, because delay() is what lets the display
    -- update at all. Nothing in the loop may be long: one settext plus at most 4000 proxy reads
    -- per pass is a few tens of milliseconds against a 500 ms sleep.
    pcall(function() sdec.progress_samples(have, nsmp) end)
    delay(step)
    waited = waited + step
    sdec.strm_waited = waited
  end

  return sdec.stream_settle()
end

-- Poll period. Two per second is well inside the 1 Hz display budget and keeps the progress
-- counter moving without spending measurable time on it.
sdec.ck_poll_s = 0.5

-- A hard ceiling on the wait for nsmp samples at fs, seconds: twice the theoretical fill time,
-- floored at 10 s and capped at 1200.
function sdec.stream_maxwait(nsmp, fs)
  if fs == nil or fs <= 0 then return 600 end
  -- INDEPENDENT OF THE IDLE WATCHDOG, which is only armed when the level probe found real
  -- levels -- so on a line whose levels could not be measured this is the only exit left.
  local t = 2 * nsmp / fs
  if t < 10 then t = 10 end
  if t > 1200 then t = 1200 end
  return t
end

-- Show acquisition progress on the mode row: have of want samples.
function sdec.progress_samples(have, want)
  -- ON THE STATUS ROW, IN SAMPLES, NOT BYTES: nothing has been decoded yet, so a byte count is fiction.
  -- Percent of the buffer is the honest number and the one the operator wants while waiting.
  sdec.ck_acq_have, sdec.ck_acq_want = have, want
  return pcall(function() sdec.progress_row() end)
end

sdec.ck_bufmax = 2800000     -- readings; raise once the real ceiling is measured
-- Samples to record for mode md at sample rate fs. Returns nil when the rate or the locked baud
-- rate cannot size a capture.
function sdec.stream_samples(md, fs)
  if fs == nil or fs <= 0 then return nil end
  local baud = sdec.force_baud
  if baud == nil or baud <= 0 then return nil end
  -- A BYTE-CAPPED MODE'S SAMPLE COUNT FOLLOWS FROM THE FORMAT: md.cap bytes at
  -- framebits*(fs/baud) samples each. md.cap = nil takes whatever the buffer allows. Both are
  -- clamped to sdec.ck_bufmax, so a mode cannot ask for more than the instrument has.
  if md.cap == nil then return sdec.ck_bufmax end
  -- 8N1 unless a width is forced; the cap is a byte count, so a wider frame simply needs
  -- more samples for the same bytes.
  local nbits = sdec.force_nbits or 8
  local parbits = 0
  if sdec.force_par ~= nil and sdec.force_par ~= sdec.PAR_NONE then parbits = 1 end
  local framebits = 1 + nbits + parbits + (sdec.force_nstop or 1)
  local n = math.ceil(md.cap * framebits * (fs / baud))
  if n > sdec.ck_bufmax then n = sdec.ck_bufmax end
  if n < 100 then n = 100 end
  return n
end

-- ck_decode's progress hook: show nbytes decoded in window nwin of nwin_est, and return false
-- to abort the run.
function sdec.ck_progress(nbytes, nwin, nwin_est)
  -- ONE settext PER WINDOW is already about 1 Hz, because a window is a few hundred
  -- milliseconds of decoding.
  sdec.ck_running = true
  pcall(function() sdec.progress(nbytes) end)
  -- FALSE aborts the run. Explicit rather than falling out of pcall's return value, which
  -- would make a failed settext look like a Stop press.
  if sdec.ck_stop then return false end
  -- AND THIS IS WHERE A LONG DECODE BECOMES CANCELLABLE. One window is the cancel granularity for
  -- the same reason it is the progress granularity: it is the only point at which this module gets
  -- control, and at ~0.96 s for a full-width window it already meets "answers within a second".
  -- Checking per FRAME instead would cost a poll per byte to shave off a delay nobody can perceive.
  if sdec.cancel_asked() then return false end
  return true
end

-- Poll the TRIGGER key and record it as a stop request. True once a cancel is in force, INCLUDING
-- one seen by an earlier poll -- the blender's latch auto-resets on read, so a caller that polled
-- twice and expected the same answer would lose the press.
function sdec.cancel_asked()
  if sdec.ck_stop then return true end
  if not sdec.cancel_pressed() then return false end
  sdec.ck_stop = true
  -- SEPARATE FROM ck_stop, because they answer different questions. ck_stop is "wind up", which
  -- Mode and mode_exit() also set; ck_cancel is "the operator pressed TRIGGER", which is what the
  -- note row and the summary need in order to say who ended the run.
  sdec.ck_cancel = true
  return true
end

-- THE TWO ANSWERS TO A REFUSED FORCED RATE. sdec.decode() publishes sdec.rate_offer when the locked
-- rate is proved wrong, and refuses rather than substituting a rate nobody chose; these are how the
-- offer is answered. Both are ORDINARY FUNCTIONS with no display or event dependency, which is what
-- makes the behaviour testable with no human at the panel -- the bench drives them over SCPI and the
-- offline suite calls them directly. A future dialog is a view over the same two calls.
--
-- Each returns ok, reason, and refuses politely when there is nothing outstanding, so a stale press or
-- a repeated remote call cannot act on an offer that has already been answered.

-- USE THE DETECTED RATE. Clears the lock instead of writing the detected number into it: detection
-- found this rate unaided and will find it again, whereas locking the number freezes one measurement
-- and would mislead the next capture on a different line. This is the same state typing 0 into
-- Options > Baud produces, reached in one call.
function sdec.rate_accept()
  if sdec.rate_offer == nil then return false, 'no rate was offered' end
  sdec.force_baud = nil
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  return sdec.capture()
end

-- KEEP THE RATE THE OPERATOR SET. The question goes; the lock and the refusal both stand, so the panel
-- does not fall back to looking like an ordinary empty capture with nothing to explain it.
function sdec.rate_decline()
  if sdec.rate_offer == nil then return false, 'no rate was offered' end
  local why = sdec.rate_refused
  sdec.rate_offer, sdec.rate_offer_from = nil, nil
  return true, why
end

-- The Capture button handler: start a capture, or stop or step one already in progress. Fully
-- guarded, and returns a verdict rather than raising.
function sdec.capture()
  -- EVERY FAILURE BELOW COMES BACK AS A MESSAGE ON THE PANEL, which is what the pcalls are for:
  -- a touch handler that raises leaves a dead button and no explanation.
  --
  -- NOT when a press-driven run is live: those have their own three-way dispatch below, and this
  -- branch would swallow the press that is meant to stop the recording or step the decode. It
  -- remains for the one-shot sdec.stream() path, where ck_running really does mean "a loop is
  -- executing and all a press can do is ask it to stop".
  if sdec.ck_running and not sdec.strm_recording and sdec.ck_job == nil then
    -- A STOP REQUEST THAT WENT UNANSWERED PROVES THERE IS NO RUN TO ANSWER IT.
    --
    -- ck_stop is a request to a loop that polls it, and a loop clears ck_running when it
    -- unwinds. So arriving here a SECOND time with ck_stop already true means the first
    -- request was never seen: nothing is executing, and ck_running is a latch left behind by a
    -- run that died -- an ABORT over the LAN, or an error escaping a path that is not pcall'd.
    --
    -- Clearing it is the only way out from the panel. Left latched, every Capture press returns
    -- here, Mode cannot clear it either, and the instrument needs a power cycle. A flag that can
    -- only be set by a fault must not be the thing that refuses the fix.
    if sdec.ck_stop then
      sdec.ck_running, sdec.ck_stop = false, false
      -- stickyerr, not lasterr: this capture carries on, and whatever it concludes will overwrite
      -- lasterr before the operator ever reads it. A fault has to outlive the press that found it.
      sdec.stickyerr = 'a previous run did not finish (aborted?) -- run flag cleared'
      pcall(function() ulog.line(sdec.stickyerr) end)
    else
      sdec.ck_stop = true                 -- second press during a stream = Stop
      sdec.ui_status = 'stopping'
      return pcall(function() sdec.ui_refresh() end)
    end
  end

  -- ABSORB THE STOP PRESS THAT ARRIVES AFTER THE STREAM IT WAS MEANT TO STOP.
  --
  -- The branch above is nearly unreachable from the front panel, for a firmware reason rather
  -- than a fault here: a press is NOT dispatched while a Lua script runs, and presses QUEUE.
  -- display.waitevent() is no help -- it waits on a display.prompt() dialog and returns
  -- BUTTON_YES/NO/OK/CANCEL, it is not a poll of this screen's buttons. So the operator who
  -- presses Capture to stop a stream is heard only once the run has already ended by itself,
  -- and the press lands HERE, as a fresh capture.
  --
  -- Which, since a finished stream leaves its bytes on screen, would clear_result() them
  -- immediately -- bytes appear, then vanish, which is worse than never showing them. So a press
  -- inside the absorb window is spent on what the operator was asking for: the run is over, the
  -- bytes stay up, and the note row says the press was taken as the Stop. EVERY press in the
  -- window, not just the first -- see sdec.press_absorbed().
  if sdec.press_absorbed('Capture') then return true end
  -- ONCE PER PRESS, not per acquire(): see clear_result(). A relock inside this press must still be on
  -- the note row when the press returns, however many internal re-captures happen after it.
  sdec.relocked = nil
  -- THE RATE OFFER IS ALSO PER PRESS, and for the opposite reason to relocked: it must OUTLIVE the
  -- press that raised it, because the operator answers it afterwards. Pressing Capture again is an
  -- answer of its own -- a fresh capture supersedes the question -- so it is retired here rather than
  -- in clear_result(), which runs on every internal re-capture.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  -- BUSY ON ENTRY MEANS A PREVIOUS RUN DIED, not that one is in progress. A second press cannot
  -- arrive during a capture -- a front-panel press is not dispatched while a Lua script runs, and
  -- presses queue until the handler returns -- so the only way this flag is still set is that a
  -- previous run never reached its `busy = false`: an ABORT over the LAN, or an error escaping a
  -- path that is not pcall'd.
  --
  -- Refusing here would make that permanent: every later Capture press would return immediately,
  -- the panel would look dead, and nothing would say why. So it is recorded, so the operator
  -- sees it once, and cleared. A latch that can only be set by a fault must not be the thing
  -- that refuses the fix.
  if sdec.busy then
    sdec.lasterr = 'previous capture did not finish (aborted?) -- starting a new one'
    pcall(function() ulog.line(sdec.lasterr) end)
  end
  sdec.busy = true

  -- ----------------------------------------------------------------------------
  -- THE PRESS-DRIVEN STREAMING PATH: nothing here holds the panel over the budget.
  -- ----------------------------------------------------------------------------
  -- ONE START BUTTON FOR BOTH CAPTURE MODES -- see sdec.ui_modes -- so in a streaming mode
  -- Capture means one of three things, and which one is never ambiguous because each is a
  -- different state of the same run:
  --
  --   no run          START recording. Arms the hardware and returns; the buffer fills with no
  --                   Lua running at all, so the panel stays live for the whole recording.
  --   recording       STOP recording, and decode the first slice.
  --   decoding        decode the NEXT slice.
  --
  -- A long capture is therefore interruptible from the panel without a control of its own.
  local md = sdec.mode_cur()
  if not md.view and sdec.strm_recording then
    local sok, swhy = false, nil
    local pok, perr = pcall(function() sok, swhy = sdec.stream_stop() end)
    sdec.busy = false
    if not pok or not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(perr or swhy or 'recording failed')
      sdec.ui_status = 'error'
      pcall(function() ulog.line(sdec.lasterr) end)
      pcall(function() sdec.mode_exit('recording failed', true) end)
    end
    pcall(function() sdec.ui_refresh() end)
    return sok
  end

  if sdec.ck_job ~= nil then
    sdec.busy = false
    return sdec.decode_step()
  end

  if not md.view and sdec.strm_press then
    -- START a recording and return. sdec.strm_press is what selects the press-driven path over
    -- the one-shot sdec.stream(); the one-shot form is kept for the host harnesses and the
    -- offline suite, which have no panel to protect.
    sdec.clear_result()
    local sok, swhy = false, nil
    local pok, perr = pcall(function() sok, swhy = sdec.stream_start() end)
    sdec.busy = false
    if not pok or not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(perr or swhy or 'could not start recording')
      sdec.ui_status = 'refused'
      pcall(function() ulog.line(sdec.lasterr) end)
      pcall(function() sdec.mode_exit(sdec.lasterr, true) end)
    else
      sdec.ui_status = 'recording -- press Capture to stop'
    end
    pcall(function() sdec.ui_refresh() end)
    return sok
  end

  if not md.view then
    -- STREAMING: produces a file, not a view, so the panel shows progress and a summary.
    sdec.clear_result()
    sdec.ui_status = 'capturing'
    -- SET BEFORE THE REFRESH, so the control cell says 'no stop until it ends' for the whole run. Only
    -- this refresh paints that cell -- sdec.progress() writes the counter and nothing else -- and
    -- ck_running does not become true until stream_begin() is already inside the job, so without a
    -- flag of its own the cell would read 'Mode=Exit to FRAME' throughout a run Mode cannot exit.
    sdec.strm_inflight = true
    -- NO REFRESH HERE. record_run() paints, immediately after it clears the cancel latch. Without a flag
    -- of its own the cell falls through to the log status (serial_ui.tsp:2443) and says nothing about a
    -- run that cannot be stopped. One refresh, in record_run(), is the right shape.
    local sok, swhy = false, nil
    -- THE WHOLE JOB, IN THIS ONE PRESS: record, decode, save, and under flow control repeat until
    -- the device stops. It holds the panel for as long as that takes, AND NOTHING CAN CUT IT SHORT --
    -- this comment used to say the hold "is only acceptable because TRIGGER stops it", and that premise
    -- was measured false on: the key emits no blender event while this runs. The bounds in
    -- record_run() (fc_maxwin, fc_maxsec) are therefore the only exits, not a backstop to a cancel.
    local pok, perr = pcall(function() sok, swhy = sdec.record_run() end)
    sdec.strm_inflight = nil
    sdec.busy, sdec.ck_running = false, false
    if not pok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = 'stream raised: ' .. tostring(perr)
      sdec.ui_status = 'error'
      pcall(function() ulog.line(sdec.lasterr) end)
    elseif not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(swhy)
      sdec.ui_status = 'refused'
      pcall(function() ulog.line('stream refused: ' .. tostring(swhy)) end)
    else
      sdec.ui_status = 'done'
      pcall(function() ulog.line(sdec.ck_summary(sdec.ck_tot)) end)
      -- EVERY RECORDING LEAVES THE BYTES IT KEPT ON SCREEN, paged with the same two buttons as a
      -- frame capture, and the file on the key holds everything the tail does not. The mode does not
      -- change -- mode_exit() is a flush -- so the next Capture records another window; press_absorbed()
      -- is what stops a queued press doing that by accident.
      if sdec.ck_tot ~= nil and sdec.ck_tot.tail ~= nil then
        -- No separate "this is a stream tail" flag: the view carries `first` and `ntotal`,
        -- so ui_notes() can tell a tail from a frame capture by looking at the view itself,
        -- and clear_result() drops it at the start of the next capture like any other result.
        sdec.res = sdec.ck_tot.tail
      end
    end
    -- LEAVING THE MODE HAPPENS ON EVERY OUTCOME, not just the successful one. Inside the `else`
    -- above it would miss exactly the cases that matter -- a refused stream, a raise out of the
    -- acquisition, a decode that could not allocate -- each of which leaves capmode set to a
    -- mode with no flush behind it -- flog_path still set, the log still open, the note row silent.
    -- The verdict and the message differ per outcome; the flush does not.
    pcall(function()
      sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, sok, sdec.lasterr), not sok)
    end)
    pcall(function() sdec.ui_refresh() end)
    -- ARMED LAST, after mode_exit()'s USB flush and the repaint: the window is 1 s from the moment it
    -- is armed, so arming above them spends part of it before the handler even returns.
    --
    -- ON EVERY OUTCOME. A raise and a refusal held the interpreter just as long, so they have the same
    -- queue of presses behind them.
    sdec.strm_absorb_arm()
    return sok, swhy
  end

  -- THE FRAME PATH OWNS THE PANEL FROM HERE, so the streaming summary goes.
  --
  -- ck_tot and ck_nbytes describe the last STREAM: while they are set, the status row shows the
  -- stream's counter and file instead of the frame row, the BYTES cell shows the stream total,
  -- and the note row says the dump is a prefix of that stream. All three are correct for a
  -- stream whose bytes are still on screen, and all three are wrong the moment a frame capture
  -- replaces them -- BYTES reads 389 over a 159-byte dump, and the note names a file that does
  -- not hold what is showing. Cleared here rather than in clear_result(), which the streaming
  -- path also calls and which would then evict the summary a stream needs to display.
  sdec.ck_tot, sdec.ck_nbytes = nil, nil
  -- The multi-window counters go with them, for the same reason: they describe the recording whose
  -- summary is being evicted, and a stale one would put '3 windows' on a frame capture.
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = nil, nil, nil, nil
  sdec.clear_result()
  sdec.ui_status = 'capturing'
  pcall(function() sdec.ui_refresh() end)

  local ok, why = false, nil
  local pok, perr = pcall(function() ok, why = sdec.autoset() end)
  sdec.busy = false

  if not pok then
    sdec.errcount = sdec.errcount + 1
    sdec.lasterr = 'capture raised: ' .. tostring(perr)
    sdec.ui_status = 'error'
    ulog.line(sdec.lasterr)
  elseif not ok then
    sdec.errcount = sdec.errcount + 1
    -- A capture that found nothing is the normal result of probing a quiet pin,
    -- so it is reported as a reason, not as a fault.
    if sdec.lasterr == nil then sdec.lasterr = tostring(why) end
    sdec.ui_status = 'no decode'
    ulog.line('no decode: ' .. tostring(why))
  else
    sdec.ui_status = 'done'
    sdec.ui_page = 0
    -- ONE pcall EACH, not one around all three. summary(3) formats sdec.fitq and (acq_fs or fs)
    -- through %.2f and %.0f, and arithmetic on a nil raises, so a raise in summary(2) must not be
    -- able to cost summary(3). The three are independent facts about the capture -- format,
    -- levels, byte count -- and a log missing the middle line is more useful than one missing the
    -- last two, let alone a dead Capture button with nothing on the panel to explain it.
    pcall(function() ulog.line(sdec.summary(1)) end)
    pcall(function() ulog.line(sdec.summary(2)) end)
    pcall(function() ulog.line(sdec.summary(3)) end)
    -- Parse the protocol layer HERE, not lazily when the view opens, so the log records the
    -- messages belonging to the capture that produced them -- and before the notes, so a note
    -- the parse produces (the LIN break count) is in the list.
    --
    -- BOTH UNDER pcall, because this is the SUCCESS path of a touch handler and both reach
    -- into other modules: proto_parse walks sdec.ui_views and calls a parser, ui_notes calls
    -- four note sources. A raise here would take out the Capture button on a capture that had
    -- ALREADY SUCCEEDED. Logging is a courtesy; it must not be able to cost the decode.
    pcall(function() sdec.proto_parse() end)
    -- BEFORE the notes are gathered, so the auto-lock note is one of them, and under pcall
    -- like everything else on this success path: locking is an optimisation for the NEXT
    -- capture and must never be able to retract one that already worked.
    pcall(function() sdec.autolock_try() end)
    pcall(function()
      -- EVERY note, not just the one the panel has room for. The cell shows the most
      -- important and counts the rest; this is where the rest become recoverable.
      local nt, nn = sdec.ui_notes()
      local ni
      for ni = 1, nn do ulog.line('note: ' .. nt[ni]) end
    end)
    -- The whole capture goes to the log as a hex dump: the panel shows one page,
    -- the file keeps everything and can be read on a computer afterwards.
    if sdec.res ~= nil then
      local i, per = 1, 16
      while i <= sdec.res.nf do
        ulog.line(sdec.ua_hex_line(i, per))
        i = i + per
      end
    end
    -- FRAME+LOG: also append this message to its own file. Under pcall like everything else
    -- on this success path -- a full USB key must not retract a capture that worked.
    if md.log then pcall(function() sdec.frame_log() end) end
  end

  pcall(function() sdec.ui_refresh() end)
  return ok
end

-- ============================================================================
-- Auto-lock
-- ============================================================================
-- LOCK THE WIRE PARAMETERS AS SOON AS THEY ARE KNOWN CONFIDENTLY, and the case for it is
-- measured rather than a matter of convenience. A capture with the format UNKNOWN costs the
-- format search, measured at the bench as 0.93 to 1.17 s against 0.076 to 0.096 s to frame a
-- known format -- twelve times, and more than the acquisition itself at every rate above 9600.
-- On top of that, autoset() takes a WHOLE EXTRA CAPTURE at the top sample rate purely to find
-- the baud rate. So an auto-detecting capture is roughly two captures plus a search where a
-- locked one is a single capture plus framing: the second press onward runs about three times
-- faster for exactly the same bytes.
--
-- It also does something the operator cannot get any other way: the streaming mode REQUIRES a
-- locked rate (mode_cur().needbaud), so until something locks, that mode is unreachable. Locking
-- on the first successful capture makes it reachable after one press rather than after finding
-- the padlock.
--
-- The streaming modes REQUIRE a locked rate (needbaud), so until something locks, Capture in them
-- refuses -- locking on the first successful capture makes them usable after one press rather than
-- after finding the padlock.
--
-- THE GATES ARE THE WHOLE DESIGN. Locking a WRONG detection is far worse than not locking,
-- because it turns a one-capture mistake into a persistent one. The five gates in autolock_try()
-- are independent -- timing, framing, sample size, fit quality and baseline stability -- which is
-- the property that matters; five correlated checks would be one check.
-- ============================================================================
sdec.autolock_min  = 8      -- frames required before a detection may be locked
-- Fraction of the capture that must be ONE unbroken correctly-framed run. 0.6 rather than
-- something near 1.0 because the auto-detect capture is the shortest one the app takes -- at
-- the top sample rate a 9600-baud line yields ~17 frames -- and head resync plus tail clipping
-- can account for a handful of them. Measured captures gave longest runs of 12 of 17, i.e.
-- 0.71, so 0.6 leaves margin without being a formality.
sdec.autolock_run  = 0.6
sdec.autolock_fitq = 0.9    -- least-squares fit quality required
-- Operator state, so `or`/nil-test like the rest: someone who turned this off must not find it
-- back on after an App relaunch. ON by default, so the fast streaming-capable state is what the
-- instrument reaches by itself.
if sdec.autolock == nil then sdec.autolock = true end

-- Suppress auto-lock for the NEXT capture only. Returns true.
function sdec.autolock_defer()
  -- AN EXPLICIT REQUEST FOR AUTO-DETECT MUST SURVIVE THE CAPTURE THAT FOLLOWS IT. Called
  -- wherever the operator asks for auto-detect -- Options with Baud Rate 0, the Auto button,
  -- unlocking the padlock, leaving MIDI or LIN -- and consumed by the next autolock_try().
  -- Without it: the operator clears the forced rate, the same press re-captures, auto-lock
  -- locks the rate it has just detected, and the padlock they were watching goes straight back
  -- to green -- the request honoured for the duration of one function call.
  --
  -- ONE capture of grace, not permanent suppression, because the request was "detect it", not
  -- "never lock again": the detect happens, its result is shown unlocked, and the press AFTER
  -- that locks and says so. It is also what makes changing the device under test work -- unlock,
  -- capture to see what the new line is, lock in on the next press.
  sdec.autolock_skip = true
  return true
end

-- Lock the detected rate if the capture is good enough to trust. Returns whether it locked.
function sdec.autolock_try()
  if not sdec.autolock then return false end
  if sdec.autolock_skip then
    sdec.autolock_skip = nil
    return false
  end
  if sdec.force_baud ~= nil then return false end       -- already locked, nothing to do
  local r = sdec.res
  if r == nil or sdec.baud == nil then return false end
  -- GATE 1, SNAPPED: the baud rate matched a standard rate within snaptol rather than being
  -- whatever fs/bittime came to. A real line runs at a real rate.
  if not sdec.snapped then return false end
  -- GATE 2, THE LONGEST CONTIGUOUS CLEAN RUN -- not an error count, and not an error POSITION.
  -- What justifies locking a format is that the format explains a long unbroken stretch of the
  -- capture. That tolerates head resync and tail clipping without having to guess where they are
  -- allowed to be, and it is strictly harder to satisfy by accident than a small error count:
  -- scattered errors, which is what a wrong format gives, leave no long run however few of them
  -- there are.
  local best, cur, i = 0, 0, nil
  for i = 1, r.nf do
    if r.errs[i] == nil then
      cur = cur + 1
      if cur > best then best = cur end
    else
      cur = 0
    end
  end
  if best < sdec.autolock_min then return false end
  if best < sdec.autolock_run * r.nf then return false end
  -- GATE 3: enough frames that agreement means something. Two clean frames of noise agree with
  -- each other too.
  if (r.ngood or 0) < sdec.autolock_min then return false end
  -- GATE 4: the least-squares bit time explained the pulse widths it was fitted to.
  if (sdec.fitq or 0) < sdec.autolock_fitq then return false end
  -- GATE 5, AND THE ONE THAT IS ABOUT THE SIGNAL RATHER THAN THE DECODE. An unstable baseline --
  -- too few samples sitting at a logic level, i.e. drift or noise -- is precisely when a
  -- confident-looking lock is least deserved: the four checks above all describe how
  -- self-consistent this ONE capture was, and a marginal line can be self-consistent by luck.
  -- Locking there carries the luck forward into every later capture.
  --
  -- Guarded on existence because sig_levelwarn lives in serial_core and this is the app layer.
  if sdec.sig_levelwarn ~= nil and sdec.sig_levelwarn() ~= nil then return false end

  -- ONLY THE FIELDS THE OPERATOR LEFT ON AUTO. Assigning all four unconditionally overwrites a
  -- hand-forced parity, width or stop count with whatever this capture happened to detect: a
  -- setting chosen in Options then survives exactly one capture, and the form reads the detected
  -- value back as though it had been chosen. The guard above only catches a forced BAUD, because
  -- that is the field that makes the second pass unnecessary; the other three are independent and
  -- have to be checked one at a time.
  --
  -- The rate is locked either way, so forcing parity does not cost the operator the speed win.
  sdec.force_baud   = sdec.baud
  if sdec.force_nbits == nil then sdec.force_nbits = r.nbits end
  if sdec.force_par   == nil then sdec.force_par   = r.par end
  if sdec.force_nstop == nil then sdec.force_nstop = r.nstop end
  -- POLARITY IS DELIBERATELY NOT LOCKED, and this is the one asymmetry in the set.
  --
  -- Left nil, decode_from() falls back to `inv = (sdec.idle == 0)` -- the level-based physical
  -- inference -- and skips the polarity contest entirely. Locked, it freezes whatever the contest
  -- decided on the DETECT capture, which is the shortest and least evidenced one the app takes:
  -- that pass runs at the top sample rate, so at 9600 baud it holds ~18 frames rather than ~240.
  --
  -- Measured on the instrument: the detect capture flipped to inverted, auto-lock
  -- froze it, and every capture afterwards was confidently wrong at 227 frames and zero errors.
  -- Baud rate and frame shape are worth locking because re-deriving them costs the whole extra
  -- capture and the format search; polarity costs one comparison per capture, and is the only
  -- one of the five the contest gets wrong.
  sdec.force_invert = nil

  -- NAMES THE PAYOFF, not just the fact: the next press behaves differently -- lower sample
  -- rate, longer window, more bytes -- and the window size is the number the operator cares
  -- about, so it is computed here rather than left to be noticed.
  --
  -- SIZED TO FIT THE NOTE CELL: 685 px at the widest field values against the cell's 700
  -- (sdec.ui_note_px). ui_fit() clips gracefully, but a note that is always clipped is a note
  -- whose tail is never read.
  local fs = sdec.fs_for_baud(sdec.force_baud)
  local nb = sdec.window_bytes(sdec.force_baud, r.nbits, r.par, r.nstop)
  sdec.autolocknote = string.format(
    'auto-locked %s %s: next %g kS/s ~%d B (Options > Baud Rate = 0 re-detects)',
    sdec.baud_text(), sdec.fmt_text(), (fs or 0) / 1000, nb or 0)
  return true
end

-- ============================================================================
-- Protocol layer
-- ============================================================================
-- Run ONE protocol layer's parser over the bytes just decoded. mode names the view whose parser
-- to run. Returns whether it ran.
function sdec.proto_parse1(mode)
  local v = sdec.ui_view(mode)
  if v == nil or v.parse == nil then return false end
  local fn = sdec[v.parse]
  -- GUARDED ON THE FUNCTION'S EXISTENCE as well as on the mode: midi_decode.tsp and
  -- lin_decode.tsp are separate modules, and a build that omits one must degrade to the raw UART
  -- views rather than raise from inside a touch handler. sdec.ui_views is the single description
  -- of which modes have a parser at all.
  if fn == nil then return false end
  local ok, perr = pcall(function() fn() end)
  -- A PARSER THAT RAISED MUST NOT LEAVE AN EMPTY PROTOCOL VIEW LOOKING LIKE AN ANSWER. The capture
  -- stays 'done' -- correctly, the UART decode underneath it worked -- so a MIDI or LIN view that came
  -- back blank reads as "your device emitted no protocol messages", which is a statement about the
  -- operator's device that the app never actually established. The raw bytes are still right and still
  -- shown; only the protocol layer failed, and saying which is the whole difference.
  --
  -- THE PARTIAL RESULT IS RETRACTED, because a parser that raised part-way through may have left a
  -- half-built list, and half a message list is worse than none: it looks complete.
  if not ok then
    sdec[v.res] = nil
    sdec.proto_why = string.format('%s decode failed (%s) -- the bytes below are still the '
                                   .. 'decoded UART stream', tostring(mode),
                                   tostring(perr or 'unknown'))
    pcall(function() ulog.line('proto: ' .. sdec.proto_why) end)
    return false
  end
  if sdec[v.res] ~= nil then
    local sm = sdec[v.summary]
    if sm ~= nil then ulog.line(tostring(mode) .. ': ' .. sm()) end
  end
  return ok
end

-- Parse the layers the panel is about to need: the one SELECTED on the options form, and the one
-- being VIEWED when that is a different one. `which` parses that layer alone. Returns whether
-- any parser ran.
function sdec.proto_parse(which)
  -- BOTH, because the View button reaches the MIDI and LIN lists for any capture -- "is this
  -- stream MIDI at all?" is a question worth being able to ask -- while the selected protocol is
  -- the one whose summary belongs in the log.
  if which ~= nil then return sdec.proto_parse1(which) end
  local did = false
  if sdec.proto ~= nil and sdec.proto ~= 'uart' then
    did = sdec.proto_parse1(sdec.proto)
  end
  if sdec.ui_mode ~= sdec.proto then
    if sdec.proto_parse1(sdec.ui_mode) then did = true end
  end
  return did
end

-- ============================================================================
-- Save the decoded stream to the USB key
-- ============================================================================
-- Write a self-describing file to the USB key: the wire parameters, then the whole capture as a
-- hex + ASCII dump, then every parsed protocol list. Returns ok.
function sdec.save()
  -- The panel only ever shows one page; this is how the rest of a capture leaves the instrument.
  sdec.savedas = nil
  if sdec.res == nil or sdec.res.nf == 0 then
    sdec.lasterr = 'nothing to save -- capture first'
    pcall(function() sdec.ui_refresh() end)
    return false
  end

  local L, n = {}, 0
  local function add(s) n = n + 1; L[n] = s end
  add('DMM6500 serial decode')
  add('')
  -- THE WIRE PARAMETERS GO IN THE FILE, because a bare byte dump is ambiguous six months later:
  -- 4800 8N1 and 9600 7N1 can produce identical bytes from the same waveform, so the file has to
  -- record which reading produced it.
  add('baud       ' .. sdec.baud_text())
  add('format     ' .. sdec.fmt_text())
  local idle = 'HIGH'
  if sdec.res.invert then idle = 'LOW' end
  add('idle       ' .. idle)
  add('levels     ' .. tostring(sdec.family) .. string.format('  %.3f / %.3f V',
      sdec.lo or 0, sdec.hi or 0))
  add(string.format('threshold  %.3f V', sdec.thr or 0))
  add(string.format('sample rate %.0f S/s', sdec.acq_fs or sdec.fs or 0))
  add(string.format('samples/bit %.2f', sdec.bittime or 0))
  add(string.format('bytes      %d   framing errors %d', sdec.res.nf, sdec.res.nbad))
  if sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('false starts rejected %d  (impulse noise)', sdec.res.nfalse))
  end
  -- EVERY note. The panel cell holds one and says how many more there are; this file and
  -- the log are where the others live, which is what makes the count honest.
  local nt, nn = sdec.ui_notes()
  local ni
  for ni = 1, nn do add('NOTE       ' .. nt[ni]) end
  -- Stated in the file as well as on screen: a spike landing on a data bit flips it
  -- undetectably, so a zero error count is not a guarantee of zero corruption.
  add('')
  add('"framing errors" counts stop/parity failures only. A noise spike on a data')
  add('bit corrupts the byte with no error indication.')
  add('')
  local i, per = 1, 16
  while i <= sdec.res.nf do
    add(sdec.ua_hex_line(i, per))
    i = i + per
  end

  -- Every parsed protocol list that has anything in it. The panel shows 13 rows at a
  -- time, and a protocol capture is the case where the bytes on their own are least
  -- readable -- MIDI running status means a message need not even start with a status
  -- byte, and a LIN frame's boundaries are timing, not values.
  local vi
  for vi = 1, table.getn(sdec.ui_views) do
    local v = sdec.ui_views[vi]
    if v.res ~= nil then
      local pr = sdec[v.res]
      if pr ~= nil and pr.n > 0 then
        local sm = sdec[v.summary]
        add('')
        add((v.label or v.name) .. ' -- ' .. (sm and sm() or ''))
        add('')
        for i = 1, pr.n do add(pr.msg[i]) end
      end
    end
  end

  local path = ulog.next_free(sdec.savepfx, sdec.saveext)
  local ok, why = ulog.write_file(path, L, n)
  if ok then
    sdec.savedas = path
    sdec.lasterr = nil
    ulog.line('saved ' .. tostring(path))
  else
    sdec.lasterr = 'save failed: ' .. tostring(why)
  end
  pcall(function() sdec.ui_refresh() end)
  return ok
end

-- ============================================================================
-- View handlers
-- ============================================================================
-- Advance through the views THIS BUILD HAS -- text -> hex -> text in version 1, which ships
-- without midi_decode.tsp and lin_decode.tsp, so ui_view_avail() hides the MIDI and LIN entries
-- rather than landing the button on a list that could only ever be empty.
function sdec.view_toggle()
  -- EVERY PROTOCOL VIEW IS OFFERED whatever the protocol setting says, because "is this stream
  -- MIDI at all?" -- or LIN -- is worth being able to ask of any capture, and each parser reports
  -- what it found, including nothing.
  --
  -- Cycles over the views THIS BUILD HAS, not the whole table: a build without the MIDI and LIN
  -- modules would otherwise land on a view that can only ever be empty. sdec.ui_view_avail()
  -- decides; see serial_ui.tsp.
  local n = sdec.ui_nviews()
  if n < 1 then return false end
  local at, i, k = 0, nil, 0
  for i = 1, table.getn(sdec.ui_views) do
    if sdec.ui_view_avail(sdec.ui_views[i]) then
      k = k + 1
      if sdec.ui_views[i].mode == sdec.ui_mode then at = k end
    end
  end
  -- math.mod, not '%': 5.0.2. at = 0 (an unrecognised mode) lands on the first view.
  local nx = sdec.ui_view_nth(math.mod(at, n) + 1)
  if nx == nil then return false end
  sdec.ui_mode = nx.mode
  -- Parse on first entry to the view. capture() has already done it when this is the
  -- selected protocol, and clear_result() drops the parsed list with the rest of the
  -- result, so this cannot show a previous capture's messages.
  if nx.res ~= nil and sdec[nx.res] == nil then sdec.proto_parse(nx.mode) end
  sdec.ui_page = 0
  sdec.ui_rowc = nil          -- force a colour re-evaluation on the new layout
  return pcall(function() sdec.ui_refresh() end)
end

-- Advance one page of bytes, wrapping at the last.
function sdec.page_cycle()
  -- ONE WRAPPING PAGE BUTTON IS ONLY SUFFICIENT BECAUSE A CAPTURE HOLDS AT MOST 500 BYTES: three
  -- hex pages, so any page is at most two presses away, and text never pages at all. IF THE
  -- CAPTURE CEILING EVER RISES -- a bigger sdec.n, or the streaming mode learning to show its
  -- bytes on the panel rather than writing a file. UNBOUND today: the panel wires page_prev and
  -- page_next to 'Up' and 'Dn' (serial_ui.tsp:1990), and a stream tail runs to sdec.ck_keep = 8192
  -- bytes -- 35 hex pages -- so one wrapping control is not enough for it.
  local npg = sdec.ui_npages()
  if npg < 1 then npg = 1 end
  sdec.ui_paged = true
  sdec.ui_page = math.mod(sdec.ui_page + 1, npg)
  return pcall(function() sdec.ui_refresh() end)
end

-- Show the next page of bytes. Bound to the 'Dn' button down the dump area's right margin, with
-- page_prev() as 'Up' above it; the host drives both over the socket as well.
--
-- ui_paged IS SET EVEN WHEN THE PAGE DOES NOT MOVE. It is what puts 'page N of M' on the note row,
-- and a press at the last page is exactly when the operator most needs to be told which page they
-- are on -- suppressing the counter there would answer "nothing happened, why?" with silence.
function sdec.page_next()
  sdec.ui_paged = true
  if sdec.ui_page + 1 < sdec.ui_npages() then sdec.ui_page = sdec.ui_page + 1 end
  return pcall(function() sdec.ui_refresh() end)
end

-- Show the previous page of bytes.
function sdec.page_prev()
  sdec.ui_paged = true
  if sdec.ui_page > 0 then sdec.ui_page = sdec.ui_page - 1 end
  return pcall(function() sdec.ui_refresh() end)
end

-- Start a new byte log, so one device's or one test's messages are separated from the next.
function sdec.log_new()
  -- FORGETTING THE PATH IS THE WHOLE MECHANISM: frame_log() opens, appends and closes per
  -- capture, so there is no handle to close here, and the next capture calls ulog.next_free()
  -- again and lands on the next unused name.
  --
  -- It says what it did on the note line rather than silently renumbering. A control whose only
  -- evidence is a filename that changes on the NEXT capture is one you press twice, because you
  -- cannot tell whether the first press worked.
  local was = sdec.flog_path
  pcall(function() ulog.flush() end)
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  if was ~= nil then
    local base = string.gsub(tostring(was), '^.*/', '')
    sdec.lognote = string.format('closed %s -- the next capture starts a new file', base)
  else
    sdec.lognote = 'no message log open yet -- the next capture starts one'
  end
  pcall(function() ulog.line(sdec.lognote) end)
  return pcall(function() sdec.ui_refresh() end)
end

-- Clear every forced setting and re-capture: the inverse of Lock Detected, which is the button
-- beside it on the options form.
function sdec.options_auto()
  -- Auto-detection is already the DEFAULT -- nothing forced means everything is searched for --
  -- so this is a one-press way back to it rather than a new capability. By hand it is six
  -- interactions on the form (baud to 0, three fields to Auto, Apply), which is enough friction
  -- that a locked rate tends to stay locked onto the next line it does not describe.
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  -- NO autolock_defer() HERE: 'Auto Detect' means "work it out and use it", so the capture this
  -- triggers is allowed to lock what it finds. Deferring instead leaves the panel amber at the
  -- top sample rate with a 19-byte window -- a press that makes things worse, with the good
  -- outcome one press away and nothing saying so. The deferral belongs to the other route to the
  -- same clearing, Options > Baud Rate = 0 plus Apply, which is a request to STAY unlocked.
  pcall(function() ulog.line('auto-detect: all forced settings cleared') end)
  pcall(function() sdec.options_seed() end)
  -- AUTO-DETECT IS A FRAME-MODE OPERATION, and a streaming mode cannot be otherwise: it is gated
  -- on a locked rate precisely because the sample rate has to be chosen before the capture, and
  -- a rate still being searched for cannot do that. So this press lands in FRAME, and it does so
  -- by exiting properly -- flushing like any other way out -- rather than by refusing and leaving
  -- the operator to press Mode and come back.
  local md = sdec.mode_cur()
  if md.needbaud then
    sdec.mode_exit('auto-detect is FRAME-mode only')
    -- SET HERE, NOT IN mode_exit(). That function is a flush and no longer touches the mode, so the
    -- two places a mode change is part of the MEANING say so themselves: auto-detect cannot run in a
    -- recording mode at all, so this press has to land in FRAME or it does nothing.
    sdec.capmode = 'frame'
  end
  return sdec.options_apply()
end

-- THE PADLOCK'S ACTION: amber (auto) locks what was detected and goes green, green (locked)
-- unlocks back to auto, red (nothing decoded) refuses with a reason. Either way it re-captures.
function sdec.lock_toggle()
  -- LOCKING THE BAUD RATE CHANGES THE SAMPLE RATE, which is why this re-captures rather than
  -- merely pinning. fs_for_baud() picks the lowest LISTED rate still giving 8 samples/bit, so
  -- locking 9600 moves fs from the 1 MS/s the auto-detect pass used down to 80 kS/s: RATE
  -- changes, SA/BIT goes from ~104 to 8.3, the capture WINDOW from 19 bytes to 240, and
  -- window_bytes() reports something else again. Without the re-capture, three header cells and
  -- a note go on describing the capture that produced them while describing nothing the
  -- instrument will do next. Locking is the step that BUYS the longer window, which is the whole
  -- point of the sample-rate-follows-baud design; options_apply() does the same after Lock
  -- Detected, so the padlock and the form behave alike.
  --
  -- Reachable three ways, only one of them certain: Options -> Lock Detected (a real button), a
  -- tap on the padlock (wired speculatively -- EVENT_PRESS on a rect is unverified, and 9x7 px is
  -- below a fingertip anyway), and from the host over the socket.
  --
  -- RE-ENTRANCY GUARD, and not a theoretical one: this handler calls capture(), and it is wired
  -- to TWO OVERLAPPING rects -- the glyph sits entirely inside the hit box -- so if the firmware
  -- delivers a press to both, one fingertip fires it twice. Nested, the outer call locks and
  -- captures, the inner sees 'locked' and UNLOCKS, and the outer then overwrites the note --
  -- leaving the wire unlocked, the rate back at the auto-detect value, and a note claiming
  -- "locked 9600 baud 8N1".
  if sdec.busy then return false end
  local st = sdec.lock_state()
  local note = nil
  if st == 'locked' then
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
    sdec.autolock_defer()
    note = 'unlocked -- auto-detecting again, back to the top sample rate'
    -- Unlocking disarms the streaming modes, so leave one rather than sit in a mode that can
    -- no longer run. Same reasoning as options_auto(), and the mode change is set HERE for the same
    -- reason: mode_exit() is a flush and the switch is part of what THIS press means.
    if sdec.mode_cur().needbaud then
      sdec.mode_exit('unlocked the baud rate')
      sdec.capmode = 'frame'
    end
  elseif st == 'auto' then
    local r = sdec.res
    if r == nil or sdec.baud == nil then
      sdec.lasterr = 'nothing decoded yet -- capture first, then lock'
      return pcall(function() sdec.ui_refresh() end)
    end
    -- Rounded, for the reason given at the Options Lock path: sdec.baud is a standard rate only
    -- when sdec.snapped, and this button has no such test.
    sdec.force_baud   = math.floor(sdec.baud + 0.5)
    sdec.force_nbits  = r.nbits
    sdec.force_par    = r.par
    sdec.force_nstop  = r.nstop
    sdec.force_invert = r.invert
    note = string.format('locked %s %s', sdec.baud_text(), sdec.fmt_text())
  else
    sdec.lasterr = 'nothing decoded yet -- capture first, then lock'
    return pcall(function() sdec.ui_refresh() end)
  end

  -- Re-capture at the rate the new lock state implies, so RATE, SA/BIT, BYTES and the window
  -- note all describe the same thing. Guarded: this is a touch handler, and capture() is
  -- already fully guarded internally, but the call itself must not be able to raise here.
  -- THE VERDICT IS KEPT, because the sentence below claims the recapture worked. Both the pcall's
  -- result and capture()'s own boolean were discarded, so a recapture that raised or refused still
  -- produced 'locked 9600 baud -- now sampling at 80 kS/s' -- a confident report of a capture that did
  -- not happen, over whatever the previous one left on screen. The lock IS still applied either way,
  -- which is why the wording has to change rather than the action.
  local cok, cerr = false, nil
  local pok = pcall(function() cok = sdec.capture() end)
  -- AFTER the capture, because clear_result() evicts the note cell. Names the new sample rate,
  -- since that is the thing the operator did not ask for and did get.
  if note ~= nil and not (pok and cok) then
    -- SAY BOTH HALVES: the setting took, the measurement did not. lasterr already carries capture()'s
    -- own reason and outranks this note in ui_notes, so this line must not contradict it.
    sdec.lognote = note .. ' -- but the re-capture failed, so the figures above are the previous one'
    note = nil
  end
  if note ~= nil then
    -- sdec.fs, the REQUESTED rate, not acq_fs. acq_fs describes the capture that just happened;
    -- what the operator needs to know is the rate now in force. They are the same on hardware
    -- and differ in the offline mock, which replays a fixed waveform's own timestamps.
    -- Formatted like the RATE column so the two agree at a glance.
    local fs = sdec.fs
    if fs ~= nil and fs > 0 then
      if fs >= 1000000 then note = string.format('%s -- now sampling at %.0f MS/s', note, fs / 1000000)
      else note = string.format('%s -- now sampling at %.0f kS/s', note, fs / 1000) end
    end
    sdec.lognote = note
  end
  pcall(function() ulog.line(tostring(sdec.lognote or sdec.lasterr)) end)
  pcall(function() sdec.options_seed() end)
  return pcall(function() sdec.ui_refresh() end)
end

-- Toggle the external trigger from the status row.
function sdec.trigext_toggle()
  -- WIRED SPECULATIVELY, exactly like the padlock: EVENT_PRESS on a rect is unverified here, so
  -- the Options field stays the reliable path. Cheap, and it makes the indicator a control if
  -- presses do arrive.
  if sdec.busy then return false end
  sdec.trigext = not sdec.trigext
  if sdec.trigext and sdec.trigmode == 'free' then
    sdec.lognote = 'external trigger ON but IGNORED -- Free run means do not wait'
  elseif sdec.trigext then
    sdec.lognote = 'external trigger ON -- the rear BNC also starts a capture'
  else
    sdec.lognote = 'external trigger OFF'
  end
  pcall(function() ulog.line(tostring(sdec.lognote)) end)
  pcall(function() sdec.options_seed() end)
  return pcall(function() sdec.ui_refresh() end)
end

-- The note-row wording for a finished recording. endwhy is sdec.ck_endwhy; ok and err are the
-- run's verdict and its message.
function sdec.strm_exit_why(endwhy, ok, err)
  -- A CANCEL OUTRANKS THE NOTHING-COLLECTED REFUSAL, because it CAUSED it. A press breaks the poll
  -- loop where it stands, so an interrupted window returns too few samples to decode and stream()
  -- reports 'long capture returned nothing' -- correct for one window taken alone, and quite wrong for
  -- the run. Tested after the failure, a press during the level probe or in the first poll of the
  -- first window read 'run failed: long capture returned nothing': the documented stop control
  -- presented as an instrument fault, counted into errcount, with the word TRIGGER nowhere on screen.
  --
  -- A FAILURE WITH A CAUSE OF ITS OWN STILL WINS, and strm_empty is what separates them -- stream()
  -- sets it for the empty-acquisition refusal and nothing else. A window that could not open its file
  -- or allocate its buffer is reported as the failure it is, press or no press.
  if ok == false and not (sdec.ck_cancel and sdec.strm_empty) then
    -- The failure is the reason, and it is worth saying on the note row rather than only in
    -- the status cell, because a mode changing itself needs an explanation either way.
    return 'run failed: ' .. tostring(err or 'unknown')
  end
  -- The three ck_endwhy values all mean "the run is over", but they say different things about
  -- the LINE, and that difference is what is worth carrying onto the note row: quiet means the
  -- device stopped talking, stopped means you stopped it, full means neither -- there is very
  -- likely more where that came from, and the file is the record while the panel shows only its
  -- last page.
  -- AND IT OUTRANKS EVERY REASON BELOW. ck_endwhy describes the ACQUISITION, so a TRIGGER press during
  -- the DECODE leaves it 'full' -- and the branch below would then report 'buffer full -- the stream
  -- may continue' under a run the operator deliberately stopped, which is both wrong and the opposite
  -- of reassuring. stream_begin() clears ck_cancel on every run of either shape, so it can only be set
  -- by a press inside this one.
  if sdec.ck_cancel then
    if (sdec.fc_win or 0) > 1 then
      return string.format('stopped with the TRIGGER key after %d windows', sdec.fc_win)
    end
    return 'stopped with the TRIGGER key'
  end
  -- A BOUND IS A RUN-LEVEL REASON AND APPLIES FROM THE FIRST WINDOW, unlike the two below it. 'quiet'
  -- and 'stopped' describe a SEQUENCE of windows and read oddly for one; a bound does not -- at 300 baud
  -- a single window waits out the whole 20 minutes, so window one is exactly where the clock bound
  -- fires. Behind a `fc_win > 1` guard these would fall through to the 'full' branch and say 'buffer
  -- full -- the stream may continue', naming neither the limit that stopped the run nor the presses that
  -- continue it. Measured: a 25 s ceiling on a 'sml' run ends it at one window in 26.9 s.
  --
  -- THE REMEDY IS TWO PRESSES AND A NEW FILE. Every way out of a recording goes through mode_exit(),
  -- which nils flog_path but does NOT change capmode -- so Capture alone records another window, and
  -- the bytes that follow land in
  -- the next numbered file. What survives is the DATA: the sender is still waiting for a credit that has
  -- not gone out, so nothing is missed in between -- the recording is fragmented across two files, not
  -- truncated.
  if sdec.fc_end == 'bound' then
    return string.format('reached the %d-window limit -- Mode, then Capture, resumes in a new file',
                         sdec.fc_maxwin or 32)
  elseif sdec.fc_end == 'timebound' then
    -- Said in minutes because that is what was spent, and with the window count because that is what
    -- says how much came back.
    return string.format('reached the %g-minute limit after %d window(s) -- Mode, then Capture, '
                         .. 'resumes in a new file', (sdec.fc_maxsec or 1200) / 60, sdec.fc_win or 1)
  end
  -- A MULTI-WINDOW RUN ENDED FOR A REASON OF ITS OWN, and it is not the last window's reason: every
  -- window but the last one ended 'full', so endwhy describes the window rather than the
  -- transmission. record_run() records which of its exits fired.
  if (sdec.fc_win or 0) > 1 and sdec.fc_end ~= nil then
    if sdec.fc_end == 'quiet' then
      return string.format('%d windows, then the device stopped sending', sdec.fc_win)
    elseif sdec.fc_end == 'stopped' then
      -- NOT REACHABLE FROM THE PANEL TODAY, and the wording must not pretend otherwise: ck_stop is the
      -- only thing that sets this, and while the loop runs nothing can set ck_stop except
      -- cancel_asked() -- which sets ck_cancel too and returns above. Mode and mode_exit() are touch
      -- handlers and a touch is not dispatched while Lua runs, so they cannot ask a one-press run to
      -- wind up mid-flight. Kept as insurance against a firmware that gains a dispatch point.
      return string.format('stopped after %d windows', sdec.fc_win)
    end
    -- NO BOUND ARMS HERE. Both returned above, from the first window on -- and leaving copies behind
    -- would be two unreachable branches carrying the wording a reader would think was the live one.
  end
  -- THE BUFFER COULD NOT BE READ, which is neither a quiet line nor a full one. Named separately because
  -- the whole reason this value exists is that folding it into 'quiet' reported a fault as the operator's
  -- device finishing normally.
  if endwhy == 'readfail' then
    return 'recording failed: ' .. tostring(sdec.strm_readfail or 'the capture buffer could not be read')
  end
  if endwhy == 'quiet' then
    return string.format('%g s with no line activity', sdec.idle_exit_s)
  elseif endwhy == 'stopped' then
    -- WHO STOPPED IT, distinguished. Both are 'stopped' to the loop, and they need different
    -- sentences: a TRIGGER press is the operator ending the run on purpose, while Mode or a mode
    -- change stopping it is the app ending the run on their behalf.
    if sdec.ck_cancel then return 'stopped with the TRIGGER key' end
    return 'stopped from the panel'
  elseif endwhy == 'full' then
    return 'buffer full -- the stream may continue'
  end
  return 'finished'
end

-- HOW LONG A QUEUED PRESS STAYS ABSORBABLE.
--
-- The absorb exists because a press aimed at stopping a stream is only dispatched once the run's
-- Lua returns, and would otherwise land as a new capture that wipes the bytes the run just put on
-- screen. But it must not eat a press made MINUTES later with the panel sitting idle -- that is a
-- deliberate new capture, and swallowing it makes the operator press twice for no visible reason.
--
-- A queued press dispatches essentially immediately: capture() is the very next thing to run
-- after this handler returns, so the real interval is milliseconds. The window only has to be
-- wider than scheduling jitter, not wider than human reaction time -- deliberately NARROWER than
-- reaction time, in fact, because a press the operator decided to make after seeing the result
-- is by definition not the one that was queued before it existed.
--
-- AN ABSORB, NOT A FLUSH: nothing can drain the firmware's pending-press queue -- display.waitevent()
-- is the only thing that reads it and it wedges the instrument. Queued presses are still delivered;
-- each is recognised as queued and does nothing.
sdec.strm_absorb_s = sdec.strm_absorb_s or 1.0

-- Arm the queued-press absorb after a run that held the interpreter.
--
-- ARMED ON EVERY ENDING, INCLUDING 'stopped'. This used to return early when a press had been SEEN,
-- reasoning that nothing could be queued behind it -- true of one press, false of an operator, who
-- presses Capture, then TRIGGER, then Capture again. A finger on TRIGGER emits no blender event
-- while a panel-initiated run executes (measured, so the run ends at its own bounds
-- with both Capture presses unabsorbed -- each starting another uninterruptable recording.
function sdec.strm_absorb_arm()
  sdec.strm_stopped_by_press = nil
  sdec.strm_nabsorbed = 0
  -- timer.cleartime() stamps the moment the run ended. Nothing else runs between here and the
  -- dispatch of a queued press, so nothing else can reset the timer in between -- and if the
  -- firmware has no timer at all, the flag is simply never armed, which fails toward honouring
  -- the press rather than eating it.
  local ok = pcall(function() timer.cleartime() end)
  if ok then sdec.strm_stopped_by_press = true end
end

-- True if we are still inside the window in which a press must have been queued.
function sdec.strm_absorb_due()
  if not sdec.strm_stopped_by_press then return false end
  local el = nil
  pcall(function() el = timer.gettime() end)
  if el == nil then return false end
  return el <= sdec.strm_absorb_s
end

-- The one gate every handler that matters consults: was this press queued behind a run that has
-- already ended? True means it is dealt with and the caller must return without acting.
--
-- EVERY PRESS IN THE WINDOW, NOT THE FIRST. Disarming on the first absorb left a burst of three with
-- one swallowed and two honoured. The window bounds this, not a count, so leaving it armed cannot eat
-- a later deliberate press.
--
-- A STALE ARM IS CLEARED HERE: the elapsed time lives in the instrument's ONE global timer, so an arm
-- standing past its window would be resurrected by the next unrelated timer.cleartime(). Anything
-- taking the timer must also disarm first -- record_run() does, as does every harness via bench_sync.
--
-- CAPTURE ONLY, and the scope was narrowed by measurement rather than by taste. It was briefly wired
-- to Mode, Save, NewLog and Options as well; bench_panel's Mode/rec-exit failed, because a Mode press
-- in the second after a recording was swallowed and the panel did nothing at all -- the harness saw
-- byte-identical grabs. Mode is the way OUT of a mode, and a dead escape hatch is worse than a mode
-- change nobody asked for.
--
-- The test that survives is the harm: Capture starts a run of tens of seconds that cannot be
-- interrupted and wipes the result on screen. Nothing else on the panel does that -- Save spends a
-- filename, NewLog renumbers a log, Options opens a form, View and the page buttons only change what
-- is displayed. All recoverable in one press, so none is worth a control that appears broken.
function sdec.press_absorbed(what)
  if not sdec.strm_absorb_due() then
    -- Stale arm from a run whose window has passed, cleared on the first press after it.
    sdec.strm_stopped_by_press = nil
    sdec.strm_absorbed = nil
    return false
  end
  local n = (sdec.strm_nabsorbed or 0) + 1
  sdec.strm_nabsorbed = n
  -- lasterr goes, because the run that just ended is what the operator is reading and a queued
  -- press must not replace its verdict with a complaint about itself.
  sdec.lasterr = nil
  if n == 1 then
    sdec.strm_absorbed = string.format('%s taken as the Stop for the recording that just '
                                       .. 'ended -- press again to use it',
                                       tostring(what or 'the press'))
  else
    -- 'WITHIN A SECOND OF', not 'queued during the recording'. A 1 s window cannot tell a queued press
    -- from a deliberate one made just after the result appeared, so it must not assert which it was.
    sdec.strm_absorbed = string.format('%d presses within a second of the run ending were '
                                       .. 'discarded -- press again to capture', n)
  end
  pcall(function() ulog.line(sdec.strm_absorbed) end)
  pcall(function() sdec.ui_refresh() end)
  return true
end

-- Flush the current capture mode's files and say why. `why` goes on the note row. Returns the mode that
-- was left -- it does NOT change it; see the block below.
-- `bad` says the run ENDED BADLY, and it is passed rather than inferred. The note row shows this
-- function's message ONLY when it is set: a recording that finished normally leaves the note row
-- EMPTY, because the status row's summary already names the bytes, the errors and the file.
--
-- NOT SNIFFED OUT OF `why`. Every caller that means "this failed" knows it -- strm_exit_why() is
-- given the same ok flag -- and matching on words like 'failed' is how a protected failure gets
-- narrowed to a boolean nobody checks, which is this app's dominant defect class.
function sdec.mode_exit(why, bad)
  -- ONE FUNCTION FOR EVERY WAY OUT -- the Mode button, an idle line, a completed run, End App --
  -- so all of them flush the same way and land in the same place. A mode that can be left by two
  -- paths with different cleanup is a mode that eventually loses the tail of a file.
  --
  -- What needs flushing, listed because "flush the files" is vaguer than the code:
  --   * an in-progress stream: ck_stop, so the window loop finishes the window it is on and
  --     ck_run() calls the sink's finish(), which flushes and closes. Aborting the file handle
  --     from here instead discards a window that had already been decoded.
  --   * the byte log: frame_log() opens, appends, flushes and closes per capture, so there is
  --     never an open handle to lose -- but the PATH is forgotten here, so re-entering starts a
  --     new numbered file rather than appending to a previous session's.
  --   * ulog: flushed, not closed. It is the debug trace and outlives every mode.
  local was = sdec.capmode
  local md = sdec.mode_cur()
  local running = sdec.ck_running
  -- A DECODE IN PROGRESS OWNS AN OPEN FILE. Leaving the mode without abandoning it would strand
  -- the handle until a power cycle and lose the rows still in the sink's carry, so the job is
  -- closed out first -- which keeps the bytes already decoded and the tail to show them with.
  -- CLEARING ck_running MATTERS HERE. `running` was snapshotted above for the one-shot path, where
  -- it means "a loop is executing and owns these flags". A press-driven run has no loop, so after
  -- abandoning the job and settling the hardware nothing is executing -- and leaving ck_running
  -- true latched the panel into "stopping" forever: every later Capture took the obsolete branch.
  local pressdriven = (sdec.ck_job ~= nil) or (sdec.strm_recording == true)
  if sdec.ck_job ~= nil then pcall(function() sdec.decode_abandon() end) end
  -- Likewise a recording still running in hardware: stop the trigger model, or it goes on filling
  -- a buffer nothing will read.
  if sdec.strm_recording then
    sdec.strm_recording = nil
    pcall(function() sdec.stream_settle() end)
  end
  if pressdriven then
    running = false
    sdec.ck_running, sdec.ck_stop = false, false
  end
  pcall(function() ulog.flush() end)
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  -- THE MODE IS NOT CHANGED HERE, and that is the point of this function being only a flush.
  --
  -- It used to set capmode = 'frame', so a recording that finished -- or hit its cap, or met a quiet
  -- line -- moved the operator to a mode they had not chosen. With the capture mode now in the TITLE
  -- BAR, that switch is a large caption changing itself, which is worse than the small grey one it
  -- used to be: the panel appears to have decided something. A recording mode is a SETTING, and a
  -- setting the app resets after every use is one the operator has to re-make every time.
  --
  -- So the mode stays where it was put and the Mode button is the only thing that moves it. The two
  -- callers that need FRAME for a REASON -- auto-detect, which is a frame-mode operation, and losing
  -- the baud lock a recording mode requires -- set it themselves, next to the reason.
  if running then
    -- REQUEST a stop and leave ck_running alone: the run owns that flag and clears it as it
    -- unwinds.
    --
    -- ck_stop is therefore left TRUE on the way out, and nothing on the unwind path clears it.
    -- What makes that safe is the ENTRY clear in stream_begin(), which sets ck_stop = false
    -- alongside ck_running = true before any window runs -- so a stop request that arrived too
    -- late to be seen cannot carry into the next run and abort it at window zero. Do not delete
    -- that entry clear on the theory that this exit path handles it. It does not.
    sdec.ck_stop = true
  else
    -- Not running, so there is no owner to defer to and both flags are this function's to
    -- normalise. ck_stop may well already be true here -- left over from exactly the case
    -- above -- which is the second reason not to rely on the unwind path clearing it.
    sdec.ck_running, sdec.ck_stop = false, false
  end
  sdec.mode_exited, sdec.mode_exitbad = nil, false
  if md.id ~= 'frame' then
    -- Said on the note line, because a run ending is what the operator needs told -- and now that
    -- the mode does NOT change, the note must not claim it did. It names the mode still selected,
    -- so the next Capture press is not a surprise.

    -- ALWAYS SET, AND ALWAYS LOGGED -- the debug trace wants every exit, and tools/test_cancel.lua
    -- reads this string for the fault reason. Only the NOTE ROW is conditional (see ui_notes).
    sdec.mode_exited = string.format('%s run ended (%s)', md.name, tostring(why or 'exited'))
    sdec.mode_exitbad = (bad == true)
    pcall(function() ulog.line(sdec.mode_exited) end)
  end
  return was
end

-- Which mode an idle Mode press advances to -- the ENTRY, not the id.
--
-- FACTORED OUT SO THE PANEL CAN NAME IT. The status row said 'Mode=Exit to FRAME' in every recording
-- mode, and from 8 kB the button goes to 32 kB: the cycle only reaches FRAME from the last mode. A
-- label that names the wrong destination is this app's recurring defect, so the label and the action
-- now read the SAME function rather than two descriptions of one behaviour.
--
-- Skips any mode that cannot be right at the locked rate (mode_suits), bounded by n steps and
-- falling back to the first entry: mode_suits is data-driven, and a table where nothing suits must
-- not spin inside a touch handler.
--
-- math.mod, not '%': Lua 5.0.2. at = 0 (an unrecognised capmode) lands on the first entry.
function sdec.mode_next()
  local n = sdec.ui_modes.n
  local at, i = 0, nil
  for i = 1, n do
    if sdec.ui_modes[i].id == sdec.capmode then at = i end
  end
  local step
  for step = 1, n do
    local cand = sdec.ui_modes[math.mod(at + step - 1, n) + 1]
    if sdec.mode_suits(cand) then return cand end
  end
  return sdec.ui_modes[1]
end

-- The Mode button. Two behaviours, and which one applies turns on whether a run is in progress:
--
--   RUNNING  -> abort. Stop the stream and flush, in one press, STAYING in the mode.
--   IDLE     -> advance to the next mode, flushing the one being left on the way out.
--
-- THE RUNNING BRANCH NO LONGER LANDS IN FRAME. mode_exit() is a flush and does not touch capmode, so
-- an abort stops the run and leaves the setting that says what the next one is -- one press, one
-- effect. Getting to FRAME from a recording mode is therefore up to two more presses of this button,
-- which is the trade for the mode never changing itself.
function sdec.mode_cycle()
  -- A RATE OFFER DIES WITH THE CAPTURE THAT RAISED IT. Both branches below discard the result, so an
  -- offer surviving a Mode press would let rate_accept() drop the operator's lock on the strength of a
  -- capture that is gone -- and in a streaming mode, which needs a lock, it would refuse straight after.
  -- capture() alone does not cover it: Mode is the other way out of a result.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  -- NOT ABSORBED. See sdec.press_absorbed: Mode is a way to STOP, and a dead Mode button in the
  -- second after a run is worse than a mode change nobody wanted. bench_panel's Mode/rec-exit caught
  -- this.
  if sdec.ck_running then
    sdec.mode_exit('Mode pressed')
    -- The summary survives a stream that ended BY ITSELF -- it is the result, and the bytes are
    -- still on screen. An explicit Mode press is the operator leaving, which is the documented
    -- point at which it stops describing anything, so it is cleared on both branches of this
    -- function rather than only on the one that advances.
    sdec.ck_tot, sdec.ck_nbytes = nil, nil
    -- MODE IS THE WAY OUT, so it must actually get out. mode_exit() defers to the run that owns
    -- ck_running and only REQUESTS a stop -- correct when it is called from inside that run's own
    -- unwind, and wrong here: a front-panel press is not dispatched while Lua runs, so a handler
    -- executing at all proves no loop is. Left set, the flag latches the panel into 'stopping'
    -- and every later Capture press is absorbed as a stop for a run that has already gone.
    sdec.ck_running, sdec.ck_stop = false, false
    sdec.ui_status = 'stopped'
    return pcall(function() sdec.ui_refresh() end)
  end

  -- DOES NOT REFUSE A MODE WHOSE PRECONDITIONS ARE UNMET: the operator should be able to line up
  -- '32 kB' and then go and lock the baud rate, and the status row says what is missing meanwhile
  -- (sdec.ck_status -> mode_why). The refusal belongs to Capture, which is what cannot proceed.
  local n = sdec.ui_modes.n
  local at, i = 0, nil
  for i = 1, n do
    if sdec.ui_modes[i].id == sdec.capmode then at = i end
  end
  -- Flush the mode being left, then select the next. `at` is read before the flush; mode_exit() does
  -- not touch capmode, so the order is not load-bearing.
  -- math.mod, not '%': 5.0.2. at = 0 (an unrecognised mode) lands on the first entry.
  --
  -- THE CYCLE SKIPS ANY MODE THAT CANNOT BE RIGHT at the locked rate, so the operator is never
  -- parked in one that is the wrong answer for their line. mode_suits() decides.
  --
  -- BOUNDED by n steps and falling back to the first entry. mode_suits() is `return true`
  -- (serial_ui.tsp:490) -- an unsuitable rate is refused by mode_why() instead -- so the bound guards
  -- a future filter, not a live one.
  local nxt = sdec.mode_next().id
  sdec.mode_exit('switching')
  sdec.capmode = nxt
  -- Switching drops the streaming result: ck_tot describes a run in a mode that may no longer be
  -- selected, and a stale byte count under a different mode name reads as a measurement.
  sdec.ck_tot, sdec.ck_nbytes = nil, nil
  pcall(function() ulog.line('mode = ' .. sdec.capmode) end)
  return pcall(function() sdec.ui_refresh() end)
end

-- ============================================================================
-- The idle watchdog
-- ============================================================================
-- Is there any activity in rd[1..n]? thr is the threshold and hyst its hysteresis, both
-- defaulting to the current capture's. Returns true if the line crossed, false if it sat still.
function sdec.smp_active(rd, n, thr, hyst)
  if rd == nil or n == nil or n < 2 then return false end
  if thr == nil then thr = sdec.thr end
  if hyst == nil then hyst = sdec.hyst or 0 end
  -- HYSTERESIS, not a bare threshold comparison: an idle line sitting AT the threshold otherwise
  -- reports activity from ADC noise alone, and this is what decides when to stop recording. The
  -- test is the same trip-past-thr+-hyst rule sig_edges uses, so "activity" here means exactly
  -- what "an edge" means there.
  local hiT, loT = thr + hyst, thr - hyst
  local st, i = nil, 0
  for i = 1, n do
    local v = rd[i]
    if v ~= nil then
      if st == nil then
        if v >= thr then st = 1 else st = 0 end
      elseif st == 1 then
        if v < loT then return true end
      else
        if v > hiT then return true end
      end
    end
  end
  return false
end

-- How many samples the idle watchdog looks at per poll, at sample rate fs.
function sdec.idle_window(fs)
  if fs == nil or fs <= 0 then return 2000 end
  -- A TENTH OF A SECOND of signal is far more than one frame at any rate this app decodes, so a
  -- single byte anywhere in the interval trips it -- and it is a few thousand proxy reads a second
  -- at most, against an acquisition otherwise idle waiting for hardware.
  local n = math.floor(fs / 10)
  if n < 200 then n = 200 end
  if n > 4000 then n = 4000 end
  return n
end

-- ============================================================================
-- Options
-- ============================================================================
-- Seed the form fields from the current force_* settings. Called on every open, and by anything
-- that changes them, so the form always shows what is in effect without rebuilding it.
function sdec.options_seed()
  return pcall(function()
    -- GUARDED EXPLICITLY, not left to the pcall. Version 1 omits the Protocol field, so this
    -- handle is nil -- and everything here is inside ONE pcall, so a raise on the first line
    -- would leave every field BELOW it unseeded and showing stale values. The pcall would
    -- hide that rather than prevent it.
    if sdec.opt_proto ~= nil then
      display.setvalue(sdec.opt_proto, sdec.opt_proto_i(sdec.proto))
    end
    display.setvalue(sdec.opt_baud, sdec.force_baud or 0)
    -- Entry 1 = Auto (7/8), 2 = Auto (any width), 3..7 = a forced 5..9.
    local bi = 1
    if sdec.widths_any then bi = 2 end
    if sdec.force_nbits ~= nil then bi = sdec.force_nbits - 2 end
    display.setvalue(sdec.opt_bits, bi)
    local pi = 1
    if sdec.force_par ~= nil then pi = sdec.force_par + 2 end
    display.setvalue(sdec.opt_par, pi)
    local li = 1
    if sdec.force_invert == false then li = 2 end
    if sdec.force_invert == true then li = 3 end
    display.setvalue(sdec.opt_pol, li)
    local ti = 1
    local tk
    for tk = 1, sdec.opt_trig_v.n do
      if sdec.opt_trig_v[tk] == sdec.trigmode then ti = tk end
    end
    -- The rear-BNC field is a 1-BASED OPTION INDEX, not display.ON/OFF -- it was a check object
    -- until flow control needed a second boolean and the form had no room for an eighth field.
    -- Seeded by searching opt_rear_v for the pair currently in force, so the two directions
    -- cannot disagree: there is one table and both ends read it.
    local xi, rk = 1, nil
    for rk = 1, sdec.opt_rear_v.n do
      if sdec.opt_rear_v[rk][1] == sdec.trigext and
         sdec.opt_rear_v[rk][2] == sdec.fc_out then xi = rk end
    end
    display.setvalue(sdec.opt_ext, xi)
    display.setvalue(sdec.opt_trig, ti)
  end)
end

-- Snapshot everything the form can change, so Cancel can undo it. Returns true.
function sdec.options_save()
  -- A screen with a Cancel button promises that its edits are provisional, and Lock Detected
  -- breaks that promise: it writes the live forced settings the moment it is pressed, so without
  -- a snapshot Cancel closes the screen over a wire configuration the operator has just declined.
  -- Taken on the way in, it covers every route the form has to that state rather than one of them.
  sdec.opt_snap = {baud = sdec.force_baud, nbits = sdec.force_nbits,
                   par = sdec.force_par, nstop = sdec.force_nstop,
                   invert = sdec.force_invert, proto = sdec.proto,
                   any = sdec.widths_any, trig = sdec.trigmode,
                   ext = sdec.trigext, fc = sdec.fc_out, view = sdec.ui_mode}
  return true
end

-- Put back the settings options_save() snapshotted. Returns false if there is no snapshot.
function sdec.options_restore()
  local s = sdec.opt_snap
  if s == nil then return false end
  sdec.force_baud, sdec.force_nbits = s.baud, s.nbits
  sdec.force_par, sdec.force_nstop, sdec.force_invert = s.par, s.nstop, s.invert
  sdec.proto, sdec.widths_any = s.proto, s.any
  sdec.trigmode, sdec.trigext, sdec.fc_out = s.trig, s.ext, s.fc
  sdec.ui_mode = s.view
  return true
end

-- Show the options screen, building it first if it does not exist yet.
function sdec.options()
  -- THROUGH pcall: this is a touch handler, and build_options() raises by design when the pool is
  -- exhausted. An uncaught raise here is an ERROR-severity event, which is a modal dialog over the
  -- app -- so the refusal is turned into a note instead, like every other refusal on this panel.
  if sdec.optscr == nil then
    local bok, berr = pcall(function() sdec.build_options() end)
    if not bok or sdec.optscr == nil then
      sdec.lasterr = tostring(berr or 'the options screen could not be built')
      pcall(function() ulog.line('options: ' .. sdec.lasterr) end)
      return pcall(function() sdec.ui_refresh() end)
    end
  end
  sdec.options_save()     -- so Cancel has something to go back to
  -- THE SEED'S VERDICT DECIDES WHETHER THE FORM MAY OPEN, and ignoring it was a real hazard rather than
  -- an untidiness. options_seed() pushes the CURRENT setting into every control; if a display.setvalue
  -- fails part way through, the fields above the failure show what is in effect and the ones below show
  -- whatever the form was left holding last time. The operator reads a mixed screen as one state, changes
  -- one field, and presses Apply -- which applies every field, including the stale ones. That is a
  -- configuration they neither chose nor were shown, and it is silent.
  --
  -- Refusing is the right answer here, unlike the sample-rate fallback: there is nothing useful to do
  -- with a form that cannot be trusted to display the truth, and Options is reachable again the moment
  -- the pool recovers.
  local sok = sdec.options_seed()
  if not sok then
    sdec.lasterr = 'the Options form could not be filled in with the current settings -- not opening '
                   .. 'it, because Apply would then apply values you were not shown'
    pcall(function() ulog.line('options: ' .. sdec.lasterr) end)
    return pcall(function() sdec.ui_refresh() end)
  end
  return pcall(function() display.changescreen(sdec.optscr) end)
end

-- Copy what the last capture DETECTED into the forced fields and re-seed the form. Does NOT
-- re-capture: the values are there to be reviewed, then applied with Apply.
function sdec.options_lock()
  -- THE WORKFLOW THE AUTO-DETECTOR IS FOR: probe an unknown line once, then pin the answer so
  -- every capture afterwards uses it. It matters most on exactly the signals where auto-detection
  -- is weakest -- a spiky or drifting line can shift the format between captures, and a bit time
  -- that is given rather than fitted cannot be corrupted by impulse noise at all, because the fit
  -- never runs.
  if sdec.res == nil or sdec.baud == nil then
    sdec.lasterr = 'nothing detected yet -- capture first'
    pcall(function() sdec.ui_refresh() end)
    return false
  end
  -- The snapped rate WHEN IT SNAPPED, since that is the one a device is actually running: locking a
  -- measured 9611 would put the sampling point a bit further into the next cell on every
  -- frame, which is the error a 10-bit frame accumulates worst.
  --
  -- ROUNDED, because sdec.baud is only a standard rate when sdec.snapped -- this path has no such
  -- test and a nonstandard line locks its raw measurement, e.g. 12345.6. force_baud must stay whole:
  -- decode_from sets snapped = true for any forced rate, so a fraction then reaches the %d in
  -- baud_text's snapped branch. At 0.003 % the rounding is far inside sdec.ratemargin.
  sdec.force_baud  = math.floor(sdec.baud + 0.5)
  sdec.force_nbits = sdec.res.nbits
  sdec.force_par   = sdec.res.par
  sdec.force_nstop = sdec.res.nstop
  sdec.force_invert = sdec.res.invert
  sdec.options_seed()
  ulog.fmt('locked: baud=%s bits=%s par=%s inv=%s', tostring(sdec.force_baud),
           tostring(sdec.force_nbits), tostring(sdec.force_par),
           tostring(sdec.force_invert))
  return true
end

-- Read every options field back, apply it, return to the main screen and capture.
function sdec.options_apply()
  -- A PARTIAL READ MUST NOT BE APPLIED AS A WHOLE CONFIGURATION. Without one pcall around every
  -- field, a getvalue that raises half way -- Baud read, Data Bits not -- leaves the new rate
  -- combined with the previous width, parity and polarity, and the form closes reporting success:
  -- the operator then captures against a setting nobody chose. The failure is recorded and the
  -- capture at the end is skipped, so the panel says so instead of guessing.
  local readok, readerr = pcall(function()
    local b = display.getvalue(sdec.opt_baud)
    -- ROUNDED TO A WHOLE Bd. force_baud must stay integral because decode_from sets snapped = true
    -- for any forced rate, and the snapped display branches format it with %d.
    --
    -- This is one of THREE sources that needed rounding, not the only one -- an earlier version of
    -- this comment claimed the others were integral by construction and was wrong. Autolock's is
    -- (gated on `snapped`, so sig_snap returned an exact sdec.stdbaud entry), and MIDI is the literal
    -- 31250, but the two LOCK paths copy sdec.baud with no snapped test and so lock a raw measurement
    -- on a nonstandard line: they round too, see :2449 and :1909.
    --
    -- The field is an OBJ_EDIT_NUMBER with NFORMAT_PREFIX and no decimal-places argument, so whether
    -- (the two rounding LOCK paths are lock_toggle and options_lock; both floor(baud + 0.5))
    -- it can hand back 9600.5 is a firmware question this code should not have to answer. Rounding
    -- rather than refusing -- 9600.4 plainly means 9600.
    if type(b) == 'number' and b >= 110 then sdec.force_baud = math.floor(b + 0.5)
    else
      -- Baud Rate 0 IS the request for auto-detect; defer auto-lock for one capture so
      -- the operator sees the detection unlocked rather than instantly re-locked.
      if sdec.force_baud ~= nil then sdec.autolock_defer() end
      sdec.force_baud = nil
    end

    local bi = display.getvalue(sdec.opt_bits)
    sdec.force_nbits = sdec.opt_pick(sdec.opt_bits_v, bi)
    -- Entry 2 widens the automatic search to 5, 6 and 9 data bits. Only meaningful when
    -- nothing is forced, and harmless when something is: a forced width skips the search.
    sdec.widths_any = (type(bi) == 'number' and math.floor(bi + 0.5) == 2)
    -- PARITY IS APPLIED ON ITS OWN, with the width left automatic. The format search narrows
    -- its candidate list to the forced parity (sdec.ua_parities), so choosing Even on a 7E1
    -- line finds 7E1 -- where pinning the width to 8 to make the setting take effect would
    -- have forced 8E1 and produced framing errors on a line the app could have read.
    sdec.force_par   = sdec.opt_pick(sdec.opt_par_v, display.getvalue(sdec.opt_par))

    local li = display.getvalue(sdec.opt_pol)
    if li == 2 then sdec.force_invert = false
    elseif li == 3 then sdec.force_invert = true
    else sdec.force_invert = nil end

    local ti = display.getvalue(sdec.opt_trig)
    sdec.trigmode = sdec.opt_pick(sdec.opt_trig_v, ti) or 'edge'
    -- Both rear-BNC booleans come from one index. Guarded with a fallback to entry 1 (both off),
    -- because a getvalue that returns something unexpected must not leave the app pulsing a BNC
    -- nobody asked it to pulse.
    local ri = sdec.opt_rear_v[display.getvalue(sdec.opt_ext)] or sdec.opt_rear_v[1]
    sdec.trigext, sdec.fc_out = ri[1], ri[2]
  end)
  if not readok then
    -- AND THIS IS WHAT MAKES THAT MESSAGE TRUE. The reads above assign as they go, so a getvalue
    -- that raises on Data Bits has already committed Baud -- the new rate combined with the old
    -- width, live, under a message saying nothing changed. options_save() has snapshotted for
    -- Cancel, so the state to go back to already exists and this is the unwind Cancel performs.
    pcall(function() sdec.options_restore() end)
    sdec.lasterr = 'Options could not be read in full -- nothing was changed (' ..
                   tostring(readerr) .. ')'
    pcall(function() ulog.line(sdec.lasterr) end)
    pcall(function() display.changescreen(sdec.ui_scr) end)
    pcall(function() sdec.ui_refresh() end)
    return false
  end

  -- Protocol LAST, because it overrides the wire fields read above.
  local was = sdec.proto or 'uart'
  -- Only when the field exists. With one protocol available there is no field and nothing to
  -- read: sdec.proto stays 'uart', which is the only thing it could be.
  if sdec.opt_proto ~= nil then
    pcall(function()
      sdec.proto = sdec.opt_pick(sdec.opt_proto_list(),
                                 display.getvalue(sdec.opt_proto))
                or 'uart'
    end)
  end
  -- MIDI is the only protocol that pins a BAUD RATE, so it is the only one whose rate
  -- must be dropped when the protocol changes: the form still SHOWS 31250 afterwards, so
  -- reading the field back would carry MIDI's rate onto a LIN bus. Everything else the
  -- operator typed in this visit is theirs and is left alone.
  if sdec.proto ~= was and was == 'midi' then
    sdec.force_baud = nil
    sdec.autolock_defer()
  end

  if sdec.proto == 'midi' then
    -- 31250 8N1 is the MIDI 1.0 specification, not a guess, so forcing it is
    -- strictly better than auto-detection: it also removes every format ambiguity
    -- the detector would otherwise have to report.
    sdec.force_baud, sdec.force_nbits = 31250, 8
    sdec.force_par, sdec.force_nstop = sdec.PAR_NONE, 1
    sdec.ui_mode = 'midi'
  elseif sdec.proto == 'lin' then
    -- LIN is 8N1, one stop bit, idle RECESSIVE (high), all by specification. Pinning them
    -- removes every format and polarity ambiguity the detector would otherwise report -- and
    -- a LIN capture is full of framing errors from its break fields, which is exactly the
    -- input that makes a format search least reliable.
    --
    -- The BAUD RATE is deliberately left alone: LIN specifies a RANGE, 1 to 20 kBd, so there
    -- is nothing to pin. Auto-detection stays the right default and the operator can still
    -- type 19200 in from the datasheet.
    sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
    sdec.force_invert = false
    sdec.ui_mode = 'lin'
  elseif was ~= 'uart' then
    -- Leaving a protocol hands the wire back to the auto-detector. Necessary because the
    -- form still SHOWS the pinned values -- 8 data bits, None, Normal -- so simply
    -- reading the fields back would keep them forced on a line that is no longer MIDI or
    -- LIN.
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop = nil, nil
    sdec.force_invert = nil
    sdec.autolock_defer()
    if sdec.ui_view() ~= nil and sdec.ui_view().res ~= nil then sdec.ui_mode = 'text' end
  end

  ulog.line(string.format('options: proto=%s baud=%s bits=%s any=%s par=%s inv=%s trig=%s',
            tostring(sdec.proto),
            tostring(sdec.force_baud), tostring(sdec.force_nbits),
            tostring(sdec.widths_any),
            tostring(sdec.force_par), tostring(sdec.force_invert),
            tostring(sdec.trigmode)))

  pcall(function() display.changescreen(sdec.ui_scr) end)
  -- Apply means "use these now": capture rather than requiring a second press.
  return sdec.capture()
end

-- Leave the options screen without applying anything.
function sdec.options_cancel()
  -- PUT BACK WHAT WAS IN EFFECT WHEN THE SCREEN OPENED. Closing the screen is not enough:
  -- Lock Detected writes the forced settings immediately, so without this Cancel would leave
  -- the wire configuration it was pressed to abandon. The form is re-seeded so a later open
  -- shows the restored values rather than the abandoned ones.
  sdec.options_restore()
  pcall(function() sdec.options_seed() end)
  pcall(function() sdec.ui_refresh() end)
  return pcall(function() display.changescreen(sdec.ui_scr) end)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================
-- Hook End App on screen scr, so leaving the app tears it down. Returns whether the hook took.
function sdec.install_cleanup(scr)
  local ok = pcall(function()
    display.setevent(scr, display.EVENT_ENDAPP, 'sdec.cleanup()')
  end)
  if not ok then
    -- STICKY, not lasterr: a later capture would clear lasterr, and this fault must outlive it.
    sdec.stickyerr = 'End App is not hooked -- exiting will not clean up'
    ulog.line(sdec.stickyerr)
  end
  return ok
end

-- Tear the app down: release the job, stop the hardware, delete objects, close the log.
function sdec.stop()
  -- ORDER MATTERS: release the decode job and stop the hardware BEFORE the buffer goes.
  --
  -- A live ck_job owns an open file handle on the byte log that only its finish() closes, and a
  -- recording still running is an initiated trigger model writing into sdec.buf -- deleting the
  -- buffer under it is the create-over-a-live-object hazard. Turning the analog trigger off is not
  -- the same as aborting the model.
  if sdec.ck_job ~= nil then pcall(function() sdec.decode_abandon() end) end
  if sdec.strm_recording then
    sdec.strm_recording = nil
    pcall(function() sdec.stream_settle() end)
  end
  sdec.ck_running, sdec.ck_stop = false, false
  pcall(function() trigger.model.abort() end)
  pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
  -- RELEASE THE CANCEL LATCH, for the reason acq_triggered() gives for releasing blender 1: an app
  -- that configures a subsystem should un-configure it, or the next user of blender 2 inherits our
  -- stimuli. sdec.cancel_ok goes with it, so a poll after teardown answers false rather than
  -- reading a blender this app no longer owns.
  sdec.cancel_ok = false
  pcall(function() trigger.blender[sdec.cancel_blender].reset() end)
  sdec.destroy_options()
  sdec.ui_destroy()
  -- SETTLE BEFORE DELETING, AND KEEP THE HANDLE IF THE DELETE IS REFUSED -- the same discipline
  -- acq_make_buffer() uses, and for the same three reasons, all of them the object-lifetime hazard this
  -- app is most careful about.
  --
  -- The abort above does not WAIT, so the trigger model can still own the buffer, and deleting it then is
  -- what posts 4915 -- the store measured against a replaced object. A refused deletion must not report
  -- success, or delfails stays 0 and nothing says the instrument needs a power cycle. And the handle must
  -- not be nil'ed first: it is the ONLY one, so dropping it strands the buffer inside the firmware with
  -- no way to retry and start() allocates another on top of it, one more per relaunch.
  --
  -- Keeping the handle is what makes it recoverable: start() calls acq_make_buffer(), which settles and
  -- retries the delete properly.
  if sdec.buf ~= nil then
    pcall(function() sdec.trig_settle() end)
    local b = sdec.buf
    local delok = pcall(function() buffer.delete(b) end)
    if delok then
      sdec.buf = nil
    else
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'the capture buffer could not be freed -- power cycle the instrument'
    end
  end
  sdec.smp, sdec.nread = nil, 0
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.ei, sdec.es, sdec.ne = nil, nil, 0
  sdec.w, sdec.nw = nil, 0
  sdec.ui_rowc = nil
  ulog.close()
  return true
end

-- End App handler: stop the app and hand the screen back to the instrument.
function sdec.cleanup()
  local r = sdec.stop()
  -- Teardown has just dropped every object handle and the capture buffer. Collecting costs
  -- 8.3 ms, measured.
  pcall(function() collectgarbage() end)
  return r
end

-- Entry point: open the log, build the UI, hook End App, and take a first capture. Everything is
-- under pcall. Returns false and a reason if a rebuild is refused or the build fails.
function sdec.start()
  -- ONE BUILD PER POWER CYCLE UNLESS THE TEARDOWN WAS CLEAN, and this is where a second one is
  -- refused. A second ui_build() over live objects crashes the firmware hard enough to need the
  -- front-panel POWER button, which costs a reboot and a reinstall.
  --
  -- REMOTE RECOVERY FROM THAT IS THIN, which is what makes the refusal worth its four lines for
  -- any unattended use:
  --   * the POWER switch is a SOFT button -- the manual's own description is "to turn the
  --     instrument on, press the power switch. To turn it off, press and hold" -- so a mains
  --     interruption most likely leaves the meter in standby rather than rebooting it.
  --   * the LXI virtual front panel is explicit: "You cannot switch the instrument on or off
  --     with the power switch."
  -- So a smart plug can switch the meter OFF but probably not ON.
  --
  -- What makes a rebuild safe is the TEARDOWN, not the power cycle. Creating over a live handle
  -- overwrites the only reference to a firmware object and strands it until power is removed; that
  -- accumulation is what walks this firmware toward a panic. sdec.cleanup() deletes every object
  -- it created, nils the handles, and collects -- so after it there are no live handles to create
  -- over, and the delete/nil/create order the rest of this file follows is preserved.
  --
  -- sdec.delfails counts refused deletions. Non-zero means the teardown did NOT fully succeed,
  -- objects have leaked, and a further build genuinely is a risk -- so that, and only that, is
  -- what refuses. sdec.allow_rebuild = true overrides it, so how many start()/cleanup() cycles
  -- the firmware tolerates can be measured deliberately; opt-in, never the default.
  if sdec.built then
    pcall(function() sdec.cleanup() end)
    -- Retry anything a previous teardown could not delete BEFORE counting failures: a handle kept
    -- by del_obj is reclaimable, and reclaiming it is what keeps the object pool from filling.
    local left = 0
    pcall(function() left = sdec.del_orphans() end)
    if left < 1 then sdec.delfails = 0 end
    local nfail = sdec.delfails or 0
    if nfail > 0 and not sdec.allow_rebuild then
      local why = string.format('teardown left %d object(s) undeleted -- rebuilding over leaked '
                                .. 'handles risks a firmware panic. Power cycle, or set '
                                .. 'sdec.allow_rebuild = true to override.', nfail)
      sdec.lasterr = why
      pcall(function() ulog.line('start refused: ' .. why) end)
      return false, why
    end
    pcall(function() ulog.line('rebuilding: previous UI torn down cleanly') end)
  end
  -- SET BEFORE ui_build(), deliberately: a build that fails halfway is exactly the dangerous
  -- state, so a failed attempt has to count as an attempt.
  sdec.built = true

  local ok, err = pcall(function()
    ulog.tag = 'SDEC'
    ulog.open(sdec.logpath)

    -- THE CANCEL KEY, WIRED ONCE. Every long job polls the latch this arms; without it they fall
    -- back to their own bounds, so it is set up before the first capture and never re-armed
    -- per run. Inside the build guard because a failure here must not cost the screen -- it
    -- cannot fail, being one pcall deep already, but the guard costs nothing to keep.
    sdec.cancel_setup()
    sdec.ui_build()
    -- Hook End App as soon as a screen exists, before anything that could fail.
    sdec.install_cleanup(sdec.ui_scr)
    sdec.build_options()

    display.changescreen(sdec.ui_scr)
    sdec.ui_status = 'ready -- press Capture'
    sdec.ui_refresh()
  end)

  if not ok then
    sdec.lasterr = tostring(err)
    -- THE USB LOG IS THE ONLY PLACE THIS CAN BE READ. A failed build has no note row to put it on
    -- and no screen to show one, which is the whole reason usb_log.tsp exists.
    ulog.line('start failed: ' .. sdec.lasterr)
    pcall(function() sdec.stop() end)
    -- `built` was set BEFORE the build, so a failure has to retract it. Left true it claims a UI
    -- that is not there: the next start() takes the rebuild path and tears down nothing, and any
    -- caller testing sdec.built to decide whether the app is usable is told yes.
    sdec.built = false
    return false, err
  end

  -- The first capture is OUTSIDE the build guard: a quiet pin is the likeliest thing on a fresh
  -- launch, and must leave a usable screen saying so rather than tearing down a good UI.
  pcall(function() sdec.capture() end)
  return true
end

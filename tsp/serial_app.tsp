-- serial_app.tsp -- lifecycle, touch handlers and capture orchestration for the Keithley TSP
-- serial decoder (TSP / Lua 5.0.2).
--
-- Needs a digitizer reachable as dmm.digitize, the touchscreen app API (display.create and the
-- OBJ_* types), and Lua 5.0.2. Only the DMM6500 has been tested; docs/PROJECT.md has the per-model
-- verdicts, and $Product: in the .tspa header decides where it installs.
--
-- OBJECT LIFETIME, throughout: delete, nil, then create. Creating over a live handle strands the
-- object beneath it in the firmware until a power cycle, and that accumulation walks this firmware
-- toward a PC=002F751C panic. sdec.delfails counts refused deletions.
--
-- Decoding is single-shot, so there is no frame timer: display writes happen on a button press.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.delfails  = sdec.delfails or 0
sdec.fillfails = sdec.fillfails or 0
sdec.errcount  = sdec.errcount or 0
sdec.busy      = sdec.busy or false
-- All three derive from ulog.usbdir. usb_log.tsp loads first, so the fallback is for a harness.
sdec.usbdir    = sdec.usbdir or (ulog ~= nil and ulog.usbdir) or '/usb1/SERDEC'
sdec.logpath   = sdec.logpath or (sdec.usbdir .. '/serial_decode_log.txt')
-- Prefix of the byte log, which every mode appends to, not just FRAME.
sdec.flogpfx   = sdec.flogpfx or (sdec.usbdir .. '/bytes')
sdec.savepfx   = sdec.savepfx or (sdec.usbdir .. '/serial_')
-- Migrated, not just defaulted: `or` keeps whatever a previous load left, so an App reload over a
-- build that wrote to the key's root would keep writing there. Only the old defaults move.
if sdec.logpath == '/usb1/serial_decode_log.txt' then
  sdec.logpath = sdec.usbdir .. '/serial_decode_log.txt'
end
if sdec.flogpfx == '/usb1/bytes' then sdec.flogpfx = sdec.usbdir .. '/bytes' end
if sdec.savepfx == '/usb1/serial_' then sdec.savepfx = sdec.usbdir .. '/serial_' end
sdec.saveext   = sdec.saveext or '.txt'
-- Protocol layer over the UART bytes: 'uart' (none), 'midi' or 'lin'. Operator state, so `or` like
-- the rest -- an App relaunch must not drop someone's MIDI or LIN choice back to raw UART.
sdec.proto     = sdec.proto or 'uart'
-- Press-driven streaming, which the panel does not use: true = Capture starts a recording, stops it,
-- then steps the decode a slice per press. false ships, and does the whole job in one press. Nothing
-- in the app sets it; test_cancel.lua and test_serial.lua drive the stepped path. The one-press path
-- cannot be stopped by a finger -- a press on TRIGGER emits no blender event while a panel-initiated
-- run executes -- so record_run()'s fc_maxwin/fc_maxsec bounds are the exits. A nil test rather than
-- `or`, because false is meaningful and `false or true` is true.
if sdec.strm_press == nil then sdec.strm_press = false end
-- Wall-clock ceiling on one streaming acquisition, seconds; nil means no bound. A backstop: a run
-- normally ends at the buffer or at a quiet line. 1200 s is where stream_maxwait already caps, and
-- two bounds that disagree make the smaller a hidden cap -- a 32 kB window is 1092 s at 300 baud.
sdec.strm_maxsec = sdec.strm_maxsec or 1200
-- Seconds of signal the fallback path may record when the trigger model refuses to arm. Shorter than
-- strm_maxsec because a blocking read cannot be polled: its whole length is uninterruptible.
sdec.strm_fallback_s = sdec.strm_fallback_s or 20
-- sdec.savedas  -- the last filename written, for the note line
-- sdec.stickyerr -- a fault that must outlive a capture (see install_cleanup)

-- Drop a decode result a later pass has invalidated, and nothing else. Returns true.
--
-- autoset() runs up to three captures per press, and a pass failing at acquire() returns before any
-- decode -- so the previous pass's res, baud and fitq survive beside the failed capture's acq_fs and
-- levels. docs/MEASUREMENTS.md, 'A failed re-capture leaves a stale fit'. Not clear_result(), which
-- also drops probe_note and lasterr: here they are the only record of what failed.
function sdec.drop_stale_result()
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
  -- clear_result()'s own values, not nil: ui_field_colour reads fitq numerically.
  sdec.snapped, sdec.fitq, sdec.snapfirm = false, 0, true
  -- These describe the dropped result; probe_note and lasterr describe this pass.
  sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
  return true
end

function sdec.clear_result()
  -- At the top of capture(), before anything can fail: the acquisition can fail before decode_from().
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
  sdec.snapped, sdec.fitq, sdec.snapfirm = false, 0, true
  sdec.lo, sdec.hi, sdec.family = nil, nil, '?'
  sdec.vmin, sdec.vmax, sdec.wlo, sdec.whi = nil, nil, nil, nil
  sdec.thr, sdec.hyst, sdec.swing = 0, 0, 0
  sdec.ne, sdec.ei, sdec.es = 0, nil, nil
  sdec.smp, sdec.nread = nil, 0
  sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
  sdec.lasterr, sdec.savedas, sdec.probe_idle = nil, nil, nil
  -- The intermediate measurements the next search runs ON -- acq_fs, the pulse widths and their
  -- median, polarity, the run statistics -- each written only on the good path.
  sdec.clear_measured()
  -- The main eviction point for the note cell: most sources are per-capture, so they go together and
  -- none can latch over the others. A latched note puts 'auto-locked 9600' over later bytes.
  sdec.mode_exited, sdec.lognote, sdec.autolocknote = nil, nil, nil
  sdec.mode_exitbad = false
  -- Evicted here too: both describe THIS capture and must not accuse the next one.
  sdec.strm_releveled, sdec.proto_why = nil, nil
  -- relocked is the exception: its note must survive to the end of the press, or correct bytes appear
  -- with nothing saying the operator's locked rate was dropped. capture() clears it per press.
  sdec.probe_note = nil                 -- set by autoset() when it had to re-capture slower
  -- The previous capture's 20 000-entry sample table is now unreachable. 8.3 ms against a 1.6 s
  -- capture, and Lua memory pressure is a suspect in this firmware's panics.
  pcall(collectgarbage)
  return true
end

-- Drop the whole lock -- every forced setting, not just the rate. Returns true.
--
-- All five or none. Clearing force_baud ALONE leaves the format pinned, because autolock_try() sets
-- nbits, par and nstop with the rate: the app then still decides the format from the previous
-- capture's answer while appearing unlocked.
function sdec.unlock_all()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  -- The provenance goes with the lock it describes, or the next back-off clears what was typed.
  sdec.autolock_set = nil
  return true
end

-- Everything the app and the decoder learned, back to a known value, before any attempt to determine
-- a baud rate or decode. Returns true.
--
-- Called once per press at the top of capture(). What it adds over clear_result() plus
-- clear_measured() is the REQUESTED sample rate, which they must not touch: autoset() carries fs and
-- fs_want from its probe pass into its real one, and a per-acquire reset would cap every unlocked
-- capture at ~19 bytes. fs_select() rather than an assignment, because the deterministic value is
-- whatever the current lock and mode imply, and computing that twice is how the two drift apart.
--
-- It does NOT unlock: a forced rate is a decision the operator can see on the padlock. A harness
-- that wants a virgin app calls sdec.unlock_all() first.
function sdec.detect_reset()
  sdec.clear_result()
  sdec.fs_want = nil
  sdec.fs_select()
  return true
end

-- ============================================================================
-- Capture orchestration
-- ============================================================================
-- The one armed capture a silent line gets. Reached from autoset() when the probe ladder found no
-- transitions and the operator's trigger mode is one that waits. Returns ok, reason.
--
-- No second pass and no octave retry, unlike the tail of autoset(): a re-capture is more data
-- everywhere else, and here it is strictly less, because the device's opening bytes exist only in the
-- window that caught them. docs/TRIGGER.md section 7 for why the pre-trigger reserve makes the start
-- recoverable. The rate is blind by construction -- arm_fs() trades window against coverage.
function sdec.arm_capture()
  local fs = sdec.arm_fs()
  -- fs_want as well as fs: fs_select() resets the rate to fs_default when nothing is locked, and
  -- nothing is locked here, so without the one-shot this capture holds a fifth of the window.
  sdec.fs, sdec.fs_want = fs, fs
  sdec.probe_note = string.format(
    'armed at %g kS/s on a line that has not started -- lock the baud rate for a longer window',
    fs / 1000)
  local ok, why = sdec.acquire()
  -- Before any decode, so a failed arm cannot leave the probe's fit beside this capture's rate.
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  if dok then return true end
  -- Nothing fitted, so try what the wire probably is -- over these samples, not a new capture.
  if sdec.arm_fit_prior() then return true end
  sdec.drop_stale_result()
  return false, dwhy
end

-- Is this candidate bit time compatible with the pulses actually on the wire? The filter the prior
-- ladder applies BEFORE spending a decode, and it is the detector's own battery of three tests.
-- Without it the ladder is unsafe and the frame gate cannot rescue it: docs/MEASUREMENTS.md, 'The
-- prior ladder needs the pulse-width filter'. It fails closed with no evidence -- all three answer
-- 'no objection' to a missing width array, so sig_bittime() must have run first.
function sdec.arm_try_ok(T, n)
  if T == nil or T <= 0 then return false end
  if sdec.wmed == nil or sdec.wmed <= 0 then return false end
  if (sdec.nw or 0) < sdec.submult_minpulses then return false end
  if not sdec.ua_plausible(T, n) then return false end
  if sdec.ua_submultiple(T) then return false end
  if sdec.ua_minrun_absurd(T) then return false end
  return true
end

-- How clean a guessed rate has to decode, as a fraction of interior frames in error. Far tighter than
-- relock_badfrac and not interchangeable: that one asks whether a typed rate has been discredited,
-- this one whether the app may invent a rate. docs/MEASUREMENTS.md, 'arm_badfrac = 0.02'.
sdec.arm_badfrac = 0.02

-- Is this decode clean enough to publish an invented rate on? A wrong bit time will still frame
-- bytes; what it cannot do is frame most of them cleanly. The frame floor is relock_minframes.
function sdec.arm_fit_ok()
  local r = sdec.res
  if r == nil then return false end
  if (r.nf or 0) < sdec.relock_minframes then return false end
  local bf = sdec.ua_badfrac(r)
  if bf == nil then return false end
  return bf < sdec.arm_badfrac
end

-- Fit the operator's prior to samples already in hand. Called by arm_capture() when a blind armed
-- capture caught the device's first bytes and no bit time could be measured from them. Returns
-- whether EXACTLY ONE of sdec.arm_try frames those samples cleanly.
--
-- Uniqueness, not the first fit: clean frames at a wrong rate are the normal outcome, because half
-- the true rate reads two real frames as one and lands its stop bit where a real one is. Every
-- surviving candidate is decoded, which is CPU and nothing else. docs/MEASUREMENTS.md, 'Uniqueness,
-- not first fit, for a guessed rate'.
--
-- decode_from(), not decode(): decode() second-guesses a forced rate, and here the lock is this
-- function's own hypothesis and the fallback measurement has already failed.
function sdec.arm_fit_prior()
  local rd, n = sdec.smp, sdec.nread
  if rd == nil or n == nil or n < 2 then return false end
  local fs = sdec.acq_fs or sdec.fs
  if fs == nil or fs <= 0 then return false end
  -- The widths are this function's evidence, so it measures them itself: they belong to one capture,
  -- and inheriting whatever ran last had the previous capture's median pulse reject the true rate of
  -- this one. The return value is ignored -- this is reached precisely because no bit time fits.
  sdec.sig_bittime()
  local was, won, alt = sdec.force_baud, nil, nil
  -- Wrapped, because decode_from can raise and both restores sit after the call -- so a raise left the
  -- operator's Auto converted into a hard lock. Around the LOOP: a raise defeats every hypothesis.
  pcall(function()
    local i
    for i = 1, table.getn(sdec.arm_try) do
      local b = sdec.arm_try[i]
      if sdec.arm_try_ok(fs / b, n) then
        sdec.force_baud = b
        if sdec.decode_from(rd, n) and sdec.arm_fit_ok() then
          if won == nil then won = b else alt = b end
        end
      end
    end
  end)
  sdec.force_baud = was
  if won == nil then return false end
  if alt ~= nil then
    -- Ambiguity is an answer: it names the two rates the capture cannot tell apart, which is what the
    -- operator needs to resolve it from the one thing the instrument does not know.
    sdec.probe_note = string.format(
      'this capture fits %d Bd AND %d Bd equally -- lock the rate in Options to decide', won, alt)
    return false
  end
  -- Re-decoded at the winner: the loop left sdec.res holding whichever candidate it tried last.
  sdec.force_baud = won
  -- Guarded like the loop, and this is the call with the operator's field already overwritten.
  local ok = false
  pcall(function() ok = sdec.decode_from(rd, n) end)
  sdec.force_baud = was
  if not ok then return false end
  -- The panel must not present an assumption as a measurement.
  sdec.probe_note = string.format(
    'no bit time could be measured -- decoded at an ASSUMED %d Bd; lock the rate to be sure', won)
  return true
end

-- Pick the sample rate, capture, and decode. Returns ok, reason.
function sdec.autoset()
  local target = sdec.force_baud
  local captured = false
  -- Per call. baud_probe is set only by giveup() and only for one call, and that held only when a
  -- decode ran: an acquisition failure never reaches decode_from(), so a retracted rate outlived it.
  sdec.baud_probe = nil

  -- Two passes, because sample rate trades resolution against DURATION and only one is knowable in
  -- advance: 1 MS/s oversamples anything up to ~125 kBd but fills the 20 000-sample buffer in 20 ms,
  -- barely 19 bytes at 9600 baud. So the first pass finds the baud at the top rate and the second
  -- re-captures at the lowest rate still giving 8 samples/bit. A forced rate skips the first pass.
  if target == nil then
    sdec.fs = sdec.rates[table.getn(sdec.rates)]      -- top rate: 1 MS/s
    -- The probe pass free-runs whatever the operator selected, and it is retried. Arming a trigger
    -- model here posts 4915 ten times a capture at ERROR severity, which showevents cannot mute, so
    -- the event has to not happen: docs/MEASUREMENTS.md, 'Event 4915 on the probe pass'. The cost is
    -- that a 20 ms window can land inside a slow line's idle gap, which is what the retries are for.
    -- Restored through pcall, or a raise inside acquire() leaves trigmode on 'free' for the session
    -- while the panel still says Edge.
    local savetrig = sdec.trigmode
    sdec.trigmode = 'free'
    local ok, why, tries = false, nil, 0
    -- Each retry looks for LONGER, by dropping the sample rate rather than repeating the same window:
    -- 20 ms, 200 ms, 2 s for the same 20 000 samples. 20 ms is less than one frame at 300 baud. The
    -- first look keeps the resolution a 250 kBd line needs.
    local ladder = sdec.probe_fs or {1000000, 100000, 10000}
    local nlad = table.getn(ladder)
    -- Registered for the boundary rather than guarded here: sdec.guard can see a field, where savetrig
    -- is a local it cannot.
    sdec.trig_restore = savetrig
    while tries < nlad do
      tries = tries + 1
      sdec.fs, sdec.fs_want = ladder[tries], ladder[tries]
      ok, why = sdec.acquire()
      if ok then
        ok, why = sdec.decode()
        if ok or sdec.baud_probe ~= nil then break end
      end
    end
    sdec.trigmode = savetrig
    sdec.trig_restore = nil
    if tries > 1 then
      sdec.probe_note = string.format(
        'probe took %d looks to catch traffic (down to %g kS/s)', tries or 0, ladder[tries] / 1000)
    end
    if not ok then
      -- A probe that measured the bit time but could not frame a byte is not a failure: 20 ms at 1 MS/s
      -- is six bit times at 300 baud. The retracted rate only chooses the second pass's sample rate.
      -- docs/MEASUREMENTS.md, 'The probe ladder and the octave retry'.
      if sdec.baud_probe == nil then
        -- A line that has not started is not a probe failure, it is the armed case: the device
        -- transmits when it is powered on, and until then there is nothing to measure. Still refused
        -- where there is nothing to wait for -- see sdec.arm_silent, and docs/MEASUREMENTS.md,
        -- 'Arming from silence needed a locked rate to reach'.
        if sdec.arm_silent() and savetrig ~= 'free' then return sdec.arm_capture() end
        sdec.drop_stale_result() return false, why
      end
      target = sdec.baud_probe
      sdec.probe_note = string.format(
        'too slow to frame at 1 MS/s -- re-captured at the rate the probe measured (%.0f Bd)',
        target or 0)
    else
      captured = true
      target = sdec.baud
    end
    -- Only worth a second pass if a genuinely lower rate would still oversample adequately.
    if target == nil then return true end
  end

  local want = sdec.pick_fs(target, 8)
  -- `captured`, not `sdec.res ~= nil`: with a forced rate the block above is skipped, so a leftover
  -- result would let a forced rate perform zero digitizer reads and return success.
  if captured and want >= sdec.fs then return true end

  -- fs_want, not just sdec.fs: without it fs_select() caps every unlocked capture at 19 bytes.
  sdec.fs = want
  sdec.fs_want = want
  -- A bare call: this path carries ONE pcall and it is sdec.capture()'s. See the depth note in start().
  local ok, why = sdec.acquire()
  -- Before any decode, or the probe's baud and fit stay beside the failed capture's rate.
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  if not dok then sdec.drop_stale_result() return false, dwhy end

  -- The probe can be an octave out, and it costs half the window when it is: every edge interval that
  -- is a multiple of T is also a multiple of T/2, and the probe has 4 ms. docs/MEASUREMENTS.md, 'The
  -- probe ladder and the octave retry'. Once, and only downward -- `w2 < sdec.fs` means a longer
  -- window, so the retry can only increase the byte count and cannot oscillate.
  if sdec.baud ~= nil and sdec.baud > 0 then
    local w2 = sdec.pick_fs(sdec.baud, 8)
    if w2 ~= nil and w2 < sdec.fs then
      sdec.probe_note = string.format(
        'probe fitted %.0f Bd, wire is %.0f -- re-captured at %g kS/s for the full window',
        target or 0, sdec.baud or 0, w2 / 1000)
      sdec.fs, sdec.fs_want = w2, w2
      local ok2, why2 = sdec.acquire()
      -- Same reason as the second pass above: this returns before the re-decode.
      if not ok2 then sdec.drop_stale_result() return false, why2 end
      local d2ok, d2why = sdec.decode()
      if not d2ok then sdec.drop_stale_result() return false, d2why end
      return d2ok, d2why
    end
  end
  return true
end

-- ============================================================================
-- The byte log
-- ============================================================================
-- One file, shared by every mode, and separate from the debug log: ulog is a trace of notes and
-- refusals, and interleaving the device's own messages with it makes both harder to read. The name is
-- chosen once per session, so successive captures append to one file.
--
-- Decoded bytes only, never samples -- here, in frame_log(), in ck_sink_file() and in save(). A 32 kB
-- stream is 3.4 M samples, ~34 MB of text against 32 kB of bytes, for data nothing downstream reads.
-- ============================================================================
--
-- Allocate the byte log's filename. Returns the path, or nil with sdec.flog_why set.
function sdec.flog_alloc()
  -- A different key needs a different name: ulog.keygen bumps when a key is inserted after one was
  -- gone, and MODE_APPEND on a name already used there would extend a stranger's file. The ask comes
  -- first, or the guard cannot fire on its own -- keygen only advances when something calls
  -- ulog.keyok(), and next_free() below is skipped on the one path the guard exists for.
  ulog.keyok()
  if sdec.flog_keygen ~= (ulog.keygen or 0) then
    sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
    sdec.flog_keygen = ulog.keygen or 0
  end
  if sdec.flog_path ~= nil then return sdec.flog_path end
  -- Lazy: the scan is 1000 file.open calls, and a filename would be burnt per session either way.
  sdec.flog_path = ulog.next_free(sdec.flogpfx, '.txt', 1000)
  if sdec.flog_path == nil then
    -- Name the reason next_free gave: it refuses for three different reasons and only one of them is
    -- the names running out, so a flat 'no free name' was wrong for the commonest case. No
    -- ' -- not logging' suffix, because ui_notes already prefixes 'NOT LOGGING: '.
    sdec.flog_why = tostring(ulog.idx_why or
                             ('no free ' .. string.gsub(sdec.flogpfx, '^.*/', '') .. 'NNN.txt name'))
    return nil
  end
  sdec.flog_n, sdec.flog_bytes = 0, 0
  return sdec.flog_path
end

-- Append one capture to the byte log: a header line, then its text lines, then its hex lines.
function sdec.frame_log()
  if sdec.res == nil or sdec.res.nf < 1 then return false end
  if sdec.flog_alloc() == nil then return false end
  -- open_write, not file.open: it carries the no-key gate and the reason string. It does not recover
  -- from a key swapped since the name was allocated -- that is reported, not worked around.
  local fh, fwhy = ulog.open_write(sdec.flog_path, file.MODE_APPEND)
  if fh == nil then
    sdec.flog_why = 'cannot append to ' .. tostring(sdec.flog_path)
    return false
  end
  -- Registered for the unwind: a FORMATTER can raise here, where a file call cannot, measured.
  sdec.fh_unwind = fh
  -- Counted after the write: the promise of that number is that it says what is on the key.
  local nfr = 0
  if sdec.res ~= nil then nfr = sdec.res.nf end
  -- The header line needs the message NUMBER, but flog_n advances only on success.
  local msgno = (sdec.flog_n or 0) + 1
  file.write(fh, string.format('---- msg %d  %s %s  %d bytes %d err\r\n',
                               msgno or 0, tostring(sdec.baud_text()), tostring(sdec.fmt_text()),
                               sdec.res.nf or 0, sdec.res.nbad or 0))
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
  file.close(fh)
  sdec.fh_unwind = nil
  -- The presence check is the whole test: a write that posted 2200 returns normally (ulog.keylost), so
  -- nothing the writes report can see a key pulled since the open. 237 us with a key in.
  if not ulog.keyok() then
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
-- A recording is two presses: stream_begin() arms the hardware and RETURNS, stream_stop() stops it and
-- decodes. Between them nothing of ours runs, so the recording lasts as long as the operator wants and
-- the panel stays live. What that costs is the quiet-line watchdog, which only advances while
-- sdec.stream() is polling. Every entry point here is guarded end to end and returns ok, reason:
-- they are all reached from a touch handler.
-- ============================================================================
--
-- Size a streaming capture, allocate its buffer, learn the levels and arm the idle watchdog.
-- Returns ok, reason, and leaves the sample count in sdec.strm_nsmp.
function sdec.stream_begin()
  local md = sdec.mode_cur()
  local why = sdec.mode_why(md)
  if why ~= nil then return false, why end
  -- Same degrade-rather-than-raise rule the protocol modules follow: chunk_decode.tsp is a separate
  -- module, so a build that omitted it must refuse with a reason rather than raise from a handler.
  if sdec.ck_run == nil then
    return false, 'this build omits chunk_decode.tsp -- the streaming modes need it'
  end

  sdec.hw_config()                      -- picks fs from the locked baud rate
  local fs = sdec.fs
  local nsmp = sdec.stream_samples(md, fs)
  if nsmp == nil then return false, 'cannot size the capture for this rate' end

  -- Headroom, the same +100 acq_cap() adds: the model can make a reading or two past `count` before
  -- abort() takes effect, and on a buffer sized exactly `count` that is a store past capacity -- 4915
  -- at error severity, 20-30 a capture. Only the capacity grows, so `have >= nsmp` still means full.
  local cap = nsmp + 100
  -- An armed recording needs the pre-trigger reserve on top: LoopUntilEvent takes its reserve out of
  -- CAPACITY, so a buffer sized at nsmp records 5 % less than was asked for. On trigger mode alone,
  -- because the probe that decides whether the line is silent reads INTO this buffer.
  if sdec.trigmode ~= 'free' and (sdec.pretrig or 0) > 0 then
    cap = math.ceil(nsmp * 100 / (100 - sdec.pretrig)) + 100
    -- And the reserve comes out of the recording where there is no room for it: overrunning ck_bufmax
    -- would turn the largest modes into an allocation refusal, a worse answer than 5 % less.
    if sdec.ck_bufmax ~= nil and cap > sdec.ck_bufmax then
      cap = sdec.ck_bufmax
      nsmp = math.floor(cap * (100 - sdec.pretrig) / 100)
    end
  end
  -- The reading ceiling covers all buffers together, and 4919 is what a request past it files, so
  -- buffer.make() here can need a default buffer shrunk first. docs/UNDOCUMENTED.md, 'The real ceiling
  -- is 7,080,255 readings'. A bare call: acq_make_buffer() guards it and leaves sdec.buf nil.
  sdec.acq_make_buffer(cap)
  -- Reclaim and retry once, because the capacities are the operator's to change MID-SESSION and this is
  -- the one place that catches a change made after the launch swept. Once, not in a loop: a second
  -- failure after the room was freed is not a room problem, and retrying would hang inside a press.
  if sdec.buf == nil then
    local rswept, rsweptwhat = sdec.buf_sweep()
    if rswept > 0 then
      ulog.line(string.format('swept %d readings to make room mid-session: %s', rswept, rsweptwhat))
    end
    local rdid, rwhat = sdec.buf_reclaim()
    if rdid then
      ulog.line('reclaimed ' .. rwhat .. ' to make room mid-session -- its readings are discarded')
    end
    if rswept > 0 or rdid then
      sdec.ck_bufmax, sdec.ck_bigbuf, sdec.ck_bigcap = sdec.bufmax_for()
      sdec.acq_make_buffer(cap)
    end
  end
  if sdec.buf == nil then
    -- Name the buffer that is actually large, re-read here: sending the operator at defbuffer2 while
    -- defbuffer1 holds the readings fails the allocation a second time.
    local _, bigname, bigcap = sdec.bufmax_for()
    local why
    if bigname ~= nil then
      why = string.format('cannot allocate %d readings -- %s still holds %d of the %d the '
                          .. 'instrument has, and resizing the default buffers down did not '
                          .. 'free enough.', cap or 0, bigname, bigcap or 0, sdec.ck_bufpool)
    else
      why = string.format('cannot allocate %d readings, and the default buffer capacities could '
                          .. 'not be read, so there is nothing to resize', cap or 0)
    end
    sdec.lasterr = why
    ulog.line('recording refused: ' .. why)
    return false, why
  end

  -- Learn the levels before the long recording: the watchdog needs a threshold, and capture() has just
  -- zeroed thr and hyst. The probe reads into the buffer just allocated, so it costs no allocation.
  sdec.ck_watch = false
  -- Bounded in time, not just in samples: read() blocks for pn/fs seconds and fs follows the locked
  -- rate, so 2000 samples at 110 baud would hold the handler ~2 s. A quarter of the latency budget.
  local pn = sdec.probe_n
  if pn > nsmp then pn = nsmp end
  local budget = 0.25 * (sdec.ui_latency_s or 0.5)
  local pmax = math.floor((sdec.fs or 1000) * budget)
  if pmax < 200 then pmax = 200 end
  if pn > pmax then pn = pmax end
  -- nofc: a probe must not spend a flow-control credit. probe_idle is cleared first because
  -- arm_silent() reads it, and the previous capture's answer is not this recording's.
  sdec.probe_idle = nil
  -- And the arm pair with it: this path skips clear_measured(), so a stale pair would arm this
  -- recording at the previous capture's level on its edge.
  sdec.arm_thr, sdec.arm_idle = nil, nil
  local pok = pcall(sdec.acq_free, pn, nil, true)
  if pok and sdec.nread ~= nil and sdec.nread > 1 then
    local lok, lwhy = sdec.sig_levels(sdec.smp, sdec.nread)
    -- Only arm the watchdog if the levels are real: a capture that runs to the end of the buffer is
    -- recoverable, and a four-minute session truncated to five seconds is not.
    if lok and sdec.thr ~= nil and (sdec.swing or 0) >= sdec.minswing then
      sdec.ck_watch = true
    else
      -- A probe that saw no transitions is the arm-from-silence case, and recording it here is what
      -- lets a recording wait for a device that has not started. Only for a probe that RAN: one that
      -- raised is a fault, and arming a 120 s wait on a broken digitizer is not the answer to it.
      sdec.probe_idle = lwhy or 'line is idle (no transitions)'
    end
  end
  -- The probe found nothing, which is the normal case for the two runs that need the watchdog most: a
  -- device under flow control stays silent until the credit leaves, and later windows are probed while
  -- it waits for the next one. So fall back to the levels the last good capture measured, which exist
  -- whenever a rate was locked -- and a locked rate is already required to enter this mode.
  if not sdec.ck_watch and sdec.lvl_thr ~= nil and
     (sdec.lvl_swing or 0) >= sdec.minswing then
    sdec.thr, sdec.hyst, sdec.swing = sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing
    sdec.ck_watch = true
    sdec.strm_lvlreuse = true
  else
    sdec.strm_lvlreuse = nil
  end
  -- The arm level is computed whatever the reuse did, and a guard skipping it is the whole of a measured
  -- defect: gating on `not strm_lvlreuse` means arm_threshold() never runs after a successful decode,
  -- and the comparator is armed at the last decode's midpoint -- mid-data, so it fires on a data edge.
  -- The reused threshold is put back: the watchdog wants the measured midpoint, not idle plus Arm At.
  if sdec.probe_idle ~= nil then
    local kthr, khyst, kidle = sdec.thr, sdec.hyst, sdec.idle
    if sdec.arm_threshold() and sdec.strm_lvlreuse then
      sdec.thr, sdec.hyst, sdec.idle = kthr, khyst, kidle
    end
  end
  -- The Lua copy goes; the count stays. sdec.nread is what a finished run is reported by, and zeroing
  -- it here published 0 beside 5 487 decoded bytes. stream_settle() overwrites it next.
  sdec.smp = nil

  -- ck_stop = false on entry is the authoritative clear: mode_exit() can leave it set after a stop the
  -- loop never saw, and no unwind path clears it. Without this the next run aborts at once.
  sdec.ck_running, sdec.ck_stop, sdec.ck_nbytes, sdec.ck_tot = true, false, 0, nil
  sdec.ck_endwhy = nil
  -- Per run, beside ck_endwhy: a level left by a previous expired arm would be quoted at the next.
  sdec.arm_expired_at = nil
  -- ck_cancel is cleared here, not in record_run(), because every run of either shape comes through
  -- this function -- cleared there, a cancelled run's flag would credit TRIGGER for the next one.
  sdec.ck_cancel = nil
  sdec.progress(0)

  sdec.strm_nsmp = nsmp
  return true
end

-- The one-shot form: begin, poll to the end, then decode, all in one call.
function sdec.stream()
  local ok, why = sdec.stream_begin()
  if not ok then return false, why end
  local got = 0
  local aok, ares = pcall(sdec.stream_acquire, sdec.strm_nsmp)
  if aok then got = ares or 0 end
  sdec.ck_running = false
  -- Flagged, not just reported: record_run() treats "the credited device sent nothing" as the END of a
  -- transmission, and a write failure or a failed allocation arrive the same way, as false plus text.
  sdec.strm_empty = nil
  -- A raise is not a quiet line. Conflated, two callers turn strm_empty into a reassuring sentence --
  -- record_run() rewrites an empty window into fc_end='quiet', strm_exit_why() lets a cancel outrank it
  -- -- so a digitizer that FAULTED was reported as the device finishing tidily. A raise never sets it.
  if not aok then
    return false, 'recording failed: ' .. tostring(ares or 'unknown')
  end
  if got < 2 then
    sdec.strm_empty = true
    return false, 'long capture returned nothing'
  end
  -- A cancel during the recording stops the recording, not the bytes it collected: ck_stop is still set
  -- and ck_progress reads it as "abort", so the decode below would end at window zero. Not followed by
  -- a cancel_clear() -- the latch auto-resets on the read that saw the press, and clearing it again
  -- discards a SECOND press made during stream_settle(). ck_cancel is left set for the note row.
  if sdec.ck_stop then sdec.ck_stop = false end
  return sdec.stream_decode(got)
end

-- What one press may spend under flow control. The normal ending needs no bound -- a credited window
-- that comes back quiet means the device has finished -- so these are for the device that never stops.
--
-- Two bounds, because the window count alone is not a time: each window's acquisition is bounded
-- separately and the decode costs more than the acquisition did. fc_maxsec is wall clock, and it is the
-- bound that binds. Under flow control it costs nothing but a press, since the sender is still waiting
-- where the run left off. docs/MEASUREMENTS.md, 'fc_maxwin = 32 and fc_maxsec = 1200'.
--
-- These bounds are the exit: cancel_pressed() answers false for ever while a panel-initiated run
-- executes, so nothing else ends the loop.
sdec.fc_maxwin = sdec.fc_maxwin or 32
sdec.fc_maxsec = sdec.fc_maxsec or 1200

-- ONE PRESS, ONE WHOLE TRANSMISSION: record, decode and save, and under flow control keep issuing
-- credits until the device stops. Returns the run's verdict and, on a failure, its reason.
function sdec.record_run()
  -- Discard a latched press before starting: TRIGGER is the stop control, so the press that ended the
  -- LAST run is still in the blender's latch and would cancel this one at its first window.
  sdec.cancel_clear()
  -- strm_empty is cleared here too: stream() clears it only after stream_begin() succeeds, so a window
  -- failing early leaves the previous run's value and the quiet test reads a failure as a tidy ending.
  -- ck_cancel for the same reason -- stream_begin()'s clear sits past the level probe.
  sdec.ck_cancel, sdec.fc_end, sdec.strm_empty = nil, nil, nil
  sdec.fc_win, sdec.fc_bytes, sdec.fc_secs = 0, 0, 0
  -- The clock is ours for the length of a run. The instrument has ONE timer, and the two other things
  -- that hold it do not overlap: stream_acquire() bounds itself with a counter, and strm_absorb_arm()
  -- stamps the moment a run ENDED, after this returns. See chunk_decode's WHY WINDOWS AND NOT SECONDS.
  -- Taking it means disarming the absorb, because the absorb's age IS this timer: any unrelated reset
  -- makes an old arm look recent, and the next Capture press is swallowed as the Stop for a run long
  -- over. Safe here -- capture() has already offered this press to the absorb, which declined.
  sdec.strm_stopped_by_press = nil
  timer.cleartime()
  -- Painted after the clear and before the first window: it is the last full refresh until the run
  -- ends, so the control cell it writes stands for the whole run and reads 'no stop until it ends'.
  sdec.ui_refresh()
  local keep = nil                 -- the last window that actually decoded something
  local ok, why = false, nil
  while true do
    -- Nil'ed before the window, not tested after it: a window that fails before stream_begin() nils
    -- ck_tot leaves the previous window's totals, and the accumulator would add the same bytes twice.
    -- A write failure still counts its bytes -- they were decoded, and the note row says so.
    sdec.ck_tot = nil
    ok, why = sdec.stream()
    sdec.fc_win = sdec.fc_win + 1
    -- Acquisition seconds, accumulated across windows for the run-wide bound below.
    sdec.fc_secs = sdec.fc_secs + (sdec.strm_waited or 0)
    if sdec.ck_tot ~= nil then
      sdec.fc_bytes = sdec.fc_bytes + (sdec.ck_tot.nf or 0)
      keep = sdec.ck_tot
    end
    -- One window unless the device is being credited: without FC Out nothing makes the sender wait, so
    -- a second window would collect a different part of the conversation and file it as the next.
    if not sdec.fc_out then break end
    -- Who ended the run is settled before why the last window looks empty: a press lands while a window
    -- waits for credited traffic, so the window it interrupts is indistinguishable from the device
    -- having finished. Tested second, such a run was rewritten as 'quiet' and two cells disagreed.
    if sdec.ck_cancel then
      sdec.fc_end = 'cancelled'
      if not ok and sdec.strm_empty and sdec.fc_bytes > 0 then ok, why = true, nil end
      break
    end
    if not ok then
      -- An empty window is how a flow-controlled transmission ends, not a failure. strm_empty is what
      -- makes that safe where fc_bytes alone would turn EVERY later failure into a success -- a window
      -- that could not open its file or allocate its buffer stays a failure.
      if sdec.strm_empty and sdec.fc_bytes > 0 then
        ok, why, sdec.fc_end = true, nil, 'quiet'
      end
      break
    end
    -- Cannot fire from the panel today, and kept as insurance. The only thing that sets ck_stop while
    -- this loop runs is cancel_asked(), which sets ck_cancel in the same call and is tested above. One
    -- comparison a window, and it would matter the day the firmware gains a dispatch point.
    if sdec.ck_stop then sdec.fc_end = 'stopped'; break end
    if sdec.ck_endwhy == 'quiet' then sdec.fc_end = 'quiet'; break end
    if sdec.fc_win >= (sdec.fc_maxwin or 32) then sdec.fc_end = 'bound'; break end
    -- The bound that holds: the window count is 1 MB of bytes but most of a working day at 300 baud, and
    -- where the cancel key cannot be delivered it and this are the only exits. The larger of the clock
    -- and the counter, because the clock is the only one that sees the DECODE and the counter is the
    -- only one that cannot be clobbered -- a reset mid-run reads SMALL, so max() degrades safely.
    local el = sdec.fc_secs
    local t = timer.gettime()
    if t ~= nil and t > el then el = t end
    if sdec.fc_maxsec ~= nil and sdec.fc_maxsec > 0 and el >= sdec.fc_maxsec then
      sdec.fc_secs = el
      sdec.fc_end = 'timebound'
      break
    end
  end
  -- The tail has to survive an empty last window: stream_begin() nils ck_tot on entry, so the window
  -- that ended the run has wiped the totals of the window that carried the bytes.
  if sdec.ck_tot == nil and keep ~= nil then
    sdec.ck_tot, sdec.ck_nbytes = keep, keep.nf
  end
  -- The loop is over, so nothing is running. capture() clears this too, but not only there: left true
  -- it makes ck_status() report 'decoding...' under a finished run.
  sdec.ck_running = false
  return ok, why
end

-- Arm and return, for the press-driven path. The buffer fills in hardware from here.
function sdec.stream_start()
  -- The flow-control counters belong to a run, and this is the other kind of run. record_run() clears
  -- them at its entry, so a press-driven recording inherited the last one-press run's and reported a
  -- bound it never hit. Not in stream_begin(), which record_run() calls once per WINDOW.
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = 0, 0, nil, 0
  local ok, why = sdec.stream_begin()
  if not ok then return false, why end
  -- stream_arm's own verdict, not a pcall's: it guards its firmware writes itself and returns false for
  -- a model that refused the configuration, which a pcall around it reports as success.
  local aok = sdec.stream_arm(sdec.strm_nsmp)
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
  local got, gerr = 0, nil
  -- The one pcall left around an sdec.* call on this path, and it is here because the RAISE TEXT is the
  -- reason the operator is given. stream_settle() reports its own buffer-read failure as a second
  -- return, the gerr branch; this catches a raise from the function itself. Not a closure, so the two
  -- returns arrive as results two and three -- and on a raise the second is the message instead.
  local sok, s1, s2 = pcall(sdec.stream_settle)
  if sok then got, gerr = s1, s2 end
  sdec.ck_running = false
  -- A settle that failed is not an empty recording: publishing the operator-stopped sentinel over a
  -- fault blames the operator for a hardware failure. Same shape as the acquisition raise in stream().
  if sok and gerr ~= nil then
    sdec.ck_endwhy = 'readfail'
    return false, 'recording failed: ' .. tostring(gerr)
  end
  if not sok then
    sdec.ck_endwhy = 'readfail'
    return false, 'recording failed: ' .. tostring(s1 or 'unknown')
  end
  sdec.ck_endwhy = 'stopped'
  if got < 2 then return false, 'recording collected nothing' end
  return sdec.stream_decode(got)
end

-- Decode a completed recording, shared by both paths. got is the reading count it collected.
function sdec.stream_decode(got)
  local md = sdec.mode_cur()
  -- One window at a time, appended to the byte log FRAME also appends to, not a per-run file.

  -- The file is optional; the decode is not. flog_alloc() returns nil with no key, with an unwritable
  -- one, or with all 1000 names taken -- and refusing here made both recording modes decode NOTHING
  -- while frame mode showed bytes from the same wire. A nil path skips the sink and keeps the tail.
  local path = sdec.flog_alloc()
  -- nocap must be set explicitly: Lua cannot tell "key absent" from "key = nil", and md.cap = nil means
  -- UNLIMITED, so without it such a mode silently inherits the 32768 default.
  local opts = {maxbytes = md.cap, nocap = (md.cap == nil),
                progress = sdec.ck_progress}
  -- How much silence this record may open with, which only this path knows. An armed record is
  -- [reserve][burst], the reserve is the line the arm waited on, and it comes out of CAPACITY -- so on a
  -- device that started late the format search read one window of the wait and refused the whole
  -- recording. docs/MEASUREMENTS.md, 'An armed record opens on silence'. Guarded at the proxy read.
  if sdec.strm_armed and sdec.buf ~= nil and (sdec.pretrig or 0) > 0 then
    local cap = nil
    if pcall(function() cap = sdec.buf.capacity end) and cap ~= nil then
      -- The instrument's own rule, not a percentage of it: see the measurement in sdec.n_deliv.
      opts.leadmax = cap - math.floor(cap * (100 - sdec.pretrig) / 100)
    end
  end
  -- Sliced when a panel is waiting on us, whole when nothing is: budget_s is what makes each
  -- ck_job_step return inside the latency budget, and the one-shot callers leave it nil.
  if sdec.strm_press then
    -- Work per press and window width are two different budgets. The width must come from ui_latency_s
    -- because every priming phase scales with it; the work per press need not, and conflating them
    -- costs 662 presses for a full-buffer decode against ck_press_budget_s's 25. Do not try to spend
    -- those presses inside display.waitevent(0): on 1.7.17a it blocks and wedges the instrument.
    opts.budget_s = sdec.ck_press_budget_s or sdec.ui_latency_s
    -- The window is chosen from the budget, not fixed: every priming phase and decode slice is
    -- proportional to it, which is what makes the latency bound real. Only the panel path narrows it.
    local W = sdec.ck_win_for(sdec.ui_latency_s)
    -- These two are globals and this path cannot restore them, because the decode_step() calls that
    -- follow need the narrowed W; the one-shot branch below asserts its own values instead. Not
    -- reachable from the panel, and the effect is decimation granularity, not a wrong decode.
    sdec.ck_win_n, sdec.ck_level_max = W, W
    local job, jerr = sdec.ck_job_new(sdec.ck_reader_buffer(sdec.buf, got), got, path, opts)
    if job == nil then return false, tostring(jerr or 'cannot start the decode') end
    sdec.ck_job, sdec.ck_job_md = job, md
    sdec.ck_running = true
    return sdec.decode_step()
  end
  -- Close the scope leak at the point of consumption: the streaming branch narrows ck_win_n and
  -- ck_level_max and cannot restore them, and ck_running is cleared in a dozen places. These are the
  -- values chunk_decode documents for the one-shot path -- the 20000 default and no latency cap.
  sdec.ck_win_n, sdec.ck_level_max = 20000, nil
  local tot, terr = nil, nil
  local dok = pcall(function()
    tot, terr = sdec.ck_run(sdec.ck_reader_buffer(sdec.buf, got), got, path, opts)
  end)
  if not dok or tot == nil then
    return false, tostring(terr or 'chunked decode failed')
  end
  -- The buffer ran out before the cap, which must not report as [done]. '32 kB' cannot reach 32 kB at
  -- most rates: pick_fs snaps UP, so the real ratio is 8.33-16 samples/bit, ~22.4 kB at 9600 baud.
  if tot.stopped == nil and sdec.ck_endwhy == 'full' and md.cap ~= nil and
     tot.nf < md.cap then
    tot.stopped = 'exhausted'
  end
  sdec.ck_tot = tot
  sdec.ck_nbytes = tot.nf
  -- A file that did not get written is not a successful recording. ck_run() returns a totals table
  -- whether or not the sink worked -- the bytes are still real -- so `tot ~= nil` is not the success
  -- test: read as one, pulling the key mid-stream ends with status 'done' over a byte count nowhere.
  if tot.stopped == 'write failed' or tot.stopped == 'sink' then
    return false, string.format('%s -- %d bytes decoded but the file is incomplete',
                                tostring(tot.stopped), tot.nf or 0)
  end
  return true
end

-- Decode ONE SLICE, put the progress on the status row, and hand the panel back. Returns the decode's
-- VERDICT, not its progress: true both for a slice still pending and for a clean finish, false when the
-- step raised, produced no totals or failed its write. Whether work REMAINS is sdec.ck_job ~= nil.
function sdec.decode_step()
  local job = sdec.ck_job
  if job == nil then return false end
  local done, tot, err = true, nil, nil
  -- Three returns, so three results after the verdict; on a raise the first of them is the message.
  local pok, p1, p2, p3 = pcall(sdec.ck_job_step, job)
  if pok then
    done, tot, err = p1, p2, p3
  else
    done, err = true, tostring(p1)
  end

  if not done then
    sdec.ck_nbytes = (tot and tot.nf) or 0
    local est = (tot and tot.nwin_est) or 0
    -- A priming phase has no byte count yet, and "decoding 0 bytes" reads as a decode that found none.
    if job.phase ~= nil then
      sdec.ui_status = string.format('preparing: %s -- press Capture', tostring(job.phase))
    else
      sdec.ui_status = string.format('decoding %d bytes (window %d/%d) -- press Capture',
                                     sdec.ck_nbytes or 0, (tot and tot.nwin) or 0, est or 0)
    end
    sdec.ui_refresh()
    return true
  end

  -- Finished, one way or another. From here it is the same ending the one-shot path has.
  sdec.ck_job, sdec.ck_running = nil, false
  if tot == nil then
    sdec.errcount = sdec.errcount + 1
    sdec.lasterr = tostring(err or 'decode failed')
    sdec.ui_status = 'error'
    ulog.line(sdec.lasterr)
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
                                   tostring(tot.stopped), tot.nf or 0)
      sdec.ui_status = 'error'
    else
      sdec.ui_status = 'done'
    end
    ulog.line(sdec.ck_summary(tot))
  end
  sdec.ck_job_md = nil
  -- The verdict goes with the reason, and leaving it out was a quiet defect on this path only: the
  -- one-shot caller passes both, so strm_exit_why's `ok == false` test could never fire here.
  local dok = (tot ~= nil and tot.stopped ~= 'write failed' and tot.stopped ~= 'sink')
  sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, dok, sdec.lasterr), not dok)
  sdec.ui_refresh()
  -- dok, not true. This is capture()'s return value, and true on every path made a decode that raised
  -- indistinguishable from one that worked. Whether work remains is sdec.ck_job ~= nil.
  return dok
end

-- Abandon a decode in progress -- Mode pressed, or a mode change. Closes the partial file and
-- keeps whatever was decoded, so the bytes already on the key are not lost.
function sdec.decode_abandon()
  if sdec.ck_job == nil then return false end
  local tot = nil
  tot = sdec.ck_job_abandon(sdec.ck_job)
  sdec.ck_job, sdec.ck_job_md, sdec.ck_running = nil, nil, false
  if tot ~= nil then
    sdec.ck_tot, sdec.ck_nbytes = tot, tot.nf
    if tot.tail ~= nil then sdec.res = tot.tail end
  end
  return true
end

-- Arm the trigger model and RETURN; the buffer fills in hardware from here. nsmp is the reading count
-- SimpleLoop is asked for. Returns whether the model took the configuration -- a false is the caller's
-- cue to fall back to a free-running read. Guarded at its own firmware boundaries, so no caller needs a
-- pcall: wrapped from outside, a refused SimpleLoop came back as a successful arm.
function sdec.stream_arm(nsmp)
  -- Cleared first, ahead of the four early returns: a stale true would have the next unarmed
  -- recording's poll loop waiting for a trigger nothing armed on.
  sdec.strm_armed = nil
  local buf = sdec.buf
  -- No buffer is a refused arm, not a raise: the caller can only choose the fallback if it is told.
  if buf == nil then return false end
  -- The closure form is required: pcall(buf.clear) fetches .clear first, and that fetch is the IPC.
  if not pcall(function() buf.clear() end) then return false end
  -- fillmode = 1 per capture, after clear(), exactly as acq_triggered() does it: fillmode reads back 0
  -- on a buffer that has been cleared and reused, and one FILL_ONCE capture is one burst of 4915. Not
  -- muted here, unlike acq_triggered(): mute_events() governs the remote interface only, and this call
  -- arms and RETURNS, so the unmute would have to sit where a stop press that never comes never goes.
  sdec.acq_fillmode(buf)
  -- No digitizer is a refused arm, like no buffer above; the write is still an IPC and still guarded.
  if sdec.dig == nil then return false end
  -- 1 is SimpleLoop's per-iteration count, and it is wrong for the armed shape even though the firmware
  -- ignores it there: LoopUntilEvent takes its post-trigger count from CAPACITY, measured over 15
  -- combinations. Set to the recording's depth anyway, so the instrument's state is not misdescribed.
  local dcount = 1
  if sdec.arm_silent() and sdec.trigmode ~= 'free' then dcount = nsmp end
  if not pcall(function() sdec.dig.count = dcount end) then return false end
  -- A recording can wait for the device too. SimpleLoop acquires the instant it is initiated -- a
  -- counted loop with no wait block -- so pressing Capture on a device that has not powered up records
  -- the silence instead of the message. LoopUntilEvent is the canned four-block shape: clear, an
  -- INFINITE digitize, the wait, then a counted burst. The infinite pre-roll is what makes an analog
  -- trigger work at all, since the comparator is derived from the sample stream, and it keeps what
  -- preceded the trigger. See docs/TRIGGER.md sections 7, 8 and 12. Only on a silent line: on a line
  -- already transmitting SimpleLoop is strictly better.
  local armed = (sdec.arm_silent() and sdec.trigmode ~= 'free')
  local ok = false
  if armed then
    -- The source, the blender and the TRIGGER-key break-in, from the one function that decides them for
    -- both paths. The nil branch is live: arm_source() returns nil when the trigger constant it assigned
    -- is itself absent, and arming on a nil loads a model that waits on nothing.
    local ev, useanalog = sdec.arm_source()
    if ev == nil then
      armed = false
    else
      -- No level and no comparator are both refusals, not details: arm_thr is nil when arm_threshold()
      -- found no idle level, and sig_levels' empty exit leaves thr at zero -- armed at 0 V, it fires on
      -- the first noise sample.
      if useanalog and (sdec.arm_thr == nil or
                        not sdec.arm_comparator(useanalog, sdec.arm_slope())) then
        armed = false
      end
      if armed then
        ok = pcall(trigger.model.load, 'LoopUntilEvent', ev, sdec.pretrig,
                   trigger.CLEAR_ENTER, 0, buf)
      end
      -- A refused load is not an armed recording: the poll loop would wait out an arm that is not there.
      if not ok then armed = false end
    end
  end
  -- Published for the poll loop, which has to bound the wait and tell an expired arm from a finished
  -- recording. On both paths, since a stale true would wait for a trigger nothing armed on.
  sdec.strm_armed = armed
  -- Two sites rather than one closure, and the `and` keeps the ordering. No OP_CLOSURE per capture.
  if not armed then ok = pcall(trigger.model.load, 'SimpleLoop', nsmp, 0, buf) end
  if ok then ok = pcall(trigger.model.initiate) end
  -- An arm is not live until the model is in its wait block, and that is this function's promise rather
  -- than the poll loop's: initiate() reports STATE_RUNNING with nine readings first, and the loop reads
  -- "no longer waiting" as "fired" -- so an 8 kB recording of a device that had not spoken ended as
  -- 'quiet'. One state read per 10 ms to arm_settle_s; docs/UNDOCUMENTED.md has the 0.19 s median.
  if ok and armed then
    local spun, saw = 0, false
    while spun < (sdec.arm_settle_s or 0.25) do
      if sdec.trig_waiting() == true then saw = true break end
      delay(0.01)
      spun = spun + 0.01
    end
    -- And the verdict is carried out, because nothing downstream would catch it: the loop cannot tell
    -- "never got there" from "left it", and would latch a model that never waited as FIRED.
    if not saw then armed = false end
  end
  sdec.strm_armed = armed
  -- The pulse goes AFTER the model is armed, never before: a SimpleLoop starts filling immediately, so a
  -- credit sent before initiate() would have the device transmitting into a buffer that does not exist.
  -- After a SUCCESSFUL arm, which is not the same thing -- when the load raises there is no buffer at
  -- all, and the fallback then issues a SECOND credit, with everything sent against the first gone.
  if ok and sdec.fc_out then
    sdec.fc_credit()
  end
  return ok
end

-- Stop the hardware and publish what it collected. -> the reading count, and a SECOND return naming the
-- failure when the buffer could not be read at all. That second return is what keeps a fault from
-- reading as an empty recording: buf.n raises on a buffer the firmware has dropped, and unguarded it
-- would come back as 0, which stream_stop() reports as 'recording collected nothing'.
function sdec.stream_settle()
  pcall(trigger.model.abort)
  local buf = sdec.buf
  sdec.nread = 0
  if buf ~= nil then
    -- Guarded at the proxy read: .n raises on a buffer the firmware has dropped, and nil cannot see it.
    local n = nil
    local ok, perr = pcall(function() n = buf.n end)
    if not ok then return 0, tostring(perr or 'the buffer could not be read') end
    sdec.nread = n or 0
    sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  end
  return sdec.nread
end

-- Re-measure the levels from the newest samples in buf when the watchdog is about to end a run on
-- REUSED levels. buf holds `have` readings; iw is the window to look at. Returns true if the reused
-- threshold is wrong and a better one is now in force, so the caller should keep going.
function sdec.strm_relevel(buf, have, iw)
  -- Only when the levels were reused: a threshold measured from THIS capture's own probe has seen this
  -- wire, so re-measuring every second would spend the recording on second-guessing itself.
  if not sdec.strm_lvlreuse then return false end
  if buf == nil or have == nil or have < 3 then return false end
  local from = have - iw + 1
  if from < 1 then from = 1 end
  local win, m = {}, 0
  local rok = pcall(function()
    m = sdec.ck_reader_buffer(buf, have)(win, from, iw, 1)
  end)
  -- Tri-state, and the second return is the point. `false` means "believe the quiet verdict", which is
  -- right for a rejection and wrong for a read that raised, because a failed read is ignorance: that
  -- conflation let a run end as 'quiet' and report a truncated prefix as a normal ending.
  if not rok then return false, true end
  if m < 3 then return false, true end
  -- The reused threshold stands until the new levels disprove it, because sig_levels() overwrites
  -- sdec.thr as a side effect. And the remembered levels with it: lvl_* is the fallback every later
  -- window of a flow-controlled run gets, so a quiet tail became the next window's threshold.
  local oldthr, oldhyst, oldswing = sdec.thr, sdec.hyst, sdec.swing
  local oldlo, oldhi = sdec.lo, sdec.hi
  local olvthr, olvhyst, olvswing = sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing
  local function unmeasure()
    sdec.thr, sdec.hyst, sdec.swing = oldthr, oldhyst, oldswing
    sdec.lo, sdec.hi = oldlo, oldhi
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = olvthr, olvhyst, olvswing
  end
  -- sig_levels() called bare, as acquire() does: no instrument, every path nil-checked, no raise.
  local lok = sdec.sig_levels(win, m)
  if not lok or sdec.thr == nil or (sdec.swing or 0) < sdec.minswing then
    unmeasure()
    return false
  end
  -- Wrong means the signal cannot cross it, not merely different: a threshold still between the two
  -- levels WITH ROOM TO SPARE is doing its job, and adopting a marginally different one would restart
  -- the watchdog for ever. And 'between the levels' is not 'crossable' -- a bare lo < thr < hi admits a
  -- threshold sitting ON a rail. docs/MEASUREMENTS.md, 'A reused threshold can sit on a rail'. The
  -- margin is the hysteresis, which already decides what counts as a crossing, taken from the levels
  -- just measured because it is the CURRENT signal that has to cross it.
  local band = sdec.hyst
  if band == nil or band <= 0 then
    band = 0.1 * ((sdec.hi or 0) - (sdec.lo or 0))
  end
  if oldthr ~= nil and sdec.lo ~= nil and sdec.hi ~= nil and
     oldthr > sdec.lo + band and oldthr < sdec.hi - band then
    unmeasure()
    return false
  end
  -- Adopted, and cleared so this runs once per recording: the next verdict has its own measurement.
  sdec.strm_lvlreuse = nil
  sdec.strm_releveled = string.format('threshold re-measured mid-recording: %.3f V, not the %.3f V '
                                      .. 'a previous capture measured', sdec.thr or 0, oldthr or 0)
  ulog.line(sdec.strm_releveled)
  return true
end

-- Arm, poll until full or quiet or stopped, then settle. nsmp is the target sample count;
-- returns the reading count collected.
function sdec.stream_acquire(nsmp)
  -- Polled, so the run can end EARLY on a quiet line: a blocking read returns when it has n samples, and
  -- at 1200 baud a 32 kB buffer is four and a half minutes whether the device is talking or not. The
  -- same bounded-wait shape as acq_triggered(), because a poll loop that cannot exit is a dead panel.
  local buf = sdec.buf
  -- What this window spent, published for record_run's run-wide bound. A counter rather than a clock
  -- reading: the one timer is already spoken for twice, and summing the poll period clobbers nothing.
  sdec.strm_waited = 0
  local ok = sdec.stream_arm(nsmp)
  if not ok then
    -- Falls back to a plain blocking read, which loses the early exit and every bound with it: neither
    -- the cancel key nor the wall-clock limit can act while it runs. So it is shortened to
    -- strm_fallback_s -- length is lost, the note row says so, and the panel always comes back.
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
    -- Cap the Lua copy too, separately: sdec.n bounds what is copied into Lua, where the first argument
    -- bounds the acquisition. Counted towards the run's bound from cap/fs, since this cannot report.
    sdec.strm_waited = cap / fs
    return sdec.acq_free(cap, sdec.n)
  end

  local quiet, seen, step = 0, 0, sdec.ck_poll_s
  -- The ring position last looked at, beside the count. -1 rather than nil, since 0 is a real endindex.
  local seenend = -1
  local iw = sdec.idle_window(sdec.fs)
  local waited = 0
  -- The arm, which this loop has to bound and has to be able to see fail. The model's own state is the
  -- observable, not the buffer: the pre-trigger phase accumulates readings while it waits, so buf.n
  -- settled just above its 5 % reserve within milliseconds of initiate(), a buffer-level test read that
  -- as "fired", and the watchdog ended the run three seconds before the device started. trig_waiting()
  -- asks the model instead. Without a bound of its own the wait is not waited at all -- stream_maxwait
  -- is 10 s for an 8 kB recording at 100 kS/s, so a device starting at fifteen seconds would be cut off
  -- and the plateau reported as 'full'. The operator's Arm Wait is added on top.
  local armdone = true
  if sdec.strm_armed then
    armdone = false
    -- Say so before blocking, through acq_triggered()'s hook: a static panel reads as the old fault.
    if sdec.armnote ~= nil then
      pcall(sdec.armnote, sdec.arm_wait_s(), sdec.arm_thr or sdec.thr or sdec.arm_level_v(),
            sdec.armkeyed)
    end
  end
  -- Consecutive failed window reads, and the last reason: a read failure must not pass for a quiet line.
  local rfail, rlast = 0, nil
  sdec.strm_readfail = nil
  -- Bounded by wall clock as well as by samples, and the clock is the only bound that always fires. A
  -- front-panel press is not dispatched while a Lua script runs -- TSP is single-threaded, a press is
  -- delivered by EXECUTING an event string, and delay() is not a yield point: measured, three presses
  -- during a stream did nothing and then all arrived afterwards, each starting another stream. So every
  -- mode has to terminate by construction, or a looped arb on an active line runs until a LAN abort.
  local limit = sdec.stream_maxwait(nsmp, sdec.fs)
  if sdec.strm_maxsec ~= nil and sdec.strm_maxsec > 0 and limit > sdec.strm_maxsec then
    limit = sdec.strm_maxsec
  end
  -- And the arm's own wait on top, AFTER the run-wide ceiling: strm_maxsec bounds the RECORDING, and
  -- clamping the sum would spend the Arm Wait out of it -- a 120 s arm leaving nothing to record.
  if sdec.strm_armed then limit = limit + sdec.arm_wait_s() end
  -- THREE WAYS OUT, each recorded in sdec.ck_endwhy so the panel can say which:
  --   full     the buffer reached nsmp -- the cap, or as much as the instrument has
  --   quiet    no threshold crossing for sdec.idle_exit_s. The device stopped talking.
  --   stopped  the operator pressed Capture (Stop) or Mode (abort)
  while true do
    local have = buf.n or 0
    -- The trigger has fired once the model leaves its wait block, and the model reports it: measured
    -- from inside the instrument, STATE_RUNNING with 9 readings at initiate, STATE_WAITING with the
    -- buffer full four seconds later, one event and no abort. One proxy read against four thousand for a
    -- window of samples, and unlike the data it cannot miss a burst between two polls. Watched from the
    -- HOST it reports ABORTED instead, because a command aborts an initiated model -- hence inside.
    if not armdone and sdec.trig_waiting() ~= true then
      armdone = true
      quiet = 0
      seen, seenend = 0, -1
    end
    -- What counts as finished depends on whether this recording waited. An armed one is finished when
    -- the model is: a pre-trigger phase that waited longer than the buffer holds has already filled it,
    -- so buf.n is pinned at capacity before a byte arrives and `have >= nsmp` would end the run on the
    -- poll the trigger fires. An unarmed one keeps the fill test, where nsmp means what it says.
    if sdec.strm_armed then
      if armdone and sdec.trig_done(buf) then sdec.ck_endwhy = 'full'; break end
    elseif have >= nsmp then
      sdec.ck_endwhy = 'full'
      break
    end
    -- The cancel latch is read here, twice a second against a 1.06 ms poll, so a blended stimulus can end
    -- the wait; a finger cannot. Before the arm expiry, and that order is load-bearing -- TRIGGER is
    -- blended INTO the arm, so a press that ended the wait early could be reported as an arm that failed.
    if sdec.cancel_asked() then sdec.ck_endwhy = 'stopped'; break end
    -- The arm expired: Arm Wait elapsed with the device still silent. Reported as its own ending rather
    -- than as 'full' or 'quiet', because both of those describe a recording that happened.
    if not armdone and waited >= sdec.arm_wait_s() then
      -- The level is stashed at the expiry because sdec.thr does not survive to the note: the reason is
      -- printed at the END of the run, by which time the next window has cleared the measurements.
      sdec.arm_expired_at = sdec.arm_thr or sdec.thr
      sdec.ck_endwhy = 'noarm'
      break
    end
    if waited >= limit then sdec.ck_endwhy = 'full'; break end

    -- Look at the NEWEST samples only, and only once new ones exist, or a busy line looks quiet the
    -- moment acquisition stalls. "New" is the ring position, not the count: on a wrapped buffer buf.n is
    -- pinned at capacity and every window looks the same. acq_end() keeps moving; nil falls back.
    local eidx = sdec.acq_end(buf)
    local fresh = (have > seen)
    if eidx ~= nil then fresh = (eidx ~= seenend) end
    if fresh then
      local from = have - iw + 1
      if from < 1 then from = 1 end
      local win, m = {}, 0
      local rok, rerr = pcall(function()
        m = sdec.ck_reader_buffer(buf, have)(win, from, iw, 1)
      end)
      -- A read that raised is ignorance, not silence, so it must not advance the quiet timer: folding it
      -- in would report a truncated prefix as SUCCESS with the note "the device stopped sending".
      if not rok then
        rfail = rfail + 1
        rlast = rerr
        -- Persistent is different from transient: one failed read is a blip, a run of them means the
        -- buffer cannot be read at all, and the wall-clock limit would take minutes to say so.
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
      seenend = eidx
    else
      quiet = quiet + step
    end

    -- The idle watchdog is off until the arm fires, and `armdone` holds it off: a waiting arm is a line
    -- with nothing on it by design, so the watchdog would end the run before the device started. Moot
    -- where a silent probe left ck_watch false; not moot where the levels were reused.
    if armdone and sdec.ck_watch and sdec.idle_exit_s ~= nil and sdec.idle_exit_s > 0 and
       quiet >= sdec.idle_exit_s then
      -- A quiet line judged with reused levels is checked before it is believed: a threshold outside the
      -- CURRENT swing sees no crossings at all. sig_levels() needs no threshold to find the levels.
      local adopted, unmeasurable = sdec.strm_relevel(buf, have, iw)
      if adopted then
        quiet = 0
      elseif unmeasurable then
        -- The check itself could not be made, so the quiet verdict is unearned: the last gate must not guess.
        sdec.strm_readfail = 'the capture buffer could not be re-measured to confirm a quiet line'
        sdec.ck_endwhy = 'readfail'
        break
      else
        sdec.ck_endwhy = 'quiet'
        break
      end
    end

    -- Yields at ck_poll_s rather than busy-waiting, because delay() is what lets the display update: one
    -- settext plus at most 4000 proxy reads is a few tens of ms against a 500 ms sleep. Not while an arm
    -- waits -- a wrapped pre-roll has filled the buffer, so the bar would read 100 % of nothing.
    if armdone then sdec.progress_samples(have, nsmp) end
    delay(step)
    waited = waited + step
    sdec.strm_waited = waited
  end

  -- Truncated to the count: stream_settle()'s second return is for its direct callers.
  return (sdec.stream_settle())
end

-- Poll period. Two per second is well inside the 1 Hz display budget and keeps the progress
-- counter moving without spending measurable time on it.
sdec.ck_poll_s = 0.5

-- A hard ceiling on the wait for nsmp samples at fs, seconds: twice the theoretical fill time,
-- floored at 10 s and capped at 1200.
function sdec.stream_maxwait(nsmp, fs)
  if fs == nil or fs <= 0 then return 600 end
  -- Independent of the watchdog, which only arms on real levels: this is then the only exit left.
  local t = 2 * nsmp / fs
  if t < 10 then t = 10 end
  if t > 1200 then t = 1200 end
  return t
end

-- Show acquisition progress on the mode row: have of want samples.
function sdec.progress_samples(have, want)
  -- In samples, not bytes: nothing is decoded yet, so percent of the buffer is the honest number.
  sdec.ck_acq_have, sdec.ck_acq_want = have, want
  return sdec.progress_row()
end

-- Readings the largest recording may ask for. The 32 kB mode at 9600 records 3 413 334 at 100 kS/s, so
-- any ceiling above that keeps all 32 768 bytes; what this figure buys is every other reachable
-- combination. Bisected, not chosen: docs/MEASUREMENTS.md, 'ck_bufwant = 4076503'.
sdec.ck_bufwant = 4076503

-- And the live ceiling, which start() recomputes from the capacities the operator has set. Initialised
-- to the static need, because a caller that never ran start() still needs a number. bufmax_for() reads
-- ck_bufwant and never this, so a launch under a large defbuffer1 cannot ratchet it down.
sdec.ck_bufmax = sdec.ck_bufwant

-- The instrument's whole reading memory, across all buffers together. Standard style only, which is what
-- acq_make_buffer() allocates; the compact ceiling is several times larger and would overstate the pool
-- by millions. docs/MEASUREMENTS.md, 'The reading pool is per model'. A lookup, not a capability test:
-- nothing can answer a pool SIZE at runtime without failing an allocation. The default is a separate
-- field because a resolver that only assigns on a match leaves the last match in place.
sdec.ck_bufpool_default = 7080255
sdec.ck_bufpool = sdec.ck_bufpool_default
sdec.ck_bufpool_model = {{'7510', 7500000}, {'2461', 6875000}}

-- Resolve the pool from the model number. -> the figure now in force.
--
-- Assigns unconditionally from a local, so the answer depends on the model and not on call order. Bare
-- read: localnode is documented on every supported model. Substring, since neither key can collide.
function sdec.buf_pool_resolve()
  local p = sdec.ck_bufpool_default
  local m = localnode.model
  if type(m) == 'string' then
    local i
    for i = 1, table.getn(sdec.ck_bufpool_model) do
      local e = sdec.ck_bufpool_model[i]
      if string.find(m, e[1], 1, true) ~= nil then
        p = e[2]
        break
      end
    end
  end
  sdec.ck_bufpool = p
  return p
end
sdec.buf_pool_resolve()

-- A chosen margin below the measurement, not a second measurement. 6 000 000 is the hard guard, which is
-- what the vendor's bufferVar.capacity documents. ck_bufmargin covers the pool figure's uncertain last
-- digits and the firmware's unreported per-buffer overhead: 0.7 % of the pool, so it costs nothing.
sdec.ck_bufguard = 6000000
sdec.ck_bufmargin = 50000

-- The smallest recording that is still a recording, which is the floor start() refuses below: under it
-- every Capture press would end in the allocation refusal, three screens into the app rather than at
-- launch. docs/MEASUREMENTS.md, 'ck_bufmin = 898347'.
sdec.ck_bufmin = 898347

-- The ceiling the live defbuffers leave, which is a QUERY and not the policy: it reports what the
-- instrument can spare as the capacities stand, and buf_reclaim() is what changes them.
--
-- One pcall for both reads, and it belongs here: an outbound firmware boundary, where the pcall budget
-- (see start()) makes a second guard for the second attribute two sites for one boundary. The fallback
-- is the static ceiling and never a raise. Returns the ceiling, then the NAME and CAPACITY of the larger
-- default buffer, which the refusals have to quote or they send the operator at the wrong one.
function sdec.bufmax_for()
  local ok, d1, d2 = pcall(function() return defbuffer1.capacity, defbuffer2.capacity end)
  if not ok or type(d1) ~= 'number' or type(d2) ~= 'number' then
    return sdec.ck_bufwant, nil, nil
  end
  local bigname, bigcap = 'defbuffer1', d1
  if d2 > d1 then bigname, bigcap = 'defbuffer2', d2 end
  local n = sdec.ck_bufwant
  if sdec.ck_bufguard < n then n = sdec.ck_bufguard end
  local avail = sdec.ck_bufpool - d1 - d2 - sdec.ck_bufmargin
  if avail < n then n = avail end
  if n < 0 then n = 0 end
  return n, bigname, bigcap
end

-- What the instrument ships with in each default buffer, and the size a reclaim returns them to.
sdec.ck_defbufcap = 100000

-- One default buffer's capacity, written and answered for. -> true if the instrument took it.
--
-- One guarded site for every capacity write this app makes, which is what lets the reclaim and the
-- restore work per buffer without paying for it: the pcall budget counts SITES, not executions.
--
-- Per buffer is not a style choice. One pcall spanning both writes is not atomic: with defbuffer1 pinned
-- by a running measurement the first assignment lands and the second raises, so defbuffer2's readings
-- were discarded while buf_reclaim reported false and logged nothing. A whitelist, and not the sweep's
-- test with the sign flipped -- buf_sweep asks the opposite question of the same two names. Named
-- exactly: without the test the else would resize defbuffer2 for any unexpected argument.
function sdec.defbuf_set(name, cap)
  if name ~= 'defbuffer1' and name ~= 'defbuffer2' then return false end
  local ok = pcall(function()
    if name == 'defbuffer1' then
      defbuffer1.capacity = cap
    else
      defbuffer2.capacity = cap
    end
  end)
  return ok
end

-- Resize the default buffers down when the recording needs the room, because the reading memory is ONE
-- pool across every buffer and that is what the other apps on this instrument do. An operator who has
-- grown defbuffer1 to 6 000 000 has taken 85 % of the pool, and an app that only adapted to that
-- recorded a quarter of the window with nothing on the glass to say why.
--
-- defbuffer2 first, then defbuffer1, and the order is the point: defbuffer1 is the instrument's default
-- ACTIVE buffer, so it is the one likely to hold the operator's readings. Back to the default and not to
-- just-enough, because a resize DISCARDS EVERY READING whatever the new capacity is. And it is recorded:
-- ck_defbufwas is what stop() hands back and what the log line quotes.
--
-- -> did_reclaim, text naming what was resized and from what. false means nothing needed doing.
function sdec.buf_reclaim()
  local ok, d1, d2 = pcall(function() return defbuffer1.capacity, defbuffer2.capacity end)
  if not ok or type(d1) ~= 'number' or type(d2) ~= 'number' then return false, nil end
  local want = sdec.ck_bufwant
  if sdec.ck_bufguard < want then want = sdec.ck_bufguard end
  local dc = sdec.ck_defbufcap
  local n1, n2 = nil, nil
  local a1, a2 = d1, d2
  if sdec.ck_bufpool - a1 - a2 - sdec.ck_bufmargin < want and a2 > dc then n2, a2 = dc, dc end
  if sdec.ck_bufpool - a1 - a2 - sdec.ck_bufmargin < want and a1 > dc then n1, a1 = dc, dc end
  if n1 == nil and n2 == nil then return false, nil end
  local what = nil
  -- Each write recorded as it lands, so a buffer that WAS resized is always one this app can name and put
  -- back. Per buffer, both endpoints, because one shared destination does not read as shared -- on the
  -- one line that records readings being destroyed.
  if n2 ~= nil and sdec.defbuf_set('defbuffer2', n2) then
    if sdec.ck_defbufwas == nil then sdec.ck_defbufwas = {} end
    sdec.ck_defbufwas.defbuffer2 = d2
    what = string.format('defbuffer2 %d -> %d', d2, n2)
  end
  if n1 ~= nil and sdec.defbuf_set('defbuffer1', n1) then
    if sdec.ck_defbufwas == nil then sdec.ck_defbufwas = {} end
    sdec.ck_defbufwas.defbuffer1 = d1
    local s = string.format('defbuffer1 %d -> %d', d1, n1)
    if what == nil then what = s else what = what .. ' and ' .. s end
  end
  if what == nil then return false, nil end
  -- And collect, same reason as the sweep: the resize is what releases the readings.
  pcall(collectgarbage)
  return true, what
end

-- And buffers this app did not make hold the same pool, so they are swept before the default buffers are
-- touched. An app that was swapped out leaves its buffer allocated with nothing to show the operator it
-- is there, so taking those first means their own defbuffer1 is the LAST thing resized.
--
-- Found by walking the globals, because the instrument publishes no way to enumerate reading buffers: a
-- global holding something with a numeric capacity is the only handle that exists. Skipped: defbuffer1
-- and defbuffer2, which cannot be deleted, and this app's own sdec.buf.
--
-- Collect, then delete, never interleaved: writing to the global table while next() walks it is
-- undefined, and dropping the handle before the delete strands the buffer with nothing to retry from.
-- Unmeasured on hardware -- whether `.capacity` on an arbitrary global answers nil or raises is not
-- established -- so the collection is guarded as though it raises.
--
-- -> freed_readings, text naming what went. 0 and nil when there was nothing to sweep.
function sdec.buf_sweep()
  local names, nn = {}, 0
  pcall(function()
    local bt = type(defbuffer1)
    local k, v = next(_G, nil)
    while k ~= nil do
      if type(k) == 'string' and k ~= 'defbuffer1' and k ~= 'defbuffer2'
         and type(v) == bt and v ~= sdec.buf then
        -- Every stranded buffer goes, whatever its size: a small one is still reading memory nothing
        -- shows the operator, and they accumulate one per relaunch. So the discriminator carries the
        -- weight, and both a numeric `.capacity` and a numeric `.n` are required.
        local c, nread = v.capacity, v.n
        if type(c) == 'number' and type(nread) == 'number' then
          nn = nn + 1
          names[nn] = k
          names[k] = c
        end
      end
      k, v = next(_G, k)
    end
  end)
  if nn == 0 then return 0, nil end
  local freed, gone = 0, nil
  local i
  for i = 1, nn do
    local nm = names[i]
    -- One site, N executions; per buffer, so a refused delete does not cost the ones after it.
    local dok = pcall(function()
      buffer.delete(_G[nm])
      _G[nm] = nil
    end)
    if dok then
      freed = freed + names[nm]
      local s = string.format('%s (%d)', nm, names[nm])
      if gone == nil then gone = s else gone = gone .. ', ' .. s end
    end
  end
  -- Collect once the handles are gone: the delete plus the nil drops the last reference. 8.3 ms.
  if freed > 0 then pcall(collectgarbage) end
  return freed, gone
end

-- Hand the capacities back -- the sizes are the operator's setting and only the READINGS were lost. Runs
-- in stop() after the capture buffer is freed, because until then the room to grow them does not exist.
-- Not fatal and not retried: failing the teardown over it costs a reinstall, and ck_defbufwas is cleared
-- either way. -> text naming what was handed back, or nil when there was nothing.
function sdec.buf_restore()
  -- A relaunch is not an exit: start() sets this across its rebuild teardown, because the ceiling is
  -- derived from the RECLAIMED capacities. One-shot, and consumed here rather than only cleared by its
  -- setter, so a raise inside cleanup() costs exactly one skipped restore instead of every one.
  if sdec.ck_relaunching then
    sdec.ck_relaunching = nil
    return nil
  end
  local was = sdec.ck_defbufwas
  if was == nil then return nil end
  -- The record is kept until each write lands. Clearing it first made a failed restore PERMANENT: the
  -- capacities this app destroyed are not derivable from anywhere else, and the one case that needs a
  -- retry -- stop() with the capture buffer still live, so there is no room to grow into -- is exactly
  -- the case that threw them away. An entry is dropped only on success, since assigning a capacity
  -- CLEARS the buffer and re-writing a restored one would discard what has accumulated since.
  local what, left = nil, nil
  if was.defbuffer2 ~= nil then
    if sdec.defbuf_set('defbuffer2', was.defbuffer2) then
      what = string.format('defbuffer2 to %d', was.defbuffer2)
      was.defbuffer2 = nil
    else
      left = 'defbuffer2'
    end
  end
  if was.defbuffer1 ~= nil then
    if sdec.defbuf_set('defbuffer1', was.defbuffer1) then
      local s = string.format('defbuffer1 to %d', was.defbuffer1)
      if what == nil then what = s else what = what .. ' and ' .. s end
      was.defbuffer1 = nil
    else
      if left == nil then left = 'defbuffer1' else left = left .. ' and defbuffer1' end
    end
  end
  if left == nil then
    sdec.ck_defbufwas = nil
    return what
  end
  local why = 'could not restore ' .. left .. ' -- kept for the next teardown'
  if what ~= nil then why = what .. '; ' .. why end
  return why
end

-- Samples to record for mode md at sample rate fs. Returns nil when the rate or the locked baud
-- rate cannot size a capture.
function sdec.stream_samples(md, fs)
  if fs == nil or fs <= 0 then return nil end
  local baud = sdec.force_baud
  if baud == nil or baud <= 0 then return nil end
  -- A byte-capped mode's sample count follows from the format: md.cap bytes at framebits*(fs/baud)
  -- samples each. md.cap = nil takes whatever the buffer allows, and both are clamped to ck_bufmax.
  if md.cap == nil then return sdec.ck_bufmax end
  -- 8N1 unless the FRAME FORMAT is forced -- and all three forced fields widen it, not just the data
  -- width. The cap is a byte count, so a wider frame simply needs more samples for the same bytes.
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
  -- One settext per window is already about 1 Hz: a window is a few hundred milliseconds of decoding.
  sdec.ck_running = true
  sdec.progress(nbytes)
  -- FALSE aborts the run, and progress()'s verdict is discarded: a failed settext is not a Stop press.
  if sdec.ck_stop then return false end
  -- And this is where a long decode becomes cancellable. One window is the granularity because it is the
  -- only point at which this module gets control, and ~0.96 s already answers within a second.
  if sdec.cancel_asked() then return false end
  return true
end

-- Poll the TRIGGER key and record it as a stop request. True once a cancel is in force, INCLUDING one
-- seen by a previous poll -- the blender's latch auto-resets on read, so a caller that polls twice and
-- expects the same answer loses the press.
function sdec.cancel_asked()
  if sdec.ck_stop then return true end
  if not sdec.cancel_pressed() then return false end
  sdec.ck_stop = true
  -- Separate from ck_stop, which Mode also sets: ck_cancel is "the operator pressed TRIGGER".
  sdec.ck_cancel = true
  return true
end

-- The two answers to a refused forced rate. decode() publishes rate_offer when the locked rate is proved
-- wrong and refuses rather than substituting one nobody chose. Both are ordinary functions with no
-- display dependency, so the behaviour is testable with no human at the panel; each returns ok, reason.

-- Use the detected rate. Clears the lock instead of writing the detected number into it: detection found
-- this rate unaided and will again, where a locked number freezes one measurement.
function sdec.rate_accept()
  if sdec.rate_offer == nil then return false, 'no rate was offered' end
  sdec.force_baud = nil
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  return sdec.capture()
end

-- Keep the rate the operator set. The question goes; the lock and the refusal both stand, so the panel
-- does not fall back to looking like an ordinary empty capture with nothing to explain it.
function sdec.rate_decline()
  if sdec.rate_offer == nil then return false, 'no rate was offered' end
  local why = sdec.rate_refused
  sdec.rate_offer, sdec.rate_offer_from = nil, nil
  return true, why
end

-- The body of the Capture press: start a capture, or stop or step one already in progress. Fully guarded,
-- and returns a verdict rather than raising. Not the handler -- sdec.capture() below wraps this to hold
-- the panel tick off for the duration of the press.
function sdec.capture_run()
  -- A key inserted since the last press resumes normal logging HERE, so the promise is "the first button
  -- press". Kept even though the panel route asks first: neither is in a host-driven capture_run()'s path.
  ulog.resume()
  -- Every failure below comes back as a message on the panel, which is what the pcalls are for. Not when
  -- a press-driven run is live: those dispatch three ways below, and this would swallow the press.
  if sdec.ck_running and not sdec.strm_recording and sdec.ck_job == nil then
    -- A stop request that went unanswered proves there is no run to answer it: a loop clears ck_running
    -- as it unwinds, so arriving here a SECOND time with ck_stop set means a run died. Clearing it is the
    -- only way out from the panel -- left latched, the instrument needs a power cycle.
    if sdec.ck_stop then
      sdec.ck_running, sdec.ck_stop = false, false
      -- stickyerr, not lasterr: this capture carries on and would overwrite lasterr before it was read.
      sdec.stickyerr = 'a previous run did not finish (aborted?) -- run flag cleared'
      ulog.line(sdec.stickyerr)
    else
      sdec.ck_stop = true                 -- second press during a stream = Stop
      sdec.ui_status = 'stopping'
      return sdec.ui_refresh()
    end
  end

  -- Absorb the stop press that arrives after the stream it was meant to stop. The branch above is nearly
  -- unreachable from the panel for a firmware reason: a press is not dispatched while Lua runs, presses
  -- QUEUE, and display.waitevent() polls a prompt rather than this screen. So the press lands HERE as a
  -- fresh capture, which would wipe the bytes the run just put on screen. See sdec.press_absorbed().
  if sdec.press_absorbed('Capture') then return true end
  -- Once per press, ahead of the mode dispatch: a relock inside this press must reach the note row.
  sdec.relocked = nil
  -- rate_backoff with it: it requests one re-capture within THIS press.
  sdec.rate_backoff = nil
  -- The rate offer is per press for the opposite reason -- a fresh capture is itself an answer to it.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  -- Busy on entry means a previous run died, not that one is in progress: presses queue until the handler
  -- returns, so the only way this is still set is that a run never reached its `busy = false`. Refusing
  -- would make that permanent, so it is recorded once and cleared.
  if sdec.busy then
    sdec.lasterr = 'previous capture did not finish (aborted?) -- starting a new one'
    ulog.line(sdec.lasterr)
  end
  sdec.busy = true

  -- ----------------------------------------------------------------------------
  -- The press-driven streaming path: nothing here holds the panel over the budget.
  -- ----------------------------------------------------------------------------
  -- One start button for both capture modes, so in a streaming mode Capture means one of three things,
  -- never ambiguously, because each is a different state of one run:
  --   no run      START recording. Arms the hardware and returns; the panel stays live throughout.
  --   recording   STOP recording, and decode the first slice.
  --   decoding    decode the NEXT slice.
  local md = sdec.mode_cur()
  if not md.view and sdec.strm_recording then
    local sok, swhy = false, nil
    local pok, r1, r2 = pcall(sdec.stream_stop)
    sok, swhy = (pok and r1), r2
    if not pok then swhy = r1 end
    sdec.busy = false
    if not pok or not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(swhy or 'recording failed')
      sdec.ui_status = 'error'
      ulog.line(sdec.lasterr)
      sdec.mode_exit('recording failed', true)
    end
    sdec.ui_refresh()
    return sok
  end

  if sdec.ck_job ~= nil then
    sdec.busy = false
    return sdec.decode_step()
  end

  if not md.view and sdec.strm_press then
    -- START a recording and return. sdec.strm_press selects the press-driven path over the one-shot
    -- sdec.stream(), which is kept for the host harnesses and the offline suite.
    sdec.detect_reset()
    local sok, swhy = false, nil
    local pok, r1, r2 = pcall(sdec.stream_start)
    sok, swhy = (pok and r1), r2
    if not pok then swhy = r1 end
    sdec.busy = false
    if not pok or not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(swhy or 'could not start recording')
      sdec.ui_status = 'refused'
      ulog.line(sdec.lasterr)
      sdec.mode_exit(sdec.lasterr, true)
    else
      sdec.ui_status = 'recording -- press Capture to stop'
    end
    sdec.ui_refresh()
    return sok
  end

  if not md.view then
    -- STREAMING: produces a file, not a view, so the panel shows progress and a summary.
    sdec.detect_reset()
    sdec.ui_status = 'capturing'
    -- Set before the refresh, so the control cell says 'no stop until it ends' for the whole run: only
    -- this refresh paints that cell, and ck_running is not true until stream_begin() is inside the job.
    sdec.strm_inflight = true
    -- No refresh here: record_run() paints, immediately after it clears the cancel latch.
    local sok, swhy = false, nil
    -- The whole job in this one press: record, decode, save, and under flow control repeat until the
    -- device stops. Nothing can cut it short -- the TRIGGER key emits no blender event while this runs,
    -- so record_run()'s bounds are the only exits.
    local pok, r1, r2 = pcall(sdec.record_run)
    sok, swhy = (pok and r1), r2
    if not pok then swhy = r1 end
    sdec.strm_inflight = nil
    sdec.busy, sdec.ck_running = false, false
    if not pok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = 'stream raised: ' .. tostring(swhy)
      sdec.ui_status = 'error'
      ulog.line(sdec.lasterr)
    elseif not sok then
      sdec.errcount = sdec.errcount + 1
      sdec.lasterr = tostring(swhy)
      sdec.ui_status = 'refused'
      ulog.line('stream refused: ' .. tostring(swhy))
    else
      sdec.ui_status = 'done'
      ulog.line(sdec.ck_summary(sdec.ck_tot))
      -- Every recording leaves the bytes it kept on screen, paged like a frame capture. With a key the
      -- file holds the rest; with none, the tail is all there is. The mode does not change.
      if sdec.ck_tot ~= nil and sdec.ck_tot.tail ~= nil then
        -- No "this is a stream tail" flag: the view carries `first` and `ntotal`, so ui_notes() can tell.
        sdec.res = sdec.ck_tot.tail
      end
    end
    -- Leaving the mode happens on every outcome: inside the `else` it would miss a refused stream, a raise
    -- out of the acquisition and a decode that could not allocate, each leaving the log open.
    sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, sok, sdec.lasterr), not sok)
    sdec.ui_refresh()
    -- Armed last, after the USB flush and the repaint: the window is 1 s from the moment it is armed. On
    -- every outcome, since a raise and a refusal held the interpreter just as long.
    sdec.strm_absorb_arm()
    return sok, swhy
  end

  -- The frame path owns the panel from here, so the streaming summary goes: ck_tot and ck_nbytes describe
  -- the last STREAM, and the cells that read them are wrong the moment a frame capture replaces it --
  -- BYTES read 389 over a 159-byte dump. Not in clear_result(), which the streaming path also calls.
  sdec.ck_tot, sdec.ck_nbytes = nil, nil
  -- The multi-window counters go with them: a stale one would put '3 windows' on a frame capture.
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = nil, nil, nil, nil
  -- Not just clear_result(): the REQUESTED rate goes back to what the lock and mode imply.
  sdec.detect_reset()
  sdec.ui_status = 'capturing'
  sdec.ui_refresh()

  -- Not pcall'd: the nesting is what the firmware cannot take (see start()). sdec.unwind restores.
  local ok, why = sdec.autoset()

  -- One fresh capture after a back-off: decode() sets rate_backoff when a locked rate fit nothing, so the
  -- lock is gone and detection re-runs. Cleared BEFORE the retry, or a second back-off retries for ever.
  local rb = sdec.rate_backoff
  sdec.rate_backoff = nil
  if rb then
    ulog.line('rate back-off: ' .. tostring(sdec.relocked))
    sdec.ui_status = 'retrying'
    sdec.ui_refresh()
    local keep = sdec.relocked
    ok, why = sdec.autoset()
    -- The retry does not clear relocked, and an autolock inside it publishes autolocknote: both belong.
    if sdec.relocked == nil then sdec.relocked = keep end
    sdec.rate_backoff = nil
  end
  sdec.busy = false

  if not ok then
    sdec.errcount = sdec.errcount + 1
    -- A capture that found nothing is the normal result of probing a quiet pin, so it is a reason.
    if sdec.lasterr == nil then sdec.lasterr = tostring(why) end
    sdec.ui_status = 'no decode'
    ulog.line('no decode: ' .. tostring(why))
  else
    sdec.ui_status = 'done'
    sdec.ui_page = 0
    -- One call each, no guard: the three are independent facts, and summary() defends every value it
    -- formats. A guard here would wrap our own formatting on a handler's success tail.
    ulog.line(sdec.summary(1))
    ulog.line(sdec.summary(2))
    ulog.line(sdec.summary(3))
    -- Parse the protocol layer HERE, not lazily when the view opens, so the log records the messages of
    -- the capture that produced them -- and before the notes, so the LIN break count is in the list.
    -- Bare calls, each callee carrying its own guard: this is a handler's success path.
    sdec.proto_parse()
    -- Before the notes, so the auto-lock note is one of them: locking must never retract a good capture.
    sdec.autolock_try()
    -- Every note, not just the one the panel has room for: this is where the rest become recoverable.
    local nt, nn = sdec.ui_notes()
    local ni
    for ni = 1, nn do ulog.line('note: ' .. nt[ni]) end
    -- The whole capture as a hex dump: the panel shows one page, the file keeps everything.
    if sdec.res ~= nil then
      local i, per = 1, 16
      while i <= sdec.res.nf do
        ulog.line(sdec.ua_hex_line(i, per))
        i = i + per
      end
    end
    -- FRAME+LOG appends to its own file. A bare call: frame_log() registers its handle for sdec.unwind.
    if md.log then sdec.frame_log() end
  end

  sdec.ui_refresh()
  return ok
end

-- The half-second tick is off for the whole press. A tick is dispatched exactly like a press, so work that
-- holds the interpreter defers ticks rather than suppressing them -- a 10 s hold releases 2, not 10, so
-- this is about not collecting one at all. A wrapper rather than an edit into the body, because
-- capture_run() has a dozen returns and a missed one would leave the panel with no tick.
--
-- The body is not guarded, and a raise reaches the caller: `pcall(sdec.capture)` is how two callers ask
-- whether the press faulted. What a raise would skip, sdec.unwind restores. The key is checked by the
-- press, first -- it closes no gap, but Capture ASKS instead of inheriting the answer from inside a
-- function the press cannot see.
function sdec.capture()
  sdec.ui_keypoll()
  sdec.ui_tick_off()
  -- Registered, so sdec.unwind drops the stale result only when a CAPTURE unwound past it.
  sdec.drop_pending = true
  local a, b = sdec.capture_run()
  sdec.drop_pending = nil
  sdec.ui_tick_on()
  return a, b
end

-- ============================================================================
-- Auto-lock
-- ============================================================================
-- Lock the wire parameters as soon as they are known confidently. An unknown format costs the format
-- search, twelve times the cost of framing a known one, and autoset() takes a WHOLE EXTRA capture at the
-- top sample rate purely to find the baud rate -- so the second press onward runs about three times
-- faster for the same bytes. docs/MEASUREMENTS.md, 'Auto-lock pays for itself'. It also does something
-- the operator cannot get otherwise: the streaming modes require a locked rate, so until something locks
-- they refuse.
--
-- The gates are the whole design: locking a WRONG detection turns a one-capture mistake into a persistent
-- one. The five in autolock_try() are independent -- timing, framing, sample size, fit quality, baseline
-- stability -- and five correlated checks would be one check.
-- ============================================================================
sdec.autolock_min  = 8      -- frames required before a detection may be locked
-- Fraction of the capture that must be ONE unbroken correctly-framed run. Well short of 1.0 because the
-- auto-detect capture is the shortest the app takes. docs/MEASUREMENTS.md, 'autolock_run = 0.6'.
sdec.autolock_run  = 0.6
sdec.autolock_fitq = 0.9    -- least-squares fit quality required
-- Operator state, so `or`/nil-test like the rest: someone who turned this off must not find it back on
-- after an App relaunch. On by default, so the fast streaming-capable state is reached by itself.
if sdec.autolock == nil then sdec.autolock = true end

-- Suppress auto-lock for the NEXT capture only. Returns true.
function sdec.autolock_defer()
  -- An explicit request for auto-detect must survive the capture that follows it. Called wherever the
  -- operator asks for it, and consumed by the next autolock_try(): without it the same press re-locks the
  -- rate just detected. One capture of grace -- the request was "detect it", not "never lock again".
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
  -- Gate 1, a credible rate: the measurement either matched a standard rate within snaptol or rounds to a
  -- 10 Bd boundary inside 1 % (sdec.baud_round). Snapping alone was not enough -- a device at 16 kBd never
  -- autolocked, so every recording mode refused for want of a locked rate. And lock the measurement, not
  -- an overstated snap: sdec.baud is already relabelled by sig_snap, so a soft snap would commit a rate
  -- the fit does not support -- a 37422 Bd line read 37703, relabelled 38400, locked 2.6 % out.
  local lockfrom = sdec.baud
  if sdec.snapped and sdec.snapfirm == false and sdec.baud_raw ~= nil then lockfrom = sdec.baud_raw end
  local lockb, lockok = sdec.baud_round(lockfrom)
  if not sdec.snapped and not lockok then return false end
  -- Gate 2, the longest contiguous clean run -- not an error count and not an error POSITION. What
  -- justifies a lock is that the format explains a long unbroken stretch: scattered errors, which is what
  -- a wrong format gives, leave no long run. nf is defended so the caller can call this bare.
  local nf = r.nf or 0
  local best, cur, i = 0, 0, nil
  for i = 1, nf do
    if r.errs[i] == nil then
      cur = cur + 1
      if cur > best then best = cur end
    else
      cur = 0
    end
  end
  if best < sdec.autolock_min then return false end
  if best < sdec.autolock_run * nf then return false end
  -- GATE 3: enough frames that agreement means something. Two clean frames of noise agree with
  -- each other too.
  if (r.ngood or 0) < sdec.autolock_min then return false end
  -- GATE 4: the least-squares bit time explains the pulse widths it was fitted to.
  if (sdec.fitq or 0) < sdec.autolock_fitq then return false end
  -- Gate 5, the one about the SIGNAL rather than the decode. An unstable baseline is precisely when a
  -- confident-looking lock is least deserved: the four above describe how self-consistent this ONE capture
  -- was, and a marginal line can be self-consistent by luck. Guarded on existence (serial_core).
  if sdec.sig_levelwarn ~= nil and sdec.sig_levelwarn() ~= nil then return false end

  -- Only the fields the operator left on Auto. Assigning all four overwrites a hand-forced parity, width
  -- or stop count, so a setting chosen in Options survives one capture and the form reads the detected
  -- value back as the operator's. Which fields this set is recorded, because a back-off has to drop what
  -- the app chose without touching what was typed, and provenance cannot be recovered afterwards.
  sdec.autolock_set = {}
  -- Rounded, so a non-standard measurement locks as a number an operator could have typed: 16099 -> 16100.
  sdec.force_baud   = lockb
  sdec.autolock_set.baud = true
  if sdec.force_nbits == nil then sdec.force_nbits = r.nbits; sdec.autolock_set.nbits = true end
  if sdec.force_par   == nil then sdec.force_par   = r.par;   sdec.autolock_set.par   = true end
  if sdec.force_nstop == nil then sdec.force_nstop = r.nstop; sdec.autolock_set.nstop = true end
  -- Polarity is deliberately not locked, the one asymmetry in the set. Left nil, decode_from() falls back
  -- to the level-based inference and skips the contest; locked, it freezes what the contest decided on the
  -- shortest, least evidenced capture the app takes. docs/MEASUREMENTS.md, 'Polarity is not locked'. Rate
  -- and frame shape are worth locking because re-deriving them costs a capture; polarity costs one test.
  sdec.force_invert = nil

  -- Names the payoff, not just the fact: the next press runs at a lower sample rate over a longer window,
  -- and the window size is the number the operator cares about. Sized to fit the note cell, 685 px against
  -- 700 (sdec.ui_note_px). The panel must show what was LOCKED, not what was measured -- baud_text() marks
  -- an unsnapped rate with '?', so a rounded 16100 beside sdec.baud 16099 drew '16099?' under a green
  -- padlock. baud_raw is left alone: it is the honest measurement, and the cross-check compares to it.
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.force_baud, true, true
  local fs = sdec.fs_for_baud(sdec.force_baud)
  local nb = sdec.window_bytes(sdec.force_baud, r.nbits, r.par, r.nstop)
  sdec.autolocknote = string.format(
    'auto-locked %s %s: next %g kS/s ~%d B (Options > Baud Rate = 0 re-detects)',
    tostring(sdec.baud_text()), tostring(sdec.fmt_text()), (fs or 0) / 1000, nb or 0)
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
  -- Guarded on the function's existence as well as on the mode: the protocol modules are separate, and a
  -- build that omits one must degrade to the raw UART views rather than raise from a touch handler.
  if fn == nil then return false end
  local ok, perr = pcall(fn)
  -- A parser that raised must not leave an empty protocol view looking like an answer: the capture stays
  -- 'done', so a blank view reads as "your device emitted no protocol messages". The partial result is
  -- retracted too, because half a message list looks complete.
  if not ok then
    sdec[v.res] = nil
    sdec.proto_why = string.format('%s decode failed (%s) -- the bytes below are still the '
                                   .. 'decoded UART stream', tostring(mode),
                                   tostring(perr or 'unknown'))
    ulog.line('proto: ' .. sdec.proto_why)
    return false
  end
  if sdec[v.res] ~= nil then
    local sm = sdec[v.summary]
    -- The summary is the protocol module's own function, so it takes the same guard as the parse.
    if sm ~= nil then pcall(function() ulog.line(tostring(mode) .. ': ' .. tostring(sm())) end) end
  end
  return ok
end

-- Parse the layers the panel is about to need: the one SELECTED on the options form, and the one
-- being VIEWED when that is a different one. `which` parses that layer alone. Returns whether
-- any parser ran.
function sdec.proto_parse(which)
  -- Both, because the View button reaches the MIDI and LIN lists for any capture.
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
-- The inbound firmware boundary
-- ============================================================================
-- Put back whatever a raise unwound past, and report it. -> false, so a catcher can end with
-- `return sdec.unwind(err)`.
--
-- Separate from sdec.guard because not every raise reaches the boundary: a frame that catches one to make
-- a decision of its own -- lock_toggle -- has to do this too, or the cleanup does not happen. One Lock
-- Rate press whose re-capture raised left trigmode on 'free', busy latched, the tick off and the panel
-- reading 'capturing', with the press reporting success.
--
-- Raise-free by construction: assignments, two self-guarding calls, and a nil test on every function
-- called by name, since a partial load must not turn the boundary into the popup source it prevents. It
-- does not log either -- ulog.line reaches file.write, and a full key is what brought us here.
-- filled up is exactly the condition that brought us here.
function sdec.unwind(why)
  sdec.busy = false
  sdec.ck_running = false
  -- The unwind registers: a frame parks a module field here, because a local is invisible from here.
  if sdec.trig_restore ~= nil then
    sdec.trigmode = sdec.trig_restore
    sdec.trig_restore = nil
  end
  -- The drop belongs to the capture path, not every handler: a capture that raised part-way has
  -- half-rewritten the measurements, where a Save or a View has invalidated nothing.
  if sdec.drop_pending then
    sdec.drop_pending = nil
    if sdec.drop_stale_result ~= nil then sdec.drop_stale_result() end
  end
  -- An open handle is not reclaimed until a power cycle. Bare: file.close cannot transfer control.
  if sdec.fh_unwind ~= nil then
    local h = sdec.fh_unwind
    sdec.fh_unwind = nil
    file.close(h)
  end
  if sdec.ui_tick_on ~= nil then sdec.ui_tick_on() end
  sdec.errcount = (sdec.errcount or 0) + 1
  sdec.lasterr = tostring(why)
  sdec.ui_status = 'error'
  if sdec.ui_refresh ~= nil then sdec.ui_refresh() end
  return false
end

-- Run a panel handler so a raise cannot reach the firmware. -> true if it returned.
--
-- The one place a pcall may wrap our own code, and it is a firmware boundary like any other: the
-- instrument calls these by name out of a display event string, and an escaping raise becomes a modal
-- dialog over the app. One helper, so the boundary is ONE pcall site and it covers the whole handler.
function sdec.guard(f)
  local ok, err = pcall(f)
  if ok then return true end
  return sdec.unwind(err)
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
    sdec.ui_refresh()
    return false
  end

  local L, n = {}, 0
  local function add(s) n = n + 1; L[n] = s end
  add('DMM6500 serial decode')
  add('')
  -- The wire parameters go in the file: 4800 8N1 and 9600 7N1 give identical bytes from one waveform.
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
  add(string.format('bytes      %d   framing errors %d', sdec.res.nf or 0, sdec.res.nbad or 0))
  if sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('false starts rejected %d  (impulse noise)', sdec.res.nfalse or 0))
  end
  -- Every note. The panel cell holds one and counts the rest; this file is where the rest live.
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

  -- Every parsed protocol list with anything in it. A protocol capture is where raw bytes are least
  -- readable: MIDI running status need not start with a status byte, and LIN boundaries are timing.
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
    -- Name the reason next_free gave: a nil path reaches write_file as 'no filename available', which
    -- describes this function's variable, where ulog.idx_why holds the real sentence.
    if path == nil and ulog.idx_why ~= nil then why = ulog.idx_why end
    sdec.lasterr = 'save failed: ' .. tostring(why)
  end
  sdec.ui_refresh()
  return ok
end

-- ============================================================================
-- View handlers
-- ============================================================================
-- Advance through the views THIS BUILD HAS -- text -> hex -> text in version 1, which ships without
-- midi_decode.tsp and lin_decode.tsp, so ui_view_avail() hides the entries that would always be empty.
function sdec.view_toggle()
  -- The key is checked by the press, first. View writes nothing to the key, so its other route to a
  -- correct panel is the ui_refresh() at the end; all three presses answer the question the same way.
  sdec.ui_keypoll()
  -- Every protocol view is offered whatever the protocol setting says, because "is this stream MIDI at
  -- all?" is worth asking of any capture. Cycles over the views this build has (ui_view_avail).
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
  -- Parse on first entry: capture() did it for the selected protocol, and clear_result() drops the list.
  if nx.res ~= nil and sdec[nx.res] == nil then sdec.proto_parse(nx.mode) end
  sdec.ui_page = 0
  sdec.ui_rowc = nil          -- force a colour re-evaluation on the new layout
  return sdec.ui_refresh()
end

-- Show the next page of bytes. Bound to the 'Dn' button down the dump area's right margin, with
-- page_prev() as 'Up' above it; the host drives both over the socket. ui_paged is set even when the page
-- does not move: it is what puts 'page N of M' on the note row, and the last page is when that matters.
function sdec.page_next()
  sdec.ui_paged = true
  if sdec.ui_page + 1 < sdec.ui_npages() then sdec.ui_page = sdec.ui_page + 1 end
  return sdec.ui_refresh()
end

-- Show the previous page of bytes.
function sdec.page_prev()
  sdec.ui_paged = true
  if sdec.ui_page > 0 then sdec.ui_page = sdec.ui_page - 1 end
  return sdec.ui_refresh()
end

-- Start a new byte log, so one device's or one test's messages are separated from the next.
function sdec.log_new()
  -- Forgetting the path is the whole mechanism: frame_log() opens and closes per capture, so the next one
  -- lands on the next unused name. It says so on the note line rather than silently renumbering.
  local was = sdec.flog_path
  ulog.flush()
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  if was ~= nil then
    local base = string.gsub(tostring(was), '^.*/', '')
    sdec.lognote = string.format('closed %s -- the next capture starts a new file', tostring(base))
  else
    sdec.lognote = 'no message log open yet -- the next capture starts one'
  end
  ulog.line(sdec.lognote)
  return sdec.ui_refresh()
end

-- Clear every forced setting and re-capture: the inverse of Lock Detected, which is the button
-- beside it on the options form.
function sdec.options_auto()
  -- Auto-detection is already the DEFAULT, so this is a one-press way back to it rather than a new
  -- capability: by hand it is six interactions, which is enough friction to leave a stale lock in place.
  sdec.unlock_all()
  -- No autolock_defer() here: 'Auto Detect' means "work it out and use it", so this capture may lock what
  -- it finds. The deferral belongs to Options > Baud Rate = 0, which is a request to STAY unlocked.
  ulog.line('auto-detect: all forced settings cleared')
  sdec.options_seed()
  -- Auto-detect is a FRAME-mode operation and cannot be otherwise, being gated on a locked rate. So this
  -- press lands in FRAME, and it does so by exiting properly rather than by refusing.
  local md = sdec.mode_cur()
  if md.needbaud then
    sdec.mode_exit('auto-detect is FRAME-mode only')
    -- Set here, not in mode_exit(): that function is a flush and does not touch the mode.
    sdec.capmode = 'frame'
  end
  return sdec.options_apply()
end

-- THE PADLOCK'S ACTION: amber (auto) locks the detected settings and goes green, green (locked)
-- unlocks back to auto, red (nothing decoded) refuses with a reason. Either way it re-captures.
function sdec.lock_toggle()
  -- Locking the baud rate changes the sample rate, which is why this re-captures rather than merely
  -- pinning: fs_for_baud() picks the lowest listed rate still giving 8 samples/bit, so locking 9600 moves
  -- fs from 1 MS/s to 80 kS/s and the window from 19 bytes to 240. Without the re-capture, three header
  -- cells and a note describe the capture that produced them and nothing the instrument will do next.
  --
  -- Re-entrancy guard, and not a theoretical one: this handler calls capture() and is wired to two
  -- overlapping rects, so one fingertip can fire it twice -- the outer locks and captures, the inner sees
  -- 'locked' and UNLOCKS, and the note then claims a lock that is gone.
  if sdec.busy then return false end
  local st = sdec.lock_state()
  local note = nil
  if st == 'locked' then
    sdec.unlock_all()
    sdec.autolock_defer()
    note = 'unlocked -- auto-detecting again, back to the top sample rate'
    -- Unlocking disarms the streaming modes, so leave one rather than sit where Capture cannot run.
    if sdec.mode_cur().needbaud then
      sdec.mode_exit('unlocked the baud rate')
      sdec.capmode = 'frame'
    end
  elseif st == 'auto' then
    local r = sdec.res
    if r == nil or sdec.baud == nil then
      sdec.lasterr = 'nothing decoded yet -- capture first, then lock'
      return sdec.ui_refresh()
    end
    -- Through baud_round, as at the Options Lock path: sdec.baud is a standard rate only when snapped.
    sdec.force_baud   = math.floor(sdec.baud_round(sdec.baud) + 0.5)
    sdec.force_nbits  = r.nbits
    sdec.force_par    = r.par
    sdec.force_nstop  = r.nstop
    sdec.force_invert = r.invert
    -- The operator pressed Lock Rate over these values, so none of them is autolock's to withdraw.
    sdec.autolock_set = nil
    -- baud_text reads sdec.baud, so the note would name the measurement, not the rounded lock.
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.force_baud, true, true
    note = string.format('locked %s %s', tostring(sdec.baud_text()), tostring(sdec.fmt_text()))
  else
    sdec.lasterr = 'nothing decoded yet -- capture first, then lock'
    return sdec.ui_refresh()
  end

  -- Re-capture at the rate the new lock implies, so RATE, SA/BIT, BYTES and the window note describe the
  -- same thing. Guarded for the VERDICT, not for safety: capture() guards nothing, so the raise arrives
  -- here and this frame owes the unwind. The verdict is kept because the sentence below claims the
  -- recapture worked -- discarded, a raise still produced 'locked 9600 baud -- now sampling at 80 kS/s'.
  local pok, cres = pcall(sdec.capture)
  local cok = pok and cres
  -- Catching it means owning the cleanup: sdec.guard never sees this raise.
  if not pok then sdec.unwind('capture raised: ' .. tostring(cres)) end
  -- After the capture, because clear_result() evicts the note cell.
  if note ~= nil and not (pok and cok) then
    -- Say both halves: the setting took, the measurement did not. lasterr outranks this note.
    sdec.lognote = note .. ' -- but the re-capture failed, so the figures above are the previous one'
    note = nil
  end
  if note ~= nil then
    -- sdec.fs, the REQUESTED rate: acq_fs describes the capture that just happened.
    local fs = sdec.fs
    if fs ~= nil and fs > 0 then
      if fs >= 1000000 then note = string.format('%s -- now sampling at %.0f MS/s', tostring(note), fs / 1000000)
      else note = string.format('%s -- now sampling at %.0f kS/s', tostring(note), fs / 1000) end
    end
    sdec.lognote = note
  end
  ulog.line(tostring(sdec.lognote or sdec.lasterr))
  sdec.options_seed()
  return sdec.ui_refresh()
end

-- Toggle the external trigger from the status row.
function sdec.trigext_toggle()
  -- Wired speculatively, like the padlock: EVENT_PRESS on a rect is unverified, so Options is the path.
  if sdec.busy then return false end
  sdec.trigext = not sdec.trigext
  if sdec.trigext and sdec.trigmode == 'free' then
    sdec.lognote = 'external trigger ON but IGNORED -- Free run means do not wait'
  elseif sdec.trigext then
    sdec.lognote = 'external trigger ON -- the rear BNC also starts a capture'
  else
    sdec.lognote = 'external trigger OFF'
  end
  ulog.line(tostring(sdec.lognote))
  sdec.options_seed()
  return sdec.ui_refresh()
end

-- The note-row wording for a finished recording. endwhy is sdec.ck_endwhy; ok and err are the
-- run's verdict and its message.
function sdec.strm_exit_why(endwhy, ok, err)
  -- A cancel outranks the nothing-collected refusal, because it CAUSED it: a press breaks the poll loop
  -- where it stands, so the interrupted window reports 'long capture returned nothing' -- the documented
  -- stop control presented as a fault. A failure with a cause of its own still wins, via strm_empty.
  if ok == false and not (sdec.ck_cancel and sdec.strm_empty) then
    -- The failure is the reason, and it belongs on the note row as well as in the status cell.
    return 'run failed: ' .. tostring(err or 'unknown')
  end
  -- The three ck_endwhy values all mean "the run is over" but say different things about the LINE: quiet
  -- means the device stopped, stopped means you stopped it, full means neither. A cancel outranks them --
  -- ck_endwhy describes the ACQUISITION, so a press during the DECODE leaves it 'full'.
  if sdec.ck_cancel then
    if (sdec.fc_win or 0) > 1 then
      return string.format('stopped with the TRIGGER key after %d windows', sdec.fc_win or 0)
    end
    return 'stopped with the TRIGGER key'
  end
  -- A bound is a run-level reason and applies from the first window, unlike the two below it: at 300 baud
  -- a single window waits out the whole 20 minutes. The remedy is two presses and a new file, and the DATA
  -- survives -- the sender still waits for a credit, so the recording fragments rather than truncates.
  if sdec.fc_end == 'bound' then
    return string.format('reached the %d-window limit -- Mode, then Capture, resumes in a new file',
                         sdec.fc_maxwin or 32)
  elseif sdec.fc_end == 'timebound' then
    -- In minutes because that is what was spent, with the window count because that says what came back.
    return string.format('reached the %g-minute limit after %d window(s) -- Mode, then Capture, '
                         .. 'resumes in a new file', (sdec.fc_maxsec or 1200) / 60, sdec.fc_win or 1)
  end
  -- A multi-window run ended for a reason of its own: every window but the last ended 'full'.
  if (sdec.fc_win or 0) > 1 and sdec.fc_end ~= nil then
    if sdec.fc_end == 'quiet' then
      return string.format('%d windows, then the device stopped sending', sdec.fc_win or 0)
    elseif sdec.fc_end == 'stopped' then
      -- Not reachable from the panel today, and the wording must not pretend otherwise: only cancel_asked()
      -- sets ck_stop while the loop runs, and it returns above. Insurance against a dispatch point.
      return string.format('stopped after %d windows', sdec.fc_win or 0)
    end
    -- No bound arms here: both returned above, from the first window on.
  end
  -- The buffer could not be read: folded into 'quiet' a fault read as the device finishing normally.
  if endwhy == 'readfail' then
    return 'recording failed: ' .. tostring(sdec.strm_readfail or 'the capture buffer could not be read')
  end
  -- The arm expired, which is not a recording that happened: name the two settings that govern the wait.
  if endwhy == 'noarm' then
    return string.format('nothing crossed %.2f V in %g s -- raise Arm Wait or lower Arm At',
                         sdec.arm_expired_at or sdec.thr or sdec.arm_level_v(), sdec.arm_wait_s())
  end
  if endwhy == 'quiet' then
    return string.format('%g s with no line activity', sdec.idle_exit_s or 0)
  elseif endwhy == 'stopped' then
    -- Who stopped it, distinguished: a TRIGGER press is the operator, Mode is the app on their behalf.
    if sdec.ck_cancel then return 'stopped with the TRIGGER key' end
    return 'stopped from the panel'
  elseif endwhy == 'full' then
    return 'buffer full -- the stream may continue'
  end
  return 'finished'
end

-- How long a queued press stays absorbable.
--
-- The absorb exists because a press aimed at stopping a stream is only dispatched once the run's Lua
-- returns, and would otherwise land as a new capture that wipes the bytes on screen. But it must not eat
-- a press made minutes later: a queued press dispatches essentially immediately, so the window only has
-- to be wider than scheduling jitter, and deliberately narrower than reaction time.
--
-- An absorb, not a flush: nothing can drain the firmware's pending-press queue, so each queued press is
-- still delivered, recognised as queued, and does nothing.
sdec.strm_absorb_s = sdec.strm_absorb_s or 1.0

-- Arm the queued-press absorb after a run that held the interpreter.
--
-- On every ending, including 'stopped'. Returning early because a press was SEEN assumes nothing is
-- queued behind it: true of one press, false of an operator who presses Capture, TRIGGER, Capture.
function sdec.strm_absorb_arm()
  sdec.strm_stopped_by_press = nil
  sdec.strm_nabsorbed = 0
  -- timer.cleartime() stamps the moment the run ended; nothing else runs before the queued press.
  timer.cleartime()
  sdec.strm_stopped_by_press = true
end

-- True if we are still inside the window in which a press must have been queued.
function sdec.strm_absorb_due()
  if not sdec.strm_stopped_by_press then return false end
  local el = timer.gettime()
  if el == nil then return false end
  return el <= sdec.strm_absorb_s
end

-- The one gate every handler that matters consults: was this press queued behind a run that has already
-- ended? True means it is dealt with and the caller must return without acting.
--
-- Every press in the window, not the first: disarming on the first absorb left a burst of three with one
-- swallowed and two honoured. A stale arm is cleared here, because the elapsed time lives in the ONE
-- global timer and an arm past its window would be resurrected by the next unrelated cleartime() -- so
-- anything taking the timer disarms first, as record_run() and every harness do.
--
-- Capture only, narrowed by measurement: wired to Mode as well, bench_panel's Mode/rec-exit failed,
-- because Mode is the way OUT of a mode and a dead escape hatch is worse than an unwanted mode change.
-- The test that survives is the harm -- only Capture starts an uninterruptible run and wipes the result.
function sdec.press_absorbed(what)
  if not sdec.strm_absorb_due() then
    -- Stale arm from a run whose window has passed, cleared on the first press after it.
    sdec.strm_stopped_by_press = nil
    sdec.strm_absorbed = nil
    return false
  end
  local n = (sdec.strm_nabsorbed or 0) + 1
  sdec.strm_nabsorbed = n
  -- lasterr goes: a queued press must not replace the verdict the operator is reading.
  sdec.lasterr = nil
  if n == 1 then
    sdec.strm_absorbed = string.format('%s taken as the Stop for the recording that just '
                                       .. 'ended -- press again to use it',
                                       tostring(what or 'the press'))
  else
    -- 'Within a second of', not 'queued during the recording': a 1 s window cannot tell which it was.
    sdec.strm_absorbed = string.format('%d presses within a second of the run ending were '
                                       .. 'discarded -- press again to capture', n or 0)
  end
  ulog.line(sdec.strm_absorbed)
  sdec.ui_refresh()
  return true
end

-- Flush the current capture mode's files and say why. `why` goes on the note row. Returns the mode that
-- was left -- it does NOT change it; see the block below.
--
-- `bad` says the run ENDED BADLY, and it is passed rather than inferred: the note row shows this
-- function's message only when it is set, because a run that finished normally has the status row's
-- summary already. Not sniffed out of `why` -- matching on words like 'failed' is how a protected failure
-- gets narrowed to a boolean nobody checks, which is this app's dominant defect class.
--
-- Never raises for any measured failure, so the four callers call it bare; see ulog.line for the one
-- unmeasured case. It touches no firmware directly.
function sdec.mode_exit(why, bad)
  -- One function for every way out -- the Mode button, an idle line, a completed run, End App -- so all
  -- flush the same way. A mode that can be left by two paths with different cleanup eventually loses the
  -- tail of a file. What needs flushing: an in-progress stream, through ck_stop, so the window loop
  -- finishes and ck_run() calls the sink's finish(); the byte log's PATH, so re-entering starts a new
  -- numbered file; and ulog, flushed and not closed, because it outlives every mode.
  local was = sdec.capmode
  local md = sdec.mode_cur()
  local running = sdec.ck_running
  -- A decode in progress owns an open file, so leaving the mode without abandoning it would strand the
  -- handle until a power cycle and lose the sink's carry. Clearing ck_running matters here: `running` was
  -- snapshotted for the one-shot path, and a press-driven run has no loop to own it.
  local pressdriven = (sdec.ck_job ~= nil) or (sdec.strm_recording == true)
  if sdec.ck_job ~= nil then sdec.decode_abandon() end
  -- Likewise a recording still running in hardware, or it goes on filling a buffer nothing will read.
  if sdec.strm_recording then
    sdec.strm_recording = nil
    sdec.stream_settle()
  end
  if pressdriven then
    running = false
    sdec.ck_running, sdec.ck_stop = false, false
  end
  ulog.flush()
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  -- The mode is not changed here, and that is the point of this function being only a flush. Setting
  -- capmode = 'frame' moves the operator to a mode they did not choose every time a recording finishes,
  -- and the capture mode is in the TITLE BAR. The two callers that need FRAME set it beside their reason.
  if running then
    -- REQUEST a stop and leave ck_running alone: the run owns that flag and clears it as it unwinds. So
    -- ck_stop is left TRUE on the way out and nothing on the unwind path clears it; what makes that safe
    -- is the ENTRY clear in stream_begin(), which sets ck_stop = false before any window runs. Do not
    -- delete that entry clear on the theory that this exit path handles it. It does not.
    sdec.ck_stop = true
  else
    -- Not running, so both flags are this function's to normalise, and ck_stop may already be true.
    sdec.ck_running, sdec.ck_stop = false, false
  end
  sdec.mode_exited, sdec.mode_exitbad = nil, false
  if md.id ~= 'frame' then
    -- Said on the note line, and now that the mode does NOT change the note must not claim it did.

    -- Always set and always logged; tools/test_cancel.lua reads it. Only the note row is conditional.
    sdec.mode_exited = string.format('%s run ended (%s)', tostring(md.name), tostring(why or 'exited'))
    sdec.mode_exitbad = (bad == true)
    ulog.line(sdec.mode_exited)
  end
  return was
end

-- Which mode an idle Mode press advances to -- the ENTRY, not the id.
--
-- Factored out so the panel can name it: the status row said 'Mode=Exit to FRAME' in every recording mode,
-- and from 8 kB the button goes to 32 kB. A label that names the wrong destination is this app's recurring
-- defect, so the label and the action read the SAME function. Skips any mode that cannot be right at the
-- locked rate (mode_suits), bounded by n steps, because a table where nothing suits must not spin inside
-- a touch handler. math.mod, not '%': 5.0.2.
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

-- The Mode button. Two behaviours, and which applies turns on whether a run is in progress:
--
--   RUNNING  -> abort. Stop the stream and flush, in one press, STAYING in the mode.
--   IDLE     -> advance to the next mode, flushing the one being left on the way out.
--
-- The running branch does not land in FRAME: mode_exit() is a flush, so an abort leaves the setting.
function sdec.mode_cycle()
  -- The key is checked by the press, first: Mode is the press the no-key reports name.
  sdec.ui_keypoll()
  -- A rate offer dies with the capture that raised it: both branches discard the result, so a surviving
  -- offer would let rate_accept() drop the lock on the strength of a capture that is gone.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  -- Not absorbed: Mode is a way to STOP, and a dead Mode button is worse than an unwanted mode change.
  if sdec.ck_running then
    sdec.mode_exit('Mode pressed')
    -- The summary survives a stream that ended by itself; an explicit Mode press is the operator leaving.
    sdec.ck_tot, sdec.ck_nbytes = nil, nil
    -- Mode is the way out, so it must get out. mode_exit() only REQUESTS a stop, which is right from
    -- inside a run's own unwind and wrong here: a handler executing proves no loop is.
    sdec.ck_running, sdec.ck_stop = false, false
    sdec.ui_status = 'stopped'
    return sdec.ui_refresh()
  end

  -- Does not refuse a mode whose preconditions are unmet: Capture refuses, and the status row says what.
  local n = sdec.ui_modes.n
  local at, i = 0, nil
  for i = 1, n do
    if sdec.ui_modes[i].id == sdec.capmode then at = i end
  end
  -- Flush the mode being left, then select the next. `at` is read before the flush, but mode_exit() does
  -- not touch capmode. The cycle skips any mode that cannot be right at the locked rate.
  local nxt = sdec.mode_next().id
  sdec.mode_exit('switching')
  sdec.capmode = nxt
  -- Switching drops the streaming result: a stale count under another mode name reads as a measurement.
  sdec.ck_tot, sdec.ck_nbytes = nil, nil
  ulog.line('mode = ' .. sdec.capmode)
  return sdec.ui_refresh()
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
  -- Hysteresis, not a bare threshold comparison: an idle line sitting AT the threshold reports activity
  -- from ADC noise alone. The same trip rule sig_edges uses, so "activity" means what "an edge" means.
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
  -- A tenth of a second is far more than one frame at any rate this app decodes, so one byte trips it.
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
    -- Guarded explicitly, not left to the pcall: version 1 omits the Protocol field, and everything here
    -- is inside ONE pcall, so a raise on the first line would leave every field below it stale.
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
    -- The rear-BNC field is a 1-based option index, not display.ON/OFF -- it was a check object until flow
    -- control needed a second boolean. Seeded by searching opt_rear_v, so the two ends cannot disagree.
    local xi, rk = 1, nil
    for rk = 1, sdec.opt_rear_v.n do
      if sdec.opt_rear_v[rk][1] == sdec.trigext and
         sdec.opt_rear_v[rk][2] == sdec.fc_out then xi = rk end
    end
    display.setvalue(sdec.opt_ext, xi)
    display.setvalue(sdec.opt_trig, ti)
    -- Seeded through the clamps, so a value set outside the form's range shows as what will be used.
    display.setvalue(sdec.opt_armv, sdec.arm_level_v())
    display.setvalue(sdec.opt_armw, sdec.arm_wait_s())
  end)
end

-- Snapshot everything the form can change, so Cancel can undo it. Returns true.
function sdec.options_save()
  -- A screen with a Cancel button promises its edits are provisional, and Lock Detected breaks that: it
  -- writes the live forced settings the moment it is pressed. Taken on the way in, this covers every route
  -- the form has to that state. The provenance is part of the state, and so is the displayed rate --
  -- options_lock() publishes baud/snapped/snapfirm, so a snapshot of force_* alone turned a soft-snapped
  -- '38400?' into an unmarked '38400'. dhas marks them recorded, since nil is legitimate for all three.
  sdec.opt_snap = {baud = sdec.force_baud, nbits = sdec.force_nbits,
                   par = sdec.force_par, nstop = sdec.force_nstop,
                   invert = sdec.force_invert, proto = sdec.proto,
                   any = sdec.widths_any, trig = sdec.trigmode,
                   ext = sdec.trigext, fc = sdec.fc_out, view = sdec.ui_mode,
                   aset = sdec.autolock_set,
                   armv = sdec.armlevel, armw = sdec.armwait,
                   dhas = true, dbaud = sdec.baud,
                   dsnap = sdec.snapped, dfirm = sdec.snapfirm}
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
  sdec.autolock_set = s.aset
  -- Guarded on the values themselves, which is a different test from the dhas below: nil is legitimate for
  -- the three display fields, and NOT for these two, so a nil here means a snapshot built without them.
  -- Two offline fixtures build one by hand, and the clamps then ran the feature at its floors unnoticed.
  if type(s.armv) == 'number' then sdec.armlevel = s.armv end
  if type(s.armw) == 'number' then sdec.armwait = s.armw end
  -- Guarded on dhas, not on the values: nil is legitimate for all three.
  if s.dhas then
    sdec.baud, sdec.snapped, sdec.snapfirm = s.dbaud, s.dsnap, s.dfirm
  end
  return true
end

-- Show the options screen, building it first if it does not exist yet.
function sdec.options()
  -- Through pcall: build_options() raises by design when the pool is exhausted, and this is a handler.
  if sdec.optscr == nil then
    local bok, berr = pcall(sdec.build_options)
    if not bok or sdec.optscr == nil then
      sdec.lasterr = tostring(berr or 'the options screen could not be built')
      ulog.line('options: ' .. sdec.lasterr)
      return sdec.ui_refresh()
    end
  end
  sdec.options_save()     -- so Cancel has something to go back to
  -- The seed's verdict decides whether the form may open: a setvalue that fails part way leaves the fields
  -- above it current and the ones below stale, the operator reads one state, and Apply applies every one.
  -- Refusing is right here, unlike the sample-rate fallback: Options is reachable when the pool recovers.
  local sok = sdec.options_seed()
  if not sok then
    sdec.lasterr = 'the Options form could not be filled in with the current settings -- not opening '
                   .. 'it, because Apply would then apply values you were not shown'
    ulog.line('options: ' .. sdec.lasterr)
    return sdec.ui_refresh()
  end
  -- Nothing periodic may run while this form is up, and the edit fields are the reason: a field is an
  -- OBJ_EDIT_*, so a press on one opens a firmware MODAL EDITOR, and the tick is dispatched like a press
  -- and polls the USB key through a filesystem call whose latency is not ours. Fields needed several
  -- presses over 5-10 s while the buttons stayed responsive. Nothing here reads key presence.
  sdec.ui_tick_off()
  local ok = pcall(display.changescreen, sdec.optscr)
  if not ok then sdec.ui_tick_on() end
  return ok
end

-- Copy what the last capture DETECTED into the forced fields and re-seed the form. Does NOT
-- re-capture: the values are there to be reviewed, then applied with Apply.
function sdec.options_lock()
  -- The workflow the auto-detector is for: probe an unknown line once, then pin the answer. It matters
  -- most where detection is weakest -- a given bit time cannot be corrupted by noise, the fit never runs.
  if sdec.res == nil or sdec.baud == nil then
    sdec.lasterr = 'nothing detected yet -- capture first'
    sdec.ui_refresh()
    return false
  end
  -- The snapped rate WHEN IT SNAPPED, since that is what a device actually runs: locking a measured 9611
  -- walks the sampling point into the next cell, which a 10-bit frame accumulates worst. Through
  -- baud_round, because sdec.baud is standard only when snapped, and whole, because baud_text uses %d.
  sdec.force_baud  = math.floor(sdec.baud_round(sdec.baud) + 0.5)
  sdec.force_nbits = sdec.res.nbits
  sdec.force_par   = sdec.res.par
  sdec.force_nstop = sdec.res.nstop
  sdec.force_invert = sdec.res.invert
  -- Every forced field is now the operator's: they pressed Lock Detected over these values.
  sdec.autolock_set = nil
  -- The BAUD cell reads sdec.baud, so without this it draws '16099?' beside a padlock holding 16100.
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.force_baud, true, true
  sdec.options_seed()
  ulog.fmt('locked: baud=%s bits=%s par=%s inv=%s', tostring(sdec.force_baud),
           tostring(sdec.force_nbits), tostring(sdec.force_par),
           tostring(sdec.force_invert))
  return true
end

-- Read every options field back, apply it, return to the main screen and capture.
function sdec.options_apply()
  -- A partial read must not be applied as a whole configuration: without one pcall around every field, a
  -- getvalue that raises on Data Bits leaves the new rate with the old width and reports success.
  local readok, readerr = pcall(function()
    -- Every field below is now the operator's, so none of it is autolock's to take back.
    sdec.autolock_set = nil
    local b = display.getvalue(sdec.opt_baud)
    -- Rounded to a whole Bd, because decode_from sets snapped = true for any forced rate and the snapped
    -- display branches use %d. One of three sources that need it: autolock's is integral by construction
    -- and MIDI is a literal, but lock_toggle and options_lock copy sdec.baud with no snapped test.
    if type(b) == 'number' and b >= 110 then sdec.force_baud = math.floor(b + 0.5)
    else
      -- Baud Rate 0 IS the request for auto-detect, so defer auto-lock for one capture.
      if sdec.force_baud ~= nil then sdec.autolock_defer() end
      sdec.force_baud = nil
    end

    local bi = display.getvalue(sdec.opt_bits)
    sdec.force_nbits = sdec.opt_pick(sdec.opt_bits_v, bi)
    -- Entry 2 widens the automatic search to 5, 6 and 9 data bits; a forced width skips the search.
    sdec.widths_any = (type(bi) == 'number' and math.floor(bi + 0.5) == 2)
    -- Parity is applied on its own, with the width left automatic: the search narrows to the forced
    -- parity, so Even on a 7E1 line finds 7E1, where pinning the width to 8 would have forced 8E1.
    sdec.force_par   = sdec.opt_pick(sdec.opt_par_v, display.getvalue(sdec.opt_par))

    local li = display.getvalue(sdec.opt_pol)
    if li == 2 then sdec.force_invert = false
    elseif li == 3 then sdec.force_invert = true
    else sdec.force_invert = nil end

    local ti = display.getvalue(sdec.opt_trig)
    sdec.trigmode = sdec.opt_pick(sdec.opt_trig_v, ti) or 'edge'
    -- Both rear-BNC booleans come from one index, with a fallback to entry 1 -- both off.
    local ri = sdec.opt_rear_v[display.getvalue(sdec.opt_ext)] or sdec.opt_rear_v[1]
    sdec.trigext, sdec.fc_out = ri[1], ri[2]

    -- The two arm fields, taken only when they read as numbers: anything else must leave the previous
    -- setting rather than put nil into a comparison against a voltage, and there is no "0 means auto"
    -- here. Not clamped: arm_level_v() and arm_wait_s() clamp at use, so the form shows what was typed.
    local av = display.getvalue(sdec.opt_armv)
    if type(av) == 'number' then sdec.armlevel = av end
    local aw = display.getvalue(sdec.opt_armw)
    if type(aw) == 'number' then sdec.armwait = aw end
  end)
  if not readok then
    -- And this is what makes that message true: the reads above assign as they go, so a raise on Data Bits
    -- has already committed Baud. options_save() has snapshotted, so this is Cancel's unwind.
    sdec.options_restore()
    sdec.lasterr = 'Options could not be read in full -- nothing was changed (' ..
                   tostring(readerr) .. ')'
    ulog.line(sdec.lasterr)
    pcall(display.changescreen, sdec.ui_scr)
    -- The form suspended the tick on the way in, so every way out re-arms it, including this refusal.
    sdec.ui_tick_on()
    sdec.ui_refresh()
    return false
  end

  -- Protocol LAST, because it overrides the wire fields read above.
  local was = sdec.proto or 'uart'
  -- Only when the field exists: with one protocol available sdec.proto stays 'uart'.
  if sdec.opt_proto ~= nil then
    pcall(function()
      sdec.proto = sdec.opt_pick(sdec.opt_proto_list(),
                                 display.getvalue(sdec.opt_proto))
                or 'uart'
    end)
  end
  -- MIDI is the only protocol that pins a BAUD RATE, so it is the only one whose rate must be dropped when
  -- the protocol changes: the form still SHOWS 31250, which would carry MIDI's rate onto a LIN bus.
  if sdec.proto ~= was and was == 'midi' then
    sdec.force_baud = nil
    sdec.autolock_defer()
  end

  if sdec.proto == 'midi' then
    -- 31250 8N1 is the MIDI 1.0 specification, so forcing it beats auto-detection outright.
    sdec.force_baud, sdec.force_nbits = 31250, 8
    sdec.force_par, sdec.force_nstop = sdec.PAR_NONE, 1
    -- A specification is not autolock's guess: insurance against stale provenance becoming live.
    sdec.autolock_set = nil
    sdec.ui_mode = 'midi'
  elseif sdec.proto == 'lin' then
    -- LIN is 8N1, idle recessive, by specification, and a LIN capture is full of framing errors from its
    -- break fields -- the worst input for a format search. The BAUD RATE is a RANGE, so nothing to pin.
    sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
    sdec.force_invert = false
    sdec.ui_mode = 'lin'
  elseif was ~= 'uart' then
    -- Leaving a protocol hands the wire back to the auto-detector, which the form cannot do by itself: it
    -- still SHOWS the pinned values, so reading the fields back would keep them forced.
    sdec.unlock_all()
    sdec.autolock_defer()
    if sdec.ui_view() ~= nil and sdec.ui_view().res ~= nil then sdec.ui_mode = 'text' end
  end

  ulog.line(string.format('options: proto=%s baud=%s bits=%s any=%s par=%s inv=%s trig=%s',
            tostring(sdec.proto),
            tostring(sdec.force_baud), tostring(sdec.force_nbits),
            tostring(sdec.widths_any),
            tostring(sdec.force_par), tostring(sdec.force_invert),
            tostring(sdec.trigmode)))

  pcall(display.changescreen, sdec.ui_scr)
  -- Re-armed here rather than left to sdec.capture(), which happens to leave it on: that is a side effect
  -- of another function, not a statement that this screen is done with it.
  sdec.ui_tick_on()
  -- Apply means "use these now": capture rather than requiring a second press.
  return sdec.capture()
end

-- Leave the options screen without applying anything.
function sdec.options_cancel()
  -- Put back what was in effect when the screen opened: Lock Detected writes the forced settings
  -- immediately, so Cancel would otherwise leave the configuration it was pressed to abandon.
  sdec.options_restore()
  sdec.options_seed()
  sdec.ui_refresh()
  local ok = pcall(display.changescreen, sdec.ui_scr)
  -- After the switch, and unconditionally: the tick belongs to the main screen, and a refused switch leaves
  -- the operator on a form whose Cancel has already restored the settings.
  sdec.ui_tick_on()
  return ok
end

-- ============================================================================
-- Lifecycle
-- ============================================================================
-- Hook End App on screen scr, so leaving the app tears it down. Returns whether the hook took.
function sdec.install_cleanup(scr)
  local ok = pcall(display.setevent, scr, display.EVENT_ENDAPP, 'sdec.guard(sdec.cleanup)')
  if not ok then
    -- Sticky, not lasterr: a later capture would clear lasterr, and this fault must outlive it.
    sdec.stickyerr = 'End App is not hooked -- exiting will not clean up'
    ulog.line(sdec.stickyerr)
  end
  return ok
end

-- Tear the app down: release the job, stop the hardware, delete objects, close the log.
--
-- Never raises for any measured failure, so every caller calls it bare; ulog.line and ulog.close can raise
-- on a key that is present and refusing, which is unmeasured. Each firmware touch below carries its own
-- guard. It is also the End App event string, through sdec.cleanup(), where a raise reaches the FIRMWARE.
function sdec.stop()
  -- The tick goes first: one can already be queued, and it would repaint deleted buttons.
  sdec.ui_tick_off()
  -- Order matters: release the decode job and stop the hardware BEFORE the buffer goes. A live ck_job owns
  -- an open handle, and a running recording is a model writing into sdec.buf -- deleting it under either
  -- is the create-over-a-live-object hazard.
  if sdec.ck_job ~= nil then sdec.decode_abandon() end
  if sdec.strm_recording then
    sdec.strm_recording = nil
    sdec.stream_settle()
  end
  sdec.ck_running, sdec.ck_stop = false, false
  pcall(trigger.model.abort)
  -- Only while the digitizer is the selected function (sdec.digitizing): the attribute does not exist while
  -- a basic function is selected, and writing it then posts 2800 as a modal box. Reachable on every exit
  -- that followed no capture, which is common because hw_config() selects the digitizer per capture.
  if sdec.digitizing() and sdec.atrig ~= nil then
    sdec.atrig.mode = sdec.k.MODE_OFF
  end
  -- Release the cancel latch: an app that configures a subsystem should un-configure it. cancel_ok goes
  -- with it, so a poll after teardown answers false rather than reading a released blender.
  sdec.cancel_ok = false
  -- The right variable: cancel_blender is a load-time constant, so testing it is vacuous -- the supported
  -- configuration is a firmware with no blenders at all, where indexing it aborted teardown and left 133
  -- display objects live.
  local bl = trigger.blender
  if bl ~= nil and bl[sdec.cancel_blender] ~= nil then
    pcall(bl[sdec.cancel_blender].reset)
  end
  sdec.destroy_options()
  sdec.ui_destroy()
  -- Settle before deleting, and keep the handle if the delete is refused -- the same discipline
  -- acq_make_buffer() uses. The abort above does not WAIT, so the model can still own the buffer and
  -- deleting it then posts 4915; a refused deletion must not report success, or delfails stays 0 and
  -- nothing says a power cycle is needed; and the handle is the ONLY one, so dropping it strands the
  -- buffer and the next acquisition allocates another on top. Keeping it makes the retry possible.
  if sdec.buf ~= nil then
    sdec.trig_settle()
    local b = sdec.buf
    local delok = pcall(buffer.delete, b)
    if delok then
      sdec.buf = nil
    else
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'the capture buffer could not be freed -- power cycle the instrument'
    end
  end
  -- The capacities go back after the capture buffer is freed and not before: until that delete the room to
  -- grow them does not exist. Only the sizes -- the readings the resize discarded are gone.
  local restored = sdec.buf_restore()
  if restored ~= nil then ulog.line('default buffer capacities: ' .. restored) end
  sdec.smp, sdec.nread = nil, 0
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.ei, sdec.es, sdec.ne = nil, nil, 0
  sdec.w, sdec.nw = nil, 0
  sdec.ui_rowc = nil
  -- Last, and after the samples are gone: selecting a basic function takes the digitizer out of the signal
  -- path, and the abort and the delete must not find the mode changed under them. Before ulog.close().
  if not sdec.mode_restore() then
    ulog.line('entry mode could not be restored -- the digitize function is still selected')
  end
  ulog.close()
  return true
end

-- End App handler: stop the app and hand the screen back to the instrument.
function sdec.cleanup()
  local r = sdec.stop()
  -- Teardown has just dropped every object handle and the capture buffer. Collecting costs 8.3 ms.
  pcall(collectgarbage)
  return r
end

-- Entry point: open the log, build the UI, and hook End App. Takes NO capture -- the app comes up idle.
-- THE BUILD is under pcall; cleanup(), del_orphans() and stop() on the failure path are not, and there is
-- no guard above launch. Returns false and a reason if a rebuild is refused or the build fails.
function sdec.start()
  -- The recording ceiling is decided first, before the rebuild guard tears anything down: a launch that
  -- cannot size the smallest recording has nothing worth building, and refusing from here leaves built and
  -- the screen as they were. Once per launch, because the capacities are a session property; a later
  -- resize is caught by stream_begin's refusal.
  --
  -- It returns to the caller rather than putting anything on the glass, because this app is driven headless
  -- over the socket and a refusal that waited for a press would stop an unattended run. The room is taken
  -- in order of whose it is -- foreign buffers, then defbuffer2, then defbuffer1 -- and both steps discard
  -- readings, so both are logged. ck_relaunching is cleared here so a raise in the teardown below cannot
  -- leave it standing and skip handing the capacities back at a later real exit.
  sdec.ck_relaunching = nil
  local swept, sweptwhat = sdec.buf_sweep()
  local reclaimed, reclaimwhat = sdec.buf_reclaim()
  -- Held rather than logged here: there is no app log open yet, and ulog.line() would RESUME onto ulog.path
  -- rather than sdec.logpath -- a file this app never writes again.
  sdec.ck_swept, sdec.ck_sweptwhat = swept, sweptwhat
  sdec.ck_reclaimwhat = nil
  if reclaimed then sdec.ck_reclaimwhat = reclaimwhat end
  sdec.ck_bufmax, sdec.ck_bigbuf, sdec.ck_bigcap = sdec.bufmax_for()
  if sdec.ck_bufmax < sdec.ck_bufmin then
    -- Reachable only where the reclaim could not help, which on the measured pool means a meter that
    -- refused the writes or will not report its sizes. So the message names what it tried.
    local why = string.format('%d readings left for a recording and the smallest mode needs %d: '
                              .. '%s holds %d of the %d the instrument has, and resizing the '
                              .. 'default buffers back to %d %s.',
                              sdec.ck_bufmax, sdec.ck_bufmin,
                              sdec.ck_bigbuf or 'a default buffer',
                              sdec.ck_bigcap or 0, sdec.ck_bufpool, sdec.ck_defbufcap,
                              reclaimed and 'did not free enough' or 'was refused')
    -- And give back what the reclaim took, because this launch is not happening: stop() is the only other
    -- caller of buf_restore and never runs here, so a refused launch shrank a buffer and left it down for
    -- good. The swept buffers cannot come back, which is the intended trade.
    local back = sdec.buf_restore()
    if back ~= nil then ulog.line('launch refused, so capacities handed back: ' .. back) end
    sdec.lasterr = why
    ulog.line('start refused: ' .. why)
    return false, why
  end
  -- One build per power cycle unless the teardown was clean, and this is where a second one is refused: a
  -- second ui_build() over live objects crashes the firmware hard enough to need the front-panel POWER
  -- button, which costs a reboot and a reinstall. Remote recovery is thin -- POWER is a soft button and the
  -- LXI panel says "You cannot switch the instrument on or off with the power switch" -- so a smart plug
  -- can switch the meter off but probably not on.
  --
  -- What makes a rebuild safe is the TEARDOWN: cleanup() deletes every object it created, nils the handles
  -- and collects, so nothing is left to create over. delfails counts refused deletions, and non-zero means
  -- objects have leaked, so that and only that is what refuses. allow_rebuild overrides it, opt-in.
  if sdec.built then
    -- And the default buffers stay reclaimed across it, because a relaunch is not an exit: the ceiling was
    -- derived above from the reclaimed sizes, so growing them back underneath it leaves every later
    -- decision against memory that is not there. docs/MEASUREMENTS.md, 'Buffer capacities across a relaunch'.
    sdec.ck_relaunching = true
    sdec.cleanup()
    sdec.ck_relaunching = nil
    -- Retry anything a previous teardown could not delete BEFORE counting failures: it is reclaimable.
    local left = 0
    left = sdec.del_orphans()
    if left < 1 then sdec.delfails = 0 end
    local nfail = sdec.delfails or 0
    if nfail > 0 and not sdec.allow_rebuild then
      local why = string.format('teardown left %d object(s) undeleted -- rebuilding over leaked '
                                .. 'handles risks a firmware panic. Power cycle, or set '
                                .. 'sdec.allow_rebuild = true to override.', nfail or 0)
      sdec.lasterr = why
      ulog.line('start refused: ' .. why)
      return false, why
    end
    ulog.line('rebuilding: previous UI torn down cleanly')
  end
  -- Set before ui_build(): a build that fails halfway is the dangerous state, so it counts as an attempt.
  sdec.built = true

  local ok, err = pcall(function()
    ulog.tag = 'SDEC'
    -- Once, here, and not per write: confirming the directory reads the whole 64 kB FAT table.
    ulog.ensuredir()
    ulog.open(sdec.logpath)

    -- What the launch took, first because it happened first and because it is the destructive half: these
    -- two lines are the only record the operator has that what went was theirs.
    if (sdec.ck_swept or 0) > 0 then
      ulog.line(string.format('swept %d readings of buffers this app did not make: %s',
                              sdec.ck_swept, tostring(sdec.ck_sweptwhat)))
    end
    if sdec.ck_reclaimwhat ~= nil then
      ulog.line('reclaimed ' .. sdec.ck_reclaimwhat
                .. ' -- the resize discarded the readings those buffers held')
    end

    -- The derived ceiling, logged because a short recording is otherwise unexplainable after the fact: it
    -- follows from a capacity set in another screen, and this line connects the two.
    if sdec.ck_bigbuf == nil then
      ulog.line(string.format('recording ceiling: %d readings -- the default buffer capacities '
                              .. 'could not be read, so this is the static ceiling',
                              sdec.ck_bufmax))
    else
      ulog.line(string.format('recording ceiling: %d readings of %d, %s at %d, margin %d',
                              sdec.ck_bufmax, sdec.ck_bufpool, sdec.ck_bigbuf,
                              sdec.ck_bigcap, sdec.ck_bufmargin))
    end

    -- Before anything touches the digitizer, and after the rebuild guard: on a rebuild that guard runs
    -- cleanup(), which restores the entry mode, so this reads the operator's and not ours.
    if sdec.mode_save() then
      ulog.line('entry mode: ' .. tostring(sdec.entrymode.side) .. ' '
                .. tostring(sdec.entrymode.func) .. ' -- restored on exit')
    else
      ulog.line('entry mode could not be read -- exiting will leave the digitize function selected')
    end

    -- Every detection setting back to automatic, BEFORE the options screen is built from them: `sdec`
    -- outlives an app run, so a launch would otherwise inherit whatever the last session pinned, with the
    -- padlock showing it. Logged, because this is the app overriding something the operator set.
    sdec.reset_options()
    ulog.line('options reset: proto uart, FRAME mode, text view, baud auto, bits auto 7/8, '
              .. 'parity auto, polarity auto, trigger Start bit, rear BNC off')

    -- The cancel key, wired once: every long job polls the latch this arms, so it is set up before the
    -- first capture and never re-armed per run.
    sdec.cancel_setup()
    sdec.ui_build(true)   -- hold the loading screen: build_options() is still to come
    -- Hook End App as soon as a screen exists, before anything that could fail.
    sdec.install_cleanup(sdec.ui_scr)
    sdec.build_options()

    -- Main screen in front, then the loading screen away: deleting the displayed screen blanks the panel.
    sdec.ui_loading_clear(sdec.ui_scr)
    sdec.ui_status = 'ready -- press Capture'
    sdec.ui_refresh()
  end)

  if not ok then
    sdec.lasterr = tostring(err)
    -- The USB log is the only place this can be read: a failed build has no note row to put it on.
    ulog.line('start failed: ' .. sdec.lasterr)
    sdec.stop()
    -- `built` was set BEFORE the build, so a failure has to retract it or it claims a UI that is not there.
    sdec.built = false
    return false, err
  end

  -- The app comes up idle and measures nothing: the first acquisition is the operator's first press, so
  -- start() returns with the digitizer untouched and sdec.res nil.
  --
  -- DO NOT PUT A CAPTURE HERE. On firmware 1.7.17a a capture taken from inside this function bluescreens
  -- the instrument when the app runs from INTERNAL MEMORY, at PC 001CF3C8. What it is, is pcall DEPTH:
  -- this path sits one layer below a firmware stack limit, and it is the PEAK depth reached anywhere
  -- during the capture, not the depth of the chain on the way in -- flattening the chain did not fix it,
  -- and taking the app from 227 pcall calls to 132 did. docs/MEASUREMENTS.md, 'The launch capture and the
  -- pcall budget'.
  --
  -- So the pcall budget is a shipping constraint and the margin is unknown: the boundary is somewhere
  -- between 132 and 191. Guards belong at a FIRMWARE BOUNDARY, never around a call into our own code,
  -- which is what the count is made of. tools/harden_formats.py exists because removing a guard exposes
  -- any nil it was hiding. No size threshold explains it, so making the app smaller buys no headroom.
  return true
end

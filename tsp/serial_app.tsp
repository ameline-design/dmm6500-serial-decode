-- serial_app.tsp -- lifecycle, touch handlers and capture orchestration for the Keithley TSP
-- serial decoder (TSP / Lua 5.0.2). Needs a digitizer reachable as dmm.digitize, the touchscreen app
-- API and Lua 5.0.2. Only the DMM6500 has been tested; docs/PROJECT.md has the per-model verdicts.
--
-- Object lifetime, throughout: delete, nil, then create. Creating over a live handle strands the
-- object beneath it until a power cycle, and that accumulation walks this firmware toward a
-- PC=002F751C panic. sdec.delfails counts refused deletions.
--
-- Decoding is single-shot, so there is no frame timer: display writes happen on a button press.
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
-- Migrated, not just defaulted: `or` would keep a previous load's path to the key's root.
if sdec.logpath == '/usb1/serial_decode_log.txt' then
  sdec.logpath = sdec.usbdir .. '/serial_decode_log.txt'
end
if sdec.flogpfx == '/usb1/bytes' then sdec.flogpfx = sdec.usbdir .. '/bytes' end
if sdec.savepfx == '/usb1/serial_' then sdec.savepfx = sdec.usbdir .. '/serial_' end
sdec.saveext   = sdec.saveext or '.txt'
-- Protocol layer over the UART bytes: 'uart', 'midi' or 'lin'. Operator state, so `or` like the rest.
sdec.proto     = sdec.proto or 'uart'
-- Press-driven streaming, which the panel does not use: true = Capture starts a recording, stops it,
-- then steps the decode a slice per press. false ships and does the whole job in one press, which no
-- finger can stop. A nil test, because `false or true` is true.
if sdec.strm_press == nil then sdec.strm_press = false end
-- Wall-clock ceiling on one streaming acquisition, seconds; nil means no bound. A backstop, set where
-- stream_maxwait already caps, because two bounds that disagree make the smaller a hidden cap.
sdec.strm_maxsec = sdec.strm_maxsec or 1200
-- Seconds of signal the blocking fallback may record. Short, because nothing can poll it.
sdec.strm_fallback_s = sdec.strm_fallback_s or 20
-- Fraction of extra samples a recording asks for. Every pause the line takes is recorded in full, and
-- those samples come out of the same count the payload does -- so without this the
-- bytes lost are the ones at the end of the mode's budget. The decoder already skips idle, so the
-- over-read buys payload and not correctness. Free on a 6 000 000-reading record, where a 21 100-reading
-- one had nowhere to put it. EVERY capture, not a subset: sdec.acquire() applies it, and the
-- declaration said 'elide path only' for long enough that the claim outlived the path.
sdec.strm_overread = sdec.strm_overread or 0.10
-- The most the Options field will offer. A ceiling and not a limit on what is sensible: the over-read
-- buys payload against the samples a refused gap costs, and a gap vector spends at most a third of a
-- pass on gaps it declined, so half again is past anything the feature can use. The field needs a
-- maximum of some kind -- OBJ_EDIT_NUMBER takes one -- and an unbounded one lets a typo ask for a
-- capture the mode cannot size.
sdec.overread_max = sdec.overread_max or 0.50
-- sdec.savedas  -- the last filename written, for the note line
-- sdec.stickyerr -- a fault that must outlive a capture (see install_cleanup)

-- Drop a decode result a later pass has invalidated, and nothing else. Returns true.
--
-- A pass failing at acquire() returns before any decode, so the previous pass's result survives beside
-- the failed capture's rate. docs/MEASUREMENTS.md, 'A failed re-capture leaves a stale fit'. Not
-- clear_result(), whose probe_note and lasterr are the only record of what failed here.
function sdec.drop_stale_result()
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
  sdec.snapped, sdec.fitq, sdec.snapfirm = false, 0, true
  sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
  return true
end

function sdec.clear_result()
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
  sdec.clear_measured()
  -- The main eviction point for the note cell: per-capture sources go together, so none can latch.
  sdec.mode_exited, sdec.lognote, sdec.autolocknote = nil, nil, nil
  sdec.mode_exitbad = false
  sdec.strm_releveled, sdec.proto_why = nil, nil
  -- relocked is the exception: its note must survive to the end of the press, so capture() clears it.
  sdec.probe_note = nil                 -- set by autoset() when it had to re-capture slower
  -- The previous capture's 20 000-entry sample table is now unreachable. 8.3 ms against a 1.6 s capture.
  pcall(collectgarbage)
  return true
end

-- Drop the whole lock -- every forced setting, not just the rate. Returns true. All five or none:
-- clearing force_baud alone leaves the format pinned, because autolock_try() sets nbits, par and nstop
-- with the rate, and the app then decides the format from the previous capture's answer.
function sdec.unlock_all()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  -- The provenance goes with the lock it describes, or the next back-off clears what was typed.
  sdec.autolock_set = nil
  return true
end

-- Everything the app and the decoder learned, back to a known value, before any attempt to determine
-- a baud rate or decode. Returns true. Called once per press at the top of capture().
--
-- What it adds over clear_result() plus clear_measured() is the requested sample rate, which they must
-- not touch. docs/MEASUREMENTS.md, 'fs_want: the second pass of autoset'. It does not unlock: a forced
-- rate is the operator's, and a harness that wants a virgin app calls sdec.unlock_all() first.
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
-- transitions and the trigger mode is one that waits. Returns ok, reason.
--
-- No second pass and no octave retry, unlike the tail of autoset(): a re-capture is more data everywhere
-- else and strictly less here, because the opening bytes exist only in the window that caught them.
function sdec.arm_capture()
  local fs = sdec.arm_fs()
  -- fs_want as well as fs: fs_select() resets to fs_default when nothing is locked, and nothing is here.
  sdec.fs, sdec.fs_want = fs, fs
  sdec.probe_note = string.format(
    'armed at %g kS/s on a line that has not started -- lock the baud rate for a longer window',
    fs / 1000)
  local ok, why = sdec.acquire()
  -- Before any decode, so a failed arm cannot leave the probe's fit beside this capture's rate.
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  if dok then return true end
  if sdec.arm_fit_prior() then return true end
  sdec.drop_stale_result()
  return false, dwhy
end

-- Is this candidate bit time compatible with the pulses actually on the wire? The filter the prior
-- ladder applies before spending a decode. docs/MEASUREMENTS.md, 'The prior ladder needs the
-- pulse-width filter'. It fails closed with no evidence, so sig_bittime() must run first.
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
-- relock_badfrac, which asks a different question. docs/MEASUREMENTS.md, 'arm_badfrac = 0.02'.
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
-- capture caught the device's first bytes and no bit time could be measured. Returns whether exactly
-- one of sdec.arm_try frames those samples cleanly.
--
-- Uniqueness, not the first fit, because clean frames at a wrong rate are the normal outcome:
-- docs/MEASUREMENTS.md, 'Uniqueness, not first fit, for a guessed rate'. decode_from(), not decode(),
-- whose fallback measurement already failed.
function sdec.arm_fit_prior()
  local rd, n = sdec.smp, sdec.nread
  if rd == nil or n == nil or n < 2 then return false end
  local fs = sdec.acq_fs or sdec.fs
  if fs == nil or fs <= 0 then return false end
  -- The widths are this function's evidence, so it measures them itself; the return value is ignored.
  sdec.sig_bittime()
  local was, won, alt = sdec.force_baud, nil, nil
  -- Wrapped, because decode_from can raise and both restores sit after the call. Around the LOOP.
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
    -- Ambiguity is an answer: it names the two rates the capture cannot tell apart.
    sdec.probe_note = string.format(
      'this capture fits %d Bd AND %d Bd equally -- lock the rate in Options to decide', won, alt)
    return false
  end
  -- Re-decoded at the winner: the loop left sdec.res holding whichever candidate it tried last.
  sdec.force_baud = won
  local ok = false
  pcall(function() ok = sdec.decode_from(rd, n) end)
  sdec.force_baud = was
  if not ok then return false end
  sdec.probe_note = string.format(
    'no bit time could be measured -- decoded at an ASSUMED %d Bd; lock the rate to be sure', won)
  return true
end

-- Pick the sample rate, capture, and decode. Returns ok, reason.
function sdec.autoset()
  local target = sdec.force_baud
  local captured = false
  -- Per call: giveup() sets baud_probe for one call, but an acquisition failure never reaches it.
  sdec.baud_probe = nil

  -- Two passes: docs/MEASUREMENTS.md, 'fs_want: the second pass of autoset'.
  if target == nil then
    sdec.fs = sdec.rates[table.getn(sdec.rates)]      -- top rate: 1 MS/s
    -- Free-running whatever the operator selected, and retried: arming a model here posts 4915 ten times
    -- a capture. docs/MEASUREMENTS.md, 'Event 4915 on the probe pass'.
    local savetrig = sdec.trigmode
    sdec.trigmode = 'free'
    local ok, why, tries = false, nil, 0
    -- Each retry looks for longer by dropping the rate: 20 ms, 200 ms, 2 s for the same 20 000 samples.
    local ladder = sdec.probe_fs or {1000000, 100000, 10000}
    local nlad = table.getn(ladder)
    -- Registered for the boundary: sdec.guard can see a field, where savetrig is a local it cannot.
    sdec.trig_restore = savetrig
    -- The restore runs on the raising path too, and sdec.unwind() is not enough cover for it. A host
    -- tool that pcalls sdec.capture() itself never reaches the firmware boundary, so a raise in this
    -- loop would leave trig_restore set -- and acquire() now reads that field to keep its free-run
    -- fall-through out of the ladder, so a leaked marker silently disables gap elision for every later
    -- capture and survives an app reload. The symptom would read as 'the fix did not take'. Caught and
    -- re-raised here rather than left to a catcher that may not exist; level 0 so the re-raise does not
    -- staple a second position onto the message.
    local lok, lerr = pcall(function()
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
    sdec.trig_restore = nil
    if not lok then error(lerr, 0) end
    if tries > 1 then
      sdec.probe_note = string.format(
        'probe took %d looks to catch traffic (down to %g kS/s)', tries or 0, ladder[tries] / 1000)
    end
    if not ok then
      -- A measured bit time that frames no byte is not a failure: 20 ms at 1 MS/s is six bit times at
      -- 300 baud. docs/MEASUREMENTS.md, 'The probe ladder and the octave retry'.
      if sdec.baud_probe == nil then
        -- A line that has not started is the armed case, not a probe failure, and arm_silent() refuses
        -- where nothing waits. docs/MEASUREMENTS.md, 'Arming from silence needed a locked rate to reach'.
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
    if target == nil then return true end
  end

  local want = sdec.pick_fs(target, 8)
  -- `captured`, not `sdec.res ~= nil`: a leftover result lets a forced rate perform zero reads.
  if captured and want >= sdec.fs then return true end

  sdec.fs = want
  sdec.fs_want = want
  -- A bare call: this path carries ONE pcall and it is sdec.capture()'s. See the depth note in start().
  local ok, why = sdec.acquire()
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  -- The probe can fit a SUB-multiple, and then the rate it asks for is too slow to frame anything.
  -- pick_fs(120, 8) is 1000 S/s, where a 300 baud bit is 3.3 samples -- under sdec.minsabit -- so this
  -- pass refuses with the wire's own rate in its message and decode_from() retracts that rate into
  -- baud_probe. Returning the refusal threw the answer away: the smoke's r06@300 'no bytes decoded' at
  -- fs 1000 against the 2500 the cell wanted. Measured over 40 capture phases of a 300 Bd 7E1 line, 4
  -- fitted 50, 60, 100 or 120 Bd on the probe and all 4 carried baud_probe = 300.
  --
  -- The retry below is the same correction in the other direction and neither covers the other: that
  -- one runs after a SUCCESSFUL decode and reads sdec.baud, where a rate too slow to frame leaves no
  -- result to read. One attempt either way -- pick_fs is monotonic in baud, so w3 > sdec.fs cannot
  -- come back to this rate.
  if not dok and sdec.baud_probe ~= nil and sdec.baud_probe > 0 then
    local w3 = sdec.pick_fs(sdec.baud_probe, 8)
    if w3 ~= nil and w3 > sdec.fs then
      sdec.probe_note = string.format(
        'probe fitted %.0f Bd, wire is %.0f -- re-captured at %g kS/s to get samples per bit',
        target or 0, sdec.baud_probe or 0, w3 / 1000)
      sdec.fs, sdec.fs_want = w3, w3
      local ok3, why3 = sdec.acquire()
      if not ok3 then sdec.drop_stale_result() return false, why3 end
      dok, dwhy = sdec.decode()
    end
  end
  if not dok then sdec.drop_stale_result() return false, dwhy end

  -- An octave-out probe costs half the window. docs/MEASUREMENTS.md, 'The probe ladder and the octave retry'.
  if sdec.baud ~= nil and sdec.baud > 0 then
    local w2 = sdec.pick_fs(sdec.baud, 8)
    if w2 ~= nil and w2 < sdec.fs then
      sdec.probe_note = string.format(
        'probe fitted %.0f Bd, wire is %.0f -- re-captured at %g kS/s for the full window',
        target or 0, sdec.baud or 0, w2 / 1000)
      sdec.fs, sdec.fs_want = w2, w2
      local ok2, why2 = sdec.acquire()
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
-- One file, shared by every mode, and separate from the debug log, which is a trace of notes and
-- refusals. The name is chosen once per session, so successive captures append to one file. Decoded
-- bytes only, never samples -- a 32 kB stream is 3.4 M samples, ~34 MB of text against 32 kB.
-- ============================================================================
--
-- Allocate the byte log's filename. Returns the path, or nil with sdec.flog_why set.
function sdec.flog_alloc()
  -- A different key needs a different name, or MODE_APPEND extends a stranger's file. The ask comes
  -- first, or the guard cannot fire: next_free() below is skipped on the path it exists for.
  ulog.keyok()
  if sdec.flog_keygen ~= (ulog.keygen or 0) then
    sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
    sdec.flog_keygen = ulog.keygen or 0
  end
  if sdec.flog_path ~= nil then return sdec.flog_path end
  -- Lazy: the scan is 1000 fs.is_file probes, and a filename would be burnt per session either way.
  sdec.flog_path = ulog.next_free(sdec.flogpfx, '.txt', 1000)
  if sdec.flog_path == nil then
    -- Name the reason next_free gave; ui_notes already prefixes 'NOT LOGGING: '.
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
  -- open_write, not file.open: it carries the no-key gate and the reason string.
  local fh, fwhy = ulog.open_write(sdec.flog_path, file.MODE_APPEND)
  if fh == nil then
    sdec.flog_why = 'cannot append to ' .. tostring(sdec.flog_path)
    return false
  end
  -- Registered for the unwind: a formatter can raise here, where a file call cannot, measured.
  sdec.fh_unwind = fh
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
  -- The presence check is the whole test: a write that posted 2200 returns normally, so nothing the
  -- writes report can see a key pulled since the open. See ulog.keylost.
  if not ulog.keyok() then
    sdec.flog_why = 'write failed part-way through ' ..
                    string.gsub(tostring(sdec.flog_path), '^.*/', '')
    return false
  end
  sdec.flog_n = msgno
  sdec.flog_bytes = (sdec.flog_bytes or 0) + nfr
  sdec.flog_why = nil
  return true
end

-- ============================================================================
-- Streaming capture
-- ============================================================================
-- Acquire long, then decode window by window straight to a file. A recording is two presses:
-- stream_begin() arms the hardware and returns, stream_stop() stops it and decodes, and between them
-- nothing of ours runs -- so the panel stays live, but the quiet-line watchdog only advances while
-- sdec.stream() is polling. Every entry point here is guarded end to end and returns ok, reason.
-- ============================================================================
--
-- Size a streaming capture, allocate its buffer, learn the levels and arm the idle watchdog.
function sdec.stream_begin()
  local md = sdec.mode_cur()
  local why = sdec.mode_why(md)
  if why ~= nil then return false, why end
  -- Same degrade-rather-than-raise rule the protocol modules follow: chunk_decode.tsp may be absent.
  if sdec.ck_run == nil then
    return false, 'this build omits chunk_decode.tsp -- the streaming modes need it'
  end

  sdec.hw_config()                      -- picks fs from the locked baud rate
  local fs = sdec.fs
  local nsmp = sdec.stream_samples(md, fs)
  if nsmp == nil then return false, 'cannot size the capture for this rate' end

  -- The capacity is sized for the over-read, not for the bare count, or the Over-read field is a
  -- no-op on this path. stream_acquire raises its target by sdec.strm_overread and then clamps it with
  -- acq_fit(), which takes the buffer's own room -- so against a buffer sized to nsmp the extra is
  -- clamped straight back off and the setting does nothing an operator could see. Sized here instead,
  -- while strm_nsmp stays the bare request: the two are different numbers and stream_acquire publishes
  -- both (sdec.strm_target is the one it ran to).
  --
  -- Every recording, for stream_acquire's reason: the margin is orthogonal to elision, and the capture
  -- that elides nothing is the one with the most idle to absorb.
  local sizefor = nsmp
  if (sdec.strm_overread or 0) > 0 then
    sizefor = math.ceil(nsmp * (1 + sdec.strm_overread))
  end
  -- Headroom, as acq_cap() adds in a triggered mode and this path adds always: a store past capacity
  -- is 4915, 20-30 a capture.
  local cap = sizefor + 100
  -- Trigger mode alone, not arm_silent(): the silence probe reads into this buffer. The reserve comes
  -- out of capacity here, nsmp*100/(100-pretrig), where acq_cap() puts it on top of the count.
  if sdec.trigmode ~= 'free' and (sdec.pretrig or 0) > 0 then
    cap = math.ceil(sizefor * 100 / (100 - sdec.pretrig)) + 100
    -- Overrunning ck_bufmax would turn the largest modes into an allocation refusal, a worse answer.
    -- nsmp comes back off the capacity and not off sizefor: what the clamp leaves is the whole room,
    -- and the over-read is taken out of it again by stream_acquire.
    if sdec.ck_bufmax ~= nil and cap > sdec.ck_bufmax then
      cap = sdec.ck_bufmax
      nsmp = math.floor(cap * (100 - sdec.pretrig) / 100)
      if (sdec.strm_overread or 0) > 0 then
        nsmp = math.floor(nsmp / (1 + sdec.strm_overread))
      end
    end
  end
  -- This can need a default buffer shrunk first: docs/UNDOCUMENTED.md, 'The real ceiling is
  -- 7,080,255 readings, across all buffers together'. Bare -- acq_make_buffer() guards it.
  --
  -- Sized to the capture, because this path arms with LoopUntilEvent whose pre-trigger reserve is a
  -- percentage of capacity: against 6 000 000 the smallest reserve it can express is 1 % and 60 000
  -- readings, where the capture wants about a thousand. Dropping the reserve instead costs the head of the
  -- record -- measured offline as three wrong bytes from offset 1 and no leading idle for the level probe.
  -- acq_pospct() is what reconciles the two where a static buffer does serve the capture.
  -- docs/MEASUREMENTS.md, 'The permanent record, and how every mode shares it'.
  sdec.acq_make_buffer(cap)
  -- Reclaim and retry once, because the capacities are the operator's to change mid-session. Once only.
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
    -- Name the buffer that is actually large, re-read here, or the advice fails the allocation again.
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

  -- Learn the levels before the long recording: the watchdog needs a threshold, and capture() zeroed it.
  sdec.ck_watch = false
  -- Bounded in time: read() blocks for pn/fs seconds, so 2000 samples at 110 baud would hold it ~2 s.
  local pn = sdec.probe_n
  if pn > nsmp then pn = nsmp end
  local budget = 0.25 * (sdec.ui_latency_s or 0.5)
  local pmax = math.floor((sdec.fs or 1000) * budget)
  if pmax < 200 then pmax = 200 end
  if pn > pmax then pn = pmax end
  -- nofc: a probe must not spend a credit. probe_idle is cleared because arm_silent() reads it.
  sdec.probe_idle = nil
  -- And the arm pair with it: this path skips clear_measured(), so a stale pair would arm on old levels.
  sdec.arm_thr, sdec.arm_idle = nil, nil
  local pok = pcall(sdec.acq_free, pn, nil, true)
  if pok and sdec.nread ~= nil and sdec.nread > 1 then
    local lok, lwhy = sdec.sig_levels(sdec.smp, sdec.nread)
    -- Only arm the watchdog if the levels are real: a truncated four-minute session is not recoverable.
    if lok and sdec.thr ~= nil and (sdec.swing or 0) >= sdec.minswing then
      sdec.ck_watch = true
    else
      -- A probe that saw no transitions is the arm-from-silence case. Only for a probe that ran: one that
      -- raised is a fault, and arming a 120 s wait on a broken digitizer is not the answer.
      sdec.probe_idle = lwhy or 'line is idle (no transitions)'
    end
  end
  -- The probe found nothing, the normal case under flow control, so the last good levels are reused.
  if not sdec.ck_watch and sdec.lvl_thr ~= nil and
     (sdec.lvl_swing or 0) >= sdec.minswing then
    sdec.thr, sdec.hyst, sdec.swing = sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing
    sdec.ck_watch = true
    sdec.strm_lvlreuse = true
  else
    sdec.strm_lvlreuse = nil
  end
  -- The arm level is computed whatever the reuse did: gated on `not strm_lvlreuse` the comparator ends up
  -- armed at the last decode's midpoint, which is mid-data. The reused threshold is put back.
  if sdec.probe_idle ~= nil then
    local kthr, khyst, kidle = sdec.thr, sdec.hyst, sdec.idle
    if sdec.arm_threshold() and sdec.strm_lvlreuse then
      sdec.thr, sdec.hyst, sdec.idle = kthr, khyst, kidle
    end
  end
  -- The Lua copy goes; the count stays, because a finished run is reported by nread. settle() rewrites it.
  sdec.smp = nil

  -- ck_stop = false on entry is the authoritative clear, or the next run aborts at once.
  sdec.ck_running, sdec.ck_stop, sdec.ck_nbytes, sdec.ck_tot = true, false, 0, nil
  sdec.ck_endwhy = nil
  -- Per run, beside ck_endwhy: a level left by a previous expired arm would be quoted at the next.
  sdec.arm_expired_at = nil
  -- ck_cancel is cleared here, because every run of either shape comes through this function.
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
  -- Flagged, not just reported: a write failure and a quiet device both arrive as false plus a sentence.
  sdec.strm_empty = nil
  -- A raise is not a quiet line: conflated, a faulted digitizer read as the device finishing tidily,
  -- because record_run() rewrites an empty window into fc_end='quiet'. A raise never sets the flag.
  if not aok then
    return false, 'recording failed: ' .. tostring(ares or 'unknown')
  end
  if got < 2 then
    sdec.strm_empty = true
    return false, 'long capture returned nothing'
  end
  -- A cancel stops the recording, not the bytes it collected: ck_progress reads ck_stop as "abort", so
  -- the decode would end at window zero. No cancel_clear(), which would discard a second press.
  if sdec.ck_stop then sdec.ck_stop = false end
  return sdec.stream_decode(got)
end

-- What one press may spend under flow control. The normal ending needs no bound -- a credited window
-- that comes back quiet means the device has finished -- so these are for the device that never stops,
-- and they are the only exits, because cancel_pressed() answers false for ever while a
-- panel-initiated run executes. Two bounds, because the window count alone is not a time.
-- docs/MEASUREMENTS.md, 'fc_maxwin = 32 and fc_maxsec = 1200'.
sdec.fc_maxwin = sdec.fc_maxwin or 32
sdec.fc_maxsec = sdec.fc_maxsec or 1200

-- One press, one whole transmission: record, decode and save, and under flow control keep issuing credits
-- until the device stops. Returns the run's verdict and, on a failure, its reason.
function sdec.record_run()
  -- Discard a latched press before starting: the press that ended the LAST run is still in the latch.
  sdec.cancel_clear()
  -- strm_empty and ck_cancel are cleared here too, because stream_begin() clears them too late.
  sdec.ck_cancel, sdec.fc_end, sdec.strm_empty = nil, nil, nil
  sdec.fc_win, sdec.fc_bytes, sdec.fc_secs = 0, 0, 0
  -- Taking the clock for a run means disarming the absorb, whose age is this same timer.
  sdec.strm_stopped_by_press = nil
  timer.cleartime()
  -- Painted after the clear and before the first window: the last full refresh until the run ends.
  sdec.ui_refresh()
  local keep = nil                 -- the last window that actually decoded something
  local ok, why = false, nil
  while true do
    -- Nil'ed before the window, not tested after it, or the accumulator adds the previous window's bytes
    -- twice. A write failure still counts its bytes: they were decoded, and the note row says so.
    sdec.ck_tot = nil
    ok, why = sdec.stream()
    sdec.fc_win = sdec.fc_win + 1
    sdec.fc_secs = sdec.fc_secs + (sdec.strm_waited or 0)
    if sdec.ck_tot ~= nil then
      sdec.fc_bytes = sdec.fc_bytes + (sdec.ck_tot.nf or 0)
      keep = sdec.ck_tot
    end
    -- One window unless the device is credited: without 'FC Out' a second window is a different conversation.
    if not sdec.fc_out then break end
    -- Who ended the run is settled before why the last window looks empty: an interrupted window is
    -- indistinguishable from the device having finished, and tested second it was rewritten as 'quiet'.
    if sdec.ck_cancel then
      sdec.fc_end = 'cancelled'
      if not ok and sdec.strm_empty and sdec.fc_bytes > 0 then ok, why = true, nil end
      break
    end
    if not ok then
      -- An empty window is how a flow-controlled transmission ends, and strm_empty keeps that narrow.
      if sdec.strm_empty and sdec.fc_bytes > 0 then
        ok, why, sdec.fc_end = true, nil, 'quiet'
      end
      break
    end
    -- Cannot fire from the panel today: only cancel_asked() sets ck_stop here, and it is tested above.
    if sdec.ck_stop then sdec.fc_end = 'stopped'; break end
    if sdec.ck_endwhy == 'quiet' then sdec.fc_end = 'quiet'; break end
    if sdec.fc_win >= (sdec.fc_maxwin or 32) then sdec.fc_end = 'bound'; break end
    -- The larger of the clock and the counter: only the clock sees the decode, only the counter is safe.
    local el = sdec.fc_secs
    local t = timer.gettime()
    if t ~= nil and t > el then el = t end
    if sdec.fc_maxsec ~= nil and sdec.fc_maxsec > 0 and el >= sdec.fc_maxsec then
      sdec.fc_secs = el
      sdec.fc_end = 'timebound'
      break
    end
  end
  -- The tail has to survive an empty last window, which has already wiped the totals that carried bytes.
  if sdec.ck_tot == nil and keep ~= nil then
    sdec.ck_tot, sdec.ck_nbytes = keep, keep.nf
  end
  -- The loop is over, so nothing is running: left true, ck_status() reports 'decoding...' under a finished run.
  sdec.ck_running = false
  return ok, why
end

-- Arm and return, for the press-driven path. The buffer fills in hardware from here.
function sdec.stream_start()
  -- These counters belong to a run and this is the other kind: record_run() clears them at entry and
  -- nothing did here, so a press-driven recording reported a bound it never hit. Not stream_begin().
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = 0, 0, nil, 0
  local ok, why = sdec.stream_begin()
  if not ok then return false, why end
  -- stream_arm's own verdict, not a pcall's: a pcall around it reports a refused configuration as success.
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
  -- The one pcall left around an sdec.* call here, because the raise text is the reason the operator is
  -- given. Not a closure, so the returns arrive as results 2 and 3, and a raise puts the message in 2.
  local sok, s1, s2 = pcall(sdec.stream_settle)
  if sok then got, gerr = s1, s2 end
  sdec.ck_running = false
  -- A settle that failed is not an empty recording: the operator must not be blamed for a hardware fault.
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

  -- The file is optional; the decode is not. Refusing here made both recording modes decode nothing while
  -- frame mode showed bytes from the same wire. A nil path skips the sink and keeps the tail.
  local path = sdec.flog_alloc()
  -- nocap must be explicit: md.cap = nil means unlimited, and Lua cannot tell it from a missing key.
  local opts = {maxbytes = md.cap, nocap = (md.cap == nil),
                progress = sdec.ck_progress}
  -- How much silence the record may open with, which only this path knows. docs/MEASUREMENTS.md,
  -- 'An armed record opens on silence'.
  -- The reserve comes from the position that actually loaded and not from sdec.pretrig, which acq_pospct
-- scales down against the permanent record: a leadmax taken from the unscaled figure would be a
-- 300 000-reading fiction.
  if sdec.strm_armed and sdec.buf ~= nil then
    opts.leadmax = sdec.acq_leadmax(sdec.buf)
  end
  -- A PLAIN READ OF THE RECORD, which is now the only kind. What stood here was the elision splice:
  -- it cleared ten spl_* fields, named which of seven guards refused, put each burst's head back from
  -- its scratch, and handed the framer a seam list to re-lock on. Gap elision is gone -- the handover
  -- hole it existed to paper over is forced by the instrument, notes/HANDOFF-session70.md -- so there
  -- is no splice, no seam list and no head to restore.
  -- LOCAL, AND THAT IS LOAD-BEARING. These were declared inside the splice block that stood above, and
  -- removing it left both as GLOBALS: nrd read nil, ck_run decoded against a nil total, and
  -- tools/test_streamfix.lua caught it as 59 of 60 bytes wrong on a device that starts late.
  local rdr, nrd = sdec.ck_reader_buffer(sdec.buf, got), got
  -- THE TOTAL THE WINDOW LOOP IS GIVEN, and the quantity a short decode has to be judged against.
  -- ck_decode breaks on `off + cnt >= ntotal`, so this is the bound that decides the reach -- and the
  -- 2026-10-19 lap found 15 cells whose decode covered 48-79 % of `ring`, where neither candidate exit
  -- was taken and nothing on the row named the limit.
  sdec.ck_nrd = nrd
  -- Sliced when a panel is waiting, whole when nothing is; the one-shot callers leave budget_s nil.
  if sdec.strm_press then
    -- Work per press and window width are two different budgets: only the width must come from
    -- ui_latency_s. Do not spend those presses in display.waitevent(0): on 1.7.17a it wedges the box.
    opts.budget_s = sdec.ck_press_budget_s or sdec.ui_latency_s
    local W = sdec.ck_win_for(sdec.ui_latency_s)
    -- Globals this path cannot restore, because the decode_step() calls that follow need the narrowed W.
    sdec.ck_win_n, sdec.ck_level_max = W, W
    local job, jerr = sdec.ck_job_new(rdr, nrd, path, opts)
    if job == nil then return false, tostring(jerr or 'cannot start the decode') end
    sdec.ck_job, sdec.ck_job_md = job, md
    sdec.ck_running = true
    return sdec.decode_step()
  end
  -- Close the scope leak at the point of consumption; these are chunk_decode's one-shot values.
  sdec.ck_win_n, sdec.ck_level_max = 20000, nil
  local tot, terr = nil, nil
  local dok = pcall(function()
    tot, terr = sdec.ck_run(rdr, nrd, path, opts)
  end)
  if not dok or tot == nil then
    return false, tostring(terr or 'chunked decode failed')
  end
  -- The buffer ran out before the cap, which is not [done]: pick_fs snaps UP, so 32 kB is ~22.4 kB at 9600.
  if tot.stopped == nil and sdec.ck_endwhy == 'full' and md.cap ~= nil and
     tot.nf < md.cap then
    tot.stopped = 'exhausted'
  end
  sdec.ck_tot = tot
  sdec.ck_nbytes = tot.nf
  -- THE TAIL IS PUBLISHED HERE TOO, as decode_step and sdec.stream() already publish it. Without this
  -- line sdec.res on the one-shot path was whatever ck_prime_step's decode_from left -- the frame-mode
  -- decode of the first ~20 000 spliced samples -- and bench_run.tsp builds nf, hex and pay= from
  -- sdec.res: measured, one 58 590-reading record reported nf=177 against the chunked decode's 520, on
  -- every elided row of every lap. The tail holds the last ck_keep bytes of the stream, which for a
  -- bench record is all of them. sdec.stream() assigns the same value after this returns, so the panel
  -- path is unchanged.
  if tot.tail ~= nil then sdec.res = tot.tail end
  -- Totals come back whether or not the sink worked, so a non-nil table is not the success test.
  if tot.stopped == 'write failed' or tot.stopped == 'sink' then
    return false, string.format('%s -- %d bytes decoded but the file is incomplete',
                                tostring(tot.stopped), tot.nf or 0)
  end
  return true
end

-- Decode one slice, put the progress on the status row, and hand the panel back. Returns the decode's
-- VERDICT, not its progress: true for a pending slice and for a clean finish, false when the step raised,
-- produced no totals or failed its write. Whether work remains is sdec.ck_job ~= nil.
function sdec.decode_step()
  local job = sdec.ck_job
  if job == nil then return false end
  local done, tot, err = true, nil, nil
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
  -- The verdict goes with the reason: the one-shot caller passes both, so strm_exit_why could not fire here.
  local dok = (tot ~= nil and tot.stopped ~= 'write failed' and tot.stopped ~= 'sink')
  sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, dok, sdec.lasterr), not dok)
  sdec.ui_refresh()
  -- dok, not true: on every path true made a raised decode indistinguishable from one that worked.
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

-- Arm the trigger model and return; the buffer fills in hardware from here. nsmp is the reading count
-- SimpleLoop is asked for, and the return says whether the model took the configuration -- false is the
-- caller's cue to fall back to a free-running read. Guarded at its own firmware boundaries.
function sdec.stream_arm(nsmp)
  -- Cleared first, ahead of the four early returns: a stale true would wait for a trigger nothing armed on.
  sdec.strm_armed = nil
  local buf = sdec.buf
  -- No buffer is a refused arm, not a raise: the caller can only choose the fallback if it is told.
  if buf == nil then return false end
  -- The closure form is required: pcall(buf.clear) fetches .clear first, and that fetch is the IPC.
  if not sdec.bufclear(buf) then return false end
  -- fillmode = 1 per capture, after clear(), as acq_triggered() does it: it reads back 0 on a reused
  -- buffer. docs/MEASUREMENTS.md, 'A reserve in a FILL_ONCE buffer posts 4915 per discard'.
  sdec.acq_fillmode(buf)
  if sdec.dig == nil then return false end
  -- 1 is SimpleLoop's per-iteration count and is wrong for the armed shape: docs/MEASUREMENTS.md, 'The
  -- pre-trigger reserve comes out of capacity, not out of count'. Set to the depth anyway, to be honest.
  local dcount = 1
  if sdec.arm_silent() and sdec.trigmode ~= 'free' then dcount = nsmp end
  if not pcall(function() sdec.dig.count = dcount end) then return false end
  -- A recording can wait for the device too: SimpleLoop acquires the instant it is initiated, and
  -- LoopUntilEvent's infinite pre-roll is what makes an analog trigger evaluate. docs/TRIGGER.md,
  -- 'Choosing a shape', 'Pre-trigger, and what the comparator needs' and
  -- 'The canned templates and the fast path'.
  local armed = (sdec.arm_silent() and sdec.trigmode ~= 'free')
  -- Cleared per arm: a refused load must not leave the previous arm's value standing.
  sdec.acq_posloaded = nil
  local ok = false
  if armed then
    -- The source, the blender and the TRIGGER-key break-in, from the one function that decides them. The
    -- nil branch is live: arm_source() returns nil when its trigger constant is itself absent.
    local ev, useanalog = sdec.arm_source()
    if ev == nil then
      armed = false
    else
      -- No level and no comparator are refusals, not details: armed at 0 V it fires on the first noise.
      if useanalog and (sdec.arm_thr == nil or
                        not sdec.arm_comparator(useanalog, sdec.arm_slope())) then
        armed = false
      end
      -- Elision needs the comparator and nothing else will do: the detector asks whether a crossing arrived in
      -- the last window, and a key press or a rear marker does not recur with the line.
      -- docs/TRIGGER.md, 'Detecting silence: `BRANCH_ON_EVENT` spends its event'.
      if armed then
        -- position is a percentage of CAPACITY, so a static buffer oversized for this capture reserves far
        -- more than the capture wants: sdec.pretrig's 5 against the 6 000 000 record is 300 000 readings.
        -- acq_pospct scales it to the readings the reserve MEANS, and rounds UP, because losing the reserve
        -- costs the head of the record while a percent too much costs only samples. Whole percent: a
        -- fractional position has never been loaded on this instrument.
        local pos = sdec.pretrig
        if sdec.acq_bufperm then pos = sdec.acq_pospct(nsmp, buf) end
        ok = pcall(trigger.model.load, 'LoopUntilEvent', ev, pos,
                   trigger.CLEAR_ENTER, 0, buf)
        -- What actually loaded, because leadmax is derived from it and sdec.pretrig is no longer it.
        if ok then sdec.acq_posloaded = pos end
      end
      -- A refused load is not an armed recording: the poll loop would wait out an arm that is not there.
      if not ok then armed = false end
    end
  end
  sdec.strm_armed = armed
  -- Two sites rather than one closure, and the `and` keeps the ordering. No OP_CLOSURE per capture.
  if not armed then ok = pcall(trigger.model.load, 'SimpleLoop', nsmp, 0, buf) end
  -- The record is cleared from here rather than inside the program, and once per initiate. The two canned
  -- templates clear their own record, so for them this call is redundant.
  --
  -- A failed clear refuses the arm rather than being noted: the recording would append to whatever the last
  -- one left behind, and every span the rate is read from would be long by the stale part -- in the one
  -- direction nothing downstream flags.
  if ok then
    local cok = sdec.bufclear(buf)
    if not cok then
      ok = false
      sdec.lasterr = 'could not clear the record before arming'
    end
  end
  if ok then ok = pcall(trigger.model.initiate) end
  -- An arm is not live until the model is in its wait block, and the poll loop reads "no longer waiting"
  -- as "fired". docs/UNDOCUMENTED.md, 'trigger.model.state() reports a lag, not a readiness -- and
  -- it has nothing to do with the buffer'.
  if ok and armed then
    local spun, saw = 0, false
    while spun < (sdec.arm_settle_s or 0.25) do
      if sdec.trig_waiting() == true then saw = true break end
      delay(0.01)
      spun = spun + 0.01
    end
    -- And the verdict is carried out: the loop cannot tell "never got there" from "left it".
    if not saw then armed = false end
  end
  sdec.strm_armed = armed
  -- The pulse goes after the model is armed, or the device transmits into a buffer that does not exist.
  -- After a successful arm, because the fallback issues a second credit and the first is spent.
  if ok and sdec.fc_out then
    sdec.fc_credit()
  end
  return ok
end

-- Stop the hardware and publish what it collected. -> the reading count, and a second return naming the
-- failure when the buffer could not be read at all, which is what keeps a fault from reading as an
-- empty recording: buf.n raises on a buffer the firmware has dropped, and 0 reads as 'collected nothing'.
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

-- Re-measure the levels from the newest samples in buf when the watchdog is about to end a run on REUSED
-- levels. buf holds `have` readings; iw is the window. Returns true if the reused threshold is wrong and a
-- better one is in force, so the caller should keep going.
function sdec.strm_relevel(buf, have, iw)
  -- Only when the levels were reused: a threshold from this capture's own probe has already seen this wire.
  if not sdec.strm_lvlreuse then return false end
  if buf == nil or have == nil or have < 3 then return false end
  local from = have - iw + 1
  if from < 1 then from = 1 end
  local win, m = {}, 0
  local rok = pcall(function()
    m = sdec.ck_reader_buffer(buf, have)(win, from, iw, 1)
  end)
  -- Tri-state, because a read that raised is ignorance, not silence.
  if not rok then return false, true end
  if m < 3 then return false, true end
  -- The reused threshold stands until the new levels disprove it, because sig_levels() overwrites thr as
  -- a side effect -- and the remembered lvl_* with it, or a quiet tail becomes the next threshold.
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
  -- Wrong means the signal cannot cross it: a bare lo < thr < hi admits one sitting on a rail, so the
  -- margin is the hysteresis. docs/MEASUREMENTS.md, 'A reused threshold can sit on a rail'.
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
  -- Polled, so the run can end early on a quiet line, which a blocking read cannot. The same bounded-wait
  -- shape as acq_triggered(), because a poll loop that cannot exit is a dead panel.
  local buf = sdec.buf
  -- Over-read, before anything is sized from nsmp: see sdec.strm_overread. Clamped to the buffer, so the
  -- target stays a count the record can actually reach and `have >= nsmp` remains a reachable exit.
  --
  -- Unconditional, because the over-read is orthogonal to gap elision. Every pause the line takes is
  -- recorded in full, and those samples come out of the same count the payload does, so every recording
  -- spends part of its budget on idle. Unconditional for that reason: the margin is wanted most by the
  -- captures with the most silence, and there is nothing to make it depend on.
  if (sdec.strm_overread or 0) > 0 then
    nsmp = sdec.acq_fit(math.ceil(nsmp * (1 + sdec.strm_overread)), buf)
  end
  -- The count this acquisition actually ran to, beside strm_nsmp's request: the two differ by the
  -- over-read and a reader of either needs to know which it has.
  sdec.strm_target = nsmp
  -- What this window spent, for record_run's bound. A counter, because the one timer is spoken for twice.
  sdec.strm_waited = 0
  local ok = sdec.stream_arm(nsmp)
  if not ok then
    -- Falls back to a blocking read, which loses every bound, so it is shortened to strm_fallback_s.
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
    -- Cap the Lua copy too: sdec.n bounds what is copied, where the first argument bounds the acquisition.
    sdec.strm_waited = cap / fs
    return sdec.acq_free(cap, sdec.n)
  end

  local quiet, seen, step = 0, 0, sdec.ck_poll_s
  -- Read once: the exit comes from Arm/Idle Wait, and the operator cannot change it mid-run.
  local qexit = sdec.idle_exit()
  -- The ring position last looked at, beside the count. -1 rather than nil, since 0 is a real endindex.
  local seenend = -1
  local iw = sdec.idle_window(sdec.fs)
  local waited = 0
  -- The arm, which this loop must bound. docs/MEASUREMENTS.md, 'buf.n is not evidence of a trigger'.
  local armdone = true
  if sdec.strm_armed then
    armdone = false
    -- Say so before blocking, through acq_triggered()'s hook: a static panel reads as a hang.
    if sdec.armnote ~= nil then
      pcall(sdec.armnote, sdec.arm_wait_s(), sdec.arm_thr or sdec.thr or sdec.arm_level_v(),
            sdec.armkeyed)
    end
  end
  -- Consecutive failed window reads, and the last reason: a read failure must not pass for a quiet line.
  local rfail, rlast = 0, nil
  sdec.strm_readfail = nil
  -- Bounded by wall clock as well as by samples, and the clock is the only bound that always fires: a
  -- press is not dispatched while Lua runs, so every mode must terminate by construction.
  local limit = sdec.stream_limit(nsmp, sdec.fs)
  -- The arm's own wait goes on top of the ceiling, not inside it: the wait must not come out of the run.
  if sdec.strm_armed then limit = limit + sdec.arm_wait_s() end
  --   full     one of three different endings, and the overload matters to a reader of the record: the
  --            buffer reached nsmp, or the wall clock `limit` expired, or stream_arm was refused and
  --            the fallback read ran. Only the first is a complete record.
  --   quiet    no threshold crossing for sdec.idle_exit(). The device stopped talking.
  --   stopped  the operator pressed Capture (Stop) or Mode (abort)
  --   noarm    the arm expired at sdec.arm_wait_s() without the comparator firing
  --   readfail the buffer could not be read, or could not be re-measured to confirm a quiet line
  while true do
    local have = buf.n or 0
    -- Leaving the wait block is the trigger firing; measured from inside, a host command aborting it.
    if not armdone and sdec.trig_waiting() ~= true then
      armdone = true
      quiet = 0
      seen, seenend = 0, -1
      -- And give the cell back, or the arm's note stands for the rest of the run: the refresh in
      -- record_run() is the last full one, so nothing else repaints this until the run ends.
      if sdec.armnote_clear ~= nil then pcall(sdec.armnote_clear) end
    end
    -- What counts as finished turns on whether this recording waited: an armed one is finished when the
    -- model is, a long pre-trigger phase having already filled the buffer. Unarmed keeps the fill test.
    if sdec.strm_armed then
      if armdone and sdec.trig_done(buf) then sdec.ck_endwhy = 'full'; break end
    elseif have >= nsmp then
      -- The sample count is the completion test for an unarmed recording. Left on
      -- the armed branch the fill test is unreachable, and because the record is fillmode = 1 it would not stop
      -- but WRAP, overwriting its own earliest bursts until some other exit fired, and then report a full record
      -- that had quietly lost its oldest traffic. docs/TRIGGER.md, 'How a recording ends'.
      sdec.ck_endwhy = 'full'
      break
    end
    -- The cancel latch is read here so a blended stimulus can end the wait; a finger cannot. Before the
    -- arm expiry, because TRIGGER is blended into the arm and a press both fires it and sets the latch.
    if sdec.cancel_asked() then sdec.ck_endwhy = 'stopped'; break end
    if not armdone and waited >= sdec.arm_wait_s() then
      -- The level is stashed at the expiry, because the next window clears thr before the note is printed.
      sdec.arm_expired_at = sdec.arm_thr or sdec.thr
      sdec.ck_endwhy = 'noarm'
      break
    end
    if waited >= limit then sdec.ck_endwhy = 'full'; break end

    -- Newest samples only, by ring position. docs/MEASUREMENTS.md, 'A record can come back rotated'.
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
      -- A read that raised is ignorance, not silence, so it must not advance the quiet timer.
      if not rok then
        rfail = rfail + 1
        rlast = rerr
        -- Persistent is different from transient: a run of failed reads means the buffer cannot be read.
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

    -- On an eliding record the quiet timer has to come from the model rather than the record. Both paths above
    -- advance it on a gap by construction: the record does not grow so `fresh` is false, and when it is read
    -- idle_window() caps at 4000 samples -- 40 ms at 100 kS/s -- which sees only the burst's own idle tail. So
    -- the timer starts running 40 ms into every burst's tail, before the gap has even begun, and no allowance
    -- against it can be right. The model's state is the gap detector instead: parked in block 2's WAIT during a
    -- gap, cycling blocks 3 to 6 during a burst. That tells a long gap from a dead line exactly, which no
    -- threshold on a record that is designed not to grow ever can. docs/TRIGGER.md, 'How a recording ends'.
    -- The idle watchdog is off until the arm fires: a waiting arm is a line with nothing on it by design,
    -- so the watchdog would end the run before the device started. Not moot where levels were reused.
    if armdone and sdec.ck_watch and qexit ~= nil and qexit > 0 and quiet >= qexit then
      -- A quiet verdict on reused levels is checked first: a threshold outside the swing sees no crossings.
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

    -- Yields at ck_poll_s, because delay() is what lets the display update. Not while an arm waits.
    if armdone then sdec.progress_samples(have, nsmp) end
    delay(step)
    waited = waited + step
    sdec.strm_waited = waited
  end

  return (sdec.stream_settle())
end

-- Poll period. Two per second is well inside the 1 Hz display budget and costs no measurable time.
sdec.ck_poll_s = 0.5

-- A hard ceiling on the wait for nsmp samples at fs: twice the fill time, floored at 10 s, capped at 1200.
function sdec.stream_maxwait(nsmp, fs)
  if fs == nil or fs <= 0 then return 600 end
  -- Independent of the watchdog, which only arms on real levels: this is then the only exit left.
  local t = 2 * nsmp / fs
  if t < 10 then t = 10 end
  if t > 1200 then t = 1200 end
  return t
end

-- The wall-clock ceiling a recording runs under.
--
-- Separate from stream_maxwait, which returns 2 * nsmp / fs -- twice how long the wire takes to deliver
-- every sample the record holds -- so the 32 kB mode at 9600 gets 68 s for its 3 413 334 readings. Elision fills
-- that record with traffic ONLY, so a line talking a tenth of the time needs ten times the clock and would be
-- cut off having recorded a fraction of what was asked, reported as a full buffer. The standing ceiling is the
-- right bound there, and it is still a bound: the fill test, the quiet-line exit and the operator all end the
-- run before it.
function sdec.stream_limit(nsmp, fs)
  local limit = sdec.stream_maxwait(nsmp, fs)
  if sdec.strm_maxsec ~= nil and sdec.strm_maxsec > 0 and limit > sdec.strm_maxsec then
    limit = sdec.strm_maxsec
  end
  return limit
end

function sdec.progress_samples(have, want)
  -- In samples, not bytes: nothing is decoded yet, so percent of the buffer is the honest number.
  sdec.ck_acq_have, sdec.ck_acq_want = have, want
  return sdec.progress_row()
end

-- Readings the largest recording may ask for. The 32 kB mode at 9600 records 3 413 334 at 100 kS/s, so any
-- ceiling above that keeps all 32 768 bytes; this figure buys every other reachable combination. Bisected,
-- not chosen: docs/MEASUREMENTS.md, 'ck_bufwant = 4076503'.
sdec.ck_bufwant = 4076503

-- And the live ceiling, which start() recomputes from the capacities the operator has set. Initialised to the
-- static need, because a caller that never ran start() still needs a number. bufmax_for() reads ck_bufwant
-- and never this, so a launch under a large defbuffer1 cannot ratchet it down.
sdec.ck_bufmax = sdec.ck_bufwant

-- The instrument's whole reading memory, across all buffers together. Standard style, which is what
-- acq_make_buffer() allocates, and not compact, and not by choice -- docs/MEASUREMENTS.md,
-- 'buffer.STYLE_COMPACT is nil on this firmware'; the per-model figures are under 'The reading pool is
-- per model'. The default is a separate field, or a resolver that only matches leaves the last match.
sdec.ck_bufpool_default = 7080255
sdec.ck_bufpool = sdec.ck_bufpool_default
sdec.ck_bufpool_model = {{'7510', 7500000}, {'2461', 6875000}}

-- Resolve the pool from the model number. -> the figure now in force. Assigns unconditionally from a local,
-- so the answer depends on the model and not on call order. Bare read: localnode is documented on every
-- supported model. Substring, since neither key can collide.
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

-- A chosen margin below the measurement, not a second measurement. 6 000 000 is the hard guard, what the
-- vendor's bufferVar.capacity documents; ck_bufmargin covers the pool figure's uncertain last digits and the
-- firmware's unreported per-buffer overhead, at 0.7 % of the pool.
sdec.ck_bufguard = 6000000
sdec.ck_bufmargin = 50000

-- The smallest recording that is still a recording, which is the floor start() refuses below. It is the
-- triggered floor: the reserve term in stream_begin() applies only where trigmode is not 'free', so a
-- free-running recording's floor is lower. docs/MEASUREMENTS.md, 'ck_bufmin = 898347'.
sdec.ck_bufmin = 898347

-- The ceiling the live defbuffers leave, which is a query and not the policy: buf_reclaim() is what
-- changes them. One pcall for both reads, because this is an outbound firmware boundary and the pcall
-- budget counts sites. Returns the ceiling, then the name and capacity of the larger default buffer,
-- which the refusals must quote or they send the operator at the wrong one.
function sdec.bufmax_for()
  local ok, d1, d2 = pcall(function() return defbuffer1.capacity, defbuffer2.capacity end)
  if not ok or type(d1) ~= 'number' or type(d2) ~= 'number' then
    return sdec.ck_bufwant, nil, nil
  end
  local bigname, bigcap = 'defbuffer1', d1
  if d2 > d1 then bigname, bigcap = 'defbuffer2', d2 end
  local n = sdec.ck_bufwant
  if sdec.ck_bufguard < n then n = sdec.ck_bufguard end
  -- BOTH BOUNDS, AND THE SMALLER WINS, because either alone is wrong.
  --
  -- The pool remainder, less whatever the set holds EXCEPT the record itself: a recording records INTO that
  -- buffer, so it is not a cost to the recording, while the frame buffer, the ladder and the scratches are
  -- allocated and the instrument genuinely does not have them to give. Subtracting none of it described a
  -- machine with no app running on it, which is how this answered 4 076 503 while the record held 6 000 000
  -- of a 7 080 255 total.
  --
  -- One call for both figures: asking acq_bufhave('rec') separately opened a window where the record could
  -- die between the two, leaving a capacity to subtract that the total no longer contained.
  local held, rcap = sdec.acq_bufheld()
  if rcap ~= nil then held = held - rcap end
  local avail = sdec.ck_bufpool - d1 - d2 - held - sdec.ck_bufmargin
  if avail < n then n = avail end
  -- And never more than the static record holds, where there is one. A recording does not allocate, so that
  -- buffer is its ceiling and no arithmetic over the pool can raise it.
  if rcap ~= nil and rcap < n then n = rcap end
  if n < 0 then n = 0 end
  return n, bigname, bigcap
end

-- What the instrument ships with in each default buffer. Not the reclaim target any more -- see
-- ck_defbufmin -- but still the figure a refusal quotes, and buf_restore puts back whatever it found.
sdec.ck_defbufcap = 100000

-- The reclaim target: the smallest capacity a reading buffer may have, which the firmware names itself in
-- 4920 "Reading buffer capacity must be between 10 and 7080255 readings". Both default buffers go here for
-- the app's whole run and buf_restore() hands the operator's sizes back at teardown, which buys the record
-- 199 980 readings it used to leave sitting in buffers no capture reads.
sdec.ck_defbufmin = 10

-- One default buffer's capacity, written and answered for. -> true if the instrument took it. One
-- guarded site for every capacity write this app makes, because the pcall budget counts sites.
--
-- Per buffer is not a style choice: one pcall spanning both writes is not atomic, so defbuffer2's
-- readings were discarded while buf_reclaim reported false. A whitelist, and named exactly, or the else
-- would resize defbuffer2 for anything.
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

-- Resize both default buffers to the minimum for the app's whole run, because the reading memory is one pool
-- across every buffer and the record wants all of it: the permanent 6 000 000 leaves 1 080 255 on a DMM6500
-- and 875 000 on a 2461, so the 200 000 these two hold by default is worth taking. Unconditional rather than
-- on demand -- an adaptive reclaim ran only once the allocation had already failed, which made the room
-- available depend on what the operator had done before launch.
--
-- defbuffer2 first, then defbuffer1, which is the default active buffer and so the one likely to hold the
-- operator's readings. A resize discards every reading whatever the new capacity is, so the sizes are
-- recorded here and buf_restore() puts them back at teardown. -> did_reclaim, and text naming what moved.
function sdec.buf_reclaim()
  local ok, d1, d2 = pcall(function() return defbuffer1.capacity, defbuffer2.capacity end)
  if not ok or type(d1) ~= 'number' or type(d2) ~= 'number' then return false, nil end
  local dc = sdec.ck_defbufmin
  local n1, n2 = nil, nil
  if d2 > dc then n2 = dc end
  if d1 > dc then n1 = dc end
  if n1 == nil and n2 == nil then return false, nil end
  local what = nil
  -- Each write recorded as it lands, so a resized buffer is one this app can name and put back.
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

-- Globals the sweep must not index. type(defbuffer1) is 'table' here, so the walk below is offered
-- every firmware namespace, and indexing one whose accessory card is absent posts 1151 -- posts, not
-- raises, so the pcall returns success and the entry reaches the log regardless. serial, digio, gpib
-- and tsplink file eight between them at each launch of a meter carrying only a scan card; channel,
-- scan and slot are quiet only while that card is fitted; trigger is model-dependent, the SMU having
-- no rear-panel trigger connections. So the list is every firmware namespace this app can name and
-- not only the ones measured posting: a stranded reading buffer is never named after one, so a name
-- here costs nothing, while a name missing from here costs an entry the operator has to read past.
-- docs/UNDOCUMENTED.md, 'Indexing the namespace of an absent accessory card posts 1151 and raises nothing'.
sdec.buf_skip = {}
do
  -- The two default buffers are in the list for the other reason: they are real buffers, and they are
  -- resized and never deleted.
  local nm = {'defbuffer1', 'defbuffer2',
              '_G', '_LOADED', 'acal', 'beeper', 'bit', 'buffer', 'cal', 'channel', 'coroutine',
              'dataqueue', 'debug', 'define', 'diagnostics', 'digio', 'display', 'dmm', 'enum',
              'errorqueue', 'eventlog', 'fan', 'file', 'format', 'fs', 'gpib', 'io', 'ki', 'lan',
              'localnode', 'math', 'memory', 'node', 'os', 'scan', 'scpi', 'script', 'serial',
              'slot', 'smu', 'status', 'string', 'table', 'timer', 'trigger', 'tsplink', 'tspnet',
              'uncertainty', 'upgrade', 'userstring'}
  local i
  for i = 1, table.getn(nm) do sdec.buf_skip[nm[i]] = true end
end

-- Buffers this app did not make hold the same pool, so they are swept before the default buffers are
-- touched. Found by walking the globals, because the instrument publishes no way to enumerate reading
-- buffers: a global with a numeric capacity and a numeric n is the only handle there is. sdec.buf and
-- every name in sdec.buf_skip are skipped.
--
-- Collect, then delete, never interleaved: writing to the global table while next() walks it is
-- undefined, and dropping the handle first strands the buffer. -> freed_readings, and text.
function sdec.buf_sweep()
  local names, nn = {}, 0
  pcall(function()
    local bt = type(defbuffer1)
    local k, v = next(_G, nil)
    while k ~= nil do
      -- EVERY ONE OF OURS, not just the one in force. sdec.buf is whichever of the static set the current
      -- mode selected, so testing against it alone offered this sweep the app's other two buffers as
      -- strangers -- and the discriminator below would have deleted the 32 kB mode's 4.8 million readings
      -- while the app was running on the frame one.
      if type(k) == 'string' and not sdec.buf_skip[k]
         and type(v) == bt and v ~= sdec.buf and not sdec.acq_isours(v) then
        -- Every stranded buffer goes, whatever its size: they accumulate one per relaunch. So the
        -- discriminator carries the weight -- a numeric `.capacity` and a numeric `.n` are both
        -- required, capacity first so `.n` is only reached once capacity has answered like a buffer.
        local c = v.capacity
        if type(c) == 'number' and type(v.n) == 'number' then
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
  if freed > 0 then pcall(collectgarbage) end
  return freed, gone
end

-- Hand the capacities back -- the sizes are the operator's setting and only the readings were lost. Runs
-- in stop() after the capture buffer is freed, because until then there is no room to grow them. Not
-- fatal and not retried: failing the teardown over it costs a reinstall. -> text, or nil for nothing.
function sdec.buf_restore()
  -- A relaunch is not an exit: the ceiling is derived from the reclaimed capacities. One-shot and consumed
  -- here, so a raise inside cleanup() costs one skipped restore instead of every one.
  if sdec.ck_relaunching then
    sdec.ck_relaunching = nil
    return nil
  end
  local was = sdec.ck_defbufwas
  if was == nil then return nil end
  -- The record is kept until each write lands: the capacities this app destroyed are derivable from
  -- nowhere else. An entry is dropped only on success, since assigning a capacity clears the buffer.
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
  -- A byte-capped mode's count follows from the format; md.cap = nil takes what the buffer allows.
  if md.cap == nil then return sdec.ck_bufmax end
  -- 8N1 unless the frame format is forced, and all three forced fields widen it, not just the width.
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
  -- And this is where a long decode becomes cancellable: one window is the only point this module gets control.
  if sdec.cancel_asked() then return false end
  return true
end

-- Poll the TRIGGER key and record it as a stop request. True once a cancel is in force, including one seen by
-- a previous poll -- the blender's latch auto-resets on read, so a caller that polls twice and expects the
-- same answer loses the press.
function sdec.cancel_asked()
  if sdec.ck_stop then return true end
  if not sdec.cancel_pressed() then return false end
  sdec.ck_stop = true
  -- Separate from ck_stop, which Mode also sets: ck_cancel is "the operator pressed TRIGGER".
  sdec.ck_cancel = true
  return true
end

-- The two answers to a refused forced rate. decode() publishes rate_offer when the locked rate is proved
-- wrong and refuses rather than substituting one nobody chose. Ordinary functions with no display dependency,
-- so the behaviour is testable with no human at the panel; each returns ok, reason.

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
-- and returns a verdict rather than raising. Not the handler -- sdec.capture() wraps this to hold the tick.
function sdec.capture_run()
  -- A key inserted since the last press resumes logging HERE, so the promise is "the first button press".
  ulog.resume()
  -- Every failure below comes back as a message on the panel.
  if sdec.ck_running and not sdec.strm_recording and sdec.ck_job == nil then
    -- A stop request that went unanswered proves there is no run to answer it, so ck_running is a latch a
    -- dead run left. Clearing it is the only way out from the panel.
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

  -- Absorb the stop press that arrives after the stream it was meant to stop: presses queue, so it lands
  -- here as a fresh capture and would wipe the bytes on screen. See sdec.press_absorbed().
  if sdec.press_absorbed('Capture') then return true end
  -- Once per press, ahead of the mode dispatch: a relock inside this press must reach the note row.
  sdec.relocked = nil
  -- rate_backoff with it: it requests one re-capture within THIS press.
  sdec.rate_backoff = nil
  -- The rate offer is per press for the opposite reason -- a fresh capture is itself an answer to it.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil

  -- The panel is blanked here, before any mode can arm or wait. Every path below eventually calls
  -- detect_reset(), but the frame path reaches it only after the mode dispatch, and an armed capture
  -- then sits on the analog trigger for as long as the line stays quiet -- so the previous capture's
  -- byte count, error count and note stay on the glass for the whole wait and read as this capture's.
  -- Clearing the result is what blanks BYTES and ERR: ui_field_values() prints '--' for both when
  -- sdec.res is nil, and ui_note_text() returns an empty string when no note survives.
  --
  -- stickyerr is deliberately kept. It carries the faults that must outlive a capture -- a
  -- buffer that could not be freed asks for a power cycle -- and a capture that blanked it would be
  -- hiding the one message the operator has to act on.
  -- Not clear_result(), which is a much bigger hammer: it ends in clear_measured(), dropping the
  -- levels the probe learned -- sdec.idle, sdec.thr, sdec.lo, sdec.hi. Paths that arm without re-probing read
  -- those back, so blanking them here costs a recording its idle sense. Only the fields the two
  -- indicators actually read are cleared.
  if not sdec.strm_recording and sdec.ck_job == nil then
    sdec.res, sdec.midi, sdec.lin = nil, nil, nil
    sdec.ck_tot, sdec.ck_nbytes = nil, nil
    sdec.lasterr, sdec.savedas = nil, nil
    sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
    sdec.mode_exited, sdec.lognote, sdec.autolocknote = nil, nil, nil
    sdec.ui_status = 'capturing'
    sdec.ui_refresh()
  end
  -- Busy on entry means a previous run died, not that one is in progress, since presses queue until the
  -- handler returns. Refusing would make it permanent, so it is recorded once and cleared.
  if sdec.busy then
    sdec.lasterr = 'previous capture did not finish (aborted?) -- starting a new one'
    ulog.line(sdec.lasterr)
  end
  sdec.busy = true

  --   no run      start recording. Arms the hardware and returns; the panel stays live throughout.
  --   recording   stop recording, and decode the first slice.
  --   decoding    decode the next slice.
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
    sdec.detect_reset()
    sdec.ui_status = 'capturing'
    -- Set before the refresh, so the control cell says 'no stop until it ends' for the whole run.
    sdec.strm_inflight = true
    -- No refresh here: record_run() paints, immediately after it clears the cancel latch.
    local sok, swhy = false, nil
    -- The whole job in one press, and nothing can cut it short: record_run()'s bounds are the only exits.
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
      -- Every recording leaves the bytes it kept on screen, paged like a frame capture. The mode does not change.
      if sdec.ck_tot ~= nil and sdec.ck_tot.tail ~= nil then
        -- No "this is a stream tail" flag: the view carries `first` and `ntotal`, so ui_notes() can tell.
        sdec.res = sdec.ck_tot.tail
      end
    end
    -- Leaving the mode happens on every outcome: in the `else` it would miss a refused or raised run.
    sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, sok, sdec.lasterr), not sok)
    sdec.ui_refresh()
    -- Armed last, after the flush and the repaint: the window is 1 s from the moment it is armed.
    sdec.strm_absorb_arm()
    return sok, swhy
  end

  -- The frame path owns the panel from here, so the streaming summary goes, or BYTES reads 389 over a
  -- 159-byte dump. Not in clear_result(), which the streaming path also calls.
  sdec.ck_tot, sdec.ck_nbytes = nil, nil
  -- The multi-window counters go with them: a stale one would put '3 windows' on a frame capture.
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = nil, nil, nil, nil
  -- Not just clear_result(): the requested rate goes back to what the lock and mode imply.
  sdec.detect_reset()
  sdec.ui_status = 'capturing'
  sdec.ui_refresh()

  -- Not pcall'd: the nesting is what the firmware cannot take (see start()). sdec.unwind restores.
  local ok, why = sdec.autoset()

  -- One fresh capture after a back-off, cleared BEFORE the retry or a second back-off retries for ever.
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
    -- One call each, no guard: summary() defends every value it formats, and this is a handler's success tail.
    ulog.line(sdec.summary(1))
    ulog.line(sdec.summary(2))
    ulog.line(sdec.summary(3))
    -- Parse the protocol layer here, not lazily at the view, so the log records the capture that produced
    -- the messages -- and before the notes, so the LIN break count is in the list. Bare, each guarded.
    sdec.proto_parse()
    -- Before the notes, so the auto-lock note is one of them: locking must never retract a good capture.
    sdec.autolock_try()
    local nt, nn = sdec.ui_notes()
    local ni
    for ni = 1, nn do ulog.line('note: ' .. nt[ni]) end
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

-- The half-second tick is off for the whole press. A tick is dispatched exactly like a press, so work
-- that holds the interpreter defers ticks rather than suppressing them. A wrapper rather than an edit
-- into the body, because capture_run() has a dozen returns and a missed one would leave no tick.
--
-- The body is not guarded, and a raise reaches the caller: `pcall(sdec.capture)` is how two callers ask
-- whether the press faulted, and what a raise would skip, sdec.unwind restores.
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
-- Lock the wire parameters as soon as they are known confidently: an unknown format costs the format
-- search and a whole extra capture, so the second press onward runs about three times faster for the
-- same bytes. docs/MEASUREMENTS.md, 'Auto-lock pays for itself'. It also makes the recording modes
-- reachable, since they require a locked rate and refuse until something locks.
--
-- The gates are the whole design: locking a wrong detection turns a one-capture mistake into a
-- persistent one, and the five in autolock_try() are independent.
-- ============================================================================
sdec.autolock_min  = 8      -- frames required before a detection may be locked
-- Fraction of the capture that must be ONE unbroken clean run. docs/MEASUREMENTS.md, 'autolock_run = 0.6'.
sdec.autolock_run  = 0.6
sdec.autolock_fitq = 0.9    -- least-squares fit quality required
-- Operator state, so `or`/nil-test like the rest. On by default, so the fast state is reached by itself.
if sdec.autolock == nil then sdec.autolock = true end

-- Suppress auto-lock for the NEXT capture only. Returns true.
function sdec.autolock_defer()
  -- An explicit request for auto-detect must survive the capture that follows it, or the same press
  -- re-locks the rate just detected. One capture of grace, consumed by the next autolock_try().
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
  -- Gate 1, a credible rate: matched within snaptol, or rounded inside 1 % -- 100 Bd over 10 kBd, 10
  -- below. Lock the measurement, not the snap. docs/MEASUREMENTS.md, 'Auto-lock pays for itself'.
  local lockfrom = sdec.baud
  if sdec.snapped and sdec.snapfirm == false and sdec.baud_raw ~= nil then lockfrom = sdec.baud_raw end
  local lockb, lockok = sdec.baud_round(lockfrom)
  if not sdec.snapped and not lockok then return false end
  -- Gate 2, the longest contiguous clean run, not an error count: scattered errors leave no long run.
  -- docs/MEASUREMENTS.md, 'autolock_run = 0.6'. nf is defended so the caller can call this bare.
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
  -- Gate 3: enough frames that agreement means something. Two clean frames of noise agree too.
  if (r.ngood or 0) < sdec.autolock_min then return false end
  -- Gate 4: the least-squares bit time explains the pulse widths it was fitted to.
  if (sdec.fitq or 0) < sdec.autolock_fitq then return false end
  -- Gate 5, the one about the signal rather than the decode: the four above say how self-consistent this
  -- one capture was, and a marginal line can be self-consistent by luck. Guarded on existence.
  if sdec.sig_levelwarn ~= nil and sdec.sig_levelwarn() ~= nil then return false end

  -- Only the fields the operator left on Auto, or a hand-forced parity survives one capture. Which fields
  -- this set is recorded, because a back-off must drop what the app chose and not what was typed.
  sdec.autolock_set = {}
  -- Rounded, so a non-standard measurement locks as a number an operator could have typed: 16099 -> 16100.
  sdec.force_baud   = lockb
  sdec.autolock_set.baud = true
  if sdec.force_nbits == nil then sdec.force_nbits = r.nbits; sdec.autolock_set.nbits = true end
  if sdec.force_par   == nil then sdec.force_par   = r.par;   sdec.autolock_set.par   = true end
  if sdec.force_nstop == nil then sdec.force_nstop = r.nstop; sdec.autolock_set.nstop = true end
  -- Polarity locks when something decided it: an observed idle run, or a tier of the contest. It
  -- stays on auto when nothing did -- `prior` means the two polarities were indistinguishable and
  -- the incumbent won by default, which is a coin flip and not a result to freeze. An armed capture
  -- of a gapless line reaches the text tier rather than the run branch, so this is the path that
  -- locks in practice. docs/MEASUREMENTS.md, 'Polarity is not locked'.
  if sdec.force_invert == nil and r.invert ~= nil and
     (sdec.idle_weak == false or (sdec.polwhy ~= nil and sdec.polwhy ~= 'prior')) then
    sdec.force_invert = r.invert
    sdec.autolock_set.invert = true
  end

  -- Names the payoff, and sized to the note row's budget. docs/MEASUREMENTS.md, 'The note row pixel budget'.
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
-- Run one protocol layer's parser over the bytes just decoded. mode names the view. -> whether it ran.
function sdec.proto_parse1(mode)
  local v = sdec.ui_view(mode)
  if v == nil or v.parse == nil then return false end
  local fn = sdec[v.parse]
  -- Guarded on the function as well as the mode: a build without the protocol modules must degrade.
  if fn == nil then return false end
  local ok, perr = pcall(fn)
  -- A parser that raised must not leave an empty view looking like an answer: the capture stays 'done',
  -- so a blank view reads as "no protocol messages". The partial result is retracted too.
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

-- Parse the layers the panel is about to need: the one selected on the options form, and the one being
-- viewed when that is a different one. `which` parses that layer alone. Returns whether any parser ran.
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
-- Separate from sdec.guard because not every raise reaches the boundary: a frame that catches one to
-- make a decision of its own, like lock_toggle, has to do this too or the cleanup does not happen.
-- Raise-free by construction, and it does not log -- a full key is the condition that brought the app here.
function sdec.unwind(why)
  sdec.busy = false
  sdec.ck_running = false
  -- The unwind registers: a frame parks a module field here, because a local is invisible from here.
  if sdec.trig_restore ~= nil then
    sdec.trigmode = sdec.trig_restore
    sdec.trig_restore = nil
  end
  -- The drop belongs to the capture path: a Save or a View that failed has invalidated nothing.
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

-- Run a panel handler so a raise cannot reach the firmware. -> true if it returned. The one place a
-- pcall may wrap this app's own code, and a firmware boundary like any other: the instrument calls these by
-- name out of a display event string, and an escaping raise becomes a modal dialog over the app.
function sdec.guard(f)
  local ok, err = pcall(f)
  if ok then return true end
  return sdec.unwind(err)
end

-- ============================================================================
-- Save the decoded stream to the USB key
-- ============================================================================
-- Write a self-describing file: the wire parameters, the capture as hex + ASCII, then every parsed
-- protocol list. Returns ok.
function sdec.save()
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
  -- A spike on a data bit flips it undetectably, so a zero error count is not zero corruption.
  add('')
  add('"framing errors" counts stop/parity failures only. A noise spike on a data')
  add('bit corrupts the byte with no error indication.')
  add('')
  local i, per = 1, 16
  while i <= sdec.res.nf do
    add(sdec.ua_hex_line(i, per))
    i = i + per
  end

  -- Every parsed protocol list with anything in it: raw bytes are least readable for a protocol capture.
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
    -- Name the reason next_free gave: ulog.idx_why holds it, where a nil path names a local variable.
    if path == nil and ulog.idx_why ~= nil then why = ulog.idx_why end
    sdec.lasterr = 'save failed: ' .. tostring(why)
  end
  sdec.ui_refresh()
  return ok
end

-- ============================================================================
-- View handlers
-- ============================================================================
-- Advance through the views this build has -- text -> hex -> text in version 1, where ui_view_avail()
-- hides the MIDI and LIN entries that would always be empty.
function sdec.view_toggle()
  -- The key is checked by the press, first, so all three presses answer the question the same way.
  sdec.ui_keypoll()
  -- Every protocol view is offered whatever the setting says; the cycle covers the views this build has.
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

-- Show the next page of bytes. Bound to the 'Dn' button down the dump area's right margin, with page_prev() as
-- 'Up' above it; the host drives both over the socket. ui_paged is set even when the page does not move,
-- because it is what puts 'page N of M' on the note row and the last page is when that matters.
function sdec.page_next()
  sdec.ui_paged = true
  if sdec.ui_page + 1 < sdec.ui_npages() then sdec.ui_page = sdec.ui_page + 1 end
  return sdec.ui_refresh()
end

function sdec.page_prev()
  sdec.ui_paged = true
  if sdec.ui_page > 0 then sdec.ui_page = sdec.ui_page - 1 end
  return sdec.ui_refresh()
end

-- Start a new byte log, so one device's or one test's messages are separated from the next.
function sdec.log_new()
  -- Forgetting the path is the whole mechanism, and it says so rather than silently renumbering.
  local was = sdec.flog_path
  ulog.flush()
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  -- And the closed-file stash goes too, the opposite of what mode_exit() does with it: the operator
  -- asked for a new file, so the cell must stop naming the old one.
  sdec.flog_last, sdec.flog_lastbytes, sdec.flog_lastgen = nil, nil, nil
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
  -- Auto-detection is already the DEFAULT, so this is one press instead of six interactions on the form.
  sdec.unlock_all()
  -- No autolock_defer() here: 'Auto Detect' means "work it out and use it", so this capture may lock.
  ulog.line('auto-detect: all forced settings cleared')
  sdec.options_seed()
  -- Auto-detect is FRAME-mode only, being gated on a locked rate, so this press lands there by exiting.
  local md = sdec.mode_cur()
  if md.needbaud then
    sdec.mode_exit('auto-detect is FRAME-mode only')
    -- Set here, not in mode_exit(): that function is a flush and does not touch the mode.
    sdec.capmode = 'frame'
  end
  return sdec.options_apply()
end

-- The padlock's action: amber (auto) locks the detected settings and goes green, green (locked) unlocks back
-- to auto, red (nothing decoded) refuses with a reason. Either way it re-captures.
function sdec.lock_toggle()
  -- Locking the baud rate changes the sample rate, so this re-captures rather than merely pinning: at
  -- 9600 the window goes from 19 bytes to 240. Re-entrancy guard, since two rects overlap on one glyph.
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

  -- Re-capture at the rate the new lock implies, so RATE, SA/BIT and BYTES describe one thing. Guarded
  -- for the verdict, not for safety: the sentence below claims the recapture worked.
  local pok, cres = pcall(sdec.capture)
  local cok = pok and cres
  -- Catching it means owning the cleanup: sdec.guard never sees this raise.
  if not pok then sdec.unwind('capture raised: ' .. tostring(cres)) end
  if note ~= nil and not (pok and cok) then
    -- Say both halves: the setting took, the measurement did not. lasterr outranks this note.
    sdec.lognote = note .. ' -- but the re-capture failed, so the figures above are the previous one'
    note = nil
  end
  if note ~= nil then
    -- sdec.fs, the requested rate: acq_fs describes the capture that just happened.
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
  -- A cancel outranks the nothing-collected refusal, because it caused it: an interrupted window reports
  -- 'long capture returned nothing'. A failure with a cause of its own still wins, via strm_empty.
  if ok == false and not (sdec.ck_cancel and sdec.strm_empty) then
    return 'run failed: ' .. tostring(err or 'unknown')
  end
  -- The ck_endwhy values all mean "the run is over" but say different things about the line -- five of
  -- them, not the three this comment used to claim: full, quiet, stopped, noarm and readfail. A cancel
  -- outranks them, because ck_endwhy describes the acquisition and a press in the decode is later.
  if sdec.ck_cancel then
    if (sdec.fc_win or 0) > 1 then
      return string.format('stopped with the TRIGGER key after %d windows', sdec.fc_win or 0)
    end
    return 'stopped with the TRIGGER key'
  end
  -- A bound is a run-level reason and applies from the first window, unlike the two below it. The data
  -- survives: the sender still waits for a credit, so the recording fragments rather than truncates.
  if sdec.fc_end == 'bound' then
    return string.format('reached the %d-window limit -- Mode, then Capture, resumes in a new file',
                         sdec.fc_maxwin or 32)
  elseif sdec.fc_end == 'timebound' then
    return string.format('reached the %g-minute limit after %d window(s) -- Mode, then Capture, '
                         .. 'resumes in a new file', (sdec.fc_maxsec or 1200) / 60, sdec.fc_win or 1)
  end
  -- A multi-window run ended for a reason of its own: every window but the last ended 'full'.
  if (sdec.fc_win or 0) > 1 and sdec.fc_end ~= nil then
    if sdec.fc_end == 'quiet' then
      return string.format('%d windows, then the device stopped sending', sdec.fc_win or 0)
    elseif sdec.fc_end == 'stopped' then
      -- Not reachable from the panel today, and the wording must not pretend otherwise. Kept as insurance.
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
    return string.format('nothing crossed %.2f V in %g s -- raise Arm/Idle Wait or lower Arm At',
                         sdec.arm_expired_at or sdec.thr or sdec.arm_level_v(), sdec.arm_wait_s())
  end
  if endwhy == 'quiet' then
    return string.format('%g s with no line activity', sdec.idle_exit() or 0)
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
-- returns, and would otherwise land as a new capture that wipes the bytes on screen. A queued press
-- dispatches immediately, so the window only has to be wider than scheduling jitter, and
-- deliberately narrower than reaction time. An absorb, not a flush: the queue cannot be drained.
sdec.strm_absorb_s = sdec.strm_absorb_s or 1.0

-- Arm the queued-press absorb after a run that held the interpreter. On every ending, including 'stopped':
-- returning early because a press was SEEN assumes nothing is queued behind it, which is true of one press and
-- false of an operator who presses Capture, TRIGGER, Capture.
function sdec.strm_absorb_arm()
  sdec.strm_stopped_by_press = nil
  sdec.strm_nabsorbed = 0
  -- timer.cleartime() stamps the moment the run ended; nothing else runs before the queued press.
  timer.cleartime()
  sdec.strm_stopped_by_press = true
end

-- True while still inside the window in which a press must have been queued.
function sdec.strm_absorb_due()
  if not sdec.strm_stopped_by_press then return false end
  local el = timer.gettime()
  if el == nil then return false end
  return el <= sdec.strm_absorb_s
end

-- The one gate every handler that matters consults: was this press queued behind a run that has
-- already ended? True means it is dealt with and the caller must return without acting.
--
-- Every press in the window, not the first. A stale arm is cleared here, because the elapsed time lives
-- in the instrument's one global timer -- so anything taking the timer disarms first, as record_run()
-- does. Capture only, and narrowed by measurement: only Capture starts an uninterruptible run and wipes
-- the result, where a dead Mode button is worse than an unwanted mode change.
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
-- was left -- it does not change it; see the block below.
--
-- `bad` says the run ended badly, and it is passed rather than inferred: the note row shows this
-- message only when it is set. Not sniffed out of `why` -- matching on words like 'failed' is how a
-- protected failure gets narrowed to a boolean nobody checks, which is this app's dominant defect class.
--
-- Never raises for any measured failure, so every caller calls it bare; see ulog.line for the one
-- unmeasured case.
function sdec.mode_exit(why, bad)
  -- One function for every way out -- Mode, an idle line, a completed run, End App -- so all flush the
  -- same way: the stream through ck_stop, the byte log's path forgotten, and ulog flushed and not closed.
  local was = sdec.capmode
  local md = sdec.mode_cur()
  local running = sdec.ck_running
  -- A decode in progress owns an open file, so the job is closed out first or the handle strands. Clearing
  -- ck_running matters here: a press-driven run has no loop to own it.
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
  -- Remember what this run wrote, or flog_status() reads the dropped path as nothing-logged-yet. The
  -- bytes and the key, not just a path: stream() returns early when a capture got nothing, so
  -- flog_alloc never ran, and a set-only guard named the PREVIOUS run's file with its count.
  if sdec.flog_path ~= nil and (sdec.flog_bytes or 0) > 0 then
    sdec.flog_last, sdec.flog_lastbytes = sdec.flog_path, sdec.flog_bytes
    sdec.flog_lastgen = sdec.flog_keygen
  else
    sdec.flog_last, sdec.flog_lastbytes, sdec.flog_lastgen = nil, nil, nil
  end
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  sdec.flog_bytes = nil        -- or the next file reports the previous file's byte total
  -- The mode is not changed here, and this function is only a flush: capmode = 'frame'
  -- would move the operator every time a recording finishes. The two callers that need it set it.
  if running then
    -- Request a stop and leave ck_running alone: the run owns it. ck_stop is left true and nothing on the
    -- unwind clears it -- the entry clear in stream_begin() is what makes that safe. Do not delete it.
    sdec.ck_stop = true
  else
    -- Not running, so both flags are this function's to normalise, and ck_stop may already be true.
    sdec.ck_running, sdec.ck_stop = false, false
  end
  sdec.mode_exited, sdec.mode_exitbad = nil, false
  if md.id ~= 'frame' then
    -- Said on the note line, and the mode does not change here, so the note must not claim it did.

    -- Always set and always logged; tools/test_cancel.lua reads it. Only the note row is conditional.
    sdec.mode_exited = string.format('%s run ended (%s)', tostring(md.name), tostring(why or 'exited'))
    sdec.mode_exitbad = (bad == true)
    ulog.line(sdec.mode_exited)
  end
  return was
end

-- Which mode an idle Mode press advances to -- the entry, not the id.
--
-- Factored out so the panel can name it: a label that names the wrong destination is this app's
-- recurring defect, so the label and the action read the same function. Skips any mode that cannot be
-- right at the locked rate, bounded by n steps, because a table where nothing suits must not spin.
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
--   running  -> abort. Stop the stream and flush, in one press, staying in the mode.
--   idle     -> advance to the next mode, flushing the one being left on the way out.
--
-- The running branch does not land in FRAME: mode_exit() is a flush, so an abort leaves the setting.
function sdec.mode_cycle()
  sdec.ui_keypoll()
  -- A rate offer dies with the capture that raised it, and both branches below discard the result.
  sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil
  -- Not absorbed: Mode is a way to STOP, and a dead Mode button is worse than an unwanted mode change.
  if sdec.ck_running then
    sdec.mode_exit('Mode pressed')
    -- The summary survives a stream that ended by itself; an explicit Mode press is the operator leaving.
    sdec.ck_tot, sdec.ck_nbytes = nil, nil
    -- Mode is the way out, so it must get out: a handler executing at all proves no loop is.
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
-- Is there any activity in rd[1..n]? thr and hyst default to the current capture's. -> true if the line
-- crossed, false if it sat still.
function sdec.smp_active(rd, n, thr, hyst)
  if rd == nil or n == nil or n < 2 then return false end
  if thr == nil then thr = sdec.thr end
  if hyst == nil then hyst = sdec.hyst or 0 end
  -- Hysteresis, not a bare comparison: an idle line at the threshold reports activity from ADC noise.
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
-- Seed the form fields from the current force_* settings, on every open and after anything that changes
-- them, so the form always shows what is in effect without rebuilding it.
function sdec.options_seed()
  return pcall(function()
    -- Guarded explicitly: version 1 omits the Protocol field, and one raise would leave the rest unseeded.
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
    -- The rear-BNC field is a 1-based option index, not display.ON/OFF. Seeded by searching opt_rear_v.
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
    display.setvalue(sdec.opt_over, (sdec.strm_overread or 0) * 100)
  end)
end

-- Snapshot everything the form can change, so Cancel can undo it. Returns true.
function sdec.options_save()
  -- A screen with a Cancel button promises its edits are provisional, and Lock Detected writes the forced
  -- settings at once. The provenance and the displayed rate are part of the state; dhas marks them kept.
  sdec.opt_snap = {baud = sdec.force_baud, nbits = sdec.force_nbits,
                   par = sdec.force_par, nstop = sdec.force_nstop,
                   invert = sdec.force_invert, proto = sdec.proto,
                   any = sdec.widths_any, trig = sdec.trigmode,
                   ext = sdec.trigext, fc = sdec.fc_out, view = sdec.ui_mode,
                   aset = sdec.autolock_set,
                   armv = sdec.armlevel, armw = sdec.armwait,
                   over = sdec.strm_overread,
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
  -- Guarded on the values, which is a different test from the dhas below: nil is legitimate for the three
  -- display fields and not for these two, so a nil means a snapshot built without them.
  if type(s.armv) == 'number' then sdec.armlevel = s.armv end
  if type(s.armw) == 'number' then sdec.armwait = s.armw end
  if type(s.over) == 'number' then sdec.strm_overread = s.over end
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
  -- The seed's verdict decides whether the form may open: a part-way setvalue leaves the fields above it
  -- current and the ones below stale, and Apply then applies every one of them.
  local sok = sdec.options_seed()
  if not sok then
    sdec.lasterr = 'the Options form could not be filled in with the current settings -- not opening '
                   .. 'it, because Apply would then apply values you were not shown'
    ulog.line('options: ' .. sdec.lasterr)
    return sdec.ui_refresh()
  end
  -- Nothing periodic may run while this form is up: a press on an OBJ_EDIT_* opens a firmware modal
  -- editor and the tick is dispatched like a press, so the two compete. Nothing here reads presence.
  sdec.ui_tick_off()
  local ok = pcall(display.changescreen, sdec.optscr)
  if not ok then sdec.ui_tick_on() end
  return ok
end

-- Copy what the last capture detected into the forced fields and re-seed the form. Does NOT
-- re-capture: the values are there to be reviewed, then applied with Apply.
function sdec.options_lock()
  -- The workflow the auto-detector is for: probe an unknown line once, then pin the answer.
  if sdec.res == nil or sdec.baud == nil then
    sdec.lasterr = 'nothing detected yet -- capture first'
    sdec.ui_refresh()
    return false
  end
  -- The snapped rate when it snapped, since that is what a device runs. Through baud_round, because
  -- sdec.baud is standard only when snapped, and whole, because baud_text uses %d.
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
  -- A partial read must not be applied as a whole configuration: a raise half way commits what it read.
  local readok, readerr = pcall(function()
    -- Every field below is now the operator's, so none of it is autolock's to take back.
    sdec.autolock_set = nil
    local b = display.getvalue(sdec.opt_baud)
    -- Rounded to a whole Bd. docs/MEASUREMENTS.md, 'baud_round cascades through three steps'.
    if type(b) == 'number' and b >= 110 then sdec.force_baud = math.floor(b + 0.5)
    else
      -- Baud Rate 0 IS the request for auto-detect, so defer auto-lock for one capture.
      if sdec.force_baud ~= nil then sdec.autolock_defer() end
      sdec.force_baud = nil
    end

    local bi = display.getvalue(sdec.opt_bits)
    sdec.force_nbits = sdec.opt_pick(sdec.opt_bits_v, bi)
    -- Entry 2 widens the automatic search to 6 and 5 data bits. 9 stays forced-only, and a forced
    -- width skips the search. docs/MEASUREMENTS.md, 'Why 9 data bits is never searched, even biased'.
    sdec.widths_any = (type(bi) == 'number' and math.floor(bi + 0.5) == 2)
    -- Parity is applied on its own: the search narrows to it, where pinning the width would force 8E1.
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

    -- The two arm fields, taken only when they read as numbers, or a nil reaches a voltage comparison. Not
    -- clamped here: arm_level_v() and arm_wait_s() clamp at use, so the form shows what was typed.
    local av = display.getvalue(sdec.opt_armv)
    if type(av) == 'number' then sdec.armlevel = av end
    local aw = display.getvalue(sdec.opt_armw)
    if type(aw) == 'number' then sdec.armwait = aw end
    -- No Gap Elide read: the field is withheld from the form, so there is nothing to getvalue and a
    -- read of a nil handle would raise inside this pcall and cost the whole apply. See serial_ui.tsp.
    -- Percent on the glass, a fraction underneath. The field reads 10 where the knob holds 0.10,
    -- because '0.100' beside 'Gap Elide 0.025 s' reads as a second time and not as a proportion.
    -- Clamped to the ceiling here rather than trusting the field, since the ceiling is a field
    -- argument and a form built before overread_max moved would still offer the old one.
    local ov = display.getvalue(sdec.opt_over)
    if type(ov) == 'number' then
      local f = ov / 100
      if f < 0 then f = 0 end
      if f > sdec.overread_max then f = sdec.overread_max end
      sdec.strm_overread = f
    end
  end)
  if not readok then
    -- The restore is what makes the message below true: the reads above assign as they go, so a
    -- partial read leaves fields already changed. options_restore() is Cancel's unwind path.
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
  -- MIDI is the only protocol that pins a BAUD RATE, so only its rate must be dropped on a change.
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
    -- LIN is 8N1, idle recessive, by specification, and its break fields are the worst input for a search.
    sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
    sdec.force_invert = false
    sdec.ui_mode = 'lin'
  elseif was ~= 'uart' then
    -- Leaving a protocol hands the wire back to the auto-detector, which the form alone cannot do.
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
  -- Re-armed here rather than left to sdec.capture(), whose leaving it on is a side effect.
  sdec.ui_tick_on()
  return sdec.capture()
end

-- Leave the options screen without applying anything.
function sdec.options_cancel()
  -- Put back what was in effect when the screen opened: Lock Detected writes the settings immediately.
  sdec.options_restore()
  sdec.options_seed()
  sdec.ui_refresh()
  local ok = pcall(display.changescreen, sdec.ui_scr)
  -- After the switch, and unconditionally: the tick belongs to the main screen.
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

-- Tear the app down: release the job, stop the hardware, delete objects, close the log. Never raises for
-- any measured failure, so every caller calls it bare; each firmware touch below carries its own guard.
-- It is also the End App event string, through sdec.cleanup(), where a raise reaches the firmware.
function sdec.stop()
  -- The tick goes first: one can already be queued, and it would repaint deleted buttons.
  sdec.ui_tick_off()
  -- Order matters: release the decode job and stop the hardware before the buffer goes, because a live
  -- ck_job owns a handle and a running recording is a model writing into sdec.buf.
  if sdec.ck_job ~= nil then sdec.decode_abandon() end
  if sdec.strm_recording then
    sdec.strm_recording = nil
    sdec.stream_settle()
  end
  sdec.ck_running, sdec.ck_stop = false, false
  pcall(trigger.model.abort)
  -- Only while the digitizer is the selected function (sdec.digitizing): the attribute does not exist
  -- under a basic function, and writing it then posts 2800 as a modal box.
  if sdec.digitizing() and sdec.atrig ~= nil then
    sdec.atrig.mode = sdec.k.MODE_OFF
  end
  -- Release the cancel latch: an app that configures a subsystem should un-configure it.
  sdec.cancel_ok = false
  -- The right variable: cancel_blender is a load-time constant, so testing it is vacuous -- the supported
  -- configuration is a firmware with no blenders, where indexing it left 133 objects live.
  local bl = trigger.blender
  if bl ~= nil and bl[sdec.cancel_blender] ~= nil then
    pcall(bl[sdec.cancel_blender].reset)
  end
  sdec.destroy_options()
  sdec.ui_destroy()
  -- Settle before deleting, and keep the handle if the delete is refused, as acq_make_buffer() does: the
  -- abort does not wait, and the handle is the only one, so dropping it strands the buffer.
  -- THE WHOLE STATIC SET, not just sdec.buf. sdec.buf is whichever of the three the mode in force
  -- selected, so deleting it alone left the other two allocated across End App and the next launch had to
  -- find room beside them. acq_buffree() takes all three and both scratch forms.
  if sdec.acq_bufs ~= nil and next(sdec.acq_bufs) ~= nil then
    sdec.acq_buffree()
    -- ANYTHING LEFT, not just 'frame' or 'rec'. acq_buffree drops an entry only when the delete was taken,
    -- so a surviving key is a buffer the instrument refused to free -- and naming the two plan ids missed
    -- the six frame rungs entirely, which would have stranded up to 163 840 readings for the power cycle
    -- while End App reported success. The whole table is the test, so a rung added later is covered without
    -- anyone remembering this line.
    if next(sdec.acq_bufs) ~= nil then
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'a capture buffer could not be freed -- power cycle the instrument'
    end
  end
  if sdec.buf ~= nil then
    sdec.trig_settle()
    local b = sdec.buf
    local delok = sdec.bufdel(b)
    if delok then
      sdec.buf = nil
    else
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'the capture buffer could not be freed -- power cycle the instrument'
    end
  end
  -- The capacities go back after the capture buffer is freed: until then there is no room to grow them.
  local restored = sdec.buf_restore()
  if restored ~= nil then ulog.line('default buffer capacities: ' .. restored) end
  sdec.smp, sdec.nread = nil, 0
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.ei, sdec.es, sdec.ne = nil, nil, 0
  sdec.w, sdec.nw = nil, 0
  sdec.ui_rowc = nil
  -- Last, and after the samples are gone: a basic function takes the digitizer out of the signal path.
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

-- Entry point: open the log, build the UI, and hook End App. Takes NO capture -- the app comes up idle. THE
-- BUILD is under pcall; cleanup(), del_orphans() and stop() on the failure path are not, and there is no guard
-- above launch. Returns false and a reason if a rebuild is refused or the build fails.
function sdec.start()
  -- The recording ceiling is decided first, before the rebuild guard tears anything down. The room is
  -- taken in order of whose it is: foreign buffers, then defbuffer2, then defbuffer1.
  sdec.ck_relaunching = nil
  local swept, sweptwhat = sdec.buf_sweep()
  local reclaimed, reclaimwhat = sdec.buf_reclaim()
  -- Held rather than logged here: with no app log open, ulog.line() would resume onto the wrong file.
  sdec.ck_swept, sdec.ck_sweptwhat = swept, sweptwhat
  sdec.ck_reclaimwhat = nil
  if reclaimed then sdec.ck_reclaimwhat = reclaimwhat end
  sdec.ck_bufmax, sdec.ck_bigbuf, sdec.ck_bigcap = sdec.bufmax_for()
  if sdec.ck_bufmax < sdec.ck_bufmin then
    -- Reachable only where the reclaim could not help, so the message names what it tried.
    local why = string.format('%d readings left for a recording and the smallest mode needs %d: '
                              .. '%s holds %d of the %d the instrument has, and resizing the '
                              .. 'default buffers back to %d %s.',
                              sdec.ck_bufmax, sdec.ck_bufmin,
                              sdec.ck_bigbuf or 'a default buffer',
                              sdec.ck_bigcap or 0, sdec.ck_bufpool, sdec.ck_defbufmin,
                              reclaimed and 'did not free enough' or 'was refused')
    -- Give back what the reclaim took, because this launch is not happening and stop() never runs here.
    local back = sdec.buf_restore()
    if back ~= nil then ulog.line('launch refused, so capacities handed back: ' .. back) end
    sdec.lasterr = why
    ulog.line('start refused: ' .. why)
    return false, why
  end
  -- THE STATIC BUFFERS, HERE AND NOWHERE ELSE. One record and twelve scratches, allocated once for the
  -- app's life, so a running session performs no buffer allocation or release at all -- a mode change
  -- from the 240-byte frame to 8 kB or 32 kB is a clear and nothing else. The reason is stability: every
  -- allocation that used to happen mid-session was a fault surface the app could not retry its way out
  -- of, and docs/UNDOCUMENTED.md records that a deleted 6 000 000-reading buffer is not free by the time
  -- the next call asks. sdec.stop() is the matching release.
  --
  -- One buffer per mode, each oversized for the worst case its own mode can ask for, totalling the
  -- operator's 6 500 000-reading budget with the twelve scratches. Sized per mode rather than shared
  -- because position is a percentage of CAPACITY: on one big buffer a 240-byte frame's reserve would need
  -- a fractional position nobody has ever loaded on this instrument. See sdec.acq_bufplan.
  -- One build per power cycle unless the teardown was clean: a second ui_build() over live objects needs
  -- the front-panel POWER button. delfails is the only thing that refuses; allow_rebuild opts out.
  if sdec.built then
    -- And the default buffers stay reclaimed across it, because the ceiling was derived from the reclaimed
    -- sizes. docs/MEASUREMENTS.md, 'Buffer capacities across a relaunch'.
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
  -- AFTER THE REBUILD, AND THAT ORDERING IS THE WHOLE OF IT. Allocated before the `sdec.built` branch
  -- above, this set was torn straight back down: a relaunch runs sdec.cleanup() in there, cleanup frees
  -- the static buffers, and start() then returned reporting success with nothing allocated. The app ran
  -- on per-capture allocation while the log said 'static buffers: 2 of 2'. test_serial caught it as a
  -- capture that allocated a buffer when the design says none ever should.
  -- Before the allocations, not after. quiet_events() was reached only through hw_config(), which start()
  -- does not call on the way here, so every launch-time buffer.make that the pool refused could file a 4919
  -- with popups still live. The ladder took that from 14 attempts to 20, and docs/UNDOCUMENTED.md records
  -- which codes raise a dialog as unresolved -- so this is cheap insurance on a path the operator watches.
  sdec.quiet_events()
  local binit, bwhy = sdec.acq_bufinit()
  if not binit then
    -- Not a refused launch: acq_make_buffer still allocates per capture for whichever mode is missing
    -- one, so the app runs with the old behaviour rather than not at all. Logged because it is the one
    -- condition that silently reinstates every allocation this was meant to remove.
    ulog.line('static buffers unavailable, falling back to per-capture allocation: ' ..
              tostring(bwhy))
  else
    -- THE FRAME RUNGS ARE ON THIS LINE, because a ladder that came up short is the difference between a
    -- capture storing 1.1x what it asked for and 2.6x, and nothing else reports it: acq_rungok was written
    -- and read by nothing at all, which is the same fault as a field set in the bench row and never
    -- serialised. Read at launch, so it is the count as allocated -- acq_framefit evicts a dead rung on any
    -- later capture, so the live figure can fall below this one without the ladder being at fault.
    ulog.line(string.format('static buffers: %s of %s, %s of %s frame rung(s), %s scratch(es), %s in force',
                            tostring(sdec.acq_bufnok), tostring(sdec.acq_bufplan.n),
                            tostring(sdec.acq_rungok), tostring(sdec.acq_rungwant),
                            tostring(sdec.acq_scrgot), tostring(sdec.acq_bufgot)))
  end
  -- Set before ui_build(): a build that fails halfway is the dangerous state, so it counts as an attempt.
  sdec.built = true

  local ok, err = pcall(function()
    ulog.tag = 'SDEC'
    -- Once, here, and not per write: confirming the directory reads the whole 64 kB FAT table.
    ulog.ensuredir()
    ulog.open(sdec.logpath)

    -- What the launch took, first because it is the destructive half: the only record that it was theirs.
    if (sdec.ck_swept or 0) > 0 then
      ulog.line(string.format('swept %d readings of buffers this app did not make: %s',
                              sdec.ck_swept, tostring(sdec.ck_sweptwhat)))
    end
    if sdec.ck_reclaimwhat ~= nil then
      ulog.line('reclaimed ' .. sdec.ck_reclaimwhat
                .. ' -- the resize discarded the readings those buffers held')
    end

    -- The derived ceiling, logged because a short recording is otherwise unexplainable afterwards.
    if sdec.ck_bigbuf == nil then
      ulog.line(string.format('recording ceiling: %d readings -- the default buffer capacities '
                              .. 'could not be read, so this is the static ceiling',
                              sdec.ck_bufmax))
    else
      ulog.line(string.format('recording ceiling: %d readings of %d, %s at %d, margin %d',
                              sdec.ck_bufmax, sdec.ck_bufpool, sdec.ck_bigbuf,
                              sdec.ck_bigcap, sdec.ck_bufmargin))
    end

    -- Before anything touches the digitizer, and after the rebuild guard, which restores the entry mode.
    if sdec.mode_save() then
      ulog.line('entry mode: ' .. tostring(sdec.entrymode.side) .. ' '
                .. tostring(sdec.entrymode.func) .. ' -- restored on exit')
    else
      ulog.line('entry mode could not be read -- exiting will leave the digitize function selected')
    end

    -- Every detection setting back to automatic, before the options screen is built from them: `sdec`
    -- outlives an app run, so a launch would inherit whatever the last session pinned. Logged.
    sdec.reset_options()
    ulog.line('options reset: proto uart, FRAME mode, text view, baud auto, bits auto 7/8, '
              .. 'parity auto, polarity auto, trigger Start bit, rear BNC off')

    -- The cancel key, wired once: every long job polls the latch this arms.
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

  -- Do not put a capture here: on 1.7.17a one taken from inside this function bluescreens the instrument
  -- at PC 001CF3C8 from internal memory. docs/MEASUREMENTS.md, 'The launch capture and the pcall budget'.
  return true
end

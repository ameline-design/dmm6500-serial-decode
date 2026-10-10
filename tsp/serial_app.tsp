-- serial_app.tsp -- lifecycle, touch handlers and capture orchestration for the
-- Keithley TSP serial decoder (TSP / Lua 5.0.2).
--
-- INSTRUMENT SCOPE. Three things are required: a digitizer reachable as dmm.digitize, the
-- touchscreen app API (display.create and the OBJ_* types), and Lua 5.0.2. The DMM6500, DAQ6510
-- and DMM7510 all have them -- but ONLY THE DMM6500 HAS BEEN TESTED, and every measured figure in
-- docs/ came off that one instrument.
--
-- THE 2400-SERIES SMUs SPLIT, and the series spec sheet hides where. Keithley's family highlights
-- say "1 MSamples/s digitized measurement speed", but the only model whose own section claims
-- digitizers is the 2461 -- "dual 18-bit 1 MS/s". The 2470 manual states digitized measurements are
-- not a feature of that instrument, and the 2450 reference documents smu.measure.* with no digitize
-- anywhere in it. All of those are true at once; a family-level number belonging to one model is what
-- makes them look contradictory. CHECK THE MODEL, NOT THE SERIES.
--
-- So the 2461 is a real candidate and 2450/2460/2470 are not. It still needs a port, because every
-- SMU reaches its measurement subsystem as smu.* rather than dmm.* -- but that port is small and
-- bounded: the app's ENTIRE instrument surface is 14 dmm.* symbols, so one indirection table covers
-- it. Two unknowns would decide how WELL it worked rather than whether it worked. Whether that
-- digitizer exposes an ANALOG TRIGGER -- without one, acq_triggered() already degrades to the
-- free-running path. And what the READING BUFFER accepts rather than what the ADC samples: the same
-- page quotes "100 kS/s to buffer" beside the 1 MS/s figure, and chunk_decode reads captures out of
-- the buffer, so the lower number is the one that would set a baud ceiling. This instrument has the
-- same shape, measured -- ~100 000 readings/s into the buffer against a 1 MS/s digitizer.
--
-- WHERE IT WILL INSTALL is decided separately from whether the code would run, by $Product: in the
-- .tspa header that tools/package_tspa.py writes.
--
-- OBJECT-LIFETIME STANDARD, applied throughout: never create over a live handle.
-- Delete -> nil -> create. Creating over a handle overwrites the only reference to
-- the object beneath and strands it inside the firmware until a power cycle; that
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
-- ALL THREE DERIVE FROM ulog.usbdir, which names the one directory every file goes to. usb_log.tsp is
-- the first module the archive loads, so it is always defined by the time this runs; the fallback is for
-- a bare serial_app.tsp loaded on its own by a harness.
sdec.usbdir    = sdec.usbdir or (ulog ~= nil and ulog.usbdir) or '/usb1/SERDEC'
sdec.logpath   = sdec.logpath or (sdec.usbdir .. '/serial_decode_log.txt')
-- Prefix of THE BYTE LOG, which every mode appends to -- not just FRAME.
sdec.flogpfx   = sdec.flogpfx or (sdec.usbdir .. '/bytes')
sdec.savepfx   = sdec.savepfx or (sdec.usbdir .. '/serial_')
-- MIGRATED, NOT JUST DEFAULTED, for the reason ulog.path is: `or` keeps whatever a previous load left
-- behind, so an App reload over a build that wrote to the key's ROOT would keep writing there with no
-- power cycle to clear it. Only the exact old defaults move; an override set by a harness stays.
if sdec.logpath == '/usb1/serial_decode_log.txt' then
  sdec.logpath = sdec.usbdir .. '/serial_decode_log.txt'
end
if sdec.flogpfx == '/usb1/bytes' then sdec.flogpfx = sdec.usbdir .. '/bytes' end
if sdec.savepfx == '/usb1/serial_' then sdec.savepfx = sdec.usbdir .. '/serial_' end
sdec.saveext   = sdec.saveext or '.txt'
-- Protocol layer sitting on top of the UART bytes: 'uart' (none), 'midi' or 'lin'.
-- Operator state, so `or` like the rest -- an App relaunch must not silently drop
-- back to raw UART on someone who selected MIDI or LIN.
sdec.proto     = sdec.proto or 'uart'
-- PRESS-DRIVEN STREAMING, WHICH THE PANEL DOES NOT USE. true = Capture starts a recording, stops it,
-- then steps the decode a slice per press: TWELVE PRESSES for a full buffer. false = one press does
-- the whole job, and that is what ships.
--
-- THE ONE-PRESS PATH CANNOT BE STOPPED BY A FINGER. Both long loops poll the cancel latch -- the
-- acquisition twice a second, the decode once a window -- but a press on TRIGGER emits no blender event
-- while a panel-initiated run executes, so record_run()'s fc_maxwin/fc_maxsec bounds are the exits.
--
-- The stepped path is driven by test_cancel.lua and test_serial.lua, and is the fallback for a firmware
-- whose blender cannot latch EVENT_DISPLAY.
--
-- A NIL TEST RATHER THAN `or`, because false is meaningful here and `false or true` is true. Set it
-- before this file loads and the setting survives.
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
-- as long as this app is ever willing to be uninterruptible.
sdec.strm_fallback_s = sdec.strm_fallback_s or 20
-- sdec.savedas  -- the last filename written, for the note line
-- sdec.stickyerr -- a fault that must outlive a capture (see install_cleanup)

-- Drop every trace of the previous capture, and return true.
-- Drop a decode result a later pass has invalidated, and nothing else.
--
-- autoset() runs up to three captures per press, and a pass failing at acquire() returns before any
-- decode -- so the previous pass's res, baud and fitq survive while the failed capture has rewritten
-- acq_fs and the levels. Measured: a probe fitting 9600 Bd at 1 MS/s then a failed 80 kS/s pass leaves
-- BAUD 9600 and SA/BIT 104.2 beside RATE 80 kS/s, and 80000/104.2 is 768.
--
-- NOT clear_result(), which also drops probe_note and lasterr -- on this path the only record of why
-- the re-capture happened and what failed. The measurements stay: they belong to the capture that ran.
function sdec.drop_stale_result()
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
  -- clear_result()'s own 'no result' values, so the two cannot disagree: false/0/true, not nil,
  -- because ui_field_colour reads fitq numerically.
  sdec.snapped, sdec.fitq, sdec.snapfirm = false, 0, true
  -- These describe the dropped result; probe_note and lasterr describe this pass.
  sdec.fmt_note, sdec.baud_note, sdec.rate_note = nil, nil, nil
  return true
end

function sdec.clear_result()
  -- CALLED AT THE TOP OF capture(), before anything can fail: acquisition can fail before
  -- decode_from() ever runs, so clearing must not depend on the decode reaching it.
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
  -- THE INTERMEDIATE MEASUREMENTS, which are not results but are what the next search runs ON:
  -- acq_fs, the pulse widths and their median, polarity, and the run statistics. Each has a writer
  -- that only reaches it on the good path, so a capture that fails part-way leaves the previous
  -- capture's figure in place for the next one to build on. See sdec.clear_measured.
  sdec.clear_measured()
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
  -- relocked IS NOT EVICTED HERE, and it is the one exception in this block. A relock happens inside a
  -- press, and its note has to survive to the end of that press: evicting it here would leave correct
  -- bytes and nothing saying the operator's locked rate was dropped, which reads as "EXACT with the
  -- forced rate silently still in force". It is cleared at the top of capture() instead: once per
  -- PRESS, which is what it describes.
  sdec.probe_note = nil                 -- set by autoset() when it had to re-capture slower
  -- The previous capture's 20 000-entry sample table has just become unreachable. Collecting it
  -- here costs 8.3 ms measured, against a 1.6 s capture, and Lua memory pressure is on the
  -- suspect list for this firmware's panics. It does NOT help the DISPLAY object pool -- those
  -- are firmware objects, which del_obj deletes explicitly.
  pcall(collectgarbage)
  return true
end

-- Drop the whole lock -- every forced setting, not just the rate. Returns true.
--
-- ALL FIVE OR NONE. sdec.force_baud is the one with a control of its own, so it is the one that
-- gets cleared by hand, and clearing it ALONE leaves the format pinned: autolock_try() sets nbits,
-- par and nstop together with the rate, so an app that has locked once is still deciding the frame
-- format from the previous capture's answer while appearing unlocked. That cost real bench time --
-- a run labelled "unlocked" was neither, and its disagreement with a clean one read as an
-- intermittent.
function sdec.unlock_all()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  -- The provenance goes with the lock it describes. Left behind, it would claim the app had chosen
  -- fields that are no longer set, and the next back-off would clear whatever was typed afterwards.
  sdec.autolock_set = nil
  return true
end

-- EVERYTHING THE APP AND THE DECODER LEARNED, BACK TO A KNOWN VALUE, before any attempt to
-- determine a baud rate or decode a signal. Returns true.
--
-- Called once per press at the top of capture(). clear_result() plus clear_measured() already run
-- on every internal re-capture; what this adds is the REQUESTED sample rate, which they must not
-- touch: autoset() deliberately carries sdec.fs and sdec.fs_want from its probe pass into its real
-- one, so a per-acquire reset of those would undo the two-pass design and cap every unlocked
-- capture at ~19 bytes.
--
-- fs_select() rather than an assignment, because the deterministic value is not a constant -- it is
-- whatever the current lock and mode imply, which is exactly what that function computes, and
-- computing it in two places is how the two drift apart. The fs_want = nil ahead of it retires any
-- one-shot a previous press left behind.
--
-- WHICH MEANS A CALLER CANNOT PRE-SET sdec.fs_want AND THEN PRESS CAPTURE: this discards it. That is
-- the intent -- a one-shot surviving into the next press is the leak -- and no caller does it:
-- fs_want is written by autoset(), which runs after this, and by tools/bench_priming.py, which calls
-- hw_config() directly. A caller that really wants a rate for one capture should set sdec.force_baud,
-- which is the supported way and which fs_select() reads.
--
-- WHAT IT DOES NOT DO IS UNLOCK. A forced rate is a decision the operator can see on the padlock
-- and must survive a press. A harness that wants a virgin app calls sdec.unlock_all() first -- and
-- should: the state this function clears is only half of what a leftover lock carries.
function sdec.detect_reset()
  sdec.clear_result()
  sdec.fs_want = nil
  sdec.fs_select()
  return true
end

-- ============================================================================
-- Capture orchestration
-- ============================================================================
-- THE ONE ARMED CAPTURE A SILENT LINE GETS. Reached from autoset() when the probe ladder found no
-- transitions and the operator's trigger mode is one that waits. Returns ok, reason.
--
-- NO SECOND PASS AND NO OCTAVE RETRY, which is the whole difference between this and the tail of
-- autoset(). Every other path re-captures once it knows the bit time, because a second window at a
-- better rate is strictly more data. Here it is strictly LESS: the device's opening bytes exist only
-- in the window that caught them, and a re-capture would show whatever it said a moment later while
-- claiming to be the start. So this keeps what it gets, including the pre-trigger samples ahead of
-- the first start bit -- see sdec.pretrig, and docs/TRIGGER.md section 7 for why that reserve is
-- what makes the start recoverable at all.
--
-- THE RATE IS BLIND BY CONSTRUCTION. sdec.arm_fs() trades window against coverage; the note below
-- tells the operator the one thing that beats it, which is locking the rate they already know.
function sdec.arm_capture()
  local fs = sdec.arm_fs()
  -- fs_want as well as fs, for the reason fs_select() documents: acquire() -> hw_config() ->
  -- fs_select(), which resets the rate to fs_default when nothing is locked -- and nothing is locked
  -- here, so without the one-shot this capture would run at 1 MS/s and hold a fifth of the window.
  sdec.fs, sdec.fs_want = fs, fs
  sdec.probe_note = string.format(
    'armed at %g kS/s on a line that has not started -- lock the baud rate for a longer window',
    fs / 1000)
  local ok, why = sdec.acquire()
  -- Before any decode, so a failed arm cannot leave the probe's fit beside this capture's rate. Same
  -- drop, and the same reason, as the two in autoset() below.
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  if dok then return true end
  -- NOTHING FITTED, SO TRY WHAT THE WIRE PROBABLY IS -- over these samples, not a new capture.
  if sdec.arm_fit_prior() then return true end
  sdec.drop_stale_result()
  return false, dwhy
end

-- IS THIS CANDIDATE BIT TIME COMPATIBLE WITH THE PULSES ACTUALLY ON THE WIRE? The filter the prior
-- ladder applies BEFORE spending a decode, and it is the detector's own battery -- three tests
-- measured over 368 640 paired decodes -- rather than anything invented for this path.
--
-- WITHOUT IT THE LADDER IS UNSAFE, and the frame gate cannot rescue it. Measured here, 1800 bytes of
-- text at each rate, every candidate forced against every truth: a 19200 line read at 9600 frames 77
-- bytes with SIX errors -- a bad fraction of 0.082, comfortably inside the gate -- and the bytes are
-- garbage. A 31250 line read at 28800 gives 258 frames and ZERO. The reason is structural: half the
-- true rate reads two real frames as one, and the real stop bit lands exactly where the hypothesis
-- looks for its own, so the one check that would notice agrees. This filter is what rejects 10 of
-- those 30 pairs before a decode is spent on them, 9600 against every truth from 28 800 up.
--
-- WHICH TEST CATCHES WHICH DIRECTION. ua_plausible refuses a bit time longer than 1.15x the median
-- pulse, which is what a HALVED baud rate claims -- that most pulses are shorter than one bit.
-- ua_submultiple and ua_minrun_absurd cover the other direction, a candidate that is a sub-multiple
-- of the truth. Unconditionally here, unlike in ua_best_probe: every entry in sdec.arm_try is a
-- standard rate by construction, so there is no unsnapped fit whose halving they could suppress.
-- AND IT FAILS CLOSED WITH NO EVIDENCE, which is not a formality. All three tests answer "no
-- objection" to a missing width array -- ua_plausible skips its median test when wmed is nil, and
-- both sub-multiple tests return false below submult_minpulses -- so a caller reaching here before
-- sig_bittime() has run would have every candidate waved through by the absence of data. MEASURED
-- exactly that way: the first version of this filter was tested with sig_bittime stubbed out, which
-- is also what computes the widths, and it rejected nothing at any truth while appearing to work.
function sdec.arm_try_ok(T, n)
  if T == nil or T <= 0 then return false end
  if sdec.wmed == nil or sdec.wmed <= 0 then return false end
  if (sdec.nw or 0) < sdec.submult_minpulses then return false end
  if not sdec.ua_plausible(T, n) then return false end
  if sdec.ua_submultiple(T) then return false end
  if sdec.ua_minrun_absurd(T) then return false end
  return true
end

-- HOW CLEAN A GUESSED RATE HAS TO DECODE, as a fraction of interior frames in error.
--
-- FAR TIGHTER THAN relock_badfrac, AND NOT INTERCHANGEABLE WITH IT. That threshold answers "has the
-- operator's typed rate been discredited?", where a false alarm throws away a deliberate setting, so
-- 0.25 is slack on purpose. This one answers "may the app invent a rate nobody asked for?", where a
-- false pass is a panel full of confident rubbish. The two numbers are opposite in spirit and sharing
-- one was a measured mistake: at 0.25 a 57 600 Bd line -- which this sample rate cannot resolve well
-- enough to decode at all -- was published as 38 400, on a bad fraction of 0.245.
--
-- MEASURED over every (truth, candidate) pair in the ladder, 1800 bytes of text each: a CORRECT rate
-- gives a bad fraction of exactly 0.000 in every case -- AND SO DO THREE WRONG ONES. 31250 read at
-- 28800, and 38400 read at either 28800 or 31250, each frame 318 of 318 frames with no error; only
-- the bytes differ. The wrong rates a slack gate admits otherwise come in at 0.082, 0.209, 0.239 and
-- 0.247. So the populations are NOT separable by this measure alone: the threshold is what buys the
-- correct answers and uniqueness is what prevents the wrong ones, and neither substitutes for the
-- other. Uniqueness at 0.25 still published 38 400 for a 57 600 Bd line.
--
-- 0.02 RATHER THAN ZERO, because a real wire is not the generator: window edges and jitter leave a
-- few framing errors, and demanding literally none would refuse correct answers on marginal captures.
-- Two per cent of a 350-frame window is seven frames.
sdec.arm_badfrac = 0.02

-- IS THIS DECODE CLEAN ENOUGH TO PUBLISH AN INVENTED RATE ON? Enough frames to be evidence at all,
-- and almost none of them broken.
--
-- WHY A GATE IS NOT OPTIONAL HERE. A wrong bit time will still frame bytes; what it cannot do is
-- frame most of them cleanly. The frame floor is relock_minframes, which is the same question in both
-- places -- how many frames before a fraction means anything -- unlike the fraction itself.
function sdec.arm_fit_ok()
  local r = sdec.res
  if r == nil then return false end
  if (r.nf or 0) < sdec.relock_minframes then return false end
  local bf = sdec.ua_badfrac(r)
  if bf == nil then return false end
  return bf < sdec.arm_badfrac
end

-- FIT THE OPERATOR'S PRIOR TO SAMPLES ALREADY IN HAND. Called by arm_capture() when a blind armed
-- capture caught the device's first bytes and no bit time could be measured from them. Returns
-- whether EXACTLY ONE of sdec.arm_try frames those samples cleanly -- which is the only condition
-- under which a guessed rate may be published.
--
-- THE FIRST CANDIDATE THAT FITS IS NOT THE ANSWER, AND THE MEASUREMENT IS BRUTAL. 1800 bytes of text
-- at each ladder rate, every candidate forced against every truth, with the pulse-width filter in
-- force: taking the first fit gave the WRONG rate for five of the six truths. A 19200 line read at
-- 9600 frames 77 bytes with six errors -- a bad fraction of 0.082, well inside any sane gate -- and
-- a 31250 line read at 28800 frames 258 bytes with ZERO. Clean frames at a wrong rate are not an
-- edge case here; they are the normal outcome, because half the true rate reads two real frames as
-- one and lands its stop bit exactly where a real stop bit is.
--
-- SO THE TEST IS UNIQUENESS, and it is what makes the path safe rather than merely gated. Every
-- surviving candidate is decoded, and a rate is published only when it is the ONLY one that fits.
-- Against the same matrix that gives three correct answers -- 9600, 19200 and 28800, which covers the
-- rates a bench is most likely to be running -- and three correct refusals, with no wrong answer
-- anywhere. Of the four combinations of rule and threshold measured, this is the only one with no
-- wrong answer: first-fit at the slack gate is wrong five times in six, first-fit at this gate twice,
-- and uniqueness at the slack gate once. A refusal costs the operator a note; a wrong rate costs them
-- a panel full of confident rubbish.
--
-- ALL CANDIDATES ARE DECODED, deliberately, instead of stopping at the first fit: the second fit is
-- the whole verdict. Five decodes of one capture is CPU and nothing else -- no instrument time, no
-- re-capture, and no byte of the start traded for the attempt.
--
-- decode_from(), NOT decode(). decode() exists to second-guess a forced rate: with force_baud set
-- and a bad fraction over the threshold it unlocks, re-decodes and keeps whichever won -- which is
-- exactly the wrong machinery here, because the "lock" is this function's own hypothesis and the
-- measurement it would fall back on is the one that already failed.
--
-- THE OPERATOR'S OWN LOCK IS RESTORED WHICHEVER WAY THIS ENDS, and on this path it is nil by
-- construction: autoset() only reaches an armed capture when nothing was forced. Restored anyway,
-- because a function that borrows a field the panel displays has to put it back.
function sdec.arm_fit_prior()
  local rd, n = sdec.smp, sdec.nread
  if rd == nil or n == nil or n < 2 then return false end
  local fs = sdec.acq_fs or sdec.fs
  if fs == nil or fs <= 0 then return false end
  -- THE WIDTHS ARE THIS FUNCTION'S EVIDENCE, SO IT MEASURES THEM ITSELF. sdec.w, nw, wmed and wshort
  -- are computed inside sig_bittime() and belong to one capture; arm_try_ok() judges every candidate
  -- by them. Inheriting whatever ran last is not a hypothetical -- a harness that called this after
  -- acquire() but before any decode had the PREVIOUS capture's median pulse reject the true rate of
  -- this one. Its return value is deliberately ignored: this is reached precisely because no bit time
  -- fits, and the pulse widths are set on the way to that answer.
  sdec.sig_bittime()
  local was, won, alt = sdec.force_baud, nil, nil
  -- WRAPPED, BECAUSE decode_from CAN RAISE. ua_note_fmt raises from inside it on a result with no
  -- surviving format, and both restores below sit after the call -- so a raise left the operator's
  -- Auto silently converted into a hard lock at a guessed rate, displayed on the panel as their own
  -- setting. Measured by stubbing the raise. The pcall is around the LOOP rather than each candidate:
  -- a raise means the samples defeated the decoder, and the next hypothesis will not do better.
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
    -- AMBIGUITY IS AN ANSWER, AND A USEFUL ONE. It names the two rates the capture cannot tell apart,
    -- which is exactly what the operator needs to resolve it from the one piece of knowledge the
    -- instrument does not have. 'no frame format fits' would have been both less true and less help.
    sdec.probe_note = string.format(
      'this capture fits %d Bd AND %d Bd equally -- lock the rate in Options to decide', won, alt)
    return false
  end
  -- RE-DECODED AT THE WINNER, because the loop left sdec.res holding whichever candidate it tried
  -- last. Publishing without this put the final candidate's bytes on the panel under the winner's
  -- rate -- the two agree only when the winner happens to be last.
  sdec.force_baud = won
  -- GUARDED LIKE THE LOOP, AND FOR THE SAME REASON: this call can raise too, and it is the one with
  -- the operator's field already overwritten -- so a raise here was what actually stranded Auto as a
  -- hard lock at a guessed rate. Wrapping only the loop fixed half of it, which the test caught.
  local ok = false
  pcall(function() ok = sdec.decode_from(rd, n) end)
  sdec.force_baud = was
  if not ok then return false end
  -- THE PANEL MUST NOT PRESENT AN ASSUMPTION AS A MEASUREMENT. Every other route to a baud rate on
  -- this display either measured it or had it typed in; this one guessed, uniquely and cleanly, and
  -- the operator is still the only one who can confirm it.
  sdec.probe_note = string.format(
    'no bit time could be measured -- decoded at an ASSUMED %d Bd; lock the rate to be sure', won)
  return true
end

-- Pick the sample rate, capture, and decode. Returns ok, reason.
function sdec.autoset()
  local target = sdec.force_baud
  local captured = false
  -- PER CALL. uart_decode's own comment says baud_probe is "set only by giveup(), and only for THIS
  -- call", and that only held when a decode ran: an acquisition failure never reaches decode_from(),
  -- so a retracted rate outlived its press. Measured -- a stale 300 turned three failed probe looks
  -- into a fourth capture at 300 Bd.
  sdec.baud_probe = nil

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
    -- Raising `position` does not help either: the template's post-trigger count is
    -- (100 - position)% of the buffer's CAPACITY -- see sdec.n_deliv -- so a reserve long enough at
    -- 1 MS/s costs two thirds of the depth.
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
    -- REGISTERED FOR THE BOUNDARY rather than guarded here. A raise out of acquire() would leave
    -- trigmode on 'free' for the session, so sdec.guard restores whatever is parked here -- which
    -- is a field it can see, where savetrig is a local it cannot.
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
      -- A no-op on a fresh press, where detect_reset() has already cleared. It matters on capture()'s
      -- back-off, which calls autoset() again without one: the unlocked decode's result is still live.
      if sdec.baud_probe == nil then
        -- A LINE THAT HAS NOT STARTED IS NOT A PROBE FAILURE -- IT IS THE ARMED CASE.
        --
        -- The ladder above ran free-running, by design, on a line with no transitions on it. That is
        -- precisely the starting condition arming from silence exists for: the device transmits when
        -- it is powered on, or when something happens to it, and until then there is nothing any
        -- probe can measure. So a probe that found nothing is EVIDENCE FOR an armed capture rather
        -- than grounds for refusing one.
        --
        -- MEASURED ON THE INSTRUMENT, which is why this is a branch and not a comment. With the rate
        -- left automatic a press on a silent line returned in 3.55 s saying 'line is idle'; with the
        -- rate LOCKED the identical press armed and waited the full 10 s, and with the generator
        -- switched on mid-wait it fired early and read 21 100 samples. The mechanism worked
        -- throughout and its default configuration never reached it.
        --
        -- STILL REFUSED WHERE THERE IS NOTHING TO WAIT FOR: free run does not wait, and a
        -- flow-controlled capture's line is quiet because no credit has been spent yet, not because
        -- the device has not started -- see sdec.arm_silent.
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
  -- A BARE CALL, DELIBERATELY: this path carries ONE pcall and it is sdec.capture()'s. Wrapping
  -- each step cost a nesting level the firmware cannot afford -- see the depth note in start() --
  -- and sdec.capture() does the same drop for a raise that these lines do for a false return.
  local ok, why = sdec.acquire()
  -- Before any decode, so without the drop the probe's baud and fit stay beside the failed capture's
  -- rate. See sdec.drop_stale_result.
  if not ok then sdec.drop_stale_result() return false, why end
  local dok, dwhy = sdec.decode()
  if not dok then sdec.drop_stale_result() return false, dwhy end

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
        target or 0, sdec.baud or 0, w2 / 1000)
      sdec.fs, sdec.fs_want = w2, w2
      local ok2, why2 = sdec.acquire()
      -- Same reason as the second pass above: this returns before the re-decode, so the result being
      -- replaced must not outlive the capture that was meant to replace it.
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
  -- A DIFFERENT KEY NEEDS A DIFFERENT NAME. ulog.keygen bumps when a key is inserted after one was
  -- gone; the name chosen on that key may already be in use on this one, and MODE_APPEND would
  -- silently extend a stranger's file.
  --
  -- THE ASK COMES FIRST, or the guard cannot fire on its own. keygen only advances when something
  -- calls ulog.keyok(), and the only such thing inside this function is ulog.next_free() -- below,
  -- and skipped entirely on the one path the guard exists for, where flog_path is already set. So
  -- the compare was between two equal values, and the guard worked only because capture_run()'s
  -- ulog.resume() and the panel tick both happen to ask first. Called from anywhere else -- or if
  -- either of those moves -- a swapped key appended into a stranger's file and reported success.
  ulog.keyok()
  if sdec.flog_keygen ~= (ulog.keygen or 0) then
    sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
    sdec.flog_keygen = ulog.keygen or 0
  end
  if sdec.flog_path ~= nil then return sdec.flog_path end
  -- LAZY: the scan is 1000 file.open calls, and allocating at power-on would burn a filename
  -- per session whether or not anything was ever captured. next_free makes the directory first.
  sdec.flog_path = ulog.next_free(sdec.flogpfx, '.txt', 1000)
  if sdec.flog_path == nil then
    -- NAME THE REASON next_free GAVE. It refuses for three different reasons and only one of them is
    -- the names running out -- with no key it does not probe at all -- so a flat 'no free name' put
    -- the wrong sentence on the note row for the commonest case of the three.
    --
    -- NO ' -- NOT LOGGING' SUFFIX. ui_notes already prefixes 'NOT LOGGING: ', so appending it made the
    -- row say it at both ends and pushed the longest reason past what the cell can show. The leaf
    -- name alone for the same reason: the directory never varies.
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
  -- open_write, NOT file.open: it carries the no-key gate and the reason string, so a missing key is a
  -- silent refusal rather than an event. It does NOT recover from a key swapped since the name was
  -- allocated -- that is unsupported and reported, not worked around.
  local fh, fwhy = ulog.open_write(sdec.flog_path, file.MODE_APPEND)
  if fh == nil then
    sdec.flog_why = 'cannot append to ' .. tostring(sdec.flog_path)
    return false
  end
  -- REGISTERED FOR THE UNWIND. A FORMATTER is what can raise on this path -- a file call cannot,
  -- measured -- and a raise out of one would otherwise strand this handle until a power cycle;
  -- sdec.unwind closes whatever is parked here.
  sdec.fh_unwind = fh
  -- COUNTED AFTER THE WRITE, never before: a raise part-way through would otherwise bump flog_n and
  -- flog_bytes anyway, so the panel's "bytes in the log" would count bytes that never reached the
  -- file. The whole promise of that number is that it says what is safely on the key.
  local nfr = 0
  if sdec.res ~= nil then nfr = sdec.res.nf end
  -- The message NUMBER is needed for the header line before the write, but flog_n itself is
  -- not advanced until the write succeeds -- so a failed message does not consume a number.
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
  -- THE PRESENCE CHECK IS THE WHOLE TEST. A write that posted 2200 returns normally (see
  -- ulog.keylost), so nothing the writes themselves report can see a key pulled since the open --
  -- this capture's bytes would be counted as logged. 237 us with a key in the slot, and it latches
  -- logging off on the way past.
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
  -- AN ARMED RECORDING NEEDS THE PRE-TRIGGER RESERVE ON TOP OF THAT, for the reason acq_cap()
  -- records for the frame path: LoopUntilEvent takes its reserve out of CAPACITY and programs
  -- (100 - position)% of capacity as the post-trigger count -- so a buffer sized at nsmp records
  -- 5 % less than was asked for. Sized this way the post count is nsmp or a little over, and
  -- `have >= nsmp` still means what it says.
  --
  -- ASKED FOR ON TRIGGER MODE ALONE, not on sdec.arm_silent(), and that is forced by the ordering:
  -- the probe that decides whether the line is silent reads INTO this buffer, so it cannot be
  -- consulted before the buffer exists. The cost of asking when the arm then does not engage is 5 %
  -- of readings left unused in a buffer that is deleted at the end of the run.
  if sdec.trigmode ~= 'free' and (sdec.pretrig or 0) > 0 then
    cap = math.ceil(nsmp * 100 / (100 - sdec.pretrig)) + 100
    -- AND THE RESERVE COMES OUT OF THE RECORDING WHERE THE INSTRUMENT HAS NO ROOM FOR IT. ck_bufmax
    -- is what the reading memory holds; overrunning it would turn the largest recording modes into
    -- an allocation refusal, which is a worse answer than a recording 5 % shorter.
    if sdec.ck_bufmax ~= nil and cap > sdec.ck_bufmax then
      cap = sdec.ck_bufmax
      nsmp = math.floor(cap * (100 - sdec.pretrig) / 100)
    end
  end
  -- THE 6 000 000 READING CEILING IS FOR ALL BUFFERS TOGETHER, so buffer.make() at these sizes
  -- can need defbuffer2 shrunk first, which is what the refusal below says.
  -- A BARE CALL: acq_make_buffer() guards buffer.make() itself and leaves sdec.buf nil when the
  -- allocation was refused, which is the condition tested below.
  sdec.acq_make_buffer(cap)
  if sdec.buf == nil then
    return false, string.format('cannot allocate %d readings -- shrink defbuffer2', cap or 0)
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
  --
  -- CLEARED FIRST, because sdec.arm_silent() reads it and the previous capture's answer is not this
  -- recording's: a frame capture of a silent line followed by Capture on a busy one would otherwise
  -- arm this recording on an inherited verdict.
  sdec.probe_idle = nil
  -- AND THE ARM PAIR WITH IT, for the reason clear_measured() gives: this path does not go through
  -- clear_measured(), so a pair from a previous capture would arm this recording at that capture's
  -- level on that capture's edge.
  sdec.arm_thr, sdec.arm_idle = nil, nil
  local pok = pcall(sdec.acq_free, pn, nil, true)
  if pok and sdec.nread ~= nil and sdec.nread > 1 then
    local lok, lwhy = sdec.sig_levels(sdec.smp, sdec.nread)
    -- ONLY ARM THE WATCHDOG IF THE LEVELS ARE REAL. An unknown threshold must never be allowed
    -- to end a recording: a capture that runs to the end of the buffer is recoverable, one
    -- truncated to five seconds of a four-minute session is not.
    if lok and sdec.thr ~= nil and (sdec.swing or 0) >= sdec.minswing then
      sdec.ck_watch = true
    else
      -- A PROBE THAT SAW NO TRANSITIONS IS THE ARM-FROM-SILENCE CASE, and recording it here is what
      -- lets a recording wait for a device that has not started -- sdec.arm_silent() is the one
      -- predicate both paths read, and nothing on this path used to set the field behind it.
      --
      -- ONLY FOR A PROBE THAT RAN. A capture that raised or came back empty is a FAULT, not a quiet
      -- line, and treating it as one would arm a 120 s wait on a broken digitizer.
      sdec.probe_idle = lwhy or 'line is idle (no transitions)'
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
  -- THE ARM LEVEL IS COMPUTED WHATEVER THE REUSE DID, and the guard that used to skip it was the
  -- whole of a measured defect: `not sdec.strm_lvlreuse` meant that on any recording following a
  -- successful decode -- which is most of them -- arm_threshold() never ran, and the comparator was
  -- armed at the LAST DECODE'S midpoint. Measured on the instrument: 1.63 V on a 0-3.29 V line, which
  -- is mid-data, so the arm would fire on a data edge rather than on a start bit; and on a first
  -- capture it inherits clear_result()'s zero and fires on ADC noise.
  --
  -- THE REUSED THRESHOLD IS PUT BACK, because the two numbers answer different questions:
  -- arm_threshold() publishes sdec.arm_thr for the comparator, and the idle watchdog and the chunked
  -- decode want the measured midpoint -- this wire, minutes ago -- rather than idle plus Arm At.
  if sdec.probe_idle ~= nil then
    local kthr, khyst, kidle = sdec.thr, sdec.hyst, sdec.idle
    if sdec.arm_threshold() and sdec.strm_lvlreuse then
      sdec.thr, sdec.hyst, sdec.idle = kthr, khyst, kidle
    end
  end
  -- THE LUA COPY GOES; THE COUNT STAYS. sdec.nread is what a finished run is reported BY --
  -- run_app.py prints it as a headline field -- and zeroing it here published 0 beside 5 487 decoded
  -- bytes, because record_run() opens the next window before the operator reads anything. Nothing
  -- reads it between here and stream_settle(), which overwrites it with the count that matters.
  sdec.smp = nil

  -- ck_stop = false HERE, on entry, is the authoritative clear -- mode_exit() can leave it set
  -- after requesting a stop the loop never got round to seeing, and no unwind path clears it.
  -- Without this line the next run aborts before its first window with 'stopped'.
  sdec.ck_running, sdec.ck_stop, sdec.ck_nbytes, sdec.ck_tot = true, false, 0, nil
  sdec.ck_endwhy = nil
  -- PER RUN, beside ck_endwhy, which is the field it qualifies: a level left behind by a previous
  -- expired arm would be quoted at the next one, which is the whole defect it exists to fix.
  sdec.arm_expired_at = nil
  -- ck_cancel IS CLEARED HERE, not in record_run(), because EVERY run of either shape comes through this
  -- function. ck_progress() sets it on the press-driven path as well, and record_run() is not on that
  -- path -- so clearing it there would leave a cancelled run's flag set for the next press-driven
  -- recording, whose note row would then credit the TRIGGER key for a run stopped with Capture.
  -- clear_result() does not clear it either, so it would survive frame captures too.
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
    return false, 'recording failed: ' .. tostring(ares or 'unknown')
  end
  if got < 2 then
    sdec.strm_empty = true
    return false, 'long capture returned nothing'
  end
  -- A CANCEL DURING THE RECORDING STOPS THE RECORDING, NOT THE BYTES IT COLLECTED. ck_stop is still
  -- set here, and ck_progress reads it as "abort" -- so the decode below would end at window zero
  -- and throw away everything the operator has just waited for. TRIGGER means "stop what is happening
  -- now", and what happens next is the decode of what was captured.
  --
  -- NOT FOLLOWED BY A cancel_clear(). The latch auto-resets on the read that saw the press, so it is
  -- already empty -- and clearing it again discards a SECOND press made during stream_settle(),
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
  -- THE TIMER IS ALWAYS PRESENT ON THIS INSTRUMENT, so taking it needs no guard and no "did we get
  -- it" flag. The counter below is not a fallback for an absent clock; it is the floor for a
  -- CLOBBERED one, which is a different failure and still real.
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
  timer.cleartime()
  -- PAINTED AFTER THE CLEAR ABOVE AND BEFORE THE FIRST WINDOW. It is the last full refresh until the
  -- run ends -- sdec.progress() repaints only the counter -- so the control cell it writes stands for
  -- the whole run, which is why it must be painted at all. That cell reads 'no stop until it ends' and
  -- invites no press. The clear still belongs ABOVE it: cancel_clear() must discard the previous run's
  -- press before this run can be cancelled by anything at all.
  sdec.ui_refresh()
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
    -- than to no bound at all.
    local el = sdec.fc_secs
    local t = timer.gettime()
    if t ~= nil and t > el then el = t end
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
  -- stream_arm's OWN VERDICT, not a pcall's. It guards its firmware writes itself and returns
  -- false for a model that refused the configuration, which a pcall around it reports as success.
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
  -- THE ONE pcall LEFT AROUND AN sdec.* CALL ON THIS PATH, and it is here because the RAISE TEXT is
  -- the reason the operator is given: serr becomes the message below. stream_settle() guards its own
  -- buffer read and reports that failure as its second return, which is the gerr branch; this catches
  -- what no guard inside it can, a raise from the function itself. tools/test_cancel.lua installs a
  -- raising stream_settle at this seam to pin the readfail verdict against both.
  -- pcall(sdec.stream_settle) RATHER THAN A CLOSURE: its two returns arrive as the second and third
  -- results, and on a RAISE the second is the message instead -- so they are copied out only when
  -- the call actually returned.
  local sok, s1, s2 = pcall(sdec.stream_settle)
  if sok then got, gerr = s1, s2 end
  sdec.ck_running = false
  -- A SETTLE THAT FAILED IS NOT AN EMPTY RECORDING, and it must not be stamped 'stopped'. The abort or
  -- the buffer read failed, which is a fault; discarding the reason and publishing the normal
  -- operator-stopped sentinel reports it as "you stopped it and it collected nothing" -- the operator
  -- blamed for a hardware failure. Same shape as the acquisition raise in stream().
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
  -- One window at a time, appended to the byte log FRAME also appends to -- not a per-run
  -- streamNN.txt. sdec.smp is released by ck_run, so the high-water mark is one window
  -- whatever the capture length.

  -- THE FILE IS OPTIONAL; THE DECODE IS NOT. flog_alloc() returns nil with no key in the slot, with
  -- an unwritable one, or with all 1000 names taken -- and refusing here made both recording modes
  -- acquire a buffer and then decode NOTHING, while frame mode went on showing bytes from the same
  -- wire. docs/MANUAL.md promises the opposite: "the app works perfectly well without a key; you
  -- simply get no log and no report."
  --
  -- A nil path skips the file sink (ck_job_sinks builds one only when path ~= nil) and leaves the
  -- tail ring, so the panel still gets the last sdec.ck_keep bytes -- the whole of an 8 kB recording.
  -- flog_why carries the reason to the note row either way.
  local path = sdec.flog_alloc()
  -- nocap MUST BE SET EXPLICITLY, because Lua cannot tell "key absent" from "key = nil" and
  -- ck_decode reads `if maxbytes == nil and not opts.nocap then maxbytes = sdec.ck_maxbytes end`.
  -- md.cap = nil means UNLIMITED, so without nocap such a mode silently inherits the 32768
  -- default: the panel promises "no cap, until Stop or a quiet line" beforehand and reports a
  -- cap afterwards, discarding bytes already in the buffer.
  local opts = {maxbytes = md.cap, nocap = (md.cap == nil),
                progress = sdec.ck_progress}
  -- HOW MUCH SILENCE THIS RECORD MAY OPEN WITH, which only this path knows and the decoder cannot
  -- derive. An armed recording's record is [pre-trigger reserve][post-trigger burst], the reserve is
  -- the line the arm was waiting on, and the reserve comes out of the buffer's CAPACITY -- so on a
  -- device that started late it is 71 865 readings of silence at the head of a 32 kB recording,
  -- 3.6 windows of 20 000, whatever fraction of the buffer the burst went on to fill. Without this
  -- the format search read one window of the wait and refused the whole recording: MEASURED, 0 bytes
  -- and 'no frame format fits the capture' for a device starting at +3.0 s. See ck_prime_tries.
  --
  -- ONLY WHERE THERE IS A RESERVE. An unarmed recording starts at the trigger, so its record opens on
  -- the traffic that fired it and an allowance would buy nothing but tries.
  --
  -- GUARDED AT THE PROXY READ, like every other attribute read on this object, and the degrade is to
  -- say nothing -- which is the pre-feature bound of two tries rather than a wrong number of them.
  if sdec.strm_armed and sdec.buf ~= nil and (sdec.pretrig or 0) > 0 then
    local cap = nil
    if pcall(function() cap = sdec.buf.capacity end) and cap ~= nil then
      -- THE INSTRUMENT'S OWN RULE, not a percentage of it: the post-trigger count is made in full and
      -- the reserve is what is left over -- see the measurement in sdec.n_deliv.
      opts.leadmax = cap - math.floor(cap * (100 - sdec.pretrig) / 100)
    end
  end
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
    -- THESE TWO ARE GLOBALS AND THIS PATH CANNOT RESTORE THEM: the decode_step() calls that follow
    -- still need the narrowed W, so it has to outlive this function. The one-shot branch below
    -- therefore asserts its own values rather than trusting what it inherits, which is what closes
    -- the leak -- see the comment there.
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
  -- CLOSE THE SCOPE LEAK AT THE POINT OF CONSUMPTION. The streaming branch above narrows ck_win_n
  -- and ck_level_max and cannot restore them -- later decode_step() calls still need the narrowed
  -- window, and ck_running is cleared in a dozen places, so hooking teardown would risk a half-fixed
  -- state. Asserting the documented one-shot values HERE closes it however the stream ended, and
  -- these are exactly the values chunk_decode says this path wants: the 20000 default, and a nil
  -- latency cap so the one-shot callers and the offline suite keep the full decimated view.
  sdec.ck_win_n, sdec.ck_level_max = 20000, nil
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
                                tostring(tot.stopped), tot.nf or 0)
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
    -- A PRIMING PHASE HAS NO BYTE COUNT YET, and "decoding 0 bytes (window 0/0)" reads as a
    -- decode that found nothing rather than one that has not started. job.phase names the phase
    -- while priming and is nil once the format is known.
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
  -- THE VERDICT GOES WITH THE REASON, and leaving it out was a quiet defect on this path only. The
  -- one-shot caller passes ok and err; this one passed neither, so strm_exit_why's `ok == false` test
  -- could never fire here -- and a decode that returned nothing, or one whose file write failed, fell
  -- through to the acquisition's own ck_endwhy and reported 'buffer full -- the stream may continue'
  -- over a run that had just failed. lasterr holds the sentence both failure branches above wrote.
  local dok = (tot ~= nil and tot.stopped ~= 'write failed' and tot.stopped ~= 'sink')
  sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, dok, sdec.lasterr), not dok)
  sdec.ui_refresh()
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
  tot = sdec.ck_job_abandon(sdec.ck_job)
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
--
-- GUARDED AT ITS OWN FIRMWARE BOUNDARIES, so the verdict is the return value and no caller needs a
-- pcall of its own. buf.clear() and sdec.dig.count are IPC writes to the second processor; a
-- caller that wrapped this instead could not tell a clear() that raised from a model load that
-- refused, and had to read pcall's verdict INSTEAD of this function's -- which is how a refused
-- SimpleLoop came back to stream_start() as a successful arm.
function sdec.stream_arm(nsmp)
  -- CLEARED FIRST, ahead of the four early returns below -- a stale true would have the next
  -- unarmed recording's poll loop waiting for a trigger nothing was armed on. Latent rather than
  -- live, since every one of those returns is a refusal the caller answers with a free-running read,
  -- but the field's own comment promises it is written on both paths and this is what makes that so.
  sdec.strm_armed = nil
  local buf = sdec.buf
  -- NO BUFFER IS A REFUSED ARM, not a raise: the caller's answer to a refusal is a free-running
  -- read, and it can only choose that if it is told rather than unwound.
  if buf == nil then return false end
  -- THE CLOSURE FORM IS REQUIRED HERE, not a style choice: pcall(buf.clear) fetches .clear off the
  -- proxy BEFORE pcall is entered, and that fetch is itself the IPC boundary the header names.
  if not pcall(function() buf.clear() end) then return false end
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
  -- NO DIGITIZER IS A REFUSED ARM, like no buffer above -- and the write is still guarded, because
  -- the header above names sdec.dig.count as an IPC write to the second processor.
  if sdec.dig == nil then return false end
  -- 1 IS SimpleLoop's PER-ITERATION COUNT, and it is wrong for the armed shape even though the
  -- firmware ignores it there: LoopUntilEvent takes its post-trigger count from the buffer's
  -- CAPACITY and dmm.digitize.count has no part in it, measured over 15 combinations. Set to the
  -- recording's own depth anyway, so a reader of the instrument's state is not told that an armed
  -- recording is a sequence of single readings -- which is what acq_triggered() does for the frame
  -- path, and the two should not describe the same hardware differently.
  local dcount = 1
  if sdec.arm_silent() and sdec.trigmode ~= 'free' then dcount = nsmp end
  if not pcall(function() sdec.dig.count = dcount end) then return false end
  -- ===== A RECORDING CAN WAIT FOR THE DEVICE TOO =====
  --
  -- SimpleLoop ACQUIRES THE INSTANT IT IS INITIATED -- it is a counted loop with no wait block in it
  -- at all -- so a recording built on it cannot be armed, and pressing Capture on a device that has
  -- not powered up yet records the silence instead of the message. The same case the frame path
  -- arms for, at 8 kB and 32 kB instead of 20 000 samples.
  --
  -- LoopUntilEvent IS THE CANNED FOUR-BLOCK SHAPE: buffer clear, an INFINITE digitize, the wait, then
  -- a counted burst. The infinite pre-roll is not a nicety here, it is what makes an analog trigger
  -- work at all -- the comparator is derived from the digitizer's sample stream, so with nothing
  -- acquiring it never evaluates. A wait followed by a counted digitize builds cleanly, passes every
  -- static check, sits on the firmware's low-latency fast path, and never fires. See docs/TRIGGER.md
  -- sections 7, 8 and 12.
  --
  -- AND IT KEEPS WHAT PRECEDED THE TRIGGER, which is the other half of why this shape and not a
  -- shorter one: the pre-trigger reserve holds the samples from before the first start bit, so the
  -- recording opens on quiet line rather than halfway through the first byte.
  --
  -- ONLY ON A SILENT LINE, exactly as the frame path decides it -- sdec.arm_silent(). On a line that
  -- is already transmitting SimpleLoop is strictly better: no wait to bound, no reserve to size, and
  -- a trigger that would fire within a byte time anyway.
  local armed = (sdec.arm_silent() and sdec.trigmode ~= 'free')
  local ok = false
  if armed then
    -- The source, the blender and the TRIGGER-key break-in, from the one function that decides them
    -- for both paths. nil means the operator's source is not on this firmware, and the answer is the
    -- same as everywhere else: record free-running rather than silently substitute another source.
    local ev, useanalog = sdec.arm_source()
    if ev == nil then
      armed = false
    else
      -- NO LEVEL AND NO COMPARATOR ARE BOTH REFUSALS, not details. sdec.arm_thr is nil when
      -- arm_threshold() could not find even an idle level -- sig_levels' 'capture is empty' exit
      -- leaves vmax nil and thr at zero, which satisfied the silent test and armed the comparator at
      -- 0 V, where it fires on the first noise sample. Measured, and it is the exact failure
      -- arm_threshold()'s own comment is written about.
      if useanalog and (sdec.arm_thr == nil or
                        not sdec.arm_comparator(useanalog, sdec.arm_slope())) then
        armed = false
      end
      if armed then
        ok = pcall(trigger.model.load, 'LoopUntilEvent', ev, sdec.pretrig,
                   trigger.CLEAR_ENTER, 0, buf)
      end
      -- A REFUSED LOAD IS NOT AN ARMED RECORDING, so it must not be reported as one: the poll loop
      -- would then wait out the arm for a model that is not running.
      if not ok then armed = false end
    end
  end
  -- PUBLISHED FOR THE POLL LOOP, which has to bound the wait and tell an expired arm from a finished
  -- recording. Written on BOTH paths, because a stale true would have the next unarmed recording
  -- waiting for a trigger nothing was armed on.
  sdec.strm_armed = armed
  -- TWO SITES RATHER THAN ONE CLOSURE, and the ordering is preserved by the `and`: a load that
  -- raised must not be followed by an initiate, exactly as the closure's fall-through guaranteed.
  -- Costs one site against the 132 ceiling and saves OP_CLOSURE's allocation on every capture.
  if not armed then ok = pcall(trigger.model.load, 'SimpleLoop', nsmp, 0, buf) end
  if ok then ok = pcall(trigger.model.initiate) end
  -- AN ARM IS NOT LIVE UNTIL THE MODEL IS IN ITS WAIT BLOCK, and that is a promise this function has
  -- to keep rather than leave to the poll loop. MEASURED on 1.7.17a: immediately after initiate() the
  -- model reports STATE_RUNNING with nine readings taken -- it is executing the buffer clear, the
  -- zero delay and the start of the infinite digitize -- and only then does it reach the wait and
  -- report STATE_WAITING. The loop reads "no longer waiting" as "the trigger has fired", so without
  -- this it latched that on its very first poll, the idle watchdog started while the line was quiet
  -- by design, and an 8 kB recording of a device that had not spoken yet ended as 'quiet' with
  -- nothing in it.
  --
  -- BOUNDED AND CHEAP: three blocks of setup, so WAITING arrives in about a millisecond, and the
  -- spin costs one state read per 10 ms against a 0.25 s ceiling. A model that never gets there is
  -- left to the loop, which will time the wait out and say so -- the one thing not done here is
  -- guessing.
  if ok and armed then
    local spun, saw = 0, false
    while spun < (sdec.arm_settle_s or 0.25) do
      if sdec.trig_waiting() == true then saw = true break end
      delay(0.01)
      spun = spun + 0.01
    end
    -- AND THE VERDICT IS CARRIED OUT, because the fallback this comment used to claim did not exist:
    -- the poll loop reads `trig_waiting() ~= true` as "the trigger has fired", so a model that never
    -- reached its wait block was latched as FIRED rather than timed out -- which is the exact
    -- consequence the spin was added to remove. The loop cannot tell "never got there" from "left
    -- it"; this flag can, so an arm that never went live is reported as one.
    if not saw then armed = false end
  end
  sdec.strm_armed = armed
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

-- Stop the hardware and publish what it collected. -> the reading count, and a SECOND return
-- naming the failure when the buffer could not be read at all.
--
-- THE SECOND RETURN IS WHAT KEEPS A FAULT FROM READING AS AN EMPTY RECORDING. buf.n is a proxy
-- read, and a buffer the firmware has dropped raises on it rather than answering 0. Guarded here
-- -- at the boundary -- it would otherwise come back as nread = 0, which stream_stop() reports as
-- 'recording collected nothing': the operator blamed for a hardware failure. So the count and the
-- reason travel together, and mode_exit()/trig_restore(), which only want the hardware stopped,
-- can call this bare.
function sdec.stream_settle()
  pcall(trigger.model.abort)
  local buf = sdec.buf
  sdec.nread = 0
  if buf ~= nil then
    -- GUARDED AT THE PROXY READ, which is what the header above promises a second return for. .n
    -- exists on every non-nil buffer; reading it on one the firmware has dropped raises, and a nil
    -- test cannot see that coming.
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
-- reused threshold is wrong and a better one is now in force, so the caller should keep going.
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
  -- THE REUSED THRESHOLD STANDS until the new levels disprove it, because sig_levels() overwrites
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
  -- sig_levels() CALLED BARE, as sdec.acquire() already calls it: it touches no instrument, every
  -- arithmetic path through it sits behind its own nil check, and it reports a refusal as false
  -- plus a reason rather than by raising.
  local lok = sdec.sig_levels(win, m)
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
                                      .. 'a previous capture measured', sdec.thr or 0, oldthr or 0)
  ulog.line(sdec.strm_releveled)
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
  -- THE RING POSITION LAST LOOKED AT, beside the count. -1 rather than nil so the first pass is
  -- always fresh: index 0 is a legitimate endindex on a buffer with nothing in it.
  local seenend = -1
  local iw = sdec.idle_window(sdec.fs)
  local waited = 0
  -- ===== THE ARM, WHICH THIS LOOP HAS TO BOUND AND HAS TO BE ABLE TO SEE FAIL =====
  --
  -- THE MODEL'S OWN STATE IS THE OBSERVABLE, NOT THE BUFFER, and that is a measurement rather than a
  -- preference. The pre-trigger phase accumulates readings while it waits, so buf.n climbing says
  -- nothing about a trigger: measured on an 8 kB recording armed on a silent line, buf.n settled a
  -- few readings ABOVE its 5 % reserve within milliseconds of initiate(), a buffer-level test read
  -- that as "fired", and the idle watchdog ended the run as 'quiet' with zero bytes one second
  -- later -- three seconds before the device started transmitting. sdec.trig_waiting() asks the
  -- model instead, and answers nil where it cannot be told.
  --
  -- WITHOUT A BOUND OF ITS OWN THE WAIT IS NOT WAITED AT ALL. stream_maxwait is 2 x nsmp/fs floored
  -- at 10 s -- 10 s for an 8 kB recording at 100 kS/s -- so an arm for a device that starts after
  -- fifteen seconds would be cut off at ten and the plateau reported as 'full': a complete recording
  -- of silence. The operator's Arm Wait is added for exactly the span the frame path gives it.
  local armdone = true
  if sdec.strm_armed then
    armdone = false
    -- SAY SO BEFORE BLOCKING, through the same hook acq_triggered() uses: a recording that waits two
    -- minutes behind a static panel is indistinguishable from the unresponsive-panel fault this app
    -- was released to fix. pcall'd and hook-optional for the reasons given there.
    if sdec.armnote ~= nil then
      pcall(sdec.armnote, sdec.arm_wait_s(), sdec.arm_thr or sdec.thr or sdec.arm_level_v(),
            sdec.armkeyed)
    end
  end
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
  -- AND THE ARM'S OWN WAIT ON TOP, AFTER the run-wide ceiling rather than before it: strm_maxsec
  -- bounds the RECORDING, and clamping the sum to it would spend the operator's Arm Wait out of the
  -- recording's time instead of in addition to it -- a 120 s arm would leave a 120 s run with
  -- nothing to record into.
  if sdec.strm_armed then limit = limit + sdec.arm_wait_s() end
  -- THREE WAYS OUT, each recorded in sdec.ck_endwhy so the panel can say which:
  --   full     the buffer reached nsmp -- the cap, or as much as the instrument has
  --   quiet    no threshold crossing for sdec.idle_exit_s. The device stopped talking.
  --   stopped  the operator pressed Capture (Stop) or Mode (abort)
  while true do
    local have = buf.n or 0
    -- THE TRIGGER HAS FIRED ONCE THE MODEL LEAVES ITS WAIT BLOCK, and the model really does report
    -- it. MEASURED on 1.7.17a, one chunk that initiates, delays four seconds INSIDE the instrument
    -- and then reports: STATE_RUNNING with 9 readings at initiate, STATE_WAITING with the buffer FULL
    -- four seconds later, one event (2731, initiated) and no abort. The state is the cheapest and the
    -- most direct observable there is -- one proxy read against four thousand for a window of
    -- samples -- and unlike the data it cannot miss a burst that fell between two polls.
    --
    -- THAT MEASUREMENT TOOK A CONTROL TO GET. Watched from the HOST the same model reports RUNNING
    -- and then ABORTED within half a second, every time, at a variable reading count -- because a
    -- command arriving on the remote interface aborts an initiated trigger model (event 2728). This
    -- loop runs INSIDE the instrument, like the frame path's wait, so nothing arrives while it polls.
    --
    -- Only a definite "waiting" keeps the latch closed: nil means the state could not be told, and
    -- the degrade there is to behave as a recording did before this feature rather than to bound a
    -- wait on a guess.
    --
    -- AND THE QUIET TIMER RESTARTS WITH THE ARM, because everything it counted up to this point was
    -- a line that had not started yet -- carrying that forward ends the run as 'the device stopped
    -- sending' within one poll of the device beginning to send.
    if not armdone and sdec.trig_waiting() ~= true then
      armdone = true
      quiet = 0
      seen, seenend = 0, -1
    end
    -- WHAT COUNTS AS FINISHED DEPENDS ON WHETHER THIS RECORDING WAITED.
    --
    -- AN ARMED ONE IS FINISHED WHEN THE MODEL IS, and that is not a preference either: a pre-trigger
    -- phase that waited longer than the buffer holds has already filled it, so buf.n is pinned at
    -- capacity BEFORE the device has sent a byte -- 0.75 s of wait at 1 MS/s does it for an 8 kB
    -- recording of a 115 200 Bd line. Testing `have >= nsmp` there ends the run on the same poll the
    -- trigger fires, and records the silence it was waiting through.
    --
    -- AN UNARMED ONE KEEPS THE FILL TEST, where the buffer starts empty, nothing has wrapped, and
    -- nsmp means exactly what it says.
    if sdec.strm_armed then
      if armdone and sdec.trig_done(buf) then sdec.ck_endwhy = 'full'; break end
    elseif have >= nsmp then
      sdec.ck_endwhy = 'full'
      break
    end
    -- THE CANCEL LATCH IS READ HERE, twice a second against a poll costing 1.06 ms, so a blended
    -- stimulus can end the wait. A FINGER CANNOT: no blender event reaches this loop from the panel,
    -- so the bounds below remain the guarantee.
    --
    -- BEFORE THE ARM EXPIRY, AND THAT ORDER IS LOAD-BEARING: the TRIGGER key is blended INTO the arm,
    -- so a press both fires the trigger and sets this latch. Tested the other way round, a press that
    -- ended the wait early could be reported as an arm that never fired.
    if sdec.cancel_asked() then sdec.ck_endwhy = 'stopped'; break end
    -- THE ARM EXPIRED: Arm Wait elapsed with the device still silent. Reported as its own ending
    -- rather than as 'full' or 'quiet', because both of those describe a recording that happened.
    if not armdone and waited >= sdec.arm_wait_s() then
      -- THE LEVEL IS STASHED HERE, AT THE EXPIRY, because sdec.thr does not survive to the note. The
      -- reason is printed at the END of the run, by which time record_run() has opened the next
      -- window and its stream_begin() has cleared the measurements -- so the note read 'nothing
      -- crossed -0.00 V', naming a threshold nothing was ever armed at. MEASURED on the instrument.
      sdec.arm_expired_at = sdec.arm_thr or sdec.thr
      sdec.ck_endwhy = 'noarm'
      break
    end
    if waited >= limit then sdec.ck_endwhy = 'full'; break end

    -- Look at the NEWEST samples only, and only once new ones exist: re-testing the same
    -- window would report the same answer and make a busy line look quiet the moment
    -- acquisition stalled for any other reason.
    --
    -- "NEW" IS THE RING POSITION, NOT THE COUNT, for the reason the completion test above gives: on a
    -- buffer that has wrapped, buf.n is pinned at capacity and every window after that looks like the
    -- same window -- so the quiet timer would run on a device that was transmitting happily and end
    -- the run as 'the device stopped sending'. sdec.acq_end() is where the next reading goes, which
    -- keeps moving. nil falls back to the count, which is right for every buffer that never wrapped.
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
      seenend = eidx
    else
      quiet = quiet + step
    end

    -- THE IDLE WATCHDOG IS OFF UNTIL THE ARM FIRES, and `armdone` is what holds it off. A waiting arm
    -- is a line with nothing on it BY DESIGN, so every condition the watchdog tests for is satisfied
    -- -- no new samples, no crossings -- and it would end the run as 'the device stopped sending'
    -- before the device had started. Normally moot, because a silent probe leaves ck_watch false;
    -- NOT moot where the levels were reused from a previous capture, which is precisely the
    -- flow-controlled and multi-window case that reuse exists for.
    if armdone and sdec.ck_watch and sdec.idle_exit_s ~= nil and sdec.idle_exit_s > 0 and
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
    -- NOT WHILE AN ARM IS WAITING. The bar is a fraction of the buffer, and a pre-roll that has
    -- wrapped has filled it -- so the bar would read 100 % through a wait in which nothing has been
    -- recorded at all. ACCEPTED, once the arm has fired: the buffer really is full then, and what the
    -- count cannot say is how much of the burst has been written.
    if armdone then sdec.progress_samples(have, nsmp) end
    delay(step)
    waited = waited + step
    sdec.strm_waited = waited
  end

  -- TRUNCATED TO THE COUNT: this function promises a reading count, and stream_settle()'s second
  -- return is a reason only its direct callers read.
  return (sdec.stream_settle())
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
  return sdec.progress_row()
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
  -- 8N1 unless the FRAME FORMAT is forced -- and all three forced fields widen it, not just the data
  -- width: force_nbits, force_par and force_nstop each add to framebits below. The cap is a byte
  -- count, so a wider frame simply needs more samples for the same bytes.
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
  sdec.progress(nbytes)
  -- FALSE aborts the run, and progress()'s own verdict is DISCARDED. Returning it instead would
  -- make a failed settext look like a Stop press.
  if sdec.ck_stop then return false end
  -- AND THIS IS WHERE A LONG DECODE BECOMES CANCELLABLE. One window is the cancel granularity for
  -- the same reason it is the progress granularity: it is the only point at which this module gets
  -- control, and at ~0.96 s for a full-width window it already meets "answers within a second".
  -- Checking per FRAME instead would cost a poll per byte to shave off a delay nobody can perceive.
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

-- The body of the Capture press: start a capture, or stop or step one already in progress. Fully
-- guarded, and returns a verdict rather than raising.
--
-- NOT THE HANDLER. sdec.capture() below wraps this to hold the panel tick off for the duration
-- of the press; the button is wired to that, and so is every caller.
function sdec.capture_run()
  -- A KEY INSERTED SINCE THE LAST PRESS RESUMES NORMAL LOGGING, HERE, so the promise is "the first
  -- button press" and not "the first press that happens to log something". Covers both orders: an
  -- app started with no key, and one whose key was pulled and put back. One integer compare and a
  -- 237 us presence read when there is nothing to do; see ulog.resume().
  --
  -- KEPT EVEN THOUGH THE PANEL ROUTE ASKS FIRST. sdec.capture() calls ui_keypoll() before this, and
  -- the tick asks while the panel is idle, but neither is in the path of a host-driven capture_run()
  -- -- the harnesses call this directly. The promise belongs to the function that needs it.
  ulog.resume()
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
      ulog.line(sdec.stickyerr)
    else
      sdec.ck_stop = true                 -- second press during a stream = Stop
      sdec.ui_status = 'stopping'
      return sdec.ui_refresh()
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
  -- ONCE PER PRESS, ahead of the mode dispatch, so it is retired for every path below and not only the
  -- frame one. A relock inside this press must still be on the note row when the press returns,
  -- however many internal re-captures happen after it.
  sdec.relocked = nil
  -- rate_backoff with it: it requests one re-capture within THIS press, so a value surviving into the
  -- next one would spend a press re-capturing for a lock that is already gone.
  sdec.rate_backoff = nil
  -- THE RATE OFFER IS ALSO PER PRESS, and for the opposite reason to relocked: it must OUTLIVE the
  -- press that raised it, because the operator answers it afterwards. Pressing Capture again is an
  -- answer of its own -- a fresh capture supersedes the question -- so it is retired here.
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
    ulog.line(sdec.lasterr)
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
    -- Direct form: the call's two returns follow the verdict, and on a RAISE the first of
    -- them is the message -- so swhy carries the reason either way.
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
    -- START a recording and return. sdec.strm_press is what selects the press-driven path over
    -- the one-shot sdec.stream(); the one-shot form is kept for the host harnesses and the
    -- offline suite, which have no panel to protect.
    sdec.detect_reset()
    local sok, swhy = false, nil
    -- Direct form: the call's two returns follow the verdict, and on a RAISE the first of
    -- them is the message -- so swhy carries the reason either way.
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
    -- the device stops. It holds the panel for as long as that takes, AND NOTHING CAN CUT IT SHORT:
    -- the TRIGGER key emits no blender event while this runs, so it is no defence. The bounds in
    -- record_run() (fc_maxwin, fc_maxsec) are the only exits, not a backstop to a cancel.
    -- Direct form: the call's two returns follow the verdict, and on a RAISE the first of
    -- them is the message -- so swhy carries the reason either way.
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
      -- EVERY RECORDING LEAVES THE BYTES IT KEPT ON SCREEN, paged with the same two buttons as a
      -- frame capture. WITH a key the file holds everything the tail does not; with none, the tail is
      -- all there is and the status row says NOT recorded. The mode does not
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
    sdec.mode_exit(sdec.strm_exit_why(sdec.ck_endwhy, sok, sdec.lasterr), not sok)
    sdec.ui_refresh()
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
  -- NOT JUST clear_result(): the REQUESTED sample rate goes back to what the lock and mode imply,
  -- so the detection about to run starts from the settings rather than from the last capture's
  -- answer. See sdec.detect_reset.
  sdec.detect_reset()
  sdec.ui_status = 'capturing'
  sdec.ui_refresh()

  -- NOT pcall'd: nothing on this path is, because the nesting these wrappers added is what the
  -- firmware cannot take. A raise travels out to whoever catches it -- sdec.guard, or the lock
  -- toggle -- and sdec.unwind puts back what it skipped. See start().
  local ok, why = sdec.autoset()

  -- ONE FRESH CAPTURE AFTER A BACK-OFF. decode() sets rate_backoff when a locked rate fit nothing and
  -- neither did anything else, so the lock is now gone and this acquisition re-runs detection from
  -- scratch at the top sample rate. sdec.relocked already carries the reason to the note row.
  --
  -- CLEARED BEFORE THE RETRY, NOT AFTER: cleared after, a retry that backed off again would be seen
  -- still set and retry forever -- inside a touch handler, on a panel that is unresponsive while Lua
  -- runs. One retry is the whole allowance.
  local rb = sdec.rate_backoff
  sdec.rate_backoff = nil
  if rb then
    ulog.line('rate back-off: ' .. tostring(sdec.relocked))
    sdec.ui_status = 'retrying'
    sdec.ui_refresh()
    local keep = sdec.relocked
    ok, why = sdec.autoset()
    -- The retry's own decode does not clear relocked, but an autolock inside it publishes
    -- autolocknote, and both belong on the row: what was dropped and what replaced it.
    if sdec.relocked == nil then sdec.relocked = keep end
    sdec.rate_backoff = nil
  end
  sdec.busy = false

  if not ok then
    sdec.errcount = sdec.errcount + 1
    -- A capture that found nothing is the normal result of probing a quiet pin,
    -- so it is reported as a reason, not as a fault.
    if sdec.lasterr == nil then sdec.lasterr = tostring(why) end
    sdec.ui_status = 'no decode'
    ulog.line('no decode: ' .. tostring(why))
  else
    sdec.ui_status = 'done'
    sdec.ui_page = 0
    -- ONE CALL EACH, and no guard around any of them. The three are independent facts about the
    -- capture -- format, levels, byte count -- so they are logged separately; what makes that safe
    -- is summary() itself, which defends every value it formats, down to the division in its
    -- kS/s figure. A guard here would be a guard around our own formatting, on the success tail of
    -- a touch handler, where the cost of a raise is a dead Capture button with nothing on the
    -- panel to explain it.
    ulog.line(sdec.summary(1))
    ulog.line(sdec.summary(2))
    ulog.line(sdec.summary(3))
    -- Parse the protocol layer HERE, not lazily when the view opens, so the log records the
    -- messages belonging to the capture that produced them -- and before the notes, so a note
    -- the parse produces (the LIN break count) is in the list.
    --
    -- BARE CALLS, AND EACH CALLEE CARRIES ITS OWN GUARD. This is the SUCCESS path of a touch
    -- handler: a raise here takes out the Capture button on a capture that had ALREADY SUCCEEDED,
    -- and logging is a courtesy that must not be able to cost the decode. What keeps that true is
    -- the callees -- proto_parse() guards the protocol module it dispatches to, ui_notes() and
    -- autolock_try() touch no firmware and defend every count they do arithmetic on -- not a pcall
    -- here, which would be a guard around our own code three layers inside a firmware stack.
    sdec.proto_parse()
    -- BEFORE the notes are gathered, so the auto-lock note is one of them: locking is an
    -- optimisation for the NEXT capture and must never be able to retract one that already worked.
    sdec.autolock_try()
    -- EVERY note, not just the one the panel has room for. The cell shows the most
    -- important and counts the rest; this is where the rest become recoverable.
    local nt, nn = sdec.ui_notes()
    local ni
    for ni = 1, nn do ulog.line('note: ' .. nt[ni]) end
    -- The whole capture goes to the log as a hex dump: the panel shows one page,
    -- the file keeps everything and can be read on a computer afterwards.
    if sdec.res ~= nil then
      local i, per = 1, 16
      while i <= sdec.res.nf do
        ulog.line(sdec.ua_hex_line(i, per))
        i = i + per
      end
    end
    -- FRAME+LOG: also append this message to its own file. A BARE CALL. frame_log() guards no file
    -- call of its own and CAN raise on a key that is present and refusing -- the unmeasured case --
    -- so it registers its handle for sdec.unwind rather than closing it on the way out.
    if md.log then sdec.frame_log() end
  end

  sdec.ui_refresh()
  return ok
end

-- THE HALF-SECOND TICK IS OFF FOR THE WHOLE PRESS. A tick is dispatched exactly like a press, so work that
-- holds the interpreter does not suppress ticks -- it defers them, and the firmware releases what it
-- kept once the handler returns. MEASURED: a 10 s busy hold releases 2 ticks, not 10, so the backlog
-- is shallow and this is about not collecting one at all rather than about a flood.
--
-- A WRAPPER RATHER THAN AN EDIT INTO THE BODY, because capture_run() has a dozen return statements
-- and a missed one would leave the panel with no tick for the rest of the session.
--
-- THE BODY IS NOT GUARDED, AND A RAISE REACHES THE CALLER. `pcall(sdec.capture)` is how two callers
-- ask whether the press faulted -- tools/bench_break.py's K line and the lock toggle -- so this must
-- stay raising. What a raise would skip, the busy latch and the tick among it, is restored by
-- sdec.unwind: whoever catches the raise calls it, which is sdec.guard at the boundary or the lock
-- toggle when it catches one to word its own note.
--
-- THE KEY IS CHECKED BY THE PRESS, FIRST, and not left to the tick -- which is off for the whole of
-- this function anyway.
--
-- IT CLOSES NO VISIBLE GAP, AND THAT IS WORTH WRITING DOWN so nobody defends it with a defect it
-- did not fix. Checked OFFLINE against tools/mock_display.lua without it, key re-inserted and the
-- acquisition stubbed to report the state it starts in: FRAME and both recording modes already
-- reached the work with the log open and Save and NewLog back, because capture_run() opens with
-- ulog.resume() and each path refreshes before its long work. What this changes is that Capture
-- ASKS, instead of inheriting the answer from where resume() sits inside a function the press
-- cannot see.
function sdec.capture()
  sdec.ui_keypoll()
  sdec.ui_tick_off()
  -- REGISTERED, so sdec.unwind drops the stale result only when a CAPTURE unwound past it. A Save
  -- or a View that raised has invalidated no measurement.
  sdec.drop_pending = true
  local a, b = sdec.capture_run()
  sdec.drop_pending = nil
  sdec.ui_tick_on()
  return a, b
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
  -- GATE 1, A CREDIBLE RATE: the measurement either matched a standard rate within snaptol, or it
  -- rounds to a 10 Bd (100 Bd over 10 kBd) boundary inside 1 % -- see sdec.baud_round. A real line
  -- runs at a real rate, and both of those are what a real rate looks like.
  --
  -- SNAPPING ALONE WAS NOT ENOUGH, and the cost was paid on the panel: a device at 16 kBd never
  -- autolocked, so the padlock stayed amber, every recording mode refused for want of a locked rate
  -- (mode_cur().needbaud), and the only route to 8 kB was typing the number into Options -- which is
  -- also how a wrong rate gets typed in. Rounding is what replaces snapping as the credibility test;
  -- the other four gates are unchanged and still have to pass.
  -- LOCK THE MEASUREMENT, NOT AN OVERSTATED SNAP. sdec.baud has already been relabelled by sig_snap, so
  -- rounding IT commits whatever the snap chose -- and when the snap was not firm that is a rate the fit
  -- does not support. Measured: a 37422 Bd line whose fit read 37703 was relabelled 38400 and locked
  -- there, 2.6 % out and persistent, because `snapped` was true and this gate never looks past it. Using
  -- the raw fit in that case locks ~37700 instead: 0.7 % out rather than 2.6 %, and still a rate an
  -- operator could have typed once baud_round has rounded it.
  --
  -- STILL AUTOLOCKING, deliberately. Refusing the lock is the other available answer and it is worse:
  -- the comment above records what that cost when a 16 kBd device could not autolock at all -- amber
  -- padlock, every recording mode refused. This keeps the lock and only corrects the number.
  local lockfrom = sdec.baud
  if sdec.snapped and sdec.snapfirm == false and sdec.baud_raw ~= nil then lockfrom = sdec.baud_raw end
  local lockb, lockok = sdec.baud_round(lockfrom)
  if not sdec.snapped and not lockok then return false end
  -- GATE 2, THE LONGEST CONTIGUOUS CLEAN RUN -- not an error count, and not an error POSITION.
  -- What justifies locking a format is that the format explains a long unbroken stretch of the
  -- capture. That tolerates head resync and tail clipping without having to guess where they are
  -- allowed to be, and it is strictly harder to satisfy by accident than a small error count:
  -- scattered errors, which is what a wrong format gives, leave no long run however few of them
  -- there are.
  -- nf DEFENDED RATHER THAN ASSUMED, which is what lets the caller call this bare. A decode that
  -- returned a result with no count makes `for i = 1, nil` and `sdec.autolock_run * nil` raises --
  -- out of a capture that had already succeeded -- and a zero count takes the refusal below, which
  -- is the right answer for a capture with nothing in it.
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
  -- value back as though the operator chose it. The guard above only catches a forced BAUD, because
  -- that is the field that makes the second pass unnecessary; the other three are independent and have
  -- to be checked one at a time.
  --
  -- The rate is locked either way, so forcing parity does not cost the operator the speed win.
  --
  -- WHICH FIELDS THIS SET IS RECORDED, because a later back-off has to be able to drop what the app
  -- chose without touching what the operator typed -- see sdec.rate_backoff. Provenance cannot be
  -- recovered afterwards: a forced 8 is a forced 8 whoever wrote it.
  sdec.autolock_set = {}
  -- ROUNDED, so a non-standard measurement locks as a number an operator could have typed. 16099
  -- locks as 16100. baud_round leaves a standard rate exactly as it is.
  sdec.force_baud   = lockb
  sdec.autolock_set.baud = true
  if sdec.force_nbits == nil then sdec.force_nbits = r.nbits; sdec.autolock_set.nbits = true end
  if sdec.force_par   == nil then sdec.force_par   = r.par;   sdec.autolock_set.par   = true end
  if sdec.force_nstop == nil then sdec.force_nstop = r.nstop; sdec.autolock_set.nstop = true end
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
  -- THE PANEL MUST SHOW WHAT WAS LOCKED, not what was measured. The BAUD cell reads baud_text(),
  -- which formats sdec.baud and marks an unsnapped rate with '?', so locking a rounded 16100 while
  -- sdec.baud still held 16099 drew '16099?' beside a green padlock -- and the next capture, which
  -- decodes AT the lock, drew '16100'. Publishing the locked value here makes the cell stable across
  -- the lock instead of changing on a press that changed nothing.
  --
  -- snapped too, for the same reason and by the same convention: decode_from already sets it for any
  -- forced rate, so a locked rate is shown without the '?' everywhere else.
  --
  -- baud_raw IS LEFT ALONE. It is the honest measurement, the summaries have already logged it, and
  -- the rate cross-check compares against it on the next capture.
  -- snapfirm TRUE alongside snapped: what is published here is exactly the rate that is locked, so
  -- nothing has been rounded away from a measurement and the '?' would be about nothing. A stale
  -- false retained from an earlier soft snap would print 'auto-locked 37700 baud?'.
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
  -- GUARDED ON THE FUNCTION'S EXISTENCE as well as on the mode: midi_decode.tsp and
  -- lin_decode.tsp are separate modules, and a build that omits one must degrade to the raw UART
  -- views rather than raise from inside a touch handler. sdec.ui_views is the single description
  -- of which modes have a parser at all.
  if fn == nil then return false end
  local ok, perr = pcall(fn)
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
    ulog.line('proto: ' .. sdec.proto_why)
    return false
  end
  if sdec[v.res] ~= nil then
    local sm = sdec[v.summary]
    -- THE SUMMARY IS THE PROTOCOL MODULE'S OWN FUNCTION, so it goes through the same guard the
    -- parse above does: a raise formatting lin/midi text must not retract a parse that worked, and
    -- this runs on the success tail of a touch handler where the caller is a bare call.
    if sm ~= nil then pcall(function() ulog.line(tostring(mode) .. ': ' .. tostring(sm())) end) end
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
-- The inbound firmware boundary
-- ============================================================================
-- Put back whatever a raise unwound past, and report it. -> false, so a catcher can end with
-- `return sdec.unwind(err)`.
--
-- SEPARATE FROM sdec.guard BECAUSE NOT EVERY RAISE REACHES THE BOUNDARY. A frame that catches one
-- to make a decision of its own -- lock_toggle, which must choose between naming the new sample
-- rate and saying the re-capture failed -- has to do this too, or the cleanup simply does not
-- happen. Measured: one Lock Rate press whose re-capture raised left trigmode on 'free', busy
-- latched, the tick off and the panel reading 'capturing', with the press reporting success.
--
-- sdec.busy and ck_running are latches only a fault can leave set, and ui_tick reads busy as "a run
-- owns the panel", so one faulting press would otherwise stop the panel noticing the key for the
-- rest of the session.
--
-- RAISE-FREE BY CONSTRUCTION: assignments, ui_tick_on and ui_refresh which each guard themselves,
-- and a nil test on every function called by name -- a partial load must not turn the boundary into
-- the popup source it exists to prevent. It also does not log: ulog.line reaches file.write, and a
-- key that has filled up is exactly the condition that brought us here.
function sdec.unwind(why)
  sdec.busy = false
  sdec.ck_running = false
  -- THE UNWIND REGISTERS. A frame that mutates a module field for the duration of a call parks the
  -- old value here, because a local is invisible from this frame. trigmode left on 'free' makes
  -- every later capture free-run while the panel still says Edge.
  if sdec.trig_restore ~= nil then
    sdec.trigmode = sdec.trig_restore
    sdec.trig_restore = nil
  end
  -- THE DROP BELONGS TO THE CAPTURE PATH, NOT TO EVERY HANDLER. A capture that raised part-way has
  -- half-rewritten the measurements, so the rate on the glass is no longer one. A Save or a View
  -- that failed has invalidated nothing, and dropping there loses the capture the operator was
  -- trying to keep.
  if sdec.drop_pending then
    sdec.drop_pending = nil
    if sdec.drop_stale_result ~= nil then sdec.drop_stale_result() end
  end
  -- AN OPEN HANDLE IS NOT RECLAIMED UNTIL A POWER CYCLE, so a frame that holds one parks it here and
  -- clears it on its own close. Bare: file.close cannot transfer control -- measured, closing an
  -- already-closed handle posts 2202 and returns -- so it cannot stop the rest of this unwind.
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
-- THE ONE PLACE A pcall MAY WRAP OUR OWN CODE, and it is a firmware boundary like any other: the
-- instrument calls these by name out of a display event string, and a raise that escapes becomes an
-- ERROR-severity event, which is a modal dialog over the app. One helper, so the whole boundary is
-- ONE pcall site instead of one per button -- and it covers the WHOLE handler, where a guard around
-- a single call inside one covered only that call.
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
  add(string.format('bytes      %d   framing errors %d', sdec.res.nf or 0, sdec.res.nbad or 0))
  if sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('false starts rejected %d  (impulse noise)', sdec.res.nfalse or 0))
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
    -- NAME THE REASON next_free GAVE, when it is the one that failed. A nil path reaches write_file
    -- as 'no filename available', which describes this function's own variable rather than anything
    -- the operator can act on -- and ulog.idx_why holds the real sentence: no key, a directory that
    -- could not be confirmed, or every name taken. The note row is all they get.
    if path == nil and ulog.idx_why ~= nil then why = ulog.idx_why end
    sdec.lasterr = 'save failed: ' .. tostring(why)
  end
  sdec.ui_refresh()
  return ok
end

-- ============================================================================
-- View handlers
-- ============================================================================
-- Advance through the views THIS BUILD HAS -- text -> hex -> text in version 1, which ships
-- without midi_decode.tsp and lin_decode.tsp, so ui_view_avail() hides the MIDI and LIN entries
-- rather than landing the button on a list that could only ever be empty.
function sdec.view_toggle()
  -- THE KEY IS CHECKED BY THE PRESS, FIRST. View is the one press that writes nothing to the key, so
  -- its only other route to a correct panel is the ui_refresh() at the end of this function, which
  -- lands after the whole view has been rebuilt. The gain is that window, which is small; the reason
  -- to have it is that all three presses answer the question the same way.
  sdec.ui_keypoll()
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
  return sdec.ui_refresh()
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
  -- FORGETTING THE PATH IS THE WHOLE MECHANISM: frame_log() opens, appends and closes per
  -- capture, so there is no handle to close here, and the next capture calls ulog.next_free()
  -- again and lands on the next unused name.
  --
  -- It says what it did on the note line rather than silently renumbering. A control whose only
  -- evidence is a filename that changes on the NEXT capture is one you press twice, because you
  -- cannot tell whether the first press worked.
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
  -- Auto-detection is already the DEFAULT -- nothing forced means everything is searched for --
  -- so this is a one-press way back to it rather than a new capability. By hand it is six
  -- interactions on the form (baud to 0, three fields to Auto, Apply), which is enough friction
  -- that a locked rate tends to stay locked onto the next line it does not describe.
  sdec.unlock_all()
  -- NO autolock_defer() HERE: 'Auto Detect' means "work it out and use it", so the capture this
  -- triggers is allowed to lock what it finds. Deferring instead leaves the panel amber at the
  -- top sample rate with a 19-byte window -- a press that makes things worse, with the good
  -- outcome one press away and nothing saying so. The deferral belongs to the other route to the
  -- same clearing, Options > Baud Rate = 0 plus Apply, which is a request to STAY unlocked.
  ulog.line('auto-detect: all forced settings cleared')
  sdec.options_seed()
  -- AUTO-DETECT IS A FRAME-MODE OPERATION, and a streaming mode cannot be otherwise: it is gated
  -- on a locked rate precisely because the sample rate has to be chosen before the capture, and
  -- a rate still being searched for cannot do that. So this press lands in FRAME, and it does so
  -- by exiting properly -- flushing like any other way out -- rather than by refusing and leaving
  -- the operator to press Mode and come back.
  local md = sdec.mode_cur()
  if md.needbaud then
    sdec.mode_exit('auto-detect is FRAME-mode only')
    -- SET HERE, NOT IN mode_exit(). That function is a flush and does not touch the mode, so the two
    -- places a mode change is part of the MEANING say so themselves: auto-detect cannot run in a
    -- recording mode at all, so this press has to land in FRAME or it does nothing.
    sdec.capmode = 'frame'
  end
  return sdec.options_apply()
end

-- THE PADLOCK'S ACTION: amber (auto) locks the detected settings and goes green, green (locked)
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
    sdec.unlock_all()
    sdec.autolock_defer()
    note = 'unlocked -- auto-detecting again, back to the top sample rate'
    -- Unlocking disarms the streaming modes, so leave one rather than sit in a mode that cannot run.
    -- Same reasoning as options_auto(), and the mode change is set HERE for the same reason:
    -- mode_exit() is a flush and the switch is part of what THIS press means.
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
    -- Through baud_round, for the reason given at the Options Lock path: sdec.baud is a standard rate
    -- only when sdec.snapped, and this button has no such test.
    sdec.force_baud   = math.floor(sdec.baud_round(sdec.baud) + 0.5)
    sdec.force_nbits  = r.nbits
    sdec.force_par    = r.par
    sdec.force_nstop  = r.nstop
    sdec.force_invert = r.invert
    -- The operator pressed Lock Rate over these values, so none of them is autolock's to withdraw.
    sdec.autolock_set = nil
    -- baud_text reads sdec.baud, so the note would name the measurement while the lock holds the
    -- rounded value. Same reason as autolock_try.
    -- snapfirm TRUE alongside snapped: what is published here is exactly the rate that is locked, so
  -- nothing has been rounded away from a measurement and the '?' would be about nothing. A stale
  -- false retained from an earlier soft snap would print 'auto-locked 37700 baud?'.
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.force_baud, true, true
    note = string.format('locked %s %s', tostring(sdec.baud_text()), tostring(sdec.fmt_text()))
  else
    sdec.lasterr = 'nothing decoded yet -- capture first, then lock'
    return sdec.ui_refresh()
  end

  -- Re-capture at the rate the new lock state implies, so RATE, SA/BIT, BYTES and the window
  -- note all describe the same thing. Guarded for the VERDICT, not for safety: capture() guards
  -- nothing of its own, so a raise arrives here and this frame owes the unwind.
  -- THE VERDICT IS KEPT, because the sentence below claims the recapture worked. Both the pcall's
  -- result and capture()'s own boolean were discarded, so a recapture that raised or refused still
  -- produced 'locked 9600 baud -- now sampling at 80 kS/s' -- a confident report of a capture that did
  -- not happen, over whatever the previous one left on screen. The lock IS still applied either way,
  -- which is why the wording has to change rather than the action.
  -- pcall(sdec.capture) RATHER THAN A CLOSURE: no OP_CLOSURE, no allocation, and the second result
  -- is capture()'s own boolean. On a RAISE that second result is the message instead, so it must not
  -- be read as a verdict -- and whoever catches a raise reports it, since capture() no longer does.
  local pok, cres = pcall(sdec.capture)
  local cok = pok and cres
  -- CATCHING IT MEANS OWNING THE CLEANUP. sdec.guard never sees this raise, and guard is the only
  -- other frame that restores trigmode, the busy latch and the tick -- so unwind is called here.
  if not pok then sdec.unwind('capture raised: ' .. tostring(cres)) end
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
  ulog.line(tostring(sdec.lognote))
  sdec.options_seed()
  return sdec.ui_refresh()
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
  -- likely more where that came from. With a key the file is the record and the panel shows only its
  -- last page; with none, the last page is the record.
  -- AND IT OUTRANKS EVERY REASON BELOW. ck_endwhy describes the ACQUISITION, so a TRIGGER press during
  -- the DECODE leaves it 'full' -- and the branch below would then report 'buffer full -- the stream
  -- may continue' under a run the operator deliberately stopped, which is both wrong and the opposite
  -- of reassuring. stream_begin() clears ck_cancel on every run of either shape, so it can only be set
  -- by a press inside this one.
  if sdec.ck_cancel then
    if (sdec.fc_win or 0) > 1 then
      return string.format('stopped with the TRIGGER key after %d windows', sdec.fc_win or 0)
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
      return string.format('%d windows, then the device stopped sending', sdec.fc_win or 0)
    elseif sdec.fc_end == 'stopped' then
      -- NOT REACHABLE FROM THE PANEL TODAY, and the wording must not pretend otherwise: ck_stop is the
      -- only thing that sets this, and while the loop runs nothing can set ck_stop except
      -- cancel_asked() -- which sets ck_cancel too and returns above. Mode and mode_exit() are touch
      -- handlers and a touch is not dispatched while Lua runs, so they cannot ask a one-press run to
      -- wind up mid-flight. Kept as insurance against a firmware that gains a dispatch point.
      return string.format('stopped after %d windows', sdec.fc_win or 0)
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
  -- THE ARM EXPIRED, WHICH IS NOT A RECORDING THAT HAPPENED. Named separately from 'quiet' and
  -- 'full' because both of those describe a run with samples in it: this one waited for a device
  -- that never started, so the two settings that govern the wait are the useful thing to say.
  if endwhy == 'noarm' then
    return string.format('nothing crossed %.2f V in %g s -- raise Arm Wait or lower Arm At',
                         sdec.arm_expired_at or sdec.thr or sdec.arm_level_v(), sdec.arm_wait_s())
  end
  if endwhy == 'quiet' then
    return string.format('%g s with no line activity', sdec.idle_exit_s or 0)
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
-- ARMED ON EVERY ENDING, INCLUDING 'stopped'. Returning early because a press was SEEN assumes
-- nothing is queued behind it: true of one press, false of an operator, who presses Capture, then
-- TRIGGER, then Capture again. A finger on TRIGGER emits no blender event while a panel-initiated run
-- executes, so the run ends at its own bounds with BOTH Capture presses unabsorbed -- each starting
-- another uninterruptable recording.
function sdec.strm_absorb_arm()
  sdec.strm_stopped_by_press = nil
  sdec.strm_nabsorbed = 0
  -- timer.cleartime() stamps the moment the run ended. Nothing else runs between here and the
  -- dispatch of a queued press, so nothing else can reset the timer in between. The timer is always
  -- present, so the arm is unconditional -- a guard here would only have described the mock.
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
                                       .. 'discarded -- press again to capture', n or 0)
  end
  ulog.line(sdec.strm_absorbed)
  sdec.ui_refresh()
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
--
-- NEVER RAISES FOR ANY MEASURED FAILURE, so the four callers call it bare -- but see ulog.line: a
-- key that is present and refusing is unmeasured and can raise through it. It touches no firmware
-- directly: decode_abandon()
-- and stream_settle() guard their own, ulog is non-raising by contract, mode_cur() is documented
-- never to return nil, and the one string.format here takes tostring() of both arguments.
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
  if sdec.ck_job ~= nil then sdec.decode_abandon() end
  -- Likewise a recording still running in hardware: stop the trigger model, or it goes on filling
  -- a buffer nothing will read.
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
  -- THE MODE IS NOT CHANGED HERE, and that is the point of this function being only a flush.
  --
  -- Setting capmode = 'frame' here moves the operator to a mode they did not choose every time a
  -- recording finishes -- or hits its cap, or meets a quiet line. With the capture mode in the TITLE
  -- BAR that switch is a large caption changing itself, so the panel appears to have decided
  -- something. A recording mode is a SETTING, and a setting the app resets after every use is one the
  -- operator has to re-make every time.
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
    sdec.mode_exited = string.format('%s run ended (%s)', tostring(md.name), tostring(why or 'exited'))
    sdec.mode_exitbad = (bad == true)
    ulog.line(sdec.mode_exited)
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
-- THE RUNNING BRANCH DOES NOT LAND IN FRAME. mode_exit() is a flush and does not touch capmode, so
-- an abort stops the run and leaves the setting that says what the next one is -- one press, one
-- effect. Getting to FRAME from a recording mode is therefore up to two more presses of this button,
-- which is the trade for the mode never changing itself.
function sdec.mode_cycle()
  -- THE KEY IS CHECKED BY THE PRESS, FIRST. Mode is the press the no-key reports name -- it is what
  -- the operator saw the buttons vanish on -- so it asks before it does anything, rather than
  -- leaving the panel right only as a side effect of the ulog.line() and ui_refresh() below. Both of
  -- those already recover by themselves: this moves the recovery to the top of the handler.
  sdec.ui_keypoll()
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
    return sdec.ui_refresh()
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
  -- Switching drops the streaming result: ck_tot describes a run in a mode that is being left behind,
  -- and a stale byte count under a different mode name reads as a measurement.
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
    -- SEEDED THROUGH THE CLAMPS, not from the raw fields, so a value set programmatically outside the
    -- form's range is shown as what the capture will actually use rather than as what was asked for.
    display.setvalue(sdec.opt_armv, sdec.arm_level_v())
    display.setvalue(sdec.opt_armw, sdec.arm_wait_s())
  end)
end

-- Snapshot everything the form can change, so Cancel can undo it. Returns true.
function sdec.options_save()
  -- A screen with a Cancel button promises that its edits are provisional, and Lock Detected
  -- breaks that promise: it writes the live forced settings the moment it is pressed, so without
  -- a snapshot Cancel closes the screen over a wire configuration the operator has just declined.
  -- Taken on the way in, it covers every route the form has to that state rather than one of them.
  --
  -- THE PROVENANCE IS PART OF THE STATE, not separate from it: autolock_set says which of the forced
  -- fields the app chose for itself, so restoring the fields without it leaves a lock whose owner is
  -- forgotten -- and a later back-off then declines to clear a width autolock picked.
  --
  -- THE DISPLAYED RATE IS PART OF IT TOO. options_lock() publishes baud/snapped/snapfirm as well as
  -- the force_* fields, so a snapshot of force_* alone cannot undo it: Cancel put force_baud back to
  -- nil and left the rounded baud and snapfirm = true, turning a soft-snapped '38400?' into an
  -- unmarked '38400' and losing the 37703 the fit produced. dhas marks these as recorded, since nil
  -- is a legitimate value for them and a snapshot built without them must not be read as 'all nil'.
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
  -- GUARDED ON THE VALUES THEMSELVES, which is a different test from the dhas below and not
  -- interchangeable with it. nil is a legitimate value for the three display fields, so a snapshot
  -- that lacks them must leave the live ones alone. nil is NOT legitimate for these two -- serial_core
  -- defaults them at load and options_apply only ever assigns a number -- so a nil here means a
  -- snapshot built without them, and copying it in hands the capture a nil where a voltage and a
  -- duration get compared.
  --
  -- WHICH IS NOT HYPOTHETICAL: two offline fixtures assemble an opt_snap by hand, and this line put
  -- nil into both fields on every restore they drove. The clamps then answered with their floors, so
  -- the suite ran the whole feature at 0.33 V and 2 s without one assertion noticing -- a defect that
  -- hid itself by looking exactly like a configuration.
  if type(s.armv) == 'number' then sdec.armlevel = s.armv end
  if type(s.armw) == 'number' then sdec.armwait = s.armw end
  -- Guarded on dhas, not on the values: nil is legitimate for all three, and a snapshot taken without
  -- them must leave the live ones alone rather than clear them.
  if s.dhas then
    sdec.baud, sdec.snapped, sdec.snapfirm = s.dbaud, s.dsnap, s.dfirm
  end
  return true
end

-- Show the options screen, building it first if it does not exist yet.
function sdec.options()
  -- THROUGH pcall: this is a touch handler, and build_options() raises by design when the pool is
  -- exhausted. An uncaught raise here is an ERROR-severity event, which is a modal dialog over the
  -- app -- so the refusal is turned into a note instead, like every other refusal on this panel.
  if sdec.optscr == nil then
    local bok, berr = pcall(sdec.build_options)
    if not bok or sdec.optscr == nil then
      sdec.lasterr = tostring(berr or 'the options screen could not be built')
      ulog.line('options: ' .. sdec.lasterr)
      return sdec.ui_refresh()
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
    ulog.line('options: ' .. sdec.lasterr)
    return sdec.ui_refresh()
  end
  -- NOTHING PERIODIC MAY RUN WHILE THIS FORM IS UP, and the edit fields are the reason.
  --
  -- A field is an OBJ_EDIT_*, so a press on one has to open and hold a firmware MODAL EDITOR,
  -- where a press on a button runs its handler and returns. The tick is dispatched LIKE A PRESS
  -- (see ui_tick_off) and polls the USB key through log_live() -> keyok(), which is a filesystem
  -- call whose latency is neither bounded nor ours. So twice a second the form competes with a
  -- key read for the panel, and a field press that lands in one is dropped -- reported from the
  -- bench as fields needing several presses over 5-10 s, intermittently, while the four buttons
  -- stayed responsive.
  --
  -- NOTHING ON THIS FORM READS KEY PRESENCE. Save and NewLog are main-screen buttons and the log
  -- cell is a main-screen object, so the poll cannot change anything that is on the glass here --
  -- it is pure cost. ui_keypoll() runs again on the way out, and Capture asks for itself.
  --
  -- OFF BEFORE THE SWITCH, restored if the switch refuses, so no path leaves the tick off while
  -- the main screen is in front. Both calls are idempotent and guarded.
  sdec.ui_tick_off()
  local ok = pcall(display.changescreen, sdec.optscr)
  if not ok then sdec.ui_tick_on() end
  return ok
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
    sdec.ui_refresh()
    return false
  end
  -- The snapped rate WHEN IT SNAPPED, since that is the one a device is actually running: locking a
  -- measured 9611 would put the sampling point a bit further into the next cell on every
  -- frame, which is the error a 10-bit frame accumulates worst.
  --
  -- THROUGH baud_round, because sdec.baud is a standard rate only when sdec.snapped and this path has
  -- no such test: a nonstandard line would otherwise lock its raw measurement, 12345.6 or 16099.
  -- force_baud must also stay whole -- decode_from sets snapped = true for any forced rate, so a
  -- fraction reaches the %d in baud_text's snapped branch -- and baud_round returns a multiple of 10
  -- or 100, or the measurement unchanged when rounding would shift it over 1 %. The floor covers that
  -- last case.
  sdec.force_baud  = math.floor(sdec.baud_round(sdec.baud) + 0.5)
  sdec.force_nbits = sdec.res.nbits
  sdec.force_par   = sdec.res.par
  sdec.force_nstop = sdec.res.nstop
  sdec.force_invert = sdec.res.invert
  -- EVERY FORCED FIELD IS NOW THE OPERATOR'S. They pressed Lock Detected over these values, so a
  -- later back-off must not treat any of them as the app's own guess to withdraw.
  sdec.autolock_set = nil
  -- The BAUD cell reads sdec.baud through baud_text, so without this it draws '16099?' beside a green
  -- padlock holding 16100. Same reason as autolock_try and lock_toggle.
  -- snapfirm TRUE alongside snapped: what is published here is exactly the rate that is locked, so
  -- nothing has been rounded away from a measurement and the '?' would be about nothing. A stale
  -- false retained from an earlier soft snap would print 'auto-locked 37700 baud?'.
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.force_baud, true, true
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
    -- EVERY FIELD BELOW IS NOW THE OPERATOR'S, so none of it is autolock's to take back. A typed rate
    -- is honoured: the back-off may still drop it when it fits nothing, but it will not quietly drop
    -- a width or parity that was chosen on this form.
    sdec.autolock_set = nil
    local b = display.getvalue(sdec.opt_baud)
    -- ROUNDED TO A WHOLE Bd. force_baud must stay integral because decode_from sets snapped = true
    -- for any forced rate, and the snapped display branches format it with %d.
    --
    -- ONE OF THREE SOURCES THAT NEED ROUNDING, and not the only one: autolock's is integral by
    -- construction (gated on `snapped`, so sig_snap returned an exact sdec.stdbaud entry) and MIDI is
    -- the literal 31250, but the two LOCK paths copy sdec.baud with no snapped test and so lock a raw
    -- measurement
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

    -- THE TWO ARM FIELDS, TAKEN ONLY WHEN THEY READ AS NUMBERS. A getvalue that hands back anything
    -- else must leave the previous setting alone rather than put nil into a comparison the capture
    -- makes against a voltage -- and unlike Baud Rate there is no "0 means auto" reading available
    -- here, because 0 V is a level and 0 s is a wait.
    --
    -- NOT CLAMPED HERE. arm_level_v() and arm_wait_s() clamp at the point of use, so the stored value
    -- stays what the operator typed and the form shows it back unaltered; clamping on the way in as
    -- well would silently rewrite a field the moment it was applied.
    local av = display.getvalue(sdec.opt_armv)
    if type(av) == 'number' then sdec.armlevel = av end
    local aw = display.getvalue(sdec.opt_armw)
    if type(aw) == 'number' then sdec.armwait = aw end
  end)
  if not readok then
    -- AND THIS IS WHAT MAKES THAT MESSAGE TRUE. The reads above assign as they go, so a getvalue
    -- that raises on Data Bits has already committed Baud -- the new rate combined with the old
    -- width, live, under a message saying nothing changed. options_save() has snapshotted for
    -- Cancel, so the state to go back to already exists and this is the unwind Cancel performs.
    sdec.options_restore()
    sdec.lasterr = 'Options could not be read in full -- nothing was changed (' ..
                   tostring(readerr) .. ')'
    ulog.line(sdec.lasterr)
    pcall(display.changescreen, sdec.ui_scr)
    -- The form suspended the tick on the way in, so every way out re-arms it. This refusal path
    -- returns to the main screen like the others, and leaving it off would strand the key poll for
    -- the rest of the session -- Save and NewLog would then never come back by themselves.
    sdec.ui_tick_on()
    sdec.ui_refresh()
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
    -- A SPECIFICATION IS NOT AUTOLOCK'S GUESS. decode()'s back-off already refuses to run on a
    -- non-uart protocol, so this is insurance rather than a live path -- but stale provenance naming
    -- fields the app no longer chose is the kind of state that becomes a live path later.
    sdec.autolock_set = nil
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
    -- reading the fields back would keep them forced on a line that has stopped being MIDI or
    -- LIN.
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
  -- Re-armed HERE rather than left to sdec.capture(), which turns the tick off and on around its
  -- own work and would happen to leave it on. That is a side effect of another function, not a
  -- statement that this screen is done with it: a capture that returns early, or one whose
  -- off/on pairing changes, would take the key poll down with it for the session.
  sdec.ui_tick_on()
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
  sdec.options_seed()
  sdec.ui_refresh()
  local ok = pcall(display.changescreen, sdec.ui_scr)
  -- AFTER the switch, and unconditionally: the tick belongs to the main screen, so re-arming it
  -- while this form is still in front would put the poll back under the fields it was suspended
  -- for. Unconditional because a refused switch leaves the operator on a form whose Cancel has
  -- already restored the settings -- the next Apply or Cancel is the way out, and both re-arm.
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
    -- STICKY, not lasterr: a later capture would clear lasterr, and this fault must outlive it.
    sdec.stickyerr = 'End App is not hooked -- exiting will not clean up'
    ulog.line(sdec.stickyerr)
  end
  return ok
end

-- Tear the app down: release the job, stop the hardware, delete objects, close the log.
--
-- NEVER RAISES FOR ANY MEASURED FAILURE, so every caller calls it bare; ulog.line and ulog.close
-- can raise on a key that is present and refusing, which is unmeasured. Each firmware touch below
-- carries its own guard --
-- the model abort, the comparator write, the blender reset, buffer.delete -- and the sdec.* calls
-- it makes are non-raising for the same reason. It is also the End App event string installed by
-- install_cleanup(), through sdec.cleanup(): a raise there reaches the FIRMWARE, which posts it at
-- the operator while the app is being left.
function sdec.stop()
  -- THE TICK GOES FIRST, before any object it touches. It is dispatched like a press, so one can be
  -- queued already -- and a tick arriving part-way through this would repaint buttons that have been
  -- deleted. ui_destroy() deletes the object itself and nils the handle; this stops it firing in the
  -- meantime, and covers End App, which reaches here through sdec.cleanup().
  sdec.ui_tick_off()
  -- ORDER MATTERS: release the decode job and stop the hardware BEFORE the buffer goes.
  --
  -- A live ck_job owns an open file handle on the byte log that only its finish() closes, and a
  -- recording still running is an initiated trigger model writing into sdec.buf -- deleting the
  -- buffer under it is the create-over-a-live-object hazard. Turning the analog trigger off is not
  -- the same as aborting the model.
  if sdec.ck_job ~= nil then sdec.decode_abandon() end
  if sdec.strm_recording then
    sdec.strm_recording = nil
    sdec.stream_settle()
  end
  sdec.ck_running, sdec.ck_stop = false, false
  pcall(trigger.model.abort)
  -- ONLY WHILE THE DIGITIZER IS THE SELECTED FUNCTION -- see sdec.digitizing(), which explains why
  -- asking at all is not enough on its own. Turning the comparator off is un-configuring a subsystem this app
  -- configured, which is right, but the attribute does not exist while a BASIC function is selected and
  -- writing it then posts 2800 as a modal box.
  --
  -- REACHABLE ON EVERY EXIT THAT FOLLOWED NO CAPTURE, and that became the common case rather than a corner
  -- one when mode_restore() started leaving a basic function selected: the next launch then begins with the
  -- digitizer deselected, and a launch closed without pressing Capture never selects it. hw_config() is what
  -- selects it, and it runs per capture, not at startup.
  if sdec.digitizing() and sdec.atrig ~= nil then
    sdec.atrig.mode = sdec.k.MODE_OFF
  end
  -- RELEASE THE CANCEL LATCH, for the reason acq_triggered() gives for releasing blender 1: an app
  -- that configures a subsystem should un-configure it, or the next user of blender 2 inherits our
  -- stimuli. sdec.cancel_ok goes with it, so a poll after teardown answers false rather than reading
  -- a blender this app has released.
  sdec.cancel_ok = false
  -- THE RIGHT VARIABLE. sdec.cancel_blender is a load-time CONSTANT (serial_core.tsp), so testing it
  -- is vacuous; what cancel_setup's own header calls a supported configuration is a firmware with no
  -- blenders at all. Measured: with trigger.blender nil, indexing it here aborted teardown and left
  -- 133 display objects live -- destroy_options, ui_destroy, trig_settle and the buffer delete are
  -- all downstream, and sdec.guard stops the dialog but not the leak.
  local bl = trigger.blender
  if bl ~= nil and bl[sdec.cancel_blender] ~= nil then
    pcall(bl[sdec.cancel_blender].reset)
  end
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
  -- no way to retry and the next acquisition allocates another on top of it, one more per relaunch that
  -- captures.
  --
  -- Keeping the handle is what makes it recoverable: sdec.acquire() calls acq_make_buffer(), which
  -- settles and retries the delete properly. That retry therefore happens on the FIRST CAPTURE after a
  -- relaunch -- the operator's first press -- and not at launch, because start() acquires nothing.
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
  sdec.smp, sdec.nread = nil, 0
  sdec.res, sdec.midi, sdec.lin = nil, nil, nil
  sdec.ei, sdec.es, sdec.ne = nil, nil, 0
  sdec.w, sdec.nw = nil, 0
  sdec.ui_rowc = nil
  -- LAST, AND AFTER THE SAMPLES ARE GONE. Selecting a basic measure function takes the digitizer out
  -- of the signal path, so it happens once nothing is left to read out -- and after the abort and the
  -- buffer delete above, because those are the steps that must not find the mode changed under them.
  -- Before ulog.close(), so a refusal still has somewhere to be reported.
  if not sdec.mode_restore() then
    ulog.line('entry mode could not be restored -- the digitize function is still selected')
  end
  ulog.close()
  return true
end

-- End App handler: stop the app and hand the screen back to the instrument.
function sdec.cleanup()
  local r = sdec.stop()
  -- Teardown has just dropped every object handle and the capture buffer. Collecting costs
  -- 8.3 ms, measured.
  pcall(collectgarbage)
  return r
end

-- Entry point: open the log, build the UI, and hook End App. Takes NO capture -- the app comes up
-- idle and the first acquisition is the operator's press. THE BUILD is under pcall; cleanup(),
-- del_orphans() and stop() on the failure path are NOT, and there is no guard above launch.
-- Returns false
-- and a reason if a rebuild is refused or the build fails.
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
    sdec.cleanup()
    -- Retry anything a previous teardown could not delete BEFORE counting failures: a handle kept
    -- by del_obj is reclaimable, and reclaiming it is what keeps the object pool from filling.
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
  -- SET BEFORE ui_build(), deliberately: a build that fails halfway is exactly the dangerous
  -- state, so a failed attempt has to count as an attempt.
  sdec.built = true

  local ok, err = pcall(function()
    ulog.tag = 'SDEC'
    -- ONCE, HERE, AND NOT PER WRITE. Confirming the directory means reading the USB root, which returns
    -- the whole 64 kB FAT table, so it is done one time at launch and cached. Every writer afterwards
    -- just opens. See THE DIRECTORY in usb_log.tsp for why there is no cheaper way to ask.
    ulog.ensuredir()
    ulog.open(sdec.logpath)

    -- BEFORE ANYTHING TOUCHES THE DIGITIZER, and after the rebuild guard above rather than before
    -- it: on a rebuild that guard runs cleanup(), which restores the entry mode and clears the
    -- latch, so reading here reads the operator's mode and not the one this app just left behind.
    -- Logged either way -- a meter that cannot report its own mode is worth knowing about, and the
    -- USB log is the only place a start-time note can be read.
    if sdec.mode_save() then
      ulog.line('entry mode: ' .. tostring(sdec.entrymode.side) .. ' '
                .. tostring(sdec.entrymode.func) .. ' -- restored on exit')
    else
      ulog.line('entry mode could not be read -- exiting will leave the digitize function selected')
    end

    -- EVERY DETECTION SETTING BACK TO AUTOMATIC, BEFORE THE OPTIONS SCREEN IS BUILT FROM THEM. `sdec`
    -- outlives an app run on this firmware, so without this a launch inherits whatever the last session
    -- pinned -- a typed baud rate, a forced format, a rear-BNC trigger -- with the padlock showing it and
    -- nobody expecting it. build_options() seeds its controls from these fields, so the reset has to come
    -- first or the screen would show the old values while the decoder used the new ones.
    --
    -- LOGGED, because this is the app overriding something the operator set, and the USB log is where a
    -- surprise gets explained after the fact.
    sdec.reset_options()
    ulog.line('options reset: proto uart, FRAME mode, text view, baud auto, bits auto 7/8, '
              .. 'parity auto, polarity auto, trigger Start bit, rear BNC off')

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
    sdec.stop()
    -- `built` was set BEFORE the build, so a failure has to retract it. Left true it claims a UI
    -- that is not there: the next start() takes the rebuild path and tears down nothing, and any
    -- caller testing sdec.built to decide whether the app is usable is told yes.
    sdec.built = false
    return false, err
  end

  -- THE APP COMES UP IDLE AND MEASURES NOTHING. 'ready -- press Capture', set above, is the
  -- literal truth: the first acquisition is the operator's first press, so start() returns with
  -- the digitizer untouched and sdec.res nil.
  --
  -- DO NOT PUT A CAPTURE HERE. On firmware 1.7.17a, a capture taken from inside this function
  -- BLUESCREENS the instrument when the app runs from INTERNAL MEMORY: 3 of 3 crashes with the
  -- call, against 2 of 2 clean for the identical build with only that call removed. Three things
  -- narrow it to this call site rather than to capturing at all -- the same archive run from a USB
  -- key never crashes, a capture from the operator's own press never crashes, and the crash lands
  -- at the END of the startup capture.
  --
  -- WHAT IT ACTUALLY IS: pcall DEPTH. This path sits ONE pcall layer below a firmware stack
  -- limit, and reaching the capture from here is deeper than reaching it from a button press.
  -- Measured on a V1.30-based pair differing by exactly one layer, everything else identical:
  --
  --     local a, b = sdec.capture_run()                                   clean, 2 of 2
  --     local ok, a, b = pcall(function() return sdec.capture_run() end)  bluescreen, PC 001CF3C8
  --
  -- IT IS THE PEAK pcall DEPTH REACHED ANYWHERE DURING THE CAPTURE, not the depth of the chain
  -- on the way in. Flattening that chain to ONE layer -- autoset(), acquire() and decode() all
  -- bare -- still bluescreened; so did a build with 191 pcalls in it. What fixed it was taking the
  -- whole app from 227 pcall calls to 132, after which a launch capture runs clean. Measured:
  --
  --     227 pcalls, 4 layers on the chain   bluescreen, PC 001CF3C8, 3 of 3
  --     227 pcalls, 1 layer  on the chain   bluescreen, same PC
  --     191 pcalls                          bluescreen, same PC
  --     132 pcalls                          runs, 2 of 2, launch capture included
  --
  -- SO THE pcall BUDGET IS A SHIPPING CONSTRAINT, and the margin is not known: the boundary lies
  -- somewhere between 132 and 191, and nothing has bisected it. Guards belong at a FIRMWARE
  -- BOUNDARY -- outbound where this app calls the instrument, inbound where the instrument calls
  -- a handler of ours -- and never around a call into our own code, which is what the count is
  -- made of. tools/harden_formats.py exists because removing a guard exposes any nil the guard
  -- was hiding; run it after taking one off.
  --
  -- NO SIZE THRESHOLD EXPLAINS IT, so do not try to buy headroom by making the app smaller. A
  -- generated app with a LARGER compiled image (190113 bytes against this app's 187613) and MORE
  -- stored source (278366 against 271345) runs cleanly, and stripping 58 kB of comments from this
  -- app does not help while the call is present. V1.30 and earlier survive the call; V1.31 and
  -- later do not, and what that commit added to make it lethal is not established.
  -- tools/repro_bigapp.py and tools/probe_appsize.py build the artefacts; docs/vendor has the report.
  return true
end

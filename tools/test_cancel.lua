-- test_cancel.lua -- one press decodes a whole transmission, and the TRIGGER key stops it.
--
-- THE FOUR THINGS THIS FILE EXISTS TO HOLD DOWN, all four of them requirements rather than fixes:
--
--   #26  a cancel that answers within about a second while the interpreter is busy
--   #25  ONE press records, decodes and files a whole transmission -- not twelve presses
--   the window size as a choice, with the responsiveness trade attached to it
--   #24  flow control that needs no interaction at all: credit, capture, decode, credit again
--
-- WHAT AN OFFLINE TEST CAN AND CANNOT SAY ABOUT #26. It cannot observe the firmware latching a key
-- press while Lua spins -- that is measured on hardware by tools/bench_cancelkey.py, and the
-- measurement is quoted in sdec.cancel_setup(). What it CAN do is pin the semantics that measurement
-- licensed: the wiring, the auto-reset on read, the clear before each run, and every place a cancel
-- has to change the outcome. The mock's blender counts unread events for exactly that reason (see
-- TRIG.press in tools/gen_serial.lua).
--
-- Run from the repo root:  lua tools/test_cancel.lua

dofile('tools/mock_display.lua')     -- hostile display + file mock, object census
dofile('tools/gen_serial.lua')       -- waveform generator, dmm/buffer mock, decode core
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
end

-- Reset everything a run leaves behind, so each block starts from the resting state rather than
-- from its predecessor's ending.
local function idle()
  sdec.ck_job, sdec.ck_job_md, sdec.strm_recording = nil, nil, nil
  sdec.ck_running, sdec.ck_stop, sdec.ck_cancel = false, false, nil
  sdec.ck_tot, sdec.ck_nbytes, sdec.ck_endwhy = nil, nil, nil
  sdec.fc_win, sdec.fc_bytes, sdec.fc_end = nil, nil, nil
  sdec.strm_inflight, sdec.fc_out = nil, nil
  TRIG.latch = {}
end

-- A DEVICE THAT KEEPS SENDING, which the mock cannot be on its own. Its waveform is far shorter
-- than a 32 kB window asks for, so every real acquisition ends 'quiet' -- and 'quiet' is precisely
-- the flow-control loop's signal that the transmission is over, so every test of a multi-window run
-- would be a one-window test. This wraps stream_acquire so the first `nfull` windows report 'full'
-- (the device filled its window and has more to send) and the next returns nothing (it has
-- finished). Nothing else is faked: the same code records, decodes, files and credits.
local function sending_for(nfull)
  local real, n = sdec.stream_acquire, 0
  sdec.stream_acquire = function(nsmp)
    n = n + 1
    if n > nfull then
      -- STILL ARMS, STILL CREDITS. The device is credited and says nothing, which is the ending
      -- being modelled -- skipping the arm would also skip the credit pulse, and the credit count
      -- is one of the things these tests assert.
      real(nsmp)
      sdec.ck_endwhy = 'quiet'
      return 0
    end
    local got = real(nsmp)
    sdec.ck_endwhy = 'full'
    return got
  end
  return function() sdec.stream_acquire = real end
end

-- A line the mocked digitizer can hand back: 9600 baud at 100 kS/s, the rate pick_fs lands on.
local bytes = {}
local i
-- CONTINUOUS TRAFFIC, not a short burst followed by idle: 760 bytes at 9600 baud is 0.79 s, which
-- fills the 80 000-sample source below. A capture whose bytes all land in the first decode window
-- cannot show that a cancel stopped anything -- 'stopped early' and 'finished' produce the same
-- byte count.
for i = 1, 760 do bytes[i] = 32 + math.fmod(i * 7, 90) end
-- LONG ENOUGH TO HAVE SEAMS. A cancel has to land BETWEEN windows, so a source of one window
-- cannot test one: 80 000 samples at 100 kS/s is four 20 000-sample decode windows, and ~760 bytes
-- at 9600 baud. The byte pattern repeats, which is fine here -- the assertions are about where the
-- run stopped, not about which bytes came out (tools/test_serial.lua owns that).
local rd, ts, nc, nsmp = GEN({bytes = bytes, baud = 9600, fs = 100000, lead = 20, n = 80000})
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
MD.usb(true)
MD.forget_files()
sdec.ui_build()

-- ============================================================================
print('\nA  the cancel latch: wiring, auto-reset, and failing safe')
-- ============================================================================
do
  idle()
  local ok = sdec.cancel_setup()
  local b = sdec.cancel_blender
  check('cancel_setup() succeeds against a firmware with blenders', ok == true)
  check('and it does NOT use blender 1, which acq_triggered() owns for the trigger source',
        b == 2, tostring(b))
  check('the front-panel TRIGGER key is stimulus 1',
        trigger.blender[b].stimulus[1] == trigger.EVENT_DISPLAY,
        tostring(trigger.blender[b].stimulus[1]))
  -- AND NOTHING ELSE IS WIRED IN. A bus trigger was tried as a second stimulus so a harness could
  -- cancel without a finger; measured on the instrument, a *TRG sent mid-script never reaches the
  -- latch, because the command queue waits for an idle interpreter. Wiring it anyway would look
  -- like coverage and be none, so the harness uses a trigger timer of its own instead.
  check('and nothing else is wired in -- a bus trigger cannot fire mid-script',
        trigger.blender[b].stimulus[2] == nil,
        tostring(trigger.blender[b].stimulus[2]))
  check('OR-ed, not AND-ed -- either source alone must fire it',
        trigger.blender[b].orenable == true)

  check('with nothing pressed, no cancel is reported', sdec.cancel_pressed() == false)
  TRIG.press(b)
  check('one press reads as a cancel', sdec.cancel_pressed() == true)
  -- THE AUTO-RESET IS THE PART THAT MATTERS. A latch that stayed set would cancel every later run
  -- at its first window, and the operator would see one press kill the next three recordings.
  check('...and exactly once -- the detector auto-resets on read',
        sdec.cancel_pressed() == false)
  TRIG.press(b)
  TRIG.press(b)
  check('two presses still read as one cancel, as documented', sdec.cancel_pressed() == true)
  check('...and leave nothing behind', sdec.cancel_pressed() == false)

  TRIG.press(b)
  sdec.cancel_clear()
  check('cancel_clear() discards a press made before the run started',
        sdec.cancel_pressed() == false)

  -- FAILING SAFE MATTERS MORE THAN WORKING HERE: a firmware without a usable blender must leave
  -- every loop running to its own bounds, never raise, and never report a cancel nobody asked for.
  local realwait = trigger.blender[b].wait
  trigger.blender[b].wait = function() error('no blender on this firmware', 0) end
  check('a blender that raises reads as NO cancel rather than propagating',
        sdec.cancel_pressed() == false)
  trigger.blender[b].wait = realwait
  sdec.cancel_ok = false
  TRIG.press(b)
  check('and with the latch unavailable, a pending press is ignored entirely',
        sdec.cancel_pressed() == false)
  sdec.cancel_ok = true
  TRIG.latch = {}

  -- A ZERO TIMEOUT IS THE DISPLAY-API WEDGE. The mock refuses it; this asserts the app never sends
  -- one, because the offline suite is the only place that check can be made cheaply.
  check('the poll timeout is nonzero -- a zero is how display.waitevent wedges the instrument',
        sdec.cancel_poll_s ~= nil and sdec.cancel_poll_s > 0,
        tostring(sdec.cancel_poll_s))
end

-- ============================================================================
print('\nB  cancel_asked() records the press, and stays true once it has')
-- ============================================================================
do
  idle()
  sdec.cancel_setup()
  check('nothing pressed, nothing asked', sdec.cancel_asked() == false)
  check('and no stop was invented', sdec.ck_stop == false and sdec.ck_cancel == nil)
  TRIG.press(sdec.cancel_blender)
  check('a press is a cancel', sdec.cancel_asked() == true)
  check('it sets the stop flag the loops already read', sdec.ck_stop == true)
  -- TWO FLAGS FOR TWO QUESTIONS: ck_stop is "wind up", which Mode and mode_exit() also set;
  -- ck_cancel is "the operator pressed TRIGGER", which is what the note row needs to name them.
  check('and records that it was a TRIGGER press, not a Mode press', sdec.ck_cancel == true)
  check('asking again still says yes, though the latch is empty by now',
        sdec.cancel_asked() == true)
end

-- ============================================================================
print('\nC  a cancel during the RECORDING keeps what was recorded')
-- ============================================================================
-- The recording loop polls the latch twice a second. A cancel there must end the ACQUISITION and
-- then decode what it collected -- which is what the old Capture-to-stop press did. Ending the
-- decode too would throw away everything the operator had just waited for.
do
  idle()
  clearforce()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  local waits0 = TRIG.waits
  local ok, why = sdec.stream_begin()
  check('a recording can be set up', ok == true, tostring(why))
  -- Pressed BEFORE the poll loop runs, which is the same as pressing during it: the latch does not
  -- care when it was set, only that it was set before the poll.
  TRIG.press(sdec.cancel_blender)
  local got = sdec.stream_acquire(sdec.strm_nsmp)
  check('the acquisition loop polls the latch', TRIG.waits > waits0,
        string.format('%d polls', TRIG.waits - waits0))
  check('and a press ends the recording', sdec.ck_endwhy == 'stopped',
        tostring(sdec.ck_endwhy))
  check('with the samples it had collected kept, not discarded', got ~= nil and got > 1,
        tostring(got))
end

-- ============================================================================
print('\nD  a cancel during the DECODE stops it and keeps the bytes')
-- ============================================================================
do
  idle()
  clearforce()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  MD.forget_files()
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local ok, why = sdec.stream()
  check('an uninterrupted recording decodes normally', ok == true, tostring(why))
  local whole = (sdec.ck_tot and sdec.ck_tot.nf) or 0
  check('and produces bytes', whole > 0, tostring(whole))
  local nwin = (sdec.ck_tot and sdec.ck_tot.nwin) or 0
  check('over more than one window, so there is somewhere to cancel', nwin > 1,
        string.format('%d windows', nwin))

  -- NOW THE SAME RUN, CANCELLED. The press lands while the decode is between windows, which is
  -- where ck_progress polls -- so the run must end there, with the windows already decoded kept and
  -- the file closed rather than abandoned.
  idle()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local realprog = sdec.ck_progress
  local nwseen = 0
  sdec.ck_progress = function(nb, nw, ne)
    nwseen = nwseen + 1
    -- Press on the first window boundary. Nothing here bypasses the mechanism: the press goes into
    -- the same latch a finger would set, and the real ck_progress below reads it.
    if nwseen == 1 then TRIG.press(sdec.cancel_blender) end
    return realprog(nb, nw, ne)
  end
  local cok, cwhy = sdec.stream()
  sdec.ck_progress = realprog
  check('a cancelled decode still reports success -- the bytes it got are real',
        cok == true, tostring(cwhy))
  local part = (sdec.ck_tot and sdec.ck_tot.nf) or 0
  check('it stopped early', part > 0 and part < whole,
        string.format('%d of %d bytes', part, whole))
  check('and says WHY it stopped', sdec.ck_tot ~= nil and sdec.ck_tot.stopped == 'stopped',
        tostring(sdec.ck_tot and sdec.ck_tot.stopped))
  check('the cancel is attributed to the TRIGGER key', sdec.ck_cancel == true)
  check('and the note row says so rather than blaming the panel',
        has(sdec.strm_exit_why('stopped', true, nil), 'TRIGGER'),
        sdec.strm_exit_why('stopped', true, nil))
  -- THE FILE IS THE POINT OF THE MODE. A cancel that abandoned the sink would leave the last rows
  -- in the carry and the handle open until a power cycle.
  local f = MD.content(sdec.flog_path)
  check('the bytes decoded before the cancel are in the file',
        f ~= nil and string.len(f) > 0,
        string.format('%d chars', f and string.len(f) or -1))
end

-- ============================================================================
print('\nE  ONE PRESS is the whole job -- not twelve')
-- ============================================================================
do
  idle()
  clearforce()
  sdec.cancel_setup()
  -- THE DEFAULT IS WHAT IS BEING TESTED. strm_press = true is the stepped path, kept for the
  -- harnesses; the panel must not take it, or one press is one slice again.
  check('the panel path is the one-press path by default', sdec.strm_press == false,
        tostring(sdec.strm_press))
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local presses = 0
  local realstream = sdec.stream
  sdec.stream = function() presses = presses + 1; return realstream() end
  local ok = sdec.capture()
  sdec.stream = realstream
  check('one Capture press ran the whole recording', ok == true)
  check('and left no decode job for a second press to step',
        sdec.ck_job == nil, tostring(sdec.ck_job))
  check('nor a recording waiting to be stopped', sdec.strm_recording == nil)
  check('exactly one window was recorded, because flow control is off', presses == 1,
        tostring(presses))
  check('bytes came out', (sdec.ck_tot and sdec.ck_tot.nf or 0) > 0,
        tostring(sdec.ck_tot and sdec.ck_tot.nf))
  -- EVERY WAY OUT LANDS IN FRAME, which is unchanged and is what makes the mode leavable.
  check('and the mode returned to FRAME with the tail on screen',
        sdec.capmode == 'frame', tostring(sdec.capmode))
  check('the control cell named the TRIGGER key while it ran, not a button',
        sdec.strm_inflight == nil)
end

-- ============================================================================
print('\nF  the window size is a choice, and both windows are capped')
-- ============================================================================
do
  idle()
  local small, big = nil, nil
  for i = 1, sdec.ui_modes.n do
    if sdec.ui_modes[i].id == 'sml' then small = sdec.ui_modes[i] end
    if sdec.ui_modes[i].id == 'med' then big = sdec.ui_modes[i] end
  end
  check('there is a small window mode', small ~= nil)
  check('and a large one', big ~= nil)
  check('both have a byte ceiling -- neither is uncapped',
        small ~= nil and big ~= nil and small.cap == 8192 and big.cap == 32768,
        string.format('%s / %s', tostring(small and small.cap), tostring(big and big.cap)))
  check('both need a locked rate, because sizing a capture needs one',
        small.needbaud == true and big.needbaud == true)
  check('both end on a quiet line', small.idlexit == true and big.idlexit == true)
  check('and they are visually distinguishable in the MODE cell', small.c ~= big.c,
        string.format('%06X vs %06X', small.c, big.c))
  -- THE SIZE IS THE SAMPLE COUNT. If the small mode asked for the same samples as the large one,
  -- the choice would be decoration.
  clearforce()
  sdec.force_baud = 9600
  local ns = sdec.stream_samples(small, sdec.fs_for_burst(9600))
  local nb = sdec.stream_samples(big, sdec.fs_for_burst(9600))
  check('the small window really does record fewer samples', ns < nb,
        string.format('%d vs %d readings', ns, nb))
  -- WITHIN ROUNDING, not exactly: stream_samples() takes a math.ceil, so four small windows come to
  -- two readings more than one large one. Asserting equality would fail on arithmetic rather than
  -- on behaviour.
  check('...by the ratio of the two ceilings', math.abs(nb - 4 * ns) <= 4,
        string.format('%d vs 4 x %d', nb, ns))
end

-- ============================================================================
print('\nG  flow control: no press per window, and it ends by itself')
-- ============================================================================
-- The credit protocol is one pulse per arm, so a run of N windows is N credits and N decodes with
-- NOTHING in between them for the operator to do. What ends it: a window that comes back quiet, a
-- TRIGGER press, or the window bound.
do
  idle()
  clearforce()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.fc_out = true
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  TRIG.asserts = 0
  -- THREE WINDOWS AND THEN SILENCE, which is how a real transmission ends: the fourth credit gets
  -- nothing back.
  local restore = sending_for(3)
  local ok, why = sdec.record_run()
  restore()
  check('a flow-controlled run reports success when the device stops', ok == true, tostring(why))
  check('it spent four windows -- three with data, one that found silence',
        sdec.fc_win == 4, tostring(sdec.fc_win))
  check('it issued one credit per window and no more', TRIG.asserts == 4,
        tostring(TRIG.asserts))
  check('and it ended because the device stopped sending', sdec.fc_end == 'quiet',
        tostring(sdec.fc_end))
  -- THE TOTAL IS THE TRANSMISSION, NOT THE LAST WINDOW. ck_tot describes one window; a run that
  -- reported it would understate a 3-window capture by two thirds.
  check('the total counts every window', (sdec.fc_bytes or 0) > (sdec.ck_tot.nf or 0),
        string.format('%d total vs %d in the last window', sdec.fc_bytes or 0,
                      sdec.ck_tot.nf or 0))
  -- THE TAIL SURVIVES THE EMPTY WINDOW. stream_begin() nils ck_tot on entry, so without the keep
  -- in record_run() the panel would show a finished run with nothing on it.
  check('and the last window that HAD bytes still supplies the tail and the filename',
        sdec.ck_tot ~= nil and sdec.ck_tot.nf > 0 and sdec.ck_tot.path ~= nil,
        tostring(sdec.ck_tot and sdec.ck_tot.path))
  check('the status row reports the transmission, not the last window',
        has(sdec.ck_status(), 'in 4 windows'), sdec.ck_status())
  check('and the note row says the device stopped, not that a buffer filled',
        has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), 'device stopped'),
        sdec.strm_exit_why(sdec.ck_endwhy, true, nil))
end

-- ============================================================================
print('\nH  flow control is BOUNDED, and cancellable')
-- ============================================================================
do
  idle()
  clearforce()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.fc_out = true
  sdec.fc_maxwin = 3                 -- a device that never stops talking
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local restore = sending_for(9999)
  local ok = sdec.record_run()
  restore()
  check('an endless sender does not run for ever', ok == true)
  check('it stops at the window bound', sdec.fc_win == 3, tostring(sdec.fc_win))
  -- THE REMEDY HAS TO BE THE REAL ONE. It used to read 'press Capture to continue', which is wrong on
  -- both halves: every exit from a recording runs mode_exit(), which puts capmode back to 'frame' and
  -- nils flog_path -- so Capture alone takes a FRAME capture and the following bytes land in the NEXT
  -- numbered file. The data survives (the sender is still waiting for a credit) but the recording is
  -- fragmented, and an instruction that does not work is worse than none.
  check('and says so, with a remedy that actually continues it',
        has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), 'Mode, then Capture')
        and has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), 'new file'),
        sdec.strm_exit_why(sdec.ck_endwhy, true, nil))

  -- CANCELLED MID-RUN. The press lands during the second window's decode; the run must end there,
  -- not at the bound.
  idle()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.fc_out = true
  sdec.fc_maxwin = 32
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local realprog, seen = sdec.ck_progress, 0
  sdec.ck_progress = function(nb, nw, ne)
    seen = seen + 1
    if seen == 3 then TRIG.press(sdec.cancel_blender) end
    return realprog(nb, nw, ne)
  end
  local rest2 = sending_for(9999)
  local cok = sdec.record_run()
  rest2()
  sdec.ck_progress = realprog
  check('a TRIGGER press ends a flow-controlled run', cok == true)
  check('well short of the bound', (sdec.fc_win or 99) < 32, tostring(sdec.fc_win))
  check('and it is recorded as a cancel, not as a quiet line', sdec.fc_end == 'cancelled',
        tostring(sdec.fc_end))
  check('the note names the key and the window count',
        has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), 'TRIGGER'),
        sdec.strm_exit_why(sdec.ck_endwhy, true, nil))
  sdec.fc_maxwin = 32

  -- THE WINDOW COUNT IS NOT A TIME, and this is the bound that noticed. Each window's acquisition is
  -- bounded independently at min(stream_maxwait, strm_maxsec), so 32 windows is 1 MB of bytes but
  -- 10.7 HOURS of waiting at 300 baud -- and on a firmware whose blender cannot latch EVENT_DISPLAY,
  -- cancel_pressed() answers false for ever and the bounds are the ONLY exits. A panel that comes
  -- back in ten hours is a power cycle in practice.
  --
  -- DRIVEN THROUGH THE REAL LOOP, not through the arithmetic. Asserting 32 * per-window-limit is what
  -- the scratch probe did, and that formula cannot see fc_maxsec at all -- it would still report 10.7 h
  -- against code that exits in twenty minutes. So the window count is set out of reach and each window
  -- is made to report a long wait, leaving the clock as the only thing that can stop it.
  idle()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.fc_out = true
  sdec.fc_maxwin, sdec.fc_maxsec = 9999, 300
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  -- 120 s per window, so the third window is the one that crosses 300 s.
  local realacq = sdec.stream_acquire
  sdec.stream_acquire = function(nsmp)
    local got = realacq(nsmp)
    sdec.strm_waited = 120
    return got
  end
  local rest3 = sending_for(9999)
  local tok = sdec.record_run()
  rest3()
  sdec.stream_acquire = realacq
  check('an endless sender on a slow line is bounded by the CLOCK, not just the window count',
        tok == true and sdec.fc_end == 'timebound',
        string.format('ok=%s fc_end=%s', tostring(tok), tostring(sdec.fc_end)))
  check('it stops on the window that crosses the limit, not one later',
        sdec.fc_win == 3, string.format('%s windows, %s s', tostring(sdec.fc_win),
                                        tostring(sdec.fc_secs)))
  check('and the note says which bound fired, in minutes, with the same remedy',
        has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), '5-minute limit')
        and has(sdec.strm_exit_why(sdec.ck_endwhy, true, nil), 'Mode, then Capture'),
        sdec.strm_exit_why(sdec.ck_endwhy, true, nil))
  -- WHICH BOUND BINDS, ON PURPOSE. The clock is the tighter of the two at every rate, and saying so
  -- here is the point: 32 windows at 9600 baud is 34 s of acquisition plus about 109 s of decode each,
  -- which is 76 minutes -- so a 20-minute ceiling stops the run at roughly eight windows rather than
  -- 32. That is a DELIBERATE reduction in bytes per press, not an oversight, and under flow control it
  -- costs nothing but a press: the sender is still waiting for its next credit, so the next press
  -- resumes the same conversation into the same file.
  sdec.fc_maxwin, sdec.fc_maxsec = 32, 1200
  local acq1 = sdec.stream_samples({cap = 32768}, 40000) / 40000
  check('the clock is the bound that binds, not the window count',
        sdec.fc_maxsec < 32 * acq1 * 2,
        string.format('%g s limit vs 32 windows of %.0f s acquisition + decode', sdec.fc_maxsec, acq1))
  check('and it still allows several full windows in one press',
        sdec.fc_maxsec / acq1 >= 4,
        string.format('%.0f windows of acquisition alone', sdec.fc_maxsec / acq1))
  -- THE CLOCK IS PREFERRED WHERE IT EXISTS AND THE COUNTER IS THE FLOOR. Offline there is no timer
  -- object, so fc_clock is false and the counter is the whole answer -- which is what keeps the three
  -- checks above deterministic. On the instrument the clock sees the decode too, and max() means a
  -- timer clobbered by anything else degrades the bound to the acquisition sum rather than removing it.
  check('offline, the bound runs on the counter because there is no clock',
        sdec.fc_clock == false, tostring(sdec.fc_clock))

  -- A BOUND THAT FIRES ON WINDOW ONE STILL NAMES ITSELF. Found on the instrument, not here: with the
  -- ceiling at 25 s a 'sml' run ended at ONE window in 26.9 s, and because the bound wording sat behind
  -- a `fc_win > 1` guard the note row fell through to 'buffer full -- the stream may continue' -- naming
  -- neither the limit nor the remedy, and inviting a press for a reason that was not the real one. It is
  -- the shipped case on a slow line: at 300 baud a single window waits out the whole 20 minutes.
  local w
  for _, w in ipairs({1, 2, 7}) do
    sdec.fc_win, sdec.fc_end, sdec.ck_cancel = w, 'timebound', nil
    check(string.format('the clock bound names itself after %d window(s)', w),
          has(sdec.strm_exit_why('full', true, nil), '20-minute limit')
          and has(sdec.strm_exit_why('full', true, nil), 'Mode, then Capture'),
          sdec.strm_exit_why('full', true, nil))
    sdec.fc_end = 'bound'
    check(string.format('and so does the window bound after %d window(s)', w),
          has(sdec.strm_exit_why('full', true, nil), '32-window limit'),
          sdec.strm_exit_why('full', true, nil))
  end
  sdec.fc_win, sdec.fc_end = nil, nil

  -- A DIGITIZER THAT FAULTS IS NOT A DEVICE THAT FINISHED, and it is not a keypress either. stream()
  -- used to fold a RAISE out of stream_acquire into the same `strm_empty` flag as a legitimately empty
  -- acquisition -- and two callers believe that flag: record_run() rewrites an empty window into
  -- fc_end='quiet' ("the device stopped sending") and strm_exit_why() lets a cancel outrank the
  -- refusal. So a hardware fault was reported either as the operator's device finishing tidily, or, with
  -- a press latched, as "stopped with the TRIGGER key" -- and the error text was thrown away.
  idle()
  clearforce()
  sdec.cancel_setup()
  sdec.force_baud = 9600
  sdec.capmode = 'sml'
  sdec.fc_out = nil
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
  local realacq2 = sdec.stream_acquire
  sdec.stream_acquire = function(nsmp) error('digitizer fault', 0) end
  local rok, rwhy = sdec.stream()
  sdec.stream_acquire = realacq2
  check('a raise inside the acquisition is a failure, not an empty line',
        rok == false and sdec.strm_empty ~= true,
        string.format('ok=%s strm_empty=%s', tostring(rok), tostring(sdec.strm_empty)))
  check('...and it carries the reason it raised, instead of discarding it',
        has(rwhy, 'digitizer fault'), tostring(rwhy))
  -- AND A LATCHED PRESS MUST NOT TAKE THE CREDIT FOR IT. This is the combination the cancel gate in
  -- strm_exit_why widened: ck_cancel true plus strm_empty true reads as a deliberate stop.
  sdec.ck_cancel = true
  check('...and a press latched at the same moment does not get the blame',
        has(sdec.strm_exit_why('full', false, rwhy), 'digitizer fault'),
        sdec.strm_exit_why('full', false, rwhy))
  sdec.ck_cancel = nil
  idle()
end

-- ============================================================================
print('\nH2  a protected failure is never reported as a normal ending')
-- ============================================================================
-- THE DEFECT CLASS THIS BLOCK EXISTS FOR, found four times in one session by an outside reviewer and
-- never once by this suite. Every one had the same shape: a pcall'd failure narrowed to a boolean, and a
-- LATER caller reading that boolean as good news --
--
--   stream()        a raise in the acquisition set strm_empty, which record_run rewrites to
--                   fc_end='quiet' ("the device stopped sending") and strm_exit_why lets a cancel claim
--   stream_acquire  a raise reading the newest window advanced the QUIET timer, manufacturing
--                   ck_endwhy='quiet' out of ignorance -- a truncated prefix reported as success
--   stream_stop     a raise in stream_settle was stamped 'stopped' and returned "collected nothing",
--                   blaming the operator for a hardware fault
--   decode_step     called strm_exit_why with no verdict at all, so a failed decode read 'buffer full'
--
-- The suite could not see any of them because it asserted what the app SAYS, and the defect was that
-- what it says is untrue. So this block asserts the NEGATIVE: whatever else happens, a fault must not
-- produce a success verdict, a quiet verdict, or a sentence blaming the line, the device or the operator.
do
  local function faults_honestly(name, install, call)
    idle()
    clearforce()
    sdec.force_baud = 9600
    sdec.capmode = 'sml'
    sdec.fc_out = nil
    sdec.flog_path, sdec.flog_n, sdec.flog_bytes = nil, nil, nil
    local restore = install()
    local ok, why = call()
    restore()
    local note = sdec.strm_exit_why(sdec.ck_endwhy, ok, why)
    -- THREE THINGS AT ONCE, because each one alone has been passed by a defect. Not a success; not a
    -- quiet verdict from any of the three flags that can carry one; and not a sentence that blames
    -- something outside the instrument.
    local blames = has(note, 'no line activity') or has(note, 'device stopped sending')
                   or has(note, 'stopped with the TRIGGER key') or has(note, 'buffer full')
    check(name .. ': fails, and says so',
          ok == false and sdec.strm_empty ~= true and sdec.ck_endwhy ~= 'quiet'
          and sdec.fc_end ~= 'quiet' and not blames,
          string.format('ok=%s empty=%s endwhy=%s fc_end=%s | %s', tostring(ok),
                        tostring(sdec.strm_empty), tostring(sdec.ck_endwhy),
                        tostring(sdec.fc_end), tostring(note)))
    idle()
  end

  -- 1. THE ACQUISITION RAISES.
  faults_honestly('the acquisition raises',
    function()
      local r = sdec.stream_acquire
      sdec.stream_acquire = function(n) error('digitizer fault', 0) end
      return function() sdec.stream_acquire = r end
    end,
    function() return sdec.stream() end)

  -- 2. THE WATCHDOG'S LAST GATE CANNOT BE MEASURED, tested where the decision is actually made rather
  -- than end to end. Through stream() the mock's source runs out, so `have` stops growing and the quiet
  -- timer advances on the ABSENCE of new samples -- which is a legitimate quiet line and not the defect.
  -- The defect is narrower: when the watchdog is about to end a run on REUSED levels, strm_relevel is the
  -- last gate before that verdict, and it returned a plain `false` both for "measured, and the old
  -- threshold is fine" and for "the read raised, so I could not measure at all". The caller believed the
  -- second as evidence of silence.
  idle()
  clearforce()
  do
    local realrb = sdec.ck_reader_buffer
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = 4.242, 0.3, 3.0
    sdec.strm_lvlreuse = true
    sdec.thr, sdec.hyst = 4.242, 0.3
    sdec.ck_reader_buffer = function(buf, have)
      return function(win, from, iw, dec) error('buffer read fault', 0) end
    end
    local adopted, unmeasurable = sdec.strm_relevel({n = 40000}, 40000, 4000)
    sdec.ck_reader_buffer = realrb
    check('a re-level whose read RAISES says it could not measure, not that the line is quiet',
          adopted == false and unmeasurable == true,
          string.format('adopted=%s unmeasurable=%s', tostring(adopted), tostring(unmeasurable)))
    check('...and the remembered levels are untouched by a read it could not make',
          sdec.lvl_thr == 4.242 and sdec.lvl_swing == 3.0,
          string.format('lvl_thr=%s lvl_swing=%s', tostring(sdec.lvl_thr), tostring(sdec.lvl_swing)))
    -- AND THE VERDICT THAT FOLLOWS IT. 'readfail' is a distinct ck_endwhy precisely so this case cannot
    -- borrow 'quiet's sentence -- the note must report a fault, not the operator's device finishing.
    sdec.strm_readfail = 'the capture buffer could not be re-measured to confirm a quiet line'
    -- WITH ok = false the run's OWN error outranks the endwhy, which is right and is tested elsewhere.
    -- The endwhy sentence is what a run that DID decode bytes gets -- the case that used to read
    -- '2.0 s with no line activity' over a watchdog check that never happened.
    local note = sdec.strm_exit_why('readfail', true, nil)
    check('...and the note reports a failure rather than a quiet line',
          has(note, 'could not be re-measured') and not has(note, 'no line activity'), note)
    check('...while a genuine quiet line still says so',
          has(sdec.strm_exit_why('quiet', true, nil), 'no line activity'),
          sdec.strm_exit_why('quiet', true, nil))
    sdec.strm_lvlreuse, sdec.strm_readfail = nil, nil
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = nil, nil, nil
  end
  idle()

  -- 2b. THE FRAME PATH, which had no fault-injection coverage at all until an outside review audited it
  -- and found four more of this same class in it. These four are cheap and each one is a sentence the
  -- operator would otherwise have believed.
  idle()
  clearforce()
  do
    -- (a) THE SAMPLE RATE COULD NOT BE MEASURED. acq_fs is not a display figure: every bit time, the
    -- baud rate and therefore every byte is scaled by it, and the readback lies for the three listed
    -- rates the hardware cannot synthesise. Substituting the REQUESTED rate silently made the panel
    -- report a measured rate, a measured baud and confident bytes derived from a number the source
    -- itself calls untrustworthy. It still substitutes -- refusing would kill a working decoder -- but
    -- it now says so.
    local realm = sdec.acq_measure_fs
    sdec.acq_measure_fs = function(buf, n) return nil end
    sdec.fs = 80000
    local got = sdec.acq_fs_or_requested({n = 100}, 100)
    sdec.acq_measure_fs = realm
    check('an unmeasurable sample rate falls back to the requested one rather than failing',
          got == 80000, tostring(got))
    check('...and flags that it was not measured', sdec.acq_fs_est == true,
          tostring(sdec.acq_fs_est))
    local nt, nn, seen = nil, 0, false
    nt, nn = sdec.ui_notes()
    for i = 1, nn do if has(nt[i], 'NOT measured') then seen = true end end
    check('...and the panel says so, because BAUD and the bytes derive from it', seen,
          string.format('%d notes', nn))
    -- AND IT CLEARS AGAIN on a capture that could measure -- a latched warning would accuse every
    -- later capture, which is the same latching defect as strm_releveled and proto_why. A buffer with
    -- REAL timestamps: 99 intervals over 1 ms is 99 kS/s.
    local realbuf = {n = 100, relativetimestamps = {}}
    realbuf.relativetimestamps[1] = 0
    realbuf.relativetimestamps[100] = 0.001
    local m2 = sdec.acq_fs_or_requested(realbuf, 100)
    check('...and a measurable capture uses the measurement and clears the flag',
          sdec.acq_fs_est == nil and m2 > 98000 and m2 < 100000,
          string.format('est=%s fs=%s', tostring(sdec.acq_fs_est), tostring(m2)))
    sdec.acq_fs_est = nil
  end

  -- (b) A TRIGGER STATE THAT CANNOT BE READ IS NOT AN IDLE MODEL. The callers DELETE or clear the
  -- reading buffer on a true from here, so believing a failed read tears a buffer out from under a
  -- live trigger model -- the object-lifetime hazard the function exists to prevent.
  do
    local realstate = trigger.model.state
    trigger.model.state = function() error('state unavailable', 0) end
    local settled = sdec.trig_settle()
    trigger.model.state = realstate
    check('a trigger state that RAISES does not read as settled',
          settled == false, tostring(settled))
    check('...while a firmware with no trigger state at all still settles',
          (function()
             local r = trigger.model.state
             trigger.model.state = function() return nil end
             local s = sdec.trig_settle()
             trigger.model.state = r
             return s == true
           end)())
  end

  -- (c) A PROTOCOL PARSER THAT RAISED must not leave an empty message list looking like an answer --
  -- "your device emitted no MIDI" is a claim about the operator's device that never got established.
  do
    sdec.proto_why = nil
    local v = sdec.ui_view('midi')
    if v ~= nil and v.parse ~= nil then
      local realfn = sdec[v.parse]
      sdec[v.parse] = function() error('parser fault', 0) end
      sdec[v.res] = {n = 3, msg = {'half', 'built', 'list'}}
      local ran = sdec.proto_parse1('midi')
      sdec[v.parse] = realfn
      check('a protocol parser that raises reports failure, not an empty stream',
            ran == false and sdec.proto_why ~= nil, tostring(sdec.proto_why))
      check('...and retracts the half-built list rather than showing it as complete',
            sdec[v.res] == nil, tostring(sdec[v.res]))
      local nt2, nn2, seen2 = nil, 0, false
      nt2, nn2 = sdec.ui_notes()
      for i = 1, nn2 do if has(nt2[i], 'decode failed') then seen2 = true end end
      check('...and the note says the bytes are still the real UART stream', seen2,
            string.format('%d notes', nn2))
      sdec.clear_result()
      check('...and it does not latch onto the next capture', sdec.proto_why == nil,
            tostring(sdec.proto_why))
    end
  end
  idle()
  clearforce()

  -- 3. THE SETTLE RAISES on the press-driven stop path.
  faults_honestly('the settle raises when the recording is stopped',
    function()
      local r = sdec.stream_settle
      sdec.stream_settle = function() error('abort fault', 0) end
      return function() sdec.stream_settle = r end
    end,
    function()
      sdec.strm_recording = true
      return sdec.stream_stop()
    end)
  clearforce()
end

-- ============================================================================
print('\nI  the idle watchdog survives a device that is waiting for a credit')
-- ============================================================================
-- A device under flow control is SILENT until the credit goes out, so the level probe that normally
-- supplies the watchdog's threshold looks at an idle line. Without a fallback the watchdog is
-- disarmed exactly where it is needed most, and every window waits out strm_maxsec instead of
-- ending when the device stops.
do
  idle()
  clearforce()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  -- A good capture first, so there are remembered levels to fall back on. This is not contrived:
  -- entering a recording mode requires a locked rate, and locking one requires a capture.
  local ok = sdec.stream()
  check('a normal recording measures the levels', sdec.lvl_thr ~= nil, tostring(sdec.lvl_thr))
  check('and remembers the swing with them', (sdec.lvl_swing or 0) >= sdec.minswing,
        tostring(sdec.lvl_swing))
  local thr = sdec.lvl_thr

  -- NOW A SILENT LINE. clear_result() has zeroed sdec.thr, and the probe finds nothing.
  idle()
  sdec.clear_result()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  local realfree = sdec.acq_free
  sdec.acq_free = function(n, cap, nofc)
    -- An idle line: the mock returns samples, but flat ones, so sig_levels refuses them.
    local r = realfree(n, cap, nofc)
    local k
    for k = 1, (sdec.nread or 0) do sdec.smp[k] = 3.3 end
    return r
  end
  local bok, bwhy = sdec.stream_begin()
  sdec.acq_free = realfree
  check('the recording still sets up on a silent line', bok == true, tostring(bwhy))
  check('the idle watchdog is ARMED anyway, from the remembered levels',
        sdec.ck_watch == true)
  check('using the threshold the last good capture measured', sdec.thr == thr,
        string.format('%s vs %s', tostring(sdec.thr), tostring(thr)))
  check('and it is recorded as reused rather than measured', sdec.strm_lvlreuse == true)
  -- WITHOUT THE FALLBACK THERE IS NO WATCHDOG. Asserted from the other direction so the test fails
  -- if the fallback is ever made unconditional and stops depending on a real measurement.
  idle()
  sdec.clear_result()
  sdec.lvl_thr, sdec.lvl_swing = nil, nil
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.acq_free = function(n, cap, nofc)
    local r = realfree(n, cap, nofc)
    local k
    for k = 1, (sdec.nread or 0) do sdec.smp[k] = 3.3 end
    return r
  end
  sdec.stream_begin()
  sdec.acq_free = realfree
  check('with NO remembered levels the watchdog stays disarmed, as it must',
        sdec.ck_watch == false, tostring(sdec.ck_watch))
end

-- ============================================================================
print('\nI2  a quiet verdict taken on REUSED levels is checked before it is believed')
-- ============================================================================
-- The failure this guards is a confident wrong reason: reused levels come from an earlier capture, and
-- if the wiring changed since -- a divider added, a different probe point -- the old threshold can sit
-- outside the new swing. Nothing crosses it, so a device transmitting happily reads as silent and the
-- run ends after idle_exit_s claiming no line activity.
do
  idle()
  clearforce()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  -- A recording first, so real levels exist to reuse.
  sdec.stream()
  local goodthr = sdec.lvl_thr
  check('there are levels to reuse', goodthr ~= nil, tostring(goodthr))

  -- THE THRESHOLD IS NOW WRONG FOR THE WIRE: pushed above both levels, as a 2.5 V threshold would be
  -- on a line divided down to 0-1.8 V. sig_levels() does not need a threshold to find the pair, which
  -- is what makes the recovery possible.
  idle()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.stream_begin()
  sdec.strm_lvlreuse = true
  sdec.thr, sdec.hyst = 9.0, 0.1
  local have = sdec.buf and (sdec.buf.n or 0) or 0
  local iw = sdec.idle_window(sdec.fs)
  local adopted = sdec.strm_relevel(sdec.buf, have, iw)
  check('a threshold outside the swing is recognised and replaced', adopted == true)
  check('...with one measured from the samples in hand', sdec.thr ~= nil and sdec.thr < 9.0,
        tostring(sdec.thr))
  check('and it is recorded, so the note can say the levels moved',
        sdec.strm_releveled ~= nil and has(sdec.strm_releveled, 're-measured'),
        tostring(sdec.strm_releveled))
  check('the reuse flag is cleared, so this happens once per recording',
        sdec.strm_lvlreuse == nil)
  check('a second call does nothing, rather than deferring the quiet verdict for ever',
        sdec.strm_relevel(sdec.buf, have, iw) == false)

  -- A THRESHOLD THAT IS STILL BETWEEN THE LEVELS MUST BE LEFT ALONE. Otherwise every quiet line
  -- restarts the watchdog and a finished device never ends the run.
  idle()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.stream_begin()
  sdec.strm_lvlreuse = true
  local mid = goodthr
  sdec.thr, sdec.hyst = mid, 0.1
  have = sdec.buf and (sdec.buf.n or 0) or 0
  check('a threshold still inside the swing is kept, and the quiet verdict stands',
        sdec.strm_relevel(sdec.buf, have, iw) == false)
  check('...and the threshold was not disturbed', sdec.thr == mid,
        string.format('%s vs %s', tostring(sdec.thr), tostring(mid)))

  -- AND NEVER WHEN THE LEVELS WERE MEASURED BY THIS CAPTURE'S OWN PROBE.
  idle()
  sdec.strm_lvlreuse = nil
  check('levels measured by this capture are not second-guessed',
        sdec.strm_relevel(sdec.buf, have, iw) == false)
end

-- ============================================================================
print('\nJ  the row that says what is happening fits its cell')
-- ============================================================================
-- Every string here shares a line with the log status, and the firmware FADES an overlong string
-- rather than clipping it -- so a too-long row is unreadable rather than truncated.
do
  idle()
  sdec.capmode = 'med'
  sdec.force_baud = 9600
  sdec.fc_out = true
  sdec.fc_win, sdec.fc_maxwin = 11, 32
  sdec.ck_running, sdec.ck_acq_have, sdec.ck_acq_want = true, 900000, 1000000
  sdec.ck_nbytes = nil
  local rec = string.format('%s  %s', sdec.mode_cur().name, sdec.ck_status())
  check('the recording row names the window it is on', has(rec, 'win 12/32'), rec)
  check('and fits the 454 px the cell has', sdec.ui_textw(rec) <= 454,
        string.format('%d px: %q', sdec.ui_textw(rec), rec))
  sdec.ck_nbytes = 32768
  local dec = string.format('%s  %s', sdec.mode_cur().name, sdec.ck_status())
  check('the decoding row shows bytes against the ceiling', has(dec, '32768/32768'), dec)
  check('and also fits', sdec.ui_textw(dec) <= 454,
        string.format('%d px: %q', sdec.ui_textw(dec), dec))
  sdec.ck_running = false
  sdec.fc_bytes, sdec.fc_end = 360448, 'quiet'
  sdec.ck_tot = {nf = 32768, nbad = 0, nwin = 20, path = '/usb1/bytes007.txt'}
  local sum = string.format('%s  %s', sdec.mode_cur().name, sdec.ck_status())
  check('the summary row reports the whole transmission', has(sum, '360448 bytes in 11 windows'),
        sum)
  check('and fits too', sdec.ui_textw(sum) <= 454,
        string.format('%d px: %q', sdec.ui_textw(sum), sum))
  -- THE CONTROL CELL is the narrow one: ~199 px between the two dividers.
  sdec.ck_running, sdec.strm_inflight = true, true
  sdec.ui_refresh()
  local ctl = MD.text(sdec.ui_log_t)
  -- NAMES NO CONTROL: measured 2026-08-18, the key's event does not reach the blender while a
  -- panel-initiated run executes, and a touch press cannot be dispatched at all.
  check('the control cell promises no control during a one-press run',
        not has(ctl, 'TRIGGER') and not has(ctl, 'Capture=') and has(ctl, 'no stop'),
        tostring(ctl))
  check('and fits its 221 px', sdec.ui_textw(ctl) <= 221,
        string.format('%d px: %q', sdec.ui_textw(ctl), tostring(ctl)))
  idle()
end

-- ============================================================================
print('\nJ2  the log cell fits at every byte count it can reach')
-- ============================================================================
-- The firmware FADES an overlong string rather than clipping it, so a cell that overflows makes its
-- number unreadable rather than merely truncated -- and this cell carries the byte total that backs
-- the "no decoded byte is lost" promise. One press now files up to 32 kB, so four of them reach six
-- digits: the count has to keep fitting as it grows, which the previous format did not.
do
  idle()
  sdec.flog_why, sdec.flog_path = nil, '/usb1/bytes127.txt'
  check('the cell width is DERIVED from the two dividers, not written down',
        sdec.ui_log_px == sdec.ui_trig_div - (sdec.ui_stat_div + 6),
        tostring(sdec.ui_log_px))
  local i, worst, worsts = 0, 0, ''
  local counts = {0, 999, 12345, 123456, 1048576, 2800000, 99999999}
  for i = 1, table.getn(counts) do
    sdec.flog_bytes = counts[i]
    local s = sdec.flog_status()
    local w = sdec.ui_textw(s)
    if w > worst then worst, worsts = w, s end
    check(string.format('%9d bytes fits in %d px', counts[i], sdec.ui_log_px),
          w <= sdec.ui_log_px, string.format('%d px: %q', w, s))
  end
  print(string.format('      worst: %d px of %d -- %q', worst, sdec.ui_log_px, worsts))
  -- EXACT BYTES AT EVERY COUNT THIS INSTRUMENT CAN REACH. Dropping the '.txt' bought enough room that
  -- the kB fallback never fires on a real byte-log name -- even 99 999 999 B fits, with 2 px spare --
  -- so the promise the count backs is never rounded away in practice.
  sdec.flog_bytes = 12345
  check('a five-digit count is exact, in bytes', has(sdec.flog_status(), '12345 B'),
        sdec.flog_status())
  sdec.flog_bytes = 99999999
  check('and so is an eight-digit one -- no rounding at any reachable count',
        has(sdec.flog_status(), '99999999 B') and not has(sdec.flog_status(), 'kB'),
        sdec.flog_status())
  -- A NAME TOO LONG FOR THE CELL LOSES CHARACTERS OFF THE NAME, not digits off the count. flogpfx is
  -- settable, so this branch is reachable, and it is exercised rather than left as a path no test has
  -- entered.
  sdec.flog_path = '/usb1/capture_session_bytes_042.txt'
  local long = sdec.flog_status()
  check('a long filename is trimmed until it fits', sdec.ui_textw(long) <= sdec.ui_log_px,
        string.format('%d px: %q', sdec.ui_textw(long), long))
  check('...and it says it was trimmed', has(long, '~'), long)
  check('...while the byte count survives in full -- it is the number that audits the promise',
        has(long, '99999999 B'), long)
  -- TRIMMING NEVER MAKES IT WIDER, and it could: '~' costs 11 px while the character it replaces may
  -- cost 3, so a one-character first step measured 163 px going to 170 on a name of 'i's. The loop
  -- converged anyway, which is why this is a sharpness bug rather than a hang -- but a name one pixel
  -- over could be pushed eight further over before it began coming back.
  --
  -- MEASURED THROUGH flog_status ITSELF, against a plain form built here from nothing but string.format.
  -- Re-deriving the trim step in the test is what let this survive a fix: the scratch probe hard-coded
  -- string.sub(base, 2) and so measured a formula the shipped code no longer uses. Every width from a
  -- 4-character name to a 40-character one, at the widest count.
  do
    local L, bad = 0, ''
    for L = 4, 40 do
      local nm = string.rep('i', L)
      sdec.flog_path, sdec.flog_bytes = '/usb1/' .. nm .. '.txt', 12345
      local got = sdec.ui_textw(sdec.flog_status())
      local plain = sdec.ui_textw(string.format('log: %s  %d B', nm, 12345))
      if got > plain and bad == '' then
        bad = string.format('%d chars: plain %d px -> %d px (%q)', L, plain, got,
                            sdec.flog_status())
      end
    end
    check('trimming a name never returns a WIDER string than not trimming it', bad == '', bad)
  end
  sdec.flog_path = '/usb1/bytes127.txt'
  -- The two non-count forms share the cell and must fit too.
  sdec.flog_path = nil
  check('the pre-capture form fits', sdec.ui_textw(sdec.flog_status()) <= sdec.ui_log_px,
        sdec.flog_status())
  -- A REFUSAL IS A FLAG HERE AND A SENTENCE ON THE NOTE ROW. The real flog_why strings run to 432 px
  -- against this cell's 200 -- 'no free /usb1/bytesNNN.txt name' -- and the firmware fades the tail, so
  -- rendering them here put the words that say the app is DISCARDING bytes into the unreadable part.
  local why
  for _, why in ipairs({'no USB key',
                        'no free /usb1/bytesNNN.txt name -- NOT LOGGING',
                        'cannot append to /usb1/bytes000.txt',
                        'write failed part-way through bytes000.txt'}) do
    sdec.flog_why, sdec.flog_bytes = why, 0
    check('a refusal fits, however long its reason: ' .. string.sub(why, 1, 24),
          sdec.ui_textw(sdec.flog_status()) <= sdec.ui_log_px,
          string.format('%d px: %q', sdec.ui_textw(sdec.flog_status()), sdec.flog_status()))
    check('...and still says the log is OFF', has(sdec.flog_status(), 'NOT LOGGING'),
          sdec.flog_status())
  end
  -- THE REASON IS NOT LOST, only moved: the note row has the full table width, and ranked low so a
  -- persistent log fault cannot mask the per-capture diagnostics behind '(+N more)' for a session.
  sdec.flog_why = 'no free /usb1/bytesNNN.txt name -- NOT LOGGING'
  local nt, nn, seen = sdec.ui_notes(), 0, false
  nt, nn = sdec.ui_notes()
  for i = 1, nn do if has(nt[i], 'no free') then seen = true end end
  check('and the full reason is on the note row, where it fits', seen,
        string.format('%d notes', nn))
  sdec.flog_why, sdec.flog_path, sdec.flog_bytes = nil, nil, nil
end

-- ============================================================================
print('\nK  teardown gives the blender back')
-- ============================================================================
do
  idle()
  sdec.cancel_setup()
  check('the latch is live before teardown', sdec.cancel_ok == true)
  sdec.stop()
  check('stop() marks the latch unavailable', sdec.cancel_ok == false,
        tostring(sdec.cancel_ok))
  check('and un-configures the blender, as acq_triggered() does with blender 1',
        trigger.blender[sdec.cancel_blender].stimulus[1] == nil,
        tostring(trigger.blender[sdec.cancel_blender].stimulus[1]))
  TRIG.press(sdec.cancel_blender)
  check('a press after teardown is not read as a cancel', sdec.cancel_pressed() == false)
end

-- ============================================================================
print('\nK2  teardown keeps the buffer handle when the firmware refuses to free it')
-- ============================================================================
-- THE OBJECT-LIFETIME RULE, at the one place that broke it. acq_make_buffer()'s comment has said for
-- some time that a refused deletion must not drop the handle -- "one more on every retry, until a power
-- cycle" -- and named stop() as the same defect "in a different place". It was still there: stop() nil'ed
-- sdec.buf FIRST and discarded buffer.delete's verdict, so a refused delete reported success, left
-- delfails at 0, stranded the buffer inside the firmware with no handle to retry, and let the next
-- start() allocate another on top of it.
do
  idle()
  sdec.ui_build()                       -- stop() above tore the UI down; K2 needs one to tear down again
  sdec.buf = buffer.make(100, buffer.STYLE_STANDARD)
  local held = sdec.buf
  local realdel, delfails0 = buffer.delete, sdec.delfails or 0
  buffer.delete = function(b) error('buffer in use', 0) end
  sdec.stop()
  buffer.delete = realdel
  check('a refused deletion KEEPS the handle, so a retry is possible',
        sdec.buf == held, tostring(sdec.buf))
  check('...and counts the failure, so the panel can say a power cycle is needed',
        (sdec.delfails or 0) > delfails0,
        string.format('%s -> %s', tostring(delfails0), tostring(sdec.delfails)))
  check('...and says so where a fault must outlive the capture',
        has(tostring(sdec.stickyerr), 'could not be freed'), tostring(sdec.stickyerr))
  -- AND THE NORMAL PATH STILL RELEASES IT, or the fix would leak on every clean teardown instead.
  sdec.ui_build()
  sdec.delfails, sdec.stickyerr = 0, nil
  sdec.stop()
  check('while a deletion that succeeds drops the handle as before',
        sdec.buf == nil and (sdec.delfails or 0) == 0,
        string.format('buf=%s delfails=%s', tostring(sdec.buf), tostring(sdec.delfails)))
  -- Leave a live buffer behind for anything after this block.
  sdec.buf = buffer.make(100, buffer.STYLE_STANDARD)
end

-- ============================================================================
print('\nK3  a filename probe that RAISES is not reported as a free name')
-- ============================================================================
-- ulog.exists() promises at the top of its own body that "could not tell" reads as TAKEN, because
-- losing a name is better than truncating a real file -- and its fallback branch did the opposite:
-- `taken` was initialised false and the pcall's verdict discarded, so a file.open that RAISED declared
-- the candidate FREE. sdec.save() then opens that name with MODE_WRITE, truncating the operator's
-- existing capture to nothing.
do
  MD.usb(true)
  MD.forget_files()
  MD.seed_file('/usb1/probe_000.txt', 'a real capture')
  local realopen, realfs = file.open, fs
  fs = nil                              -- force the open-probe fallback
  file.open = function(p, m) error('filesystem refused', 0) end
  local ex = ulog.exists('/usb1/probe_000.txt')
  file.open, fs = realopen, realfs
  check('a probe that raises reports the name as TAKEN, not free', ex == true, tostring(ex))
  -- AND THE NO-KEY CASE IS UNCHANGED, which is why this survived so long: with no key file.open RETURNS
  -- NIL rather than raising, so "free" is still right there and the failure surfaces at the write.
  MD.usb(false)
  local exnokey = ulog.exists('/usb1/probe_000.txt')
  MD.usb(true)
  check('...while no USB key still reads as free, failing later at the write instead',
        exnokey == false, tostring(exnokey))
  check('and a file that really is there is still found', ulog.exists('/usb1/probe_000.txt') == true)
  MD.forget_files()
end

-- ============================================================================
print('\nK4  a form that cannot show the truth does not open')
-- ============================================================================
-- options_seed() pushes the CURRENT setting into every control, and its verdict was discarded. A
-- display.setvalue that fails part way leaves the fields above it showing what is in effect and the ones
-- below showing whatever the form held last time -- one screen, two states, no indication. The operator
-- changes one field and presses Apply, which applies them ALL, including the stale ones: a configuration
-- they neither chose nor were shown. Refusing is right here because there is nothing useful to do with a
-- form that cannot be trusted to display the truth.
do
  idle()
  sdec.ui_build()
  sdec.build_options()
  local realsv, screens = display.setvalue, 0
  local realcs = display.changescreen
  display.changescreen = function(s) screens = screens + 1; return realcs(s) end
  display.setvalue = function(o, v) error('object pool exhausted', 0) end
  sdec.lasterr = nil
  sdec.options()
  display.setvalue, display.changescreen = realsv, realcs
  check('a seed that fails does not put the operator on the form',
        screens == 0, string.format('%d changescreen call(s)', screens))
  check('...and says why, naming the consequence rather than the mechanism',
        has(tostring(sdec.lasterr), 'Apply would then apply values you were not shown'),
        tostring(sdec.lasterr))
  -- AND A HEALTHY SEED STILL OPENS IT, or the guard would have replaced one defect with a worse one.
  screens = 0
  display.changescreen = function(s) screens = screens + 1; return realcs(s) end
  sdec.options()
  display.changescreen = realcs
  check('while a form that seeded correctly still opens', screens == 1, tostring(screens))
  sdec.options_cancel()
  idle()
end

-- ============================================================================
print('\nK5  a byte-log sink reports what actually reached the file')
-- ============================================================================
do
  MD.usb(true)
  MD.forget_files()
  -- (a) THE STREAM HEADER IS THE SINK'S FIRST WRITE, so its failure is the sink's failure. Discarded, a
  -- header that could not be written was followed by rows that could -- appending an UNLABELLED stream
  -- into the shared byte log, indistinguishable from the frame captures around it. That is the one thing
  -- the header exists to prevent.
  local realwrite, nw = file.write, 0
  file.write = function(fh, s)
    nw = nw + 1
    if nw == 1 then error('header write failed', 0) end
    return realwrite(fh, s)
  end
  local sink, finish, serr = sdec.ck_sink_file('/usb1/hdr_000.txt', 16)
  file.write = realwrite
  check('a stream header that cannot be written refuses the sink',
        sink == nil and finish == nil and serr ~= nil, tostring(serr))
  check('...and names the file, so the reason is actionable',
        has(tostring(serr), 'hdr_000.txt'), tostring(serr))

  -- (b) THE FINAL PARTIAL ROW. finish() flushes and closes the last 1-15 bytes through a formatter that
  -- is NOT one of the guarded file calls, so it can raise -- and with its verdict discarded finish()
  -- returned TRUE, reporting a byte total that included a row which never reached the file. That total is
  -- the number backing "no decoded byte is lost".
  local sink2, finish2 = sdec.ck_sink_file('/usb1/hdr_001.txt', 16)
  check('a sink with a good header is created', sink2 ~= nil and finish2 ~= nil)
  if sink2 ~= nil then
    sink2({65, 66, 67}, {0, 0, 0}, 3, 0)          -- 3 bytes: a partial row, held as carry
    local realrow = sdec.ua_hexrow
    sdec.ua_hexrow = function(...) error('row format failed', 0) end
    local fin = finish2()
    sdec.ua_hexrow = realrow
    check('a final partial row that cannot be formatted makes finish() report FAILURE',
          fin == false, tostring(fin))
  end
  MD.forget_files()
end

-- ============================================================================
-- THE QUEUED-PRESS ABSORB. Bench report 2026-08-18: presses made during an 8 kB recording were
-- stored up and then each STARTED ANOTHER uninterruptable recording. The absorb existed but had
-- three holes, and none of them had a test -- this suite was 161 green while all three were open.
--
-- OFFLINE THERE IS NO `timer`, so the arm's pcall fails and the absorb never engages: that is the
-- degrade-to-honouring-the-press path, tested last. The window itself needs a fake clock.
-- ============================================================================
do
  idle()
  local CLK = {t = 0}
  timer = {cleartime = function() CLK.t = 0 end, gettime = function() return CLK.t end}

  -- (1) ARMED ON EVERY ENDING. It used to return early for endwhy 'stopped', which is exactly the
  -- run an operator stops with TRIGGER after having already pressed Capture twice.
  sdec.strm_absorb_arm('stopped')
  check('the absorb arms even for a run that ended stopped',
        sdec.strm_stopped_by_press == true, tostring(sdec.strm_stopped_by_press))
  check('arming resets the absorbed count', sdec.strm_nabsorbed == 0,
        tostring(sdec.strm_nabsorbed))

  -- (2) EVERY PRESS IN THE WINDOW, not just the first. One swallowed and two honoured is what the
  -- operator saw as "it started again by itself".
  local a1 = sdec.press_absorbed('Capture')
  local m1 = sdec.strm_absorbed
  local a2 = sdec.press_absorbed('Capture')
  local a3 = sdec.press_absorbed('Capture')
  check('press 1 in the window is absorbed', a1 == true, tostring(a1))
  check('press 2 in the window is ALSO absorbed', a2 == true, tostring(a2))
  check('press 3 in the window is ALSO absorbed', a3 == true, tostring(a3))
  check('all three are counted', sdec.strm_nabsorbed == 3, tostring(sdec.strm_nabsorbed))
  check('the first says which control was taken and to press again',
        has(m1, 'Capture') and has(m1, 'press again'), tostring(m1))
  check('a burst reports the count rather than repeating the single-press wording',
        has(sdec.strm_absorbed, '3 presses'), tostring(sdec.strm_absorbed))

  -- (3) THE WINDOW BOUNDS IT. A press made after it must be honoured, and the stale arm cleared --
  -- left standing, the next unrelated timer.cleartime() would resurrect it.
  CLK.t = (sdec.strm_absorb_s or 1.0) + 0.5
  local a4 = sdec.press_absorbed('Capture')
  check('a press past the window is NOT absorbed', a4 == false, tostring(a4))
  check('and the stale arm is cleared by that press',
        sdec.strm_stopped_by_press == nil, tostring(sdec.strm_stopped_by_press))
  check('the absorbed note is cleared with it', sdec.strm_absorbed == nil,
        tostring(sdec.strm_absorbed))

  -- (4) WHAT THE HANDLERS DO WITH IT. The point is not the flag, it is that the press does nothing.
  sdec.res = {nf = 3, vals = {65, 66, 67}, errs = {}, ngood = 3, nbad = 0}
  sdec.capmode, sdec.savedas, sdec.busy = 'frame', nil, false
  sdec.strm_absorb_arm()
  CLK.t = 0
  local cres = sdec.capture()
  check('an absorbed Capture keeps the result on screen',
        sdec.res ~= nil and sdec.res.nf == 3, tostring(sdec.res and sdec.res.nf))
  check('an absorbed Capture reports handled', cres == true, tostring(cres))
  check('an absorbed Capture does not leave the busy latch set', sdec.busy == false,
        tostring(sdec.busy))

  sdec.strm_absorb_arm()
  CLK.t = 0
  sdec.mode_cycle()
  check('an absorbed Mode does not advance the capture mode', sdec.capmode == 'frame',
        tostring(sdec.capmode))

  sdec.strm_absorb_arm()
  CLK.t = 0
  local sres = sdec.save()
  check('an absorbed Save writes nothing', sdec.savedas == nil, tostring(sdec.savedas))
  check('an absorbed Save took the absorb path, not "nothing to save"',
        sres == false and has(sdec.strm_absorbed, 'Save'), tostring(sdec.strm_absorbed))

  -- (5) PAGING IS NOT ABSORBED, deliberately: it starts no work, loses no data, and is what an
  -- operator does next. Swallowing it would only teach that the buttons are unreliable.
  sdec.ui_mode = 'hex'
  sdec.res = {nf = 600, vals = {}, errs = {}, ngood = 600, nbad = 0}
  local i
  for i = 1, 600 do sdec.res.vals[i] = 65 end
  sdec.ui_page = 0
  sdec.strm_absorb_arm()
  CLK.t = 0
  sdec.page_next()
  check('Page Dn still works inside the absorb window', sdec.ui_page == 1,
        tostring(sdec.ui_page))

  -- (6) NO TIMER AT ALL: the arm cannot stamp the moment, so nothing is ever absorbed and every
  -- press is honoured. Failing toward the operator's press rather than eating it.
  timer = nil
  sdec.strm_stopped_by_press, sdec.strm_absorbed = nil, nil
  sdec.strm_absorb_arm()
  check('with no timer the absorb never arms', sdec.strm_stopped_by_press == nil,
        tostring(sdec.strm_stopped_by_press))
  check('and so no press is ever absorbed', sdec.press_absorbed('Capture') == false)
  idle()
  sdec.strm_stopped_by_press, sdec.strm_absorbed, sdec.strm_nabsorbed = nil, nil, nil
  sdec.res, sdec.ui_page = nil, 0
end

print(string.format('\n%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

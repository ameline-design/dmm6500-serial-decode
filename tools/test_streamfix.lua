-- test_streamfix.lua -- three streaming defects, one test each.
--
-- Shares tools/test_serial.lua's preamble, so these run against the REAL tsp/*.tsp sources and the
-- same mocked instrument. Each check below fails if its defect is reintroduced.
--
-- Run from the repo root:  lua tools/test_streamfix.lua

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

-- A line the mocked digitizer can hand back: 9600 baud at 100 kS/s, the rate pick_fs lands on.
local bytes = {}
local i
for i = 1, 60 do bytes[i] = 32 + math.mod(i * 7, 90) end
local rd, ts, nc, nsmp = GEN({bytes = bytes, baud = 9600, fs = 100000, lead = 20, n = 12000})
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
MD.usb(true)
MD.forget_files()
sdec.ui_build()

-- ============================================================================
print('\nA  the streaming arm applies both 4915 defences')
-- ============================================================================
-- sdec.acq_triggered() protects every armed capture twice against 4915 "attempting to store past
-- the capacity of a reading buffer": fillmode = 1 per capture, and 100 readings of headroom past
-- `count`. The press-driven streaming arm had neither, and its NORMAL ending -- the buffer reaching
-- nsmp -- is exactly the store the headroom is for.
do
  clearforce()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.ck_job, sdec.strm_recording = nil, nil
  local ok, why = sdec.stream_begin()
  check('a streaming recording can be set up at all', ok == true, tostring(why))
  local buf, nreq = sdec.buf, sdec.strm_nsmp

  -- MODEL WHAT THE INSTRUMENT DOES, which is the whole reason the fillmode call has to be per
  -- capture: acq_triggered records reading fillmode back as 0 on a buffer that was cleared and
  -- reused. Setting it at buffer.make() time is therefore not enough.
  local oldclear = buf.clear
  buf.clear = function() oldclear(); buf.fillmode = 0 end
  -- SNAPSHOTTED AT trigger.model.load, because that is the moment the state has to be right --
  -- and because the mock's initiate() fills the buffer, which clears it again.
  local oldload = trigger.model.load
  local atload = {}
  trigger.model.load = function(template, a, b, c, d, e)
    oldload(template, a, b, c, d, e)
    atload.fillmode, atload.capacity, atload.count =
      TRIG.buf.fillmode, TRIG.buf.capacity, TRIG.count
  end

  sdec.stream_arm(nreq)
  buf.clear, trigger.model.load = oldclear, oldload
  check('SimpleLoop is what got armed', TRIG.template == 'SimpleLoop', tostring(TRIG.template))
  check('fillmode is CONTINUOUS at trigger.model.load, not FILL_ONCE after the clear',
        atload.fillmode == 1, string.format('fillmode=%s', tostring(atload.fillmode)))
  -- THE HEADROOM IS PAST THE PRE-TRIGGER RESERVE AS WELL AS PAST THE COUNT, and the reserve is asked
  -- for whenever the operator's trigger mode is one that waits -- which is the default. It has to be
  -- in CAPACITY because that is where LoopUntilEvent takes it from: a buffer sized at the count
  -- records 5 % less than was asked for. This recording armed a SimpleLoop, because the line is
  -- transmitting, and then the reserve is 5 % of readings left unused rather than a shortfall.
  do
    local want = atload.count + 100
    if sdec.trigmode ~= 'free' then
      want = math.ceil(atload.count * 100 / (100 - sdec.pretrig)) + 100
    end
    check('and the buffer has 100 readings of headroom past the count and the reserve',
          atload.capacity == want,
          string.format('capacity=%s count=%s want=%s at trigmode %s', tostring(atload.capacity),
                        tostring(atload.count), tostring(want), tostring(sdec.trigmode)))
  end
  -- The headroom must be CAPACITY only. Moving it into `count` would make the recording overrun
  -- the sample bound the progress figure and the full-buffer exit are both stated against.
  check('the count itself is still exactly the sample bound the caller asked for',
        TRIG.count == nreq, string.format('%d vs %d', TRIG.count, nreq))
  -- localnode.showevents governs the REMOTE interface only, so muting cannot remove the panel's
  -- box -- and an arm that returns would have to unmute from the STOP press, which may never come.
  check('and the arm does not leave the panel muted between the two presses',
        MD.showevents() ~= 0, tostring(MD.showevents()))
  sdec.ck_running, sdec.strm_recording = false, nil
end

-- ============================================================================
print('\nB  a decode slice is not pinned to one window per press')
-- ============================================================================
-- ck_budget_frac was taken out of the budget twice -- once sizing the window, once counting windows
-- per slice -- and a decode window was costed at the worst PRIMING phase, three times its own
-- measured cost. Together those made every press worth exactly one window.
do
  check('the decode window has its own measured per-sample cost',
        sdec.ck_win_us ~= nil and sdec.ck_win_us < sdec.ck_smp_us,
        string.format('win=%s smp=%s', tostring(sdec.ck_win_us), tostring(sdec.ck_smp_us)))
  -- 3200 x 73 us = 0.234 s. Three fit in 0.5 s and two in 0.45 s, so this is exactly the width at
  -- which taking the margin twice loses a window.
  check('a slice gets the whole budget, not 0.9 of it twice',
        sdec.ck_slice_win(0.5, 3200) == 2, tostring(sdec.ck_slice_win(0.5, 3200)))
  check('and the cheaper decode cost buys a window the format cost cannot',
        sdec.ck_slice_win(0.5, 5000, sdec.ck_win_us) == 2 and
        sdec.ck_slice_win(0.5, 5000) == 1,
        string.format('%s vs %s', tostring(sdec.ck_slice_win(0.5, 5000, sdec.ck_win_us)),
                      tostring(sdec.ck_slice_win(0.5, 5000))))
  -- The two-argument callers are unchanged, which is what keeps the offline suite meaningful.
  check('an unlimited budget is still unlimited', sdec.ck_slice_win(nil, 20000) == nil)
  check('and a budget smaller than one window still buys one',
        sdec.ck_slice_win(0.000001, 20000) == 1)

  -- END TO END, on the press path: how many windows one ck_job_step actually spends.
  clearforce()
  sdec.force_baud = 9600
  sdec.acq_fs = 100000
  sdec.sig_levels(rd, nsmp)
  local oldw, oldl = sdec.ck_win_n, sdec.ck_level_max
  sdec.ck_win_n, sdec.ck_level_max = 3200, 3200
  local job, jerr = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp,
                                    '/usb1/streamfix.txt',
                                    {budget_s = 0.5, nocap = true})
  check('a sliced job starts', job ~= nil, tostring(jerr))
  local nwin1, guard = nil, 0
  if job ~= nil then
    while nwin1 == nil and guard < 64 do
      local done, tot = sdec.ck_job_step(job)
      guard = guard + 1
      if tot ~= nil and tot.nwin ~= nil and tot.nwin > 0 then nwin1 = tot.nwin end
      if done then break end
    end
    pcall(function() sdec.ck_job_abandon(job) end)
  end
  -- 3200 x 3 x 48 us = 0.461 s, inside the 0.5 s bound; a fourth would be 0.61 s.
  check('one press spends every window the latency budget pays for, not one',
        nwin1 == 3, tostring(nwin1))
  sdec.ck_win_n, sdec.ck_level_max = oldw, oldl
  sdec.ck_job, sdec.ck_running = nil, false
end

-- ============================================================================
print('\nC  a press-driven recording says what is true')
-- ============================================================================
-- Observed on the instrument: 'STREAM  recording... 0 % of the buffer' beside a log cell reading
-- 'runs to 20 s or quiet', while buf.n was 1960 and climbing. The percentage is written only by
-- progress_samples(), which only the polled one-shot path calls; neither bound in the log cell
-- exists on this path; and sdec.ui_status -- the one line that was right -- is not rendered here.
do
  clearforce()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.ck_tot, sdec.ck_nbytes, sdec.ck_job = nil, 0, nil
  sdec.ck_acq_have, sdec.ck_acq_want = nil, nil
  sdec.ck_running, sdec.strm_recording = true, true

  local st = sdec.ck_status()
  check('the status row names the control that actually works',
        has(st, 'press Capture to stop'), string.format('%q', st))
  check('and states no percentage, rather than a 0 % that can never advance',
        not has(st, '%'), string.format('%q', st))
  -- The row shares its line with the log cell at sdec.ui_stat_div + 6, so the mode name and this
  -- string together have ui_stat_div - 8. Derived, never a literal: a hard-coded width outlives the
  -- divider that set it.
  local row = string.format('%s  %s', sdec.mode_cur().name, st)
  check('and it fits the status cell', sdec.ui_textw(row) <= sdec.ui_stat_div - 8,
        string.format('%d px', sdec.ui_textw(row)))

  sdec.ui_refresh()
  local lg = MD.text(sdec.ui_log_t)
  -- BOTH CONTROLS BY NAME, not one exact phrase. Mode aborts the run without changing the mode, so
  -- a label like 'Mode=Exit' promises behaviour the button does not have. What has to hold is that
  -- the cell names the two buttons that stop this run and calls what they do a stop.
  check('the log cell offers the controls a press can reach, and calls them a stop',
        has(lg, 'Capture') and has(lg, 'Mode') and has(lg, 'Stop'),
        string.format('%q', tostring(lg)))
  check('and claims neither the 20 s ceiling nor the quiet-line exit, which this path has not',
        not has(lg, 'runs to') and not has(lg, 'quiet'), string.format('%q', tostring(lg)))
  -- AGAINST ui_log_px, NOT A LITERAL. The cell is 188 px and moves whenever the rear-BNC cell beside
  -- it changes width. A literal keeps passing while the string it measures runs into its neighbour.
  check('the cell still fits the log cell as it is TODAY',
        sdec.ui_textw(lg) <= sdec.ui_log_px,
        string.format('%d px of %d', sdec.ui_textw(lg), sdec.ui_log_px))

  -- THE POLLED PATH NAMES NOTHING, because nothing can act on it. The TRIGGER key does not deliver
  -- while a panel-initiated run executes: pressed 20 % into a 32 kB decode, the run ends 'full' with
  -- the blender latch empty. The plumbing itself works -- a blended firmware timer cancels -- so it is
  -- only the finger's part that fails. Naming a control that cannot act is worse than naming none, so
  -- the cell says it runs to its own end and the note line carries the duration.
  sdec.strm_recording = nil
  sdec.ui_refresh()
  check('a polled one-shot stream names no control, because none can act',
        not has(MD.text(sdec.ui_log_t), 'TRIGGER')
        and not has(MD.text(sdec.ui_log_t), 'Capture=')
        and has(MD.text(sdec.ui_log_t), 'no stop'),
        string.format('%q', tostring(MD.text(sdec.ui_log_t))))
  sdec.progress_samples(1960, 20000)
  check('and its percentage still works', has(sdec.ck_status(), '9 % of the buffer'),
        string.format('%q', sdec.ck_status()))

  -- A SLICED DECODE IS ALSO PRESS-DRIVEN, so it gets the control rather than the bound.
  sdec.ck_nbytes, sdec.ck_job = 0, {}
  sdec.ui_refresh()
  check('a sliced decode says a press steps it',
        has(MD.text(sdec.ui_log_t), 'Capture=step'),
        string.format('%q', tostring(MD.text(sdec.ui_log_t))))

  sdec.ck_running, sdec.strm_recording, sdec.ck_job = false, nil, nil
  sdec.ck_acq_have, sdec.ck_acq_want, sdec.ck_nbytes = nil, nil, nil
  sdec.capmode = 'frame'
end

-- ============================================================================
print('\nD  a recording with NO USB KEY still decodes to the panel')
-- ============================================================================
-- Reported from the bench: with no key in the slot the 8 kB and 32 kB modes loaded the buffer and
-- decoded NOTHING, while 240-byte FRAME mode went on showing bytes from the same wire. stream_decode()
-- refused the moment flog_alloc() returned nil, so the whole decode was gated on a file -- against
-- docs/MANUAL.md, which promises "the app works perfectly well without a key; you simply get no log
-- and no report". The file is now optional: a nil path skips the sink and the tail ring feeds the panel.
do
  clearforce()
  MD.usb(false)
  MD.forget_fevents()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
  ulog.on, ulog.dirok = false, nil
  sdec.force_baud = 9600
  sdec.acq_fs = 100000
  sdec.capmode = 'sml'
  sdec.ck_job, sdec.strm_recording = nil, nil
  sdec.res, sdec.ck_tot, sdec.ck_nbytes = nil, nil, nil
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil

  local cok, cwhy = sdec.capture()
  check('a recording with no key SUCCEEDS rather than refusing', cok == true, tostring(cwhy))
  check('and it leaves decoded bytes on the panel, which is the whole defect',
        sdec.res ~= nil and sdec.res.nf > 0, tostring(sdec.res and sdec.res.nf))
  check('the totals are real, not a stub', sdec.ck_tot ~= nil and sdec.ck_tot.nf > 0,
        tostring(sdec.ck_tot and sdec.ck_tot.nf))
  -- NO FILE WAS OPENED AND NO EVENT WAS POSTED. A run that tried the key anyway would pop 2224 at
  -- the operator, which is the other half of what 'works perfectly well without a key' means.
  check('no file was written', sdec.ck_tot.path == nil, tostring(sdec.ck_tot.path))
  check('and nothing was posted at the operator', MD.fevent_count() == 0,
        'events=' .. MD.fevent_count())

  -- THE PANEL MUST NOT CLAIM A FILE. These three strings all named one before the fix: 'USB' in the
  -- status row, 'all are in the USB file' on the note row, and 'to a file' in the ready row.
  local st = sdec.ck_status()
  check('the status row says the bytes were NOT recorded, rather than naming the key',
        has(st, 'NOT recorded') and not has(st, '-> USB'), string.format('%q', st))
  -- mode_exit() clears flog_why after every recording, so the cell cannot report the attempt. It
  -- must still not promise to log the NEXT one: 'on first capture' is a promise, and there is no key.
  check('the log cell names the key rather than promising the next capture',
        has(sdec.flog_status(), 'no USB key'), sdec.flog_status())

  -- 8 kB mode keeps its WHOLE recording: cap 8192 == sdec.ck_keep, so nothing is discarded and the
  -- note row must not say anything was. 32 kB mode is the case that loses its head.
  check('8 kB mode keeps everything it decoded -- cap equals the retained tail',
        sdec.ui_modes[2].cap == sdec.ck_keep,
        string.format('%s vs %s', tostring(sdec.ui_modes[2].cap), tostring(sdec.ck_keep)))

  -- And the ready row, BEFORE a press, must not promise a file either.
  sdec.ck_tot, sdec.res = nil, nil
  check('the ready row offers the panel, not a file, when there is no key',
        has(sdec.ck_status(), 'panel only') and not has(sdec.ck_status(), 'to a file'),
        string.format('%q', sdec.ck_status()))
  -- AND IT NAMES THE NUMBER THAT ACTUALLY ARRIVES. 8 kB mode keeps its whole recording, so one
  -- figure is right there; 32 kB decodes 32768 and keeps 8192, and a row reading '32768 bytes, panel
  -- only' promises four times what the panel will hold. Asserting only 'panel only' could not catch
  -- that, because 8 kB is the mode where that wording is correct.
  sdec.capmode = 'med'
  local medrow = sdec.ck_status()
  check('the 32 kB ready row names the cap AND what the panel keeps',
        has(medrow, tostring(sdec.ui_modes[3].cap)) and has(medrow, tostring(sdec.ck_keep))
        and not has(medrow, 'to a file'), string.format('%q', medrow))
  check('...and it still fits the row', sdec.ui_textw(medrow) <= 456,
        string.format('%d px: %q', sdec.ui_textw(medrow), medrow))
  sdec.capmode = 'sml'
  check('8 kB, where cap equals the tail, states one number rather than two',
        has(sdec.ck_status(), 'panel only'), string.format('%q', sdec.ck_status()))

  MD.usb(true)
  MD.forget_files()
  check('...and offers the file again once a key is back',
        has(sdec.ck_status(), 'to a file'), string.format('%q', sdec.ck_status()))

  sdec.ck_running, sdec.strm_recording, sdec.ck_job = false, nil, nil
  sdec.capmode = 'frame'
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
end

-- ============================================================================
print('\nE  the one-second tick notices a key with no press')
-- ============================================================================
-- The firmware posts NO event for a key arriving or leaving -- measured: usbdriveexists goes 0 -> 1
-- and eventlog.getcount() stays 0 -- and a Lua poll loop cannot fill the gap, because a handler is
-- dispatched only while the interpreter is idle, so a loop that never returns leaves every button
-- dead. display.OBJ_TIMER is the instrument's own answer (see its clockIV3 sample).
do
  sdec.capmode = 'frame'
  sdec.busy, sdec.ck_running, sdec.strm_recording = false, false, nil
  MD.usb(true)
  MD.forget_files()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil

  check('the tick object exists and is a timer', sdec.ui_tick_obj ~= nil
        and MD.live('timer') == 1, 'timers=' .. MD.live('timer'))
  -- TIMER_FOREVER is a repeat COUNT and is 0 on this firmware, not -1. 0.5 s is honoured as a
  -- FRACTION rather than rounded to a whole second -- measured at 8 ticks in 4 s.
  check('it repeats forever at 2 Hz',
        sdec.ui_tick_s == 0.5 and display.TIMER_FOREVER == 0,
        string.format('%s / %s', tostring(sdec.ui_tick_s), tostring(display.TIMER_FOREVER)))

  -- WITH A KEY: the buttons are up and the cell promises the next capture.
  sdec.ui_tick()
  check('with a key in the slot the tick leaves Save and NewLog showing',
        sdec.ui_savevis == true, tostring(sdec.ui_savevis))

  -- PULL IT, AND TICK -- no press anywhere in between.
  MD.usb(false)
  check('the tick notices the key has gone', sdec.ui_tick() == true
        and sdec.ui_savevis == false, tostring(sdec.ui_savevis))
  check('and repaints the log cell to name the key',
        has(MD.text(sdec.ui_log_t), 'no USB key'), tostring(MD.text(sdec.ui_log_t)))
  -- A FILENAME ALLOCATED BEFORE THE PULL MUST NOT OUTRANK IT. flog_path stays set and flog_why stays
  -- nil -- nothing has failed, because nothing has been attempted -- so the cell read
  -- 'log: bytes248  2721 B' with the key in a pocket. Seen on the instrument, with a path set; the
  -- check above passes with flog_path nil and could not catch it.
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes, sdec.flog_why = '/usb1/SERDEC/bytes248.txt', 3, 2721, nil
  check('a filename allocated before the pull does not outrank the missing key',
        has(sdec.flog_status(), 'no USB key') and not has(sdec.flog_status(), 'bytes248'),
        sdec.flog_status())
  sdec.flog_path, sdec.flog_n, sdec.flog_bytes, sdec.flog_why = nil, nil, nil, nil

  -- PUT IT BACK, AND TICK.
  MD.usb(true)
  MD.forget_files()
  check('the tick notices it come back', sdec.ui_tick() == true and sdec.ui_savevis == true,
        tostring(sdec.ui_savevis))

  -- A TICK DISPATCHED INTO A RUNNING CAPTURE MUST DO NOTHING. Ticks queue behind a capture exactly
  -- as presses do, so they arrive in a burst afterwards -- and a repaint from inside one would
  -- fight the capture for the same objects.
  MD.usb(false)
  sdec.busy = true
  check('a tick during a capture is a no-op, not a repaint',
        sdec.ui_tick() == false and sdec.ui_savevis == true, tostring(sdec.ui_savevis))
  sdec.busy = false
  sdec.ck_running = true
  check('and so is one during a decode', sdec.ui_tick() == false and sdec.ui_savevis == true)
  sdec.ck_running = false
  check('once the run is over the next tick catches up',
        sdec.ui_tick() == true and sdec.ui_savevis == false)

  -- IDEMPOTENT, because that burst may be thirty ticks long.
  local before = sdec.ui_savevis
  local i
  for i = 1, 30 do sdec.ui_tick() end
  check('thirty queued ticks settle to the same answer as one', sdec.ui_savevis == before,
        tostring(sdec.ui_savevis))

  -- The handler the mock recorded for the tick object, or nil.
  local function TICKEV()
    local e = MD.events(sdec.ui_tick_obj)
    if e == nil then return nil end
    return e[display.EVENT_PRESS]
  end
  -- THE OFF SWITCH IS THE HANDLER STRING, not STATE_INVISIBLE -- measured: an invisible timer still
  -- fires 4 times in 4 s, a cleared handler fires 0. So the test is what the handler is SET TO.
  check('turning the tick off clears its handler', sdec.ui_tick_off() == true
        and TICKEV() == '',
        string.format('%q', tostring(TICKEV())))
  check('and turning it on puts the handler back', sdec.ui_tick_on() == true
        and TICKEV() == 'sdec.guard(sdec.ui_tick)',
        string.format('%q', tostring(TICKEV())))
  -- A press turns it off for the whole capture and back on afterwards, however the capture ended.
  MD.usb(true)
  MD.forget_files()
  sdec.capture()
  check('a capture leaves the tick ON when it returns',
        TICKEV() == 'sdec.guard(sdec.ui_tick)',
        string.format('%q', tostring(TICKEV())))
  -- INCLUDING A CAPTURE THAT RAISED, which is why the boundary, not capture(), is what catches it: a raise that skipped
  -- the re-enable leaves the panel blind to the key for the rest of the session.
  --
  -- sdec.mode_cur, NOT sdec.autoset. capture_run's OWN pcall absorbs an autoset raise, so it
  -- returns false normally and the wrapper's pcall is never entered -- the test passed with the
  -- wrapper's pcall deleted outright, which makes it a test of nothing. mode_cur is called unguarded
  -- near the top of capture_run, so stubbing it is a genuine escape, and the signature is the
  -- difference between `false, nil` and a reason.
  local raised, rwhy, gverdict = nil, nil, nil
  do
    -- DISARMED FIRST, or the stub is never reached. The capture above ended a run and armed the
    -- queued-press absorb; capture() tests that at its top and returns without acting, so the press
    -- below would report NO raise and this would be a test of nothing. The mock's clock does not
    -- advance on its own, so the window never expires here -- bench_sync disarms for the same reason.
    sdec.strm_stopped_by_press, sdec.strm_absorbed = nil, nil
    local saved = sdec.mode_cur
    sdec.mode_cur = function() error('escaping', 0) end
    raised, rwhy = pcall(function() return sdec.capture() end)
    -- AND AGAIN THROUGH THE BOUNDARY, which is how the firmware calls it. capture() guards nothing
    -- of its own, so the cleanup a raise skips -- the tick, the busy latch, the stale result -- is
    -- sdec.guard's, and both contracts are checked off the one stub.
    gverdict = sdec.guard(sdec.capture)
    sdec.mode_cur = saved
  end
  check('a raise out of the body still reaches the caller, rather than being swallowed',
        raised == false and has(tostring(rwhy), 'escaping'),
        string.format('%s / %s', tostring(raised), tostring(rwhy)))
  check('...and the boundary turns that raise into a refusal rather than a popup',
        gverdict == false, tostring(gverdict))
  check('and the tick is back ON after it', TICKEV() == 'sdec.guard(sdec.ui_tick)',
        string.format('%q', tostring(TICKEV())))
  -- AND sdec.busy IS NOT LEFT SET. ui_tick treats busy as "a run owns the panel", so one faulting
  -- press would stop the panel noticing the key for the rest of the session.
  check('...and sdec.busy is cleared, so the tick is not silently dead',
        not sdec.busy, tostring(sdec.busy))
  MD.usb(false)
  check('proved by a tick that still acts', sdec.ui_tick() == true and sdec.ui_savevis == false,
        tostring(sdec.ui_savevis))
  MD.usb(true)
  MD.forget_files()
  sdec.ui_tick()
  -- Teardown deletes the object and nils the handle, so nothing can fire into a dead screen.
  check('teardown deletes the tick and nils the handle', (function()
          sdec.stop()
          return sdec.ui_tick_obj == nil and MD.live('timer') == 0
        end)(), 'timers=' .. MD.live('timer'))
  sdec.start()
  check('a restart builds exactly one again', sdec.ui_tick_obj ~= nil and MD.live('timer') == 1,
        'timers=' .. MD.live('timer'))

  -- And it survives having no screen, which is what a tick arriving during teardown looks like.
  local scr = sdec.ui_scr
  sdec.ui_scr = nil
  check('a tick with no screen is refused rather than raising', sdec.ui_tick() == false)
  sdec.ui_scr = scr

  MD.usb(true)
  MD.forget_files()
  sdec.ui_tick()
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
end

-- ============================================================================
print('\nF  a key pulled DURING a recording stops the rows, not just the verdict')
-- ============================================================================
-- ck_sink_file writes ONE ROW AT A TIME, and a pulled key does not fail a write in Lua -- it posts
-- 2200 and returns. So a 32 kB recording wrote 2048 rows into nothing and put 2048 modal boxes on
-- the panel, in the one mode whose status row says 'no stop once started'. A check in finish() alone
-- catches the verdict and none of the boxes, which is what this exists to prove.
do
  MD.usb(true)
  MD.forget_files()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
  check('ensuredir on a good key, so the open below is not what fails',
        ulog.ensuredir() == true)
  local sink, finish, serr = sdec.ck_sink_file('/usb1/SERDEC/rows.txt', 16)
  check('ck_sink_file opens on a good key', sink ~= nil, tostring(serr))
  if sink ~= nil then
    local v, e, i2 = {}, {}, nil
    for i2 = 1, 16 do v[i2], e[i2] = 65 + math.mod(i2, 26), nil end
    check('a row written with the key present succeeds', sink(v, e, 16, 0) ~= false)
    MD.usb(false)
    MD.forget_fevents()
    -- Eight more windows of 16 bytes. Before the gate in emit() these wrote eight rows into nothing,
    -- posted eight events, and every sink call returned true.
    local j, ok8 = nil, true
    for j = 1, 8 do
      if sink(v, e, 16, j * 16) == false then ok8 = false end
    end
    check('the sink REFUSES once the key has gone, rather than writing into nothing', ok8 == false)
    check('and eight rows post at most ONE event, not eight',
          MD.fevent_count(2200) <= 1, '2200 x ' .. MD.fevent_count(2200))
    check('finish() reports the run as incomplete', finish() == false)
  end
  MD.usb(true)
  MD.forget_files()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
end

-- ============================================================================
print('\nG  Capture, View and Mode check the key BEFORE they do their work')
-- ============================================================================
-- The three presses now call sdec.ui_keypoll() as their first act, so a key inserted or pulled in
-- the half-second before a press is honoured by THAT press.
--
-- EACH CHECK IS ON THE ORDER, NOT ON THE OUTCOME, and that is the only way these can fail. All
-- three handlers end in sdec.ui_refresh(), which moves the buttons anyway, and capture_run() opens
-- with ulog.resume() -- so asserting that anything is right AFTERWARDS passes without the change as
-- well. These pin the ORDER: each stubs the first function the handler's own body calls and records
-- the state at that instant.
--
-- SO THESE DO NOT GUARD A VISIBLE DEFECT, and should not be read as doing so -- a Capture press
-- reached its work with the log open and the buttons back before any of this. What they guard is
-- that the property is OWNED by the three handlers rather than inherited from where resume() sits
-- in a function they cannot see.
do
  local function settle_nokey()
    MD.usb(true)
    MD.forget_files()
    ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
    ulog.keygen, ulog.keyopen = 0, 0
    ulog.on, ulog.dirok, ulog.fh = false, nil, nil
    ulog.path = '/usb1/SERDEC/press.txt'
    ulog.enabled = true
    ulog.open(ulog.path, true)
    sdec.ui_savevis = nil
    sdec.ui_tick()                 -- the panel settles into the key-present state
    MD.usb(false)
    ulog.line('into the void')     -- latches keybad, closes the handle
    sdec.ui_tick()                 -- and the panel settles into the no-key state
    MD.usb(true)                   -- the key is back, and NOTHING has noticed yet
    MD.forget_files()
    MD.forget_fevents()
  end

  local function invisible(h)
    return h ~= nil and MD.obj(h) ~= nil and MD.obj(h).state == display.STATE_INVISIBLE
  end

  settle_nokey()
  check('the no-key state really does hide Save, so these tests start where they claim',
        invisible(sdec.ui_savebtn) and sdec.ui_savevis == false,
        tostring(sdec.ui_savevis))
  check('and the log really is closed', ulog.on == false)

  -- CAPTURE. capture_run() is the body, and it is stubbed rather than run: a real capture here
  -- would measure the mocked digitizer, not the order of two calls.
  local realrun = sdec.capture_run
  local at_on, at_vis
  sdec.capture_run = function()
    at_on, at_vis = ulog.on, sdec.ui_savevis
    return true, nil
  end
  pcall(function() sdec.capture() end)
  sdec.capture_run = realrun
  check('Save is back on the glass before the run starts, not after it', at_vis == true,
        tostring(at_vis))
  -- THE POLL MUST NOT RE-OPEN THE LOG, and that is a decision rather than an oversight: resume()
  -- allows one open attempt per insertion, so spending it from a 2 Hz tick within half a second of
  -- insertion risks 'NOT LOGGING' standing all session. capture_run() resumes -- stubbed out here,
  -- which is exactly why this reads false.
  check('and the poll itself did NOT re-open the log file', at_on == false, tostring(at_on))

  -- VIEW. ui_nviews() is the first call in view_toggle()'s body.
  settle_nokey()
  local realn = sdec.ui_nviews
  at_on, at_vis = nil, nil
  sdec.ui_nviews = function()
    at_on, at_vis = ulog.on, sdec.ui_savevis
    return realn()
  end
  pcall(function() sdec.view_toggle() end)
  sdec.ui_nviews = realn
  check('View has the buttons back before it changes the view, not only in the refresh after it',
        at_vis == true, tostring(at_vis))
  -- View writes nothing to the key, so nothing in it resumes -- and the next logged line will.
  check('and the very next logged line re-opens the log by itself',
        ulog.line('after a View press') == true and ulog.on == true, tostring(ulog.lasterr))

  -- MODE. mode_next() is reached before the ulog.line() further down, and that line resumes the log
  -- by itself -- so recording the state here is what pins the order rather than the outcome.
  settle_nokey()
  local realnext = sdec.mode_next
  at_on, at_vis = nil, nil
  sdec.mode_next = function()
    at_on, at_vis = ulog.on, sdec.ui_savevis
    return realnext()
  end
  pcall(function() sdec.mode_cycle() end)
  sdec.mode_next = realnext
  check('Mode has the buttons back before it picks the next mode', at_vis == true, tostring(at_vis))
  -- mode_cycle() logs the new mode, and that line is what re-opens the log on this path.
  check('and its own log line left the log open', ulog.on == true, tostring(ulog.lasterr))

  -- NO EVENT FOR ANY OF IT. A press that re-opens the log must not pop a box at the operator.
  check('none of the three presses posted anything at the operator',
        MD.fevent_count() == 0, 'events=' .. MD.fevent_count())

  -- A PRESS WITH NO KEY MUST STILL BE SILENT, which is the case the whole latch exists for.
  MD.usb(false)
  MD.forget_fevents()
  pcall(function() sdec.view_toggle() end)
  pcall(function() sdec.mode_cycle() end)
  check('and with the key OUT, two more presses post nothing either',
        MD.fevent_count() == 0, 'events=' .. MD.fevent_count())
  check('with Save hidden', invisible(sdec.ui_savebtn), tostring(sdec.ui_savevis))

  -- ui_keypoll() IS CALLED THROUGH pcall FROM A TOUCH HANDLER, so it must not raise on a torn-down
  -- panel either -- that is the state a queued press arrives in during teardown.
  --
  -- THE KEY GOES BACK IN AND ui_savevis IS FORCED STALE FIRST, or this assertion cannot fail.
  -- Reached with the key out and Save already hidden, ui_usb_btns() reports no change and keypoll
  -- answers false whether the ui_scr guard exists or not -- proved by deleting the guard and
  -- watching it still pass. Set up like this, deleting the guard returns true and it fails.
  MD.usb(true)
  sdec.ui_savevis = false
  local scr = sdec.ui_scr
  sdec.ui_scr = nil
  check('ui_keypoll() on a torn-down panel answers false rather than raising',
        sdec.ui_keypoll() == false)
  sdec.ui_scr = scr

  -- PUT THE LOG AND THE MODE BACK, or everything after this runs with a dead logger and in a
  -- recording mode. settle_nokey() leaves ulog.path at its own file with ulog.on false and
  -- keyopen == keygen, so every later ulog.line() would resume() to false and be dropped in
  -- silence -- which no assertion here would notice and a later one would be baffled by.
  MD.usb(true)
  MD.forget_files()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
  ulog.path = '/usb1/SERDEC/dmm6500_log.txt'
  ulog.keygen, ulog.keyopen = 0, 0
  ulog.on, ulog.dirok, ulog.fh = false, nil, nil
  ulog.open(ulog.path, true)
  check('the log is left open for whatever runs next', ulog.on == true, tostring(ulog.lasterr))
  sdec.capmode = 'frame'          -- two Mode presses above moved it
end

-- ============================================================================
print('\nH  ui_log_owned() agrees with ui_refresh about who owns the log cell')
-- ============================================================================
-- The status row's right-hand cell is the LOG's when nothing is running and a RUN's while one is --
-- it carries the only statement of how to stop an uninterruptable recording. ui_refresh() decides
-- that with a four-way branch; ui_keypoll() has to know the same answer, because it writes the same
-- object from a press. Two opinions about one object is a defect this app has paid for before.
--
-- THE ASSERTION IS THE AGREEMENT, state by state, rather than either function's own output: it
-- fails if ui_refresh grows a case that ui_log_owned() does not know about.
do
  MD.usb(true)
  local function clearrun()
    sdec.strm_recording, sdec.ck_job, sdec.ck_running = nil, nil, false
    sdec.strm_inflight, sdec.ck_tot, sdec.ck_nbytes = nil, nil, nil
  end
  local states = {
    {n = 'idle, FRAME',          f = function() sdec.capmode = 'frame' end},
    -- 8 kB and 32 kB are view = false, so ui_refresh's OUTER test is true for them with
    -- nothing running -- which is the case that must still come out as the log's, not a run's.
    {n = 'idle, 8 kB',           f = function() sdec.capmode = 'med' end},
    {n = 'press-driven record',  f = function() sdec.capmode = 'med'
                                                sdec.strm_recording = true end},
    {n = 'a chunked job open',   f = function() sdec.capmode = 'med'
                                                sdec.ck_job = {} end},
    {n = 'ck_running',           f = function() sdec.capmode = 'med'
                                                sdec.ck_running = true end},
    {n = 'strm_inflight',        f = function() sdec.capmode = 'med'
                                                sdec.strm_inflight = true end},
    -- FRAME IS view = true, so ui_refresh's outer test is only SATISFIED through ck_tot or
    -- ck_running. These two reach the hint block with FRAME selected.
    {n = 'FRAME + ck_running',   f = function() sdec.capmode = 'frame'
                                                sdec.ck_running = true end},
    {n = 'FRAME + a summary',    f = function() sdec.capmode = 'frame'
                                                sdec.ck_tot = {nf = 0, nwin = 1, nbad = 0,
                                                               stopped = 'done'} end},
    -- THESE THREE ARE THE ONLY STATES THAT TEST THE OUTER CONDITION AT ALL, and without them this
    -- section was vacuous about it: deleting ui_log_owned's `md.view and ck_tot == nil and not
    -- ck_running` early return left all of the above passing. The two FRAME states above MAKE the
    -- outer condition true, so they never reach that line. Here a run flag is set while FRAME is
    -- selected and ck_tot is nil -- the shape a stale ck_running or strm_inflight latch leaves
    -- behind after a fault -- so the outer condition is FALSE, ui_refresh writes the log status,
    -- and anything claiming the cell is a run's would be wrong.
    {n = 'FRAME + strm_recording', f = function() sdec.capmode = 'frame'
                                                  sdec.strm_recording = true end},
    {n = 'FRAME + a chunked job',  f = function() sdec.capmode = 'frame'
                                                  sdec.ck_job = {} end},
    {n = 'FRAME + strm_inflight',  f = function() sdec.capmode = 'frame'
                                                  sdec.strm_inflight = true end},
  }
  local k
  for k = 1, table.getn(states) do
    clearrun()
    states[k].f()
    sdec.ui_refresh()
    local shown = MD.text(sdec.ui_log_t)
    local islog = (shown == sdec.flog_status())
    check('  ' .. states[k].n .. ': ui_log_owned() matches what ui_refresh wrote',
          sdec.ui_log_owned() == (not islog),
          string.format('owned=%s cell=%q', tostring(sdec.ui_log_owned()), tostring(shown)))
  end

  -- AND THE BEHAVIOUR THAT MATTERS: a key pulled during a press-driven recording must not cost the
  -- stop instruction. This is the press that stops the run, so keypoll runs in that state.
  clearrun()
  sdec.capmode = 'med'
  sdec.strm_recording = true
  sdec.ui_refresh()
  local hint = MD.text(sdec.ui_log_t)
  check('a live recording shows how to stop', has(tostring(hint), 'Stop'), tostring(hint))
  sdec.ui_savevis = nil                 -- so ui_usb_btns() reports a change
  MD.usb(false)
  sdec.ui_keypoll()
  check('and a key pulled mid-recording leaves that instruction alone',
        MD.text(sdec.ui_log_t) == hint, tostring(MD.text(sdec.ui_log_t)))
  check('while still hiding Save, which cannot work without a key',
        MD.obj(sdec.ui_savebtn).state == display.STATE_INVISIBLE,
        tostring(sdec.ui_savevis))

  -- LEAVE THE LOGGER ALIVE, for the same reason G does: the key-out keypoll above leaves ulog.on
  -- false with keyopen == keygen, so clearing the latch alone would let every later ulog.line()
  -- resume to false and be dropped in silence. Nothing follows H today; the next section added
  -- would inherit a dead log and no assertion here would notice.
  clearrun()
  sdec.capmode = 'frame'
  MD.usb(true)
  MD.forget_files()
  ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
  ulog.keygen, ulog.keyopen = 0, 0
  ulog.on, ulog.dirok, ulog.fh = false, nil, nil
  ulog.path = '/usb1/SERDEC/dmm6500_log.txt'
  ulog.open(ulog.path, true)
  check('H leaves the logger open too', ulog.on == true, tostring(ulog.lasterr))
end

-- ============================================================================
print('\nI  an 8 kB or 32 kB recording can wait for a device that has not started')
-- ============================================================================
-- SimpleLoop ACQUIRES THE INSTANT IT IS INITIATED, so a recording built on it records the silence
-- when Capture is pressed before the DUT powers up -- the case the frame path arms for, at 8 kB and
-- 32 kB. LoopUntilEvent is the canned four-block shape that waits, and its infinite pre-roll is what
-- makes the analog comparator evaluate at all: a wait followed by a counted digitize builds cleanly,
-- passes every static check, and never fires.
;(function()
  local keep = {tm = sdec.trigmode, cm = sdec.capmode, pi = sdec.probe_idle,
                fc = sdec.fc_out, lvl = sdec.armlevel, wait = sdec.armwait,
                key = sdec.armkey, ext = sdec.trigext}
  sdec.trigext, sdec.trigext_only, sdec.fc_out = false, false, false
  sdec.armlevel, sdec.armwait, sdec.armkey = 1.0, 4.0, true

  -- A LINE AT GROUND WITH NOTHING ON IT: the swing is under sdec.minswing, so the level probe in
  -- stream_begin() refuses it and arm_silent() is true -- the real precondition, not a flag set by
  -- hand.
  local function quiet_line()
    SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
      GEN({bytes = {0x55}, baud = 9600, fs = 100000, hi = 0.02, lo = 0.0})
    SRC.trigat = nil
  end
  local function busy_line()
    SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
      GEN({bytes = {72, 101, 108, 108, 111}, baud = 9600, fs = 100000, lead = 20, n = 12000})
    SRC.trigat = nil
  end
  local function begin(mode, tm, line)
    clearforce()
    sdec.force_baud, sdec.capmode, sdec.trigmode = 9600, mode, tm
    sdec.strm_recording, sdec.ck_job, sdec.ck_running = nil, nil, false
    sdec.strm_armed = nil
    line()
    TRIG.template, TRIG.ev, TRIG.position, TRIG.clear = nil, nil, nil, nil
    local ok, why = sdec.stream_begin()
    return ok, why
  end

  -- THE MODEL DOES NOT REACH ITS WAIT BLOCK INSTANTLY, and the mock says so because the instrument
  -- does: measured, STATE_RUNNING with nine readings at initiate and STATE_WAITING a moment later.
  -- stream_arm() spins for that transition, so a mock that reported WAITING from initiate would
  -- leave the spin untested -- and it was the absence of the spin that ended an armed 8 kB recording
  -- as 'quiet' with nothing in it.
  -- ONE READ OF STATE_RUNNING AFTER EVERY initiate(), because that is what the instrument gives:
  -- measured, STATE_RUNNING with nine readings taken immediately after initiate -- the model is
  -- executing the buffer clear, the zero delay and the start of the infinite digitize -- and
  -- STATE_WAITING only once it reaches the wait. stream_arm() spins for that transition, and a mock
  -- that reported the final state from the first read would leave the spin untested.
  ARMSTATES = 0
  local realstate0 = trigger.model.state
  trigger.model.state = function()
    ARMSTATES = ARMSTATES + 1
    -- RUNNING, THEN WAITING, THEN WHATEVER THE FIXTURE SAYS -- which is the instrument's own sequence
    -- for an armed model (measured: RUNNING with nine readings at initiate, WAITING about a
    -- millisecond later, and then whatever the line does). The mock fills the armed buffer
    -- synchronously inside initiate(), so without these two reads the model would appear to have
    -- finished before stream_arm()'s settle spin ever looked, and the spin -- which refuses to call
    -- an arm live until it has seen WAITING -- would refuse every offline arm.
    if ARMSTATES == 1 then return trigger.STATE_RUNNING, 'ok', 0 end
    if ARMSTATES == 2 then return trigger.STATE_WAITING, 'ok', 0 end
    return realstate0()
  end
  local realinit0 = trigger.model.initiate
  trigger.model.initiate = function()
    ARMSTATES = 0
    return realinit0()
  end

  local bok, bwhy = begin('med', 'edge', quiet_line)
  check('an 8 kB recording sets up on a silent line', bok == true, tostring(bwhy))
  check('...and the probe reports the line as silent, which is what decides the arm',
        sdec.arm_silent() == true, tostring(sdec.probe_idle))
  sdec.stream_arm(sdec.strm_nsmp)
  check('so the recording arms the WAITING template, not the one that fires immediately',
        TRIG.template == 'LoopUntilEvent' and sdec.strm_armed == true,
        string.format('template=%s armed=%s', tostring(TRIG.template), tostring(sdec.strm_armed)))
  check('...on the comparator, at the level the silent branch chose, with a pre-trigger reserve',
        TRIG.ev == trigger.EVENT_BLENDER1 and TRIG.position == sdec.pretrig and
        dmm.digitize.analogtrigger.mode == dmm.MODE_EDGE,
        string.format('ev=%s position=%s cmp=%s level=%s', tostring(TRIG.ev),
                      tostring(TRIG.position), tostring(dmm.digitize.analogtrigger.mode),
                      tostring(dmm.digitize.analogtrigger.edge.level)))
  check('...and the TRIGGER key is blended in here too, so the wait is always escapable',
        sdec.armkeyed == true and trigger.blender[1].stimulus[3] == trigger.EVENT_DISPLAY,
        string.format('keyed=%s s3=%s', tostring(sdec.armkeyed),
                      tostring(trigger.blender[1].stimulus[3])))
  -- THE RESERVE HAS TO BE IN CAPACITY OR THE RECORDING IS 5 % SHORT, because that is where
  -- LoopUntilEvent takes it from -- see sdec.n_deliv for the measurement.
  check('...with the reserve taken out of CAPACITY, so the recording is still the length asked for',
        math.floor((sdec.buf.capacity or 0) * (100 - sdec.pretrig) / 100) >= sdec.strm_nsmp,
        string.format('post %d of capacity %s for nsmp %d',
                      math.floor((sdec.buf.capacity or 0) * (100 - sdec.pretrig) / 100),
                      tostring(sdec.buf.capacity), sdec.strm_nsmp))

  -- THE ARM LEVEL IS NOT THE REUSED DECODE THRESHOLD, and the two have to coexist. A recording
  -- reuses the last good capture's measured threshold for its idle watchdog -- the right economy --
  -- and the guard that did so skipped arm_threshold() entirely, so the comparator was armed at that
  -- midpoint. MEASURED on the instrument: 1.63 V on a 0-3.29 V line, which is mid-data, where the arm
  -- fires on a data edge rather than on a start bit.
  do
    begin('med', 'edge', quiet_line)
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = 1.63, 0.3, 3.3
    sdec.strm_lvlreuse = nil
    begin('med', 'edge', quiet_line)
    check('a recording reuses the measured threshold for its watchdog',
          sdec.strm_lvlreuse == true and math.abs((sdec.thr or 0) - 1.63) < 0.01,
          string.format('reuse=%s thr=%s', tostring(sdec.strm_lvlreuse), tostring(sdec.thr)))
    -- idle sits at ~0 on this stimulus, so the arm level is 0 + Arm At. Nowhere near 1.63.
    check('...and still arms the comparator at idle plus Arm At, not at that midpoint',
          sdec.arm_thr ~= nil and math.abs(sdec.arm_thr - sdec.arm_level_v()) < 0.1,
          string.format('arm_thr=%s Arm At=%s thr=%s', tostring(sdec.arm_thr),
                        tostring(sdec.arm_level_v()), tostring(sdec.thr)))
    sdec.stream_arm(sdec.strm_nsmp)
    check('...and that is the level that reaches the hardware',
          math.abs((dmm.digitize.analogtrigger.edge.level or 0) - sdec.arm_thr) < 0.01,
          string.format('comparator=%s arm_thr=%s',
                        tostring(dmm.digitize.analogtrigger.edge.level), tostring(sdec.arm_thr)))
    -- AND WITH NO LEVEL AT ALL IT MUST NOT ARM. sig_levels' empty-capture exit leaves vmax nil and
    -- thr at zero, which satisfied the silent test and armed the comparator at 0 V.
    sdec.arm_thr = nil
    sdec.stream_arm(sdec.strm_nsmp)
    check('a silent line with no measurable idle level does not arm at 0 V',
          TRIG.template == 'SimpleLoop' and not sdec.strm_armed,
          string.format('template=%s armed=%s', tostring(TRIG.template), tostring(sdec.strm_armed)))
    sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = nil, nil, nil
  end

  -- AND WAITING CAN ARRIVE LATE, WHICH THE BUDGET HAS TO COVER. The spin advances in 10 ms steps, so
  -- the budget is really a poll count: 0.25 s was twenty-five looks. MEASURED on the instrument -- a
  -- 21 100-reading frame buffer reaches STATE_WAITING in about a millisecond, and the buffer behind an
  -- 8 kB recording does not, because the template's first block is BUFFER_CLEAR and the setup ahead of
  -- the wait scales with the buffer. The frame path's margin does not carry over.
  --
  -- THE CONSEQUENCE WAS A COIN TOSS, which is why this is worth a fixture rather than a constant. The
  -- same hardware case armed and collected 5 485 bytes on one run and ended as 'quiet' with nothing in
  -- it on the next three, because `not saw` is carried out as an arm that never went live -- correctly,
  -- since the poll loop cannot tell that from a trigger that fired. A budget that the instrument can
  -- miss therefore does not degrade, it inverts.
  do
    -- THE LEVELS AND THE ARM FLAG GO BACK, for the reason the block below gives: this one runs two
    -- probes of a ground-idle line, and a later fixture reads sdec.idle to decide which side of the
    -- threshold idle sits on -- left at 0 it looks for a leading LOW run in an idle-high record and
    -- finds none.
    local kthr, kidle, kat, kai = sdec.thr, sdec.idle, sdec.arm_thr, sdec.arm_idle
    local karmed = sdec.strm_armed
    local keepstate = trigger.model.state
    -- SIXTY LOOKS, which is 0.6 s of spin -- past the 25 that 0.25 s bought and inside the budget the
    -- measurement set. A fixture that passed at any budget would be asserting nothing.
    local LATE, looks = 60, 0
    trigger.model.state = function()
      looks = looks + 1
      if looks < LATE then return trigger.STATE_RUNNING, 'ok', 0 end
      return trigger.STATE_WAITING, 'ok', 0
    end
    begin('med', 'edge', quiet_line)
    looks = 0
    sdec.stream_arm(sdec.strm_nsmp)
    check('an arm whose model takes 0.6 s to reach its wait block is still an arm',
          sdec.strm_armed == true and TRIG.template == 'LoopUntilEvent',
          string.format('armed=%s template=%s after %d looks, budget %s s',
                        tostring(sdec.strm_armed), tostring(TRIG.template), looks,
                        tostring(sdec.arm_settle_s)))
    -- AND THE BUDGET IS STILL A BOUND, not patience without end. A model that never reaches its wait
    -- has to be reported as an arm that did not go live -- the whole point of carrying the verdict out
    -- -- so the generous budget must not have turned the refusal into a hang.
    trigger.model.state = function() return trigger.STATE_RUNNING, 'ok', 0 end
    begin('med', 'edge', quiet_line)
    sdec.stream_arm(sdec.strm_nsmp)
    check('...and a model that never reaches its wait is still reported as not armed',
          sdec.strm_armed == false, string.format('armed=%s', tostring(sdec.strm_armed)))
    trigger.model.state = keepstate
    sdec.thr, sdec.idle, sdec.arm_thr, sdec.arm_idle = kthr, kidle, kat, kai
    sdec.strm_armed = karmed
  end

  -- THE NOTE MUST NOT PROMISE AN ESCAPE THAT IS NOT WIRED IN. sdec.armkeyed was write-only -- three
  -- writers in arm_source(), no reader in tsp/ -- while the note said `TRIGGER=go` unconditionally.
  -- So with Arm key off, on a firmware whose blender refuses, or on an anchored rear-BNC capture, the
  -- panel promised the operator's only escape for up to two minutes while the key was not blended in.
  do
    -- THE LEVELS GO BACK, because this block runs two probes of a ground-idle line and the fixture
    -- below reads sdec.idle to decide which side of the threshold "idle" is on -- left at 0 it looked
    -- for a leading LOW run in an idle-high record and found none.
    local kthr, kidle, kat, kai = sdec.thr, sdec.idle, sdec.arm_thr, sdec.arm_idle
    local realnote = sdec.armnote
    local got = {}
    sdec.armnote = function(w, l, k) got = {w = w, l = l, k = k} end
    begin('med', 'edge', quiet_line)
    sdec.armkey = true
    sdec.stream_arm(sdec.strm_nsmp)
    sdec.stream_acquire(sdec.strm_nsmp)
    check('with the key blended in, the wait note is told so',
          got.k == true, string.format('keyed=%s', tostring(got.k)))
    begin('med', 'edge', quiet_line)
    sdec.armkey = false
    sdec.stream_arm(sdec.strm_nsmp)
    sdec.stream_acquire(sdec.strm_nsmp)
    check('...and with Arm key off it is not, so the panel cannot promise the escape',
          not got.k, string.format('keyed=%s', tostring(got.k)))
    sdec.armkey = true
    sdec.armnote = realnote
    sdec.thr, sdec.idle, sdec.arm_thr, sdec.arm_idle = kthr, kidle, kat, kai
  end

  -- AND NOT ON A LINE THAT IS ALREADY TALKING, which is the containment argument: SimpleLoop is
  -- strictly better there -- no wait to bound, and a trigger that would fire within a byte time.
  begin('med', 'edge', busy_line)
  sdec.stream_arm(sdec.strm_nsmp)
  check('a recording of a line that is already transmitting still arms SimpleLoop',
        TRIG.template == 'SimpleLoop' and not sdec.strm_armed,
        string.format('template=%s armed=%s', tostring(TRIG.template), tostring(sdec.strm_armed)))
  -- NOR IN FREE RUN, where the operator has said DO NOT WAIT.
  begin('med', 'free', quiet_line)
  sdec.stream_arm(sdec.strm_nsmp)
  check('nor does free run, where the operator asked not to wait',
        TRIG.template == 'SimpleLoop' and not sdec.strm_armed,
        string.format('template=%s armed=%s', tostring(TRIG.template), tostring(sdec.strm_armed)))

  -- ---- THE WAIT, BOUNDED, AND AN ARM THAT EXPIRES ----
  --
  -- The mock fills the armed buffer inside initiate(), so a live arm has to be modelled: wrap
  -- stream_arm and leave the buffer holding only its pre-trigger reserve, which is exactly what the
  -- instrument shows while the model sits in its wait block. delay() is a no-op offline, so the poll
  -- loop runs the whole bound in milliseconds.
  do
    begin('med', 'edge', quiet_line)
    local realarm = sdec.stream_arm
    sdec.stream_arm = function(nn)
      local ok = realarm(nn)
      -- WHAT A LIVE ARM LOOKS LIKE, in the two things the poll loop can see. The mock fills the
      -- armed buffer inside initiate(), so both have to be put back by hand: the model sits in its
      -- WAIT block, and the buffer holds the readings its pre-trigger phase has accumulated.
      --
      -- THE STATE IS THE LOAD-BEARING HALF. Measured on the instrument, buf.n settles a few readings
      -- ABOVE the reserve while waiting, so a buffer-level test reads a live arm as a fired one --
      -- which is why this fixture pins the state and the count a little above the reserve rather
      -- than at it.
      local b = sdec.buf
      b.n = math.floor((b.capacity or nn) * (sdec.pretrig or 0) / 100) + 2
      TRIG.state = trigger.STATE_WAITING
      return ok
    end
    local got = sdec.stream_acquire(sdec.strm_nsmp)
    sdec.stream_arm = realarm
    TRIG.state = trigger.STATE_IDLE
    check('an arm that never fires ends the recording as an EXPIRED ARM, not as a full buffer',
          sdec.ck_endwhy == 'noarm',
          string.format('endwhy=%s got=%s', tostring(sdec.ck_endwhy), tostring(got)))
    -- 'full' would have claimed a complete recording of silence, and 'quiet' would have blamed the
    -- device for stopping. Both describe a recording that happened.
    -- THE LEVEL IS READ FROM THE STASH, NOT FROM sdec.thr, and the fixture proves it by clearing thr
    -- before asking -- which is what record_run() does by opening the next window. On the instrument
    -- the note read 'nothing crossed -0.00 V' for an arm that had been watching 0.99 V.
    local keepthr = sdec.thr
    sdec.thr = 0
    local why = sdec.strm_exit_why(sdec.ck_endwhy, true, nil)
    sdec.thr = keepthr
    check('...and the note names the two settings that govern the wait, and the armed level',
          has(why, 'raise Arm Wait or lower Arm At') and has(why, 'crossed') and
          not has(why, 'crossed 0.00 V') and not has(why, 'crossed -0.00 V'), why)
    check('...and it waited the operator\'s Arm Wait rather than the recording\'s fill time',
          (sdec.strm_waited or 0) >= sdec.arm_wait_s() - sdec.ck_poll_s,
          string.format('%.2f s waited, Arm Wait %s', sdec.strm_waited or 0,
                        tostring(sdec.arm_wait_s())))
  end

  -- THE BUFFER ALONE CANNOT SEE A TRIGGER, which is what the case above would still pass if the
  -- detection went back to a buffer-level test -- its buf.n sits two readings over the reserve, which
  -- is exactly what the instrument does. This is the other direction: the model reports WAITING and
  -- the buffer is nearly FULL, which no buffer test can tell from a finished recording.
  do
    begin('med', 'edge', quiet_line)
    local realarm = sdec.stream_arm
    sdec.stream_arm = function(nn)
      local ok = realarm(nn)
      sdec.buf.n = nn - 1                  -- one reading short of the whole recording
      TRIG.state = trigger.STATE_WAITING
      return ok
    end
    sdec.stream_acquire(sdec.strm_nsmp)
    sdec.stream_arm = realarm
    TRIG.state = trigger.STATE_IDLE
    check('a model still in its WAIT block is not a finished recording, however full the buffer',
          sdec.ck_endwhy == 'noarm', string.format('endwhy=%s', tostring(sdec.ck_endwhy)))
  end

  -- A PRE-ROLL THAT WRAPPED THE BUFFER BEFORE THE DEVICE SPOKE is the case that broke two of the
  -- three things this loop reads off buf.n. The buffer is FULL and the model is still WAITING: 0.75 s
  -- of wait at 1 MS/s puts an 8 kB recording of a 115 200 Bd line in that state, so it is the common
  -- case at speed rather than a corner.
  do
    begin('med', 'edge', quiet_line)
    local realarm = sdec.stream_arm
    sdec.stream_arm = function(nn)
      local ok = realarm(nn)
      local b = sdec.buf
      b.n = b.capacity                   -- the ring is full, and none of it is the recording
      b.endindex = 12345                 -- parked, because nothing is being written while it waits
      TRIG.state = trigger.STATE_WAITING
      return ok
    end
    local got = sdec.stream_acquire(sdec.strm_nsmp)
    sdec.stream_arm = realarm
    TRIG.state = trigger.STATE_IDLE
    -- 'full' would have claimed a complete recording of the silence it was waiting through, and
    -- 'quiet' would have blamed the device for stopping before it started.
    check('a FULL buffer with the model still waiting is an expired arm, not a finished recording',
          sdec.ck_endwhy == 'noarm',
          string.format('endwhy=%s got=%s', tostring(sdec.ck_endwhy), tostring(got)))
  end

  -- AND A FIRMWARE THAT CANNOT REPORT THE STATE DEGRADES TO THE OLD BEHAVIOUR rather than bounding
  -- every recording on a guess: with trigger.STATE_WAITING absent, trig_waiting() answers nil and
  -- the arm is treated as fired.
  do
    local keepw = trigger.STATE_WAITING
    check('with no STATE_WAITING constant the arm cannot be told, which reads as nil not false',
          sdec.trig_waiting() ~= nil, tostring(sdec.trig_waiting()))
    trigger.STATE_WAITING = nil
    check('...and then an armed recording is NOT bounded as an arm -- the pre-feature behaviour',
          sdec.trig_waiting() == nil, tostring(sdec.trig_waiting()))
    trigger.STATE_WAITING = keepw
  end

  -- ---- AND THE WORKFLOW: silent at the press, transmitting a moment later ----
  do
    begin('med', 'edge', quiet_line)
    local realinit = trigger.model.initiate
    trigger.model.initiate = function()
      -- THE DEVICE STARTS HERE, with the arm already live: the mock fills the armed buffer inside
      -- initiate(), so this is the point that models "and then it began transmitting".
      --
      -- LONGER THAN THE PRE-TRIGGER RESERVE, deliberately: the reserve of an 8 kB recording's buffer
      -- is ~72 000 readings, and the poll loop reads "the buffer has passed its reserve" as "the
      -- trigger fired". A render shorter than that models a capture the instrument cannot produce --
      -- the post-trigger count is 95 % of capacity -- and it reported the fired arm as expired.
      -- A PAYLOAD THAT IS STILL TRANSMITTING AT THE END OF THE RECORD, which is what the arm's own
      -- test needs: "the device has started" is read from the NEWEST window, so a six-byte banner
      -- followed by 1.4 seconds of idle leaves every later window quiet and the arm reads as never
      -- fired. 1500 bytes at 9600 Bd fills 150 000 samples at 100 kS/s, which is a device that keeps
      -- talking -- the case the 8 kB and 32 kB modes exist for.
      local many, q = {}, nil
      for q = 1, 1500 do many[q] = 32 + math.mod(q * 7, 90) end
      SRC.rd, SRC.ts, SRC.nsmp =
        GEN({bytes = many, baud = 9600, fs = 100000, lead = 200, n = 150000})
      SRC.trigat = math.floor(200 * 100000 / 9600)
      return realinit()
    end
    local got = sdec.stream_acquire(sdec.strm_nsmp)
    trigger.model.initiate = realinit
    check('a recording armed on silence collects the message once the device starts',
          got ~= nil and got > 1000 and sdec.ck_endwhy ~= 'noarm',
          string.format('%s readings, endwhy=%s', tostring(got), tostring(sdec.ck_endwhy)))
    -- THE START IS THE POINT: the pre-trigger reserve means the record opens on QUIET LINE, so the
    -- first start bit is not the first sample.
    --
    -- ASSERTED ON THE BUFFER, NOT ON sdec.smp, which is nil here by design -- stream_begin() drops the
    -- probe's Lua copy and the chunked decoder reads the firmware buffer a window at a time, so there
    -- is no Lua array to look at. The readings proxy is what the recording actually holds.
    do
      local rd, lead, i = sdec.buf.readings, 0, nil
      for i = 1, 400 do
        if rd[i] == nil then break end
        if sdec.idle == 1 then
          if rd[i] <= sdec.thr then break end
        else
          if rd[i] >= sdec.thr then break end
        end
        lead = lead + 1
      end
      check('...beginning in the idle line, so no byte of the start is lost',
            lead >= 100, string.format('%d leading idle samples at thr %.2f V, idle=%s', lead,
                                       sdec.thr or 0, tostring(sdec.idle)))
    end
  end

  trigger.model.initiate = realinit0
  trigger.model.state = realstate0
  TRIG.state = trigger.STATE_IDLE
  sdec.stream_armed = nil
  sdec.trigmode, sdec.capmode, sdec.probe_idle = keep.tm, keep.cm, keep.pi
  sdec.fc_out, sdec.trigext = keep.fc, keep.ext
  sdec.armlevel, sdec.armwait, sdec.armkey = keep.lvl, keep.wait, keep.key
  sdec.strm_armed, sdec.strm_recording, sdec.ck_job = nil, nil, nil
  sdec.ck_running, sdec.ck_endwhy = false, nil
  clearforce()
end)()

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

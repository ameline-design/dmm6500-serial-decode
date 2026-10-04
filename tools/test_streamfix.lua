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
  check('and the buffer has 100 readings of headroom past the count asked for',
        atload.capacity - atload.count == 100,
        string.format('capacity=%s count=%s', tostring(atload.capacity), tostring(atload.count)))
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
        and TICKEV() == 'sdec.ui_tick()',
        string.format('%q', tostring(TICKEV())))
  -- A press turns it off for the whole capture and back on afterwards, however the capture ended.
  MD.usb(true)
  MD.forget_files()
  sdec.capture()
  check('a capture leaves the tick ON when it returns',
        TICKEV() == 'sdec.ui_tick()',
        string.format('%q', tostring(TICKEV())))
  -- INCLUDING A CAPTURE THAT RAISED, which is why the wrapper pcalls the body: a raise that skipped
  -- the re-enable leaves the panel blind to the key for the rest of the session.
  --
  -- sdec.mode_cur, NOT sdec.autoset. capture_run's OWN pcall absorbs an autoset raise, so it
  -- returns false normally and the wrapper's pcall is never entered -- the test passed with the
  -- wrapper's pcall deleted outright, which makes it a test of nothing. mode_cur is called unguarded
  -- near the top of capture_run, so stubbing it is a genuine escape, and the signature is the
  -- difference between `false, nil` and a reason.
  local raised, rwhy = nil, nil
  do
    local saved = sdec.mode_cur
    sdec.mode_cur = function() error('escaping', 0) end
    raised, rwhy = pcall(function() return sdec.capture() end)
    sdec.mode_cur = saved
  end
  check('a raise out of the body still reaches the caller, rather than being swallowed',
        raised == false and has(tostring(rwhy), 'escaping'),
        string.format('%s / %s', tostring(raised), tostring(rwhy)))
  check('and the tick is back ON after it', TICKEV() == 'sdec.ui_tick()',
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

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

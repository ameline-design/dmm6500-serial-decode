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

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

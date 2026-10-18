-- test_frontrig.lua -- the trigger SOURCES, driven through sdec.acquire().
--
-- Separate from test_serial.lua for one reason, and it is the reason this file exists
-- at all: every front-trigger test there calls sdec.acq_triggered() DIRECTLY. That
-- proves the branch inside it is written correctly and proves nothing about whether
-- anything reaches it -- and for the whole life of the feature nothing did. acquire()
-- routed only 'edge' to the armed path, so 'Options > Trigger = Trigger key' free-ran
-- while the status row read EXT TRIG KEY, and 844 passing tests said nothing.
--
-- So: EVERY case here goes through sdec.acquire(), the same call the panel makes.
-- What is asserted is the ARMING, not its side effects -- the mocked trigger model in
-- tools/gen_serial.lua records the template, the event constant and the initiate count
-- in TRIG, and a capture that decodes is not evidence that anything was armed.
--
-- Run from the repo root:  lua tools/test_frontrig.lua

dofile('tools/mock_display.lua')     -- hostile display + file mock, object census
dofile('tools/gen_serial.lua')       -- waveform generator, dmm/buffer/trigger mock, decode core
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

-- ---------- test harness (same shape as test_serial.lua) ----------
local pass, fail, nxfail = 0, 0, 0
-- Known-open defects, excused by name, as tools/test_octave.lua does it. An excused case that PASSES fails
-- the suite, so a defect that gets fixed cannot go on being reported as open.
local XFAIL, XSEEN = {}, {}
local function expect_fail(name, why) XFAIL[name] = why end
local function check(name, cond, detail)
  local why = XFAIL[name]
  if why ~= nil then
    XSEEN[name] = true
    if cond then
      fail = fail + 1
      print('  XPASS ' .. name .. (detail and ('   ' .. detail) or ''))
      print('        ^ EXCUSED as a known failure and it PASSED. Remove the expect_fail() for it.')
    else
      nxfail = nxfail + 1
      print('  XFAIL ' .. name .. (detail and ('   ' .. detail) or ''))
      print('        ^ expected: ' .. why)
    end
    return
  end
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end
local function txt(r) if r == nil then return '<nil>' end return GEN_STR(r.vals, r.nf) end

-- Everything the arming assertions read, cleared before each acquire() so a pass can
-- never be inherited from the previous case.
local function arm_reset()
  TRIG.loaded, TRIG.template, TRIG.ev, TRIG.position = false, nil, nil, nil
  TRIG.inits, TRIG.aborts, TRIG.asserts = 0, 0, 0
  TRIG.armed_at_assert = {}
  READS.n, READS.triggered = 0, 0
  dmm.digitize.analogtrigger.mode = nil
  dmm.digitize.analogtrigger.edge.level = nil
  dmm.digitize.analogtrigger.edge.slope = nil
  localnode.showevents = nil
  sdec.lasterr = nil
end

local HELLO = 'Hello, World!'
local hb, hn = GEN_BYTES(HELLO)

sdec.fs, sdec.n = 100000, 8000
sdec.trigext, sdec.fc_out = false, false

-- THREE LINES, and which one a case uses is the whole point.
--   BUSY  -- traffic inside the 2000-sample probe window; the easy case.
--   LATE  -- 400 bit times of lead = 4167 samples, so the PROBE SEES ONLY IDLE and the
--            traffic arrives afterwards. This is what a human pressing TRIGGER looks
--            like: idle when they reach for the key, traffic once the DUT answers.
--   QUIET -- nothing at all, ever.
local brd, bts, bnc, bn = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 20, n = 12000})
local lrd, lts, lnc, ln = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 400, n = 12000})
local qrd, qts, qnc, qn = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 12000,
                               tail = 0, n = 12000})
local LATE_AT = math.floor(400 * 100000 / 9600)

local function use_busy()  SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat = brd, bts, bn, nil end
local function use_late()  SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat = lrd, lts, ln, LATE_AT end
local function use_quiet() SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat = qrd, qts, qn, nil end

-- ============================================================================
print('\nthe front-panel TRIGGER key, through acquire()')
-- ============================================================================
sdec.trigmode = 'front'
use_late()
arm_reset()
local aok, awhy = sdec.acquire()
check('Trigger key: acquire() LOADS a trigger model rather than free-running',
      TRIG.loaded == true and TRIG.template == 'LoopUntilEvent',
      string.format('loaded=%s template=%s', tostring(TRIG.loaded), tostring(TRIG.template)))
check('and it waits on the front-panel key event, not on the analog comparator',
      TRIG.ev == trigger.EVENT_DISPLAY, tostring(TRIG.ev))
check('the capture came from the armed path, not from digitize.read()',
      READS.triggered == 1 and TRIG.inits == 1,
      string.format('triggered=%d inits=%d', READS.triggered, TRIG.inits))
-- IN READINGS, NOT IN PERCENT, and reading the percent is what made this assertion vacuous. position is a
-- percentage of the buffer's CAPACITY and sdec.pretrig is a percentage of the CAPTURE, so the two are equal
-- only where the buffer is exactly the capture. This read `== sdec.pretrig` and passed only because
-- acq_premin's floor happened to force the position there; lowering that floor to what the comparator was
-- measured to need broke the check without changing the reserve by one reading.
-- docs/MEASUREMENTS.md, 'The pre-trigger reserve comes out of capacity, not out of count'.
-- A BAND AND NOT AN EQUALITY, because the over-read sits between sdec.n and the capture: acquire() raises the
-- count by strm_overread before acq_cap sizes the buffer, so the reserve follows 8800 readings where sdec.n
-- says 8000, and the capacity reads 9340 rather than 8500. Pinning either end to sdec.n would make this fail
-- whenever the over-read default moves, which is a setting and not a defect. What the case is for is that a
-- reserve EXISTS and is of the right order -- acq_pospct's arithmetic is asserted exactly in test_serial.
local resv = (sdec.acq_poscap or 0) * (TRIG.position or 0) / 100
check('the pre-trigger reserve is kept, so the start bit is not the first sample',
      resv >= sdec.n * 0.01 and resv <= sdec.n * 0.2,
      string.format('%s %% of %s = %.0f readings, want between %.0f and %.0f',
                    tostring(TRIG.position), tostring(sdec.acq_poscap), resv,
                    sdec.n * 0.01, sdec.n * 0.2))
-- The comparator is not a source for this mode, so an arm left over from an 'edge' capture is
-- instrument state nobody asked for.
check('the analog comparator is turned OFF when the key is the source',
      dmm.digitize.analogtrigger.mode == dmm.MODE_OFF,
      tostring(dmm.digitize.analogtrigger.mode))
check('a key-triggered acquire() of a line that was idle at arm time succeeds',
      aok, tostring(awhy))
local dok, dwhy = sdec.decode()
check('and the captured window decodes the traffic that followed the press',
      dok and sdec.res ~= nil and sdec.res.nbad == 0 and has(txt(sdec.res), HELLO),
      sdec.res and string.format('%q err=%s', txt(sdec.res), tostring(sdec.res.nbad))
      or tostring(dwhy))
check('popups are restored after the capture, not left muted',
      localnode.showevents == eventlog.SEV_ERROR, tostring(localnode.showevents))

-- ---- THE REGRESSION. Fails against the shipped code, passes after the fix. ----
-- A QUIET LINE IS THE CONDITION THE TRIGGER KEY EXISTS FOR. The operator presses it when
-- they are ready; the line being silent until then is normal, not a fault. acquire()
-- refused 'front' on an all-idle probe with "no transitions" -- the one source that
-- tolerates silence was the one that demanded traffic.
sdec.trigmode = 'front'
use_quiet()
arm_reset()
aok, awhy = sdec.acquire()
check('a QUIET line does not stop the key from arming -- the model is still loaded',
      TRIG.loaded == true and TRIG.ev == trigger.EVENT_DISPLAY,
      string.format('loaded=%s ev=%s', tostring(TRIG.loaded), tostring(TRIG.ev)))
check('and the capture is armed rather than refused before it starts',
      TRIG.inits == 1 and READS.triggered == 1,
      string.format('inits=%d triggered=%d', TRIG.inits, READS.triggered))
check('the all-idle probe is recorded rather than treated as a failure',
      sdec.probe_idle ~= nil, tostring(sdec.probe_idle))
-- AND IT STILL ENDS IN A REASON, which is the honest outcome and worth pinning so this
-- file is not read as claiming success: the key was pressed, the window was captured,
-- and there was nothing on the line to decode. What changed is WHERE that is decided --
-- after arming and capturing, not instead of it.
check('a line that is still silent after the press fails with a reason, not a raise',
      not aok and awhy ~= nil, tostring(awhy))

-- Free run has nothing to wait for, so for IT a quiet line really is the end of the road.
-- Pinned here because the fix above widened that check, and widening it too far would
-- turn free run into a capture that waits.
sdec.trigmode = 'free'
use_quiet()
arm_reset()
aok, awhy = sdec.acquire()
check('free run on a quiet line is still refused up front', not aok and awhy ~= nil,
      tostring(awhy))
check('and free run arms nothing at all', TRIG.loaded == false and TRIG.inits == 0,
      string.format('loaded=%s inits=%d', tostring(TRIG.loaded), TRIG.inits))

-- ============================================================================
print('\nrear BNC composed with each source, through acquire()')
-- ============================================================================
-- Rear BNC + Trigger key: dead in both directions before the fix, since the blending
-- lives inside acq_triggered() and nothing routed 'front' there.
sdec.trigmode, sdec.trigext = 'front', true
use_late()
arm_reset()
aok, awhy = sdec.acquire()
check('Rear BNC + Trigger key arms on the BLENDER -- press the key OR pulse the BNC',
      TRIG.ev == trigger.EVENT_BLENDER1, tostring(TRIG.ev))
check('with the key as one stimulus and the rear BNC as the other',
      trigger.blender[1].orenable == true and
      trigger.blender[1].stimulus[1] == trigger.EVENT_DISPLAY and
      trigger.blender[1].stimulus[2] == trigger.EVENT_EXTERNAL,
      string.format('or=%s s1=%s s2=%s', tostring(trigger.blender[1].orenable),
                    tostring(trigger.blender[1].stimulus[1]),
                    tostring(trigger.blender[1].stimulus[2])))
check('and the pair actually captures', aok and sdec.nread > 1,
      string.format('%s nread=%s', tostring(awhy), tostring(sdec.nread)))

-- Rear BNC + Edge: the comparator is stimulus 1 of the blender, so it has to be CONFIGURED. `ev` is
-- reassigned to EVENT_BLENDER1 before any test of it, so a configure gated on `ev` leaves the mode,
-- level and slope unset -- the analog stimulus can never fire, and ticking the rear BNC silently
-- reduces an edge trigger to the BNC alone.
sdec.trigmode, sdec.trigext = 'edge', true
use_late()
arm_reset()
aok, awhy = sdec.acquire()
check('Rear BNC + Edge waits on the blender', TRIG.ev == trigger.EVENT_BLENDER1,
      tostring(TRIG.ev))
check('and CONFIGURES the comparator it wired in as stimulus 1',
      dmm.digitize.analogtrigger.mode == dmm.MODE_EDGE and
      type(dmm.digitize.analogtrigger.edge.level) == 'number' and
      dmm.digitize.analogtrigger.edge.slope == dmm.SLOPE_FALLING,
      string.format('mode=%s level=%s slope=%s',
                    tostring(dmm.digitize.analogtrigger.mode),
                    tostring(dmm.digitize.analogtrigger.edge.level),
                    tostring(dmm.digitize.analogtrigger.edge.slope)))
sdec.trigext = false

-- ============================================================================
print('\ndegradation, and what must NOT be left behind')
-- ============================================================================
-- A source the instrument refuses must come back with samples and a reason. A raise here
-- reaches the front panel as an ERROR-severity event, which is a modal dialog over the app.
sdec.trigmode = 'front'
use_busy()
arm_reset()
local realinit = trigger.model.initiate
trigger.model.initiate = function() error('no such event source', 0) end
local pok, pres, pwhy = pcall(sdec.acquire)
trigger.model.initiate = realinit
check('a refused front-key arm does not RAISE at the panel', pok, tostring(pres))
check('it still returns a capture rather than nothing', pres == true,
      string.format('%s / %s', tostring(pres), tostring(pwhy)))
check('and names the KEY as the source that failed, not the analog trigger',
      has(sdec.lasterr, 'front') and has(sdec.lasterr, 'captured free-running'),
      tostring(sdec.lasterr))
-- A REFUSAL APPENDS NOTHING. The suffix is only ever the bounded wait's own text; firmware-controlled
-- text must not enter a sentence two bench tools parse.
check('a refusal appends no detail, so firmware text stays out of the parsed sentence',
      not has(sdec.lasterr, 'no trigger in'), tostring(sdec.lasterr))
check('the operator trigger setting survives the failure untouched',
      sdec.trigmode == 'front', tostring(sdec.trigmode))
check('the trigger model is not left armed', TRIG.aborts >= 1 and
      trigger.model.state() == trigger.STATE_IDLE,
      string.format('aborts=%d state=%s', TRIG.aborts, tostring(trigger.model.state())))
check('and popups are restored on the failure path too',
      localnode.showevents == eventlog.SEV_ERROR, tostring(localnode.showevents))

-- serial_app.tsp's header says acq_triggered degrades to free-running on a digitizer with no analog
-- trigger. The failure exit's sdec.atrig.mode write sits OUTSIDE the function's pcall, so with atrig
-- nil it raised there instead of degrading -- making the header's claim false on exactly the hardware
-- it describes.
sdec.trigmode = 'front'
use_busy()
arm_reset()
local realatrig = sdec.atrig
sdec.atrig = nil
local realinit2 = trigger.model.initiate
trigger.model.initiate = function() error('no such event source', 0) end
local nok, nres, nwhy = pcall(sdec.acquire)
trigger.model.initiate = realinit2
sdec.atrig = realatrig
check('a digitizer with NO analog trigger degrades rather than raising',
      nok and nres == true, string.format('%s / %s / %s', tostring(nok), tostring(nres),
                                          tostring(nwhy)))

-- AN EXPIRED ARM, AND THE DISCRIMINATOR bench_trigin.py AND bench_trigkey.py DEPEND ON. Those tools
-- read 'trigger unavailable' as "the arm expired" and a lasterr naming an IDLE line as "the trigger
-- FIRED", so the prefix must survive and the suffix must never contain either idle phrase -- otherwise
-- a TRIGGER key that was never pressed reports as a pass.
sdec.trigmode = 'front'
use_busy()
arm_reset()
local realdone = sdec.trig_done
sdec.trig_done = function() return false end
local eok, eres = pcall(sdec.acquire)
sdec.trig_done = realdone
check('an expired arm degrades rather than raising, keeping the contract prefix',
      eok and eres == true and has(sdec.lasterr, 'trigger unavailable')
      and has(sdec.lasterr, 'captured free-running'),
      string.format('%s / %s', tostring(eres), tostring(sdec.lasterr)))
check('...and appends the wait reason, which reached only the USB log before',
      has(sdec.lasterr, 'no trigger in') and has(sdec.lasterr, 'try Free run'),
      tostring(sdec.lasterr))
check('...and never the words the bench reads as "the trigger FIRED"',
      not has(sdec.lasterr, 'idle') and not has(sdec.lasterr, 'no transitions'),
      tostring(sdec.lasterr))

-- Flow control on the key path. The credit pulse is permission to transmit one window's
-- worth, and it is only correct AFTER the model is armed -- a pulse issued first loses the
-- head of the frame. Never exercised for 'front' before, since nothing arrived armed.
sdec.trigmode, sdec.fc_out = 'front', true
use_late()
arm_reset()
aok, awhy = sdec.acquire()
check('the key path pulses the rear output exactly once', TRIG.asserts == 1,
      tostring(TRIG.asserts))
check('and the pulse leaves AFTER the model is armed, not before',
      (TRIG.armed_at_assert[1] or 0) >= 1,
      string.format('inits at assert = %s', tostring(TRIG.armed_at_assert[1])))
sdec.fc_out = false

-- Repeated arming must not accumulate buffers: the same rule acquire() is held to on the edge path,
-- which 'front' also takes.
sdec.trigmode = 'front'
use_late()
sdec.acquire()
local b1 = LIVEBUFS()
sdec.acquire()
check('re-arming the key path leaks no reading buffers', LIVEBUFS() == b1,
      'buffers=' .. LIVEBUFS() .. ' vs ' .. b1)

sdec.trigmode, sdec.trigext, sdec.fc_out = 'edge', false, false

-- ============================================================================
print('\nthe capture is bounded by the count, not by the buffer')
-- ============================================================================
-- WHY THIS FIXTURE IS LONG, and it is the whole reason this section exists. LoopUntilEvent's post-trigger
-- count is (100 - position) % of the buffer's CAPACITY, and position only moves the split, so an armed
-- capture stores the buffer rather than the count it asked for. Against a buffer sized by acq_cap(n) the
-- two are the same number, which is why no suite ever saw it; against the static 262 144-reading frame
-- buffer they are not. Measured on the instrument: position 4.5455 % stored 250 228 readings for a 22 000
-- ask, so 64 smoke cells decoded ~2950 bytes in a 240-byte mode and every cell at fs <= 80 kS/s expired
-- against a wait sized from n and fell back to free-running.
--
-- Every other source in this file renders 12 000 samples, under any bound worth testing, so a short record
-- cannot tell a bounded capture from an unbounded one. This one renders 90 000.
-- docs/MEASUREMENTS.md, 'The pre-trigger reserve comes out of capacity, not out of count'.
local ord, ots, onc, on = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 20, n = 90000})
SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat = ord, ots, on, nil
sdec.capmode, sdec.trigmode, sdec.fs = 'frame', 'edge', 100000
-- AT A REAL FRAME DEPTH, because the ladder is sized for what frame mode actually asks: 240 bytes x 10 bits
-- x 4.3 to 12 samples a bit, so acq_cap lands between 12 020 and 45 460. This suite's own n of 8000 is below
-- the bottom rung, where the fit is necessarily loose and says nothing about the ladder working.
local keepn = sdec.n
sdec.n = 20000
pcall(sdec.acq_buffree)
sdec.acq_bufs = {}
local binit = pcall(sdec.acq_bufinit)
local bigbuf, bigcap = sdec.acq_bufmode('frame')
arm_reset()
sdec.thr, sdec.hyst = 1.65, 0.5
-- THROUGH acq_make_buffer, which is how acquire() reaches this and therefore the only path that picks a
-- rung. Setting sdec.buf from acq_bufinit alone takes the plan's default and measures the old behaviour --
-- which is what this case did, and why it went on reporting 31 129 after the ladder landed.
sdec.acq_make_buffer(sdec.acq_cap(sdec.n))
local fitbuf, fitcap = sdec.acq_bufmode('frame', sdec.acq_cap(sdec.n))
local nr = sdec.acq_triggered(sdec.n, dmm.SLOPE_FALLING)

-- THE TWO PREMISES FIRST. Without them a pass means only that something was small.
check('the plan default really is larger than this capture, so a loose fit was available',
      binit == true and bigcap ~= nil and bigcap > sdec.acq_cap(sdec.n),
      string.format('init=%s plan cap=%s ask=%s', tostring(binit), tostring(bigcap),
                    tostring(sdec.acq_cap(sdec.n))))
check('...and the rung chosen is smaller than it, so a rung really was chosen',
      fitcap ~= nil and bigcap ~= nil and fitcap < bigcap,
      string.format('rung=%s of plan default %s', tostring(fitcap), tostring(bigcap)))
check('and the source outruns the count, or a bound cannot be seen at all',
      on > 4 * sdec.n, string.format('%s samples against n=%s', tostring(on), tostring(sdec.n)))

-- BOUNDED BY THE LADDER, AND NOT EXACTLY, which is the honest claim. An armed capture stores the whole
-- buffer, so the record can only be as close to the count as the nearest rung is to acq_cap(n) -- the rungs
-- are spaced about 1.25x, so 1.3 is the tolerance the design can promise and anything looser means a rung
-- was not chosen. Exactness would need a capacity per capture, which is the one thing a static set forbids.
--
-- The two alternatives are both closed: an explicit post-trigger count moves the pre-roll into a scratch and
-- clips the first byte of every capture ('Hello, World!' as 'ello, World!'), and a bound in acq_triggered's
-- poll loop must be gated on the trigger having fired, which docs/TRIGGER.md records as never once
-- observable -- STATE_WAITING was not seen in twelve hardware captures.
local resv2 = math.ceil((sdec.acq_poscap or 0) * (TRIG.position or 0) / 100)
local nbound = resv2 + sdec.n
local unbounded = (sdec.acq_poscap or 0) * (100 - (TRIG.position or 0)) / 100
check('the record holds about the reserve plus the count, not a share of the largest buffer',
      nr ~= nil and nr <= nbound * 1.3,
      string.format('%s readings; bound %s = %s reserve + %s count, x%.2f; the chosen rung %s stores %.0f',
                    tostring(nr), tostring(nbound), tostring(resv2), tostring(sdec.n),
                    (nr or 0) / nbound, tostring(sdec.acq_poscap), unbounded))
-- Expected-fail the other way: the bound must not be passing because the source ran out.
check('and not merely because the source ended, which would pass the bound by accident',
      nr ~= nil and nr < on * 0.9, string.format('%s of %s rendered', tostring(nr), tostring(on)))
check('the capture still reports as triggered rather than as an expired arm',
      sdec.lasterr == nil, tostring(sdec.lasterr))
sdec.n = keepn
check('and the suite puts the capture depth back, or every case after this one measures 20 000',
      sdec.n == keepn, tostring(sdec.n))

print()
print(string.format('%d passed, %d failed, %d expected failure(s)', pass, fail, nxfail))
if nxfail > 0 then
  print('Expected failures are KNOWN OPEN DEFECTS, named above with the reason. '
        .. 'They do not fail the suite; an expected failure that PASSES does.')
end
-- An excused name that no case reached is a stale excuse, and it would hide a regression silently.
for k in pairs(XFAIL) do
  if not XSEEN[k] then
    fail = fail + 1
    print('  STALE expect_fail with no matching case: ' .. k)
  end
end
os.exit(fail == 0 and 0 or 1)

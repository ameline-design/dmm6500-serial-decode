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
check('the pre-trigger reserve is kept, so the start bit is not the first sample',
      TRIG.position == sdec.pretrig, tostring(TRIG.position))
-- The comparator is not a source for this mode, so leaving it armed from an earlier
-- 'edge' capture would be instrument state nobody asked for.
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

-- Rear BNC + Edge: the comparator is stimulus 1 of the blender, so it has to be
-- CONFIGURED. `ev` is reassigned to EVENT_BLENDER1 before the old test of it, so the
-- mode, level and slope went unset and the analog stimulus could never fire -- ticking
-- the rear BNC silently reduced an edge trigger to the BNC alone.
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
check('the operator trigger setting survives the failure untouched',
      sdec.trigmode == 'front', tostring(sdec.trigmode))
check('the trigger model is not left armed', TRIG.aborts >= 1 and
      trigger.model.state() == trigger.STATE_IDLE,
      string.format('aborts=%d state=%s', TRIG.aborts, tostring(trigger.model.state())))
check('and popups are restored on the failure path too',
      localnode.showevents == eventlog.SEV_ERROR, tostring(localnode.showevents))

-- A firmware without trigger.EVENT_DISPLAY would otherwise pass NIL to model.load() and
-- to the blender stimulus, where the key vanishes silently.
sdec.trigmode = 'front'
use_busy()
arm_reset()
local realev = trigger.EVENT_DISPLAY
trigger.EVENT_DISPLAY = nil
pok, pres, pwhy = pcall(sdec.acquire)
trigger.EVENT_DISPLAY = realev
check('a missing front-key event constant degrades instead of raising',
      pok and pres == true, string.format('%s / %s', tostring(pok), tostring(pres)))
check('with the missing thing named', has(sdec.lasterr, 'front-panel'),
      tostring(sdec.lasterr))
check('and no model is ever loaded on a nil event', TRIG.loaded == false,
      string.format('loaded=%s ev=%s', tostring(TRIG.loaded), tostring(TRIG.ev)))

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

-- Repeated arming must not accumulate buffers, the same rule acquire() is held to on the
-- edge path -- and 'front' now takes that path too.
sdec.trigmode = 'front'
use_late()
sdec.acquire()
local b1 = LIVEBUFS()
sdec.acquire()
check('re-arming the key path leaks no reading buffers', LIVEBUFS() == b1,
      'buffers=' .. LIVEBUFS() .. ' vs ' .. b1)

sdec.trigmode, sdec.trigext, sdec.fc_out = 'edge', false, false

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

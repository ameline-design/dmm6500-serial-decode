-- test_trigmodel.lua -- the trigger subsystem as a MACHINE, against the mock's model of one.
--
-- WHY THIS FILE EXISTS. Two things the offline harness could not express, both of which cost a
-- hardware lap to find:
--
--   1. THE COMPARATOR WAS NOT MODELLED. SRC.trigat was a fixture input: the test said where the
--      trigger fired and gen_serial.lua honoured it whatever dmm.digitize.analogtrigger.edge.level
--      and .slope had been set to. So a capture armed at a level nowhere near the signal fired
--      anyway, and no assertion could tell a correct arm from a wrong one. MEASURED on the
--      instrument: the shipped app armed an 8 kB recording's comparator at 1.63 V -- the PREVIOUS
--      capture's measured midpoint on a 0-3.29 V line, which is mid-data -- instead of at idle plus
--      the operator's Arm At. Every offline test passed. Only the bench caught it.
--
--   2. THE MODEL HAD NO STATE MACHINE. trigger.model.state() answered a static field, so the passage
--      of time through the template's blocks was unmodelled and every suite that needed the
--      instrument's own sequence staged it by hand. That is why sdec.arm_settle_s could ship at
--      0.25 s against an arrival MEASURED at 0.164 to 0.228 s -- about ten per cent of margin over
--      the slowest arm the instrument makes, so the same hardware case armed once and failed the
--      next three. Offline it was always fine: the mock reported WAITING on the second state read,
--      always, whatever the budget was.
--
-- WHAT THE MODEL NOW DERIVES RATHER THAN BEING TOLD. The trigger point comes from a scan of SRC.rd
-- for the first crossing of the comparator's own level in the direction its own slope names, and the
-- states come from a block walk on a virtual clock that delay() advances. Both are opt-in --
-- SRC_TRIGDERIVE(true) and TRIG_WALK(true) -- because turning either on by default would recompute
-- the stimulus of every existing fixture, which is a different experiment and not a better one.
--
-- THE TWO ASSERTIONS THAT CARRY THIS FILE are marked ==== MUTATION PROOF ==== below. Each fails when
-- its correction is removed from tsp/, and each says which line that is. An assertion that passes
-- with the app's logic taken out is worse than no assertion at all.
--
-- Run from the repo root:  lua tools/test_trigmodel.lua

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

local PASS, FAIL = 0, 0
local function CK(name, cond, detail)
  if cond then
    PASS = PASS + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    FAIL = FAIL + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end
local function HAS(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end
local function NEAR(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= tol end

MD.usb(true)
MD.forget_files()
sdec.ui_build()
TRIG_WALK(true)
SRC_TRIGDERIVE(true)

-- A SYNTHETIC STEP RATHER THAN A UART RENDER, for the unit sections: the comparator's contract is
-- about a level and a direction, and a two-level step with known indices is the only stimulus that
-- makes "the trigger index is the first sample on the new side" an exact assertion instead of an
-- approximate one. nhi = 0 leaves a line that only ever RISES, which is what makes a wrong slope
-- wrong-able.
local function STEP(nlo, nhi, ntail, lo, hi, fs)
  local rd, ts, n, i = {}, {}, 0, nil
  fs = fs or 100000
  for i = 1, nlo do n = n + 1; rd[n] = lo end
  for i = 1, nhi do n = n + 1; rd[n] = hi end
  for i = 1, ntail do n = n + 1; rd[n] = lo end
  for i = 1, n do ts[i] = (i - 1) / fs end
  SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat = rd, ts, n, nil
  SRC.loop, SRC.native_fs = false, nil
  return n
end

-- One armed capture, built by hand so the comparator is the only variable. `ev` is the model's event,
-- so the blender and front-key branches are reachable from here too.
local function ARM(level, slope, mode, ev, cap)
  local b = buffer.make(cap or 300)
  dmm.digitize.analogtrigger.mode = mode
  dmm.digitize.analogtrigger.edge.level = level
  dmm.digitize.analogtrigger.edge.slope = slope
  trigger.model.load('LoopUntilEvent', ev or trigger.EVENT_ANALOGTRIGGER, 5,
                     trigger.CLEAR_ENTER, 0, b)
  TRIG_CLOCK(0)
  trigger.model.initiate()
  return b
end
local function DROP(b)
  -- DELETED, NOT DROPPED: a handle set to nil strands the buffer in firmware until a power cycle,
  -- and LIVEBUFS() is what the other suites count.
  pcall(buffer.delete, b)
end

-- ============================================================================
print('\nA  the loaded template is a PROGRAM, and its shape is what the firmware acts on')
-- ============================================================================
-- docs/TRIGGER.md section 8 disassembles both templates. Asserting the SHAPE rather than the
-- template's name is the difference between testing the firmware's behaviour and testing that the
-- app passed a particular string: "a SimpleLoop recording cannot be armed" is true because the
-- program has no WAIT block in it, not because of what it is called.
;(function()
  STEP(100, 100, 100, 0.0, 3.3)
  local b = buffer.make(300)
  trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5, trigger.CLEAR_ENTER, 0, b)
  CK('LoopUntilEvent is six blocks', TRIG.nblocks == 6, tostring(TRIG.nblocks))
  local ops, i = {}, nil
  for i = 1, TRIG.nblocks do ops[i] = TRIG.blocks[i].op end
  CK('...in the order the instrument disassembles them',
     ops[1] == 'BUFFER_CLEAR' and ops[2] == 'DELAY_CONSTANT' and ops[3] == 'MEASURE_DIGITIZE' and
     ops[4] == 'WAIT' and ops[5] == 'MEASURE_DIGITIZE' and ops[6] == 'NOTIFY',
     table.concat(ops, ' '))
  CK('...with the pre-roll INFINITE, which is what makes the comparator evaluate at all',
     TRIG.blocks[3].arg == 'infinite', tostring(TRIG.blocks[3].arg))
  CK('...and the wait carrying the event and CLEAR_ENTER',
     TRIG.blocks[4].arg == trigger.EVENT_ANALOGTRIGGER and
     TRIG.blocks[4].clear == trigger.CLEAR_ENTER,
     string.format('%s %s', tostring(TRIG.blocks[4].arg), tostring(TRIG.blocks[4].clear)))
  CK('so it is armable, because it has a block that waits', TRIG.armable == true,
     tostring(TRIG.armable))

  trigger.model.load('SimpleLoop', 4096, 0, b)
  CK('SimpleLoop is five blocks and NONE of them waits',
     TRIG.nblocks == 5 and TRIG.armable == false,
     string.format('%d blocks, armable=%s', TRIG.nblocks, tostring(TRIG.armable)))
  CK('...it is a counted loop, so the branch is what ends it',
     TRIG.blocks[5].op == 'BRANCH_COUNTER' and TRIG.blocks[5].target == 2 and
     TRIG.blocks[5].arg == 4096,
     string.format('%s %s -> %s', TRIG.blocks[5].op, tostring(TRIG.blocks[5].arg),
                   tostring(TRIG.blocks[5].target)))
  -- ANY load() REPLACES THE STORE WHOLESALE AND TRUNCATES IT -- MEASURED against eight NOPs, and the
  -- reason there is no stale-tail trap. A six-block template over a five-block one must leave six.
  trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5, trigger.CLEAR_ENTER, 0, b)
  CK('...and a load replaces the store wholesale, leaving no tail blocks',
     TRIG.nblocks == 6 and TRIG.blocks[7] == nil, tostring(TRIG.nblocks))
  DROP(b)
end)()

-- ============================================================================
print('\nB  the model WALKS its blocks on a virtual clock')
-- ============================================================================
-- MEASURED on 1.7.17a, and the two halves of it are DIFFERENT TIMES (docs/TRIGGER.md section 8):
--   * THE WAIT BLOCK GOES LIVE ABOUT 2 ms after initiate(). From the recorded data, pre-roll start =
--     fire_s - N5/fs - n_pre/fs gives 1.6 to 2.6 ms over six captures; from the block trajectory,
--     BUFFER_CLEAR completes at 0.0003 s and the zero DELAY_CONSTANT at 0.0012 s.
--   * THE STATE CALL DOES NOT ADMIT IT for another 190 ms -- 0.164 to 0.228 s from initiate(),
--     depending on what the instrument was doing before.
-- So the 0.19 s bounds the firmware's CANDOUR, not its readiness, and a mock that modelled it as an
-- arming delay would get the consequence backwards. Both are only assertable against a model where
-- time passes.
;(function()
  -- A LONG PRE-TRIGGER SILENCE, because a wait has to outlast the candour lag to be observable at
  -- all: 40 000 samples at 100 kS/s is 0.4 s of line with nothing on it.
  --
  -- THE PRIOR STATE IS SET BY HAND HERE AND ONLY HERE, to the row that means "nothing was acquiring",
  -- so this section's arithmetic does not depend on what an earlier section left the instrument
  -- doing. Sections D, E and F take whatever they earn.
  TRIG_PRIOR(nil)
  STEP(40000, 200, 200, 0.0, 3.3)
  local b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)

  CK('immediately after initiate() the model is RUNNING, not waiting',
     trigger.model.state() == trigger.STATE_RUNNING, tostring(trigger.model.state()))
  CK('...so the app\'s first look sees "not waiting" with no trigger having happened',
     sdec.trig_waiting() == false, tostring(sdec.trig_waiting()))
  CK('...and it is executing the FIRST block', TRIG.at() == 1, tostring(TRIG.at()))
  -- READING THE STATE MUST NOT MOVE THE CLOCK. An app that polls without delaying is spinning, and
  -- a mock that advanced time on each read would make every spin terminate for free -- which is
  -- precisely the defect class here, a budget spent in poll counts against a model that needs
  -- wall time.
  local c0, i = TRIG_CLOCK(), nil
  for i = 1, 20 do trigger.model.state() end
  CK('...and twenty state reads advance the clock by nothing at all',
     TRIG_CLOCK() == c0, string.format('%s -> %s', tostring(c0), tostring(TRIG_CLOCK())))

  -- ==== READINESS: THE WAIT IS LIVE AT 2 ms ====
  CK('the wait block goes live about 2 ms after initiate, the measured block trajectory',
     NEAR(TRIG.t_wait - TRIG.t0, 0.002, 1e-9),
     string.format('%.6f s = clear %s + delay %s + digitize %s', TRIG.t_wait - TRIG.t0,
                   tostring(TRIG.cost.buffer_clear), tostring(TRIG.cost.delay),
                   tostring(TRIG.cost.digitize)))
  delay(0.005)
  CK('...so at 5 ms the model is REALLY in its wait block',
     TRIG.walkstate() == 'waiting' and TRIG.at() == 4,
     string.format('%s, block %s', TRIG.walkstate(), tostring(TRIG.at())))
  -- ==== CANDOUR: THE STATE CALL STILL SAYS RUNNING ====
  CK('...and the state call still says RUNNING, because 0.19 s is a REPORTING lag',
     trigger.model.state() == trigger.STATE_RUNNING and sdec.trig_waiting() == false,
     string.format('reported %s while really %s', tostring(trigger.model.state()),
                   TRIG.walkstate()))
  CK('...and delay() advanced the clock by exactly what it was asked for, without sleeping',
     NEAR(TRIG_CLOCK() - c0, 0.005, 1e-9), string.format('%.6f s', TRIG_CLOCK() - c0))
  -- THE OBSERVATION TIME IS THE MEASURED FIGURE, not one this file picked: 0.191 s for a model loaded
  -- with nothing acquiring beforehand. Checked against the measured band rather than for equality,
  -- so re-measuring the median does not fail a suite that is asserting the behaviour.
  delay(TRIG.observed_at() - (TRIG_CLOCK() - c0) + 0.0001)
  CK('the state admits the wait at the measured 0.164 to 0.228 s, by prior state',
     sdec.trig_waiting() == true and TRIG.observed_at() >= 0.164 and
     TRIG.observed_at() <= 0.228,
     string.format('%.4f s, prior=%s, lag %.4f s', TRIG.observed_at(), tostring(TRIG.prior),
                   TRIG.lag()))
  CK('...which is ninety times longer than the model took to get there',
     TRIG.lag() / (TRIG.t_wait - TRIG.t0) > 50,
     string.format('%.4f s of lag against %.4f s of work', TRIG.lag(), TRIG.t_wait - TRIG.t0))

  -- THE WAIT LASTS AS LONG AS THE SIGNAL TAKES, not as long as the poll loop is willing to look.
  -- The step rises at sample 40 001 of a 100 kS/s render, so the event is 0.4 s away.
  CK('the wait ends when the signal crosses, and not before',
     NEAR(TRIG.t_fire - TRIG.t_wait, 40000 / 100000, 1e-9),
     string.format('%.6f s of wait for a crossing at sample %s', TRIG.t_fire - TRIG.t_wait,
                   tostring(SRC.trigfired)))
  -- STEPPED TO THE MODEL'S OWN FIRE TIME rather than to a hand-written number, so the assertion is
  -- about the ORDER of the phases and not about this stimulus's arithmetic.
  delay(TRIG.t_fire - TRIG_CLOCK() + 0.0001)
  CK('...and the model really leaves the wait then', TRIG.walkstate() ~= 'waiting',
     TRIG.walkstate())
  CK('...while the state call is still reporting the wait, lagging the fire as it lagged the entry',
     trigger.model.state() == trigger.STATE_WAITING,
     string.format('reported %s while really %s', tostring(trigger.model.state()),
                   TRIG.walkstate()))
  -- The burst is post readings at the delivered rate: 285 of a 300-reading buffer at position 5,
  -- plus the cost of starting the block.
  CK('...for as long as the burst takes',
     NEAR(TRIG.t_done - TRIG.t_fire, 285 / 100000 + TRIG.cost.digitize, 1e-9),
     string.format('%.6f s for %d readings', TRIG.t_done - TRIG.t_fire, 285))
  delay(1.0)
  CK('and then it goes IDLE, which is what trig_done() tests for',
     trigger.model.state() == trigger.STATE_IDLE and sdec.trig_done(b) == true,
     string.format('%s n=%s', tostring(trigger.model.state()), tostring(b.n)))

  -- ==== AN ARM THAT FIRES INSIDE THE LAG IS NEVER REPORTED AS WAITING AT ALL ====
  -- MEASURED: in twelve latency captures STATE_WAITING was never once observed, because the signal
  -- fired within one ramp period of the wait going live. 2 ms of pre-trigger silence here against a
  -- 0.19 s candour lag, polled every 10 ms for a whole second -- which is a hundred looks.
  --
  -- THIS IS THE DEFECT, NOT A CURIOSITY: stream_arm() reads "I never saw WAITING" as "the arm never
  -- went live", so a capture that armed and fired correctly is reported as one that did not.
  DROP(b)
  STEP(200, 200, 200, 0.0, 3.3)
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  local sawwait, k = false, nil
  for k = 1, 100 do
    if sdec.trig_waiting() == true then sawwait = true end
    delay(0.01)
  end
  CK('an arm whose event arrives inside the candour lag is NEVER reported as waiting',
     sawwait == false and TRIG.t_fire ~= nil,
     string.format('fired at %s, %.4f s after the wait went live, against a %.4f s lag',
                   tostring(SRC.trigfired), TRIG.t_fire - TRIG.t_wait, TRIG.lag()))
  CK('...even though the capture is complete and correct',
     sdec.trig_done(b) == true and (b.n or 0) > 0,
     string.format('done=%s n=%s', tostring(sdec.trig_done(b)), tostring(b.n)))

  -- ==== THE COMPARATOR'S LATENCY IS FIXED IN TIME, NOT IN SAMPLES ====
  -- MEASURED against a slow ramp: 7.16 us at 200 kS/s and 7.36 us at 1 MS/s -- a 1.03x change across
  -- a 5.0x change of rate, against 3.44x measured in samples. So the same crossing lands 0 samples
  -- late at 40 kS/s and 7 late at 1 MS/s, and a mock charging it in samples would be wrong by 3.4x.
  DROP(b)
  STEP(200, 200, 200, 0.0, 3.3, 1000000)
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('at 1 MS/s the 7.3 us comparator latency puts the trigger seven samples past the crossing',
     SRC.trigfired == 201 + math.floor(TRIG.cost.cmp_latency * 1000000) and SRC.trigfired == 208,
     string.format('crossing at 201, trigger at %s', tostring(SRC.trigfired)))
  DROP(b)
  STEP(200, 200, 200, 0.0, 3.3, 40000)
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('...and at 40 kS/s the same latency is 0.29 of a sample and rounds away',
     SRC.trigfired == 201, string.format('crossing at 201, trigger at %s',
                                         tostring(SRC.trigfired)))
  STEP(40000, 200, 200, 0.0, 3.3)

  -- ABORT ENDS THE WALK. sdec.trig_settle() aborts and then polls fifty times for IDLE, so a model
  -- that kept running would cost half a second of clock and answer false.
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  CK('a running model aborts to IDLE', TRIG.t0 ~= nil, tostring(TRIG.t0))
  trigger.model.abort()
  CK('...and an aborted one is executing no block at all',
     trigger.model.state() == trigger.STATE_IDLE and TRIG.at() == nil,
     string.format('%s block=%s', tostring(trigger.model.state()), tostring(TRIG.at())))
  -- THE STORE SURVIVES THE ABORT -- MEASURED, docs/TRIGGER.md section 4: abort() leaves every block
  -- in place and only load() replaces them.
  CK('...but the program is still loaded, because abort does not clear the store',
     TRIG.nblocks == 6 and TRIG.loaded == true, tostring(TRIG.nblocks))

  -- ==== THE ARRIVAL DOES NOT SCALE WITH THE BUFFER, AND THAT IS A NULL WORTH GATING ====
  -- This mock charged BUFFER_CLEAR per reading, taken from buffer.make()'s cost on the argument that
  -- buffer work is linear in readings. MEASURED and refuted: seven capacities from 21 100 to
  -- 2 800 000 -- a 133-fold range -- are flat at 0.171 to 0.180 s, and a per-reading charge predicts
  -- the 860 000 case about seventy times too high. If anyone reintroduces the scaling, this fails.
  TRIG_PRIOR(nil)
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  local small = TRIG.t_wait - TRIG.t0
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300000)
  local big = TRIG.t_wait - TRIG.t0
  CK('a buffer a THOUSAND times deeper reaches its wait at the same time -- the arrival is flat',
     NEAR(big, small, 1e-12),
     string.format('%.6f s at 300 readings, %.6f s at 300000', small, big))

  -- ==== WHAT DOES MOVE IT IS THE PRIOR MODEL'S STATE ====
  -- MEASURED: 0.228 s after aborting a model that was itself sitting in STATE_WAITING, against
  -- 0.164 s after a completed dmm.digitize.read(). Earned rather than declared -- the mock records
  -- the row where each prior state ENDS, so this arranges the state and reads the consequence.
  STEP(40000, 200, 200, 0.0, 3.3)
  ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)     -- a level nothing crosses: it will wait
  delay(0.3)
  CK('a model left sitting in its wait is the state the next arm pays most for',
     sdec.trig_waiting() == true, tostring(trigger.model.state()))
  trigger.model.abort()
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  local afterwait = TRIG.observed_at()
  CK('...so the next arm is admitted at the measured worst case',
     TRIG.prior == 'waiting' and NEAR(afterwait, 0.228, 1e-9),
     string.format('%.4f s after prior=%s', afterwait, tostring(TRIG.prior)))
  trigger.model.abort()
  local rb = buffer.make(300)
  dmm.digitize.count = 100
  dmm.digitize.read(rb)
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  CK('...while an arm after a completed free-run read is admitted soonest',
     TRIG.prior == 'read' and NEAR(TRIG.observed_at(), 0.164, 1e-9) and
     TRIG.observed_at() < afterwait,
     string.format('%.4f s after prior=%s, against %.4f s', TRIG.observed_at(),
                   tostring(TRIG.prior), afterwait))
  -- AND THE READINESS DOES NOT MOVE WITH IT, which is the whole distinction: the prior state changes
  -- when the firmware ADMITS the wait, not when the wait goes live.
  CK('...and the block trajectory is the same either way -- only the candour moved',
     NEAR(TRIG.t_wait - TRIG.t0, 0.002, 1e-9),
     string.format('%.6f s to live, %.4f s to admitted', TRIG.t_wait - TRIG.t0,
                   TRIG.observed_at()))
  DROP(rb)

  -- AND THE LAG IS STILL SETTABLE, which is the point of it being a field: a suite documenting a
  -- story about a firmware that is slow to admit a wait pins it and says so, rather than arranging a
  -- prior state that happens to be slow. Asserted as a delta, so what is pinned is the law.
  local keep = TRIG.cost.report_lag
  TRIG_PRIOR(nil)
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  local base = TRIG.observed_at()
  TRIG.cost.report_lag = base + 0.1
  ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, nil, 300)
  CK('a tenth of a second more candour lag puts the ADMISSION later, and nothing else moves',
     NEAR(TRIG.observed_at() - base, 0.1, 1e-9) and
     NEAR(TRIG.t_wait - TRIG.t0, 0.002, 1e-9) and NEAR(TRIG.t_fire - TRIG.t_wait, 0.4, 1e-9),
     string.format('%.4f s -> %.4f s admitted, still %.6f s to live', base, TRIG.observed_at(),
                   TRIG.t_wait - TRIG.t0))
  delay(base + 0.01)
  CK('...and the old admission time no longer reaches it', sdec.trig_waiting() == false,
     tostring(trigger.model.state()))
  delay(TRIG.t_wait + TRIG.lag() - TRIG_CLOCK() + 0.0001)
  CK('...while the new one does', sdec.trig_waiting() == true, tostring(trigger.model.state()))
  TRIG.cost.report_lag = keep

  -- SimpleLoop HAS NO WAIT BLOCK, so it can never be found waiting however long anyone looks. This
  -- is the containment half of "a recording built on SimpleLoop cannot be armed".
  local sb = buffer.make(300)
  trigger.model.load('SimpleLoop', 200, 0, sb)
  TRIG_CLOCK(0)
  trigger.model.initiate()
  local sawwait = false
  local k
  for k = 1, 50 do
    if sdec.trig_waiting() == true then sawwait = true end
    delay(0.01)
  end
  CK('SimpleLoop is never found WAITING, at any point in half a second of polling',
     sawwait == false, tostring(trigger.model.state()))
  CK('...and it acquires the instant it is initiated', sb.n == 200, tostring(sb.n))
  DROP(sb)
  DROP(b)
end)()

-- ============================================================================
print('\nC  the trigger point is DERIVED from the comparator, not declared by the fixture')
-- ============================================================================
-- Three firmware facts, all MEASURED and recorded in docs/TRIGGER.md section 7, and none of them
-- expressible against a mock that honours SRC.trigat whatever the comparator says:
--   * the level is real -- armed at 8 V on a 0-3 V square wave the model sat in STATE_WAITING
--     indefinitely and never fired;
--   * the slope is real, and the two settings give opposite directions through the trigger index;
--   * MODE_OFF means the comparator is not a source.
--
-- THE HARDWARE HALF IS hw-arm CASES H, I AND M, which measure the level and slope the comparator
-- actually HOLDS -- 0.33 V above a grounded line, 5.99 V read back against 6.00 asked, and -4.00 V
-- RISING on a line idling at -5 V where a wrong sign cannot fire at all. What those cannot do is give
-- a wrong level a consequence, because a bench case that does not fire is indistinguishable from a
-- quiet device. This section is the other half: the level decides WHERE the trigger lands, so arming
-- at the wrong one changes the record.
;(function()
  local n = STEP(100, 100, 100, 0.0, 3.3)
  local b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('a comparator armed inside the swing fires, and the scan is what decided it',
     SRC.trigfired == 101 and SRC.trigsrc == 'comparator',
     string.format('fired at %s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  -- MEASURED: reading either side of the trigger index gave -0.001 V before and 3.000 V after for
  -- SLOPE_RISING. The index is the first sample on the NEW side.
  CK('...at the first sample on the new side of the level',
     SRC.rd[SRC.trigfired] == 3.3 and SRC.rd[SRC.trigfired - 1] == 0.0,
     string.format('%s before, %s at', tostring(SRC.rd[SRC.trigfired - 1]),
                   tostring(SRC.rd[SRC.trigfired])))
  DROP(b)

  b = ARM(1.5, dmm.SLOPE_FALLING, dmm.MODE_EDGE)
  CK('the opposite slope fires on the opposite edge of the same signal',
     SRC.trigfired == 201 and SRC.rd[201] == 0.0 and SRC.rd[200] == 3.3,
     string.format('fired at %s', tostring(SRC.trigfired)))
  DROP(b)

  -- ==== THE 8 V MEASUREMENT ====
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('a level ABOVE the whole signal never fires, however long the pre-roll runs',
     SRC.trigfired == nil and HAS(SRC.trigwhy, 'nothing crossed'),
     tostring(SRC.trigwhy))
  -- A WAIT THAT NEVER ENDS HAS NO END TIME, so the model stays in its wait block for ever -- which
  -- is what STATE_WAITING indefinitely means and is not an error state. Stepped past the setup
  -- first, because the blocks AHEAD of the wait still have to run.
  delay(10.0)
  CK('...and the model is left sitting in its WAIT block, which is what the instrument does',
     sdec.trig_waiting() == true and TRIG.t_fire == nil and TRIG.at() == 4,
     string.format('state=%s t_fire=%s block=%s', tostring(trigger.model.state()),
                   tostring(TRIG.t_fire), tostring(TRIG.at())))
  CK('...with its pre-roll in the buffer, so a buffer-level completion test is satisfiable',
     (b.n or 0) > 0 and sdec.trig_done(b) == false,
     string.format('n=%s done=%s', tostring(b.n), tostring(sdec.trig_done(b))))
  CK('...counted as an arm that never fired rather than as a capture', READS.noarm > 0,
     string.format('noarm=%d', READS.noarm))
  DROP(b)

  -- ==== THE SLOPE MUST BE WRONG-ABLE ====
  -- A line that only ever rises. SLOPE_FALLING on it is an arm that cannot fire, and a mock that
  -- ignored the slope would report a trigger anyway.
  STEP(100, 100, 0, 0.0, 3.3)
  b = ARM(1.5, dmm.SLOPE_FALLING, dmm.MODE_EDGE)
  CK('SLOPE_FALLING on a line that only rises never fires',
     SRC.trigfired == nil and HAS(SRC.trigwhy, 'fall'), tostring(SRC.trigwhy))
  DROP(b)
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('...and the same line with the right slope fires at once, so the stimulus is not the reason',
     SRC.trigfired == 101, tostring(SRC.trigfired))
  DROP(b)
  b = ARM(1.5, nil, dmm.MODE_EDGE)
  CK('a comparator with NO slope is not a source', SRC.trigfired == nil and HAS(SRC.trigwhy, 'slope'),
     tostring(SRC.trigwhy))
  DROP(b)

  -- ==== MODE_OFF ====
  STEP(100, 100, 100, 0.0, 3.3)
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_OFF)
  CK('MODE_OFF means the comparator is not an edge source at all',
     SRC.trigfired == nil and HAS(SRC.trigwhy, 'not an edge source'), tostring(SRC.trigwhy))
  DROP(b)
  b = ARM(nil, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('...and so does a comparator with no level', SRC.trigfired == nil and HAS(SRC.trigwhy, 'level'),
     tostring(SRC.trigwhy))
  DROP(b)

  -- ==== THE OVERRIDE STILL MEANS WHAT IT MEANT ====
  -- Every existing fixture that sets SRC.trigat deliberately keeps its behaviour, and nothing is
  -- preferred silently: SRC.trigsrc names whichever decided, so a test meaning to exercise the
  -- comparator can insist on it.
  SRC.trigat = 60
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('SRC.trigat overrides the comparator, and says so', SRC.trigfired == 60 and
     SRC.trigsrc == 'override', string.format('%s by %s', tostring(SRC.trigfired),
                                              tostring(SRC.trigsrc)))
  DROP(b)
  SRC.trigat_force = 77
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('...and the explicitly named override wins over the legacy one',
     SRC.trigfired == 77 and SRC.trigsrc == 'force',
     string.format('%s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  DROP(b)
  SRC.trigat, SRC.trigat_force = nil, nil
  SRC_TRIGDERIVE(false)
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE)
  CK('with the derivation off, a nil trigat is sample 1 exactly as it always was',
     SRC.trigfired == 1 and SRC.trigsrc == 'default',
     string.format('%s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  DROP(b)
  SRC_TRIGDERIVE(true)

  -- ==== THE SOURCES THIS FILE CANNOT MODEL ====
  -- There is no finger on the front key and no marker on the rear BNC here, so a model waiting on
  -- one of those alone is conceded -- and said to be conceded, which is what keeps a test from
  -- reading it as a comparator that worked.
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_OFF, trigger.EVENT_DISPLAY)
  CK('a model waiting on the front TRIGGER key is conceded, not derived',
     SRC.trigfired == 1 and SRC.trigsrc == 'event',
     string.format('%s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  DROP(b)
  -- A BLENDER IS AN OR, and the comparator is still a stimulus of it: arm_source() rewrites `ev` to
  -- EVENT_BLENDER1 whenever the rear BNC or the key is OR'd in, so testing the event alone answered
  -- NO for exactly the configurations where the comparator still decides.
  pcall(trigger.blender[1].reset)
  trigger.blender[1].orenable = true
  trigger.blender[1].stimulus[1] = trigger.EVENT_ANALOGTRIGGER
  trigger.blender[1].stimulus[3] = trigger.EVENT_DISPLAY
  b = ARM(1.5, dmm.SLOPE_RISING, dmm.MODE_EDGE, trigger.EVENT_BLENDER1)
  CK('a blended arm is still decided by the comparator when nothing else fired',
     SRC.trigfired == 101 and SRC.trigsrc == 'comparator',
     string.format('%s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  DROP(b)
  TRIG.press(1)
  b = ARM(8.0, dmm.SLOPE_RISING, dmm.MODE_EDGE, trigger.EVENT_BLENDER1)
  CK('...and a press OR\'d into it cuts an arm short that the comparator could never satisfy',
     SRC.trigfired == 1 and SRC.trigsrc == 'blender',
     string.format('%s by %s', tostring(SRC.trigfired), tostring(SRC.trigsrc)))
  CK('...read once, like the firmware\'s own auto-resetting detector',
     (TRIG.latch[1] or 0) == 0, tostring(TRIG.latch[1]))
  DROP(b)
  pcall(trigger.blender[1].reset)
  CK('the scan is bounded by the render, so a line that never crosses is not an endless loop',
     SRC.trigscan <= n, string.format('%d samples examined of %d', SRC.trigscan, n))
end)()

-- ============================================================================
print('\nD  THE 1.63 V DEFECT: an armed recording must not inherit a previous capture\'s midpoint')
-- ============================================================================
-- MEASURED on the instrument. A recording reuses the last good capture's measured threshold for its
-- idle watchdog -- the right economy, since that is this wire minutes ago -- and the guard that did
-- so skipped sdec.arm_threshold() entirely, so the COMPARATOR was armed at that midpoint: 1.63 V on
-- a 0-3.29 V line, which is mid-data. The arm level is not a measurement at all; it is idle plus the
-- operator's Arm At.
--
-- THE CONSEQUENCE NEEDS A LINE THE REUSED LEVEL DOES NOT FIT, and that is the honest shape of the
-- defect rather than a contrivance: a reused level belongs to a DIFFERENT capture and nothing
-- guarantees it lies inside this one's swing. Here the previous capture was of a 3.3 V line and this
-- one is of a 1.2 V line that has not started transmitting yet -- an operator who moved the probe, or
-- a different device on the same bench. The reused midpoint is then ABOVE the whole signal, the
-- comparator can never fire, and the recording ends as an expired arm with nothing in it.
;(function()
  local keep = {lvl = sdec.armlevel, wait = sdec.armwait, key = sdec.armkey,
                ext = sdec.trigext, fc = sdec.fc_out, lt = sdec.lvl_thr, ls = sdec.lvl_swing}
  sdec.trigext, sdec.trigext_only, sdec.fc_out = false, false, false
  sdec.armlevel, sdec.armwait, sdec.armkey = 1.0, 4.0, false

  -- A DEVICE THAT STARTS LATE, on a line idling at 1.2 V. The lead is 1000 bit times -- 4167 samples
  -- at the rate the app picks for a recording -- which is longer than sdec.probe_n, so the level
  -- probe really does find the line silent rather than being told that it is.
  local msg, i = {}, nil
  for i = 1, 40 do msg[i] = 32 + math.mod(i * 7, 90) end
  local function latedev()
    SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
      GEN({bytes = msg, baud = 9600, fs = 40000, lead = 1000, hi = 1.2, lo = 0.0, n = 40000})
    SRC.trigat = nil
    SRC.loop, SRC.native_fs = false, nil
  end
  local function begin()
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
    sdec.force_baud, sdec.capmode, sdec.trigmode = 9600, 'med', 'edge'
    sdec.strm_recording, sdec.ck_job, sdec.ck_running, sdec.strm_armed = nil, nil, false, nil
    latedev()
    return sdec.stream_begin()
  end

  -- THE PREVIOUS CAPTURE'S MEASURED LEVELS, which is what makes the reuse engage at all.
  sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = 1.65, 0.3, 3.3
  sdec.strm_lvlreuse = nil
  local bok, bwhy = begin()
  CK('a recording sets up on a line that has not started', bok == true, tostring(bwhy))
  CK('...the probe finds it silent, which is the real precondition for an arm',
     sdec.arm_silent() == true, tostring(sdec.probe_idle))
  CK('...and it reuses the previous capture\'s midpoint for its idle watchdog',
     sdec.strm_lvlreuse == true and NEAR(sdec.thr, 1.65, 0.01),
     string.format('reuse=%s thr=%s', tostring(sdec.strm_lvlreuse), tostring(sdec.thr)))
  CK('...while the ARM level is idle minus Arm At, which is a different number entirely',
     NEAR(sdec.arm_thr, 0.6, 0.01) and sdec.arm_idle == 1 and
     sdec.arm_slope() == sdec.k.SLOPE_FALLING,
     string.format('arm_thr=%s idle=%s slope=%s', tostring(sdec.arm_thr), tostring(sdec.arm_idle),
                   tostring(sdec.arm_slope())))

  TRIG_CLOCK(0)
  local noarm0, got = READS.noarm, nil
  got = sdec.stream_acquire(sdec.strm_nsmp)
  CK('...and that is the level that reaches the comparator, not the midpoint',
     NEAR(dmm.digitize.analogtrigger.edge.level, sdec.arm_thr, 0.001) and
     math.abs(dmm.digitize.analogtrigger.edge.level - 1.65) > 1.0,
     string.format('comparator=%s arm_thr=%s thr=%s',
                   tostring(dmm.digitize.analogtrigger.edge.level), tostring(sdec.arm_thr),
                   tostring(sdec.thr)))
  -- ==== MUTATION PROOF 1 ====
  -- Fails if arm_comparator()'s `sdec.atedge.level = sdec.arm_thr or sdec.thr` in
  -- tsp/serial_core.tsp loses its arm_thr term. With `= sdec.thr` the comparator is armed at 1.65 V,
  -- which is above this line's whole 1.2 V swing, nothing ever crosses it, and the recording ends as
  -- an expired arm having captured none of the message.
  CK('SO THE ARM FIRES ON THE FIRST START BIT, and the recording is not an expired arm',
     SRC.trigsrc == 'comparator' and SRC.trigfired == 4167 and sdec.ck_endwhy ~= 'noarm' and
     READS.noarm == noarm0,
     string.format('fired at %s by %s, endwhy=%s, %s readings', tostring(SRC.trigfired),
                   tostring(SRC.trigsrc), tostring(sdec.ck_endwhy), tostring(got)))
  -- THE NULL THAT MAKES THE ASSERTION ABOVE DISCRIMINATING. Without this a reader cannot tell
  -- whether the midpoint would have failed or whether every level on this line fires.
  dmm.digitize.analogtrigger.edge.level = 1.65
  dmm.digitize.analogtrigger.edge.slope = sdec.k.SLOPE_FALLING
  dmm.digitize.analogtrigger.mode = sdec.k.MODE_EDGE
  local midfire, midwhy = TRIG.fire_at(1)
  CK('...and the midpoint would NOT have fired, which is what makes that a discriminating test',
     midfire == nil and HAS(midwhy, 'nothing crossed 1.6500'), tostring(midwhy))
  -- AND THE RECORD OPENS IN THE IDLE LINE, which is the other half of why the armed shape is worth
  -- having: the pre-trigger reserve holds the samples from before the first start bit.
  local rd, lo = sdec.buf.readings, 0
  local k
  for k = 1, 400 do
    if rd[k] ~= nil and rd[k] > sdec.arm_thr then lo = lo + 1 end
  end
  CK('...opening on quiet line, so no byte of the start is lost', lo >= 300,
     string.format('%d of the first 400 readings above the arm level', lo))

  sdec.lvl_thr, sdec.lvl_swing = keep.lt, keep.ls
  sdec.armlevel, sdec.armwait, sdec.armkey = keep.lvl, keep.wait, keep.key
  sdec.trigext, sdec.fc_out = keep.ext, keep.fc
  sdec.strm_lvlreuse = nil
end)()

-- ============================================================================
print('\nE  TODAY\'S DEFECT: the settle budget has to cover the time the model takes to get there')
-- ============================================================================
-- sdec.arm_settle_s bounds the spin in stream_arm() that waits to SEE STATE_WAITING, and `not saw` is
-- carried out as an arm that never went live -- correctly, since the poll loop cannot tell that from
-- a trigger that fired. So a budget the instrument can miss does not degrade the capture, it INVERTS
-- it: the recording runs free and the operator gets the buffer of silence that pressing Capture on a
-- quiet line is meant to avoid. MEASURED, case F of hw-arm: the identical 8 kB case armed and
-- collected 5 485 bytes on one run and ended as 'quiet' with nothing in it on the next three.
--
-- NO STUB ANYWHERE IN THIS SECTION, and that is the point of modelling the clock. The time the
-- firmware takes to ADMIT the wait is the mock's own measured figure -- flat in the buffer, and taken
-- from the row of TRIG.lag_after that this recording EARNED by probing the line before it armed -- so
-- the budget is tested against the instrument's behaviour rather than against a poll count a fixture
-- invented.
--
-- WHAT THE BUDGET REALLY BOUNDS IS CANDOUR, NOT READINESS. The wait block is live 2 ms after
-- initiate(); the state call does not admit it for another 190. So every one of these looks is spent
-- waiting for the firmware to own up to something that is already true, and a spin that runs out has
-- declared an arm dead that was working the whole time.
--
-- AND THE SHIPPED 0.25 s IS NOT THE MUTATION VALUE ANY MORE, which is a consequence of the
-- measurement rather than of this file: the admission lands at 0.164 to 0.228 s, so a spin bounded at
-- 0.25 s takes its last look at 0.24 s and DOES see the wait. 0.25 was a coin toss -- about ten per
-- cent above the slowest admission the instrument produces -- and a deterministic model cannot
-- reproduce a coin toss as a failure. The margin is asserted instead, below, and the mutation uses a
-- budget under the measured floor.
;(function()
  local keep = {lvl = sdec.armlevel, wait = sdec.armwait, key = sdec.armkey, set = sdec.arm_settle_s}
  sdec.trigext, sdec.trigext_only, sdec.fc_out = false, false, false
  sdec.armlevel, sdec.armwait, sdec.armkey = 1.0, 4.0, false

  local function quiet_line()
    SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
      GEN({bytes = {0x55}, baud = 9600, fs = 40000, hi = 0.02, lo = 0.0})
    SRC.trigat = nil
    SRC.loop, SRC.native_fs = false, nil
  end
  local function begin()
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
    sdec.force_baud, sdec.capmode, sdec.trigmode = 9600, 'med', 'edge'
    sdec.strm_recording, sdec.ck_job, sdec.ck_running, sdec.strm_armed = nil, nil, false, nil
    quiet_line()
    return sdec.stream_begin()
  end

  local bok, bwhy = begin()
  CK('a 32 kB recording sets up on a silent line', bok == true, tostring(bwhy))
  local cap = sdec.buf.capacity
  TRIG_CLOCK(0)
  local d0 = TRIG.delays
  local ok = sdec.stream_arm(sdec.strm_nsmp)
  local tow = TRIG.t_wait - TRIG.t0
  -- THE ADMISSION TIME IS EARNED, NOT DECLARED: stream_begin() probes the line with a free-running
  -- read before it arms, which is the 'read' row of the measured table -- the promptest prior state
  -- there is, and still 0.164 s. The wait itself went live 2 ms in, so the whole of the budget is
  -- spent waiting for the firmware to admit something that was already true.
  CK('...and its wait is live in 2 ms but not ADMITTED for 0.164 s, the row the probe earned',
     TRIG.prior == 'read' and NEAR(tow, 0.002, 1e-9) and NEAR(TRIG.observed_at(), 0.164, 1e-9),
     string.format('%.4f s to live, %.4f s to admitted, prior=%s, %d-reading buffer', tow,
                   TRIG.observed_at(), tostring(TRIG.prior), cap))
  -- ==== MUTATION PROOF 2 ====
  -- Fails if sdec.arm_settle_s in tsp/serial_core.tsp is set below the arrival -- 0.1 s is under the
  -- measured floor of 0.1668 s. The spin then exhausts its budget before the model reaches its wait,
  -- `saw` stays false, and the arm is reported as one that never went live -- so the recording runs
  -- free and captures exactly the silence that arming exists to avoid.
  CK('SO THE ARM IS STILL AN ARM, because the budget covers the time the model really needs',
     ok == true and sdec.strm_armed == true and TRIG.template == 'LoopUntilEvent',
     string.format('armed=%s template=%s, %.4f s needed against a %s s budget',
                   tostring(sdec.strm_armed), tostring(TRIG.template), tow,
                   tostring(sdec.arm_settle_s)))
  -- THE BUDGET IS SPENT IN WALL TIME, NOT IN LOOKS, and the two are only the same while delay() is a
  -- no-op. The spin steps 10 ms at a time, so a 0.164 s admission is seventeen looks -- and a budget
  -- expressed in looks would have passed at any admission time at all.
  CK('...and the spin paid for it in clock, one 10 ms delay at a time',
     NEAR(TRIG.clock, TRIG.t_wait + TRIG.lag(), 0.011) and (TRIG.delays - d0) >= 15,
     string.format('%d delays, clock %.4f s against an admission at %.4f s', TRIG.delays - d0,
                   TRIG.clock, TRIG.t_wait + TRIG.lag()))
  -- ==== WHY 0.25 s WAS A COIN TOSS, AS A NUMBER ====
  -- The spin steps 10 ms, so a bound of B takes its last look at B - 0.01. Against the measured worst
  -- arm -- 0.228 s, after aborting a model that was itself waiting -- the old 0.25 s bound left
  -- 0.012 s, which is ONE look. That is why hw-arm case F armed once and failed the next three, and
  -- it is the thing a budget has to be measured against: not the median arm but the slowest one.
  local worst = TRIG.lag_after.waiting
  CK('the old 0.25 s bound left ONE look of margin over the slowest arm the instrument makes',
     math.floor((0.25 - 0.01 - worst) / 0.01) <= 1 and worst > 0.2,
     string.format('%.4f s worst arm, %.3f s of margin under a 0.25 s bound, %.0f look(s)', worst,
                   0.25 - 0.01 - worst, math.floor((0.25 - 0.01 - worst) / 0.01)))
  -- AN ORDER OF MAGNITUDE IS THE FLOOR ASSERTED, not the shipped 44x: the rule worth gating is that
  -- the budget is measured against the SLOWEST arm with room to spare, and a future value chosen
  -- lower than ten times it is the same mistake 0.25 was. 0.25 is 1.1x and fails this.
  CK('...and the shipped bound clears the slowest arm by an order of magnitude',
     sdec.arm_settle_s / worst >= 10,
     string.format('%s s against a %.4f s worst arm, %.1fx', tostring(sdec.arm_settle_s), worst,
                   sdec.arm_settle_s / worst))

  -- THE BUDGET IS STILL A BOUND, not patience without end: a firmware that never admits the wait has
  -- to be reported as an arm that did not go live, or the generous budget has turned a refusal into a
  -- hang. Twenty seconds of candour lag is past any budget this field should ever hold.
  local kc = TRIG.cost.report_lag
  TRIG.cost.report_lag = 20.0
  begin()
  TRIG_CLOCK(0)
  local ok2 = sdec.stream_arm(sdec.strm_nsmp)
  CK('a wait the firmware never admits is still reported as NOT armed',
     sdec.strm_armed == false, string.format('armed=%s after %.2f s of spin',
                                             tostring(sdec.strm_armed), TRIG.clock))
  CK('...and the spin stopped at the budget rather than waiting the model out',
     NEAR(TRIG.clock, sdec.arm_settle_s, 0.02) and ok2 == true,
     string.format('%.3f s spun against a %s s budget', TRIG.clock, tostring(sdec.arm_settle_s)))
  TRIG.cost.report_lag = kc

  -- AND THE FIELD IS A RECORDING-PATH NUMBER, which is what makes a generous value free:
  -- sdec.arm_settle_s is read only by stream_arm(), and acq_triggered() has no spin at all. Tested
  -- by setting it to a value NO arm could satisfy and then arming a FRAME capture of the same late
  -- device: if the spin were ever wired into acq_triggered, this capture would be refused.
  sdec.arm_settle_s = 0.0001
  local msg, i = {}, nil
  for i = 1, 20 do msg[i] = 32 + math.mod(i * 7, 90) end
  sdec.force_baud, sdec.capmode, sdec.trigmode = nil, 'frame', 'edge'
  sdec.strm_recording, sdec.ck_job, sdec.ck_running = nil, nil, false
  SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
    GEN({bytes = msg, baud = 9600, fs = 100000, lead = 400, n = 12000})
  SRC.trigat = nil
  SRC.loop, SRC.native_fs = false, nil
  TRIG_CLOCK(0)
  local fok, fwhy = sdec.acquire()
  CK('a FRAME capture is unaffected by a settle budget no arm could meet',
     fok == true and TRIG.template == 'LoopUntilEvent' and SRC.trigsrc == 'comparator' and
     SRC.trigfired ~= nil,
     string.format('ok=%s template=%s fired at %s by %s (%s)', tostring(fok),
                   tostring(TRIG.template), tostring(SRC.trigfired), tostring(SRC.trigsrc),
                   tostring(fwhy)))

  sdec.arm_settle_s = keep.set
  sdec.armlevel, sdec.armwait, sdec.armkey = keep.lvl, keep.wait, keep.key
end)()

-- ============================================================================
print('\nF  an arm the signal never satisfies expires, and the mock gets there on its own')
-- ============================================================================
-- THE SAME ENDING, REACHED WITHOUT A FIXTURE. The existing coverage of 'noarm' pins the model's state
-- and the buffer level by hand, because the mock filled the armed buffer inside initiate() and had no
-- way to represent an arm that was still waiting. With the comparator derived and the clock walking,
-- a quiet line produces it by itself: nothing crosses, the model stays in its wait block, and the
-- operator's Arm Wait is what ends the recording.
;(function()
  local keep = {lvl = sdec.armlevel, wait = sdec.armwait, key = sdec.armkey}
  sdec.trigext, sdec.trigext_only, sdec.fc_out = false, false, false
  sdec.armlevel, sdec.armwait, sdec.armkey = 1.0, 4.0, false
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.force_baud, sdec.capmode, sdec.trigmode = 9600, 'sml', 'edge'
  sdec.strm_recording, sdec.ck_job, sdec.ck_running, sdec.strm_armed = nil, nil, false, nil
  SRC.rd, SRC.ts, SRC.nsmp, SRC.trigat =
    GEN({bytes = {0x55}, baud = 9600, fs = 40000, hi = 0.02, lo = 0.0})
  SRC.trigat = nil
  SRC.loop, SRC.native_fs = false, nil
  local bok, bwhy = sdec.stream_begin()
  CK('an 8 kB recording sets up on a line at ground', bok == true, tostring(bwhy))
  local tr0, na0 = READS.triggered, READS.noarm
  TRIG_CLOCK(0)
  local got = sdec.stream_acquire(sdec.strm_nsmp)
  CK('the arm goes live, because the model reaches its wait inside the budget',
     sdec.strm_armed == true, tostring(sdec.strm_armed))
  CK('...and nothing crosses the level it is watching',
     SRC.trigfired == nil and HAS(SRC.trigwhy, 'nothing crossed'), tostring(SRC.trigwhy))
  CK('...so the recording ends as an EXPIRED ARM, not as a full buffer or a quiet device',
     sdec.ck_endwhy == 'noarm',
     string.format('endwhy=%s got=%s', tostring(sdec.ck_endwhy), tostring(got)))
  CK('...counted as an arm, not as a capture',
     READS.noarm == na0 + 1 and READS.triggered == tr0,
     string.format('noarm %d->%d, triggered %d->%d', na0, READS.noarm, tr0, READS.triggered))
  CK('...having waited the operator\'s Arm Wait rather than the recording\'s fill time',
     (sdec.strm_waited or 0) >= sdec.arm_wait_s() - sdec.ck_poll_s,
     string.format('%.2f s waited, Arm Wait %s', sdec.strm_waited or 0, tostring(sdec.arm_wait_s())))
  -- THE NOTE NAMES THE TWO SETTINGS THAT GOVERN IT, and the level the comparator was really watching
  -- -- which on a line idling away from ground is idle MINUS the setting, not the setting.
  local keepthr = sdec.thr
  sdec.thr = 0
  local why = sdec.strm_exit_why(sdec.ck_endwhy, true, nil)
  sdec.thr = keepthr
  CK('...and the expiry names Arm Wait, Arm At and the level that was armed',
     HAS(why, 'raise Arm Wait or lower Arm At') and HAS(why, 'crossed') and
     not HAS(why, 'crossed 0.00 V'), why)
  sdec.armlevel, sdec.armwait, sdec.armkey = keep.lvl, keep.wait, keep.key
end)()

-- The machine and the derivation are left OFF, so a suite that dofile's this one inherits the
-- defaults rather than this file's choices.
TRIG_WALK(false)
SRC_TRIGDERIVE(false)
print(string.format('\n%d passed, %d failed', PASS, FAIL))
if FAIL > 0 then os.exit(1) end

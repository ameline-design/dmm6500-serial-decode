-- mock_bench.lua -- the instrument-side APIs bench/ needs, so the whole soak runs on the Mac.
--
-- WHY THIS IS WORTH BUILDING RATHER THAN TESTING ON THE BOX. bench/bench_run.tsp is a loop that will
-- run unattended for eight days with nobody able to power cycle anything. Every branch in it that has
-- never executed is a branch that will first execute while nobody is watching: the generator failing
-- mid-lap, the plan file ending, the key filling, the write failing twice. Those are exactly the paths
-- an instrument session will not reach on purpose, and they are the ones that decide whether a week
-- produces data or a dead script.
--
-- WHAT IS MOCKED, and how faithfully:
--   tspnet    a state machine standing in for the generator, answering the same four queries and
--             REFUSING to answer when told to be dead, so the give-up path is reachable
--   file      NOT MOCKED HERE. tools/mock_display.lua already has one, it is the tested one, and it
--             models things a fresh mock would not: no key posts event 2205, a missing parent fails
--             every mode, MD.failwrite() fills the key mid-run, and -- the one that changed this
--             design -- the firmware hands out ONE write handle, so two files cannot be open at once
--   eventlog  a counter, because the app's hardest rule is that it never puts a message on the panel
--             and the soak's job is to police that
--
-- WHAT IS NOT MOCKED: the analog path. MOCK_SDG_ARB below hands the vector's own codewords to
-- gen_serial's SRC, so the app digitises the real rendered waveform at the real requested rate -- the
-- same arrangement tools/sweep_plan.lua uses. The DMM front end is not modelled here; this file exists
-- to test the RUNNER, and sweep_plan.lua is where signal fidelity is argued about.

MOCKB = {sdg = nil, events = 0}

-- ---------------------------------------------------------------------------
-- timer
-- ---------------------------------------------------------------------------
-- The instrument's stopwatch, which bench_uart.py's bench_point uses to time the acquire and the
-- decode. Only needed because test_bench_engine.lua runs that function side by side with brun.point;
-- nothing in bench/ reads it, and the numbers it returns are host time, not instrument time.
timer = {}
MOCKB.t0 = 0
function timer.cleartime() MOCKB.t0 = os.clock() end
function timer.gettime() return os.clock() - MOCKB.t0 end

-- ---------------------------------------------------------------------------
-- eventlog
-- ---------------------------------------------------------------------------
eventlog = {}
function eventlog.clear() MOCKB.events = 0 end
function eventlog.getcount() return MOCKB.events end
function eventlog.next() return nil end

-- ---------------------------------------------------------------------------
-- The generator
-- ---------------------------------------------------------------------------
-- One table per connection id. `dead` makes every query time out, which is the only way to reach
-- bench_run's give-up path; `wedged` accepts writes and never answers, which is the generator's real
-- observed failure -- connections accepted, nothing ever replied, output still playing correctly.
function MOCKB_SDG(opts)
  opts = opts or {}
  MOCKB.sdg = {arb = nil, amp = nil, ofst = nil, srate = nil, mode = nil, out = false,
               dead = opts.dead or false, wedged = opts.wedged or false,
               nconnect = 0, ncmd = 0, refuse_arb = opts.refuse_arb or nil,
               dds_after_arb = opts.dds_after_arb or false, pending = nil, log = {}, nlog = 0}
  return MOCKB.sdg
end

tspnet = {TERM_LF = 1, TERM_CR = 2, TERM_CRLF = 4, timeout = 20}

function tspnet.connect(ip, port, init)
  local g = MOCKB.sdg
  if g == nil then error('MOCKB_SDG() was not called, so there is no generator to connect to') end
  if g.dead then error('connection refused') end
  g.nconnect = g.nconnect + 1
  return 1
end

function tspnet.disconnect(id) end
function tspnet.reset() if MOCKB.sdg ~= nil then MOCKB.sdg.pending = nil end end
function tspnet.termination(id, t) end

function tspnet.write(id, s)
  local g = MOCKB.sdg
  if g == nil or g.dead then error('write to a dead generator') end
  g.ncmd = g.ncmd + 1
  g.nlog = g.nlog + 1
  g.log[g.nlog] = s
  local cmd = string.gsub(s, '[\r\n]', '')
  -- THE ONE COMMAND THAT MUST NEVER ARRIVE. If bench/sdg_net.tsp's interlock ever regresses, this is
  -- where the test finds out, rather than the generator finding out.
  if string.find(string.upper(cmd), 'WVDT', 1, true) ~= nil then
    error('the mock generator was sent WVDT, which is the command that wedges the real one')
  end
  if g.wedged then return end
  MOCKB_SDG_DO(g, cmd)
end

function tspnet.readavailable(id)
  local g = MOCKB.sdg
  if g == nil or g.dead or g.wedged then return 0 end
  if g.pending == nil then return 0 end
  return string.len(g.pending)
end

function tspnet.read(id)
  local g = MOCKB.sdg
  if g == nil or g.pending == nil then error('read with nothing pending') end
  local r = g.pending
  g.pending = nil
  return r
end

-- The SCPI subset, and only that subset: a mock that answers commands the real generator does not
-- would let a caller depend on one.
function MOCKB_SDG_DO(g, cmd)
  local up = string.upper(cmd)
  if up == '*IDN?' then
    g.pending = 'Siglent Technologies,SDG2122X,SDG2XCAQ5R2571,2.01.01.39R7'
    return
  end
  local a = string.find(cmd, 'ARWV NAME,"U%-disk0/([^"]+)"')
  if a ~= nil then
    local name = string.match(cmd, 'ARWV NAME,"U%-disk0/([^"]+)"')
    name = string.gsub(name or '', '%.bin$', '')
    -- refuse_arb IMITATES THE REAL FAILURE, which is not an error reply: a file the generator cannot
    -- read leaves the PREVIOUS waveform selected and says nothing. That is why bench/sdg_net.tsp
    -- compares the ARWV? reply instead of trusting the write.
    if g.refuse_arb ~= nil and g.refuse_arb == name then return end
    g.arb = name
    if g.dds_after_arb then g.mode = 'DDS' end
    MOCKB_SDG_ARB(g)
    return
  end
  if up == 'C1:ARWV?' then
    g.pending = 'C1:ARWV INDEX,0,NAME,' .. tostring(g.arb or '')
    return
  end
  if string.find(up, 'SRATE MODE,TARB', 1, true) ~= nil then g.mode = 'TARB'; return end
  local v = string.match(cmd, 'SRATE VALUE,([%-%d%.eE+]+)')
  if v ~= nil then g.srate = tonumber(v); MOCKB_SDG_ARB(g); return end
  if up == 'C1:SRATE?' then
    g.pending = string.format('C1:SRATE MODE,%s,VALUE,%s,INTER,LINE',
                              tostring(g.mode or 'DDS'), tostring(g.srate or 0))
    return
  end
  local am = string.match(cmd, 'BSWV AMP,([%-%d%.eE+]+)')
  local om = string.match(cmd, 'OFST,([%-%d%.eE+]+)')
  if am ~= nil then
    g.amp = tonumber(am)
    if om ~= nil then g.ofst = tonumber(om) end
    MOCKB_SDG_ARB(g)
    return
  end
  if string.find(up, 'OUTP ON', 1, true) ~= nil then g.out = true; return end
  if string.find(up, 'OUTP OFF', 1, true) ~= nil then g.out = false; return end
end

-- ---------------------------------------------------------------------------
-- The stimulus itself
-- ---------------------------------------------------------------------------
-- HANDS THE VECTOR'S OWN CODEWORDS TO gen_serial's SRC, at the amplitude and offset the generator was
-- told, so the app then digitises the real rendered waveform at whatever rate it asks for. Without
-- this the runner could be tested only against silence, and every cell would fail for a reason that
-- says nothing about the runner.
MOCKB.arbcache = {}

function MOCKB_SDG_ARB(g)
  if g.arb == nil or g.amp == nil or g.srate == nil then return end
  local c = MOCKB.arbcache[g.arb]
  if c == nil then
    local cw, n = GEN_READ('out/vectors/' .. g.arb .. '.bin')
    if cw == nil then return end
    c = {cw = cw, n = n}
    MOCKB.arbcache[g.arb] = c
  end
  -- fsv is AMP/2: the file's +32767 is +AMP/2, the same convention sweep_plan.lua's wire() uses.
  local fsv = g.amp / 2
  local volts, i = {}, nil
  for i = 1, c.n do volts[i] = GEN_VOLTS(c.cw[i], fsv, g.ofst or 0) end
  SRC.rd, SRC.nsmp, SRC.native_fs, SRC.loop = volts, c.n, g.srate, true
  SRC.ts = nil
  local ts = {}
  for i = 1, c.n do ts[i] = (i - 1) / g.srate end
  SRC.ts = ts
end

-- sdg_net.tsp -- the DMM6500 driving the SDG2122X directly, over tspnet.
--
-- WHY THIS EXISTS. Every bench run so far has had a Mac in the critical path: the host sets the
-- generator, presses the app's buttons and judges the result. That caps a soak at as long as someone
-- is watching. With the DMM talking to the generator itself, a run continues while nobody is
-- connected -- which is the difference between four laps a night and a week of them.
--
-- NOT IN tsp/. This is not part of the app and must never ship inside it: package_tspa.py's MODULES
-- list is explicit, and a bench harness in the shipped .tspa would be dead weight on an instrument
-- that never soaks. It is loaded alongside the app for a soak and not otherwise.
--
-- THE ONE COMMAND THIS MODULE CANNOT SEND. C1:WVDT uploads waveform data, and repeated uploads over
-- 65536 bytes have twice stopped this generator answering on BOTH SCPI ports -- connections accepted,
-- nothing ever replied, including *IDN?. It goes on playing correctly, so the failure is invisible
-- from the signal side, and recovery is a power cycle on an instrument with no smart plug. During an
-- unattended week there is nobody to perform one, so the whole run would be lost from that moment.
-- bsdg.cmd() therefore REFUSES any string containing WVDT rather than trusting every future caller
-- not to write one. Waveforms are played off the generator's own USB key with ARWV, which needs no
-- transfer at all (programming guide 3.9.1).
--
-- PORT 5025, NEVER 5024. The LAN has also died twice with ZERO bytes uploaded, and probing 5024 is
-- the remaining suspect for that -- see SDG_SHUTDOWN_SUSPECTED_HAZARD in tools/instruments.py.

bsdg = bsdg or {}

bsdg.ip      = bsdg.ip or '10.0.1.79'
bsdg.port    = bsdg.port or 5025
bsdg.id      = nil                 -- tspnet connection id, nil when closed
bsdg.why     = nil                 -- why the last call failed, for the status file
bsdg.nfail   = 0                   -- consecutive failures, so a caller can give up deliberately
bsdg.ncmd    = 0
bsdg.timeout = bsdg.timeout or 5   -- seconds; the tspnet default of 20 is far too long to wait
                                   -- 1677 times a lap when the generator has stopped answering

-- Vpp CEILING. The vectors are built for a 20 Vpp part into high-Z; a value past that is a plan
-- error rather than a stimulus, and clipping would be measured as a decode failure.
bsdg.maxvpp = bsdg.maxvpp or 20.0
-- TrueArb's rate limits, from the datasheet via tools/instruments.py.
bsdg.minsrate = bsdg.minsrate or 1e-6
bsdg.maxsrate = bsdg.maxsrate or 75e6

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------
-- OPEN IS IDEMPOTENT and never raises: a soak that dies because the generator was slow to answer is
-- worse than one that records the miss and tries again at the next cell.
function bsdg.open()
  if bsdg.id ~= nil then return true end
  local ok, err = pcall(function()
    tspnet.timeout = bsdg.timeout
    -- AN EMPTY initString, WHICH IS NOT THE SAME AS NONE. The manual's non-TSP procedure gives
    -- tspnet.connect(ip, port, initString) and the argument is not optional in practice: measured on
    -- this instrument, both tspnet.connect(ip, port) and tspnet.connect(ip, port, nil) return NIL
    -- WITHOUT RAISING, while tspnet.connect(ip, port, '') returns a handle. A silent nil is the worst
    -- shape that failure could take -- it cost a full 86-cell run that parked itself with
    -- 'connect failed: nil' after 20 cells, which is the give-up path working correctly on a bug.
    --
    -- EMPTY RATHER THAN THE MANUAL'S EXAMPLE, which sends *rst: on this generator that would drop the
    -- output and the loaded waveform mid-soak. There is nothing this side needs to say on connect.
    bsdg.id = tspnet.connect(bsdg.ip, bsdg.port, '')
    -- PER CONNECTION, not once: the manual states the termination has to be set after every
    -- connect. Siglent replies are CRLF-terminated.
    tspnet.termination(bsdg.id, tspnet.TERM_CRLF)
  end)
  if not ok or bsdg.id == nil then
    bsdg.id = nil
    bsdg.why = 'connect failed: ' .. tostring(err)
    bsdg.nfail = bsdg.nfail + 1
    return false, bsdg.why
  end
  bsdg.why = nil
  return true
end

function bsdg.close()
  if bsdg.id == nil then return end
  pcall(function() tspnet.disconnect(bsdg.id) end)
  bsdg.id = nil
end

-- EVERY SESSION, not just ours. tspnet sessions survive a script ending, and a stale one holds the
-- generator's single client slot -- so the next run cannot connect and the failure looks like a dead
-- generator. Called at both ends of a run.
function bsdg.reset()
  bsdg.id = nil
  pcall(function() tspnet.reset() end)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
-- The interlock described at the top of this file, applied to every write.
function bsdg.forbidden(s)
  if s == nil then return 'nil command' end
  local up = string.upper(s)
  if string.find(up, 'WVDT', 1, true) ~= nil then
    return 'WVDT is refused: a waveform upload can wedge this generator\'s LAN service, and '
           .. 'recovery is a power cycle by hand. Play the file off the key with ARWV instead.'
  end
  -- *RST would drop the output and the selected waveform, which mid-soak reads as a signal fault.
  if string.find(up, '*RST', 1, true) ~= nil then
    return '*RST is refused: it would clear the loaded waveform and the output state mid-run.'
  end
  return nil
end

-- Write one command. Returns true, or false and a reason. Never raises.
function bsdg.cmd(s)
  local bad = bsdg.forbidden(s)
  if bad ~= nil then bsdg.why = bad; return false, bad end
  if not bsdg.open() then return false, bsdg.why end
  local ok, err = pcall(function() tspnet.write(bsdg.id, s .. '\n') end)
  if not ok then
    -- A WRITE THAT FAILED MEANS THE SESSION IS SUSPECT, so it is dropped rather than reused. The
    -- next call reconnects, which is the only recovery available from this side.
    bsdg.close()
    bsdg.why = 'write failed: ' .. tostring(err)
    bsdg.nfail = bsdg.nfail + 1
    return false, bsdg.why
  end
  bsdg.ncmd = bsdg.ncmd + 1
  bsdg.nfail = 0
  return true
end

-- Write a query and return the reply, or nil and a reason.
--
-- POLLED, NOT BLOCKED. tspnet.read() suspends until the reply arrives or the timeout elapses, and a
-- generator that has stopped answering would then cost bsdg.timeout seconds per query for the rest of
-- the week. readavailable() lets this give up on its own terms and, more importantly, lets the caller
-- distinguish "no reply" from "wrong reply" -- which for TrueArb is the whole point: a timeout is not
-- a wrong answer and must be retried, while a reply that arrives and says DDS is a real fault.
function bsdg.ask(s)
  local bad = bsdg.forbidden(s)
  if bad ~= nil then bsdg.why = bad; return nil, bad end
  if not bsdg.cmd(s) then return nil, bsdg.why end
  local waited, step = 0, 0.05
  while waited < bsdg.timeout do
    local avail = 0
    local ok = pcall(function() avail = tspnet.readavailable(bsdg.id) or 0 end)
    if not ok then
      bsdg.close()
      bsdg.why = 'readavailable failed on ' .. s
      bsdg.nfail = bsdg.nfail + 1
      return nil, bsdg.why
    end
    if avail > 0 then
      local rep = nil
      local rok = pcall(function() rep = tspnet.read(bsdg.id) end)
      if not rok or rep == nil then
        bsdg.close()
        bsdg.why = 'read failed on ' .. s
        bsdg.nfail = bsdg.nfail + 1
        return nil, bsdg.why
      end
      bsdg.nfail = 0
      return rep
    end
    delay(step)
    waited = waited + step
  end
  bsdg.why = 'no reply to ' .. s .. ' within ' .. tostring(bsdg.timeout) .. ' s'
  bsdg.nfail = bsdg.nfail + 1
  return nil, bsdg.why
end

-- Does the generator answer at all? Everything else is meaningless if this fails, so a caller checks
-- it once per lap rather than interpreting a thousand downstream failures.
function bsdg.alive()
  local r = bsdg.ask('*IDN?')
  if r == nil then return false, bsdg.why end
  if string.find(string.upper(r), 'SDG', 1, true) == nil then
    return false, 'IDN does not look like an SDG: ' .. tostring(r)
  end
  return true, r
end

function bsdg.output(on)
  if on then return bsdg.cmd('C1:OUTP ON,LOAD,HZ') end
  return bsdg.cmd('C1:OUTP OFF,LOAD,HZ')
end

-- ---------------------------------------------------------------------------
-- Selecting a vector
-- ---------------------------------------------------------------------------
-- THE ORDER IS THE MEASURED ONE, and tools/siglent.py's load_arb_file records why: ARWV first, then
-- BSWV, then SRATE MODE,TARB LAST and verified. Neither manual says whether ARWV or BSWV resets the
-- sample-rate mode, so setting TrueArb first risks it being silently undone -- and a silent fall back
-- to DDS resamples the stored points, corrupting the sub-sample edge timing this project exists to
-- measure, with nothing on the panel to say so.
--
-- ARWV? IS THE AUTHORITATIVE CHECK that the file was readable, because a file the generator cannot
-- open leaves the PREVIOUS waveform selected -- so a reply naming the old vector is the failure
-- signature, and it is indistinguishable from success unless the reply is actually compared.
-- `name` IS THE GENERATOR'S STORED WAVEFORM NAME, e.g. SER_Fox_8N1_x10, exactly the string
-- tools/siglent.py's select_arb sends -- not a local vector id and not a path. A name with a slash in
-- it is a file on the key (U-disk0/v94.bin) and is quoted; a bare stored name is not, which is how the
-- host sends it. Getting this wrong is silent: ARWV NAME with an unknown name does nothing and the
-- previous waveform keeps playing, which is why the reply is compared below.
function bsdg.select(name, amp, ofst, srate)
  if name == nil or name == '' then return false, 'no waveform name' end
  if amp == nil or amp <= 0 or amp > bsdg.maxvpp then
    return false, string.format('amplitude %s Vpp is outside 0..%.1f', tostring(amp), bsdg.maxvpp)
  end
  if srate == nil or srate < bsdg.minsrate or srate > bsdg.maxsrate then
    return false, string.format('sample rate %s is outside %g..%g', tostring(srate),
                                bsdg.minsrate, bsdg.maxsrate)
  end
  local sel = name
  if string.find(name, '/', 1, true) ~= nil then sel = '"' .. name .. '"' end
  if not bsdg.cmd('C1:ARWV NAME,' .. sel) then return false, bsdg.why end
  -- Compared, not assumed. A file on the key answers without its .bin, so the comparison is against
  -- the name with any path and extension stripped.
  local want = string.gsub(name, '^.*/', '')
  want = string.gsub(want, '%.bin$', '')
  -- THREE TRIES FOR THE REPLY, HALF A SECOND APART, for the same measured reason bsdg.truearb has them:
  -- selecting a waveform makes this generator briefly stop answering, and a single timeout is not
  -- evidence that the selection failed. It is evidence about the query. MEASURED: 15 of 86 cells in one
  -- lap were thrown away on 'no reply to C1:ARWV? within 5 s' from a generator that was working -- 17 %
  -- of a run, recorded as stimulus failures, on an instrument nobody could power cycle.
  --
  -- ONLY A MISSING REPLY IS RETRIED. A reply that arrives naming the WRONG waveform is a different fact
  -- and fails immediately: the name was not accepted, the previous waveform is still playing, and waiting
  -- longer cannot change that.
  local r, tries = nil, nil
  for tries = 1, 3 do
    r = bsdg.ask('C1:ARWV?')
    if r ~= nil then break end
    delay(0.5)
  end
  if r == nil then return false, bsdg.why end
  if string.find(string.upper(r), string.upper(want), 1, true) == nil then
    return false, string.format('ARWV? still names %s after selecting %s -- the generator does not '
                                .. 'have that waveform', tostring(r), name)
  end
  if not bsdg.cmd(string.format('C1:BSWV AMP,%.4f,OFST,%.4f', amp, ofst or 0)) then
    return false, bsdg.why
  end
  if not bsdg.cmd('C1:SRATE MODE,TARB') then return false, bsdg.why end
  if not bsdg.cmd(string.format('C1:SRATE VALUE,%.6f', srate)) then return false, bsdg.why end
  local ok, why = bsdg.truearb()
  if not ok then return false, why end
  return bsdg.output(true)
end

-- THREE TRIES, HALF A SECOND APART, and the reason is measured: after a large upload this generator
-- stops answering queries for a moment, and treating that first timeout as "not in TrueArb" aborted a
-- sweep over a channel that was configured correctly -- a false alarm from the check that exists to
-- prevent silent misconfiguration, which is how a check loses its authority. A reply that ARRIVES and
-- says the wrong thing still fails immediately, because that is the real fault being guarded against.
function bsdg.truearb()
  local i, r
  for i = 1, 3 do
    r = bsdg.ask('C1:SRATE?')
    if r ~= nil then
      if string.find(string.upper(r), 'TARB', 1, true) ~= nil then return true end
      return false, 'C1 is not in TrueArb: ' .. tostring(r) .. ' -- DDS would resample the points '
                    .. 'and corrupt edge timing silently'
    end
    delay(0.5)
  end
  return false, 'C1:SRATE? did not answer in 3 tries, so TrueArb is unconfirmed'
end

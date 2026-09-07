-- sdg_net.tsp -- the DMM6500 driving the SDG2122X directly, over tspnet.
--
-- WHY THIS EXISTS. With the instrument selecting its own stimulus, no host sits in the critical path
-- and a run continues while nobody is connected. That is what makes a multi-day soak possible.
--
-- NOT IN tsp/. This is not part of the app and must never ship inside it: package_tspa.py's MODULES
-- list is explicit. It is loaded alongside the app for a soak and not otherwise.
--
-- THE ONE COMMAND THIS MODULE CANNOT SEND. C1:WVDT uploads waveform data, and repeated uploads over
-- 65536 bytes stop this generator answering on BOTH SCPI ports -- connections accepted, nothing ever
-- replied to, including *IDN?. It goes on playing correctly, so the failure is invisible from the
-- signal side, and recovery is a power cycle by hand. bsdg.cmd() therefore REFUSES any string
-- containing WVDT rather than trusting every future caller not to write one -- and nothing here needs
-- it: tools/upload_vectors.py has already put every waveform in the generator's internal flash, so a
-- soak only ever SELECTS one by name with ARWV.
--
-- PORT 5025, NEVER 5024. The LAN has also died with ZERO bytes uploaded, and probing 5024 is the
-- remaining suspect -- see SDG_SHUTDOWN_SUSPECTED_HAZARD in tools/instruments.py.

bsdg = bsdg or {}

bsdg.ip      = bsdg.ip or '10.0.1.79'
bsdg.port    = bsdg.port or 5025
bsdg.id      = nil                 -- tspnet connection id, nil when closed
bsdg.why     = nil                 -- why the last call failed, for the status file
bsdg.nfail   = 0                   -- consecutive failures, so a caller can give up deliberately
bsdg.ncmd    = 0
bsdg.timeout = bsdg.timeout or 5   -- seconds; the tspnet default of 20 is far too long to spend on
                                   -- every query of a cell whose generator has gone quiet

-- Vpp CEILING. The vectors are built for a 20 Vpp part into high-Z; a value past that is a plan
-- error rather than a stimulus, and clipping would be measured as a decode failure.
bsdg.maxvpp = bsdg.maxvpp or 20.0
-- TrueArb's rate limits, from the datasheet via tools/instruments.py.
bsdg.minsrate = bsdg.minsrate or 1e-6
-- 40 MSa/s, WHICH IS THE FAMILY'S FLOOR AND NOT THIS UNIT'S CEILING. The SDG2122X here does 75e6, but
-- the cheapest SDG2000X does 40e6 and the highest rate any plan cell draws is 25e6. Matches
-- tools/instruments.py's SDG_MAX_SRATE, so the instrument refuses exactly what the host refuses.
bsdg.maxsrate = bsdg.maxsrate or 40e6

-- HOW MANY TIMES THE SWITCH VERIFY ASKS. Selecting a waveform makes this generator briefly stop
-- answering, so one timeout is evidence about the query rather than about the selection. Asking again
-- covers that. It does NOT cure a reply naming the PREVIOUS waveform: only re-sending the selection
-- does, which is brun.selretry's job. Only the 39 cells a lap where the vector changes need either.
-- arwvwait is seconds between asks.
bsdg.arwvtries = bsdg.arwvtries or 4
bsdg.arwvwait = bsdg.arwvwait or 0.4

-- WHAT THE GENERATOR IS ALREADY PLAYING, so a cell that asks for the same thing can skip the asking.
-- A lap sweeps 43 rates across one waveform before moving to the next, so 97.7 % of cells re-select a
-- waveform that is already selected -- and re-selecting is not free in either direction: the ARWV write
-- is what makes this generator briefly stop answering, and the ARWV? that verifies it is then blocking
-- on a stall the write itself caused. Skipping both when the name is unchanged removes a self-inflicted
-- round trip from almost every cell of every lap.
--
-- CONFIRMED, NOT COMMANDED. bsdg.cur is set only after ARWV? has named the waveform back, so the cache
-- can never assert a switch that did not land -- which is the failure the verify exists to catch, and
-- one that would silently mis-attribute every cell after it to the wrong stimulus. Every failure path
-- in select() clears it, as do close() and reset(), because a reconnected session knows nothing.
bsdg.cur     = nil     -- waveform name last CONFIRMED by ARWV?; nil means unknown
bsdg.curamp  = nil     -- the BSWV/SRATE values last written and not since disturbed
bsdg.curofst = nil
bsdg.cursrate = nil
bsdg.nskip   = 0       -- consecutive selects that skipped the ARWV verify
bsdg.nsame   = 0       -- selects that skipped the conversation entirely, for the run's own accounting

-- A CEILING ON HOW LONG A STALE CACHE COULD GO UNNOTICED. Nothing in this module can change the
-- selected waveform behind the cache, but the generator is a third party: a front-panel press or a
-- firmware quirk could, and then every later cell would be recorded against a waveform it never played.
-- One forced verify per this many skips bounds the damage at a known number of cells while keeping
-- 49 of every 50 savings, which is a better trade than trusting the cache indefinitely.
--
-- ZERO DISABLES BOTH SKIPS AND RESTORES THE OLD CONVERSATION EXACTLY -- measured in the mock, 602 SCPI
-- messages for 86 cells either way. That makes this the A/B knob for the saving itself: two laps of one
-- plan, `bsdg.arwvevery = 0` against the default, and the wall-time difference is what the skip is
-- worth. The traffic reduction is measurable on the host; the TIME it buys is not, because the cost is
-- the generator's response latency and only the generator can be asked. It is also the runtime revert
-- if anything about the cache misbehaves on the bench -- one assignment over the socket, no reload.
bsdg.arwvevery = bsdg.arwvevery or 50

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------
-- OPEN IS IDEMPOTENT and never raises: a soak that dies because the generator was slow to answer is
-- worse than one that records the miss and tries again at the next cell.
function bsdg.open()
  if bsdg.id ~= nil then return true end
  local ok, err = pcall(function()
    tspnet.timeout = bsdg.timeout
    -- AN EMPTY initString, WHICH IS NOT THE SAME AS NONE. Measured on this instrument: both
    -- tspnet.connect(ip, port) and tspnet.connect(ip, port, nil) return NIL WITHOUT RAISING, while
    -- tspnet.connect(ip, port, '') returns a handle. A silent nil is the worst shape that failure
    -- could take, because every later call fails against a nil id.
    --
    -- EMPTY RATHER THAN THE MANUAL'S EXAMPLE, which sends *rst: that would drop the output and the
    -- loaded waveform mid-soak. There is nothing this side needs to say on connect.
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

-- FORGET WHAT THE GENERATOR IS PLAYING. Called wherever the answer stops being knowable: a dropped
-- session, a reset, and every failure inside select(). Cheap, and the only safe default -- a cache that
-- survives a reconnect would let the next cell skip the one verify that could have caught a generator
-- that came back playing something else.
function bsdg.forget()
  bsdg.cur, bsdg.curamp, bsdg.curofst, bsdg.cursrate = nil, nil, nil, nil
  bsdg.nskip = 0
end

function bsdg.close()
  if bsdg.id == nil then return end
  pcall(function() tspnet.disconnect(bsdg.id) end)
  bsdg.id = nil
  bsdg.forget()
end

-- EVERY SESSION, not just ours. tspnet sessions survive a script ending, and a stale one holds the
-- generator's single client slot -- so the next run cannot connect and the failure looks like a dead
-- generator. Called at both ends of a run.
function bsdg.reset()
  bsdg.id = nil
  bsdg.forget()
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
           .. 'recovery is a power cycle by hand. Every waveform is already in internal flash -- '
           .. 'select it by name with ARWV. Uploading is tools/upload_vectors.py\'s job, not a run\'s.'
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
-- WHAT THE GENERATOR SAYS IT IS DOING, as one compact line for a record. -> string
--
-- FOR A CELL THAT ALREADY FAILED, and only for one. 24 % of a diagnostic lap came back 'line is idle (no
-- transitions)' -- deterministically on particular (vector, rate) pairs, at every amplitude from 1.4 to
-- 20 Vpp -- and nothing in the record could say whether the generator was driving the wrong waveform,
-- the wrong amplitude, the wrong sample rate, or nothing at all. bench_matrix.py has always read BSWV
-- back and failed the point when it did not match; the soak path never did, which is the same gap that
-- let a clamped offset be measured as a decoder result for a hundred laps.
--
-- FOUR QUERIES IS FOUR ROUND TRIPS, which is why this is not on the healthy path. A cell that produced no
-- stimulus has already spent its time; spending four more round trips to learn WHY is the cheapest
-- diagnostic on this bench. On a lap where nothing fails it costs nothing at all.
-- READ AND THROW AWAY ANYTHING STILL BUFFERED. -> reads discarded
--
-- WHY IT IS NEEDED, AND ONLY BY snapshot(). bsdg.ask() returns after ONE tspnet.read as soon as any
-- bytes are available, so a reply longer than a chunk is TRUNCATED and its tail stays in the socket for
-- the next reader. Four queries in a row therefore desynchronise: measured on the bench, a snapshot came
-- back with `srate=0S` and the SRATE reply sitting in the `outp=` field, every value plausible and every
-- label wrong. The soak's own two queries survive this because they are substring tests on content that
-- arrives in the first chunk -- so ask() is deliberately left alone, and the draining is done here.
function bsdg.drain()
  if bsdg.id == nil then return 0 end
  local n, guard = 0, 0
  -- BOUNDED. A generator streaming without end would otherwise hold the interpreter for ever, and this
  -- runs inside a soak that has to survive eight days unattended.
  while guard < 40 do
    guard = guard + 1
    local avail = 0
    if not pcall(function() avail = tspnet.readavailable(bsdg.id) or 0 end) then return n end
    if avail <= 0 then return n end
    if not pcall(function() tspnet.read(bsdg.id) end) then return n end
    n = n + 1
  end
  return n
end

-- IT MUST NOT DISTURB bsdg.nfail, AND THAT IS NOT TIDINESS. nfail is the wedge detector:
-- bench_run.tsp's select retry loop breaks the moment it is non-zero, on the reasoning that retrying a
-- wedged generator costs a minute a cell and cannot help. A query with no reply raises it. So four
-- queries charged to a stimulus-free cell left nfail at 1, and the NEXT cell's select got one try
-- instead of five -- turning a recoverable late ARWV switch into a hard failure and printing GENERATOR
-- SILENT within the first lap of the very run this diagnostic was added for. A read that mutates shared
-- failure state is not a read. Saved and restored around the whole snapshot.
function bsdg.snapshot()
  local out, k = {}, nil
  local keep, keepwhy = bsdg.nfail, bsdg.why
  -- NOT ASKED OF A GENERATOR THAT IS ALREADY NOT ANSWERING. Four queries at bsdg.timeout each is 20 s,
  -- and the answer would be four nils -- which is what nfail already said. The cells worth asking about
  -- are the ones where the generator IS talking and the capture still came back empty.
  if keep > 0 then return 'skipped: nfail=' .. tostring(keep) end
  -- A SHORT TIMEOUT FOR THE WHOLE SNAPSHOT, restored below. At the standard bsdg.timeout of 5 s four
  -- unanswered queries would cost 20 s on a cell that has already failed, and on a plan built out of
  -- failing cells that is most of the lap. One second is ample for a generator that is answering at all,
  -- and a query this misses is recorded as nil -- which is itself the finding.
  local keept = bsdg.timeout
  bsdg.timeout = 1
  local q = {{'arwv', 'C1:ARWV?'}, {'bswv', 'C1:BSWV?'}, {'srate', 'C1:SRATE?'}, {'outp', 'C1:OUTP?'}}
  for k = 1, table.getn(q) do
    -- DRAINED BEFORE EACH QUERY, so this label carries the first chunk of ITS OWN reply rather than the
    -- previous one's tail. A long reply is still truncated -- ARWV's name, BSWV's AMP and OFST and
    -- SRATE's MODE all arrive in the first chunk, which is what this is for -- but nothing is misattributed.
    bsdg.drain()
    local r = bsdg.ask(q[k][2])
    -- THE REPLY IS FLATTENED, not parsed. A parser here would have to know every field of four different
    -- replies and would fail silently on a firmware that reorders one; the host has judge code and can
    -- afford to parse. Commas would break the record's own CSV, so they become semicolons.
    if r == nil then
      out[k] = q[k][1] .. '=nil'
    else
      r = string.gsub(r, '[\r\n]', '')
      r = string.gsub(r, ',', ';')
      out[k] = q[k][1] .. '=' .. r
    end
  end
  -- RESTORED WHATEVER HAPPENED ABOVE, including on the path where every query timed out: the caller's
  -- view of how healthy the generator is must be the one it had before it asked a diagnostic question.
  bsdg.nfail, bsdg.why, bsdg.timeout = keep, keepwhy, keept
  return table.concat(out, ' ')
end

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
-- THE ORDER IS THE MEASURED ONE, matching tools/siglent.py's load_arb_file: ARWV first, then BSWV, then
-- SRATE MODE,TARB last and verified. Neither manual says whether ARWV or BSWV resets the sample-rate
-- mode, so setting TrueArb first risks it being silently undone -- and a fall back to DDS resamples the
-- stored points, corrupting the sub-sample edge timing this project exists to measure, with nothing on
-- the panel to say so.
--
-- `name` IS THE GENERATOR'S STORED WAVEFORM NAME, e.g. SER_Fox_8N1_x10 -- not a local vector id and not
-- a path. Every vector the plan names is in internal flash and arrives here as a bare stored name, so the
-- path-quoting and .bin-stripping below are DEFENSIVE AND UNEXERCISED on this bench; they exist only for
-- the "U-disk0/<file>.bin" form, which nothing here sends. ARWV NAME with an unknown name does nothing and
-- the previous waveform keeps playing, so the reply is compared rather than assumed.
function bsdg.select(name, amp, ofst, srate)
  if name == nil or name == '' then return false, 'no waveform name' end
  if amp == nil or amp <= 0 or amp > bsdg.maxvpp then
    return false, string.format('amplitude %s Vpp is outside 0..%.1f', tostring(amp), bsdg.maxvpp)
  end
  if srate == nil or srate < bsdg.minsrate or srate > bsdg.maxsrate then
    return false, string.format('sample rate %s is outside %g..%g', tostring(srate),
                                bsdg.minsrate, bsdg.maxsrate)
  end
  -- NOTHING CHANGED, SO NOTHING IS SENT. A repeat cell -- same waveform, same amplitude, offset and
  -- sample rate -- needs no conversation at all: the arb is already looping and the capture opens on
  -- whatever phase the wait lands on. That makes a second look at one operating point cost a capture and
  -- a decode instead of a capture, a decode and seven SCPI messages of which two block.
  --
  -- AND IT IS PROBABLY BETTER STIMULUS, NOT JUST CHEAPER: re-sending SRATE VALUE may restart the arb,
  -- which would tie the capture phase to the command timing. Free-running between captures cannot.
  -- That is a hypothesis about this generator, not a measurement -- the phase would have to be measured
  -- to claim it -- but it is a reason this path is not merely an optimisation.
  if name == bsdg.cur and amp == bsdg.curamp and (ofst or 0) == bsdg.curofst
      and srate == bsdg.cursrate and bsdg.id ~= nil and bsdg.nskip < bsdg.arwvevery then
    bsdg.nskip = bsdg.nskip + 1
    bsdg.nsame = bsdg.nsame + 1
    return true
  end

  -- THE WAVEFORM IS ALREADY THE RIGHT ONE, so neither the write nor the verify is sent. Only the 39
  -- cells a lap that genuinely change vector pay for either, and bsdg.arwvevery forces the verify back
  -- periodically so a cache that has gone stale cannot stay stale.
  if name == bsdg.cur and bsdg.id ~= nil and bsdg.nskip < bsdg.arwvevery then
    bsdg.nskip = bsdg.nskip + 1
  else
    -- FORGOTTEN BEFORE THE WRITE, not after the verify fails. From the moment ARWV NAME goes out, what
    -- the generator is playing is unknown, and an early return between here and the confirmation must
    -- not leave a name behind that the next cell would trust.
    bsdg.forget()
    local sel = name
    if string.find(name, '/', 1, true) ~= nil then sel = '"' .. name .. '"' end
    if not bsdg.cmd('C1:ARWV NAME,' .. sel) then return false, bsdg.why end
    -- Compared, not assumed. A bare flash name needs no stripping; the path and .bin removal is for the
    -- key-file form, which answers without its extension.
    local want = string.gsub(name, '^.*/', '')
    want = string.gsub(want, '%.bin$', '')
    -- ASKED AGAIN BECAUSE THE REPLY CAN LAG. Selecting makes this generator briefly stop answering, and
    -- 15 of the 86 cells in a smoke run were thrown away on 'no reply to C1:ARWV? within 5 s' from a
    -- generator that was working -- 17 % of the run, recorded as stimulus failures.
    --
    -- A REPLY THAT NAMES THE PREVIOUS WAVEFORM IS A LATE SWITCH, not a missing file: 4 of the 39 real
    -- switches in a lap answer that way and the generator has the waveform. Asking again does not recover
    -- it -- re-sending the selection does, which brun.selretry handles. So the failure below does not
    -- assert which of the two it was.
    local vok, r, tries = false, nil, nil
    for tries = 1, bsdg.arwvtries do
      if tries > 1 then delay(bsdg.arwvwait) end
      r = bsdg.ask('C1:ARWV?')
      if r ~= nil and string.find(string.upper(r), string.upper(want), 1, true) ~= nil then
        vok = true
        break
      end
    end
    if not vok then
      if r == nil then return false, bsdg.why end
      return false, string.format('ARWV? still names %s after %d tries selecting %s -- the switch did '
                                  .. 'not land, or the generator does not have it',
                                  tostring(r), bsdg.arwvtries, name)
    end
    -- CONFIRMED, and this is the only assignment to bsdg.cur -- downstream of the comparison, never of
    -- the command. A cache set from what was asked for could assert a switch that never landed.
    bsdg.cur, bsdg.nskip = name, 0
  end
  if not bsdg.cmd(string.format('C1:BSWV AMP,%.4f,OFST,%.4f', amp, ofst or 0)) then
    bsdg.forget()
    return false, bsdg.why
  end
  -- TrueArb IS STILL SET AND STILL VERIFIED ON EVERY CELL, deliberately. Neither manual says whether
  -- BSWV resets the sample-rate mode, and a silent fall back to DDS resamples the stored points and
  -- corrupts the sub-sample edge timing this project exists to measure. That is the one failure worth a
  -- blocking query per cell, so the saving above stops here rather than taking the last round trip.
  if not bsdg.cmd('C1:SRATE MODE,TARB') then bsdg.forget(); return false, bsdg.why end
  if not bsdg.cmd(string.format('C1:SRATE VALUE,%.6f', srate)) then
    bsdg.forget()
    return false, bsdg.why
  end
  local ok, why = bsdg.truearb()
  if not ok then bsdg.forget(); return false, why end
  local ook, owhy = bsdg.output(true)
  if not ook then bsdg.forget(); return false, owhy end
  -- Recorded only once the whole conversation has succeeded, so a repeat cell can only skip a state
  -- that was fully established.
  bsdg.curamp, bsdg.curofst, bsdg.cursrate = amp, ofst or 0, srate
  return true
end

-- THREE TRIES, HALF A SECOND APART. After a large upload this generator stops answering for a moment,
-- and reading that timeout as "not in TrueArb" fails a channel that is configured correctly. A reply
-- that ARRIVES and says the wrong thing fails at once: that is the real fault being guarded against.
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

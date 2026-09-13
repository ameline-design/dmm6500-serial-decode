-- Does the on-instrument soak engine work, including the paths a session on the box will not reach?
--
-- bench/bench_run.tsp is meant to run for eight days with nobody able to power cycle anything, so the
-- branches that matter most are the ones an instrument test cannot arrange on purpose: the generator
-- going dead mid-lap, a file the generator cannot read, TrueArb silently falling back to DDS, the plan
-- ending, the key refusing a write. Each of those is driven here.
--
-- AND ONE FIDELITY CHECK THAT IS THE WHOLE JUSTIFICATION FOR THE ENGINE. brun.point() must measure what
-- bench_point() in tools/bench_uart.py measures, or the soak's results cannot be compared with any
-- bench result on record. That function lives in a Python string, so it is EXTRACTED from that file and
-- run side by side here rather than eyeballed.

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
dofile('tools/mock_bench.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
for _, m in ipairs({'bench/arb_names.tsp', 'bench/sdg_net.tsp', 'bench/bench_rec.tsp',
                    'bench/bench_run.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(true)

-- THE SHIPPED DEFAULTS, CAPTURED BEFORE ANY TEST TOUCHES THEM, because the assertion that matters most in
-- this file is about what an UNCONFIGURED run does and every test here reconfigures. Restoring to a
-- literal instead cost this suite its whole point once already: with `brun.holdsecs = 300` typed into a
-- teardown, four assertions claiming the shipped default never parks passed against a build whose default
-- was 0 -- the earlier block had set the value they were reading. A test that writes the number it is
-- checking is checking itself.
local SHIP = {holdsecs = brun.holdsecs, holdslice = brun.holdslice, holdmax = brun.holdmax,
              recretry = brun.recretry, maxsdgfail = brun.maxsdgfail,
              selretry = brun.selretry, selwait = brun.selwait}
local function shipdefaults()
  brun.holdsecs, brun.holdslice, brun.holdmax = SHIP.holdsecs, SHIP.holdslice, SHIP.holdmax
  brun.recretry, brun.maxsdgfail, brun.maxcell = SHIP.recretry, SHIP.maxsdgfail, 0
  brun.selretry, brun.selwait = SHIP.selretry, SHIP.selwait
end

-- THE REAL STORED NAMES, from soakplan.py's own output rather than typed here: the reason a wrong ARWV
-- reached an instrument at all is that the mock understood a name this file had invented. Parsing the
-- plan the instrument will actually stream means the mock answers to exactly what the cells carry.
local ARB
do
  local ph = io.popen("python3 tools/soakplan.py --emit-csv --iteration 1 "
                      .. "--spec 'v77:std,v78:nonstd' 2>/dev/null")
  local ptext = ph:read('*a')
  ph:close()
  ARB = MOCKB_ARBMAP_FROM_PLAN(ptext)
  if ARB.v77 == nil or ARB.v78 == nil then
    print('cannot read the generator names out of soakplan.py --emit-csv'); os.exit(1)
  end
end

local pass, fail = 0, 0
local function ck(cond, what, detail)
  if cond then pass = pass + 1; print('  PASS  ' .. what .. (detail and ('   ' .. detail) or ''))
  else fail = fail + 1; print('  FAIL  ' .. what .. (detail and ('   ' .. detail) or '')) end
end

-- CONTENT COMES BACK THROUGH THE MOCK, not off the host filesystem: mock_display.lua's file mock is
-- the tested one and keeps each path's bytes, so reading them back the way the instrument would is
-- both more faithful and the only option.
local function slurp(p)
  local fh = file.open(p, file.MODE_READ)
  if fh == nil then return nil end
  local s = nil
  pcall(function() s = file.read(fh, file.READ_ALL) end)
  pcall(function() file.close(fh) end)
  return s
end

local function lines(s)
  local out, n = {}, 0
  if s == nil then return out, 0 end
  string.gsub(s, '([^\n]+)', function(l) n = n + 1; out[n] = l end)
  return out, n
end

-- EVERY R ROW AGAINST THE HEADER THE SAME FILE DECLARES, for the run tagged `tag`.
--
-- WHY THIS IS A TEST AND NOT A COMMENT. bench_run writes result rows from two places -- a measured cell
-- and a cell with no stimulus -- and the second one wrote ELEVEN empty columns where twelve belonged.
-- Nothing on the instrument noticed: the row landed on the key, the run completed, the panel stayed
-- quiet. judge_bench.py refused the whole 182-row file, which is the right answer and an expensive place
-- to find out. The header line in the record is the declaration, so the rows are checked against it
-- rather than against a number repeated here.
local function ncomma(s)
  local n = 0
  string.gsub(s, ',', function() n = n + 1 end)
  return n
end

local function checkcols(tag)
  local L, n = lines(slurp(brec.path))
  local k, start, want = nil, 0, nil
  for k = 1, n do
    if string.find(L[k], 'tag=' .. tag, 1, true) ~= nil then start = k end
  end
  for k = start, n do
    if string.sub(L[k], 1, 4) == '# R,' then want = ncomma(L[k]); break end
  end
  local nrow, nbad, first = 0, 0, nil
  for k = start, n do
    if string.sub(L[k], 1, 2) == 'R,' then
      nrow = nrow + 1
      if ncomma(L[k]) ~= want then
        nbad = nbad + 1
        if first == nil then first = L[k] end
      end
    end
  end
  ck(want ~= nil and nrow > 0 and nbad == 0,
     'every result row has the columns the file itself declares (' .. tag .. ')',
     string.format('%d row(s), %d wrong%s', nrow, nbad,
                   first and ('  ' .. string.sub(first, 1, 70)) or ''))
end

-- A tiny plan on the key: two vectors the repo actually has, at rates they can play.
local function writeplan(rows)
  local fh = file.open(brun.planpath, file.MODE_WRITE)
  if fh == nil then print('cannot write the test plan'); os.exit(1) end
  file.write(fh, '# test plan\niter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms\n')
  local i
  for i = 1, table.getn(rows) do file.write(fh, rows[i] .. '\n') end
  file.close(fh)
end

local function droptouch(p)
  local fh = file.open(p, file.MODE_WRITE)
  if fh ~= nil then file.write(fh, 'x\n'); file.close(fh) end
end

print('test_bench_engine: the DMM-driven soak, offline')
print('')

-- ---------------------------------------------------------------------------
print('-- the generator name table --')
do
  -- CURRENT, not merely present. bench/arb_names.tsp is generated from vector_names.py, and a vector
  -- renamed there without regenerating would leave the instrument sending a name the generator does not
  -- have -- which does nothing at all while the previous waveform keeps playing.
  local ph = io.popen('python3 tools/gen_arb_names.py --check 2>&1')
  local out = ph:read('*a')
  ph:close()
  ck(string.find(out, 'is current', 1, true) ~= nil,
     'bench/arb_names.tsp is current with tools/vector_names.py', string.gsub(out, '\n', ' '))
  ck(barb ~= nil and barb.n ~= nil and barb.n >= 40,
     'the table carries every vector, not a truncated file', tostring(barb and barb.n))
  ck(barb.of('v77') == ARB.v77, 'and the table agrees with what the plan carries',
     string.format('%s vs %s', tostring(barb.of('v77')), tostring(ARB.v77)))
  -- NEVER GUESSES. A fallback to the id would send 'v77' to the generator, which is the silent failure.
  ck(barb.of('nosuchvector') == nil, 'an unknown id returns nil rather than itself')
end

-- ---------------------------------------------------------------------------
print('-- the WVDT interlock --')
do
  MOCKB_SDG({})
  bsdg.reset()
  local ok, why = bsdg.cmd('C1:WVDT WVNM,foo,LENGTH,1024')
  ck(ok == false and why ~= nil and string.find(why, 'WVDT', 1, true) ~= nil,
     'an upload is refused before it reaches the wire', tostring(why))
  ck(MOCKB.sdg.ncmd == 0, 'and nothing at all was written to the generator',
     tostring(MOCKB.sdg.ncmd))
  local ok2, why2 = bsdg.cmd('*RST')
  ck(ok2 == false and why2 ~= nil, 'a reset is refused too -- it would drop the loaded waveform',
     tostring(why2))
end

-- ---------------------------------------------------------------------------
print('')
print('-- selecting a vector --')
do
  MOCKB_SDG({})
  bsdg.reset()
  local live, idn = bsdg.alive()
  ck(live == true and string.find(tostring(idn), 'SDG', 1, true) ~= nil,
     'the generator answers *IDN?', tostring(idn))
  local ok, why = bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  ck(ok == true, 'a vector selects, verifies and turns the output on', tostring(why))
  ck(MOCKB.sdg.arb == ARB.v77 and MOCKB.sdg.mode == 'TARB' and MOCKB.sdg.out == true,
     'and the generator is left in TrueArb with the output on',
     string.format('arb=%s mode=%s out=%s', tostring(MOCKB.sdg.arb), tostring(MOCKB.sdg.mode),
                   tostring(MOCKB.sdg.out)))
  -- THE ORDER IS THE MEASURED ONE. TrueArb must be set AFTER ARWV and BSWV, because neither manual
  -- says whether those reset the mode -- so a run that set it first could be silently in DDS.
  local iarwv, ibswv, itarb, k = nil, nil, nil, nil
  for k = 1, MOCKB.sdg.nlog do
    local L = string.upper(MOCKB.sdg.log[k])
    if iarwv == nil and string.find(L, 'ARWV NAME', 1, true) then iarwv = k end
    if ibswv == nil and string.find(L, 'BSWV AMP', 1, true) then ibswv = k end
    if itarb == nil and string.find(L, 'SRATE MODE,TARB', 1, true) then itarb = k end
  end
  ck(iarwv ~= nil and ibswv ~= nil and itarb ~= nil and itarb > iarwv and itarb > ibswv,
     'TrueArb is set LAST, after ARWV and BSWV',
     string.format('arwv@%s bswv@%s tarb@%s', tostring(iarwv), tostring(ibswv), tostring(itarb)))
end

-- ---------------------------------------------------------------------------
print('')
print('-- not re-asking for what the generator is already playing --')
-- A LAP SWEEPS 43 RATES ACROSS ONE WAVEFORM, so 97.7 % of cells used to re-select a waveform that was
-- already selected. That is not free in either direction: the ARWV write is what makes this generator
-- briefly stop answering, and the ARWV? verifying it then blocks on a stall the write itself caused.
-- These assertions are about SCPI TRAFFIC rather than about time, because traffic is what a mock can
-- measure and time is not -- but the two queries removed here are the round trips.
do
  -- How many log lines match, and the log is read rather than the mock's final state: the state cannot
  -- distinguish "set once" from "set forty-three times", which is the entire question.
  local function nlog(pat)
    local n, k = 0, nil
    for k = 1, MOCKB.sdg.nlog do
      if string.find(string.upper(MOCKB.sdg.log[k]), string.upper(pat), 1, true) ~= nil then
        n = n + 1
      end
    end
    return n
  end

  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  local base = MOCKB.sdg.nlog
  -- 43 rates on ONE waveform: what a lap actually does between vector changes.
  local i, allok = nil, true
  for i = 1, 43 do
    local ok = bsdg.select(ARB.v77, 5.0, 0.0, 96000 + i)
    if not ok then allok = false end
  end
  ck(allok, '43 rates on one waveform all select')
  ck(nlog('ARWV NAME') == 1,
     'one ARWV NAME for 43 cells on the same waveform, not 43', nlog('ARWV NAME'))
  ck(nlog('ARWV?') == 1,
     'and one ARWV? verify, not 43 -- the blocking query is what this saves', nlog('ARWV?'))
  ck(nlog('BSWV AMP') == 43, 'while every cell still sets its own amplitude and offset', nlog('BSWV AMP'))
  ck(nlog('SRATE VALUE') == 43, 'and its own sample rate', nlog('SRATE VALUE'))
  -- THE ONE ROUND TRIP DELIBERATELY KEPT. Neither manual says whether BSWV resets the sample-rate mode,
  -- and a silent fall back to DDS resamples the stored points and corrupts the sub-sample edge timing
  -- this project exists to measure. So TrueArb is still asserted and still verified on every cell.
  ck(nlog('SRATE?') == 43, 'and TrueArb is still VERIFIED on every cell, not cached', nlog('SRATE?'))
  local per = (MOCKB.sdg.nlog - base) / 43
  ck(per > 4.9 and per < 5.2,
     'so a same-waveform cell costs 5 messages instead of 7', string.format('%.2f', per))

  -- A REPEAT CELL -- the user-facing point of the cache. Same waveform, same amplitude, same offset,
  -- same rate: a second look at one operating point at a fresh capture phase. Nothing needs to be sent
  -- at all, because the arb is already looping.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  ck(bsdg.select(ARB.v77, 5.0, 0.0, 96000) == true, 'a first cell at an operating point selects')
  local after1 = MOCKB.sdg.nlog
  local r, nrep = nil, 0
  for r = 1, 8 do
    if bsdg.select(ARB.v77, 5.0, 0.0, 96000) then nrep = nrep + 1 end
  end
  ck(nrep == 8, 'and eight repeats of the identical operating point all succeed', nrep)
  ck(MOCKB.sdg.nlog == after1,
     'sending NOTHING to the generator: 0 messages for 8 repeat captures',
     MOCKB.sdg.nlog - after1)
  ck(bsdg.nsame == 8, 'and the run can account for them', bsdg.nsame)

  -- CHANGING ANY ONE OF THE FOUR BREAKS THE SKIP. A cache that ignored the offset would drive a
  -- stimulus the record does not describe, which is the failure mode this project has already spent a
  -- soak on -- so each field is checked on its own rather than trusting one composite key.
  local fields = {{'amplitude', 6.0, 0.0, 96000}, {'offset', 5.0, 1.0, 96000},
                  {'sample rate', 5.0, 0.0, 48000}}
  local f
  for f = 1, 3 do
    MOCKB_SDG({})
    bsdg.reset()
    bsdg.alive()
    bsdg.select(ARB.v77, 5.0, 0.0, 96000)
    local n0 = MOCKB.sdg.nlog
    bsdg.select(ARB.v77, fields[f][2], fields[f][3], fields[f][4])
    ck(MOCKB.sdg.nlog > n0,
       'a change of ' .. fields[f][1] .. ' is still sent, never skipped',
       MOCKB.sdg.nlog - n0)
  end

  -- A DIFFERENT WAVEFORM STILL VERIFIES. The cache must not be able to suppress the check that catches
  -- a switch that did not land.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  local n0 = nlog('ARWV?')
  bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(nlog('ARWV?') == n0 + 1, 'a real vector change still sends ARWV and verifies the reply')

  -- A DROPPED SESSION FORGETS. A reconnected generator knows nothing about what it was playing, and a
  -- cache that survived the reconnect would skip the one verify able to notice.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  bsdg.close()
  ck(bsdg.cur == nil, 'closing the session forgets what was selected')
  local n1 = nlog('ARWV NAME')
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  ck(nlog('ARWV NAME') == n1 + 1, 'so the next cell re-selects and re-verifies')

  -- A FAILED SELECT FORGETS, which is what makes brun.selretry able to recover. If a failure left the
  -- name cached, every one of the five retries would skip the selection and the run would report the
  -- same failure five times without ever re-sending anything.
  MOCKB_SDG({refuse_arb = ARB.v78})
  bsdg.reset()
  bsdg.alive()
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  local ok2 = bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(ok2 == false, 'a refused waveform still fails')
  ck(bsdg.cur == nil, 'and the failure forgets, so brun.selretry re-sends instead of re-skipping')
  local n2 = nlog('ARWV NAME')
  bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(nlog('ARWV NAME') == n2 + 1, 'which the retry demonstrably does')

  -- THE CEILING ON A STALE CACHE. Nothing in this module can change the selected waveform behind the
  -- cache, but the generator is a third party -- a front-panel press could. One forced verify every
  -- arwvevery skips bounds how many cells a stale cache could misattribute.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.arwvevery = 10
  for i = 1, 25 do bsdg.select(ARB.v77, 5.0, 0.0, 96000 + i) end
  bsdg.arwvevery = 50
  ck(nlog('ARWV?') == 3,
     'the verify comes back every arwvevery cells, so a stale cache is bounded', nlog('ARWV?'))

  -- ZERO IS AN EXACT REVERT, and that is what makes the saving measurable rather than merely argued:
  -- two laps of one plan, this at 0 against the default, and the wall-time difference is what the skip
  -- is worth on the real generator. It is also the escape hatch -- one assignment over the socket, no
  -- reload -- which matters on an instrument where a reload costs a display-object generation.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.arwvevery = 0
  local z0 = MOCKB.sdg.nlog
  for i = 1, 43 do bsdg.select(ARB.v77, 5.0, 0.0, 96000 + i) end
  local zoff = MOCKB.sdg.nlog - z0
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.arwvevery = 50
  local o0 = MOCKB.sdg.nlog
  for i = 1, 43 do bsdg.select(ARB.v77, 5.0, 0.0, 96000 + i) end
  local zon = MOCKB.sdg.nlog - o0
  ck(zoff == 43 * 7, 'arwvevery = 0 sends the full 7-message conversation on every cell', zoff)
  ck(zon < zoff, 'and the default sends fewer', string.format('%d vs %d', zon, zoff))
end

-- ---------------------------------------------------------------------------
print('')
print('-- reading the generator back on a stimulus-free cell --')
-- THE DIAGNOSTIC MUST NOT CREATE THE FAULT IT OBSERVES. bsdg.nfail is the wedge detector: bench_run's
-- select retry loop breaks the moment it is non-zero. bsdg.snapshot() asks four questions, and a query
-- with no reply raises nfail -- so charging four of them to a stimulus-free cell left nfail at 1 and gave
-- the NEXT cell one select attempt instead of five. That printed GENERATOR SILENT inside the first lap of
-- the run this diagnostic was written for, on a generator that was answering perfectly.
do
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.alive()
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  local snap = bsdg.snapshot()
  ck(bsdg.nfail == 0, 'a snapshot of a healthy generator leaves nfail at 0', bsdg.nfail)
  ck(snap ~= nil and string.find(snap, 'arwv=', 1, true) ~= nil,
     'and it reports what the generator says it is playing', tostring(snap))
  ck(string.find(snap, ',', 1, true) == nil,
     'with no commas, which would break the record it is written into', tostring(snap))

  -- AND ON A GENERATOR THAT HAS STOPPED ANSWERING: nfail must come back exactly as it went in, and the
  -- snapshot must not spend four timeouts discovering what nfail already said.
  MOCKB_SDG({dead = true})
  bsdg.reset()
  bsdg.nfail = 3
  local s2 = bsdg.snapshot()
  ck(bsdg.nfail == 3, 'a snapshot never changes nfail, even when nothing answers', bsdg.nfail)
  ck(s2 ~= nil and string.find(s2, 'skipped', 1, true) ~= nil,
     'and it does not ask a generator that is already known silent', tostring(s2))
end

-- ---------------------------------------------------------------------------
print('')
print('-- the failures an instrument session cannot arrange --')
do
  -- A FILE THE GENERATOR CANNOT READ. It does not answer with an error: it leaves the previous
  -- waveform selected and says nothing, which is why the reply is compared.
  MOCKB_SDG({refuse_arb = ARB.v78})
  bsdg.reset()
  bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  local ok, why = bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(ok == false and why ~= nil and string.find(why, 'ARWV?', 1, true) ~= nil,
     'a file the generator cannot read is caught by comparing ARWV?, not assumed loaded',
     tostring(why))
  ck(MOCKB.sdg.arb == ARB.v77, 'and the generator is still playing the previous vector, as it would be',
     tostring(MOCKB.sdg.arb))

  -- TRUEARB FALLING BACK TO DDS, which would resample the points and corrupt edge timing with nothing
  -- on the panel to say so.
  MOCKB_SDG({dds_after_arb = true})
  bsdg.reset()
  -- The mock sets DDS on ARWV; sdg_net sets TARB after, so this must still pass -- that IS the reason
  -- for the order. Then force the fallback by clearing the mode after everything is set.
  local ok2 = bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  ck(ok2 == true, 'setting TrueArb after ARWV survives a generator that resets the mode on ARWV')
  MOCKB.sdg.mode = 'DDS'
  local ok3, why3 = bsdg.truearb()
  ck(ok3 == false and why3 ~= nil and string.find(why3, 'TrueArb', 1, true) ~= nil,
     'and a channel actually in DDS is refused rather than measured', tostring(why3))

  -- A DEAD GENERATOR: every query times out. Nothing may raise, and the reason must be reportable.
  MOCKB_SDG({dead = true})
  bsdg.reset()
  bsdg.timeout = 0.05
  local live, why4 = bsdg.alive()
  ck(live == false and why4 ~= nil, 'a dead generator reports rather than raising', tostring(why4))

  -- A WEDGED GENERATOR: writes accepted, nothing ever answered. This is the failure actually observed
  -- on this part, and it is NOT the same as a refused connection.
  MOCKB_SDG({wedged = true})
  bsdg.reset()
  local live2, why5 = bsdg.alive()
  ck(live2 == false and why5 ~= nil and string.find(why5, 'no reply', 1, true) ~= nil,
     'a WEDGED generator -- accepting writes, answering nothing -- is caught by the poll timeout',
     tostring(why5))
  bsdg.timeout = 5
end

-- ---------------------------------------------------------------------------
print('')
print('-- recording, and what survives a power cut --')
do
  MOCKB_SDG({})
  bsdg.reset()
  brec.syncrows = 3      -- so the close/reopen path runs several times in a short test
  local ok = brec.begin('unit', 2, 'PLAN.CSV')
  ck(ok == true, 'a run opens a numbered result file and a status log', tostring(brec.path))
  local i
  for i = 1, 10 do brec.row(string.format('%d,%d,v77,X,9600,std,5,0,96000,0,,,,,,,,,,,,,', 1, i)) end
  brec.note(1, 10, 10, 'ten cells in', 0, 0)
  -- NOT CLOSED. This is the point: the file must be readable with the handle still open, because a
  -- power cut is the stop button and there is no close to wait for.
  local s = slurp(brec.path)
  local L, n = lines(s)
  ck(s ~= nil and n >= 12, 'every row is on disk with the file still open -- no close required',
     string.format('%d line(s)', n))
  ck(string.find(L[1], 'serdec%-soak%-1') ~= nil, 'the schema version is the first line', L[1])
  -- THE PLAN VARIANT, because lap 7 of a four-random plan and lap 7 of a full one are different
  -- stimulus with the same number: the subset is a skip, applied before the shuffle, and the shuffle
  -- keys every cell's amplitude.
  ck(string.find(L[1], 'randomperlap=', 1, true) ~= nil,
     'and the header says which plan variant produced it', L[1])
  ck(string.find(L[2], 'iter,cell,vid,baud', 1, true) ~= nil,
     'and the column names are in the file, not only in a tool that reads it')
  ck(string.find(s, 'ten cells in', 1, true) ~= nil,
     'progress rows are interleaved with results in the same file, tagged S')
  ck(string.find(s, '\nR,1,1,v77', 1, true) ~= nil, 'and result rows are tagged R')
  brec.finish('unit done')
end

-- ---------------------------------------------------------------------------
print('')
print('-- a whole soak, end to end --')
do
  MOCKB_SDG({})
  bsdg.reset()
  brec.syncrows = 50
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',19200,std,5.0000,0.0000,192000,0.000',
             '2,1,v77,' .. ARB.v77 .. ',9600,std,4.0000,0.0000,96000,0.000'})
  local ok, why = brun.soak(1, 'e2e')
  ck(ok == true, 'the soak runs and returns', tostring(why))
  local L, n = lines(slurp(brec.path))
  -- COUNTED WITHIN THIS RUN'S SECTION OF THE FILE, and that is the contract rather than a workaround:
  -- the record is ONE fixed name opened for append, because a numbered filename means probing candidates
  -- and a probe that misses posts 2205 on the panel. Runs are therefore separated by their header line,
  -- and a reader has to split on it -- so this test splits the same way judge_bench.py must. Counting
  -- every R row in the file instead counts every earlier test's cells: 12 where 2 were expected.
  local k, start = nil, 0
  for k = 1, n do
    if string.find(L[k], 'tag=e2e', 1, true) ~= nil then start = k end
  end
  ck(start > 0, 'this run is separated from the previous one by its own header line',
     string.format('header at line %d of %d', start, n))
  -- Two data rows for iteration 1, and it must STOP there rather than running iteration 2.
  -- COUNTED BY TAG, not by "not a comment": progress rows share this file now, so anything that is
  -- merely non-comment includes them and a count of cells would be inflated by its own status lines.
  local ndata, lastR = 0, nil
  for k = start + 1, n do
    if string.sub(L[k], 1, 2) == 'R,' then ndata = ndata + 1; lastR = L[k] end
  end
  ck(ndata == 2, 'one iteration means iteration 1 only, not everything in the file',
     string.format('%d data row(s)', ndata))
  ck(why ~= nil and string.find(why, 'iteration', 1, true) ~= nil,
     'and it says why it stopped', tostring(why))
  -- THE BYTES ARE IN THE ROW. Without them the host cannot judge, and judging on the instrument would
  -- mean a second implementation of the bench's judge.
  local last = lastR or ''
  local nfield = 1
  string.gsub(last, ',', function() nfield = nfield + 1 end)
  ck(nfield >= 22, 'a result row carries every field the host judge needs',
     string.format('%d fields: %s', nfield, string.sub(last, 1, 90)))
  ck(string.find(last, 'v77', 1, true) ~= nil, 'including which vector it was')
  checkcols('e2e')
end

-- ---------------------------------------------------------------------------
print('')
print('-- the generator dying mid-soak --')
do
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.timeout = 0.05
  brun.maxsdgfail = 3
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,3,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,4,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,5,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,6,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  MOCKB.sdg.wedged = true
  -- BOUNDED, BECAUSE IT NO LONGER PARKS. A wedged generator now holds and retries until somebody stops
  -- the run, so a test has to be the thing that stops it: holdmax is the bound, and delay() being a no-op
  -- offline means an unbounded hold would SPIN rather than wait.
  brun.holdslice, brun.holdsecs, brun.holdmax = 1, 1, 3
  local ok, why = brun.soak(1, 'dead')
  shipdefaults()
  ck(ok == true and why ~= nil and string.find(why, 'gave up after', 1, true) ~= nil,
     'a wedged generator holds and retries rather than filling the key', tostring(why))
  local s = slurp(brec.path)
  ck(s ~= nil and string.find(s, 'sdg failed', 1, true) ~= nil,
     'and the record names the generator, so a reader is not left guessing')
  -- THE ROWS IT DID WRITE MUST SAY THE STIMULUS WAS ABSENT. Rows that merely showed no bytes would
  -- read, to anyone judging later, exactly like a decoder that had collapsed.
  local L, n = lines(slurp(brec.path))
  local nsdg, k = 0, nil
  for k = 1, n do if string.find(L[k], 'SDG:', 1, true) ~= nil then nsdg = nsdg + 1 end end
  ck(nsdg >= 3, 'and each unmeasured cell is marked as a generator failure, not as a decode failure',
     string.format('%d row(s) marked SDG:', nsdg))
  -- AND THOSE ROWS ARE STILL THE RIGHT SHAPE. This is the row kind that was a column short, and 15 of
  -- them in one real lap made the host refuse the entire 182-row file.
  checkcols('dead')
  bsdg.timeout = 5
  brun.maxsdgfail = 20
end

-- ---------------------------------------------------------------------------
print('')
print('-- resuming a run from the last cell the record holds --')
do
  MOCKB_SDG({})
  bsdg.reset()
  local plan, i = {}, nil
  for i = 1, 8 do
    plan[i] = '1,' .. i .. ',v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'
  end
  writeplan(plan)
  -- Run four cells, then stop the way a crash does: by ending the lap early.
  brun.maxcell = 4
  brun.resume = false
  brun.soak(1, 'part1')
  brun.maxcell = 0
  local it, ce = brun.resume_scan()
  ck(it == 1 and ce == 4, 'the record names the last completed cell',
     string.format('L%sC%s', tostring(it), tostring(ce)))

  -- RESUMED: the next cell measured must be the one AFTER it, not the first in the plan.
  brun.resume = true
  local ok, why = brun.soak(1, 'part2')
  brun.resume = false
  ck(ok == true, 'a resumed run completes', tostring(why))
  ck(brun.nskipped == 4, 'and it skipped exactly the cells already recorded',
     string.format('%d row(s) skipped', brun.nskipped))
  local s2 = slurp(brec.path)
  ck(s2 ~= nil and string.find(s2, 'resumed after L1C4', 1, true) ~= nil,
     'and the record says where it resumed from')
  -- THE CELLS AFTER IT, AND ONLY THOSE. Four remained, so a resumed lap of an eight-row plan runs four.
  local L, n = lines(s2)
  local start, k, ndata = 0, nil, 0
  for k = 1, n do if string.find(L[k], 'tag=part2', 1, true) ~= nil then start = k end end
  for k = start, n do if string.sub(L[k], 1, 2) == 'R,' then ndata = ndata + 1 end end
  ck(ndata == 4, 'measuring only the cells that were left', string.format('%d cell(s)', ndata))

  -- THE TAG REACHES THE PANEL, not only the record header. brun.soak leaves it on brun before ui_build
  -- reads it, so a smoke cannot paint a screen that says SOAK.
  ck(brun.tag == 'part2', 'the run tag is left on brun for the screen to read', tostring(brun.tag))

  -- AND THE SCREEN COUNTS THE WHOLE RUN, NOT JUST THIS SESSION. brun.ncell is what this session measured,
  -- which is what the RATE has to be divided by; the run's POSITION is that plus whatever the resume
  -- skipped. With one counter a soak resumed at lap 9 would read '500 of 279930 (0.2 %)' and put eight
  -- completed laps back on the clock, understating progress and overstating what is left for eight days.
  brun.ui_build()
  brun.percell, brun.iterwant = 1333, 210
  brun.ncell, brun.nskipped = 500, 10664          -- resumed after 8 laps, 500 cells into the 9th
  brun.t0, brun.tlap = os.time() - 2650, os.time() - 2650
  brun.screen({iter = 9, cell = 500, vid = 'v77', baud = 9600}, ARB.v77)
  local tres = tostring(MD.text(brun.ui.time))
  -- THE RATE FIELD ITSELF, three significant digits over the range a soak really spans: a 250 kBd cell at
  -- 8 kB is a fraction of a second and a 300 Bd cell behind a long wait is minutes, so the format has to
  -- hold both without a fixed decimal count making one of them useless. The clamp is the load-bearing part:
  -- %.3g turns 1050 into '1.05e+03', which is 8 characters on a line measured to the character, so anything
  -- that wide is reported as '>999' instead.
  ck(brun.sig3(6.5873) == '6.59', 'sig3 gives three significant digits', tostring(brun.sig3(6.5873)))
  ck(brun.sig3(0.23412) == '0.234', '...on a sub-second cell', tostring(brun.sig3(0.23412)))
  ck(brun.sig3(12.34) == '12.3' and brun.sig3(105.4) == '105',
     '...and on a slow one', tostring(brun.sig3(12.34)) .. ' / ' .. tostring(brun.sig3(105.4)))
  ck(brun.sig3(1050) == '>999' and brun.sig3(999.6) == '>999',
     'sig3 clamps rather than emitting an exponent that would overrun the line',
     tostring(brun.sig3(1050)))
  ck(brun.sig3(nil) == '--' and brun.sig3(-1) == '--',
     'sig3 answers -- for no rate and for a negative one', tostring(brun.sig3(nil)))
  ck(string.len(brun.sig3(6.5873)) <= 5 and string.len(brun.sig3(1050)) <= 5,
     'sig3 is never wider than 5 characters, which is what the line was measured against',
     tostring(string.len(brun.sig3(6.5873))))

  ck(string.find(tres, '11164/279930', 1, true) ~= nil
     and string.find(tres, '(4.0%)', 1, true) ~= nil,
     'a resumed run counts the cells it skipped as done', tres)
  -- AND THE RATE STILL COMES FROM THIS SESSION ONLY. 2650 s over 500 cells is 5.3 s a cell, so the
  -- 268 766 cells left are 395.8 h -- dividing the session's seconds by the RUN's cells would read 9 s a
  -- cell and claim a fortnight that never existed.
  ck(string.find(tres, 'of 412.1h', 1, true) ~= nil,
     'and the projection uses this session\'s rate, not the whole run\'s', tres)
  -- AND THE LINE AGREES WITH ITSELF. 4.0 % of 412.1 h is 16.4 h, so an elapsed of 0.7 h -- this session's
  -- wall clock -- would be the line contradicting its own percentage. The figure shown is elapsed AT THIS
  -- RATE, which for a run that was never resumed is the wall clock exactly, and after a resume excludes
  -- the hours the instrument spent doing something else.
  ck(string.find(tres, 'Total: 16.4h of 412.1h', 1, true) ~= nil,
     'and the elapsed figure agrees with the percentage rather than the session', tres)

  -- A CELL NUMBER PAST THE LAP SIZE MUST NOT PRINT A PERCENTAGE. A plan whose cell numbers run
  -- cumulatively instead of restarting each lap makes brun.percell -- learned as the highest cell of the
  -- previous lap -- smaller than this lap's numbers. Observed on the glass: 'cell 240/197  (122%)', which
  -- an operator reasonably read as the run being broken. The cell number is always true so it is always
  -- shown; the denominator and the share are withheld, exactly as 'left' already was.
  brun.percell, brun.iterwant = 47, 6
  brun.ncell, brun.nskipped = 251, 0
  brun.t0, brun.tlap = os.time() - 900, os.time() - 900
  brun.screen({iter = 6, cell = 251, pos = 7, vid = 'v77', baud = 9600}, ARB.v77)
  local pres = tostring(MD.text(brun.ui.prog))
  ck(string.find(pres, '7/47', 1, true) ~= nil,
     'a cumulative plan shows the COUNTED position in the lap, not the label', pres)
  ck(string.find(pres, '251/47', 1, true) == nil and string.find(pres, '(534%)', 1, true) == nil,
     'so the panel cannot print a share over 100 %', pres)
  ck(string.find(pres, 'r251', 1, true) ~= nil,
     'and the plan label is still shown, because the record keys its rows on it', pres)
  ck(string.find(pres, 'Left:', 1, true) ~= nil
     and string.find(pres, 'Left: --', 1, true) == nil,
     'and the lap countdown is a number rather than --, which is the point of the fix', pres)
  -- AND THE ORDINARY CASE IS UNCHANGED: no pos on the row means the label IS the position, and no
  -- redundant label is appended.
  brun.percell = 197
  brun.screen({iter = 5, cell = 100, vid = 'v77', baud = 9600}, ARB.v77)
  local qres = tostring(MD.text(brun.ui.prog))
  ck(string.find(qres, '100/197', 1, true) ~= nil and string.find(qres, 'r100', 1, true) == nil,
     'a plan that restarts its numbering reads exactly as before', qres)

  -- A WRAPPED PLAN IS THE MIRROR CASE, and it is the one an operator met on the glass. A one-lap plan run
  -- for 15 iterations reaches the end of the file and starts it again, so the COUNTED position runs on --
  -- 110 = 44 + 44 + 22 on a 44-cell lap -- while the plan's own label restarts with the plan. Withholding
  -- the denominator then left 'cell 110' with no share and 'left --' on a run that knew both, and the bare
  -- label suffix beside it meant nothing to the reader.
  --
  -- THE LABEL IS BUILT RATHER THAN WRITTEN OUT, here and below, because tools/lint_vecrefs.py reads r<NN>
  -- as a vector id and a two-digit one that is not in vector_names.MAP fails the gate. The existing case
  -- above gets away with 'r251' only because three digits do not match.
  brun.percell, brun.iterwant = 44, 15
  brun.ncell, brun.nskipped = 110, 0
  brun.t0, brun.tlap = os.time() - 600, os.time() - 120
  brun.screen({iter = 1, cell = 22, pos = 110, vid = 'v77', baud = 2400}, ARB.v77)
  local wres = tostring(MD.text(brun.ui.prog))
  ck(string.find(wres, '22/44', 1, true) ~= nil,
     'a wrapped plan shows the label, which is the position within the lap', wres)
  ck(string.find(wres, 'cell 110', 1, true) == nil,
     'and not the counted position, which has run past the lap', wres)
  ck(string.find(wres, ' r' .. 22, 1, true) == nil,
     'and appends no label, because the label is what it is already showing', wres)
  ck(string.find(wres, 'left --', 1, true) == nil,
     'and the lap countdown becomes a number, since the position in the lap is known', wres)
  -- AND A LABEL ALSO PAST THE LAP IS STILL REFUSED. Neither number is inside the lap then, so there is
  -- nothing to stand behind: this is the case pos % nlap would have answered confidently and wrongly.
  brun.screen({iter = 1, cell = 251, pos = 110, vid = 'v77', baud = 2400}, ARB.v77)
  local xres = tostring(MD.text(brun.ui.prog))
  ck(string.find(xres, '/44', 1, true) == nil,
     'a label past the lap prints no denominator at all', xres)
  ck(string.find(xres, 'r251', 1, true) ~= nil,
     'and falls back to showing the label separately, as before', xres)
  brun.nskipped = 0
  brun.ui_destroy()

  -- A RESUME POINT THE PLAN DOES NOT CONTAIN IS REFUSED, not quietly restarted. That means the plan on the
  -- key is not the plan that produced the record -- a different --random-per-lap, a different skip, a
  -- regenerated file -- and starting from row one would replay days of stimulus while reporting a resume.
  writeplan({'9,777,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  brun.resume = true
  local ok3, why3 = brun.soak(1, 'part3')
  brun.resume = false
  ck(ok3 == false and string.find(tostring(why3), 'does not contain', 1, true) ~= nil,
     'a resume point missing from the plan refuses the run', tostring(why3))
end

-- ---------------------------------------------------------------------------
print('')
print('-- a wedged generator: never parks, holds until somebody stops the run --')
do
  bsdg.timeout = 0.05
  brun.maxsdgfail = 3
  local plan = {}
  local i
  for i = 1, 8 do
    plan[i] = '1,' .. i .. ',v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'
  end

  -- (a) THE DEFAULT MUST NOT PARK. A run ends when the iteration count runs out, when the TRIGGER key is
  -- pressed, or when the stop file appears -- and a fault is none of those. This is the assertion that
  -- says so: with nothing but the default set, a generator that never answers is still being waited for
  -- when holdmax -- the test's own bound, not the instrument's -- ends it.
  --
  -- CHECKED AGAINST THE SHIPPED DEFAULT rather than a value the test sets, because the whole point is
  -- what an unattended run does when nobody has configured it. brun.holdsecs is read here, not written.
  ck(SHIP.holdsecs > 0, 'the SHIPPED default holds rather than parks',
     string.format('brun.holdsecs = %s at load', tostring(SHIP.holdsecs)))
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  brun.holdslice, brun.holdmax = 1, 4
  MOCKB.sdg.wedged = true
  -- delay() IS SPIED ON, not inferred from a counter. brun.heldsecs increments next to the delay call
  -- rather than because of it, so asserting on the counter alone would still pass with the waiting
  -- removed -- and offline delay() is a no-op, so nothing else can tell the difference.
  local realdelay, ndelay, delayed = brun.holddelay, 0, 0
  brun.holddelay = function(s) ndelay = ndelay + 1; delayed = delayed + s; return realdelay(s) end
  local ok1, why1 = brun.soak(1, 'nopark')
  brun.holddelay = realdelay
  ck(ok1 == true and string.find(tostring(why1), 'gave up after', 1, true) ~= nil
     and string.find(tostring(why1), 'in a row', 1, true) == nil,
     'a wedged generator is held for, not parked on -- only holdmax ends it', tostring(why1))
  -- SECONDS HELD, NOT RETRIES ATTEMPTED, and the difference is the point of running this at the shipped
  -- period: brun.nhold counts COMPLETED holdsecs waits, and holdsecs is 300 here because nothing set it,
  -- so a test bounded at 4 s cannot see one. What it can see is that the run spent those 4 s waiting for
  -- the generator rather than ending. Retries are counted in (c), where the period is 1 s.
  ck(ndelay > 0 and delayed >= brun.holdmax and brun.heldsecs == delayed,
     'and it really did wait -- delay() was called, for as long as the counter claims',
     string.format('%d call(s), %g s delayed, counter says %g', ndelay, delayed, brun.heldsecs))
  ck(delayed <= brun.holdmax + brun.holdslice,
     'and it stopped waiting when holdmax said to, not later',
     string.format('%g s against holdmax %g', delayed, brun.holdmax))

  -- (b) A GENERATOR THAT ANSWERS IS NOT WAITED FOR. maxsdgfail counts cells with no stimulus, and a stale
  -- arb_names.tsp produces those with the generator perfectly alive -- a static fault no amount of holding
  -- fixes. Holding 300 s per 20 cells would add ~7 h to a lap that runs in under three, and call it recovery.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.timeout = 5
  writeplan({'1,1,v77,SER_NoSuchWaveform_8N1_x10,9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,SER_NoSuchWaveform_8N1_x10,9600,std,5.0000,0.0000,96000,0.000',
             '1,3,v77,SER_NoSuchWaveform_8N1_x10,9600,std,5.0000,0.0000,96000,0.000',
             '1,4,v77,SER_NoSuchWaveform_8N1_x10,9600,std,5.0000,0.0000,96000,0.000'})
  brun.holdslice, brun.holdmax = 1, 4
  local heldb = brun.heldsecs
  local okb, whyb = brun.soak(1, 'aliveb')
  ck(okb == true and string.find(tostring(whyb), 'iteration', 1, true) ~= nil,
     'a plan the arb table disagrees with does not stop or hold the run', tostring(whyb))
  ck(brun.heldsecs == 0, 'and nothing was waited for, because the generator answers',
     string.format('%d s held', brun.heldsecs))
  ck(brun.nsdgalive >= 1, 'and the record says the fault is not the wire',
     string.format('%d time(s)', brun.nsdgalive))
  local sa = slurp(brec.path)
  ck(sa ~= nil and string.find(sa, 'generator ANSWERS', 1, true) ~= nil,
     'in those words, so nobody power cycles a working generator')
  bsdg.timeout = 0.05
  MOCKB.sdg.wedged = true

  -- (c) IT CARRIES ON FROM WHERE IT STOPPED once the generator answers. It comes back on the second call
  -- to alive() -- the first is soak's own pre-flight check.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  -- BOUNDED, ALWAYS, IN A TEST. delay() is a no-op offline, so an unbounded hold does not wait -- it
  -- SPINS, and a suite that spins until something kills it reports exit 0 through a pipeline.
  brun.holdsecs, brun.holdslice, brun.holdmax = 1, 1, 60
  MOCKB.sdg.wedged = true
  -- THREE CALLS, NOT TWO, and the third is what makes this test the one it claims to be. sdghold now asks
  -- alive() BEFORE it waits, so the calls are: soak's pre-flight (1), sdghold's is-it-really-the-wire
  -- check (2), and the check after the first hold (3). Coming back on call 2 would mean the run never
  -- held at all -- which is correct behaviour for a generator that answers, and is asserted in (b), but
  -- it is not this case.
  local realalive, nalive = bsdg.alive, 0
  bsdg.alive = function()
    nalive = nalive + 1
    if nalive >= 3 then MOCKB.sdg.wedged = false end
    return realalive()
  end
  local ok2, why2 = brun.soak(1, 'hold')
  bsdg.alive = realalive
  ck(ok2 == true and brun.nhold >= 1
     and string.find(tostring(why2), 'iteration', 1, true) ~= nil,
     'with a hold it waits for the generator and finishes the lap',
     string.format('%d retry(s), ended: %s', brun.nhold, tostring(why2)))
  -- THE GAP HAS TO BE ON THE KEY. Cells that stop and resume with nothing in between are
  -- indistinguishable from a run somebody restarted by hand.
  local sh = slurp(brec.path)
  ck(sh ~= nil and string.find(sh, 'holding for the generator', 1, true) ~= nil,
     'and every retry is written to the key, so the gap is readable')

  -- (d) AND IT GIVES UP ONLY IF TOLD TO. holdmax bounds the total wait; it is 0 on the instrument, which
  -- is what 'until it is stopped' means, and it is the only reason a test can end one of these runs.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  brun.holdsecs, brun.holdslice, brun.holdmax = 1, 1, 3
  MOCKB.sdg.wedged = true
  local ok3, why3 = brun.soak(1, 'holdmax')
  ck(ok3 == true and string.find(tostring(why3), 'gave up after', 1, true) ~= nil,
     'a hold that runs past holdmax ends the run with a reason', tostring(why3))
  ck(brun.stopbad == true, 'and it is marked as a fault, so the screen goes red')

  -- RESTORED TO THE SHIPPED DEFAULTS, not to zero. Leaving holdsecs = 0 here would put every test after
  -- this one back into the parking configuration -- so the assertions would pass against a module
  -- configured the way the instrument never is, which is the shape of half the bugs in this file's
  -- history.
  shipdefaults()
  brun.maxsdgfail = 20
  bsdg.timeout = 5
end

-- ---------------------------------------------------------------------------
print('')
print('-- a fault is a report, not an ending: the run keeps going --')
do
  -- THE RULE THIS BLOCK EXISTS FOR: a run stops when the iteration count runs out, when the TRIGGER key
  -- is pressed, or when the stop file appears. Nothing else. Every fault below used to end it.
  local plan, i = {}, nil
  for i = 1, 6 do
    plan[i] = '1,' .. i .. ',v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'
  end

  -- (a) THE RECORD STOPS BEING WRITEABLE MID-LAP. The cells keep being measured, the record is retried,
  -- and the lap still reaches its end -- because the app is still being exercised whether or not anything
  -- is writing the transcript down, and the operator is the only one who gets to decide to stop.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  brun.recretry = 2
  local nrow0 = 0
  local realrow = brec.row
  brec.row = function(s)
    nrow0 = nrow0 + 1
    -- FAIL THE WAY THE INSTRUMENT FAILS: brec.row sets stopped and returns false, which is what a pulled
    -- key produces. Faking it any other way would test a path the hardware cannot reach.
    if nrow0 == 2 then
      brec.stopped, brec.why = true, 'write failed and SOAK.csv will not reopen -- key pulled?'
      return false
    end
    return realrow(s)
  end
  local okr, whyr = brun.soak(1, 'recfail')
  brec.row = realrow
  brun.recretry = 50
  ck(okr == true and string.find(tostring(whyr), 'iteration', 1, true) ~= nil,
     'a record that stops being writeable does NOT end the run', tostring(whyr))
  ck(brun.ncell == 6, 'and every cell in the lap was still measured',
     string.format('%d cell(s)', brun.ncell))
  ck(brun.nreclost >= 1, 'and the cells nobody wrote down are counted',
     string.format('%d cell(s) unrecorded', brun.nreclost))
  ck(brun.nrecback >= 1, 'and recording came back by itself',
     string.format('%d recovery(s)', brun.nrecback))
  local sr = slurp(brec.path)
  ck(sr ~= nil and string.find(sr, 'tag=resumed', 1, true) ~= nil,
     'and the gap is declared in the file, so a reader is not told a lie by omission')
  ck(sr ~= nil and string.find(sr, 'unrecorded cell', 1, true) ~= nil,
     'with the number of cells it cost')
  -- THE SCREEN SAYS SO FOR THE REST OF THE RUN. Those cells are gone -- no later pass recovers them --
  -- so the amber outlives the fault, unlike the generator's.
  --
  -- stopwhy IS CLEARED FOR THE CHECK, because this is a claim about what the screen says WHILE the run is
  -- going: a finished run reports its ending first and rightly outranks every warning below it, which is
  -- asserted where the end-of-run screen is. Restored immediately, since leaving a run's stop reason
  -- cleared would make the next test's screen read as one still in progress.
  local savewhy = brun.stopwhy
  brun.stopwhy = nil
  local rcol, rmsg = brun.ui_status()
  brun.stopwhy = savewhy
  ck(rcol == brun.c_warn and string.find(rmsg, 'never recorded', 1, true) ~= nil,
     'and the screen keeps saying so after the record recovers', tostring(rmsg))

  -- (b) THE PLAN FILE GOES AWAY at the wrap. It holds and retries instead of parking, and comes back.
  --
  -- THE CELL CAP IS WHAT ENDS THIS ONE, and that is the assertion rather than a workaround. asking for two
  -- iterations of a plan that holds only iteration 1 wraps FOR EVER -- the end-of-plan test wraps unless
  -- the last row's iteration has reached the count -- which is correct for the indefinite run the wrap was
  -- written for, and offline, where delay() is a no-op, that is a spin rather than a wait. So the run is
  -- bounded by brun.maxcell, and the plan failure has to not be what stopped it.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  brun.maxcell = 40
  brun.holdslice, brun.holdsecs, brun.holdmax = 1, 1, 30
  local realopen, nopen = brun.planopen, 0
  brun.planopen = function()
    nopen = nopen + 1
    -- The first reopen after the wrap fails; the next succeeds, which is what a key that was briefly
    -- unreadable looks like.
    if nopen == 2 then return false end
    return realopen()
  end
  local okp, whyp = brun.soak(2, 'planfail')
  brun.planopen = realopen
  shipdefaults()
  brun.maxcell = 0
  ck(okp == true and string.find(tostring(whyp), 'plan file', 1, true) == nil,
     'a plan file that will not reopen does NOT end the run', tostring(whyp))
  ck(string.find(tostring(whyp), 'cell cap', 1, true) ~= nil,
     'it runs until something that is not a fault stops it', tostring(whyp))
  ck(brun.ncell == 40, 'and it kept measuring straight through the gap',
     string.format('%d cell(s)', brun.ncell))
  ck(nopen >= 3, 'having reopened the plan after the failed attempt',
     string.format('%d open(s)', nopen))
  local sp = slurp(brec.path)
  ck(sp ~= nil and string.find(sp, 'unreadable or empty', 1, true) ~= nil,
     'and the hold is on the key, so the gap in the timestamps is explained')
  ck(sp ~= nil and string.find(sp, 'readable again', 1, true) ~= nil,
     'as is the recovery')

  -- (c) THE TRIGGER KEY STILL ENDS IT, and that is the point of the rule rather than an exception to it:
  -- the operator is what stops a run. Pressed during a hold, which is the case that would be easiest to
  -- get wrong -- a hold that ignored the key would need the power cycle the key exists to avoid.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  bsdg.timeout = 0.05
  brun.maxsdgfail = 2
  brun.holdslice, brun.holdsecs, brun.holdmax = 1, 1, 600
  MOCKB.sdg.wedged = true
  local realhit, nhit = brun.stopkey_hit, 0
  brun.stopkey_hit = function()
    nhit = nhit + 1
    return nhit >= 4          -- not at once: let the hold start first
  end
  local okk, whyk = brun.soak(1, 'keyinhold')
  brun.stopkey_hit = realhit
  shipdefaults()
  brun.maxsdgfail = 20
  bsdg.timeout = 5
  MOCKB.sdg.wedged = false
  -- EXACTLY 'TRIGGER Pressed', because that is the whole message and the panel prints it after
  -- 'STOPPED: '. Two things ride on the literal: brun.stateword() picks the amber ABORTED state by
  -- searching the reason for bare uppercase 'TRIGGER', so a reword that drops it turns an operator stop
  -- into FINISHED in cyan -- the one thing those lines must never say about a cut-short run; and
  -- brec.finish() only supplies the lap and cell when the reason does not already carry them, so a
  -- reason that grows an 'L1C2:' prefix back would put two disagreeing cell numbers on one line.
  ck(okk == true and tostring(whyk) == 'TRIGGER Pressed',
     'the TRIGGER key ends a run even from inside a hold, and that is the whole message',
     tostring(whyk))
  -- WHAT IT WAS HOLDING FOR IS STILL RECORDED, just not in the stop reason: the run-total line carries
  -- heldsecs over nhold retry(s). Asserted here so shortening the message cannot quietly lose it.
  ck((brun.heldsecs or 0) > 0 and (brun.nhold or 0) > 0,
     'and the hold it was pressed during is still counted for the run total',
     string.format('%s s over %s retry(s)', tostring(brun.heldsecs), tostring(brun.nhold)))
  ck(brun.stopbad ~= true, 'and an operator stop is not a fault, so the screen does not go red')
end

-- ---------------------------------------------------------------------------
print('')
print('-- a lap ends when the iteration number moves --')
do
  -- THE BOUNDARY CARRIES TWO FACTS: the lap size, which is the highest cell seen in the lap just
  -- finished, and the start of the new lap's clock. One branch sets both.
  --
  -- A PLAN THAT WRAPS CANNOT TEST IT. Wrapping replays iteration 1, so the iteration number never moves
  -- and the boundary is never reached -- which is why this drive uses a plan holding two real iterations
  -- rather than reusing one of the single-iteration plans above.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,3,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '2,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '2,2,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  brun.percell = 0
  -- os.time IS STUBBED TO ADVANCE ONE SECOND PER CALL, and that is what makes the lap clock checkable by
  -- value. The real clock has one-second resolution and this drive finishes well inside a second, so a
  -- clock restarted at the boundary and one still sitting at brun.t0 hold the SAME integer -- the
  -- assertion would pass either way. Ticking every call separates them: tlap can only exceed t0 if
  -- something assigned it after the run began.
  local realtime = os.time
  local tick = realtime()
  os.time = function() tick = tick + 1; return tick end
  local okc, whyc = brun.soak(2, 'lapclock')
  os.time = realtime
  ck(okc == true, 'the two-lap drive runs to the end of the plan', tostring(whyc))
  ck(brun.tlap ~= nil and brun.t0 ~= nil and brun.tlap > brun.t0,
     'the lap clock is restarted at the boundary rather than left at the run start',
     string.format('tlap - t0 = %s', tostring((brun.tlap or 0) - (brun.t0 or 0))))
  -- THREE, LEARNED FROM THE PLAN RATHER THAN FROM A HEADER. Iteration 1 holds cells 1..3, so the lap
  -- size is 3. While the boundary goes unseen this stays 0 and every per-lap figure on the screen falls
  -- back to brun.perlap_guess(), which divides the whole file by the iteration count and cannot see a
  -- plan whose laps are not all the same length.
  ck(brun.percell == 3, 'the lap size is learned from the lap that just finished',
     string.format('percell %d', brun.percell))
  -- AND NOTHING GUESSES IT BEFORE THAT. perlap_guess used to divide brun.planrows by brun.iterwant and
  -- offer the quotient, guarded only by divisibility -- which is nearly vacuous, and which assumes the
  -- plan holds exactly the laps that were asked for. Plans are deliberately emitted with far more laps
  -- than a run will reach so they never wrap, so that assumption is false by design. Measured on the
  -- bench: a 4200-row 40-lap plan run with iterations=2 made the panel announce 2100 cells a lap, 4200
  -- total and 5.9 HOURS REMAINING for a run that stopped 19 minutes later at 210 cells.
  local keeprows, keepwant = brun.planrows, brun.iterwant
  brun.planrows, brun.iterwant = 4200, 2
  ck(brun.perlap_guess() == 0,
     'an oversized plan gets NO guessed lap size -- 4200/2 is not 2100 cells a lap',
     brun.perlap_guess())
  brun.planrows, brun.iterwant = 1720, 1
  ck(brun.perlap_guess() == 0,
     'and the lap size is never inferred from the file at all: a plan declares it or it is unknown',
     brun.perlap_guess())
  brun.planrows, brun.iterwant = keeprows, keepwant
  -- THE DECLARED FORM IS WHAT REPLACES IT, read straight into percell by nextrow.
  writeplan({'# cells-per-lap=7',
             '1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  brun.percell = 0
  brun.planclose()
  brun.planopen()
  brun.nextrow()
  ck(brun.percell == 7, 'a plan header declaring the lap size sets it before any cell runs',
     string.format('percell %d', brun.percell))
  brun.planclose()
  -- THE RENDERING HALF OF THE SAME DEFECT -- the lap line reporting the whole run's elapsed as this lap's
  -- -- is pinned where brun.screen is checked, with t0 and tlap deliberately set apart.
  shipdefaults()
end

-- ---------------------------------------------------------------------------
print('')
print('-- a waveform switch that lands late is not a missing waveform --')
do
  -- MEASURED ON HARDWARE, and it refutes what this code used to assert. ARWV performs a REAL switch only
  -- on the cells where the vector changes -- 39 of a 1677-cell lap, all at 300 Bd, the first rate in each
  -- vector's block -- and 4 of those 39 answered C1:ARWV? with the PREVIOUS name. Each succeeded when the
  -- next cell selected the same name, so the generator had it and the switch had not landed yet, while
  -- the recorded reason blamed a missing file.
  MOCKB_SDG({slow_arb = 2})       -- the new name is reported only from the 2nd ARWV? onwards
  bsdg.reset()
  bsdg.arwvtries, bsdg.arwvwait = 4, 0
  local ok1 = bsdg.select(ARB.v77, 5.0, 0.0, 96000)
  ck(ok1 == true, 'a first switch, with nothing playing yet, is accepted')
  local ok2, why2 = bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(ok2 == true, 'and a switch that reports the PREVIOUS name is retried, not failed', tostring(why2))
  ck(MOCKB.sdg.arb == string.gsub(string.gsub(ARB.v78, '^.*/', ''), '%.bin$', ''),
     'and the generator ends up playing the waveform that was asked for', tostring(MOCKB.sdg.arb))

  -- AND A GENUINELY ABSENT WAVEFORM STILL FAILS -- one wait later, and without asserting which of the two
  -- it was, because from here they are indistinguishable.
  MOCKB_SDG({refuse_arb = 'SER_Fox_8N1_x10'})
  bsdg.reset()
  local ok3, why3 = bsdg.select(ARB.v78, 5.0, 0.0, 96000)
  ck(ok3 == true, 'a waveform the generator has is still selected', tostring(why3))
  local ok4, why4 = bsdg.select('SER_Fox_8N1_x10', 5.0, 0.0, 96000)
  ck(ok4 == false and string.find(tostring(why4), 'did not land', 1, true) ~= nil,
     'while one it does not have fails, naming both possibilities', tostring(why4))
  bsdg.arwvtries, bsdg.arwvwait = 4, 0.4
  MOCKB_SDG({})
  bsdg.reset()
end

-- ---------------------------------------------------------------------------
print('')
print('-- a switch too late for the verify is recovered by sending it again --')
do
  -- THE RECORD'S OWN WORDS, from the lap AFTER bsdg.arwvtries was added:
  --   L1C173 j20 300 Bd  SDG:ARWV? still names C1:ARWV NAME SER_Hello_8N1_Drift10_x10.bin
  --                      after 4 tries selecting SER_Jitter20pct_x100
  -- So four tries at the verify are not always enough, and a fifth would not help either: the operation
  -- that recovers a late switch is SENDING THE SELECTION AGAIN, which is what the next cell did every
  -- time one was observed. The likely mechanism is the generator's own CPU-to-FPGA link, which takes
  -- about a second to load a large waveform -- so the wait needed scales with the waveform, not with
  -- anything this side can see.
  --
  -- slow_arb IS PAST bsdg.arwvtries ON PURPOSE, so the verify cannot reach it and only brun.selretry can.
  -- COUNTED AS A DELTA. The record is one append-only file holding every run this suite has driven, so an
  -- absolute count of SDG: rows is a count of the whole file -- 18 of them, from tests that are supposed
  -- to produce them. Only the rows this soak added say anything about this soak.
  local function nsdgrows()
    local L, n = lines(slurp(brec.path))
    local nsdg, nback, k = 0, 0, nil
    for k = 1, n do
      if string.find(L[k], 'SDG:', 1, true) ~= nil then nsdg = nsdg + 1 end
      if string.find(L[k], 'sdg select recovered', 1, true) ~= nil then nback = nback + 1 end
    end
    return nsdg, nback
  end

  -- THREE CELLS, NOT TWO, and the third is what makes the log stamp testable: the failure is at cell 2, so
  -- a line pushed at the top of the NEXT cell would read L1C3. Cell 3 re-selects the same name, which is
  -- the 1638-cells-a-lap case that costs one attempt.
  local function lateswitch(nsel)
    MOCKB_SDG({slow_arb = 5})
    bsdg.reset()
    bsdg.arwvwait = 0
    brun.selretry, brun.selwait = nsel, 0
    brun.msgs, brun.lastmsg, brun.lastshape, brun.lastn = nil, nil, nil, 0
    writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
               '1,2,v78,' .. ARB.v78 .. ',9600,std,5.0000,0.0000,96000,0.000',
               '1,3,v78,' .. ARB.v78 .. ',9600,std,5.0000,0.0000,96000,0.000'})
    local sdg0 = nsdgrows()
    brun.soak(1, 'late')
    local sdg1, nback = nsdgrows()
    return sdg1 - sdg0, nback, brun.nselback
  end

  local nsdg2, nback2, nsel2 = lateswitch(3)
  ck(nsdg2 == 0, 'a switch too late for the verify is no longer a stimulus failure',
     string.format('%d row(s) marked SDG:', nsdg2))
  ck(nback2 >= 1 and nsel2 == 1,
     'and the retry that recovered it is counted on the key, since the screen no longer says so',
     string.format('%d note(s), nselback=%d', nback2, nsel2))

  -- AND THE ASSERTION CAN FAIL. One attempt is the old behaviour and it has to lose the cell -- without
  -- this pair the two above would also pass against a mock that simply never misses.
  local nsdg1 = lateswitch(1)
  ck(nsdg1 == 1, 'while a single attempt loses the cell, which is what this replaces',
     string.format('%d row(s) marked SDG:', nsdg1))
  -- AND THE LOG NAMES CELL 2, THE ONE THAT FAILED. Pushed from brun.ui_show it named cell 3, because the
  -- screen is drawn before the generator runs and cell 2's own draw came too early to see the counter
  -- move. On hardware that turned a failure the record puts at L1C173 into an L1C174 on the glass -- and
  -- 173 is the first cell of a vector's block, the only kind of cell that can fail this way.
  -- SEARCHED, NOT INDEXED. The ring opens with the run's own 'started -- <IDN>' line, so a fixed index
  -- reads whichever line happens to sit there.
  local function findmsg(sub)
    local k
    for k = 1, (brun.msgs ~= nil and table.getn(brun.msgs)) or 0 do
      if string.find(brun.msgs[k].txt, sub, 1, true) ~= nil then return brun.msgs[k].txt end
    end
    return nil
  end
  local m1, m2 = findmsg('no stimulus'), findmsg('recovered')
  ck(m1 ~= nil and string.find(m1, 'L1C2 ', 1, true) ~= nil
     and string.find(m1, 'no stimulus', 1, true) ~= nil,
     'and the log line names the cell that failed, not the one after it', tostring(m1))
  -- AND THE RECOVERY IS ITS OWN LINE, AT THE CELL THAT RECOVERED. A single line reading 'generator missed
  -- 1 cell(s) and recovered' had to serve both states, and it was pushed while brun.nbadsdg was still
  -- non-zero -- so a generator failing one or two cells at a time for ever, never reaching badsdgwarn in a
  -- row, described itself as recovered the whole time.
  ck(m2 ~= nil and string.find(m2, 'L1C3 ', 1, true) ~= nil
     and string.find(m2, 'recovered', 1, true) ~= nil,
     'while the recovery is a second line, at the cell where it recovered', tostring(m2))

  -- A WEDGED GENERATOR IS NOT RETRIED, and the reason is arithmetic: three attempts at four ARWV? tries
  -- apiece, each waiting out bsdg.timeout, is a minute a cell spent proving what the first one proved.
  -- bsdg.nfail separates the two -- a stale name ARRIVES as a reply and leaves it 0, a wedge raises it.
  -- COUNTED IN ARWV NAME SENDS, not in commands: brun.sdghold's own bsdg.alive() probe is on the same
  -- socket, so a command count cannot tell a retried selection from the liveness check after it.
  MOCKB_SDG({wedged = true})
  bsdg.reset()
  bsdg.timeout, bsdg.arwvwait = 0.05, 0
  brun.selretry, brun.selwait = 3, 0
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  brun.holdslice, brun.holdsecs, brun.holdmax, brun.maxsdgfail = 1, 1, 2, 1
  MOCKB.sdg.log, MOCKB.sdg.nlog = {}, 0
  brun.soak(1, 'wedge')
  local narwv, k = 0, nil
  for k = 1, MOCKB.sdg.nlog do
    if string.find(string.upper(MOCKB.sdg.log[k]), 'ARWV NAME', 1, true) ~= nil then
      narwv = narwv + 1
    end
  end
  ck(narwv == 1, 'a generator that answers nothing is asked once, not three times over',
     string.format('%d ARWV NAME send(s) for one cell', narwv))

  bsdg.timeout, bsdg.arwvtries, bsdg.arwvwait = 5, 4, 0.4
  shipdefaults()
  MOCKB_SDG({})
  bsdg.reset()
end

-- ---------------------------------------------------------------------------
print('')
print('-- one repeating condition must not fill the five-line log --')
do
  -- MEASURED ON HARDWARE: 4 generator misses in 1578 cells, so a fortnight's 273 000 is ~690. Deduping on
  -- exact text pushes a line per increment, and five lines of 'missed 648 cell(s)' is a log with every
  -- one-off event scrolled off the top.
  brun.ui_build()
  brun.iter, brun.cell, brun.stopwhy, brun.keyarmed = 1, 0, nil, true
  brun.ncell, brun.nunexp, brun.nexp, brun.nbadsdg, brun.nevtot = 0, 0, 0, 0, 0
  brun.nreclost, brun.nsdgtot, brun.nsdgalive = 0, 0, 0
  brun.msgs, brun.lastmsg, brun.lastshape, brun.lastn = nil, nil, nil, 0
  local pushed, n = 0, nil
  for n = 1, 650 do
    brun.nsdgtot, brun.cell = n, n * 420
    local col, msg = brun.ui_status()
    if col ~= brun.c_ok and brun.newsworthy(msg) then
      brun.lastmsg = msg
      brun.msg(col, msg)
      pushed = pushed + 1
    end
  end
  ck(pushed > 4 and pushed <= 14,
     'a counter that reaches 650 pushes about ten lines, not 650',
     string.format('%d line(s)', pushed))
  -- AND A GENUINELY DIFFERENT CONDITION IS STILL PUSHED AT ONCE, which is the half that makes the
  -- suppression safe: it is the SHAPE that repeats, not the news.
  brun.nreclost = 3
  local col2, msg2 = brun.ui_status()
  local said = brun.newsworthy(msg2)
  if said then brun.lastmsg = msg2; brun.msg(col2, msg2) end
  ck(said == true, 'while a different condition appears immediately', tostring(msg2))
  ck(string.find(MD.text(brun.ui.msg[brun.msgn]) or '', 'never recorded', 1, true) ~= nil,
     'and it is the newest line, at the bottom, not lost behind the counter',
     tostring(MD.text(brun.ui.msg[brun.msgn])))
  brun.nreclost, brun.nsdgtot = 0, 0
end

-- ---------------------------------------------------------------------------
print('')
print('-- the faults that used to end a run before it started --')
do
  local plan, i = {}, nil
  for i = 1, 3 do
    plan[i] = '1,' .. i .. ',v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'
  end

  -- (a) A PLAN THAT WILL NOT OPEN AT STARTUP. This returned before the loop, which loses a fortnight to a
  -- key that was briefly unreadable at nine in the morning.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  brun.holdslice, brun.holdsecs, brun.holdmax = 1, 1, 30
  local realopen, nopen = brun.planopen, 0
  brun.planopen = function()
    nopen = nopen + 1
    if nopen == 1 then return false end        -- the startup open, and only that one
    return realopen()
  end
  local oks, whys = brun.soak(1, 'startplan')
  brun.planopen = realopen
  shipdefaults()
  ck(oks == true and string.find(tostring(whys), 'iteration', 1, true) ~= nil,
     'a plan that will not open at startup holds instead of refusing', tostring(whys))
  ck(brun.ncell == 3, 'and the lap runs once it opens', string.format('%d cell(s)', brun.ncell))

  -- (b) A RECORD THAT DIES ON THE LAST CELL. brec.stopped is tested at the TOP of a cell, so the final
  -- row's failure had no next pass to be noticed in: it was neither counted nor retried.
  MOCKB_SDG({})
  bsdg.reset()
  writeplan(plan)
  local realrow, nrow = brec.row, 0
  brec.row = function(s)
    nrow = nrow + 1
    if nrow == 3 then
      brec.stopped, brec.why = true, 'write failed twice on SOAK.csv'
      return false
    end
    return realrow(s)
  end
  local okl = brun.soak(1, 'lastcell')
  brec.row = realrow
  ck(okl == true and brun.nreclost >= 1, 'a record that fails on the LAST cell is still counted',
     string.format('%d cell(s) unrecorded', brun.nreclost))

  -- (c) THE HEADER'S OWN BYTES COUNT. Three header lines per run, per roll and per recovery went into the
  -- file and not into the budgets, so a key that failed and recovered repeatedly could pass maxfile and
  -- maxtotal while both counters said otherwise.
  brec.finish('done')
  brec.begin('bytes', 1, 'x')
  ck(brec.nbyte > 200 and brec.ntotbyte == brec.nbyte,
     'a header is charged to the file it is written to',
     string.format('%d byte(s) after begin', brec.nbyte))
  local before = brec.nbyte
  brec.stopped, brec.why = true, 'pretend'
  ck(brec.reopen() == true and brec.nbyte > before,
     'and so is the resumed header', string.format('%d -> %d', before, brec.nbyte))

  -- (d) A REOPEN WHOSE HEADER DOES NOT LAND IS NOT A RECOVERY. Marking the record live before writing it
  -- let a still-failing key report 'recording resumed' and count a recovery.
  brec.stopped, brec.why = true, 'pretend again'
  local realraw = brec.rawwrite
  brec.rawwrite = function(fh, s) return false end
  local back = brec.reopen()
  brec.rawwrite = realraw
  ck(back == false and brec.stopped == true,
     'a reopen whose header will not write reports failure, not recovery',
     string.format('reopen said %s, stopped=%s', tostring(back), tostring(brec.stopped)))
  brec.finish('done')
end

-- ---------------------------------------------------------------------------
print('')
print('-- no popups: the checks that run every cell must not post events --')
do
  MOCKB_SDG({})
  bsdg.reset()
  -- file.open ON A MISSING FILE POSTS AN EVENT on this instrument, and mock_display.lua models that.
  -- brun.stopped() runs once per cell, so probing for an absent STOP.TXT that way is 86 popups in a
  -- smoke and ~120 000 across eight days. It reads the DIRECTORY listing instead.
  MD.rmfile(brun.stoppath)
  eventlog.clear()
  local i
  for i = 1, 20 do brun.stopped() end
  ck(brun.stopped() == false, 'with no STOP.TXT the run continues')
  ck(eventlog.getcount() == 0,
     'and twenty stop-file checks post NO events -- the directory is listed, not a missing file opened',
     tostring(eventlog.getcount()))
  droptouch(brun.stoppath)
  ck(brun.stopped() == true, 'and a STOP.TXT that IS there is still found by the listing')
  MD.rmfile(brun.stoppath)

  -- READING PAST EOF posts 2201. The plan's own '# rows=N' header is what lets the loop stop at the
  -- last row instead of discovering the end by running off it.
  -- WITH THE HEADER, so the count path is the one under test. Without it the assertion below passes on
  -- the fallback branch instead -- which is a check that cannot fail, and the first version of this
  -- test did exactly that.
  do
    local fh = file.open(brun.planpath, file.MODE_WRITE)
    file.write(fh, '# test plan\n# rows=1\niter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms\n')
    file.write(fh, '1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000\n')
    file.close(fh)
  end
  brun.planrows = 0
  brun.planopen()
  local r1 = brun.nextrow()
  ck(brun.planrows == 1, 'the row count is read out of the plan header', tostring(brun.planrows))
  eventlog.clear()
  local r2 = brun.nextrow()
  brun.planclose()
  ck(r1 ~= nil and r2 == nil, 'the plan ends after its last row')
  ck(eventlog.getcount() == 0,
     'and stopping at the declared count posts NO event -- nothing reads off the end',
     string.format('rows=%d events=%s', brun.planrows, tostring(eventlog.getcount())))
end

-- ---------------------------------------------------------------------------
print('')
print('-- the front panel carries the lap, the waveform, the rate and the failure rate --')
do
  -- THE EXACT STRINGS, because every field on this screen was asked for by name and a substring test
  -- would pass on a line that had lost one. Six facts in 52 characters: lap, cell, failed cells and
  -- fail rate above; vector, baud, frame format and waveform below.
  -- THE TALLIES COME OFF brun, so they are set here rather than passed: a screen handed every number it
  -- draws is a screen that can be handed a stale one, which is exactly what a soak screen must not do.
  brun.nbad, brun.ncell = 12, 1677
  brun.vcell, brun.vbad = {}, {}
  brun.screen({iter = 3, cell = 412, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  ck(MD.usertext(display.TEXT1) == 'L3C412 F12 0.7%',
     'the top line is lap, cell, failed cells and fail rate', tostring(MD.usertext(display.TEXT1)))
  ck(MD.usertext(display.TEXT2) == 'v77 9600 8N1 Fox',
     'and the bottom line is vector, baud, format and waveform',
     tostring(MD.usertext(display.TEXT2)))

  -- THE BOILERPLATE IS DROPPED, THE MEANING IS NOT. Every stored name begins 'SER_' and ends '_x10' or
  -- '_x100' and the format is its own field, so those characters cost width and say nothing -- but what
  -- is left has to still distinguish the vectors it names. v41 and v44e are both 'Hello' and are told
  -- apart by the format field; v45's inversion and v48b's drift survive in the name.
  ck(brun.wave('SER_Hello_8N1_Drift10_x10') == 'Hello_Drift10'
     and brun.fmtof('SER_Hello_8N1_Drift10_x10') == '8N1',
     'the longest name shortens to its distinguishing part', brun.wave('SER_Hello_8N1_Drift10_x10'))
  ck(brun.wave('SER_Hello_8N2_x10') == 'Hello' and brun.fmtof('SER_Hello_8N2_x10') == '8N2',
     'two stop bits are reported as the format, which is the only place they are recorded')
  ck(brun.wave('SER_Hello_8N1_Inv_x10') == 'Hello_Inv', 'an inverted line keeps saying so',
     brun.wave('SER_Hello_8N1_Inv_x10'))
  ck(brun.wave('SER_Random_07_7E1_x10') == 'Random_07'
     and brun.fmtof('SER_Random_07_7E1_x10') == '7E1', 'and 7E1 is read out of the name')
  -- NO GUESS WHERE THE NAME CARRIES NOTHING. The three LIN frames and the three jitter waveforms have
  -- no format token; an empty field is the honest answer and the line closes up around it.
  ck(brun.fmtof('SER_LIN_01_x10') == '' and brun.wave('SER_LIN_01_x10') == 'LIN_01',
     'a name with no format token gets an empty field, not an invented 8N1')
  ck(brun.cellline({vid = 'v61', baud = 9600}, 'SER_LIN_01_x10') == 'v61 9600 LIN_01',
     'and the line closes up around it', brun.cellline({vid = 'v61', baud = 9600},
                                                      'SER_LIN_01_x10'))

  -- EVERY NAME, AT THE WIDEST RATE, AGAINST THE FIRMWARE'S OWN LIMIT. Over 20 characters on TEXT1 or 32
  -- on TEXT2 and the instrument posts a warning event and shortens the line -- a box on the panel, once
  -- per cell. This is the assertion that stops that: it is measured over all 41 stored names rather
  -- than over the two a smoke happens to drive, because the two widest names (v48a, v48b) are only
  -- reached deep in a full lap.
  local widest, wname, nchecked = 0, nil, 0
  local vid, arb
  for vid, arb in pairs(barb.name) do
    local l2 = brun.cellline({vid = vid, baud = 153600}, arb)
    nchecked = nchecked + 1
    if string.len(l2) > widest then widest, wname = string.len(l2), l2 end
  end
  ck(nchecked == barb.n and widest <= MD.usertext_lim(display.TEXT2),
     'every stored name fits the bottom line at the fastest rate, unclipped',
     string.format('%d name(s), widest %d of %d: %s', nchecked, widest,
                   MD.usertext_lim(display.TEXT2), tostring(wname)))
  -- AND THE TOP LINE AT ITS WIDEST: a three-digit lap, a four-digit cell, four digits of failures and
  -- a rate of 100 %. 20 characters exactly, which is why the fields are this terse.
  brun.screen({iter = 999, cell = 9999, vid = 'v', baud = 1}, nil, 9999, 9999)
  ck(string.len(MD.usertext(display.TEXT1)) <= MD.usertext_lim(display.TEXT1)
     and MD.usertext_over(display.TEXT1) == 0,
     'and the top line fits at its widest, unclipped',
     string.format('%d of %d: %s', string.len(MD.usertext(display.TEXT1)),
                   MD.usertext_lim(display.TEXT1), tostring(MD.usertext(display.TEXT1))))

  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',19200,std,5.0000,0.0000,192000,0.000'})
  local n0 = MD.usertext_sets(display.TEXT1)
  local over0 = MD.usertext_over(display.TEXT1) + MD.usertext_over(display.TEXT2)
  brun.soak(1, 'screen')
  -- UPDATED PER CELL, not once at the start: a line frozen on cell 1 for eight days is exactly as
  -- uninformative as a blank panel, and looks the same as a wedged instrument.
  ck(MD.usertext_sets(display.TEXT1) - n0 >= 2,
     'it is rewritten for every cell, not just at the start',
     string.format('%d write(s) for 2 cells', MD.usertext_sets(display.TEXT1) - n0))
  -- THE RUN'S OWN VERDICT STAYS UP. After six days away the first question is whether it finished.
  -- AND THE APP'S OWN PANEL SAYS SO, IN GREEN. The DONE line above goes to the home screen's TEXT1, which
  -- the app's own screen covers -- so until this existed ui_end left the progress line showing the last
  -- cell it drew ('lap 6/6  cell 251/244'), which is indistinguishable from a run still working, while
  -- every other line it touched went grey. An operator across the room could not tell it had ended.
  ck(string.find(tostring(MD.text(brun.ui.prog)), 'FINISHED', 1, true) ~= nil,
     'the progress line becomes FINISHED when the run ends',
     tostring(MD.text(brun.ui.prog)))
  -- CYAN, THE SAME COLOUR AND THE SAME WORD AS THE HEADLINE. Both lines take brun.stateword, so a clean
  -- end cannot read FINISHED on one and ABORTED on the other -- and neither can wear the red that means
  -- somebody has to come and fix something.
  ck(MD.obj(brun.ui.prog) ~= nil and MD.obj(brun.ui.prog).color == brun.c_ok,
     'and it is cyan, which ABORTED (red) must not be confused with',
     string.format('%s vs c_ok %s', tostring((MD.obj(brun.ui.prog) or {}).color),
                   tostring(brun.c_ok)))
  ck(string.find(tostring(MD.usertext(display.TEXT1)), 'DONE', 1, true) ~= nil
     and string.find(tostring(MD.usertext(display.TEXT2)), 'iteration', 1, true) ~= nil,
     'and the finished run says so, with its reason',
     tostring(MD.usertext(display.TEXT1)) .. ' / ' .. tostring(MD.usertext(display.TEXT2)))
  -- NOT ONE CHARACTER OVER, ACROSS A WHOLE RUN, and counted by the run itself: brun.point clears the
  -- event log at the top of every cell, so an event the panel posts is wiped before the cell's count is
  -- read. brun.settext measures its own writes for exactly that reason.
  ck(MD.usertext_over(display.TEXT1) + MD.usertext_over(display.TEXT2) - over0 == 0
     and brun.nevpanel == 0,
     'and no line in the whole run was over length -- the panel instigated nothing',
     string.format('over=%d nevpanel=%d',
                   MD.usertext_over(display.TEXT1) + MD.usertext_over(display.TEXT2) - over0,
                   brun.nevpanel))
  -- AND THE OBJECT COUNT IS FIXED, not per cell. Object ids are never reclaimed on this instrument, so
  -- a text object per cell would exhaust the pool long before a week was up. The two swipe lines cost
  -- nothing at all -- they are the firmware's own -- and the status screen costs a fixed five texts
  -- under one screen, whatever the run's length. The status-screen block below asserts that directly.
  -- THIRTEEN SINCE THE LIVENESS SPINNER, which is a 1-character JUST_RIGHT object of its own. It could not
  -- share the headline: FONT_MEDIUM is proportional, so padding with spaces moves a glyph ~4 px each and it
  -- sat nowhere near the right edge. One object per BUILD -- not per cell -- is the price of right
  -- alignment, and the number is pinned here because the pool is never reclaimed.
  ck(MD.live(display.OBJ_TEXT) <= 13,
     'and the object count is fixed -- the swipe lines cost none, the screen a bounded thirteen',
     tostring(MD.live(display.OBJ_TEXT)))

  -- THE DETECTOR ITSELF, FIRED ON PURPOSE. Without this the two assertions above pass just as happily
  -- against a mock that cannot count, which is how a 21-character line reached the instrument in the
  -- first place: every offline test agreed with it.
  local ev0, ov0 = eventlog.getcount(), MD.usertext_over(display.TEXT1)
  display.settext(display.TEXT1, '123456789012345678901')          -- 21, one over
  ck(MD.usertext_over(display.TEXT1) - ov0 == 1 and eventlog.getcount() - ev0 == 1,
     'a 21-character top line IS caught, and charged an event, as the firmware charges one',
     string.format('over+%d ev+%d', MD.usertext_over(display.TEXT1) - ov0,
                   eventlog.getcount() - ev0))
  ck(string.len(MD.usertext(display.TEXT1)) == 20,
     'and shortened to fit, which is what the firmware does with it')
  eventlog.clear()
end

-- ---------------------------------------------------------------------------
print('')
print('-- the rate a cell asks for is the rate it gets --')
do
  MOCKB_SDG({})
  bsdg.reset()
  -- THE ONE THAT GOT AWAY WITH IT FOR A WHOLE PROJECT. brun.point set sdec.fs and nothing else, and
  -- hw_config() resets sdec.fs to fs_default -- 1 MS/s -- whenever no baud is locked. So EVERY unlocked
  -- capture ran at 1 MS/s: measured, 108 of 108 cells in a hardware lap, and 1139 of 1139 offline. At
  -- 1 MS/s the 20 000-sample buffer is 20 ms, which is 19 bytes at 9600 baud against 240 at the rate
  -- asked for, and the judge's 'too few trusted bytes' was the harness starving itself.
  --
  -- THE ASSERTION IS THE EFFECTIVE RATE, not the assignment. Testing that fs_want was set would pass
  -- against a build that set it and then had it ignored, which is the whole failure mode: an assignment
  -- that looks right and is discarded one call later.
  local want = sdec.pick_fs(9600, 8)
  local p = brun.point(want, 9600, false)
  ck(p.fs ~= nil and math.abs(p.fs - want) / want < 0.05,
     'an UNLOCKED capture runs at the rate it was given, not at fs_default',
     string.format('asked %g, captured %s (fs_default %g)', want, tostring(p.fs), sdec.fs_default))
  -- AND THE PAYLOAD IS THE POINT OF IT. The same window at the right rate holds an order of magnitude
  -- more bytes, which is the difference between a judged cell and an inconclusive one.
  ck(p.ran == true and (p.nf or 0) > 40,
     'and it therefore returns a payload worth judging, not a 20 ms sliver',
     string.format('%s frame(s) at %g Sa/s', tostring(p.nf), tostring(p.fs)))
  -- A LOCKED capture picks its own rate from the locked baud and must not regress either.
  local p2 = brun.point(want, 9600, true)
  ck(p2.ran == true and p2.fs ~= nil, 'a locked capture still works', tostring(p2.fs))
end

-- ---------------------------------------------------------------------------
print('')
print('-- every plan rate is captured at a rate that can see it --')
do
  -- THE ARITHMETIC IS NOT ENOUGH, AND THIS IS WHAT THAT COST. pick_fs(300, 8) asks for 2500 Sa/s; the
  -- instrument captured at 1 000 000, measured from its own timestamps, which is 3333 samples a bit --
  -- so ua_probe's 4000-sample window spanned 1.2 bit times and no format could be fitted to it. Every
  -- unexpected failure below 2400 baud in a 117-cell hardware lap was this one thing.
  --
  -- SO THE PROPERTY UNDER TEST IS PHYSICAL, not a rate comparison: at the rate a cell will be captured
  -- at, does the probe window hold enough BIT TIMES to contain a frame? A 10-bit frame needs ten, and
  -- anything under about twenty leaves no room for the anchor the walk starts from.
  local rates = {300, 379, 600, 630, 1200, 1207, 1800, 2400, 4800, 9600, 19200, 38400, 57600,
                 115200, 153600, 250000}
  local worst, wb, k = 1e9, nil, nil
  for k = 1, table.getn(rates) do
    local b = rates[k]
    local fs = sdec.pick_fs(b, 8)
    if fs < brun.minfs then fs = brun.minfs end
    local bits = sdec.ua_probe_n / (fs / b)
    if bits < worst then worst, wb = bits, b end
  end
  ck(worst >= 20, 'the probe window holds at least twenty bit times at every rate the plan drives',
     string.format('worst %.1f bit(s) at %s baud', worst, tostring(wb)))
  -- AND THE FLOOR IS A RATE THE APP ITSELF USES. serial_app's probe ladder bottoms at 10 kSa/s because
  -- 20 000 samples there is 2 s -- sixty frames at 300 baud -- so this is not a new claim about the
  -- hardware, it is the one the app already relies on.
  local inladder, j = false, nil
  for j = 1, table.getn(sdec.probe_fs) do
    if sdec.probe_fs[j] == brun.minfs then inladder = true end
  end
  ck(inladder, 'and the rate floor is one the app already captures at', tostring(brun.minfs))
end

-- ---------------------------------------------------------------------------
print('')
print('-- the status screen: what it says, and what its colours claim --')
do
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',19200,std,5.0000,0.0000,192000,0.000'})
  -- SIX OBJECTS, AND THE COUNT IS THE POINT. Display object ids are never reclaimed on this firmware, so
  -- a screen that costs one object per cell exhausts the pool inside a lap and display.create then
  -- returns nil in silence. This asserts the screen is built once and never grows.
  brun.ui_destroy()
  local live0 = MD.live(display.OBJ_TEXT)
  local ok = brun.ui_build()
  ck(ok == true and brun.ui ~= nil and brun.ui.n == 14,
     'the screen is fourteen objects, built once -- thirteen plus the liveness spinner', string.format('ok=%s n=%s', tostring(ok),
                                                             tostring(brun.ui and brun.ui.n)))
  brun.soak(1, 'uiscreen')
  ck(MD.live(display.OBJ_TEXT) - live0 == 13,
     'and a whole run adds no more of them -- settext only, per cell',
     string.format('%d text object(s)', MD.live(display.OBJ_TEXT) - live0))

  -- EVERY FIELD THE OPERATOR ASKED FOR, and n-of-m rather than a bare index: 'cell 412' says nothing
  -- about how much is left, which is the question a soak screen exists to answer.
  -- THE LAP SIZE IS NOT brun.planrows, and this is the assertion that would have caught it: planrows is
  -- the whole FILE, so a 210-lap plan read 'cell 114 of 279930 (0 %)' on the instrument and the
  -- hours-remaining figure came out 210x too large.
  brun.percell, brun.iterwant, brun.ncell = 1677, 210, 412
  brun.screen({iter = 3, cell = 412, vid = 'v48b', baud = 153600}, 'SER_Hello_8N1_Drift10_x10')
  local prog, tim = MD.text(brun.ui.prog), MD.text(brun.ui.time)
  local stim, fail = MD.text(brun.ui.stim), MD.text(brun.ui.fail)
  -- LABELLED AND CAPITALISED, EVERY FIELD. 'Lap:' anchors the start of the line, and the four labels are
  -- what let the eye find a field on a line read across the glass rather than counting numbers along it.
  ck(string.find(prog, 'Lap: 3/210', 1, true) == 1
     and string.find(prog, 'Cell 412/1677', 1, true) ~= nil
     and string.find(prog, '(25%)', 1, true) ~= nil,
     'the progress line is lap n of m, cell n of the LAP, and the share of the lap', prog)
  -- AND THE WHOLE RUN, on the time line: 210 x 1677 = 352 170 cells, of which 412 is 0.1 %.
  ck(string.find(tim, '412/352170 c', 1, true) ~= nil
     and string.find(tim, '(0.1%)', 1, true) ~= nil,
     'and the time line carries cells done out of the whole run, with its share', tim)
  -- AND IT WITHHOLDS THE PROJECTED TOTAL IT CANNOT COMPUTE. This scenario has no rate yet, so there is no
  -- ' of <total>' field and no 's/c' field either. Asserting the ABSENCE matters here: the old form of this
  -- check looked for ' of ' and was satisfied by the ' of ' inside '412 of 352170 cells', so it passed
  -- without ever testing the elapsed-of-total field. Shortening that count to '412/352170 c' removed the
  -- accidental match and exposed it.
  ck(string.find(tim, 'Total: ', 1, true) == 1 and string.find(tim, ' of ', 1, true) == nil
     and string.find(tim, 's/c', 1, true) == nil,
     'the time line withholds a projected total and a rate until a rate exists', tim)

  -- HOW LONG THIS LAP HAS TO RUN, which is the field the operator acts on rather than reads: a run ends
  -- with the TRIGGER key, and stopping nine tenths of the way through a lap discards that lap as far as
  -- whole-laps-completed goes. One hour over 412 cells is 8.74 s a cell, so the 1265 cells left in the lap
  -- are 3.1 h and the 351 758 left in the run are 853.9 h. BOTH SCOPES, ON THEIR OWN LINES: two remaining
  -- times a space apart on one line would be two numbers labelled 'left' meaning different things.
  -- 8.737864 s a cell: the 1265 cells left in the lap are 3.1 h, and 352 170 cells at that rate is a
  -- 854.8 h run. Pinned to the digit, because both figures come off the SAME rate and a layout change that
  -- silently re-derived one of them from something else would still look plausible.
  -- THE TWO CLOCKS ARE SET APART, which is what makes this a test of SCOPE and not merely of format:
  -- with t0 and tlap equal, a lap clock still sitting at the run's start satisfies the assertion exactly
  -- as a correct one does. The run has been going an hour and this lap for half of it, so the lap line
  -- must say 0.5h while the total line says 1.0h. The rate still comes off t0, so 'left' and the
  -- projection below are unchanged.
  brun.t0, brun.tlap = os.time() - 3600, os.time() - 1800
  brun.screen({iter = 3, cell = 412, vid = 'v48b', baud = 153600}, 'SER_Hello_8N1_Drift10_x10')
  local prog2, tim2 = MD.text(brun.ui.prog), MD.text(brun.ui.time)
  ck(string.find(prog2, 'Ran: 0.5h Left: 3.1h', 1, true) ~= nil,
     'the lap line says how long THIS lap has run and has left', prog2)
  ck(string.find(tim2, 'Total: 1.0h of 854.8h', 1, true) ~= nil,
     'while the total line is the run: elapsed of what the whole run will take', tim2)
  -- AND IT FITS AT ITS WIDEST, which is what the firmware punishes: over 58 characters it clips the field
  -- at the END of the line, and the countdown is now the field at the end. Two extremes -- the last cell of
  -- the last lap, and a run ten times slower than any measured so that the countdown needs two figures.
  local wide, wtxt, kk = 0, nil, nil
  local ext = {{it = 210, ce = 1677, nc = 352170, el = 783000},   -- the last cell of the last lap
               {it = 210, ce = 1000, nc = 1000, el = 70000}}      -- ten times slower: two-figure hours
  for kk = 1, table.getn(ext) do
    brun.ncell = ext[kk].nc
    brun.t0, brun.tlap = os.time() - ext[kk].el, os.time() - ext[kk].el
    brun.screen({iter = ext[kk].it, cell = ext[kk].ce, vid = 'v48b', baud = 153600},
                'SER_Hello_8N1_Drift10_x10')
    local jj
    for jj = 1, 2 do
      local t = MD.text(jj == 1 and brun.ui.prog or brun.ui.time)
      if t ~= nil and string.len(t) > wide then wide, wtxt = string.len(t), t end
    end
  end
  ck(wide <= 58, 'and both lines still fit the glass with four times on them',
     string.format('widest %d of 58: %s', wide, tostring(wtxt)))
  brun.ncell = 412
  brun.t0, brun.tlap = os.time() - 3600, os.time() - 3600
  brun.screen({iter = 3, cell = 412, vid = 'v48b', baud = 153600}, 'SER_Hello_8N1_Drift10_x10')
  ck(string.find(stim, 'v48b', 1, true) ~= nil and string.find(stim, '153600 Bd', 1, true) ~= nil
     and string.find(stim, '8N1', 1, true) ~= nil
     and string.find(stim, 'SER_Hello_8N1_Drift10_x10', 1, true) ~= nil,
     'the stimulus line is the vector, the rate, the format and the waveform in full', stim)
  -- LABELLED. A bare percentage on a status screen is a number whose meaning has to be guessed, and the
  -- guess that matters -- bytes wrong -- is not what it measures.
  local vfail = MD.text(brun.ui.vfail)
  ck(string.find(fail, 'Refusals: Allowed', 1, true) == 1
     and string.find(fail, 'Unexpected', 1, true) ~= nil
     and string.find(vfail, 'Vec: v48b', 1, true) == 1
     and string.find(vfail, ' bad ', 1, true) ~= nil,
     'the counts are split into refusals that are allowed and refusals that are not', fail .. ' / '
     .. vfail)
  -- BRIGHT, DIM, BRIGHT, DIM, BRIGHT, DOWN THE GLASS. Five 58-character lines at a 34 px pitch is a block
  -- the eye loses its place in on the way across, and alternating white and grey gives each line something
  -- to be held by. ASSERTED AS A PATTERN, not one line at a time, because the defect is two ADJACENT rows
  -- taking the same colour -- which is what a single-line assertion cannot see.
  local rows = {{brun.ui.prog, brun.c_val}, {brun.ui.time, brun.c_lab}, {brun.ui.stim, brun.c_val},
                {brun.ui.fail, brun.c_lab}, {brun.ui.vfail, brun.c_val}}
  local rk, rbad, rgot = nil, nil, nil
  for rk = 1, table.getn(rows) do
    local o, cgot = MD.obj(rows[rk][1]), nil
    if o ~= nil then cgot = o.color end
    if cgot ~= rows[rk][2] then rbad, rgot = rk, cgot end
  end
  ck(rbad == nil, 'and the five body lines alternate bright and dim down the glass',
     rbad == nil and 'white grey white grey white'
     or string.format('row %d is %s, wanted %s', rbad, tostring(rgot), tostring(rows[rbad][2])))
  -- AND THE ERROR LIGHT IS RED ONLY WHEN A REFUSAL WAS NOT ALLOWED. brun.nbad is raised on the same two
  -- paths that raise one of nexp/nunexp, so nbad == nexp means every failure so far was a vector barb.loud
  -- excuses, and nbad > nexp means at least one cell came back empty when it should not have. An absolute
  -- ceiling cannot say that: refusing is the right answer on seven of the plan's vectors, so a fixed
  -- handful goes red in the first minutes of a healthy soak.
  local sv_b, sv_x = brun.nbad, brun.nexp
  brun.nbad, brun.nexp = 0, 0
  local e0, c0 = brun.errsline()
  brun.nbad, brun.nexp = 40, 40
  local e1, c1 = brun.errsline()
  brun.nbad, brun.nexp = 41, 40
  local e2, c2 = brun.errsline()
  ck(c0 == brun.c_good and c1 == brun.c_warn and c2 == brun.c_bad
     and string.find(e1, 'Errors: 40', 1, true) == 1,
     'the error count is green at none, amber while every one was allowed, red past that',
     string.format('%s/%s  %s/%s  %s/%s', e0, tostring(c0), e1, tostring(c1), e2, tostring(c2)))
  brun.nbad, brun.nexp = sv_b, sv_x
  -- AND THE VECTOR LINE FITS THE GLASS AT COUNTS NO RUN CAN EXCEED, which is the whole reason its three
  -- reason fields are initials. It is the widest line on the screen and it is NOT passed through brun.fit,
  -- so going over does not truncate tidily -- the firmware drops whatever crosses 798 px, and the field at
  -- the end is the one that goes. Driven at every cell of the biggest plan failing on one vector: five
  -- figures either side of 'of' and six in each reason count, which no plan can reach but bounds them all.
  local sv_i, sv_l, sv_sw = brun.nidle, brun.nlevels, brun.nswing
  local sv_vc, sv_vb = brun.vcell, brun.vbad
  brun.nidle, brun.nlevels, brun.nswing = 352170, 352170, 352170
  brun.vcell, brun.vbad = {v48b = 99999}, {v48b = 99999}
  brun.screen({iter = 210, cell = 1677, pos = 1677, vid = 'v48b', baud = 153600},
              'SER_Hello_8N1_Drift10_x10')
  local vwide = tostring(MD.text(brun.ui.vfail))
  -- THE FIGURES MUST BE ON THE LINE, not merely the line short enough. A length test alone passes if the
  -- three reason fields are dropped or come back as stale zeroes -- shorter is not better here, and a
  -- test that cannot fail that way is worse than no test.
  ck(string.len(vwide) <= brun.panelw
     and string.find(vwide, 'I352170', 1, true) ~= nil
     and string.find(vwide, 'L352170', 1, true) ~= nil
     and string.find(vwide, 'S352170', 1, true) ~= nil
     and string.find(vwide, '99999 of 99999', 1, true) ~= nil,
     'and the vector line carries all six figures and still fits -- why the reasons are initials',
     string.format('%d of %d: %s', string.len(vwide), brun.panelw, vwide))
  -- AND THE END-OF-RUN VERSION OF THAT ROW, which carries five run totals rather than three and spells
  -- them out. Same widest case, same glass.
  brun.stopwhy, brun.stopbad = '4 iteration(s) complete', false
  brun.nwhyother = 352170
  brun.ui_end()
  local ewide = tostring(MD.text(brun.ui.vfail))
  brun.stopwhy, brun.nwhyother = nil, 0
  ck(string.len(ewide) <= brun.panelw
     and string.find(ewide, 'other 352170', 1, true) ~= nil,
     'and the ending diagnostic row keeps its last field at six-figure totals',
     string.format('%d of %d: %s', string.len(ewide), brun.panelw, ewide))
  brun.nidle, brun.nlevels, brun.nswing = sv_i, sv_l, sv_sw
  brun.vcell, brun.vbad = sv_vc, sv_vb
  -- THE HEADLINE, WHICH IS THE ONLY PERCENTAGE ON THE SCREEN. 100 % means nothing unexpected has
  -- happened; every point below it is a cell that came back empty when it should not have.
  --
  -- stopwhy IS CLEARED FIRST, because a run that has ENDED reports its ending and nothing else -- which
  -- is right, and which quietly made this block's last assertion vacuous until it was cleared here.
  brun.stopwhy, brun.stopbad = nil, false
  -- NOTHING BUT A CELL COUNT BEFORE THERE ARE ENOUGH CELLS TO DIVIDE BY. One unexpected refusal on cell 1
  -- is 0.0 % health, and a headline that opens red on a healthy instrument is a headline nobody believes
  -- by the third day.
  brun.ncell, brun.nunexp, brun.nexp = 1, 1, 0
  local hl0, hcol0 = brun.healthline()
  ck(string.find(hl0, 'of 100 cells', 1, true) ~= nil and hcol0 == brun.c_ok,
     'the headline shows no figure, and no alarm, until 100 cells have run', hl0)
  -- BUT A HARD FAULT IS NOT A SAMPLE-SIZE QUESTION. A generator silent by cell 3 is red at once.
  brun.nbadsdg = brun.badsdgwarn
  local hl1, hcol1 = brun.healthline()
  ck(hcol1 == brun.c_bad, 'while a silent generator is red from the third cell, figure or no figure', hl1)
  brun.nbadsdg = 0
  -- THE BAND THAT MATTERS IS WHERE A REAL LAP SITS, and the measurement of that moved by fourteen points
  -- when brun.point stopped capturing 20 ms at 1 MS/s regardless of what it asked for. A lap driven at the
  -- rate it requests reads 1 unexpected cell in 586 and 2 in the high hundreds -- about 0.3 %, or 99.7 %
  -- health -- so THREE unexpected cells in 400 is what 'working' looks like and it has to be green.
  brun.ncell, brun.nunexp, brun.nexp = 400, 3, 78
  local hl, hcol = brun.healthline()
  ck(hl == 'Health: 99.25%' and hcol == brun.c_good,
     'the headline is one health figure, and the rate a working lap runs at is green', hl)
  brun.nunexp = 0
  hl, hcol = brun.healthline()
  ck(hl == 'Health: 100.00%' and hcol == brun.c_good,
     'and 100 % with 78 ALLOWED refusals is green', hl)
  -- THE TRIP ITSELF, ASSERTED AT THE BOUNDARY. Four in 400 is exactly brun.healthwarn, and the comparison
  -- is <=, so the threshold value is amber rather than green. Worth pinning: a band tested only well
  -- inside and well outside cannot tell which side of it the boundary falls on, and the boundary is the
  -- only value an operator will ever argue about.
  brun.nunexp = 4
  hl, hcol = brun.healthline()
  ck(hl == 'Health: 99.00%' and hcol == brun.c_warn,
     'exactly at the threshold is amber, not green', hl)
  -- AND THE FIGURE THAT USED TO BE THE STANDARD IS NOW AMBER, which is the whole point of moving it: 92 %
  -- was measured on laps that were starving the decoder of payload, so treating it as healthy would be
  -- carrying the harness bug forward as a specification.
  brun.nunexp = 32
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_warn, 'a 92 % lap -- what a STARVED lap read -- is no longer called healthy', hl)
  brun.nunexp = 80
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_warn, 'while 80 % is amber -- worse than a good lap', hl)
  brun.nunexp = 300
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_bad, 'and 25 % health is red', hl)
  -- AND IT NEVER LOOKS BETTER THAN THE DETAIL BELOW IT: a silent generator is red on the bottom line, so
  -- a green headline above it would be the screen contradicting itself.
  brun.nunexp, brun.nbadsdg = 0, brun.badsdgwarn
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_bad, 'and 100 % health still reads red while the generator is silent', hl)
  brun.nbadsdg = 0
  -- EVERY LINE FITS THE GLASS AT FONT_MEDIUM. A medium character advances ~13.4 px and the usable width
  -- is about 780, so 58 characters is the budget; over it, the firmware simply clips and the field that
  -- falls off is the one at the end. Checked at the widest values rather than the ones a test happens to
  -- set, which is how the 21-character swipe line got shipped.
  local widest, wname, kk = 0, nil, nil
  for kk = 1, brun.ui.n do
    local t = MD.text(brun.ui.all[kk])
    if t ~= nil and string.len(t) > widest then widest, wname = string.len(t), t end
  end
  ck(widest <= 58, 'and no line is wider than the glass holds at FONT_MEDIUM',
     string.format('widest %d of 58: %s', widest, tostring(wname)))

  -- THE COLOURS ARE A CLAIM ABOUT WHETHER TO WALK OVER, so each one is asserted against the state that
  -- should produce it. Without this the whole traffic light is decoration.
  local col, msg = brun.ui_status()
  ck(col == brun.c_ok, 'a finished run is the panel blue, not red -- it did what it was asked',
     tostring(msg))
  -- AND WHILE IT RUNS IT SAYS HOW TO STOP IT. A stop control nobody knows about is not a stop control.
  local swhy = brun.stopwhy
  brun.stopwhy, brun.keyarmed = nil, true
  local _, run = brun.ui_status()
  ck(string.find(run, 'TRIGGER', 1, true) ~= nil, 'and a running soak says the TRIGGER key stops it',
     tostring(run))
  brun.stopwhy = swhy
  brun.nsdgtot, brun.stopwhy = 2, nil
  col, msg = brun.ui_status()
  ck(col == brun.c_warn, 'a generator that missed a cell and recovered is amber', tostring(msg))
  brun.nbadsdg = brun.badsdgwarn
  col, msg = brun.ui_status()
  ck(col == brun.c_bad and string.find(msg, 'ower cycle', 1, true) ~= nil,
     'a generator silent for several cells is RED and says what to do', tostring(msg))
  brun.nbadsdg, brun.nsdgtot = 0, 0
  brun.nevtot = 1
  col, msg = brun.ui_status()
  ck(col == brun.c_bad and string.find(msg, 'EVENT', 1, true) ~= nil,
     'and one event posted anywhere is RED -- that is a message on the panel', tostring(msg))
  brun.nevtot = 0
  -- THE RATE THAT MOVES THE LIGHT IS THE UNEXPECTED ONE. A third of a healthy lap refuses on purpose,
  -- so a light wired to the raw rate is amber on a working instrument -- measured, it was.
  brun.ncell, brun.nbad, brun.nunexp, brun.nexp = 100, 60, 50, 10
  col, msg = brun.ui_status()
  ck(col == brun.c_bad, 'half the cells refusing UNEXPECTEDLY is RED', tostring(msg))
  brun.nunexp = 30
  col, msg = brun.ui_status()
  ck(col == brun.c_warn, 'and 30 % unexpected is amber -- borderline, not broken', tostring(msg))
  -- THE CASE THAT WAS GETTING THIS WRONG: 60 refusals in 100 cells, but every one of them on a vector
  -- the plan allows to refuse. That is a healthy run and must read as one.
  brun.nbad, brun.nunexp, brun.nexp = 60, 5, 55
  col, msg = brun.ui_status()
  ck(col == brun.c_ok, 'while 60 % refusing where refusing is CORRECT is the blue of a healthy run',
     tostring(msg))
  -- AND NOT BEFORE THERE IS ENOUGH TO JUDGE ON: two failures out of three cells is 67 %, and means
  -- nothing at all.
  brun.ncell, brun.nbad, brun.nunexp = 3, 2, 2
  col, msg = brun.ui_status()
  ck(col == brun.c_ok, 'a rate over few cells makes no claim', tostring(msg))

  -- EVERY STATUS MESSAGE, AT ITS WIDEST, AGAINST THE GLASS. The width test above only sees whichever
  -- state the run happened to leave behind -- which is the healthy one -- so the alarm lines went out at
  -- 66 to 90 characters and clipped away the half that says what to do about it. Each state is driven
  -- here on purpose, with the widest numbers it can carry.
  local states = {
    {why = 'the generator failed 20 cells in a row: no reply to C1:ARWV? within 5 s', bad = true},
    {why = '1 iteration(s) complete'},
    {why = 'TRIGGER Pressed'},
    {nbadsdg = 9999}, {nevtot = 99999},
    {ncell = 9999, nbad = 9999, nunexp = 9999},      -- 100 % unexpected: the red rate
    {ncell = 9999, nbad = 3000, nunexp = 3000},      -- amber
    {nsdgtot = 9999},                                -- amber, recovered
    {evshed = 'progress push'},
    {},                                              -- healthy: the line the operator reads all week
  }
  local si, worst, wmsg = nil, 0, nil
  for si = 1, table.getn(states) do
    local st = states[si]
    brun.stopwhy, brun.stopbad = st.why, st.bad or false
    brun.nbadsdg, brun.nevtot = st.nbadsdg or 0, st.nevtot or 0
    brun.ncell, brun.nbad, brun.nunexp = st.ncell or 100, st.nbad or 0, st.nunexp or 0
    brun.nsdgtot, brun.evshed = st.nsdgtot or 0, st.evshed
    brun.keyarmed = true
    local _, m = brun.ui_status()
    if string.len(m) > worst then worst, wmsg = string.len(m), m end
  end
  ck(worst <= brun.panelw, 'every status message fits the glass, including the alarms',
     string.format('widest %d of %d: %s', worst, brun.panelw, tostring(wmsg)))
  brun.stopwhy, brun.stopbad, brun.evshed = nil, false, nil
  brun.nbadsdg, brun.nevtot, brun.nsdgtot = 0, 0, 0
  brun.ncell, brun.nbad, brun.nunexp = 100, 0, 0
  brun.keyarmed = true
  -- THE HEADLINE IS THE WHOLE ANSWER TO 'HOW IS IT', so all three fields are asserted together: a health
  -- figure to two decimals, the run's state in a word, and the heap.
  brun.screen({iter = 1, cell = 200, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  local hl1 = tostring(MD.text(brun.ui.health))
  ck(string.find(hl1, 'Health: 100.00%', 1, true) == 1
     and string.find(hl1, ' - RUNNING', 1, true) ~= nil,
     'the headline is the health figure to two decimals and the run state in a word', hl1)
  -- THE HEAP, CHECKED AS A SHAPE AND NEVER AS A VALUE: 5.0.2's gcinfo() counts whole kBytes and 5.5's
  -- collectgarbage('count') carries a fraction, so the two interpreters cannot print this field alike, and
  -- the figure moves with every allocation the draw itself makes.
  ck(string.find(hl1, ' %- Heap: %d+%.%dK') ~= nil and string.len(hl1) <= brun.panelw,
     'with the heap after it, to one decimal, on the line read first',
     string.format('%d of %d: %s', string.len(hl1), brun.panelw, hl1))
  -- AND THE HEAP STANDS ASIDE ON A DIAGNOSTIC RUN, which carries a heap of its own as `mem`. The headline
  -- plus the heap is 41 characters of the 58 the glass holds and a --timing run's flags are 31 more, so
  -- showing both clips the flag string -- the failure diagflags exists to have fixed.
  local sv_t, sv_m, sv_s = brun.timing, brun.memk, brun.nspinlast
  brun.timing, brun.memk, brun.nspinlast = true, 2861, 10
  brun.screen({iter = 1, cell = 200, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  local hl2 = tostring(MD.text(brun.ui.health))
  ck(string.find(hl2, 'Heap:', 1, true) == nil
     and string.find(hl2, 'diag: timing', 1, true) ~= nil
     and string.find(hl2, 'mem2861k', 1, true) ~= nil
     and string.len(hl2) <= brun.panelw,
     'and stands aside on a diagnostic run, whose own flags already carry one',
     string.format('%d of %d: %s', string.len(hl2), brun.panelw, hl2))
  brun.timing, brun.memk, brun.nspinlast = sv_t, sv_m, sv_s
  -- THE HEAP BANDS, THROUGH THE ONE SEAM THAT EXISTS OFFLINE. gcinfo() is absent under 5.5, so
  -- brun.heapsetk returns nil on the host and the field has no opinion -- correct, and it would leave the
  -- bands untested on BOTH interpreters, the instrument's included, since nothing offline can produce a
  -- threshold. Stubbing that one function is the honest way in: its contract is 'the live set in kB, or nil
  -- when this interpreter cannot say', and the four answers it can give are the whole of the colour rule.
  --
  -- THE BAND IS ON THE SET, NOT ON THE PRINTED COUNT, which is the point being pinned: the count is a
  -- sawtooth between the set and twice the set, so a band on it fires on the tooth.
  local realset = brun.heapsetk
  brun.heapsetk = function() return 2600 end
  local _, hc0 = brun.heapfield()
  brun.heapsetk = function() return 3001 end
  local _, hc1 = brun.heapfield()
  brun.heapsetk = function() return 3501 end
  local _, hc2 = brun.heapfield()
  brun.heapsetk = function() return nil end
  local ht3, hc3 = brun.heapfield()
  ck(hc0 == nil and hc1 == brun.c_warn and hc2 == brun.c_bad and hc3 == nil
     and string.find(ht3, 'Heap:', 1, true) ~= nil,
     'the heap colours on the live set -- clear under 3000, amber over it, red over 3500',
     string.format('%s %s %s %s / %s', tostring(hc0), tostring(hc1), tostring(hc2), tostring(hc3),
                   ht3))
  -- AND A RED HEAP OUTRANKS A GREEN HEALTH FIGURE. A run whose every cell is passing is exactly the case
  -- this field exists for: nothing else on the screen can see the allocator coming.
  brun.heapsetk = function() return 3600 end
  local hlh, hlc = brun.headline(false)
  brun.heapsetk = realset
  ck(hlc == brun.c_bad,
     'and a red heap makes the headline red on a run whose cells are all passing', hlh)
  -- THE FOUR STATE WORDS AND THEIR FOUR COLOURS, which is what the headline is read for from across the
  -- room: cyan while there is nothing to judge yet, green while it runs and the figure is good, red for a
  -- run that gave up, cyan again for one that finished the laps it was asked for. The operator's own
  -- TRIGGER press is AMBER -- it is how every soak ends, and red is a request for somebody to come and fix
  -- something, so the normal ending must not wear it.
  local sv_c, sv_w, sv_bad = brun.ncell, brun.stopwhy, brun.stopbad
  brun.stopwhy, brun.stopbad, brun.ncell = nil, false, 0
  local w1, k1 = brun.statesuffix()
  brun.ncell = 200
  local w2, k2 = brun.statesuffix()
  brun.stopwhy, brun.stopbad = 'no reply to C1:ARWV? within 5 s', true
  local w3, k3 = brun.statesuffix()
  brun.stopwhy, brun.stopbad = 'TRIGGER Pressed', false
  local w4, k4 = brun.statesuffix()
  brun.stopwhy = '4 iteration(s) complete'
  local w5, k5 = brun.statesuffix()
  ck(w1 == ' - STARTING' and k1 == brun.c_ok and w2 == ' - RUNNING' and k2 == brun.c_good
     and w3 == ' - ABORTED' and k3 == brun.c_warn and w4 == ' - ABORTED' and k4 == brun.c_warn
     and w5 == ' - FINISHED' and k5 == brun.c_ok,
     'the headline state is STARTING, RUNNING, ABORTED or FINISHED, in four colours',
     w1 .. w2 .. w3 .. w4 .. w5)
  -- AND THE CALL TO ACTION RIDES THE ERROR COUNT, IN CAPITALS. There is no prompt row -- the stop control
  -- is in the screen title, which never scrolls -- so the one instruction that has to interrupt is
  -- appended to the line that has already gone red. NOTHING while the run is healthy, and nothing once it
  -- has ended: a run that is over has nothing to abort.
  brun.stopwhy, brun.stopbad, brun.keyarmed = nil, false, true
  brun.ncell, brun.nbad, brun.nexp, brun.nunexp = 200, 0, 0, 0
  local q1 = brun.stopnag()
  brun.nevtot = 1                              -- an event posted: the traffic light goes red
  local e3, c3 = brun.errsline()
  -- THE UNARMED WARNING OUTRANKS THE ABORT, because telling an operator to press a key nothing will read
  -- is worse than saying nothing: brun.keyarmed is the result of stopkey_setup(), which can fail.
  brun.keyarmed = false
  local e4, c4 = brun.errsline()
  ck(q1 == '' and string.find(e3, 'ABORT NOW WITH TRIGGER BUTTON', 1, true) ~= nil
     and c3 == brun.c_bad
     and string.find(e4, 'CUT POWER TO STOP', 1, true) ~= nil and c4 == brun.c_bad
     and string.len(e3) <= brun.panelw and string.len(e4) <= brun.panelw,
     'a red run says ABORT NOW on the error line, and an unarmed stop key says cut power',
     e3 .. ' / ' .. e4)
  brun.keyarmed, brun.nevtot = true, 0
  brun.ncell, brun.stopwhy, brun.stopbad = sv_c, sv_w, sv_bad
  -- THE ALARM MUST NOT BE ABLE TO TAKE THE ERROR LINE'S PLACE. The line that says what to do about a red
  -- run is the error count, and the alarm text goes to the log beneath it -- so an alarm arriving must not
  -- cost the operator the one instruction they can act on.
  brun.msgs, brun.lastmsg = nil, nil
  brun.nsdgtot, brun.ncell = 1, 200
  -- brun.screen does NOT set brun.iter/brun.cell -- brun.soak does, before it calls screen -- and the log
  -- prefix reads those, not the row it is handed. The PLAN's lap and cell, not the run's running total,
  -- because those two numbers are what replay a cell.
  brun.iter, brun.cell = 1, 200
  brun.screen({iter = 1, cell = 200, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  brun.ui_note()
  local nt = tostring(MD.text(brun.ui.errs))
  ck(string.find(nt, 'Errors: ', 1, true) == 1
     and string.len(nt) <= brun.panelw,
     'an alarm leaves the error line alone', nt)
  local m5 = MD.text(brun.ui.msg[1])
  ck(m5 ~= nil and string.find(m5, 'generator missed', 1, true) ~= nil
     and string.find(m5, 'L1C200', 1, true) ~= nil,
     'and appears in the log below it, stamped with the time, the lap and the cell', tostring(m5))
  -- THE STAMP NAMES THE CELL THAT CAUSED THE LINE, NOT THE NEXT ONE, and that is why the push is not in
  -- brun.ui_show: the screen is drawn at the TOP of a cell, before the generator and the capture, so a
  -- fault raised its counter too late for its own draw and the following cell pushed the line. MEASURED:
  -- a stimulus failure the record puts at L1C173 reached the glass as L1C174, and 173 is the first cell
  -- of a vector's block -- the only kind that can fail this way -- while 174 is not.
  brun.msgs, brun.lastmsg, brun.lastshape, brun.lastn = nil, nil, nil, 0
  brun.nsdgtot = 0
  brun.iter, brun.cell = 1, 173
  brun.screen({iter = 1, cell = 173, vid = 'j20', baud = 300}, 'SER_Jitter20pct_x100')
  ck(brun.msgs == nil or table.getn(brun.msgs) == 0,
     'the top-of-cell draw pushes nothing, because the cell has not run yet')
  brun.nsdgtot = 1                                  -- as the select failure would leave it, mid-cell
  brun.ui_note()
  local m6 = MD.text(brun.ui.msg[1])
  ck(m6 ~= nil and string.find(m6, 'L1C173', 1, true) ~= nil,
     'and the end-of-cell push carries the cell it was raised in', tostring(m6))
  -- ONCE, NOT PER CELL. A log that repeats the same line for four hundred cells cannot say when
  -- anything started.
  brun.screen({iter = 1, cell = 201, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  brun.ui_note()
  brun.screen({iter = 1, cell = 202, vid = 'v77', baud = 9600}, 'SER_Fox_8N1_x10')
  brun.ui_note()
  ck(MD.text(brun.ui.msg[2]) == '' and table.getn(brun.msgs) == 1,
     'and an unchanged state is not pushed again', tostring(MD.text(brun.ui.msg[2])))
  -- THE LAP NUMBER IS IN EVERY LINE. A soak is reproducible from its iteration number alone -- every
  -- amplitude, offset, wait and vector order is keyed on it -- so a log line naming only the cell is a
  -- failure nobody can replay a fortnight later.
  brun.iter, brun.cell = 7, 1234
  brun.msg(brun.c_warn, 'something happened')
  -- THE LAST POPULATED LINE, not the last line. The log fills downward from the top of its area the way
  -- a console does, and only scrolls once it is full -- so with two entries the newest is on line 2.
  local ml = tostring(MD.text(brun.ui.msg[table.getn(brun.msgs)]))
  ck(string.find(ml, 'L7C1234', 1, true) ~= nil,
     'every log line names the lap as well as the cell', ml)

  -- NEWEST AT THE BOTTOM, and bounded: with brun.msgn log lines, the oldest kept is 'event 6 - msgn + 1'.
  -- FOUR LINES, NOT FIVE, since one row was traded for the colour-banded 'Errors:' count -- the log rarely fills
  -- even four on a healthy run, and object ids are never reclaimed so a new row would have cost the pool.
  local mi
  for mi = 1, 6 do brun.msg(brun.c_lab, 'event ' .. tostring(mi)) end
  ck(string.find(tostring(MD.text(brun.ui.msg[brun.msgn])), 'event 6', 1, true) ~= nil
     and string.find(tostring(MD.text(brun.ui.msg[1])),
                     'event ' .. tostring(6 - brun.msgn + 1), 1, true) ~= nil,
     'the newest message is at the bottom and the log is bounded',
     tostring(MD.text(brun.ui.msg[1])) .. ' .. ' .. tostring(MD.text(brun.ui.msg[brun.msgn])))
  brun.nsdgtot, brun.msgs, brun.lastmsg = 0, nil, nil

  -- TEARDOWN VISITS EACH HANDLE EXACTLY ONCE. sdec.del_obj is not idempotent: a second delete is refused
  -- and the handle goes on sdec.orphans, where it reads as a leaked object and blocks the next rebuild.
  local nfail0 = sdec.delfails or 0
  brun.ui_destroy()
  ck(brun.ui == nil and MD.live(display.OBJ_TEXT) - live0 == 0 and (sdec.delfails or 0) == nfail0,
     'and teardown frees every object with no refused deletes',
     string.format('live=%d delfails=%d', MD.live(display.OBJ_TEXT) - live0,
                   (sdec.delfails or 0) - nfail0))
  ck(brun.ui_build() == true and brun.ui.n == 14, 'and it can be built again afterwards')
  brun.ui_destroy()
end

-- ---------------------------------------------------------------------------
print('')
print('-- the event watchdog sheds the noisy subsystem --')
do
  MOCKB_SDG({})
  bsdg.reset()
  brun.listenip, brun.listenport = '127.0.0.1', 1   -- nothing listens there
  brun.nannfail, brun.maxannfail = 0, 3
  -- A FAILING PUSH MUST GO QUIET ON ITS OWN. The real one posted event 1138 per cell for a whole lap
  -- because a pcall hid the failure and nothing counted it.
  local i
  for i = 1, 10 do brun.announce('x') end
  ck(brun.nannfail >= brun.maxannfail,
     'a push that cannot connect stops trying after a bounded number of failures',
     string.format('%d failure(s), cap %d', brun.nannfail, brun.maxannfail))
  local before = brun.nannfail
  brun.announce('y')
  ck(brun.nannfail == before, 'and once disabled it does not even attempt a connection')
  -- AND A LISTENER THAT IS THERE MUST STILL BE USED, or the bound above would be indistinguishable from
  -- the push never working at all.
  brun.nannfail, brun.maxannfail = 0, 5
  MOCKB_LISTEN('127.0.0.1', 5099)
  brun.listenip, brun.listenport = '127.0.0.1', 5099
  MOCKB.nannounce = 0
  brun.announce('z')
  ck(MOCKB.nannounce == 1 and brun.nannfail == 0,
     'and a listener that IS there receives the line', tostring(MOCKB.nannounce))
  -- THE ARITY THE INSTRUMENT ENFORCES, pinned here because two runs were lost to it.
  ck(tspnet.connect('127.0.0.1', 5099, nil) == nil,
     'tspnet.connect with a nil initString returns nil, as the instrument does')
  ck(tspnet.connect('127.0.0.1', 5099, '') ~= nil, 'and with an empty string it connects')
  brun.listenip = nil
  brun.nannfail, brun.maxannfail = 0, 5
end

-- ---------------------------------------------------------------------------
print('')
print('-- stopping on purpose, without a power cut --')
do
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  droptouch(brun.stoppath)
  -- THE CHECK IS OFF BY DEFAULT AND THIS TEST HAS TO TURN IT ON. Looking for a file that is not there
  -- posts event 2205 -- a box on the panel -- so brun.stopevery is 0 unless an attended run asks for it.
  -- That default silently broke this test: an indefinite run that never looks for the stop file never
  -- ends, so the suite spun here and, killed through a pipeline, reported exit 0.
  brun.stopevery = 1
  brun.maxcell = 40                    -- so a broken stop path fails instead of hanging
  local ok, why = brun.soak(0, 'stopfile')
  brun.stopevery, brun.maxcell = 0, 0
  ck(ok == true and why ~= nil and string.find(why, 'STOP', 1, true) ~= nil,
     'STOP.TXT ends an indefinite run cleanly at a cell boundary', tostring(why))
  -- AND THE OTHER HALF OF THE SAME FACT: with the check off, the file is not looked for at all. This is
  -- the shipped default, so the run really cannot be stopped that way -- the power cycle is the stop
  -- button, which is what the operator was told.
  brun.maxcell = 4
  local ok2, why2 = brun.soak(0, 'stopfile-ignored')
  brun.maxcell = 0
  ck(ok2 == true and why2 ~= nil and string.find(why2, 'cell cap', 1, true) ~= nil,
     'and with the check off (the default) STOP.TXT is ignored, as documented', tostring(why2))
  MD.rmfile(brun.stoppath)
end

-- ---------------------------------------------------------------------------
print('')
print('-- an indefinite run wraps rather than stopping or lying --')
do
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,' .. ARB.v77 .. ',9600,std,5.0000,0.0000,96000,0.000'})
  -- Bounded by the stop file rather than by a count, because that is how a real run ends.
  brun.wrapstop = nil
  local nwrapwant = 3
  -- Drop STOP.TXT after enough cells by hooking the recorder's row counter through a wrapper.
  local realrow = brec.row
  local ncall = 0
  brec.row = function(s)
    ncall = ncall + 1
    if ncall >= nwrapwant then
      droptouch(brun.stoppath)
    end
    return realrow(s)
  end
  brun.stopevery = 1                   -- as above: the stop file is what ends this run
  brun.maxcell = 40
  local ok, why = brun.soak(0, 'wrap')
  brun.stopevery, brun.maxcell = 0, 0
  brec.row = realrow
  ck(ok == true, 'the run ends', tostring(why))
  ck(brun.nwrap >= 1, 'a one-cell plan wraps rather than reporting the plan empty',
     string.format('%d wrap(s)', brun.nwrap))
  local s = slurp(brec.path)
  ck(s ~= nil and string.find(s, 'wrapped', 1, true) ~= nil,
     'and the wrap is recorded, so repeated stimulus is not read as new coverage')
  MD.rmfile(brun.stoppath)
end

-- ---------------------------------------------------------------------------
print('')
print('-- brun.point measures what the bench measures --')
do
  -- EXTRACTED FROM tools/bench_uart.py, not transcribed: that file's BENCH_TSP string is the function
  -- every bench result on record came through, and a copy here would be a second thing to drift.
  local py = io.open('tools/bench_uart.py', 'r')
  local src = py:read('*a')
  py:close()
  local body = string.match(src, "BENCH_TSP = r'''(.-)'''")
  ck(body ~= nil and string.find(body, 'function bench_point', 1, true) ~= nil,
     'bench_uart.py still carries bench_point in BENCH_TSP where this test looks for it')
  if body ~= nil then
    -- It prints; capture that instead of letting it scroll.
    local out, nout = {}, 0
    local realprint = print
    -- load(), because loadstring is gone from the host's Lua; the instrument has neither
    -- concern -- this is host-only test scaffolding.
    local loadfn = loadstring or load
    local chunk, err = loadfn(body, 'BENCH_TSP')
    ck(chunk ~= nil, 'and it loads as Lua on this host', tostring(err))
    if chunk ~= nil then
      chunk()
      MOCKB_SDG({})
      bsdg.reset()
      bsdg.select(ARB.v77, 5.0, 0.0, 96000)
      local fs = sdec.pick_fs(9600, 8)
      -- brun.point first, then bench_point on the same stimulus, and compare the fields both report.
      --
      -- THE PHASE IS PINNED ACROSS THE PAIR, and it has to be: this asserts that two READERS agree about
      -- ONE capture, while the start phase is drawn per capture, so two successive reads see different
      -- windows of the looping arb and disagree legitimately. Measured when phase went on: 228 frames
      -- against 234, with the rate, sample count and read baud all still agreeing -- the signature of a
      -- different window rather than a different reader. The phase model is what a sweep exercises; here
      -- it would only break an equivalence check. Restored afterwards, and only if it was on.
      local phon, phseed = SRC.phaserand, SRC.phaseseed
      SRC_PHASE(nil)
      local p = brun.point(fs, 9600, false)
      print = function(s) nout = nout + 1; out[nout] = s end
      bench_point(9600, fs, sdec.trigmode, false, nil)
      print = realprint
      if phon then SRC_PHASE(phseed) end
      local head = nil
      local k
      for k = 1, nout do
        if string.sub(out[k], 1, 5) == 'P ok ' then head = out[k] end
      end
      ck(head ~= nil, 'bench_point reports a good point on the same stimulus',
         tostring(nout) .. ' line(s)')
      if head ~= nil and p.ran then
        -- P ok <acq_fs> <nread> <baud> <nf> <ngood> <nbad> ...
        local f, nf = {}, 0
        string.gsub(head, '(%S+)', function(w) nf = nf + 1; f[nf] = w end)
        local bfs, bnread, bbaud, bnf = tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
        ck(math.abs((p.fs or 0) - (bfs or -1)) < 1e-6,
           'the two agree on the capture rate',
           string.format('%s vs %s', tostring(p.fs), tostring(bfs)))
        ck((p.nread or 0) == (bnread or -1), 'and on how many samples came back',
           string.format('%s vs %s', tostring(p.nread), tostring(bnread)))
        ck(math.abs((p.baud or 0) - (bbaud or -1)) < 1e-6, 'and on the rate they read',
           string.format('%s vs %s', tostring(p.baud), tostring(bbaud)))
        ck((p.nf or 0) == (bnf or -1), 'and on how many frames they found',
           string.format('%s vs %s', tostring(p.nf), tostring(bnf)))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
print('')
-- THE GENERATOR'S OUTPUT ENVELOPE, AGAINST FOUR PAIRS READ OFF THE INSTRUMENT.
--
-- Measured on the SDG2122X 2026-09-08 by commanding each pair and reading C1:BSWV? back. The law is that
-- AMP survives and OFST is pulled to 10 - AMP/2; the alternatives considered before measuring -- clip the
-- samples, or shrink the amplitude -- both predict different numbers here, so these four rows are what
-- stops the model drifting back to a guess. The 20 Vpp row is soakplan.py's "at 20 Vpp the only legal
-- offset is 0", confirmed on hardware.
print('-- the generator envelope matches the instrument --')
do
  local save = GENLIM.clamp_mode
  GEN_CLAMP('ofst')
  local hw = {
    {17.0,  8.5, 17.0,  1.5,  10.0,  -7.0},
    {10.0,  6.0, 10.0,  5.0,  10.0,   0.0},
    { 4.0, 12.0,  4.0,  8.0,  10.0,   6.0},
    {20.0,  3.0, 20.0,  0.0,  10.0, -10.0},
  }
  local i
  for i = 1, table.getn(hw) do
    local h = hw[i]
    local fsv, o = GEN_ENVELOPE(h[1] / 2, h[2])
    ck(math.abs(fsv * 2 - h[3]) < 1e-6 and math.abs(o - h[4]) < 1e-6,
       string.format('AMP %.1f OFST %+.1f is applied as AMP %.1f OFST %+.1f', h[1], h[2], h[3], h[4]),
       string.format('got AMP %.4f OFST %.4f', fsv * 2, o))
    ck(math.abs((o + fsv) - h[5]) < 1e-6 and math.abs((o - fsv) - h[6]) < 1e-6,
       string.format('and reports HLEV %+.1f LLEV %+.1f', h[5], h[6]),
       string.format('got HLEV %.4f LLEV %.4f', o + fsv, o - fsv))
  end
  -- A PAIR INSIDE THE ENVELOPE MUST BE UNTOUCHED, which is what proves the clamp is not simply always on:
  -- soakplan refuses to emit an out-of-envelope pair, so every cell of a real plan takes this path.
  local fsv, o = GEN_ENVELOPE(12.088 / 2, 1.894)
  ck(math.abs(fsv * 2 - 12.088) < 1e-6 and math.abs(o - 1.894) < 1e-6,
     'an in-envelope pair passes through unchanged',
     string.format('got AMP %.4f OFST %.4f', fsv * 2, o))
  -- AND THE MOCK REPORTS THE APPLIED PAIR, because the instrument does: bsdg.select writes BSWV without
  -- reading it back, so a clamped offset is only ever visible through this query.
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.select(ARB.v77, 17.0, 8.5, 96000)
  local rep = bsdg.ask('C1:BSWV?')
  ck(rep ~= nil and string.find(rep, 'OFST,1.5000V', 1, true) ~= nil,
     'BSWV? reports the CLAMPED offset, not the commanded one', tostring(rep))
  ck(rep ~= nil and string.find(rep, 'HLEV,10.0000V', 1, true) ~= nil,
     'and HLEV pinned at the 10 V envelope', tostring(rep))
  GEN_CLAMP(save)
end

print('-- reconstruction between arb samples --')
do
  -- RESTORE THE STIMULUS, WHICH IS NOT THE SAME AS RESTORING EVERYTHING. This block rewrites SRC
  -- wholesale and drives both read paths, so a later block that inherited a 2-sample render would fail
  -- for a reason that says nothing about it. What is put back: SRC's render, rate, loop and interp flag,
  -- SRC.trigat, the digitize rate and count, and the phase setting.
  --
  -- WHAT IS NOT, deliberately or unavoidably: SRC.frac_n/interp_n/held_n and READS are run-cumulative
  -- diagnostics and resetting them would corrupt the totals a caller reads at exit; TRIG.inits and the
  -- other trigger-model fields are left as the last load left them, with only TRIG.loaded put back; and
  -- the phase PRNG's STREAM POSITION cannot be restored at all -- SRC_PHASE(seed) reseeds, so a later
  -- capture draws from the start of the sequence rather than where it would have been. Nothing after this
  -- block captures through a drawn phase, which is why that is survivable rather than fine.
  local sv = {rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp, native_fs = SRC.native_fs, loop = SRC.loop,
              interp = SRC.interp, trigat = SRC.trigat, phon = SRC.phaserand, phseed = SRC.phaseseed,
              ap = SRC.aperture, fo = SRC.fracorigin,
              rate = dmm.digitize.samplerate, count = dmm.digitize.count, loaded = TRIG.loaded}
  -- A FIXED START PHASE, because every assertion below names an exact sample and the per-capture draw
  -- would move all of them.
  SRC_PHASE(nil)
  -- AND THE INSTRUMENT MODELS PINNED OFF, because this block is about the SOURCE model. The aperture
  -- supersedes interpolation in SRC_val, so leaving it on would make every assertion below describe the
  -- aperture while claiming to describe interpolation -- a test that passes for the wrong reason.
  SRC_APERTURE(false)
  SRC_FRACORIGIN(false)

  local function setsrc(vals, native, loop)
    SRC.rd, SRC.nsmp, SRC.native_fs, SRC.loop = vals, table.getn(vals), native, loop
    local ts, i = {}, nil
    for i = 1, SRC.nsmp do ts[i] = (i - 1) / native end
    SRC.ts = ts
  end

  setsrc({0, 1, 2, 3}, 1000, true)
  SRC_INTERP(true)
  local v = SRC_val(1, 3, 1)
  ck(v == 2, 'an integral position returns the source sample unchanged', tostring(v))

  v = SRC_val(1, 2, 0.5)
  ck(v == 0.5, 'a half-sample position returns the mean of its two neighbours', tostring(v))

  -- THE SEAM, AND THE OFF-BY-ONE IN IT. A looping arb joins its last sample to its first, so the
  -- interpolation point is nsmp-1+frac counting from sample 1 -- at nsmp the position has already
  -- wrapped onto rd[1] and there is nothing left to interpolate.
  setsrc({0, 0, 0, 8}, 1000, true)
  v = SRC_val(1, 5, 0.75)
  ck(v == 8, 'position 3.0 lands exactly on the last sample', tostring(v))
  v = SRC_val(4, 2, 0.5)
  ck(v == 4, 'and half a sample past the last one interpolates toward the FIRST', tostring(v))

  -- NOWHERE TO WRAP TO on a non-looping render, so the last sample is held. Interpolating toward a nil
  -- neighbour would raise, and ending the capture early would make the delivered count depend on the
  -- reconstruction model rather than on the requested rate.
  -- i = 2, NOT 1: delivered sample 1 is always at position 0 with frac 0, so it takes the exact-sample
  -- short circuit and never reaches the branch under test -- returning the right value for the wrong
  -- reason. SRC.held_n is what tells the two apart.
  setsrc({0, 10}, 1000, false)
  local held0 = SRC.held_n
  v = SRC_val(2, 2, 0.5)
  ck(v == 10 and SRC.held_n == held0 + 1,
     'a non-looping render holds its last sample rather than interpolating toward nil',
     tostring(v) .. ', held_n +' .. tostring(SRC.held_n - held0))

  -- A ONE-SAMPLE LOOP IS A CONSTANT, not an error: every position wraps onto the same sample.
  setsrc({7}, 1000, true)
  v = SRC_val(1, 4, 0.3)
  ck(v == 7, 'a one-sample loop returns that constant at every position', tostring(v))

  -- THE FLAG OFF IS THE OLD ARITHMETIC EXACTLY, not merely close to it: the same index SRC_at picks.
  setsrc({0, 1, 2, 3}, 1000, true)
  SRC_INTERP(false)
  local n0, same, i = SRC.interp_n, true, nil
  for i = 1, 12 do
    if SRC_val(1, i, 0.7) ~= SRC.rd[SRC_at(1, i, 0.7)] then same = false end
  end
  ck(same and SRC.interp_n == n0,
     'with the flag off every read equals the plain SRC_at index read and nothing interpolates',
     'interp_n moved by ' .. tostring(SRC.interp_n - n0))

  -- AND NOW THROUGH THE READS THEMSELVES. The six assertions above all pass while either call site
  -- still indexes SRC.rd directly, so they cannot show that a capture reconstructs -- only that the
  -- helper can. rd = {0, 4} at half a source sample per delivered sample makes every odd delivered
  -- sample a midpoint, so one reading tells the two models apart: 0 2 4 2 against 0 0 4 4.
  setsrc({0, 4}, 1000, true)
  dmm.digitize.samplerate, dmm.digitize.count = 2000, 4
  local b = buffer.make(1000)

  SRC_INTERP(false)
  dmm.digitize.read(b)
  ck(b.n == 4 and b.readings[2] == 0 and b.readings[4] == 4,
     'the free-running read holds between arb samples with the flag off',
     string.format('%s %s %s %s', tostring(b.readings[1]), tostring(b.readings[2]),
                   tostring(b.readings[3]), tostring(b.readings[4])))

  SRC_INTERP(true)
  local m0 = SRC.interp_n
  dmm.digitize.read(b)
  ck(b.n == 4 and b.readings[2] == 2 and b.readings[4] == 2,
     'and interpolates between them with it on',
     string.format('%s %s %s %s', tostring(b.readings[1]), tostring(b.readings[2]),
                   tostring(b.readings[3]), tostring(b.readings[4])))
  ck(SRC.interp_n > m0, 'through SRC_val, not around it',
     'interp_n moved by ' .. tostring(SRC.interp_n - m0))

  -- THE ARMED PATH TOO, on the same terms: it has its own read loop and its own origin arithmetic, so
  -- it can regress to a hold independently of the free-running one. trigat 2 with a 50 % position
  -- reserves one pre-trigger sample, so the delivered run is rd[2], the seam midpoint, rd[1].
  SRC.trigat = 2
  trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 50, trigger.CLEAR_ENTER, nil, b)

  SRC_INTERP(false)
  trigger.model.initiate()
  ck(b.readings[2] == 4, 'the armed read holds between arb samples with the flag off',
     tostring(b.readings[2]))

  SRC_INTERP(true)
  trigger.model.initiate()
  ck(b.readings[2] == 2, 'and interpolates between them with it on', tostring(b.readings[2]))

  buffer.delete(b)
  TRIG.loaded = sv.loaded
  SRC.rd, SRC.ts, SRC.nsmp, SRC.native_fs = sv.rd, sv.ts, sv.nsmp, sv.native_fs
  SRC.loop, SRC.interp, SRC.trigat = sv.loop, sv.interp, sv.trigat
  SRC_APERTURE(sv.ap)
  SRC_FRACORIGIN(sv.fo)
  dmm.digitize.samplerate, dmm.digitize.count = sv.rate, sv.count
  if sv.phon then SRC_PHASE(sv.phseed) else SRC_PHASE(nil) end
end

print('-- the digitiser INTEGRATES over its aperture, it does not point-sample --')
do
  local sv = {rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp, native_fs = SRC.native_fs, loop = SRC.loop,
              interp = SRC.interp, ap = SRC.aperture, trigat = SRC.trigat,
              rate = dmm.digitize.samplerate, count = dmm.digitize.count, loaded = TRIG.loaded}
  SRC_PHASE(nil)

  local function setsrc(vals, native, loop)
    SRC.rd, SRC.nsmp, SRC.native_fs, SRC.loop = vals, table.getn(vals), native, loop
    local ts, i = {}, nil
    for i = 1, SRC.nsmp do ts[i] = (i - 1) / native end
    SRC.ts = ts
  end

  -- THE WIDTH IS A MEASURED CONSTANT, so a silent edit must fail here rather than quietly move every
  -- offline stimulus. 0.85 us is fitted from ground truth at three well-conditioned arb rates; the
  -- NOMINAL aperture is 1 us and costs +0.27 points of residual, so the difference is deliberate.
  ck(AP_WIDTH_S == 0.85e-6, 'the aperture width is the measured 0.85 us, not the nominal 1 us',
     tostring(AP_WIDTH_S))

  -- AN INDEPENDENT IMPLEMENTATION, walking the window cell by cell. The shipped path uses a cumulative
  -- sum plus cyclic index arithmetic; if that is wrong at a wrap, this disagrees and nothing else would.
  local function refmean(lo, hi, rd, n)
    local acc, x, k, nxt, q, kk = 0, lo, nil, nil, nil, nil
    while x < hi do
      k = math.floor(x)
      nxt = k + 1
      if nxt > hi then nxt = hi end
      if nxt <= x then break end
      q = math.floor((k - 1) / n)
      kk = k - q * n
      acc = acc + rd[kk] * (nxt - x)
      x = nxt
    end
    return acc / (hi - lo)
  end

  -- native 4 MSa/s makes the window 3.4 arb samples, so it spans several cells and wraps.
  setsrc({0, 10, 3, 3, 0, 0, 7, 7}, 4e6, true)
  SRC_INTERP(false)
  SRC_APERTURE(true)
  local w = AP_WIDTH_S * 4e6
  local worst, n0, i, from, step = 0, SRC.ap_n, nil, nil, nil
  for from = 1, 8 do
    for i = 1, 9 do
      for step = 1, 3 do
        local st = step * 0.5 + 0.25
        local x = from + (i - 1) * st
        local got = SRC_val(from, i, st)
        local want = refmean(x - 0.5 * w, x + 0.5 * w, SRC.rd, SRC.nsmp)
        local d = got - want
        if d < 0 then d = -d end
        if d > worst then worst = d end
      end
    end
  end
  ck(worst < 1e-12, 'every windowed read equals an independent cell-by-cell mean, wraps included',
     string.format('worst disagreement %.3g V over %d reads', worst, 8 * 9 * 3))
  ck(SRC.ap_n == n0 + 8 * 9 * 3, 'and all of them went through the aperture branch',
     'ap_n moved by ' .. tostring(SRC.ap_n - n0))

  -- DC GAIN EXACTLY 1. A window that averages a constant must return that constant at ANY width and
  -- position, or the model injects gain error into every held level in the capture.
  setsrc({2.5, 2.5, 2.5, 2.5}, 4e6, true)
  local flat = true
  for i = 1, 7 do
    if SRC_val(1, i, 0.7) ~= 2.5 then flat = false end
  end
  ck(flat, 'a constant source comes back as that constant, so DC gain is exactly 1', tostring(flat))

  -- IT MUST ACTUALLY SMOOTH. A point read of a step returns a rail; an integral straddling one cannot.
  setsrc({0, 0, 0, 0, 10, 10, 10, 10}, 4e6, true)
  local mid = SRC_val(4, 2, 1.0)                 -- window centred at index 5, the step
  ck(mid > 0.01 and mid < 9.99,
     'a window straddling a step returns neither rail, which is the whole point', tostring(mid))

  -- THE FLAG OFF IS THE OLD ARITHMETIC EXACTLY, and ap_n proves the branch stayed out of it.
  setsrc({0, 1, 2, 3}, 4e6, true)
  SRC_APERTURE(false)
  local a0, same = SRC.ap_n, true
  for i = 1, 12 do
    if SRC_val(1, i, 0.7) ~= SRC.rd[SRC_at(1, i, 0.7)] then same = false end
  end
  ck(same and SRC.ap_n == a0,
     'with the flag off every read is the plain index read and the aperture never runs',
     'ap_n moved by ' .. tostring(SRC.ap_n - a0))

  -- THE APERTURE SUPERSEDES INTERPOLATION, and this pins it because the behaviour is invisible from the
  -- outside: SRC_val returns from the aperture branch before reaching the interpolating one, so a caller
  -- that asks for both gets only the aperture. That is correct -- the integral already assumes the
  -- generator HOLDS, and linear reconstruction is a cheap approximation to the same average rather than
  -- something to compose with it -- but it means offline_bench must REFUSE the pair instead of logging a
  -- reconstruction that never ran. interp_n is what tells the two apart.
  setsrc({0, 0, 12, 12}, 4e6, true)
  SRC_INTERP(true)
  SRC_APERTURE(true)
  local i0, ai0 = SRC.interp_n, SRC.ap_n
  for i = 1, 10 do SRC_val(1, i, 2.5) end
  ck(SRC.interp_n == i0 and SRC.ap_n == ai0 + 10,
     'with both flags on the aperture runs and interpolation does not, so the pair must be refused',
     string.format('interp_n +%d, ap_n +%d', SRC.interp_n - i0, SRC.ap_n - ai0))
  SRC_APERTURE(false)
  local i1 = SRC.interp_n
  for i = 1, 10 do SRC_val(1, i, 2.5) end
  ck(SRC.interp_n > i1, 'and interpolation does run once the aperture is off, so the flag is live',
     'interp_n +' .. tostring(SRC.interp_n - i1))
  SRC_INTERP(false)

  -- A NON-LOOPING RENDER HAS NOTHING OUTSIDE IT TO AVERAGE, so the window shortens rather than wrapping.
  -- Wrapping would splice the tail onto the head, the exact seam artifact SRC.loop = false avoids.
  setsrc({0, 0, 0, 0, 0, 0, 0, 12}, 4e6, false)
  SRC_APERTURE(true)
  local c0 = SRC.ap_clamp_n
  local last = SRC_val(8, 1, 1.0)                -- centred on index 8, half the window past the end
  ck(SRC.ap_clamp_n == c0 + 1 and last > 0,
     'a non-looping render clamps the window to the samples that exist',
     string.format('%.4f, clamp_n +%d', last, SRC.ap_clamp_n - c0))

  -- AND THROUGH THE READS THEMSELVES, both call sites. The assertions above all pass while either read
  -- loop still indexes SRC.rd directly, so they show the helper works, not that a capture integrates.
  setsrc({0, 0, 12, 12}, 4e6, true)
  dmm.digitize.samplerate, dmm.digitize.count = 1.6e6, 4      -- step 2.5, a fractional window
  local b = buffer.make(1000)

  SRC_APERTURE(false)
  dmm.digitize.read(b)
  local hold2, hold3 = b.readings[2], b.readings[3]

  SRC_APERTURE(true)
  local r0 = SRC.ap_n
  dmm.digitize.read(b)
  ck(b.n == 4 and SRC.ap_n == r0 + 4,
     'the free-running read goes through the aperture for every delivered sample',
     'ap_n moved by ' .. tostring(SRC.ap_n - r0))
  ck(b.readings[2] ~= hold2 or b.readings[3] ~= hold3,
     'and the values it delivers differ from the held ones',
     string.format('held %s %s vs aperture %s %s', tostring(hold2), tostring(hold3),
                   tostring(b.readings[2]), tostring(b.readings[3])))

  SRC.trigat = 2
  trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 50, trigger.CLEAR_ENTER, nil, b)
  SRC_APERTURE(false)
  trigger.model.initiate()
  local armhold = b.readings[2]
  SRC_APERTURE(true)
  local q0 = SRC.ap_n
  trigger.model.initiate()
  ck(SRC.ap_n > q0 and b.readings[2] ~= armhold,
     'and so does the armed read, which has its own loop and its own origin arithmetic',
     string.format('held %s vs aperture %s', tostring(armhold), tostring(b.readings[2])))

  buffer.delete(b)
  TRIG.loaded = sv.loaded
  SRC.rd, SRC.ts, SRC.nsmp, SRC.native_fs = sv.rd, sv.ts, sv.nsmp, sv.native_fs
  SRC.loop, SRC.interp, SRC.trigat = sv.loop, sv.interp, sv.trigat
  SRC_APERTURE(sv.ap)
  dmm.digitize.samplerate, dmm.digitize.count = sv.rate, sv.count
  SRC_PHASE(nil)
end

print('-- a FRACTIONAL capture origin, because two independent clocks never align on a sample --')
do
  local sv = {rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp, native_fs = SRC.native_fs, loop = SRC.loop,
              interp = SRC.interp, ap = SRC.aperture, fo = SRC.fracorigin,
              phon = SRC.phaserand, phseed = SRC.phaseseed}
  SRC.rd, SRC.nsmp, SRC.native_fs, SRC.loop = {0, 3, 6, 9, 12, 15, 18, 21}, 8, 1e6, true
  SRC_INTERP(false); SRC_APERTURE(false)

  -- THE DRAW SEQUENCE MUST NOT MOVE. This is the assertion that protects every result already recorded:
  -- the sub-sample part is the REMAINDER of the draw that picks the integer index, not a second draw, so
  -- the integer sequence has to be bit-identical with the flag on and off. If it ever needs an extra
  -- value from the stream, every phase after the first shifts and no earlier soak is comparable again.
  local function seq(n)
    SRC_PHASE(20260907)
    local out, i = {}, nil
    for i = 1, n do out[i] = SRC_NEXTPHASE() end
    return out
  end
  SRC_FRACORIGIN(false)
  local a = seq(40)
  SRC_FRACORIGIN(true)
  local b = seq(40)
  local same, i = true, nil
  for i = 1, 40 do if a[i] ~= b[i] then same = false end end
  ck(same, 'the integer phase sequence is identical with the fractional origin on and off',
     'first mismatch at ' .. tostring(same and 'none' or i))

  -- AND THE FRACTION IS ACTUALLY THERE, in range, and varies between captures.
  SRC_FRACORIGIN(true)
  SRC_PHASE(20260907)
  local nz, inrange, seen, j = 0, true, {}, nil
  for i = 1, 40 do
    SRC_NEXTPHASE()
    if SRC.phasefrac ~= 0 then nz = nz + 1 end
    if SRC.phasefrac < 0 or SRC.phasefrac >= 1 then inrange = false end
    seen[i] = SRC.phasefrac
  end
  ck(nz >= 38 and inrange, 'every capture draws a sub-sample offset in [0, 1)',
     string.format('%d of 40 nonzero, in range %s', nz, tostring(inrange)))
  ck(seen[1] ~= seen[2] and seen[2] ~= seen[3], 'and it differs between captures',
     string.format('%.6f %.6f %.6f', seen[1], seen[2], seen[3]))

  -- WITH THE FLAG OFF THE ORIGIN IS EXACT, which is the behaviour every existing result was produced by.
  SRC_FRACORIGIN(false)
  SRC_PHASE(20260907)
  local ph = SRC_NEXTPHASE()
  local n0 = SRC.fracorigin_n
  local v = SRC_val(ph, 1, 1)
  ck(SRC.phasefrac == 0 and v == SRC.rd[ph] and SRC.fracorigin_n == n0,
     'with the flag off delivered sample 1 lands exactly on an arb sample',
     string.format('%s vs rd[%d]=%s', tostring(v), ph, tostring(SRC.rd[ph])))

  -- AN INTEGRAL STEP IS THE STARKEST CASE: with step 1 the origin is the ONLY source of sub-sample
  -- offset, so with the flag off EVERY delivered sample sits at offset exactly 0 and the whole capture
  -- explores one degenerate phase. Interpolation makes that visible as a value between two arb samples.
  SRC_INTERP(true)
  SRC_FRACORIGIN(true)
  SRC_PHASE(20260907)
  ph = SRC_NEXTPHASE()
  n0 = SRC.fracorigin_n
  v = SRC_val(ph, 1, 1)
  local lo, hi = SRC.rd[ph], SRC.rd[math.mod(ph, 8) + 1]
  ck(SRC.fracorigin_n == n0 + 1 and v ~= lo,
     'with it on, and an INTEGRAL step, sample 1 falls between two arb samples',
     string.format('%.4f between %s and %s, frac %.4f', v, tostring(lo), tostring(hi), SRC.phasefrac))

  SRC_INTERP(false); SRC_FRACORIGIN(false)
  SRC.rd, SRC.ts, SRC.nsmp, SRC.native_fs = sv.rd, sv.ts, sv.nsmp, sv.native_fs
  SRC.loop, SRC.interp = sv.loop, sv.interp
  SRC_APERTURE(sv.ap); SRC_FRACORIGIN(sv.fo)
  if sv.phon then SRC_PHASE(sv.phseed) else SRC_PHASE(nil) end
end

print('-- the DMM front end, which is the other half of the signal chain --')
do
  -- THE CONSTANTS ARE NOT FREE PARAMETERS. Both come from tsp/, which is the shipped source, so a test
  -- that only checked the filter's shape would let either drift silently. 440 kHz is the 10 V range's
  -- digitize bandwidth and 1 us is sdec.dig.aperture, whose own comment calls it non-negotiable.
  local f = io.open('tsp/serial_core.tsp', 'r')
  local core = f and f:read('*a') or ''
  if f then f:close() end
  ck(string.find(core, '440', 1, true) ~= nil,
     'tsp/serial_core.tsp still states the 440 kHz digitize bandwidth GEN_FRONTEND uses')
  ck(FE_BW_HZ == 440e3 and FE_APERTURE_S == 1e-6,
     'and GEN_FRONTEND carries those two figures',
     string.format('%g Hz, %g s', FE_BW_HZ, FE_APERTURE_S))

  -- DC GAIN IS EXACTLY 1 in both stages, which is what makes it a filter rather than a scaling. A boxcar
  -- of any width and a one-pole low pass both pass a constant unchanged, so a flat input must come back
  -- flat -- and if it does not, the logic LEVELS have moved and every threshold test downstream is wrong.
  local flat, i = {}, nil
  for i = 1, 64 do flat[i] = 3.3 end
  local g = GEN_FRONTEND(flat, 64, 2000000)
  local worst = 0
  for i = 1, 64 do
    local e = g[i] - 3.3
    if e < 0 then e = -e end
    if e > worst then worst = e end
  end
  ck(worst < 1e-9, 'a constant passes through the front end unchanged', string.format('worst %g V', worst))

  -- THE APERTURE IS SKIPPED BELOW ONE ARB SAMPLE, which is the truth rather than an optimisation: a 1 us
  -- window inside a DAC value held for longer averages nothing. At 125 kSa/s the tread is 8 us.
  local step = {}
  for i = 1, 64 do step[i] = (i <= 32) and 0 or 3.3 end
  -- A TOLERANCE, NOT EQUALITY, and the reason is worth stating: at 125 kSa/s `a` is 1 - 2.2e-10, which is
  -- NOT 1 to double precision, so the pole does run. Its residue decays as (1-a)^n and reaches 3e-96 ten
  -- samples in -- a no-op in effect, but never exactly zero, and an equality test here fails for a reason
  -- that has nothing to do with the model.
  local slow = GEN_FRONTEND(step, 64, 125000)
  ck(math.abs(slow[10]) < 1e-9 and math.abs(slow[40] - 3.3) < 1e-9,
     'at 125 kSa/s neither stage moves a held level -- w < 1 and the pole settles in under a sample',
     string.format('%g .. %g', slow[10], slow[40]))

  -- AND AT A HIGH ARB RATE IT GENUINELY SMOOTHS, which is the whole point: a step becomes a transition
  -- spread over several samples, so a threshold crossing lands BETWEEN sample instants and the app's
  -- fractional edge list has something to recover. A hold alone puts every crossing on the grid.
  local fast = GEN_FRONTEND(step, 64, 4000000)
  local mid = 0
  for i = 1, 64 do
    if fast[i] > 0.05 and fast[i] < 3.25 then mid = mid + 1 end
  end
  ck(mid >= 2, 'at 4 MSa/s a step becomes a multi-sample transition', tostring(mid) .. ' intermediate')

  -- THE INPUT IS NOT MUTATED, so a caller can keep the unfiltered wire beside the filtered one.
  ck(step[10] == 0 and step[40] == 3.3, 'and the caller\'s array is left alone')

  -- CYCLIC, TESTED AS SHIFT INVARIANCE, which is what "cyclic" actually means and is exact. Rotating the
  -- input by k and filtering must equal filtering and then rotating by k. A filter started from rest fails
  -- this at the seam, which is the transient the hardware does not have -- and it would land exactly where
  -- the looping-arb seam already causes trouble.
  --
  -- NOT tested with a ramp: 1..64 is discontinuous at the seam by construction, so a CORRECT cyclic filter
  -- shows a large step there and the test would be asserting the opposite of the property.
  local sq, k = {}, 21
  for i = 1, 64 do sq[i] = (math.mod(i - 1, 16) < 8) and 0 or 3.3 end
  local rot = {}
  for i = 1, 64 do rot[i] = sq[math.mod(i - 1 + k, 64) + 1] end
  local fa = GEN_FRONTEND(sq, 64, 4000000)
  local fb = GEN_FRONTEND(rot, 64, 4000000)
  local worstshift = 0
  for i = 1, 64 do
    local e = fb[i] - fa[math.mod(i - 1 + k, 64) + 1]
    if e < 0 then e = -e end
    if e > worstshift then worstshift = e end
  end
  ck(worstshift < 1e-9, 'the filter is cyclic: rotating the input just rotates the output',
     string.format('worst %g V over a %d-sample rotation', worstshift, k))
end

print('-- the digitiser synthesises the rate it can, not the one it was asked for --')
do
  local sv = {rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp, native_fs = SRC.native_fs, loop = SRC.loop,
              truefs = SRC.truefs, rate = dmm.digitize.samplerate}

  -- THE THREE INEXACT LISTED RATES, against the figures tsp/serial_core.tsp states from 26 measured
  -- rates. They are listed on purpose -- they are what 19200, 38400 and 76800 need -- so a change that
  -- "fixed" them into round numbers would be undoing a deliberate choice.
  SRC.rd, SRC.nsmp, SRC.native_fs, SRC.loop = {0, 1}, 2, 1000000, true
  SRC.ts = {0, 1e-6}
  SRC_TRUEFS(true)
  local want = {[640000] = -0.841, [320000] = -0.362, [160000] = -0.121}
  local f
  for f in pairs(want) do
    dmm.digitize.samplerate = f
    local step, dt = SRC_step()
    local fs = 1 / dt
    local err = 100 * (fs - f) / f
    ck(math.abs(err - want[f]) < 0.001,
       string.format('%d S/s is synthesised as %.1f, %+.3f %%', f, fs, err),
       string.format('expected %+.3f %%', want[f]))
    -- AND THE STEP MOVES WITH IT, not just the timestamp: acq_measure_fs divides the delivered interval
    -- into the sample count, so the two must come from one rate or the mock reports a rate it did not use.
    ck(math.abs(step - 1000000 / fs) < 1e-9, '  and the resampling step uses that same rate',
       tostring(step))
  end

  -- AN EXACT RATE IS UNTOUCHED, which is what makes the flag safe to leave on: 66e6 = 2^7*3*5^6*11, so
  -- every rate that divides it is synthesised exactly and 11.0 % of a lap's cells are the ones that move.
  local exact = {1000000, 500000, 250000, 120000, 100000, 80000, 60000, 10000}
  local allexact, i = true, nil
  for i = 1, table.getn(exact) do
    dmm.digitize.samplerate = exact[i]
    local _, dt = SRC_step()
    if math.abs(1 / dt - exact[i]) > 1e-6 then allexact = false end
  end
  ck(allexact, 'every rate that divides 66e6 is synthesised exactly', 'checked 8 of them')

  -- FLAG OFF IS THE REQUEST, unchanged, so the arms of an A/B differ only in this.
  SRC_TRUEFS(false)
  dmm.digitize.samplerate = 640000
  local _, dt = SRC_step()
  ck(math.abs(1 / dt - 640000) < 1e-6,
     'with the flag off the requested rate is delivered verbatim', tostring(1 / dt))

  SRC.rd, SRC.ts, SRC.nsmp, SRC.native_fs, SRC.loop = sv.rd, sv.ts, sv.nsmp, sv.native_fs, sv.loop
  SRC.truefs, dmm.digitize.samplerate = sv.truefs, sv.rate
end

print('-- the flagged-frame convention --')
do
  -- '??' FOR A FLAGGED FRAME is what stops a byte passing the host's substring check only because the
  -- error was ignored. Written plainly, this is the difference between a judge and a rubber stamp.
  local res = {nf = 3, ngood = 2, nbad = 1, vals = {0x41, 0x42, 0x43}, errs = {nil, 'framing', nil}}
  local h = brun.hex(res)
  ck(h == '41??43', 'a flagged frame is written ?? rather than its value', h)
  local res2 = {nf = 2, ngood = 2, nbad = 0, vals = {0x00, 0xFF}, errs = {}}
  ck(brun.hex(res2) == '00FF', 'and clean frames are plain hex', brun.hex(res2))
  ck(brun.hex(nil) == '' and brun.hex({nf = 0}) == '', 'no frames is an empty field, not a crash')
end

-- ---------------------------------------------------------------------------
-- The screen names the run, so a smoke is not read as a soak
-- ---------------------------------------------------------------------------
-- BOTH RUN THROUGH brun.soak AND DRAW THE SAME SCREEN. The cell count is the only other thing separating
-- them, and an operator glancing at the glass reaches for the TRIGGER key -- which stops whichever run is
-- really there. The title is checked against the firmware's 31-character ceiling as well as its spelling:
-- over that the firmware truncates and posts 1707, and mock_display raises rather than let it pass.
do
  brun.tag = nil
  ck(brun.tagword() == 'SOAK', 'tagword defaults to SOAK when nothing has set a tag', brun.tagword())
  brun.tag = ''
  ck(brun.tagword() == 'SOAK', 'and an empty tag reads as SOAK rather than as nothing')

  local tags = {'soak', 'smoke', 'resumed'}
  local want = {'SD SOAK - TRIGGER TO STOP', 'SD SMOKE - TRIGGER TO STOP',
                'SD RESUMED - TRIGGER TO STOP'}
  local k
  for k = 1, 3 do
    brun.tag = tags[k]
    ck(brun.ui_build() == true and brun.ui ~= nil, 'the screen builds for tag ' .. tags[k])
    local ti = tostring(MD.obj(brun.ui.scr).title)
    ck(ti == want[k], 'and the title names the run', ti)
    ck(string.len(ti) <= 31, 'inside the 31-character title ceiling',
       string.format('%d char(s)', string.len(ti)))
    ck(MD.text(brun.ui.health) == string.upper(tags[k]) .. ' HEALTH --',
       'and the headline placeholder names it too', tostring(MD.text(brun.ui.health)))
  end
  brun.ui_destroy()
  brun.tag = 'soak'
end

print('')
print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

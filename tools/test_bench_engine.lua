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
for _, m in ipairs({'bench/sdg_net.tsp', 'bench/bench_rec.tsp', 'bench/bench_run.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(true)

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

-- A tiny plan on the key: two vectors the repo actually has, at rates they can play.
local function writeplan(rows)
  local fh = file.open(brun.planpath, file.MODE_WRITE)
  if fh == nil then print('cannot write the test plan'); os.exit(1) end
  file.write(fh, '# test plan\niter,cell,vid,baud,kind,amp_vpp,ofst_v,srate,wait_ms\n')
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
  local ok, why = bsdg.select('v77', 5.0, 0.0, 96000)
  ck(ok == true, 'a vector selects, verifies and turns the output on', tostring(why))
  ck(MOCKB.sdg.arb == 'v77' and MOCKB.sdg.mode == 'TARB' and MOCKB.sdg.out == true,
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
print('-- the failures an instrument session cannot arrange --')
do
  -- A FILE THE GENERATOR CANNOT READ. It does not answer with an error: it leaves the previous
  -- waveform selected and says nothing, which is why the reply is compared.
  MOCKB_SDG({refuse_arb = 'v78'})
  bsdg.reset()
  bsdg.select('v77', 5.0, 0.0, 96000)
  local ok, why = bsdg.select('v78', 5.0, 0.0, 96000)
  ck(ok == false and why ~= nil and string.find(why, 'ARWV?', 1, true) ~= nil,
     'a file the generator cannot read is caught by comparing ARWV?, not assumed loaded',
     tostring(why))
  ck(MOCKB.sdg.arb == 'v77', 'and the generator is still playing the previous vector, as it would be',
     tostring(MOCKB.sdg.arb))

  -- TRUEARB FALLING BACK TO DDS, which would resample the points and corrupt edge timing with nothing
  -- on the panel to say so.
  MOCKB_SDG({dds_after_arb = true})
  bsdg.reset()
  -- The mock sets DDS on ARWV; sdg_net sets TARB after, so this must still pass -- that IS the reason
  -- for the order. Then force the fallback by clearing the mode after everything is set.
  local ok2 = bsdg.select('v77', 5.0, 0.0, 96000)
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
  for i = 1, 10 do brec.row(string.format('%d,%d,v77,9600,std,5,0,96000,0,,,,,,,,,,,,,', 1, i)) end
  brec.note(1, 10, 10, 'ten cells in', 0, 0)
  -- NOT CLOSED. This is the point: the file must be readable with the handle still open, because a
  -- power cut is the stop button and there is no close to wait for.
  local s = slurp(brec.path)
  local L, n = lines(s)
  ck(s ~= nil and n >= 12, 'every row is on disk with the file still open -- no close required',
     string.format('%d line(s)', n))
  ck(string.find(L[1], 'serdec%-soak%-1') ~= nil, 'the schema version is the first line', L[1])
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
  writeplan({'1,1,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,19200,std,5.0000,0.0000,192000,0.000',
             '2,1,v77,9600,std,4.0000,0.0000,96000,0.000'})
  local ok, why = brun.soak(1, 'e2e')
  ck(ok == true, 'the soak runs and returns', tostring(why))
  local L, n = lines(slurp(brec.path))
  -- Two data rows for iteration 1, and it must STOP there rather than running iteration 2.
  -- COUNTED BY TAG, not by "not a comment": progress rows share this file now, so anything that is
  -- merely non-comment includes them and a count of cells would be inflated by its own status lines.
  local ndata, k, lastR = 0, nil, nil
  for k = 1, n do
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
end

-- ---------------------------------------------------------------------------
print('')
print('-- the generator dying mid-soak --')
do
  MOCKB_SDG({})
  bsdg.reset()
  bsdg.timeout = 0.05
  brun.maxsdgfail = 3
  writeplan({'1,1,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,3,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,4,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,5,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,6,v77,9600,std,5.0000,0.0000,96000,0.000'})
  MOCKB.sdg.wedged = true
  local ok, why = brun.soak(1, 'dead')
  ck(ok == true and why ~= nil and string.find(why, 'in a row', 1, true) ~= nil,
     'a wedged generator PARKS the run with a reason rather than filling the key', tostring(why))
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
  bsdg.timeout = 5
  brun.maxsdgfail = 20
end

-- ---------------------------------------------------------------------------
print('')
print('-- stopping on purpose, without a power cut --')
do
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,9600,std,5.0000,0.0000,96000,0.000',
             '1,2,v77,9600,std,5.0000,0.0000,96000,0.000'})
  droptouch(brun.stoppath)
  local ok, why = brun.soak(0, 'stopfile')
  ck(ok == true and why ~= nil and string.find(why, 'STOP', 1, true) ~= nil,
     'STOP.TXT ends an indefinite run cleanly at a cell boundary', tostring(why))
  MD.rmfile(brun.stoppath)
end

-- ---------------------------------------------------------------------------
print('')
print('-- an indefinite run wraps rather than stopping or lying --')
do
  MOCKB_SDG({})
  bsdg.reset()
  writeplan({'1,1,v77,9600,std,5.0000,0.0000,96000,0.000'})
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
  local ok, why = brun.soak(0, 'wrap')
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
      bsdg.select('v77', 5.0, 0.0, 96000)
      local fs = sdec.pick_fs(9600, 8)
      -- brun.point first, then bench_point on the same stimulus, and compare the fields both report.
      local p = brun.point(fs, 9600, false)
      print = function(s) nout = nout + 1; out[nout] = s end
      bench_point(9600, fs, sdec.trigmode, false, nil)
      print = realprint
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

print('')
print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

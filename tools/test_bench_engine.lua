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

-- THE REAL STORED NAMES, read out of tools/vector_names.py rather than typed here: the whole reason a
-- wrong ARWV reached an instrument is that the mock understood a name this test had invented. Parsing
-- the host's own map means the mock answers to exactly what the plan will carry.
-- THE REAL STORED NAMES, from soakplan.py's own output rather than typed here: the reason a wrong ARWV
-- reached an instrument at all is that the mock understood a name this file had invented.
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
  -- AND THOSE ROWS ARE STILL THE RIGHT SHAPE. This is the row kind that was a column short, and 15 of
  -- them in one real lap made the host refuse the entire 182-row file.
  checkcols('dead')
  bsdg.timeout = 5
  brun.maxsdgfail = 20
end

-- ---------------------------------------------------------------------------
print('')
print('-- no popups: the checks that run every cell must not post events --')
do
  MOCKB_SDG({})
  bsdg.reset()
  -- file.open ON A MISSING FILE POSTS AN EVENT on this instrument, and mock_display.lua models that.
  -- brun.stopped() runs once per cell, so probing for an absent STOP.TXT that way is 86 popups in a
  -- smoke and about 1.4 million across eight days. It reads the DIRECTORY listing instead.
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
  ck(MD.usertext(display.TEXT1) == 'L3#412 F12 0.7%',
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
  ck(MD.live(display.OBJ_TEXT) <= 7,
     'and the object count is fixed -- the swipe lines cost none, the screen a bounded seven',
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
  ck(ok == true and brun.ui ~= nil and brun.ui.n == 8,
     'the screen is eight objects, built once', string.format('ok=%s n=%s', tostring(ok),
                                                             tostring(brun.ui and brun.ui.n)))
  brun.soak(1, 'uiscreen')
  ck(MD.live(display.OBJ_TEXT) - live0 == 7,
     'and a whole run adds no more of them -- settext only, per cell',
     string.format('%d text object(s)', MD.live(display.OBJ_TEXT) - live0))

  -- EVERY FIELD THE OPERATOR ASKED FOR, and n-of-m rather than a bare index: 'cell 412' says nothing
  -- about how much is left, which is the question a soak screen exists to answer.
  brun.screen({iter = 3, cell = 412, vid = 'v48b', baud = 153600}, 'SER_Hello_8N1_Drift10_x10')
  local prog, tim = MD.text(brun.ui.prog), MD.text(brun.ui.time)
  local stim, fail = MD.text(brun.ui.stim), MD.text(brun.ui.fail)
  ck(string.find(prog, 'lap 3', 1, true) ~= nil and string.find(prog, 'cell 412 of', 1, true) ~= nil
     and string.find(prog, '% of the lap', 1, true) ~= nil,
     'the progress line is lap n of m, cell n of m, and how far through the lap', prog)
  ck(string.find(tim, 'ran ', 1, true) ~= nil and string.find(tim, 'left ', 1, true) ~= nil,
     'the time line is hours run and hours left', tim)
  ck(string.find(stim, 'v48b', 1, true) ~= nil and string.find(stim, '153600 Bd', 1, true) ~= nil
     and string.find(stim, '8N1', 1, true) ~= nil
     and string.find(stim, 'SER_Hello_8N1_Drift10_x10', 1, true) ~= nil,
     'the stimulus line is the vector, the rate, the format and the waveform in full', stim)
  -- LABELLED. A bare percentage on a status screen is a number whose meaning has to be guessed, and the
  -- guess that matters -- bytes wrong -- is not what it measures.
  local vfail = MD.text(brun.ui.vfail)
  ck(string.find(fail, 'allowed refusals', 1, true) ~= nil
     and string.find(fail, 'UNEXPECTED', 1, true) ~= nil
     and string.find(vfail, 'v48b', 1, true) ~= nil
     and string.find(vfail, 'refused', 1, true) ~= nil,
     'the counts are split into refusals that are allowed and refusals that are not', fail .. ' / '
     .. vfail)
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
  brun.ncell, brun.nunexp, brun.nexp = 400, 4, 78
  local hl, hcol = brun.healthline()
  ck(hl == 'SOAK HEALTH 99.0 %' and hcol == brun.c_good,
     'the headline is one health figure, green above 85 %', hl)
  brun.nunexp = 0
  hl, hcol = brun.healthline()
  ck(hl == 'SOAK HEALTH 100.0 %' and hcol == brun.c_good,
     'and 100 % with 78 ALLOWED refusals is green', hl)
  -- THE BAND THAT MATTERS, because it is where a real lap sits: 92 % is what hardware measured while
  -- working, so it must read as healthy. A light that turns amber at 99.9 % is amber all week.
  brun.nunexp = 32
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_good, 'a 92 % lap -- what hardware actually measures -- is still green', hl)
  -- THE MEASURED FLOOR: 89.8 % was the worst this lap read while healthy, so it has to be green or the
  -- headline flickers for two hours.
  brun.nunexp = 41
  hl, hcol = brun.healthline()
  ck(hcol == brun.c_good, 'and 89.8 %, the worst a healthy lap read, is green rather than flickering', hl)
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
    {why = 'the TRIGGER key was pressed'},
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
  local _, run2 = brun.ui_status()
  ck(run2 == 'Running -- press TRIGGER to stop and flush',
     'and the line it shows all week is the one that says how to stop it', run2)

  -- TEARDOWN VISITS EACH HANDLE EXACTLY ONCE. sdec.del_obj is not idempotent: a second delete is refused
  -- and the handle goes on sdec.orphans, where it reads as a leaked object and blocks the next rebuild.
  local nfail0 = sdec.delfails or 0
  brun.ui_destroy()
  ck(brun.ui == nil and MD.live(display.OBJ_TEXT) - live0 == 0 and (sdec.delfails or 0) == nfail0,
     'and teardown frees every object with no refused deletes',
     string.format('live=%d delfails=%d', MD.live(display.OBJ_TEXT) - live0,
                   (sdec.delfails or 0) - nfail0))
  ck(brun.ui_build() == true and brun.ui.n == 8, 'and it can be built again afterwards')
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

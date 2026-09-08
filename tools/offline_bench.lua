-- offline_bench.lua -- run the on-instrument soak engine on the Mac, against a real plan, and write
-- the record out where the host judge can read it.
--
-- WHY THIS EXISTS SEPARATELY FROM test_bench_engine.lua. That suite drives the engine's BRANCHES --
-- the generator dying, the plan wrapping, the key refusing a write. This drives its OUTPUT: a real
-- plan file from soakplan.py, every cell measured against the real rendered vectors, and the resulting
-- CSV dropped on the host filesystem so tools/judge_bench.py can be run against it for real. Together
-- they mean the only thing left untested before instrument time is the instrument itself.
--
-- NOT A FIDELITY CLAIM. There is no DMM front end here and no noise -- gen_serial's SRC hands the app
-- the vector's own samples, decimated. tools/sweep_plan.lua is where signal fidelity is argued about.
-- What this validates is the ENGINE and the FILE FORMAT: that a plan in, a judgeable record out.
--
--   python3 tools/soakplan.py --emit-csv --iteration 1 --spec 'v77:std,r06:std,v78:nonstd,r00:nonstd' \
--       > out/bench/PLAN.CSV
--   lua tools/offline_bench.lua --plan out/bench/PLAN.CSV --out out/bench/OFFLINE.csv
--   python3 tools/judge_bench.py out/bench/OFFLINE.csv

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

local A = {plan = nil, out = nil, iterations = 1, phaseseed = nil, clamp = nil}
local ai = 1
while arg ~= nil and arg[ai] ~= nil do
  local k, v = arg[ai], arg[ai + 1]
  if k == '--plan' then A.plan = v; ai = ai + 2
  elseif k == '--out' then A.out = v; ai = ai + 2
  elseif k == '--iterations' then A.iterations = tonumber(v); ai = ai + 2
  -- ONE SEED PER RUN, so a soak can cover phase space across laps while each lap stays reproducible on
  -- its own. Without this every lap would draw the same phase sequence and extra laps would add nothing.
  elseif k == '--phase-seed' then A.phaseseed = tonumber(v); ai = ai + 2
  elseif k == '--no-phase' then A.phaseseed = -1; ai = ai + 1
  elseif k == '--clamp' then A.clamp = v; ai = ai + 2
  else print('unknown argument: ' .. tostring(k)); os.exit(2) end
end
if A.plan == nil or A.out == nil then
  print('REFUSING: --plan FILE and --out FILE are both required.')
  print('  python3 tools/soakplan.py --emit-csv --iteration 1 --spec \'v77:std\' > out/bench/PLAN.CSV')
  print('  lua tools/offline_bench.lua --plan out/bench/PLAN.CSV --out out/bench/OFFLINE.csv')
  os.exit(2)
end

MD.usb(true)
MOCKB_SDG({})
bsdg.reset()

-- THE STIMULUS MODEL, ANNOUNCED. Both of these change what the app is shown, so a record produced with
-- them differs from one produced without and the log has to say which it is -- a run whose conditions are
-- not on the record cannot be compared with anything later.
if A.phaseseed == -1 then
  SRC_PHASE(nil)
elseif A.phaseseed ~= nil then
  SRC_PHASE(A.phaseseed)
end
if A.clamp ~= nil then GEN_CLAMP(A.clamp) end
print(string.format('stimulus: capture phase %s, generator envelope %s at %.3f V',
                    SRC.phaserand and ('random, seed ' .. tostring(SRC.phaseseed)) or 'fixed at sample 1',
                    tostring(GENLIM.clamp_mode), GENLIM.clamp_v))

-- COPY THE HOST'S PLAN INTO THE MOCK FILESYSTEM, because the engine reads it through the instrument's
-- file API and must not be handed a host path -- that difference is exactly what the mock is for.
local src = io.open(A.plan, 'r')
if src == nil then print('cannot read ' .. A.plan); os.exit(2) end
local text = src:read('*a')
src:close()
-- THE DIRECTORY FIRST, through ulog's own helper: the mock refuses an open whose parent is absent,
-- exactly as the instrument does, and nothing has created SERDEC yet at this point in the run.
ulog.ensuredir(brun.dir)
local fh = file.open(brun.planpath, file.MODE_WRITE)
if fh == nil then print('cannot write ' .. brun.planpath .. ' in the mock filesystem'); os.exit(2) end
file.write(fh, text)
file.close(fh)

-- The generator knows waveforms by their stored SER_ names and the repo stores files by vector id;
-- the plan carries both in every row, so the mock's mapping comes from the plan itself.
MOCKB_ARBMAP_FROM_PLAN(text)

local nrow = 0
string.gsub(text, '\n', function() nrow = nrow + 1 end)
print(string.format('offline_bench: %d plan line(s), %d iteration(s)', nrow, A.iterations))

local t0 = os.clock()
local ok, why = brun.soak(A.iterations, 'offline')
local dt = os.clock() - t0
print(string.format('soak returned %s: %s  (%.1f s, %d cell(s))', tostring(ok), tostring(why), dt,
                    brun.ncell))
-- HOW OFTEN THE ENVELOPE ACTUALLY BIT. Zero is the expected answer on a plan soakplan.py emitted, because
-- it refuses to write a pair outside the envelope -- so a non-zero count here means the plan came from
-- somewhere else, or the envelope was narrowed, and either way the run is not comparable with the archive.
print(string.format('envelope: %d stimulus(es) altered over %d render(s), %d sample(s) limited',
                    GENLIM.clamp_stimuli, GENLIM.clamp_renders, GENLIM.clamp_samples))

-- AND OUT TO A REAL FILE, so the judge is exercised on bytes rather than on a table in this process.
local rfh = file.open(brec.path, file.MODE_READ)
if rfh == nil then print('the record did not open: ' .. tostring(brec.path)); os.exit(1) end
local body = nil
pcall(function() body = file.read(rfh, file.READ_ALL) end)
pcall(function() file.close(rfh) end)
if body == nil then print('the record read back empty'); os.exit(1) end
local dst = io.open(A.out, 'w')
if dst == nil then print('cannot write ' .. A.out); os.exit(1) end
dst:write(body)
dst:close()
print(string.format('%d byte(s) -> %s', string.len(body), A.out))

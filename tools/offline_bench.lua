-- offline_bench.lua -- run the on-instrument soak engine on the Mac, against a real plan, and write
-- the record out where the host judge can read it.
--
-- WHY THIS EXISTS SEPARATELY FROM test_bench_engine.lua. That suite drives the engine's BRANCHES --
-- the generator dying, the plan wrapping, the key refusing a write. This drives its OUTPUT: a real
-- plan file from soakplan.py, every cell measured against the real rendered vectors, and the resulting
-- CSV dropped on the host filesystem so tools/judge_bench.py can be run against it for real. Together
-- they mean the only thing left untested before instrument time is the instrument itself.
--
-- WHAT IT VALIDATES IS THE ENGINE AND THE FILE FORMAT: a plan in, a judgeable record out. The stimulus
-- models are each printed on the record, because a run whose conditions are not stated cannot be compared
-- with anything later. FIVE of them, and THREE ARE NOW ON BY DEFAULT -- a bare run is the instrument model
-- that ground truth supports, not the raw generator:
--
--   ON   --aperture     the digitiser INTEGRATES over a 0.85 us window rather than point-sampling.
--                        Measured against real DMM samples: 1.07 % of swing against 5.62 % for a point
--                        read. Paired A/B: BAD 2.147 % -> 1.509 %, toward hardware's 1.210 %.
--   ON   --truefs        the digitiser's real rate, 66e6/ceil(66e6/requested). Null on the fail count
--                        three times over; on for COVERAGE, because the requested rate manufactures
--                        ROUND samples-per-bit the bench never gives and round fs hid issue #29.
--   ON   --fracorigin    delivered sample 1 lands at a sub-sample offset, because two independent clocks
--                        never align. Rate-neutral. Costs no PRNG draw, so the phase sequence is
--                        unchanged either way and older records stay comparable.
--   off  --interp        linear between arb samples. REFUTED -- it under-predicts, and the wire shows the
--                        generator HOLDS. Refused with --aperture, which supersedes it.
--   off  --frontend      a 440 kHz pole plus an INTEGER-rounded aperture applied before decimation.
--                        Refused with --aperture; it double-counts, and alone it under-predicts.
--
-- Every one has a --no- form, and BOTH forms are always passed by soak_offline_bench.py so neither arm of
-- an A/B is ever unlabelled. --no-aperture --no-truefs --no-fracorigin reproduces the older behaviour.
-- There is still no noise and no quantisation in any mode.
-- tools/sweep_plan.lua models the front end by default and is where signal fidelity has been argued
-- about; it reached 110 bad WITH it.
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

local A = {plan = nil, out = nil, iterations = 1, phaseseed = nil, clamp = nil, interp = nil,
           truefs = nil, frontend = nil, aperture = nil, fracorigin = nil}
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
  -- LINEAR RECONSTRUCTION BETWEEN ARB SAMPLES, which is an alternative source model and NOT the
  -- generator's measured behaviour -- the one scope measurement of it matches a hold once the vectors'
  -- own encoded ramp is counted. See gen_serial.lua's SRC.interp. A PAIR of flags with no default here,
  -- because the point of the pair is a paired A/B on one seed: --interp and --no-interp each state the
  -- condition on the record, where a single flag would leave one arm unlabelled.
  elseif k == '--interp' then A.interp = true; ai = ai + 1
  elseif k == '--no-interp' then A.interp = false; ai = ai + 1
  -- THE DIGITISER'S ACTUAL RATE, 66e6/ceil(66e6/requested). Same paired-flag reasoning as --interp:
  -- resampling at the requested rate manufactures round samples-per-bit the bench never gives.
  elseif k == '--truefs' then A.truefs = true; ai = ai + 1
  elseif k == '--no-truefs' then A.truefs = false; ai = ai + 1
  -- THE DMM'S 440 kHz POLE AND 1 us APERTURE. Without them the mock is the generator and not the
  -- instrument, and a perfect staircase carries content the DMM cannot see.
  elseif k == '--frontend' then A.frontend = true; ai = ai + 1
  elseif k == '--no-frontend' then A.frontend = false; ai = ai + 1
  -- THE DIGITISER'S APERTURE AS AN INTEGRAL, at the measured 0.85 us. This is the instrument model the
  -- ground-truth captures support: mean residual 1.07 % of swing against linear's 2.18 % and the held
  -- default's 5.62 %. Same paired-flag reasoning as --interp. Do NOT combine with --frontend, which
  -- rounds the aperture to whole arb samples and applies it before decimation, so the two double-count.
  elseif k == '--aperture' then A.aperture = true; ai = ai + 1
  elseif k == '--no-aperture' then A.aperture = false; ai = ai + 1
  -- A SUB-SAMPLE CAPTURE ORIGIN. SRC.phase is an integer index, so delivered sample 1 has always landed
  -- exactly on an arb sample, which two independent clocks never do. Same paired-flag reasoning as
  -- --interp. It costs no PRNG draw, so the phase sequence is unchanged either way.
  elseif k == '--fracorigin' then A.fracorigin = true; ai = ai + 1
  elseif k == '--no-fracorigin' then A.fracorigin = false; ai = ai + 1
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
if A.interp ~= nil then SRC_INTERP(A.interp) end
if A.truefs ~= nil then SRC_TRUEFS(A.truefs) end
if A.frontend ~= nil then SRC_FRONTEND(A.frontend) end
if A.aperture ~= nil then SRC_APERTURE(A.aperture) end
if A.fracorigin ~= nil then SRC_FRACORIGIN(A.fracorigin) end
-- TWO COMBINATIONS ARE REFUSED, AND BOTH FOR THE SAME REASON: the run would record a condition it did
-- not actually apply, and a record whose conditions are wrong is worse than no record -- it will be
-- compared against something later by someone who trusts the header.
if SRC.aperture and SRC.frontend then
  print('REFUSING: --aperture and --frontend both model the DMM aperture, so together they apply it')
  print('  twice. GEN_FRONTEND rounds it to whole arb samples before decimation; --aperture applies a')
  print('  fractional window at the delivered instants. THE APERTURE IS NOW ON BY DEFAULT, so --frontend')
  print('  on its own lands here: add --no-aperture to get the old front-end model back.')
  os.exit(2)
end
if SRC.aperture and SRC.interp then
  print('REFUSING: --aperture SUPERSEDES --interp, so asking for both would log a reconstruction that')
  print('  never ran -- SRC_val returns from the aperture branch before reaching the interpolating one,')
  print('  measured as interp_n staying at 0. That is the correct behaviour and not a bug: the aperture')
  print('  integral already assumes the generator HOLDS, which is what the wire measures, and linear')
  print('  reconstruction is a cheap approximation to the same average rather than something to add to')
  print('  it. THE APERTURE IS NOW ON BY DEFAULT, so --interp on its own lands here: add --no-aperture')
  print('  to get the interpolating source model back.')
  os.exit(2)
end
print(string.format('stimulus: capture phase %s, envelope %s at %.3f V, reconstruction %s, rate %s, front end %s, aperture %s, origin %s',
                    SRC.phaserand and ('random, seed ' .. tostring(SRC.phaseseed)) or 'fixed at sample 1',
                    tostring(GENLIM.clamp_mode), GENLIM.clamp_v,
                    SRC.interp and 'linear between arb samples' or 'zero-order hold',
                    SRC.truefs and '66e6/ceil(66e6/requested)' or 'as requested',
                    SRC.frontend and '440 kHz pole + 1 us aperture' or 'none',
                    SRC.aperture and string.format('integral, %.2f us window', AP_WIDTH_S * 1e6)
                                  or 'point sample',
                    SRC.fracorigin and 'sub-sample' or 'on an arb sample'))

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

-- test_ratefit.lua -- reproduce the hardware rate misfit (#46) and the silently-wrong-at-a-correct-rate
-- class (#125) OFFLINE, which no existing suite can do.
--
-- WHY THE OTHER SUITES CANNOT SEE THESE. Two independent blind spots, both in the RENDER rather than in
-- the decoder, and either one alone is enough to hide the whole family:
--
--   1. SAMPLES PER BIT IS A ROUND NUMBER. tools/sweep_startphase.lua renders each vector at v.fs, and
--      the vectors are built at spb 10 -- v90 is baud 9600 at 96000 Sa/s, exactly 10.000 sa/bit. The
--      misfit needs floor(sa/bit)/(sa/bit) inside (0.8696, 0.9326): m = 10 requires T <= 9Tb/9.5, and
--      the fit's 0.35T admission gate requires 9Tb/10.35 < T < 9Tb/9.65. At exactly 10.000 the ratio is
--      1.0000 and the window is unreachable BY CONSTRUCTION. On hardware SP.pick_fs gives 8.33, 8.00,
--      11.97, 12.87 and so on, and the cells that misreport are the ones inside the window.
--
--   2. THE EDGE IS RENDERED IN SAMPLES, NOT IN TIME. gen_serial's `rise` is in SAMPLE PERIODS and
--      defaults to 1.5, so the edge SHARPENS as fs falls and blurs as fs rises -- the opposite of the
--      instrument, where the edge is fixed in time by the digitizer's bandwidth and therefore shrinks
--      in samples as fs rises. At a constant 1.5 samples the fit lands on the truth at every rate and
--      the family never appears. This file passes rise in TIME and converts per render.
--
-- Run from the repo root:  lua tools/test_ratefit.lua
--
-- THE EDGE TIME IS AN ESTIMATE, NOT A MEASUREMENT. RISE_S is set from the DMM's ~440 kHz digitize
-- bandwidth on the 10 V range, which is a datasheet figure, not something measured on this bench. What
-- the assertions below depend on is NOT its exact value: it is that the edge is fixed in TIME, so that
-- the smallest measured pulse width is short in samples at high fs. Measuring the real edge would let
-- RISE_S be tightened; it would not change the shape of the result.
--
-- WHAT IS ASSERTED. Deliberately NOT "the decoder is correct here" -- it is not, and #46/#125 are open
-- and knowingly unfixed. These are CHARACTERISATION assertions: the defect reproduces, the null stays
-- clean, and the numbers are pinned so a change in either direction is visible. A fix to #46 will fail
-- this file, and that is the point -- it is the test that #46 currently does not have.

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local RISE_S = 1.5e-6              -- edge transition time, seconds; see the header
local NPHASE = 16                  -- capture start phases per cell
local SNAP = 0.02                  -- sdec.snaptol: how close a report must be to count as right

local pass, fail = 0, 0
local function ck(cond, what, detail)
  if cond then pass = pass + 1 else fail = fail + 1 end
  print(string.format('  %-4s %s%s', cond and 'PASS' or 'FAIL', what,
                      detail ~= nil and ('   ' .. tostring(detail)) or ''))
end

-- ---------------------------------------------------------------------------
-- Payloads. blocks256 is v90 (hard_blocks(64) from make_vectors.lua); lorem1k stands in for v71; fox
-- and rand are the NULLS -- they pass every cell on hardware and must stay clean here, because a
-- reproduction that fires on everything has demonstrated nothing.
-- ---------------------------------------------------------------------------
local function blocks256()
  local by, nb, pats, i, k = {}, 0, {0x00, 0xFF, 0x55, 0xAA}, 0, 0
  for i = 1, 4 do for k = 1, 64 do nb = nb + 1; by[nb] = pats[i] end end
  return by, nb
end

local function from_string(s, n)
  local by, nb, i = {}, 0, 0
  for i = 1, n do nb = nb + 1; by[nb] = string.byte(s, math.mod(i - 1, string.len(s)) + 1) end
  return by, nb
end

local LOREM = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor ' ..
              'incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud ' ..
              'exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.'
local FOX = 'The quick brown fox jumps over the lazy dog. '

local function lorem1k() return from_string(LOREM, 1024) end
local function fox256() return from_string(FOX, 256) end
local function rand256()
  GEN_RESEED(20260827)
  local by, nb, i = {}, 0, 0
  -- GEN_RAND returns a FLOAT in [0,1). math.mod on it leaves a fraction, and a fractional payload
  -- renders as garbage -- which made this 'null' fail 96 of 128 cells, worse than the vector under
  -- test. A null that fails is not a null.
  for i = 1, 256 do nb = nb + 1; by[nb] = math.floor(GEN_RAND() * 256) end
  return by, nb
end

-- ---------------------------------------------------------------------------
-- One cell: render at `fs` with the edge fixed in TIME, then run the real signal chain and decode.
-- Returns the reported baud, the raw fit, and the decoded byte array.
-- ---------------------------------------------------------------------------
local function decode_cell(by, nb, baud, fs, phase)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.baud, sdec.baud_raw = nil, nil
  sdec.clear_result()
  local rd, ts, nc, nsmp = GEN({bytes = by, baud = baud, fs = fs, gap = 0, noise = 0.02,
                                lead = 20 + phase,
                                -- THE WHOLE POINT: seconds converted to samples per render, so the
                                -- edge does not sharpen when fs falls.
                                rise = RISE_S * fs})
  local ok = pcall(function()
    sdec.acq_fs, sdec.fs = fs, fs
    sdec.sig_levels(rd, nsmp)
    sdec.sig_edges(rd, nsmp)
    sdec.sig_idle(rd, nsmp)
    return sdec.decode_from(rd, nsmp)
  end)
  return sdec.baud, sdec.baud_raw, (sdec.res or {}), ok
end

-- Is `got` the payload, read at ANY offset in the looping payload? Mirrors what the bench judge does,
-- so a byte run that is correct-but-rotated counts as correct rather than as silently wrong.
local function matches_payload(res, by, nb)
  local n = res.nf or 0
  if n < 24 then return nil end                      -- too short to judge either way
  -- res.vals, NOT res.bytes: there is no `bytes` key, so guessing one made this whole check return
  -- nil every time and the silently-wrong column read 0 because it COULD not read anything else.
  local bytes = res.vals
  if bytes == nil then return nil end
  local bestv, cand, j = -1, 0, 0
  for cand = 0, nb - 1 do
    local v = 0
    for j = 1, n do
      local want = by[math.mod(cand + j - 1, nb) + 1]
      if bytes[j] == want then v = v + 1 end
    end
    if v > bestv then bestv = v end
  end
  return bestv / n
end

-- ---------------------------------------------------------------------------
-- The sweep. Rates are the hardware ones that misreported, plus std neighbours that did not, and the
-- sample rates are the FRACTIONAL ones SP.pick_fs actually selects -- expressed here as sa/bit so the
-- window arithmetic in the header is checkable by eye.
-- ---------------------------------------------------------------------------
local CELLS = {
  -- baud,   sa/bit,  in the (0.8696, 0.9326) window?
  {28800,  11.97, true},
  {28800,   8.33, false},
  {5810,   12.87, true},
  {8189,    9.78, true},
  {57600,   8.68, true},
  {9600,    8.00, false},
  {19200,   8.33, false},
  {1800,    8.33, false},
}

local PAYLOADS = {
  {'blocks256', blocks256, 'v90'},
  {'lorem1k',   lorem1k,   'v71'},
  {'fox256',    fox256,    'NULL'},
  {'rand256',   rand256,   'NULL'},
}

print(string.format('test_ratefit: edge %.2f us fixed in TIME, %d phases/cell',
                    RISE_S * 1e6, NPHASE))
print('')

local results = {}
local pi, ci, ph
for pi = 1, table.getn(PAYLOADS) do
  local name, fn, tag = PAYLOADS[pi][1], PAYLOADS[pi][2], PAYLOADS[pi][3]
  local by, nb = fn()
  local nrate, nwrong, ncell = 0, 0, 0
  for ci = 1, table.getn(CELLS) do
    local baud, sab = CELLS[ci][1], CELLS[ci][2]
    local fs = baud * sab
    for ph = 0, NPHASE - 1 do
      ncell = ncell + 1
      local rb, raw, res, ok = decode_cell(by, nb, baud, fs, ph)
      if ok and rb ~= nil then
        local d = (rb - baud) / baud
        if d < 0 then d = -d end
        if d > SNAP then
          nrate = nrate + 1
        else
          local cov = matches_payload(res, by, nb)
          -- SILENTLY WRONG: the rate is right and the bytes are not the payload at any rotation.
          if cov ~= nil and cov < 0.5 then nwrong = nwrong + 1 end
        end
      end
    end
  end
  results[name] = {rate = nrate, wrong = nwrong, cells = ncell, tag = tag}
  print(string.format('  %-10s %-5s %3d cells   %3d rate-misreport   %3d silently-wrong-at-right-rate',
                      name, tag, ncell, nrate, nwrong))
end
print('')

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------
local B, L = results['blocks256'], results['lorem1k']
local F, R = results['fox256'], results['rand256']

-- #46 REPRODUCES. This is the assertion no existing suite can make.
ck(B.rate > 0, 'blocks256 misreports the rate offline (#46 reproduces)',
   string.format('%d of %d cells', B.rate, B.cells))

-- AND THE NULLS STAY CLEAN. Without this the line above proves only that the render is broken.
ck(F.rate == 0, 'fox is never rate-misreported (null holds)',
   string.format('%d of %d', F.rate, F.cells))
ck(R.rate == 0, 'random is never rate-misreported (null holds)',
   string.format('%d of %d', R.rate, R.cells))

-- THE WINDOW IS THE DISCRIMINATOR, not the payload alone: cells outside (0.8696, 0.9326) must not
-- misreport even for blocks256. Recomputed here rather than asserted from the table.
do
  local by, nb = blocks256()
  local inwin, outwin = 0, 0
  local ci, ph
  for ci = 1, table.getn(CELLS) do
    local baud, sab, want = CELLS[ci][1], CELLS[ci][2], CELLS[ci][3]
    local fs = baud * sab
    local fr = math.floor(sab) / sab
    local isin = (fr > 0.8696 and fr < 0.9326)
    ck(isin == want, string.format('sa/bit %.2f -> floor/sab %.4f, in-window = %s', sab, fr,
                                   tostring(isin)))
    for ph = 0, NPHASE - 1 do
      local rb = decode_cell(by, nb, baud, fs, ph)
      if rb ~= nil then
        local d = (rb - baud) / baud
        if d < 0 then d = -d end
        if d > SNAP then
          if isin then inwin = inwin + 1 else outwin = outwin + 1 end
        end
      end
    end
  end
  ck(inwin > 0, 'blocks256 misreports INSIDE the window', inwin)
  ck(outwin == 0, 'blocks256 never misreports OUTSIDE the window', outwin)
end

print('')
print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

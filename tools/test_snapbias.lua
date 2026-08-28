-- Does JITTER ALONE bias the width fit enough for sig_snap to relabel a rate? Measured answer: NO.
--
-- WHY THIS FILE EXISTS AS A NULL. A hardware lap produced three cases where the reported rate was a
-- standard rate 2.4-2.7 % above the commanded one while every byte decoded correctly -- 37422 read as
-- 38400, 149527 as 153600, 187477 as 192000. All three came from j10, the 10 % jitter vector, and the
-- obvious hypothesis was that 10 % jitter (which docs/MANUAL.md declares tolerable) biases the fit.
--
-- THE HYPOTHESIS IS REFUTED HERE, which is worth more than another failing assertion: with independent
-- per-edge jitter on a non-repeating payload the fit error is +0.005 % at 10 % jitter and +0.081 % at
-- 25 %, against the +0.36 to +0.67 % needed to reach the neighbouring standard rate's snap window. So the
-- manual's +/-15 % jitter tolerance is NOT the thing to change, and the decoder's fit is not
-- jitter-biased in any direction that matters.
--
-- WHERE THE REAL REPRODUCTION LIVES. tools/sweep_plan.lua reproduces the defect against the actual arb
-- files at 24 points a lap, matching the hardware rate per cell (0.17 % offline against 0.18 % on the
-- instrument). What differs there and cannot be reproduced by rendering directly at the capture rate is
-- the RESAMPLING: those arbs are rendered at baud x spb and decimated to pick_fs, 12.47:1 for the 37422
-- case, and the measured fit bias is +0.70 to +0.75 % on every capture phase -- consistent rather than
-- scattered, so it is a property of that waveform's realisation and its resampling, not of jitter.
--
-- SO WHAT THIS FILE GUARDS is the null: if a future change makes plain jitter bias the fit, the numbers
-- below move and the assertions fail. That is the boundary worth pinning, because a jitter-biased fit
-- would put every rate near the standard ladder at risk rather than the handful of drawn ones.

dofile('tools/gen_serial.lua')

local NPHASE   = 8          -- capture start phases per cell
local JITTERS  = {0, 2, 4, 6, 8, 10, 12, 15, 25}     -- per cent of a bit time
local PAYBYTES = 256
-- HOW MUCH FIT ERROR THE SNAP NEEDS, the smallest of the three hardware cases. Any measured bias below
-- this cannot relabel a rate however unlucky the draw, which is what makes it a usable ceiling.
local SNAP_NEEDS = 0.36

-- The three rates hardware misreported, each just under a standard rate and none snapping on its own.
local CASES = {
  {37422,  38400},
  {149527, 153600},
  {187477, 192000},
}

local pass, fail = 0, 0
local function ck(cond, what, detail)
  if cond then pass = pass + 1; print('  PASS  ' .. what .. (detail and ('   ' .. detail) or ''))
  else fail = fail + 1; print('  FAIL  ' .. what .. (detail and ('   ' .. detail) or '')) end
end

-- A NON-REPEATING payload, so the fit sees a wide spread of run lengths. A periodic one would add its own
-- rate ambiguity and confuse this measurement with issue #46's harmonic route.
local function payload()
  local b, n = {}, 0
  GEN_RESEED(20260828)
  local i
  for i = 1, PAYBYTES do n = n + 1; b[n] = math.mod(i * 37 + math.floor(i / 5) * 11, 256) end
  return b, n
end

-- One capture: render at `baud` with `jpct` per cent jitter, decode, report what the panel would say.
local function probe(by, nb, baud, jpct, phase)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.baud, sdec.baud_raw, sdec.bittime, sdec.snapped = nil, nil, nil, nil
  sdec.res, sdec.ck_tot = nil, nil
  local fs = sdec.pick_fs(baud, 8)
  -- RESEEDED PER POINT so a cell's outcome cannot depend on how much of the stream earlier cells drew.
  GEN_RESEED(20260828 + baud + jpct * 7919 + phase)
  local rd, ts, nc, ns = GEN({bytes = by, baud = baud, fs = fs, nbits = 8, par = 0,
                              gap = 1, lead = 20 + phase, tail = 20, loop = false})
  -- JITTER AS A FRACTION OF A BIT, converted to samples, so the axis means the same thing at every rate --
  -- the manual states its tolerance as a fraction of a bit, not as a time.
  if jpct > 0 then GEN_RELAY(rd, ns, {jitter_sa = (jpct / 100) * (fs / baud)}) end
  local ok = pcall(function()
    sdec.acq_fs, sdec.fs = fs, fs
    sdec.sig_levels(rd, ns); sdec.sig_edges(rd, ns); sdec.sig_idle(rd, ns)
    return sdec.decode_from(rd, ns)
  end)
  return ok, sdec.baud, sdec.baud_raw, sdec.snapped
end

print('test_snapbias: does jitter alone bias the width fit into a wrong standard rate?')
print(string.format('%d rates x %d jitter levels x %d phases, non-repeating payload',
                    table.getn(CASES), table.getn(JITTERS), NPHASE))
print('')

local by, nb = payload()
local SNAP = sdec.snaptol or 0.02
local results, raised = {}, 0

local ji
for ji = 1, table.getn(JITTERS) do
  local j = JITTERS[ji]
  local wrong, tried, worstbias = 0, 0, 0
  local ci, ph
  for ci = 1, table.getn(CASES) do
    local baud = CASES[ci][1]
    for ph = 0, NPHASE - 1 do
      local ok, rb, raw = probe(by, nb, baud, j, ph)
      if not ok then raised = raised + 1 end
      if ok and rb ~= nil then
        tried = tried + 1
        local lerr = rb / baud - 1
        if lerr < 0 then lerr = -lerr end
        if lerr > SNAP then wrong = wrong + 1 end
        -- THE FIT'S OWN ERROR, which is the quantity the hypothesis is about. The label error is a
        -- consequence of it, so measuring only the label would hide a fit that is drifting but has not
        -- yet crossed a snap window.
        if raw ~= nil then
          local berr = raw / baud - 1
          if berr < 0 then berr = -berr end
          if berr > worstbias then worstbias = berr end
        end
      end
    end
  end
  results[j] = {wrong = wrong, tried = tried, bias = worstbias}
  print(string.format('  jitter %2d %%   fit bias up to %+.3f %%   %d of %d points mislabelled',
                      j, worstbias * 100, wrong, tried))
end
print('')

ck(raised == 0, 'no capture RAISED -- a crash is not a clean measurement', tostring(raised))

-- THE NULL ITSELF, at every level the manual declares tolerable and beyond it.
local overall, worstj = 0, nil
local k
for k = 1, table.getn(JITTERS) do
  local j = JITTERS[k]
  if results[j].bias > overall then overall, worstj = results[j].bias, j end
end
ck(overall * 100 < SNAP_NEEDS,
   string.format('independent jitter never biases the fit the %.2f %% a relabel needs', SNAP_NEEDS),
   string.format('worst %+.3f %% at %d %% jitter', overall * 100, worstj or -1))

local anywrong = 0
for k = 1, table.getn(JITTERS) do anywrong = anywrong + results[JITTERS[k]].wrong end
ck(anywrong == 0, 'and no rate is ever relabelled, at any jitter level tested', tostring(anywrong))

-- THE TOLERANCE THE MANUAL CLAIMS IS SPECIFICALLY CLEARED, so the claim is pinned rather than implied.
ck(results[15].bias * 100 < SNAP_NEEDS,
   'at the +/-15 % the manual declares tolerable the fit is still far from a relabel',
   string.format('%+.3f %%', results[15].bias * 100))

-- AND A CLEAN LINE IS EXACT, or the whole sweep is measuring a broken render rather than jitter.
ck(results[0].bias * 100 < 0.01, 'a jitter-free line fits its rate to better than 0.01 %',
   string.format('%+.4f %%', results[0].bias * 100))

print('')
print('  CONCLUSION: jitter is not the cause. The reproduction that matters is tools/sweep_plan.lua')
print('  against the real arbs, where resampling a looping waveform biases the fit by +0.70 to +0.75 %.')
print('')
print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

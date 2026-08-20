-- sweep_rates.lua -- what would extra sample rates be WORTH, and does the decoder
-- survive them?
--
-- sdec.rates is {1k, 10k, 20k, 50k, 100k, 200k, 500k, 1M} -- a 1/2/5 series, and the
-- comment above it says "only DECIMAL sample rates are exact on this instrument". That
-- claim rests on the nine rates measured in notes/FINDINGS.md, eight exact and one
-- (102400) not. Nothing between 200 k and 500 k was ever tried, and the gap costs real
-- bytes: fs_for_baud picks the LOWEST listed rate at or above baud x 8, so 38400 needs
-- 307200 and gets 500000 -- 13.02 samples/bit, 63 % of the samples spent on oversampling
-- nobody asked for.
--
-- TWO SEPARATE QUESTIONS, and only one of them needs the instrument:
--
--   BENCH   does the hardware accept the rate, and what does it ACTUALLY produce?
--           Answered by BRINGUP 4b.11: set it, capture, derive fs from timestamps.
--   OFFLINE does the decoder still work at the samples/bit the new rate implies?
--           Answered here, now, by generating a vector at that exact ratio and
--           decoding it with the real code.
--
-- Run:  lua tools/sweep_rates.lua            both sections
--       lua tools/sweep_rates.lua table      the payoff arithmetic only
--       lua tools/sweep_rates.lua decode     the decode sweep only

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local WHICH = arg and arg[1]
local function want(sec) return WHICH == nil or WHICH == sec end

-- Candidate rates, in the order they are worth asking the instrument about. The 10000 x 2^k
-- ladder is the interesting one: every baud in the 1200 x 2^k family lands on exactly
-- 8.333 samples/bit, which is the ratio 1200 and 2400 already get and the most oversampling
-- the 8-samples/bit target will ever leave on the table.
-- The low four exist because sdec.stdbaud goes down to 110 and the stock ladder has a TEN-FOLD
-- hole between 1 k and 10 k: 300 baud lands on 10 kS/s at 33 samples/bit and holds 60 bytes.
-- 2500 and 5000 continue the same 10000 / 2^k ladder downward; 900 is the one odd number in the
-- list and it is there solely for 110 baud, which needs 880.
local CAND = {900, 1250, 2500, 5000, 15000, 30000, 40000, 60000, 80000, 120000, 160000,
              250000, 300000, 320000, 350000, 400000, 640000}

-- sdec.stdbaud, the app's OWN list, not a hand-written set of the common ones. A local list drifts
-- away from what the app believes: one with no entry below 1200 reports a clean bill while 300 baud
-- -- which IS in stdbaud, and is what slow bit-banged hardware runs at -- holds only 60 bytes.
-- Deriving the sweep from the app's own definition of "standard" is what makes that impossible.
local BAUDS = sdec.stdbaud
local NAMED = {[31250] = 'MIDI', [250000] = 'DMX512'}

local STREAM_N = 2800000     -- the deep-capture buffer BRINGUP 4b.2 will size for real

local function lowest_at_or_above(rates, need)
  local best = nil
  for _, r in ipairs(rates) do
    if r >= need and (best == nil or r < best) then best = r end
  end
  return best
end

-- The app's own capacity arithmetic, with n as a parameter so the same function answers
-- for the 20000-sample frame window and the 2.8 M-sample stream buffer.
local function bytes_at(n, baud, fs)
  local saved_n, saved_fs = sdec.n, sdec.acq_fs
  sdec.n, sdec.acq_fs = n, fs
  local b = sdec.window_bytes(baud, 8, sdec.PAR_NONE, 1)
  sdec.n, sdec.acq_fs = saved_n, saved_fs
  return b
end

-- ============================================================================
if want('table') then
-- ============================================================================
print('')
print('WHAT THE EXTRA RATES WOULD BUY  (8N1, target ' .. sdec.fs_sabit .. ' samples/bit)')
print('')
print('                        now                        with candidates')
print('  baud        fs    sa/bit  frame  stream        fs    sa/bit  frame  stream   gain')
print('  ' .. string.rep('-', 88))

local ext = {}
for _, r in ipairs(sdec.rates) do ext[table.getn(ext) + 1] = r end
for _, r in ipairs(CAND) do ext[table.getn(ext) + 1] = r end

local wins, refused = 0, 0
for _, baud in ipairs(BAUDS) do
  local need = baud * sdec.fs_sabit
  local now  = lowest_at_or_above(sdec.rates, need) or 1000000
  local new  = lowest_at_or_above(ext, need) or 1000000
  local tag = ''
  if NAMED[baud] then tag = '  <- ' .. NAMED[baud] end
  -- Past the 1 MS/s wall the app REFUSES rather than decoding short, so these rows would
  -- otherwise print a large, meaningless byte count. Named, not silently dropped.
  if new / baud < sdec.minsabit then
    refused = refused + 1
    print(string.format('  %6d  %8d  %6.2f  -- refused, under minsabit %d --%s',
          baud, new, new / baud, sdec.minsabit, tag))
  else
  local gain = ''
  if new < now then
    wins = wins + 1
    gain = string.format('%.2fx', now / new)
  else
    gain = '   --'
  end
  print(string.format('  %6d  %8d  %6.2f  %5d  %6d    %8d  %6.2f  %5d  %6d  %6s%s',
        baud, now, now / baud, bytes_at(sdec.n, baud, now), bytes_at(STREAM_N, baud, now),
        new, new / baud, bytes_at(sdec.n, baud, new), bytes_at(STREAM_N, baud, new),
        gain, tag))
  end
end
print('')
print(string.format('  %d of %d rates in sdec.stdbaud improve (%d are past the 1 MS/s wall and',
      wins, table.getn(BAUDS), refused))
print('  refused either way). NO baud gets worse: a candidate is')
print('  only ever chosen when it is BELOW the rate already picked and still at or above')
print('  baud x ' .. sdec.fs_sabit .. ', so the oversampling target is never relaxed to get these.')
print('')
-- The stream column is the one that touches an open design question: the 32 kB mode cannot
-- currently reach 32 kB at most rates, which is a recorded PLAUSIBLE finding awaiting a
-- bench decision on ck_bufmax. Some of these candidates settle it without touching the cap.
print('  EFFECT ON THE 32 kB MODE (cap 32768, buffer ' .. STREAM_N .. ' samples):')
for _, baud in ipairs(BAUDS) do
  local need = baud * sdec.fs_sabit
  local now  = lowest_at_or_above(sdec.rates, need) or 1000000
  local new  = lowest_at_or_above(ext, need) or 1000000
  if new < now then
    local bn, bx = bytes_at(STREAM_N, baud, now), bytes_at(STREAM_N, baud, new)
    local was, is = 'short', 'short'
    if bn >= 32768 then was = 'REACHES' end
    if bx >= 32768 then is = 'REACHES' end
    if was ~= is then
      print(string.format('    %6d baud: %d -> %d bytes -- %s 32 kB becomes reachable',
            baud, bn, bx, NAMED[baud] or ''))
    else
      print(string.format('    %6d baud: %d -> %d bytes (%s either way)', baud, bn, bx, is))
    end
  end
end
print('')
end

-- ============================================================================
if want('gaps') or WHICH == nil then
-- ============================================================================
-- THE NINE STANDARD BAUDS ARE NOT THE METRIC. The options form accepts any forced rate and
-- the detector reports any rate it finds, so what actually bounds this app is the WORST CASE
-- OVER ALL BAUDS -- and that is decided by one number: the largest ratio between consecutive
-- rungs of the ladder.
--
-- The reason is exact. fs_for_baud picks the lowest rung at or above baud x 8, so the worst
-- baud for a given rung is the one JUST above rung/8: its target clears the rung by a hair
-- and it gets thrown up to the next one, ending at
--
--     samples/bit = next_rung / (rung / 8) = 8 x (next_rung / rung)
--
-- So a 2.5x gap in the ladder means somebody, somewhere, runs at 20 samples/bit and gets 40 %
-- of the bytes they could have. Filling gaps is worth more than adding rungs at the top.
local function ladder_worst(rates, label)
  local sorted = {}
  for _, r in ipairs(rates) do sorted[table.getn(sorted) + 1] = r end
  table.sort(sorted)
  local worst, wat, wnext = 0, nil, nil
  for i = 1, table.getn(sorted) - 1 do
    local ratio = sorted[i + 1] / sorted[i]
    -- NOTHING IS EXCLUDED any more, and the reason is a mistake worth leaving a note about.
    -- This started at `>= 10000`, on the stated grounds that the 1 k -> 10 k gap "only bites
    -- below 1250 baud and nothing this app is for runs there". sdec.stdbaud contains 110, 300
    -- and 600. That gap is the single worst rung in the stock ladder -- TEN-fold, against 2.5x
    -- for the next worst -- and excluding it hid the largest defect this sweep was written to
    -- find. An exclusion justified by a claim about what users do is a way of not measuring.
    if sorted[i] >= 1000 and ratio > worst then
      worst, wat, wnext = ratio, sorted[i], sorted[i + 1]
    end
  end
  local sabit = sdec.fs_sabit * worst
  local baud = wat / sdec.fs_sabit
  print(string.format('  %-12s worst gap %7d -> %7d  (%.2fx)  =  %5.2f samples/bit  %3d bytes',
        label, wat, wnext, worst, sabit,
        bytes_at(sdec.n, math.floor(baud) + 1, wnext)))
  return worst, wat, wnext
end

print('WORST CASE OVER ALL BAUDS  (what actually bounds the app)')
print('')
local ext = {}
for _, r in ipairs(sdec.rates) do ext[table.getn(ext) + 1] = r end
for _, r in ipairs(CAND) do ext[table.getn(ext) + 1] = r end
ladder_worst(sdec.rates, 'today:')
ladder_worst(ext, 'candidates:')
print('')
print('  The stock ladder is worst not at the top but at the BOTTOM: 1 k -> 10 k is a ten-fold')
print('  gap, so 300 baud (in sdec.stdbaud) runs at 33 samples/bit for 60 bytes and 600 baud')
print('  at 16.7 for 120. That is the largest single defect here and it is invisible unless')
print('  the sweep uses the app\'s own baud list rather than a hand-picked set of common ones.')
print('')
print('  The rungs that matter are therefore the ones that CLOSE A GAP, not the ones that')
print('  serve a named baud. Ranked by the ratio each one removes:')
local sorted = {}
for _, r in ipairs(sdec.rates) do sorted[table.getn(sorted) + 1] = r end
table.sort(sorted)
local gaps = {}
for i = 1, table.getn(sorted) - 1 do
  -- >= 1000, i.e. everything. Same exclusion as ladder_worst had and the same reason for
  -- dropping it: the 1 k -> 10 k gap is the worst rung in the ladder and cutting it out of
  -- the ranking is what kept 300 baud's 60-byte window off this list.
  if sorted[i] >= 1000 then
    local best, bestr = nil, nil
    for _, c in ipairs(CAND) do
      if c > sorted[i] and c < sorted[i + 1] then
        -- The rung that most reduces the WORST of the two halves it creates.
        local half = math.max(c / sorted[i], sorted[i + 1] / c)
        if best == nil or half < bestr then best, bestr = c, half end
      end
    end
    if best ~= nil then
      gaps[table.getn(gaps) + 1] = {lo = sorted[i], hi = sorted[i + 1], was = sorted[i + 1] / sorted[i],
                                    add = best, now = bestr}
    end
  end
end
table.sort(gaps, function(a, b) return a.was > b.was end)
for _, g in ipairs(gaps) do
  print(string.format('    %7d -> %7d  was %.2fx (%5.2f sa/bit)  add %6d  -> %.2fx (%5.2f sa/bit)',
        g.lo, g.hi, g.was, sdec.fs_sabit * g.was, g.add, g.now, sdec.fs_sabit * g.now))
end
print('')
print('  ONE rung per gap is what is ranked above; TWO do better where both are available.')
print('  20 k -> 50 k with 30 k AND 40 k gives 1.5x / 1.33x / 1.25x -- worst 12.0 sa/bit')
print('  rather than 13.3. So ask the instrument about every candidate, then keep the ones')
print('  that measure exact: this is a list to TEST, not a list to install.')
print('')
end

-- ============================================================================
if want('spec') or WHICH == nil then
-- ============================================================================
-- THE TWO NUMBERS THE PANEL WOULD STATE, CHECKED RATHER THAN ASSERTED.
--
-- The point of extending the ladder is not per-baud arithmetic on screen, it is being able to
-- say ONE thing about frame capacity and have it be true. A number the operator can hold in
-- their head beats a cell that changes every time they lock a different rate -- so what
-- matters is the FLOOR, and a floor is only worth stating if nothing gets under it.
--
-- Two tiers, and THE DISCRIMINATOR IS sdec.snapped, not "is this a round number". That matters
-- for the case the tiers exist to serve. A bit-banged UART misses its target rate by whatever
-- its clock divisor rounds to, and sig_snap pulls anything within sdec.snaptol (2 %) onto the
-- standard rate -- so lock_toggle stores the SNAPPED value in force_baud, fs_for_baud sees a
-- standard rate, and a device 1.8 % fast gets the full standard-tier window. Timing error up to
-- 2 % costs nothing at all. Past 2 % the raw measured rate is what gets forced, the panel marks
-- it with a '?', and the window is whatever the ladder gives at that rate.
--
-- Tiers apply to the LOCKED path only. Unlocked, fs is sdec.fs_default (1 MS/s) whatever the
-- line is doing -- 19 bytes at 9600 -- which is the whole reason the padlock exists.
local STD_FLOOR, ANY_FLOOR = 230, 160

local ext = {}
for _, r in ipairs(sdec.rates) do ext[table.getn(ext) + 1] = r end
for _, r in ipairs(CAND) do ext[table.getn(ext) + 1] = r end
table.sort(ext)
local function pick(need)
  for _, r in ipairs(ext) do if r >= need then return r end end
  return ext[table.getn(ext)]
end
-- A rate under minsabit is REFUSED, not decoded short, so it must not drag the floor down:
-- 460800 and 921600 are in stdbaud and are past the 1 MS/s wall by design.
local function cap_bytes(b)
  local fs = pick(b * sdec.fs_sabit)
  if fs / b < sdec.minsabit then return nil end
  return bytes_at(sdec.n, b, fs)
end

print('THE STATED FLOOR, VERIFIED  (what the UI would promise instead of a per-baud number)')
print('')
-- sdec.stdbaud, the app's OWN list -- 22 entries including 110, 300, 600, 1800, 7200, 14400,
-- 28800, 76800 and 128000. Checking a hand-picked list of "the common ones" instead is how the
-- 300-baud hole got missed: it is 60 bytes on the stock ladder and nothing in a nine-entry
-- sample of round rates would have shown it.
local sworst, sbaud = 1e9, nil
for _, b in ipairs(sdec.stdbaud) do
  local n = cap_bytes(b)
  if n ~= nil and n < sworst then sworst, sbaud = n, b end
end
-- Every integer baud, not a sample of them: the worst case sits one baud ABOVE a rung/8
-- boundary, which no list of round numbers would ever contain.
local aworst, abaud = 1e9, nil
for b = 1200, 250000 do
  local n = cap_bytes(b)
  if n ~= nil and n < aworst then aworst, abaud = n, b end
end
local lworst, lbaud = 1e9, nil
for b = 110, 1199 do
  local n = cap_bytes(b)
  if n ~= nil and n < lworst then lworst, lbaud = n, b end
end
print(string.format('  SNAPPED (any of the %d rates in sdec.stdbaud): at least %3d bytes  ' ..
      '(worst %6d)  claim %d  %s',
      table.getn(sdec.stdbaud), sworst, sbaud, STD_FLOOR,
      (sworst >= STD_FLOOR) and 'OK' or 'FAILS'))
print(string.format('  NOT SNAPPED, 1200..250000 baud:            at least %3d bytes  ' ..
      '(worst %6d)  claim %d  %s',
      aworst, abaud, ANY_FLOOR, (aworst >= ANY_FLOOR) and 'OK' or 'FAILS'))
print(string.format('  NOT SNAPPED, 110..1199 baud:               at least %3d bytes  (worst %6d)',
      lworst, lbaud))
print('')
print('  The low four rungs (900, 1250, 2500, 5000) are what make the FIRST line true. The')
print('  stock ladder has a ten-fold hole between 1 k and 10 k, so on it 300 baud -- which is')
print('  in stdbaud -- runs at 33 samples/bit and holds 60 bytes, and 600 holds 120.')
print('  15 kS/s is there for 1800 baud and to keep non-standard 1251..2499 off 125 bytes.')
print('')
print('  Sub-1200 NON-standard rates are the one case no reasonable ladder rescues: 313 baud')
print('  needs 2504 S/s, clears the 2500 rung by four, and takes 5000 at 16 samples/bit. It')
print('  is also not a case that occurs -- 313 is 4 % off 300, and 2 % would have SNAPPED.')
print('')
print('  All figures are 8N1 on ' .. sdec.n .. ' samples. A parity bit makes a frame 11 bits')
print('  rather than 10, so multiply by 10/11: ' ..
      string.format('%d and %d.', math.floor(sworst * 10 / 11), math.floor(aworst * 10 / 11)))
print('')
end

-- ============================================================================
if want('decode') then
-- ============================================================================
-- Does the REAL decoder work at the new samples/bit ratios? Every candidate above lands
-- between 8.00 and 8.33 samples/bit, which is LESS oversampling than any rate the app
-- currently picks for these bauds -- so this is the half of the question that could make
-- the whole idea worthless, and it does not need the instrument to answer.
--
-- Deliberately not a clean waveform: finite edges, noise and a swept sampling PHASE. Phase
-- is the one that matters here. At 8 samples/bit a bit cell is 8 samples wide and the
-- decoder picks a mid-bit point; the fewer samples per bit, the more of the cell a phase
-- error eats. If low oversampling is fragile, it shows up as a phase that fails.
print('')
print('DOES THE DECODER SURVIVE THE NEW RATIOS?  (real sig_levels/sig_edges/decode_from)')
print('')

local PHASES = {0.0, 0.17, 0.37, 0.5, 0.63, 0.83}
local payload = {}
for i = 1, 40 do payload[i] = math.fmod(i * 37 + 11, 256) end
local np = table.getn(payload)

local function decode_at(baud, fs, phase, noise)
  local rd, _, _, nsmp = GEN({bytes = payload, baud = baud, fs = fs, lo = 0, hi = 3.3,
                              rise = 1.5, noise = noise, phase = phase,
                              lead = 20, tail = 20, gap = 2})
  sdec.acq_fs, sdec.fs = fs, fs
  local nf, nbad, gotbaud = 0, 0, nil
  local ok = pcall(function()
    if not sdec.sig_levels(rd, nsmp) then return end
    sdec.sig_edges(rd, nsmp)
    sdec.sig_idle(rd, nsmp)
    sdec.decode_from(rd, nsmp)
    if sdec.res ~= nil then nf, nbad = sdec.res.nf, sdec.res.nbad end
    gotbaud = sdec.baud
  end)
  if not ok then return nil end
  -- Every byte back, in order, no framing errors, and the RATE identified correctly.
  local exact = (nf >= np) and (nbad == 0) and gotbaud ~= nil and
                math.abs(gotbaud / baud - 1) < 0.02
  if exact and sdec.res ~= nil then
    for i = 1, np do
      if sdec.res.vals[i] ~= payload[i] then exact = false; break end
    end
  end
  return exact, nf, nbad, gotbaud
end

-- Every (baud, candidate) pair the ladder would actually select, plus the rate it replaces, so a
-- failure can be blamed on the ratio rather than on the vector.
--
-- Driven from sdec.stdbaud, NOT from a hand-written list of common rates. The spec section made
-- exactly that mistake and it hid 300 baud's 60-byte window; making it twice in one file would be
-- worse than making it once. It also matters more here than there: the low rungs are the ones
-- carrying bauds this sweep had never generated a vector for at all.
local CASES = {}
local ext = {}
for _, r in ipairs(sdec.rates) do ext[table.getn(ext) + 1] = r end
for _, r in ipairs(CAND) do ext[table.getn(ext) + 1] = r end
for _, baud in ipairs(sdec.stdbaud) do
  local need = baud * sdec.fs_sabit
  local now = lowest_at_or_above(sdec.rates, need) or 1000000
  local new = lowest_at_or_above(ext, need) or 1000000
  -- A rate under minsabit is REFUSED by design (460800 and 921600 at 1 MS/s), so decoding it is
  -- not the question being asked here.
  if new < now and new / baud >= sdec.minsabit and now / baud >= sdec.minsabit then
    CASES[table.getn(CASES) + 1] = {baud = baud, fs = new,  what = 'candidate'}
    CASES[table.getn(CASES) + 1] = {baud = baud, fs = now,  what = 'today'}
  end
end

print('  baud        fs  sa/bit  noise  phases passing (of ' .. table.getn(PHASES) .. ')  what')
print('  ' .. string.rep('-', 74))
local allgood = true
for _, c in ipairs(CASES) do
  for _, noise in ipairs({0, 0.15}) do
    local pass, worst = 0, nil
    for _, ph in ipairs(PHASES) do
      local exact, nf, nbad = decode_at(c.baud, c.fs, ph, noise)
      if exact then pass = pass + 1
      elseif worst == nil then
        worst = string.format('phase %.2f: %s/%d bytes %s bad', ph, tostring(nf), np,
                              tostring(nbad))
      end
    end
    local flag = ''
    if pass < table.getn(PHASES) then flag = '  <-- ' .. tostring(worst); allgood = false end
    print(string.format('  %6d  %8d  %6.2f  %5.2f  %d%s',
          c.baud, c.fs, c.fs / c.baud, noise, pass, flag))
  end
end
print('')
if allgood then
  print('  ALL PASS at every phase, clean and with 0.15 V noise -- the ratios these')
  print('  candidates imply (8.00 to 8.33 samples/bit) are not the limiting factor.')
  print('  What is unproven is only whether the INSTRUMENT can produce the rates:')
  print('  see BRINGUP 4b.11.')
else
  print('  SOMETHING FAILED -- the ratio, not the instrument, is the problem. Do not')
  print('  extend sdec.rates until this is understood.')
end
print('')
end

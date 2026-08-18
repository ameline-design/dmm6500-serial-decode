-- test_patterns.lua -- the pathological BYTE PATTERNS, decoded offline, at both ends of the
-- samples-per-bit range.
--
-- WHY THIS FILE EXISTS SEPARATELY FROM test_serial.lua. test_serial already decodes six of
-- each hard byte (its 'hard' table) and 300 of 0x55 and 0x00 through the streaming seams. What
-- it does not do is the thing the bench vectors do: run each pattern at FULL BLOCK LENGTH, in
-- BOTH the pinned and the auto format, at BOTH the top and the bottom of the sample-rate range.
-- Those three axes are what out/vectors/v93.bin and v94.bin will exercise on hardware, and
-- every one of them is testable here for free. A bench finding that could have been found
-- offline is a wasted bench session.
--
-- Run from the repo root:  lua tools/test_patterns.lua
--
-- THE TWO CLAIMS, one per pattern, and they are deliberately different in kind:
--
--   PINNED   with the format nailed down by hand -- baud, data bits, parity, stop bits and
--            polarity all forced -- there is no search left to get wrong, so the only honest
--            outcome is EVERY BYTE EXACTLY AS SENT and zero framing errors. Anything less is a
--            framing bug, and this is the assertion that says so without hedging.
--
--   AUTO     with nothing forced, the app may legitimately land on a DIFFERENT FORMAT, because
--            several of these patterns genuinely fit more than one. What it may not do is be
--            silently wrong. So the pass condition is: the bytes are exactly right, OR the
--            bytes are the same wire bits read under the format it chose AND it said out loud
--            that a rival format also fits.
--
-- THE 7E1 EXEMPTION, WHICH IS NOT A HEDGE. All four of 0x00, 0xFF, 0x55 and 0xAA have bit 7
-- equal to the EVEN PARITY of their low seven bits; the walking-one and walking-zero bytes have
-- bit 7 equal to the ODD parity of theirs. An 8N1 frame and a 7E1 frame occupy the SAME ten bit
-- cells and differ only in whether bit 7 is data or a parity bit -- so for these payloads the
-- two formats are not merely confusable, they are indistinguishable on the wire, in every
-- single frame. Calling such a stream 7E1 is a correct reading of it. The assertion below
-- therefore VERIFIES the rival format really does fit (fits_7par) before allowing it, so the
-- exemption cannot launder a genuinely wrong answer, and demands a note either way.
--
-- BOTH 10 AND 4 SAMPLES/BIT, because tolerance follows samples-per-bit and nothing else. 4 is
-- sdec.minsabit, the declared floor -- sig_quality() warns at exactly 4.0 -- so it is the
-- marginal case by construction, and a pattern whose edges are sparse (0x00, 0xFF) has the
-- least evidence to fit a bit time to precisely where each sample costs the most.

dofile('tools/mock_display.lua')     -- hostile display + file mock, object census
dofile('tools/gen_serial.lua')       -- waveform generator, dmm/buffer mock, decode core
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.proto, sdec.ui_mode = 'uart', 'text'
end

-- ---------------------------------------------------------------------------
-- test_serial.lua's driving idiom, unchanged: GEN the waveform, run the real
-- signal chain over it, then decode_from. No acquire(), so no digitizer mock is
-- involved and the only thing under test is the decode.
-- ---------------------------------------------------------------------------
local function analyse(rd, nsmp, fs)
  sdec.acq_fs, sdec.fs = fs, fs
  local ok, why = sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  return ok, why
end

local function run(opts)
  local rd, ts, nc, nsmp = GEN(opts)
  local fs = opts.fs or 1000000
  sdec.clear_result()
  analyse(rd, nsmp, fs)
  local ok, why = sdec.decode_from(rd, nsmp)
  return sdec.res, ok, why
end

-- ---------------------------------------------------------------------------
-- Bit arithmetic, spelled out because Lua 5.0.2 has no bitwise operators and
-- the parity argument above is the whole justification for the AUTO exemption.
-- ---------------------------------------------------------------------------
local function popc(v)
  local n, t = 0, math.mod(v, 256)
  while t > 0 do
    n = n + math.mod(t, 2)
    t = math.floor(t / 2)
  end
  return n
end

-- v as the low `nbits` bits, which is what a narrower frame reads off the same wire.
local function proj(v, nbits)
  local m, i = 1, 0
  for i = 1, nbits do m = m * 2 end
  return math.mod(v, m)
end

local function bit7(v) return math.floor(math.mod(v, 256) / 128) end

-- Does EVERY byte of this payload have bit 7 equal to the parity `par` demands over its low
-- seven bits? If so a 7-data-bit frame with that parity is an exact alternative reading of the
-- wire, and choosing it is correct rather than wrong. This is the gate on the exemption.
local function fits_7par(sent, n, par)
  local i
  for i = 1, n do
    local want = math.mod(popc(proj(sent[i], 7)), 2)     -- even parity of the low 7 bits
    if par == sdec.PAR_ODD then want = 1 - want end
    if bit7(sent[i]) ~= want then return false end
  end
  return true
end

local function bhex(t, n, cap)
  local h, i = {}, nil
  local m = n
  if cap ~= nil and m > cap then m = cap end
  for i = 1, m do
    if t[i] == nil then h[i] = '--' else h[i] = string.format('%02X', t[i]) end
  end
  local s = table.concat(h, ' ')
  if m < n then s = s .. string.format(' ...(%d more)', n - m) end
  return s
end

-- The FIRST disagreement, not a count. On a walking pattern the position of the bad byte says
-- WHICH bit position was mis-sampled, and a count of bad bytes cannot say that.
local function firstdiff(got, ngot, want, nwant)
  local i
  local n = nwant
  if ngot < n then n = ngot end
  for i = 1, n do
    if got[i] ~= want[i] then return i end
  end
  if ngot ~= nwant then return n + 1 end
  return nil
end

-- ---------------------------------------------------------------------------
-- The patterns. Byte counts match out/vectors/v93.bin and v94.bin exactly, so
-- this file is the offline twin of those two vectors rather than a rough
-- analogue of them.
-- ---------------------------------------------------------------------------
local function rep(v, k)
  local t, i = {}, 0
  for i = 1, k do t[i] = v end
  return t
end

-- 0x01, 0x02, 0x04 ... 0x80 (dir = 1) or its complement 0xFE, 0xFD ... 0x7F (dir = 0),
-- repeated to `nrep` passes. One 1 (or one 0) per bit position, so a decoder sampling one bit
-- at the wrong phase gets exactly one byte of each pass wrong and the index names the bit.
local function walk(dir, nrep)
  local t, n, r, b = {}, 0, 0, 0
  for r = 1, nrep do
    for b = 0, 7 do
      local v, k = 1, 0
      for k = 1, b do v = v * 2 end
      n = n + 1
      if dir == 1 then t[n] = v else t[n] = 255 - v end
    end
  end
  return t, n
end

-- 1024 uniform bytes 0-255 from the suite's PRNG at seed 20260818 -- byte for byte the payload
-- of out/vectors/v93.bin, and of out/vectors/v91.bin in its first 256.
local function rand_bytes(n, seed)
  GEN_RESEED(seed)
  local by, i = {}, 0
  for i = 1, n do
    by[i] = math.floor(GEN_RAND() * 256)
    if by[i] > 255 then by[i] = 255 end
  end
  return by, n
end

local RANDN = 1024
local randp = rand_bytes(RANDN, 20260818)
local walk1, walk1n = walk(1, 16)
local walk0, walk0n = walk(0, 16)

local PAT = {
  {name = 'all 0x00 x128',  bytes = rep(0x00, 128), n = 128,
   why = 'a nine-bit LOW run per frame -- one rising edge, at the stop bit, and nothing else'},
  {name = 'all 0xFF x128',  bytes = rep(0xFF, 128), n = 128,
   why = 'a nine-bit HIGH run per frame -- one narrow start-bit notch in an idle-looking line'},
  {name = 'all 0x55 x128',  bytes = rep(0x55, 128), n = 128,
   why = 'an edge every bit time -- the maximum edge density a UART can emit'},
  {name = 'all 0xAA x128',  bytes = rep(0xAA, 128), n = 128,
   why = 'the same density in the opposite phase -- LSB 1, so the start bit does NOT merge'},
  {name = 'walking-one x16',  bytes = walk1, n = walk1n,
   why = 'one 1 per bit position -- a mis-sampled bit shows as ONE bad byte, and says which bit'},
  {name = 'walking-zero x16', bytes = walk0, n = walk0n,
   why = 'one 0 per bit position -- the complement, which fails on the opposite phase error'},
  {name = '1024 random bytes (seed 20260818)', bytes = randp, n = RANDN,
   why = 'every byte value ~16 times -- catches any decode that depends on a byte VALUE'},
}

-- 9600 baud throughout, and the SAMPLE RATE is what moves: 96000 is 10.0 samples/bit,
-- 38400 is exactly 4.0, which is sdec.minsabit. Holding the baud fixed and moving fs is what
-- makes the two runs a test of TOLERANCE rather than of two unrelated configurations.
local BAUD = 9600
local RATES = {{sabit = 10, fs = BAUD * 10}, {sabit = 4, fs = BAUD * 4}}

-- gap 0 / lead 10 / tail 10 / loop, matching v93 and v94: back-to-back bytes are what a device
-- dumping a buffer sends, and they leave sig_idle one stop bit per frame of idle-level evidence.
local function opts_for(p, fs)
  return {bytes = p.bytes, baud = BAUD, fs = fs, gap = 0, lead = 10, tail = 10, loop = true}
end

-- ============================================================================
print('\nA  the ambiguity is real -- verified before it is ever excused')
-- ============================================================================
-- If these four checks fail, the AUTO exemption below is unjustified and the whole file is
-- wrong. They are cheap, they are pure arithmetic, and they turn the long comment at the top
-- into something that is checked rather than believed.
do
  check('0x00/0xFF/0x55/0xAA are ALL exact 7E1 frames -- bit 7 is the even parity of bits 0-6',
        fits_7par({0x00, 0xFF, 0x55, 0xAA}, 4, sdec.PAR_EVEN))
  check('...and none of them is a valid 7O1 frame, so the ambiguity has exactly one rival',
        not fits_7par({0x00, 0xFF, 0x55, 0xAA}, 4, sdec.PAR_ODD))
  check('the walking-one/walking-zero bytes are ALL exact 7O1 frames',
        fits_7par(walk1, walk1n, sdec.PAR_ODD) and fits_7par(walk0, walk0n, sdec.PAR_ODD))
  -- The random payload is the control: if it were also parity-consistent the AUTO checks below
  -- would all pass vacuously, and the suite would prove nothing about 8N1 detection.
  check('1024 random bytes fit NEITHER 7E1 nor 7O1, so 8N1 is the only reading of them',
        not fits_7par(randp, RANDN, sdec.PAR_EVEN)
        and not fits_7par(randp, RANDN, sdec.PAR_ODD))
  -- Ties this file's PRNG payload to the one that is on the generator. The prefix is quoted
  -- from out/vectors/manifest.tsv, so a drift in GEN_RAND breaks this and not a bench run.
  check('the random payload is byte-for-byte v93.bin\'s -- same seed, same first eight bytes',
        bhex(randp, 8) == '91 2F E9 D9 08 39 68 79', bhex(randp, 8))
  check('and it is 1024 bytes, the length the vector is', RANDN == 1024, tostring(RANDN))
end

-- ============================================================================
print('\nB  format PINNED to 8N1 -- no search left, so every byte must be exact')
-- ============================================================================
local pi, ri
for ri = 1, table.getn(RATES) do
  local R = RATES[ri]
  for pi = 1, table.getn(PAT) do
    local p = PAT[pi]
    clearforce()
    -- ALL FIVE forced, which is what 'pinned' has to mean: a forced format with a searched
    -- BAUD RATE still has a search in it, and a rate error would then show up as byte errors
    -- and be blamed on framing. force_invert = false pins the polarity too, so an inverted
    -- reading of 0x00 (which looks like idle inverted) cannot be chosen.
    sdec.force_baud = BAUD
    sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
    sdec.force_invert = false

    local r, ok, why = run(opts_for(p, R.fs))
    local nf, nbad = -1, -1
    if r ~= nil then nf, nbad = r.nf, r.nbad end
    local bad = nil
    if r ~= nil then bad = firstdiff(r.vals, r.nf, p.bytes, p.n) end
    local exact = (r ~= nil and nf == p.n and nbad == 0 and bad == nil)

    local detail
    if r == nil then
      detail = string.format('REFUSED: %s', tostring(why))
    elseif bad ~= nil then
      -- The exact bytes, both ways, at the point they first diverge. This is the line that
      -- makes a failure actionable instead of a mystery.
      local lo = bad - 3
      if lo < 1 then lo = 1 end
      local sw, sg, k = {}, {}, 0
      for k = lo, lo + 7 do sw[k - lo + 1] = p.bytes[k]; sg[k - lo + 1] = r.vals[k] end
      detail = string.format('%d/%d bytes, %d err; first diff at byte %d: sent %s / got %s',
                             nf, p.n, nbad, bad, bhex(sw, 8), bhex(sg, 8))
    else
      detail = string.format('%d/%d bytes, %d err, %s', nf, p.n, nbad, sdec.fmt_text())
    end
    check(string.format('PINNED 8N1 at %d samples/bit, %s -- every byte exactly as sent',
                        R.sabit, p.name), exact, detail)
  end
end
clearforce()

-- ============================================================================
print('\nC  AUTO format -- right, or honest about the rival. Never silently wrong.')
-- ============================================================================
-- Returns ok, verdict-string. The verdict is printed either way, so a PASS on the 7E1 branch
-- still shows WHICH format was chosen and what it said -- a pass that hides that is a pass
-- nobody can audit.
local function auto_verdict(p, r, ok, why)
  if r == nil then
    -- A REFUSAL IS NOT A PASS HERE. These are clean, full-amplitude, correctly framed signals;
    -- refusing one is a failure to decode traffic the app claims to handle. (A refusal WITH a
    -- reason is still better than a wrong answer, which is why the reason is printed.)
    return false, string.format('REFUSED: %s', tostring(why))
  end
  local fmt = sdec.fmt_text()
  local note = sdec.fmt_note
  local nb = r.nbits or 8
  local base = string.format('%s, %d/%d bytes, %d err', fmt, r.nf, p.n, r.nbad)

  -- Branch 1: it read the payload as 8 data bits with no parity, i.e. exactly what was sent.
  -- Then there is no ambiguity to declare and the bytes must simply be right.
  if nb == 8 and r.par == sdec.PAR_NONE then
    local bad = firstdiff(r.vals, r.nf, p.bytes, p.n)
    if r.nf == p.n and bad == nil then return true, base end
    if bad == nil then return false, base .. ' -- WRONG COUNT' end
    return false, string.format('%s -- WRONG at byte %d: sent %02X got %s', base, bad,
                                p.bytes[bad], tostring(r.vals[bad]))
  end

  -- Branch 2: it read the payload with a narrower frame plus parity. Legitimate ONLY if the
  -- rival format genuinely fits every frame, the bytes are that format's reading of the same
  -- wire bits, and it SAID a rival exists. All three, or it is a silent misread.
  if nb < 8 and r.par ~= sdec.PAR_NONE then
    if not fits_7par(p.bytes, p.n, r.par) then
      return false, base .. ' -- chose a parity format the payload does NOT fit'
    end
    local want, i = {}, 0
    for i = 1, p.n do want[i] = proj(p.bytes[i], nb) end
    local bad = firstdiff(r.vals, r.nf, want, p.n)
    if bad ~= nil or r.nf ~= p.n then
      return false, string.format('%s -- not even the %s reading of the wire (byte %s)',
                                  base, fmt, tostring(bad))
    end
    if note == nil then
      return false, base .. ' -- SILENT: a rival format fits and nothing was said'
    end
    -- The note has to name the rival, not merely exist. 'a note was set' would be satisfied by
    -- an unrelated warning about the baseline.
    if not has(note, '8N1') then
      return false, base .. ' -- note does not name the 8N1 rival: ' .. note
    end
    return true, base .. ' + note: ' .. note
  end

  -- Anything else -- 8E1, 8O1, a 5- or 6-bit frame without parity -- is only acceptable if the
  -- bytes came out right anyway.
  local bad = firstdiff(r.vals, r.nf, p.bytes, p.n)
  if r.nf == p.n and bad == nil then return true, base end
  return false, string.format('%s -- unexpected format and the bytes are wrong (byte %s)',
                              base, tostring(bad))
end

for ri = 1, table.getn(RATES) do
  local R = RATES[ri]
  for pi = 1, table.getn(PAT) do
    local p = PAT[pi]
    clearforce()
    local r, ok, why = run(opts_for(p, R.fs))
    local good, verdict = auto_verdict(p, r, ok, why)
    check(string.format('AUTO at %d samples/bit, %s -- correct, or a declared ambiguity',
                        R.sabit, p.name), good, verdict)

    -- THE RATE IS A SEPARATE CLAIM FROM THE FORMAT, and a separate failure. A pattern that
    -- fools the bit-time fit -- 0xFF offers one narrow pulse per frame to fit it to -- would
    -- otherwise be reported as a byte error, which points at the framer rather than the timer.
    local bok = (sdec.baud ~= nil and math.abs(sdec.baud / BAUD - 1) <= 0.02)
    check(string.format('AUTO at %d samples/bit, %s -- the rate is measured as 9600 baud',
                        R.sabit, p.name), bok,
          string.format('%s (snapped=%s)', sdec.baud_text(), tostring(sdec.snapped)))
  end
end
clearforce()

-- ============================================================================
print('\nD  the pinned format is what makes v94 usable -- 8N1 and 7E1 side by side')
-- ============================================================================
-- v94's manifest row says 7E1 and its .txt payload says 0x00/0xFF/0x55/0xAA, and at the bench
-- that reads like a contradiction. It is not: it is the same capture under two formats. This
-- block is that pair, so the bench has an offline statement of both numbers rather than a
-- surprise.
do
  local blocks, nblk, i, k = {}, 0, 0, 0
  local pats = {0x00, 0xFF, 0x55, 0xAA}
  for i = 1, 4 do
    for k = 1, 128 do nblk = nblk + 1; blocks[nblk] = pats[i] end
  end
  check('the v94 payload is 512 bytes, 128 per block', nblk == 512, tostring(nblk))

  clearforce()
  local r = run(opts_for({bytes = blocks, n = nblk}, BAUD * 10))
  local autofmt = sdec.fmt_text()
  local autonote = sdec.fmt_note
  check('AUTO calls the v94 payload 7E1 -- the reading the manifest publishes as exp_fmt',
        autofmt == '7E1', autofmt)
  check('...and says so, naming 8N1 as the rival rather than leaving the operator to guess',
        has(autonote, '8N1') and has(autonote, '7E1'), tostring(autonote))
  local sevens = (r ~= nil and r.nf == nblk)
  if r ~= nil then
    for i = 1, r.nf do
      if r.vals[i] ~= proj(blocks[i], 7) then sevens = false end
    end
  end
  check('under 7E1 the bytes are the low seven bits -- 00, 7F, 55, 2A, which is exp_hex',
        sevens, r and bhex(r.vals, 4) .. ' / ' .. bhex(r.vals, 4, 1) or 'nil')

  -- The BLOCK BOUNDARY is the part 64-per-block cannot reach: 128 bytes is comparable to the
  -- 192-byte capture window, so a window can sit entirely inside one block and the decoder gets
  -- no mix of edge densities to fit its timing to. The 0xFF -> 0x00 step is the largest
  -- possible change in edge density; check the bytes either side of it survive.
  clearforce()
  sdec.force_baud = BAUD
  sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
  sdec.force_invert = false
  local r2 = run(opts_for({bytes = blocks, n = nblk}, BAUD * 10))
  local seam = (r2 ~= nil and r2.nf == nblk and firstdiff(r2.vals, r2.nf, blocks, nblk) == nil)
  local seamtxt = 'nil'
  if r2 ~= nil and r2.nf >= 260 then
    local w, j = {}, 0
    for j = 253, 260 do w[j - 252] = r2.vals[j] end
    seamtxt = 'bytes 253-260 = ' .. bhex(w, 8)
  end
  check('PINNED 8N1 crosses every 128-byte block seam, including 0xFF -> 0x00', seam, seamtxt)
  clearforce()
end

-- ============================================================================
print('\nE  the same patterns INVERTED -- an RS-232 line is the other half of the range')
-- ============================================================================
-- 0x00 inverted is a nine-bit HIGH run and 0xFF inverted a nine-bit LOW one, so inverting
-- SWAPS which pattern starves which detector. Without this block the sparse-edge case is only
-- ever tested in one polarity, and sig_idle's longest-run prior is polarity-sensitive by
-- construction. Pinned only: the auto claim is already covered above and polarity detection has
-- its own coverage in test_serial.lua.
do
  local inv = {{name = 'all 0x00 x128', bytes = rep(0x00, 128), n = 128},
               {name = 'all 0xFF x128', bytes = rep(0xFF, 128), n = 128},
               {name = 'walking-one x16', bytes = walk1, n = walk1n}}
  for ri = 1, table.getn(RATES) do
    local R = RATES[ri]
    for pi = 1, table.getn(inv) do
      local p = inv[pi]
      clearforce()
      sdec.force_baud = BAUD
      sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
      sdec.force_invert = true
      local o = opts_for(p, R.fs)
      o.invert = true
      o.lo, o.hi = -6, 6            -- and at RS-232 levels, since that is where inversion lives
      local r, ok, why = run(o)
      local bad = nil
      if r ~= nil then bad = firstdiff(r.vals, r.nf, p.bytes, p.n) end
      local exact = (r ~= nil and r.nf == p.n and r.nbad == 0 and bad == nil)
      local detail
      if r == nil then detail = 'REFUSED: ' .. tostring(why)
      else detail = string.format('%d/%d bytes, %d err, %s, first diff %s', r.nf, p.n, r.nbad,
                                  sdec.family or '?', tostring(bad)) end
      check(string.format('PINNED 8N1 INVERTED at %d samples/bit, %s -- every byte exact',
                          R.sabit, p.name), exact, detail)
    end
  end
  clearforce()
end

-- ============================================================================
print('\nF  the same patterns on a DEGRADED wire -- noise, and slew eating the bit cell')
-- ============================================================================
-- Everything above runs on a clean 3.3 V line with 1.5-sample edges. A pattern's real hazard is
-- that it removes the decoder's margin BEFORE the wire does, so the two compound: 0xFF offers
-- exactly one narrow pulse per frame to fit a bit time to, and noise on that pulse has nothing
-- to be averaged against.
--
-- WHAT IS ASSERTED HERE IS DELIBERATELY WEAKER THAN B AND C, and the weakening is the point. On
-- a wire this bad, bytes are allowed to be lost -- what is NOT allowed is a confident wrong
-- answer. So the pass condition is honesty: right, or refused, or the panel says the bytes may
-- be wrong. Nothing here may quietly hand over 128 plausible bytes.
local function honest(p, r, why)
  if r == nil then return true, 'REFUSED: ' .. tostring(why) end
  local bad = firstdiff(r.vals, r.nf, p.bytes, p.n)
  if r.nf == p.n and bad == nil then
    return true, string.format('exact, %d/%d, %d err', r.nf, p.n, r.nbad)
  end
  -- A CORRECTNESS warning, not just any warning. At 4 samples/bit sig_quality() always warns
  -- about the sample rate, so 'some note exists' would be satisfied by every run at this rate
  -- and would assert nothing. The note has to be about the BYTES.
  local t, m, i = sdec.ui_notes()
  for i = 1, m do
    if has(t[i], 'may be WRONG') or has(t[i], 'baseline') then
      return true, string.format('wrong at byte %s BUT declared: %s', tostring(bad), t[i])
    end
  end
  return false, string.format('SILENT: %d/%d bytes, %d err, first diff at %s -- sent %02X ' ..
                              'got %s, and no note says the bytes may be wrong',
                              r.nf, p.n, r.nbad, tostring(bad), p.bytes[bad],
                              tostring(r.vals[bad]))
end

do
  local four = {PAT[1], PAT[2], PAT[3], PAT[4]}
  -- 0.3 V of noise on a 3.3 V swing: 9 % of the swing, so a fifth of the way to the threshold.
  -- Enough to add spurious edges to a slow transition without ever crossing the midpoint on its
  -- own, which is the regime where a rate detector is misled rather than blinded.
  local WIRES = {
    {tag = '0.3 V noise', o = {noise = 0.3}},
    -- rise = 2.0 samples in a 4-sample cell: the edge occupies HALF the bit time. Slew-limited
    -- wiring at the top of the rate range looks exactly like this, and 0x55 -- an edge every
    -- cell -- is the pattern it attacks, since the line never settles at either level.
    {tag = 'slew = half a bit cell', o = {rise = 2.0}},
    -- rise = 3.5 of 4 is past slew-limited and into TRIANGLE: the stop bit is a one-sample spike
    -- that never dwells at the mark level, so the group-mean level estimator measures a 0.45 V
    -- swing on a 0.0-3.3 V waveform and the threshold lands near the bottom. This is no longer a
    -- UART signal, and the only defensible requirement is that the app not pretend otherwise.
    {tag = 'slew = 7/8 of a bit cell (a triangle, not a UART)', o = {rise = 3.5}},
  }
  local wi
  for wi = 1, table.getn(WIRES) do
    local W = WIRES[wi]
    for pi = 1, table.getn(four) do
      local p = four[pi]
      -- PINNED, so the format and rate are given and only the WIRE is in question. An auto run
      -- here would conflate a misfit format with a mismeasured edge.
      clearforce()
      sdec.force_baud = BAUD
      sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
      sdec.force_invert = false
      local o = opts_for(p, BAUD * 4)
      local k, v
      for k, v in pairs(W.o) do o[k] = v end
      GEN_RESEED(999)                                  -- noise is deterministic per run
      local r, ok, why = run(o)
      local good, verdict = honest(p, r, why)
      check(string.format('PINNED, 4 samples/bit, %s, %s -- right, or it says the bytes may be wrong',
                          W.tag, p.name), good, verdict)
    end
  end

  -- AND THE AUTO PATH ON THE SAME NOISY WIRE, because a refusal is the outcome worth pinning: a
  -- rate detector fed one narrow pulse per frame plus noise SHOULD decline rather than guess.
  for pi = 1, table.getn(four) do
    local p = four[pi]
    clearforce()
    GEN_RESEED(999)
    local o = opts_for(p, BAUD * 4)
    o.noise = 0.3
    local r, ok, why = run(o)
    local good, verdict = honest(p, r, why)
    check(string.format('AUTO, 4 samples/bit, 0.3 V noise, %s -- right, or an honest refusal',
                        p.name), good, verdict)
  end
  clearforce()
end

-- ============================================================================
print(string.format('\n%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

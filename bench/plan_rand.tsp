-- plan_rand.tsp -- MT19937, MOVED HERE FROM tools/mt19937.lua so the instrument can draw a plan.
--
-- ONE IMPLEMENTATION, TWO HOSTS. tools/mt19937.lua is now a three-line shim that loads this file, so
-- tools/test_soakrand.py goes on checking THIS code against CPython's random module word for word --
-- which is what makes an on-instrument plan draw trustworthy. Copying it would have made that proof
-- apply to the copy nobody runs.
--
-- WHY IT WAS ALREADY INSTRUMENT-READY. It was written arithmetic-only on purpose: no bitwise
-- operators, no '%', no '#'. Those are SYNTAX errors in 5.0.2 rather than missing functions, so one
-- occurrence anywhere stops the whole archive loading, taken branch or not.
--
-- WRAPPED IN do ... end, which is the only change of substance. Every module in this archive is
-- concatenated into ONE chunk and Lua allows 200 active locals per function; this file is the only
-- one with file-scope locals, and the block frees its twenty-two at the end instead of holding them
-- for every module that loads after it.
--
-- EXACTNESS, which is the only thing that makes arithmetic-only safe:
--   * imod(a, b) is exact whenever a/b is exact or its true quotient is under 2^53. Every modulus
--     here is a POWER OF TWO except in below(), where the quotient is bounded by 2^32.
--   * mul32 splits the multiplier into 16-bit halves so no product exceeds 2^48. A direct
--     1812433253 * (2^32-1) is 7.8e18 -- 860x over 2^53 -- and would silently lose low bits, which
--     is exactly the state the generator carries forward.
--   * bxor and band go through a 4-bit table, so they never form an intermediate above 2^32.

bplan = bplan or {}
bplan.mt = {}

do

local M = bplan.mt


-- Array length WITHOUT '#' AND WITHOUT table.getn, because neither spelling works in both places
-- this file has to run. 5.0.2 has no '#' at all -- it is a SYNTAX error, so one occurrence anywhere
-- stops the whole module loading on the instrument, taken branch or not -- and the host Lua has no
-- table.getn. Counting is the only form both accept.
local function alen(t)
  local n = 0
  while t[n + 1] ~= nil do n = n + 1 end
  return n
end

local N, MM = 624, 397
local MATRIX_A = 2567483615      -- 0x9908b0df
local UPPER    = 2147483648      -- 0x80000000
local LOWER    = 2147483647      -- 0x7fffffff
local TEMPER_B = 2636928640      -- 0x9d2c5680
local TEMPER_C = 4022730752      -- 0xefc60000
local TWO32    = 4294967296

M.TWO32 = TWO32

local floor = math.floor

local function imod(a, b) return a - floor(a / b) * b end

-- 4-bit xor and and, built once. ONE TABLE EACH, FLAT, indexed a*16+b.
--
-- FLAT AND NOT NESTED, which costs nothing and saves a lookup per nibble: X4[a][b] is two table
-- reads, X4[a * 16 + b] is one, and 256 entries in the array part is the same ~4 kB either way.
-- MEASURED under both Luas on 200 000 full-width xors: 0.177 s nested, 0.147 s flat on 5.0.2.
--
-- WHY NOT BYTE-WIDE. A byte table halves the lookups again -- 0.078 s, 2.3x -- but xor and and need
-- BOTH operands, so it is 256x256 and not 256: 1025 kB on 5.0.2, against a Lua heap this app has
-- about 5.4 MB of. Not worth a fifth of the heap. The two places a byte table WOULD be 1 kB are the
-- constant operands (MATRIX_A, TEMPER_B, TEMPER_C), as four per-position rows of 256; that is a real
-- option if the twist ever has to get faster, and it is not needed yet.
--
-- NO `or` TABLE. The one place the reference algorithm ORs is (hi & UPPER) | (lo & LOWER), and those
-- two masks are disjoint, so it is written as + below -- and then as plain arithmetic, which is why
-- neither table is consulted in the twist at all.
local X4, A4 = {}, {}
do
  local a, b, i
  for a = 0, 15 do
    for b = 0, 15 do
      local x, n, pa, pb, p = 0, 0, a, b, 1
      for i = 1, 4 do
        local ba, bb = imod(pa, 2), imod(pb, 2)
        if ba ~= bb then x = x + p end
        if ba == 1 and bb == 1 then n = n + p end
        pa, pb, p = (pa - ba) / 2, (pb - bb) / 2, p * 2
      end
      X4[a * 16 + b], A4[a * 16 + b] = x, n
    end
  end
end

-- STOPPING WHEN ONE OPERAND RUNS OUT, which is not a micro-optimisation here: it is most of the cost
-- of drawing a plan. Every nibble above the top set bit of the smaller operand is a lookup whose
-- answer is the other operand's nibble unchanged, and the hot callers pass a SMALL second operand --
-- init_by_array and init_genrand both do bxor(x, rsh(x, 30)), where the second is 0..3, so eight
-- lookups become one. Seeding is 1247 of those per draw and a plan is thousands of draws.
--
-- EXACT, not approximate: xor and and with zero are identity and zero respectively, so the tail is
-- carried verbatim rather than skipped. tools/test_soakrand.py checks both against the host Lua's
-- native operators over 4000 random pairs, and the whole sequence against CPython, so this is
-- guarded by test and not by argument.
--
-- MEASURED TOGETHER WITH THE UPPER/LOWER SUBSTITUTION in u32 below, on a 1512-row plan under the host
-- Lua: 19.3 s to 8.7 s. The two are reported as one figure because they were measured as one change.
local function bxor(a, b)
  local r, p = 0, 1
  while true do
    if b == 0 then return r + a * p end
    if a == 0 then return r + b * p end
    local al = imod(a, 16)
    local bl = imod(b, 16)
    r = r + X4[al * 16 + bl] * p
    a = (a - al) / 16; b = (b - bl) / 16; p = p * 16
  end
end

local function band(a, b)
  local r, p = 0, 1
  while true do
    -- AND with zero is zero, so a run-out ends the whole result rather than carrying a tail.
    if a == 0 or b == 0 then return r end
    local al = imod(a, 16)
    local bl = imod(b, 16)
    r = r + A4[al * 16 + bl] * p
    a = (a - al) / 16; b = (b - bl) / 16; p = p * 16
  end
end

-- a * b mod 2^32 with both under 2^32. Splitting b keeps every product under 2^48.
local function mul32(a, b)
  local bh = floor(b / 65536)
  local bl = b - bh * 65536
  return imod(a * bl + imod(a * bh, 65536) * 65536, TWO32)
end

local function rsh(a, k) return floor(a / (2 ^ k)) end
local function lsh(a, k) return imod(a * (2 ^ k), TWO32) end

M.bxor, M.band, M.mul32, M.imod = bxor, band, mul32, imod

local MT = {}
MT.__index = MT

-- Knuth's multiplicative fill. The ONLY seed-dependent step is mt[0]; everything after is the same
-- recurrence at every seed, which is why agreement at one seed settles the routine.
local function init_genrand(s)
  local mt = {}
  mt[0] = imod(s, TWO32)
  local i
  for i = 1, N - 1 do
    mt[i] = imod(mul32(1812433253, bxor(mt[i - 1], rsh(mt[i - 1], 30))) + i, TWO32)
  end
  return mt, N
end

-- Seeding from a KEY ARRAY rather than one integer, because a soak decision is addressed by several
-- small numbers -- iteration, purpose, index -- and concatenating them into one seed would make
-- neighbouring cells neighbouring seeds. init_by_array mixes them instead.
local function init_by_array(key)
  local klen = alen(key)
  if klen < 1 then error('mt19937: the key array is empty', 2) end
  local mt = init_genrand(19650218)
  local i, j, k = 1, 0, N
  if klen > N then k = klen end
  while k > 0 do
    mt[i] = imod(bxor(mt[i], mul32(bxor(mt[i - 1], rsh(mt[i - 1], 30)), 1664525))
                 + key[j + 1] + j, TWO32)
    i = i + 1; j = j + 1
    if i >= N then mt[0] = mt[N - 1]; i = 1 end
    if j >= klen then j = 0 end
    k = k - 1
  end
  k = N - 1
  while k > 0 do
    -- + TWO32 keeps the operand NON-NEGATIVE. imod floor-divides, so it already returns the right
    -- residue for a negative input; this is here for the reader who substitutes a truncating
    -- modulus -- math.mod on 5.0.2 is fmod, which returns a NEGATIVE remainder and would corrupt
    -- the state silently from this one line.
    mt[i] = imod(bxor(mt[i], mul32(bxor(mt[i - 1], rsh(mt[i - 1], 30)), 1566083941))
                 - i + TWO32, TWO32)
    i = i + 1
    if i >= N then mt[0] = mt[N - 1]; i = 1 end
    k = k - 1
  end
  mt[0] = UPPER
  return mt, N
end

-- new(seed) or new{a, b, c}. An integer is wrapped, so a one-element key and a bare integer are the
-- same stream and there is no second convention to remember.
function M.new(seed)
  local key = seed
  if type(seed) == 'number' then key = {seed} end
  if type(key) ~= 'table' then error('mt19937.new wants a number or an array of numbers', 2) end
  local o = {}
  o.mt, o.mti = init_by_array(key)
  -- tw IS THE LAZY TWIST'S WATERMARK: how many words of the current pass have been regenerated.
  -- Seeding leaves mti at N, so the first u32 opens a pass and sets both -- this is here so the
  -- invariant holds from construction rather than from the first call happening to reset it.
  o.tw = N
  return setmetatable(o, MT)
end

-- Twist words tw .. upto of the current pass, IN ORDER. -> nothing
--
-- LAZY, AND THAT IS WHERE THE TIME WENT. The reference algorithm regenerates all 624 words the moment
-- one is asked for, and this generator is used differently from the reference: a plan keys a FRESH
-- stream per cell -- {magic, iteration, purpose, vi, ri} -- and then draws ONE number from it. So 624
-- twists were run to consume one word, about 5000 table lookups to produce 32 bits.
--
-- EXACT, BECAUSE THE DEPENDENCIES RUN FORWARD. Word kk reads mt[kk] and mt[kk+1] -- both still
-- untwisted in this pass, which is what the reference reads too -- and mt[kk+MM] for kk < N-MM, also
-- untwisted. Past that it reads mt[kk+MM-N], which is BEHIND kk and therefore already twisted, and
-- the last word reads mt[0] and mt[MM-1], both twisted earlier in the pass. In-order lazy twisting
-- presents every one of those reads with the same value the eager loop would have. Nothing is
-- skipped: a draw that walks the whole block -- below() rejecting, or a shuffle -- twists every word
-- it reaches, just later.
--
-- MEASURED on a 1512-row plan under the host Lua: 8.7 s to 5.2 s, and the emitted CSV is unchanged
-- byte for byte. With the flat table and the run-out above, the draw is 19.3 s to 5.2 s overall.
-- tools/test_soakrand.py holds the sequence to CPython's, including the rejection loop that draws
-- hundreds of words from one stream; MT:u32_eager below is the reference form, kept so a test can
-- hold the lazy path to it directly rather than only to the Python twin.
function MT:twistto(upto)
  local mt, kk = self.mt, nil
  for kk = self.tw, upto do
    -- The partner word, wrapping at the end of the block: the reference spells this as a separate
    -- tail step for kk = N-1, which is the one place it reads mt[0] instead of mt[kk+1].
    local nxt = kk + 1
    if nxt >= N then nxt = 0 end
    -- (mt[kk] & 0x80000000) | (mt[nxt] & 0x7fffffff), as arithmetic: the masks are disjoint, so the
    -- OR is a sum, and neither half needs the and-table.
    local y = floor(mt[kk] / UPPER) * UPPER + imod(mt[nxt], UPPER)
    local src
    if kk < N - MM then src = mt[kk + MM] else src = mt[kk + MM - N] end
    mt[kk] = bxor(src, rsh(y, 1))
    if imod(y, 2) == 1 then mt[kk] = bxor(mt[kk], MATRIX_A) end
  end
  if upto + 1 > self.tw then self.tw = upto + 1 end
end

function MT:u32()
  if self.mti >= N then
    self.mti = 0
    self.tw = 0
  end
  if self.mti >= self.tw then self:twistto(self.mti) end
  local y = self.mt[self.mti]
  self.mti = self.mti + 1
  y = bxor(y, rsh(y, 11))
  y = bxor(y, band(lsh(y, 7), TEMPER_B))
  y = bxor(y, band(lsh(y, 15), TEMPER_C))
  y = bxor(y, rsh(y, 18))
  return y
end

function MT:u32_eager()
  if self.mti >= N then
    local mt, kk, y = self.mt, nil, nil
    for kk = 0, N - MM - 1 do
      y = floor(mt[kk] / UPPER) * UPPER + imod(mt[kk + 1], UPPER)
      mt[kk] = bxor(mt[kk + MM], rsh(y, 1))
      if imod(y, 2) == 1 then mt[kk] = bxor(mt[kk], MATRIX_A) end
    end
    for kk = N - MM, N - 2 do
      y = floor(mt[kk] / UPPER) * UPPER + imod(mt[kk + 1], UPPER)
      mt[kk] = bxor(mt[kk + (MM - N)], rsh(y, 1))
      if imod(y, 2) == 1 then mt[kk] = bxor(mt[kk], MATRIX_A) end
    end
    y = floor(mt[N - 1] / UPPER) * UPPER + imod(mt[0], UPPER)
    mt[N - 1] = bxor(mt[MM - 1], rsh(y, 1))
    if imod(y, 2) == 1 then mt[N - 1] = bxor(mt[N - 1], MATRIX_A) end
    self.mti = 0
  end
  local y = self.mt[self.mti]
  self.mti = self.mti + 1
  y = bxor(y, rsh(y, 11))
  y = bxor(y, band(lsh(y, 7), TEMPER_B))
  y = bxor(y, band(lsh(y, 15), TEMPER_C))
  y = bxor(y, rsh(y, 18))
  return y
end

-- [0,1). u32/2^32 rather than the 53-bit form: one word per draw keeps the two implementations
-- comparable word for word, and no decision here needs more than 32 bits of resolution.
function MT:float() return self:u32() / TWO32 end

-- An integer in [0, n), REJECTING the ragged tail rather than taking a modulus of the whole range.
-- A bare mod favours the low residues, and the whole point of a seeded rate draw is that the
-- distribution is the one claimed.
function MT:below(n)
  if n == nil or n < 1 or floor(n) ~= n then
    error('mt19937 below() wants a positive integer, got ' .. tostring(n), 2)
  end
  if n == 1 then return 0 end
  local limit = TWO32 - imod(TWO32, n)
  local x = self:u32()
  while x >= limit do x = self:u32() end
  return imod(x, n)
end

-- Inclusive, for reading at the call site.
function MT:range(lo, hi) return lo + self:below(hi - lo + 1) end

-- Fisher-Yates, descending, on a 1-based array. In place, and it returns the table so a call reads
-- as a value. Descending and below(i) are chosen to match the Python twin exactly; any other order
-- is a different permutation from the same seed.
function MT:shuffle(t)
  local n = alen(t)
  local i
  for i = n, 2, -1 do
    local j = 1 + self:below(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

end

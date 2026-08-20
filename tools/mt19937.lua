-- MT19937, seeded by an integer key array, producing the reference sequence.
--
-- WHY NOT math.random. A soak that varies per iteration is only useful if iteration 129 can be
-- replayed on its own, and math.random is the platform's rand(): the host and the instrument
-- disagree, so the same seed picks different rates in the offline suites than on the box. Park-Miller
-- in gen_serial.lua exists for the same reason; this is the same argument with a generator whose
-- sequence has no short-period structure to trip over.
--
-- ARITHMETIC ONLY -- NO BITWISE OPERATORS, NO '%', NO '#'. 5.0.2 has none of them (they are SYNTAX
-- errors there, not missing functions), so a module written with them cannot move to the instrument
-- later and cannot be checked by eye against the Python twin. Every operation here is +, -, *, / and
-- math.floor on doubles.
--
-- EXACTNESS, which is the only thing that makes that safe:
--   * imod(a, b) is exact whenever a/b is exact or its true quotient is under 2^53. Every modulus
--     here is a POWER OF TWO except in below(), where the quotient is bounded by 2^32.
--   * mul32 splits the multiplier into 16-bit halves so no product exceeds 2^48. A direct
--     1812433253 * (2^32-1) is 7.8e18 -- 860x over 2^53 -- and would silently lose low bits, which
--     is exactly the state the generator carries forward.
--   * bxor and band go through a 4-bit table, so they never form an intermediate above 2^32.
--
-- The sequence is checked against CPython's random module, which is this algorithm, by
-- tools/test_soakrand.py. init_by_array's first act is init_genrand(19650218), so agreement there
-- exercises both seeding routines.

local M = {}

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

-- 4-bit xor and and, built once. Eight lookups cover a 32-bit word.
local X4, A4 = {}, {}
do
  local a, b, i
  for a = 0, 15 do
    X4[a], A4[a] = {}, {}
    for b = 0, 15 do
      local x, n, pa, pb, p = 0, 0, a, b, 1
      for i = 1, 4 do
        local ba, bb = imod(pa, 2), imod(pb, 2)
        if ba ~= bb then x = x + p end
        if ba == 1 and bb == 1 then n = n + p end
        pa, pb, p = (pa - ba) / 2, (pb - bb) / 2, p * 2
      end
      X4[a][b], A4[a][b] = x, n
    end
  end
end

local function bxor(a, b)
  local r, p, i = 0, 1
  for i = 1, 8 do
    r = r + X4[imod(a, 16)][imod(b, 16)] * p
    a = floor(a / 16); b = floor(b / 16); p = p * 16
  end
  return r
end

local function band(a, b)
  local r, p, i = 0, 1
  for i = 1, 8 do
    r = r + A4[imod(a, 16)][imod(b, 16)] * p
    a = floor(a / 16); b = floor(b / 16); p = p * 16
  end
  return r
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
  return setmetatable(o, MT)
end

function MT:u32()
  if self.mti >= N then
    local mt, kk, y = self.mt, nil, nil
    for kk = 0, N - MM - 1 do
      y = band(mt[kk], UPPER) + band(mt[kk + 1], LOWER)
      mt[kk] = bxor(mt[kk + MM], rsh(y, 1))
      if imod(y, 2) == 1 then mt[kk] = bxor(mt[kk], MATRIX_A) end
    end
    for kk = N - MM, N - 2 do
      y = band(mt[kk], UPPER) + band(mt[kk + 1], LOWER)
      mt[kk] = bxor(mt[kk + (MM - N)], rsh(y, 1))
      if imod(y, 2) == 1 then mt[kk] = bxor(mt[kk], MATRIX_A) end
    end
    y = band(mt[N - 1], UPPER) + band(mt[0], LOWER)
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

return M

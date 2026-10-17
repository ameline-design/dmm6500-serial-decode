-- ---------------------------------------------------------------------------
-- bench/expect.tsp -- what each vector should have said, computed not stored
-- ---------------------------------------------------------------------------
-- Why this exists: the soak panel could say how many cells failed to produce a decode and nothing about
-- whether the bytes were right, so a run decoding garbage looked identical to a healthy one. Measured on
-- a 396-cell lap: the panel showed 59 failures where tools/judge_bench.py found 192, the other 133 having
-- decoded confidently wrong bytes. An operator deciding whether to abort could not see the 133.
--
-- Generated rather than tabulated, and the sizes are why. The 48 vectors carry about 110 kB of payload
-- between them -- 64 kB in one of them, 32 kB in another -- which escaped into Lua source would be two to
-- four times that against a 721 kB app. Every payload is reproducible instead: the prose ones from one
-- 460-byte string, the random ones from a seed. So this file is a few hundred bytes and covers any length.
--
-- It also avoids a trap. The prose payloads contain CR LF, and the DMM strips CR from a socket load, so a
-- stored literal would need escaping to survive one. A generator has nothing to escape.
--
-- The generators must stay byte-identical to tools/make_vectors.lua, which is what actually built the
-- waveforms. That is a copy, and a copy can drift, so tools/test_bench_engine.lua runs both at several
-- lengths and compares -- the same guard tools/test_judge_v.py puts on the loud budget.
bexp = bexp or {}

-- Verbatim from tools/make_vectors.lua. Concatenated the same way so the two are diffable line for line.
bexp.LOREM =
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod ' ..
  'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim ' ..
  'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea ' ..
  'commodo consequat. Duis aute irure dolor in reprehenderit in voluptate ' ..
  'velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint ' ..
  'occaecat cupidatat non proident, sunt in culpa qui officia deserunt ' ..
  'mollit anim id est laborum. '

-- Exactly nwant bytes of wrapped prose. math.mod rather than math.fmod: this is Lua 5.0.2 and fmod does
-- not exist. Truncated hard at the end rather than rounded to a line, so the count here is the count on
-- the wire.
function bexp.lorem_text(nwant, cols)
  local out, no = {}, 0
  local col, i, total = 0, 0, 0
  local ln = string.len(bexp.LOREM)
  while total < nwant do
    i = i + 1
    local at = math.mod(i - 1, ln) + 1
    local ch = string.sub(bexp.LOREM, at, at)
    no = no + 1; out[no] = ch; total = total + 1
    col = col + 1
    if col >= cols and ch == ' ' and total + 2 <= nwant then
      no = no + 1; out[no] = '\013'
      no = no + 1; out[no] = '\010'
      total = total + 2
      col = 0
    end
  end
  return table.concat(out)
end

-- What each vector sends, by id. `kind` names the generator and the rest are its arguments, so a vector
-- added to make_vectors.lua needs one row here and no new code.
--
-- The six gap vectors only, to begin with. Their idle runs carry no frames, so the expected bytes are the
-- payload unchanged -- make_vectors.lua says so at the definitions -- which makes them the set where this
-- comparison is unambiguous. The random and impaired vectors need the per-vector expectation rules
-- tools/judge_bench.py already carries, and guessing at those here would put a wrong verdict on the glass.
bexp.VEC = {
  v98a = {kind = 'lorem', n = 130, cols = 64},
  v98b = {kind = 'lorem', n = 130, cols = 64},
  v98c = {kind = 'lorem', n = 130, cols = 64},
  v99a = {kind = 'lorem', n = 80, cols = 64},
  v99b = {kind = 'lorem', n = 80, cols = 64},
  v99c = {kind = 'lorem', n = 80, cols = 64},
}

-- Cached per id, because a lap plays one vector over 22 rates and regenerating the same bytes 22 times is
-- the kind of cost that only shows up as a slower lap.
bexp.cache = bexp.cache or {}

-- The bytes a vector should have sent, or nil when this file does not know. nil is a real answer and the
-- caller must treat it as "no verdict" rather than as a mismatch.
function bexp.bytes(vid)
  if vid == nil then return nil end
  if bexp.cache[vid] ~= nil then return bexp.cache[vid] end
  local d = bexp.VEC[vid]
  if d == nil then return nil end
  local s = nil
  if d.kind == 'lorem' then s = bexp.lorem_text(d.n, d.cols) end
  bexp.cache[vid] = s
  return s
end

-- The same bytes as an array, cached beside the string, because the fallback sweep below reads the payload
-- wl times and string.byte in that inner loop is the whole cost.
bexp.barr_cache = bexp.barr_cache or {}

function bexp.barr(vid)
  if vid == nil then return nil end
  if bexp.barr_cache[vid] ~= nil then return bexp.barr_cache[vid] end
  local s = bexp.bytes(vid)
  if s == nil then return nil end
  local a, i = {}, nil
  for i = 1, string.len(s) do a[i] = string.byte(s, i) end
  bexp.barr_cache[vid] = a
  return a
end

-- How many bytes to align on. Long enough that a run of prose cannot match in two places, short enough to
-- survive a capture that opens mid-frame.
bexp.alignn = 12

-- How many confident bytes before a verdict means anything -- a COUNT, not a run. The gate used to be
-- alignn CONSECUTIVE confident frames, which is also what the alignment needed, and that coupling is what
-- made the five worst cells of the 2026-10-17 lap report no verdict at all: too corrupt to supply a clean
-- run, so they dropped out of the denominator the panel divides by while being real failures.
--
-- Twelve is also what keeps the fallback sweep honest. Best-of-wl inflates by construction, and at twelve
-- compared the chance best over 130 shifts of lowercase prose is three or four -- under the 0.5 fraction
-- brun.paywrong_frac calls wrong, so the inflation cannot manufacture a pass.
bexp.mincmp = 12

-- Ceiling on the fallback sweep, in byte comparisons, which cost wl * ncmp. The worst gap cell measured is
-- 130 x 704 = 91 520 and runs in the noise beside a cell that takes seconds; a 64 kB payload would be 46
-- million. Past the ceiling there is no verdict rather than a slow one.
bexp.cmpmax = 200000

-- How much larger than the median frame pitch a gap has to be to count as a seam. Two: a frame follows
-- its predecessor by one frame time on a gap = 0 payload, so anything near twice that is silence.
bexp.seammult = 2

-- Per-BURST comparison. -> nmatch, ncmp, nburst; nil when there is no verdict.
--
-- WHY A SECOND FUNCTION RATHER THAN A BETTER ONE. bexp.match aligns the whole capture on a single shift,
-- which is right for a contiguous record and wrong for an elided one: each seam destroys 4 to 9 payload
-- bytes while the framer resynchronises, and the record comes out one FRAME short of where the payload
-- got to -- so every byte after the first seam is charged wrong and a cell carrying 2 to 3 % bad bytes
-- reports 33 to 73 %. Worse, which segment the single shift happens to fit depends on where the record
-- opened, so the figure is not even stable across cells of the same vector.
--
-- This is reported ALONGSIDE that figure and feeds no gate. The per-burst number is strictly more
-- generous -- given enough bursts an alignment can be found for anything -- so it is information for a
-- reader and not a verdict, and the burst COUNT goes out with it because a record needing many is itself
-- the finding. brun.paywrong_frac keeps reading bexp.match, so the red rule on the panel is unchanged;
-- whether it SHOULD read this instead is a question about what the operator is being asked to abort on.
--
-- Seams come from res.tpos, each frame's start in samples, so no rate or format arithmetic is needed:
-- a pitch more than seammult times the median is silence. That is the same shape of test ua_run uses.
function bexp.match_bursts(res, vid)
  local want = bexp.bytes(vid)
  if want == nil or res == nil or (res.nf or 0) < 1 then return nil end
  if res.tpos == nil then return nil end
  local wl = string.len(want)
  local arr = bexp.barr(vid)
  if wl < 1 or arr == nil then return nil end

  -- Pitches between CONSECUTIVE frames, confident or not: a seam's own debris frames are flagged, and
  -- skipping them would merge the seam into the burst before it.
  local k, pitch, np = nil, {}, 0
  for k = 2, res.nf do
    local a, b = res.tpos[k - 1], res.tpos[k]
    if a ~= nil and b ~= nil and b > a then np = np + 1 pitch[np] = b - a end
  end
  if np < 2 then return nil end
  -- Median by selection rather than a sort: np is a few hundred and this runs once a cell.
  local med, best = nil, nil
  do
    local i
    for i = 1, np do
      local below, j = 0, nil
      for j = 1, np do if pitch[j] < pitch[i] then below = below + 1 end end
      if below <= np / 2 and (best == nil or pitch[i] < best) then best = pitch[i] end
    end
    med = best
  end
  if med == nil or med <= 0 then return nil end

  -- Split at the seams, then align each burst on its own with the whole-record machinery.
  local bursts, nb, from = {}, 0, 1
  for k = 2, res.nf do
    local a, b = res.tpos[k - 1], res.tpos[k]
    if a ~= nil and b ~= nil and (b - a) > bexp.seammult * med then
      nb = nb + 1
      bursts[nb] = {from, k - 1}
      from = k
    end
  end
  nb = nb + 1
  bursts[nb] = {from, res.nf}

  local tm, tc, nused = 0, 0, 0
  local bi
  for bi = 1, nb do
    local lo, hi = bursts[bi][1], bursts[bi][2]
    -- A view of the burst, renumbered from 1, so match() aligns it as if it were a whole capture.
    local sub = {nf = hi - lo + 1, vals = {}, errs = {}}
    local j
    for j = lo, hi do
      sub.vals[j - lo + 1] = res.vals[j]
      sub.errs[j - lo + 1] = res.errs[j]
    end
    local m, c = bexp.match(sub, vid)
    if m ~= nil and c ~= nil then tm = tm + m tc = tc + c nused = nused + 1 end
  end
  if tc < bexp.mincmp then return nil end
  return tm, tc, nb
end

-- Compare a decode against what the vector sends. -> nmatch, ncmp, shift; nil when there is no verdict.
--
-- The arb loops, so a capture starts at an arbitrary byte of the payload and the comparison has to find
-- that offset before it can count anything. Found with string.find over the payload doubled, which is a
-- plain C search rather than a Lua loop over every shift: the whole-shift sweep is 130 x 130 comparisons
-- on the shortest vector here and a million on a 1 kB one, and this is two string operations.
--
-- Flagged frames are skipped rather than counted wrong. The app already flagged them and brun counts them
-- separately; counting them here too would report one defect as two and make a framing problem look like
-- a payload problem. So ncmp is the number of confident bytes compared, which is exactly the population
-- the question "were the bytes right" is about.
function bexp.match(res, vid)
  local want = bexp.bytes(vid)
  if want == nil or res == nil or (res.nf or 0) < 1 then return nil end
  local wl = string.len(want)
  if wl < 1 then return nil end
  local arr = bexp.barr(vid)
  if arr == nil then return nil end

  -- Every confident frame once, keeping its own frame INDEX: the shift arithmetic is on the index, so a
  -- skipped frame must not renumber the ones after it.
  local idx, val, nc, k = {}, {}, 0, nil
  for k = 1, res.nf do
    if res.errs[k] == nil then
      nc = nc + 1
      idx[nc] = k
      val[nc] = math.mod(res.vals[k] or 0, 256)
    end
  end
  if nc < bexp.mincmp then return nil end

  local function count(sh)
    local n, i = 0, nil
    for i = 1, nc do
      if val[i] == arr[math.mod(sh + idx[i] - 1, wl) + 1] then n = n + 1 end
    end
    return n
  end

  -- FAST PATH, and the common one: the first run of alignn confident bytes, located with string.find over
  -- the payload doubled, which is a C search rather than a Lua loop over every shift. Twelve bytes of
  -- prose land in one place, so a hit IS the shift and needs no search.
  local run, at0, sh = 0, nil, nil
  for k = 1, res.nf do
    if res.errs[k] == nil then
      if run == 0 then at0 = k end
      run = run + 1
      if run >= bexp.alignn then break end
    else
      run = 0
    end
  end
  if at0 ~= nil and run >= bexp.alignn then
    local nd = ''
    for k = at0, at0 + bexp.alignn - 1 do
      nd = nd .. string.char(math.mod(res.vals[k] or 0, 256))
    end
    local found = string.find(want .. want, nd, 1, true)
    if found ~= nil then sh = math.mod(found - 1 - (at0 - 1) + wl * 2, wl) end
  end

  -- FALLBACK: every alignment, best wins, which is what tools/judge_bench.py does and the only form a
  -- corrupt anchor cannot defeat. Reached two ways and BOTH were live in the lap of 2026-10-17:
  --
  --   * no run of alignn confident frames at all. Five cells, and they were five real failures -- they
  --     used to return nil here and vanish from the denominator the panel divides by, so the worst cells
  --     in the lap were exactly the ones it could not count.
  --   * a run whose bytes appear nowhere in the payload, because one of them is confidently wrong. That
  --     used to report a hard 0 of nf, and cell 11 did: 0 of 131 on a cell the host judge passes. An
  --     exact zero is a program artefact -- real corruption scatters, and best-of-wl is what shows it.
  if sh == nil then
    if wl * nc > bexp.cmpmax then return nil end
    local best, bs, s = -1, nil, nil
    for s = 0, wl - 1 do
      local n = count(s)
      if n > best then best, bs = n, s end
      if best == nc then break end
    end
    return best, nc, bs
  end
  return count(sh), nc, sh
end

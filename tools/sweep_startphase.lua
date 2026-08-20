-- sweep_startphase.lua -- every bench vector, decoded from an arbitrary capture start, under noise
-- and jitter. One shard of an embarrassingly parallel sweep.
--
-- WHY. The bench runs one capture per point and a soak lap is minutes; this host runs a decode in
-- ~8 ms across 12 shards on 16 cores, so the same coverage costs seconds. Every defect this decoder
-- ships hides behind something the suites hold FIXED -- a sample rate named by hand, a capture that
-- always opens at the same place -- so the cheap move is to vary everything at once, on every vector,
-- and let the machine find the holes.
--
-- THE VECTOR SET COMES FROM make_vectors.lua, not from a list here. It is dofile()d in define-only
-- mode (VEC_DEFINE_ONLY) and VEC_LIST is read, so a vector added for the bench is swept from the
-- moment it exists; a hand-copied subset drifts the first time one is added.
--
--   lua tools/sweep_startphase.lua --shard 1/12 --offsets 24 --seed 7
--   python3 tools/sweep_all.py                       # fans out every shard and aggregates
--
-- WHAT IS A HARD FAILURE, AND WHAT IS ONLY COUNTED. Three things are always wrong and exit 1:
--   * the decode RAISES -- there is no capture for which that is the right answer;
--   * a result comes back with an incomplete format (any of nbits/par/nstop/invert nil) -- the panel
--     reads all four, and this is the r06 defect;
--   * the format was read CORRECTLY and a byte the decoder presents as trustworthy is still wrong --
--     a silent wrong answer, the defect class this decoder exists to avoid.
-- Everything else is counted and printed, not failed, because it is honest or already known:
--   * a REFUSAL on a short or badly placed window is the correct answer;
--   * a DIFFERENT format on a genuinely ambiguous payload -- 7E1 read as 8N1 on a gapless stream is
--     open issue #49 and a real ambiguity, not a bug this sweep gets to relitigate;
--   * a WRONG RATE on a periodic payload is open issue #46, mechanism still unresolved.
-- Counting them means a regression shows up as a count that moved, which is the honest signal while
-- the issues are open. Turning either into a gate needs its issue closed first.

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

VEC_DEFINE_ONLY = true
dofile('tools/make_vectors.lua')
local V = VEC_LIST
if V == nil then print('make_vectors.lua did not publish VEC_LIST'); os.exit(1) end

-- ---------- arguments ----------
-- maxpts HIGH ENOUGH TO SKIP NOTHING, which is a measurement and not a guess. The bound must sit
-- ABOVE the largest vector: below it, v96 -- the 32 kB random vector, 3 413 625 points -- is dropped
-- from every run silently. Measured: v96 renders in 0.4 s and 148 MB resident, so twelve workers all
-- rendering it at once is under 2 GB. The guard stays because an unbounded render is worth refusing.
local A = {shard = 1, nshard = 1, offsets = 24, seed = 1, maxpts = 4000000, quiet = false}
-- Bounds-checked below rather than trusted. An out-of-range shard makes the unit filter match
-- NOTHING, and a shard that runs zero cases still prints a clean summary and exits 0 -- so a typo in
-- the driver would report full coverage from a run that decoded nothing at all.
local ai = 1
while arg ~= nil and arg[ai] ~= nil do
  local k, v = arg[ai], arg[ai + 1]
  if k == '--shard' then
    local a, b = string.find(v, '/')
    A.shard = tonumber(string.sub(v, 1, a - 1))
    A.nshard = tonumber(string.sub(v, b + 1))
    ai = ai + 2
  elseif k == '--offsets' then A.offsets = tonumber(v); ai = ai + 2
  elseif k == '--seed' then A.seed = tonumber(v); ai = ai + 2
  elseif k == '--maxpts' then A.maxpts = tonumber(v); ai = ai + 2
  elseif k == '--quiet' then A.quiet = true; ai = ai + 1
  else print('unknown argument: ' .. tostring(k)); os.exit(2) end
end
if A.nshard == nil or A.nshard < 1 or A.shard == nil or A.shard < 1 or A.shard > A.nshard then
  print(string.format('REFUSING: --shard %s/%s is out of range; shard must be 1..nshard',
                      tostring(A.shard), tostring(A.nshard)))
  os.exit(2)
end
if A.offsets == nil or A.offsets < 1 then
  print('REFUSING: --offsets must be at least 1'); os.exit(2)
end

-- ---------- conditions ----------
-- PHASE IS SWEPT ALONGSIDE jitter and noise rather than on its own axis, because it is a different
-- variable from the window start and both matter: `phase` moves where every sample lands INSIDE each
-- bit cell, the window start moves which bit cell comes first. Multiplying them out would quadruple
-- the run for a second-order interaction, so each condition carries a distinct phase instead.
-- 0.37 is GEN_RENDER's own default and is kept as condition 1 so a result stays comparable with
-- every historical offline number in this repo.
local COND = {
  {phase = 0.37, jitter = 0.00, noise = 0.00},
  {phase = 0.12, jitter = 0.05, noise = 0.02},
  {phase = 0.63, jitter = 0.10, noise = 0.02},
  {phase = 0.88, jitter = 0.05, noise = 0.05},
}
local ncond = table.getn(COND)

-- ---------- helpers ----------
local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.proto = 'uart'
  sdec.ui_mode = 'text'
end

-- Bytes i0..i1 of a value table as a string. NOT GEN_STR, which starts at 1, has no slice argument
-- and substitutes '.' for anything out of range -- a substitution that would turn a nil value into a
-- byte that matches real payload text and quietly weaken the substring check.
local function bytes_str(by, i0, i1)
  if by == nil or i1 < i0 then return nil end
  local out, no = {}, 0
  local chunk, nc = {}, 0
  local i
  for i = i0, i1 do
    local v = by[i]
    if v == nil or v < 0 or v > 255 then return nil end
    nc = nc + 1; chunk[nc] = string.char(v)
    if nc >= 64 then no = no + 1; out[no] = table.concat(chunk); chunk, nc = {}, 0 end
  end
  if nc > 0 then no = no + 1; out[no] = table.concat(chunk) end
  return table.concat(out)
end

-- The longest run of consecutive frames the decoder itself presents as trustworthy. -> first, len.
--
-- THE LOWER BOUND IS ua_err_count'S OWN, max(ua_edge_frames, head_bad), AND GETTING THAT WRONG
-- PRODUCED 13 FALSE FAILURES on the first run of this file. Using head_bad alone starts the run at
-- frame 1 whenever headsusp is nil -- which is most of the time, since a misaligned head on a
-- gapless line often produces no framing error to notice -- and the head bytes ARE wrong there.
-- Measured over those 13: the damage was 1 to 3 bytes, i.e. exactly what ua_edge_frames = 3 already
-- excludes, and every one of them decoded correctly from frame 4 on.
--
-- Deriving the bound from the app rather than restating it is also the point: this then tests the
-- shipped ERR semantics -- "every byte ERR does not count is a byte you can trust" -- instead of a
-- rule invented here that could agree with nothing.
-- The final frame is always excluded; the window boundary halves it whatever the alignment.
local function trusted_run(r)
  local hb = sdec.ua_head_bad(r, r.headsusp) or 0
  local ef = sdec.ua_edge_frames or 3
  if ef > hb then hb = ef end
  local first, len = 0, 0
  local cur, curn = nil, 0
  local j
  for j = hb + 1, (r.nf or 0) - 1 do
    if r.errs[j] == nil and r.vals[j] ~= nil then
      if cur == nil then cur, curn = j, 0 end
      curn = curn + 1
      if curn > len then first, len = cur, curn end
    else
      cur, curn = nil, 0
    end
  end
  return first, len
end

-- A run this short carries too little information to be evidence either way: at 4 bytes a false
-- substring hit in a 256-byte payload is likely enough to make the check meaningless.
local MINRUN = 8
-- How far past ERR's own exclusion the head is allowed to bleed before the case is called interior
-- corruption instead. 40 frames is well beyond anything measured (the worst so far is 11) and is
-- there to bound the search, not to express a tolerance.
local MAXSHIFT = 40

local function fmt_of(nbits, par, nstop)
  local p = 'N'
  if par == 1 then p = 'E' elseif par == 2 then p = 'O' end
  return string.format('%s%s%s', tostring(nbits), p, tostring(nstop))
end

-- ---------- the sweep ----------
local nv = table.getn(V)
local hard, nhard = {}, 0           -- hard failures, with enough detail to rerun the case
local ncase, nrefuse, nfmtdiff, nratediff, nshortrun, nok = 0, 0, 0, 0, 0, 0
local nheadbleed, worstbleed, worstbleedwhat = 0, 0, ''
-- WOULD QUOTING headsusp BE BETTER THAN NARROWING TO THE LAST FLAG? uart_decode.tsp:508 asserts that
-- headsusp "over-claims" and narrows to the last flagged frame for that reason, which costs the bleed
-- above. The counters below measure both directions, since the first byte that agrees with the payload
-- is where the damage actually ends. Measured over 4704 decodes: narrowing under-reports 396 bytes,
-- quoting headsusp over-reports 57902 and catches nothing extra. The narrowing wins by 146x.
local nhs, nhsover, hsoversum, worsthsover, worsthsoverwhat = 0, 0, 0, 0, ''
local nhsunder, bleedsum = 0, 0
local nredecode = 0                 -- times refine_parity's non-strict branch ran, for coverage
local nskip, skipped = 0, {}
local WANT = sdec.n_deliv(sdec.n) or 19000

-- Wrapped so the branch is counted wherever it fires, over every vector rather than one family.
local real_refine = sdec.ua_refine_parity
sdec.ua_refine_parity = function(r, rd, n, T)
  local out = real_refine(r, rd, n, T)
  if out ~= nil and r ~= nil and out ~= r then nredecode = nredecode + 1 end
  return out
end

local function note_hard(what, detail)
  nhard = nhard + 1
  if nhard <= 40 then hard[nhard] = what .. '  ' .. detail end
end

local vi
for vi = 1, nv do
  -- SHARDED BY (VECTOR x CONDITION), not by vector: Random32kB (v96) renders 3.4 M points and
  -- Hello (v41) 2.0 k,
  -- so sharding by vector alone would leave one core doing minutes of work while eleven idled.
  local v = V[vi]
  local ci
  for ci = 1, ncond do
    local unit = (vi - 1) * ncond + ci
    if math.mod(unit - 1, A.nshard) == A.shard - 1 then
      local c = COND[ci]
      -- The generator's PRNG is reseeded per vector so a payload is a function of its seed alone --
      -- make_vectors.lua does the same, and a vector whose bytes moved between the two would make
      -- every oracle comparison meaningless.
      GEN_RESEED(12345)
      local opts, want, nwant, post, payload = v.build()
      local npts = math.ceil((opts.fs or v.fs) / (opts.baud or 9600))
      opts.phase, opts.jitter, opts.noise = c.phase, c.jitter, c.noise
      local rd, ts, nc, ns, lb, lnb
      if v.lin then
        rd, ts, nc, ns, lb, lnb = GEN_LIN(opts)
        want, nwant = lb, lnb
      else
        rd, ts, nc, ns = GEN(opts)
      end
      if ns == nil or ns < 100 then
        nskip = nskip + 1
        skipped[nskip] = string.format('%s cond %d: render returned %s points', v.id, ci, tostring(ns))
      elseif ns > A.maxpts then
        nskip = nskip + 1
        skipped[nskip] = string.format('%s cond %d: %d points over --maxpts %d', v.id, ci, ns, A.maxpts)
      else
        if post ~= nil then rd = post(rd, ns) end
        local pay = payload
        if pay == nil and want ~= nil and nwant ~= nil and nwant > 0 then
          pay = bytes_str(want, 1, nwant)
        end
        -- REPEATED UNTIL IT COVERS A WHOLE WINDOW PLUS ONE PERIOD, not merely doubled. Payloads here
        -- run from 13 bytes to 32 kB, and a 19 000-sample window holds ~182 bytes at 8.33 sa/bit, so
        -- doubling a payload shorter than the window leaves nowhere for a correct full-window run to
        -- match -- for a 13-byte payload, no alignment at all. That reads as a WRONG BYTES failure on
        -- a decode that was perfect, so the multiple is computed from the window rather than fixed.
        -- npts is samples per bit; a frame is at most 13 cells, so this bounds the bytes a window can
        -- possibly hold. Two extra copies cover the alignment slack at both ends.
        local pay2 = nil
        if pay ~= nil and string.len(pay) > 0 then
          local maxb = math.ceil(WANT / (npts * 10)) + 2
          local nrep = math.ceil(maxb / string.len(pay)) + 2
          local t, i = {}, nil
          for i = 1, nrep do t[i] = pay end
          pay2 = table.concat(t)
        end

        -- WINDOW LENGTH AND WHETHER THE WINDOW WRAPS BOTH FOLLOW opts.loop, and that is a
        -- correctness point rather than a convenience. loop = true means the render is an exact
        -- whole number of bit times, so a TrueArb repeat joins seamlessly and a wrapped window is
        -- exactly what the instrument sees. WITHOUT it the repeat splices a partial cell onto the
        -- first one and corrupts that frame -- a real artefact on the bench, but not one this sweep
        -- can attribute, so a non-looping vector is windowed strictly INSIDE its own render.
        local wrap = (opts.loop == true)
        local wlen = WANT
        if not wrap then
          -- 0.6 rather than the whole render: at ns - wlen == 0 there is exactly one placement and
          -- nothing is swept, which is the failure mode this file exists to avoid.
          if wlen > math.floor(ns * 0.6) then wlen = math.floor(ns * 0.6) end
        end
        local span = ns
        if not wrap then span = ns - wlen end
        if span < 1 then span = 1 end

        local oi
        for oi = 0, A.offsets - 1 do
          -- Offsets are spread across the span and then SKEWED by the shard seed, so successive
          -- runs of the loop driver probe different placements instead of re-testing one grid.
          -- The skew is a prime-ish stride against the ~10.4-sample bit cell, so the sub-bit phase
          -- moves too rather than the whole grid sliding by whole bits.
          local base = math.floor(oi * span / A.offsets)
          local s0 = math.mod(base + A.seed * 37 + oi * 7, span)
          local w, n = {}, 0
          local i
          if wrap then
            for i = 0, wlen - 1 do n = n + 1; w[n] = rd[math.mod(s0 + i, ns) + 1] end
          else
            for i = 0, wlen - 1 do n = n + 1; w[n] = rd[s0 + i + 1] end
          end

          clearforce()
          if v.proto ~= nil then sdec.proto = v.proto end
          sdec.acq_fs = v.fs
          sdec.sig_levels(w, n)
          sdec.sig_edges(w, n)
          sdec.sig_idle(w, n)
          local ok, why = pcall(function() return sdec.decode_from(w, n) end)
          local r = sdec.res
          ncase = ncase + 1
          local tag = string.format('%s cond %d (phase %.2f jitter %.2f noise %.2f) start %d/%d',
                                    v.id, ci, c.phase, c.jitter, c.noise, s0, ns)

          if not ok then
            note_hard('RAISED', tag .. ': ' .. tostring(why))
          elseif r == nil then
            nrefuse = nrefuse + 1
          elseif r.nbits == nil or r.par == nil or r.nstop == nil or r.invert == nil then
            note_hard('NO FORMAT', string.format('%s: nbits=%s par=%s nstop=%s invert=%s', tag,
                                                 tostring(r.nbits), tostring(r.par),
                                                 tostring(r.nstop), tostring(r.invert)))
          else
            local wf = fmt_of(opts.nbits or 8, opts.par or 0, opts.nstop or 1)
            local gf = fmt_of(r.nbits, r.par, r.nstop)
            local braw = sdec.baud
            local ratebad = (braw == nil or math.abs(braw / (opts.baud or 9600) - 1) > 0.02)
            if ratebad then nratediff = nratediff + 1 end
            -- The stop count is NOT observable -- a second stop bit is a bit of idle -- so it is
            -- excluded from the comparison rather than counted as a disagreement.
            local samefmt = (r.nbits == (opts.nbits or 8) and r.par == (opts.par or 0))
            if not samefmt then
              nfmtdiff = nfmtdiff + 1
            elseif ratebad then
              nok = nok + 1                     -- rate already counted; bytes cannot be judged
            elseif pay2 == nil then
              nok = nok + 1                     -- LIN and the no-payload vectors: nothing to match
            else
              local first, len = trusted_run(r)
              if len < MINRUN then
                nshortrun = nshortrun + 1
              else
                -- THE RUN IS RE-TRIED FROM LATER STARTS, and the number of shifts it takes is the
                -- measurement. A misaligned head that frames cleanly bleeds past what ERR excludes:
                -- ua_head_bad narrows headsusp to the LAST FLAGGED frame on purpose (quoting
                -- headsusp itself over-claims, uart_decode.tsp:508), so when the tail of a suspect
                -- head carries no flags those bytes are wrong and uncounted. Measured on the fox at
                -- gap = 0: headsusp 30, last flag 19, ERR 19, and frames 20..30 wrong.
                -- That is open issue #49's family, not a regression, so it is COUNTED here rather
                -- than failed -- but a run that matches at NO shift is interior corruption and does
                -- fail, because nothing about a capture boundary explains it.
                local shift, hit = 0, nil
                while shift < MAXSHIFT and first + shift + MINRUN - 1 <= first + len - 1 do
                  local s = bytes_str(r.vals, first + shift, first + len - 1)
                  if s ~= nil and string.find(pay2, s, 1, true) ~= nil then hit = shift; break end
                  shift = shift + 1
                end
                -- THE FIRST BYTE THAT AGREES WITH THE PAYLOAD IS WHERE THE DAMAGE ENDS, so a matched
                -- case knows the truth and both candidate rules can be scored against it.
                if hit ~= nil then
                  local hs = r.headsusp or 0
                  local truebad = first + hit - 1
                  if hs > 0 then
                    nhs = nhs + 1
                    if hs > truebad then
                      nhsover = nhsover + 1
                      hsoversum = hsoversum + (hs - truebad)
                      if hs - truebad > worsthsover then
                        worsthsover, worsthsoverwhat = hs - truebad, tag
                      end
                    elseif hs < truebad then
                      nhsunder = nhsunder + 1     -- headsusp would not have covered it either
                    end
                  end
                end
                if hit == 0 then
                  nok = nok + 1
                elseif hit ~= nil then
                  nheadbleed = nheadbleed + 1
                  bleedsum = bleedsum + hit
                  if hit > worstbleed then worstbleed, worstbleedwhat = hit, tag end
                else
                  local s = bytes_str(r.vals, first, first + len - 1)
                  note_hard('WRONG BYTES', string.format(
                      '%s: read %s at the right format, %d trusted bytes match the payload at no '
                      .. 'alignment within %d shifts: %q',
                      tag, gf, len, MAXSHIFT, string.sub(s or '', 1, 40)))
                end
              end
            end
          end
        end
      end
    end
  end
end
sdec.ua_refine_parity = real_refine

-- ---------- report ----------
-- MACHINE-READABLE FIRST LINE, so sweep_all.py can total the shards without parsing prose.
print(string.format('SHARD %d/%d seed %d: cases %d ok %d refused %d fmtdiff %d ratediff %d ' ..
                    'shortrun %d headbleed %d (worst %d) redecodes %d skipped %d HARD %d',
                    A.shard, A.nshard, A.seed, ncase, nok, nrefuse, nfmtdiff, nratediff,
                    nshortrun, nheadbleed, worstbleed, nredecode, nskip, nhard))
-- SECOND MACHINE-READABLE LINE: the two error directions, so the narrow-vs-headsusp choice is decided
-- by totals across every shard rather than by one remembered case.
print(string.format('BLEED %d/%d bleeds %d bleedsum %d bleedworst %d hsset %d hsover %d ' ..
                    'hsoversum %d hsoverworst %d hsunder %d',
                    A.shard, A.nshard, nheadbleed, bleedsum, worstbleed,
                    nhs, nhsover, hsoversum, worsthsover, nhsunder))
if worstbleed > 0 and not A.quiet then
  print(string.format('  worst head bleed %d bytes past ERR\'s exclusion: %s',
                      worstbleed, worstbleedwhat))
end
if worsthsover > 0 and not A.quiet then
  print(string.format('  worst headsusp over-claim %d bytes past the real damage: %s',
                      worsthsover, worsthsoverwhat))
end
if nskip > 0 and not A.quiet then
  -- NAMED, NEVER SILENT: a vector dropped for size is coverage this run did not have, and a
  -- summary that hides it reads as "everything passed".
  local i
  for i = 1, nskip do print('  SKIPPED ' .. skipped[i]) end
end
if nhard > 0 then
  local i
  for i = 1, math.min(nhard, 40) do print('  ' .. hard[i]) end
  if nhard > 40 then print(string.format('  ... and %d more', nhard - 40)) end
  os.exit(1)
end

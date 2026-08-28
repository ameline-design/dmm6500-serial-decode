-- sweep_plan.lua -- the offline twin of bench_matrix's plan suite: the SAME cells, on the Mac.
--
-- WHY IT EXISTS. The hardware soak runs about four laps a night; this runs a lap in seconds. On its
-- own that only buys volume. What it buys with the SAME PLAN is attribution: when the bench reports
-- a failure at iteration N, waveform V, rate B, running exactly that cell here answers the only
-- question that matters next -- does it fail without the analogue path? Fails here too, and it is
-- logic, deterministic, and debuggable at a breakpoint. Passes here, and the difference is the
-- hardware: the DAC, the cable, the digitiser, the capture phase the wait could only perturb.
--
-- THE PLAN IS READ, NOT RECOMPUTED. tools/soakplan.py --emit-lua writes it. mt19937.lua is proven to
-- match its Python twin word for word, so this file COULD draw its own rates -- and must not. The
-- plan is more than its draws: log-uniform placement in each gap, the ladder-edge substitution, the
-- standard-rate list read out of the TSP source. Two implementations of that is two things to get
-- subtly different, on a night when both look right.
--
-- THE SKIPPED SET IS PART OF THE PLAN, and leaving it out is not a small error. soakplan applies
-- --skip-vectors BEFORE the shuffle, so dropping two waveforms moves every remaining vector's index --
-- and that index keys the amplitude, the offset AND the wait for every cell. Every hardware lap skips
-- v95 and v96, so a twin lap emitted without them drove a different waveform in all 1677 cells:
-- v94 at 300 Bd was 20.000 Vpp at -8.220 V on the bench and 8.595 Vpp at +2.347 V here. Pass the
-- bench's own flag through:
--   python3 tools/plan_sweep.py --iteration 1 --skip-vectors v95,v96 --offsets 8
--
-- badcells IS A UNION OVER CAPTURE PHASES AND IS NOT COMPARABLE TO A BENCH LAP. With --offsets 8 a cell
-- is called bad if any ONE of eight phases failed, where the bench takes one capture and asks once.
-- Measured against soak lap 1: 65 cells fail here and passed on the bench, and not one of them fails at
-- all eight phases -- 41 fail at one of eight, 20 at two, none past five. Per CAPTURE this harness fails
-- 1.09 % against the bench's 2.80 %, so it is not harsher; the union is. Compare bad/points, or badall,
-- and never badcells.
--
-- WHAT THIS IS NOT. It is not the app. bench_matrix presses the real Capture button and reads the
-- real panel; this calls sdec directly, so it never exercises pick_fs's two-pass probe, autolock, or
-- anything the operator sees. In particular the bench digitises at pick_fs(the baud its own PROBE
-- measured) and this digitises at pick_fs(the baud that was COMMANDED); on soak lap 1 those disagreed
-- on 26 of 1385 cells, 1.9 %. It also judges more simply -- the decoded bytes must be a cyclic
-- substring of the payload, save for the loud mismatch allowance below which is bench_uart's own
-- number -- where bench_uart.judge_payload_v additionally weighs flag budgets, coverage floors and
-- head damage. So a pass here is the narrower claim "these samples decode to the right bytes", which is
-- exactly the claim needed to acquit or convict the analogue path.
--
-- WHERE THIS IS LAXER THAN THE BENCH, stated because the asymmetry runs both ways and the other
-- direction is easy to miss: a cell whose bytes are right and whose REPORTED BAUD is outside snaptol
-- fails on the bench and passes here, because classify() is only reached once the payload verdict is
-- already BAD. The bench also fails an INCONCLUSIVE cell on an exact vector where this counts it as
-- unjudgeable, and checks the reported format, which this does not.
--
--   lua tools/sweep_plan.lua --plan out/plans/plan-3.lua
--   lua tools/sweep_plan.lua --plan out/plans/plan-3.lua --hold      # zero-order hold instead
--   lua tools/sweep_plan.lua --plan out/plans/plan-3.lua --cell v44b:9600
--   python3 tools/plan_sweep.py --iteration 1 --offsets 8            # sharded, ratcheted, fresh plan
--
-- ONE CAPTURE PER CELL IS A COIN FLIP, which is what --offsets exists to fix. The generator plays the
-- arb on repeat, so the capture phase decides the answer: on v63 the reported rate is 19200 at 23 of
-- 48 start phases and 57600 at the other 25, with no state involved. A one-capture-per-cell table
-- therefore measures the draw, not the decoder, and two runs of the same plan disagree for no reason
-- worth reporting. --offsets N spreads N captures across the arb period -- the first is always the
-- plan's own wait, so --offsets 1 is exactly the historical behaviour -- and the summary reports both
-- the failing POINTS and the failing CELLS, which are different numbers as soon as N > 1.
--
-- Exit 1 if any point behaves worse than its class allows.

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')

local A = {plan = nil, hold = false, quiet = false, cell = nil, n = 20000,
           offsets = 1, shard = 1, nshard = 1}
local ai = 1
while arg ~= nil and arg[ai] ~= nil do
  local k, v = arg[ai], arg[ai + 1]
  if k == '--plan' then A.plan = v; ai = ai + 2
  elseif k == '--cell' then A.cell = v; ai = ai + 2
  elseif k == '--n' then A.n = tonumber(v); ai = ai + 2
  elseif k == '--offsets' then A.offsets = tonumber(v); ai = ai + 2
  elseif k == '--shard' then
    local a, b = string.find(v, '/')
    if a == nil then print('--shard wants k/n, got ' .. tostring(v)); os.exit(2) end
    A.shard = tonumber(string.sub(v, 1, a - 1))
    A.nshard = tonumber(string.sub(v, b + 1))
    ai = ai + 2
  elseif k == '--hold' then A.hold = true; ai = ai + 1
  elseif k == '--quiet' then A.quiet = true; ai = ai + 1
  else print('unknown argument: ' .. tostring(k)); os.exit(2) end
end
if A.plan == nil then
  print('REFUSING: --plan FILE is required. Generate one with:')
  print('  python3 tools/soakplan.py --emit-lua --iteration N > out/plans/plan-N.lua')
  os.exit(2)
end
-- BOUNDS-CHECKED, because an out-of-range shard selects NOTHING and a shard that judged nothing would
-- otherwise print a clean summary and exit 0 -- full coverage reported from a run that decoded nothing.
if A.nshard == nil or A.nshard < 1 or A.shard == nil or A.shard < 1 or A.shard > A.nshard then
  print(string.format('REFUSING: --shard %s/%s is out of range; shard must be 1..nshard',
                      tostring(A.shard), tostring(A.nshard)))
  os.exit(2)
end
if A.offsets == nil or A.offsets < 1 then
  print('REFUSING: --offsets must be at least 1'); os.exit(2)
end

local P = dofile(A.plan)

-- The app's own rate choice, so the twin digitises at the rate the panel would pick.
local function pick_fs(baud)
  local r = sdec.rates
  local i
  for i = 1, table.getn(r) do
    if r[i] >= baud * 8 then return r[i] end
  end
  return r[table.getn(r)]
end

-- ---------------------------------------------------------------------------
-- The wire: the arb file in volts, exactly the bytes the generator holds.
-- ---------------------------------------------------------------------------
-- CODEWORDS ARE CACHED, VOLTS ARE NOT. Amplitude and offset are drawn PER CELL now, so a cache keyed
-- on the vector alone would hand every rate the first cell's scaling and quietly decode a waveform the
-- generator never played.
local cwcache = {}
local function wire(v, amp, ofst)
  if cwcache[v.id] == nil then
    local cw, n = GEN_READ('out/vectors/' .. v.id .. '.bin')
    cwcache[v.id] = {cw = cw, n = n}
  end
  local c = cwcache[v.id]
  -- fsv is AMP/2: the file's +32767 is +AMP/2.
  local fsv = (amp or v.amp) / 2
  local o = ofst
  if o == nil then o = v.ofst end
  local volts, i = {}, nil
  for i = 1, c.n do volts[i] = GEN_VOLTS(c.cw[i], fsv, o) end
  return volts, c.n
end

-- One capture of the LOOPING arb, digitised independently of it.
--
-- LINEAR BETWEEN ARB POINTS BY DEFAULT, not a step. A DAC feeding a reconstruction filter does not
-- present a staircase, and the scope measured clean 0/3.26 V edges with real slope for the app's
-- sub-sample interpolation to work on. --hold is the harsher model, swept as a robustness check.
local function capture(v, arb_fs, fs, off, n, amp, ofst)
  local wv, na = wire(v, amp, ofst)
  local step = arb_fs / fs
  local out, i = {}, nil
  local x = off
  for i = 1, n do
    -- Wrapped, because the generator plays the file on repeat and a capture straddles the seam.
    local xm = math.mod(x, na)
    local i0 = math.floor(xm)
    local frac = xm - i0
    local a = wv[i0 + 1]
    if a == nil then a = wv[1] end
    if A.hold or frac == 0 then
      out[i] = a
    else
      local b = wv[math.mod(i0 + 1, na) + 1]
      if b == nil then b = a end
      out[i] = a + (b - a) * frac
    end
    x = x + step
  end
  return out, n
end

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.widths_any = false
end

local function decode(rd, n, fs)
  clearforce()
  sdec.acq_fs, sdec.fs = fs, fs
  sdec.sig_levels(rd, n)
  sdec.sig_edges(rd, n)
  sdec.sig_idle(rd, n)
  local ok, why = pcall(function() return sdec.decode_from(rd, n) end)
  if not ok then return false, tostring(why), nil end
  return true, nil, sdec.res
end

local HEX = '0123456789ABCDEF'
local function tohex(r)
  if r == nil or r.nf == nil or r.nf < 1 then return '' end
  local s, i = {}, nil
  for i = 1, r.nf do
    local b = r.vals[i] or 0
    s[i] = string.sub(HEX, math.floor(b / 16) + 1, math.floor(b / 16) + 1) ..
           string.sub(HEX, math.mod(b, 16) + 1, math.mod(b, 16) + 1)
  end
  return table.concat(s)
end

-- CYCLIC, because the arb repeats and a capture starts anywhere in it.
--
-- THE HEAD SKIP IS THE APP'S OWN AND NOT A CONSTANT, which is the difference between measuring the
-- decoder and measuring this file. A capture that opens mid-frame has a legitimately misaligned head,
-- and the app says how long it is: ua_head_bad, floored at ua_edge_frames exactly as ua_err_count
-- does, so what is judged here is the shipped ERR promise -- every byte ERR does not count is a byte
-- you can trust -- rather than a rule invented here. A FIXED 12-byte skip judges the tail of a longer
-- damaged head as payload and reports byte-exact decodes as wrong: measured on v77 at 19200, head_bad
-- reads 34 and 16 at two capture phases of eight and the bytes are correct from 46 and 28, which made
-- that vector fail at all 43 rates for a fault entirely in this function.
--
-- PAST THE APP'S OWN BOUND A BOUNDED SHIFT IS COUNTED, NOT FAILED. ua_head_bad narrows headsusp to the
-- last FLAGGED frame deliberately, so where the tail of a suspect head frames cleanly those bytes are
-- wrong and uncounted -- open issue #49's family, which tools/sweep_startphase.lua also counts as
-- headbleed rather than failing. A run matching at NO shift inside the bound is the real failure,
-- because nothing about a capture boundary explains it.
-- A loud VECTOR'S MISMATCH ALLOWANCE, which is the bench's own and not this file's.
--
-- THE NUMBERS ARE bench_uart.py's JP_LOUD_MISMATCH_FRAC and JP_LOUD_MISMATCH_FLOOR, and that file
-- records why they are these numbers: in 8N1 a data sample that crosses into the neighbouring cell
-- yields a wrong byte with framing intact and NO parity to catch it, so nothing is flagged and a jitter
-- vector cannot be held to zero. bench_uart measured j20 losing 1-5 bytes in 256 at 172800-240959 Bd.
-- tools/test_judge_v.py runs loud_budget under lua and compares it with bench_uart's expression at ten
-- body sizes, so the copy cannot drift in its constants or in its arithmetic.
--
-- WHAT IT IS WORTH. Holding a loud vector to byte-exactness where the bench allows 3 % is how a harness
-- invents failures: on soak lap 1 that accounts for 11 of the 73 cells this twin failed and the bench
-- passed -- seven j20 cells the bench logged as "6 mismatched of 6 allowed" and the like, and four v47.
-- The app was right in all eleven.
--
-- EXACT VECTORS GET ZERO. A clean vector losing one byte is still a defect, and this allowance may never
-- reach one -- which is why judge() takes the CLASS and not a number.
--
-- AND EVERY BYTE IT FORGIVES IS COUNTED, in `loudmiss`. A tolerance that moves no counter cannot be
-- bounded, so a regression that started losing bytes on every loud vector would read as an unchanged
-- run -- the same trap `loudquiet` exists to close.
local LOUD_MISS_FRAC, LOUD_MISS_FLOOR = 0.03, 2
local function loud_budget(nbody)
  local b = math.ceil(LOUD_MISS_FRAC * nbody)
  if b < LOUD_MISS_FLOOR then b = LOUD_MISS_FLOOR end
  return b
end

-- The fewest byte mismatches `body` has against any cyclic alignment of `want`. -> (mismatches, offset)
--
-- EVERY ALIGNMENT IS SCORED, not searched for, exactly as bench_uart.judge_payload_v does and for the
-- reason recorded there: find() is all-or-nothing, so one jitter-flipped byte anywhere loses the
-- alignment and the capture is called silently wrong. The loud payloads are 9 to 18 bytes, so there
-- are at most 18 alignments and trying all of them is exact and free.
local function best_align(body, want)
  local nb, nw = string.len(body) / 2, string.len(want) / 2
  local hay = string.rep(want, math.ceil((string.len(body) + string.len(want))
                                         / string.len(want)) + 1)
  local bestm, besto = nil, 0
  local a
  for a = 0, nw - 1 do
    local mism, j = 0, nil
    for j = 0, nb - 1 do
      if string.sub(body, j * 2 + 1, j * 2 + 2) ~= string.sub(hay, (a + j) * 2 + 1, (a + j) * 2 + 2)
      then
        mism = mism + 1
        -- Nothing more to learn once this alignment is already worse than the best.
        if bestm ~= nil and mism >= bestm then break end
      end
    end
    if bestm == nil or mism < bestm then bestm, besto = mism, a end
    if bestm == 0 then break end
  end
  return bestm or 0, besto
end

local MINJUDGE, MAXSHIFT = 8, 40
-- `loud` IS THE CLASS, NOT A BUDGET, and the budget is sized INSIDE the loop from the body actually
-- being compared at that shift. Sizing it once outside would hand a 40-byte shift the allowance its
-- unshifted body earned -- 3 % of forty bytes is up to two mismatches the shorter body has not paid
-- for -- and a tolerance that grows as the evidence shrinks is the wrong way round.
--
-- IT IS STILL 3 % OF A LONGER BODY THAN THE BENCH JUDGES, and the difference is stated rather than
-- corrected: bench_uart trims head_damage, then JP_HEADSKIP = 12 and JP_TAILSKIP = 1 on top, where this
-- trims max(ua_head_bad, ua_edge_frames) and no tail. So this body runs up to 13 bytes longer and the
-- allowance can be one byte larger. The RATE is the same 3 %, which is the rule bench_uart states, and
-- every byte it forgives is counted in loudmiss where the difference stays bounded and visible.
local function judge(got, want, skip0, loud)
  if want == '' then return nil, 'no expected payload' end
  if got == '' then return false, 'no bytes decoded' end
  local nb = string.len(got) / 2
  -- REPEATED TO COVER THE CAPTURE, not merely doubled. The arb loops, so a 240-byte window of a
  -- 13-byte payload is eighteen passes of it; searching a doubled 13 bytes can never contain that and
  -- reports every correct decode as wrong. Enough copies to hold the body plus one full period, so a
  -- match starting at any offset has somewhere to finish.
  local reps = math.ceil((string.len(got) + string.len(want)) / string.len(want)) + 1
  local hay = string.rep(want, reps)
  local sh
  for sh = 0, MAXSHIFT do
    local skip = skip0 + sh
    if nb - skip < MINJUDGE then
      if sh == 0 then
        return nil, string.format('too short to judge (%d B, %d-byte head)', nb, skip0)
      end
      break
    end
    local body = string.sub(got, skip * 2 + 1)
    local at = string.find(hay, body, 1, true)
    if at ~= nil then
      return true, string.format('%d B cyclic-exact at offset %d, head %d+%d',
                                 nb - skip,
                                 math.mod(math.floor((at - 1) / 2), string.len(want) / 2),
                                 skip0, sh), sh, 0
    end
    if loud then
      local mbudget = loud_budget(nb - skip)
      local mism, at2 = best_align(body, want)
      if mism <= mbudget then
        return true, string.format('%d B at offset %d with %d of %d allowed mismatch(es), head %d+%d',
                                   nb - skip, at2, mism, mbudget, skip0, sh), sh, mism
      end
    end
  end
  if loud and nb - skip0 >= MINJUDGE then
    local mism = best_align(string.sub(got, skip0 * 2 + 1), want)
    return false, string.format('%d B miss the payload by %d byte(s) at the best alignment past a '
                                .. '%d-byte head, budget %d',
                                nb - skip0, mism, skip0, loud_budget(nb - skip0))
  end
  return false, string.format('%d B do NOT appear in the payload past a %d-byte head, at any of %d '
                              .. 'further shifts', nb - skip0, skip0, MAXSHIFT)
end

-- The head bound the app itself would exclude from ERR: ua_head_bad, never below ua_edge_frames.
local function head_skip(r)
  if r == nil then return 0 end
  local hb = sdec.ua_head_bad(r, r.headsusp) or 0
  local ef = sdec.ua_edge_frames or 3
  if ef > hb then hb = ef end
  return hb
end

-- THE SOAK'S OWN FAILURE TAXONOMY, so an offline row can be set beside a hardware one without
-- re-reading either. The three classes are not interchangeable and the distinction is the whole
-- diagnostic value: a wrong RATE is issue #46, right rate with wrong BYTES is #125, and NOBYTES is an
-- honest refusal. A bare BAD count merges all three and hides which one moved.
local SNAP = sdec.snaptol or 0.02

-- Whether `b` is a rate the panel would present as STANDARD. sig_snap returns the ladder entry
-- itself when it snaps, so an exact compare is right and a tolerance here would fold in the
-- near-misses this is meant to separate from.
local function is_std(b)
  if b == nil then return false end
  local i
  local nb = table.getn(sdec.stdbaud)
  for i = 1, nb do
    if math.abs(b / sdec.stdbaud[i] - 1) <= 1e-6 then return true end
  end
  return false
end

-- WHICH ROUTE A RATE MISREPORT CAME DOWN. Issue #46 is one counter over three different defects with
-- three different fixes, and merging them is how a 14.5 % share sat uncharacterised: the counter can
-- only say the rate was wrong, not which mechanism made it wrong.
--
-- Split on reported/commanded, which is the one number available at every point without reaching into
-- arbitration state. The bands are measured on the 124 hardware misreports, not chosen:
local function rate_route(rb, baud)
  local a = rb / baud
  if a < 1 then a = 1 / a end
  -- 46b -- ua_best_end let a SNAPPED HARMONIC win on score alone, entered when the width fit lands on
  -- a non-standard rate so both guards switch off. Harmonics are 2x and up and their reciprocals,
  -- which is why this band starts at 1.8 rather than at a fraction of a per cent: 11374->57600,
  -- 5810->28800, 3572->14400 are all near-exact doublings or better.
  if a >= 1.8 then return 'r46b' end
  -- route 1 -- sig_fit's SECOND FIXED POINT. 0.91 Tb is stable once enough 9-bit runs corroborate it,
  -- so reported lands ~1.10x commanded; the hardware cases sit at 1.09-1.11.
  if a >= 1.05 then return 'rfit1' end
  -- cluster C -- the fit drifts into a NEIGHBOURING STANDARD RATE'S basin and then snaps to it, so
  -- reported is on the ladder while commanded is past snaptol away. That is what makes it interesting:
  -- an accurate fit cannot reach a standard rate that far off, so the drift came first. This is the
  -- shape a real user meets, because drawn rates near the ladder are where equipment sits.
  --
  -- THE BAND IS (snaptol, 1.05), NOT the 2.4-2.7 % the hardware cases happen to sit at. Those six are
  -- observations inside this band, not its definition, and writing the narrower number here would claim
  -- an attribution the test does not make -- a 4 % standard-rate miss also lands in rstdC and is not
  -- known to share a mechanism with them. The ratio is printed on every failure row so the spread
  -- inside the band stays visible rather than being asserted away.
  if is_std(rb) then return 'rstdC' end
  -- NOT FORCED INTO A BAND IT DOES NOT FIT. A misreport just outside snaptol that is NOT on the ladder
  -- is none of the three, and bucketing it as the nearest one would put invented evidence under a
  -- defect's name -- the error this harness has already made once by fixing its head trim.
  return 'rother'
end

local function classify(ran, r, rb, baud)
  if not ran then return 'raised' end
  if r == nil or (r.nf or 0) < 1 then return 'nobytes' end
  if rb == nil then return 'norate' end
  if math.abs(rb / baud - 1) > SNAP then return 'rate' end
  return 'bytes'
end

-- ---------------------------------------------------------------------------
local nok, nbad, nskip = 0, 0, 0
local ncell, nbadcell = 0, 0
-- HEAD BLEED IS COUNTED, NEVER SILENT: it is the number of points that needed a shift PAST the app's
-- own head bound before the bytes matched, i.e. bytes the panel presents as trustworthy and are not.
-- Counting it here is what stops the judge's tolerance from quietly absorbing a real defect.
local nbleed, worstbleed = 0, 0
-- loud VECTORS THAT DECLINED, which is a pass and must still be visible. Not part of `bad`: see the
-- verdict block for why counting a correct refusal as a failure is the harness lying, and why leaving it
-- uncounted lets total byte suppression hide.
local nloudquiet = 0
-- EVERY BYTE THE loud MISMATCH BUDGET FORGAVE, and the worst single point. Same reasoning as nbleed:
-- an allowance the bench has must be here too, and an allowance nobody counts is one nobody checks.
local nloudmiss, worstloudmiss = 0, 0
-- CELLS THAT FAILED AT EVERY OFFSET, which is the only cell-level number a ONE-CAPTURE hardware lap can
-- be set beside. `badcells` is a UNION over A.offsets capture phases, so it rises with the offset count
-- for a fixed defect: measured against soak lap 1, 65 cells fail here and passed on the bench, and not
-- one of them fails at all eight phases -- 41 fail at one of eight and 20 at two. Compared against a lap
-- that took one capture per cell, `badcells` at 8 offsets reads as 1.8x the bench's failure rate while
-- the PER-CAPTURE rate is 0.39x it. Both numbers are honest; only one of them is comparable.
local nbadall = 0
-- The four r* entries are SUBDIVISIONS OF `rate`, not siblings of it: rate stays the total so the
-- ratchet keyed on it keeps meaning what it measured, and the routes sum to it.
local CLS = {'raised', 'nobytes', 'norate', 'rate', 'bytes',
             'r46b', 'rfit1', 'rstdC', 'rother'}
local cls = {}
do local i; for i = 1, table.getn(CLS) do cls[CLS[i]] = 0 end end
print(string.format('=== OFFLINE PLAN iteration %d -- %d vectors x %d rates x %d offset(s)%s ===',
                    P.iteration, table.getn(P.vectors), table.getn(P.rates), A.offsets,
                    A.hold and ' (zero-order hold)' or ''))
-- THE SKIPPED SET, PRINTED, because it is half of the plan's identity and the half a reader assumes.
-- soakplan applies it BEFORE the shuffle, so it moves every vector's vi and therefore every cell's
-- amplitude, offset and wait: a twin lap run without the bench's own skip set drives a different
-- waveform in all 1677 cells. A plan file with no `skipped` field is itself the warning -- nothing in
-- it says which vectors the draw covered, so it cannot be matched to a lap that skipped anything.
if P.skipped == nil then
  print('    skipped: UNRECORDED -- this plan predates --skip-vectors. If the bench lap skipped a '
        .. 'vector, every cell here has the wrong amplitude, offset and wait.')
elseif table.getn(P.skipped) > 0 then
  print('    skipped, and therefore the reason every vi moved: '
        .. table.concat(P.skipped, ' '))
else
  print('    skipped: nothing -- comparable only to a bench lap that also skipped nothing')
end
local nrate = table.getn(P.rates)
local vi
for vi = 1, table.getn(P.vectors) do
  local v = P.vectors[vi]
  local t0 = os.clock()
  local vbad, vcell = 0, 0
  local ri
  for ri = 1, nrate do
    local baud, kind = P.rates[ri][1], P.rates[ri][2]
    local sel = (A.cell == nil) or (A.cell == v.id .. ':' .. baud)
    -- SHARDED BY (VECTOR x RATE), not by vector: v96 renders 3.4 M points and v41 2.0 k, so sharding
    -- by vector alone leaves one core doing minutes of work while the rest idle.
    local unit = (vi - 1) * nrate + ri
    if sel and math.mod(unit - 1, A.nshard) == A.shard - 1 then
      local arb_fs = baud * v.spb
      local fs = pick_fs(baud)
      local waits = P.waits[vi] or {}
      local off0 = math.mod((waits[ri] or 0) * arb_fs, math.max(1, v.npts))
      -- The cell's OWN amplitude and offset. Absent from an older plan file, in which case the
      -- vector's reference values stand in -- so a stale plan degrades to the previous behaviour
      -- rather than silently mixing one cell's scaling into another's.
      -- BOTH AXES OR NEITHER. Falling back per axis would pair a drawn amplitude with the reference
      -- offset and decode a geometry the generator never played, for a reason that looks like neither
      -- hardware nor app.
      local amps = P.amps and P.amps[vi] or {}
      local ofsts = P.ofsts and P.ofsts[vi] or {}
      local camp, cofst = amps[ri], ofsts[ri]
      if (camp == nil) ~= (cofst == nil) then
        print(string.format('REFUSING %s at %d Bd: the plan carries one of amp/ofst and not the other',
                            v.id, baud))
        os.exit(1)
      end
      ncell = ncell + 1; vcell = vcell + 1
      local cellbad = 0
      local period = math.max(1, v.npts)
      local oi
      for oi = 0, A.offsets - 1 do
        -- OFFSET 0 IS THE PLAN'S OWN WAIT, so --offsets 1 reproduces the historical cell exactly and
        -- a changed number can only come from the extra captures.
        local off = math.mod(off0 + oi * period / A.offsets, period)
        local rd, n = capture(v, arb_fs, fs, off, A.n, camp, cofst)
        local ran, why, r = decode(rd, n, fs)
        local rb = sdec.baud
        local good, det, bleed, lmiss
        if not ran then
          good, det = false, 'RAISED ' .. tostring(why)
        else
          local hs = head_skip(r)
          local hx = tohex(r)
          -- THE CLASS TRAVELS, NOT A NUMBER. judge() sizes the allowance from the body it is actually
          -- comparing at each shift, which a value computed here could not do.
          local loud = v.class == 'loud'
          -- EITHER legitimate reading passes; v.hex2 is set only where the wire genuinely supports
          -- two framings and the app is right whichever it picks.
          good, det, bleed, lmiss = judge(hx, v.hex, hs, loud)
          if good ~= true and v.hex2 ~= nil and v.hex2 ~= '' then
            local g2, d2, b2, m2 = judge(hx, v.hex2, hs, loud)
            if g2 == true then good, det, bleed, lmiss = g2, d2 .. ' (alternate framing)', b2, m2 end
          end
          if det == nil then det = '' end
          if bleed ~= nil and bleed > 0 then
            nbleed = nbleed + 1
            if bleed > worstbleed then worstbleed = bleed end
          end
          if good == true and lmiss ~= nil and lmiss > 0 then
            nloudmiss = nloudmiss + lmiss
            if lmiss > worstloudmiss then worstloudmiss = lmiss end
          end
        end
        -- A point that cannot be judged is neither a pass nor a failure, and is counted apart so a
        -- clean-looking run cannot be clean because nothing was checked.
        local verdict
        if good == nil then
          verdict = 'skip'; nskip = nskip + 1
        elseif good then
          verdict = 'ok'; nok = nok + 1
        else
          -- 'loud' vectors may fail; they may not be SILENTLY WRONG. Silent means bytes came back AND
          -- NOT ONE FRAME WAS FLAGGED: a decode that raised a flag has told the operator something is
          -- wrong, which is the loud half of the contract. Counting any non-empty decode as silent --
          -- as a bare nf > 0 does -- fails a vector for reporting its own trouble correctly.
          local silent = false
          if r ~= nil and (r.nf or 0) > 0 then
            silent = true
            local k
            for k = 1, r.nf do
              if r.errs ~= nil and r.errs[k] ~= nil then silent = false end
            end
          end
          -- A DECLINE IS THE DOCUMENTED PASS FOR A loud VECTOR, not a failure: docs/BENCH.md states
          -- "Declining, or failing with flags raised, is a pass", and v47's spikes stack to 9.3 V so it
          -- decodes nothing at many rates. Refusing an unreadable signal is the right answer, and
          -- counting it BAD is a harness inventing failures -- 81 a lap, measured.
          --
          -- WHAT WAS ACTUALLY WRONG IS THAT IT MOVED NO COUNTER. A pass that increments nothing cannot
          -- be bounded, so a regression suppressing every byte on every loud vector reads as a
          -- completely unchanged run. `loudquiet` counts it and plan_sweep.py ratchets it, which bounds
          -- the case without calling a correct refusal a defect.
          -- `ran` IS REQUIRED FOR THE loud PASS, and this is the sharp edge. A decode that RAISED arrives
          -- here with ran = false and r = nil, so `silent` is false and the loud contract would grant it a
          -- pass -- leaving cls.raised at zero, because classify() is only reached down the BAD path. A
          -- raise is the one thing that gates unconditionally at every placement, so hiding it behind a
          -- waveform's licence to fail is the worst reading this file could produce.
          local spoke = r ~= nil and (r.nf or 0) > 0
          if v.class == 'loud' and ran and not silent then
            verdict = 'ok'; nok = nok + 1
            if not spoke then nloudquiet = nloudquiet + 1 end
          else
            verdict = 'BAD'; nbad = nbad + 1; vbad = vbad + 1; cellbad = cellbad + 1
            local c = classify(ran, r, rb, baud)
            cls[c] = cls[c] + 1
            -- THE ROUTE GOES IN THE ROW TOO. A count says #46 moved; only the row says which of the
            -- three mechanisms moved it, and that is the difference between a number and a lead.
            local route = ''
            if c == 'rate' then
              local rt = rate_route(rb, baud)
              cls[rt] = cls[rt] + 1
              route = string.format(' %s x%.3f', rt, rb / baud)
            end
            -- ROUNDED, because sdec.baud is a measurement: 379.00138669341982 in a failure row is
            -- eighteen digits of noise over the one fact that matters, which is that it read 379.
            det = string.format('[%s%s, read %s Bd] %s', c, route,
                                rb ~= nil and string.format('%.0f', rb) or 'nil', det)
          end
        end
        if not A.quiet or verdict == 'BAD' then
          print(string.format('  %-6s %7d Bd %-5s %-5s %-5s fs %7d  %5.2f sa/bit  off %8.1f  %s',
                              v.id, baud, kind, v.class, verdict, fs, fs / baud, off, det))
        end
      end
      if cellbad > 0 then nbadcell = nbadcell + 1 end
      -- A CELL THAT FAILED AT EVERY PHASE IT WAS OFFERED. At --offsets 1 this equals badcells, which is
      -- correct: with one capture there is no distinction to draw.
      if cellbad >= A.offsets then nbadall = nbadall + 1 end
    end
  end
  if not A.quiet and vcell > 0 then
    print(string.format('  %-6s %s: %d cell(s) in %.2f s, %d point(s) not as expected',
                        v.id, v.class, vcell, os.clock() - t0, vbad))
  end
end

-- MACHINE-READABLE FIRST, so tools/plan_sweep.py totals the shards without parsing prose. POINTS and
-- CELLS are both reported because they answer different questions: points is the rate at which a
-- capture of this plan comes back wrong, cells is how much of the plan is affected at all.
--
-- THREE CELL NUMBERS, NOT ONE, and which of them to quote depends on what is being compared:
--   badcells  a UNION over the offsets -- at least one phase failed. Grows with --offsets for a fixed
--             defect, so it must NEVER be set beside a hardware lap's failing-cell count.
--   badall    the INTERSECTION -- every phase failed. The phase-independent defects.
--   bad/points the per-CAPTURE rate, which is the one directly comparable to a bench lap that took one
--             capture per cell.
print(string.format('\nPLAN %d/%d iteration %d: cells %d badcells %d badall %d points %d ok %d bad %d '
                    .. 'skip %d '
                    .. 'raised %d nobytes %d norate %d rate %d bytes %d bleed %d bleedworst %d '
                    .. 'r46b %d rfit1 %d rstdC %d rother %d loudquiet %d loudmiss %d loudmissworst %d',
                    A.shard, A.nshard, P.iteration, ncell, nbadcell, nbadall, nok + nbad + nskip,
                    nok, nbad, nskip,
                    cls.raised, cls.nobytes, cls.norate, cls.rate, cls.bytes, nbleed, worstbleed,
                    cls.r46b, cls.rfit1, cls.rstdC, cls.rother, nloudquiet,
                    nloudmiss, worstloudmiss))
-- THE ROUTES MUST SUM TO `rate`, and this is checked rather than assumed: rate_route returns exactly
-- one of the four for every rate point, so a mismatch means a point was counted twice or lost, and a
-- subdivision that does not reconcile with its total is worse than no subdivision at all.
do
  local rsum = cls.r46b + cls.rfit1 + cls.rstdC + cls.rother
  if rsum ~= cls.rate then
    -- EXIT 2, NOT 1. This check runs AFTER the summary line, and 1 is the code a shard uses for a
    -- known failure -- so exiting 1 here would print a reconciled-looking summary and be totalled as
    -- an ordinary bad lap. 2 is what tools/plan_sweep.py refuses to trust the numbers of.
    print(string.format('REFUSING: the %d rate point(s) split into %d route(s) -- they must reconcile',
                        cls.rate, rsum))
    os.exit(2)
  end
end
print(string.format('%d ok, %d BAD, %d unjudgeable of %d point(s) over %d cell(s), %d cell(s) '
                    .. 'affected at any phase and %d at every phase, %d head bleed (worst %d), '
                    .. '%d byte(s) inside the loud budget (worst %d)',
                    nok, nbad, nskip, nok + nbad + nskip, ncell, nbadcell, nbadall,
                    nbleed, worstbleed, nloudmiss, worstloudmiss))
-- THE COMPARABLE FIGURE, SPELT OUT, because getting this wrong is how 73 harness failures were filed
-- against the app. A bench lap takes ONE capture per cell; this takes A.offsets of them and unions.
if nok + nbad > 0 then
  print(string.format('per-CAPTURE failure rate %.2f %% (%d of %d) -- this, not the %d affected '
                      .. 'cell(s), is what a one-capture bench lap can be compared with',
                      100 * nbad / (nok + nbad + nskip), nbad, nok + nbad + nskip, nbadcell))
end
if nok + nbad == 0 then
  print('REFUSING to report success: nothing was judged at all.')
  os.exit(1)
end
os.exit(nbad > 0 and 1 or 0)

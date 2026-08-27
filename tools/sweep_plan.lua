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
-- WHAT THIS IS NOT. It is not the app. bench_matrix presses the real Capture button and reads the
-- real panel; this calls sdec directly, so it never exercises pick_fs's two-pass probe, autolock, or
-- anything the operator sees. It also judges more simply -- the decoded bytes must be a cyclic
-- substring of the payload -- where bench_uart.judge_payload weighs flag budgets and head damage. So
-- a pass here is the narrower claim "these samples decode to the right bytes", which is exactly the
-- claim needed to acquit or convict the analogue path.
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
local MINJUDGE, MAXSHIFT = 8, 40
local function judge(got, want, skip0)
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
                                 skip0, sh), sh
    end
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
local CLS = {'raised', 'nobytes', 'norate', 'rate', 'bytes'}
local cls = {}
do local i; for i = 1, table.getn(CLS) do cls[CLS[i]] = 0 end end
print(string.format('=== OFFLINE PLAN iteration %d -- %d vectors x %d rates x %d offset(s)%s ===',
                    P.iteration, table.getn(P.vectors), table.getn(P.rates), A.offsets,
                    A.hold and ' (zero-order hold)' or ''))
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
        local good, det, bleed
        if not ran then
          good, det = false, 'RAISED ' .. tostring(why)
        else
          local hs = head_skip(r)
          -- EITHER legitimate reading passes; v.hex2 is set only where the wire genuinely supports
          -- two framings and the app is right whichever it picks.
          good, det, bleed = judge(tohex(r), v.hex, hs)
          if good ~= true and v.hex2 ~= nil and v.hex2 ~= '' then
            local g2, d2, b2 = judge(tohex(r), v.hex2, hs)
            if g2 == true then good, det, bleed = g2, d2 .. ' (alternate framing)', b2 end
          end
          if det == nil then det = '' end
          if bleed ~= nil and bleed > 0 then
            nbleed = nbleed + 1
            if bleed > worstbleed then worstbleed = bleed end
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
          if v.class == 'loud' and not silent then
            verdict = 'ok'; nok = nok + 1
          else
            verdict = 'BAD'; nbad = nbad + 1; vbad = vbad + 1; cellbad = cellbad + 1
            local c = classify(ran, r, rb, baud)
            cls[c] = cls[c] + 1
            -- ROUNDED, because sdec.baud is a measurement: 379.00138669341982 in a failure row is
            -- eighteen digits of noise over the one fact that matters, which is that it read 379.
            det = string.format('[%s, read %s Bd] %s', c,
                                rb ~= nil and string.format('%.0f', rb) or 'nil', det)
          end
        end
        if not A.quiet or verdict == 'BAD' then
          print(string.format('  %-6s %7d Bd %-5s %-5s %-5s fs %7d  %5.2f sa/bit  off %8.1f  %s',
                              v.id, baud, kind, v.class, verdict, fs, fs / baud, off, det))
        end
      end
      if cellbad > 0 then nbadcell = nbadcell + 1 end
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
print(string.format('\nPLAN %d/%d iteration %d: cells %d badcells %d points %d ok %d bad %d skip %d '
                    .. 'raised %d nobytes %d norate %d rate %d bytes %d bleed %d bleedworst %d',
                    A.shard, A.nshard, P.iteration, ncell, nbadcell, nok + nbad + nskip,
                    nok, nbad, nskip,
                    cls.raised, cls.nobytes, cls.norate, cls.rate, cls.bytes, nbleed, worstbleed))
print(string.format('%d ok, %d BAD, %d unjudgeable of %d point(s) over %d cell(s), %d cell(s) '
                    .. 'affected, %d head bleed (worst %d)',
                    nok, nbad, nskip, nok + nbad + nskip, ncell, nbadcell, nbleed, worstbleed))
if nok + nbad == 0 then
  print('REFUSING to report success: nothing was judged at all.')
  os.exit(1)
end
os.exit(nbad > 0 and 1 or 0)

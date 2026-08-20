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
--
-- Exit 1 if any cell behaves worse than its class allows.

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')

local A = {plan = nil, hold = false, quiet = false, cell = nil, n = 20000}
local ai = 1
while arg ~= nil and arg[ai] ~= nil do
  local k, v = arg[ai], arg[ai + 1]
  if k == '--plan' then A.plan = v; ai = ai + 2
  elseif k == '--cell' then A.cell = v; ai = ai + 2
  elseif k == '--n' then A.n = tonumber(v); ai = ai + 2
  elseif k == '--hold' then A.hold = true; ai = ai + 1
  elseif k == '--quiet' then A.quiet = true; ai = ai + 1
  else print('unknown argument: ' .. tostring(k)); os.exit(2) end
end
if A.plan == nil then
  print('REFUSING: --plan FILE is required. Generate one with:')
  print('  python3 tools/soakplan.py --emit-lua --iteration N > out/plans/plan-N.lua')
  os.exit(2)
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
local wirecache = {}
local function wire(v)
  if wirecache[v.id] == nil then
    local cw, n = GEN_READ('out/vectors/' .. v.id .. '.bin')
    local volts, i = {}, nil
    -- fsv is AMP/2: the file's +32767 is +AMP/2. Four of the 41 are not 10 Vpp, so this comes from
    -- the plan rather than from a constant.
    local fsv = v.amp / 2
    for i = 1, n do volts[i] = GEN_VOLTS(cw[i], fsv, v.ofst) end
    wirecache[v.id] = {v = volts, n = n}
  end
  local c = wirecache[v.id]
  return c.v, c.n
end

-- One capture of the LOOPING arb, digitised independently of it.
--
-- LINEAR BETWEEN ARB POINTS BY DEFAULT, not a step. A DAC feeding a reconstruction filter does not
-- present a staircase, and the scope measured clean 0/3.26 V edges with real slope for the app's
-- sub-sample interpolation to work on. --hold is the harsher model, swept as a robustness check.
local function capture(v, arb_fs, fs, off, n)
  local wv, na = wire(v)
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

-- CYCLIC, because the arb repeats and a capture starts anywhere in it. HEADSKIP mirrors
-- bench_uart's: the first bytes of a capture that began mid-frame are legitimately misaligned, and
-- judging them would fail correct decodes.
local HEADSKIP, MINJUDGE = 12, 8
local function judge(got, want)
  if want == '' then return nil, 'no expected payload' end
  if got == '' then return false, 'no bytes decoded' end
  local skip = HEADSKIP * 2
  if string.len(got) <= skip + MINJUDGE * 2 then skip = 0 end
  local body = string.sub(got, skip + 1)
  if string.len(body) < MINJUDGE * 2 then
    return nil, string.format('too short to judge (%d B)', string.len(got) / 2)
  end
  -- REPEATED TO COVER THE CAPTURE, not merely doubled. The arb loops, so a 240-byte window of a
  -- 13-byte payload is eighteen passes of it; searching a doubled 13 bytes can never contain that and
  -- reports every correct decode as wrong. Enough copies to hold the body plus one full period, so a
  -- match starting at any offset has somewhere to finish.
  local reps = math.ceil((string.len(body) + string.len(want)) / string.len(want))
  local at = string.find(string.rep(want, reps), body, 1, true)
  if at ~= nil then
    return true, string.format('%d B cyclic-exact at offset %d',
                               string.len(body) / 2, math.mod(math.floor((at - 1) / 2),
                                                              string.len(want) / 2))
  end
  return false, string.format('%d B do NOT appear in the payload', string.len(body) / 2)
end

-- ---------------------------------------------------------------------------
local nok, nbad, nskip, nfail = 0, 0, 0, 0
print(string.format('=== OFFLINE PLAN iteration %d -- %d vectors x %d rates%s ===',
                    P.iteration, table.getn(P.vectors), table.getn(P.rates),
                    A.hold and ' (zero-order hold)' or ''))
local vi
for vi = 1, table.getn(P.vectors) do
  local v = P.vectors[vi]
  local t0 = os.clock()
  local vbad = 0
  local ri
  for ri = 1, table.getn(P.rates) do
    local baud, kind = P.rates[ri][1], P.rates[ri][2]
    local sel = (A.cell == nil) or (A.cell == v.id .. ':' .. baud)
    if sel then
      local arb_fs = baud * v.spb
      local fs = pick_fs(baud)
      local waits = P.waits[vi] or {}
      local off = math.mod((waits[ri] or 0) * arb_fs, math.max(1, v.npts))
      local rd, n = capture(v, arb_fs, fs, off, A.n)
      local ran, why, r = decode(rd, n, fs)
      local good, det
      if not ran then
        good, det = false, 'RAISED ' .. tostring(why)
      else
        good, det = judge(tohex(r), v.hex)
        if det == nil then det = '' end
      end
      -- A cell that cannot be judged is neither a pass nor a failure, and is counted apart so a
      -- clean-looking run cannot be clean because nothing was checked.
      local verdict
      if good == nil then
        verdict = 'skip'; nskip = nskip + 1
      elseif good then
        verdict = 'ok'; nok = nok + 1
      else
        -- 'loud' vectors may fail; they may not be SILENTLY WRONG. Silent means bytes came back AND
        -- NOT ONE FRAME WAS FLAGGED: a decode that raised a flag has told the operator something is
        -- wrong, which is the loud half of the contract. Counting any non-empty decode as silent -- as
        -- a bare nf > 0 does -- fails a vector for reporting its own trouble correctly.
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
          verdict = 'BAD'; nbad = nbad + 1; vbad = vbad + 1
        end
      end
      if not A.quiet or verdict == 'BAD' then
        print(string.format('  %-6s %7d Bd %-5s %-5s %-5s fs %7d  %5.2f sa/bit  off %8.1f  %s',
                            v.id, baud, kind, v.class, verdict, fs, fs / baud, off, det))
      end
    end
  end
  if not A.quiet then
    print(string.format('  %-6s %s: %d rates in %.2f s, %d not as expected',
                        v.id, v.class, table.getn(P.rates), os.clock() - t0, vbad))
  end
end

print(string.format('\n%d ok, %d BAD, %d unjudgeable of %d cell(s)',
                    nok, nbad, nskip, nok + nbad + nskip))
if nok + nbad == 0 then
  print('REFUSING to report success: nothing was judged at all.')
  os.exit(1)
end
os.exit(nbad > 0 and 1 or 0)

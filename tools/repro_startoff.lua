-- repro_startoff.lua -- the lead's start-offset recipe, with ua_best_* fully instrumented.
--
-- Run from the repo root:
--   lua tools/repro_startoff.lua sweep  [v44d|v44e]     which start offsets take the octave
--   lua tools/repro_startoff.lua why    [v44d|v44e] [k] every number ua_best_end decided on
--   lua tools/repro_startoff.lua med                    med/T for the candidate that must be KEPT
--
-- THE POINT OF THE FILE is the `why` mode: which branch of ua_best_end returns the halved
-- bit time, and with what numbers. Everything else here exists to get to a capture that
-- takes the octave.
--
-- Stimulus per the lead's recipe: the cells the ARB plays, LOOPED, so each seam carries a
-- 40-bit idle run (20 tail + 20 lead); rendered at fs = pick_fs(9600, 8) = 80000, phase 0.37;
-- then a window of floor(ns/2) samples opened at an arbitrary SAMPLE rather than on the lead
-- idle, which is what a triggered hardware capture does.

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')

local BAUD, FS = 9600, 80000
local NLOOP    = 26

-- ---------------------------------------------------------------------------
-- Logical cells, built directly so the loop seam is explicit.
-- ---------------------------------------------------------------------------
local function popcount(v)
  local ones, t = 0, v
  while t > 0 do
    if math.mod(t, 2) >= 1 then ones = ones + 1 end
    t = math.floor(t / 2)
  end
  return ones
end

local function cells(o)
  local nbits = o.nbits or 8
  local par   = o.par or 0
  local nstop = o.nstop or 1
  local by, nb = GEN_BYTES('Hello, World!')
  local c, nc = {}, 0
  local function put(v, k) local j; for j = 1, k do nc = nc + 1; c[nc] = v end end
  local L
  for L = 1, NLOOP do
    put(1, 20)                                       -- lead idle
    local i, k
    for i = 1, nb do
      local v = by[i]
      put(0, 1)                                      -- start
      local t = v
      for k = 1, nbits do put(math.mod(t, 2), 1); t = math.floor(t / 2) end
      if par ~= 0 then
        local pe = math.mod(popcount(math.mod(v, 2 ^ nbits)), 2)
        if par == 1 then put(pe, 1) else put(1 - pe, 1) end
      end
      put(1, nstop)
      if i < nb then put(1, 2) end                   -- 2-bit inter-byte gap
    end
    put(1, 20)                                       -- tail idle -> 40-bit seam
  end
  return c, nc
end

local CASES = {
  v44e = {opt = {nstop = 2},          want = '8N1'},
  v44d = {opt = {nbits = 8, par = 2}, want = '8O1'},
}

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.widths_any = false
end

-- A window opened at an arbitrary sample, copied into a fresh 1-based array.
local function window(id, startfrac)
  local c, nc = cells(CASES[id].opt)
  local rd, ts, _, ns = GEN_RENDER(c, nc, {baud = BAUD, fs = FS, phase = 0.37})
  local want = math.floor(ns / 2)
  local i0 = 1 + math.floor(startfrac * (ns - want))
  local w, j = {}, nil
  for j = 1, want do w[j] = rd[i0 + j - 1] end
  return w, want, i0, ns
end

local PN = {'N', 'E', 'O'}
local function fmtname(r)
  if r == nil then return '<none>' end
  return string.format('%d%s%d', r.nbits or 0, PN[(r.par or 0) + 1], r.nstop or 0)
end

local function analyse(rd, n)
  clearforce()
  sdec.acq_fs, sdec.fs = FS, FS
  if not sdec.sig_levels(rd, n) then return false end
  sdec.sig_edges(rd, n)
  sdec.sig_idle(rd, n)
  return true
end

-- ===========================================================================
local cmd = (arg and arg[1]) or 'sweep'
local id  = (arg and arg[2]) or 'v44d'

if cmd == 'sweep' then
  local ids = {'v44d', 'v44e'}
  if id ~= 'both' then ids = {id} end
  local j, k
  for j = 1, table.getn(ids) do
    local vid = ids[j]
    print(string.format('\n%s -- 32 start offsets, fs=%g, window = half the render', vid, FS))
    print('  k/32  startfrac  baud    fmt   nf    bad   T       wmed    wmed/T  fitq      ratio  note')
    local nwrong = 0
    for k = 0, 31 do
      local rd, n = window(vid, k / 32)
      if analyse(rd, n) then
        local ok = sdec.decode_from(rd, n)
        local r = sdec.res
        local T = sdec.bittime or -1
        local bad = (r and r.nbad) or 0
        local wrong = not (ok and fmtname(r) == CASES[vid].want and sdec.baud == BAUD)
        if wrong then nwrong = nwrong + 1 end
        print(string.format('  %2d/32  %.4f    %-7s %-5s %-5d %-5d %-7.3f %-7.2f %-7.2f %-9.6f %-6s %s%s',
              k, k / 32, tostring(sdec.baud), fmtname(r), (r and r.nf) or 0, bad, T,
              sdec.wmed or -1, (sdec.wmed or 0) / T, sdec.fitq or -1,
              tostring(sdec.fitratio), tostring(sdec.baud_note),
              wrong and '   <== WRONG' or ''))
      end
    end
    print(string.format('  %d of 32 start offsets misread', nwrong))
  end

elseif cmd == 'why' then
  local k = tonumber(arg[3]) or 25
  local rd, n, i0, ns = window(id, k / 32)
  analyse(rd, n)
  local Ttrue = FS / BAUD
  print(string.format('%s  start %d/32 (sample %d of %d), window %d samples, true T=%.4f',
        id, k, i0, ns, n, Ttrue))
  print(string.format('  levels lo=%.4f hi=%.4f thr=%.4f  edges=%d idle=%d',
        sdec.lo, sdec.hi, sdec.thr, sdec.ne, sdec.idle))

  -- THE FIRST PULSE, which is what the truncated window damages. uart_decode.tsp:159:
  -- "one narrow glitch is enough to pull the fit to a sub-multiple".
  local w1 = nil
  if sdec.ne >= 2 then w1 = sdec.ei[2] - sdec.ei[1] end
  print(string.format('  first edge at %.3f (so %.3f samples = %.3f bit of truncated run before it); first pulse %s',
        sdec.ei[1] or -1, (sdec.ei[1] or 1) - 1, ((sdec.ei[1] or 1) - 1) / Ttrue,
        w1 and string.format('%.3f sa = %.3f bit', w1, w1 / Ttrue) or 'n/a'))

  local Tfit, why = sdec.sig_bittime()
  print(string.format('  sig_bittime -> Tfit=%.4f (%.4f x true) q=%.9f wmed=%.3f (%.3f x true)  why=%s',
        Tfit or -1, (Tfit or 0) / Ttrue, sdec.fitq, sdec.wmed, sdec.wmed / Ttrue,
        tostring(why)))

  local st = sdec.ua_best_begin(rd, n, Tfit)
  -- qbest is not returned, so recompute it exactly as ua_best_begin does.
  local qbest, i = 0, nil
  for i = 1, st.nc do
    if st.cands[i].q ~= nil and st.cands[i].q > qbest then qbest = st.cands[i].q end
  end
  print(string.format('\n  == ua_best_begin ==\n  snap1=%s  mayrescale=%s  qbest=%.9f  qmin=%.9f',
        tostring(st.snap1), tostring(st.mayrescale), qbest, st.qmin))
  print(string.format('  sc1=%s  good1=%s  bad1=%s     <-- the FIT scored over ua_probe_n=%s samples',
        tostring(st.sc1), tostring(st.good1), tostring(st.bad1), tostring(sdec.ua_probe_n)))
  -- Why sc1 came out as it did: nil means an admission test rejected the fit.
  if st.sc1 == nil then
    local plaus = sdec.ua_plausible(Tfit, n)
    local _, q1 = sdec.sig_fit(sdec.w, sdec.nw, Tfit)
    print(string.format('  sc1 is NIL because: ua_plausible=%s (%s), q1=%.9f vs qmin=%.9f -> %s',
          tostring(plaus),
          plaus and 'passed' or tostring(sdec.ua_implausible_why(Tfit)),
          q1 or -1, st.qmin,
          (q1 or 0) >= st.qmin and 'q gate passed, so ua_probe framed nothing'
                                or 'q GATE REJECTED THE FIT'))
  else
    print(string.format('  sc1 is %d = ngood - 3*nbad = %d - 3*%d  (%s zero, so the `sc1 > 0` branch is %s)',
          st.sc1, st.good1, st.bad1, st.sc1 > 0 and 'above' or 'AT OR BELOW',
          st.sc1 > 0 and 'ENTERED' or 'SKIPPED -- and both defences live inside it'))
  end

  print('\n  == every candidate ua_best_probe considered ==')
  print('    ratio     T        T/true  baud       snap      q            >=qmin plaus med/T  probe_sc')
  local function row(cn)
    local T, r, q = cn.T, cn.r, cn.q
    local snapb, snapped = sdec.sig_snap(FS / T)
    local plaus = sdec.ua_plausible(T, n)
    local pass = (q ~= nil and q >= st.qmin)
    local sc = nil
    if st.mayrescale and r ~= 1 and pass and plaus and snapped then
      sc = sdec.ua_probe(rd, n, T)
    end
    print(string.format('    %-9.4f %-8.4f %-7.4f %-10.1f %-9s %-12s %-6s %-5s %-6.2f %s',
          r, T, T / Ttrue, FS / T,
          snapped and ('->' .. tostring(snapb)) or 'unsnap',
          q and string.format('%.9f', q) or 'nil',
          pass and 'yes' or 'NO', plaus and 'yes' or 'NO',
          sdec.wmed / T, tostring(sc)))
  end
  for i = 1, st.nc do row(st.cands[i]) end

  while sdec.ua_best_probe(st) do end
  print(string.format('\n  == ua_best_end ==\n  altT=%s  altsc=%s  altr=%s',
        st.altT and string.format('%.4f', st.altT) or 'nil',
        tostring(st.altsc), tostring(st.altr)))
  -- Walk the branch conditions in source order so the answer is not inferred.
  local sc1, altsc = st.sc1, st.altsc
  print(string.format('  :1013  if snap1 and sc1 ~= nil and sc1 > 0            -> %s',
        (st.snap1 and sc1 ~= nil and sc1 > 0) and 'TAKEN (sets a baud_note either way)'
                                              or 'NOT TAKEN'))
  print(string.format('  :1032  if altT == nil                                 -> %s',
        st.altT == nil and 'TAKEN' or 'NOT TAKEN'))
  print(string.format('  :1042  if snap1 and sc1 ~= nil and altsc <= 0         -> %s',
        (st.snap1 and sc1 ~= nil and altsc ~= nil and altsc <= 0) and 'TAKEN'
          or string.format('NOT TAKEN (altsc=%s)', tostring(altsc))))
  print(string.format('  :1043  if sc1 ~= nil and altsc <= sc1                 -> %s',
        (sc1 ~= nil and altsc ~= nil and altsc <= sc1) and 'TAKEN'
          or string.format('NOT TAKEN (%s <= %s is false)', tostring(altsc), tostring(sc1))))
  local T, ratio = sdec.ua_best_end(st)
  print(string.format('  :1044  return altT, altr                              -> %s',
        (T ~= nil and ratio ~= 1) and 'REACHED, and this is the line that returns the halved fit'
                                   or 'not reached'))
  print(string.format('  ua_best_end returned T=%.4f ratio=%s -> %s Bd;  baud_note=%s',
        T or -1, tostring(ratio), tostring(sdec.sig_snap(FS / (T or 1))),
        tostring(sdec.baud_note)))

  -- And what the format search then does at that bit time.
  print(string.format('\n  == format search at T=%.4f (%.3f x true) ==', T, T / Ttrue))
  local rows, nr = {}, 0
  local a, b, c2, d
  for a = 0, 1 do
    local widths = sdec.ua_widths()
    for b = 1, table.getn(widths) do
      for c2 = 1, table.getn(sdec.try_par) do
        for d = 1, table.getn(sdec.try_stop) do
          local rr = sdec.ua_run(rd, n, T, widths[b], sdec.try_par[c2], sdec.try_stop[d], a == 1)
          if rr.ngood >= 1 then
            nr = nr + 1
            rows[nr] = {name = string.format('%d%s%d%s', widths[b], PN[sdec.try_par[c2] + 1],
                                             sdec.try_stop[d], a == 1 and ' inv' or ''),
                        sc = sdec.ua_score(rr), nf = rr.nf, g = rr.ngood, b = rr.nbad}
          end
        end
      end
    end
  end
  table.sort(rows, function(x, y) return x.sc > y.sc end)
  for i = 1, nr do
    if i <= 5 then
      print(string.format('    %-10s score=%-6d frames=%-5d good=%-5d bad=%d%s',
            rows[i].name, rows[i].sc, rows[i].nf, rows[i].g, rows[i].b,
            i == 1 and '   <== wins' or ''))
    end
  end
  local rt = sdec.ua_run(rd, n, Ttrue, CASES[id].opt.nbits or 8,
                         CASES[id].opt.par or 0, 1, false)
  print(string.format('    for contrast, %s at the TRUE bit time: score=%d frames=%d good=%d bad=%d',
        CASES[id].want, sdec.ua_score(rt), rt.nf, rt.ngood, rt.nbad))

-- ===========================================================================
-- 'med' -- is `reject a candidate when wmed / T' > 2.5` safe?
--
-- The gate would be applied to the candidate that must be KEPT, so the number that decides
-- the design is med/T' for the candidate each legitimate case NEEDS. Anything at or above
-- 2.5 there is a case the gate would break.
-- ===========================================================================
elseif cmd == 'med' then
  local function rep(v, k) local t, i = {}, nil; for i = 1, k do t[i] = v end; return t end
  -- Payloads whose pulse-width statistics are NOT "median = 2 bit times". These are the
  -- suites' own hard cases, not invented ones.
  local pats = {
    {name = 'Hello, World! 8N1 gap2',  o = {bytes = GEN_BYTES('Hello, World!')}},
    {name = 'Hello, World! 8N2 gap2',  o = {bytes = GEN_BYTES('Hello, World!'), nstop = 2}},
    {name = 'all 0x00 x8 gap2',        o = {bytes = rep(0, 8)}},
    {name = 'all 0x00 x8 gap1',        o = {bytes = rep(0, 8), gap = 1}},
    {name = 'all 0x00 x8 gap0',        o = {bytes = rep(0, 8), gap = 0}},
    {name = 'all 0xFF x8 gap2',        o = {bytes = rep(255, 8)}},
    {name = 'all 0x55 x8 gap2',        o = {bytes = rep(0x55, 8)}},
    {name = 'all 0xAA x8 gap2',        o = {bytes = rep(0xAA, 8)}},
    {name = 'all 0x0F x8 gap2',        o = {bytes = rep(0x0F, 8)}},
    {name = 'all 0x33 x8 gap2',        o = {bytes = rep(0x33, 8)}},
    {name = '0x00 x8 7N1 gap1',        o = {bytes = rep(0, 8), nbits = 7, gap = 1}},
    {name = '5N1 varied gap0',         o = {bytes = {0x11,0x0A,0x15,0x1F,0x00,0x1A,0x07,0x13},
                                            nbits = 5, gap = 0}},
  }
  print('med/T for the bit time each capture NEEDS, i.e. what a `wmed/T > 2.5` gate would judge.')
  print('A value at or above 2.50 in the last column is a case the proposed gate would REJECT.')
  print('\n  payload                       Tneed    wmed     med/Tneed  verdict')
  local i
  for i = 1, table.getn(pats) do
    local p = pats[i]
    local o = p.o
    o.baud, o.fs = BAUD, FS
    local rd, ts, nc, n = GEN(o)
    clearforce()
    sdec.acq_fs, sdec.fs = FS, FS
    sdec.sig_levels(rd, n); sdec.sig_edges(rd, n); sdec.sig_idle(rd, n)
    sdec.sig_bittime()
    local Tneed = FS / BAUD
    local ratio = sdec.wmed / Tneed
    print(string.format('  %-29s %-8.3f %-8.3f %-10.2f %s', p.name, Tneed, sdec.wmed, ratio,
          ratio > 2.5 and 'GATE REJECTS THE TRUTH' or 'ok'))
  end
else
  print('usage: lua tools/repro_startoff.lua [sweep|why|med] [v44d|v44e|both] [k]')
end

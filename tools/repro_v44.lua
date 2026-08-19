-- repro_v44.lua -- reproduce the intermittent v44d / v44e format misreads OFFLINE.
--
-- Run from the repo root:   lua tools/repro_v44.lua [sweep|one|why] [v44d|v44e] ...
--
-- WHY A NEW TOOL RATHER THAN A CASE IN debug_serial.lua. Both bench failures are
-- INTERMITTENT -- the same vector passes most laps and fails some -- so a single
-- offline waveform proves nothing either way. What varies between laps is not the
-- stimulus (measured on an independent scope: identical, ten cycles running) but WHERE
-- THE DMM'S SAMPLING GRID LANDS on it. So the free variable has to be swept, and the
-- thing being reported is a FRACTION of the swept space, not a verdict.
--
-- WHAT IS MODELLED, and why each piece is needed:
--
--   1. The SDG plays out/vectors/v44X.bin at 100 000 Sa/s, ON REPEAT. That file is read
--      here rather than regenerated, so the stimulus is the literal codeword stream the
--      bench loads -- no chance of modelling a waveform the bench does not send.
--   2. A bit is 10.41667 arb points, so the arb grid does NOT align with cell
--      boundaries: every edge is quantised to a whole arb point, i.e. displaced by up to
--      +/-0.5 point = +/-4.8 % of a bit. That is a real, systematic impairment of the
--      stimulus and it is invisible if the waveform is rendered directly at the DMM's
--      rate.
--   3. The arb is 2158 points where 207 cells is 2156.25, so the LOOP SEAM adds 1.75
--      points of extra idle per pass -- the phase creeps by 0.168 of a cell every 13
--      bytes. A window holds ~11 passes, so the creep is ~1.9 cells across one capture.
--   4. The DMM samples INDEPENDENTLY at 80 000 Sa/s (fs_for_baud(9600), 8.333
--      samples/bit) from an arbitrary point in the loop. That start point is the free
--      variable: `off` in arb points, swept over a full bit period and beyond.
--
-- Sample rates are the app's own choices, not guesses: sdec.fs_for_baud(9600) = 80000
-- and sdec.fs_for_baud(19200) = 160000, and BOTH occur on the bench because the 1 MS/s
-- probe pass sometimes fits 19200 and sizes the real capture from it (serial_app.tsp:225).
-- So fs is a swept variable too.

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')

local ARB_FS  = 100000       -- the rate the SDG plays the file at (manifest srate_sa_s)
local ARB_FSV = 5.0          -- full scale the file was encoded at (AMP 10 Vpp)
local BAUD    = 9600
local NCAP    = 19011        -- samples a 20000-point frame capture actually delivers

-- ---------------------------------------------------------------------------
-- The wire: the arb file, in volts, exactly as the SDG will reconstruct it.
-- ---------------------------------------------------------------------------
local wirecache = {}
local function wire(id)
  if wirecache[id] == nil then
    local cw, n = GEN_READ('out/vectors/' .. id .. '.bin')
    local v, i = {}, nil
    for i = 1, n do v[i] = GEN_VOLTS(cw[i], ARB_FSV, 0) end
    wirecache[id] = {v = v, n = n}
  end
  local c = wirecache[id]
  return c.v, c.n
end

-- ---------------------------------------------------------------------------
-- One DMM capture of the looping arb.
--
--   o.off   start position in ARB POINTS (fractional) -- the capture phase
--   o.fs    the DMM's sample rate (80000 or 160000)
--   o.n     samples to take (NCAP)
--   o.ferr  relative error in the GENERATOR's rate (the DMM's is the reference)
--   o.hold  true for zero-order hold, else linear between arb points
--
-- Linear is the default. A DAC playing 100 kSa/s into a reconstruction filter does not
-- produce a step, and the app's sub-sample edge interpolation (sig_cross) has real
-- slope to work with on the bench -- the scope measured clean 0/3.26 V levels. `hold`
-- is the harsher alternative and is swept as a robustness check, not as the model.
-- ---------------------------------------------------------------------------
local function capture(id, o)
  local v, na = wire(id)
  local fs   = o.fs or 80000
  local n    = o.n or NCAP
  local step = ARB_FS * (1 + (o.ferr or 0)) / fs
  local x0   = o.off or 0
  local hold = o.hold
  local rd, j = {}, nil
  local mod, floor = math.fmod, math.floor
  for j = 1, n do
    local x  = mod(x0 + (j - 1) * step, na)
    local i0 = floor(x)
    local a  = v[i0 + 1]
    if hold then
      rd[j] = a
    else
      local b = v[mod(i0 + 1, na) + 1]
      rd[j] = a + (b - a) * (x - i0)
    end
  end

  -- The BENCH offset and swing, not the file's. The scope measured -0.020 / 3.260 V and the
  -- panel reports thr 1.63, which is (lo+hi)/2 of exactly those -- so the model's 0.000 /
  -- 3.300 puts the threshold 30 mV high and every edge crossing a shade late.
  if o.bench then
    for j = 1, n do rd[j] = -0.020 + rd[j] * (3.280 / 3.300) end
  end
  -- Front-end impairments, in the order the physical chain applies them.
  if o.rc and o.rc > 0 then
    local tau = o.rc * (fs / BAUD)
    local alpha = 1 - math.exp(-1 / tau)
    local y = rd[1]
    for j = 1, n do y = y + (rd[j] - y) * alpha; rd[j] = y end
  end
  if o.ring and o.ring > 0 then
    GEN_RING(rd, n, o.ring, o.ringper or (0.25 * fs / BAUD), o.ringdec or 0.5)
  end
  if o.noise and o.noise > 0 then
    for j = 1, n do rd[j] = rd[j] + o.noise * (GEN_RAND() * 2 - 1) end
  end
  return rd, n
end

-- ---------------------------------------------------------------------------
-- Run the real chain, exactly as tools/test_serial.lua's analyse()+run() do.
-- ---------------------------------------------------------------------------
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
  local ok, why = sdec.decode_from(rd, n)
  return ok, why, sdec.res
end

local PN = {'N', 'E', 'O'}
local function fmtname(r)
  if r == nil then return '<nil>' end
  return string.format('%d%s%d', r.nbits or 0, PN[(r.par or 0) + 1], r.nstop or 0)
end

-- Interior bad frames and the longest error-free run, the two numbers
-- bench_matrix.py prints beside a BAD verdict.
local function shape(r)
  if r == nil then return 0, 0, 0 end
  local nin = sdec.ua_bad_interior(r)
  local run, best, i = 0, 0, nil
  for i = 1, r.nf do
    if r.errs[i] == nil then run = run + 1; if run > best then best = run end
    else run = 0 end
  end
  return r.nf, nin, best
end

-- ---------------------------------------------------------------------------
-- One point of the sweep. Returns a compact record.
-- ---------------------------------------------------------------------------
local function point(id, o)
  local rd, n = capture(id, o)
  local ok, why, r = decode(rd, n, o.fs or 80000)
  local nf, nin, run = shape(r)
  return {ok = ok, why = why, fmt = fmtname(r), baud = sdec.baud,
          braw = sdec.baud_raw, T = sdec.bittime, ratio = sdec.fitratio,
          nf = nf, nbad = (r and r.nbad) or 0, nin = nin, run = run,
          note = sdec.fmt_note, bnote = sdec.baud_note,
          head = (r and r.headsusp) or 0, r = r, rd = rd, n = n}
end

-- Expected format per vector: what the panel must say. v44e is 8N2 on the wire and
-- 8N1 is the honest report (the second stop bit is idle, uart_decode.tsp:117-121).
local WANT = {v44e = '8N1', v44d = '8O1'}

-- ===========================================================================
-- 'one' -- a single point, in full
-- ===========================================================================
local function cmd_one(id, off, fs, ferr, hold)
  local o = {off = off, fs = fs, ferr = ferr, hold = hold}
  local p = point(id, o)
  print(string.format('%s  off=%.3f arb  fs=%g  ferr=%+.4f%s', id, off, fs,
                      ferr or 0, hold and '  ZOH' or ''))
  print(string.format('  levels lo=%.3f hi=%.3f thr=%.3f  edges=%d  idle=%d  wmed=%.3f',
        sdec.lo, sdec.hi, sdec.thr, sdec.ne, sdec.idle, sdec.wmed or -1))
  print(string.format('  fit T=%.4f sa (true %.4f)  baud_raw=%.1f  baud=%s snapped=%s  fitratio=%s',
        p.T or -1, fs / BAUD, p.braw or -1, tostring(p.baud), tostring(sdec.snapped),
        tostring(p.ratio)))
  print(string.format('  --> %s  %s   %d B, %d bad (%d interior), longest clean run %d, head %d',
        p.ok and 'ok' or 'REFUSED', p.fmt, p.nf, p.nbad, p.nin, p.run, p.head))
  if p.note  then print('      fmt_note:  ' .. p.note) end
  if p.bnote then print('      baud_note: ' .. p.bnote) end
  local want = WANT[id]
  print(string.format('  VERDICT: %s (want %s at %d Bd)',
        (p.fmt == want and p.baud == BAUD) and 'PASS' or 'MISREAD', want, BAUD))
  return p
end

-- ===========================================================================
-- 'why' -- the whole decision, for one point: the bit-time candidates ua_best
-- ranked, then every format ua_search_pol scored at the bit time it chose.
-- ===========================================================================
local function cmd_why(id, off, fs, ferr, hold)
  local p = cmd_one(id, off, fs, ferr, hold)
  local rd, n = p.rd, p.n
  local Ttrue = fs / BAUD

  -- Re-derive the fit the way decode_from does, then walk ua_best's own state machine
  -- so the numbers printed are the ones the decision used.
  sdec.acq_fs = fs
  local Tfit = sdec.sig_bittime()
  print(string.format('\n  sig_bittime -> Tfit=%.4f sa = %.4f x true;  q=%.4f;  wmed=%.3f (%.3f x true)',
        Tfit or -1, (Tfit or 0) / Ttrue, sdec.fitq, sdec.wmed, sdec.wmed / Ttrue))

  local st = sdec.ua_best_begin(rd, n, Tfit)
  print(string.format('  ua_best_begin: snap1=%s  sc1=%s  good1=%s bad1=%s  qmin=%.4f  mayrescale=%s',
        tostring(st.snap1), tostring(st.sc1), tostring(st.good1), tostring(st.bad1),
        st.qmin, tostring(st.mayrescale)))
  print('  candidate bit times ua_best considered:')
  local i
  for i = 1, st.nc do
    local c = st.cands[i]
    local snapb, snapped = sdec.sig_snap(fs / c.T)
    local plaus = sdec.ua_plausible(c.T, n)
    local sc = nil
    if plaus and c.q ~= nil and c.q >= st.qmin then sc = sdec.ua_probe(rd, n, c.T) end
    print(string.format('    r=%-8.4f T=%8.4f (%.4f x true)  baud=%9.1f %-8s q=%-7s %s probe_sc=%s',
          c.r, c.T, c.T / Ttrue, fs / c.T,
          snapped and ('->' .. tostring(snapb)) or 'unsnap',
          c.q and string.format('%.4f', c.q) or 'nil',
          plaus and ' ' or 'X', tostring(sc)))
  end
  while sdec.ua_best_probe(st) do end
  print(string.format('  ua_best chose: altT=%s altsc=%s altr=%s',
        st.altT and string.format('%.4f', st.altT) or 'nil',
        tostring(st.altsc), tostring(st.altr)))
  local T, ratio, badwhy = sdec.ua_best_end(st)
  print(string.format('  ua_best_end -> T=%s ratio=%s why=%s  (baud_note: %s)',
        T and string.format('%.4f', T) or 'nil', tostring(ratio), tostring(badwhy),
        tostring(sdec.baud_note)))

  -- Every format the search scores, at the bit time actually chosen.
  print(string.format('\n  ua_search_pol at T=%.4f (%.4f x true) -- every candidate, best first:',
        T, T / Ttrue))
  local rows, nr = {}, 0
  local a, b, c, d
  for a = 0, 1 do
    local inv = (a == 1)
    local widths = sdec.ua_widths()
    for b = 1, table.getn(widths) do
      for c = 1, table.getn(sdec.try_par) do
        for d = 1, table.getn(sdec.try_stop) do
          local rr = sdec.ua_run(rd, n, T, widths[b], sdec.try_par[c], sdec.try_stop[d], inv)
          if rr.ngood >= 1 then
            nr = nr + 1
            rows[nr] = {name = string.format('%d%s%d%s', widths[b], PN[sdec.try_par[c] + 1],
                                            sdec.try_stop[d], inv and ' inv' or ''),
                        sc = sdec.ua_score(rr), nf = rr.nf, ngood = rr.ngood, nbad = rr.nbad}
          end
        end
      end
    end
  end
  table.sort(rows, function(x, y) return x.sc > y.sc end)
  for i = 1, nr do
    local rr = rows[i]
    print(string.format('    %-10s score=%-6d frames=%-5d good=%-5d bad=%d%s',
          rr.name, rr.sc, rr.nf, rr.ngood, rr.nbad,
          i == 1 and '   <== WINS the search' or ''))
  end
  print(string.format('    margin a rival must clear over the winner: %.1f (ordinary), %.1f (5/6-bit)',
        sdec.ua_margin(rows[1].sc), sdec.ua_margin(rows[1].sc, 6)))

  -- And what the truth would have given at the true bit time, for contrast.
  local rt = sdec.ua_run(rd, n, Ttrue, 8, sdec.PAR_NONE, 1, false)
  print(string.format('\n  for contrast, 8N1 at the TRUE bit time %.4f: score=%d frames=%d good=%d bad=%d',
        Ttrue, sdec.ua_score(rt), rt.nf, rt.ngood, rt.nbad))
end

-- ===========================================================================
-- 'half' -- GIVEN the 2x bit-time misfit, what does the rest of the decoder do?
--
-- The bench panel reported 19200 Bd. This injects exactly that and nothing else --
-- sdec.force_baud sets the bit time and leaves the ENTIRE format search,
-- ua_refine_width and ua_refine_parity running normally (decode_from only shortcuts the
-- search when the WIDTH is forced) -- so the frame count, bad count and clean-run length
-- printed here are directly comparable with the bench line, and a match is the
-- arbitration's doing rather than the injection's.
-- ===========================================================================
local function cmd_half(id, off, fs, baud)
  local rd, n = capture(id, {off = off, fs = fs, bench = true})
  clearforce()
  sdec.acq_fs, sdec.fs = fs, fs
  sdec.sig_levels(rd, n)
  sdec.sig_edges(rd, n)
  sdec.sig_idle(rd, n)
  sdec.force_baud = baud
  local ok = sdec.decode_from(rd, n)
  local r = sdec.res
  local nf, nin, run = shape(r)
  print(string.format('%s  fs=%g  bit time forced to %d Bd (true %d, %.3fx)  off=%.2f',
        id, fs, baud, BAUD, BAUD / baud, off))
  print(string.format('  --> %s  %s  %d B, %d bad (%d interior), longest clean run %d, head %d',
        ok and 'ok' or 'REFUSED', fmtname(r), nf, (r and r.nbad) or 0, nin, run,
        (r and r.headsusp) or 0))
  if sdec.fmt_note then print('      fmt_note: ' .. sdec.fmt_note) end
  print('      bench v44e: 7N1 153 B (head 0), longest clean run  9, 35 bad (35 interior)')
  print('      bench v44d: 7N1 153 B (head 0), longest clean run  8, 41 bad (41 interior)')
  sdec.force_baud = nil
  return r
end

-- ===========================================================================
-- 'seeds' -- what sig_bittime is actually choosing between.
--
-- The 2x misfit can ONLY come from here: sig_fit refines from a SEED, seeds are the
-- four smallest CORROBORATED pulse widths thinned 30 % apart, and half the bit time is
-- reachable only if the capture contains pulses that narrow. So this prints the width
-- census and every seed's fit, which is the difference between "the fit is wrong" and
-- "the fit had no way to be right".
-- ===========================================================================
local function cmd_seeds(id, off, fs, o)
  o = o or {}
  o.off, o.fs = off, fs
  local rd, n = capture(id, o)
  clearforce()
  sdec.acq_fs, sdec.fs = fs, fs
  sdec.sig_levels(rd, n)
  sdec.sig_edges(rd, n)
  sdec.sig_idle(rd, n)
  local Ttrue = fs / BAUD
  print(string.format('%s off=%.3f fs=%g n=%d  noise=%s ring=%s rc=%s', id, off, fs, n,
        tostring(o.noise), tostring(o.ring), tostring(o.rc)))
  print(string.format('  lo=%.4f hi=%.4f thr=%.4f hyst=%.4f  edges=%d  true T=%.4f',
        sdec.lo, sdec.hi, sdec.thr, sdec.hyst, sdec.ne, Ttrue))

  local w, s, nw = {}, {}, sdec.ne - 1
  local k
  for k = 1, nw do w[k] = sdec.ei[k+1] - sdec.ei[k]; s[k] = w[k] end
  table.sort(s)
  -- census in units of the true bit time
  local hist, keys, nk = {}, {}, 0
  for k = 1, nw do
    local key = string.format('%.2f', w[k] / Ttrue)
    if hist[key] == nil then nk = nk + 1; keys[nk] = key; hist[key] = 0 end
    hist[key] = hist[key] + 1
  end
  table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
  local out, no = {}, 0
  for k = 1, nk do
    if tonumber(keys[k]) < 7 then no = no + 1; out[no] = keys[k] .. 'T x' .. hist[keys[k]] end
  end
  print('  widths (<7T): ' .. table.concat(out, '  '))
  print(string.format('  smallest 8 widths: %.3f %.3f %.3f %.3f %.3f %.3f %.3f %.3f  (in T: %.3f %.3f %.3f %.3f)',
        s[1] or -1, s[2] or -1, s[3] or -1, s[4] or -1, s[5] or -1, s[6] or -1, s[7] or -1, s[8] or -1,
        (s[1] or 0)/Ttrue, (s[2] or 0)/Ttrue, (s[3] or 0)/Ttrue, (s[4] or 0)/Ttrue))

  -- the seed selection, verbatim from sig_bittime
  local seeds, nseed, last = {}, 0, 0
  for k = 1, nw do
    local v = s[k]
    local corrob = (k < nw and s[k+1] <= 1.25 * v) or nw < 3
    if v > 0 and corrob and (nseed == 0 or v > 1.3 * last) then
      nseed = nseed + 1; seeds[nseed] = v; last = v
      if nseed >= 4 then break end
    end
  end
  for k = 1, nseed do
    local T, q, nfit = sdec.sig_fit(w, nw, seeds[k])
    print(string.format('  seed %2d = %8.4f sa (%.4f T) -> T=%s (%.4f T) q=%.6f nfit=%d  baud=%s',
          k, seeds[k], seeds[k] / Ttrue,
          T and string.format('%.4f', T) or 'nil', (T or 0) / Ttrue, q, nfit,
          T and tostring(sdec.sig_snap(fs / T)) or '-'))
  end
  local Tfit = sdec.sig_bittime()
  print(string.format('  CHOSE T=%.4f (%.4f x true) -> baud_raw=%.1f baud=%s snapped=%s q=%.6f',
        Tfit or -1, (Tfit or 0) / Ttrue, sdec.baud_raw or -1, tostring(sdec.baud),
        tostring(sdec.snapped), sdec.fitq))
end

-- ===========================================================================
-- 'sweep' -- the free variables, and what fraction of the space misreads
-- ===========================================================================
local function cmd_sweep(id, o)
  o = o or {}
  local want = WANT[id]
  local nstep = o.nstep or 40
  local fslist = o.fslist or {80000, 160000}
  local ferrs  = o.ferrs or {0}
  local holds  = o.holds or {false}
  -- One arb point at 100 kSa/s is 0.096 of a bit, so a full bit period is 10.4167
  -- points. Sweeping 13 CELLS (one byte pitch) in fine steps covers the sub-bit phase
  -- and the starting byte at once, and multiples of it walk the payload.
  local _, arbn = wire(id)
  local span = o.span or arbn
  local base = o.base or 0

  local nbad, ntot = 0, 0
  local fails, nfail = {}, 0
  local kinds = {}
  local fi, ei, hi, k
  for fi = 1, table.getn(fslist) do
    for ei = 1, table.getn(ferrs) do
      for hi = 1, table.getn(holds) do
        for k = 0, nstep - 1 do
          local off = base + span * k / nstep
          local p = point(id, {off = off, fs = fslist[fi], ferr = ferrs[ei],
                               hold = holds[hi]})
          ntot = ntot + 1
          local good = (p.ok and p.fmt == want and p.baud == BAUD)
          if not good then
            nbad = nbad + 1
            local kind = string.format('%s @ %s Bd', p.fmt, tostring(p.baud))
            kinds[kind] = (kinds[kind] or 0) + 1
            nfail = nfail + 1
            fails[nfail] = {off = off, fs = fslist[fi], ferr = ferrs[ei],
                            hold = holds[hi], p = p}
          end
        end
      end
    end
  end
  return nbad, ntot, fails, nfail, kinds
end

local function report_sweep(id, label, nbad, ntot, fails, nfail, kinds)
  print(string.format('\n%s  %s: %d of %d misread (%.1f %%)',
        id, label, nbad, ntot, 100 * nbad / ntot))
  local ks, nk = {}, 0
  for kk in pairs(kinds) do nk = nk + 1; ks[nk] = kk end
  table.sort(ks)
  local i
  for i = 1, nk do
    print(string.format('    %-24s x%d', ks[i], kinds[ks[i]]))
  end
  local m = nfail
  if m > 12 then m = 12 end
  for i = 1, m do
    local f = fails[i]
    print(string.format('    off=%8.3f fs=%-7g ferr=%+.4f %s -> %s @ %s Bd, %d B, %d bad (%d int), run %d',
          f.off, f.fs, f.ferr, f.hold and 'ZOH' or 'lin', f.p.fmt, tostring(f.p.baud),
          f.p.nf, f.p.nbad, f.p.nin, f.p.run))
  end
  if nfail > m then print(string.format('    ... and %d more', nfail - m)) end
end

-- ===========================================================================
-- 'app' -- THE WHOLE PANEL PATH, not one capture.
--
-- What the bench measures is sdec.capture() -> autoset(), which takes up to THREE
-- captures, and the intermittency lives in the handoff between them:
--
--   pass 1  probe at 1 MS/s. 20000 samples is 20 ms = ~12 bytes, and ua_probe_n caps the
--           RANKING at 4000 samples = ~3 bytes. Whatever baud this pass reports sizes the
--           next one.
--   pass 2  capture at pick_fs(that baud, 8). If pass 1 said 19200 this is 160 kS/s.
--   pass 3  only if pass 2's own baud wants a LOWER rate than pass 2 ran at
--           (serial_app.tsp:225). A pass-2 fit of 19200 at 160 kS/s asks for 160 kS/s
--           again, so this defence does NOT fire and 19200 reaches the panel.
--
-- Each capture is separately triggered, so the three phases are INDEPENDENT -- which is
-- why one lap can pass and the next fail with the stimulus provably identical.
-- ===========================================================================
local function app_capture(id, phases, o)
  o = o or {}
  local trace = {}
  local nt = 0
  local function pass(fs, off, n)
    local rd, nn = capture(id, {off = off, fs = fs, n = n or 20000,
                                ferr = o.ferr, noise = o.noise, rc = o.rc, bench = true})
    clearforce()
    sdec.acq_fs, sdec.fs = fs, fs
    if not sdec.sig_levels(rd, nn) then return false, nil, rd, nn end
    sdec.sig_edges(rd, nn)
    sdec.sig_idle(rd, nn)
    local ok = sdec.decode_from(rd, nn)
    nt = nt + 1
    trace[nt] = string.format('%g kS/s off=%.2f -> %s %s @ %s (T=%.4f, ratio=%s)',
                              fs / 1000, off, ok and 'ok' or 'refused',
                              fmtname(sdec.res), tostring(sdec.baud), sdec.bittime or -1,
                              tostring(sdec.fitratio))
    return ok, sdec.baud, rd, nn
  end

  -- pass 1: the probe
  local ok1, b1 = pass(1000000, phases[1] or 0)
  local target = b1
  if not ok1 or target == nil then return nil, trace end

  -- pass 2 at the rate the probe implies
  local want = sdec.pick_fs(target, 8)
  if want >= 1000000 then
    return {fmt = fmtname(sdec.res), baud = sdec.baud, r = sdec.res}, trace
  end
  local ok2, b2 = pass(want, phases[2] or 0)
  if not ok2 then return nil, trace end

  -- pass 3, the octave defence: only ever downward
  if b2 ~= nil and b2 > 0 then
    local w2 = sdec.pick_fs(b2, 8)
    if w2 ~= nil and w2 < want then
      local ok3 = pass(w2, phases[3] or 0)
      if not ok3 then return nil, trace end
    end
  end
  local r = sdec.res
  local nf, nin, run = shape(r)
  return {fmt = fmtname(r), baud = sdec.baud, nf = nf, nbad = r.nbad, nin = nin,
          run = run, head = r.headsusp or 0, note = sdec.fmt_note, r = r}, trace
end

-- ===========================================================================
local cmd = (arg and arg[1]) or 'sweep'
local id  = (arg and arg[2]) or 'v44e'

if cmd == 'one' then
  cmd_one(id, tonumber(arg[3]) or 0, tonumber(arg[4]) or 80000,
          tonumber(arg[5]) or 0, arg[6] == 'hold')
elseif cmd == 'why' then
  cmd_why(id, tonumber(arg[3]) or 0, tonumber(arg[4]) or 80000,
          tonumber(arg[5]) or 0, arg[6] == 'hold')
elseif cmd == 'sweep' then
  local ids = {id}
  if id == 'both' then ids = {'v44e', 'v44d'} end
  local j
  for j = 1, table.getn(ids) do
    local vid = ids[j]
    -- phase only, at each of the two sample rates the app actually uses
    local a, b, c, d, e = cmd_sweep(vid, {nstep = 40, fslist = {80000}})
    report_sweep(vid, 'phase x 40, fs 80 kS/s', a, b, c, d, e)
    a, b, c, d, e = cmd_sweep(vid, {nstep = 40, fslist = {160000}})
    report_sweep(vid, 'phase x 40, fs 160 kS/s', a, b, c, d, e)
  end
elseif cmd == 'full' then
  local ids = {id}
  if id == 'both' then ids = {'v44e', 'v44d'} end
  local j
  for j = 1, table.getn(ids) do
    local a, b, c, d, e = cmd_sweep(ids[j], {
      nstep = tonumber(arg[3]) or 60,
      fslist = {80000, 160000},
      ferrs = {-0.002, 0, 0.002},
      holds = {false, true},
      span = nil})
    report_sweep(ids[j], 'phase x N, fs {80k,160k}, ferr {-0.2%,0,+0.2%}, lin+ZOH',
                 a, b, c, d, e)
  end
elseif cmd == 'half' then
  cmd_half(id, tonumber(arg[3]) or 0, tonumber(arg[4]) or 80000, tonumber(arg[5]) or 19200)

-- Phase x window length, with the 19200 misfit injected: does the bench's exact
-- 153 B / 35 bad / run 9 and 153 B / 41 bad / run 8 fall inside the range?
elseif cmd == 'halfsweep' then
  local ids = {'v44e', 'v44d'}
  if id ~= 'both' then ids = {id} end
  local j, k, m
  local _, span = wire('v44e')
  for j = 1, table.getn(ids) do
    local vid = ids[j]
    for m = 1, 2 do
      local nn = ({19011, 20000})[m]
      local lo, hi, lob, hib, runs = 1e9, 0, 1e9, 0, {}
      local hit = nil
      for k = 0, 39 do
        local rd, n = capture(vid, {off = span * k / 40, fs = 160000, n = nn, bench = true})
        clearforce()
        sdec.acq_fs, sdec.fs = 160000, 160000
        sdec.sig_levels(rd, n); sdec.sig_edges(rd, n); sdec.sig_idle(rd, n)
        sdec.force_baud = 19200
        sdec.decode_from(rd, n)
        local r = sdec.res
        local nf, nin, run = shape(r)
        sdec.force_baud = nil
        if nf < lo then lo = nf end
        if nf > hi then hi = nf end
        if r.nbad < lob then lob = r.nbad end
        if r.nbad > hib then hib = r.nbad end
        runs[run] = (runs[run] or 0) + 1
        local wnf = (vid == 'v44e') and 35 or 41
        local wrun = (vid == 'v44e') and 9 or 8
        if nf == 153 and r.nbad == wnf and run == wrun then
          hit = string.format('off=%.3f', span * k / 40)
        end
      end
      local rs, nr = {}, 0
      for kk in pairs(runs) do nr = nr + 1; rs[nr] = kk end
      table.sort(rs)
      local parts, np = {}, 0
      for k = 1, nr do np = np + 1; parts[np] = rs[k] .. 'x' .. runs[rs[k]] end
      print(string.format('%s fs=160k n=%d forced 19200, 40 phases: frames %d..%d, nbad %d..%d, clean runs {%s}%s',
            vid, nn, lo, hi, lob, hib, table.concat(parts, ' '),
            hit and ('   EXACT BENCH MATCH at ' .. hit) or ''))
    end
  end
elseif cmd == 'seeds' then
  cmd_seeds(id, tonumber(arg[3]) or 0, tonumber(arg[4]) or 80000,
            {n = tonumber(arg[5]), noise = tonumber(arg[6]), bench = true})

-- ===========================================================================
-- 'probe' -- the 1 MS/s FIRST pass, which is what actually chooses the sample rate the
-- real capture runs at. serial_app.tsp:216 records this as measured: "two of ten
-- identical 9600-baud captures fitted 19200 on the probe and so ran the real capture at
-- 160 kS/s". Everything downstream follows from that, so it is swept on its own.
-- ===========================================================================
elseif cmd == 'probe' then
  local ids = {id}
  if id == 'both' then ids = {'v44e', 'v44d'} end
  local nstep = tonumber(arg[3]) or 60
  local noise = tonumber(arg[4]) or 0
  local j, k
  for j = 1, table.getn(ids) do
    local vid = ids[j]
    local tally, keys, nk = {}, {}, 0
    local _, span = wire(vid)
    for k = 0, nstep - 1 do
      local off = span * k / nstep
      local rd, n = capture(vid, {off = off, fs = 1000000, n = 20000,
                                  noise = noise, bench = true})
      clearforce()
      sdec.acq_fs, sdec.fs = 1000000, 1000000
      sdec.sig_levels(rd, n)
      sdec.sig_edges(rd, n)
      sdec.sig_idle(rd, n)
      local T = sdec.sig_bittime()
      local ok = sdec.decode_from(rd, n)
      local key = string.format('fit %s -> baud %s%s', T and string.format('%.2f', T) or 'nil',
                                tostring(sdec.baud), ok and '' or ' (no frame)')
      if tally[key] == nil then nk = nk + 1; keys[nk] = key; tally[key] = 0 end
      tally[key] = tally[key] + 1
    end
    print(string.format('\n%s probe pass, 1 MS/s x 20000, %d phases, noise=%g:', vid, nstep, noise))
    table.sort(keys)
    for k = 1, nk do print(string.format('    %-42s x%d', keys[k], tally[keys[k]])) end
  end
-- ===========================================================================
-- 'imp' -- which FRONT-END impairment drives sig_bittime onto half the bit time.
--
-- The clean model never misfits at any phase, so the 2x is not a property of the
-- stimulus. sig_fit refines from a seed and seeds are the smallest CORROBORATED widths,
-- so a fit at T/2 needs the capture to CONTAIN pulses near half a bit -- which is what a
-- bandwidth-limited front end produces, systematically and in one direction: a short
-- pulse never reaches full amplitude before it ends, so its threshold crossings move
-- inward and every one-bit pulse measures narrow. See GEN_RENDER's own note on rc.
-- ===========================================================================
elseif cmd == 'imp' then
  local ids = {'v44e', 'v44d'}
  if id ~= 'both' then ids = {id} end
  local rcs    = {0, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6}
  local noises = {0, 0.15, 0.3}
  local j, a, b, k
  for j = 1, table.getn(ids) do
    print(string.format('\n%s -- fit vs front-end RC (bit times) and noise (V), 8 phases each,',
          ids[j]))
    print('   at each sample rate the app can pick.  "19200" is the misfit being hunted.')
    local fss = {1000000, 160000, 80000}
    local ns  = {20000, 20000, 20000}
    local fi
    for fi = 1, 3 do
      for a = 1, table.getn(rcs) do
        for b = 1, table.getn(noises) do
          local tally, keys, nk = {}, {}, 0
          for k = 0, 7 do
            local rd, n = capture(ids[j], {off = 135.4 * k / 8, fs = fss[fi], n = ns[fi],
                                           rc = rcs[a], noise = noises[b], bench = true})
            clearforce()
            sdec.acq_fs, sdec.fs = fss[fi], fss[fi]
            local lok = sdec.sig_levels(rd, n)
            local key
            if not lok then
              key = 'levels refused'
            else
              sdec.sig_edges(rd, n); sdec.sig_idle(rd, n)
              local ok = sdec.decode_from(rd, n)
              key = string.format('%s @ %s', ok and fmtname(sdec.res) or 'refused',
                                  tostring(sdec.baud))
            end
            if tally[key] == nil then nk = nk + 1; keys[nk] = key; tally[key] = 0 end
            tally[key] = tally[key] + 1
          end
          table.sort(keys)
          local parts, np = {}, 0
          for k = 1, nk do np = np + 1; parts[np] = keys[k] .. ' x' .. tally[keys[k]] end
          print(string.format('   fs=%-8g rc=%-5g noise=%-5g -> %s', fss[fi], rcs[a],
                              noises[b], table.concat(parts, ' | ')))
        end
      end
    end
  end
elseif cmd == 'app' then
  local ph = {tonumber(arg[3]) or 0, tonumber(arg[4]) or 0, tonumber(arg[5]) or 0}
  local res, trace = app_capture(id, ph, {})
  local i
  for i = 1, table.getn(trace) do print('  pass ' .. i .. ': ' .. trace[i]) end
  if res == nil then print('  --> no result') else
    print(string.format('  PANEL: %s @ %s Bd, %d B, %d bad (%d interior), longest clean run %d, head %d',
          res.fmt, tostring(res.baud), res.nf or 0, res.nbad or 0, res.nin or 0,
          res.run or 0, res.head or 0))
    if res.note then print('    note: ' .. res.note) end
  end

-- The two-phase sweep. phase1 is the probe's trigger point, phase2 the main capture's;
-- they are independent, so the failing FRACTION is over the product space.
elseif cmd == 'appsweep' then
  local ids = {'v44e', 'v44d'}
  if id ~= 'both' then ids = {id} end
  local n1 = tonumber(arg[3]) or 12
  local n2 = tonumber(arg[4]) or 12
  local _, span = wire(id == 'both' and 'v44e' or id)
  local j, a, b
  for j = 1, table.getn(ids) do
    local vid = ids[j]
    local want = WANT[vid]
    local nbad, ntot, kinds, ks, nk = 0, 0, {}, {}, 0
    local first = nil
    for a = 0, n1 - 1 do
      for b = 0, n2 - 1 do
        local res = app_capture(vid, {span * a / n1, span * b / n2, span * b / n2}, {})
        ntot = ntot + 1
        local fmt = res and res.fmt or 'none'
        local bd  = res and res.baud or nil
        if not (res ~= nil and fmt == want and bd == BAUD) then
          nbad = nbad + 1
          local key = string.format('%s @ %s Bd', fmt, tostring(bd))
          if kinds[key] == nil then nk = nk + 1; ks[nk] = key; kinds[key] = 0 end
          kinds[key] = kinds[key] + 1
          if first == nil and res ~= nil then
            first = string.format('ph1=%.3f ph2=%.3f -> %s @ %s, %d B, %d bad (%d int), run %d',
                                  span * a / n1, span * b / n2, fmt, tostring(bd),
                                  res.nf or 0, res.nbad or 0, res.nin or 0, res.run or 0)
          end
        end
      end
    end
    print(string.format('\n%s  full app path, %d x %d phase pairs: %d of %d MISREAD (%.1f %%)',
          vid, n1, n2, nbad, ntot, 100 * nbad / ntot))
    table.sort(ks)
    for a = 1, nk do print(string.format('    %-26s x%d', ks[a], kinds[ks[a]])) end
    if first then print('    first: ' .. first) end
  end
else
  print('usage: lua tools/repro_v44.lua [sweep|full|one|why|seeds|probe|half|halfsweep|imp|app|appsweep] [v44d|v44e|both] ...')
end

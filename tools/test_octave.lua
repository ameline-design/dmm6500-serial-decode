-- test_octave.lua -- THE PROBE IS AN OCTAVE OUT AND NOTHING CATCHES IT.
--
-- Run from the repo root:  lua tools/test_octave.lua
--
-- Pins the intermittent v44d / v44e misread measured on the instrument: an 8N2 (v44e) or
-- 8O1 (v44d) stream at 9600 Bd reported as 7N1 at 19200 Bd, with the bytes silently
-- wrong. From out/soak/2026-08-18T01-15-46 -- 55 laps, v44e failed 3 of them (5.5 %) --
-- the bench line is
--
--     format v44e   BAD  7N1 153 B (head 0), longest clean run 9, 35 bad (35 interior)
--         note: 8N1 also fits; chose 7N1 (the top 1 data bit(s) were 1 in every frame)
--     format v44d   BAD  7N1 153 B (head 0), longest clean run 8, 41 bad (41 interior)
--
-- and both reproduce here, digit for digit, including the two clean-run lengths that
-- differ per vector.
--
-- WHY IT IS A SEPARATE FILE AND NOT A CASE IN test_serial.lua. test_serial decodes ONE
-- capture per case at a sampling phase of its own choosing. This defect is not visible in
-- one capture: it needs the app's REAL rate-selection path, which takes up to three
-- captures, and it appears only for some capture START POINTS. So what is asserted here is
-- a FRACTION of a swept space, which is a different shape of test.
--
-- THE CHAIN, all three links measured offline (tools/repro_v44.lua):
--
--   1. sig_bittime() gets the bit time RIGHT on every pass -- q = 0.9989, snapped to 9600.
--      It is not the fit that is wrong.
--   2. ua_best_end() throws the correct fit away. ua_probe scores the fit over
--      ua_probe_n = 4000 samples, which at 1 MS/s is ~3 bytes; a capture that begins
--      mid-message puts ONE misaligned frame in that window, so ua_score = ngood - 3*nbad
--      goes to 2 - 3 = -1. `sc1 > 0` is then false, the whole protective branch is skipped
--      -- both the `failing` test and the 3x ua_alt_margin live inside it -- and control
--      reaches the final unguarded `return altT, altr`. The ratio-0.5 candidate wins on
--      6 > -1, i.e. on ONE NET FRAME AND NO MARGIN AT ALL.
--   3. At half the bit time an 8N1 frame samples data bit 7 at t0 + 8.25 T and the stop bit
--      at t0 + 9.5 T -- BOTH INSIDE THE SAME REAL CELL. So "the top data bit was 1 in every
--      error-free frame" is true by construction, not by observation: a frame is only
--      error-free when that cell reads 1, and bit 7 reads that same cell.
--      ua_refine_width() takes it as evidence and collapses 8N1 to 7N1, which is what turns
--      a flagged wrong answer into a confident one.
--
-- The two rate-selection passes are INDEPENDENTLY triggered, so link 2 has to happen twice
-- for the failure to reach the panel: pass 1 (21 % of start points) sizes the real capture
-- at 160 kS/s, and pass 2 must misfit as well (13.5 %), because a pass-2 fit of 19200
-- asks for 160 kS/s again and serial_app.tsp's octave defence only ever re-captures
-- DOWNWARD. Joint 2.5 % against the bench's 5.5 %.

dofile('tools/mock_display.lua')     -- hostile display + file mock, object census
dofile('tools/gen_serial.lua')       -- waveform generator, dmm/buffer mock, decode core
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

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
  sdec.widths_any = false
end

-- ---------------------------------------------------------------------------
-- The stimulus: the arb the SDG actually plays, rebuilt rather than read.
--
-- out/ is not published (.gitignore), so reading out/vectors/v44e.bin would make this
-- suite pass vacuously on a fresh clone. It is built exactly as tools/make_vectors.lua
-- builds it -- hello{baud = 9600, fs = 100000, ...} -- and then put through the SAME 16-bit
-- codeword round trip the file imposes, so the volts here are the volts the generator
-- reconstructs. The manifest checksums confirm the two agree: v44e 1686873953,
-- v44d 1487963536, both 2158 points.
-- ---------------------------------------------------------------------------
local ARB_FS  = 100000               -- manifest srate_sa_s for both vectors
local ARB_FSV = 5.0                  -- AMP 10 Vpp
local BAUD    = 9600

local HB, HN = GEN_BYTES('Hello, World!')

local function arb(o)
  local rd, ts, nc, n = GEN({bytes = HB, baud = BAUD, fs = ARB_FS,
                             nbits = o.nbits, par = o.par, nstop = o.nstop})
  local v, i = {}, nil
  for i = 1, n do v[i] = GEN_VOLTS(GEN_CODE(rd[i], ARB_FSV, 0), ARB_FSV, 0) end
  return v, n
end

-- ---------------------------------------------------------------------------
-- One DMM capture of the LOOPING arb, started at an arbitrary point in it.
--
-- The generator renders 10.41667 arb points per bit and the DMM samples independently, so
-- this is a resampling with a sub-bit phase -- and `off` past the first byte gives the
-- partial leading frame a real capture always has. Levels are the bench's measured
-- -0.020 / 3.260 V, which is what puts thr at the 1.63 the panel reports.
-- ---------------------------------------------------------------------------
local function dmm_capture(v, na, off, fs, n)
  local rd, j = {}, nil
  local step = ARB_FS / fs
  local mod, floor = math.fmod, math.floor
  for j = 1, n do
    local x  = mod(off + (j - 1) * step, na)
    local i0 = floor(x)
    local a  = v[i0 + 1]
    local b  = v[mod(i0 + 1, na) + 1]
    rd[j] = -0.020 + (a + (b - a) * (x - i0)) * (3.280 / 3.300)
  end
  return rd, n
end

local function analyse(rd, n, fs)
  clearforce()
  sdec.acq_fs, sdec.fs = fs, fs
  if not sdec.sig_levels(rd, n) then return false end
  sdec.sig_edges(rd, n)
  sdec.sig_idle(rd, n)
  return true
end

local PN = {'N', 'E', 'O'}
local function fmtname(r)
  if r == nil then return '<none>' end
  return string.format('%d%s%d', r.nbits or 0, PN[(r.par or 0) + 1], r.nstop or 0)
end

local function longest_clean(r)
  local run, best, i = 0, 0, nil
  if r == nil then return 0 end
  for i = 1, r.nf do
    if r.errs[i] == nil then run = run + 1; if run > best then best = run end
    else run = 0 end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- serial_app.tsp's autoset(), offline: probe at 1 MS/s, capture at pick_fs(that, 8),
-- then the octave defence, which re-captures only when the second pass's own baud rate
-- wants a LOWER sample rate than the one it ran at.
--
-- Each pass gets its own start point, because each is a separately triggered capture.
-- ---------------------------------------------------------------------------
local NCAP = 20000
local function autoset(v, na, ph)
  local function onepass(fs, off)
    local rd, n = dmm_capture(v, na, off, fs, NCAP)
    if not analyse(rd, n, fs) then return false end
    return sdec.decode_from(rd, n), sdec.baud
  end

  -- The probe walks sdec.probe_fs until something frames, because 20000 samples at 1 MS/s is
  -- 20 ms and cannot hold a frame at the bottom of the range. Modelling only the top rung
  -- turns a start point the app handles on the second rung into a fake refusal.
  local ladder = sdec.probe_fs or {1000000, 100000, 10000}
  local ok1, b1, t = false, nil, 0
  while t < table.getn(ladder) do
    t = t + 1
    ok1, b1 = onepass(ladder[t], ph[1])
    if ok1 or sdec.baud_probe ~= nil then break end
  end
  if not ok1 then b1 = sdec.baud_probe end
  if b1 == nil then return nil end
  local want = sdec.pick_fs(b1, 8)
  if want >= ladder[t] and ok1 then return sdec.res, sdec.baud, sdec.fmt_note end

  local ok2, b2 = onepass(want, ph[2])
  if not ok2 then return nil end
  if b2 ~= nil and b2 > 0 then
    local w2 = sdec.pick_fs(b2, 8)
    if w2 ~= nil and w2 < want then
      if not onepass(w2, ph[3] or ph[2]) then return nil end
    end
  end
  return sdec.res, sdec.baud, sdec.fmt_note
end

-- The two vectors, with what the panel must say.
--
-- v44e is 8N2 on the wire and 8N1 is the CORRECT report: the stop-bit count is not
-- observable, a second stop bit being a bit time of idle that the framer already tolerates
-- (uart_decode.tsp:117). So the claim is not "detect 8N2", it is "read the bytes and
-- report the format honestly", which is exactly what a 7N1 at 19200 fails to do.
local CASES = {
  {id = 'v44e', opt = {nstop = 2},           want = '8N1', nbad = 35, run = 9,
   bench = '7N1 153 B, 35 bad, longest clean run 9'},
  {id = 'v44d', opt = {nbits = 8, par = 2},  want = '8O1', nbad = 41, run = 8,
   bench = '7N1 153 B, 41 bad, longest clean run 8'},
}

-- A start point INSIDE the message, which is what a real capture of a busy line has and
-- what puts a misaligned frame in the 4000-sample probe window. Measured: every failing
-- start point lies in the message body (arb points 208..1948); starts in the 40-bit idle
-- at the loop seam anchor cleanly and always decode.
local MIDMSG = 539.5

-- ============================================================================
print('A  the whole panel path, at a capture start inside the message')
-- ============================================================================
local ci
for ci = 1, table.getn(CASES) do
  local c = CASES[ci]
  local v, na = arb(c.opt)
  local r, baud, note = autoset(v, na, {MIDMSG, MIDMSG, MIDMSG})
  local got = fmtname(r)
  local detail = string.format('got %s @ %s Bd, %d B, %d bad, longest clean run %d (bench: %s)',
                               got, tostring(baud), (r and r.nf) or 0, (r and r.nbad) or 0,
                               longest_clean(r), c.bench)
  check(string.format('%s reads as %s at %d Bd, not 7N1 at 19200', c.id, c.want, BAUD),
        r ~= nil and got == c.want and baud == BAUD, detail)
  -- THE NOTE IS THE TELL, and it is worth its own assertion: ua_refine_width only says
  -- this when it has collapsed a width, and on an 8-bit ASCII stream at the right bit
  -- time bit 7 is 0 in every frame, so it can never say it. Seeing it means the bit time
  -- was halved, whatever the format line ended up reading.
  check(string.format('%s: no "top data bit was 1 in every frame" collapse', c.id),
        not has(note, 'were 1 in every frame'), string.format('note %q', tostring(note)))
end

-- ============================================================================
print('\nB  and across the whole loop, not just one lucky start')
-- ============================================================================
-- The capture can begin anywhere in the 21.58 ms arb loop and the two passes are
-- independent, so the honest measure is the fraction of the PRODUCT space that misreads.
--
-- THE GRID MATTERS AND 16 IS NOT ARBITRARY. The failing set is finely structured -- it is
-- the start points that leave a misaligned frame inside the 4000-sample probe window -- so
-- a coarse grid can step straight over it: measured v44e / v44d over the same product
-- space, 10x10 gave 0.0 % / 0.0 %, 16x16 gives 5.9 % / 3.1 %, 20x20 2.5 % / 0.8 % and
-- 24x24 3.6 % / 1.2 %. The instrument measured 5.5 % for v44e over 55 laps. So the NUMBER
-- here is a sampling of a rate, not the rate, and only its being non-zero is an assertion.
-- 10x10 is the trap: it passes today, against a defect the bench sees every twentieth lap.
local NGRID = 16
for ci = 1, table.getn(CASES) do
  local c = CASES[ci]
  local v, na = arb(c.opt)
  local nbad, ntot, worst = 0, 0, nil
  local a, b
  for a = 0, NGRID - 1 do
    for b = 0, NGRID - 1 do
      local r, baud = autoset(v, na, {na * a / NGRID, na * b / NGRID, na * b / NGRID})
      ntot = ntot + 1
      if not (r ~= nil and fmtname(r) == c.want and baud == BAUD) then
        nbad = nbad + 1
        if worst == nil then
          worst = string.format('first at start %.1f/%.1f -> %s @ %s Bd',
                                na * a / NGRID, na * b / NGRID, fmtname(r), tostring(baud))
        end
      end
    end
  end
  check(string.format('%s: no capture start in the loop misreads (%d of %d = %.1f %% did)',
                      c.id, nbad, ntot, 100 * nbad / ntot), nbad == 0, worst or '')
end

-- ============================================================================
print('\nC  the cause: a fit that scores badly is still the fit')
-- ============================================================================
-- Unit-level, so a fix can be aimed rather than guessed at. The bit time sig_bittime
-- proposes here is CORRECT to four figures and snaps to a standard rate; its probe score
-- is <= 0 only because the truncated probe window holds a misaligned head frame. A
-- rescaling that beats that by a couple of frames is not evidence about the wire, and
-- ua_best must not take it -- the same conclusion ua_best_end already reaches, and states
-- at length, for the `altsc <= 0` case.
for ci = 1, table.getn(CASES) do
  local c = CASES[ci]
  local v, na = arb(c.opt)
  local fi
  for fi = 1, 2 do
    local fs = ({1000000, 160000})[fi]
    local rd, n = dmm_capture(v, na, MIDMSG, fs, NCAP)
    analyse(rd, n, fs)
    local Tfit = sdec.sig_bittime()
    local st = sdec.ua_best_begin(rd, n, Tfit)
    while sdec.ua_best_probe(st) do end
    local T, ratio = sdec.ua_best_end(st)
    local Ttrue = fs / BAUD
    -- Guard the premise first: if the fit were wrong this test would be asserting
    -- something else entirely.
    check(string.format('%s at %g kS/s: sig_bittime fits the TRUE bit time (q=%.4f)',
                        c.id, fs / 1000, sdec.fitq),
          Tfit ~= nil and math.abs(Tfit / Ttrue - 1) < 0.01,
          string.format('Tfit %.4f, true %.4f', Tfit or -1, Ttrue))
    check(string.format('%s at %g kS/s: ua_best keeps it despite sc1=%s (rival scored %s)',
                        c.id, fs / 1000, tostring(st.sc1), tostring(st.altsc)),
          T ~= nil and math.abs(T / Ttrue - 1) < 0.01,
          string.format('chose T=%.4f = %.3f x true, ratio %s -> %s Bd',
                        T or -1, (T or 0) / Ttrue, tostring(ratio),
                        tostring(sdec.sig_snap(fs / (T or 1)))))

    -- WHICH PULSES ARE ALLOWED TO VOUCH FOR A SUB-MULTIPLE. Named separately because C above
    -- only says the answer came out wrong; this says why, and it is one line's worth of fix.
    --
    -- A sub-multiple gate that asks "is any pulse an ODD number of candidate bit times" must
    -- ask it of BIT RUNS only. sig_fit already draws that line and states the reason -- a
    -- multiple beyond sdec.maxmult is inter-byte idle, not a run of bits, so it carries no
    -- timing information -- and the inter-message gap here is 42 bit times, whose length is
    -- set by the arb's loop seam and the capture phase rather than by the format. At a quarter
    -- of the true bit time every real pulse is an even multiple and that ONE idle run comes out
    -- at k = 169, odd, which is enough to vouch for the candidate on its own.
    if sdec.ua_submultiple ~= nil then
      local nodd, noddreal, worst, i = 0, 0, nil, nil
      local Tq = Tfit * 0.25
      for i = 1, sdec.nw do
        local k = math.floor(sdec.w[i] / Tq + 0.5)
        if k >= 1 and math.fmod(k, 2) == 1 then
          nodd = nodd + 1
          if k <= sdec.maxmult then noddreal = noddreal + 1
          elseif worst == nil then
            worst = string.format('k=%d from a %.1f-bit run', k, sdec.w[i] / Tfit)
          end
        end
      end
      -- The gate must reject a quarter of the true bit time. It does so only when NO pulse
      -- looks odd, so an idle run vouching for it is exactly the failure.
      check(string.format('%s at %g kS/s: only bit runs may vouch for a sub-multiple',
                          c.id, fs / 1000),
            sdec.ua_submultiple(Tq) or noddreal > 0,
            string.format('quarter-bit candidate cleared the gate on %d odd multiple(s), %d of them real bit runs%s',
                          nodd, noddreal, worst and ('; ' .. worst) or ''))
    end
  end
end

-- ============================================================================
print('\nD  the guard is what is doing the work, and must keep doing it')
-- ============================================================================
-- WITHOUT THIS, A AND B ARE UNFALSIFIABLE. They assert an outcome; nothing in them says the
-- outcome comes from the sub-multiple gate rather than from the reproduction being too gentle
-- to provoke anything. So the gate is stubbed out and the bench signature must come back
-- EXACTLY, both vectors, including the two clean-run lengths that differ between them.
--
-- STUBBING THE PREDICATE, not a tunable, because the tunable is not the contract. The gate
-- has already been a median test (sdec.medratio) and an odd-multiple test
-- (sdec.submult_minpulses) within one session; both are named below and an unrecognised
-- successor makes this case fail loudly rather than pass vacuously -- if none of the names
-- is present, the misread must be there for real, which is what HEAD does.
local GATES = {'ua_submultiple', 'ua_med_wrong'}
for ci = 1, table.getn(CASES) do
  local c = CASES[ci]
  local v, na = arb(c.opt)
  local keep, gi, found = {}, nil, 0
  for gi = 1, table.getn(GATES) do
    if sdec[GATES[gi]] ~= nil then
      keep[GATES[gi]] = sdec[GATES[gi]]
      sdec[GATES[gi]] = function() return false end
      found = found + 1
    end
  end
  local r, baud = autoset(v, na, {MIDMSG, MIDMSG, MIDMSG})
  for gi = 1, table.getn(GATES) do
    if keep[GATES[gi]] ~= nil then sdec[GATES[gi]] = keep[GATES[gi]] end
  end
  local got = string.format('%s @ %s Bd, %d bad, longest clean run %d (%d gate(s) stubbed)',
                            fmtname(r), tostring(baud), (r and r.nbad) or 0,
                            longest_clean(r), found)
  check(string.format('%s: stub the sub-multiple gate and the bench misread returns', c.id),
        r ~= nil and fmtname(r) == '7N1' and baud == 2 * BAUD
          and r.nbad == c.nbad and longest_clean(r) == c.run,
        string.format('%s   (bench: %s)', got, c.bench))
end

-- ============================================================================
print('\nE  half a bit time may not manufacture its own evidence')
-- ============================================================================
-- LINK 3, WHICH ua_med_wrong DOES NOT ADDRESS -- it stops the auto path REACHING a halved
-- bit time; it does not make the halved reading honest once something else gets there. A
-- forced rate does, and it is reachable from the panel (Options > Baud Rate) and from a
-- stale auto-lock.
--
-- decode_from's cross-check DOES warn on the rate itself ('bytes may be WRONG if the device
-- runs at 9600 baud, 2x the 19200 you set'), which is the right behaviour and is asserted
-- here so this case cannot be read as claiming otherwise. What is NOT warned about is the
-- WIDTH: at half the bit time an 8N1 frame samples data bit 7 at t0 + 8.25 T and its stop
-- bit at t0 + 9.5 T, both inside the same real cell, so "the top data bit was 1 in every
-- error-free frame" is a tautology -- a frame is only error-free when that cell reads 1.
-- ua_refine_width takes the tautology as evidence and narrows the format on it, turning a
-- flagged 8N1 into a 7N1 whose values are also shifted. The guard it is missing is a test
-- that the always-one bit was observed INDEPENDENTLY of the stop bit that follows it.
for ci = 1, table.getn(CASES) do
  local c = CASES[ci]
  local v, na = arb(c.opt)
  local rd, n = dmm_capture(v, na, MIDMSG, 160000, NCAP)
  analyse(rd, n, 160000)
  sdec.force_baud = 2 * BAUD
  local ok = sdec.decode_from(rd, n)
  local r, note, rnote = sdec.res, sdec.fmt_note, sdec.rate_note
  sdec.force_baud = nil
  check(string.format('%s: a forced 2x rate is still flagged as a rate error', c.id),
        has(rnote, 'may be WRONG'), string.format('rate_note %q', tostring(rnote)))
  check(string.format('%s: and no width collapse on a top bit the stop bit already proved',
                      c.id),
        not has(note, 'were 1 in every frame'),
        string.format('%s %s, %d B, %d bad, run %d; note %q', ok and 'ok' or 'refused',
                      fmtname(r), (r and r.nf) or 0, (r and r.nbad) or 0, longest_clean(r),
                      tostring(note)))
end

print(string.format('\n%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

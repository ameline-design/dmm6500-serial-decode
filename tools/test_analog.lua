-- test_analog.lua -- the SAME cases the bench runs, swept over sampling phase, edge jitter and
-- amplitude noise, at the sample rates the app itself selects.
--
-- WHY THIS FILE EXISTS. The 2x baud misfit (#29) failed on the instrument two laps in seven while
-- 884 offline assertions stayed green, and the reason was not subtlety in the decoder -- it was
-- that the offline suite and the bench were not running the same experiment:
--
--   * SAMPLE RATE. Every offline case names a round fs by hand -- both 8N2 cases used 100000, i.e.
--     10.42 samples/bit -- but pick_fs(9600, 8) returns 80000, i.e. 8.33. That is not cosmetic: the
--     app's ladder delivers ~8.33 sa/bit at every standard rate from 300 to 38400, which puts the
--     halved (2x baud) candidate at 4.17 sa/bit, just 6 % above ua_plausible's 3.92 floor. At the
--     tested 10.42 the halved candidate sits at 5.21, a comfortable 33 % clear. The suite only ever
--     tested the safe side of the cliff the app actually operates on. So fs comes from pick_fs here,
--     never from a literal.
--   * SAMPLING PHASE. GEN_RENDER takes opts.phase and defaults it to 0.37; NO test in this repo
--     ever varied it, so all 884 assertions ran at one arbitrary sub-bit alignment. A real capture
--     starts wherever the trigger fired.
--   * JITTER AND NOISE. Left at 0 in almost every case. The bench signal is quantised twice --
--     the generator renders edges on its own 10 us grid at 10.4167 samples/bit, then the DMM
--     resamples at 12.5 us -- and GEN_RENDER's own comment explains that per-edge displacement is
--     the impairment that attacks the baud detector at its weakest point, in a way amplitude noise
--     cannot reproduce.
--
-- The standing rule this encodes: the only differences between an offline case and the same case on
-- the instrument should be the Lua version and analog effects that cannot be simulated. Anything
-- else is a gap where a defect can live, and #29 lived in exactly that gap.
--
-- Run from the repo root:  lua tools/test_analog.lua

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end

local PAYLOAD = 'Hello, World!'

-- The payload repeated to about the byte count a real frame capture returns, so the pulse-width
-- statistics the baud fit is computed from are the bench's and not a 13-byte sample of them.
local function reps(s, k)
  local t, n = {}, 0
  local i, j
  for i = 1, k do
    local b, nb = GEN_BYTES(s)
    for j = 1, nb do n = n + 1; t[n] = b[j] end
  end
  return t, n
end

-- One case, driven through the real signal chain. Returns detected baud, format string, byte text.
local function decode_case(o)
  local rd, ts, nc, nsmp = GEN(o)
  sdec.acq_fs = o.fs
  sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  -- LEFTOVER PINS POISON THE NEXT CASE, and a swept matrix is where that does the most damage: one
  -- forced width silently converts every later case into a forced-format decode that cannot fail.
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.decode_from(rd, nsmp)
  local r = sdec.res
  if r == nil then return nil, '-', '' end
  local p = 'N'
  if r.par == 1 then p = 'E' elseif r.par == 2 then p = 'O' end
  return sdec.baud, string.format('%d%s', r.nbits or 0, p), GEN_STR(r.vals, r.nf)
end

-- Does the decoded text contain the payload, allowing for a partial first frame? A capture that
-- starts mid-stream loses at most one byte, and demanding an exact match would fail honestly.
local function carries(txt, want)
  return txt ~= nil and string.find(txt, want, 1, true) ~= nil
end

-- The formats the bench's FORMATS suite plays, with the width+parity the panel must report. The
-- stop count is deliberately absent: a second stop bit is a bit of idle and is not observable, so
-- 8N2 must read as 8N1 -- which is exactly the case that failed on the bench.
local FORMATS = {
  {name = '8N1', nbits = 8, par = 0, nstop = 1, want = '8N'},
  {name = '7E1', nbits = 7, par = 1, nstop = 1, want = '7E'},
  {name = '7O1', nbits = 7, par = 2, nstop = 1, want = '7O'},
  {name = '8E1', nbits = 8, par = 1, nstop = 1, want = '8E'},
  {name = '8O1', nbits = 8, par = 2, nstop = 1, want = '8O'},
  {name = '8N2', nbits = 8, par = 0, nstop = 2, want = '8N'},
}

local NPHASE = 8          -- sub-bit alignments per case; 8 is enough to walk a whole bit cell
local wrong = {}          -- one entry per wrong answer, for the summary

local function record(tag, baud, want_baud, fmt, want_fmt, txt)
  local why = nil
  if baud == nil then
    why = 'refused'
  elseif math.abs(baud / want_baud - 1) > 0.02 then
    local ratio = baud / want_baud
    if math.abs(ratio - 2) < 0.1 then why = string.format('OCTAVE: %.0f Bd (2x)', baud)
    elseif math.abs(ratio - 0.5) < 0.05 then why = string.format('HALF: %.0f Bd', baud)
    else why = string.format('%.0f Bd', baud) end
  elseif fmt ~= want_fmt then
    why = string.format('read as %s', fmt)
  elseif not carries(txt, PAYLOAD) then
    why = 'bytes wrong'
  end
  if why ~= nil then wrong[table.getn(wrong) + 1] = tag .. ': ' .. why end
  return why == nil
end

-- ============================================================================
print('the format matrix at 9600, swept over phase x jitter x noise')
-- fs FROM THE APP, not from a literal -- this is the whole point of the file.
-- ============================================================================
local FS9600 = sdec.pick_fs(9600, 8)
check('pick_fs(9600, 8) is 80000, i.e. 8.33 samples/bit -- the rate the app really uses',
      FS9600 == 80000, string.format('got %s', tostring(FS9600)))

local by152 = reps(PAYLOAD, 12)          -- 156 bytes, about a real frame capture
local nfmt = table.getn(FORMATS)
local fi, ph, ji, ni
local IMPAIR = {{0, 0}, {0.05, 0}, {0, 0.05}, {0.05, 0.05}, {0.10, 0.02}}
local nimp = table.getn(IMPAIR)
local nrun = 0
for fi = 1, nfmt do
  local f = FORMATS[fi]
  local bad = 0
  for ii = 1, nimp do
    local jit, nz = IMPAIR[ii][1], IMPAIR[ii][2]
    for ph = 0, NPHASE - 1 do
      local baud, fmt, txt = decode_case({
        bytes = by152, baud = 9600, fs = FS9600, nbits = f.nbits, par = f.par,
        nstop = f.nstop, phase = ph / NPHASE, jitter = jit, noise = nz})
      nrun = nrun + 1
      if not record(string.format('%s@9600 phase %.2f jitter %.2f noise %.2f',
                                  f.name, ph / NPHASE, jit, nz),
                    baud, 9600, fmt, f.want, txt) then
        bad = bad + 1
      end
    end
  end
  check(string.format('%s survives all %d phase/jitter/noise combinations at %d kS/s',
                      f.name, nimp * NPHASE, FS9600 / 1000), bad == 0,
        bad == 0 and '' or string.format('%d of %d wrong', bad, nimp * NPHASE))
end

-- ============================================================================
print('every standard rate, at its OWN pick_fs, swept over phase')
-- The ladder is built to deliver ~8.33 sa/bit at every rate, so the halved candidate sits ~6 %
-- above the plausibility floor at ALL of them, not just at 9600. If the octave error is rate
-- dependent this is where it shows.
-- ============================================================================
local RATES = {300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200}
local nr = table.getn(RATES)
local ri
for ri = 1, nr do
  local b = RATES[ri]
  local fs = sdec.pick_fs(b, 8)
  -- Enough bytes to fill a comparable window at every rate, and a floor so the slow rates still
  -- carry enough frames for the fit to mean anything.
  local nby = 12
  local by = reps(PAYLOAD, nby)
  local bad = 0
  for ph = 0, NPHASE - 1 do
    local baud, fmt, txt = decode_case({
      bytes = by, baud = b, fs = fs, nstop = 1, phase = ph / NPHASE,
      jitter = 0.05, noise = 0.02})
    nrun = nrun + 1
    if not record(string.format('8N1@%d phase %.2f', b, ph / NPHASE),
                  baud, b, fmt, '8N', txt) then
      bad = bad + 1
    end
  end
  check(string.format('%6d Bd at %g kS/s (%.2f sa/bit) survives all %d phases',
                      b, fs / 1000, fs / b, NPHASE), bad == 0,
        bad == 0 and '' or string.format('%d of %d wrong', bad, NPHASE))
end

-- ============================================================================
print('8N2 at every rate -- the format that failed on the bench')
-- The stop-bit count is NOT the mechanism, and an earlier version of this comment said it was.
-- Measured: 8O1 (one stop bit) misfits where 8N2 does not, the reverse of that prediction, and
-- med/T is 2.00 for this payload at both formats. 8N2 is the more frequent BENCH failure because its
-- entry point is the probe octave, which needs two independent misfits, not because of its stop bit.
-- Kept as a case because it is what the bench fails on, not because 8N2 is inherently susceptible.
-- ============================================================================
for ri = 1, nr do
  local b = RATES[ri]
  local fs = sdec.pick_fs(b, 8)
  local by = reps(PAYLOAD, 12)
  local bad = 0
  for ph = 0, NPHASE - 1 do
    local baud, fmt, txt = decode_case({
      bytes = by, baud = b, fs = fs, nstop = 2, phase = ph / NPHASE,
      jitter = 0.05, noise = 0.02})
    nrun = nrun + 1
    if not record(string.format('8N2@%d phase %.2f', b, ph / NPHASE),
                  baud, b, fmt, '8N', txt) then
      bad = bad + 1
    end
  end
  check(string.format('%6d Bd 8N2 reads as 8N at the true rate, all %d phases', b, NPHASE),
        bad == 0, bad == 0 and '' or string.format('%d of %d wrong', bad, NPHASE))
end

-- ============================================================================
print('the probe\'s own conditions')
-- The probe is a SEPARATE decode at a rate off sdec.probe_fs, and its answer chooses the full
-- capture's sample rate. serial_app.tsp:216-241 records that it can be an octave out -- "two of
-- ten identical 9600-baud captures fitted 19200" -- and the recovery there is keyed on the SECOND
-- pass disagreeing with it, so a probe error the second pass repeats is never corrected. Nothing
-- offline modelled the probe's view until now.
-- ============================================================================
local PFS = sdec.probe_fs or {1000000, 100000, 10000}
local pfs1 = PFS[1]
local byp = reps(PAYLOAD, 20)
local bad = 0
local nprobe = 0
for ii = 1, nimp do
  local jit, nz = IMPAIR[ii][1], IMPAIR[ii][2]
  for ph = 0, NPHASE - 1 do
    local baud, fmt, txt = decode_case({
      bytes = byp, baud = 9600, fs = pfs1, n = 20000, nstop = 2,
      phase = ph / NPHASE, jitter = jit, noise = nz})
    nrun = nrun + 1
    nprobe = nprobe + 1
    -- A REFUSAL IS ALLOWED HERE and a WRONG RATE IS NOT. The probe legitimately cannot frame a
    -- byte at the bottom of the range (serial_app.tsp:172-180 keeps its measured rate anyway), so
    -- nil is honest; an octave is what puts a wrong sample rate on the real capture.
    if baud ~= nil and math.abs(baud / 9600 - 1) > 0.02 then
      bad = bad + 1
      wrong[table.getn(wrong) + 1] = string.format(
        'PROBE 8N2@9600 %g kS/s phase %.2f jitter %.2f noise %.2f: %.0f Bd',
        pfs1 / 1000, ph / NPHASE, jit, nz, baud)
    end
  end
end
check(string.format('the probe never returns a WRONG rate over %d impaired phases at %g kS/s',
                    nprobe, pfs1 / 1000), bad == 0,
      bad == 0 and '' or string.format('%d wrong', bad))

-- ============================================================================
print('the capture window opens at an arbitrary sample')
-- THE VARIABLE THAT WAS MISSING, and the one that reproduces #29.
--
-- Every other case in this repo -- all 884 assertions -- begins on the generator's clean 20-bit
-- lead idle. A triggered capture does not: it opens wherever the trigger fired, part way through
-- a pulse, so the FIRST width in the array is a fraction of a bit time rather than a multiple of
-- one. uart_decode.tsp:158-160 states the consequence: sig_bittime "fits the greatest common bit
-- period of the observed pulses, so it errs SHORT: one narrow glitch is enough to pull the fit to
-- a sub-multiple". A truncated leading pulse is that glitch, arriving on every real capture.
--
-- MEASURED: 8O1 at 9600 on an 80 kS/s window takes the octave at start offset 25/32, with 9600
-- correct at 24/32 and 26/32, and identically with and without jitter and noise --
--
--   start  baud   fmt  nf   bad  T      wmed   wmed/T  fitq    fitratio  baud_note
--   0.750  9600   8O   169  3    8.333  16.67  2.00    ~1.0    1         nil
--   0.781  19200  7N   338  90   4.167  16.67  4.00    ~1.0    0.5       nil
--   0.812  9600   8O   168  0    8.333  16.67  2.00    ~1.0    1         nil
--
-- fitq is ~1.0 at BOTH bit times, so the qgate cannot separate them -- every pulse that is a
-- multiple of T is also a multiple of T/2. What DOES separate them is wmed/T: 2.00 for the truth
-- and 4.00 for the halving, against ua_fit_corrupt's own measured "med/Tfit is 2.0 for every
-- healthy capture" with its 2.5 threshold -- a test applied to the fit but never to a candidate.
-- ============================================================================

-- The cells the ARB actually plays, with the loop repeated so each seam carries a 40-bit idle run.
-- Written out rather than reusing GEN because GEN emits ONE message and the wire carries the loop.
local function loopcells(nbits, par, nstop, nloops)
  local by, nb = GEN_BYTES(PAYLOAD)
  local c, n = {}, 0
  local L, i, k
  for L = 1, nloops do
    for i = 1, 20 do n = n + 1; c[n] = 1 end
    for i = 1, nb do
      n = n + 1; c[n] = 0                                   -- start bit
      local t = by[i]
      local ones = 0
      for k = 1, nbits do
        local bit = math.fmod(t, 2)
        n = n + 1; c[n] = bit
        ones = ones + bit
        t = math.floor(t / 2)
      end
      if par ~= 0 then
        local pe = math.fmod(ones, 2)
        n = n + 1
        if par == 1 then c[n] = pe else c[n] = 1 - pe end
      end
      for k = 1, nstop do n = n + 1; c[n] = 1 end
      if i < nb then for k = 1, 2 do n = n + 1; c[n] = 1 end end
    end
    for i = 1, 20 do n = n + 1; c[n] = 1 end
  end
  return c, n
end

-- Render long, then take a window that opens at an arbitrary sample -- what a trigger does.
--
-- nloops IS SWEPT, not fixed, and that is not padding. The offset that misfits depends on where the
-- window lands relative to the frame structure in ABSOLUTE samples, so changing the rendered length
-- moves every failing offset: a first draft of this test used 16 loops, sampled 32 offsets, and
-- passed -- while the same code at 26 loops reproduced the octave at 25/32. A test that only passes
-- because its geometry missed the hole is the thing this file exists to stop.
local function window_case(f, fs, startfrac, jitter, noise, nloops)
  local c, nc = loopcells(f.nbits, f.par, f.nstop, nloops)
  local rd, ts, ncc, ns = GEN_RENDER(c, nc,
      {baud = 9600, fs = fs, phase = 0.37, jitter = jitter, noise = noise})
  local want = math.floor(ns / 2)
  local s0 = 1 + math.floor(startfrac * (ns - want))
  local w, n = {}, 0
  local i
  for i = s0, s0 + want - 1 do n = n + 1; w[n] = rd[i] end
  sdec.acq_fs = fs
  sdec.sig_levels(w, n)
  sdec.sig_edges(w, n)
  sdec.sig_idle(w, n)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.decode_from(w, n)
  local r = sdec.res
  if r == nil then return nil, '-', '' end
  local p = 'N'
  if r.par == 1 then p = 'E' elseif r.par == 2 then p = 'O' end
  return sdec.baud, string.format('%d%s', r.nbits or 0, p), GEN_STR(r.vals, r.nf)
end

local NOFF = 32
local LOOPS = {16, 21, 26}
local nloopc = table.getn(LOOPS)
local oi, li
for fi = 1, nfmt do
  local f = FORMATS[fi]
  local bad = 0
  local worst = ''
  for li = 1, nloopc do
    for oi = 0, NOFF - 1 do
      local baud, fmt, txt = window_case(f, FS9600, oi / NOFF, 0, 0, LOOPS[li])
      nrun = nrun + 1
      local tag = string.format('%s@9600 %d loops, window opens at %.3f',
                                f.name, LOOPS[li], oi / NOFF)
      if not record(tag, baud, 9600, fmt, f.want, txt) then
        bad = bad + 1
        if worst == '' and baud ~= nil then
          worst = string.format('%.0f Bd as %s at %d loops offset %.3f',
                                baud, fmt, LOOPS[li], oi / NOFF)
        end
      end
    end
  end
  check(string.format('%s: the rate is right wherever the window opens (%d offsets x %d lengths)',
                      f.name, NOFF, nloopc), bad == 0,
        bad == 0 and '' or string.format('%d of %d wrong; first: %s',
                                         bad, NOFF * nloopc, worst))
end

-- ============================================================================
print('the 7-bit shuffled payload, capture starting at an arbitrary sample')
-- THE CASE THE SOAK FOUND AND EVERY OFFLINE SUITE MISSED (r06, 2026-08-19).
--
-- ua_refine_parity's non-strict branch re-decodes at 7 bits and returned a result carrying
-- nbits/par/nstop/invert all nil, because ua_run takes the format as ARGUMENTS and records none of
-- it -- the search loop stamps the winner, and this branch copied only score and headsusp. The
-- branch whose entire purpose is to change the format returned one with none. It surfaced as a
-- raise in ua_note_fmt's %d, so capture() died DESCRIBING a decode that had succeeded, and the
-- bench filed 'no bytes decoded' -- a symptom pointing at the wrong subsystem entirely.
--
-- WHY THE EXISTING SWEEPS ABOVE CANNOT REACH IT. They play 'Hello, World!', and cleanly generated
-- text gives a UNANIMOUS parity vote, which takes the strict in-place path where r already has the
-- fields. Reaching the broken branch needs a vote of 232 of 233 rather than 233 of 233: one
-- dissenting frame, which is what a capture opening mid-byte on a GAPLESS 7E1 stream produces.
-- Three conditions have to coincide -- 7-bit random payload, no inter-frame gap, arbitrary start --
-- and no other case in this repo has all three.
--
-- THE ASSERTION IS AN INVARIANT, NOT AN ABSENCE OF A CRASH: a result handed back by the decoder
-- always carries the format that produced it. That holds whichever branch ran, so it also covers
-- the sibling call sites (ua_refine_width and the forced path both stamp; audited 2026-08-19).
-- ============================================================================

-- r06..r11's payloads, built here rather than read from out/vectors/: those files are generated
-- output, so a gate that needs them fails on a fresh clone for a reason that is not a defect.
-- Fisher-Yates over two copies of 0..127 on the suite's own PRNG -- see make_vectors.lua, which
-- must produce the same bytes from the same seed.
local function shuffled7(seed)
  GEN_RESEED(seed)
  local by, nb = {}, 0
  local r, v, i
  for r = 1, 2 do
    for v = 0, 127 do nb = nb + 1; by[nb] = v end
  end
  for i = nb, 2, -1 do
    local j = math.floor(GEN_RAND() * i) + 1
    if j > i then j = i end
    by[i], by[j] = by[j], by[i]
  end
  return by, nb
end

-- One capture from a looping ARB: read `want` samples starting at s0, WRAPPING, because the
-- generator plays the waveform on repeat and a trigger lands wherever it lands. The wrap is not
-- decoration -- without it the offsets near the end of the payload are the only ones that never
-- get tested, and the seam is exactly where the head is least aligned.
local function startphase_case(rd, ns, fs, s0, want)
  local w, n = {}, 0
  local i
  for i = 0, want - 1 do
    n = n + 1
    w[n] = rd[math.mod(s0 + i, ns) + 1]
  end
  sdec.acq_fs = fs
  sdec.sig_levels(w, n)
  sdec.sig_edges(w, n)
  sdec.sig_idle(w, n)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  local ok, why = pcall(function() return sdec.decode_from(w, n) end)
  return ok, why, sdec.res
end

-- The armed path's real yield, from the app's own function rather than a literal: LoopUntilEvent
-- keeps pretrig per cent of the buffer, so a completed capture is ~19000 of 20000 samples.
local WANT = sdec.n_deliv(sdec.n) or 19000
check('n_deliv is the armed yield, not the buffer depth',
      WANT < sdec.n, string.format('%d of %d', WANT, sdec.n))

-- WRAPPED, RATHER THAN INFERRED FROM sdec.res, and the difference decides whether this test can
-- fail at all. When the format is missing, ua_note_fmt raises INSIDE decode_from -- before
-- `sdec.res = r` -- so res stays nil and a check on it never sees the broken table. Worse, the
-- raise needs an alternative format to have survived scoring, so the same defect goes SILENT
-- whenever ua_alts came back empty: a result with no format, handed to the panel, no crash.
--
-- The wrapper sees the return value itself, so both paths are covered. `out ~= r` is an exact
-- discriminator for the branch under test: the strict path mutates r and returns it, every early
-- return returns r, and only the non-strict re-decode returns a DIFFERENT table.
local real_refine = sdec.ua_refine_parity
local nredecode, nilfmt, firstbad = 0, 0, ''
sdec.ua_refine_parity = function(r, rd, n, T)
  local out = real_refine(r, rd, n, T)
  if out ~= nil and r ~= nil and out ~= r then
    nredecode = nredecode + 1
    -- ALL FOUR, not just nbits: invert feeds the idle level the panel reports and nstop the format
    -- name, so a nil in any of them is a wrong answer waiting for a caller to read it.
    if out.nbits == nil or out.par == nil or out.nstop == nil or out.invert == nil then
      nilfmt = nilfmt + 1
      if firstbad == '' then
        firstbad = string.format('re-decode returned nbits=%s par=%s nstop=%s invert=%s',
                                 tostring(out.nbits), tostring(out.par),
                                 tostring(out.nstop), tostring(out.invert))
      end
    end
  end
  return out
end

-- STEPPED ACROSS THE WHOLE PAYLOAD, NOT DENSELY ACROSS THE FIRST FEW FRAMES, and that was measured
-- rather than assumed. A first version stepped 1 sample through 220 samples -- every sub-bit phase
-- of two whole frames -- and reached the non-strict branch ZERO times in 1320 starts. Which BYTES
-- land in the window is the determining variable, not the sub-bit phase: the dissent that makes the
-- vote 232-of-233 comes from the misaligned head, so it depends on the values there. Swept whole,
-- the hits cluster in a handful of payload regions (seed 7108 has 2 in 538 starts, seed 7109 has 16).
--
-- 250 samples is 2.4 frame times, so the sub-bit phase still walks ~0.4 of a bit per step and gets
-- covered incidentally. Measured: 18 re-decodes in 648 starts, against 21 in 1080 at step 150 and
-- 64 in 3228 at step 50 -- so this is the cheap end of a flat curve, not a lucky sample.
local STEP = 250
local SEEDS = {7106, 7107, 7108, 7109, 7110, 7111}
local nseed = table.getn(SEEDS)
local raised, firstraise = 0, ''
local nstart, npromote = 0, 0
local si
for si = 1, nseed do
  local by, nb = shuffled7(SEEDS[si])
  -- RENDERED ONCE PER SEED, outside the offset loop: the render is the expensive half and the
  -- window is a slice of it. r06's own opts, so this is the waveform the SDG plays.
  local rd, ts, nc, ns = GEN({bytes = by, nbits = 7, par = 1, baud = 9600, fs = 100000,
                              gap = 0, lead = 10, tail = 10, loop = true})
  local s0
  for s0 = 0, ns - 1, STEP do
    local ok, why, r = startphase_case(rd, ns, 100000, s0, WANT)
    nrun = nrun + 1
    nstart = nstart + 1
    if not ok then
      raised = raised + 1
      if firstraise == '' then
        firstraise = string.format('seed %d start %d: %s', SEEDS[si], s0, tostring(why))
      end
    elseif r ~= nil and r.nbits == 7 then
      npromote = npromote + 1
    end
  end
end
sdec.ua_refine_parity = real_refine        -- a wrapper left in place poisons every later case
check(string.format('%d mid-byte starts over %d 7E1 payloads: none raises', nstart, nseed),
      raised == 0, raised == 0 and '' or string.format('%d raised; first: %s', raised, firstraise))
check('every 7E1 re-decode carries the format that produced it (nbits, par, nstop, invert)',
      nilfmt == 0, nilfmt == 0 and '' or string.format('%d of %d incomplete; %s',
                                                       nilfmt, nredecode, firstbad))
-- THE TWO CHECKS ABOVE ARE VACUOUS WITHOUT THESE. A sweep in which no start offset ever reaches the
-- non-strict re-decode passes by not exercising the code at all -- which is exactly how the first
-- regression test written for this bug came to pass with the fix removed.
check('the non-strict 7E1 re-decode is reached, so the branch under test really ran',
      nredecode > 0, string.format('%d re-decodes over %d starts', nredecode, nstart))
check('the promotion to 7 bits reaches the result the panel reads',
      npromote > 0, string.format('%d of %d starts read 7 bits', npromote, nstart))

-- ============================================================================
print(string.format('\n%d passed, %d failed   (%d decodes swept)', pass, fail, nrun))
if table.getn(wrong) > 0 then
  print('\nevery wrong answer, so a rate can be read off rather than guessed:')
  local i
  local nw = table.getn(wrong)
  for i = 1, nw do
    if i <= 40 then print('  ' .. wrong[i]) end
  end
  if nw > 40 then print(string.format('  ... and %d more', nw - 40)) end
  print(string.format('  %d of %d swept decodes were wrong (%.1f %%)', nw, nrun, 100.0 * nw / nrun))
end
if fail > 0 then os.exit(1) end

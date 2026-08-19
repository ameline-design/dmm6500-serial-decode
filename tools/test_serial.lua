-- test_serial.lua -- unit tests that run the REAL tsp/*.tsp serial decoder on the
-- host, against a synthesised UART waveform.
--
-- The instrument is away, and even on the bench a build costs a power cycle, so
-- the decoder is developed here. tools/gen_serial.lua loads the ACTUAL shipped
-- sources via loadfile -- not a re-implementation, which would drift from them --
-- and provides the waveform generator and the mocked instrument.
--
-- Run from the repo root:  lua tools/test_serial.lua
-- When a test fails, tools/debug_serial.lua dumps the widths, seeds and every
-- format score behind the decision.
--
-- A NOTE ON WHAT IS TESTABLE. Several UART formats are genuinely
-- indistinguishable on the wire, and these tests assert the honest outcome
-- rather than an impossible one:
--   * the STOP BIT COUNT is not observable at all (a second stop bit is
--     identical to one bit of idle), so 8N2 traffic is expected to read as 8N1;
--   * 7E1 and 8N1 occupy the same ten bit cells, separated only statistically
--     (ua_refine_parity);
--   * a repeated single byte, and a pure 0x55 square wave, fit several formats
--     exactly, so the commonest is the right answer and the rest are reported
--     as alternatives.

dofile('tools/mock_display.lua')     -- hostile display + file mock, object census
dofile('tools/gen_serial.lua')       -- waveform generator, dmm/buffer mock, decode core
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

-- ---------- test harness ----------
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
local function near(a, b, tol)
  return a ~= nil and b ~= nil and math.abs(a - b) <= tol
end
local function relnear(a, b, frac)
  return a ~= nil and b ~= nil and b ~= 0 and math.abs(a / b - 1) <= frac
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end

-- Run the real signal chain over a generated waveform, without acquire().
local function analyse(rd, nsmp, fs)
  sdec.acq_fs = fs
  local ok, why = sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  return ok, why
end

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
end

-- Generate, analyse and decode. Returns the result table, samples and count.
local function run(opts)
  local rd, ts, nc, nsmp = GEN(opts)
  local fs = opts.fs or 1000000
  analyse(rd, nsmp, fs)
  local ok, why = sdec.decode_from(rd, nsmp)
  return sdec.res, rd, nsmp, ok, why
end

local HELLO = 'Hello, World!'
local hb, hn = GEN_BYTES(HELLO)
local function rep(v, k)
  local t = {}
  local i
  for i = 1, k do t[i] = v end
  return t
end
local function txt(r) if r == nil then return '<nil>' end return GEN_STR(r.vals, r.nf) end

print('module load')
check('both modules load and define sdec', type(sdec) == 'table')
local leaked = 0
for k, v in pairs(_G) do
  if type(k) == 'string' and k ~= 'sdec' then
    if string.find(k, '^sig_') or string.find(k, '^ua_') or string.find(k, '^acq_') then
      leaked = leaked + 1
      print('      leaked global: ' .. k)
    end
  end
end
check('the modules leak no app globals besides sdec', leaked == 0)

-- ============================================================================
print('\nlevel detection (real code)')
-- ============================================================================
local rd, ts, nc, nsmp = GEN({bytes = hb, baud = 9600, fs = 100000, noise = 0.04})
local ok = analyse(rd, nsmp, 100000)
check('a clean 3.3 V line is accepted', ok)
-- Tolerance is 0.06 V, not 0.01, and the slack is a real effect rather than
-- sloppiness: samples caught mid-transition on a finite edge belong to neither
-- level but are still grouped into one, pulling both group means slightly toward
-- the centre. It is systematic, symmetric and tiny -- the threshold, which is
-- what actually matters, lands within 0.3 % of the swing.
check('low level found', near(sdec.lo, 0, 0.06), string.format('lo=%.4f V', sdec.lo))
check('high level found', near(sdec.hi, 3.3, 0.06), string.format('hi=%.4f V', sdec.hi))
check('threshold is midway', near(sdec.thr, 1.65, 0.03), string.format('thr=%.4f V', sdec.thr))
check('logic family named', sdec.family == '3V3 CMOS', sdec.family)
check('idle is high on a TTL line', sdec.idle == 1, 'idle=' .. tostring(sdec.idle))
-- Naming a family is a diagnostic -- "you are on the wrong pin" -- so naming the WRONG
-- one is worse than declining to name any. Each band is bounded at both ends; the 5 V
-- one used to be open-ended, so a 12 V LIN bus through its 2:1 divider read as 5V TTL.
check('every logic-family band is bounded at both ends',
      sdec.sig_family(0, 3.3) == '3V3 CMOS' and sdec.sig_family(0, 5.0) == '5V TTL'
      and sdec.sig_family(0, 1.8) == '1V8 CMOS'
      and sdec.sig_family(-6, 6) == 'RS-232'
      and sdec.sig_family(0, 6.0) == '6.0Vpp'
      and sdec.sig_family(0, 12.0) == '12.0Vpp',
      sdec.sig_family(0, 6.0) .. ' / ' .. sdec.sig_family(0, 12.0))

-- One wild outlier must not move the threshold: this is exactly why the levels
-- are group MEANS rather than min and max.
local spikerd = {}
for i = 1, nsmp do spikerd[i] = rd[i] end
spikerd[500] = 40.0
analyse(spikerd, nsmp, 100000)
check('one 40 V spike barely moves the threshold', near(sdec.thr, 1.65, 0.05),
      string.format('thr=%.4f V (min/max would give %.2f)', sdec.thr, (sdec.vmin + 40) / 2))

rd, ts, nc, nsmp = GEN({bytes = hb, baud = 9600, fs = 100000, lo = -6, hi = 6,
                        invert = true, noise = 0.05})
analyse(rd, nsmp, 100000)
check('an RS-232 line is named', sdec.family == 'RS-232', sdec.family)
check('idle is low on an inverted line', sdec.idle == 0, 'idle=' .. tostring(sdec.idle))

rd, ts, nc, nsmp = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 200, tail = 0})
ok = analyse(rd, nsmp, 100000)
check('a flat idle line is rejected with a reason', not ok)
check('a flat line produces no edges', sdec.ne == 0, 'ne=' .. tostring(sdec.ne))
check('bit timing on a flat line fails safely',
      pcall(function() sdec.sig_bittime() end) and sdec.bittime == nil)

rd, ts, nc, nsmp = GEN({bytes = hb, baud = 9600, fs = 100000, lo = 0, hi = 0.05})
ok = analyse(rd, nsmp, 100000)
check('a signal below the swing floor is rejected', not ok)

-- ============================================================================
print('\nedge extraction and sub-sample interpolation (real code)')
-- ============================================================================
-- 0x55 alternates every bit, so a frame is ten one-bit cells and the edge count
-- is exactly predictable -- the tightest available check that no edge is missed
-- or doubled.
rd, ts, nc, nsmp = GEN({bytes = rep(0x55, 8), baud = 9600, fs = 100000, gap = 2})
analyse(rd, nsmp, 100000)
check('0x55 x8 gives the exact expected edge count', sdec.ne == 8 * 10,
      'ne=' .. tostring(sdec.ne))

local worst = 0
local Tb = 100000 / 9600
for i = 2, sdec.ne do
  local d = sdec.ei[i] - sdec.ei[i-1]
  local m = math.floor(d / Tb + 0.5)
  if m >= 1 and m <= 4 then
    local e = math.abs(d - m * Tb)
    if e > worst then worst = e end
  end
end
check('interpolated edge spacing is within 0.15 samples of an exact multiple',
      worst < 0.15, string.format('worst error %.4f samples', worst))

-- Hysteresis must reject a sub-threshold wobble.
local base_ne = sdec.ne
local wob = {}
for i = 1, nsmp do wob[i] = rd[i] end
for i = 40, 60 do
  if wob[i] > 3.0 then wob[i] = 1.75 end     -- just above thr, inside the band
end
analyse(wob, nsmp, 100000)
check('a wobble across thr but inside the hysteresis band makes no edge',
      sdec.ne == base_ne, 'ne=' .. tostring(sdec.ne) .. ' vs ' .. tostring(base_ne))

-- ============================================================================
print('\nbit-time recovery (real code)')
-- ============================================================================
clearforce()
local cases = {
  {baud = 9600,   fs = 100000},
  {baud = 9600,   fs = 1000000},
  {baud = 19200,  fs = 200000},
  {baud = 38400,  fs = 500000},
  {baud = 57600,  fs = 1000000},
  {baud = 115200, fs = 1000000},   -- 8.68 samples/bit: the practical top end
  {baud = 1200,   fs = 20000},
  {baud = 31250,  fs = 500000},    -- MIDI
}
local allbaud = true
for _, c in ipairs(cases) do
  run({bytes = hb, baud = c.baud, fs = c.fs})
  if sdec.baud ~= c.baud then
    allbaud = false
    print(string.format('      %d baud at %d S/s -> %s (raw %.1f, T=%.3f sa, ratio %.3f)',
          c.baud, c.fs, tostring(sdec.baud), sdec.baud_raw or -1,
          sdec.bittime or -1, sdec.fitratio or -1))
  end
end
check('every baud/rate pair snaps to the exact standard rate', allbaud)

run({bytes = hb, baud = 115200, fs = 1000000})
check('115200 at 1 MS/s recovers the bit time to 0.5 %',
      relnear(sdec.bittime, 1000000 / 115200, 0.005),
      string.format('T=%.4f sa (want %.4f)', sdec.bittime, 1000000 / 115200))
check('the fit reports high quality on a clean line', sdec.fitq > 0.9,
      string.format('fitq=%.4f', sdec.fitq))

-- A glitch shorter than a bit must not become the bit time. The pulse-width fit
-- alone gets this WRONG (it lands on one fifth of the real bit time and scores
-- higher than the truth), so this is the test that justifies ua_best().
local grd, gts, gnc, gnsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
grd[900], grd[901] = 0.0, 0.0          -- a 2-sample notch in the idle line
analyse(grd, gnsmp, 100000)
local gok = sdec.decode_from(grd, gnsmp)
check('a 2-sample glitch does not become the bit time',
      relnear(sdec.bittime, 100000 / 9600, 0.02),
      string.format('T=%.3f sa (want %.3f) ratio=%.3f', sdec.bittime or -1,
                    100000 / 9600, sdec.fitratio or -1))
check('the glitched capture still snaps to 9600', sdec.baud == 9600, tostring(sdec.baud))
check('the glitched capture still reads the right text', has(txt(sdec.res), HELLO),
      txt(sdec.res))

-- Pulse widths sharing a common factor: 0x00 at 8N1 with a 2-bit gap contains
-- only 9-bit and 3-bit runs, so the width fit lands on THREE bit times.
run({bytes = rep(0, 6), baud = 9600, fs = 100000})
check('a capture whose widths share a common factor still finds the real baud',
      sdec.baud == 9600, string.format('%s baud, ratio %.4f', tostring(sdec.baud),
                                       sdec.fitratio or -1))

-- Non-standard rate: report it, do not force it onto the grid.
run({bytes = hb, baud = 12345, fs = 500000})
check('a non-standard rate is reported unsnapped',
      sdec.snapped == false and relnear(sdec.baud, 12345, 0.02),
      string.format('%.0f baud, snapped=%s', sdec.baud or -1, tostring(sdec.snapped)))
check('the unsnapped label is marked as approximate', has(sdec.baud_text(), '?'),
      sdec.baud_text())

-- Sample-rate quality gate.
run({bytes = hb, baud = 250000, fs = 1000000})       -- 4.0 samples/bit
local _, warn = sdec.sig_quality()
check('4 samples/bit is flagged as marginal', warn ~= nil, tostring(warn))
run({bytes = hb, baud = 9600, fs = 1000000})
local _, warn2 = sdec.sig_quality()
check('104 samples/bit is not flagged', warn2 == nil)

-- A harmonic of the true bit time that ALSO snaps to a standard rate is a genuine
-- ambiguity, not an error: eight 0x00 frames at 9600 7N1 with a one-bit gap are the
-- same waveform as four 0x08 bytes at 4800 8N1. The commoner reading is chosen, but
-- the alternative must be REPORTED -- silently picking one was the defect.
local zz = {}
for i = 1, 8 do zz[i] = 0 end
run({bytes = zz, baud = 9600, fs = 100000, nbits = 7, par = 0, nstop = 1, gap = 1})
check('a snapped harmonic is reported rather than silently chosen',
      sdec.baud_note ~= nil and has(sdec.baud_note, '9600'),
      string.format('chose %s %s; note: %s', tostring(sdec.baud), sdec.fmt_text(),
                    tostring(sdec.baud_note)))
check('the note reaches the panel note line ahead of format alternatives',
      (function()
        local save = sdec.lasterr
        sdec.lasterr = nil
        local t = sdec.ui_note_text()
        sdec.lasterr = save
        return has(t, 'also fits this waveform')
      end)(), sdec.ui_note_text())
-- An unambiguous capture must NOT acquire a spurious note.
run({bytes = hb, baud = 9600, fs = 100000})
check('a clean unambiguous capture reports no baud alternative',
      sdec.baud_note == nil, tostring(sdec.baud_note))

-- ============================================================================
print('\nUART frame decode (real code)')
-- ============================================================================
local r = run({bytes = hb, baud = 9600, fs = 100000})
check('the byte stream round-trips exactly',
      r ~= nil and r.nf == hn and txt(r) == HELLO,
      string.format('%d bytes: %q', r and r.nf or -1, txt(r)))
check('no framing or parity errors on a clean capture', r.nbad == 0, 'nbad=' .. r.nbad)
check('the format is identified as 8N1', sdec.fmt_text() == '8N1', sdec.fmt_text())
check('polarity identified as non-inverted', r.invert == false)

-- The patterns that break naive decoders: all-zeros makes a nine-bit low run,
-- all-ones is nearly indistinguishable from idle, 0x55 transitions on every bit.
local hard = {
  {name = 'all 0x00', bytes = rep(0, 6)},
  {name = 'all 0xFF', bytes = rep(255, 6)},
  {name = 'all 0x55', bytes = rep(0x55, 6)},
  {name = 'all 0xAA', bytes = rep(0xAA, 6)},
  {name = 'mixed extremes', bytes = {0x00, 0xFF, 0x00, 0xFF, 0x01, 0x80, 0x7F}},
}
for _, h in ipairs(hard) do
  local rr = run({bytes = h.bytes, baud = 9600, fs = 100000})
  local n = table.getn(h.bytes)
  local exact = rr ~= nil and rr.nf == n and rr.nbad == 0
  if exact then
    for i = 1, n do if rr.vals[i] ~= h.bytes[i] then exact = false end end
  end
  check('decodes ' .. h.name, exact,
        rr and string.format('%d bytes, %d err, %s', rr.nf, rr.nbad, sdec.fmt_text())
            or 'nil')
end

-- Mid-frame falling edges must not be mistaken for start bits. 0x00 is the
-- strongest case: a naive per-edge decoder resynchronises inside the byte.
local rr = run({bytes = rep(0, 4), baud = 9600, fs = 100000})
check('a 9-bit low run yields exactly 4 bytes', rr ~= nil and rr.nf == 4,
      'nf=' .. tostring(rr and rr.nf))

-- ============================================================================
print('\nformat auto-detection (real code)')
-- ============================================================================
local fmts = {
  {name = '8N1', nbits = 8, par = 0, nstop = 1},
  {name = '8E1', nbits = 8, par = 1, nstop = 1},
  {name = '8O1', nbits = 8, par = 2, nstop = 1},
  {name = '7E1', nbits = 7, par = 1, nstop = 1},
  {name = '7O1', nbits = 7, par = 2, nstop = 1},
}
for _, f in ipairs(fmts) do
  local rr = run({bytes = hb, baud = 9600, fs = 100000,
                  nbits = f.nbits, par = f.par, nstop = f.nstop})
  local got = sdec.fmt_text()
  local exact = rr ~= nil and rr.nf == hn and rr.nbad == 0 and got == f.name
                and txt(rr) == HELLO
  check('auto-detects ' .. f.name, exact,
        rr and string.format('got %s, %d bytes, %d err, %q', got, rr.nf, rr.nbad, txt(rr))
            or 'nil')
end

-- ---------- the rare-width switch (default: 7 and 8 only) ----------
-- 5, 6 and 9 data bits are excluded from the automatic search by default, because every
-- extra candidate format is another chance for a damaged capture to be won by the wrong
-- one, and the rare widths lose SILENTLY -- they absorb a stop bit into the data, so the
-- bytes are wrong with zero framing errors. The switch is entry 2 of Data Bits.
check('the default search is 7 and 8 data bits only',
      sdec.widths_any == false and table.getn(sdec.try_nbits) == 2
      and table.getn(sdec.try_nbits_all) == 4,
      table.concat(sdec.try_nbits, ',') .. '  vs any: '
      .. table.concat(sdec.try_nbits_all, ','))
-- 9 IS NOT IN EITHER LIST. It is the width that launders damage most effectively -- it reads the
-- real stop bit as data bit 9 and the first idle bit as its own stop, so a damaged frame decodes
-- CLEAN and an undamaged one decodes clean at +256, either way with no error to report. Biasing
-- against it does not work: ua_margin's proportional term is zero exactly when the honest reading
-- is damaged, so the margin falls to its floor and a 9N1 rival clears it. Forced, it still works.
do
  local ni, has9 = nil, false
  for ni = 1, table.getn(sdec.try_nbits_all) do
    if sdec.try_nbits_all[ni] == 9 then has9 = true end
  end
  check('...and 9 is in NEITHER list, because it cannot be biased against effectively',
        not has9, table.concat(sdec.try_nbits_all, ','))
  sdec.force_nbits = 9
  local w9 = sdec.ua_widths()
  check('...but forcing Data Bits = 9 still searches exactly 9',
        table.getn(w9) == 1 and w9[1] == 9, table.concat(w9, ','))
  sdec.force_nbits = nil
end
check('ua_widths reports the list in force',
      table.getn(sdec.ua_widths()) == 2,
      table.concat(sdec.ua_widths(), ','))

local rare5 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
local rare6 = {1, 2, 3, 40, 5, 60, 7, 8, 9, 10, 11, 12}
local rg, rnb

-- With the switch OFF (the default) a rare-width stream must not be reported as a rare
-- width -- and where it decodes cleanly as 7N1 anyway, the note has to SAY the top bit was
-- constant and how to get the other reading. Silent is the one unacceptable outcome.
for _, rg in ipairs({2, 3}) do
  for _, rnb in ipairs({5, 6}) do
    local want = rare5
    if rnb == 6 then want = rare6 end
    rr = run({bytes = want, baud = 9600, fs = 100000, nbits = rnb, gap = rg})
    check(string.format('by default a %dN1 stream (gap %d) is not reported as a rare width',
                        rnb, rg),
          rr ~= nil and sdec.fmt_text() ~= '5N1' and sdec.fmt_text() ~= '6N1',
          sdec.fmt_text())
    check(string.format('...and the note says it may be one, with the remedy (%dN1 gap %d)',
                        rnb, rg),
          has(sdec.fmt_note, 'may be') and has(sdec.fmt_note, 'any width'),
          tostring(sdec.fmt_note))
  end
end

-- With the switch ON, every rare width at every gap must come back exactly. This pairs the
-- biased search with ua_refine_width's walk back down; a masking bug in that walk returned
-- 6N1 traffic as 7N1 with every byte 64 too large and ZERO framing errors, and nothing had
-- tested 6N1 at all.
sdec.widths_any = true
rr = run({bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
          baud = 9600, fs = 100000, nbits = 5, gap = 0})
check('with any width allowed, back-to-back 5N1 auto-detects',
      rr ~= nil and sdec.fmt_text() == '5N1' and rr.nf == 8 and rr.nbad == 0,
      rr and string.format('got %s, %d bytes, %d err', sdec.fmt_text(), rr.nf, rr.nbad)
          or 'nil')
for _, rg in ipairs({0, 1, 2, 3}) do
  for _, rnb in ipairs({5, 6}) do
    local want = rare5
    if rnb == 6 then want = rare6 end
    rr = run({bytes = want, baud = 9600, fs = 100000, nbits = rnb, gap = rg})
    local exact = rr ~= nil and rr.nf == 12 and rr.nbad == 0
                  and sdec.fmt_text() == (rnb .. 'N1')
    if exact then
      local i
      for i = 1, 12 do if rr.vals[i] ~= want[i] then exact = false end end
    end
    check(string.format('any width: %dN1 with a %d-bit gap recovers every byte exactly',
                        rnb, rg), exact,
          rr and string.format('got %s, %d bytes, %d err', sdec.fmt_text(), rr.nf, rr.nbad)
              or 'nil')
  end
end
check('the rare widths are biased against even when allowed', sdec.rarewidth > 1,
      'rarewidth=' .. tostring(sdec.rarewidth))
check('the bias scales the proportional term, never the noise floor',
      sdec.ua_margin(0, 5) == sdec.ua_margin(0, 8)
      and sdec.ua_margin(20, 5) > sdec.ua_margin(20, 8),
      string.format('at 0: %g vs %g;  at 20: %g vs %g',
                    sdec.ua_margin(0, 5), sdec.ua_margin(0, 8),
                    sdec.ua_margin(20, 5), sdec.ua_margin(20, 8)))
sdec.widths_any = false

-- A FORCED rare width bypasses the search entirely, so it works whatever the switch says.
sdec.force_nbits = 6
rr = run({bytes = rare6, baud = 9600, fs = 100000, nbits = 6, gap = 2})
check('a FORCED rare width works with the switch off, since forcing skips the search',
      rr ~= nil and sdec.fmt_text() == '6N1' and rr.nf == 12 and rr.nbad == 0,
      rr and string.format('got %s, %d bytes, %d err', sdec.fmt_text(), rr.nf, rr.nbad)
          or 'nil')
clearforce()

-- Inverted (RS-232 sense) at 8N1.
rr = run({bytes = hb, baud = 9600, fs = 100000, lo = -6, hi = 6, invert = true})
check('auto-detects an inverted RS-232 line',
      rr ~= nil and rr.invert == true and txt(rr) == HELLO and rr.nbad == 0,
      string.format('invert=%s %q err=%s', tostring(rr and rr.invert), txt(rr),
                    tostring(rr and rr.nbad)))
check('the summary states idle LOW for RS-232', has(sdec.summary(1), 'idle LOW'),
      sdec.summary(1))

-- 7E1 versus 8N1: the one pair error-scoring alone cannot separate.
rr = run({bytes = hb, baud = 9600, fs = 100000, nbits = 7, par = 1})
check('7E1 traffic is reported as 7E1, not 8N1', sdec.fmt_text() == '7E1', sdec.fmt_text())
check('the 7E1 reclassification is explained', has(sdec.fmt_note, 'parity'),
      tostring(sdec.fmt_note))
check('7E1 values are the 7-bit characters', txt(rr) == HELLO, txt(rr))

-- Text at 8N1 must NOT be reclassified: real text breaks 7-bit parity.
rr = run({bytes = hb, baud = 9600, fs = 100000})
check('8N1 text is not misread as 7E1', sdec.fmt_text() == '8N1', sdec.fmt_text())

-- ---- the genuine ambiguities, asserted as such ----
-- A second stop bit is indistinguishable from a bit of idle, so 8N2 must read as
-- 8N1 with the right bytes rather than be guessed at.
rr = run({bytes = hb, baud = 9600, fs = 100000, nstop = 2})
check('8N2 traffic reads as 8N1 with the correct bytes (stop count is unobservable)',
      rr ~= nil and sdec.fmt_text() == '8N1' and txt(rr) == HELLO and rr.nbad == 0,
      string.format('got %s %q err=%s', sdec.fmt_text(), txt(rr), tostring(rr and rr.nbad)))

-- A repeated byte fits 8N1 and 7E1 identically, so the common format must win.
rr = run({bytes = rep(0x55, 10), baud = 9600, fs = 100000})
check('a repeated ambiguous byte stays 8N1', sdec.fmt_text() == '8N1',
      sdec.fmt_text() .. ' note=' .. tostring(sdec.fmt_note))
check('all ten bytes are recovered', rr ~= nil and rr.nf == 10 and rr.vals[1] == 0x55,
      rr and string.format('%d bytes, first=0x%02X', rr.nf, rr.vals[1] or 0) or 'nil')

-- 5N1 with a gap: report 7N1 (the common choice) and say what else fits.
rr = run({bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
          baud = 9600, fs = 100000, nbits = 5, gap = 2})
check('5N1 with an inter-byte gap reports alternatives rather than a coin flip',
      sdec.fmt_note ~= nil, string.format('got %s, note=%s', sdec.fmt_text(),
                                          tostring(sdec.fmt_note)))

-- ============================================================================
print('\nmanual override (real code)')
-- ============================================================================
-- Auto-detection is a default, not an argument with someone reading a datasheet.
rr = run({bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
          baud = 9600, fs = 100000, nbits = 5, gap = 2})
local autofmt = sdec.fmt_text()
local grd2, gts2, gnc2, gn2 = GEN({bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
                                   baud = 9600, fs = 100000, nbits = 5, gap = 2})
analyse(grd2, gn2, 100000)
sdec.force_nbits, sdec.force_par, sdec.force_nstop = 5, sdec.PAR_NONE, 1
local fok = sdec.decode_from(grd2, gn2)
check('forcing 5N1 overrides the ambiguous auto-detection',
      fok and sdec.fmt_text() == '5N1' and sdec.res.nf == 8 and sdec.res.nbad == 0,
      string.format('auto said %s, forced gives %s (%d bytes, %s err)', autofmt,
                    sdec.fmt_text(), sdec.res and sdec.res.nf or -1,
                    tostring(sdec.res and sdec.res.nbad)))
check('the forced 5-bit values are correct',
      sdec.res ~= nil and sdec.res.vals[1] == 0x11 and sdec.res.vals[4] == 0x1F,
      sdec.res and string.format('0x%02X 0x%02X', sdec.res.vals[1] or 0,
                                 sdec.res.vals[4] or 0) or 'nil')
clearforce()

-- Forcing the baud rate skips the fit entirely.
local brd, bts, bnc, bn = GEN({bytes = hb, baud = 9600, fs = 100000})
analyse(brd, bn, 100000)
sdec.force_baud = 9600
fok = sdec.decode_from(brd, bn)
check('forcing the baud rate decodes without any timing search',
      fok and sdec.baud == 9600 and txt(sdec.res) == HELLO,
      string.format('%s baud %q', tostring(sdec.baud), txt(sdec.res)))
sdec.force_baud = 4800
fok = sdec.decode_from(brd, bn)
check('forcing the WRONG baud rate produces errors rather than silence',
      (not fok) or sdec.res == nil or sdec.res.nbad > 0 or txt(sdec.res) ~= HELLO,
      string.format('ok=%s %q err=%s', tostring(fok), txt(sdec.res),
                    tostring(sdec.res and sdec.res.nbad)))
clearforce()

-- ============================================================================
print('\nawkward captures (real code)')
-- ============================================================================
-- Capture starting mid-frame but with inter-byte gaps: the anchor rule must
-- resynchronise on the first real gap and get everything after it right.
rr = run({bytes = hb, baud = 9600, fs = 100000, lead = 0, gap = 2})
check('a capture starting mid-frame resynchronises on the first gap',
      rr ~= nil and has(txt(rr), 'ello, World!'),
      rr and string.format('%q err=%d', txt(rr), rr.nbad) or 'nil')

-- Gapless AND starting mid-frame: nothing can align the first frame, but the
-- decoder must still recover rather than produce garbage throughout.
rr = run({bytes = hb, baud = 9600, fs = 100000, lead = 0, gap = 0, tail = 0})
check('a gapless mid-stream capture still recovers the tail',
      rr ~= nil and has(txt(rr), 'World!'),
      rr and string.format('%q err=%d', txt(rr), rr.nbad) or 'nil')

-- ---------------------------------------------------------------------------
-- THE GAPLESS LOWERCASE STREAM. This is the case that shipped broken, and the
-- 13-byte "Hello, World!" above is why: it is too SHORT and too mixed-case to
-- put the longest run on the wrong level.
--
-- Found on hardware 2026-08-16. Real 9600-baud lorem ipsum, no inter-byte gaps,
-- gave run0 = 63 samples against run1 = 42 -- because a space (0x20) runs its
-- start bit into five zero data bits for six low bits, while lowercase letters
-- offer at most four consecutive ones. sig_idle's longest-run rule therefore
-- said idle = 0 on a line idling at 3.3 V, ua_autoformat made that the incumbent,
-- and the inverted reading returned 218 frames with ZERO framing errors. Every
-- byte wrong, nothing anywhere saying so.
--
-- The test asserts three separate things, because any one of them alone would
-- pass for the wrong reason: the run statistics really are inverted (so the
-- fixture reproduces the hardware), the prior is nonetheless correct, and the
-- text decodes.
-- do...end because the main chunk is at Lua 5.0's 200-local ceiling; the block
-- releases these three registers again at its close.
do
local LOREM = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do ' ..
              'eiusmod tempor incididunt ut labore et dolore magna aliqua ut ' ..
              'enim ad minim veniam quis nostrud exercitation ullamco laboris'
local lb, ln = GEN_BYTES(LOREM)
rr = run({bytes = lb, baud = 9600, fs = 100000, lead = 0, gap = 0, tail = 0})
check('gapless lowercase text: the longest run really is LOW, as on hardware',
      sdec.run0 > sdec.run1,
      string.format('run0=%s run1=%s', tostring(sdec.run0), tostring(sdec.run1)))
check('...and the run prior is marked UNTRUSTWORTHY rather than believed',
      sdec.idle_weak == true, tostring(sdec.idle_weak))
check('...so idle is still HIGH, from the single-supply levels',
      sdec.idle == 1,
      string.format('idle=%s lo=%.2f hi=%.2f', tostring(sdec.idle),
                    sdec.lo or -99, sdec.hi or -99))
check('...the polarity chosen is NOT inverted',
      rr ~= nil and rr.invert == false,
      rr and tostring(rr.invert) or 'nil')
check('...and the text decodes, which the inverted reading also did -- '
      .. 'confidently and wrongly',
      rr ~= nil and has(txt(rr), 'consectetur adipiscing'),
      rr and string.format('%q err=%d', string.sub(txt(rr), 1, 40), rr.nbad)
      or 'nil')

-- The same stream WITH gaps must still work, and must reach the answer the
-- ordinary way -- through the runs, not the level fallback. Otherwise the fix
-- above could be masking the run path entirely.
rr = run({bytes = lb, baud = 9600, fs = 100000, gap = 2})
check('with inter-byte gaps the run prior is TRUSTED again',
      sdec.idle_weak == false, tostring(sdec.idle_weak))
check('...and still decodes', rr ~= nil and has(txt(rr), 'lorem ipsum'),
      rr and string.format('%q', string.sub(txt(rr), 1, 24)) or 'nil')

-- An inverted line WITH idle in the window must still be detected as inverted:
-- the level fallback must not have replaced the run rule, only backstopped it.
rr = run({bytes = lb, baud = 9600, fs = 100000, gap = 2, invert = true,
          lo = -6, hi = 6})
check('an RS-232 line with gaps is still read as inverted',
      rr ~= nil and rr.invert == true and sdec.idle == 0,
      rr and string.format('invert=%s idle=%s', tostring(rr.invert),
                           tostring(sdec.idle)) or 'nil')
-- And GAPLESS RS-232, where the runs are useless and the levels straddle ground,
-- is the case the level fallback exists for.
rr = run({bytes = lb, baud = 9600, fs = 100000, lead = 0, gap = 0, tail = 0,
          invert = true, lo = -6, hi = 6})
check('gapless RS-232 falls back to the NEGATIVE level being mark',
      sdec.idle == 0 and sdec.idle_weak == true,
      string.format('idle=%s weak=%s lo=%.1f hi=%.1f', tostring(sdec.idle),
                    tostring(sdec.idle_weak), sdec.lo or -99, sdec.hi or -99))
end
clearforce()

-- Capture truncated mid-frame: the partial byte must be dropped, not invented.
local trd, tts, tnc, tn = GEN({bytes = hb, baud = 9600, fs = 100000, tail = 0})
local cut = tn - math.floor(100000 / 9600 * 5)      -- lose the last 5 bit times
analyse(trd, cut, 100000)
sdec.decode_from(trd, cut)
check('a mid-frame truncation drops the partial byte rather than inventing one',
      sdec.res ~= nil and sdec.res.nf == hn - 1 and sdec.res.nbad == 0,
      sdec.res and string.format('%d bytes (want %d), %d err', sdec.res.nf, hn - 1,
                                 sdec.res.nbad) or 'nil')

-- Noise at 10 % of the swing, with the 3-tap mid-bit vote doing the work.
GEN_RESEED(999)
rr = run({bytes = hb, baud = 9600, fs = 100000, noise = 0.33})
check('10 % noise still decodes exactly', rr ~= nil and rr.nbad == 0 and txt(rr) == HELLO,
      rr and string.format('%q err=%d', txt(rr), rr.nbad) or 'nil')

-- Slow RS-232 edges: rise time a third of a bit.
rr = run({bytes = hb, baud = 9600, fs = 100000, lo = -6, hi = 6, invert = true,
          rise = 100000 / 9600 / 3})
check('a rise time of a third of a bit still decodes',
      rr ~= nil and rr.nbad == 0 and txt(rr) == HELLO,
      rr and string.format('%q err=%d', txt(rr), rr.nbad) or 'nil')

rr = run({bytes = {0x41}, baud = 9600, fs = 100000})
check('a single byte decodes', rr ~= nil and rr.nf == 1 and rr.vals[1] == 0x41,
      rr and string.format('%d bytes val=%s fmt=%s', rr.nf, tostring(rr.vals[1]),
                           sdec.fmt_text()) or 'nil')

-- ============================================================================
print('\nnoise, spikes and ugly signals (real code)')
-- ============================================================================
-- A longer payload for these: more frames means the pass/fail is statistical
-- rather than luck, and it also lets a realistic number of spikes be injected
-- while staying under the 0.5 % trim budget the level detector is built for.
local LONG = 'The quick brown fox jumps over the lazy dog 0123456789 !@#$%^&*()'
local lgb, lgn = GEN_BYTES(LONG)

local function corrupt(opts, mangle)
  local crd, cts, cnc, cn = GEN(opts)
  if mangle then mangle(crd, cn) end
  analyse(crd, cn, opts.fs or 100000)
  local cok, cwhy = sdec.decode_from(crd, cn)
  return sdec.res, cok, cwhy, crd, cn
end

GEN_RESEED(4242)
local base = {bytes = lgb, baud = 9600, fs = 100000}
local function ok_exact(r) return r ~= nil and r.nf == lgn and r.nbad == 0 and txt(r) == LONG end
local function detail(r)
  if r == nil then return 'nil' end
  return string.format('%d/%d bytes %d err %s baud %s', r.nf, lgn, r.nbad,
                       tostring(sdec.baud), sdec.fmt_text())
end

-- 20 double-width spikes of +-10 V on a 0/3.3 V line: 40 samples out of ~7000,
-- well inside the 0.5 % winsorising budget.
local nr = corrupt(base, function(rd, n) GEN_SPIKES(rd, n, 20, 10.0, 2) end)
check('survives 20 spikes of +-10 V (3x the supply)', ok_exact(nr), detail(nr))
check('the spikes did not drag the threshold', near(sdec.thr, 1.65, 0.1),
      string.format('thr=%.3f V (raw range %.1f..%.1f V, trimmed %.2f..%.2f)',
                    sdec.thr, sdec.vmin, sdec.vmax, sdec.wlo or -99, sdec.whi or -99))

-- The pathological one: a single spike far larger than anything real.
nr = corrupt(base, function(rd) rd[777] = 200.0 end)
check('survives one 200 V spike', ok_exact(nr), detail(nr))

-- Bipolar spikes below ground as well as above the rail.
nr = corrupt(base, function(rd, n) GEN_SPIKES(rd, n, 30, 25.0, 1) end)
check('survives 30 single-sample bipolar spikes of +-25 V', ok_exact(nr), detail(nr))

-- Ringing that recrosses the threshold is what hysteresis is for.
nr = corrupt(base, function(rd, n) GEN_RING(rd, n, 0.35, 4, 3) end)
check('survives 35 % overshoot with ringing', ok_exact(nr), detail(nr))

-- Baseline wander eats the hysteresis budget, because the threshold is decided
-- once for the whole capture.
nr = corrupt(base, function(rd, n) GEN_DRIFT(rd, n, 0.5, 1.5) end)
check('survives +-0.5 V baseline drift (15 % of swing)', ok_exact(nr), detail(nr))

-- Everything at once, at levels a real bench can produce.
GEN_RESEED(7)
nr = corrupt({bytes = lgb, baud = 9600, fs = 100000, noise = 0.15, rise = 3},
             function(rd, n)
               GEN_RING(rd, n, 0.2, 5, 3)
               GEN_DRIFT(rd, n, 0.25, 2)
               GEN_SPIKES(rd, n, 12, 8.0, 2)
             end)
check('survives noise + ringing + drift + spikes together', ok_exact(nr), detail(nr))

-- An RS-232 line with everything wrong with it: slow edges, ringing, drift,
-- spikes, and inverted polarity to detect on top.
GEN_RESEED(31337)
local rsopts = {bytes = lgb, baud = 9600, fs = 100000, lo = -7, hi = 6.5,
                invert = true, noise = 0.35, rise = 6}
nr = corrupt(rsopts, function(rd, n)
  GEN_RING(rd, n, 0.25, 6, 4)
  GEN_DRIFT(rd, n, 0.8, 1.2)
  GEN_SPIKES(rd, n, 15, 20.0, 2)
end)
local ndiff = 0
if nr ~= nil then
  for i = 1, lgn do if nr.vals[i] ~= lgb[i] then ndiff = ndiff + 1 end end
end
-- Every WIRE parameter must still be recovered exactly. The bytes are allowed to
-- take damage, because at this spike amplitude some are physically unrecoverable.
check('an ugly RS-232 line still yields the right baud, format, polarity and count',
      nr ~= nil and sdec.baud == 9600 and sdec.fmt_text() == '8N1'
      and nr.invert == true and nr.nf == lgn,
      detail(nr) .. ' invert=' .. tostring(nr and nr.invert))
check('at most 2 of 65 bytes are corrupted by 15 spikes of +-20 V', ndiff <= 2,
      string.format('%d bytes differ', ndiff))
-- The important and slightly uncomfortable property: a spike that lands on a DATA
-- bit flips it and nothing detects that. The start and stop bits are still where
-- they should be, so the frame passes. This is exactly why real protocols carry a
-- parity bit or a checksum, and it means the panel's "0 err" must be read as "no
-- FRAMING errors" rather than "no corruption" -- worth stating in the UI.
check('a spike on a data bit corrupts the byte SILENTLY (no framing error)',
      nr ~= nil and nr.nbad == 0 and ndiff >= 1,
      string.format('%d corrupted, %d flagged', ndiff, nr and nr.nbad or -1))

-- Where does it actually break? Reported, not asserted beyond a floor, because
-- the number is the useful output.
print('      noise sweep (fraction of swing -> result):')
local lastgood = 0
for _, frac in ipairs({0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50}) do
  GEN_RESEED(1000 + math.floor(frac * 100))
  local sr = corrupt({bytes = lgb, baud = 9600, fs = 100000, noise = frac * 3.3})
  local good = ok_exact(sr)
  if good then lastgood = frac end
  print(string.format('        %.0f%% peak noise: %s', frac * 100,
                      good and 'exact' or ('FAILS  ' .. detail(sr))))
end
check('decodes exactly with at least 20 % peak noise on the swing', lastgood >= 0.20,
      string.format('last clean at %.0f%%', lastgood * 100))

-- ============================================================================
print('\nbaud ceiling on real DMM6500 sample rates (real code)')
-- ============================================================================
-- The instrument tops out at 1 MS/s, so the ceiling is set by samples per bit.
-- This measures where it actually falls rather than projecting it.
print('      at 1 MS/s, clean signal:')
local ceiling = 0
for _, b in ipairs({57600, 76800, 115200, 128000, 230400, 250000, 460800, 921600}) do
  local sr = corrupt({bytes = lgb, baud = b, fs = 1000000})
  local exactly = sr ~= nil and sr.nf == lgn and sr.nbad == 0 and txt(sr) == LONG
  if exactly and b > ceiling then ceiling = b end
  print(string.format('        %6d baud (%.2f sa/bit): %s', b, 1000000 / b,
                      exactly and 'exact' or ('fails - ' .. detail(sr))))
end
print('      at 1 MS/s, 10 % noise + 25 % ringing:')
local nceiling = 0
for _, b in ipairs({57600, 115200, 230400, 460800}) do
  GEN_RESEED(55)
  local sr = corrupt({bytes = lgb, baud = b, fs = 1000000, noise = 0.33},
                     function(rd, n) GEN_RING(rd, n, 0.25, 4, 3) end)
  local exactly = sr ~= nil and sr.nf == lgn and sr.nbad == 0 and txt(sr) == LONG
  if exactly and b > nceiling then nceiling = b end
  print(string.format('        %6d baud (%.2f sa/bit): %s', b, 1000000 / b,
                      exactly and 'exact' or ('fails - ' .. detail(sr))))
end
check('115200 decodes exactly at 1 MS/s (8.68 samples/bit)', ceiling >= 115200,
      'clean ceiling ' .. tostring(ceiling) .. ' baud')
check('115200 still decodes with noise and ringing', nceiling >= 115200,
      'noisy ceiling ' .. tostring(nceiling) .. ' baud')

-- ============================================================================
print('\nacquisition path (real code, mocked instrument)')
-- ============================================================================
clearforce()
local ard, ats, anc, an = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 20,
                               n = 12000})
SRC.rd, SRC.ts, SRC.nsmp = ard, ats, an

sdec.fs, sdec.n, sdec.trigmode = 100000, 8000, 'free'
local aok, awhy = sdec.acquire()
check('free-run acquire() succeeds', aok, tostring(awhy))
check('acquire() measured the true sample rate from timestamps',
      relnear(sdec.acq_fs, 100000, 1e-6), tostring(sdec.acq_fs))
local dok, dwhy = sdec.decode()
check('decode() after free-run acquire() succeeds', dok, tostring(dwhy))
check('free-run capture reads the right text', has(txt(sdec.res), HELLO), txt(sdec.res))

-- A quiet line in free-run mode has nothing to wait for, so it must say so.
local qrd, qts, qnc, qn = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 12000,
                               tail = 0, n = 12000})
SRC.rd, SRC.ts = qrd, qts
aok, awhy = sdec.acquire()
check('a quiet line in free-run mode fails with a reason', not aok and awhy ~= nil,
      tostring(awhy))

-- The probe landing entirely in idle is the NORMAL case for triggered capture:
-- 400 bit times of lead is 4167 samples, far more than the 2000-sample probe.
local lrd, lts, lnc, ln = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 400,
                               n = 12000})
SRC.rd, SRC.ts = lrd, lts
SRC.trigat = math.floor(400 * 100000 / 9600)
sdec.trigmode = 'edge'
local t0trig = READS.triggered
aok, awhy = sdec.acquire()
check('triggered acquire() succeeds even when the probe saw only idle', aok, tostring(awhy))
check('the all-idle probe is recorded rather than silently ignored',
      sdec.probe_idle ~= nil, tostring(sdec.probe_idle))
check('the analog trigger path was actually used', READS.triggered == t0trig + 1,
      'triggered=' .. tostring(READS.triggered))
check('the trigger armed on a FALLING edge for an idle-high line',
      dmm.digitize.analogtrigger.edge.slope == dmm.SLOPE_FALLING,
      tostring(dmm.digitize.analogtrigger.edge.slope))
-- The position is DERIVED from a reserve measured in TIME, not the fixed sdec.pretrig percentage:
-- 5 % of the buffer is 1.05 ms at 1 MS/s, shorter than the wait for a falling edge on a slow line,
-- and the reserve then wraps and posts 4915 per overwrite. See sdec.acq_position.
check('the pre-trigger percentage was passed through', TRIG.position == sdec.pretrig,
      tostring(TRIG.position))
-- The reserve's duration is what decides whether it WRAPS while waiting for the first edge, and a
-- wrap posts 4915 per discarded reading. It cannot be lengthened without cost -- see acq_reserve --
-- so it is measured here rather than fixed, and the event is muted for the capture instead.
check('the reserve is a known number of readings, so its duration is calculable',
      sdec.acq_reserve(sdec.n) > 0 and
      sdec.acq_reserve(sdec.n) < sdec.acq_cap(sdec.n),
      string.format('%d readings = %.1f ms at %s S/s', sdec.acq_reserve(sdec.n),
                    1000 * sdec.acq_reserve(sdec.n) / sdec.fs, tostring(sdec.fs)))
-- AND THE BUFFER FILLS CONTINUOUSLY, which is what makes the circular reserve legal. A FILL_ONCE
-- buffer DISCARDS a reading past the end and posts 4915 per discard; continuous overwrites instead.
-- The constant is absent on this firmware, so the numeric 1 is used -- see sdec.acq_fillmode.
check('the capture buffer was set to fill continuously',
      sdec.buf ~= nil and sdec.buf.fillmode == 1,
      tostring(sdec.buf and sdec.buf.fillmode))
dok, dwhy = sdec.decode()
check('decode() after triggered acquire() succeeds', dok, tostring(dwhy))
check('the triggered capture decodes cleanly from just before the start bit',
      sdec.res ~= nil and sdec.res.nbad == 0 and has(txt(sdec.res), HELLO),
      sdec.res and string.format('%q err=%d', txt(sdec.res), sdec.res.nbad) or 'nil')

-- Object-lifetime rule: a second acquire() must not leave the old buffer behind.
local b1 = LIVEBUFS()
sdec.acquire()
check('re-acquiring leaks no buffers', LIVEBUFS() == b1,
      'buffers=' .. LIVEBUFS() .. ' vs ' .. b1)

-- An inverted line must arm on a RISING edge instead.
local ird, its, inc, iN = GEN({bytes = hb, baud = 9600, fs = 100000, lo = -6, hi = 6,
                               invert = true, lead = 20, n = 12000})
SRC.rd, SRC.ts, SRC.trigat = ird, its, nil
aok, awhy = sdec.acquire()
check('acquire() on an inverted line succeeds', aok, tostring(awhy))
check('an idle-low line arms on a RISING edge',
      dmm.digitize.analogtrigger.edge.slope == dmm.SLOPE_RISING,
      tostring(dmm.digitize.analogtrigger.edge.slope))

-- A trigger model that errors must fall back rather than abort the capture.
local realload = trigger.model.load
trigger.model.load = function() error('analog trigger not supported', 0) end
SRC.rd, SRC.ts = ard, ats
aok, awhy = sdec.acquire()
trigger.model.load = realload
check('a failed trigger model falls back to a free-run capture', aok, tostring(awhy))
check('the fallback is recorded, not swallowed', sdec.lasterr ~= nil,
      tostring(sdec.lasterr))

-- ============================================================================
print('\nsample-rate selection (real code)')
-- ============================================================================
local spbok = true
for _, b in ipairs({300, 1200, 9600, 19200, 57600, 115200}) do
  local f = sdec.pick_fs(b, 8)
  if f / b < 8 then
    spbok = false
    print(string.format('      %d baud -> %d S/s = %.1f sa/bit', b, f, f / b))
  end
end
check('pick_fs always reaches 8 samples per bit where the hardware can', spbok)
-- 80000, not 100000: 9600 x 8 = 76800, and after BRINGUP 4b.11 added the exact
-- divisors of 66 MHz the lowest listed rate at or above that is 80000. This is the
-- test's own point -- lower rate, longer window -- paying off: 240 bytes per capture
-- instead of 192.
check('pick_fs prefers the LOWEST adequate rate (more bytes per capture)',
      sdec.pick_fs(9600, 8) == 80000, tostring(sdec.pick_fs(9600, 8)))
check('pick_fs saturates at 1 MS/s for rates it cannot oversample',
      sdec.pick_fs(460800, 8) == 1000000, tostring(sdec.pick_fs(460800, 8)))
-- EVERY OFFERED RATE IS EITHER AN EXACT DIVISOR OF THE 66 MHz SAMPLE CLOCK, OR ONE
-- OF THREE NAMED EXCEPTIONS. This replaces a list of the eight rates the old ladder
-- happened to contain, and it is a stronger check: it re-derives what the hardware
-- will actually deliver from the divider model measured in BRINGUP 4b.11
-- (fs = 66e6 / ceil(66e6 / requested)) rather than trusting a table of names.
--
-- The three exceptions are listed deliberately -- see sdec.rates -- because 19200,
-- 38400 and 76800 need them. They must still clear minsabit once the rounding-up of
-- the divider has taken its bite, and that is checked here rather than asserted in a
-- comment.
do
  local F0 = 66000000
  local allowed = {[160000] = true, [320000] = true, [640000] = true}
  local exact, bad, i = true, nil, nil
  for i = 1, table.getn(sdec.rates) do
    local f = sdec.rates[i]
    local delivered = F0 / math.ceil(F0 / f)
    if math.abs(delivered - f) > 1e-6 then
      -- Inexact. Permitted only if named, and only if it still oversamples enough.
      if not allowed[f] then
        exact = false
        bad = string.format('%d is inexact (%.1f) and not one of the three named',
                            f, delivered)
      elseif delivered / (f / 8) < sdec.minsabit then
        exact = false
        bad = string.format('%d delivers %.1f, under minsabit', f, delivered)
      end
    end
    if f < 1000 then
      exact = false
      bad = string.format('%d is below the 1000 S/s floor (900 is rejected, 1130)', f)
    end
  end
  check('every offered rate divides 66 MHz, or is one of three named exceptions '
        .. 'that still clear minsabit', exact, bad)
  -- And the three exceptions really are the rates that need to exist, i.e. removing
  -- them would cost the three commonest high baud rates a quarter of their window.
  check('19200, 38400 and 76800 each land on one of those exceptions',
        sdec.fs_for_baud(19200) == 160000 and sdec.fs_for_baud(38400) == 320000
        and sdec.fs_for_baud(76800) == 640000,
        string.format('%s / %s / %s', tostring(sdec.fs_for_baud(19200)),
                      tostring(sdec.fs_for_baud(38400)),
                      tostring(sdec.fs_for_baud(76800))))
end

-- ============================================================================
print('\npresentation (real code)')
-- ============================================================================
r = run({bytes = hb, baud = 9600, fs = 100000})
check('the ASCII row shows the characters', sdec.ua_text_line(1, 13) == HELLO,
      sdec.ua_text_line(1, 13))
check('the hex row carries the offset, the bytes AND the characters',
      sdec.ua_hex_line(1, 4) == '0000  48 65 6C 6C  |Hell|', sdec.ua_hex_line(1, 4))
-- A short final row is padded so its ASCII gutter still lines up under the row
-- above, which is the whole reason the two columns are on one line.
check('a short final row pads to keep the gutter aligned',
      string.len(sdec.ua_hex_line(13, 4)) == string.len(sdec.ua_hex_line(1, 4)),
      '"' .. sdec.ua_hex_line(13, 4) .. '"')
check('the hex row offset advances', has(sdec.ua_hex_line(9, 4), '0008 '),
      sdec.ua_hex_line(9, 4))
-- Paging extent, per view. ui_npages is the only row-count arithmetic left --
-- sdec.ua_nrows() duplicated it and nothing but a test ever called it. Columns per row
-- live in sdec.ui_views, which is the single description of a view.
local savemode, savenrow = sdec.ui_mode, sdec.ui_nrow
local savecols = sdec.ui_views[1].cols
sdec.ui_nrow = 4
sdec.ui_mode = 'text'
sdec.ui_views[1].cols = 1
check('the text view pages by ui_nrow rows of its own column count',
      sdec.ui_npages() == 4, tostring(sdec.ui_npages()))       -- 13 bytes / 4
sdec.ui_views[1].cols = 5
check('a partial last page is still a page', sdec.ui_npages() == 1,
      tostring(sdec.ui_npages()))                              -- 13 / 20
sdec.ui_views[1].cols = savecols
sdec.ui_mode = 'hex'
check('the hex view pages by 16 bytes a row', sdec.ui_npages() == 1,
      tostring(sdec.ui_npages()))
sdec.ui_mode = 'midi'
check('the MIDI view pages by MESSAGES, not bytes, and is empty unparsed',
      sdec.ui_nitems() == 0 and sdec.ui_npages() == 1,
      sdec.ui_nitems() .. ' items')
sdec.ui_mode = 'lin'
check('the LIN view pages by FRAMES, and is empty unparsed',
      sdec.ui_nitems() == 0 and sdec.ui_npages() == 1,
      sdec.ui_nitems() .. ' items')
check('the status row names the unit per view',
      (function() sdec.ui_mode = 'text'; local a = sdec.ui_unit()
         sdec.ui_mode = 'midi'; local b = sdec.ui_unit()
         sdec.ui_mode = 'lin'; local c = sdec.ui_unit()
         return a == 'bytes' and b == 'msg' and c == 'frame' end)())
-- An unrecognised mode must fall back rather than leaving every caller to guard.
sdec.ui_mode = 'nonsense'
check('an unknown view mode falls back to text', sdec.ui_cur().mode == 'text'
      and sdec.ui_unit() == 'bytes', sdec.ui_cur().mode)
sdec.ui_mode, sdec.ui_nrow = savemode, savenrow
check('a row past the end is empty', sdec.ua_text_line(99, 8) == '',
      '"' .. sdec.ua_text_line(99, 8) .. '"')
check('control characters render as . so columns cannot shift',
      sdec.ua_char(0x0D) == '.' and sdec.ua_char(0x00) == '.' and sdec.ua_char(0xFF) == '.')
check('an errored frame renders as ?', sdec.ua_char(0x41, 'framing') == '?')
check('summary 1 names rate, format and polarity',
      has(sdec.summary(1), '9600 baud') and has(sdec.summary(1), '8N1')
      and has(sdec.summary(1), 'idle HIGH'), sdec.summary(1))
check('summary 2 names the wire',
      has(sdec.summary(2), '3V3 CMOS') and has(sdec.summary(2), 'sa/bit'),
      sdec.summary(2))
check('summary 3 counts bytes, errors and the real sample rate',
      has(sdec.summary(3), '13 bytes') and has(sdec.summary(3), '0 err')
      and has(sdec.summary(3), '100 kS/s'), sdec.summary(3))
sdec.res = nil
check('the summary is safe with nothing decoded',
      sdec.summary(1) ~= nil and sdec.summary(3) ~= nil and sdec.fmt_text() == '--')

-- ============================================================================
print('\nUSB logger (real code, mocked file API)')
-- ============================================================================
-- No key present is the NORMAL case on a bench unit, not an error, so nothing here
-- may raise and the app must not care.
MD.usb(false)
ulog.tag = 'TEST'
local lok = ulog.open('/usb1/t.txt')
check('open with no USB key returns false rather than raising', lok == false)
check('the reason is recorded', has(ulog.lasterr, 'no USB key'), tostring(ulog.lasterr))
check('writing with no key is a silent no-op', ulog.line('x') == false)
check('status says why', has(ulog.status(), 'no USB key'), ulog.status())
check('close with nothing open is harmless', ulog.close() == true)

MD.usb(true)
check('open with a key present succeeds', ulog.open('/usb1/t.txt', true) == true)
check('a session header is written first', has(MD.logtext(), 'session start'), MD.logtext())
ulog.line('hello')
check('a line is written with a sequence number and tag',
      has(MD.logtext(), 'hello') and has(MD.logtext(), 'TEST'), MD.logtext())
check('lines are counted', ulog.nlines == 2, tostring(ulog.nlines))
ulog.fmt('value=%d name=%s', 42, 'x')
check('fmt formats', has(MD.logtext(), 'value=42 name=x'))
ulog.fmt('bad %d', 'not a number')
check('a bad format is reported, not raised', has(MD.logtext(), 'bad format args'),
      'logger survived a format mismatch')
check('status shows the file name, not the whole path',
      has(ulog.status(), 't.txt') and not has(ulog.status(), '/usb1/'), ulog.status())

-- The key pulled mid-session must stop the logger, not fail every subsequent line.
local before = ulog.nlines
MD.usb(true, ulog.nlines)          -- next write fails
ulog.line('this write fails')
check('a failed write turns logging off instead of retrying forever', ulog.on == false)
check('the failure reason is kept', ulog.lasterr ~= nil, tostring(ulog.lasterr))
ulog.line('and this is a no-op')
check('further lines are no-ops', ulog.nlines == before + 1, tostring(ulog.nlines))

-- Reload safety. Opening the installed App re-runs every module body, and a
-- file-scope `ulog.fh = nil` would erase the only reference to an already-open file
-- before anything could close it -- leaking a firmware descriptor and losing
-- whatever was still buffered.
MD.usb(true)
ulog.open('/usb1/reload.txt', true)
ulog.line('before reload')
local fh_before, n_before = ulog.fh, ulog.nlines
loadfile('tsp/usb_log.tsp')()
check('a script reload keeps the open log handle reachable', ulog.fh == fh_before,
      string.format('fh %s -> %s', tostring(fh_before), tostring(ulog.fh)))
check('a script reload keeps the log open', ulog.on == true, tostring(ulog.on))
check('a script reload preserves the line count', ulog.nlines == n_before,
      tostring(ulog.nlines))
check('a reloaded logger can still write', ulog.line('after reload') == true)
check('a reload does not reset the configured path', has(ulog.path, 'reload.txt'),
      ulog.path)
ulog.enabled = false
loadfile('tsp/usb_log.tsp')()
check('a reload does not resurrect a deliberately disabled logger',
      ulog.enabled == false, tostring(ulog.enabled))
ulog.enabled = true
ulog.close()

-- The per-session cap stops a runaway loop filling the key.
MD.usb(true)
ulog.open('/usb1/t.txt', true)
ulog.maxlines = 5
local i
for i = 1, 20 do ulog.line('spam ' .. i) end
check('the line cap is enforced', ulog.nlines == 5, tostring(ulog.nlines))
-- 16, not 15: ulog.open() writes a session-start header, which is line 1.
check('dropped lines are counted, not silently discarded', ulog.dropped == 16,
      tostring(ulog.dropped))
check('the status admits the drops', has(ulog.status(), 'dropped'), ulog.status())
ulog.maxlines = 20000
ulog.close()

-- ============================================================================
print('\nUSB save path (real code, mocked file API)')
-- ============================================================================
-- The Save USB button had ZERO coverage: its only exercise anywhere returned false,
-- because the mock handed back a handle for every file.open regardless of mode, so
-- next_free() saw all 100 candidate names as taken. A new front-panel button whose
-- one code path never ran is exactly the thing to test before touching hardware.

-- ---- ulog.next_free ----
MD.usb(true)
MD.forget_files()
check('next_free starts at 00 on an empty key',
      ulog.next_free('/usb1/s_', '.txt') == '/usb1/s_000.txt',
      tostring(ulog.next_free('/usb1/s_', '.txt')))
ulog.write_file('/usb1/s_000.txt', {'a'}, 1)
check('next_free skips a name that now exists',
      ulog.next_free('/usb1/s_', '.txt') == '/usb1/s_001.txt',
      tostring(ulog.next_free('/usb1/s_', '.txt')))
check('next_free zero-pads so names sort',
      has(ulog.next_free('/usb1/s_', '.txt'), '_001.'))
-- All names taken has to be a nil, not name 100 or an overwrite of 00.
local nf_i
for nf_i = 1, 5 do ulog.write_file(string.format('/usb1/f_%03d.txt', nf_i - 1), {'x'}, 1) end
check('next_free returns nil when every candidate is taken',
      ulog.next_free('/usb1/f_', '.txt', 5) == nil,
      tostring(ulog.next_free('/usb1/f_', '.txt', 5)))
MD.usb(false)
-- A NAME, not a specific number. With no key every probe fails, so every candidate looks free
-- and the first one tried is returned -- and which one that is depends on the session's index
-- cache, which is legitimate history rather than a defect. The property that matters is that a
-- missing key does not make this return nil and strand the caller with no filename: probing
-- cannot distinguish "absent" from "no key", and write_file is what reports the real failure.
check('next_free with no key still yields a name rather than nil',
      (function()
         local nm = ulog.next_free('/usb1/s_', '.txt')
         return type(nm) == 'string' and has(nm, '/usb1/s_') and has(nm, '.txt')
       end)(),
      tostring(ulog.next_free('/usb1/s_', '.txt')))
MD.usb(true)

-- ---- ulog.write_file ----
MD.forget_files()
check('write_file with no filename fails cleanly',
      (function() local ok, why = ulog.write_file(nil, {'a'}, 1)
         return ok == false and why ~= nil end)())
MD.usb(false)
check('write_file with no key fails cleanly and says which path',
      (function() local ok, why = ulog.write_file('/usb1/x.txt', {'a'}, 1)
         return ok == false and has(why, '/usb1/x.txt') end)())
MD.usb(true)
MD.forget_files()
check('write_file writes every line', ulog.write_file('/usb1/w.txt', {'l1', 'l2', 'l3'}, 3)
      and MD.loglines() == 3, MD.loglines() .. ' lines')
check('write_file terminates lines CRLF for a PC', has(MD.logtext(), 'l1\r\n'),
      string.format('%q', MD.logtext()))
-- The key filling up part-way through is the realistic failure, and it must be
-- reported: a truncated capture file that claims success is worse than no file.
MD.failwrite(2)
check('a write that fails part-way is reported, not claimed as saved',
      (function() local ok, why = ulog.write_file('/usb1/p.txt', {'a', 'b', 'c', 'd'}, 4)
         return ok == false and has(why, 'part-way') end)())
MD.failwrite(nil)

-- ---- sdec.save ----
sdec.res = nil
sdec.savedas = nil
check('save with nothing captured refuses and says why',
      sdec.save() == false and has(sdec.lasterr, 'capture first'),
      tostring(sdec.lasterr))
check('a refused save leaves no filename claimed', sdec.savedas == nil)

MD.forget_files()
MD.usb(true)
sdec.savepfx = '/usb1/cap_'
clearforce()
r = run({bytes = hb, baud = 9600, fs = 100000})
check('save after a capture succeeds', sdec.save() == true, tostring(sdec.lasterr))
check('save records the filename it used', sdec.savedas == '/usb1/cap_000.txt',
      tostring(sdec.savedas))
check('the note line tells the operator where it went',
      has(sdec.ui_note_text(), 'cap_000.txt'), sdec.ui_note_text())
local saved = MD.logtext()
-- The wire parameters must be IN the file: 4800 8N1 and 9600 7N1 can yield identical
-- bytes from one waveform, so a bare dump cannot be read six months later.
check('the saved file records the baud rate', has(saved, '9600 baud'))
check('the saved file records the format', has(saved, '8N1'))
check('the saved file records the threshold and sample rate',
      has(saved, 'threshold') and has(saved, '100000 S/s'))
-- The gutter is padded to 16 columns, so the closing bar sits past the text.
check('the saved file carries the whole capture as hex + ASCII',
      has(saved, '48 65 6C 6C') and has(saved, '|Hello, World!'))
check('the saved file states that 0 errors is not 0 corruption',
      has(saved, 'corrupts the byte with no error indication'))
-- A second save must not overwrite the first.
check('a second save picks a new name', sdec.save() == true
      and sdec.savedas == '/usb1/cap_001.txt', tostring(sdec.savedas))
-- A failing save must say so and must NOT leave a filename the operator would go
-- looking for on the key.
MD.failwrite(3)
check('a save that fails mid-write returns false', sdec.save() == false)
check('a failed save reports the reason', has(sdec.lasterr, 'save failed'),
      tostring(sdec.lasterr))
check('a failed save claims no filename', sdec.savedas == nil, tostring(sdec.savedas))
MD.failwrite(nil)
MD.usb(false)
check('a save with no USB key fails cleanly rather than raising',
      sdec.save() == false and sdec.lasterr ~= nil, tostring(sdec.lasterr))
MD.usb(true)
sdec.savepfx = '/usb1/serial_'

-- ============================================================================
-- A WIDER FRAME MUST NOT LAUNDER THE EVIDENCE OF DAMAGE
-- ============================================================================
-- The app's worst failure mode is silently wrong bytes with ERR reading 0, and a 9-bit frame on a
-- damaged 8N1 line produced exactly that: it absorbs the broken stop bit into data bit 9, so it
-- reports no errors while every undamaged byte comes back 256 too large. Measured with "any width"
-- selected, 20 bytes with 6 corrupted stop bits decoded as 9N1 with nbad = 0 and 14 of 20 bytes
-- wrong -- the honest 8N1 reading was PENALISED for reporting its 6 real errors.
--
-- THE STRUCTURAL GUARD IS ABOVE: 9 is in neither width list, so the search cannot reach it. The
-- BEHAVIOURAL test is not here, and deliberately not faked: it needs the generator to corrupt
-- individual stop bits, which tools/gen_serial.lua cannot yet do. Proof meanwhile is the standalone
-- repro that found it, which drives the real search over a hand-damaged waveform. See
-- notes/HANDOFF.md -- adding a stop-bit damage option to GEN and folding that repro in here is
-- outstanding work, and a test that silently ran undamaged frames would be worse than none.

-- ============================================================================
-- A FORCED RATE MUST SURVIVE ITS OWN CROSS-CHECK
-- ============================================================================
-- decode_from publishes the forced bit time and then calls sig_bittime() purely to compare the
-- wire against it. sig_bittime is NOT pure -- it nils and re-publishes bittime, baud, baud_raw,
-- fitq and snapped -- so the advisory call overwrote the forced state with a measured one.
-- chunk_decode builds fmt.T from sdec.bittime, so a streaming run then decoded the whole
-- recording at the measured rate and wrote that to the USB byte log; on the frame path the panel
-- drew a measured BAUD in the colour reserved for a pinned one.
do
  clearforce()
  -- 0x00 padding: the widths hold only 9-bit and 3-bit runs, so the greatest-common-period fit
  -- lands on a multiple of the truth. That is the case where the two rates differ most.
  local zb, zn = GEN_BYTES(string.rep('\0', 40))
  sdec.force_baud, sdec.force_nbits, sdec.force_par = 9600, 8, sdec.PAR_NONE
  sdec.force_nstop, sdec.force_invert = 1, false
  local rz = run({bytes = zb, baud = 9600, fs = 40000, gap = 0})
  local want = 40000 / 9600
  check('the published bit time is the FORCED one, not what the cross-check measured',
        sdec.bittime ~= nil and math.abs(sdec.bittime - want) < 0.01,
        string.format('bittime=%s want %.4f', tostring(sdec.bittime), want))
  check('...and so is the published baud rate',
        sdec.baud == 9600, tostring(sdec.baud))
  check('...and it is still marked as snapped/pinned rather than fitted',
        sdec.snapped == true and sdec.fitq == 1,
        string.format('snapped=%s fitq=%s', tostring(sdec.snapped), tostring(sdec.fitq)))
  -- The cross-check must still be able to WARN -- fencing it must not silence it.
  clearforce()
  sdec.force_baud, sdec.force_nbits, sdec.force_par = 4800, 8, sdec.PAR_NONE
  sdec.force_nstop, sdec.force_invert = 1, false
  run({bytes = GEN_BYTES('Hello, World!'), baud = 9600, fs = 40000})
  check('the cross-check still fires its warning after being fenced',
        sdec.rate_note ~= nil, tostring(sdec.rate_note))
  -- THE VERDICT HAS TO SURVIVE THE CELL, and this is the note where that matters most: a wrong
  -- forced rate produces plausible bytes with NO framing error, so ERR reads 0 and this string is
  -- the only thing on the panel contradicting them. Both forms measured 914 px and 990 px against a
  -- 700 px cell, which clipped them to "-- bytes may be..." and "...the bytes are..." -- the word
  -- WRONG, the entire point of the note, cut off. Asserted on the string the real path produced
  -- rather than on a copy of the format, so rewording the source cannot pass this by accident.
  check('...and the whole warning fits the note cell, verdict included',
        sdec.ui_textw(sdec.rate_note) <= sdec.ui_note_px,
        string.format('%d px of %d: %s', sdec.ui_textw(sdec.rate_note), sdec.ui_note_px,
                      tostring(sdec.rate_note)))
  check('...and WRONG is still there after the cell has clipped it',
        has(sdec.ui_fit(sdec.rate_note, sdec.ui_note_px), 'WRONG'),
        sdec.ui_fit(sdec.rate_note, sdec.ui_note_px))
  -- THE OTHER FORM of the same warning: a non-integer ratio takes the "wire measures N baud" branch
  -- rather than the submultiple one, and it clips independently. 10176 on a 9600 wire is +6 %, the
  -- documented silent-corruption edge.
  clearforce()
  sdec.force_baud, sdec.force_nbits, sdec.force_par = 10176, 8, sdec.PAR_NONE
  sdec.force_nstop, sdec.force_invert = 1, false
  run({bytes = GEN_BYTES('Hello, World!'), baud = 9600, fs = 80000})
  check('the +6 % form of the warning fires too',
        sdec.rate_note ~= nil, tostring(sdec.rate_note))
  check('...and it fits the cell with WRONG still readable',
        sdec.rate_note ~= nil and sdec.ui_textw(sdec.rate_note) <= sdec.ui_note_px
        and has(sdec.ui_fit(sdec.rate_note, sdec.ui_note_px), 'WRONG'),
        string.format('%d px of %d: %s',
                      sdec.ui_textw(sdec.rate_note or ''), sdec.ui_note_px,
                      tostring(sdec.rate_note)))
  clearforce()
end

-- ============================================================================
-- CANCEL MUST UNDO WHAT THE FORM DID
-- ============================================================================
-- Lock Detected writes the live forced settings the moment it is pressed, so a Cancel that only
-- closed the screen left the operator with the wire configuration they had just declined -- and
-- reopening the form showed it as though they had chosen it.
do
  clearforce()
  local cb = GEN_BYTES('Hello, World!')
  run({bytes = cb, baud = 9600, fs = 100000})
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.trigmode = 'edge'
  sdec.options()
  check('opening Options snapshots what is in effect', sdec.opt_snap ~= nil)
  local lok = sdec.options_lock()
  check('Lock Detected pins the detected settings', lok == true and sdec.force_baud ~= nil,
        tostring(sdec.force_baud))
  sdec.trigmode = 'free'
  sdec.options_cancel()
  check('Cancel puts the forced settings back as they were',
        sdec.force_baud == nil and sdec.force_nbits == nil and sdec.force_par == nil,
        string.format('baud=%s bits=%s par=%s', tostring(sdec.force_baud),
                      tostring(sdec.force_nbits), tostring(sdec.force_par)))
  check('...and the trigger source too', sdec.trigmode == 'edge', tostring(sdec.trigmode))

  -- EVERY FIELD THE SNAPSHOT COVERS MUST SURVIVE THE ROUND TRIP. A field added to the form and
  -- forgotten in options_save() is the failure mode here: Cancel would silently keep that one
  -- change while putting the others back, which is worse than not undoing at all.
  do
    local want = {baud = 19200, nbits = 7, par = sdec.PAR_ODD, nstop = 2, invert = true,
                  proto = 'uart', any = true, trig = 'front', ext = true, fc = true,
                  view = 'hex'}
    sdec.force_baud, sdec.force_nbits = want.baud, want.nbits
    sdec.force_par, sdec.force_nstop, sdec.force_invert = want.par, want.nstop, want.invert
    sdec.proto, sdec.widths_any = want.proto, want.any
    sdec.trigmode, sdec.trigext, sdec.fc_out = want.trig, want.ext, want.fc
    sdec.ui_mode = want.view
    sdec.options_save()
    -- Stamp every one of them with something different, as the form would.
    sdec.force_baud, sdec.force_nbits = 300, 8
    sdec.force_par, sdec.force_nstop, sdec.force_invert = sdec.PAR_NONE, 1, false
    sdec.widths_any, sdec.trigmode = false, 'free'
    sdec.trigext, sdec.fc_out, sdec.ui_mode = false, false, 'text'
    sdec.options_restore()
    local got = {baud = sdec.force_baud, nbits = sdec.force_nbits, par = sdec.force_par,
                 nstop = sdec.force_nstop, invert = sdec.force_invert, proto = sdec.proto,
                 any = sdec.widths_any, trig = sdec.trigmode, ext = sdec.trigext,
                 fc = sdec.fc_out, view = sdec.ui_mode}
    local miss, nm = {}, 0
    local k, v
    for k, v in pairs(want) do
      if got[k] ~= v then
        nm = nm + 1
        miss[nm] = string.format('%s: %s not %s', k, tostring(got[k]), tostring(v))
      end
    end
    check('Cancel restores every field the form can change, not just some of them', nm == 0,
          nm == 0 and '11 fields round-tripped' or table.concat(miss, ' | '))
    -- A restore with no snapshot must decline rather than nil out live settings.
    sdec.opt_snap = nil
    check('a restore with nothing snapshotted declines instead of clearing the settings',
          sdec.options_restore() == false and sdec.force_baud == want.baud,
          tostring(sdec.force_baud))
    clearforce()
    sdec.trigmode, sdec.trigext, sdec.fc_out = 'edge', false, false
    sdec.widths_any, sdec.ui_mode = false, 'text'
  end

  -- Apply, by contrast, must KEEP them: the two buttons have to differ.
  sdec.options()
  sdec.options_lock()
  local kept = sdec.force_baud
  sdec.options_apply()
  check('Apply keeps what Lock Detected pinned, so the two buttons differ',
        sdec.force_baud == kept and kept ~= nil, tostring(sdec.force_baud))
  clearforce()
end

-- ============================================================================
-- EVERY OPTIONS FORMAT FIELD MUST WORK ON ITS OWN
-- ============================================================================
-- The forced-format shortcut in decode_from() runs only when the WIDTH is forced, so parity,
-- stop bits and polarity set on their own were read by nothing: three live Options fields that
-- changed the decode only in combination with a fourth. Each now narrows the search's candidate
-- list instead, so each is independently effective.
--
-- Judged on the REPORTED FORMAT, not on the bytes: a wrong forced setting is allowed to produce
-- wrong bytes -- that is the operator's choice, and the error count says so. What must not happen
-- is the app quietly deciding it knew better and reporting a format nobody asked for.
do
  clearforce()
  local pb, pn = GEN_BYTES('Hello, World!')

  -- 7E1 on the wire, so a forced parity that disagrees is visible in the report.
  local function cap7e1()
    return run({bytes = pb, baud = 9600, fs = 100000, nbits = 7, par = 1})
  end

  clearforce()
  local ra = cap7e1()
  check('with nothing forced, a 7E1 line is detected as 7E1',
        ra ~= nil and ra.nbits == 7 and ra.par == 1,
        string.format('nbits=%s par=%s', tostring(ra and ra.nbits), tostring(ra and ra.par)))

  clearforce()
  sdec.force_par = sdec.PAR_NONE
  local rb = cap7e1()
  check('PARITY forced NONE is honoured on its own, with no width forced',
        rb ~= nil and rb.par == sdec.PAR_NONE,
        string.format('par=%s (fmt %s)', tostring(rb and rb.par), tostring(sdec.fmt_text())))

  clearforce()
  sdec.force_par = sdec.PAR_ODD
  local rc = cap7e1()
  check('...and so is ODD, even though the wire is EVEN',
        rc ~= nil and rc.par == sdec.PAR_ODD,
        string.format('par=%s (fmt %s)', tostring(rc and rc.par), tostring(sdec.fmt_text())))

  clearforce()
  sdec.force_nstop = 2
  local rd2 = cap7e1()
  check('STOP BITS forced to 2 is honoured on its own',
        rd2 ~= nil and rd2.nstop == 2, tostring(rd2 and rd2.nstop))

  -- Polarity forced against the wire must be OBEYED, not overturned by a score. The bytes are
  -- then wrong, which is the point: the operator asked for a reading the wire does not support.
  clearforce()
  sdec.force_invert = true
  local re = cap7e1()
  check('POLARITY forced inverted is honoured on its own, not overturned by the contest',
        re ~= nil and re.invert == true, tostring(re and re.invert))
  clearforce()
  sdec.force_invert = false
  local rf = cap7e1()
  check('...and forced normal likewise', rf ~= nil and rf.invert == false,
        tostring(rf and rf.invert))

  -- AUTO-LOCK MUST NOT OVERWRITE WHAT THE OPERATOR PINNED. It locks the rate, which is the whole
  -- speed win, and leaves the hand-set fields alone -- otherwise a setting chosen in Options
  -- survives exactly one capture and the form reads back the detected value instead.
  clearforce()
  sdec.force_par = sdec.PAR_ODD
  sdec.autolock = true
  cap7e1()
  sdec.autolock_try()
  check('auto-lock still pins the baud rate when parity was forced by hand',
        sdec.force_baud ~= nil, tostring(sdec.force_baud))
  check('...but leaves the hand-forced parity exactly as the operator set it',
        sdec.force_par == sdec.PAR_ODD,
        string.format('par=%s, wire was EVEN', tostring(sdec.force_par)))

  clearforce()
  sdec.force_nstop = 2
  cap7e1()
  sdec.autolock_try()
  check('and a hand-forced stop count survives auto-lock too',
        sdec.force_nstop == 2, tostring(sdec.force_nstop))
  clearforce()
end

-- ============================================================================
print('\nUI build, refresh and object lifetime (real code, hostile mock)')
-- ============================================================================
clearforce()
MD.usb(true)
-- A payload longer than one hex page (16 x 12 = 192 bytes), so paging is actually
-- exercised rather than trivially satisfied.
local ULONG = LONG .. LONG .. LONG .. LONG
local ulgb, ulgn = GEN_BYTES(ULONG)
local urd, uts, unc, un = GEN({bytes = ulgb, baud = 9600, fs = 100000, lead = 20,
                               n = 50000})
SRC.rd, SRC.ts, SRC.trigat = urd, uts, nil
sdec.fs, sdec.n, sdec.trigmode, sdec.range = 100000, 50000, 'free', 10

-- Clear anything the acquisition section left behind, so the buffer baseline is a
-- real zero rather than whatever happened to be alive.
sdec.stop()
check('nothing is live before start()', MD.live() == 0, 'live=' .. MD.live())
local base_bufs = LIVEBUFS()
local sok, serr = sdec.start()
check('start() succeeds', sok, tostring(serr))
local live1, bufs1 = MD.live(), LIVEBUFS()
check('start() created objects', live1 > 0, 'live=' .. live1)
check('exactly two screens are live', MD.live('screen') == 2,
      'screens=' .. MD.live('screen'))
check('there is no frame timer -- a single-shot app needs none',
      MD.live('timer') == 0, 'timers=' .. MD.live('timer'))
check('the first capture ran and decoded', sdec.res ~= nil and sdec.res.nf == ulgn,
      string.format('%s of %d bytes', sdec.res and tostring(sdec.res.nf) or 'nil', ulgn))
-- The header is a strip of fixed fields, each its own object at its own x, so
-- columns line up in a proportional font. Check the values landed in the right
-- ones rather than looking for a run-on string.
check('the header fields reached the panel',
      MD.text(sdec.ui_fval[1]) == '9600' and MD.text(sdec.ui_fval[2]) == '8N1'
      and MD.text(sdec.ui_fval[3]) == 'HIGH',
      table.concat({tostring(MD.text(sdec.ui_fval[1])), tostring(MD.text(sdec.ui_fval[2])),
                    tostring(MD.text(sdec.ui_fval[3]))}, ' / '))
check('the field labels are static and correct',
      MD.text(sdec.ui_flab[1]) == 'BAUD' and MD.text(sdec.ui_flab[2]) == 'FORMAT',
      tostring(MD.text(sdec.ui_flab[1])))
-- ui_flab carries one extra entry: the static NOTE label for the table's second
-- row, kept there so teardown deletes it explicitly rather than relying on the
-- parent cascade.
check('every field has both a label and a value object, plus the NOTE label',
      table.getn(sdec.ui_flab) == table.getn(sdec.ui_fields) + 1
      and table.getn(sdec.ui_fval) == table.getn(sdec.ui_fields),
      table.getn(sdec.ui_fval) .. ' values, ' .. table.getn(sdec.ui_flab) .. ' labels')
-- Fields must not run into each other: each value has to fit the gap to the next
-- column. Width is checked in tools/render_png.py against real font metrics; here
-- the check is that the columns are at least ordered and non-overlapping in x.
check('field columns are strictly left to right', (function()
  local i
  for i = 2, table.getn(sdec.ui_fields) do
    if sdec.ui_fields[i].x <= sdec.ui_fields[i-1].x then return false end
  end
  return sdec.ui_fields[table.getn(sdec.ui_fields)].x < 798
end)())
check('the decoded text reached a dump row', has(MD.text(sdec.ui_row[1]), 'The quick'),
      tostring(MD.text(sdec.ui_row[1])))
check('End App is hooked on the main screen',
      MD.events(sdec.ui_scr) ~= nil and MD.events(sdec.ui_scr)['endapp'] == 'sdec.cleanup()')
check('End App is hooked on the options screen too',
      MD.events(sdec.optscr) ~= nil and MD.events(sdec.optscr)['endapp'] == 'sdec.cleanup()')
check('the capture was logged to USB', has(MD.logtext(), '9600 baud'),
      'log has ' .. tostring(MD.loglines()) .. ' writes')

-- Rebuilding must not orphan the first build. This is THE invariant.
sdec.ui_build()
sdec.build_options()
check('rebuilding the UI leaks NO display objects', MD.live() == live1,
      'live=' .. MD.live() .. ' vs ' .. live1)
check('still exactly two screens after a rebuild', MD.live('screen') == 2,
      'screens=' .. MD.live('screen'))
check('no deletion was refused', sdec.delfails == 0, 'delfails=' .. tostring(sdec.delfails))

-- A refresh must not create or delete anything, and must skip unchanged text.
sdec.ui_refresh()
local sets = MD.obj(sdec.ui_row[1]).sets or 0
sdec.ui_refresh()
sdec.ui_refresh()
check('an unchanged refresh costs ZERO display writes',
      (MD.obj(sdec.ui_row[1]).sets or 0) == sets,
      string.format('%d writes vs %d', MD.obj(sdec.ui_row[1]).sets or 0, sets))

-- ONE OBJECT, ONE SHADOW CACHE. The ERR field used to be written twice per refresh -- once by
-- the generic value loop from ui_field_colour, then again by a special-case block behind its
-- OWN cache -- so the two caches disagreed about the colour the object actually had. It worked
-- only because the special case ran last. The regression this pins is the disagreement itself:
-- with errors present the object is red, so the cache must say red. Under the two-writer
-- version it said the plain column colour, and the first thing to change ui_field_colour's
-- answer for this field would have repainted a red error count green -- with the error cache
-- still saying red, so it would never have been repainted back.
local ef = sdec.ui_errfield
local nbad0 = sdec.res.nbad
check('a clean decode shows the ERR count in the column colour',
      MD.obj(sdec.ui_fval[ef]).color == sdec.ui_fields[ef].c,
      string.format('%06X vs %06X', MD.obj(sdec.ui_fval[ef]).color or 0,
                    sdec.ui_fields[ef].c))
-- An INTERIOR error, injected where it counts. Setting r.nbad alone no longer drives the
-- colour: ERR reports interior errors only, so a boundary frame -- which every capture of a
-- gapless line has -- cannot turn it red. The error therefore has to be placed in a frame
-- that is neither in the resync head nor the clipped tail.
sdec.res.nbad = 1
sdec.res.errs[math.floor(sdec.res.nf / 2)] = 'framing'
sdec.ui_refresh()
check('framing errors turn the ERR count RED',
      MD.obj(sdec.ui_fval[ef]).color == sdec.ui_c_err,
      string.format('%06X', MD.obj(sdec.ui_fval[ef]).color or 0))
check('and the cache agrees with the colour the object actually has',
      sdec.ui_fvalc[ef] == MD.obj(sdec.ui_fval[ef]).color,
      string.format('cache %06X vs object %06X', sdec.ui_fvalc[ef] or 0,
                    MD.obj(sdec.ui_fval[ef]).color or 0))
sdec.res.nbad = nbad0
sdec.res.errs[math.floor(sdec.res.nf / 2)] = nil
sdec.ui_refresh()
check('clearing the errors takes the red back off -- the cache does not pin it',
      MD.obj(sdec.ui_fval[ef]).color == sdec.ui_fields[ef].c and
      sdec.ui_fvalc[ef] == sdec.ui_fields[ef].c,
      string.format('%06X', MD.obj(sdec.ui_fval[ef]).color or 0))

-- ============================================================================
print('\nview and paging handlers (real code)')
-- ============================================================================
sdec.ui_mode = 'text'
sdec.ui_refresh()
local tpages = sdec.ui_npages()
sdec.view_toggle()
check('the toggle switches to hex', sdec.ui_mode == 'hex', sdec.ui_mode)
-- THREE FIELDS, one per column, each at its own fixed x -- so the ASCII block cannot drift
-- into the hex block whatever the firmware font's character advance turns out to be.
check('the hex view puts the OFFSET in the first field, alone',
      MD.text(sdec.ui_row[1]) == '0000', tostring(MD.text(sdec.ui_row[1])))
-- 'The quick brown ' is the payload here, so 54 is 'T' and 68 is 'h'. Asserted structurally as
-- well as by content: the hex field must be nothing BUT hex pairs and spaces, which is what
-- catches an offset or a stray delimiter leaking into the wrong column.
check('the hex bytes are their own field, and only hex',
      has(MD.text(sdec.ui_rhx[1]), '54 68') and
      string.find(MD.text(sdec.ui_rhx[1]), '^[0-9A-F%- ]+$') ~= nil,
      tostring(MD.text(sdec.ui_rhx[1])))
check('and the characters are theirs',
      has(MD.text(sdec.ui_ras[1]), 'The quick'), tostring(MD.text(sdec.ui_ras[1])))
check('the ASCII field is exactly one character per column',
      string.len(MD.text(sdec.ui_ras[1])) == 16,
      string.format('%d chars', string.len(MD.text(sdec.ui_ras[1]))))
-- The '|' delimiters are the rules' job now. On screen they must be GONE, or the pipes and the
-- rule objects both mark the same edge and the column reads as double-walled.
check('no field carries a | -- the vertical RULES delimit the ASCII column now',
      not has(MD.text(sdec.ui_row[1]), '|') and not has(MD.text(sdec.ui_rhx[1]), '|')
      and not has(MD.text(sdec.ui_ras[1]), '|'),
      tostring(MD.text(sdec.ui_ras[1])))
-- TWO, not three. The third closed the ASCII gutter on the right, and there is no correct
-- place for it: the gutter holds arbitrary bytes, so its rendered width is not knowable in
-- advance (mixed-case measures 7.80 px/char, a row of 'W's does not), and a boundary the
-- content can cross is worse than none. Nothing follows the gutter, so nothing needs closing.
check('and there are TWO of them, spanning the dump block',
      table.getn(sdec.ui_vr) == 2, tostring(table.getn(sdec.ui_vr or {})))
-- THE RULES BELONG TO A DUMP, so they need BOTH a hex view and a mode that paints rows. A
-- streaming mode paints none, and on the view test alone three rules stood over an empty area
-- delimiting nothing -- which the MOCKUP caught, not this suite, so it is pinned here now.
-- Asserted on ui_vrc, the shadow cache the fill is written from.
-- do...end, NOT two more top-level locals: this file's main chunk is at Lua 5.0's 200-active-local
-- ceiling, and adding them raised 'too many local variables (limit is 200) in main function' 900
-- lines further down. A nested block releases its registers at `end`, which is the cheap version
-- of the wrap-a-section-in-a-function fix used elsewhere in this file.
do
  local vr_hex = sdec.ui_vrc
  sdec.capmode = 'med'
  sdec.ui_refresh()
  local vr_stream = sdec.ui_vrc
  sdec.capmode = 'frame'
  sdec.ui_refresh()
  check('the dump rules hide in a mode that paints no rows, and come back',
        vr_hex == sdec.ui_c_rule and vr_stream == sdec.ui_c_hide and
        sdec.ui_vrc == sdec.ui_c_rule,
        string.format('hex=%s stream=%s back=%s', tostring(vr_hex), tostring(vr_stream),
                      tostring(sdec.ui_vrc)))
end
-- ...but the FILE form is unchanged: a log line has to be parseable standing alone, where the
-- pipes are the only thing marking where the ASCII field starts.
check('the FILE form keeps its |ascii| delimiters',
      has(sdec.ua_hex_line(1, 16), '|'), sdec.ua_hex_line(1, 16))
-- Columns are computed from ui_ch_w, so a wider font must not push the ASCII block under the
-- position bar. This is the assertion that catches a bad bench measurement being pasted in.
check('every dump column clears the position bar',
      sdec.ui_vr3_x < sdec.ui_sb_x and sdec.ui_col_as > sdec.ui_vr2_x
      and sdec.ui_col_hx > sdec.ui_vr1_x,
      string.format('vr3=%d sb=%d', sdec.ui_vr3_x, sdec.ui_sb_x))
-- EVERY FIELD MUST LEAVE A POSITIVE GAP BEFORE THE NEXT RULE, measured from the string it
-- actually produces rather than from the ui_*n constant that is supposed to describe it. The two
-- disagreed: ua_hexparts emitted '%02X ' -- 48 characters for a 47-character field -- so the last
-- byte painted exactly on the divider. The mockup showed it and nothing failed, because the only
-- check that existed compared HEADER columns. This is the dump's version of that check.
local gix, ghx, ghx2, gas = sdec.ua_hexparts({65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80},
                                             {}, 16, 1, 16, 0)
local gw = sdec.ui_ch_w
check('the offset field clears rule 1',
      sdec.ui_col_ix + string.len(gix) * gw < sdec.ui_vr1_x,
      string.format('ends %d, rule at %d', sdec.ui_col_ix + string.len(gix) * gw, sdec.ui_vr1_x))
check('the hex block clears rule 2 -- the one that was 0 px',
      sdec.ui_col_hx + string.len(ghx) * gw < sdec.ui_vr2_x,
      string.format('%d chars ends %d, rule at %d', string.len(ghx),
                    sdec.ui_col_hx + string.len(ghx) * gw, sdec.ui_vr2_x))
-- The SECOND hex group must clear rule 2 as well, and it is the one that can overrun: it starts a
-- whole group plus a gap along, so any widening of the first group pushes it right.
check('the second hex group clears rule 2',
      sdec.ui_col_hx2 + string.len(ghx2) * gw < sdec.ui_vr2_x,
      string.format('%d chars ends %d, rule at %d', string.len(ghx2),
                    sdec.ui_col_hx2 + string.len(ghx2) * gw, sdec.ui_vr2_x))
-- The two groups must not overlap each other -- the whole reason for splitting the row.
check('the two hex groups do not overlap',
      sdec.ui_col_hx + string.len(ghx) * gw < sdec.ui_col_hx2,
      string.format('group 1 ends %d, group 2 starts %d',
                    sdec.ui_col_hx + string.len(ghx) * gw, sdec.ui_col_hx2))
-- The ASCII block must fit on the 800 px screen, clear of the right-margin buttons. Rule 3 was
-- removed from the layout (it could not be placed far enough right without crowding the buttons),
-- so the screen edge is what it is checked against now.
check('the ASCII block fits on screen',
      sdec.ui_col_as + string.len(gas) * gw < 700,
      string.format('ends %d', sdec.ui_col_as + string.len(gas) * gw))
-- ...and the constants must MATCH the strings, so a future edit to either is caught.
check('ui_hxn and ui_asn describe the strings ua_hexparts actually returns',
      string.len(ghx) == sdec.ui_hxn and string.len(ghx2) == sdec.ui_hxn
      and string.len(gas) == sdec.ui_asn and string.len(gix) == sdec.ui_ixn,
      string.format('ix %d/%d hx %d+%d/%d as %d/%d', string.len(gix), sdec.ui_ixn,
                    string.len(ghx), string.len(ghx2), sdec.ui_hxn,
                    string.len(gas), sdec.ui_asn))
check('hex needs more pages than text for the same capture',
      sdec.ui_npages() > tpages,
      string.format('hex %d pages vs text %d', sdec.ui_npages(), tpages))
check('the status line names the view and the page',
      has(MD.text(sdec.ui_page_t), 'HEX') and has(MD.text(sdec.ui_page_t), 'pg 1/'),
      tostring(MD.text(sdec.ui_page_t)))

-- The page buttons must hide when there is nowhere to page to, and appear when there is.
do
  local vis = function()
    local b = sdec.ui_pgbtn and sdec.ui_pgbtn[1]
    local o = b and MD.obj(b)
    return o and o.state
  end
  sdec.ui_refresh()
  local multi = sdec.ui_npages() > 1
  check('the page buttons follow the page count -- shown only when there is a page 2',
        (multi and vis() == display.STATE_ENABLE)
        or ((not multi) and vis() == display.STATE_INVISIBLE),
        string.format('%d pages, state=%s', sdec.ui_npages(), tostring(vis())))
end

sdec.page_prev()
check('prev on the first page stays put', sdec.ui_page == 0, tostring(sdec.ui_page))
sdec.page_next()
check('next advances', sdec.ui_page == 1, tostring(sdec.ui_page))
check('the second page shows a later offset',
      not has(MD.text(sdec.ui_row[1]), '0000'), tostring(MD.text(sdec.ui_row[1])))
for i = 1, 50 do sdec.page_next() end
check('next cannot run past the last page', sdec.ui_page == sdec.ui_npages() - 1,
      string.format('page %d of %d', sdec.ui_page + 1, sdec.ui_npages()))
-- Four views now, cycled by one button: text -> hex -> midi -> lin -> text. The cycle
-- reads sdec.ui_views, so this also asserts that adding a protocol needs no change here.
sdec.view_toggle()
check('the third view is the MIDI message list', sdec.ui_mode == 'midi', sdec.ui_mode)
check('entering the MIDI view parses the captured bytes', sdec.midi ~= nil)
check('the MIDI view pages by messages and says so',
      has(MD.text(sdec.ui_page_t), 'MIDI') and has(MD.text(sdec.ui_page_t), 'msg '),
      tostring(MD.text(sdec.ui_page_t)))
check('switching view resets to page 1', sdec.ui_page == 0, tostring(sdec.ui_page))
sdec.view_toggle()
check('the fourth view is the LIN frame list', sdec.ui_mode == 'lin', sdec.ui_mode)
check('entering the LIN view parses the captured bytes even on a non-LIN stream',
      sdec.lin ~= nil)
check('the LIN view pages by frames and says so',
      has(MD.text(sdec.ui_page_t), 'LIN') and has(MD.text(sdec.ui_page_t), 'frame '),
      tostring(MD.text(sdec.ui_page_t)))
check('a plain UART capture yields no LIN frames rather than inventing some',
      sdec.lin.nframes == 0, tostring(sdec.lin.nframes) .. ' frames')
sdec.view_toggle()
check('cycling once more returns to text',
      sdec.ui_mode == 'text' and sdec.ui_page == 0, sdec.ui_mode)
-- ---------------------------------------------------------------------------
-- THE VERSION 1 DESCOPE. The shipped .tspa omits midi_decode.tsp and
-- lin_decode.tsp, so the app must behave as though those protocols do not exist
-- rather than offering controls with nothing behind them. The harness DOES load
-- both modules, so absence is simulated by hiding the two parse functions --
-- which is exactly the condition a build without them presents.
--
-- Tested because a descope that only removes a line from the packager is a
-- descope that ships an Options field selecting a protocol the app cannot decode
-- and a View button landing on a permanently empty list.
do
  local savedmi, savedli = sdec.mi_parse, sdec.li_parse
  local nfull = sdec.ui_nviews()
  sdec.mi_parse, sdec.li_parse = nil, nil

  check('with both protocol modules absent only TEXT and HEX remain',
        sdec.ui_nviews() == 2,
        string.format('%d of %d views', sdec.ui_nviews(), nfull))
  check('...and ui_view() reports the MIDI view as absent, so existing nil '
        .. 'guards cover it', sdec.ui_view('midi') == nil)
  local pv, pl = sdec.opt_proto_list()
  check('...the Protocol option offers UART alone',
        pv.n == 1 and pv[1] == 'uart' and pl[1] == 'UART',
        string.format('n=%d first=%s', pv.n, tostring(pv[1])))

  -- The button must CYCLE, not stall or land on a hidden view.
  sdec.ui_mode = 'text'
  sdec.view_toggle()
  local a = sdec.ui_mode
  sdec.view_toggle()
  local b = sdec.ui_mode
  check('...and View cycles text -> hex -> text with nothing in between',
        a == 'hex' and b == 'text', tostring(a) .. ' -> ' .. tostring(b))

  -- Starting FROM a hidden view must recover rather than get stuck: an operator
  -- who selected MIDI, then installed a build without it, keeps the saved mode.
  sdec.ui_mode = 'midi'
  sdec.view_toggle()
  check('...a stale MIDI mode from a previous build recovers on the next press',
        sdec.ui_mode == 'text' or sdec.ui_mode == 'hex', tostring(sdec.ui_mode))

  sdec.mi_parse, sdec.li_parse = savedmi, savedli
  check('restoring the modules restores every view -- the switch is the MODULE, '
        .. 'nothing else', sdec.ui_nviews() == nfull,
        string.format('%d of %d', sdec.ui_nviews(), nfull))
  sdec.ui_mode = 'text'
end

-- ---------------------------------------------------------------------------
-- NO HORIZONTAL RULE MAY BE STRUCK THROUGH A TEXT ROW.
--
-- A text object's y is the BOTTOM of its glyph box, so its ink occupies
-- [y - ui_ink + 1, y] and it grows UPWARD. Every rule in this layout was originally
-- placed as though y were the top, so four of them -- above the header labels, the
-- FRAME mode cell, the first dump row and the status line -- landed inside the ink of
-- the row above and rendered as a strike-through. See sdec.ui_ink.
--
-- THIS TEST EXISTS BECAUSE THE PANEL COSTS A POWER CYCLE TO LOOK AT. One UI build per
-- power cycle means a layout mistake is not a quick retry: it is a rebuild, and until
-- display.setfill was fixed the rules did not paint at all, so six sessions of
-- screenshots could not have shown it either. Geometry has to be checkable offline.
do
  -- Per-font ink: FONT_MEDIUM is 17 px tall against FONT_SMALL's 12, and using one height
  -- for both is what let the BAUD value overlap its own label undetected.
  local ink = sdec.ui_ink or 12
  local bad, nbad2 = {}, 0
  local i, j
  for i = 1, MD.nobj() do
    local r = MD.obj(i)
    -- A horizontal rule: a live 1 px-tall rect.
    if r ~= nil and r.alive and r.kind == display.OBJ_RECT and r.h == 1
       and r.x ~= nil and r.w ~= nil then
      for j = 1, MD.nobj() do
        local t = MD.obj(j)
        if t ~= nil and t.alive and t.kind == display.OBJ_TEXT
           and t.x ~= nil and t.y ~= nil then
          -- Only if they overlap horizontally. A rule beside a text object is fine.
          local tw = string.len(t.text or '') * (sdec.ui_ch_w or 8)
          if tw < 8 then tw = 8 end
          if t.x < r.x + r.w and r.x < t.x + tw then
            local tink = ink
            if t.font == display.FONT_MEDIUM then tink = sdec.ui_ink_med or 17 end
            if r.y <= t.y and r.y > t.y - tink then
              nbad2 = nbad2 + 1
              if nbad2 <= 4 then
                bad[nbad2] = string.format('rule y=%d through text y=%d %q',
                                           r.y, t.y, string.sub(t.text or '', 1, 18))
              end
            end
          end
        end
      end
    end
  end
  -- TEXT MUST NOT OVERLAP TEXT EITHER. The rule check above would never have caught the
  -- BAUD value sitting on the BAUD label: no rule was involved, just two rows whose ink boxes
  -- intersected because one of them uses the taller font.
  do
    local ov, no = {}, 0
    local a, bq
    for a = 1, MD.nobj() do
      local t1 = MD.obj(a)
      if t1 ~= nil and t1.alive and t1.kind == display.OBJ_TEXT
         and t1.x ~= nil and t1.y ~= nil and (t1.text or '') ~= '' then
        for bq = a + 1, MD.nobj() do
          local t2 = MD.obj(bq)
          if t2 ~= nil and t2.alive and t2.kind == display.OBJ_TEXT
             and t2.x ~= nil and t2.y ~= nil and (t2.text or '') ~= '' then
            local i1 = ink
            if t1.font == display.FONT_MEDIUM then i1 = sdec.ui_ink_med or 17 end
            local i2 = ink
            if t2.font == display.FONT_MEDIUM then i2 = sdec.ui_ink_med or 17 end
            -- Advance per STRING, not one for all: uppercase measures 9.67 px/char and
            -- mixed-case 7.80, so charging 10 px to a lowercase status line overstates it by
            -- a quarter and reports neighbouring cells as overlapping when they do not.
            local function adv(t)
              if string.find(t, '%l') then return sdec.ui_adv_mixed or 8 end
              return sdec.ui_adv_upper or 10
            end
            local w1 = string.len(t1.text) * adv(t1.text)
            local w2 = string.len(t2.text) * adv(t2.text)
            local xo = t1.x < t2.x + w2 and t2.x < t1.x + w1
            local yo = t1.y - i1 + 1 <= t2.y and t2.y - i2 + 1 <= t1.y
            if xo and yo then
              no = no + 1
              if no <= 3 then
                ov[no] = string.format('%q(y=%d) over %q(y=%d)',
                                       string.sub(t1.text, 1, 10), t1.y,
                                       string.sub(t2.text, 1, 10), t2.y)
              end
            end
          end
        end
      end
    end
    check('no text row overlaps another text row', no == 0,
          no == 0 and 'clear' or (tostring(no) .. ': ' .. table.concat(ov, ' | ')))
  end

  check('no horizontal rule is struck through a text row', nbad2 == 0,
        nbad2 == 0 and 'clear' or (tostring(nbad2) .. ': '
        .. table.concat(bad, ' | ')))
end

-- ---------------------------------------------------------------------------
-- AUTO-LOCK. Locks the wire parameters after a confident detection so later
-- captures skip both the extra detect capture and the format search -- measured on
-- the instrument as 5.2 s and 17 bytes unlocked against 1.6 s and 227 bytes locked.
--
-- The tests that matter are the ones about WHAT IT REFUSES, because a wrong lock is
-- persistent: it converts a one-capture mistake into every later capture's mistake.
do
  local LOREM2 = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do ' ..
                 'eiusmod tempor incididunt ut labore et dolore magna aliqua'
  local lb2 = GEN_BYTES(LOREM2)
  local function fresh(opts)
    clearforce()
    sdec.autolock, sdec.autolock_skip = true, nil
    sdec.autolocknote = nil
    return run(opts)
  end

  local rr2 = fresh({bytes = lb2, baud = 9600, fs = 100000, gap = 2})
  sdec.autolock_try()
  check('a clean capture auto-locks the baud rate and frame shape',
        sdec.force_baud == 9600 and sdec.force_nbits == 8,
        string.format('baud=%s bits=%s', tostring(sdec.force_baud),
                      tostring(sdec.force_nbits)))
  check('...but NOT the polarity, which is re-derived every capture',
        sdec.force_invert == nil, tostring(sdec.force_invert))
  check('...and it says so on the note line, naming the payoff',
        sdec.autolocknote ~= nil and has(sdec.autolocknote, 'auto-locked')
        and has(sdec.autolocknote, 'kS/s') and has(sdec.autolocknote, ' B '),
        tostring(sdec.autolocknote))
  -- The note is only useful if the panel can DRAW it. The firmware clips at the panel edge
  -- silently, so a note that outgrows the cell loses its tail with nothing to say it did.
  check('...and the note fits the note cell without being clipped',
        sdec.ui_textw(sdec.autolocknote) <= sdec.ui_note_px,
        string.format('%d px of %d', sdec.ui_textw(sdec.autolocknote), sdec.ui_note_px))

  -- An explicit request for auto-detect must survive the capture that follows it.
  clearforce()
  sdec.autolock_defer()
  fresh_ok = nil
  local rr3 = run({bytes = lb2, baud = 9600, fs = 100000, gap = 2})
  sdec.autolock_try()
  check('an explicit auto-detect request is NOT undone by the next capture',
        sdec.force_baud == nil, tostring(sdec.force_baud))
  -- ...but only for one capture: the request was "detect it", not "never lock".
  local rr4 = run({bytes = lb2, baud = 9600, fs = 100000, gap = 2})
  sdec.autolock_try()
  check('...and the capture after THAT locks normally',
        sdec.force_baud == 9600, tostring(sdec.force_baud))

  -- Too few frames to be sure of anything.
  clearforce()
  sdec.autolock, sdec.autolock_skip = true, nil
  local short = {}
  local si
  for si = 1, 3 do short[si] = lb2[si] end
  run({bytes = short, baud = 9600, fs = 100000, gap = 2})
  sdec.autolock_try()
  check('three frames is too little evidence to lock on',
        sdec.force_baud == nil,
        string.format('%s from %s frames', tostring(sdec.force_baud),
                      tostring(sdec.res and sdec.res.nf)))

  clearforce()
  sdec.autolock = true
end
clearforce()

-- The cycle must be driven by the table, not by a hardcoded chain.
check('the view cycle covers every entry in sdec.ui_views',
      (function()
         local seen, i = {}, nil
         for i = 1, table.getn(sdec.ui_views) do
           seen[sdec.ui_mode] = true
           sdec.view_toggle()
         end
         if sdec.ui_mode ~= 'text' then return false end
         for i = 1, table.getn(sdec.ui_views) do
           if seen[sdec.ui_views[i].mode] == nil then return false end
         end
         return true end)())

-- ============================================================================
print('\noptions form round trip (real code)')
-- ============================================================================
sdec.options()
check('options() switches to the form', display.active == sdec.optscr)
-- No range field: the app is fixed at 10 V, the widest digitize bandwidth (440 kHz
-- against 17 kHz on the 100 V and 1000 V ranges), with a divider for anything bigger.
check('the range is fixed at 10 V and not offered as a field',
      sdec.range == 10 and sdec.opt_rng == nil, tostring(sdec.range))
display.setvalue(sdec.opt_baud, 9600)
display.setvalue(sdec.opt_bits, 6)         -- entry 6 = "8" (1/2 are the Auto pair)
display.setvalue(sdec.opt_par, 2)          -- entry 2 = "None"
display.setvalue(sdec.opt_pol, 2)          -- entry 2 = "Normal"
display.setvalue(sdec.opt_trig, 2)         -- free run
sdec.options_apply()
check('apply forces the protocol settings',
      sdec.force_baud == 9600 and sdec.force_nbits == 8
      and sdec.force_par == sdec.PAR_NONE and sdec.force_invert == false,
      string.format('%s %s %s %s', tostring(sdec.force_baud), tostring(sdec.force_nbits),
                    tostring(sdec.force_par), tostring(sdec.force_invert)))
check('apply sets the hardware settings',
      sdec.range == 10 and sdec.trigmode == 'free',
      string.format('range=%s trig=%s', tostring(sdec.range), tostring(sdec.trigmode)))
check('apply returns to the main screen', display.active == sdec.ui_scr)
check('apply re-captures rather than waiting to be asked',
      sdec.res ~= nil and sdec.res.nf == ulgn, sdec.res and tostring(sdec.res.nf) or 'nil')

-- PARITY ON ITS OWN, WITH THE WIDTH LEFT AUTOMATIC. The search narrows to the forced parity
-- (sdec.ua_parities), so the setting takes effect without pinning a width -- which matters,
-- because pinning 8 to make parity work would force 8E1 onto a 7E1 line and raise framing
-- errors on a line the app could otherwise have read.
sdec.options()
display.setvalue(sdec.opt_baud, 0)
display.setvalue(sdec.opt_bits, 1)         -- Auto
display.setvalue(sdec.opt_par, 3)          -- Even
sdec.options_apply()
check('forcing parity alone applies the parity and leaves the width automatic',
      sdec.force_par == sdec.PAR_EVEN and sdec.force_nbits == nil,
      string.format('bits=%s par=%s', tostring(sdec.force_nbits), tostring(sdec.force_par)))

sdec.options()
display.setvalue(sdec.opt_bits, 1)
display.setvalue(sdec.opt_par, 1)          -- back to Auto/Auto
display.setvalue(sdec.opt_trig, 1)
sdec.options_apply()
check('cancel just returns without applying',
      (function() sdec.options(); sdec.options_cancel()
         return display.active == sdec.ui_scr end)())

-- LOCK DETECTED: probe an unknown line once, then pin the answer. The reason this
-- matters is that a forced baud rate skips the pulse-width fit entirely, and the fit is
-- the stage impulse noise captures -- so locking is the strongest lever on a spiky line.
clearforce()
SRC.rd, SRC.ts = urd, uts
sdec.trigmode = 'free'
sdec.capture()
local dbaud, dbits = sdec.baud, sdec.res.nbits
sdec.options()
check('lock detected copies the detected parameters into the forced fields',
      sdec.options_lock() == true and sdec.force_baud == dbaud
      and sdec.force_nbits == dbits and sdec.force_par == sdec.PAR_NONE
      and sdec.force_invert == false,
      string.format('baud=%s bits=%s par=%s inv=%s', tostring(sdec.force_baud),
                    tostring(sdec.force_nbits), tostring(sdec.force_par),
                    tostring(sdec.force_invert)))
check('lock detected re-seeds the form so the values can be seen before applying',
      display.getvalue(sdec.opt_baud) == dbaud
      and display.getvalue(sdec.opt_bits) == dbits - 2,
      string.format('baud field=%s bits field=%s',
                    tostring(display.getvalue(sdec.opt_baud)),
                    tostring(display.getvalue(sdec.opt_bits))))
-- It must NOT capture on its own: the point is to review the values, then press Apply.
local rd0 = READS.n
sdec.options_lock()
check('lock detected does not re-capture behind the operator', READS.n == rd0,
      string.format('%d reads', READS.n - rd0))
check('locking the SNAPPED rate, not the measured one', sdec.force_baud == 9600,
      tostring(sdec.force_baud))
sdec.options_apply()
check('the locked settings then decode the same bytes',
      sdec.res ~= nil and sdec.res.nf == ulgn and sdec.res.nbad == 0,
      sdec.res and string.format('%d bytes %d err', sdec.res.nf, sdec.res.nbad) or 'nil')
clearforce()
sdec.res = nil
sdec.baud = nil
check('lock detected with nothing captured refuses and says why',
      sdec.options_lock() == false and has(sdec.lasterr, 'capture first'),
      tostring(sdec.lasterr))
sdec.capture()

-- ============================================================================
print('\nthe 250 kBd ceiling and undersampling (real code)')
-- ============================================================================
-- 4 samples/bit is the wall, and at 1 MS/s that is exactly 250 kBd. Past it the
-- decoder must REFUSE rather than return plausible-looking bytes: a 921600 baud line
-- captured at 1 MS/s used to come back as four clean bytes labelled 230400 baud.
clearforce()
check('the ceiling is declared, not emergent',
      sdec.maxbaud == 250000 and sdec.minsabit == 4,
      string.format('%s baud, %s sa/bit', tostring(sdec.maxbaud), tostring(sdec.minsabit)))
r = run({bytes = hb, baud = 250000, fs = 1000000})
check('250 kBd at 1 MS/s decodes exactly -- the ceiling is usable, not just survivable',
      r ~= nil and r.nf == hn and txt(r) == HELLO and r.nbad == 0,
      r and string.format('%d bytes, %d err, %q', r.nf, r.nbad, txt(r)) or 'nil')
check('and 4.0 samples/bit is reported as marginal',
      (function() local _, w = sdec.sig_quality(); return w ~= nil end)(),
      tostring(select(2, sdec.sig_quality())))
local okc, whyc
r, _, _, okc, whyc = run({bytes = hb, baud = 921600, fs = 1000000})
check('921600 at 1 MS/s is refused, not decoded into something plausible',
      okc == false and r == nil, string.format('ok=%s why=%s', tostring(okc), tostring(whyc)))
check('and the refusal says the line is too fast, not that the probe is bad',
      has(whyc, 'ceiling'), tostring(whyc))
r, _, _, okc, whyc = run({bytes = hb, baud = 400000, fs = 1000000})
check('400 kBd is refused too, though a clean capture would decode it',
      okc == false, string.format('ok=%s why=%s', tostring(okc), tostring(whyc)))

-- ============================================================================
print('\nwire-quality reporting (real code)')
-- ============================================================================
-- A drifting baseline is DECODED rather than refused, because the bit time survives it
-- -- so the panel has to say the wire is bad, or a good-looking dump reads as a clean
-- measurement.
GEN_RESEED(4242)
local drd, dts, dnc, dnsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
GEN_DRIFT(drd, dnsmp, 1.0, 1.5)
local dok = analyse(drd, dnsmp, 100000)
check('1 V of drift on a 3.3 V swing is still accepted', dok,
      string.format('modal=%.2f', sdec.modal or -1))
sdec.decode_from(drd, dnsmp)
check('but it is reported as an unstable baseline',
      sdec.sig_levelwarn() ~= nil and has(sdec.ui_note_text(), 'baseline unstable'),
      tostring(sdec.ui_note_text()))

-- Broadband noise with no signal in it has no separable pair of levels, so there is
-- nothing to place a threshold between. It used to come back as 42 bytes at 14400 baud.
local nrd = {}
local nseed = 12345
for i = 1, 4000 do
  nseed = math.fmod(nseed * 16807, 2147483647)
  nrd[i] = 5 * (nseed / 2147483647)
end
local nok, nwhy = analyse(nrd, 4000, 100000)
check('broadband noise with no signal is refused', not nok, tostring(nwhy))
check('and the refusal gives a reason', nwhy ~= nil and string.len(nwhy) > 8,
      tostring(nwhy))

-- A decode that dies AFTER measuring a bit time must retract it: a rate shown against
-- "-- bytes" reads as a measurement when nothing was decoded.
GEN_RESEED(4242)
local hrd, hts, hnc, hnsmp = GEN({bytes = hb, baud = 9600, fs = 100000, noise = 4.0})
analyse(hrd, hnsmp, 100000)
local hok = sdec.decode_from(hrd, hnsmp)
check('noise past the swing yields no bytes', hok == false and sdec.res == nil)
check('and no baud rate is left on the panel to look measured',
      sdec.baud == nil and sdec.bittime == nil,
      string.format('baud=%s bittime=%s', tostring(sdec.baud), tostring(sdec.bittime)))
check('the header shows dashes rather than a number',
      sdec.ui_field_values()[1] == '--', tostring(sdec.ui_field_values()[1]))

-- The FIT column must describe the bit time actually CHOSEN. sig_bittime leaves fitq
-- describing its own proposal, so whenever ua_best overrode that proposal the panel
-- reported the quality of a rejected candidate.
GEN_RESEED(20250812)
local srd, sts, snc, snsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
GEN_SPIKES(srd, snsmp, 40, 25, 2)
analyse(srd, snsmp, 100000)
local Tprop = sdec.sig_bittime()
local qprop = sdec.fitq
sdec.decode_from(srd, snsmp)
check('forty spikes no longer capture the bit time', sdec.baud == 9600,
      tostring(sdec.baud))
check('the bit time chosen is not the one the width fit proposed',
      math.abs(sdec.bittime - Tprop) > 1,
      string.format('chose %.2f, fit proposed %.2f', sdec.bittime, Tprop))
check('and FIT describes the bit time CHOSEN, not the rejected proposal',
      math.abs(sdec.fitq - qprop) > 0.05,
      string.format('fitq now %.3f, proposal scored %.3f', sdec.fitq, qprop))
clearforce()

-- ============================================================================
print('\nfailure handling and teardown (real code)')
-- ============================================================================
-- A quiet pin is the most likely thing on a fresh launch. It must leave a usable
-- screen saying so, not a torn-down app.
local qrd2, qts2 = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 25000,
                        tail = 0, n = 25000})
SRC.rd, SRC.ts = qrd2, qts2
sdec.trigmode = 'free'
sdec.capture()
check('a quiet line leaves the UI alive', MD.live() > 0 and sdec.ui_scr ~= nil)
check('a quiet line says so on the note line',
      MD.text(sdec.ui_note) ~= nil and string.len(MD.text(sdec.ui_note)) > 0,
      tostring(MD.text(sdec.ui_note)))
check('a quiet line is counted as an error, not hidden', sdec.errcount > 0,
      'errcount=' .. tostring(sdec.errcount))

-- A capture that RAISES must still be contained.
SRC.rd, SRC.ts = urd, uts
local realread = dmm.digitize.read
dmm.digitize.read = function() error('digitizer gone', 0) end
sdec.capture()
dmm.digitize.read = realread
check('a raising capture is caught and reported', has(sdec.lasterr, 'digitizer gone')
      or sdec.lasterr ~= nil, tostring(sdec.lasterr))
check('the app is still alive after a raising capture', MD.live() > 0)
check('busy is released after a failure so Capture still works', sdec.busy == false)
sdec.capture()
check('a later capture recovers', sdec.res ~= nil and sdec.res.nf == ulgn,
      sdec.res and tostring(sdec.res.nf) or 'nil')

-- A forced baud rate must still RE-READ the wire. The rate-reuse guard used to
-- test a leftover result rather than whether this call had captured, so forcing a
-- baud rate did no digitizer reads at all and reported the previous bytes as fresh.
SRC.rd, SRC.ts = urd, uts
sdec.force_baud = 9600
sdec.trigmode = 'free'
local zb = GEN_BYTES('ZZZZZZZZZZZZZZZZ')
local zrd, zts = GEN({bytes = zb, baud = 9600, fs = 100000, lead = 20, n = 50000})
SRC.rd, SRC.ts = zrd, zts
local reads0 = READS.n
sdec.capture()
check('a forced baud rate still reads the wire', READS.n > reads0,
      string.format('%d digitizer reads', READS.n - reads0))
check('a forced baud rate shows the NEW bytes, not the previous capture',
      sdec.res ~= nil and sdec.res.vals[1] == string.byte('Z'),
      sdec.res and string.format('first byte %q', string.char(sdec.res.vals[1] or 63)) or 'nil')
clearforce()
SRC.rd, SRC.ts = urd, uts
sdec.capture()

-- Teardown must leave nothing behind.
sdec.stop()
check('stop() deletes every display object', MD.live() == 0, 'live=' .. MD.live())
-- The census above passes whether or not the app deleted children itself, because
-- deleting a screen cascades. Three objects (Apply, Cancel and the NOTE label) once
-- relied on that and 226 tests could not see it, so assert it directly.
check('NOTHING relied on the parent cascade to be freed',
      (select(1, MD.cascaded())) == 0,
      select(1, MD.cascaded()) .. ' cascaded: ' .. select(2, MD.cascaded()))
check('stop() frees every buffer it made', LIVEBUFS() == base_bufs,
      'buffers=' .. LIVEBUFS() .. ' vs baseline ' .. base_bufs)
check('stop() nils every handle',
      sdec.ui_scr == nil and sdec.ui_row == nil and sdec.ui_fval == nil
      and sdec.ui_flab == nil
      and sdec.optscr == nil and sdec.opt_baud == nil and sdec.buf == nil
      and sdec.smp == nil and sdec.ui_btn == nil)
check('stop() closes the log', ulog.on == false)
check('stop() twice is harmless', pcall(function() sdec.stop() end))
check('cleanup() with nothing built is harmless', pcall(function() sdec.cleanup() end))

-- ---------------------------------------------------------------------------
-- The one-build-per-power-cycle guard.
--
-- A second ui_build() crashes the firmware, and there is NO remote way to bring
-- the instrument back: the POWER switch is a soft button ("press" to turn on,
-- "press and hold" to turn off), so a mains interruption most likely leaves it in
-- standby, and the LXI virtual front panel states outright that it "cannot switch
-- the instrument on or off". With the bench 300 km away that turns a crash from a
-- 45-second power cycle into the end of a session, which is why start() refuses
-- rather than trusting the operator to remember.
--
-- Tested BEFORE allow_rebuild is set for the rest of this file, since the whole
-- point is the default behaviour.
-- ---------------------------------------------------------------------------
do
  sdec.built, sdec.allow_rebuild, sdec.lasterr = nil, nil, nil
  local ok1 = sdec.start()
  local ok2, why2 = sdec.start()
  check('start() succeeds once', ok1 == true)
  -- RESTARTING IS SAFE, so a second start() SUCCEEDS: it tears the old UI down first, and what
  -- makes a rebuild safe is the teardown rather than a power cycle. Creating over a live handle is
  -- the hazard, and after cleanup() there are no live handles left to create over.
  check('a second start() SUCCEEDS -- restarting must never need a power cycle',
        ok2 == true, tostring(why2))
  check('and it says so in the log rather than silently rebuilding',
        sdec.lasterr == nil, tostring(sdec.lasterr))
  sdec.stop()
  local ok3 = sdec.start()
  check('and again after an explicit stop()', ok3 == true)
  -- THE ONE CASE THAT STILL REFUSES: a teardown that could not delete everything AND could not
  -- reclaim it either. del_obj now KEEPS a handle it failed to delete, so start() retries it before
  -- counting -- a refused deletion that then succeeds is not a leak and must not refuse a rebuild.
  -- Only a handle that stays undeletable is the real risk.
  sdec.stop()
  local savedel, saveorph = sdec.delfails, sdec.orphans
  sdec.delfails, sdec.orphans = 2, nil
  local ok3a, why3a = sdec.start()
  check('a delete failure that RECLAIMS on retry does not refuse the rebuild',
        ok3a == true, tostring(why3a))
  -- An orphan that will not go: a table display.delete refuses forever.
  sdec.stop()
  sdec.delfails, sdec.orphans = 2, {'not-a-handle'}
  local ok3b, why3b = sdec.start()
  check('a rebuild IS refused when a handle cannot be reclaimed', ok3b == false,
        tostring(why3b))
  check('and the refusal names the leak and the remedy',
        has(why3b, 'undeleted') and has(why3b, 'Power cycle'), tostring(why3b))
  check('and the unreclaimable handle is KEPT, so a later retry is still possible',
        sdec.orphans ~= nil and table.getn(sdec.orphans) > 0,
        tostring(sdec.orphans and table.getn(sdec.orphans)))
  sdec.delfails, sdec.orphans = savedel, saveorph
  -- A failed build must count as a build: a half-built UI is the dangerous state.
  check('the flag is set before ui_build(), so a failed attempt still counts',
        sdec.built == true)
  sdec.allow_rebuild = true
  local ok4 = sdec.start()
  check('allow_rebuild = true overrides it, so the cycle test remains possible',
        ok4 == true)
  sdec.stop()
end
-- The mock has no firmware to crash, so the rest of this file rebuilds freely.
sdec.allow_rebuild = true

-- End App from the OPTIONS screen must tear down just as completely.
sdec.start()
sdec.options()
local ev = MD.events(sdec.optscr)
if ev ~= nil and ev['endapp'] ~= nil then (load or loadstring)(ev['endapp'])() end
check('End App from the options screen frees every object', MD.live() == 0,
      'live=' .. MD.live())
check('End App from the options screen frees every buffer', LIVEBUFS() == base_bufs,
      'buffers=' .. LIVEBUFS())

-- The deployed launch path: opening the App re-runs the whole script body first.
-- If the handle declarations reset the fields, the previous launch's objects become
-- unreachable and survive until a power cycle.
sdec.start()
local live2, bufs2 = MD.live(), LIVEBUFS()
-- SETTINGS, not just handles. The reload test only ever checked display objects and
-- buffers, which is why `range` and `trigmode` being assigned unconditionally at file
-- scope survived: an App relaunch silently reverted the range to 10 V and the trigger
-- to 'edge', and the next capture then reported "swing too small" on a line that had
-- been decoding a minute earlier.
sdec.trigmode, sdec.proto = 'free', 'midi'
sdec.force_baud, sdec.force_nbits, sdec.force_par = 31250, 8, sdec.PAR_NONE
sdec.force_invert, sdec.force_nstop = false, 1
sdec.ui_mode, sdec.alt_minframes = 'hex', 11
ulog.enabled, ulog.maxlines, ulog.path = true, 1234, '/usb1/keepme.txt'
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
                    'tsp/midi_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  loadfile(m)()
end
check('a script reload keeps the live handles reachable',
      sdec.ui_scr ~= nil and sdec.ui_row ~= nil and sdec.buf ~= nil)
check('a script reload preserves the acquisition settings',
      sdec.trigmode == 'free' and sdec.range == 10,
      string.format('range=%s trig=%s', tostring(sdec.range), tostring(sdec.trigmode)))
check('a script reload preserves the forced wire format',
      sdec.force_baud == 31250 and sdec.force_nbits == 8
      and sdec.force_par == sdec.PAR_NONE and sdec.force_invert == false
      and sdec.force_nstop == 1,
      string.format('baud=%s bits=%s par=%s inv=%s',
                    tostring(sdec.force_baud), tostring(sdec.force_nbits),
                    tostring(sdec.force_par), tostring(sdec.force_invert)))
check('a script reload preserves the protocol and the view',
      sdec.proto == 'midi' and sdec.ui_mode == 'hex',
      string.format('proto=%s mode=%s', tostring(sdec.proto), tostring(sdec.ui_mode)))
check('a script reload preserves tunables set from the form',
      sdec.alt_minframes == 11 and ulog.maxlines == 1234
      and has(ulog.path, 'keepme.txt'),
      string.format('alt=%s max=%s path=%s', tostring(sdec.alt_minframes),
                    tostring(ulog.maxlines), tostring(ulog.path)))
sdec.trigmode, sdec.proto = 'free', 'uart'
sdec.ui_mode, sdec.alt_minframes = 'text', 8
ulog.maxlines, ulog.path = 20000, '/usb1/t.txt'
clearforce()
sdec.start()
check('relaunching leaks NO display objects', MD.live() == live2,
      'live=' .. MD.live() .. ' vs ' .. live2)
check('relaunching leaks NO buffers', LIVEBUFS() == bufs2,
      'buffers=' .. LIVEBUFS() .. ' vs ' .. bufs2)
check('no deletion was ever refused across the whole run', sdec.delfails == 0,
      'delfails=' .. tostring(sdec.delfails))
sdec.stop()


-- ============================================================================
print('\nMIDI message layer (real code)')
-- ============================================================================
-- Parsing runs on the decoded BYTE STREAM, so these tests inject bytes directly
-- rather than going through a waveform -- the wire layer is already covered above
-- and MIDI adds nothing to it but a fixed 31250 baud 8N1.
local function midi(bytes)
  local n = table.getn(bytes)
  sdec.res = {nf = n, ngood = n, nbad = 0, nfalse = 0, vals = bytes, errs = {},
              tpos = {}, framebits = 10, nbits = 8, par = 0, nstop = 1,
              invert = false, score = n}
  local ok, why = sdec.mi_parse()
  return sdec.midi, ok, why
end
local function has_msg(m, sub)
  local i
  for i = 1, m.n do if has(m.msg[i], sub) then return true end end
  return false
end

check('note 69 is A4, so A440 numbering is right', sdec.mi_note_name(69) == 'A4',
      sdec.mi_note_name(69))
check('note 60 is middle C', sdec.mi_note_name(60) == 'C4', sdec.mi_note_name(60))
check('note 0 is C-1', sdec.mi_note_name(0) == 'C-1', sdec.mi_note_name(0))
check('note 61 is C#4', sdec.mi_note_name(61) == 'C#4', sdec.mi_note_name(61))

local m = midi({0x90, 0x3C, 0x64, 0x80, 0x3C, 0x40})
check('note on and note off decode', m.n == 2
      and has(m.msg[1], 'ch1') and has(m.msg[1], 'Note On') and has(m.msg[1], 'C4')
      and has(m.msg[1], 'vel 100') and has(m.msg[2], 'Note Off'),
      m.msg[1] .. ' | ' .. tostring(m.msg[2]))

m = midi({0x90, 0x3C, 0x00})
check('note on with velocity 0 is flagged as a note off',
      has(m.msg[1], '= Note Off'), m.msg[1])

-- RUNNING STATUS: the status byte appears once and the following data pairs
-- continue it. A parser that demands a status byte drops three of these four.
m = midi({0x92, 0x3C, 0x40, 0x3E, 0x41, 0x40, 0x42, 0x43, 0x44})
check('running status yields four notes from one status byte', m.n == 4,
      'n=' .. tostring(m.n))
check('running status keeps the channel', has(m.msg[4], 'ch3'), tostring(m.msg[4]))
check('running status keeps the note names',
      has(m.msg[1], 'C4') and has(m.msg[3], 'E4') and has(m.msg[4], 'G4'),
      tostring(m.msg[1]) .. ' .. ' .. tostring(m.msg[4]))

-- REAL-TIME INTERLEAVING: a clock byte between the two data bytes of a note must
-- be emitted without corrupting the note.
m = midi({0x90, 0x3C, 0xF8, 0x64})
check('a clock byte between data bytes does not corrupt the note', m.n == 2
      and has_msg(m, 'Clock') and has_msg(m, 'Note On'),
      table.concat(m.msg, ' | ', 1, m.n))
check('the interleaved note keeps its velocity', has_msg(m, 'vel 100'),
      table.concat(m.msg, ' | ', 1, m.n))

-- Real-time must NOT clear running status.
m = midi({0x90, 0x3C, 0x40, 0xFE, 0x3E, 0x41})
check('real-time does not clear running status', m.n == 3
      and has_msg(m, 'Active Sensing') and has(m.msg[3], 'D4'),
      table.concat(m.msg, ' | ', 1, m.n))

-- System Common DOES clear running status, so the trailing pair is orphaned.
m = midi({0x90, 0x3C, 0x40, 0xF3, 0x02, 0x3E, 0x41})
check('system common clears running status', has_msg(m, 'Song Select')
      and has_msg(m, 'orphan'), table.concat(m.msg, ' | ', 1, m.n))

m = midi({0xB0, 0x07, 0x60})
check('a named controller prints its name', has(m.msg[1], 'Volume')
      and has(m.msg[1], '= 96'), m.msg[1])
m = midi({0xB0, 0x33, 0x10})
check('an unnamed controller prints its number', has(m.msg[1], 'CC 51'), m.msg[1])

m = midi({0xE0, 0x00, 0x40})
check('centred pitch bend reads zero', has(m.msg[1], '+0'), m.msg[1])
m = midi({0xE0, 0x00, 0x60})
check('pitch bend is 14-bit LSB-first and signed about 8192',
      has(m.msg[1], '+4096'), m.msg[1])

m = midi({0xC2, 0x04})
check('program change is 1-based for the musician',
      has(m.msg[1], 'ch3') and has(m.msg[1], 'Program    5'), m.msg[1])

-- SysEx, including a real-time byte inside the block.
m = midi({0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF8, 0xF7})
check('sysex decodes and names the universal ID', has_msg(m, 'SysEx')
      and has_msg(m, 'Universal Non-Real Time'), table.concat(m.msg, ' | ', 1, m.n))
check('a real-time byte inside sysex is emitted separately', has_msg(m, 'Clock'),
      table.concat(m.msg, ' | ', 1, m.n))
m = midi({0xF0, 0x43, 0x10, 0x4C, 0xF7})
check('sysex names a manufacturer', has_msg(m, 'Yamaha'), m.msg[1])
m = midi({0xF0, 0x41, 0x01, 0x02})
check('an unterminated sysex is reported, not silently dropped',
      has_msg(m, 'unterminated'), table.concat(m.msg, ' | ', 1, m.n))
m = midi({0xF0, 0x41, 0x01, 0x90, 0x3C, 0x40})
check('a status byte inside sysex reports truncation and resumes',
      has_msg(m, 'truncated') and has_msg(m, 'Note On'),
      table.concat(m.msg, ' | ', 1, m.n))
m = midi({0xF7})
check('a stray sysex end is reported', has_msg(m, 'stray'), m.msg[1])

m = midi({0x3C, 0x40})
check('data bytes with no status at all are reported as orphans',
      m.bad == 2, 'bad=' .. tostring(m.bad))

-- A framing error in the byte stream must surface in the message list.
sdec.res = {nf = 3, ngood = 2, nbad = 1, nfalse = 0,
            vals = {0x90, 0x3C, 0x64}, errs = {nil, 'framing', nil},
            tpos = {}, framebits = 10}
sdec.mi_parse()
check('a framing error appears in the message list', sdec.midi.bad >= 1
      and has_msg(sdec.midi, 'framing error'),
      table.concat(sdec.midi.msg, ' | ', 1, sdec.midi.n))

m = midi({0xF8, 0xFA, 0x90, 0x3C, 0x40, 0xFC})
check('the summary counts real-time separately', has(sdec.mi_summary(), 'real-time')
      and has(sdec.mi_summary(), '4 messages'), sdec.mi_summary())
check('rows are counted for paging', sdec.mi_nrows() == 4, tostring(sdec.mi_nrows()))
check('a row past the end is empty', sdec.mi_line(99) == '')
sdec.midi = nil
check('the summary is safe with nothing parsed', sdec.mi_summary() ~= nil
      and sdec.mi_nrows() == 0)
-- A channel message left short by the end of the capture used to VANISH: SysEx
-- truncation was reported but a Note On missing its velocity byte simply was not in
-- the list, so the message count disagreed with the byte dump and nothing said why.
m = midi({0x90, 0x3C, 0x80, 0x3C, 0x40})
check('a truncated channel message is reported rather than dropped',
      has_msg(m, 'truncated'), table.concat(m.msg, ' | ', 1, m.n))
m = midi({0xC0})
check('a status byte with no data at all is reported',
      has_msg(m, 'truncated'), table.concat(m.msg, ' | ', 1, m.n))
m = midi({0x90, 0x3C, 0x40})
check('a COMPLETE message is not falsely reported as truncated',
      not has_msg(m, 'truncated'), table.concat(m.msg, ' | ', 1, m.n))

sdec.res = nil
check('parsing with no bytes fails cleanly',
      (function() local ok = sdec.mi_parse(); return ok == false end)())

-- ============================================================================
print('\nMIDI end to end: waveform -> UART bytes -> messages (real code)')
-- ============================================================================
-- Every test above hand-builds sdec.res, so mi_parse() had never once run on output
-- the real decoder produced -- which is exactly where a field-convention mismatch
-- (errs[] holding false rather than nil, vals[] 1-based or 0-based) would hide.
-- This drives the whole app: 31250 baud on the wire, through acquire and decode, to
-- the panel rows.
local MIDIBYTES = {0xF8,                     -- clock, before anything
                   0x90, 0x3C, 0x64,         -- note on  C4 vel 100
                   0x3E, 0x60,               -- running status: D4 vel 96
                   0xB0, 0x07, 0x50,         -- CC7 volume 80
                   0x80, 0x3C, 0x40}         -- note off C4
local mrd, mts, mnc, mnsmp = GEN({bytes = MIDIBYTES, baud = 31250, fs = 500000,
                                  lead = 20, gap = 2, tail = 20, noise = 0.03})
SRC.rd, SRC.ts, SRC.trigat = mrd, mts, nil
sdec.start()
sdec.trigmode = 'free'
sdec.options()
display.setvalue(sdec.opt_proto, 2)          -- MIDI
sdec.options_apply()

check('choosing MIDI forces the specified wire parameters',
      sdec.force_baud == 31250 and sdec.force_nbits == 8
      and sdec.force_par == sdec.PAR_NONE,
      string.format('baud=%s bits=%s par=%s', tostring(sdec.force_baud),
                    tostring(sdec.force_nbits), tostring(sdec.force_par)))
check('choosing MIDI switches to the message view', sdec.ui_mode == 'midi',
      tostring(sdec.ui_mode))
check('the real decoder recovers every MIDI byte',
      sdec.res ~= nil and sdec.res.nf == table.getn(MIDIBYTES) and sdec.res.nbad == 0,
      sdec.res and string.format('%d bytes, %d err', sdec.res.nf, sdec.res.nbad) or 'nil')
check('those bytes are the ones transmitted',
      (function()
         if sdec.res == nil then return false end
         local i
         for i = 1, table.getn(MIDIBYTES) do
           if sdec.res.vals[i] ~= MIDIBYTES[i] then return false end
         end
         return true end)(),
      sdec.res and sdec.ua_hex_line(1, 16) or 'nil')
check('capture() parsed the messages without being asked twice',
      sdec.midi ~= nil and sdec.midi.n == 5,
      sdec.midi and (sdec.midi.n .. ' messages') or 'nil')
check('running status survived the round trip through the real decoder',
      sdec.midi ~= nil and has_msg(sdec.midi, 'D4'),
      sdec.midi and table.concat(sdec.midi.msg, ' | ', 1, sdec.midi.n) or 'nil')
check('no message came out as an error', sdec.midi ~= nil and sdec.midi.bad == 0,
      sdec.midi and ('bad=' .. sdec.midi.bad) or 'nil')
check('the messages reach the panel rows',
      has(MD.text(sdec.ui_row[1]), 'Clock') and has(MD.text(sdec.ui_row[2]), 'Note On'),
      tostring(MD.text(sdec.ui_row[1])) .. ' / ' .. tostring(MD.text(sdec.ui_row[2])))
check('the status row names the protocol as well as the view',
      has(MD.text(sdec.ui_page_t), 'MIDI') and has(MD.text(sdec.ui_page_t), 'msg 1-'),
      tostring(MD.text(sdec.ui_page_t)))
-- A saved capture in MIDI mode must carry the messages, not just the bytes.
MD.usb(true)
MD.forget_files()
sdec.savepfx = '/usb1/midi_'
check('the saved file includes the parsed messages', sdec.save() == true
      and has(MD.logtext(), 'MIDI messages') and has(MD.logtext(), 'Note On'),
      tostring(sdec.lasterr))
sdec.savepfx = '/usb1/serial_'

-- Leaving MIDI must hand the wire back to the auto-detector: the form still SHOWS
-- 31250 / 8 / None, so reading the fields back would keep them forced.
SRC.rd, SRC.ts = urd, uts
sdec.options()
display.setvalue(sdec.opt_proto, 1)          -- back to UART
sdec.options_apply()
check('leaving MIDI clears the forced wire parameters',
      sdec.force_baud == nil and sdec.force_nbits == nil and sdec.force_par == nil,
      string.format('baud=%s bits=%s par=%s', tostring(sdec.force_baud),
                    tostring(sdec.force_nbits), tostring(sdec.force_par)))
check('leaving MIDI leaves the message view', sdec.ui_mode ~= 'midi',
      tostring(sdec.ui_mode))
check('and the auto-detector works again straight away',
      sdec.res ~= nil and sdec.baud == 9600, tostring(sdec.baud))
sdec.stop()

do    -- scoped: the main chunk is near Lua's 200-active-local limit
-- ============================================================================
print('\nLIN protected identifier and checksum (real code)')
-- ============================================================================
-- Pinned to the PIDs that are common knowledge rather than to this module's own output:
-- ID 0x3C is the master request header and ID 0x3D the slave response, and every LIN
-- trace in existence shows them as 0x3C and 0x7D. If the two parity formulas were
-- swapped or a bit index were off, at least one of these four would move.
check('PID for ID 0x00 is 0x80', sdec.li_pid(0x00) == 0x80,
      string.format('%02X', sdec.li_pid(0x00)))
check('PID for ID 0x01 is 0xC1', sdec.li_pid(0x01) == 0xC1,
      string.format('%02X', sdec.li_pid(0x01)))
check('PID for ID 0x3C (master request) is 0x3C', sdec.li_pid(0x3C) == 0x3C,
      string.format('%02X', sdec.li_pid(0x3C)))
check('PID for ID 0x3D (slave response) is 0x7D', sdec.li_pid(0x3D) == 0x7D,
      string.format('%02X', sdec.li_pid(0x3D)))
check('the generator computes PIDs independently and agrees',
      (function()
         local id
         for id = 0, 63 do
           if LIN_PID(id) ~= sdec.li_pid(id) then return false end
         end
         return true end)())
check('li_pid_ok accepts a valid PID and recovers the ID',
      (function() local ok, id = sdec.li_pid_ok(0x7D); return ok and id == 0x3D end)())
check('li_pid_ok rejects a PID with a flipped parity bit',
      not (sdec.li_pid_ok(0x3D)), '0x3D would be ID 0x3D with wrong parity')
check('li_pid_ok is safe on nil', not (sdec.li_pid_ok(nil)))
check('every ID has exactly one valid PID, so parity really is a check',
      (function()
         local n, v = 0, nil
         for v = 0, 255 do if sdec.li_pid_ok(v) then n = n + 1 end end
         return n == 64 end)())

-- Checksum, on cases small enough to check by hand.
check('classic checksum of a single 0x00 is 0xFF',
      sdec.li_csum({0x00}, 1, 1, nil) == 0xFF,
      string.format('%02X', sdec.li_csum({0x00}, 1, 1, nil)))
check('the carry really is added back, not dropped',
      sdec.li_csum({0x80, 0x80}, 1, 2, nil) == 0xFE,   -- 256 -> 1, inverted 0xFE
      string.format('%02X', sdec.li_csum({0x80, 0x80}, 1, 2, nil)))
check('enhanced includes the PID and classic does not',
      sdec.li_csum({0x01}, 1, 1, 0x80) ~= sdec.li_csum({0x01}, 1, 1, nil))
check('enhanced over PID 0x00 equals classic (nothing to add)',
      sdec.li_csum({0x12, 0x34}, 1, 2, 0) == sdec.li_csum({0x12, 0x34}, 1, 2, nil))
-- The receiver-side property, which is the reason this arithmetic is specified the way
-- it is: sum the data AND the received checksum the same way and you get 255.
check('data plus its own checksum sums to 255',
      (function()
         local d = {0x2B, 0xFF, 0x01, 0x7E, 0x80}
         local cs = sdec.li_csum(d, 1, 5, 0x4A)
         local t = {0x2B, 0xFF, 0x01, 0x7E, 0x80, cs}
         local sum = 0x4A
         local i
         for i = 1, 6 do
           sum = sum + t[i]
           if sum > 255 then sum = sum - 255 end
         end
         return sum == 255 end)())
check('a nil byte in the range gives nil rather than a wrong checksum',
      sdec.li_csum({0x01, nil, 0x03}, 1, 3, nil) == nil)

-- ============================================================================
print('\nLIN frame layer on a hand-built byte stream (real code)')
-- ============================================================================
-- The frame layer's own logic, driven directly, so a failure here is not confounded by
-- the wire layer. The waveform round trip is the section after this one.
--
-- tpos and sdec.bittime matter: a break is identified partly by TIMING -- a dominant
-- period longer than a whole frame -- so the helper lays the bytes out on a real grid,
-- 10 bit times apart for an ordinary byte and 14 for a break (13 dominant + 1 delimiter).
local LT = 10                          -- samples per bit, for the synthetic timing
local function linres(vals, brk)
  local n = table.getn(vals)
  local errs, tpos, isbrk = {}, {}, {}
  local i
  for i = 1, table.getn(brk or {}) do isbrk[brk[i]] = true end
  local t, ngood, nbad = 100, 0, 0
  for i = 1, n do
    tpos[i] = t
    if isbrk[i] then
      errs[i] = 'framing'
      nbad = nbad + 1
      t = t + 14 * LT
    else
      ngood = ngood + 1
      t = t + 10 * LT
    end
  end
  sdec.bittime = LT
  sdec.nread = t + 20 * LT
  sdec.res = {nf = n, ngood = ngood, nbad = nbad, nfalse = 0, vals = vals, errs = errs,
              tpos = tpos, framebits = 10, nbits = 8, par = 0, nstop = 1,
              invert = false, score = ngood - 3 * nbad}
  local ok, why = sdec.li_parse()
  return sdec.lin, ok, why
end
local function has_frame(L, sub)
  local i
  for i = 1, L.n do if has(L.msg[i], sub) then return true end end
  return false
end

-- A textbook LIN 2.x frame: break, sync, PID for ID 0x11, four data bytes, enhanced
-- checksum.
local D4 = {0xA1, 0xB2, 0xC3, 0xD4}
local P11 = LIN_PID(0x11)
local L = linres({0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4,
                  LIN_CSUM(D4, 4, P11)}, {1})
check('one LIN frame is one row', L.n == 1 and L.nframes == 1,
      L.n .. ' rows, ' .. L.nframes .. ' frames')
check('the frame names its ID and data length',
      has(L.msg[1], 'ID 11') and has(L.msg[1], '4 data'), L.msg[1])
check('the data bytes are shown in order',
      has(L.msg[1], 'A1 B2 C3 D4'), L.msg[1])
check('an enhanced checksum validates and is named as enhanced',
      has(L.msg[1], 'ok enh') and L.bad == 0 and L.nenh == 1, L.msg[1])
check('a good frame is not coloured as an error', L.kind[1] == 'frame', L.kind[1])
check('the break is counted', L.nbreak == 1, tostring(L.nbreak))

-- The same data with the CLASSIC checksum: a LIN 1.x segment.
L = linres({0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4, LIN_CSUM(D4, 4, nil)}, {1})
check('a classic checksum validates and is named as classic',
      has(L.msg[1], 'ok cls') and L.bad == 0 and L.ncls == 1, L.msg[1])

-- Diagnostic frames are specified as CLASSIC whatever the rest of the bus does.
local P3C = LIN_PID(0x3C)
local D8 = {1, 2, 3, 4, 5, 6, 7, 8}
L = linres({0, 0x55, P3C, 1, 2, 3, 4, 5, 6, 7, 8, LIN_CSUM(D8, 8, nil)}, {1})
check('a diagnostic frame is named', has(L.msg[1], 'MasterReq'), L.msg[1])
check('and its classic checksum validates', has(L.msg[1], 'ok cls'), L.msg[1])
L = linres({0, 0x55, P3C, 1, 2, 3, 4, 5, 6, 7, 8, LIN_CSUM(D8, 8, P3C)}, {1})
check('an ENHANCED checksum on a diagnostic frame is flagged as a spec violation',
      has(L.msg[1], 'spec wants classic'), L.msg[1])

-- A genuinely mixed bus -- one NON-diagnostic frame validating as classic among
-- enhanced ones -- is worth reporting: either a half-migrated stack, or a corrupted
-- enhanced checksum that landed on the classic value, which happens once in 256 frames.
local P22 = LIN_PID(0x22)
L = linres({0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4, LIN_CSUM(D4, 4, P11),
            0, 0x55, P22, 0xA1, 0xB2, 0xC3, 0xD4, LIN_CSUM(D4, 4, nil)}, {1, 9})
check('a mixture among non-diagnostic frames IS reported as mixed',
      L.nenh == 1 and L.ncls == 1 and has(sdec.li_summary(), 'mixed'),
      sdec.li_summary())

-- A corrupt checksum must fail and show what both readings would have been, because
-- "which style is this bus using" and "this byte is wrong" look identical otherwise.
L = linres({0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4, 0x00}, {1})
check('a wrong checksum is reported as BAD', has(L.msg[1], 'BAD'), L.msg[1])
check('and both expected values are given',
      has(L.msg[1], 'enh') and has(L.msg[1], 'cls'), L.msg[1])
check('a bad checksum colours the row', L.kind[1] == 'err', L.kind[1])
check('and is counted', L.bad == 1, tostring(L.bad))

-- A PID whose parity is wrong: the frame is still shown, since its data is still data.
L = linres({0, 0x55, 0x12, 0xA1, LIN_CSUM({0xA1}, 1, 0x12)}, {1})
check('a PID with bad parity is reported', has(L.msg[1], 'parity BAD'), L.msg[1])
check('and the frame is still shown rather than dropped',
      has(L.msg[1], 'A1') and L.nframes == 1, L.msg[1])

-- The sync field is 0x55 by definition. Anything else is the loudest available signal
-- that the bit rate is wrong.
L = linres({0, 0x57, P11, 0xA1, 0x00}, {1})
check('a sync field that is not 0x55 is reported', has_frame(L, 'sync field is 57'),
      L.msg[1])
check('and the wrong bit rate is named as a likely cause',
      has_frame(L, 'wrong bit rate'), L.msg[1])
check('no frame is claimed from a bad header', L.nframes == 0, tostring(L.nframes))

-- A header the schedule reached with nothing answering. Legal, and the single most
-- useful thing a bench decoder can tell you about a LIN bus.
L = linres({0, 0x55, P11, 0, 0x55, P11, 0xA1, LIN_CSUM({0xA1}, 1, P11)}, {1, 4})
check('a header with no response is reported', has_frame(L, 'header only, no response'),
      L.msg[1])
check('a missing response is not an error, just an observation', L.kind[1] == 'note',
      L.kind[1])
check('the frame after it still decodes', L.nframes == 2 and has(L.msg[2], 'ID 11'),
      L.msg[2])

-- A capture that started mid-frame: the leading bytes belong to a frame whose header
-- was never seen, and saying so is the difference between "the bus is broken" and
-- "press Capture again".
L = linres({0x33, 0x44, 0, 0x55, P11, 0xA1, LIN_CSUM({0xA1}, 1, P11)}, {3})
check('bytes before the first break are reported once, not per byte',
      has(L.msg[1], '2 byte(s) before the first break'), L.msg[1])
check('and the note comes first, in capture order', L.kind[1] == 'note', L.kind[1])
check('the frame after them decodes', L.nframes == 1, tostring(L.nframes))

L = linres({0x41, 0x42, 0x43}, {})
check('a stream with no break at all says there is no LIN frame here',
      has_frame(L, 'no break field'), L.msg[1])
check('and claims no frames', L.nframes == 0, tostring(L.nframes))

-- More than 8 data bytes means a break was missed and two frames ran together. Naming
-- that is worth more than the checksum failure it causes.
local D10 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
L = linres({0, 0x55, P11, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
            LIN_CSUM(D10, 10, P11)}, {1})
check('a response longer than 8 data bytes is flagged',
      has(L.msg[1], 'over the 8-byte maximum'), L.msg[1])
check('and a missed break is named as the likely cause',
      has(L.msg[1], 'missed break'), L.msg[1])
check('the byte list is capped so the row stays on the panel',
      has(L.msg[1], '...') and string.len(L.msg[1]) < 120,
      string.len(L.msg[1]) .. ' chars')

L = linres({0, 0x55, P11, 0xFF}, {1})
check('a response of nothing but a checksum is flagged',
      has(L.msg[1], '0 data'), L.msg[1])

-- A damaged data byte changes what a checksum failure MEANS.
L = linres({0, 0x55, P11, 0xA1, 0xB2, 0x00}, {1})
sdec.res.errs[5] = 'framing'
sdec.li_parse()
L = sdec.lin
check('a damaged byte inside the response is counted and named',
      has(L.msg[1], 'damaged byte'), L.msg[1])

-- A DAMAGED BYTE IS NOT CLEARED BY THE CHECKSUM AGREEING, and the reason is arithmetic:
-- the LIN checksum is a modulo-255 sum, so 0xFF is congruent to 0x00 and swapping one for
-- the other is invisible in EVERY byte position -- a sweep of all 64 IDs x 4 positions
-- detects 0 of 256 such swaps. With PID 0x11, data 0xFF and data 0x00 both give checksum
-- 0xEE. So a frame whose data byte the UART layer flagged came back as `csum EE ok enh`,
-- kind 'frame', bad = 0, with data that was never transmitted.
check('the checksum cannot tell 0x00 from 0xFF, in any position',
      (function()
         local k, pos
         for k = 0, 63 do
           local pd = sdec.li_pid(k)
           for pos = 1, 4 do
             local a, b = {1, 2, 3, 4}, {1, 2, 3, 4}
             a[pos], b[pos] = 0x00, 0xFF
             if sdec.li_csum(a, 1, 4, pd) ~= sdec.li_csum(b, 1, 4, pd) then return false end
           end
         end
         return true end)(), 'modulo-255: 255 is congruent to 0')
L = linres({0, 0x55, P11, 0x00, sdec.li_csum({0xFF}, 1, 1, P11)}, {1})
sdec.res.errs[4] = 'framing'      -- the UART layer flagged the data byte
sdec.li_parse()
L = sdec.lin
check('a checksum that agrees does NOT clear a byte the UART layer flagged',
      L.kind[1] == 'err' and L.bad == 1, L.msg[1])
check('and the row says the match is not proof', has(L.msg[1], 'not proof'), L.msg[1])
check('an untrusted frame does not get to decide the bus checksum style',
      L.nenh == 0 and L.ncls == 0,
      string.format('enh=%d cls=%d', L.nenh, L.ncls))

-- A DAMAGED PID NAMES THE WRONG ID. 0x11 damaged into 0xE2 is a perfectly valid PID for
-- ID 0x22, so parity cannot catch it and the frame was reported as a clean "ID 22" with
-- nothing saying the byte had arrived broken. The sync field was already checked for a
-- UART error; the PID was not.
check('0xE2 is a valid PID, so parity alone cannot catch a damaged PID',
      sdec.li_pid(0x22) == 0xE2 and (sdec.li_pid_ok(0xE2)),
      string.format('%02X', sdec.li_pid(0x22)))
L = linres({0, 0x55, 0xE2, 0xA1, LIN_CSUM({0xA1}, 1, 0xE2)}, {1})
sdec.res.errs[3] = 'framing'      -- the PID byte itself arrived broken
sdec.li_parse()
L = sdec.lin
check('a damaged PID byte is reported even though its parity is valid',
      has(L.msg[1], 'PID byte damaged') and L.kind[1] == 'err', L.msg[1])
check('and the ID is still shown, as the best guess it is',
      has(L.msg[1], 'ID 22'), L.msg[1])

-- MISSING BYTES MUST NOT VALIDATE. In Lua `nil == nil` is TRUE, and both sides of the
-- checksum comparison can legitimately be nil: r.vals[] holds nil for a byte the capture
-- lost, and li_csum returns nil when any byte it must sum is missing. So a response with a
-- missing data byte AND a missing checksum byte came back as `csum -- ok enh`, kind
-- 'frame', not red, bad = 0 -- a frame confidently validated out of two absences.
L = linres({0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4, LIN_CSUM(D4, 4, P11)}, {1})
sdec.res.vals[5] = nil            -- a lost data byte
sdec.res.vals[8] = nil            -- and the lost checksum
sdec.li_parse()
L = sdec.lin
check('a response with missing bytes is NOT reported as checksum-valid',
      L.bad == 1 and L.kind[1] == 'err' and not has(L.msg[1], 'ok'), L.msg[1])
check('and it says the checksum could not be verified rather than that it is wrong',
      has(L.msg[1], 'missing') and has(L.msg[1], 'unverifiable'), L.msg[1])

-- nframes counted a header-only frame and nids did not, so the summary undercounted the
-- distinct IDs on the bus. Found by reading the generated mockup: "6 frames 4 ID(s)" over
-- five distinct IDs.
L = linres({0, 0x55, LIN_PID(0x2C),
            0, 0x55, P11, 0xA1, LIN_CSUM({0xA1}, 1, P11)}, {1, 4})
check('a header with no response still counts its ID',
      L.nframes == 2 and L.nids == 2,
      string.format('%d frames, %d IDs', L.nframes, L.nids))

-- The timing test is corroboration, so the value-and-error test alone must still work
-- when there is no timing at all -- a hand-built result, or a decode with no bit time.
sdec.res = {nf = 8, ngood = 7, nbad = 1,
            vals = {0, 0x55, P11, 0xA1, 0xB2, 0xC3, 0xD4, LIN_CSUM(D4, 4, P11)},
            errs = {'framing'}, tpos = {}, framebits = 10}
sdec.li_parse()
check('a break is still found when no timing is available',
      sdec.lin.nframes == 1 and sdec.lin.nbreak == 1,
      sdec.lin.nframes .. ' frames')

-- A 0x00 byte with a GOOD stop bit is data, not a break: after eight dominant data bits
-- a real 0x00's stop bit is recessive and passes. This is the whole reason the error
-- flag is part of the test.
L = linres({0, 0x55, P11, 0x00, 0x00, LIN_CSUM({0x00, 0x00}, 2, P11)}, {1})
check('a clean 0x00 data byte is not mistaken for a break',
      L.nbreak == 1 and L.nframes == 1 and has(L.msg[1], '2 data'), L.msg[1])

-- ...and a 0x00 whose stop bit was flipped by NOISE is not a break either, as long as it
-- is butted against the next byte: 10 bit times is not long enough to be a break. This
-- is the one case the value-and-error test cannot decide on its own, and the whole reason
-- the timing is consulted.
L = linres({0, 0x55, P11, 0x00, LIN_CSUM({0x00}, 1, P11)}, {1})
sdec.res.errs[4] = 'framing'         -- a noise-flipped stop bit, gap still 10 bit times
sdec.li_parse()
L = sdec.lin
check('a 0x00 with a flipped stop bit but only 10 bit times of gap is not a break',
      L.nbreak == 1 and L.nframes == 1, L.nbreak .. ' breaks, ' .. L.nframes .. ' frames')
check('it is reported as a damaged byte inside the response instead',
      has(L.msg[1], 'damaged byte'), L.msg[1])

sdec.res = nil
check('parsing with no bytes fails cleanly',
      (function() local ok = sdec.li_parse(); return ok == false end)())
check('the summary and row count are safe with nothing parsed',
      sdec.li_summary() ~= nil and sdec.li_nrows() == 0 and sdec.li_line(1) == '')

-- ============================================================================
print('\nLIN end to end: waveform -> UART bytes -> frames (real code)')
-- ============================================================================
-- The whole app on a synthesised bus: a 13-bit break no byte can express, at 19200 baud
-- on the 0/6 V levels a 12 V bus gives through the 2:1 divider the app asks for.
clearforce()
sdec.proto = 'uart'
local LINF = {
  {id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
  {id = 0x22, data = {0x01, 0x02}},
  {id = 0x3C, data = {1, 2, 3, 4, 5, 6, 7, 8}, classic = true},
  {id = 0x05, data = {0xFF}},
}
local lrd, lts, lnc, lnsmp, lbytes, lnby =
  GEN_LIN({frames = LINF, baud = 19200, fs = 200000, noise = 0.03})
SRC.rd, SRC.ts, SRC.trigat = lrd, lts, nil
sdec.fs, sdec.trigmode = 200000, 'free'
sdec.start()

check('the wire layer recovers every byte of the LIN capture, breaks included',
      sdec.res ~= nil and sdec.res.nf == lnby,
      sdec.res and (sdec.res.nf .. ' of ' .. lnby) or 'nil')
check('and they are the bytes transmitted',
      (function()
         if sdec.res == nil then return false end
         local i
         for i = 1, lnby do
           if sdec.res.vals[i] ~= lbytes[i] then
             return false, i
           end
         end
         return true end)(),
      sdec.res and sdec.ua_hex_line(1, 16) or 'nil')
check('the baud rate is recovered from a capture full of break fields',
      sdec.baud == 19200, tostring(sdec.baud))
check('the auto-detector still reads 8N1 despite one framing error per frame',
      sdec.res ~= nil and sdec.fmt_text() == '8N1', sdec.fmt_text())
check('the breaks are the only framing errors',
      sdec.res ~= nil and sdec.res.nbad == table.getn(LINF),
      sdec.res and (sdec.res.nbad .. ' err') or 'nil')

-- Now select LIN the way the operator would.
sdec.options()
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('lin'))
sdec.options_apply()
check('choosing LIN pins 8N1 and normal polarity',
      sdec.force_nbits == 8 and sdec.force_par == sdec.PAR_NONE
      and sdec.force_nstop == 1 and sdec.force_invert == false,
      string.format('bits=%s par=%s stop=%s inv=%s', tostring(sdec.force_nbits),
                    tostring(sdec.force_par), tostring(sdec.force_nstop),
                    tostring(sdec.force_invert)))
check('choosing LIN does NOT pin a baud rate -- LIN specifies a range, not a rate',
      sdec.force_baud == nil, tostring(sdec.force_baud))
check('and the rate is still found automatically', sdec.baud == 19200,
      tostring(sdec.baud))
check('choosing LIN switches to the frame view', sdec.ui_mode == 'lin',
      tostring(sdec.ui_mode))
check('capture() parsed the frames without being asked twice',
      sdec.lin ~= nil and sdec.lin.nframes == table.getn(LINF),
      sdec.lin and (sdec.lin.nframes .. ' frames') or 'nil')
check('every frame checksum validates',
      sdec.lin ~= nil and sdec.lin.bad == 0,
      sdec.lin and (sdec.lin.bad .. ' bad') or 'nil')
check('every break was found', sdec.lin ~= nil
      and sdec.lin.nbreak == table.getn(LINF),
      sdec.lin and tostring(sdec.lin.nbreak) or 'nil')
-- The style census EXCLUDES diagnostic frames, which are classic by specification
-- whatever version the bus is. Counting them made every ordinary LIN 2.x bus carrying a
-- 0x3C frame report "mixed csum" -- the one thing that summary exists to tell you.
check('a diagnostic frame is counted as diagnostic, not as a classic-checksum bus',
      sdec.lin ~= nil and sdec.lin.nenh == 3 and sdec.lin.ncls == 0
      and sdec.lin.ndiag == 1,
      sdec.lin and string.format('enh=%d cls=%d diag=%d', sdec.lin.nenh,
                                 sdec.lin.ncls, sdec.lin.ndiag) or 'nil')
check('so the bus reads as enhanced rather than mixed',
      has(sdec.li_summary(), 'enhanced') and not has(sdec.li_summary(), 'mixed'),
      sdec.li_summary())
check('the IDs are counted', has(sdec.li_summary(), '4 ID'), sdec.li_summary())
check('the frames reach the panel rows',
      has(MD.text(sdec.ui_row[1]), 'ID 11')
      and has(MD.text(sdec.ui_row[3]), 'MasterReq'),
      tostring(MD.text(sdec.ui_row[1])) .. ' / ' .. tostring(MD.text(sdec.ui_row[3])))
check('the status row names the protocol, the view and the unit',
      has(MD.text(sdec.ui_page_t), 'LIN') and has(MD.text(sdec.ui_page_t), 'frame 1-'),
      tostring(MD.text(sdec.ui_page_t)))

-- THE note that a LIN capture needs: every break is a framing error at the byte layer,
-- so the ERR field goes red on a perfectly healthy bus.
check('the note explains that the framing errors are break fields',
      has(sdec.ui_note_text(), 'break field')
      and has(sdec.ui_note_text(), 'normal'), sdec.ui_note_text())
check('and the stop-bit remark is suppressed now the format is forced',
      not has(MD.text(sdec.ui_note), 'stop-bit count'), tostring(MD.text(sdec.ui_note)))

-- The saved file must carry the frames, not just the bytes.
MD.usb(true)
MD.forget_files()
sdec.savepfx = '/usb1/lin_'
check('the saved file includes the parsed frames', sdec.save() == true
      and has(MD.logtext(), 'LIN frames') and has(MD.logtext(), 'ID 11'),
      tostring(sdec.lasterr))
sdec.savepfx = '/usb1/serial_'
MD.usb(false)

-- A longer break, inter-byte space, and 9600 baud: all legal, none of it may matter.
local l2rd, l2ts, _, _, l2b, l2n =
  GEN_LIN({frames = {{id = 0x11, data = {0xDE, 0xAD, 0xBE, 0xEF}},
                     {id = 0x22, data = {0x55, 0xAA}}},
           baud = 9600, fs = 100000, nbreak = 18, delim = 2, space = 2, noise = 0.03})
SRC.rd, SRC.ts = l2rd, l2ts
sdec.fs = 100000
sdec.capture()
check('an 18-bit break with inter-byte space still frames',
      sdec.lin ~= nil and sdec.lin.nframes == 2 and sdec.lin.bad == 0,
      sdec.lin and string.format('%d frames %d bad', sdec.lin.nframes, sdec.lin.bad)
        or 'nil')
check('at 9600 baud too', sdec.baud == 9600, tostring(sdec.baud))
check('and the data survives',
      sdec.lin ~= nil and has(sdec.lin.msg[1], 'DE AD BE EF'),
      sdec.lin and tostring(sdec.lin.msg[1]) or 'nil')

-- A header with no slave response, on the wire this time.
local l3rd, l3ts = GEN_LIN({frames = {{id = 0x11, nodata = true},
                                      {id = 0x22, data = {0x01, 0x02}}},
                            baud = 19200, fs = 200000, noise = 0.03})
SRC.rd, SRC.ts = l3rd, l3ts
sdec.fs = 200000
sdec.capture()
check('a header with no response is seen on a real waveform',
      sdec.lin ~= nil and has_frame(sdec.lin, 'header only, no response'),
      sdec.lin and table.concat(sdec.lin.msg, ' | ', 1, sdec.lin.n) or 'nil')

-- A corrupted data byte: the checksum is what catches it, which is the whole point of
-- having one, and the frame layer must say so rather than passing the bytes on.
local l4rd, l4ts = GEN_LIN({frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4},
                                       csum = 0x00}},
                            baud = 19200, fs = 200000, noise = 0.03})
SRC.rd, SRC.ts = l4rd, l4ts
sdec.capture()
check('a wrong checksum on the wire is caught',
      sdec.lin ~= nil and sdec.lin.bad == 1 and has_frame(sdec.lin, 'BAD'),
      sdec.lin and tostring(sdec.lin.msg[1]) or 'nil')

-- The divider hint. An undivided 12 V bus puts the recessive level at the top of the
-- 10 V range, and nothing else on the panel would say why nothing decodes.
local l5rd, l5ts = GEN_LIN({frames = {{id = 0x11, data = {0xA1, 0xB2}}},
                            baud = 19200, fs = 200000, lo = 0, hi = 12.0, noise = 0.03})
SRC.rd, SRC.ts = l5rd, l5ts
sdec.capture()
check('an undivided 12 V bus is told to use the divider',
      has(sdec.ui_note_text(), 'divide the bus'), sdec.ui_note_text())
check('and the note is not shown for a properly divided one',
      (function()
         sdec.lo, sdec.hi = 0, 6.0
         return sdec.li_levelnote() == nil end)())

-- Leaving LIN must hand the wire back, exactly as leaving MIDI does.
SRC.rd, SRC.ts = urd, uts
sdec.fs = 100000
sdec.options()
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('uart'))
sdec.options_apply()
check('leaving LIN clears the pinned format and polarity',
      sdec.force_nbits == nil and sdec.force_par == nil
      and sdec.force_invert == nil,
      string.format('bits=%s par=%s inv=%s', tostring(sdec.force_nbits),
                    tostring(sdec.force_par), tostring(sdec.force_invert)))
check('leaving LIN leaves the frame view', sdec.ui_mode ~= 'lin', tostring(sdec.ui_mode))
check('and the auto-detector works again straight away',
      sdec.res ~= nil and sdec.baud == 9600, tostring(sdec.baud))

-- MIDI pins a baud rate and LIN does not, so switching between them must not carry
-- MIDI's 31250 onto a LIN bus -- the form still shows it.
sdec.options()
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('midi'))
sdec.options_apply()
check('MIDI pins 31250', sdec.force_baud == 31250, tostring(sdec.force_baud))
SRC.rd, SRC.ts = lrd, lts
sdec.fs = 200000
sdec.options()
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('lin'))
sdec.options_apply()
check('switching MIDI -> LIN drops the pinned 31250 rather than inheriting it',
      sdec.force_baud == nil, tostring(sdec.force_baud))
check('and LIN then finds the real rate', sdec.baud == 19200, tostring(sdec.baud))
sdec.stop()
clearforce()
sdec.proto = 'uart'
end

-- ============================================================================
print('\na rescaling that frames nothing must not displace a snapping fit (real code)')
-- ============================================================================
-- Found by the LIN sweep, but it is a property of ua_best, not of LIN. A bus with NO
-- BREAK DELIMITER merges the break's 13 dominant bits into the sync byte's start bit, so
-- every subsequent frame is two bit times out and nothing frames at all: the true 19200
-- scored -20 at the probe and its own half scored -15. The half won on -15 > -20 and came
-- back as a confidently SNAPPED 38400 -- a wrong number that looked measured, from a
-- comparison between two candidates that both said "this does not frame".
--
-- delim = 0 is an illegal waveform, so losing the bytes is fine. Reporting double the
-- baud rate is not.
clearforce()
do    -- scoped: the main chunk is near Lua's 200-active-local limit
local ndrd, ndts, _, ndn = GEN_LIN({frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
                                              {id = 0x22, data = {0xDE, 0xAD}}},
                                    baud = 19200, fs = 200000, delim = 0})
analyse(ndrd, ndn, 200000)
sdec.decode_from(ndrd, ndn)
check('a bus with no break delimiter reports the true rate, not double it',
      sdec.baud == 19200, tostring(sdec.baud))
check('and the damage shows up as framing errors rather than as a clean decode',
      sdec.res ~= nil and sdec.res.nbad > 0,
      sdec.res and (sdec.res.nbad .. ' err') or 'nil')
-- The other half of the guard: when the fit is INADMISSIBLE, a negative-scoring
-- rescaling is the best answer there is and must still win. On this capture the fit lands
-- at 3.47 samples/bit and the only rescaling to survive the q gate is the truth at 9600,
-- scoring -5.
GEN_RESEED(20250812)
local wrd, wts, _, wn = GEN({bytes = GEN_BYTES('The quick brown fox jumps over the lazy dog 0123456789'),
                             baud = 9600, fs = 100000, noise = 0.4})
GEN_SPIKES(wrd, wn, 20, 20, 3)
GEN_RING(wrd, wn, 0.3, 4, 3)
GEN_DRIFT(wrd, wn, 0.5, 2)
analyse(wrd, wn, 100000)
sdec.decode_from(wrd, wn)
check('an inadmissible fit is still overridden by a rescaling that frames badly',
      sdec.baud == 9600, tostring(sdec.baud))
end

-- ============================================================================
print('\nsample rate follows a forced baud rate')
-- ============================================================================
-- 20000 samples at a fixed 1 MSa/s is 20 ms of signal whatever the line speed, so
-- a SLOW line yields LESS text -- 19 bytes at 9600, which is not enough to read a
-- bit-banged debug message. When the operator has forced the rate it is known
-- before the capture, so the sample rate can follow it deterministically.
do
  clearforce()
  check('nothing forced selects the default 1 MSa/s',
        sdec.fs_select() == 1000000, tostring(sdec.fs))
  -- The whole point: lowest EXACT rate meeting the oversampling target, because
  -- lower rate = longer window = more bytes.
  -- Expected values updated for the post-4b.11 ladder. Four of these got FASTER
  -- windows rather than merely different rates: 4800 40k (was 50k), 9600 80k (was
  -- 100k), 19200 160k (was 200k), 38400 320k (was 500k) -- 240 bytes per capture
  -- where three of them held 192.
  local cases = {{1200, 10000}, {2400, 20000}, {4800, 40000}, {9600, 80000},
                 {19200, 160000}, {38400, 320000}, {57600, 500000},
                 {115200, 1000000}, {250000, 1000000}}
  local allok, i = true, nil
  for i = 1, table.getn(cases) do
    if sdec.fs_for_baud(cases[i][1]) ~= cases[i][2] then allok = false end
  end
  check('each forced rate picks the lowest exact sample rate that still fits', allok)
  -- Every chosen rate must be IN sdec.rates: only decimal rates are exact on this
  -- instrument (102400 becomes 102325.5 Hz), so a computed rate would acquire at
  -- one value while the decode assumed another.
  local snapped = true
  for i = 1, table.getn(cases) do
    local fs, found, j = sdec.fs_for_baud(cases[i][1]), false, nil
    for j = 1, table.getn(sdec.rates) do
      if sdec.rates[j] == fs then found = true end
    end
    if not found then snapped = false end
  end
  check('and every chosen rate is one of the exactly-representable rates', snapped)
  check('at least 4 samples/bit -- the declared floor -- at every forced rate',
        (function()
           local j
           for j = 1, table.getn(cases) do
             if sdec.fs_for_baud(cases[j][1]) / cases[j][1] < sdec.minsabit then
               return false
             end
           end
           return true
         end)())
  check('a rate faster than the instrument can sample clamps rather than failing',
        sdec.fs_for_baud(2000000) == 1000000, tostring(sdec.fs_for_baud(2000000)))
  check('a nil or nonsense baud falls back to the default',
        sdec.fs_for_baud(nil) == 1000000 and sdec.fs_for_baud(0) == 1000000)

  -- STATELESSNESS is the property that keeps this safe. If fs stayed low after the
  -- forced rate was cleared, automatic detection would be capped near fs/minsabit
  -- and every faster line would look absent.
  sdec.force_baud = 9600
  check('forcing 9600 drops the sample rate to 80 kSa/s',
        sdec.fs_select() == 80000, tostring(sdec.fs))
  sdec.force_baud = nil
  check('and CLEARING it restores 1 MSa/s, so fast lines are still detectable',
        sdec.fs_select() == 1000000, tostring(sdec.fs))
  -- hw_config() is what the capture path calls; it must apply the selection too,
  -- or the digitizer and the assumed rate disagree.
  sdec.force_baud = 19200
  sdec.hw_config()
  check('hw_config() applies the selection rather than leaving it to the caller',
        sdec.fs == 160000, tostring(sdec.fs))
  clearforce()
  sdec.hw_config()
  check('and hw_config() restores the default once nothing is forced',
        sdec.fs == 1000000, tostring(sdec.fs))

  -- The capacity figure the operator needs, and the note built on it.
  sdec.acq_fs = 1000000
  check('the window is 19 bytes at 9600 8N1 on the default rate -- the problem',
        sdec.window_bytes(9600, 8, sdec.PAR_NONE, 1) == 19,
        tostring(sdec.window_bytes(9600, 8, sdec.PAR_NONE, 1)))
  sdec.acq_fs = 100000
  check('and 192 bytes once the rate follows a locked 9600 -- the fix',
        sdec.window_bytes(9600, 8, sdec.PAR_NONE, 1) == 192,
        tostring(sdec.window_bytes(9600, 8, sdec.PAR_NONE, 1)))
  -- Format matters: an 11-bit frame holds fewer bytes than a 10-bit one.
  check('an 8E1 frame is 11 bits, so the window is correspondingly shorter',
        sdec.window_bytes(9600, 8, sdec.PAR_EVEN, 1) == 174,
        tostring(sdec.window_bytes(9600, 8, sdec.PAR_EVEN, 1)))
  check('a nonsense baud gives nil rather than a misleading number',
        sdec.window_bytes(0, 8, sdec.PAR_NONE, 1) == nil
        and sdec.window_bytes(nil, 8, sdec.PAR_NONE, 1) == nil)
  -- AN EXACT DIVISION MUST NOT FLOOR TO ONE LESS. 20000 samples at 10 kS/s is 240 8N1 bytes
  -- at 1200 baud EXACTLY, and the two-step form -- floor(n / (fs/baud * framebits)) -- gave
  -- 239.99999999999997 and reported 239, disagreeing with the table in the comment above the
  -- function. Found while sizing candidate sample rates (tools/sweep_rates.lua): every rate
  -- picked to give a round samples/bit divides exactly, so the artifact was not an edge case,
  -- it was the good cases.
  sdec.acq_fs = 10000
  check('an EXACT window is not floored away -- 1200 baud at 10 kS/s is 240, not 239',
        sdec.window_bytes(1200, 8, sdec.PAR_NONE, 1) == 240,
        tostring(sdec.window_bytes(1200, 8, sdec.PAR_NONE, 1)))
  sdec.acq_fs = 20000
  check('and the same at 2400 baud on 20 kS/s',
        sdec.window_bytes(2400, 8, sdec.PAR_NONE, 1) == 240,
        tostring(sdec.window_bytes(2400, 8, sdec.PAR_NONE, 1)))
  -- Never OVER-report: a capacity larger than the truth would make a truncated capture look
  -- complete, which is the one direction that matters.
  sdec.acq_fs = 1000000
  local wbok, wj = true, nil
  for wj = 1, table.getn(sdec.rates) do
    local wfs, wb = sdec.rates[wj], nil
    sdec.acq_fs = wfs
    wb = sdec.window_bytes(9600, 8, sdec.PAR_NONE, 1)
    if wb ~= nil and wb > (sdec.n * 9600) / (wfs * 10) then wbok = false end
  end
  check('and no rate in sdec.rates over-reports the window', wbok)
  sdec.acq_fs = nil
end

-- ============================================================================
print('\n1.5 stop bits (Baudot)')
-- ============================================================================
-- The one format where "stop bits are unobservable, so ignore them" breaks down.
-- A 1.5-bit stop makes some pulse widths odd multiples of HALF a bit, so
-- sig_bittime's greatest-common-period fit collapses to half the true bit time and
-- the reported rate comes out DOUBLE.
--
-- This pins the REMEDY and the HONESTY, not the defect: auto-detection is expected
-- to fail here, and what must hold is that (a) it flags the failure rather than
-- returning clean-looking garbage, and (b) forcing the baud rate -- the documented
-- workflow for a wire the detector cannot read -- recovers every byte exactly.
--
-- Deliberately NOT fixed: hardening sig_bittime against a structural half-bit
-- feature would risk every common format to rescue a doubly-rare one, since 1.5
-- stop bits belongs to Baudot and therefore needs 5 data bits as well.
do
  -- GEN cannot emit half a stop bit, so build at HALF-BIT cell resolution and
  -- render at 2x baud: every real bit is two cells, the 1.5-bit stop is three.
  local cells, nc = {}, 0
  local function put(v, k) local j; for j = 1, k do nc = nc + 1; cells[nc] = v end end
  local want5 = {0x15, 0x0A, 0x1F, 0x00, 0x11, 0x1A}
  local i, b
  put(1, 40)
  for i = 1, 6 do
    put(0, 2)                                   -- start
    local t = want5[i]
    for b = 1, 5 do put(math.fmod(t, 2), 2); t = math.floor(t / 2) end
    put(1, 3)                                   -- 1.5 stop bits
    if i < 6 then put(1, 4) end
  end
  put(1, 40)
  local brd, bts, bnc, bn = GEN_RENDER(cells, nc, {baud = 19200, fs = 200000,
                                                   lo = 0, hi = 3.3})
  clearforce()
  sdec.force_nbits, sdec.force_par = 5, sdec.PAR_NONE
  analyse(brd, bn, 200000)
  sdec.decode_from(brd, bn)
  local ra = sdec.res
  check('5N1.5 defeats the automatic bit-time fit, reporting double the true rate',
        sdec.baud == 19200, tostring(sdec.baud) .. ' for a 9600 waveform')
  check('and it FLAGS the failure rather than returning clean-looking garbage',
        ra ~= nil and ra.nbad > 0, ra and (ra.nf .. ' frames ' .. ra.nbad .. ' bad'))

  -- The documented remedy. If this ever breaks, 1.5 stop bits becomes undecodable.
  sdec.force_baud = 9600
  analyse(brd, bn, 200000)
  sdec.decode_from(brd, bn)
  local rf = sdec.res
  local exact = rf ~= nil and rf.nf == 6 and rf.nbad == 0
  for i = 1, 6 do if rf == nil or rf.vals[i] ~= want5[i] then exact = false end end
  check('forcing the baud rate decodes 5N1.5 EXACTLY -- the frame layer is fine',
        exact, rf and (rf.nf .. ' frames ' .. rf.nbad .. ' bad ' ..
                       GEN_STR(rf.vals, rf.nf)) or 'nil')
  clearforce()
end

-- ============================================================================
print('\nthe note list (real code)')
-- ============================================================================
-- The note cell was a fall-through chain returning its first hit, so a second real
-- warning was not merely hidden -- nothing said it existed. It is a ranked LIST now.

-- A FULL capture is indistinguishable from a complete short message unless the panel
-- says so -- and on a continuously busy line, which is what a microcontroller dumping
-- debug text produces, every capture is full. The note is the only way the operator
-- learns they are looking at a window rather than a message.
do
  clearforce()
  sdec.clear_result()
  sdec.acq_fs, sdec.baud = 1000000, 9600
  -- 19 bytes is exactly the capacity at 9600 on the default rate.
  sdec.res = {nf = 19, nbad = 0, nbits = 8, par = sdec.PAR_NONE, nstop = 1,
              vals = {}, errs = {}}
  local nt, nn = sdec.ui_notes()
  local full, hint, i = false, false, nil
  for i = 1, nn do
    if has(nt[i], 'capture FULL') then full = true end
    if has(nt[i], 'lock the baud rate') then hint = true end
  end
  check('a capture filled to capacity SAYS so rather than looking complete', full,
        tostring(nt[1]))
  check('and points at the remedy while the rate is still unlocked', hint)
  -- One byte short of capacity is a complete message; no note.
  sdec.res.nf = 18
  nt, nn = sdec.ui_notes()
  full = false
  for i = 1, nn do if has(nt[i], 'capture FULL') then full = true end end
  check('a capture with room to spare is reported as complete, with no note', not full)
  -- Once locked, the remedy has been taken, so only the fact remains.
  sdec.res.nf = 192
  sdec.acq_fs, sdec.force_baud = 100000, 9600
  nt, nn = sdec.ui_notes()
  full, hint = false, false
  for i = 1, nn do
    if has(nt[i], 'capture FULL') then full = true end
    if has(nt[i], 'lock the baud rate') then hint = true end
  end
  check('still says FULL at the longer window, but stops suggesting a done deed',
        full and not hint)
  clearforce()
  sdec.acq_fs = nil
  sdec.clear_result()
end

-- "Auto" parity with a forced width is NOT auto: decode_from's forced path takes
-- force_par or PAR_NONE, so Data Bits = 8 with Parity = Auto decodes 8N1 without ever
-- trying 8E1 or 8O1. That is deliberate -- forcing a width bypasses the search, which
-- is the point of forcing on a noisy wire -- but the operator selected "Auto" and must
-- not read the resulting "8N1" as detected.
do
  clearforce()
  sdec.clear_result()
  sdec.force_nbits, sdec.force_par = 8, nil
  local nt, nn = sdec.ui_notes()
  local found = false
  local i
  for i = 1, nn do if has(nt[i], 'parity was ASSUMED') then found = true end end
  check('a forced width with Auto parity SAYS parity was assumed, not detected', found,
        tostring(nt[1]))
  -- Setting parity explicitly means nothing was assumed, so the note must go away.
  sdec.force_par = sdec.PAR_EVEN
  nt, nn = sdec.ui_notes()
  found = false
  for i = 1, nn do if has(nt[i], 'parity was ASSUMED') then found = true end end
  check('and it is silent once parity is set explicitly', not found)
  -- MIDI and LIN both pin width AND parity, so neither may trip it.
  sdec.force_nbits, sdec.force_par = 8, sdec.PAR_NONE
  nt, nn = sdec.ui_notes()
  found = false
  for i = 1, nn do if has(nt[i], 'parity was ASSUMED') then found = true end end
  check('nor does a protocol that pins both, which is how MIDI and LIN apply', not found)
  clearforce()
end

sdec.clear_result()
-- flog_why BY HAND, because clear_result() deliberately does not touch it: a byte-log fault is a
-- property of the KEY and outlives the capture that met it. The LIN block above pulled the key
-- (MD.usb(false)) and every capture since has failed its append, so the note list arrives here with a
-- NOT LOGGING entry already on it -- and these four checks are about the CELL's suffix arithmetic,
-- which needs the note set to be exactly what they put in it.
sdec.flog_why = nil
sdec.lasterr, sdec.stickyerr = 'first thing', 'second thing'
do    -- scoped, same reason
local nt, nn = sdec.ui_notes()
check('every applicable note is collected, not just the first', nn >= 2,
      nn .. ' notes')
check('the most important comes first', has(nt[1], 'first thing'), tostring(nt[1]))
check('the cell shows one note and says how many others there are',
      has(sdec.ui_note_text(), 'first thing')
      and has(sdec.ui_note_text(), '+' .. (nn - 1) .. ' more'), sdec.ui_note_text())
sdec.stickyerr = nil
nt, nn = sdec.ui_notes()
check('a single note carries no suffix', nn == 1
      and not has(sdec.ui_note_text(), 'more'), sdec.ui_note_text())
sdec.lasterr = nil
check('and no notes at all is an empty cell, not the word nil',
      sdec.ui_note_text() == '', '"' .. sdec.ui_note_text() .. '"')

-- WIDTH IS MEASURED, NOT COUNTED. A character count cannot decide this: the small face runs
-- 3 px to 17 px per character, so a count calibrated on narrow text passes strings that overrun
-- and one calibrated on wide text truncates strings that fit.
check('the note cell is the space between the label column and the right rule',
      sdec.ui_note_px <= sdec.ui_rule_x1 - sdec.ui_note_val_x,
      string.format('%d px vs %d available', sdec.ui_note_px,
                    sdec.ui_rule_x1 - sdec.ui_note_val_x))
check('the width model has an entry for every printable byte',
      string.len(sdec.ui_cw) == 95, string.len(sdec.ui_cw) .. ' entries')
check('a wide character measures wider than a narrow one',
      sdec.ui_textw('WWWW') > sdec.ui_textw('iiii'),
      string.format('W=%d i=%d', sdec.ui_textw('WWWW'), sdec.ui_textw('iiii')))
check('width is additive', sdec.ui_textw('ab') == sdec.ui_textw('a') + sdec.ui_textw('b'))
check('an empty string is zero px and nil is too',
      sdec.ui_textw('') == 0 and sdec.ui_textw(nil) == 0)

check('a string that fits is returned untouched',
      sdec.ui_fit('short', 700) == 'short', sdec.ui_fit('short', 700))
do
  local long = string.rep('long sentence ', 20)
  local cut = sdec.ui_fit(long, 400)
  check('one that does not is clipped INSIDE the budget',
        sdec.ui_textw(cut) <= 400, sdec.ui_textw(cut) .. ' px of 400')
  check('...and says it was clipped, rather than just ending',
        string.sub(cut, -3) == '...', cut)
  check('...and a budget too small for even the ellipsis yields nothing',
        sdec.ui_fit(long, 2) == '', '"' .. sdec.ui_fit(long, 2) .. '"')
end

-- FUZZ THE FITTER. ui_fit does byte-indexed arithmetic over a 95-entry width table and is the
-- newest code in the app, so the invariant is asserted over hostile input rather than over the
-- handful of strings the notes happen to produce: whatever comes back must fit the budget, and
-- must never be longer than what went in.
do
  local seeds = {'', 'a', '...', 'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW', string.rep('i', 400),
                 'mixed CASE with  spaces and 12345 digits!',
                 'trailing space ', ' leading space', string.rep('@', 60),
                 'tab\there', 'nul\0inside', 'high\200byte\255end',
                 string.rep('(+12 more)', 12), '...already ends in dots...'}
  local bad, nb = {}, 0
  local si, px
  for si = 1, table.getn(seeds) do
    local str = seeds[si]
    for px = -20, 760, 17 do
      local out = sdec.ui_fit(str, px)
      local w = sdec.ui_textw(out)
      if out == nil then
        nb = nb + 1; bad[nb] = string.format('seed %d px %d returned nil', si, px)
      elseif px > 0 and w > px then
        nb = nb + 1
        bad[nb] = string.format('seed %d px %d -> %d px (%q)', si, px, w, string.sub(out, 1, 24))
      elseif string.len(out) > string.len(str) + 3 then
        nb = nb + 1
        bad[nb] = string.format('seed %d px %d grew %d -> %d chars', si, px,
                                string.len(str), string.len(out))
      end
    end
  end
  check('ui_fit never exceeds its budget and never grows the string, over 14 hostile seeds '
        .. 'at 46 budgets', nb == 0,
        nb == 0 and '644 combinations clear' or table.concat(bad, ' | ', 1, math.min(nb, 4)))
  -- Width must be monotonic in the budget: a bigger cell never yields a narrower result.
  local mono = true
  local prev = -1
  for px = 0, 700, 7 do
    local w = sdec.ui_textw(sdec.ui_fit(string.rep('note text ', 30), px))
    if w < prev - 20 then mono = false end
    prev = w
  end
  check('...and a wider cell never yields a narrower result', mono)
  check('a nil budget or a nil string cannot raise',
        sdec.ui_fit(nil, 100) == '' and sdec.ui_textw(nil) == 0)
end

-- The failure this guards: an over-long note pushed '(+N more)' past the panel edge, so the
-- operator could not see that further notes existed -- the marker was itself clipped mid-word.
do
  sdec.lasterr = string.rep('WM', 200)          -- wide characters, far past any cell
  sdec.stickyerr = 'and there is a second one'
  local nt, nn = sdec.ui_notes()
  local s = sdec.ui_note_text()
  check('a note far too wide for the cell is still clipped to it',
        sdec.ui_textw(s) <= sdec.ui_note_px,
        string.format('%d px of %d', sdec.ui_textw(s), sdec.ui_note_px))
  check('...and the (+N more) marker survives the clipping',
        has(s, '+' .. (nn - 1) .. ' more'), s)
  check('...with the ellipsis before it, so the clip is visible',
        has(s, '...'), s)
  sdec.lasterr, sdec.stickyerr = nil, nil
end
end

-- ============================================================================
-- SDG arbitrary-waveform export
-- ============================================================================
-- The published example in the SDG Programming Guide is the only oracle in this
-- project that is not ours: an 8-point waveform whose file bytes the vendor
-- prints. Pinning the encoder to it is what makes "the format is right" a fact
-- rather than a reading of the prose. Everything else here guards the ways a
-- 16-bit little-endian encoder goes quietly wrong -- byte order, sign, and a
-- clip that turns a stimulus into a different stimulus without saying so.
print()
print('-- SDG arb export --')
do    -- scoped: the 200-active-locals ceiling applies to the main chunk
local TMP = os.getenv('TMPDIR') or '/tmp'
local path = TMP .. '/sdec_test_wave.bin'

-- Guide section 5.1.3: codewords 0x1000,0x2000..0x7000,0x7FFF are written as
-- the byte pairs 00 10, 00 20, .. 00 70, FF 7F.
local want = {0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x6000, 0x7000, 0x7fff}
local rd = {}
local i
for i = 1, 8 do rd[i] = GEN_VOLTS(want[i], 10.0, 0) end
local nb = GEN_WRITE(path, rd, 8, {fsv = 10.0})
local fh = io.open(path, 'rb')
local raw = fh:read('*a')
fh:close()
local hx = {}
for i = 1, string.len(raw) do hx[i] = string.format('%02x', string.byte(raw, i)) end
local got = table.concat(hx, ' ')
check('the encoder matches the programming guide\'s published 8-point example',
      got == '00 10 00 20 00 30 00 40 00 50 00 60 00 70 ff 7f', got)
check('and is two bytes per point with no header or terminator', nb == 16, nb .. ' bytes')

-- Round-trip through the INDEPENDENT reader. Written from the format
-- description rather than by inverting the encoder, so this catches a
-- byte-order or sign error instead of agreeing with one.
local back, nback = GEN_READ(path)
local rok = (nback == 8)
for i = 1, 8 do if back[i] ~= want[i] then rok = false end end
check('the file round-trips through an independent reader', rok,
      nback .. ' points')

-- Sign. A negative codeword written with the wrong endianness or as unsigned
-- comes back as a large positive one, which on the bench is a spike that was
-- never asked for.
local neg = {-1, -32768, 32767, 0}
local nrd = {}
for i = 1, 4 do nrd[i] = GEN_VOLTS(neg[i], 10.0, 0) end
GEN_WRITE(path, nrd, 4, {fsv = 10.0, clip = true})
local nb2, n2 = GEN_READ(path)
check('negative codewords survive the round trip',
      n2 == 4 and nb2[1] == -1 and nb2[3] == 32767 and nb2[4] == 0,
      string.format('%s %s %s %s', tostring(nb2[1]), tostring(nb2[2]),
                    tostring(nb2[3]), tostring(nb2[4])))

check('full scale maps to +32767 and -32767 symmetrically about the offset',
      GEN_CODE(10.0, 10.0, 0) == 32767 and GEN_CODE(-10.0, 10.0, 0) == -32767
      and GEN_CODE(0, 10.0, 0) == 0, tostring(GEN_CODE(10.0, 10.0, 0)))
check('an offset shifts the mapping rather than scaling it',
      GEN_CODE(2.5, 5.0, 2.5) == 0 and GEN_CODE(7.5, 5.0, 2.5) == 32767,
      tostring(GEN_CODE(2.5, 5.0, 2.5)))

-- A silent clip is the worst failure this code could have: the stimulus becomes
-- a different stimulus, the decode goes wrong, and it looks exactly like a
-- decoder defect. So out of range raises unless the caller says otherwise.
check('a sample past full scale RAISES rather than clipping silently',
      not pcall(function() GEN_WRITE(nil, {0, 25.0}, 2, {fsv = 5.0}) end))
check('clip = true is accepted, saturates, and counts what it saturated',
      (function()
         local n, info = GEN_WRITE(nil, {0, 25.0, -25.0}, 3,
                                   {fsv = 5.0, clip = true})
         return info.nclip == 2 and info.peak_code == 32768
       end)())
check('an fsv above the 20 Vpp ceiling RAISES -- the generator cannot reach it',
      not pcall(function() GEN_WRITE(nil, {0, 0}, 2, {fsv = 10.5}) end))
check('a nil sample RAISES rather than encoding as zero volts',
      not pcall(function() GEN_WRITE(nil, {0, nil, 0}, 3, {fsv = 5.0}) end))
check('a point count past the SDG2000X 8 Mpt limit RAISES',
      not pcall(function() GEN_WRITE(nil, {0, 0}, GEN_SDG_MAXPTS + 1, {fsv = 5}) end))

-- An odd-length file is a truncated copy. Playing one is a silently shorter
-- waveform, so the reader must refuse it rather than drop the last byte.
local tf = io.open(path, 'wb')
tf:write('\1\2\3')
tf:close()
check('an odd-length file RAISES instead of dropping half a point',
      not pcall(function() GEN_READ(path) end))

-- The checksum exists to catch exactly that: a truncated copy to the USB key.
local a = GEN_CKSUM('hello')
check('the checksum changes when a byte changes', a ~= GEN_CKSUM('hellp'),
      tostring(a))
check('and when the length changes', a ~= GEN_CKSUM('hello\0'), tostring(a))
-- Order sensitivity is the property a plain additive sum lacks, and a swapped
-- pair of bytes is what a wrong-endian write looks like.
check('and when two bytes are transposed', GEN_CKSUM('ab') ~= GEN_CKSUM('ba'),
      tostring(GEN_CKSUM('ab')))

os.remove(path)
end

-- ===========================================================================
print('chunked decode -- captures longer than Lua memory (chunk_decode.tsp)')
-- ===========================================================================
-- The seam is the only genuinely new failure mode here, and it is invisible: a
-- byte lost or doubled where two windows meet reads as a plausible log file.
-- So the tests run a DELIBERATELY TINY window -- 2000 samples, about 16 bytes --
-- and sweep the payload length, which walks the seam through every phase of a
-- frame. At the shipped 20 000 the same payloads would cross no seam at all.
--
-- WRAPPED IN A FUNCTION, not a do...end block like the sections above it. The main
-- chunk already carries ~130 top-level locals and Lua's limit is 200 ACTIVE ones per
-- function -- a do...end block's locals still occupy the enclosing function's register
-- window, so this section's ~70 tipped the whole file over with "too many local
-- variables (limit is 200) in main function". A function scope costs one local instead
-- of seventy. The instrument has the same limit, so a section this long belongs in a
-- function whichever Lua is running it.
local function test_chunked()
  local LOREM = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do ' ..
                'eiusmod tempor incididunt ut labore et dolore magna aliqua. '

  -- Chunked decode of a generated waveform. Returns bytes, totals, reason.
  local function ck(opts, ckwin, maxbytes)
    local rd, ts, nc, nsmp = GEN(opts)
    sdec.acq_fs = opts.fs or 1000000
    local old = sdec.ck_win_n
    if ckwin ~= nil then sdec.ck_win_n = ckwin end
    local reader = sdec.ck_reader_table(rd, nsmp)
    local got, errs, win = {}, {}, {}
    local fmt, why = sdec.ck_prime(reader, nsmp, win)
    local tot, terr = nil, why
    if fmt ~= nil then
      tot, terr = sdec.ck_decode(reader, nsmp, fmt, sdec.ck_sink_collect(got, errs),
                                 {win = win, maxbytes = maxbytes})
    end
    sdec.ck_win_n = old
    return got, tot, terr, errs
  end

  clearforce()
  sdec.force_baud = 9600

  -- ---- the seam sweep ----
  local firstbad, nsweep = nil, 0
  local L
  for L = 1, 240 do
    local pay = string.sub(string.rep(LOREM, 3), 1, L)
    local got, tot = ck({bytes = GEN_BYTES(pay), baud = 9600, fs = 100000}, 2000)
    nsweep = nsweep + 1
    if tot == nil or GEN_STR(got, tot.nf) ~= pay then
      if firstbad == nil then firstbad = L end
    end
  end
  check('every payload length 1..240 decodes EXACTLY across ~15 seams',
        firstbad == nil, string.format('%d lengths swept, first failure %s',
                                       nsweep, tostring(firstbad)))

  -- ---- the case that makes carried phase necessary rather than merely tidy ----
  -- A gapless stream has no 1.5-bit mark run, so a window that re-anchored would
  -- fall through to "the first candidate edge" -- a DATA transition inside a byte --
  -- and everything after it in that window would decode misaligned.
  local src2 = string.rep(LOREM, 2)
  local g, t = ck({bytes = GEN_BYTES(src2), baud = 9600, fs = 100000, gap = 0}, 2000)
  check('a GAPLESS stream survives every seam (no idle to re-anchor on)',
        t ~= nil and GEN_STR(g, t.nf) == src2,
        string.format('%s bytes over %s windows', tostring(t and t.nf),
                      tostring(t and t.nwin)))

  -- De-duplication is by POSITION, not by value: two identical bytes at different
  -- positions are two bytes, so a value-based dedup would silently eat one.
  local rep55 = {}
  for L = 1, 300 do rep55[L] = 0x55 end
  g, t = ck({bytes = rep55, baud = 9600, fs = 100000, gap = 0}, 2000)
  local same = (t ~= nil and t.nf == 300)
  if t ~= nil then
    for L = 1, t.nf do if g[L] ~= 0x55 then same = false end end
  end
  check('300 identical bytes gapless -- dedup is positional, not by value', same,
        string.format('nf=%s', tostring(t and t.nf)))

  -- 0x00 is the case that defeats sig_idle's longest-run prior (start bit plus
  -- eight zero data bits is a nine-bit low run against a one-bit stop).
  local rep00 = {}
  for L = 1, 300 do rep00[L] = 0 end
  g, t = ck({bytes = rep00, baud = 9600, fs = 100000, gap = 0}, 2000)
  local zok = (t ~= nil and t.nf == 300)
  if t ~= nil then
    for L = 1, t.nf do if g[L] ~= 0 then zok = false end end
  end
  check('300 x 0x00 gapless across ~19 seams', zok,
        string.format('nf=%s', tostring(t and t.nf)))

  -- A bursty line puts entire windows at idle, which is the case that forbids
  -- re-measuring the levels per window.
  local fox = 'The quick brown fox jumps over the lazy dog'
  g, t = ck({bytes = GEN_BYTES(fox), baud = 9600, fs = 100000, gap = 200}, 2000)
  check('a bursty line with whole windows of idle still decodes exactly',
        t ~= nil and GEN_STR(g, t.nf) == fox,
        string.format('%s bytes over %s windows', tostring(t and t.nf),
                      tostring(t and t.nwin)))

  -- ---- differential: chunked must equal the monolithic decoder ----
  -- The strongest available assertion, because it needs no expected value: the
  -- same waveform through both paths must give the same bytes.
  local dcases = {
    {'8N1',      {baud = 9600,   fs = 100000}},
    {'7E1',      {baud = 9600,   fs = 100000, nbits = 7, par = 1}},
    {'8E1',      {baud = 9600,   fs = 100000, nbits = 8, par = 1}},
    {'8O1',      {baud = 9600,   fs = 100000, nbits = 8, par = 2}},
    {'RS-232',   {baud = 9600,   fs = 100000, invert = true, lo = -6, hi = 6}},
    {'115200',   {baud = 115200, fs = 1000000}},
    {'20 % noise', {baud = 9600, fs = 100000, noise = 0.25}},
  }
  local di
  for di = 1, table.getn(dcases) do
    local nm, o = dcases[di][1], dcases[di][2]
    o.bytes = hb
    clearforce()
    local rd, ts, nc, nsmp = GEN(o)
    analyse(rd, nsmp, o.fs)
    local mok = sdec.decode_from(rd, nsmp)
    local mtxt = mok and GEN_STR(sdec.res.vals, sdec.res.nf) or nil
    local mnf = mok and sdec.res.nf or -1
    clearforce()
    local cg, ct = ck(o, 20000)
    local ctxt = ct and GEN_STR(cg, ct.nf) or nil
    check('chunked == monolithic, ' .. nm,
          mtxt ~= nil and mtxt == ctxt and mnf == (ct and ct.nf),
          string.format('mono %d [%s] / chunk %s [%s]', mnf, tostring(mtxt),
                        tostring(ct and ct.nf), tostring(ctxt)))
  end

  -- ---- geometry ----
  clearforce()
  sdec.force_baud = 9600
  local W, ov, stride, why = sdec.ck_geometry(10.417, 10)
  check('overlap is at least one whole frame -- the derived floor',
        ov ~= nil and ov >= 10 * 10.417, tostring(ov))
  check('and the stride still makes forward progress',
        stride ~= nil and stride > 0 and stride < W,
        string.format('W=%s stride=%s', tostring(W), tostring(stride)))
  -- Forcing 1200 baud while fs is still 1 MSa/s gives T = 833, so one 12-bit frame
  -- is 10 000 samples and the stride would go to zero. Refuse, and name the remedy.
  local W2, ov2, st2, why2 = sdec.ck_geometry(833.33, 12)
  check('a bit time too long for the window is REFUSED, not clamped',
        W2 == nil and why2 ~= nil and has(why2, 'sample slower'), tostring(why2))
  -- Window count is exact because the stride is constant, which is what lets the
  -- progress indicator be a count rather than a guess.
  check('the window count is exact, not estimated',
        sdec.ck_nwin(100000, 20000, 19623) == 1 + math.ceil(80000 / 19623),
        tostring(sdec.ck_nwin(100000, 20000, 19623)))
  check('a capture inside one window is one window',
        sdec.ck_nwin(5000, 20000, 19623) == 1)
  -- Below the minimum the whole run refuses rather than looping forever.
  local rg, rt, rwhy = ck({bytes = GEN_BYTES(fox), baud = 9600, fs = 100000}, 500)
  check('a window below the minimum refuses the run and says why',
        rt == nil and rwhy ~= nil and has(rwhy, 'sample slower'), tostring(rwhy))

  -- ---- the cap ----
  local capsrc = string.rep(LOREM, 3)
  local capb, capn = GEN_BYTES(capsrc)
  local ci
  local caps = {1, 7, 16, 17, 100, 333}
  for ci = 1, table.getn(caps) do
    local cap = caps[ci]
    local cg, ct = ck({bytes = capb, baud = 9600, fs = 100000}, 2000, cap)
    check(string.format('the %d byte cap is exact, clipping mid-window', cap),
          ct ~= nil and ct.nf == cap and GEN_STR(cg, ct.nf) == string.sub(capsrc, 1, cap),
          string.format('nf=%s stopped=%s', tostring(ct and ct.nf),
                        tostring(ct and ct.stopped)))
  end
  local cg2, ct2 = ck({bytes = capb, baud = 9600, fs = 100000}, 2000, capn + 50)
  check('a cap above the stream length is not reported as a truncation',
        ct2 ~= nil and ct2.nf == capn and ct2.stopped == nil,
        string.format('nf=%s stopped=%s', tostring(ct2 and ct2.nf),
                      tostring(ct2 and ct2.stopped)))
  local cg3, ct3 = ck({bytes = capb, baud = 9600, fs = 100000}, 2000, capn)
  check('a cap exactly at the stream length DOES say the stream may continue',
        ct3 ~= nil and ct3.nf == capn and ct3.stopped == 'cap' and
        has(sdec.ck_summary(ct3), 'may continue'), sdec.ck_summary(ct3))

  -- ---- levels are measured over the WHOLE recording, not its head ----
  -- The defect this replaced: priming the threshold on the first window decoded
  -- 78 of 248 bytes with 50 errors on a drifting line, because the head of a
  -- drifting capture is a systematically offset slice of it.
  check('the level count is fixed, not tied to the window size',
        sdec.ck_level_n == sdec.n,
        string.format('ck_level_n=%s n=%s', tostring(sdec.ck_level_n),
                      tostring(sdec.n)))
  do
    local dsrc = string.rep(LOREM, 2)
    local dbytes = GEN_BYTES(dsrc)
    local rd, ts, nc, nsmp = GEN({bytes = dbytes, baud = 9600, fs = 100000})
    GEN_DRIFT(rd, nsmp, 0.3, 3)
    -- Frame mode's own answer on the identical array is the oracle.
    clearforce()
    sdec.force_baud = 9600
    sdec.acq_fs = 100000
    local fok = sdec.sig_levels(rd, nsmp)
    sdec.sig_edges(rd, nsmp)
    sdec.sig_idle(rd, nsmp)
    local fdok = fok and sdec.decode_from(rd, nsmp)
    local fthr = sdec.thr
    local ftxt = fdok and GEN_STR(sdec.res.vals, sdec.res.nf) or nil

    -- Chunked, at two window sizes an order of magnitude apart. The threshold must
    -- not move with the window, or an accept/refuse decision about signal quality
    -- would depend on a memory parameter.
    local thr2000, thr20000 = nil, nil
    local ok2000, ok20000 = nil, nil
    local ws = {2000, 20000}
    local wi
    for wi = 1, 2 do
      local rd2, ts2, nc2, n2 = GEN({bytes = dbytes, baud = 9600, fs = 100000})
      GEN_DRIFT(rd2, n2, 0.3, 3)
      clearforce()
      sdec.force_baud = 9600
      sdec.acq_fs = 100000
      local old = sdec.ck_win_n
      sdec.ck_win_n = ws[wi]
      local reader = sdec.ck_reader_table(rd2, n2)
      local got, win = {}, {}
      local fmt = sdec.ck_prime(reader, n2, win)
      local tot = nil
      if fmt ~= nil then
        tot = sdec.ck_decode(reader, n2, fmt, sdec.ck_sink_collect(got), {win = win})
      end
      sdec.ck_win_n = old
      if wi == 1 then thr2000, ok2000 = sdec.thr, tot and GEN_STR(got, tot.nf)
      else thr20000, ok20000 = sdec.thr, tot and GEN_STR(got, tot.nf) end
    end
    check('the threshold does not move with the window size',
          near(thr2000, thr20000, 1e-9),
          string.format('%.6f vs %.6f', thr2000, thr20000))
    -- NOT bit-identical to frame mode's, and it should not be: frame mode averages
    -- all 31 397 samples while this decimates to 15 699 of them. Two different
    -- populations of the same signal, agreeing to 4e-5 V -- a thousandth of the
    -- hysteresis band. Asserting equality here would be asserting a coincidence.
    check('and it matches what frame mode measures over the whole capture',
          near(thr2000, fthr, 0.005), string.format('%.6f vs %.6f', thr2000, fthr))
    check('0.3 V of drift decodes exactly at both window sizes',
          ftxt == dsrc and ok2000 == dsrc and ok20000 == dsrc,
          string.format('frame=%s w2000=%s w20000=%s',
                        tostring(ftxt == dsrc), tostring(ok2000 == dsrc),
                        tostring(ok20000 == dsrc)))
  end

  -- ---- the file sink ----
  clearforce()
  sdec.force_baud = 9600
  -- Through the MOCK's file API, not io.open: ck_sink_file calls the instrument's
  -- file.open/write, so the mock is the only thing that exercises the shipped path --
  -- and it is also what models a missing key and a key pulled mid-write.
  do
    MD.usb(true)                      -- an earlier section leaves the key "removed"
    MD.forget_files()
    local rd, ts, nc, nsmp = GEN({bytes = GEN_BYTES(string.rep(LOREM, 2)),
                                  baud = 9600, fs = 100000})
    sdec.acq_fs = 100000
    local old = sdec.ck_win_n
    sdec.ck_win_n = 2000
    local tot, terr = sdec.ck_run(sdec.ck_reader_table(rd, nsmp), nsmp,
                                  '/usb1/stream00.txt', {})
    sdec.ck_win_n = old
    check('ck_run writes a file and reports the byte count',
          tot ~= nil and tot.nf == 248, string.format('%s / %s',
          tostring(tot and tot.nf), tostring(terr)))
    check('and the file it named exists on the key',
          MD.files()['/usb1/stream00.txt'] == true)
    -- Rows are 16 bytes and a window boundary is not a multiple of 16, so the carry
    -- across seams is what keeps every row full and every offset aligned. A ragged
    -- row would mean a seam had flushed early.
    -- HEADER LINES ARE SKIPPED, and they exist by design: the byte log is now ONE file that
    -- every mode appends to, so a stream's rows sit alongside frame captures' '---- msg N'
    -- blocks and its own '---- stream' header. The contiguity being checked is of the DATA
    -- rows -- a ragged one still means a seam flushed early -- so the parse has to skip what
    -- is not a data row rather than counting it as one and reporting 17 misaligned rows.
    local body = MD.logtext()
    local nl, nshort = 0, 0
    local line
    for line in string.gmatch(body, '[^\r\n]+') do
      if string.sub(line, 1, 4) ~= '----' then
        nl = nl + 1
        local off = tonumber(string.sub(line, 1, 4))
        if off ~= (nl - 1) * 16 then nshort = nshort + 1 end
      end
    end
    check('the file is 16 bytes a row with contiguous offsets across every seam',
          nl == math.ceil(248 / 16) and nshort == 0,
          string.format('%d rows, %d misaligned', nl, nshort))
    check('and the first row is the start of the payload',
          has(body, '|Lorem ipsum dolo|'), string.sub(body, 1, 60))
    check('ck_run frees the frame-mode capture rather than holding it alongside',
          sdec.smp == nil)

    -- A key pulled mid-stream must stop the run and SAY the file is incomplete: a
    -- truncated log that reports success is worse than no log.
    MD.usb(true)
    MD.forget_files()
    MD.failwrite(3)
    sdec.ck_win_n = 2000
    local btot = sdec.ck_run(sdec.ck_reader_table(rd, nsmp), nsmp,
                             '/usb1/stream01.txt', {})
    sdec.ck_win_n = old
    check('a key pulled mid-stream stops the run and reports the write failure',
          btot ~= nil and btot.stopped ~= nil and
          has(sdec.ck_summary(btot), 'WRITE FAILED'),
          string.format('stopped=%s / %s', tostring(btot and btot.stopped),
                        btot and sdec.ck_summary(btot) or '?'))
    MD.failwrite(nil)

    -- No key at all is a NORMAL condition, so it refuses with a reason rather than
    -- raising from inside what will be a touch handler.
    MD.usb(false)
    sdec.ck_win_n = 2000
    local ntot, nwhy = sdec.ck_run(sdec.ck_reader_table(rd, nsmp), nsmp,
                                   '/usb1/stream02.txt', {})
    sdec.ck_win_n = old
    check('no USB key refuses with a reason rather than raising',
          ntot == nil and nwhy ~= nil and has(nwhy, 'cannot append'), tostring(nwhy))
    MD.usb(true)
  end

  -- ---- chunking: a budgeted run must equal an unbudgeted one, byte for byte ----
  --
  -- This is THE invariant. Slicing a decode is only safe if the seam arithmetic survives being
  -- suspended and resumed, so the test is not "does it still produce bytes" but "does it produce
  -- the SAME bytes as the one-shot path" -- including the error flags, whose positions are what a
  -- mis-stepped seam would disturb first.
  do
    MD.usb(true)
    MD.forget_files()
    clearforce()
    sdec.force_baud = 9600
    local rd, ts, nc, nsmp = GEN({bytes = GEN_BYTES(string.rep(LOREM, 2)),
                                  baud = 9600, fs = 100000})
    sdec.acq_fs = 100000
    local old = sdec.ck_win_n
    sdec.ck_win_n = 2000

    -- One shot, collecting into arrays.
    local av, ae = {}, {}
    local aj = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp, nil,
                               {sink = sdec.ck_sink_collect(av, ae)})
    local adone, atot = false, nil
    while not adone do adone, atot = sdec.ck_job_step(aj) end

    -- Sliced one window at a time: budget_s below a single window's cost, which ck_slice_win
    -- floors at 1. The most adversarial slicing available, and the cheapest to reason about.
    local bv, be = {}, {}
    local bj = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp, nil,
                               {budget_s = 0.000001, sink = sdec.ck_sink_collect(bv, be)})
    local bdone, btot, nslice = false, nil, 0
    while not bdone and nslice < 500 do
      bdone, btot = sdec.ck_job_step(bj)
      nslice = nslice + 1
    end

    check('a one-window-at-a-time run takes MANY slices -- the budget is really being honoured',
          nslice > 3, string.format('%d slices', nslice))
    check('and it decodes the same number of bytes as the one-shot run',
          atot ~= nil and btot ~= nil and atot.nf == btot.nf,
          string.format('one-shot %s vs sliced %s', tostring(atot and atot.nf),
                        tostring(btot and btot.nf)))
    local diff, ediff = -1, -1
    if atot ~= nil and btot ~= nil then
      diff, ediff = 0, 0
      local i
      for i = 1, atot.nf do
        if av[i] ~= bv[i] then diff = diff + 1 end
        if ae[i] ~= be[i] then ediff = ediff + 1 end
      end
    end
    check('and every byte is IDENTICAL -- the seam survives suspend/resume', diff == 0,
          string.format('%d differing bytes of %s', diff, tostring(atot and atot.nf)))
    check('and so is every error flag -- a mis-stepped seam would move these first',
          ediff == 0, string.format('%d differing flags', ediff))
    check('the same error counts, not just the same total',
          atot ~= nil and btot ~= nil and atot.ngood == btot.ngood and
          atot.nbad == btot.nbad,
          string.format('good %s/%s bad %s/%s', tostring(atot and atot.ngood),
                        tostring(btot and btot.ngood), tostring(atot and atot.nbad),
                        tostring(btot and btot.nbad)))
    check('a finished job reports done and stays done when stepped again',
          sdec.ck_job_step(bj) == true)

    -- The tail must also survive slicing: it is fed per sink call, so a resumed run that
    -- rebuilt its ring would show only the last slice's bytes.
    check('the retained tail spans the whole run, not just the final slice',
          btot ~= nil and btot.tail ~= nil and btot.tail.nf == atot.tail.nf,
          string.format('sliced tail %s vs one-shot %s',
                        tostring(btot and btot.tail and btot.tail.nf),
                        tostring(atot and atot.tail and atot.tail.nf)))

    -- ck_slice_win's own arithmetic, since everything above depends on it.
    check('no budget means no limit -- which is why ck_run is unchanged',
          sdec.ck_slice_win(nil, 20000) == nil)
    check('a budget below one window still yields one window, never zero',
          sdec.ck_slice_win(0.001, 20000) == 1)
    -- ONE window, and not because of a reserve: at the measured 52 us a sample a 20 000-sample
    -- window is 1.04 s all by itself, so a 0.5 s budget cannot buy one -- ck_slice_win floors at
    -- one and the WIDTH is what has to come down. That is ck_win_for's job.
    check('the 500 ms budget cannot buy a 20 000-sample window at all -- it floors at one',
          sdec.ck_slice_win(0.5, 20000) == 1,
          tostring(sdec.ck_slice_win(0.5, 20000)))
    check('and NARROWER windows are cheaper, so more of them fit',
          sdec.ck_slice_win(0.5, 2000) == 3,
          tostring(sdec.ck_slice_win(0.5, 2000)))
    check('and it is monotonic in the budget, which is the only property callers rely on',
          sdec.ck_slice_win(1.0, 2000) > sdec.ck_slice_win(0.5, 2000),
          string.format('%s vs %s', tostring(sdec.ck_slice_win(1.0, 2000)),
                        tostring(sdec.ck_slice_win(0.5, 2000))))

    -- ck_win_for: the width the latency bound actually rests on. Measured per-phase costs are all
    -- proportional to W, so ONE width bounds levels, the lead-in read, the edge pass, the format
    -- search and every decode slice together.
    local w5 = sdec.ck_win_for(0.5)
    check('a 500 ms budget picks a window whose worst phase fits inside it',
          w5 * sdec.ck_smp_us * 1e-6 <= 0.5,
          string.format('W=%d -> %.3f s', w5, w5 * sdec.ck_smp_us * 1e-6))
    check('and that window is a useful size, not a token one', w5 >= 5000,
          string.format('%d samples', w5))
    check('no budget means the full window -- the one-shot path wants the fewest seams',
          sdec.ck_win_for(nil) == sdec.ck_win_max, tostring(sdec.ck_win_for(nil)))
    check('a generous budget is still capped at the maximum',
          sdec.ck_win_for(100) == sdec.ck_win_max, tostring(sdec.ck_win_for(100)))
    check('and an absurd budget is floored, because seam overhead dominates below that',
          sdec.ck_win_for(1e-6) == sdec.ck_win_min, tostring(sdec.ck_win_for(1e-6)))
    check('wider budget, wider window', sdec.ck_win_for(0.9) > sdec.ck_win_for(0.3),
          string.format('%d vs %d', sdec.ck_win_for(0.9), sdec.ck_win_for(0.3)))

    -- The level cap is SEPARATE from the window, and nil off the panel path.
    local oldcap = sdec.ck_level_max
    sdec.ck_level_max = nil
    local lr = sdec.ck_reader_table(rd, nsmp)
    check('with no cap the decimated level pass uses the full ck_level_n',
          sdec.ck_levels_dec(lr, nsmp, {}) == true)
    sdec.ck_level_max = 1500
    check('and with a cap it still finds the levels, on fewer samples',
          sdec.ck_levels_dec(lr, nsmp, {}) == true)
    sdec.ck_level_max = oldcap

    -- ---- chunking the RATE SEARCH: stepped must equal one-shot ----
    --
    -- Same invariant as the decode above, and the same reason for insisting on it: ua_best decides
    -- the BAUD RATE, so a split that changes its answer is the worst class of bug this app can
    -- have -- a confident wrong number. The stepper is compared against ua_best() itself, which is
    -- now built on it, so this also pins the wrapper.
    do
      clearforce()
      local rd2, ts2, nc2, ns2 = GEN({bytes = GEN_BYTES('Hello, World!'),
                                      baud = 9600, fs = 100000})
      sdec.acq_fs = 100000
      sdec.sig_levels(rd2, ns2)
      sdec.sig_edges(rd2, ns2)
      local Tfit = sdec.sig_bittime(sdec.w, sdec.nw)
      check('the fixture produces a bit time to search around', Tfit ~= nil,
            tostring(Tfit))

      local wT, wr, wwhy = sdec.ua_best(rd2, ns2, Tfit)

      local st = sdec.ua_best_begin(rd2, ns2, Tfit)
      local nprobe = 0
      while sdec.ua_best_probe(st) do nprobe = nprobe + 1 end
      local sT, sr, swhy = sdec.ua_best_end(st)

      check('the stepped search probes every candidate, one per call', nprobe > 5,
            string.format('%d probes', nprobe))
      check('and reaches the SAME bit time as the one-shot search', wT == sT,
            string.format('one-shot %s vs stepped %s', tostring(wT), tostring(sT)))
      check('and the same ratio and the same reason', wr == sr and wwhy == swhy,
            string.format('%s/%s vs %s/%s', tostring(wr), tostring(wwhy),
                          tostring(sr), tostring(swhy)))
      local at, tot2 = sdec.ua_best_progress(st)
      check('progress reports position and total, for a "searching N/M" row',
            at == tot2 and tot2 == nprobe,
            string.format('%s/%s of %d', tostring(at), tostring(tot2), nprobe))
      check('probing past the end reports false rather than looping forever',
            sdec.ua_best_probe(st) == false)
      check('and a nil state is refused rather than raising',
            sdec.ua_best_probe(nil) == false)

      -- The probe cap: its DEFAULT must be on, since the 4.376 s auto-detect measured on the
      -- instrument is what it exists for, and a nil default would silently restore that.
      check('the ranking probe is capped by default -- the search is the latency offender',
            sdec.ua_probe_n ~= nil and sdec.ua_probe_n > 0,
            tostring(sdec.ua_probe_n))
      check('and the cap leaves margin over the 1500-sample floor the sweep measured',
            sdec.ua_probe_n >= 1500, tostring(sdec.ua_probe_n))
      -- Anchored to the first edge, not to sample 1 -- the "one byte at the very end" case.
      local oldcap = sdec.ua_probe_n
      sdec.ua_probe_n = 200
      local lateT = sdec.ua_best(rd2, ns2, Tfit)
      sdec.ua_probe_n = oldcap
      check('an absurdly small cap still finds a bit time, because the window follows the '
            .. 'traffic rather than starting at sample 1', lateT ~= nil, tostring(lateT))
    end

    -- Abandoning mid-run has to close the file and keep what was decoded. Stepping to the
    -- FIRST BYTES rather than once: priming is phased, so the early steps are level, edge and
    -- format phases that have decoded nothing yet -- and abandoning before any window has run
    -- is a different case, covered below.
    MD.forget_files()
    local cj = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp,
                               '/usb1/stream09.txt', {budget_s = 0.000001})
    local cn = 0
    while cn < 32 and (cj.tot == nil or cj.tot.nf == 0) do
      sdec.ck_job_step(cj)
      cn = cn + 1
    end
    check('priming is phased, so reaching the first decoded byte takes several steps',
          cn > 1, string.format('%d steps', cn))
    local ctot = sdec.ck_job_abandon(cj)
    check('abandoning a job keeps the bytes decoded so far',
          ctot ~= nil and ctot.nf > 0 and ctot.stopped ~= nil,
          string.format('%s bytes, stopped=%s', tostring(ctot and ctot.nf),
                        tostring(ctot and ctot.stopped)))
    check('and still gives a tail to show them with',
          ctot ~= nil and ctot.tail ~= nil and ctot.tail.nf > 0,
          tostring(ctot and ctot.tail and ctot.tail.nf))
    check('and the partial file was closed rather than leaked',
          MD.files()['/usb1/stream09.txt'] == true)

    -- PHASED PRIMING. The press that stops a recording used to pay for every level probe, the
    -- lead-in read, the edge pass and the format search in one handler; each is now its own step.
    MD.forget_files()
    local pj = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp,
                               '/usb1/stream10.txt', {budget_s = 0.000001})
    check('a job is created without priming -- creation itself does no work',
          pj ~= nil and pj.fmt == nil and pj.prime ~= nil)
    check('and it names the phase it is about to run, for the status row',
          pj ~= nil and pj.phase ~= nil, tostring(pj and pj.phase))
    check('the file is NOT open yet either -- an unprimeable recording must not spend a number',
          MD.files()['/usb1/stream10.txt'] == nil)
    local phases, pn, pdone = {}, 0, false
    local pk = 0
    while not pdone and pk < 32 do
      if pj.prime ~= nil then pn = pn + 1; phases[pn] = tostring(pj.prime.phase) end
      pdone = sdec.ck_job_step(pj)
      if pj.fmt ~= nil then break end
      pk = pk + 1
    end
    check('priming ran as several phases, not one', pn >= 3,
          string.format('%d phases: %s', pn, table.concat(phases, ' ')))
    check('and it ends with a format, which is what the windows need',
          pj.fmt ~= nil and pj.fmt.T ~= nil and pj.fmt.framebits ~= nil,
          string.format('T=%s framebits=%s', tostring(pj.fmt and pj.fmt.T),
                        tostring(pj.fmt and pj.fmt.framebits)))
    check('the sink chain exists once the format does, and only then',
          pj.sink ~= nil and pj.tail ~= nil)
    sdec.ck_job_abandon(pj)

    -- Abandoning DURING priming: nothing was decoded, so there is nothing to keep -- and
    -- crucially nothing to close, because no file was ever opened.
    MD.forget_files()
    local qj = sdec.ck_job_new(sdec.ck_reader_table(rd, nsmp), nsmp, '/usb1/stream11.txt', {})
    sdec.ck_job_step(qj)
    local qtot = sdec.ck_job_abandon(qj)
    check('abandoning mid-prime returns no result, because nothing was decoded', qtot == nil)
    check('and left no empty file behind', MD.files()['/usb1/stream11.txt'] == nil)
    check('and cleared the prime state, so the job cannot be resumed into',
          qj.prime == nil and qj.done == true)

    -- An idle line: ck_job_new now SUCCEEDS and the failure arrives from a step. Every caller
    -- reads the reason off ck_job_step, so the message must survive the move.
    MD.forget_files()
    local idle = {}
    local ii
    for ii = 1, 4000 do idle[ii] = 3.3 end
    local ij, ijerr = sdec.ck_job_new(sdec.ck_reader_table(idle, 4000), 4000,
                                      '/usb1/stream12.txt', {})
    check('a job on an idle line is still CREATED -- priming has not run yet',
          ij ~= nil, tostring(ijerr))
    local idone, itot, ierr = false, nil, nil
    local ik = 0
    while not idone and ik < 32 do
      idone, itot, ierr = sdec.ck_job_step(ij)
      ik = ik + 1
    end
    check('and the idle line is reported from a STEP, with a reason',
          idone == true and itot == nil and ierr ~= nil, tostring(ierr))
    check('and no file was created for a recording that could not be primed',
          MD.files()['/usb1/stream12.txt'] == nil)

    -- ck_run must be untouched by all of it: one call in, a totals table out.
    local rtot, rerr = sdec.ck_run(sdec.ck_reader_table(rd, nsmp), nsmp, nil, {})
    check('ck_run still primes and decodes in one call', rtot ~= nil and rtot.nf > 0,
          string.format('%s bytes %s', tostring(rtot and rtot.nf), tostring(rerr)))
    local ptot, perr2 = sdec.ck_run(sdec.ck_reader_table(idle, 4000), 4000, nil, {})
    check('and still reports an idle line as a failure with a reason',
          ptot == nil and perr2 ~= nil, tostring(perr2))

    sdec.ck_win_n = old
  end
  clearforce()
end
test_chunked()

-- ===========================================================================
print('\nmuting event 4915 -- the instrument complaining about its own behaviour')
-- ===========================================================================
-- LoopUntilEvent's pre-trigger reserve is circular: it keeps the LAST readings before the trigger,
-- so it overwrites the oldest while waiting. A user-defined buffer is FILL_ONCE, where an overwrite
-- is a discard, and each discard posts 4915 at ERROR severity -- a modal box over the hex dump.
-- Measured: ten per capture at 300, 600 and 1200 baud, none at 9600 and above. FILL_CONTINUOUS does
-- not exist on this firmware. So the POPUPS are muted for the capture and the LOG is left intact --
-- draining it was tried and lost real events, because next() consumes and post() cannot put one back.
local function test_mute()
  sdec.quiet_events()
  check('normally the panel shows error-severity events', MD.showevents() == eventlog.SEV_ERROR,
        tostring(MD.showevents()))
  sdec.mute_events()
  check('muting stops them entirely, popups included', MD.showevents() == 0,
        tostring(MD.showevents()))
  sdec.unmute_events()
  check('and unmuting restores exactly the previous setting',
        MD.showevents() == eventlog.SEV_ERROR, tostring(MD.showevents()))

  -- THE LOG IS NOT TOUCHED. Muting is a display setting; the events still accumulate, so a report
  -- or the USB log can still see them. Draining instead LOST events -- next() consumes and post()
  -- cannot put one back, it creates a fresh "1005 User" entry.
  if MD.evpost ~= nil then
    MD.evclear()
    sdec.mute_events()
    MD.evpost(4915, 'store past capacity')
    MD.evpost(1234, 'something genuinely wrong')
    check('events still reach the log while muted', eventlog.getcount() == 2,
          tostring(eventlog.getcount()))
    sdec.unmute_events()
    local code = eventlog.next()
    check('and nothing was consumed or rewritten -- the first is still 4915', code == 4915,
          tostring(code))
    MD.evclear()
  end
end
test_mute()

-- ===========================================================================
print('\nbuffer capacity vs capture depth -- event 4915')
-- ===========================================================================
-- LoopUntilEvent takes its pre-trigger reserve out of buffer CAPACITY, not out of `count`, so a
-- buffer sized exactly n delivers n minus the reserve -- measured 19011 of 20000 -- and asking for
-- more than fits posts 4915 and truncates. acq_cap() adds the reserve; acq_fit() clamps a request
-- that still would not fit, so 4915 is unreachable rather than merely unlikely.
local function test_capacity()
  clearforce()
  local oldtm, oldpt, oldn = sdec.trigmode, sdec.pretrig, sdec.n
  sdec.pretrig, sdec.n = 5, 20000

  sdec.trigmode = 'edge'
  local cap = sdec.acq_cap(20000)
  check('an armed capture asks for the pre-trigger reserve ON TOP of its depth',
        cap > 20000 + 20000 * 0.05, string.format('%s for n=20000', tostring(cap)))
  check('and the reserve leaves room for the full depth',
        cap - math.ceil(cap * 0.05) >= 20000,
        string.format('%d usable of %d', cap - math.ceil(cap * 0.05), cap))

  sdec.trigmode = 'free'
  check('a free-running capture needs no reserve, since nothing is held back',
        sdec.acq_cap(20000) == 20000, tostring(sdec.acq_cap(20000)))

  -- acq_fit: the clamp. A buffer smaller than the request must reduce the request.
  local fake = {capacity = 5000}
  sdec.trigmode = 'free'
  check('a request larger than the buffer is clamped to it',
        sdec.acq_fit(20000, fake) == 5000, tostring(sdec.acq_fit(20000, fake)))
  check('and a request that fits is left alone',
        sdec.acq_fit(1000, fake) == 1000, tostring(sdec.acq_fit(1000, fake)))
  sdec.trigmode = 'edge'
  local fitted = sdec.acq_fit(20000, fake)
  check('on the armed path the clamp also allows for the reserve',
        fitted < 5000 and fitted >= 5000 - math.ceil(5000 * 0.05) - 1,
        string.format('%d of a 5000 buffer', fitted))
  check('a buffer with no readable capacity leaves the request untouched',
        sdec.acq_fit(20000, {}) == 20000, tostring(sdec.acq_fit(20000, {})))

  -- The real acquisition path must now size its buffer with the reserve.
  sdec.trigmode = oldtm
  sdec.pretrig, sdec.n = oldpt, oldn
  clearforce()
end
test_capacity()

-- ===========================================================================
print('\na capture that BEGAN MID-BYTE -- measured on hardware 2026-08-17')
-- ===========================================================================
-- On a continuously busy line the trigger fires wherever it fires, and for the FIRST edge the
-- mark run is bounded only by the start of the capture -- so two bit times of apparent mark is
-- indistinguishable from a run of 1s inside a byte, and the framer can anchor mid-byte. Measured
-- on the instrument: 8E1 at 9600 came out at pitches of 11, 12 and 14.9 bit times ahead of the
-- first idle and exact after it, and a single unflagged frame from that region was enough to make
-- ua_refine_parity call a 7E1 line 8N1 on two runs out of three.
local function test_midbyte()
  clearforce()
  local T, fsr = 8.3333, 100000
  -- TWO messages spliced, so there is a real inter-message idle to find: each render carries 20
  -- bit times of lead and tail, so the junction is 40 bit times of mark -- which is what the
  -- looping arb on the bench presents, and what the instrument measurements were taken against.
  local by, nb = GEN_BYTES('Hello, World!')
  local ra, ta, nca, na = GEN({bytes = by, baud = 9600, fs = fsr, nbits = 8,
                               par = 1, gap = 2, lead = 20, tail = 20})
  local rd, ts, n = {}, {}, 0
  local pass, i
  for pass = 1, 2 do
    for i = 1, na do
      n = n + 1
      rd[n] = ra[i]
      ts[n] = (n - 1) / fsr
    end
  end

  -- A CLEAN capture: nothing is marked, because there is no evidence of misalignment.
  sdec.fs, sdec.acq_fs = fsr, fsr
  sdec.sig_levels(rd, n); sdec.sig_edges(rd, n); sdec.sig_idle(rd, n)
  local ok = sdec.decode_from(rd, n)
  check('a capture that anchored correctly is not marked as misaligned',
        ok and sdec.res ~= nil and sdec.res.headsusp == nil,
        string.format('nf=%s nbad=%s headsusp=%s', tostring(sdec.res and sdec.res.nf),
                      tostring(sdec.res and sdec.res.nbad),
                      tostring(sdec.res and sdec.res.headsusp)))
  check('and it still found the first idle, which is what bounds the head region',
        sdec.res ~= nil and sdec.res.idle1 ~= nil, tostring(sdec.res and sdec.res.idle1))

  -- ua_run's marking rule, exercised directly: errors ahead of the first idle and none after it.
  local r = {nf = 8, ngood = 5, nbad = 3, nfalse = 0, framebits = 11,
             vals = {1, 2, 3, 4, 5, 6, 7, 8}, errs = {}, tpos = {}, idle1 = 4}
  r.errs[1], r.errs[2] = 'parity', 'framing'
  local nh, nt, i = 0, 0, nil
  for i = 1, r.nf do
    if r.errs[i] ~= nil then
      if i < r.idle1 then nh = nh + 1 else nt = nt + 1 end
    end
  end
  check('the marking rule counts head errors and tail errors separately',
        nh == 2 and nt == 0, string.format('head %d tail %d', nh, nt))

  -- THE FORMAT VERDICT. 7E1 data read as 8N1: bit 7 carries even parity of the low 7. One
  -- unflagged dissenting frame at the head must not veto the rest, and the head is only skipped
  -- because ua_run marked it -- unmarked, unanimity still rules.
  local function mkpar(vals, nv, dissent, head)
    local rr = {nf = nv, ngood = nv, nbad = 0, nfalse = 0, nbits = 8, par = sdec.PAR_NONE,
                nstop = 1, framebits = 10, vals = {}, errs = {}, tpos = {}}
    local k
    for k = 1, nv do
      local v = vals[k]
      local pe = math.mod(sdec.ua_popcount(v), 2)
      if pe == 1 then v = v + 128 end
      rr.vals[k] = v
    end
    if dissent ~= nil then rr.vals[dissent] = math.mod(rr.vals[dissent] + 128, 256) end
    rr.headsusp = head
    return rr
  end
  local pv, pn = {}, 0
  for i = 1, 40 do pn = pn + 1; pv[pn] = 32 + math.mod(i * 7, 90) end

  local ra = sdec.ua_refine_parity(mkpar(pv, pn, nil, nil))
  check('a clean 7E1 stream is reclassified from 8N1 to 7E1',
        ra.nbits == 7 and ra.par == sdec.PAR_EVEN,
        string.format('%d bits par=%s', ra.nbits, tostring(ra.par)))

  -- UNANIMITY IS NO LONGER THE GUARD, and the check that used to assert it has been retired
  -- deliberately. It encoded the policy that CAUSED a hardware defect: measured 2026-08-19 with
  -- v78 (7E1, gap = 0), four captures in eight came back as 8N1 with every byte carrying a spurious
  -- bit 7 and NOTHING flagged, because one misaligned frame at the head vetoed a hundred and thirty
  -- agreeing ones. The head is now skipped unconditionally, so a dissenter there cannot vote.
  local rb = sdec.ua_refine_parity(mkpar(pv, pn, 2, nil))
  check('a dissenter in the always-skipped head does NOT veto, with no marking needed',
        rb.nbits == 7 and rb.par == sdec.PAR_EVEN,
        string.format('%d bits par=%s (skiphead %d)', rb.nbits, tostring(rb.par), sdec.par_skiphead))

  local rc = sdec.ua_refine_parity(mkpar(pv, pn, 2, 3))
  check('and a dissenter inside a MARKED misaligned head does not either',
        rc.nbits == 7 and rc.par == sdec.PAR_EVEN,
        string.format('%d bits par=%s', rc.nbits, tostring(rc.par)))

  -- A DISSENTER THAT REALLY VOTED cannot be promoted from a synthetic table, and the reason matters:
  -- stripping bit 7 in place is sound only under unanimity, so any dissent forces a re-decode, which
  -- needs the waveform. Without rd/n/T the honest answer is to stay 8N1. Asserting the verdict alone
  -- would pass for the wrong reason, so the note is checked too.
  local rd2 = sdec.ua_refine_parity(mkpar(pv, pn, 30, 3))
  check('a real dissenter is not promoted in place -- it needs a re-decode, so 8N1 stands',
        rd2.nbits == 8 and rd2.par == sdec.PAR_NONE,
        string.format('%d bits par=%s', rd2.nbits, tostring(rd2.par)))

  -- Almost the whole capture marked: too few votes left to be evidence of anything.
  local re = sdec.ua_refine_parity(mkpar(pv, pn, nil, pn - 2))
  check('and a head that swallowed the capture leaves too few votes to reclassify on',
        re.nbits == 8 and re.par == sdec.PAR_NONE,
        string.format('%d bits par=%s', re.nbits, tostring(re.par)))

  -- THE RESTRICTED-ALPHABET TRAP. ndist >= 3 does not protect: 48 of the 95 printable ASCII
  -- characters have EVEN popcount, so an 8N1 payload drawn only from those carries bit 7 = 0 in
  -- every frame AND even parity 0 in every frame -- perfect apparent 7E1 agreement over as many
  -- distinct values as you like. Requiring BOTH bit-7 states present is what rejects it.
  local ev, nev2 = {}, 0
  local c
  for c = 33, 126 do
    if math.mod(sdec.ua_popcount(c), 2) == 0 then nev2 = nev2 + 1; ev[nev2] = c end
  end
  check('there really are enough even-popcount printable glyphs to build the trap', nev2 >= 20,
        string.format('%d of 94', nev2))
  local rf = sdec.ua_refine_parity(mkpar(ev, nev2, nil, nil))
  check('an 8N1 payload of only even-popcount bytes stays 8N1 -- bit 7 never varies, so it is '
        .. 'not evidence of parity', rf.nbits == 8 and rf.par == sdec.PAR_NONE,
        string.format('%d bits par=%s over %d distinct values', rf.nbits, tostring(rf.par), nev2))
  clearforce()
end
test_midbyte()

-- ===========================================================================
print('\nthe bottom of the rate range -- a probe that cannot frame a byte')
-- ===========================================================================
-- autoset()'s first pass runs at 1 MS/s, where 20 000 samples is 20 ms: six bit times at 300
-- baud. So the probe can measure the bit time and cannot fit a frame, and its refusal used to be
-- returned as the capture's -- "no frame fits a 3333.5 sample bit time", with the answer in the
-- message. Measured on the instrument 2026-08-17: 300 and 600 baud failed outright, 1200 and up
-- were fine, which is why it went unnoticed.
local function test_slow_probe()
  clearforce()
  -- 300 baud sampled at 1 MS/s, cut to 20 000 samples -- what the probe actually captures. That
  -- is six bit times: enough edges to FIT a bit time if the data is transitioning, never enough
  -- for a ten-bit frame. 0x55 back to back is the case that reaches the bit-time stage, which is
  -- the one the fix is about; a window with too few edges to fit anything fails earlier and is
  -- covered by the idle-line check below.
  local rd, ts, nc, n = GEN({bytes = {85, 85, 85}, baud = 300, fs = 1000000,
                             lead = 1, gap = 0, tail = 1})
  local nshort = 20000
  if n < nshort then nshort = n end
  sdec.fs, sdec.acq_fs = 1000000, 1000000
  sdec.sig_levels(rd, nshort); sdec.sig_edges(rd, nshort); sdec.sig_idle(rd, nshort)
  local ok, why = sdec.decode_from(rd, nshort)
  check('a window too short for a frame is still REFUSED -- the retraction is unchanged',
        ok == false and sdec.baud == nil, string.format('%s / baud=%s', tostring(why),
                                                        tostring(sdec.baud)))
  check('but the measured rate survives in baud_probe, for choosing the second pass',
        sdec.baud_probe ~= nil and relnear(sdec.baud_probe, 300, 0.1),
        tostring(sdec.baud_probe))
  local pfs = nil
  if sdec.baud_probe ~= nil then pfs = sdec.pick_fs(sdec.baud_probe, 8) end
  check('and the sample rate it implies oversamples properly, which is the point of re-capturing',
        pfs ~= nil and pfs < 1000000, string.format('%s S/s', tostring(pfs)))

  -- A SUCCESSFUL decode must not leave one behind, or a later failure would inherit it.
  local rd2, ts2, nc2, n2 = GEN({bytes = GEN_BYTES('Hello'), baud = 9600, fs = 100000})
  sdec.fs, sdec.acq_fs = 100000, 100000
  sdec.sig_levels(rd2, n2); sdec.sig_edges(rd2, n2); sdec.sig_idle(rd2, n2)
  local ok2 = sdec.decode_from(rd2, n2)
  check('a successful decode leaves no retracted rate behind', ok2 and sdec.baud_probe == nil,
        tostring(sdec.baud_probe))

  -- A DEAD LINE has no bit time either, so there is nothing to fall back to and the failure
  -- must still be a failure.
  local flat, fts, i = {}, {}, nil
  for i = 1, 4000 do flat[i] = 3.3; fts[i] = (i - 1) * 1e-6 end
  sdec.clear_result()
  sdec.fs, sdec.acq_fs = 1000000, 1000000
  local lok = sdec.sig_levels(flat, 4000)
  local ok3 = sdec.decode_from(flat, 4000)
  check('an idle line still fails with nothing to retry at',
        ok3 == false and sdec.baud_probe == nil,
        string.format('levels=%s probe=%s', tostring(lok), tostring(sdec.baud_probe)))
  clearforce()
end
test_slow_probe()

-- ===========================================================================
print('capture modes -- three modes, the MODE cell, exit-and-flush, idle watchdog')
-- ===========================================================================
-- Three modes on one cycling button, Capture starting all of them, and every way OUT of a
-- mode going through one flush. In a function scope for the 200-local reason above.
local function test_modes()
  clearforce()
  sdec.capmode = 'frame'
  sdec.ck_tot, sdec.ck_nbytes, sdec.ck_running, sdec.ck_stop = nil, nil, false, false
  sdec.allow_rebuild = true
  sdec.start()

  -- ---- the cycle ----
  check('THREE capture modes -- one screenful, or a recording at either window size',
        sdec.ui_modes.n == 3, tostring(sdec.ui_modes.n))
  check('and frame mode logs unconditionally, so the choice is a default not a mode',
        sdec.ui_modes[1].id == 'frame' and sdec.ui_modes[1].log == true)
  -- THE THIRD MODE IS A WINDOW SIZE, NOT THE RETURN OF THE UNCAPPED ONE. 'strm' had no byte
  -- ceiling; both recording modes here have one, and the choice between them is the responsiveness
  -- trade -- 8 kB reaches bytes sooner and credits the device sooner, 32 kB spends less on seams.
  check('there are exactly three modes and no fourth',
        sdec.ui_modes.n == 3 and sdec.ui_modes[4] == nil,
        tostring(sdec.ui_modes.n))
  local seen, i = {}, 0
  for i = 1, 3 do
    seen[i] = sdec.mode_cur().id
    sdec.mode_cycle()
  end
  check('Mode cycles frame -> 8 kB -> 32 kB and WRAPS, so FRAME is never more than two presses',
        seen[1] == 'frame' and seen[2] == 'sml' and seen[3] == 'med'
        and sdec.mode_cur().id == 'frame',
        table.concat(seen, ' -> '))
  check('and EVERY recording mode has a BYTE CEILING -- nothing is uncapped',
        sdec.ui_modes[2].cap == 8192 and sdec.ui_modes[3].cap == 32768,
        string.format('%s / %s', tostring(sdec.ui_modes[2].cap),
                      tostring(sdec.ui_modes[3].cap)))
  check('the two windows differ by 4x, which is what makes the choice worth a press',
        sdec.ui_modes[3].cap == 4 * sdec.ui_modes[2].cap)
  sdec.capmode = 'nonsense'
  check('an unrecognised mode reads as frame rather than nil',
        sdec.mode_cur().id == 'frame', tostring(sdec.mode_cur().id))
  -- The old 'strm' id must not resurrect a mode by the back door either.
  sdec.capmode = 'strm'
  check('the retired strm id falls back to frame rather than half-selecting a gone mode',
        sdec.mode_cur().id == 'frame', tostring(sdec.mode_cur().id))

  -- ---- the MODE cell: the at-a-glance channel ----
  local cols = {}
  for i = 1, 2 do
    sdec.capmode = sdec.ui_modes[i].id
    sdec.ui_refresh()
    cols[i] = MD.obj(sdec.ui_modelab).color
    check('the MODE cell names ' .. sdec.ui_modes[i].name,
          MD.text(sdec.ui_modelab) == sdec.ui_modes[i].name,
          string.format('%q', MD.text(sdec.ui_modelab)))
  end
  check('and each mode has its OWN colour -- colour is read faster than a word',
        cols[1] ~= cols[2] and cols[2] ~= cols[3] and cols[1] ~= cols[3],
        string.format('%s / %s / %s', tostring(cols[1]), tostring(cols[2]),
                      tostring(cols[3])))
  -- The cell must fit its 70 px box: the note value sits at x = 78.
  check('the longest mode name still fits the MODE cell',
        string.len('STREAM') <= 8 and sdec.ui_note_val_x - sdec.ui_note_lab_x >= 60,
        string.format('%d px', sdec.ui_note_val_x - sdec.ui_note_lab_x))

  -- ---- the gate ----
  clearforce()
  sdec.capmode = 'frame'
  check('frame mode needs no locked baud rate', sdec.mode_why() == nil)
  sdec.capmode = 'med'
  check('but 32 kB refuses without one, naming the remedy',
        sdec.mode_why() ~= nil and has(sdec.mode_why(), 'lock the baud rate'),
        tostring(sdec.mode_why()))
  sdec.force_baud = 9600
  check('locking the rate arms it', sdec.mode_why() == nil)
  sdec.force_baud = 0
  check('a forced baud of 0 means auto, so it does not arm streaming',
        sdec.mode_why() ~= nil)
  clearforce()

  -- ---- EXIT AND FLUSH: one path out, and it lands in FRAME ----
  sdec.capmode = 'med'
  sdec.flog_path, sdec.flog_n = '/usb1/frames03.txt', 12
  sdec.ck_tot = {nf = 100, nbad = 0, nwin = 2, nsmp = 1000, path = '/usb1/stream00.txt'}
  local was = sdec.mode_exit('test')
  check('mode_exit returns the mode it left', was == 'med', tostring(was))
  check('and lands in FRAME', sdec.capmode == 'frame', tostring(sdec.capmode))
  check('forgetting the message-log path, so re-entering starts a NEW file',
        sdec.flog_path == nil and sdec.flog_n == nil)
  check('and it SAYS what it did rather than silently going grey',
        sdec.mode_exited ~= nil and has(sdec.mode_exited, '32 kB') and
        has(sdec.mode_exited, 'flushed'), tostring(sdec.mode_exited))
  local nt, nn = sdec.ui_notes()
  check('the exit note reaches the note line',
        has(table.concat(nt, ' | '), 'flushed'), table.concat(nt, ' | '))
  -- Leaving FRAME says nothing: there is nothing to report about staying put.
  sdec.capmode = 'frame'
  sdec.mode_exit('test')
  check('exiting FRAME is silent -- it is already the resting state',
        sdec.mode_exited == nil)

  -- Mode pressed DURING a run is an abort: stop, flush, straight back to FRAME, one press.
  sdec.capmode = 'med'
  sdec.ck_running, sdec.ck_stop = true, false
  sdec.ck_tot = {nf = 389, nbad = 2, nwin = 4, nsmp = 40000, path = '/usb1/bytes044.txt'}
  sdec.ck_nbytes = 389
  sdec.mode_cycle()
  check('Mode during a run ABORTS to FRAME in one press, not to the next mode',
        sdec.capmode == 'frame', tostring(sdec.capmode))
  -- The old assertion here was ck_stop == true -- Mode REQUESTING a stop. It now clears the run
  -- flags outright, because a handler cannot execute while a loop does, so there is no owner to
  -- defer to and a deferred stop is what latched the panel.
  check('...leaving no run flag set, so the next Capture is a capture and not another stop',
        sdec.ck_running == false and sdec.ck_stop == false,
        string.format('running=%s stop=%s', tostring(sdec.ck_running), tostring(sdec.ck_stop)))
  -- The abort path must drop the stream summary as the advance path does. Left set, the status
  -- row keeps the stream's counter and filename, BYTES keeps the stream total, and the note row
  -- calls the next frame capture a prefix of a file that does not contain it.
  check('...and it drops the finished stream summary, exactly as the advance path does',
        sdec.ck_tot == nil and sdec.ck_nbytes == nil,
        string.format('tot=%s nbytes=%s', tostring(sdec.ck_tot), tostring(sdec.ck_nbytes)))
  sdec.ck_running, sdec.ck_stop = false, false

  -- ---- Capture is the one start button, and is Stop while running ----
  clearforce()
  sdec.capmode = 'med'
  local cok = sdec.capture()
  check('Capture in a streaming mode with no locked rate REFUSES, and does not raise',
        cok == false and sdec.lasterr ~= nil and has(sdec.lasterr, 'lock the baud rate'),
        tostring(sdec.lasterr))
  check('and it says refused rather than error -- an unmet precondition is not a fault',
        sdec.ui_status == 'refused', tostring(sdec.ui_status))
  check('a refused stream also LEAVES the streaming mode -- a mode whose precondition is '
        .. 'unmet must not keep offering the same failure', sdec.capmode == 'frame',
        tostring(sdec.capmode))
  -- Re-entered on purpose: the refuse above now lands in FRAME, so the second-press check needs
  -- the mode put back rather than inherited. It used to inherit it, which is why this line did
  -- not exist -- the assertion below was reading a mode the previous scenario happened to leave.
  sdec.capmode = 'med'
  sdec.ck_running, sdec.ck_stop = true, false
  sdec.capture()
  check('a second Capture press during a run requests a STOP and STAYS in the mode',
        sdec.ck_stop == true and sdec.capmode == 'med',
        string.format('stop=%s mode=%s', tostring(sdec.ck_stop), tostring(sdec.capmode)))

  -- ---- AND THE LATCH THAT REQUEST CAN LEAVE BEHIND HAS A WAY OUT ----
  --
  -- ck_running is cleared by the run that owns it. If the run died -- an ABORT over the LAN, an
  -- error escaping a path that is not pcall'd -- the flag survives with nothing to clear it, and
  -- every Capture press lands in the stop branch above. Permanent, and a power cycle to fix.
  --
  -- The evidence that no run exists is the UNANSWERED REQUEST: ck_stop is still set from the
  -- press before, so nothing polled it. That is a measurement, not an assumption.
  sdec.capmode = 'med'
  sdec.ck_running, sdec.ck_stop = true, true
  sdec.ck_job, sdec.strm_recording = nil, nil
  sdec.capture()
  check('a stop request that went UNANSWERED clears the latch instead of repeating itself',
        sdec.ck_running == false,
        string.format('running=%s stop=%s status=%s', tostring(sdec.ck_running),
                      tostring(sdec.ck_stop), tostring(sdec.ui_status)))
  -- On stickyerr, not lasterr: the capture carries on and its own outcome overwrites lasterr
  -- before the operator reads it, so a fault reported there is a fault nobody sees.
  check('...and says why on the channel that outlives the capture',
        sdec.stickyerr ~= nil and has(sdec.stickyerr, 'did not finish'),
        tostring(sdec.stickyerr))

  -- Mode is the documented way out of a run, so it must actually get out. A press cannot be
  -- dispatched while a loop runs, so a handler executing at all proves there is no loop to
  -- defer to -- mode_exit()'s deferral is right from inside a run's unwind and wrong from here.
  clearforce()
  sdec.capmode = 'med'
  sdec.ck_running, sdec.ck_stop = true, false
  sdec.ck_job, sdec.strm_recording = nil, nil
  sdec.mode_cycle()
  check('Mode clears a run flag no run owns, rather than latching the panel into stopping',
        sdec.ck_running == false and sdec.capmode == 'frame',
        string.format('running=%s mode=%s', tostring(sdec.ck_running), tostring(sdec.capmode)))
  sdec.ck_running, sdec.ck_stop = false, false
  -- ---- press-driven streaming: nothing may hold the panel over the budget ----
  --
  -- Capture means START, then STOP, then one DECODE SLICE per press. It has to be shaped this way
  -- rather than looped because a press is never dispatched while a handler runs, so RETURNING is
  -- the only way to answer one. These check the STATE MACHINE; the byte-level behaviour of a
  -- sliced decode is covered by the byte-identity tests in test_chunked().
  do
    local sv = {watch = sdec.ck_watch, stop = sdec.ck_stop, tot = sdec.ck_tot,
                res = sdec.res, mode = sdec.capmode, press = sdec.strm_press,
                running = sdec.ck_running}
    clearforce()
    MD.usb(true); MD.forget_files()
    sdec.force_baud = 9600
    sdec.strm_press = true
    sdec.ck_job, sdec.strm_recording = nil, nil

    sdec.capmode = 'med'
    local ok1 = sdec.capture()
    check('press 1 in a streaming mode STARTS a recording and returns', ok1 == true,
          tostring(sdec.lasterr))
    check('and says so, rather than reporting a finished capture',
          has(sdec.ui_status, 'recording'), tostring(sdec.ui_status))
    check('the recording is live in HARDWARE, with no Lua loop to protect the panel from',
          sdec.strm_recording == true)

    sdec.capture()
    check('press 2 STOPS the recording', sdec.strm_recording == nil)
    local stepped = 0
    while sdec.ck_job ~= nil and stepped < 300 do
      sdec.capture()
      stepped = stepped + 1
    end
    check('any decode completes in a BOUNDED number of slices -- no runaway',
          sdec.ck_job == nil, string.format('%d slices', stepped))
    check('and the run ends back in FRAME', sdec.capmode == 'frame',
          tostring(sdec.capmode))

    -- Mode pressed mid-decode must close the partial file rather than strand the handle.
    sdec.capmode = 'med'
    sdec.ck_job, sdec.strm_recording = nil, nil
    sdec.capture()
    check('a recording is live again before the exit', sdec.strm_recording == true,
          tostring(sdec.lasterr))
    sdec.mode_exit('test')
    check('leaving the mode STOPS a live recording', sdec.strm_recording == nil)
    check('and releases any decode job rather than stranding its file handle',
          sdec.ck_job == nil)

    -- decode_abandon is safe with nothing to abandon, since mode_exit calls it unconditionally.
    check('abandoning with no job is a no-op, not a raise', sdec.decode_abandon() == false)

    sdec.strm_press = sv.press
    sdec.ck_watch, sdec.ck_stop, sdec.ck_tot = sv.watch, sv.stop, sv.tot
    sdec.res, sdec.capmode, sdec.ck_running = sv.res, sv.mode, sv.running
    sdec.ck_job, sdec.strm_recording = nil, nil
    clearforce()
  end

  check('the stop travels through the progress hook', sdec.ck_progress(10, 1, 5) == true)
  sdec.ck_stop = true
  check('and ck_progress returns false once Stop is pending',
        sdec.ck_progress(10, 1, 5) == false)
  sdec.ck_stop, sdec.ck_running = false, false

  -- ---- the idle watchdog: pure logic, so it is testable with no instrument ----
  sdec.thr, sdec.hyst = 1.65, 0.5
  local quiet, k = {}, 0
  for k = 1, 500 do quiet[k] = 3.3 end
  check('a line held at the mark level is NOT active',
        sdec.smp_active(quiet, 500, 1.65, 0.5) == false)
  for k = 1, 500 do quiet[k] = 0 end
  check('nor is one held at the space level -- idle is a level, not a value',
        sdec.smp_active(quiet, 500, 1.65, 0.5) == false)
  -- Noise around the threshold must not count, which is what the hysteresis is for.
  for k = 1, 500 do quiet[k] = 1.65 + 0.4 * math.sin(k) end
  check('noise INSIDE the hysteresis band is not activity',
        sdec.smp_active(quiet, 500, 1.65, 0.5) == false)
  local busy = {}
  for k = 1, 500 do busy[k] = 3.3 end
  busy[250] = 0
  check('but one sample crossing past the band IS activity',
        sdec.smp_active(busy, 500, 1.65, 0.5) == true)
  -- A real byte anywhere in the window trips it.
  local brd, bts, bnc, bn = GEN({bytes = {0x55}, baud = 9600, fs = 100000, lead = 5,
                                 tail = 5})
  check('a single byte in the window is activity',
        sdec.smp_active(brd, bn, 1.65, 0.5) == true)
  check('the idle window is a tenth of a second of signal, clamped',
        sdec.idle_window(100000) == 4000 and sdec.idle_window(1000) == 200 and
        sdec.idle_window(nil) == 2000,
        string.format('%d / %d', sdec.idle_window(100000), sdec.idle_window(1000)))

  -- A quiet line ends the run AND leaves the mode; a full buffer ends the run and STAYS.
  -- That distinction is the design, so it is asserted rather than left to the comment.
  clearforce()
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.ck_endwhy, sdec.ck_running = 'full', false
  sdec.mode_exited = nil
  check('a mode that reached the cap has idlexit set but does not exit on its own',
        sdec.mode_cur().idlexit == true and sdec.capmode == 'med')
  check('frame mode never idle-exits -- it is already the resting state',
        sdec.ui_modes[1].idlexit == nil)
  check('the idle timeout is configurable and defaults to something usable',
        sdec.idle_exit_s ~= nil and sdec.idle_exit_s > 0 and sdec.idle_exit_s <= 60,
        tostring(sdec.idle_exit_s))
  -- stream_maxwait is the belt-and-braces ceiling for the case buf.n never advances.
  check('the acquisition has a hard wait ceiling independent of the watchdog',
        sdec.stream_maxwait(2800000, 100000) == 56 and
        sdec.stream_maxwait(1000, 100000) == 10,
        string.format('%s / %s', tostring(sdec.stream_maxwait(2800000, 100000)),
                      tostring(sdec.stream_maxwait(1000, 100000))))

  -- ---- NewLog ----
  MD.usb(true)
  MD.forget_files()
  clearforce()
  sdec.capmode = 'frame'
  sdec.flog_path, sdec.flog_n = nil, nil
  local r = run({bytes = hb, baud = 9600, fs = 100000})
  check('frame_log writes a message file and names it',
        sdec.frame_log() == true and has(tostring(sdec.flog_path), sdec.flogpfx),
        tostring(sdec.flog_path))
  local first = sdec.flog_path
  sdec.frame_log()
  check('a second capture APPENDS to the same file rather than opening a new one',
        sdec.flog_path == first and sdec.flog_n == 2,
        string.format('%s n=%s', tostring(sdec.flog_path), tostring(sdec.flog_n)))
  sdec.log_new()
  check('NewLog forgets the path, so the next capture starts a new file',
        sdec.flog_path == nil and sdec.flog_n == nil)
  check('and it SAYS so -- a control whose only evidence appears next capture gets pressed twice',
        sdec.lognote ~= nil and has(sdec.lognote, 'bytes000.txt'), tostring(sdec.lognote))
  check('the NewLog note reaches the note line',
        has(table.concat(sdec.ui_notes(), ' | '), 'next capture starts a new file'),
        table.concat(sdec.ui_notes(), ' | '))
  sdec.frame_log()
  check('the new file is a DIFFERENT name',
        sdec.flog_path ~= nil and sdec.flog_path ~= first,
        string.format('%s vs %s', tostring(sdec.flog_path), tostring(first)))
  local body = MD.logtext()
  check('the log holds decoded bytes as text AND hex -- and NO samples',
        has(body, 'Hello, World!') and has(body, '48 65 6C 6C') and
        not has(body, 'e+') and not has(body, '3.3000'), string.sub(body, 1, 70))
  -- The right-hand status cell carries the message log in frame mode, the controls while
  -- streaming: both do not fit, and while streaming the way out matters more.
  sdec.ui_refresh()
  sdec.ck_tot, sdec.ck_running = nil, false
  sdec.ui_refresh()
  -- The cell must name the FILE and show the BYTE total -- both, because 'no byte is lost' is
  -- a promise and this cell is the only place it is visible.
  check('FRAME shows the byte log: filename AND byte count',
        has(MD.text(sdec.ui_log_t) or '', 'log:') and
        has(MD.text(sdec.ui_log_t) or '', 'bytes') and
        has(MD.text(sdec.ui_log_t) or '', ' B'),
        string.format('%q', MD.text(sdec.ui_log_t)))
  sdec.capmode = 'med'
  sdec.force_baud = 9600
  sdec.ck_running = true
  sdec.ui_refresh()
  -- IT NAMES NO CONTROL, BECAUSE THERE IS NONE. This asserted 'TRIGGER key = stop' on the strength of
  -- cancel_setup()'s blender latch. MEASURED FALSE 2026-08-18 on the instrument: pressed 20 % into a
  -- 32 kB decode the run still finished 'full' and the latch was EMPTY, so the key's event does not
  -- reach the blender while a panel-initiated run executes. A touch press cannot act either -- presses
  -- queue. Advertising either one is the defect class this whole suite exists to catch, so the cell
  -- must promise nothing and the duration lives on the note line.
  check('a running stream promises NO control, because none can act',
        not has(MD.text(sdec.ui_log_t), 'TRIGGER')
        and not has(MD.text(sdec.ui_log_t), 'Capture=')
        and not has(MD.text(sdec.ui_log_t), 'Mode='),
        tostring(MD.text(sdec.ui_log_t)))
  check('...and says instead that it runs to its own end',
        has(MD.text(sdec.ui_log_t), 'no stop'), tostring(MD.text(sdec.ui_log_t)))
  sdec.ck_running = false
  MD.usb(false)
  sdec.flog_path = nil
  check('no USB key makes frame_log a no-op rather than a raise',
        sdec.frame_log() == false)
  MD.usb(true)

  -- ---- Auto Detect: the inverse of Lock Detected ----
  clearforce()
  sdec.force_baud, sdec.force_nbits, sdec.force_par = 19200, 7, 1
  sdec.capmode = 'med'
  SRC.rd, SRC.ts, SRC.nsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
  sdec.options_auto()
  -- CLEARS THEM AND THEN RE-DERIVES THEM, which is the contract the button's name implies:
  -- 'Auto Detect' means "work it out and use it", so the capture it triggers is allowed to lock
  -- what it finds. It used to defer the lock, which left the panel amber at the top sample rate
  -- with a 19-byte window -- a press that made things worse, with the good outcome one press
  -- away and nothing saying so.
  --
  -- So the assertion is not "nothing is forced afterwards" but "nothing STALE is": the values
  -- now present were derived from a fresh capture, not carried over from the old lock.
  check('Auto Detect re-derives the wire settings from a fresh capture',
        sdec.force_baud == sdec.baud and sdec.force_nbits == (sdec.res and sdec.res.nbits),
        string.format('forced=%s/%s decoded=%s/%s', tostring(sdec.force_baud),
                      tostring(sdec.force_nbits), tostring(sdec.baud),
                      tostring(sdec.res and sdec.res.nbits)))
  check('and it leaves a streaming mode, since it just removed what armed it',
        sdec.capmode == 'frame', tostring(sdec.capmode))

  -- ---- a FRAME capture takes the panel back off the last stream ----
  -- A stream that ends BY ITSELF keeps its summary on purpose: the bytes are still on screen and
  -- the summary is the result. The next FRAME capture replaces those bytes, and from that moment
  -- the summary describes nothing on the panel -- so the frame path drops it. Without this the
  -- status row advertises a stopped stream, BYTES reads the stream total over a shorter dump, and
  -- the note row calls the dump a prefix of a file that does not hold it.
  do
    clearforce()
    sdec.capmode = 'frame'
    sdec.ck_tot = {nf = 389, nbad = 2, nwin = 4, nsmp = 40000, path = '/usb1/bytes044.txt'}
    sdec.ck_nbytes = 389
    sdec.ck_running = false
    -- Through sdec.capture(), not the run() helper: the clear lives on capture()'s frame path,
    -- which is the whole point -- run() drives the signal chain directly and would skip it.
    SRC.rd, SRC.ts, SRC.nsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
    sdec.capture()
    check('a frame capture clears the previous stream summary',
          sdec.ck_tot == nil and sdec.ck_nbytes == nil,
          string.format('tot=%s nbytes=%s', tostring(sdec.ck_tot), tostring(sdec.ck_nbytes)))
    local fv = sdec.ui_field_values()
    check('...so BYTES is this capture, not the stream total',
          fv[8] == tostring(sdec.res.nf), string.format('%s vs nf=%s', fv[8],
          tostring(sdec.res.nf)))
    local nt2, nn2 = sdec.ui_notes()
    check('...and no note claims the dump is a slice of the stream file',
          not has(table.concat(nt2, ' | '), 'bytes044.txt'), table.concat(nt2, ' | '))
  end

  -- ---- the header field the modes made necessary ----
  clearforce()
  r = run({bytes = hb, baud = 9600, fs = 100000})
  sdec.capmode = 'frame'
  sdec.ck_tot, sdec.ck_running, sdec.ck_nbytes = nil, false, nil
  local fv = sdec.ui_field_values()
  check('in frame mode BYTES is the capture', fv[8] == tostring(sdec.res.nf), fv[8])
  sdec.capmode = 'med'
  sdec.force_baud = 9600
  sdec.ck_running = false
  sdec.ck_tot = {nf = 32768, nbad = 3, nwin = 143, nsmp = 2764800,
                 stopped = 'cap', path = '/usb1/stream00.txt'}
  fv = sdec.ui_field_values()
  check('in a streaming mode BYTES is the STREAM total, not the primed window',
        fv[8] == '32768' and fv[9] == '3',
        string.format('bytes=%s err=%s (window was %d)', fv[8], fv[9], sdec.res.nf))
  -- Recording has decoded nothing, so the honest value is dashes, not a green zero.
  sdec.ck_running, sdec.ck_nbytes = true, nil
  fv = sdec.ui_field_values()
  check('while RECORDING it is -- , not 0: an unknown must not read as a result',
        fv[8] == '--' and fv[9] == '--', string.format('bytes=%s err=%s', fv[8], fv[9]))
  sdec.ck_nbytes = 12480
  fv = sdec.ui_field_values()
  check('and once DECODING starts it is the live count',
        fv[8] == '12480', fv[8])
  sdec.ck_running = false
  -- EVERY HEADER CELL FITS ITS LABEL AND ITS WIDEST VALUE, at that cell's own font.
  --
  -- This replaced a single assertion that the BYTES column was >= 84 px, whose number came
  -- from an estimate rather than a measurement -- and which said nothing about the other nine
  -- columns, one of which (FORMAT) was overflowing its divider on the real panel while this
  -- test passed. The advances are measured: uppercase 9.67 px worst case, digits and
  -- mixed-case 7.80, FONT_MEDIUM ~14. `wid` names the widest value each cell must hold, so
  -- this is a worst-case check and not a check of whatever is on screen right now.
  do
    local bad, nb = {}, 0
    local j
    for j = 1, table.getn(sdec.ui_fields) do
      local f = sdec.ui_fields[j]
      local adv = sdec.ui_adv_mixed
      if f.med then adv = 14 end
      -- A value containing an uppercase letter is as wide as a label.
      if f.wid ~= nil and string.find(f.wid, '%u') and not f.med then
        adv = sdec.ui_adv_upper
      end
      local vw = string.len(f.wid or '') * adv
      local lw = string.len(f.lab) * sdec.ui_adv_upper
      local need = vw
      if lw > need then need = lw end
      -- The divider before the next field sits at its x - 9; the last cell runs to the
      -- table's right rule.
      local lim = sdec.ui_rule_x1
      if j < table.getn(sdec.ui_fields) then lim = sdec.ui_fields[j + 1].x - 9 end
      if f.x + need > lim then
        nb = nb + 1
        bad[nb] = string.format('%s needs %d px to %d, divider at %d',
                                f.lab, need, f.x + need, lim)
      end
    end
    check('every header cell fits its label and its widest value', nb == 0,
          nb == 0 and 'all 10 clear' or table.concat(bad, ' | '))
  end

  -- ---- the three cells a stream DOES know ----
  --
  -- A streaming mode hands back a file rather than an sdec.res, so every cell derived from res
  -- read '--' for the whole run. For the MEASURED cells that is right -- nothing has been fitted.
  -- For BAUD, FORMAT and IDLE it was wrong: a streaming mode cannot be entered without a locked
  -- rate, so those three are the only things about a stream that are certain, and the panel was
  -- disclaiming knowledge the operator had pinned themselves while the app was actively using it.
  do
    -- Save and restore: this block deliberately clears the lock to check the '--' case, and the
    -- tests after it are mid-scenario with a locked rate. Leaking cleared state out of here made
    -- the NEXT check see "lock the baud rate in Options" instead of its own note.
    local sv1, sv2 = sdec.force_baud, sdec.force_nbits
    local sv3, sv4, sv5 = sdec.force_par, sdec.force_nstop, sdec.force_invert
    -- sdec.res too: clearing it is the whole point here (a stream has no decode result), and the
    -- checks after this block are mid-scenario and derive their note from one.
    local svres, svbaud, svsnap = sdec.res, sdec.baud, sdec.snapped
    sdec.clear_result()          -- no decode result, exactly as during a stream
    sdec.force_baud, sdec.force_nbits = 4800, 8
    sdec.force_par, sdec.force_nstop, sdec.force_invert = sdec.PAR_NONE, 1, false
    local fv = sdec.ui_field_values()
    check('a stream shows the LOCKED baud rather than --', fv[1] == '4800', fv[1])
    check('...and the locked format', fv[2] == '8N1', fv[2])
    check('...and the locked polarity', fv[3] == 'HIGH', fv[3])
    check('...while the MEASURED cells still say -- , because nothing was fitted',
          fv[5] == '--' and fv[6] == '--',
          string.format('thresh=%s sa/bit=%s', fv[5], fv[6]))
    check('and baud_text/fmt_text agree, so notes and logs match the header',
          has(sdec.baud_text(), '4800') and sdec.fmt_text() == '8N1',
          string.format('%q / %q', sdec.baud_text(), sdec.fmt_text()))
    -- An inverted lock must show LOW, or the fallback is only half wired.
    sdec.force_invert = true
    check('...and an inverted locked line shows LOW',
          sdec.ui_field_values()[3] == 'LOW', sdec.ui_field_values()[3])
    clearforce()
    check('with nothing locked and nothing decoded they go back to --',
          sdec.ui_field_values()[1] == '--' and sdec.ui_field_values()[2] == '--',
          string.format('%s / %s', sdec.ui_field_values()[1],
                        sdec.ui_field_values()[2]))
    sdec.force_baud, sdec.force_nbits = sv1, sv2
    sdec.force_par, sdec.force_nstop, sdec.force_invert = sv3, sv4, sv5
    sdec.res, sdec.baud, sdec.snapped = svres, svbaud, svsnap
  end

  -- ---- the streaming notes and the short status row ----
  nt, nn = sdec.ui_notes()
  check('a finished stream SAYS the panel shows only the first window',
        has(table.concat(nt, ' | '), 'panel shows the first'), table.concat(nt, ' | '))

  -- A RETAINED TAIL IS NOT A PREFIX, and the note used to call it one: a recording ends with
  -- sdec.res = ck_tot.tail -- the LAST ck_keep bytes -- while this line said 'the first 8192 bytes'
  -- and the index column beside it counted from 24576. Two cells contradicting each other about
  -- which end of the stream is on screen.
  do
    local svres, svtot = sdec.res, sdec.ck_tot
    sdec.res = {nf = 8192, ngood = 8192, nbad = 0, vals = {}, errs = {},
                first = 24577, ntotal = 32768}
    sdec.ck_tot = {nf = 32768, nbad = 0, nwin = 1, nsmp = 1, path = '/usb1/stream00.txt'}
    local tnt = table.concat(sdec.ui_notes(), ' | ')
    check('a retained TAIL names the byte range it is showing',
          has(tnt, 'bytes 24577-32768 of 32768'), tnt)
    check('...and does NOT claim to be the first bytes of the stream',
          not has(tnt, 'panel shows the first'), tnt)
    check('...and still names the file holding all of them',
          has(tnt, 'stream00.txt'), tnt)
    sdec.res, sdec.ck_tot = svres, svtot
  end
  sdec.ck_tot = nil
  clearforce()
  sdec.capmode = 'med'
  sdec.ui_refresh()
  local strow = MD.text(sdec.ui_page_t) or ''
  check('an unarmed recording mode says so on the note line, with the remedy',
        has(table.concat(sdec.ui_notes(), ' | '), 'lock the baud rate'))
  check('the status row stays short and defers to the note',
        has(strow, 'not armed') and not has(strow, 'lock the baud rate') and
        string.len(strow) < 40, string.format('%q', strow))
  check('and shows no page/of counters -- there is no view',
        not has(strow, 'page'), string.format('%q', strow))

  -- ---- one wrapping Page button ----
  clearforce()
  r = run({bytes = GEN_BYTES(string.rep('abcdefghij', 30)), baud = 9600, fs = 100000})
  sdec.capmode = 'frame'
  sdec.ui_mode = 'hex'
  sdec.ui_page = 0
  local npg = sdec.ui_npages()
  check('a 300-byte capture needs more than one hex page', npg > 1, tostring(npg))
  local pages = {}
  for i = 1, npg + 1 do
    pages[i] = sdec.ui_page
    sdec.page_cycle()
  end
  check('Page advances through every page and WRAPS to the first',
        pages[1] == 0 and pages[npg] == npg - 1 and sdec.ui_page == 1,
        table.concat(pages, ','))
  sdec.clear_result()
  sdec.ui_page = 5
  sdec.page_cycle()
  check('Page on an empty capture lands on page 0 rather than raising',
        sdec.ui_page == 0, tostring(sdec.ui_page))

  -- ---- the streaming mode is CHOSEN FROM THE LOCKED RATE, not by the operator ----
  -- Below sdec.strm_maxbaud a continuous run is possible, and it is unlimited AND lossless, so
  -- 32 kB is strictly worse there and the cycle must not offer it. Above the ceiling continuous
  -- cannot keep up and STREAM must not be offered. The point is that at any given rate the Mode
  -- button walks TWO modes, never three, and never parks on the wrong answer.
  local function cycled()
    sdec.capmode = 'frame'
    local seen, k = {}, nil
    for k = 1, 3 do sdec.mode_cycle(); seen[k] = sdec.mode_cur().name end
    return table.concat(seen, ' ')
  end
  clearforce()
  -- BOTH RECORDING MODES, OFFERED AT EVERY RATE. Modes were once chosen for the operator either
  -- side of strm_maxbaud, and a block here checked that boundary from both directions. Nothing is
  -- rate-dependent now -- the two windows differ only in size, and both work at every locked rate --
  -- so what is left to assert is that the cycle is identical everywhere, which is the point.
  check('with nothing locked both recording windows are reachable -- the gate is at Capture',
        cycled() == '8 kB 32 kB FRAME', cycled())
  sdec.force_baud = 300
  check('...and at the slowest rate', cycled() == '8 kB 32 kB FRAME', cycled())
  sdec.force_baud = 4800
  check('...and at the old ceiling, which no longer means anything',
        cycled() == '8 kB 32 kB FRAME', cycled())
  sdec.force_baud = 115200
  check('...and at a fast rate', cycled() == '8 kB 32 kB FRAME', cycled())
  check('mode_for_rate names a recording mode at any rate, and nil with nothing locked',
        (function()
           sdec.force_baud = 300;    local a = sdec.mode_for_rate()
           sdec.force_baud = 115200; local b = sdec.mode_for_rate()
           sdec.force_baud = nil;    local c = sdec.mode_for_rate()
           return a == 'med' and b == 'med' and c == nil
         end)())
  clearforce()
  sdec.capmode = 'frame'

  -- ---- the button bar ----
  local nb, ends = 0, 0
  for i = 1, MD.nobj() do
    local o = MD.obj(i)
    if o ~= nil and o.kind == display.OBJ_BUTTON and o.parent == sdec.ui_scr then
      nb = nb + 1
      local right = o.x + (o.w or 0)
      if right > ends then ends = right end
    end
  end
  -- SIX, not seven. Page is gone: a 14-row hex page holds 224 bytes, which is the whole frame at
  -- every snapped baud, so there is only ever one page to be on in the hex and text views.
  -- EIGHT now: the six along the bottom plus Page Up and Page Dn in the dump area's right
  -- margin. Paging had NO control at all after the wrapping `Page` button was dropped -- fine
  -- for FRAME mode's single 240-byte page, and wrong for a 32 kB streaming capture, which is
  -- 137 pages of which only the first was reachable. The margin came free when the position
  -- bar was removed.
  -- NINE: six along the bottom, plus Page Up / Lock Rate / Page Dn down the right margin.
  check('NINE buttons: six along the bottom plus Page Up / Lock Rate / Page Dn', nb == 9,
        tostring(nb))
  -- EVERY BUTTON LABEL MUST FIT ITS FACE, on both screens.
  --
  -- Measured on the panel 2026-08-16: a face needs len * 14 + 8 px to render its label uncut.
  -- Two shipped clipped -- 'Save USB' showed as 'Save USI' at 112 px, and 'Lock Detected' at
  -- 150 px ran across the button beside it. The rule reproduces both, and reproduces 'Options'
  -- (7 chars at 112) just fitting, so it is calibrated rather than guessed.
  do
    local bad, nbb = {}, 0
    local function fits(h)
      local o = MD.obj(h)
      if o == nil or o.text == nil or o.w == nil then return end
      local need = string.len(o.text) * (sdec.ui_adv_btn or 14) + 8
      if need > o.w then
        nbb = nbb + 1
        bad[nbb] = string.format('%q needs %d px, face is %d', o.text, need, o.w)
      end
    end
    local bi
    for bi = 1, table.getn(sdec.ui_btn or {}) do fits(sdec.ui_btn[bi]) end
    for bi = 1, table.getn(sdec.opt_btn or {}) do fits(sdec.opt_btn[bi]) end
    check('every button label fits its face on both screens', nbb == 0,
          nbb == 0 and 'all clear' or table.concat(bad, ' | '))
  end
  -- AND EVERY OPTION-FIELD ENTRY MUST FIT ITS VALUE COLUMN.
  --
  -- An OBJ_EDIT_OPTION value too long for the column is NOT clipped at the box edge: the firmware
  -- fades the tail out and stops. Four 14-character entries shipped faded -- 'Normal idle hi'
  -- read 'Normal idle', and 'Trig In+FC Out' read 'Trig In+FC', which is not distinguishable from
  -- the 'Trig In' entry above it in the same field.
  --
  -- WEIGHED, NOT COUNTED. A count says 'TRIGGER key' and 'In + FC Out' are the same size; on the
  -- panel the first fades and the second does not, because seven of its letters are uppercase.
  do
    local bad, nof = {}, 0
    local fields = {sdec.opt_proto, sdec.opt_baud, sdec.opt_bits, sdec.opt_par,
                    sdec.opt_pol, sdec.opt_trig, sdec.opt_ext}
    local fi, q
    for fi = 1, table.getn(fields) do
      local o = MD.obj(fields[fi])
      if o ~= nil and o.opts ~= nil then
        for q = 1, (o.nopts or 0) do
          local e = o.opts[q]
          if e ~= nil and sdec.ui_optw(e) > sdec.ui_opt_px then
            nof = nof + 1
            bad[nof] = string.format('%q needs %d px of %d', e, sdec.ui_optw(e),
                                     sdec.ui_opt_px)
          end
        end
      end
    end
    check('every option-field entry fits the value column without fading out', nof == 0,
          nof == 0 and 'all clear' or table.concat(bad, ' | '))
  end
  -- page_cycle() still EXISTS and is still correct -- it is only unbound from the bar. The MIDI
  -- and LIN views are one message per row and can still exceed 14 rows, so if the bench says the
  -- protocol views need scrolling, the handler is already there and only a button is missing.
  check('page_cycle survives the button removal, so paging can be restored',
        type(sdec.page_cycle) == 'function' and sdec.ui_npages() >= 1,
        tostring(sdec.ui_npages()))
  check('and the row ends inside the 798 px limit with room to spare',
        ends <= 798 and ends >= 700, string.format('ends at %d', ends))
  -- Every event string must resolve, including the two new ones.
  check('log_new and options_auto exist and are bound',
        type(sdec.log_new) == 'function' and type(sdec.options_auto) == 'function' and
        type(sdec.mode_cycle) == 'function' and type(sdec.page_cycle) == 'function')

  -- ---- the MAX for the current mode is stated, not discovered ----
  -- Frame mode shows its WINDOW in the status row -- the number that answers "was the message
  -- seen whole?" -- and it moves with the sample rate, so it is shown continuously rather than
  -- only once the capture is full (which is all the capture-FULL note ever did).
  clearforce()
  sdec.capmode = 'frame'
  r = run({bytes = hb, baud = 9600, fs = 100000})
  sdec.ui_refresh()
  local srow = MD.text(sdec.ui_page_t) or ''
  local wb = sdec.window_bytes(sdec.baud, 8, sdec.PAR_NONE, 1)
  check('frame mode states the WINDOW capacity, not just the byte count',
        has(srow, 'win ' .. tostring(wb)) and wb > 0,
        string.format('%q (window %s)', srow, tostring(wb)))
  -- And the streaming modes state their cap before the capture rather than after.
  sdec.force_baud = 9600
  sdec.capmode = 'med'
  sdec.ck_tot, sdec.ck_running = nil, false
  check('32 kB states its cap while armed',
        has(sdec.ck_status(), 'max 32768'), sdec.ck_status())
  -- THE 'no cap' CASE IS GONE WITH THE MODE. This used to set capmode = 'strm' and assert that
  -- ck_status() said 'no cap'. That assertion still PASSED after the mode was removed -- capmode
  -- 'strm' falls back to FRAME, whose cap is also nil -- so it was testing the fallback, not a
  -- recording mode, and it would have hidden exactly the removal residue it should have caught.
  -- What is worth pinning instead is that the surviving mode states a NUMBER.
  sdec.capmode = 'med'
  check('...and it is a real byte count, not a vague promise',
        has(sdec.ck_status(), '32768') and not has(sdec.ck_status(), 'no cap'),
        sdec.ck_status())
  -- The status band is boxed, so it reads as state rather than as more dump.
  check('the status row is boxed off from the dump area',
        sdec.ui_stat_top < sdec.ui_stat_y and sdec.ui_stat_bot > sdec.ui_stat_y and
        sdec.ui_stat_bot < sdec.ui_btn_y,
        string.format('%d < %d < %d, buttons at %d', sdec.ui_stat_top, sdec.ui_stat_y,
                      sdec.ui_stat_bot, sdec.ui_btn_y))
  -- THE PAGE TEXT MUST FIT ITS CELL, expressed against the objects rather than as a
  -- magic window around whatever the divider happened to be. The old form asserted
  -- 400 < stat_div < 430, which said nothing about whether anything fitted -- and it
  -- passed while the page string outgrew the cell and rendered straight through the log
  -- field, so the panel showed 'win 240  [donkg: bytes000.txt': two overlapping strings.
  check('and its divider sits between the page cell and the trigger cell',
        sdec.ui_stat_div > sdec.ui_x and sdec.ui_stat_div < sdec.ui_trig_div,
        string.format('%d < %d < %d', sdec.ui_x, sdec.ui_stat_div,
                      sdec.ui_trig_div))
  check('...and the page text actually FITS between them',
        (function()
           local t = MD.text(sdec.ui_page_t) or ''
           local w = string.len(t) * (sdec.ui_ch_w or 8)
           return sdec.ui_x + w <= sdec.ui_stat_div
         end)(),
        (function()
           local t = MD.text(sdec.ui_page_t) or ''
           return string.format('%d chars = %d px from %d, ends %d, divider %d',
                                string.len(t), string.len(t) * (sdec.ui_ch_w or 8),
                                sdec.ui_x, sdec.ui_x + string.len(t)
                                * (sdec.ui_ch_w or 8), sdec.ui_stat_div)
         end)())
  check('...and the log text fits before the trigger divider',
        (function()
           local t = MD.text(sdec.ui_log_t) or ''
           local w = string.len(t) * (sdec.ui_ch_w or 8)
           return sdec.ui_stat_div + 6 + w <= sdec.ui_trig_div
         end)(),
        string.format('%q', string.sub(MD.text(sdec.ui_log_t) or '', 1, 30)))
  clearforce()
  sdec.capmode = 'frame'

  -- ---- the trigger source is VISIBLE, by exception ----
  clearforce()
  sdec.capmode = 'frame'
  sdec.trigext, sdec.trigmode = false, 'edge'
  r = run({bytes = hb, baud = 9600, fs = 100000})
  sdec.ui_refresh()
  check('the DEFAULT trigger says nothing -- an always-present marker is not a marker',
        not has(MD.text(sdec.ui_log_t) or '', 'TRIG') and
        not has(MD.text(sdec.ui_log_t) or '', 'free run'),
        string.format('%q', MD.text(sdec.ui_log_t)))
  sdec.trigext = true
  sdec.ui_refresh()
  -- ITS OWN CELL, in the status band -- not prefixed onto the log, which put two unrelated
  -- facts in one box. GREEN = armed and in force, AMBER = off or ignored.
  check('the external trigger has its own boxed cell',
        sdec.ui_trig_t ~= nil and sdec.ui_trig_div > sdec.ui_stat_div and
        sdec.ui_trig_x > sdec.ui_trig_div,
        string.format('div %d, x %d', sdec.ui_trig_div, sdec.ui_trig_x))
  check('armed and in force reads GREEN',
        has(MD.text(sdec.ui_trig_t) or '', 'EXT TRIG') and
        MD.obj(sdec.ui_trig_t).color == sdec.ui_c_locked,
        string.format('%q 0x%06X', MD.text(sdec.ui_trig_t),
                      MD.obj(sdec.ui_trig_t).color))
  sdec.trigmode = 'free'
  sdec.ui_refresh()
  check('ticked but IGNORED under free run reads amber and says ignored',
        has(MD.text(sdec.ui_trig_t) or '', 'ignored') and
        MD.obj(sdec.ui_trig_t).color == sdec.ui_c_warn,
        string.format('%q', MD.text(sdec.ui_trig_t)))
  check('and the note says so, which the code claimed but never did',
        has(table.concat(sdec.ui_notes(), ' | '), 'ticked but IGNORED'),
        table.concat(sdec.ui_notes(), ' | '))
  sdec.trigext, sdec.trigmode = false, 'edge'
  sdec.ui_refresh()
  check('off reads amber too -- off and ignored are the same to the operator',
        MD.obj(sdec.ui_trig_t).color == sdec.ui_c_warn)
  -- And it is a control, wired the same speculative way as the padlock.
  sdec.trigext_toggle()
  check('tapping the cell toggles the external trigger', sdec.trigext == true)
  sdec.trigext_toggle()
  check('and toggles it back, saying so each time',
        sdec.trigext == false and sdec.lognote ~= nil and has(sdec.lognote, 'OFF'),
        tostring(sdec.lognote))

  -- ---- the padlock: lock state, its three colours, and its action ----
  clearforce()
  sdec.clear_result()
  check('with nothing decoded the padlock is RED -- there is nothing to lock',
        sdec.lock_state() == 'unknown' and sdec.lock_colour() == sdec.ui_c_unknown,
        sdec.lock_state())
  r = run({bytes = hb, baud = 9600, fs = 100000})
  check('after an auto decode it is AMBER -- the app worked it out',
        sdec.lock_state() == 'auto' and sdec.lock_colour() == sdec.ui_c_auto,
        sdec.lock_state())
  sdec.lock_toggle()
  check('and one press LOCKS what was detected, turning it green',
        sdec.lock_state() == 'locked' and sdec.lock_colour() == sdec.ui_c_locked and
        sdec.force_baud == 9600 and sdec.force_nbits == 8,
        string.format('%s baud=%s bits=%s', sdec.lock_state(), tostring(sdec.force_baud),
                      tostring(sdec.force_nbits)))
  check('it says what it locked, on the note line',
        sdec.lognote ~= nil and has(sdec.lognote, '9600') and
        has(sdec.lognote, 'locked') and
        has(table.concat(sdec.ui_notes(), ' | '), 'locked 9600'),
        tostring(sdec.lognote))

  -- ---- and the BUTTON that does it has to appear and disappear with those states ----
  -- The three checks above test the STATE MACHINE. Nothing tested the button's VISIBILITY, and that
  -- gap shipped a defect: ui_build() assigned sdec.ui_lockbtn and then cleared it three lines later
  -- among two visibility caches, so the guard `if sdec.ui_lockbtn ~= nil` made the whole
  -- show/hide block dead code. Lock Rate stayed on the glass with the rate already locked --
  -- offering exactly the unlocking press its own comment forbids. It took a pixel measurement on
  -- the bench to see it, because every state variable was correct; only the glass was wrong.
  local function lockvis()
    if sdec.ui_lockbtn == nil then return 'NO HANDLE' end
    local o = MD.obj(sdec.ui_lockbtn)
    if o == nil then return 'NO OBJECT' end
    if o.state == display.STATE_INVISIBLE then return 'hidden' end
    return 'shown'
  end
  check('the Lock Rate handle survives ui_build rather than being cleared by it',
        sdec.ui_lockbtn ~= nil, tostring(sdec.ui_lockbtn))
  -- locked: nothing for it to do, so it must go away.
  pcall(function() sdec.ui_refresh() end)
  check('with the rate LOCKED the button is hidden', lockvis() == 'hidden', lockvis())
  -- auto: a rate was detected but not pinned -- the one state that wants the button.
  clearforce()
  r = run({bytes = hb, baud = 9600, fs = 100000})
  pcall(function() sdec.ui_refresh() end)
  check('with a rate DETECTED but not pinned it is shown',
        sdec.lock_state() == 'auto' and lockvis() == 'shown',
        sdec.lock_state() .. ' / ' .. lockvis())
  -- nothing decoded: no rate to pin, so hidden again.
  clearforce()
  sdec.clear_result()
  pcall(function() sdec.ui_refresh() end)
  check('with NOTHING decoded it is hidden -- there is no rate to lock',
        sdec.lock_state() == 'unknown' and lockvis() == 'hidden',
        sdec.lock_state() .. ' / ' .. lockvis())
  -- PUT BACK WHAT THE CHECKS BELOW CONTINUE FROM. Testing all three visibility states means walking
  -- the lock state machine through all three, which destroys the "decoded at 9600 and locked" that
  -- the rest of this section reads -- its next three checks are still the same lock_toggle
  -- narrative. Restored here rather than moving these checks elsewhere, because they belong beside
  -- the state-machine checks they complement.
  clearforce()
  r = run({bytes = hb, baud = 9600, fs = 100000})
  sdec.lock_toggle()
  -- The three lockable values carry the state as a colour too, so the distinction survives
  -- even if setfill on a rect turns out not to work on this firmware.
  check('and the BAUD/FORMAT/IDLE values go green with it',
        sdec.ui_field_colour(1) == sdec.ui_c_locked and
        sdec.ui_field_colour(2) == sdec.ui_c_locked and
        sdec.ui_field_colour(3) == sdec.ui_c_locked)
  check('but a measured column keeps its own colour',
        sdec.ui_field_colour(5) == sdec.ui_fields[5].c)
  -- LOCKING CHANGES THE SAMPLE RATE, so it must re-capture: fs_for_baud picks the lowest exact
  -- rate still giving 8 samples/bit, which for 9600 is 100 kS/s against the 1 MS/s the detection
  -- pass used. RATE, SA/BIT and the capture WINDOW all move with it -- 19 bytes to 192 -- so
  -- pinning the values without re-capturing would leave three header cells describing a rate no
  -- longer in force. This is the one that made the padlock and Lock Detected behave alike.
  --
  -- Asserted on sdec.fs, the REQUESTED rate. The mock cannot show acq_fs changing because it
  -- replays a fixed waveform's own timestamps, so the measured rate is whatever the vector was
  -- generated at -- a fidelity limit of the harness, not of the app.
  check('locking drops the sample rate to the one the locked baud implies',
        sdec.fs == sdec.fs_for_baud(9600) and sdec.fs < 1000000,
        string.format('fs=%s, fs_for_baud(9600)=%s', tostring(sdec.fs),
                      tostring(sdec.fs_for_baud(9600))))
  check('which is the whole point: a longer window at the same buffer depth',
        math.floor(sdec.n / ((sdec.fs / 9600) * 10)) > 100,
        string.format('%d bytes', math.floor(sdec.n / ((sdec.fs / 9600) * 10))))
  check('and the note names the new rate, since it is a change nobody asked for',
        sdec.lognote ~= nil and has(sdec.lognote, 'sampling at'), tostring(sdec.lognote))
  sdec.lock_toggle()
  check('a second press UNLOCKS, back to auto',
        sdec.lock_state() == 'auto' and sdec.force_baud == nil, sdec.lock_state())
  -- The PROPERTY, not the leftover value. sdec.fs is whatever the last capture used, and
  -- autoset() legitimately leaves it at the lower rate it just captured at. What must hold is
  -- that SELECTION is stateless: with nothing forced and no one-shot request pending,
  -- fs_select() returns the top rate, so the next auto-detect is not capped by history.
  sdec.fs_want = nil
  check('and rate SELECTION returns to the top rate, or auto-detection would be capped',
        sdec.fs_select() == sdec.fs_default,
        string.format('fs_select=%s default=%s', tostring(sdec.fs_select()),
                      tostring(sdec.fs_default)))
  -- Locking with nothing decoded must refuse rather than pin nils.
  sdec.clear_result()
  clearforce()
  sdec.lock_toggle()
  check('locking with nothing decoded refuses and says why',
        sdec.lock_state() == 'unknown' and sdec.force_baud == nil and
        sdec.lasterr ~= nil and has(sdec.lasterr, 'capture first'),
        tostring(sdec.lasterr))
  -- Unlocking disarms streaming, so it must leave the mode rather than sit in a dead one.
  r = run({bytes = hb, baud = 9600, fs = 100000})
  sdec.lock_toggle()
  sdec.capmode = 'med'
  check('a streaming mode is armed while locked', sdec.mode_why() == nil)
  sdec.lock_toggle()
  check('and unlocking LEAVES the streaming mode rather than stranding it',
        sdec.capmode == 'frame', tostring(sdec.capmode))
  check('the padlock is drawn from four rects, all deletable',
        sdec.ui_lock ~= nil and table.getn(sdec.ui_lock) == 4,
        tostring(sdec.ui_lock and table.getn(sdec.ui_lock)))
  -- THERE IS NO HIT RECT, and this replaces three assertions about its size, its fill and
  -- whether it stayed inside the table rules. All three described an object whose only purpose
  -- was to catch a tap, and BRINGUP 4b.9 settled on hardware 2026-08-16 that EVENT_PRESS on an
  -- OBJ_RECT is refused ("1717 Attribute event, does not apply to an object of type
  -- Rectangle"). It caught nothing -- and worse, an OBJ_RECT draws an outline whether filled or
  -- not, so it painted a box around the BAUD field brighter than every real rule in the header.
  -- Two rects removed; the padlock glyph still shows lock state, and Options > Lock Detected is
  -- the control. Asserting the absence keeps a future build from quietly reintroducing them.
  check('no press-catching rects: they cannot take events and they draw stray outlines',
        sdec.ui_lockhit == nil and sdec.ui_trighit == nil,
        string.format('lockhit=%s trighit=%s', tostring(sdec.ui_lockhit),
                      tostring(sdec.ui_trighit)))

  -- ---- trigger sources: the data line, or something outside it ----
  clearforce()
  -- THREE sources plus an orthogonal checkbox, not four sources: the rear BNC is an ADDITION
  -- to whichever source is selected, which no single-choice field can express.
  check('three trigger sources', sdec.opt_trig_v.n == 3, tostring(sdec.opt_trig_v.n))
  local tsrc = {}
  for i = 1, 3 do tsrc[i] = sdec.opt_trig_v[i] end
  check('edge / free / front -- the rear BNC is not one of them',
        table.concat(tsrc, ',') == 'edge,free,front', table.concat(tsrc, ','))
  -- The event constant must follow the mode, or 'ext' would silently arm the analog trigger.
  local function armed_with(mode)
    sdec.trigmode = mode
    SRC.rd, SRC.ts, SRC.nsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
    sdec.fs = 100000
    sdec.acq_make_buffer(sdec.n)
    sdec.thr, sdec.hyst = 1.65, 0.5
    sdec.acq_triggered(sdec.n, dmm.SLOPE_FALLING)
    return TRIG.ev
  end
  check('edge arms the ANALOG trigger -- the signal on HI/LO itself',
        armed_with('edge') == trigger.EVENT_ANALOGTRIGGER, tostring(TRIG.ev))
  check('front arms the physical TRIGGER key',
        armed_with('front') == trigger.EVENT_DISPLAY, tostring(TRIG.ev))
  check('and the external sources get a LONGER bounded wait -- a person is not a byte time',
        sdec.trigwait_ext > sdec.trigwait,
        string.format('%s vs %s', tostring(sdec.trigwait_ext), tostring(sdec.trigwait)))
  -- THE EXTERNAL TRIGGER IS OPTIONAL, and that is a requirement rather than a nicety: this is
  -- a serial decoder and it must work with one probe on one line and nothing else attached.
  check('the DEFAULT source watches the signal itself, not the rear BNC',
        sdec.opt_trig_v[1] == 'edge')
  check('and the rear BNC is a CHECKBOX, off by default, not a trigger source',
        sdec.trigext == false and sdec.opt_trig_v.n == 3,
        string.format('trigext=%s sources=%d', tostring(sdec.trigext), sdec.opt_trig_v.n))

  -- Ticked, the rear BNC is OR'd IN rather than selected instead -- which is the whole point
  -- of a checkbox over a fifth entry in the Trigger field.
  sdec.trigext = true
  sdec.trigmode = 'edge'
  check('ticked, the model waits on the BLENDER, not on one source',
        armed_with('edge') == trigger.EVENT_BLENDER1, tostring(TRIG.ev))
  check('and the blender OR-s the analog trigger with the rear BNC',
        trigger.blender[1].orenable == true and
        trigger.blender[1].stimulus[1] == trigger.EVENT_ANALOGTRIGGER and
        trigger.blender[1].stimulus[2] == trigger.EVENT_EXTERNAL,
        string.format('or=%s s1=%s s2=%s', tostring(trigger.blender[1].orenable),
                      tostring(trigger.blender[1].stimulus[1]),
                      tostring(trigger.blender[1].stimulus[2])))
  check('it composes with the front key too, not just the analog trigger',
        armed_with('front') == trigger.EVENT_BLENDER1 and
        trigger.blender[1].stimulus[1] == trigger.EVENT_DISPLAY,
        tostring(trigger.blender[1].stimulus[1]))
  -- FREE RUN means do not wait. OR-ing a trigger into it would silently make it triggered.
  sdec.trigmode = 'free'
  sdec.trigblended = nil
  sdec.acq_make_buffer(sdec.n)
  sdec.acq_free(sdec.n)
  check('but free run is NOT blended -- it means do not wait',
        sdec.trigblended ~= true, tostring(sdec.trigblended))
  sdec.trigext = false
  sdec.trigmode = 'edge'
  check('unticked, it goes back to a single source',
        armed_with('edge') == trigger.EVENT_ANALOGTRIGGER, tostring(TRIG.ev))
  -- AND RELEASES THE BLENDER. Not a correctness bug -- the model waits on the analog trigger
  -- and never references it -- but leaving a subsystem configured is left-behind instrument
  -- state, which is the same objection the object-lifetime rule makes about display objects.
  check('and releases the blender rather than leaving it armed',
        trigger.blender[1].orenable == false and
        trigger.blender[1].stimulus[2] == nil,
        string.format('or=%s s2=%s', tostring(trigger.blender[1].orenable),
                      tostring(trigger.blender[1].stimulus[2])))
  -- ONE FIELD, TWO BOOLEANS. The rear-BNC control was a check object carrying trigext alone;
  -- flow control needed fc_out too and the options form has no room for an eighth field, so the
  -- two booleans became four entries of one OBJ_EDIT_OPTION. Round-tripped in BOTH directions for
  -- EVERY combination, because a four-entry mapping is exactly where an off-by-one hides -- and
  -- the failure would be silent in the worst way: pulsing a rear BNC nobody asked to be pulsed.
  sdec.allow_rebuild = true
  sdec.build_options()
  local rt_ok, rk = true, nil
  for rk = 1, sdec.opt_rear_v.n do
    local want_ext, want_fc = sdec.opt_rear_v[rk][1], sdec.opt_rear_v[rk][2]
    sdec.trigext, sdec.fc_out = want_ext, want_fc
    sdec.options_seed()
    if MD.obj(sdec.opt_ext).value ~= rk then rt_ok = false end
    -- ...and back out again, from the index alone.
    sdec.trigext, sdec.fc_out = nil, nil
    display.setvalue(sdec.opt_ext, rk)
    sdec.options_apply()
    if sdec.trigext ~= want_ext or sdec.fc_out ~= want_fc then rt_ok = false end
  end
  check('the rear-BNC field round-trips all four trigext/fc_out combinations', rt_ok)
  -- An index the firmware should never return must not leave the app pulsing anything.
  display.setvalue(sdec.opt_ext, 99)
  sdec.options_apply()
  check('an out-of-range index falls back to both rear functions OFF',
        sdec.trigext == false and sdec.fc_out == false,
        string.format('ext=%s fc=%s', tostring(sdec.trigext), tostring(sdec.fc_out)))
  display.setvalue(sdec.opt_ext, 1)
  sdec.options_apply()
  -- ---- the panel SAYS whether data is being lost ----
  -- Three regimes, and which one you are in depends on the locked rate AND the rear-BNC setting
  -- together, so it is not derivable from any single cell. The app's stated promise is that no
  -- byte is lost; a streaming mode that quietly drops traffic between windows while claiming that
  -- would be the worst failure this design can have, so the ceiling is stated on the panel.
  local function regime()
    local t, n = sdec.ui_notes()
    local i
    for i = 1, n do
      if has(t[i], 'bounded at') or has(t[i], 'records until')
         or has(t[i], 'ARE LOST') or has(t[i], 'continuous:') then
        return t[i]
      end
    end
    return nil
  end

  -- THE NOTE MUST NOT CLAIM BYTES ARE LOST, at any rate. The press-driven path arms ONE hardware
  -- acquisition, so there are no windows to lose bytes between -- measured at 9600 baud, twice
  -- strm_maxbaud, a recording came back 1925 of 1925 bytes contiguous against a non-repeating
  -- payload. A loss warning there sends the operator to wire up flow control they do not need.
  sdec.capmode, sdec.fc_out = 'med', false
  local rates = {300, 1200, sdec.strm_maxbaud, sdec.strm_maxbaud + 1, 9600, 115200, 250000}
  local ri, claimed = nil, nil
  for ri = 1, table.getn(rates) do
    sdec.force_baud = rates[ri]
    local g = regime() or ''
    if has(g, 'ARE LOST') then claimed = string.format('%d Bd: %s', rates[ri], g) end
  end
  check('no rate makes the panel claim bytes are lost between windows',
        claimed == nil, tostring(claimed))

  -- What it DOES say is the real bound, in seconds of this line.
  sdec.force_baud = 9600
  check('a bounded streaming mode names its byte ceiling and how long that is',
        has(regime() or '', 'bounded at') and has(regime() or '', 'bytes'),
        tostring(regime()))
  -- THE UNCAPPED MODE IS GONE, so there is no longer a 'records until you stop it' regime to
  -- check. What replaces it is that the SAME bounded note appears at a slow rate too -- the ceiling
  -- is a byte count, so it does not change with the rate, only the seconds it works out to do.
  sdec.force_baud = 2400
  check('and it says the same at a slow rate -- the ceiling is bytes, not seconds',
        has(regime() or '', 'bounded at') and has(regime() or '', 'bytes'),
        tostring(regime()))
  sdec.capmode, sdec.fc_out = 'med', false
  -- FRAME never shows it: the regime is a property of the streaming modes, and FRAME's own
  -- gaps are stated by its duty cycle rather than by this note.
  sdec.capmode, sdec.fc_out = 'frame', false
  check('FRAME shows no regime note at all', regime() == nil, tostring(regime()))
  clearforce()
  sdec.capmode = 'frame'

  -- ---- credit-based flow control on EXT TRIG OUT ----
  -- The pulse is permission for the sending device to transmit one window's worth. THE ONLY
  -- THING THAT MAKES IT CORRECT IS THAT IT LEAVES AFTER THE MODEL IS ARMED: assert before
  -- initiate and the head of every frame lands while nothing is listening, losing exactly the
  -- bytes the feature exists to save, on every frame, looking like a decoder bug. The mock counts
  -- initiate() calls and records the count at each assert, so the ordering is asserted rather
  -- than assumed.
  clearforce()
  sdec.trigmode = 'edge'
  sdec.fc_out = false
  TRIG.asserts, TRIG.inits, TRIG.armed_at_assert = 0, 0, {}
  sdec.acquire()
  check('with flow control OFF the rear output is never pulsed', TRIG.asserts == 0,
        tostring(TRIG.asserts))
  sdec.fc_out = true
  TRIG.asserts, TRIG.inits, TRIG.armed_at_assert = 0, 0, {}
  sdec.acquire()
  check('with it ON a triggered capture pulses exactly once', TRIG.asserts == 1,
        tostring(TRIG.asserts))
  check('and the pulse leaves AFTER the trigger model is armed -- not before',
        (TRIG.armed_at_assert[1] or 0) >= 1,
        string.format('inits at assert = %s', tostring(TRIG.armed_at_assert[1])))
  -- The streaming path arms with SimpleLoop and must obey the same rule -- more strictly, since
  -- SimpleLoop starts filling at once rather than waiting for an edge.
  sdec.force_baud, sdec.force_nbits = 9600, 8
  sdec.force_par, sdec.force_nstop, sdec.force_invert = sdec.PAR_NONE, 1, false
  TRIG.asserts, TRIG.inits, TRIG.armed_at_assert = 0, 0, {}
  pcall(function() sdec.acq_make_buffer(4000) end)
  pcall(function() sdec.stream_acquire(4000) end)
  check('the streaming path pulses once, also after arming',
        TRIG.asserts == 1 and (TRIG.armed_at_assert[1] or 0) >= 1,
        string.format('asserts=%d armed=%s', TRIG.asserts,
                      tostring(TRIG.armed_at_assert[1])))
  -- fc_config only touches the line when the feature is on: an unasked-for logic change to a rear
  -- BNC is exactly the surprise the opt-in exists to prevent.
  trigger.extout.logic = nil
  sdec.fc_out = false
  sdec.fc_config()
  check('fc_config leaves the rear output alone when disabled',
        trigger.extout.logic == nil, tostring(trigger.extout.logic))
  sdec.fc_out = true
  sdec.fc_config()
  check('and sets a positive-going pulse when enabled -- rising edge for the device',
        trigger.extout.logic == trigger.LOGIC_POSITIVE, tostring(trigger.extout.logic))
  sdec.fc_out = false
  clearforce()

  -- An external source selected with nothing wired must degrade, not fail. The mock's trigger
  -- model completes immediately, so this asserts the FALLBACK PATH exists and is reachable
  -- rather than the timeout itself, which needs real time to elapse.
  sdec.trigext, sdec.trigmode = true, 'edge'
  SRC.rd, SRC.ts, SRC.nsmp = GEN({bytes = hb, baud = 9600, fs = 100000})
  sdec.fs = 100000
  sdec.acq_make_buffer(sdec.n)
  sdec.thr, sdec.hyst = 1.65, 0.5
  local gotn = sdec.acq_triggered(sdec.n, dmm.SLOPE_FALLING)
  check('an external source still returns samples rather than nothing',
        gotn ~= nil and gotn > 1, tostring(gotn))
  -- Break the trigger model outright -- an unwired rear BNC on a firmware that refuses the
  -- event, which is the pessimistic version of "selected but not connected". The capture must
  -- still come back, with a stated reason, rather than leaving the operator with nothing.
  local realinit = trigger.model.initiate
  trigger.model.initiate = function() error('no such event source', 0) end
  sdec.lasterr = nil
  local fb = sdec.acq_triggered(sdec.n, dmm.SLOPE_FALLING)
  trigger.model.initiate = realinit
  check('a trigger source the instrument refuses DEGRADES to a free capture',
        fb ~= nil and fb > 1, tostring(fb))
  check('and names the SOURCE that failed, not a generic one',
        sdec.lasterr ~= nil and has(sdec.lasterr, 'edge') and
        has(sdec.lasterr, 'captured free-running'), tostring(sdec.lasterr))
  sdec.trigext, sdec.trigmode = false, 'free'

  -- ---- THREE REGRESSIONS FROM ADVERSARIAL REVIEW (session 5) ----
  -- Each of these shipped, each was found by review rather than by the suite, and each is
  -- pinned here because the failure mode was quiet in all three cases.

  -- 1. The idle watchdog read levels that clear_result() had just ZEROED. With thr = 0 and
  -- hyst = 0, smp_active() starts a 0/3.3 V line in state 1 and waits for a sample below
  -- 0 V, which never comes -- so continuous traffic measured as QUIET and every long
  -- capture would have ended after idle_exit_s seconds.
  local act = {}
  for i = 1, 200 do act[i] = 3.3 end
  for i = 50, 59 do act[i] = 0 end          -- one real space bit: unambiguous traffic
  check('traffic reads as ACTIVE with measured levels',
        sdec.smp_active(act, 200, 1.65, 0.495) == true)
  sdec.clear_result()
  check('and zeroed levels must NOT be usable as a watchdog threshold',
        sdec.thr == 0 and sdec.hyst == 0 and
        sdec.smp_active(act, 200, sdec.thr, sdec.hyst) == false,
        'this is why stream() probes for levels before the long recording')
  check('so the watchdog is DISARMED until a probe measures the line',
        sdec.ck_watch ~= true, tostring(sdec.ck_watch))

  -- 2. The minority-hump gate was binocc (16), a PER-BIN target used for a whole hump's
  -- total. At 16 it refused a sparse burst -- one short message in a long recording, the
  -- traffic the streaming modes exist for. It is 2: the minimum that kills a one-sample
  -- hump, which is all this gate is for.
  check('the hump gate is the minimum that kills a one-sample hump', sdec.minhump == 2,
        tostring(sdec.minhump))
  local function sparse(nlow)
    local t = {}
    for i = 1, 20000 do t[i] = 3.3 end
    for i = 10000, 10000 + nlow - 1 do t[i] = 0 end
    return sdec.sig_levels(t, 20000)
  end
  check('a 2-sample minority level is accepted -- a sparse burst is real traffic',
        sparse(2) == true)
  check('but a 1-sample one is not a level', sparse(1) == false)
  -- The case the gate exists for must still be refused.
  local nrd, nseed = {}, 12345
  for i = 1, 4000 do
    nseed = math.fmod(nseed * 16807, 2147483647)
    nrd[i] = 5 * (nseed / 2147483647)
  end
  check('and structureless noise is still refused at the level stage',
        sdec.sig_levels(nrd, 4000) == false)

  -- 3. Decimation can ALIAS PAST a sparse burst: 50 low samples in 2.8 M decimate to one
  -- or none at step 140. ck_levels falls back to a contiguous window rather than reporting
  -- a measurable recording as an idle line.
  local NT = 2800000
  local function vat(i)
    if i >= 1001 and i <= 1050 then return 0.0 end
    return 3.3
  end
  local rdr = function(dst, from, count, step)
    if step == nil then step = 1 end
    local m, i = 0, 0
    for i = 1, count do
      local a = from + (i - 1) * step
      if a > NT then break end
      dst[i] = vat(a)
      m = i
    end
    return m
  end
  local lok = sdec.ck_levels(rdr, NT, {})
  check('a burst the decimated view aliases past is caught by the contiguous fallback',
        lok == true and sdec.ck_levelsrc == 'contiguous',
        string.format('ok=%s src=%s', tostring(lok), tostring(sdec.ck_levelsrc)))
  -- And the decimated path is still preferred when it works, or the drift fix is undone.
  local clean = {}
  for i = 1, 40000 do clean[i] = 3.3 end
  for i = 1, 40000, 4 do clean[i] = 0 end
  local ok2 = sdec.ck_levels(sdec.ck_reader_table(clean, 40000), 40000, {})
  check('and an ordinary recording still uses the DECIMATED view, not the fallback',
        ok2 == true and sdec.ck_levelsrc == 'decimated', tostring(sdec.ck_levelsrc))

  -- 4. frame_log's write-failure path was DEAD: `wrote` was initialised true and the
  -- pcall's result discarded, so a key pulled mid-message returned success.
  MD.usb(true)
  MD.forget_files()
  clearforce()
  sdec.capmode = 'frame'
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  r = run({bytes = hb, baud = 9600, fs = 100000})
  MD.failwrite(2)                            -- the second write raises
  local fok = sdec.frame_log()
  check('a key pulled mid-message REPORTS the failure rather than returning success',
        fok == false and sdec.flog_why ~= nil and has(sdec.flog_why, 'write failed'),
        string.format('ok=%s why=%s', tostring(fok), tostring(sdec.flog_why)))
  MD.failwrite(nil)
  sdec.flog_path, sdec.flog_n, sdec.flog_why = nil, nil, nil
  check('and a healthy write still reports success', sdec.frame_log() == true)

  clearforce()
  sdec.capmode = 'frame'
  sdec.ck_tot, sdec.ck_nbytes, sdec.ck_running = nil, nil, false
end
test_modes()

-- ============================================================================
-- ABANDONING A LOCKED RATE THE WIRE CONTRADICTS.
--
-- Bench report 2026-08-18: the generator's rate was doubled under a 19200 lock, every frame failed,
-- and repeated Capture presses kept showing an all-red hex page. Nothing recovered -- the operator
-- had to type 0 into Options to get detection back. sdec.decode() now drops such a lock.
--
-- THE GATE THAT MATTERS IS THE THIRD ONE, and it has its own test below: a rate that FITS but a
-- format that does not also fails every frame, and that lock must survive. Discarding a rate the
-- operator typed, when the rate was right, would be a worse defect than the one being fixed.
-- ============================================================================
print('\nabandoning a locked rate that fits nothing')
do
  -- THE BENCH CASE, REPRODUCED AT THE INSTRUMENT'S OWN SAMPLE RATE. fs must be ~8.3 samples/bit at
  -- the LOCKED rate, as the app picks it: at a cleaner 400 kS/s the same mismatch decodes with a
  -- badfrac of 0.06 and no framing trouble at all, which is the silent-wrong case and NOT what was
  -- reported. Getting this wrong made the first version of this test pass while nothing happened.
  local FS = 160000
  clearforce()

  -- (1) THE WIRE AT TWICE THE LOCK -- asserted unconditionally, no `if relocked ~= nil` wrapper:
  -- guarding the assertions on the behaviour they are testing is how a test passes vacuously.
  local rd, ts, nc, nsmp = GEN({bytes = hb, baud = 38400, fs = FS})
  analyse(rd, nsmp, FS)
  sdec.smp, sdec.nread = rd, nsmp
  sdec.force_baud = 19200
  sdec.relocked, sdec.rate_note = nil, nil
  sdec.decode()
  check('a wire at 2x the locked rate makes the app abandon the lock',
        sdec.relocked ~= nil and sdec.force_baud == nil,
        string.format('relocked=%s force_baud=%s', tostring(sdec.relocked),
                      tostring(sdec.force_baud)))
  check('...it says so, naming the rate it dropped', has(tostring(sdec.relocked), '19200'),
        tostring(sdec.relocked))
  check('...and the note fits the cell',
        sdec.ui_textw(tostring(sdec.relocked)) <= sdec.ui_note_px,
        string.format('%d px of %d', sdec.ui_textw(tostring(sdec.relocked)), sdec.ui_note_px))
  check('...the warning about the rate it just dropped does not outlive it',
        sdec.rate_note == nil, tostring(sdec.rate_note))
  check('...and it reaches the note row', has(table.concat(sdec.ui_notes(), ' | '), '19200'),
        table.concat(sdec.ui_notes(), ' | '))

  -- (2) THE SAFETY GATE. A rate that fits, with a format that does not: every frame fails, and the
  -- lock MUST survive because the evidence is against the format, not the rate. rate_note nil is
  -- what carries that distinction.
  clearforce()
  local rd2, ts2, nc2, nsmp2 = GEN({bytes = hb, baud = 9600, fs = 100000, nbits = 7,
                                    par = 1, nstop = 1})
  analyse(rd2, nsmp2, 100000)
  sdec.smp, sdec.nread = rd2, nsmp2
  sdec.force_baud, sdec.force_nbits = 9600, 8
  sdec.force_par, sdec.force_nstop = sdec.PAR_NONE, 1
  sdec.relocked, sdec.rate_note = nil, nil
  sdec.decode()
  check('a RIGHT rate with a wrong format keeps its lock',
        sdec.force_baud == 9600 and sdec.relocked == nil,
        string.format('force_baud=%s relocked=%s', tostring(sdec.force_baud),
                      tostring(sdec.relocked)))

  -- (3) TOO FEW FRAMES IS NOT EVIDENCE. Two bad bytes must not throw away a rate.
  clearforce()
  local rd3, ts3, nc3, nsmp3 = GEN({bytes = {65, 66}, baud = 38400, fs = FS})
  analyse(rd3, nsmp3, FS)
  sdec.smp, sdec.nread = rd3, nsmp3
  sdec.force_baud = 19200
  sdec.relocked = nil
  sdec.decode()
  check('a capture too short to judge keeps its lock',
        sdec.force_baud == 19200, tostring(sdec.force_baud))

  -- (4) A HEALTHY CAPTURE IS LEFT ALONE, which is the case that runs every day.
  clearforce()
  local rd4, ts4, nc4, nsmp4 = GEN({bytes = hb, baud = 9600, fs = 100000})
  analyse(rd4, nsmp4, 100000)
  sdec.smp, sdec.nread = rd4, nsmp4
  sdec.force_baud = 9600
  sdec.relocked = nil
  sdec.decode()
  check('a correct lock on a good capture is never touched',
        sdec.force_baud == 9600 and sdec.relocked == nil,
        string.format('force_baud=%s relocked=%s', tostring(sdec.force_baud),
                      tostring(sdec.relocked)))

  -- (4b) THE RETRY HAS TO EARN IT. Raised by review: rate_note also fires on healthy captures (its
  -- integer-multiple branch is usually the fit erring short), so a CORRECT hand-typed rate with a wrong
  -- forced FORMAT could have its rate thrown away. Driven deterministically by making every decode look
  -- equally bad -- detection then beats nothing, so the operator's rate must come back.
  do
    clearforce()
    local rd5, ts5, nc5, nsmp5 = GEN({bytes = hb, baud = 38400, fs = FS})
    analyse(rd5, nsmp5, FS)
    sdec.smp, sdec.nread = rd5, nsmp5
    sdec.force_baud = 19200
    sdec.relocked = nil
    local realbf = sdec.ua_badfrac
    sdec.ua_badfrac = function() return 0.95 end     -- nothing improves on anything
    sdec.decode()
    sdec.ua_badfrac = realbf
    check('a retry that is no better restores the operator rate',
          sdec.force_baud == 19200, tostring(sdec.force_baud))
    check('...and claims no relock, because none helped',
          sdec.relocked == nil, tostring(sdec.relocked))
  end

  -- (5) IT IS PER-PRESS, NOT PER-ACQUIRE, and that distinction is the fix for a real failure.
  -- clear_result() runs on every acquire(), including autoset()'s re-capture after a rate change -- so
  -- evicting it there wiped the note between the relock and the end of the same press, leaving correct
  -- bytes and nothing saying the operator's lock had been dropped. bench_break caught it.
  sdec.relocked = 'kept'
  sdec.clear_result()
  check('clear_result KEEPS the note, so it survives an internal re-capture',
        sdec.relocked == 'kept', tostring(sdec.relocked))
  clearforce()
end

-- ============================================================================
-- 153.6 kBd MUST SNAP, OR AUTO-LOCK CAN NEVER PIN IT.
--
-- Bench, 2026-08-18: a 153.6 kBd line decoded correctly but the padlock never went green and the
-- recording modes stayed unarmed, because the rate ladder jumped 128000 -> 230400 and
-- autolock_try()'s first gate is `snapped`. The operator had to type the raw measured figure into
-- Options. Being in the list is not the claim worth testing -- SNAPPING is, and so is the auto-lock
-- that depends on it.
-- ============================================================================
print('\n153.6 kBd snaps, so auto-lock can pin it')
do
  clearforce()
  local FS = 1000000
  local hb2, hn2 = GEN_BYTES(string.rep('Lorem ipsum dolor sit amet. ', 12))
  local rd, ts, nc, nsmp = GEN({bytes = hb2, baud = 153600, fs = FS})
  analyse(rd, nsmp, FS)
  local ok, why = sdec.decode_from(rd, nsmp)
  check('a 153.6 kBd line decodes', ok and sdec.res ~= nil and sdec.res.nf > 0,
        string.format('ok=%s nf=%s why=%s', tostring(ok),
                      tostring(sdec.res and sdec.res.nf), tostring(why)))
  check('...and SNAPS to 153600 rather than reporting a raw figure',
        sdec.snapped == true and sdec.baud == 153600,
        string.format('snapped=%s baud=%s', tostring(sdec.snapped), tostring(sdec.baud)))
  check('...so the panel shows it without a question mark',
        not has(sdec.baud_text(), '?'), sdec.baud_text())
  -- THE GATE THAT WAS FAILING. autolock_try() has five; only `snapped` was in the way.
  sdec.autolock, sdec.autolock_skip = true, nil
  sdec.autolock_try()
  check('...and auto-lock pins it, so the recording modes arm',
        sdec.force_baud == 153600, tostring(sdec.force_baud))
  check('...which is what makes an 8 kB recording available',
        sdec.mode_why({needbaud = true, cap = 8192}) == nil,
        tostring(sdec.mode_why({needbaud = true, cap = 8192})))
  -- THE REFUSAL MUST NOT CONTRADICT THE HEADER BESIDE IT. At 192024 Bd the SA/BIT cell reads 5.2,
  -- measured from a FRAME capture that gets nearly the 1 MS/s it asks for, while the note used to say
  -- "no sample rate delivers 4 samples/bit". Both true, and together they read as a bug -- the owner
  -- quoted the two cells against each other. A recording's burst acquisition loses acq_overhead per
  -- sample, so it gets 3.4, and the note has to say whose figure it means.
  do
    local svb = sdec.force_baud
    sdec.force_baud = 192024
    local w = sdec.mode_why({needbaud = true, cap = 8192})
    check('a rate too fast to record is refused', w ~= nil, tostring(w))
    check('...naming the figure a RECORDING gets, not the frame one',
          has(tostring(w), '3.4') and not has(tostring(w), '5.2'), tostring(w))
    check('...and it still points at FRAME, which does work there',
          has(tostring(w), 'FRAME'), tostring(w))
    check('...and fits the note cell WITH its WARNING prefix',
          sdec.ui_textw('WARNING: ' .. tostring(w)) <= sdec.ui_note_px,
          string.format('%d px of %d', sdec.ui_textw('WARNING: ' .. tostring(w)),
                        sdec.ui_note_px))
    -- 153.6 kBd is on the other side of the same gate and must stay available.
    sdec.force_baud = 153600
    check('...while 153.6 kBd, which records fine, is not refused',
          sdec.mode_why({needbaud = true, cap = 8192}) == nil,
          tostring(sdec.mode_why({needbaud = true, cap = 8192})))
    -- THE CROSSOVER IS 165563 Bd, so 153600 is the last standard rate that can record and everything
    -- above it is frame-only. Asserted as a boundary rather than a single point: an acq_overhead or
    -- rate-ladder change that moved it would go unnoticed otherwise.
    local recmax, i = nil, nil
    for i = 1, table.getn(sdec.stdbaud) do
      if sdec.fs_for_burst(sdec.stdbaud[i]) ~= nil then recmax = sdec.stdbaud[i] end
    end
    check('...and 153600 is the fastest standard rate that can record at all',
          recmax == 153600, tostring(recmax))
    sdec.force_baud = svb
  end

  -- 307200 is deliberately absent: maxbaud refuses it, so listing it would advertise a refusal.
  local has307 = false
  local i
  for i = 1, table.getn(sdec.stdbaud) do
    if sdec.stdbaud[i] == 307200 then has307 = true end
  end
  check('307200 stays out of the ladder while maxbaud is 250000',
        not has307 and sdec.maxbaud == 250000,
        string.format('has307=%s maxbaud=%s', tostring(has307), tostring(sdec.maxbaud)))
  clearforce()
end

-- ============================================================================
-- THE PADLOCK'S FAILED RE-CAPTURE, which had no test anywhere: 're-capture failed' appeared in no
-- suite at all. Locking a rate CHANGES the sample rate, so lock_toggle() re-captures -- and both the
-- pcall's verdict and capture()'s own boolean were once discarded, so a re-capture that refused or
-- raised still produced 'locked 9600 baud -- now sampling at 80 kS/s' over whatever the previous
-- capture had left on the glass. A confident report of a capture that did not happen: the panel
-- stating something untrue, which is this project's other recurring defect.
-- ============================================================================
print('\nthe padlock says so when its re-capture fails')
local function test_lock_recapture()
  -- The line goes silent between the decode that produced the rate and the press that locks it,
  -- which is not contrived at all: locking is what the operator does after a burst has gone past.
  local qrd, qts, qnc, qn = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 12000,
                                 tail = 0, n = 12000})
  local svrd, svts, svn = SRC.rd, SRC.ts, SRC.nsmp
  local brd, bts, bnc, bn = GEN({bytes = hb, baud = 9600, fs = 100000, lead = 20, n = 12000})

  -- AMBER, WITH A RATE TO LOCK: nothing forced and a real decode behind it, which is the only state
  -- from which the padlock locks anything.
  local function ready_to_lock()
    clearforce()
    sdec.busy, sdec.capmode = false, 'frame'
    sdec.lognote, sdec.lasterr = nil, nil
    SRC.rd, SRC.ts, SRC.nsmp = brd, bts, bn
    analyse(brd, bn, 100000)
    sdec.decode_from(brd, bn)
    return sdec.lock_state()
  end

  check('the padlock starts amber, with a detected rate to pin',
        ready_to_lock() == 'auto' and sdec.baud ~= nil,
        string.format('%s baud=%s', sdec.lock_state(), tostring(sdec.baud)))

  -- ---- 1. THE RE-CAPTURE REFUSES: there is nothing on the wire any more ----
  SRC.rd, SRC.ts, SRC.nsmp = qrd, qts, qn
  sdec.lock_toggle()
  check('a re-capture that found nothing SAYS the re-capture failed',
        has(sdec.lognote, 're-capture failed'), tostring(sdec.lognote))
  check('...and says which figures the header is therefore still showing',
        has(sdec.lognote, 'the figures above are the previous one'), tostring(sdec.lognote))
  -- THE SENTENCE IT MUST NOT PRINT. 'now sampling at N kS/s' is a claim about a capture that was
  -- never made, and it is what the shipped code said here.
  check('...and does NOT claim a new sample rate is in force',
        not has(sdec.lognote, 'now sampling at'), tostring(sdec.lognote))
  -- THE ACTION STILL HAPPENED, which is why the WORDING had to change rather than the behaviour:
  -- the lock is applied whether or not the capture that follows it works.
  check('...while the lock itself did take, so the wording is the only thing that moves',
        sdec.force_baud == 9600 and sdec.lock_state() == 'locked',
        string.format('baud=%s %s', tostring(sdec.force_baud), sdec.lock_state()))
  check('...and it still names what was locked, which is the half that succeeded',
        has(sdec.lognote, 'locked') and has(sdec.lognote, '9600'), tostring(sdec.lognote))
  -- TWO CELLS THAT MUST NOT CONTRADICT EACH OTHER: lasterr carries capture()'s own reason and
  -- outranks this note in ui_notes, so both have to be on the note list and both have to be true.
  check('...with capture()\'s own reason kept beside it', has(sdec.lasterr, 'idle'),
        tostring(sdec.lasterr))
  local nt = table.concat(sdec.ui_notes(), ' | ')
  check('...and the panel carries both, not one over the other',
        has(nt, 're-capture failed') and has(nt, 'idle'), nt)

  -- ---- 2. THE RE-CAPTURE RAISES inside the acquisition ----
  ready_to_lock()
  local realauto = sdec.autoset
  sdec.autoset = function() error('acquisition fault', 0) end
  sdec.lock_toggle()
  sdec.autoset = realauto
  check('a re-capture whose acquisition RAISED gets the same sentence',
        has(sdec.lognote, 're-capture failed')
        and not has(sdec.lognote, 'now sampling at'), tostring(sdec.lognote))
  check('...with the raise reported rather than swallowed',
        has(sdec.lasterr, 'acquisition fault'), tostring(sdec.lasterr))

  -- ---- 3. THE CALL ITSELF RAISES, which is the half the pcall is for ----
  -- lock_toggle() is a touch handler and capture() is guarded internally, but its own comment says
  -- the call must not be able to raise HERE either -- so the pcall's verdict has to be read too, not
  -- only capture()'s boolean.
  ready_to_lock()
  local realcap = sdec.capture
  sdec.capture = function() error('touch handler fault', 0) end
  local pok = pcall(function() sdec.lock_toggle() end)
  sdec.capture = realcap
  check('a capture() that RAISES does not take the padlock handler with it', pok == true)
  check('...and is reported as a failed re-capture, not as a new sample rate',
        has(sdec.lognote, 're-capture failed')
        and not has(sdec.lognote, 'now sampling at'), tostring(sdec.lognote))

  -- ---- 4. AND A RE-CAPTURE THAT WORKED STILL NAMES THE NEW RATE ----
  -- Asserted from the other side, or the guard could be made unconditional and every successful lock
  -- would report a failure while this section stayed green.
  ready_to_lock()
  sdec.lock_toggle()
  check('a re-capture that succeeded names the rate now in force',
        has(sdec.lognote, 'now sampling at')
        and not has(sdec.lognote, 're-capture failed'), tostring(sdec.lognote))

  SRC.rd, SRC.ts, SRC.nsmp = svrd, svts, svn
  clearforce()
  sdec.clear_result()
  sdec.lognote, sdec.lasterr = nil, nil
end
test_lock_recapture()

-- ============================================================================
-- THE TAIL RING'S ABSOLUTE OFFSETS, computed from the ring rather than typed out. The note row's
-- 'bytes 24577-32768 of 32768' is pinned against a hand-written first = 24577 elsewhere in this file,
-- and a hand-written expectation cannot catch an off-by-one in the thing that computes it -- so
-- nothing tested tl.w, which is the total ever pushed and the only source of that number.
--
-- ck_tail_push's skip is where it went wrong once already: a batch wider than the ring jumped
-- straight to the last cap bytes without advancing w, so the ring held the right bytes and labelled
-- them with the wrong offsets, and every later push inherited the error.
-- ============================================================================
print('\nthe stream tail ring: which absolute bytes it says it is holding')
local function test_tail_offsets()
  -- Bytes ARE their own absolute index, so a wrong offset is visible in the values themselves rather
  -- than only in the arithmetic. `base` is passed as the caller passes it: the 0-based index of the
  -- first byte of the batch.
  local function ring(cap, batches)
    local tl, total, bi = sdec.ck_tail_new(cap), 0, nil
    for bi = 1, table.getn(batches) do
      local m, v, e, i = batches[bi], {}, {}, nil
      for i = 1, m do total = total + 1; v[i] = total end
      sdec.ck_tail_push(tl, v, e, m, total - m)
    end
    return tl, total
  end
  -- THE INVARIANT EVERY CASE IS CHECKED AGAINST: the view's last absolute index is the number of
  -- bytes ever pushed, and its values are exactly that closed range. Asserted as a range rather than
  -- as one number, because `first` alone is satisfied by a ring that kept the wrong bytes.
  local function holds(name, cap, batches, wantfirst, wantn)
    local tl, total = ring(cap, batches)
    local r = sdec.ck_tail_result(tl, nil, total)
    local bad, i = nil, nil
    if r == nil then bad = 'no view at all'
    else
      for i = 1, r.nf do
        if r.vals[i] ~= r.first + i - 1 and bad == nil then
          bad = string.format('vals[%d]=%s, not %d', i, tostring(r.vals[i]), r.first + i - 1)
        end
      end
    end
    check(name,
          r ~= nil and r.first == wantfirst and r.nf == wantn
          and r.first + r.nf - 1 == total and r.ntotal == total and bad == nil,
          string.format('first=%s nf=%s w=%d pushed=%d%s',
                        tostring(r and r.first), tostring(r and r.nf), tl.w, total,
                        bad and (' -- ' .. bad) or ''))
  end

  -- NOT WRAPPED: everything ever pushed is still in the ring, so the view starts at byte 1.
  holds('a ring that has not wrapped starts at byte 1', 8, {5}, 1, 5)
  holds('...and one filled exactly to its capacity still does', 8, {8}, 1, 8)
  -- WRAPPED EXACTLY ONCE, on a batch boundary: the write cursor is back at slot 1 and the oldest
  -- kept byte is cap+1.
  holds('a ring wrapped exactly once starts at cap + 1', 8, {8, 8}, 9, 8)
  holds('...and twice, at 2 x cap + 1', 8, {8, 8, 8}, 17, 8)
  -- WRAPPED MID-ELEMENT: the cursor sits in the middle of the array, so the linearisation has to
  -- start from the oldest slot rather than from slot 1. This is the case an off-by-one in `start`
  -- rotates without changing the count.
  holds('a ring wrapped mid-batch still reports the oldest byte it kept', 8, {5, 5}, 3, 8)
  holds('...however uneven the batches were', 4, {2, 3, 4}, 6, 4)
  holds('...including a wrap that lands one short of the cursor', 4, {3, 3, 3}, 6, 4)
  -- A BATCH WIDER THAN THE RING. The skip must still COUNT: cap 3 fed a batch of 5 keeps bytes 3-5,
  -- and the defect this replaced reported first = 1 for exactly this case.
  holds('a batch wider than the ring keeps its LAST cap bytes, and says which', 3, {5}, 3, 3)
  holds('...and a later push inherits the corrected total rather than a stale one', 3, {5, 2}, 5, 3)
  holds('...for a batch many times the width', 4, {40}, 37, 4)

  -- AND THE FIGURE THE NOTE ROW PRINTS, derived here instead of typed. This is the 24577 the
  -- streaming note is pinned against: a shipped 8192-byte ring after a full 32 kB recording.
  local tl32, total32 = ring(sdec.ck_keep, {8192, 8192, 8192, 8192})
  local r32 = sdec.ck_tail_result(tl32, nil, total32)
  check('the shipped ring after a 32 kB recording holds bytes 24577-32768',
        sdec.ck_keep == 8192 and r32.first == 24577 and r32.nf == 8192
        and r32.ntotal == 32768,
        string.format('keep=%s first=%s nf=%s ntotal=%s', tostring(sdec.ck_keep),
                      tostring(r32.first), tostring(r32.nf), tostring(r32.ntotal)))
  -- THE PANEL'S SENTENCE, READ OFF THAT VIEW rather than off a table written by hand -- which is what
  -- closes the loop between the offsets and the note that publishes them.
  local svres, svtot = sdec.res, sdec.ck_tot
  sdec.res = r32
  sdec.ck_tot = {nf = total32, nbad = 0, nwin = 4, nsmp = 1, path = '/usb1/stream00.txt'}
  local nt = table.concat(sdec.ui_notes(), ' | ')
  check('...and the note row names that range, computed from the ring itself',
        has(nt, string.format('bytes %d-%d of %d', r32.first, r32.first + r32.nf - 1,
                              total32)), nt)
  sdec.res, sdec.ck_tot = svres, svtot

  -- AN EMPTY RING IS NO VIEW AT ALL, not a view of zero bytes: sdec.res = {nf = 0} would page and
  -- label bytes that do not exist.
  check('an empty ring produces no view', sdec.ck_tail_result(sdec.ck_tail_new(8), nil, 0) == nil)
  check('and a ring cannot be made with no room in it',
        sdec.ck_tail_new(0) == nil and sdec.ck_tail_new(-1) == nil)
end
test_tail_offsets()

-- ============================================================================
-- A FRACTIONAL BAUD RATE, WHICH THE OPTIONS FORM IS THE ONLY SOURCE OF. The Baud Rate field used to
-- admit any number >= 110, so 9600.5 could be applied -- and force_baud is formatted with %d at
-- three sites, which TRUNCATES silently on the instrument's Lua 5.0.2 and RAISES on the 5.5 these
-- suites run. options_apply() now rounds at the point of entry, which is what makes the rest safe.
--
-- Pinned here BOTH ways: the rounding, and the panel strings rendering a fractional rate anyway. The
-- second half is what keeps the hazard visible -- a %d put back at any of those sites raises here
-- rather than waiting to truncate on the box.
-- ============================================================================
print('\na baud rate typed with a fraction in it')
local function test_baud_round()
  clearforce()
  sdec.allow_rebuild = true
  sdec.build_options()
  local svproto = sdec.proto
  sdec.proto = 'uart'
  -- A LINE THAT IS IDLE WHILE THE FORM IS APPLIED, because Apply ENDS IN A CAPTURE ('use these now')
  -- and a capture that decodes would move the rate out from under the assertion: auto-lock pins the
  -- rate it detected, and decode() DROPS a locked rate the wire contradicts -- both of them correct,
  -- both of them about the capture rather than about the field. Typing a rate in with nothing on the
  -- wire yet is also the ordinary case: the rate comes from a datasheet, not from a burst.
  local svrd, svts, svn = SRC.rd, SRC.ts, SRC.nsmp
  local qrd, qts, qnc, qn = GEN({bytes = {}, baud = 9600, fs = 100000, lead = 12000,
                                 tail = 0, n = 12000})
  SRC.rd, SRC.ts, SRC.nsmp = qrd, qts, qn

  -- ---- 1. THE FIELD ROUNDS, AT THE ONE PLACE THE VALUE ENTERS ----
  local cases = {{9600.4, 9600}, {9600.6, 9601}, {110.5, 111}, {31250.0, 31250},
                 {153588.155, 153588}}
  local ci
  for ci = 1, table.getn(cases) do
    display.setvalue(sdec.opt_baud, cases[ci][1])
    sdec.options_apply()
    check(string.format('Baud Rate %.3f is applied as %d', cases[ci][1], cases[ci][2]),
          sdec.force_baud == cases[ci][2],
          string.format('%s (%s)', tostring(sdec.force_baud), type(sdec.force_baud)))
    -- AN INTEGER, not merely a value that compares equal: %d is what the app formats it with, and
    -- 9600.0 passes an == test and still raises on 5.5.
    check('...as a whole number %d can format',
          pcall(function() return string.format('%d', sdec.force_baud) end) == true,
          tostring(sdec.force_baud))
  end
  -- BELOW THE FLOOR IS STILL AUTO-DETECT, and the rounding must not have moved the floor: 109.5
  -- rounds to 110, but the test is on the value read, not on the rounded one.
  display.setvalue(sdec.opt_baud, 109.6)
  sdec.options_apply()
  check('a rate under the 110 floor is still read as auto-detect, not rounded up into range',
        sdec.force_baud == nil, tostring(sdec.force_baud))
  display.setvalue(sdec.opt_baud, 0)
  sdec.options_apply()
  check('and 0 is still the auto-detect request it always was', sdec.force_baud == nil,
        tostring(sdec.force_baud))

  -- ---- 2. THE PANEL STRINGS THAT FORMAT A LOCKED RATE ----
  -- Driven with a fractional force_baud on purpose. Nothing in the app should produce one now, and
  -- that is exactly why these have to be exercised by hand: the sites are unreachable, so a %d put
  -- back at any of them would never be noticed until the value came from somewhere new -- the socket,
  -- a restore path, a future field.
  local svb, svbaud, svres, svsnap = sdec.force_baud, sdec.baud, sdec.res, sdec.snapped
  local svmode = sdec.capmode
  -- No res and no fitted rate, which is the state a streaming run leaves: the forced value is the
  -- only thing these three cells have to go on, and it is what they fall back to.
  sdec.baud, sdec.res, sdec.snapped = nil, nil, nil
  -- .4 rather than .5, so there is one right answer: %.0f rounds a half to even and math.floor(x+0.5)
  -- rounds it up, and a test that cannot say which is correct pins nothing.
  sdec.force_baud = 9600.4
  local bok, btxt = pcall(function() return sdec.baud_text() end)
  check('baud_text() renders a fractional locked rate instead of raising',
        bok == true and btxt == '9600 baud', tostring(btxt))
  -- THE HEADER CELL BESIDE IT reads the same variable and must agree with it -- two cells stating
  -- different rates for the same locked wire is the panel contradicting itself, and this one is still
  -- on %d (serial_ui.tsp:802) while the other two were moved to %.0f.
  local vok, v1 = pcall(function() return sdec.ui_field_values()[1] end)
  check('the BAUD header cell renders it too', vok == true, tostring(v1))
  check('...and agrees with baud_text() about what the rate is',
        vok == true and bok == true and v1 == '9600',
        string.format('%s vs %s', tostring(v1), tostring(btxt)))

  -- mode_why's REFUSAL, which is the other string the rate reaches. It needs a rate no sample rate
  -- can stream: 192024.5 Bd, one of the rates fs_for_burst() gives up on.
  sdec.capmode = 'med'
  sdec.force_baud = 192024.5
  check('the rate chosen for this case really is unstreamable',
        sdec.fs_for_burst(sdec.force_baud) == nil,
        tostring(sdec.fs_for_burst(sdec.force_baud)))
  local wok, wtxt = pcall(function() return sdec.mode_why() end)
  check('the streaming refusal renders a fractional rate rather than raising',
        wok == true and wtxt ~= nil and has(wtxt, '192024') and has(wtxt, 'use FRAME'),
        tostring(wtxt))
  -- The SECOND wording, for a build that cannot say what the top rate delivers. Both branches format
  -- the rate, so both need the same treatment.
  local svdel = sdec.fs_delivered
  sdec.fs_delivered = nil
  local w2ok, w2 = pcall(function() return sdec.mode_why() end)
  sdec.fs_delivered = svdel
  check('...and so does the shorter wording behind it',
        w2ok == true and w2 ~= nil and has(w2, '192024') and has(w2, 'too fast to stream'),
        tostring(w2))

  sdec.force_baud, sdec.baud, sdec.res, sdec.snapped = svb, svbaud, svres, svsnap
  sdec.capmode, sdec.proto = svmode, svproto
  clearforce()
  display.setvalue(sdec.opt_baud, 0)
  sdec.options_apply()
  SRC.rd, SRC.ts, SRC.nsmp = svrd, svts, svn
end
test_baud_round()

-- ============================================================================
print('\nevery visible 7-bit glyph, in one payload (real code)')
-- ============================================================================
-- LONG covers the 26 letters once, lower case, plus digits and nine punctuation marks. This covers
-- ALL 94 visible glyphs, 0x21..0x7E: the pangram twice, cased, which is the trick of it -- 52 of the
-- 94 come free from two copies -- then the digits and every remaining symbol in code-point order.
--
-- Why it earns its place next to LONG rather than replacing it: a byte the decoder never sees is a
-- byte whose bit pattern was never framed. '~' is 0x7E = 1111110, six consecutive ones inside one
-- frame, and '!' is 0x21 = 0100001; those exercise the stop-bit search and the run-length logic
-- differently from the letters, and the shipped suites had no coverage of either.
--
-- LONG is left exactly as it is on purpose. ok_exact() compares txt(r) == LONG byte for byte, and
-- stress_serial.lua names its case 'long payload, 54 bytes' after the length of its own copy, so
-- editing the string in place would have made a test name state something untrue.
-- AN IMMEDIATELY-INVOKED FUNCTION, not a do...end block. The main chunk sits at Lua's
-- 200-local ceiling, and a do...end block still charges its locals to the enclosing
-- function's register budget -- only a new function body gets a fresh one. This form
-- also adds no name to the main chunk, which a `local function` would.
;(function()
  local ASCII94 = 'the quick brown fox jumps over the lazy dog. ' ..
                  'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. ' ..
                  '0123456789 !"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~'

  -- THE VECTOR CHECKS ITSELF FIRST. Without this a later edit could drop a glyph and every decode
  -- assertion below would still pass, having quietly stopped testing what it claims to.
  local a94seen, a94missing, a94i = {}, '', nil
  for a94i = 1, string.len(ASCII94) do
    a94seen[string.byte(ASCII94, a94i)] = true
  end
  for a94i = 33, 126 do              -- 0x21..0x7E, every visible glyph; 32 is space, a separator here
    if not a94seen[a94i] then a94missing = a94missing .. string.char(a94i) end
  end
  check('the vector covers all 94 visible 7-bit glyphs',
        a94missing == '' and string.len(ASCII94) == 133,
        string.format('%d bytes, missing [%s]', string.len(ASCII94), a94missing))

  local a94b, a94n = GEN_BYTES(ASCII94)
  local function a94_exact(r)
    return r ~= nil and r.nf == a94n and r.nbad == 0 and txt(r) == ASCII94
  end
  -- Its OWN detail, not detail(): that one divides by lgn, so reusing it here printed '133/65 bytes'
  -- and named LONG's length as this payload's expected count.
  local function a94_detail(r)
    if r == nil then return 'nil' end
    return string.format('%d/%d bytes %d err %s %s', r.nf, a94n, r.nbad,
                         tostring(sdec.baud), sdec.fmt_text())
  end

  -- 8N1 across the ladder, and 7E1/7O1 too: every byte here is <= 0x7E, so a seven-bit frame carries
  -- the whole payload without loss and must still come back byte-exact.
  for _, a94baud in ipairs({1200, 9600, 38400, 115200}) do
    local a94r = corrupt({bytes = a94b, baud = a94baud, fs = sdec.pick_fs(a94baud, 8)})
    check(string.format('all 94 glyphs decode exactly at %d baud 8N1', a94baud),
          a94_exact(a94r), a94_detail(a94r))
  end
  for _, a94f in ipairs({{1, '7E1'}, {2, '7O1'}}) do
    local a94r = corrupt({bytes = a94b, baud = 9600, fs = sdec.pick_fs(9600, 8),
                          nbits = 7, par = a94f[1]})
    check('all 94 glyphs decode exactly at 9600 ' .. a94f[2], a94_exact(a94r), a94_detail(a94r))
  end

  -- The two extremes of run length in this payload, asserted as data rather than as a claim: '~'
  -- (0x7E) is the longest run of ones inside a frame and '!' (0x21) among the sparsest.
  GEN_RESEED(9494)
  local a94nr = corrupt({bytes = a94b, baud = 9600, fs = sdec.pick_fs(9600, 8), noise = 0.15})
  check('all 94 glyphs survive 15 % noise', a94_exact(a94nr), a94_detail(a94nr))
  check('and the payload really does contain the awkward ones (0x7E, 0x21, 0x5C)',
        a94seen[126] and a94seen[33] and a94seen[92], 'tilde / bang / backslash')

  -- ============================================================================
  print('\n7E1 with no idle gap, captured from a mid-byte start (real code)')
  -- ============================================================================
  -- THE HARDWARE DEFECT OF 2026-08-19, reproduced offline. v78 (94 glyphs, 7E1, gap = 0) captured
  -- through the app returned 8N1 on four runs in eight, with ZERO flagged frames and every byte
  -- carrying a spurious bit 7 -- 47 of 48 bytes had bit 7 equal to the parity of their low seven, and
  -- the one exception was the FIRST frame. 8N1 is a genuinely self-consistent reading of a 7E1
  -- waveform, so there was no framing error to report and nothing was flagged.
  --
  -- It needed hardware only to be NOTICED. The mechanism is entirely reproducible here: start the
  -- window part-way through a frame on a gapless stream, and the misaligned head used to veto the
  -- parity vote. gap = 0 matters -- with idle between bytes the framer resynchronises immediately.
  do
    -- Window offsets are taken DEEP INTO THE PAYLOAD, at fractional bit positions. A first attempt
  -- sliced only a few bit times in and proved nothing -- it landed in the generator's lead-in idle,
  -- where the framer anchors cleanly, so it passed under the OLD policy too. Verified to
  -- discriminate: with par_skiphead = 0 and par_minfrac = 1.0 restored, 21 of these 60 offsets are
  -- read as 8N1-with-bit-7; with the shipped values, none are. That 35 % also matches the 4-in-8
  -- seen on hardware.
  local a94g = {bytes = a94b, baud = 9600, fs = sdec.pick_fs(9600, 8), nbits = 7, par = 1, gap = 0}
  local grd, gts, gnc, gn = GEN(a94g)
  local sabit = a94g.fs / a94g.baud
  local nbad8, nchecked, worst = 0, 0, ''
  local a94off
  for a94off = 0, 59 do
    local s0 = 1 + math.floor(gn * 0.15 + a94off * sabit / 3.0)
    local w, wn = {}, 0
    local i
    for i = s0, gn do wn = wn + 1; w[wn] = grd[i] end
    if wn > 2000 then
      nchecked = nchecked + 1
      analyse(w, wn, a94g.fs)
      sdec.decode_from(w, wn)
      local rr = sdec.res
      -- The failure signature: called 8N1, with bit 7 set on bytes that are really 7-bit characters.
      if rr ~= nil and rr.nbits == 8 then
        local hi, k = 0, nil
        for k = 1, rr.nf do
          local v = rr.vals[k]
          if v ~= nil and v >= 128 then hi = hi + 1 end
        end
        if hi > 2 then
          nbad8 = nbad8 + 1
          worst = string.format('offset %d: 8N1, %d of %d bytes carry bit 7', a94off, hi, rr.nf)
        end
      end
    end
  end
  check('a gapless 7E1 stream is never read as 8N1-with-bit-7, at any mid-frame window start',
        nbad8 == 0 and nchecked >= 50,
        string.format('%d of %d offsets failed  %s', nbad8, nchecked, worst))
  end

end)()
print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

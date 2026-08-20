-- stress_serial.lua -- push the REAL decoder at deliberately bad signals and report
-- where it breaks.
--
-- tools/test_serial.lua asserts correct behaviour on cases we understand. This does
-- the opposite job: it sweeps hostile conditions looking for cases we do NOT
-- understand yet, and it separates the two things that matter:
--
--   RAISED   the decoder threw. Always a defect -- these run inside a touch handler
--            on the instrument, and an unguarded raise there is a dead button.
--   WRONG    it returned confidently and the bytes are wrong. A defect unless the
--            waveform is genuinely ambiguous.
--   DEGRADED it returned fewer bytes, or refused. Acceptable on a bad enough signal;
--            the point is that it SAYS so rather than inventing data.
--
-- Run from the repo root:  lua tools/stress_serial.lua [pattern]
-- A pattern filters case names, e.g. `lua tools/stress_serial.lua spike`.

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)          -- logging off: this is about the decoder, not the key

-- SDEC_ANYWIDTH=1 widens the automatic search to 5, 6 and 9 data bits, which is what the
-- options form's "Auto (any width)" does. Running the sweep both ways is how the claim
-- "fewer candidate formats is more tolerant of noise" gets measured instead of asserted.
if os.getenv('SDEC_ANYWIDTH') == '1' then sdec.widths_any = true end

-- SDEC_PROBE_N caps how many samples the format search's ranking probes look at. The search is
-- 18 framing passes per candidate over up to ~20 candidates, and it measured 4.376 s on the
-- instrument against a 500 ms latency budget -- so truncating the RANKING (not the final decode)
-- is the obvious economy. Whether it is a SAFE economy is exactly what this suite can answer,
-- because a cap that damages discrimination shows up here as a WRONG, on waveforms built to
-- make the search fail. Sweep it before choosing a default.
local PROBE_N = tonumber(os.getenv('SDEC_PROBE_N') or '')
if PROBE_N ~= nil and PROBE_N > 0 then sdec.ua_probe_n = PROBE_N end

local FILTER = arg and arg[1]

local nraise, nwrong, ndeg, nok = 0, 0, 0, 0
local raised, wrong = {}, {}

local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
end

-- Run the whole chain on a sample array and report what came back.
--   name    what is being stressed
--   want    the byte array that was transmitted, or nil to accept anything
--   expect  'exact'    every byte must come back and the baud must be right
--           'partial'  fewer bytes is fine, wrong bytes are not
--           'baud'     badly damaged wire: byte loss accepted, the RATE must be right
--           'warn'     wire too damaged to decode: the panel must SAY the wire is bad
--           'refuse'   out of range: a confident answer is the failure
--           'any'      only "did not raise" is asserted
local function relnear(a, b, frac)
  return a ~= nil and b ~= nil and b ~= 0 and math.abs(a / b - 1) <= frac
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end

-- The baud rate the waveform was generated at, for expect = 'baud'.
local wantbaud = nil

local function attempt(name, rd, nsmp, fs, want, expect)
  if FILTER ~= nil and not string.find(name, FILTER, 1, true) then return end

  sdec.acq_fs = fs
  sdec.fs = fs
  local ok, res, baud, note, lvok
  local pok, perr = pcall(function()
    -- HONOUR the level-detection verdict, exactly as sdec.acquire() does. Ignoring it
    -- and decoding anyway tested a path the app never takes, and made every drifting
    -- signal look like a decoder defect when the decoder had already refused it.
    lvok = sdec.sig_levels(rd, nsmp)
    if not lvok then
      sdec.res, sdec.baud, sdec.bittime = nil, nil, nil
      return
    end
    sdec.sig_edges(rd, nsmp)
    sdec.sig_idle(rd, nsmp)
    ok = sdec.decode_from(rd, nsmp)
    res, baud = sdec.res, sdec.baud
    note = sdec.fmt_note or sdec.baud_note
    -- Everything the UI would do with the result, since a decode that cannot be
    -- PRESENTED is just as broken as one that cannot be produced.
    sdec.summary(1); sdec.summary(2); sdec.summary(3)
    sdec.ua_text_line(1, 80); sdec.ua_hex_line(1, 16)
    sdec.ui_note_text(); sdec.ui_npages(); sdec.ui_field_values()
    -- BOTH protocol layers, on every hostile case, because the View button reaches
    -- both from any capture -- so "does the LIN frame layer survive 20 % spiked
    -- garbage?" is a question every case here answers for free.
    if sdec.mi_parse ~= nil then sdec.mi_parse() end
    if sdec.li_parse ~= nil then sdec.li_parse() end
  end)

  if not pok then
    nraise = nraise + 1
    raised[table.getn(raised) + 1] = name .. ': ' .. tostring(perr)
    print(string.format('  RAISED    %-52s %s', name, tostring(perr)))
    return
  end

  local nf, nbad = 0, 0
  if res ~= nil then nf, nbad = res.nf, res.nbad end
  local nw = 0
  if want ~= nil then nw = table.getn(want) end

  -- Longest run of the payload that came back in order, ANYWHERE in the result.
  --
  -- Not a prefix from byte one: a capture that begins on a start bit has no edge for
  -- the first frame's leading transition, so losing exactly that byte is the physically
  -- correct answer, not a defect. Scoring from byte one called it wrong.
  local nmatch = 0
  if res ~= nil and want ~= nil and nw > 0 then
    local a, b
    for a = 1, nf do
      for b = 1, nw do
        if res.vals[a] == want[b] then
          local k = 0
          while a + k <= nf and b + k <= nw and res.vals[a + k] == want[b + k] do
            k = k + 1
          end
          if k > nmatch then nmatch = k end
        end
      end
    end
  end

  local verdict
  if expect == 'any' then
    verdict = 'ok'
  elseif expect == 'refuse' then
    -- Must NOT return a confident answer. Refusing, or returning nothing, is the pass.
    if res == nil or nf == 0 then verdict = 'ok' else verdict = 'wrong' end
  elseif res == nil or nf == 0 then
    verdict = 'degraded'
  elseif expect == 'warn' then
    -- Badly damaged wire. The requirement is not a correct decode, it is that the panel
    -- SAYS the wire is bad -- silence would read as a clean measurement.
    if has(sdec.ui_note_text(), 'WARNING') or has(sdec.ui_note_text(), 'NOTE')
       or (note ~= nil) then verdict = 'ok' else verdict = 'wrong' end
  elseif expect == 'baud' then
    -- Byte-level damage accepted; the reported RATE must still be right.
    if baud ~= nil and want ~= nil and nmatch >= 2 and relnear(baud, wantbaud, 0.03) then
      verdict = 'ok'
    else
      verdict = 'wrong'
    end
  elseif expect == 'exact' then
    if nf == nw and nmatch == nw and nbad == 0 then verdict = 'ok'
    elseif nmatch >= nf - 1 and nf <= nw then verdict = 'degraded'
    else verdict = 'wrong' end
  else -- partial
    -- Every byte returned must be a byte that was sent, contiguously.
    --
    -- A result that FLAGS its own errors counts as degraded rather than wrong, however
    -- mangled the bytes are. Silent corruption is the thing worth calling a defect: a
    -- dump with seven of fourteen frames marked bad tells the operator exactly what it
    -- knows, and that is the honest outcome on a line with 20 % of its samples spiked.
    if nmatch >= nf and nbad == 0 then verdict = 'ok'
    elseif nmatch >= 2 or nbad > 0 then verdict = 'degraded'
    else verdict = 'wrong' end
  end

  local detail = string.format('%s  %d/%d bytes  %d err  %s',
      tostring(baud), nf, nw, nbad, sdec.fmt_text())
  if verdict == 'ok' then
    nok = nok + 1
    print(string.format('  ok        %-52s %s', name, detail))
  elseif verdict == 'degraded' then
    ndeg = ndeg + 1
    print(string.format('  DEGRADED  %-52s %s', name, detail))
  else
    nwrong = nwrong + 1
    wrong[table.getn(wrong) + 1] = name .. ': ' .. detail
    print(string.format('  WRONG     %-52s %s   got %q', name, detail,
          string.sub(GEN_STR(res.vals, math.min(nf, 24)), 1, 24)))
  end
end

-- Generate and attempt in one step.
local function case(name, opts, expect, mangle)
  GEN_RESEED(20250812)
  clearforce()
  wantbaud = opts.baud or 9600
  local rd, ts, nc, nsmp = GEN(opts)
  if mangle ~= nil then mangle(rd, nsmp) end
  attempt(name, rd, nsmp, opts.fs or 1000000, opts.bytes, expect or 'exact')
end

local function forced(name, opts, mangle, fb, fbits, fpar)
  GEN_RESEED(20250812)
  clearforce()
  wantbaud = opts.baud or 9600
  local rd, ts, nc, nsmp = GEN(opts)
  if mangle ~= nil then mangle(rd, nsmp) end
  sdec.force_baud  = fb or opts.baud
  sdec.force_nbits = fbits or opts.nbits or 8
  sdec.force_par   = fpar or opts.par or 0
  attempt('forced: ' .. name, rd, nsmp, opts.fs or 1000000, opts.bytes, 'partial')
  clearforce()
end


local HELLO = GEN_BYTES('Hello, World!')
local LONG = GEN_BYTES('The quick brown fox jumps over the lazy dog 0123456789')
local function rep(v, k)
  local t, i = {}, 0
  for i = 1, k do t[i] = v end
  return t
end

-- ============================================================================
print('\nnoise amplitude sweep (3.3 V swing, hysteresis is 15 % = 0.5 V)')
-- ============================================================================
local amp
for _, amp in ipairs({0.1, 0.3, 0.5, 0.8, 1.0, 1.3, 1.6, 2.5, 4.0, 8.0}) do
  case(string.format('noise %.1f Vpk (%.0f %% of swing)', amp, 100 * amp / 3.3),
       {bytes = HELLO, baud = 9600, fs = 100000, noise = amp}, 'partial')
end

-- ============================================================================
print('\nimpulse spikes (count x amplitude x width)')
-- ============================================================================
local sp
for _, sp in ipairs({{8, 25, 2}, {40, 25, 2}, {8, 25, 6}, {8, 25, 20},
                     {200, 10, 2}, {8, 200, 2}, {60, 5, 8}}) do
  local n, a, w = sp[1], sp[2], sp[3]
  -- Wide spike trains corrupt a large share of the samples -- sixty 8-sample spikes is
  -- 24 % of this capture -- so the rate is the requirement and byte damage is expected.
  local exp = 'partial'
  if n * w >= 300 then exp = 'baud' end
  case(string.format('%d spikes  %d V  %d samples wide', n, a, w),
       {bytes = HELLO, baud = 9600, fs = 100000}, exp,
       function(rd, ns) GEN_SPIKES(rd, ns, n, a, w) end)
end

-- ============================================================================
print('\novershoot and ringing (unterminated line / reactive load)')
-- ============================================================================
local rg
for _, rg in ipairs({0.15, 0.35, 0.6, 0.9}) do
  case(string.format('ringing %.0f %% overshoot', 100 * rg),
       {bytes = HELLO, baud = 9600, fs = 100000}, 'partial',
       function(rd, ns) GEN_RING(rd, ns, rg, 4, 3) end)
end
case('ringing at the bit rate itself', {bytes = HELLO, baud = 9600, fs = 100000},
     'partial', function(rd, ns) GEN_RING(rd, ns, 0.4, 10.4, 6) end)

-- ============================================================================
print('\nbaseline drift (ground bounce, thermal, common mode)')
-- ============================================================================
local dr
for _, dr in ipairs({{0.5, 1.5}, {1.0, 1.5}, {1.5, 1.5}, {1.0, 12}, {1.0, 60}}) do
  -- 1 V of wander on a 3.3 V swing exceeds the 0.5 V hysteresis budget, and the
  -- threshold is decided ONCE for the whole capture -- so levels really do cross it in
  -- both directions. The requirement is that the panel says the baseline is unstable,
  -- not that the bytes survive.
  local exp = 'partial'
  if dr[1] >= 1.0 then exp = 'warn' end
  case(string.format('drift %.1f V over %.0f cycles', dr[1], dr[2]),
       {bytes = HELLO, baud = 9600, fs = 100000}, exp,
       function(rd, ns) GEN_DRIFT(rd, ns, dr[1], dr[2]) end)
end

-- ============================================================================
print('\nslow edges (long cable, RC loading, opto-isolator)')
-- ============================================================================
local ri
for _, ri in ipairs({2, 4, 6, 8, 10}) do
  -- 10.4 samples per bit at 9600 / 100 kS/s, so rise = 8 is ~77 % of a bit cell.
  case(string.format('rise %d samples (%.0f %% of a bit)', ri, 100 * ri / 10.42),
       {bytes = HELLO, baud = 9600, fs = 100000, rise = ri}, 'partial')
end

-- ============================================================================
print('\nlogic families and levels')
-- ============================================================================
case('RS-232 +-12 V inverted', {bytes = HELLO, baud = 9600, fs = 100000,
     lo = -12, hi = 12, invert = true})
case('RS-232 asymmetric -9 / +6 V', {bytes = HELLO, baud = 9600, fs = 100000,
     lo = -9, hi = 6, invert = true})
case('1V8 CMOS', {bytes = HELLO, baud = 9600, fs = 100000, lo = 0, hi = 1.8})
case('0.15 V swing (just above the 0.10 V floor)',
     {bytes = HELLO, baud = 9600, fs = 100000, lo = 0, hi = 0.15}, 'partial')
case('0.05 V swing (below the floor -- must refuse)',
     {bytes = HELLO, baud = 9600, fs = 100000, lo = 0, hi = 0.05}, 'partial')
case('5 V TTL riding a +2 V offset',
     {bytes = HELLO, baud = 9600, fs = 100000, lo = 2, hi = 7})
-- Clipped: the signal exceeds the range and the ADC saturates flat.
case('clipped flat-topped (signal past full scale)',
     {bytes = HELLO, baud = 9600, fs = 100000, lo = -6, hi = 16}, 'partial',
     function(rd, ns)
       local i
       for i = 1, ns do
         if rd[i] > 10 then rd[i] = 10 end
         if rd[i] < -10 then rd[i] = -10 end
       end
     end)

-- ============================================================================
print('\nsamples per bit, from comfortable down to the wall')
-- ============================================================================
local sb
for _, sb in ipairs({20, 10, 8, 6, 5, 4, 3.5, 3, 2.5}) do
  local baud = math.floor(1000000 / sb)
  case(string.format('%.1f samples/bit (%d baud at 1 MS/s)', sb, baud),
       {bytes = HELLO, baud = baud, fs = 1000000}, 'partial')
end

-- ============================================================================
print('\nbaud rate extremes and off-nominal rates')
-- ============================================================================
case('110 baud', {bytes = HELLO, baud = 110, fs = 1000}, 'partial')
case('921600 baud at 1 MS/s (1.08 sa/bit -- must refuse)',
     {bytes = HELLO, baud = 921600, fs = 1000000}, 'refuse')
case('400000 baud at 1 MS/s (2.5 sa/bit -- past the cap)',
     {bytes = HELLO, baud = 400000, fs = 1000000}, 'refuse')
case('115200 baud at 1 MS/s', {bytes = HELLO, baud = 115200, fs = 1000000})
case('230400 baud at 1 MS/s', {bytes = HELLO, baud = 230400, fs = 1000000}, 'partial')
-- A transmitter running off nominal. 2 % is the snap tolerance, so 1.5 % must snap
-- and 4 % must NOT be reported as a standard rate.
case('9600 baud 1.5 % fast (must still snap)',
     {bytes = HELLO, baud = 9744, fs = 100000}, 'partial')
case('9600 baud 4 % slow (must not claim a standard rate)',
     {bytes = HELLO, baud = 9216, fs = 100000}, 'partial')
case('non-standard 7000 baud', {bytes = HELLO, baud = 7000, fs = 100000}, 'partial')

-- ============================================================================
print('\ncapture framing: truncation, gaps, payload shape')
-- ============================================================================
case('no lead-in idle at all (capture starts on a start bit)',
     {bytes = HELLO, baud = 9600, fs = 100000, lead = 0, tail = 20}, 'partial')
case('gapless stream (no idle anywhere)',
     {bytes = HELLO, baud = 9600, fs = 100000, lead = 2, gap = 0, tail = 2}, 'partial')
case('cut off mid-frame', {bytes = HELLO, baud = 9600, fs = 100000, n = 900},
     'partial')
case('cut off after half a byte', {bytes = HELLO, baud = 9600, fs = 100000, n = 250},
     'partial')
case('one byte only', {bytes = {0x41}, baud = 9600, fs = 100000}, 'partial')
case('two bytes only', {bytes = {0x41, 0x42}, baud = 9600, fs = 100000}, 'partial')
case('huge idle then one byte at the very end',
     {bytes = {0x41}, baud = 9600, fs = 100000, lead = 900, tail = 2}, 'partial')
case('long payload, 54 bytes', {bytes = LONG, baud = 9600, fs = 100000})
case('wide inter-byte gaps (11 bit times)',
     {bytes = HELLO, baud = 9600, fs = 100000, gap = 11}, 'partial')
case('gaps just over maxmult (13 bit times)',
     {bytes = HELLO, baud = 9600, fs = 100000, gap = 13}, 'partial')

-- ============================================================================
print('\npathological payloads (the genuinely ambiguous ones)')
-- ============================================================================
case('all 0x00', {bytes = rep(0x00, 10), baud = 9600, fs = 100000}, 'partial')
case('all 0xFF', {bytes = rep(0xFF, 10), baud = 9600, fs = 100000}, 'partial')
case('all 0x55 (square wave)', {bytes = rep(0x55, 10), baud = 9600, fs = 100000},
     'partial')
case('all 0xAA', {bytes = rep(0xAA, 10), baud = 9600, fs = 100000}, 'partial')
case('alternating 0x00 / 0xFF', {bytes = {0, 255, 0, 255, 0, 255, 0, 255},
     baud = 9600, fs = 100000}, 'partial')
case('one repeated byte, 30 times', {bytes = rep(0x5A, 30), baud = 9600, fs = 100000},
     'partial')

-- ============================================================================
print('\nformats')
-- ============================================================================
case('7E1', {bytes = GEN_BYTES('Hello there'), baud = 9600, fs = 100000, nbits = 7,
     par = 1}, 'partial')
case('7O1', {bytes = GEN_BYTES('Hello there'), baud = 9600, fs = 100000, nbits = 7,
     par = 2}, 'partial')
case('8E1', {bytes = HELLO, baud = 9600, fs = 100000, par = 1}, 'partial')
case('8N2', {bytes = HELLO, baud = 9600, fs = 100000, nstop = 2}, 'partial')
-- 5 and 6 data bits at EVERY gap. These are the rare widths, heavily biased against in
-- the search because a shorter frame tiles a longer one -- 6N1 plus a 2-bit gap is exactly
-- an 8N1 frame and both score 12 -- so the bias and ua_refine_width's walk back down have
-- to be exercised together, at every gap. A masking bug in that walk returned 6N1 traffic
-- as 7N1 with every byte 64 too large and ZERO framing errors, and no case covered it.
local rw, rg
-- Forced, so they run identically whatever the width switch says: a forced width bypasses
-- the search, which is the point of offering 5 and 6 on the form at all.
for _, rw in ipairs({5, 6}) do
  for _, rg in ipairs({0, 1, 2, 3}) do
    local pay = {1, 2, 3, 40, 5, 60, 7, 8, 9, 10, 11, 12}
    if rw == 5 then pay = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12} end
    forced(string.format('%dN1 with a %d-bit inter-byte gap', rw, rg),
           {bytes = pay, baud = 9600, fs = 100000, nbits = rw, gap = rg}, nil,
           9600, rw, 0)
  end
end
-- Bit 8 must VARY. Every value over 255 makes the ninth data bit a constant 1, which
-- is genuinely indistinguishable from a stop bit one cell earlier -- so an all-high
-- payload tests the ambiguity, not the format.
case('9N1 with a varying ninth bit',
     {bytes = {0x100, 0x00F, 0x1FF, 0x055, 0x123, 0x001, 0x1AA, 0x0C3, 0x142, 0x03C},
      baud = 9600, fs = 100000, nbits = 9}, 'partial')

-- ============================================================================
print('\ncombined worst case (everything at once)')
-- ============================================================================
case('noise + spikes + ringing + drift, 9600',
     {bytes = LONG, baud = 9600, fs = 100000, noise = 0.4}, 'partial',
     function(rd, ns)
       GEN_SPIKES(rd, ns, 20, 20, 3)
       GEN_RING(rd, ns, 0.3, 4, 3)
       GEN_DRIFT(rd, ns, 0.5, 2)
     end)
case('noise + spikes + ringing + drift, 115200',
     {bytes = LONG, baud = 115200, fs = 1000000, noise = 0.4}, 'partial',
     function(rd, ns)
       GEN_SPIKES(rd, ns, 20, 20, 3)
       GEN_RING(rd, ns, 0.3, 4, 3)
       GEN_DRIFT(rd, ns, 0.5, 2)
     end)
case('RS-232 with everything wrong', {bytes = LONG, baud = 9600, fs = 100000,
     lo = -12, hi = 9, invert = true, noise = 2.0, rise = 5}, 'partial',
     function(rd, ns)
       GEN_SPIKES(rd, ns, 15, 40, 4)
       GEN_DRIFT(rd, ns, 3, 2)
     end)

-- ============================================================================
print('\nFORCED wire parameters -- what the operator does when they KNOW')
-- ============================================================================
-- The auto-detector is a good default, not the only path. On a badly damaged line it
-- can pick the wrong frame shape, and someone who knows the device is running 9600 8N1
-- should not have to argue with it -- so these are the same hostile waveforms with the
-- parameters locked down. Forcing the baud rate also skips the pulse-width fit
-- ENTIRELY, which is the stage impulse noise captures, so it is the strongest lever
-- available on a spiky signal.
forced('60 spikes 5 V 8 wide', {bytes = HELLO, baud = 9600, fs = 100000},
       function(rd, ns) GEN_SPIKES(rd, ns, 60, 5, 8) end)
forced('200 spikes 10 V 2 wide', {bytes = HELLO, baud = 9600, fs = 100000},
       function(rd, ns) GEN_SPIKES(rd, ns, 200, 10, 2) end)
forced('everything wrong at once', {bytes = LONG, baud = 9600, fs = 100000, noise = 0.4},
       function(rd, ns)
         GEN_SPIKES(rd, ns, 20, 20, 3)
         GEN_RING(rd, ns, 0.3, 4, 3)
         GEN_DRIFT(rd, ns, 0.5, 2)
       end)
forced('1 V drift over 12 cycles', {bytes = HELLO, baud = 9600, fs = 100000},
       function(rd, ns) GEN_DRIFT(rd, ns, 1.0, 12) end)
forced('9N1, which auto no longer searches',
       {bytes = {0x100, 0x00F, 0x1FF, 0x055, 0x123, 0x001, 0x1AA, 0x0C3, 0x142, 0x03C},
        baud = 9600, fs = 100000, nbits = 9}, nil, 9600, 9, 0)
forced('8E1 with heavy noise',
       {bytes = HELLO, baud = 9600, fs = 100000, par = 1, noise = 1.0}, nil, 9600, 8, 1)
forced('115200 with noise and ringing',
       {bytes = LONG, baud = 115200, fs = 1000000, noise = 0.5},
       function(rd, ns) GEN_RING(rd, ns, 0.3, 4, 3) end)

-- ============================================================================
print('\ndegenerate captures (must refuse, never raise)')
-- ============================================================================
attempt('empty array', {}, 0, 100000, nil, 'any')
attempt('one sample', {1.0}, 1, 100000, nil, 'any')
attempt('two samples', {0.0, 3.3}, 2, 100000, nil, 'any')
attempt('flat line at 0 V', (function() local t = {} local i
  for i = 1, 2000 do t[i] = 0 end return t end)(), 2000, 100000, nil, 'any')
attempt('flat line at 3.3 V', (function() local t = {} local i
  for i = 1, 2000 do t[i] = 3.3 end return t end)(), 2000, 100000, nil, 'any')
attempt('pure noise, no signal', (function() local t = {} local i
  GEN_RESEED(7) for i = 1, 4000 do t[i] = math.random() end return t end)(),
  4000, 100000, nil, 'any')
attempt('a single 3.3 V step and nothing else', (function() local t = {} local i
  for i = 1, 2000 do if i < 1000 then t[i] = 0 else t[i] = 3.3 end end
  return t end)(), 2000, 100000, nil, 'any')
attempt('one clean square cycle only', (function() local t = {} local i
  for i = 1, 400 do
    if math.fmod(math.floor((i - 1) / 100), 2) == 0 then t[i] = 0 else t[i] = 3.3 end
  end return t end)(), 400, 100000, nil, 'any')
-- Holes in the sample array. acq_copy reads buf.readings index by index, and a
-- firmware that returned fewer readings than buf.n claimed would leave nils.
case('a nil hole mid-capture', {bytes = HELLO, baud = 9600, fs = 100000},
     'partial', function(rd, ns) rd[math.floor(ns / 2)] = nil end)
case('20 nil holes scattered', {bytes = HELLO, baud = 9600, fs = 100000},
     'partial', function(rd, ns)
       local i
       for i = 1, 20 do rd[math.floor(ns * i / 21)] = nil end
     end)

-- ---------------------------------------------------------------------------
-- TIMING JITTER -- the impairment aimed at the BAUD DETECTOR, not the framing
-- ---------------------------------------------------------------------------
-- Every cell boundary displaced independently by up to +/-N% of a unit interval. This attacks
-- sig_bittime where it is weakest: it fits the greatest common period of the observed pulse
-- widths, so jitter makes every pulse a slightly wrong multiple and the GCD of the set can
-- collapse far below the true bit time. No amount of amplitude noise reproduces that -- a spike
-- adds a spurious edge, whereas jitter moves the REAL ones.
--
-- MEASURED ACROSS 24 SEEDS at 9600 baud, 8 samples/bit. One seed is not a tolerance: a lucky draw
-- supports "good to +/-25 % UI" while the suite's own seed produces a CONFIDENT WRONG ANSWER at that
-- level -- baud reported as 9366 (not snapped to any standard rate), 13 of 13 bytes, ZERO framing
-- errors, two bytes corrupted.
--
--     jitter   exact   flagged wrong   SILENTLY WRONG
--     +/- 5%   24/24         0                0
--     +/-10%   24/24         0                0
--     +/-15%   24/24         0                0
--     +/-20%   23/24         0                1
--     +/-25%   14/24         6                4
--     +/-30%    2/24        12               10
--
-- So the honest figure is RELIABLE TO +/-15 % UI, with the first silent wrong answer at +/-20 %.
-- The last column is the one that matters: past +/-20 % the decoder does not merely fail, it
-- produces zero framing errors alongside wrong bytes -- because jitter moves the real edges, so
-- every frame remains internally consistent at whatever bit time the GCD collapsed to.
--
-- Expectations below therefore stop at 15 % for 'exact'. A regression that pushes the silent-wrong
-- threshold DOWN is the thing this is guarding, and it would show up as a WRONG at 10 or 15 %.
case('+/-10 % UI timing jitter', {bytes = HELLO, baud = 9600, fs = 100000, jitter = 0.10})
case('+/-15 % UI timing jitter -- the reliable limit', {bytes = HELLO, baud = 9600,
     fs = 100000, jitter = 0.15})
-- Past the reliable limit. 'any' rather than 'partial' because the failure at 25 % is
-- seed-dependent and a suite that demanded a specific degradation would be asserting the seed.
case('+/-25 % UI timing jitter -- past the limit, seed-dependent',
     {bytes = HELLO, baud = 9600, fs = 100000, jitter = 0.25}, 'any')
-- Past the cliff. The requirement is NOT a correct decode -- it is that the failure is visible,
-- which for jitter means framing errors rather than a confident wrong byte stream.
case('+/-40 % UI jitter -- past the cliff, must FLAG not fabricate',
     {bytes = HELLO, baud = 9600, fs = 100000, jitter = 0.40}, 'any')
-- Jitter on top of a slow line, where a bit time is many samples and the displacement is
-- therefore many samples too -- so this is not the same test scaled down.
case('+/-20 % UI jitter at 1200 baud', {bytes = HELLO, baud = 1200, fs = 10000,
     jitter = 0.20}, 'any')
-- Jitter AND amplitude noise together, which is what a real bad wire looks like: the noise
-- moves the threshold crossing and the jitter moves the edge, and the two compound.
case('+/-15 % UI jitter plus 0.3 V noise',
     {bytes = HELLO, baud = 9600, fs = 100000, jitter = 0.15, noise = 0.3}, 'any')

-- ============================================================================
print('\nLIN bus: break fields, frame assembly and checksums')
-- ============================================================================
-- Scored at the FRAME layer, not the byte layer, because that is where LIN's own
-- failure modes live -- a missed break merges two frames, a false one splits one, and
-- both come back as bytes that decoded perfectly well.
--
-- WRONG here means one specific thing: the layer VALIDATED a frame whose data was never
-- transmitted. A frame it flags as bad, or does not report at all, is degraded -- the
-- checksum exists precisely so that damage is loud, and reporting the damage is the
-- correct behaviour, not a failure.
local function lincase(name, opts, expect)
  if FILTER ~= nil and not string.find(name, FILTER, 1, true) then return end
  GEN_RESEED(20250812)
  clearforce()
  local frames = opts.frames or {}
  local nwant = table.getn(frames)
  local baud = opts.baud or 19200
  local fs = opts.fs or 200000

  -- The hex string each frame's data should appear as, for the match test.
  local dhex, i, j = {}, nil, nil
  for i = 1, nwant do
    local d = frames[i].data or {}
    local t, m = {}, 0
    for j = 1, table.getn(d) do m = m + 1; t[m] = string.format('%02X', d[j]) end
    dhex[i] = table.concat(t, ' ', 1, m)
  end

  local rd, ts, nc, nsmp = GEN_LIN(opts)
  if opts.mangle ~= nil then opts.mangle(rd, nsmp) end

  sdec.acq_fs, sdec.fs = fs, fs
  -- LIN pins 8N1 and normal polarity, exactly as the options form does.
  sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, 0, 1
  sdec.force_invert = false
  sdec.proto = 'lin'

  local L, lvok
  local pok, perr = pcall(function()
    lvok = sdec.sig_levels(rd, nsmp)
    if not lvok then
      sdec.res, sdec.baud, sdec.bittime, sdec.lin = nil, nil, nil, nil
      return
    end
    sdec.sig_edges(rd, nsmp)
    sdec.sig_idle(rd, nsmp)
    sdec.decode_from(rd, nsmp)
    sdec.li_parse()
    L = sdec.lin
    -- Everything the panel would do with it.
    sdec.li_summary(); sdec.li_breaknote(); sdec.li_levelnote()
    sdec.ui_note_text(); sdec.ui_npages(); sdec.ui_field_values()
    local k
    for k = 1, 13 do sdec.li_line(k) end
  end)
  sdec.proto = 'uart'
  clearforce()

  if not pok then
    nraise = nraise + 1
    raised[table.getn(raised) + 1] = name .. ': ' .. tostring(perr)
    print(string.format('  RAISED    %-52s %s', name, tostring(perr)))
    return
  end

  local nfr, nbad, nmatch, bogus = 0, 0, 0, 0
  if L ~= nil then
    nfr, nbad = L.nframes, L.bad
    for i = 1, nwant do
      if dhex[i] ~= '' then
        for j = 1, L.n do
          if L.kind[j] == 'frame' and has(L.msg[j], dhex[i]) then
            nmatch = nmatch + 1
            break
          end
        end
      end
    end
    -- A frame the layer validated must correspond to something that was sent.
    for j = 1, L.n do
      if L.kind[j] == 'frame' then
        local found = false
        for i = 1, nwant do
          if dhex[i] ~= '' and has(L.msg[j], dhex[i]) then found = true end
        end
        if not found then bogus = bogus + 1 end
      end
    end
  end

  local verdict
  if expect == 'any' then
    verdict = 'ok'
    if bogus > 0 then verdict = 'wrong' end
  elseif bogus > 0 then
    verdict = 'wrong'
  elseif nmatch == nwant and nbad == 0 and nfr == nwant then
    verdict = 'ok'
  else
    verdict = 'degraded'
  end

  local detail = string.format('%s  %d/%d frames  %d bad  %d matched',
      tostring(sdec.baud), nfr, nwant, nbad, nmatch)
  if verdict == 'ok' then
    nok = nok + 1
    print(string.format('  ok        %-52s %s', name, detail))
  elseif verdict == 'degraded' then
    ndeg = ndeg + 1
    print(string.format('  DEGRADED  %-52s %s', name, detail))
  else
    nwrong = nwrong + 1
    wrong[table.getn(wrong) + 1] = name .. ': ' .. detail
    print(string.format('  WRONG     %-52s %s   %d validated frame(s) never sent',
          name, detail, bogus))
  end
end

-- Distinctive data, so a matched hex string cannot be a coincidence.
local LF1 = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
             {id = 0x22, data = {0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34}},
             {id = 0x05, data = {0x5A, 0xA5}}}
local LF8 = {{id = 0x30, data = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}},
             {id = 0x31, data = {0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01}}}

-- ---- the rate range LIN actually specifies: 1 to 20 kBd ----
lincase('LIN 19200, clean', {frames = LF1, baud = 19200, fs = 200000})
lincase('LIN 9600, clean', {frames = LF1, baud = 9600, fs = 100000})
lincase('LIN 19200 at 1 MS/s (52 sa/bit)', {frames = LF1, baud = 19200, fs = 1000000})
lincase('LIN 20000, the specified maximum', {frames = LF1, baud = 20000, fs = 200000})
lincase('LIN 2400, a slow segment', {frames = LF1, baud = 2400, fs = 20000})
lincase('LIN 1000, the specified minimum', {frames = LF1, baud = 1000, fs = 10000})
lincase('LIN 19200, 8-byte frames', {frames = LF8, baud = 19200, fs = 200000})

-- ---- the break field, which is the one thing no byte can express ----
lincase('break of 11 bits, the receiver minimum',
        {frames = LF1, baud = 19200, fs = 200000, nbreak = 11})
lincase('break of 13 bits, the transmitter minimum',
        {frames = LF1, baud = 19200, fs = 200000, nbreak = 13})
lincase('break of 30 bits', {frames = LF1, baud = 19200, fs = 200000, nbreak = 30})
-- 10 dominant bits is below the receiver minimum and, more to the point, is what a
-- 0x00 byte looks like. It must NOT be taken for a break; the frame is then unframed
-- bytes, which is honest.
lincase('break of 10 bits -- indistinguishable from a 0x00 byte',
        {frames = LF1, baud = 19200, fs = 200000, nbreak = 10}, 'any')
lincase('no break delimiter at all (delim = 0)',
        {frames = LF1, baud = 19200, fs = 200000, delim = 0}, 'any')
lincase('4-bit break delimiter', {frames = LF1, baud = 19200, fs = 200000, delim = 4})

-- ---- inter-byte and inter-frame spacing, all of it legal ----
lincase('2 bit times of inter-byte space',
        {frames = LF1, baud = 19200, fs = 200000, space = 2})
lincase('4 bit times of inter-byte space',
        {frames = LF1, baud = 19200, fs = 200000, space = 4})
lincase('no idle between frames at all (inter = 0)',
        {frames = LF1, baud = 19200, fs = 200000, inter = 0})
lincase('60 bit times between frames',
        {frames = LF1, baud = 19200, fs = 200000, inter = 60})

-- ---- data that fights the wire layer ----
-- All-zero data is the case that defeats sig_idle's longest-run prior, and next to a
-- break it is the case that defeats break detection by value alone.
lincase('all-zero data next to the break',
        {frames = {{id = 0x11, data = {0x00, 0x00, 0x00, 0x00}},
                   {id = 0x22, data = {0x00, 0x00}}}, baud = 19200, fs = 200000}, 'any')
lincase('all-ones data', {frames = {{id = 0x11, data = {0xFF, 0xFF, 0xFF, 0xFF}}},
        baud = 19200, fs = 200000}, 'any')
lincase('0x55 data, so every cell alternates',
        {frames = {{id = 0x11, data = {0x55, 0x55, 0x55, 0x55}}},
         baud = 19200, fs = 200000}, 'any')
lincase('data that contains a 0x55 sync pattern and a 0x00',
        {frames = {{id = 0x11, data = {0x00, 0x55, 0x00, 0x55}}},
         baud = 19200, fs = 200000}, 'any')

-- ---- diagnostic frames, which must use the classic checksum ----
lincase('master request 0x3C, classic checksum',
        {frames = {{id = 0x3C, data = {1, 2, 3, 4, 5, 6, 7, 8}, classic = true},
                   {id = 0x3D, data = {0x7F, 0x06, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55},
                    classic = true}}, baud = 19200, fs = 200000})
lincase('classic checksum on every frame (a LIN 1.x segment)',
        {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}, classic = true},
                   {id = 0x22, data = {0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34},
                    classic = true}}, baud = 19200, fs = 200000})

-- ---- headers with no response, and malformed headers ----
lincase('a header with no slave response between two good frames',
        {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
                   {id = 0x22, nodata = true},
                   {id = 0x05, data = {0x5A, 0xA5}}}, baud = 19200, fs = 200000},
        'any')
lincase('a corrupted sync byte', {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4},
        sync = 0x57}}, baud = 19200, fs = 200000}, 'any')
lincase('a PID with broken parity', {frames = {{id = 0x11, pid = 0x12,
        data = {0xA1, 0xB2, 0xC3, 0xD4}}}, baud = 19200, fs = 200000}, 'any')
lincase('a wrong checksum', {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4},
        csum = 0x00}}, baud = 19200, fs = 200000}, 'any')
lincase('a frame with no break, so it runs into the previous one',
        {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
                   {id = 0x22, data = {0xDE, 0xAD}, nobreak = true}},
         baud = 19200, fs = 200000}, 'any')

-- ---- a bad wire, on top of all of it ----
lincase('LIN with 5 % noise', {frames = LF1, baud = 19200, fs = 200000, noise = 0.3})
lincase('LIN with 15 % noise', {frames = LF1, baud = 19200, fs = 200000, noise = 0.9},
        'any')
lincase('LIN with 12 spikes at 25 V', {frames = LF1, baud = 19200, fs = 200000,
        mangle = function(rd, n) GEN_SPIKES(rd, n, 12, 25, 2) end}, 'any')
lincase('LIN with 40 % ringing', {frames = LF1, baud = 19200, fs = 200000,
        mangle = function(rd, n) GEN_RING(rd, n, 0.4, 4, 3) end}, 'any')
lincase('LIN with 1.5 V of baseline drift', {frames = LF1, baud = 19200, fs = 200000,
        mangle = function(rd, n) GEN_DRIFT(rd, n, 1.5, 2) end}, 'any')
lincase('LIN with slow 6-sample edges', {frames = LF1, baud = 19200, fs = 200000,
        rise = 6})
-- An undivided 12 V bus, which is the mistake the panel note exists for.
lincase('an undivided 12 V bus on the 10 V range',
        {frames = LF1, baud = 19200, fs = 200000, lo = 0, hi = 12.0}, 'any')
-- A single frame, which is the fewest the layer can be asked to work from.
lincase('one frame and nothing else',
        {frames = {{id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}}},
         baud = 19200, fs = 200000})
-- A capture that begins ON the first break's falling edge, so there is no mark run in
-- front of it and the wire layer cannot anchor there: frame 1 loses its break and becomes
-- unframed bytes, and frames 2 and 3 must still decode.
lincase('capture starting mid-frame', {frames = LF1, baud = 19200, fs = 200000,
        lead = 0}, 'any')

-- ============================================================================
print(string.format('\n%d ok   %d degraded   %d WRONG   %d RAISED',
      nok, ndeg, nwrong, nraise))
if nraise > 0 then
  print('\nRAISED -- always a defect:')
  local i
  for i = 1, table.getn(raised) do print('  ' .. raised[i]) end
end
if nwrong > 0 then
  print('\nWRONG -- confident and incorrect:')
  local i
  for i = 1, table.getn(wrong) do print('  ' .. wrong[i]) end
end

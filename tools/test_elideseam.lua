-- test_elideseam.lua -- the elision seam, offline, across the rate ladder.
--
-- WHY THIS FILE EXISTS. tools/test_serial.lua already asserts that a spliced record decodes both sides of
-- the seam and that "the seam costs no frame". Both pass. On the instrument, on 2026-10-17, they did not
-- hold: with elision finally firing, 18 of 120 cells came back with 33-73 % of their confident bytes
-- wrong, all of them elided cells, while 60 free-running control cells in the same lap were clean.
--
-- Three things the existing test does differently from the bench, each of which could be the whole
-- difference, and none of which it varies:
--
--   * it AUTO-DETECTS the rate. Every elided capture is FORCED, gap_elide() refusing without a rate.
--   * it splices two DIFFERENT payloads with 400 samples of idle between them. The bench plays one
--     LOOPING payload, so a seam joins the end of a pass to the start of the next and the payload index
--     has to wrap -- and elision leaves roughly one WINDOW of idle, not 400 samples.
--   * it runs one rate, 9600 Bd at 100 kS/s. The hardware failures start at exactly 4800 Bd and 2400 is
--     clean on the identical 10 ms window, so whatever this is keys on the rate and not the window.
--
-- So this reproduces the bench's experiment instead of a simplification of it: the real lorem payload, a
-- looping multi-pass waveform, idle elided down to the window, the rate forced, and the score taken with
-- bexp.match -- the same function the instrument puts on the panel, so the numbers compare directly with
-- the pay= field in the record.
--
--   lua tools/test_elideseam.lua

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp', 'bench/expect.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local pass, fail, failed = 0, 0, {}
local function check(what, cond, detail)
  if cond then
    pass = pass + 1
    print('  ok   ' .. what)
  else
    fail = fail + 1
    failed[table.getn(failed) + 1] = what
    print('  FAIL ' .. what .. '   ' .. tostring(detail or ''))
  end
end

-- ---------------------------------------------------------------------------
-- The waveform: P passes of one gap vector, concatenated, exactly as a looping arb plays it.
--
-- lead and tail are BIT TIMES and they ADD at the join: lead 600 with tail 10 gives 610 bit times of mark
-- between one pass's last stop bit and the next pass's first start bit, which is what make_vectors.lua:618
-- says the vectors render and why they are tabulated as 410/610/1010 rather than 400/600/1000.
-- ---------------------------------------------------------------------------
local function passes(payload, baud, fs, lead, tail, np)
  local by = GEN_BYTES(payload)
  local rd, n, i, p = {}, 0, nil, nil
  for p = 1, np do
    local r1, _, _, n1 = GEN({bytes = by, nbits = 8, par = 0, baud = baud, fs = fs,
                              gap = 0, lead = lead, tail = tail, loop = false})
    for i = 1, n1 do n = n + 1 rd[n] = r1[i] end
  end
  return rd, n
end

-- Elide: every run at the idle level of at least `winsamp` readings is cut down to `winsamp`.
--
-- THIS IS THE SHAPE THE PROGRAM PRODUCES, not a splice of two captures. The detector concludes the line
-- went quiet only after a window of silence has passed, so that much idle is already IN the record when
-- block 3 stops; recording resumes on the next crossing. So a seam keeps one window of mark on the
-- leading side and nothing on the trailing side, which is a legal idle line of exactly the length the
-- window names.
--
-- The idle level is taken from reading 1 rather than from sdec.idle: the lead is mark by construction, and
-- reading the app's own verdict here would make the fixture agree with the code under test.
-- `lat` is the RESUME LATENCY in readings: how much of the burst is missing because the recording
-- restarted after the crossing that released it rather than at it. Zero models a perfect splice, which is
-- what the first version of this file assumed and why it reproduced nothing.
local function elide(rd, n, winsamp, lat)
  local idle = rd[1]
  local out, m, i = {}, 0, 1
  local nseam = 0
  lat = lat or 0
  while i <= n do
    if rd[i] == idle then
      local j = i
      while j <= n and rd[j] == idle do j = j + 1 end
      local runlen = j - i
      local keep = runlen
      local drop = 0
      if runlen > winsamp then keep = winsamp nseam = nseam + 1 drop = lat end
      local k
      for k = 1, keep do m = m + 1 out[m] = idle end
      -- The latency eats the head of the NEXT burst, not the tail of the idle: the comparator fires on
      -- the burst's own first falling edge, so what is lost is the start bit that edge belongs to.
      i = j + drop
    else
      m = m + 1
      out[m] = rd[i]
      i = i + 1
    end
  end
  return out, m, nseam
end

local function analyse(rd, nsmp, fs)
  sdec.acq_fs = fs
  sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
end

-- One cell, the way brun.point runs one: force the rate, elide, truncate to sdec.n, decode, score.
local function cell(vid, payload, baud, fs, lead, tail, win, ncap, latsec)
  local rd, n = passes(payload, baud, fs, lead, tail, 5)
  local erd, en, nseam = elide(rd, n, win * fs, math.floor((latsec or 0) * fs))
  if en > ncap then en = ncap end          -- the record holds sdec.n readings and stops
  local kb, kf, kt = sdec.force_baud, sdec.fs, sdec.trigmode
  sdec.force_baud, sdec.fs, sdec.trigmode = baud, fs, 'free'
  sdec.force_nbits, sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil, nil
  sdec.acq_pretrig = nil
  sdec.proto, sdec.ui_mode = 'uart', 'text'
  analyse(erd, en, fs)
  local ok, why = sdec.decode_from(erd, en)
  local nm, nc = nil, nil
  if ok then nm, nc = bexp.match(sdec.res, vid) end
  local nf = (sdec.res ~= nil) and sdec.res.nf or 0
  sdec.force_baud, sdec.fs, sdec.trigmode = kb, kf, kt
  return {ok = ok, why = why, nm = nm, nc = nc, nf = nf, nseam = nseam,
          kept = en, raw = n, sabit = fs / baud}
end

-- ---------------------------------------------------------------------------
-- THE LADDER, and the windows the bench actually used on 2026-10-17. Taken from the record rather than
-- recomputed, so a change to the tier cannot quietly move the fixture off the case it reproduces.
-- ---------------------------------------------------------------------------
local LADDER = {
  {baud = 300,   fs = 2500,   win = 0.100, hw = 'CLEAN', hwpay = '225/228'},
  {baud = 1200,  fs = 10000,  win = 0.100, hw = 'CLEAN', hwpay = '221/221'},
  {baud = 2400,  fs = 20000,  win = 0.010, hw = 'CLEAN', hwpay = '223/231'},
  {baud = 4800,  fs = 40000,  win = 0.010, hw = 'BAD',   hwpay = '75/220'},
  {baud = 7200,  fs = 60000,  win = 0.010, hw = 'BAD',   hwpay = '51/210'},
  {baud = 9600,  fs = 80000,  win = 0.010, hw = 'BAD',   hwpay = '90/219'},
  {baud = 14400, fs = 120000, win = 0.010, hw = 'BAD',   hwpay = '65/197'},
  {baud = 19200, fs = 159806, win = 0.010, hw = 'BAD',   hwpay = '51/146'},
}

local NCAP = 20000                 -- sdec.n, the readings an elided record stops at

print('-- v98a elided offline, across the ladder: does the 4800 Bd edge reproduce? --')
print(string.format('  %-6s %-7s %-6s %-6s %-5s %-9s %-7s %-8s %s',
                    'baud', 'fs', 'win', 'sa/bit', 'seam', 'pay', 'frac', 'hw', 'hw pay'))
local v98a = bexp.bytes('v98a')
check('the payload is the one the instrument plays', v98a ~= nil and string.len(v98a) == 130,
      v98a ~= nil and string.len(v98a) or 'nil')

local results, li = {}, nil
for li = 1, table.getn(LADDER) do
  local L = LADDER[li]
  local r = cell('v98a', v98a, L.baud, L.fs, 600, 10, L.win, NCAP)
  r.L = L
  results[li] = r
  local frac = (r.nm ~= nil and r.nc ~= nil and r.nc > 0) and (r.nm / r.nc) or nil
  print(string.format('  %-6d %-7d %-6g %-6.2f %-5d %-9s %-7s %-8s %s',
                      L.baud, L.fs, L.win, r.sabit, r.nseam,
                      (r.nm ~= nil) and (tostring(r.nm) .. '/' .. tostring(r.nc)) or ('REFUSED'),
                      (frac ~= nil) and string.format('%.0f%%', frac * 100) or '-',
                      L.hw, L.hwpay))
end

-- ---------------------------------------------------------------------------
-- WHAT THIS FILE ASSERTS. Not "elision works" -- the instrument says it does not above 2400 Bd, and a
-- fixture that demanded success would just fail in sympathy without localising anything. What it asserts
-- is that the offline twin REPRODUCES the hardware split, because that is the property that makes the
-- twin worth owning: if it does, the defect is debuggable here; if it does not, the twin is missing the
-- mechanism and no amount of green offline means anything about the bench.
-- ---------------------------------------------------------------------------
local function frac(r)
  if r.nm == nil or r.nc == nil or r.nc < 1 then return nil end
  return r.nm / r.nc
end

-- The three rates the instrument decoded byte-exact must be byte-exact here too, or the fixture is not
-- modelling the working case and its verdict on the failing one is worthless.
local lowok, lowdetail = true, ''
for li = 1, 3 do
  local f = frac(results[li])
  if f == nil or f < 0.95 then lowok = false end
  lowdetail = lowdetail .. string.format('%d:%s ', LADDER[li].baud,
                                         (f ~= nil) and string.format('%.0f%%', f * 100) or 'nil')
end
check('the premise: 300, 1200 and 2400 Bd elide byte-exact offline, as they did on the instrument',
      lowok, lowdetail)

-- And the question. Stated as a comparison rather than as a pass, so the row reads the same whichever way
-- it falls and nobody has to re-derive what it meant.
local hiok, hidetail = true, ''
for li = 4, table.getn(LADDER) do
  local f = frac(results[li])
  if f == nil or f > 0.95 then hiok = false end
  hidetail = hidetail .. string.format('%d:%s ', LADDER[li].baud,
                                       (f ~= nil) and string.format('%.0f%%', f * 100) or 'nil')
end
-- A NOTE AND NOT A CHECK, deliberately. Whether the twin reproduces a hardware defect is a finding about
-- the twin, not a contract the twin breaks -- and a suite left permanently red over a diagnostic stops
-- being read at all, which costs more than the finding is worth. The contract this file enforces is the
-- premise above and the rotation property below; this line is the measurement it exists to report.
if hiok then
  print('  NOTE  a PERFECT splice reproduces the edge, which would be a surprise:  ' .. hidetail)
else
  print('  NOTE  a PERFECT splice does not reproduce the edge, and that is the point of this block:')
  print('        ' .. hidetail)
  print('        Hardware on 2026-10-17: 75/220, 51/210, 90/219, 65/197, 51/146 over the same rates.')
  print('        So splicing is not the defect. The resume-latency block below reproduces it from one')
  print('        constant-time parameter, which is what localises the fault to the restart and not')
  print('        to the decode.')
end

-- ---------------------------------------------------------------------------
print('\n-- a ROTATED record: can a ring wrap produce the fractions the instrument reported? --')
-- ---------------------------------------------------------------------------
-- WHY THIS IS THE NEXT THING TO TRY. The fixture above is a flat Lua array and it is byte-exact at every
-- rate, so decoding a spliced record is not the defect. The instrument's record is a RING: acq_fillmode
-- sets fillmode = 1, and acq_cap gives a 20 000-reading record only 100 readings of headroom at
-- pretrig = 0 (tsp/serial_core.tsp:1363-1370). stream_acquire's own comment says what happens then --
-- "because the record is fillmode = 1 it would not stop but WRAP, overwriting its own earliest bursts"
-- (tsp/serial_app.tsp:1073-1076) -- and the `have >= nsmp` exit that prevents it is tested ONCE PER POLL,
-- at ck_poll_s = 0.5 s. So the overrun is about 0.5 * duty * fs readings against 100 of headroom, which
-- is thousands at every rate and scales with fs.
--
-- A ROTATION IS NOT A PHASE SHIFT, which is the part worth being careful about: the payload loops, so a
-- cyclic shift of a CONTIGUOUS record would just be a different starting byte and bexp.match's shift
-- search would absorb it completely. What breaks is that a rotated record is [B|A] where A preceded B in
-- time -- two fragments each internally correct, whose payload indices are not contiguous across the
-- join. One shift fits the larger fragment and misses the other, which is why the failures are partial
-- rather than noise.
--
-- So this sweeps the rotation and asks whether the measured fractions are reachable at all. It does not
-- claim a particular rotation happened: that needs the instrument to record startindex and capacity,
-- which it does not yet.
local function rotate(rd, n, by)
  local out, i = {}, nil
  by = math.mod(by, n)
  for i = 1, n do out[i] = rd[math.mod(by + i - 1, n) + 1] end
  return out, n
end

local RB, RFS, RWIN = 9600, 80000, 0.010
local rrd, rn = passes(v98a, RB, RFS, 600, 10, 5)
local erd, en = elide(rrd, rn, RWIN * RFS)
if en > NCAP then en = NCAP end

print(string.format('  record is %d readings at %d Bd / %d S/s; hardware reported 90/219 = 41%%',
                    en, RB, RFS))
print(string.format('  %-8s %-6s %-10s %s', 'rot', 'bytes', 'pay', 'frac'))
local rots = {0, 500, 2000, 5000, 8000, 10000, 13600, 16000}
local best, worst, ri = nil, nil, nil
for ri = 1, table.getn(rots) do
  local by = rots[ri]
  local prd = erd
  local pn = en
  if by > 0 then prd, pn = rotate(erd, en, by) end
  local kb, kf, kt = sdec.force_baud, sdec.fs, sdec.trigmode
  sdec.force_baud, sdec.fs, sdec.trigmode = RB, RFS, 'free'
  sdec.force_nbits, sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil, nil
  sdec.acq_pretrig = nil
  analyse(prd, pn, RFS)
  local rok = sdec.decode_from(prd, pn)
  local nm, nc = nil, nil
  if rok then nm, nc = bexp.match(sdec.res, 'v98a') end
  sdec.force_baud, sdec.fs, sdec.trigmode = kb, kf, kt
  local f = (nm ~= nil and nc ~= nil and nc > 0) and (nm / nc) or nil
  if f ~= nil then
    if best == nil or f > best then best = f end
    if worst == nil or f < worst then worst = f end
  end
  print(string.format('  %-8d %-6.0f %-10s %s', by, by / (RFS / RB),
                      (nm ~= nil) and (tostring(nm) .. '/' .. tostring(nc)) or 'REFUSED',
                      (f ~= nil) and string.format('%.0f%%', f * 100) or '-'))
end

-- THE PREMISE: rotation zero must still be byte-exact, or the sweep is measuring the rotation harness.
check('the premise: an unrotated record is still byte-exact, so the sweep measures the rotation alone',
      best ~= nil and best > 0.95, (best ~= nil) and string.format('%.0f%%', best * 100) or 'nil')

-- AND THE QUESTION. The instrument reported 41 % on this cell. A rotation has to be able to REACH that,
-- or it is not the mechanism however well the threshold arithmetic lines up.
check('a ring wrap can produce the partial match the instrument reported, so it stays a live cause',
      worst ~= nil and worst < 0.80,
      (worst ~= nil) and string.format('worst %.0f%% against the hardware 41%%', worst * 100) or 'nil')

-- ---------------------------------------------------------------------------
print('\n-- the RESUME LATENCY: a constant microsecond cost, which is a bit time that scales --')
-- ---------------------------------------------------------------------------
-- WHY THIS IS THE MECHANISM AND THE fs SPLIT WAS A CONFOUND. On this ladder pick_fs targets 8.33 samples
-- a bit, so fs = 8.33 * baud and "fs at or above 40000" and "baud at or above 4800" are the SAME cut.
-- What is actually constant is a wall-clock latency between the comparator crossing that releases the
-- wait block and the first reading the measure block stores. A fixed number of microseconds is a bit time
-- that GROWS with baud, and it crosses half a bit -- the framer's sampling margin -- between 2400 and
-- 4800 Bd. Bounded from the 2026-10-17 record at 104 to 156 us.
--
-- Below half a bit the start bit is still sampled on the correct side of the threshold and the seam costs
-- nothing. Above it the framer anchors on the splice instead of on the start bit, emits a few flagged
-- frames while it re-synchronises, and comes out ONE payload byte further on -- so each seam advances the
-- alignment by one and a single global shift can only fit one segment. That is why the bytes inside each
-- segment are right while the cell scores 33-73 %.
local LAT = {0, 50e-6, 104e-6, 156e-6, 250e-6}
print(string.format('  %-7s %-9s %-7s %-9s %-7s %s', 'latency', 'at 2400', 'bits', 'at 4800', 'bits', 'hardware'))
local l2400, l4800 = nil, nil
for li = 1, table.getn(LAT) do
  local L = LAT[li]
  local a = cell('v98a', v98a, 2400, 20000, 600, 10, 0.010, NCAP, L)
  local b = cell('v98a', v98a, 4800, 40000, 600, 10, 0.010, NCAP, L)
  local fa = frac(a)
  local fb = frac(b)
  if L == 0 then l2400, l4800 = fa, fb end
  print(string.format('  %-7.0f %-9s %-7.2f %-9s %-7.2f %s', L * 1e6,
                      (fa ~= nil) and string.format('%.0f%%', fa * 100) or 'REFUSED', L * 2400,
                      (fb ~= nil) and string.format('%.0f%%', fb * 100) or 'REFUSED', L * 4800,
                      (L >= 104e-6 and L <= 156e-6) and '<- fable bounded L here' or ''))
end

check('the premise: with no resume latency both rates are byte-exact, so the sweep varies one thing',
      l2400 ~= nil and l2400 > 0.95 and l4800 ~= nil and l4800 > 0.95,
      string.format('2400:%s 4800:%s',
                    (l2400 ~= nil) and string.format('%.0f%%', l2400 * 100) or 'nil',
                    (l4800 ~= nil) and string.format('%.0f%%', l4800 * 100) or 'nil'))

-- THE CLAIM, stated as a property over the bounded range rather than at one value. The bound from the
-- record is 104-156 us; where inside it the break falls depends on the framer's sampling margin, and
-- pinning a single number here would be asserting the fixture's arithmetic rather than the mechanism.
-- 130 us, for instance, is 0.62 of a bit at 4800 Bd and still decodes -- the break is nearer 0.75.
local asym, asymat = false, ''
for li = 1, table.getn(LAT) do
  local L = LAT[li]
  if L >= 104e-6 and L <= 156e-6 then
    local f24 = frac(cell('v98a', v98a, 2400, 20000, 600, 10, 0.010, NCAP, L))
    local f48 = frac(cell('v98a', v98a, 4800, 40000, 600, 10, 0.010, NCAP, L))
    if f24 ~= nil and f24 > 0.95 and f48 ~= nil and f48 < 0.95 then
      asym = true
      asymat = string.format('%.0f us: 2400 at %.0f%% (%.2f bit), 4800 at %.0f%% (%.2f bit)',
                             L * 1e6, f24 * 100, L * 2400, f48 * 100, L * 4800)
    end
  end
end
-- The hardware figures are 223/231 at 2400 and 75/220 at 4800. The asymmetry is what this reproduces;
-- the exact fraction is not, the real record carrying more seams and more debris per seam than five
-- clean passes do, so a check on the value would fail for the wrong reason.
check('a resume latency inside the bound from the record spares 2400 Bd and breaks 4800 -- the hardware '
      .. 'edge, from one constant-time parameter', asym,
      (asym and asymat) or 'no latency in [104, 156] us produced the split')

-- ---------------------------------------------------------------------------
-- THE HEX OF ONE KNOWN-LATENCY CELL, for tools/judge_seam.py --hex to check its own interpretation
-- against. On the instrument the "+1 shift per seam means one payload byte consumed without a frame"
-- reading is an inference from the deltas; here the loss is a parameter, so feeding this string to
-- judge_seam proves the reading rather than assuming it.
--
--   lua tools/test_elideseam.lua | sed -n 's/^HEX v98a //p' | xargs -I{} python3 tools/judge_seam.py --vid v98a --hex {}
-- ---------------------------------------------------------------------------
do
  local h = cell('v98a', v98a, 4800, 40000, 600, 10, 0.010, NCAP, 156e-6)
  local s = ''
  if sdec.res ~= nil and sdec.res.vals ~= nil then
    local gi
    for gi = 1, (sdec.res.nf or 0) do
      if sdec.res.errs[gi] ~= nil then
        s = s .. '??'
      else
        s = s .. string.format('%02X', math.mod(sdec.res.vals[gi] or 0, 256))
      end
    end
  end
  print(string.format('\nHEX v98a %s', s))
end

print(string.format('\n%d passed, %d failed', pass, fail))
if fail > 0 then
  local i
  for i = 1, table.getn(failed) do print('  - ' .. failed[i]) end
  os.exit(1)
end

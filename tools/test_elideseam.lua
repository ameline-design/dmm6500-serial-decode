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
-- A mock scratch buffer over a logical sequence, newest last: a 2048-reading fillmode-1 ring, so a
-- sequence longer than that keeps only its tail, rotated by roff the way the instrument's does. This is
-- what sdec.gap_tail has to unwind.
local function mkscratch(seq, nseq, roff, cap)
  if cap == nil then cap = 2048 end
  if roff == nil then roff = 0 end
  local from = nseq - cap + 1
  local nlive = cap
  if from < 1 then from = 1 nlive = nseq end
  local s, i = {readings = {}, n = nlive, capacity = cap}, nil
  for i = 1, nlive do
    local p = i + roff
    if p > nlive then p = p - nlive end
    s.readings[p] = seq[from + i - 1]
  end
  -- Only a full ring can have rotated, which is acq_first's own gate.
  if nlive >= cap then
    s.startindex = roff + 1
    if s.startindex > nlive then s.startindex = s.startindex - nlive end
  else
    s.startindex = 1
  end
  return s
end

-- Returns, beyond the elided record: `ts`, the relativetimestamps the record would carry (so a seam is a
-- step and not a guess), and `scrs`, one scratch per burst holding what that burst lost -- the idle the
-- record did not keep, then the head the latency ate. That pairing is the program's: gap_model unrolls one
-- group per scratch and burst j's head lands in scratch j.
local function elide(rd, n, winsamp, lat, fs, roff, pad)
  local idle = rd[1]
  local out, m, i = {}, 0, 1
  local nseam = 0
  lat = lat or 0
  local ts, scrs, nscr = {}, {}, 0
  local dt = 1 / (fs or 1)
  local t = 0
  local pend, npend = nil, 0           -- the sequence the next burst's scratch will hold
  while i <= n do
    if rd[i] == idle then
      local j = i
      while j <= n and rd[j] == idle do j = j + 1 end
      local runlen = j - i
      local keep = runlen
      local drop = 0
      if runlen > winsamp then keep = winsamp nseam = nseam + 1 drop = lat end
      local k
      for k = 1, keep do
        m = m + 1 out[m] = idle ts[m] = t t = t + dt
      end
      -- The latency eats the head of the NEXT burst, not the tail of the idle: the comparator fires on
      -- the burst's own first falling edge, so what is lost is the start bit that edge belongs to.
      if drop > 0 or runlen > keep then
        -- Everything the record did not take, in time order, is what block 1 was storing.
        pend, npend = {}, 0
        for k = 1, runlen - keep do npend = npend + 1 pend[npend] = idle end
        for k = 0, drop - 1 do
          local src = j + k
          if src <= n then npend = npend + 1 pend[npend] = rd[src] end
        end
        -- The elided readings are real time that the record's stamps must step over.
        t = t + ((runlen - keep) + drop) * dt
      end
      i = j + drop
    else
      -- The first reading of a burst: its scratch is whatever block 1 held when block 3 took over.
      if pend ~= nil then
        -- `pad` puts extra idle AFTER the head, which is a splice landing late by that many samples.
        -- It is the null for sample-exactness: the right readings in the wrong place.
        if pad ~= nil and pad > 0 then
          local q
          for q = 1, pad do npend = npend + 1 pend[npend] = idle end
        end
        nscr = nscr + 1
        scrs[nscr] = mkscratch(pend, npend, roff or 0)
        pend = nil
      end
      m = m + 1
      out[m] = rd[i]
      ts[m] = t
      t = t + dt
      i = i + 1
    end
  end
  return out, m, nseam, ts, scrs
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
-- 3200 Bd. Bounded at 156 to 208 us from the record's seam debris: each seam's debris string depends
-- only on the resume offset in bit times, so every observed string bounds it and the tight rows
-- intersect there.
--
-- WHY HALF A BIT IS THE NUMBER. ua_frame samples each cell at t0 + (slot + 0.5) * T. A burst resuming s
-- bit times into its first start bit leaves no edge at the true start, so the framer anchors on the
-- splice -- a falling edge preceded by at least 1.5 T of mark -- and every sample is late by s. Under
-- 0.5 they stay inside their cells and the frame is exact. At 0.5 the stop sample lands in the next
-- start bit, that frame fails, and the resync walks through the next three to eight bytes before it
-- finds a real start bit, lowercase ASCII never offering the 1.5 T mark run it anchors on. The record
-- then comes out ONE payload byte further on, so each seam advances the alignment by one and a single
-- global shift fits only one segment. That is why the bytes inside each segment are right while the
-- cell scores 33-73 %.
local LAT = {0, 100e-6, 156e-6, 208e-6, 300e-6}
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
                      (L >= 156e-6 and L <= 208e-6) and '<- bounded L here' or ''))
end

check('the premise: with no resume latency both rates are byte-exact, so the sweep varies one thing',
      l2400 ~= nil and l2400 > 0.95 and l4800 ~= nil and l4800 > 0.95,
      string.format('2400:%s 4800:%s',
                    (l2400 ~= nil) and string.format('%.0f%%', l2400 * 100) or 'nil',
                    (l4800 ~= nil) and string.format('%.0f%%', l4800 * 100) or 'nil'))

-- THE CLAIM, stated as a property over the bounded range rather than at one value. The bound from the
-- record is 104-156 us; where inside it the break falls depends on the framer's sampling margin, and
-- pinning a single number here would be asserting the fixture's arithmetic rather than the mechanism.
local asym, asymat = false, ''
for li = 1, table.getn(LAT) do
  local L = LAT[li]
  if L >= 156e-6 and L <= 208e-6 then
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
--
-- 2400 Bd IS A NEAR MISS AND NOT A MARGIN, which this test should not be read as claiming. At the top of
-- the bound 208 us is 0.4992 of a bit there, against a 0.5 sampling margin -- so a 10 % drift in the
-- latency fails those cells, and on the real record one of the three vectors already lost a whole burst
-- at that offset. What passes here is v98a; the honest rule is in time, not in baud: a seam is free only
-- where 0.5 / baud exceeds the largest latency, which is about 2400 Bd at 208 us and nothing above it.
check('a resume latency inside the bound from the record spares 2400 Bd and breaks 4800 -- the hardware '
      .. 'edge, from one constant-time parameter', asym,
      (asym and asymat) or 'no latency in [156, 208] us produced the split')

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

-- ---------------------------------------------------------------------------
-- THE SPLICE, scored by the function the instrument puts on the panel
-- ---------------------------------------------------------------------------
-- Everything above measures the damage. This measures the repair, through sdec.gap_splice on the real
-- functions rather than a reference implementation of them, and scores it with bexp.match -- one shift,
-- the same gate as the pay= field in the record and the panel's red rule.
--
-- WHAT IT DOES NOT SHOW: that the firmware fills the scratches. tools/gen_serial.lua routes nothing into
-- them and applies no resume latency, so the scratches here come from elide() -- which knows what it took
-- away and hands back exactly that. The claim under test is that the splice puts back what was lost and
-- the decode then reads it, not that the instrument captured it. That is an instrument question and
-- r.splseam/splran/splorph/spladd on every cell is what will answer it.
print('')
print('-- the splice: does putting the head back restore the bytes? --')
print(string.format('  %-6s %-7s %-7s %-10s %-10s %s',
                    'baud', 'fs', 'lat us', 'unspliced', 'spliced', 'verdict'))

local function cell_spliced(vid, payload, baud, fs, lead, tail, win, ncap, latsec, roff, pad)
  local rd, n = passes(payload, baud, fs, lead, tail, 5)
  local erd, en, nseam, ts, scrs = elide(rd, n, win * fs, math.floor((latsec or 0) * fs), fs, roff, pad)
  if en > ncap then en = ncap end
  local kb, kf, kt = sdec.force_baud, sdec.fs, sdec.trigmode
  sdec.force_baud, sdec.fs, sdec.trigmode = baud, fs, 'free'
  sdec.force_nbits, sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil, nil
  sdec.acq_pretrig = nil
  sdec.proto, sdec.ui_mode = 'uart', 'text'
  -- Levels first: the splice needs the capture's own threshold, and a scratch cannot supply one.
  analyse(erd, en, fs)
  local thr = sdec.thr
  local buf = {readings = erd, relativetimestamps = ts, n = en, capacity = 6000000}
  local arr, m = sdec.gap_splice(buf, en, scrs, thr, fs / baud, fs)
  local nm, nc, nsp = nil, nil, sdec.spl_nspliced
  if arr ~= nil then
    analyse(arr, m, fs)
    local ok = sdec.decode_from(arr, m)
    if ok then nm, nc = bexp.match(sdec.res, vid) end
  end
  sdec.force_baud, sdec.fs, sdec.trigmode = kb, kf, kt
  return {nm = nm, nc = nc, nspliced = nsp, nseam = nseam, spliced = arr ~= nil}
end

local SPL = {{baud = 4800, fs = 40000, lat = 0.000156}, {baud = 9600, fs = 80000, lat = 0.000140},
             {baud = 19200, fs = 159806, lat = 0.000208}}
local allfixed, anybroken, si = true, false, nil
for si = 1, table.getn(SPL) do
  local S = SPL[si]
  -- The ring offset is varied per rate so no row passes on an unrotated scratch alone.
  local before = cell('v98a', v98a, S.baud, S.fs, 600, 10, 0.010, NCAP, S.lat)
  local after = cell_spliced('v98a', v98a, S.baud, S.fs, 600, 10, 0.010, NCAP, S.lat, si * 377)
  local fb, fa = 0, 0
  if before.nm ~= nil and (before.nc or 0) > 0 then fb = before.nm / before.nc end
  if after.nm ~= nil and (after.nc or 0) > 0 then fa = after.nm / after.nc end
  if fb < 0.99 then anybroken = true end
  if fa < 0.99 then allfixed = false end
  print(string.format('  %-6d %-7d %-7.0f %-10s %-10s %s', S.baud, S.fs, S.lat * 1e6,
                      string.format('%s/%s %.0f%%', tostring(before.nm), tostring(before.nc), fb * 100),
                      string.format('%s/%s %.0f%%', tostring(after.nm), tostring(after.nc), fa * 100),
                      (fa >= 0.99 and 'RESTORED') or 'still short'))
end
-- THE PREMISE, asserted rather than assumed: if the unspliced rows were already byte-exact there would be
-- nothing to repair and the row above would prove nothing.
check('the premise: every rate in this block is genuinely damaged without the splice', anybroken,
      'at least one unspliced row below 99 %')
check('the splice restores the payload to byte-exact at 4800, 9600 and 19200 Bd', allfixed,
      'all three spliced rows at 99 % or better on bexp.match, one shift')

-- AND THE NULL. Same splice, same record, scratches holding idle instead of the head: the decode must
-- stay broken, or the two checks above would pass against a fixture that was never damaged.
-- AND THE NULL IS A SHIFT, not a missing head: the SAME readings spliced four samples late, which at
-- 8.33 samples a bit is about half a bit. All-idle scratches would not do -- gap_tail refuses those on
-- purpose, so that tests a declined path rather than a wrong splice. This one is accepted and wrong.
local wrong = cell_spliced('v98a', v98a, 9600, 80000, 600, 10, 0.010, NCAP, 0.000140, 0, 4)
local fw = 0
if wrong.nm ~= nil and (wrong.nc or 0) > 0 then fw = wrong.nm / wrong.nc end
check('...while the same head spliced half a bit late does NOT restore it, so the splice is sample-exact',
      wrong.spliced and fw < 0.99,
      string.format('%s/%s = %.0f%% four samples late', tostring(wrong.nm), tostring(wrong.nc),
                    fw * 100))

-- ---------------------------------------------------------------------------
print('')
print('-- the ACQUISITION side: the whole chain, with the two-buffer program filling the scratches --')
-- ---------------------------------------------------------------------------
-- WHY THIS BLOCK EXISTS AND WHY EVERYTHING ABOVE IT WAS NOT ENOUGH. Every splice check above feeds the
-- scratches from elide(), which computes them by subtracting what the record kept -- that is, from the
-- answer the splice is being asked to find. So each of those passes was consistent with a splice that
-- cannot work on a real scratch, and the file said so: 'WHAT IT DOES NOT SHOW: that the firmware fills
-- the scratches'.
--
-- tools/gen_serial.lua now walks the program sdec.gap_model builds -- block b+1 digitizing into scratch
-- gi through the WAIT, block b+3 recording until the detector sees a crossing-free window -- and routes
-- every source sample to whichever buffer was live. So this drives the REAL chain, stream_begin through
-- stream_acquire to stream_decode, and scores the bytes the decode actually produced with bexp.match:
-- one shift, the same gate as the pay= field in the record and the panel's red rule.
--
-- WHAT IT STILL CANNOT SHOW, and no check below claims it: whether the firmware's handover from block
-- b+1 to block b+3 is CONTINUOUS. The walk assumes it is, which is the design's premise. A dead interval
-- there would leave the head in no buffer at all and its length would floor the bytes a seam destroys.
-- That stays the one hardware measurement this feature is waiting on.
;(function()
  local keep = {ge = sdec.gapelide, fb = sdec.force_baud, cm = sdec.capmode, tm = sdec.trigmode,
                ms = sdec.strm_maxsec, ns = sdec.gap_nscratch, w = TRIG.walk, d = SRC.trigderive,
                lat = TRIG_RESUME(), rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp,
                lp = SRC.loop, nf = SRC.native_fs, ta = SRC.trigat}
  TRIG_WALK(true)
  SRC_TRIGDERIVE(true)

  -- One cell through the real chain. `nscr` is how many scratches the program is built with, which is what
  -- forces the orphan cases; `defeat` takes the set away after the capture, for the unspliced null.
  local function cell(baud, np, lat, nscr, defeat, keepset)
    sdec.capmode, sdec.force_baud, sdec.trigmode = 'sml', baud, 'edge'
    sdec.force_nbits, sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil, nil
    sdec.gapelide, sdec.strm_maxsec = 0.01, 60
    sdec.proto, sdec.ui_mode = 'uart', 'text'
    -- Released before the count is lowered, or gap_scratches takes its reuse path and hands back the first
    -- nscr of a set it leaves twelve long. `keepset` is how the case below asks for exactly that, because
    -- it is the pool-against-program mismatch and it has to be reachable to be tested.
    sdec.gap_nscratch = nscr
    if not keepset then sdec.gap_release_all() end
    sdec.clear_measured()
    -- Begun once to learn the rate the app chooses, then rendered AT it, so the record's own timestamps and
    -- the app's fs agree and no rate error is mixed into the subject.
    sdec.stream_begin()
    local fs = sdec.fs
    local rd, ts, n, i, p = {}, {}, 0, nil, nil
    for p = 1, np do
      local r1, _, _, n1 = GEN({bytes = GEN_BYTES(v98a), nbits = 8, par = 0, baud = baud, fs = fs,
                                gap = 0, lead = 600, tail = 10, loop = false})
      for i = 1, n1 do n = n + 1 rd[n] = r1[i] ts[n] = (n - 1) / fs end
    end
    SRC.rd, SRC.ts, SRC.nsmp = rd, ts, n
    SRC.trigat, SRC.loop, SRC.native_fs = nil, false, nil
    TRIG_RESUME(lat)
    sdec.clear_measured()
    local bok, bwhy = sdec.stream_begin()
    if not bok then return {err = 'begin: ' .. tostring(bwhy)} end
    TRIG_CLOCK(0)
    local got = sdec.stream_acquire(20000)
    if defeat then sdec.gap_used = nil end
    pcall(function() sdec.stream_decode(got) end)
    local r = {got = got, why = sdec.spl_why, nseam = sdec.spl_nseam, nspl = sdec.spl_nspliced,
               nadd = sdec.spl_nadded, norph = sdec.spl_norphan, armed = sdec.strm_armed,
               elided = sdec.acq_elided}
    local tl = (sdec.ck_tot ~= nil) and sdec.ck_tot.tail or nil
    if tl ~= nil then r.nm, r.nc = bexp.match(tl, 'v98a') end
    if r.nm ~= nil and r.nc ~= nil and r.nc > 0 then r.f = r.nm / r.nc end
    return r
  end
  local function show(r)
    if r.err ~= nil then return r.err end
    return string.format('%s nseam=%s spl=%s orph=%s add=%s pay=%s/%s %s', tostring(r.why),
                         tostring(r.nseam), tostring(r.nspl), tostring(r.norph), tostring(r.nadd),
                         tostring(r.nm), tostring(r.nc),
                         (r.f ~= nil) and string.format('%.0f%%', r.f * 100) or '-')
  end

  -- THE PREMISE, and it is two facts at once: the chain reaches the splice at all, and a handover that
  -- loses nothing leaves no head to restore. gap_tail refusing an all-idle scratch is the correct answer
  -- there, not a fault -- and the record is already byte-exact, which is what proves the fixture's
  -- working case before any damage is introduced.
  local perfect = cell(9600, 4, 0, 12, false)
  check('the premise: with a lossless handover the record is byte-exact and every tail is refused',
        perfect.why == 'tails refused' and (perfect.nseam or 0) > 1 and perfect.nspl == 0
        and perfect.f ~= nil and perfect.f > 0.95, show(perfect))

  -- THE NULL: the resume latency in, and the splice taken away. This is the damage, and without it every
  -- check below would pass against a record that was never broken.
  local null = cell(9600, 4, 156e-6, 12, true)
  check('the null: the same record with no splice is badly damaged, so there is something to repair',
        null.why == 'no scratches' and null.f ~= nil and null.f < 0.80, show(null))

  -- AND THE REPAIR, on scratches the PROGRAM filled. This is the claim the file could not make before.
  local fixed = cell(9600, 4, 156e-6, 12, false)
  check('the splice restores the payload byte-exact from scratches the trigger model itself filled',
        fixed.why == 'ok' and fixed.nspl == fixed.nseam and (fixed.norph or 1) == 0
        and fixed.f ~= nil and fixed.f > 0.99, show(fixed))
  -- AND THE HEAD IT PUT BACK IS THE LATENCY IT WAS CHARGED, less the margin, to the reading: 156 us at the
  -- rate the app chose is floor(156e-6 * fs) readings. This is the figure the row now carries as splhead=,
  -- and it dies if the margin accounting in gap_splice_plan drifts from gap_tail's.
  local wanthead = math.floor(156e-6 * sdec.fs)
  check('...and the recovered head per seam is the latency charged, to the reading',
        sdec.spl_headrd ~= nil and fixed.nspl ~= nil and fixed.nspl > 0
        and sdec.spl_headrd / fixed.nspl == wanthead,
        string.format('headrd=%s over %s seams, want %d at fs %s', tostring(sdec.spl_headrd),
                      tostring(fixed.nspl), wanthead, tostring(sdec.fs)))

  -- ---- AND THE FINDING: a splice that misses ONE INTERIOR SEAM is worth nothing ----
  -- Six bursts against five scratches orphans seam 1, which is the record's own OPENING: a missing head
  -- there costs the first frame and no more, because the offset it leaves IS the single shift every scorer
  -- solves for. Against four scratches seam 2 is orphaned too, and that one is interior -- it shifts the
  -- remainder against everything before it, so one shift fits only one segment and the recovered bytes
  -- become invisible. The two rows are one scratch apart and they are the whole mechanism.
  local open1 = cell(9600, 6, 156e-6, 5, false)
  check('a splice that misses only the record OPENING is still byte-exact, the offset being the shift',
        open1.why == 'ok' and open1.norph == 1 and open1.f ~= nil and open1.f > 0.99, show(open1))
  local inner = cell(9600, 6, 156e-6, 4, false)
  check('...while missing ONE INTERIOR seam recovers nothing measurable, which is the defect',
        inner.norph == 2 and inner.f ~= nil and inner.f < 0.80, show(inner))
  -- AND THE REASON HAS TO SEPARATE THEM, because the byte count is what a lap cannot see: 'ok' beside a
  -- count that did not move sends the next reader to the decoder, which is the one place the fault is not.
  check('...and the reason says `partial` rather than `ok`, so a lap reads the consequence',
        inner.why == 'partial' and open1.why == 'ok',
        string.format('interior=%s opening=%s', tostring(inner.why), tostring(open1.why)))

  -- ---- THE SPLICE MUST PAIR AGAINST THE PROGRAM, NOT AGAINST THE POOL ----
  -- gap_scratches leaves the whole set in sdec.gapbufs and returns only the first nwant, so the two differ
  -- whenever fewer are asked for than are held. The program then has 5 groups and wraps at burst 6, which
  -- puts burst 6's head in scratch 1 -- while a plan built from a 12-long pool reads scratch 1 as burst 1's
  -- and splices one burst's head onto another, then finds scratch 6 empty and orphans an interior seam.
  --
  -- Forced by allocating twelve and then asking for five WITHOUT releasing, which is the one ordering that
  -- reaches the reuse path. The previous row is the control: the same 6-burst, 5-scratch geometry with the
  -- set released comes back byte-exact, so anything this row loses is the pool-against-program mismatch
  -- and not the orphaned opening it shares with it.
  cell(9600, 2, 156e-6, 12, false)                    -- allocate twelve, then keep them
  local reuse = cell(9600, 6, 156e-6, 5, false, true)
  check('a program built with five of twelve scratches still pairs burst to scratch correctly',
        reuse.why == 'ok' and reuse.norph == 1 and reuse.f ~= nil and reuse.f > 0.99, show(reuse))

  -- ---- THE HANDOVER HOLE: the one thing the walk assumes, and what the lap of 2026-10-18 says about it ----
  -- Everything above holds for a CONTINUOUS handover, where the resume latency's samples all went to the
  -- scratch. The hardware lap says otherwise: on every cell whose scored window held an interior seam, a
  -- splice reporting ok with every head restored left the bursts misaligned -- one shift 0.3 to 0.8 against
  -- per-segment 0.95 to 1.00, and tools/judge_seam.py deltas of +1 to +5 at every seam from 80 kS/s up,
  -- mixed at 60 kS/s, intact at 50 kS/s and below. A dead interval at the record block's entry, in neither
  -- buffer, does exactly that: the framer anchors on the restored head and every bit centre after the hole
  -- is sampled late by its width. Swept here through the real chain to find the width that breaks a frame.
  --
  -- WHAT THE THREE ROWS PIN. Under half a bit the hole is absorbed and the splice stays byte-exact; over it
  -- the one-shift score collapses to one segment's worth while the per-segment alignment is intact and
  -- every seam moves by +1 -- the hardware signature -- with spl_why still 'ok'. An OVERLAP of the same
  -- width, both buffers holding the readings, costs nothing but flagged frames: the deltas stay at 0. So
  -- the +1 to +5 the lap carries can only be a hole, and 60 kS/s being mixed puts it at 0.5 T there, about
  -- 70 to 90 us. The value is unmeasured; TRIG.cost.hole stays 0 by default and this block sets it per row.
  local function wordshifts(res)
    -- The per-run best cyclic shift and the deltas between them, as tools/judge_seam.py takes them.
    local want, wl, i = {}, string.len(v98a), nil
    for i = 1, wl do want[i] = string.byte(v98a, i) end
    local runs, cur, start = {}, nil, nil
    for i = 1, res.nf do
      if res.errs[i] ~= nil then
        if cur ~= nil then runs[table.getn(runs) + 1] = {at = start, v = cur} end
        cur, start = nil, nil
      else
        if cur == nil then cur, start = {}, i - 1 end
        cur[table.getn(cur) + 1] = math.mod(res.vals[i], 256)
      end
    end
    if cur ~= nil then runs[table.getn(runs) + 1] = {at = start, v = cur} end
    local shifts, r = {}, nil
    for r = 1, table.getn(runs) do
      local vals, at = runs[r].v, runs[r].at
      if table.getn(vals) >= 8 then
        local best, bsh, sh = -1, nil, nil
        for sh = 0, wl - 1 do
          local n, k = 0, nil
          for k = 1, table.getn(vals) do
            if vals[k] == want[math.mod(sh + at + k - 1, wl) + 1] then n = n + 1 end
          end
          if n > best then best, bsh = n, sh end
        end
        shifts[table.getn(shifts) + 1] = bsh
      end
    end
    local d = {}
    for r = 2, table.getn(shifts) do d[r - 1] = math.mod(shifts[r] - shifts[r - 1] + wl, wl) end
    return d
  end
  local function hcell(hole_rd)
    local keephole = TRIG_HOLE()
    sdec.capmode, sdec.force_baud, sdec.trigmode = 'sml', 9600, 'edge'
    sdec.gapelide, sdec.strm_maxsec = 0.01, 60
    sdec.gap_nscratch = 12
    sdec.gap_release_all()
    sdec.clear_measured()
    sdec.stream_begin()
    local fs = sdec.fs
    local rd, ts, n, i, p = {}, {}, 0, nil, nil
    for p = 1, 4 do
      local r1, _, _, n1 = GEN({bytes = GEN_BYTES(v98a), nbits = 8, par = 0, baud = 9600, fs = fs,
                                gap = 0, lead = 600, tail = 10, loop = false})
      for i = 1, n1 do n = n + 1 rd[n] = r1[i] ts[n] = (n - 1) / fs end
    end
    SRC.rd, SRC.ts, SRC.nsmp = rd, ts, n
    SRC.trigat, SRC.loop, SRC.native_fs = nil, false, nil
    TRIG_RESUME(156e-6)
    TRIG_HOLE(hole_rd / fs)
    sdec.clear_measured()
    sdec.stream_begin()
    TRIG_CLOCK(0)
    local got = sdec.stream_acquire(20000)
    pcall(function() sdec.stream_decode(got) end)
    TRIG_HOLE(keephole)
    local r = {T = fs / 9600, why = sdec.spl_why, nseam = sdec.spl_nseam, nspl = sdec.spl_nspliced}
    local tl = (sdec.ck_tot ~= nil) and sdec.ck_tot.tail or nil
    if tl ~= nil then
      r.nm, r.nc = bexp.match(tl, 'v98a')
      r.d = wordshifts(tl)
    end
    if r.nm ~= nil and r.nc ~= nil and r.nc > 0 then r.f = r.nm / r.nc end
    return r
  end
  local function hshow(r)
    local s = ''
    if r.d ~= nil then local i for i = 1, table.getn(r.d) do s = s .. string.format('%+d ', r.d[i]) end end
    return string.format('%s spl=%s/%s one=%s/%s %s deltas[%s]', tostring(r.why), tostring(r.nspl),
                         tostring(r.nseam), tostring(r.nm), tostring(r.nc),
                         (r.f ~= nil) and string.format('%.0f%%', r.f * 100) or '-', s)
  end
  local under = hcell(4)                 -- 0.38 of a bit at 10.4 samples a bit
  local over = hcell(6)                  -- 0.58 of a bit
  local lap = hcell(-6)                  -- an overlap of the same width
  check('a handover hole under half a bit is absorbed: the splice is still byte-exact',
        under.why == 'ok' and under.nspl == under.nseam and under.f ~= nil and under.f > 0.99,
        hshow(under))
  -- The hardware signature, all three parts of it at once: the splice reports ok with every head back, the
  -- one-shift score is one segment's worth, and every seam advances the alignment by one.
  local plusone = (over.d ~= nil and table.getn(over.d) == (over.nseam or 0) - 1)
  if plusone then local i for i = 1, table.getn(over.d) do if over.d[i] ~= 1 then plusone = false end end end
  check('...over half a bit it is broken at every seam while the splice still says ok, the lap signature',
        over.why == 'ok' and over.nspl == over.nseam and over.f ~= nil and over.f < 0.5 and plusone,
        hshow(over))
  -- AND THE NULL THAT SEPARATES A HOLE FROM AN OVERLAP: duplicated readings of the same width leave the
  -- alignment alone, so a lap carrying +1 deltas was not an overlap.
  check('...while an overlap of the same width costs no alignment at all, so the lap\'s +1 is a hole',
        lap.why == 'ok' and lap.f ~= nil and lap.f > 0.99, hshow(lap))

  -- THE HOLE'S WIDTH, BRACKETED BY THE HARDWARE'S OWN VERDICT PAIR. The instrument reports
  -- `splwhy=ok` beside payloads around 29 % on 110 of 144 elided cells, and only a narrow band of
  -- holes produces BOTH of those at once -- which makes the pair a measurement of the width without
  -- any instrument, and a better one than the direct attempt. Below the band the splice is
  -- byte-exact, so the hardware would not be failing; above it gap_tail finds no head at all and the
  -- verdict becomes `tails refused`, which the hardware does not report. The band straddles the
  -- 70-90 us independently predicted for the handover, 7-9 readings at 100 kS/s.
  --
  -- Asserted as a BAND rather than at one width on purpose: the quantity is not known to a reading,
  -- and a check pinned at a single value would read as precision this does not have.
  local band, bi, bshow = true, nil, ''
  for bi = 1, 3 do
    local hr = ({6, 10, 14})[bi]
    local c = hcell(hr)
    bshow = bshow .. string.format('%d:%s/%s ', hr, tostring(c.why),
                                   (c.f ~= nil) and string.format('%.0f%%', c.f * 100) or '-')
    if not (c.why == 'ok' and c.f ~= nil and c.f < 0.5) then band = false end
  end
  check('the hardware pair -- splwhy=ok beside a third of the payload -- holds across 6 to 14 readings',
        band, bshow)
  -- AND BOTH EDGES OF THE BAND, so it is a band and not an unbounded claim.
  local lo2, hi2 = hcell(2), hcell(18)
  check('...is byte-exact below it, so a smaller hole would not produce the hardware failure',
        lo2.why == 'ok' and lo2.f ~= nil and lo2.f > 0.99, hshow(lo2))
  check('...and loses the head above it, which the hardware does not report',
        hi2.why == 'tails refused', hshow(hi2))

  sdec.gap_nscratch = keep.ns
  pcall(sdec.gap_release_all)
  sdec.gapelide, sdec.force_baud, sdec.capmode = keep.ge, keep.fb, keep.cm
  sdec.trigmode, sdec.strm_maxsec = keep.tm, keep.ms
  TRIG_RESUME(keep.lat)
  SRC.rd, SRC.ts, SRC.nsmp = keep.rd, keep.ts, keep.nsmp
  SRC.loop, SRC.native_fs, SRC.trigat = keep.lp, keep.nf, keep.ta
  TRIG_WALK(keep.w == true)
  SRC_TRIGDERIVE(keep.d == true)
  check('and the suite leaves the scratch count, the modelled latency and the hole as it found them',
        sdec.gap_nscratch == keep.ns and TRIG_RESUME() == keep.lat and TRIG_HOLE() == 0,
        string.format('%s / %s / %s', tostring(sdec.gap_nscratch), tostring(TRIG_RESUME()),
                      tostring(TRIG_HOLE())))
end)()

print('')
print('-- THE EIGHT GAP VECTORS, REBUILT FROM THEIR DECLARATIONS --')
-- ---------------------------------------------------------------------------
-- The seam and elision work is tested on the gap-targeted vectors and not on generic stimulus, so the
-- first thing to establish is that the rebuild IS those vectors. out/ is gitignored, so reading
-- out/vectors/v98a.bin would make every row below pass vacuously on a fresh clone -- the trap
-- tools/test_octave.lua's header sets out -- and the parameters are therefore taken from
-- tools/make_vectors.lua's own vec{} calls.
--
-- THE ORACLE IS THE CYCLIC IDLE RUN, measured off the real .bin files on 2026-10-19, because that is
-- the quantity elision keys on: the detector fires when a run of mark exceeds the window, so if the
-- rebuild's runs are the file's runs then the rebuild elides where the file elides.
--
-- AND IT IS NOT THE DECLARED GAP. Every run is about one bit time longer, because the last frame's STOP
-- BIT is a mark at the idle level and merges into the gap -- no measurement can separate them -- and at
-- 7E1 a parity bit that is also mark adds a second, which is why v99b's 1000-bit-time midgap measures
-- 1001.9 and v99c's 600 measures 601.9 while 8N1's v98b measures 600.9 on the same declaration. That is
-- data-dependent, so it is MEASURED here rather than asserted as a rule: the rebuild has to reproduce
-- the file's number, not a derivation of it. The same relation is asserted in tools/test_bench_engine.lua.
--
-- `loop = true` in make_vectors means the tail runs into the next pass's lead, so the join run is the
-- trailing idle plus the leading idle of one rendered pass. Measured that way here, which needs one
-- pass rather than two.
-- ---------------------------------------------------------------------------
local GAPVEC = {
  {id = 'v98a', nbits = 8, par = 0, lead = 600,  tail = 10, mid = 0,    at = nil, spb = 10,
   runs = {610.9}},
  {id = 'v98b', nbits = 8, par = 0, lead = 10,   tail = 10, mid = 600,  at = 65,  spb = 10,
   runs = {600.9}},
  {id = 'v98c', nbits = 8, par = 0, lead = 400,  tail = 10, mid = 400,  at = 65,  spb = 10,
   runs = {400.9, 410.9}},
  {id = 'v98d', nbits = 8, par = 0, lead = 950,  tail = 10, mid = 0,    at = nil, spb = 10,
   runs = {960.9}},
  {id = 'v99a', nbits = 7, par = 1, lead = 1000, tail = 10, mid = 0,    at = nil, spb = 10,
   runs = {1010.9}},
  {id = 'v99b', nbits = 7, par = 1, lead = 10,   tail = 10, mid = 1000, at = 40,  spb = 10,
   runs = {1001.9}},
  {id = 'v99c', nbits = 7, par = 1, lead = 600,  tail = 10, mid = 600,  at = 40,  spb = 10,
   runs = {601.9, 610.9}},
  {id = 'v99d', nbits = 7, par = 1, lead = 4790, tail = 10, mid = 0,    at = nil, spb = 5,
   runs = {4800.8}},
}

-- One pass of a gap vector at its declared shape. -> readings, count, samples a bit.
local function gaprender(g, baud, fs)
  if baud == nil then baud = 9600 end
  if fs == nil then fs = baud * g.spb end
  -- loop = true, as make_vectors passes it, and it is not cosmetic here: without it GEN renders
  -- floor(nc * Tb) + 2 samples, and those two samples of trailing pad lengthen the join by 0.2 bit
  -- times at spb 10 and 0.4 at spb 5 -- which is exactly the discrepancy against the file that this
  -- block first reported. With it the render is an exact whole number of bit times and the join is the
  -- file's.
  local o = {bytes = GEN_BYTES(bexp.bytes(g.id)), nbits = g.nbits, par = g.par, baud = baud,
             fs = fs, gap = 0, lead = g.lead, tail = g.tail, loop = true}
  if g.mid > 0 then o.midgap = g.mid o.midgap_at = g.at end
  local rd, _, _, n = GEN(o)
  return rd, n, fs / baud
end

-- The distinct idle runs of a looping arb, in BIT TIMES, ascending. `minbits` drops the intra-frame mark
-- runs, which are bounded by the frame and are not gaps; it is also what keeps v98b's and v99b's 21-bit
-- join out, which the file measurement does not list either.
--
-- TWO PASSES, AND ONLY THE INTERIOR RUNS COUNTED. The join is the quantity that needed care: measured on
-- ONE pass as the leading idle plus the trailing idle it comes out two samples long at every rate,
-- because sample 1 and sample n have no neighbour and so no rendered edge, while the real join has an
-- edge at each end. Rendering the pass twice puts a genuine frame on both sides of the join and the
-- number then matches the file. The outermost runs of the two-pass render are dropped for the same
-- reason they were wrong before.
local function gapruns(rd1, n1, sabit, minbits)
  local rd, n, i = {}, 0, nil
  for i = 1, n1 do n = n + 1 rd[n] = rd1[i] end
  for i = 1, n1 do n = n + 1 rd[n] = rd1[i] end
  local idle = rd[1]
  local lead, tail = 0, 0
  for i = 1, n do if rd[i] == idle then lead = lead + 1 else break end end
  for i = n, 1, -1 do if rd[i] == idle then tail = tail + 1 else break end end
  local raw, nr, run = {}, 0, 0
  for i = lead + 1, n - tail do
    if rd[i] == idle then
      run = run + 1
    else
      if run / sabit >= minbits then nr = nr + 1 raw[nr] = run / sabit end
      run = 0
    end
  end
  table.sort(raw)
  -- Distinct, because a two-pass render shows each of a two-gap vector's runs twice.
  local out, no, k = {}, 0, nil
  for k = 1, nr do
    if no == 0 or (raw[k] - out[no]) > 0.5 then no = no + 1 out[no] = raw[k] end
  end
  return out, no
end

;(function()
  local gi
  for gi = 1, table.getn(GAPVEC) do
    local g = GAPVEC[gi]
    local rd, n, sabit = gaprender(g)
    local got, ngot = gapruns(rd, n, sabit, 50)
    -- One sample period, in bit times: the rendered edge is a sample or two of neither level, so that is
    -- the whole budget. 0.1 bit times at spb 10 and 0.2 at v99d's spb 5 -- derived, not chosen.
    local tol = 1.05 / g.spb
    local want = g.runs
    local ok = (ngot == table.getn(want))
    local txt, k = '', nil
    for k = 1, ngot do
      txt = txt .. string.format('%s%.1f', (k > 1) and ', ' or '', got[k])
      if ok and math.abs(got[k] - want[k]) > tol then ok = false end
    end
    local wtxt = ''
    for k = 1, table.getn(want) do
      wtxt = wtxt .. string.format('%s%.1f', (k > 1) and ', ' or '', want[k])
    end
    check(string.format('%s rebuilds the file`s idle runs: %s bit times', g.id, wtxt),
          ok, string.format('got [%s] want [%s] tol %.2f', txt, wtxt, tol))
  end
  -- AND THE +1 IS THE STOP BIT, asserted rather than left in the comment: the declared gap alone is
  -- short of every measured run, and by about one bit time, which is what makes the rebuild's agreement
  -- above a fact about the waveform rather than about the arithmetic.
  local g = GAPVEC[1]
  local rd, n, sabit = gaprender(g)
  local got = gapruns(rd, n, sabit, 50)
  check('the measured join exceeds the declared lead+tail by about a stop bit, not by zero',
        got[1] - (g.lead + g.tail) > 0.8 and got[1] - (g.lead + g.tail) < 1.2,
        string.format('%.2f against declared %d', got[1], g.lead + g.tail))
end)()

print('')
print('-- THE RATE LADDER ON THE ELIDE PATH, driven the way brun.point drives it --')
-- ---------------------------------------------------------------------------
-- WHY A SECOND ACQUISITION BLOCK. The one above runs ONE rate, 9600 Bd, and reaches the chain through
-- sdec.stream_begin(). The soak does neither. Its ladder runs to 230400 Bd, and brun.point calls
-- sdec.stream_acquire() DIRECTLY -- bench/bench_run.tsp says so where it does the setup by hand, 'the
-- setup acquire() does and stream_acquire() does not'. The difference is not cosmetic: stream_begin
-- consults sdec.mode_why(), which refuses any recording whose baud makes fs_for_burst() nil, so above
-- about 165563 Bd stream_begin returns 'a recording gets 3.8 samples/bit, under the 4 floor -- use
-- FRAME' and never captures. The bench never meets that gate, so the top five rates of the hardware
-- ladder are reachable there and were not reachable from any offline fixture.
--
-- So this block mirrors brun.point's elide branch in its own order -- brun.cell_fs, then
-- brun.elide_appfs, then brun.elide_fsmax, then the window cap, then the probe, then
-- stream_acquire -- and sweeps the rate instead of holding it.
--
-- sdec.capmode IS PINNED AND brun DOES NOT SET IT. It is left at the 'frame' default on the
-- instrument, where the block above chooses 'sml'. Measured here: 'frame', 'sml' and 'smx' give the
-- same record, the same splice and the same bytes at both 76800 and 115200 Bd, because nothing on
-- this path reads mode_cur() once stream_begin is out of it. Pinned anyway, so the preceding block's
-- choice cannot leak in and make this one's subject the mode.
--
-- THE GEOMETRY IS v99d's, which is the only gap vector the hardware ladder took past 38400 Bd, and
-- the reason is arithmetic rather than a draw: elision needs an idle run longer than the detector
-- window, v99d's lead is 4800 bit times, and at 230400 Bd that is 20.8 ms against a 10 ms window
-- where v98a's 610 bit times is 2.6 ms. The payload is v99d's own, out of bench/expect.tsp, so a
-- fresh clone builds the whole stimulus -- out/ is gitignored and a suite that read out/vectors/
-- would pass vacuously there, which tools/test_octave.lua's header sets out at length.
-- ---------------------------------------------------------------------------
;(function()
  local keep = {ge = sdec.gapelide, fb = sdec.force_baud, cm = sdec.capmode, tm = sdec.trigmode,
                ms = sdec.strm_maxsec, ns = sdec.gap_nscratch, w = TRIG.walk, d = SRC.trigderive,
                lat = TRIG_RESUME(), rd = SRC.rd, ts = SRC.ts, nsmp = SRC.nsmp,
                lp = SRC.loop, nf = SRC.native_fs, ta = SRC.trigat, n = sdec.n,
                fs = sdec.fs, fw = sdec.fs_want, pr = sdec.proto, um = sdec.ui_mode,
                nb = sdec.force_nbits, pa = sdec.force_par, st = sdec.force_nstop,
                iv = sdec.force_invert, at = sdec.arm_thr, ai = sdec.arm_idle,
                pi = sdec.probe_idle}
  TRIG_WALK(true)
  SRC_TRIGDERIVE(true)

  local NCAP = 20000                 -- sdec.n, the depth brun gives an elided cell

  -- One cell, as brun.point runs an elided one. `fsmax` is brun.elide_fsmax; nil lifts the cap.
  -- `fs` overrides the whole rate chain, which is how the two rows below hold the rate still and
  -- move the baud.
  local function cell(o)
    local baud = o.baud
    sdec.n = NCAP
    sdec.proto, sdec.ui_mode = 'uart', 'text'
    sdec.capmode = 'frame'
    sdec.force_baud, sdec.force_nbits, sdec.force_par = baud, o.nbits, o.par
    sdec.force_nstop, sdec.force_invert = nil, nil
    sdec.gap_nscratch = o.nscr or 12
    sdec.gap_release_all()
    -- brun.point's own order. cell_fs first and both fields together: hw_config() re-runs
    -- fs_select(), which consults force_baud and throws a bare sdec.fs away -- fs_want is the
    -- one-shot that survives it, and bench_run.tsp sets the pair for exactly that reason.
    local cellfs = sdec.pick_fs(baud, 8)
    sdec.fs, sdec.fs_want = cellfs, cellfs
    sdec.gapelide, sdec.trigmode = o.win or 0.01, 'edge'
    local appfs = nil
    pcall(function() appfs = sdec.fs_for_burst(baud) end)
    if appfs ~= nil and appfs > 0 then sdec.fs, sdec.fs_want = appfs, appfs end
    local capped = nil
    if o.fsmax ~= nil and sdec.fs > o.fsmax then
      sdec.fs, sdec.fs_want = o.fsmax, o.fsmax
      capped = o.fsmax
    end
    if o.fs ~= nil then sdec.fs, sdec.fs_want, capped = o.fs, o.fs, nil end
    if sdec.fs > 0 then
      local wmax = 0.4 * sdec.n / sdec.fs
      if sdec.gapelide > wmax then sdec.gapelide = wmax end
    end
    sdec.clear_measured()
    sdec.hw_config()
    local fs = sdec.fs

    -- Rendered AT the rate the capture runs at, so no rate error is mixed into the subject.
    local rd, ts, n, i, p = {}, {}, 0, nil, nil
    for p = 1, (o.np or 4) do
      local go = {bytes = GEN_BYTES(bexp.bytes(o.vid)), nbits = o.nbits or 8,
                  par = o.par or 0, baud = baud, fs = fs, gap = 0,
                  lead = o.lead, tail = o.tail or 10, loop = (o.loop == true)}
      if (o.mid or 0) > 0 then go.midgap = o.mid go.midgap_at = o.at end
      local r1, _, _, n1 = GEN(go)
      for i = 1, n1 do n = n + 1 rd[n] = r1[i] ts[n] = (n - 1) / fs end
    end
    SRC.rd, SRC.ts, SRC.nsmp = rd, ts, n
    SRC.trigat, SRC.loop, SRC.native_fs = nil, false, nil
    TRIG_RESUME(o.lat)

    sdec.acq_make_buffer(sdec.acq_cap(sdec.n), true)
    -- The probe, which is what stream_arm needs: without sdec.arm_thr it refuses elision and every
    -- cell falls back to the canned template, which on the 2026-10-17 lap was silent in 53 of 53.
    local lok = false
    pcall(function()
      if sdec.acq_free(sdec.n, nil, true) >= 2 then lok = sdec.sig_levels(sdec.smp, sdec.nread) end
      if lok then sdec.sig_edges(sdec.smp, sdec.nread) sdec.sig_idle(sdec.smp, sdec.nread) end
      if lok and sdec.thr ~= nil and sdec.swing ~= nil and sdec.swing > 0 then
        sdec.arm_thr, sdec.arm_idle = sdec.thr, sdec.idle
      else
        sdec.arm_threshold()
      end
      local t = sdec.arm_thr
      if t ~= nil and t == t and t > -10 and t < 10 then
        sdec.probe_idle = 'gap vector: arming on the waveform own idle runs'
      else
        sdec.arm_thr = nil
      end
    end)

    local keepmax = sdec.strm_maxsec
    sdec.strm_maxsec = 30
    sdec.ck_endwhy = nil
    TRIG_CLOCK(0)
    local got = nil
    pcall(function() got = sdec.stream_acquire(sdec.n) end)
    sdec.strm_maxsec = keepmax
    local dok, dwhy = nil, nil
    if got ~= nil and got > 0 then
      pcall(function() dok, dwhy = sdec.stream_decode(sdec.nread) end)
    end
    local r = {got = got, why = sdec.spl_why, nseam = sdec.spl_nseam, nspl = sdec.spl_nspliced,
               norph = sdec.spl_norphan, nadd = sdec.spl_nadded, elided = sdec.acq_elided,
               fs = fs, cellfs = cellfs, appfs = appfs, capped = capped, sabit = fs / baud,
               dok = dok, dwhy = dwhy, armed = sdec.strm_armed,
               -- The head the latency really ate, in readings, and the margin gap_tail adds back.
               -- Both are the fixture's own arithmetic, so a recovered tail can be compared with
               -- what a complete one WOULD be instead of only with zero.
               head = math.floor((o.lat or 0) * fs) + math.ceil(sdec.gap_idlemargin * (fs / baud))}
    local tl = (sdec.ck_tot ~= nil) and sdec.ck_tot.tail or nil
    if tl ~= nil then r.nm, r.nc = bexp.match(tl, o.vid) r.nf = tl.nf end
    if r.nm ~= nil and r.nc ~= nil and r.nc > 0 then r.f = r.nm / r.nc end
    if r.nadd ~= nil and r.nspl ~= nil and r.nspl > 0 then r.per = r.nadd / r.nspl end
    return r
  end

  local function show(r)
    return string.format('fs=%.0f sab=%.2f %s %s/%s orph=%s add=%s/seam vs head %s pay=%s/%s %s%s',
                         r.fs, r.sabit, tostring(r.why), tostring(r.nspl), tostring(r.nseam),
                         tostring(r.norph),
                         (r.per ~= nil) and string.format('%.0f', r.per) or '-',
                         tostring(r.head), tostring(r.nm), tostring(r.nc),
                         (r.f ~= nil) and string.format('%.0f%%', r.f * 100) or '-',
                         (r.dok == false) and (' REFUSED: ' .. tostring(r.dwhy)) or '')
  end
  -- v99d's own geometry, fixed across every row below so the rate is the only thing moving.
  local function v99d(baud, more)
    local o = {vid = 'v99d', baud = baud, lead = 4800, nbits = 7, par = 1, np = 4, lat = 156e-6}
    local k, v
    if more ~= nil then for k, v in pairs(more) do o[k] = v end end
    return cell(o)
  end

  -- ---- THE PREMISE, three ways, because every claim below is a comparison ----
  -- Without these the block could pass on a capture that never elided, at a rate that cannot carry
  -- the payload, against a record that was never damaged.
  local free = v99d(115200, {fs = 500000, win = 0})
  check('premise: 115200 Bd at 500 kS/s with elision OFF is byte-exact, so the rate carries it',
        free.why == 'not elided' and free.f ~= nil and free.f > 0.99, show(free))
  local lossless = v99d(115200, {fs = 500000, lat = 0})
  check('premise: with a lossless handover the same elided record needs no splice and gets none',
        lossless.why == 'tails refused' and (lossless.nseam or 0) > 1 and lossless.nspl == 0
        and lossless.f ~= nil and lossless.f > 0.95, show(lossless))
  local top = v99d(230400, {fsmax = nil})
  check('premise: the ladder TOP really elides, so a failure there is the elide path',
        top.elided == true and (top.nseam or 0) > 1 and top.armed == true, show(top))

  -- ---- THE HEAD IS RECOVERED WHOLE ACROSS THE LADDER, AND WHAT THAT TOOK ----
  -- gap_tail finds the burst inside the scratch by scanning BACK for a run of idle and taking the
  -- last non-idle reading before it. The run it is looking for is the elided gap, and it only
  -- separates the two if nothing inside the HEAD is that long. A head is the resume latency wide,
  -- fixed in TIME, so in bit times it grows with the baud: 156 us is 1.5 bit times at 9600 Bd, 12.5
  -- at 80000 and 18.0 at 115200. Past a frame's width the head carries frame boundaries of its own,
  -- and a mark run across one -- trailing data 1s, the parity bit, the stop bit -- reaches 4 bit
  -- times on lowercase text.
  --
  -- MEASURED HERE BEFORE sdec.gap_tail TOOK framebits AS ITS FLOOR, with the run fixed at
  -- sdec.gap_idlerun's three bit times: at 115200 Bd and 500 kS/s the scan stopped inside the head
  -- and handed back 22 readings of an 87-reading head, 26 of 87 at 208 us, and the payload came out
  -- 88 of 304 bytes -- 29 %. 76800 Bd on the same rate was byte-exact, so it keyed on the baud and
  -- not the capture rate, and with elision off 115200 Bd was byte-exact too.
  --
  -- AND THE PLAN CALLED THAT A SPLICE, which is the part that cost a lap. gap_splice_plan tests the
  -- tail for being non-nil and non-empty, so a quarter of a head counted: spl_why read 'ok', every
  -- seam was paired and spl_norphan was 0, beside a payload that had collapsed. That is the shape
  -- the 2026-10-18 lap reports at the top of the ladder -- splwhy=ok with pay=80/89 -- and it is the
  -- one verdict a reader cannot act on, because 'ok' sends them to the decoder.
  --
  -- SAMPLE-EXACT, not a tolerance: `per` is what the splice put back per seam and `head` is what the
  -- latency took plus gap_idlemargin, both arithmetic, so equality is the available assertion and
  -- anything less than the whole head fails.
  local lo = v99d(76800, {fs = 500000})
  check('at 76800 Bd the splice recovers the WHOLE head and the payload is byte-exact',
        lo.why == 'ok' and lo.nspl == lo.nseam and (lo.norph or 1) == 0
        and lo.per ~= nil and lo.per == lo.head and lo.f ~= nil and lo.f > 0.99, show(lo))
  -- BOTH ENDS OF THE MEASURED LATENCY BRACKET, not one point in it. 156 to 208 us is what the record
  -- brackets the resume at (sdec.gapelide_frames), and a head shown whole at one value inside it
  -- could be a knife edge on the rounding; shown at both it is the band.
  local hi156 = v99d(115200, {fs = 500000})
  local hi208 = v99d(115200, {fs = 500000, lat = 208e-6})
  check('and at 115200 Bd, where the head is 18 bit times, the whole head comes back at 156 us',
        hi156.why == 'ok' and hi156.nspl == hi156.nseam and (hi156.norph or 1) == 0
        and hi156.per ~= nil and hi156.per == hi156.head
        and hi156.f ~= nil and hi156.f > 0.99, show(hi156))
  check('...and at 208 us as well, so the whole measured latency band is covered',
        hi208.why == 'ok' and hi208.per ~= nil and hi208.per == hi208.head
        and hi208.f ~= nil and hi208.f > 0.99, show(hi208))
  -- AND THE RATE IS NOT THE SUBJECT EITHER, held the other way round: 76800 Bd at 1 MS/s is a
  -- 156-reading head against the 78 above, on the same baud.
  local lofast = v99d(76800, {fs = 1000000})
  check('...and 76800 Bd at 1 MS/s, so the rule holds across the rate as well as the baud',
        lofast.why == 'ok' and lofast.per ~= nil and lofast.per == lofast.head
        and lofast.f ~= nil and lofast.f > 0.99, show(lofast))

  -- THE RULE ITSELF, on a scratch built to carry the run that used to defeat it -- because every row
  -- above would also pass if gap_tail had simply stopped searching. A head of two near-all-mark
  -- frames holds an interior mark run far longer than three bit times and shorter than a frame, so
  -- the premise is that the OLD rule would have cut here, asserted from the fixture's own samples
  -- rather than assumed, and the claim is that the current one does not.
  ;(function()
    local baud, fs = 115200, 500000
    local sabit = fs / baud
    local hi, lo2, thr = 3.3, 0.0, 1.65
    local bits = {0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1}
    local seq, ns, i, k = {}, 0, nil, nil
    -- The elided gap first, a detector window of it, then the head.
    for i = 1, math.floor(0.01 * fs) do ns = ns + 1 seq[ns] = hi end
    local hstart = ns + 1
    for i = 1, table.getn(bits) do
      for k = 1, math.floor(sabit) do
        ns = ns + 1
        if bits[i] == 1 then seq[ns] = hi else seq[ns] = lo2 end
      end
    end
    local H = ns - hstart + 1
    -- The longest mark run strictly inside the head, in readings.
    local run, best = 0, 0
    for i = hstart, ns do
      if seq[i] > thr then run = run + 1 if run > best then best = run end else run = 0 end
    end
    local oldneed = math.ceil(sdec.gap_idlerun * sabit)
    check('premise: the head really does carry a mark run past gap_idlerun`s three bit times',
          best >= oldneed and best < math.ceil(10 * sabit),
          string.format('longest interior mark run %d readings, old rule needed %d, a frame is %d',
                        best, oldneed, math.ceil(10 * sabit)))
    local scr = mkscratch(seq, ns, 0)
    local tt, tn = sdec.gap_tail(scr, thr, sabit)
    local want = H + math.ceil(sdec.gap_idlemargin * sabit)
    check('...and gap_tail still returns the whole head, so the floor is the frame and not three',
          tt ~= nil and tn == want,
          string.format('got %s readings, want %d (head %d + margin %d)', tostring(tn), want, H,
                        math.ceil(sdec.gap_idlemargin * sabit)))
  end)()

  -- ---- ALL EIGHT GAP VECTORS AT 28800 Bd: ONE MECHANISM OR EIGHT GEOMETRIES? ----
  -- The judge puts 94 of the hardware lap's 141 BAD cells on these eight, 9 to 14 each, and an even
  -- spread across geometries from 400 to 4800 bit times of gap argues for one mechanism in the elide
  -- path rather than for the gaps. 28800 Bd is where it bites: 8 of the judge's FAILs are there and 4 at
  -- 31250, and the band is also where pick_fs lands on 159 806 and splorph >= 2 appears.
  --
  -- THE ASSERTION IS ON THE BYTES, cyclically through bexp.match, which is the only thing that can see
  -- the class. 'The splice ran' and 'the splice said ok' both pass on every one of the 44 hardware cells
  -- where an ok splice returned confident bytes that were not the payload -- 33 of 110 ok cells and 11 of
  -- 31 partial, and ok against partial does not discriminate. A row here that checked spl_why would be
  -- blind to exactly the defect it is for.
  --
  -- Each vector is driven at ITS OWN declared shape -- format, lead, tail and midgap -- so v98c and v99c
  -- bring their two separate idle runs and make the framer re-anchor twice in one capture, which no other
  -- shape in the set does.
  do
    local gi, nok, nbad, worst, wid = nil, 0, 0, 1.1, nil
    local detail = ''
    for gi = 1, table.getn(GAPVEC) do
      local g = GAPVEC[gi]
      local r = cell({vid = g.id, baud = 28800, lead = g.lead, tail = g.tail, mid = g.mid,
                      at = g.at, nbits = g.nbits, par = g.par, np = 4, lat = 156e-6,
                      loop = true, fsmax = 500000})
      -- The premise, per vector: a vector whose gap is shorter than the detector window records
      -- continuously and tests nothing, so it must not be counted as a pass.
      local elided = (r.elided == true and (r.nseam or 0) > 1)
      local f = r.f
      if elided and f ~= nil and f > 0.99 then nok = nok + 1 else nbad = nbad + 1 end
      if f ~= nil and f < worst then worst, wid = f, g.id end
      detail = detail .. string.format(' %s=%s/%s', g.id,
                                       (f ~= nil) and string.format('%.0f%%', f * 100) or 'nil',
                                       tostring(r.why))
    end
    check('all eight gap vectors elide at 28800 Bd and come back byte-exact on their own geometry',
          nok == 8 and nbad == 0,
          string.format('%d of 8 clean, worst %s at %.0f%%:%s', nok, tostring(wid), worst * 100,
                        detail))
  end

  -- ---- brun.elide_fsmax: WHICH RUNGS OF THE LADDER IT CLOSES ----
  -- The decode gate is arithmetic. decode_from() refuses a forced rate when fs / baud is under
  -- sdec.minsabit * (1 - sdec.plaustol) -- 4 x 0.98 = 3.92 -- and every elided capture is forced,
  -- gap_elide() refusing without a rate. So a cap of C makes every baud above C / 3.92
  -- undecodable on this path whatever the signal does, and the splice says so: spl_why is 'ok' on
  -- all of them.
  --
  -- THE SETS BELOW ARE THE HARDWARE'S, cell for cell. SOAK-20261018-gaplap-merged-splice.csv:
  -- the final lap ran brun.elide_fsmax = 500000 and refused v99d at 128000, 149009, 153600,
  -- 156354, 172800, 189041, 192000, 210286 and 230400 -- nine of nine, each with splwhy=ok -- and
  -- an earlier run of the same file carried 640000 and refused 172800, 192000 and 230400 while
  -- 128000 and 153600 decoded 89 and 80 frames with no bad frame in either. This reproduces both
  -- boundaries, so a change to the cap, to minsabit or to plaustol moves a count here and is not
  -- silent.
  local LAD = {115200, 124606, 128000, 149009, 153600, 156354, 172800, 189041, 192000,
               210286, 230400}
  local function sweep(fsmax)
    local out, nref, b, i = {}, 0, nil, nil
    for i = 1, table.getn(LAD) do
      b = LAD[i]
      local r = v99d(b, {fsmax = fsmax})
      if r.dok == false then nref = nref + 1 out[nref] = b end
      -- Whatever the decode did, the splice must still have run: a refusal that also lost the
      -- splice would make the count below agree for the wrong reason.
      if r.why ~= 'ok' then out.badwhy = (out.badwhy or '') .. ' ' .. b .. '=' .. tostring(r.why) end
    end
    out.n = nref
    return out
  end
  local function lst(s)
    local t, i = '', nil
    for i = 1, s.n do t = t .. (i > 1 and ',' or '') .. s[i] end
    return '[' .. t .. '] badwhy=' .. tostring(s.badwhy)
  end
  local c500 = sweep(500000)
  check('cap 500000 closes nine rungs, 128000 Bd up, exactly the hardware lap`s nine',
        c500.n == 9 and c500[1] == 128000 and c500[9] == 230400 and c500.badwhy == nil, lst(c500))
  local c640 = sweep(640000)
  check('cap 640000 closes five, 172800 Bd up -- so 128000 and 153600 decode, as they did',
        c640.n == 5 and c640[1] == 172800 and c640[5] == 230400 and c640.badwhy == nil, lst(c640))
  local cnil = sweep(nil)
  check('and with no cap the ladder is open to its top: 230400 Bd gets 4.34 samples/bit',
        cnil.n == 0 and cnil.badwhy == nil, lst(cnil))
  -- THE CAP IS WHAT CLOSED THEM, not the rate the app would have chosen. 1 MS/s is the only listed
  -- rate at or above 230400 x 3.92 = 903168, so the cap and the ladder's top cannot both stand.
  check('the premise of the three rows above: 230400 Bd is inside sdec.maxbaud and needs 1 MS/s',
        230400 <= sdec.maxbaud and top.fs == 1000000
        and sdec.pick_fs(230400, sdec.minsabit) == 1000000,
        string.format('maxbaud=%s topfs=%s pick=%s', tostring(sdec.maxbaud), tostring(top.fs),
                      tostring(sdec.pick_fs(230400, sdec.minsabit))))


  sdec.gap_nscratch = keep.ns
  pcall(sdec.gap_release_all)
  sdec.gapelide, sdec.force_baud, sdec.capmode = keep.ge, keep.fb, keep.cm
  sdec.trigmode, sdec.strm_maxsec, sdec.n = keep.tm, keep.ms, keep.n
  sdec.fs, sdec.fs_want, sdec.proto, sdec.ui_mode = keep.fs, keep.fw, keep.pr, keep.um
  sdec.force_nbits, sdec.force_par, sdec.force_nstop = keep.nb, keep.pa, keep.st
  sdec.force_invert, sdec.arm_thr, sdec.arm_idle, sdec.probe_idle = keep.iv, keep.at, keep.ai, keep.pi
  TRIG_RESUME(keep.lat)
  SRC.rd, SRC.ts, SRC.nsmp = keep.rd, keep.ts, keep.nsmp
  SRC.loop, SRC.native_fs, SRC.trigat = keep.lp, keep.nf, keep.ta
  TRIG_WALK(keep.w == true)
  SRC_TRIGDERIVE(keep.d == true)
  check('and the ladder block leaves the depth, the rate and the format as it found them',
        sdec.n == keep.n and sdec.fs == keep.fs and sdec.force_nbits == keep.nb
        and sdec.capmode == keep.cm,
        string.format('n=%s fs=%s nbits=%s capmode=%s', tostring(sdec.n), tostring(sdec.fs),
                      tostring(sdec.force_nbits), tostring(sdec.capmode)))
end)()

print(string.format('\n%d passed, %d failed', pass, fail))
if fail > 0 then
  local i
  for i = 1, table.getn(failed) do print('  - ' .. failed[i]) end
  os.exit(1)
end

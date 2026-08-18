-- debug_serial.lua -- diagnostic dump for the serial decoder's decision making.
--
-- test_serial.lua asserts outcomes; this explains them. It prints the pulse-width
-- histogram, every bit-time seed and its fit quality, and the score of every
-- format the search considered -- which is the only practical way to tell a
-- genuine protocol ambiguity apart from a bug in the scoring.
--
-- Run from the repo root:  lua tools/debug_serial.lua [case]

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

dofile('tools/gen_serial.lua')          -- shared waveform generator + mocks

local function dump(label, opts)
  print('\n================ ' .. label .. ' ================')
  local rd, ts, nc, nsmp = GEN(opts)
  local fs = opts.fs or 1000000
  sdec.acq_fs = fs
  local ok, why = sdec.sig_levels(rd, nsmp)
  print(string.format('levels: ok=%s lo=%.3f hi=%.3f thr=%.3f hyst=%.3f  %s',
        tostring(ok), sdec.lo or -99, sdec.hi or -99, sdec.thr, sdec.hyst,
        why or ''))
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  local Tb = fs / (opts.baud or 9600)
  print(string.format('samples=%d edges=%d idle=%d (run1=%.1f run0=%.1f)  true T=%.4f sa',
        nsmp, sdec.ne, sdec.idle, sdec.run1 or -1, sdec.run0 or -1, Tb))

  -- pulse-width histogram in units of the TRUE bit time
  local hist = {}
  local i
  for i = 1, sdec.ne - 1 do
    local m = string.format('%.2f', (sdec.ei[i+1] - sdec.ei[i]) / Tb)
    hist[m] = (hist[m] or 0) + 1
  end
  local keys = {}
  for k in pairs(hist) do keys[table.getn(keys) + 1] = k end
  table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
  local hs = {}
  for i = 1, table.getn(keys) do
    hs[i] = keys[i] .. 'T x' .. hist[keys[i]]
  end
  print('widths: ' .. table.concat(hs, '  '))

  local T = sdec.sig_bittime()
  print(string.format('fit: T=%s sa (%.4f true bits)  q=%.4f  baud_raw=%.1f  baud=%s snapped=%s',
        T and string.format('%.4f', T) or 'nil', T and T / Tb or -1, sdec.fitq,
        sdec.baud_raw or -1, tostring(sdec.baud), tostring(sdec.snapped)))
  if T == nil then return end

  -- every format, scored, best first
  local rows = {}
  local pn = {'N', 'E', 'O'}
  local a, b, c, d
  for a = 0, 1 do
    local inv = (a == 1)
    for b = 1, table.getn(sdec.try_nbits) do
      for c = 1, table.getn(sdec.try_par) do
        for d = 1, table.getn(sdec.try_stop) do
          local nb, pr, ns = sdec.try_nbits[b], sdec.try_par[c], sdec.try_stop[d]
          local r = sdec.ua_run(rd, nsmp, T, nb, pr, ns, inv)
          if r.nf > 0 then
            rows[table.getn(rows) + 1] = {
              name = string.format('%d%s%d%s', nb, pn[pr + 1], ns, inv and ' inv' or ''),
              sc = sdec.ua_score(r), nf = r.nf, ngood = r.ngood, nbad = r.nbad,
            }
          end
        end
      end
    end
  end
  table.sort(rows, function(x, y) return x.sc > y.sc end)
  local n = table.getn(rows)
  if n > 8 then n = 8 end
  for i = 1, n do
    local r = rows[i]
    print(string.format('  %-9s score=%-5d frames=%-4d good=%-4d bad=%d',
          r.name, r.sc, r.nf, r.ngood, r.nbad))
  end
end

-- For each candidate bit-time rescaling, what the probe sees. This is the table
-- that decides sdec.ua_best(), so it is the one to look at when the baud comes
-- out a factor of two or three off.
local function ratios(label, opts, mangle)
  print('\n---------------- ratios: ' .. label .. ' ----------------')
  local rd, ts, nc, nsmp = GEN(opts)
  if mangle then mangle(rd, nsmp) end
  local fs = opts.fs or 1000000
  sdec.acq_fs = fs
  sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  local Tfit = sdec.sig_bittime()
  local Tb = fs / (opts.baud or 9600)
  if Tfit == nil then print('  no fit'); return end
  local span = sdec.ei[sdec.ne] - sdec.ei[1]
  print(string.format('  Tfit=%.4f sa = %.4f true bits;  true baud %d;  span %.1f sa',
        Tfit, Tfit / Tb, opts.baud or 9600, span))
  local pn = {'N', 'E', 'O'}
  local i, j, k
  for i = 1, table.getn(sdec.ratios) do
    local T = Tfit * sdec.ratios[i]
    local okp = sdec.ua_plausible(T, nsmp)
    local baud = fs / T
    local snapb, snapped = sdec.sig_snap(baud)
    local bsc, bnb, bfb, bg, bb = nil, nil, nil, nil, nil
    if okp then
      for j = 1, table.getn(sdec.probe_nbits) do
        for k = 0, 1 do
          local r = sdec.ua_run(rd, nsmp, T, sdec.probe_nbits[j], sdec.PAR_NONE, 1, (k == 1))
          if r.ngood >= 1 then
            local s = sdec.ua_score(r)
            if bsc == nil or s > bsc then
              bsc, bnb, bfb, bg, bb = s, sdec.probe_nbits[j], r.framebits, r.ngood, r.nbad
            end
          end
        end
      end
    end
    local cov = 0
    if bsc ~= nil then cov = bsc * bfb * T / span end
    print(string.format('  r=%-7.4f T=%8.4f (%.3fT) baud=%9.1f %-7s %s best=%sN1 sc=%s good=%s bad=%s cov=%.3f',
          sdec.ratios[i], T, T / Tb, baud,
          snapped and ('->' .. tostring(snapb)) or 'unsnap',
          okp and ' ' or 'X',
          tostring(bnb), tostring(bsc), tostring(bg), tostring(bb), cov))
  end
end

local HELLO = GEN_BYTES('Hello, World!')
local function rep(v, k) local t = {} local i for i = 1, k do t[i] = v end return t end

local case = arg and arg[1]

if case == nil or case == '00' then
  dump('all 0x00 x6, 9600 @ 100k, gap 2', {bytes = rep(0, 6), baud = 9600, fs = 100000})
end
if case == nil or case == '55' then
  dump('all 0x55 x6, 9600 @ 100k, gap 2', {bytes = rep(0x55, 6), baud = 9600, fs = 100000})
end
if case == nil or case == 'one' then
  dump('single 0x41, 9600 @ 100k', {bytes = {0x41}, baud = 9600, fs = 100000})
end
if case == nil or case == 'glitch' then
  local rd, ts, nc, nsmp = GEN({bytes = HELLO, baud = 9600, fs = 100000})
  rd[900], rd[901] = 0.0, 0.0
  print('\n================ glitched idle line ================')
  sdec.acq_fs = 100000
  sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  local Tb = 100000 / 9600
  print(string.format('edges=%d  true T=%.4f', sdec.ne, Tb))
  -- show every seed the search would try, with its fit
  local w, s = {}, {}
  local i
  for i = 1, sdec.ne - 1 do w[i] = sdec.ei[i+1] - sdec.ei[i]; s[i] = w[i] end
  table.sort(s)
  local nw = sdec.ne - 1
  local last, nseed = 0, 0
  for i = 1, nw do
    if s[i] > 0 and (nseed == 0 or s[i] > 1.3 * last) then
      nseed = nseed + 1
      last = s[i]
      local T, q, nfit = sdec.sig_fit(w, nw, s[i])
      print(string.format('  seed %8.4f sa (%.3f T) -> T=%s q=%.4f nfit=%d',
            s[i], s[i] / Tb, T and string.format('%.4f', T) or 'nil', q, nfit))
      if nseed >= 4 then break end
    end
  end
  local T = sdec.sig_bittime()
  print(string.format('  CHOSE T=%.4f (%.3f true bits) -> %s baud',
        T or -1, (T or 0) / Tb, tostring(sdec.baud)))
end
if case == nil or case == '5n1' then
  dump('5N1 gap=2', {bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
                     baud = 9600, fs = 100000, nbits = 5, par = 0, nstop = 1})
  dump('5N1 gap=0', {bytes = {0x11, 0x0A, 0x15, 0x1F, 0x00, 0x1A, 0x07, 0x13},
                     baud = 9600, fs = 100000, nbits = 5, par = 0, nstop = 1, gap = 0})
end
if case == nil or case == '8n2' then
  dump('8N2', {bytes = HELLO, baud = 9600, fs = 100000, nstop = 2})
end
if case == nil or case == 'gapless' then
  dump('gapless, no lead', {bytes = HELLO, baud = 9600, fs = 100000,
                            lead = 0, gap = 0, tail = 0})
end

if case == 'ratios' then
  local function rep2(v, k) local t = {} local i for i = 1, k do t[i] = v end return t end
  ratios('all 0x00 x6 (true 9600)', {bytes = rep2(0, 6), baud = 9600, fs = 100000})
  ratios('all 0x55 x6 (true 9600)', {bytes = rep2(0x55, 6), baud = 9600, fs = 100000})
  ratios('all 0xAA x6 (true 9600)', {bytes = rep2(0xAA, 6), baud = 9600, fs = 100000})
  ratios('8E1 text (true 9600)', {bytes = HELLO, baud = 9600, fs = 100000, par = 1})
  ratios('glitched idle (true 9600)', {bytes = HELLO, baud = 9600, fs = 100000},
         function(rd) rd[900] = 0.0; rd[901] = 0.0 end)
  ratios('clean text (true 9600)', {bytes = HELLO, baud = 9600, fs = 100000})
end

if case == 'u55x10' then
  local t = {} for i = 1, 10 do t[i] = 0x55 end
  dump('0x55 x10 (true 9600 8N1)', {bytes = t, baud = 9600, fs = 100000})
end

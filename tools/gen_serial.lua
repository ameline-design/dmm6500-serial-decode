-- gen_serial.lua -- synthetic UART waveform generator and mocked DMM6500,
-- shared by tools/test_serial.lua (asserts) and tools/debug_serial.lua (explains).
--
-- The generator is what stands in for the bench while the instruments are away.
-- A real capture gives one baud rate, one format and whatever noise the bench
-- happened to have; this gives every combination on demand, including the cases
-- that are awkward to produce deliberately: 8.68 samples per bit, an inverted
-- RS-232 line, a stream with no idle gap anywhere, a capture that stops
-- mid-frame, a sub-bit glitch.
--
-- Loads the REAL tsp/*.tsp sources via loadfile -- not a re-implementation,
-- which would drift from them.
--
-- Exports: GEN(opts), GEN_BYTES(str), GEN_STR(vals, n), GEN_RESEED(s),
--          SRC, TRIG, READS, LIVEBUFS()
--          GEN_WRITE/GEN_READ/GEN_CODE/GEN_VOLTS/GEN_CKSUM (SDG arb export)

-- ---------- Lua 5.0.2 compatibility shims ----------
-- The instrument runs 5.0.2; host Lua is 5.4/5.5 and dropped these two.
-- tools/lint_tsp.py separately guards against 5.0.2 SYNTAX incompatibilities.
table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

-- Deterministic Park-Miller PRNG. Tests must be reproducible, and the modulus
-- and multiplier keep every intermediate under 2^53 and therefore exact in a
-- double; math.random would vary across Lua versions.
local rs = 12345
local function rnd()
  rs = math.fmod(rs * 16807, 2147483647)
  return rs / 2147483647
end
function GEN_RESEED(s) rs = s or 12345 end
-- EXPORTED so a vector can be built from KNOWN random bytes. A random payload is the only stimulus
-- that catches a decode depending on a byte's VALUE rather than its timing -- a parity refinement
-- that only holds for text, a format search biased by ASCII's clear top bit -- and it is only usable
-- as an oracle if the same seed gives the same bytes on every machine, which is why this generator
-- and not math.random.
function GEN_RAND() return rnd() end

local function popcount(v)
  local ones, t = 0, v
  while t > 0 do
    if math.fmod(t, 2) >= 1 then ones = ones + 1 end
    t = math.floor(t / 2)
  end
  return ones
end

-- INJECTED PARITY ERRORS: the frame indices to corrupt, evenly spaced. -> array, 1-based.
--
-- Even spacing is not cosmetic. For a payload that LOOPS on the generator, if the interval divides the
-- capture window the number of errors a capture sees is the same wherever it lands -- so the count can be
-- asserted instead of eyeballed. Computed over all 300 start offsets: 300 bytes with an error every 30
-- yields exactly 8 in a 240-byte window; every 25 gives 9 or 10.
--
-- `first` defaults past sdec.ua_edge_frames, and that default is the point of this helper. The decoder
-- excludes the first 3 frames and the last one as windowing artefacts, so an error injected at frame 2
-- is not counted, not coloured, and proves nothing -- a vector built that way would be named for errors
-- it cannot demonstrate.
function GEN_PERR_EVERY(nb, step, first)
  if step == nil or step < 1 then error('GEN_PERR_EVERY needs a step >= 1', 2) end
  if first == nil then first = 4 end
  local out, n, i = {}, 0, nil
  -- Stops one short of nb: the final frame is excluded too, by the capture boundary that halves it.
  for i = first, nb - 1, step do
    n = n + 1
    out[n] = i
  end
  return out, n
end

-- ============================================================================
-- GEN(opts) -> rd, ts, ncells, nsamples
-- ============================================================================
--   bytes   array of byte values to transmit
--   baud    bit rate                      fs      sample rate
--   nbits   data bits (8)                 par     0 none / 1 even / 2 odd
--   nstop   stop bits (1)                 invert  true for an idle-low RS-232 sense
--   perr    array of 1-based FRAME indices whose parity bit is inverted (see below)
--   lo, hi  logic levels in volts (0 / 3.3)
--   lead    bit times of idle before the first frame (20)
--   gap     bit times of idle between frames (2)
--   tail    bit times of idle after the last frame (20)
--   rise    edge transition time in SAMPLE PERIODS (1.5)
--   noise   peak noise amplitude in volts (0)
--   phase   fraction of a bit cell to shift the sampling grid (0.37, so the
--           capture does not start neatly on a cell boundary -- a real one never
--           does, and assuming it does hides off-by-half-a-sample bugs)
--   n       samples to render (default: the whole stream)
function GEN(opts)
  local nbits = opts.nbits or 8
  local par   = opts.par or 0
  local nstop = opts.nstop or 1
  local lead  = opts.lead or 20
  local gap   = opts.gap or 2
  local tail  = opts.tail or 20
  local bytes = opts.bytes or {}
  local nb    = table.getn(bytes)

  -- INJECTED PARITY ERRORS, as a lookup keyed by frame index.
  --
  -- IT RAISES RATHER THAN IGNORING. par == 0 has no parity bit, so there is nothing to invert; an index
  -- outside 1..nb corrupts nothing. Either would hand back a waveform that silently lacks the errors the
  -- caller asked for -- and since these vectors are NAMED for their error count (SER_..._PErr8), a quiet
  -- miss makes the name a lie and every assertion built on it vacuous.
  local perrset, nperr = nil, 0
  if opts.perr ~= nil then
    local np = table.getn(opts.perr)
    if np > 0 then
      if par == 0 then
        error('opts.perr needs a parity bit to invert; par is 0 (no parity)', 2)
      end
      perrset = {}
      local i
      for i = 1, np do
        local fi = opts.perr[i]
        if fi == nil or fi < 1 or fi > nb then
          error(string.format('opts.perr[%d] = %s is outside 1..%d frames',
                              i, tostring(fi), nb), 2)
        end
        if perrset[fi] == nil then nperr = nperr + 1 end
        perrset[fi] = true
      end
    end
  end

  -- ---- logical bit cells: 1 = mark/idle, 0 = space ----
  local cells, nc = {}, 0
  local i, k
  for i = 1, lead do nc = nc + 1; cells[nc] = 1 end
  for i = 1, nb do
    local v = bytes[i]
    nc = nc + 1; cells[nc] = 0                       -- start bit
    local t = v
    for k = 1, nbits do                              -- data, LSB first
      nc = nc + 1
      cells[nc] = math.fmod(t, 2)
      t = math.floor(t / 2)
    end
    if par ~= 0 then
      local pe = math.fmod(popcount(math.fmod(v, 2 ^ nbits)), 2)
      nc = nc + 1
      if par == 1 then cells[nc] = pe else cells[nc] = 1 - pe end
      -- THE PARITY BIT ONLY. The data cells are already emitted and untouched, which is what makes this
      -- a parity error rather than a corrupt byte: the decoder should recover the CORRECT value and flag
      -- the frame. So the expected bytes are unchanged and only the expected error positions move.
      if perrset ~= nil and perrset[i] then cells[nc] = 1 - cells[nc] end
    end
    for k = 1, nstop do nc = nc + 1; cells[nc] = 1 end
    if i < nb then
      for k = 1, gap do nc = nc + 1; cells[nc] = 1 end
    end
  end
  for i = 1, tail do nc = nc + 1; cells[nc] = 1 end

  return GEN_RENDER(cells, nc, opts)
end

-- ============================================================================
-- GEN_RENDER(cells, nc, opts) -> rd, ts, ncells, nsamples
-- ============================================================================
-- Render a logical CELL array to volts. Split out of GEN so a protocol whose framing is
-- not "a run of 8N1 bytes" can build its own cells and still get exactly the same edge
-- shaping, noise and sampling phase -- GEN_LIN needs a 13-bit dominant break, which no
-- byte can express.
--
-- Reads the same opts keys GEN does: baud, fs, lo, hi, rise, noise, phase, invert, n.
function GEN_RENDER(cells, nc, opts)
  local baud  = opts.baud or 9600
  local fs    = opts.fs or 1000000
  local lo    = opts.lo or 0
  local hi    = opts.hi or 3.3
  local rise  = opts.rise
  if rise == nil then rise = 1.5 end
  local fall  = opts.fall            -- nil = symmetric with rise (see the ramp below)
  local noise = opts.noise or 0
  local phase = opts.phase
  if phase == nil then phase = 0.37 end

  local Tb   = fs / baud                 -- bit time in samples

  -- opts.loop: render an EXACT whole number of bit times, so the waveform can be played on repeat
  -- with a seamless join. The default length is floor(nc*Tb)+2, which lands mid-cell -- and a
  -- TrueArb loop then splices the last partial cell onto the first, corrupting the frame that
  -- straddles the junction. Measured against v71 (106877 points = 10260.19 bit times at 9600 baud):
  -- one interior bad frame in nearly every capture, which reads as a decoder fault and is not one.
  --
  -- nsmp must be a multiple of Tb's numerator in lowest terms -- 125 for fs/baud = 100000/9600 --
  -- so the cell count is padded with idle up to the next exact boundary. GEN pads with mark, which
  -- is idle, so the padding lengthens the inter-message gap and nothing else.
  local nsmp = opts.n
  if nsmp == nil and opts.loop then
    local num = fs
    local den = baud
    local a, b = num, den
    while b ~= 0 do a, b = b, math.mod(a, b) end     -- gcd
    local step = num / a                             -- samples per exact group of bit times
    nsmp = math.ceil(nc * Tb / step) * step
  end
  if nsmp == nil then nsmp = math.floor(nc * Tb) + 2 end
  local rd, ts = {}, {}
  local i

  -- JITTER: each cell boundary displaced independently, as a fraction of a bit time.
  --
  -- opts.jitter = 0.1 means every edge lands within +/-10% of a unit interval of where it should.
  -- This is the impairment that attacks the BAUD DETECTOR rather than the framing, and it does so
  -- at its weakest point: sig_bittime fits the greatest common period of the observed pulse
  -- widths, so it already errs SHORT when one pulse is narrow (which is why sdec.ratios carries
  -- integer multiples well above 1). Jitter makes EVERY pulse a slightly wrong multiple, so the
  -- greatest common divisor of the set can collapse far below the true bit time -- a failure mode
  -- no amount of amplitude noise reproduces.
  --
  -- IT IS ALSO SCALE-FREE, which matters for the bench: a displacement expressed as a fraction of
  -- a bit time stays the same fraction whatever rate the waveform is replayed at. So ONE jittered
  -- vector, swept over SRATE, is a jitter test at every baud rate.
  --
  -- Boundaries are built cumulatively and CLAMPED monotonic. Independent displacements of more
  -- than half a UI could otherwise reorder two boundaries, which is not jitter but a deleted cell,
  -- and it would make the sample-to-cell walk below go backwards.
  local jitter = opts.jitter or 0
  local bnd = nil
  if jitter > 0 then
    bnd = {}
    local k
    bnd[1] = 0
    for k = 2, nc + 1 do
      local nominal = (k - 1) * Tb
      local d = 0
      if k <= nc then d = jitter * Tb * (rnd() * 2 - 1) end
      local b = nominal + d
      -- Never closer than a tenth of a bit to the previous boundary: a cell of zero width is a
      -- missing cell, and that is a different defect being tested by accident.
      if b < bnd[k - 1] + 0.1 * Tb then b = bnd[k - 1] + 0.1 * Tb end
      bnd[k] = b
    end
  end

  -- Where the walk has got to, for the jittered path. Samples are monotonic so this only ever
  -- moves forward, which keeps the whole render linear rather than a binary search per sample.
  local ptr = 1

  for i = 1, nsmp do
    local xs = (i - 1) + phase * Tb                -- position in SAMPLES
    local x = xs / Tb                              -- position in cells
    local ci, cstart
    if bnd == nil then
      ci = math.floor(x) + 1
      cstart = (ci - 1) * Tb
    else
      while ptr < nc and bnd[ptr + 1] <= xs do ptr = ptr + 1 end
      ci = ptr
      cstart = bnd[ci]
      if xs < bnd[1] then ci = 0 end               -- before the first cell: idle
    end
    local lvl
    if ci < 1 or ci > nc then lvl = 1 else lvl = cells[ci] end

    if rise > 0 then
      -- Blend from the previous cell over the first `rise` SAMPLES of this cell,
      -- so an edge is a ramp rather than a step. Without this the threshold
      -- crossing always lands exactly midway between two samples and the
      -- sub-sample interpolation in sig_cross has nothing to recover.
      local into = xs - cstart                     -- samples since the cell began
      local pv
      if ci - 1 < 1 or ci - 1 > nc then pv = 1 else pv = cells[ci - 1] end
      -- WHICH time constant: a transition UP uses rise, a transition DOWN uses fall. An unset
      -- opts.fall falls back to rise for both, which is symmetric.
      local edge = rise
      if pv ~= lvl and lvl < pv and fall ~= nil then edge = fall end
      if into < edge and pv ~= lvl then
        local f = into / edge
        lvl = pv + (lvl - pv) * f
      end
    end

    local phys = lvl
    if opts.invert then phys = 1 - lvl end
    local v = lo + (hi - lo) * phys
    if noise > 0 then v = v + noise * (rnd() * 2 - 1) end
    rd[i] = v
    ts[i] = (i - 1) / fs
  end

  -- BANDWIDTH LIMITING -- "a crappy probe that filters out the high frequencies".
  --
  -- opts.rc is a first-order low-pass time constant expressed in BIT TIMES, which is the unit that
  -- makes it scale-free: rc = 0.25 means the RC is a quarter of a bit whatever the baud rate, so
  -- the same number describes the same damage at 300 Bd and 115200 Bd. A real probe, a long
  -- unterminated cable, a series resistor into a capacitive input, or an opto-isolator all look
  -- like this.
  --
  -- WHY IT IS MORE DANGEROUS THAN NOISE, and the reason it is worth its own parameter: noise is
  -- random and averages out, whereas this is SYSTEMATIC. Two effects, both one-directional:
  --
  --   1. SAG. A run of identical bits decays toward the far rail, so the level a long run reaches
  --      differs from the level a short one reaches -- and sig_levels fits ONE pair of levels for
  --      the whole capture.
  --   2. DUTY-CYCLE DISTORTION. A narrow pulse never reaches full amplitude before it is over, so
  --      its threshold crossings move INWARD -- every short pulse measures narrower than it is,
  --      consistently. That attacks sig_bittime directly, because the fit takes the greatest
  --      common period of the measured widths, and it biases every measurement the same way
  --      rather than scattering them.
  --
  -- Applied after the noise, so `noise` is filtered too -- i.e. it models noise generated at the
  -- SOURCE rather than picked up at the receiver. For pickup at the receiver, filter first is
  -- wanted; nothing here needs that yet and one pass is cheaper than two.
  local rc = opts.rc or 0
  if rc > 0 then
    local tau = rc * Tb
    local alpha = 1 - math.exp(-1 / tau)
    local y = rd[1]
    for i = 1, nsmp do
      y = y + (rd[i] - y) * alpha
      rd[i] = y
    end
  end

  -- ASYMMETRIC EDGES -- an open-drain line with a pull-up.
  --
  -- opts.fall, in SAMPLE PERIODS like opts.rise. A bit-banged UART on an open-collector output
  -- pulls DOWN hard through a transistor and rises only through a resistor into whatever
  -- capacitance the line has, so rise and fall differ by an order of magnitude. This is extremely
  -- common and, like the RC above, it distorts duty cycle in ONE direction -- so it is the other
  -- systematic hazard worth being able to generate. Handled in the ramp above by selecting which
  -- time constant applies to this transition; see the `rise` block.
  return rd, ts, nc, nsmp
end

function GEN_BYTES(s)
  local t, n = {}, 0
  local i
  for i = 1, string.len(s) do
    n = n + 1
    t[n] = string.byte(s, i)
  end
  return t, n
end

-- Render decoded values as a string for eyeballing in test output. Values can
-- legitimately exceed 255 (a 9-data-bit format, or a wrong forced baud rate that
-- lands on one), so anything outside a byte becomes '.' rather than raising.
function GEN_STR(vals, nf)
  local t = {}
  local i
  for i = 1, nf do
    local v = vals[i]
    if v == nil or v < 0 or v > 255 then t[i] = '.' else t[i] = string.char(v) end
  end
  return table.concat(t)
end

-- ============================================================================
-- SDG arbitrary-waveform export
-- ============================================================================
-- Turns a GEN() volt array into a file the SDG2122X can play, so the SAME vector
-- that produced an offline result drives the real bench. That is what makes a
-- hardware result comparable to the offline one byte for byte rather than merely
-- plausible: any divergence is then a fact about the instrument.
--
-- Format, confirmed from the SDG Programming Guide PG02-E05B and NOT from memory:
--
--   §4.1 "The bin file content is binary, and the file content is the codeword
--   value of each point (codeword range -32768~32767). [...] When the machine
--   imports the file, it maintains the current amplitude, frequency and offset
--   information, and directly converts each codeword value into voltage output."
--
--   §5.1.3's worked example carries the byte order in a comment -- "Little
--   endian, 16-bit 2's complement" -- and builds 0x1000,0x2000..0x7FFF as the
--   byte pairs 00 10, 00 20 .. FF 7F. So: raw int16 LE, no header, no
--   terminator, nothing else in the file. test_serial.lua pins the encoder to
--   that published example, which is the one oracle here that is not ours.
--
--   bin is the right choice over csv/dat: all three are listed for the SDG2000X
--   but only bin's layout is specified for it (§4.2 describes the csv header
--   against the SDG7000A), and bin is also what the WVDT upload path takes, so
--   one encoder serves both file-on-USB and direct-over-LAN.
--
-- THE FILE CARRIES SHAPE, THE INSTRUMENT CARRIES VOLTS. A codeword is a
-- fraction of whatever AMP is set to, so the same file at a different AMP is a
-- different signal. Every write therefore returns the amp/ofst it assumed, and
-- the manifest records them per file -- the bench must never set amplitude from
-- memory.
--
-- Amplitude ceiling: 20 Vpp into high-Z (BSWV MAX_OUTPUT_AMP takes {1-20}, and
-- the published specs give max amplitude as +/-10 V), so fsv cannot exceed 10.
-- The offline suite is not amplitude-limited and the hardware is; a vector with
-- +/-25 V spikes CANNOT be reproduced on this generator. Hence the default is
-- to raise rather than clip -- a clipped stimulus decodes wrongly and looks
-- exactly like a decoder bug.
GEN_SDG_MAXPTS = 8388608        -- bin length 4 B .. 16 MB at 2 bytes/point
GEN_SDG_MINPTS = 2              -- the 4 B floor. The panel spec says 8 pts
GEN_SDG_MAXFSV = 10.0           -- half of the 20 Vpp ceiling
GEN_SDG_MINSR  = 1e-6           -- TrueArb sample rate range, Sa/s
GEN_SDG_MAXSR  = 75e6

-- volts -> codeword. Rounds half away from zero, which is what keeps the
-- round-trip through GEN_VOLTS symmetric about the offset.
function GEN_CODE(v, fsv, ofst)
  local x = (v - ofst) / fsv * 32767
  if x >= 0 then return math.floor(x + 0.5) end
  return -math.floor(-x + 0.5)
end

-- codeword -> volts. +32767 is +fsv by construction; -32768 is a half-LSB
-- beyond -fsv, which at 20 Vpp is 0.3 mV and below anything that matters here.
function GEN_VOLTS(c, fsv, ofst)
  return ofst + c / 32767 * fsv
end

-- Fletcher-32 over the encoded bytes. Not cryptographic and not meant to be:
-- it exists so a file copied to the USB key can be re-checked at the bench
-- against the manifest, because a truncated copy plays as a truncated waveform
-- and there is nothing on screen to say so.
function GEN_CKSUM(s)
  local a, b = 1, 0
  local i
  for i = 1, string.len(s) do
    a = math.fmod(a + string.byte(s, i), 65521)
    b = math.fmod(b + a, 65521)
  end
  return b * 65536 + a
end

-- GEN_WRITE(path, rd, n, o) -> nbytes, info
--
--   o.fsv    full-scale volts, i.e. AMP/2 (default 5.0 -> set AMP 10 Vpp)
--   o.ofst   offset volts the generator will be set to (default 0)
--   o.clip   true to saturate out-of-range samples instead of raising
--
-- info carries {npts, nbytes, amp_vpp, ofst_v, fsv, min_v, max_v, nclip,
-- cksum, peak_code}. path = nil encodes without writing, which is how the
-- tests exercise it.
function GEN_WRITE(path, rd, n, o)
  o = o or {}
  local fsv  = o.fsv or 5.0
  local ofst = o.ofst or 0
  if fsv <= 0 then error('GEN_WRITE: fsv must be positive', 0) end
  if fsv > GEN_SDG_MAXFSV then
    error(string.format('GEN_WRITE: fsv %.3f V exceeds the %.1f V ceiling ' ..
                        '(20 Vpp max)', fsv, GEN_SDG_MAXFSV), 0)
  end
  if n < GEN_SDG_MINPTS or n > GEN_SDG_MAXPTS then
    error(string.format('GEN_WRITE: %d points outside %d..%d', n,
                        GEN_SDG_MINPTS, GEN_SDG_MAXPTS), 0)
  end

  local parts, np = {}, 0            -- chunked so the concat stays linear
  local chunk, ncw = {}, 0
  local minv, maxv, nclip, peak = rd[1], rd[1], 0, 0
  local i
  for i = 1, n do
    local v = rd[i]
    if v == nil then
      error(string.format('GEN_WRITE: sample %d is nil', i), 0)
    end
    if v < minv then minv = v end
    if v > maxv then maxv = v end
    local c = GEN_CODE(v, fsv, ofst)
    if c > 32767 or c < -32768 then
      if not o.clip then
        error(string.format('GEN_WRITE: sample %d is %.3f V, outside the ' ..
                            '%.3f V full scale at offset %.3f V -- raise fsv ' ..
                            'or pass clip=true and accept a distorted ' ..
                            'stimulus', i, v, fsv, ofst), 0)
      end
      nclip = nclip + 1
      if c > 32767 then c = 32767 else c = -32768 end
    end
    if c > peak then peak = c end
    if -c > peak then peak = -c end
    local u = c
    if u < 0 then u = u + 65536 end
    local blo = math.fmod(u, 256)
    ncw = ncw + 1
    chunk[ncw] = string.char(blo, (u - blo) / 256)
    if ncw >= 4096 then
      np = np + 1; parts[np] = table.concat(chunk)
      chunk, ncw = {}, 0
    end
  end
  if ncw > 0 then np = np + 1; parts[np] = table.concat(chunk) end
  local s = table.concat(parts)

  if path ~= nil then
    local f, err = io.open(path, 'wb')
    if f == nil then error('GEN_WRITE: cannot open ' .. path .. ': ' ..
                           tostring(err), 0) end
    f:write(s)
    f:close()
  end

  return string.len(s), {npts = n, nbytes = string.len(s), fsv = fsv,
                         amp_vpp = fsv * 2, ofst_v = ofst, min_v = minv,
                         max_v = maxv, nclip = nclip, peak_code = peak,
                         cksum = GEN_CKSUM(s)}
end

-- GEN_READ(path) -> codewords, n
--
-- An INDEPENDENT decode of the file, written from the format description rather
-- than by inverting GEN_WRITE's expression, so a round-trip test can catch a
-- byte-order or sign error instead of confirming one. Returns codewords, not
-- volts: the file does not know what AMP it will be played at.
function GEN_READ(path)
  local f, err = io.open(path, 'rb')
  if f == nil then error('GEN_READ: cannot open ' .. path .. ': ' ..
                         tostring(err), 0) end
  local s = f:read('*a')
  f:close()
  local len = string.len(s)
  if math.fmod(len, 2) ~= 0 then
    error(string.format('GEN_READ: %s is %d bytes, not a whole number of ' ..
                        '16-bit points', path, len), 0)
  end
  local out, n = {}, 0
  local i
  for i = 1, len, 2 do
    local u = string.byte(s, i) + 256 * string.byte(s, i + 1)
    if u >= 32768 then u = u - 65536 end
    n = n + 1
    out[n] = u
  end
  return out, n
end

-- ============================================================================
-- LIN waveform
-- ============================================================================
-- INDEPENDENT reference implementations of the PID and the checksum. Deliberately not
-- calls into sdec.li_*: a test that generates its stimulus with the code under test
-- proves only that the code agrees with itself. These are written straight from the
-- field definitions, and tools/test_serial.lua additionally pins them to the four PIDs
-- that are common knowledge (ID 0x00 -> 0x80, 0x01 -> 0xC1, 0x3C -> 0x3C, 0x3D -> 0x7D).
function LIN_PID(id)
  local function b(k) return math.fmod(math.floor(id / (2 ^ k)), 2) end
  local p0 = math.fmod(b(0) + b(1) + b(2) + b(4), 2)
  local p1 = 1 - math.fmod(b(1) + b(3) + b(4) + b(5), 2)
  return math.fmod(id, 64) + 64 * p0 + 128 * p1
end

-- Inverted sum with the carry added back. pid = nil for the classic checksum (data
-- only), or the PID for the enhanced one.
function LIN_CSUM(data, nd, pid)
  local sum = 0
  if pid ~= nil then sum = pid end
  local i
  for i = 1, nd do
    sum = sum + data[i]
    if sum > 255 then sum = sum - 255 end
  end
  return 255 - sum
end

-- ============================================================================
-- GEN_LIN(opts) -> rd, ts, ncells, nsamples, bytes, nbytes
-- ============================================================================
-- A LIN bus waveform: one or more complete frames, each break / sync / PID / data /
-- checksum.
--
--   frames   list of {id = 0x11, data = {...}, classic = true, csum = 0x5E,
--                     nobreak = true, nodata = true, sync = 0x55}
--            csum overrides the computed checksum (for corruption tests); classic
--            selects the classic checksum; nodata omits the response entirely (a
--            header the schedule reached and nothing answered); sync overrides the
--            sync byte; nobreak omits this frame's break field.
--   nbreak   dominant bits in the break (13, the master minimum)
--   delim    recessive delimiter bits (1)
--   space    inter-byte space, bit times (0 -- LIN allows it, most stacks send none)
--   inter    idle bits between frames (10)
--   lead, tail, baud, fs, lo, hi, noise, rise, phase  as GEN
--
-- lo/hi default to 0 / 6.0 V: a 12 V bus through the 2:1 divider the app asks for, which
-- is what the instrument would actually see.
--
-- Also returns the BYTE SEQUENCE the UART layer should recover, so a test can assert the
-- wire layer separately from the frame layer.
function GEN_LIN(opts)
  local nbreak = opts.nbreak or 13
  local delim  = opts.delim or 1
  local space  = opts.space or 0
  local inter  = opts.inter or 10
  local lead   = opts.lead or 20
  local tail   = opts.tail or 20
  local frames = opts.frames or {}
  local nf     = table.getn(frames)

  local cells, nc = {}, 0
  local bytes, nby = {}, 0
  local i, k, j

  local function put(v, n)
    for k = 1, n do nc = nc + 1; cells[nc] = v end
  end

  -- One 8N1 byte: start bit, eight data bits LSB first, one stop bit.
  local function byte(v)
    nc = nc + 1; cells[nc] = 0
    local t = v
    for k = 1, 8 do
      nc = nc + 1
      cells[nc] = math.fmod(t, 2)
      t = math.floor(t / 2)
    end
    nc = nc + 1; cells[nc] = 1
    if space > 0 then put(1, space) end
    nby = nby + 1
    bytes[nby] = v
  end

  put(1, lead)
  for i = 1, nf do
    local f = frames[i]
    if not f.nobreak then
      -- The break: nbreak dominant bits, then the recessive delimiter. This is the one
      -- field no byte can express, and the reason GEN_RENDER exists separately.
      put(0, nbreak)
      put(1, delim)
      -- The break reads as 0x00 with a failed stop bit at the UART layer, so it IS a
      -- byte in the recovered stream -- which is what sdec.li_break() looks for.
      nby = nby + 1
      bytes[nby] = 0
    end
    byte(f.sync or 0x55)
    local pid = f.pid or LIN_PID(f.id or 0)
    byte(pid)
    if not f.nodata then
      local d, nd = f.data or {}, 0
      nd = table.getn(d)
      for j = 1, nd do byte(d[j]) end
      local cs = f.csum
      if cs == nil then
        local usepid = pid
        if f.classic then usepid = nil end
        cs = LIN_CSUM(d, nd, usepid)
      end
      byte(cs)
    end
    if i < nf then put(1, inter) end
  end
  put(1, tail)

  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  if o.lo == nil then o.lo = 0 end
  if o.hi == nil then o.hi = 6.0 end
  if o.baud == nil then o.baud = 19200 end
  local rd, ts, _, nsmp = GEN_RENDER(cells, nc, o)
  return rd, ts, nc, nsmp, bytes, nby
end

-- ============================================================================
-- Mock instrument
-- ============================================================================
local BUFS = {}
local function newbuf(cap)
  -- fillmode starts at 0 (FILL_ONCE), as the reference says a user-defined buffer does. The app
  -- sets 1 so an overwrite is an overwrite rather than a discard -- see sdec.acq_fillmode.
  local b = {alive = true, capacity = cap, n = 0, readings = {},
             relativetimestamps = {}, fillmode = 0}
  function b.clear()
    b.n = 0
    b.readings, b.relativetimestamps = {}, {}
  end
  BUFS[table.getn(BUFS) + 1] = b
  return b
end
function LIVEBUFS()
  local n = 0
  local i
  for i = 1, table.getn(BUFS) do if BUFS[i].alive then n = n + 1 end end
  return n
end

buffer = {STYLE_STANDARD = 'std', STYLE_WRITABLE_FULL = 'wf', UNIT_VOLT = 'V'}
-- fillmode: a real attribute here, so acq_fillmode() is exercised rather than pcall'd into a no-op.
-- A user-defined buffer starts FILL_ONCE (0), as the reference states; the app sets 1.
function buffer.make(cap, style)
  if cap ~= nil and cap < 10 then error('buffer.make below the 10 minimum', 0) end
  return newbuf(cap)
end
function buffer.delete(b)
  if type(b) ~= 'table' or not b.alive then error('buffer.delete on a dead buffer', 0) end
  b.alive = false
end

-- The waveform the mocked digitizer hands back. Tests set SRC before calling into
-- the app so acquisition and decode can be exercised end to end.
--
-- SRC.native_fs OPTIONALLY MAKES THE MOCK HONOUR THE RATE THE APP ASKED FOR, and without it a
-- whole class of defect is invisible here. By default the samples come back verbatim, so
-- acq_fs is re-derived from SRC.ts and comes out the same whatever dmm.digitize.samplerate was
-- set to -- which means no offline test can see the app CHOOSE a rate, only what it does once
-- chosen. The rate-selection failure that cost a bench session was exactly that shape: a 19200
-- line acquired at 500 kS/s, where a 19200 bit is 26.04 samples and the width fit lands on
-- 8.679, one third of it, so 57600 is reported with nbad 0.
--
-- Set SRC.native_fs to the rate SRC was RENDERED at and the read resamples to the requested rate,
-- nearest neighbour, with timestamps to match. Two honest limits, both of which decide how a
-- vector must be built rather than being hidden:
--   * nearest neighbour is DECIMATION, not an analog front end. Asking for a rate above native
--     repeats samples rather than inventing detail, so render at or above the highest rate under
--     test -- 1 MS/s covers the app's whole ladder.
--   * SRC.loop = true wraps at SRC.nsmp, which is what the generator does with an arb on repeat.
--     Without it a slower rate runs off the end of the render and the capture comes back short.
SRC   = {rd = nil, ts = nil, nsmp = 0, trigat = nil, native_fs = nil, loop = false}
READS = {n = 0, triggered = 0}
TRIG  = {}

dmm = {
  FUNC_DIGITIZE_VOLTAGE = 'digv',
  MODE_EDGE = 'edge', MODE_WINDOW = 'window', MODE_OFF = 'off',
  SLOPE_RISING = 'rise', SLOPE_FALLING = 'fall',
  digitize = {analogtrigger = {edge = {}}},
}

-- Source samples per delivered sample, and the delivered sample interval. 1 and nil mean "hand
-- SRC back as it is", which is every test that has not opted in.
function SRC_step()
  if SRC.native_fs == nil or SRC.native_fs <= 0 then return 1, nil end
  local want = dmm.digitize.samplerate
  if want == nil or want <= 0 then return 1, nil end
  return SRC.native_fs / want, 1 / want
end

-- Source index for delivered sample i counting from `from`, or nil once the render runs out.
function SRC_at(from, i, step)
  local j = from + math.floor((i - 1) * step)
  if SRC.loop and SRC.nsmp ~= nil and SRC.nsmp > 0 then
    j = math.fmod(j - 1, SRC.nsmp) + 1
  end
  return j
end

function dmm.digitize.read(b)
  local count = dmm.digitize.count or 1000
  local step, dt = SRC_step()
  b.clear()
  local i
  for i = 1, count do
    local j = SRC_at(1, i, step)
    if SRC.rd[j] == nil then break end
    b.n = i
    b.readings[i] = SRC.rd[j]
    if dt == nil then
      b.relativetimestamps[i] = SRC.ts[j]
    else
      -- THE REQUESTED RATE, not the source's. This is the number acq_measure_fs() divides by, so
      -- it is what makes the app's rate choice observable at all.
      b.relativetimestamps[i] = (i - 1) * dt
    end
  end
  READS.n = READS.n + 1
  return b.readings[1]
end

trigger = {
  EVENT_ANALOGTRIGGER = 'atrig', CLEAR_ENTER = 'enter', CLEAR_NEVER = 'never',
  -- The rear EXT TRIG IN BNC and the front-panel TRIGGER key. Both are real
  -- constants in the DMM6500 reference; the mock carries them so the trigger-source
  -- branch in acq_triggered() is exercised rather than merely written.
  EVENT_EXTERNAL = 'ext', EVENT_DISPLAY = 'frontkey',
  -- A trigger TIMER event, which is what fires while the interpreter is busy: measured firing
  -- 2.019 s into a 6 s busy loop, where a *TRG sent at the same moment did not arrive at all.
  -- tools/bench_panel.py wires it as an extra cancel stimulus to test a cancel without a finger.
  EVENT_TIMER1 = 'timer1', EVENT_NONE = 'none',
  -- Blender 1 OR's several stimuli into one event; the reference's own example is two
  -- DIGIO events, which is this shape with different sources.
  EVENT_BLENDER1 = 'blend1',
  LOGIC_POSITIVE = 'pos', LOGIC_NEGATIVE = 'neg',
  -- Trigger-model states. Only IDLE and RUNNING are distinguished here, which is all
  -- sdec.trig_done() and sdec.trig_settle() ask about.
  STATE_IDLE = 'idle', STATE_RUNNING = 'running', STATE_ABORTED = 'aborted',
  model = {},
}
TRIG.state = 'idle'
-- The real call returns three values (state, status, block); only the first is read.
function trigger.model.state() return TRIG.state, 'ok', 0 end
-- THE REAR EXT TRIG OUT LINE, for credit-based flow control. Deliberately hostile in one specific
-- way: asserts are COUNTED and time-stamped against the arm order, because the whole correctness
-- argument for the feature is that the pulse leaves AFTER the trigger model is armed. A mock that
-- only recorded "assert was called" would pass a version with the ordering inverted -- which loses
-- the head of every frame on real hardware and looks like a decoder bug.
TRIG.asserts = 0
TRIG.armed_at_assert = {}
trigger.extout = {}
function trigger.extout.assert()
  TRIG.asserts = TRIG.asserts + 1
  -- TRIG.inits is incremented by trigger.model.initiate(); recording it here is what lets a test
  -- assert "the model was armed before the pulse went out".
  TRIG.armed_at_assert[TRIG.asserts] = TRIG.inits or 0
end
-- Two templates, and the argument lists differ -- which is the point of validating them here
-- rather than accepting anything: 'SimpleLoop' takes (count, delay, buf) while
-- 'LoopUntilEvent' takes (event, position, clear, delay, buf), so a call that passed the wrong
-- shape would be caught on the instrument and not before.
function trigger.model.load(template, a, b, c, d, e)
  if template == 'SimpleLoop' then
    local count, buf = a, c
    if count == nil or count < 1 then error('SimpleLoop needs a count', 0) end
    if buf == nil or not buf.alive then error('trigger model on a dead buffer', 0) end
    TRIG.template, TRIG.count, TRIG.buf = 'SimpleLoop', count, buf
    TRIG.ev, TRIG.position, TRIG.clear = nil, nil, nil
    TRIG.loaded = true
    return
  end
  if template ~= 'LoopUntilEvent' then
    error('unexpected template ' .. tostring(template), 0)
  end
  local ev, position, clear, buf = a, b, c, e
  if position == nil or position < 0 or position > 100 then
    error('position must be a percentage', 0)
  end
  if buf == nil or not buf.alive then error('trigger model on a dead buffer', 0) end
  TRIG.template = 'LoopUntilEvent'
  TRIG.ev, TRIG.position, TRIG.buf, TRIG.clear = ev, position, buf, clear
  TRIG.loaded = true
end

TRIG.aborts = 0
-- Trigger blenders, so the OR path in acq_triggered() is exercised rather than merely
-- written. Records what was wired so a test can assert the stimuli, not just the event.
trigger.blender = {}
-- THE LATCH IS MODELLED, not just the wiring, because the cancel key depends on its exact
-- semantics: the real detector holds an event until read and then AUTO-RESETS ("after detecting a
-- trigger with this function, the event detector automatically resets and rearms... regardless of
-- the number of events detected", ref 14-334). A mock that returned a sticky boolean would pass a
-- cancel that fires for ever after one press, and one that returned false always would pass a
-- cancel that never fires at all.
--
-- TRIG.latch[N] counts unread events, so TRIG.press(N) is the offline stand-in for a finger on the
-- TRIGGER key -- see sdec.cancel_pressed(). Counting rather than flagging is what lets a test assert
-- that TWO presses are not one press seen twice, and that one press is not seen twice either.
TRIG.latch = {}
TRIG.waits = 0
function TRIG.press(n)
  n = n or 2
  TRIG.latch[n] = (TRIG.latch[n] or 0) + 1
end
local bi
for bi = 1, 2 do
  trigger.blender[bi] = {stimulus = {}, orenable = false}
  trigger.blender[bi].reset = function()
    trigger.blender[bi].stimulus = {}
    trigger.blender[bi].orenable = false
    TRIG.latch[bi] = 0
  end
  trigger.blender[bi].clear = function() TRIG.latch[bi] = 0 end
  trigger.blender[bi].wait = function(t)
    -- A ZERO TIMEOUT IS A BUG AT THE CALL SITE, not something to be tolerant of: it is how
    -- display.waitevent() wedges this instrument, so the mock refuses it rather than letting an
    -- accidental wait(0) pass the offline suite and hang the hardware.
    if t == nil or t <= 0 then error('blender wait needs a nonzero timeout', 0) end
    TRIG.waits = TRIG.waits + 1
    local n = TRIG.latch[bi] or 0
    if n < 1 then return false end
    TRIG.latch[bi] = 0                  -- one read clears every pending event, as documented
    return true
  end
end

function trigger.model.abort() TRIG.aborts = TRIG.aborts + 1 end

function trigger.model.initiate()
  if not TRIG.loaded then error('initiate without a loaded model', 0) end
  -- Counted so a flow-control test can prove the credit pulse left AFTER the arm. See
  -- trigger.extout.assert().
  TRIG.inits = (TRIG.inits or 0) + 1
  -- SimpleLoop fills the buffer from the start of the source, no pre-trigger split. It
  -- completes IMMEDIATELY here, which is the honest mock: the real instrument fills over
  -- seconds to minutes and the poll loop watches it, but nothing offline can model that
  -- passage of time, so the loop sees a full buffer on its first look. What that DOES
  -- exercise -- the geometry, the end reason, the progress calls, the decode -- is
  -- everything except the waiting itself.
  if TRIG.template == 'SimpleLoop' then
    local b = TRIG.buf
    local dt = SRC.ts[2] - SRC.ts[1]
    b.clear()
    local i
    for i = 1, TRIG.count do
      local v = SRC.rd[i]
      if v == nil then break end
      b.n = i
      b.readings[i] = v
      b.relativetimestamps[i] = (i - 1) * dt
    end
    READS.triggered = READS.triggered + 1
    return
  end
  -- Emulate the pre-trigger split: `position` percent of the capture is kept from
  -- before the trigger edge, the rest from after. SRC.trigat is the sample index
  -- of the edge the analog comparator would have fired on.
  --
  -- A COMPLETED CAPTURE IS SHORTER THAN `count`, and the mock reproduces that.
  -- Measured on hardware: count = 20000 with position = 5 completes at 19011
  -- samples, twice, differing only in the last two digits. The rule is
  --     post = count - floor(count x position/100)      -- always made
  --     pre  = min(samples available before the trigger, that same budget)
  -- and on a continuously transmitting line pre is a dozen, not the 1000 the 5 %
  -- budget allows -- because the pre-trigger phase ENDS when the trigger fires, and
  -- on a busy line that is immediately.
  --
  -- Filling to `count` here is why the app shipped a wait loop that could never be
  -- satisfied: offline, buf.n reached n on the first look, so `buf.n >= n` passed
  -- every test and timed out on every real capture. The mock has to be able to
  -- disappoint the code, or it only tests the code's own assumptions.
  local b = TRIG.buf
  local count = dmm.digitize.count or 1000
  local budget = math.floor(count * TRIG.position / 100)
  local post = count - budget
  local avail = (SRC.trigat or 1) - 1
  local pre = avail
  if pre > budget then pre = budget end
  local start = (SRC.trigat or 1) - pre
  if start < 1 then start = 1 end
  local total = pre + post
  -- SRC.native_fs makes the armed path honour the requested rate too, on the same terms as
  -- dmm.digitize.read(). Both or neither: an app that chose the rate on the free-run probe and
  -- captured on the armed path would otherwise be tested at two different rates in one capture.
  local step, dt = SRC_step()
  if dt == nil then dt = SRC.ts[2] - SRC.ts[1] end
  b.clear()
  local i
  for i = 1, total do
    local j = SRC_at(start, i, step)
    if SRC.rd[j] == nil then break end
    b.n = i
    b.readings[i] = SRC.rd[j]
    b.relativetimestamps[i] = (i - 1) * dt
  end
  READS.triggered = READS.triggered + 1
end

function waitcomplete() end
function delay(_) end

-- ---------- load the REAL modules ----------
for _, m in ipairs({'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
                    'tsp/chunk_decode.tsp',
                    'tsp/midi_decode.tsp', 'tsp/lin_decode.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then
    print('LOAD FAILED ' .. m .. ': ' .. tostring(err))
    os.exit(1)
  end
  chunk()
end

-- ============================================================================
-- Waveform corruption helpers (host-only; these mangle a GEN() result in place)
-- ============================================================================
-- Impulse noise. Spikes are the specific reason a min/max threshold fails: a
-- single one moves the decision level arbitrarily far, and a handful defeats a
-- group-mean threshold too unless the extremes are trimmed first.
function GEN_SPIKES(rd, n, count, amp, width)
  width = width or 2
  local i, j
  for i = 1, count do
    local p = 2 + math.floor(rnd() * (n - width - 2))
    local sign = 1
    if rnd() < 0.5 then sign = -1 end
    for j = 0, width - 1 do
      rd[p + j] = (rd[p + j] or 0) + sign * amp
    end
  end
  return rd
end

-- Overshoot and damped ringing after every transition -- a probe on an
-- unterminated line, or any fast edge into a reactive load. This is the case
-- hysteresis exists for: ringing that recrosses the threshold makes phantom
-- edges, and a phantom edge is a phantom bit.
function GEN_RING(rd, n, frac, period, decay)
  period = period or 4
  decay  = decay or 3
  local out = {}
  local i, j
  for i = 1, n do out[i] = rd[i] end
  for i = 2, n do
    local d = rd[i] - rd[i-1]
    if d > 0.3 or d < -0.3 then
      for j = 0, math.floor(period * 4) do
        local k = i + j
        if k > n then break end
        out[k] = out[k] + d * frac * math.exp(-j / decay)
                          * math.sin(2 * math.pi * j / period)
      end
    end
  end
  for i = 1, n do rd[i] = out[i] end
  return rd
end

-- Slow baseline wander: ground bounce, thermal drift, a common-mode offset the
-- probe return does not share. Dangerous because the threshold is decided ONCE
-- for the whole capture, so drift eats the hysteresis budget.
function GEN_DRIFT(rd, n, amp, cycles)
  cycles = cycles or 1.5
  local i
  for i = 1, n do
    rd[i] = rd[i] + amp * math.sin(2 * math.pi * cycles * (i - 1) / n)
  end
  return rd
end

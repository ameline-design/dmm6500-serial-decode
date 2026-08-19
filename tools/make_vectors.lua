-- make_vectors.lua -- build the bench stimulus set as SDG arb files, with the
-- offline answer recorded beside each one.
--
-- Run from the repo root:  lua tools/make_vectors.lua [outdir]
-- Default outdir is out/vectors/. Copy the whole directory to the SDG's USB key.
--
-- WHY THIS EXISTS, and why it is more than a file converter:
--
-- Every offline result in this project came from tools/gen_serial.lua. Replaying
-- those same arrays through real analog hardware makes the hardware result
-- comparable to the offline one BYTE FOR BYTE rather than merely plausible, so
-- any divergence is a fact about the instrument -- which is the entire point of
-- the bench session.
--
-- So this script does not just encode. For each vector it:
--   1. builds the volt array exactly as the offline suite does,
--   2. writes the .bin,
--   3. reads it back with GEN_READ -- an independent decoder of the format,
--   4. converts those codewords back to volts and runs the REAL decoder on them,
--   5. compares that against the decode of the original unquantised array.
--
-- Step 5 is the one that earns its keep. It answers "does 16-bit quantisation at
-- this full scale damage the decode?" offline, before Sunday, instead of finding
-- out at the bench where a quantisation loss would be indistinguishable from a
-- front-end problem. Any row whose two decodes disagree is a vector that must
-- not be trusted as a bench oracle.
--
-- The manifest carries the offline answer per file: expected bytes, baud, format
-- and note text. At the bench the DMM's panel is then compared against a written
-- number, not against a memory.

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local OUT = (arg and arg[1]) or 'out/vectors'
os.execute('mkdir -p ' .. OUT)
-- Clear stale .bin files first. Renaming or splitting a vector otherwise leaves an
-- orphan behind that is absent from the manifest but still sitting on the USB key,
-- where its name makes it look like a plan row. That is a real trap at a bench:
-- the file loads, plays something, and matches nothing it is compared against.
os.execute('rm -f ' .. OUT .. '/*.bin')

-- ---------------------------------------------------------------------------
-- Run the real decoder over a volt array and flatten the answer to strings.
-- ---------------------------------------------------------------------------
local function clearforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.proto = 'uart'
  sdec.ui_mode = 'text'
end

local function decode(rd, n, fs, proto)
  clearforce()
  if proto == 'lin' then
    sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
    sdec.force_invert = false
    sdec.proto, sdec.ui_mode = 'lin', 'lin'
  end
  sdec.acq_fs, sdec.fs = fs, fs
  local out = {bytes = {}, nb = 0, baud = nil, fmt = nil, note = nil,
               nbad = 0, refused = false, err = nil}
  local pok, perr = pcall(function()
    if not sdec.sig_levels(rd, n) then
      sdec.res, sdec.baud = nil, nil
      out.refused = true
      return
    end
    sdec.sig_edges(rd, n)
    sdec.sig_idle(rd, n)
    sdec.decode_from(rd, n)
    local r = sdec.res
    if r == nil or r.nf == 0 then out.refused = true; return end
    local i
    for i = 1, r.nf do out.bytes[i] = r.vals[i] end
    out.nb, out.nbad, out.baud = r.nf, r.nbad, sdec.baud
    if proto == 'lin' and sdec.li_parse ~= nil then sdec.li_parse() end
    if sdec.fmt_text ~= nil then out.fmt = sdec.fmt_text() end
    out.note = sdec.ui_note_text()
  end)
  if not pok then out.err = tostring(perr) end
  return out
end

-- Byte arrays equal? nil-tolerant, since a missing byte is a legitimate result.
local function sameb(a, na, b, nb)
  if na ~= nb then return false end
  local i
  for i = 1, na do if a[i] ~= b[i] then return false end end
  return true
end

-- Wrap to a fixed width under a hanging indent. The README is read at a bench,
-- where a 300-character line is a line nobody reads.
local function wrap(pre, s, width)
  width = width or 74
  local out, nl = {}, 0
  local line = pre
  local first = true
  local w
  for w in string.gmatch(s, '%S+') do
    if not first and string.len(line) + 1 + string.len(w) > width then
      nl = nl + 1; out[nl] = line
      line = string.rep(' ', string.len(pre)) .. w
    else
      if first then line = line .. w; first = false
      else line = line .. ' ' .. w end
    end
  end
  nl = nl + 1; out[nl] = line
  return table.concat(out, '\n') .. '\n'
end

local function bhex(t, n, cap)
  local h, i = {}, nil
  local m = n
  if cap ~= nil and m > cap then m = cap end
  for i = 1, m do
    if t[i] == nil then h[i] = '--' else h[i] = string.format('%02X', t[i]) end
  end
  local s = table.concat(h, ' ')
  if m < n then s = s .. string.format(' ...(%d more)', n - m) end
  return s
end

-- ---------------------------------------------------------------------------
-- The vector set. Numbering follows notes/BRINGUP.md's phase tables, so a file
-- name maps to a plan row with no ambiguity at the bench: v41.bin is row 4.1.
--
-- fsv is per vector and appears in the manifest, because the file carries only
-- shape -- the volts come from the AMP setting. One fsv for as many rows as
-- possible keeps the generator untouched between them; the spike rows need a
-- wider scale and say so.
-- ---------------------------------------------------------------------------
local HELLO = 'Hello, World!'
local V = {}
local function vec(t) V[table.getn(V) + 1] = t end

-- ---------------------------------------------------------------------------
-- Lorem ipsum, because tradition. Wrapped into CRLF-terminated lines because
-- that is what real serial traffic looks like: line-oriented, and the CR/LF
-- pair exercises the text view's handling of non-printables at a known cadence
-- rather than leaving them to chance.
-- ---------------------------------------------------------------------------
local LOREM =
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod ' ..
  'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim ' ..
  'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea ' ..
  'commodo consequat. Duis aute irure dolor in reprehenderit in voluptate ' ..
  'velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint ' ..
  'occaecat cupidatat non proident, sunt in culpa qui officia deserunt ' ..
  'mollit anim id est laborum. '

-- Exactly nwant bytes of wrapped lorem. Truncated hard at the end rather than
-- rounded to a line, so the byte count in the manifest is the byte count on the
-- wire -- an off-by-a-few there would be indistinguishable from lost bytes.
local function lorem_text(nwant, cols)
  local out, no = {}, 0
  local col, i = 0, 0
  local total = 0
  while total < nwant do
    i = i + 1
    local ch = string.sub(LOREM, math.mod(i - 1, string.len(LOREM)) + 1,
                          math.mod(i - 1, string.len(LOREM)) + 1)
    no = no + 1; out[no] = ch; total = total + 1
    col = col + 1
    if col >= cols and ch == ' ' and total + 2 <= nwant then
      no = no + 1; out[no] = '\r'
      no = no + 1; out[no] = '\n'
      total = total + 2
      col = 0
    end
  end
  return string.sub(table.concat(out), 1, nwant)
end

-- gap = 0: back-to-back bytes, which is what a device dumping a buffer actually
-- sends and the hardest case for sig_idle, since the only idle-level evidence is
-- one stop bit per frame. lead/tail 10 leaves a 20-bit idle at the loop seam, so
-- each pass of the arb still offers one clean resync point.
-- loop = true renders an EXACT whole number of bit times, so a TrueArb repeat joins seamlessly.
-- Without it the last cell is partial and the frame straddling the junction is corrupt -- measured
-- as one interior bad frame in nearly every hardware capture of v71, which looks like a decoder
-- fault and is a stimulus one. See GEN_RENDER.
local function lorem_vec(baud, fs, nbytes)
  local s = lorem_text(nbytes or 1024, 64)
  local by, nb = GEN_BYTES(s)
  return {bytes = by, baud = baud, fs = fs, gap = 0, lead = 10, tail = 10, loop = true},
         by, nb, nil, s
end

-- EVERY VISIBLE 7-BIT GLYPH, 0x21..0x7E, in one 133-byte payload. The pangram twice, cased, which
-- is the trick of it -- 52 of the 94 come free from two copies -- then the digits and every
-- remaining symbol in code-point order so a gap is visible on inspection.
--
-- Worth a vector of its own because a byte the decoder never sees is a bit pattern that was never
-- framed. The lorem vectors are English prose: they never send '~' (0x7E, six consecutive ones
-- inside one frame), '!' (0x21), '\' or '{|}'. Those attack the stop-bit search and the run-length
-- logic differently from letters, and no shipped vector contained them.
--
-- tools/test_serial.lua asserts the same 94-glyph coverage offline against the same string, so the
-- offline and hardware halves are testing one payload rather than two similar ones.
local ASCII94 = 'the quick brown fox jumps over the lazy dog. ' ..
                'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG. ' ..
                '0123456789 !"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~'

-- SIZED FOR A LAN UPLOAD. 133 bytes at ~10.4 samples/bit is about 14 kpts / 28 kB, comfortably
-- under SDG_UPLOAD_SAFE_BYTES (tools/instruments.py) -- unlike the 1 kB lorem vectors, whose 213 kB
-- has to reach the generator on a USB key. gap/lead/tail and loop match lorem_vec for the same
-- reasons stated there; loop = true especially, since without it the frame across the arb's repeat
-- seam is corrupt and reads as a decoder fault rather than a stimulus one.
local function ascii94_vec(baud, fs, nbits, par)
  local by, nb = GEN_BYTES(ASCII94)
  return {bytes = by, baud = baud, fs = fs, nbits = nbits, par = par,
          gap = 0, lead = 10, tail = 10, loop = true}, by, nb, nil, ASCII94
end

local function hello(o)
  local by, nb = GEN_BYTES(HELLO)
  local opts = {bytes = by, baud = o.baud, fs = o.fs, nbits = o.nbits,
                par = o.par, nstop = o.nstop, invert = o.invert,
                lo = o.lo, hi = o.hi, noise = o.noise}
  return opts, by, nb
end

vec{id = 'v41', desc = "'Hello, World!' 9600 8N1", fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000} end}
vec{id = 'v42', desc = 'same at 115200', fs = 1000000, fsv = 5.0,
    build = function() return hello{baud = 115200, fs = 1000000} end}
vec{id = 'v43', desc = 'same at 250000 (the maxbaud wall)', fs = 1000000, fsv = 5.0,
    build = function() return hello{baud = 250000, fs = 1000000} end}
-- The four parity formats, as DEFENSIVE coverage rather than expected traffic.
-- Reported field experience: real serial data is almost always 8N1; 7E1, 7O1,
-- 8E1 and 8O1 are all things that *might* turn up but have not actually been
-- seen; more than one stop bit has never been seen; and 7 data bits without
-- parity has not been seen either. So these are here because the decoder claims
-- to detect them, not because a bus is waiting to send them.
--
-- v44a is the one that earns its place regardless of prevalence. 8N1 (v41) and
-- 7E1 are the SAME FRAME LENGTH and differ only in whether bit 7 is data or
-- parity, so they are mutually confusable, and the pair tests that ambiguity
-- from BOTH sides: v41 must not be called 7E1, and v44a must not be called 8N1.
-- ua_refine_parity decides it by checking whether bit 7 tracked parity across
-- every frame. 8E1/8O1 are 11-bit frames and far less confusable, so they are
-- cheap confirmation rather than a real test -- 4 KB each.
vec{id = 'v44a', desc = '9600 7E1', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, nbits = 7, par = 1} end}
vec{id = 'v44b', desc = '9600 7O1', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, nbits = 7, par = 2} end}
vec{id = 'v44c', desc = '9600 8E1', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, nbits = 8, par = 1} end}
vec{id = 'v44d', desc = '9600 8O1', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, nbits = 8, par = 2} end}
-- Two stop bits, which the decoder deliberately does NOT search for: a second stop
-- bit is a bit time of idle, and idle between frames is already tolerated. So the
-- expected result is a byte-exact decode REPORTED AS 8N1, and this vector is what
-- turns that claim from a comment into a measurement.
vec{id = 'v44e', desc = '9600 8N2 (two stop bits)', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, nstop = 2} end}
vec{id = 'v45', desc = '9600 8N1 inverted (RS-232 sense)', fs = 100000, fsv = 5.0,
    build = function() return hello{baud = 9600, fs = 100000, invert = true} end}
vec{id = 'v46', desc = '200-byte payload, 9600 (paging)', fs = 100000, fsv = 5.0,
    build = function()
      local by, nb = {}, 0
      local i
      for i = 1, 200 do nb = nb + 1; by[nb] = 32 + math.fmod(i * 7, 95) end
      return {bytes = by, baud = 9600, fs = 100000}, by, nb
    end}
vec{id = 'v47', desc = 'v41 + impulse spikes at the amplitude ceiling',
    fs = 100000, fsv = 10.0,
    note = 'spikes are +/-3.0 V, NOT the +/-25 V of the offline case. The SDG ' ..
           'ceiling is +/-10 V, and GEN_SPIKES ADDS, so two spikes on one ' ..
           'sample stack: 3.3 + 2*3.0 = 9.3 V is the real worst case and it ' ..
           'has to fit. A larger figure clips at the generator, and a clipped ' ..
           'stimulus decodes wrongly while looking exactly like a decoder bug.',
    build = function()
      local o, by, nb = hello{baud = 9600, fs = 100000}
      return o, by, nb, function(rd, n) GEN_RESEED(4711); return GEN_SPIKES(rd, n, 12, 3.0, 2) end
    end}
-- Drift is TWO vectors because it makes two different claims, and one vector can
-- only test one of them. A sweep offline puts the knee at 0.7 V on a 3.3 V swing:
-- every byte survives to 0.6 V, bytes start being lost at 0.7 V, and the
-- "baseline unstable" warning appears at exactly the amplitude where loss
-- begins -- so the decoder never drops a byte silently. Both halves of that are
-- worth checking against real analog drift, and a single 1 V vector would have
-- checked only the second.
vec{id = 'v48a', desc = 'v41 + 0.6 V drift (inside tolerance)', fs = 100000, fsv = 5.0,
    build = function()
      local o, by, nb = hello{baud = 9600, fs = 100000}
      return o, by, nb, function(rd, n) return GEN_DRIFT(rd, n, 0.6, 1.5) end
    end}
vec{id = 'v48b', desc = 'v41 + 1.0 V drift (beyond tolerance)', fs = 100000, fsv = 5.0,
    note = 'bytes are EXPECTED to be lost here. The pass is that the panel ' ..
           'warns and does not claim a clean decode -- not that the bytes ' ..
           'survive. They do not survive offline either.',
    build = function()
      local o, by, nb = hello{baud = 9600, fs = 100000}
      return o, by, nb, function(rd, n) return GEN_DRIFT(rd, n, 1.0, 1.5) end
    end}
vec{id = 'v51', desc = 'MIDI: Note On / Note Off at 31250', fs = 500000, fsv = 5.0,
    build = function()
      local by = {0x90, 0x3C, 0x64, 0x80, 0x3C, 0x40, 0x90, 0x40, 0x7F,
                  0x43, 0x70, 0x45, 0x60}   -- running status on the tail
      return {bytes = by, baud = 31250, fs = 500000}, by, table.getn(by)
    end}

-- ---------------------------------------------------------------------------
-- Long streams: 1 kB of lorem ipsum at the four most common rates.
--
-- THE DMM CANNOT CAPTURE 1 kB, AND THAT IS THE POINT. sdec.n = 20000 samples at
-- the app's fixed sdec.fs = 1 MSa/s is 20 ms of signal whatever the baud rate, so
-- a capture holds baud/500 bytes: 19 at 9600, 38 at 19200, 115 at 57600, 230 at
-- 115200. The hard ceiling is 500 bytes at ANY rate, because 20000 samples over
-- (4 samples/bit x 10 bits) is 500 and the baud cancels -- and 4 samples/bit is
-- sdec.minsabit, the declared floor.
--
-- So these vectors test what a REAL line looks like rather than what fits:
--
--   * The capture lands mid-stream, with no lead-in idle and no tail. Short
--     vectors give the decoder 20 bit times of clean idle at each end, which a
--     real line does not.
--   * gap = 0, so bytes are back-to-back. The only idle-level evidence is one
--     stop bit per frame, which is the least sig_idle ever has to work with.
--   * Every byte returned must appear as a CONTIGUOUS SUBSTRING of the known
--     payload. That is a far stronger check than "13 of 13 matched" -- it catches
--     a decoder that drops or duplicates a byte mid-stream, which a short vector
--     cannot expose.
--   * The scope at 14 Mpts can decode the WHOLE kilobyte while the DMM sees a
--     slice, so the oracle covers what the DUT cannot.
--
-- The payload is written beside each vector as <id>.txt for exactly that
-- substring check.
--
-- ONE THING TO SET AT THE BENCH: a vector's fs here is the ARB PLAYBACK rate,
-- while the DMM samples independently at its own sdec.fs. Left at the default
-- 1 MSa/s the DMM oversamples these 10x more than the offline decode did, so the
-- two are not decoding under the same conditions. `sdec.fs = <the row's
-- srate_sa_s>` over port 5025 before capturing makes them comparable.
local LONG_N = 1024
vec{id = 'v71', desc = 'lorem ipsum 1 kB, 9600 8N1', fs = 100000, fsv = 5.0,
    long = true, build = function() return lorem_vec(9600, 100000, LONG_N) end}
vec{id = 'v72', desc = 'lorem ipsum 1 kB, 19200 8N1', fs = 200000, fsv = 5.0,
    long = true, build = function() return lorem_vec(19200, 200000, LONG_N) end}
vec{id = 'v73', desc = 'lorem ipsum 1 kB, 57600 8N1', fs = 600000, fsv = 5.0,
    long = true, build = function() return lorem_vec(57600, 600000, LONG_N) end}
vec{id = 'v74', desc = 'lorem ipsum 1 kB, 115200 8N1', fs = 1000000, fsv = 5.0,
    long = true, build = function() return lorem_vec(115200, 1000000, LONG_N) end}

-- ============================================================================
-- THE HARD VECTORS: patterns chosen to attack the decoder rather than resemble traffic
-- ============================================================================
-- Lorem is REAL text, and that is its weakness as well as its strength: real text has a comfortable
-- mix of edges and never sits on a pathological case for long. These four do nothing else.
--
--   0x00 x128   the longest possible LOW run. One start bit, eight zero data bits and a stop is
--               nine bit times low, so the only edge per frame is the stop bit's rise. This is the
--               case that starves the bit-time fit of short pulses.
--   0xFF x128   the longest possible HIGH run: the frame is a single start-bit-wide low pulse in an
--               otherwise idle line, so the rate detector gets ONE narrow pulse per frame and
--               nothing else. The manual warns firmware authors off 0xFF padding for this reason;
--               this vector is that warning, measured.
--   0x55 x128   alternating bits, so an edge EVERY bit time -- the maximum edge density a UART can
--               produce, and the worst case for edge-list allocation and for slew-limited wiring.
--   0xAA x128   the same density in the opposite phase. Not redundant with 0x55: the start bit is
--               low and the LSB is 0 in 0x55 but 1 in 0xAA, so the two differ in whether the start
--               bit merges with the first data bit -- which is exactly where a start-of-frame
--               detector goes wrong.
--
-- ALL FOUR IN ONE VECTOR, in blocks, rather than four vectors: the block BOUNDARIES are themselves
-- the interesting part -- 0xFF followed by 0x00 is the largest possible step in edge density, and a
-- decoder that adapts its timing per window has to survive the transition. It also keeps the upload
-- count down, and uploads are the generator's wedge hazard.
-- THE PAYLOAD AS A STRING, because that is what gets written beside the vector as <id>.txt and a
-- windowed capture can only be judged as a substring of it. Built in chunks: Lua 5.0.2 concatenation
-- is O(n) per append, so byte-at-a-time over 512 bytes is a quadratic that shows up in the build.
local function bytes_to_string(by, nb)
  local parts, np, i = {}, 0, 0
  local chunk = {}
  for i = 1, nb do
    chunk[math.mod(i - 1, 64) + 1] = string.char(by[i])
    if math.mod(i, 64) == 0 or i == nb then
      np = np + 1
      parts[np] = table.concat(chunk, '', 1, math.mod(i - 1, 64) + 1)
      chunk = {}
    end
  end
  return table.concat(parts, '', 1, np)
end

local function hard_blocks(n)
  local by, nb = {}, 0
  local pats, i, k = {0x00, 0xFF, 0x55, 0xAA}, 0, 0
  for i = 1, 4 do
    for k = 1, n do nb = nb + 1; by[nb] = pats[i] end
  end
  return by, nb
end

-- n uniform bytes 0..255 from the suite's own PRNG, reseeded per call so the payload is a
-- function of (seed, n) alone and reproducible from the manifest rather than stored anywhere.
--
-- ONE HELPER FOR EVERY LENGTH, and that is what makes v91 the exact 256-byte PREFIX of v93.
-- Two copies of this loop would have made the prefix relationship a coincidence that a later
-- edit could quietly break; as one function it is structural. It matters at the bench: a
-- capture that matches v91's first bytes and not v93's would then be evidence about the
-- generator, whereas with two generators it would only be evidence about this script.
local function rand_bytes(n, seed)
  GEN_RESEED(seed)
  local by, nb, i = {}, 0, 0
  for i = 1, n do
    nb = nb + 1
    -- rnd() is [0,1); floor(x * 256) is uniform over 0..255 and never 256.
    by[nb] = math.floor(GEN_RAND() * 256)
    if by[nb] > 255 then by[nb] = 255 end
  end
  return by, nb
end

-- 64 EACH, NOT 128, AND THE REASON IS THE UPLOAD CEILING rather than the test: a byte is ~104
-- codewords at 10.42 samples/bit, so 512 bytes is 107 kB against the 64 kB a LAN upload may safely
-- carry (tools/instruments.py, SDG_UPLOAD_SAFE_BYTES -- larger uploads wedge the generator's LAN
-- service). 256 bytes is 53 kB and still longer than the ~240-byte capture window, so a capture is
-- a unique substring rather than a repeat. The 128-byte version is worth building for a USB-key
-- transfer, which is how v71's 213 kB got onto the generator.
vec{id = 'v90', desc = '64 each of 0x00, 0xFF, 0x55, 0xAA -- 9600 8N1', fs = 100000, fsv = 5.0,
    long = true,
    build = function()
      local by, nb = hard_blocks(64)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

-- 1 kB OF KNOWN RANDOM BYTES, 0-255, from the suite's own deterministic PRNG so the expected bytes
-- are reproducible from the seed rather than stored. This is the vector that catches what patterns
-- cannot: any decode that depends on a byte's VALUE -- a parity refinement that only holds for text,
-- a format search biased by ASCII's clear top bit, an off-by-one that only shows on 0x80 -- fails
-- here and nowhere else. Every byte value appears about four times.
-- 256 BYTES over the LAN, for the ceiling reason above. The intent survives the shortening: what a
-- random payload buys is that a capture is a UNIQUE substring and that every decode path meets byte
-- values it cannot have been tuned for, and 256 > the ~240-byte window keeps both. A 1024-byte
-- version is the USB-key vector to build next.
vec{id = 'v91', desc = '256 uniform random bytes 0-255, 9600 8N1', fs = 100000, fsv = 5.0,
    long = true,
    build = function()
      local by, nb = rand_bytes(256, 20260818)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

-- A WALKING ONE and its complement, which is the classic memory-test pattern applied to framing:
-- 0x01, 0x02, 0x04 ... 0x80 then 0xFE, 0xFD ... 0x7F. Each byte puts a single 1 (then a single 0) in
-- a different bit position, so a decoder that samples one bit at the wrong phase gets exactly one
-- byte wrong and the position of that byte says WHICH bit it mis-sampled. A count of bad bytes could
-- not tell you that.
vec{id = 'v92', desc = 'walking-one and walking-zero bytes, 9600 8N1', fs = 100000, fsv = 5.0,
    long = true,
    build = function()
      local by, nb, r, b = {}, 0, 0, 0
      for r = 1, 8 do
        local v = 1
        for b = 2, r do v = v * 2 end
        nb = nb + 1; by[nb] = v
      end
      for r = 1, 8 do
        local v = 1
        for b = 2, r do v = v * 2 end
        nb = nb + 1; by[nb] = 255 - v
      end
      -- Repeated to fill a capture, so a window landing anywhere sees the whole sequence.
      -- Repeated to fill a capture window and no further: 15 reps of 16 bytes is 240 bytes plus the
      -- original 16, which clears the window without clearing the upload ceiling.
      local rep, i = nb, 0
      for i = 1, 14 * rep do nb = nb + 1; by[nb] = by[math.mod(i - 1, rep) + 1] end
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

-- ============================================================================
-- THE FULL-LENGTH HARD VECTORS -- USB KEY ONLY, NOT LAN
-- ============================================================================
-- v90 and v91 are the SHORTENED forms of these two, and the shortening was forced by the
-- transport rather than by the test: a byte is ~104 codewords at 100 kSa/s and 9600 baud, so
-- 512 bytes is 107 kB and 1024 bytes is 213 kB, against the 65536 bytes of
-- SDG_UPLOAD_SAFE_BYTES (tools/instruments.py) below which a C1:WVDT upload has never wedged
-- the generator's LAN service. Recovery from that wedge is a power cycle on an instrument with
-- no smart plug, so it costs a human -- which is why the ceiling is treated as hard.
--
-- The USB key has no such ceiling. C1:ARWV NAME,"U-disk0/<file>" plays straight off the key
-- (guide section 3.9.1), no upload and no bulk transfer at all, which is exactly how v71's
-- 213 kB reached the generator. So these two are built to the size the OWNER ASKED FOR and
-- carried by hand: see out/vectors/USB-TRANSFER.md.
--
-- WHAT THE EXTRA LENGTH BUYS, given the short forms already exist:
--
--   v93  1024 random bytes is FOUR TIMES the capture window, so no single capture can see the
--        whole payload and successive captures land on different bytes. With 256 bytes a
--        192-byte window overlaps itself heavily between runs, so a value-dependent fault has
--        few chances to show; at 1024 it has four independent looks. Every byte value appears
--        about sixteen times rather than about four, which is the difference between "0x80 was
--        decoded correctly" as an anecdote and as a statement.
--        THE FIRST 256 BYTES ARE v91's, BY CONSTRUCTION (same seed, same helper). That makes
--        the pair a clean control: same bytes, same rate, different transport and length, so a
--        disagreement between v91 and the head of v93 is about the transport and nothing else.
--
--   v94  128 each is the count the owner asked for, and it changes one thing that 64 cannot
--        test: each block is 128 bytes long, which is LONGER than the ~104-byte hex page and
--        comparable to the 192-byte capture window, so a capture can land ENTIRELY INSIDE one
--        pathological block. At 64 each (v90) every 192-byte window straddles at least two
--        blocks, so the decoder always has a mix of edge densities to fit its timing to. Here
--        it can be handed 128 consecutive 0xFF -- one narrow start-bit pulse per frame and
--        nothing else -- with no relief anywhere in the window. That is the case the manual
--        warns firmware authors about, and it is unreachable at 64.
vec{id = 'v93', desc = '1024 uniform random bytes 0-255, 9600 8N1 (USB key)',
    fs = 100000, fsv = 5.0, long = true,
    build = function()
      local by, nb = rand_bytes(1024, 20260818)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

vec{id = 'v94', desc = '128 each of 0x00, 0xFF, 0x55, 0xAA -- 9600 8N1 (USB key)',
    fs = 100000, fsv = 5.0, long = true,
    build = function()
      local by, nb = hard_blocks(128)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

-- A PAYLOAD THE EXACT SIZE OF A RECORDING, which is the one thing a looping vector cannot be.
--
-- The app's recording modes capture exactly 8192 and 32768 bytes. Against a 1 kB loop a 32 kB recording
-- sees the same 1024 bytes THIRTY-TWO times, so a byte that is systematically wrong repeats in every
-- copy and reads as the payload rather than as damage -- and a substring check passes on a capture that
-- silently dropped a whole period. A non-repeating payload of the capture's own length makes every
-- position unique: a wrong byte cannot be explained by the loop, and a missing run cannot be hidden by
-- the next copy of itself.
--
-- SAME SEED, SAME HELPER, so these are PREFIX-COMPATIBLE with the shorter random vectors: v91's 256
-- bytes are the head of v93's 1024, which are the head of v95's 8192, which are the head of v96's
-- 32768. That is structural rather than incidental (see rand_bytes) and it is what makes a disagreement
-- between two of them evidence about the TRANSPORT and not about the payload.
--
-- USB KEY ONLY, and by a wide margin: 1.63 MB and 6.51 MB against a 65536-byte LAN ceiling. Measured
-- 2026-08-19, a THIRD consecutive large upload wedged the generator's LAN service at 213 kB, so these
-- are not close calls. Both fit SDG_MAX_PTS (8388608): 853542 and 3413542 points.
vec{id = 'v95', desc = '8192 uniform random bytes 0-255, 9600 8N1 (USB key, one 8 kB recording)',
    fs = 100000, fsv = 5.0, long = true,
    build = function()
      local by, nb = rand_bytes(8192, 20260818)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

vec{id = 'v96', desc = '32768 uniform random bytes 0-255, 9600 8N1 (USB key, one 32 kB recording)',
    fs = 100000, fsv = 5.0, long = true,
    build = function()
      local by, nb = rand_bytes(32768, 20260818)
      return {bytes = by, baud = 9600, fs = 100000, gap = 0, lead = 10, tail = 10,
              loop = true}, by, nb, nil, bytes_to_string(by, nb)
    end}

-- 1200 baud, and it is the ONLY vector that exercises PAGING.
--
-- Page size is cols x ui_nrow: TEXT is 80 x 15 = 1200 bytes, HEX is 16 x 15 = 240.
-- The capture ceiling is 500 bytes (sdec.n / (minsabit x 10)), so TEXT can never
-- page at all -- one page always holds everything -- and HEX pages at most three
-- times.
--
-- Every other vector misses that boundary, by coincidence and narrowly: v46 decodes
-- 200 bytes and v71 yields 192 at a locked 9600, against a 208-byte hex page. Eight
-- and sixteen bytes short. So until this vector, the paging code had never been
-- driven by a bench stimulus in any view.
--
-- 1200 baud with the rate locked gives fs = 10 kSa/s, 8.33 samples/bit and a 240-byte
-- window -- over the boundary, so Next/Prev, the position bar and the "bytes N-M of
-- T" counter all become reachable. 1200 baud is also entirely plausible for the
-- bit-banged-debug use case, since a slow line is the easy one to bit-bang.
-- THE SWEEP VECTOR. 300 bytes rather than 1024 keeps the upload under the 64 kB that has never
-- wedged the generator, while still being long enough that a 240-byte capture is a SUBSTRING rather
-- than a repeat -- which is the whole point of using lorem instead of 'Hello, World!'. Loop-exact,
-- so replaying it at any SRATE gives a clean join.
vec{id = 'v76', desc = 'lorem 300 B, 9600 8N1 (loop-exact sweep vector)', fs = 100000, fsv = 5.0,
    build = function() return lorem_vec(9600, 100000, 300) end}
vec{id = 'v75', desc = 'lorem ipsum 1 kB, 1200 8N1 (paging)', fs = 10000, fsv = 5.0,
    long = true, build = function() return lorem_vec(1200, 10000, LONG_N) end}

-- THE FULL-GLYPH VECTORS. NOT YET UPLOADED TO THE GENERATOR -- built here so the files and the
-- manifest rows exist, and uploaded on the next deliberate `bench_matrix.py --upload`. Deferred on
-- purpose: an upload mid-soak risks wedging the generator's LAN service, and recovery is a power
-- cycle on an instrument with no smart plug, so it costs a human.
--
-- 7E1 as well as 8N1, because that is where full-glyph coverage earns the most: the parity bit is
-- then computed over all 94 bit patterns rather than over the 40-odd that English prose produces.
-- Every byte is <= 0x7E, so a seven-bit frame carries the whole payload with nothing truncated --
-- which is what makes the 8N1 and 7E1 rows directly comparable.
vec{id = 'v77', desc = 'all 94 visible glyphs, 9600 8N1', fs = 100000, fsv = 5.0,
    build = function() return ascii94_vec(9600, 100000) end}
vec{id = 'v78', desc = 'all 94 visible glyphs, 9600 7E1', fs = 100000, fsv = 5.0,
    build = function() return ascii94_vec(9600, 100000, 7, 1) end}

-- ---------------------------------------------------------------------------
-- A DOZEN RANDOM VECTORS, for cycling through a long soak
-- ---------------------------------------------------------------------------
-- A soak that replays one payload for eight hours measures repeatability, not coverage: every lap
-- decodes the same bit patterns at the same phases. Twelve distinct random payloads turn the same
-- wall-clock into twelve times the pattern space, and because they are RANDOM they contain runs,
-- alternations and near-misses nobody thought to write down.
--
-- SIZED 250 BYTES SO EVERY ONE IS A SAFE LAN UPLOAD. At 10.42 samples/bit a 250-byte payload at
-- 10 bit times per frame is ~26.3 kpts = ~52.6 kB, comfortably inside SDG_UPLOAD_SAFE_BYTES
-- (65536, tools/instruments.py) with room to spare -- 300 bytes would be 63 kB, which is inside
-- the limit but leaves no margin, and this generator has wedged on uploads before. 250 is also
-- still LONGER than the ~240-byte capture window, which is the property that makes a capture a
-- unique substring rather than a repeat.
--
-- SIX 8N1 AND SIX 7E1, and the split is the point rather than symmetry. The 8-bit ones exercise
-- byte values the 7-bit ones cannot reach at all -- everything with bit 7 set -- while the 7-bit
-- ones are the only ones that exercise the PARITY path over uniformly distributed data, which is
-- exactly where the 7E1/8N1 ambiguity lives (see ua_refine_parity). A random 7-bit payload is the
-- strongest possible input to the bit-7-diversity guard: roughly half its frames set the parity
-- bit, so a decoder that cannot tell 7E1 from 8N1 has nowhere to hide.
--
-- SHUFFLED PERMUTATIONS, NOT UNIFORM RANDOM BYTES, and that is a deliberate correction. Drawing
-- 250 bytes uniformly gives an expected 5.9 occurrences of each value across six vectors, but
-- coverage is then a lottery: with Poisson mean 5.9 the chance a given value never appears is
-- 0.27 %, so about one value in the whole set would be MISSING, and which one would change with
-- the seed. "Random" and "covers every byte" are different requirements and only one of them can
-- be left to chance.
--
-- So each 8-bit vector is a shuffle of 0..255 -- every value EXACTLY ONCE per vector, six times
-- across the group, guaranteed rather than probable. Each 7-bit vector is a shuffle of two copies
-- of 0..127, so every 7-bit value appears exactly twice per vector and twelve times across the
-- group. The ORDER is still random, which is what makes the bit patterns, run lengths and
-- inter-symbol transitions unpredictable -- that was always the useful part, not the value
-- histogram.
--
-- 256 bytes rather than 250: it is what a full permutation costs, it is still LONGER than the
-- ~240-byte capture window so a capture stays a unique substring rather than a repeat, and at
-- ~10.42 samples/bit it lands near 54 kB -- inside SDG_UPLOAD_SAFE_BYTES (65536) with real margin.
--
-- Fisher-Yates on the suite's own PRNG, reseeded per vector, so each payload is a function of its
-- seed alone and regenerates from its manifest row with nothing stored.
-- The byte table as a STRING, which is what makes <id>.txt get written beside the vector -- and
-- without it the substring check at the bench has nothing to compare against. Built in chunks
-- because string.char(unpack(t)) overflows the argument stack well before 256 values.
local function bytes_to_str(by, nb)
  local out, no, i = {}, 0, nil
  local chunk, nc = {}, 0
  for i = 1, nb do
    nc = nc + 1; chunk[nc] = string.char(by[i])
    if nc >= 64 then no = no + 1; out[no] = table.concat(chunk); chunk, nc = {}, 0 end
  end
  if nc > 0 then no = no + 1; out[no] = table.concat(chunk) end
  return table.concat(out)
end

local function shuffled(hi, reps, seed)
  GEN_RESEED(seed)
  local by, nb, v, r, i = {}, 0, nil, nil, nil
  for r = 1, reps do
    for v = 0, hi do nb = nb + 1; by[nb] = v end
  end
  for i = nb, 2, -1 do
    local j = math.floor(GEN_RAND() * i) + 1
    if j > i then j = i end
    by[i], by[j] = by[j], by[i]
  end
  return by, nb
end

local RSEED0 = 7100
local rk
for rk = 0, 11 do
  local seed = RSEED0 + rk
  local sevenbit = (rk >= 6)
  local id = string.format('r%02d', rk)
  local d = 'shuffled 256 B, 9600 '
  if sevenbit then d = d .. '7E1 (0-127 x2)' else d = d .. '8N1 (0-255 x1)' end
  vec{id = id, desc = d .. string.format(' seed %d', seed), fs = 100000, fsv = 5.0,
      long = true,
      build = function()
        local by, nb
        if sevenbit then by, nb = shuffled(127, 2, seed) else by, nb = shuffled(255, 1, seed) end
        local opts = {bytes = by, baud = 9600, fs = 100000, gap = 0,
                      lead = 10, tail = 10, loop = true}
        if sevenbit then opts.nbits = 7; opts.par = 1 end
        return opts, by, nb, nil, bytes_to_str(by, nb)
      end}
end

-- ---------------------------------------------------------------------------
-- THE STANDARD-RATE SWEEP, 300 to 38400
-- ---------------------------------------------------------------------------
-- The manifest had 1200, 9600, 19200, 31250, 57600, 115200 and 250000 -- chosen one at a time to
-- answer particular questions, which left the ordinary RS-232 ladder full of holes. These fill
-- it, so "does the app work at every standard rate an operator would actually meet?" is a run
-- rather than an argument.
--
-- SIZED TO STAY UNDER THE SDG WEDGE THRESHOLD. Repeated 170-210 kB C1:WVDT uploads hang the
-- generator's remote interface, and recovery is a power cycle on an instrument with no smart plug
-- -- it costs a human, so an unattended sweep must not risk it. Every vector here is 13 bytes at
-- 10 samples/bit: 1300 points, 2.6 kB, forty times under SDG_UPLOAD_SAFE_BYTES. Note that fs
-- here is the SDG's rendering rate, not the DMM's -- the DMM picks its own from the baud rate.
--
-- 300 baud is the interesting end. The DMM's digitize floor is 1000 S/s, which at 300 baud is
-- 3.3 samples/bit and far too coarse -- but the floor is a MINIMUM, not a ceiling, so the app
-- asks for 8 x 300 = 2400 S/s and gets it. What the low end really costs is WINDOW TIME: at 8.33
-- samples/bit a 20 000-sample capture is 240 bytes at every rate, but at 300 baud those 240
-- bytes take 8 seconds of wall clock to arrive.
vec{id = 'v80', desc = 'hello 300 8N1 (slowest standard rate)', fs = 3000, fsv = 5.0,
    build = function() return hello{baud = 300, fs = 3000} end}
vec{id = 'v81', desc = 'hello 600 8N1', fs = 6000, fsv = 5.0,
    build = function() return hello{baud = 600, fs = 6000} end}
vec{id = 'v82', desc = 'hello 2400 8N1', fs = 24000, fsv = 5.0,
    build = function() return hello{baud = 2400, fs = 24000} end}
vec{id = 'v83', desc = 'hello 4800 8N1 (the streaming ceiling)', fs = 48000, fsv = 5.0,
    build = function() return hello{baud = 4800, fs = 48000} end}
vec{id = 'v84', desc = 'hello 38400 8N1 (past the 19.2k continuous limit)', fs = 384000,
    fsv = 5.0, build = function() return hello{baud = 38400, fs = 384000} end}

-- LIN: 0..6 V, a 12 V bus through the 2:1 divider the app asks for, which is
-- what the instrument would actually see. fsv 7.5 covers it with headroom.
vec{id = 'v61', desc = 'LIN 19200: two frames, enhanced checksum',
    fs = 500000, fsv = 7.5, proto = 'lin',
    build = function()
      return {baud = 19200, fs = 500000, lo = 0, hi = 6.0,
              frames = {{id = 0x11, data = {0x01, 0x02, 0x03, 0x04}},
                        {id = 0x22, data = {0xAA, 0xBB}}}}, nil, 0
    end, lin = true}
vec{id = 'v62', desc = 'LIN 19200: diagnostic 0x3C/0x3D, classic checksum',
    fs = 500000, fsv = 7.5, proto = 'lin',
    build = function()
      return {baud = 19200, fs = 500000, lo = 0, hi = 6.0,
              frames = {{id = 0x3C, data = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}},
                        {id = 0x3D, data = {0x7F, 0x00}}}}, nil, 0
    end, lin = true}
vec{id = 'v63', desc = 'LIN 9600: header with no response, then a good frame',
    fs = 500000, fsv = 7.5, proto = 'lin',
    build = function()
      return {baud = 9600, fs = 500000, lo = 0, hi = 6.0,
              frames = {{id = 0x15, nodata = true},
                        {id = 0x15, data = {0xDE, 0xAD}}}}, nil, 0
    end, lin = true}

-- ---------------------------------------------------------------------------
-- Build, export, read back, decode both ways, compare.
-- ---------------------------------------------------------------------------
local rows, nrows = {}, 0
local nsuspect = 0
print(string.format('%-5s %-44s %7s %8s %5s %5s %s', 'file', 'what', 'points',
                    'bytes', 'fsv', 'use', 'quantisation check'))
print(string.rep('-', 108))

local vi
for vi = 1, table.getn(V) do
  local v = V[vi]
  GEN_RESEED(12345)
  local opts, want, nwant, post, payload = v.build()
  local rd, ts, nc, nsmp, lbytes, lnby
  if v.lin then
    rd, ts, nc, nsmp, lbytes, lnby = GEN_LIN(opts)
    want, nwant = lbytes, lnby
  else
    rd, ts, nc, nsmp = GEN(opts)
  end
  if post ~= nil then rd = post(rd, nsmp) end

  local path = OUT .. '/' .. v.id .. '.bin'
  local nbytes, info = GEN_WRITE(path, rd, nsmp, {fsv = v.fsv, ofst = 0})

  -- The payload beside the vector, for the substring check a windowed capture
  -- needs: the DMM sees a slice, so "is what came back a contiguous run of this?"
  -- is the only question that can be asked of it.
  if payload ~= nil then
    local pf = io.open(OUT .. '/' .. v.id .. '.txt', 'wb')
    pf:write(payload)
    pf:close()
  end

  -- Decode the ORIGINAL array, then the array recovered FROM THE FILE. If those
  -- two disagree the export changed the signal, and the vector is not usable as
  -- a bench oracle no matter how good it looks.
  local a = decode(rd, nsmp, v.fs, v.proto)
  local back, nback = GEN_READ(path)
  local qrd = {}
  local i
  for i = 1, nback do qrd[i] = GEN_VOLTS(back[i], v.fsv, 0) end
  local b = decode(qrd, nback, v.fs, v.proto)

  local qnote
  if nback ~= nsmp then
    qnote = string.format('POINT COUNT %d vs %d', nback, nsmp)
  elseif a.err ~= nil or b.err ~= nil then
    qnote = 'RAISED: ' .. tostring(a.err or b.err)
  elseif a.refused ~= b.refused then
    qnote = 'REFUSAL DIFFERS'
  elseif not sameb(a.bytes, a.nb, b.bytes, b.nb) then
    qnote = string.format('BYTES DIFFER %d vs %d', a.nb, b.nb)
  elseif a.baud ~= b.baud then
    qnote = string.format('BAUD DIFFERS %s vs %s', tostring(a.baud), tostring(b.baud))
  else
    qnote = 'identical'
  end
  if qnote ~= 'identical' then nsuspect = nsuspect + 1 end

  -- Peak as a fraction of full scale. Low utilisation is not an error -- v47
  -- needs headroom for transients that a given seed may not realise -- but a
  -- silently over-wide scale throws away SNR, so it is shown rather than
  -- assumed. The quantisation check above is what proves it does not matter.
  local util = info.peak_code / 32767 * 100

  print(string.format('%-5s %-44s %7d %8d %5.1f %4.0f%% %s', v.id, v.desc, nsmp,
                      nbytes, v.fsv, util, qnote))

  nrows = nrows + 1
  rows[nrows] = {id = v.id, desc = v.desc, npts = nsmp, nbytes = nbytes,
                 fsv = v.fsv, amp = info.amp_vpp, fs = v.fs,
                 minv = info.min_v, maxv = info.max_v, cksum = info.cksum,
                 proto = v.proto or 'uart', baud = b.baud, fmt = b.fmt, nb = b.nb,
                 nbad = b.nbad, want = want, nwant = nwant,
                 got = b.bytes, refused = b.refused, note = v.note,
                 dnote = b.note, quant = qnote, long = v.long,
                 -- Bytes the DMM can hold from this stream, at its own sample
                 -- rate rather than the arb's: sdec.n samples / (sabit * 10).
                 win_dflt = math.floor(20000 / (1000000 / (opts.baud or 9600)) / 10),
                 win_match = math.floor(20000 / (v.fs / (opts.baud or 9600)) / 10)}
end

-- ---------------------------------------------------------------------------
-- The manifest. Two files: a TSV a script can read and a text file a human can
-- read at the bench, generated from the same rows so they cannot disagree.
-- ---------------------------------------------------------------------------
local f = io.open(OUT .. '/manifest.tsv', 'w')
f:write('file\tproto\tbaud\texp_fmt\tsrate_sa_s\tnpts\tnbytes\tamp_vpp\tofst_v\t' ..
        'min_v\tmax_v\tcksum\texp_nbytes\texp_hex\n')
local ri
for ri = 1, nrows do
  local r = rows[ri]
  f:write(string.format('%s.bin\t%s\t%s\t%s\t%d\t%d\t%d\t%.1f\t0\t%.3f\t%.3f\t' ..
                        '%d\t%d\t%s\n',
                        r.id, r.proto, tostring(r.baud), tostring(r.fmt), r.fs,
                        r.npts, r.nbytes, r.amp, r.minv, r.maxv, r.cksum, r.nb,
                        bhex(r.got, r.nb)))
end
f:close()

f = io.open(OUT .. '/README.txt', 'w')
f:write('SDG2122X arbitrary-waveform stimulus set for the DMM6500 serial decoder\n')
f:write('Generated by tools/make_vectors.lua from tools/gen_serial.lua.\n\n')
f:write('FORMAT: raw little-endian 16-bit two\'s complement codewords, no header.\n')
f:write('  Confirmed against SDG Programming Guide PG02-E05B section 4.1 and the\n')
f:write('  worked example in 5.1.3. Codeword +32767 is +AMP/2, -32768 is -AMP/2.\n\n')
f:write('PER FILE, BEFORE PLAYING IT -- the file carries shape only, the volts\n')
f:write('come from the generator setting, so these three commands are not\n')
f:write('optional:\n')
f:write('  C1:SRATE MODE,TARB              TrueArb, NOT DDS. DDS holds the DAC\n')
f:write('                                  clock fixed and steps a phase\n')
f:write('                                  accumulator, so it RESAMPLES -- which\n')
f:write('                                  is actively wrong for sub-sample edge\n')
f:write('                                  timing, the thing being measured.\n')
f:write('  C1:SRATE VALUE,<srate_sa_s>     from the manifest. TrueArb range is\n')
f:write('                                  1 uSa/s to 75 MSa/s; every row here is\n')
f:write('                                  inside it. In TrueArb the rate is set\n')
f:write('                                  directly, so no f = fs/N arithmetic.\n')
f:write('  C1:BSWV AMP,<amp_vpp>           and OFST,0. WRONG AMP MEANS WRONG\n')
f:write('                                  LOGIC LEVELS and every threshold\n')
f:write('                                  result is then meaningless.\n')
f:write('  C1:ARWV NAME,"U-disk0/<file>"   USB paths load directly; there is no\n')
f:write('                                  need to copy into internal flash.\n')
f:write('  C1:OUTP ON,LOAD,HZ              high-Z suits the DMM 10 Mohm input.\n\n')
f:write('cksum is Fletcher-32 over the file bytes, so a truncated copy to the\n')
f:write('USB key is detectable -- it would otherwise play as a short waveform\n')
f:write('with nothing on screen to say so.\n\n')
f:write('v71, v72 and v73 are DELIBERATELY THE SAME FILE -- identical checksums\n')
f:write('are correct, not a mistake. They share a samples-per-bit ratio, so only\n')
f:write('the SRATE differs, which makes them a clean test of one thing: the same\n')
f:write('shape played at 100k, 200k and 600k Sa/s must be detected as 9600, 19200\n')
f:write('and 57600 baud with an identical payload. Baud detection is thereby shown\n')
f:write('to follow the playback rate rather than anything in the file.\n\n')
f:write('exp_* columns are what the OFFLINE decoder returns for the quantised\n')
f:write('file. The panel should match them exactly. It is the comparison that\n')
f:write('makes a hardware disagreement a fact rather than an impression.\n\n')
for ri = 1, nrows do
  local r = rows[ri]
  f:write(string.rep('-', 74) .. '\n')
  f:write(string.format('%s.bin  %s\n', r.id, r.desc))
  f:write(string.format('  set:      SRATE VALUE,%d   BSWV AMP,%.1f OFST,0\n',
                        r.fs, r.amp))
  f:write(string.format('  file:     %d points, %d bytes, cksum %d\n',
                        r.npts, r.nbytes, r.cksum))
  f:write(string.format('  signal:   %.3f to %.3f V, %s\n', r.minv, r.maxv, r.proto))
  if r.refused then
    f:write('  expect:   the decoder REFUSES. A confident answer is the failure.\n')
  else
    f:write(string.format('  expect:   %d bytes at %s baud %s, %d framing error(s)\n',
                          r.nb, tostring(r.baud), tostring(r.fmt), r.nbad))
    f:write('            ' .. bhex(r.got, r.nb, 24) .. '\n')
    if r.long then
      f:write(wrap('  WINDOW:   ', string.format(
        'this stream is LONGER than one capture. The DMM holds %d bytes of it ' ..
        'at the default sdec.fs = 1 MSa/s, or %d bytes with sdec.fs set to %d ' ..
        'to match this vector -- do that, or the DMM oversamples 10x more than ' ..
        'the offline decode did and the two are not comparable. The pass is ' ..
        'that every byte returned is a CONTIGUOUS SUBSTRING of %s.txt, not that ' ..
        'the count matches.', r.win_dflt, r.win_match, r.fs, r.id)))
    end
    if r.nwant ~= nil and r.nwant > 0 and not sameb(r.want, r.nwant, r.got, r.nb) then
      f:write(string.format('            transmitted %d: %s\n', r.nwant,
                            bhex(r.want, r.nwant, 24)))
    end
  end
  if r.dnote ~= nil and r.dnote ~= '' then
    f:write(wrap('  note:     ', r.dnote))
  end
  if r.note ~= nil then f:write(wrap('  CAVEAT:   ', r.note)) end
  if r.quant ~= 'identical' then
    f:write(wrap('  SUSPECT:  ', 'export changed the decode -- ' .. r.quant ..
                 '. Do not use as an oracle.'))
  end
end
f:close()

print(string.rep('-', 108))
print(string.format('%d vectors written to %s/  (manifest.tsv, README.txt)',
                    nrows, OUT))
if nsuspect > 0 then
  print(string.format('%d vector(s) SUSPECT: the export changed the decode.', nsuspect))
  os.exit(1)
end
print('all vectors decode identically before and after the 16-bit export')

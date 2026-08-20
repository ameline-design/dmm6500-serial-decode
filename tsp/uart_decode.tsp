-- uart_decode.tsp -- asynchronous serial (UART) framing for the DMM6500 serial
-- decoder (TSP / Lua 5.0.2).
--
-- Works from what serial_core.tsp produced: threshold, edge list, bit time. It
-- never scans the samples linearly -- it samples ~14 computed positions per frame,
-- so decode cost scales with the number of BYTES, not the capture length. That is
-- what makes the brute-force format search affordable.
--
-- Brute force is the right answer because a UART line carries no clock and no
-- framing metadata: data width, parity and stop bits are not derivable in closed
-- form. They are, however, strongly constrained -- a wrong guess puts the stop-bit
-- sampling point on a data bit, which reads as space about half the time and
-- raises a framing error. So decoding under every plausible format and keeping the
-- fewest-error result recovers the format from the data. By default that is 2 widths x 3
-- parities x 2 polarities = 12 decodes, each ~14 samples per byte; "Auto (any width)" makes
-- it 5 widths and 30, and the reason that is not the default is set out below.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.PAR_NONE = 0
sdec.PAR_EVEN = 1
sdec.PAR_ODD  = 2

-- Search order matters: it is also the tie-break order, so the most common
-- format on a bench wins when two formats explain the capture equally well.
--
-- ESSENTIALLY EVERY REAL STREAM IS 7 OR 8 DATA BITS, so by DEFAULT only those two are
-- searched. 5, 6 and 9 are excluded outright unless the operator asks for them, which is
-- the "Data Bits: Auto (7/8)" versus "Auto (any width)" choice on the options form.
--
-- The reason is NOISE TOLERANCE, measured rather than assumed: the hostile sweep run both ways
-- changes 5 of its 105 UART cases, and every one changes the same way. (Its LIN cases cannot
-- change, since LIN pins the width at 8.)
--
--   case                          7/8 only            any width
--   60 spikes 5 V 8 wide          8N1, 2 err          9N1, 1 err   <- bytes all +256
--   1 V drift over 2 cycles       8N1, 3 err          9N1, 0 err
--   1 V drift over 12 cycles      8O1, 5 err          9N1, 1 err
--   noise+spikes+ringing+drift    8N1, 15 err         9N1, 9 err
--   genuine 9N1 stream            8N1, 5 err          9N1, 0 err   <- the one real gain
--
-- Two mechanisms, and the second is the dangerous one:
--
--   1. The search keeps the highest-scoring candidate, so every extra format is another
--      draw at winning by luck -- a multiple-comparisons problem. Two widths x 3 parities
--      x 2 polarities is 12 candidates; five widths is 30. On a clean capture the truth
--      wins by a mile and the count is irrelevant; on a damaged one the scores bunch up.
--   2. A WIDER FRAME LAUNDERS THE EVIDENCE OF DAMAGE. 9N1 has an extra data cell and its
--      stop bit lands one place later, so it absorbs whatever broke the 8N1 stop check
--      into a data bit instead of failing on it. That is why the error count FALLS as the
--      answer gets worse -- 15 errors to 9, 3 to 0, 5 to 1 -- and every byte is 256 too
--      large. The wrong answer looks cleaner than the right one.
--
-- 6 data bits does the same thing one cell down: 6 bits plus a stop plus two idle bits is
-- exactly a 10-cell 8N1 frame, so on any capture with a 2-bit gap both score 12 and the
-- loser's bytes are silently wrong.
--
-- With "any width" selected, 5 and 6 are searched but heavily biased against
-- (sdec.rarewidth). Independently of the setting, sdec.ua_refine_width still walks DOWN from a
-- common width on positive evidence, so a rare width is reached when the capture proves it rather
-- than when a score happens to favour it.
--
-- 9 IS NOT SEARCHED AT ALL, in either setting, and is reachable only by FORCING Data Bits = 9.
--
-- Biasing against it is not enough, and the reason is structural. ua_margin's proportional term is
-- 0.6 * sc and applies only when sc > 0; on a damaged line the honest reading's own score is driven
-- to zero or below by its correct error count -- 12 frames with 3 bad scores 9 - 3*3 = 0 -- so the
-- term is 0, multiplying it by rarewidth leaves 0, and the margin collapses to its floor of 2. A
-- 9N1 rival scoring 12 clears that trivially. THE BIAS IS INERT EXACTLY WHEN THE INCUMBENT IS
-- DAMAGED, which is exactly when a laundering width can win. Measured on an 8N1 line with a 2-bit
-- gap and stop-bit damage on interior frames, with "any width" selected:
--
--   12 bytes, 3 stop bits corrupted  ->  9N1, nbad = 0,  9 of 12 bytes wrong, every one +256
--   20 bytes, 6 stop bits corrupted  ->  9N1, nbad = 0, 14 of 20 bytes wrong, every one +256
--
-- ERR reads 0 -- the one number an operator uses to decide whether to trust the dump -- and those
-- bytes reach the USB byte log and the saved report. ua_refine_width cannot walk it back either:
-- its collapse requires the top bit set in EVERY error-free frame, and since 9N1 reports no errors
-- the damaged frames are all examined and the first with bit 9 = 0 breaks the loop. The same damage
-- that lets 9N1 win is what disables the defence against it.
--
-- So 9 is treated the way nstop already is: not observable from the wire when the damage pattern is
-- not uniform, therefore not guessed, but still honoured when GIVEN. The cost is the one case a
-- search of 9 genuinely won -- a real 9-bit stream, which reads 8N1 with 5 errors -- and the remedy
-- for that operator is one Options field.
sdec.try_nbits     = {8, 7}              -- the default: the two widths that actually occur
sdec.try_nbits_all = {8, 7, 6, 5}        -- with "Auto (any width)"; 9 is forced-only, see above
sdec.try_par       = {0, 1, 2}

-- Operator state, so an explicit nil test rather than `or` -- `or false` would be fine but
-- reads as a bug next to the booleans that genuinely need the test.
if sdec.widths_any == nil then sdec.widths_any = false end

-- The width list in force. Everything that searches widths goes through here.
function sdec.ua_widths()
  if sdec.force_nbits ~= nil then return {sdec.force_nbits} end
  if sdec.widths_any then return sdec.try_nbits_all end
  return sdec.try_nbits
end

-- A FORCED FIELD CONSTRAINS THE SEARCH; it does not merely sit in a variable.
--
-- The forced-format shortcut in decode_from() runs only when the WIDTH is forced, so any of the
-- other three set on its own was read by nothing and had no effect at all -- Options > Parity,
-- Stop Bits and Polarity were live fields that changed the decode only in combination with a
-- fourth. These make each one independently effective by narrowing the candidate list the search
-- walks, which keeps every scoring and margin rule below unchanged: a one-entry list simply has
-- nothing to lose to.
function sdec.ua_parities()
  if sdec.force_par ~= nil then return {sdec.force_par} end
  return sdec.try_par
end

function sdec.ua_stops()
  if sdec.force_nstop ~= nil then return {sdec.force_nstop} end
  return sdec.try_stop
end

-- Only ONE stop bit is searched, and that is a conclusion rather than a
-- simplification: the stop-bit count is NOT OBSERVABLE from the wire. A second
-- stop bit is indistinguishable from a bit time of idle, which the decoder already
-- tolerates, so nstop = 2 can never rescue a capture nstop = 1 fails on -- it can
-- only tie and muddy the report. The UI states this rather than hiding it;
-- sdec.ua_frame() still honours nstop so it can be forced.
--
-- 1.5 STOP BITS IS DIFFERENT, and it is the one case where the argument above does
--
--   5N1.5 at 9600, auto      -> reports 19200 -- exactly DOUBLE -- 8 frames, 4 bad
--   5N1.5 at 9600, baud 9600 -> all six bytes exact, 0 framing errors
--
-- So the FRAME layer handles it perfectly and sig_bittime does not, because a
-- 1.5-bit stop makes some pulse widths odd multiples of HALF a bit; the greatest
-- common bit period then collapses to half the true one. That is exactly the "errs
-- SHORT" failure described below, except structural to the format rather than caused
-- by a glitch, so no amount of noise tolerance helps.
--
-- Left unfixed deliberately. Widening sig_bittime to resist a structural half-bit
-- feature would put every common format at risk to rescue a doubly-rare one -- 1.5
-- stop bits belongs to Baudot, so it needs 5 data bits too, which are already
-- outside the default search. The remedy already exists and works: type the rate
-- into the Baud Rate field. And the failure is FLAGGED rather than silent (4 of 8
-- frames bad), which is the property that matters.
--
-- Why the format exists at all, since it looks like whimsy: Baudot teleprinters used
-- a 7.5-unit character (1 start + 5 data + 1.5 stop), and at a 22 ms bit that makes
-- 45.45 Bd come out at the standard 60 words per minute. The mechanism needed
-- settling time that was not an integer number of bit periods, so the character was
-- defined as 7.5 units and the gearing landed on a round typing rate.
sdec.try_stop  = {1}

-- Candidate bit-time rescalings for sdec.ua_best(). Ordered by distance from 1,
-- so the pulse-width fit is trusted unless a rescaling decodes measurably
-- better, and near-ties resolve toward it.
--
-- The set is ASYMMETRIC ON PURPOSE -- integers to 10, reciprocals only to 1/6 --
-- because the two error directions are not equally likely. sig_bittime fits the
-- greatest common bit period of the observed pulses, so it errs SHORT: one narrow
-- glitch is enough to pull the fit to a sub-multiple, hence integer ratios well
-- above 1. Erring LONG by a factor k needs every pulse in the whole capture to be
-- an exact multiple of k bit times, and inside a 10-bit frame that stops being
-- constructible past k = 6 (k = 6 already means no run shorter than six bits).
sdec.ratios      = {1, 0.5, 2, 0.3333333333, 3, 0.25, 4, 0.2, 5, 0.1666666667, 6, 8, 10}
sdec.probe_nbits = {8, 7, 5}

-- HOW FAR A FORCED RATE MAY DISAGREE WITH THE WIRE BEFORE THE PANEL SAYS SO.
--
-- 4 %, just inside the measured 5.26 % cliff (0.5/9.5 for 8N1 -- half a cell accumulated over the
-- 9.5 bit times from the start edge to the stop sample). Deliberately advisory: it warns at the
-- point where the NEXT percent could start corrupting bytes silently, rather than waiting for
-- corruption that by construction leaves no other trace.
sdec.ratemargin = sdec.ratemargin or 0.04

-- How close to the best pulse-width consistency a candidate bit time must come to stay
-- in the running. Relative, not absolute, so it needs no tuning against a noise level.
--
-- This is the second, INDEPENDENT piece of evidence, and it is what breaks the one
-- ambiguity framing alone cannot. On a badly corrupted 9600 baud capture, 7N1 at 7200
-- baud frames 54 of 54 bytes with zero errors while the truth frames 40 with 15 errors:
-- a 9-cell frame at 13.87 samples spans 124.8 samples and a 10-cell frame plus a 2-bit
-- gap at 10.417 spans 125, so the alias re-samples every frame at the wrong offsets and
-- still lands its stop bit in the gap every time. No frame-error score can prefer the
-- truth. Pulse-width consistency is decisive though -- 0.855 against 0.497 -- because
-- the real widths are multiples of the real bit time and of nothing else.
sdec.qgate = 0.8

-- Fewest good frames before format alternatives are worth reporting. The search
-- margin has an absolute floor (see ua_margin), so on a handful of frames almost
-- every format lands inside it -- a clean 5-byte ASCII capture listed
-- "also fits: 9N1 6N1", which is true of that capture and useless as a report.
sdec.alt_minframes = sdec.alt_minframes or 8

-- sdec.res           -- the chosen decode result (declared, not assigned: see
-- sdec.fmt_note      -- serial_core.tsp on why a reload must not clobber state)
-- sdec.baud_note     -- an equally-valid reading at a different baud rate
sdec.fitratio = sdec.fitratio or 1    -- the rescaling ua_best() settled on

-- Manual overrides. Any of these, when set, replaces the corresponding
-- auto-detected value -- the point of an auto-detector is to be a good default,
-- not to argue with someone reading a datasheet.
-- Declared, not assigned -- a relaunch must not silently discard settings the
-- operator entered on the options form.
-- sdec.force_baud
-- sdec.force_nbits
-- sdec.force_par
-- sdec.force_nstop
-- sdec.force_invert

-- ============================================================================
-- Bit sampling
-- ============================================================================
-- Sample the logical bit level at fractional sample position x.
--
-- With enough samples per bit, three taps across the middle of the cell are
-- majority-voted rather than one sampled. A single sample is one ADC conversion,
-- so a noise excursion at that instant flips the bit; three taps spanning 40 % of
-- the cell need two wrong together. Skipped below 6 samples/bit, where the outer
-- taps would sit too close to the cell edges.
--
-- Returns 0, 1, or nil when the position falls outside the capture.
function sdec.ua_bit(rd, n, x, invert, T)
  local thr = sdec.thr
  local floor = math.floor

  -- The centre tap defines the bit, and its absence defines a truncated frame.
  -- Test it first and unconditionally: if outer taps could stand in, a frame
  -- running off the end would decode from whatever samples remain and fabricate a
  -- trailing byte instead of reporting truncation.
  local ic = floor(x + 0.5)
  if ic < 1 or ic > n then return nil end
  local vc = rd[ic]
  if vc == nil then return nil end

  local ones, votes = 0, 1
  if vc >= thr then ones = 1 end

  if T ~= nil and T >= 6 then
    local off = 0.2 * T
    local j
    for j = -1, 1, 2 do
      local i = floor(x + j * off + 0.5)
      if i >= 1 and i <= n then
        local v = rd[i]
        if v ~= nil then
          votes = votes + 1
          if v >= thr then ones = ones + 1 end
        end
      end
    end
  end

  local b
  -- With 3 votes this is a plain majority; with 2 (an outer tap off the end) a
  -- tie falls to the centre tap, which is the one we trust.
  if ones * 2 > votes then b = 1
  elseif ones * 2 < votes then b = 0
  elseif vc >= thr then b = 1
  else b = 0 end

  if invert then b = 1 - b end
  return b
end

-- Number of set bits in v. No bitwise operators in 5.0.2, so this is the
-- repeated-halving form.
function sdec.ua_popcount(v)
  local ones, t = 0, v
  local mod, floor = math.mod, math.floor
  while t > 0 do
    if mod(t, 2) == 1 then ones = ones + 1 end
    t = floor(t / 2)
  end
  return ones
end

-- ============================================================================
-- One frame
-- ============================================================================
-- Decode the frame whose start-bit leading edge sits at fractional sample t0.
--
-- Bit cell k (k = 0 for the start bit) spans [t0 + k*T, t0 + (k+1)*T), so its
-- centre is t0 + (k + 0.5)*T. Data bits are LSB first, which is universal for
-- asynchronous serial.
--
-- Returns value, err -- nil on success, else 'start', 'parity', 'framing' or
-- 'truncated'. A parity or framing failure still returns the value: a byte with a
-- bad stop bit is usually the right byte at the wrong baud rate.
function sdec.ua_frame(rd, n, t0, T, nbits, par, nstop, invert)
  local bit = sdec.ua_bit

  local sb = bit(rd, n, t0 + 0.5 * T, invert, T)
  if sb == nil then return nil, 'truncated' end
  if sb ~= 0 then return nil, 'start' end

  local val, bv = 0, 1
  local k
  for k = 1, nbits do
    local s = bit(rd, n, t0 + (k + 0.5) * T, invert, T)
    if s == nil then return nil, 'truncated' end
    if s == 1 then val = val + bv end
    bv = bv * 2
  end

  local slot = nbits + 1
  if par ~= sdec.PAR_NONE then
    local pb = bit(rd, n, t0 + (slot + 0.5) * T, invert, T)
    if pb == nil then return nil, 'truncated' end
    local pe = math.mod(sdec.ua_popcount(val), 2)
    local want
    if par == sdec.PAR_EVEN then want = pe else want = 1 - pe end
    if pb ~= want then return val, 'parity' end
    slot = slot + 1
  end

  local j
  for j = 1, nstop do
    local st = bit(rd, n, t0 + (slot + j - 1 + 0.5) * T, invert, T)
    if st == nil then return nil, 'truncated' end
    if st ~= 1 then return val, 'framing' end
  end

  return val, nil
end

-- ============================================================================
-- Sequential decode of a whole capture
-- ============================================================================
-- Returns a result table: {nf, ngood, nbad, vals, errs, tpos, framebits}.
--
-- Decoding is SEQUENTIAL, not per-candidate-edge, and that is the crux: inside a
-- byte a 1 -> 0 data transition is indistinguishable from a start bit, and only
-- knowing where the current frame ends separates them. So consume a frame, jump
-- past it, then look for the next start edge. Treating every falling edge as a
-- start bit produces plausible garbage.
--
-- The first frame has no predecessor, so it is anchored on an edge preceded by
-- >= 1.5 bit times at mark. A mark run that long cannot occur inside a frame (a
-- stop bit is one bit, anything longer is idle), so it is a real boundary.
--
-- tmin0 makes this RESUMABLE, and is what chunk_decode.tsp needs: pass the position
-- (in this array's coordinates) at which the previous frame ended and the anchor
-- search is skipped, so the first frame here is found exactly the way every
-- subsequent one is -- the first candidate edge not inside its predecessor. Frames
-- before tmin0 are therefore not emitted at all, which is simultaneously the
-- continuation rule and the de-duplication rule for an overlapping window.
--
-- It has to be a parameter rather than a second copy of this loop: the sequential
-- walk below is the subtlest code in the app, and a chunked variant of it would
-- drift out of step with this one at the first bug fix.
function sdec.ua_run(rd, n, T, nbits, par, nstop, invert, tmin0)
  local parbits = 0
  if par ~= sdec.PAR_NONE then parbits = 1 end
  local framebits = 1 + nbits + parbits + nstop

  local r = {nf = 0, ngood = 0, nbad = 0, nfalse = 0, vals = {}, errs = {},
             tpos = {}, framebits = framebits}

  local ne, ei, es = sdec.ne, sdec.ei, sdec.es
  if ne == nil or ne < 1 then return r end

  -- A frame begins where the line leaves mark. Physically that is a falling edge
  -- on a normally-idle-high line and a rising edge on an inverted one.
  local want = 0
  if invert then want = 1 end

  local anchor = nil
  local k
  if tmin0 == nil then
    for k = 1, ne do
      if es[k] == want then
        local markrun
        if k == 1 then markrun = ei[1] - 1 else markrun = ei[k] - ei[k-1] end
        if markrun >= 1.5 * T then anchor = k; break end
      end
    end
    if anchor == nil then
      -- No idle gap anywhere in the capture (a gapless stream, or a capture that
      -- starts mid-byte). Fall back to the first candidate edge and accept that
      -- the first frame may be misaligned.
      for k = 1, ne do
        if es[k] == want then anchor = k; break end
      end
    end
  else
    -- RESUMING. The caller already knows the phase, so re-deriving it would be
    -- strictly worse than trusting it: on a gapless stream the search above finds no
    -- 1.5-bit mark run and falls through to "the first candidate edge", which inside
    -- a byte is a 1 -> 0 DATA transition -- and every frame in the window after it
    -- decodes misaligned. Scanning from the first edge with tmin already set lets the
    -- loop's own exclusion test do the anchoring.
    anchor = 1
  end
  if anchor == nil then return r end

  -- Allow half a bit of slop so ordinary edge jitter cannot make a legitimate next
  -- start bit look like it arrived inside the previous frame. The last possible
  -- in-frame edge is at t0 + (1 + nbits + parbits)*T, i.e. (nstop - 0.5) bit times
  -- before tmin -- half a bit at nstop = 1. Mid-frame edges are still excluded, but
  -- the margin is half a bit, not a full one: widen the jitter allowance with care.
  local tmin = -1
  if tmin0 ~= nil then tmin = tmin0 end
  k = anchor
  local prev = nil          -- t0 of the previous emitted frame, for the idle test below
  while k <= ne do
    if es[k] == want and ei[k] >= tmin then
      local t0 = ei[k]
      local val, err = sdec.ua_frame(rd, n, t0, T, nbits, par, nstop, invert)
      if err == 'truncated' then break end

      -- A failed START BIT is a FALSE TRIGGER, not a corrupt byte. The edge was
      -- not a frame boundary at all -- usually an impulse on an idle line, one or
      -- two samples wide, so by mid-bit the line is back at mark. A real UART
      -- makes this check and returns to hunting without emitting anything.
      --
      -- Counting it as an errored byte would leak the spike count into both the
      -- byte stream and the error count, and the error count is what the format
      -- search scores on -- so impulse noise could tip the search onto the wrong
      -- format. Skipping also leaves tmin alone, so a false trigger cannot
      -- desynchronise the frames after it.
      if err == 'start' then
        r.nfalse = r.nfalse + 1
      else

      local nf = r.nf + 1
      r.nf = nf
      r.vals[nf] = val
      r.errs[nf] = err
      r.tpos[nf] = t0
      if err == nil then r.ngood = r.ngood + 1 else r.nbad = r.nbad + 1 end
      tmin = t0 + (framebits - 0.5) * T

      -- THE FIRST GENUINE IDLE. A pitch of two frame times or more is a gap no inter-byte
      -- spacing produces, so it is a message boundary -- and from there the framer is anchored
      -- correctly whatever it did earlier in the capture. Only the FIRST one is recorded, because
      -- only that one bounds the region a mid-byte capture start can corrupt.
      if r.idle1 == nil and prev ~= nil and (t0 - prev) >= 2 * framebits * T then
        r.idle1 = nf
      end
      prev = t0

      end
    end
    k = k + 1
  end

  -- A CAPTURE THAT BEGAN MID-BYTE corrupts the frames before the first idle and nothing after it.
  --
  -- Measured on the instrument, 8E1 at 9600 into the front terminals: the frames ahead of the first
  -- idle come out at pitches of 11, 12 and 14.9 bit times instead of 13, and every frame after it
  -- is exact. The cause is the anchor: for the first edge the mark run is only
  -- bounded BELOW, by the start of the capture, so two bit times of apparent mark is
  -- indistinguishable from a run of 1s in the middle of a byte -- and an armed capture legitimately
  -- starts a few samples before a real start bit, so the ambiguity cannot be resolved by requiring
  -- a longer run.
  --
  -- It is marked on EVIDENCE, not assumption: errors confined to the head. A capture that simply
  -- began at a message boundary has an idle1 too and no errors, so nothing is marked.
  if r.idle1 ~= nil and r.idle1 > 1 then
    local nh, nt, i = 0, 0, nil
    for i = 1, r.nf do
      if r.errs[i] ~= nil then
        if i < r.idle1 then nh = nh + 1 else nt = nt + 1 end
      end
    end
    if nh > 0 and nt == 0 then r.headsusp = r.idle1 - 1 end
  end

  return r
end

-- ============================================================================
-- Format search
-- ============================================================================
-- Score a decode. Errors are weighted heavily against, because the whole premise
-- is that a wrong format shows up as framing errors: a format that decodes 40
-- bytes with 12 errors is not a better description of the line than one that
-- decodes 30 with none.

-- FRAMING ERRORS AT THE CAPTURE BOUNDARY ARE NOT SIGNAL ERRORS.
--
-- A capture of a continuously busy line starts and ends wherever the trigger and the buffer end
-- put it, so the first and last frames are routinely sliced through the middle -- and a gapless
-- stream has no idle for the framer to anchor on, so it also RESYNCHRONISES a few frames in.
-- Measured on the instrument: without the exclusion, every 9600-baud capture of a healthy line
-- reports ERR 1 or 2 with the errors in the first row, colouring that row red on a signal with
-- nothing wrong with it. An error count that is never zero on good data is not a fault indicator,
-- it is decoration.
--
-- So the boundary region is excluded: `first` frames at the head and the last frame. Everything
-- between them is real, and a genuine framing error there still shows.
sdec.ua_edge_frames = 3     -- head frames the framer may spend resynchronising

-- Framing errors away from the window edges, i.e. the ones that are real faults.
function sdec.ua_bad_interior(r)
  if r == nil or r.errs == nil then return 0, 0 end
  local nin, nedge, i = 0, 0, nil
  local lo = sdec.ua_edge_frames + 1
  for i = 1, r.nf do
    if r.errs[i] ~= nil then
      if i < lo or i == r.nf then nedge = nedge + 1 else nin = nin + 1 end
    end
  end
  return nin, nedge
end

-- How far a misaligned head reaches: the last flagged frame inside headsusp, or 0. headsusp itself is
-- the region before the first gap, not a count of damage, so quoting it over-claims. One place, because
-- the note and ERR derived it separately and the panel said four bytes misaligned beside ERR 1.
-- `hs` overrides r.headsusp: a recording's TAIL result carries none (ck_tail_result does not set it),
-- so its caller supplies the run's figure and this still narrows it against the errs on screen.
function sdec.ua_head_bad(r, hs)
  if r == nil or r.errs == nil then return 0 end
  if hs == nil then hs = r.headsusp end
  if hs == nil then return 0 end
  local last, i = 0, nil
  if hs > r.nf then hs = r.nf end
  for i = 1, hs do
    if r.errs[i] ~= nil then last = i end
  end
  return last
end

-- BYTES YOU CANNOT TRUST, not frames that failed a check. In a misaligned head the bit boundaries are
-- wrong, so a frame there can pass parity and stop by luck and still hand back a plausible WRONG byte.
-- An identified head therefore counts IN FULL, and the resync exclusion is dropped across it: that
-- exclusion is for a healthy gapless line, and headsusp is evidence this is not one. The final frame
-- stays excluded -- the capture boundary halves it regardless. With no head this is ua_bad_interior,
-- so good captures still read 0. A real misaligned capture reads '????UMPS OVER TH', note 4, ERR 1.
function sdec.ua_err_count(r, hb)
  if r == nil or r.errs == nil then return 0 end
  if hb == nil then hb = sdec.ua_head_bad(r) end
  if hb > r.nf then hb = r.nf end
  local lo, n, i = sdec.ua_edge_frames, hb, nil
  if hb > lo then lo = hb end
  for i = lo + 1, r.nf do
    if i ~= r.nf and r.errs[i] ~= nil then n = n + 1 end
  end
  return n
end

-- Rank a decode: good frames less three times the bad ones.
function sdec.ua_score(r)
  return r.ngood - 3 * r.nbad
end

-- How much better a rival format must score to displace the incumbent.
--
-- A plain '>' is wrong. Several formats are genuinely indistinguishable on the
-- wire, and the shorter frame of such a pair always finds MORE frames in the same
-- capture, so it always scores higher: 0x55 at 8N1 with a two-bit gap has a
-- 12-bit period, and three 8-bit 6N1 frames tile two real frames exactly, so 6N1
-- decodes 9 error-free frames where 8N1 decodes 6. Both are complete, consistent
-- descriptions; no signal processing separates them.
--
-- So the rule is proportional -- a rival must win by >60 % -- which turns the
-- search order into a commonality prior. Being scale-free, it behaves the same on
-- a 6-byte capture and a 600-byte one, and real evidence clears it easily
-- (genuine 5N1 scores 8 against 8N1's 1).
-- Extra margin a 5- or 6-bit rival must clear, on top of the ordinary one.
--
-- Essentially every real stream is 7 or 8 data bits; 5 and 6 are legacy (Baudot
-- teletype, some telemetry) and well under 1 % of use. They also have the more dangerous
-- failure mode, because a SHORTER frame tiles a longer one: 6 data bits plus a stop bit
-- plus two idle bits is ten cells, exactly an 8N1 frame, so on any capture with a 2-bit
-- gap 6N1 and 8N1 both frame every byte with zero errors and the loser's bytes are
-- silently wrong. Measured scores for that case are 12 and 12 -- a dead tie, decided
-- purely by search order.
--
-- So they are BIASED AGAINST rather than excluded, and the bias can be STRONG because the
-- two situations differ by ratio rather than by a point or two. Genuine rare-width traffic
-- beats the common reading decisively -- back-to-back 5N1 scores 8 against 8N1's 1, or 12
-- against -12 -- while a tiling artefact ties it exactly, 12 against 12. A multiplicative
-- bias separates those cleanly, so at 8 a rare width must score nearly SIX TIMES the
-- incumbent and every genuine case still wins.
--
-- MEASURED BOUNDARY: 10 is the largest value that keeps every genuine 5N1 and 6N1 case
-- decoding, and 12 breaks the tightest one (8 bytes of back-to-back 5N1, where 8N1
-- accidentally frames 4 of them and scores 1, so the rival needs to clear 0.6 * k). 8
-- leaves real headroom rather than sitting on the wall. The 5N1/6N1-at-every-gap tests are
-- the guard: raise this too far and they fail.
--
-- What makes the bias safe rather than lossy is ua_refine_width, which walks back DOWN to
-- the rare widths afterwards on positive evidence -- top data bits that are 1 in every
-- frame -- instead of on a score a tiling artefact can win.
sdec.rarewidth = 8

-- Extra margin a POLARITY flip must clear when the idle prior came from the signalling
-- standard rather than from a run length -- i.e. when the window held no idle. 4 was chosen as
-- the smallest value that blocks the measured 18-frame inverted win while leaving every
-- offline inverted-line test decoding: those captures contain idle, so idle_weak is false and
-- this multiplier does not apply to them at all.
sdec.polmargin = 4

-- The bias multiplies the PROPORTIONAL term only, never the absolute floor. The floor is
-- there to stop noise deciding on a handful of frames, and quadrupling it made a rare
-- width unwinnable on exactly the short captures where it is easiest to be sure: genuine
-- back-to-back 5N1 over 8 bytes scores 8 against 8N1's 1, which is decisive evidence, and
-- a floor of 8 rejected it by one point. Scaling only the proportional part means the
-- bias grows with how much evidence the incumbent actually has.
function sdec.ua_margin(sc, nbits)
  local m = 0
  if sc > 0 then m = 0.6 * sc end
  if nbits ~= nil and nbits < 7 then m = m * sdec.rarewidth end
  if m < 2 then m = 2 end
  return m
end

-- Search every format at one polarity. Also returns the list of formats whose
-- raw score came within the margin, which is what the UI reports as ambiguity.
function sdec.ua_search_pol(rd, n, T, inv)
  local widths = sdec.ua_widths()
  local pars = sdec.ua_parities()
  local stops = sdec.ua_stops()
  local nnb = table.getn(widths)
  local npa = table.getn(pars)
  local nst = table.getn(stops)
  local best, alts = nil, {}
  local na = 0
  local b, c, d

  for b = 1, nnb do
    local nbits = widths[b]
    for c = 1, npa do
      local par = pars[c]
      for d = 1, nst do
        local nstop = stops[d]
        local r = sdec.ua_run(rd, n, T, nbits, par, nstop, inv)
        if r.ngood >= 1 then
          local sc = sdec.ua_score(r)
          na = na + 1
          alts[na] = {sc = sc, nbits = nbits, par = par, nstop = nstop}
          -- The RIVAL's width sets the extra margin, so a rare width has to be
          -- convincing rather than merely first past the ordinary bar.
          if best == nil or sc > best.score + sdec.ua_margin(best.score, nbits) then
            r.score  = sc
            r.nbits  = nbits
            r.par    = par
            r.nstop  = nstop
            r.invert = inv
            best = r
          end
        end
      end
    end
  end

  if best ~= nil then best.alts, best.nalts = alts, na end
  return best
end

-- Try both polarities and keep the better. Returns the result table (with
-- nbits/par/nstop/invert/score filled in) or nil.
function sdec.ua_autoformat(rd, n, T)
  sdec.fmt_note = nil

  -- The prior polarity goes first and keeps the decision unless the other wins by
  -- the same margin used for frame shape.
  --
  -- A raw score comparison fails here because the frame-count bias arrives by the
  -- back door: each polarity's winner is whatever format survived its own search,
  -- and the losing polarity can win its own search with a SHORTER frame that finds
  -- more of them -- on a repeated 0x55, the inverted reading's best 6N1 scores 11
  -- against the correct 8N1's 10, flipping polarity and data width at once. The
  -- margin blocks that while still letting a genuinely wrong prior be overturned,
  -- since a wrong polarity on real data scores near zero.
  -- A FORCED POLARITY ENDS THE CONTEST RATHER THAN ENTERING IT. Options > Polarity is the
  -- operator saying they know the signalling sense, which is exactly the case the contest is a
  -- substitute for -- and searching the other sense anyway is how a forced setting gets
  -- overturned by a score.
  if sdec.force_invert ~= nil then
    return sdec.ua_search_pol(rd, n, T, sdec.force_invert)
  end

  local first, second
  if sdec.idle == 0 then first, second = true, false else first, second = false, true end

  local ra = sdec.ua_search_pol(rd, n, T, first)
  local rb = sdec.ua_search_pol(rd, n, T, second)
  local best = ra
  if ra == nil then
    best = rb
  elseif rb ~= nil then
    -- HOW HARD IT IS TO OVERTURN THE PRIOR DEPENDS ON WHERE THE PRIOR CAME FROM.
    --
    -- sig_idle sets sdec.idle_weak when the capture contained NO IDLE, in which case the
    -- prior is not a run-length observation of this capture at all -- it is the signalling
    -- standard (a single-supply line marks high, a ground-straddling one is RS-232 and marks
    -- low). That is a physical fact about the wire, and a frame-count contest on one window
    -- should not be allowed to overturn physics on a 60 % margin.
    --
    -- MEASURED ON THE INSTRUMENT, and this is why the multiplier exists. Three consecutive
    -- captures of the SAME 9600-baud line at 1 MS/s: the first decodes correctly, the second
    -- flips to inverted and returns 18 frames with ZERO errors, the third inherits it. At
    -- 104 samples/bit a 19000-sample window holds only ~18 frames, and on
    -- that little evidence the inverted reading of ASCII text can out-score the correct one --
    -- because ASCII's always-zero top bit manufactures a periodic fake start edge nine bits
    -- after every real one. Self-consistent, confident, every byte wrong.
    --
    -- So when the prior is physical, the rival needs to win by ~3.4x rather than 1.6x. When
    -- the capture DID contain idle, sdec.idle_weak is false and the ordinary margin applies --
    -- run-length evidence is evidence, and a genuinely inverted line still overturns it, which
    -- is what the RS-232 auto-detect tests assert.
    local m = sdec.ua_margin(ra.score)
    if sdec.idle_weak then m = m * sdec.polmargin end
    if rb.score > ra.score + m then best = rb end
  end
  return best
end

-- Whether a candidate bit time could describe this capture at all.
--
-- The floor is sdec.minsabit (4 samples/bit) and the ceiling sdec.maxbaud (250 kBd),
-- both declared in serial_core.tsp. Below the floor a clean synthetic waveform still
-- decodes -- the harness recovers 13 of 13 bytes at 2.5 samples/bit -- which is exactly
-- why the gate is here rather than left to emerge: nothing real is that clean, and a
-- decode that only works on a noiseless line is a trap, not a feature.
-- Slack on the floor and the ceiling. Both carry the snap tolerance, because a
-- genuine 250 kBd line measures 3.99998 samples per bit and 250018 baud -- refusing it
-- for being two hundred-thousandths under its own floor is not a limit, it is a bug.
sdec.plaustol = 0.02

-- Is this bit time inside the samples-per-bit range the instrument can actually carry?
function sdec.ua_plausible(T, n)
  if T == nil then return false end
  if T < sdec.minsabit * (1 - sdec.plaustol) then return false end
  if T > n / 8 then return false end               -- no room for even one frame
  -- EVERY pulse is a whole number of bit times, so every observed width is at least
  -- one bit and the median is too: a candidate longer than the median pulse claims
  -- most pulses are shorter than a single bit. This is what rules out the long-bit-time
  -- rescalings that a damaged capture otherwise rewards: at 1 V of drift the fit is right
  -- (10.36 samples against a true 10.42) but frames badly, and an 8x rescaling framing one
  -- byte takes over and reports 1200 baud.
  if sdec.wmed ~= nil and sdec.wmed > 0 and T > 1.15 * sdec.wmed then return false end
  local fs = sdec.acq_fs or sdec.fs
  local b = fs / T
  return b >= 50 and b <= sdec.maxbaud * (1 + sdec.plaustol)
end

-- Is this candidate bit time a SUB-MULTIPLE of the one that generated the pulses?
--
-- The mirror of ua_plausible's too-LONG test, which had no counterpart. Halving is the dangerous
-- direction: every pulse that is a multiple of T is also a multiple of T/2, so the q gate cannot
-- separate them (measured 0.99999999 for both), while the halved reading finds twice the frames.
--
-- The ODD multiples separate them. At the true bit time some pulses are an odd number of cells --
-- a frame of varied data has single- and three-bit runs -- and at half it every pulse is even. It
-- catches 1/3 and 1/4 the same way. Not the median: all-0x00 is a nine-bit low run, so a median test
-- rejected the truth (broke 'decodes all 0x00').
--
-- IT IS A PRIOR ON REAL TRAFFIC, NOT A STRUCTURAL PROOF. A payload can have no odd run at all:
-- repeated 0xE6 at 8N1 with a 2-bit gap gives runs of 2,2,2,6 -- 0 of 159 odd. Measured on that case
-- and on 0x33/0xCC/0x0F/0x66/0x00 at three gaps: the gate changes no answer for the worse and fixes
-- two (0xE6 gap 1 refused -> correct, 0xCC gap 1 19200 -> 9600). The 0xE6 gap-2 capture does read as
-- half rate, but identically with this gate disabled, so that is the documented harmonic ambiguity
-- and not this.
--
-- Both constants measured over 368640 paired decodes. A FRACTION, not zero: jitter leaves 6-13 stray
-- odd multiples per ~1000 pulses, and demanding exactly zero repairs only 398 of 708 cases. Odd
-- fraction is 0.011-0.013 at a halved T against 0.587-0.604 at the true one.
--
-- ONLY BIT RUNS MAY VOUCH, bounded by sdec.maxmult for the reason sig_fit already gives: a multiple
-- beyond it is inter-byte idle carrying no timing information. The strays above are exactly that --
-- a 42-bit loop-seam gap gives k = 169, whose parity is set by the capture phase, not the format,
-- and one such width was enough to silence the gate and let ratio 0.25 through.
--
-- Gates CANDIDATES only, never the fit, so a corrupt fit can still be rescaled.
sdec.submult_minpulses = sdec.submult_minpulses or 20
sdec.submult_oddfrac   = sdec.submult_oddfrac   or 0.10

function sdec.ua_submultiple(T)
  if T == nil or T <= 0 then return false end
  local nw = sdec.nw or 0
  if nw < sdec.submult_minpulses then return false end
  local odd, seen = 0, 0
  local i
  for i = 1, nw do
    local k = math.floor(sdec.w[i] / T + 0.5)
    if k >= 1 and k <= sdec.maxmult then
      seen = seen + 1
      -- math.mod, not % and NOT math.fmod: 5.0.2 has no modulo operator and no math.fmod. The
      -- offline suites shim math.mod to math.fmod (gen_serial.lua:22), so fmod passes every test
      -- here and dies on the instrument -- measured, this build refused every capture with
      -- "attempt to call field `fmod' (a nil value)".
      if math.mod(k, 2) == 1 then odd = odd + 1 end
    end
  end
  if seen < sdec.submult_minpulses then return false end
  return odd < sdec.submult_oddfrac * seen
end

-- Whether the fit is consistent with the pulse-width distribution it came from.
--
-- This is the one number that separates "the line is faster than this instrument" from
-- "impulse noise captured the fit", and it is structural rather than tuned: in async
-- serial the median pulse is TWO bit times, because a ten-bit frame plus a couple of
-- idle bits produces runs whose middle value is about two. Measured med/Tfit is 2.0 for
-- every healthy capture tried -- 9600 clean, 250 kBd, 285 kBd, 921 kBd, and all the
-- drift cases -- and 3.0, 11 and 13 for the three spike-corrupted fits.
--
-- So when the fit is implausible AND consistent with its own widths, the line really is
-- out of range and rescaling would only manufacture a plausible-looking wrong answer.
-- When it is grossly inconsistent, the fit is the thing that is wrong, and rescaling is
-- exactly the right move.
function sdec.ua_fit_corrupt(Tfit)
  local med = sdec.wmed
  if med == nil or med <= 0 or Tfit == nil or Tfit <= 0 then return true end
  return med > 2.5 * Tfit
end

-- Why no bit time was usable, in the operator's terms. "Too fast for this sample
-- rate" and "nothing resembling a frame" are different faults with different actions
-- -- lower the baud rate, versus check the probe.
function sdec.ua_implausible_why(T)
  if T == nil then return 'no bit timing' end
  if T < sdec.minsabit then
    return string.format('%.1f samples/bit -- the line is faster than the %d kBd ceiling',
                         T, sdec.maxbaud / 1000)
  end
  local fs = sdec.acq_fs or sdec.fs
  if fs / T > sdec.maxbaud * (1 + sdec.snaptol) then
    return string.format('%.0f baud is past the %d kBd ceiling',
                         fs / T, sdec.maxbaud / 1000)
  end
  return string.format('no frame fits a %.1f sample bit time', T)
end

-- Bit times worth scoring: the fit rescaled by sdec.ratios, plus MEDIAN-DERIVED
-- candidates.
--
-- The median matters because the least-squares fit has one failure mode the ratio
-- ladder cannot cover. Forty 2-sample spikes on a 9600 baud line produce forty narrow
-- widths that corroborate EACH OTHER, so seed corroboration passes them, and the fit
-- lands at 0.95 samples against a true bit time of 10.42 -- a ratio of 11, which is not
-- on the ladder and never will be for every such case. Coverage scoring cannot reject
-- it either, because a shorter trial period reclassifies the contradicting long widths
-- as idle and drops them from its own denominator.
--
-- The median cannot be moved that way: spikes are a minority of the widths however
-- many of them there are. Real widths are 1..maxmult bit times, so med/k for small k
-- brackets the truth from a direction impulse noise cannot corrupt -- and med/1 alone
-- recovers all three spike cases the ladder missed.
function sdec.ua_cands(Tfit)
  local c, m = {}, 0
  local i
  local nr = table.getn(sdec.ratios)
  for i = 1, nr do
    m = m + 1
    c[m] = {T = Tfit * sdec.ratios[i], r = sdec.ratios[i]}
  end
  local med = sdec.wmed
  if med ~= nil and med > 0 and Tfit ~= nil and Tfit > 0 then
    local k
    for k = 1, 6 do
      local T = med / k
      -- Skip anything the ladder already covers, so near-duplicates do not crowd out
      -- the tie-break order.
      if T < 0.97 * Tfit or T > 1.03 * Tfit then
        m = m + 1
        c[m] = {T = T, r = T / Tfit}
      end
    end
  end
  return c, m
end

-- Choose the bit time by DECODE quality rather than by pulse statistics alone.
--
-- sig_bittime() fits the greatest common bit period of the observed pulse widths,
-- which is the right estimator but has two blind spots seen on synthesised
-- captures: the widths can share a common factor (0x00 at 8N1 with a two-bit gap
-- yields only 9- and 3-bit runs, best-fitting THREE bit times), and a sub-bit
-- glitch can score higher than the truth because a shorter trial period draws
-- fewer long widths into its coverage measure (a 2-sample notch produced a fit
-- at one fifth of the real bit time, q = 0.984 against the truth's 0.962).
--
-- Framing is a far stronger constraint than pulse width: a wrong bit time puts
-- the stop bit sampling point on a data bit, which shows up as errors. So try
-- small integer rescalings and keep the one that FRAMES best, probing with just
-- the common data widths and no parity to keep it cheap.
--
-- Best score any probe format achieves at one candidate bit time, or nil if none
-- frames. Parity is included: without it 8E1 traffic scores negative at EVERY
-- candidate, because its parity bit reads as a bad stop bit, and the search then
-- wanders off to a nonsense rescaling.

-- HOW MANY SAMPLES A PROBE MAY LOOK AT. nil = all of them.
--
-- This is the search's cost knob, and the search is the app's worst latency offender: measured
-- 4.376 s to auto-detect 38400 baud on the instrument, against a 500 ms press-latency budget.
-- The reason is multiplicative -- 3 widths x 3 parities x 2 polarities is EIGHTEEN full framing
-- passes per candidate bit time, and sdec.ratios offers thirteen of those before the extra
-- integer sub-multiples -- so a probe pass is run over the samples upward of two hundred times.
--
-- Nothing about that needs the WHOLE capture. A probe's output is a relative score used only to
-- rank candidates against each other, and ranking is settled long before the last byte: a few
-- dozen frames separate a format that describes the waveform from one that does not, and a format
-- that is wrong is wrong in the first frames as much as the last. Scoring 240 bytes to pick
-- between candidates and then decoding all 240 properly is doing the expensive part twice.
--
-- The FINAL decode is unaffected -- it runs over everything. Only the ranking is truncated.
--
-- 4000 IS MEASURED, NOT CHOSEN. Sweeping the cap against the 142-case hostile suite, edge-anchored:
--
--     none 8000 6000 4000 3000 2000 1500   ->  121 ok, 21 degraded, 0 WRONG, 0 RAISED  (identical)
--     1000                                 ->  120 ok, 22 degraded, 0 WRONG, 0 RAISED
--
-- So discrimination is intact down to 1500 samples and starts costing at 1000. 4000 keeps 2.7x
-- margin over that floor while cutting the search's work 5x against a 20 000-sample capture --
-- which should take the measured 4.376 s auto-detect at 38400 baud to roughly 0.9 s. It is ~48
-- bytes at 8.33 samples/bit: plenty to rank formats, far less than a page.
--
-- Re-run that sweep (SDEC_PROBE_N=N lua tools/stress_serial.lua) before changing this. The
-- failure mode of too small a value is not a crash, it is a QUIETLY WORSE ANSWER -- a degraded
-- case rather than a wrong one -- and only the suite makes that visible.
sdec.ua_probe_n = sdec.ua_probe_n or 4000

-- How much better a snapped RESCALING must score before it may displace the width fit, and how
-- badly the fit must be failing to be displaceable at all. See ua_best_end.
sdec.ua_alt_margin = sdec.ua_alt_margin or 3
sdec.ua_alt_badfrac = sdec.ua_alt_badfrac or 0.1

-- Best score any probe format reaches at one candidate bit time, or nil if none frames.
function sdec.ua_probe(rd, n, T)
  local cap = sdec.ua_probe_n
  if cap ~= nil and cap > 0 then
    local n0 = 1
    if sdec.ne ~= nil and sdec.ne >= 1 and sdec.ei ~= nil and sdec.ei[1] ~= nil then
      n0 = sdec.ei[1]
    end
    if n - n0 > cap then n = n0 + cap end
  end
  local npn = table.getn(sdec.probe_nbits)
  local npa = table.getn(sdec.try_par)
  local sc, scbad, scgood = nil, nil, nil
  local j, c, k
  for j = 1, npn do
    for c = 1, npa do
      for k = 0, 1 do
        local r = sdec.ua_run(rd, n, T, sdec.probe_nbits[j], sdec.try_par[c], 1, (k == 1))
        if r.ngood >= 1 then
          local s = sdec.ua_score(r)
          -- nbad too: a caller deciding whether to displace this fit needs to know whether it is
          -- FAILING or merely finding fewer frames. See ua_best_end.
          if sc == nil or s > sc then sc, scbad, scgood = s, r.nbad, r.ngood end
        end
      end
    end
  end
  return sc, scbad, scgood
end

-- Returns bittime, ratio.
--
-- The rescaling search is GATED, not unconditional. Halving the bit time roughly
-- doubles the frames found, so any score that counts frames -- or bits, or
-- coverage -- is biased toward a smaller bit time: on a repeated 0x55 square wave
-- the true bit time frames 6 bytes and a quarter of it frames 30, all error-free.
-- Every rescaling of an alternating pattern is self-consistent, so no scoring
-- function can prefer the truth.
--
-- So the width fit is trusted whenever it snaps to a standard rate and frames
-- something; otherwise the snapped rescalings are searched, since real devices use
-- standard rates and that is the strongest prior available. A fit too short to
-- frame anything scores at or below zero and is rejected that way.
--
-- BUT TRUSTING IT SILENTLY IS WRONG, and the reason is worth stating precisely: a
-- common factor in the pulse widths does NOT reliably produce a non-standard rate,
-- because half of a standard rate is usually also standard. Eight 0x00 frames at
-- 9600 7N1 with a one-bit gap fit 4800 exactly, and read as four 0x08 bytes at
-- 4800 8N1 with zero errors -- and that is not an error, because the two encodings
-- are bit-for-bit the SAME WAVEFORM (verified sample by sample). Which device is on
-- the wire cannot be recovered from it.
--
-- Both readings are therefore legitimate, and the commonality prior even favours
-- the 8N1 one. What the operator needs is to be TOLD, so a rescaling that also
-- snaps and explains materially more of the capture is reported in sdec.baud_note.
-- Perfectly periodic traffic is what creates this; irregular inter-byte gaps break
-- the coincidence, so it is largely a synthetic-stream phenomenon.
-- SPLIT INTO THREE, so the expensive middle can be served a slice at a time.
--
-- ua_best_begin  does the prologue and the cheap width pass, and probes the FIT itself
-- ua_best_probe  scores ONE candidate -- the expensive unit, ~76 ms measured at 38400 baud
-- ua_best_end    applies the decision logic to whatever the probes found
--
-- ua_best() itself is begin + probe-every-candidate + end, so every existing caller is unchanged
-- and the offline suites judge the split rather than trusting it. The reason for splitting at the
-- CANDIDATE is that a candidate probe is the loop's atom: 18 framing passes (3 widths x 3 parities
-- x 2 polarities) with no state carried between candidates except the best-so-far. So the
-- checkpoint is four values -- the index and the winning triple -- and a slice boundary cannot
-- land anywhere awkward.
--
-- The state table `st` holds everything the three share. Kept as one table rather than a dozen
-- returns because the 200-active-locals ceiling is real on this instrument and this function was
-- already among the largest.
function sdec.ua_best_begin(rd, n, Tfit)
  local fs = sdec.acq_fs or sdec.fs
  sdec.baud_note = nil

  local _, snap1 = sdec.sig_snap(fs / Tfit)

  -- Score every candidate that itself snaps to a standard rate. This runs even when
  -- the unscaled fit is going to be kept, because an alternative that explains more
  -- of the capture has to be reported rather than discarded.
  -- An implausible fit is only rescaled when it is also inconsistent with its own
  -- widths. Otherwise the fit is telling the truth and the truth is out of range.
  local mayrescale = sdec.ua_plausible(Tfit, n) or sdec.ua_fit_corrupt(Tfit)

  local cands, nc = sdec.ua_cands(Tfit)
  local i

  -- First pass: how well each candidate explains the PULSE WIDTHS. Cheap -- sig_fit
  -- works on the width array, not on the samples -- and it has to be known for every
  -- candidate before any of them can be judged, since the gate is relative.
  local qbest = 0
  for i = 1, nc do
    if sdec.ua_plausible(cands[i].T, n) then
      local _, q = sdec.sig_fit(sdec.w, sdec.nw, cands[i].T)
      cands[i].q = q or 0
      if cands[i].q > qbest then qbest = cands[i].q end
    end
  end
  local qmin = sdec.qgate * qbest

  -- The fit itself is held to the same gate as its rivals.
  local sc1, q1, bad1, good1 = nil, nil, nil, nil
  if sdec.ua_plausible(Tfit, n) then
    local _, qq = sdec.sig_fit(sdec.w, sdec.nw, Tfit)
    q1 = qq or 0
    if q1 >= qmin then sc1, bad1, good1 = sdec.ua_probe(rd, n, Tfit) end
  end

  return {rd = rd, n = n, Tfit = Tfit, fs = fs, snap1 = snap1,
          mayrescale = mayrescale, cands = cands, nc = nc, qmin = qmin,
          sc1 = sc1, bad1 = bad1, good1 = good1,
          i = 0, altT = nil, altsc = nil, altr = nil}
end

-- Score the next candidate. Returns false once every candidate has been scored. One call is one
-- slice's worth of work; the caller decides how many to run before handing the panel back.
function sdec.ua_best_probe(st)
  if st == nil or st.i >= st.nc then return false end
  st.i = st.i + 1
  local i = st.i
  local T, ratio, q = st.cands[i].T, st.cands[i].r, st.cands[i].q
  if st.mayrescale and ratio ~= 1 and q ~= nil and q >= st.qmin
     and sdec.ua_plausible(T, st.n)
     -- ONLY DEFEND A FIT THAT LANDED ON A STANDARD RATE. The gate exists to stop a GOOD fit being
     -- displaced by its own halving; when the fit does not snap it is not a good fit, and a
     -- rescaling is the only route to the truth. MEASURED: repeated 0xE0 at 8N1 gap 2 is all
     -- 6-bit runs, so the fit lands on 1600 Bd (snapped false) and the TRUTH is the ratio-1/6
     -- candidate, whose multiples are all k = 6 -- even, so an ungated test rejected it and handed
     -- 4800 to the ratio-1/3 candidate: 20 frames of 0x1C, zero errors, against 40 exact 0xE0.
     and not (st.snap1 and sdec.ua_submultiple(T)) then
    local _, snapped = sdec.sig_snap(st.fs / T)
    if snapped then
      local sc = sdec.ua_probe(st.rd, st.n, T)
      -- Candidates are ordered outward from ratio 1 and the comparison is strict,
      -- so the closest one wins ties.
      if sc ~= nil and (st.altsc == nil or sc > st.altsc) then
        st.altT, st.altsc, st.altr = T, sc, ratio
      end
    end
  end
  return true
end

-- How many candidates there are, for a "searching 3/12" status row.
function sdec.ua_best_progress(st)
  if st == nil then return 0, 0 end
  return st.i, st.nc
end

-- Decide between the width fit and the best rescaling, and report an ambiguity if there is one.
function sdec.ua_best_end(st)
  local rd, n, Tfit, fs = st.rd, st.n, st.Tfit, st.fs
  local snap1, sc1 = st.snap1, st.sc1
  local altT, altsc, altr = st.altT, st.altsc, st.altr
  local bad1, good1 = st.bad1, st.good1

  if snap1 and sc1 ~= nil and sc1 > 0 then
    if altsc ~= nil and altsc > sc1 then
      local ab = sdec.sig_snap(fs / altT)
      -- ONLY DISPLACE A FIT THAT IS FAILING, and then only by a wide margin. A margin alone
      -- cannot decide it: on an alternating pattern every rescaling is error-free, so 0x55 frames
      -- 6 bytes at the true rate and 30 at a quarter of it. What separates the cases is whether the
      -- FIT explains the capture -- measured, a 9600 line fitted 19200 with 35 bad frames (score
      -- 11) against a snapped 9600 at ~150. A clean fit is never displaced.
      local failing = bad1 ~= nil and good1 ~= nil and good1 > 0 and
                      bad1 >= (sdec.ua_alt_badfrac or 0.1) * (good1 + bad1)
      if failing and altsc >= (sdec.ua_alt_margin or 3) * sc1 then
        sdec.baud_note = string.format(
          '%s baud fits far better than %s (score %d vs %d, %d framing error(s))',
          tostring(ab), tostring((sdec.sig_snap(fs / Tfit))), altsc, sc1, bad1)
        return altT, altr
      end
      -- "score", not "frames": these come from ua_score = ngood - 3*nbad, so a
      -- decode with errors scores below its frame count and the two can be
      -- misordered relative to the frames actually found.
      sdec.baud_note = string.format('%s baud also fits this waveform (score %d vs %d)',
                                     tostring(ab), altsc, sc1)
    end
    return Tfit, 1
  end

  if altT == nil then
    -- No rescaling frames anything, so the FIT is the only evidence there is -- and
    -- pulse-width evidence is real evidence. Keep it, unless it is not even admissible.
    --
    -- sc1 is nil exactly when the fit failed one of its own two admission tests:
    -- ua_plausible (samples per bit inside the range this instrument can carry) or the
    -- relative q gate. That is what rejects the undersampled line this branch was
    -- written for -- at 921600 baud on a 1 MS/s capture the fit is 1.09 samples per bit,
    -- and four plausible-looking bytes once came back labelled 230400 baud.
    --
    if sc1 == nil then
      return nil, 1, sdec.ua_implausible_why(Tfit)
    end
    return Tfit, 1
  end
  -- A RESCALING THAT FRAMES NOTHING MAY NOT DISPLACE AN ADMISSIBLE FIT THAT LANDS ON A
  -- STANDARD RATE. ua_score is ngood - 3*nbad, so a score at or below zero means the
  -- errors outnumber the good frames threefold: the candidate does not describe the
  -- capture, and ranking two such candidates against each other is ranking noise.
  --
  -- Measured on a waveform where every candidate fails -- a LIN bus with no break delimiter,
  -- where the merged break and start bit destroy the framing. The true 19200 scores -20 and its
  -- own half scores -15, so the half wins on -15 > -20 and is reported as a confidently snapped
  -- 38400. The fit is right, snapped, and has the best pulse-width q of any candidate; nothing
  -- about -15 is evidence.
  --
  -- Both halves of the guard are load-bearing. `sc1 ~= nil` means the fit passed its own
  -- plausibility and q admission tests, so there is something worth protecting: when the
  -- fit is INADMISSIBLE, a negative-scoring rescaling really is the best answer available
  -- and must still win -- on noise plus spikes plus ringing plus drift at 9600 the fit
  -- lands at 3.47 samples/bit, and the only rescaling to survive the q gate is the truth
  -- at 9600 scoring -5. And `snap1` matters because a standard rate is the strongest prior
  -- there is: when the fit does NOT snap and a rival does, that is real evidence and the
  -- rival should win however badly both frame.
  if snap1 and sc1 ~= nil and altsc ~= nil and altsc <= 0 then return Tfit, 1 end
  if sc1 ~= nil and altsc ~= nil and altsc <= sc1 then return Tfit, 1 end
  return altT, altr
end

-- The unchunked form. Every current caller uses this; the stepper exists for the panel.
function sdec.ua_best(rd, n, Tfit)
  local st = sdec.ua_best_begin(rd, n, Tfit)
  while sdec.ua_best_probe(st) do end
  return sdec.ua_best_end(st)
end

-- Collapse data bits that are 1 in EVERY frame into the stop bit.
--
-- A data bit that never changes carries no information, and in the TOP position it is
-- indistinguishable from the stop bit that has to follow it: N data bits whose MSB is
-- always 1 describe exactly the same cells as N-1 data bits with the stop bit one place
-- earlier. Both readings are complete and consistent, so error scoring cannot separate
-- them, and the longer frame wins whenever noise gives it a single extra frame -- which is how a
-- spiked 9600 baud line comes back as 9N1 with every byte 256 too large.
--
-- The shorter reading is also almost always the physically right one. Nine-bit formats
-- exist for multidrop address marking, where the ninth bit VARIES by design; a ninth
-- bit stuck at 1 is not a nine-bit device.
--
-- Only an always-ONE bit qualifies. An always-zero MSB is ordinary 7-bit ASCII in an
-- 8-bit frame and must be left alone. Seven data bits plus MARK parity genuinely does
-- put a constant 1 there, which is why the collapse is reported rather than silent.
--
-- Guards match ua_refine_parity: >= 6 good frames, and >= 3 distinct values in the bits
-- being KEPT, so a repeated byte cannot drive it.
function sdec.ua_refine_width(r, rd, n, T)
  if r == nil or r.par ~= sdec.PAR_NONE then return r end
  -- Likewise a forced WIDTH: collapsing an always-zero top bit is a width decision, and the
  -- operator has already made it.
  if sdec.force_nbits ~= nil then return r end
  if r.ngood < 6 then return r end
  local mod = math.mod
  local want, dropped = r.nbits, 0
  -- Floor follows the width setting. With rare widths excluded the collapse stops at 7,
  -- but it still DETECTS that it wanted to go further and says so below -- refusing to
  -- report 6N1 is a defensible choice, reporting 7N1 values that are 64 too large without
  -- mentioning it is not.
  local floorw = 5
  if not sdec.widths_any then floorw = 7 end

  while want > floorw do
    local top  = 2 ^ (want - 1)
    -- MASK OFF the bits already dropped. Testing the raw value instead only works when
    -- every strip happens to be valid: a 6N1 stream read as 7N1 has values d + 64, and
    -- once bit 6 is dropped the test for bit 5 must look at d, not at d + 64 -- which is
    -- always >= 32 and so always "another constant 1". It stripped twice, the 5-bit
    -- re-decode then framed worse than the 7-bit one, the ngood guard threw the whole
    -- collapse away, and 6N1 traffic came back as 7N1 with every byte 64 too large and
    -- ZERO framing errors.
    local span = 2 ^ want
    local allone, seen, ndist = true, {}, 0
    local i
    for i = 1, r.nf do
      if r.errs[i] == nil then
        local v = r.vals[i]
        if v == nil then allone = false; break end
        local eff = mod(v, span)
        if eff < top then allone = false; break end
        local low = mod(eff, top)
        if seen[low] == nil then seen[low] = true; ndist = ndist + 1 end
      end
    end
    if not allone or ndist < 3 then break end
    want = want - 1
    dropped = dropped + 1
  end

  -- EVIDENCE STILL POINTING BELOW THE FLOOR: the stream looks like a rare width that the
  -- current setting excludes. Refusing to report 6N1 is a defensible choice; reporting 7N1
  -- values that are 64 too large without mentioning it is not. Computed before either note
  -- is composed, so the two cannot fight over fmt_note.
  local blocked = nil
  if want == floorw and floorw > 5 and r.ngood >= 6 then
    local top, span = 2 ^ (want - 1), 2 ^ want
    local allone, i = true, nil
    for i = 1, r.nf do
      if r.errs[i] == nil then
        local v = r.vals[i]
        if v == nil or mod(v, span) < top then allone = false; break end
      end
    end
    if allone then
      blocked = string.format('bit %d was 1 in every frame -- this may be %dN%d; set Data Bits to "Auto (any width)"',
                              want - 1, want - 1, r.nstop)
    end
  end

  if dropped < 1 then
    if blocked ~= nil then sdec.fmt_note = blocked end
    return r
  end

  -- RE-DECODE rather than shifting the values in place. The shorter frame has a shorter
  -- framebits, so its resync point sits earlier and it can pick up a start edge the
  -- longer reading steps over -- shifting values keeps the longer reading's frame count while
  -- claiming the shorter format.
  local r2 = sdec.ua_run(rd, n, T, want, r.par, r.nstop, r.invert)
  if r2 == nil or r2.ngood < r.ngood then return r end
  r2.score  = sdec.ua_score(r2)
  r2.nbits  = want
  r2.par    = r.par
  r2.nstop  = r.nstop
  r2.invert = r.invert
  r2.alts, r2.nalts = r.alts, r.nalts
  sdec.fmt_note = string.format('%s also fits; chose %s (the top %d data bit(s) were 1 in every frame)',
                                sdec.ua_fmt_name(r.nbits, r.par, r.nstop),
                                sdec.ua_fmt_name(want, r.par, r.nstop), dropped)
  if blocked ~= nil then sdec.fmt_note = sdec.fmt_note .. '; ' .. blocked end
  return r2
end

-- Separate 8N1 from 7E1 / 7O1 -- the one pair error scoring cannot tell apart,
-- since 7 data bits plus parity occupy the same ten cells as 8 data bits with the
-- stop bit in the same place. 7E1 traffic decodes as 8N1 with zero framing errors
-- and wins on order.
--
-- What gives it away: under the 8N1 reading bit 7 would equal the parity of bits
-- 0..6 in EVERY frame, a 1-in-2 coincidence per frame.
--
-- Guards: >= 6 good frames and >= 3 distinct values. The second matters because a
-- repeated byte is genuinely ambiguous -- 0x55 as 8N1 and as 7E1 give identical
-- waveforms -- so the common format should win.
-- How many frames at each end are excluded from the parity vote regardless of what headsusp says.
-- THREE at the head, not one: a gapless stream "RESYNCHRONISES a few frames in" (see the boundary
-- comment above ua_score), so trusting only the first frame to be suspect contradicts what this
-- file already knows. One at the tail, which the buffer end slices.
sdec.par_skiphead = sdec.par_skiphead or 3
sdec.par_skiptail = sdec.par_skiptail or 1
-- TWO TIERS, because the sample size a verdict needs depends on whether it tolerates dissent.
--   UNANIMOUS agreement: par_minvote_all is enough. This is the original rule and it must stay
--   small -- 'Hello, World!' is thirteen bytes and is legitimately 7E1, so a bar of twenty would
--   refuse to classify a whole class of real short captures. Raising it broke six tests.
--   ANY DISSENT: par_minvote_frac and par_minfrac. Tolerating a dissenter is the new and riskier
--   claim, so it earns the larger sample. Null hypothesis is random 8-bit data, bit 7 matching
--   parity with p = 0.5: 95 % of 20 votes is 2e-5, of 140 is 1.4e-31 (doubled, both parities tried).
sdec.par_minfrac      = sdec.par_minfrac      or 0.95
sdec.par_minvote_all  = sdec.par_minvote_all  or 6
sdec.par_minvote_frac = sdec.par_minvote_frac or 20
-- Votes required in EACH bit-7 state. The guard that stops a restricted alphabet faking parity.
sdec.par_minboth = sdec.par_minboth or 2

function sdec.ua_refine_parity(r, rd, n, T)
  if r == nil then return r end
  -- A FORCED PARITY IS NOT A HYPOTHESIS TO REFINE. Reading the top data bit as parity is exactly
  -- what the operator turned off by setting Parity = None, so running it anyway hands 7E1 back to
  -- someone who asked for 8N1 -- the setting takes effect in the search and is then undone here.
  if sdec.force_par ~= nil then return r end
  if r.nbits ~= 8 or r.par ~= sdec.PAR_NONE then return r end
  if r.ngood < 6 then return r end

  -- SKIP THE CAPTURE BOUNDARIES, ALWAYS -- not only when headsusp says so.
  --
  -- UNANIMITY WILL NOT DO, and headsusp cannot rescue it: headsusp needs `nh > 0`, a framing ERROR
  -- in the head, and a misaligned head that happens to frame cleanly as 8N1 produces NONE. Measured
  -- on hardware with v78 (7E1, gap = 0): 4 of 8 captures come back with ZERO flagged frames and every
  -- byte carrying a spurious bit 7 -- 7E1 read as 8N1, parity absorbed into data bit 7, nothing
  -- flagged, because 8N1 is a genuinely self-consistent reading of a 7E1 waveform. 47 of 48 bytes
  -- have bit 7 == the parity of their low seven, the exception being the FIRST frame. With gap = 0
  -- there is often no idle1 either, so headsusp has two independent reasons not to fire.
  local i0 = sdec.par_skiphead + 1
  if r.headsusp ~= nil and r.headsusp + 1 > i0 then i0 = r.headsusp + 1 end
  local i1 = r.nf - sdec.par_skiptail

  local mod = math.mod
  local nev, nod, nvote = 0, 0, 0
  local seen, ndist = {}, 0
  local ntop0, ntop1 = 0, 0
  local i
  for i = i0, i1 do
    if r.errs[i] == nil then
      nvote = nvote + 1
      local v = r.vals[i]
      local top = 0
      if v >= 128 then top = 1 end
      if top == 1 then ntop1 = ntop1 + 1 else ntop0 = ntop0 + 1 end
      local low = mod(v, 128)
      if seen[low] == nil then seen[low] = true; ndist = ndist + 1 end
      local pe = mod(sdec.ua_popcount(low), 2)
      if top == pe then nev = nev + 1 end
      if top == 1 - pe then nod = nod + 1 end
    end
  end

  if ndist < 3 then return r end
  if nvote < sdec.par_minvote_all then return r end
  -- BOTH BIT-7 STATES, OR IT IS NOT EVIDENCE OF PARITY AT ALL. ndist alone does not protect: 48 of
  -- the 95 printable ASCII characters have even popcount, so an 8N1 payload drawn only from those
  -- has bit 7 always 0 AND even parity 0 in every frame -- perfect apparent 7E1 agreement over
  -- arbitrarily many distinct values. A real parity stream exercises both states (all 94 visible
  -- glyphs: 46 of them set bit 7 under even parity). A constant-parity payload genuinely lacks the
  -- evidence to prefer 7E1 over 8N1, and must stay 8N1.
  if ntop0 < sdec.par_minboth or ntop1 < sdec.par_minboth then return r end

  -- Unanimity gets in on the small sample; anything short of it must clear the fraction AND the
  -- larger vote count. So a dissent can never buy a promotion that unanimity could not.
  local need = sdec.par_minfrac * nvote
  if nvote < sdec.par_minvote_frac then need = nvote end
  local par, pname, nagree = nil, nil, 0
  if nev >= need and nev >= nod then
    par, pname, nagree = sdec.PAR_EVEN, 'even', nev
  elseif nod >= need then
    par, pname, nagree = sdec.PAR_ODD, 'odd', nod
  end
  if par == nil then return r end

  -- HOW THE PROMOTION IS APPLIED DEPENDS ON WHETHER ANY VOTER DISSENTED, and the distinction is
  -- not cosmetic. Rewriting every value to mod(v,128) is sound only when EVERY voting frame agreed:
  -- then no frame is being relabelled 7E1 while actually failing that parity. Under a fraction the
  -- dissenters would keep a clean bill of health while contradicting the format just assigned --
  -- the fix would itself become a silent wrong answer, which is the defect class this decoder
  -- exists to avoid. So a dissent forces a real re-decode, where a dissenter becomes a real parity
  -- error. ua_refine_width re-decodes for a related reason; see its comment.
  local strict = (nagree == nvote)
  local note = string.format(
      '8N1 also fits; chose 7%s1 (bit 7 tracked %s parity in %d of %d frames)',
      string.upper(string.sub(pname, 1, 1)), pname, nagree, nvote)

  if not strict then
    -- rd/n/T are absent only when a caller hands in a synthetic result table. Refuse rather than
    -- fall back to the unsound in-place path: staying 8N1 is a worse answer but an honest one.
    if rd == nil or n == nil or T == nil then return r end
    local r2 = sdec.ua_run(rd, n, T, 7, par, r.nstop, r.invert)
    if r2 == nil then return r end
    r2.score = sdec.ua_score(r2)
    -- WIDENED, NEVER OVERWRITTEN. The re-decode finds its own suspect-head extent and the 8N1 result's
    -- is nil whenever that pass framed the head cleanly, so overwriting loses the evidence and ERR then
    -- counts no head on a capture this format says is misaligned. Measured over the firings on the
    -- 7-bit random payload: 2 in 7 differ, at 14 and 57 frames, narrowing to 5 and 4. Both formats frame
    -- 10 bits, so the figures share a unit; the wider is safe because headsusp only bounds
    -- ua_head_bad's scan and the narrowing is what prevents over-claiming.
    if r.headsusp ~= nil and (r2.headsusp == nil or r.headsusp > r2.headsusp) then
      r2.headsusp = r.headsusp
    end
    -- STAMP THE FORMAT ON. ua_run returns values and errors, not which format produced them -- the search
    -- loop does that when it picks a winner -- so this re-decode came back with nbits/par/nstop/invert all
    -- NIL, and only score and headsusp were copied. The branch whose purpose is to change the format
    -- returned one with none. It surfaced as a crash in ua_note_fmt's %d, so capture() raised while
    -- DESCRIBING a decode that had succeeded and the bench filed 'no bytes decoded'. 14 of 256 offsets
    -- offline, identical at c7ca3e9. The strict path escaped it by mutating r in place.
    r2.nbits, r2.par, r2.nstop, r2.invert = 7, par, r.nstop, r.invert
    sdec.fmt_note = note
    return r2
  end

  -- Unanimous: the low 7 bits ARE the value in every frame that voted, so strip in place.
  for i = 1, r.nf do
    local v = r.vals[i]
    if v ~= nil then r.vals[i] = mod(v, 128) end
  end
  r.nbits = 7
  r.par   = par
  sdec.fmt_note = note
  return r
end

-- ============================================================================
-- Top-level decode
-- ============================================================================
-- Formats whose score came within the margin of the winner's -- the ones this
-- capture genuinely does not distinguish. Returns a name list and its length.
--
-- PURE, and it must be called BEFORE ua_refine_parity. The exclusion test compares
-- each candidate against the format that WON THE SEARCH, and refine_parity
-- rewrites r.nbits/r.par in place -- so running afterwards compared 8N1-scored
-- alternatives against 7E1. Worse, refine_parity also sets fmt_note, which the old
-- version bailed on, so whenever the 7E1 reclassification fired NO alternative was
-- ever reported at all. Composing the note is now a separate step (ua_note_fmt),
-- which is what lets both notes coexist.
function sdec.ua_alts(r)
  local names, m = {}, 0
  if r == nil or r.alts == nil then return names, 0 end
  if (r.ngood or 0) < sdec.alt_minframes then return names, 0 end
  local lim = r.score - sdec.ua_margin(r.score)
  local i
  for i = 1, r.nalts do
    local a = r.alts[i]
    if a.sc >= lim and not (a.nbits == r.nbits and a.par == r.par) then
      m = m + 1
      if m <= 3 then names[m] = sdec.ua_fmt_name(a.nbits, a.par, a.nstop) end
    end
  end
  return names, m
end

-- Fold the alternatives into sdec.fmt_note, keeping whatever ua_refine_parity
-- already put there. Candidates naming the format finally chosen are dropped: after
-- a 7E1 reclassification the list still holds the 7E1 it was scored as 8N1 against,
-- and "chose 7E1 ... also fits: 7E1" is nonsense.
function sdec.ua_note_fmt(r, names, m)
  if m == nil or m < 1 then return end
  local now = sdec.ua_fmt_name(r.nbits, r.par, r.nstop)
  local keep, k = {}, 0
  local i
  for i = 1, math.min(m, 3) do
    if names[i] ~= now then k = k + 1; keep[k] = names[i] end
  end
  if k < 1 then return end
  local s = 'also fits: ' .. table.concat(keep, ' ', 1, k)
  if sdec.fmt_note == nil then sdec.fmt_note = s
  else sdec.fmt_note = sdec.fmt_note .. '; ' .. s end
end

-- Decode an arbitrary sample array. serial_core's sig_levels / sig_edges /
-- sig_idle must have run over the same array first. Returns ok, reason.
function sdec.decode_from(rd, n)
  sdec.res, sdec.fmt_note, sdec.baud_note = nil, nil, nil
  sdec.baud_probe = nil                 -- set only by giveup(), and only for THIS call
  if rd == nil or n == nil or n < 2 then return false, 'nothing captured' end
  local fs = sdec.acq_fs or sdec.fs

  -- Any failure PAST the bit-time stage must retract the bit time as well.
  --
  -- The stages run in order, so a decode that dies at the format stage has already
  -- written sdec.baud -- and the panel would show a confident "216018?" against BYTES
  -- "--", which is the same defect as H1 in a different dress: a number that looks
  -- measured when nothing was decoded. A bit time that frames nothing is not a baud
  -- rate, it is an artefact of noise.
  local function giveup(why)
    -- KEEP THE RETRACTED RATE, separately, for the one caller that can act on it. It must not be
    -- displayed -- that is the whole point of retracting it -- but autoset()'s FIRST pass runs at
    -- 1 MS/s, where a 20 000-sample window is 20 ms and holds only six bit times at 300 baud. The
    -- bit time is measurable there and a FRAME is not, so "no frame fits" from the probe is not a
    -- dead line, it is an instruction to re-capture slower. Discarding the measurement made every
    -- rate below ~1200 baud fail outright with the answer already in hand.
    sdec.baud_probe = sdec.baud
    sdec.baud, sdec.baud_raw, sdec.bittime = nil, nil, nil
    sdec.snapped, sdec.fitq = false, 0
    return false, why
  end

  -- ---- bit time ----
  local T
  if sdec.force_baud ~= nil then
    T = fs / sdec.force_baud
    sdec.bittime, sdec.fitratio, sdec.fitq = T, 1, 1
    sdec.baud, sdec.baud_raw, sdec.snapped = sdec.force_baud, sdec.force_baud, true

    -- CROSS-CHECK THE FORCED RATE AGAINST THE WIRE, because the one dangerous failure this
    -- decoder has is a forced rate the device is not using.
    --
    -- Measured, 8N1 forced to 9600, 8 seeds per point:
    --
    --     -4.5 % .. +5.0 %   byte-exact, 8/8
    --     +6 % and above     SILENTLY wrong, 8/8 -- zero framing errors, corrupted bytes
    --     -5 % and below     FLAGGED wrong, 8/8 -- framing errors raised
    --
    -- The cliff is 0.5/9.5 = 5.26 %, exactly the textbook figure: the stop bit is sampled 9.5 bit
    -- times after the start edge, so accumulated error must stay inside half a cell. The ASYMMETRY
    -- is what makes this worth a guard. Too FAST and the sampling point drifts EARLY, staying
    -- inside the previous cell, so every frame remains internally self-consistent -- nothing
    -- downstream can detect it and the panel shows confident garbage. Too SLOW and it drifts PAST
    -- the stop bit into the next start bit, which fails the stop check and is already reported.
    --
    -- So the fit is measured even though it is not used. It costs one sig_bittime() over the width
    -- array -- no per-sample work, the widths are already built -- and it is the only evidence
    -- available that the forced number is wrong. Advisory, never fatal: the operator typed that
    -- rate deliberately and may be right when the fit is not (a 5N1.5 Baudot line defeats
    -- sig_bittime structurally, which is exactly when someone types the rate in).
    sdec.rate_note = nil
    -- sig_bittime() IS NOT PURE: its first act is to nil and re-publish sdec.bittime, baud,
    -- baud_raw, fitq and snapped. Calling it as an advisory cross-check therefore OVERWRITES the
    -- forced state published two lines above with a MEASURED one, and nothing downstream knows.
    -- chunk_decode reads sdec.bittime to build fmt.T, so a streaming run decodes the whole
    -- recording at the measured rate instead of the locked one and writes the result to the USB
    -- byte log; on the frame path the panel draws the measured BAUD in the locked GREEN whose
    -- entire justification is that a forced value must not look measured.
    --
    -- So the advisory call is fenced: snapshot, call, restore unconditionally. Restoring after the
    -- pcall rather than inside it covers the raise path too.
    local keepT, keepR, keepQ = sdec.bittime, sdec.fitratio, sdec.fitq
    local keepB, keepRaw, keepSnap = sdec.baud, sdec.baud_raw, sdec.snapped
    pcall(function()
      local Tm = sdec.sig_bittime()
      if Tm == nil or Tm <= 0 then return end
      -- Only compare like with like. sig_bittime fits the greatest common period, so a fit that
      -- landed on a sub-multiple of the truth is a KNOWN artefact rather than a rate error --
      -- ratios of about 1/2, 1/3 and so on are the fit erring short, not the device running slow.
      -- Judging those as disagreement would fire the warning on most healthy captures.
      local ratio = Tm / T
      local near = nil
      local k
      for k = 1, 6 do
        if math.abs(ratio * k - 1) < 0.12 then near = k end
        if math.abs(ratio / k - 1) < 0.12 then near = k end
      end
      -- AN INTEGER RESCALING IS AMBIGUOUS, NOT INNOCENT. sig_bittime fits the greatest common
      -- period, so a ratio near 1/2 is usually the fit erring short on a healthy capture -- but it
      -- is EXACTLY what a device running at twice the forced rate looks like, and that decodes with
      -- no framing error and wrong bytes. The two cannot be told apart from the ratio, so the
      -- measurement is stated rather than the disagreement suppressed. Raised by review with a
      -- concrete repro: force 9600, transmit 0x43 at 19200, get 0x78 with zero errors.
      if near ~= nil and near > 1 then
        local other = sdec.force_baud * near
        if ratio > 1 then other = sdec.force_baud / near end
        sdec.rate_note = string.format(
          -- THE VERDICT LEADS. ui_note_px is 700 and this cell clips with an ellipsis, so a note
          -- that builds up to "WRONG" loses the only word that matters -- measured at 990 px, the
          -- operator read "...the bytes are..." and nothing after it. Front-loaded and trimmed to
          -- 699 px at the widest field values this can print (8x, 250000 against 104857).
          'WARNING: bytes may be WRONG if the device runs at %.0f baud, %dx the %g you set',
          other, near, sdec.force_baud)
        return
      end
      local err = ratio - 1
      if math.abs(err) > (sdec.ratemargin or 0.04) then
        local meas = fs / Tm
        sdec.rate_note = string.format(
          -- Same reason as the note above: verdict first, because this one clipped at 914 px and
          -- the operator read "-- bytes may be..." with the word WRONG cut off. The percentage
          -- loses its decimal to buy that room; +6 % against +6.0 % changes no decision, and
          -- "you set" stays because whose number it is IS the actionable part. 693 px worst case.
          'WARNING: bytes may be WRONG -- wire is %.0f baud, not the %g you set (%+.0f %%)',
          meas, sdec.force_baud, err * 100)
      end
    end)
    sdec.bittime, sdec.fitratio, sdec.fitq = keepT, keepR, keepQ
    sdec.baud, sdec.baud_raw, sdec.snapped = keepB, keepRaw, keepSnap
  else
    -- sig_bittime() publishes sdec.bittime and sdec.baud as it goes, so both of these
    -- failures have to retract them -- hence giveup rather than a bare return.
    local Tfit, why = sdec.sig_bittime()
    if Tfit == nil then return giveup(why or 'no bit timing') end
    local ratio, badwhy
    T, ratio, badwhy = sdec.ua_best(rd, n, Tfit)
    if T == nil then return giveup(badwhy or 'no usable bit time') end
    -- Re-measure the fit quality AT THE BIT TIME ACTUALLY CHOSEN. sig_bittime left
    -- sdec.fitq describing its own proposal, so whenever ua_best overrode that proposal
    -- the panel's FIT column reported the quality of a rejected candidate -- reading
    -- 0.95 for a bit time that explained barely half the pulse widths.
    local _, q = sdec.sig_fit(sdec.w, sdec.nw, T)
    sdec.fitq = q or 0
    sdec.bittime  = T
    sdec.fitratio = ratio
    sdec.baud_raw = fs / T
    sdec.baud, sdec.snapped = sdec.sig_snap(sdec.baud_raw)
  end
  if T == nil or T <= 0 then return giveup('no bit timing') end

  -- ---- format ----
  local r
  if sdec.force_nbits ~= nil then
    local par = sdec.force_par or sdec.PAR_NONE
    local nstop = sdec.force_nstop or 1
    local inv = sdec.force_invert
    if inv == nil then inv = (sdec.idle == 0) end
    r = sdec.ua_run(rd, n, T, sdec.force_nbits, par, nstop, inv)
    r.score  = sdec.ua_score(r)
    r.nbits  = sdec.force_nbits
    r.par    = par
    r.nstop  = nstop
    r.invert = inv
    if r.nf == 0 then return giveup('the forced format found no frames') end
  else
    r = sdec.ua_autoformat(rd, n, T)
    if r == nil then return giveup('no frame format fits the capture') end
    -- Order matters. Score the alternatives against the format the search chose;
    -- collapse always-one top data bits BEFORE testing the rest for parity, since
    -- stripping a bit changes what "the parity bit" would be; then compose one note.
    local anames, na = sdec.ua_alts(r)
    r = sdec.ua_refine_width(r, rd, n, T)
    -- rd/n/T go in because promotion to 7E1 RE-DECODES rather than shifting values, so a frame that
    -- dissents from the chosen parity becomes a real parity error instead of a clean-looking lie.
    r = sdec.ua_refine_parity(r, rd, n, T)
    sdec.ua_note_fmt(r, anames, na)
  end

  sdec.res = r
  -- Keep the reported idle level consistent with what actually decoded; the
  -- chosen polarity overrides sig_idle's longest-run prior.
  if r.invert then sdec.idle = 0 else sdec.idle = 1 end
  return true
end

-- WHEN A LOCKED RATE IS OBVIOUSLY WRONG, SAY SO RATHER THAN DEFEND IT.
--
-- Doubling the generator's rate under a 19200 lock made every frame fail, and repeated Capture
-- presses kept showing all-red: the app had no way back, and the operator had to type 0 into Options
-- to re-enable detection. A rate that explains nothing is not worth keeping.
--
-- 0.25, AND IT WAS 0.9 UNTIL THE NUMBER WAS MEASURED. "Every byte is in error" is what the panel
-- LOOKS like -- a row is painted red if any of its 16 bytes failed, so a third of frames bad reddens
-- essentially every row -- but the actual interior-bad fraction for the bench case (38400 on the wire
-- under a 19200 lock at 8.3 samples/bit) is 0.37. A 0.9 gate would never have fired on the very
-- report it was written for. Measured across mismatches: 0.34-0.50 for a wrong rate, against ~0.004
-- for a healthy capture, so a quarter separates them with room on both sides.
sdec.relock_badfrac   = 0.25     -- interior frames in error before the lock is doubted
sdec.relock_minframes = 8        -- fewer frames than this and a bad fraction is not evidence

-- WHAT HAPPENS WHEN A FORCED RATE IS PROVED WRONG -- 'ask' or 'adopt'.
--
-- 'ask' REFUSES the decode, names the rate the wire actually carries, and leaves the choice with the
-- operator: sdec.rate_accept() takes the detected rate, sdec.rate_decline() keeps theirs. 'adopt' is
-- the older behaviour -- take the detected rate and say so on the note row.
--
-- ASK IS THE DEFAULT BECAUSE A FORCED SETTING IS AN INSTRUCTION, NOT A HINT. Adopting silently puts
-- bytes on the panel decoded at a rate nobody chose, with one note line as the only trace, and the
-- whole premise of the hw-break suite is that a refusal with a reason beats confident output. Refusing
-- costs nothing here: the detected rate is already known, so it is named in the refusal rather than
-- left as a guess.
--
-- NOTHING BLOCKS ON A HUMAN. There is no modal wait -- the offer is published as state and the two
-- answers are ordinary functions, so a headless caller drives either branch and an unattended lap that
-- never answers simply stays refused.
sdec.force_conflict = sdec.force_conflict or 'ask'

-- Fraction of INTERIOR frames that failed, or nil when there are too few to judge. Interior, because
-- head resync and a clipped tail fail on healthy captures too.
function sdec.ua_badfrac(r)
  if r == nil or (r.nf or 0) < 1 then return nil end
  local ninter = r.nf - sdec.ua_edge_frames - 1
  if ninter < 1 then return nil end
  local nin = sdec.ua_bad_interior(r)
  return nin / ninter
end

-- Runs the whole chain on an already-acquired capture. serial_core.acquire()
-- leaves the levels, edges and idle level in place; this adds bit timing,
-- format and bytes. Returns ok, reason.
function sdec.decode()
  -- sdec.smp, not sdec.buf.readings: see sdec.acq_copy(). Every pass below would
  -- otherwise pay an IPC round trip per sample.
  if sdec.smp == nil then return false, 'nothing captured' end
  -- relocked IS NOT CLEARED HERE. capture() clears it once per press; clearing it per DECODE undoes
  -- that, because autoset() re-captures and decode() runs again -- erasing the note that says the
  -- operator's lock was dropped, which is the whole justification for dropping it.
  local ok, why = sdec.decode_from(sdec.smp, sdec.nread)

  -- THREE GATES, AND THE THIRD IS WHAT KEEPS A HAND-TYPED RATE SAFE. rate_note is set only when the
  -- measured bit time DISAGREES with the locked one, so a correct rate with a wrong FORMAT -- which
  -- also fails every frame -- leaves the lock alone. That case is real: a 5N1.5 line defeats
  -- sig_bittime structurally, and is exactly when someone types the rate in by hand.
  --
  -- FRAME PATH ONLY. decode_from() is also the streaming prime, and a streaming mode REFUSES without
  -- a locked rate -- unlocking inside one would strand a run that has already sized its buffer.
  if sdec.force_baud == nil or sdec.rate_note == nil then return ok, why end

  -- PLAIN UART ONLY, and both other protocols are excluded for their own reason. MIDI's 31250 is the
  -- MIDI 1.0 SPECIFICATION rather than a detection (see options_apply), so a capture that does not
  -- decode at it means the wire is not MIDI -- not that the rate is wrong. And a LIN capture is full
  -- of framing errors from its break fields by design, which would trip the bad-fraction gate on a
  -- perfectly good bus. Caught by test_serial's 'MIDI pins 31250', which this broke.
  if sdec.proto ~= nil and sdec.proto ~= 'uart' then return ok, why end
  local bf = sdec.ua_badfrac(sdec.res)
  if bf == nil or bf < sdec.relock_badfrac then return ok, why end
  if (sdec.res.nf or 0) < sdec.relock_minframes then return ok, why end

  -- Unlock and decode the SAME samples again. No restore path: the lock explained nothing, so being
  -- left unlocked is the useful outcome even if detection does no better -- the next Capture then
  -- auto-detects instead of repeating this. autolock_try() re-locks afterwards if its own five gates
  -- are satisfied, which is the same route as typing 0 into Options.
  -- THE RETRY HAS TO EARN IT, and this is the gate that keeps a CORRECT hand-typed rate safe.
  -- rate_note is not proof the RATE is wrong: its integer-multiple branch fires on healthy captures
  -- too (sig_bittime fits the greatest common period, so a ratio near 1/2 is usually the fit erring
  -- short). So a right rate with a WRONG FORCED FORMAT -- errors everywhere, plus that artefact --
  -- would otherwise have its rate thrown away and a detected one substituted. Raised by review.
  --
  -- So: unlock, re-decode, and keep the result only if it beats the threshold that triggered this.
  -- Otherwise put the operator's rate back and decode at it again -- three decodes in the failing
  -- case, which is a frame capture's cost and nothing on the streaming path.
  local was, bf0 = sdec.force_baud, bf
  sdec.force_baud = nil
  -- Or the warning about the rate we just abandoned outlives it: the no-lock branch of decode_from
  -- does not clear this.
  sdec.rate_note = nil
  local ok2, why2 = sdec.decode_from(sdec.smp, sdec.nread)
  local bf2 = sdec.ua_badfrac(sdec.res)
  if ok2 and bf2 ~= nil and bf2 < sdec.relock_badfrac and sdec.baud ~= nil then
    local found = sdec.baud
    if sdec.force_conflict == 'adopt' then
      sdec.relocked = string.format('%g baud fit nothing -- unlocked, and this capture reads %.0f',
                                    was, found)
      return ok2, why2
    end
    -- REFUSE, AND GIVE THE OPERATOR THEIR RATE BACK. This path reports a disagreement; it does not
    -- edit a setting behind them.
    sdec.force_baud = was
    -- NO BYTES ON SCREEN. res currently holds the decode that PROVED the rate wrong -- correct bytes,
    -- at a rate we are declining to use -- and showing them would be adopting by another route.
    -- A refused capture with res nil is a state the panel already handles; that is what refusal is.
    sdec.res = nil
    sdec.rate_offer, sdec.rate_offer_from = found, was
    sdec.rate_refused = string.format(
        '%g baud fits nothing -- this capture reads %.0f. Options > Baud 0 restores detection.',
        was, found)
    return false, string.format('%g baud fits nothing; this capture reads %.0f', was, found)
  end
  -- Detection did no better, so the lock was not the problem. Put it back; rate_note is re-published
  -- by the decode below and still says the wire disagrees, which is the honest state.
  sdec.force_baud = was
  sdec.relocked = nil
  return sdec.decode_from(sdec.smp, sdec.nread)
end

-- ============================================================================
-- Presentation
-- ============================================================================
-- "8N1", "7E2", ... from explicit fields, so a CANDIDATE format can be named as
-- well as the chosen one (ua_alts needs exactly that).
function sdec.ua_fmt_name(nbits, par, nstop)
  local p = 'N'
  if par == sdec.PAR_EVEN then p = 'E' end
  if par == sdec.PAR_ODD  then p = 'O' end
  return string.format('%d%s%d', nbits, p, nstop)
end

-- FALLS BACK TO THE FORCED FORMAT, so a streaming capture names the format it is decoding with.
--
-- The streaming modes produce a FILE, not an sdec.res -- so every cell derived from res read '--'
-- during a run. That is right for the measured cells (nothing has been fitted) and wrong for the
-- forced ones: a streaming mode cannot even be ENTERED without a locked rate, so the format is
-- the one thing about a stream that is certain. Showing '--' for the two values the operator
-- pinned themselves, while the app is actively using them, is the panel disclaiming knowledge it
-- has.
function sdec.fmt_text()
  local r = sdec.res
  if r ~= nil then return sdec.ua_fmt_name(r.nbits, r.par, r.nstop) end
  if sdec.force_nbits ~= nil then
    return sdec.ua_fmt_name(sdec.force_nbits, sdec.force_par or sdec.PAR_NONE,
                            sdec.force_nstop or 1)
  end
  return '--'
end

-- The baud rate as the panel shows it, falling back to a forced value.
function sdec.baud_text()
  -- Same fallback as fmt_text(): a locked rate is knowledge, and a stream has one by definition.
  -- %.0f because a locked rate came from a MEASUREMENT and is fractional -- see the note in
  -- serial_ui.tsp's mode_why. Identical characters on 5.0.2, and no longer untestable off the box.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    return string.format('%.0f baud', sdec.force_baud)
  end
  if sdec.baud == nil then return '--' end
  -- %.0f here too: `snapped` is true for any FORCED rate (see decode_from), not only for one
  -- sig_snap matched, so this branch is not guaranteed a standard-rate integer by itself.
  if sdec.snapped then return string.format('%.0f baud', sdec.baud) end
  return string.format('%.0f baud?', sdec.baud)
end

-- One printable character per byte; '.' for control and high-bit values so the
-- column grid never shifts, '?' for a frame that failed its stop or parity bit.
function sdec.ua_char(v, err)
  if err ~= nil then return '?' end
  if v == nil then return ' ' end
  if v >= 32 and v <= 126 then return string.char(v) end
  return '.'
end

-- The three summary lines, split so each fits the width: what the protocol is,
-- what the wire looks like, and how well it went.
function sdec.summary(i)
  local r = sdec.res

  if i == 1 then
    if r == nil then return sdec.baud_text() end
    local idle = 'HIGH'
    if r.invert then idle = 'LOW' end
    return string.format('%s  %s  idle %s', sdec.baud_text(), sdec.fmt_text(), idle)
  end

  if i == 2 then
    if sdec.lo == nil then return 'no signal' end
    local spb = ''
    if sdec.bittime ~= nil then
      spb = string.format('  %.1f sa/bit', sdec.bittime)
    end
    return string.format('%s  %.2f/%.2f V  thr %.2f V%s',
                         sdec.family, sdec.lo, sdec.hi, sdec.thr, spb)
  end

  if i == 3 then
    if r == nil then return '0 bytes' end
    local fs = sdec.acq_fs or sdec.fs
    return string.format('%d bytes  %d err  fit %.2f  %.0f kS/s',
                         r.nf, r.nbad, sdec.fitq, fs / 1000)
  end

  return ''
end

-- A row of the ASCII view: ncol characters starting at byte i0 (1-based).
function sdec.ua_text_line(i0, ncol)
  local r = sdec.res
  if r == nil then return '' end
  local t, m = {}, 0
  local i
  for i = i0, i0 + ncol - 1 do
    if i > r.nf then break end
    m = m + 1
    t[m] = sdec.ua_char(r.vals[i], r.errs[i])
  end
  return table.concat(t)
end

-- A row of the hex view: "0000  48 65 6C 6C ...  |Hell...|".
--
-- Hex and characters on the same row, deliberately: the text says what the device
-- is saying, the hex says what the bytes are, and they disagree exactly where it
-- matters (control codes, high bytes, a byte that looks like a space but is 0xA0).
--
-- Short rows are padded so the last row's ASCII gutter stays aligned. The offset
-- is decimal, matching the "bytes 1-97 of 97" status line, since these are stream
-- positions rather than addresses. An unrecoverable value shows as '--'.
-- Split from ua_hex_line so the chunked decoder can format rows from a WINDOW's own
-- arrays -- which are not sdec.res and carry a stream offset the panel never needs.
-- One formatter, so the file a long stream produces is byte-for-byte the same shape
-- as the panel's view and the log's dump.

-- TWO GROUPS OF EIGHT, WITH A GAP -- because the panel's font is PROPORTIONAL.
--
-- FONT_SMALL is not a fixed-pitch face: hex digits measure ~7.47 px against ~8 for a digit
-- column, so a 16-byte row's characters drift relative to any grid as the row is read, and by
-- the far end a byte is most of a character-width away from where the eye expects it. Nothing
-- here can fix that -- the firmware offers no monospace font -- but the drift is CUMULATIVE,
-- so breaking the row into two eight-byte groups halves the worst case, and the gap gives the
-- eye a hard restart point in the middle instead of one 47-character run to track across.
--
-- Eight is also the natural group for the job: a byte offset within a row becomes "left half
-- or right half, then count at most eight", which is how anyone reads a hex dump anyway.
--
-- Both formatters group identically. A log file whose rows do not match the panel's rows is a
-- file you cannot check the panel against, which is most of what the dump is for.
sdec.ua_hexgroup = 8         -- bytes per group; 0 disables grouping
sdec.ua_hexgap   = 2         -- EXTRA spaces at a group boundary, on top of the normal one

-- Join formatted cells, widening the separator at each group boundary. `sep` is '' for the
-- file form, whose cells carry their own leading space, and ' ' for the screen form.
function sdec.ua_hexjoin(cells, m, sep)
  local grp = sdec.ua_hexgroup or 0
  local extra = sdec.ua_hexgap or 0
  local wide = sep .. string.rep(' ', extra)
  local out, k, i = {}, 0, 0
  for i = 1, m do
    if i > 1 then
      k = k + 1
      if grp > 0 and extra > 0 and math.mod(i - 1, grp) == 0 then out[k] = wide
      else out[k] = sep end
    end
    k = k + 1
    out[k] = cells[i]
  end
  return table.concat(out)
end

-- Width in characters of the joined hex block, so the layout derives its columns instead of
-- carrying a literal that a change to the grouping would silently invalidate.
-- Width in characters of ONE hex group of `ncol` bytes: two chars each plus a single separator
-- between. The gap between the two groups is now LAYOUT (sdec.ui_col_gap2), not spaces, so no
-- group-gap term appears here.
function sdec.ua_hexwidth(ncol)
  local grp = sdec.ua_hexgroup or 0
  local extra = sdec.ua_hexgap or 0
  local w = ncol * 3 - 1                     -- 2 chars per byte + 1 separator between
  if grp > 0 and extra > 0 and ncol > 1 then
    w = w + extra * math.floor((ncol - 1) / grp)
  end
  return w
end

-- One hex+ASCII row as a single string, for a file or the debug log.
function sdec.ua_hexrow(vals, errs, nf, i0, ncol, base)
  if base == nil then base = 0 end
  local hx, as = {}, {}
  local i, m = 0, 0
  for i = i0, i0 + ncol - 1 do
    m = m + 1
    if i > nf then
      hx[m] = '   '
      as[m] = ' '
    else
      local v = vals[i]
      if v == nil then hx[m] = ' --' else hx[m] = string.format(' %02X', v) end
      as[m] = sdec.ua_char(v, errs[i])
    end
  end
  return string.format('%04d %s  |%s|', base + i0 - 1, sdec.ua_hexjoin(hx, m, ''),
                       table.concat(as))
end

-- THE SAME ROW, AS THREE PIECES, for the on-screen dump's three fixed-x text fields.
--
-- Separate from ua_hexrow rather than built on it, because the two have genuinely different
-- requirements and merging them would compromise both. The FILE form keeps its '|ascii|'
-- delimiters: a log line has to be readable and parseable on its own, where the pipes are the
-- only thing marking the ASCII field. The SCREEN form drops them, because vertical rule objects
-- do that job at a fixed x -- and a '|' inside the string cannot, since it sits wherever the
-- preceding hex happened to render.
--
-- The hex block also loses ua_hexrow's leading space. There it separates the offset from the
-- data inside one string; here the offset is a different object and the space would just push
-- the block off its own column by one character.
function sdec.ua_hexparts(vals, errs, nf, i0, ncol, base)
  if base == nil then base = 0 end
  local hx, as = {}, {}
  local i, m = 0, 0
  for i = i0, i0 + ncol - 1 do
    m = m + 1
    if i > nf then
      hx[m] = '  '
      as[m] = ' '
    else
      local v = vals[i]
      if v == nil then hx[m] = '--' else hx[m] = string.format('%02X', v) end
      as[m] = sdec.ua_char(v, errs[i])
    end
  end
  -- TWO characters per entry joined by a separator, NOT '%02X ' with a trailing space. The
  -- trailing version is one character wider than the field it lives in -- 48 rather than 47 --
  -- and since the vertical rule's x is computed from ui_hxn * ui_ch_w, that one space closed the
  -- gap to exactly 0 px and the last byte rendered on top of the rule. Visible in the mockup as
  -- '...33 35' touching the divider, and easy to mistake for a font-metric problem rather than
  -- an off-by-one in the string. A field with no trailing padding cannot drift that way.
  --
  -- FOUR PIECES, NOT THREE: offset, first eight bytes, second eight bytes, ASCII.
  --
  -- The two hex groups are separate strings because they are separate DISPLAY OBJECTS at fixed x.
  -- Putting all sixteen in one string and spacing the groups apart inside it does not work on this
  -- panel: FONT_SMALL is proportional, so where the second group starts depends on the rendered
  -- width of the first eight bytes, which varies with the digits in them. '00 00 ...' and
  -- 'FF FF ...' are different widths, so the second column wandered row by row. Two objects at
  -- fixed x cannot wander.
  --
  -- The ASCII field is NOT split to match. Its job is to be read as text, and a gap in the middle
  -- of a string breaks words for a column correspondence the proportional font cannot deliver.
  local half = math.floor(m / 2)
  local a, b, k = {}, {}, 0
  for k = 1, m do
    if k <= half then a[k] = hx[k] else b[k - half] = hx[k] end
  end
  return string.format('%04d', base + i0 - 1),
         table.concat(a, ' '), table.concat(b, ' '), table.concat(as)
end

-- THE OFFSET COLUMN IS ABSOLUTE, which for a frame capture is the same as relative and for a
-- STREAM TAIL is not. A retained tail may begin at byte 32 049 of the run, and labelling its
-- first row 0000 makes the panel disagree with the file the same run just wrote -- the one place
-- an operator would go to check it. res.first is the tail's 1-based absolute start; a frame
-- result has no `first`, so the base falls back to 0 and nothing about frame mode changes.
function sdec.ua_base(r)
  if r == nil or r.first == nil then return 0 end
  return r.first - 1
end

-- One row of the current result as four pieces, for the panel's four fixed columns.
function sdec.ua_hex_parts_line(i0, ncol)
  local r = sdec.res
  if r == nil or i0 > r.nf then return '', '', '', '' end
  return sdec.ua_hexparts(r.vals, r.errs, r.nf, i0, ncol, sdec.ua_base(r))
end

-- One row of the current result as a single string.
function sdec.ua_hex_line(i0, ncol)
  local r = sdec.res
  if r == nil or i0 > r.nf then return '' end
  return sdec.ua_hexrow(r.vals, r.errs, r.nf, i0, ncol, sdec.ua_base(r))
end

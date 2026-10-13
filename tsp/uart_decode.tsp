-- uart_decode.tsp -- asynchronous serial (UART) framing for the Keithley TSP serial decoder
-- (Lua 5.0.2).
--
-- Works from what serial_core.tsp produced: threshold, edge list, bit time. It never scans the
-- samples linearly, sampling ~14 computed positions per frame, so decode cost scales with BYTES
-- rather than capture length -- which is what makes a brute-force format search affordable.
--
-- Brute force is right because a UART line carries no clock and no framing metadata: width, parity
-- and stop bits are not derivable in closed form, but they are strongly constrained. A wrong guess
-- puts the stop-bit sampling point on a data bit, which reads as space about half the time and raises
-- a framing error, so decoding under every plausible format and keeping the fewest-error result
-- recovers the format from the data. By default 2 widths x 3 parities x 2 polarities = 12 decodes.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.PAR_NONE = 0
sdec.PAR_EVEN = 1
sdec.PAR_ODD  = 2

-- Search order is also the tie-break order, so the commonest bench format wins when two explain the
-- capture equally well.
--
-- Only 7 and 8 are searched by default. A wider frame launders the evidence of damage, so the error
-- count can FALL as the answer gets worse and every byte comes out 256 too large.
-- docs/MEASUREMENTS.md, 'Why only 7 and 8 data bits are searched by default'.
--
-- With "any width" selected, 5 and 6 are searched but heavily biased against (sdec.rarewidth), and
-- ua_refine_width still walks DOWN from a common width on positive evidence -- so a rare width is
-- reached when the capture proves it, not when a score happens to favour it.
--
-- 9 is never searched in either setting and is reachable only by forcing Data Bits = 9: the bias is
-- inert exactly when a laundering width can win. docs/MEASUREMENTS.md, 'Why 9 data bits is never
-- searched, even biased'. Treated the way nstop is -- not observable from the wire, so not guessed,
-- but honoured when given.
sdec.try_nbits     = {8, 7}              -- the default: the two widths that actually occur
sdec.try_nbits_all = {8, 7, 6, 5}        -- with "Auto (any width)"; 9 is forced-only, see above
sdec.try_par       = {0, 1, 2}

-- Explicit nil test rather than `or`: `or false` works but reads as a bug beside the booleans that
-- need the test.
if sdec.widths_any == nil then sdec.widths_any = false end

-- The width list in force. Everything that searches widths goes through here.
function sdec.ua_widths()
  if sdec.force_nbits ~= nil then return {sdec.force_nbits} end
  if sdec.widths_any then return sdec.try_nbits_all end
  return sdec.try_nbits
end

-- A forced field constrains the search rather than sitting in a variable. decode_from()'s
-- forced-format shortcut runs only when the WIDTH is forced, so these narrow the candidate list
-- instead, which leaves every scoring and margin rule below unchanged -- a one-entry list has nothing
-- to lose to.
function sdec.ua_parities()
  if sdec.force_par ~= nil then return {sdec.force_par} end
  return sdec.try_par
end

function sdec.ua_stops()
  if sdec.force_nstop ~= nil then return {sdec.force_nstop} end
  return sdec.try_stop
end

-- One stop bit is searched, which is a conclusion and not a simplification: the count is not
-- observable from the wire. A second stop bit is indistinguishable from a bit time of idle, which the
-- decoder already tolerates, so nstop = 2 can never rescue a capture nstop = 1 fails on. ua_frame()
-- still honours nstop so it can be forced.
--
-- 1.5 stop bits defeats sig_bittime rather than the frame layer, and is left unfixed: the remedy is
-- the Baud Rate field, and the failure is flagged rather than silent. docs/MEASUREMENTS.md,
-- '1.5 stop bits'.
sdec.try_stop  = {1}

-- Candidate bit-time rescalings for ua_best(), ordered by distance from 1, so the pulse-width fit is
-- trusted unless a rescaling decodes measurably better. Asymmetric on purpose, because the two error
-- directions are not equally likely: docs/MEASUREMENTS.md, 'Why sdec.ratios is asymmetric'.
sdec.ratios      = {1, 0.5, 2, 0.3333333333, 3, 0.25, 4, 0.2, 5, 0.1666666667, 6, 8, 10}
sdec.probe_nbits = {8, 7, 5}

-- How far a forced rate may disagree with the wire before the panel says so. Just inside the measured
-- 5.26 % cliff, so it warns before corruption starts rather than after. docs/MEASUREMENTS.md,
-- 'ratemargin = 0.04'.
sdec.ratemargin = sdec.ratemargin or 0.04

-- How close to the best pulse-width consistency a candidate bit time must come to stay in the
-- running. Relative, so it needs no tuning against a noise level. The second, independent piece of
-- evidence, and the only thing that breaks a frame-count alias: docs/MEASUREMENTS.md, 'qgate = 0.8'.
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
-- majority-voted rather than one sampled; docs/MEASUREMENTS.md, 'Three-tap majority sampling'.
-- Returns 0, 1, or nil when the position falls outside the capture.
function sdec.ua_bit(rd, n, x, invert, T)
  local thr = sdec.thr
  local floor = math.floor

  -- Centre tap first and unconditionally: its absence is what defines a truncated frame. If outer
  -- taps could stand in, a frame running off the end would fabricate a trailing byte.
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
  -- A tie, which only happens with an outer tap off the end, falls to the centre tap.
  if ones * 2 > votes then b = 1
  elseif ones * 2 < votes then b = 0
  elseif vc >= thr then b = 1
  else b = 0 end

  if invert then b = 1 - b end
  return b
end

-- Set bits in v, there being no bitwise operators in 5.0.2. Table over the 9-bit domain, built on
-- first use; the loop is kept for anything wider. docs/MEASUREMENTS.md, 'ua_popcount's lookup table'.
sdec.ua_pc = nil
function sdec.ua_popcount(v)
  local t = sdec.ua_pc
  if t == nil then
    t = {}
    local floor = math.floor
    local i = 0
    while i < 512 do
      local ones, x = 0, i
      while x > 0 do
        local h = x * 0.5
        local f = floor(h)
        if h ~= f then ones = ones + 1 end
        x = f
      end
      t[i] = ones
      i = i + 1
    end
    sdec.ua_pc = t
  end
  local c = t[v]
  if c ~= nil then return c end
  local ones, x = 0, v
  local floor = math.floor
  while x > 0 do
    local h = x * 0.5
    local f = floor(h)
    if h ~= f then ones = ones + 1 end
    x = f
  end
  return ones
end

-- ============================================================================
-- One frame
-- ============================================================================
-- Decode the frame whose start-bit leading edge sits at fractional sample t0. Bit cell k spans
-- [t0 + k*T, t0 + (k+1)*T), k = 0 the start bit; data is LSB first.
--
-- Returns value, err -- nil on success, else 'start', 'parity', 'framing' or 'truncated'. A parity or
-- framing failure still returns the value: a byte with a bad stop bit is usually the right byte at
-- the wrong baud rate.
--
-- The sampling is ua_bit written out inline, expression for expression, because a call costs about as
-- much as the sampling it wraps. docs/MEASUREMENTS.md, 'Three-tap majority sampling'.
function sdec.ua_frame(rd, n, t0, T, nbits, par, nstop, invert)
  local thr = sdec.thr
  local floor = math.floor
  local three, off = false, 0
  if T ~= nil and T >= 6 then
    three = true
    off = 0.2 * T
  end

  local pslot = -1
  if par ~= sdec.PAR_NONE then pslot = nbits + 1 end
  local last = nbits + nstop
  if pslot > 0 then last = last + 1 end

  local val, bv = 0, 1
  local slot

  -- Folded into the two bit values rather than tested per slot: `invert` is fixed before the loop.
  local hib, lob = 1, 0
  if invert then hib, lob = 0, 1 end

  for slot = 0, last do
    local x = t0 + (slot + 0.5) * T
    local ic = floor(x + 0.5)
    if ic < 1 or ic > n then return nil, 'truncated' end
    local vc = rd[ic]
    if vc == nil then return nil, 'truncated' end

    local b
    if three then
      -- Two taps that agree settle a majority of three, so the third is not read.
      local cb = 0
      if vc >= thr then cb = 1 end
      local ones, votes = cb, 1
      local settled = false
      local i = floor(x - off + 0.5)
      if i >= 1 and i <= n then
        local v = rd[i]
        if v ~= nil then
          votes = 2
          if v >= thr then
            ones = ones + 1
            if cb == 1 then settled = true end
          elseif cb == 0 then settled = true end
        end
      end
      if not settled then
        i = floor(x + off + 0.5)
        if i >= 1 and i <= n then
          local v = rd[i]
          if v ~= nil then
            votes = votes + 1
            if v >= thr then ones = ones + 1 end
          end
        end
      end
      if ones * 2 > votes then b = hib
      elseif ones * 2 < votes then b = lob
      elseif vc >= thr then b = hib
      else b = lob end
    elseif vc >= thr then b = hib
    else b = lob end

    if slot == 0 then
      if b ~= 0 then return nil, 'start' end
    elseif slot <= nbits then
      if b == 1 then val = val + bv end
      bv = bv * 2
    elseif slot == pslot then
      local pe = math.mod(sdec.ua_popcount(val), 2)
      local want
      if par == sdec.PAR_EVEN then want = pe else want = 1 - pe end
      if b ~= want then return val, 'parity' end
    else
      if b ~= 1 then return val, 'framing' end
    end
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

  -- The anchor has to be inside `n`, and the bound is `n` rather than "room for a whole frame".
  -- docs/MEASUREMENTS.md, 'Why the anchor search is bounded by `n`'. Inert for every caller that
  -- passes the whole capture, since sig_edges only records edges inside it. Only the 1.5-bit search is
  -- bounded: the fallback takes the first candidate edge and ei ascends, so bounding it would trade
  -- nf = 0 for nf = 0.
  local anchor = nil
  if tmin0 == nil then
    for k = 1, ne do
      if es[k] == want and ei[k] <= n then
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
    -- Resuming: the caller knows the phase, and re-deriving it is worse than trusting it. On a
    -- gapless stream the search above falls through to the first candidate edge, which inside a byte
    -- is a data transition, and every frame after it decodes misaligned.
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
  local prev = nil          -- t0 of the previous emitted frame, for the idle test below
  -- Numeric for, not a while: the VM folds the increment and bound into one FORLOOP opcode, and the
  -- walk never alters its own index.
  for k = anchor, ne do
    if es[k] == want and ei[k] >= tmin then
      local t0 = ei[k]
      local val, err = sdec.ua_frame(rd, n, t0, T, nbits, par, nstop, invert)
      if err == 'truncated' then break end

      -- A failed start bit is a false trigger, not a corrupt byte, usually an impulse on an idle
      -- line. Counting it would leak the spike count into the error count the format search scores
      -- on, so impulse noise could tip the search. Skipping also leaves tmin alone.
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

      -- A pitch of two frame times or more is a message boundary, from which the framer is anchored
      -- correctly whatever it did earlier. Only the first bounds the region a mid-byte start corrupts.
      if r.idle1 == nil and prev ~= nil and (t0 - prev) >= 2 * framebits * T then
        r.idle1 = nf
      end
      prev = t0

      end
    end
  end

  -- A capture that began mid-byte corrupts the frames before the first idle and nothing after it
  -- (docs/MEASUREMENTS.md, 'A capture that began mid-byte'). Marked on evidence -- errors confined to
  -- the head -- so a capture that began at a message boundary marks nothing.
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
-- Errors are weighted heavily against, the premise being that a wrong format shows up as framing
-- errors: 40 bytes with 12 errors is not a better description than 30 with none.

-- Framing errors at the capture boundary are not signal errors, so the head frames and the last
-- frame are excluded. docs/MEASUREMENTS.md, 'ua_edge_frames = 3'.
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

-- How far a misaligned head reaches: the last flagged frame inside headsusp, or 0. headsusp is the
-- region before the first gap, not a count of damage, so quoting it over-claims. `hs` overrides
-- r.headsusp, because a recording's tail result carries none.
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

-- Bytes you cannot trust, not frames that failed a check: in a misaligned head the bit boundaries are
-- wrong, so a frame can pass parity and stop by luck and hand back a plausible wrong byte. An
-- identified head counts in full and the resync exclusion is dropped across it, that exclusion being
-- for a healthy gapless line. The final frame stays excluded. With no head this is ua_bad_interior.
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

-- How much better a rival format must score to displace the incumbent. Proportional, a rival having
-- to win by >60 %, which turns the search order into a commonality prior and is scale-free.
-- docs/MEASUREMENTS.md, "ua_margin: why a plain '>' is wrong".
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
-- docs/MEASUREMENTS.md, 'rarewidth = 8'. What makes the bias safe rather than lossy is
-- ua_refine_width, which walks back down to the rare widths on positive evidence -- top data bits
-- that are 1 in every frame -- instead of on a score a tiling artefact can win.
sdec.rarewidth = 8

-- Extra margin a polarity flip must clear when the idle prior came from the signalling standard
-- rather than a run length. docs/MEASUREMENTS.md, 'polmargin = 4, and the inverted-ASCII trap'.
sdec.polmargin = 4

-- The bias multiplies the proportional term only, never the floor, so it grows with how much
-- evidence the incumbent has. docs/MEASUREMENTS.md, 'rarewidth = 8'.
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
          -- The rival's width sets the extra margin, not the incumbent's.
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

  -- The prior polarity goes first and keeps the decision unless the other wins by the frame-shape
  -- margin. A raw comparison fails because the frame-count bias arrives by the back door: the losing
  -- polarity can win its own search with a shorter frame that finds more frames -- on repeated 0x55
  -- the inverted 6N1 scores 11 against the correct 8N1's 10, flipping polarity and width at once.
  --
  -- A forced polarity ends the contest rather than entering it, otherwise a forced setting gets
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
    -- How hard the prior is to overturn depends on where it came from: with no idle in the capture
    -- the prior is the signalling standard rather than an observation, so the rival needs ~3.4x
    -- instead of 1.6x. docs/MEASUREMENTS.md, 'polmargin = 4, and the inverted-ASCII trap'.
    local m = sdec.ua_margin(ra.score)
    if sdec.idle_weak then m = m * sdec.polmargin end
    if rb.score > ra.score + m then best = rb end
  end
  return best
end

-- Whether a candidate bit time could describe this capture at all. Floor sdec.minsabit, ceiling
-- sdec.maxbaud, both in serial_core.tsp. docs/MEASUREMENTS.md, 'minsabit, and why the floor exists at
-- all' and 'plaustol = 0.02, on both ends'.
sdec.plaustol = 0.02

-- Is this bit time inside the samples-per-bit range the instrument can actually carry?
function sdec.ua_plausible(T, n)
  if T == nil then return false end
  if T < sdec.minsabit * (1 - sdec.plaustol) then return false end
  if T > n / 8 then return false end               -- no room for even one frame
  -- A candidate longer than the median pulse claims most pulses are shorter than a single bit, which
  -- rules out the long rescalings a damaged capture rewards. docs/MEASUREMENTS.md, 'The median-pulse
  -- ceiling'.
  if sdec.wmed ~= nil and sdec.wmed > 0 and T > 1.15 * sdec.wmed then return false end
  local fs = sdec.acq_fs or sdec.fs
  local b = fs / T
  -- Both ends carry plaustol: a limit a rounding error can cross is not a limit.
  return b >= sdec.minbaud * (1 - sdec.plaustol)
     and b <= sdec.maxbaud * (1 + sdec.plaustol)
end

-- Is this candidate bit time a SUB-MULTIPLE of the one that generated the pulses? The mirror of
-- ua_plausible's too-long test. A prior on real traffic rather than a structural proof, and it gates
-- candidates only, never the fit, so a corrupt fit can still be rescaled.
-- docs/MEASUREMENTS.md, 'ua_submultiple: the odd-multiple test'.
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

-- Does this candidate claim the shortest pulse on the wire is several bit times long? Covers the odd
-- divisors ua_submultiple structurally cannot. The 5th percentile, not the minimum, because one
-- 2-sample notch would silence it. docs/MEASUREMENTS.md, 'ua_minrun_absurd = 2.5'.
--
-- Gates CANDIDATES only, never the fit, and only behind snap1 -- see ua_best_probe.
sdec.submult_maxrunlo = sdec.submult_maxrunlo or 2.5

function sdec.ua_minrun_absurd(T)
  if T == nil or T <= 0 then return false end
  if (sdec.nw or 0) < sdec.submult_minpulses then return false end
  local lo = sdec.wshort
  if lo == nil or lo <= 0 then return false end
  return lo / T > sdec.submult_maxrunlo
end

-- Whether the fit is consistent with the pulse-width distribution it came from, which separates "the
-- line is faster than this instrument" from "impulse noise captured the fit".
-- docs/MEASUREMENTS.md, 'ua_fit_corrupt: med/Tfit separates two faults'.
function sdec.ua_fit_corrupt(Tfit)
  local med = sdec.wmed
  if med == nil or med <= 0 or Tfit == nil or Tfit <= 0 then return true end
  return med > 2.5 * Tfit
end

-- Why no bit time was usable, in the operator's terms. "Too fast for this sample
-- rate" and "nothing resembling a frame" are different faults with different actions
-- -- lower the baud rate, versus check the probe.
-- Every limit named here is the one ua_plausible refused with, constant for constant. A sentence
-- built from a different threshold blames a limit that did not fire.
function sdec.ua_implausible_why(T)
  if T == nil or T <= 0 then return 'no bit timing' end
  local fs = sdec.acq_fs or sdec.fs
  if fs == nil or fs <= 0 then return 'no sample rate' end
  local b = fs / T
  -- Ceiling before the samples-per-bit floor, and in baud, because the two coincide at one sample
  -- rate: the top of sdec.rates over minsabit is maxbaud. Checked second, the floor swallows every
  -- case and the ceiling sentence can never print.
  if b > sdec.maxbaud * (1 + sdec.plaustol) then
    return string.format('%.0f baud is past the %d kBd ceiling', b or 0, sdec.maxbaud / 1000)
  end
  -- Past the check above, too few samples per bit is the capture rate and not the ceiling: 3.5
  -- samples/bit at 20 kSa/s is 5714 baud, nowhere near maxbaud.
  if T < sdec.minsabit * (1 - sdec.plaustol) then
    return string.format('%.1f samples/bit -- %.0f baud needs a faster capture than %.0f kSa/s',
                         T or 0, b or 0, fs / 1000)
  end
  -- The floor needs its own sentence, or a rate below it falls through to 'no frame fits' -- false,
  -- since forcing that same rate frames every byte.
  if b < sdec.minbaud * (1 - sdec.plaustol) then
    return string.format('%.0f baud is below the %d baud floor', b or 0, sdec.minbaud or 0)
  end
  return string.format('no frame fits a %.1f sample bit time', T or 0)
end

-- Bit times worth scoring: the fit rescaled by sdec.ratios, plus median-derived candidates for the
-- failure mode the ladder cannot cover. docs/MEASUREMENTS.md, 'Why ua_cands adds median-derived
-- candidates'.
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
      -- Skip what the ladder covers, so near-duplicates do not crowd out the tie-break order.
      if T < 0.97 * Tfit or T > 1.03 * Tfit then
        m = m + 1
        c[m] = {T = T, r = T / Tfit}
      end
    end
  end
  return c, m
end

-- Choose the bit time by decode quality rather than pulse statistics alone: framing is a far stronger
-- constraint, since a wrong bit time puts the stop sample on a data bit.
-- docs/MEASUREMENTS.md, 'Why the rescaling search is gated'.
--
-- Parity is included in the probe: without it 8E1 traffic scores negative at every candidate, its
-- parity bit reading as a bad stop bit, and the search wanders off to a nonsense rescaling.

-- How many samples a probe may look at; nil = all of them. The search's cost knob, and the search is
-- the app's worst latency offender. Only the ranking is truncated -- the final decode runs over
-- everything. docs/MEASUREMENTS.md, 'ua_probe_n = 4000', which also has the sweep to re-run
-- (SDEC_PROBE_N=N lua tools/stress_serial.lua) before changing this. The failure mode of too small a
-- value is a quietly worse answer, not a crash.
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
          -- failing or merely finding fewer frames.
          if sc == nil or s > sc then sc, scbad, scgood = s, r.nbad, r.ngood end
        end
      end
    end
  end
  return sc, scbad, scgood
end

-- Returns bittime, ratio. The rescaling search is gated, not unconditional: the width fit is trusted
-- whenever it snaps to a standard rate and frames something, otherwise the snapped rescalings are
-- searched. A fit too short to frame anything scores at or below zero.
-- docs/MEASUREMENTS.md, 'Why the rescaling search is gated' and 'The same waveform at two rates'.
-- Trusting the fit silently would be wrong, so an equally-snapping rescaling that explains materially
-- more of the capture is reported in sdec.baud_note.
--
-- Split into three so the expensive middle can be served a slice at a time:
--   ua_best_begin  prologue, the cheap width pass, and a probe of the fit itself
--   ua_best_probe  scores ONE candidate -- the expensive unit
--   ua_best_end    the decision logic over whatever the probes found
--
-- ua_best() is begin + probe-every-candidate + end, so every caller is unchanged and the suites judge
-- the split. The state table `st` holds what the three share, as one table rather than a dozen
-- returns, because the 200-active-locals ceiling is real here.
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
     -- BOTH SUB-MULTIPLE TESTS, and the snap1 gate is what makes the pair safe: in the 0xE0 case the
     -- fit does not snap, so neither is consulted and the 1/6 truth is still reachable.
     and not (st.snap1 and (sdec.ua_submultiple(T) or sdec.ua_minrun_absurd(T))) then
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
          tostring(ab), tostring((sdec.sig_snap(fs / Tfit))), altsc or 0, sc1 or 0, bad1 or 0)
        return altT, altr
      end
      -- "score", not "frames": these come from ua_score = ngood - 3*nbad, so a
      -- decode with errors scores below its frame count and the two can be
      -- misordered relative to the frames actually found.
      sdec.baud_note = string.format('%s baud also fits this waveform (score %d vs %d)',
                                     tostring(ab), altsc or 0, sc1 or 0)
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
  -- ONE TICK PER CANDIDATE, because the candidate is this loop's atom and the only boundary inside
  -- the decode that carries no state: ua_best_probe checkpoints into st, so a caller that runs
  -- between two probes cannot land anywhere awkward. A candidate is ~76 ms at 38400 baud, which is
  -- the granularity a liveness indicator needs. sdec.tick is nil in the shipped app, so the cost is
  -- one nil compare per candidate.
  while sdec.ua_best_probe(st) do
    if sdec.tick ~= nil then sdec.tick() end
  end
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
                              want - 1, want - 1, r.nstop or 0)
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
                                tostring(sdec.ua_fmt_name(r.nbits, r.par, r.nstop)),
                                tostring(sdec.ua_fmt_name(want, r.par, r.nstop)), dropped or 0)
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
  local i1 = r.nf - sdec.par_skiptail
  -- headsusp IS THE REGION BEFORE THE FIRST GAP, NOT A COUNT OF DAMAGE (see ua_head_bad), so on a
  -- GAPLESS stream there is no gap to end it and it reaches almost the whole capture: measured on v78
  -- at 348 and 630 Bd, headsusp claims 130 of 136 and 120 of 122 frames while ngood is 135 and 121 --
  -- one frame in error. Excluding all of that leaves nvote 5 and 1, which then fails par_minvote_all
  -- and ndist, so the promotion never runs and a 7E1 waveform is reported as 8N1 with every byte
  -- carrying a spurious bit 7.
  --
  -- A gapless stream has ONE alignment for the whole run, so if the frames decode without error the
  -- alignment is self-consistent and the only open question is 8N1 versus 7E1 -- which is exactly what
  -- this vote settles. So headsusp is honoured only while it leaves a usable vote; where it would
  -- starve one it carries no information and the MEASURED damage bounds the head instead.
  if r.headsusp ~= nil and r.headsusp + 1 > i0 then
    local hs = r.headsusp + 1
    if i1 - hs + 1 >= sdec.par_minvote_all then
      i0 = hs
    else
      local hb = sdec.ua_head_bad(r) + 1
      if hb > i0 then i0 = hb end
    end
  end

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
      tostring(string.upper(string.sub(pname, 1, 1))), tostring(pname), nagree or 0, nvote or 0)

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
    sdec.snapped, sdec.fitq, sdec.snapfirm = false, 0, true
    return false, why
  end

  -- ---- bit time ----
  local T
  if sdec.force_baud ~= nil then
    T = fs / sdec.force_baud
    sdec.bittime, sdec.fitratio, sdec.fitq = T, 1, 1
    -- snapfirm TRUE alongside snapped: what is published here is exactly the rate that is locked, so
  -- nothing has been rounded away from a measurement and the '?' would be about nothing. A stale
  -- false retained from an earlier soft snap would print 'auto-locked 37700 baud?'.
  sdec.baud, sdec.baud_raw, sdec.snapped, sdec.snapfirm = sdec.force_baud, sdec.force_baud, true, true

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
    -- So the advisory call is fenced: snapshot, call, restore unconditionally.
    --
    -- A LOCAL FUNCTION RATHER THAN AN INLINE BLOCK, and not a pcall: the body has two early
    -- returns -- "no measurement" and "an integer rescaling, stated" -- and inlining them would
    -- return out of decode_from() and skip the restore below, which is the one thing the fence is
    -- for. Nothing in it reaches the instrument; sig_bittime() is called bare in the unforced
    -- branch of this same function, so a guard here would be a guard around our own arithmetic.
    local keepT, keepR, keepQ = sdec.bittime, sdec.fitratio, sdec.fitq
    -- snapfirm IS PART OF THE FENCE. sig_bittime publishes it alongside baud and snapped, so leaving it
    -- out of the snapshot lets an ADVISORY measurement add or remove a forced rate's '?' -- the same
    -- overwrite this fence exists to prevent for the other three.
    local keepB, keepRaw, keepSnap = sdec.baud, sdec.baud_raw, sdec.snapped
    local keepFirm = sdec.snapfirm
    local function ratenote()
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
    end
    ratenote()
    sdec.bittime, sdec.fitratio, sdec.fitq = keepT, keepR, keepQ
    sdec.baud, sdec.baud_raw, sdec.snapped = keepB, keepRaw, keepSnap
    sdec.snapfirm = keepFirm
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
    sdec.baud, sdec.snapped, sdec.snapfirm = sdec.sig_snap(sdec.baud_raw)
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
-- 0.25, AND THAT NUMBER IS MEASURED, NOT ASSUMED. "Every byte is in error" is what the panel
-- LOOKS like -- a row is painted red if any of its 16 bytes failed, so a third of frames bad reddens
-- essentially every row -- but the actual interior-bad fraction for the bench case (38400 on the wire
-- under a 19200 lock at 8.3 samples/bit) is 0.37. A 0.9 gate would never have fired on the very
-- report it was written for. Measured across mismatches: 0.34-0.50 for a wrong rate, against ~0.004
-- for a healthy capture, so a quarter separates them with room on both sides.
sdec.relock_badfrac   = 0.25     -- interior frames in error before the lock is doubted
sdec.relock_minframes = 8        -- fewer frames than this and a bad fraction is not evidence

-- WHAT HAPPENS WHEN A FORCED RATE IS PROVED WRONG -- 'adopt' or 'ask'.
--
-- 'adopt' TAKES THE DETECTED RATE, rounded to a credible boundary, locks it and says so on the note
-- row. 'ask' refuses the decode, names the rate the wire carries, and leaves the choice with the
-- operator: sdec.rate_accept() takes the detected rate, sdec.rate_decline() keeps theirs.
--
-- ADOPT IS THE DEFAULT BECAUSE THE REFUSAL COULD NOT BE ANSWERED FROM THE PANEL. Measured on the
-- instrument: BAUD read '16099?' locked, the note read '18700 baud fits nothing; this capture reads
-- 16099', no bytes, and no control offered the detected rate -- rate_accept() has no button, and
-- 'Lock Rate' hides itself while a rate is locked, which it was. The only route out was Options and
-- the number typed by hand, which is also how the wrong rate got there.
--
-- The case against adopting was that it puts bytes on the panel at a rate nobody chose. That still
-- holds, and what answers it is the note row plus the gates: the rate is adopted only when it has
-- been decoded at successfully AND the operator's own rate failed AND the wire's measured bit time
-- disagreed with it. A rate that explains the capture is not "a rate nobody chose".
--
-- NOTHING BLOCKS ON A HUMAN in either mode. There is no modal wait -- the offer is published as state
-- and the two answers are ordinary functions, so a headless caller drives either branch and an
-- unattended lap that never answers simply stays refused.
sdec.force_conflict = sdec.force_conflict or 'adopt'

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
  -- perfectly good bus. Gated by test_serial's 'MIDI pins 31250'.
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
      -- LOCK IT, rather than leaving the app unlocked and hoping autolock picks it up. It will not
      -- always: autolock is skipped for one capture after any request for auto-detect, and it has
      -- four more gates of its own. Leaving this unlocked is what made the panel read 'unlocked'
      -- while the recording modes stayed unreachable for want of a locked rate.
      --
      -- ROUNDED, so what gets locked reads like a setting: 16099 locks as 16100. Not rounded when
      -- the value is a standard rate, and not rounded when the shift would exceed 1 % -- baud_round
      -- decides both, and hands back `credible` for the second case.
      -- FROM THE MEASUREMENT WHEN THE SNAP WAS NOT FIRM, for the same reason autolock_try does it:
      -- `found` is sdec.baud, which sig_snap has already relabelled, so adopting it here relocks the
      -- overstated standard rate and makes a one-capture mislabel permanent. Cluster C reached the
      -- instrument through exactly this shape.
      if sdec.snapfirm == false and sdec.baud_raw ~= nil then found = sdec.baud_raw end
      local adopt = sdec.baud_round(found)
      sdec.force_baud = adopt
      -- snapfirm GOES TRUE WITH snapped. What is published now is a rate the app chose deliberately and
      -- rounded to something typeable, so it is not an overstated snap -- and leaving a stale false here
      -- would print 'auto-locked 37700 baud?' about a number that is exactly what was locked.
      sdec.baud, sdec.snapped, sdec.snapfirm = adopt, true, true
      -- THE FORMAT LOCK STAYS. This branch is the one where the decode SUCCEEDED -- ok2 with a bad
      -- fraction under the threshold, framed with whatever width, parity and stop count were forced
      -- -- so the format is evidenced, and clearing it would discard working knowledge and pay for
      -- the format search again on the next capture. The back-off branch below is where nothing
      -- worked, and that is where the format is dropped.
      sdec.relocked = string.format('%g baud fit nothing -- now locked to %.0f, which this capture reads',
                                    was or 0, adopt or 0)
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
        was or 0, found or 0)
    return false, string.format('%g baud fits nothing; this capture reads %.0f', was or 0, found or 0)
  end
  -- NO RATE FIT THESE SAMPLES, so there is nothing to adopt -- but the locked one failed too, and
  -- putting it back left the operator pressing Capture at an all-red panel with no way out but
  -- Options. So back off to auto and ask capture() for one fresh acquisition: these samples were
  -- taken through a window sized for the failed rate, so re-deciding on them is not a new
  -- measurement. Only what autolock chose is dropped; a typed width or parity is a decision.
  sdec.relocked = string.format('%g baud fits nothing, and no other rate fit either -- ' ..
                                'back to auto-detect', was or 0)
  sdec.rate_backoff = true
  sdec.force_baud = nil
  if sdec.autolock_set ~= nil then
    if sdec.autolock_set.nbits then sdec.force_nbits = nil end
    if sdec.autolock_set.par   then sdec.force_par   = nil end
    if sdec.autolock_set.nstop then sdec.force_nstop = nil end
    sdec.autolock_set = nil
  end
  -- The UNLOCKED decode, not another pass at the rate just abandoned: that would publish rate_note
  -- about a lock which no longer exists.
  return ok2, why2
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
  return string.format('%d%s%d', nbits or 0, tostring(p), nstop or 0)
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
  -- serial_ui.tsp's mode_why. Identical characters on 5.0.2, so the offline suites cover it.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    return string.format('%.0f baud', sdec.force_baud or 0)
  end
  if sdec.baud == nil then return '--' end
  -- %.0f here too: `snapped` is true for any FORCED rate (see decode_from), not only for one
  -- sig_snap matched, so this branch is not guaranteed a standard-rate integer by itself.
  --
  -- A SNAP THAT IS NOT FIRM KEEPS THE '?'. The standard rate is still the answer -- real devices use
  -- standard rates -- but when the measurement sat further from it than the fit's own accuracy, the
  -- number is a choice rather than a reading, and dropping the marker is what made a 2.6 % error look
  -- exact. See sdec.snaptol_firm for where that boundary is and how it was calibrated.
  if sdec.snapped and sdec.snapfirm ~= false then return string.format('%.0f baud', sdec.baud or 0) end
  return string.format('%.0f baud?', sdec.baud or 0)
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
    return string.format('%s  %s  idle %s', tostring(sdec.baud_text()), tostring(sdec.fmt_text()), tostring(idle))
  end

  if i == 2 then
    if sdec.lo == nil then return 'no signal' end
    local spb = ''
    if sdec.bittime ~= nil then
      spb = string.format('  %.1f sa/bit', sdec.bittime or 0)
    end
    return string.format('%s  %.2f/%.2f V  thr %.2f V%s',
                         tostring(sdec.family), sdec.lo or 0, sdec.hi or 0, sdec.thr or 0, tostring(spb))
  end

  if i == 3 then
    if r == nil then return '0 bytes' end
    local fs = sdec.acq_fs or sdec.fs
    -- fs DEFENDED INSIDE THE DIVISION, not by `or 0` on the argument: the divide happens first, so
    -- `fs / 1000 or 0` still raises when both acq_fs and fs are nil. capture_run() logs this line
    -- bare on its success tail, where a raise would cost the two lines beside it and the repaint.
    return string.format('%d bytes  %d err  fit %.2f  %.0f kS/s',
                         r.nf or 0, r.nbad or 0, sdec.fitq or 0, (fs or 0) / 1000)
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
--
-- TOTAL FOR ANY vals CONTENT, which is load-bearing rather than defensive: ck_sink_file's emit()
-- formats a row and THEN shifts its carry, so a raise out of here leaves cn and cbase describing a
-- row the file never got, while flog_bytes has already counted those bytes on acceptance. Making
-- this total is what lets both call sites run it bare -- the alternative was a pcall around our own
-- formatter at each of them.
--
-- A TYPE TEST ALONE IS NOT ENOUGH, and the gap is interpreter-dependent, which is the worst kind.
-- '%02X' on a number with no integer representation RAISES under the host's 5.1+ Lua (1.5, nan, inf,
-- 1e300) and merely CASTS under the 5.0.2 that ships -- so a type test passes every offline suite
-- and the claim above would be false on the interpreter the tests run on. The range test below is
-- what makes it true on both. It also keeps the row FIXED WIDTH: 256 or 65536 formats without
-- raising and widens the row, which no test would have caught either.
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
      -- TYPE *AND* RANGE. Measured on the host: a string, a boolean and a table each RAISE -- the
      -- first two words through string.format('%02X'), a numeric string through ua_char's `v >= 32`
      -- -- and so does any number without an integer representation. `v ~= v` is the nan test;
      -- floor(inf) == inf, so inf is caught by the bound rather than by it. A nil already rendered
      -- as ' --', so every rejected value joins a branch that already existed.
      local bad = type(v) ~= 'number'
      if not bad then
        bad = v ~= v or v < 0 or v > 255 or math.floor(v) ~= v
      end
      if bad then
        hx[m] = ' --'
        as[m] = sdec.ua_char(nil, errs[i])
      else
        hx[m] = string.format(' %02X', v)
        as[m] = sdec.ua_char(v, errs[i])
      end
    end
  end
  return string.format('%04d %s  |%s|', base + i0 - 1, tostring(sdec.ua_hexjoin(hx, m, '')),
                       tostring(table.concat(as)))
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
      if v == nil then hx[m] = '--' else hx[m] = string.format('%02X', v or 0) end
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

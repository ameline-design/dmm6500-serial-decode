-- uart_decode.tsp -- asynchronous serial (UART) framing for the Keithley TSP serial decoder.
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.
--
-- Works from what serial_core.tsp produced: threshold, edge list, bit time. It samples ~14 computed
-- positions per frame rather than scanning linearly, so decode cost scales with bytes, not capture
-- length, which makes a brute-force format search affordable -- and brute force is the only option,
-- a UART line carrying no clock and no framing metadata. A wrong guess puts the stop-bit sample on a
-- data bit, which raises a framing error about half the time, so decoding under every plausible
-- format and keeping the fewest-error result recovers it: 12 decodes by default.

sdec = sdec or {}

sdec.PAR_NONE = 0
sdec.PAR_EVEN = 1
sdec.PAR_ODD  = 2

-- Search order is also the tie-break order, so the commonest bench format wins when two explain the
-- capture equally well. A wider frame launders the evidence of damage, so the error count can fall
-- as the answer gets worse, and 9 is unreachable without forcing Data Bits = 9. With "any width"
-- selected 5 and 6 join the search, biased against by sdec.rarewidth, and ua_refine_width still
-- walks down from a common width on positive evidence. docs/MEASUREMENTS.md, 'Why only 7 and 8 data
-- bits are searched by default' and 'Why 9 data bits is never searched, even biased'.
sdec.try_nbits     = {8, 7}              -- the default: the two widths that actually occur
sdec.try_nbits_all = {8, 7, 6, 5}        -- with "Auto (any width)"; 9 is forced-only, see above
sdec.try_par       = {0, 1, 2}

-- Explicit nil test: `or false` works but reads as a bug beside the booleans that need the test.
if sdec.widths_any == nil then sdec.widths_any = false end

-- The width list in force. Everything that searches widths goes through here.
function sdec.ua_widths()
  if sdec.force_nbits ~= nil then return {sdec.force_nbits} end
  if sdec.widths_any then return sdec.try_nbits_all end
  return sdec.try_nbits
end

-- A forced field narrows the candidate list rather than bypassing the search, leaving every scoring
-- and margin rule below unchanged: a one-entry list has nothing to lose to.
function sdec.ua_parities()
  if sdec.force_par ~= nil then return {sdec.force_par} end
  return sdec.try_par
end

function sdec.ua_stops()
  if sdec.force_nstop ~= nil then return {sdec.force_nstop} end
  return sdec.try_stop
end

-- One stop bit, which is a conclusion rather than a simplification: a second is indistinguishable
-- from a bit time of idle, which the decoder already tolerates, so nstop = 2 can never rescue a
-- capture nstop = 1 fails on. ua_frame() still honours a forced nstop. 1.5 stop bits defeats
-- sig_bittime rather than the frame layer and is left unfixed: docs/MEASUREMENTS.md, '1.5 stop bits'.
sdec.try_stop  = {1}

-- Candidate bit-time rescalings for ua_best(), ordered by distance from 1, so the fit is trusted
-- unless a rescaling decodes better. docs/MEASUREMENTS.md, 'Why sdec.ratios is asymmetric'.
sdec.ratios      = {1, 0.5, 2, 0.3333333333, 3, 0.25, 4, 0.2, 5, 0.1666666667, 6, 8, 10}
sdec.probe_nbits = {8, 7, 5}

-- How far a forced rate may disagree with the wire before the panel says so. Just inside the measured
-- 5.26 % cliff, so it warns before corruption starts. docs/MEASUREMENTS.md, 'ratemargin = 0.04'.
sdec.ratemargin = sdec.ratemargin or 0.04

-- How close to the best pulse-width consistency a candidate must come to stay in the running, and
-- the only thing that breaks a frame-count alias. docs/MEASUREMENTS.md, 'qgate = 0.8, and why
-- pulse-width consistency is needed at all'.
sdec.qgate = 0.8

-- Fewest good frames before format alternatives are worth reporting: ua_margin has an absolute
-- floor, so on a handful of frames almost every format lands inside it and the list says nothing.
sdec.alt_minframes = sdec.alt_minframes or 8

-- sdec.res           -- the chosen decode result (declared, not assigned: see
-- sdec.fmt_note      -- serial_core.tsp on why a reload must not clobber state)
-- sdec.baud_note     -- an equally-valid reading at a different baud rate
sdec.fitratio = sdec.fitratio or 1    -- the rescaling ua_best() settled on

-- Manual overrides: each replaces the corresponding auto-detected value. Declared, not assigned, so a
-- relaunch cannot discard settings the operator entered on the options form.
-- sdec.force_baud
-- sdec.force_nbits
-- sdec.force_par
-- sdec.force_nstop
-- sdec.force_invert

-- ============================================================================
-- Bit sampling
-- ============================================================================
-- Sample the logical bit level at fractional sample position x. Returns 0, 1, or nil outside the
-- capture. Three taps are majority-voted: docs/MEASUREMENTS.md, 'Three-tap majority sampling'.
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
-- first use; the loop is kept for anything wider. docs/MEASUREMENTS.md, "ua_popcount's lookup table".
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
-- [t0 + k*T, t0 + (k+1)*T), k = 0 the start bit; data is LSB first. Returns value, err -- nil on
-- success, else 'start', 'parity', 'framing' or 'truncated'. A parity or framing failure still
-- returns the value: a byte with a bad stop bit is usually the right byte at the wrong baud rate. The
-- sampling is ua_bit inline, expression for expression, a call costing about as much as the sampling
-- it wraps. docs/MEASUREMENTS.md, 'Three-tap majority sampling'.
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
-- Decoding is sequential, not per-candidate-edge: inside a byte a 1 -> 0 data transition is
-- indistinguishable from a start bit, and only knowing where the current frame ends separates them.
-- The first frame is anchored on an edge preceded by >= 1.5 bit times at mark; tmin0 resumes
-- instead, and frames before it are not emitted. docs/MEASUREMENTS.md, 'tmin0 makes ua_run
-- resumable'.
-- When the residue vote may override the mark-run rule. Two conditions, and both earn their keep.
-- The share guards against an inter-byte gap, which smears the residues: measured at 0.38 gapless
-- and at most 0.19 with a gap. The count guards against a short capture, where a dozen frames put
-- the share over any threshold by chance -- a 13-byte capture was losing its first byte to a vote
-- taken over 12 frames. A capture worth voting on has hundreds: 20000 samples at 9600 baud holds
-- about 190 frames, and the ranking probe's 4000-sample window about 38.
sdec.ua_resid_frac = sdec.ua_resid_frac or 0.25
sdec.ua_resid_min  = sdec.ua_resid_min  or 20

function sdec.ua_run(rd, n, T, nbits, par, nstop, invert, tmin0)
  local parbits = 0
  if par ~= sdec.PAR_NONE then parbits = 1 end
  local framebits = 1 + nbits + parbits + nstop

  local r = {nf = 0, ngood = 0, nbad = 0, nfalse = 0, vals = {}, errs = {},
             tpos = {}, framebits = framebits}

  local ne, ei, es = sdec.ne, sdec.ei, sdec.es
  if ne == nil or ne < 1 then return r end

  -- A frame begins where the line leaves mark: falling on an idle-high line, rising on an inverted.
  local want = 0
  if invert then want = 1 end

  -- The anchor has to be inside `n`, and the bound is `n` rather than "room for a whole frame":
  -- docs/MEASUREMENTS.md, 'Why the anchor search is bounded by `n`'. Only the 1.5-bit search is
  -- bounded; the fallback takes the first candidate edge and ei ascends, so bounding it changes none.
  local anchor = nil
  if tmin0 == nil then
    -- A gapless stream holds no mark run that data could not have produced, so the 1.5-bit test
    -- below anchors inside a byte and misaligns the head. The phase is still recoverable: a frame
    -- boundary always carries a stop-to-start transition, so a start bit falls once per frame where
    -- a data edge at a given bit position appears only when the data demands it. Binning candidates
    -- by bit index modulo the frame length therefore lets the start bits win outright.
    --
    -- The residue test assumes a frame pitch of framebits, which holds only with no inter-byte gap,
    -- so it abstains unless the vote is decisive: by a share of its own count, since a gap smears the
    -- residues, and above a floor, since a dozen frames clear any share by chance.
    --
    -- How far the lead reaches is a property of the payload, so this fixes some gapless captures and
    -- abstains on others. Measured at gap 0: a mixed payload of letters, digits and spaces leads by
    -- 37.9 % and the vote fires at every start offset, recovering the whole head; lowercase prose
    -- leads by 15.1 % and all-lowercase p-z by 7.4 %, and the vote declines on both, because a
    -- lowercase byte puts an edge in the same cell as the start bit in most frames. What it reliably
    -- resolves is a periodic payload, where one residue holds every frame.
    if T > 0 and ne >= framebits then
      local h, base = {}, ei[1]
      for k = 0, framebits - 1 do h[k] = 0 end
      for k = 1, ne do
        if es[k] == want then
          local rsd = math.mod(math.floor((ei[k] - base) / T + 0.5), framebits)
          h[rsd] = h[rsd] + 1
        end
      end
      local bestr, bestn, second = nil, -1, 0
      for k = 0, framebits - 1 do
        if h[k] > bestn then second = bestn; bestr, bestn = k, h[k]
        elseif h[k] > second then second = h[k] end
      end
      if second < 0 then second = 0 end
      if bestn >= sdec.ua_resid_min and (bestn - second) >= sdec.ua_resid_frac * bestn then
        -- Earliest edge at the winning residue, so the decode starts as soon as the phase allows.
        for k = 1, ne do
          if es[k] == want
             and math.mod(math.floor((ei[k] - base) / T + 0.5), framebits) == bestr then
            anchor = k
            break
          end
        end
      end
    end
    if anchor == nil then
      for k = 1, ne do
        if es[k] == want and ei[k] <= n then
          local markrun
          if k == 1 then markrun = ei[1] - 1 else markrun = ei[k] - ei[k-1] end
          if markrun >= 1.5 * T then anchor = k; break end
        end
      end
    end
    if anchor == nil then
      -- No idle gap anywhere and no decisive vote: fall back to the first candidate edge and accept
      -- that the first frame may be misaligned.
      for k = 1, ne do
        if es[k] == want then anchor = k; break end
      end
    end
  else
    -- Resuming: the caller knows the phase. On a gapless stream the search above falls through to the
    -- first candidate edge, a data transition inside a byte, and every frame after it is misaligned.
    anchor = 1
  end
  if anchor == nil then return r end

  -- Half a bit of slop, so ordinary edge jitter cannot make a legitimate next start bit look like it
  -- arrived inside the previous frame. The last possible in-frame edge is at
  -- t0 + (1 + nbits + parbits)*T, which is (nstop - 0.5) bit times before tmin -- so widen with care.
  local tmin = -1
  if tmin0 ~= nil then tmin = tmin0 end
  local prev = nil          -- t0 of the previous emitted frame, for the idle test below
  -- Numeric for, not a while: the VM folds the increment and bound into one FORLOOP opcode.
  for k = anchor, ne do
    if es[k] == want and ei[k] >= tmin then
      local t0 = ei[k]
      local val, err = sdec.ua_frame(rd, n, t0, T, nbits, par, nstop, invert)
      if err == 'truncated' then break end

      -- A failed start bit is a false trigger, not a corrupt byte -- usually an impulse on an idle
      -- line. Counting it would leak the spike count into the score the format search ranks on.
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

  -- Frames before the first idle are the ones a mid-byte start corrupts, and the mark is set on
  -- evidence. docs/MEASUREMENTS.md, 'A capture that began mid-byte'.
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

-- How far a misaligned head reaches: the last flagged frame inside headsusp, or 0. headsusp is a
-- region, not a count of damage, so quoting it over-claims. `hs` overrides r.headsusp for a tail.
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
-- wrong, so a frame can pass parity and stop by luck. An identified head counts in full and the
-- resync exclusion is dropped across it; the final frame stays excluded.
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

-- Bytes a reader would take for text: A-Z, a-z, 0-9, and how many good frames were looked at. Good
-- frames only, a flagged frame's value being untrustworthy by definition. Ties break on this in
-- ua_best_end, which needs the denominator as well as the count.
function sdec.ua_textn(r)
  if r == nil or r.vals == nil or r.errs == nil then return 0, 0 end
  local c, g, i = 0, 0, nil
  for i = 1, r.nf do
    if r.errs[i] == nil then
      local v = r.vals[i]
      g = g + 1
      if (v >= 48 and v <= 57) or (v >= 65 and v <= 90) or (v >= 97 and v <= 122) then
        c = c + 1
      end
    end
  end
  return c, g
end

-- Rank a decode: good frames less three times the bad ones.
function sdec.ua_score(r)
  return r.ngood - 3 * r.nbad
end

-- How much better a rival format must score to displace the incumbent: proportional, a rival having
-- to win by >60 %, which turns the search order into a commonality prior and is scale-free.
-- docs/MEASUREMENTS.md, "ua_margin: why a plain '>' is wrong".
--
-- sdec.rarewidth is the extra margin a 5- or 6-bit rival must clear on top of that: a shorter frame
-- tiles a longer one, so a tiling artefact scores a dead tie that search order alone decides.
-- ua_refine_width keeps the bias from being lossy, walking back down to a rare width on positive
-- evidence. docs/MEASUREMENTS.md, 'rarewidth = 8'.
sdec.rarewidth = 8

-- Extra margin a polarity flip must clear when the idle prior came from the signalling standard
-- rather than a run length. docs/MEASUREMENTS.md, 'polmargin = 4, and the inverted-ASCII trap'.
sdec.polmargin = 4

-- The bias multiplies the proportional term only, never the floor.
function sdec.ua_margin(sc, nbits)
  local m = 0
  if sc > 0 then m = 0.6 * sc end
  if nbits ~= nil and nbits < 7 then m = m * sdec.rarewidth end
  if m < 2 then m = 2 end
  return m
end

-- Fraction of a decode's values that read as text. The last resort when two polarities tie, and it
-- has to stay last: on a random payload it points the wrong way, 40.2 % for the inverted reading
-- against 34.1 % for the truth. docs/MEASUREMENTS.md, 'The polarity tiebreak'.
function sdec.ua_printfrac(r)
  if r == nil or (r.nf or 0) < 1 then return 0 end
  local ok, tot = 0, 0
  local i
  for i = 1, r.nf do
    local v = r.vals[i]
    if v ~= nil then
      tot = tot + 1
      if (v >= 32 and v < 127) or v == 9 or v == 10 or v == 13 then ok = ok + 1 end
    end
  end
  if tot == 0 then return 0 end
  return ok / tot
end

-- How close two polarities' frame counts must be before their error counts compare fairly. A mirror
-- framing of one capture covers it to within a frame; one that frames half as much has lost rather
-- than tied, and its lower error count is an artefact of framing less.
sdec.ua_polnftol = 0.1
-- How far ahead on text a winner must be before text is allowed to decide. Measured separations:
-- 0.389 on gapless lowercase lorem and 0.576 on the fox vector, against 0.061 between the two
-- readings of a random payload, where text means nothing and must not decide.
sdec.ua_textmin = 0.25

-- One run at a fixed format, with the fields ua_pick_pol and the caller read filled in.
function sdec.ua_run_fmt(rd, n, T, nbits, par, nstop, inv)
  local r = sdec.ua_run(rd, n, T, nbits, par, nstop, inv)
  r.score = sdec.ua_score(r)
  r.nbits, r.par, r.nstop, r.invert = nbits, par, nstop, inv
  return r
end

-- Choose between the two polarities of one capture, prior first. The prior keeps the decision unless
-- the rival earns it, and the tiers run in the order the evidence has earned: the score beyond its
-- margin, then text, then the error count. Returns the winner and the tier that decided.
--
-- Text outranks the error count, which is the opposite of what it looks like it should be. The error
-- count is not reliable here: on gapless lowercase lorem the CORRECT polarity carries two interior
-- errors, at frames 2 and 5, where the fake framing carries none, so the cleaner decode is the wrong
-- one in both directions. Text reads 97.8 % against 58.9 % on the same pair and is right both times.
-- The error count still breaks a tie text cannot see, which is a payload with no alphabet to read.
-- docs/MEASUREMENTS.md, 'The polarity tiebreak'.
function sdec.ua_pick_pol(a, b, weak)
  if a == nil then return b, 'only' end
  if b == nil then return a, 'only' end
  local m = sdec.ua_margin(a.score)
  if weak then m = m * sdec.polmargin end
  if b.score > a.score + m then return b, 'score' end
  -- The tiers below run only on a guessed prior. An observed idle run is direct evidence of the
  -- resting level, and neither an alphabet nor an error count is entitled to overturn it.
  if not weak then return a, 'prior' end
  -- Both tiers need the two framings to cover the capture equally. A mirror framing of one capture
  -- matches the other's frame count to within a frame; one that frames half as much has lost rather
  -- than tied, and both its error count and its text fraction are artefacts of framing less.
  local na, nb = a.nf or 0, b.nf or 0
  local big = na
  if nb > big then big = nb end
  if big < 1 or math.abs(na - nb) > sdec.ua_polnftol * big then return a, 'prior' end
  local fa, fb = sdec.ua_printfrac(a), sdec.ua_printfrac(b)
  if fb > fa + sdec.ua_textmin then return b, 'text' end
  if fa > fb + sdec.ua_textmin then return a, 'text' end
  if (b.nbad or 0) < (a.nbad or 0) then return b, 'errors' end
  return a, 'prior'
end

-- Search every format at one polarity, also returning those within the margin, the UI's ambiguity.
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

-- Try both polarities and keep the better. Returns the result table with nbits/par/nstop/invert/score
-- filled in, or nil.
function sdec.ua_autoformat(rd, n, T)
  sdec.fmt_note = nil
  sdec.polwhy = nil

  -- The prior polarity goes first and keeps the decision unless the other wins by the frame-shape
  -- margin; a forced polarity ends the contest rather than entering it. docs/MEASUREMENTS.md,
  -- 'The polarity contest needs a margin'.
  if sdec.force_invert ~= nil then
    return sdec.ua_search_pol(rd, n, T, sdec.force_invert)
  end

  local first, second
  if sdec.idle == 0 then first, second = true, false else first, second = false, true end

  local ra = sdec.ua_search_pol(rd, n, T, first)
  local rb = sdec.ua_search_pol(rd, n, T, second)
  -- How hard the prior is to overturn depends on where it came from: with no idle in the capture it
  -- is the signalling standard, not an observation, so the rival needs ~3.4x instead of 1.6x. When
  -- that leaves the two tied, ua_pick_pol's tiers decide instead of the prior winning by default.
  local best, why = sdec.ua_pick_pol(ra, rb, sdec.idle_weak)
  sdec.polwhy = why
  return best
end

-- Whether a candidate bit time could describe this capture at all. Floor sdec.minsabit, ceiling
-- sdec.maxbaud, both in serial_core.tsp. docs/MEASUREMENTS.md, 'minsabit, and why the floor exists
-- at all' and 'plaustol = 0.02, on both ends'.
sdec.plaustol = 0.02

-- Is this bit time inside the samples-per-bit range the instrument can carry?
function sdec.ua_plausible(T, n)
  if T == nil then return false end
  if T < sdec.minsabit * (1 - sdec.plaustol) then return false end
  if T > n / 8 then return false end               -- no room for even one frame
  -- A candidate longer than the median pulse claims most pulses are shorter than one bit.
  -- docs/MEASUREMENTS.md, 'The median-pulse ceiling'.
  if sdec.wmed ~= nil and sdec.wmed > 0 and T > 1.15 * sdec.wmed then return false end
  local fs = sdec.acq_fs or sdec.fs
  local b = fs / T
  -- Both ends carry plaustol: a limit a rounding error can cross is not a limit.
  return b >= sdec.minbaud * (1 - sdec.plaustol)
     and b <= sdec.maxbaud * (1 + sdec.plaustol)
end

-- Is this candidate bit time a sub-multiple of the one that generated the pulses? The mirror of
-- ua_plausible's too-long test, and a prior on real traffic rather than a structural proof. Gates
-- candidates only, never the fit. docs/MEASUREMENTS.md, 'ua_submultiple: the odd-multiple test'.
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
      -- math.mod, not % and not math.fmod: the offline harness shims fmod, so a wrong call passes
      -- every offline test and dies on the instrument.
      -- docs/MEASUREMENTS.md, 'math.mod, not math.fmod'.
      if math.mod(k, 2) == 1 then odd = odd + 1 end
    end
  end
  if seen < sdec.submult_minpulses then return false end
  return odd < sdec.submult_oddfrac * seen
end

-- Good frames the width fit must reach before ua_submultiple also guards a fit that snapped to no
-- standard rate. A fit on an m-multiple of the truth frames only 1/m of the bytes in ua_probe's
-- window, so a high count is itself evidence the fit is not a multiple.
-- docs/MEASUREMENTS.md, 'Guarding a fit that snapped to nothing'.
sdec.ua_submult_minsc = sdec.ua_submult_minsc or 15

-- Does this candidate claim the shortest pulse on the wire is several bit times long? Covers the odd
-- divisors ua_submultiple cannot, on the 5th percentile rather than the minimum, and gates candidates
-- only, never the fit. Armed by ua_fit_mults below rather than by snap1 alone, which left every odd
-- multiple admitted on a non-standard commanded rate. docs/MEASUREMENTS.md, 'submult_maxrunlo = 2.5'.
sdec.submult_maxrunlo = sdec.submult_maxrunlo or 2.5

function sdec.ua_minrun_absurd(T)
  if T == nil or T <= 0 then return false end
  if (sdec.nw or 0) < sdec.submult_minpulses then return false end
  local lo = sdec.wshort
  if lo == nil or lo <= 0 then return false end
  return lo / T > sdec.submult_maxrunlo
end

-- How many separate pulse multiples the fit explains, bounded by maxmult. A fit that accounts for the
-- whole capture with one or two multiples has not been corroborated by the capture's structure: that
-- is the signature of a periodic payload, where the fit may sit on k bit times and the truth is
-- reachable only as a 1/k rescaling. A fit seeing several distinct multiples is doing real work on
-- real traffic, and there it is the sub-multiple candidate that should be doubted.
-- docs/MEASUREMENTS.md, 'Arming the sub-multiple gates'.
sdec.ua_submult_minmults = sdec.ua_submult_minmults or 4

function sdec.ua_fit_mults(T)
  if T == nil or T <= 0 then return 0 end
  local seen, n = {}, 0
  local i
  for i = 1, (sdec.nw or 0) do
    local k = math.floor(sdec.w[i] / T + 0.5)
    if k >= 1 and k <= sdec.maxmult and seen[k] == nil then
      seen[k] = true
      n = n + 1
    end
  end
  return n
end

-- Whether the fit is consistent with the pulse-width distribution it came from, which separates "the
-- line is faster than this instrument" from "impulse noise captured the fit".
-- docs/MEASUREMENTS.md, 'ua_fit_corrupt: med/Tfit separates two faults'.
function sdec.ua_fit_corrupt(Tfit)
  local med = sdec.wmed
  if med == nil or med <= 0 or Tfit == nil or Tfit <= 0 then return true end
  return med > 2.5 * Tfit
end

-- Why no bit time was usable, in the operator's terms: "too fast for this sample rate" and "nothing
-- resembling a frame" call for different actions. Every limit named here is the one ua_plausible
-- refused with, constant for constant, or the sentence blames a limit that did not fire.
function sdec.ua_implausible_why(T)
  if T == nil or T <= 0 then return 'no bit timing' end
  local fs = sdec.acq_fs or sdec.fs
  if fs == nil or fs <= 0 then return 'no sample rate' end
  local b = fs / T
  -- Ceiling before the samples-per-bit floor, and in baud, because the two coincide at one sample
  -- rate. Were it checked second the floor would swallow every case and this message never print.
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

-- Choose the bit time by decode quality rather than pulse statistics alone: framing is the stronger
-- constraint, since a wrong bit time puts the stop sample on a data bit. Parity is in the probe, or
-- 8E1 scores negative at every candidate. docs/MEASUREMENTS.md, 'Why the rescaling search is gated'.

-- How many samples a probe may look at; nil = all. Only the ranking is truncated -- the final decode
-- runs over everything. docs/MEASUREMENTS.md, 'ua_probe_n = 4000', with the sweep to re-run first.
sdec.ua_probe_n = sdec.ua_probe_n or 4000

-- How much better a snapped rescaling must score before it may displace the width fit, and how
-- badly the fit must be failing to be displaceable at all. See ua_best_end.
sdec.ua_alt_margin = sdec.ua_alt_margin or 3
sdec.ua_alt_badfrac = sdec.ua_alt_badfrac or 0.1

-- Score gap inside which two bit times are called equal and the text count decides. One point: at
-- two, the all-zero family -- where the rescaling is the truth and the fit reads four letters to its
-- none -- loses the displacement that recovers it.
sdec.ua_tie_margin = sdec.ua_tie_margin or 1

-- What makes a text count evidence rather than an artefact. A wrong bit time re-slices the stream and
-- fabricates letters, so a bare count decides nothing: both floors must clear.
-- docs/MEASUREMENTS.md, 'What makes a text count evidence'.
sdec.ua_textmin  = sdec.ua_textmin  or 16      -- letters, absolute
sdec.ua_textfrac = sdec.ua_textfrac or 0.25    -- share of good frames; chance alone reaches 0.242

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
  local snb, spar, sinv = nil, nil, nil
  local j, c, k
  for j = 1, npn do
    for c = 1, npa do
      for k = 0, 1 do
        local r = sdec.ua_run(rd, n, T, sdec.probe_nbits[j], sdec.try_par[c], 1, (k == 1))
        if r.ngood >= 1 then
          local s = sdec.ua_score(r)
          -- nbad too: the caller needs to know whether the fit is failing or finding fewer frames.
          if sc == nil or s > sc then
            sc, scbad, scgood = s, r.nbad, r.ngood
            snb, spar, sinv = sdec.probe_nbits[j], sdec.try_par[c], (k == 1)
          end
        end
      end
    end
  end
  return sc, scbad, scgood, snb, spar, sinv
end

-- Returns bittime, ratio. The width fit is trusted whenever it snaps to a standard rate and frames
-- something; otherwise the snapped rescalings are searched, and one that explains materially more of
-- the capture is reported in sdec.baud_note. docs/MEASUREMENTS.md, 'Why the rescaling search is
-- gated' and 'The same waveform at two rates'.
--
-- Split into three so the expensive middle can be served a slice at a time:
--   ua_best_begin  prologue, the cheap width pass, and a probe of the fit itself
--   ua_best_probe  scores one candidate -- the expensive unit
--   ua_best_end    the decision logic over whatever the probes found
-- `st` holds what the three share: one table, the 200-active-locals ceiling being real here.
function sdec.ua_best_begin(rd, n, Tfit)
  local fs = sdec.acq_fs or sdec.fs
  sdec.baud_note = nil

  local _, snap1 = sdec.sig_snap(fs / Tfit)

  -- Score every candidate that snaps to a standard rate even when the fit will be kept, so an
  -- alternative that explains more of the capture is reported. An implausible fit is rescaled only
  -- when it is also inconsistent with its own widths.
  local mayrescale = sdec.ua_plausible(Tfit, n) or sdec.ua_fit_corrupt(Tfit)

  local cands, nc = sdec.ua_cands(Tfit)
  local i

  -- First pass: how well each candidate explains the pulse widths. Cheap, and needed for every
  -- candidate before any can be judged, the gate being relative.
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
  local fnb, fpar, finv = nil, nil, nil
  -- Admissibility is recorded apart from the score, because sc1 comes back nil for two unrelated
  -- reasons -- the fit was inadmissible, or ua_probe's window framed nothing -- and ua_best_end must
  -- report "no bit time" for only the first. A capped probe on a late-starting capture hits the
  -- second, and reading it as inadmissible loses a fit that is perfectly good.
  local adm = false
  if sdec.ua_plausible(Tfit, n) then
    local _, qq = sdec.sig_fit(sdec.w, sdec.nw, Tfit)
    q1 = qq or 0
    if q1 >= qmin then
      adm = true
      sc1, bad1, good1, fnb, fpar, finv = sdec.ua_probe(rd, n, Tfit)
    end
  end

  -- Armed once per capture: each costs a pass over the widths, and neither answer can change between
  -- candidates. The two gates are armed on different questions, because only one of them can reject a
  -- true candidate. ua_minrun_absurd does that whenever the payload's shortest real pulse is genuinely
  -- several bit times -- all-0x00 is runs of 9 and 3, which puts wshort/T at 3 against a 2.5
  -- threshold -- so it is armed only on evidence that the capture holds short pulses to compare
  -- against, which is what a diverse multiple set is. ua_submultiple cannot make that mistake: where
  -- the runs are odd it abstains, so it may also be armed by a fit that simply frames a lot.
  local armrun = snap1 or sdec.ua_fit_mults(Tfit) >= sdec.ua_submult_minmults
  local armsub = armrun or (sc1 or 0) >= sdec.ua_submult_minsc

  return {rd = rd, n = n, Tfit = Tfit, fs = fs, snap1 = snap1,
          mayrescale = mayrescale, cands = cands, nc = nc, qmin = qmin,
          sc1 = sc1, bad1 = bad1, good1 = good1, adm = adm,
          armsub = armsub, armrun = armrun,
          fnb = fnb, fpar = fpar, finv = finv,
          i = 0, altT = nil, altsc = nil, altr = nil}
end

-- Score the next candidate; false once every candidate has been scored. One call is one slice, and
-- the caller decides how many to run before handing the panel back.
function sdec.ua_best_probe(st)
  if st == nil or st.i >= st.nc then return false end
  st.i = st.i + 1
  local i = st.i
  local T, ratio, q = st.cands[i].T, st.cands[i].r, st.cands[i].q
  if st.mayrescale and ratio ~= 1 and q ~= nil and q >= st.qmin
     and sdec.ua_plausible(T, st.n)
     -- Both gates also guard a fit that snapped to nothing: the standard ladder is full of factor-2
     -- relations, so snap1 alone cannot see a halving, and a non-standard commanded rate leaves snap1
     -- false on exactly the captures where an odd multiple snaps. ua_best_begin arms them -- on
     -- different conditions, for the reason given there.
     -- docs/MEASUREMENTS.md, 'Guarding a fit that snapped to nothing'.
     and not (st.armsub and sdec.ua_submultiple(T))
     and not (st.armrun and sdec.ua_minrun_absurd(T)) then
    local _, snapped = sdec.sig_snap(st.fs / T)
    if snapped then
      local sc, _, _, anb, apar, ainv = sdec.ua_probe(st.rd, st.n, T)
      -- Candidates are ordered outward from ratio 1 and the comparison is strict, so the closest
      -- one wins ties.
      if sc ~= nil and (st.altsc == nil or sc > st.altsc) then
        st.altT, st.altsc, st.altr = T, sc, ratio
        st.anb, st.apar, st.ainv = anb, apar, ainv
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

-- Text a bit time yields over the whole capture, for the format ua_probe already ranked best.
-- ua_probe reads sdec.ua_probe_n samples, which at 8 samples a bit is ~47 bytes -- too few to see
-- text in a capture whose head is padding. One run, not the 18-way search again.
function sdec.ua_textat(rd, n, T, nb, par, inv)
  if T == nil or nb == nil then return 0, 0 end
  return sdec.ua_textn(sdec.ua_run(rd, n, T, nb, par, 1, inv))
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
      -- Displace only a fit that is failing, and then only by a wide margin: a clean fit is never
      -- displaced. docs/MEASUREMENTS.md, 'Only displace a fit that is failing'.
      local failing = bad1 ~= nil and good1 ~= nil and good1 > 0 and
                      bad1 >= (sdec.ua_alt_badfrac or 0.1) * (good1 + bad1)
      if failing and altsc >= (sdec.ua_alt_margin or 3) * sc1 then
        sdec.baud_note = string.format(
          '%s baud fits far better than %s (score %d vs %d, %d framing error(s))',
          tostring(ab), tostring((sdec.sig_snap(fs / Tfit))), altsc or 0, sc1 or 0, bad1 or 0)
        return altT, altr
      end
      -- "score", not "frames": ua_score is ngood - 3*nbad, so a decode with errors scores below its
      -- frame count and the two can be misordered.
      sdec.baud_note = string.format('%s baud also fits this waveform (score %d vs %d)',
                                     tostring(ab), altsc or 0, sc1 or 0)
    end
    return Tfit, 1
  end

  if altT == nil then
    -- No rescaling frames anything, so the fit is the only evidence there is. Keep it unless sc1 is
    -- nil, which means it failed ua_plausible or the q gate. docs/MEASUREMENTS.md, 'An inadmissible
    -- fit on an undersampled line'.
    if not st.adm then
      return nil, 1, sdec.ua_implausible_why(Tfit)
    end
    return Tfit, 1
  end
  -- A rescaling that frames nothing may not displace an admissible fit that lands on a standard
  -- rate. Both halves of that guard -- sc1 ~= nil and snap1 -- are load-bearing.
  -- docs/MEASUREMENTS.md, 'A negative-scoring rescaling may not displace a snapped fit'.
  if snap1 and sc1 ~= nil and altsc ~= nil and altsc <= 0 then return Tfit, 1 end
  if sc1 ~= nil and altsc ~= nil and altsc <= sc1 then return Tfit, 1 end
  -- A one-point win over hundreds of frames is a coin toss, so let the bytes break it: at equal
  -- framing, prefer the bit time that yields more text. Inert on binary payloads, both counts being
  -- zero, so it cannot disturb one. docs/MEASUREMENTS.md, 'The text tie-break'.
  if sc1 ~= nil and altsc ~= nil and (altsc - sc1) <= sdec.ua_tie_margin then
    -- Two full-length decodes, so the panel gets a tick: ua_best_probe gives one per candidate and
    -- this is the only other unbounded step in the function.
    if sdec.tick ~= nil then sdec.tick() end
    local t1, g1 = sdec.ua_textat(rd, n, Tfit, st.fnb, st.fpar, st.finv)
    local t2 = sdec.ua_textat(rd, n, altT, st.anb, st.apar, st.ainv)
    if t1 > t2 and t1 >= sdec.ua_textmin and t1 >= sdec.ua_textfrac * g1 then
      sdec.baud_note = string.format('%s baud fits as well and decodes less text (%d vs %d letters)',
                                     tostring((sdec.sig_snap(fs / altT))), t2, t1)
      return Tfit, 1
    end
  end
  return altT, altr
end

-- The unchunked form. Every current caller uses this; the stepper exists for the panel.
function sdec.ua_best(rd, n, Tfit)
  local st = sdec.ua_best_begin(rd, n, Tfit)
  -- One tick per candidate: the candidate is the only boundary inside the decode that carries no
  -- state, and it is the granularity a liveness indicator needs. docs/MEASUREMENTS.md, "ua_best's
  -- split". sdec.tick is nil in the shipped app, so the cost is one nil compare per candidate.
  while sdec.ua_best_probe(st) do
    if sdec.tick ~= nil then sdec.tick() end
  end
  return sdec.ua_best_end(st)
end

-- Collapse data bits that are 1 in every frame into the stop bit. Only an always-one bit qualifies,
-- and the collapse is reported rather than silent, 7 data bits plus mark parity genuinely putting a
-- constant 1 there. Guards match ua_refine_parity: >= 6 good frames and >= 3 distinct values in the
-- bits kept. docs/MEASUREMENTS.md, 'Collapsing an always-one top data bit'.
function sdec.ua_refine_width(r, rd, n, T)
  if r == nil or r.par ~= sdec.PAR_NONE then return r end
  -- A forced width is a decision the operator has already made.
  if sdec.force_nbits ~= nil then return r end
  if r.ngood < 6 then return r end
  local mod = math.mod
  local want, dropped = r.nbits, 0
  -- Floor follows the width setting. With rare widths excluded the collapse stops at 7 but still
  -- detects that it wanted to go further, and says so below.
  local floorw = 5
  if not sdec.widths_any then floorw = 7 end

  while want > floorw do
    local top  = 2 ^ (want - 1)
    -- Mask off the bits already dropped: testing the raw value works only when every strip happens
    -- to be valid. docs/MEASUREMENTS.md, 'Collapsing an always-one top data bit'.
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

  -- Evidence still pointing below the floor: the stream looks like a rare width the current setting
  -- excludes. Computed before either note is composed, so the two cannot fight over fmt_note.
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

  -- Re-decode rather than shifting the values in place: shifting keeps the longer reading's frame
  -- count while claiming the shorter format.
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

-- Separate 8N1 from 7E1 / 7O1, the one pair error scoring cannot tell apart: under the 8N1 reading
-- bit 7 would equal the parity of bits 0..6 in every frame. Guards are >= 6 good frames and >= 3
-- distinct values. docs/MEASUREMENTS.md, 'Separating 8N1 from 7E1'.
-- Frames at each end excluded from the vote regardless of what headsusp says: three at the head,
-- because a gapless stream resynchronises a few frames in, and one at the tail, which the buffer end
-- slices. docs/MEASUREMENTS.md, 'Why the parity vote skips the capture boundaries'.
sdec.par_skiphead = sdec.par_skiphead or 3
sdec.par_skiptail = sdec.par_skiptail or 1
-- Two tiers, unanimity getting in on a small sample and any dissent earning a larger one:
-- docs/MEASUREMENTS.md, "The parity vote's two tiers".
sdec.par_minfrac      = sdec.par_minfrac      or 0.95
sdec.par_minvote_all  = sdec.par_minvote_all  or 6
sdec.par_minvote_frac = sdec.par_minvote_frac or 20
-- Votes required in each bit-7 state, which stops a restricted alphabet faking parity.
-- docs/MEASUREMENTS.md, 'par_minboth: both bit-7 states, or it is not evidence of parity'.
sdec.par_minboth = sdec.par_minboth or 2

function sdec.ua_refine_parity(r, rd, n, T)
  if r == nil then return r end
  -- A forced parity is not a hypothesis to refine: reading the top data bit as parity is what the
  -- operator turned off by setting Parity = None.
  if sdec.force_par ~= nil then return r end
  if r.nbits ~= 8 or r.par ~= sdec.PAR_NONE then return r end
  if r.ngood < 6 then return r end

  -- Skip the capture boundaries always, not only when headsusp says so: headsusp needs a framing
  -- error in the head, and a misaligned head that frames cleanly as 8N1 produces none.
  local i0 = sdec.par_skiphead + 1
  local i1 = r.nf - sdec.par_skiptail
  -- headsusp is a region, not a count of damage (see ua_head_bad), so on a gapless stream it reaches
  -- almost the whole capture and excluding all of it starves the vote. Honoured only while it leaves
  -- a usable vote; where it would starve one the measured damage bounds the head instead.
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
  -- Both bit-7 states, or it is not evidence of parity at all: ndist alone does not protect.
  if ntop0 < sdec.par_minboth or ntop1 < sdec.par_minboth then return r end

  -- Unanimity gets in on the small sample; anything less must clear the fraction and the vote count.
  local need = sdec.par_minfrac * nvote
  if nvote < sdec.par_minvote_frac then need = nvote end
  local par, pname, nagree = nil, nil, 0
  if nev >= need and nev >= nod then
    par, pname, nagree = sdec.PAR_EVEN, 'even', nev
  elseif nod >= need then
    par, pname, nagree = sdec.PAR_ODD, 'odd', nod
  end
  if par == nil then return r end

  -- A dissent forces a real re-decode: rewriting every value to mod(v,128) is sound only when every
  -- voting frame agreed. docs/MEASUREMENTS.md, 'A dissenting voter forces a re-decode'.
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
    -- Widened, never overwritten: the re-decode finds its own suspect-head extent and the 8N1
    -- result's is nil whenever that pass framed the head cleanly, so overwriting loses the evidence.
    if r.headsusp ~= nil and (r2.headsusp == nil or r.headsusp > r2.headsusp) then
      r2.headsusp = r.headsusp
    end
    -- Stamp the format on: ua_run returns values and errors, not which format produced them, so the
    -- branch whose purpose is to change the format otherwise returns one with none.
    r2.nbits, r2.par, r2.nstop, r2.invert = 7, par, r.nstop, r.invert
    sdec.fmt_note = note
    return r2
  end

  -- Unanimous: the low 7 bits are the value in every frame that voted, so strip in place.
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
-- Formats whose score came within the margin of the winner's -- the ones this capture genuinely does
-- not distinguish. Returns a name list and its length. Pure, and it must be called before
-- ua_refine_parity: docs/MEASUREMENTS.md, 'ua_alts must run before ua_refine_parity'.
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

-- Fold the alternatives into sdec.fmt_note, keeping whatever ua_refine_parity put there. Candidates
-- naming the chosen format are dropped: after a 7E1 reclassification the list still holds that 7E1.
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

-- Decode an arbitrary sample array. serial_core's sig_levels / sig_edges / sig_idle must have run
-- over the same array first. Returns ok, reason.
function sdec.decode_from(rd, n)
  sdec.res, sdec.fmt_note, sdec.baud_note = nil, nil, nil
  sdec.baud_probe = nil                 -- set only by giveup(), and only for THIS call
  if rd == nil or n == nil or n < 2 then return false, 'nothing captured' end
  local fs = sdec.acq_fs or sdec.fs

  -- A failure past the bit-time stage must retract the bit time: a rate that frames nothing is noise.
  local function giveup(why)
    -- Keep the retracted rate for the one caller that can act on it. docs/MEASUREMENTS.md, 'The
    -- retracted bit time is kept for autoset'.
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
    -- snapfirm true alongside snapped: what is published here is exactly the rate that is locked, so
    -- a stale false from an earlier soft snap would print 'auto-locked 37700 baud?' about nothing.
  sdec.baud, sdec.baud_raw, sdec.snapped, sdec.snapfirm = sdec.force_baud, sdec.force_baud, true, true

    -- Cross-check the forced rate against the wire, the one dangerous failure this decoder has. The
    -- fit is the only evidence available that the forced number is wrong -- advisory, never fatal.
    -- docs/MEASUREMENTS.md, 'A forced rate the device is not using'.
    sdec.rate_note = nil
    -- sig_bittime() is not pure: it re-publishes bittime, baud, baud_raw, fitq, snapped and
    -- snapfirm, so the advisory call is fenced and lives in a local function.
    -- docs/MEASUREMENTS.md, 'sig_bittime() is not pure, so the advisory call is fenced'.
    local keepT, keepR, keepQ = sdec.bittime, sdec.fitratio, sdec.fitq
    local keepB, keepRaw, keepSnap = sdec.baud, sdec.baud_raw, sdec.snapped
    local keepFirm = sdec.snapfirm
    local function ratenote()
      local Tm = sdec.sig_bittime()
      if Tm == nil or Tm <= 0 then return end
      -- Only compare like with like: sig_bittime fits the greatest common period, so a fit that
      -- landed on a sub-multiple is a known artefact and would fire the warning on healthy captures.
      local ratio = Tm / T
      local near = nil
      local k
      for k = 1, 6 do
        if math.abs(ratio * k - 1) < 0.12 then near = k end
        if math.abs(ratio / k - 1) < 0.12 then near = k end
      end
      -- An integer rescaling is also exactly what a device running at a multiple of the forced rate
      -- looks like, so the measurement is stated rather than the disagreement suppressed.
      -- docs/MEASUREMENTS.md, 'An integer rescaling is ambiguous, not innocent'.
      if near ~= nil and near > 1 then
        local other = sdec.force_baud * near
        if ratio > 1 then other = sdec.force_baud / near end
        sdec.rate_note = string.format(
          -- docs/MEASUREMENTS.md, 'The note row clips, so the verdict leads'.
          'WARNING: bytes may be WRONG if the device runs at %.0f baud, %dx the %g you set',
          other, near, sdec.force_baud)
        return
      end
      local err = ratio - 1
      if math.abs(err) > (sdec.ratemargin or 0.04) then
        local meas = fs / Tm
        sdec.rate_note = string.format(
          -- Verdict first, same as the note above; the percentage loses its decimal to buy the room.
          'WARNING: bytes may be WRONG -- wire is %.0f baud, not the %g you set (%+.0f %%)',
          meas, sdec.force_baud, err * 100)
      end
    end
    ratenote()
    sdec.bittime, sdec.fitratio, sdec.fitq = keepT, keepR, keepQ
    sdec.baud, sdec.baud_raw, sdec.snapped = keepB, keepRaw, keepSnap
    sdec.snapfirm = keepFirm
  else
    -- sig_bittime() publishes bittime and baud as it goes, so both failures must retract them.
    local Tfit, why = sdec.sig_bittime()
    if Tfit == nil then return giveup(why or 'no bit timing') end
    local ratio, badwhy
    T, ratio, badwhy = sdec.ua_best(rd, n, Tfit)
    if T == nil then return giveup(badwhy or 'no usable bit time') end
    -- Re-measure the fit quality at the chosen bit time: sig_bittime left sdec.fitq
    -- describing its own proposal, so the FIT column reported a rejected candidate's quality.
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
    if sdec.force_invert ~= nil then
      r = sdec.ua_run_fmt(rd, n, T, sdec.force_nbits, par, nstop, sdec.force_invert)
      sdec.polwhy = nil
    else
      -- A locked format must still contest the polarity. Taking the level inference unopposed is the
      -- wrong answer on every capture of a ground-straddling line that holds no idle, and the format
      -- being locked is the common case because auto-lock locks it.
      local prior = (sdec.idle == 0)
      local why
      r, why = sdec.ua_pick_pol(sdec.ua_run_fmt(rd, n, T, sdec.force_nbits, par, nstop, prior),
                                sdec.ua_run_fmt(rd, n, T, sdec.force_nbits, par, nstop, not prior),
                                sdec.idle_weak)
      sdec.polwhy = why
    end
    if r.nf == 0 then return giveup('the forced format found no frames') end
  else
    r = sdec.ua_autoformat(rd, n, T)
    if r == nil then return giveup('no frame format fits the capture') end
    -- Order matters. Score the alternatives against the format the search chose; collapse always-one
    -- top data bits before testing the rest for parity, since stripping a bit changes what "the
    -- parity bit" would be; then compose one note.
    local anames, na = sdec.ua_alts(r)
    r = sdec.ua_refine_width(r, rd, n, T)
    -- rd/n/T go in because promotion to 7E1 re-decodes rather than shifting values.
    r = sdec.ua_refine_parity(r, rd, n, T)
    sdec.ua_note_fmt(r, anames, na)
  end

  sdec.res = r
  -- Keep the reported idle level consistent with what decoded: it overrides sig_idle's prior.
  if r.invert then sdec.idle = 0 else sdec.idle = 1 end
  return true
end

-- A locked rate the frames contradict is doubted, not defended; the alternative is the operator
-- typing 0 into Options to get detection back. docs/MEASUREMENTS.md, 'relock_badfrac = 0.25'.
sdec.relock_badfrac   = 0.25     -- interior frames in error before the lock is doubted
sdec.relock_minframes = 8        -- fewer frames than this and a bad fraction is not evidence

-- What happens when a forced rate is proved wrong -- 'adopt' or 'ask'. 'adopt' takes the detected
-- rate, rounds it to a credible boundary, locks it and says so on the note row. 'ask' refuses and
-- leaves the choice with the operator: rate_accept() takes the detected rate, rate_decline() keeps
-- theirs. Neither blocks on a human. docs/MEASUREMENTS.md, 'force_conflict defaults to adopt'.
sdec.force_conflict = sdec.force_conflict or 'adopt'

-- Fraction of interior frames that failed, or nil when there are too few to judge. Interior, because
-- head resync and a clipped tail fail on healthy captures too.
function sdec.ua_badfrac(r)
  if r == nil or (r.nf or 0) < 1 then return nil end
  local ninter = r.nf - sdec.ua_edge_frames - 1
  if ninter < 1 then return nil end
  local nin = sdec.ua_bad_interior(r)
  return nin / ninter
end

-- Runs the whole chain on an already-acquired capture. serial_core.acquire() leaves the levels, edges
-- and idle level in place; this adds bit timing, format and bytes. Returns ok, reason.
function sdec.decode()
  -- sdec.smp, not sdec.buf.readings (see acq_copy): a pass would otherwise pay IPC per sample.
  if sdec.smp == nil then return false, 'nothing captured' end
  -- relocked is cleared once per press by capture(), not per decode: autoset() re-captures, and the
  -- note saying the operator's lock was dropped has to survive that.
  local ok, why = sdec.decode_from(sdec.smp, sdec.nread)

  -- Three gates, and the third keeps a hand-typed rate safe: rate_note is set only when the measured
  -- bit time disagrees with the locked one, so a correct rate with a wrong format -- which also fails
  -- every frame -- leaves the lock alone. Frame path only: unlocking inside a stream would strand it.
  if sdec.force_baud == nil or sdec.rate_note == nil then return ok, why end

  -- Plain UART only. MIDI's 31250 is the MIDI 1.0 specification rather than a detection (see
  -- options_apply), so a capture that does not decode at it means the wire is not MIDI; and a LIN
  -- capture is full of framing errors by design. Gated by test_serial's 'MIDI pins 31250'.
  if sdec.proto ~= nil and sdec.proto ~= 'uart' then return ok, why end
  local bf = sdec.ua_badfrac(sdec.res)
  if bf == nil or bf < sdec.relock_badfrac then return ok, why end
  if (sdec.res.nf or 0) < sdec.relock_minframes then return ok, why end

  -- Unlock and decode the same samples again, keeping the result only if it beats the threshold that
  -- triggered this. docs/MEASUREMENTS.md, 'The relock retry has to earn it'.
  local was, bf0 = sdec.force_baud, bf
  sdec.force_baud = nil
  -- Or the warning about the abandoned rate outlives it: the no-lock branch does not clear this.
  sdec.rate_note = nil
  local ok2, why2 = sdec.decode_from(sdec.smp, sdec.nread)
  local bf2 = sdec.ua_badfrac(sdec.res)
  if ok2 and bf2 ~= nil and bf2 < sdec.relock_badfrac and sdec.baud ~= nil then
    local found = sdec.baud
    if sdec.force_conflict == 'adopt' then
      -- Lock it, rather than leaving the app unlocked and hoping autolock picks it up, and adopt the
      -- measurement rather than the relabelled snap. docs/MEASUREMENTS.md, 'Adopting a rate from the
      -- measurement when the snap was not firm'.
      if sdec.snapfirm == false and sdec.baud_raw ~= nil then found = sdec.baud_raw end
      local adopt = sdec.baud_round(found)
      sdec.force_baud = adopt
      -- snapfirm goes true with snapped: this rate was chosen deliberately and rounded to be typed.
      sdec.baud, sdec.snapped, sdec.snapfirm = adopt, true, true
      -- The format lock stays: this is the branch where the decode succeeded with the forced width,
      -- parity and stop count, so the format is evidenced. The back-off branch below drops it.
      sdec.relocked = string.format('%g baud fit nothing -- now locked to %.0f, which this capture reads',
                                    was or 0, adopt or 0)
      return ok2, why2
    end
    -- Refuse, and give the operator their rate back: report a disagreement, do not edit a setting.
    sdec.force_baud = was
    -- No bytes on screen. res holds the decode that proved the rate wrong -- correct bytes, at a rate
    -- being declined -- and showing them would be adopting by another route.
    sdec.res = nil
    sdec.rate_offer, sdec.rate_offer_from = found, was
    sdec.rate_refused = string.format(
        '%g baud fits nothing -- this capture reads %.0f. Options > Baud 0 restores detection.',
        was or 0, found or 0)
    return false, string.format('%g baud fits nothing; this capture reads %.0f', was or 0, found or 0)
  end
  -- No rate fit these samples, so there is nothing to adopt -- but the locked one failed too, so
  -- back off to auto and ask capture() for a fresh acquisition. Only what autolock chose is
  -- dropped; a typed width or parity is a decision.
  sdec.relocked = string.format('%g baud fits nothing, and no other rate fit either -- ' ..
                                'back to auto-detect', was or 0)
  sdec.rate_backoff = true
  sdec.force_baud = nil
  if sdec.autolock_set ~= nil then
    if sdec.autolock_set.nbits  then sdec.force_nbits  = nil end
    if sdec.autolock_set.par    then sdec.force_par    = nil end
    if sdec.autolock_set.nstop  then sdec.force_nstop  = nil end
    if sdec.autolock_set.invert then sdec.force_invert = nil end
    sdec.autolock_set = nil
  end
  -- The unlocked decode: another pass at the abandoned rate publishes rate_note about no lock.
  return ok2, why2
end

-- ============================================================================
-- Presentation
-- ============================================================================
-- "8N1", "7E2", ... from explicit fields, so a candidate can be named as well as the chosen format.
function sdec.ua_fmt_name(nbits, par, nstop)
  local p = 'N'
  if par == sdec.PAR_EVEN then p = 'E' end
  if par == sdec.PAR_ODD  then p = 'O' end
  return string.format('%d%s%d', nbits or 0, tostring(p), nstop or 0)
end

-- Falls back to the forced format, so a streaming capture names the format it is decoding with: the
-- modes that produce a file have no sdec.res, and '--' is wrong for the two values the operator set.
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
  -- %.0f because a locked rate came from a measurement and is fractional -- see serial_ui's mode_why.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    return string.format('%.0f baud', sdec.force_baud or 0)
  end
  if sdec.baud == nil then return '--' end
  -- %.0f here too: `snapped` is true for any forced rate (see decode_from), so this branch is not
  -- guaranteed a standard-rate integer. A snap that is not firm keeps the '?': the measurement sat
  -- further from the standard rate than the fit's own accuracy. See sdec.snaptol_firm.
  if sdec.snapped and sdec.snapfirm ~= false then return string.format('%.0f baud', sdec.baud or 0) end
  return string.format('%.0f baud?', sdec.baud or 0)
end

-- One printable character per byte; '.' for control and high-bit values so the column grid never
-- shifts, '?' for a frame that failed its stop or parity bit.
function sdec.ua_char(v, err)
  if err ~= nil then return '?' end
  if v == nil then return ' ' end
  if v >= 32 and v <= 126 then return string.char(v) end
  return '.'
end

-- The three summary lines, split so each fits the width: what the protocol is, what the wire looks
-- like, and how well it went.
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
    -- fs defended inside the division: the divide happens first, so `fs / 1000 or 0` still raises
    -- when both acq_fs and fs are nil, and capture_run() logs this line bare on its success tail.
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

-- A row of the hex view: "0000  48 65 6C 6C ...  |Hell...|". Hex and characters on the same row
-- deliberately: the text says what the device is saying, the hex says what the bytes are, and they
-- disagree exactly where it matters. Short rows are padded so the ASCII gutter stays aligned, an
-- unrecoverable value shows as '--', and the offset is decimal, these being stream positions rather
-- than addresses. One formatter serves the panel, the log's dump and a long stream's file.

-- Two groups of eight, with a gap, because the panel's font is proportional and the drift is
-- cumulative. docs/MEASUREMENTS.md, 'Why the hex row is two groups of eight'.
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

-- Width in characters of one hex group of `ncol` bytes: two chars each plus one separator between, so
-- the layout derives its columns. The gap between groups is layout (sdec.ui_col_gap2), not spaces.
function sdec.ua_hexwidth(ncol)
  local grp = sdec.ua_hexgroup or 0
  local extra = sdec.ua_hexgap or 0
  local w = ncol * 3 - 1                     -- 2 chars per byte + 1 separator between
  if grp > 0 and extra > 0 and ncol > 1 then
    w = w + extra * math.floor((ncol - 1) / grp)
  end
  return w
end

-- One hex+ASCII row as a single string, for a file or the debug log. Total for any vals content,
-- which is load-bearing rather than defensive, and a type test alone is not enough.
-- docs/MEASUREMENTS.md, 'ua_hexrow is total for any vals content'.
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
      -- Type and range. `v ~= v` is the nan test; floor(inf) == inf, so inf is caught by the bound
      -- rather than by it. docs/MEASUREMENTS.md, 'ua_hexrow is total for any vals content'.
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

-- The same row as separate pieces, for the on-screen dump's fixed-x text fields. Separate from
-- ua_hexrow rather than built on it: the file form keeps its '|ascii|' delimiters, and the screen
-- form drops them because vertical rule objects do that job at a fixed x.
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
  -- Four pieces: offset, first eight bytes, second eight bytes, ASCII. The two hex groups are
  -- separate display objects at fixed x; the ASCII field is not split to match, and cells are two
  -- characters joined by a separator. docs/MEASUREMENTS.md, 'Why the hex row is two groups of eight'.
  local half = math.floor(m / 2)
  local a, b, k = {}, {}, 0
  for k = 1, m do
    if k <= half then a[k] = hx[k] else b[k - half] = hx[k] end
  end
  return string.format('%04d', base + i0 - 1),
         table.concat(a, ' '), table.concat(b, ' '), table.concat(as)
end

-- The offset column is absolute, which for a frame capture is the same as relative and for a stream
-- tail is not: labelling a tail's first row 0000 makes the panel disagree with the file the same run
-- wrote. res.first is the tail's 1-based absolute start; a frame result has none, so the base is 0.
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

-- serial_core.tsp -- acquisition, signal conditioning and bit-timing recovery
-- for the DMM6500 serial decoder (TSP / Lua 5.0.2).
--
-- The PROTOCOL-INDEPENDENT layer:
--
--     levels  ->  threshold  ->  edge list  ->  pulse widths  ->  bit time
--
-- Each stage is a large data reduction. A Lua table read costs ~1.4 us here, so a
-- 20 000-sample capture is ~30 ms per pass; the edge list is a few hundred
-- entries, and protocol decoders work from that, not from the samples.
--
-- Decoding is single-shot, so a decode may take a second unnoticed. That affords
-- a least-squares bit-time fit over every pulse and a brute-force format search
-- (uart_decode.tsp) -- neither would fit a live frame budget.
--
-- Lua 5.0.2: no '#' (use table.getn), no bitwise operators, math.mod for modulo,
-- no '//'. Counts are tracked explicitly; it is cheaper than table.getn in loops.

sdec = sdec or {}   -- the single global this app exposes
-- Handles and captured state are DECLARED, not assigned.
-- Opening an installed App re-runs this whole script body, so a file-scope
-- `sdec.x = nil` would wipe the handle of a still-live object from the previous
-- launch and strand it inside the firmware until a power cycle -- the exact
-- accumulation that walks this firmware toward a PC=002F751C panic. A missing
-- table key already reads as nil, so declaring these in a comment is enough,
-- and anything with a real default uses `or` so a reload preserves it.


-- ---------- acquisition configuration ----------
-- EVERY RATE HERE DIVIDES 66 000 000 EXACTLY, and that is the whole rule.
--
-- Measured over 26 rates: the sample clock is 66 MHz with an INTEGER divider, rounded UP --
-- fs_actual = 66e6 / ceil(66e6 / fs_requested). The model predicts all 25 accepted rates to
-- within 4.3e-7, so a rate is exact if and only if 66e6 is divisible by it.
--
-- 66e6 = 2^7 * 3 * 5^6 * 11. So 120000 is exact and
-- 160000 = 2^8*5^4 is not -- it wants one more factor of two than the clock has.
--
-- fs_for_baud snaps UP to the lowest listed rate at or above baud x 8, so holes in the ladder are
-- spent oversampling. Hence the wide set: 38400 gets 320 k rather than 500 k.
--
-- 1000 is the FLOOR: 900 is rejected outright (error 1130), so dmm.digitize.samplerate does
-- not go below 1 kS/s.
--
-- THREE INEXACT RATES ARE LISTED ANYWAY: 160000, 320000 and 640000, off by -0.121 %, -0.362 % and
-- -0.841 %. They are exactly what 19200, 38400 and 76800 need; without them those three -- the
-- commonest rates on a bit-banged micro -- snap up a whole step and get 192, 192 and 153 bytes per
-- capture instead of 240 each.
--
-- Safe because the shortfall is downward and tiny: 8.32, 8.30 and 8.26 samples/bit, all above the 8
-- the selector asked for, and every bit time is scaled by acq_fs rather than by the requested rate.
-- 350000 is omitted only because no standard baud rate wants it.
--
-- The true rate is still re-derived from buffer timestamps after every capture (sdec.acq_fs),
-- because the readback lies for any rate the hardware cannot synthesise -- and for these three
-- it certainly does.
sdec.rates      = {1000, 1250, 2500, 5000, 10000, 15000, 20000, 30000, 40000,
                   50000, 60000, 80000, 100000, 120000, 160000, 200000, 250000,
                   300000, 320000, 400000, 500000, 640000, 1000000}
sdec.fs         = 1000000   -- requested sample rate
-- sdec.acq_fs             -- rate MEASURED from relativetimestamps; the one we use
-- Capture depth. The pre-trigger reserve comes out of buffer CAPACITY, so acq_cap() asks for it
-- on top and an armed capture delivers the full depth -- measured 20050-20350 readings, against
-- 19011 for a buffer sized exactly n.
sdec.n          = 20000     -- capture depth, samples (see sdec.acq_cap)
-- FIXED at the 10 V range, and not an option. It has the widest digitize bandwidth of
-- any range -- 440 kHz, against 210 kHz on 1 V and 100 mV and only 17 kHz on 100 V and
-- 1000 V -- so it is simultaneously the most capable choice and the simplest. Nothing
-- worth decoding swings under 1 V, and anything swinging over 10 V wants a divider
-- (docs/lin-divider-panel.png). A constant, so unlike range-as-a-setting it is safe to
-- assign unconditionally on reload.
sdec.range      = 10
sdec.probe_n    = 2000      -- samples in the level-learning probe capture
-- Sample rates the free-run auto-detect probe tries, in order. Each covers TEN TIMES as long for
-- the same sample count -- 20 ms, 200 ms, 2 s at sdec.n = 20 000 -- because a window shorter than
-- one frame cannot see a slow line at all: 20 ms at 1 MS/s is less than a 300-baud frame's 33 ms.
-- Every entry must be in sdec.rates.
sdec.probe_fs = sdec.probe_fs or {1000000, 100000, 10000}
sdec.pretrig    = 5         -- pre-trigger percentage for the analog-trigger path
-- 'edge' (analog trigger on the signal itself), 'free' (untriggered) or 'front' (the physical
-- TRIGGER key). The rear EXT TRIG IN is NOT a mode -- it is sdec.trigext, an orthogonal
-- checkbox that OR's the rear BNC into whichever of these is selected.
sdec.trigmode   = sdec.trigmode or 'edge'
-- Booleans need an explicit nil test: `or false` would resurrect a deliberate true, and this is
-- operator state that must survive an App relaunch. OFF by default -- a serial decoder must work
-- with one probe and nothing else attached.
if sdec.trigext == nil then sdec.trigext = false end
-- FLOW CONTROL OUT: pulse the rear EXT TRIG OUT once the instrument is armed, as a "send the next
-- frame" credit to a device that waits for it. Off by default and an explicit nil test, like
-- trigext -- it drives a rear BNC that may be wired to other equipment, so it must be asked for.
--
-- Not CTS: trigger.extout has no settable level, only assert(), which emits a pulse. So this is
-- credit-based and block-granular -- one pulse per window -- which
-- suits an instrument whose unit of work is a window rather than a byte.
if sdec.fc_out == nil then sdec.fc_out = false end
-- Requested pulse width, and IT IS NOT APPLIED ON THIS FIRMWARE. `trigger.extout.pulsewidth` is NIL
-- on 1.7.17a, so fc_config() skips the assignment and the width is the firmware default.
--
-- THE DEFAULT IS ABOUT 10 us, MEASURED -- not the 100 us requested here. On an SDS1204X-E at
-- 1 GSa/s, armed SINGLE on the rising edge: 9.41 us and 9.82 us on two trials, 4.92 V peak,
-- -0.96 V baseline. So a device meant to wait for a credit needs an EDGE-TRIGGERED input, an
-- interrupt or a latch: 10 us is 2.5 bit times at 250 kBd, and a firmware polling a GPIO in a loop
-- can miss it entirely. That consequence is in the manual, because it decides whether flow control
-- works for a given device.
--
-- The value is kept because it is the right REQUEST: wide enough for a micro polling in a loop rather
-- than one that must catch an interrupt -- 100 us is 25 bit times at 250 kBd and a comfortable number
-- of instructions even on a 1 MHz part -- and a firmware or model that does expose pulsewidth will
-- get it.
sdec.fc_pulse = sdec.fc_pulse or 100e-6
-- BOTH trigger timeouts BELONG HERE, next to the only code that reads them.
--
-- Declaring either of them in serial_app.tsp instead leaves it nil when serial_core is loaded on its
-- own, and `while waited < wait` then compares a number with nil, which RAISES. Inside
-- acq_triggered's pcall that surfaces as "edge trigger unavailable; captured free-running" -- a
-- missing default reported as absent hardware, on an instrument whose analog trigger is working
-- perfectly.
sdec.trigwait     = sdec.trigwait or 3.0        -- seconds to wait for a start-bit edge
sdec.trigwait_ext = sdec.trigwait_ext or 30.0   -- see acq_triggered: a person or a DUT event
-- sdec.buf                -- capture buffer handle
-- sdec.smp                -- the capture as a PLAIN Lua array (see acq_copy)
sdec.nread      = sdec.nread or 0

-- ---------- signal conditioning results ----------
-- sdec.vmin, sdec.vmax          -- raw extremes of the capture
-- sdec.lo, sdec.hi              -- the two logic levels, volts
sdec.swing           = sdec.swing or 0     -- hi - lo
sdec.thr             = sdec.thr or 0       -- decision threshold, volts
sdec.hyst            = sdec.hyst or 0      -- hysteresis half-width, volts
sdec.hystfrac        = 0.15       -- hysteresis as a fraction of the swing
sdec.minswing        = 0.10       -- below this the line is treated as dead, volts
sdec.family          = '?'        -- inferred logic family, for the summary line

-- ---------- edge list ----------
-- ei[k] is a FRACTIONAL 1-based sample position (sample i is at time (i-1)/fs),
-- interpolated to the threshold crossing. At 115200 baud and 1 MS/s there are
-- 8.68 samples per bit, so grid-quantised edges carry up to +-5.8 % of a bit time
-- -- enough to walk the mid-bit sampling point into the next bit across a 10-bit
-- frame. Interpolation costs one divide per edge.
sdec.ne  = sdec.ne or 0
-- sdec.ei          -- fractional sample position of each edge
-- sdec.es          -- physical level AFTER edge k: 1 = high, 0 = low
sdec.st0 = sdec.st0 or 1    -- physical level at the start of the capture
sdec.maxback = 64   -- how far to walk back from a hysteresis trip for the crossing

-- ---------- bit timing ----------
-- sdec.bittime      -- bit period in SAMPLES (the native unit here)
-- sdec.baud_raw     -- fs / bittime, unrounded
-- sdec.baud         -- snapped to a standard rate when close enough
sdec.fitq     = sdec.fitq or 0    -- 0..1 quality of the least-squares fit
sdec.snapped  = sdec.snapped or false
sdec.snaptol  = 0.02  -- snap when within 2 % of a standard rate
sdec.maxmult  = 12    -- a gap longer than this many bit times is idle, not data

-- Standard rates, including a few worth recognising by name: 31250 is MIDI and
-- 250000 is DMX512, both of which show up on a bench.
--
-- 153600 IS HERE BECAUSE ITS ABSENCE COST A WHOLE BENCH SESSION. The ladder jumped 128000 -> 230400,
-- so a 153.6 kBd line -- 8 x 19200, and the next doubling anyone sweeping upward reaches -- could not
-- snap: the nearest listed rate is 20 % away. Nothing decoded wrongly, but autolock_try()'s FIRST
-- gate is `snapped`, so the rate was never pinned; the recording modes are gated on a lock, so they
-- stayed unarmed; and the only way in was to type the raw figure into Options by hand. Pinned by
-- hand, an 8 kB recording at 153588 baud captured and decoded correctly -- so the rate was always
-- usable and the ladder was the only thing refusing it.
--
-- No new ambiguity: 153600 sits 20 % from 128000 and 33 % from 230400, against a 2 % snaptol.
--
-- 172800 (9x) and 192000 (10x) are here for the same reason, found the same way: the ladder had
-- nothing between 153600 and 230400, so a 192 kBd line reported a raw 191993 with a question mark and
-- needed a Lock Rate press to pin. Both are FRAME-ONLY -- see below -- but snapping still buys the
-- green padlock and the auto-lock instead of a manual press.
--
-- Spacing checked against the 2 % snaptol: 153600 -> 172800 is 12.5 %, 172800 -> 192000 is 10 %,
-- 192000 -> 230400 is 17 %. No new ambiguity anywhere in the group.
--
-- 307200 is the next doubling and is NOT here, because sdec.maxbaud is 250000 and the detector
-- rejects anything above it -- adding the rate without raising that would list a rate it refuses.
--
-- WHICH OF THESE CAN RECORD is a separate question from whether they decode, and the answer follows
-- from fs_for_burst(): the burst path loses acq_overhead per sample, so the crossover is at
-- 1/(4*(1/1e6 + 5.1e-7)) = 165563 Bd. 153600 is therefore the FASTEST STANDARD RATE THAT CAN RECORD
-- (4.31 samples/bit delivered); 172800 and above are frame-only. Frame decodes to the full 250000.
sdec.stdbaud = {110, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600, 14400,
                19200, 28800, 31250, 38400, 57600, 76800, 115200, 128000,
                153600, 172800, 192000, 230400, 250000, 460800, 921600}

-- ============================================================================
-- Level detection
-- ============================================================================
-- THE TWO LOGIC LEVELS ARE THE TWO DENSEST AMPLITUDES, and everything here follows
-- from working outward from that density rather than inward from the extremes.
--
-- Inward from the extremes is what a percentile trim does, and it fails because the
-- trim fraction has to be guessed against an unknown outlier count. Measured: eight
-- 2-sample 25 V spikes on a 0/3.3 V line are 16 samples in 1400 -- 1.1 %, over a
-- 0.5 % budget -- so the trimmed upper bound landed INSIDE the spikes, the high-group
-- mean was dragged to ~12 V, the threshold went with it, and the edge list collapsed
-- from 80 edges to 12. The decoder then fitted the 2-sample spike pairs and reported
-- 47427 baud with six confident-looking bytes. Perversely, FORTY spikes worked,
-- because past the trim budget the bound landed outside them again.
--
-- Density has no such budget. A logic level holds hundreds of samples in one or two
-- bins; spikes of differing amplitude scatter one or two samples per bin, and even a
-- wide spike train loses to the minority logic level on count. So: find the densest
-- bin, then the densest bin at least minswing away from it. Nothing has to be assumed
-- about how many outliers there are or how far out they sit.

-- BIN COUNT IS ADAPTIVE, capped here. A fixed 512 bins over a 2000-sample probe
-- averages four samples a bin, and at that occupancy Poisson scatter alone drops the
-- occasional bin below any sensible threshold -- one such dip inside the idle hump
-- ended the width walk early, left the rest of the SAME hump looking like a separate
-- level, and put both levels within 0.35 V of each other on a 3.3 V line. Sixteen
-- samples a bin keeps the scatter far below the hump threshold.
sdec.nbins     = 512
sdec.binocc    = 16    -- target samples per BIN
-- Minimum samples in the minority HUMP for it to count as a logic level. A different
-- quantity from binocc despite the similar name -- see the gate in sig_pair for why it is
-- 2 and why a larger value buys nothing.
sdec.minhump   = 2
sdec.flatfloor = 1.0    -- below this an idle level counts as sitting at ground
sdec.flatoffs  = 0.5    -- and the guessed threshold goes this far above it
-- Share of samples sitting at one of the two levels. A clean line is ~0.95. It falls
-- with anything that spreads the samples out, and the two thresholds separate the two
-- meanings of that:
--
--   below warnmodal  the baseline is unstable -- said on the note line, but DECODED,
--                    because a drifting line still yields the right bit time. 1 V of
--                    drift on a 3.3 V swing measures 0.45 modal and 10.36 samples/bit
--                    against a true 10.42, so refusing it would throw away a good
--                    answer over a cosmetic complaint.
--   below minmodal   there are no logic levels, only noise. Refused.
sdec.minmodal  = 0.15
sdec.warnmodal = 0.50

-- Bins at or above humpfrac of a peak's own height count as part of that peak. This
-- MEASURES each hump's width rather than assuming one, which is the whole trick: the
-- separation between the two levels cannot be a fixed voltage, because noise widens
-- the humps. Requiring a fixed minswing gap instead put both "modes" 14 bins apart on
-- opposite flanks of the SAME hump as soon as the noise spread exceeded 0.1 V.
sdec.humpfrac = 0.2

-- The two densest amplitudes within [v0, v1]. Returns lo, hi, modal -- the share of
-- in-range samples belonging to either hump -- or nil when no pair is separable.
--
-- Each level is the TRUE MEAN of the samples in its hump, from one more pass over the capture --
-- not the histogram's own moment, and not a bin centre. See the membership-by-bin-index note below.
function sdec.sig_pair(rd, n, v0, v1)
  local floor = math.floor
  local nb = floor(n / sdec.binocc)
  if nb > sdec.nbins then nb = sdec.nbins end
  if nb < 24 then nb = 24 end
  if v0 == nil or v1 == nil or v1 <= v0 then return nil end
  local scale = (nb - 1) / (v1 - v0)
  local hist = {}
  local i
  for i = 1, nb do hist[i] = 0 end
  local cnt = 0
  for i = 1, n do
    local v = rd[i]
    if v ~= nil and v >= v0 and v <= v1 then
      local b = floor((v - v0) * scale) + 1
      hist[b] = hist[b] + 1
      cnt = cnt + 1
    end
  end
  if cnt < 4 then return nil end

  local m1, c1 = 1, -1
  for i = 1, nb do
    if hist[i] > c1 then m1, c1 = i, hist[i] end
  end

  -- Extent of the tallest hump.
  local edge = sdec.humpfrac * c1
  if edge < 1 then edge = 1 end
  local a1, b1 = m1, m1
  while a1 > 1 and hist[a1 - 1] >= edge do a1 = a1 - 1 end
  while b1 < nb and hist[b1 + 1] >= edge do b1 = b1 + 1 end

  -- The tallest bin OUTSIDE that hump. Spikes cannot win this: differing amplitudes
  -- scatter them one or two samples to a bin, while the minority logic level holds
  -- hundreds. Broadband noise cannot win either -- its single hump swallows the whole
  -- range, leaving nothing outside, and the capture is correctly refused.
  local sep = floor(sdec.minswing * scale)
  if sep < 1 then sep = 1 end
  local m2, c2 = nil, -1
  for i = 1, nb do
    if i < a1 or i > b1 then
      local d = i - m1
      if d < 0 then d = -d end
      if d >= sep and hist[i] > c2 then m2, c2 = i, hist[i] end
    end
  end
  if m2 == nil or c2 < 1 then return nil end

  local edge2 = sdec.humpfrac * c2
  if edge2 < 1 then edge2 = 1 end
  local a2, b2 = m2, m2
  while a2 > 1 and hist[a2 - 1] >= edge2 and (a2 - 1 < a1 or a2 - 1 > b1) do
    a2 = a2 - 1
  end
  while b2 < nb and hist[b2 + 1] >= edge2 and (b2 + 1 < a1 or b2 + 1 > b1) do
    b2 = b2 + 1
  end

  -- Each level is the TRUE MEAN of the samples inside its hump, from one more pass
  -- over the capture rather than from the histogram's own moment. A clean line puts a
  -- whole level in a single bin, and a binned moment then reports that bin's position
  -- rather than the level -- worth up to a bin width of bias, which lands directly on
  -- sdec.thr and from there on the analog trigger level.
  --
  -- MEMBERSHIP IS BY BIN INDEX, recomputed with the identical expression the histogram
  -- pass used -- NOT by re-deriving each hump's voltage band as v0 + (a-1)/scale and
  -- comparing volts. That round trip loses, and it lost in production:
  --
  --   a clean 0 / 3.300 V capture, 2272 samples, so nb = 142 and scale = 141/3.3.
  --   The tallest hump is the single bin 142 holding vmax itself, and its re-derived
  --   lower edge v0 + 141/scale came out 4.44e-16 V ABOVE vmax -- 1.9e-14 of a bin.
  --   Not one sample fell in the band, na was 0, and sig_pair returned nil: "line is
  --   idle (no transitions)" on a textbook waveform.
  --
  -- It is LENGTH-DEPENDENT, which is what makes it nasty rather than merely wrong: the
  -- same waveform at 13, 14, 16 and 17 bytes round-trips exactly and only 15 bytes
  -- fails, so it presents as one capture in five inexplicably seeing a dead line --
  -- indistinguishable at the bench from a probe on the wrong pin.
  --
  -- Comparing bins cannot drift, because the humps were CHOSEN by bin index. It also
  -- fixes a quieter inconsistency: the voltage test was inclusive at both ends while
  -- the histogram assigns by floor(), i.e. half-open, so a sample sitting exactly on
  -- the boundary between the two humps could be averaged into the wrong one.
  local sa, na, sb, nbb = 0, 0, 0, 0
  for i = 1, n do
    local v = rd[i]
    if v ~= nil and v >= v0 and v <= v1 then
      local b = floor((v - v0) * scale) + 1
      if b >= a1 and b <= b1 then
        sa = sa + v
        na = na + 1
      elseif b >= a2 and b <= b2 then
        sb = sb + v
        nbb = nbb + 1
      end
    end
  end
  -- A HUMP OF ONE SAMPLE IS NOT A LEVEL. That is the whole job of this gate, and the
  -- number is deliberately the MINIMUM that does it rather than something larger.
  --
  -- WHY 2 AND NOT 16, WHICH IS WHAT THIS FIRST SHIPPED AS. Two measurements, both of which
  -- said the same thing:
  --
  --   * `binocc` is a PER-BIN occupancy target -- the count at which Poisson scatter inside
  --     one bin stops mattering. `nbb` is a whole HUMP's total. Using one for the other was a
  --     category error, and review caught it.
  --   * sweeping the gate from 2 to 16 changes NOTHING about noise rejection: 31 of 40
  --     uniform-noise seeds are refused at every value in that range, and gaussian-shaped
  --     noise is refused at none of them. So this gate is not what refuses noise in general.
  --     The hump-swallowing test is, where it applies, and everything else is caught further
  --     down by `modal < minmodal` or by sig_bittime finding no usable pulse widths.
  --
  -- So a large gate buys no noise rejection and costs real signals: at 16 it refused a sparse
  -- burst -- one short message in a long recording, which is exactly the traffic the streaming
  -- modes exist for -- because a decimated view of it holds only a few samples at the space
  -- level. The minimum that kills a one-sample hump is 2.
  if na < 1 or nbb < sdec.minhump then return nil end
  local v1m, v2m = sa / na, sb / nbb
  if v2m < v1m then v1m, v2m = v2m, v1m end
  return v1m, v2m, (na + nbb) / cnt
end

-- Every field the signal chain MEASURES, back to its power-on value. Called from sdec.acquire(), so
-- it runs before every acquisition, and from sdec.clear_result(), so a press that refuses before it
-- ever acquires still leaves nothing behind for the next one.
--
-- THE RULE: A CAPTURE MUST NOT INHERIT A MEASUREMENT FROM THE CAPTURE BEFORE IT. Rate, format and
-- polarity are derived FROM THE SIGNAL, and a value carried across a capture boundary turns that
-- derivation into a feedback loop -- the app's own previous answer becomes an input to the next one.
-- Measured on the instrument, on a 19200 line: a leftover 500 kS/s makes a 19200 bit 26.04 samples,
-- the width fit lands on 8.679 -- exactly one third -- 57600 is reported with nbad 0, and
-- pick_fs(57600) writes 500 kS/s back for next time. It is a two-state flip-flop rather than a
-- one-way latch, so clearing once is not enough; it has to be every time.
--
-- WHY THESE ARE NOT ALREADY ON clear_result()'S LIST. That list drops the RESULT -- bytes, notes,
-- levels, edges. These are the intermediate MEASUREMENTS the search runs on, and each has a writer
-- that only reaches it on the good path: sig_bittime() returns 'need at least two edges' without
-- touching w/nw/wmed, and acq_fs is only rewritten by a read that came back with samples. Every one
-- is re-derived by any capture that gets that far, so clearing them can only remove a wrong answer.
--
-- WHAT IS DELIBERATELY LEFT ALONE, each for a reason of its own:
--   * sdec.force_baud/nbits/par/nstop/invert -- the lock. Operator state, shown by the padlock, and
--     sdec.unlock_all() is how it goes.
--   * sdec.lvl_thr/lvl_hyst/lvl_swing -- the recording watchdog's fallback threshold, kept ACROSS
--     captures on purpose: under flow control the device is silent until the credit pulse goes out,
--     so the probe that normally supplies a threshold looks at an idle line. See sig_levels.
--   * sdec.buf -- a live firmware handle under the delete -> nil -> create rule.
--   * sdec.flog_path/flog_n/flog_bytes -- the byte log, which spans captures by design.
function sdec.clear_measured()
  -- The MEASURED sample rate and the flag saying it was not measured. Every bit time, the baud
  -- rate and therefore every byte is scaled by this one number.
  sdec.acq_fs, sdec.acq_fs_est = nil, nil
  -- The pulse widths and their median. sdec.wmed GATES candidate rates in ua_cands(), so a stale
  -- one rejects the true bit time of the capture in hand.
  sdec.w, sdec.nw, sdec.wmed = nil, 0, nil
  -- Polarity, and the flag saying the evidence for it was thin.
  sdec.idle, sdec.idle_weak = nil, nil
  -- Level and run statistics: the fraction of samples near the two levels, and the longest run of
  -- each. sig_idle() reads st0, so it goes back to its declared default rather than to nil.
  sdec.modal, sdec.run0, sdec.run1 = nil, nil, nil
  sdec.st0 = 1
  return true
end

-- Returns ok, reason. Sets lo/hi/thr/hyst/swing/family, wlo/whi, modal, and the remembered
-- lvl_thr/lvl_hyst/lvl_swing that serial_app saves and restores.
function sdec.sig_levels(rd, n)
  local vmin, vmax, nv = nil, nil, 0
  local i

  for i = 1, n do
    local v = rd[i]
    if v ~= nil then
      nv = nv + 1
      if vmin == nil then
        vmin, vmax = v, v
      else
        if v < vmin then vmin = v end
        if v > vmax then vmax = v end
      end
    end
  end
  if vmin == nil then
    sdec.vmin, sdec.vmax, sdec.swing = nil, nil, 0
    sdec.lo, sdec.hi, sdec.thr, sdec.hyst = nil, nil, 0, 0
    sdec.wlo, sdec.whi = nil, nil
    sdec.family = '?'
    return false, 'capture is empty'
  end
  sdec.vmin, sdec.vmax = vmin, vmax
  sdec.modal = nil

  -- Pass one over the full extremes locates the pair coarsely. Its bin width is set
  -- by the furthest outlier, so with a 200 V spike on a 3.3 V line the two levels land
  -- only four bins apart -- separable, but far too coarse to measure. Pass two re-bins
  -- over a window holding just the swing, where the levels resolve properly.
  --
  -- Run ONLY when the raw extremes are much wider than the swing, i.e. when something
  -- really is far outside it. Otherwise pass one is already well scaled and re-binning
  -- over a padded window would make the resolution WORSE, not better.
  local lo, hi, modal = sdec.sig_pair(rd, n, vmin, vmax)
  if lo ~= nil and (vmax - vmin) > 3 * (hi - lo) then
    local pad = 0.5 * (hi - lo)
    if pad < sdec.minswing then pad = sdec.minswing end
    local lo2, hi2, modal2 = sdec.sig_pair(rd, n, lo - pad, hi + pad)
    if lo2 ~= nil and modal2 >= modal then lo, hi, modal = lo2, hi2, modal2 end
  end

  if lo == nil or hi - lo < sdec.minswing then
    -- No separable pair: a flat line, or a swing too small to call. Report the case
    -- rather than placing a threshold in the middle of one level and manufacturing
    -- edges out of ADC noise.
    sdec.wlo, sdec.whi = vmin, vmax
    sdec.lo, sdec.hi = vmin, vmax
    sdec.thr, sdec.hyst = 0.5 * (vmin + vmax), 0
    sdec.swing = vmax - vmin
    sdec.family = sdec.sig_family(vmin, vmax)
    if lo ~= nil then
      sdec.lo, sdec.hi, sdec.swing = lo, hi, hi - lo
      sdec.thr = 0.5 * (lo + hi)
      sdec.family = sdec.sig_family(lo, hi)
      return false, string.format('swing only %.3f V', hi - lo)
    end
    return false, 'line is idle (no transitions)'
  end

  sdec.wlo, sdec.whi = lo, hi        -- the working range, for diagnostics
  sdec.lo, sdec.hi = lo, hi
  sdec.modal = modal
  sdec.swing = hi - lo
  sdec.thr   = 0.5 * (lo + hi)
  sdec.hyst  = sdec.hystfrac * sdec.swing
  sdec.family = sdec.sig_family(lo, hi)
  -- Two humps holding almost none of the samples are not a pair of logic levels --
  -- that is broadband noise, or a signal buried in it.
  if modal < sdec.minmodal then
    return false, string.format('no clear logic levels (%.0f %% of samples near them)',
                                100 * modal)
  end
  -- REMEMBERED ACROSS CAPTURES, unlike sdec.thr, which clear_result() zeroes at the top of every
  -- one. A recording's idle watchdog needs a threshold before the device has said anything, and
  -- under flow control the device is SILENT until the credit pulse goes out -- so the probe that
  -- normally supplies the threshold looks at an idle line and finds nothing, leaving the watchdog
  -- disarmed exactly where it matters most. stream_begin() falls back to these when its own probe
  -- comes up empty.
  --
  -- AFTER THE MODAL GATE, NOT BEFORE IT. Set above the check, a capture this function has just
  -- refused as "no clear logic levels" would overwrite the last levels it trusted -- so a single
  -- noisy look could poison the watchdog threshold for every recording after it. Only a measurement
  -- good enough to return true is good enough to keep.
  sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = sdec.thr, sdec.hyst, sdec.swing
  return true
end

-- Wire-quality warning about the levels themselves, for the note line. Separate from
-- sig_quality, which is about the sample rate.
function sdec.sig_levelwarn()
  if sdec.modal == nil then return nil end
  if sdec.modal >= sdec.warnmodal then return nil end
  return string.format('baseline unstable -- only %.0f %% of samples sit at a logic level (drift or noise)',
                       100 * sdec.modal)
end

-- Name the logic family from the measured levels: the fastest way to spot a probe
-- on the wrong pin, and RS-232 mistaken for TTL is the usual cause of nothing.
function sdec.sig_family(lo, hi)
  if lo == nil or hi == nil then return '?' end
  if lo < -1.5 and hi > 1.5 then return 'RS-232' end
  if hi >= 4.0 and hi <= 5.75 then return '5V TTL' end
  if hi >= 2.7 and hi < 4.0 then return '3V3 CMOS' end
  if hi >= 1.6 and hi < 2.7 then return '1V8 CMOS' end
  return string.format('%.1fVpp', hi - lo)
end

-- ============================================================================
-- Edge extraction
-- ============================================================================
-- Fractional position of the threshold crossing at or before sample i.
--
-- Hysteresis makes this necessary: the trip is detected once the signal has passed
-- thr +- hyst, so thr itself is crossed one or more samples before that -- several on
-- a slow RS-232 edge. Walking back to the straddling pair keeps edge positions
-- independent of the hysteresis setting, which matters because the bit-time fit
-- reads them as timing.
function sdec.sig_cross(rd, i, thr)
  local j   = i
  local lim = i - sdec.maxback
  if lim < 2 then lim = 2 end
  while j >= lim do
    local a, b = rd[j-1], rd[j]
    if a ~= nil and b ~= nil then
      local da, db = a - thr, b - thr
      if (da < 0 and db >= 0) or (da >= 0 and db < 0) then
        local d = b - a
        if d == 0 then return j end
        local f = (thr - a) / d
        if f < 0 then f = 0 end
        if f > 1 then f = 1 end
        return (j - 1) + f
      end
    end
    j = j - 1
  end
  return i        -- no straddling pair in range: fall back to the trip sample
end

-- Build the edge list. Returns the edge count.
function sdec.sig_edges(rd, n)
  local thr = sdec.thr
  local hy  = sdec.hyst
  local hiT, loT = thr + hy, thr - hy
  local cross = sdec.sig_cross
  local ei, es = {}, {}
  local ne = 0
  local st = nil
  local i

  for i = 1, n do
    local v = rd[i]
    if v ~= nil then
      if v >= thr then st = 1 else st = 0 end
      break
    end
  end
  if st == nil then
    sdec.ne, sdec.ei, sdec.es, sdec.st0 = 0, ei, es, 1
    return 0
  end
  sdec.st0 = st

  for i = 2, n do
    local v = rd[i]
    if v ~= nil then
      if st == 1 then
        if v < loT then
          ne = ne + 1
          ei[ne] = cross(rd, i, thr)
          es[ne] = 0
          st = 0
        end
      else
        if v > hiT then
          ne = ne + 1
          ei[ne] = cross(rd, i, thr)
          es[ne] = 1
          st = 1
        end
      end
    end
  end

  sdec.ne, sdec.ei, sdec.es = ne, ei, es
  return ne
end

-- Which physical level is idle (the UART mark level): the level holding the
-- LONGEST single run. Correct whenever the capture has any inter-byte gap, and it
-- separates TTL (idle high) from RS-232 (idle low) without being told.
--
-- A gapless stream of 0x00 defeats it -- start bit plus eight zero data bits is a
-- nine-bit low run against a one-bit stop -- so this is only a PRIOR.
-- sdec.ua_autoformat scores both polarities and lets frame errors decide.
function sdec.sig_idle(rd, n)
  local ne, ei, es = sdec.ne, sdec.ei, sdec.es
  if ne == 0 then
    sdec.run1, sdec.run0 = 0, 0
    sdec.idle = sdec.st0
    return sdec.st0
  end

  local best1, best0 = 0, 0
  local lead = ei[1] - 1
  if sdec.st0 == 1 then
    if lead > best1 then best1 = lead end
  else
    if lead > best0 then best0 = lead end
  end

  local k
  for k = 1, ne - 1 do
    local len = ei[k+1] - ei[k]
    if es[k] == 1 then
      if len > best1 then best1 = len end
    else
      if len > best0 then best0 = len end
    end
  end

  local tail = n - ei[ne]
  if es[ne] == 1 then
    if tail > best1 then best1 = tail end
  else
    if tail > best0 then best0 = tail end
  end

  sdec.run1, sdec.run0 = best1, best0

  -- A RUN IS ONLY EVIDENCE OF IDLE IF DATA COULD NOT HAVE PRODUCED IT.
  --
  -- MEASURED AT THE BENCH, real 9600-baud ASCII into the front
  -- terminals: run0 = 63 samples, run1 = 42, and longest-run therefore said
  -- idle = 0 on a line that idles HIGH. Both runs are DATA. 63 samples at 10.42
  -- samples/bit is six bits -- a space, 0x20, whose start bit plus five zero data
  -- bits run together -- and 42 is the four 1-bits of a lowercase letter. The
  -- window held no idle at all, so the longest run was never idle to begin with.
  --
  -- WHY THAT WAS WORSE THAN A COIN TOSS. ua_autoformat makes this prior the
  -- incumbent and requires a rival polarity to beat it by 60 %, and the inverted
  -- reading of an ASCII stream frames just as cleanly as the correct one: ASCII's
  -- top data bit is always 0, which puts a rising edge exactly nine bit times
  -- after every start bit -- a perfectly periodic FAKE start edge. At 57600 baud
  -- the inverted reading scored 218 good frames and 0 bad. Self-consistent,
  -- confident, and every byte wrong. A wrong prior that no evidence can overturn
  -- is worse than no prior.
  --
  -- At 8N1 the longest run data can make is nine bit times (start + eight zeros,
  -- or eight ones + stop), so ten bit times is the smallest run that must be idle.
  -- One bit time is estimated as a low percentile of the pulse widths rather than
  -- their minimum, so a single narrow glitch cannot shrink it.
  local onebit = sdec.sig_onebit(ei, ne)
  local longest = best1
  if best0 > longest then longest = best0 end
  if onebit ~= nil and longest < 10 * onebit then
    -- The runs carry no information about idle. Decide from the LEVELS instead,
    -- which is a fact about signalling rather than a guess about this capture: a
    -- single-supply logic line marks HIGH, and one that straddles ground is RS-232
    -- at line levels and marks at its NEGATIVE level.
    --
    -- This is wrong for an inverted TTL line with no idle in the window -- MIDI's
    -- current-loop receiver side, or a deliberately inverted debug pin. That case
    -- keeps working whenever the window DOES contain idle, which is every bursty
    -- line, and Options -> Invert forces it otherwise. Being right about ordinary
    -- UART is worth more than being undecided about all of it.
    sdec.idle_weak = true
    if sdec.lo ~= nil and sdec.hi ~= nil and
       sdec.lo < -sdec.flatfloor and sdec.hi > sdec.flatfloor then
      sdec.idle = 0
    else
      sdec.idle = 1
    end
    return sdec.idle
  end

  sdec.idle_weak = false
  if best1 >= best0 then sdec.idle = 1 else sdec.idle = 0 end
  return sdec.idle
end

-- One bit time in samples, from the EDGE LIST, before any bit-time fit has run.
--
-- FROM ei, NOT FROM sdec.w. sdec.w is populated by sig_bittime(), which runs
-- during decode -- i.e. AFTER sig_idle -- so at this point sdec.w is either nil or left over from
-- the previous capture.
--
-- A LOW PERCENTILE, NOT THE MINIMUM. Most pulses on a UART line are one or two
-- bits, so the 10th percentile lands on a one-bit pulse; the minimum lands on
-- whatever the narrowest glitch in the capture was, and one bad sample would then
-- halve the estimate and make every run look like idle.
--
-- Interior gaps only. The runs before the first edge and after the last are cut
-- short by the capture boundary, so they are not pulse widths.
function sdec.sig_onebit(ei, ne)
  if ei == nil or ne == nil or ne < 5 then return nil end
  local t, nt = {}, 0
  local k
  for k = 1, ne - 1 do
    local d = ei[k + 1] - ei[k]
    if d > 0 then
      nt = nt + 1
      t[nt] = d
    end
  end
  if nt < 4 then return nil end
  table.sort(t)
  local i = math.floor(nt * 0.1)
  if i < 1 then i = 1 end
  local v = t[i]
  if v == nil or v <= 0 then return nil end
  return v
end

-- ============================================================================
-- Bit-time recovery
-- ============================================================================
-- Least-squares refinement from a seed bit time.
--
-- In any asynchronous or self-clocked line code every pulse width is an integer
-- multiple of the bit time, so this is a fit through the origin: given widths w[k]
-- and integer multiples m[k], the bit time is sum(w*m)/sum(m*m). Using every
-- pulse beats using the shortest -- a single short pulse carries the full sample
-- quantisation error, a 10-bit gap divided by 10 carries a tenth of it, and the
-- fit weights long gaps accordingly.
--
-- Returns bittime, quality, nfit -- or nil when nothing fits.
function sdec.sig_fit(w, nw, seed)
  local floor, abs = math.floor, math.abs
  local maxm = sdec.maxmult
  local T = seed
  local it, k

  for it = 1, 6 do
    local sn, snn = 0, 0
    for k = 1, nw do
      local wk = w[k]
      local m = floor(wk / T + 0.5)
      -- Multiples beyond maxmult are inter-byte idle, not a run of bits, so they
      -- carry no timing information and must not drag the fit.
      if m >= 1 and m <= maxm then
        if abs(wk - m * T) < 0.35 * T then
          sn  = sn + wk * m
          snn = snn + m * m
        end
      end
    end
    if snn <= 0 then return nil, 0, 0 end
    local newT = sn / snn
    local moved = abs(newT - T)
    T = newT
    if moved < 1e-9 * T then break end
  end

  -- Quality combines fit tightness with COVERAGE -- how many eligible widths fit
  -- at all. Coverage is what rejects a seed at twice the true bit time: the real
  -- one-bit pulses stay inside maxmult*T so they count as eligible, but land half
  -- a period from any multiple and fail the gate.
  local serr, nfit, nsmall = 0, 0, 0
  for k = 1, nw do
    local wk = w[k]
    if wk <= (maxm + 0.5) * T then
      nsmall = nsmall + 1
      local m = floor(wk / T + 0.5)
      if m < 1 then m = 1 end
      local e = abs(wk - m * T)
      if e < 0.35 * T then
        nfit = nfit + 1
        serr = serr + e
      end
    end
  end
  if nfit == 0 or nsmall == 0 then return nil, 0, 0 end

  local q = (1 - (serr / nfit) / T) * (nfit / nsmall)
  if q < 0 then q = 0 end
  return T, q, nfit
end

-- Recover the bit time from the edge list. Returns bittime, reason.
function sdec.sig_bittime()
  local ne, ei = sdec.ne, sdec.ei
  sdec.bittime, sdec.baud_raw, sdec.baud = nil, nil, nil
  sdec.fitq, sdec.snapped = 0, false
  if ne == nil or ne < 2 then return nil, 'need at least two edges' end

  local nw = ne - 1
  local w, s = {}, {}
  local k
  for k = 1, nw do
    local d = ei[k+1] - ei[k]
    w[k] = d
    s[k] = d
  end
  sdec.nw, sdec.w = nw, w
  table.sort(s)
  -- The MEDIAN pulse width, kept for sdec.ua_cands(). Spikes are a minority of the
  -- widths however many of them there are, so they cannot move it -- unlike the
  -- least-squares fit below, which they capture outright.
  sdec.wmed = s[math.floor(nw / 2) + 1]

  -- Candidate seeds: the smallest widths, but only CORROBORATED ones -- another
  -- width must sit within 25 %. Seeds are then thinned to be >30 % apart.
  --
  -- Corroboration is not optional. A sub-bit glitch produces one isolated short
  -- width, and a fit seeded from it can score HIGHER than the truth: a shorter
  -- trial period draws fewer long widths into its own coverage denominator, so the
  -- metric flatters it. Scoring alone cannot reject that; requiring a neighbour
  -- does, because real bit-time widths arrive in dozens and glitches arrive alone.
  --
  -- The list is sorted, so "within 25 %" is a look at the next entry.
  local seeds, nseed, last = {}, 0, 0
  for k = 1, nw do
    local v = s[k]
    local corrob = (k < nw and s[k+1] <= 1.25 * v) or nw < 3
    if v > 0 and corrob and (nseed == 0 or v > 1.3 * last) then
      nseed = nseed + 1
      seeds[nseed] = v
      last = v
      if nseed >= 4 then break end
    end
  end
  if nseed == 0 then return nil, 'no usable pulse widths' end

  -- Seeds ascend and the comparison is strict, so a tie keeps the smaller bit time
  -- (higher baud).
  --
  -- The result is a PROPOSAL. Pulse-width statistics cannot always find the bit
  -- time: widths can share a common factor (0x00 at 8N1 with a two-bit gap holds
  -- only 9-bit and 3-bit runs, best-fitting three bit times). sdec.ua_best()
  -- rescales by small integer ratios and lets the frame decode arbitrate.
  local bestT, bestq = nil, -1
  for k = 1, nseed do
    local T, q = sdec.sig_fit(w, nw, seeds[k])
    if T ~= nil and q > bestq then bestT, bestq = T, q end
  end
  if bestT == nil then return nil, 'no bit time fits the pulse widths' end

  sdec.bittime = bestT
  sdec.fitq    = bestq
  local fs = sdec.acq_fs or sdec.fs
  sdec.baud_raw = fs / bestT
  sdec.baud, sdec.snapped = sdec.sig_snap(sdec.baud_raw)
  return bestT
end

-- Snap a measured rate to a standard one when it is within tolerance.
-- Returns rate, snapped.
function sdec.sig_snap(b)
  if b == nil then return nil, false end
  local best, bestd = nil, nil
  local i
  local nb = table.getn(sdec.stdbaud)
  for i = 1, nb do
    local r = sdec.stdbaud[i]
    local d = b / r - 1
    if d < 0 then d = -d end
    if bestd == nil or d < bestd then best, bestd = r, d end
  end
  if bestd ~= nil and bestd <= sdec.snaptol then return best, true end
  return b, false
end

-- THE CEILING. 4 samples per bit is the wall: below it the mid-bit sampling point
-- cannot be held across a ten-bit frame, because the accumulated edge-position error
-- walks it into the neighbouring cell. At the top sample rate of 1 MS/s that puts the
-- ceiling at exactly 250 kBd, which is also what the harness measures on a CLEAN
-- waveform -- a spiky or ringing line does worse, and is expected to.
--
-- So it is a declared limit, not an emergent one: anything ABOVE sdec.maxbaud is refused outright
-- rather than decoded into plausible-looking bytes, and 4.0 samples/bit itself warns,
-- since being exactly at the wall is the marginal case rather than a comfortable one.
sdec.minsabit = 4
sdec.maxbaud  = 250000

-- One-line verdict on the signal, for the panel and the log.
function sdec.sig_quality()
  local T = sdec.bittime
  if T == nil then return nil, 'no bit time' end
  if T <= sdec.minsabit then
    return T, string.format('only %.1f samples/bit -- at or past the %d kBd ceiling',
                            T, sdec.maxbaud / 1000)
  end
  return T
end

-- ============================================================================
-- Acquisition
-- ============================================================================
-- Pick the lowest LISTED sample rate that still gives at least `want` samples per bit; three listed
-- rates are deliberately inexact (see sdec.rates). A lower rate covers more TIME in the same buffer, which is what decides
-- how many bytes a capture holds -- at 9600 baud, 20 000 samples is 190 bytes at
-- 100 kS/s but only 19 at 1 MS/s.
function sdec.pick_fs(baud, want)
  if want == nil then want = 8 end
  local need = baud * want
  local i
  local nr = table.getn(sdec.rates)
  for i = 1, nr do
    if sdec.rates[i] >= need then return sdec.rates[i] end
  end
  return sdec.rates[nr]
end

-- Derive the true sample rate from the buffer's own timestamps. The readback
-- LIES for any rate the hardware cannot synthesise, so this is the only
-- trustworthy source; every bit time in this module is scaled by it.
function sdec.acq_measure_fs(buf, n)
  local ts = buf.relativetimestamps
  if ts == nil or n == nil or n < 2 then return nil end
  local t1, tn = ts[1], ts[n]
  if t1 == nil or tn == nil then return nil end
  local span = tn - t1
  if span <= 0 then return nil end
  return (n - 1) / span
end

-- The measured rate, or the REQUESTED one with a flag saying so. Every acquisition path uses this.
--
-- WHY NOT A BARE `or sdec.fs`. acq_fs is not a display figure -- every bit time, the baud rate, the
-- format search and therefore every BYTE is scaled by it. The readback lies for any rate the hardware
-- cannot synthesise (three of the listed rates are inexact ON PURPOSE, see sdec.rates), which is why it
-- is re-derived from timestamps at all. Substituting the request SILENTLY would have the panel report a
-- measured rate, a measured baud and confident bytes derived from a number known to be untrustworthy.
--
-- IT STILL SUBSTITUTES, rather than failing the capture. Refusing would turn a working decoder into a
-- dead one the moment relativetimestamps is unavailable in some configuration -- a large behavioural
-- change to guard a fault never seen on this instrument, where 80 000 requested measures 79 999.995. The
-- app's rule is that refusing with a reason is acceptable and confident nonsense is not; here it can
-- keep working AND not be confident, which is strictly better than either alternative. ui_notes() says
-- so whenever this flag is set.
function sdec.acq_fs_or_requested(buf, n)
  local m = nil
  pcall(function() m = sdec.acq_measure_fs(buf, n) end)
  if m ~= nil then
    sdec.acq_fs_est = nil
    return m
  end
  sdec.acq_fs_est = true
  return sdec.fs
end

-- ============================================================================
-- SAMPLE RATE FOLLOWS A KNOWN BAUD RATE. This is where most of the app's usable
-- text comes from.
-- ============================================================================
-- sdec.n is 20000 samples, so at a fixed 1 MSa/s a capture is 20 ms of signal
-- WHATEVER the line speed -- which means a slow line yields LESS text, the
-- opposite of what anyone expects. At 9600 8N1 that is 19 bytes. Nineteen bytes
-- is not enough to read a debug message, and debug messages bit-banged out of a
-- small microcontroller are what this app is mostly for.
--
-- When the operator has FORCED the baud rate, the bit rate is known before the
-- capture, so the rate can be chosen deterministically -- no detect-then-retry,
-- no state, no surprise. Lower rate, longer window, more bytes:
--
--   forced baud   fs      samples/bit   bytes
--      1200      10 k        8.33        240
--      2400      20 k        8.33        240
--      4800      40 k        8.33        240
--      9600      80 k        8.33        240
--     19200     160 k        8.33        240
--     38400     320 k        8.33        240
--     57600     500 k        8.68        230
--    115200       1 M        8.68        230   (at the ceiling)
--    250000       1 M        4.00        500
--
-- Two things this must get right:
--
-- 1. The rate must be SNAPPED to sdec.rates. Only decimal rates are exact on this
--    instrument -- ask for 102400 and you get 102325.5 Hz -- so a computed
--    baud*8 would quietly acquire at a rate that is not the one assumed.
-- 2. It must RESET when nothing is forced. Leaving fs at 100 kSa/s after the
--    operator clears the forced rate would cap automatic detection near 25 kBd
--    (fs / minsabit) and make every fast line look absent. Statelessness is what
--    keeps that from happening.
--
-- 8 samples/bit is the target because 8.68 is already a proven case in the test
-- suite; going lower heads toward sdec.minsabit = 4, which is the declared floor
-- and only reached with a warning.
sdec.fs_default = 1000000
sdec.fs_sabit   = 8

-- Lowest listed sample rate giving at least `sabit` samples per bit at this baud rate.
function sdec.fs_for_baud(baud)
  local top = sdec.rates[table.getn(sdec.rates)]
  if baud == nil or baud <= 0 then return sdec.fs_default end
  local want = baud * sdec.fs_sabit
  local i
  -- sdec.rates ascends, so the first rate at or above `want` is the LOWEST one
  -- that still meets the oversampling target -- i.e. the longest capture.
  for i = 1, table.getn(sdec.rates) do
    if sdec.rates[i] >= want then return sdec.rates[i] end
  end
  return top                      -- faster than the instrument can sample; clamp
end

-- Call before every capture. Stateless by construction: it derives fs from the
-- current forced rate each time rather than remembering anything.

-- THE STREAMING MODES WANT THE OPPOSITE RATE FROM FRAME, and this is the single most
-- consequential piece of arithmetic in the app.
--
-- Decode cost is per SAMPLE, so what bounds throughput is SAMPLES PER BYTE:
--
--     samples/byte = framebits x (fs / baud)      decode ceiling = 1 / (samples_per_byte x Tread)
--
-- fs_for_baud() minimises nothing -- it maximises oversampling, picking the lowest rate at or
-- above baud x 8. That is right for FRAME, where the format is UNKNOWN and oversampling is the
-- margin the search needs. It is actively wrong for a streaming mode, where baud, width, parity,
-- stop bits and polarity are all FORCED (needbaud), so the margin buys nothing and the samples
-- cost everything.
--
-- The measured consequence, at the predicted Tread of 8 us:
--
--     baud     fs_for_baud       fs_for_burst   delivered   gain
--     115200   1 M   8.68 sa/bit  640 k          4.19 sa/bit  1440 -> 2880 B/s, 32 kB -> 64 kB/buffer
--      38400   320 k 8.33         200 k          4.73         1229 -> 2400 B/s
--       9600   80 k  8.33          40 k          4.08         1501 -> 2400 B/s
--
-- 115200 was the WORST baud in the table -- slower to decode than 9600 -- purely because the
-- ladder handed it 8.68 samples/bit. Both wins come from the same change and both reduce LOST
-- DATA, which is the point: fewer samples per byte means MORE bytes fit one buffer (a longer
-- window, so fewer gaps) AND the decode between windows is shorter (a smaller gap each time).
--
-- WHY minsabit AND NOT SOMETHING SAFER LIKE 5: the ladder is coarse, so asking for 5 snaps back
-- up and gives nothing. 115200 x 5 = 576000, and the lowest listed rate at or above that is
-- 1 MS/s -- the very rate this is trying to avoid. Asking for 4 lands 115200 on 640 kS/s and 4.19
-- delivered samples/bit. Snapping usually leaves margin, but not always: 19200 lands on 80 kS/s and
-- exactly 4.00 delivered, and 250 kBd is on 4.0 already.

-- MEASURED: a SimpleLoop trigger model adds a CONSTANT 0.510 us to every sample
-- interval. Dead constant from 1250 S/s to 640 kS/s, and independent of aperture (AUTO and 1 us
-- give identical results). dmm.digitize.read() does NOT pay it -- it hits requested rates exactly
-- -- but it BLOCKS Lua for the whole acquisition, so the idle watchdog cannot poll buf.n, and
-- chunking it to regain control costs 9139 us per seam (8.8 bytes at 9600 baud). The streaming
-- modes therefore keep SimpleLoop and live with the offset, which is the right trade: an offset
-- rate is measured and compensated by acq_measure_fs(), whereas a seam is data that is gone.
--
-- It is also why an exact-rate table measured with digitize.read() does not describe this app:
-- digitize.read() and a trigger model do not pay the same per-sample cost.
sdec.acq_overhead = 0.510e-6

-- The rate that DELIVERS `want` samples per bit, not the rate that would if there were no
-- overhead. Solving fs_actual = 1/(1/fs + OV) >= baud * want for the REQUESTED fs:
--
--     fs  >=  1 / ( 1/(baud*want) - OV )
--
-- Without this the burst path asked for exactly baud*minsabit and DELIVERED less: 115200 asked
-- 500 kS/s for 4.34 samples/bit and got 398 kS/s and 3.46 -- under the declared floor, while the
-- app believed it had cleared it. That is the confident-and-wrong failure this project cares most
-- about, and it appears only on hardware: offline, ladder snapping made minsabit look safe.
--
-- Returns nil when NO listed rate can deliver the floor, rather than a rate that cannot work.
-- At minsabit = 4 that bites above 165563 Bd = 1/(4*(1/1e6 + 5.1e-7)) -- 153600 still gets 1 MS/s
-- and 4.31 delivered samples/bit, 172800 gets nothing. 250 kBd needs 2.04 MS/s
-- requested to deliver 1 MS/s, which does not exist, so streaming genuinely cannot reach it.
function sdec.fs_for_burst(baud)
  if baud == nil or baud <= 0 then return sdec.fs_default end
  local want = sdec.minsabit
  local ideal = 1 / (baud * want)
  if ideal <= sdec.acq_overhead then return nil end   -- unreachable at any rate
  local need = 1 / (ideal - sdec.acq_overhead)
  local i
  for i = 1, table.getn(sdec.rates) do
    if sdec.rates[i] >= need then return sdec.rates[i] end
  end
  return nil                                          -- past the top listed rate
end

-- What a requested rate ACTUALLY delivers, and the samples/bit that follows. Used by the panel so
-- the operator sees the delivered figure rather than the asked-for one -- the header's SA/BIT is
-- computed from acq_fs after a capture, but before one there is nothing measured to show.
function sdec.fs_delivered(fs)
  if fs == nil or fs <= 0 then return nil end
  return 1 / (1 / fs + sdec.acq_overhead)
end

-- Call before every capture. Stateless by construction: it derives fs from the current forced
-- rate AND the current mode each time rather than remembering anything.
function sdec.fs_select()
  -- A RATE THE CALLER ALREADY WORKED OUT WINS, and without this the two-pass auto-detect
  -- could not work at all.
  --
  -- autoset() captures once at the top rate to FIND the baud, then sets sdec.fs to the lowest
  -- rate still giving 8 samples/bit and captures again -- which is the step that turns a 19-byte
  -- window into a 240-byte one. But acquire() calls hw_config(), which calls this, and this only
  -- ever consulted force_baud: with nothing locked it reset sdec.fs straight back to
  -- fs_default. So the second pass ran at 1 MS/s, exactly like the first, and an UNLOCKED
  -- capture could never return more than ~19 bytes at 9600 baud however long the line talked.
  --
  -- Found on the instrument by pressing Options > Auto Detect and watching a 227-byte
  -- capture become an 18-byte one. It was not the button: nothing unlocked had ever produced a
  -- long window, and the auto-detect path is simply where that is most visible.
  --
  -- ONE-SHOT, cleared here, because it describes a decision made for the NEXT capture only.
  -- Leaving it set would be a second kind of lock with none of the lock's UI, and the panel
  -- would show a rate the operator never chose and cannot see.
  if sdec.fs_want ~= nil then
    sdec.fs = sdec.fs_want
    sdec.fs_want = nil
    return sdec.fs
  end
  if sdec.force_baud ~= nil and sdec.force_baud > 0 then
    -- mode_cur lives in serial_ui.tsp; guarded so serial_core stays usable on its own, and
    -- falling back to the FRAME rule -- the conservative direction, since it oversamples.
    local md = nil
    if sdec.mode_cur ~= nil then md = sdec.mode_cur() end
    if md ~= nil and md.needbaud then
      -- nil means no listed rate DELIVERS minsabit at this baud. Fall back to the top rate so a
      -- capture still happens and still decodes as well as it can; mode_why() is what refuses,
      -- because a refusal belongs where it can carry a reason to the panel.
      sdec.fs = sdec.fs_for_burst(sdec.force_baud) or
                sdec.rates[table.getn(sdec.rates)]
    else
      sdec.fs = sdec.fs_for_baud(sdec.force_baud)
    end
  else
    sdec.fs = sdec.fs_default
  end
  return sdec.fs
end

-- How many bytes a capture can physically hold, at the rate actually used and the
-- format actually decoded. Uses acq_fs, the MEASURED rate, in preference to the
-- requested one -- the two differ by up to 0.073 % on this instrument and the
-- measured one is the truth.
--
-- Worth more than a convenience number: it is the only way the operator can know
-- whether a message was SEEN WHOLE or merely sampled. A capture that comes back
-- exactly full is indistinguishable from a complete short message unless something
-- says so, and on a continuously busy line every capture is full.
--
--     baud     fs      bytes (8N1)
--     1200    10 k        240
--     2400    20 k        240
--     4800    50 k        192
--     9600   100 k        192
--    19200   200 k        192
--    38400   500 k        153
--    57600   500 k        230
--   115200     1 M        230
--   250000     1 M        500
-- ONE DIVISION, NOT TWO, and it is not a micro-optimisation -- it is the difference between
-- the numbers above being right and being one short. The obvious form, floor(n / (fs/baud *
-- framebits)), rounds twice: 10000/1200 is 8.3333333333333339, ten of those is
-- 83.333333333333343, and 20000 divided by THAT is 239.99999999999997 -- so it floored to 239
-- while this comment claimed 240. The exact answer is 240 and the table was right.
--
-- n * baud / (fs * framebits) is algebraically identical with a single rounding step, and it
-- is EXACT whenever fs is an exact integer rate, which is the entire reason sdec.rates exists.
-- Both products stay far inside double precision: the largest case is a 2.8 M-sample buffer at
-- 250 kBd, 7e11, against 2^53.
--
-- Worth a fix rather than a shrug because the whole point of the number is "was this message
-- seen WHOLE?", and every case where the division comes out exact -- i.e. every case where the
-- sample rate was chosen to give a round samples/bit -- is a case where the operator was told
-- the window was one byte smaller than it is.

-- Capacity a capture of n samples needs. LoopUntilEvent takes its pre-trigger reserve out of
-- CAPACITY, not out of `count`, so a buffer sized exactly n delivers n minus the reserve: measured
-- 19 011 at capacity 20 000, 20 066 at 21 100. FRAME only -- SimpleLoop has no reserve, and its
-- buffers run to 2.8 M readings against a 6 M ceiling for all buffers together.
function sdec.acq_cap(n)
  if n == nil then n = sdec.n end
  if n == nil then return nil end
  if sdec.trigmode == 'free' then return n end
  -- HEADROOM UNCONDITIONALLY, including at pretrig = 0. The model can make a reading or two past
  -- `count` before abort() takes effect, and with a buffer sized exactly n that overshoot is a
  -- discard -- which is the same 4915 by a shorter route. Measured with pretrig = 0 and no
  -- headroom: 20-30 events per capture.
  return n + math.ceil(n * (sdec.pretrig or 0) / 100) + 100
end

-- FILL CONTINUOUSLY, SO NOTHING IS EVER STORED PAST THE END OF THE BUFFER.
--
-- This is the root cause of **4915 "attempting to store past the capacity of reading buffer"**.
-- buffer.make() gives a FILL_ONCE buffer, where the reference says a reading past the end is
-- DISCARDED -- and every discard posts 4915 at error severity, which the panel shows regardless of
-- localnode.showevents (that attribute governs the remote interface only, so it cannot be muted).
--
-- LoopUntilEvent's pre-trigger reserve is inherently circular: it keeps the LAST readings before the
-- trigger, so it must overwrite its oldest while it waits. On a FILL_ONCE buffer that is a discard.
-- Worst exactly where the app is most used -- a bursty device leaves the model waiting -- and at
-- 1 MS/s the 5 % reserve is only 1.05 ms, so it wrapped on every auto-detect probe.
--
-- buffer.FILL_CONTINUOUS the CONSTANT does not exist on firmware 1.7.17a and assigning it raises,
-- which is what made this look unfixable. The ATTRIBUTE takes its numeric value: `fillmode = 1`
-- reads back as 1. defbuffer1 ships in that mode, which is the confirmation that it is the normal
-- one for a buffer something else is filling.
function sdec.acq_fillmode(buf)
  if buf == nil then return false end
  return pcall(function() buf.fillmode = 1 end)
end

-- Readings the pre-trigger reserve holds, and how long that is in TIME -- which is what decides
-- whether it WRAPS while waiting for the first edge. A wrap on a FILL_ONCE buffer is a discard, and
-- each discard posts 4915. Measured at 1200 baud, one armed capture each:
--
--     fs = 1 MS/s   reserve 1.05 ms   got 21100 (the whole buffer)   4915 x10
--     fs = 10 kS/s  reserve 105 ms    got 20085 (the depth asked)    4915 x0
--
-- NOT fixed by raising `position`: the firmware makes post = count - count x position/100, so a
-- reserve big enough in time at 1 MS/s (66 %) would cost two thirds of the depth. Nor by a bigger
-- buffer alone -- 5 % of enough readings to cover 40 ms at 1 MS/s is an 800 000-reading buffer per
-- capture. So the reserve stays at 5 % and the EVENT is muted for the capture instead
-- (sdec.mute_events); the data is unaffected, verified byte-exact throughout.
function sdec.acq_reserve(n)
  if n == nil then n = sdec.n end
  local pt = sdec.pretrig or 0
  if pt <= 0 then return 0 end
  return math.ceil((sdec.acq_cap(n) or n) * pt / 100)
end

-- HOW MANY SAMPLES A CAPTURE ACTUALLY DELIVERS, which is not sdec.n on the armed path.
--
-- LoopUntilEvent reserves `pretrig` per cent of the buffer for pre-trigger readings and makes only
-- the remainder as post-trigger ones; on a busy line the trigger fires within ~15 samples so the
-- reserve is never spent. Measured 19011 of 20000. Free-run (dmm.digitize.read) has no reserve and
-- delivers the lot.
--
-- window_bytes() used sdec.n, so it reported a capacity 5 % larger than any armed capture could
-- return -- the panel said 240 while the dump held 227, and "was this message seen WHOLE?" is the
-- one question that number exists to answer.
function sdec.n_deliv(n)
  if n == nil then n = sdec.n end
  if n == nil then return nil end
  -- Only the armed paths reserve. 'free' means dmm.digitize.read(), which fills the buffer.
  if sdec.trigmode == 'free' then return n end
  local pt = sdec.pretrig or 0
  if pt <= 0 then return n end
  return n - math.floor(n * pt / 100)
end

-- How many bytes one capture window can hold at this rate and format.
function sdec.window_bytes(baud, nbits, par, nstop)
  local fs = sdec.acq_fs or sdec.fs
  if baud == nil or baud <= 0 or fs == nil or fs <= 0 then return nil end
  local parbits = 0
  if par ~= nil and par ~= sdec.PAR_NONE then parbits = 1 end
  local framebits = 1 + (nbits or 8) + parbits + (nstop or 1)
  if fs / baud <= 0 then return nil end
  -- STILL sdec.n, NOT sdec.n_deliv(), and that is a known overstatement of 5 % on the armed
  -- path -- see the note at sdec.n. Switching it is a two-line change here and a handful of test
  -- expectations, and it is NOT done because n_deliv() depends on sdec.trigmode: free run has no
  -- pre-trigger reserve and delivers the whole buffer, so the capacity figure would flip with a
  -- setting the operator has no reason to connect to it. Whether that is honest or confusing is a
  -- design call, not a bug fix, so it is left for a session with room to make it properly.
  return math.floor((sdec.n * baud) / (fs * framebits))
end

-- Configure the digitizer. Fixed range and a 1 us aperture, both non-negotiable:
-- autorange would rescale mid-capture, and APERTURE_AUTO integrates the whole
-- sample interval, a boxcar whose sinc roll-off rounds off the very edges this
-- decoder measures.
--
-- Order matters and is documented: "Set the sample rate before setting the
-- aperture. If the aperture setting is too high for the selected sample rate, it
-- is automatically adjusted." At 1 MSa/s the 1 us aperture exactly fills the
-- sample interval; at the lower rates chosen above it is a short window inside a
-- longer interval, which if anything smears an edge less.
-- Configure the rear EXT TRIG OUT line for flow control, or leave it entirely alone.
--
-- Called from hw_config() so it is re-applied before every capture rather than once at start-up:
-- trigger.extout.logic is documented as reset by "Instrument reset / Power cycle / External I/O
-- trigger reset", and acq_triggered() calls trigger.ext.reset() on some paths. A one-time setup
-- would be silently undone by the app's own reset.
--
-- LOGIC_POSITIVE: a TTL-high pulse from an idle-low line, so the device watches for a RISING edge.
-- Chosen because a rising-edge "go" is the convention a micro's pin-change interrupt expects, and
-- because an idle-low line does not look like a permanently-granted credit if the DMM is off.
function sdec.fc_config()
  if not sdec.fc_out then return false end
  local ok = pcall(function()
    trigger.extout.logic = trigger.LOGIC_POSITIVE
  end)
  -- Width under its OWN pcall: the manual states the width is settable but not the legal range for
  -- this model, so a refusal here must not also lose the logic setting above.
  pcall(function()
    if trigger.extout.pulsewidth ~= nil then
      trigger.extout.pulsewidth = sdec.fc_pulse
    end
  end)
  return ok
end

-- STOP THE FIRMWARE POPPING DIALOGS OVER THE APP.
--
-- The panel raises a modal "Multiple errors have occurred" box when unread event-log entries
-- accumulate, and it lands ON TOP of the hex dump where it has to be dismissed by hand. The app
-- produces entries in NORMAL operation and cannot avoid it: every armed capture posts 2731
-- (trigger model initiated) and 2732 (idled), and finding the next free byte-log name means
-- probing file.open until one fails, which posts 2205 (file not found). None are faults, and
-- none should interrupt someone reading bytes off the screen.
--
-- localnode.showevents selects which severities are DISPLAYED, not which are LOGGED, so the log
-- stays complete for sdec.errcount and for diagnosis; this only suppresses the popup. Real
-- errors still show.
--
-- Applied from hw_config so it is re-asserted per capture: it is instrument state, and an App
-- relaunch or another app may have changed it.
function sdec.quiet_events()
  return pcall(function()
    localnode.showevents = eventlog.SEV_ERROR
  end)
end

-- Mute the panel's event popups for a capture. The pre-trigger reserve is a CIRCULAR sub-region, so
-- it overwrites its oldest reading while waiting -- and a FILL_ONCE buffer treats an overwrite as a
-- discard, posting 4915. Fires whenever the first edge is further off than the reserve: 12.7 ms at
-- 9600 baud, 0.42 s at 300 (measured: ten per capture at 300-1200 baud, none at 9600 and up).
-- buffer.FILL_CONTINUOUS does not exist on firmware 1.7.17a -- assigning it raises. Data is
-- unaffected, so only the modal box is the harm.
--
-- THE LOG IS LEFT INTACT. Draining it is worse: eventlog.next CONSUMES and eventlog.post cannot put
-- an event back, so real events come out as generic "1005 User" entries, multiplied per poll, and
-- trip 1707. Do not try it.
function sdec.mute_events()
  return pcall(function() localnode.showevents = 0 end)
end

function sdec.unmute_events()
  return pcall(function() localnode.showevents = eventlog.SEV_ERROR end)
end

-- Apply the range, sample rate and trigger settings to the digitizer before a capture.
function sdec.hw_config()
  sdec.quiet_events()
  sdec.fs_select()
  sdec.fc_config()
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = sdec.range
  dmm.digitize.samplerate = sdec.fs
  dmm.digitize.aperture   = 1e-6
end

-- Clamp a request to what the buffer can hold, reserve included. A store past capacity posts 4915
-- and truncates the capture.
function sdec.acq_fit(n, buf)
  local cap = nil
  pcall(function() cap = buf.capacity end)
  if cap == nil or cap < 10 then return n end
  local room = cap
  if sdec.trigmode ~= 'free' and (sdec.pretrig or 0) > 0 then
    -- A percentage of THIS buffer, which is what the model takes -- not of the capture we intended.
    -- The two differ exactly when the buffer came out smaller than asked for, which is the case
    -- this clamp exists for. No fudge term either: acq_cap sizes the buffer as n + reserve, so room
    -- comes out at n and a capture asking for its own depth is never clamped. An extra -1 cost a
    -- sample on every armed capture and truncated the last frame.
    room = cap - math.ceil(cap * (sdec.pretrig or 0) / 100)
  end
  if room < 10 then room = 10 end
  if n > room then return room end
  return n
end

-- Free and remake the capture buffer. Follows the project's object-lifetime rule
-- -- delete, nil, then create -- because creating over a live handle leaves the
-- buffer beneath allocated and unreachable until a power cycle.
function sdec.acq_make_buffer(n)
  -- NEVER REPLACE A BUFFER THE TRIGGER MODEL MAY STILL BE WRITING INTO.
  --
  -- acq_free() settles first and acq_triggered() waits, but this function is reachable with a model
  -- still armed -- acquire() calls it before any settle, and an armed capture that timed out
  -- or aborted leaves the model running. The model then stores into a buffer that has been deleted
  -- and replaced, which is what posts **4915 "attempting to store past the capacity of reading
  -- buffer"**: the store is measured against the wrong object. sdec.stop() needs the same discipline for
  -- the same reason -- neither may delete a buffer the hardware still owns.
  --
  -- Cheap when there is nothing to settle: trig_settle() polls the model state and returns at once
  -- when it is already idle.
  pcall(function() sdec.trig_settle() end)
  if sdec.buf ~= nil then
    local b = sdec.buf
    -- A REFUSED DELETION MUST NOT BE FOLLOWED BY A NEW ALLOCATION, and the handle must not be
    -- dropped. Nil'ing first and swallowing the error would strand the buffer inside the firmware
    -- and allocate another on top -- one more on every retry, until a power cycle. Reachable
    -- whenever trig_settle() times out and the model still owns the buffer.
    local delok = pcall(function() buffer.delete(b) end)
    if not delok then
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'the capture buffer could not be freed -- power cycle the instrument'
      return sdec.buf                    -- KEEP the handle: it is the only way to retry
    end
    sdec.buf = nil
  end
  if n < 10 then n = 10 end     -- buffer.make() minimum
  sdec.buf = buffer.make(n, buffer.STYLE_STANDARD)
  -- Continuous, so an overwrite is an overwrite rather than a discard -- see acq_fillmode.
  sdec.acq_fillmode(sdec.buf)
  return sdec.buf
end

-- Copy the capture out of the reading buffer into a PLAIN Lua array, once.
--
-- This is what keeps the decoder usable. A reading buffer is not a table:
-- `buf.readings` is a metatable proxy, so every index goes through the firmware
-- rather than hitting a Lua table. The decode chain rereads the samples many times
-- (three passes in sig_levels, one in sig_edges, ~14 points per byte per format
-- tried), so any per-access penalty is paid five-plus times over. Paying it once,
-- on one linear pass, makes the rest free.
--
--   NOT MEASURED            the cost of a buf.readings[i] READ. Assuming it equals
--                           the write cost is an inference, not a result.
--
-- That unmeasured number decides whether long captures can be STREAMED to a file
-- rather than decoded one window at a time. At 9600 baud with 10 samples/bit,
-- keeping up in real time means extracting 96 000 samples per second, so the
-- break-even read cost is ~10 us with NOTHING left for decoding, or ~5 us to leave
-- half the budget. At 1.4 us it just about fits at 9600 and does not at 19200; at
-- 80 us it is eight times too slow and no amount of double buffering helps, since
-- the deficit is throughput rather than a gap between captures.
--
-- Five lines to settle it, and worth doing early:
--   timer.cleartime(); local rd = buf.readings; local s = 0
--   for i = 1, 20000 do s = s + rd[i] end
--   print(timer.gettime() / 20000)        -- seconds per proxy read
function sdec.acq_copy(buf, n)
  local rd = buf.readings
  local t = {}
  local i
  for i = 1, n do t[i] = rd[i] end
  sdec.smp = t
  return t
end

-- Untriggered capture of n samples. Used for the level-learning probe and for
-- 'free' mode, where the line is transmitting continuously enough that where the
-- capture starts does not matter.
-- ncopy CAPS THE LUA COPY, and without it the streaming fallback could try to build a
-- multi-million-entry table.
--
-- stream_acquire() falls back to acq_free(nsmp) when SimpleLoop is refused, and nsmp there is 2.8-6
-- MILLION. acq_copy() copies the whole buffer into sdec.smp, so an uncapped fallback would defeat the
-- entire one-window memory design and could exhaust Lua memory on an instrument whose failure mode for
-- that is a firmware panic. The samples stay in the reading buffer either way; only the Lua-side view
-- is bounded.
function sdec.acq_free(n, ncopy, nofc)
  local buf = sdec.buf
  -- Never read into a buffer a trigger model might still be writing.
  sdec.trig_settle()
  n = sdec.acq_fit(n, buf)
  dmm.digitize.count = n
  buf.clear()
  -- FLOW CONTROL ON THE FREE-RUN PATH TOO. An armed capture degrades silently to free-run when the
  -- trigger source is refused, so a credit issued only on the armed path can never fire -- and
  -- flow control is the only thing preventing byte loss between windows above 4800 baud.
  -- Measured on scope CH4: assert() gives 4.92 V / 5.88 V pk-pk.
  --
  -- BEFORE the read: dmm.digitize.read() blocks until it has n samples, so a credit issued after
  -- it invites the device to transmit into a window that has already closed.
  --
  -- `nofc` suppresses it for the level-learning PROBE reads. A credit spent on a 2000-sample probe
  -- invites a window's worth of traffic that nothing keeps.
  if sdec.fc_out and not nofc then
    sdec.fc_credit()
  end
  dmm.digitize.read(buf)
  sdec.nread = buf.n or 0
  sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  local ncp = sdec.nread
  if ncopy ~= nil and ncopy < ncp then ncp = ncopy end
  sdec.acq_copy(buf, ncp)
  return sdec.nread
end

-- Capture armed on a start-bit edge, keeping sdec.pretrig percent of the buffer
-- from BEFORE the trigger.
--
-- The pre-trigger part earns its keep: a start bit is only a start bit if the line
-- was at mark beforehand. Without it the capture begins AT the edge and the
-- decoder must simply trust that its first edge is a frame boundary.
--
-- The comparison runs on the analog board's Cortex-M4, not in Lua, so arming
-- costs nothing per sample and the edge is caught with hardware timing.
--
-- Falls back to free-run if the model errors.
-- Is the trigger model finished, as opposed to not started yet?
--
-- trigger.model.state() returns three values; only the first is the state. IDLE is
-- also the state BEFORE initiate(), so idleness alone cannot mean "done" -- hence
-- the buffer check. pcall'd because a firmware without the constant must degrade to
-- "not finished" (the caller then falls back on its timeout) rather than raise from
-- inside a poll loop.
function sdec.trig_done(buf)
  local st = nil
  pcall(function() st = trigger.model.state() end)
  if st == nil then return false end
  return st == trigger.STATE_IDLE and (buf.n or 0) > 0
end

-- Stop the trigger model AND WAIT FOR IT TO STOP. abort() is asynchronous; see the
-- note in acq_triggered for what happens when the next capture does not wait.
-- Bounded, because a model that will not idle must not hang the panel.
function sdec.trig_settle()
  pcall(function() trigger.model.abort() end)
  local i
  local unread = 0
  for i = 1, 50 do
    local st = nil
    local sok = pcall(function() st = trigger.model.state() end)
    -- A STATE WE COULD NOT READ IS NOT A MODEL WE KNOW IS IDLE. Treating `st == nil` as settled would
    -- conflate two opposite things: a firmware with no trigger model at all (nothing to settle, so true
    -- is right) and a state() call that RAISED while a model was running. The callers act on this by
    -- DELETING or clearing the reading buffer, so believing a failed read means tearing a buffer out from
    -- under a live trigger model -- the object-lifetime hazard this function exists to prevent.
    --
    -- Distinguished by the pcall's own verdict rather than by the value: sok false means the call
    -- failed, sok true with st nil means the firmware has no state to report.
    if sok then
      if st == nil or st == trigger.STATE_IDLE or st == trigger.STATE_ABORTED then
        return true
      end
      unread = 0
    else
      unread = unread + 1
      -- KEEP TRYING FIRST, because a transient refusal is likelier than a broken firmware and the whole
      -- loop is only half a second. Persistent failure returns FALSE -- the callers already treat false
      -- as "do not touch the buffer", which is the safe direction.
      if unread >= 10 then return false end
    end
    delay(0.01)
  end
  return false
end

-- ============================================================================
-- The cancel key
-- ============================================================================
-- THE FRONT-PANEL TRIGGER KEY IS THE ONLY STOP CONTROL THIS FIRMWARE MAKES POSSIBLE for a job longer
-- than one press. A touch press is not dispatched while Lua runs -- presses QUEUE -- so no button on
-- the glass can stop a loop that has not returned. display.waitevent() BLOCKS and wedges the
-- instrument (DMM_WAITEVENT_WEDGES_THE_INSTRUMENT), and trigger.wait() reads *TRG out of the command
-- queue rather than watching the panel (ref 14-417).
--
-- The trigger subsystem works because it is firmware and needs no interpreter: the key generates
-- trigger.EVENT_DISPLAY and an event blender LATCHES it. MEASURED on 1.7.17a by
-- tools/bench_cancelkey.py -- a press latches with NOTHING armed; the latch is set WHILE LUA SPINS
-- (pressed during a deliberate 10 s busy loop, seen by the poll afterwards, twice); wait(0.001)
-- returns in 1.1 ms and wait(0.05) in 50.1 ms, so it polls rather than blocking; 1.06 ms a poll; and
-- nothing reaches the event log.
--
-- BLENDER 2, because acq_triggered() below owns blender 1 for the trigger-source OR.
sdec.cancel_blender = 2
-- The timeout handed to wait(). NEVER ZERO: display.waitevent() reads a zero timeout as "wait for
-- ever", and wedging the instrument that way cost a power cycle. 1 ms is the smallest value measured
-- to return promptly, and 0.2 % of one decode window.
sdec.cancel_poll_s = 0.001

-- Send one flow-control credit out of the rear EXT TRIG OUT. Returns whether the pulse went.
function sdec.fc_credit()
  local ok = pcall(function() trigger.extout.assert() end)
  -- A REFUSED CREDIT IS NOT A QUIET LINE, and without this it looks exactly like one: a device that
  -- is waiting for permission it never got sends nothing, the window comes back empty, and the run
  -- reports "the device stopped sending" -- a confident, wrong diagnosis of the operator's device.
  -- stickyerr is the right channel because it outlives the capture that found it.
  --
  -- ONE CHANNEL, NOT TWO. A second flag recording the same fact was set here and read nowhere, and a
  -- latch nothing clears is worse than no latch: whatever eventually read it would have been told the
  -- credit failed for the rest of the session.
  if not ok then
    sdec.stickyerr = 'the flow-control credit pulse was refused -- the device was never told to send'
  end
  return ok
end

-- Wire the TRIGGER key to blender 2's latch and discard anything already latched. Returns whether
-- the latch is available.
function sdec.cancel_setup()
  local b = sdec.cancel_blender
  local ok = pcall(function()
    trigger.blender[b].reset()
    trigger.blender[b].orenable = true
    trigger.blender[b].stimulus[1] = trigger.EVENT_DISPLAY
    -- ONE STIMULUS, AND A BUS TRIGGER IS DELIBERATELY NOT THE SECOND. trigger.EVENT_COMMAND (*TRG)
    -- looks like a free way for a harness to cancel a run without a finger, and it does not work:
    -- measured on 1.7.17a, a *TRG sent 2 s into a 6 s busy loop did not reach the latch, because the
    -- command queue is only drained once the interpreter is idle. A stimulus that can only ever fire
    -- between runs -- where cancel_clear() discards it -- would be wiring that reads as coverage and
    -- is not. What DOES fire mid-script is a trigger TIMER, which is firmware: tools/bench_panel.py
    -- adds one as its own stimulus for the duration of the cancel case and removes it afterwards.
    trigger.blender[b].clear()
  end)
  -- FALSE, NOT NIL, so `not sdec.cancel_ok` reads the same on a firmware without blenders as on one
  -- that has not been set up yet: every poll answers "no cancel" and every loop falls back to its
  -- own bounds. A missing cancel key must degrade to the bounds, never to a raise.
  sdec.cancel_ok = ok
  return ok
end

-- Discard any latched press. Called at the top of every cancellable run, because a press made
-- before the run started must not cancel it -- the operator who pressed TRIGGER to stop the LAST
-- run would otherwise stop this one too.
function sdec.cancel_clear()
  if not sdec.cancel_ok then return false end
  return pcall(function() trigger.blender[sdec.cancel_blender].clear() end)
end

-- Has TRIGGER been pressed since the last cancel_clear() or cancel_pressed()? The detector
-- auto-resets on read (ref 14-334), so one press answers true exactly once -- which is why callers
-- record the answer rather than polling twice and expecting the same reply.
function sdec.cancel_pressed()
  if not sdec.cancel_ok then return false end
  local got = false
  local ok = pcall(function()
    got = trigger.blender[sdec.cancel_blender].wait(sdec.cancel_poll_s or 0.001)
  end)
  if not ok then return false end
  return got == true
end

-- Capture armed on a signal edge, on the front-panel TRIGGER key or on the rear BNC,
-- degrading to a free-running read if the source is refused.
function sdec.acq_triggered(n, slope)
  local buf = sdec.buf
  -- NIL IS NOT A TRIGGER SOURCE, and it is checked here, before any instrument state is
  -- touched, so the refusal has nothing to undo. trigger.EVENT_DISPLAY is documented for the
  -- DMM6500, but on a firmware without it the constant reaches trigger.model.load() and the
  -- blender stimulus below AS NIL -- where the front key vanishes silently and a ticked rear BNC
  -- looks like a deliberate sole choice. acq_free() sets up its own capture.
  if sdec.trigmode == 'front' and trigger.EVENT_DISPLAY == nil then
    sdec.lasterr = 'no front-panel TRIGGER event on this firmware; captured free-running'
    return sdec.acq_free(n)
  end
  buf.clear()
  -- PER CAPTURE, not only at creation. Observed reading back 0 on a capture that reused an existing
  -- buffer, and one FILL_ONCE capture is one burst of 4915. Setting it also clears the buffer, which
  -- is why it goes here rather than after clear().
  sdec.acq_fillmode(buf)
  n = sdec.acq_fit(n, buf)
  dmm.digitize.count = n
  -- The pre-trigger reserve posts 4915 while it waits -- see sdec.mute_events. Muted for the
  -- capture and restored below whichever way it ends.
  sdec.mute_events()

  -- WHICH EVENT ARMS THE CAPTURE. The analog trigger watches the SIGNAL ITSELF on the front
  -- INPUT HI/LO and fires on a start-bit edge -- which catches "a byte arrived" but cannot
  -- distinguish WHICH byte, because every byte looks like the start of a message.
  --
  -- The other two sources answer a different question, and that is why they are worth having
  -- rather than redundant: something OUTSIDE the data line decides when the interesting moment
  -- is. A DUT can assert a GPIO into the rear EXT TRIG IN immediately before the message that
  -- matters, and an operator with a probe in each hand can press the front TRIGGER key. Both
  -- are the same trigger-model mechanism with a different event constant, so they cost almost
  -- nothing beyond this branch.
  local ev = trigger.EVENT_ANALOGTRIGGER
  if sdec.trigmode == 'front' then ev = trigger.EVENT_DISPLAY end
  -- WHETHER THE COMPARATOR IS A SOURCE IS DECIDED HERE, before the blender below overwrites
  -- `ev`. Asking `ev == EVENT_ANALOGTRIGGER` after that point answered no for Rear BNC + Edge,
  -- because the model then waits on EVENT_BLENDER1 -- so the mode, level and slope went unset
  -- and the analog stimulus wired INTO the blender could never fire. Ticking the rear BNC
  -- silently reduced an edge trigger to the BNC alone.
  local useanalog = (ev == trigger.EVENT_ANALOGTRIGGER)
  -- Defaulted AT THE POINT OF USE as well as at module load, so that no future
  -- ordering of module loads can put a nil into the comparison below again.
  local wait = sdec.trigwait or 3.0
  -- A HUMAN OR A DUT EVENT IS NOT A 3-SECOND AFFAIR. The analog trigger fires within a byte
  -- time or not at all, but someone reaching for the TRIGGER key, or a device that emits its
  -- message once a minute, needs a longer bounded wait. Still bounded -- an unbounded wait
  -- inside a touch handler is an unresponsive panel.
  if sdec.trigmode == 'front' or sdec.trigext then wait = sdec.trigwait_ext or 30.0 end

  -- THE WAIT MUST OUTLAST THE CAPTURE ITSELF, or the armed path can never complete at a low sample
  -- rate. Completion is the model going idle, which needs all n post-trigger readings: 20 000 at
  -- 2500 S/s is 8 s, against a 3 s wait. A fixed wait therefore times out on every capture below
  -- ~7 kS/s and degrades to free-run with 'edge trigger unavailable' -- a working analog trigger
  -- reported as absent. Measured at 300 baud.
  local dur = nil
  if sdec.fs ~= nil and sdec.fs > 0 then dur = n / sdec.fs end
  if dur ~= nil and wait < dur * 1.5 + 1.0 then wait = dur * 1.5 + 1.0 end

  -- THE REAR BNC IS OR'd IN, not selected instead. That is what the checkbox buys over a
  -- fifth entry in the Trigger field: "start on a start bit, OR when the DUT asserts its
  -- GPIO, whichever comes first" is not expressible as a single choice.
  --
  -- trigger.blender[N].orenable = true makes the blender fire when ANY stimulus fires
  -- (false would require all of them), and the model then waits on EVENT_BLENDER1. Both the
  -- blender API and the event constant are confirmed present in the DMM6500 reference; the
  -- worked example there is stimulus[1]/stimulus[2] with two DIGIO events, which is exactly
  -- this shape with different sources.
  --
  -- Skipped for free run, because 'free' means DO NOT WAIT: OR-ing a trigger into an
  -- untriggered capture would silently turn it into a triggered one, which is the opposite
  -- of what was asked for. Said on the note line rather than done quietly.
  local blended = false
  -- RELEASE THE BLENDER WHEN NOT USING IT. Leaving it armed is not a correctness bug -- the
  -- model below waits on `ev`, which is the analog trigger again, so a configured blender is
  -- simply not referenced. It is left behind instrument STATE the operator did not ask for,
  -- which is the same objection the object-lifetime rule makes about display objects: an app
  -- that configures a subsystem should un-configure it, or the next thing to use a blender
  -- inherits our stimuli and our overrun flag. Costs one guarded call per capture.
  if not sdec.trigext then
    pcall(function() trigger.blender[1].reset() end)
  end
  if sdec.trigext and sdec.trigmode ~= 'free' then
    local bok = pcall(function()
      trigger.blender[1].reset()
      trigger.blender[1].orenable = true
      trigger.blender[1].stimulus[1] = ev
      trigger.blender[1].stimulus[2] = trigger.EVENT_EXTERNAL
    end)
    if bok then
      ev = trigger.EVENT_BLENDER1
      blended = true
    else
      -- No blender on this firmware: fall back to the rear BNC ALONE rather than silently
      -- ignoring the checkbox. The operator asked for the external input to matter.
      ev = trigger.EVENT_EXTERNAL
      sdec.lasterr = 'no trigger blender; using the rear BNC alone'
    end
  end
  sdec.trigblended = blended

  local ok = pcall(function()
    -- The analog trigger is configured ONLY when it is a source. Setting a level and slope
    -- for an external event would be harmless but misleading to read.
    if useanalog then
      dmm.digitize.analogtrigger.mode       = dmm.MODE_EDGE
      dmm.digitize.analogtrigger.edge.level = sdec.thr
      dmm.digitize.analogtrigger.edge.slope = slope
    else
      -- And OFF when it is not: a MODE_EDGE comparator left behind by a previous 'edge'
      -- capture is instrument state the operator did not ask for, which is the same
      -- objection the blender release above makes.
      dmm.digitize.analogtrigger.mode = dmm.MODE_OFF
    end
    -- position is the PRE-trigger percentage: at 5 % of a 20 000-sample buffer
    -- the trigger model keeps 1000 samples before the edge and 19 000 after.
    trigger.model.load('LoopUntilEvent', ev,
                       sdec.pretrig, trigger.CLEAR_ENTER, 0, buf)
    trigger.model.initiate()

    -- FLOW CONTROL: "GO" GOES HERE, AND ONLY HERE.
    --
    -- One pulse on EXT TRIG OUT = permission for the sending device to transmit one frame.
    -- Credit-based rather than CTS-style, because trigger.extout has no settable level -- only
    -- assert(), which emits a pulse. The device waits for the pulse, sends at most one window's
    -- worth, and waits again; nothing is ever lost between frames because nothing is ever sent
    -- between frames.
    --
    -- THE POSITION OF THIS CALL IS THE WHOLE CORRECTNESS ARGUMENT. trigger.model.initiate()
    -- arms the digitizer and returns immediately -- the model runs in firmware -- so by the time
    -- this line executes the instrument is already listening. Asserting BEFORE initiate() would
    -- let the head of every frame arrive while nothing was armed: it would lose exactly the
    -- bytes this feature exists to save, on every single frame, and would present as "the
    -- decoder always misses the first few bytes" rather than as a sequencing error.
    --
    -- pcall'd and unconditional on success: a rear BNC that refuses must not retract a capture
    -- that is already armed and about to work. If the pulse does not fire the capture simply
    -- behaves as it always did -- it waits for traffic that may not come, and times out with a
    -- reason, which is the existing no-trigger path.
    if sdec.fc_out then
      pcall(function() trigger.extout.assert() end)
    end

    -- BOUNDED WAIT. A bare waitcomplete() here is a hang: LoopUntilEvent makes
    -- readings "until it detects the event constant", so on a line with no start bit
    -- -- a dead or grounded pin, which the probe treats as the normal starting
    -- condition -- the model never leaves its wait block and Lua never returns from
    -- inside a touch handler. That is an unresponsive panel needing a power cycle.
    --
    -- MEASURED, 9600 baud into the front terminals: a completed armed
    -- capture holds 19011 of 20000 samples and then goes STATE_IDLE. Never 20000.
    -- `position` is the PRE-trigger percentage, and pre-trigger readings accumulate
    -- only until the trigger fires -- which on a continuously transmitting line is
    -- within about fifteen samples, not the 1000 that 5 % of the buffer allows for.
    -- So a completed capture is n x (1 - pretrig/100) plus a handful, and a test of
    -- `buf.n >= n` cannot be satisfied by any capture that worked.
    --
    -- The consequence is worth stating in full, because it is why this is a paragraph
    -- and not a one-line fix: with that test, EVERY edge-triggered capture times out,
    -- aborts and falls back to free run. The analog trigger itself works --
    -- trigger.model.load() takes the buffer OBJECT, the level and slope take, the
    -- model fires within 0.2 s -- and none of it shows, because the wait is for a
    -- 20000th sample
    -- that was never coming and reported "no trigger". A working feature presented
    -- as a missing signal.
    --
    -- Fill level is still polled, but only as an early exit for pretrig = 0, where
    -- a full buffer IS the completion condition. It cannot stand alone: on a quiet
    -- line the model keeps making pre-trigger readings and wraps the buffer, so
    -- buf.n reaches capacity with no trigger ever having occurred -- accepting that
    -- would report a triggered capture of a dead line.
    local waited, step = 0, 0.05
    while waited < wait do
      if sdec.trig_done(buf) then break end
      if (buf.n or 0) >= n and sdec.pretrig <= 0 then break end
      delay(step)
      waited = waited + step
    end
    -- A FULL BUFFER IS ONLY SUCCESS WHEN pretrig IS ZERO.
    --
    -- On a QUIET line the model keeps making pre-trigger readings and wraps the buffer, so buf.n
    -- reaches n with no trigger ever having occurred. Testing `buf.n < n` would let that through as a
    -- TRIGGERED capture -- aborting the model and reporting success on samples nothing had armed.
    -- Usually caught later as an idle line, but not always: pre-trigger samples of unrelated activity
    -- decode perfectly well and would be presented as "captured on a start bit".
    --
    -- Completion is trig_done(); the fill level counts only in the pretrig = 0 case, where
    -- there is no pre-trigger phase to wrap and a full buffer really does mean finished.
    local full = (buf.n or 0) >= n and sdec.pretrig <= 0
    if not sdec.trig_done(buf) and not full then
      error('no trigger in ' .. tostring(wait) .. ' s (' ..
            tostring(sdec.trigmode) .. ') -- try Free run', 0)
    end
  end)

  -- SETTLE BEFORE ANYTHING ELSE TOUCHES THE BUFFER, on both paths: the failure path below reaches it
  -- too, through acq_free.
  sdec.trig_settle()

  -- BOTH exits restore the popups, including the failure one: a muted panel that stayed muted
  -- would swallow every later firmware error, which is a far worse fault than the box it removed.
  sdec.unmute_events()
  if not ok then
    -- Names the SOURCE that failed, not "analog trigger" -- there are four now, and telling
    -- someone their analog trigger is unavailable when they selected the rear BNC sends them
    -- to the wrong place.
    sdec.lasterr = tostring(sdec.trigmode) ..
                   ' trigger unavailable; captured free-running'
    dmm.digitize.analogtrigger.mode = dmm.MODE_OFF
    return sdec.acq_free(n)
  end

  sdec.nread = buf.n or 0
  sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  sdec.acq_copy(buf, sdec.nread)
  return sdec.nread
end

-- Full acquisition: learn the levels, then capture for real.
--
-- Two stages because the analog trigger level is a voltage and the logic levels
-- are unknown until the line has been looked at. A short untriggered probe
-- measures them; the real capture arms at the midpoint. Returns ok, reason.
function sdec.acquire()
  sdec.lasterr = nil
  -- EVERY ACQUISITION, NOT EVERY PRESS, and the difference is four acquisitions wide: autoset()
  -- runs the three-step probe ladder, then the real capture, then an octave retry, so a press that
  -- cleared only at its start would have its later looks reading the earlier looks' measurements.
  -- Safe here because every field this drops is written further down this same function -- acq_fs by
  -- the read, the rest by sig_levels/sig_edges/sig_idle -- before anything reads it.
  sdec.clear_measured()
  sdec.hw_config()
  -- The pre-trigger reserve comes out of CAPACITY, so ask for it on top -- see sdec.acq_cap.
  sdec.acq_make_buffer(sdec.acq_cap(sdec.n))

  local pn = sdec.probe_n
  if pn > sdec.n then pn = sdec.n end
  if sdec.acq_free(pn, nil, true) < 2 then return false, 'probe capture returned nothing' end

  local ok, why = sdec.sig_levels(sdec.smp, sdec.nread)
  sdec.probe_idle = nil
  if ok then
    sdec.sig_edges(sdec.smp, sdec.nread)
    sdec.sig_idle(sdec.smp, sdec.nread)
  else
    -- A probe that saw no transitions is NOT a failure: a bursty line is idle far
    -- longer than a 2000-sample probe, and for the triggered path idle is the
    -- normal starting condition -- the point is to arm and wait.
    --
    -- Guess the threshold at half the idle level. That lands inside the swing for
    -- a ground-referenced logic line (3.3 V idle -> 1.65 V) and for a bipolar
    -- RS-232 one (-6 V idle -> -3 V, off centre but between the levels). The real
    -- capture re-measures properly below.
    if sdec.vmax == nil then return false, why end
    local idlev = sdec.vmax
    if math.abs(sdec.vmin) > math.abs(sdec.vmax) then idlev = sdec.vmin end
    sdec.hyst = 0
    if math.abs(idlev) < sdec.flatfloor then
      -- Idle sits AT GROUND, so half of it is not between the levels -- it is the
      -- idle level itself, and arming there fires on ADC noise immediately. This is
      -- an inverted TTL line or the TTL side of an idle-low current loop (MIDI).
      -- The active level must be away from ground, and for logic it is essentially
      -- always positive, so put the threshold above idle and arm on a rising edge.
      sdec.thr  = idlev + sdec.flatoffs
      sdec.idle = 0
    else
      sdec.thr = 0.5 * idlev
      if idlev < 0 then sdec.idle = 0 else sdec.idle = 1 end
    end
    sdec.probe_idle = why
    -- Without a trigger there is nothing to wait for, so a quiet line in free-run mode
    -- really is the end of the road. IT IS NOT THE END FOR THE FRONT TRIGGER KEY: a quiet
    -- line is the exact condition that key exists for, since the operator presses it when
    -- they are ready and the line being idle until then is normal. Refusing 'front' here
    -- turned the one source that tolerates silence into the one that demanded traffic.
    if sdec.trigmode == 'free' then return false, why end
  end

  -- THE ARMED PATH IS EVERY SOURCE THAT WAITS, which is all of them except 'free'. Routing
  -- only 'edge' here left 'front' free-running while the status row read EXT TRIG KEY.
  if sdec.trigmode == 'edge' or sdec.trigmode == 'front' then
    -- Arm on the transition AWAY from idle, which is the start bit. Nil for the front key:
    -- the comparator is not a source there, so a slope would be dead state on the board.
    local slope = nil
    if sdec.trigmode == 'edge' then
      slope = dmm.SLOPE_FALLING
      if sdec.idle == 0 then slope = dmm.SLOPE_RISING end
    end
    if sdec.acq_triggered(sdec.n, slope) < 2 then
      return false, 'triggered capture returned nothing'
    end
  else
    if sdec.acq_free(sdec.n) < 2 then return false, 'capture returned nothing' end
  end

  -- Re-measure the levels on the real capture; the probe was only a scout.
  ok, why = sdec.sig_levels(sdec.smp, sdec.nread)
  if not ok then return false, why end
  sdec.sig_edges(sdec.smp, sdec.nread)
  sdec.sig_idle(sdec.smp, sdec.nread)
  return true
end

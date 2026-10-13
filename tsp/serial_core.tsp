-- serial_core.tsp -- acquisition, signal conditioning and bit-timing recovery for the Keithley TSP serial decoder
-- (TSP / Lua 5.0.2). Tested on a DMM6500 only; instrument scope is in serial_app.tsp.
--
--     levels  ->  threshold  ->  edge list  ->  pulse widths  ->  bit time
--
-- Each stage is a large data reduction, so protocol decoders work from the edge list rather than the samples.
-- Lua 5.0.2: no '#' (use table.getn), no bitwise operators, math.mod for modulo, no '//'.

sdec = sdec or {}   -- the single global this app exposes
-- Handles and captured state are declared here, not assigned: opening an installed App re-runs this script body,
-- so a file-scope `sdec.x = nil` would strand a still-live firmware object until a power cycle.


-- ---------- acquisition configuration ----------
-- Every rate here divides 66 000 000 exactly, and three deliberately do not: 160000, 320000 and 640000 are
-- listed because 19200, 38400 and 76800 need them. docs/MEASUREMENTS.md, 'The sample-rate ladder divides 66 MHz'.
-- begin namespace resolver -- the only place in tsp/ that may name dmm. or smu. directly. Which namespace owns
-- the digitizer is decided once, so no capture path tests it; capability detection, not a model list. See README.
local ns, nskey = nil, nil
if     dmm ~= nil and dmm.digitize ~= nil then ns, nskey = dmm, 'dmm_'
elseif smu ~= nil and smu.digitize ~= nil then ns, nskey = smu, 'smu_' end

-- The keys carry a trailing underscore so that `PREP.dmm_.foo` cannot match the instrument-surface inventory
-- grep in the README. The table values below name the real namespaces: an audit should see those.
sdec.ns_key = nskey
sdec.dig    = nil       -- the digitize table itself
sdec.meas   = nil       -- the BASIC measure table, used only to save and restore the entry mode
sdec.atrig  = nil       -- .analogtrigger, or nil where the instrument has no comparator
sdec.atedge = nil       -- .analogtrigger.edge
sdec.k      = {}        -- the constants, copied by value

if ns ~= nil then
  sdec.dig = ns.digitize
  -- Not used by any capture path: this handle exists only so mode_save/mode_restore can put back a basic function
  -- the operator was left in. Guarded, since a digitizer with no measure table still decodes.
  sdec.meas = ns.measure
  -- Cached two and three deep because acq_triggered indexes analogtrigger.edge three times over.
  if ns.digitize.analogtrigger ~= nil then
    sdec.atrig = ns.digitize.analogtrigger
    if ns.digitize.analogtrigger.edge ~= nil then
      sdec.atedge = ns.digitize.analogtrigger.edge
    end
  end
  -- Safe to copy however the firmware implements the tables: values, not assignment targets.
  sdec.k.FUNC_VOLT     = ns.FUNC_DIGITIZE_VOLTAGE
  sdec.k.MODE_EDGE     = ns.MODE_EDGE
  sdec.k.MODE_OFF      = ns.MODE_OFF
  sdec.k.SLOPE_RISING  = ns.SLOPE_RISING
  sdec.k.SLOPE_FALLING = ns.SLOPE_FALLING
  -- The sentinel saying which engine is active, and the only way to ask: exactly one of ns.digitize.func and
  -- ns.measure.func reads it at any time. Read-only as a value, never assigned.
  sdec.k.FUNC_NONE     = ns.FUNC_NONE
end

-- Per-namespace preparation before a capture, resolved to one function so the path carries no test. The dmm_ entry
-- is an empty function, not nil: a nil test is the branch this table exists to remove.
local PREP = {
  dmm_ = function() end,
  smu_ = function()
    -- An SMU used as a voltmeter with its output live drives the circuit under test, so this runs per capture. Not
    -- pcall'd: the constant names here are unverified, so `smu.OFF` being nil is the failure to design for.
    smu.source.output = smu.OFF
    if smu.source.output ~= smu.OFF then
      error('cannot confirm the SMU source output is off -- refusing to capture', 0)
    end
  end,
}
sdec.acq_prep = PREP[nskey] or function() end
-- end namespace resolver

sdec.rates      = {1000, 1250, 2500, 5000, 10000, 15000, 20000, 30000, 40000,
                   50000, 60000, 80000, 100000, 120000, 160000, 200000, 250000,
                   300000, 320000, 400000, 500000, 640000, 1000000}
sdec.fs         = 1000000   -- requested sample rate
-- sdec.acq_fs -- the rate measured from relativetimestamps, which is the one every bit time is scaled by
-- Capture depth. docs/MEASUREMENTS.md, 'The pre-trigger reserve comes out of capacity, not out of count'.
sdec.n          = 20000     -- capture depth, samples (see sdec.acq_cap)
-- Fixed at the 10 V range and not an option, and a constant, so unlike range-as-a-setting it is safe to assign
-- unconditionally on reload. docs/MEASUREMENTS.md, 'The 10 V range has the widest digitize bandwidth'.
sdec.range      = 10
sdec.probe_n    = 2000      -- samples in the level-learning probe capture
-- Sample rates the free-run auto-detect probe tries, in order. Each covers ten times as long for the same sample
-- count, because a window shorter than one frame cannot see a slow line. Every entry must be in sdec.rates.
sdec.probe_fs = sdec.probe_fs or {1000000, 100000, 10000}
sdec.pretrig    = 5         -- pre-trigger percentage for the analog-trigger path
-- 'edge' (analog trigger on the signal), 'free' (untriggered) or 'front' (the TRIGGER key). The rear EXT TRIG IN
-- is not a mode: sdec.trigext OR's it into whichever is selected.
sdec.trigmode   = sdec.trigmode or 'edge'
-- Booleans need an explicit nil test, `or false` resurrecting a deliberate true, and this is operator state that
-- must survive an App relaunch. Off by default: a decoder has to work with one probe and nothing else.
if sdec.trigext == nil then sdec.trigext = false end
-- The rear BNC alone, rather than OR'd with the start-bit trigger, which makes an anchored capture possible. Off
-- by default, since it needs equipment the product does not require. docs/MEASUREMENTS.md, 'trigext_only'.
if sdec.trigext_only == nil then sdec.trigext_only = false end
-- Flow control out: pulse the rear EXT TRIG OUT once the instrument is armed, as a "send the next frame" credit.
-- Off by default with an explicit nil test, since it drives a rear BNC that may be wired to other equipment.
if sdec.fc_out == nil then sdec.fc_out = false end
-- The requested pulse width, not applied on this firmware -- trigger.extout.pulsewidth is nil on 1.7.17a.
-- docs/MEASUREMENTS.md, 'The flow-control pulse is ~10 us, not the 100 us requested'.
sdec.fc_pulse = sdec.fc_pulse or 100e-6
-- Both trigger timeouts belong here, next to the only code that reads them: declared in serial_app.tsp one of them
-- is nil when serial_core loads alone, and the wait comparison then raises.
sdec.trigwait     = sdec.trigwait or 3.0        -- seconds to wait for a start-bit edge
sdec.trigwait_ext = sdec.trigwait_ext or 30.0   -- see acq_triggered: a person or a DUT event
-- sdec.buf                -- capture buffer handle
-- sdec.smp                -- the capture as a plain Lua array (see acq_copy)
sdec.nread      = sdec.nread or 0

-- ---------- signal conditioning results ----------
-- sdec.vmin/vmax (raw extremes of the capture), sdec.lo/hi (the two logic levels, volts)
sdec.swing           = sdec.swing or 0     -- hi - lo
sdec.thr             = sdec.thr or 0       -- decision threshold, volts
sdec.hyst            = sdec.hyst or 0      -- hysteresis half-width, volts
sdec.hystfrac        = 0.15       -- hysteresis as a fraction of the swing
sdec.minswing        = 0.10       -- below this the line is treated as dead, volts
sdec.family          = '?'        -- inferred logic family, for the summary line

-- ---------- edge list ----------
-- ei[k] is a fractional 1-based sample position (sample i is at time (i-1)/fs), interpolated to the threshold
-- crossing, because grid-quantised edges walk the mid-bit sampling point into the next bit across a frame.
sdec.ne  = sdec.ne or 0
-- sdec.ei          -- fractional sample position of each edge
-- sdec.es          -- physical level after edge k: 1 = high, 0 = low
sdec.st0 = sdec.st0 or 1    -- physical level at the start of the capture
sdec.maxback = 64   -- how far to walk back from a hysteresis trip for the crossing

-- ---------- bit timing ----------
-- sdec.bittime (samples, the native unit), sdec.baud_raw (fs / bittime), sdec.baud (snapped when close enough)
sdec.fitq     = sdec.fitq or 0    -- 0..1 quality of the least-squares fit
sdec.snapped  = sdec.snapped or false
sdec.snaptol  = 0.02  -- snap when within 2 % of a standard rate
sdec.maxmult  = 12    -- a gap longer than this many bit times is idle, not data

-- Standard rates. 153600, 172800 and 192000 are here because a rate that cannot snap cannot auto-lock and the
-- recording modes are gated on a lock. docs/MEASUREMENTS.md, 'Why 153600, 172800 and 192000 are in stdbaud'.
sdec.stdbaud = {110, 300, 600, 1200, 1800, 2400, 4800, 7200, 9600, 14400,
                19200, 28800, 31250, 38400, 57600, 76800, 115200, 128000,
                153600, 172800, 192000, 230400, 250000, 460800, 921600}

-- The two logic levels are the two densest amplitudes.
-- docs/MEASUREMENTS.md, 'Why the levels are the two densest amplitudes'.

-- The bin count is adaptive, capped here. docs/MEASUREMENTS.md, 'binocc = 16'.
sdec.nbins     = 512
sdec.binocc    = 16    -- target samples per BIN
-- Minimum samples in the minority hump for it to count as a logic level, which is a different quantity from
-- binocc. docs/MEASUREMENTS.md, 'minhump = 2'.
sdec.minhump   = 2
sdec.flatfloor = 1.0    -- below this an idle level counts as sitting at ground

-- ============================================================================
-- Arming from silence: waiting for a device that has not started talking yet. The probe finds no transitions, so
-- the silent branch in sdec.acquire() arms the comparator arm_level_v() volts from the idle level, on the side
-- the start bit travels. Options carries these two settings as 'Arm At' and 'Arm Wait'; armlevel equals
-- sdec.flatfloor by coincidence. docs/MEASUREMENTS.md, 'armlevel 1.0, floor 0.33, ceiling 6.0'.
sdec.armlevel     = sdec.armlevel or 1.0
sdec.armlevel_min = 0.33
sdec.armlevel_max = 6.0

-- How long such an arm may wait, in seconds, and the panel is frozen for the whole of it.
-- docs/MEASUREMENTS.md, 'armwait 10, floor 2, ceiling 120'.
sdec.armwait     = sdec.armwait or 10.0
sdec.armwait_min = 2.0
sdec.armwait_max = 120.0

-- May the front TRIGGER key cut an arm short? On, it being the only escape from the wait that works -- see the
-- blend in acq_triggered(). Not on the form: an accidental press costs one retry.
if sdec.armkey == nil then sdec.armkey = true end

-- Both read through one function each, by the capture and by the form, so a typed value cannot mean one thing
-- to the field and another to the comparator. Clamped rather than refused.
function sdec.arm_level_v()
  local v = tonumber(sdec.armlevel)
  if v == nil or v < sdec.armlevel_min then return sdec.armlevel_min end
  if v > sdec.armlevel_max then return sdec.armlevel_max end
  return v
end

-- Clamped to the same [min, max] the field offers, so the form and the comparator cannot disagree.
function sdec.arm_wait_s()
  local w = tonumber(sdec.armwait)
  if w == nil or w < sdec.armwait_min then return sdec.armwait_min end
  if w > sdec.armwait_max then return sdec.armwait_max end
  return w
end

-- The rate an arm from silence captures at: the fastest line it commits to decoding, and the samples per bit it
-- must have there. docs/MEASUREMENTS.md, 'The blind arm commits to 38400, and the choice is a window length'.
sdec.arm_baud  = 38400
-- One sample over sdec.minsabit, deliberately not the sdec.fs_sabit target of 8: this is the rate the window is
-- traded against. The suite asserts the relation, so raising minsabit cannot leave this below it.
sdec.arm_sabit = 5

function sdec.arm_fs()
  return sdec.pick_fs(sdec.arm_baud, sdec.arm_sabit)
end

-- The rates a blind armed capture falls back on, fitted to the samples already in hand so no byte of the start is
-- traded for the attempt. arm_fit_prior() drops any entry needing more samples per bit than the window has.
sdec.arm_try = {9600, 19200, 28800, 31250, 38400}

-- Is this capture waiting for a device that has not started? sdec.probe_idle alone is not the condition, which is
-- why this is a function: it is equally true of every flow-controlled capture, where the probe runs nofc.
function sdec.arm_silent()
  if sdec.probe_idle == nil then return false end
  if sdec.fc_out then return false end
  return true
end
-- How long a run must be before sig_idle will believe it is idle, in estimated bit times. Guards the run-length
-- branch, and is not what inverts captures on the bench. docs/MEASUREMENTS.md, 'idlemult = 10.5'.
sdec.idlemult  = 10.5
-- Share of samples sitting at one of the two levels; a clean line is ~0.95. Below warnmodal the baseline is
-- unstable but still decoded; below minmodal there are no logic levels, only noise.
sdec.minmodal  = 0.15
sdec.warnmodal = 0.50

-- Bins at or above humpfrac of a peak's own height count as part of it, which measures each hump's width: the
-- separation cannot be a fixed voltage, because noise widens the humps.
sdec.humpfrac = 0.2

-- The two densest amplitudes within [v0, v1]. Returns lo, hi and the share of in-range samples belonging to
-- either hump, or nil when no pair is separable. Each level is the true mean of the samples in its hump.
function sdec.sig_pair(rd, n, v0, v1)
  local floor = math.floor
  local nb = floor(n / sdec.binocc)
  if nb > sdec.nbins then nb = sdec.nbins end
  if nb < 24 then nb = 24 end
  if v0 == nil or v1 == nil or v1 <= v0 then return nil end
  local scale = (nb - 1) / (v1 - v0)
  local hist = {}
  -- The sum of the samples in each bin makes the level means below a walk over bins, not over the capture.
  local bsum = {}
  local i
  for i = 1, nb do hist[i] = 0; bsum[i] = 0 end
  local cnt = 0
  for i = 1, n do
    local v = rd[i]
    if v ~= nil and v >= v0 and v <= v1 then
      local b = floor((v - v0) * scale) + 1
      hist[b] = hist[b] + 1
      bsum[b] = bsum[b] + v
      cnt = cnt + 1
    end
  end
  if cnt < 4 then return nil end

  local m1, c1 = 1, -1
  for i = 1, nb do
    if hist[i] > c1 then m1, c1 = i, hist[i] end
  end

  local edge = sdec.humpfrac * c1
  if edge < 1 then edge = 1 end
  local a1, b1 = m1, m1
  while a1 > 1 and hist[a1 - 1] >= edge do a1 = a1 - 1 end
  while b1 < nb and hist[b1 + 1] >= edge do b1 = b1 + 1 end

  -- The tallest bin outside that hump. Spikes cannot win it, differing amplitudes scattering them one or two
  -- samples to a bin; broadband noise cannot either, its single hump leaving nothing outside.
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

  -- Each level is the true mean of the samples inside its hump, and membership is the bin index the histogram pass
  -- already summed by. docs/MEASUREMENTS.md, 'Hump membership is the bin index'.
  local sa, na, sb, nbb = 0, 0, 0, 0
  for i = a1, b1 do
    sa = sa + bsum[i]
    na = na + hist[i]
  end
  for i = a2, b2 do
    sb = sb + bsum[i]
    nbb = nbb + hist[i]
  end
  -- A hump of one sample is not a level, and 2 is the minimum that does it. docs/MEASUREMENTS.md, 'minhump = 2'.
  if na < 1 or nbb < sdec.minhump then return nil end
  local v1m, v2m = sa / na, sb / nbb
  if v2m < v1m then v1m, v2m = v2m, v1m end
  return v1m, v2m, (na + nbb) / cnt
end

-- Every field the signal chain measures, back to its power-on value. Called from sdec.acquire() and
-- sdec.clear_result(). docs/MEASUREMENTS.md, 'A measurement must not cross a capture boundary'.
function sdec.clear_measured()
  sdec.acq_fs, sdec.acq_fs_est = nil, nil
  -- arm_slope() and arm_comparator() prefer these where they exist, so a pair left over from a capture of a silent
  -- line would arm the next capture of a busy one at the wrong level, on the wrong edge.
  sdec.arm_thr, sdec.arm_idle = nil, nil
  -- sdec.wmed gates candidate rates in ua_cands() and sdec.wshort gates them in ua_minrun_absurd(), so a stale one
  -- rejects the true bit time of the capture in hand.
  sdec.w, sdec.nw, sdec.wmed, sdec.wshort = nil, 0, nil, nil
  sdec.snr_db, sdec.noise_v = nil, nil
  sdec.idle, sdec.idle_weak = nil, nil
  -- acq_triggered sets acq_pretrig on its successful exit and acq_free clears it, so the probe read inside one
  -- acquire() cannot leave the real capture looking armed.
  sdec.acq_pretrig, sdec.leadrun, sdec.idlerec = nil, nil, nil
  -- sig_idle() reads st0, so it goes back to its declared default rather than to nil.
  sdec.modal, sdec.run0, sdec.run1 = nil, nil, nil
  sdec.st0 = 1
  return true
end

-- Returns ok, reason. Sets lo/hi/thr/hyst/swing/family, wlo/whi, modal, and the remembered
-- lvl_thr/lvl_hyst/lvl_swing that serial_app saves and restores.
function sdec.sig_levels(rd, n)
  -- Cleared here, not only in sig_noise: every refusal path below returns before sig_noise runs.
  sdec.snr_db, sdec.noise_v = nil, nil
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

  -- Pass one over the full extremes locates the pair coarsely, its bin width set by the furthest outlier; pass two
  -- re-bins over the swing, and only where the extremes are much wider than it.
  local lo, hi, modal = sdec.sig_pair(rd, n, vmin, vmax)
  if lo ~= nil and (vmax - vmin) > 3 * (hi - lo) then
    local pad = 0.5 * (hi - lo)
    if pad < sdec.minswing then pad = sdec.minswing end
    local lo2, hi2, modal2 = sdec.sig_pair(rd, n, lo - pad, hi + pad)
    if lo2 ~= nil and modal2 >= modal then lo, hi, modal = lo2, hi2, modal2 end
  end

  if lo == nil or hi - lo < sdec.minswing then
    -- No separable pair: a flat line, or a swing too small to call. Report the case rather than manufacturing
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
  -- Two humps holding almost none of the samples are broadband noise, or a signal buried in it.
  if modal < sdec.minmodal then
    return false, string.format('no clear logic levels (%.0f %% of samples near them)',
                                100 * modal)
  end
  -- Remembered across captures, unlike sdec.thr: a recording's idle watchdog needs a threshold before the device
  -- has spoken. After the modal gate, so a refused capture cannot overwrite it.
  sdec.lvl_thr, sdec.lvl_hyst, sdec.lvl_swing = sdec.thr, sdec.hyst, sdec.swing
  sdec.sig_noise(rd, n)
  return true
end

-- Signal-to-noise on the two logic levels, in dB. Sets sdec.snr_db and sdec.noise_v, and is positive by
-- construction. docs/MEASUREMENTS.md, 'Noise is excluded by position, not by amplitude'.
sdec.noise_nsamp = 1000

function sdec.sig_noise(rd, n)
  -- Localised here because serial_core takes math.* per function rather than once at file scope.
  local floor, sqrt, log = math.floor, math.sqrt, math.log
  sdec.snr_db, sdec.noise_v = nil, nil
  if rd == nil or n == nil or n < 8 then return end
  local thr, hy, sw = sdec.thr, sdec.hyst, sdec.swing
  if thr == nil or hy == nil or sw == nil or sw <= 0 then return end
  local step = floor(n / sdec.noise_nsamp)
  if step < 1 then step = 1 end
  local nlo, slo, qlo, nhi, shi, qhi = 0, 0, 0, 0, 0, 0
  local i = 2
  while i <= n - 1 do
    local v = rd[i]
    if v ~= nil then
      local up = v > thr + hy
      local dn = v < thr - hy
      -- Excluded by position, not by voltage: both neighbours must be on the same side.
      local a, b = rd[i - 1], rd[i + 1]
      if up and a ~= nil and b ~= nil and a > thr + hy and b > thr + hy then
        nhi = nhi + 1; shi = shi + v; qhi = qhi + v * v
      elseif dn and a ~= nil and b ~= nil and a < thr - hy and b < thr - hy then
        nlo = nlo + 1; slo = slo + v; qlo = qlo + v * v
      end
    end
    i = i + step
  end
  -- A variance needs two samples, and one level is enough: a capture opening in a long idle offers only one.
  local ss, k = 0, 0
  if nlo > 1 then ss = ss + (qlo - slo * slo / nlo); k = k + nlo - 1 end
  if nhi > 1 then ss = ss + (qhi - shi * shi / nhi); k = k + nhi - 1 end
  if k < 1 then return end
  if ss < 0 then ss = 0 end          -- rounding only, but a negative would kill the sqrt
  local rms = sqrt(ss / k)
  sdec.noise_v = rms
  -- Floored at the digitiser, not at zero: a synthesised capture can be noiseless, and log(0) is -inf.
  if rms < 1e-6 then rms = 1e-6 end
  sdec.snr_db = 20 * (log(sw / rms) / log(10))
end

-- Wire-quality warning about the levels, for the note line. sig_quality is about the sample rate.
function sdec.sig_levelwarn()
  if sdec.modal == nil then return nil end
  if sdec.modal >= sdec.warnmodal then return nil end
  return string.format('baseline unstable -- only %.0f %% of samples sit at a logic level (drift or noise)',
                       100 * sdec.modal)
end

-- Name the logic family from the measured levels: the fastest way to spot a probe on the wrong pin.
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
-- Fractional position of the threshold crossing at or before sample i. Hysteresis makes this necessary: the trip
-- is at thr +- hyst, so thr itself is crossed earlier, and the bit-time fit reads these positions as timing.
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

-- Which physical level is idle (the UART mark level): the level holding the longest single run. A gapless stream
-- of 0x00 defeats it, so it is only a prior and ua_autoformat scores both.
function sdec.sig_idle(rd, n)
  local ne, ei, es = sdec.ne, sdec.ei, sdec.es
  if ne == 0 then
    sdec.run1, sdec.run0 = 0, 0
    sdec.idle = sdec.st0
    return sdec.st0
  end

  local best1, best0 = 0, 0
  -- onebit is computed first because the recurrence test below needs the idle threshold. It reads only ei.
  local onebit = sdec.sig_onebit(ei, ne)
  local idlelen = nil
  if onebit ~= nil then idlelen = sdec.idlemult * onebit end

  local k
  local nlong1, nlong0 = 0, 0
  for k = 1, ne - 1 do
    local len = ei[k+1] - ei[k]
    if es[k] == 1 then
      if len > best1 then best1 = len end
      if idlelen ~= nil and len >= idlelen then nlong1 = nlong1 + 1 end
    else
      if len > best0 then best0 = len end
      if idlelen ~= nil and len >= idlelen then nlong0 = nlong0 + 1 end
    end
  end

  local tail = n - ei[ne]
  if es[ne] == 1 then
    if tail > best1 then best1 = tail end
  else
    if tail > best0 then best0 = tail end
  end

  -- On an armed capture the leading run is the reserve, not the line, and the interior must recur.
  -- docs/MEASUREMENTS.md, "sig_idle's run branch, and when the levels decide instead".
  local lead = ei[1] - 1
  -- Published for the record, like sdec.onebit: a lap that cannot see the leading run or the recurrence count
  -- cannot tell this branch from a genuinely inverted line.
  sdec.leadrun = lead
  local nrec = nlong1
  if nlong0 > nrec then nrec = nlong0 end
  sdec.idlerec = nrec
  local thin = false
  if sdec.acq_pretrig then
    thin = nrec < 2
  else
    if sdec.st0 == 1 then
      if lead > best1 then best1 = lead end
    else
      if lead > best0 then best0 = lead end
    end
  end

  sdec.run1, sdec.run0 = best1, best0

  -- A run is only evidence of idle if data could not have produced it, and sdec.idlemult carries that margin.
  -- sdec.onebit is published for the record. docs/MEASUREMENTS.md, 'idlemult = 10.5'.
  sdec.onebit = onebit
  local longest = best1
  if best0 > longest then longest = best0 end
  -- `thin` forces this branch on an armed capture whose interior idle does not recur. Without it the branch is
  -- unreachable when it is needed, a single long excursion clearing the threshold and deciding unopposed.
  if thin or (onebit ~= nil and longest < sdec.idlemult * onebit) then
    -- The runs carry no information about idle, so decide from the levels: a single-supply line marks high, one
    -- that straddles ground marks at its negative level. Options -> Invert forces it.
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

-- One bit time in samples, from the edge list and not from sdec.w, which is always nil here. A low percentile, not
-- the minimum, so one narrow glitch cannot halve the estimate; interior gaps only.
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
-- Least-squares refinement from a seed bit time. Returns bittime, quality, nfit, or nil when nothing fits. Every
-- pulse width is an integer multiple of the bit time, so this is a fit through the origin: sum(w*m)/sum(m*m).
function sdec.sig_fit(w, nw, seed)
  local floor = math.floor
  local maxm = sdec.maxmult
  local T = seed
  local it, k

  for it = 1, 6 do
    local sn, snn = 0, 0
    -- The tolerance is hoisted and math.abs inlined, this being the hottest counted loop in the app.
    -- docs/MEASUREMENTS.md, 'math.abs was 14.2 % of every C call the app makes'.
    local tol = 0.35 * T
    for k = 1, nw do
      local wk = w[k]
      local m = floor(wk / T + 0.5)
      -- Multiples beyond maxmult are inter-byte idle, carry no timing information, and must not drag the fit.
      if m >= 1 and m <= maxm then
        local d = wk - m * T
        if d < 0 then d = -d end
        if d < tol then
          sn  = sn + wk * m
          snn = snn + m * m
        end
      end
    end
    if snn <= 0 then return nil, 0, 0 end
    local newT = sn / snn
    local moved = newT - T
    if moved < 0 then moved = -moved end
    T = newT
    if moved < 1e-9 * T then break end
  end

  -- Quality combines fit tightness with coverage, which rejects a seed at twice the true bit time: the one-bit
  -- pulses stay inside maxmult*T, so they count as eligible but land half a period from any multiple.
  local serr, nfit, nsmall = 0, 0, 0
  local tol = 0.35 * T
  local maxw = (maxm + 0.5) * T
  for k = 1, nw do
    local wk = w[k]
    if wk <= maxw then
      nsmall = nsmall + 1
      local m = floor(wk / T + 0.5)
      if m < 1 then m = 1 end
      local e = wk - m * T
      if e < 0 then e = -e end
      if e < tol then
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
  -- snapfirm starts true because nothing has been claimed yet: a false would mark every pre-capture panel
  -- approximate.
  sdec.fitq, sdec.snapped, sdec.snapfirm = 0, false, true
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
  -- The median pulse width, kept for sdec.ua_cands(). Spikes are always a minority of the widths, so they cannot
  -- move it -- unlike the least-squares fit below, which they capture outright.
  sdec.wmed = s[math.floor(nw / 2) + 1]

  -- The short end of the same sort, for sdec.ua_minrun_absurd(). Not named wlo: sig_levels owns that name for a
  -- voltage, and overwriting it made the panel's range figure report a pulse width.
  sdec.wshort = s[math.floor(nw * 0.05) + 1]

  -- Candidate seeds: the smallest corroborated widths -- another within 25 % -- thinned to be >30 % apart. A fit
  -- seeded from one isolated short width can score higher than the truth.
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

  -- Seeds ascend and the comparison is strict, so a tie keeps the higher baud. A proposal only: widths can share a
  -- common factor, so ua_best() rescales and lets the frame decode arbitrate.
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
  sdec.baud, sdec.snapped, sdec.snapfirm = sdec.sig_snap(sdec.baud_raw)
  return bestT
end

-- How close the measurement must land for a snap to read as certain rather than merely chosen.
-- docs/MEASUREMENTS.md, 'snaptol_firm = 1.25 %'.
sdec.snaptol_firm = sdec.snaptol_firm or 0.0125

-- Snap a measured rate to a standard one when it is within tolerance. Returns rate, snapped, firm -- the third
-- separate on purpose: `snapped` is evidence ua_best acts on, `firm` is read only where confidence is claimed.
function sdec.sig_snap(b)
  if b == nil then return nil, false, false end
  local best, bestd = nil, nil
  local i
  local nb = table.getn(sdec.stdbaud)
  for i = 1, nb do
    local r = sdec.stdbaud[i]
    local d = b / r - 1
    if d < 0 then d = -d end
    if bestd == nil or d < bestd then best, bestd = r, d end
  end
  if bestd ~= nil and bestd <= sdec.snaptol then
    return best, true, bestd <= sdec.snaptol_firm
  end
  -- Not snapped is firm: the measurement is reported as itself, so nothing has been overstated.
  return b, false, true
end

-- Round a measured rate to a credible setting: the coarsest step that moves it less than 1 %. Returns rate,
-- credible. docs/MEASUREMENTS.md, 'baud_round cascades through three steps'.
sdec.baud_round_lo   = 10       -- step below the crossover
sdec.baud_round_hi   = 100      -- step above it
sdec.baud_round_at   = 10000    -- crossover
sdec.baud_round_fine = 1        -- the fallback: always inside the cap above sdec.minbaud
sdec.baud_round_tol  = 0.01     -- largest shift any step may make
function sdec.baud_round(b)
  if b == nil or b <= 0 then return b, false end
  local i
  for i = 1, table.getn(sdec.stdbaud) do
    if sdec.stdbaud[i] == b then return b, true end
  end
  -- Coarsest first, so the rule stays "100 over 10 kBd, 10 below" and the fine step rescues the rest.
  local steps, ns = {}, 0
  if b >= sdec.baud_round_at then ns = ns + 1; steps[ns] = sdec.baud_round_hi end
  ns = ns + 1; steps[ns] = sdec.baud_round_lo
  ns = ns + 1; steps[ns] = sdec.baud_round_fine
  local k
  for k = 1, ns do
    local r = math.floor(b / steps[k] + 0.5) * steps[k]
    if r > 0 then
      local d = r / b - 1
      if d < 0 then d = -d end
      if d <= sdec.baud_round_tol then return r, true end
    end
  end
  return b, false
end

-- The ceiling. 4 samples per bit is the wall, and at 1 MS/s that puts it at exactly 250 kBd -- a declared limit,
-- not an emergent one. docs/MEASUREMENTS.md, 'minsabit, and why the floor exists at all'.
sdec.minsabit = 4
sdec.maxbaud  = 250000
-- The floor on the rate itself, as maxbaud is the ceiling: below it a candidate bit time is the fit having landed
-- on a long multiple. Named here so it sits beside the ceiling it mirrors, which carried sdec.plaustol first.
sdec.minbaud  = 100

-- One-line verdict on the signal, for the panel and the log.
function sdec.sig_quality()
  local T = sdec.bittime
  if T == nil then return nil, 'no bit time' end
  if T <= sdec.minsabit then
    -- Which limit is actually tight, the same question ua_implausible_why answers: minsabit samples per bit is
    -- maxbaud only at the top rate, and this warning sits beside a decode that succeeded.
    local fs = sdec.acq_fs or sdec.fs
    if fs ~= nil and fs > 0 and fs / T > sdec.maxbaud * (1 - sdec.plaustol) then
      return T, string.format('only %.1f samples/bit -- at or past the %d kBd ceiling',
                              T or 0, sdec.maxbaud / 1000)
    end
    return T, string.format('only %.1f samples/bit at %.0f kSa/s -- no margin left in the capture rate',
                            T or 0, (fs or 0) / 1000)
  end
  return T
end

-- ============================================================================
-- Acquisition
-- ============================================================================
-- Pick the lowest listed sample rate giving at least `want` samples per bit. A lower rate covers more time in
-- the same buffer, which is what decides how many bytes a capture holds.
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

-- Derive the true sample rate from the buffer's own timestamps, the only trustworthy source. Guarded at the proxy
-- read: a buffer the firmware has dropped raises rather than returning nil.
function sdec.acq_measure_fs(buf, n)
  if buf == nil or n == nil or n < 2 then return nil end
  -- A nil test cannot replace the guard: existence and a successful proxy read are different claims. The two ends
  -- are taken in time order -- on a wrapped buffer not index 1 and n, see acq_first.
  local first = sdec.acq_first(buf, n)
  local last = first + n - 1
  if last > n then last = last - n end
  local t1, tn = nil, nil
  local ok = pcall(function()
    local ts = buf.relativetimestamps
    if ts ~= nil then t1, tn = ts[first], ts[last] end
  end)
  if not ok then return nil end
  if t1 == nil or tn == nil then return nil end
  local span = tn - t1
  if span <= 0 then return nil end
  return (n - 1) / span
end

-- The measured rate, or the requested one with a flag saying so: every byte is scaled by acq_fs, so a silent
-- substitution would report confident bytes from an untrustworthy number.
function sdec.acq_fs_or_requested(buf, n)
  local m = nil
  m = sdec.acq_measure_fs(buf, n)
  if m ~= nil then
    sdec.acq_fs_est = nil
    return m
  end
  sdec.acq_fs_est = true
  return sdec.fs
end

-- ============================================================================
-- Sample rate follows a known baud rate. This is where most of the app's usable text comes from.
-- ============================================================================
-- A forced baud rate is known before the capture, so the rate is chosen deterministically and a lower rate is a
-- longer window. It must reset when nothing is forced, or detection stays capped at fs / minsabit.
-- docs/MEASUREMENTS.md, 'Sample rate follows a forced baud rate'.
sdec.fs_default = 1000000
sdec.fs_sabit   = 8

-- Lowest listed sample rate giving at least `sabit` samples per bit at this baud rate.
function sdec.fs_for_baud(baud)
  local top = sdec.rates[table.getn(sdec.rates)]
  if baud == nil or baud <= 0 then return sdec.fs_default end
  local want = baud * sdec.fs_sabit
  local i
  for i = 1, table.getn(sdec.rates) do
    if sdec.rates[i] >= want then return sdec.rates[i] end
  end
  return top                      -- faster than the instrument can sample; clamp
end

-- The streaming modes want the opposite rate from frame, decode cost being per sample:
--
--     samples/byte = framebits x (fs / baud)      decode ceiling = 1 / (samples_per_byte x Tread)
--
-- fs_for_baud() maximises oversampling, right for frame and wrong for a streaming mode where everything is
-- forced. docs/MEASUREMENTS.md, 'fs_for_burst delivers a floor rather than requesting one'.

-- A SimpleLoop trigger model adds a constant 0.510 us to every sample interval, which the streaming modes live
-- with because the alternative loses data at the seams. docs/MEASUREMENTS.md, 'acq_overhead = 0.510 us'.
sdec.acq_overhead = 0.510e-6

-- The rate that delivers `want` samples per bit, not the rate that would without overhead; nil when none can.
-- docs/MEASUREMENTS.md, 'The no-loss sample rate is 120 kS/s, and baud is not in it'.
sdec.minsabit_tier = {{9600, 8}, {19200, 5}}

-- And a rate ceiling, which keeps the instrument's own backlog dialog off the capture and may override the floor,
-- but never past minsabit. docs/MEASUREMENTS.md, 'The reading-backlog dialog above ~100 kS/s'.
sdec.fs_cap_tier = {{19200, 100000}}

-- Nor more oversampling than the decoder can use: past the vote threshold extra samples buy only bit-centre
-- placement, while costing readings and a decode priced per sample. docs/MEASUREMENTS.md, 'sabit_max = 12'.
sdec.sabit_max = 12

-- `md` is optional and bounds the boost by what the buffer can afford, so the ceiling is per mode rather than per
-- baud. docs/MEASUREMENTS.md, 'What the ck_bufmax bound on oversampling is worth'.
function sdec.fs_for_burst(baud, md)
  if baud == nil or baud <= 0 then return sdec.fs_default end
  local want = sdec.minsabit
  -- Nil-guarded: a probe that cleared the table must degrade to the flat floor rather than raise.
  if sdec.minsabit_tier ~= nil then
    local ti
    for ti = 1, table.getn(sdec.minsabit_tier) do
      local tier = sdec.minsabit_tier[ti]
      if baud <= tier[1] then
        if tier[2] > want then want = tier[2] end
        break
      end
    end
  end
  local ideal = 1 / (baud * want)
  if ideal <= sdec.acq_overhead then return nil end   -- unreachable at any rate
  local need = 1 / (ideal - sdec.acq_overhead)
  local i
  local lowest = nil
  for i = 1, table.getn(sdec.rates) do
    if sdec.rates[i] >= need then
      lowest = sdec.rates[i]
      break
    end
  end
  if lowest == nil then return nil end                -- past the top listed rate

  -- Then take the most oversampling the ceilings allow, which is why `lowest` is only a starting point: where a
  -- rate cap applies the samples above the floor are free. Bounded by the cap and by sabit_max.
  local cap = nil
  if sdec.fs_cap_tier ~= nil then
    local ci
    for ci = 1, table.getn(sdec.fs_cap_tier) do
      if baud <= sdec.fs_cap_tier[ci][1] then
        cap = sdec.fs_cap_tier[ci][2]
        break
      end
    end
  end
  -- What this mode's own buffer can hold, in samples per bit. nil where the mode is not byte-capped.
  local sabcap = nil
  if md ~= nil and md.cap ~= nil and sdec.ck_bufmax ~= nil then
    local nbits = sdec.force_nbits or 8
    local parbits = 0
    if sdec.force_par ~= nil and sdec.force_par ~= sdec.PAR_NONE then parbits = 1 end
    local framebits = 1 + nbits + parbits + (sdec.force_nstop or 1)
    -- The count that leaves room for the reserve and the overshoot headroom, which is stream_begin's own clamp
    -- arithmetic inverted. docs/MEASUREMENTS.md, 'What the ck_bufmax bound on oversampling is worth'.
    local nmax = sdec.ck_bufmax - 100
    if sdec.trigmode ~= 'free' then
      nmax = math.floor((sdec.ck_bufmax - 100) * (100 - (sdec.pretrig or 0)) / 100)
    end
    sabcap = nmax / (md.cap * framebits)
  end

  if cap ~= nil and lowest > cap then
    -- The cap wins over the floor here, and only here: the floor's rate would cross the drain rate for a gain the
    -- decoder cannot use. Take the fastest rate under the cap that still clears minsabit.
    local fallback = nil
    for i = 1, table.getn(sdec.rates) do
      local r = sdec.rates[i]
      if r > cap then break end
      if sdec.fs_delivered(r) / baud >= sdec.minsabit then fallback = r end
    end
    if fallback ~= nil then return fallback end
    return lowest
  end
  if cap ~= nil then
    local best = lowest
    for i = 1, table.getn(sdec.rates) do
      local r = sdec.rates[i]
      if r > cap then break end
      if r >= lowest then
        local t = sdec.fs_delivered(r) / baud
        local ok = (sdec.sabit_max == nil or t <= sdec.sabit_max)
        -- The requested ratio is what sizes the capture, not the delivered one: stream_samples multiplies by
        -- fs/baud, so that is the figure the buffer has to hold.
        if ok and sabcap ~= nil and (r / baud) > sabcap then ok = false end
        if ok then best = r end
      end
    end
    return best
  end
  return lowest
end

-- What a requested rate actually delivers. Used by the panel so the operator sees the delivered figure: SA/BIT
-- comes from acq_fs after a capture, and before one there is nothing measured to show.
function sdec.fs_delivered(fs)
  if fs == nil or fs <= 0 then return nil end
  return 1 / (1 / fs + sdec.acq_overhead)
end

-- Call before every capture. Stateless by construction: it derives fs from the current forced rate and the current
-- mode each time rather than remembering anything.
function sdec.fs_select()
  -- A rate the caller already worked out wins, and without this the two-pass auto-detect cannot work. One-shot,
  -- describing a decision for the next capture only. docs/MEASUREMENTS.md, 'fs_want: the second pass of autoset'.
  if sdec.fs_want ~= nil then
    sdec.fs = sdec.fs_want
    sdec.fs_want = nil
    return sdec.fs
  end
  if sdec.force_baud ~= nil and sdec.force_baud > 0 then
    -- mode_cur lives in serial_ui.tsp; guarded so serial_core stays usable on its own, falling back to the frame
    -- rule, which is the conservative direction since it oversamples.
    local md = nil
    if sdec.mode_cur ~= nil then md = sdec.mode_cur() end
    if md ~= nil and md.needbaud then
      -- nil means no listed rate delivers minsabit here, so fall back to the top rate; mode_why() is what refuses.
      -- md is passed so the boost cannot shorten a byte-capped recording.
      sdec.fs = sdec.fs_for_burst(sdec.force_baud, md) or
                sdec.rates[table.getn(sdec.rates)]
    else
      sdec.fs = sdec.fs_for_baud(sdec.force_baud)
    end
  else
    sdec.fs = sdec.fs_default
  end
  return sdec.fs
end

-- How many bytes a capture can physically hold, from acq_fs rather than the requested rate: the only way to know
-- whether a message was seen whole. docs/MEASUREMENTS.md, 'window_bytes: one division, not two'.

-- Capacity a capture of n samples needs. Frame only -- SimpleLoop has no reserve.
-- docs/MEASUREMENTS.md, 'The pre-trigger reserve comes out of capacity, not out of count'.
function sdec.acq_cap(n)
  if n == nil then n = sdec.n end
  if n == nil then return nil end
  if sdec.trigmode == 'free' then return n end
  -- Headroom unconditionally, including at pretrig = 0: the model can make a reading or two past `count` before
  -- abort() takes effect, and with a buffer sized exactly n that overshoot is a discard.
  return n + math.ceil(n * (sdec.pretrig or 0) / 100) + 100
end

-- Fill continuously, so nothing is ever stored past the end of the buffer, and the numeric assignment is the only
-- route to it. docs/MEASUREMENTS.md, 'A reserve in a FILL_ONCE buffer posts 4915 per discard'.
function sdec.acq_fillmode(buf)
  if buf == nil then return false end
  return pcall(function() buf.fillmode = 1 end)
end

-- Readings the pre-trigger reserve holds, and how long that is in time, which decides whether it wraps.
-- docs/MEASUREMENTS.md, 'A reserve in a FILL_ONCE buffer posts 4915 per discard'.
function sdec.acq_reserve(n)
  if n == nil then n = sdec.n end
  local pt = sdec.pretrig or 0
  if pt <= 0 then return 0 end
  return math.ceil((sdec.acq_cap(n) or n) * pt / 100)
end

-- How many samples a capture actually delivers, which is not sdec.n on the armed path, and a floor never a
-- ceiling. docs/MEASUREMENTS.md, 'The pre-trigger reserve comes out of capacity, not out of count'.
function sdec.n_deliv(n)
  if n == nil then n = sdec.n end
  if n == nil then return nil end
  if sdec.trigmode == 'free' then return n end
  local pt = sdec.pretrig or 0
  -- At pretrig = 0 the rule gives the whole capacity. Reported as n, the headroom absorbing the overshoot.
  if pt <= 0 then return n end
  local cap = sdec.acq_cap(n) or n
  return math.floor(cap * (100 - pt) / 100)
end

-- How many bytes one capture window can hold at this rate and format.
function sdec.window_bytes(baud, nbits, par, nstop)
  local fs = sdec.acq_fs or sdec.fs
  if baud == nil or baud <= 0 or fs == nil or fs <= 0 then return nil end
  local parbits = 0
  if par ~= nil and par ~= sdec.PAR_NONE then parbits = 1 end
  local framebits = 1 + (nbits or 8) + parbits + (nstop or 1)
  if fs / baud <= 0 then return nil end
  -- Still sdec.n and not sdec.n_deliv(), a known 5 % overstatement on the armed path: n_deliv() depends on
  -- trigmode, so the figure would flip with a setting nobody connects to it.
  return math.floor((sdec.n * baud) / (fs * framebits))
end

-- Configure the digitizer. Fixed range and a 1 us aperture: autorange would rescale mid-capture, and APERTURE_AUTO
-- rounds off the edges. Set the rate before the aperture, or it is adjusted silently.

-- Configure the rear EXT TRIG OUT line for flow control, or leave it alone. Re-applied per capture,
-- trigger.extout.logic being reset by an I/O trigger reset. LOGIC_POSITIVE, so a rising edge.
function sdec.fc_config()
  if not sdec.fc_out then return false end
  -- trigger.extout does not exist on every supported model, so the write cannot be bare: the 2461 carries a
  -- digital I/O port instead. false is the same answer this gives when the feature is off.
  if trigger.extout == nil then return false end
  trigger.extout.logic = trigger.LOGIC_POSITIVE
  -- The width is the only attribute here that may not exist, so the nil test is expected to be false on this
  -- model. It stays separate from the pcall so that a refused width cannot lose the logic setting above.
  if trigger.extout.pulsewidth ~= nil then
    pcall(function() trigger.extout.pulsewidth = sdec.fc_pulse end)
  end
  return true
end

-- Stop the firmware popping dialogs over the app: normal operation posts 2731 and 2732 per armed capture and 2205
-- per byte-log probe. showevents selects what is displayed, not what is logged.
function sdec.quiet_events()
  -- Bare: eventlog.SEV_ERROR is a documented constant, so there is nothing for a pcall to catch.
  localnode.showevents = eventlog.SEV_ERROR
  return true
end

-- Mute the panel's event popups where the firmware honours the mute, which for 4915 it does not.
-- docs/MEASUREMENTS.md, 'A reserve in a FILL_ONCE buffer posts 4915 per discard'.
function sdec.mute_events()
  localnode.showevents = 0
  return true
end

function sdec.unmute_events()
  localnode.showevents = eventlog.SEV_ERROR
  return true
end

-- Remember the measurement mode the instrument was left in, choosing a digitize function deselecting the basic
-- one. A pair is saved, and only on the digitize side. One-shot: the entry value.
function sdec.mode_save()
  if sdec.entrymode ~= nil then return true end
  if sdec.dig == nil then return false end
  local m = nil
  -- One pcall around all the reads, so a partially-read mode is never stored: a nil would raise in teardown.
  local ok = pcall(function()
    local df = sdec.dig.func
    if sdec.k.FUNC_NONE ~= nil and df == sdec.k.FUNC_NONE then
      m = {side = 'measure', func = sdec.meas.func}
    else
      -- Already digitizing, so the four fields hw_config() writes are the ones at risk. Reached also where the
      -- namespace has no FUNC_NONE and the modes cannot be told apart.
      m = {side = 'digitize', func = df, range = sdec.dig.range,
           samplerate = sdec.dig.samplerate, aperture = sdec.dig.aperture}
    end
  end)
  if not ok or m == nil or m.func == nil then return false end
  sdec.entrymode = m
  return true
end

-- Is a digitize function selected right now? Writing sdec.dig or sdec.atrig under a basic function posts 2800, an
-- event rather than a Lua error. True when it cannot tell, the safe direction.
function sdec.digitizing()
  if sdec.dig == nil then return false end
  if sdec.k.FUNC_NONE == nil then return true end
  -- Guarded: .func is an IPC read of the second processor's state, not a table lookup.
  local f = nil
  if not pcall(function() f = sdec.dig.func end) then return true end
  return f ~= sdec.k.FUNC_NONE
end

-- Put back what mode_save() found. Safe to call with nothing saved, and safe to call twice.
function sdec.mode_restore()
  local m = sdec.entrymode
  if m == nil then return true end
  -- Cleared before the write, so a raise inside teardown is not retried on the next call.
  sdec.entrymode = nil
  local ok = pcall(function()
    if m.side == 'measure' then
      -- One assignment does the whole job: selecting a basic function is what deselects the digitize one.
      sdec.meas.func = m.func
    else
      sdec.dig.func = m.func
      -- Each guarded separately: an attribute this firmware does not expose reads nil, and assigning nil back raises.
      if m.range      ~= nil then sdec.dig.range      = m.range      end
      if m.samplerate ~= nil then sdec.dig.samplerate = m.samplerate end
      if m.aperture   ~= nil then sdec.dig.aperture   = m.aperture   end
    end
  end)
  return ok
end

-- Every detection setting back to automatic, and every rear-BNC option off: none reset themselves, and only a
-- power cycle nils `sdec`. The lock goes through unlock_all(), which knows all five.
function sdec.reset_options()
  sdec.unlock_all()
  sdec.proto = 'uart'
  sdec.proto_why = nil
  -- The capture mode deserves resetting most: a session left in 32 kB makes the first press of a fresh launch a
  -- minutes-long recording, with a file written and no way to stop it.
  sdec.capmode = 'frame'
  sdec.ui_mode = 'text'
  sdec.widths_any = false
  sdec.trigmode = 'edge'
  -- Both rear-BNC directions, so the connector is not in the signal path at all.
  sdec.trigext = false
  sdec.trigext_only = false
  sdec.fc_out = false
  return true
end

-- Relative compare for a readback: a float attribute can come back a bit-wobble away from what went in, and that
-- is not a snap. Non-numbers compare by identity, which the func constant needs.
function sdec.hw_same(want, got)
  if type(want) ~= 'number' or type(got) ~= 'number' then return want == got end
  local d = want - got
  if d < 0 then d = -d end
  local s = want
  if s < 0 then s = -s end
  if s < 1 then s = 1 end
  return d / s < 1e-9
end

-- What the digitizer actually took. -> true if everything matched. One pcall for all three reads, at one boundary.
-- docs/MEASUREMENTS.md, 'hw_verify reads back three attributes, once a launch'.
sdec.hw_checked = nil

function sdec.hw_verify()
  if sdec.hw_checked then return true end
  sdec.hw_checked = true
  local ok, f, r, a = pcall(function()
    return sdec.dig.func, sdec.dig.range, sdec.dig.aperture
  end)
  -- A meter that will not report its own settings is not a snap, so say nothing rather than accuse it of one.
  if not ok then return true end
  sdec.hw_snap = {func = f, range = r, aperture = a}
  local w = {sdec.k.FUNC_VOLT, sdec.range, 1e-6}
  local g = {f, r, a}
  local nm = {'func', 'range', 'aperture'}
  local allok, i = true, nil
  for i = 1, 3 do
    if not sdec.hw_same(w[i], g[i]) then
      allok = false
      ulog.line(string.format('digitizer %s: asked %s, took %s -- the instrument snapped it',
                              nm[i], tostring(w[i]), tostring(g[i])))
    end
  end
  return allok
end

-- Apply the range, sample rate and trigger settings to the digitizer before a capture.
function sdec.hw_config()
  sdec.quiet_events()
  sdec.fs_select()
  sdec.fc_config()
  sdec.acq_prep()
  sdec.dig.func       = sdec.k.FUNC_VOLT
  sdec.dig.range      = sdec.range
  sdec.dig.samplerate = sdec.fs
  sdec.dig.aperture   = 1e-6
  sdec.hw_verify()
end

-- Clamp a request to what the buffer can hold, reserve included. A store past capacity posts 4915 and truncates
-- the capture.
function sdec.acq_fit(n, buf)
  -- .capacity exists on any non-nil buffer, and reading it still raises once the firmware has dropped it.
  if buf == nil then return n end
  local cap = nil
  pcall(function() cap = buf.capacity end)
  if cap == nil or cap < 10 then return n end
  local room = cap
  if sdec.trigmode ~= 'free' and (sdec.pretrig or 0) > 0 then
    -- A percentage of this buffer, which is what the model takes, and with no fudge term. docs/MEASUREMENTS.md,
    -- 'acq_fit takes a percentage of the buffer, with no fudge term'.
    room = cap - math.ceil(cap * (sdec.pretrig or 0) / 100)
  end
  if room < 10 then room = 10 end
  if n > room then return room end
  return n
end

-- Free and remake the capture buffer. Follows the project's object-lifetime rule -- delete, nil, then create --
-- because creating over a live handle leaves the buffer beneath allocated and unreachable until a power cycle.
function sdec.acq_make_buffer(n)
  -- Never replace a buffer the trigger model may still be writing into, and this is reachable with one armed: it
  -- then stores into a buffer that has been deleted and replaced, which posts 4915.
  sdec.trig_settle()
  if sdec.buf ~= nil then
    local b = sdec.buf
    -- A refused deletion must not be followed by a new allocation, and the handle must not be dropped: nil'ing first
    -- and swallowing the error strands the buffer and allocates another on top, one more on every retry.
    local delok = pcall(buffer.delete, b)
    if not delok then
      sdec.delfails = (sdec.delfails or 0) + 1
      sdec.stickyerr = 'the capture buffer could not be freed -- power cycle the instrument'
      return sdec.buf                    -- KEEP the handle: it is the only way to retry
    end
    sdec.buf = nil
  end
  if n < 10 then n = 10 end     -- buffer.make() minimum
  -- Guarded at the allocation, the only thing left here that can raise. Standard and not compact, and not by
  -- choice -- docs/MEASUREMENTS.md, 'buffer.STYLE_COMPACT is nil on this firmware'.
  local mok, nb = pcall(buffer.make, n, buffer.STYLE_STANDARD)
  if not mok then return nil end
  sdec.buf = nb
  sdec.acq_fillmode(sdec.buf)
  return sdec.buf
end

-- Copy the capture out of the reading buffer into a plain Lua array, once: `buf.readings` is a proxy, so every
-- index is a firmware round trip. docs/MEASUREMENTS.md, 'Reading a sample out of a reading buffer'.

-- An optional liveness hook, nil in the shipped app and set by nothing inside it: one call per chunk of samples.
-- docs/MEASUREMENTS.md, 'sdec.tick: what a soak cell spends inside acquire'.
sdec.tick = nil
sdec.tickevery = sdec.tickevery or 2000    -- samples between hook calls; the bench caps the
                                           -- redraw rate itself, so this only has to be small enough

-- Chunked so the hook costs nothing per sample: a modulo inside the loop would land on all 20 000 iterations of
-- the hottest loop in the acquisition path. Slicing the range leaves the inner loop what it was.

-- Where the oldest reading is, as an index into buf.readings. 1 unless the buffer has wrapped, and the
-- firmware answers it in one proxy read. docs/MEASUREMENTS.md, 'A record can come back rotated'.
function sdec.acq_first(buf, n)
  if buf == nil or n == nil or n < 1 then return 1 end
  -- Only a full buffer can have wrapped, and testing that first is what makes the rest safe to trust: it disarms a
  -- startindex left by an earlier wrapped capture.
  local cap = nil
  if not pcall(function() cap = buf.capacity end) then return 1 end
  if cap ~= nil and n < cap then return 1 end
  local s = nil
  -- Guarded at the proxy read, like every other attribute on this object: on a firmware without startindex the
  -- read must come back as "not rotated" rather than unwinding a capture that is otherwise complete.
  local ok = pcall(function() s = buf.startindex end)
  if not ok or s == nil then return 1 end
  s = math.floor(s)
  if s < 1 or s > n then return 1 end
  return s
end

-- Where the next reading will go, or nil when it cannot be read: the only progress counter that survives a wrap,
-- being a position in the ring. docs/MEASUREMENTS.md, 'A record can come back rotated'.
function sdec.acq_end(buf)
  if buf == nil then return nil end
  local e = nil
  if not pcall(function() e = buf.endindex end) then return nil end
  if e == nil then return nil end
  return math.floor(e)
end

function sdec.acq_copy(buf, n)
  local rd = buf.readings
  local t = {}
  local step = sdec.tickevery
  if step == nil or step < 1 then step = n end
  -- The copy is in time order, not ring order -- see sdec.acq_first. Offset zero is the normal case.
  local off = sdec.acq_first(buf, n) - 1
  local i = 1
  while i <= n do
    local j = i + step - 1
    if j > n then j = n end
    local k
    for k = i, j do
      local p = k + off
      if p > n then p = p - n end
      t[k] = rd[p]
    end
    if sdec.tick ~= nil then sdec.tick() end
    i = j + 1
  end
  sdec.smp = t
  return t
end

-- Untriggered capture of n samples, for the level-learning probe and for 'free' mode. ncopy caps the Lua copy: the
-- streaming fallback arrives with nsmp at 2.8-6 million.
function sdec.acq_free(n, ncopy, nofc)
  local buf = sdec.buf
  -- Try not to read into a buffer a trigger model might still be writing. Best effort only: the verdict is
  -- discarded, so a settle that timed out is followed by buf.clear() and dig.read() regardless.
  sdec.trig_settle()
  n = sdec.acq_fit(n, buf)
  sdec.dig.count = n
  buf.clear()
  -- Flow control on the free-run path too, and before the read. `nofc` suppresses it for the probe reads.
  -- docs/MEASUREMENTS.md, 'The flow-control credit pulse on the free-run path'.
  if sdec.fc_out and not nofc then
    sdec.fc_credit()
  end
  sdec.dig.read(buf)
  sdec.nread = buf.n or 0
  sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  local ncp = sdec.nread
  if ncopy ~= nil and ncopy < ncp then ncp = ncopy end
  sdec.acq_copy(buf, ncp)
  -- A free-running record has no reserve, so its leading run is the line and sig_idle may use it. Cleared rather
  -- than left alone because this is also acq_triggered's failure exit and the level-learning probe.
  sdec.acq_pretrig = nil
  return sdec.nread
end

-- Capture armed on a start-bit edge, keeping sdec.pretrig percent of the buffer from before the trigger, and
-- falling back to free-run if the model errors. A start bit is only a start bit if the line was at mark first.

-- Is the trigger model finished, as opposed to not started yet? idle is also the state before initiate(), hence
-- the buffer check. pcall'd because a state read that raises must degrade to "not finished".
function sdec.trig_done(buf)
  -- On a raise the second result is the message, and a string would read as a state.
  local sok, st = pcall(trigger.model.state)
  if not sok then st = nil end
  if st == nil then return false end
  return st == trigger.STATE_IDLE and (buf.n or 0) > 0
end

-- How long to wait for an armed model to reach its wait block, in seconds. Read only by stream_arm(), so nothing
-- here can lengthen a frame press. docs/MEASUREMENTS.md, 'arm_settle_s = 10'.
sdec.arm_settle_s = 10.0

-- Is the model sitting in a wait block? -> true, false, or nil when it cannot be told; nil means degrade rather
-- than retry. docs/MEASUREMENTS.md, 'buf.n is not evidence of a trigger'.
function sdec.trig_waiting()
  -- On a raise the second result is the message, and a string would read as "not waiting".
  local sok, st = pcall(trigger.model.state)
  if not sok or st == nil then return nil end
  return st == trigger.STATE_WAITING
end

-- Stop the trigger model and wait for it to stop, abort() being asynchronous. Bounded, because a model that will
-- not idle must not hang the panel. Every caller is bare: each firmware call here carries its own guard.
function sdec.trig_settle()
  pcall(trigger.model.abort)
  local i
  local unread = 0
  for i = 1, 50 do
    local sok, st = pcall(trigger.model.state)
    if not sok then st = nil end
    -- A state we could not read is not a model we know is idle, and the callers act on this by deleting the
    -- buffer. Distinguished by the pcall's verdict rather than by the value.
    if sok then
      if st == nil or st == trigger.STATE_IDLE or st == trigger.STATE_ABORTED then
        return true
      end
      unread = 0
    else
      unread = unread + 1
      -- Keep trying first, a transient refusal being likelier than a broken firmware. Persistent failure returns
      -- false and no caller reads it, so this is best effort.
      if unread >= 10 then return false end
    end
    -- The sleep carries its own guard, so a raise out of delay() cannot escape into sdec.stop()'s teardown.
    pcall(delay, 0.01)
  end
  return false
end

-- ============================================================================
-- The cancel key
-- ============================================================================
-- The front-panel TRIGGER key is the only stop control this firmware allows for a job longer than one press, and
-- blender 2 because acq_triggered() owns blender 1. docs/MEASUREMENTS.md, 'The front TRIGGER key is the only
-- stop control this firmware allows'.
sdec.cancel_blender = 2
-- The timeout handed to wait(). Never zero: waitevent() reads zero as "wait for ever" and wedges the box.
sdec.cancel_poll_s = 0.001

-- Send one flow-control credit out of the rear EXT TRIG OUT. Returns whether the pulse went.
function sdec.fc_credit()
  -- Guard the index, not the call: pcall's first argument is evaluated before pcall is entered, so
  -- `pcall(trigger.extout.assert)` raised on a model with no trigger.extout.
  local ok = false
  if trigger.extout ~= nil then ok = pcall(trigger.extout.assert) end
  -- A refused credit is not a quiet line, and without this it looks exactly like one: the window comes back empty
  -- and the run blames the operator's device.
  if not ok then
    sdec.stickyerr = 'the flow-control credit pulse was refused -- the device was never told to send'
  end
  return ok
end

-- Wire the TRIGGER key to blender 2's latch and discard anything already latched. Returns whether the latch is
-- available.
function sdec.cancel_setup()
  local b = sdec.cancel_blender
  local ok = pcall(function()
    trigger.blender[b].reset()
    trigger.blender[b].orenable = true
    trigger.blender[b].stimulus[1] = trigger.EVENT_DISPLAY
    -- One stimulus, and a bus trigger is deliberately not the second. docs/MEASUREMENTS.md, 'The front TRIGGER key
    -- is the only stop control this firmware allows'.
    trigger.blender[b].clear()
  end)
  -- false, not nil, so every poll answers "no cancel" and every loop falls back to its own bounds.
  sdec.cancel_ok = ok
  return ok
end

-- Discard any latched press, because the operator who pressed TRIGGER to stop the last run must not stop this
-- one too.
function sdec.cancel_clear()
  if not sdec.cancel_ok then return false end
  -- The index is outside the guard, and cancel_ok makes that safe: it is true only if cancel_setup's own guarded
  -- wiring completed. Parenthesised so this returns one value rather than forwarding clear()'s returns.
  return (pcall(trigger.blender[sdec.cancel_blender].clear))
end

-- Has TRIGGER been pressed since the last cancel_clear() or cancel_pressed()? The detector auto-resets on read
-- (ref 14-334), so one press answers true exactly once and callers record the answer.
function sdec.cancel_pressed()
  if not sdec.cancel_ok then return false end
  local ok, got = pcall(trigger.blender[sdec.cancel_blender].wait, sdec.cancel_poll_s or 0.001)
  if not ok then return false end
  return got == true
end
-- Which event arms a capture, and what that costs in shared instrument state. -> ev, useanalog, blended. Called by
-- both armed paths; ev is nil when the event constant is absent.
function sdec.arm_source()
  -- The analog trigger watches the signal itself on the front INPUT HI/LO and fires on a start-bit edge, which
  -- cannot tell which byte. The other two let something outside the line decide.
  local ev = trigger.EVENT_ANALOGTRIGGER
  if sdec.trigmode == 'front' then ev = trigger.EVENT_DISPLAY end
  -- Whether the comparator is a source is decided here, before the blender overwrites `ev`: asking later answered
  -- no for Rear BNC + Edge, so the mode, level and slope went unset.
  local useanalog = (ev == trigger.EVENT_ANALOGTRIGGER)

  -- The rear BNC is OR'd in, not selected instead, because
  -- "start on a start bit, or when the DUT asserts its GPIO, whichever comes first"
  -- is not expressible as a single choice. Skipped for free run, which means do not wait.
  local blended = false
  -- Release the blender when not using it. Not a correctness bug -- the model waits on `ev` -- but the next thing
  -- to use a blender would inherit our stimuli and our overrun flag.
  if not sdec.trigext then
    pcall(trigger.blender[1].reset)
  end
  if sdec.trigext and sdec.trigext_only and sdec.trigmode ~= 'free' then
    -- The rear BNC alone: no blender, and the comparator turned off below by clearing useanalog, since leaving it
    -- armed keeps a live stimulus on a model that no longer waits on it. This is what anchors a capture.
    ev = trigger.EVENT_EXTERNAL
    useanalog = false
    pcall(trigger.blender[1].reset)
  elseif sdec.trigext and sdec.trigmode ~= 'free' then
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
      -- No blender on this firmware: fall back to the rear BNC alone, which is what the operator asked to matter.
      ev = trigger.EVENT_EXTERNAL
      sdec.lasterr = 'no trigger blender; using the rear BNC alone'
    end
  end

  -- The TRIGGER key as a manual break-in: the wait below cannot be interrupted from Lua, but as a stimulus of the
  -- trigger model the key is serviced by firmware. Only on an arm from silence.
  if sdec.arm_silent() and sdec.armkey and sdec.trigmode ~= 'front' and
     not (sdec.trigext and sdec.trigext_only) then
    local kok = pcall(function()
      if not blended then
        trigger.blender[1].reset()
        trigger.blender[1].orenable = true
        trigger.blender[1].stimulus[1] = ev
      end
      trigger.blender[1].stimulus[3] = trigger.EVENT_DISPLAY
    end)
    if kok then
      ev = trigger.EVENT_BLENDER1
      blended = true
      sdec.armkeyed = true
    else
      sdec.armkeyed = nil
      -- Appended, not assigned: the rear-BNC fallback above sets lasterr for the same missing blender, and a bare
      -- assignment replaced it. One firmware shortfall, two consequences, both worth saying.
      local knote = 'the TRIGGER key will not cut the arm short'
      if sdec.lasterr == nil then
        sdec.lasterr = 'no trigger blender; ' .. knote
      else
        sdec.lasterr = sdec.lasterr .. '; ' .. knote
      end
    end
  else
    sdec.armkeyed = nil
  end
  sdec.trigblended = blended
  return ev, useanalog, blended
end

-- Where to arm on a line the probe found silent, in volts, written to sdec.thr with the matching sdec.idle. ->
-- false when there is not even a level to work from. Shared by both armed paths.
function sdec.arm_threshold()
  sdec.arm_thr, sdec.arm_idle = nil, nil
  if sdec.vmax == nil then return false end
  local idlev = sdec.vmax
  if math.abs(sdec.vmin) > math.abs(sdec.vmax) then idlev = sdec.vmin end
  sdec.hyst = 0
  if math.abs(idlev) < sdec.flatfloor then
    -- Idle sits at ground, so the start bit can only go up: an inverted TTL line, or the TTL side of an idle-low
    -- current loop (MIDI). No midpoint to clamp against -- a ground-idle line is as tall as its part.
    sdec.thr, sdec.idle = idlev + sdec.arm_level_v(), 0
    sdec.arm_thr, sdec.arm_idle = sdec.thr, sdec.idle
    return true
  end
  -- Idle is away from ground, so the start bit moves towards ground and the arm goes on that side. Clamped at half
  -- the idle level, the deepest arm certainly still inside the swing.
  local off = sdec.arm_level_v()
  local half = 0.5 * math.abs(idlev)
  if off > half then off = half end
  if idlev < 0 then
    sdec.thr, sdec.idle = idlev + off, 0
  else
    sdec.thr, sdec.idle = idlev - off, 1
  end
  -- Published separately, because the comparator's level and the decode's threshold are different questions: a
  -- recording reuses the last good capture's threshold, which is not Arm At.
  sdec.arm_thr, sdec.arm_idle = sdec.thr, sdec.idle
  return true
end

-- The slope the start bit takes, or nil where the comparator is not the source and a slope would be dead state
-- on the board. Shared, so the frame path and the armed recording arm on the same edge of the same line.
function sdec.arm_slope()
  if sdec.trigmode ~= 'edge' then return nil end
  -- The arm's own idle side where there is one, for the reason arm_threshold() gives: sdec.idle is the polarity of
  -- the last decode, and arming the far side of a level the line sits on cannot fire at all.
  local side = sdec.arm_idle
  if side == nil then side = sdec.idle end
  if side == 0 then return sdec.k.SLOPE_RISING end
  return sdec.k.SLOPE_FALLING
end

-- Point the comparator at sdec.thr, or turn it off where it is not a source. -> whether the writes went through.
-- Guarded, a digitizer with no comparator being supported: a bare write with atrig nil raised.
function sdec.arm_comparator(useanalog, slope)
  if sdec.atrig == nil then return false end
  return pcall(function()
    if useanalog then
      sdec.atrig.mode   = sdec.k.MODE_EDGE
      -- arm_thr where the arm computed one, sdec.thr otherwise -- see arm_threshold(). On a line already transmitting
      -- there is no arm level and the measured midpoint is right; on one waiting for a device there is.
      sdec.atedge.level = sdec.arm_thr or sdec.thr
      sdec.atedge.slope = slope
    else
      -- A MODE_EDGE comparator left behind by a previous capture is state the operator did not ask for.
      sdec.atrig.mode = sdec.k.MODE_OFF
    end
  end)
end



-- Capture armed on a signal edge, on the front-panel TRIGGER key or on the rear BNC, degrading to a free-running
-- read if the source is refused.
function sdec.acq_triggered(n, slope)
  local buf = sdec.buf
  buf.clear()
  -- Per capture, not only at creation: observed reading back 0 on a capture that reused a buffer, and one
  -- FILL_ONCE capture is one burst of 4915. Setting it also clears the buffer, so it goes before clear().
  sdec.acq_fillmode(buf)
  n = sdec.acq_fit(n, buf)
  sdec.dig.count = n
  -- The pre-trigger reserve posts 4915 while it waits. Muted here and restored below on both exits.
  sdec.mute_events()

  -- Defaulted at the point of use, so no ordering of module loads can put a nil into the comparison below.
  local wait = sdec.trigwait or 3.0
  -- A human or a DUT event is not a 3-second affair: the analog trigger fires within a byte time or not at all,
  -- but a finger needs longer. Still bounded, an unbounded wait inside a touch handler being a dead panel.
  if sdec.trigmode == 'front' or sdec.trigext then wait = sdec.trigwait_ext or 30.0 end

  -- An arm from silence gets the operator's own wait and can only lengthen it, hence a comparison.
  -- docs/MEASUREMENTS.md, 'Arm Wait applies only where the comparator is the source'.
  if sdec.arm_silent() and sdec.trigmode == 'edge' and
     not (sdec.trigext and sdec.trigext_only) then
    local armw = sdec.arm_wait_s()
    if armw > wait then wait = armw end
  end

  -- The wait must outlast the capture itself, or the armed path can never complete at a low sample rate.
  -- docs/MEASUREMENTS.md, 'The armed wait must outlast the capture itself'.
  local dur = nil
  if sdec.fs ~= nil and sdec.fs > 0 then dur = n / sdec.fs end
  if dur ~= nil and wait < dur * 1.5 + 1.0 then wait = dur * 1.5 + 1.0 end

  -- The source, the blender and the key, chosen by sdec.arm_source() so this path and the armed recording cannot
  -- disagree. The mute is lifted first, a muted panel swallowing later errors.
  local ev, useanalog = sdec.arm_source()
  if ev == nil then
    sdec.unmute_events()
    sdec.lasterr = 'no front-panel TRIGGER event on this firmware; captured free-running'
    return sdec.acq_free(n)
  end

  -- The raised reason is carried out, and `expired` says which fault it was. An upvalue, so the exit need not
  -- match on firmware text it does not control.
  local expired = false
  local ok, perr = pcall(function()
    -- The analog trigger is configured only when it is a source, through arm_comparator() so both armed paths
    -- point the same comparator at the same threshold. The verdict is acted on.
    if not sdec.arm_comparator(useanalog, slope) then
      error('no analog comparator on this digitizer', 0)
    end
    -- position is the pre-trigger percentage: 5 % of 20 000 keeps 1000 samples before the edge, 19 000 after.
    trigger.model.load('LoopUntilEvent', ev,
                       sdec.pretrig, trigger.CLEAR_ENTER, 0, buf)
    trigger.model.initiate()

    -- Flow control: "go" goes here, and only here, and the position of this call is the whole correctness
    -- argument. docs/MEASUREMENTS.md, 'The flow-control credit pulse on the free-run path'.
    if sdec.fc_out then
      -- Table tested for the same reason as fc_credit(). The verdict is discarded here by design.
      if trigger.extout ~= nil then pcall(trigger.extout.assert) end
    end

    -- A bounded wait, because a bare waitcomplete() is a hang, and the note is painted once -- a touch press only
    -- queues while this loop runs. docs/MEASUREMENTS.md, 'The armed wait must outlast the capture itself'.
    if sdec.arm_silent() and sdec.armnote ~= nil then
      pcall(sdec.armnote, wait, sdec.arm_thr or sdec.thr or sdec.arm_level_v(), sdec.armkeyed)
    end

    local waited, step = 0, 0.05
    while waited < wait do
      if sdec.trig_done(buf) then break end
      if (buf.n or 0) >= n and sdec.pretrig <= 0 then break end
      delay(step)
      waited = waited + step
    end
    -- A full buffer is only success when pretrig is zero: on a quiet line the model keeps making pre-trigger
    -- readings and wraps, so buf.n reaches n with no trigger. Completion is trig_done().
    local full = (buf.n or 0) >= n and sdec.pretrig <= 0
    if not sdec.trig_done(buf) and not full then
      expired = true
      -- The advice depends on which fault this was, and 'try Free run' is wrong for the silent case. The word for
      -- a quiet line is deliberately absent: two bench tools discriminate on it.
      local why = 'no trigger in ' .. tostring(wait) .. ' s (' .. tostring(sdec.trigmode) .. ')'
      -- And useanalog, not the silent test alone: the two settings named here govern the comparator. A 'front' press
      -- and an anchored rear-BNC capture reach this line too, and both wait on a person or a marker.
      if sdec.arm_silent() and useanalog then
        -- The level the comparator was actually armed at, not the setting it came from: on a line idling away from
        -- ground the arm sits arm_level_v() volts below idle.
        why = why .. ' -- nothing crossed ' ..
              string.format('%.2f', sdec.thr or sdec.arm_level_v()) ..
              ' V; raise Arm Wait or lower Arm At'
      else
        why = why .. ' -- try Free run'
      end
      error(why, 0)
    end
  end)

  -- Settle before anything else touches the buffer, on both paths -- the failure path reaches it through
  -- acq_free. Best effort; see trig_settle().
  sdec.trig_settle()

  -- Both exits restore the popups: a panel left muted would swallow every later firmware error.
  sdec.unmute_events()
  if not ok then
    -- Names the source that failed, not "analog trigger". A contract: bench_trigin.py reads 'trigger unavailable'
    -- as a timeout and bench_trigkey.py reads an idle line as a trigger that fired.
    sdec.lasterr = tostring(sdec.trigmode) ..
                   ' trigger unavailable; captured free-running'
    -- The wait's own reason, expired path only: a firmware refusal's text must not enter a parsed sentence.
    if expired and perr ~= nil then
      sdec.lasterr = sdec.lasterr .. ' (' .. tostring(perr) .. ')'
    end
    -- Tested, because sdec.atrig need not exist. serial_app.tsp's header claims this degrades to free-running
    -- without a comparator, and a bare write made that false: with atrig nil it raised and acquire() died.
    if sdec.atrig ~= nil then sdec.atrig.mode = sdec.k.MODE_OFF end
    return sdec.acq_free(n)
  end

  sdec.nread = buf.n or 0
  sdec.acq_fs = sdec.acq_fs_or_requested(buf, sdec.nread)
  sdec.acq_copy(buf, sdec.nread)
  -- This record opens before the edge that started it, so sig_idle declines to treat the leading run as idle. Set
  -- only on the exit that actually triggered, and only where a reserve was asked for.
  sdec.acq_pretrig = (sdec.pretrig or 0) > 0
  return sdec.nread
end

-- Full acquisition: learn the levels, then capture for real. Returns ok, reason. Two stages because the analog
-- trigger level is a voltage and the logic levels are unknown until a short probe has measured them.
function sdec.acquire()
  sdec.lasterr = nil
  -- Every acquisition, not every press. Safe here because every field this drops is written further down this same
  -- function, before anything reads it. docs/MEASUREMENTS.md, 'A measurement must not cross a capture boundary'.
  sdec.clear_measured()
  sdec.hw_config()
  -- The pre-trigger reserve comes out of capacity, so ask for it on top -- see sdec.acq_cap.
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
    -- A probe that saw no transitions is not a failure: a bursty line is idle far longer than a 2000-sample probe,
    -- and for the triggered path idle is the normal start.
    if not sdec.arm_threshold() then return false, why end
    sdec.probe_idle = why
    -- Without a trigger there is nothing to wait for, so a quiet line in free-run mode is the end of the road. Not
    -- for the front TRIGGER key: a quiet line is the exact condition that key exists for.
    if sdec.trigmode == 'free' then return false, why end
  end

  -- The armed path is every source that waits, which is all but 'free'. Routing only 'edge' here left 'front'
  -- free-running while the status row read EXT TRIG key.
  if sdec.trigmode == 'edge' or sdec.trigmode == 'front' then
    -- Arm on the transition away from idle, and through arm_slope() so stream_arm() arms on the same edge.
    if sdec.acq_triggered(sdec.n, sdec.arm_slope()) < 2 then
      return false, 'triggered capture returned nothing'
    end
  else
    if sdec.acq_free(sdec.n) < 2 then return false, 'capture returned nothing' end
  end

  -- Re-measure the levels on the real capture; the probe was only a scout.
  ok, why = sdec.sig_levels(sdec.smp, sdec.nread)
  if not ok then return false, why end
  -- Stage boundaries, for the liveness hook: each of these three walks all sdec.nread samples. A tick between them
  -- cannot affect what they compute, each reading sdec.smp afresh.
  if sdec.tick ~= nil then sdec.tick() end
  sdec.sig_edges(sdec.smp, sdec.nread)
  if sdec.tick ~= nil then sdec.tick() end
  sdec.sig_idle(sdec.smp, sdec.nread)
  return true
end

-- tolerance.lua -- how much of each impairment the decoder survives, PER BAUD RATE.
--
-- The stress suite answers "does it break on this specific bad signal?". This answers the
-- question an operator actually has: HOW BAD CAN THE WIRE BE. For every rate on the standard
-- ladder and every impairment we can generate, it reports the largest level at which the decode
-- is still byte-exact with the right rate and zero framing errors.
--
-- MEASURED ACROSS SEVERAL SEEDS, NOT ONE. One draw is not a tolerance: at a jitter of +/-25 % UI
-- one seed decodes byte-exact and the next produces a CONFIDENT WRONG ANSWER -- zero framing errors,
-- an unsnapped baud rate, corrupted bytes. A level passes here only if EVERY seed is exact.
--
-- The two columns are different questions and both are reported:
--   CLEAN  the largest level at which every seed is byte-exact
--   SAFE   the largest level at which no seed is SILENTLY wrong -- i.e. a wrong result always
--          announces itself, by framing errors or by an unsnapped rate. Past this the panel can
--          show confident garbage, which is the only truly dangerous failure.
--
-- WHY WHOLE BLOCKS OF ROWS ARE IDENTICAL, and why that is a RESULT rather than a bug: fs comes from
-- pick_fs, which snaps UP into sdec.rates, and it lands on 8.3333 sa/bit for every standard rate from
-- 300 to 76800 bar two. Those rates hand the decoder the SAME SAMPLE ARRAY -- same cells, same
-- oversampling, same everything but the wall-clock duration it was collected over -- so nothing
-- downstream of the ADC can tell them apart and the tolerance cannot differ either. The real axis is
-- SAMPLES PER BIT. It varies at the two rates that snap to a busy rung (28800 and 57600 at 8.6806,
-- 31250 at 8.0000) and then falls away above 115200 as fs clamps at 1 MSa/s: 7.81 at 128000, 6.51 at
-- 153600, 4.34 at 230400, 4.00 at 250000. Those are the rows to read.
--
-- The upshot for the operator is a good one: a slow line is not more robust than a fast one, and
-- quoting a tolerance per baud rate would imply it is. Tolerance is a property of oversampling.
--
-- Run from the repo root:  lua tools/tolerance.lua [--fast]
dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local FAST = false
local i
for i = 1, table.getn(arg or {}) do if arg[i] == '--fast' then FAST = true end end

local PAYLOAD = 'Hello, World!'
local NSEED = 6
if FAST then NSEED = 3 end

-- The ladder. fs follows what FRAME mode picks -- 8 samples/bit -- clamped at the instrument's
-- 1 MSa/s ceiling, which is why the top two rates are undersampled and expected to be worse.
local RATES = {300, 1200, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 250000}
if FAST then RATES = {1200, 9600, 38400, 115200} end

-- THE RATE FRAME MODE REALLY PICKS, not baud x 8. pick_fs snaps UP into sdec.rates, so oversampling
-- is 8.33 at most rates and 8.68 at 57600/115200 -- never a flat 8.00, and baud x 8 asks for rates the
-- instrument cannot select at all. Tolerance follows SAMPLES PER BIT, so sweeping the wrong rate
-- measures a configuration the app never runs.
local function fs_for(baud)
  return sdec.pick_fs(baud, 8)
end

-- ---------------------------------------------------------------------------
-- The impairments. Each is {name, unit, levels, apply(opts, level) -> mangle}
-- ---------------------------------------------------------------------------
-- JITTER goes into the render (it moves cell boundaries, which cannot be done afterwards).
-- The others are post-render mangles, which is also how the stress suite applies them.
local IMP = {
  {name = 'jitter', unit = '% UI',
   levels = {2, 5, 8, 10, 12, 15, 18, 20, 25, 30, 40},
   pre = function(opts, lv) opts.jitter = lv / 100 end},

  {name = 'noise', unit = 'V pk',
   levels = {0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.1, 1.4, 1.7, 2.0},
   pre = function(opts, lv) opts.noise = lv end},

  -- Impulses: a few samples pinned well outside the logic swing. Narrow and tall, which is what
  -- coupled digital noise looks like, and what the hump gate in sig_levels exists to survive.
  {name = 'spikes', unit = 'V, 40 of them',
   levels = {1, 2, 3, 5, 8, 12, 20, 30},
   post = function(lv)
     return function(rd, ns)
       local k
       for k = 1, 40 do
         local at = math.floor(ns * k / 41)
         local j
         for j = 0, 2 do
           if rd[at + j] ~= nil then
             local s = 1
             if math.mod(k, 2) == 0 then s = -1 end
             rd[at + j] = rd[at + j] + s * lv
           end
         end
       end
     end
   end},

  -- DROPOUT: the line collapses to mid-scale for a run of BIT TIMES -- a connector going
  -- intermittent, or a driver releasing the bus. Distinct from a spike in the way that matters:
  -- a spike adds an edge pair the framing can reject, whereas a dropout DELETES real edges and
  -- parks the line at a level that is neither mark nor space, so the threshold sits inside it.
  {name = 'dropout', unit = 'bit times',
   levels = {0.5, 1, 2, 3, 5, 8, 12, 20},
   post = function(lv)
     return function(rd, ns, sabit)
       local w = math.floor(lv * sabit)
       if w < 1 then w = 1 end
       local at = math.floor(ns * 0.45)
       local k
       for k = at, at + w do
         if rd[k] ~= nil then rd[k] = 1.65 end
       end
     end
   end},
}

-- One trial. Returns 'exact', 'flagged' (wrong but it says so) or 'silent' (wrong and confident).
local function trial(baud, imp, level, seed)
  local fs = fs_for(baud)
  local opts = {bytes = GEN_BYTES(PAYLOAD), baud = baud, fs = fs}
  if imp.pre ~= nil then imp.pre(opts, level) end
  GEN_RESEED(seed)
  local rd, ts, nc, ns = GEN(opts)
  if imp.post ~= nil then imp.post(level)(rd, ns, fs / baud) end

  sdec.acq_fs, sdec.fs = fs, fs
  sdec.res, sdec.baud, sdec.snapped = nil, nil, nil
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil

  local ok = false
  local pok = pcall(function()
    if sdec.sig_levels(rd, ns) then
      sdec.sig_edges(rd, ns)
      sdec.sig_idle(rd, ns)
      ok = sdec.decode_from(rd, ns)
    end
  end)
  if not pok then return 'silent' end          -- a raise is the worst outcome, counted as unsafe

  local r = sdec.res
  if r == nil or r.nf == 0 then return 'flagged' end
  local s = ''
  local k
  for k = 1, r.nf do
    local v = r.vals[k]
    if v ~= nil and r.errs[k] == nil then s = s .. string.char(v) else s = s .. '\1' end
  end
  if s == PAYLOAD and r.nbad == 0 then return 'exact' end
  -- Wrong. Does it announce itself? Framing errors, a missing rate, or a rate that did not snap
  -- to a standard value are all ways of saying "do not trust this".
  if r.nbad > 0 or sdec.baud == nil or sdec.snapped == false then return 'flagged' end
  return 'silent'
end

-- Largest level at which EVERY seed is exact, and largest at which no seed is silently wrong.
local function limits(baud, imp)
  local clean, safe = nil, nil
  local li
  for li = 1, table.getn(imp.levels) do
    local lv = imp.levels[li]
    local allexact, anysilent = true, false
    local s
    for s = 1, NSEED do
      local v = trial(baud, imp, lv, s * 7919 + 13)
      if v ~= 'exact' then allexact = false end
      if v == 'silent' then anysilent = true end
    end
    if allexact then clean = lv end
    if not anysilent then safe = lv end
    -- Keep going even after a failure: tolerance is not always monotonic, and reporting the
    -- LARGEST passing level rather than the first failure is the honest summary.
  end
  return clean, safe
end

print('DECODER TOLERANCE, per baud rate. ' .. NSEED .. ' seeds per point; a level passes only')
print('if EVERY seed is byte-exact with the right rate and zero framing errors.')
print('CLEAN = largest level still exact.   SAFE = largest level with no SILENT wrong answer.')
print('')
local hdr = string.format('%-8s %-7s', 'baud', 'sa/bit')
local ii
for ii = 1, table.getn(IMP) do
  hdr = hdr .. string.format(' | %-18s', IMP[ii].name)
end
print(hdr)
print(string.rep('-', string.len(hdr)))

local ri
for ri = 1, table.getn(RATES) do
  local baud = RATES[ri]
  local line = string.format('%-8d %-7.2f', baud, fs_for(baud) / baud)
  for ii = 1, table.getn(IMP) do
    local clean, safe = limits(baud, IMP[ii])
    local cs = 'none'
    if clean ~= nil then cs = tostring(clean) end
    local ss = 'none'
    if safe ~= nil then ss = tostring(safe) end
    line = line .. string.format(' | %8s /%8s', cs, ss)
  end
  print(line)
  io.write('')
end
print('')
local u = string.format('%-8s %-7s', 'units', '')
for ii = 1, table.getn(IMP) do
  u = u .. string.format(' | %-18s', IMP[ii].unit)
end
print(u)
print('')
print('Read a cell as CLEAN/SAFE. A cell reading "none" in the CLEAN column means even the')
print('smallest level tested cost at least one seed its exactness at that rate.')

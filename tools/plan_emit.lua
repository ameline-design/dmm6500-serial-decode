-- plan_emit.lua -- run the INSTRUMENT'S plan draw on the host and print the CSV it would write.
--
-- WHY IT EXISTS. bench/plan_gen.tsp draws the soak plan on the instrument. The only thing that makes
-- that safe is a byte-for-byte comparison against tools/soakplan.py, and this is the harness that
-- gets the instrument's own bytes out where they can be compared. tools/test_plan_gen.py runs it
-- under BOTH Luas -- the host's and out/lua502/bin/lua, which is the instrument's dialect -- and
-- diffs all three outputs.
--
-- IT MUST LOAD UNDER 5.0.2 AS WELL AS THE HOST LUA, so: no '#', no '%', no string.match, no select,
-- no varargs. Same rules as the modules it loads.
--
-- THE RATE LADDER IS READ FROM tsp/serial_core.tsp, which loads standalone under both -- so this
-- harness holds no copy of sdec.rates, sdec.stdbaud or sdec.flatfloor either.
--
--   lua tools/plan_emit.lua [ITER [LAST]] [--reps N] [--random-per-lap N] [--vectors N] [--no-skip]

-- A file mock that keeps the bytes. The real one posts events and needs a key; this one only has to
-- hand back what was written.
PLANOUT = {n = 0}

-- AN io SHIM, NOT A file.* ONE. bench/plan_gen.tsp writes through io now, because
-- Keithley's file.* wrapper posts event 2201 at the end of a read and that is a modal
-- box on the panel. A shim for the old API intercepts nothing, io.open on the host
-- answers nil for '/usb1/...', and emit then refuses every draw -- 19 failures all
-- reading 'python 1518, lua 0'.
--
-- Only the instrument's own root is intercepted; anything else goes to the real
-- io.open, because this harness also reads vector files off the real disk.
local real_io_open = io.open

function io.open(path, mode)
  local raw = tostring(path)
  if string.sub(raw, 1, 5) ~= '/usb1' then return real_io_open(path, mode) end
  if mode ~= 'w' and mode ~= 'wb' then return nil, raw .. ': emit only writes' end
  PLANOUT = {n = 0}
  local h = {path = raw}
  function h.write(self, s)
    PLANOUT.n = PLANOUT.n + 1
    PLANOUT[PLANOUT.n] = s
    return self
  end
  function h.flush(self) return self end
  function h.close(self) return true end
  -- Deliberately absent: seek and read. Nothing in the draw uses them, and a stub
  -- answering plausibly would hide a draw that started to.
  return h
end

dofile('tsp/serial_core.tsp')
dofile('bench/arb_names.tsp')
dofile('bench/plan_rand.tsp')
dofile('bench/plan_data.tsp')
dofile('bench/plan_gen.tsp')

local first, last, opt = 1, nil, {}
do
  local i, pos = 1, 0
  while arg[i] ~= nil do
    local a = arg[i]
    if a == '--reps' then
      i = i + 1
      opt.reps = tonumber(arg[i])
    elseif a == '--random-per-lap' then
      i = i + 1
      opt.rkeep = tonumber(arg[i])
    elseif a == '--vectors' then
      i = i + 1
      opt.nvec = tonumber(arg[i])
    elseif a == '--no-skip' then
      opt.skip = {}
    elseif a == '--exact' then
      -- The per-cell keyed draw that preceded the block-seeded one. Kept so a test can compare the
      -- two schemes and so an old plan can be reproduced.
      opt.fast = false
    else
      pos = pos + 1
      if pos == 1 then first = tonumber(a) else last = tonumber(a) end
    end
    i = i + 1
  end
end
opt.first = first
opt.last = last or first

local ok, nrows, err = bplan.emit('/usb1/SERDEC/PLAN.CSV', opt)
if not ok then
  io.write('PLAN_EMIT_FAILED: ' .. tostring(err) .. '\n')
  os.exit(1)
end
io.write(table.concat(PLANOUT, '', 1, PLANOUT.n))

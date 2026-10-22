-- Is the plan the INSTRUMENT draws the same plan the host draws? One question, asked byte for byte.
--
-- WHY THIS IS THE WHOLE SAFETY ARGUMENT for bench/plan_gen.tsp. The amplitude, the offset and the
-- wait of every cell are keyed off a vector's INDEX in a shuffled list, so two draws that differ
-- anywhere differ in nearly every cell -- and both plans still look perfectly reasonable. Measured
-- once at 1677 of 1677 cells, from nothing worse than a skip applied in the wrong order. There is no
-- reading of the two implementations that establishes equivalence; only a diff does.
--
-- THREE PRODUCERS, AND ALL THREE MUST AGREE:
--   * tools/soakplan.py          -- the reference. Every lap on disk was drawn by it.
--   * out/lua502/bin/lua         -- the INSTRUMENT'S dialect. This is the one that ships.
--   * the host lua               -- because a 5.0.2-only answer would not prove the arithmetic is
--                                   dialect-independent, and the offline suites run under this one.
--
-- IN LUA RATHER THAN PYTHON, on the operator's instruction of 2026-10-22: the project is moving to
-- Lua wherever a host-only tool does not need otherwise, so that the draw and the test of the draw
-- are not in two languages. It runs under the HOST Lua and not 5.0.2 for one concrete reason --
-- 5.0.2 has no io.popen, so it cannot start the three producers.
--
--   lua tools/test_plan_gen.lua            # the standard set
--   lua tools/test_plan_gen.lua --quick    # iteration 1 only, for an edit loop

local QUICK = false
do
  local i = 1
  while arg[i] ~= nil do
    if arg[i] == '--quick' then QUICK = true end
    i = i + 1
  end
end

-- gfind IS 5.0'S SPELLING and gmatch is 5.1's. This file runs under the host Lua, but the probe
-- sources it writes run under 5.0.2, so both names appear in this directory on purpose -- and
-- tools/lint_tsp.py refuses gmatch inside tsp/ and bench/ for exactly that reason.
local gmatch = string.gmatch or string.gfind

local pass, fail = 0, 0
local function ck(cond, what, detail)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. what .. (detail ~= nil and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. what .. (detail ~= nil and ('   ' .. detail) or ''))
  end
end

local function run(cmd)
  local h = io.popen(cmd .. ' 2>/dev/null')
  local s = h:read('*a')
  h:close()
  return s
end

-- The provenance line is DELIBERATELY different -- a reader has to be able to tell which draw made a
-- plan -- so it is dropped before comparing and checked separately.
local function body(text)
  local out, first = {}, true
  local n = 0
  local i = 1
  for line in gmatch(text, '([^\n]*)\n') do
    if first then
      first = false
    else
      n = n + 1
      out[n] = line
    end
  end
  return table.concat(out, '\n'), n
end

local function firstline(text)
  local _, _, l = string.find(text, '^([^\n]*)')
  return l
end

-- ONE CASE = the same plan asked of all three, with the option spellings each one uses.
local CASES = {
  {name = 'iteration 1',        py = '--iteration 1',                    lua = '1'},
  {name = 'iteration 7',        py = '--iteration 7',                    lua = '7'},
  {name = 'iteration 129',      py = '--iteration 129',                  lua = '129'},
  {name = 'iterations 1..3',    py = '--iteration 1 --iterations 3',     lua = '1 3'},
  {name = 'repeats 4',          py = '--iteration 2 --repeats 4',        lua = '2 --reps 4'},
  {name = 'random-per-lap 3',   py = '--iteration 5 --random-per-lap 3', lua = '5 --random-per-lap 3'},
  {name = 'vector subset 6',    py = '--iteration 4 --vectors 6',        lua = '4 --vectors 6'},
  {name = 'no skip at all',     py = "--iteration 1 --skip-vectors ''",  lua = '1 --no-skip'},
}

print('plan draw: host python vs host lua vs lua 5.0.2')

local ncase = QUICK and 1 or 8
local i
for i = 1, ncase do
  local c = CASES[i]
  local py = run('python3 tools/soakplan.py --emit-csv ' .. c.py)
  local hl = run('lua tools/plan_emit.lua ' .. c.lua)
  local fl = run('out/lua502/bin/lua tools/plan_emit.lua ' .. c.lua)
  local pyb, pyn = body(py)
  local hlb, hln = body(hl)
  local flb = body(fl)
  -- A VACUOUS PASS IS THE FAILURE MODE HERE: three empty strings are equal. The row count is
  -- asserted before the equality, so a producer that printed nothing cannot read as agreement.
  ck(pyn > 20, c.name .. ': the reference produced a plan', pyn .. ' line(s)')
  ck(hln == pyn, c.name .. ': the instrument draw has the same line count',
     'python ' .. pyn .. ', lua ' .. hln)
  ck(hlb == pyb, c.name .. ': INSTRUMENT DRAW == soakplan.py, byte for byte')
  ck(flb == hlb, c.name .. ': lua 5.0.2 == host lua, byte for byte')
end

-- The provenance line says which draw made the file, and is the one line that must NOT match.
do
  local py = run('python3 tools/soakplan.py --emit-csv --iteration 1')
  local lu = run('lua tools/plan_emit.lua 1')
  ck(string.find(firstline(py), 'soakplan.py', 1, true) ~= nil,
     'the reference names itself on line 1')
  ck(string.find(firstline(lu), 'plan_gen.tsp', 1, true) ~= nil,
     'the instrument draw names itself on line 1')
  ck(firstline(py) ~= firstline(lu),
     'the two provenance lines differ, so a plan says which drew it')
end

-- bench/plan_data.tsp is generated. A vector added to vector_names.py without regenerating it would
-- change the host's draw and not the instrument's -- which is exactly the divergence above, arriving
-- through the data instead of the code.
do
  local out = run('python3 tools/gen_plan_data.py --check; echo RC=$?')
  ck(string.find(out, 'RC=0', 1, true) ~= nil,
     'bench/plan_data.tsp is current with soakplan.py', string.gsub(firstline(out), '%s+$', ''))
end

-- THE LAZY TWIST, held to the eager form it replaced. test_soakrand.py already holds the whole
-- generator to CPython; this is the narrower check that the optimisation did not change the
-- sequence, and it walks PAST one 624-word block so the pass boundary is included.
do
  local src = [[
    dofile('bench/plan_rand.tsp')
    local a = bplan.mt.new{1, 2, 3}
    local b = bplan.mt.new{1, 2, 3}
    local bad, i = 0, nil
    for i = 1, 1400 do
      if a:u32() ~= b:u32_eager() then bad = bad + 1 end
    end
    print('BAD=' .. bad)
  ]]
  local fh = io.open('/tmp/plan_twist_probe.lua', 'w')
  fh:write(src)
  fh:close()
  local h = run('lua /tmp/plan_twist_probe.lua')
  local f = run('out/lua502/bin/lua /tmp/plan_twist_probe.lua')
  ck(string.find(h, 'BAD=0', 1, true) ~= nil,
     'lazy twist == eager twist over 1400 words, host lua', string.gsub(h, '%s+$', ''))
  ck(string.find(f, 'BAD=0', 1, true) ~= nil,
     'lazy twist == eager twist over 1400 words, lua 5.0.2', string.gsub(f, '%s+$', ''))
end

-- bplan.check has to tell a GOOD plan from a TRUNCATED one, because a truncated plan opens, parses
-- and streams -- and then ends early, so the lap silently runs a prefix and the record reads as a
-- short run rather than a broken file.
do
  local src = [[
    PLANTEXT = nil
    file = {MODE_WRITE = 'w', MODE_READ = 'r', READ_LINE = 'line', READ_ALL = 'all'}
    local lines, nl, pos = {}, 0, 0
    function file.open(p, m)
      if m == file.MODE_WRITE then lines, nl = {}, 0; return {w = true} end
      if PLANTEXT == nil then return nil end
      lines, nl, pos = {}, 0, 0
      for ln in string.gfind(PLANTEXT, '([^\n]*)\n') do nl = nl + 1; lines[nl] = ln end
      return {r = true}
    end
    function file.write(fh, s)
      for ln in string.gfind(s, '([^\n]*)\n') do nl = nl + 1; lines[nl] = ln end
    end
    function file.flush(fh) end
    function file.close(fh) end
    function file.read(fh, what)
      pos = pos + 1
      if pos > nl then return nil end
      return lines[pos] .. '\n'
    end
    dofile('tsp/serial_core.tsp')
    dofile('bench/arb_names.tsp')
    dofile('bench/plan_rand.tsp')
    dofile('bench/plan_data.tsp')
    dofile('bench/plan_gen.tsp')

    -- NOTHING ON THE KEY
    local ok, rows, why = bplan.check('/usb1/SERDEC/PLAN.CSV')
    print('EMPTY ok=' .. tostring(ok) .. ' why=' .. tostring(why))

    -- A GOOD PLAN, drawn small so the test is quick
    bplan.emit('/usb1/SERDEC/PLAN.CSV', {first = 1, nvec = 2})
    local t = {}
    local i
    for i = 1, nl do t[i] = lines[i] end
    PLANTEXT = table.concat(t, '\n') .. '\n'
    local gok, grows, gwhy = bplan.check('/usb1/SERDEC/PLAN.CSV')
    print('GOOD ok=' .. tostring(gok) .. ' rows=' .. tostring(grows) .. ' why=' .. tostring(gwhy))

    -- THE SAME PLAN WITH ITS TAIL CUT OFF
    local keep = {}
    for i = 1, nl - 3 do keep[i] = lines[i] end
    PLANTEXT = table.concat(keep, '\n') .. '\n'
    local tok, trows, twhy = bplan.check('/usb1/SERDEC/PLAN.CSV')
    print('TRUNC ok=' .. tostring(tok) .. ' rows=' .. tostring(trows) .. ' why=' .. tostring(twhy))

    -- A FILE THAT IS NOT A PLAN AT ALL
    PLANTEXT = 'hello\nworld\n'
    local fok, frows, fwhy = bplan.check('/usb1/SERDEC/PLAN.CSV')
    print('FOREIGN ok=' .. tostring(fok) .. ' why=' .. tostring(fwhy))
  ]]
  local fh = io.open('/tmp/plan_check_probe.lua', 'w')
  fh:write(src)
  fh:close()
  local out = run('out/lua502/bin/lua /tmp/plan_check_probe.lua')
  ck(string.find(out, 'EMPTY ok=false', 1, true) ~= nil,
     'check refuses a key with no plan')
  ck(string.find(out, 'no plan on the key', 1, true) ~= nil,
     'and says so in words the panel can show')
  ck(string.find(out, 'GOOD ok=true', 1, true) ~= nil,
     'check accepts a plan it just drew', string.gsub(out, '.*(GOOD[^\n]*).*', '%1'))
  ck(string.find(out, 'TRUNC ok=false', 1, true) ~= nil,
     'check REFUSES a truncated plan rather than streaming a prefix')
  ck(string.find(out, 'truncated', 1, true) ~= nil,
     'and names truncation as the reason')
  ck(string.find(out, 'FOREIGN ok=false', 1, true) ~= nil,
     'check refuses a file that is not a plan')
end

print('')
print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

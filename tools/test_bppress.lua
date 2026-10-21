-- bp_press must ALWAYS put a PRESS line on the socket, whatever the app is doing.
--
-- tools/bench_panel.py reads the instrument's replies until 'P end' and treats silence as a timeout.
-- A raise inside the press helper prints NOTHING -- the host then blocks for its whole budget at 0%
-- CPU and reports a fault in the app. That is not hypothetical: it cost a 300 s panel-stage failure
-- that was published as an absorb collision, and the absorb was disarmed and innocent the whole time.
--
-- bp_state is OUR Lua, not firmware, so it genuinely can raise -- `sdec.res` on a torn-down app is
-- one nil index. A power cycle leaves sdec unset and so does a reset between stages.
--
-- BOTH ARMS RUN. The real preamble is read out of bench_panel.py and must survive three fault
-- injections; an UNGUARDED fixture of the same shape must fail every one of them. Without the second
-- arm this file would pass just as happily against code that cannot fail, which is the trap a DRY
-- collapse sets. The fixture is written here rather than taken from a git revision on purpose: a
-- control pinned to a commit stops being a control the moment that commit is the fix.

local SRC = 'tools/bench_panel.py'

-- 5.0.2 AND 5.5 BOTH, because this file is checked against the real 5.0.2 that the instrument
-- runs AND against whatever `lua` the sweep has. That rules out three idioms: `#` is a PARSE error
-- in 5.0.2, table.getn was removed after 5.1, and loadstring was renamed. So lines are counted by
-- hand and the loader is picked once, here.
local loadit = loadstring or load

-- ---- read the preamble out of the harness ------------------------------------------------------
local function preamble()
  local f = assert(io.open(SRC, 'r'), SRC .. ' not found -- run from the repo root')
  local all = f:read('*a')
  f:close()
  local open = string.find(all, "PRESS_TSP = r'''", 1, true)
  assert(open ~= nil, 'PRESS_TSP is gone from ' .. SRC .. ' -- this test needs re-pointing')
  local from = open + string.len("PRESS_TSP = r'''")
  local close = string.find(all, "'''", from, true)
  assert(close ~= nil, 'PRESS_TSP is unterminated in ' .. SRC)
  return string.sub(all, from, close - 1)
end

-- An unguarded bp_press/bp_state of the shape this file exists to forbid. Deliberately minimal: the
-- only thing it has to share with the original is that nothing stands between a nil index and the
-- print that was meant to report it.
local UNGUARDED = [[
function bp_state()
  local r = sdec.res
  return 'nf=' .. tostring(r and r.nf)
end
function bp_press(name, fn)
  eventlog.clear()
  print('BEFORE ' .. bp_state())
  timer.cleartime()
  local ok, ret = pcall(fn)
  print('AFTER ' .. bp_state())
  print(string.format('PRESS %s|%s|%.4f|%d|%s|%s', name, tostring(ok), timer.gettime(),
                      eventlog.getcount(), '', tostring(ret)))
  local nt, nn = sdec.ui_notes()
  for i = 1, nn do print('NOTE ' .. tostring(nt[i])) end
  print('P end')
end
]]

-- ---- the stub instrument -----------------------------------------------------------------------
local realprint = print
local lines, nlines = {}, 0

local function stubs()
  print = function(s) nlines = nlines + 1 lines[nlines] = tostring(s) end
  eventlog = {clear = function() end, getcount = function() return 0 end,
              next = function() return 0, nil end}
  timer = {cleartime = function() end, gettime = function() return 0.5 end}
end

local function saw(tag)
  local i
  for i = 1, nlines do
    if string.sub(lines[i], 1, string.len(tag)) == tag then return lines[i] end
  end
  return nil
end

local npass, nfail = 0, 0
local function check(name, cond, detail)
  if cond then
    npass = npass + 1
  else
    nfail = nfail + 1
    realprint(string.format('  FAIL  %s   [%s]', name, tostring(detail)))
  end
end

-- ---- the three fault injections ----------------------------------------------------------------
-- Each returns what the host would have seen: whether bp_press survived, and the lines it emitted.
local function run_case(name)
  lines, nlines = {}, 0
  if name == 'app-gone' then
    -- What a power cycle leaves, and what a reset between stages leaves mid-sequence.
    sdec = nil
  elseif name == 'state-raises' then
    -- Any unguarded nil field inside bp_state reaches here. Injected directly so the case does not
    -- depend on WHICH field is unguarded today.
    sdec = {ui_notes = function() return {}, 0 end}
    bp_state = function() error('bp_state blew up') end
  elseif name == 'notes-raises' then
    -- The press itself SUCCEEDED and the tail raised. The measurement is complete; losing it to a
    -- timeout is the waste this guards against.
    sdec = {ui_notes = function() error('ui_notes blew up') end, res = nil, ui_mode = 'TEXT'}
  end
  local ok = pcall(bp_press, name, function() return 'ret' end)
  return ok, saw('PRESS ') ~= nil, saw('P end') ~= nil
end

local CASES = {'app-gone', 'state-raises', 'notes-raises'}
local NCASES = 3

-- ---- arm 1: the real preamble -------------------------------------------------------------------
realprint('bp_press, as shipped in ' .. SRC .. ':')
local i
for i = 1, NCASES do
  local c = CASES[i]
  stubs()
  assert(loadit(preamble()))()
  local ok, press, pend = run_case(c)
  realprint(string.format('  %-14s survived=%-5s PRESS=%-5s P-end=%-5s',
                          c, tostring(ok), tostring(press), tostring(pend)))
  check(c .. ': bp_press does not raise', ok, 'it raised')
  check(c .. ': a PRESS line reaches the host', press, 'the socket stayed silent')
  check(c .. ": 'P end' closes the press", pend, 'the host would read to its timeout')
end

-- The app-gone case must also SAY the app is gone. A press that invents a plausible state is worse
-- than one that raises, because the run goes green against an instrument that was never tested.
stubs()
assert(loadit(preamble()))()
run_case('app-gone')
local before = saw('BEFORE ')
check('app-gone: the state reported names the condition rather than inventing one',
      before ~= nil and string.find(before, 'APP%-GONE') ~= nil, before)

-- ---- arm 2: the control, which must fail every assertion above ---------------------------------
realprint('the unguarded fixture, which must fail all three:')
for i = 1, NCASES do
  local c = CASES[i]
  stubs()
  assert(loadit(UNGUARDED))()
  local ok, press, pend = run_case(c)
  realprint(string.format('  %-14s survived=%-5s PRESS=%-5s P-end=%-5s',
                          c, tostring(ok), tostring(press), tostring(pend)))
  if c == 'notes-raises' then
    -- Here the PRESS line DOES get out and only the tail is lost, which is the subtler half of the
    -- fault: the host's loop keeps reading, hits its timeout, and used to overwrite a good result.
    check('control/' .. c .. ': the tail is lost', not pend,
          "'P end' came out anyway -- the fixture no longer reproduces this")
  else
    check('control/' .. c .. ': the unguarded shape raises', not ok,
          'it survived -- the guard being tested is not what makes the difference')
    check('control/' .. c .. ': and the host sees nothing at all', not press,
          'a PRESS line came out anyway')
  end
end

print = realprint
realprint(string.format('\n%d passed, %d failed', npass, nfail))
if nfail > 0 then os.exit(1) end

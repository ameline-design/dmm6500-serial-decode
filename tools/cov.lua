-- Line coverage of tsp/ during an offline suite, with no dependencies beyond the debug library.
--
-- The executable-line DENOMINATOR is not guessed here: tools/covreport.py takes it from
-- `luac -l -p`, which lists the source line of every instruction the compiler actually emitted. So a
-- comment, a blank line and a bare `end` are never counted as uncovered.
--
--   COV_OUT=~/tmp/hits.txt COV_TARGET=tools/test_patterns.lua lua tools/cov.lua
--   COV_ARGS='--shard 1/12 --offsets 4' COV_TARGET=tools/sweep_startphase.lua lua tools/cov.lua
--
-- Run from the repo root: COV_TARGET is resolved relative to the current directory, and a run started
-- elsewhere loads nothing, dumps an empty-but-present file, and reads as a suite that covered nothing.

local HITS = {}
-- THE SOURCE TEST IS MEMOISED, because this hook fires on every line of every Lua file loaded --
-- the suites, the mock, the generator, not just tsp/ -- and a string.find per line is what makes the
-- run 30-50x slower rather than the 5-10x a first guess suggests. WANT caches the verdict per source
-- string, so the steady-state cost is one table lookup for the files we do not care about.
local WANT = {}
local OUT = os.getenv('COV_OUT') or 'cov_hits.txt'

-- HOW OFTEN A PARTIAL DUMP IS WRITTEN, in hook calls. Plain Lua cannot trap SIGTERM, so a killed run
-- can only leave evidence it wrote BEFORE it died -- and a coverage run is exactly the thing that gets
-- killed, being the slow one. Without this a SIGTERM leaves NO FILE AT ALL, not even a partial, and
-- "no hit file" then means killed-or-still-running rather than a suite that found nothing. Every
-- interval costs one rewrite of the accumulated set, which is milliseconds against minutes of hook.
local FLUSH_EVERY = 2000000
local since = 0

local writeout   -- forward declaration; defined below, called from the hook

local function hook()
  local i = debug.getinfo(2, 'Sl')
  if i == nil then return end
  local src = i.short_src
  if src == nil then return end
  local w = WANT[src]
  if w == nil then
    w = (string.find(src, 'tsp/', 1, true) ~= nil)
    WANT[src] = w
    if w then HITS[src] = {} end
  end
  if w then
    HITS[src][i.currentline] = true
    since = since + 1
    if since >= FLUSH_EVERY then since = 0; writeout(false) end
  end
end

-- The hit set as it stands. `final` only changes what is printed: the file is the same either way, so
-- a partial dump is a valid input to covreport.py rather than a special case it has to know about.
--
-- WRITTEN TO A SCRATCH NAME AND RENAMED. Opening OUT with 'w' truncates the previous snapshot before a
-- byte of the new one lands, so a kill during the rewrite leaves an empty or half-written file -- and a
-- half-written file is worse than none, because a line cut mid-number ('...tsp 88' for 887) parses as
-- a perfectly valid hit on a line that was never executed. os.rename is atomic within a filesystem, so
-- a reader sees either the whole old snapshot or the whole new one.
writeout = function(final)
  local tmp = OUT .. '.part'
  local fh = io.open(tmp, 'w')
  if fh == nil then
    io.stderr:write('COVERAGE DUMP FAILED: cannot open ' .. tostring(tmp) .. '\n')
    return
  end
  -- BUILT IN MEMORY AND WRITTEN ONCE, so there is ONE write result to check rather than one per line.
  -- An unchecked write publishes a truncated snapshot when the filesystem fills after the open: the
  -- rename then makes that partial file the authoritative one, and it looks exactly like a real result.
  local buf, nb = {}, 0
  local nsrc, nline = 0, 0
  for src, t in pairs(HITS) do
    local ls, n = {}, 0
    for l in pairs(t) do n = n + 1; ls[n] = l end
    table.sort(ls)
    local k
    for k = 1, n do nb = nb + 1; buf[nb] = src .. ' ' .. ls[k] end
    nsrc = nsrc + 1
    nline = nline + n
  end
  local body = ''
  if nb > 0 then body = table.concat(buf, '\n') .. '\n' end
  local wok, werr = fh:write(body)
  local cok, cerr = fh:close()
  if not wok or not cok then
    io.stderr:write('COVERAGE WRITE FAILED, not publishing a partial file: '
                    .. tostring(werr or cerr) .. '\n')
    os.remove(tmp)
    return
  end
  local rok, rerr = os.rename(tmp, OUT)
  if not rok then
    io.stderr:write('COVERAGE RENAME FAILED: ' .. tostring(rerr) .. '\n')
    return
  end
  if final then
    io.stderr:write(string.format('COVERAGE WROTE %s: %d source(s), %d line(s)\n', OUT, nsrc, nline))
  end
end

local dumped = false
local function dump()
  if dumped then return end
  dumped = true
  debug.sethook()
  writeout(true)
end

-- THE SUITES CALL os.exit, so the dump has to happen in front of it or a passing run writes nothing.
local realexit = os.exit
os.exit = function(...) dump(); return realexit(...) end

local target = os.getenv('COV_TARGET')
if target == nil then print('COV_TARGET is required'); realexit(2) end
arg = {}
local extra = os.getenv('COV_ARGS')
if extra ~= nil and extra ~= '' then
  local n = 0
  for w in string.gmatch(extra, '%S+') do n = n + 1; arg[n] = w end
end

-- OUT IS EMPTIED BEFORE THE FIRST LINE RUNS. Without this a run killed before its first flush leaves
-- the PREVIOUS run's hit file in place, and there is nothing in the file to say it is stale -- so the
-- old run's coverage is read as this one's, which is the same class of error as reading a missing
-- counter as zero. An empty file is unambiguous: it says this run measured nothing yet.
do
  local fh = io.open(OUT, 'w')
  if fh == nil then
    print('COVERAGE cannot write ' .. tostring(OUT))
    realexit(2)
  end
  fh:close()
end

debug.sethook(hook, 'l')
local ok, err = pcall(dofile, target)
dump()
-- THE TARGET'S OWN VERDICT IS NOT SWALLOWED. A suite that raised covered whatever it covered before it
-- died, and that hit file is worth keeping -- but reporting exit 0 for it would make a broken suite
-- look like a measured one.
if not ok then print('TARGET RAISED: ' .. tostring(err)); realexit(1) end

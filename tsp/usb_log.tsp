-- usb_log.tsp -- debug logging to the USB key, for TSP apps on Keithley TTI instruments (Lua 5.0.2).
-- A .tspa from the Apps menu has nowhere to print, and the event log holds only firmware errors and
-- is cleared by whatever happens next. `ulog` is the one exception to the one-global rule: sdec and
-- fftsa share it. No key is normal, so every call degrades to a no-op. io answers nil rather than
-- raising on every failure measured on 1.7.17a, including a write to a dead-key handle; a second
-- close is the one call here that does raise, so handles are deregistered before closing.

ulog        = ulog or {}

-- Declared, not assigned: re-running this file must not erase the only reference to an open file,
-- and firmware descriptors are not reclaimed until a power cycle, so every default below uses `or`.
-- ulog.fh      -- file handle object from io.open, or nil. Write through it with ulog.fh:write(s),
--                 never file.write: the firmware wrapper wants a descriptor and refuses an object.
-- ulog.lasterr
ulog.usbdir = ulog.usbdir or '/usb1/SERDEC'
ulog.path   = ulog.path or (ulog.usbdir .. '/dmm6500_log.txt')
-- Migrated, not just defaulted: the `or` above would inherit a root path from an older build. Only
-- the exact old default moves, so an override survives.
if ulog.path == '/usb1/dmm6500_log.txt' then ulog.path = ulog.usbdir .. '/dmm6500_log.txt' end
ulog.on       = ulog.on or false      -- true once a file is genuinely open
ulog.nlines   = ulog.nlines or 0
ulog.dropped  = ulog.dropped or 0     -- lines refused after the cap
ulog.maxlines = ulog.maxlines or 20000  -- cap, so a runaway loop cannot fill the key
-- nlines numbers the rows of one file and restarts at every open(); nwritten bounds the power cycle.
-- A key pulled and replaced restarts the allowance, and at 2 Hz a flapping contact does that unasked.
ulog.nwritten = ulog.nwritten or 0
ulog.tag      = ulog.tag or '?'       -- short app name, prefixed to every line
-- Booleans need an explicit nil test: `or true` would resurrect a false.
if ulog.enabled == nil then ulog.enabled = true end
if ulog.autoflush == nil then ulog.autoflush = true end
-- keybad stops further attempts and keywhy is the status-row sentence; keyout records the slot seen
-- empty, the only evidence that clears keybad. keygen counts insertions, so a caller holding a name
-- chosen on a departed key picks another, and keyopen is the generation the open log belongs to.
if ulog.keybad == nil then ulog.keybad = false end
if ulog.keyout == nil then ulog.keyout = false end
-- ulog.keywhy  -- why writing stopped, or nil
ulog.keygen  = ulog.keygen or 0
ulog.keyopen = ulog.keyopen or 0


-- Is a key in the slot? The only question answerable without naming a path.
function ulog.haskey()
  -- THE ONE DELIBERATE file.* SURVIVOR. It is the only SILENT way to ask whether a key is present:
  -- with the slot empty a file path posts 2224 and even file.open('/usb1') posts 2205, and io is no
  -- quieter -- io.open of a missing path posts 2203. It is also DMM-specific, with no io or os
  -- equivalent, and fs.is_dir('/usb1') answers a different question: a mounted root, not a key.
  if file.usbdriveexists() == 0 then return false end
  return true
end

-- Stop touching the key until one is inserted. A latch rather than a reason per attempt, because
-- presence is the only file failure the app can observe -- docs/MEASUREMENTS.md, 'A key pulled from
-- under a running app'.
function ulog.keylost(why)
  ulog.keybad  = true
  ulog.keywhy  = tostring(why or 'the USB key stopped accepting writes')
  ulog.lasterr = ulog.keywhy
  ulog.dirok   = nil
  -- keyok() sets this on seeing the slot empty. This may be running on a key still in it.
  ulog.keyout  = false
  local h      = ulog.fh
  ulog.fh, ulog.on = nil, false
  -- Closed here or never: with ulog.on false nothing else would.
  if h ~= nil then h:close() end
  return true
end

-- Is the key there and still accepting writes? One usbdriveexists, 237 us and silent, so it is
-- askable per line, per capture and per panel refresh. keylost() runs only from the no-key branch,
-- so keybad is set only with the slot empty; a refusing key is reported by its writer.
function ulog.keyok()
  if not ulog.haskey() then
    -- Not debounced, and a key that was never there is not a key that went away.
    if not ulog.keybad and (ulog.on or ulog.dirok ~= nil) then
      ulog.keylost('no USB key -- removed while running')
    end
    ulog.keyout = true          -- after keylost, which clears it
    return false
  end
  -- keyout means one was inserted and nothing is known about it, so the directory cache goes and
  -- keygen advances, telling flog_alloc() to pick a new name and resume() to re-open. Clearing on
  -- presence alone would retry a latched key once per capture.
  if ulog.keyout then
    ulog.keybad, ulog.keywhy, ulog.keyout = false, nil, false
    ulog.dirok  = nil
    ulog.keygen = (ulog.keygen or 0) + 1
  elseif ulog.keybad then
    return false
  end
  return true
end

-- Re-open the log on a key just inserted, which nothing else does: the debug log is held open
-- across captures where ensuredir and flog_alloc re-establish themselves at the next write. Keyed
-- on keygen, so one insertion causes one re-open however many callers ask, and that one attempt is
-- the whole allowance -- an open per line would post an event per line. An open that fails on a
-- present key waits for another, showing 'log: NOT LOGGING'.
function ulog.resume()
  if not ulog.enabled then return false end
  if not ulog.keyok() then return false end
  if ulog.keyopen == ulog.keygen then return ulog.on end
  ulog.keyopen = ulog.keygen
  return ulog.open(nil, false)
end

-- Is `name` listed in the USB root? true, false, or nil when the root could not be read. nil taken as
-- absence orders a mkdir on no evidence, and a mkdir on a directory already there posts 2220 -- a box
-- -- so the two must not be merged. fs.is_dir cannot express the nil, which is why it is not used.
--
-- fs.readdir replaced a parse of 65536 bytes of raw FAT table, which tied this to FAT32 and could
-- only see a name FAT stores contiguously: an 11-character directory once broke a run because its
-- long name was split across entries and read as absent.
--
-- Walked with pairs() because readdir is indexed from 0 -- measured on three directories: getn
-- reports one less than the entry count, and a directory holding one file reports getn 0.
--
-- Upper-cased on both sides, because the filesystem is case-insensitive and the directory on the
-- shipped key is actually 'SerDec'. An exact match would report it absent and mkdir over it.
function ulog.rootlists(name)
  if name == nil or name == '' then return nil end
  -- Guarded, not assumed. fs is always there on 1.7.17a, but a bare index would raise at launch on a
  -- firmware without it, and nil here is the honest answer: the root could not be read.
  if fs == nil or fs.readdir == nil then return nil end
  local t = fs.readdir('/usb1')
  if type(t) ~= 'table' then return nil end
  local want = string.upper(name)
  local k, v
  for k, v in pairs(t) do
    if type(v) == 'string' and string.upper(v) == want then return true end
  end
  return false
end

-- Make sure ulog.usbdir exists. true, or false and why not. Silent in every ordinary case, and
-- mkdir is never speculative, because there is no free one.
function ulog.ensuredir(dir)
  if dir == nil then dir = ulog.usbdir end
  if dir == nil or dir == '' then return false, 'no directory configured' end
  -- First, without touching a path: with no key a file path posts 2224 and /usb1 posts 2205. keyok()
  -- rather than haskey(), so the latch is honoured and a dead key is not re-probed per capture.
  if not ulog.keyok() then return false, tostring(ulog.keywhy or 'no USB key') end
  -- Cached, and only a confirmed directory is cached: the listing is one readdir, but this runs per
  -- capture.
  if ulog.dirok == dir then return true end
  if string.sub(dir, 1, 1) ~= '/' then return false, 'directory must be absolute: ' .. dir end
  -- One level below the root, checked: rootlists searches the /usb1 listing, so a deeper leaf can
  -- never appear in it. It answers false rather than nil, a mkdir goes out on no evidence, and with
  -- the intermediate directory absent that mkdir posts 2205 -- a box, once per capture, since dirok
  -- is never set. Every shipped default is one level, but `dir` is a parameter.
  local rest = string.gsub(dir, '^/[^/]*/?', '')
  if string.find(rest, '/') ~= nil then
    return false, 'directory must be one level below the root: ' .. dir
  end
  -- The listing no longer needs an 8.3 name, but the convention is kept: the host tools that prune
  -- and fetch the key match on these names.
  local leafchk = string.gsub(dir, '^.*/', '')
  if string.len(leafchk) > 8 or leafchk ~= string.upper(leafchk) then
    return false, 'directory name must be 8 upper-case characters or fewer: ' .. leafchk
  end
  local leaf   = string.gsub(dir, '^.*/', '')
  local listed = ulog.rootlists(leaf)
  if listed == true then ulog.dirok = dir; return true end
  -- Absence is not established, and a mkdir on that basis is the 2220 this path avoids.
  if listed == nil then return false, 'cannot read the USB root' end
  -- Bare, and it has to be: measured 2026-10-24, fs.mkdir returns nil on success AND on every
  -- failure, so a guard round it would report success every time. It posts 2220 for a directory that
  -- already exists and 2205 for an absent parent. The rootlists() re-read below is the only verdict
  -- there is, and the one piece of this function that must not be traded for a return value.
  fs.mkdir(dir)
  if ulog.rootlists(leaf) == true then ulog.dirok = dir; return true end
  return false, 'cannot create ' .. dir
end

-- Forget that the directory was confirmed, for the harness and the no-key gate.
function ulog.dirlost()
  ulog.dirok = nil
end

-- Open a file for writing. Handle, or nil and why. sdec.start() calls ensuredir(), so the 64 kB
-- listing is paid once per launch and the call below is a cached no-op. A failed open is reported
-- and not retried, having already posted its event; an inserted key is recovered from by resume().
function ulog.open_write(path, mode)
  if path == nil then return nil, 'no filename available' end
  if mode == nil then mode = 'a' end
  -- Before the open and before the directory, an open against an absent key posting 2224. The path
  -- goes in the reason, a bare 'no USB key' reading as the ordinary keyless run.
  if not ulog.keyok() then
    return nil, tostring(ulog.keywhy or 'no USB key') .. ' -- ' .. tostring(path)
  end
  local ready, rwhy = ulog.ensuredir()
  if not ready then return nil, tostring(rwhy) .. ' -- cannot open ' .. tostring(path) end
  local fh = io.open(path, mode)
  if fh ~= nil then return fh end
  -- Not a reason to latch: an absent directory reaches this as readily as a bad key, and a session
  -- of silence over a transient is the worse failure.
  return nil, 'cannot open ' .. tostring(path)
                .. ' -- key may be absent, full, write-protected, or refusing the directory'
end

-- Open the log. `truncate` starts a fresh file and the default appends, since comparing this run
-- against the last is usually the point. open_write owns the no-key gate and the reason.
function ulog.open(path, truncate)
  ulog.close()
  ulog.nlines, ulog.dropped, ulog.lasterr = 0, 0, nil
  if not ulog.enabled then return false end
  if path ~= nil then ulog.path = path end

  local mode = 'a'
  if truncate then mode = 'w' end
  local why = nil
  ulog.fh, why = ulog.open_write(ulog.path, mode)
  -- After the open, on both outcomes: open_write's keyok() is what advances keygen, so recording the
  -- generation first leaves keyopen one behind and resume() re-opens a current log, resetting nlines.
  ulog.keyopen = ulog.keygen
  if ulog.fh == nil then
    ulog.on      = false
    ulog.lasterr = tostring(why)
    return false
  end

  ulog.on     = true
  -- A separator distinguishes sessions in an appended file. os is tested, not caught: a nil os
  -- raises before pcall is entered.
  local stamp = ''
  if os ~= nil then
    local tok, tv = pcall(os.time)
    if tok and tv ~= nil then stamp = ' t=' .. tostring(tv) end
  end
  ulog.line('==== session start ' .. tostring(ulog.tag) .. stamp .. ' ====')
  return true
end

-- Write one line. No key, a pulled key and a missing directory are all gates that return false.
function ulog.line(s)
  if not ulog.enabled then return false end
  -- Off is recoverable, and the attempt belongs here rather than in five button handlers.
  if not ulog.on then
    if not ulog.resume() then return false end
  end
  -- Before the write, a write to a pulled key posting 2200 and returning. 237 us against a flush.
  if not ulog.keyok() then return false end
  if ulog.nlines >= ulog.maxlines or ulog.nwritten >= ulog.maxlines then
    ulog.dropped = ulog.dropped + 1
    return false
  end
  ulog.nlines   = ulog.nlines + 1
  ulog.nwritten = (ulog.nwritten or 0) + 1
  local txt = string.format('%05d %s %s\r\n', ulog.nlines or 0, tostring(ulog.tag),
                            tostring(s))
  -- A nil test, not a guard: `on` true implies a handle, and the invariant is worth a compare.
  if ulog.fh == nil then
    ulog.on      = false
    ulog.lasterr = 'the log handle went away'
    return false
  end
  ulog.fh:write(txt)
  -- Flush every line: the log that matters is the one before a panic. autoflush=false in a hot loop.
  if ulog.autoflush then ulog.fh:flush() end
  return true
end

-- string.format wrapper with explicit parameters: the 5.0.2 idiom string.format(f, unpack(arg))
-- relies on an implicit `arg` table host Lua removed. Five slots cover every call site.
function ulog.fmt(f, a, b, c, d, e)
  -- enabled, not `on`: line() recovers an inserted key, and gating on `on` would drop the first fmt.
  if not ulog.enabled then return false end
  local ok, s = pcall(string.format, f, a, b, c, d, e)
  if not ok then s = tostring(f) .. ' <ulog: bad format args>' end
  return ulog.line(s)
end

-- Flush buffered lines to the key without closing the file.
function ulog.flush()
  if not ulog.on or ulog.fh == nil then return false end
  ulog.fh:flush()
  return true
end

-- Flush and close the log, leaving no handle behind.
function ulog.close()
  if ulog.fh ~= nil then
    local h = ulog.fh
    ulog.fh = nil
    h:flush()
    h:close()
  end
  ulog.on = false
  return true
end

-- Does this file exist, without logging an error if it does not? true or false, never nil. fs.is_file
-- stays the probe: an open per candidate posts an event per candidate, and 1000 of them arrive as
-- 'Multiple errors have occurred' over the hex dump -- docs/MEASUREMENTS.md, 'fs.is_file against the
-- open probe'.
function ulog.exists(path)
  if path == nil then return false end
  -- Bare: fs.is_file answers false for a bad path and for garbage, and posts nothing.
  local got = fs.is_file(path)
  if got == nil then
    -- io.open, not file.open: both answer nil for an absent path, but file.open posts 2205 -- the one
    -- severity showevents still raises a box for -- where io posts 2203, which it does not. Measured
    -- on 1.7.17a, 2026-10-24. Still one event per call, so this stays the fallback and not the probe.
    -- The message io returns alongside the nil is dropped: presence is the whole question.
    local fh    = io.open(path, 'r')
    local taken = fh ~= nil
    if fh ~= nil then fh:close() end
    return taken
  end
  return got == true
end

-- First unused '<prefix>NNN<ext>' on the key. A path, or nil if every NNN is taken; 1000 names.
function ulog.next_free(prefix, ext, limit)
  if limit == nil then limit = 1000 end
  -- fs.is_file per candidate, posting nothing; with no directory the scan is worthless, so dir first.
  local dok, dwhy = ulog.ensuredir()
  if not dok then
    ulog.idx_why = tostring(dwhy)
    return nil
  end
  local idxpath = prefix .. 'idx.txt'

  -- A starting point, not an answer; the probe still runs forward from it.
  -- docs/MEASUREMENTS.md, "ulog.next_free's index and the wrapping scan".
  ulog.idx_ram  = ulog.idx_ram or {}
  local start   = ulog.idx_ram[prefix]
  if start ~= nil and (start < 0 or start >= limit) then start = nil end
  if start == nil and ulog.exists(idxpath) then
    -- io, not file: an EMPTY index file -- a key pulled mid-write, which is the case below -- is at
    -- end of file on the first read, and file.read answers nil there AND posts 2201 'File read error',
    -- a modal box nothing can suppress. io answers nil and posts nothing; measured 1.7.17a 2026-10-24.
    -- A key pulled mid-read gives nil from the read and nil from tonumber, so the close is reached.
    local fh = io.open(idxpath, 'r')
    if fh ~= nil then
      -- '*l' STRIPS the terminator where file.READ_LINE kept it. Nothing here counts bytes, and
      -- tonumber takes '5' and '5\n' alike, so the index reads the same either way.
      local ln = fh:read('*l')
      fh:close()
      local n = tonumber(ln)
      if n ~= nil and n >= 0 and n < limit then start = math.floor(n) end
    end
  end
  if start == nil then start = 0 end

  -- Exactly `limit` probes, wrapping, since the index may be stale high after deletions.
  local i, k
  for k = 0, limit - 1 do
    i = start + k
    if i >= limit then i = i - limit end      -- both are < limit, so one subtraction wraps it
    local path = string.format('%s%03d%s', tostring(prefix), i or 0, tostring(ext))
    if not ulog.exists(path) then
      -- Cache the index found, not the one after, so this stays a query: asked twice it answers once.
      ulog.idx_ram[prefix] = i
      local wh    = nil
      wh          = ulog.open_write(idxpath, 'w')
      local wrote = false
      if wh ~= nil then
        -- The verdict comes from the gate: a pcall round this write returns true however it went.
        wh:write(tostring(i) .. '\n')
        wh:flush()
        wh:close()
        wrote = ulog.keyok()
      end
      if wrote then ulog.idx_why = nil
      else ulog.idx_why = 'log index not saved -- numbering restarts after a power cycle' end
      return path
    end
  end
  -- Genuinely full. idx_why is set here, and names the leaf only: the note row shows 658 px.
  local leaf   = string.gsub(tostring(prefix), '^.*/', '')
  ulog.idx_why = string.format('all %d %sNNN%s names are taken', limit or 0, tostring(leaf), tostring(ext))
  return nil
end


-- Write an array of lines to its own file and close it. ok, reason. The handle never outlives it.
function ulog.write_file(path, lines, n)
  if path == nil then return false, 'no filename available' end
  -- MODE_WRITE creates the file, never its parent: a Save into an absent directory just fails.
  local fh, why = ulog.open_write(path, 'w')
  if fh == nil then return false, tostring(why) end

  local gone = false
  local i
  for i = 1, n do
    -- Per row. Measured 2026-10-24, KEY PULLED MID-CAPTURE WITH THE HANDLE HELD: an io write to a dead-key
    -- handle NEITHER RAISES NOR POSTS. pcall says ok, the event log stays at 0 over twelve writes,
    -- a flush and a close, and the data goes NOWHERE -- the file was 12 bytes before the pull and
    -- 12 bytes after. file.write posted 2200 per write here; io is the layer below the one that
    -- posts, so the storm is gone.
--
    -- SO THIS CHECK IS NOT ABOUT EVENTS ANY MORE, AND IT MUST NOT BE DELETED FOR LACK OF THEM.
    -- A silent write that discards its data leaves this as the ONLY way anything notices the key
    -- has gone.
    if not ulog.keyok() then gone = true; break end
    fh:write(tostring(lines[i]) .. '\r\n')
  end
  fh:flush()
  fh:close()
  -- The trailing keyok() is the detector; `gone` only short-circuits the remaining writes.
  if gone or not ulog.keyok() then
    return false, 'the USB key went away -- the file is empty or truncated'
  end
  return true
end

-- One-line state summary for the panel. Name only: the status row shows ~45 proportional characters.
function ulog.status()
  if not ulog.enabled then return 'log off' end
  if not ulog.on then
    local why = ulog.lasterr
    if why == nil then why = 'not open' end
    return 'log: ' .. why
  end
  local extra = ''
  if ulog.dropped > 0 then extra = string.format(' (+%d dropped)', ulog.dropped or 0) end
  local base = string.gsub(tostring(ulog.path), '^.*/', '')
  return string.format('log: %d ln %s%s', ulog.nlines or 0, tostring(base), tostring(extra))
end

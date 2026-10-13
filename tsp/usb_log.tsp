-- usb_log.tsp -- debug logging to the USB key, for TSP apps on Keithley TTI instruments (Lua 5.0.2).
-- A .tspa from the Apps menu has nowhere to print, and the event log holds only firmware errors and
-- is cleared by whatever happens next. `ulog` is the one exception to the one-global rule: sdec and
-- fftsa share it. No key is normal, so every call degrades to a no-op, and no file call raises.
-- The file API's measured behaviour is in docs/MEASUREMENTS.md, 'The USB file API'.

ulog = ulog or {}

-- Declared, not assigned: opening the installed App re-runs this file, and a file-scope
-- `ulog.fh = nil` would erase the only reference to an open file before anything could close it.
-- Firmware descriptors are not reclaimed until a power cycle, so every default below uses `or`.
-- ulog.fh      -- file number from file.open, or nil
-- ulog.lasterr
-- The directory is named once here; the byte log, the Save reports and this log all build on it.
ulog.usbdir    = ulog.usbdir or '/usb1/SERDEC'
ulog.path      = ulog.path or (ulog.usbdir .. '/dmm6500_log.txt')
-- Migrated, not just defaulted: the `or` above would inherit a root path from an older build and go
-- on writing there. Only the exact old default moves, so an override survives.
if ulog.path == '/usb1/dmm6500_log.txt' then ulog.path = ulog.usbdir .. '/dmm6500_log.txt' end
ulog.on        = ulog.on or false      -- true once a file is genuinely open
ulog.nlines    = ulog.nlines or 0
ulog.dropped   = ulog.dropped or 0     -- lines refused after the cap
ulog.maxlines  = ulog.maxlines or 20000  -- cap, so a runaway loop cannot fill the key
-- nlines numbers the rows of one file and restarts at every open(); nwritten bounds the power cycle.
-- A key pulled and replaced restarts the allowance, and at 2 Hz a flapping contact does that unasked.
ulog.nwritten  = ulog.nwritten or 0
ulog.tag       = ulog.tag or '?'       -- short app name, prefixed to every line
-- Booleans need an explicit nil test: `or true` would resurrect a false.
if ulog.enabled == nil then ulog.enabled = true end
if ulog.autoflush == nil then ulog.autoflush = true end
-- keybad stops further attempts, keywhy is the status-row sentence, and keyout records the slot seen
-- empty, which is the only evidence that clears keybad. keygen counts insertions, so a caller
-- holding a name chosen on a departed key -- sdec.flog_path -- knows to pick another. keyopen is the
-- generation the open log belongs to.
if ulog.keybad == nil then ulog.keybad = false end
if ulog.keyout == nil then ulog.keyout = false end
-- ulog.keywhy  -- why writing stopped, or nil
ulog.keygen    = ulog.keygen or 0
ulog.keyopen   = ulog.keyopen or 0

-- Finding the directory, with no free way to ask whether one exists: mkdir posts 2208 even for a
-- name that already exists, and opening a missing path posts 2205. So ask usbdriveexists() first,
-- which is silent, then read /usb1's raw FAT table, then create only on a genuine absence.
-- docs/MEASUREMENTS.md, 'file.mkdir'.

-- Is a key in the slot? The only question answerable without naming a path.
function ulog.haskey()
  if file.usbdriveexists() == 0 then return false end
  return true
end

-- Stop touching the key until one is inserted. A latch, not a reason per attempt, because presence is
-- the only file failure the app can observe -- a write to a pulled key returns normally and posts
-- 2200. docs/MEASUREMENTS.md, 'A key pulled from under a running app'.
function ulog.keylost(why)
  ulog.keybad = true
  ulog.keywhy = tostring(why or 'the USB key stopped accepting writes')
  ulog.lasterr = ulog.keywhy
  -- The confirmed directory belonged to the departed key.
  ulog.dirok = nil
  -- keyok() sets this on seeing the slot empty. This may be running on a key still in it.
  ulog.keyout = false
  local h = ulog.fh
  ulog.fh, ulog.on = nil, false
  -- Closed here or never: with ulog.on false nothing else would.
  if h ~= nil then file.close(h) end
  return true
end

-- Is the key there and still accepting writes? One usbdriveexists, 237 us and silent, so it is
-- askable per line, per capture and per panel refresh. keylost() is called only from the no-key
-- branch, so keybad is set only with the slot empty; a refusing key is reported by its writer.
function ulog.keyok()
  if not ulog.haskey() then
    -- Not debounced, and a key that was never there is not a key that went away.
    -- docs/MEASUREMENTS.md, 'The key-presence latch is not debounced'.
    if not ulog.keybad and (ulog.on or ulog.dirok ~= nil) then
      ulog.keylost('no USB key -- removed while running')
    end
    ulog.keyout = true          -- after keylost, which clears it
    return false
  end
  -- keyout means one was inserted. Nothing is known about it, so the directory cache goes and keygen
  -- advances, which tells flog_alloc() to pick a new name and resume() to re-open. Clearing on
  -- presence alone would retry a latched key once per capture.
  if ulog.keyout then
    ulog.keybad, ulog.keywhy, ulog.keyout = false, nil, false
    ulog.dirok = nil
    ulog.keygen = (ulog.keygen or 0) + 1
  elseif ulog.keybad then
    return false
  end
  return true
end

-- Re-open the log on a key just inserted. ensuredir and flog_alloc re-establish themselves at the
-- next write, but the debug log is held open across captures, so nothing else would re-open it.
-- Keyed on keygen, so one insertion causes one re-open however many callers ask, and one attempt per
-- insertion is the whole allowance -- the alternative is an open attempt per line, and a failed open
-- posts an event. An open that fails on a present key waits for another, showing 'log: NOT LOGGING'.
function ulog.resume()
  if not ulog.enabled then return false end
  if not ulog.keyok() then return false end
  if ulog.keyopen == ulog.keygen then return ulog.on end
  ulog.keyopen = ulog.keygen
  return ulog.open(nil, false)
end

-- Is `name` listed in the USB root? true, false, or nil when the root could not be read. nil taken
-- as absence orders a mkdir on no evidence and posts 2208, so the two must not be merged.
--
-- Only an 8.3-clean name is contiguous in the FAT table, which is why the directory is 'SERDEC':
-- docs/MEASUREMENTS.md, 'Why the directory is called SERDEC'. Not a FAT parser -- a file of this
-- name, or a deleted entry whose bytes remain, both err towards 'present' and cost a failed open.
function ulog.rootlists(name)
  if name == nil or name == '' then return nil end
  local fh = file.open('/usb1', file.MODE_READ)
  if fh == nil then return nil end
  -- file.read returns nil and posts 2201 on a closed or write-mode handle, so nil is the whole verdict.
  local raw = file.read(fh, file.READ_ALL)
  file.close(fh)
  if raw == nil then return nil end
  -- `1` for a plain find, no patterns.
  if string.find(raw, string.upper(name), 1, 1) ~= nil then return true end
  return false
end

-- Make sure ulog.usbdir exists. true, or false and why not. Silent in every ordinary case, and mkdir
-- is never speculative, because there is no free one.
function ulog.ensuredir(dir)
  if dir == nil then dir = ulog.usbdir end
  if dir == nil or dir == '' then return false, 'no directory configured' end
  -- First, without touching a path: with no key a file path posts 2224 and /usb1 posts 2205. keyok()
  -- not haskey(), so the latch is honoured and the directory is not re-established per capture under
  -- a key nothing can write.
  if not ulog.keyok() then return false, tostring(ulog.keywhy or 'no USB key') end
  -- Cached, the root listing being 65536 bytes. Only a confirmed directory is cached, and dirlost()
  -- drops it when an open fails -- the one moment it could be wrong.
  if ulog.dirok == dir then return true end
  if string.sub(dir, 1, 1) ~= '/' then return false, 'directory must be absolute: ' .. dir end
  -- Refused rather than renamed silently: a longer name is not contiguous in the FAT table, so every
  -- lookup would answer absent, order a mkdir on a directory that exists, and post 2208.
  local leafchk = string.gsub(dir, '^.*/', '')
  if string.len(leafchk) > 8 or leafchk ~= string.upper(leafchk) then
    return false, 'directory name must be 8 upper-case characters or fewer: ' .. leafchk
  end
  local leaf = string.gsub(dir, '^.*/', '')
  local listed = ulog.rootlists(leaf)
  if listed == true then ulog.dirok = dir; return true end
  -- Absence is not established, and a mkdir on that basis is the 2208 this path avoids.
  if listed == nil then return false, 'cannot read the USB root' end
  -- Bare: mkdir has no return value, so a guard reports success every time.
  file.mkdir(dir)
  if ulog.rootlists(leaf) == true then ulog.dirok = dir; return true end
  return false, 'cannot create ' .. dir
end

-- Forget that the directory was confirmed. For the harness and the no-key gate; swapping a key under
-- a running app is unsupported.
function ulog.dirlost()
  ulog.dirok = nil
end

-- Open a file for writing. Handle, or nil and why. sdec.start() calls ensuredir(), so the 64 kB
-- listing is paid once per launch and the call below is a cached no-op. A failed open is reported,
-- not retried: it has already posted its event, so a retry cannot keep the panel quiet. An inserted
-- key is still recovered from, by resume().
function ulog.open_write(path, mode)
  if path == nil then return nil, 'no filename available' end
  if mode == nil then mode = file.MODE_APPEND end
  -- Before the open and before the directory, since an open against an absent key posts 2224. The
  -- path goes in the reason: Save and the note row have no other way to say which file failed, and a
  -- bare 'no USB key' reads as the ordinary keyless run rather than a key the app watched go.
  if not ulog.keyok() then
    return nil, tostring(ulog.keywhy or 'no USB key') .. ' -- ' .. tostring(path)
  end
  local ready, rwhy = ulog.ensuredir()
  if not ready then return nil, tostring(rwhy) .. ' -- cannot open ' .. tostring(path) end
  -- A failed open returns nil, so the nil test is the error handling.
  local fh = file.open(path, mode)
  if fh ~= nil then return fh end
  -- Not a reason to latch: an absent directory reaches this as readily as a bad key, and keylost()
  -- would stop logging for the session over a transient. Listed, not diagnosed -- a key can be
  -- pulled between haskey() and this open.
  return nil, 'cannot open ' .. tostring(path)
                .. ' -- key may be absent, full, write-protected, or refusing the directory'
end

-- Open the log. `truncate` starts a fresh file; the default appends, since comparing this run against
-- the last is usually the point. open_write owns the no-key gate, the directory and the reason.
function ulog.open(path, truncate)
  ulog.close()
  ulog.nlines, ulog.dropped, ulog.lasterr = 0, 0, nil
  if not ulog.enabled then return false end
  if path ~= nil then ulog.path = path end

  local mode = file.MODE_APPEND
  if truncate then mode = file.MODE_WRITE end
  local why = nil
  ulog.fh, why = ulog.open_write(ulog.path, mode)
  -- After the open, on both outcomes: open_write's keyok() is what advances keygen, so recording the
  -- generation first leaves keyopen one behind and resume() re-opens a current log, resetting nlines.
  ulog.keyopen = ulog.keygen
  if ulog.fh == nil then
    ulog.on = false
    ulog.lasterr = tostring(why)
    return false
  end

  ulog.on = true
  -- A separator distinguishes sessions in an appended file. os is tested, not caught: unlike file and
  -- fs it is not hardware-verified anywhere here, and a nil os raises before pcall is entered. A nil
  -- os.time is safe, since pcall(nil) returns false.
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
  -- Before the write, since the write posts 2200 and cannot report having done so. 237 us against a
  -- line that already flushes.
  if not ulog.keyok() then return false end
  if ulog.nlines >= ulog.maxlines or ulog.nwritten >= ulog.maxlines then
    ulog.dropped = ulog.dropped + 1
    return false
  end
  ulog.nlines = ulog.nlines + 1
  ulog.nwritten = (ulog.nwritten or 0) + 1
  local txt = string.format('%05d %s %s\r\n', ulog.nlines or 0, tostring(ulog.tag),
                            tostring(s))
  -- A nil test, not a guard: `on` true implies a handle by construction, and that invariant is worth
  -- a compare rather than passing nil to file.write.
  if ulog.fh == nil then
    ulog.on = false
    ulog.lasterr = 'the log handle went away'
    return false
  end
  file.write(ulog.fh, txt)
  -- Flush every line: the most valuable log is the one written just before a firmware panic, and
  -- anything buffered is lost. Set ulog.autoflush = false in a hot loop.
  if ulog.autoflush then file.flush(ulog.fh) end
  return true
end

-- string.format wrapper with explicit parameters. The 5.0.2 idiom string.format(f, unpack(arg))
-- relies on an implicit `arg` table that host Lua removed, so it cannot be exercised offline. Five
-- slots cover every call site, and string.format ignores surplus arguments.
function ulog.fmt(f, a, b, c, d, e)
  -- enabled, not `on`: line() recovers an inserted key, and gating on `on` would drop the first fmt
  -- after an insertion while keeping the first line.
  if not ulog.enabled then return false end
  local ok, s = pcall(string.format, f, a, b, c, d, e)
  if not ok then s = tostring(f) .. ' <ulog: bad format args>' end
  return ulog.line(s)
end

-- Flush buffered lines to the key without closing the file.
function ulog.flush()
  if not ulog.on or ulog.fh == nil then return false end
  file.flush(ulog.fh)
  return true
end

-- Flush and close the log, leaving no handle behind.
function ulog.close()
  if ulog.fh ~= nil then
    local h = ulog.fh
    ulog.fh = nil
    file.flush(h)
    file.close(h)
  end
  ulog.on = false
  return true
end

-- Does this file exist, without logging an error if it does not? true or false, never nil. The open
-- probe would post 2205 at the one severity showevents still raises a box for, so finding a free name
-- would produce one on every Save. docs/MEASUREMENTS.md, 'fs.is_file against the open probe'.
function ulog.exists(path)
  if path == nil then return false end
  -- Bare: fs.is_file answers false for a bad path and for garbage, and posts nothing.
  local got = fs.is_file(path)
  if got == nil then
    -- One 2205 beats truncating a file or refusing to save. No key and no such file are the same
    -- answer, correctly: 'free', with the failure surfacing at the write.
    local fh = file.open(path, file.MODE_READ)
    local taken = fh ~= nil
    if fh ~= nil then file.close(fh) end
    return taken
  end
  return got == true
end

-- First unused '<prefix>NNN<ext>' on the key. A path, or nil if every NNN is taken. 1000 names, three
-- digits; a bench session pressing New Log per device reaches 100.
function ulog.next_free(prefix, ext, limit)
  if limit == nil then limit = 1000 end
  -- The scan posts 2205 per miss, probing forward and using the failure as its answer. With no key or
  -- no directory every candidate posts its own event and the answer is worthless anyway.
  local dok, dwhy = ulog.ensuredir()
  if not dok then
    ulog.idx_why = tostring(dwhy)
    return nil
  end
  local idxpath = prefix .. 'idx.txt'

  -- A starting point, not an answer; the probe still runs forward from it.
  -- docs/MEASUREMENTS.md, "ulog.next_free's index and the wrapping scan".
  ulog.idx_ram = ulog.idx_ram or {}
  local start = ulog.idx_ram[prefix]
  if start ~= nil and (start < 0 or start >= limit) then start = nil end
  if start == nil and ulog.exists(idxpath) then
    -- A key pulled between the open and the read gives nil from file.read and nil from tonumber, so
    -- the close is always reached.
    local fh = file.open(idxpath, file.MODE_READ)
    if fh ~= nil then
      local ln = file.read(fh, file.READ_LINE)
      file.close(fh)
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
      -- Cache the index found, not the one after it, so this stays a query: asked twice it returns
      -- the same name. Once the file exists the probe steps over it, at one extra open.
      ulog.idx_ram[prefix] = i
      local wh = nil
      wh = ulog.open_write(idxpath, file.MODE_WRITE)
      local wrote = false
      if wh ~= nil then
        -- The verdict comes from the gate: a pcall round this write returns true however it went, so
        -- `wrote` would be a constant and the note below could never appear.
        file.write(wh, tostring(i) .. '\n')
        file.flush(wh)
        file.close(wh)
        wrote = ulog.keyok()
      end
      if wrote then ulog.idx_why = nil
      else ulog.idx_why = 'log index not saved -- numbering restarts after a power cycle' end
      return path
    end
  end
  -- Genuinely full. idx_why is set here, and names the leaf only: the note row shows 658 px.
  local leaf = string.gsub(tostring(prefix), '^.*/', '')
  ulog.idx_why = string.format('all %d %sNNN%s names are taken', limit or 0, tostring(leaf), tostring(ext))
  return nil
end


-- Write an array of lines to its own file and close it. ok, reason. Not routed through the rolling
-- log: a saved capture wants its own file, and the handle never outlives the call.
function ulog.write_file(path, lines, n)
  if path == nil then return false, 'no filename available' end
  -- MODE_WRITE creates the file, never its parent, so a Save into an absent directory fails with
  -- 'cannot write' and no sign the directory was all of it. Save puts this on the note row.
  local fh, why = ulog.open_write(path, file.MODE_WRITE)
  if fh == nil then return false, tostring(why) end

  local gone = false
  local i
  for i = 1, n do
    -- Per row, to suppress the event storm: a write to a departed key posts 2200 and returns, so
    -- checking only after the loop means 24 modal dialogs for a report and 2048 for a 32 kB one.
    if not ulog.keyok() then gone = true; break end
    file.write(fh, tostring(lines[i]) .. '\r\n')
  end
  file.flush(fh)
  file.close(fh)
  -- The trailing keyok() is the detector and catches a key lost anywhere in the loop; `gone` only
  -- short-circuits the remaining writes.
  if gone or not ulog.keyok() then
    return false, 'the USB key went away -- the file is empty or truncated'
  end
  return true
end

-- One-line state summary for the panel, so logging can be seen rather than assumed. Name only: the
-- status row shows ~45 proportional characters, and the directory never varies.
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

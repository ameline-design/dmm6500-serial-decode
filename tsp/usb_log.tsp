-- usb_log.tsp -- best-effort debug logging to the USB flash drive, for TSP apps
-- on the DMM6500 (Lua 5.0.2).
--
-- A .tspa launched from the Apps menu has nowhere to print: no host socket is
-- attached, `print()` goes to an interface nobody is reading, and the event log
-- holds only firmware errors and is cleared by whatever happens next. So the two
-- failure modes that matter most -- a fault on a front-panel launch, and a fault
-- just before a firmware panic -- leave no evidence. A file on the USB key
-- survives both.
--
-- NAMESPACE: the one deliberate exception to the one-global rule, since this is
-- shared between the serial decoder (`sdec`) and the FFT analyser (`fftsa`).
-- Everything hangs off `ulog`.
--
-- API (docs/DMM6500-901-01B_Sept_2019_Ref.txt, file.open at 14-255):
--   file.open(path, file.MODE_APPEND) -> file number, or NIL on failure
--   file.write(n, s) / file.flush(n) / file.close(n)
--   MODE_APPEND creates the file if absent; paths are absolute, USB root /usb1/.
--
-- The nil return matters: no USB key is a NORMAL condition, so every call here
-- degrades to a no-op rather than raising. An app must never fail because logging
-- failed.

ulog = ulog or {}

-- DECLARED, NOT ASSIGNED, for the same reason as the sdec state: opening the
-- installed App re-runs this whole file, and a file-scope `ulog.fh = nil` would
-- erase the only reference to an already-open file before anything could close it,
-- leaking a firmware file descriptor and losing whatever was still buffered. Every
-- default below therefore uses `or`, and the handle is not assigned at all.
-- ulog.fh      -- file number from file.open, or nil
-- ulog.lasterr
ulog.path      = ulog.path or '/usb1/dmm6500_log.txt'
ulog.on        = ulog.on or false      -- true once a file is genuinely open
ulog.nlines    = ulog.nlines or 0
ulog.dropped   = ulog.dropped or 0     -- lines refused after the cap
ulog.maxlines  = ulog.maxlines or 20000  -- per-session cap, so a runaway loop cannot fill the key
ulog.tag       = ulog.tag or '?'       -- short app name, prefixed to every line
-- Booleans need an explicit nil test: `or true` would resurrect a deliberate false.
if ulog.enabled == nil then ulog.enabled = true end
if ulog.autoflush == nil then ulog.autoflush = true end

-- Open the log. `truncate` starts a fresh file; the default appends across
-- sessions, since comparing this run against the last is usually the point.
-- Returns true if logging is live.
--
-- Wrapped throughout: a missing key returns nil, but a firmware without the file
-- API would raise on indexing `file`, and that must not take the app down.
function ulog.open(path, truncate)
  ulog.close()
  ulog.nlines, ulog.dropped, ulog.lasterr = 0, 0, nil
  if not ulog.enabled then return false end
  if path ~= nil then ulog.path = path end

  local ok, err = pcall(function()
    local mode = file.MODE_APPEND
    if truncate then mode = file.MODE_WRITE end
    ulog.fh = file.open(ulog.path, mode)
  end)
  if not ok then
    ulog.fh, ulog.on, ulog.lasterr = nil, false, tostring(err)
    return false
  end
  if ulog.fh == nil then
    ulog.on = false
    ulog.lasterr = 'no USB key at ' .. tostring(ulog.path)
    return false
  end

  ulog.on = true
  -- A separator distinguishes sessions in an appended file. os.time may not exist
  -- on this firmware, so it is probed once here rather than risked on every line.
  local stamp = ''
  pcall(function()
    if os ~= nil and os.time ~= nil then stamp = ' t=' .. tostring(os.time()) end
  end)
  ulog.line('==== session start ' .. tostring(ulog.tag) .. stamp .. ' ====')
  return true
end

-- Write one line. Never raises: a logging call site should read as a statement,
-- not as something to check.
function ulog.line(s)
  if not ulog.on or not ulog.enabled then return false end
  if ulog.nlines >= ulog.maxlines then
    ulog.dropped = ulog.dropped + 1
    return false
  end
  ulog.nlines = ulog.nlines + 1
  local txt = string.format('%05d %s %s\r\n', ulog.nlines, tostring(ulog.tag),
                            tostring(s))
  local ok, err = pcall(function()
    file.write(ulog.fh, txt)
    -- Flushing every line is deliberate: the most valuable log is the one written
    -- immediately before a firmware panic, and anything still buffered then is
    -- lost. Set ulog.autoflush = false in a hot loop.
    if ulog.autoflush then file.flush(ulog.fh) end
  end)
  if not ok then
    -- Key pulled mid-session, or the filesystem is full. Stop trying: repeating a
    -- failing write every line would be its own denial of service.
    --
    -- AND CLOSE THE HANDLE. Setting `on = false` while keeping ulog.fh would leave a firmware
    -- file descriptor open for the rest of the power cycle: nothing logs again, so nothing
    -- would close it.
    ulog.on, ulog.lasterr = false, tostring(err)
    local h = ulog.fh
    ulog.fh = nil
    if h ~= nil then pcall(function() file.close(h) end) end
    return false
  end
  return true
end

-- string.format wrapper with EXPLICIT parameters rather than varargs.
--
-- The 5.0.2 vararg idiom, string.format(f, unpack(arg)), relies on an implicit
-- `arg` table that host Lua removed -- so it could not be exercised offline at
-- all, which is unacceptable in a logger. Five slots cover every call site,
-- string.format ignores surplus arguments, and this behaves identically on 5.0.2
-- and 5.4. Guarded so a format mismatch cannot raise from inside a log call.
function ulog.fmt(f, a, b, c, d, e)
  if not ulog.on or not ulog.enabled then return false end
  local s
  local ok = pcall(function() s = string.format(f, a, b, c, d, e) end)
  if not ok then s = tostring(f) .. ' <ulog: bad format args>' end
  return ulog.line(s)
end

-- Flush buffered lines to the key without closing the file.
function ulog.flush()
  if not ulog.on then return false end
  return pcall(function() file.flush(ulog.fh) end)
end

-- Flush and close the log, leaving no handle behind.
function ulog.close()
  if ulog.fh ~= nil then
    local h = ulog.fh
    ulog.fh = nil
    pcall(function()
      file.flush(h)
      file.close(h)
    end)
  end
  ulog.on = false
  return true
end

-- DOES THIS FILE EXIST, WITHOUT LOGGING AN ERROR IF IT DOES NOT?
--
-- Testing existence with file.open(path, MODE_READ) uses the FAILURE as the answer, and a failed
-- open posts event 2205 at severity ERROR. The app sets localnode.showevents = eventlog.SEV_ERROR
-- to suppress warning and info popups, so 2205 is precisely the severity that still raises a modal
-- box -- which makes the SUCCESSFUL path (finding a free name) produce one on every Save.
--
-- fs.is_file() answers the same question silently. Verified on firmware 1.7.17a: eventlog.getcount()
-- stays 0 across both an existing and a missing path.
--
-- Returns true or false, never nil. A PROBE THAT RAISES answers TAKEN: losing a name beats
-- truncating a real file. A nil is NOT taken -- fs.is_file returning nil falls through to the open
-- probe, and file.open returning nil (no key, or no such file) is the normal FREE answer, with the
-- failure surfacing at the write where it belongs.
function ulog.exists(path)
  if path == nil then return false end
  local got = nil
  local ok = pcall(function()
    if fs ~= nil and fs.is_file ~= nil then got = fs.is_file(path) end
  end)
  if not ok or got == nil then
    -- No fs.is_file. Fall back to the open probe, which is what this replaced -- one 2205 is
    -- better than either truncating a file or refusing to save.
    local taken = false
    local pok = pcall(function()
      local fh = file.open(path, file.MODE_READ)
      if fh ~= nil then
        taken = true
        file.close(fh)
      end
    end)
    -- A PROBE THAT RAISED KNOWS NOTHING, AND MUST SAY TAKEN. This block contradicted the promise made
    -- at the top of this very function -- "a nil is treated as TAKEN, losing a name is better than
    -- truncating a real file" -- because `taken` was initialised false and the pcall's verdict was
    -- discarded. So a file.open that RAISED reported the candidate as FREE, and sdec.save() opens the
    -- name it is given with MODE_WRITE: the operator's existing capture, truncated to nothing.
    --
    -- Not the no-key case, which is why this survived: with no key file.open RETURNS NIL rather than
    -- raising, so "free" is still the answer there and the failure surfaces later at the write, where it
    -- belongs. This is the case where the filesystem itself refuses the question.
    if not pok then return true end
    return taken
  end
  return got == true
end

-- First unused '<prefix>NNN<ext>' on the key, so successive saves do not overwrite each other.
-- Returns a path, or nil if every NNN is taken.
--
-- THE INDEX IS A STARTING POINT, NOT AN ANSWER. prefix..'idx.txt' remembers where to start so the
-- common path costs one open instead of N, but the probe still runs forward from there: a file the
-- index does not know about -- copied onto the key, or written by another prefix -- would otherwise
-- be handed out and TRUNCATED by MODE_WRITE.
--
-- 1000 names, three digits. At 100 the byte log simply stopped logging once prefix000..099 existed,
-- and a bench session that presses NewLog per device reaches 100.
function ulog.next_free(prefix, ext, limit)
  if limit == nil then limit = 1000 end
  local idxpath = prefix .. 'idx.txt'

  -- THE INDEX IS A STARTING POINT, NOT AN ANSWER.
  --
  -- The scan itself was the pathology: probing bytes000, bytes001, ... until file.open FAILED
  -- takes the failure as its "this one is free" signal, and every failure posts "2205 File not
  -- found". Allocating bytes006 is seven opens, so repeated New Log presses generate errors
  -- QUADRATICALLY and the panel raises a modal "Multiple errors have occurred" box over the hex
  -- dump. Measured on the instrument.
  --
  -- Remembering where to start fixes that -- one open per allocation instead of N -- but it must
  --
  -- So: start where the index says, then probe forward. Never truncates, and costs one failed
  -- open per allocation rather than one per file already on the key.
  ulog.idx_ram = ulog.idx_ram or {}
  local start = ulog.idx_ram[prefix]
  if start ~= nil and (start < 0 or start >= limit) then start = nil end
  if start == nil and ulog.exists(idxpath) then
    -- THE HANDLE IS CLOSED OUTSIDE THE pcall THAT MIGHT RAISE. A file.read that raises -- the key
    -- pulled between open and read -- would otherwise exit the pcall before file.close, and the
    -- handle is local, so it would become permanently unreachable.
    local fh = nil
    pcall(function() fh = file.open(idxpath, file.MODE_READ) end)
    if fh ~= nil then
      local ln = nil
      pcall(function() ln = file.read(fh, file.READ_LINE) end)
      pcall(function() file.close(fh) end)
      local n = tonumber(ln)
      if n ~= nil and n >= 0 and n < limit then start = math.floor(n) end
    end
  end
  if start == nil then start = 0 end

  -- EXACTLY `limit` PROBES, WRAPPING PAST THE END. The index may be stale HIGH (files deleted), so
  -- an exhausted forward scan has to continue at 0 rather than refuse: a key whose bytes000 was
  -- deleted must not report "no names left".
  --
  -- Wrapping, rather than clearing ulog.idx_ram and calling this again: that retry re-read the
  -- index FILE, which still held the same high number -- it is only rewritten when a free name IS
  -- found -- so `start` came back identical, the scan exhausted identically, and it went round
  -- again. 5.0.2 has proper tail calls, so it never overflowed the stack and a caller's pcall could
  -- not break it; the panel hung until a power cycle, and handing out the 1000th name reaches that
  -- state on its own. Here the bound is the loop's own count and every candidate is visited once.
  local i, k
  for k = 0, limit - 1 do
    i = start + k
    if i >= limit then i = i - limit end      -- both are < limit, so one subtraction wraps it
    local path = string.format('%s%03d%s', prefix, i, ext)
    if not ulog.exists(path) then
      -- CACHE THE INDEX FOUND, NOT THE ONE AFTER IT -- so this stays a pure QUERY.
      --
      -- Storing i+1 made next_free() advance on every call, which meant asking twice gave two
      --
      -- Storing i is idempotent: call it again and the probe finds i still free and returns the
      -- same name. Once the file really exists, the probe finds i taken and moves on, at a cost
      -- of one extra open. That keeps the cache's whole purpose -- not re-probing every file
      -- already on the key, which is what posted a 2205 per miss -- without the side effect.
      ulog.idx_ram[prefix] = i
      -- Same shape as the read above: open outside, close unconditionally.
      local wh = nil
      pcall(function() wh = file.open(idxpath, file.MODE_WRITE) end)
      local wrote = false
      if wh ~= nil then
        wrote = pcall(function()
          file.write(wh, tostring(i) .. '\n')
          file.flush(wh)
        end)
        pcall(function() file.close(wh) end)
      end
      if wrote then ulog.idx_why = nil
      else ulog.idx_why = 'log index not saved -- numbering restarts after a power cycle' end
      return path
    end
  end
  -- Genuinely full. The index file is left alone: it still points into a full range, which costs
  -- one wasted probe per call and nothing else, and the failure path must not need a working key.
  return nil
end


-- Write a whole array of lines to its own file and close it immediately.
--
-- Deliberately NOT routed through the rolling log: a saved capture wants its own
-- file, and interleaving it with debug output would make both harder to read. Uses a
-- separate handle that never outlives the call, so it cannot interact with
-- ulog.fh's lifetime. Returns ok, reason.
function ulog.write_file(path, lines, n)
  if path == nil then return false, 'no filename available' end
  local fh = nil
  local ok, err = pcall(function() fh = file.open(path, file.MODE_WRITE) end)
  if not ok then return false, tostring(err) end
  if fh == nil then return false, 'cannot write ' .. tostring(path) end

  local wrote = true
  local i
  for i = 1, n do
    local w = pcall(function() file.write(fh, tostring(lines[i]) .. '\r\n') end)
    if not w then wrote = false; break end
  end
  -- FLUSH AND CLOSE IN SEPARATE pcalls, AND THE FLUSH RESULT IS PART OF THE ANSWER.
  --
  -- Sharing one pcall had two faults at once. A raising flush SKIPPED the close, leaking the
  -- handle until a power cycle; and the flush's failure was discarded, so Save reported success
  -- and set savedas to a file whose last rows never left the buffer. Both are reachable by
  -- pulling the key -- or filling it -- after the final row is written, which is the moment
  -- flush is the only thing that can still fail.
  local flushed = pcall(function() file.flush(fh) end)
  pcall(function() file.close(fh) end)      -- its OWN pcall, so a flush raise cannot skip it
  if not wrote then return false, 'write failed part-way through' end
  if not flushed then return false, 'flush failed -- the file may be truncated' end
  return true
end

-- One-line state summary for the panel, so logging can be seen to be happening
-- rather than assumed.
function ulog.status()
  if not ulog.enabled then return 'log off' end
  if not ulog.on then
    local why = ulog.lasterr
    if why == nil then why = 'not open' end
    return 'log: ' .. why
  end
  local extra = ''
  if ulog.dropped > 0 then extra = string.format(' (+%d dropped)', ulog.dropped) end
  -- File NAME only: the status row has ~45 proportional characters before the
  -- panel edge, and the directory is always /usb1/.
  local base = string.gsub(tostring(ulog.path), '^.*/', '')
  return string.format('log: %d ln %s%s', ulog.nlines, base, extra)
end

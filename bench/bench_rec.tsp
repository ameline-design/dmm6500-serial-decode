-- bench_rec.tsp -- the soak's record on the USB key, written to survive being killed mid-write.
--
-- THE POWER CYCLE IS THE STOP BUTTON. An indefinite soak has no clean shutdown: it ends whenever
-- someone cuts the power, at an instant nothing here chooses. So there is no end-of-run summary to
-- write, no in-memory tally to flush, and nothing that becomes readable only after a graceful exit.
-- Every fact a reader will want is committed as it is measured, and the last row is the only thing a
-- torn write can cost.
--
-- APPEND-ONLY, INCLUDING THE STATUS. The obvious design for progress is one small file rewritten each
-- cell -- and rewriting means truncating, so a cut at exactly the wrong instant leaves an EMPTY status
-- file and no idea how far the run got. Appending instead means a torn last line still has an intact
-- line above it, so the worst case is losing one cell's worth of knowledge rather than all of it.
--
-- ONE FILE, WITH TAGGED ROWS, and that is forced rather than tidy: the firmware hands out a SINGLE
-- write handle (tools/mock_display.lua enforces it, and 67 assertions in test_usblog.lua run against
-- that), so a results file and a status file cannot be open at the same time. Opening the second would
-- silently redirect the first's writes. So results are 'R,...' rows and progress is 'S,...' rows in one
-- append-only file, which also halves the file count on a FAT volume and puts the last status line
-- immediately before whatever the run was doing when it stopped -- the thing a post-mortem wants most.
--
-- CLOSED AND REOPENED PERIODICALLY, because flush and close are not the same promise on FAT: flush
-- pushes the bytes, close updates the directory entry that says how long the file is. A key pulled
-- with a long-open handle can hold data the directory does not admit to. Reopening every
-- brec.syncrows bounds that to a known number of rows. THIS IS THE ONE ASSUMPTION HERE THAT OFFLINE
-- TESTING CANNOT SETTLE -- it needs a real power cycle mid-run to confirm.
--
-- SIZE. The key is 8 GB with a 6 GB working budget and a 2 GB per-file ceiling. A cell row is ~600
-- bytes with its decoded bytes in hex, so a 1677-cell lap is ~1 MB and a week of laps is ~60 MB. The
-- caps below are therefore not expected to bind; they exist because "indefinite" plus one unexpectedly
-- verbose path is how a key fills, and a full key would silently stop recording a run that keeps going.

brec = brec or {}

brec.dir      = brec.dir or '/usb1/SERDEC'
-- FULL PATH, because ulog.next_free numbers whatever prefix it is handed and does not prepend a
-- directory -- serial_app.tsp builds sdec.flogpfx the same way. A bare 'SOAK' yields 'SOAK000.CSV',
-- which file.open refuses since the path must be absolute.
brec.pfx      = brec.pfx or (brec.dir .. '/SOAK')   -- SOAKnnn.CSV, 8.3 like everything else here
brec.ext      = brec.ext or '.csv'
brec.maxfile  = brec.maxfile or 268435456   -- 256 MB, far under the 2 GB per-file ceiling and still
                                            -- small enough to pull over the socket in one piece
brec.maxtotal = brec.maxtotal or 4294967296 -- 4 GB, inside the 6 GB budget with headroom
brec.syncrows = brec.syncrows or 50         -- rows between close/reopen

brec.fh       = nil     -- the one open file, or nil
brec.path     = nil
brec.nrow     = 0       -- rows in the current file
brec.ntotrow  = 0       -- rows this run
brec.nbyte    = 0       -- bytes in the current file
brec.ntotbyte = 0       -- bytes this run, across rolled files
brec.nfile    = 0
brec.sincesync = 0
brec.why      = nil     -- why recording stopped, if it did
brec.stopped  = false   -- true once the byte budget is spent; the run may continue, unrecorded,
                        -- but it must SAY it is unrecorded rather than look complete

-- SCHEMA VERSION IN THE HEADER, because these files will be read by a tool that did not exist when
-- they were written, possibly after this file has changed. A reader that cannot recognise the version
-- must refuse rather than mis-parse a column.
brec.schema = brec.schema or 'serdec-soak-1'

-- ---------------------------------------------------------------------------
-- One-line escape for a CSV field. Commas and quotes cannot reach a field here -- vector ids, formats
-- and hex are all plain -- but a note can carry anything, so it is escaped rather than trusted.
function brec.q(s)
  if s == nil then return '' end
  local t = tostring(s)
  t = string.gsub(t, '"', "''")
  t = string.gsub(t, '[\r\n,]', ' ')
  return t
end

-- Open a numbered file. Returns handle, path, or nil and a reason. ulog.next_free makes the directory
-- first and is the tested allocator -- a second one here would be a second thing to get wrong.
function brec.newfile(pfx)
  if ulog == nil or ulog.next_free == nil then
    return nil, nil, 'usb_log.tsp is not loaded, so there is no allocator and no directory'
  end
  local path = ulog.next_free(pfx, brec.ext, 999)
  if path == nil then
    return nil, nil, 'no free ' .. pfx .. 'NNN' .. brec.ext .. ' name on the key'
  end
  local fh = nil
  -- file.open RETURNS NIL rather than raising, and a pcall around it reports ok = true either way, so
  -- the handle is what has to be tested.
  pcall(function() fh = file.open(path, file.MODE_APPEND) end)
  if fh == nil then return nil, path, 'cannot open ' .. path end
  return fh, path, nil
end

function brec.rawwrite(fh, s)
  if fh == nil then return false end
  local ok = pcall(function() file.write(fh, s) end)
  if not ok then return false end
  pcall(function() file.flush(fh) end)
  return true
end

-- ---------------------------------------------------------------------------
-- Start recording. `tag` names the run in the header so two runs on one key are never confused.
function brec.begin(tag, iterations, planid)
  brec.why, brec.stopped = nil, false
  brec.nrow, brec.ntotrow, brec.nbyte, brec.ntotbyte, brec.nfile, brec.sincesync = 0, 0, 0, 0, 0, 0
  local fh, path, why = brec.newfile(brec.pfx)
  if fh == nil then brec.why = why; brec.stopped = true; return false, why end
  brec.fh, brec.path, brec.nfile = fh, path, 1
  brec.header(tag, iterations, planid)
  return true
end

function brec.header(tag, iterations, planid)
  brec.rawwrite(brec.fh, string.format('# %s tag=%s iterations=%s plan=%s file=%d\n',
                                       brec.schema, brec.q(tag), tostring(iterations or 'forever'),
                                       brec.q(planid), brec.nfile))
  -- THE COLUMN NAMES, IN THE FILE, for both row kinds. A reader told the schema out of band is a
  -- reader that will one day be told the wrong one.
  brec.rawwrite(brec.fh,
    '# R,iter,cell,vid,baud,kind,amp_vpp,ofst_v,srate,wait_ms,fs,sa_bit,'
    .. 'ran,read_baud,fmt,nf,ngood,nbad,nflag,headsusp,snapped,snapfirm,why,hex\n')
  brec.rawwrite(brec.fh, '# S,stamp_s,iter,cell,ncell,nrow,nbad,nsdgfail,note\n')
end

-- ROLL rather than grow past the per-file cap, and count the total so an indefinite run cannot fill
-- the key behind everyone's back.
function brec.roll()
  if brec.fh ~= nil then pcall(function() file.close(brec.fh) end) end
  brec.fh = nil
  if brec.ntotbyte >= brec.maxtotal then
    brec.stopped = true
    brec.why = string.format('byte budget spent: %d bytes over %d file(s)', brec.ntotbyte, brec.nfile)
    brec.note(-1, -1, 0, brec.why)
    return false
  end
  local fh, path, why = brec.newfile(brec.pfx)
  if fh == nil then
    brec.stopped = true
    brec.why = 'cannot roll to a new file: ' .. tostring(why)
    brec.note(-1, -1, 0, brec.why)
    return false
  end
  brec.fh, brec.path = fh, path
  brec.nfile = brec.nfile + 1
  brec.nrow, brec.nbyte, brec.sincesync = 0, 0, 0
  brec.header('roll', nil, nil)
  return true
end

-- Append one row. Returns false once recording has stopped, so a caller can report that its cells are
-- no longer being written down instead of carrying on as if they were.
function brec.row(s)
  if brec.stopped then return false end
  if brec.fh == nil then return false end
  local line = 'R,' .. s .. '\n'
  if not brec.rawwrite(brec.fh, line) then
    -- A WRITE THAT FAILED is usually a pulled key. Reopening once is worth trying; failing that, the
    -- run says so rather than discarding rows silently.
    pcall(function() file.close(brec.fh) end)
    brec.fh = nil
    local fh = nil
    pcall(function() fh = file.open(brec.path, file.MODE_APPEND) end)
    if fh == nil then
      brec.stopped = true
      brec.why = 'write failed and ' .. tostring(brec.path) .. ' will not reopen -- key pulled?'
      return false
    end
    brec.fh = fh
    if not brec.rawwrite(brec.fh, line) then
      brec.stopped = true
      brec.why = 'write failed twice on ' .. tostring(brec.path)
      return false
    end
  end
  brec.nrow = brec.nrow + 1
  brec.ntotrow = brec.ntotrow + 1
  brec.nbyte = brec.nbyte + string.len(line)
  brec.ntotbyte = brec.ntotbyte + string.len(line)
  brec.sincesync = brec.sincesync + 1
  -- THE DIRECTORY ENTRY, COMMITTED. See the note at the top: flush is not close.
  if brec.sincesync >= brec.syncrows then
    pcall(function() file.close(brec.fh) end)
    brec.fh = nil
    local fh = nil
    pcall(function() fh = file.open(brec.path, file.MODE_APPEND) end)
    if fh == nil then
      brec.stopped = true
      brec.why = 'reopen after sync failed on ' .. tostring(brec.path)
      return false
    end
    brec.fh = fh
    brec.sincesync = 0
  end
  if brec.nbyte >= brec.maxfile then return brec.roll() end
  return true
end

-- One progress line. Cheap and frequent: this is what a reader looks at first, and what says how far
-- an interrupted run got.
function brec.note(iter, cell, ncell, note, nbad, nsdgfail)
  if brec.fh == nil then return end
  -- os.time() IS THE ONLY CLOCK A RESTARTED INSTRUMENT AGREES WITH ITSELF ABOUT, and it is recorded
  -- as seconds rather than formatted, so a reader can subtract two of them without parsing.
  local t = 0
  pcall(function() t = os.time() end)
  brec.rawwrite(brec.fh, string.format('S,%d,%d,%d,%d,%d,%d,%d,%s\n',
                                       t, iter or -1, cell or -1, ncell or 0,
                                       brec.ntotrow, nbad or 0, nsdgfail or 0, brec.q(note)))
end

function brec.finish(note)
  brec.note(-1, -1, 0, note or 'finished')
  if brec.fh ~= nil then pcall(function() file.close(brec.fh) end) end
  brec.fh = nil
end

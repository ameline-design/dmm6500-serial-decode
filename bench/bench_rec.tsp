-- bench_rec.tsp -- the soak's record on the USB key, written to survive being killed mid-write.
--
-- THE POWER CYCLE IS THE STOP BUTTON. An indefinite soak has no clean shutdown: it ends whenever
-- someone cuts the power, at an instant nothing here chooses. So there is no end-of-run summary to
-- write and no in-memory tally to flush -- every fact a reader will want is committed as it is
-- measured. What a cut costs is the row in flight plus whatever the directory entry has not yet
-- admitted to, which brec.syncrows bounds.
--
-- APPEND-ONLY, INCLUDING THE STATUS. Rewriting one small progress file per cell means truncating it,
-- so a cut at the wrong instant leaves an EMPTY file and no idea how far the run got. Appending leaves
-- a torn last line with an intact line above it.
--
-- ONE FILE, WITH TAGGED ROWS, and that is forced rather than tidy: the firmware hands out a SINGLE
-- write handle, so a results file and a status file cannot be open at once -- opening the second
-- silently redirects the first's writes. tools/mock_display.lua models that one handle and 67
-- assertions in test_usblog.lua run against it. Results are 'R,...' rows and progress is 'S,...' rows in
-- one file, which also puts the last status line immediately before whatever the run was doing when it
-- stopped.
--
-- CLOSED AND REOPENED PERIODICALLY, because flush and close are not the same promise on FAT: flush
-- pushes the bytes, close updates the directory entry that says how long the file is. A key pulled
-- with a long-open handle holds data the directory does not admit to. THIS IS THE ONE ASSUMPTION HERE
-- THAT OFFLINE TESTING CANNOT SETTLE -- it needs a real power cycle mid-run to confirm.
--
-- SIZE. The key is 8 GB with a 6 GB working budget and a 2 GB per-file ceiling. A cell row is ~600
-- bytes with its decoded bytes in hex, so a 1677-cell lap is ~1 MB and a week of laps is ~60 MB. The
-- caps below are not expected to bind; they exist because a full key would silently stop recording a
-- run that keeps going.

brec = brec or {}

brec.dir      = brec.dir or '/usb1/SERDEC'
-- FULL PATH, because file.open on this instrument requires an absolute one -- a bare 'SOAK.CSV' is
-- refused. serial_app.tsp builds sdec.flogpfx the same way.
brec.pfx      = brec.pfx or (brec.dir .. '/SOAK')   -- SOAK.CSV, 8.3 like everything else here
brec.ext      = brec.ext or '.csv'
brec.maxfile  = brec.maxfile or 268435456   -- 256 MB, far under the 2 GB per-file ceiling and still
                                            -- small enough to pull over the socket in one piece
brec.maxtotal = brec.maxtotal or 4294967296 -- 4 GB, inside the 6 GB budget with headroom
-- FIFTY ROWS, ABOUT FOUR MINUTES. Every cell is written and flushed as it completes, so the bytes reach
-- the key at once -- but on FAT the DIRECTORY ENTRY only learns the file's length when the handle is
-- CLOSED. So this is how much a machine that stops without warning leaves behind: fifty cells of bytes
-- no reader will see, because the directory says the file ends before them.
--
-- WHY NOT ONE. brun.resume finds the last row the record HOLDS and carries on after it, so an
-- uncommitted tail costs those cells being MEASURED AGAIN, not lost -- against a FAT directory write on
-- every one of the ~230 000 cells a fortnight completes, at a latency this key has never been measured
-- for.
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

-- ONE FIXED NAME, OPENED FOR APPEND, AND NOT A NUMBERED SLOT. ulog.next_free finds a free number by
-- OPENING CANDIDATES, and an open on a name that is not there posts event 2205 -- a box on the panel.
-- One per run is one too many for a machine that sits unattended for days. MODE_APPEND on a fixed path
-- always succeeds, creating the file if it is absent, so nothing is ever probed.
--
-- RUNS ARE SEPARATED BY THEIR HEADER, not by their filename: every run writes a '# serdec-soak-1 tag=..'
-- line first and a reader splits the file on those. brec.roll numbers ROLLED files, which happens only
-- when one run passes brec.maxfile, and the roll opens for append too.
function brec.newfile(pfx)
  if ulog ~= nil and ulog.ensuredir ~= nil then
    -- The directory, made once. ensuredir looks in the FAT listing before ordering a mkdir precisely so
    -- a speculative one is never issued -- see its own note on why that matters.
    pcall(function() ulog.ensuredir(brec.dir) end)
  end
  local path = pfx .. brec.ext
  if brec.nfile > 1 then path = pfx .. tostring(brec.nfile) .. brec.ext end
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

-- HEADER BYTES COUNT TOWARDS THE BUDGETS. A header is ~250 bytes and three paths write one; brec.reopen
-- writes another on every recovery, so a key that fails and recovers repeatedly would pass maxfile and
-- maxtotal while both counters said otherwise. -> the bytes written, so callers can add them.
function brec.hwrite(s)
  if not brec.rawwrite(brec.fh, s) then return 0 end
  brec.nbyte = brec.nbyte + string.len(s)
  brec.ntotbyte = brec.ntotbyte + string.len(s)
  return string.len(s)
end

function brec.header(tag, iterations, planid)
  -- THE PLAN VARIANT IN THE HEADER, because a lap is reproducible from its iteration number ONLY
  -- against the plan it was run from. random-per-lap changes the skip, the skip is applied before the
  -- shuffle, and the shuffle keys every cell's amplitude, offset and wait -- so lap 7 of a four-random
  -- plan and lap 7 of a full one are different stimulus with the same number. Recorded rather than
  -- remembered.
  local rsub = 'all'
  if brun ~= nil and brun.planrsub ~= nil then rsub = tostring(brun.planrsub) end
  local n = brec.hwrite(string.format('# %s tag=%s iterations=%s plan=%s randomperlap=%s file=%d\n',
                                     brec.schema, brec.q(tag), tostring(iterations or 'forever'),
                                     brec.q(planid), brec.q(rsub), brec.nfile))
  -- THE COLUMN NAMES, IN THE FILE, for both row kinds. A reader told the schema out of band is a
  -- reader that will one day be told the wrong one.
  n = n + brec.hwrite(
    '# R,iter,cell,vid,baud,kind,amp_vpp,ofst_v,srate,wait_ms,fs,sa_bit,'
    .. 'ran,read_baud,fmt,nf,ngood,nbad,nflag,headsusp,snapped,snapfirm,why,hex\n')
  n = n + brec.hwrite('# S,stamp_s,iter,cell,ncell,nrow,nbad,nsdgfail,note\n')
  return n > 0
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

-- Try to record again after recording stopped. -> true if the record is live again.
--
-- BECAUSE A FAULT MUST NOT END A RUN. The run keeps measuring until somebody stops it, so this is the
-- retry that lets a transient failure -- a briefly unreadable key, a write that failed once -- heal
-- instead of costing the rest of a fortnight.
--
-- THE BYTE BUDGET IS NOT RETRIED, which is why this lives here rather than as a file.open in the loop: a
-- spent budget is still spent in five minutes. brec.stopped stays true and the run says so.
--
-- A HEADER MARKS THE GAP, tagged `resumed`, which judge_bench's split_runs reads as a continuation --
-- otherwise the rows either side look like one unbroken run.
function brec.reopen()
  if brec.ntotbyte >= brec.maxtotal then return false end
  if brec.fh ~= nil and not brec.stopped then return true end
  if brec.fh ~= nil then pcall(function() file.close(brec.fh) end) end
  brec.fh = nil
  local fh, path = brec.newfile(brec.pfx)
  if fh == nil then return false end
  brec.fh, brec.path = fh, path
  brec.sincesync = 0
  -- THE HEADER HAS TO LAND BEFORE THIS IS CALLED RECOVERED, or a still-failing key reports 'recording
  -- resumed' and counts a recovery it did not make.
  if not brec.header('resumed', nil, nil) then
    pcall(function() file.close(brec.fh) end)
    brec.fh = nil
    return false
  end
  brec.stopped, brec.why = false, nil
  return true
end

-- One progress line. Cheap and frequent: this is what a reader looks at first, and what says how far
-- an interrupted run got.
function brec.note(iter, cell, ncell, note, nbad, nsdgfail)
  if brec.fh == nil then return end
  -- THE LAP NUMBER IS NEVER OMITTED. Several callers pass -1 because they are not inside a cell -- a
  -- rolled file, a disabled progress push, the closing line -- and a status row whose lap column says -1
  -- cannot be placed in a run that is 200 laps long. Where the run knows which lap it is on, that is
  -- what gets written; -1 survives only before the first row has been read, where it is the truth.
  if brun ~= nil then
    if iter == nil or iter == -1 then iter = brun.iter end
    if cell == nil or cell == -1 then cell = brun.cell end
  end
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

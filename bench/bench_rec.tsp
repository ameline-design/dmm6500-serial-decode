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
-- FULL PATH, because file.open on this instrument requires an absolute one -- a bare 'SOAK.CSV' is
-- refused. serial_app.tsp builds sdec.flogpfx the same way.
brec.pfx      = brec.pfx or (brec.dir .. '/SOAK')   -- SOAK.CSV, 8.3 like everything else here
brec.ext      = brec.ext or '.csv'
brec.maxfile  = brec.maxfile or 268435456   -- 256 MB, far under the 2 GB per-file ceiling and still
                                            -- small enough to pull over the socket in one piece
brec.maxtotal = brec.maxtotal or 4294967296 -- 4 GB, inside the 6 GB budget with headroom
-- FIFTY ROWS, WHICH IS ABOUT FOUR MINUTES, AND THAT IS DELIBERATE RATHER THAN LEFTOVER. Every cell is
-- written and flushed as it completes, so the bytes reach the key almost immediately -- but on FAT the
-- DIRECTORY ENTRY only learns the file's new length when the handle is CLOSED. Flush pushes bytes; close
-- updates the size field a reader trusts. So this number is how much a machine that stops without warning
-- can leave behind: fifty cells of bytes no reader will see, because the directory says the file ends
-- before them.
--
-- WHY NOT ONE. Because brun.resume exists: a restarted run finds the last row the record HOLDS and
-- carries on after it, so an unwritten tail costs those cells being MEASURED AGAIN, not lost. Set against
-- that, closing per row adds a FAT directory write to every one of a fortnight's 280 000 cells, and the
-- latency of one on this key has never been measured -- an unmeasured cost on every cell, to avoid
-- repeating four minutes of work that the resume repeats anyway.
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

-- ONE FIXED NAME, OPENED FOR APPEND, AND NOT A NUMBERED SLOT. ulog.next_free is the tested allocator
-- and it works, but it finds a free number by OPENING CANDIDATES -- and an open on a name that is not
-- there posts event 2205 on this instrument, which is a box on the panel. One per run is one too many
-- for a machine that has to sit unattended for days: the requirement is that nothing is instigated at
-- all, not that it is rare. MODE_APPEND on a fixed path always succeeds, creating the file if it is
-- absent, so nothing is ever probed.
--
-- RUNS ARE SEPARATED BY THEIR HEADER, not by their filename. Every run writes a '# serdec-soak-1 tag=..'
-- line first, so a reader splits the file on those; and one file per key is kinder to a FAT volume than
-- a new directory entry per run. brec.roll still numbers ROLLED files, which only happens when a single
-- run passes brec.maxfile -- rare, and the roll opens for append too.
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

function brec.header(tag, iterations, planid)
  -- THE PLAN VARIANT IN THE HEADER, because a lap is reproducible from its iteration number ONLY
  -- against the plan it was run from. random-per-lap changes the skip, the skip is applied before the
  -- shuffle, and the shuffle keys every cell's amplitude, offset and wait -- so lap 7 of a four-random
  -- plan and lap 7 of a full one are different stimulus with the same number. Recorded rather than
  -- remembered.
  local rsub = 'all'
  if brun ~= nil and brun.planrsub ~= nil then rsub = tostring(brun.planrsub) end
  brec.rawwrite(brec.fh, string.format('# %s tag=%s iterations=%s plan=%s randomperlap=%s file=%d\n',
                                       brec.schema, brec.q(tag), tostring(iterations or 'forever'),
                                       brec.q(planid), brec.q(rsub), brec.nfile))
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

-- Try to record again after recording stopped. -> true if the record is live again.
--
-- BECAUSE A FAULT MUST NOT END A RUN. brec.stopped means rows are being thrown away, which is bad enough
-- to paint the screen red -- but the run keeps measuring until somebody stops it, so this is the retry
-- that lets a transient failure heal instead of costing the rest of a fortnight. The failures worth
-- retrying are the ones that are really about the volume rather than the budget: a key that was briefly
-- unreadable, a write that failed once, a reopen that lost a race.
--
-- THE BYTE BUDGET IS NOT RETRIED, and that is why this lives here rather than as a file.open in the loop:
-- a spent budget will still be spent in five minutes, so retrying it would be a red line that never
-- changes and a key filled to its ceiling anyway. brec.stopped stays true and the run says so.
--
-- A HEADER MARKS THE GAP. Rows that stop and resume with nothing between them read as one unbroken run,
-- so the resumed stretch declares itself -- tag=resumed, which judge_bench.py's split_runs treats as a
-- continuation of the run above it rather than as a new run whose counts get judged on their own.
function brec.reopen()
  if brec.ntotbyte >= brec.maxtotal then return false end
  if brec.fh ~= nil and not brec.stopped then return true end
  if brec.fh ~= nil then pcall(function() file.close(brec.fh) end) end
  brec.fh = nil
  local fh, path = brec.newfile(brec.pfx)
  if fh == nil then return false end
  brec.fh, brec.path = fh, path
  brec.stopped, brec.why = false, nil
  brec.sincesync = 0
  brec.header('resumed', nil, nil)
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

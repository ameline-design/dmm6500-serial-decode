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
-- One file, with tagged rows. The original reason was the firmware's file.* API, which handed out a
-- single write handle: a results file and a status file could not be open at once, because opening
-- the second silently redirected the first's writes. That limit does not survive the move to io --
-- measured 2026-10-24, two handles open together each kept their own bytes, 0 events -- so the one
-- file is now a choice rather than a constraint, and what carries it is that the last status line
-- lands immediately before whatever the run was doing when it stopped. Results are 'R,...' rows and
-- progress is 'S,...' rows.
--
-- The app does hold two write handles at once, so do not read the above as a claim that it cannot:
-- ulog.fh is held open across captures and one logged error in a soak cell leaves it live alongside
-- brec.fh for the rest of the run.
--
-- Closed and reopened periodically, because flush and close are not the same promise on this
-- filesystem: flush pushes the bytes, close updates the directory entry that says how long the file
-- is. A key pulled with a long-open handle holds data the directory does not admit to. This is the
-- one assumption here that offline testing cannot settle -- it needs a real power cycle mid-run.
--
-- Size. The key is 8 GB with a 6 GB working budget and a 2 GB per-file ceiling. A cell row is ~600
-- bytes with its decoded bytes in hex, so a 1677-cell lap is ~1 MB and a week of laps is ~60 MB. The
-- caps below are not expected to bind; they exist because a full key would silently stop recording a
-- run that keeps going.

brec           = brec or {}

brec.dir       = brec.dir or '/usb1/SERDEC'
-- FULL PATH, because this instrument's filesystem calls require an absolute one -- a bare 'SOAK.CSV'
-- is refused, and every io.open measured on the box was given an absolute path too.
-- serial_app.tsp builds sdec.flogpfx the same way.
brec.pfx       = brec.pfx or (brec.dir .. '/SOAK')   -- SOAK.CSV, 8.3 like everything else here
brec.ext       = brec.ext or '.csv'
brec.maxfile   = brec.maxfile or 268435456   -- 256 MB, far under the 2 GB per-file ceiling and still
                                            -- small enough to pull over the socket in one piece
brec.maxtotal  = brec.maxtotal or 4294967296 -- 4 GB, inside the 6 GB budget with headroom
-- FIFTY ROWS, ABOUT FOUR MINUTES. Every cell is written and flushed as it completes, so the bytes reach
-- the key at once -- but on FAT the DIRECTORY ENTRY only learns the file's length when the handle is
-- CLOSED. So this is how much a machine that stops without warning leaves behind: fifty cells of bytes
-- no reader will see, because the directory says the file ends before them.
--
-- WHY NOT ONE. brun.resume finds the last row the record HOLDS and carries on after it, so an
-- uncommitted tail costs those cells being MEASURED AGAIN, not lost -- against a FAT directory write on
-- every one of the ~230 000 cells a fortnight completes, at a latency this key has never been measured
-- for.
brec.syncrows  = brec.syncrows or 50         -- rows between close/reopen

brec.fh        = nil     -- the one open file, or nil
brec.path      = nil
brec.nrow      = 0       -- rows in the current file
brec.ntotrow   = 0       -- rows this run
brec.nbyte     = 0       -- bytes in the current file
brec.ntotbyte  = 0       -- bytes this run, across rolled files
brec.nfile     = 0
brec.sincesync = 0
brec.why       = nil     -- why recording stopped, if it did
brec.stopped  = false   -- true once the byte budget is spent; the run may continue, unrecorded,
                        -- but it must say it is unrecorded rather than look complete
brec.rollfail = false   -- true once a roll was refused, which stops brec.reopen recovering onto a
                        -- file that is over maxfile and cannot be rolled

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
  t       = string.gsub(t, '"', "''")
  t       = string.gsub(t, '[\r\n,]', ' ')
  return t
end

-- ONE FIXED NAME, OPENED FOR APPEND, AND NOT A NUMBERED SLOT. ulog.next_free finds a free number by
-- OPENING CANDIDATES, and an open on a name that is not there posts an event -- 2205 through file.open,
-- 2203 through io.open, a box on the panel either way. One per run is one too many for a machine that
-- sits unattended for days. Mode 'a' on a fixed path always succeeds, creating the file if it is
-- absent, so nothing is ever probed.
--
-- RUNS ARE SEPARATED BY THEIR HEADER, not by their filename: every run writes a '# serdec-soak-1 tag=..'
-- line first and a reader splits the file on those. brec.roll numbers ROLLED files, which happens only
-- when one run passes brec.maxfile, and the roll opens for append too.
function brec.newfile(pfx)
  if ulog ~= nil and ulog.ensuredir ~= nil then
    -- The directory, made once. ensuredir looks in the FAT listing before ordering a mkdir precisely so
    -- a speculative one is never issued -- see its own note on why that matters.
    ulog.ensuredir(brec.dir)
  end
  local path = pfx .. brec.ext
  if brec.nfile > 1 then path = pfx .. tostring(brec.nfile) .. brec.ext end
  local fh, oerr = nil, nil
  -- io.open RETURNS NIL AND A MESSAGE rather than raising, so the HANDLE is what has to be tested and
  -- there is nothing for a guard to catch. Measured on the instrument 2026-10-24: a missing path
  -- answers nil plus '<path>: No such file'. Every pcall site costs part of a shipping budget the
  -- firmware enforces by bluescreening on load, so an inert one is not free.
  --
  -- THE MESSAGE IS KEPT, which it was not worth doing under file.open: that call posted an event the
  -- operator could read off the panel, and io posts none for most failures. So the string this returns
  -- is now the only account of why the record would not open.
  fh, oerr = io.open(path, 'a')
  if fh == nil then return nil, path, 'cannot open ' .. path .. ': ' .. tostring(oerr) end
  return fh, path, nil
end

-- A write is not where a pulled key is caught. Measured 2026-10-24, key pulled mid-capture with the
-- handle held: an io write to a dead-key handle neither raises nor posts -- pcall says ok, the event
-- log stays at 0 over twelve writes, a flush and a close, and the data goes nowhere. file.write
-- posted 2200 per write here, which was the popup storm.
--
-- What does catch it is the reopen at the sync boundary in brec.row: the record closes and reopens
-- every `syncrows` rows to commit the directory entry, and that open returning nil is a real verdict.
--
-- So the `fh == nil` test is not a key check and never fires here -- every caller has already
-- excluded a nil handle, leaving the false return and the recovery paths behind it unreachable. It
-- stays because this is where a future failure signal would land. brec has no per-row keyok() gate;
-- usb_log and chunk_decode do, and that is what notices a key going in those modules.
--
-- Unguarded by design, and io does not raise here -- now measured rather than assumed.
function brec.rawwrite(fh, s)
  if fh == nil then return false end
  fh:write(s)
  fh:flush()
  return true
end

-- ---------------------------------------------------------------------------
-- Start recording. `tag` names the run in the header so two runs on one key are never confused.
function brec.begin(tag, iterations, planid)
  brec.why, brec.stopped, brec.rollfail = nil, false, false
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
  brec.nbyte    = brec.nbyte + string.len(s)
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
-- The old handle stays open until the new file is known to be there, so both failure paths below have
-- somewhere to write their note. Closing first discarded it -- brec.note returns early on a nil
-- handle -- leaving an ordinary R row as the record's last line, indistinguishable from a power cut.
-- Overlapping two write handles is honest under io, measured 2026-10-24.
function brec.roll()
  local old = brec.fh
  if brec.ntotbyte >= brec.maxtotal then
    brec.stopped = true
    brec.why     = string.format('byte budget spent: %d bytes over %d file(s)', brec.ntotbyte, brec.nfile)
    brec.note(-1, -1, 0, brec.why)
    if old ~= nil then old:close() end
    brec.fh = nil
    return false
  end
  -- THE COUNT GOES UP BEFORE newfile, NOT AFTER, because newfile builds the name FROM it: it numbers
  -- only when brec.nfile > 1, and brec.open leaves it at 1. Incrementing afterwards meant the FIRST
  -- roll asked for a name while the count still said 1, got SOAK.csv back, reopened the file it was
  -- supposed to be leaving for append, reset nbyte to 0 and wrote a 'tag=roll ... file=2' header into
  -- the MIDDLE of it. SOAK2.csv appeared only on the second roll, the first file grew to about twice
  -- maxfile, and judge_bench's split_runs saw a roll header mid-file.
  brec.nfile = brec.nfile + 1
  local fh, path, why = brec.newfile(brec.pfx)
  if fh == nil then
    -- Back down: brec.nfile counts files actually opened, and the byte-budget message reports it.
    brec.nfile    = brec.nfile - 1
    brec.stopped  = true
    brec.rollfail = true
    brec.why      = 'cannot roll to a new file: ' .. tostring(why)
    -- Into the old file, which is still open for exactly this.
    brec.note(-1, -1, 0, brec.why)
    if old ~= nil then old:close() end
    brec.fh = nil
    return false
  end
  if old ~= nil then old:close() end
  brec.rollfail      = false
  brec.fh, brec.path = fh, path
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
    brec.fh:close()
    brec.fh  = nil
    local fh = nil
    fh = io.open(brec.path, 'a')
    if fh == nil then
      brec.stopped = true
      brec.why     = 'write failed and ' .. tostring(brec.path) .. ' will not reopen -- key pulled?'
      return false
    end
    brec.fh = fh
    if not brec.rawwrite(brec.fh, line) then
      brec.stopped = true
      brec.why     = 'write failed twice on ' .. tostring(brec.path)
      return false
    end
  end
  brec.nrow      = brec.nrow + 1
  brec.ntotrow   = brec.ntotrow + 1
  brec.nbyte     = brec.nbyte + string.len(line)
  brec.ntotbyte  = brec.ntotbyte + string.len(line)
  brec.sincesync = brec.sincesync + 1
  -- THE DIRECTORY ENTRY, COMMITTED. See the note at the top: flush is not close.
  if brec.sincesync >= brec.syncrows then
    brec.fh:close()
    brec.fh  = nil
    local fh = nil
    fh = io.open(brec.path, 'a')
    if fh == nil then
      brec.stopped = true
      brec.why     = 'reopen after sync failed on ' .. tostring(brec.path)
      return false
    end
    brec.fh        = fh
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
-- THE BYTE BUDGET IS NOT RETRIED, which is why this lives here rather than as an io.open in the loop: a
-- spent budget is still spent in five minutes. brec.stopped stays true and the run says so.
--
-- A HEADER MARKS THE GAP, tagged `resumed`, which judge_bench's split_runs reads as a continuation --
-- otherwise the rows either side look like one unbroken run.
function brec.reopen()
  if brec.ntotbyte >= brec.maxtotal then return false end
  if brec.fh ~= nil and not brec.stopped then return true end
  if brec.fh ~= nil then brec.fh:close() end
  brec.fh = nil
  local fh, path = brec.newfile(brec.pfx)
  if fh == nil then return false end
  brec.fh, brec.path = fh, path
  -- The file's real length, not a counter that survived the failure. seek('end') on an append handle
  -- is the length, measured 2026-10-24.
  local n = fh:seek('end')
  if n ~= nil then brec.nbyte = n end
  -- A roll already refused will be refused again -- the failing open is a create on a full key or
  -- directory. Recovering would append past maxfile and add one 'resumed' header per recovery, which
  -- split_runs reads as a legitimate continuation: measured offline at 3.8x the cap with three.
  if brec.rollfail and brec.nbyte >= brec.maxfile then
    brec.fh:close()
    brec.fh = nil
    return false
  end
  brec.sincesync = 0
  -- The header has to land before this is called recovered, or a still-failing key reports
  -- 'recording resumed' and counts a recovery it did not make.
  if not brec.header('resumed', nil, nil) then
    brec.fh:close()
    brec.fh = nil
    return false
  end
  brec.stopped, brec.why = false, nil
  -- Already over the cap, so roll now rather than at the next row: that way the header just written
  -- closes the old file instead of being the first of a run of them.
  if brec.nbyte >= brec.maxfile then return brec.roll() end
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
  t = os.time()
  brec.rawwrite(brec.fh, string.format('S,%d,%d,%d,%d,%d,%d,%d,%s\n',
                                       t, iter or -1, cell or -1, ncell or 0,
                                       brec.ntotrow, nbad or 0, nsdgfail or 0, brec.q(note)))
end

function brec.finish(note)
  brec.note(-1, -1, 0, note or 'finished')
  if brec.fh ~= nil then brec.fh:close() end
  brec.fh = nil
end

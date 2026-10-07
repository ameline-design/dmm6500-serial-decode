-- Report 4, part b: does a key that is PRESENT AND REFUSING fail the same way as a pulled one?
--
-- DMM6500, firmware 1.7.17a. Nothing need be connected to the inputs.
--
-- WHY THIS IS A SEPARATE SCRIPT. Report 4 measured ONE failure mode -- the key physically removed --
-- and the whole table it produced is about a STALE handle on ABSENT media. Every later decision that
-- cites "the firmware posts an event and returns rather than raising" rests on that one case, and
-- generalising it to a key that is still mounted and simply will not take the write is exactly the
-- step that is unjustified. A full key differs in the one way that matters to an application:
--
--     file.usbdriveexists() answers 1, because the key IS there.
--
-- That is the quiet gate every path in this application uses to decide whether to write at all. On a
-- pulled key it answers 0 and the app stops cleanly. On a full key it answers 1, so the gate passes
-- and the write is attempted -- and nothing here is known about what happens next.
--
-- SETUP, ON THE MAC, NOT ON THE INSTRUMENT. Filling a 32 GB key through TSP would take hours, so
-- leave the margin from the host and let this script close it:
--
--     diskutil list                          # find the key, e.g. /dev/disk4s1
--     df -m /Volumes/<KEY>                   # note the free megabytes
--     mkfile -n 0 /Volumes/<KEY>/FILLER.BIN  # sparse placeholder, resized next
--     dd if=/dev/zero of=/Volumes/<KEY>/FILLER.BIN bs=1m count=<free - 2>
--     df -m /Volumes/<KEY>                   # confirm ~2 MB free, then eject and insert
--
-- 2 MB of margin rather than 0 so the OPEN still succeeds and the refusal lands on a WRITE, which is
-- the call the application cannot see failing. With 0 free, a refusal on the open would be the
-- already-understood case and would tell us nothing new.
--
-- PART 2 NEEDS A KEY WITH A PHYSICAL LOCK SWITCH and is skipped silently if the write path opens.
--
-- WATCH THE PANEL. A pop-up is a posted event, and a posted event is the thing pcall cannot reach --
-- so the panel is half the result and the printed table is the other half.

local P = '/usb1/REP04B.TXT'
local CHUNK = 16384                 -- 16 kB a call; 8.3 name, absolute path
local MAXCALL = 512                 -- hard cap: 8 MB, so a wrong margin cannot run for ever

local function show(s)
  print(s)
end

-- One call, with everything the firmware can tell us about it: the pcall verdict, the returned
-- error, and every event the call posted. The event log is drained per call so a code cannot be
-- attributed to the wrong one.
local function try(what, f)
  local ok, err = pcall(f)
  local n = eventlog.getcount()
  local codes = ''
  local i
  for i = 1, n do
    local c, m = eventlog.next()
    codes = codes .. ' ' .. tostring(c) .. ' "' .. tostring(m) .. '"'
  end
  if codes == '' then codes = ' (none)' end
  show(string.format('%-28s pcall ok=%-5s err=%-6s events:%s',
                     what, tostring(ok), tostring(err), codes))
  return ok
end

eventlog.clear()
show('')
show('--- the key is PRESENT. This is the whole point of the script ---')
try('usbdriveexists', function() show('   -> ' .. tostring(file.usbdriveexists())) end)
try('fs.is_dir /usb1', function() show('   -> ' .. tostring(fs.is_dir('/usb1'))) end)

show('')
show('--- open for write on a nearly-full key ---')
local fh = nil
try('open for write', function() fh = file.open(P, file.MODE_WRITE) end)
show('   handle = ' .. tostring(fh))

if fh == nil then
  -- NOT A FAILED RUN. It is the margin being too small, and it is still a result: it says the open
  -- path reports a full key the same way it reports an absent one, by returning nil.
  show('')
  show('OPEN REFUSED on a present key -- re-make the filler 2 MB smaller to move the refusal onto')
  show('the WRITE, which is the call an application cannot see fail. Record this either way:')
  show('  open on a full key    returns NIL, like the absent case')
else
  -- THE FILL. One 16 kB write per call so the transition is attributable to a single call, with the
  -- verdict printed only around the transition -- 512 lines of "ok" is not a result, the first line
  -- that differs is.
  local pad = string.rep('F', CHUNK - 2) .. '\r\n'
  local i, nok, firstbad = 0, 0, nil
  show('')
  show('--- writing ' .. tostring(CHUNK) .. ' bytes a call until the key refuses ---')
  for i = 1, MAXCALL do
    eventlog.clear()
    local ok = pcall(file.write, fh, pad)
    local ne = eventlog.getcount()
    if ok and ne == 0 then
      nok = nok + 1
    else
      -- THE TRANSITION. Print this call and the two after it: the question is not only whether the
      -- first refusal is visible, but whether the SECOND one is -- a pulled key posts 2200 per call
      -- for ever, and an application that keeps writing papers the panel with dialogs.
      firstbad = i
      show(string.format('   first anomaly at call %d, after %d clean calls (%d bytes)',
                         i, nok, nok * CHUNK))
      local c, m = eventlog.next()
      show(string.format('   call %-4d pcall ok=%-5s events=%d first=%s "%s"',
                         i, tostring(ok), ne, tostring(c), tostring(m)))
      try('write again (n+1)', function() file.write(fh, pad) end)
      try('write again (n+2)', function() file.write(fh, pad) end)
      break
    end
  end
  if firstbad == nil then
    show(string.format('   %d calls, %d bytes, no anomaly -- the margin was larger than %d bytes',
                       MAXCALL, MAXCALL * CHUNK, MAXCALL * CHUNK))
  end

  -- THE THREE CALLS THE APPLICATION'S CLEANUP DEPENDS ON. ck_sink_file's finish() flushes and then
  -- closes, and a close that never happens strands the handle until a power cycle -- so a flush that
  -- RAISES here, rather than posting, is the one offline-mock behaviour that would be vindicated.
  show('')
  show('--- the cleanup path, on a key that has just refused ---')
  try('flush', function() file.flush(fh) end)
  try('close', function() file.close(fh) end)
  fh = nil
end

-- READ IS NOT IN REPORT 4's TABLE AT ALL, and usb_log.rootlists guards it. Measure it here rather
-- than keep guessing: a full key is still readable, so this should succeed, and a success is what
-- justifies dropping that guard.
show('')
show('--- read, which report 4 never measured in any state ---')
local rh = nil
try('open for read', function() rh = file.open(P, file.MODE_READ) end)
show('   handle = ' .. tostring(rh))
if rh ~= nil then
  try('read READ_LINE', function() show('   -> ' .. tostring(file.read(rh, file.READ_LINE))) end)
  try('close read handle', function() file.close(rh) end)
end

show('')
show('--- part 2: WRITE-PROTECTED, which needs a key with a lock switch ---')
show('Flip the switch, re-insert, and run this script again. The questions are the same three:')
show('  does usbdriveexists still answer 1')
show('  does the open return nil or a handle')
show('  does a write post, raise, or silently do nothing')

show('')
show('WHAT TO RECORD. Report 4 says, for a PULLED key:')
show('  usbdriveexists      0')
show('  write to handle     pcall ok=TRUE, err=nil, 2200 "File write error" PER CALL')
show('  flush / close       ok, no event')
show('  open                NIL, posts 2224')
show('The table above is the same four rows for a key that is present and refusing. Any row that')
show('differs breaks a decision made on report 4 alone. The application removed MOST of the pcalls')
show('on its file calls on the strength of "the firmware posts and returns"; the ones it kept exist')
show('only to keep a file.close reachable, since a stranded handle needs a power cycle. A RAISE in')
show('any row above is what those remaining guards are for -- and a post-and-return in every row is')
show('what would let them go too.')

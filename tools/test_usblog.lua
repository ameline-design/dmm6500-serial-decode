-- test_usblog.lua -- unit tests for tsp/usb_log.tsp's FILENAME ALLOCATOR, ulog.next_free(),
-- and for the file.read the mock needs in order to exercise it.
--
-- Separate from tools/test_serial.lua because the interesting states here are properties of the
-- KEY, not of a waveform: an index file left pointing at 999, an index holding junk, a key pulled
-- between open and read. None of them need the decoder, so none of it is loaded.
--
-- Run from the repo root:  lua tools/test_usblog.lua
--
-- EVERY TEST THAT SCANS IS CAPPED. next_free() could not terminate once the names ran out (the
-- retry re-read the index file, which still held the high number, so the scan restarted where it
-- had just failed -- and 5.0.2's proper tail calls turn that into an unbounded loop rather than a
-- stack overflow, which is why the front panel hung instead of erroring). A test for that must
-- fail, not hang, so ulog.exists is counted and raises past a cap.

dofile('tools/mock_display.lua')     -- hostile display + file mock

-- ---------- Lua 5.0.2 compatibility shims ----------
-- The instrument runs 5.0.2; host Lua is 5.4/5.5 and dropped these. Same two as
-- tools/gen_serial.lua, which this file deliberately does not load.
table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

do
  local chunk, err = loadfile('tsp/usb_log.tsp')
  if chunk == nil then print('LOAD FAILED tsp/usb_log.tsp: ' .. tostring(err)); os.exit(1) end
  chunk()
end

-- ---------- test harness ----------
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end
local function has(s, sub) return s ~= nil and string.find(s, sub, 1, true) ~= nil end

-- THE CAP. Counts probes and raises past `cap`, so a next_free() that cannot terminate produces a
-- failing test in milliseconds instead of a hung suite. Returns path, probes, err.
local REAL_EXISTS = ulog.exists
local function capped(prefix, ext, limit, cap)
  local probes = 0
  ulog.exists = function(p)
    probes = probes + 1
    if probes > cap then error('probe cap ' .. cap .. ' exceeded -- next_free is not terminating', 0) end
    return REAL_EXISTS(p)
  end
  local path = nil
  local ok, err = pcall(function() path = ulog.next_free(prefix, ext, limit) end)
  ulog.exists = REAL_EXISTS
  if not ok then return nil, probes, tostring(err) end
  return path, probes, nil
end

-- A key holding `n` capture files and an index file that names the last of them, which is the
-- state the app puts the key into by itself: next_free writes the index, then the caller creates
-- the file. Files are seeded from `first` so a run can leave low names free.
local function seed_key(prefix, first, last, idx)
  MD.forget_files()
  local i
  for i = first, last do
    MD.seed_file(string.format('%s%03d.txt', prefix, i), '')
  end
  if idx ~= nil then MD.seed_file(prefix .. 'idx.txt', idx) end
end

print('---- file.read, the branch the mock never had ----')

MD.forget_files()
MD.seed_file('/usb1/two.txt', 'first\nsecond\n')
local fh = file.open('/usb1/two.txt', file.MODE_READ)
check('MODE_READ on a seeded file gives a handle', fh ~= nil, tostring(fh))
check('READ_LINE returns the first line, without its terminator',
      file.read(fh, file.READ_LINE) == 'first')
check('and then the second', file.read(fh, file.READ_LINE) == 'second')
check('and NIL at end of file, as the reference manual specifies (14-256)',
      file.read(fh, file.READ_LINE) == nil)
file.close(fh)
check('a closed read handle dangles rather than reading on',
      pcall(function() file.read(fh, file.READ_LINE) end) == false)

MD.seed_file('/usb1/empty.txt', '')
local eh = file.open('/usb1/empty.txt', file.MODE_READ)
check('an empty file is at end of file immediately', file.read(eh, file.READ_LINE) == nil)
file.close(eh)

MD.seed_file('/usb1/crlf.txt', '12\r\n34\r\n')
local ch = file.open('/usb1/crlf.txt', file.MODE_READ)
check('a CRLF file reads the same as an LF one -- ulog writes \\r\\n elsewhere',
      file.read(ch, file.READ_LINE) == '12')
file.close(ch)

MD.seed_file('/usb1/notail.txt', '77')
local nh = file.open('/usb1/notail.txt', file.MODE_READ)
check('a last line with no terminator still reads', file.read(nh, file.READ_LINE) == '77')
check('and the position is then at end of file', file.read(nh, file.READ_LINE) == nil)
file.close(nh)

MD.seed_file('/usb1/all.txt', 'a\nb\n')
local ah = file.open('/usb1/all.txt', file.MODE_READ)
check('READ_ALL returns the rest of the file', file.read(ah, file.READ_ALL) == 'a\nb\n')
check('and nil once there is no rest', file.read(ah, file.READ_ALL) == nil)
file.close(ah)

MD.forget_files()
check('a write is READABLE back, so the index round-trips through the mock',
      (function()
         local wh = file.open('/usb1/rt.txt', file.MODE_WRITE)
         file.write(wh, '42\n')
         file.close(wh)
         local rh = file.open('/usb1/rt.txt', file.MODE_READ)
         local ln = file.read(rh, file.READ_LINE)
         file.close(rh)
         return ln
       end)() == '42')

check('MODE_READ on a file that does not exist is still NIL, not a handle',
      file.open('/usb1/nope.txt', file.MODE_READ) == nil)

print('---- ulog.next_free: the index is a starting point ----')

seed_key('/usb1/s_', 1, 0, '5')          -- no capture files, index says 5
local p, n = capped('/usb1/s_', '.txt', 1000, 2500)
check('the index file is actually READ -- allocation starts where it says, not at 0',
      p == '/usb1/s_005.txt', tostring(p) .. ' in ' .. n .. ' probes')
check('and that costs one probe for the index and one for the name',
      n <= 4, n .. ' probes')

seed_key('/usb1/s_', 5, 5, '5')          -- index says 5, and s_005 now exists
p, n = capped('/usb1/s_', '.txt', 1000, 2500)
check('a name the index points at but which EXISTS is skipped, not truncated',
      p == '/usb1/s_006.txt', tostring(p))

seed_key('/usb1/s_', 1, 0, '4\n9\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('only the FIRST line of the index is read', p == '/usb1/s_004.txt', tostring(p))

seed_key('/usb1/s_', 1, 0, 'banana\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('junk in the index falls back to 0 rather than raising', p == '/usb1/s_000.txt',
      tostring(p))

seed_key('/usb1/s_', 1, 0, '-4\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('a negative index is refused -- string.format %03d would emit -04', p == '/usb1/s_000.txt',
      tostring(p))

seed_key('/usb1/s_', 1, 0, '1500\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('an index beyond the limit is refused', p == '/usb1/s_000.txt', tostring(p))

seed_key('/usb1/s_', 1, 0, '3.7\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('a fractional index floors, so the name has three digits', p == '/usb1/s_003.txt',
      tostring(p))

seed_key('/usb1/s_', 1, 0, '')
p = capped('/usb1/s_', '.txt', 1000, 2500)
check('an EMPTY index file -- a key pulled mid-write -- falls back to 0',
      p == '/usb1/s_000.txt', tostring(p))

seed_key('/usb1/s_', 1, 0, '5\n')
MD.failread(0)
p, n = capped('/usb1/s_', '.txt', 1000, 2500)
MD.failread(nil)
check('a read that RAISES (key pulled between open and read) degrades to 0, does not propagate',
      p == '/usb1/s_000.txt', tostring(p))

seed_key('/usb1/s_', 1, 0, '5\n')
p = capped('/usb1/s_', '.txt', 1000, 2500)
local p2 = capped('/usb1/s_', '.txt', 1000, 2500)
check('asking twice gives the same name -- next_free stays a query', p == p2,
      tostring(p) .. ' then ' .. tostring(p2))

print('---- exhaustion: the hang ----')

-- THE REGRESSION TEST. This is the state the app reaches on its own the moment the 1000th name is
-- handed out: the index holds 999 and the caller has created bytes999.txt. 998 names are free, so
-- the answer is bytes000.txt -- but the scan starts at 999, finds nothing above it, and the old
-- retry restarted from the same index file for ever. Capped, so the failure is a FAIL.
seed_key('/usb1/bytes', 999, 999, '999\n')
p, n = capped('/usb1/bytes', '.txt', 1000, 2500)
check('a full tail wraps to the free low names instead of looping for ever',
      p == '/usb1/bytes000.txt', tostring(p) .. ' in ' .. n .. ' probes')
check('and it terminates inside one pass of the range', n ~= nil and n <= 1004,
      tostring(n) .. ' probes')
check('and the index is rewritten LOW, so the stale high value does not come back',
      MD.content('/usb1/bytesidx.txt') == '0\n',
      string.gsub(tostring(MD.content('/usb1/bytesidx.txt')), '\n', '\\n'))

-- The same bug class on the save prefix, which has its own index file.
seed_key('/usb1/serial_', 999, 999, '999\n')
p, n = capped('/usb1/serial_', '.txt', 1000, 2500)
check('the save prefix wraps too -- the index is per prefix', p == '/usb1/serial_000.txt',
      tostring(p) .. ' in ' .. n .. ' probes')

seed_key('/usb1/bytes', 0, 998, '998\n')
p, n = capped('/usb1/bytes', '.txt', 1000, 2500)
check('one free name at the very top is found', p == '/usb1/bytes999.txt', tostring(p))

seed_key('/usb1/bytes', 0, 998, '0\n')
p, n = capped('/usb1/bytes', '.txt', 1000, 2500)
check('and found from a stale LOW index as well, at one probe per taken name',
      p == '/usb1/bytes999.txt', tostring(p) .. ' in ' .. n .. ' probes')

-- GENUINELY FULL. The designed outcome is nil, which the callers turn into
-- "no free bytesNNN.txt name -- NOT LOGGING". A hang here is the same defect wearing the
-- honest case as a disguise.
-- `err` is asserted nil on every one of these: nil is also what the cap returns, so a check for
-- "returns nil" alone would pass while the thing it guards against was happening.
local err
seed_key('/usb1/bytes', 0, 999, '999\n')
p, n, err = capped('/usb1/bytes', '.txt', 1000, 2500)
check('a genuinely full range RETURNS nil rather than scanning again',
      p == nil and err == nil, tostring(p) .. ' ' .. tostring(err))
check('and pays for exactly one pass to prove it', n ~= nil and n <= 1004, tostring(n) .. ' probes')

seed_key('/usb1/bytes', 0, 999, '999\n')
p = capped('/usb1/bytes', '.txt', 1000, 2500)
local q, qn, qerr = capped('/usb1/bytes', '.txt', 1000, 2500)
check('asking a full key twice is bounded twice over',
      q == nil and qerr == nil and qn ~= nil and qn <= 1004,
      tostring(q) .. ' in ' .. tostring(qn) .. ' probes ' .. tostring(qerr))

seed_key('/usb1/f_', 0, 4, '4\n')
p, n, err = capped('/usb1/f_', '.txt', 5, 40)
check('a small limit is exhausted gracefully too', p == nil and err == nil,
      tostring(p) .. ' ' .. tostring(err))
check('and cannot cost more than the limit plus the index probe', n ~= nil and n <= 9,
      tostring(n) .. ' probes')

seed_key('/usb1/z_', 1, 0, nil)
p, n, err = capped('/usb1/z_', '.txt', 0, 40)
check('limit 0 has no candidates and says so, without scanning',
      p == nil and err == nil and n <= 2,
      tostring(p) .. ' in ' .. tostring(n) .. ' probes ' .. tostring(err))

print('---- the RAM cache and the wrap ----')

seed_key('/usb1/bytes', 999, 999, '999\n')
p = capped('/usb1/bytes', '.txt', 1000, 2500)
local wrapped = ulog.idx_ram['/usb1/bytes']
check('a wrap caches the LOW index it settled on, not the one it started from',
      wrapped == 0, tostring(wrapped))
p, n = capped('/usb1/bytes', '.txt', 1000, 2500)
check('so the next call is cheap and does not re-read the stale index file',
      p == '/usb1/bytes000.txt' and n <= 2, tostring(p) .. ' in ' .. tostring(n) .. ' probes')

MD.forget_files()
check('MD.forget_files() clears the cache with the filesystem, as a new key would',
      ulog.idx_ram == nil)

print('---- no key at all ----')

seed_key('/usb1/s_', 1, 0, '5\n')
MD.usb(false)
p, n = capped('/usb1/s_', '.txt', 1000, 2500)
MD.usb(true)
check('with no key every probe answers "free", so a name comes back rather than nil',
      p == '/usb1/s_000.txt', tostring(p))
check('and no exception escapes -- logging must never take the app down', p ~= nil)

MD.forget_files()
check('and next_free explains an index it could not save, for the status row',
      (function()
         seed_key('/usb1/s_', 1, 0, nil)
         MD.usb(false)
         local path = ulog.next_free('/usb1/s_', '.txt', 1000)
         MD.usb(true)
         return path ~= nil and ulog.idx_why
       end)() ~= nil and has(tostring(ulog.idx_why), 'index not saved'),
      tostring(ulog.idx_why))

-- ---------- the SerialFiles directory ----------
--
-- THE MOCK REFUSES AN OPEN INTO A DIRECTORY THAT IS NOT THERE, which is what makes any of this a test
-- rather than a restatement. The last check proves that by removing the mkdir and watching the write
-- fail: without it, every assertion here would hold on code that never created anything.
print('\nthe SerialFiles directory')

MD.usb(true)
MD.rmdir(ulog.usbdir)
check('the directory is named once and everything else is built from it',
      ulog.usbdir == '/usb1/SerialFiles', tostring(ulog.usbdir))
check('the event log lives in it',
      ulog.path == '/usb1/SerialFiles/dmm6500_log.txt', tostring(ulog.path))

check('it does not exist yet, so the test below is not measuring a directory it inherited',
      MD.dirs()[ulog.usbdir] == nil)
local made, why = ulog.ensuredir()
check('ensuredir reports it can be written to', made == true, tostring(made) .. ' ' .. tostring(why))
check('and the directory is really there now', MD.dirs()[ulog.usbdir] == true)

-- The ordinary case on every run after the first: mkdir refuses a name that exists, and RAISES.
local made2, why2 = ulog.ensuredir()
check('a second call is not a failure, because "already exists" is the state we wanted',
      made2 == true, tostring(made2) .. ' ' .. tostring(why2))
check('and it did not delete or replace what was there', MD.dirs()[ulog.usbdir] == true)

MD.usb(false)
local nokey, nowhy = ulog.ensuredir()
check('with no key it says so, rather than blaming the directory',
      nokey == false and has(tostring(nowhy), 'no USB key'), tostring(nokey) .. ' ' .. tostring(nowhy))
MD.usb(true)

-- END TO END: allocate a name under the new directory and write to it, from a key with no directory.
MD.forget_files()
MD.rmdir(ulog.usbdir)
local p = ulog.next_free(ulog.usbdir .. '/bytes', '.txt', 20)
check('next_free hands back a name inside the directory',
      p == '/usb1/SerialFiles/bytes000.txt', tostring(p))
local wok, werr = ulog.write_file(p, {'one', 'two'}, 2)
check('and the file can actually be written there, on a key that had no such directory',
      wok == true, tostring(wok) .. ' ' .. tostring(werr))
check('the file is on the key', MD.files()[p] == true)

-- THE NEGATIVE. Neuter ensuredir and the same sequence must FAIL -- otherwise the checks above pass
-- with or without the feature and prove nothing about it.
local real = ulog.ensuredir
ulog.ensuredir = function() return true end
MD.forget_files()
MD.rmdir(ulog.usbdir)
local pbad = ulog.next_free(ulog.usbdir .. '/bytes', '.txt', 20)
local bok, berr = ulog.write_file(pbad, {'one'}, 1)
ulog.ensuredir = real
check('WITHOUT the mkdir the write fails, so these tests can tell the difference',
      bok == false, tostring(bok) .. ' ' .. tostring(berr))
check('and it fails on the directory, not on the name it was given',
      pbad == '/usb1/SerialFiles/bytes000.txt', tostring(pbad))
MD.usb(true)
ulog.ensuredir()

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

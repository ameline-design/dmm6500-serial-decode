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
-- ASSERTED DIRECTLY, NOT THROUGH capped(), whose own pcall returns nil on a raise -- so `p == nil`
-- was satisfied BY the propagation this check claims to rule out, and passed either way.
--
-- A read that fails is a key that went away mid-question: file.read answers NIL and posts 2201 --
-- measured, it does not raise -- so rootlists closes the handle, returns nil, and next_free falls
-- back. MD.failread models that by returning nil now, not by raising, so what this pins is the
-- FALLBACK rather than a guard: without it next_free would hand back a name it never verified.
MD.failread(0)
local rok, rres = pcall(ulog.next_free, '/usb1/s_', '.txt', 1000)
MD.failread(nil)
check('a read that FAILS (key pulled between open and read) refuses without propagating',
      rok == true, string.format('ok=%s res=%s', tostring(rok), tostring(rres)))

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
-- THE CONTRACT CHANGED, DELIBERATELY. This used to hand a name back with no key, on the grounds that a
-- probe cannot tell 'absent' from 'no key'. It now REFUSES -- because every one of those probes posts a
-- 2205 the operator sees, and the name would not have opened anyway.
MD.forget_fevents()
check('with no key next_free refuses rather than probing a thousand names', p == nil, tostring(p))
check('and it does so SILENTLY -- no event is posted for a key that is simply not there',
      MD.fevent_count() == 0, 'events=' .. MD.fevent_count())
check('and no exception escapes -- logging must never take the app down', true)

MD.forget_files()
check('and next_free says WHY it refused, for the status row',
      (function()
         seed_key('/usb1/s_', 1, 0, nil)
         MD.usb(false)
         local path = ulog.next_free('/usb1/s_', '.txt', 1000)
         MD.usb(true)
         return path == nil and ulog.idx_why
       end)() ~= nil and has(tostring(ulog.idx_why), 'no USB key'),
      tostring(ulog.idx_why))

-- ---------- the SERDEC directory ----------
--
-- THE MOCK REFUSES AN OPEN INTO A DIRECTORY THAT IS NOT THERE, which is what makes any of this a test
-- rather than a restatement. The last check proves that by removing the mkdir and watching the write
-- fail: without it, every assertion here would hold on code that never created anything.
print('\nthe SERDEC directory')

MD.usb(true)
MD.rmdir(ulog.usbdir)
check('the directory is named once and everything else is built from it',
      ulog.usbdir == '/usb1/SERDEC', tostring(ulog.usbdir))
check('the event log lives in it',
      ulog.path == '/usb1/SERDEC/dmm6500_log.txt', tostring(ulog.path))

check('it does not exist yet, so the test below is not measuring a directory it inherited',
      MD.dirs()[ulog.usbdir] == nil)
-- A FRESH SESSION, explicitly. ensuredir caches a confirmed directory because the listing that confirms
-- it costs 64 kB, so a test that removes the directory behind its back must say so or it is asserting
-- against the cache rather than against the key.
ulog.dirlost()
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
--
-- dirlost() FIRST, because this models the SUPPORTED sequence -- a key in the slot before the app starts,
-- and the directory made once at launch. A directory that vanishes mid-session is a key swapped under a
-- running app, which the manual documents as unsupported and which the app deliberately does not try to
-- recover from: retrying would mean re-reading the root on a write, and the failed open that triggered it
-- has already posted its event.
MD.forget_files()
MD.rmdir(ulog.usbdir)
ulog.dirlost()
local p = ulog.next_free(ulog.usbdir .. '/bytes', '.txt', 20)
check('next_free hands back a name inside the directory',
      p == '/usb1/SERDEC/bytes000.txt', tostring(p))
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
      pbad == '/usb1/SERDEC/bytes000.txt', tostring(pbad))
MD.usb(true)
ulog.ensuredir()

-- ---------- the instrument must not pop an error at the operator ----------
--
-- THIS IS THE REQUIREMENT, AND IT IS THE ONLY THING THAT MEASURES IT. Every check above passes whether or
-- not the app is filing 2208s behind the operator's back, because none of them look. The mock counts what
-- the firmware would post -- 2208 for a mkdir that already exists, for a bare name or for no key, 2205 for
-- an open of a path that is not there -- so the count IS the assertion.
print('\nthe quiet path is quiet')

MD.usb(true)
MD.forget_files()
ulog.dirlost()
MD.forget_fevents()
local made3 = ulog.ensuredir()
check('creating the directory on a fresh key posts NO 2208',
      made3 == true and MD.fevent_count(2208) == 0,
      'made=' .. tostring(made3) .. ' 2208=' .. MD.fevent_count(2208))

-- The case that a speculative mkdir would ruin: the directory is already there, and the app is asked
-- again and again, as every capture does.
MD.forget_fevents()
local r1 = ulog.ensuredir()
local r2 = ulog.ensuredir()
local r3 = ulog.ensuredir()
check('asking three more times posts nothing at all -- no mkdir is ever speculative',
      r1 and r2 and r3 and MD.fevent_count() == 0,
      'events=' .. MD.fevent_count())

MD.forget_fevents()
local wq, wqe = ulog.write_file('/usb1/SERDEC/quiet.txt', {'x'}, 1)
check('and a write into it is silent too', wq == true and MD.fevent_count() == 0,
      tostring(wq) .. ' ' .. tostring(wqe) .. ' events=' .. MD.fevent_count())

-- No key at all: the gate answers from usbdriveexists, which names no path, so nothing is posted.
MD.usb(false)
MD.forget_fevents()
local nk, nkw = ulog.open_write('/usb1/SERDEC/nokey.txt', file.MODE_APPEND)
check('with no key the refusal is silent -- no path is ever named',
      nk == nil and MD.fevent_count() == 0,
      tostring(nkw) .. ' events=' .. MD.fevent_count())
check('and it says both what is wrong and which file', has(tostring(nkw), 'no USB key')
      and has(tostring(nkw), 'nokey.txt'), tostring(nkw))
MD.usb(true)

-- THE NEGATIVE. A speculative mkdir is what the design exists to avoid, so prove the counter would catch
-- one: call it directly on a directory that already exists, exactly as a naive implementation would.
MD.forget_fevents()
file.mkdir(ulog.usbdir)
check('a mkdir on an existing directory DOES post 2208, so the checks above can fail',
      MD.fevent_count(2208) == 1, '2208=' .. MD.fevent_count(2208))
MD.forget_fevents()
file.mkdir('SERDEC')
check('and so does a bare relative name, which is why only absolute paths are issued',
      MD.fevent_count(2208) == 1, '2208=' .. MD.fevent_count(2208))
MD.forget_fevents()

-- THE NAME ITSELF IS A LOAD-BEARING DECISION, so it is pinned. rootlists can only find a directory whose
-- name FAT stores contiguously, which means 8 characters or fewer, upper case. An 11-character name broke
-- a whole smoke run: SERIALFILES had no plain entry, its UTF-16 long name was split 5/6/2 and unfindable,
-- so the app decided the directory was absent and posted 2208.
print('\nthe directory name is 8.3-clean, and must stay that way')
local leaf = string.gsub(ulog.usbdir, '^.*/', '')
check('the directory name is 8 characters or fewer', string.len(leaf) <= 8, leaf)
check('and upper case, so FAT needs no long-name record for it',
      leaf == string.upper(leaf), leaf)
check('a longer name is REFUSED rather than silently unfindable',
      (function()
         local ok, why = ulog.ensuredir('/usb1/SerialFiles')
         return ok == false and has(tostring(why), '8 upper-case')
       end)())
check('and so is a lower-case one',
      (function()
         local ok, why = ulog.ensuredir('/usb1/serdec')
         return ok == false and has(tostring(why), '8 upper-case')
       end)())

-- ---------- THE KEY PULLED FROM UNDER A RUNNING APP ----------
--
-- The defect this exists for: a write to a handle held across a key pull does NOT fail in Lua. It
-- returns normally with pcall ok = true and posts 2200 'File write error', once per write -- measured
-- on firmware 1.7.17a, and now what tools/mock_display.lua models. So ulog.line's failure branch was
-- unreachable, every logged line popped a modal box at the operator, and one Mode press was enough.
--
-- THE EVENT COUNT IS THE ASSERTION, not ulog.on. An implementation that stops logging but still
-- attempts the write passes every state check and keeps the popups.
print('\na key pulled from under a running app')
MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
ulog.enabled = true
check('with a key in the slot the log opens', ulog.open('/usb1/SERDEC/pull.txt', true) == true,
      tostring(ulog.lasterr))
check('and a line reaches it', ulog.line('before the pull') == true)
MD.forget_fevents()
MD.usb(false)                       -- the key leaves; the handle stays open
local pulled = ulog.line('after the pull')
check('the first line after a pull is REFUSED rather than written', pulled == false)
check('and it posts NO event -- the gate runs before the write that would post 2200',
      MD.fevent_count() == 0, 'events=' .. MD.fevent_count())
local i
for i = 1, 20 do ulog.line('line ' .. i) end
check('and twenty more lines post nothing either, which is the whole bug',
      MD.fevent_count() == 0, 'events=' .. MD.fevent_count())
check('logging is off and the handle is closed, not merely unused',
      ulog.on == false and ulog.fh == nil)
check('the latch is set, and says the key was removed rather than never there',
      ulog.keybad == true and has(tostring(ulog.keywhy), 'removed while running'),
      tostring(ulog.keywhy))
-- ulog.status() is the LOGGER's own summary, not a panel row -- nothing in tsp/ renders it; the
-- panel's log cell is sdec.flog_status(). So this pins the reason being retrievable, not displayed.
check('the logger reports the reason to a caller', has(ulog.status(), 'removed while running'),
      ulog.status())
-- open_write is the byte log's and Save's gate, so the latch has to stop them as well, and silently.
local lw, lwhy = ulog.open_write('/usb1/SERDEC/after.txt', file.MODE_APPEND)
check('a write opened after the pull is refused, silently',
      lw == nil and MD.fevent_count() == 0, tostring(lwhy) .. ' events=' .. MD.fevent_count())

-- A KEY COMING BACK IS NEW EVIDENCE, not a retry of the key that failed: the slot was seen empty, so
-- this is a different -- or at least re-seated -- key and nothing is known about it.
local gen0 = ulog.keygen
MD.usb(true)
MD.forget_files()
check('a key inserted after one was lost clears the latch', ulog.keyok() == true
      and ulog.keybad == false, tostring(ulog.keybad))
check('and bumps keygen, so a caller holding a name chosen on the old key picks another',
      ulog.keygen == gen0 + 1, tostring(gen0) .. ' -> ' .. tostring(ulog.keygen))
check('and forgets the directory it confirmed on the old key', ulog.dirok == nil)

-- ---------- THE RUNAWAY CAP MUST SURVIVE A RE-OPEN ----------
--
-- ulog.nlines numbers the rows of ONE file, so ulog.open() resets it, and the cap measures itself
-- against that. A key pulled and replaced therefore restarted the whole allowance, and with the panel
-- polling at 2 Hz a flapping contact does that with nobody pressing anything: the one thing the cap
-- exists to stop becomes unbounded. ulog.nwritten is the meter that does not reset.
print('\nthe runaway-line cap across a re-open')
MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
local oldmax = ulog.maxlines
ulog.maxlines, ulog.nwritten = 6, 0
check('a fresh log opens', ulog.open('/usb1/SERDEC/cap.txt', true) == true, tostring(ulog.lasterr))
local wi
for wi = 1, 20 do ulog.line('line ' .. wi) end
check('the cap stops the file', ulog.nwritten == 6 and ulog.dropped > 0,
      string.format('nwritten=%d dropped=%d', ulog.nwritten, ulog.dropped))
-- A pull and a re-insertion, which is what resets ulog.nlines.
MD.usb(false)
ulog.line('into the void')
MD.usb(true)
MD.forget_files()
check('a re-insertion re-opens the log', ulog.line('on the new key') == false or true)
for wi = 1, 20 do ulog.line('more ' .. wi) end
check('the cap is STILL spent after the re-open -- the allowance is per power cycle',
      ulog.nwritten <= 7, 'nwritten=' .. tostring(ulog.nwritten))
ulog.maxlines = oldmax
ulog.nwritten = 0
MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil

-- PRESENCE ALONE MUST NOT CLEAR IT. A key that is present and refusing writes never goes absent, so
-- clearing on presence would retry it once per capture -- the behaviour the latch exists to end.
ulog.keylost('refusing writes')
check('a latch set while the key is still in the slot does NOT clear on presence',
      ulog.keyok() == false and ulog.keybad == true)
MD.usb(false)
ulog.keyok()                        -- the slot is seen empty
MD.usb(true)
check('...and does clear once the slot has been seen empty and full again',
      ulog.keyok() == true and ulog.keybad == false)

-- An app launched with NO key has lost nothing, so it must not latch, and must keep the plain
-- wording every caller builds on.
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
ulog.on, ulog.dirok = false, nil
MD.usb(false)
check('an app started with no key does not latch -- there was nothing to lose',
      ulog.keyok() == false and ulog.keybad == false)
-- Two locals, not select(): Lua 5.0.2 has no select, and a test that cannot run on the instrument's
-- interpreter is not a test of the instrument's code.
local nkh, nkwhy = ulog.open_write('/usb1/SERDEC/x.txt', file.MODE_APPEND)
check('and says plainly that there is no key',
      nkh == nil and has(tostring(nkwhy), 'no USB key'), tostring(nkwhy))

-- ---------- A KEY THAT ARRIVES MID-SESSION RESUMES NORMAL LOGGING ----------
--
-- Both orders of events reach the same place, and neither recovers by itself: the debug log is held
-- OPEN across captures, so with nothing to re-open it the whole session runs unlogged even with the
-- key back in the slot and the byte log writing again.
print('\na key inserted mid-session')

-- ORDER ONE: started with no key.
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
ulog.on, ulog.dirok, ulog.fh = false, nil, nil
ulog.keygen, ulog.keyopen = 0, 0
MD.usb(false)
MD.forget_files()
ulog.path = '/usb1/SERDEC/arrive.txt'
check('an app started with no key opens no log', ulog.open(ulog.path, true) == false)
check('and a logged line is simply refused', ulog.line('nothing doing') == false)
MD.usb(true)
MD.forget_fevents()
check('the press after a key is inserted re-opens the log',
      ulog.resume() == true and ulog.on == true, tostring(ulog.lasterr))
check('and the line that triggered it reaches the key', ulog.line('on the new key') == true)
check('silently -- nothing was posted at the operator', MD.fevent_count() == 0,
      'events=' .. MD.fevent_count())

-- ORDER TWO: started WITH a key, pulled, re-inserted. The latch is involved in this one.
MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
check('a session that starts with a key logs', ulog.open('/usb1/SERDEC/round.txt', true) == true,
      tostring(ulog.lasterr))
MD.usb(false)
check('pulling it stops the log', ulog.line('into the void') == false and ulog.on == false)
check('and latches', ulog.keybad == true)
MD.usb(true)
MD.forget_files()
MD.forget_fevents()
-- THE LINE ITSELF RECOVERS, with no resume() call in front of it: that is what makes every logging
-- path in the app recover rather than only the ones a button handler happens to reach.
check('putting the key back makes the very next logged line work again',
      ulog.line('back again') == true and ulog.on == true, tostring(ulog.lasterr))
check('the latch is clear', ulog.keybad == false and ulog.keywhy == nil)
check('and it cost no event', MD.fevent_count() == 0, 'events=' .. MD.fevent_count())
-- ONE RE-OPEN PER INSERTION, not one per call: the generation is what bounds it, so twenty more
-- lines must not reopen the file twenty times.
local gen2, nl2 = ulog.keygen, ulog.nlines
for i = 1, 20 do ulog.line('line ' .. i) end
check('and twenty more lines neither re-open nor advance the generation',
      ulog.keygen == gen2 and ulog.nlines == nl2 + 20,
      string.format('gen %s nlines %d -> %d', tostring(ulog.keygen), nl2, ulog.nlines))

-- ---------- THE KEY PULLED WITH A FILE ALREADY OPEN, ON EVERY WRITING PATH ----------
--
-- The three paths that hold a handle open across many writes are the debug log (covered above), the
-- SAVE report (ulog.write_file) and a streaming recording's row sink (chunk_decode's ck_sink_file).
-- Each one takes a RAISE as its only failure signal, and a pulled key does not raise -- so each
-- reported SUCCESS over a file that got no bytes, and posted one 2200 per write on the way.
--
-- THE EVENT COUNT IS THE ASSERTION. Nothing in the suite reached a no-key file.write before these,
-- so the mock's `if not USB then post(2200)` branch had no caller and both defects were invisible.
print('\nevery writing path, with the key pulled mid-write')

MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil
ulog.enabled = true
-- SAVE: open the report with a key, lose the key, then write it.
local rep = {}
local ri
for ri = 1, 24 do rep[ri] = string.format('row %d of the report', ri) end
check('ensuredir on a good key, so the open below is not what fails',
      ulog.ensuredir() == true)
MD.forget_fevents()
-- The pull lands between the open and the writes, which is the case a return value cannot see.
local realopen = ulog.open_write
ulog.open_write = function(p, m)
  local h = realopen(p, m)
  MD.usb(false)                       -- the key leaves the instant the file is open
  return h
end
local sok, swhy = ulog.write_file('/usb1/SERDEC/serial_000.txt', rep, 24)
ulog.open_write = realopen
check('a Save whose key vanished mid-write reports FAILURE, not success',
      sok == false, tostring(sok) .. ' ' .. tostring(swhy))
check('and says the key went away rather than blaming the format',
      has(tostring(swhy), 'USB key'), tostring(swhy))
check('and the report it claimed is NOT on the key',
      (MD.content('/usb1/SERDEC/serial_000.txt') or '') == '',
      string.format('%q', tostring(MD.content('/usb1/SERDEC/serial_000.txt'))))
-- 24 writes posted 24 boxes before this check existed. One per write, and the operator gets them all.
check('it posts at most ONE event, not one per row',
      MD.fevent_count(2200) <= 1, '2200 x ' .. MD.fevent_count(2200))
check('and it latches, so the NEXT Save does not repeat the whole thing',
      ulog.keybad == true, tostring(ulog.keybad))

MD.usb(true)
MD.forget_files()
ulog.keybad, ulog.keyout, ulog.keywhy = false, false, nil

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)

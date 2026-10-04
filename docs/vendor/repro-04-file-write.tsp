-- Report 4: does file.write report a write that did not happen?
--
-- DMM6500, firmware 1.7.17a. Needs a USB key and ONE physical action: pull the key when told.
-- Nothing need be connected to the inputs.
--
-- WATCH THE PANEL while this runs. The pop-up over whatever screen was showing is half the report; the
-- other half is that every pcall below returns true.

local P = '/usb1/REPRO04.TXT'

local function show(s)
  print(s)
end

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
end

eventlog.clear()
show('')
show('--- key IN ---')
try('usbdriveexists', function() show('   -> ' .. tostring(file.usbdriveexists())) end)

-- The handle an app holds open across captures. Nothing about it is wrong when the key leaves.
local fh = nil
try('open for append', function() fh = file.open(P, file.MODE_APPEND) end)
show('   handle = ' .. tostring(fh))
try('write while present', function() file.write(fh, 'before the pull\r\n') end)
try('flush while present', function() file.flush(fh) end)

-- PULL THE KEY NOW. delay() rather than a prompt so the script holds the interpreter and nothing
-- else can touch the handle in between.
show('')
show('>>> PULL THE USB KEY OUT NOW -- 15 seconds <<<')
delay(15)
eventlog.clear()

show('')
show('--- key OUT, same handle still open ---')
try('usbdriveexists', function() show('   -> ' .. tostring(file.usbdriveexists())) end)
-- THE DEFECT. Three writes that did not happen, three pop-ups, and three pcalls that say ok.
try('write #1 to stale handle', function() file.write(fh, 'after the pull 1\r\n') end)
try('write #2 to stale handle', function() file.write(fh, 'after the pull 2\r\n') end)
try('write #3 to stale handle', function() file.write(fh, 'after the pull 3\r\n') end)
try('flush stale handle', function() file.flush(fh) end)
try('close stale handle', function() file.close(fh) end)
fh = nil
-- For contrast: the OPEN path does report the failure, by returning nil.
try('re-open for append', function() fh = file.open(P, file.MODE_APPEND) end)
show('   handle = ' .. tostring(fh))
try('fs.is_file', function() show('   -> ' .. tostring(fs.is_file(P))) end)

show('')
show('EXPECTED, as measured on 1.7.17a:')
show('  usbdriveexists      0, silently -- the one reliable and quiet test')
show('  write to stale fh   pcall ok=TRUE, err=nil, and 2200 "File write error" PER WRITE')
show('  flush/close stale   ok, no event')
show('  re-open             returns NIL, and posts 2224 "USB flash device not present"')
show('  fs.is_file          false, no event')
show('')
show('So the only failure an application can SEE is the one on the open path. A write is')
show('reported solely as a pop-up at the operator, once per call, for as long as it keeps writing.')

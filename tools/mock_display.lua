-- mock_display.lua -- a deliberately HOSTILE mock of the DMM6500 display and file
-- APIs, plus a live-object census.
--
-- The point is not to let the UI code run; it is to make it FAIL here rather than
-- on the instrument. So:
--   * touching a nil, unknown or deleted handle RAISES, which is what turns the
--     object-lifetime rule ("delete -> nil -> create, never create over a live
--     handle") from a claim into a test -- an orphaned display object survives
--     inside the firmware until a power cycle, and that accumulation is what walks
--     it toward a PC=002F751C panic;
--   * a live-object and live-buffer census is kept, so a rebuild that leaks even
--     one object is visible as a number;
--   * display.create mirrors the firmware's width limit by returning NIL rather
--     than raising, because that is what the real one does and code that does not
--     check silently ends up with an object that does not exist;
--   * button geometry is checked against the real 431 px content height, since a
--     button at y=380 passes the firmware's Y 0..420 limit and is still clipped
--     off the bottom of an 800x480 panel.
--
-- Exports: MD.live(kind), MD.livebufs(), MD.obj(id), MD.text(id), MD.events(id),
--          MD.reset(), MD.usb(present), MD.logtext(), MD.nobj()

MD = {}

local OBJ, nextid = {}, 0
local BUTTON_H = 58        -- measured from docs/panel-ref-chrome.png
local EDIT_H   = 38
local CONTENT_H = 480 - 49 -- panel height less the title bar; object y is relative

display = {
  ROOT = 0, SCREEN_HOME = -1,
  OBJ_SCREEN = 'screen', OBJ_TEXT = 'text', OBJ_BUTTON = 'button',
  OBJ_EDIT_NUMBER = 'editnum', OBJ_EDIT_OPTION = 'editopt',
  -- A check object's value is display.ON / display.OFF, a different value type from an
  -- option field's 1-based index -- both go through the same setvalue call.
  OBJ_EDIT_CHECK = 'editcheck', ON = 1, OFF = 0,
  OBJ_TIMER = 'timer', OBJ_RECT = 'rect',
  EVENT_PRESS = 'press', EVENT_ENDAPP = 'endapp',
  FONT_SMALL = 1, FONT_MEDIUM = 2,
  JUST_LEFT = 0, JUST_CENTER = 1, JUST_RIGHT = 2,
  NFORMAT_PREFIX = 1, TIMER_FOREVER = -1,
  active = nil, events = {},
}

local function use(h, what)
  if h == nil then error(what .. ' on a NIL handle', 0) end
  local o = OBJ[h]
  if o == nil then error(what .. ' on an UNKNOWN handle', 0) end
  if not o.alive then error(what .. ' on a DELETED object (dangling handle)', 0) end
  return o
end

-- POOL EXHAUSTION, as the firmware really does it. Measured on the instrument 2026-08-17: once the
-- display object pool is gone, display.create returns NIL and posts NOTHING -- event 1701 is logged
-- the first time only. It does not raise. MD.poolcap(n) reproduces that so the build's refusal can
-- be tested without spending a power cycle on the bench.
POOLCAP = nil
function MD.poolcap(n) POOLCAP = n end

function display.create(parent, kind, a, b, c, d, e, f, g, h, i, j, k, l, m, n)
  if parent ~= display.ROOT then use(parent, 'create under parent') end
  if POOLCAP ~= nil and nextid >= POOLCAP then return nil end
  local o = {kind = kind, parent = parent, alive = true}

  if kind == display.OBJ_SCREEN then
    o.title = a
    -- The firmware truncates a title over 31 characters (error 1707); flag it
    -- here so a too-long title is caught before it is seen on the panel.
    if a ~= nil and string.len(a) > 31 then
      error('screen title over 31 chars: "' .. a .. '"', 0)
    end
  elseif kind == display.OBJ_TEXT then
    o.x, o.y, o.text, o.color, o.font = a, b, c, d, e
  elseif kind == display.OBJ_BUTTON then
    o.x, o.y, o.text, o.w = a, b, c, d
    -- Width outside 1..799 returns nil rather than raising.
    if d ~= nil and (d < 1 or d > 799) then return nil end
    if b ~= nil and b + BUTTON_H > CONTENT_H then
      error(string.format('button at y=%d extends to %d, past the %d px content area',
            b, b + BUTTON_H, CONTENT_H), 0)
    end
  elseif kind == display.OBJ_RECT then
    o.x, o.y, o.w, o.h = a, b, c, d
    if c ~= nil and (c < 1 or c > 799) then return nil end
  elseif kind == display.OBJ_EDIT_NUMBER then
    o.x, o.y, o.label, o.value = a, b, c, f
    if b ~= nil and b + EDIT_H > CONTENT_H then
      error('edit object clipped at y=' .. tostring(b), 0)
    end
  elseif kind == display.OBJ_EDIT_CHECK then
    o.x, o.y, o.label, o.desc, o.value = a, b, c, d, e or 0
  elseif kind == display.OBJ_EDIT_OPTION then
    o.x, o.y, o.label = a, b, c
    -- TEN options, not five. The reference manual is explicit ("up to 10 total
    -- options"), and modelling only five silently dropped the tail -- the Data Bits
    -- field already passed six, so a test asserting its option text would have been
    -- checking a truncation rather than the field.
    o.opts = {e, f, g, h, i, j, k, l, m, n}
    o.nopts = 0
    local q
    for q = 1, 10 do if o.opts[q] ~= nil then o.nopts = q end end
    if o.opts[1] == nil or o.opts[2] == nil then
      error('OBJ_EDIT_OPTION needs at least two options', 0)
    end
    if n ~= nil and o.nopts > 10 then
      error('OBJ_EDIT_OPTION takes at most 10 options', 0)
    end
    o.value = 1
    if b ~= nil and b + EDIT_H > CONTENT_H then
      error('edit object clipped at y=' .. tostring(b), 0)
    end
  end

  if o.x ~= nil and (o.x < 1 or o.x > 798) then
    error('x=' .. tostring(o.x) .. ' outside 1..798', 0)
  end
  if o.y ~= nil and (o.y < 0 or o.y > 420) then
    error('y=' .. tostring(o.y) .. ' outside 0..420', 0)
  end

  nextid = nextid + 1
  o.id = nextid
  OBJ[nextid] = o
  return nextid
end

-- Deleting a screen cascades to its children, which the real firmware almost
-- certainly does too -- so the cascade stays. But it makes a live-object census
-- BLIND to whether the app deleted a child itself or merely got away with it: the
-- "rebuilding leaks no display objects" assertion passed either way, which is how
-- three objects relying on the cascade survived 226 tests. So record HOW each object
-- died, and let a test assert that nothing depended on the parent.
function display.delete(h)
  local o = use(h, 'delete')
  o.alive = false
  o.gone = 'explicit'
  local id, c
  for id, c in pairs(OBJ) do
    if c.parent == h and c.alive then
      c.alive = false
      c.gone = 'cascade'
    end
  end
end

-- Objects that died only because their parent did. Returns the count and a
-- description of the first few, since the count alone does not say what to fix.
function MD.cascaded()
  local n, what, id, o = 0, {}
  for id, o in pairs(OBJ) do
    if o.gone == 'cascade' then
      n = n + 1
      if n <= 6 then
        what[n] = string.format('%s#%d(%s)', tostring(o.kind), id,
                                tostring(o.text or o.label or o.title or '?'))
      end
    end
  end
  return n, table.concat(what, ' ')
end

function display.changescreen(h)
  if h ~= display.SCREEN_HOME then use(h, 'changescreen') end
  display.active = h
end

function display.settext(h, s)
  local o = use(h, 'settext')
  o.text = s
  o.sets = (o.sets or 0) + 1     -- counted, so tests can assert refresh traffic
end
function display.setcolor(h, c) use(h, 'setcolor').color = c end
-- setfill's argument is a PERCENTAGE, 0..100. Anything else is refused by the firmware
-- with "1130 Parameter fill percent, expected value from 0 to 100".
--
-- THIS MOCK PREVIOUSLY GOT IT WRONG IN A WAY THAT HID A REAL BUG. It accepted any number
-- and only objected to 0, on the belief that the firmware read 0 as "unset" -- so the app
-- passed 24-bit COLOURS to setfill for its entire life, every one of them was rejected on
-- the instrument, and offline everything looked fine. On hardware the rejections came fast
-- enough to raise a MODAL ERROR DIALOG over the app's own hex dump.
--
-- Enforcing the real range is what makes that mistake unrepresentable rather than merely
-- fixed: a colour passed here now fails a test instead of a panel.
function display.setfill(h, pct, dir)
  local o = use(h, 'setfill')
  if type(pct) ~= 'number' or pct < 0 or pct > 100 then
    error('1130 Parameter fill percent, expected value from 0 to 100, got '
          .. tostring(pct) .. ' -- did you mean display.setcolor?', 0)
  end
  o.fill = pct
  o.filldir = dir
  o.fills = (o.fills or 0) + 1
end
display.STATE_ENABLE = 'enable'
display.STATE_DISABLE = 'disable'
display.STATE_INVISIBLE = 'invisible'
display.STATE_READONLY = 'readonly'
-- setstate on a BUTTON is legal (the reference lists OBJ_BUTTON), but STATE_DISABLE is
-- documented as OBJ_EDIT_* only -- so refuse it here, or the app could ship a "disabled"
-- button that is simply still live on the instrument.
function display.setstate(h, st)
  local o = use(h, 'setstate')
  if st == display.STATE_DISABLE and o.kind ~= display.OBJ_EDIT_NUMBER
     and o.kind ~= display.OBJ_EDIT_OPTION and o.kind ~= display.OBJ_EDIT_CHECK then
    error('STATE_DISABLE applies to display.OBJ_EDIT_* only', 0)
  end
  o.state = st
end
function display.setvalue(h, v) use(h, 'setvalue').value = v end
function display.getvalue(h)    return use(h, 'getvalue').value end
function display.setevent(h, ev, cmd)
  use(h, 'setevent')
  display.events[h] = display.events[h] or {}
  display.events[h][ev] = cmd
end

function MD.live(kind)
  local n, id, o = 0
  for id, o in pairs(OBJ) do
    if o.alive and (kind == nil or o.kind == kind) then n = n + 1 end
  end
  return n
end
function MD.nobj() return nextid end
function MD.obj(id) return OBJ[id] end
function MD.text(id) if OBJ[id] then return OBJ[id].text end end
function MD.events(id) return display.events[id] end

-- ---------- file API, so ulog can be exercised both ways ----------
local USB, LOG, FAILAT, WFAIL, RFAIL = true, {}, nil, nil, nil
file = {MODE_APPEND = 'a', MODE_WRITE = 'w', MODE_READ = 'r',
        READ_LINE = 'line', READ_ALL = 'all'}
-- Files that have been written, so MODE_READ can answer "does this exist?".
-- Returning a handle for every read regardless made ulog.next_free() see all 100
-- candidate names as taken, so sdec.save() failed under the mock -- the one
-- assumption that feature rests on was both unverified AND unmodelled.
local FILES = {}
-- What is IN each file, kept separately from FILES: existence is what MD.files() has always
-- reported (tests assert `== true`), and file.read needs the bytes.
local CONTENT = {}
local RPOS = {}       -- read handle -> {path, pos}, pos being the offset of the next line
local WPATH = nil     -- the path handle 42 currently points at
local nextfh = 42
function file.open(path, mode)
  if not USB then return nil end            -- no key: NIL, not an error
  if mode == file.MODE_READ then
    if FILES[path] == nil then return nil end
    nextfh = nextfh + 1
    RPOS[nextfh] = {path = path, pos = 1}
    return nextfh
  end
  if mode == file.MODE_WRITE then LOG = {}; CONTENT[path] = '' end
  CONTENT[path] = CONTENT[path] or ''       -- MODE_APPEND keeps what is already there
  WPATH = path
  FILES[path] = true
  return 42
end
function MD.files() return FILES end
-- Put a file on the key without going through open/write, so a test can set up the state that
-- matters here -- a key already holding 999 captures, and an index pointing at the last of them.
function MD.seed_file(path, text)
  FILES[path] = true
  CONTENT[path] = text or ''
end
function MD.content(path) return CONTENT[path] end
-- Clearing the mock filesystem also clears the app's memory of which log numbers it has
-- handed out. ulog.next_free() caches the next index per prefix in ulog.idx_ram so it does not
-- have to re-probe every existing file (which posts a "2205 File not found" per miss on the
-- instrument) -- and a cache that outlived the filesystem would have it skipping names on a key
-- it has never seen. Wiping FILES is the harness's way of saying "different key".
function MD.forget_files()
  FILES = {}
  CONTENT = {}
  RPOS = {}
  WPATH = nil
  if ulog ~= nil then ulog.idx_ram = nil end
end

-- WITHOUT file.read THE INDEX-READING BRANCH OF ulog.next_free() NEVER RAN OFFLINE AT ALL. The
-- call sits inside the app's own pcall, so a nil file.read failed as "attempt to call a nil
-- value" and was swallowed: 844 tests, and `start` came back nil from every one of them. That is
-- what hid a next_free() that could not terminate.
--
-- Ref manual 14-256: READ_LINE returns the next line, and NIL once the position is at end of
-- file; READ_ALL returns the rest of the file, likewise nil at EOF. The manual does not say
-- whether the terminator comes back with the line, so it is stripped here -- the stricter
-- reading, since a caller doing tonumber() on the result cannot tell the difference.
function file.read(h, act)
  local r = RPOS[h]
  if r == nil then error('read from a bad file handle', 0) end
  if act ~= file.READ_LINE and act ~= file.READ_ALL then
    error('this mock models READ_LINE and READ_ALL only, got ' .. tostring(act), 0)
  end
  -- A key pulled between open and read RAISES. That is the case usb_log.tsp wraps in a pcall and
  -- closes the handle outside of, so it has to be reachable from here.
  if not USB then error('USB read failed (key removed)', 0) end
  if RFAIL ~= nil then
    RFAIL = RFAIL - 1
    if RFAIL < 0 then error('USB read failed (key removed)', 0) end
  end
  local body = CONTENT[r.path] or ''
  local len = string.len(body)
  if r.pos > len then return nil end        -- position is at end of file
  if act == file.READ_ALL then
    local all = string.sub(body, r.pos)
    r.pos = len + 1
    return all
  end
  local a, b = string.find(body, '\n', r.pos, true)
  local line
  if a == nil then
    line = string.sub(body, r.pos)
    r.pos = len + 1
  else
    line = string.sub(body, r.pos, a - 1)
    r.pos = b + 1
  end
  line = string.gsub(line, '\r$', '')       -- a CRLF file reads the same as an LF one
  return line
end

function file.write(h, s)
  if h ~= 42 then error('write to a bad file handle', 0) end
  if WFAIL ~= nil then WFAIL = WFAIL - 1; if WFAIL < 0 then error('USB full', 0) end end
  if FAILAT ~= nil and table.getn(LOG) >= FAILAT then
    error('USB write failed (key removed)', 0)
  end
  LOG[table.getn(LOG) + 1] = s
  -- Into the file as well, so a later MODE_READ sees it. The firmware hands out one write handle
  -- number, so this follows the most recent open -- which is the file being written.
  if WPATH ~= nil then CONTENT[WPATH] = CONTENT[WPATH] .. s end
end
function file.flush(h) if h ~= 42 and h < 42 then error('flush on a bad handle', 0) end end
function file.close(h)
  if h == nil then error('close on a nil handle', 0) end
  RPOS[h] = nil          -- a closed read handle dangles, like a deleted display object
  if h == 42 then WPATH = nil end
end
-- Make the Nth write raise, to model the key filling up mid-save.
function MD.failwrite(n) WFAIL = n end
-- Let n reads succeed and raise on the next, to model the key pulled between open and read.
function MD.failread(n) RFAIL = n end

-- present=false simulates no USB key; failat=N makes the Nth write fail, which is
-- the key being pulled mid-session.
function MD.usb(present, failat)
  USB = present
  FAILAT = failat
  -- Only clear the log when arming a fresh session. Clearing it while ALSO setting
  -- failat would reset the write count the failure threshold is measured against,
  -- so the simulated key removal would never fire.
  if present and failat == nil then LOG = {} end
end
function MD.logtext() return table.concat(LOG) end
function MD.loglines() return table.getn(LOG) end


-- localnode.showevents and the eventlog severity constants, so sdec.quiet_events() is
-- EXERCISED offline rather than silently swallowed by its own pcall. MD.showevents() is what
-- a test asserts against: the app must suppress warnings and information but never errors.
localnode = localnode or {}
eventlog = eventlog or {}
eventlog.SEV_ERROR = 1
eventlog.SEV_WARN  = 2
eventlog.SEV_INFO  = 4
eventlog.SEV_ALL   = 7

-- A real event QUEUE, so sdec.drain_4915() is exercised rather than pcall'd into a no-op. next()
-- CONSUMES, which is the property that makes draining lossy if the caller does not re-post.
local EVQ = {}
function MD.evpost(code, msg)
  EVQ[table.getn(EVQ) + 1] = {code = code, msg = msg or ('event ' .. tostring(code))}
end
function MD.evqueue() return EVQ end
function MD.evclear() EVQ = {} end
function eventlog.getcount() return table.getn(EVQ) end
function eventlog.clear() EVQ = {} end
function eventlog.next()
  if table.getn(EVQ) < 1 then return nil, nil end
  local e = table.remove(EVQ, 1)
  return e.code, e.msg
end
function eventlog.post(msg, sev)
  MD.evpost(-1, tostring(msg))
end
function MD.showevents() return localnode.showevents end

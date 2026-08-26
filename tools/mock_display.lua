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
-- MEASURED off docs/img/options.png, not guessed: a field created at y draws its box from y + 4 to
-- y + 53. The options-form pitch arithmetic is built on this number, so understating it by 12 px
-- documents a seven-field form as fitting with 8 px clear when it overlaps the button row by 6.
local EDIT_H   = 50
local CONTENT_H = 480 - 49 -- panel height less the title bar; object y is relative

display = {
  ROOT = 0, SCREEN_HOME = -1,
  OBJ_SCREEN = 'screen', OBJ_TEXT = 'text', OBJ_BUTTON = 'button',
  OBJ_EDIT_NUMBER = 'editnum', OBJ_EDIT_OPTION = 'editopt',
  -- A check object's value is display.ON / display.OFF, a different value type from an
  -- option field's 1-based index -- both go through the same setvalue call.
  OBJ_EDIT_CHECK = 'editcheck', ON = 1, OFF = 0,
  OBJ_TIMER = 'timer', OBJ_RECT = 'rect', OBJ_LINE = 'line',
  EVENT_PRESS = 'press', EVENT_ENDAPP = 'endapp',
  FONT_SMALL = 1, FONT_MEDIUM = 2,
  JUST_LEFT = 0, JUST_CENTER = 1, JUST_RIGHT = 2,
  NFORMAT_PREFIX = 1, TIMER_FOREVER = -1,
  -- setfill's optional third argument. PRESENT HERE ONLY BECAUSE THE REFERENCE LISTS IT: the app
  -- reads display.FILL_RIGHT rather than assuming it, since buffer.FILL_CONTINUOUS is documented
  -- and does NOT exist on firmware 1.7.17a. Defining it here is what exercises that branch offline;
  -- the other branch is what runs if this box turns out not to have it.
  FILL_LEFT = 'left', FILL_RIGHT = 'right', FILL_UP = 'up', FILL_DOWN = 'down',
  active = nil, events = {},
}

local function use(h, what)
  if h == nil then error(what .. ' on a NIL handle', 0) end
  local o = OBJ[h]
  if o == nil then error(what .. ' on an UNKNOWN handle', 0) end
  if not o.alive then error(what .. ' on a DELETED object (dangling handle)', 0) end
  return o
end

-- POOL EXHAUSTION, as the firmware really does it: once the display object pool is gone,
-- display.create returns NIL and posts NOTHING -- event 1701 is logged the first time only -- and it
-- does not raise. MD.poolcap(n) reproduces that, so the build's refusal is testable without spending
-- a power cycle on the bench.
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
    -- JUSTIFICATION IS RECORDED. Dropping it is what made the overlap check in test_serial blind to
    -- a JUST_RIGHT object: with x read as a left edge, the page counter appeared to sit off the
    -- right of the panel and could collide with nothing.
    o.x, o.y, o.text, o.color, o.font, o.just = a, b, c, d, e, f
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
  elseif kind == display.OBJ_LINE then
    -- (x, y, x2, y2) -- ENDPOINTS, not a width and height. Held as both so a geometry check can
    -- treat a line like any other extent.
    o.x, o.y, o.x2, o.y2 = a, b, c, d
    o.w, o.h = (c or a) - a + 1, (d or b) - b + 1
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
-- The second colour is a rect's BACKGROUND -- what shows through the part a partial fill has not
-- covered. Recorded, not dropped, so a test can tell an empty progress bar from a hidden one.
function display.setcolor(h, c, c2)
  local o = use(h, 'setcolor')
  o.color = c
  if c2 ~= nil then o.color2 = c2 end
end
-- setfill's argument is a PERCENTAGE, 0..100. Anything else is refused by the firmware
-- with "1130 Parameter fill percent, expected value from 0 to 100".
--
-- THE RANGE IS ENFORCED HERE BECAUSE A LAX MOCK HIDES THE BUG ENTIRELY. Accept any number and a
-- 24-bit COLOUR passed to setfill looks fine offline while the instrument rejects every call -- fast
-- enough to raise a MODAL ERROR DIALOG over the app's own hex dump. Enforcing it makes the mistake
-- unrepresentable: a colour passed here fails a test instead of a panel.
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
-- THE THICKNESS CEILING IS 10, and passing 12 is not a silent no-op: the firmware refuses with
-- "1130 Parameter thickness, expected value from 1 to 10" at a severity that raises a MODAL DIALOG
-- over the app's own panel, which has to be dismissed by hand. It happened while measuring the
-- progress bar. Enforced here so an over-thick line fails a test instead of a bench session.
--
-- pcall DOES NOT CATCH IT ON THE INSTRUMENT -- the refusal arrives as a queued event, so the call
-- returns true and the dialog appears anyway. Offline is the only place this can be caught cheaply.
function display.setthickness(h, t)
  local o = use(h, 'setthickness')
  if type(t) ~= 'number' or t < 1 or t > 10 then
    error('1130 Parameter thickness, expected value from 1 to 10, got ' .. tostring(t), 0)
  end
  o.thick = t
end

-- Move or resize an object. RECT, LINE, CIRCLE and IMAGE only: on an OBJ_EDIT_* the instrument
-- answers "1717 Attribute position does not apply to an object of type EditNumber" -- again as a
-- queued event a pcall cannot see, and again as a modal dialog. Measured while trying to widen the
-- options fields, which is why those cannot be widened at all.
function display.setposition(h, x, y, c, d)
  local o = use(h, 'setposition')
  if o.kind ~= display.OBJ_RECT and o.kind ~= display.OBJ_LINE then
    error('1717 Attribute position does not apply to an object of type ' .. tostring(o.kind), 0)
  end
  o.x, o.y = x, y
  if o.kind == display.OBJ_LINE then
    o.x2, o.y2 = c, d
    o.w, o.h = (c or x) - x + 1, (d or y) - y + 1
  else
    o.w, o.h = c or o.w, d or o.h
  end
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

-- DIRECTORIES, because an open into one that does not exist has to FAIL here or the app's mkdir is
-- untestable offline: a mock that accepts every path passes whether or not the directory was ever
-- created, which is the same as not testing it. The key's root always exists.
local DIRS = {['/usb1'] = true}
-- mkdir takes a bare name in the reference's own example and an absolute path in its Details, so both
-- are accepted and normalised the same way -- a bare name is relative to the key's root.
local function abs(p)
  p = tostring(p)
  if string.sub(p, 1, 1) ~= '/' then p = '/usb1/' .. p end
  return (string.gsub(p, '/$', ''))
end
local function parentof(path)
  local d = string.gsub(tostring(path), '/[^/]*$', '')
  if d == '' then return '/' end
  return d
end
-- MODELLED FROM THE INSTRUMENT, NOT THE MANUAL. Measured on firmware 1.7.17a: file.mkdir never raises
-- and returns nothing -- pcall reports ok=true even for calls that did nothing at all. A failure POSTS
-- EVENT 2208 instead, which pcall cannot see or suppress, and which pops up on the operator's panel.
-- The failing cases are a name that already exists, a BARE relative name, and no key.
--
-- EVENTS ARE COUNTED HERE BECAUSE THEIR ABSENCE IS THE REQUIREMENT. The instrument must never pop an
-- error at the operator, so 'how many did we cause' is the property under test -- and a mock that only
-- modelled success could not express it. Opening a missing path posts 2205 the same way.
local EVENTS = {}
local function post(code)
  EVENTS[table.getn(EVENTS) + 1] = code
end
function file.mkdir(path)
  local p = tostring(path)
  if not USB then post(2208); return end
  if string.sub(p, 1, 1) ~= '/' then post(2208); return end     -- bare names always fail
  if DIRS[p] then post(2208); return end                        -- and so does one that exists
  -- ONE level only: the firmware creates a directory, not a path of them.
  if not DIRS[parentof(p)] then post(2208); return end
  DIRS[p] = true
end
function file.usbdriveexists() if USB then return 1 end return 0 end
-- What the app actually created, so a test can assert the directory rather than infer it.
function MD.dirs() return DIRS end
function MD.rmdir(path) DIRS[abs(path)] = nil end
-- Posted instrument events, so a test can require that the quiet path really is quiet.
function MD.fevents() return EVENTS end
function MD.forget_fevents() EVENTS = {} end
function MD.fevent_count(code)
  local n, i = 0, nil
  for i = 1, table.getn(EVENTS) do
    if code == nil or EVENTS[i] == code then n = n + 1 end
  end
  return n
end

-- A DIRECTORY OPENS FOR READ AND YIELDS ITS RAW FAT TABLE on this firmware -- measured: /usb1 returns
-- 65536 bytes of directory entries, with 8.3 names in plain ASCII and long names as UTF-16LE fragments.
-- That is the only silent way to ask whether a directory exists, so the mock has to provide it or the
-- app's one safe path is untestable. Synthesised rather than byte-accurate: it carries each child's name
-- in both forms, which is what a name search actually reads.
local function fat_table(dir)
  local out, k = '', nil
  local pfx = dir
  if string.sub(pfx, -1) ~= '/' then pfx = pfx .. '/' end
  local function addname(nm)
    local wide, i = '', nil
    for i = 1, string.len(nm) do wide = wide .. string.sub(nm, i, i) .. string.char(0) end
    out = out .. string.upper(nm) .. '    ' .. wide .. string.char(0) .. '  '
  end
  for k in pairs(DIRS) do
    if k ~= dir and string.sub(k, 1, string.len(pfx)) == pfx then
      addname(string.gsub(string.sub(k, string.len(pfx) + 1), '/.*$', ''))
    end
  end
  for k in pairs(FILES) do
    if string.sub(k, 1, string.len(pfx)) == pfx then
      addname(string.gsub(string.sub(k, string.len(pfx) + 1), '/.*$', ''))
    end
  end
  -- PADDED, BECAUSE THE REAL TABLE IS NEVER EMPTY. Measured: /usb1 returns 65536 bytes whatever it
  -- holds, since a FAT directory is a fixed allocation of mostly-blank entries. An empty string here
  -- would come back from READ_ALL as nil -- 'the root could not be read' -- and an EMPTY directory would
  -- then be indistinguishable from an unreadable one, which is precisely the distinction the app relies
  -- on to decide whether creating is safe.
  return out .. string.rep(string.char(0), 64)
end

function file.open(path, mode)
  -- NO KEY POSTS 2205 TOO. Measured: with the key out even /usb1 is 'File not found', so a mock that
  -- returned a quiet nil here hid every open the app performs without a key -- which is exactly the class
  -- of leak the event counter exists to catch.
  if not USB then post(2205); return nil end
  -- A missing parent fails EVERY mode, including READ. A filesystem cannot hold /usb1/SERDEC/x
  -- while /usb1/SERDEC is absent, so letting a seeded file stay readable through a deleted
  -- directory would model something the instrument cannot do -- and it would do it in the app's favour,
  -- which is worse than not modelling directories at all.
  if not DIRS[parentof(path)] and not DIRS[path] then post(2205); return nil end
  if mode == file.MODE_READ then
    -- The directory case first: a handle whose contents are the listing.
    if DIRS[path] then
      nextfh = nextfh + 1
      RPOS[nextfh] = {path = path, pos = 1, listing = fat_table(path)}
      return nextfh
    end
    if FILES[path] == nil then post(2205); return nil end
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
  -- AND THE DIRECTORIES, because "different key" means a key with no SERDEC on it. Keeping DIRS
  -- across the wipe made the swap unmodellable: every path stayed openable, so the one case this
  -- harness exists to reach -- a second key, mid-session, with the app holding an allocated name from
  -- the first -- silently could not happen.
  DIRS = {['/usb1'] = true}
  -- AND THE APP'S CACHES, both of them, for the reason already given above about idx_ram: a cache that
  -- outlives the filesystem describes a key that is no longer there. ulog.dirok is the same shape of
  -- claim -- 'the directory exists' -- so a fresh key must invalidate it too, which is what makes this
  -- 'a new key in the slot before the app starts' rather than 'a key swapped under a running app'. The
  -- second of those is unsupported and is modelled by leaving dirok alone; see the swap tests.
  if ulog ~= nil then ulog.idx_ram = nil; ulog.dirok = nil end
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
  -- A directory handle reads back its listing, not file content: that is how the app asks whether a
  -- directory exists without risking an event.
  local body = r.listing or CONTENT[r.path] or ''
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

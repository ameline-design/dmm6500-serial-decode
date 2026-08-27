-- mockup.lua -- record what the REAL tsp/serial_ui.tsp builds, for rendering.
--
-- Runs sdec.ui_build() and sdec.build_options() against a display mock that
-- RECORDS every object's type, position, size, colour, font and text, and writes
-- the result as TSV. A hand-made mockup drifts from the code the moment either
-- changes; this cannot, and it doubles as a geometry check -- anything outside the
-- 798x420 object area, or a button clipped by the 431 px content height, is
-- reported here rather than found on the instrument.
--
-- Run from the repo root:  lua tools/mockup.lua
--   then:                  python3 tools/render_png.py panel
--
-- Writes docs/mockup-objects-{text,hex,opts}.tsv. Drawing is left to
-- render_png.py, which uses PIL: macOS has no reliable SVG rasteriser.

table.getn = table.getn or function(t) return #t end
math.mod   = math.mod   or math.fmod

-- ---------- recording display mock ----------
local OBJ, nobj = {}, 0
local SCREENS = {}
local active = nil

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
  FILL_LEFT = 'left', FILL_RIGHT = 'right', FILL_UP = 'up', FILL_DOWN = 'down',
}

function display.create(parent, kind, a, b, c, d, e, f, g, h, i, j, k, l, m, n)
  -- Mirror the firmware limit: a width outside 1..799 returns nil rather than
  -- raising, so the object silently does not exist.
  -- For a button the args are (x, y, text, width), so the width is `d`, not `c`.
  if kind == display.OBJ_BUTTON and d ~= nil and (d < 1 or d > 799) then return nil end
  nobj = nobj + 1
  local o = {id = nobj, kind = kind, parent = parent, alive = true}
  if kind == display.OBJ_SCREEN then
    o.title = a
    SCREENS[table.getn(SCREENS) + 1] = o
  elseif kind == display.OBJ_TEXT then
    o.x, o.y, o.text, o.color, o.font, o.just = a, b, c, d, e, f
  elseif kind == display.OBJ_BUTTON then
    o.x, o.y, o.text, o.w = a, b, c, d
  elseif kind == display.OBJ_RECT then
    o.x, o.y, o.w, o.h = a, b, c, d
  elseif kind == display.OBJ_LINE then
    -- (x, y, x2, y2). w/h are derived so the geometry check below sees a line's extent like any
    -- other object's; the renderer strokes it from the endpoints and the thickness.
    o.x, o.y, o.x2, o.y2 = a, b, c, d
    o.w, o.h = (c or a) - a + 1, (d or b) - b + 1
  elseif kind == display.OBJ_EDIT_NUMBER then
    o.x, o.y, o.label, o.desc, o.value, o.units = a, b, c, d, f, i
  elseif kind == display.OBJ_EDIT_OPTION then
    o.x, o.y, o.label, o.desc = a, b, c, d
    o.opts = {e, f, g, h, i, j, k, l, m, n}
    o.value = 1
  elseif kind == display.OBJ_EDIT_CHECK then
    -- (parent, type, x, y, label, description, [default]) -- default is 0 or 1
    o.x, o.y, o.label, o.desc, o.value = a, b, c, d, e or 0
  end
  OBJ[nobj] = o
  return nobj
end

function display.delete(id)
  local o = OBJ[id]
  if o == nil then error('delete of unknown object', 0) end
  o.alive = false
  local k, c
  for k, c in pairs(OBJ) do if c.parent == id then c.alive = false end end
end
function display.changescreen(id) active = id end
function display.settext(id, s)
  local o = OBJ[id]
  if o == nil or not o.alive then error('settext on a dead object', 0) end
  o.text = s
end
-- The second colour is a rect's BACKGROUND -- what shows through the part a partial fill leaves.
function display.setcolor(id, c, c2)
  if OBJ[id] then
    OBJ[id].color = c
    if c2 ~= nil then OBJ[id].color2 = c2 end
  end
end
-- FILL IS A PERCENTAGE, 0..100, and on this firmware it has NO VISIBLE EFFECT on a rect. Recorded
-- anyway: the renderer uses `fill >= 0` to mean "this rect was set up", and a later firmware may
-- honour the number.
function display.setfill(id, pct, dir)
  if OBJ[id] then
    OBJ[id].fill = pct
    OBJ[id].filldir = dir
  end
end
-- A rect's border width and a line's stroke width. 1..10 on the instrument.
function display.setthickness(id, t) if OBJ[id] then OBJ[id].thick = t end end
-- Move or resize. The progress bar's line is the only object the app repositions.
function display.setposition(id, x, y, c, d)
  local o = OBJ[id]
  if o == nil then return end
  o.x, o.y = x, y
  if o.kind == display.OBJ_LINE then
    o.x2, o.y2 = c, d
    o.w, o.h = (c or x) - x + 1, (d or y) - y + 1
  else
    o.w, o.h = c or o.w, d or o.h
  end
end
-- STATE_INVISIBLE is how the app hides a rect or a line -- recolouring does not work on the panel.
-- Recorded so the renderer can leave a hidden object off the mockup.
display.STATE_ENABLE, display.STATE_INVISIBLE = 'enable', 'invisible'
function display.setstate(id, st) if OBJ[id] then OBJ[id].state = st end end
function display.setvalue(id, v) if OBJ[id] then OBJ[id].value = v end end
function display.getvalue(id) if OBJ[id] then return OBJ[id].value end end
function display.setevent(id, ev, cmd)
  if OBJ[id] == nil then error('setevent on a nil object', 0) end
  OBJ[id].ev = cmd
end

-- ---------- USB present, so the log status line shows the real case ----------
file = {MODE_APPEND = 'a', MODE_WRITE = 'w', MODE_READ = 'r'}
local LOGLINES = 0
-- MODE_READ returns NIL: that is what an empty USB key looks like, and it is what
-- ulog.next_free() probes with. Returning a handle for reads as well made every candidate
-- name look taken, so next_free() ran out and the panel showed
-- 'NOTE: no free /usb1/streamNN.txt name' in a mockup that was supposed to show a filename.
function file.open(path, mode)
  if mode == file.MODE_READ then return nil end
  return 7
end
function file.write(h, s) LOGLINES = LOGLINES + 1 end
function file.flush(h) end
function file.close(h) end

-- ---------- waveform + instrument mocks, and the real modules ----------
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

-- ---------- machine-readable object dump ----------
-- One row per object: which screen it belongs to, its type, geometry, font,
-- colour, fill and text. tools/render_png.py draws the panel from this.
--
-- Tab-separated because decoded serial text is full of commas, so a comma
-- delimiter would need quoting and escaping. `text` is deliberately the LAST
-- column: an edit object packs label, description and value into it separated by
-- further tabs, and the reader rejoins everything from column 10 onward.
local function dumpobjs(path)
  local f = io.open(path, 'w')
  -- `just` sits BEFORE text on purpose: text is the last column because it may itself contain tabs
  -- (an edit object packs label/desc/value into it), so anything after it could not be parsed out.
  f:write('screen\tkind\tx\ty\tw\th\tfont\tcolor\tfill\tjust\tthick\tstate\ttext\n')
  local i
  for i = 1, nobj do
    local o = OBJ[i]
    -- ONLY LIVE OBJECTS. The mock keeps deleted ones in OBJ with alive=false so that touching a
    -- dangling handle can raise, which is the point of it -- but a dump that includes them
    -- renders every build that ever existed on top of itself. Seen the moment a scenario needed
    -- ui_destroy/ui_build to change the row count: the 14-row screen came out with the 15-row
    -- screen's text overlaid, doubled offsets, and two status lines in the same box.
    if o ~= nil and o.alive and o.kind ~= display.OBJ_SCREEN then
      local scr = OBJ[o.parent]
      local title = ''
      if scr ~= nil and scr.title ~= nil then title = scr.title end
      local txt = o.text
      if o.kind == display.OBJ_EDIT_NUMBER then
        txt = tostring(o.label) .. '\t' .. tostring(o.desc) .. '\t'
              .. tostring(o.value) .. ' ' .. tostring(o.units or '')
      elseif o.kind == display.OBJ_EDIT_OPTION then
        txt = tostring(o.label) .. '\t' .. tostring(o.desc) .. '\t'
              .. tostring(o.opts[o.value or 1] or o.opts[1] or '')
      elseif o.kind == display.OBJ_EDIT_CHECK then
        -- The renderer draws a tick box from this, so the value travels as ON/OFF rather
        -- than as a rendered glyph the dump would have to guess at.
        txt = tostring(o.label) .. '\t' .. tostring(o.desc) .. '\t'
              .. ((o.value == 1) and 'ON' or 'OFF')
      end
      -- HIDDEN OBJECTS ARE DROPPED, not dumped dark. STATE_INVISIBLE is how the app takes a rect or
      -- a line off the glass, so rendering one would put the progress bar in every mockup that has
      -- no run in progress -- which is the bug it had on the instrument.
      if o.state ~= display.STATE_INVISIBLE then
      f:write(string.format('%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n',
        title, tostring(o.kind), tostring(o.x or 0), tostring(o.y or 0),
        tostring(o.w or 0), tostring(o.h or 0), tostring(o.font or 1),
        tostring(o.color or 16777215), tostring(o.fill or -1),
        tostring(o.just or 0), tostring(o.thick or 1), tostring(o.state or 'enable'),
        tostring(txt or '')))
      end
    end
  end
  f:close()
  print('wrote ' .. path)
end

-- Panel geometry the check below needs: object y = 0 is 49 px below the panel top,
-- so the usable content height is 480 - 49 = 431 px.
local PANEL_H, Y_OFFSET = 480, 49

-- ---------- drive the app with a realistic capture ----------
-- A payload that exercises the interesting cases in one screen: printable text, a
-- CR/LF pair and a NUL that must render as '.', and enough bytes to need paging.
local PAYLOAD = 'GPS: $GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M*47\r\n'
              .. 'Temp=21.5C Hum=48% Batt=3.97V OK\r\n'
local pb, pn = GEN_BYTES(PAYLOAD)
local rd, ts, nc, nsmp = GEN({bytes = pb, baud = 9600, fs = 100000, lead = 30,
                              noise = 0.05})
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
sdec.fs, sdec.n, sdec.trigmode = 100000, 20000, 'free'

local ok, err = sdec.start()
if not ok then print('start() failed: ' .. tostring(err)) end
print(string.format('decoded %d bytes, %d framing errors, %s, %s',
      sdec.res and sdec.res.nf or 0, sdec.res and sdec.res.nbad or -1,
      sdec.baud_text(), sdec.fmt_text()))

-- Find the main and options screens by title.
local main, opts
local i
for i = 1, table.getn(SCREENS) do
  local s = SCREENS[i]
  -- PREFIX, NOT EQUALITY. The title bar carries the capture mode too -- 'SERIAL DECODE - 240B
  -- FRAME' -- so an exact match against sdec.ui_title finds no main screen at all and every dump
  -- comes out empty.
  if string.sub(s.title or '', 1, string.len(sdec.ui_title)) == sdec.ui_title then main = s end
  if s.title == 'SERIAL DECODE OPTIONS' then opts = s end
end

dumpobjs('docs/mockup-objects-text.tsv')

-- THE FIT AND S/N BANDS, forced -- SIX SCREENS, one per colour per field. A clean synthesised
-- capture is 41 dB at fitq 1.00, so the amber and red bands are unreachable from the mock's own
-- signal and would ship unseen. ONE FIELD MOVES AT A TIME, the other held green, so each cell is
-- shown banding on its own rather than the pair always agreeing. Set on the values the cells read --
-- sdec.snr_db and sdec.fitq -- so ui_field_colour is exercised rather than bypassed.
local keep_sn, keep_q = sdec.snr_db, sdec.fitq
local bands = {
  {'fit-green', 41, 1.00},   -- FIT >= ui_fit_good
  {'fit-amber', 41, 0.83},   -- FIT in ui_fit_bad..ui_fit_good
  {'fit-red',   41, 0.61},   -- FIT < ui_fit_bad
  {'sn-green',  41, 1.00},   -- S/N >= ui_sn_good
  {'sn-amber',  18, 1.00},   -- S/N in ui_sn_bad..ui_sn_good
  {'sn-red',     9, 1.00},   -- S/N < ui_sn_bad
}
local bi
for bi = 1, table.getn(bands) do
  sdec.snr_db, sdec.fitq = bands[bi][2], bands[bi][3]
  sdec.ui_refresh()
  dumpobjs('docs/mockup-objects-' .. bands[bi][1] .. '.tsv')
end
sdec.snr_db, sdec.fitq = keep_sn, keep_q
sdec.ui_refresh()

sdec.view_toggle()
dumpobjs('docs/mockup-objects-hex.tsv')

sdec.ui_mode = 'text'
sdec.ui_refresh()
-- Seed the form the way a button press does, so the mockup shows the values that
-- are actually in effect rather than each field's create-time default.
sdec.options()
dumpobjs('docs/mockup-objects-opts.tsv')

-- BOTH REAR FUNCTIONS ON, because that is the state that changes behaviour and it is the entry
-- that did not exist before: 'Trig In + FC Out'. The field carries two orthogonal booleans as four
-- entries -- the rear BNC input OR'd into whatever the Trigger field selects, and the rear BNC
-- output pulsed as a flow-control credit after each window. An 'Off' render would only show that
-- the control exists.
sdec.trigext, sdec.fc_out = true, true
sdec.trigmode = 'edge'
sdec.options_seed()
dumpobjs('docs/mockup-objects-opts-ext.tsv')
sdec.trigext, sdec.fc_out = false, false
sdec.trigmode = 'free'
sdec.options_seed()

-- ---------- MIDI message view ----------
-- A separate capture at 31250 baud, driven the way the operator would: choose MIDI on
-- the form, which forces the wire parameters and switches to the message list.
local MIDI = {0xF8,                          -- clock
              0x90, 0x3C, 0x64,              -- note on  C4 vel 100
              0x40, 0x58, 0x43, 0x60,        -- running status: E4, G4
              0xB0, 0x07, 0x50,              -- CC7 volume 80
              0xE0, 0x00, 0x60,              -- pitch bend +4096
              0xF0, 0x43, 0x10, 0x4C, 0xF7,  -- Yamaha SysEx
              0x80, 0x3C, 0x40, 0xFE,        -- note off, active sensing
              0xC2, 0x04}                    -- program change
local mrd, mts, mnc, mnsmp = GEN({bytes = MIDI, baud = 31250, fs = 500000,
                                  lead = 20, gap = 3, noise = 0.04})
SRC.rd, SRC.ts, SRC.nsmp = mrd, mts, mnsmp
sdec.fs = 500000
display.setvalue(sdec.opt_proto, 2)          -- MIDI
sdec.options_apply()
print(string.format('MIDI: %d bytes, %s, %s', sdec.res and sdec.res.nf or 0,
      sdec.baud_text(), sdec.midi and sdec.mi_summary() or 'no messages'))
dumpobjs('docs/mockup-objects-midi.tsv')

-- ---------- LIN frame view ----------
-- A LIN bus, driven the same way: choose LIN on the form, which pins 8N1 and normal
-- polarity but deliberately leaves the baud rate to the auto-detector -- LIN specifies
-- 1 to 20 kBd, a range, not a rate. The levels are 0 / 6 V, a 12 V bus seen through the
-- 2:1 divider the app asks for (docs/lin-divider-panel.png).
--
-- The frame list is the interesting screen: a header the schedule reached with nothing
-- answering, a diagnostic frame that must use the classic checksum, and a frame whose
-- checksum fails -- which is the row that goes red.
local LINF = {
  {id = 0x11, data = {0xA1, 0xB2, 0xC3, 0xD4}},
  {id = 0x22, data = {0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34}},
  {id = 0x2C, nodata = true},
  {id = 0x3C, data = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}, classic = true},
  {id = 0x05, data = {0x5A, 0xA5}, csum = 0x37},
  {id = 0x11, data = {0xA2, 0xB3, 0xC4, 0xD5}},
}
local lrd, lts, lnc, lnsmp = GEN_LIN({frames = LINF, baud = 19200, fs = 200000,
                                      noise = 0.04})
SRC.rd, SRC.ts, SRC.nsmp = lrd, lts, lnsmp
sdec.fs = 200000
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('lin'))
sdec.options_apply()
print(string.format('LIN: %d bytes, %s, %s', sdec.res and sdec.res.nf or 0,
      sdec.baud_text(), sdec.lin and sdec.li_summary() or 'no frames'))
dumpobjs('docs/mockup-objects-lin.tsv')

-- ---------- the three capture modes ----------
-- Mode cycles FRAME / 32 kB. The MODE cell at top-left carries the name in a
-- per-mode colour, which is the at-a-glance channel; the status row says it in words.
-- Five dumps, because each shows something the others cannot:
--
--   frame-log    FRAME, with the message log accumulating -- what frame mode does
--   stream-arm   32 kB selected and ARMED, before Capture: what "ready" looks like
--   stream-run   mid-recording: the buffer percentage, and both controls named on the right
--   stream-done  finished at the cap, five-digit BYTES, and the note reconciling it with a
--                panel showing 97
--   stream-gate  32 kB selected with no locked baud: the refusal and its remedy
--
-- Back to a UART text capture first: the LIN run above left 19200 8N1 and a LIN view.
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
sdec.fs = 100000
display.setvalue(sdec.opt_proto, sdec.opt_proto_i('uart'))
sdec.options_apply()

sdec.capmode = 'frame'
sdec.ui_mode = 'text'
sdec.flog_path = '/usb1/frames00.txt'
sdec.flog_n = 7
sdec.ui_refresh()
print(string.format('FRAME: %d bytes -> %s   padlock=%s', sdec.res and sdec.res.nf or 0,
      tostring(sdec.flog_path), sdec.lock_state()))
dumpobjs('docs/mockup-objects-frame-log.tsv')

-- The external trigger armed: the right-hand cell names it and turns amber, because a capture
-- waiting on an edge that never arrives is otherwise indistinguishable from a hang.
sdec.trigext = true
sdec.ui_refresh()
print('FRAME + EXT TRIG mockup written')
dumpobjs('docs/mockup-objects-frame-exttrig.tsv')
sdec.trigext = false
sdec.ui_refresh()

-- The padlock's third state: nothing decoded, so there is nothing to lock. Red. Its own dump,
-- because a tri-colour indicator whose colours are never all rendered is a tri-colour
-- indicator that has only been reasoned about.
sdec.clear_result()
sdec.ui_status = 'no decode'
sdec.ui_refresh()
print('FRAME, nothing decoded: padlock=' .. sdec.lock_state())
dumpobjs('docs/mockup-objects-frame-nolock.tsv')

-- And LOCKED: green, with the values in green too as the second channel. NO TOGGLE HERE -- capture()
-- autolocks, so the state after it IS locked; toggling first rendered the amber auto state into the
-- file named "locked", which left the green colour never rendered at all.
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
sdec.capture()
sdec.ui_refresh()
print(string.format('FRAME, locked: padlock=%s  %s %s', sdec.lock_state(),
      sdec.baud_text(), sdec.fmt_text()))
dumpobjs('docs/mockup-objects-frame-locked.tsv')
sdec.lock_toggle()          -- back to auto for the scenarios below
sdec.flog_path, sdec.flog_n, sdec.flog_bytes = '/usb1/bytes000.txt', 7, 1743

-- 32 kB armed but not started. Worth its own dump: it is the state an operator sees after
-- locking the rate and pressing Mode, and it must read as "ready", not as "nothing happened".
sdec.capmode = 'med'
sdec.force_baud = 9600
sdec.ck_running, sdec.ck_nbytes, sdec.ck_tot = false, nil, nil
sdec.ui_status = 'ready'
sdec.ui_refresh()
print('32 kB armed: ' .. sdec.ck_status())
dumpobjs('docs/mockup-objects-stream-arm.tsv')

-- Mid-RECORDING. Nothing has been decoded yet -- the digitizer is filling the buffer in
-- hardware -- so the honest number is percent of the buffer, not a byte count, and the state
-- must be cleared, or the mockup shows text left over from the previous capture.
sdec.clear_result()
sdec.baud, sdec.bittime, sdec.fitq = 9600, 10.42, 1.0
sdec.acq_fs, sdec.fs = 100000, 100000
sdec.ck_running, sdec.ck_nbytes, sdec.ck_tot = true, nil, nil
sdec.ck_acq_have, sdec.ck_acq_want = 1043000, 2800000
sdec.ui_status = 'capturing'
sdec.ui_refresh()
print('32 kB recording: ' .. sdec.ck_status())
dumpobjs('docs/mockup-objects-stream-run.tsv')

-- Finished at the cap. ck_running MUST be cleared before this capture, or Capture reads the press
-- as Stop and renders that instead.
sdec.ck_running, sdec.ck_stop = false, false
SRC.rd, SRC.ts, SRC.nsmp = rd, ts, nsmp
sdec.capmode = 'frame'
sdec.capture()
sdec.capmode = 'med'
sdec.ck_nbytes = 32768
sdec.ck_tot = {nf = 32768, nbad = 3, nwin = 143, nsmp = 2764800,
               stopped = 'cap', path = '/usb1/stream00.txt'}
sdec.ui_status = 'done'
sdec.ui_refresh()
print('32 kB done: ' .. sdec.ck_summary(sdec.ck_tot))
dumpobjs('docs/mockup-objects-stream-done.tsv')

-- THE RESTING STATE AFTER A RECORDING, and the one an operator actually reads: capture() lands in
-- FRAME with the retained tail on screen (sdec.res = ck_tot.tail), paged. The mockup above holds
-- res at the 97-byte frame capture, which cannot show the paging at all.
--
-- sdec.ck_keep bytes, carrying `first` and `ntotal` exactly as ck_tail_result() builds them -- which
-- is what lets ui_notes() tell a tail from a frame capture, and what puts the page count on screen.
do
  local keep = sdec.ck_keep
  local tail = {nf = keep, ngood = keep, nbad = 0, nfalse = 0, vals = {}, errs = {}, tpos = {},
                first = 32768 - keep + 1, ntotal = 32768,
                nbits = 8, par = sdec.PAR_NONE, nstop = 1, framebits = 10}
  local ti
  for ti = 1, keep do tail.vals[ti] = 32 + math.mod(ti * 7, 95) end
  sdec.capmode = 'frame'
  sdec.res = tail
  sdec.ui_mode = 'hex'
  sdec.ui_page = 0
  -- AS IF THE OPERATOR HAD PRESSED Dn. The counter is latched on a page press, so a scenario that
  -- only sets ui_page renders a blank note row and the mockup would show a paged screen with no
  -- indication that paging is even possible.
  sdec.ui_paged = true
  sdec.ui_refresh()
  print(string.format('recording tail: %d bytes kept of %d, %d pages, indicator %q',
        tail.nf, tail.ntotal, sdec.ui_npages(), tostring(sdec.ui_pgindtxt)))
  dumpobjs('docs/mockup-objects-stream-tail.tsv')
end

-- The recording mode with the rate back on auto: the gate, stated before anything is attempted.
sdec.capmode = 'med'
sdec.force_baud = nil
sdec.clear_result()
sdec.ck_running, sdec.ck_nbytes, sdec.ck_tot = false, nil, nil
sdec.ui_status = 'ready'
sdec.ui_refresh()
print('recording gate: ' .. tostring(sdec.mode_why()))
dumpobjs('docs/mockup-objects-stream-gate.tsv')

sdec.capmode = 'frame'

-- THE TWO LOSS REGIMES. These are the states that decide whether the app is keeping its central
-- promise, and neither had a mockup: at a fast locked rate the decode between windows cannot keep up
-- with the wire, so either the device waits for a flow-control credit or traffic is lost between
-- windows. The panel has to say which.
sdec.clear_result()
sdec.capmode = 'med'
sdec.force_baud, sdec.force_nbits = 115200, 8
sdec.force_par, sdec.force_nstop, sdec.force_invert = sdec.PAR_NONE, 1, false
sdec.baud, sdec.bittime, sdec.fitq, sdec.snapped = 115200, 4.34, 1.0, true
sdec.acq_fs, sdec.fs = 500000, 500000
sdec.lo, sdec.hi, sdec.family, sdec.thr = 0, 3.3, '3V3 CMOS', 1.65
sdec.ck_running, sdec.ck_nbytes, sdec.ck_tot = false, nil, nil
sdec.ui_status = 'ready'

sdec.fc_out = false
sdec.ui_refresh()
print('losing:        ' .. tostring(sdec.ui_note_text()))
dumpobjs('docs/mockup-objects-fc-losing.tsv')

sdec.fc_out = true
sdec.ui_refresh()
print('flow-controlled: ' .. tostring(sdec.ui_note_text()))
dumpobjs('docs/mockup-objects-fc-ok.tsv')
sdec.fc_out = false

-- ---------- FULL SCREENS OF HEX, at 14 rows and at 15 ----------
-- The point of these two is to be judged side by side, so the only thing allowed to differ is
-- the row count. Same payload, same rate, same everything else.
--
-- Captured at 80 kS/s rather than the 100 kS/s used above, because that is the rate the
-- candidate ladder picks for 9600 (8.33 samples/bit) and it is what makes 20 000 samples hold
-- 240 bytes -- exactly 15 rows. At 100 kS/s the window is 192 bytes and neither screen would
-- fill, which would make the comparison meaningless.
-- gap = 0 and a 260-byte payload, both deliberate. The default 2-bit inter-byte gap makes a
-- frame 12 bit times rather than 10, which costs a sixth of the window: 199 bytes, leaving the
-- bottom three rows of the 14-row screen empty -- and a full screen is the one thing these two
-- mockups exist to show. A back-to-back stream is also the realistic case for a
-- device that is actually busy.
--
-- n = 21000, not 20000: 21000 / (8.33 x 10) is 252 bytes, enough to fill 240 with headroom, so
-- BOTH screens are completely full and the comparison is about the layout rather than about
-- which one happened to run out of data first.
local LOREM = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
           .. 'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, '
           .. 'quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo do. '
           .. 'Duis aute irure dolor in reprehenderit in voluptate velit esse cillum. '
local lb, ln = GEN_BYTES(LOREM)
local lrd, lts, lnc, lnsmp = GEN({bytes = lb, baud = 9600, fs = 80000, lead = 6,
                                  gap = 0, noise = 0.05})
SRC.rd, SRC.ts, SRC.nsmp = lrd, lts, lnsmp
sdec.fs, sdec.n = 80000, 21000
sdec.force_baud, sdec.force_nbits = 9600, 8
sdec.force_par, sdec.force_nstop = sdec.PAR_NONE, 1
-- POLARITY FORCED TOO, and it has to be. gap = 0 means the line is never idle between bytes, so
-- sig_idle has almost nothing to measure and picked LOW -- which decodes the whole capture
-- inverted: 250 plausible-looking bytes of garbage, 2 framing errors, and an ASCII column of
-- punctuation. A back-to-back stream genuinely is ambiguous about which level is idle; the real
-- operator resolves it with the Logic field, and so does this mockup.
sdec.force_invert = false

local function fullhex(nrow, pitch, path)
  -- ui_nrow sizes the row arrays at BUILD time, so a row-count change needs a real rebuild --
  -- destroy, then build. Exactly what the instrument would need a power cycle for, and the one
  -- place the mock is more permissive than the firmware.
  sdec.ui_destroy()
  sdec.ui_nrow, sdec.ui_row_dy = nrow, pitch
  sdec.ui_sb_n = nrow
  -- The band and the button row sit below the dump, so they move with it -- using THE APP'S OWN
  -- CLEARANCES, expressed against the last row's ink, so that fullhex(ui_nrow, ui_row_dy) reproduces
  -- the shipped layout exactly rather than a near-miss. Its own arithmetic put the band 10 px low and
  -- 4 px too tall, and left the column separators short of the rule above them -- so the one render
  -- that shows a full page of hex was the one render that did not show the panel.
  local lastink = sdec.ui_row_y0 + (nrow - 1) * pitch
  sdec.ui_stat_top = lastink + 10
  sdec.ui_stat_bot = sdec.ui_stat_top + 19
  sdec.ui_stat_y   = sdec.ui_stat_top + 14
  sdec.ui_btn_y    = sdec.ui_stat_bot + 14
  -- Both ends anchored on the rules they touch, exactly as serial_ui.tsp derives them.
  sdec.ui_vr_y0    = sdec.ui_rule_bot + 1
  sdec.ui_vr_y1    = sdec.ui_stat_top
  sdec.ui_invalidate()
  sdec.ui_build()
  sdec.ui_mode, sdec.ui_page = 'hex', 0
  sdec.ui_refresh()
  print(string.format('%d rows @ %d px: %d bytes/page, %d decoded, buttons %d..%d of 431',
        nrow, pitch, sdec.ui_bytes_per_page(), sdec.res and sdec.res.nf or 0,
        sdec.ui_btn_y, sdec.ui_btn_y + sdec.ui_btn_h))
  dumpobjs(path)
end

local ok2, err2 = sdec.capture()
if not ok2 then print('full-screen capture failed: ' .. tostring(err2)) end
-- 15 rows at an 18 px pitch is the CHOSEN geometry, and 18 px is not a guess: it is the row pitch
-- the instrument's own FFT app uses, measured off docs/panel-ref-chrome.png (see FINDINGS).
fullhex(15, 18, 'docs/mockup-objects-hex15.tsv')

-- ---------- geometry check ----------
print('\ngeometry check (object coordinate limits are X 1..798, Y 0..420):')
local bad = 0
for i = 1, nobj do
  local o = OBJ[i]
  if o ~= nil and o.kind ~= display.OBJ_SCREEN and o.x ~= nil then
    local right = o.x + (o.w or 0)
    -- Buttons are ~58 px tall and the content area is only PANEL_H - 49 = 431 px,
    -- so a button can pass the firmware's Y 0..420 limit and still be clipped off
    -- the bottom of the screen. Check the real extent, not just the origin.
    local h = 0
    if o.kind == display.OBJ_RECT then h = o.h or 0 end
    if o.kind == display.OBJ_BUTTON then h = 58 end
    if o.kind == display.OBJ_EDIT_NUMBER or o.kind == display.OBJ_EDIT_OPTION or
       o.kind == display.OBJ_EDIT_CHECK then h = 38 end
    local bottom = o.y + h
    if o.x < 1 or right > 798 or o.y < 0 or o.y > 420 then
      bad = bad + 1
      print(string.format('  OFF-SCREEN %s at x=%d y=%d right=%d', o.kind, o.x, o.y, right))
    elseif bottom > PANEL_H - Y_OFFSET then
      bad = bad + 1
      print(string.format('  CLIPPED %s at y=%d extends to %d, past the %d px content area',
            o.kind, o.y, bottom, PANEL_H - Y_OFFSET))
    end
  end
end
if bad == 0 then print('  all objects inside the usable area') end

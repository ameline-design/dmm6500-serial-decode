-- Serial_ui.tsp -- front-panel screens for the Keithley TSP serial decoder (TSP / Lua 5.0.2). No
-- '#', no bitwise operators, math.mod for modulo.
--
-- Panel constraints, measured. Coordinates are X 1..798, Y 0..420, and y is relative to the screen
-- content area 49 px below the panel top. display.create returns nil rather than raising when it
-- refuses -- a width of 800 is error 1130, a title over 31 characters is truncated with 1707 -- so a
-- refused object silently does not exist. setposition errors on edit objects, so the options form
-- cannot be re-laid-out; an edit object draws its label left of the value box, so the box x must be
-- >= ~270; OBJ_EDIT_OPTION getvalue/setvalue are 1-based. The font is proportional, so anything
-- that must line up needs its own fixed-x object. docs/MEASUREMENTS.md, 'The panel coordinate space'
-- covers the geometry, and 'Display objects: cost, census and the dump-row choice' the object cost.

sdec = sdec or {}

-- ---------- main screen geometry (object coordinates) ----------
-- The words go in the bar and the colour in the mode cell. mockup.lua and render_png.py identify
-- the main screen by this prefix.
-- docs/UNDOCUMENTED.md, 'display.settext works on an OBJ_SCREEN, and setcolor on one is refused with 1717'.
sdec.ui_title    = 'SERIAL DECODE'

-- ---------- header field strip ----------
-- Dim labels over bright values, each at its own fixed x, because separate objects are the only way
-- to align columns in a proportional font. No rule lands inside a glyph band, which test_serial
-- asserts -- docs/MEASUREMENTS.md, 'Where the header table rules go'.
sdec.ui_ink = 12
sdec.ui_ink_med = 17
sdec.ui_lab_y = 14
sdec.ui_val_y = 32
-- X positions come from the measured label and widest-value widths; render_png.py reports a collision.
sdec.ui_fields = {
  -- `med` keeps FONT_MEDIUM, `wid` is the widest value the column is sized for, `dy` drops it n px.
  {lab = 'BAUD',   x = 8,   c = 0x00DCFF, med = true, dy = 2, wid = '115200'},
  {lab = 'FORMAT', x = 115, c = 0x00DCFF, med = true, dy = 2, labdx = -4, wid = '8N1'},
  {lab = 'IDLE',   x = 188, c = 0xFFFFFF, wid = 'HIGH'},
  {lab = 'LOGIC',  x = 241, c = 0xFFFFFF, wid = '3V3 CMOS'},
  {lab = 'THRESH', x = 334, c = 0xFFFFFF, wid = '-6.00 V'},
  {lab = 'SA/BIT', x = 417, c = 0xFFFFFF, wid = '10.42'},
  {lab = 'RATE',   x = 490, c = 0xFFFFFF, wid = '80 kS/s'},
  -- BYTES must hold six digits: the streaming modes report 32768 and up.
  {lab = 'BYTES',  x = 573, c = 0x80FF80, wid = '999999'},
  {lab = 'ERR',    x = 636, c = 0x80FF80, labdx = -2, wid = '999'},
  {lab = 'FIT',    x = 679, c = 0xFFFFFF, wid = '1.00'},
  -- S/N: the value is unsigned, so bigger is better.
  {lab = 'S/N',    x = 721, c = 0xFFFFFF, wid = '>99 dB'},
}

-- The ink band of one value cell, [top, bottom] inclusive, as one function so the panel and
-- test_serial cannot disagree. It must account for the font and fd.dy, or the tallest cells go
-- unguarded.
function sdec.ui_field_band(j)
  local fd = sdec.ui_fields[j]
  local y = sdec.ui_val_y + (fd.dy or 0)
  local ink = sdec.ui_ink
  if fd.med then ink = sdec.ui_ink_med end
  return y - ink + 1, y
end

-- Measured advances -- docs/MEASUREMENTS.md, 'Character advances on the three panel faces'.
sdec.ui_adv_upper = 10       -- uppercase, measured 9.67 worst case
-- A button face needs len * ui_adv_btn + 8 px to render its label uncut.
sdec.ui_adv_btn = 14
sdec.ui_adv_mixed = 8        -- digits and mixed-case, measured 7.80 worst case
-- The label row, at 66 %. Judged on the LCD rather than in a grab, which flatters a dim grey: the
-- labels stay dimmer than the values they head, but not so dim they have to be hunted for.
sdec.ui_c_lab  = 0xA8A8A8                    -- the label row
-- ---------- lock state ----------
-- Which header fields the operator can assert rather than measure. A forced value looks exactly
-- like a measured one -- lock 9600, probe a 19200 line -- hence the colour channel below.
sdec.ui_lockfields = {baud = 1, fmt = 2, idle = 3}
sdec.ui_c_locked  = 0x40FF40   -- green:  the operator pinned this
sdec.ui_c_auto    = 0xFFC000   -- amber:  the app worked it out
sdec.ui_c_unknown = 0xFF6060   -- red:    nothing to lock -- no decode
-- ERR's index, which lets ui_field_colour be the single writer of every value cell's colour. A
-- second writer with its own cache leaves the loser never repainting: a red error count in green.
sdec.ui_errfield  = 9
-- S/N thresholds are the point of the cell -- docs/MEASUREMENTS.md, 'The S/N cliff is at 12 dB'.
sdec.ui_snfield   = 11
-- FIT bands -- docs/MEASUREMENTS.md, 'Why the FIT bands are 0.90 and 0.72'.
sdec.ui_fitfield  = 10
sdec.ui_fit_good  = 0.90
sdec.ui_fit_bad   = 0.72
-- Above the measured cliff, not on it: red must appear while the capture is still byte-exact.
sdec.ui_sn_good   = 30       -- at or above: green
sdec.ui_sn_bad    = 15       -- below: red. Between the two: amber
sdec.ui_c_sn_ok   = 0x80FF80 -- green:  the same "all clear" green BYTES and ERR carry
sdec.ui_c_sn_warn = 0xFFFF00 -- yellow: margin, but not much
sdec.ui_c_sn_bad  = 0xFF6060 -- red:    the same red ERR goes when it has something to report
-- Rules boxing the strip into a table: thin OBJ_RECTs, created once and never touched again.
sdec.ui_c_rule = 0xA8A8A8
-- The screen background, for hiding an object. It must not be 0: the firmware reads a fill of 0 as
-- "unset" and paints nothing, so setfill(h, 0) climbs sdec.fillfails and changes nothing.
sdec.ui_c_hide = 0x000A0D
sdec.ui_rule_top = 1
-- Between the label ink and the value ink, with one free row either side.
sdec.ui_rule_hdr = 15
sdec.ui_rule_mid = 37                        -- under the value ink (medium 18..34 on the dy cells)
sdec.ui_rule_bot = 56                        -- one clear row under the descender tip at 55
-- The full width the space allows; 797 -- docs/MEASUREMENTS.md, 'The panel coordinate space'.
sdec.ui_rule_x0  = 1
sdec.ui_rule_x1  = 797
sdec.ui_note_lab_x = 8
-- The trigger source, in the note row's left cell. Labels are the option field's own, letter for
-- letter, build_options() creating that field from this table; the keys are sdec.trigmode's values.
sdec.ui_trigsrc = {
  edge  = {name = 'Start bit',   c = 0x40FF40},
  free  = {name = 'Free run',    c = 0xFFFF00},
  front = {name = 'Trigger key', c = 0x00FFFF},
}
-- The trigger-source cell's right edge, and ui_note_px derives from it. test_serial measures every
-- ui_trigsrc label against its rule: render_png.py catches only an overrun of the panel edge.
sdec.ui_note_val_x = 112
-- The page counter shares the note row. X is the right edge of the last of its four pieces.
sdec.ui_pgind_x  = 788
-- Digit columns sized for two digits; a wider count overflows left into the gap.
sdec.ui_pgind_dig = '99'
sdec.ui_pgind_gap = 6
sdec.ui_note_gap = 20

sdec.ui_note_y   = 51
sdec.ui_row_y0   = 71                        -- first dump row
sdec.ui_row_dy   = 18                        -- row pitch (see docs/panel-ref-rows.png)
-- 15 rows x 16 bytes = 240, so a hex page holds an exact number of 16-byte rows.
sdec.ui_nrow     = 15
sdec.ui_stat_y   = 344
-- The status band is boxed like the header strip, so the two do not run together into one wall.
sdec.ui_stat_top = 330   -- above the status ink (333..344)
sdec.ui_stat_bot = 349   -- below it, one clear row under the descender tip at 347
-- A divider before the right-hand cell. ui_vr2_x derives from it, so the two stay one column.
sdec.ui_stat_div = 472
-- ---------- the acquire / decode progress bar ----------
-- A fixed slot in the left status cell: following the progress text would step the bar sideways at
-- 10 % and again at 100 %, movement the eye reads as the thing itself changing. x is measured --
-- docs/MEASUREMENTS.md, 'The progress bar extents'.
sdec.ui_prog_x = 339
-- Every extent below is derived from the three rules that bound the status cell, so moving any of
-- them moves the bar. A literal goes stale silently: the bar is invisible in frame mode.
sdec.ui_prog_y = sdec.ui_stat_top + 2
sdec.ui_prog_h = sdec.ui_stat_bot - 2 - sdec.ui_prog_y + 1
sdec.ui_prog_w = sdec.ui_stat_div - 3 - sdec.ui_prog_x
-- Thickness of the bar; 10 is the firmware's ceiling, which is why the trough is 2 px and not 1.
sdec.ui_prog_lw = 10
-- The bar's travel inside the frame's 1 px border, and the row its thick line is stroked along.
sdec.ui_prog_wmax = sdec.ui_prog_w - 2
sdec.ui_prog_pad  = math.floor((sdec.ui_prog_h - 2 - sdec.ui_prog_lw) / 2)
sdec.ui_prog_ly   = sdec.ui_prog_y + 1 + sdec.ui_prog_pad + math.floor(sdec.ui_prog_lw / 2)
-- The rear BNC gets its own cell, so what the app writes and what its back panel does are not two
-- unrelated facts in one box. Its labels lost the 'ext' because the cell is 1 px too narrow for it.
sdec.ui_trig_div = 666
sdec.ui_trig_x   = 675
-- A button is 58 px tall and the content area 431, so a button needs y <= 373. The firmware accepts
-- a y past that and clips; tools/mock_display raises, so an over-reach fails a test instead.
sdec.ui_btn_y    = 362
sdec.ui_btn_h    = 58                        -- for layout arithmetic, not passed to the API
sdec.ui_x        = 8

-- ---------- dump column geometry ----------
-- One unmeasured number, and every column derives from it: at 8 px/char the hex block is 376 px
-- wide and at 11 it is 517, so a literal ASCII column would sit 141 px inside the hex.
sdec.ui_ch_w     = 8                         -- character advance, ESTIMATE
sdec.ui_col_gap  = 8                         -- clear space each side of a vertical rule
-- Five, not four. '%04d' is a minimum width, not a maximum: a 32 kB recording's last row is offset
-- 32752, and at four the separator at 48 was drawn through the offset text.
sdec.ui_ixn      = 5                         -- offset field, '%04d', five digits past 9999
-- Hex block width, derived: changing the grouping has to move the ASCII column and rule 2 with it.
sdec.ui_hxn      = sdec.ua_hexwidth(8)      -- ONE group of 8 bytes: 8*3 - 1 = 23 chars
sdec.ui_col_gap2 = 12                       -- clear space BETWEEN the two hex groups
sdec.ui_asn      = 16                        -- ASCII block, one char per byte

sdec.ui_col_ix   = sdec.ui_x
-- Wider than ui_col_gap, and the same on both sides of rule 1, centring it in its own clear space.
sdec.ui_ix_gap   = 12
sdec.ui_vr1_x    = sdec.ui_col_ix + sdec.ui_ixn * sdec.ui_ch_w + sdec.ui_ix_gap
sdec.ui_col_hx   = sdec.ui_vr1_x + sdec.ui_ix_gap
-- The second group of eight at a fixed x: positioned by string content it would drift row to row.
sdec.ui_col_hx2  = sdec.ui_col_hx + sdec.ui_hxn * sdec.ui_ch_w + sdec.ui_col_gap2
-- Aligned with the status band's divider, because the two are stacked in one column and 10 px of
-- disagreement reads as a mistake. Taken from ui_stat_div, this being checkable only by eye.
sdec.ui_vr2_x    = sdec.ui_stat_div
-- Wider than ui_col_gap, and rule 2 does not move with it: this only pushes the text off the line.
sdec.ui_as_gap   = 16
sdec.ui_col_as   = sdec.ui_vr2_x + sdec.ui_as_gap
sdec.ui_vr3_x    = sdec.ui_col_as + sdec.ui_asn * sdec.ui_ch_w + sdec.ui_col_gap
-- The rules span the dump block, both ends derived from the rules they touch, never from the grid.
sdec.ui_vr_y0    = sdec.ui_rule_bot + 1
sdec.ui_vr_y1    = sdec.ui_stat_top

-- ---------- position bar ----------
-- A proportional indicator, not a draggable scrollbar, gestures not reaching custom objects here.
-- Segments are recoloured in place because setposition is unverified on rectangles. Off by default:
-- a FRAME capture is one page, and 15 segments cost 15 objects.
if sdec.ui_sb_show == nil then sdec.ui_sb_show = false end
sdec.ui_sb_x   = 778
sdec.ui_sb_w   = 12
-- Derived, not a matching literal: segments sit on the dump's own grid. Nothing catches a mismatch
-- -- ui_bar() lights from page fractions, so the only symptom is cosmetic misalignment.
sdec.ui_sb_n   = sdec.ui_nrow                -- segments, one per dump row -- BY CONSTRUCTION
sdec.ui_sb_h   = 17                          -- segment height, 3 px of gap at 20 px pitch

-- ---------- the capture modes ----------
-- The Mode button cycles this list, so there is one start control and no rule about which of two
-- start buttons wins. The button is a static `Mode`; the mode shows in the mode cell's colour, the
-- status row's words and the title bar, all on objects that already exist. FRAME always appends to
-- the log rather than offering a 'frame + log' mode, ulog degrading to a no-op with no key.
--   cap        byte ceiling, or nil for "as much as the buffer holds"
--   log        append the decode to a file on the USB key
--   view       the panel shows bytes (frame mode) or progress (streaming modes)
--   needbaud   refuses unless the baud rate is locked -- see sdec.mode_why()
--   idlexit    a quiet line ends the run and leaves the mode -- see sdec.mode_exit()
--   c          the mode cell's colour, which is the at-a-glance channel
--   title      the title bar's suffix; 'SERIAL DECODE - 32K CAPTURE' is 27 of the 31 allowed
sdec.ui_modes = {
  {id = 'frame', name = 'FRAME',  cap = nil,   log = true, view = true, title = '240B FRAME',
   c = 0xB0B0B0, desc = 'capture, show, and append to the message log'},
  -- Two recording sizes, and size is the only difference. Both are lossless; the mode cell shows it.
  {id = 'sml',   name = '8 kB',   cap = 8192,  log = true, view = false, title = '8K CAPTURE',
   needbaud = true, idlexit = true, c = 0x40C0FF,
   desc = 'shorter capture window -- quicker to bytes, more credits'},
  {id = 'med',   name = '32 kB',  cap = 32768, log = true, view = false, title = '32K CAPTURE',
   needbaud = true, idlexit = true, c = 0xFFC000,
   desc = 'long capture, decoded to a file'},
  -- There is no uncapped mode: a run longer than one window is what flow control is for.
  n = 3,
}
sdec.capmode = sdec.capmode or 'frame'    -- operator state, hence `or`

-- The FLOOR on how long a quiet line ends a stream, not the exit itself -- sdec.idle_exit() takes it
-- from Arm/Idle Wait. Without any such exit a 1200 baud run waits nine minutes for the buffer to fill
-- after the device stops talking, and 1 s is ~40 frame times at the slowest rate allowed. Zero or nil
-- here turns the watchdog off entirely, which is the one thing idle_exit() passes straight through.
sdec.idle_exit_s = sdec.idle_exit_s or 1

-- Arm/Idle Wait itself, never below the floor above: 10 s at the default, 2 s at the minimum, 120 s at
-- the ceiling. One field answers both halves of the same question, which is how long this device may go
-- without saying anything -- before it starts, and between blocks once it has. A device dumping its
-- startup banner stops for seconds at a time, and a fixed 1 s ends the recording inside the first of
-- those pauses with the interesting part still to come. One setting the operator can see on the glass
-- beats two they have to read about.
function sdec.idle_exit()
  local floor = sdec.idle_exit_s
  -- The off switch, passed through unchanged: a watchdog disabled by the floor must not come back from
  -- Arm/Idle Wait.
  if floor == nil or floor <= 0 then return floor end
  local w = sdec.arm_wait_s()
  if w ~= nil and w > floor then return w end
  return floor
end

-- How long any one piece of work may hold the panel: a budget, not a poll interval, since only a
-- handler returning lets a press through -- docs/MEASUREMENTS.md, 'ui_latency_s = 0.5 and
-- ck_press_budget_s = 8'.
sdec.ui_latency_s = sdec.ui_latency_s or 0.5

-- How much work one press of a stepped decode does, which is not how wide a window should be --
-- ui_latency_s sizes that. A press that returns has been answered; one inside the 8 s is queued.
sdec.ck_press_budget_s = sdec.ck_press_budget_s or 8.0

-- The mode in force, never nil: an unrecognised id falls back to frame.
function sdec.mode_cur()
  local i
  for i = 1, sdec.ui_modes.n do
    if sdec.ui_modes[i].id == sdec.capmode then return sdec.ui_modes[i] end
  end
  return sdec.ui_modes[1]
end

-- How often the panel looks for a key. Do not raise this rate to make a key appear sooner --
-- docs/MEASUREMENTS.md, 'The key-presence poll costs 340 us a tick'.
sdec.ui_tick_s = sdec.ui_tick_s or 0.5

-- Stop and start the tick around work that will hold the interpreter. -> true if it acted.
-- Clearing the handler is the off switch, and nothing else is: an invisible timer still fires, and a
-- busy run defers ticks rather than suppressing them. sdec.options() calls ui_tick_off() explicitly
-- and every exit re-arms, which is a no-op if a sibling screen stops the timer and the fix if it
-- does not -- docs/MEASUREMENTS.md, 'Clearing the handler is the only timer off switch'.
function sdec.ui_tick_off()
  if sdec.ui_tick_obj == nil then return false end
  return pcall(display.setevent, sdec.ui_tick_obj, display.EVENT_PRESS, '')
end

function sdec.ui_tick_on()
  if sdec.ui_tick_obj == nil then return false end
  return pcall(display.setevent, sdec.ui_tick_obj, display.EVENT_PRESS, 'sdec.guard(sdec.ui_tick)')
end

-- Look for a key that has come or gone, and make the panel agree. -> true if anything moved.
-- The shared body of the tick and of the three presses that want an answer now, so Capture, View
-- and Mode each act on the key state at the press. It does not re-open the log, and must not:
-- ulog.resume() allows one open attempt per insertion, and spending it half a second after
-- insertion spends it when it is least likely to succeed. Guarded -- a raise here reaches firmware.
function sdec.ui_keypoll()
  if sdec.ui_scr == nil then return false end
  local moved = false
  pcall(function()
    -- One presence decision, one owner: ui_usb_btns() caches the answer in ui_savevis, and a second
    -- cache here would sit on its own opinion for ever. The buttons move in every state, run or not.
    if not sdec.ui_usb_btns() then return end
    moved = true
    -- The log cell is only ours when no run owns it: a run's hint there is the only way to stop.
    if sdec.ui_log_owned() then return end
    -- The log cell names the key too, so it moves with the buttons.
    sdec.ui_set(sdec.ui_log_t, sdec.flog_status())
  end)
  return moved
end

-- Is the status row's right-hand cell currently a run's, rather than the log's? -> true or false.
-- It must track ui_refresh()'s branch for that cell, because ui_keypoll() writes the same object
-- from a press; tools/test_streamfix.lua walks eleven states and asserts the two agree in each.
function sdec.ui_log_owned()
  local md = sdec.mode_cur()
  if md == nil then return false end
  -- The negation of ui_refresh's test for the log cell -- the one guarding the block that writes
  -- ui_log_t, not the similarly-shaped test above it that chooses the status row's left cell.
  if md.view and sdec.ck_tot == nil and not sdec.ck_running then return false end
  if sdec.strm_recording then return true end
  if sdec.ck_job ~= nil then return true end
  if sdec.ck_running or sdec.strm_inflight then return true end
  return false
end

-- What that cell says, decided in one place because three callers write it: ui_refresh paints it, a
-- press writes it through ui_keypoll, and an armed record takes it for an armnote and has to give it
-- back. Not owned by a run means the log's own status, which is what both ui_refresh branches said.
function sdec.ui_runnote()
  if not sdec.ui_log_owned() then return sdec.flog_status() end
  if sdec.strm_recording then return 'Capture or Mode = Stop' end
  if sdec.ck_job ~= nil then return 'Capture=step  Mode=Stop' end
  -- No 'Mode=...' for a one-press run, where the true answer is none. docs/MEASUREMENTS.md, 'The
  -- trigger key does not cancel a panel-initiated run'.
  if sdec.ck_running or sdec.strm_inflight then return 'no stop until it ends' end
  return sdec.flog_status()
end

-- Give the control cell back once the trigger has fired. record_run()'s refresh is the last full one
-- of the run and the arm paints over that cell afterwards, so without this an armed 8 kB or 32 kB
-- record keeps 'waiting Ns for N.NNV' on screen through the acquisition and the decode as well.
function sdec.armnote_clear()
  if sdec.ui_log_t == nil then return false end
  return sdec.ui_set(sdec.ui_log_t, sdec.ui_runnote())
end

-- One tick of sdec.ui_tick_obj: the unattended half of ui_keypoll(). It must not act while the app
-- is busy, a tick being dispatched like a press and so arriving in a burst after a capture. The
-- press route needs no such test: a handler executing at all proves no run is.
function sdec.ui_tick()
  if sdec.ui_scr == nil then return false end
  if sdec.busy or sdec.ck_running or sdec.strm_recording then return false end
  return sdec.ui_keypoll()
end

-- Will anything the app writes reach the key? -> true or false. Asked before a capture, so it
-- cannot read sdec.flog_why; unknown counts as yes, so a build without usb_log.tsp still reads right.
function sdec.log_live()
  local live = true
  if ulog ~= nil and ulog.keyok ~= nil then
    live = ulog.keyok()
  end
  return live
end

-- Whether mode `m` suits the current rate. Always true; mode_why() is what refuses, with a reason.
function sdec.mode_suits(m)
  return true
end

-- Why mode `m` cannot run right now, as a sentence for the note line, or nil if it can. Called when
-- capture is pressed, so a mode can be lined up before the rate is known.
function sdec.mode_why(m)
  if m == nil then m = sdec.mode_cur() end
  -- Streaming is gated on a locked rate: the lock is what picks the sample rate ahead of time.
  if m.needbaud and (sdec.force_baud == nil or sdec.force_baud <= 0) then
    -- Kept short: with the 'WARNING: ' prefix this has to fit the note cell, on modelled metrics.
    return 'lock the baud rate in Options -- streaming picks the sample rate from it'
  end
  -- No rate can deliver the floor at this baud: the burst path loses acq_overhead per sample, so
  -- above 165563 Bd nothing listed closes the gap -- see fs_for_burst(). Refused with the number.
  if m.needbaud and sdec.force_baud ~= nil and sdec.force_baud > 0 and
     sdec.fs_for_burst ~= nil and sdec.fs_for_burst(sdec.force_baud) == nil then
    -- Name the recording's own figure, or this contradicts the header beside it: SA/BIT is measured
    -- from a FRAME capture, which nearly gets its 1 MS/s, where a recording gets 662 kS/s.
    local dl = nil
    if sdec.rates ~= nil and sdec.fs_delivered ~= nil then
      dl = sdec.fs_delivered(sdec.rates[table.getn(sdec.rates)])
    end
    -- %.0f, not %d: force_baud carries a measured rate whenever autolock set it, and 153588.155 has
    -- been on this panel. 5.0.2 truncates silently and 5.4 raises, and no offline test reaches here.
    if dl ~= nil and dl > 0 then
      return string.format('%.0f Bd: a recording gets %.1f samples/bit, under the %d floor -- '
                           .. 'use FRAME', sdec.force_baud or 0, dl / sdec.force_baud, sdec.minsabit or 0)
    end
    return string.format('%.0f Bd is too fast to stream -- no sample rate delivers %d ' ..
                         'samples/bit; use FRAME', sdec.force_baud or 0, sdec.minsabit or 0)
  end
  return nil
end

-- Three states, distinguished by the padlock's colour:
--   'locked'   green  -- at least one wire parameter is forced
--   'auto'     amber  -- nothing forced, and there is a decode, so there is something to lock
--   'unknown'  red    -- nothing forced and nothing decoded: nothing to lock yet
function sdec.lock_state()
  if sdec.force_baud ~= nil and sdec.force_baud > 0 then return 'locked' end
  if sdec.force_nbits ~= nil or sdec.force_par ~= nil or
     sdec.force_nstop ~= nil or sdec.force_invert ~= nil then return 'locked' end
  if sdec.baud == nil or sdec.res == nil then return 'unknown' end
  return 'auto'
end

-- The title bar's text: the app's name and the capture mode, in the largest type on the screen.
-- Bounded at 31 characters, the firmware's limit, over which it raises 1707 and truncates silently.
function sdec.ui_title_text()
  local md = sdec.mode_cur()
  local s = sdec.ui_title
  if md ~= nil and md.title ~= nil then s = s .. ' - ' .. md.title end
  if string.len(s) > 31 then s = string.sub(s, 1, 31) end
  return s
end

function sdec.lock_colour()
  local st = sdec.lock_state()
  if st == 'locked' then return sdec.ui_c_locked end
  if st == 'auto' then return sdec.ui_c_auto end
  return sdec.ui_c_unknown
end

-- ---------- the views ----------
-- The View button cycles this list, and every per-view decision reads it: page size, item count,
-- unit name, row text, row colour. An entry with `res` is a protocol layer, its module parsing the
-- byte stream into sdec[res] = {n, msg[], kind[]} where kind[i] == 'err' colours the row. Function
-- names are strings, so a build without a module degrades to an empty list rather than failing.
sdec.ui_views = {
  {mode = 'text', name = 'TEXT', unit = 'bytes', cols = 80},
  {mode = 'hex',  name = 'HEX',  unit = 'bytes', cols = 16},
  {mode = 'midi', name = 'MIDI', unit = 'msg',   cols = 1, res = 'midi',
   label = 'MIDI messages', nrows = 'mi_nrows', line = 'mi_line',
   parse = 'mi_parse', summary = 'mi_summary'},
  {mode = 'lin',  name = 'LIN',  unit = 'frame', cols = 1, res = 'lin',
   label = 'LIN frames', nrows = 'li_nrows', line = 'li_line',
   parse = 'li_parse', summary = 'li_summary'},
}

-- Whether view `v` is available in this build: a protocol view needs its module loaded. The entries
-- stay in ui_views so that restoring either is one line in package_tspa.py modules.
function sdec.ui_view_avail(v)
  if v == nil then return false end
  if v.res == nil then return true end          -- text and hex need no module
  -- Checked lazily, not by pruning ui_views at load time: the app loads serial_ui after the protocol
  -- modules and the offline harnesses load them the other way round.
  return v.parse ~= nil and sdec[v.parse] ~= nil
end

-- How many views this build offers, so the button never lands on a view that can only be empty.
function sdec.ui_nviews()
  local n, i = 0, nil
  for i = 1, table.getn(sdec.ui_views) do
    if sdec.ui_view_avail(sdec.ui_views[i]) then n = n + 1 end
  end
  return n
end

-- The nth byte view this build offers.
function sdec.ui_view_nth(k)
  local n, i = 0, nil
  for i = 1, table.getn(sdec.ui_views) do
    if sdec.ui_view_avail(sdec.ui_views[i]) then
      n = n + 1
      if n == k then return sdec.ui_views[i] end
    end
  end
  return nil
end

-- The ui_views entry for `mode`, or nil if absent here. Callers that must have one use ui_cur().
function sdec.ui_view(mode)
  if mode == nil then mode = sdec.ui_mode end
  local i
  for i = 1, table.getn(sdec.ui_views) do
    if sdec.ui_views[i].mode == mode then
      if sdec.ui_view_avail(sdec.ui_views[i]) then return sdec.ui_views[i] end
      return nil
    end
  end
  return nil
end

-- The view in force, never nil: an unrecognised sdec.ui_mode falls back to text.
function sdec.ui_cur()
  return sdec.ui_view() or sdec.ui_views[1]
end

-- ---------- colours ----------
sdec.ui_c_dim  = 0xB0B0B0    -- grey: secondary detail
-- The dump's offset column, dimmer than ui_c_dim: it is metadata the eye navigates by, not data.
sdec.ui_c_off  = 0x808080
sdec.ui_c_warn = 0xFFC000    -- amber: ambiguity and warnings
sdec.ui_c_data = 0xFFFFFF    -- white: the decoded bytes
sdec.ui_c_err  = 0xFF6060    -- red: a row containing a framing or parity error
sdec.ui_c_sb_off = 0x282828  -- position bar, outside the current page
sdec.ui_c_sb_on  = 0x00DCFF  -- position bar, current page
-- The page counter, in two intensities, and a text object carries one: hence four objects.
sdec.ui_c_pgnum  = 0xFFFFFF    -- the numerals: 100 %
sdec.ui_c_pgword = 0xA8A8A8    -- 'page' and 'of': 66 %
-- The bar: cyan filled, and a grey box so that what is left is as visible as what is done.
sdec.ui_c_prog     = 0x00FFFF
sdec.ui_c_prog_box = 0xCCCCCC
-- The rear BNC's three states. Empty when off: a marker that is always present is not a marker.
sdec.ui_c_extin  = 0x40FF40   -- green: an input, armed
sdec.ui_c_extout = 0xFFC000   -- amber: an output, pulsing a credit per capture
sdec.ui_c_extio  = 0x00FFFF   -- cyan:  both directions live

-- ---------- handles ----------
-- Declared, not assigned: opening the installed App re-runs this file, and nil-ing a live handle
-- strands its object. ui_scr, ui_note, ui_page_t, ui_log_t, ui_flab, ui_fval, ui_rule, ui_row,
-- ui_btn (kept so teardown can see them), ui_sb and ui_sbc. See the note in serial_core.tsp.

-- ---------- view state ----------
sdec.ui_mode = sdec.ui_mode or 'text'    -- 'text', 'hex' or 'midi'
sdec.ui_page = sdec.ui_page or 0          -- 0-based page index
-- Has the operator paged yet. The counter stays off the note row until they have, 'page 1 of 1'
-- being worth less than a note. Latched, and `or false` so re-running this file keeps it.
sdec.ui_paged = sdec.ui_paged or false
sdec.ui_status = sdec.ui_status or 'ready'
-- sdec.ui_last   -- last text written per handle, to skip redundant settext

-- Say the panel is waiting on purpose, called by acq_triggered() before it blocks on an
-- arm-from-silence: the wait can be 120 s and nothing can interrupt it. The offline harnesses
-- install no armnote.
function sdec.armnote(wait, level, keyed)
  -- ui_log_t, the right-hand cell, written through ui_set or the note is not temporary, and `keyed`
  -- is what stops it promising the trigger key. docs/MEASUREMENTS.md, 'The armnote cell goes
  -- through ui_set'.
  if sdec.ui_log_t == nil then return false end
  local tail = ''
  if keyed then tail = ' -- TRIGGER=go' end
  return sdec.ui_set(sdec.ui_log_t,
                     string.format('waiting %.0fs for %.2fV%s', wait or 0, level or 0, tail))
end

-- ---------- options form handles ----------
-- sdec.optscr, sdec.opt_proto, sdec.opt_baud, sdec.opt_bits, sdec.opt_par, sdec.opt_pol,
-- sdec.opt_trig, sdec.opt_ext, sdec.opt_armv, sdec.opt_armw, sdec.opt_gape -- declared, not assigned.
-- Eight fields, nine with a protocol module, and this is the riskiest geometry in the app --
-- docs/MEASUREMENTS.md, 'The options form vertical geometry'. test_serial checks the last box
-- against the button row. A field added now folds into another as an extra option entry, free.
sdec.ui_opt_y0 = 8
-- The pitch asks for every pixel available and the clamp in build_options() decides what it gets: a
-- gap is a touch target -- docs/MEASUREMENTS.md, 'The options form vertical geometry'.
sdec.ui_opt_dy = 100
-- Measured, with the offset of the box inside the object; the mock carries the same height.
sdec.ui_opt_edit_h  = 50
sdec.ui_opt_edit_dy = 4
-- The options button row, 360 and not 366: a button is 60 px tall on this screen, not 58.
sdec.ui_opt_btn_y   = 360
-- And the clamp keeps this much back: handing over every pixel put the bottom field 1 px off the
-- row. It costs air between the boxes, and the dy < eh branch catches a build that cannot afford it.
sdec.ui_opt_btn_gap = 24
sdec.ui_opt_x  = 185   -- the label is RIGHT-ALIGNED and ends here, so this is its width
-- Two columns buy the vertical gap: six fields become three rows. display.create
-- takes no width for an OBJ_EDIT_*, so the second column's x is the one number to check on the glass.
-- How far the centred block is nudged, negative being up. See the application site.
sdec.ui_opt_y_adj = -8
sdec.ui_opt_cols = 2
sdec.ui_opt_x_c2 = 552
-- How wide an option-field entry may be, in px: past this the firmware fades the tail rather than
-- clipping -- docs/MEASUREMENTS.md, 'The options form field and button widths'.
sdec.ui_opt_px = 96

-- Width available to the log cell, derived so that moving a divider moves the fit budget with it. A
-- literal went stale once already, asserting a margin that had not existed for some time.
sdec.ui_log_px = sdec.ui_trig_div - (sdec.ui_stat_div + 6)

-- Width of an option entry under that model.
function sdec.ui_optw(s)
  if s == nil then return 0 end
  local _, nup = string.gsub(s, '%u', '')
  local n = string.len(s)
  return nup * (sdec.ui_adv_upper or 10) + (n - nup) * (sdec.ui_adv_mixed or 8)
end

-- ============================================================================
-- Small helpers
-- ============================================================================
-- settext `txt` on `h`, but only when the text changed. Returns true if it wrote.
function sdec.ui_set(h, txt)
  if h == nil then return false end
  if sdec.ui_last == nil then sdec.ui_last = {} end
  -- Not a micro-optimisation: display calls are asynchronous messages over a bounded queue, and
  -- "1706 Message dropped from display queue" precedes the firmware panics.
  if sdec.ui_last[h] == txt then return false end
  local ok = pcall(display.settext, h, txt)
  if ok then sdec.ui_last[h] = txt end
  return ok
end

-- Set an object's colour, tolerating a handle the build never created.
function sdec.ui_color(h, c)
  if h == nil then return false end
  -- Guarded: setcolor fails on Image objects (1717) and is unconfirmed on text.
  return (pcall(display.setcolor, h, c))
end

-- Delete object `h`, counting a refusal rather than assuming it worked. Returns whether it went.
function sdec.del_obj(h)
  if h == nil then return true end
  local ok = pcall(display.delete, h)
  if not ok then
    -- Keep a handle that would not delete: every teardown nils its variables, so dropping a refused
    -- handle strands a live object until a power cycle, and that accumulation raises event 1701.
    sdec.delfails = (sdec.delfails or 0) + 1
    sdec.orphans = sdec.orphans or {}
    sdec.orphans[table.getn(sdec.orphans) + 1] = h
  end
  return ok
end

-- Retry every handle a previous teardown could not delete. Returns how many are still live.
function sdec.del_orphans()
  local o = sdec.orphans
  if o == nil then return 0 end
  local keep, nk, i = {}, 0, nil
  for i = 1, table.getn(o) do
    local ok = pcall(display.delete, o[i])
    if not ok then nk = nk + 1; keep[nk] = o[i] end
  end
  if nk < 1 then sdec.orphans = nil else sdec.orphans = keep end
  return nk
end

-- Recolour rect `h` to `c`, counting a refusal in sdec.fillfails, which the status row surfaces.
-- Colour a rect with setcolor, not setfill: a 24-bit colour is refused with 1130, and enough
-- refusals per refresh raise a modal dialog over the panel. setfill does nothing to a rect at all.
function sdec.ui_fill(h, c)
  if h == nil then return false end
  local ok = pcall(display.setcolor, h, c)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Make a rect paint: 100 % foreground, once per rect at build time.
function sdec.ui_fill_solid(h)
  if h == nil then return false end
  local ok = pcall(display.setfill, h, 100)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Show or hide object `h`. The only way to take a rect or a line off the glass: recolouring one to
-- ui_c_hide does not hide it, and that works for the dump rules only because they are 1 px wide.
function sdec.ui_setstate(h, st)
  if h == nil then return false end
  local ok = pcall(display.setstate, h, st)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Paint the acquire/decode bar at `pct` (0..100), or hide it when pct is nil -- every state with no
-- honest fraction passes nil, and sdec.ck_pct says which those are.
--   nil   gone. Frame and bar both STATE_INVISIBLE.
--   0     the grey frame alone: a run has started and has nothing to show yet.
--   > 0   the frame plus a cyan bar out to pct.
-- A thick OBJ_LINE in an OBJ_RECT frame, cached -- docs/MEASUREMENTS.md, 'The progress bar extents'.
function sdec.ui_progbar_set(pct)
  if sdec.ui_progbox == nil or sdec.ui_progline == nil then return false end
  if pct ~= nil then
    pct = math.floor(pct + 0.5)
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
  end
  local vis = 0
  if pct ~= nil then vis = 1 end
  if pct ~= nil and pct > 0 then vis = 2 end
  if vis ~= sdec.ui_progvis then
    local on, off = display.STATE_ENABLE, display.STATE_INVISIBLE
    local boxst, barst = off, off
    if vis > 0 then boxst = on end
    if vis > 1 then barst = on end
    sdec.ui_setstate(sdec.ui_progbox, boxst)
    sdec.ui_setstate(sdec.ui_progline, barst)
    sdec.ui_progvis = vis
  end
  -- The length, and only when it changed. Rounded to whole px, the granularity the panel has.
  if pct ~= sdec.ui_progpct then
    if pct ~= nil and pct > 0 then
      local w = math.floor(pct * sdec.ui_prog_wmax / 100 + 0.5)
      if w < 1 then w = 1 end
      local x0 = sdec.ui_prog_x + 1
      pcall(display.setposition, sdec.ui_progline, x0, sdec.ui_prog_ly, x0 + w - 1, sdec.ui_prog_ly)
    end
    sdec.ui_progpct = pct
  end
  return true
end

-- Items per page, and per row. A protocol view is one message or frame per row, so cols is 1.
function sdec.ui_bytes_per_page()
  local cols = sdec.ui_cur().cols or 80
  return cols * sdec.ui_nrow, cols
end

-- What the current view is paging through: bytes, MIDI messages or LIN frames.
function sdec.ui_nitems()
  local v = sdec.ui_cur()
  if v.nrows ~= nil then
    local fn = sdec[v.nrows]
    if fn == nil then return 0 end
    return fn()
  end
  if sdec.res == nil then return 0 end
  return sdec.res.nf
end

-- Pages the current result needs at the current view.
function sdec.ui_npages()
  local per = sdec.ui_bytes_per_page()
  local n = sdec.ui_nitems()
  if n <= 0 then return 1 end
  return math.floor((n + per - 1) / per)
end

-- 'bytes', 'msg' or 'frame', for the status row.
function sdec.ui_unit()
  return sdec.ui_cur().unit or 'bytes'
end

-- The ERR field's number, in one place: the value and its colour were computed apart and by
-- different rules, so a head-damaged run showed a non-zero ERR in green. Takes the table, not ck_tot.
function sdec.ck_err_n(t)
  if t == nil then return 0 end
  local n = t.nbad or 0
  local hb = t.headbad or 0
  if hb > 0 then n = n - (t.headnbad or 0) + hb end
  return n
end

function sdec.ui_err_n()
  local ct = sdec.ck_tot
  if ct ~= nil then
    return sdec.ck_err_n(ct)
  end
  if sdec.res == nil then return nil end
  if sdec.ua_err_count == nil then return sdec.res.nbad end
  return sdec.ua_err_count(sdec.res)
end

-- The colour header value `j` is drawn in; the three lockable fields carry the lock state too.
function sdec.ui_field_colour(j)
  local fd = sdec.ui_fields[j]
  if j == sdec.ui_lockfields.baud or j == sdec.ui_lockfields.fmt or
     j == sdec.ui_lockfields.idle then
    local st = sdec.lock_state()
    if st == 'locked' then return sdec.ui_c_locked end
    if st == 'unknown' then return fd.c end   -- the value is '--' already; red would shout
    return fd.c                               -- auto: the column's own colour, unchanged
  end
  -- Errors go red when there are any. fd.c, not a literal green: the "all clear" colour is this
  -- column's colour, and writing it in two places lets the two drift.
  if j == sdec.ui_errfield then
    -- The same number the field shows, so the colour cannot contradict it.
    local n = sdec.ui_err_n()
    if n ~= nil and n > 0 then return sdec.ui_c_err end
    return fd.c
  end
  -- Read from the same number the cell prints, so the colour cannot disagree with the figure. nil
  -- keeps the column's own colour, the value being '--'. If the cell shows a number, band it.
  if j == sdec.ui_fitfield then
    local q = sdec.fitq
    if q == nil then return fd.c end
    -- Band the displayed value, not the raw one: banding 0.8996 put an amber '0.90' on the panel.
    q = math.floor(q * 100 + 0.5) / 100
    if q < sdec.ui_fit_bad then return sdec.ui_c_sn_bad end
    if q < sdec.ui_fit_good then return sdec.ui_c_sn_warn end
    return sdec.ui_c_sn_ok
  end
  if j == sdec.ui_snfield then
    local db = sdec.snr_db
    if db == nil then return fd.c end
    -- Same rounding as the cell's '%.0f dB', so 24.6 cannot print '25 dB' in amber.
    db = math.floor(db + 0.5)
    if db < sdec.ui_sn_bad then return sdec.ui_c_sn_bad end
    if db < sdec.ui_sn_good then return sdec.ui_c_sn_warn end
    return sdec.ui_c_sn_ok
  end
  return fd.c
end

-- The header values, in sdec.ui_fields order. Kept short: a value that outgrows its column collides.
function sdec.ui_field_values()
  local r = sdec.res
  local v = {}

  -- BAUD, FORMAT and IDLE fall back to the forced values when nothing is decoded; the measured cells
  -- stay '--'. %.0f, never %d -- docs/MEASUREMENTS.md, 'Why BAUD, FORMAT and IDLE fall back to
  -- forced values'.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    v[1] = string.format('%.0f', sdec.force_baud or 0)
  elseif sdec.baud == nil then v[1] = '--'
  -- The same condition baud_text() uses, or the cell reads 38400 beside a text row of '38400 baud?'.
  elseif sdec.snapped and sdec.snapfirm ~= false then v[1] = string.format('%.0f', sdec.baud or 0)
  else v[1] = string.format('%.0f?', sdec.baud or 0) end

  v[2] = sdec.fmt_text()

  if r ~= nil then
    if r.invert then v[3] = 'LOW' else v[3] = 'HIGH' end
  elseif sdec.force_invert ~= nil then
    if sdec.force_invert then v[3] = 'LOW' else v[3] = 'HIGH' end
  else v[3] = '--' end

  v[4] = sdec.family or '--'

  if sdec.lo == nil then
    v[5] = '--'
  else
    v[5] = string.format('%.2f V', sdec.thr or 0)
  end

  if sdec.bittime == nil then v[6] = '--'
  else v[6] = string.format('%.1f', sdec.bittime or 0) end

  local fs = sdec.acq_fs or sdec.fs
  if fs == nil then v[7] = '--'
  elseif fs >= 1000000 then v[7] = string.format('%.0f MS/s', fs / 1000000)
  else v[7] = string.format('%.0f kS/s', fs / 1000) end

  -- BYTES and ERR come from the stream in the streaming modes, sdec.res holding only the lead-in
  -- window there. Gated on ck_tot and not on the mode, a quiet line ending a stream in FRAME.
  local ct = sdec.ck_tot
  if (ct ~= nil or sdec.ck_running) then
    if sdec.ck_running then
      -- Dashes, not zero, during the recording phase: a green '0' in BYTES reads as a measurement.
      if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then v[8] = '--'
      else v[8] = tostring(sdec.ck_nbytes) end
      v[9] = '--'                     -- not known until the run finishes
    else
      v[8] = tostring(ct.nf)
      v[9] = tostring(sdec.ui_err_n())
    end
  elseif r == nil then v[8], v[9] = '--', '--'
  else
    v[8] = tostring(r.nf)
    -- Windowing artefacts are excluded and an identified misaligned head is not -- see ua_err_count.
    v[9] = tostring(sdec.ui_err_n())
  end

  -- '--' when there is no FIT, not '0.00': a number takes the column's colour and reads as unbanded.
  if sdec.fitq == nil then
    v[10] = '--'
  else
    v[10] = string.format('%.2f', sdec.fitq or 0)
  end
  -- '--' rather than a number: a noise figure with no measured swing behind it is no number.
  if sdec.snr_db == nil then
    v[11] = '--'
  elseif sdec.snr_db >= 99 then
    -- Clamped with a '>': a synthetic capture reaches 130 dB and the ADC floors near 97.
    v[11] = '>99 dB'
  else
    v[11] = string.format('%.0f dB', sdec.snr_db or 0)
  end
  return v
end

-- How far a misaligned head reaches, and whether it is on screen. Returns extent, onscreen --
-- extent nil when no head was identified.
-- One function because three indicators share this number and must agree: the note names the extent,
-- ERR counts it, and the hex rows covering it are red. Asked separately, the colour asked the
-- narrower question -- did this byte fail a check -- and reddened only part of a named head. A
-- recording's head may be off screen, a 32 kB run showing its retained tail, so res.first == 1.
function sdec.ui_head_extent()
  local hs = nil
  if sdec.res ~= nil and sdec.res.headsusp ~= nil and sdec.res.headsusp > 0 then
    hs = sdec.res.headsusp
  elseif sdec.ck_tot ~= nil and sdec.ck_tot.headsusp ~= nil and sdec.ck_tot.headsusp > 0 then
    hs = sdec.ck_tot.headsusp
  end
  if hs == nil then return nil, true, false end
  local onscreen = (sdec.res == nil or sdec.res.first == nil or sdec.res.first <= 1)
  -- Which quantity the number is, as the third return: ua_head_bad narrows the region to the frames
  -- that failed, but a misaligned head can pass parity and stop by luck, leaving it unnarrowed. A
  -- caller that cannot tell states a region as damage -- measured, two bytes lost reported as eight.
  local measured = false
  -- How far the damage reaches, not how far the suspicion does, and only countable when the
  -- head is on screen -- docs/MEASUREMENTS.md, 'How far a misaligned head reaches'.
  if onscreen and sdec.res ~= nil and sdec.res.errs ~= nil then
    -- Through ua_head_bad, not a loop of its own: ERR counts this same region and must agree.
    local last = sdec.ua_head_bad(sdec.res, hs)
    if last > 0 then hs, measured = last, true end
  elseif sdec.ck_tot ~= nil and sdec.ck_tot.headbad ~= nil
         and sdec.ck_tot.headbad > 0 then
    -- From the run, for a tail without its own head: the first window is where those bytes exist.
    -- headbad is a damage count, so this branch is measured by construction.
    hs, measured = sdec.ck_tot.headbad, true
  end
  return hs, onscreen, measured
end

-- ============================================================================
-- The note / warning line
-- ============================================================================
-- Every note that applies, most important first. Returns the list and its count.
-- A list, not a fall-through chain: seventeen sources feed one cell, and a chain shows one of them
-- with nothing to say the others exist. The cell shows the one that fits and says how many more
-- there are; ulog and the saved file get all of them. Ordered by how badly an absence would mislead.
function sdec.ui_notes()
  local t, m = {}, 0
  local function add(s)
    if s ~= nil and s ~= '' then m = m + 1; t[m] = s end
  end

  if sdec.lasterr ~= nil then add('NOTE: ' .. tostring(sdec.lasterr)) end
  if sdec.savedas ~= nil then add('saved to ' .. tostring(sdec.savedas)) end
  if sdec.stickyerr ~= nil then add('NOTE: ' .. tostring(sdec.stickyerr)) end

  -- A setting that looks applied and is not: Free run skips blending, and the field still reads it.
  if sdec.trigext and sdec.trigmode == 'free' then
    add('Rear BNC = Trig In is set but IGNORED -- Free run means do not wait for anything')
  end

  -- No recording forecast on this row: ui_notes cannot tell whether the run has already happened,
  -- and cap/bps is the line's time where the decode costs an order of magnitude more.

  -- A mode that changed itself has to say so. Only when it ended badly: else the summary says it.
  if sdec.mode_exited ~= nil and sdec.mode_exitbad then add(tostring(sdec.mode_exited)) end
  if sdec.lognote ~= nil then add(tostring(sdec.lognote)) end
  -- A recording that relevelled mid-run says so: the two halves are judged against different levels.
  if sdec.strm_releveled ~= nil then add(tostring(sdec.strm_releveled)) end
  -- The app threw away a setting the operator made, and nothing else explains the BAUD cell moving.
  if sdec.relocked ~= nil then add(tostring(sdec.relocked)) end
  -- The app refused a setting the operator made, and unlike relocked there are no bytes on screen to
  -- explain themselves. Options > Baud 0 is named because it exists, where rate_accept() does not.
  if sdec.rate_refused ~= nil then add(tostring(sdec.rate_refused)) end

  -- A streaming mode that cannot run says so before Capture is pressed, and here rather than in the
  -- status row: the remedy is a sentence, and the full one measures 802 px against a 798 px panel.
  local md = sdec.mode_cur()
  if not md.view then
    local mw = sdec.mode_why(md)
    if mw ~= nil then add('WARNING: ' .. mw) end
  end

  -- The dump area shows one window and the file holds the stream, so BYTES says 32768 while the panel
  -- shows ~192. Without this line that reads as a bug: a partial view is honest only if it says so.
  if sdec.ck_tot ~= nil and sdec.res ~= nil and sdec.ck_tot.nf > sdec.res.nf then
    -- Which bytes, not just how many: a finished recording leaves its retained tail on screen, so
    -- 'the first 8192' would name the wrong end. res.first is the index ck_tail_result() records.
    local first, tot = sdec.res.first, sdec.res.ntotal or sdec.ck_tot.nf
    -- With no file the rest is gone: 'all are in the USB file' is then the opposite of true.
    if sdec.ck_tot.path == nil then
      -- Why there is no file is not always 'no USB key': flog_why holds the reason flog_alloc gave.
      local why = 'NOT RECORDED'
      if sdec.flog_why == nil then why = 'NOT RECORDED -- no USB key' end
      if first ~= nil and first > 1 then
        add(string.format('panel shows bytes %d-%d of %d -- the rest was DISCARDED, %s',
                          first or 0, first + (sdec.res.nf or 0) - 1, tot or 0, tostring(why)))
      else
        add(string.format('panel shows the first %d of %d bytes -- the rest was DISCARDED, %s',
                          sdec.res.nf or 0, tot or 0, tostring(why)))
      end
    else
      local base = string.gsub(tostring(sdec.ck_tot.path), '^.*/', '')
      if first ~= nil and first > 1 then
        add(string.format('panel shows bytes %d-%d of %d; all are in %s',
                          first or 0, first + (sdec.res.nf or 0) - 1, tot or 0, tostring(base)))
      else
        add(string.format('panel shows the first %d bytes of the stream; all %d are in %s',
                          sdec.res.nf or 0, tot or 0, tostring(base)))
      end
    end
  end

  -- Only warn about samples/bit once there is one: 'no bit time' reads as a fault before a capture.
  if sdec.bittime ~= nil then
    local _, warn = sdec.sig_quality()
    if warn ~= nil then add('WARNING: ' .. warn) end
  end

  -- An unstable baseline is decoded rather than refused, so it has to be said, and auto-lock must
  -- announce itself. Below the signal-quality warnings: a shaky baseline deserves a lock least.
  local lw = sdec.sig_levelwarn()
  if lw ~= nil then add('WARNING: ' .. lw) end

  if sdec.autolocknote ~= nil then add(sdec.autolocknote) end
  -- Why the capture took two passes: the press is twice as long and nothing else would say why.
  if sdec.probe_note ~= nil then add(sdec.probe_note) end

  -- LIN's own level check: a 12 V bus probed without the 2:1 divider decodes nothing.
  if sdec.proto == 'lin' and sdec.li_levelnote ~= nil then
    local ln = sdec.li_levelnote()
    if ln ~= nil then add('WARNING: ' .. ln) end
  end

  -- Every LIN break is a framing error at the UART layer, so a healthy capture lights ERR red.
  if sdec.proto == 'lin' and sdec.li_breaknote ~= nil then
    add(sdec.li_breaknote())
  end

  -- A capture that began mid-byte: the framer can anchor inside a byte and stay wrong until the
  -- first idle, and the bytes look like data -- docs/MEASUREMENTS.md, 'How far a misaligned head
  -- reaches'.
  local hs, onscreen, hmeas = sdec.ui_head_extent()
  if hs ~= nil then
    -- The note states the extent and stops, having 556 px beside the page counter. Singular and
    -- plural are spelled out, a parenthesised plural reading as a placeholder nobody filled in.
    --
    -- A narrowed count is frames that failed, so 'are' is a fact; an unnarrowed one is the suspicion
    -- region, and asserting it overstates the damage several-fold. The region is still the right
    -- number to print, those bytes being untrustworthy and the operator unable to see it, so the
    -- hedge goes in the verb rather than into a smaller count.
    local isv, arev = 'is', 'are'
    if not hmeas then isv, arev = 'may be', 'may be' end
    if onscreen then
      if hs == 1 then
        add('began mid-byte -- the first byte ' .. isv .. ' misaligned.')
      else
        add(string.format('began mid-byte -- the first %d bytes %s misaligned.', hs or 0, arev))
      end
    else
      -- Where the bytes went distinguishes this branch: the ones this note names are not the ones on the
      -- panel. And there is not always a file -- the panel cited one for 14190 discarded bytes.
      local where = ', in the file.'
      if sdec.ck_tot ~= nil and sdec.ck_tot.path == nil then
        where = ', and were NOT recorded.'
      end
      if hs == 1 then
        add('the run began mid-byte -- its first byte ' .. isv .. ' misaligned' .. where)
      else
        add(string.format('the run began mid-byte -- its first %d bytes %s misaligned%s',
                          hs or 0, arev, tostring(where)))
      end
    end
  end

  -- Impulse noise flips a data bit undetectably, so a zero err count reads as 'no corruption'.
  if sdec.res ~= nil and sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('%d false start(s) rejected -- impulse noise; "err" counts framing only',
                      sdec.res.nfalse or 0))
  end

  -- A protocol layer that failed, said where an empty message list would otherwise speak for it.
  if sdec.proto_why ~= nil then add('WARNING: ' .. tostring(sdec.proto_why)) end

  -- The rate on screen was not measured. acq_fs is normally re-derived from the buffer's timestamps,
  -- the readback lying for any rate the hardware cannot synthesise, so a substitution must show.
  if sdec.acq_fs_est then
    add(string.format('sample rate NOT measured from this capture -- showing the requested %g S/s; '
                      .. 'every timing figure derives from it', sdec.fs or 0))
  end

  -- Why the byte log is off, in full, the status cell having room only for the flag. Deliberately
  -- low: a log fault persists, and above the wire warnings it masked the 12 V divider hint.
  if sdec.flog_why ~= nil then add('NOT LOGGING: ' .. tostring(sdec.flog_why)) end

  -- Order matters here. The forced-rate disagreement goes first: it is the only note that says the
  -- bytes on screen may be wrong with nothing else to indicate it. A rate outranks a format.
  add(sdec.rate_note)
  add(sdec.baud_note)
  add(sdec.fmt_note)

  -- The capture was FULL, so the message probably continues past what is shown. Not for a retained
  -- tail -- docs/MEASUREMENTS.md, 'Why the capture-FULL note excludes a retained tail'.
  local istail = (sdec.res ~= nil and sdec.res.first ~= nil)
  if sdec.res ~= nil and sdec.res.nf > 0 and not istail then
    local cap = sdec.window_bytes(sdec.baud, sdec.res.nbits, sdec.res.par,
                                  sdec.res.nstop)
    if cap ~= nil and cap > 0 and sdec.res.nf >= cap then
      if sdec.force_baud == nil then
        add(string.format('capture FULL at %d bytes -- the message may continue; ' ..
                          'lock the baud rate for a longer window', cap or 0))
      else
        add(string.format('capture FULL at %d bytes -- the message may continue', cap or 0))
      end
    end
  end

  -- "Auto" parity with a forced width is not auto, the forced path taking `sdec.force_par or
  -- PAR_NONE` -- docs/MEASUREMENTS.md, 'Why a forced width assumes no parity'.
  if sdec.force_nbits ~= nil and sdec.force_par == nil then
    add('parity was ASSUMED none, not detected -- a forced width skips the search')
  end

  -- A property of the wire: a second stop bit is indistinguishable from a bit of idle.
  if sdec.res ~= nil and sdec.res.nbad == 0 and sdec.force_nbits == nil then
    add('stop-bit count is not observable from the wire; shown as 1')
  end
  return t, m
end

-- Character widths for the panel's small proportional face, bytes 32..126, as px + 48 so the table
-- is a printable literal -- docs/MEASUREMENTS.md, 'ui_cw, and the 1.159 render-to-panel factor'.
sdec.ui_cw = '55699?<3667:5655999999999955:::9'
          .. 'A<<==<:>=59<9?=><>=<:=<@<<:55589'
          .. '6999995993393?999969599=999656:'
sdec.ui_cw_def = 9        -- anything outside 32..126, which notes do not contain

-- Rendered width of `s` in px.
function sdec.ui_textw(s)
  if s == nil then return 0 end
  local w, i, n = 0, 1, string.len(s)
  local tab, def = sdec.ui_cw, sdec.ui_cw_def
  while i <= n do
    local b = string.byte(s, i)
    if b >= 32 and b <= 126 then
      w = w + string.byte(tab, b - 31) - 48
    else
      w = w + def
    end
    i = i + 1
  end
  return w
end

-- Headroom, ui_cw reading narrow -- docs/MEASUREMENTS.md, 'ui_cw, and the 1.159 render-to-panel factor'.
sdec.ui_fit_slack = 1.04

-- `s` clipped to fit `maxpx`, with '...' marking that it was clipped. The firmware clips at the
-- panel edge and says nothing, so an over-long string is cut without a mark.
function sdec.ui_fit(s, maxpx)
  if s == nil then return '' end
  maxpx = math.floor(maxpx / sdec.ui_fit_slack)
  if sdec.ui_textw(s) <= maxpx then return s end
  local ell = sdec.ui_textw('...')
  local budget = maxpx - ell
  if budget <= 0 then return '' end
  local w, i, n = 0, 1, string.len(s)
  while i <= n do
    local b = string.byte(s, i)
    local cw = sdec.ui_cw_def
    if b >= 32 and b <= 126 then cw = string.byte(sdec.ui_cw, b - 31) - 48 end
    if w + cw > budget then break end
    w = w + cw
    i = i + 1
  end
  return string.sub(s, 1, i - 1) .. '...'
end

-- The note cell, derived: as the literal 700 it drew through its own left rule when that moved.
sdec.ui_note_px = sdec.ui_rule_x1 - sdec.ui_note_val_x

-- 'page N of M' for the note row, or '' when there is nothing worth saying. 1-based, since 'page 0
-- of 35' names a page no button can reach, and computed rather than cached: ui_note_text reserves
-- room from this, and a second copy could describe a string that has left the screen.
function sdec.ui_pgind_text()
  if not sdec.ui_paged then return '' end
  local npg = sdec.ui_npages()
  if npg <= 1 then return '' end
  return string.format('page %d of %d', sdec.ui_page + 1, npg or 0)
end

-- Where the counter's four pieces go, right to left from ui_pgind_x. Returns x_page, x_n, x_of, x_m,
-- the two number x's being right edges (JUST_RIGHT) and the two word x's left edges.
function sdec.ui_pgind_layout()
  local g = sdec.ui_pgind_gap
  local wn = sdec.ui_textw(sdec.ui_pgind_dig)
  local xm = sdec.ui_pgind_x
  local xof = xm - wn - g - sdec.ui_textw('of')
  local xn = xof - g
  local xpage = xn - wn - g - sdec.ui_textw('page')
  return xpage, xn, xof, xm
end

-- How much of the note cell the counter holds. The fixed group extent, not today's string.
function sdec.ui_pgind_px()
  if sdec.ui_pgind_text() == '' then return 0 end
  local xpage = sdec.ui_pgind_layout()
  return (sdec.ui_pgind_x - xpage) + sdec.ui_note_gap
end

-- The one note the cell has room for, plus how many others there are. Both parts are fitted and the
-- marker wins when they compete, or a long note pushes '(+N more)' off the panel and nothing says a
-- second note exists. The page counter's width comes off the cell too; the firmware overlaps them.
function sdec.ui_note_text()
  local t, m = sdec.ui_notes()
  if m < 1 then return '' end
  local px = sdec.ui_note_px - sdec.ui_pgind_px()
  if m == 1 then return sdec.ui_fit(t[1], px) end
  local mk = string.format('  (+%d more)', m - 1)
  return sdec.ui_fit(t[1], px - sdec.ui_textw(mk)) .. mk
end

-- ============================================================================
-- Main screen
-- ============================================================================
-- Drop every display shadow cache: the caches let a refresh skip writes that would change nothing,
-- and they must go together with the objects they shadow. Every cache must be listed here -- an
-- omission brings the object back at its create-time colour while the stale cache suppresses the
-- write, so a capture with framing errors shows its error count in green. Keeping the caches few is
-- what makes the list maintainable, and ui_page is not one: it is view state.
function sdec.ui_invalidate()
  sdec.ui_last, sdec.ui_rowc = nil, nil
  -- ui_vrc shadows a whole array with one value, so a fifth cache costs little.
  sdec.ui_vrc = nil
  sdec.ui_sbc = nil
  -- Omitting any one of these three defeats the colour channel it shadows: a locked wire shows its
  -- values in the plain column colour, silently undoing the lock indicator.
  sdec.ui_fvalc, sdec.ui_trigsrcc, sdec.ui_logc = nil, nil, nil
  sdec.ui_trigc = nil
  sdec.ui_lockc = nil
  -- Omitting ui_progvis leaves a rebuilt bar believing it has already painted itself away.
  sdec.ui_progpct, sdec.ui_progvis = nil, nil
  -- The title bar's shadow. Without it a build in 8 kB mode keeps its create-time title for ever.
  sdec.ui_titletxt = nil
  return true
end

-- Delete every main-screen object and nil its handle.
function sdec.ui_destroy()
  -- Switch away before deleting a visible screen, and delete children before their screen. The cover
  -- counts as a screen to leave: gating on ui_scr alone deleted the screen the panel was showing.
  if sdec.ui_scr ~= nil or sdec.ui_loadscr ~= nil then
    pcall(display.changescreen, display.SCREEN_HOME)
  end
  local i
  if sdec.ui_row ~= nil then
    for i = 1, table.getn(sdec.ui_row) do sdec.del_obj(sdec.ui_row[i]) end
  end
  -- Deleted here and not after the screen: a delete against a dead parent is refused, and leaks.
  if sdec.ui_rhx ~= nil then
    for i = 1, table.getn(sdec.ui_rhx) do sdec.del_obj(sdec.ui_rhx[i]) end
    if sdec.ui_rhx2 ~= nil then
      for i = 1, table.getn(sdec.ui_rhx2) do sdec.del_obj(sdec.ui_rhx2[i]) end
    end
  end
  if sdec.ui_ras ~= nil then
    for i = 1, table.getn(sdec.ui_ras) do sdec.del_obj(sdec.ui_ras[i]) end
  end
  if sdec.ui_vr ~= nil then
    for i = 1, table.getn(sdec.ui_vr) do sdec.del_obj(sdec.ui_vr[i]) end
  end
  if sdec.ui_flab ~= nil then
    for i = 1, table.getn(sdec.ui_flab) do sdec.del_obj(sdec.ui_flab[i]) end
  end
  if sdec.ui_fval ~= nil then
    for i = 1, table.getn(sdec.ui_fval) do sdec.del_obj(sdec.ui_fval[i]) end
  end
  -- Every button, via a dense list, because ui_btn is positional and table.getn stops at a hole --
  -- docs/MEASUREMENTS.md, 'Deleting buttons from a dense list'.
  if sdec.ui_allbtn ~= nil then
    local ai
    for ai = 1, table.getn(sdec.ui_allbtn) do sdec.del_obj(sdec.ui_allbtn[ai]) end
    sdec.ui_allbtn = nil
  end
  -- Nil'd because ui_build only assigns these on success: a rebuild would inherit a dead handle.
  sdec.ui_pgbtn = nil
  sdec.ui_lockbtn = nil
  if sdec.ui_sb ~= nil then
    for i = 1, table.getn(sdec.ui_sb) do sdec.del_obj(sdec.ui_sb[i]) end
  end
  if sdec.ui_rule ~= nil then
    for i = 1, table.getn(sdec.ui_rule) do sdec.del_obj(sdec.ui_rule[i]) end
  end
  sdec.del_obj(sdec.ui_note)
  if sdec.ui_lock ~= nil then
    local li
    for li = 1, table.getn(sdec.ui_lock) do sdec.del_obj(sdec.ui_lock[li]) end
    sdec.ui_lock = nil
  end
  sdec.del_obj(sdec.ui_lockhit)
  sdec.del_obj(sdec.ui_trig_t)
  sdec.del_obj(sdec.ui_trighit)
  sdec.ui_lockbody, sdec.ui_lockc, sdec.ui_lockhit = nil, nil, nil
  -- The tick, deleted before its screen. sdec.stop() calling ui_tick_off() is what stops it firing.
  sdec.del_obj(sdec.ui_tick_obj)
  sdec.ui_tick_obj = nil
  sdec.del_obj(sdec.ui_page_t)
  sdec.del_obj(sdec.ui_log_t)
  if sdec.ui_pgind ~= nil then
    for i = 1, table.getn(sdec.ui_pgind) do sdec.del_obj(sdec.ui_pgind[i]) end
  end
  sdec.ui_pgind, sdec.ui_pgindtxt = nil, nil
  sdec.ui_pgind_w1, sdec.ui_pgind_n = nil, nil
  sdec.ui_pgind_w2, sdec.ui_pgind_m = nil, nil
  sdec.del_obj(sdec.ui_progbox)
  sdec.del_obj(sdec.ui_progline)
  sdec.ui_progbox, sdec.ui_progline = nil, nil
  sdec.del_obj(sdec.ui_scr)
  -- The loading screen, for the path that matters: a build that failed while it was still in front,
  -- which otherwise leaves "Loading, please wait..." up for ever. Not through ui_loading_clear().
  sdec.del_obj(sdec.ui_loadtxt)
  sdec.del_obj(sdec.ui_loadscr)
  sdec.ui_loadtxt, sdec.ui_loadscr = nil, nil
  sdec.ui_scr, sdec.ui_note = nil, nil
  sdec.ui_flab, sdec.ui_fval = nil, nil
  sdec.ui_row, sdec.ui_btn = nil, nil
  sdec.ui_rhx, sdec.ui_ras, sdec.ui_vr = nil, nil, nil
  sdec.ui_page_t, sdec.ui_log_t, sdec.ui_logc = nil, nil, nil
  sdec.ui_trig_t, sdec.ui_trighit, sdec.ui_trigc = nil, nil, nil
  sdec.ui_sb, sdec.ui_sbc, sdec.ui_rule = nil, nil, nil
  sdec.ui_invalidate()
  return true
end

-- A screen nobody is looking at, held in front while the real ones are assembled.
-- Creating a screen makes it the active one, which is why the operator can otherwise watch this app
-- build itself, in the wrong order, ending on a jump. Raised after every screen create, not once at
-- the start, and idempotent so the call sites do not have to care. Never fatal: the pool can be
-- exhausted, and a missing cover costs only a visible build.
function sdec.ui_loading_front()
  if sdec.ui_loadscr == nil then return false end
  pcall(display.changescreen, sdec.ui_loadscr)
  return true
end

function sdec.ui_loading_raise()
  if sdec.ui_loadscr == nil then
    local h = display.create(display.ROOT, display.OBJ_SCREEN, 'SERIAL DECODE')
    if h == nil then return false end
    sdec.ui_loadscr = h
    -- One line of text, because the title bar alone reads as a half-drawn screen. Centred on the
    -- medium face, which is not the face ui_textw() measures: its number puts this 29 px left.
    sdec.ui_loadtxt = display.create(h, display.OBJ_TEXT, 261, 214,
                                     'Loading, please wait...', 0xFFFFFF, display.FONT_MEDIUM)
  end
  -- The create above already took the front, so this is only for a raise over an existing cover.
  pcall(display.changescreen, sdec.ui_loadscr)
  return true
end

-- Put the real screen in front and take the loading screen away. Switch first, delete second, the
-- rule ui_destroy follows. The switch is unconditional: a nil `showscr` read as "do not switch"
-- left the panel displaying a deleted object, so it falls back to SCREEN_HOME.
function sdec.ui_loading_clear(showscr)
  if showscr == nil then showscr = display.SCREEN_HOME end
  pcall(display.changescreen, showscr)
  if sdec.ui_loadscr == nil then return false end
  sdec.del_obj(sdec.ui_loadtxt)
  sdec.del_obj(sdec.ui_loadscr)
  sdec.ui_loadtxt, sdec.ui_loadscr = nil, nil
  return true
end

-- Build the main screen: status fields, dump rows, rules and buttons. `hold` keeps the loading
-- screen up for the caller, which only start() needs, it alone building a second screen afterwards.
function sdec.ui_build(hold)
  -- Destroy first, always. Creating over a live handle overwrites the only reference to the object
  -- beneath, stranding it until a power cycle; that accumulation walks the firmware into a panic.
  sdec.ui_destroy()
  sdec.ui_invalidate()

  local create = display.create
  local small, med = display.FONT_SMALL, display.FONT_MEDIUM
  local left = display.JUST_LEFT
  local x = sdec.ui_x

  sdec.ui_scr = create(display.ROOT, display.OBJ_SCREEN, sdec.ui_title_text())

  -- display.create returns nil when the pool is exhausted, posts nothing and does not raise, so
  -- without this every child is built against a nil parent and start()'s pcall sees success --
  -- docs/MEASUREMENTS.md, 'The display object pool fails silently'.
  if sdec.ui_scr == nil then
    error('display object pool exhausted -- power cycle the instrument. (The firmware posts '
          .. 'event 1701 only once, then display.create returns nil silently.)', 0)
  end

  -- Before the first child: creating ui_scr took the front, so the build would be drawn in view.
  sdec.ui_loading_raise()

  -- Table rules first, so the text is created after and cannot be painted over.
  sdec.ui_rule = {}
  local nr = 0
  local function rule(rx, ry, rw, rh)
    local h = create(sdec.ui_scr, display.OBJ_RECT, rx, ry, rw, rh)
    if h ~= nil then
      nr = nr + 1
      sdec.ui_rule[nr] = h
      sdec.ui_fill_solid(h)
      sdec.ui_fill(h, sdec.ui_c_rule)
    end
  end
  local rw = sdec.ui_rule_x1 - sdec.ui_rule_x0
  rule(sdec.ui_rule_x0, sdec.ui_stat_top, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_stat_bot, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_rule_x1, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_stat_div, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_trig_div, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_rule_x0, sdec.ui_rule_top, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_hdr, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_mid, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_bot, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  rule(sdec.ui_rule_x1, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  -- The note row is one wide cell, not part of the grid: carrying every separator through it draws
  -- lines across the note text. Only the trigger-source divider continues, from ui_fields[2].x.
  rule(sdec.ui_fields[2].x - 9, sdec.ui_rule_mid, 1,
       sdec.ui_rule_bot - sdec.ui_rule_mid)

  -- The dump's two vertical rules: offset | hex | ascii. Nothing closes the ASCII column, its width
  -- not being knowable, and these live outside ui_rule because they are recoloured per refresh.
  sdec.ui_vr = {}
  local vi, vx
  for vi, vx in ipairs({sdec.ui_vr1_x, sdec.ui_vr2_x}) do
    local h = create(sdec.ui_scr, display.OBJ_RECT, vx, sdec.ui_vr_y0, 1,
                     sdec.ui_vr_y1 - sdec.ui_vr_y0)
    if h ~= nil then
      -- Solid, or a 1 px rule at 0 % fill is invisible whatever colour it carries.
      sdec.ui_fill_solid(h)
      sdec.ui_vr[vi] = h
    end
  end

  sdec.ui_flab, sdec.ui_fval = {}, {}
  -- No hit rect over BAUD + FORMAT and no setevent: EVENT_PRESS does not reach an OBJ_RECT (1717) at
  -- severity 2, which raises a dialog over the panel, and a rect draws an outline whether filled or
  -- not, brighter than any rule.
  sdec.ui_lockhit = nil

  local nf = table.getn(sdec.ui_fields)
  local j
  for j = 2, nf do
    rule(sdec.ui_fields[j].x - 9, sdec.ui_rule_top,
         1, sdec.ui_rule_mid - sdec.ui_rule_top)
  end
  for j = 1, nf do
    local fd = sdec.ui_fields[j]
    -- fd.labdx nudges the label only: a label as wide as its column butts against the divider.
    sdec.ui_flab[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x + (fd.labdx or 0), sdec.ui_lab_y,
                             fd.lab, sdec.ui_c_lab, small, left)
    -- Small, not medium, for every cell but the two flagged `med`: every field x is sized on the 8 px
    -- FONT_SMALL advance, and a medium LOGIC value takes 107 px and touches THRESH.
    local fnt = small
    if fd.med then fnt = med end
    -- fd.dy is per-cell, so ui_val_y stays the one baseline, and ui_field_band() reads the same sum.
    sdec.ui_fval[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x, sdec.ui_val_y + (fd.dy or 0),
                             '--', fd.c, fnt, left)
  end
  -- The padlock, four rects because the panel font has no padlock glyph, and worth counting: object
  -- creation is what destabilises this firmware -- docs/MEASUREMENTS.md, 'Rects, the padlock and
  -- the progress bar as objects'.
  local lx = 95
  sdec.ui_lock = {}
  local function lockpart(rx, ry, rw, rh)
    local h = create(sdec.ui_scr, display.OBJ_RECT, rx, ry, rw, rh)
    if h ~= nil then
      sdec.ui_lock[table.getn(sdec.ui_lock) + 1] = h
      sdec.ui_fill_solid(h)
      sdec.ui_fill(h, sdec.ui_c_auto)
    end
    return h
  end
  -- Dropped clear of ui_rule_hdr, which ran through a shackle anchored on ui_lab_y.
  local lock_y = sdec.ui_lab_y + 5
  lockpart(lx + 2, lock_y + 0, 5, 1)     -- shackle: top bar
  lockpart(lx + 2, lock_y + 1, 1, 4)     -- shackle: left post
  lockpart(lx + 6, lock_y + 1, 1, 4)     -- shackle: right post
  sdec.ui_lockbody = lockpart(lx, lock_y + 5, 9, 7)   -- body

  -- The trigger-source cell, top-left in the header grid, in a per-source colour: one text object,
  -- retexted and recoloured per refresh. In ui_flab so ui_destroy deletes it explicitly.
  sdec.ui_trigsrc_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_note_lab_x,
                             sdec.ui_note_y, sdec.ui_trigsrc.edge.name, sdec.ui_c_dim, small, left)
  sdec.ui_flab[nf + 1] = sdec.ui_trigsrc_t
  sdec.ui_note = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_note_val_x,
                        sdec.ui_note_y, '', sdec.ui_c_warn, small, left)

  -- Four fields per row. ui_row is the leftmost, so a non-hex view writes its whole line there.
  sdec.ui_row, sdec.ui_rhx, sdec.ui_rhx2, sdec.ui_ras = {}, {}, {}, {}
  local i
  for i = 1, sdec.ui_nrow do
    local y = sdec.ui_row_y0 + (i - 1) * sdec.ui_row_dy
    sdec.ui_row[i] = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_col_ix, y, '',
                            sdec.ui_c_off, small, left)
    sdec.ui_rhx[i] = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_col_hx, y, '',
                            sdec.ui_c_data, small, left)
    sdec.ui_rhx2[i] = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_col_hx2, y, '',
                             sdec.ui_c_data, small, left)
    sdec.ui_ras[i] = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_col_as, y, '',
                            sdec.ui_c_data, small, left)
  end

  sdec.ui_sb = {}
  for i = 1, sdec.ui_sb_show and sdec.ui_sb_n or 0 do
    local sy = sdec.ui_row_y0 + (i - 1) * sdec.ui_row_dy
    local h = create(sdec.ui_scr, display.OBJ_RECT, sdec.ui_sb_x, sy,
                     sdec.ui_sb_w, sdec.ui_sb_h)
    sdec.ui_sb[i] = h
    sdec.ui_fill_solid(h)
    sdec.ui_fill(h, sdec.ui_c_sb_off)
  end
  sdec.ui_sbc = {}

  -- The progress bar, two rects, built before ui_page_t because creation order is z-order here and
  -- the resting strings are the longer ones -- docs/MEASUREMENTS.md, 'The progress bar extents'.
  sdec.ui_progbox = create(sdec.ui_scr, display.OBJ_RECT, sdec.ui_prog_x, sdec.ui_prog_y,
                           sdec.ui_prog_w, sdec.ui_prog_h)
  sdec.ui_fill(sdec.ui_progbox, sdec.ui_c_prog_box)
  pcall(display.setthickness, sdec.ui_progbox, 1)
  sdec.ui_progline = create(sdec.ui_scr, display.OBJ_LINE, sdec.ui_prog_x + 1, sdec.ui_prog_ly,
                            sdec.ui_prog_x + 1, sdec.ui_prog_ly)
  sdec.ui_fill(sdec.ui_progline, sdec.ui_c_prog)
  pcall(display.setthickness, sdec.ui_progline, sdec.ui_prog_lw)
  -- Hidden until a run needs it. The caches are nil, so this genuinely writes STATE_INVISIBLE to both
  -- rather than believing they are already away -- the bug that put a grey frame on the glass.
  sdec.ui_progbar_set(nil)

  -- A tick, so the key is noticed without a press; interval and cost are at sdec.ui_tick_s --
  -- docs/MEASUREMENTS.md, 'display.OBJ_TIMER is the only periodic work'.
  local tok, tobj = pcall(display.create, sdec.ui_scr, display.OBJ_TIMER, sdec.ui_tick_s,
                          display.TIMER_FOREVER)
  sdec.ui_tick_obj = nil
  if tok then sdec.ui_tick_obj = tobj end
  if sdec.ui_tick_obj ~= nil then
    pcall(display.setevent, sdec.ui_tick_obj, display.EVENT_PRESS, 'sdec.guard(sdec.ui_tick)')
  end

  sdec.ui_page_t = create(sdec.ui_scr, display.OBJ_TEXT, x, sdec.ui_stat_y, '',
                          sdec.ui_c_dim, small, left)
  sdec.ui_log_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_stat_div + 6,
                         sdec.ui_stat_y, '',
                         sdec.ui_c_dim, small, left)
  -- No hit rect over the trigger cell: a rect refuses EVENT_PRESS and still draws its outline.
  sdec.ui_trighit = nil
  sdec.ui_trig_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_trig_x, sdec.ui_stat_y,
                          'TRIG', sdec.ui_c_warn, small, left)

  local by = sdec.ui_btn_y
  sdec.ui_btn = {}
  -- Dense, appended in creation order, and the only list ui_destroy deletes buttons from.
  sdec.ui_allbtn = {}
  local b
  -- Six buttons across 8..774. `View` and `Mode` are static labels, the state they cycle to being
  -- named elsewhere -- docs/MEASUREMENTS.md, 'The six bottom buttons and the three in the margin'.
  local bdef = {
    {x = 8,   w = 120, t = 'Capture',    e = 'sdec.capture'},
    {x = 152, w = 90,  t = 'View',       e = 'sdec.view_toggle'},
    {x = 266, w = 100, t = 'Mode',       e = 'sdec.mode_cycle'},
    {x = 390, w = 112, t = 'NewLog',     e = 'sdec.log_new', hide = 'ui_newlogbtn'},
    -- `hide` keeps a button's handle by name as well as by index, because ui_page_btns reaches it
    -- every refresh and ui_btn is positional: reordering this table would hide the wrong control.
    {x = 526, w = 112, t = 'Save',       e = 'sdec.save', hide = 'ui_savebtn'},
    {x = 662, w = 112, t = 'Options',    e = 'sdec.options'},
  }
  -- Up, Lock Rate, Dn, in that vertical order, each hiding itself when it has nothing to do. A
  -- paging control is not optional, a 32 kB capture being 137 pages, and narrowing these does not
  -- widen the text view -- docs/MEASUREMENTS.md, 'The six bottom buttons and the three in the margin'.
  local pbw, lbw = 56, 140
  local pdef = {
    {x = 785 - pbw, y = 58,  w = pbw, t = 'Up',        e = 'sdec.page_prev',  pg = true},
    {x = 785 - lbw, y = 160, w = lbw, t = 'Lock Rate', e = 'sdec.lock_toggle'},
    {x = 785 - pbw, y = 262, w = pbw, t = 'Dn',        e = 'sdec.page_next',  pg = true},
  }
  local pk, npg = nil, 0
  sdec.ui_pgbtn = {}
  for pk = 1, table.getn(pdef) do
    local pd = pdef[pk]
    local pb = create(sdec.ui_scr, display.OBJ_BUTTON, pd.x, pd.y, pd.t, pd.w)
    if pb ~= nil then
      display.setevent(pb, display.EVENT_PRESS, 'sdec.guard(' .. pd.e .. ')')
      sdec.ui_btn[table.getn(bdef) + pk] = pb
      sdec.ui_allbtn[table.getn(sdec.ui_allbtn) + 1] = pb
      if pd.pg then
        npg = npg + 1
        sdec.ui_pgbtn[npg] = pb
      else
        sdec.ui_lockbtn = pb
      end
    end
  end
  -- Which page of how many, on the note row, in four objects because a text object carries one
  -- colour and this line carries two -- docs/MEASUREMENTS.md, 'The page counter is four objects on
  -- the note row'.
  local xpage, xn, xof, xm = sdec.ui_pgind_layout()
  local ny = sdec.ui_note_y
  sdec.ui_pgind = {}
  local function pgpiece(px, pc, pj)
    local h = create(sdec.ui_scr, display.OBJ_TEXT, px, ny, '', pc, small, pj)
    if h ~= nil then sdec.ui_pgind[table.getn(sdec.ui_pgind) + 1] = h end
    return h
  end
  sdec.ui_pgind_w1 = pgpiece(xpage, sdec.ui_c_pgword, left)
  sdec.ui_pgind_n  = pgpiece(xn,    sdec.ui_c_pgnum,  display.JUST_RIGHT)
  sdec.ui_pgind_w2 = pgpiece(xof,   sdec.ui_c_pgword, left)
  sdec.ui_pgind_m  = pgpiece(xm,    sdec.ui_c_pgnum,  display.JUST_RIGHT)
  sdec.ui_pgindtxt = nil
  -- Visibility shadow caches, where nil means "unknown, so write it on the next refresh".
  -- sdec.ui_lockbtn is not one -- docs/MEASUREMENTS.md, 'The visibility shadow caches'.
  sdec.ui_pgvis = nil
  sdec.ui_lockvis = nil
  sdec.ui_savevis = nil
  sdec.ui_savebtn = nil
  sdec.ui_newlogbtn = nil
  local k
  local nb = 0
  for k = 1, table.getn(bdef) do
    local bd = bdef[k]
    b = create(sdec.ui_scr, display.OBJ_BUTTON, bd.x, by, bd.t, bd.w)
    if b ~= nil then
      display.setevent(b, display.EVENT_PRESS, 'sdec.guard(' .. bd.e .. ')')
      sdec.ui_btn[k] = b
      if bd.hide ~= nil then sdec[bd.hide] = b end
      sdec.ui_allbtn[table.getn(sdec.ui_allbtn) + 1] = b
      nb = nb + 1
    end
  end

  -- A screen with no buttons is not a usable app, and this catches a pool that ran out part way
  -- through: the screen exists, so the guard above passed, and there is nothing to press.
  if nb < table.getn(bdef) then
    error(string.format('only %d of %d buttons could be created -- display object pool exhausted. '
                        .. 'Power cycle the instrument.', nb or 0, table.getn(bdef) or 0), 0)
  end

  -- The cover comes down here unless the caller asked to keep it; the error paths leave it up.
  if not hold then sdec.ui_loading_clear(sdec.ui_scr) end

  return sdec.ui_scr
end

-- Save and NewLog, shown only when something the app writes could reach the key. -> true if the
-- visibility changed. Its own function because two callers need it and one guard must not gate
-- both: ui_page_btns() returns early on a build whose Page buttons failed to create, and this block
-- sat after that return. ui_savevis is written here and nowhere else.
function sdec.ui_usb_btns()
-- Both are hidden with no key in the slot, neither having a press that can succeed, and a button
-- that can only report a failure is worse than no button. STATE_INVISIBLE, not STATE_DISABLE, the
-- reference being explicit that disable is edit-objects only; log_live() names no path, and it is
-- what brings both back by themselves.
if sdec.ui_savebtn ~= nil or sdec.ui_newlogbtn ~= nil then
  local sw = sdec.log_live()
  if sw ~= sdec.ui_savevis then
    local sst = display.STATE_INVISIBLE
    if sw then sst = display.STATE_ENABLE end
    if sdec.ui_savebtn ~= nil then
      pcall(display.setstate, sdec.ui_savebtn, sst)
    end
    if sdec.ui_newlogbtn ~= nil then
      pcall(display.setstate, sdec.ui_newlogbtn, sst)
    end
    sdec.ui_savevis = sw
    return true
  end
end
  return false
end

function sdec.ui_page_btns()
  -- Save and NewLog first, before the guard: gating them on ui_pgbtn meant they could never hide.
  sdec.ui_usb_btns()
  local t = sdec.ui_pgbtn
  if t == nil then return false end
  local npg = sdec.ui_npages()
  local want = false
  if npg > 1 then want = true end
  -- The counter is not gated the way the buttons are: they appear whenever a page 2 exists, where it
  -- waits until the operator has paged. One cache for four objects, keyed on the whole line.
  if sdec.ui_pgind_n ~= nil then
    local ptxt = sdec.ui_pgind_text()
    if ptxt ~= sdec.ui_pgindtxt then
      local w1, nn, w2, mm = '', '', '', ''
      if ptxt ~= '' then
        w1, w2 = 'page', 'of'
        nn, mm = tostring(sdec.ui_page + 1), tostring(npg)
      end
      sdec.ui_set(sdec.ui_pgind_w1, w1)
      sdec.ui_set(sdec.ui_pgind_n, nn)
      sdec.ui_set(sdec.ui_pgind_w2, w2)
      sdec.ui_set(sdec.ui_pgind_m, mm)
      sdec.ui_pgindtxt = ptxt
    end
  end
  if want ~= sdec.ui_pgvis then
    local st = display.STATE_INVISIBLE
    if want then st = display.STATE_ENABLE end
    local i
    for i = 1, table.getn(t) do
      pcall(display.setstate, t[i], st)
    end
    sdec.ui_pgvis = want
  end

  -- Lock Rate is shown only in the 'auto' state: a button labelled 'Lock Rate' must not unlock, and
  -- unlocking is Options > Auto Detect -- docs/MEASUREMENTS.md, 'The six bottom buttons and the
  -- three in the margin'.
  if sdec.ui_lockbtn ~= nil then
    local lw = false
    if sdec.lock_state ~= nil and sdec.lock_state() == 'auto' then lw = true end
    if lw ~= sdec.ui_lockvis then
      local lst = display.STATE_INVISIBLE
      if lw then lst = display.STATE_ENABLE end
      pcall(display.setstate, sdec.ui_lockbtn, lst)
      sdec.ui_lockvis = lw
    end
  end

  return true
end

-- Repaint from the current decode result. settext only, which keeps a refresh cheap.
function sdec.ui_refresh_do()
  -- A bare call: every display write inside ui_page_btns() is already guarded one line at a time.
  sdec.ui_page_btns()
  if sdec.ui_scr == nil then return false end
  local set = sdec.ui_set

  local fv = sdec.ui_field_values()
  local j
  if sdec.ui_fvalc == nil then sdec.ui_fvalc = {} end
  for j = 1, table.getn(sdec.ui_fval) do
    set(sdec.ui_fval[j], fv[j] or '--')
    local want = sdec.ui_field_colour(j)
    if sdec.ui_fvalc[j] ~= want then
      sdec.ui_color(sdec.ui_fval[j], want)
      sdec.ui_fvalc[j] = want
    end
  end
  local lc = sdec.lock_colour()
  if sdec.ui_lockc ~= lc then
    local li
    for li = 1, table.getn(sdec.ui_lock or {}) do
      sdec.ui_fill(sdec.ui_lock[li], lc)
    end
    sdec.ui_lockc = lc
  end

  -- The trigger source, which distinguishes a hung capture from one waiting for an edge that is not
  -- coming. Falls back to 'Start bit' rather than blank: this carries the trigger key's only sign.
  local tsrc = sdec.ui_trigsrc[sdec.trigmode or 'edge'] or sdec.ui_trigsrc.edge
  set(sdec.ui_trigsrc_t, tsrc.name)
  if sdec.ui_trigsrcc ~= tsrc.c then
    sdec.ui_color(sdec.ui_trigsrc_t, tsrc.c)
    sdec.ui_trigsrcc = tsrc.c
  end
  -- The title bar names the mode too, retexted on change and guarded: a refusal must cost the bar.
  local ttl = sdec.ui_title_text()
  if sdec.ui_titletxt ~= ttl then
    if pcall(display.settext, sdec.ui_scr, ttl) then sdec.ui_titletxt = ttl end
  end
  set(sdec.ui_note, sdec.ui_note_text())

  local per, cols = sdec.ui_bytes_per_page()
  local npg = sdec.ui_npages()
  if sdec.ui_page >= npg then sdec.ui_page = npg - 1 end
  if sdec.ui_page < 0 then sdec.ui_page = 0 end
  local base = sdec.ui_page * per

  local mode = sdec.ui_mode
  local vw = sdec.ui_cur()
  local r = sdec.res
  -- The misaligned head, once for the whole loop: one number, and ua_head_bad walks errs for it.
  local hext, honscr = sdec.ui_head_extent()
  if not honscr then hext = nil end
  local i
  for i = 1, sdec.ui_nrow do
    local i0 = base + (i - 1) * cols + 1
    -- Hxs/ass must be blanked: a stale hex block behind a text view is a second, wrong reading.
    local txt, bad, hxs, hxs2, ass

    if vw.line ~= nil then
      -- One parsed message or frame per row, coloured from its own kind rather than from the byte
      -- error list: a LIN break is a framing error at the byte layer and no fault at the frame layer.
      txt = ''
      bad = false
      local fn = sdec[vw.line]
      if fn ~= nil then txt = fn(i0) end
      local pr = sdec[vw.res]
      if pr ~= nil and pr.kind ~= nil then bad = (pr.kind[i0] == 'err') end
    else
      if mode == 'hex' then txt, hxs, hxs2, ass = sdec.ua_hex_parts_line(i0, cols)
      else txt = sdec.ua_text_line(i0, cols) end
      -- Colour the whole row when a frame failed its stop or parity bit: per-row finds the damage.
      bad = false
      -- Or when it lies inside a misaligned head, whether or not those frames failed a check: the
      -- bit boundaries are wrong there, so a frame can pass by luck and hand back a wrong byte.
      if hext ~= nil and i0 <= hext then bad = true end
      if r ~= nil then
        local j
        for j = i0, i0 + cols - 1 do
          -- Any flagged byte reddens its row, edges included: excluding the first ua_edge_frames drew
          -- '???OWN FOX JUMPS' in white. ERR excludes those edges, so a red row with ERR 0 is meant.
          if j <= r.nf and r.errs[j] ~= nil then bad = true end
        end
      end
    end

    set(sdec.ui_row[i], txt)
    set(sdec.ui_rhx[i], hxs or '')
    set(sdec.ui_rhx2[i], hxs2 or '')
    set(sdec.ui_ras[i], ass or '')
    local want = sdec.ui_c_data
    if bad then want = sdec.ui_c_err end
    if sdec.ui_rowc == nil then sdec.ui_rowc = {} end
    if sdec.ui_rowo == nil then sdec.ui_rowo = {} end
    -- The leftmost object is not always the offset: in every other view it holds the whole line.
    local woff = want
    if mode == 'hex' then
      -- Dim on a healthy row; a bad row is red all the way across or the eye misses it.
      woff = sdec.ui_c_off
      if bad then woff = want end
    end
    -- The cache key carries the offset colour too, so switching hex <-> text repaints it.
    if sdec.ui_rowc[i] ~= want or sdec.ui_rowo[i] ~= woff then
      sdec.ui_rowo[i] = woff
      sdec.ui_color(sdec.ui_row[i], woff)
      -- Both hex fields and the ASCII carry the row's colour, or one field reads as the wrong one.
      sdec.ui_color(sdec.ui_rhx[i], want)
      sdec.ui_color(sdec.ui_rhx2[i], want)
      sdec.ui_color(sdec.ui_ras[i], want)
      sdec.ui_rowc[i] = want
    end
  end

  -- The vertical rules belong to the hex view, and the view decides, not the mode --
  -- docs/MEASUREMENTS.md, 'Why the vertical rules follow the view alone'.
  local vwant = sdec.ui_c_hide
  if mode == 'hex' then
    vwant = sdec.ui_c_rule
  end
  if sdec.ui_vrc ~= vwant then
    local vi
    for vi = 1, table.getn(sdec.ui_vr or {}) do
      sdec.ui_fill(sdec.ui_vr[vi], vwant)
    end
    sdec.ui_vrc = vwant
  end

  sdec.ui_bar(npg)

  local nit = sdec.ui_nitems()
  local mname = vw.name or 'TEXT'
  -- The protocol qualifies the status word rather than taking a header column: there is no room.
  local st = sdec.ui_status
  if sdec.proto ~= nil and sdec.proto ~= 'uart' then
    st = string.upper(sdec.proto) .. ' ' .. st
  end
  -- delfails/fillfails are display-API refusals, and this row is the only place that reports them.
  local warn = ''
  if (sdec.delfails or 0) > 0 or (sdec.fillfails or 0) > 0 then
    warn = string.format('  del?%d fill?%d', sdec.delfails or 0, sdec.fillfails or 0)
  end
  -- The status row leads with the capture mode, the setting that changes what capture does. The
  -- streaming modes get a different row: they produce a file, so page/of/bytes describes nothing.
  local md = sdec.mode_cur()
  -- A finished stream keeps the row until the mode is cycled, or its own summary would be replaced.
  if md.view and sdec.ck_tot == nil and not sdec.ck_running then
    -- The window capacity, not just the byte count: '97 of 97' does not say the capture could have
    -- held 192, answering "was the message seen whole?". It moves with the sample rate.
    local capn = nil
    if sdec.res ~= nil then
      capn = sdec.window_bytes(sdec.baud, sdec.res.nbits, sdec.res.par, sdec.res.nstop)
    end
    local wintxt = ''
    if capn ~= nil and capn > 0 then wintxt = string.format(' win %d', capn or 0) end
    -- Compact, because this string has to fit its cell at every baud rate and in every view. 'pg' and
    -- 'N-M/T' drop words rather than numbers; the unit name stays, bytes against msg being the point.
    set(sdec.ui_page_t, string.format('%s %s pg %d/%d %s %d-%d/%d%s [%s]%s',
        tostring(md.name), tostring(mname), sdec.ui_page + 1, npg or 0, tostring(sdec.ui_unit()),
        math.min(base + 1, nit), math.min(base + per, nit), nit or 0, tostring(wintxt), tostring(st), tostring(warn)))
  else
    set(sdec.ui_page_t, string.format('%s  %s%s', tostring(md.name), tostring(sdec.ck_status()), tostring(warn)))
  end
  -- The bar follows the row above, and this is the call that takes it away when a run ends.
  sdec.ui_progbar_set(sdec.ck_pct())
  -- The rear BNC, and which way it is pointing: empty when off, TRIG IN green, TRIG OUT amber,
  -- TRIG I/O cyan -- docs/MEASUREMENTS.md, 'The rear BNC cell states and the uncertainty mark'.
  local trigtxt, trigcol = '', sdec.ui_c_dim
  local tin, tout = (sdec.trigext == true), (sdec.fc_out == true)
  -- 'TRIG', not 'ext TRIG': the cell is 122 px and 'EXT TRIG OUT' is 123.
  if tin and tout then trigtxt, trigcol = 'TRIG I/O', sdec.ui_c_extio
  elseif tin then trigtxt, trigcol = 'TRIG IN', sdec.ui_c_extin
  elseif tout then trigtxt, trigcol = 'TRIG OUT', sdec.ui_c_extout
  end
  if tin and sdec.trigmode == 'free' then trigtxt = trigtxt .. '?' end
  set(sdec.ui_trig_t, trigtxt)
  if sdec.ui_trigc ~= trigcol then
    sdec.ui_color(sdec.ui_trig_t, trigcol)
    sdec.ui_trigc = trigcol
  end

  -- ui_runnote() carries this cell's whole decision, ui_log_owned() included, so the branch that used
  -- to be written out here cannot drift from the one a press or an armnote takes.
  set(sdec.ui_log_t, sdec.ui_runnote())
  return true
end

-- Refresh the panel, and never raise doing it. -> true, or false if the body gave up part way.
-- One guard here, not one at each call site: sixteen callers wrapped this in a pcall of their own,
-- which guards app code rather than a firmware boundary, where what they feared was this body
-- formatting a nil. A refresh is cosmetic and must not cost its caller a correct capture.
function sdec.ui_refresh()
  return (pcall(sdec.ui_refresh_do))
end

-- The byte log, for the status row: which file is being appended to, and how many BYTES are in it
-- so far. Both, always, in every mode, the app's promise being that no decoded byte is lost.
-- It has 188 px and the obvious form does not fit, so the '.txt' goes and the name gives way,
-- trimmed from the left with a '~'; the count never does, being what audits the promise --
-- docs/MEASUREMENTS.md, 'The three status row cells'.
function sdec.flog_status()
  if sdec.flog_why ~= nil then return 'log: NOT LOGGING' end
  -- No key outranks both the filename and the promise, and has to be asked first: a path outlives
  -- the key -- docs/MEASUREMENTS.md, 'Why flog_status asks about the key before the filename'.
  if not sdec.log_live() then return 'log: no USB key' end
  -- Any mode_exit drops the path so the next run opens a new numbered file, and remembers the name
  -- only when that run wrote bytes to this key. So nothing to name means nothing written, Log New, or
  -- a swapped key -- not merely that no file is open.
  local path, n = sdec.flog_path, sdec.flog_bytes or 0
  if path == nil then
    -- And a swapped key makes a remembered name a stranger's, so the generation has to match: the
    -- key, not the path, is what MODE_APPEND would extend. nil-safe for a build without usb_log.tsp.
    local gen = (ulog ~= nil and ulog.keygen) or 0
    if sdec.flog_last == nil or sdec.flog_lastgen ~= gen then return 'log: on first capture' end
    path, n = sdec.flog_last, sdec.flog_lastbytes or 0
  end
  local base = string.gsub(tostring(path), '^.*/', '')
  base = string.gsub(base, '%.txt$', '')
  local s = string.format('log: %s  %d B', tostring(base), n)
  -- Bounded by the name length, so a cell too narrow for a 4-character name returns the overlong
  -- string rather than looping. The first step drops four characters: one can make it wider.
  local first = true
  while sdec.ui_textw(s) > sdec.ui_log_px and string.len(base) > 4 do
    if first then base = string.sub(base, 5) else base = string.sub(base, 2) end
    first = false
    s = string.format('log: ~%s  %d B', tostring(base), n or 0)
  end
  return s
end

-- The streaming modes' status text: progress while running, then the outcome. Separate from
-- ui_refresh so sdec.progress() can write the same object once a second without touching the other
-- ~20, every display call being an IPC round trip.
function sdec.ck_status()
  local t = sdec.ck_tot
  local md = sdec.mode_cur()
  if sdec.ck_running then
    -- A press-driven recording states its control and nothing else: no Lua of ours runs between the
    -- start press and the stop press, so any figure here stays at 0 % for the whole recording.
    if sdec.strm_recording then return 'recording -- press Capture to stop' end
    -- Which window, when there is more than one, counted from window 1 -- docs/MEASUREMENTS.md,
    -- 'The window counter counts from window 1'.
    local wtxt = ''
    if sdec.fc_out then
      wtxt = string.format(' win %d/%d', (sdec.fc_win or 0) + 1, sdec.fc_maxwin or 32)
    end
    -- Two phases: nothing is decoded while the digitizer fills the buffer, so percent of the buffer
    -- is the honest number there. The words and the window counter are alternatives, not both.
    if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then
      local have, want = sdec.ck_acq_have or 0, sdec.ck_acq_want or 0
      local pct = 0
      if want > 0 then pct = math.floor(100 * have / want) end
      if wtxt ~= '' then return string.format('recording...%s %d %%', tostring(wtxt), pct or 0) end
      return string.format('recording... %d %% of the buffer', pct)
    end
    -- The stop control is not said here: controls belong in the right-hand cell, which has room.
    local cap = md.cap
    if cap ~= nil then
      if wtxt ~= '' then
        return string.format('decoding...%s %d/%d', tostring(wtxt), sdec.ck_nbytes or 0, cap or 0)
      end
      return string.format('decoding... %d/%d bytes', sdec.ck_nbytes or 0, cap or 0)
    end
    if wtxt ~= '' then return string.format('decoding...%s %d', tostring(wtxt), sdec.ck_nbytes or 0) end
    return string.format('decoding... %d bytes', sdec.ck_nbytes or 0)
  end
  -- Short, always: this row shares its line with the log status. The remedy is on the note line.
  if t == nil then
    if sdec.mode_why(md) ~= nil then return 'not armed -- see the note' end
    -- The max for this mode, stated before the capture rather than discovered after it.
    if md.cap ~= nil then
      -- And that nothing cuts it short, which is the other half of what the operator needs before
      -- pressing: neither a button nor the trigger key can, measured. No time figure at all.

      -- And whether it is going anywhere: with no key only the last sdec.ck_keep bytes survive, so
      -- 'to a file' is the one thing this row must not promise. It names both numbers.
      if not sdec.log_live() then
        local keep = sdec.ck_keep
        if keep ~= nil and keep < md.cap then
          return string.format('ready -- %d bytes, panel keeps the last %d', md.cap or 0, keep or 0)
        end
        return string.format('ready -- %d bytes, panel only (no USB key)', md.cap or 0)
      end
      return string.format('ready -- %d bytes to a file, no stop once started', md.cap or 0)
    end
    return 'ready -- no cap'
  end
  -- A nil path is a recording that had nowhere to go: 'USB' reported it as written to the key.
  local base = 'NOT recorded'
  if t.path ~= nil then base = string.gsub(tostring(t.path), '^.*/', '') end
  -- A multi-window run reports the transmission, not its last window: ck_tot describes one window, so
  -- '2048 bytes' under a 300 kB transmission is the wrong subject. fc_bytes is the total.
  if (sdec.fc_win or 0) > 1 then
    return string.format('%d bytes in %d windows -> %s  [%s]',
                         sdec.fc_bytes or 0, sdec.fc_win or 0, tostring(base),
                         sdec.fc_end or t.stopped or 'done')
  end
  -- ck_err_n, not t.nbad: the raw failure count put '1 err' under an 'ERR 7' on the same screen.
  return string.format('%d bytes  %d err  %d win  -> %s  [%s]',
                       t.nf or 0, sdec.ck_err_n(t) or 0, t.nwin or 0, tostring(base), t.stopped or 'done')
end

-- The fraction the progress bar shows, 0..100, or nil when no honest one exists. The two phases
-- have different denominators, as ck_status's text does: per cent of the buffer, then bytes against
-- the cap. nil for a press-driven recording, where a bar would hold 0 for the whole run.
function sdec.ck_pct()
  if not sdec.ck_running then return nil end
  if sdec.strm_recording then return nil end
  if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then
    local want = sdec.ck_acq_want or 0
    if want <= 0 then return nil end
    return 100 * (sdec.ck_acq_have or 0) / want
  end
  local cap = sdec.mode_cur().cap
  if cap == nil or cap <= 0 then return nil end
  return 100 * sdec.ck_nbytes / cap
end

-- The streaming status row: its text and its bar, written together so the two cannot disagree about
-- which phase the run is in. sdec.progress and sdec.progress_samples are the callers, one per phase.
-- Never raises, and the one guard that promises it lives here, not at either call site:
-- ck_status() is a 130-line text builder, so "this cannot raise" is a proof that would have to be
-- redone at every edit, and this row is painted from the capture loop, which cannot afford depth.
function sdec.progress_row()
  return (pcall(sdec.progress_row_do))
end

-- The row itself: one settext and one setfill. -> ui_progbar_set's verdict.
function sdec.progress_row_do()
  local md = sdec.mode_cur()
  sdec.ui_set(sdec.ui_page_t, string.format('%s  %s', tostring(md.name), tostring(sdec.ck_status())))
  return sdec.ui_progbar_set(sdec.ck_pct())
end

-- One settext and one setfill, at ~1 Hz. A bare call: progress_row() carries the guard.
function sdec.progress(nbytes)
  sdec.ck_nbytes = nbytes
  return sdec.progress_row()
end

-- Light the segments covering the current page; a single-page capture lights the whole bar.
function sdec.ui_bar(npg)
  if sdec.ui_sb == nil or table.getn(sdec.ui_sb) == 0 then return false end
  if npg == nil or npg < 1 then npg = 1 end
  local n = sdec.ui_sb_n
  local floor = math.floor

  local a = floor(sdec.ui_page * n / npg) + 1
  local b = floor((sdec.ui_page + 1) * n / npg)
  if b < a then b = a end          -- more pages than segments: at least one lit
  if a < 1 then a = 1 end
  if b > n then b = n end

  if sdec.ui_sbc == nil then sdec.ui_sbc = {} end
  local i
  for i = 1, n do
    local want = sdec.ui_c_sb_off
    if i >= a and i <= b then want = sdec.ui_c_sb_on end
    if sdec.ui_sbc[i] ~= want then
      if sdec.ui_fill(sdec.ui_sb[i], want) then sdec.ui_sbc[i] = want end
    end
  end
  return true
end

-- ============================================================================
-- Options form
-- ============================================================================
-- Index <-> value mappings for the OBJ_EDIT_OPTION fields: getvalue() is 1-based but each mapping
-- clamps, and the count travels as `n`, table.getn being unreliable on the nil holes these have.
-- Entries 1 and 2 of opt_bits_v both mean "no forced width"; 2 also turns on the rare widths.
sdec.opt_bits_v  = {nil, nil, 5, 6, 7, 8, 9, n = 7}
sdec.opt_par_v   = {nil, 0, 1, 2, n = 4}             -- entry 1 = Auto
-- Protocol entries, with the module each one needs. Version 1 ships UART only; the rest stay
-- described so that restoring either is one line in package_tspa.py MODULES, and a field listing an
-- absent parser would appear to work. Bare names, the value column fading past sdec.ui_opt_px.
sdec.opt_proto_all = {
  {v = 'uart', label = 'UART', need = nil},
  {v = 'midi', label = 'MIDI', need = 'mi_parse'},
  {v = 'lin',  label = 'LIN',  need = 'li_parse'},
  n = 3,
}

-- The subset this build can offer, values and labels. Computed on demand for the same ordering
-- reason as sdec.ui_view_avail(): the offline harnesses load the protocol modules after serial_ui.
function sdec.opt_proto_list()
  local vals, labs, n, i = {}, {}, 0, nil
  for i = 1, sdec.opt_proto_all.n do
    local e = sdec.opt_proto_all[i]
    if e.need == nil or sdec[e.need] ~= nil then
      n = n + 1
      vals[n] = e.v
      labs[n] = e.label
    end
  end
  vals.n, labs.n = n, n
  return vals, labs
end
sdec.opt_trig_v  = {'edge', 'free', 'front', n = 3}
-- The rear-BNC field's entries, as the booleans they stand for: a table reads in both directions.
sdec.opt_rear_v  = {{false, false}, {true, false}, {false, true}, {true, true}, n = 4}

-- Which Protocol entry `name` sits at. A reverse lookup, not a second list that would drift.
function sdec.opt_proto_i(name)
  local vals = sdec.opt_proto_list()
  local i
  for i = 1, vals.n do
    if vals[i] == name then return i end
  end
  return 1
end

-- Read one options field back as the value it stands for.
function sdec.opt_pick(tbl, idx)
  if tbl == nil then return nil end
  local n = tbl.n or table.getn(tbl)
  if type(idx) ~= 'number' then return tbl[1] end
  local i = math.floor(idx + 0.5)
  if i < 1 then i = 1 end
  if i > n then i = n end
  return tbl[i]
end

-- Delete every options-screen object and nil its handle.
function sdec.destroy_options()
  if sdec.optscr ~= nil then
    -- Switch away before deleting, or the firmware is left showing a deleted screen.
    local scr = sdec.ui_scr
    if scr == nil then scr = display.SCREEN_HOME end
    pcall(display.changescreen, scr)
    -- sdec.options() suspends the tick, so tearing the form down is one of the exits that re-arm.
    if sdec.ui_scr ~= nil then sdec.ui_tick_on() end
  end
  sdec.del_obj(sdec.opt_proto)
  sdec.del_obj(sdec.opt_baud)
  sdec.del_obj(sdec.opt_bits)
  sdec.del_obj(sdec.opt_par)
  sdec.del_obj(sdec.opt_pol)
  sdec.del_obj(sdec.opt_trig)
  sdec.del_obj(sdec.opt_ext)
  sdec.del_obj(sdec.opt_armv)
  sdec.del_obj(sdec.opt_armw)
  sdec.del_obj(sdec.opt_gape)
  if sdec.opt_btn ~= nil then
    local i
    for i = 1, table.getn(sdec.opt_btn) do sdec.del_obj(sdec.opt_btn[i]) end
    sdec.opt_btn = nil
  end
  sdec.del_obj(sdec.optscr)
  sdec.optscr, sdec.opt_proto, sdec.opt_baud = nil, nil, nil
  sdec.opt_bits, sdec.opt_par, sdec.opt_pol = nil, nil, nil
  sdec.opt_trig, sdec.opt_ext = nil, nil
  sdec.opt_armv, sdec.opt_armw, sdec.opt_gape = nil, nil, nil
  return true
end

-- Build the options screen, its edit fields and its four buttons. Returns the screen handle.
function sdec.build_options()
  sdec.destroy_options()
  local create = display.create
  local y0, dy, x = sdec.ui_opt_y0, sdec.ui_opt_dy, sdec.ui_opt_x
  -- How many fields there will be, decided before the pitch, because the pitch depends on it. The
  -- Protocol field exists only with a module loaded, OBJ_EDIT_OPTION refusing fewer than two options.
  local pv, pl = sdec.opt_proto_list()
  local nf = 9
  if pl.n >= 2 then nf = 10 end
  -- The pitch is clamped to what fits, ui_opt_dy being a preference and the last box having
  -- to end above the button row -- docs/MEASUREMENTS.md, 'The options form vertical geometry'.
  local eh, edy = sdec.ui_opt_edit_h, sdec.ui_opt_edit_dy
  -- Rows, not fields, is what the pitch has to clear: six fields in two columns is three rows.
  local ncols = sdec.ui_opt_cols or 1
  if ncols < 1 then ncols = 1 end
  local nrows = math.ceil(nf / ncols)
  local maxdy = math.floor((sdec.ui_opt_btn_y - (sdec.ui_opt_btn_gap or 0) - y0 - edy - eh) /
                           (nrows - 1))
  if dy > maxdy then dy = maxdy end
  -- Centred, because three rows do not fill the form. Only ever down, and only by what is spare.
  local used = (nrows - 1) * dy + eh + edy
  local spare = sdec.ui_opt_btn_y - used - y0
  if spare > 0 then y0 = y0 + math.floor(spare / 2) end
  -- Then nudged, and a separate number from y0 on purpose: the centring above divides the leftover
  -- space, so a move asked for through y0 gives back half of itself. Not applied when it would
  -- push the block off the top.
  local adj = sdec.ui_opt_y_adj or 0
  if y0 + adj >= 0 then y0 = y0 + adj end
  -- A pitch under the box height overlaps the boxes, so the column moves up instead.
  if dy < eh then
    dy = eh
    y0 = sdec.ui_opt_btn_y - edy - eh - (nrows - 1) * dy
    if y0 < 0 then y0 = 0 end
  end
  -- Published, because ui_opt_dy is only the preference and a check that reads it checks the wrong
  -- number: test_serial once reported 'pitch 54, box 50, gap 4' about a form laid out at 50.
  sdec.ui_opt_dy_used, sdec.ui_opt_nf_used, sdec.ui_opt_y0_used = dy, nf, y0
  -- Rows are allocated, not numbered, Version 1 omitting the Protocol field entirely: with only UART
  -- there is nothing to choose between, and a one-entry OBJ_EDIT_OPTION fails the build.
  local row = 0
  local function nextpos()
    local c = math.floor(row / nrows)
    if c > ncols - 1 then c = ncols - 1 end
    local fx = x
    if c > 0 then fx = sdec.ui_opt_x_c2 end
    local fy = y0 + (row - c * nrows) * dy
    row = row + 1
    return fx, fy
  end

  sdec.optscr = create(display.ROOT, display.OBJ_SCREEN, 'SERIAL DECODE OPTIONS')

  -- Same silent nil as ui_build's screen: an Options button that opens nothing is worse than a stop.
  if sdec.optscr == nil then
    error('display object pool exhausted building the options screen -- power cycle the '
          .. 'instrument.', 0)
  end

  -- And a cover here too, the create above having taken the front for the options screen. Who raised
  -- it decides who clears it -- docs/MEASUREMENTS.md, 'Who raises and who clears the loading cover'.
  local covermine = false
  if sdec.ui_loadscr == nil then
    covermine = sdec.ui_loading_raise()
  else
    sdec.ui_loading_front()
  end

  -- Protocol first, because it overrides the fields below it, and spelled out rather than unpack()'d
  -- -- docs/MEASUREMENTS.md, 'Why the Protocol field comes first and is spelled out'.
  if pl.n >= 3 then
    local fx1, fy1 = nextpos()
    sdec.opt_proto = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx1, fy1,
                            'Protocol', 'wire parameters',
                            pl[1], pl[2], pl[3])
  elseif pl.n == 2 then
    local fx2, fy2 = nextpos()
    sdec.opt_proto = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx2, fy2,
                            'Protocol', 'sets the wire parameters', pl[1], pl[2])
  end
  -- pl.n == 1 creates nothing and sdec.opt_proto stays nil, which every reader copes with. Baud 0
  -- means auto, hence a minimum of 0: a spinner that cannot say "work it out" forces a guess.
  local fx3, fy3 = nextpos()
  sdec.opt_baud = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx3, fy3,
                         'Baud Rate', '0 = auto-detect',
                         -- Left at the firmware's 6 digits, unlike the two arm fields: a typed rate can
                         -- be 104857 Bd, and 4 significant digits would show it as 104.9k.
                         display.NFORMAT_PREFIX, 0, 0, 1000000, 'Bd')
  -- 'Auto (7/8)' is the default and deliberately first, and forcing a width bypasses the search --
  -- docs/MEASUREMENTS.md, 'Why only 7 and 8 data bits are searched by default'.
  local fx4, fy4 = nextpos()
  sdec.opt_bits = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx4, fy4,
                         'Data Bits', 'auto, or fix it',
                         'Auto (7/8)', 'Auto (any)', '5', '6', '7', '8', '9')
  local fx5, fy5 = nextpos()
  sdec.opt_par = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx5, fy5,
                        'Parity', 'auto or fixed',
                        'Auto', 'None', 'Even', 'Odd')
  -- Eleven characters is the field's limit: past it the firmware fades the tail, so 'Trig In+FC Out'
  -- reads 'Trig In+FC'. Display only -- every field maps its selection by index.
  local fx6, fy6 = nextpos()
  sdec.opt_pol = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx6, fy6,
                        'Polarity', 'idle level',
                        'Auto', 'Idle high', 'Idle low')
  -- No range selector, 10 V having the bandwidth, and three trigger sources rather than four --
  -- docs/MEASUREMENTS.md, 'Why the 10 V range is the only one offered'.
  local fx7, fy7 = nextpos()
  sdec.opt_trig = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx7, fy7,
                         'Trigger', 'capture start',
                         sdec.ui_trigsrc[sdec.opt_trig_v[1]].name,
                         sdec.ui_trigsrc[sdec.opt_trig_v[2]].name,
                         sdec.ui_trigsrc[sdec.opt_trig_v[3]].name)
  -- One field for both rear BNCs, and the reason is height. Off by default is a requirement, not a
  -- courtesy -- docs/MEASUREMENTS.md, 'Why one field carries both rear BNCs'.
  local fx8, fy8 = nextpos()
  sdec.opt_ext = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx8, fy8,
                        'Rear BNC', 'trig in / FC out',
                        'Off', 'Trig In', 'FC Out', 'In + FC Out')

  -- The two armed-from-silence fields govern one case: Capture pressed on a line that is not
  -- transmitting yet. Their ranges come from the core -- docs/MEASUREMENTS.md, 'armlevel 1.0, floor
  -- 0.33, ceiling 6.0'.
  local fx9, fy9 = nextpos()
  -- 4 digits, not the firmware's default of 6: a comparator level of '1.00000 V' reads as a precision
  -- the setting does not have, and 1 mV is already finer than any logic swing cares about. The argument
  -- counts significant digits with a floor of 4, so 1 V shows as 1.000 and the 0.33 V minimum as 0.3300 --
  -- three decimals where it matters is the closest the firmware offers.
  sdec.opt_armv = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx9, fy9,
                         'Arm At', 'wake-up level',
                         display.NFORMAT_PREFIX, sdec.arm_level_v(),
                         sdec.armlevel_min, sdec.armlevel_max, 'V', 4)
  -- Seconds, and the panel is frozen for every one of them. The help says 'max' rather than 'timeout'
  -- because that is the operator-visible consequence: this is how long the panel may stop responding.
  -- The label carries both uses because one number serves both: the arm's wait for a line that has not
  -- started, and the quiet-line exit once it has. 13 characters is longer than any other label here, so
  -- check it on the glass after any change to the form's geometry.
  local fx10, fy10 = nextpos()
  sdec.opt_armw = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx10, fy10,
                         'Arm/Idle Wait', 'max wait, frozen',
                         display.NFORMAT_PREFIX, sdec.arm_wait_s(),
                         sdec.armwait_min, sdec.armwait_max, 's', 4)
  -- Zero is off, so the raw setting is shown rather than gap_elide()'s enforced window: the field has to be able
  -- to say 'off', and the accessor returns nil for that. The floor is applied when a capture arms, not here.
  -- 'cut after' says which of the two readings the number has: it is the quiet the line must reach before the
  -- recording stops keeping it, not how much gap comes out, which is unbounded. 16 characters, as wide as the
  -- Arm/Idle Wait help above it, so check it on the glass after any change to the form's geometry.
  local fx11, fy11 = nextpos()
  sdec.opt_gape = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx11, fy11,
                         'Gap Elide', '0 off, cut after',
                         display.NFORMAT_PREFIX, tonumber(sdec.gapelide) or 0,
                         0, sdec.gapelide_max, 's', 4)

  -- Stored, not left in locals: destroy_options() deletes them. Lock Detected only fills the form.
  sdec.opt_btn = {}
  -- Auto Detect is the inverse of Lock Detected and sits beside it. Guarded, like ui_build's button
  -- loops -- docs/MEASUREMENTS.md, 'The options form field and button widths'.
  local odef = {
    {i = 4, x = 22,  w = 200, t = 'Auto Detect',   e = 'sdec.options_auto'},
    {i = 1, x = 234, w = 220, t = 'Lock Detected', e = 'sdec.options_lock'},
    {i = 2, x = 466, w = 150, t = 'Apply',         e = 'sdec.options_apply'},
    {i = 3, x = 628, w = 150, t = 'Cancel',        e = 'sdec.options_cancel'},
  }
  local ok, nob = nil, 0
  for ok = 1, table.getn(odef) do
    local od = odef[ok]
    local ob = create(sdec.optscr, display.OBJ_BUTTON, od.x, sdec.ui_opt_btn_y, od.t, od.w)
    if ob ~= nil then
      display.setevent(ob, display.EVENT_PRESS, 'sdec.guard(' .. od.e .. ')')
      sdec.opt_btn[od.i] = ob
      nob = nob + 1
    end
  end
  -- A form with no way out is worse than no form: Cancel is one of these four.
  if nob < table.getn(odef) then
    error(string.format('only %d of %d options buttons could be created -- display object pool '
                        .. 'exhausted. Power cycle the instrument.', nob or 0, table.getn(odef) or 0), 0)
  end

  -- Hook End App on this screen too: if the firmware delivers EVENT_ENDAPP only to the visible
  -- screen, exiting from the form would strand both screens and the buffer until a power cycle.
  pcall(display.setevent, sdec.optscr, display.EVENT_ENDAPP, 'sdec.guard(sdec.cleanup)')

  -- The cover comes down only if this function raised it; on a launch start() owns it.
  if covermine then sdec.ui_loading_clear(sdec.optscr) end
  return sdec.optscr
end

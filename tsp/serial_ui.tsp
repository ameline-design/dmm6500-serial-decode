-- serial_ui.tsp -- front-panel screens for the DMM6500 serial decoder
-- (TSP / Lua 5.0.2).
--
-- PANEL CONSTRAINTS (measured, taken as given):
--
--  * Object y is relative to the screen CONTENT area, 49 px below the panel top,
--    so a child at y=350 lands on panel row 399. X needs no correction.
--  * Coordinate limits are X 1..798, Y 0..420.
--  * display.create rejects a width of 800 (error 1130) and returns NIL rather
--    than raising, so the object silently does not exist.
--  * A screen title over 31 characters is truncated (error 1707).
--  * display.setposition ERRORS on edit objects; their position is create-time
--    only, so the options form cannot be re-laid-out afterwards.
--  * Edit objects draw label and description to the LEFT of the value box, so the
--    box x must be >= ~270 or the labels run off the edge.
--  * OBJ_EDIT_OPTION getvalue/setvalue are 1-BASED.
--  * The font is PROPORTIONAL: nothing aligns by padding a string, so anything
--    that must line up needs its own fixed-x object.
--
-- OBJECTS PER DUMP ROW. A text object costs ~12 ms to create and one display message per
-- refresh; ~192 messages per refresh is the flood that hangs the display processor. Each
-- BLOCK starts at its own fixed x, so no block can drift into the next however wide the
-- font's glyphs turn out to be.
--
--   4/row    60 objects, <=60 writes/refresh. THIS: offset, two 8-byte hex groups, ASCII.
--   7/row   105 objects. Offset + four 4-byte groups + ASCII. The escalation if columns come
--            out ragged WITHIN a block: it bounds drift to 4 bytes. Not built.
--   18/row  270 objects, ~3 s to build alone. UNAFFORDABLE -- one field per hex pair aligns
--            perfectly and cannot be paid for. Do not go here; take 7/row instead.
--
-- THE FONT'S CHARACTER ADVANCE IS AN ESTIMATE, and every column x derives from one constant
-- (sdec.ui_ch_w), so correcting it is a one-line change rather than a re-layout. Within a
-- block, columns align only if the digit glyphs are equal-width; digits are usually tabular.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

-- ---------- main screen geometry (object coordinates) ----------
-- 13 chars, inside the 31-char title truncation limit.
--
-- display.settext() DOES work on an OBJ_SCREEN -- undocumented (the Display API reference lists
-- only OBJ_TEXT and the OBJ_EDIT_* family as valid targets), verified on firmware 1.7.17a -- so
-- the title bar is available for saying what the app is doing. The bar cannot be RECOLOURED:
-- display.setcolor on a screen is refused with 1717, 'does not apply to an object of type Custom
-- Screen'. Words go in the bar; the mode cell carries the colour.
sdec.ui_title    = 'SERIAL DECODE'

-- ---------- header field strip ----------
-- One row of dim labels over one row of bright values, each field at its own fixed x.
-- Separate objects per field are the only way to align columns in a PROPORTIONAL font --
-- padding a single string cannot do it. The labels are static and written once at build;
-- only the values are refreshed.
--
-- A TEXT OBJECT'S y IS THE BOTTOM OF ITS GLYPH BOX, NOT THE TOP. Measured from a panel
-- screenshot: dump rows created at content y = 66 ink panel rows 104..115, i.e. content
-- 55..66, so the ink occupies [y - 11, y] and the object grows UPWARD from its given y.
--
-- EVERY VERTICAL POSITION BELOW IS CHOSEN SO THAT NO HORIZONTAL RULE LANDS INSIDE ANY
-- [y - ui_ink + 1, y] BAND, and tools/test_serial.lua asserts exactly that. A rule inside a
-- band draws a line struck through the text, and the one-build-per-power-cycle rule means a
-- layout error costs a power cycle to see.
--
-- GLYPH INK HEIGHTS, per font, MEASURED from panel-v3.png in regions where only one row's ink
-- could fall. FONT_SMALL is 12 px and FONT_MEDIUM is 17: a medium value at y = 28 inks content
-- 12..28 while a small label at y = 14 inks 3..14, so those two collide over three rows. The
-- value row has to sit low enough that the TALLER font still clears the labels.
sdec.ui_ink = 12
sdec.ui_ink_med = 17
-- Character advances, MEASURED. FONT_SMALL is 8 px (docs/panel-ref-chrome.png, and
-- sdec.ui_ch_w below is the same number). FONT_MEDIUM is ~13.4 px, from the panel screenshot
-- where an 8-character LOGIC value spanned exactly its 107 px column.
sdec.ui_adv_small = 8
sdec.ui_adv_med   = 14
sdec.ui_lab_y = 14
sdec.ui_val_y = 32
-- x positions are sized from the measured width of each label and its widest plausible value,
-- leaving ~14 px clear before the next column. tools/render_png.py measures every value against
-- the next column's x and reports a collision.
sdec.ui_fields = {
  -- `med` marks the two headline cells, which keep FONT_MEDIUM; everything else is FONT_SMALL.
  -- The panel's column arithmetic is built on the measured 8 px FONT_SMALL advance
  -- (sdec.ui_ch_w) and FONT_MEDIUM measures ~13.4 px, so a medium cell is sized explicitly
  -- rather than inherited.
  --
  -- `wid` is the widest value the cell must hold, and each column is sized for THAT rather than
  -- for a typical one: BAUD holds six medium digits (115200, 250000) = 84 px, so its column
  -- runs 8..115. A collision that appears only when someone probes a fast line is the kind
  -- that ships.
  {lab = 'BAUD',   x = 8,   c = 0x00DCFF, med = true, wid = '115200'},
  {lab = 'FORMAT', x = 115, c = 0x00DCFF, med = true, wid = '8N1'},
  {lab = 'IDLE',   x = 188, c = 0xFFFFFF, wid = 'HIGH'},
  {lab = 'LOGIC',  x = 241, c = 0xFFFFFF, wid = '3V3 CMOS'},
  {lab = 'THRESH', x = 334, c = 0xFFFFFF, wid = '-6.00 V'},
  {lab = 'SA/BIT', x = 417, c = 0xFFFFFF, wid = '10.42'},
  {lab = 'RATE',   x = 490, c = 0xFFFFFF, wid = '80 kS/s'},
  -- BYTES must hold SIX digits: the streaming modes report 32768 and up, which is ~48 px at
  -- this font. FIT never shows more than '1.00', so the slack it does not need lives at the
  -- right-hand end, out to the table's right rule at 792.
  {lab = 'BYTES',  x = 573, c = 0x80FF80, wid = '999999'},
  {lab = 'ERR',    x = 636, c = 0x80FF80, wid = '999'},
  {lab = 'FIT',    x = 679, c = 0xB0B0B0, wid = '1.00'},
}

-- MEASURED CHARACTER ADVANCES. The font is proportional and UPPERCASE IS ~25 % WIDER THAN
-- EVERYTHING ELSE, so a label's width does not follow from its length:
--
--     hex digits and spaces   7.47 px/char
--     mixed-case ASCII        7.73 px/char   (the dump's ASCII gutter)
--     UPPERCASE               9.0 .. 9.67 px/char   (every label in this table)
--     FONT_MEDIUM digits      ~14 px/char
sdec.ui_adv_upper = 10       -- uppercase, measured 9.67 worst case
-- Button FACES use a larger font again: labels measured 12.7 to 15.5 px/char, and a face needs
-- len * ui_adv_btn + 8 px to render its label uncut. Calibration points: 'Save USB' is clipped
-- at a width of 112, 'Lock Detected' at 150, and 'Options' (7 chars) just fits at 112.
sdec.ui_adv_btn = 14
sdec.ui_adv_mixed = 8        -- digits and mixed-case, measured 7.80 worst case
sdec.ui_c_lab  = 0x707070                    -- the label row
-- ---------- lock state ----------
-- Which header fields are ASSERTED by the operator rather than measured. BAUD, FORMAT and IDLE
-- are the three the options form can force; everything else in the table is a measurement and
-- can never be locked.
--
-- WARNING: a forced value looks exactly like a measured one. Lock 9600, probe a 19200 line, and
-- the panel shows a confident '9600' that no other cell contradicts -- the easiest way for this
-- app to mislead. Hence the colour channel below.
sdec.ui_lockfields = {baud = 1, fmt = 2, idle = 3}
sdec.ui_c_locked  = 0x40FF40   -- green:  the operator pinned this
sdec.ui_c_auto    = 0xFFC000   -- amber:  the app worked it out
sdec.ui_c_unknown = 0xFF6060   -- red:    nothing to lock -- no decode
-- ERR is the other field whose colour carries meaning. Naming its index is what lets
-- ui_field_colour be the SINGLE writer of every value cell's colour.
--
-- ONE OBJECT, ONE OWNER, ONE CACHE. A second writer with its own shadow cache leaves two caches
-- disagreeing about what colour an object is, and the loser never repaints -- a red error count
-- painted in a non-error colour, with the error cache still saying red.
sdec.ui_errfield  = 9
-- Rules boxing the strip into a table. Thin OBJ_RECTs, created once and never
-- touched again, so they cost nothing per refresh. A fill of 0 would paint NOTHING
-- (the firmware reads it as "unset"), hence a near-black grey.
sdec.ui_c_rule = 0x484848
-- THE SCREEN BACKGROUND, for HIDING an object. It must not be 0: the firmware reads a fill of 0
-- as "unset" and paints NOTHING, so setfill(h, 0) is a refused write rather than a black
-- rectangle -- it climbs sdec.fillfails and leaves the object exactly as visible as it was.
sdec.ui_c_hide = 0x000A0D
sdec.ui_rule_top = 1
sdec.ui_rule_mid = 35                        -- under the value ink (medium 16..32)
sdec.ui_rule_bot = 51                        -- under the note row's ink (37..48)
sdec.ui_rule_x0  = 4
sdec.ui_rule_x1  = 792
-- The note is a labelled cell in the same table, spanning the full width under the
-- field row, rather than a loose line floating beneath it.
sdec.ui_note_lab_x = 8
-- The MODE cell is this row's left cell, and the row's vertical rule sits at
-- ui_note_val_x - 9 = 83, which the longest mode name clears by 12 px.
--
-- WARNING: the panel-edge check in tools/render_png.py catches only a string that overruns 798,
-- not one that overruns an INTERIOR rule -- so a cell bounded by its neighbour has to be
-- measured against that neighbour by hand.
sdec.ui_note_val_x = 92

sdec.ui_note_y   = 48
sdec.ui_row_y0   = 66                        -- first dump row
sdec.ui_row_dy   = 18                        -- row pitch (see docs/panel-ref-rows.png)
-- 15 rows x 16 bytes = 240 bytes, so a hex page holds an exact number of 16-byte rows.
--
-- A button cannot be made shorter to find vertical space for another row: display.create takes
-- (x, y, text, WIDTH) and there is no height parameter -- 58 px is the firmware's.
sdec.ui_nrow     = 15
sdec.ui_stat_y   = 342
-- THE STATUS ROW IS BOXED like the header table: it holds state about the capture rather than
-- the capture itself, and without a rule around it the two run together into one wall of small
-- grey text. The dump's last row inks up to 318 and the buttons start at 362, so the band
-- clears both.
sdec.ui_stat_top = 328   -- above the status ink (331..342)
sdec.ui_stat_bot = 346   -- below it
-- A divider before the right-hand cell, matching the note row's. ui_log_t starts 6 px after it.
sdec.ui_stat_div = 462
-- THE EXTERNAL TRIGGER GETS ITS OWN CELL, so that what the app is writing and what it is waiting
-- for are not two unrelated facts in one box. The log cell is 468..667, the trigger's 677..792.
sdec.ui_trig_div = 668
sdec.ui_trig_x   = 677
-- A BUTTON IS ~58 PX TALL (measured from docs/panel-ref-chrome.png). The content area is only
-- 480 - 49 = 431 px, so a button needs y + 58 <= 431, i.e. y <= 373.
--
-- WARNING: the coordinate limit is Y 0..420, so the firmware accepts a y past that ceiling
-- without complaint and simply clips the button off the bottom of the screen. tools/mock_display
-- RAISES on it instead, so an over-reach fails in tools/test_serial.lua rather than on a panel
-- that cannot be rebuilt without a power cycle.
sdec.ui_btn_y    = 362
sdec.ui_btn_h    = 58                        -- for layout arithmetic, not passed to the API
sdec.ui_x        = 8

-- ---------- dump column geometry ----------
-- ONE UNMEASURED NUMBER, AND EVERYTHING ELSE DERIVES FROM IT. ui_ch_w is the font's character
-- advance in the dump rows, and 8 is an ESTIMATE -- Menlo at 14 px, which is what
-- tools/render_png.py uses to approximate FONT_SMALL. The real face is not measured, so the
-- column positions below are computed rather than written out: if the true advance turns out to
-- be 9 or 11, this one line changes and the whole layout follows.
--
-- WRITING THE x POSITIONS AS LITERALS IS THE TRAP. At 8 px/char the hex block is 376 px wide; at
-- 11 it is 517, so a hardcoded ASCII column would sit 141 px INSIDE the hex it is meant to
-- follow -- overlapping text, not merely ugly.
sdec.ui_ch_w     = 8                         -- character advance, ESTIMATE
sdec.ui_col_gap  = 8                         -- clear space each side of a vertical rule
sdec.ui_ixn      = 4                         -- offset field, '%04d'
-- Hex block width, DERIVED rather than written. Changing the grouping has to move the ASCII
-- column and the vertical rule with it, and a literal here would not.
sdec.ui_hxn      = sdec.ua_hexwidth(8)      -- ONE group of 8 bytes: 8*3 - 1 = 23 chars
sdec.ui_col_gap2 = 12                       -- clear space BETWEEN the two hex groups
sdec.ui_asn      = 16                        -- ASCII block, one char per byte

sdec.ui_col_ix   = sdec.ui_x
sdec.ui_vr1_x    = sdec.ui_col_ix + sdec.ui_ixn * sdec.ui_ch_w + sdec.ui_col_gap
-- DOUBLE the standard gap after the offset column. The offset is metadata and painted dim;
-- pushing the data away from it makes the separation structural rather than only tonal.
sdec.ui_col_hx   = sdec.ui_vr1_x + 2 * sdec.ui_col_gap
-- The second group of eight, at a FIXED x one group plus a gap along. The proportional font makes
-- the first group's rendered width depend on which digits it holds, so a second group positioned
-- by string content would drift row to row.
sdec.ui_col_hx2  = sdec.ui_col_hx + sdec.ui_hxn * sdec.ui_ch_w + sdec.ui_col_gap2
sdec.ui_vr2_x    = sdec.ui_col_hx2 + sdec.ui_hxn * sdec.ui_ch_w + sdec.ui_col_gap
sdec.ui_col_as   = sdec.ui_vr2_x + sdec.ui_col_gap
sdec.ui_vr3_x    = sdec.ui_col_as + sdec.ui_asn * sdec.ui_ch_w + sdec.ui_col_gap
-- The vertical rules span the dump block: two px above the first row's text to the bottom of
-- the last row's.
sdec.ui_vr_y0    = sdec.ui_row_y0 - sdec.ui_ink
sdec.ui_vr_y1    = sdec.ui_row_y0 + (sdec.ui_nrow - 1) * sdec.ui_row_dy + 2

-- ---------- position bar ----------
-- A proportional INDICATOR, not a draggable scrollbar: gestures do not reach custom display
-- objects on this firmware, so there is nothing to drag. It shows how much capture there is and
-- where the current page sits.
--
-- A fixed ladder of segments recoloured in place, rather than one thumb moved with
-- display.setposition: setposition ERRORS on edit objects and is unverified on rectangles, and a
-- colour change cannot fail that way.
--
-- OFF BY DEFAULT. A FRAME capture is 240 bytes, which is one page, so the bar would permanently
-- read "all of it" while the status row says the same thing in words. It earns its place only on
-- a 32 kB streaming capture, which is 137 pages: turning it on is one assignment and costs 15
-- display objects, on a firmware where object count is what destabilises the panel.
if sdec.ui_sb_show == nil then sdec.ui_sb_show = false end
sdec.ui_sb_x   = 778
sdec.ui_sb_w   = 12
-- DERIVED, not a matching literal: segments sit on the dump's own grid
-- (ui_row_y0 + (i-1) * ui_row_dy), so a count that disagrees with ui_nrow leaves the bar
-- stopping ui_row_dy px short of the last row.
--
-- WARNING: nothing catches that. ui_bar() derives its lit range from page fractions rather than
-- from the row count, so a mismatch keeps working and the geometry check keeps passing -- the
-- only symptom is cosmetic misalignment.
sdec.ui_sb_n   = sdec.ui_nrow                -- segments, one per dump row -- BY CONSTRUCTION
sdec.ui_sb_h   = 17                          -- segment height, 3 px of gap at 20 px pitch

-- ---------- the capture modes ----------
-- The Mode button cycles this list. Capture does whatever the mode says, so there is one START
-- control and no rule about which of two start buttons wins.
--
-- THE BUTTON IS A STATIC `Mode`, as `View` is a static `View`, and the mode is shown elsewhere:
--
--   * the MODE CELL, top-left in the header table, in a PER-MODE COLOUR -- colour is read faster
--     than any word, which is what "recognisable at a glance" requires;
--   * the status row, which names it in words.
--
-- Both are existing text objects, retexted and recoloured on refresh, so the at-a-glance
-- indicator costs no new object. display.settext on a BUTTON is unverified on this firmware, so
-- a self-relabelling button is not an option in any case.
--
-- FRAME ALWAYS APPENDS TO THE LOG rather than offering a separate 'frame + log' mode: the USB key
-- is always in this instrument, ulog/frame_log degrade to a no-op when it is absent rather than
-- failing, and a few hundred ms of file write is invisible against a button press. The status row
-- shows the count and filename so the append is visibly happening rather than promised.
--
--   cap        byte ceiling, or nil for "as much as the buffer holds"
--   log        append the decode to a file on the USB key
--   view       the panel shows bytes (frame mode) or progress (streaming modes)
--   needbaud   refuses unless the baud rate is locked -- see sdec.mode_why()
--   idlexit    a quiet line ends the run AND leaves the mode -- see sdec.mode_exit()
--   c          the MODE cell's colour, which is the at-a-glance channel
sdec.ui_modes = {
  {id = 'frame', name = 'FRAME',  cap = nil,   log = true, view = true,
   c = 0xB0B0B0, desc = 'capture, show, and append to the message log'},
  -- TWO RECORDING SIZES, AND SIZE IS THE ONLY DIFFERENCE. Here rather than on the options form
  -- because the form has no room for an eighth field (ui_opt_y0) and because the MODE CELL ALREADY
  -- DISPLAYS IT -- so the indicator is free and the control is one press.
  --
  -- THE WINDOW IS THE UNIT OF EVERYTHING: one press records a window, decodes it, files it, and under
  -- flow control credits the device for the next. So a smaller window reaches bytes sooner, loses less
  -- to a cancel, and credits sooner; a larger one spends less on seams and needs fewer credits. Both
  -- are lossless. At the measured ~250-360 byte/s, 8 kB is ~30 s of decoding and 32 kB about two
  -- minutes -- which is the responsiveness this choice is really about.
  {id = 'sml',   name = '8 kB',   cap = 8192,  log = true, view = false,
   needbaud = true, idlexit = true, c = 0x40C0FF,
   desc = 'shorter capture window -- quicker to bytes, more credits'},
  {id = 'med',   name = '32 kB',  cap = 32768, log = true, view = false,
   needbaud = true, idlexit = true, c = 0xFFC000,
   desc = 'long capture, decoded to a file'},
  -- THERE IS NO UNCAPPED MODE and that is deliberate: every recording is a window with a ceiling,
  -- because a run longer than one window is what flow control is for (Options > Rear BNC = FC Out),
  -- and that makes the device wait for the capture instead of outrunning it.
  n = 3,
}
sdec.capmode = sdec.capmode or 'frame'    -- operator state, hence `or`

-- HOW LONG A QUIET LINE ENDS A STREAM. A recording watches the line while it acquires and stops
-- when nothing has crossed the threshold for this long; without it a 1200 baud run waits nine
-- minutes for the buffer to fill after the device has stopped talking.
--
-- 1 SECOND, from bench experience. A quiet line is the ONLY way a stream ends early, so every
-- second of this is a second the panel spends looking hung after the device went silent -- which
-- is what an operator notices. One second is still ~40 frame times at the slowest rate this mode
-- allows, so it cannot fire inside a message.
--
-- Settable from the host over the socket (`sdec.idle_exit_s = 30`) but not from the panel: the
-- options form has no room for an eighth field (see the arithmetic at ui_opt_y0). A device with
-- second-scale gaps between messages wants a longer value, and that is what the override is for.
sdec.idle_exit_s = sdec.idle_exit_s or 1

-- HOW LONG ANY ONE PIECE OF WORK MAY HOLD THE PANEL. The press-latency budget.
--
-- IT IS A BUDGET, NOT A POLL INTERVAL, because there is NO WAY for running Lua to observe a
-- front-panel press. Not display.setevent (the firmware calls the handler, and it cannot while
-- the interpreter is busy -- presses QUEUE), not display.waitevent (WARNING: it ignores a zero
-- timeout and blocks indefinitely, wedging the instrument until an ABORT over the LAN recovers
-- it), and not delay(). The only thing that lets a press through is the handler RETURNING.
--
-- So responsiveness is not something the app can poll for; it is a property of how long each
-- handler runs. Every long job is cut into pieces no bigger than this, and the panel is
-- repainted and the handler returned between them.
--
-- 500 ms. The slowdown from chunking is repaint_cost / budget, so the budget must be ~10x a
-- repaint to stay under 10 % overhead. Decode throughput is ~881 byte/s (20 000 samples = 0.236 s,
-- 0.115 s of edge detection plus 0.120 s of framing, yielding 208 bytes at 8 samples/bit), so
-- 500 ms is about 440 bytes of work -- comfortably more than the 240-byte page and the 256-byte
-- chunk, and comfortably less than a human's threshold for "did that button do anything?".
--
-- CAREFUL WITH THAT 881, and do not budget anything else against it: it is the COST OF DECODING
-- SAMPLES ALREADY IN LUA and excludes reading them out of the capture buffer, which is the larger
-- half at 21.7 us a sample. End to end the figure is ~358 byte/s, and ~250 byte/s at the streaming
-- modes' 4.17 samples/bit. Anything sized against 881 is 2.5-3.5x optimistic. ck_win_us = 48 us a
-- sample is the number that includes the read, and it is what the slice budget uses.
sdec.ui_latency_s = sdec.ui_latency_s or 0.5

-- HOW MUCH WORK ONE PRESS OF A STEPPED DECODE DOES, which is a different question from how wide a
-- decode window should be: ui_latency_s above sizes the WINDOW, because every priming phase scales
-- with it. This is deliberately much larger than the repaint budget, because a press that RETURNS
-- is a press that has been answered and waiting once beats pressing hundreds of times.
--
-- 8 s gives 27 windows a press -- a full 2 800 000-reading buffer in 17 presses, a 30 s recording
-- at 4800 Bd in 4 -- and stays inside the 12 s bound bench_panel.py holds capture presses to, with
-- room for the final window to run past the check that admitted it.
--
-- The panel does NOT repaint during those 8 s, and a press inside them is queued, not lost. FRAME
-- mode makes the same deal for up to 9 s. Lower this for a more interactive run; raise it to press
-- less often.
sdec.ck_press_budget_s = sdec.ck_press_budget_s or 8.0

-- The mode in force, never nil -- an unrecognised id falls back to frame rather than
-- leaving every caller to guard.
function sdec.mode_cur()
  local i
  for i = 1, sdec.ui_modes.n do
    if sdec.ui_modes[i].id == sdec.capmode then return sdec.ui_modes[i] end
  end
  return sdec.ui_modes[1]
end

-- ---------- the continuous ceiling ----------
-- A MEASURED NUMBER WEARING A CONSTANT'S CLOTHES, and NOTHING READS IT AT RUNTIME. It survives
-- because the harnesses print it and because the derivation is worth not repeating.
--
-- A ping-pong (acquire into one buffer while Lua decodes the other) only keeps up while
-- decoding a buffer finishes before the other fills:
--
--     nsmp * Tread  <  nsmp / fs     =>     fs < 1 / Tread
--
-- and fs must still clear baud * minsabit, so continuous is possible only while
-- baud < 1 / (Tread * minsabit). Continuous means the decoder keeps up with the wire, so the
-- per-sample cost bounds the sample rate:
--
--   Tread = 21.73 us      buffer -> Lua copy, measured
--   + ~5.6 us             the conditioning passes over the copied window (measured end to end)
--   = ~27.3 us/sample     so continuous needs fs < 1/27.3us = 36.6 kS/s
--
-- THAT 27.3 IS READ PLUS EDGE DETECTION AND OMITS ua_run, the pass that frames bytes. The
-- applicable per-sample figure is ck_win_us = 48 us, which makes the inequality baud < 5208 -- so
-- 4800 clears it by luck of the rate ladder, at 95 % duty.
--
-- fs_for_burst() picks the lowest listed rate DELIVERING minsabit samples/bit, so 4800 baud
-- takes 20 kS/s (duty 0.55, keeps up) and 9600 takes 40 kS/s (duty 1.09, does not). 4800 is
-- therefore the highest standard rate that is genuinely continuous.
--
-- WARNING: do not raise this on the strength of Tread alone, which would allow 9600. The
-- conditioning passes are real work on the same samples, and a ceiling that ignores them is not
-- a ceiling -- it makes the panel state a rate the instrument cannot deliver, on a mode whose
-- whole promise is that no byte is lost.
sdec.strm_maxbaud = 4800

-- Whether mode `m` suits the current rate. Always true: there is one recording mode and it suits
-- every rate it can run at. A rate too fast to stream is refused by mode_why(), which carries a
-- reason to the panel; this exists because the panel and the harnesses call it.
function sdec.mode_suits(m)
  return true
end

-- The recording mode id for the locked rate, or nil when no rate is locked.
function sdec.mode_for_rate()
  local b = sdec.force_baud
  if b == nil or b <= 0 then return nil end
  return 'med'
end

-- Why mode `m` cannot run right now, as a sentence for the note line, or nil if it can. `m`
-- defaults to the current mode. Called when Capture is pressed rather than when the mode is
-- selected, so a mode can be lined up before the rate is known.
function sdec.mode_why(m)
  if m == nil then m = sdec.mode_cur() end
  -- Streaming is GATED ON A LOCKED BAUD RATE: the lock is what lets the sample rate be chosen
  -- ahead of the capture, which is what makes a long window mean anything.
  if m.needbaud and (sdec.force_baud == nil or sdec.force_baud <= 0) then
    -- KEPT SHORT ON PURPOSE: with the 'WARNING: ' prefix this has to fit the note cell's
    -- ui_note_px = 700. The font metrics are approximated, so a sentence measuring a few pixels
    -- inside the limit has no real margin.
    return 'lock the baud rate in Options -- streaming picks the sample rate from it'
  end
  -- NO RATE CAN DELIVER THE FLOOR AT THIS BAUD. Measured on hardware: a SimpleLoop capture runs
  -- 0.510 us/sample slower than requested, so the rate that would have given minsabit samples per
  -- bit in theory gives less in fact, and above ~115 kBd no listed rate closes the gap. Refused
  -- with the number rather than run at 2.6 samples/bit while claiming 4 -- see fs_for_burst().
  if m.needbaud and sdec.force_baud ~= nil and sdec.force_baud > 0 and
     sdec.fs_for_burst ~= nil and sdec.fs_for_burst(sdec.force_baud) == nil then
    return string.format('%d Bd is too fast to stream -- no sample rate delivers %d ' ..
                         'samples/bit; use FRAME', sdec.force_baud, sdec.minsabit)
  end
  return nil
end

-- THREE STATES, and the padlock's colour is the whole point of having them:
--   'locked'   green  -- at least one wire parameter is forced
--   'auto'     amber  -- nothing forced, and there IS a decode, so there is something to lock
--   'unknown'  red    -- nothing forced and nothing decoded: nothing to lock yet
function sdec.lock_state()
  if sdec.force_baud ~= nil and sdec.force_baud > 0 then return 'locked' end
  if sdec.force_nbits ~= nil or sdec.force_par ~= nil or
     sdec.force_nstop ~= nil or sdec.force_invert ~= nil then return 'locked' end
  if sdec.baud == nil or sdec.res == nil then return 'unknown' end
  return 'auto'
end

-- Padlock colour for the current lock state.
function sdec.lock_colour()
  local st = sdec.lock_state()
  if st == 'locked' then return sdec.ui_c_locked end
  if st == 'auto' then return sdec.ui_c_auto end
  return sdec.ui_c_unknown
end

-- ---------- the views ----------
-- The View button cycles this list, and every per-view decision reads it: page size, item count,
-- unit name, row text, row colour.
--
-- `cols` is items per row, stated ONLY here: one character per byte for text, 16 bytes for hex,
-- one parsed message or frame for a protocol view. An entry with `res` IS a protocol layer -- its
-- module parses the byte stream into sdec[res] = {n, msg[], kind[]}, and kind[i] == 'err' colours
-- the row.
--
-- Function names are STRINGS, looked up in sdec when called, not references. Each protocol layer
-- is a separate module, so a build without one degrades to an empty list instead of failing to
-- load, and the host harnesses load the modules in a different order from the app.
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

-- Whether view `v` is available in this build: a protocol view needs its module loaded. Version 1
-- ships without midi_decode.tsp and lin_decode.tsp, and the entries stay in ui_views so that
-- restoring either is one line in tools/package_tspa.py MODULES and nothing else.
function sdec.ui_view_avail(v)
  if v == nil then return false end
  if v.res == nil then return true end          -- text and hex need no module
  -- CHECKED LAZILY, not by pruning ui_views at load time: the app loads serial_ui AFTER the
  -- protocol modules but the offline harnesses load them in the other order, so a load-time prune
  -- would drop MIDI from a full build depending only on who loaded what first.
  return v.parse ~= nil and sdec[v.parse] ~= nil
end

-- How many views this build offers. view_toggle() cycles over these rather than over the raw
-- table, so an absent module means the button never lands on a view that can only be empty.
function sdec.ui_nviews()
  local n, i = 0, nil
  for i = 1, table.getn(sdec.ui_views) do
    if sdec.ui_view_avail(sdec.ui_views[i]) then n = n + 1 end
  end
  return n
end

-- The nth byte view this build actually offers.
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

-- The ui_views entry for `mode`, defaulting to sdec.ui_mode, or nil if it is absent or
-- unavailable in this build. Callers that must have an entry use sdec.ui_cur().
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

-- The view in force, never nil: an unrecognised sdec.ui_mode falls back to text rather
-- than leaving every caller to guard against it.
function sdec.ui_cur()
  return sdec.ui_view() or sdec.ui_views[1]
end

-- ---------- colours ----------
sdec.ui_c_head = 0x00DCFF    -- cyan: the headline wire parameters
sdec.ui_c_dim  = 0xB0B0B0    -- grey: secondary detail
-- The dump's offset column. Dimmer than ui_c_dim because it is the least important thing on the
-- row: it is metadata the eye uses to navigate, not data being read, and at full brightness a
-- column of numbers competes with the bytes beside it.
sdec.ui_c_off  = 0x808080
sdec.ui_c_warn = 0xFFC000    -- amber: ambiguity and warnings
sdec.ui_c_data = 0xFFFFFF    -- white: the decoded bytes
sdec.ui_c_err  = 0xFF6060    -- red: a row containing a framing or parity error
-- OBJ_RECT treats a fill of 0 as "unset" and paints NOTHING, so a dark trough has
-- to be a near-black value rather than true black.
sdec.ui_c_sb_off = 0x282828  -- position bar, outside the current page
sdec.ui_c_sb_on  = 0x00DCFF  -- position bar, current page

-- ---------- handles ----------
-- Declared, not assigned: see the note in serial_core.tsp. Opening the installed
-- App re-runs this file, and nil-ing a live handle here strands its object.
-- sdec.ui_scr
-- sdec.ui_flab     -- static field labels
-- sdec.ui_fval     -- field values
-- sdec.ui_rule     -- table rules around the field strip
-- sdec.ui_note
-- sdec.ui_row      -- ui_nrow dump rows
-- sdec.ui_page_t
-- sdec.ui_log_t
-- sdec.ui_btn      -- button handles, kept only so teardown can see them
-- sdec.ui_sb       -- position-bar segments
-- sdec.ui_sbc      -- last colour written per segment

-- ---------- view state ----------
sdec.ui_mode = sdec.ui_mode or 'text'    -- 'text', 'hex' or 'midi'
sdec.ui_page = sdec.ui_page or 0          -- 0-based page index
sdec.ui_status = sdec.ui_status or 'ready'
-- sdec.ui_last   -- last text written per handle, to skip redundant settext

-- ---------- options form handles ----------
-- sdec.optscr, sdec.opt_proto, sdec.opt_baud, sdec.opt_bits, sdec.opt_par,
-- sdec.opt_pol, sdec.opt_trig, sdec.opt_ext -- declared, not assigned
--
-- SEVEN FIELDS, AND THIS IS THE RISKIEST GEOMETRY IN THE APP.
--
-- ui_opt_dy is the pitch between edit objects, and the real HEIGHT of an edit object on this
-- firmware is NOT MEASURED. 72 px is the only pitch confirmed working, at 3 fields.
-- Seven fields fit only at y0 = 8 and dy = 52, which puts the last field's bottom at 358 against
-- a button row at 366:
--
--     fields  y0  dy   last bottom   buttons at 366
--        6    26  58       354          fits
--        7    26  58       412          COLLIDES
--        7    26  52       376          COLLIDES
--        7     8  52       358          fits, 8 px clear
--
-- WARNING: the edit-object height is a guess. If the true height is over 52 px the fields overlap
-- and the form is unusable; one screenshot settles it. The remedy is to fold a field's control
-- into another field as an extra option entry, which costs no vertical space at all -- the
-- firmware allows ten options per field.
sdec.ui_opt_y0 = 8
sdec.ui_opt_dy = 52
sdec.ui_opt_x  = 270   -- >= 270 so edit labels stay on screen
sdec.ui_opt_nf = 7     -- fields, for the layout arithmetic above
-- HOW WIDE AN OPTION-FIELD ENTRY MAY BE, in px. Past this the firmware FADES the tail out
-- rather than clipping, so an over-long entry is unreadable AND can be mistaken for a shorter
-- entry in the same field ('Trig In+FC Out' draws as 'Trig In+FC', beside a real 'Trig In').
--
-- A CHARACTER COUNT CANNOT DECIDE THIS: 'In + FC Out' fits at 11 characters while 'TRIGGER key'
-- fades at 11, because seven of its letters are uppercase. Entries are weighed with the same two
-- advances the header cells use -- 10 px uppercase, 8 px otherwise -- against a bound measured
-- between the two: 'In + FC Out' at 96 px renders whole and 'TRIGGER key' at 102 px does not.
sdec.ui_opt_px = 96

-- WIDTH AVAILABLE TO THE LOG CELL, DERIVED rather than written down. It is the gap between the two
-- dividers, less the 6 px inset the text object is created at -- 200 px today. A literal here went
-- stale once already: a comment claimed "221 px, from 430..651" long after ui_stat_div had moved to
-- 462, so the margin it asserted had not existed for some time. Deriving it means moving a divider
-- moves the fit budget with it.
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
-- settext `txt` on `h`, but only when the text actually changed. Returns true if it wrote.
function sdec.ui_set(h, txt)
  if h == nil then return false end
  if sdec.ui_last == nil then sdec.ui_last = {} end
  -- Not a micro-optimisation: display calls are asynchronous messages to the second PowerPC and
  -- the queue is bounded and overrunnable -- "1706 Message dropped from display queue" precedes
  -- the firmware panics. Rewriting unchanged rows is pure queue pressure.
  if sdec.ui_last[h] == txt then return false end
  local ok = pcall(function() display.settext(h, txt) end)
  if ok then sdec.ui_last[h] = txt end
  return ok
end

-- Set an object's colour, tolerating a handle the build never created.
function sdec.ui_color(h, c)
  if h == nil then return false end
  -- Guarded: setcolor is known to fail on Image objects (error 1717) and has not
  -- been confirmed on text. If it does not apply, rows stay white and the summary's
  -- error counts still report the damage.
  return pcall(function() display.setcolor(h, c) end)
end

-- Delete object `h`, counting a refusal rather than assuming it worked. Returns whether it went.
function sdec.del_obj(h)
  if h == nil then return true end
  local ok = pcall(function() display.delete(h) end)
  if not ok then
    -- KEEP A HANDLE THAT WOULD NOT DELETE. Every teardown nils its variables afterwards, so
    -- dropping a refused handle loses the ONLY reference to a live firmware object -- stranded
    -- until a power cycle, and unreclaimable even by retrying. That accumulation is what raises
    -- event 1701, "the maximum number of objects have already been created". Refused handles go
    -- on sdec.orphans, and del_orphans() retries them before any rebuild.
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
    local ok = pcall(function() display.delete(o[i]) end)
    if not ok then nk = nk + 1; keep[nk] = o[i] end
  end
  if nk < 1 then sdec.orphans = nil else sdec.orphans = keep end
  return nk
end

-- Recolour rect `h` to `c`, counting a refusal in sdec.fillfails, which the status row surfaces.
--
-- COLOUR A RECT WITH setcolor, NOT setfill, and the difference is not a detail:
--
--   display.setfill(id, percent, direction)   percent is 0..100 -- HOW MUCH is painted
--   display.setcolor(id, foreground, second)  WHAT COLOUR it is painted
--
-- Passing a 24-bit colour to setfill is refused with "1130 Parameter fill percent, expected value
-- from 0 to 100", and enough refusals per refresh make the instrument raise a MODAL ERROR DIALOG
-- over the app's own panel -- which covers the hex dump and has to be dismissed by hand.
--
-- FILL PERCENT MUST ALSO BE SET. display.create(..., OBJ_RECT, x, y, w, h) defaults the fill
-- percent to 0, so a rect is invisible whatever colour it is. Every rect here is solid, so 100 is
-- set once at creation (see ui_fill_solid) and this function only ever changes the colour.
--
-- display.setfill is UNVERIFIED ON HARDWARE and carries the header table rules as well as the
-- position bar, so a silent refusal would make both invisible -- indistinguishable from a layout
-- mistake. The counter is the difference between "the rules are not drawn" and "the rules were
-- refused 19 times".
function sdec.ui_fill(h, c)
  if h == nil then return false end
  local ok = pcall(function() display.setcolor(h, c) end)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Make a rect actually paint: 100 % foreground. Called once per rect at build time; the
-- position bar is the one object that varies its fill afterwards, and it calls setfill itself.
function sdec.ui_fill_solid(h)
  if h == nil then return false end
  local ok = pcall(function() display.setfill(h, 100) end)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Items per page, and per row, for the current view. A protocol view is one PARSED
-- MESSAGE OR FRAME per row rather than a run of bytes, so its column count is 1.
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

-- The colour header value `j` is drawn in. The three lockable fields carry the lock state as a
-- second channel, so the distinction survives even if setfill on a rect turns out not to work;
-- everything else keeps its own column colour.
function sdec.ui_field_colour(j)
  local fd = sdec.ui_fields[j]
  if j == sdec.ui_lockfields.baud or j == sdec.ui_lockfields.fmt or
     j == sdec.ui_lockfields.idle then
    local st = sdec.lock_state()
    if st == 'locked' then return sdec.ui_c_locked end
    if st == 'unknown' then return fd.c end   -- the value is '--' already; red would shout
    return fd.c                               -- auto: the column's own colour, unchanged
  end
  -- Errors go red when there are any, so the one number that matters is not another grey figure
  -- in a row of grey figures. fd.c, not a literal green: the "all clear" colour IS this column's
  -- colour, and writing it in two places lets the two drift.
  if j == sdec.ui_errfield then
    -- Interior errors only, for the same reason as the value beside it.
    if sdec.res ~= nil then
      local nin = sdec.ua_bad_interior and sdec.ua_bad_interior(sdec.res)
                  or sdec.res.nbad
      if nin > 0 then return sdec.ui_c_err end
    end
    return fd.c
  end
  return fd.c
end

-- The ten header values, in sdec.ui_fields order. Kept short: each has its own column, so a value
-- that outgrows it collides with the next rather than wrapping.
function sdec.ui_field_values()
  local r = sdec.res
  local v = {}

  -- BAUD, FORMAT and IDLE fall back to the FORCED values when nothing has been decoded.
  --
  -- The streaming modes hand back a file rather than an sdec.res, so without this these three
  -- read '--' for the whole run -- and a streaming mode cannot be entered without a locked rate,
  -- which makes them the three cells that are certain. The measured cells (LOGIC, THRESH, SA/BIT,
  -- FIT) do stay '--', because nothing has been fitted.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    v[1] = string.format('%d', sdec.force_baud)
  elseif sdec.baud == nil then v[1] = '--'
  elseif sdec.snapped then v[1] = string.format('%d', sdec.baud)
  else v[1] = string.format('%.0f?', sdec.baud) end

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
    v[5] = string.format('%.2f V', sdec.thr)
  end

  if sdec.bittime == nil then v[6] = '--'
  else v[6] = string.format('%.1f', sdec.bittime) end

  local fs = sdec.acq_fs or sdec.fs
  if fs == nil then v[7] = '--'
  elseif fs >= 1000000 then v[7] = string.format('%.0f MS/s', fs / 1000000)
  else v[7] = string.format('%.0f kS/s', fs / 1000) end

  -- BYTES and ERR come from the STREAM in the streaming modes, not from sdec.res. sdec.res holds
  -- only the primed lead-in window there -- a couple of hundred bytes -- so reporting it would put
  -- a quietly plausible number on the panel: 230 looks like a capture rather than like 1 % of one.
  --
  -- GATED ON ck_tot, NOT ON THE CURRENT MODE. A quiet line ends a stream through mode_exit(),
  -- which lands in FRAME, so keying this on mode_cur() makes the next refresh describe the mode
  -- the app has just moved TO -- BYTES falling back to the lead-in window and reporting ~158 for a
  -- 400-byte file, a plausible count and a strict subset of the file that nothing else on screen
  -- contradicts. A result outlives the mode that produced it, and ck_tot says which one it
  -- belongs to.
  local ct = sdec.ck_tot
  if (ct ~= nil or sdec.ck_running) then
    if sdec.ck_running then
      -- DASHES, NOT ZERO, during the recording phase. Nothing has been decoded yet, and a
      -- green '0' in the BYTES column reads as a measurement -- "it found nothing" -- when the
      -- truth is "it has not looked yet". Same reason every other field shows '--' before a
      -- capture: the panel must never present an unknown as a result.
      if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then v[8] = '--'
      else v[8] = tostring(sdec.ck_nbytes) end
      v[9] = '--'                     -- not known until the run finishes
    else
      v[8] = tostring(ct.nf)
      v[9] = tostring(ct.nbad)
    end
  elseif r == nil then v[8], v[9] = '--', '--'
  else
    v[8] = tostring(r.nf)
    -- INTERIOR framing errors. A frame sliced by the capture boundary, or one lost while the
    -- framer resynchronised at the head of a gapless stream, is a windowing artefact -- see
    -- sdec.ua_bad_interior. Counting those made ERR read 1 or 2 on every healthy capture, which
    -- is an error indicator that is never zero, and a red first row on a perfect signal.
    local nin = sdec.ua_bad_interior and sdec.ua_bad_interior(r) or r.nbad
    v[9] = tostring(nin)
  end

  v[10] = string.format('%.2f', sdec.fitq or 0)
  return v
end

-- ============================================================================
-- The note / warning line
-- ============================================================================
-- Every note that applies, most important first. Returns the list and its count.
--
-- A LIST, NOT A FALL-THROUGH CHAIN. Seventeen sources feed one cell, and a chain shows only one of
-- them -- so a second real warning would not merely be hidden, nothing would say it existed. The
-- cell shows one note because one is what fits, but it says HOW MANY MORE there are, and ulog and
-- the saved file get all of them. Ordered by how badly an absence would mislead.
function sdec.ui_notes()
  local t, m = {}, 0
  local function add(s)
    if s ~= nil and s ~= '' then m = m + 1; t[m] = s end
  end

  if sdec.lasterr ~= nil then add('NOTE: ' .. tostring(sdec.lasterr)) end
  if sdec.savedas ~= nil then add('saved to ' .. tostring(sdec.savedas)) end
  if sdec.stickyerr ~= nil then add('NOTE: ' .. tostring(sdec.stickyerr)) end

  -- A SETTING THAT LOOKS APPLIED AND IS NOT: acq_triggered() skips blending under Free run,
  -- because 'free' means do not wait -- so the checkbox stays ticked while the external trigger
  -- does nothing. Same class as the 'parity was ASSUMED none' note below.
  if sdec.trigext and sdec.trigmode == 'free' then
    add('external trigger is ticked but IGNORED -- Free run means do not wait for anything')
  end

  -- SAY WHAT BOUNDS THE RECORDING, in the units the operator is deciding in: the byte ceiling,
  -- and how long that works out to at this rate.
  --
  -- NOT "bytes are lost". The press-driven path arms ONE hardware acquisition and decodes it
  -- afterwards, so there are no windows to lose anything between. Measured at 9600 baud -- double
  -- strm_maxbaud -- a recording comes back 1925 of 1925 bytes contiguous against a non-repeating
  -- payload, byte rate matching the wire to 0.5 %. Warning about loss here would send the operator
  -- to wire up flow control they do not need, and cast doubt on a complete capture.
  local md2 = sdec.mode_cur()
  if md2.needbaud and sdec.force_baud ~= nil and sdec.force_baud > 0 then
    local bps = sdec.force_baud / 10          -- 10 bit times a byte, near enough for a note
    if md2.cap ~= nil then
      -- AND THAT NOTHING CAN CUT IT SHORT, which is the other half of what an operator needs BEFORE
      -- pressing: neither a button nor the TRIGGER key can (measured 2026-08-18 -- see the control
      -- cell in ui_refresh), and the decode costs more than the acquisition, so the hold outlasts the
      -- figure here. 'EARLY' is the precise word: 'bounded' already says it ends by itself.
      --
      -- KEPT SHORT BECAUSE THE NOTE TRIMMER IS REAL. A fuller sentence -- '...and nothing on the panel
      -- can stop it once started' -- rendered as '...once st...', so the warning was the part that got
      -- cut. ~74 characters is the budget once '(+N more)' takes its share.
      add(string.format('bounded at %d bytes -- ~%.0f s of this line, and nothing stops it early',
                        md2.cap, md2.cap / bps))
    else
      -- Unlimited by design, but the capture buffer is finite, so say how long that is.
      local nsmp = sdec.ck_bufmax or 2800000
      local fs = nil
      pcall(function() fs = sdec.fs_for_burst(sdec.force_baud) end)
      if fs ~= nil and fs > 0 then
        add(string.format('records until Capture stops it, or %.0f s when the buffer fills',
                          nsmp / fs))
      else
        add('records until Capture stops it, or until the capture buffer fills')
      end
    end
  end

  -- A mode that changed ITSELF has to say so. Both of these are consequences of a button press
  -- whose effect is otherwise invisible: mode_exit() moves the MODE cell back to a grey FRAME, and
  -- log_new() changes a filename that only appears on the NEXT capture. Ranked above the wire
  -- warnings because they answer "what did that press just do?".
  if sdec.mode_exited ~= nil then add(tostring(sdec.mode_exited)) end
  if sdec.lognote ~= nil then add(tostring(sdec.lognote)) end
  -- A RECORDING THAT CHANGED ITS OWN MEASUREMENT BASIS MID-RUN SAYS SO. strm_relevel() only fires when
  -- the watchdog was about to end a run on levels REUSED from an earlier capture and this capture's own
  -- samples disagree -- so the threshold the second half was judged against is not the one the first
  -- half was. That is the same class as the two above: a consequence of the app's own decision, with no
  -- other trace on the panel. Ranked with them, above the wire warnings.
  if sdec.strm_releveled ~= nil then add(tostring(sdec.strm_releveled)) end

  -- A streaming mode that cannot run says so BEFORE Capture is pressed, and here rather than in
  -- the status row: the remedy is a sentence, the status row shares its line with the log status,
  -- and the note cell spans the full table width. The full sentence in the status row measures
  -- 802 px against a 798 px panel.
  local md = sdec.mode_cur()
  if not md.view then
    local mw = sdec.mode_why(md)
    if mw ~= nil then add('WARNING: ' .. mw) end
  end

  -- THE DUMP AREA SHOWS ONE WINDOW, THE FILE HOLDS THE STREAM, and the two numbers on
  -- screen disagree by two orders of magnitude -- BYTES says 32768 while the panel shows
  -- ~192. Without this line that reads as a bug. It is the same problem the frame-mode
  -- capture-FULL note solves: a partial view is honest only if it says it is partial.
  if sdec.ck_tot ~= nil and sdec.res ~= nil and sdec.ck_tot.nf > sdec.res.nf then
    local base = string.gsub(tostring(sdec.ck_tot.path or 'the USB file'), '^.*/', '')
    -- WHICH BYTES, NOT JUST HOW MANY. A finished recording leaves its retained TAIL on screen, so
    -- 'the first 8192' named the wrong end of the stream while the index column read 24576 -- the
    -- panel contradicting itself. res.first is the 1-based absolute index ck_tail_result() records
    -- for exactly this, and capture() says so where it assigns the tail.
    local first, tot = sdec.res.first, sdec.res.ntotal or sdec.ck_tot.nf
    if first ~= nil and first > 1 then
      add(string.format('panel shows bytes %d-%d of %d; all are in %s',
                        first, first + sdec.res.nf - 1, tot, base))
    else
      add(string.format('panel shows the first %d bytes of the stream; all %d are in %s',
                        sdec.res.nf, tot, base))
    end
  end

  -- Only warn about samples/bit once there IS a bit time; before the first capture
  -- sig_quality() reports 'no bit time', which reads as a fault rather than as
  -- "nothing captured yet".
  if sdec.bittime ~= nil then
    local _, warn = sdec.sig_quality()
    if warn ~= nil then add('WARNING: ' .. warn) end
  end

  -- An unstable baseline is decoded rather than refused, so it has to be SAID: the bytes may be
  -- right, and the reason the next capture might not be is the wire.
  --
  -- AUTO-LOCK MUST ANNOUNCE ITSELF -- it stops the app auto-detecting, which changes what the next
  -- capture DOES, and a padlock that quietly turns green is the same defect as a mode that changes
  -- colour without saying why.
  --
  -- IT RANKS BELOW THE SIGNAL-QUALITY WARNINGS. Above them it displaces "the baseline is unstable"
  -- on a capture that has both, and a warning that the measurement may be untrustworthy matters
  -- more than a note about the next one being faster -- the more so because a shaky baseline is
  -- exactly when a confident-looking lock is least deserved.
  local lw = sdec.sig_levelwarn()
  if lw ~= nil then add('WARNING: ' .. lw) end

  if sdec.autolocknote ~= nil then add(sdec.autolocknote) end
  -- Why the capture took two passes at the bottom of the rate range. Worth a line because the
  -- press is then twice as long as usual and nothing else would say why.
  if sdec.probe_note ~= nil then add(sdec.probe_note) end

  -- LIN's own level check: a 12 V bus probed without the 2:1 divider decodes nothing,
  -- and nothing about that says "you need a divider". High in the list because it is the
  -- difference between a five-minute fix and an afternoon.
  if sdec.proto == 'lin' and sdec.li_levelnote ~= nil then
    local ln = sdec.li_levelnote()
    if ln ~= nil then add('WARNING: ' .. ln) end
  end

  -- Every LIN break costs one framing error at the UART layer, so a perfectly healthy
  -- LIN capture lights the ERR field red. Without this line that reads as a bad wire.
  if sdec.proto == 'lin' and sdec.li_breaknote ~= nil then
    add(sdec.li_breaknote())
  end

  -- A CAPTURE THAT BEGAN MID-BYTE. On a continuously busy line the trigger fires wherever it
  -- fires, and the first edge carries no evidence of how long the line was at mark before the
  -- capture started -- so the framer can anchor inside a byte and stay wrong until the first
  -- idle. ua_run marks the region when the errors are confined to it. Worth saying because the
  -- bytes are THERE, on screen, looking like data; most are flagged but a frame can pass its
  -- stop bit and parity by chance.
  if sdec.res ~= nil and sdec.res.headsusp ~= nil and sdec.res.headsusp > 0 then
    add(string.format('capture began mid-byte -- the first %d byte(s) are misaligned; '
                      .. 'everything from the first gap on is sound', sdec.res.headsusp))
  end

  -- Impulse noise on a data bit flips it undetectably: the start and stop bits are
  -- still in place, so the frame passes. "0 err" would then be read as "no
  -- corruption", so say otherwise when the capture shows impulse noise.
  if sdec.res ~= nil and sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('%d false start(s) rejected -- impulse noise; "err" counts framing only',
                      sdec.res.nfalse))
  end

  -- A PROTOCOL LAYER THAT FAILED, said where an empty message list would otherwise speak for it. Ranked
  -- above the rate note because it is about the view the operator is looking at right now.
  if sdec.proto_why ~= nil then add('WARNING: ' .. tostring(sdec.proto_why)) end

  -- THE RATE ON SCREEN WAS NOT MEASURED. acq_fs is normally re-derived from the buffer's timestamps,
  -- because the sample-rate readback lies for any rate the hardware cannot synthesise -- and every bit
  -- time, the baud rate and therefore every byte is scaled by it. When the timestamps cannot be read the
  -- REQUESTED rate is substituted so the capture still works, and that substitution has to be visible:
  -- otherwise RATE, BAUD and the bytes all carry a confidence the capture did not earn. Ranked above the
  -- informational notes and below the wire warnings, which describe things already wrong with the signal.
  if sdec.acq_fs_est then
    add(string.format('sample rate NOT measured from this capture -- showing the requested %g S/s; '
                      .. 'every timing figure derives from it', sdec.fs or 0))
  end

  -- WHY THE BYTE LOG IS OFF, in full, and DELIBERATELY LOW. The status cell has 200 px and spends them
  -- saying 'log: NOT LOGGING' -- always visible, never faded -- so this note's only job is the reason,
  -- which is two to three times that width and needs the table's own. Ranked here rather than beside
  -- stickyerr because a log fault PERSISTS: with no key at all it is true of every capture, and above
  -- the wire warnings it would have been the one note shown for the rest of the session, suppressing
  -- every per-capture diagnostic behind '(+3 more)'. Measured -- it masked the 12 V divider hint.
  --
  -- Not in clear_result()'s eviction either, for the same reason: a log fault is a property of the KEY,
  -- and a successful append, log_new() or a teardown is what clears it.
  if sdec.flog_why ~= nil then add('NOT LOGGING: ' .. tostring(sdec.flog_why)) end

  -- ORDER MATTERS HERE. The forced-rate disagreement warning goes FIRST: it is the only note that
  -- says the bytes on screen may be wrong with nothing else to indicate it, so it must not be the
  -- one truncated away behind an informational note about an alternative rate that also fits. A
  -- different baud rate that explains the same waveform in turn outranks a format alternative,
  -- because it changes every byte rather than just the framing.
  add(sdec.rate_note)
  add(sdec.baud_note)
  add(sdec.fmt_note)

  -- THE CAPTURE WAS FULL, so the message probably continues past what is shown -- and that is the
  -- one thing the operator cannot otherwise know. A capture that comes back exactly full looks
  -- identical to a complete short message, and on a continuously busy line (a microcontroller
  -- dumping debug text, which is the main use of this app) EVERY capture is full.
  --
  -- The note names the remedy too: locking the detected baud rate drops the sample rate to suit it
  -- and lengthens the window, 19 bytes to 192 at 9600.
  if sdec.res ~= nil and sdec.res.nf > 0 then
    local cap = sdec.window_bytes(sdec.baud, sdec.res.nbits, sdec.res.par,
                                  sdec.res.nstop)
    if cap ~= nil and cap > 0 and sdec.res.nf >= cap then
      if sdec.force_baud == nil then
        add(string.format('capture FULL at %d bytes -- the message may continue; ' ..
                          'lock the baud rate for a longer window', cap))
      else
        add(string.format('capture FULL at %d bytes -- the message may continue', cap))
      end
    end
  end

  -- "Auto" parity with a FORCED width is not auto, and the operator has to be told.
  --
  -- decode_from's forced path takes `sdec.force_par or PAR_NONE`, because forcing a width bypasses
  -- the format search entirely -- which is the point of forcing on a bad wire, the search being
  -- the stage impulse noise captures. So Data Bits = 8 with Parity = Auto decodes as 8N1 without
  -- ever trying 8E1 or 8O1. The header does show "8N1", but a reader who chose "Auto" would fairly
  -- take that as DETECTED rather than ASSUMED.
  --
  -- MIDI and LIN set both fields, so neither trips this, and Lock Detected sets parity from the
  -- result. It fires only for a hand-forced width with parity left on Auto.
  if sdec.force_nbits ~= nil and sdec.force_par == nil then
    add('parity was ASSUMED none, not detected -- a forced width skips the search')
  end

  -- A property of the wire, not of this decoder: a second stop bit is indistinguishable from a bit
  -- of idle. Suppressed when the format is FORCED, since the stop-bit count is then GIVEN rather
  -- than inferred and the remark is pure noise. Last in the list, so it shows only when nothing
  -- more urgent is competing.
  if sdec.res ~= nil and sdec.res.nbad == 0 and sdec.force_nbits == nil then
    add('stop-bit count is not observable from the wire; shown as 1')
  end
  return t, m
end

-- CHARACTER WIDTHS FOR THE PANEL'S SMALL PROPORTIONAL FACE, bytes 32..126, as px + 48 so the
-- table is a printable literal. There is no text-measurement call on this firmware, and the only
-- alternative is a character COUNT -- but the face runs 3 px (an 'i') to 17 px (an '@'), so a
-- count safe for a wide string wastes a third of the cell on a narrow one.
--
-- CALIBRATED AGAINST THE INSTRUMENT, not against tools/render_png.py, whose face renders ~16 %
-- narrow: these are the mockup's widths scaled by 1.159, the factor measured off a screen grab
-- (the 74-char 250 kBd warning draws 568 px on the panel and 490 px in the mockup).
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

-- `s` clipped to fit `maxpx`, with '...' marking that it was clipped.
--
-- The firmware clips at the PANEL EDGE and says nothing, so an over-long string is cut without a
-- mark and the operator cannot tell a complete sentence from a truncated one.
function sdec.ui_fit(s, maxpx)
  if s == nil then return '' end
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

-- The note cell runs from ui_note_val_x to the table's right rule at ui_rule_x1.
sdec.ui_note_px = 700

-- The one note the cell has room for, plus how many others there are.
--
-- BOTH PARTS ARE FITTED TO THE CELL, and the marker wins when they compete: a note long enough to
-- fill the cell would otherwise push '(+N more)' off the panel, leaving no sign that a second note
-- exists at all. The marker's width is reserved only when there IS a marker, so the whole cell
-- stays available for the common single-note case.
function sdec.ui_note_text()
  local t, m = sdec.ui_notes()
  if m < 1 then return '' end
  local px = sdec.ui_note_px
  if m == 1 then return sdec.ui_fit(t[1], px) end
  local mk = string.format('  (+%d more)', m - 1)
  return sdec.ui_fit(t[1], px - sdec.ui_textw(mk)) .. mk
end

-- ============================================================================
-- Main screen
-- ============================================================================
-- Drop every display SHADOW CACHE. The caches let a refresh skip writes that would change nothing
-- (see ui_set), and they must go TOGETHER whenever the objects they shadow are rebuilt.
--
-- EVERY CACHE MUST BE LISTED HERE. An omission fails the same way every time: the object comes
-- back at its create-time colour while the stale cache says the write is unnecessary -- so a
-- capture with framing errors shows its error count in the "all clear" green. Keeping the caches
-- FEW is what makes the list maintainable.
--
-- Called from ui_destroy AND ui_build. Redundant in build, which destroys first, but the invariant
-- is "a cache never outlives its object", and stating it twice is what makes it an invariant
-- rather than a coincidence of call order.
--
-- ui_page is NOT a cache. It is view state, and clearing it here would silently move the operator
-- back to page 1.
function sdec.ui_invalidate()
  sdec.ui_last, sdec.ui_rowc = nil, nil
  -- ui_vrc shadows the vertical rules' fill, so it goes with them. Acceptable as a fifth cache
  -- because it shadows a whole ARRAY with one value, not one object with a second cache.
  sdec.ui_vrc = nil
  sdec.ui_sbc = nil
  -- ui_fvalc, ui_modec and ui_logc must be here too. Omitting any one defeats the colour channel
  -- it shadows: a locked wire shows its values in the plain column colour and the MODE cell
  -- reverts to grey, silently undoing the lock indicator -- whose whole point is that a forced
  -- value must not look measured.
  sdec.ui_fvalc, sdec.ui_modec, sdec.ui_logc = nil, nil, nil
  sdec.ui_trigc = nil
  sdec.ui_lockc = nil
  return true
end

-- Delete every main-screen object and nil its handle.
function sdec.ui_destroy()
  -- Switch away BEFORE deleting a visible screen; delete children before the
  -- screen that owns them.
  if sdec.ui_scr ~= nil then
    pcall(function() display.changescreen(display.SCREEN_HOME) end)
  end
  local i
  if sdec.ui_row ~= nil then
    for i = 1, table.getn(sdec.ui_row) do sdec.del_obj(sdec.ui_row[i]) end
  end
  -- The extra dump fields and the vertical rules. Deleted HERE, in the del_obj block, and NOT
  -- after the screen goes: a delete against a dead parent is refused, counts in delfails, and
  -- leaks every object it was supposed to reclaim.
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
  -- EVERY BUTTON, VIA A DENSE LIST, because sdec.ui_btn is POSITIONAL and can have a hole:
  -- ui_build stores the three right-margin buttons at ui_btn[7..9] before the bottom row fills
  -- 1..6, so a bottom row that partly fails leaves a gap -- and table.getn stops at a gap, so a
  -- walk over ui_btn would never reach 7, 8 or 9. Those would be dropped unreferenced when ui_btn
  -- is nil'd, surviving only by the firmware's parent cascade, which this app never relies on.
  --
  -- ui_allbtn is appended to in creation order, so it is dense whatever fails. Delete from it
  -- INSTEAD of from ui_btn, not as well: del_obj on an already-deleted handle is refused, which
  -- counts against delfails and strands the handle on sdec.orphans, and the rebuild guard reads
  -- both.
  if sdec.ui_allbtn ~= nil then
    local ai
    for ai = 1, table.getn(sdec.ui_allbtn) do sdec.del_obj(sdec.ui_allbtn[ai]) end
    sdec.ui_allbtn = nil
  end
  -- Nil'd because ui_build only ASSIGNS these when the create succeeds, so a rebuild whose Lock
  -- Rate button failed would otherwise inherit the previous build's dead handle and go on calling
  -- setstate against it.
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
  sdec.del_obj(sdec.ui_page_t)
  sdec.del_obj(sdec.ui_log_t)
  sdec.del_obj(sdec.ui_pgind)
  sdec.ui_pgind, sdec.ui_pgindtxt = nil, nil
  sdec.del_obj(sdec.ui_scr)
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

-- Build the main screen: status fields, dump rows, rules and buttons.
function sdec.ui_build()
  -- Destroy first, ALWAYS. Creating over a live handle overwrites the only
  -- reference to the old object, stranding it inside the firmware until a power
  -- cycle; that accumulation is what walks this firmware toward a PC=002F751C
  -- panic.
  sdec.ui_destroy()
  sdec.ui_invalidate()

  local create = display.create
  local small, med = display.FONT_SMALL, display.FONT_MEDIUM
  local left = display.JUST_LEFT
  local x = sdec.ui_x

  sdec.ui_scr = create(display.ROOT, display.OBJ_SCREEN, sdec.ui_title)

  -- display.create RETURNS NIL WHEN THE POOL IS EXHAUSTED, POSTS NOTHING, AND DOES NOT RAISE.
  -- Event 1701 is logged the first time only; after that the failure is silent, every child is
  -- created against a nil parent, and start()'s pcall sees success -- which showed as a screen
  -- with no buttons and no message. Raising here reuses start()'s existing teardown-and-report
  -- path.
  if sdec.ui_scr == nil then
    error('display object pool exhausted -- power cycle the instrument. (The firmware posts '
          .. 'event 1701 only once, then display.create returns nil silently.)', 0)
  end

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
  -- The status band, boxed the same way the header strip is. Five thin rects, created once and
  -- never touched again, so they cost nothing per refresh.
  rule(sdec.ui_rule_x0, sdec.ui_stat_top, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_stat_bot, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_rule_x1, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_stat_div, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_trig_div, sdec.ui_stat_top, 1, sdec.ui_stat_bot - sdec.ui_stat_top)
  rule(sdec.ui_rule_x0, sdec.ui_rule_top, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_mid, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_bot, rw, 1)
  -- Outer verticals close the box at both ends.
  rule(sdec.ui_rule_x0, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  rule(sdec.ui_rule_x1, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  -- ...and one after the NOTE label, so the note reads as a cell too.
  rule(sdec.ui_note_val_x - 9, sdec.ui_rule_mid, 1,
       sdec.ui_rule_bot - sdec.ui_rule_mid)

  -- THE DUMP'S TWO VERTICAL RULES: offset | hex | ascii.
  --
  -- THERE IS NO RULE AT ui_vr3_x closing the ASCII column on the right. The ASCII text is
  -- arbitrary bytes, so its rendered width is not knowable in advance -- mixed-case measures 7.80
  -- px/char but a row of 'W's does not -- and a boundary the content can cross is worse than no
  -- boundary. Nothing follows the gutter, so its right edge needs no line. ui_vr3_x stays defined
  -- because ui_asn's arithmetic reads naturally with it.
  --
  -- Kept in their own array, NOT ui_rule, because unlike every other rule here these are
  -- recoloured per refresh: they belong to the hex view and are hidden in the others.
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
  -- NO HIT RECT OVER BAUD + FORMAT, and no setevent, for two firmware reasons:
  --
  --   * EVENT_PRESS does not reach an OBJ_RECT -- "1717 Attribute event, does not apply to an
  --     object of type Rectangle" -- and the refusal is severity 2, which raises an error dialog
  --     OVER the panel;
  --   * an OBJ_RECT draws an OUTLINE whether or not it is filled, so a hit box paints a border
  --     around the BAUD field brighter than any rule in the header table.
  --
  -- The padlock glyph SHOWS the lock state; the Lock Rate button and Options > Lock Detected
  -- change it.
  sdec.ui_lockhit = nil

  local nf = table.getn(sdec.ui_fields)
  local j
  -- A vertical rule before every column but the first, so the strip reads as a
  -- table rather than as a row of loose words.
  for j = 2, nf do
    rule(sdec.ui_fields[j].x - 9, sdec.ui_rule_top,
         1, sdec.ui_rule_mid - sdec.ui_rule_top)
  end
  for j = 1, nf do
    local fd = sdec.ui_fields[j]
    sdec.ui_flab[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x, sdec.ui_lab_y,
                             fd.lab, sdec.ui_c_lab, small, left)
    -- SMALL, not MEDIUM, for every cell but the two flagged `med`. Each field x in sdec.ui_fields
    -- is sized on the MEASURED 8 px FONT_SMALL advance (sdec.ui_ch_w), which also governs the dump
    -- columns, the vertical rules and the collision check in tools/render_png.py -- one advance
    -- for the whole panel rather than two.
    --
    -- A FONT_MEDIUM value advances ~13.4 px, so an 8-character LOGIC value ('3V3 CMOS') takes 107
    -- px and touches THRESH: a row drawn off the grid its columns were built from does not line
    -- up. Emphasis is carried by COLOUR here instead (green locked, amber auto, red nothing
    -- decoded), which is a stronger signal than 5 px of glyph.
    local fnt = small
    if fd.med then fnt = med end
    sdec.ui_fval[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x, sdec.ui_val_y,
                             '--', fd.c, fnt, left)
  end
  -- THE PADLOCK, drawn from RECTS because the panel font has no padlock glyph: TSP strings are
  -- bytes the firmware renders from its own proportional face, and U+1F512 is not in it. FOUR
  -- DISPLAY OBJECTS -- a solid body and a three-piece arch -- which is worth counting, because
  -- object creation is the destabilising operation behind the one-build-per-power-cycle rule.
  -- Recolouring them afterwards is not.
  --
  -- It sits AFTER THE WIDEST VALUE THE BAUD CELL CAN HOLD, not after the one currently shown:
  -- '115200' is 6 x 14 = 84 px from x = 8, ending at 92, so the glyph goes at 95 and the BAUD
  -- column is 107 px wide to hold value + gap + glyph.
  --
  -- Colour is the whole reason it exists (green locked / amber auto / red nothing-to-lock), and it
  -- changes through sdec.ui_fill, which counts refusals in fillfails -- so if setfill turns out
  -- not to work on rects, the status row says so rather than the icon silently lying.
  --
  -- OBJECT CENSUS, counted by tools/mock_display.lua rather than estimated: 122 objects live after
  -- ui_build(), and 134 once the options screen has been built too, 12 of them its own. Any
  -- reasoning about how close the pool is to exhaustion starts from those two numbers.
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
  lockpart(lx + 2, sdec.ui_lab_y + 0, 5, 1)     -- shackle: top bar
  lockpart(lx + 2, sdec.ui_lab_y + 1, 1, 4)     -- shackle: left post
  lockpart(lx + 6, sdec.ui_lab_y + 1, 1, 4)     -- shackle: right post
  sdec.ui_lockbody = lockpart(lx, sdec.ui_lab_y + 5, 9, 7)   -- body
  -- No setevent on these either: EVENT_PRESS on an OBJ_RECT is refused (1717) at severity 2, which
  -- raises an error dialog over the panel.

  -- THE MODE CELL: the capture mode, top-left inside the header table's box grid, in a per-mode
  -- colour -- the at-a-glance channel, since colour is read faster than any word. One text object,
  -- retexted and recoloured per refresh, so it costs no extra object.
  --
  -- Stored in ui_flab so ui_destroy deletes it explicitly rather than leaving it to the firmware's
  -- parent cascade, which this app never relies on.
  sdec.ui_modelab = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_note_lab_x,
                           sdec.ui_note_y, 'FRAME', sdec.ui_c_dim, small, left)
  sdec.ui_flab[nf + 1] = sdec.ui_modelab
  sdec.ui_note = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_note_val_x,
                        sdec.ui_note_y, '', sdec.ui_c_warn, small, left)

  -- FOUR FIELDS PER ROW: offset, two hex groups, ASCII. ui_row is the LEFTMOST text of the row, so
  -- a non-hex view writes its whole line there and blanks the other three. Only the hex view
  -- splits the row, and only the hex view needs the vertical rules.
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

  -- Position bar, to the right of the dump rows and on the same pitch.
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

  sdec.ui_page_t = create(sdec.ui_scr, display.OBJ_TEXT, x, sdec.ui_stat_y, '',
                          sdec.ui_c_dim, small, left)
  sdec.ui_log_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_stat_div + 6,
                         sdec.ui_stat_y, '',
                         sdec.ui_c_dim, small, left)
  -- NO HIT RECT OVER THE TRIGGER CELL. It existed to catch a tap, and EVENT_PRESS on an
  -- OBJ_RECT is refused on this firmware (1717) -- so it caught nothing while still drawing
  -- an outline, which rendered as a box around EXT TRIG visibly brighter than every real rule
  -- on the panel. Options > Rear BNC is the control.
  sdec.ui_trighit = nil
  -- Likewise no setevent: rects do not take presses on this firmware (see the padlock).
  -- Options > Rear BNC is the reliable control.
  sdec.ui_trig_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_trig_x, sdec.ui_stat_y,
                          'EXT TRIG', sdec.ui_c_warn, small, left)

  -- Buttons. Widths chosen so the row ends well inside the 798 px limit.
  local by = sdec.ui_btn_y
  sdec.ui_btn = {}
  -- Dense, appended in creation order, and the ONLY list ui_destroy deletes buttons from:
  -- ui_btn is positional and can have a hole (see ui_destroy).
  sdec.ui_allbtn = {}
  local b
  -- SIX BUTTONS across 8..774, inside the 798 limit: 84 to 120 px each, all far above a
  -- comfortable touch target at 58 px tall.
  --
  -- `View` and `Mode` are STATIC labels rather than naming the state they cycle to. There are four
  -- views (text, hex, MIDI messages, LIN frames) and three modes; which one is showing is named in
  -- the status row and the MODE cell, and a button that relabels itself has to be read twice.
  --
  -- `NewLog` is a button rather than an options field because separating one device's messages
  -- from the next is something done WHILE watching them arrive, and a control you must leave the
  -- screen to reach is a control you do not use.
  --
  -- `Save` stays even though frame mode logs every capture automatically, because the two write
  -- different things: the auto-log is one message per capture as text and hex, while Save writes
  -- the full report -- every view, the notes, the summary.
  local bdef = {
    {x = 8,   w = 120, t = 'Capture',    e = 'sdec.capture()'},
    {x = 152, w = 90,  t = 'View',       e = 'sdec.view_toggle()'},
    {x = 266, w = 100, t = 'Mode',       e = 'sdec.mode_cycle()'},
    {x = 390, w = 112, t = 'NewLog',     e = 'sdec.log_new()'},
    {x = 526, w = 112, t = 'Save',       e = 'sdec.save()'},
    {x = 662, w = 112, t = 'Options',    e = 'sdec.options()'},
  }
  -- PAGE UP, LOCK RATE, PAGE DN, down the dump area's right margin in that vertical order: up is
  -- up and down is down, so neither page button needs reading.
  --
  -- A PAGING CONTROL IS NOT OPTIONAL. 240 bytes is one page only in FRAME mode; a 32 kB streaming
  -- capture is 137 pages, and without these the app collects 32768 bytes and shows the first 240.
  --
  -- LOCK RATE IS HERE BECAUSE THE PADLOCK GLYPH CANNOT BE PRESSED: it is drawn from OBJ_RECTs and
  -- EVENT_PRESS on a rect is refused on this firmware (1717), which would otherwise leave
  -- Options > Lock Detected as the only route to the most useful action on the panel.
  --
  -- All three hide themselves when they have nothing to do -- the page buttons when the capture
  -- fits one page, Lock Rate when there is no detected rate to pin -- which is why they are
  -- tracked separately from the bottom row. See sdec.ui_page_btns().
  -- NARROWER THAN 185, RIGHT EDGES ALL AT 785. The width these buttons do not use is width the dump
  -- rows get: a TEXT row is 80 columns of a proportional font, needing 636 px against the 592 it had,
  -- so the right-hand characters were drawn under Page Up -- and the page arithmetic still counted
  -- them, so paging stepped over bytes that were never visible.
  --
  -- THE PAGE BUTTONS GO NARROWER THAN Lock Rate BECAUSE THEIR LABELS ARE SHORTER. 'Lock Rate'
  -- measures 134 px and cannot follow them down; test_serial's label-fit check is what caught 130.
  -- Right edges are what line up, since these sit against the panel edge.
  local pbw, lbw = 125, 140
  local pdef = {
    {x = 785 - pbw, y = 58,  w = pbw, t = 'Page Up',   e = 'sdec.page_prev()',  pg = true},
    {x = 785 - lbw, y = 160, w = lbw, t = 'Lock Rate', e = 'sdec.lock_toggle()'},
    {x = 785 - pbw, y = 262, w = pbw, t = 'Page Dn',   e = 'sdec.page_next()',  pg = true},
  }
  local pk, npg = nil, 0
  sdec.ui_pgbtn = {}
  for pk = 1, table.getn(pdef) do
    local pd = pdef[pk]
    local pb = create(sdec.ui_scr, display.OBJ_BUTTON, pd.x, pd.y, pd.t, pd.w)
    if pb ~= nil then
      display.setevent(pb, display.EVENT_PRESS, pd.e)
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
  -- WHICH PAGE OF HOW MANY, in the gap between Page Up (ends at 116) and Lock Rate (starts at 160).
  -- Paging blind is the complaint this answers: the buttons move the view but nothing said how much
  -- there was or where in it you were. Shown and hidden with the page buttons -- 'page 1 of 1' is
  -- noise -- and it costs ONE display object, unlike the 15 the position bar wants.
  --
  -- JUST_RIGHT against the panel edge, so the count does not shuffle sideways as it grows from
  -- 'page 1 of 9' to 'page 27 of 35'. x is therefore the RIGHT edge, not the left.
  sdec.ui_pgind = create(sdec.ui_scr, display.OBJ_TEXT, 770, 141, '',
                         sdec.ui_c_dim, small, display.JUST_RIGHT)
  sdec.ui_pgindtxt = nil
  -- THESE TWO ARE VISIBILITY SHADOW CACHES, and nil means "unknown, so write it on the next
  -- refresh".
  --
  -- WARNING: sdec.ui_lockbtn is NOT a cache -- it is the button's handle, assigned in the loop
  -- above. Clearing it here leaves it nil for the life of the app, which makes the visibility
  -- block in ui_page_btns() (`if sdec.ui_lockbtn ~= nil`) dead code: Lock Rate then keeps whatever
  -- state create() left it in and is never hidden, sitting on the glass with the rate already
  -- locked and offering a press it must not offer. bench_panel.py measures the margin buttons by
  -- pixel and is what catches this.
  sdec.ui_pgvis = nil
  sdec.ui_lockvis = nil
  local k
  local nb = 0
  for k = 1, table.getn(bdef) do
    local bd = bdef[k]
    b = create(sdec.ui_scr, display.OBJ_BUTTON, bd.x, by, bd.t, bd.w)
    if b ~= nil then
      display.setevent(b, display.EVENT_PRESS, bd.e)
      sdec.ui_btn[k] = b
      sdec.ui_allbtn[table.getn(sdec.ui_allbtn) + 1] = b
      nb = nb + 1
    end
  end

  -- A SCREEN WITH NO BUTTONS IS NOT A USABLE APP, and this is the check that catches a pool that
  -- ran out PART WAY through -- the screen exists, so the guard above passed, and there is nothing
  -- to press. The buttons are built last precisely so this covers everything before them.
  if nb < table.getn(bdef) then
    error(string.format('only %d of %d buttons could be created -- display object pool exhausted. '
                        .. 'Power cycle the instrument.', nb, table.getn(bdef)), 0)
  end

  return sdec.ui_scr
end

-- Show or hide the right-margin buttons: the page buttons when there is somewhere to page to, Lock
-- Rate when there is a detected rate to pin. A control that does nothing is worse than an absent
-- one -- it invites a press and teaches that presses do nothing.
--
-- STATE_INVISIBLE, not STATE_DISABLE: the reference is explicit that DISABLE applies to
-- display.OBJ_EDIT_* only, so a disabled button is not available on this firmware.
--
-- Cached, because this runs on every refresh and a setstate per button per refresh is display
-- traffic for a state that changes only when the page count does.
function sdec.ui_page_btns()
  local t = sdec.ui_pgbtn
  if t == nil then return false end
  local npg = sdec.ui_npages()
  local want = false
  if npg > 1 then want = true end
  -- 1-BASED FOR THE OPERATOR: ui_page is a 0-based index and 'page 0 of 35' names a page no button
  -- can reach. Cached like every other cell, so a refresh with the same page costs no display traffic.
  if sdec.ui_pgind ~= nil then
    local ptxt = ''
    if want then ptxt = string.format('page %d of %d', sdec.ui_page + 1, npg) end
    if ptxt ~= sdec.ui_pgindtxt then
      sdec.ui_set(sdec.ui_pgind, ptxt)
      sdec.ui_pgindtxt = ptxt
    end
  end
  if want ~= sdec.ui_pgvis then
    local st = display.STATE_INVISIBLE
    if want then st = display.STATE_ENABLE end
    local i
    for i = 1, table.getn(t) do
      pcall(function() display.setstate(t[i], st) end)
    end
    sdec.ui_pgvis = want
  end

  -- LOCK RATE IS SHOWN ONLY WHEN THERE IS SOMETHING TO LOCK. Three states, and only one of
  -- them wants the button:
  --
  --   'auto'    a rate was DETECTED and is not pinned -- the button locks it. Shown.
  --   'locked'  already pinned. Nothing for it to do, so hidden rather than offering a press
  --             that would UNLOCK -- a button labelled 'Lock Rate' must not unlock.
  --   neither   nothing decoded yet, so there is no rate to pin. Hidden.
  --
  -- Unlocking is Options > Auto Detect, which is also the press that re-detects: the two belong
  -- together, and 'not locked' is not a thing to aim for on its own.
  --
  -- With auto-lock on this button is usually absent, which is correct -- it is the manual route
  -- for the captures auto-lock DECLINED: too few frames, a poor fit, an unstable baseline.
  if sdec.ui_lockbtn ~= nil then
    local lw = false
    if sdec.lock_state ~= nil and sdec.lock_state() == 'auto' then lw = true end
    if lw ~= sdec.ui_lockvis then
      local lst = display.STATE_INVISIBLE
      if lw then lst = display.STATE_ENABLE end
      pcall(function() display.setstate(sdec.ui_lockbtn, lst) end)
      sdec.ui_lockvis = lw
    end
  end
  return true
end

-- Repaint from the current decode result. settext only: nothing is created,
-- deleted or repositioned, which is what keeps a refresh cheap.
function sdec.ui_refresh()
  pcall(function() sdec.ui_page_btns() end)
  if sdec.ui_scr == nil then return false end
  local set = sdec.ui_set

  local fv = sdec.ui_field_values()
  local j
  -- Values, and the three lockable ones also carry the lock state as a colour -- a second
  -- channel, so the distinction survives even if setfill on a rect turns out not to work.
  if sdec.ui_fvalc == nil then sdec.ui_fvalc = {} end
  for j = 1, table.getn(sdec.ui_fval) do
    set(sdec.ui_fval[j], fv[j] or '--')
    local want = sdec.ui_field_colour(j)
    if sdec.ui_fvalc[j] ~= want then
      sdec.ui_color(sdec.ui_fval[j], want)
      sdec.ui_fvalc[j] = want
    end
  end
  -- The padlock, recoloured only when the state actually changes.
  local lc = sdec.lock_colour()
  if sdec.ui_lockc ~= lc then
    local li
    for li = 1, table.getn(sdec.ui_lock or {}) do
      sdec.ui_fill(sdec.ui_lock[li], lc)
    end
    sdec.ui_lockc = lc
  end

  -- The MODE cell, recoloured as well as retexted: the colour is what makes the mode
  -- readable without reading. Only written when it changes, like every other cell.
  local mdc = sdec.mode_cur()
  set(sdec.ui_modelab, mdc.name)
  if sdec.ui_modec ~= mdc.c then
    sdec.ui_color(sdec.ui_modelab, mdc.c)
    sdec.ui_modec = mdc.c
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
  local i
  for i = 1, sdec.ui_nrow do
    local i0 = base + (i - 1) * cols + 1
    -- hxs/ass stay nil in every view but hex, and are written as '' below. They MUST be blanked: a
    -- stale hex block behind a TEXT view is a second, wrong reading of the same bytes sitting next
    -- to the right one.
    local txt, bad, hxs, hxs2, ass

    if vw.line ~= nil then
      -- One parsed message or frame per row. Its own kind says whether it is a
      -- problem, so the row colour comes from that rather than from the byte error
      -- list -- a LIN break, for instance, IS a framing error at the byte layer and is
      -- not a fault at the frame layer.
      txt = ''
      bad = false
      local fn = sdec[vw.line]
      if fn ~= nil then txt = fn(i0) end
      local pr = sdec[vw.res]
      if pr ~= nil and pr.kind ~= nil then bad = (pr.kind[i0] == 'err') end
    else
      if mode == 'hex' then txt, hxs, hxs2, ass = sdec.ua_hex_parts_line(i0, cols)
      else txt = sdec.ua_text_line(i0, cols) end
      -- Colour the whole row when it holds a frame that failed its stop or parity
      -- bit. Per-character colour is impossible with one object per row, and per-row
      -- is enough to find the damage.
      bad = false
      if r ~= nil then
        local j
        for j = i0, i0 + cols - 1 do
          -- Red for an INTERIOR error only. The head frames a gapless stream spends
          -- resynchronising, and the last frame the buffer cut in half, are not signal faults
          -- and must not paint a row red on a healthy line.
          if j <= r.nf and r.errs[j] ~= nil
             and j > (sdec.ua_edge_frames or 3) and j < r.nf then
            bad = true
          end
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
    -- THE LEFTMOST OBJECT IS NOT ALWAYS THE OFFSET. In hex view ui_row[i] holds the offset, which
    -- should be dim; in every other view it holds the WHOLE LINE, which must not be. Dimming it
    -- unconditionally greyed out the entire text view.
    local woff = want
    if mode == 'hex' then
      -- Dim on a healthy row, but a bad row is red all the way across or the eye misses which
      -- row is flagged.
      woff = sdec.ui_c_off
      if bad then woff = want end
    end
    -- The cache key carries the offset colour too, so switching hex <-> text repaints it even
    -- when the row's own colour has not changed.
    if sdec.ui_rowc[i] ~= want or sdec.ui_rowo[i] ~= woff then
      sdec.ui_rowo[i] = woff
      sdec.ui_color(sdec.ui_row[i], woff)
      -- Both hex fields and the ASCII carry the row's colour. Colouring only some would put a
      -- red field beside white bytes, which reads as "that field is wrong".
      sdec.ui_color(sdec.ui_rhx[i], want)
      sdec.ui_color(sdec.ui_rhx2[i], want)
      sdec.ui_color(sdec.ui_ras[i], want)
      sdec.ui_rowc[i] = want
    end
  end

  -- THE VERTICAL RULES BELONG TO THE HEX VIEW, so they are hidden in the others -- otherwise two
  -- hairlines cut across an 80-column TEXT row that has no columns to divide.
  --
  -- Hidden by painting them sdec.ui_c_hide, which matches the background, and NOT 0. The two look
  -- identical on screen and only one works: the firmware reads a fill of 0 as "unset" and paints
  -- nothing at all, so setfill(h, 0) is a refused write rather than a black rectangle.
  -- tools/mock_display raises on it by name. A background-matching colour is an ORDINARY fill, so
  -- hiding uses exactly the mechanism showing uses and cannot fail differently.
  --
  -- Recolouring is the ONLY way to take an object off the screen: display objects have no
  -- visibility attribute, and setposition ERRORS on some types.
  --
  -- BOTH conditions, not just the view. `mode == 'hex'` says the columns would be meaningful IF
  -- there were a dump; md.view says whether there is one. A streaming mode paints no rows at all,
  -- so the view test alone would leave the rules standing over an empty area, delimiting nothing.
  local vwant = sdec.ui_c_hide
  if mode == 'hex' and sdec.mode_cur().view then vwant = sdec.ui_c_rule end
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
  -- The protocol qualifies the status word rather than taking a header column: the
  -- header table has no clear space left, and when MIDI is selected the forced
  -- 31250 / 8N1 in BAUD and FORMAT already say so.
  local st = sdec.ui_status
  if sdec.proto ~= nil and sdec.proto ~= 'uart' then
    st = string.upper(sdec.proto) .. ' ' .. st
  end
  -- delfails/fillfails are display-API refusals. Both are zero on a healthy panel,
  -- so they cost nothing until they matter -- and if setfill turns out not to work
  -- on this firmware, this row is the only place that would say so.
  local warn = ''
  if (sdec.delfails or 0) > 0 or (sdec.fillfails or 0) > 0 then
    warn = string.format('  del?%d fill?%d', sdec.delfails or 0, sdec.fillfails or 0)
  end
  -- The status row leads with the CAPTURE MODE, the setting that changes what Capture does. The
  -- Mode button is a static label, so the MODE cell and this row are the two places it is named.
  --
  -- The streaming modes get a different row entirely: they produce a FILE, not a view, so
  -- page/of/bytes describes nothing the operator can act on. sdec.ck_status() supplies the counter
  -- and the filename.
  local md = sdec.mode_cur()
  -- Same reasoning as the BYTES column: a finished stream keeps the status row until the mode
  -- is cycled, or the quiet-line exit would replace its own summary with a frame-mode row.
  if md.view and sdec.ck_tot == nil and not sdec.ck_running then
    -- THE WINDOW CAPACITY, not just the byte count. '97 of 97' says how much was decoded; it
    -- does not say the capture could have held 192, which is the number that answers "was the
    -- message seen whole?". It moves with the sample rate -- 19 bytes at 1 MS/s, 192 once 9600
    -- is locked -- which is why it is shown continuously rather than only when the capture is
    -- full, and rather than left to be inferred.
    local capn = nil
    if sdec.res ~= nil then
      capn = sdec.window_bytes(sdec.baud, sdec.res.nbits, sdec.res.par, sdec.res.nstop)
    end
    local wintxt = ''
    if capn ~= nil and capn > 0 then wintxt = string.format(' win %d', capn) end
    -- COMPACT, because this string has to fit its cell at every baud rate and in every view. A
    -- verbose form -- 'FRAME  TEXT  page 1/1  bytes 1-1200 of 1200  win 240  [done]' -- runs to
    -- 60-odd characters, and at the measured 7.80 px/char that is past the divider and straight
    -- through the log field beside it. Hence 'pg' and 'N-M/T', which drop words rather than
    -- numbers. The unit name stays, because 'bytes' versus 'msg' is what says whether the counts
    -- are bytes or parsed messages.
    set(sdec.ui_page_t, string.format('%s %s pg %d/%d %s %d-%d/%d%s [%s]%s',
        md.name, mname, sdec.ui_page + 1, npg, sdec.ui_unit(),
        math.min(base + 1, nit), math.min(base + per, nit), nit, wintxt, st, warn))
  else
    set(sdec.ui_page_t, string.format('%s  %s%s', md.name, sdec.ck_status(), warn))
  end
  -- THE TRIGGER SOURCE, so that a capture which appears to hang is distinguishable from one
  -- waiting for an edge that is not coming.
  --
  -- EXCEPTION REPORTING: the default (start-bit edge, no external) says NOTHING, because a marker
  -- that is always present is not a marker. Anything else texts this cell AND turns it amber --
  -- one setcolor on an object that already exists, so the glanceable channel costs nothing.
  --
  -- GREEN = armed and in force. AMBER = off, or on but IGNORED. The two are distinguished because
  -- "ticked but doing nothing" is the case that misleads: free run means DO NOT WAIT, so an
  -- external trigger cannot apply while the checkbox on the form still shows ticked.
  local trigtxt, trigcol = 'EXT TRIG', sdec.ui_c_warn
  if sdec.trigext and sdec.trigmode ~= 'free' then
    trigcol = sdec.ui_c_locked
  elseif sdec.trigext then
    trigtxt = 'EXT ignored'
  end
  if sdec.trigmode == 'front' then trigtxt = trigtxt .. '  KEY' end
  set(sdec.ui_trig_t, trigtxt)
  if sdec.ui_trigc ~= trigcol then
    sdec.ui_color(sdec.ui_trig_t, trigcol)
    sdec.ui_trigc = trigcol
  end

  if not md.view or sdec.ck_tot ~= nil or sdec.ck_running then
    -- While streaming, the right-hand cell carries the CONTROLS: an operator watching a
    -- four-minute capture needs to know how to get out of it more than they need the debug log's
    -- line count, and both will not fit in the left string, which already ends near 385 px of the
    -- 430 available.
    --
    -- WHICH CONTROL IS TRUE IS DECIDED BY THE STATE, AND FOR A ONE-PRESS RUN THE TRUE ANSWER IS NONE.
    -- This cell said 'TRIGGER key = stop' on the strength of cancel_setup()'s blender latch. MEASURED
    -- 2026-08-18 and it is not so: pressed 20 % into a 32 kB decode, with tens of seconds of polling
    -- still to come, the run finished 'full' and the latch was EMPTY -- the key's event never reaches
    -- the blender while a panel-initiated run executes. The plumbing behind it is sound (a firmware
    -- trigger timer blended in as stimulus 2 DID cancel at 8 s, keeping 497 bytes), so what is false
    -- is only the claim that a finger can deliver it. A touch press cannot act either: presses queue.
    --
    -- So it names no control. The duration is on the note line, where there is room for it.
    --
    -- PAINTED ONCE, BEFORE THE RUN, and correct for its whole duration: sdec.progress() repaints
    -- only the counter cell, so nothing overwrites this until the run returns. strm_inflight is what
    -- makes that possible -- it is set by capture() before the refresh, because ck_running does not
    -- become true until stream_begin() is already inside the job.
    if sdec.strm_recording then
      set(sdec.ui_log_t, 'Capture=Stop  Mode=Exit')
    elseif sdec.ck_job ~= nil then
      set(sdec.ui_log_t, 'Capture=step  Mode=Exit')
    elseif sdec.ck_running or sdec.strm_inflight then
      set(sdec.ui_log_t, 'no stop until it ends')
    else set(sdec.ui_log_t, 'Mode=Exit to FRAME') end
  else
    set(sdec.ui_log_t, sdec.flog_status())
  end
  return true
end

-- THE BYTE LOG, for the status row: which file is being appended to, and how many BYTES are in it
-- so far. Both, always, in every mode -- the app's promise is that no decoded byte is lost, and a
-- promise the operator cannot see is one they have to take on trust.
--
-- IT HAS 200 px, AND THE OBVIOUS FORM DOES NOT FIT. Measured with ui_textw against the real
-- geometry: the cell runs from ui_stat_div + 6 = 468 to ui_trig_div = 668, and
-- 'log: bytes007.txt  12345 B' is 195 px -- inside it by 5 px, which held only while byte counts
-- stayed at five digits. A SIX-digit count is 204 px and a megabyte 213 px, and the firmware fades an
-- overlong string's tail rather than clipping it, so the number goes unreadable exactly as it gets
-- interesting. One press now files up to 32 kB, so four of them cross 100 000 bytes.
--
-- Dropping the '.txt' buys the room: every byte-log name carries it, so four characters of constant
-- is the cheapest thing on the row to lose, and that leaves even 99 999 999 B fitting with 2 px spare.
--
-- THE COUNT IS NEVER WHAT GIVES WAY. If a name still does not fit -- flogpfx is settable, and a longer
-- prefix would push it out -- the NAME is trimmed from the left with a '~'. Rounding the total to kB
-- instead fails twice over: it does not fit either, since a long name overflows whatever the count says,
-- and it rounds away the one number that audits "no decoded byte is lost".
--
-- THE FAILURE CASE IS A FLAG HERE AND A SENTENCE ON THE NOTE ROW, which is the only split that fits.
-- flog_why runs to 'no free /usb1/bytesNNN.txt name' and 'cannot append to /usb1/bytes000.txt' -- 432
-- px and 302 px against this cell's 200 -- and rendering it here at all put the words that say the app
-- is DISCARDING the operator's bytes into the faded tail, which is the one thing on the row that must
-- survive. 'log: NOT LOGGING' measures 156 px, so it always fits and never needs the clip; ui_notes
-- carries the reason across the full table width, where all three reasons fit whole.
function sdec.flog_status()
  if sdec.flog_why ~= nil then return 'log: NOT LOGGING' end
  if sdec.flog_path == nil then return 'log: on first capture' end
  local base = string.gsub(tostring(sdec.flog_path), '^.*/', '')
  base = string.gsub(base, '%.txt$', '')
  local n = sdec.flog_bytes or 0
  local s = string.format('log: %s  %d B', base, n)
  -- BOUNDED BY THE NAME LENGTH, so a cell too narrow for even a 4-character name returns the overlong
  -- string rather than looping: a faded tail is bad, a hung refresh is worse.
  --
  -- THE FIRST STEP DROPS FOUR CHARACTERS, NOT ONE, because '~' costs 11 px and the character it
  -- replaces may cost 3 -- so a one-character first step can make the string WIDER, measured at 163 px
  -- going to 170 on a name of 'i's. The loop converged anyway, but a name one pixel over could be
  -- pushed eight further over before it began coming back. Four narrow characters are 12 px, which
  -- covers the '~' outright; every later step already has it and always narrows.
  local first = true
  while sdec.ui_textw(s) > sdec.ui_log_px and string.len(base) > 4 do
    if first then base = string.sub(base, 5) else base = string.sub(base, 2) end
    first = false
    s = string.format('log: ~%s  %d B', base, n)
  end
  return s
end

-- The streaming modes' status text: progress while running, then the outcome.
--
-- Separate from ui_refresh so sdec.progress() can write the SAME object with the SAME format once
-- a second without touching the other ~20: every display call is an IPC round trip to the second
-- processor, so a full refresh during a four-minute capture would spend more of the instrument on
-- saying so than on the work.
function sdec.ck_status()
  local t = sdec.ck_tot
  local md = sdec.mode_cur()
  if sdec.ck_running then
    -- A PRESS-DRIVEN RECORDING STATES ITS CONTROL AND NOTHING ELSE, because between the start
    -- press and the stop press no Lua of ours runs: nothing repaints this row, so any figure here
    -- is the one painted at the start press -- 0 % of the buffer, for the whole recording, reading
    -- as "nothing is being recorded". A percentage that can only ever be 0 is worse than none. The
    -- streaming row replaces sdec.ui_status, so the one control that works has to be said here.
    if sdec.strm_recording then return 'recording -- press Capture to stop' end
    -- WHICH WINDOW, when there is more than one. Under flow control a press is a whole
    -- transmission, so 'recording... 40 %' alone reads as one 32 kB window that is taking a very
    -- long time. The window number is what says the run is making progress through a message
    -- larger than one buffer.
    --
    -- COUNTED FROM WINDOW 1, not from window 2. fc_win is incremented after each window RETURNS, so it
    -- is 0 throughout the first one -- and a `>= 1` guard therefore suppressed the counter for exactly
    -- that window and made 'win 2/32' the first thing the operator ever saw, reading as a run that had
    -- already lost its beginning. (fc_win or 0) + 1 is the correct 1-based number from the start.
    local wtxt = ''
    if sdec.fc_out then
      wtxt = string.format(' win %d/%d', (sdec.fc_win or 0) + 1, sdec.fc_maxwin or 32)
    end
    -- TWO PHASES, and conflating them was tempting and wrong. While the digitizer fills the
    -- buffer nothing has been decoded, so a byte count would be a fiction; percent of the
    -- buffer is the honest number. Bytes only become real once the chunked decode starts.
    if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then
      local have, want = sdec.ck_acq_have or 0, sdec.ck_acq_want or 0
      local pct = 0
      if want > 0 then pct = math.floor(100 * have / want) end
      return string.format('recording...%s %d %% of the buffer', wtxt, pct)
    end
    -- THE STOP CONTROL IS NOT SAID HERE. This string shares its line with the log status and has
    -- ~58 characters before the divider; 'TRIGGER stops' would cost 13 of them at exactly the
    -- moment the byte counters matter most. Controls belong in the right-hand cell, which
    -- ui_refresh() fills with 'TRIGGER=stop' for the whole run.
    local cap = md.cap
    if cap ~= nil then
      return string.format('decoding...%s %d/%d bytes', wtxt, sdec.ck_nbytes, cap)
    end
    return string.format('decoding...%s %d bytes', wtxt, sdec.ck_nbytes)
  end
  -- SHORT, always. This row shares its line with the log status, so the left string has ~454 px
  -- before ui_stat_div; the reason a mode cannot run is a full sentence and lives on the note line
  -- instead (see ui_notes). 'not armed' here and the remedy there is one fact at two levels of
  -- detail, which is what the two rows are for.
  if t == nil then
    if sdec.mode_why(md) ~= nil then return 'not armed -- see the note' end
    -- THE MAX FOR THIS MODE, stated before the capture rather than discovered after it. Frame
    -- mode shows its window in the row above (win N, which moves with the sample rate); the
    -- streaming modes show their cap here, and 'no cap' is a real answer rather than a blank.
    if md.cap ~= nil then
      return string.format('ready -- max %d bytes, to a file', md.cap)
    end
    return 'ready -- no cap, until Stop or a quiet line'
  end
  local where = t.path or 'USB'
  local base = string.gsub(tostring(where), '^.*/', '')
  -- A MULTI-WINDOW RUN REPORTS THE TRANSMISSION, NOT ITS LAST WINDOW. ck_tot describes one window,
  -- so after a flow-controlled run of eleven windows it names the eleventh -- and '2048 bytes' under
  -- a 300 kB transmission is not a small inaccuracy, it is the wrong subject. fc_bytes is the total
  -- record_run() accumulated across every window it credited.
  if (sdec.fc_win or 0) > 1 then
    return string.format('%d bytes in %d windows -> %s  [%s]',
                         sdec.fc_bytes or 0, sdec.fc_win, base,
                         sdec.fc_end or t.stopped or 'done')
  end
  return string.format('%d bytes  %d err  %d win  -> %s  [%s]',
                       t.nf, t.nbad, t.nwin, base, t.stopped or 'done')
end

-- One settext on ONE object, called at ~1 Hz from the capture loop. Guarded, because a
-- progress update must never be able to cost the capture it is reporting on.
function sdec.progress(nbytes)
  sdec.ck_nbytes = nbytes
  return pcall(function()
    local md = sdec.mode_cur()
    sdec.ui_set(sdec.ui_page_t, string.format('%s  %s', md.name, sdec.ck_status()))
  end)
end

-- Light the segments covering the current page.
--
-- The thumb spans a proportional slice, so a single-page capture lights the whole
-- bar -- which is the useful signal that nothing is off screen. Only segments whose
-- colour actually changed are written, for the same reason ui_set exists.
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
-- Index <-> value mappings for the OBJ_EDIT_OPTION fields. getvalue() is 1-based, but each mapping
-- clamps rather than trusting that.
--
-- THE ENTRY COUNT TRAVELS WITH THE TABLE as `n`, because table.getn is unreliable on a list with
-- nil holes -- and these lists have them.
--
-- Entries 1 and 2 both mean "no forced width"; 2 additionally turns on the rare widths. Folded
-- into this field rather than given a row of its own because it IS the data-bits setting, and the
-- firmware allows up to ten options per field.
sdec.opt_bits_v  = {nil, nil, 5, 6, 7, 8, 9, n = 7}
sdec.opt_par_v   = {nil, 0, 1, 2, n = 4}             -- entry 1 = Auto
-- PROTOCOL ENTRIES, WITH THE MODULE EACH ONE NEEDS. Version 1 ships UART only; MIDI and LIN stay
-- described here so that restoring either is one line in package_tspa.py MODULES. A Protocol field
-- listing a protocol whose parser is absent would appear to work and change nothing, which is the
-- worst kind of dead control.
--
-- BARE NAMES, because the value column fades out past sdec.ui_opt_px and the detail is already on
-- screen: selecting MIDI forces 31250 8N1, which the BAUD and FORMAT cells then show.
-- 'LIN (8N1, auto baud)' would draw as 'LIN (8N1, a'.
sdec.opt_proto_all = {
  {v = 'uart', label = 'UART', need = nil},
  {v = 'midi', label = 'MIDI', need = 'mi_parse'},
  {v = 'lin',  label = 'LIN',  need = 'li_parse'},
  n = 3,
}

-- The subset this build can offer, values and labels. Computed on demand for the same
-- ordering reason as sdec.ui_view_avail(): the offline harnesses load the protocol modules
-- after serial_ui, so anything decided at load time would be wrong half the time.
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
-- The rear-BNC field's four entries, as the two booleans they stand for: {trigext, fc_out}. A
-- table rather than arithmetic on the index, so the mapping reads in both directions and a fifth
-- combination does not mean editing two sums.
sdec.opt_rear_v  = {{false, false}, {true, false}, {false, true}, {true, true}, n = 4}

-- Which Protocol entry the protocol `name` sits at, for seeding the form. A reverse lookup over
-- opt_proto_list() rather than a second hardcoded list, which would drift from the first.
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
    -- Switch away before deleting, or the firmware is left showing a screen that
    -- no longer exists.
    pcall(function()
      if sdec.ui_scr ~= nil then display.changescreen(sdec.ui_scr)
      else display.changescreen(display.SCREEN_HOME) end
    end)
  end
  sdec.del_obj(sdec.opt_proto)
  sdec.del_obj(sdec.opt_baud)
  sdec.del_obj(sdec.opt_bits)
  sdec.del_obj(sdec.opt_par)
  sdec.del_obj(sdec.opt_pol)
  sdec.del_obj(sdec.opt_trig)
  sdec.del_obj(sdec.opt_ext)
  if sdec.opt_btn ~= nil then
    local i
    for i = 1, table.getn(sdec.opt_btn) do sdec.del_obj(sdec.opt_btn[i]) end
    sdec.opt_btn = nil
  end
  sdec.del_obj(sdec.optscr)
  sdec.optscr, sdec.opt_proto, sdec.opt_baud = nil, nil, nil
  sdec.opt_bits, sdec.opt_par, sdec.opt_pol = nil, nil, nil
  sdec.opt_trig, sdec.opt_ext = nil, nil
  return true
end

-- Build the options screen, its edit fields and its four buttons. Returns the screen handle.
function sdec.build_options()
  sdec.destroy_options()
  local create = display.create
  local y0, dy, x = sdec.ui_opt_y0, sdec.ui_opt_dy, sdec.ui_opt_x
  -- ROWS ARE ALLOCATED, NOT NUMBERED. Version 1 omits the Protocol field entirely -- with
  -- only UART present there is nothing to choose between, and display.OBJ_EDIT_OPTION
  -- REFUSES fewer than two options ("OBJ_EDIT_OPTION needs at least two options"), so a
  -- one-entry field does not merely look odd, it FAILS THE BUILD.
  local row = 0
  local function nexty()
    local y = y0 + row * dy
    row = row + 1
    return y
  end

  sdec.optscr = create(display.ROOT, display.OBJ_SCREEN, 'SERIAL DECODE OPTIONS')

  -- Same silent nil as ui_build's screen, and the same reason to refuse rather than press on: an
  -- Options button that opens nothing is worse than a launch that says why it will not start.
  if sdec.optscr == nil then
    error('display object pool exhausted building the options screen -- power cycle the '
          .. 'instrument.', 0)
  end

  -- Protocol FIRST, because it overrides the fields below it: MIDI is 31250 baud 8N1 by
  -- specification, so choosing it fills in the wire parameters instead of asking for
  -- them, and switches the view to the parsed message list.
  --
  -- LIN pins 8N1 and normal polarity the same way but deliberately NOT the baud rate:
  -- LIN specifies a RANGE, 1 to 20 kBd, so there is nothing to pin and the auto-detector
  -- remains the best answer. Anyone holding the bus datasheet can still type it in.
  -- Labels come from sdec.opt_proto_list(), so a build without a protocol module does not
  -- offer it.
  --
  -- SPELLED OUT RATHER THAN unpack()'d. The instrument's Lua 5.0.2 has a global unpack(), but the
  -- offline harness runs on a modern Lua where it moved to table.unpack -- so the clever form
  -- works on the DMM and raises in every test. There are exactly three possible protocols, so a
  -- branch per count is shorter than the portability shim.
  local pv, pl = sdec.opt_proto_list()
  if pl.n >= 3 then
    sdec.opt_proto = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                            'Protocol', 'sets the wire parameters',
                            pl[1], pl[2], pl[3])
  elseif pl.n == 2 then
    sdec.opt_proto = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                            'Protocol', 'sets the wire parameters', pl[1], pl[2])
  end
  -- pl.n == 1 creates NOTHING, and sdec.opt_proto stays nil. Every reader of it already has
  -- to cope with a nil handle -- create() returns nil on refusal, which this app treats as
  -- normal -- so no caller changes. options_seed() and options_apply() are guarded below.
  -- Baud 0 means auto, hence a minimum of 0 rather than 110: a spinner that cannot
  -- express "work it out yourself" would force a guess on every capture.
  sdec.opt_baud = create(sdec.optscr, display.OBJ_EDIT_NUMBER, x, nexty(),
                         'Baud Rate', '0 = auto-detect',
                         display.NFORMAT_PREFIX, 0, 0, 1000000, 'Bd')
  -- 'Auto (7/8)' is the default and deliberately the first entry. 5, 6 and 9 data bits are
  -- excluded from the automatic search unless 'any width' is chosen, because every extra
  -- candidate format is another chance for a damaged capture to be won by the wrong one --
  -- and the rare widths lose silently, absorbing a stop bit into the data. Forcing a
  -- specific width bypasses the search entirely, so 5, 6 and 9 remain directly selectable.
  sdec.opt_bits = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                         'Data Bits', 'auto, or fix it',
                         'Auto (7/8)', 'Auto (any)', '5', '6', '7', '8', '9')
  sdec.opt_par = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                        'Parity', 'auto or fixed',
                        'Auto', 'None', 'Even', 'Odd')
  -- ELEVEN CHARACTERS IS THE FIELD'S LIMIT. An OBJ_EDIT_OPTION value longer than that is not
  -- clipped at the box edge -- the firmware FADES the tail out and stops, so 'Normal idle hi'
  -- reads 'Normal idle' and 'Trig In+FC Out' reads 'Trig In+FC', which is indistinguishable from
  -- the 'Trig In' entry above it. Measured on the panel: the value column is 146 px inside its
  -- box and the face advances ~10.6 px, so every entry below is kept to 11 characters.
  --
  -- These strings are DISPLAY ONLY. Every field maps its selection by INDEX (sdec.opt_pick and
  -- the li/ti/ri tests in options_apply), so shortening a label cannot change what it means.
  sdec.opt_pol = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                        'Polarity', 'idle level',
                        'Auto', 'Idle high', 'Idle low')
  -- NO RANGE SELECTOR. The 10 V range is the only one offered and sdec.range is fixed
  -- there, because it is also the best one: its digitize bandwidth is 440 kHz against
  -- 210 kHz on 1 V and 100 mV, and 17 kHz on 100 V and 1000 V -- and 17 kHz would cap
  -- decoding near 30 kBd while looking like a decoder fault rather than a front-end one.
  -- Nothing worth decoding swings under 1 V, and anything over 10 V wants a divider
  -- (docs/lin-divider-panel.png shows one), which is a better answer than a range that
  -- throws the bandwidth away.
  -- THREE sources here, not four, because the rear BNC moved to its own checkbox below. Two
  -- controls for one connector would have been redundant: this field picks the PRIMARY source
  -- and the checkbox adds the rear input alongside it.
  sdec.opt_trig = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                         'Trigger', 'capture start',
                         'Start bit', 'Free run', 'Trigger key')
  -- ONE FIELD FOR BOTH REAR BNCs, and the reason is height. Two orthogonal booleans (trigext and
  -- fc_out) become four entries in one field, because the form has NO ROOM for an eighth field:
  -- see the arithmetic at ui_opt_y0 -- seven fields already sit at 8 px of clearance on a pitch
  -- that is a GUESS, and an eighth would end at 410 against a button row at 366. An option field's
  -- entries cost no vertical space at all.
  --
  -- It is a fair grouping rather than a squeeze: both settings configure the REAR BNCs, one the
  -- input and one the output, and neither is a trigger SOURCE -- the field above picks the source,
  -- and this one says what the back panel does alongside it.
  --
  -- OFF BY DEFAULT, and that remains a requirement rather than a courtesy: this is a serial
  -- decoder and it must work with one probe on one line and nothing else attached. A default of
  -- anything else would make an unconnected rear connector part of the critical path -- and for
  -- FC Out it would also mean pulsing a BNC that may be wired to other bench equipment.
  sdec.opt_ext = create(sdec.optscr, display.OBJ_EDIT_OPTION, x, nexty(),
                        'Rear BNC', 'trig in / flow-control out',
                        'Off', 'Trig In', 'FC Out', 'In + FC Out')

  -- Stored, not left in locals: destroy_options() has to be able to delete them.
  --
  -- Lock Detected fills the fields above from the last capture, so an unknown line is probed once
  -- and then pinned. It does not apply or re-capture on its own -- it puts the values on screen to
  -- be looked at, and Apply is a separate press.
  sdec.opt_btn = {}
  -- Auto Detect is the INVERSE of Lock Detected and sits beside it, in the left half of this row.
  --
  -- WIDTHS SIZED TO THE LABELS. Measured on the panel, a button label needs len * 14 + 8 px of
  -- face: 'Lock Detected' is 190 px and 'Auto Detect' 162, so a uniform 150 truncates both.
  -- tools/test_serial.lua checks every button on both screens against this rule.
  --
  -- GUARDED, like ui_build's two button loops. display.create returns nil when the pool is
  -- exhausted, so setevent can be handed nil -- and this form is reached with the main screen's 9
  -- buttons already built, which is exactly the pool state where the next create is the one that
  -- fails. Unguarded, the failure is either a raise whose message names neither the pool nor the
  -- remedy, or four buttons that do nothing and say nothing.
  -- THE ROW SPANS THE SCREEN, and the widths come from the space available rather than from a MODEL
  -- (len * 14 + 8): sized to the model the labels sit nearly edge to edge inside their faces, which is
  -- legible in a screenshot and tight on the glass.
  -- 22 px margins, 12 px gaps, and the two long labels given the extra: 22 + 200 + 12 + 220 + 12 +
  -- 150 + 12 + 150 = 778, so the right margin matches the left. Every label now clears the rule that
  -- sizes it by 30 px or more: 'Lock Detected' wants 190 and has 220, 'Auto Detect' 162 in 200,
  -- 'Apply' 78 in 150, 'Cancel' 92 in 150.
  local odef = {
    {i = 4, x = 22,  w = 200, t = 'Auto Detect',   e = 'sdec.options_auto()'},
    {i = 1, x = 234, w = 220, t = 'Lock Detected', e = 'sdec.options_lock()'},
    {i = 2, x = 466, w = 150, t = 'Apply',         e = 'sdec.options_apply()'},
    {i = 3, x = 628, w = 150, t = 'Cancel',        e = 'sdec.options_cancel()'},
  }
  local ok, nob = nil, 0
  for ok = 1, table.getn(odef) do
    local od = odef[ok]
    local ob = create(sdec.optscr, display.OBJ_BUTTON, od.x, 366, od.t, od.w)
    if ob ~= nil then
      display.setevent(ob, display.EVENT_PRESS, od.e)
      sdec.opt_btn[od.i] = ob
      nob = nob + 1
    end
  end
  -- A FORM WITH NO WAY OUT IS WORSE THAN NO FORM: Cancel is one of these four, so a partial row
  -- can leave the operator on a screen they cannot leave. Refused with the same message shape
  -- ui_build uses, which names the cause and the remedy.
  if nob < table.getn(odef) then
    error(string.format('only %d of %d options buttons could be created -- display object pool '
                        .. 'exhausted. Power cycle the instrument.', nob, table.getn(odef)), 0)
  end

  -- Hook End App on THIS screen too: if the firmware delivers EVENT_ENDAPP only to
  -- the visible screen, exiting from the form would strand both screens and the
  -- buffer until a power cycle.
  pcall(function()
    display.setevent(sdec.optscr, display.EVENT_ENDAPP, 'sdec.cleanup()')
  end)
  return sdec.optscr
end

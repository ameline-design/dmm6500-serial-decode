-- serial_ui.tsp -- front-panel screens for the Keithley TSP serial decoder
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
-- THE BASE, and also the key every tool identifies the main screen by (tools/mockup.lua and
-- tools/render_png.py both match on it). The bar shown on the panel is this plus the capture mode --
-- see sdec.ui_title_text -- so those two match on the PREFIX, not the whole string.
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
-- Character advances, MEASURED, and stated here because the x positions below are sized from them:
-- FONT_SMALL is 8 px (docs/panel-ref-chrome.png, and sdec.ui_ch_w below is the same number),
-- FONT_MEDIUM ~13.4 px, from the panel screenshot where an 8-character LOGIC value spanned exactly
-- its 107 px column.
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
  -- `dy` DROPS A CELL BY N PX, and only these two carry it. FONT_MEDIUM's ink box is 17 px against
  -- FONT_SMALL's 12, and drawing both rows off one baseline sits the two big values a pixel high
  -- against the nine small ones beside them. One px down is what makes the row read as level.
  {lab = 'BAUD',   x = 8,   c = 0x00DCFF, med = true, dy = 2, wid = '115200'},
  {lab = 'FORMAT', x = 115, c = 0x00DCFF, med = true, dy = 2, labdx = -4, wid = '8N1'},
  {lab = 'IDLE',   x = 188, c = 0xFFFFFF, wid = 'HIGH'},
  {lab = 'LOGIC',  x = 241, c = 0xFFFFFF, wid = '3V3 CMOS'},
  {lab = 'THRESH', x = 334, c = 0xFFFFFF, wid = '-6.00 V'},
  {lab = 'SA/BIT', x = 417, c = 0xFFFFFF, wid = '10.42'},
  {lab = 'RATE',   x = 490, c = 0xFFFFFF, wid = '80 kS/s'},
  -- BYTES must hold SIX digits: the streaming modes report 32768 and up, which is ~48 px at
  -- this font. FIT never shows more than '1.00', so the slack it does not need lives at the
  -- right-hand end, out to the table's right rule at ui_rule_x1.
  {lab = 'BYTES',  x = 573, c = 0x80FF80, wid = '999999'},
  {lab = 'ERR',    x = 636, c = 0x80FF80, labdx = -2, wid = '999'},
  {lab = 'FIT',    x = 679, c = 0xFFFFFF, wid = '1.00'},
  -- S/N, so the value is UNSIGNED and bigger is better. The cliff is at 12 dB, measured -- see
  -- sdec.ui_sn_bad for the measurement and for the unit error that put it at 8.
  {lab = 'S/N',    x = 721, c = 0xFFFFFF, wid = '>99 dB'},
}

-- THE INK BAND OF ONE VALUE CELL, [top, bottom] inclusive, as ONE function so the panel and
-- tools/test_serial.lua cannot disagree about where a cell's glyphs land. A text object's y is the
-- BOTTOM of its glyph box and it grows upward, so the band is [y - ink + 1, y].
--
-- IT MUST ACCOUNT FOR BOTH THE FONT AND fd.dy. FONT_MEDIUM inks 17 px against FONT_SMALL's 12, so the
-- two headline cells reach 5 px HIGHER than the nine beside them: their band top is 17 where the small
-- cells' is 21, and ui_rule_hdr sits at 15. A check written against the small band alone leaves the
-- tallest cells -- the only ones that can actually reach the rule -- unguarded.
function sdec.ui_field_band(j)
  local fd = sdec.ui_fields[j]
  local y = sdec.ui_val_y + (fd.dy or 0)
  local ink = sdec.ui_ink
  if fd.med then ink = sdec.ui_ink_med end
  return y - ink + 1, y
end

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
-- THE LABEL ROW, at 66 %. Read off the instrument rather than off a render: 0x70 (44 %) is legible in
-- a screen grab and hard to read on the LCD itself, which is a 5-inch panel seen from a bench away and
-- under room light a grab does not model. The labels are static text an operator learns once, so they
-- stay dimmer than the values they head -- but not so dim they have to be hunted for.
sdec.ui_c_lab  = 0xA8A8A8                    -- the label row
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
-- S/N is the third, and its thresholds are the point of the cell.
--
-- 12 dB IS THE MEASURED CLIFF, not a margin above one. Swept offline at 9600 Bd over 12 capture
-- phases per point, injecting uniform noise as a fraction of the swing: byte-exact 12/12 at every
-- level down to 45 % of the swing, which reports 12.5 dB -- and at 50 % sig_levels REFUSES all
-- twelve. So the band boundary sits one step above a refusal, and what lies past it is 'no clear
-- logic levels' rather than a wrong answer.
--
-- THE SAME THREE dB FIGURES AT 3.3 V, 1.0 V AND 0.5 V of swing, to 0.1 dB. That is what justifies one
-- pair of thresholds for every line the app will ever see: the tolerance is a fraction of the swing,
-- so the dB at which it fails does not move with the swing.
--
-- THE 40 % NOISE TOLERANCE IS A PEAK FIGURE AND THIS CELL IS AN RMS ONE, so 20*log10(1/0.4) = 8 dB is
-- not the cliff in these units and nothing should be derived that way. gen_serial's `noise` is the
-- peak of a uniform draw, whose rms is 1/sqrt(3) of it; 40 % peak is 23 % rms, which is 12.7 dB.
sdec.ui_snfield   = 11
-- FIT bands. 0.90 is not a taste: it is sdec.autolock_fitq, the quality the app itself demands before
-- it will pin a rate, so green means "good enough to autolock". 0.72 sits 10 % above a structural
-- knee at 0.65 -- sig_fit's quality is (1 - mean_err/T) * (nfit/nsmall) and only widths within
-- 0.35*T of a multiple count, so tightness alone cannot fall below 0.65 and anything under it means
-- COVERAGE is collapsing. At 0.72 either the mean width error is a quarter of a bit time or a
-- quarter of the widths match no multiple, and both are close to losing bits.
sdec.ui_fitfield  = 10
sdec.ui_fit_good  = 0.90
sdec.ui_fit_bad   = 0.72
-- ABOVE THE MEASURED 12 dB CLIFF, NOT ON IT. Red has to mean "close to failing" rather than "failing",
-- which is only useful if it appears while the capture is still byte-exact: 15 dB is noise at ~31 % of
-- the swing, which decodes 12/12, and the cliff is at 45-50 %. Green at 30 dB is noise under ~5.5 %.
sdec.ui_sn_good   = 30       -- at or above: green
sdec.ui_sn_bad    = 15       -- below: red. Between the two: amber
sdec.ui_c_sn_ok   = 0x80FF80 -- green:  the same "all clear" green BYTES and ERR carry
sdec.ui_c_sn_warn = 0xFFFF00 -- yellow: margin, but not much
sdec.ui_c_sn_bad  = 0xFF6060 -- red:    the same red ERR goes when it has something to report
-- Rules boxing the strip into a table. Thin OBJ_RECTs, created once and never
-- touched again, so they cost nothing per refresh. A fill of 0 would paint NOTHING
-- (the firmware reads it as "unset"), hence a near-black grey.
--
-- 66 %, THE SAME AS THE LABELS, and for the same reason: on the LCD 0x80 rules read as barely-there
-- smudges where a grab shows a clean grid. Matching ui_c_lab is deliberate -- the grid and the labels
-- it separates are one piece of chrome, and two different greys there look like a rendering fault.
sdec.ui_c_rule = 0xA8A8A8
-- THE SCREEN BACKGROUND, for HIDING an object. It must not be 0: the firmware reads a fill of 0
-- as "unset" and paints NOTHING, so setfill(h, 0) is a refused write rather than a black
-- rectangle -- it climbs sdec.fillfails and leaves the object exactly as visible as before.
sdec.ui_c_hide = 0x000A0D
sdec.ui_rule_top = 1
-- BETWEEN THE LABEL INK (3..14) AND THE VALUE INK (16..32), which leaves exactly one free row.
-- A rule inside either band draws a line struck through the text, and test_serial asserts against it.
sdec.ui_rule_hdr = 15
-- 37, THREE ROWS UNDER THE VALUE INK, not one. BAUD and FORMAT carry fd.dy = 2, so their medium ink
-- reaches 34 where the rest of the row stops at 32; at 35 the rule sat one row under the two lowered
-- cells and read as underlining them.
sdec.ui_rule_mid = 37                        -- under the value ink (medium 18..34 on the dy cells)
-- 56, FIVE ROWS UNDER ui_note_y, because ui_ink MEASURES THE GLYPH BOX AND EXCLUDES DESCENDERS. The
-- note row is lower-case prose, so a 'p' or 'y' inks four rows past the nominal bottom -- measured on
-- the panel, the deepest tip is at 55 against a nominal 51. A rule placed by ui_ink alone lands inside
-- the descenders and draws through them.
sdec.ui_rule_bot = 56                        -- one clear row under the descender tip at 55
-- THE FULL WIDTH THE COORDINATE SPACE ALLOWS. Both the header strip and the status band are boxed
-- from this pair, so they end flush with each other.
--
-- 797 AND NOT 798, THOUGH 798 IS THE X LIMIT. mockup.lua's geometry check reads a rect's extent as
-- x + w, so at x1 = 798 the right-hand vertical is reported as reaching 799 and refused as off-screen.
-- That matters more than a pixel: display.create REFUSES an out-of-range object and returns NIL rather
-- than raising, so the right edge of the table would simply not be drawn, and the one-build-per-power-
-- cycle rule means nobody would find out until the panel was up.
--
-- MEASURED ON THE PANEL, the firmware inks exactly w columns from x: the horizontal rules run 1..796
-- and the 1 px vertical at 797 inks column 797 alone. So the render's arithmetic is one pixel more
-- generous than the instrument's, and 798..799 stay dark. Do not "reclaim" them on the render's word.
sdec.ui_rule_x0  = 1
sdec.ui_rule_x1  = 797
-- The note is a labelled cell in the same table, spanning the full width under the
-- field row, rather than a loose line floating beneath it.
sdec.ui_note_lab_x = 8
-- THE TRIGGER SOURCE, in the note row's left cell. The capture mode lives in the title bar, and two
-- indicators for one setting is one too many; this cell carries the thing a capture actually WAITS
-- for instead.
--
-- LABELS ARE THE OPTION FIELD'S OWN, letter for letter, and build_options() creates that field FROM
-- this table -- so the cell cannot paraphrase the control that sets it, which is the defect this app
-- keeps finding. Keys are sdec.trigmode's values (see ui_opt_trig_v).
--
-- COLOUR IS THE GLANCE CHANNEL: green is the ordinary case (wait for the line's own start bit),
-- yellow is "do not wait for anything", cyan is "waiting for a finger".
sdec.ui_trigsrc = {
  edge  = {name = 'Start bit',   c = 0x40FF40},
  free  = {name = 'Free run',    c = 0xFFFF00},
  front = {name = 'Trigger key', c = 0x00FFFF},
}
-- The TRIGGER SOURCE cell is this row's left cell, and the row's vertical rule sits at
-- ui_note_val_x - 9 = 103, which the longest label clears by 8 px.
--
-- 112, NOT 92. The cell held mode names -- 'FRAME' at 62 px was the widest -- and now holds
-- 'Trigger key' at 84, which did not fit the 75 px it had. The 20 px come off the note beside it,
-- which is ellipsised anyway; ui_note_px is DERIVED from this so the two cannot disagree.
--
-- WARNING: the panel-edge check in tools/render_png.py catches only a string that overruns 798,
-- not one that overruns an INTERIOR rule -- so a cell bounded by its neighbour has to be
-- measured against that neighbour by hand. test_serial measures every label in ui_trigsrc.
sdec.ui_note_val_x = 112
-- THE PAGE COUNTER SHARES THE NOTE ROW, ending 4 px inside the table's right rule at ui_rule_x1. It
-- sat in the right margin between the page buttons until those shrank to 'Up' and 'Dn'; the margin
-- is buttons now and nothing else.
--
-- x IS THE RIGHT EDGE of the last piece. The counter is four objects (see ui_c_pgnum) and their x
-- positions are DERIVED from measured widths in ui_pgind_layout, not written here: the two numerals
-- sit in right-aligned columns wide enough for four digits, so 'page 7 of 137' and 'page 137 of 137'
-- put their digits in the same place and nothing shuffles as the page changes.
sdec.ui_pgind_x  = 788
-- Digit columns sized for TWO digits, and a wider count OVERFLOWS LEFT INTO THE GAP rather than
-- being given a column of its own. Sizing them for the worst case (137 pages of a 32 kB hex capture,
-- more in a protocol view) renders 'page    1 of    35' -- 24 px of slack around every ordinary
-- number to hold a case almost nobody meets. Two digits puts at
-- most one digit of slack in the common case and lets three digits eat 8 px of the 6 px gap, which
-- costs a tighter line and nothing else.
sdec.ui_pgind_dig = '99'
-- Clear space between the counter's pieces, and between the counter and the note beside it. 20 px
-- for the note, not 12: 12 left an 8 px gap the note's own width model could overrun, and it did --
-- the yellow note drew over the 'p' of 'page'. ui_fit_slack is the other half of that fix.
sdec.ui_pgind_gap = 6
sdec.ui_note_gap = 20

sdec.ui_note_y   = 51
sdec.ui_row_y0   = 71                        -- first dump row
sdec.ui_row_dy   = 18                        -- row pitch (see docs/panel-ref-rows.png)
-- 15 rows x 16 bytes = 240 bytes, so a hex page holds an exact number of 16-byte rows.
--
-- A button cannot be made shorter to find vertical space for another row: display.create takes
-- (x, y, text, WIDTH) and there is no height parameter -- 58 px is the firmware's.
sdec.ui_nrow     = 15
sdec.ui_stat_y   = 344
-- THE STATUS ROW IS BOXED like the header table: it holds state about the capture rather than
-- the capture itself, and without a rule around it the two run together into one wall of small
-- grey text. The dump's last row inks up to 320 and the buttons start at 362, so the band
-- clears both.
sdec.ui_stat_top = 330   -- above the status ink (333..344)
sdec.ui_stat_bot = 349   -- below it, one clear row under the descender tip at 347
-- A divider before the right-hand cell, matching the note row's. ui_log_t starts 6 px after it.
--
-- IT CARRIES THE DUMP'S ASCII SEPARATOR WITH IT: ui_vr2_x is derived from this, so the two stay one
-- column. 472 rather than 462 because widening the offset field to five digits pushed both hex groups
-- 8 px right, and the gutter after the hex wants more than the 10 px that would have left.
sdec.ui_stat_div = 472
-- ---------- the acquire / decode progress bar ----------
-- A FIXED SLOT IN THE LEFT STATUS CELL, right of the progress text and never moved. Following the
-- text would make the bar's left edge track the digit count, so it would step sideways at 10 % and
-- again at 100 % -- movement the eye reads as the thing itself changing.
--
-- THE LEFT EDGE IS THE TEXT'S, THE RIGHT EDGE IS THE DIVIDER'S. x is MEASURED with ui_textw against
-- the WIDEST string ck_status() can return while running, which is the flow-controlled decode:
-- '32 kB  decoding... win 32/32 32768/32768', 311 px, so it ends at 319. 20 px of clear space then puts
-- the left edge at 339. test_serial recomputes the 319 from the format strings themselves, so a longer
-- message fails a test instead of being drawn through the bar.
sdec.ui_prog_x = 339
-- ---------- PINNED TO THE BOX, NOT TO NUMBERS ----------
-- Every extent below is derived from the three rules that bound the status cell -- ui_stat_top,
-- ui_stat_bot and ui_stat_div -- so moving any of them moves the bar with it. Written as literals they
-- go stale SILENTLY: the bar is invisible in frame mode, so a stale y draws a grey frame through a rule
-- only while a recording runs, which is the one state nobody is looking at the geometry in.
--
-- A RECT SPANS y..y+h-1 AND x..x+w-1, measured on a real grab rather than inferred: the divider
-- declared at (472, 330, 1, 19) inks object rows 330..348, and row 349 at that column belongs to the
-- bottom rule, which is what makes it look 20 rows tall.
--
-- ONE CLEAR ROW INSIDE EACH RULE. The band's interior is rows ui_stat_top+1 .. ui_stat_bot-1; leaving
-- the first and last of those empty puts the frame at 332..347 in a 330/349 band.
sdec.ui_prog_y = sdec.ui_stat_top + 2
sdec.ui_prog_h = sdec.ui_stat_bot - 2 - sdec.ui_prog_y + 1
-- THREE CLEAR COLUMNS BEFORE THE DIVIDER, so the frame's last column is ui_stat_div - 4.
sdec.ui_prog_w = sdec.ui_stat_div - 3 - sdec.ui_prog_x
-- THICKNESS OF THE BAR, and 10 is the firmware's CEILING -- 12 is refused with "1130 Parameter
-- thickness, expected value from 1 to 10", which raises a MODAL DIALOG over the panel.
--
-- THAT CEILING IS WHY THE TROUGH IS 2 px AND NOT 1. The frame's interior is ui_prog_h - 2 = 14 rows,
-- so a single empty row above and below the bar would need a 12 px stroke. 10 is the most the firmware
-- will take, so the 4 spare rows are split evenly instead -- even matters more than thin, because an
-- uneven trough reads as the bar sitting crookedly in its frame.
sdec.ui_prog_lw = 10
-- The bar's travel, inside the frame's 1 px border, and the row its thick line is stroked along.
--
-- MEASURED, NOT ASSUMED: a stroke of thickness lw declared at row r inks r - floor(lw/2) upward and
-- lw - 1 - floor(lw/2) downward -- on a real grab, lw = 10 at row 339 inks 334..343. So centring the
-- stroke in the interior means offsetting the interior's top by half the leftover and then by half the
-- thickness. Everything here follows ui_prog_y, ui_prog_h and ui_prog_lw, so changing the band or the
-- thickness keeps the trough even without a second edit.
sdec.ui_prog_wmax = sdec.ui_prog_w - 2
sdec.ui_prog_pad  = math.floor((sdec.ui_prog_h - 2 - sdec.ui_prog_lw) / 2)
sdec.ui_prog_ly   = sdec.ui_prog_y + 1 + sdec.ui_prog_pad + math.floor(sdec.ui_prog_lw / 2)
-- THE REAR BNC GETS ITS OWN CELL, so that what the app is writing and what its back panel is doing
-- are not two unrelated facts in one box. The log cell is 478..665, the rear BNC's 675..ui_rule_x1.
--
-- BOTH MOVED RIGHT WITH ui_stat_div, so the log cell keeps its 188 px: it needs 180 for
-- 'log: bytes007  999999 B', and its name already trims with a '~' beyond that. The rear BNC cell pays
-- for it instead, dropping from 141 px to 131.
--
-- WHICH IS WHY ITS LABELS LOST THE 'EXT '. At x = 675 the cell offers 122 px and 'EXT TRIG OUT' is
-- 123 -- one px over, and the firmware FADES an overlong string's tail rather than clipping it, so the
-- direction would have gone unreadable exactly when it was set. 'TRIG OUT' is 84 px. Nothing is lost:
-- this instrument has one external trigger connector, the direction is the fact the cell exists to
-- carry, and Options names it in full as the Rear BNC.
sdec.ui_trig_div = 666
sdec.ui_trig_x   = 675
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
-- FIVE, NOT FOUR. The offset is DECIMAL and '%04d' is a minimum width, not a maximum: a 32 kB
-- recording's last row is offset 32752, which renders five digits whatever the format string says. At
-- four the column was 32 px, a five-digit offset reached exactly 48, and rule 1 also stood at 48 -- so
-- in 32 kB mode the separator was drawn through the offset text. Five keeps the same 8 px of clearance
-- a four-digit offset had, and every column right of it derives from this one number.
sdec.ui_ixn      = 5                         -- offset field, '%04d', five digits past 9999
-- Hex block width, DERIVED rather than written. Changing the grouping has to move the ASCII
-- column and the vertical rule with it, and a literal here would not.
sdec.ui_hxn      = sdec.ua_hexwidth(8)      -- ONE group of 8 bytes: 8*3 - 1 = 23 chars
sdec.ui_col_gap2 = 12                       -- clear space BETWEEN the two hex groups
sdec.ui_asn      = 16                        -- ASCII block, one char per byte

sdec.ui_col_ix   = sdec.ui_x
-- WIDER THAN ui_col_gap, AND THE SAME ON BOTH SIDES OF RULE 1. The offset is metadata and painted dim,
-- so pushing the data away from it makes the separation structural rather than only tonal -- that much
-- was already true when the gap ran 8 px before the rule and 16 after. Using one constant for both
-- centres the rule in its own clear space instead, which is what the eye reads as a column boundary.
-- The hex columns do not move: 8 + 5*8 + 12 puts the rule at 60 and the hex still starts at 72.
sdec.ui_ix_gap   = 12
sdec.ui_vr1_x    = sdec.ui_col_ix + sdec.ui_ixn * sdec.ui_ch_w + sdec.ui_ix_gap
sdec.ui_col_hx   = sdec.ui_vr1_x + sdec.ui_ix_gap
-- The second group of eight, at a FIXED x one group plus a gap along. The proportional font makes
-- the first group's rendered width depend on which digits it holds, so a second group positioned
-- by string content would drift row to row.
sdec.ui_col_hx2  = sdec.ui_col_hx + sdec.ui_hxn * sdec.ui_ch_w + sdec.ui_col_gap2
-- ALIGNED WITH THE STATUS BAND'S DIVIDER, the rule left of 'log:', because the two are stacked in the
-- same column of the screen and 10 px of disagreement between them read as a mistake. TAKEN FROM
-- ui_stat_div rather than set to 462 beside it: two literals that must be equal are two literals that
-- will eventually differ, and this one is only checkable by eye on the panel.
--
-- The cost is paid in the GUTTER AFTER THE HEX, which widens from 8 px to 18: the second group of
-- eight ends at 444 and the rule now stands at 462. The ASCII block moves right with it and still ends
-- at 598, well clear of the position bar at ui_sb_x. test_serial pins both bounds, because a future
-- ui_stat_div moved left would otherwise walk this rule into the hex digits.
sdec.ui_vr2_x    = sdec.ui_stat_div
-- WIDER THAN ui_col_gap, and the rule does NOT move with it: rule 2 stays on ui_stat_div, which is what
-- keeps it aligned with the divider left of 'log:' in the band below. This gap only pushes the
-- characters off the line, so the ASCII block reads as its own column rather than as text hung on a
-- boundary. It costs nothing downstream -- the gutter after it is empty to the position bar.
sdec.ui_as_gap   = 16
sdec.ui_col_as   = sdec.ui_vr2_x + sdec.ui_as_gap
sdec.ui_vr3_x    = sdec.ui_col_as + sdec.ui_asn * sdec.ui_ch_w + sdec.ui_col_gap
-- The vertical rules span the dump block: from the row of the note row's own bottom rule down to the
-- status band's top rule, so the column separators MEET both lines instead of stopping in mid-air.
--
-- BOTH ENDS ARE DERIVED FROM THE RULES THEY TOUCH, never from the row grid. Anchored on the grid the
-- bottom ended at the last row's baseline, 8 px short, and the top sat at ui_row_y0 - ui_ink, which
-- left a 2 px gap under ui_rule_bot -- close enough to read as a rendering fault rather than a
-- boundary. A grid anchor also silently reopens the gap the moment the row pitch or the ink height
-- changes, because neither of those has anything to do with where the rule above is. Moving the note
-- row or the status band now moves these with them, and there is no text in either gap for them to
-- strike through.
sdec.ui_vr_y0    = sdec.ui_rule_bot + 1
sdec.ui_vr_y1    = sdec.ui_stat_top

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
-- THE TITLE BAR CARRIES THE MODE TOO, as 'SERIAL DECODE - <title>'. The mode already has two
-- indicators -- the MODE cell's colour and the status row's words -- and both are small text in a
-- dense panel; the title bar is the largest type on the screen and was saying nothing that changes.
--
-- `title` IS NOT `name`. The cell wants the shortest thing that fits a 92 px column ('8 kB'); the
-- title bar has room for the whole idea, and '8K CAPTURE' says what '8 kB' leaves to be inferred.
-- Longest is 'SERIAL DECODE - 32K CAPTURE' at 27 characters, inside the firmware's 31-character
-- screen-title limit (over it is error 1707, and the title is silently truncated).
sdec.ui_modes = {
  {id = 'frame', name = 'FRAME',  cap = nil,   log = true, view = true, title = '240B FRAME',
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
  {id = 'sml',   name = '8 kB',   cap = 8192,  log = true, view = false, title = '8K CAPTURE',
   needbaud = true, idlexit = true, c = 0x40C0FF,
   desc = 'shorter capture window -- quicker to bytes, more credits'},
  {id = 'med',   name = '32 kB',  cap = 32768, log = true, view = false, title = '32K CAPTURE',
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

-- HOW OFTEN THE PANEL LOOKS FOR A KEY, in seconds. 2 Hz: a key pulled or inserted shows on the panel
-- within half a second, which is below the threshold at which an operator wonders whether it worked.
--
-- THE COST IS ONE PRESENCE READ PER TICK and nothing else unless the answer changed. Measured on
-- 1.7.17a over 200 calls each, with a key in the slot:
--
--     file.usbdriveexists()   237 us
--     ui_usb_btns()           297 us      the read, plus the change test
--     ui_tick()               340 us      measured whole, NOT summed from the parts above
--
-- So 2 Hz is 0.07 % of the instrument. Fractional intervals are honoured by display.OBJ_TIMER
-- (measured; the firmware's own clock sample happens to use 1).
--
-- DO NOT RAISE THIS RATE TO MAKE A KEY APPEAR SOONER. It will not work, and the reason is the
-- firmware rather than the clock. Observed on the panel: pulling the key hides the buttons AT ONCE,
-- every time, while an insertion takes about 2 s to bring them back -- and the 2 s is there whether
-- or not a button is pressed in the meantime. Both directions run this same code, so a difference
-- between them cannot be ours: it is file.usbdriveexists() answering 0 until the key is mounted.
-- 2 Hz already samples far faster than that signal moves, and a press asks the same question
-- sooner still. tools/probe_keylatency.py holds the measurements, and the two ways of taking them
-- that cost a sluggish panel and an instrument power cycle.
--
-- MEASURE ui_tick ITSELF, NOT ITS PARTS, and know which tree answered. A tick that also calls
-- ulog.resume() costs 629 us against the 340 here, which is the whole reason it does not. And a
-- load that fails silently leaves the PREVIOUS app running while answering every query cheerfully,
-- so a figure can belong to a tree that is not on disk -- check a function you have just added
-- before trusting a number. See tools/dmmrun.py's load_script.
--
-- 237 us IS WITH A KEY PRESENT, which is the case every per-line and per-row gate in this app
-- pays. The 111 us quoted for this call elsewhere was taken with the slot EMPTY -- a different
-- measurement, not a disagreement with this one. Why the empty slot is cheaper is a guess and is
-- not worth one: the expensive case is the only one that runs.
sdec.ui_tick_s = sdec.ui_tick_s or 0.5

-- Stop and start the tick around work that will hold the interpreter. -> true if it acted.
--
-- WHY NOT JUST THE BUSY TEST IN ui_tick(). A tick is dispatched like a press, so a run that holds
-- the interpreter does not suppress ticks -- it defers them. Measured: a 10 s busy hold releases 2,
-- so the backlog is shallow rather than one per second. The busy test already makes each one cheap;
-- this is what stops them arriving at all while a capture owns the panel.
--
-- CLEARING THE HANDLER IS THE OFF SWITCH, and nothing else is. Measured on 1.7.17a against a 1 s
-- timer, counting handler calls over 4 s of idle:
--
--     enabled                        4
--     display.STATE_INVISIBLE        4     <- an invisible timer STILL FIRES
--     handler set to ''              0
--     handler restored               4
--     another screen in front        0     <- the firmware's own HOME screen, which is what was tested
--
-- So the state call every other control on this panel uses does not work here: clearing the handler
-- is the only off switch.
--
-- THE LAST ROW DOES NOT COVER THE OPTIONS FORM, and reading it as though it did cost bench time. It
-- was taken with the firmware's HOME screen in front -- the app BACKGROUNDED -- and sdec.optscr is a
-- sibling screen of our own with the app still foreground, which is a different case and was never
-- measured. Observed on the panel with the form up: the edit fields need several presses over 5-10 s
-- to open, intermittently, while the four buttons stay responsive -- which is what a 2 Hz poll
-- competing with a modal editor looks like, and is not what a stopped timer looks like.
--
-- So sdec.options() now calls ui_tick_off() explicitly and every exit re-arms. That is correct
-- whichever way the firmware behaves: if a sibling screen does stop the timer, these calls are a
-- no-op, and if it does not, they are the fix. Do not remove them on the strength of the row above.
--
-- IDEMPOTENT AND GUARDED. Both are reached from teardown paths that can run twice and from inside
-- pcall'd handlers, and a build whose timer create failed leaves ui_tick_obj nil.
function sdec.ui_tick_off()
  if sdec.ui_tick_obj == nil then return false end
  return pcall(display.setevent, sdec.ui_tick_obj, display.EVENT_PRESS, '')
end

function sdec.ui_tick_on()
  if sdec.ui_tick_obj == nil then return false end
  return pcall(display.setevent, sdec.ui_tick_obj, display.EVENT_PRESS, 'sdec.guard(sdec.ui_tick)')
end

-- Look for a key that has come or gone, and make the panel agree. -> true if anything moved.
--
-- THE SHARED BODY OF THE TICK AND OF THE THREE PRESSES THAT WANT AN ANSWER NOW. The tick is the
-- unattended route and this is the deliberate one: Capture, View and Mode each call it as their
-- first act, so the key state a press acts on is the key state at the press, asked for rather than
-- inherited from whenever the last tick happened to land.
--
-- WHAT IT IS AND IS NOT WORTH. It is NOT a fix for a visible defect -- checked OFFLINE against the
-- mocked instrument on the tree before it, with a key re-inserted and the acquisition stubbed, a
-- Capture press already reached the work with the log re-opened and both buttons back, because
-- capture_run() opens with ulog.resume() and every path refreshes before its long work. What this
-- buys is that the property stops being INCIDENTAL: it holds because each handler asks, not because
-- of where resume() happens to sit in a function none of them can see. flog_alloc() asks
-- ulog.keyok() for itself for exactly that reason, and its docblock records what it cost to learn.
-- View and Mode additionally gain the window between the press and their own trailing ui_refresh().
--
-- IT DOES NOT RE-OPEN THE LOG, AND MUST NOT. ulog.resume() allows ONE open attempt per insertion and
-- a failed one is not retried until another key arrives (its docblock says so, and names a slot that
-- reports a key before its filesystem is usable as the case). Calling it from here spends that single
-- allowance within half a second of insertion -- the moment it is LEAST likely to succeed -- where a
-- press arrives seconds later, at human speed. Trading a sooner re-open for a chance of
-- 'log: NOT LOGGING' standing for the rest of the session with a good key in the slot is the wrong
-- side of that bargain. capture_run() resumes, and ulog.line() resumes by itself, so every path that
-- writes to the key already recovers; this one only has to make the PANEL agree.
--
-- EVERYTHING EXPENSIVE IS BEHIND A CHANGE TEST. The repaint runs only when the answer differs from
-- the last one, so a steady state is one presence read and nothing else: measured over 200 calls
-- with a key in the slot, ui_usb_btns() 297 us and a whole tick 340 us, i.e. 0.07 % at 2 Hz.
--
-- GUARDED: a raise escaping here reaches the firmware, which then posts it twice a second.
function sdec.ui_keypoll()
  if sdec.ui_scr == nil then return false end
  local moved = false
  pcall(function()
    -- ONE PRESENCE DECISION, AND IT BELONGS TO ONE OWNER. ui_usb_btns() asks log_live() and caches
    -- the answer in ui_savevis; a second cache here would go stale the moment a repaint from
    -- anywhere else moved that flag, and this would then sit on its own opinion for ever.
    --
    -- THE BUTTONS MOVE IN EVERY STATE, including during a run: Save and NewLog cannot work without a
    -- key whatever else is happening, and ui_refresh() hides them mid-run for the same reason.
    if not sdec.ui_usb_btns() then return end
    moved = true
    -- THE LOG CELL IS ONLY OURS WHEN NO RUN OWNS IT. While a recording or a chunked decode is live
    -- that cell carries the only statement of how to STOP, and writing the log status over it is
    -- wrong whoever does it: one display object, one writer.
    --
    -- THE WINDOW IS SHORT, AND SAYING SO IS THE HONEST VERSION. The tick cannot get here mid-run --
    -- ui_tick() refuses outright on busy/ck_running/strm_recording -- and every press that CAN
    -- (capture_run's stop branch, mode_cycle's running branch, view_toggle) ends in ui_refresh(),
    -- which puts the hint back. So without this test the stop instruction is lost only for the
    -- duration of the handler that is already stopping or stepping the run, not indefinitely. It is
    -- still the wrong thing to write, and ui_log_owned() is one compare.
    if sdec.ui_log_owned() then return end
    -- The log cell names the key too, so it moves with the buttons.
    sdec.ui_set(sdec.ui_log_t, sdec.flog_status())
  end)
  return moved
end

-- Is the status row's right-hand cell currently a run's, rather than the log's? -> true or false.
--
-- MUST TRACK ui_refresh()'s BRANCH FOR THAT CELL: the tests below are that branch's outer condition
-- followed by its three hint cases. They are stated here rather than only there because
-- ui_keypoll() writes the same object from a press and has to know whose it is.
-- tools/test_streamfix.lua walks eleven states and asserts the two agree in each, rather than
-- leaving them to be kept in step by hand: two opinions about one display object is a defect this
-- panel is prone to, which is why ui_usb_btns() keeps the ui_savevis cache under one owner.
--
-- GUARDED AGAINST A nil MODE, which is what an EMPTY sdec.ui_modes gives -- an absent one raises
-- inside mode_cur() instead, and ui_refresh has no guard either, so that state is nobody's contract.
function sdec.ui_log_owned()
  local md = sdec.mode_cur()
  if md == nil then return false end
  -- THE NEGATION OF ui_refresh's TEST FOR THE LOG CELL, which is the one guarding the four-way
  -- block that writes sdec.ui_log_t -- NOT the similarly-shaped test further up that chooses the
  -- status row's LEFT cell. Both read this same md, and both spell this condition, so the one to
  -- follow is the one whose branch sets ui_log_t. Without this line, strm_inflight on its own would
  -- claim a hint that ui_refresh never writes.
  if md.view and sdec.ck_tot == nil and not sdec.ck_running then return false end
  if sdec.strm_recording then return true end
  if sdec.ck_job ~= nil then return true end
  if sdec.ck_running or sdec.strm_inflight then return true end
  return false
end

-- One tick of sdec.ui_tick_obj: the unattended half of ui_keypoll().
--
-- IT MUST NOT ACT WHILE THE APP IS BUSY. A tick is dispatched exactly like a press, so it queues
-- behind a capture and arrives in a burst afterwards -- and a repaint from inside one would fight
-- the capture for the same objects. The busy test makes a queued tick a no-op; the next tick, one
-- half-second later, does the work. The PRESS route has no such test and needs none: a handler
-- executing at all proves no run is.
function sdec.ui_tick()
  if sdec.ui_scr == nil then return false end
  if sdec.busy or sdec.ck_running or sdec.strm_recording then return false end
  return sdec.ui_keypoll()
end

-- Will anything the app writes reach the key? -> true or false.
--
-- Asked BEFORE a capture, so it cannot read sdec.flog_why -- that is set by the attempt. keyok()
-- names no path and posts no event, which is what makes it askable here; unknown counts as yes, so
-- a build or firmware without the call keeps the key-present wording.
function sdec.log_live()
  local live = true
  if ulog ~= nil and ulog.keyok ~= nil then
    live = ulog.keyok()
  end
  return live
end

-- Whether mode `m` suits the current rate. Always true: the TWO recording sizes differ only in
-- byte ceiling, so any rate one can run the other can, and it suits
-- every rate it can run at. A rate too fast to stream is refused by mode_why(), which carries a
-- reason to the panel; this exists because the panel and the harnesses call it.
function sdec.mode_suits(m)
  return true
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
  -- bit in theory gives less in fact, and above 165563 Bd no listed rate closes the gap. Refused
  -- with the number rather than run at 2.6 samples/bit while claiming 4 -- see fs_for_burst().
  if m.needbaud and sdec.force_baud ~= nil and sdec.force_baud > 0 and
     sdec.fs_for_burst ~= nil and sdec.fs_for_burst(sdec.force_baud) == nil then
    -- NAME THE RECORDING'S OWN FIGURE, or this note contradicts the header beside it. At 192024 Bd
    -- the SA/BIT cell reads 5.2 -- true, and measured from a FRAME capture, which gets very nearly
    -- the 1 MS/s it asks for -- while this said "no sample rate delivers 4 samples/bit". Both are
    -- right and together they read as a bug: a recording's burst acquisition loses acq_overhead per
    -- sample, so the same 1 MS/s request delivers 662 kS/s and only 3.4 samples/bit. The two cells
    -- read as a contradiction to anyone holding them side by side.
    local dl = nil
    if sdec.rates ~= nil and sdec.fs_delivered ~= nil then
      dl = sdec.fs_delivered(sdec.rates[table.getn(sdec.rates)])
    end
    -- %.0f, NOT %d, FOR THE RATE. force_baud carries a MEASURED rate whenever autolock set it, and a
    -- measurement is fractional -- 153588.155 has been on this panel. Lua 5.0.2 truncates such a value
    -- silently, so the instrument renders the same characters either way, but 5.4 raises on it: the
    -- hazard is that no offline test can enter this branch, which is how it stayed uncovered.
    if dl ~= nil and dl > 0 then
      return string.format('%.0f Bd: a recording gets %.1f samples/bit, under the %d floor -- '
                           .. 'use FRAME', sdec.force_baud or 0, dl / sdec.force_baud, sdec.minsabit or 0)
    end
    return string.format('%.0f Bd is too fast to stream -- no sample rate delivers %d ' ..
                         'samples/bit; use FRAME', sdec.force_baud or 0, sdec.minsabit or 0)
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

-- The title bar's text: the app's name and the capture mode, in the largest type on the screen.
--
-- BOUNDED AT 31 CHARACTERS, which is the firmware's screen-title limit -- over it raises 1707 and the
-- title is truncated without a word. The longest form is 'SERIAL DECODE - 32K CAPTURE' at 27, so the
-- clamp never fires today; it is here because `title` is data and a longer entry must degrade rather
-- than raise. tools/mock_display.lua enforces the same limit, so an over-long one fails a test.
function sdec.ui_title_text()
  local md = sdec.mode_cur()
  local s = sdec.ui_title
  if md ~= nil and md.title ~= nil then s = s .. ' - ' .. md.title end
  if string.len(s) > 31 then s = string.sub(s, 1, 31) end
  return s
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
  -- CHECKED LAZILY, not by pruning ui_views at load time: the app loads serial_ui AFTER the protocol
  -- modules but the offline harnesses load them in the other order, so a load-time prune drops MIDI
  -- from a full build depending only on who loaded what first.
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
-- THE PAGE COUNTER, on the note row, IN TWO INTENSITIES. The two numbers are what the operator
-- reads; 'page' and 'of' are scaffolding that says what they mean, and dimming them puts the
-- numerals a clear step in front rather than in a row of identical grey.
--
-- IT IS WHY THE COUNTER IS FOUR DISPLAY OBJECTS AND NOT ONE. A text object carries ONE colour, so
-- two intensities in one line is two objects minimum and four once the words are not adjacent.
sdec.ui_c_pgnum  = 0xFFFFFF    -- the numerals: 100 %
sdec.ui_c_pgword = 0xA8A8A8    -- 'page' and 'of': 66 %
-- THE PROGRESS BAR. Full-intensity cyan for the filled part, and an 80 % grey box around the whole
-- extent so that what is LEFT is as visible as what is done -- a bare bar shows only the fraction
-- already spent and leaves the denominator to be guessed.
sdec.ui_c_prog     = 0x00FFFF
sdec.ui_c_prog_box = 0xCCCCCC
-- THE REAR BNC's THREE STATES. Its cell is EMPTY when the connector is off -- a marker that is always
-- present is not a marker, and a permanent amber 'EXT TRIG' over an Options page saying the rear BNC
-- is off is the panel asserting hardware that is not in use.
sdec.ui_c_extin  = 0x40FF40   -- green: an input, armed
sdec.ui_c_extout = 0xFFC000   -- amber: an output, pulsing a credit per capture
sdec.ui_c_extio  = 0x00FFFF   -- cyan:  both directions live

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
-- HAS THE OPERATOR PAGED YET. The page counter stays off the note row until they have: on a
-- single-page capture it would say 'page 1 of 1', and a note is worth more than that. Latched, not
-- momentary -- someone who pages once wants the counter for the rest of the session.
--
-- `or false` like every other piece of operator state: opening the installed App re-runs this file,
-- and a plain assignment would forget it.
sdec.ui_paged = sdec.ui_paged or false
sdec.ui_status = sdec.ui_status or 'ready'
-- sdec.ui_last   -- last text written per handle, to skip redundant settext

-- SAY THE PANEL IS WAITING ON PURPOSE, called by acq_triggered() immediately before it blocks on an
-- arm-from-silence. Installed HERE rather than in the core because it is the only place that knows
-- the panel exists: the offline harnesses install no armnote and so behave exactly as before.
--
-- WHY IT IS WORTH A HOOK AT ALL. The wait can be 120 s and nothing can interrupt it -- a touch press
-- only queues -- so without this the operator sees a dead panel for two minutes and no reason for
-- it, which is indistinguishable from the fault V1.40 was released to fix. One settext before the
-- block is the whole remedy, and it is correct for the entire wait because nothing below repaints.
--
-- THE TRIGGER KEY IS NAMED because it genuinely works here, unlike the cancel latch: the key is a
-- stimulus of the trigger MODEL, which runs in firmware, so it fires while Lua spins. That is the
-- same mechanism 'front' mode has always used.
function sdec.armnote(wait, level, keyed)
  -- ui_log_t, THE RIGHT-HAND CELL, because that is already where this panel puts what the operator
  -- can DO about a long operation -- it carries 'Capture or Mode = Stop' and 'no stop until it ends'
  -- for exactly the same reason. The left cell is a composite of mode, page and byte range built by
  -- ui_refresh_do(), and overwriting it here would drop all of that to say one thing.
  --
  -- sdec.ui_status IS DELIBERATELY NOT TOUCHED. It is a mode WORD -- 'ready', 'decoding...' -- read
  -- into the left cell and asserted against elsewhere; borrowing it for a sentence would leak into
  -- the next refresh and into the panel's own self-consistency checks.
  --
  -- ONE CELL, NOT ui_refresh(). A full refresh rebuilds every cell from state that is mid-capture
  -- here, with clear_result() having already zeroed the decode, so it would paint blanks over the
  -- previous result. One cell has news; one cell is written.
  --
  -- THROUGH ui_set, WHICH IS WHAT MAKES THE NOTE TEMPORARY. ui_set keeps the last text written per
  -- handle and skips a rewrite that would not change anything; a bare settext leaves that cache
  -- holding whatever the previous refresh put there. So the next refresh after a failed arm saw its
  -- own stale entry, decided the cell already said the right thing, and the wait note STUCK on the
  -- panel for the rest of the session -- the exact inverse of a note that exists to say "right now".
  -- AND IT ONLY PROMISES THE KEY WHEN THE KEY IS ACTUALLY WIRED IN. `keyed` is sdec.armkeyed, which
  -- arm_source() sets only where the TRIGGER key really was blended into the arm -- and there are
  -- three live cases where it was not: Arm key off, a firmware whose blender refuses, and an anchored
  -- rear-BNC capture. Printed unconditionally, this cell told the operator their one escape worked at
  -- the exact moment it did not, for up to two minutes. Nothing in tsp/ read armkeyed before this.
  if sdec.ui_log_t == nil then return false end
  local tail = ''
  if keyed then tail = ' -- TRIGGER=go' end
  return sdec.ui_set(sdec.ui_log_t,
                     string.format('waiting %.0fs for %.2fV%s', wait or 0, level or 0, tail))
end

-- ---------- options form handles ----------
-- sdec.optscr, sdec.opt_proto, sdec.opt_baud, sdec.opt_bits, sdec.opt_par,
-- sdec.opt_pol, sdec.opt_trig, sdec.opt_ext, sdec.opt_armv, sdec.opt_armw
-- -- declared, not assigned
--
-- EIGHT FIELDS, NINE WITH A PROTOCOL MODULE, AND THIS IS THE RISKIEST GEOMETRY IN THE APP.
--
-- THE EDIT-OBJECT HEIGHT IS MEASURED, not guessed. Off docs/img/options.png: a field created at y
-- draws its box from y + 4 to y + 53, so it is 50 px tall -- and the options button row starts at 367
-- and is 60 px, not the 58 the main screen's arithmetic assumes.
--
-- WHICH IS WHY THE PITCH IS NOT DERIVED FROM A GUESS. On a 38 px height, seven fields at dy = 52 end
-- at 358 with 8 px clear. At the measured 50 they end at 373 -- 6 px INSIDE the button
-- row. V1 ships six fields (no Protocol: with only UART there is nothing to choose between, and
-- OBJ_EDIT_OPTION refuses fewer than two options), so nothing collides today, but a build that
-- restores MIDI and LIN brings the seventh field back and it does not fit at this pitch.
--
--     fields  y0  dy   last box bottom   buttons at 367
--        6     8  52        321            46 px clear
--        6     8  54        331            36 px clear   <- shipped
--        6     8  61        366            1 px clear, the ceiling
--        7     8  52        373            COLLIDES by 6
--        7     8  50        361            fits, 6 px clear
--
-- 54, NOT 52: the gap between boxes was 2 px, which reads as one crowded block rather than six
-- controls, and 54 makes it 4. The ceiling is 61 and test_serial checks the last box against the
-- button row, so going further fails a test rather than the panel.
--
-- The remedy if a seventh field ever returns is to fold its control into another field as an extra
-- option entry, which costs no vertical space at all -- the firmware allows ten options per field.
sdec.ui_opt_y0 = 8
-- THE PITCH ASKS FOR EVERY PIXEL AVAILABLE, and the clamp in build_options() decides what that is.
--
-- WHY A GAP IS A TOUCH TARGET AND NOT DECORATION. An edit box is ui_opt_edit_h = 50 px tall and the
-- pitch is the distance between consecutive boxes, so the gap is dy - 50. At the shipped 54 that was
-- FOUR pixels, and a 7-field build clamps to 50 and gets NONE -- the boxes then share an edge, where
-- which object receives a touch is the firmware's hit-test order rather than the operator's aim.
--
-- Reported from the bench: the fields need several presses over 5-10 s to open, intermittently,
-- while the four buttons -- a row with nothing above or below them -- stay responsive, and the LAST
-- field, the only one with no neighbour beneath it, is responsive too. That is the signature of an
-- ambiguous boundary, not of a busy interpreter.
--
-- 100 IS A REQUEST, NOT A LAYOUT, and the clamp in build_options() decides what it gets. The second
-- column is what makes a number this large affordable: six fields are THREE rows, so the span is cut
-- by two gaps rather than five.
--
--     6 fields, 2 cols -> 3 rows, pitch 100, gap 50 px
--     7 fields, 2 cols -> 4 rows, clamped to 99, gap 49 px
--
-- against the 4 px a single column of six had and the 0 px a single column of seven had. A 50 px gap
-- between 50 px boxes means half the form is dead space, which is the point: a touch has to be able
-- to miss by 20 px and still land in the field the operator aimed at.
--
-- THE CEILING IS THE BUTTON ROW, so raising this further buys nothing -- the clamp already hands
-- over every pixel between y0 and the buttons. Moving the BUTTONS down is what it would cost, and
-- that comes out of the bottom margin: a button is 60 px tall against a 431 px content area, so 366
-- already leaves 5 px and reads as clipped. See ui_opt_btn_y.
sdec.ui_opt_dy = 100
-- MEASURED, and the offset of the box inside the object. Both are what test_serial checks the last
-- field against; the mock carries the same height so an overflow fails offline.
sdec.ui_opt_edit_h  = 50
sdec.ui_opt_edit_dy = 4
-- THE OPTIONS BUTTON ROW, 360 and not 366. A button is 60 px tall on this panel, not the 58 the main
-- screen's arithmetic assumes -- measured off docs/img/options.png with the rest of this geometry --
-- so at 366 the row occupies 367..426 of a 431 px content area, and 5 px from the bottom edge reads
-- as clipped. 360 gives 11 px, matching the main screen's row, and still leaves 29 px under the last
-- field. build_options() takes the row's y FROM HERE rather than repeating the number.
sdec.ui_opt_btn_y   = 360
-- AND THE CLAMP KEEPS THIS MUCH OF IT BACK, because handing over every pixel between y0 and the
-- buttons is what put the bottom field 1 px off the row. The clamp's job is to stop a field
-- OVERLAPPING the buttons; it is not a reason to leave them touching. Reported from the glass: the
-- bottom field of each column reads as sitting on the button row.
--
-- WHAT IT COSTS IS AIR BETWEEN THE BOXES, and that is the right trade only because there is plenty.
-- A 9-field build goes from a 24 px gap with 5 px of clearance to an 18 px gap with 20, and 18 px is
-- still four times the 4 px that made the fields unresponsive to touch. A build that cannot afford it
-- is caught by the dy < eh branch below, which moves the whole column up instead.
sdec.ui_opt_btn_gap = 24
sdec.ui_opt_x  = 185   -- the label is RIGHT-ALIGNED and ends here, so this is its width
-- TWO COLUMNS. Six fields become three and three, which is what buys the vertical gap: three rows
-- in the space six used to share, so the pitch clears the 50 px box with room to spare instead of
-- the 4 px it had.
--
-- THE SECOND COLUMN'S x IS THE ONE NUMBER TO CHECK ON THE GLASS. display.create takes NO width for
-- an OBJ_EDIT_* -- confirmed against the display reference, where the signature is
-- (parent, kind, x, y, label, help) -- so the firmware sizes the widget itself and we place only
-- the origin. The reference's own example puts an OBJ_EDIT_NUMBER at x = 400 and an OBJ_EDIT_CHECK
-- at x = 200 on the same row, so the widget is narrower than half the screen and two columns are
-- possible; what it is NOT is measured here. 670 mirrors column one's 270 about the midpoint
-- (270 + 400), keeping both label runs the same width.
-- HOW FAR THE CENTRED BLOCK IS NUDGED, negative being up. See the application site.
sdec.ui_opt_y_adj = -8
sdec.ui_opt_cols = 2
sdec.ui_opt_x_c2 = 552
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
  local ok = pcall(display.settext, h, txt)
  if ok then sdec.ui_last[h] = txt end
  return ok
end

-- Set an object's colour, tolerating a handle the build never created.
function sdec.ui_color(h, c)
  if h == nil then return false end
  -- Guarded: setcolor is known to fail on Image objects (error 1717) and has not
  -- been confirmed on text. If it does not apply, rows stay white and the summary's
  -- error counts still report the damage.
  return (pcall(display.setcolor, h, c))
end

-- Delete object `h`, counting a refusal rather than assuming it worked. Returns whether it went.
function sdec.del_obj(h)
  if h == nil then return true end
  local ok = pcall(display.delete, h)
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
    local ok = pcall(display.delete, o[i])
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
-- AN OBJ_RECT IS NOTHING BUT ITS BORDER, AND display.setfill DOES NOTHING TO IT. Measured on the
-- panel: a 64 x 14 rect at setfill(100) lights 137 px -- its perimeter -- and not the 896 a filled
-- one would. So every rect this app draws is a hollow box, and the table rules only look solid
-- because they are 1 px wide, where the border IS the rect.
--
-- WHICH MAKES ui_fill_solid INERT. It is kept because it costs one call at build time, it is the
-- right thing to say if a later firmware honours the percentage, and its refusal counter is what
-- would say so. Anything that must actually be solid uses geometry instead: 1 px, or an OBJ_LINE
-- with a thickness (see ui_progbar_set).
--
-- IT ALSO MEANS A RECT CANNOT BE HIDDEN BY COLOUR beyond 1 px -- see sdec.ui_setstate.
function sdec.ui_fill(h, c)
  if h == nil then return false end
  local ok = pcall(display.setcolor, h, c)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Make a rect actually paint: 100 % foreground. Called once per rect at build time; the
-- position bar is the one object that varies its fill afterwards, and it calls setfill itself.
function sdec.ui_fill_solid(h)
  if h == nil then return false end
  local ok = pcall(display.setfill, h, 100)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Show or hide object `h`. THE ONLY WAY TO TAKE A RECT OR A LINE OFF THE GLASS: recolouring one to
-- ui_c_hide does NOT hide it. That works for the dump rules only because they are 1 px wide, where a
-- background-coloured pixel IS the background -- a 64 x 14 frame painted 0x000A0D stays plainly
-- visible on the panel with its own fillfails counter reading 0.
--
-- The reference lists OBJ_RECT and OBJ_LINE among setstate's allowable types, and both are confirmed
-- on the instrument. Counted in fillfails on refusal like every other display write.
function sdec.ui_setstate(h, st)
  if h == nil then return false end
  local ok = pcall(display.setstate, h, st)
  if not ok then sdec.fillfails = (sdec.fillfails or 0) + 1 end
  return ok
end

-- Paint the acquire/decode bar at `pct` (0..100), or HIDE it when pct is nil -- which is what every
-- state with no honest fraction passes. See sdec.ck_pct for which those are.
--
-- THREE VISUAL STATES, and nil is not 0:
--   nil   gone. Frame and bar both STATE_INVISIBLE.
--   0     the grey frame alone: a run has started and has nothing to show yet.
--   > 0   the frame plus a cyan bar out to pct.
--
-- THE BAR IS A THICK LINE AND THE FRAME IS A RECT, and that split is forced by what this firmware
-- actually draws, measured on the instrument:
--
--   * an OBJ_RECT is drawn as an OUTLINE `thickness` px wide, in its setcolor colour. That is
--     exactly the 1 px 80 % grey frame this wants, for one object.
--   * display.setfill's PERCENTAGE HAS NO VISIBLE EFFECT on a rect. A 64 x 14 rect at setfill(100)
--     rendered as its perimeter -- 137 lit px, not 896. So the app's ui_fill_solid calls are inert,
--     and every rect it draws is a hollow box; the table rules only look solid because they are 1 px
--     wide. A partial fill was the first design here and it drew nothing at all.
--   * setthickness caps at 10 ("1130 Parameter thickness, expected value from 1 to 10"), so a rect
--     cannot be thickened into a solid 62 px bar either -- at thickness 6 it drew a 6 px border with
--     a hollow middle.
--   * an OBJ_LINE with thickness 10 IS solid, at any length, and display.setposition moves its
--     endpoint. So one line is a bar with 1 px granularity and no ladder of segments.
--
-- CACHED, because this runs at ~1 Hz from inside a capture and every display call is an IPC round
-- trip to the second processor. Two entries: the percentage, and which of the three states the
-- objects are in, so 40 -> 41 costs one setposition and no setstate.
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
  -- THE LENGTH, and only when it changed. Rounded to whole px, which is the granularity the panel
  -- has: ui_prog_wmax px of travel, so one px is under 1 %.
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

-- THE ERR FIELD'S NUMBER, in one place. The value and its colour were computed apart, and by different
-- rules: a recording took the count from ck_tot and the colour from the retained TAIL, so a run damaged
-- only in its head showed a non-zero ERR in the all-clear colour. Returns nil when nothing is decoded.
-- The trust count for a RUN's totals. A run keeps no errs of its own, only per window, so the head swap
-- is arithmetic -- see sdec.ua_err_count for why the extent replaces the failure count. Takes the table
-- rather than reading ck_tot, so the status row and the ERR field cannot answer differently: they did,
-- and the panel read 'ERR 7' beside '1 err' on the same screen.
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
    -- THE SAME NUMBER THE FIELD SHOWS, so the colour cannot contradict it.
    local n = sdec.ui_err_n()
    if n ~= nil and n > 0 then return sdec.ui_c_err end
    return fd.c
  end
  -- S/N BANDS. Read from sdec.snr_db, which is the same number the cell prints, so the colour and
  -- the figure cannot disagree. nil keeps the column's own colour: the value is '--' already and a
  -- red '--' would report a bad measurement where there is none.
  -- FIT BANDS, ON THE NUMBER THE CELL PRINTS AND NOTHING ELSE. Guarding on sdec.res or on q <= 0
  -- instead put a WHITE 1.00 on every streaming and flow-control screen, where there is no frame
  -- result but the fit is real, and a WHITE 0.00 wherever nothing fitted -- a figure the operator
  -- reads as unbanded while the two beside it are banded. If the cell shows a number, band it.
  if j == sdec.ui_fitfield then
    local q = sdec.fitq
    if q == nil then return fd.c end
    -- BAND THE DISPLAYED VALUE, NOT THE RAW ONE. The cell prints '%.2f', so 0.8996 shows as '0.90' --
    -- banding the raw number put an amber '0.90' on the panel, which is the colour contradicting the
    -- figure beside it, the exact thing these bands exist to avoid.
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
  -- %.0f on both: a locked rate can be a MEASUREMENT, and decode_from copies force_baud into
  -- sdec.baud with snapped = true, so a fraction reaches either branch. This is the repaint path for
  -- every capture, so on 5.5 a %d here raises the whole refresh and on 5.0.2 it silently truncates
  -- -- leaving the BAUD cell disagreeing with baud_text() beside it.
  if sdec.baud == nil and sdec.force_baud ~= nil then
    v[1] = string.format('%.0f', sdec.force_baud or 0)
  elseif sdec.baud == nil then v[1] = '--'
  -- THE SAME CONDITION baud_text() USES, or the two disagree about the same capture: the cell would read
  -- 38400 while the text row read '38400 baud?'. A panel that contradicts itself is worse than either
  -- answer alone, because the operator cannot tell which one to believe.
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
      v[9] = tostring(sdec.ui_err_n())
    end
  elseif r == nil then v[8], v[9] = '--', '--'
  else
    v[8] = tostring(r.nf)
    -- Windowing artefacts are excluded and an identified misaligned head is not -- see
    -- sdec.ua_err_count. Counting the artefacts made ERR read 1 or 2 on every healthy capture, an
    -- indicator that is never zero; excluding the head made it read 1 beside a note naming four.
    v[9] = tostring(sdec.ui_err_n())
  end

  -- '--' WHEN THERE IS NO FIT, not '0.00'. `or 0` printed a number for a capture that fitted nothing,
  -- which then took the column's own colour and put an UNBANDED figure between two banded ones.
  if sdec.fitq == nil then
    v[10] = '--'
  else
    v[10] = string.format('%.2f', sdec.fitq or 0)
  end
  -- '--' RATHER THAN A NUMBER when sig_levels refused or has not run: a noise figure with no
  -- measured swing behind it is not a small number, it is no number.
  if sdec.snr_db == nil then
    v[11] = '--'
  elseif sdec.snr_db >= 99 then
    -- CLAMPED WITH A '>', not rounded into two digits. A synthesised capture reaches 130 dB and the
    -- instrument's own ADC floors near 97; reporting either as '99 dB' would state a measurement
    -- where there is only a limit.
    v[11] = '>99 dB'
  else
    v[11] = string.format('%.0f dB', sdec.snr_db or 0)
  end
  return v
end

-- How far a misaligned head reaches, and whether it is on screen. Returns extent, onscreen --
-- extent nil when no head was identified.
--
-- ONE FUNCTION BECAUSE THREE INDICATORS SHARE THIS NUMBER and must agree: the note names the
-- extent, ERR counts it (sdec.ua_err_count), and the hex rows covering it are red. Asked
-- separately, the colour asked the narrower question -- did this byte FAIL a check -- so a head
-- reddened only where it happened to fail: 'the first 35 bytes are misaligned' beside ERR 35, with
-- bytes 17-32 painted white for passing their stop bit by luck.
--
-- A RECORDING'S HEAD MAY BE OFF SCREEN. ck_decode discards r.headsusp with its window, so the run's
-- figure comes from ck_tot's first window; but a 32 kB run shows its retained TAIL, and both the
-- note and the colour would then point at the wrong end. res.first == 1 means the head is on screen.
function sdec.ui_head_extent()
  local hs = nil
  if sdec.res ~= nil and sdec.res.headsusp ~= nil and sdec.res.headsusp > 0 then
    hs = sdec.res.headsusp
  elseif sdec.ck_tot ~= nil and sdec.ck_tot.headsusp ~= nil and sdec.ck_tot.headsusp > 0 then
    hs = sdec.ck_tot.headsusp
  end
  if hs == nil then return nil, true end
  local onscreen = (sdec.res == nil or sdec.res.first == nil or sdec.res.first <= 1)
  -- HOW FAR THE DAMAGE ACTUALLY REACHES, not how far the SUSPICION does. headsusp is idle1 - 1: the
  -- bytes before the first inter-message GAP, which ua_run excludes from the parity vote as a
  -- conservative region. It is not a count of bad bytes, and reporting it as one over-claimed badly
  -- -- 'the first 79 byte(s) are misaligned' over a capture with 3 flagged bytes and a first row that
  -- was not even red, because the fox vector runs 79 bytes before its first gap. An earlier capture
  -- said 36 against 20 errors, close enough to look plausible, which is how it survived.
  --
  -- THE LAST FLAGGED BYTE IN THAT REGION, so 'the first N' is literally true: N covers every byte the
  -- decoder could not frame, and nothing beyond. Only countable when the head is ON SCREEN -- a
  -- 32 kB tail does not carry its own head's errs -- so the other branch keeps no number at all
  -- rather than quoting the suspect region as if it were damage.
  if onscreen and sdec.res ~= nil and sdec.res.errs ~= nil then
    -- THROUGH ua_head_bad, not a loop of its own: ERR counts this same region, and when the two
    -- derived it separately the panel said four bytes were misaligned beside an ERR of 1.
    local last = sdec.ua_head_bad(sdec.res, hs)
    if last > 0 then hs = last end
  elseif sdec.ck_tot ~= nil and sdec.ck_tot.headbad ~= nil
         and sdec.ck_tot.headbad > 0 then
    -- FROM THE RUN, for a tail that does not contain its own head. ck_decode counted it on the window
    -- that produced the first bytes, which is the only place the opening bytes exist.
    hs = sdec.ck_tot.headbad
  end
  return hs, onscreen
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
  -- because 'free' means do not wait -- so the field still reads Trig In while the external trigger
  -- does nothing. Same class as the 'parity was ASSUMED none' note below. The rear BNC is an option
  -- FIELD, not a checkbox: no OBJ_EDIT_CHECK exists anywhere in the app.
  if sdec.trigext and sdec.trigmode == 'free' then
    add('Rear BNC = Trig In is set but IGNORED -- Free run means do not wait for anything')
  end

  -- NO RECORDING FORECAST ON THIS ROW. A note like 'bounded at 8192 bytes -- ~2 s of this line, and
  -- nothing stops it early' is wrong in two ways at once:
  --
  --   * IT OUTLIVES THE RUN. ui_notes has no idea whether the recording it forecasts has already
  --     happened, so a finished 8 kB capture sits under a yellow warning about a press made a minute
  --     ago -- distracting, and above the notes describing the result.
  --   * '~2 s' IS THE LINE'S TIME, NOT THE OPERATION'S. It is cap/bps: how long the DEVICE takes to
  --     send that many bytes. The meter then decodes at ~300 byte/s whatever the baud rate, so 8 kB is
  --     ~27 s of decoding after the acquisition -- an order of magnitude out, in the reassuring
  --     direction, which is the worst direction for a figure nothing can interrupt.
  --
  -- THE BOTTOM ROW CARRIES IT INSTEAD, where it is a property of the mode and not of a run: see
  -- ck_status's 'ready' string, which names the ceiling AND that nothing stops it once started. That
  -- string appears only while the mode is armed and idle, so it cannot outlive its own subject.

  -- A mode that changed ITSELF has to say so. Both of these are consequences of a button press
  -- whose effect is otherwise invisible: mode_exit() moves the MODE cell back to a grey FRAME, and
  -- log_new() changes a filename that only appears on the NEXT capture. Ranked above the wire
  -- warnings because they answer "what did that press just do?".
  -- ONLY WHEN THE RUN ENDED BADLY. A normal ending here leaves a yellow note describing its own exit,
  -- sitting over the notes that describe the RESULT and outliving the press that caused it. The status
  -- row's summary -- bytes, errors, window count, filename -- is the completion message, and it is
  -- enough. A FAILED run does say so here, because the summary cannot carry a reason.
  if sdec.mode_exited ~= nil and sdec.mode_exitbad then add(tostring(sdec.mode_exited)) end
  if sdec.lognote ~= nil then add(tostring(sdec.lognote)) end
  -- A RECORDING THAT CHANGED ITS OWN MEASUREMENT BASIS MID-RUN SAYS SO. strm_relevel() only fires when
  -- the watchdog is about to end a run on levels REUSED from a previous capture and this capture's own
  -- samples disagree -- so the threshold the second half is judged against is not the one the first
  -- half was. That is the same class as the two above: a consequence of the app's own decision, with no
  -- other trace on the panel. Ranked with them, above the wire warnings.
  if sdec.strm_releveled ~= nil then add(tostring(sdec.strm_releveled)) end
  -- THE APP THREW AWAY A SETTING THE OPERATOR MADE, which is the loudest thing it can do without
  -- asking, and the BAUD cell and padlock both change with no other explanation. Ranked with the
  -- others in this group for the same reason: it is a consequence of the app's own decision.
  if sdec.relocked ~= nil then add(tostring(sdec.relocked)) end
  -- THE APP REFUSED A SETTING THE OPERATOR MADE, and unlike relocked there are no bytes on screen to
  -- explain themselves -- an empty dump with a locked rate looks like a dead wire. So this outranks
  -- every wire warning below: it names the rate the capture actually carries and the control that
  -- takes it, which is the whole content of the refusal. Options > Baud 0 is named because it EXISTS;
  -- rate_accept() is the same action for a caller, but the panel must not cite a control it lacks.
  if sdec.rate_refused ~= nil then add(tostring(sdec.rate_refused)) end

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
    -- WHICH BYTES, NOT JUST HOW MANY. A finished recording leaves its retained TAIL on screen, so
    -- 'the first 8192' named the wrong end of the stream while the index column read 24576 -- the
    -- panel contradicting itself. res.first is the 1-based absolute index ck_tail_result() records
    -- for exactly this, and capture() says so where it assigns the tail.
    local first, tot = sdec.res.first, sdec.res.ntotal or sdec.ck_tot.nf
    -- WITH NO FILE THE REST IS GONE. A nil path is a recording made with no key (stream_decode
    -- passes one), and 'all are in the USB file' was then the opposite of true about the only bytes
    -- the operator cannot get back.
    if sdec.ck_tot.path == nil then
      -- WHY THERE IS NO FILE IS NOT ALWAYS 'no USB key'. stream_decode passes a nil path whenever
      -- flog_alloc() refuses, and it refuses for three reasons -- no key, a directory it cannot
      -- confirm, and all 1000 names taken. Hard-coding the first put 'no USB key' on the panel with a
      -- key in the slot. flog_why already holds the reason, and the row below it states it in full.
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
  --
  -- THE EXTENT AND WHETHER IT IS ON SCREEN both come from sdec.ui_head_extent, which the hex rows
  -- read too -- see there for why one function rather than two.
  local hs, onscreen = sdec.ui_head_extent()
  if hs ~= nil then
    -- IT STATES THE EXTENT AND STOPS. The note shares its row with the page counter, which leaves it
    -- 556 px, and every trailing reassurance was what got cut: measured on the panel, the long form was
    -- 757 px and rendered as '...everythi...'. Ending at 'misaligned.' removes the clause rather than
    -- betting on it fitting. ERR carries the count of failures; this carries how far they reach.
    -- SINGULAR AND PLURAL, spelled out rather than 'byte(s)': one byte is 'the first byte is', more is
    -- 'the first 3 bytes are'. A parenthesised plural on a panel reads as a placeholder nobody filled in.
    if onscreen then
      if hs == 1 then
        add('began mid-byte -- the first byte is misaligned.')
      else
        add(string.format('began mid-byte -- the first %d bytes are misaligned.', hs or 0))
      end
    else
      -- WHERE THOSE BYTES ARE is the fact that distinguishes this branch and cannot be dropped: the
      -- ones it names are not the ones on the panel.
      --
      -- AND THERE IS NOT ALWAYS A FILE. A recording made with no key keeps its tail and discards the
      -- rest, so 'in the file' named something that does not exist -- about the one part of the run
      -- the operator cannot go and look at. Seen on the instrument: 22382 bytes decoded, 8192 kept,
      -- and a note citing a file for the other 14190.
      local where = ', in the file.'
      if sdec.ck_tot ~= nil and sdec.ck_tot.path == nil then
        where = ', and were NOT recorded.'
      end
      if hs == 1 then
        add('the run began mid-byte -- its first byte is misaligned' .. where)
      else
        add(string.format('the run began mid-byte -- its first %d bytes are misaligned%s', hs or 0, tostring(where)))
      end
    end
  end

  -- Impulse noise on a data bit flips it undetectably: the start and stop bits are
  -- still in place, so the frame passes. "0 err" would then be read as "no
  -- corruption", so say otherwise when the capture shows impulse noise.
  if sdec.res ~= nil and sdec.res.nfalse ~= nil and sdec.res.nfalse > 0 then
    add(string.format('%d false start(s) rejected -- impulse noise; "err" counts framing only',
                      sdec.res.nfalse or 0))
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
  --
  -- NOT FOR A RECORDING'S RETAINED TAIL, and this is the guard that was missing. After an 8 kB run the
  -- result on screen is a SLICE of a capture that went to a file, so 'the capture was full' is not a
  -- fact about it -- and the figure came out as the FRAME window at the recording's own sample rate
  -- (423 bytes, measured on the panel), a number belonging to no capture that had happened. The remedy
  -- it offers is wrong too: a recording mode requires a locked rate, so 'lock the baud rate for a
  -- longer window' names a thing already done.
  --
  -- r.first IS THE TAIL MARKER. ck_tail_result() sets it -- the 1-based absolute index of the oldest
  -- kept byte -- and nothing else in the app does, so a result carrying it is by construction a window
  -- onto something larger. The note above it already states that case properly: 'panel shows bytes
  -- N-M of T; all are in <file>'.
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

-- HEADROOM ON EVERY ui_fit BUDGET, because ui_cw is a MODEL and it reads narrow.
--
-- MEASURED ON THE PANEL: the 104-character mid-byte note fitted to 700 px models at 696 and RENDERS
-- 706 -- 1.4 % over, which from x = 92 puts its tail past the 798 px edge, where the firmware cuts a
-- string without a mark. The same 1.4 % is enough for a full-width note to overwrite the 'p' of the
-- page counter beside it, since the gap between them is only 8 px.
--
-- 1.04, not 1.014: the error is a per-character model against a proportional face, so it is a bound
-- and not a constant, and 4 % of the note cell is 28 px -- three characters of a sentence that is
-- being ellipsised anyway, against a tail that would otherwise be silently cut.
sdec.ui_fit_slack = 1.04

-- `s` clipped to fit `maxpx`, with '...' marking that it was clipped.
--
-- The firmware clips at the PANEL EDGE and says nothing, so an over-long string is cut without a
-- mark and the operator cannot tell a complete sentence from a truncated one.
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

-- The note cell runs from ui_note_val_x to the table's right rule at ui_rule_x1 -- DERIVED, because
-- it was the literal 700 and the trigger-source cell beside it just took 20 px. A literal here would
-- have let the note draw through its own left rule.
sdec.ui_note_px = sdec.ui_rule_x1 - sdec.ui_note_val_x

-- 'page N of M' for the note row, or '' when there is nothing worth saying: one page, or the
-- operator has not paged yet.
--
-- 1-BASED FOR THE OPERATOR: ui_page is a 0-based index and 'page 0 of 35' names a page no button
-- can reach.
--
-- COMPUTED, NOT CACHED, and read by two callers -- ui_page_btns writes it to the panel and
-- ui_note_text reserves room for it. A second copy in a variable would let the reservation describe
-- a string that has since left the screen, and the note is then fitted around nothing.
function sdec.ui_pgind_text()
  if not sdec.ui_paged then return '' end
  local npg = sdec.ui_npages()
  if npg <= 1 then return '' end
  return string.format('page %d of %d', sdec.ui_page + 1, npg or 0)
end

-- WHERE THE COUNTER'S FOUR PIECES GO, right to left from ui_pgind_x. Returns
-- x_page, x_n, x_of, x_m -- and the two number x's are RIGHT edges (JUST_RIGHT), the two word x's
-- LEFT edges.
--
-- DERIVED FROM MEASURED WIDTHS rather than written as four literals, for the reason the dump columns
-- are: the font is proportional and its advances are a measured table, so a literal here would be
-- right only until someone believed the wrong number. Called at build time and by ui_pgind_px.
function sdec.ui_pgind_layout()
  local g = sdec.ui_pgind_gap
  local wn = sdec.ui_textw(sdec.ui_pgind_dig)
  local xm = sdec.ui_pgind_x
  local xof = xm - wn - g - sdec.ui_textw('of')
  local xn = xof - g
  local xpage = xn - wn - g - sdec.ui_textw('page')
  return xpage, xn, xof, xm
end

-- How much of the note cell the page counter is holding. ZERO when it is blank, so the common
-- single-note case keeps the whole cell.
--
-- THE FIXED GROUP EXTENT, not the width of today's string: the pieces do not move, so a two-digit
-- page reserves exactly what a four-digit one does. Reserving the measured string instead would let
-- the note grow into the digit columns and be overlapped there on the next press.
function sdec.ui_pgind_px()
  if sdec.ui_pgind_text() == '' then return 0 end
  local xpage = sdec.ui_pgind_layout()
  return (sdec.ui_pgind_x - xpage) + sdec.ui_note_gap
end

-- The one note the cell has room for, plus how many others there are.
--
-- BOTH PARTS ARE FITTED TO THE CELL, and the marker wins when they compete: a note long enough to
-- fill the cell would otherwise push '(+N more)' off the panel, leaving no sign that a second note
-- exists at all. The marker's width is reserved only when there IS a marker, so the whole cell
-- stays available for the common single-note case.
--
-- THE PAGE COUNTER SHARES THE ROW and is right-justified against the same rule, so its width comes
-- off the cell too -- otherwise a full-width note is drawn straight through it and the firmware
-- fades neither, it just overlaps them.
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
  -- ui_fvalc, ui_trigsrcc and ui_logc must be here too. Omitting any one defeats the colour channel
  -- it shadows: a locked wire shows its values in the plain column colour and the MODE cell
  -- reverts to grey, silently undoing the lock indicator -- whose whole point is that a forced
  -- value must not look measured.
  sdec.ui_fvalc, sdec.ui_trigsrcc, sdec.ui_logc = nil, nil, nil
  sdec.ui_trigc = nil
  sdec.ui_lockc = nil
  -- The progress bar's two: the percentage last written, and which of its three colour states the
  -- rects are in. Omitting ui_progvis would leave a rebuilt bar believing it had already painted
  -- itself away, so the first run of a fresh build would show a frame and no cyan.
  sdec.ui_progpct, sdec.ui_progvis = nil, nil
  -- The title bar's shadow. Omitting it would leave a rebuilt screen believing its bar already said
  -- the current mode, so a build in 8 kB mode would keep the title it was created with forever.
  sdec.ui_titletxt = nil
  return true
end

-- Delete every main-screen object and nil its handle.
function sdec.ui_destroy()
  -- Switch away BEFORE deleting a visible screen; delete children before the
  -- screen that owns them.
  if sdec.ui_scr ~= nil then
    pcall(display.changescreen, display.SCREEN_HOME)
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
  -- The tick, deleted like every other child and BEFORE the screen. Deleting it is what makes the
  -- handle safe to drop; what stops it FIRING in the meantime is sdec.stop() calling ui_tick_off()
  -- first, and the measured rule that a timer only runs while its own screen is the active one.
  sdec.del_obj(sdec.ui_tick_obj)
  sdec.ui_tick_obj = nil
  sdec.del_obj(sdec.ui_page_t)
  sdec.del_obj(sdec.ui_log_t)
  -- The page counter's four pieces, from the dense list ui_build appends them to, so a build where
  -- one create failed still deletes the rest.
  if sdec.ui_pgind ~= nil then
    for i = 1, table.getn(sdec.ui_pgind) do sdec.del_obj(sdec.ui_pgind[i]) end
  end
  sdec.ui_pgind, sdec.ui_pgindtxt = nil, nil
  sdec.ui_pgind_w1, sdec.ui_pgind_n = nil, nil
  sdec.ui_pgind_w2, sdec.ui_pgind_m = nil, nil
  -- The progress bar's frame and line. Deleted HERE, before the screen, like every other child: a
  -- delete against a dead parent is refused, counts in delfails and leaks what it meant to reclaim.
  sdec.del_obj(sdec.ui_progbox)
  sdec.del_obj(sdec.ui_progline)
  sdec.ui_progbox, sdec.ui_progline = nil, nil
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
  -- reference to the object beneath, stranding it inside the firmware until a power
  -- cycle; that accumulation is what walks this firmware toward a PC=002F751C
  -- panic.
  sdec.ui_destroy()
  sdec.ui_invalidate()

  local create = display.create
  local small, med = display.FONT_SMALL, display.FONT_MEDIUM
  local left = display.JUST_LEFT
  local x = sdec.ui_x

  sdec.ui_scr = create(display.ROOT, display.OBJ_SCREEN, sdec.ui_title_text())

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
  rule(sdec.ui_rule_x0, sdec.ui_rule_hdr, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_mid, rw, 1)
  rule(sdec.ui_rule_x0, sdec.ui_rule_bot, rw, 1)
  -- Outer verticals close the box at both ends.
  rule(sdec.ui_rule_x0, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  rule(sdec.ui_rule_x1, sdec.ui_rule_top, 1, sdec.ui_rule_bot - sdec.ui_rule_top)
  -- ...and one after the NOTE label, so the note reads as a cell too.
  -- THE NOTE ROW IS ONE WIDE CELL, not part of the grid: carrying every separator through it draws
  -- lines across the note text. Only the trigger-source divider continues, and it takes its x from
  -- ui_fields[2] so it and the separator above it are one line.
  rule(sdec.ui_fields[2].x - 9, sdec.ui_rule_mid, 1,
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
    -- fd.labdx NUDGES THE LABEL ONLY, never the value under it. Labels sit at a uniform 9 px inset
    -- from their cell's left rule, which reads as a grid everywhere the label is narrower than its
    -- column. Where it is not -- FORMAT is 63 px in a 72 px cell -- that same inset leaves nothing on
    -- the right and the word butts against the divider. The nudge centres those cells instead, and is
    -- separate from fd.x because fd.x also positions the value, whose own centring is already right.
    sdec.ui_flab[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x + (fd.labdx or 0), sdec.ui_lab_y,
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
    -- fd.dy IS PER-CELL, so the shared ui_val_y stays the one baseline everything is reasoned from
    -- and an optical correction cannot quietly become the grid. Only the two FONT_MEDIUM cells set
    -- it; ui_field_band() below derives each cell's ink band from the same sum, so the no-rule-inside
    -- -a-glyph-band invariant is checked against where the text ACTUALLY lands.
    sdec.ui_fval[j] = create(sdec.ui_scr, display.OBJ_TEXT, fd.x, sdec.ui_val_y + (fd.dy or 0),
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
  -- DROPPED CLEAR OF ui_rule_hdr. Anchored on the label ink the shackle started at ui_lab_y itself,
  -- so the header rule ran straight through it; one offset moves the whole glyph rather than four.
  local lock_y = sdec.ui_lab_y + 5
  lockpart(lx + 2, lock_y + 0, 5, 1)     -- shackle: top bar
  lockpart(lx + 2, lock_y + 1, 1, 4)     -- shackle: left post
  lockpart(lx + 6, lock_y + 1, 1, 4)     -- shackle: right post
  sdec.ui_lockbody = lockpart(lx, lock_y + 5, 9, 7)   -- body
  -- No setevent on these either: EVENT_PRESS on an OBJ_RECT is refused (1717) at severity 2, which
  -- raises an error dialog over the panel.

  -- THE TRIGGER-SOURCE CELL: top-left inside the header table's box grid, in a per-source colour --
  -- the at-a-glance channel, since colour is read faster than any word. One text object, retexted and
  -- recoloured per refresh, so it costs no extra object.
  --
  -- IT HELD THE CAPTURE MODE until the mode moved to the title bar. Two indicators for one setting is
  -- one too many, and the trigger source had none.
  --
  -- Stored in ui_flab so ui_destroy deletes it explicitly rather than leaving it to the firmware's
  -- parent cascade, which this app never relies on.
  sdec.ui_trigsrc_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_note_lab_x,
                             sdec.ui_note_y, sdec.ui_trigsrc.edge.name, sdec.ui_c_dim, small, left)
  sdec.ui_flab[nf + 1] = sdec.ui_trigsrc_t
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

  -- THE PROGRESS BAR, TWO RECTS, AND IT IS BUILT BEFORE ui_page_t ON PURPOSE. Creation order is
  -- z-order on this firmware, so the status text must be created AFTER: the resting strings are
  -- longer than the running ones -- '32768 bytes 999 err 9 win -> bytes009 [full]' reaches 404 px,
  -- past the bar's 383 -- and a rect created later would paint over the tail of the sentence that
  -- says where the file went.
  --
  --   ui_progbox   the extent, an OBJ_RECT drawn as a 1 px 80 % grey OUTLINE. A rect is nothing but
  --                its border on this firmware, which is exactly what a frame is. It shows how much
  --                is LEFT, which a bare bar cannot.
  --   ui_progline  the bar, an OBJ_LINE stroked 10 px thick in cyan, its right endpoint moved by
  --                setposition. See ui_progbar_set for why a rect cannot be the bar.
  sdec.ui_progbox = create(sdec.ui_scr, display.OBJ_RECT, sdec.ui_prog_x, sdec.ui_prog_y,
                           sdec.ui_prog_w, sdec.ui_prog_h)
  sdec.ui_fill(sdec.ui_progbox, sdec.ui_c_prog_box)
  pcall(display.setthickness, sdec.ui_progbox, 1)
  sdec.ui_progline = create(sdec.ui_scr, display.OBJ_LINE, sdec.ui_prog_x + 1, sdec.ui_prog_ly,
                            sdec.ui_prog_x + 1, sdec.ui_prog_ly)
  sdec.ui_fill(sdec.ui_progline, sdec.ui_c_prog)
  pcall(display.setthickness, sdec.ui_progline, sdec.ui_prog_lw)
  -- Hidden until a run needs it. The caches are nil (ui_invalidate ran at the top of this function),
  -- so this genuinely writes STATE_INVISIBLE to both rather than believing they are already away --
  -- which is the bug that put a grey frame on the glass in FRAME mode.
  sdec.ui_progbar_set(nil)

  -- A TICK, SO THE KEY IS NOTICED WITHOUT A PRESS. Interval and cost are at sdec.ui_tick_s.
  --
  -- display.OBJ_TIMER is a display OBJECT with an interval and a repeat count, and it reports
  -- through EVENT_PRESS like a button -- which is why no EVENT_TIMER constant exists and why
  -- probing for one finds nothing. Taken from the instrument's own clockIV3 sample, which drives an
  -- analog second hand this way.
  --
  -- TIMER_FOREVER IS 0 ON THIS FIRMWARE, measured; it is the repeat count, not a flag.
  --
  -- THIS IS THE ONLY WAY TO GET PERIODIC WORK HERE. A Lua loop cannot do it: the firmware dispatches
  -- a handler only while the interpreter is idle, so a polling loop never returns and every button
  -- on the panel goes dead -- and display.waitevent() waits on a display.prompt() dialog, not on
  -- these objects, and wedges the instrument (see ui_latency_s).
  --
  -- A TICK CANNOT INTERRUPT A CAPTURE: it is dispatched like a press, so it waits for the handler to
  -- return. sdec.capture() turns it off for the duration anyway, and ui_tick() is a cheap no-op
  -- while the app is busy -- a deferred tick must not repaint objects a run is still using.
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
  -- NO HIT RECT OVER THE TRIGGER CELL. It existed to catch a tap, and EVENT_PRESS on an
  -- OBJ_RECT is refused on this firmware (1717) -- so it caught nothing while still drawing
  -- an outline, which rendered as a box around EXT TRIG visibly brighter than every real rule
  -- on the panel. Options > Rear BNC is the control.
  sdec.ui_trighit = nil
  -- Likewise no setevent: rects do not take presses on this firmware (see the padlock).
  -- Options > Rear BNC is the reliable control.
  sdec.ui_trig_t = create(sdec.ui_scr, display.OBJ_TEXT, sdec.ui_trig_x, sdec.ui_stat_y,
                          'TRIG', sdec.ui_c_warn, small, left)

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
    {x = 8,   w = 120, t = 'Capture',    e = 'sdec.capture'},
    {x = 152, w = 90,  t = 'View',       e = 'sdec.view_toggle'},
    {x = 266, w = 100, t = 'Mode',       e = 'sdec.mode_cycle'},
    {x = 390, w = 112, t = 'NewLog',     e = 'sdec.log_new', hide = 'ui_newlogbtn'},
    -- `hide` marks a button whose handle is kept by NAME as well as by index, because ui_page_btns has
    -- to reach it every refresh. ui_btn is positional and can have a hole, so an index is the wrong
    -- handle to remember: reordering this table would hide the wrong control.
    {x = 526, w = 112, t = 'Save',       e = 'sdec.save', hide = 'ui_savebtn'},
    {x = 662, w = 112, t = 'Options',    e = 'sdec.options'},
  }
  -- UP, LOCK RATE, DN, down the dump area's right margin in that vertical order: up is up and down
  -- is down, so neither page button needs reading -- which is why the labels can be two characters.
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
  -- RIGHT EDGES ALL AT 785, and each face only as wide as its own label. The width these buttons do
  -- not use is width the dump rows get: a TEXT row is 80 columns of a proportional font, needing 636
  -- px against the 592 it had at 185, so the right-hand characters were drawn under Page Up -- and
  -- the page arithmetic still counted them, so paging stepped over bytes that were never visible.
  --
  -- 'Up' AND 'Dn' RATHER THAN 'Page Up' AND 'Page Dn'. A face needs len * ui_adv_btn + 8 px, so two
  -- characters fit in 36 and the 56 here is a comfortable touch target with room over.
  --
  -- WARNING: THIS DOES NOT WIDEN THE TEXT VIEW BY ITSELF. The dump's usable width is set by the
  -- LEFTMOST margin button, and that is Lock Rate at 645 -- 'Lock Rate' measures 134 px and cannot
  -- follow the page buttons down. Rows 7..10 sit under it, so cols stays at 80 (631 px, ending at
  -- 639) until Lock Rate itself moves. tools/render_png.py measures every row against that edge.
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
  -- WHICH PAGE OF HOW MANY, on the NOTE ROW at the right-hand end. Paging blind is the complaint this
  -- answers: the buttons move the view but nothing said how much there was or where in it you were.
  --
  -- ON THE NOTE ROW rather than in the right margin between the page buttons. The margin is the wrong
  -- home twice over: it puts a sentence-sized fact in a 44 px gap between two buttons, and it spends
  -- margin width the dump rows want.
  --
  -- FOUR OBJECTS, because a text object carries one colour and this line carries two: the numerals at
  -- full white, 'page' and 'of' at 66 %. They are created with their colours and never recoloured, so
  -- the counter needs no colour shadow cache -- one fewer entry ui_invalidate could be missing.
  --
  -- THE NUMERALS ARE JUST_RIGHT IN FIXED COLUMNS so the digits land in the same place at 7 and at
  -- 137; the words are left-anchored. Nothing here moves as the page changes, which is the point.
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

  -- A SCREEN WITH NO BUTTONS IS NOT A USABLE APP, and this is the check that catches a pool that
  -- ran out PART WAY through -- the screen exists, so the guard above passed, and there is nothing
  -- to press. The buttons are built last precisely so this covers everything before them.
  if nb < table.getn(bdef) then
    error(string.format('only %d of %d buttons could be created -- display object pool exhausted. '
                        .. 'Power cycle the instrument.', nb or 0, table.getn(bdef) or 0), 0)
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
-- Save and NewLog, shown only when something the app writes could reach the key. -> true if
-- the visibility changed.
--
-- ITS OWN FUNCTION BECAUSE TWO CALLERS NEED IT AND ONE GUARD MUST NOT GATE BOTH. ui_page_btns()
-- returns at its second line when sdec.ui_pgbtn is nil -- a build whose Page buttons failed to
-- create -- and this block sat after that return, so those two buttons could never hide on such a
-- build. ui_tick() needs it per tick and has nothing to do with paging.
--
-- ONE CACHE WITH ONE OWNER. ui_savevis is written here and nowhere else, so the tick cannot hold a
-- second opinion that a repaint elsewhere has already made stale.
function sdec.ui_usb_btns()
-- SAVE AND NewLog ARE HIDDEN WITH NO KEY IN THE SLOT. Both exist only to put a file on the key -- Save
-- writes the report, NewLog starts the next byte log -- so with no key neither has a press that can
-- succeed, and a button that can only report a failure is worse than no button. Same reasoning as Lock
-- Rate above: do not offer a press that cannot do its job.
--
-- STATE_INVISIBLE, not STATE_DISABLE: the display reference is explicit that DISABLE applies to
-- display.OBJ_EDIT_* only, so a disabled button is not available on this firmware.
--
-- sdec.log_live() IS THE TEST, and it names no path -- so asking on every refresh costs 237 us and
-- posts nothing. It is also what lets both buttons come back by themselves when a key is inserted.
-- keyok() rather than haskey() so the latch is honoured, and so a refresh is one of the places a
-- key pulled mid-run is NOTICED: the operator sees both buttons go.
--
-- ONE CACHED FLAG FOR BOTH, because they are a function of the same single fact: there is no state in
-- which one should be showing and the other hidden.
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
  -- FIRST, AND BEFORE THE GUARD BELOW. Save and NewLog are not page buttons, and gating them on
  -- sdec.ui_pgbtn meant a build whose Page buttons failed to create could never hide them.
  sdec.ui_usb_btns()
  local t = sdec.ui_pgbtn
  if t == nil then return false end
  local npg = sdec.ui_npages()
  local want = false
  if npg > 1 then want = true end
  -- THE COUNTER IS NOT GATED THE SAME WAY THE BUTTONS ARE. They appear whenever a page 2 exists;
  -- it waits until the operator has actually paged (ui_pgind_text), because until then the note it
  -- shares the row with is worth more.
  --
  -- ONE CACHE FOR FOUR OBJECTS, keyed on the whole line, because all four are a function of the same
  -- two numbers -- so there is no state in which some pieces are current and others are not. Blanked
  -- rather than recoloured when there is nothing to say: settext('') is how every other cell here
  -- goes away, and it leaves the colours alone.
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
      pcall(display.setstate, sdec.ui_lockbtn, lst)
      sdec.ui_lockvis = lw
    end
  end

  return true
end

-- Repaint from the current decode result. settext only: nothing is created,
-- deleted or repositioned, which is what keeps a refresh cheap.
function sdec.ui_refresh_do()
  -- A BARE CALL: every display write inside ui_page_btns() and the ui_usb_btns() it calls is
  -- already guarded one line at a time, so it returns false rather than raising and a button that
  -- could not be repainted cannot abandon the field repaint below it.
  sdec.ui_page_btns()
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
  -- THE TRIGGER SOURCE. What a capture WAITS for is what distinguishes a capture that is hung from one
  -- waiting for an edge that is not coming, and the capture mode has the title bar. Recoloured as well
  -- as retexted: the colour is what makes it readable without reading.
  --
  -- FALLS BACK TO 'Start bit' RATHER THAN GOING BLANK on an unrecognised trigmode, because this cell
  -- now carries the front-panel key's only indicator -- see the rear-BNC cell, which is empty when the
  -- connector is off and so cannot carry it.
  local tsrc = sdec.ui_trigsrc[sdec.trigmode or 'edge'] or sdec.ui_trigsrc.edge
  set(sdec.ui_trigsrc_t, tsrc.name)
  if sdec.ui_trigsrcc ~= tsrc.c then
    sdec.ui_color(sdec.ui_trigsrc_t, tsrc.c)
    sdec.ui_trigsrcc = tsrc.c
  end
  -- THE TITLE BAR NAMES THE MODE TOO, in the largest type on the panel. Retexted only when it
  -- changes, like every other cell -- and the mode changes on a button press, so that is at most once
  -- per press. settext on an OBJ_SCREEN is undocumented but verified on this firmware (see ui_title);
  -- guarded anyway, because a refusal must cost the title bar and not the refresh.
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
  -- The misaligned head, once for the whole loop rather than per row: it is one number about the
  -- capture, and ua_head_bad walks the errs array to get it.
  local hext, honscr = sdec.ui_head_extent()
  if not honscr then hext = nil end
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
      -- OR WHEN IT LIES INSIDE A MISALIGNED HEAD, whether or not those frames failed a check. In a
      -- head the bit boundaries are wrong, so a frame can pass its stop bit and parity by luck and
      -- still hand back a plausible WRONG byte -- and the note and ERR both already count the whole
      -- extent. Reaching only part of a row still reddens it: the row is the unit of colour.
      if hext ~= nil and i0 <= hext then bad = true end
      if r ~= nil then
        local j
        for j = i0, i0 + cols - 1 do
          -- ANY flagged byte reddens its row, edges included. The colour excluded the first
          -- ua_edge_frames and the clipped last frame, which contradicted the row it was
          -- describing: seen on the panel, an 8 kB run with ERR 3 drew '???OWN FOX JUMPS' in
          -- normal white. The bytes are ALREADY '??' in hex and '?' in ASCII, so the colour
          -- claims nothing new -- it agrees with what is on screen, and damage is meant to be
          -- visible at a glance.
          --
          -- ERR EXCLUDES THE SAME EDGES (sdec.ua_err_count skips resync debris and the clipped
          -- final frame), so a row can be red with ERR at 0. That is deliberate: a count that is
          -- never zero on a healthy gapless line is decoration, while the colour only ever agrees
          -- with the '??' already drawn in it.
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
  -- hairlines cut across an 80-column TEXT row that has no columns to divide. MIDI and LIN are hidden
  -- for the same reason and not as an oversight: both are `cols = 1` in sdec.ui_views, one message or
  -- frame of free text per row, so they have no column boundary either.
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
  -- THE VIEW DECIDES, AND ONLY THE VIEW. The capture mode has no say: in the 8 kB and 32 kB modes the
  -- table structure is the same table, and a grid that appears and disappears as the Mode button is
  -- pressed reads as a fault rather than as information. Testing the mode's own `view` flag as well
  -- left the rules missing for the whole of a recording mode until a capture had finished -- which is
  -- exactly when an operator is looking at the panel and deciding whether it is working.
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
    if capn ~= nil and capn > 0 then wintxt = string.format(' win %d', capn or 0) end
    -- COMPACT, because this string has to fit its cell at every baud rate and in every view. A
    -- verbose form -- 'FRAME  TEXT  page 1/1  bytes 1-1200 of 1200  win 240  [done]' -- runs to
    -- 60-odd characters, and at the measured 7.80 px/char that is past the divider and straight
    -- through the log field beside it. Hence 'pg' and 'N-M/T', which drop words rather than
    -- numbers. The unit name stays, because 'bytes' versus 'msg' is what says whether the counts
    -- are bytes or parsed messages.
    set(sdec.ui_page_t, string.format('%s %s pg %d/%d %s %d-%d/%d%s [%s]%s',
        tostring(md.name), tostring(mname), sdec.ui_page + 1, npg or 0, tostring(sdec.ui_unit()),
        math.min(base + 1, nit), math.min(base + per, nit), nit or 0, tostring(wintxt), tostring(st), tostring(warn)))
  else
    set(sdec.ui_page_t, string.format('%s  %s%s', tostring(md.name), tostring(sdec.ck_status()), tostring(warn)))
  end
  -- THE BAR FOLLOWS THE SAME STATE THE ROW ABOVE DOES, and this is the call that TAKES IT AWAY: a
  -- run that ends leaves ck_running false, so ck_pct returns nil and both rects go. Without it the
  -- bar would stay at its last percentage under a row that has moved on to naming the file.
  sdec.ui_progbar_set(sdec.ck_pct())
  -- THE REAR BNC, AND WHICH WAY IT IS POINTING -- and EMPTY when it is off.
  --
  -- A PERMANENT AMBER 'EXT TRIG' over an Options page reading Rear BNC = Off is the panel asserting
  -- hardware that is not in use. A marker that is always present is not a marker, so the off state
  -- draws nothing at all.
  --
  -- THE DIRECTION IS THE FACT. Rear BNC is two independent booleans -- trigext (an input: wait for an
  -- edge) and fc_out (an output: pulse a credit per capture) -- and 'EXT TRIG' named neither, so the
  -- cell could not distinguish a meter waiting for a signal from one driving another device.
  --
  --   trigext          TRIG IN    green
  --   fc_out           TRIG OUT   amber
  --   both             TRIG I/O   cyan
  --   neither          (empty)
  --
  -- THE '?' IS THE APP'S OWN UNCERTAINTY MARK, the one the BAUD cell uses for an unlocked rate. A rear
  -- INPUT is configured-but-not-in-force under Free run, because free run means DO NOT WAIT -- the case
  -- that misleads, since the form still shows it ticked. The colour stays the mode's (the three are
  -- spoken for) and ui_notes carries the sentence.
  local trigtxt, trigcol = '', sdec.ui_c_dim
  local tin, tout = (sdec.trigext == true), (sdec.fc_out == true)
  -- 'TRIG', NOT 'EXT TRIG': the cell is 122 px wide since the status divider moved right, and
  -- 'EXT TRIG OUT' is 123. The instrument has one external trigger connector, so the direction is the
  -- only part that carries information.
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

  if not md.view or sdec.ck_tot ~= nil or sdec.ck_running then
    -- While streaming, the right-hand cell carries the CONTROLS: an operator watching a
    -- four-minute capture needs to know how to get out of it more than they need the debug log's
    -- line count, and both will not fit in the left string, which already ends near 385 px of the
    -- 430 available.
    --
    -- WHICH CONTROL IS TRUE IS DECIDED BY THE STATE, AND FOR A ONE-PRESS RUN THE TRUE ANSWER IS NONE.
    -- 'TRIGGER key = stop' on the strength of cancel_setup()'s blender latch is FALSE, measured:
    -- pressed 20 % into a 32 kB decode, with tens of seconds of polling still to come, the run
    -- finishes 'full' and the latch is EMPTY -- the key's event never reaches
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
    -- 'Stop', NOT 'Exit'. Mode aborts the RUN without changing the mode, so a label promising an exit
    -- describes behaviour the button does not have. Either button stops; saying so twice in one cell
    -- is better than naming a control that does something else.
    if sdec.strm_recording then
      set(sdec.ui_log_t, 'Capture or Mode = Stop')
    elseif sdec.ck_job ~= nil then
      set(sdec.ui_log_t, 'Capture=step  Mode=Stop')
    elseif sdec.ck_running or sdec.strm_inflight then
      set(sdec.ui_log_t, 'no stop until it ends')
    else
      -- NO 'Mode=...' HERE AT ALL. 'Mode=Exit to FRAME' is wrong in two of the three states that show
      -- this cell: Mode CYCLES, so from FRAME it reaches 8 kB and from 8 kB it reaches 32 kB, and only
      -- from 32 kB does it reach FRAME. Naming the destination correctly is still confusing, because a
      -- mode name on the panel reads as the mode you
      -- are IN, and this row sits under a MODE cell that means exactly that. Two mode names on one
      -- screen meaning different things is worse than one fewer hint.
      --
      -- The log status goes here instead, which is what FRAME mode shows and is never a claim about
      -- a control. sdec.mode_next() survives as the thing mode_cycle() steps with.
      set(sdec.ui_log_t, sdec.flog_status())
    end
  else
    set(sdec.ui_log_t, sdec.flog_status())
  end
  return true
end

-- Refresh the panel, and NEVER raise doing it. -> true, or false if the body gave up part way.
--
-- ONE GUARD HERE, NOT ONE AT EACH CALL SITE. Sixteen callers wrapped this in a pcall of their
-- own, which is a guard around OUR code rather than around a firmware boundary: display writes
-- already go through ui_set, which pcalls each one. What the callers were really protecting
-- against is this body formatting a number that is nil -- %d on a nil raises -- so the guard
-- belongs with the body that can raise, once, where it cannot be forgotten at a new call site.
--
-- A REFRESH IS COSMETIC AND MUST NOT COST ITS CALLER. A capture that decoded correctly must not
-- be reported as failed because one panel field could not be formatted, which is exactly what
-- an unguarded raise reaching sdec.capture() would do.
--
-- The parenthesis TRUNCATES pcall to its first result: the body returns nothing and no caller
-- reads a value, so this is a plain boolean rather than pcall's true-plus-results.
function sdec.ui_refresh()
  return (pcall(sdec.ui_refresh_do))
end

-- THE BYTE LOG, for the status row: which file is being appended to, and how many BYTES are in it
-- so far. Both, always, in every mode -- the app's promise is that no decoded byte is lost, and a
-- promise the operator cannot see is one they have to take on trust.
--
-- IT HAS 188 px, AND THE OBVIOUS FORM DOES NOT FIT. Measured with ui_textw against the real
-- geometry: the cell runs from ui_stat_div + 6 = 468 to ui_trig_div = 656, and
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
  -- NO KEY OUTRANKS BOTH THE FILENAME AND THE PROMISE, and it has to be asked before either.
  --
  -- A path allocated while a key was in the slot stays set after it leaves, and flog_why is nil
  -- because nothing has failed -- nothing has been ATTEMPTED. So the cell went on reading
  -- 'log: bytes248  2721 B' with the key in a pocket: the bytes are real and on that key, and the
  -- row still reads as logging in progress. Seen on the instrument.
  --
  -- It also covers the empty case, where 'on first capture' is a promise the app cannot keep:
  -- mode_exit() clears flog_why after every recording, so the branch above cannot carry that one.
  if not sdec.log_live() then return 'log: no USB key' end
  if sdec.flog_path == nil then return 'log: on first capture' end
  local base = string.gsub(tostring(sdec.flog_path), '^.*/', '')
  base = string.gsub(base, '%.txt$', '')
  local n = sdec.flog_bytes or 0
  local s = string.format('log: %s  %d B', tostring(base), n or 0)
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
    s = string.format('log: ~%s  %d B', tostring(base), n or 0)
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
    --
    -- THE TRAILING WORDS AND THE WINDOW COUNTER ARE ALTERNATIVES, NOT BOTH. This row now has to end
    -- 20 px before the progress bar at 339, and 'win 32/32' together with 'of the buffer' runs to
    -- 369 -- straight through it. The counter wins when it is there: it is the fact that says a
    -- multi-window run is progressing, and the bar beside the figure shows what the words explained.
    if sdec.ck_nbytes == nil or sdec.ck_nbytes < 1 then
      local have, want = sdec.ck_acq_have or 0, sdec.ck_acq_want or 0
      local pct = 0
      if want > 0 then pct = math.floor(100 * have / want) end
      if wtxt ~= '' then return string.format('recording...%s %d %%', tostring(wtxt), pct or 0) end
      return string.format('recording... %d %% of the buffer', pct)
    end
    -- THE STOP CONTROL IS NOT SAID HERE. This string shares its line with the log status and has
    -- ~58 characters before the divider; 'TRIGGER stops' would cost 13 of them at exactly the
    -- moment the byte counters matter most. Controls belong in the right-hand cell, which
    -- ui_refresh() fills with 'TRIGGER=stop' for the whole run.
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
  -- SHORT, always. This row shares its line with the log status, so the left string has ~454 px
  -- before ui_stat_div; the reason a mode cannot run is a full sentence and lives on the note line
  -- instead (see ui_notes). 'not armed' here and the remedy there is one fact at two levels of
  -- detail, which is what the two rows are for.
  if t == nil then
    if sdec.mode_why(md) ~= nil then return 'not armed -- see the note' end
    -- THE MAX FOR THIS MODE, stated before the capture rather than discovered after it. Frame
    -- mode shows its window in the row above (win N, which moves with the sample rate); the
    -- streaming modes show their cap here. Every mode with view = false has a cap, so the fallback
    -- below is unreachable and names no control.
    if md.cap ~= nil then
      -- AND THAT NOTHING CUTS IT SHORT, which is the other half of what the operator needs BEFORE
      -- pressing: neither a button nor the TRIGGER key can (measured). It belongs HERE and not on the
      -- note line, where a forecast outlives the run it describes and quotes the LINE's time rather
      -- than the operation's.
      --
      -- NO TIME FIGURE AT ALL. cap/bps is the device's sending time and the decode costs several
      -- times more, so any single number here would mislead; the byte ceiling is exact and the bar
      -- shows progress once it starts. Measured at 438 px for the widest form, inside the 456 a
      -- not-running string has before the divider.

      -- AND WHETHER IT IS GOING ANYWHERE. With no key the recording still runs and still fills the
      -- panel, but only the last sdec.ck_keep bytes survive it -- so promising 'to a file' is the one
      -- thing this row must not do.
      --
      -- IT NAMES BOTH NUMBERS, because the cap alone is the wrong promise: 'ready -- 32768 bytes,
      -- panel only' reads as 32768 bytes arriving on screen, and 8192 do. Where the two are equal --
      -- 8 kB mode, cap == ck_keep -- saying it twice would invite the reader to look for a
      -- difference, so that case states the one number. 46 characters at the widest, against the 51
      -- of the string below, so the 456 px this row has before the divider still holds.
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
  -- A nil path is a recording that had nowhere to go, not a name nobody filled in: 'USB' reported it
  -- as written to the key, which is the one thing the operator needs to know it was not.
  local base = 'NOT recorded'
  if t.path ~= nil then base = string.gsub(tostring(t.path), '^.*/', '') end
  -- A MULTI-WINDOW RUN REPORTS THE TRANSMISSION, NOT ITS LAST WINDOW. ck_tot describes one window,
  -- so after a flow-controlled run of eleven windows it names the eleventh -- and '2048 bytes' under
  -- a 300 kB transmission is not a small inaccuracy, it is the wrong subject. fc_bytes is the total
  -- record_run() accumulated across every window it credited.
  if (sdec.fc_win or 0) > 1 then
    return string.format('%d bytes in %d windows -> %s  [%s]',
                         sdec.fc_bytes or 0, sdec.fc_win or 0, tostring(base),
                         sdec.fc_end or t.stopped or 'done')
  end
  -- ck_err_n, NOT t.nbad: this string sits on the same screen as the ERR field, and reading the raw
  -- failure count here put '1 err' under an 'ERR 7' on a run whose misaligned head reached byte 7.
  return string.format('%d bytes  %d err  %d win  -> %s  [%s]',
                       t.nf or 0, sdec.ck_err_n(t) or 0, t.nwin or 0, tostring(base), t.stopped or 'done')
end

-- The fraction the progress bar shows, 0..100, or nil when no honest one exists.
--
-- THE TWO PHASES HAVE DIFFERENT DENOMINATORS, exactly as ck_status's text does: per cent of the
-- BUFFER while the digitizer fills it, then bytes against the mode's cap once the decode starts.
-- Nothing is decoded during the first, so a byte fraction there would be a fiction.
--
-- nil FOR A PRESS-DRIVEN RECORDING, which is the case that would lie. Between the start press and
-- the stop press no Lua of ours runs, so a bar drawn there would hold whatever the start press put
-- in it for the whole recording -- empty, reading as "nothing is being recorded". An absent bar is
-- honest; a frozen one is not. It is the same reason ck_status states its control and no figure.
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
-- which phase the run is in. sdec.progress and sdec.progress_samples are the callers -- one per
-- phase -- and this is the only place that knows they paint the same row.
-- NEVER RAISES, and the ONE guard that promises it lives here, not at the three call sites.
-- ck_status() is a 130-line text builder over a dozen result fields, so "this cannot raise" is a
-- proof that has to be redone at every edit of it; a guard here cannot be forgotten at a new
-- caller. A guard at the caller would be a guard around OUR code, and this row is painted from
-- inside the capture loop, which is the one path that cannot afford pcall depth.
--
-- The parenthesis TRUNCATES pcall to its first result: no caller reads a value, so this is a
-- plain boolean rather than pcall's true-plus-results.
function sdec.progress_row()
  return (pcall(sdec.progress_row_do))
end

-- The row itself: one settext and one setfill. -> ui_progbar_set's verdict.
function sdec.progress_row_do()
  local md = sdec.mode_cur()
  sdec.ui_set(sdec.ui_page_t, string.format('%s  %s', tostring(md.name), tostring(sdec.ck_status())))
  return sdec.ui_progbar_set(sdec.ck_pct())
end

-- One settext and one setfill, called at ~1 Hz from the capture loop. A BARE CALL: progress_row()
-- carries the guard, so a progress update cannot cost the capture it is reporting on without
-- adding a pcall layer to the capture path.
function sdec.progress(nbytes)
  sdec.ck_nbytes = nbytes
  return sdec.progress_row()
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
    -- Switch away before deleting, or the firmware is left showing a deleted screen.
    --
    -- THE BRANCH IS PURE VALUE SELECTION, so it belongs OUTSIDE the guard: it picks which screen and
    -- touches no firmware, which leaves one call for the direct form to take. A closure here was
    -- paying OP_CLOSURE's allocation to wrap an `if`.
    local scr = sdec.ui_scr
    if scr == nil then scr = display.SCREEN_HOME end
    pcall(display.changescreen, scr)
    -- sdec.options() suspends the tick while the form is up, so tearing the form down is one of
    -- the ways out and has to re-arm it. Only when a main screen is what we switched BACK to: on
    -- the SCREEN_HOME path ui_scr is nil, there is no timer left to arm, and ui_tick_on() would be
    -- a no-op anyway -- but saying so here keeps the pairing readable.
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
  if sdec.opt_btn ~= nil then
    local i
    for i = 1, table.getn(sdec.opt_btn) do sdec.del_obj(sdec.opt_btn[i]) end
    sdec.opt_btn = nil
  end
  sdec.del_obj(sdec.optscr)
  sdec.optscr, sdec.opt_proto, sdec.opt_baud = nil, nil, nil
  sdec.opt_bits, sdec.opt_par, sdec.opt_pol = nil, nil, nil
  sdec.opt_trig, sdec.opt_ext = nil, nil
  sdec.opt_armv, sdec.opt_armw = nil, nil
  return true
end

-- Build the options screen, its edit fields and its four buttons. Returns the screen handle.
function sdec.build_options()
  sdec.destroy_options()
  local create = display.create
  local y0, dy, x = sdec.ui_opt_y0, sdec.ui_opt_dy, sdec.ui_opt_x
  -- HOW MANY FIELDS THERE WILL BE, decided BEFORE the pitch, because the pitch depends on it. The
  -- Protocol field exists only when a protocol module is loaded (OBJ_EDIT_OPTION refuses fewer than
  -- two options, so a UART-only build must not create it at all), so a full build has NINE fields
  -- and a UART-only one has EIGHT.
  local pv, pl = sdec.opt_proto_list()
  local nf = 8
  if pl.n >= 2 then nf = 9 end
  -- THE PITCH IS CLAMPED TO WHAT ACTUALLY FITS. ui_opt_dy is a PREFERENCE -- how much air the boxes
  -- get -- and this is the ceiling: the last box must end above the button row.
  --
  -- WITHOUT THIS, A FIELD OVERLAPS THE BUTTONS AND NOTHING SAYS SO. In ONE column at the old pitch
  -- six fields ended at 331 and seven at 385 against a button row at 366 -- and arithmetic built on a
  -- 38 px edit height, 12 px under the measured 50, reported 8 px of clearance over an overlap.
  --
  -- THE SECOND COLUMN IS WHAT PAYS FOR THE EXTRA FIELDS, and the counts below are measured against
  -- the clamp as written rather than asserted:
  --
  --     6 fields -> 3 rows, pitch 100, gap 50 px, 73 px clear of the buttons
  --     8 fields -> 4 rows, pitch  99, gap 49 px,  5 px clear      (UART-only build)
  --     9 fields -> 5 rows, pitch  74, gap 24 px,  5 px clear      (a protocol module loaded)
  --
  -- An EIGHTH field is free: seven already needs four rows and leaves the second column's last slot
  -- empty, so it costs no vertical space at all. The ninth is what forces a fifth row, and 24 px is
  -- still six times the 4 px gap that made the fields unresponsive in the first place. A TENTH field
  -- also fits in five rows; an ELEVENTH would force six and is where this stops working.
  local eh, edy = sdec.ui_opt_edit_h, sdec.ui_opt_edit_dy
  -- ROWS, NOT FIELDS, is what the pitch has to clear now. Six fields in two columns is three rows,
  -- so the available span is divided by two gaps instead of five -- which is the whole point of the
  -- second column. A seven-field build is four and three.
  local ncols = sdec.ui_opt_cols or 1
  if ncols < 1 then ncols = 1 end
  local nrows = math.ceil(nf / ncols)
  local maxdy = math.floor((sdec.ui_opt_btn_y - (sdec.ui_opt_btn_gap or 0) - y0 - edy - eh) /
                           (nrows - 1))
  if dy > maxdy then dy = maxdy end
  -- CENTRED, because three rows at a sane pitch no longer fill the form and a block pinned to the
  -- top leaves all its air in one band under the last field. Only ever moves the block DOWN from
  -- y0, and only by what is genuinely spare.
  local used = (nrows - 1) * dy + eh + edy
  local spare = sdec.ui_opt_btn_y - used - y0
  if spare > 0 then y0 = y0 + math.floor(spare / 2) end
  -- THEN NUDGED, and this is a SEPARATE number from y0 on purpose. Adjusting ui_opt_y0 instead does
  -- not do what it reads as: the centring above divides the leftover space, so it gives back half of
  -- whatever is taken away and a 10 px move has to be asked for as 20. Chosen on the glass -- the
  -- centred block sits slightly low against the title bar, because the buttons below it are visually
  -- heavier than the chrome above.
  --
  -- NOT APPLIED WHEN IT WOULD PUSH THE BLOCK OFF THE TOP, which is the seven-field case: four rows
  -- at the clamped pitch already fill the form, spare is 1 px, and the offset would ask for y0 = -12.
  local adj = sdec.ui_opt_y_adj or 0
  if y0 + adj >= 0 then y0 = y0 + adj end
  -- A PITCH UNDER THE BOX HEIGHT OVERLAPS THE BOXES, which is worse than either thing it was
  -- avoiding. Seven fields at y0 = 8 need a pitch of 49 to clear the button row and the box is 50, so
  -- the clamp above alone would have drawn them 1 px on top of each other. When that happens the
  -- COLUMN MOVES UP instead: the pitch goes to the box height, and y0 becomes whatever puts the last
  -- box just above the buttons -- 6 for seven fields, which is 2 px of the 8 given back.
  if dy < eh then
    dy = eh
    y0 = sdec.ui_opt_btn_y - edy - eh - (nrows - 1) * dy
    if y0 < 0 then y0 = 0 end
  end
  -- PUBLISHED, because ui_opt_dy is only the preference and a check that reads IT is checking the
  -- wrong number. The gap assertion in test_serial did exactly that for one run: it reported
  -- 'pitch 54, box 50, gap 4' about a form laid out at 50 with no gap at all.
  sdec.ui_opt_dy_used, sdec.ui_opt_nf_used, sdec.ui_opt_y0_used = dy, nf, y0
  -- ROWS ARE ALLOCATED, NOT NUMBERED. Version 1 omits the Protocol field entirely -- with
  -- only UART present there is nothing to choose between, and display.OBJ_EDIT_OPTION
  -- REFUSES fewer than two options ("OBJ_EDIT_OPTION needs at least two options"), so a
  -- one-entry field does not merely look odd, it FAILS THE BUILD.
  -- TWO COLUMNS, FILLED COLUMN-MAJOR, so a six-field build reads as three and three rather than as
  -- alternating sides. The allocator hands out (x, y) and the fields take it in creation order.
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
  --
  -- pl is computed at the top of this function, because the field COUNT sets the pitch.
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
  -- pl.n == 1 creates NOTHING, and sdec.opt_proto stays nil. Every reader of it already has
  -- to cope with a nil handle -- create() returns nil on refusal, which this app treats as
  -- normal -- so no caller changes. options_seed() and options_apply() are guarded below.
  -- Baud 0 means auto, hence a minimum of 0 rather than 110: a spinner that cannot
  -- express "work it out yourself" would force a guess on every capture.
  local fx3, fy3 = nextpos()
  sdec.opt_baud = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx3, fy3,
                         'Baud Rate', '0 = auto-detect',
                         display.NFORMAT_PREFIX, 0, 0, 1000000, 'Bd')
  -- 'Auto (7/8)' is the default and deliberately the first entry. 5, 6 and 9 data bits are
  -- excluded from the automatic search unless 'any width' is chosen, because every extra
  -- candidate format is another chance for a damaged capture to be won by the wrong one --
  -- and the rare widths lose silently, absorbing a stop bit into the data. Forcing a
  -- specific width bypasses the search entirely, so 5, 6 and 9 remain directly selectable.
  local fx4, fy4 = nextpos()
  sdec.opt_bits = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx4, fy4,
                         'Data Bits', 'auto, or fix it',
                         'Auto (7/8)', 'Auto (any)', '5', '6', '7', '8', '9')
  local fx5, fy5 = nextpos()
  sdec.opt_par = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx5, fy5,
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
  local fx6, fy6 = nextpos()
  sdec.opt_pol = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx6, fy6,
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
  --
  -- ENTRIES COME FROM sdec.ui_trigsrc, not from literals, because the note row's left cell shows this
  -- field's value and the two must be the same words. Spelled out per index rather than unpack()'d:
  -- Lua 5.0.2 has a global unpack() and the offline harness's modern Lua does not.
  local fx7, fy7 = nextpos()
  sdec.opt_trig = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx7, fy7,
                         'Trigger', 'capture start',
                         sdec.ui_trigsrc[sdec.opt_trig_v[1]].name,
                         sdec.ui_trigsrc[sdec.opt_trig_v[2]].name,
                         sdec.ui_trigsrc[sdec.opt_trig_v[3]].name)
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
  local fx8, fy8 = nextpos()
  sdec.opt_ext = create(sdec.optscr, display.OBJ_EDIT_OPTION, fx8, fy8,
                        'Rear BNC', 'trig in / FC out',
                        'Off', 'Trig In', 'FC Out', 'In + FC Out')

  -- THE TWO ARMED-FROM-SILENCE FIELDS. They govern one case and one only: Capture pressed on a line
  -- that is not transmitting yet, where the probe finds no transitions and the capture arms on the
  -- device's first start bit instead of recording the silence. See the block at sdec.armlevel in
  -- serial_core.tsp for why that case needs its own level and its own wait.
  --
  -- THEY DO NOTHING ON A LINE THAT IS ALREADY TALKING, which is worth knowing before reading them as
  -- a general trigger level: where the probe found two levels the threshold is their midpoint, which
  -- beats any fixed voltage.
  --
  -- RANGES COME FROM THE CORE, not typed here, so the field and the comparator cannot disagree about
  -- what is acceptable -- the same reason opt_rear_v is one table read from both ends. The core
  -- clamps as well, because a programmatic set never passes through this field at all.
  local fx9, fy9 = nextpos()
  sdec.opt_armv = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx9, fy9,
                         'Arm At', 'wake-up level',
                         display.NFORMAT_PREFIX, sdec.arm_level_v(),
                         sdec.armlevel_min, sdec.armlevel_max, 'V')
  -- SECONDS, AND THE PANEL IS FROZEN FOR EVERY ONE OF THEM. The help text says 'max' rather than
  -- 'timeout' because that is the operator-visible consequence: nothing can interrupt the wait, so
  -- the number typed here is how long the panel may stop responding. The core's ceiling is the only
  -- guard against a mistyped entry.
  local fx10, fy10 = nextpos()
  sdec.opt_armw = create(sdec.optscr, display.OBJ_EDIT_NUMBER, fx10, fy10,
                         'Arm Wait', 'max wait, frozen',
                         display.NFORMAT_PREFIX, sdec.arm_wait_s(),
                         sdec.armwait_min, sdec.armwait_max, 's')

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
  -- A FORM WITH NO WAY OUT IS WORSE THAN NO FORM: Cancel is one of these four, so a partial row
  -- can leave the operator on a screen they cannot leave. Refused with the same message shape
  -- ui_build uses, which names the cause and the remedy.
  if nob < table.getn(odef) then
    error(string.format('only %d of %d options buttons could be created -- display object pool '
                        .. 'exhausted. Power cycle the instrument.', nob or 0, table.getn(odef) or 0), 0)
  end

  -- Hook End App on THIS screen too: if the firmware delivers EVENT_ENDAPP only to
  -- the visible screen, exiting from the form would strand both screens and the
  -- buffer until a power cycle.
  pcall(display.setevent, sdec.optscr, display.EVENT_ENDAPP, 'sdec.guard(sdec.cleanup)')
  return sdec.optscr
end

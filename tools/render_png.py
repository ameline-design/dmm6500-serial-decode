#!/usr/bin/env python3
"""Render DMM6500 panel artwork to PNG at exact panel pixels, using PIL.

Two subcommands:

  panel      Draw the front-panel mockups from the object dumps that
             tools/mockup.lua records while running the real tsp/serial_ui.tsp.
  schematic  Draw the LIN 2:1 divider as an image sized to be displayed ON the
             instrument (799x400, black background).

Why PIL and not SVG. macOS ships no reliable SVG rasteriser: qlmanage distorts
the viewport -- a probe with corner markers came back with the bottom-right marker
missing and the background stretched past the declared height, which is what made
the earlier mockups look cropped on the right. Drawing directly gives exact
pixels, and it also lets text be MEASURED, so a string that would overrun the
798 px panel is reported instead of being discovered on the instrument.

Font metrics are still an approximation of the panel's own proportional font,
calibrated so a FONT_SMALL row matches the 20 px row pitch seen in
docs/panel-ref-rows.png.

Usage:
  python3 tools/render_png.py panel [--outdir ~/tmp] [--scale 2]
  python3 tools/render_png.py schematic [--outdir ~/tmp]
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REG = '/System/Library/Fonts/Supplemental/Arial.ttf'
BOLD = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'
MONO = '/System/Library/Fonts/Menlo.ttc'

PANEL_W, PANEL_H = 800, 480
TITLE_H = 49            # object y = 0 lands this far below the panel top
CONTENT_H = PANEL_H - TITLE_H

# Panel chrome, sampled from docs/panel-ref-rows.png and
# docs/panel-ref-chrome.png.
BG = (0, 10, 13)        # measured: most common pixel in an empty region of panel-ref-chrome.png
TITLE_TOP = (156, 106, 30)
TITLE_BOT = (92, 58, 13)
BTN_TOP = (242, 242, 242)
BTN_BOT = (168, 168, 168)
BTN_EDGE = (138, 138, 138)
BTN_TEXT = (26, 26, 26)
BUTTON_H = 58           # measured from the FFT app's Options button
# THE DUMP BAND, from serial_ui.tsp: ui_row_y0 = 66 to ui_row_y0 + (ui_nrow-1) * ui_row_dy = 318.
# Distinguishes a dump row from the note and status lines, which pass beside the margin buttons
# legitimately -- ui_note_y = 48 is deliberately truncated with '(+N more)'.
DUMP_Y0, DUMP_Y1 = 66, 318

FONT_SMALL, FONT_MEDIUM = 15, 19


def rgb(v):
    v = int(v) & 0xFFFFFF
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)


def vgrad(img, box, top, bot):
    """Vertical gradient; the panel's title bar and buttons both use one."""
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    h = max(1, y1 - y0)
    for i in range(h):
        f = i / h
        c = tuple(int(top[k] + (bot[k] - top[k]) * f) for k in range(3))
        d.line([(x0, y0 + i), (x1, y0 + i)], fill=c)


class Fonts:
    def __init__(self, s):
        self.reg = {}
        self.bold = {}
        self.mono = {}
        self.s = s

    def r(self, px):
        k = int(px * self.s)
        if k not in self.reg:
            self.reg[k] = ImageFont.truetype(REG, k)
        return self.reg[k]

    def b(self, px):
        k = int(px * self.s)
        if k not in self.bold:
            self.bold[k] = ImageFont.truetype(BOLD, k)
        return self.bold[k]

    def m(self, px):
        k = int(px * self.s)
        if k not in self.mono:
            self.mono[k] = ImageFont.truetype(MONO, k)
        return self.mono[k]


# ===========================================================================
# panel mockups
# ===========================================================================
def read_dump(path):
    rows = []
    with open(path, encoding='utf-8') as fh:
        next(fh)
        for line in fh:
            f = line.rstrip('\n').split('\t')
            if len(f) < 13:
                continue
            rows.append({
                'screen': f[0], 'kind': f[1],
                'x': int(float(f[2])), 'y': int(float(f[3])),
                'w': int(float(f[4])), 'h': int(float(f[5])),
                'font': int(float(f[6])), 'color': int(float(f[7])),
                'fill': int(float(f[8])), 'just': int(float(f[9])),
                'thick': int(float(f[10])), 'state': f[11],
                'text': '\t'.join(f[12:]),
            })
    return rows


def draw_panel(rows, screen, title, out, scale, mono_rows, fonts):
    S = scale
    img = Image.new('RGB', (PANEL_W * S, PANEL_H * S), BG)
    d = ImageDraw.Draw(img)

    overflow = []
    # PREFIX, NOT EQUALITY. The main screen's title carries the capture mode after the app's name
    # ('SERIAL DECODE - 8K CAPTURE'), so an exact match selects no rows and renders an empty panel.
    mine = [r for r in rows if r['screen'] == screen or r['screen'].startswith(screen + ' -')]

    vgrad(img, (0, 0, PANEL_W * S, TITLE_H * S), TITLE_TOP, TITLE_BOT)
    # THE BAR SHOWS THE DUMP'S OWN TITLE, not the filter key. The app puts the capture mode up there,
    # so drawing the passed-in `title` would render every mockup with the same bar while the panel
    # showed three different ones -- a mockup that quietly disagrees with the instrument.
    d.text((14 * S, 12 * S), (mine[0]['screen'] if mine else title),
           font=fonts.b(21), fill=(255, 255, 255))
    # The firmware draws End App itself; it is not one of the app's objects.
    d.rounded_rectangle([686 * S, 7 * S, 792 * S, 41 * S], radius=6 * S,
                        fill=(122, 82, 24), outline=(168, 123, 44), width=max(1, S))
    d.text((700 * S, 14 * S), 'End App', font=fonts.b(16), fill=(255, 255, 255))
    # THE RIGHT-MARGIN BUTTON COLUMN, found from the dump itself: any button sitting beside the dump
    # rather than in the bottom row. A dump row that reaches it is invisible from there rightwards.
    mbtn = [r for r in mine if r['kind'] == 'button' and r['y'] + BUTTON_H <= DUMP_Y1 + BUTTON_H
            and r['y'] < DUMP_Y1]
    marginx = min((r['x'] for r in mbtn), default=None)
    marginy1 = max((r['y'] + BUTTON_H for r in mbtn), default=0)
    # A PANEL WITH NO OBJECTS IS A BROKEN RENDER, NOT AN EMPTY SCREEN. The title bar is drawn above
    # unconditionally, so a filter that matches nothing still produces a plausible-looking PNG -- and
    # that is how a screen-name mismatch went unnoticed. Raise instead: every scenario here builds a
    # panel with dozens of objects, so zero can only mean the filter is wrong.
    if not mine:
        names = sorted({r['screen'] for r in rows})
        raise SystemExit('render_png: no objects for screen %r in this dump -- it holds %s'
                         % (screen, ', '.join(repr(n) for n in names) or 'nothing'))

    # Header field strip: the value row is a set of fixed columns, so a value that
    # outgrows its column collides with the next rather than wrapping. Collect the
    # x positions of that row so each value can be measured against its neighbour.
    colx = sorted(r['x'] for r in mine if r['kind'] == 'text' and r['y'] == 18)

    for r in mine:
        y = (r['y'] + TITLE_H) * S
        x = r['x'] * S

        if r['kind'] == 'rect':
            # AN OBJ_RECT IS DRAWN AS ITS BORDER, not as a filled block, and setfill's percentage
            # does nothing to it: on the panel a 64 x 14 rect at setfill(100) lights its 137-pixel
            # perimeter and nothing inside. Drawing rects SOLID here shows the options form with
            # 480 px wide field boxes the instrument renders at 150, and makes a progress bar that
            # draws nothing at all on the glass look correct.
            #
            # EVERY RECT IS DRAWN, setfill or not, because setfill is not what makes one visible --
            # its colour is. A skip-if-never-filled rule leaves the progress bar's frame off the
            # mockup entirely while the instrument drew it, which is the same class of lie in the
            # other direction.
            #
            # THE COLOUR IS THE color COLUMN, NOT THE fill COLUMN. It was the fill column for as long
            # as a 24-bit colour passed to display.setfill is refused by the instrument while this
            # line renders it faithfully -- making the mockups the only place that colour appears.
            # rgb(100) is (0, 0, 100), a dark blue, which is what every rule looks like here if the
            # percentage is not honoured.
            wpx, hpx = r['w'] * S, r['h'] * S
            # A rect 1 or 2 px on either axis has no interior, so border and block are the same
            # pixels -- which is every rule, and the only reason the panel looks the way it does.
            if r['w'] <= 2 or r['h'] <= 2:
                d.rectangle([x, y, x + wpx, y + hpx], fill=rgb(r['color']))
            else:
                d.rectangle([x, y, x + wpx, y + hpx], outline=rgb(r['color']),
                            width=max(1, S) * r['thick'])

        elif r['kind'] == 'line':
            # A THICK LINE IS THE ONLY SOLID BAR THIS FIRMWARE DRAWS -- see ui_progbar_set. w/h in
            # the dump are derived from the endpoints, so the far end comes back from them.
            x2 = (r['x'] + r['w'] - 1) * S
            y2 = (r['y'] + r['h'] - 1 + TITLE_H) * S
            d.line([x, y, x2, y2], fill=rgb(r['color']), width=max(1, S) * r['thick'])

        elif r['kind'] == 'text':
            px = FONT_MEDIUM if r['font'] == 2 else FONT_SMALL
            # Dump rows start at ui_row_y0 = 66, not 90: a bound at 90 renders the first two rows
            # in the proportional face while the rest are monospace.
            f = fonts.m(px - 1) if (mono_rows and r['y'] >= 62 and r['y'] < 330) \
                else fonts.r(px)
            # JUSTIFICATION IS HONOURED, because the app uses it. A JUST_RIGHT object's x is its
            # RIGHT edge, so drawing it left-anchored -- which is what this did before the dump
            # carried `just` -- puts it a whole string-width away from where the instrument shows it,
            # and the overflow check below then measures the wrong edge too.
            wpx = d.textlength(r['text'], font=f) / S
            xl = r['x']
            if r['just'] == 2:                     # display.JUST_RIGHT
                xl = r['x'] - wpx
            elif r['just'] == 1:                   # display.JUST_CENTER
                xl = r['x'] - wpx / 2
            d.text((xl * S, y), r['text'], font=f, fill=rgb(r['color']))
            if xl + wpx > 798:
                overflow.append((r['text'][:46], round(xl + wpx), 'past 798 px'))
            # AND AGAINST THE RIGHT-MARGIN BUTTONS, not just the panel edge. A dump row that runs
            # under Page Up is invisible while still being counted by the page arithmetic, so paging
            # steps over bytes nobody saw -- and checking only 798 px could not see it.
            if marginx is not None and DUMP_Y0 <= r['y'] <= DUMP_Y1 and xl < marginx \
                    and xl + wpx > marginx:
                overflow.append((r['text'][:46], round(xl + wpx),
                                 f'runs under the margin buttons at {marginx}'))
            if r['y'] == 18 and r['x'] in colx:
                nxt = [c for c in colx if c > r['x']]
                if nxt and r['x'] + wpx > nxt[0] - 4:
                    overflow.append((r['text'][:46], round(r['x'] + wpx),
                                     f'collides with the column at {nxt[0]}'))

        elif r['kind'] == 'button':
            bw = r['w'] * S
            vgrad(img, (x, y, x + bw, y + BUTTON_H * S), BTN_TOP, BTN_BOT)
            d.rectangle([x, y, x + bw, y + BUTTON_H * S], outline=BTN_EDGE,
                        width=max(1, S))
            f = fonts.b(17)
            tw = d.textlength(r['text'], font=f)
            d.text((x + (bw - tw) / 2, y + 18 * S), r['text'], font=f, fill=BTN_TEXT)

        elif r['kind'] == 'editcheck':
            # A check object draws its label and description to the left like every other edit
            # object, but the control itself is a tick box rather than a value field -- so it is
            # drawn narrow. The box is the actual control; the wide field the others use would
            # misrepresent how much of the row is touchable.
            parts = r['text'].split('\t')
            label = parts[0] if parts else ''
            desc = parts[1] if len(parts) > 1 else ''
            on = (parts[2] if len(parts) > 2 else 'OFF') == 'ON'
            d.text((20 * S, y + 2 * S), label, font=fonts.b(15), fill=(232, 240, 255))
            d.text((20 * S, y + 20 * S), desc, font=fonts.r(12), fill=(138, 153, 168))
            bx = 30 * S
            d.rounded_rectangle([x, y + 4 * S, x + bx, y + 4 * S + bx], radius=3 * S,
                                fill=(14, 22, 32), outline=(74, 96, 118), width=max(1, S))
            if on:
                # A tick, drawn as two strokes.
                d.line([(x + 7 * S, y + 18 * S), (x + 13 * S, y + 25 * S)],
                       fill=(0, 220, 255), width=max(2, 2 * S))
                d.line([(x + 13 * S, y + 25 * S), (x + 24 * S, y + 9 * S)],
                       fill=(0, 220, 255), width=max(2, 2 * S))

        elif r['kind'] in ('editnum', 'editopt'):
            parts = r['text'].split('\t')
            label = parts[0] if parts else ''
            desc = parts[1] if len(parts) > 1 else ''
            val = parts[2] if len(parts) > 2 else ''
            d.text((20 * S, y + 2 * S), label, font=fonts.b(15), fill=(232, 240, 255))
            d.text((20 * S, y + 20 * S), desc, font=fonts.r(12), fill=(138, 153, 168))
            d.rounded_rectangle([x, y, x + 480 * S, y + 38 * S], radius=4 * S,
                                fill=(14, 22, 32), outline=(74, 96, 118),
                                width=max(1, S))
            d.text((x + 12 * S, y + 9 * S), val, font=fonts.r(16), fill=(0, 220, 255))

    img.save(out)
    return out, img.size, overflow


def cmd_panel(args):
    out = os.path.expanduser(args.outdir)
    os.makedirs(out, exist_ok=True)
    fonts = Fonts(args.scale)

    # THE MAIN SCREEN'S NAME, WHICH IS ALSO THE ROW FILTER (draw_panel keys on it) -- so it must be
    # the app's own sdec.ui_title and nothing else.
    #
    # A literal here goes stale silently in BOTH directions. While the committed .tsv dumps carry the
    # same stale name, rendering from them matches and looks fine -- and draws a title bar the
    # instrument does not show. Re-running `lua tools/mockup.lua` (the documented first step) rewrites
    # them with the real name, after which the filter matches NOTHING and every main-screen panel
    # renders EMPTY, reporting success and a size.
    MAIN = 'SERIAL DECODE'

    # mono=True renders the dump area in a fixed-pitch font, which is what the hex, MIDI
    # and LIN views rely on for their columns to line up. The text view and the streaming
    # views are proportional.
    jobs = [
        ('docs/mockup-objects-text.tsv', MAIN, 'mockup-main-text', False),
        ('docs/mockup-objects-hex.tsv', MAIN, 'mockup-main-hex', True),
        ('docs/mockup-objects-midi.tsv', MAIN, 'mockup-main-midi', True),
        ('docs/mockup-objects-lin.tsv', MAIN, 'mockup-main-lin', True),
        ('docs/mockup-objects-opts.tsv', 'SERIAL DECODE OPTIONS', 'mockup-options', False),
        ('docs/mockup-objects-opts-ext.tsv', 'SERIAL DECODE OPTIONS',
         'mockup-options-ext', False),
        # The three capture modes, five states. stream-done matters most for layout: its
        # five-digit BYTES value is what the header table was widened to hold, so a LAYOUT
        # warning there means the widening was not enough.
        ('docs/mockup-objects-frame-log.tsv', MAIN,
         'mockup-mode-frame-log', False),
        ('docs/mockup-objects-frame-exttrig.tsv', MAIN,
         'mockup-trig-ext', False),
        ('docs/mockup-objects-frame-nolock.tsv', MAIN,
         'mockup-lock-none', False),
        ('docs/mockup-objects-frame-locked.tsv', MAIN,
         'mockup-lock-locked', False),
        ('docs/mockup-objects-stream-arm.tsv', MAIN,
         'mockup-mode-stream-arm', False),
        ('docs/mockup-objects-stream-run.tsv', MAIN,
         'mockup-mode-stream-run', False),
        ('docs/mockup-objects-stream-done.tsv', MAIN,
         'mockup-mode-stream-done', False),
        ('docs/mockup-objects-stream-gate.tsv', MAIN,
         'mockup-mode-stream-gate', False),
        # THE RESTING STATE AFTER A RECORDING: FRAME, showing the retained tail, paged, with the page
        # counter on the note row. stream-done above cannot show this -- it holds sdec.res at the
        # frame capture, so it renders a single page and the counter stays away.
        ('docs/mockup-objects-stream-tail.tsv', MAIN,
         'mockup-stream-tail', True),
        # THE TWO LOSS REGIMES above the continuous ceiling -- the states that decide whether
        # the app keeps its central promise. Locked 115200 either way; only the rear-BNC
        # flow-control setting differs, and the note line has to say which one you are in.
        ('docs/mockup-objects-fc-losing.tsv', MAIN,
         'mockup-fc-losing', False),
        ('docs/mockup-objects-fc-ok.tsv', MAIN, 'mockup-fc-ok', False),
        # A COMPLETELY FULL hex screen at the CHOSEN geometry: 15 rows, 18 px pitch, 240 bytes.
        # Only the chosen geometry is rendered -- a mockup of a layout the app does not have is the
        # stale-render trap the check below exists for.
        ('docs/mockup-objects-hex15.tsv', MAIN, 'mockup-hex-full', True),
    ]
    missing = [j[0] for j in jobs if not os.path.exists(os.path.join(ROOT, j[0]))]
    if missing:
        raise SystemExit('run `lua tools/mockup.lua` first; missing: ' + ', '.join(missing))

    for tsv, screen, name, mono in jobs:
        rows = read_dump(os.path.join(ROOT, tsv))
        png = os.path.join(out, name + '.png')
        _, size, over = draw_panel(rows, screen, screen, png, args.scale, mono, fonts)
        print(f'{png}   {size[0]}x{size[1]}')
        for txt, end, why in over:
            print(f'    LAYOUT: {txt!r} ends at {end} — {why}')

    # STALE RENDERS ARE REPORTED, because a renamed scenario leaves its old PNG behind and a mockup
    # of a screen that does not exist is worse than a missing one -- it gets believed. Condensing two
    # modes into one is enough to do it: the retired mode's PNG stays in both output directories.
    want = {j[2] + '.png' for j in jobs} | {'lin-divider.png'}
    for f in sorted(os.listdir(out)):
        if f.startswith('mockup-') and f.endswith('.png') and f not in want:
            print(f'    STALE: {os.path.join(out, f)} has no scenario -- delete it')

    idx = os.path.join(out, 'index.html')
    with open(idx, 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html><meta charset="utf-8">'
                 '<title>DMM6500 serial decode mockups</title>'
                 '<style>body{background:#0d0f12;color:#c8d2dc;margin:32px;'
                 'font:14px/1.5 -apple-system,Helvetica,Arial,sans-serif}'
                 'h1{font-size:20px}h2{font-size:15px;color:#8fa8bf;margin-top:28px}'
                 'img{border:1px solid #2a333d;display:block;width:800px}'
                 'p{max-width:800px;color:#93a1af}</style>'
                 '<h1>DMM6500 serial decode &mdash; panel mockups</h1>'
                 '<p>Rendered at exact panel pixels by <code>tools/render_png.py</code> '
                 'from object dumps recorded while running the real '
                 '<code>tsp/serial_ui.tsp</code>. Shown here at 1:1; the files are 2x.</p>'
                 '<h2>Main screen &mdash; TEXT view</h2>'
                 '<img src="mockup-main-text.png">'
                 '<h2>Main screen &mdash; HEX view</h2>'
                 '<img src="mockup-main-hex.png">'
                 '<h2>Main screen &mdash; MIDI message view</h2>'
                 '<img src="mockup-main-midi.png">'
                 '<h2>Main screen &mdash; LIN frame view</h2>'
                 '<img src="mockup-main-lin.png">'
                 '<h2>Options form &mdash; seven fields</h2>'
                 '<img src="mockup-options.png">'
                 '<h2>Options form &mdash; <code>Ext Trig In</code> ticked</h2>'
                 '<p>Orthogonal to the <code>Trigger</code> field above it: ticked, the rear '
                 'BNC starts a capture <b>in addition</b> to the selected source, via the '
                 'trigger blender\'s OR. Off by default &mdash; the app must work with one '
                 'probe and nothing else attached.</p>'
                 '<img src="mockup-options-ext.png">'
                 '<h1>The padlock &mdash; locked / auto / nothing to lock</h1>'
                 '<p>Drawn from rects (the panel font has no padlock glyph), in the gap '
                 'after the <code>BAUD</code> label. <b>Green</b> = the operator pinned the '
                 'wire parameters, <b>amber</b> = the app worked them out, <b>red</b> = '
                 'nothing decoded, so there is nothing to lock. The three lockable values '
                 'carry the state as a colour too.</p>'
                 '<h2>Amber &mdash; auto-detected</h2>'
                 '<img src="mockup-mode-frame-log.png">'
                 '<h2>Green &mdash; manually locked</h2>'
                 '<img src="mockup-lock-locked.png">'
                 '<h2>Red &mdash; nothing decoded</h2>'
                 '<img src="mockup-lock-none.png">'
                 '<h1>Trigger source, shown by exception</h1>'
                 '<p>The default (start-bit edge on the signal itself) says nothing. Anything '
                 'that can <b>wait for something external</b> names itself in the status row\'s '
                 'right-hand cell and turns it <b>amber</b> &mdash; because a capture waiting on '
                 'an edge that never arrives is otherwise indistinguishable from a hang.</p>'
                 '<img src="mockup-trig-ext.png">'
                 '<h1>The three capture modes</h1>'
                 '<p><code>Mode</code> cycles FRAME / 32&nbsp;kB / STREAM. The <b>MODE cell '
                 'top-left is coloured per mode</b> &mdash; grey, amber, green &mdash; which '
                 'is the at-a-glance channel; the status row names it in words. '
                 '<code>Capture</code> starts all three and is Stop while one runs; '
                 '<code>Mode</code> aborts and returns to FRAME, flushing files.</p>'
                 '<h2>FRAME &mdash; capture, show, and append to the message log</h2>'
                 '<img src="mockup-mode-frame-log.png">'
                 '<h2>32 kB &mdash; armed, waiting for Capture</h2>'
                 '<img src="mockup-mode-stream-arm.png">'
                 '<h2>32 kB &mdash; recording (percent of buffer; both controls named)</h2>'
                 '<img src="mockup-mode-stream-run.png">'
                 '<h2>32 kB &mdash; finished at the cap</h2>'
                 '<img src="mockup-mode-stream-done.png">'
                 '<h2>STREAM &mdash; refused, because the baud rate is not locked</h2>'
                 '<img src="mockup-mode-stream-gate.png">'
                 '<h1>Reference</h1>'
                 '<h2>LIN divider (799x400, as shown on the instrument)</h2>'
                 '<img src="lin-divider.png">')
    print(idx)
    return 0


# ===========================================================================
# LIN divider schematic, sized for the instrument's own screen
# ===========================================================================
# 799 wide, not 800: display.create rejects a width of 800 ("1130 Parameter width,
# expected value from 1 to 799") and returns nil rather than raising, so an 800 px
# OBJ_IMAGE would silently fail to exist.
SCH_W, SCH_H = 799, 400

WIRE = (255, 255, 255)
ACCENT = (0, 220, 255)
DIM = (150, 150, 150)
FAINT = (110, 110, 110)


def zigzag_h(d, x0, x1, y, colour, wid, amp=11):
    """Resistor, horizontal. Lead, six alternating segments, lead."""
    seg = (x1 - x0 - 20) / 6.0
    pts = [(x0, y), (x0 + 10, y)]
    xx = x0 + 10
    for i in range(6):
        xx += seg
        pts.append((xx, y - amp if i % 2 == 0 else y + amp))
    pts[-1] = (xx, y)
    pts.append((x1, y))
    d.line(pts, fill=colour, width=wid, joint='curve')


def zigzag_v(d, y0, y1, x, colour, wid, amp=11):
    seg = (y1 - y0 - 20) / 6.0
    pts = [(x, y0), (x, y0 + 10)]
    yy = y0 + 10
    for i in range(6):
        yy += seg
        pts.append((x - amp if i % 2 == 0 else x + amp, yy))
    pts[-1] = (x, yy)
    pts.append((x, y1))
    d.line(pts, fill=colour, width=wid, joint='curve')


def cmd_schematic(args):
    out = os.path.expanduser(args.outdir)
    os.makedirs(out, exist_ok=True)
    S = args.scale
    fonts = Fonts(S)
    img = Image.new('RGB', (SCH_W * S, SCH_H * S), (0, 0, 0))
    d = ImageDraw.Draw(img)
    W = max(2, 2 * S)

    def t(x, y, s, f, c, anchor=None):
        d.text((x * S, y * S), s, font=f, fill=c, anchor=anchor)

    # ---- title ----
    # One short line: a subtitle alongside it collides with both the title and the C1 label.
    t(10, 6, 'LIN BUS 2:1 DIVIDER', fonts.b(17), (255, 255, 255))
    t(224, 9, 'automotive 8–18 V bus into the 10 V range', fonts.r(13), DIM)

    # ---- geometry ----
    yt, yg = 108, 250            # top rail, ground rail
    xl, xr = 62, 640             # left terminals, right terminals
    xtap = 330
    xz = 470

    # top rail: LIN -> R1 -> tap -> HI
    d.line([(xl * S, yt * S), (150 * S, yt * S)], fill=WIRE, width=W)
    zigzag_h(d, 150 * S, 250 * S, yt * S, WIRE, W, 11 * S)
    d.line([(250 * S, yt * S), (xr * S, yt * S)], fill=WIRE, width=W)

    # C1 in parallel with R1
    d.line([(150 * S, yt * S), (150 * S, 58 * S), (188 * S, 58 * S)], fill=DIM, width=W)
    d.line([(212 * S, 58 * S), (250 * S, 58 * S), (250 * S, yt * S)], fill=DIM, width=W)
    d.line([(192 * S, 40 * S), (192 * S, 76 * S)], fill=DIM, width=max(3, 3 * S))
    d.line([(208 * S, 40 * S), (208 * S, 76 * S)], fill=DIM, width=max(3, 3 * S))

    # R2 from tap to ground
    d.line([(xtap * S, yt * S), (xtap * S, 150 * S)], fill=WIRE, width=W)
    zigzag_v(d, 150 * S, 218 * S, xtap * S, WIRE, W, 11 * S)
    d.line([(xtap * S, 218 * S), (xtap * S, yg * S)], fill=WIRE, width=W)

    # No transient clamp: the meter's own input protection covers any realistic
    # automotive transient, and R1 already limits the current to under 1 mA.

    # ground rail
    d.line([(xl * S, yg * S), (xr * S, yg * S)], fill=WIRE, width=W)

    # ---- nodes ----
    for (cx, cy, rr, col) in ((xl, yt, 5, WIRE), (xl, yg, 5, WIRE), (xr, yt, 5, WIRE),
                              (xr, yg, 5, WIRE), (xtap, yt, 4, WIRE)):
        d.ellipse([(cx - rr) * S, (cy - rr) * S, (cx + rr) * S, (cy + rr) * S], fill=col)

    # ---- labels ----
    t(xl - 12, yt - 20, 'LIN', fonts.b(15), (255, 255, 255), anchor='ra')
    t(xl - 12, yt + 4, 'bus', fonts.r(12), DIM, anchor='ra')
    t(xl - 12, yg - 20, 'GND', fonts.b(15), (255, 255, 255), anchor='ra')
    t(xl - 12, yg + 4, 'batt −', fonts.r(12), DIM, anchor='ra')

    t(xr + 14, yt - 18, 'DMM  HI', fonts.b(15), (255, 255, 255))
    t(xr + 14, yt + 2, 'front', fonts.r(12), DIM)
    t(xr + 14, yg - 18, 'DMM  LO', fonts.b(15), (255, 255, 255))
    t(xr + 14, yg + 2, 'one bond only', fonts.r(11), DIM)

    t(200, yt + 24, 'R1', fonts.b(15), (255, 255, 255), anchor='ma')
    t(200, yt + 44, '47 kΩ  1 %', fonts.r(14), ACCENT, anchor='ma')
    t(268, 42, 'C1   5–30 pF trimmer', fonts.r(13), DIM)
    t(268, 60, 'optional — see below', fonts.r(11), FAINT)

    t(xtap - 22, 160, 'R2', fonts.b(15), (255, 255, 255), anchor='ra')
    t(xtap - 22, 180, '47 kΩ  1 %', fonts.r(14), ACCENT, anchor='ra')
    t(xtap - 22, 200, 'match R1', fonts.r(11), DIM, anchor='ra')

    # Worked values at the tap.
    t(xz - 4, 138, 'AT THE TAP', fonts.b(13), (255, 255, 255))
    t(xz - 4, 160, '12 V bus', fonts.r(13), DIM)
    t(xz + 78, 160, '6.0 V', fonts.r(13), ACCENT)
    t(xz - 4, 180, '18 V bus', fonts.r(13), DIM)
    t(xz + 78, 180, '9.0 V', fonts.r(13), ACCENT)
    t(xz - 4, 202, 'swing halves; the', fonts.r(11), FAINT)
    t(xz - 4, 216, 'decoder only needs', fonts.r(11), FAINT)
    t(xz - 4, 230, 'the edges.', fonts.r(11), FAINT)

    t(xtap + 12, yt - 20, 'tap', fonts.r(12), DIM)

    # ---- notes ----
    d.line([(10 * S, 276 * S), ((SCH_W - 10) * S, 276 * S)], fill=(48, 48, 48),
           width=max(1, S))
    left = [
        '2:1 covers any automotive bus: 8 V reads 4 V,',
        '18 V reads 9 V — both inside the ±10 V range.',
        'Load 94 kΩ. The master’s 1 kΩ pull-up holds the',
        'recessive level, so droop is about 1 %. Do NOT',
        'go below 20 kΩ per leg — on a slave-only segment',
        '(30 kΩ pull-up) recessive would read as dominant.',
    ]
    right = [
        'Use the 10 V range. Bond DMM LO to battery − at',
        'ONE point; the front terminals float.',
        'C1 only if edges look rounded — trim against a',
        '10 kHz square wave, as for a scope probe.',
        'No clamp needed: 1000 V DC / 750 V AC rated, with',
        '1100 V peak input protection; R1 caps it at 1 mA.',
    ]
    for i, s in enumerate(left):
        t(14, 284 + i * 18, s, fonts.r(13), (215, 215, 215))
    for i, s in enumerate(right):
        t(408, 284 + i * 18, s, fonts.r(13), (215, 215, 215))

    png = os.path.join(out, 'lin-divider.png')
    img.save(png)
    print(f'{png}   {img.size[0]}x{img.size[1]}')

    # A 1:1 copy lives in docs/ because it is what gets embedded in the .tspa.
    if S != 1:
        one = img.resize((SCH_W, SCH_H), Image.LANCZOS)
    else:
        one = img
    panel = os.path.join(ROOT, 'docs', 'lin-divider-panel.png')
    one.save(panel, optimize=True)
    print(f'{panel}   {one.size[0]}x{one.size[1]}   '
          f'{os.path.getsize(panel)} bytes (embeds in the .tspa as base64)')
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p1 = sub.add_parser('panel')
    p1.add_argument('--outdir', default='~/tmp')
    p1.add_argument('--scale', type=int, default=2)
    p1.set_defaults(fn=cmd_panel)
    p2 = sub.add_parser('schematic')
    p2.add_argument('--outdir', default='~/tmp')
    p2.add_argument('--scale', type=int, default=2)
    p2.set_defaults(fn=cmd_schematic)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())

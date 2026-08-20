#!/usr/bin/env python3
"""Package the serial protocol decoder as a single .tspa TTI App for the DMM6500.

Concatenates the TSP modules into one `loadscript` wrapper with an App manifest, an
auto-start entry point and an embedded base64 PNG icon -- matching the layout of the
Keithley example .tspa apps (loadscript / -- $manifest / endscript, then
loadimage / <base64> / endimage).

The modules are script BODIES: each populates the single `sdec` table (plus `ulog`,
deliberately shared with other apps), so opening the App runs the concatenated
definitions and then sdec.start().

MODULE ORDER MATTERS at load time only for `sdec = sdec or {}`, which every module
opens with, so any order works -- but usb_log goes first because serial_app calls
ulog.line() during start(), and serial_app goes last because it is the entry point.

Usage:  python3 tools/package_tspa.py [--out PATH]
"""
import argparse
import base64
import os

# Strip whole-line comments from the packaged archive (not from the source).
STRIP_COMMENTS = True
# Comment lines kept above each definition in the archive: at least one, never more than this.
KEEP_COMMENT_LINES = 5
import re
import struct
import textwrap
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = 'Serial_Decode'         # internal script name (loadscript <NAME>)
ICON = 'sdec_icon'             # icon name (matches -- $Icon and loadimage)
AUTHOR = 'Ian Ameline'
YEAR = '2026'
# chunk_decode.tsp IS included, because the Mode button reaches it: the streaming modes are a
# feature the operator can press, so the code that serves them ships. It is 13 % of the archive.
#
# serial_app.tsp guards on `sdec.ck_run == nil` and refuses with a reason, the same way the protocol
# views degrade when a protocol module is absent. Removing this line must produce an app that says
# what is missing, not one that raises inside a touch handler.
# VERSION 1 IS UART ONLY. midi_decode.tsp and lin_decode.tsp are complete, tested and
# deliberately NOT SHIPPED: one protocol is the simpler first release, and the LIN
# checksum has never been checked against a real frame (notes/FINDINGS.md), so shipping
# it would ship an unverified decode. Re-adding either is exactly this line -- the app
# discovers what it has at runtime rather than being told:
#
#   sdec.ui_view_avail()   hides the MIDI and LIN views, so the View button never lands
#                          on a list that could only ever be empty
#   sdec.opt_proto_list()  builds the Options > Protocol field from the modules present,
#                          so it cannot offer a protocol with no parser behind it
#
# Both ask sdec for the parse function by name at the point of use, so neither depends on
# module load order -- which matters because the offline harnesses load in a different
# order from the app and DO load the protocol modules.
MODULES = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
           'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp',
           'tsp/serial_app.tsp']

# A MODULE-LEVEL CONSTANT NEITHER CONSUMES A DOC BLOCK NOR DESTROYS ONE. Constants sit between a block
# and the function it describes -- the odd-multiple gate's 25 lines, then two assignments, then
# ua_submultiple -- so flushing at an assignment ships all three bare. Treating every assignment as a
# definition instead costs +51 kB of archive, measured, because these modules are full of them.
# Passing through costs nothing and leaves the block immediately above the function its constants tune.
DEF_ASSIGN = re.compile(r'^(sdec|ulog)\.[A-Za-z_][A-Za-z0-9_]*\s*=')
# A rule, a bare '--', or a row of ='s carries no text, so it must not spend a line of the keep budget
# -- otherwise a section banner arrives as a definition's entire first kept line.
SEPARATOR = re.compile(r'^--\s*[=\-~*_]*\s*$')


def is_definition(stripped):
    return (stripped.startswith('function ') or stripped.startswith('local function ')
            or ' = function' in stripped)


def doc_for(block):
    """The lines of one comment block worth shipping above its definition.

    HEAD FIRST, THEN THE TAIL, because both block shapes exist here. 64 of 222 documented definitions
    are summary-FIRST, so keeping only the tail starts them mid-sentence and sometimes mid-word; a
    block's first line always starts a sentence, so keeping it cannot truncate that way. Keeping the
    tail too retains the closing summary where a block has one, and `[...]` marks the elision rather
    than letting two distant fragments read as continuous prose.
    """
    body = [c for c in block if not SEPARATOR.match(c.strip())]
    if len(body) <= KEEP_COMMENT_LINES:
        return body
    lead = body[0]
    indent = lead[:len(lead) - len(lead.lstrip())]
    return [lead] + [indent + '--   [...]'] + body[-(KEEP_COMMENT_LINES - 2):]

MANIFEST = [
    ('Title', 'Serial Protocol Decode'),
    ('Product', 'DMM6500'),
    # No MIDI or LIN in the tag or the description: version 1 does not ship them, and an
    # app store entry promising a protocol the build cannot decode is the same dead control
    # as an Options field offering it.
    ('Tag', 'Serial, UART, Decode, Digitize'),
    ('Description', 'BETA. Decodes an asynchronous serial line with the instrument\'s own '
                    'digitizer: recovers baud rate, frame format and bytes, shows '
                    'them as text or hex, streams every byte to a USB key, and '
                    'saves the capture. Everything auto-detects; everything can be '
                    'locked down.'),
    # MATCHES THE GIT TAG, and stays a plain dotted number. This string goes into a manifest an
    # instrument installer parses and whose compares cannot be assumed numeric, so the version must
    # never carry a pre-release suffix -- '1.0-beta' could fail a parse or sort anywhere. The word
    # "beta" lives in the Description instead, which is free text the Manage Apps screen shows. As
    # STRINGS, every release sorts above the last ('1.04' > '1.03' > '1.02' > '0.9'), so an upgrade is
    # never read as a downgrade -- and two digits after the dot is what keeps that true, because
    # '1.4' sorts BELOW '1.03'.
    ('Version', '1.04'),
    # Stated minimum firmware, kept deliberately low: if the installer compares this
    # field as a STRING then "1.7.3c" sorts above "1.7.17a" and the app refuses to
    # install on the very unit it is developed on. "1.7.0" satisfies either compare.
    ('Requires', '1.7.0'),
    ('Author', AUTHOR),
    ('License', 'MIT'),
    ('Icon', ICON),
]

# THE FULL PERMISSION NOTICE, not just the SPDX tag. MIT requires the notice to accompany the
# software, and the .tspa is the whole distributable -- it installs off a USB key onto an
# instrument with no filesystem the recipient reads, so there is nowhere else for a LICENSE file
# to live. Emitted as Lua line comments, since the archive body is a Lua chunk.
LICENSE = '''
-- ============================================================================
-- Serial Protocol Decode -- a UART decoder for the Keithley DMM6500
--
-- Copyright (c) %s %s
--
-- SPDX-License-Identifier: MIT
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
-- ============================================================================
''' % (YEAR, AUTHOR)

# THESE COMMENTS ARE LUA, NOT PYTHON. This string is emitted verbatim into the .tspa, so
# '#' here is a syntax error on the instrument -- Lua 5.0 has no '#' operator at all, and
# verify_tspa.lua catches it as "unexpected symbol near '#'" at the bundle's line number.
ENTRY = '''
-- ==================== TTI App entry point ====================
-- sdec.start() opens the USB log, builds both screens, hooks End App
-- (EVENT_ENDAPP -> sdec.cleanup) as soon as the main screen exists, then takes a first
-- capture -- all under pcall, so a failure part-way through tears its own display
-- objects back down instead of stranding them until the next power cycle.
sdec.start()
'''

# ===========================================================================
# icon
# ===========================================================================
# CONDENSED 4x7 capitals for the label, 3x5 digits for the background field.
#
# 4 columns rather than 5 on purpose. Six characters have to fit across 60 px, so the
# label's width is fixed and the only free choice is how to spend it -- and one column
# narrower per glyph buys a glyph-pixel 2 final px thick instead of 1.6, which is the
# difference between strokes that survive the downsample and strokes that go muddy.
CAPS = {
    'D': ["1110", "1001", "1001", "1001", "1001", "1001", "1110"],
    'E': ["1111", "1000", "1000", "1110", "1000", "1000", "1111"],
    'C': ["0111", "1000", "1000", "1000", "1000", "1000", "0111"],
    'O': ["0110", "1001", "1001", "1001", "1001", "1001", "0110"],
}
DIGITS = {
    '0': ["111", "101", "101", "101", "111"],
    '1': ["010", "110", "010", "010", "111"],
}


def png_icon(W=60, H=60):
    """RGB PNG (pure stdlib): a field of random green 0s and 1s with 'DECODE' in
    magenta over it, rendered at 8x and box-downsampled so the edges are anti-aliased.
    """
    SS = 8                               # supersample; box-downsampled below -> AA
    HW, HH = W * SS, H * SS
    hi = bytearray(HW * HH * 3)          # black background, at SSx

    def hset(x, y, r, g, b):
        if 0 <= x < HW and 0 <= y < HH:
            i = (y * HW + x) * 3
            hi[i], hi[i + 1], hi[i + 2] = r, g, b

    def blit(glyph, gw, gh, x0, y0, s, colour, into=None):
        """Draw a bitmap glyph at glyph-pixel size s. Collects into `into` if given,
        so the label can be haloed before it is painted."""
        for ry in range(gh):
            for rx in range(gw):
                if glyph[ry][rx] == '1':
                    for sy in range(s):
                        for sx in range(s):
                            px, py = x0 + rx * s + sx, y0 + ry * s + sy
                            if into is None:
                                hset(px, py, colour[0], colour[1], colour[2])
                            else:
                                into.add((px, py))

    # ---- background: a grid of green 0s and 1s ----
    # Deterministic LCG rather than `random`, so the icon is byte-identical on every
    # build and a rebuild does not churn the base64 block in the .tspa.
    seed = 0x5EED
    def rnd():
        nonlocal seed
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        return seed / 0x7FFFFFFF

    ds = 1 * SS                          # digit glyph-pixel size -> 3x5 px digits
    cw, ch = 4 * SS, 6 * SS              # cell pitch, one px of gap each way
    for cy in range(0, HH, ch):
        for cx in range(0, HW, cw):
            ch_ = '1' if rnd() < 0.5 else '0'
            # Brightness varies per digit for a data-rain look; the dimmest still reads
            # as green rather than as noise once it is downsampled.
            g = int(110 + 145 * rnd())
            blit(DIGITS[ch_], 3, 5, cx, cy, ds, (0, g, 40))

    # ---- label: DECODE in magenta, with a black halo so it reads over the field ----
    text = 'DECODE'
    s, gap = 16, 8                       # 16 hi-res px per glyph pixel = 2 final px
    gw = 4 * s
    total_w = len(text) * gw + (len(text) - 1) * gap
    x0, y0 = (HW - total_w) // 2, (HH - 7 * s) // 2
    lit, cx = set(), x0
    for chn in text:
        blit(CAPS[chn], 4, 7, cx, y0, s, None, into=lit)
        cx += gw + gap
    # A 2 px halo reads as a black box at this size; 1.5 px keeps the letters legible
    # against the green field without walling them off from it.
    halo = 12
    for (x, y) in lit:
        for dx in range(-halo, halo + 1):
            for dy in range(-halo, halo + 1):
                if (x + dx, y + dy) not in lit:
                    hset(x + dx, y + dy, 0, 0, 0)
    for (x, y) in lit:
        hset(x, y, 255, 0, 255)

    # ---- box-downsample each SSxSS block to one pixel -> anti-aliased W x H ----
    img = bytearray(W * H * 3)
    n = SS * SS
    for oy in range(H):
        for ox in range(W):
            r = g = b = 0
            for dy in range(SS):
                base = ((oy * SS + dy) * HW + ox * SS) * 3
                for dx in range(SS):
                    k = base + dx * 3
                    r += hi[k]; g += hi[k + 1]; b += hi[k + 2]
            j = (oy * W + ox) * 3
            img[j], img[j + 1], img[j + 2] = r // n, g // n, b // n

    raw = bytearray()
    for y in range(H):
        raw.append(0)                       # filter byte per scanline
        raw.extend(img[y * W * 3:(y + 1) * W * 3])

    def chunk(typ, data):
        return (struct.pack('>I', len(data)) + typ + data
                + struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))  # 8-bit RGB
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    return png


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, NAME + '.tspa'))
    ap.add_argument('--icon-png', default=os.path.join(ROOT, 'docs', 'sdec_icon.png'),
                    help='also write the icon on its own, for review')
    args = ap.parse_args()

    out = []
    out.append('loadscript ' + NAME)
    for k, v in MANIFEST:
        out.append('-- $%s: %s' % (k, v))
    out.append('')
    # The notice goes FIRST in the body, ahead of every module, so it is the first thing in the
    # file after the manifest the installer reads.
    for ln in LICENSE.strip('\n').split('\n'):
        out.append(ln)
    out.append('')

    nlines, nstripped = 0, 0
    for m in MODULES:
        out.append('-- ================= %s =================' % m)
        with open(os.path.join(ROOT, m)) as f:
            src = f.read()
        # REFUSE TO BUILD RATHER THAN SHIP AN UNTERMINATED COMMENT. Every rule here treats a '--' line
        # as a whole-line comment it may keep or drop freely. A Lua LONG comment breaks that: keeping
        # '--[[' while dropping '--]]' comments out the rest of the module, and the only symptom would be
        # an archive that fails to load on the instrument. No module uses one today, so this costs
        # nothing, and an archive that will not load is worth a build error rather than a guess.
        for delim in ('--[[', '--]]', '--[=['):
            if delim in src:
                raise SystemExit('%s contains a Lua long comment (%s); the comment rules here only '
                                 'handle whole-line comments -- convert it to -- lines' % (m, delim))
        body = src.split('\n')
        # BLOCKS, NOT ONE FLAT LIST. Accumulating comment runs across blank lines and taking the keep
        # window over the concatenation ships a definition lines from a block describing something
        # else -- `ck_reader_table` gets a micro-optimisation note, `clear_result` a field list. Only
        # the block ADJACENT to the definition is its doc.
        blocks, cur, carried = [], [], False
        for ln in body:
            ln = ln.rstrip('\r')
            stripped = ln.lstrip()
            if STRIP_COMMENTS and stripped.startswith('--'):
                # Held back rather than emitted or dropped yet: whether a comment is worth shipping
                # depends on what FOLLOWS it.
                cur.append(ln)
                continue
            if cur:
                blocks.append(cur)
                cur, carried = [], False
            # A BLANK LINE DOES NOT END THE ASSOCIATION. Many blocks here are separated from the
            # function they describe by one blank line, and treating that as a break left 40 of 183
            # functions with no comment at all in the archive. Once a constant has been CARRIED past,
            # though, the blank lines between those constants are ordinary layout and must survive --
            # swallowing them ran sdec.probe_nbits, ratemargin and qgate together into one block.
            if STRIP_COMMENTS and blocks and stripped == '':
                if not carried:
                    continue
            elif STRIP_COMMENTS and blocks:
                if DEF_ASSIGN.match(stripped):
                    carried = True
                elif is_definition(stripped):
                    keep = doc_for(blocks[-1])
                    nstripped += sum(len(b) for b in blocks) - len(keep)
                    out.extend(keep)
                    blocks, carried = [], False
                else:
                    nstripped += sum(len(b) for b in blocks)
                    blocks, carried = [], False
            out.append(ln)
        nstripped += sum(len(b) for b in blocks) + len(cur)
        nlines += len(body)
        out.append('')

    for ln in ENTRY.strip('\n').split('\n'):
        out.append(ln)
    out.append('endscript')

    icon = png_icon()
    b64 = base64.b64encode(icon).decode('ascii')
    out.append('loadimage %s %s' % (ICON, NAME))
    out.extend(textwrap.wrap(b64, 76))
    out.append('endimage')

    text = '\r\n'.join(out) + '\r\n'        # CRLF, like the Keithley examples
    with open(args.out, 'w', newline='') as f:
        f.write(text)

    if args.icon_png:
        with open(args.icon_png, 'wb') as f:
            f.write(icon)

    print('wrote %s' % args.out)
    print('  %d bytes, %d lines   script: %s   icon: %s (%d bytes PNG)'
          % (len(text), len(out), NAME, ICON, len(icon)))
    print('  %d modules, %d lines of TSP' % (len(MODULES), nlines))
    if args.icon_png:
        print('  icon also written to %s' % args.icon_png)


if __name__ == '__main__':
    main()

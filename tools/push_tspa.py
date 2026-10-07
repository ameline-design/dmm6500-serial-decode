#!/usr/bin/env python3
"""Write a .tspa onto the instrument's USB key over the LAN, byte for byte.

WHY NOT JUST loadscript IT. Sending the script over the control socket and calling
scriptVar.save() does put it in internal memory, but it is NOT the same artefact or the
same install path:

  * the firmware STRIPS every '\\r' it receives, so the stored source comes back about
    7 kB smaller than the archive -- fatal when the quantity under test is size
  * the icon after `endscript` is never registered, so the app appears only under
    MENU > Scripts and not under Manage Apps

Writing the file to the key instead leaves the instrument's own installer to do the
install, so a result can be compared with every result obtained by carrying the key
across the room. The only thing this replaces is the walk.

VERIFIED BY READING IT BACK, because a silent short write is the exact failure this
must not have: file.write on this firmware reports a failed write only as a pop-up and
returns success, so the length and the CR/LF counts are compared against the local file
afterwards. READ_ALL is used for that, and only the counts come back over the socket,
never the content.

    python3 tools/push_tspa.py --file ~/tmp/sdec-versions/C_ca93c8f.tspa
    python3 tools/push_tspa.py --file build.tspa --dest /usb1/Serial_Decode.tspa
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM          # noqa: E402

END = '===PUSH-END==='
# The execute path accepts exactly 1024 bytes on a line, terminator included; one more
# raises -363. Everything below budgets against that, with room for the wrapper.
LINE_BUDGET = 1024
WRAP = len('file.write(fh,"")') + 8
SYNC_EVERY = 25


def lua_quote(chunk):
    """A Lua 5.0.2 double-quoted literal for arbitrary bytes."""
    out = []
    for b in chunk:
        if b == 0x5C:
            out.append('\\\\')
        elif b == 0x22:
            out.append('\\"')
        elif b == 0x0A:
            out.append('\\n')
        elif b == 0x0D:
            out.append('\\r')
        elif 32 <= b <= 126:
            out.append(chr(b))
        else:
            # Decimal escape. NOT padded to three digits blindly -- \\ddd stops at three
            # digits, so a following literal digit would be absorbed into the escape.
            out.append('\\%03d' % b)
    return ''.join(out)


def chunks(data, budget):
    """Split so that each chunk's ESCAPED length fits the budget.

    Measured per byte rather than assumed: an escaped byte is 1 to 4 characters, so a
    fixed raw chunk size would overrun the line limit on a run of escapes.
    """
    out, cur, curlen = [], bytearray(), 0
    for b in data:
        esc = len(lua_quote(bytes([b])))
        if curlen + esc > budget and cur:
            out.append(bytes(cur))
            cur, curlen = bytearray(), 0
        cur.append(b)
        curlen += esc
    if cur:
        out.append(bytes(cur))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--dest', default=None,
                    help='path on the instrument; defaults to /usb1/<basename>')
    a = ap.parse_args()

    with open(a.file, 'rb') as fh:
        data = fh.read()
    dest = a.dest or ('/usb1/' + os.path.basename(a.file))
    print('%s -> %s' % (a.file, dest))
    print('  %d bytes, cr=%d lf=%d' % (len(data), data.count(b'\r'), data.count(b'\n')))

    parts = chunks(data, LINE_BUDGET - WRAP)
    print('  %d write statements' % len(parts))

    d = DMM(timeout=120)
    try:
        print(' ', d.q('print(localnode.model, localnode.version)'))
        # HOME FIRST: with a live app's screen in front this socket's statements get refused,
        # and the app's own timer would be touching the same filesystem mid-write.
        d.exec('pcall(function() display.changescreen(display.SCREEN_HOME) end)', timeout=30)
        d.exec('eventlog.clear()', timeout=30)

        # MODE_WRITE truncates, which is what a replacement wants. Opened once and held: one
        # open per chunk would be 600 opens and would also lose the truncation semantics.
        r = d.q('fh = nil pcall(function() fh = file.open("%s", file.MODE_WRITE) end) '
                'print(tostring(fh ~= nil))' % dest, timeout=60)
        if r != 'true':
            raise SystemExit('could not open %s for writing (reply %r)' % (dest, r))

        t0 = time.time()
        for i, part in enumerate(parts):
            d.send('file.write(fh,"%s")' % lua_quote(part))
            if (i + 1) % SYNC_EVERY == 0:
                # SYNCED PERIODICALLY, not fired blind: a few hundred unread statements can
                # overrun the instrument's input buffer, and a sync also gives a progress point
                # that is a real acknowledgement rather than a hope.
                if d.q('print("SYNC")', timeout=60) != 'SYNC':
                    raise SystemExit('lost sync after %d of %d statements' % (i + 1, len(parts)))
                sys.stdout.write('\r  %d/%d statements' % (i + 1, len(parts)))
                sys.stdout.flush()
        d.exec('pcall(function() file.close(fh) end) fh = nil', timeout=60)
        print('\r  %d/%d statements, %.1f s' % (len(parts), len(parts), time.time() - t0))

        d.drain()
        d.send('local g = nil pcall(function() g = file.open("%s", file.MODE_READ) end) '
               'if g == nil then print("NO-FILE") else '
               '  local raw = nil pcall(function() raw = file.read(g, file.READ_ALL) end) '
               '  pcall(function() file.close(g) end) '
               '  if raw == nil then print("NO-READ") else '
               '    local _, ncr = string.gsub(raw, "\\r", "") '
               '    local _, nlf = string.gsub(raw, "\\n", "") '
               '    print("ONKEY len=" .. string.len(raw) .. " cr=" .. ncr .. " lf=" .. nlf) '
               '  end end '
               'print("EV " .. tostring(eventlog.getcount())) '
               'print("%s")' % (dest, END))
        got = None
        while True:
            ln = d.line(120)
            if ln is None or ln == END:
                break
            print('  ' + ln)
            if ln.startswith('ONKEY '):
                got = dict(kv.split('=') for kv in ln[6:].split())

        print()
        if got is None:
            print('  COULD NOT READ THE FILE BACK')
            raise SystemExit(1)
        same = (int(got['len']) == len(data) and int(got['cr']) == data.count(b'\r')
                and int(got['lf']) == data.count(b'\n'))
        print('  local len=%d cr=%d lf=%d' % (len(data), data.count(b'\r'), data.count(b'\n')))
        print('  onkey len=%s cr=%s lf=%s' % (got['len'], got['cr'], got['lf']))
        print('  -> %s' % ('IDENTICAL: install it from Manage Apps as usual'
                           if same else 'MISMATCH: do not install this'))
        if not same:
            raise SystemExit(1)
    finally:
        d.close()


if __name__ == '__main__':
    main()

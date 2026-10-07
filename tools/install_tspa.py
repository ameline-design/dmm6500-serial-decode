#!/usr/bin/env python3
"""Install a .tspa's script into the instrument's NON-VOLATILE memory over the LAN.

WHAT THIS IS FOR. Bisecting a firmware fault that only appears for an app in internal
memory needs a build in internal memory per attempt, and walking to the instrument with
a USB key costs a round trip each time. loadscript/endscript puts the chunk in RAM;
scriptVar.save() is what commits it to non-volatile memory so it survives the restart
the fault needs.

LINE ENDINGS ARE LOAD-BEARING HERE, which is why this does not use load_script().
That helper sends body.splitlines() and appends '\\n', so the stored source comes back
LF-terminated -- about 7164 bytes smaller than the same archive installed from a key,
which stores CRLF. When the quantity under bisection IS the stored size, and the live
window is about 9250 bytes wide, that is 77 % of the window: a build loaded the naive
way sits somewhere else on the ladder than the file it came from. So each line goes out
with an explicit '\\r', and the result is VERIFIED rather than assumed -- length, CR
count and LF count all have to match the archive's own body.

WHAT IT IS NOT. This bypasses the firmware's own app installer. The icon after
`endscript` is not registered and the app may therefore not appear under Manage Apps,
only in the script catalog. So this is a different INSTALL PATH from copying the .tspa
off a key, and a result that disagrees with the key-installed ladder may be telling you
about the path rather than about the size. Confirm a boundary through the key before
believing it.

    python3 tools/install_tspa.py --file ~/tmp/sdec-versions/C_ca93c8f.tspa
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM          # noqa: E402

END = '===INST-END==='


def parse_archive(path):
    """-> (script name, body text with its CRLF endings intact)."""
    with open(path, newline='') as fh:
        text = fh.read()
    i = text.index('loadscript ')
    nl = text.index('\n', i)
    name = text[i + len('loadscript '):nl].strip()
    body = text[nl + 1:text.index('\r\nendscript')]
    return name, body


def stream(d, src, timeout=120):
    d.drain()
    d.send(src)
    out = []
    while True:
        ln = d.line(timeout)
        if ln is None:
            out.append('<TIMEOUT>')
            break
        if ln == END:
            break
        out.append(ln)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--no-save', action='store_true',
                    help='load into RAM only, do not commit to non-volatile memory')
    a = ap.parse_args()

    name, body = parse_archive(a.file)
    lines = body.split('\r\n')
    want_len = len(body)
    want_cr = body.count('\r')
    want_lf = body.count('\n')
    print('%s -> script %s' % (a.file, name))
    print('  body %d bytes, %d lines, cr=%d lf=%d' % (want_len, len(lines), want_cr, want_lf))

    d = DMM(timeout=120)
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        # THE PANEL GOES HOME FIRST. With a live TSP app's own screen in front, statements on
        # this socket get refused outright -- the front panel IS the other interface -- and it
        # also stops the app's own timer, which would otherwise run during the replacement.
        d.exec('pcall(function() display.changescreen(display.SCREEN_HOME) end)', timeout=30)
        print('  panel sent HOME; sdec is %s' % d.q('print(type(sdec))'))

        # DROP THE EXISTING SCRIPT, by object and not by name: script.delete() given a string
        # raises 1138. It also logs -104 asynchronously even when it succeeds, so the log is
        # cleared afterwards and settled before the body goes out, or that event lands in the
        # middle of the transfer.
        d.exec('if %s ~= nil then pcall(function() script.delete(%s) end) %s = nil '
               'eventlog.clear() end' % (name, name, name), timeout=60)
        time.sleep(0.4)
        d.drain()

        print('  sending %d lines...' % len(lines))
        t0 = time.time()
        d.send('loadscript ' + name)
        for ln in lines:
            # '\r' EXPLICITLY, so the stored line ends CRLF exactly as the archive does.
            # send() supplies the '\n'.
            d.send(ln + '\r')
        d.send('endscript')
        time.sleep(0.5)
        print('  transfer %.1f s' % (time.time() - t0))

        if d.q('print(type(%s))' % name, timeout=60) == 'nil':
            raise SystemExit('LOAD FAILED: %s is not defined -- the loadscript line was lost' % name)
        print('  loaded into RAM')

        if not a.no_save:
            # scriptVar.save() is the documented commit to non-volatile memory. Tried as a
            # method and then as a module call, because which one a given firmware accepts is
            # not worth guessing at -- whichever reports true is the one that ran.
            out = stream(d, "local ok1 = pcall(function() %s.save() end) "
                            "local ok2 = false "
                            "if not ok1 then ok2 = pcall(function() script.save(%s) end) end "
                            "print('SAVE method=' .. tostring(ok1) .. ' module=' .. tostring(ok2)) "
                            "print('%s')" % (name, name, END))
            for l in out:
                print('  ' + l)

        # VERIFIED, NOT ASSUMED: the three numbers that describe the stored artefact, against
        # the three from the file. A CR count that comes back zero means the firmware stripped
        # them and this build is NOT comparable with a key-installed one.
        out = stream(d, "local s = %s.source "
                        "if s == nil then print('NO-SOURCE') else "
                        "  local _, ncr = string.gsub(s, '\\r', '') "
                        "  local _, nlf = string.gsub(s, '\\n', '') "
                        "  print('STORED len=' .. string.len(s) .. ' cr=' .. ncr .. ' lf=' .. nlf) "
                        "end "
                        "local n = 0 for nm in script.catalog() do if nm == '%s' then n = n + 1 end end "
                        "print('CATALOG entries named %s: ' .. n) "
                        "print('EV ' .. tostring(eventlog.getcount())) "
                        "print('%s')" % (name, name, name, END))
        stored = None
        for l in out:
            print('  ' + l)
            if l.startswith('STORED '):
                stored = dict(kv.split('=') for kv in l[7:].split())

        print()
        if stored is None:
            print('  COULD NOT READ THE STORED SOURCE BACK')
        else:
            got = (int(stored['len']), int(stored['cr']), int(stored['lf']))
            want = (want_len, want_cr, want_lf)
            # The archive's body has no terminator on its final line; the stored copy may, so
            # one line's worth of slack is allowed on length and counts.
            ok = (abs(got[0] - want[0]) <= 2 and abs(got[1] - want[1]) <= 1
                  and abs(got[2] - want[2]) <= 1)
            print('  file   len=%d cr=%d lf=%d' % want)
            print('  stored len=%d cr=%d lf=%d' % got)
            print('  -> %s' % ('FAITHFUL: this build sits where the file says it does'
                               if ok else
                               'DIFFERENT: do NOT place this result on the key-installed ladder'))
    finally:
        d.close()


if __name__ == '__main__':
    main()

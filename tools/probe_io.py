#!/usr/bin/env python3
"""Is Lua 5.0.2's io library present on the DMM6500, and does it read quietly?

file.read posts event 2201 'File read error' for a read past the end, and on this
instrument that is a modal box nothing can suppress -- one per pass over a plan for
as long as a soak runs. If the standard io library is present and reachable, three
things change: f:seek('end') IS the file length, so no FAT directory parse is needed;
and a read at the end may come back as nil or as an error RETURN rather than a dialog.

Every step is pcall'd and bracketed by an event count, so a step that posts gets
attributed to itself rather than to the next one. Nothing is opened for write and
nothing is deleted.

    python3 -I tools/probe_io.py [--path /usb1/SERDEC/PLAN.CSV]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM                                          # noqa: E402

STEPS = [
    ('namespaces',
     'print(type(io) .. " os=" .. type(os) .. " loadfile=" .. type(loadfile))'),
    ('io members',
     'print("open=" .. type(io and io.open) .. " lines=" .. type(io and io.lines) '
     '.. " read=" .. type(io and io.read) .. " input=" .. type(io and io.input))'),
]


def ev(d):
    try:
        return int(str(d.q('print(eventlog.getcount())')).strip().split()[-1])
    except Exception:
        return -1


def step(d, tag, lua):
    """Every entry is already a complete statement that prints its own result, so it
    goes over as-is. The event count is read either side so a step that posts is
    attributed to itself and not to the one after it."""
    before = ev(d)
    out = d.q(lua)
    after = ev(d)
    print('  %-26s %-56s events +%d'
          % (tag, str(out).replace('\n', ' ')[:56], max(0, after - before)))
    return str(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--path', default='/usb1/SERDEC/PLAN.CSV')
    a = ap.parse_args()

    d = DMM(timeout=60)
    try:
        print(' ', d.q('print(localnode.model .. " fw " .. localnode.version)'))
        d.q('eventlog.clear()')
        for tag, lua in STEPS:
            step(d, tag, lua)

        have = step(d, 'io is usable', 'print(tostring(io ~= nil and io.open ~= nil))')
        if 'true' not in have:
            print('\n  VERDICT: no io library -- file.* is the only route, and the FAT '
                  'directory entry stays the only size oracle.')
            return

        # Open read-only. Everything below is guarded so a missing io.open cannot raise
        # out of the probe.
        step(d, 'open for read',
             'do PF = nil local ok, f = pcall(function() return io.open("%s", "r") end) '
             'if ok then PF = f end print("ok=" .. tostring(ok) .. " h=" .. tostring(PF)) end'
             % a.path)
        step(d, 'seek end = length',
             'do local ok, n = pcall(function() return PF:seek("end") end) '
             'print("ok=" .. tostring(ok) .. " len=" .. tostring(n)) end')
        step(d, 'seek back to start',
             'do local ok, n = pcall(function() return PF:seek("set", 0) end) '
             'print("ok=" .. tostring(ok) .. " pos=" .. tostring(n)) end')
        step(d, 'read one line',
             'do local ok, l = pcall(function() return PF:read("*l") end) '
             'print("ok=" .. tostring(ok) .. " n=" .. tostring(l and string.len(l))) end')
        # THE QUESTION. Seek to the end, then read: that is the read file.read answers
        # with 2201. If io posts nothing here, the whole class of dialog goes away.
        step(d, 'READ AT THE END',
             'do local ok1 = pcall(function() PF:seek("end") end) '
             'local ok, l = pcall(function() return PF:read("*l") end) '
             'print("seek=" .. tostring(ok1) .. " ok=" .. tostring(ok) '
             '.. " val=" .. tostring(l)) end')
        step(d, 'read again at the end',
             'do local ok, l = pcall(function() return PF:read("*l") end) '
             'print("ok=" .. tostring(ok) .. " val=" .. tostring(l)) end')
        step(d, 'close', 'do local ok = pcall(function() PF:close() end) '
                         'print("ok=" .. tostring(ok)) end')
        step(d, 'open a missing path',
             'do local ok, f, e = pcall(function() return io.open('
             '"/usb1/SERDEC/NOSUCH.CSV", "r") end) '
             'print("ok=" .. tostring(ok) .. " h=" .. tostring(f) .. " err=" .. tostring(e)) end')
        step(d, 'cleanup', 'PF = nil print("done")')

        print('')
        print('  Event text, if any posted:')
        print('   ', d.q('do local n = eventlog.getcount() local s = "" '
                         'for i = 1, n do s = s .. "|" .. tostring(eventlog.next()) end '
                         'print(s) end'))
    finally:
        d.close()


if __name__ == '__main__':
    main()

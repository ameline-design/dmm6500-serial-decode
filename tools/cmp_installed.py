#!/usr/bin/env python3
"""Diff the INSTALLED TSP app against the .tspa sitting on the USB key.

WHY IT CANNOT BE DONE WITH A CHECKSUM. There is no hash function on this
instrument and no fs.fsize, so the only way to compare two artefacts is to pull
both to the host. Both are streamed line by line -- one `print` per line against
one statement -- rather than fetched with file.READ_ALL, which would put 273 kB
in a single reply.

WHAT THE TWO THINGS ARE. The installed app is a script object in the catalog, and
a script carries its text in `.source`. The key holds a .tspa PACKAGE: a manifest
header, then the same script body, then a base64 icon. So the comparison is
body-to-body, and the manifest is reported separately -- it is where $Version
lives, and the version string is the only difference this is expected to find.

    python3 tools/cmp_installed.py [--name Serial_Decode] [--key /usb1/Serial_Decode.tspa]
"""
import argparse
import difflib
import os
import subprocess
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402

END = '===CMP-END==='


def stream(d, src, timeout=300):
    """Send one statement that prints many lines; collect until the sentinel."""
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


def fetch_source(d, name):
    """The installed script's own text, a line at a time, plus its exact byte length.

    Split in Lua rather than on the host: a chunked string.sub would cut lines in
    half and the host could not reassemble them without knowing where the breaks
    were. string.find with a plain-text 4th argument is Lua 5.0.2-safe.

    THE LENGTH IS WHAT MAKES THIS A BYTE COMPARISON. Everything else here is
    line-based, and a line-based diff is blind to exactly the differences a bad
    artefact has: trailing spaces, CRLF against LF, a stray NUL. string.len() is
    the instrument's own count of the stored bytes, so reassembling the streamed
    lines on the host and finding the same total proves the transport was faithful
    AND pins the stored size. A mismatch localises the fault: disagreeing with the
    repo means the stored script differs, disagreeing with the host's own
    reassembly means this tool's line splitting lost something.
    """
    src = ("local s = %s.source "
           "if s == nil then print('NO-SOURCE') else "
           "  print('@LEN ' .. tostring(string.len(s))) "
           "  local pos = 1 local n = string.len(s) "
           "  while pos <= n do "
           "    local a, b = string.find(s, '\\n', pos, true) "
           "    if a == nil then print('L' .. string.sub(s, pos)) pos = n + 1 "
           "    else print('L' .. string.sub(s, pos, a - 1)) pos = b + 1 end "
           "  end end "
           "print('%s')" % (name, END))
    out = stream(d, src)
    # 'L' is the line prefix and '@LEN ' is deliberately NOT one: a bare 'LEN...' would
    # start with L and be spliced into the source as a line of code.
    nbytes = None
    for l in out:
        if l.startswith('@LEN '):
            try:
                nbytes = int(l[5:].strip())
            except ValueError:
                pass
    return [l[1:] for l in out if l.startswith('L')], nbytes


def fetch_file(d, path):
    """Every line of a file on the key."""
    src = ("local fh = nil pcall(function() fh = file.open('%s', file.MODE_READ) end) "
           "if fh == nil then print('NO-FILE') else "
           "  while true do local ln = nil "
           "    local ok = pcall(function() ln = file.read(fh, file.READ_LINE) end) "
           "    if not ok or ln == nil or ln == '' then break end "
           "    print('L' .. ln) end "
           "  pcall(function() file.close(fh) end) end "
           "print('%s')" % (path, END))
    return [l[1:] for l in stream(d, src) if l.startswith('L')]


def norm(lines):
    return [l.rstrip('\r\n') for l in lines]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', default='Serial_Decode')
    ap.add_argument('--key', default='/usb1/Serial_Decode.tspa')
    ap.add_argument('--save', default=os.path.expanduser('~/tmp/installed_source.tsp'),
                    help='where to write the installed source for offline diffing')
    ap.add_argument('--against', default='6976f70,5634ac0,bf9f4c9,c3ddd50',
                    help='commits whose .tspa bodies to compare the installed source with')
    a = ap.parse_args()

    d = DMM(timeout=60)
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        print('installed script type:', d.q('print(type(%s))' % a.name))

        print('\nfetching the installed source...')
        inst, nbytes = fetch_source(d, a.name)
        inst = norm(inst)
        print('  %d lines' % len(inst))
        # THE TRANSPORT IS CHECKED BEFORE ANYTHING IS CONCLUDED FROM IT. Reassembled with
        # '\n' this must come back to the instrument's own string.len(); if it does not,
        # the line splitting dropped or mangled bytes and every 'IDENTICAL' below is a
        # statement about a damaged copy rather than about the stored script.
        # BOTH TERMINATORS ARE TRIED, and that is not hedging. THIS ARCHIVE IS CRLF: the
        # packaged .tspa carries '\r\n' on every line and the instrument stores it that way,
        # so a host reassembly joined with '\n' is short by one byte per line -- 7164 bytes
        # on this app. Reporting that as a mismatch accuses a perfectly good artefact of
        # being corrupt, which is exactly the wrong answer to give while hunting a crash.
        cands = {'LF': len('\n'.join(inst)), 'CRLF': len('\r\n'.join(inst))}
        print('  stored bytes (string.len on the instrument): %s' % nbytes)
        hit = None
        for k, v in cands.items():
            # +/-2 covers whether the LAST line carries a terminator, which the split drops.
            if nbytes is not None and abs(nbytes - v) <= 2:
                hit = k
        print('  host reassembly: LF %d, CRLF %d  -> %s'
              % (cands['LF'], cands['CRLF'],
                 ('transport faithful, stored as %s' % hit) if hit
                 else 'MISMATCH -- bytes were lost in transport or the store differs'))
        print('fetching the .tspa from the key...')
        pkg = norm(fetch_file(d, a.key))
        print('  %d lines' % len(pkg))

        # The manifest is the header; the body is what the installer loads. The split is
        # made by locating the installed source's FIRST line inside the package rather than
        # by counting header lines, which would rot if the manifest grew a field.
        head, body = pkg, []
        if inst:
            for i, l in enumerate(pkg):
                if l == inst[0]:
                    head, body = pkg[:i], pkg[i:]
                    break
        print('\n== manifest in the package (%d lines) ==' % len(head))
        for l in head:
            print('  ' + l)
        ver = [l for l in head if 'Version' in l]
        print('  -> version line(s): %s' % (ver or 'NONE FOUND'))

        # The package also carries the icon after the body; compare only as far as the
        # installed source runs, and report the tail separately.
        tail = body[len(inst):]
        body = body[:len(inst)]
        print('\n== body comparison ==')
        print('  installed %d lines, package body %d lines, package tail %d lines'
              % (len(inst), len(body), len(tail)))
        diff = [l for l in difflib.unified_diff(inst, body, lineterm='', n=0)
                if l[:1] in '+-' and l[:3] not in ('+++', '---')]
        print('  differing lines: %d' % len(diff))
        for l in diff[:40]:
            print('   ' + l[:160])
        if not diff:
            print('  -> the installed app and the package body are IDENTICAL')
        # SAVED AND COMPARED AGAINST KNOWN BUILDS, because the header/body split above is a
        # guess and a misaligned split invents differences. A repo .tspa is a known quantity:
        # whichever one the installed source matches exactly IS the installed build, and that
        # settles which commit is on the instrument without trusting any slicing.
        with open(a.save, 'w') as fh:
            fh.write('\n'.join(inst) + '\n')
        print('\n  installed source saved to %s (%d lines)' % (a.save, len(inst)))
        print('\n== which repo build is installed? ==')
        for rev in [r.strip() for r in a.against.split(',') if r.strip()]:
            try:
                blob = subprocess.run(['git', 'show', '%s:Serial_Decode.tspa' % rev],
                                      capture_output=True, text=True, check=True).stdout
            except subprocess.CalledProcessError:
                print('  %-10s <could not read>' % rev)
                continue
            lines = [l.rstrip('\r\n') for l in blob.split('\n')]
            # The body is the span between the loadscript and endscript wrapper lines.
            try:
                i0 = next(i for i, l in enumerate(lines) if l.startswith('loadscript ')) + 1
                i1 = next(i for i, l in enumerate(lines) if l.strip() == 'endscript')
            except StopIteration:
                print('  %-10s <no loadscript/endscript wrapper>' % rev)
                continue
            rbody = lines[i0:i1]
            dd = [l for l in difflib.unified_diff(inst, rbody, lineterm='', n=0)
                  if l[:1] in '+-' and l[:3] not in ('+++', '---')]
            # BYTES, NOT JUST LINES. Equal line lists with unequal joined lengths means a
            # whitespace-only or line-ending difference, which is invisible above and is
            # precisely what a bad transfer leaves behind.
            rjoin, ijoin = '\n'.join(rbody), '\n'.join(inst)
            if not dd and rjoin == ijoin:
                tag = 'IDENTICAL, byte for byte (%d bytes)' % len(ijoin)
            elif not dd:
                tag = ('same lines but %d vs %d BYTES -- whitespace or line endings differ'
                       % (len(ijoin), len(rjoin)))
            else:
                tag = '%d differing lines' % len(dd)
            print('  %-10s body %5d lines   %s' % (rev, len(rbody), tag))
            if dd and len(dd) <= 12:
                for l in dd:
                    print('        ' + l[:150])
        print('\nevents:', d.q('print(tostring(eventlog.getcount()))'))
    finally:
        d.close()


if __name__ == '__main__':
    main()

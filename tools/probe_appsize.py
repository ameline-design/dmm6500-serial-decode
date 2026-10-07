#!/usr/bin/env python3
"""Build a .tspa of a chosen SIZE, to find the size at which this firmware stops
being able to run an installed app.

THE DEFECT THIS EXISTS FOR. On a DMM6500 (1.7.17a) an app installed into internal
memory runs correctly when freshly copied, and then bluescreens the instrument on any
capture with a signal on the pin after the next restart. The same archive run from the
USB key never fails. Bisecting the project's own tagged releases put the boundary
between V1.30 (works) and V1.32 (crashes) -- but the tags run out of resolution there,
and worse, source size and compiled size rise TOGETHER across them, so no tag can say
which of the two the firmware is actually limited by.

TWO AXES, MOVED INDEPENDENTLY. That is the whole point of this tool:

    --pad-code       adds dead functions: bytecode grows, and so does source
    --pad-comment    adds comment lines:  source grows, bytecode does NOT

Comments never reach a compiled chunk, so a build padded only with comments is the
control: if the firmware's limit is on the stored source it must fail, and if the limit
is on the compiled image it must not. The two predictions are opposite, which is what
makes a single install decisive rather than suggestive.

WHY THE PADDING IS WRAPPED IN `if false then`. The padding must be COMPILED but never
RUN -- otherwise a bigger build is also a build that does more work, and a crash could
be blamed on the work instead of the size. Lua compiles the body of a constant-false
branch in full, prototypes and all, and skips it at runtime, so the padding costs
bytecode and nothing else. It also keeps every padding name out of the global table,
which matters because verify_tspa.lua checks what the archive leaks into _G.

    python3 tools/probe_appsize.py --base ~/tmp/sdec-versions/SD130.tspa \
                                   --bytecode 183000 --out ~/tmp/pad183.tspa

Sizes are reported on both axes for every build, because a result is only usable
alongside the two numbers that describe the artefact it came from.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# CRLF, because that is what the packaged archive uses and what the instrument stores.
# Mixing in LF lines would make a size comparison against a tagged build meaningless.
EOL = '\r\n'


def split_archive(text):
    """-> (head, tail) around the point padding is inserted.

    Inserted BEFORE `endscript` rather than appended to the file: everything after
    endscript is the base64 icon, and padding there would not be compiled at all.
    """
    i = text.index(EOL + 'endscript')
    return text[:i], text[i:]


def pad_code(n):
    """n dead functions, compiled and unreachable."""
    out = ['', '-- ==== probe_appsize padding: compiled, never executed ====', 'if false then']
    for i in range(n):
        out.append('  local function pad_%06d(x) local a = x + %d a = a * 2 '
                   'local t = {a, a + 1} return t[1] + a end' % (i, i))
    out.append('end')
    return EOL.join(out) + EOL


def pad_comment(nbytes):
    """Comment lines totalling about nbytes, which add nothing to the bytecode."""
    line = '-- ' + ('padding ' * 11).strip()
    per = len(line) + len(EOL)
    return EOL.join([line] * max(1, nbytes // per)) + EOL


def bytecode_size(body):
    """Compile the body with the HOST luac and return the chunk size.

    THE HOST COMPILER, NOT THE INSTRUMENT'S. lua502's luac rejects literals this
    project uses and fails on the shipped app too, so it cannot measure anything here.
    The absolute number is therefore the host's, and only COMPARISONS between builds
    measured the same way mean anything -- which is all this tool needs, since comments
    are absent from a compiled chunk under every Lua version.
    """
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as fh:
        fh.write(body)
        src = fh.name
    out = src + '.out'
    try:
        r = subprocess.run(['luac', '-o', out, src], capture_output=True, text=True)
        if r.returncode != 0:
            return None, r.stderr.strip()
        return os.path.getsize(out), None
    finally:
        for p in (src, out):
            if os.path.exists(p):
                os.unlink(p)


def body_of(text):
    """The compilable span: after the `loadscript` line, up to `endscript`."""
    i0 = text.index('loadscript ')
    i0 = text.index('\n', i0) + 1
    i1 = text.index(EOL + 'endscript')
    return text[i0:i1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default=os.path.join(ROOT, 'Serial_Decode.tspa'),
                    help='archive to grow; use a build KNOWN to work on the instrument')
    ap.add_argument('--out', required=True)
    ap.add_argument('--bytecode', type=int,
                    help='target total bytecode bytes: pads with dead code to reach it')
    ap.add_argument('--pad-comment-kb', type=int,
                    help='add this many kB of COMMENTS -- source grows, bytecode does not')
    a = ap.parse_args()

    with open(a.base, newline='') as fh:
        text = fh.read()
    head, tail = split_archive(text)
    base_src = body_of(text)
    base_bc, err = bytecode_size(base_src)
    if base_bc is None:
        raise SystemExit('the base archive does not compile: %s' % err)
    print('base %s' % a.base)
    print('  source %d bytes   bytecode %d bytes' % (len(base_src), base_bc))

    pad = ''
    if a.pad_comment_kb:
        pad = pad_comment(a.pad_comment_kb * 1024)
    elif a.bytecode:
        if a.bytecode <= base_bc:
            raise SystemExit('target %d is not above the base %d -- this tool only grows'
                             % (a.bytecode, base_bc))
        # MEASURED, NOT CALCULATED. Bytes-per-padding-function depends on the compiler's
        # constant folding and debug tables, so the count is converged on by compiling
        # rather than predicted from a per-function estimate.
        lo, hi = 1, 64
        while True:
            bc, _ = bytecode_size(base_src + pad_code(hi))
            if bc is not None and bc >= a.bytecode:
                break
            hi *= 2
            if hi > 200000:
                raise SystemExit('cannot reach %d' % a.bytecode)
        while lo < hi:
            mid = (lo + hi) // 2
            bc, _ = bytecode_size(base_src + pad_code(mid))
            if bc is None or bc < a.bytecode:
                lo = mid + 1
            else:
                hi = mid
        pad = pad_code(lo)
        print('  padding: %d dead functions' % lo)
    else:
        raise SystemExit('give --bytecode or --pad-comment-kb')

    newbody = base_src + pad
    bc, err = bytecode_size(newbody)
    if bc is None:
        raise SystemExit('the padded body does not compile: %s' % err)
    with open(a.out, 'w', newline='') as fh:
        fh.write(head + pad + tail)
    print('wrote %s' % a.out)
    print('  source %d bytes (%+d)   bytecode %d bytes (%+d)'
          % (len(newbody), len(newbody) - len(base_src), bc, bc - base_bc))
    print('  archive %d bytes' % os.path.getsize(a.out))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Per-FUNCTION coverage of a tsp module, so a gap can be designed against by name.

WHY BY FUNCTION AND NOT BY LINE RANGE. A line range says where to look; a function name says what to
write a test for. The executable-line denominator still comes from `luac -l -p` -- the compiler's own
opinion of which lines emitted code -- so a comment block or a bare `end` is never counted as a gap.

    python3 tools/covfunc.py tsp/uart_decode.tsp ~/tmp/cov/*.txt
"""
import collections
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTR = re.compile(r'^\s+\d+\s+\[(\d+)\]')
# ANCHORED AT COLUMN 0, so a NESTED function does not steal its parent's body. tsp/ declares top-level
# functions flush left and nested helpers indented, so `local function giveup(why)` inside decode_from
# is indented -- and matching it would end decode_from at that line and hand every remaining line of the
# decoder to `giveup`. Attributing 190 lines of decoder to a four-line helper does not merely mislabel
# the gap, it points the next test at the wrong function.
FUNC = re.compile(r'^(?:local\s+)?function\s+([A-Za-z_][\w.:]*)')


def executable_lines(rel):
    """Source lines luac emitted an instruction for. REFUSES rather than returning empty: an empty
    denominator makes a broken module look like a fully covered one."""
    p = subprocess.run(['luac', '-l', '-p', rel], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = p.stdout.decode('utf-8', 'replace')
    if p.returncode != 0:
        raise SystemExit('luac -l -p %s exited %d:\n%s' % (rel, p.returncode, text))
    out = set(int(m.group(1)) for m in (INSTR.match(l) for l in text.splitlines()) if m)
    if not out:
        raise SystemExit('luac -l -p %s emitted no instruction lines; that is not a module' % rel)
    return out


def functions(rel):
    """[(name, first_line, last_line)] -- a function owns lines up to the next function's start."""
    out = []
    with open(os.path.join(ROOT, rel)) as fh:
        for i, line in enumerate(fh, 1):
            m = FUNC.match(line)
            if m:
                out.append([m.group(1), i, None])
    for k in range(len(out) - 1):
        out[k][2] = out[k + 1][1] - 1
    if out:
        out[-1][2] = 10 ** 9
    return out


def main(argv):
    rel, hitfiles = argv[0], argv[1:]
    hits = set()
    for f in hitfiles:
        for line in open(f):
            p = line.split()
            if len(p) == 2 and p[0] == rel:
                hits.add(int(p[1]))
    ex = executable_lines(rel)
    fns = functions(rel)
    rows = []
    for name, a, b in fns:
        own = set(l for l in ex if a <= l <= b)
        if not own:
            continue
        h = len(own & hits)
        rows.append((len(own) - h, len(own), h, name, a))
    rows.sort(reverse=True)
    tot_e = len(ex)
    tot_h = len(ex & hits)
    print('%s  %d executable, %d hit, %.1f%%' % (rel, tot_e, tot_h, 100.0 * tot_h / tot_e))
    print('%-34s %6s %6s %6s  %s' % ('function', 'exec', 'hit', 'cov', 'line'))
    for miss, n, h, name, a in rows:
        if miss == 0:
            continue
        print('%-34s %6d %6d %5.0f%%  %d' % (name, n, h, 100.0 * h / n, a))
    zero = [r for r in rows if r[2] == 0]
    print('\nNEVER ENTERED AT ALL (%d function(s), %d executable lines):'
          % (len(zero), sum(r[1] for r in zero)))
    for miss, n, h, name, a in zero:
        print('  %-34s %4d lines  tsp:%d' % (name, n, a))


if __name__ == '__main__':
    main(sys.argv[1:])

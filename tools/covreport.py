#!/usr/bin/env python3
"""Report line coverage of tsp/ from a hit file written by tools/cov.lua.

THE DENOMINATOR COMES FROM THE COMPILER, not from a guess about what a line is. `luac -l -p` lists the
source line of every instruction emitted, so the executable-line set is exact: comments, blank lines and
bare `end`s never count as uncovered, and a line that compiles to nothing is never demanded.

    python3 tools/covreport.py /tmp/hits.txt [more_hit_files...]
"""
import collections
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTR = re.compile(r'^\s+\d+\s+\[(\d+)\]')


def executable_lines(path):
    """The set of source lines luac emitted an instruction for. REFUSES rather than returning empty.

    A luac that exits nonzero -- a syntax error, a missing file, a luac that is not on PATH -- yields no
    instruction lines, and an empty denominator drops the module out of the report entirely: it prints
    0 executable, 0 hit, and contributes nothing to the total, so BREAKING a module improves the
    coverage figure. That is a verdict drawn from absent evidence, so it raises instead.
    """
    p = subprocess.run(['luac', '-l', '-p', path], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = p.stdout.decode('utf-8', 'replace')
    if p.returncode != 0:
        raise SystemExit('luac -l -p %s exited %d, so its executable-line count is unknown:\n%s'
                         % (path, p.returncode, text))
    out = set()
    for line in text.splitlines():
        m = INSTR.match(line)
        if m:
            out.add(int(m.group(1)))
    if not out:
        raise SystemExit('luac -l -p %s emitted no instruction lines; that is not a module' % path)
    return out


def main(argv):
    if not argv:
        raise SystemExit('usage: covreport.py HITFILE [HITFILE...]')
    hits = collections.defaultdict(set)
    read, skipped = [], []
    for f in argv:
        # A '.part' FILE IS A SNAPSHOT MID-WRITE, never a result. cov.lua writes OUT..'.part' and renames
        # it into place, so a caller globbing a whole directory can otherwise hand us a half-written file
        # -- and a line cut mid-number parses as a valid hit on a line that never ran.
        if f.endswith('.part'):
            skipped.append(f)
            continue
        read.append(f)
        for line in open(f):
            parts = line.split()
            if len(parts) == 2:
                hits[parts[0]].add(int(parts[1]))
    for f in skipped:
        print('SKIPPED %s -- a .part file is a snapshot being written, not a result' % f)
    # AN EMPTY HIT SET IS NO MEASUREMENT, NOT A MEASUREMENT OF ZERO. cov.lua truncates its output file
    # before installing the hook, so a run killed before its first flush leaves a legitimately EMPTY
    # file -- and reporting that as 0.0 % against every module is the same error as reading a missing
    # counter as zero: a confident verdict drawn from absent evidence. It reads as a catastrophe rather
    # than as "this run has not reported yet".
    if not hits:
        raise SystemExit('no hits in %d file(s) (%s). An empty hit file means the run was killed before '
                         'it flushed, NOT that nothing was covered -- refusing to report 0 %%.'
                         % (len(read), ', '.join(read) or 'none'))

    mods = sorted(glob.glob(os.path.join(ROOT, 'tsp', '*.tsp')))
    print('%-24s %7s %7s %6s  %s' % ('module', 'exec', 'hit', 'cov', 'largest unhit runs (start-end)'))
    tot_e = tot_h = 0
    for m in mods:
        rel = 'tsp/' + os.path.basename(m)
        ex = executable_lines(rel)
        hit = set(l for l in hits.get(rel, ()) if l in ex)
        tot_e += len(ex)
        tot_h += len(hit)
        miss = sorted(ex - hit)
        # Contiguous runs of unhit executable lines, longest first: one long run is a whole function
        # nothing reached, which is the actionable shape. Scattered singles are usually error branches.
        runs, cur = [], None
        prev = None
        for l in miss:
            if prev is not None and l - prev <= 2:
                cur[1] = l
            else:
                cur = [l, l]
                runs.append(cur)
            prev = l
        runs.sort(key=lambda r: r[0] - r[1])
        top = ', '.join('%d-%d(%d)' % (a, b, b - a + 1) for a, b in runs[:4] if b - a >= 4)
        pct = 100.0 * len(hit) / len(ex) if ex else 0.0
        print('%-24s %7d %7d %5.1f%%  %s' % (rel, len(ex), len(hit), pct, top))
    print('%-24s %7d %7d %5.1f%%' % ('TOTAL', tot_e, tot_h,
                                     100.0 * tot_h / tot_e if tot_e else 0.0))


if __name__ == '__main__':
    main(sys.argv[1:])

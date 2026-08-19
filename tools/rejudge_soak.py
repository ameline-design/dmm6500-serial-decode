#!/usr/bin/env python3
"""Re-judge a finished (or running) soak from its records, separating real failures from the
known lorem gate artifact.

WHY THIS EXISTS. bench_matrix's lorem gate is `longest_clean_run/body >= 0.95`, which is a
fragile ORDER STATISTIC: with k bytes flagged, the score depends on WHERE they land, not how
many there are. Two flags near an edge leave 234/239 and pass; one flag deeper in splits the
capture and fails. Across 143 lorem points in 13 runs the longest clean run was byte-exact
against the payload 141 of 141 times it was reported, so the suite has never once produced a
silently wrong byte -- yet 1.4 % of points fell below the gate. Those verdicts say something
about flag POSITION, not about correctness, and a soak that tallies them cannot be compared
against a baseline measured before the lorem suite was in the rotation.

So the raw lap-failure rate is not the number to read. This tool reports both, and the count
that matters is LAPS WITH A REAL FAILURE.

`bad` is not corruption: bench_uart.py:363 counts frames equal to '??' -- bytes the decoder
FLAGGED and declined to stand behind. Honest uncertainty, not a wrong answer.

Reads only. Touches no instrument, so it is safe to run against a live soak.

Usage:  python3 tools/rejudge_soak.py [out/soak/<dir> ...]     (default: newest)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The artifact's signature, as bench_matrix.py:460 prints it.
LOREM_BAD = re.compile(r'longest clean run (\d+) \((\d+) %\), (\d+) bad \((\d+) interior\)')

# Bounds on what may be dismissed. A lorem point is only excused when the decoder flagged a
# FEW bytes and the clean run still covered nearly everything -- i.e. the gate missed on flag
# position. Below MIN_PCT or above MAX_FLAGS is a different phenomenon and stays a failure:
# the point of this tool is to subtract a measurement artifact, not to launder failures.
MIN_PCT = 94
MAX_FLAGS = 3


def classify(name, detail):
    """-> ('artifact', why) | ('real', why). Anything not positively identified is REAL."""
    if not name.startswith('lorem '):
        return 'real', 'not a lorem point'
    m = LOREM_BAD.search(detail)
    if not m:
        return 'real', 'lorem failure but not the gate signature'
    run, pct, bad, interior = (int(m.group(i)) for i in (1, 2, 3, 4))
    if pct < MIN_PCT:
        return 'real', 'clean run only %d %% (< %d)' % (pct, MIN_PCT)
    if bad > MAX_FLAGS:
        return 'real', '%d flagged (> %d)' % (bad, MAX_FLAGS)
    return 'artifact', 'run %d = %d %%, %d flagged -- gate missed on flag position' % (
        run, pct, bad)


def rejudge(d):
    jl = os.path.join(d, 'laps.jsonl')
    if not os.path.exists(jl):
        print('%s: no laps.jsonl' % d)
        return
    laps = []
    with open(jl, errors='replace') as f:
        for ln in f:
            ln = ln.strip()
            if ln:
                laps.append(json.loads(ln))

    complete = [l for l in laps if 'incomplete' not in l]
    incomplete = [l for l in laps if 'incomplete' in l]
    clean, artifact_only, real = [], [], []
    per_point = {}          # name -> [seen_bad, artifact, real]
    for l in complete:
        fails = l.get('fails') or []
        kinds = []
        for f in fails:
            name, _, detail = f.partition(': ')
            k, why = classify(name.strip(), detail)
            kinds.append((name.strip(), k, why))
            p = per_point.setdefault(name.strip(), [0, 0, 0])
            p[0] += 1
            p[1 if k == 'artifact' else 2] += 1
        # ONE real failure makes the lap real, however many artifacts sit beside it.
        if not fails:
            clean.append(l)
        elif any(k == 'real' for _, k, _ in kinds):
            real.append((l, kinds))
        else:
            artifact_only.append((l, kinds))

    print('=' * 78)
    print('%s' % d)
    print('=' * 78)
    n = len(complete)
    print('laps recorded      : %d  (%d complete, %d incomplete/not tallied)'
          % (len(laps), n, len(incomplete)))
    if not n:
        return
    pts = sum(l.get('npoints', 0) for l in complete)
    print('points measured    : %d' % pts)
    print()
    print('RAW verdict (what the soak printed):')
    print('  laps with any BAD point : %d of %d = %.1f %%'
          % (len(real) + len(artifact_only), n, 100.0 * (len(real) + len(artifact_only)) / n))
    print()
    print('RE-JUDGED (lorem gate artifact separated out):')
    print('  laps fully clean        : %d' % len(clean))
    print('  laps lorem-artifact only: %d   <- measurement artifact, not a defect' % len(artifact_only))
    print('  LAPS WITH A REAL FAILURE: %d of %d = %.1f %%   <-- THE NUMBER'
          % (len(real), n, 100.0 * len(real) / n))
    print()

    # The headline the run was commissioned to settle. v44d/v44e live in the `formats` suite,
    # so the lorem artifact cannot pollute this either way -- it is counted on its own.
    v44 = [(l['lap'], f) for l in complete for f in (l.get('fails') or [])
           if 'v44d' in f or 'v44e' in f]
    print('v44d / v44e failures    : %d   %s'
          % (len(v44), '<-- baseline for V1.01 was 15.2 % of laps' if not v44 else '*** REGRESSION ***'))
    for lap, f in v44[:10]:
        print('    lap %d: %s' % (lap, f))
    print()

    if real:
        print('REAL failures, every one:')
        for l, kinds in real:
            for name, k, why in kinds:
                if k == 'real':
                    print('  lap %-4d %-22s %s' % (l['lap'], name, why))
        print()
    if per_point:
        print('per point that ever failed:   bad  artifact  real')
        for name in sorted(per_point, key=lambda k: -per_point[k][2]):
            seen, art, rl = per_point[name]
            print('  %-24s %5d %9d %5d %s' % (name, seen, art, rl, '<-- real' if rl else ''))
        print()
    recs = [l for l in complete if l.get('record')]
    print('recordings taken   : %d' % len(recs))
    if incomplete:
        print()
        print('incomplete laps (evidence of nothing, not tallied):')
        for l in incomplete[:10]:
            print('  lap %-4d %s' % (l['lap'], l['incomplete'][:90]))


def main():
    dirs = sys.argv[1:]
    if not dirs:
        # Newest by MTIME, not by name: the directory names are timestamps but the tree also holds
        # hand-renamed ones ('PARTIAL-00-48-15-9laps-...'), which sort after every real timestamp
        # and would silently make an old partial run the default.
        cand = [c for c in glob.glob(os.path.join(ROOT, 'out', 'soak', '*')) if os.path.isdir(c)]
        if not cand:
            print('no soak directories under out/soak/')
            return 1
        dirs = [max(cand, key=os.path.getmtime)]
    for d in dirs:
        rejudge(d)
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main())

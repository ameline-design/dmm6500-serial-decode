#!/usr/bin/env python3
"""Classify an elision lap's cells from out/bench/SOAK.csv, and say which mechanism each failure is.

    python3 tools/judge_elide.py                       # the last run in the record
    python3 tools/judge_elide.py --from 17814           # from a line number
    python3 tools/judge_elide.py --cells                # one line per failing cell

WHY THIS EXISTS. An elided cell that fails reports `FAIL acq: stream_acquire returned nothing` and that
one sentence used to cover three endings, because stream_acquire() sets no lasterr on most of its exits.
Three laps were spent reading it as one fault. The row now carries endwhy, got, armexp and armpair, and
this file is the arithmetic that turns them into a mechanism:

  noarm, got=0, arm outside its own swing    the comparator was pointed where the line never goes
  noarm, got=0, arm inside its own swing     it was pointed correctly and no crossing was detected
  noarm, got>0                               it DID fire and the host's model-state read gave up

The third is the one worth watching for: the elision program is a branch loop that re-enters its own
wait block on every pass, so a host polling trigger.model.state() can see STATE_WAITING on a model that
is working. Separating it from a real detection limit is the whole point of recording `got`.

THE SWING IS THE COMMANDED PAIR, which is not always what reached the wire -- the SDG2122X clamps to
|OFST| + AMP/2 <= 10 V and soakplan's draw does not respect it. Where the row carries armpair the
measured pair is used instead and the commanded one is reported beside it, so a disagreement between
them is visible rather than averaged away. notes/FINDING-elide-noarm.md.
"""
import argparse
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REC = os.path.join(ROOT, 'out', 'bench', 'SOAK.csv')


def last_run_start(lines):
    """The index of the last '# serdec-soak' header, which is where the newest run begins."""
    at = 0
    for i, ln in enumerate(lines):
        if ln.startswith('# serdec-soak'):
            at = i
    return at


def pairs(lines, start):
    """(R fields, S note) for every elided cell, R and S being written as a pair per cell."""
    out, cur = [], None
    for ln in lines[start:]:
        f = ln.rstrip('\n').split(',')
        if f[0] == 'R':
            cur = f
        elif f[0] == 'S' and cur is not None and 'elide=' in ln:
            out.append((cur, ','.join(f[8:])))
            cur = None
    return out


def num(note, key):
    m = re.search(r'\b%s=(-?[\d.]+)' % key, note)
    return float(m.group(1)) if m else None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--record', default=REC)
    ap.add_argument('--from', dest='frm', type=int, default=None,
                    help='line to start at; the default is the last run in the file')
    ap.add_argument('--cells', action='store_true', help='one line per failing cell')
    a = ap.parse_args(argv)

    if not os.path.exists(a.record):
        raise SystemExit('REFUSING: no record at %s' % a.record)
    lines = open(a.record, errors='replace').readlines()
    start = a.frm if a.frm is not None else last_run_start(lines)
    rows = pairs(lines, start)
    if not rows:
        raise SystemExit('REFUSING: no elided cells after line %d, so there is nothing to judge'
                         % start)

    kinds = collections.Counter()
    bybaud = collections.defaultdict(lambda: [0, 0])
    detail = []
    nelide = nfell = 0
    for r, note in rows:
        cell, vid, baud = r[2], r[3], float(r[4])
        amp, ofst = float(r[6]), float(r[7])
        clo, chi = ofst - amp / 2.0, ofst + amp / 2.0
        nelide += ('elide=FELLBACK' not in note)
        nfell += ('elide=FELLBACK' in note)
        bybaud[baud][0] += 1
        ok = note.startswith('ok')
        if ok:
            kinds['ok'] += 1
            continue
        bybaud[baud][1] += 1
        if 'endwhy=noarm' not in note:
            kinds['other: ' + note.split(' elide=')[0][:40]] += 1
            continue
        got, exp = num(note, 'got'), num(note, 'armexp')
        mp = re.search(r'armpair=(-?[\d.]+)/(-?[\d.]+)', note)
        lo, hi = (float(mp.group(1)), float(mp.group(2))) if mp else (clo, chi)
        if got is not None and got > 0:
            kind = 'noarm but got>0 -- it fired, the host gave up'
        elif exp is None:
            kind = 'noarm, no level recorded'
        elif not (lo < exp < hi):
            kind = 'noarm, arm OUTSIDE its swing'
        else:
            kind = 'noarm, arm inside its swing'
        kinds[kind] += 1
        detail.append((cell, vid, baud, lo, hi, clo, chi, exp, got, kind))

    n = len(rows)
    print('%d elided cell(s) from line %d: %d elided, %d fell back' % (n, start, nelide, nfell))
    print()
    for k, c in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print('  %5d  %5.1f%%  %s' % (c, 100.0 * c / n, k))

    lo19 = [(c, f) for b, (c, f) in bybaud.items() if b <= 19200]
    hi19 = [(c, f) for b, (c, f) in bybaud.items() if b > 19200]
    print()
    print('  at or below 19200 Bd: %d cell(s), %d failed' % (sum(c for c, _ in lo19),
                                                             sum(f for _, f in lo19)))
    print('  above 19200 Bd:       %d cell(s), %d failed' % (sum(c for c, _ in hi19),
                                                             sum(f for _, f in hi19)))
    print()
    print('  baud      cells  failed')
    for b in sorted(bybaud):
        c, f = bybaud[b]
        print('  %8.0f %5d %5d  %s' % (b, c, f, '#' * f))

    if a.cells and detail:
        print()
        print('  cell vid    baud      measured pair        commanded pair       armexp   got')
        for cell, vid, baud, lo, hi, clo, chi, exp, got, kind in detail:
            print('  %-5s %-6s %7.0f  %7.3f..%7.3f  %7.3f..%7.3f  %7s %5s  %s'
                  % (cell, vid, baud, lo, hi, clo, chi,
                     '%.3f' % exp if exp is not None else '-',
                     '%.0f' % got if got is not None else '-', kind))
    return 0


if __name__ == '__main__':
    sys.exit(main())

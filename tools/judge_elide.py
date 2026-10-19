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
import subprocess
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


def judged_bad(record):
    """The set of cell numbers the JUDGE calls bad, from judge_bench itself.

    ONE ORACLE. judge_bench compares the decoded bytes against the expected payload with rules this
    file has no business restating -- alignment, head damage, the three verdicts -- so the verdict is
    taken from it rather than recomputed. A second implementation here would be a second answer, and
    the first thing to go wrong would be the two disagreeing quietly.
    """
    out = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'judge_bench.py'),
                          record, '--verbose', '--verbose-max', '0'],
                         capture_output=True, text=True).stdout
    bad = set(m.group(1) for m in re.finditer(r'^\s+L1C(\d+)\s', out, re.M))
    if not bad:
        # A judge that found nothing is far more likely to be a parse mismatch than a perfect lap,
        # and silently reporting 0 % bad in every bucket is exactly how this analysis went wrong.
        print('NOTE: judge_bench reported no failing cell. If that is not a clean lap, the verbose')
        print('      line format has moved and this join is reading nothing.')
    return bad


def pad_report(record, lines, start, rows):
    """Judged outcome against the padding inserted, bucketed by readings per seam."""
    bad = judged_bad(record)
    buckets = [(-1, -1, 'no pad'), (1, 4, '1-4 rd/seam'), (5, 8, '5-8 rd/seam'),
               (9, 14, '9-14 rd/seam'), (15, 10 ** 9, '15+ rd/seam')]
    got = collections.defaultdict(lambda: [0, 0])
    npad = 0
    for r, note in rows:
        cell = r[2]
        m = re.search(r'splpad=(\d+)/(\d+)', note)
        per = None
        if m and int(m.group(2)) > 0:
            per = int(m.group(1)) / float(m.group(2))
            npad += 1
        for lo, hi, lab in buckets:
            if (per is None and lo < 0) or (per is not None and lo >= 0 and lo <= round(per) <= hi):
                got[lab][0] += 1
                got[lab][1] += 1 if cell in bad else 0
                break
    print('%d elided cell(s), %d padded, judged against %d bad cell(s)'
          % (len(rows), npad, len(bad)))
    print()
    print('%-14s %6s %6s %8s' % ('pad per seam', 'cells', 'bad', 'bad rate'))
    for _, _, lab in buckets:
        n, b = got[lab]
        if n:
            print('%-14s %6d %6d %7.1f%%' % (lab, n, b, 100.0 * b / n))
    print()
    # THE TREND, stated rather than left to the reader, because a monotone one is the whole claim:
    # more padding means fewer failures, which is what says the mechanism is right and the constant
    # is too small. Anything else and the constant has gone past the latency.
    seq = [(lab, got[lab]) for _, _, lab in buckets if got[lab][0] and lab != 'no pad']
    rates = [100.0 * b / n for _, (n, b) in seq]
    if len(rates) >= 2:
        if all(rates[i] >= rates[i + 1] for i in range(len(rates) - 1)):
            print('MONOTONE DOWN: more padding, fewer failures. The mechanism holds and the')
            print('constant is still too SMALL -- raise sdec.gap_resume and measure again.')
        elif all(rates[i] <= rates[i + 1] for i in range(len(rates) - 1)):
            print('MONOTONE UP: more padding, MORE failures. The constant is past the latency.')
        else:
            print('NOT MONOTONE: %s. The peak brackets the latency between its neighbours.'
                  % ' '.join('%.0f%%' % x for x in rates))
    # AND THE CONFOUND, named rather than omitted: pad size is not assigned, it is derived from fs
    # and the recovered head, so cells with large pads differ in rate and baud too. The clean
    # comparison is the SAME cells across two laps at different gap_resume values.
    print()
    print('Pad size is DERIVED, not assigned -- it is gap_resume * fs less the recovered head -- so')
    print('these buckets differ in rate and baud as well. The assigned comparison is the same spec')
    print('run at two gap_resume values; this is the within-lap gradient only.')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--record', default=REC)
    ap.add_argument('--from', dest='frm', type=int, default=None,
                    help='line to start at; the default is the last run in the file')
    ap.add_argument('--cells', action='store_true', help='one line per failing cell')
    # THE DOSE-RESPONSE JOIN, and it is a mode here because doing it by hand got the record's shape
    # wrong twice in one day: the cell number is field 2 of the R row, NOT an `L1C` prefix on the S
    # row, and the judge's verdict is not the literal word FAIL in the S note -- a hand-rolled version
    # of each reported 0 failures for every bucket, which reads as a clean result.
    ap.add_argument('--pad', action='store_true',
                    help='judged outcome against the seam padding actually inserted, bucketed. '
                         'Answers whether more padding means fewer failures')
    a = ap.parse_args(argv)

    if not os.path.exists(a.record):
        raise SystemExit('REFUSING: no record at %s' % a.record)
    lines = open(a.record, errors='replace').readlines()
    start = a.frm if a.frm is not None else last_run_start(lines)
    rows = pairs(lines, start)
    if not rows:
        raise SystemExit('REFUSING: no elided cells after line %d, so there is nothing to judge'
                         % start)

    if a.pad:
        return pad_report(a.record, lines, start, rows)

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

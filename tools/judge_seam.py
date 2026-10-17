#!/usr/bin/env python3
"""Per-segment alignment of an elided record, because a single shift under-reports it badly.

WHY THIS EXISTS. Both tools/judge_bench.py and bench/expect.tsp's bexp.match align a capture
against the payload on ONE best cyclic shift. That is right for a contiguous record and wrong
for an elided one: the 2026-10-17 lap showed each elision seam costing a fixed 104-156 us of
signal, which is over the framer's half-bit sampling margin from 4800 Bd up, so the record
comes back as a chain of segments each byte-exact at a shift ONE HIGHER than the last. A single
shift fits one segment and scores the rest wrong -- 33-73 % on cells carrying almost no wrong
bytes.

So this reports both figures side by side. The gap between them is the metric's error.

WHAT THE +1 DELTA IS NOT. It is the net change in FRAME COUNT across a seam, not the byte loss.
The record is missing the resume latency of wire at every burst start, so 4-9 payload bytes per
seam are destroyed -- 3-8 frames of which 2-5 are flagged and 2-4 confidently wrong. On cell 4
of the 2026-10-17 lap that is 6 unmatched confident bytes plus 7 flagged, 13 across 2 seams.

So the per-segment figure is NOT a pass. A `nodrop` vector exists so that a declined byte inside
the body is the failure being looked for, and these cells really do drop the first bytes of
every burst: judge_bench is right to fail them. What it is wrong about is the DESCRIPTION --
"not the payload, silently wrong, 60 %" is a claim about 2-3 % of the bytes, because a single
shift cannot express a frame-count change and so charges everything after the first seam.

WHAT IT DOES NOT DO. It does not replace the judge. Per-segment alignment is strictly more
permissive -- give it enough segments and it will fit noise -- so it is a diagnostic and not a
gate. Two guards keep it honest and both are reported: a segment must be at least MINSEG bytes
to earn its own shift, and the segment COUNT is printed, because a record needing fifty
segments to align is itself the finding.

Usage:  python3 tools/judge_seam.py [out/bench/SOAK.csv] [--run N] [--vid v98a]
"""
import argparse
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECDIR = os.path.join(ROOT, 'out', 'vectors')

# A segment shorter than this gets no shift of its own: at 8 bytes a cyclic prose payload of 130
# has roughly a 1-in-10 chance of fitting somewhere by luck, and segments that short are the
# debris around a seam rather than body text.
MINSEG = 8


def payload(vid):
    p = os.path.join(VECDIR, vid + '.txt')
    if not os.path.exists(p):
        return None
    with open(p, 'rb') as f:
        return f.read()


def best_shift(vals, want, at):
    """Best cyclic shift for one run of confident bytes. -> (nmatch, shift)

    `at` is the run's frame index, so a shift means the same thing to every run: the payload
    index that frame 0 of the capture would have sat at.
    """
    wl = len(want)
    best, bshift = -1, None
    for sh in range(wl):
        n = 0
        for k, v in enumerate(vals):
            if v == want[(sh + at + k) % wl]:
                n += 1
        if n > best:
            best, bshift = n, sh
    return best, bshift


def split_runs(toks):
    """-> list of (frame_index, [byte, ...]) for each run of confident frames."""
    runs, cur, start = [], [], None
    for i, t in enumerate(toks):
        if t == '??' or not re.fullmatch(r'[0-9a-fA-F]{2}', t):
            if cur:
                runs.append((start, cur))
            cur, start = [], None
        else:
            if start is None:
                start = i
            cur.append(int(t, 16))
    if cur:
        runs.append((start, cur))
    return runs


def judge_cell(hexs, want):
    toks = [hexs[i:i + 2] for i in range(0, len(hexs), 2)]
    runs = split_runs(toks)
    ncmp = sum(len(v) for _, v in runs)
    if ncmp < MINSEG or not want:
        return None

    # ONE SHIFT, which is what the judges do today.
    allv, allat = [], []
    for at, vals in runs:
        for k, v in enumerate(vals):
            allv.append(v)
            allat.append(at + k)
    wl = len(want)
    one = -1
    for sh in range(wl):
        n = 0
        for v, a in zip(allv, allat):
            if v == want[(sh + a) % wl]:
                n += 1
        if n > one:
            one = n

    # PER SEGMENT, with the short runs scored against their neighbour's shift rather than given
    # one of their own -- otherwise the debris each seam produces would be fitted individually.
    seg, shifts, nshort = 0, [], 0
    last = None
    for at, vals in runs:
        if len(vals) >= MINSEG:
            n, sh = best_shift(vals, want, at)
            seg += n
            shifts.append(sh)
            last = sh
        else:
            nshort += len(vals)
            if last is not None:
                seg += sum(1 for k, v in enumerate(vals)
                           if v == want[(last + at + k) % wl])
    return {'ncmp': ncmp, 'one': one, 'seg': seg, 'nseg': len(shifts),
            'shifts': shifts, 'nshort': nshort}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?', default=os.path.join(ROOT, 'out', 'bench', 'SOAK.csv'))
    ap.add_argument('--run', type=int, default=None,
                    help='how many trailing R rows to read; default is the last run header')
    ap.add_argument('--vid', default=None, help='only this vector')
    # ONE RECORD FROM THE OFFLINE TWIN, where the ground truth is known. The +1 delta is the central
    # claim -- that a seam consumes one payload byte without emitting a frame -- and on the instrument
    # it is an inference from the deltas themselves. tools/test_elideseam.lua prints the hex of a cell
    # it built with a KNOWN resume latency, so feeding it here checks the interpretation against a
    # record whose loss is a parameter rather than a hypothesis.
    ap.add_argument('--hex', default=None, metavar='HEX',
                    help='judge one hex string instead of a record; needs --vid')
    a = ap.parse_args()

    if a.hex:
        if not a.vid:
            print('judge_seam: --hex needs --vid')
            return 2
        want = payload(a.vid)
        if not want:
            print('judge_seam: no payload for %s' % a.vid)
            return 2
        v = judge_cell(a.hex.strip(), want)
        if v is None:
            print('judge_seam: too few confident bytes to judge')
            return 1
        deltas = [v['shifts'][i + 1] - v['shifts'][i] for i in range(len(v['shifts']) - 1)]
        print('%s  %d confident byte(s)' % (a.vid, v['ncmp']))
        print('  one shift   %d (%.0f%%)' % (v['one'], 100.0 * v['one'] / v['ncmp']))
        print('  per segment %d (%.0f%%) across %d segment(s)'
              % (v['seg'], 100.0 * v['seg'] / v['ncmp'], v['nseg']))
        print('  shift deltas %s' % ' '.join('%+d' % d for d in deltas))
        return 0

    rows = []
    with open(a.path, 'r', errors='replace') as f:
        for line in f:
            if line.startswith('R,'):
                rows.append(line.rstrip('\n').split(','))
    if not rows:
        print('judge_seam: no result rows in %s' % a.path)
        return 1
    if a.run:
        rows = rows[-a.run:]

    want = {}
    print('%-5s %-6s %-8s %-6s %-11s %-11s %-6s %s'
          % ('cell', 'vid', 'baud', 'ncmp', 'one shift', 'per segment', 'segs', 'shift deltas'))
    tot = collections.Counter()
    for r in rows:
        if len(r) < 24:
            continue
        vid, baud, hexs = r[3], r[4], r[-1]
        if a.vid and vid != a.vid:
            continue
        if vid not in want:
            want[vid] = payload(vid)
        if not want[vid]:
            continue
        v = judge_cell(hexs, want[vid])
        if v is None:
            continue
        deltas = [v['shifts'][i + 1] - v['shifts'][i] for i in range(len(v['shifts']) - 1)]
        tot['ncmp'] += v['ncmp']
        tot['one'] += v['one']
        tot['seg'] += v['seg']
        tot['cells'] += 1
        print('%-5s %-6s %-8s %-6d %-11s %-11s %-6d %s'
              % (r[2], vid, baud, v['ncmp'],
                 '%d (%.0f%%)' % (v['one'], 100.0 * v['one'] / v['ncmp']),
                 '%d (%.0f%%)' % (v['seg'], 100.0 * v['seg'] / v['ncmp']),
                 v['nseg'], ' '.join('%+d' % d for d in deltas[:12])))

    if tot['cells']:
        print('\n%d cell(s), %d confident byte(s)' % (tot['cells'], tot['ncmp']))
        print('  one shift   %d matched, %.1f%%' % (tot['one'], 100.0 * tot['one'] / tot['ncmp']))
        print('  per segment %d matched, %.1f%%' % (tot['seg'], 100.0 * tot['seg'] / tot['ncmp']))
        print('  the difference is the metric, not the decoder: %d byte(s)'
              % (tot['seg'] - tot['one']))
        # THE SIGNATURE. A fixed loss at each seam advances the alignment by a constant, so the
        # deltas should cluster on one small positive number. Scattered deltas mean something
        # else is moving the alignment and this account is wrong.
        print('  a shift delta clustered on one small positive value is the per-seam loss;')
        print('  scattered deltas mean the alignment is moving for another reason')
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Decompose a --rate-diag record: what the rate finder proposed BEFORE sig_snap moved it.

WHY THIS EXISTS. RCOLS keeps read_baud, which is sdec.baud -- the rate AFTER sig_snap. So a misreported
rate is indistinguishable between two unrelated faults: the width fit was right and the snap went to a
wrong neighbour, or the fit itself landed on the wrong solution. brun.ratediag puts sdec.baud_raw on the
per-cell status note, and baud_raw / commanded separates them in one division.

THE THREE MECHANISMS THIS IS BUILT TO TELL APART, each with a prediction fixed before the run:

  SNAP BOUNDARY   37500 and 125000 are the plan's kind='edge' rates (floor(fs/8)) and the only two that
                  sit BELOW a standard rate -- 2.344 % under 38400/128000, i.e. 0.352 % outside
                  sdec.snaptol. Predict: read_baud is exactly the standard rate, snapfirm=false, and
                  rawbaud lands +0.35..2 % high. The app prints '38400?' and autolocks from baud_raw
                  instead, so it does not stand behind the number the judge fails it on.

  EXACT DOUBLE    125000 is the ONLY edge rate whose double (250000) is itself a standard rate, and
                  8.00 sa/bit halves to exactly sdec.minsabit = 4, so ua_plausible accepts it. Predict:
                  read_baud 250000, snapfirm=TRUE, and rawbaud ~= 250000 -- the fit itself doubled. If
                  rawbaud comes back near 125000 the doubling happens later than sig_bittime and this
                  mechanism is wrong.

  SOMETHING ELSE  rawbaud within 0.35 % of the commanded rate while read_baud is wrong => the fit was
                  right and the fault is downstream. That is the outcome that refutes both hypotheses.

Also reports the straddle/alphabet controls (v71, v76 must now be clean) and any cell whose measured
band crossed ground, which after the envelope fix should be none outside v47/v48a/v48b.

    python3 tools/judge_ratediag.py [out/bench/hot1/SOAK.csv] [--plan out/bench/hot1/PLAN.csv]
"""
import argparse
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_uart as BU                                                 # noqa: E402
import judge_bench as JB                                                # noqa: E402
import soakplan as SP                                                   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FF = SP.FLATFLOOR
CEIL = 10.0
SUSPECT = {37500: 38400, 125000: 128000}
EXEMPT = ('v47', 'v48a', 'v48b')        # min_v < 0: RS-232-shaped in the file, straddle by design

RATE = re.compile(r'rawbaud=(\S+) bittime=(\S+) fitq=(\S+) snap=(\S+)/(\S+)')
IDLE = re.compile(r'idle=(\S+) weak=(\S+) run0=(\S+) run1=(\S+) onebit=(\S+) ratio=(\S+) '
                  r'lo=(\S+) hi=(\S+)')


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def band(vid, amp, ofst):
    lo, hi = SP._cw_span(vid)
    return ofst + lo / 32767.0 * (amp / 2.0), ofst + hi / 32767.0 * (amp / 2.0)


def ratebad(r):
    """Is the REPORTED rate more than 2 % from the commanded one? -> bool

    COMPUTED SEPARATELY FROM verdict(), and that is not duplication. verdict() mirrors judge_bench, which
    returns INCONCLUSIVE before it ever looks at the rate -- so a cell with a wrong rate and too few
    trusted bytes to judge is 'inc', not 'rate'. Filtering the mechanism table on the verdict therefore
    drops exactly the cells most likely to have a short window, which at 250000 baud is most of them.
    The rate question is independent of the byte question and is asked independently.
    """
    try:
        return abs(float(r['read_baud']) / float(r['baud']) - 1) > 0.02
    except (ValueError, ZeroDivisionError, TypeError):
        return True


def verdict(r):
    """judge_bench's own verdict, so this tool cannot disagree with the gate. -> str"""
    if r['why'].startswith('SDG:'):
        return 'sdg'
    if r['ran'] != 'y':
        return 'pass' if SP.expect_for(r['vid']) == 'loud' else 'nodec'
    want = JB.payloads(r['vid'])
    got = r['hex'].upper()
    try:
        hs = int(r['headsusp'] or 0)
    except (TypeError, ValueError):
        hs = 0
    got = got[2 * BU.head_damage(got, hs):]
    v, lin = 'INCONCLUSIVE', bool(want) and JB.is_lin(r['vid'])
    for w in (want or []):
        g, syn = (BU.lin_repair(got, w) if lin else (got, set()))
        v = BU.judge_payload_v(g, w, SP.expect_for(r['vid']), synth=syn)[0]
        if v == 'PASS':
            break
    ratebad = True
    try:
        ratebad = abs(float(r['read_baud']) / float(r['baud']) - 1) > 0.02
    except ValueError:
        pass
    if v == 'PASS' and not ratebad:
        return 'pass'
    if v == 'INCONCLUSIVE':
        return 'inc'
    return 'rate' if ratebad else 'byte'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?',
                    default=os.path.join(ROOT, 'out', 'bench', 'hot1', 'SOAK.csv'))
    ap.add_argument('--plan', default=os.path.join(ROOT, 'out', 'bench', 'hot1', 'PLAN.csv'))
    ap.add_argument('--top', type=int, default=26)
    a = ap.parse_args()

    lines = open(a.path, errors='replace').read().splitlines()
    runs = JB.split_runs(lines)
    body = runs[-1][1]
    R, S = {}, {}
    for ln in body:
        f = ln.split(',')
        if ln.startswith('R,') and len(f) - 1 >= len(JB.RCOLS):
            d = dict(zip(JB.RCOLS, f[1:1 + len(JB.RCOLS)]))
            R[(d['iter'], d['cell'])] = d
        elif ln.startswith('S,') and len(f) > 8:
            S.setdefault((f[2], f[3]), ','.join(f[8:]))
    print('%s\n%d run(s); last run %d cell(s), %d lap(s)'
          % (a.path, len(runs), len(R), len({k[0] for k in R})))
    if not R:
        raise SystemExit('no cells: an empty record is a FAILURE, not an empty file')

    cells = []
    ndiag = 0
    for k in sorted(R, key=lambda kv: (int(kv[0]), int(kv[1]))):
        d = dict(R[k])
        note = S.get(k) or ''
        m, mi = RATE.search(note), IDLE.search(note)
        if m:
            ndiag += 1
            d['_raw'], d['_bt'], d['_fitq'] = fnum(m.group(1)), fnum(m.group(2)), m.group(3)
            d['_snapped'], d['_firm'] = m.group(4), m.group(5)
        if mi:
            d['_idle'], d['_weak'], d['_ratio'] = mi.group(1), mi.group(2), mi.group(6)
            d['_lo'], d['_hi'] = fnum(mi.group(7)), fnum(mi.group(8))
        d['_key'] = 'L%sC%s' % k
        d['_v'] = verdict(d)
        d['_rb'] = ratebad(d)
        cells.append(d)
    print('  %d cell(s) carry the rate diagnostic' % ndiag)
    if not ndiag:
        raise SystemExit('no rate diagnostic on any cell -- was --rate-diag passed?')

    tally = collections.Counter(c['_v'] for c in cells)
    print('  verdicts: %s' % ', '.join('%s %d' % kv for kv in sorted(tally.items())))

    # ---- the three mechanisms -------------------------------------------------------------------
    nrb = sum(1 for c in cells if c['_rb'])
    print('  cells whose REPORTED rate is >2 %% off: %d  (of which the judge calls %d a rate miss and'
          ' %d inconclusive on bytes)'
          % (nrb, sum(1 for c in cells if c['_rb'] and c['_v'] == 'rate'),
             sum(1 for c in cells if c['_rb'] and c['_v'] == 'inc')))

    print('\n== WHAT THE FIT PROPOSED, on every cell whose REPORTED rate is wrong ==')
    print('%-9s %-5s %8s %10s %10s %8s %-6s %-6s %s'
          % ('cell', 'vid', 'commanded', 'read_baud', 'RAWBAUD', 'raw/cmd', 'snap', 'firm', 'mechanism'))
    mech = collections.Counter()
    shown = 0
    for c in cells:
        if not c['_rb'] or '_raw' not in c:
            continue
        cmd = fnum(c['baud'])
        rd = fnum(c['read_baud'])
        raw = c['_raw']
        if None in (cmd, rd, raw) or cmd <= 0:
            continue
        ratio = raw / cmd
        if abs(ratio - 2.0) < 0.05:
            why = 'EXACT DOUBLE (fit doubled)'
        elif abs(ratio - 0.5) < 0.05:
            why = 'exact half'
        elif 1.0035 <= ratio <= 1.021 and int(round(rd)) in SUSPECT.values():
            why = 'SNAP BOUNDARY (fit %+.2f %% high)' % (100 * (ratio - 1))
        elif abs(ratio - 1) <= 0.0035:
            why = 'FIT WAS RIGHT -- fault is downstream'
        else:
            why = 'fit off %+.2f %%' % (100 * (ratio - 1))
        mech[why.split(' (')[0]] += 1
        shown += 1
        if shown <= a.top:
            print('%-9s %-5s %10.0f %10.0f %10.1f %8.4f %-6s %-6s %s'
                  % (c['_key'], c['vid'], cmd, rd, raw, ratio,
                     c.get('_snapped', '?'), c.get('_firm', '?'), why))
    print('\n  mechanism tally over ALL %d wrong-rate cell(s):' % sum(mech.values()))
    for w, n in mech.most_common():
        print('    %-42s %5d' % (w, n))

    # ---- per pair -------------------------------------------------------------------------------
    print('\n== PER (VECTOR, RATE): failure rate and the raw fit ==')
    per = collections.defaultdict(lambda: [0, 0, []])
    for c in cells:
        cmd = fnum(c['baud'])
        if cmd is None:
            continue
        k = (c['vid'], int(round(cmd)))
        per[k][0] += 1
        if c['_v'] in ('rate', 'byte', 'nodec'):
            per[k][1] += 1
        if '_raw' in c and c['_raw'] and cmd > 0:
            per[k][2].append(c['_raw'] / cmd)
    print('%-6s %8s %6s %6s %8s  %-11s %s'
          % ('vid', 'baud', 'cells', 'fail', 'rate', 'class', 'raw/cmd  min..max (median)'))
    for k in sorted(per, key=lambda x: -(per[x][1] / max(per[x][0], 1))):
        n, fl, rr = per[k]
        rs = ''
        if rr:
            rr = sorted(rr)
            rs = '%.4f..%.4f (%.4f)' % (rr[0], rr[-1], rr[len(rr) // 2])
        print('%-6s %8d %6d %6d %7.1f%%  %-11s %s'
              % (k[0], k[1], n, fl, 100.0 * fl / max(n, 1), SP.expect_for(k[0]), rs))

    # ---- controls -------------------------------------------------------------------------------
    print('\n== CONTROLS: the envelope fix, and any band still crossing ground ==')
    for vid in ('v71', 'v76', 'v93'):
        sub = [c for c in cells if c['vid'] == vid]
        bad = [c for c in sub if c['_v'] in ('rate', 'byte', 'nodec')]
        inv = [c for c in sub if c.get('_idle') == '0']
        if sub:
            print('  %-5s %4d cell(s)  %d failure(s)  %d inverted   %s'
                  % (vid, len(sub), len(bad), len(inv),
                     'CLEAN' if not bad and not inv else 'SEE ABOVE'))
    strad = [c for c in cells
             if c.get('_lo') is not None and c['_lo'] < -FF and c.get('_hi', 0) > FF]
    byv = collections.Counter(c['vid'] for c in strad)
    print('  bands measured crossing ground: %d cell(s)%s'
          % (len(strad), (' -> ' + ', '.join('%s %d' % kv for kv in byv.most_common())) if strad else ''))
    unexpected = {v: n for v, n in byv.items() if v not in EXEMPT}
    if unexpected:
        print('  UNEXPECTED (not an RS-232-shaped vector): %s' % unexpected)
    else:
        print('  all of them on %s, which straddle by design' % ', '.join(EXEMPT))


if __name__ == '__main__':
    main()

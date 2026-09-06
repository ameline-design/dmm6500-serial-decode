#!/usr/bin/env python3
"""Read the ground-straddle experiment's record and score it against the predictions. -> a table

THE PREDICTIONS ARE FIXED BEFORE THE LAP RUNS, in tools/mkplan_abc.py, and this only scores them. That
matters more than usual here: the effect being tested was first reached by elimination and twice
attributed to the wrong mechanism, so the value of the lap is entirely in it being able to come back NO.

WHAT IS MEASURED THAT WAS NOT BEFORE. sdec.lo and sdec.hi now ride the per-cell diagnostic note, so the
record finally says what reached the wire rather than only what the plan commanded. The two differ
whenever |OFST| + AMP/2 > 10 V, because bsdg.select writes BSWV and never reads it back.

    SWEEP   ofst = -(10 - amp/2), so nothing clamps and the band is exactly as asked. The band straddles
            ground for 13.253 < amp < 18.000 Vpp at frac 0.660, and predicts an INVERTED decode there and
            a clean one on BOTH sides. A defect window with a clean side above it is the shape no decoder
            fault has.
    ZERO    the same amplitudes at ofst 0: band 0..hi, never straddling. Predicts clean, which is what
            separates the straddle from the amplitude.
    PAIR    the diagnostic's own cells, as commanded (A) and with the offset pre-clamped by the host (B).
            Equal measured lo/hi means the generator clamps the offset, which is the only step of the
            chain that was pure inference.

AND THE ALPHABET IS THE CONTROL, not an afterthought: v71/v76 are Lorem (ASCII, constant top data bit)
and v93 is random bytes over the same codeword span. A straddling band only sets sig_idle's PRIOR --
uart_decode.tsp:1747 lets ua_autoformat's contest override it -- and ASCII is what stops the contest
working, because a constant top bit puts a rising edge exactly nine bit times after every start bit and
the inverted framing scores as well as the correct one. So v71/v76 should invert inside the window and
v93 should not, on a wire that is identical.

    python3 tools/judge_abc.py [out/bench/abc1/SOAK.csv] [--plan out/bench/abc1/PLAN.csv]
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
CEIL = 10.0
FF = SP.FLATFLOOR

DIAG = re.compile(r'idle=(\S+) weak=(\S+) run0=(\S+) run1=(\S+) onebit=(\S+) ratio=(\S+) '
                  r'lo=(\S+) hi=(\S+)')
ASCII_VECS = ('v71', 'v76')          # Lorem: top data bit always 0


def band(vid, amp, ofst):
    lo, hi = SP._cw_span(vid)
    return ofst + lo / 32767.0 * (amp / 2.0), ofst + hi / 32767.0 * (amp / 2.0)


def preclamp(amp, ofst):
    a = min(amp, 2 * CEIL)
    lim = CEIL - a / 2.0
    return a, max(-lim, min(lim, ofst))


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def read_record(path):
    """-> list of per-cell dicts, in plan order, with the diagnostic fields parsed."""
    lines = open(path, errors='replace').read().splitlines()
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
    out = []
    for k in sorted(R, key=lambda kv: (int(kv[0]), int(kv[1]))):
        d = dict(R[k])
        d['_key'] = 'L%sC%s' % k
        note = S.get(k) or ''
        d['_note'] = note
        m = DIAG.search(note)
        if m:
            (d['_idle'], d['_weak'], d['_run0'], d['_run1'],
             d['_onebit'], d['_ratio'], d['_lo'], d['_hi']) = m.groups()
        out.append(d)
    return out, len(runs)


def verdict(r):
    """judge_bench's own byte/rate verdict for one row. -> 'pass'|'fail'|'inc'|'nodec'|'sdg'"""
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
    v = 'INCONCLUSIVE'
    for w in (want or []):
        v = BU.judge_payload_v(got, w, SP.expect_for(r['vid']))[0]
        if v == 'PASS':
            break
    ratebad = True
    try:
        ratebad = abs(float(r['read_baud']) / float(r['baud']) - 1) > 0.02
    except ValueError:
        pass
    if v == 'PASS' and not ratebad:
        return 'pass'
    return 'inc' if v == 'INCONCLUSIVE' else 'fail'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?', default=os.path.join(ROOT, 'out', 'bench', 'abc1', 'SOAK.csv'))
    ap.add_argument('--plan', default=os.path.join(ROOT, 'out', 'bench', 'abc1', 'PLAN.csv'))
    a = ap.parse_args()

    rows, nruns = read_record(a.path)
    print('%s\n%d run(s) in the file, %d cell(s) in the last one' % (a.path, nruns, len(rows)))
    if not rows:
        raise SystemExit('no cells: the record is empty, which is a FAILURE and not an empty file')

    # THE RECEIPT. Every conclusion below is keyed on which cell carried which amplitude and offset, so a
    # record judged against the wrong plan is not a weaker result -- it is a confidently wrong one. Checked
    # cell by cell rather than by counting rows, because two plans of the same length are the easy mistake.
    if os.path.exists(a.plan):
        want = {}
        for ln in open(a.plan):
            if not ln[:1].isdigit():
                continue
            f = ln.strip().split(',')
            want[f[1]] = (f[2], int(f[4]), round(float(f[6]), 3), round(float(f[7]), 3))
        bad = []
        for r in rows:
            w = want.get(r['cell'])
            if w is None:
                bad.append('%s is not in the plan' % r['_key'])
                continue
            got = (r['vid'], int(round(float(r['baud']))),
                   round(float(r['amp_vpp']), 3), round(float(r['ofst_v']), 3))
            if got != w:
                bad.append('%s: record %s, plan %s' % (r['_key'], got, w))
        if bad:
            raise SystemExit('REFUSING: the record does not match %s\n  %s'
                             % (a.plan, '\n  '.join(bad[:6])))
        print('  receipt: all %d cell(s) match %s on vector, baud, amplitude and offset'
              % (len(rows), os.path.relpath(a.plan, ROOT)))
    else:
        print('  WARNING: %s is absent, so the cell attribution below is unverified' % a.plan)
    nodiag = [r['_key'] for r in rows if '_idle' not in r]
    if nodiag:
        print('WARNING: %d cell(s) carry no diagnostic note (first: %s) -- was --idle-diag set?'
              % (len(nodiag), nodiag[0]))

    # ---- what reached the wire, against the two models ------------------------------------------
    print('\n== WHAT DID THE GENERATOR DO WITH AN OUT-OF-ENVELOPE PAIR? measured lo/hi vs three models ==')
    print('  commanded  the wire carries what the plan asked for -- the envelope is not real')
    print('  clamped    the offset was held to +-(10 - AMP/2), the amplitude honoured')
    print('  refused    the command was rejected and the PREVIOUS cell\'s pair is still playing')
    print('Only cells where the models disagree can tell them apart, so the rest are skipped.')
    print('%-9s %-5s %8s %8s %7s  %-15s %-15s %-15s %s'
          % ('cell', 'vid', 'amp', 'ofst', 'env', 'commanded', 'clamped', 'MEASURED', 'supports'))
    score = collections.Counter()
    prev = None
    for r in rows:
        amp, ofst = fnum(r['amp_vpp']), fnum(r['ofst_v'])
        if '_lo' not in r or None in (amp, ofst):
            prev = (r['vid'], amp, ofst)
            continue
        mlo, mhi = fnum(r['_lo']), fnum(r['_hi'])
        if None in (mlo, mhi):
            prev = (r['vid'], amp, ofst)
            continue
        env = abs(ofst) + amp / 2.0
        cand = {'commanded': band(r['vid'], amp, ofst),
                'clamped': band(r['vid'], *preclamp(amp, ofst))}
        # THE PREVIOUS CELL'S PAIR, on THIS cell's waveform -- a refused BSWV leaves the old amplitude and
        # offset driving whatever ARWV then selected, so the vector is this row's and the levels are not.
        if prev is not None and prev[1] is not None:
            cand['refused'] = band(r['vid'], prev[1], prev[2])
        prev = (r['vid'], amp, ofst)
        uniq = set()
        for lo_v, hi_v in cand.values():
            uniq.add((round(lo_v, 1), round(hi_v, 1)))
        if len(uniq) < 2:
            continue                                     # the models agree; no information here
        who = min(cand, key=lambda k: abs(mlo - cand[k][0]) + abs(mhi - cand[k][1]))
        score[who] += 1
        if sum(score.values()) <= 14:
            print('%-9s %-5s %8.3f %8.3f %7.3f  %6.2f..%-8.2f %6.2f..%-8.2f %6.2f..%-8.2f %s'
                  % (r['_key'], r['vid'], amp, ofst, env,
                     cand['commanded'][0], cand['commanded'][1],
                     cand['clamped'][0], cand['clamped'][1], mlo, mhi, who.upper()))
    if score:
        print('  %d discriminating cell(s): %s'
              % (sum(score.values()),
                 ', '.join('%s %d' % (k, v) for k, v in score.most_common())))
    else:
        print('  no cell discriminates -- every commanded pair was inside the envelope')

    # ---- the amplitude sweep, which is the experiment ------------------------------------------
    print('\n== THE AMPLITUDE SWEEP: a defect window with a clean side ABOVE it ==')
    byv = collections.defaultdict(list)
    for r in rows:
        if '_lo' not in r:
            continue
        amp, ofst = fnum(r['amp_vpp']), fnum(r['ofst_v'])
        if amp is None or ofst is None:
            continue
        if abs(ofst + (CEIL - amp / 2.0)) > 1e-3:        # not a sweep row
            continue
        byv[(r['vid'], r['baud'])].append(r)
    hit = miss = 0
    for key in sorted(byv):
        vid, baud = key
        lo_edge = 2.0 * (CEIL + FF) / (1.0 + (SP._cw_span(vid)[1] - SP._cw_span(vid)[0]) / 32767.0)
        print('\n%s @ %s Bd   %s   predict inverted for %.3f < amp < %.3f Vpp'
              % (vid, baud, 'ASCII payload' if vid in ASCII_VECS else 'random payload',
                 lo_edge, 2.0 * (CEIL - FF)))
        print('  %8s %8s %8s %8s %-7s %-5s %8s %-9s %-9s %s'
              % ('amp', 'ofst', 'lo', 'hi', 'straddle', 'weak', 'ratio', 'predict', 'observed', 'verdict'))
        for r in sorted(byv[key], key=lambda x: fnum(x['amp_vpp'])):
            amp, ofst = fnum(r['amp_vpp']), fnum(r['ofst_v'])
            mlo, mhi = fnum(r['_lo']), fnum(r['_hi'])
            st = (mlo is not None and mhi is not None and mlo < -FF and mhi > FF)
            # PREDICTED FROM THE MEASURED BAND, not from the commanded one. The commanded band is what
            # makes the prediction interesting; the measured band is what the decoder actually saw, and
            # scoring against anything else would score the generator instead of the app.
            #
            # THREE TERMS, ALL NECESSARY, and the third was added because the lap said so. The straddle
            # sets the prior; ASCII stops ua_autoformat overturning it; and the LEVELS branch has to be
            # the one that ran, because sig_idle only consults levels when no run reaches 10.5 bit times.
            # At 19 200 Bd the window holds a real idle gap, `ratio` is ~21.8 rather than ~6.0, the
            # run-length branch decides, and every straddling cell decodes correctly on all three vectors.
            # Scoring without the weak term called 17 of those correct decodes misses.
            pred = 'inverted' if (st and vid in ASCII_VECS and r.get('_weak') == 'y') else 'clean'
            obs = 'inverted' if r.get('_idle') == '0' else 'clean'
            ok = (pred == obs)
            hit, miss = (hit + 1, miss) if ok else (hit, miss + 1)
            print('  %8.2f %8.3f %8s %8s %-7s %-5s %8s %-9s %-9s %s  %s'
                  % (amp, ofst, r.get('_lo', '?'), r.get('_hi', '?'), 'YES' if st else 'no',
                     r.get('_weak', '?'), r.get('_ratio', '?'), pred, obs, verdict(r),
                     '' if ok else '<-- MISS'))
    print('\n  sweep predictions: %d correct, %d missed' % (hit, miss))

    # ---- the alphabet control ------------------------------------------------------------------
    print('\n== THE ALPHABET, ON AN IDENTICAL WIRE ==')
    tab = collections.Counter()
    for r in rows:
        if '_lo' not in r:
            continue
        mlo, mhi = fnum(r['_lo']), fnum(r['_hi'])
        if None in (mlo, mhi):
            continue
        st = mlo < -FF and mhi > FF
        tab[(r['vid'], st, r.get('_idle'))] += 1
    print('  %-5s %-9s %-6s %6s' % ('vid', 'straddle', 'idle', 'cells'))
    for k in sorted(tab, key=lambda x: (x[0], x[1], str(x[2]))):
        print('  %-5s %-9s %-6s %6d' % (k[0], 'YES' if k[1] else 'no', k[2], tab[k]))
    for vid in ('v71', 'v76', 'v93'):
        s = sum(v for k, v in tab.items() if k[0] == vid and k[1])
        i = sum(v for k, v in tab.items() if k[0] == vid and k[1] and k[2] == '0')
        if s:
            print('  %-5s %s: %d of %d straddling cells inverted (%.0f %%)'
                  % (vid, 'ASCII ' if vid in ASCII_VECS else 'random', i, s, 100.0 * i / s))

    # ---- and the byte verdicts, so the polarity claim is not the only evidence -----------------
    print('\n== BYTE VERDICTS, straddling against not ==')
    v = collections.Counter()
    for r in rows:
        if '_lo' not in r:
            continue
        mlo, mhi = fnum(r['_lo']), fnum(r['_hi'])
        if None in (mlo, mhi):
            continue
        v[(mlo < -FF and mhi > FF, verdict(r))] += 1
    for k in sorted(v, key=str):
        print('  straddle=%-4s %-6s %6d' % ('YES' if k[0] else 'no', k[1], v[k]))


if __name__ == '__main__':
    main()

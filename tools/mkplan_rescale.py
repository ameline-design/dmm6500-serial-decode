#!/usr/bin/env python3
"""Two hours' worth of questions in one lap: what makes ua_best rescale, and why the drift vectors refuse.

BLOCK 1 -- THE RESCALE MAP. ua_best may replace sig_bittime's correct fit with a rescaled candidate from
sdec.ratios. Measured on hardware: v63, v90 and v94 all reported 250000 for a commanded 125000 with
fitratio EXACTLY 0.5000 and snapfirm true -- the width fit was right and the rescale halved the bit time.
uart_decode.tsp:1149 says when that is allowed:

    if st.mayrescale and ratio ~= 1 and q >= st.qmin and ua_plausible(T)
       and not (st.snap1 and (ua_submultiple(T) or ua_minrun_absurd(T)))

`st.snap1` is whether the UNRESCALED fit snapped to a standard rate, and the comment is explicit: "ONLY
DEFEND A FIT THAT LANDED ON A STANDARD RATE ... when the fit does not snap it is not a good fit". So a
correct fit at a NON-STANDARD rate is undefended, and a halved candidate that does snap can take it.

125000 is 2.344 % below 128000 -- outside sdec.snaptol -- so it does not snap and is undefended, while its
half-bit-time candidate lands on 250000, which is standard. That is the whole mechanism, and it predicts:

    VULNERABLE   non-standard commanded rate, and a rescaled candidate that snaps   -> expect fitratio 0.5
    CONTROL      non-standard commanded rate, no rescaled candidate that snaps      -> expect fitratio 1
    DEFENDED     standard commanded rate: snap1 is true, so the guard fires          -> expect fitratio 1

312 is in the CONTROL set by the naive form of the rule -- 2 x 312 = 624 is not standard -- and it doubles
anyway, because the halved fit lands at 606 and 606 snaps to 600. It is kept in the plan as exactly that:
the case that refutes the tidy version of the rule. A control that is known to fire is worth more than one
assumed clean.

BLOCK 2 -- WHY THE DRIFT VECTORS REFUSE. v48a and v48b fail 83-100 % of their cells with 'no clear logic
levels (N % of samples near threshold)', and that survived a power cycle unchanged (196 of 2746 before,
20 of 291 after -- 7.1 % against 6.9 %) while the whole 'line is idle' family went to zero. So it is a
property of the decoder and the stimulus, not of instrument state. It also fails at 300 Bd, where the
capture is 2 s, so it is not a short-window effect. This block sweeps AMPLITUDE at one rate to find where
the refusal starts: if it tracks amplitude, the refusal is sig_levels correctly declining a signal whose
samples really do sit near the threshold, and the ~7 % is honest. If it refuses at every amplitude, the
threshold logic is worth looking at.

    python3 tools/mkplan_rescale.py --laps 3 --repeats 2 > out/bench/resc1/PLAN.csv
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as _I                                                  # noqa: E402
import soakplan as SP                                                     # noqa: E402
from vector_names import MAP as VMAP                                      # noqa: E402

SNAPTOL = 0.02
# THREE PAYLOAD CLASSES, because all three of the observed doubling cells were different vectors and the
# mechanism should not care: v90 repeating blocks, v94 longer blocks, v63 LIN framing.
RESCALE_VECS = ['v90', 'v94', 'v63']
DRIFT_VECS = ['v48a', 'v48b']
DRIFT_BAUD = 9600          # a standard rate, so nothing in block 2 is confounded by the rescale question
DRIFT_STEPS = 8            # amplitude steps, swept through soakplan's own unit draw so each stays legal


def snaps(b, std):
    return any(abs(b / float(s) - 1) <= SNAPTOL for s in std)


def rate_classes():
    """-> [(baud, kind)] : vulnerable, control and defended rates, derived rather than typed."""
    std = sorted(SP.standard_rates())
    edges = sorted(SP.ladder_edges(SP.rate_ladder()))
    cand = sorted(set(edges) | {s // 2 for s in std} | {312, 625, 15625, 64000, 96000, 125000})
    out = []
    for b in cand:
        if b < 100 or b > SP.BAUD_HI:
            continue
        srate = b * 10
        if srate > _I.SDG_MAX_SRATE:
            continue
        if snaps(b, std):
            continue                        # a standard-ish rate goes in the DEFENDED set below
        out.append((b, 'vuln' if snaps(b * 2, std) else 'ctl'))
    # DEFENDED: genuine standard rates, where snap1 is true and the submultiple guard fires. Four spread
    # across the range rather than all of them -- the point is that the guard works, not to re-sweep it.
    for b in (9600, 38400, 115200, 250000):
        if b in std:
            out.append((b, 'std'))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--laps', type=int, default=3)
    ap.add_argument('--repeats', type=int, default=2)
    a = ap.parse_args()

    rates = rate_classes()
    manifest = SP._manifest_rows()
    rows = []
    nb1 = nb2 = 0
    for it in range(1, a.laps + 1):
        n = 0
        # ---- block 1: the rescale map -----------------------------------------------------------
        for vi, vid in enumerate(RESCALE_VECS):
            spb = int((manifest.get(vid) or {}).get('spb') or 10)
            for ri, (baud, kind) in enumerate(rates):
                srate = int(round(baud * spb))
                if srate > _I.SDG_MAX_SRATE:
                    continue
                ua, uo = SP.amp_ofst_u(it, vi, ri)
                amp, ofst = SP.amp_ofst_for(vid, ua, uo)[0:2]
                SP.assert_unclipped(vid, amp, ofst)
                for rep in range(a.repeats):
                    n += 1
                    nb1 += 1
                    rows.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                                % (it, n, vid, VMAP[vid], baud, kind, amp, ofst, srate,
                                   1000.0 * SP.wait_s(it, vi, ri, baud, rep)))
        # ---- block 2: the drift amplitude ladder ------------------------------------------------
        for vj, vid in enumerate(DRIFT_VECS):
            spb = int((manifest.get(vid) or {}).get('spb') or 10)
            srate = int(round(DRIFT_BAUD * spb))
            if srate > _I.SDG_MAX_SRATE:
                continue
            for k in range(DRIFT_STEPS):
                # SWEPT THROUGH soakplan's OWN UNIT DRAW, not by picking volts: amp_ofst_for maps the unit
                # interval onto the legal region for THIS vector, so every step is inside the rails and
                # inside |OFST| + AMP/2 <= 10 V without this file re-deriving either.
                ua = (k + 0.5) / float(DRIFT_STEPS)
                amp, ofst = SP.amp_ofst_for(vid, ua, 0.5)[0:2]
                SP.assert_unclipped(vid, amp, ofst)
                for rep in range(a.repeats):
                    n += 1
                    nb2 += 1
                    rows.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                                % (it, n, vid, VMAP[vid], DRIFT_BAUD, 'drift', amp, ofst, srate,
                                   1000.0 * SP.wait_s(it, 90 + vj, k, DRIFT_BAUD, rep)))

    per = collections.Counter(ln.split(',', 1)[0] for ln in rows)
    out = ['# generated by tools/mkplan_rescale.py -- the ua_best rescale map and the drift refusal',
           '# rows=%d' % len(rows),
           '# random-per-lap=all',
           '# repeats=%d' % a.repeats]
    if per and len(set(per.values())) == 1:
        out.append('# cells-per-lap=%d' % next(iter(per.values())))
    nv = len([1 for b, k in rates if k == 'vuln'])
    nc = len([1 for b, k in rates if k == 'ctl'])
    ns = len([1 for b, k in rates if k == 'std'])
    out.append('# rescale-map: %d vulnerable, %d control, %d standard rate(s) x %d vector(s)'
               % (nv, nc, ns, len(RESCALE_VECS)))
    out.append('# drift-ladder: %d amplitude step(s) x %d vector(s) at %d Bd'
               % (DRIFT_STEPS, len(DRIFT_VECS), DRIFT_BAUD))
    out.append('iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms')
    sys.stdout.write('\n'.join(out + rows) + '\n')

    sys.stderr.write('block 1 %d cell(s), block 2 %d cell(s); %d a lap, %d lap(s), %d row(s)\n'
                     % (nb1, nb2, len(rows) // max(a.laps, 1), a.laps, len(rows)))
    sys.stderr.write('\n%8s %-6s %10s  %s\n' % ('baud', 'class', '2x', 'prediction'))
    std = sorted(SP.standard_rates())
    for b, k in rates:
        pred = {'vuln': 'EXPECT fitratio 0.5 (undefended, 2x snaps)',
                'ctl': 'expect fitratio 1 (nothing to snap to)',
                'std': 'expect fitratio 1 (snap1 defends the fit)'}[k]
        sys.stderr.write('%8d %-6s %10d  %s\n' % (b, k, b * 2, pred))
    sys.stderr.write('\n312 is in ctl and IS KNOWN TO DOUBLE (its halved fit lands at 606, which snaps to\n'
                     '600) -- it is the case that refutes the tidy form of the rule.\n')


if __name__ == '__main__':
    main()

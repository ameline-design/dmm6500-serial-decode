#!/usr/bin/env python3
"""Drive the snap/judge asymmetry band on purpose, instead of waiting for the interstitial draw to find it.

THE BAND. sdec.sig_snap tests |raw/std - 1| <= sdec.snaptol; judge_bench.ratebad tests
|read_baud/commanded - 1| > 0.02. Same 2 %, OPPOSITE DENOMINATORS, so there is a window where the snap
fires and the judge then fails the cell:

    snap accepts   commanded >= 0.98 * std
    judge fails    commanded <  std / 1.02  =  0.980392 * std
    => the band is  [0.98, 1.0/1.02)  --  0.0392 % of std wide

Every rate in it is also above sdec.snaptol_firm = 0.0125, so snapfirm is FALSE by construction: the app
prints the rate with a literal '?' and AUTOLOCKS FROM sdec.baud_raw instead (serial_app.tsp:1716,
uart_decode.tsp:1864). So the app does not stand behind the number the judge fails it on.

WHY DRIVE IT DELIBERATELY. soakplan's interstitial draw is log-uniform inside each standard-rate gap, so
the chance of landing in a 0.0392 %-wide band is about 0.4 % per gap per lap -- the 100-lap archive caught
it 58 times out of 620 misfits, entirely by accident (125453 and 125485 below 128000, 245068 below 250000,
30628 below 31250). Choosing baud = ceil(0.98 * std) puts EVERY cell in the band, which turns a 0.4 %
sampling problem into a 100 % test and settles in one lap what the archive could only hint at.

THE PREDICTION, fixed before the run:

    read_baud  == std exactly          (the snap fires)
    snapfirm   == false                (0.98 is outside snaptol_firm 0.0125)
    raw/cmd    ~= 1.000                (the WIDTH FIT IS RIGHT -- nothing is wrong with the decode)
    fitratio   == 1.0                  (no rescale involved, unlike the exact-double family)

If that holds, these cells are a JUDGE defect and not a decoder defect, and judging them against
baud_raw -- which is what the app locks to -- is worth up to 0.4 pp of the headline failure rate.

THE CONTROL IS THE OTHER SIDE OF THE EDGE. baud = floor(0.9795 * std) is just BELOW the band: the snap
should NOT fire, read_baud should come back as the measured rate, and the judge should pass it. A run
where both sides fail has found something else.

    python3 tools/mkplan_band.py --laps 8 > out/bench/band1/PLAN.csv
"""
import argparse
import collections
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as _I                                                  # noqa: E402
import soakplan as SP                                                     # noqa: E402
from vector_names import MAP as VMAP                                      # noqa: E402

# THE VECTORS. Chosen for a clean width fit rather than for being hotspots: the band is a snap/judge
# question and a vector whose FIT is biased would confound it. j10 is deliberately included as the
# counter-case -- its fit runs +0.71 % high at every rate, so it should fail the band cells for a second,
# independent reason and its raw/cmd should NOT come back at 1.000.
VECS = ['v90', 'v94', 'v63', 'j10']


def band_interior(s):
    """The integer nearest the MIDDLE of the band for standard rate `s`, or None. -> int or None

    STRICTLY INSIDE, NOT ON THE EDGE. ceil(0.98*s) lands EXACTLY on 0.98*s whenever that is an integer --
    294 for 300, 588 for 600, 1176 for 1200 -- and sig_snap's test is `bestd <= sdec.snaptol` with
    snaptol = 0.02, so such a cell sits precisely on the comparison boundary. One ULP either way decides
    whether the snap fires at all, which makes the cell a test of floating-point rounding rather than of
    the band. The midpoint is chosen instead, and a rate is only emitted if it clears both edges by a
    margin.

    THE BAND IS 0.0392 % OF s WIDE, so it contains no integer at all below s ~ 2550: at 300 Bd the whole
    band is [294, 294.118) and the only integer in it is the boundary itself. Those rates are therefore
    SKIPPED rather than fudged -- the effect is real only where the band is wide enough to hold a rate,
    which is also where the archive found it (125453 and 125485 under 128000, 245068 under 250000).
    """
    lo, hi = 0.98 * s, s / 1.02
    mid = int(round((lo + hi) / 2.0))
    # A MARGIN OF ONE PART IN 10^6 EACH SIDE, so the cell cannot be decided by rounding.
    if mid / float(s) > 0.98 * (1 + 1e-6) and float(s) / mid > 1.02 * (1 + 1e-6):
        return mid
    return None


def band_rates():
    """-> [(baud, why)] : one rate strictly inside the asymmetry band per standard rate, plus a control."""
    out = []
    for s in sorted(SP.standard_rates()):
        mid = band_interior(s)
        if mid is not None and mid >= 100:
            out.append((mid, 'band'))
            # CONTROL: clearly BELOW the band, so the snap must not fire and the judge must pass. Paired
            # with the band rate rather than emitted for every standard rate, so the two columns of the
            # result table describe the same set of standard rates.
            ctl = int(math.floor(0.975 * s))
            if ctl >= 100 and ctl != mid:
                out.append((ctl, 'ctl'))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--laps', type=int, default=8)
    ap.add_argument('--repeats', type=int, default=1)
    a = ap.parse_args()

    rates = band_rates()
    manifest = SP._manifest_rows()
    rows = []
    for it in range(1, a.laps + 1):
        n = 0
        for vi, vid in enumerate(VECS):
            row = manifest.get(vid) or {}
            spb = int(row.get('spb') or 10)
            for ri, (baud, why) in enumerate(rates):
                srate = int(round(baud * spb))
                if srate > _I.SDG_MAX_SRATE:
                    continue
                ua, uo = SP.amp_ofst_u(it, vi, ri)
                amp, ofst = SP.amp_ofst_for(vid, ua, uo)[0:2]
                SP.assert_unclipped(vid, amp, ofst)
                for rep in range(a.repeats):
                    n += 1
                    rows.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                                % (it, n, vid, VMAP[vid], baud, why, amp, ofst, srate,
                                   1000.0 * SP.wait_s(it, vi, ri, baud, rep)))
    per = collections.Counter(ln.split(',', 1)[0] for ln in rows)
    out = ['# generated by tools/mkplan_band.py -- the snap/judge asymmetry band, driven deliberately',
           '# rows=%d' % len(rows),
           '# random-per-lap=all',
           '# repeats=%d' % a.repeats]
    if per and len(set(per.values())) == 1:
        out.append('# cells-per-lap=%d' % next(iter(per.values())))
    nb = len([1 for b, w in rates if w == 'band'])
    out.append('# band=%d control=%d vectors=%s' % (nb, len(rates) - nb, ','.join(VECS)))
    out.append('iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms')
    sys.stdout.write('\n'.join(out + rows) + '\n')
    sys.stderr.write('%d band rate(s) + %d control(s) x %d vector(s) x %d repeat(s) = %d cell(s) a lap, '
                     '%d lap(s), %d row(s)\n'
                     % (nb, len(rates) - nb, len(VECS), a.repeats,
                        len(rows) // max(a.laps, 1), a.laps, len(rows)))
    # THE BAND ARITHMETIC, PRINTED, so the plan can be checked by eye against the prediction rather than
    # trusted. A rate that is not actually inside [0.98, 1/1.02) would silently test nothing.
    sys.stderr.write('\n%8s %8s %10s %11s %11s  %s\n'
                     % ('std', 'baud', 'baud/std', 'snap sees', 'judge sees', 'verdict'))
    nskip = 0
    for s in sorted(SP.standard_rates()):
        mid = band_interior(s)
        if mid is None:
            nskip += 1
            continue
        snap = 100 * abs(mid / float(s) - 1)
        judge = 100 * abs(s / float(mid) - 1)
        sys.stderr.write('%8d %8d %10.6f %10.4f%% %10.4f%%  %s\n'
                         % (s, mid, mid / float(s), snap, judge,
                            'snaps AND judge fails' if snap < 2.0 < judge else 'NOT IN THE BAND'))
    sys.stderr.write('%d standard rate(s) skipped: the band is narrower than 1 Bd below ~2550\n' % nskip)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build the A/B/C plan for the ground-straddle experiment. -> a plan CSV bench_run.tsp can stream.

WHAT THIS LAP IS FOR. The 100-lap soak's byte failures concentrate 9.55x on cells whose commanded
amplitude/offset pair the SDG2122X cannot produce -- |OFST| + AMP/2 <= 10 V into Hi-Z, which
soakplan.amp_ofst_for does not enforce because it constrains the DATA band against V_RAIL instead. The
generator clamps, the band recentres on ground, and sig_idle's level branch reads a ground-straddling
line as RS-232 marking at its negative level -- correctly, per its own comment. Rate failures show NO
enrichment at all (0.97x, chi-square 0.14), which is the control that rules out "big signals are just
harder".

Every step of that is inference from commanded values, because bsdg.select writes BSWV without reading
it back and nothing records what reached the wire. This plan measures it instead, with sdec.lo/sdec.hi
now in the diagnostic note.

THE EXPERIMENT IS THE AMPLITUDE SWEEP, and its virtue is that the prediction is NON-MONOTONIC -- no
decoder defect can produce a defect window with a clean side above it. Every cell is commanded AT the
envelope limit, ofst = -(10 - amp/2), so nothing clamps and the band is exactly what was asked for:

    lo = ofst                          hi = ofst + frac * amp/2,  frac = cw_span/32767

The band straddles ground -- lo < -flatfloor and hi > +flatfloor -- iff

    amp < 2 * (10 - flatfloor)                    = 18.000 Vpp    (else lo is not below -1 V)
    amp > 2 * (10 + flatfloor) / (1 + frac)       = 13.253 Vpp    (else hi is not above +1 V)

for frac = 0.660, which v71, v76 and v93 all share. So: clean, then inverted, then clean again, with
both edges bracketed to 0.2 Vpp.

AND THE ALPHABET IS THE CONTROL. A straddling band only sets the PRIOR: uart_decode.tsp:1747 lets
ua_autoformat's contest override it, and ASCII is what stops the contest working -- a constant top data
bit puts a rising edge exactly nine bit times after every start bit, a periodic fake start edge, so the
inverted reading frames as cleanly as the correct one and survives the 60 % margin. v71 and v76 are
Lorem (ASCII); v93 is random bytes over the same 102 600 points with the same codeword span. Predict
v71/v76 invert inside the window and v93 does not, on an identical wire.

The three parts, per vector:

  SWEEP    ofst at the envelope limit, amp swept across both edges. The experiment.
  ZERO     the same amplitudes at ofst 0 -- same amp, same span, band 0..hi, no straddle. Predict clean,
           which separates the straddle from the amplitude.
  PAIR     the cells the 258-cell diagnostic actually inverted, twice: A as the soak commanded it
           (outside the envelope) and B with the offset pre-clamped by this host. If the generator
           clamps the offset, A and B put the SAME band on the wire and lo/hi will say so.

    python3 tools/mkplan_abc.py > out/bench/abc1/PLAN.csv
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import judge_bench as JB                                                # noqa: E402
import soakplan as SP                                                   # noqa: E402
from vector_names import MAP                                            # noqa: E402

CEIL = 10.0                      # |OFST| + AMP/2, Hi-Z, SDG2122X
FF = SP.FLATFLOOR                # 1.0 V
WAIT_MS = 100.0
DIAG = 'out/bench/diag1/SOAK.csv'

# TWO BAUDS A VECTOR, both recorded weak=y in the diagnostic, and one of them fast enough to put plenty
# of bytes in the window so the byte verdict is judgeable as well as the polarity.
BAUDS = {'v71': ((1875, 'edge'), (19200, 'std')),
         'v76': ((1800, 'std'), (19200, 'std')),
         'v93': ((1200, 'std'), (19200, 'std'))}

# BOTH EDGES BRACKETED TO 0.2 Vpp, and deliberately NOT sitting on either: 13.253 and 18.000 are where
# the strict inequalities flip, and a cell commanded exactly there would turn a float comparison into the
# experiment. 13.2/13.4 and 17.9/18.1 straddle them instead.
SWEEP_AMPS = (8.0, 10.0, 12.0, 13.0, 13.2, 13.4, 14.0, 15.0,
              16.0, 17.0, 17.6, 17.9, 18.1, 18.5, 19.0, 20.0)
ZERO_AMPS = (10.0, 14.0, 17.0, 20.0)


def frac(vid):
    """The data band's span as a fraction of amp/2. -> float"""
    lo, hi = SP._cw_span(vid)
    return (hi - lo) / 32767.0


def band(vid, amp, ofst):
    lo, hi = SP._cw_span(vid)
    return ofst + lo / 32767.0 * (amp / 2.0), ofst + hi / 32767.0 * (amp / 2.0)


def straddles(vid, amp, ofst):
    lo, hi = band(vid, amp, ofst)
    return lo < -FF and hi > FF


def preclamp(amp, ofst):
    """What the generator can actually do with a pair. -> (amp, ofst)"""
    a = min(amp, 2 * CEIL)
    lim = CEIL - a / 2.0
    return a, max(-lim, min(lim, ofst))


def diag_cells():
    """The diagnostic's own inverted cells and its straddling-but-recovered ones. -> list of dicts

    READ FROM THE RECORD rather than retyped, because the whole point of the A rows is that they are the
    pairs the soak commanded -- a transcription would make them a different experiment.
    """
    if not os.path.exists(DIAG):
        return []
    lines = open(DIAG, errors='replace').read().splitlines()
    body = JB.split_runs(lines)[-1][1]
    R, S = {}, {}
    for ln in body:
        f = ln.split(',')
        if ln.startswith('R,') and len(f) - 1 >= len(JB.RCOLS):
            d = dict(zip(JB.RCOLS, f[1:1 + len(JB.RCOLS)]))
            R[(d['iter'], d['cell'])] = d
        elif ln.startswith('S,') and len(f) > 8:
            S.setdefault((f[2], f[3]), ln)
    pat = re.compile(r'idle=(\S+) weak=(\S+)')
    out = []
    for k, d in R.items():
        s = S.get(k)
        m = pat.search(s) if s else None
        if not m:
            continue
        idle, weak = m.groups()
        try:
            amp, ofst = float(d['amp_vpp']), float(d['ofst_v'])
        except ValueError:
            continue
        ca, co = preclamp(amp, ofst)
        if not straddles(d['vid'], ca, co) or weak != 'y':
            continue
        out.append({'vid': d['vid'], 'baud': int(round(float(d['baud']))), 'kind': d['kind'],
                    'amp': amp, 'ofst': ofst, 'was': idle, 'src': 'L%sC%s' % k})
    out.sort(key=lambda r: (r['vid'], r['baud']))
    return out


def main():
    rows, notes = [], []
    n = 0
    # GROUPED BY VECTOR. bsdg.select writes ARWV for every cell and verifies the reply, and a real switch
    # is the expensive part of a cell -- so the vector changes twice in the lap rather than every row.
    for vid in ('v71', 'v76', 'v93'):
        spb = int((SP._manifest_rows().get(vid) or {}).get('spb') or 10)
        f = frac(vid)
        lo_edge = 2.0 * (CEIL + FF) / (1.0 + f)
        hi_edge = 2.0 * (CEIL - FF)
        notes.append('# %s frac %.4f -- predict inverted for %.3f < amp < %.3f Vpp'
                     % (vid, f, lo_edge, hi_edge))
        for baud, kind in BAUDS[vid]:
            for amp in SWEEP_AMPS:
                ofst = round(-(CEIL - amp / 2.0), 4)
                n += 1
                rows.append((n, vid, baud, kind, amp, ofst))
            for amp in ZERO_AMPS:
                n += 1
                rows.append((n, vid, baud, kind, amp, 0.0))
        for c in diag_cells():
            if c['vid'] != vid:
                continue
            n += 1
            rows.append((n, vid, c['baud'], c['kind'], c['amp'], c['ofst']))       # A, as commanded
            ca, co = preclamp(c['amp'], c['ofst'])
            n += 1
            rows.append((n, vid, c['baud'], c['kind'], round(ca, 4), round(co, 4)))  # B, pre-clamped

    # REFUSED HERE RATHER THAN DISCOVERED ON THE INSTRUMENT. bsdg.select checks amp and srate and returns
    # a stimulus failure; the DMM's fixed 10 V range is checked by nothing at all, so a band outside it
    # would be recorded as a decode of a signal that was flat-topped by the meter. The envelope is NOT
    # checked, because commanding pairs outside it is the experiment.
    import instruments as _I
    for n, vid, baud, kind, amp, ofst in rows:
        spb = int((SP._manifest_rows().get(vid) or {}).get('spb') or 10)
        srate = baud * spb
        blo, bhi = band(vid, *preclamp(amp, ofst))
        clo, chi = band(vid, amp, ofst)
        if amp <= 0 or amp > _I.SDG_MAX_VPP + 1e-9:
            raise SystemExit('cell %d: %.4f Vpp is outside 0..%.1f' % (n, amp, _I.SDG_MAX_VPP))
        if srate > _I.SDG_MAX_SRATE:
            raise SystemExit('cell %d: %g Sa/s is past SDG_MAX_SRATE' % (n, srate))
        for lo_v, hi_v, what in ((blo, bhi, 'clamped'), (clo, chi, 'commanded')):
            if lo_v < -10.0 - 1e-9 or hi_v > 10.0 + 1e-9:
                raise SystemExit('cell %d: %s band %.3f..%.3f V leaves the DMM 10 V range'
                                 % (n, what, lo_v, hi_v))

    out = ['# generated by tools/mkplan_abc.py; the ground-straddle experiment, one row per cell',
           '# rows=@@ROWS@@',
           '# random-per-lap=all']
    out += notes
    out.append('iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms')
    for n, vid, baud, kind, amp, ofst in rows:
        spb = int((SP._manifest_rows().get(vid) or {}).get('spb') or 10)
        out.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                   % (1, n, vid, MAP[vid], baud, kind, amp, ofst, int(round(baud * spb)), WAIT_MS))
    ndata = len(rows)
    out = [ln.replace('@@ROWS@@', str(ndata)) for ln in out]
    sys.stdout.write('\n'.join(out) + '\n')
    sys.stderr.write('%d cell(s)\n' % ndata)
    # THE PREDICTION TABLE ON STDERR, so the plan file stays a plan and the expectations are still
    # recorded before the lap runs rather than fitted after it.
    ns = sum(1 for _, vid, _, _, a, o in rows if straddles(vid, a, o))
    sys.stderr.write('%d predicted straddling, %d not\n' % (ns, ndata - ns))
    for vid in ('v71', 'v76', 'v93'):
        k = [(a, o) for _, v, _, _, a, o in rows if v == vid and straddles(v, a, o)]
        sys.stderr.write('  %-4s %3d straddling of %3d\n'
                         % (vid, len(k), sum(1 for _, v, _, _, _, _ in rows if v == vid)))


if __name__ == '__main__':
    main()

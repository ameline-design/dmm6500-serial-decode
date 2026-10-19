#!/usr/bin/env python3
"""Pin bench_seamhole's arithmetic against a synthesised handover with a KNOWN hole.

WHY A SYNTHETIC FIXTURE AND NOT THE INSTRUMENT. The risk in that tool is not the instrument: it is
the sign of each phase and the one-sample continuity convention. Those cannot be checked against
hardware, because hardware has no known answer -- the whole point of the measurement is that the
hole's value is unknown. So the two buffers are built here from one sample grid with the handover
placed by construction, and the tool's own parser and analysis have to recover the number that was
put in.

Every case is run BOTH WAYS -- a hole and an overlap of the same width -- because the failure this
guards against is a sign error, and a sign error reads as a plausible number on a one-sided test.

    python3 tools/test_seamhole.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_seamhole as SH          # noqa: E402

FAIL = [0]


def ck(cond, name, detail=''):
    print('%-5s %s%s' % ('ok' if cond else 'FAIL', name, ('   ' + detail) if detail else ''))
    if not cond:
        FAIL[0] += 1


EDGE_US = 100.0          # bench_seamhole's default pulse edge, in the fixture's units


def wave(t_us, edge_us=EDGE_US, half_us=SH.HALF_US, lo=0.0, hi=3.0):
    """The stimulus at absolute time t_us: a pulse with symmetric edges of edge_us.

    edge_us = 0 is the ideal square, kept because it is the pathological case for interpolation and
    the tool offers it as a cross-check. Anything else is a trapezoid whose midpoint crossings still
    sit every half_us, which is the property the whole measurement rests on.
    """
    n = int(t_us // half_us)
    frac = t_us - n * half_us
    rising = (n % 2) == 0            # level after this boundary is hi on even n
    if edge_us <= 0:
        return hi if rising else lo
    # The edge is centred on the boundary, so the midpoint crossing stays at the boundary itself.
    if frac < 0.5 * edge_us:
        x = 0.5 + frac / edge_us
    elif frac > half_us - 0.5 * edge_us:
        x = (frac - (half_us - 0.5 * edge_us)) / edge_us
        x = 0.0 + x
        return (lo + (hi - lo) * (1.0 - x)) if rising else (lo + (hi - lo) * x)
    else:
        return hi if rising else lo
    return (lo + (hi - lo) * x) if rising else (lo + (hi - lo) * (1.0 - x))


def build(dt_us, hole_samples, nscr=300, nrec=300, phase_us=0.0, dtg_us=None,
          edge_us=EDGE_US):
    """Tagged lines as the instrument would print them, for one handover.

    Sample k is taken at k * dt. The scratch holds 0..S and the record holds R..R+nrec-1, with
    R = S + 1 + hole_samples -- so hole_samples is positive for a hole, negative for an overlap,
    and 0 is a continuous handover. That assignment IS the definition under test.
    """
    if dtg_us is None:
        dtg_us = dt_us
    S = nscr - 1
    R = S + 1 + hole_samples
    out = []
    # The scratch's absolute times run on its own interval, so a rate difference between the two
    # blocks can be fixtured; the record's start instant stays keyed to the record's grid.
    chunks = []
    for i in range(nscr):
        chunks.append(wave(i * dtg_us + phase_us, edge_us=edge_us))
    out.append('SH gn=%d gcap=2000 gstart=1' % nscr)
    for i in range(0, nscr, SH.CHUNK):
        body = ' '.join('%.5f' % v for v in chunks[i:i + SH.CHUNK])
        out.append('SH gd %d %s' % (i, body))
    # The record opens at R on the shared time axis: its first sample's time is S*dtg + (1+hole)*dt.
    t0 = S * dtg_us + (1 + hole_samples) * dt_us
    rec = []
    for i in range(nrec):
        rec.append(wave(t0 + i * dt_us + phase_us, edge_us=edge_us))
    out.append('SH rn=%d rcap=22000 rstart=1' % nrec)
    for i in range(0, nrec, SH.CHUNK):
        body = ' '.join('%.5f' % v for v in rec[i:i + SH.CHUNK])
        out.append('SH rd %d %s' % (i, body))
    out.append('SH lv vmin=0.0 vmax=3.0 thr=1.5 idle=1')
    out.append('SH ran=true why=nil')
    return out


def recover(lines):
    """THE TOOL'S OWN analyse(), not a copy of it.

    A second implementation here would be the tautology this suite's rules name: it would pass while
    the tool was wrong, because both would be wrong the same way. So the fixture is the only thing
    this file owns.
    """
    return SH.analyse(lines, 9600)


def hole(lines):
    return recover(lines)[0]


def lua502_parse():
    """The embedded TSP script, through the real 5.0.2 parser.

    THE DEFECT THIS EXISTS FOR, because it cost 24 instrument trials: a dropped `end` makes the whole
    script a parse error, the instrument then prints NOTHING, and every tagged read comes back None
    -- which reads exactly like a capture that refused. The script is a Python template, so it is not
    a file any linter sees; rendering and parsing it here is the only place that can catch it, and it
    needs no instrument. Skipped with a stated reason where the 5.0.2 parser has not been built,
    rather than passing silently: the firmware's Lua rejects hex literals the host's accepts.
    """
    luac = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        'out', 'lua502', 'bin', 'luac')
    if not os.path.exists(luac):
        print('skip  the 5.0.2 parser is not built (out/lua502/bin/luac) -- run tools/get_lua502.sh')
        return
    body = SH.TRIAL % {'fs': '100000', 'pinfs': 'true', 'baud': 9600, 'win': 0.01,
                       'vec': 'v98a', 'ndump': SH.NDUMP, 'chunk': SH.CHUNK}
    import subprocess
    import tempfile
    fd, path = tempfile.mkstemp(suffix='.lua')
    try:
        os.write(fd, body.encode())
        os.close(fd)
        p = subprocess.run([luac, '-p', path], capture_output=True, text=True)
        ck(p.returncode == 0, 'the embedded TSP script parses under Lua 5.0.2',
           (p.stderr or p.stdout).strip()[:160])
    finally:
        os.unlink(path)


def main():
    print('-- THE SCRIPT THE INSTRUMENT IS SENT --')
    lua502_parse()

    print('')
    print('-- THE PARSER --')
    lines = build(10.0, 0)
    gv, rv = SH.samples(lines, 'g'), SH.samples(lines, 'r')
    ck(len(gv) == 300 and len(rv) == 300, 'both buffers come back whole',
       '%d / %d readings' % (len(gv), len(rv)))
    # A DROPPED CHUNK MUST READ AS A HOLE IN THE ARRAY, not as a shift: keying on arrival order
    # would silently slide every reading after the loss and move the crossing it is measuring.
    short = [ln for ln in lines if not ln.startswith('SH gd 100 ')]
    gs = SH.samples(short, 'g')
    ck(len(gs) == 300 and gs[100] is None and gs[150] is not None,
       'a lost chunk leaves a gap at its own offset and does not shift the rest',
       'len=%d, [100]=%s, [150]=%s' % (len(gs), gs[100], gs[150]))

    print('')
    print('-- THE CROSSING GRID --')
    _, det = recover(build(10.0, 0))
    ck(abs(det['dtr'] - 10.0) < 0.05 and abs(det.get('dtg', 10.0) - 10.0) < 0.05,
       'the sample interval comes back from the crossings alone, fs never consulted',
       'record %.4f us, scratch %.4f us' % (det['dtr'], det.get('dtg', float('nan'))))
    # A HALF-SAMPLE PHASE, so the interpolator is doing something: with the crossings on sample
    # boundaries a nearest-sample reader would score the same as an interpolating one.
    ck(abs(hole(build(10.0, 0, phase_us=5.0))) < 0.6,
       'a continuous handover reads as no hole at a half-sample grid phase',
       '%+.3f us' % hole(build(10.0, 0, phase_us=5.0)))

    print('')
    print('-- THE HOLE, BOTH WAYS --')
    # Both signs at each width. A sign error gives a plausible number on either test alone: at
    # 10 us a 7-sample hole and a 7-sample overlap are 70 us apart and both inside half a period.
    for n in (1, 3, 7, 9, 20):
        for sign in (1, -1):
            want = sign * n * 10.0
            h = hole(build(10.0, sign * n))
            ck(h is not None and abs(h - want) < 0.6,
               '%s of %d samples reads back as %+.0f us'
               % ('a hole' if sign > 0 else 'an overlap', n, want),
               'got %+.3f us' % h if h is not None else 'got nothing')

    print('')
    print('-- THE SECOND RATE THE PREDICTION NAMES --')
    # 50 kS/s: 25 readings a half period against 50, so the same hole in time is half the readings.
    # The tool must report the TIME, which is what a firmware handover cost would hold constant.
    h100, h50 = hole(build(10.0, 8)), hole(build(20.0, 4))      # 80 us each
    ck(abs(h100 - 80.0) < 0.6 and abs(h50 - 80.0) < 1.2,
       'one hole fixed in TIME reads the same at both rates, which is the prediction under test',
       '100 kS/s %+.2f us, 50 kS/s %+.2f us' % (h100, h50))
    # AND THE RIVAL HYPOTHESIS HAS TO LOOK DIFFERENT, or the measurement cannot choose between
    # them: a hole fixed in SAMPLES doubles in time when the interval does.
    ck(abs(hole(build(20.0, 8)) - 160.0) < 1.2,
       'a hole fixed in SAMPLES doubles instead, so the two hypotheses are separable',
       '%+.2f us' % hole(build(20.0, 8)))

    print('')
    print('-- THE BLOCKS AT DIFFERENT RATES --')
    # THE ONE CASE THE TOOL CANNOT CORRECT, pinned so it is not mistaken for one it can. The scratch
    # is at most one half period long on the instrument, so it cannot carry two crossings to measure
    # its own interval from, and the record's is borrowed. Where the two blocks really did run at
    # different rates that borrow is wrong -- so the tool has to DETECT the mismatch rather than
    # absorb it, and the fixture's job is to prove the figure moves when it is present.
    h, det = recover(build(10.0, 5, dtg_us=12.5))
    ck('dtg' in det and abs(det['dtg'] - 12.5) < 0.1,
       'a scratch long enough to hold two crossings reports its OWN interval, as the check',
       'scratch %.3f us, record %.3f us' % (det.get('dtg', float('nan')), det['dtr']))
    ck(abs(h - 50.0) > 2.0,
       'and the hole is biased when they differ, which is why that check exists and prints',
       '%+.2f us against a true 50.00' % h)

    print('')
    print('-- WHY THE STIMULUS HAS A SLOW EDGE --')
    # THE REASON --wave pulse IS THE DEFAULT, measured rather than asserted, and the first version
    # of this block asserted the WRONG reason. A square's crossing is sub-sample, so interpolating
    # between the two rails that straddle it puts it at their midpoint wherever the truth was. That
    # is a BIAS of half a sample on each phase and the two cancel, since both phases are scaled by
    # one interval -- so the square is not biased, and a check claiming it was passed only because
    # a rate mismatch was doing the work.
    #
    # The real cost appears once the hole is NOT a whole number of sample periods -- which there is
    # no reason for a firmware handover to be. A fractional hole puts the record's grid off the
    # scratch's by part of a sample, so the two crossings sit at different offsets inside the
    # samples that straddle them, their errors stop being correlated, and the cancellation above
    # fails. Moving the grid phase with an integer hole showed ZERO scatter for exactly this
    # reason, and taking that as the test was the first version's mistake.
    for edge, name in ((0.0, 'an ideal square'), (EDGE_US, 'a 100 us edge')):
        err = []
        for frac in (0.0, 0.25, 0.5, 0.75):
            want = (7 + frac) * 10.0
            err.append(hole(build(10.0, 7 + frac, edge_us=edge)) - want)
        worst = max(abs(e) for e in err)
        ck(worst > 2.0 if edge == 0.0 else worst < 0.35,
           '%s is %s on a FRACTIONAL hole, worst error %.2f us'
           % (name, 'out by sample quantisation' if edge == 0.0 else 'accurate', worst),
           'errors %s' % ' '.join('%+.2f' % e for e in err))
    # AND A FRACTIONAL HOLE IS MEASURABLE AT ALL, which is the capability the slow edge buys: the
    # whole point of a time measurement is that the answer need not land on the sample grid.
    ck(abs(hole(build(10.0, 7.35)) - 73.5) < 0.35,
       'a hole of 73.5 us -- not a whole sample -- reads back as itself',
       '%+.3f us' % hole(build(10.0, 7.35)))

    print('')
    print('-- THE INTERPOLATOR BIAS CANCELS --')
    # A front end that reports every crossing late by b shifts the scratch's phase one way and the
    # record's the other, and the sum the hole is built from is unchanged. Fixtured by moving the
    # whole grid, which is what a common bias is.
    base = hole(build(10.0, 7, phase_us=0.0))
    for b in (1.0, 2.5, 4.0, 7.3):
        h = hole(build(10.0, 7, phase_us=b))
        ck(abs(h - base) < 0.6, 'a common crossing bias of %.1f us does not move the hole' % b,
           '%+.3f vs %+.3f us' % (h, base))

    print('')
    print('-- EXPECTED FAIL: the convention is load-bearing --')
    # Drop the one-sample continuity term and every figure moves by exactly one interval. Compared
    # at the SAME k the tool chose, because k is picked from the quantity being changed: hard-coding
    # k = 1 here read a correct continuous handover as -490 us, which looks like a defect and is
    # arithmetic. If this check ever fails, the term has moved and the hole is one sample out.
    for n in (0, 7, -7):
        h, det = recover(build(10.0, n))
        naive = det['k'] * SH.HALF_US - det['t_s'] - det['t_r']          # no '- dtr'
        ck(abs((naive - h) - det['dtr']) < 1e-6,
           'without the one-sample term a %s reads one interval larger'
           % ('hole' if n > 0 else ('overlap' if n < 0 else 'continuous handover')),
           '%+.3f vs %+.3f us, interval %.3f' % (naive, h, det['dtr']))

    print('')
    print('%d check(s) failed' % FAIL[0])
    return 1 if FAIL[0] else 0


if __name__ == '__main__':
    sys.exit(main())

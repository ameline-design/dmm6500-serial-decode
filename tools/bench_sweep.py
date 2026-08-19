#!/usr/bin/env python3
"""Sweep every standard baud rate to 250 kBd by REPLAYING ONE WAVEFORM AT DIFFERENT SPEEDS.

WHY THIS EXISTS RATHER THAN MORE VECTORS. tools/bench_uart.py maps one uploaded .bin to one baud
rate, so a sixteen-rate sweep meant sixteen uploads -- and repeated C1:WVDT uploads are what wedge
the SDG's remote interface, a failure whose only recovery is a power cycle on an instrument with no
smart plug. It costs a human.

The generator's TrueArb SRATE is independent of the waveform DATA, so one waveform played at N
sample rates is N baud rates, exactly:

    baud = SRATE / samples_per_bit

v80 is "Hello, World!" 8N1 rendered at 10 samples per bit, so SRATE = baud x 10 covers 300 Bd
(3 kSa/s) to 250 kBd (2.5 MSa/s), all far inside the 75 MSa/s ceiling. ONE upload per power cycle,
and every rate after that is a single BSWV/SRATE write. The wedge hazard leaves the sweep entirely.

It also removes a confound the per-vector sweep had: sixteen files could differ in ways nobody
intended. Here every rate is bit-for-bit the same payload, so a rate that behaves differently is a
fact about the RATE.

TWO MEASUREMENTS PER RATE:
  auto    the baud rate NOT locked -- does auto-detect find it?
  locked  the rate locked, which is what FRAME mode does -- how many bytes does a window hold,
          and are they right? The arb loops, so the line is continuously busy and a full window
          is reachable at every rate.

THE UPPER END IS EXPECTED TO DEGRADE, and the sweep is how that is quantified rather than argued:
the DMM digitizes at 1 MSa/s maximum, so 8 samples/bit is unreachable above 125 kBd. At 250 kBd the
best possible is 4 samples/bit. Where the decode falls apart is a property of the instrument.

    python3 tools/bench_sweep.py                  # clean, every standard rate
    python3 tools/bench_sweep.py --noise drift    # + CH2 baseline drift summed into CH1
    python3 tools/bench_sweep.py --noise spikes   # + CH2 impulse noise
    python3 tools/bench_sweep.py --upload         # upload the waveform first (once per cycle)
    python3 tools/bench_sweep.py --rates 9600,115200
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG
import bench_uart as BU
import vector_names as VN                                     # noqa: E402

# The standard ladder. 14400/28800/76800 are included because they are genuinely standard even
# though they are less common, and 250000 because it is the documented wall -- the point of a
# sweep is to include the rate that is expected to fail.
RATES = [300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400,
         57600, 76800, 115200, 230400, 250000]

ARB = 'v80'                 # "Hello, World!" 8N1 at 10 samples/bit
SAMPLES_PER_BIT = 10.0
PAYLOAD = 'Hello, World!'

# The DMM cannot exceed this, so above 125 kBd the samples/bit falls below the 8 the decoder is
# designed around. Clamped here rather than left to fail as a parameter error, so the sweep
# reports "4.0 sa/bit" instead of stopping.
DMM_FS_MAX = 1000000


def fs_for(baud):
    fs = baud * 8
    if fs > DMM_FS_MAX:
        fs = DMM_FS_MAX
    if fs < 1000:
        fs = 1000
    return int(fs)


def want_bytes(nf):
    """The expected byte string for a capture of nf bytes off a LOOPING 13-byte payload.

    Not simply PAYLOAD: the arb repeats, so a 240-byte window holds the payload eighteen times
    over and a comparison against one copy would fail on a correct decode.
    """
    if nf <= 0:
        return ''
    # BYTES, not str: analyse() converts the capture to bytes and searches for it inside this,
    # so a str here fails with "find() argument must be str, not bytes". And it must be at least
    # as long as the capture, because cyclic_find refuses a needle longer than its haystack even
    # though the haystack is treated as a loop.
    reps = int(nf / len(PAYLOAD)) + 2
    return (PAYLOAD * reps).encode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rates', help='comma-separated subset of the ladder')
    ap.add_argument('--noise', choices=['none', 'drift', 'spikes'], default='none')
    ap.add_argument('--noise-vpp', type=float, default=0.6)
    ap.add_argument('--upload', action='store_true',
                    help='upload the waveform first. Needed ONCE per generator power cycle; '
                         'repeated uploads are what wedge it.')
    ap.add_argument('--amp', type=float, default=10.0)
    ap.add_argument('--settle', type=float, default=0.35)
    ap.add_argument('--no-output-off', action='store_true')
    a = ap.parse_args()

    rates = RATES
    if a.rates:
        rates = [int(x) for x in a.rates.split(',')]

    print('SDG %s   DMM %s   fw %s' % (I.SDG_IP, I.DMM_IP, I.SDG_FW))
    print('one waveform (%s, %g samples/bit) replayed at %d sample rates'
          % (ARB, SAMPLES_PER_BIT, len(rates)))
    print('noise: %s%s' % (a.noise,
                           '' if a.noise == 'none' else ' %.2f Vpp on CH2 -> CH1' % a.noise_vpp))

    g = SDG()
    d = DMM()
    rows = []
    try:
        print('\n' + g.idn())
        if a.upload:
            cw = BU.codewords(ARB)
            print('uploading %s (%d points, %d bytes) ONCE' % (ARB, len(cw), 2 * len(cw)))
            g.upload_arb(VN.arb(ARB), cw, a.amp, int(rates[0] * SAMPLES_PER_BIT))
        # CH2 into CH1, or explicitly off -- set once, not per rate, so a rate change is only
        # ever an SRATE write.
        if a.noise == 'none':
            g.impair_off(ch=2)
            g.combine(False, ch=1)
        else:
            if a.noise == 'drift':
                g.impair_drift(a.noise_vpp, ch=2)
            else:
                g.impair_spikes(a.noise_vpp, ch=2)
            g.combine_pair(sum_ch=1)

        print('\nloading the decoder onto the DMM...')
        BU.load_modules(d, ['tsp/serial_core.tsp', 'tsp/uart_decode.tsp'])
        d.exec('localnode.showevents = eventlog.SEV_ERROR')

        for baud in rates:
            srate = int(baud * SAMPLES_PER_BIT)
            if srate > I.SDG_MAX_SRATE:
                print('%7d Bd  SKIPPED -- needs %g Sa/s, over the SDG ceiling'
                      % (baud, srate))
                continue
            # SELECT, never re-upload: this is the whole point of the design.
            g.select_arb(VN.arb(ARB), a.amp, srate)
            g.output(True, ch=1)
            time.sleep(a.settle)

            fs = fs_for(baud)
            sabit = float(fs) / baud
            row = {'baud': baud, 'srate': srate, 'fs': fs, 'sabit': sabit}

            for mode, lock in (('auto', False), ('locked', True)):
                # run_point returns (result_dict, hexstring). A failure is signalled by a
                # 'fail' key rather than by a falsy 'ok' -- reading it the other way turned
                # every point into "no result".
                res, got = BU.run_point(d, baud, fs, 'free', lock, timeout=240)
                if res is None or 'fail' in res:
                    row[mode] = {'fail': (res or {}).get('fail', 'no result')}
                    continue
                nf = res.get('nf', 0)
                # analyse returns (position, longest_clean_run, bad, interior_bad).
                pos, run, bad, interior = BU.analyse(got, want_bytes(nf))
                row[mode] = {'nf': nf, 'nbad': res.get('nbad', 0),
                             'baud': res.get('baud', 0), 'dec': res.get('tdec', 0),
                             'acq': res.get('tacq', 0), 'run': run,
                             'interior': interior,
                             # Found somewhere in the looping payload AND nothing broken in
                             # the middle: pos alone would accept a 3-byte run out of 240.
                             'match': (pos >= 0 and run >= nf and nf > 0)}
            rows.append(row)
            print('%7d Bd  srate %9d  fs %7d  %6.2f sa/bit   auto %-28s  locked %s'
                  % (baud, srate, fs, sabit, fmt_cell(row.get('auto')),
                     fmt_cell(row.get('locked'))))

    finally:
        try:
            if not a.no_output_off:
                g.output(False, ch=1)
                g.impair_off(ch=2)
                g.combine(False, ch=1)
        except Exception as e:
            print('cleanup: %s' % e)
        g.close()
        d.close()

    print('\n%-8s %-7s %-8s | %-30s | %s' % ('baud', 'sa/bit', 'srate', 'AUTO-DETECT', 'LOCKED'))
    print('-' * 100)
    for r in rows:
        print('%-8d %-7.2f %-8d | %-30s | %s'
              % (r['baud'], r['sabit'], r['srate'],
                 fmt_cell(r.get('auto')), fmt_cell(r.get('locked'))))

    ok_auto = sum(1 for r in rows if (r.get('auto') or {}).get('baud') == r['baud'])
    ok_lock = sum(1 for r in rows if (r.get('locked') or {}).get('match'))
    print('\nauto-detect found the exact rate at %d of %d' % (ok_auto, len(rows)))
    print('locked capture was byte-exact at %d of %d' % (ok_lock, len(rows)))
    slow = [r for r in rows if (r.get('locked') or {}).get('dec', 0) > 0.5]
    if slow:
        print('locked decode over the 500 ms budget at: %s'
              % ', '.join('%d Bd (%.2f s)' % (r['baud'], r['locked']['dec']) for r in slow))
    return 0


def fmt_cell(c):
    if c is None:
        return '-'
    if 'fail' in c:
        return 'FAIL %s' % str(c['fail'])[:22]
    tag = 'exact' if c.get('match') else ('run %d' % c.get('run', 0))
    return '%6d Bd %3d B %2d bad %s %.2fs' % (c.get('baud', 0), c.get('nf', 0),
                                              c.get('nbad', 0), tag, c.get('dec', 0))


if __name__ == '__main__':
    sys.exit(main())

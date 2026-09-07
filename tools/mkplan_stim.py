#!/usr/bin/env python3
"""The stimulus-loss plan: why does a quarter of a diagnostic lap produce no usable capture?

WHAT THE LAST RUN FOUND. Of 2746 cells, 663 (24.1 %) never produced a decodable capture -- 457 'line is
idle (no transitions)' and 196 'no clear logic levels'. That is EIGHTEEN TIMES the whole decoder defect
rate, it is deterministic on particular (vector, rate) pairs, and nothing in the record can say whether
the generator was driving the wrong thing or nothing at all:

    v71 @  19200   57 of 57 idle          v94 @ 125000   56 of 57 idle
    v93 @  19200   57 of 57 idle          v94 @ 115200   54 of 57 idle
    v48a @ 28800   50 of 57 no levels     v94 @ 250000   53 of 57 idle

Amplitude spans 1.41..20.00 Vpp across those cells, so it is not amplitude, and the same vectors are
CLEAN at other rates -- v71 at 1875 and v90 at 300/1200/4800 are 0 %. So the plan pairs each suspect
rate with control rates ON THE SAME VECTOR. A lap that only drove the failing pairs could not tell a
broken vector from a broken rate.

THE DISCRIMINATOR IS bsdg.snapshot(), recorded by brun.sdgverify on exactly the cells that failed:
ARWV?/BSWV?/SRATE?/OUTP? on the spot, before the next select can move anything. Four round trips charged
only to a cell that had already spent its time.

REPEATS, because the failing pairs are near-deterministic and the marginal ones are not. v94 at 19200 is
20 of 57 and v90 at 57600 is 11 of 58: one look cannot separate "sometimes" from "always", and repeats at
one operating point cost nothing -- bsdg.select sends the generator no messages at all when the waveform,
amplitude, offset and rate are unchanged, so the 2nd..Nth look is a capture and a decode only.

    python3 tools/mkplan_stim.py --laps 40 --repeats 3 > out/bench/stim1/PLAN.csv
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as _I                                                  # noqa: E402
import soakplan as SP                                                     # noqa: E402
from vector_names import MAP as VMAP                                      # noqa: E402

# THE SUSPECTS: every (vector, rate) pair that lost more than a third of its cells to no-stimulus.
SUSPECT = [
    ('v71', 19200), ('v93', 19200),
    ('v94', 125000), ('v94', 115200), ('v94', 250000), ('v94', 57600), ('v94', 28800),
    ('v94', 19200),
    ('v48a', 28800), ('v48a', 31250), ('v48a', 38400),
    ('v90', 57600), ('v90', 115200), ('v90', 250000),
    ('v76', 19200), ('j20', 250000),
]

# THE CONTROLS: the SAME vectors at rates that came back clean. Without these the run cannot separate
# "this vector cannot be played" from "this rate cannot be played", which is the whole question.
CONTROL = [
    ('v71', 1875), ('v71', 4800), ('v93', 1200), ('v93', 4800),
    ('v94', 300), ('v94', 1200), ('v94', 4800),
    ('v90', 300), ('v90', 1200), ('v90', 4800), ('v90', 19200),
    ('v48a', 1200), ('v76', 1800), ('j20', 1200),
]

# THE THREE CONFIRMED MECHANISMS, carried along to check the new fitratio field behaves. Cheap: 5 pairs.
# j10 is the constant-bias case (+0.71 % at every rate, fatal only at the two that sit 2.344 % below a
# standard rate); v63/v90 at 125000 are the exact doubling, where rawbaud/commanded is 2.0000 and only
# fitratio can say whether sig_bittime found the double or ua_best chose it.
MECH = [('j10', 37500), ('j10', 125000), ('j10', 4800), ('v63', 125000), ('v90', 28800)]

PAIRS = SUSPECT + CONTROL + MECH


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--laps', type=int, default=40)
    ap.add_argument('--repeats', type=int, default=3)
    ap.add_argument('--first', type=int, default=1)
    a = ap.parse_args()
    if a.repeats < 1:
        raise SystemExit('--repeats must be at least 1')

    rows = []
    manifest = SP._manifest_rows()
    for it in range(a.first, a.first + a.laps):
        # THE CELL COUNTER RESETS PER LAP, exactly as soakplan.emit_csv does. A generator that numbered
        # cumulatively made brun.cellmax accumulate and the panel print 'cell 264 of 244'.
        n = 0
        for vi, (vid, baud) in enumerate(PAIRS):
            row = manifest.get(vid) or {}
            spb = int(row.get('spb') or 10)
            srate = int(round(baud * spb))
            # THE SAME CEILING soakplan APPLIES. A row the generator cannot play is not a test of
            # anything, and emitting one would put a cell on the key that always reports no stimulus --
            # indistinguishable, in this run of all runs, from the defect being investigated.
            if srate > _I.SDG_MAX_SRATE:
                sys.stderr.write('skipping %s at %d Bd: srate %d is past the %d Sa/s ceiling\n'
                                 % (vid, baud, srate, _I.SDG_MAX_SRATE))
                continue
            # THE AMPLITUDE AND OFFSET COME FROM soakplan's OWN DRAW, so every cell is inside the
            # generator's |OFST| + AMP/2 <= 10 V envelope. Half of a hundred-lap soak commanded a pair
            # this generator silently clamps, and the whole inversion family was that clamp.
            ua, uo = SP.amp_ofst_u(it, vi, baud % 97)
            amp, ofst = SP.amp_ofst_for(vid, ua, uo)[0:2]
            SP.assert_unclipped(vid, amp, ofst)
            kind = 'std' if baud in SP.standard_rates() else 'edge'
            for rep in range(a.repeats):
                n += 1
                rows.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                            % (it, n, vid, VMAP[vid], baud, kind, amp, ofst, srate,
                               1000.0 * SP.wait_s(it, vi, baud % 97, baud, rep)))

    percell = len(rows) // a.laps if a.laps else 0
    out = ['# generated by tools/mkplan_stim.py -- the stimulus-loss diagnostic',
           '# rows=%d' % len(rows),
           '# random-per-lap=all',
           '# repeats=%d' % a.repeats,
           # THE PANEL CANNOT COUNT A LAP IT HAS NOT FINISHED. brun.percell -- the 'of N' beside the cell
           # number -- is LEARNED from the highest cell seen in the previous lap, so for the whole of lap 1
           # the display has nothing to show and an operator watching for a lap boundary has to know the
           # number already. bench_run.tsp reads this header straight into brun.percell, which makes the
           # figure right from cell 1. soakplan's own emit_csv does not emit it; a lap there is 1677 by
           # construction, but nothing about that helps the person standing at the instrument.
           '# cells-per-lap=%d' % percell,
           '# pairs=%d suspect=%d control=%d mech=%d'
           % (len(PAIRS), len(SUSPECT), len(CONTROL), len(MECH)),
           'iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms']
    sys.stdout.write('\n'.join(out + rows) + '\n')
    sys.stderr.write('%d pair(s) x %d repeat(s) = %d cell(s) a lap, %d lap(s), %d row(s)\n'
                     % (len(PAIRS), a.repeats, len(PAIRS) * a.repeats, a.laps, len(rows)))


if __name__ == '__main__':
    main()

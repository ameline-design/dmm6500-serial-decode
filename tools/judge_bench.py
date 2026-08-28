#!/usr/bin/env python3
"""Judge a record written by bench/bench_run.tsp on the instrument.

    python3 tools/judge_bench.py out/bench/SOAK000.csv
    python3 tools/judge_bench.py out/bench/SOAK000.csv --verbose

WHY THE INSTRUMENT DOES NOT JUDGE. The verdict rules are the accumulated argument of this project --
the loud-vector allowance, the interior flag budget, the head skip, the cyclic substring over a looping
payload, and the lorem gate that judge_payload_v exists to replace. Reimplementing that in Lua 5.0.2 on
a 2016 instrument would be a SECOND judge, and two judges is the failure this repo keeps writing
comments about: on the night they disagree, both look right. So the instrument records what it read --
including the '??' it writes for a frame it flagged, which is what stops a byte passing only because the
error was ignored -- and this reads those rows through bench_uart's own judge.

WHAT IT CANNOT SEE. Nothing here reaches the panel, so the format-ambiguity notes, the button matrix and
the display are outside its scope: this judges BYTES and RATES against the stimulus the plan commanded.
The host-driven bench remains the wider test; this is the one that can run for a week.
"""
import argparse
import csv
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_uart as BU                                                  # noqa: E402
import soakplan as SP                                                    # noqa: E402
import vector_names as VN                                                # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = 'serdec-soak-1'

# The columns bench_rec.tsp writes after the 'R' tag, in order. Named here so a mismatch is a refusal
# rather than a silently shifted field -- the schema line in the file is what makes that checkable.
RCOLS = ['iter', 'cell', 'vid', 'baud', 'kind', 'amp_vpp', 'ofst_v', 'srate', 'wait_ms',
         'fs', 'sa_bit', 'ran', 'read_baud', 'fmt', 'nf', 'ngood', 'nbad', 'nflag',
         'headsusp', 'snapped', 'snapfirm', 'why', 'hex']


def payloads(vid):
    """The expected bytes for a vector, both legitimate readings where there are two.

    THREE VECTORS ARE FRAMED AMBIGUOUSLY BY CONSTRUCTION -- every byte of v90/v94's blocks has bit 7
    equal to the even parity of its low seven, so the payload is simultaneously valid 8N1 and valid 7E1
    and the app is right either way. Judging against one reading alone fails a correct decode.
    """
    import bench_matrix as BM
    return BM.plan_payloads(vid)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--verbose', action='store_true', help='one line per failing cell')
    a = ap.parse_args()

    with open(a.path) as f:
        raw = f.read()
    lines = [ln for ln in raw.split('\n') if ln.strip()]
    # THE SCHEMA IS CHECKED, not assumed. These files outlive the tool that wrote them and a reader that
    # mis-parses a column produces a verdict rather than an error, which is the worse failure.
    head = [ln for ln in lines if ln.startswith('#')]
    if not any(SCHEMA in h for h in head):
        raise SystemExit('REFUSING: %s does not declare schema %s in a header line. Its columns cannot '
                         'be trusted to be the ones this tool reads.' % (a.path, SCHEMA))

    rrows, srows = [], []
    for ln in lines:
        if ln.startswith('#'):
            continue
        f = next(csv.reader([ln]))
        if f[0] == 'R':
            if len(f) - 1 < len(RCOLS):
                # A TORN LAST LINE IS EXPECTED, not an error: a power cycle is the stop button, so the
                # final row can be half-written. Anything earlier is a real problem and says so.
                if ln is lines[-1]:
                    print('note: the last row is short (%d of %d fields) -- consistent with the power '
                          'being cut mid-write, which is how a run ends' % (len(f) - 1, len(RCOLS)))
                    continue
                raise SystemExit('REFUSING: a non-final R row has %d of %d fields'
                                 % (len(f) - 1, len(RCOLS)))
            rrows.append(dict(zip(RCOLS, f[1:1 + len(RCOLS)])))
        elif f[0] == 'S':
            srows.append(f)

    npass = nfail = ninc = nsdg = nnodec = 0
    ev = 0
    byvec = Counter()
    fails = []
    for r in rrows:
        vid = r['vid']
        if r['why'].startswith('SDG:'):
            nsdg += 1
            continue
        if r['ran'] != 'y':
            # NOT A FAILURE BY ITSELF. A refusal on a vector whose class allows it is the documented
            # right answer; the plan's own class decides, exactly as the offline twin does it.
            if SP.expect_for(vid) == 'loud':
                npass += 1
            else:
                nnodec += 1
                fails.append((vid, r['baud'], 'no decode: ' + r['why']))
            continue
        want = payloads(vid)
        got = r['hex'].upper()
        verdict, detail = 'INCONCLUSIVE', 'no payload for %s' % vid
        for w in (want or []):
            verdict, detail = BU.judge_payload_v(got, w, SP.expect_for(vid))
            if verdict == 'PASS':
                break
        # THE RATE IS JUDGED TOO, and separately: a capture can be byte-exact and still name a rate
        # 2.5 % wrong, which is cluster C and is invisible to any byte comparison.
        ratebad = False
        try:
            rb, cb = float(r['read_baud']), float(r['baud'])
            ratebad = abs(rb / cb - 1) > 0.02
        except ValueError:
            ratebad = True
        if verdict == 'PASS' and not ratebad:
            npass += 1
        elif verdict == 'INCONCLUSIVE':
            ninc += 1
        else:
            nfail += 1
            byvec[vid] += 1
            fails.append((vid, r['baud'],
                          ('rate %s for %s commanded' % (r['read_baud'], r['baud'])) if ratebad
                          else detail))

    print('%s' % a.path)
    print('  %d result row(s), %d progress row(s)' % (len(rrows), len(srows)))
    print('  %-14s %d' % ('pass', npass))
    print('  %-14s %d' % ('FAIL', nfail))
    print('  %-14s %d   (too few trusted bytes to judge)' % ('inconclusive', ninc))
    print('  %-14s %d   (nothing decoded on a vector that should decode)' % ('no decode', nnodec))
    print('  %-14s %d   (the generator, not the app)' % ('SDG failed', nsdg))
    if byvec:
        print('  failures by vector: %s' % ' '.join('%s %d' % kv for kv in byvec.most_common()))
    if srows:
        last = srows[-1]
        print('  last progress row: %s' % ','.join(last[1:]))
    if a.verbose and fails:
        print()
        for vid, baud, why in fails[:80]:
            print('  %-6s %8s Bd  %s' % (vid, baud, why[:110]))
    bad = nfail + nnodec
    print()
    if bad:
        print('%d BAD of %d judged' % (bad, npass + bad))
        return 1
    print('0 BAD of %d judged' % (npass + bad))
    return 0


if __name__ == '__main__':
    sys.exit(main())

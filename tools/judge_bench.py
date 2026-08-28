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


def split_runs(lines):
    """-> [(tag, [lines])], one entry per RUN in the file, in the order they were written.

    ONE FILE HOLDS MANY RUNS, and that is by design rather than by accident: the record is a single fixed
    filename opened for append, because a numbered name means probing candidates for a free one and a
    probe that misses posts event 2205 -- a box on the panel of an instrument that must never show one.
    bench_rec.tsp therefore separates runs by their header line, and this is the reader that honours it.

    Judging the whole file instead merges a smoke into a soak: the counts add up, no error is raised, and
    the verdict is about a mixture nobody ran. That is exactly the kind of quietly-wrong answer this
    project keeps finding, so the default is the LAST run and everything else takes a flag.

    A 'tag=roll' header is a CONTINUATION, not a new run: brec.roll writes one when a single run passes
    the per-file byte cap, and its rows belong to the run above it.
    """
    runs, cur = [], None
    for ln in lines:
        if ln.startswith('#') and SCHEMA in ln:
            tag = 'unnamed'
            for part in ln.split():
                if part.startswith('tag='):
                    tag = part[4:]
            if tag == 'roll' and cur is not None:
                continue                      # same run, next file
            cur = (tag, [])
            runs.append(cur)
            continue
        if cur is not None:
            cur[1].append(ln)
    return runs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--verbose', action='store_true', help='one line per failing cell')
    ap.add_argument('--run', default=None,
                    help='which run in the file: a 1-based index, a tag, or "all" to merge them')
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

    runs = split_runs(lines)
    print('%s holds %d run(s):' % (a.path, len(runs)))
    for i, (tag, body) in enumerate(runs):
        print('  %d  tag=%-10s %5d result row(s)'
              % (i + 1, tag, len([x for x in body if x.startswith('R,')])))
    if a.run is None or a.run == 'last':
        chosen = [runs[-1]] if runs else []
    elif a.run == 'all':
        chosen = runs
    elif a.run.isdigit() and 1 <= int(a.run) <= len(runs):
        chosen = [runs[int(a.run) - 1]]
    else:
        chosen = [r for r in runs if r[0] == a.run]
        if not chosen:
            raise SystemExit('REFUSING: no run in %s matches %r. The runs above are what it holds.'
                             % (a.path, a.run))
    print('  judging: %s' % ', '.join('%s (%d rows)'
                                      % (t, len([x for x in b if x.startswith('R,')]))
                                      for t, b in chosen))
    lines = []
    for _, body in chosen:
        lines.extend(body)
    # ONLY THE FILE'S LAST ROW MAY BE TORN. A power cycle is the stop button, so the final write can be
    # half-finished -- but a short row in the MIDDLE of the file means something else went wrong, and
    # excusing it would hide that. When an earlier run is selected, its last row is followed by more data,
    # so nothing here is allowed to be short.
    torn_ok = lines[-1] if (chosen and runs and chosen[-1] is runs[-1] and lines) else None

    rrows, srows = [], []
    for ln in lines:
        if ln.startswith('#'):
            continue
        f = next(csv.reader([ln]))
        if f[0] == 'R':
            if len(f) - 1 < len(RCOLS):
                # A TORN LAST LINE IS EXPECTED, not an error: a power cycle is the stop button, so the
                # final row can be half-written. Anything earlier is a real problem and says so.
                if ln is torn_ok:
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
                fails.append((r['iter'], r['cell'], vid, r['baud'],
                              'no decode: ' + r['why']))
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
            fails.append((r['iter'], r['cell'], vid, r['baud'],
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
        # THE LAP AND CELL, ON EVERY LINE. A fortnight is two hundred laps of the same 39 vectors, so
        # 'v77 at 9600 Bd failed' names a cell that occurs two hundred times. With the lap and cell the
        # exact stimulus is reproducible -- every amplitude, offset, wait and vector order is keyed on the
        # iteration -- which is the difference between a failure that can be replayed and one that cannot.
        # LnnnCmmm IS THE PROJECT'S FORMAT for a lap and a cell -- 'C' rather than '#' because these
        # files use '#' to mean a comment line, in the plan's header and the record's own -- the same string the instrument's own
        # status log writes -- so a failure quoted from either place reads the same way.
        for it, cell, vid, baud, why in fails[:80]:
            print('  %-10s %-6s %8s Bd  %s' % ('L%sC%s' % (it, cell), vid, baud, why[:100]))
    bad = nfail + nnodec
    print()
    if bad:
        print('%d BAD of %d judged' % (bad, npass + bad))
        return 1
    print('0 BAD of %d judged' % (npass + bad))
    return 0


if __name__ == '__main__':
    sys.exit(main())

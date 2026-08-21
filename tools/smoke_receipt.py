#!/usr/bin/env python3
"""Record that the smoke gate passed against an exact tree, and refuse a push that outran it.

WHY A RECEIPT AND NOT A PROMISE. "I ran the smoke test" is a claim about the past that says nothing
about the code being pushed -- the interesting case is the one-line fix made after the run, which is
exactly the change most likely to be wrong. So the receipt is CONTENT-ADDRESSED: it stores a hash of
tsp/ and tools/ as they were when the gate passed, and `--verify` recomputes it. Any edit to either
tree invalidates the receipt, including one made a minute later.

WHAT IS HASHED, and why both trees. tsp/ is the shipped app. tools/ is the harness that judges it, and
a harness defect is not a lesser problem: a wrong oracle invents failures by the hundred, and a
selection fault leaves a waveform unplayed. Neither is catchable by anything cheaper than this gate.

Docs, notes and out/ are not hashed, so a documentation push needs no bench.

    python3 tools/smoke_receipt.py --write --iteration 1 --cells 86 --presses 45
    python3 tools/smoke_receipt.py --verify          # exit 1 if the trees moved
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECEIPT = os.path.join(ROOT, 'out', 'smoke-receipt.json')
TREES = ('tsp', 'tools')


def tree_hash():
    """A hash over the CONTENT of every tracked file in tsp/ and tools/. -> (hex, count)

    git hash-object rather than mtimes: a file touched but unchanged must not invalidate a receipt,
    and a file changed back to a previous content must not appear changed.
    """
    h, n = hashlib.sha256(), 0
    for tree in TREES:
        out = subprocess.run(['git', 'ls-files', '-s', tree], cwd=ROOT,
                             capture_output=True, text=True).stdout
        for line in sorted(out.strip().split('\n')):
            if not line.strip():
                continue
            # "<mode> <sha1> <stage>\t<path>" -- the sha1 IS the content hash git records.
            h.update(line.encode())
            n += 1
    # Uncommitted work is the case that matters most, and ls-files -s reports the INDEX. So the working
    # tree is folded in too, or a receipt would survive an edit that was never staged.
    diff = subprocess.run(['git', 'diff', '--'] + list(TREES), cwd=ROOT,
                          capture_output=True, text=True).stdout
    h.update(diff.encode())
    return h.hexdigest()[:16], n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--iteration', type=int, default=0)
    ap.add_argument('--cells', type=int, default=0)
    ap.add_argument('--presses', type=int, default=0)
    ap.add_argument('--stamp', default='')
    a = ap.parse_args()

    hx, n = tree_hash()
    if a.write:
        os.makedirs(os.path.dirname(RECEIPT), exist_ok=True)
        with open(RECEIPT, 'w') as f:
            json.dump({'tree': hx, 'files': n, 'iteration': a.iteration, 'cells': a.cells,
                       'presses': a.presses, 'stamp': a.stamp}, f, indent=2, sort_keys=True)
            f.write('\n')
        print('smoke receipt written: tree %s over %d files' % (hx, n))
        return 0

    if not a.verify:
        print('use --write or --verify')
        return 2

    if not os.path.exists(RECEIPT):
        print('NO SMOKE RECEIPT. tsp/ or tools/ is being pushed with no record that the smoke gate '
              'passed against it.\n  python3 tools/bench_smoke.py')
        return 1
    with open(RECEIPT) as f:
        r = json.load(f)
    if r.get('tree') != hx:
        print('SMOKE RECEIPT IS STALE. It records tree %s; tsp/ and tools/ now hash to %s.'
              % (r.get('tree'), hx))
        changed = subprocess.run(['git', 'status', '--short', '--'] + list(TREES), cwd=ROOT,
                                 capture_output=True, text=True).stdout.strip()
        if changed:
            print('uncommitted in those trees:\n%s' % changed)
        print('Re-run the gate:\n  python3 tools/bench_smoke.py')
        return 1
    print('smoke receipt ok: tree %s, iteration %s, %s cells, %s presses%s'
          % (hx, r.get('iteration'), r.get('cells'), r.get('presses'),
             (', ' + r['stamp']) if r.get('stamp') else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())

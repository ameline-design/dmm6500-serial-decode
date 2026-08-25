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
    """A hash over the CONTENT of every tracked file in tsp/ and tools/, AS IT SITS ON DISK.
    -> (hex, count)

    THE WORKING TREE, AND NOTHING ELSE. This function used to hash `git ls-files -s` -- which reports
    the INDEX -- and fold in the unstaged `git diff` on top. Those two describe the same bytes in two
    different ways depending on what has been STAGED, so `git add` of a file whose content never
    changed moved the hash and invalidated a receipt the code had genuinely earned. The receipt then
    went stale on COMMIT rather than on EDIT, which is backwards: committing is the one action that
    cannot alter what was tested. Measured cost, 2026-08-22: seven SMOKE_OVERRIDE pushes, several of
    them for commits whose tsp/ and tools/ were byte-identical to the gate run that had just passed.
    It also broke the docs-only exemption, because once the hash had flipped a commit touching nothing
    but README.md was refused too.

    Reading the files directly is what makes the hash depend on content alone. `git ls-files` is still
    used, but only to enumerate TRACKED paths -- so an untracked scratch file or a stray .pyc under
    tools/ cannot invalidate a receipt, which is a second way the old form misfired.

    A path that is tracked but missing from disk is hashed as absent rather than skipped: deleting a
    module is exactly the kind of change the gate must not sit through silently.
    """
    h, n = hashlib.sha256(), 0
    for tree in TREES:
        out = subprocess.run(['git', 'ls-files', '-z', tree], cwd=ROOT,
                             capture_output=True).stdout
        for raw in sorted(out.split(b'\0')):
            if not raw:
                continue
            path = raw.decode('utf-8', 'surrogateescape')
            h.update(raw)
            full = os.path.join(ROOT, path)
            try:
                with open(full, 'rb') as fh:
                    h.update(hashlib.sha256(fh.read()).digest())
            except OSError:
                h.update(b'<absent>')
            n += 1
    return h.hexdigest()[:16], n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--iteration', type=int, default=0)
    ap.add_argument('--cells', type=int, default=0)
    ap.add_argument('--presses', type=int, default=0)
    # WHAT RAN IS PART OF THE RECORD, not just that something did. A --no-rates or --no-panel run must
    # not leave a receipt indistinguishable from a full one: the tree hash proves WHICH code passed, and
    # these counts prove WHAT it passed.
    ap.add_argument('--rates', type=int, default=0)
    ap.add_argument('--stamp', default='')
    a = ap.parse_args()

    hx, n = tree_hash()
    if a.write:
        os.makedirs(os.path.dirname(RECEIPT), exist_ok=True)
        with open(RECEIPT, 'w') as f:
            json.dump({'tree': hx, 'files': n, 'iteration': a.iteration, 'cells': a.cells,
                       'presses': a.presses, 'rates': a.rates, 'stamp': a.stamp},
                      f, indent=2, sort_keys=True)
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
    # rates via .get with a default, because a receipt written before the field existed has none and
    # must still verify rather than crash -- the tree hash is what decides validity.
    print('smoke receipt ok: tree %s, iteration %s, %s cells, %s presses, %s rate cases%s'
          % (hx, r.get('iteration'), r.get('cells'), r.get('presses'), r.get('rates', 0),
             (', ' + r['stamp']) if r.get('stamp') else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())

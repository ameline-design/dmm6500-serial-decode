#!/usr/bin/env python3
"""THE ELEVEN-MINUTE GATE: four waveforms across the rate range, then every button.

WHY IT EXISTS. A full soak lap is 157 minutes, so a broken harness costs an evening to discover --
and it did: a lap ran 147 minutes and its headline failures turned out to be an oracle asking for two
things that could not both be true. This asks the same questions on a quarter of the cells, so a
harness or app regression is found before anything long is started, and it is short enough to run
before every soak and after every change.

WHAT IT COVERS, and the pairing is crosswise on purpose:

    standard rates   v77  the fox, 8N1, 133 B repeating
                     r06  random, 7E1, 256 B non-repeating
    drawn rates      v78  the fox, 7E1
                     r00  random, 8N1

Each rate family therefore sees BOTH formats and BOTH content classes. Pairing by family instead --
fox on the standard ladder, random on the drawn rates -- would leave the standard rates never facing a
non-repeating payload, and that is where head alignment and the parity vote actually get tested.

Then the button matrix: 45 presses, every button in every state, with the panel grabbed either side
of each press. It is 2.8 of the 11 minutes and one press is 50 s of it -- the 8 kB one-shot -- which is
also the press most likely to catch the recording-path defects, so it stays.

THE CELLS ARE THE SOAK'S OWN CELLS. Rates, order and the wait before every capture come from
tools/soakplan.py at --iteration, and a wait is keyed on the cell's index in the FULL rate list. So a
failure here reproduces from the same iteration number the soak would use, and the offline twin can
replay it: python3 tools/soakplan.py --emit-lua --iteration N > p.lua && lua tools/sweep_plan.lua
--plan p.lua --cell v77:9600

    python3 tools/bench_smoke.py                 # iteration 1, needs a built app
    python3 tools/bench_smoke.py --iteration 7   # a different draw of the non-standard rates
    python3 tools/bench_smoke.py --no-panel      # the plan half only, about 8 minutes
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Crosswise, so each rate family sees both formats and both content classes. See the module note.
SPEC = 'v77:std,r06:std,v78:nonstd,r00:nonstd'


def run(name, argv, log):
    print('=== %s ===' % name)
    t0 = time.time()
    with open(log, 'w') as f:
        rc = subprocess.call(argv, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    secs = time.time() - t0
    with open(log, errors='replace') as f:
        out = f.read()
    # BAD IS THE FAILURE TOKEN IN THESE LOGS, not FAIL. A summary grep for FAIL alone reads a red run
    # as green, which is exactly how a failing stage got recorded as passing.
    nbad = out.count(' BAD ')
    tail = [ln for ln in out.split('\n')
            if 'points fully correct' in ln or ln.startswith('45 presses')
            or 'cases behaved acceptably' in ln]
    print('  %-4s %5.1f min  %d BAD  %s' % ('ok' if rc == 0 else 'FAIL', secs / 60.0, nbad,
                                            tail[-1] if tail else ''))
    return rc, nbad, secs, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iteration', type=int, default=1)
    ap.add_argument('--no-panel', action='store_true', help='skip the button matrix')
    ap.add_argument('--out', default=os.path.expanduser('~/tmp/smoke'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    print('SMOKE  iteration %d  spec %s%s' % (a.iteration, SPEC,
                                              '' if not a.no_panel else '  (no panel)'))
    print()
    rc1, bad1, s1, _ = run('plan', ['python3', '-u', 'tools/bench_matrix.py', '--suites', 'plan',
                                    '--no-start', '--no-output-off', '--iteration', str(a.iteration),
                                    '--plan-spec', SPEC,
                                    '--heartbeat', os.path.join(a.out, 'heartbeat.txt')],
                           os.path.join(a.out, 'plan.log'))
    rc2, bad2, s2 = 0, 0, 0.0
    if not a.no_panel:
        rc2, bad2, s2, _ = run('panel', ['python3', '-u', 'tools/bench_panel.py', '--reuse'],
                               os.path.join(a.out, 'panel.log'))

    print()
    print('%.1f min total, %d BAD' % ((s1 + s2) / 60.0, bad1 + bad2))
    if rc1 or rc2:
        print('SMOKE FAILED -- do not start a soak on this. Logs in %s' % a.out)
        print('Reproduce a failing cell offline:')
        print('  python3 tools/soakplan.py --emit-lua --iteration %d > /tmp/p.lua' % a.iteration)
        print('  lua tools/sweep_plan.lua --plan /tmp/p.lua --cell <vector>:<baud>')
        return 1
    # THE RECEIPT IS WRITTEN ONLY HERE, on the pass path, and it records a hash of tsp/ and tools/ as
    # they are right now -- so an edit made after this run invalidates it and the pre-push hook says so.
    subprocess.call(['python3', 'tools/smoke_receipt.py', '--write',
                     '--iteration', str(a.iteration), '--cells', '86',
                     '--presses', '0' if a.no_panel else '45',
                     '--stamp', time.strftime('%Y-%m-%dT%H:%M:%S')], cwd=ROOT)
    print('SMOKE PASSED')
    return 0


if __name__ == '__main__':
    sys.exit(main())

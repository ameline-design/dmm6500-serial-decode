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
of each press. It is 2.8 of the 12 minutes and one press is 50 s of it -- the 8 kB one-shot -- which is
also the press most likely to catch the recording-path defects, so it stays.

Then eight RATE cases from bench_break, ~1 min, covering the two things the stages above cannot:

  a lock the wire CONTRADICTS -- 2x and half-rate misfit, the +6 % silent-corruption edge, the offer
  answered both ways, and the back-off where no rate fits at all. Both stages above play a line whose
  rate is correct, so none of this is reachable from them.

  AUTOLOCK ON A NON-STANDARD RATE, asserted on force_baud. The plan suite's std cells all snap, so they
  passed under the old snap-only rule too; its nonstd cells run the path but assert only bytes, and
  locking changes what the NEXT capture does. So both stayed green whether autolock locked or not.

THE CELLS ARE THE SOAK'S OWN CELLS. Rates, order and the wait before every capture come from
tools/soakplan.py at --iteration, and a wait is keyed on the cell's index in the FULL rate list. So a
failure here reproduces from the same iteration number the soak would use, and the offline twin can
replay it: python3 tools/soakplan.py --emit-lua --iteration N > p.lua && lua tools/sweep_plan.lua
--plan p.lua --cell v77:9600

    python3 tools/bench_smoke.py                 # iteration 1, needs a built app
    python3 tools/bench_smoke.py --iteration 7   # a different draw of the non-standard rates
    python3 tools/bench_smoke.py --no-panel      # the plan half only, about 8 minutes
    python3 tools/bench_smoke.py --no-rates      # skip the wrong-lock cases

Skipping a stage is recorded in the receipt, not just in this log: --no-panel writes 0 presses and
--no-rates writes 0 rate cases, so a partial run cannot later be mistaken for a full one.
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

# THE WRONG-LOCK CASES, from bench_break rather than reimplemented here. Neither the plan stage nor the
# button matrix can reach them: both capture a line whose rate is correct, and these need a lock the
# wire CONTRADICTS. Without them the app's two self-correcting paths -- adopt the detected rate, or back
# off to auto-detect and re-capture -- were gated only by the full sweep's hw-break stage, which is an
# hour, so in practice they were tagged on offline evidence.
#
# FIVE CASES, ~40 s, chosen as the smallest set that covers both directions of misfit and both
# policies: 2x and half rate, the +6 % silent-corruption edge, the offer answered both ways under
# force_conflict = 'ask', and the back-off where nothing fits at all.
RATE_CASES = ('force-2x-rate,force-half-rate,force-6pct-fast,'
              'accept-detected-rate,decline-detected-rate,rate-backoff,'
              'autolock-16099,autolock-4444')


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
    ap.add_argument('--no-rates', action='store_true',
                    help='skip the wrong-locked-rate cases (adopt and back-off)')
    ap.add_argument('--keep-combine', action='store_true',
                    help='gate the stimulus WITH SDG CH2 summed into CH1, as the soak will run it')
    ap.add_argument('--out', default=os.path.expanduser('~/tmp/smoke'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    print('SMOKE  iteration %d  spec %s%s%s' % (a.iteration, SPEC,
                                                '' if not a.no_panel else '  (no panel)',
                                                '  (CH2 merged into CH1)' if a.keep_combine else ''))
    print()
    argv = ['python3', '-u', 'tools/bench_matrix.py', '--suites', 'plan',
            '--no-start', '--no-output-off', '--iteration', str(a.iteration),
            '--plan-spec', SPEC,
            '--heartbeat', os.path.join(a.out, 'heartbeat.txt')]
    if a.keep_combine:
        argv += ['--keep-combine']
    rc1, bad1, s1, _ = run('plan', argv, os.path.join(a.out, 'plan.log'))
    rc2, bad2, s2 = 0, 0, 0.0
    if not a.no_panel:
        rc2, bad2, s2, _ = run('panel', ['python3', '-u', 'tools/bench_panel.py', '--reuse'],
                               os.path.join(a.out, 'panel.log'))
    # AFTER the panel matrix, because rate-backoff stubs sdec.ua_badfrac on the instrument. bench_break
    # restores it in its own teardown, but running last means a teardown that failed cannot silently
    # change the verdict of anything else in this gate.
    rc3, bad3, s3 = 0, 0, 0.0
    if not a.no_rates:
        rc3, bad3, s3, _ = run('rates', ['python3', '-u', 'tools/bench_break.py', '--reuse',
                                         '--only', RATE_CASES],
                               os.path.join(a.out, 'rates.log'))

    print()
    print('%.1f min total, %d BAD' % ((s1 + s2 + s3) / 60.0, bad1 + bad2 + bad3))
    if rc1 or rc2 or rc3:
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
                     '--rates', '0' if a.no_rates else str(len(RATE_CASES.split(','))),
                     '--stamp', time.strftime('%Y-%m-%dT%H:%M:%S')], cwd=ROOT)
    print('SMOKE PASSED')
    return 0


if __name__ == '__main__':
    sys.exit(main())

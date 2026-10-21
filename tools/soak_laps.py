#!/usr/bin/env python3
"""Run the soak ON THE INSTRUMENT for a given number of laps. One argument.

    python3 tools/soak_laps.py 4              # four laps, ~8.9 h, host detaches
    python3 tools/soak_laps.py 4 --cycled     # after a smoke, when the DMM HAS been power cycled
    python3 tools/soak_laps.py 4 --dry-run    # print the command and the estimate, touch nothing

WHY THIS EXISTS. Starting this run by hand went wrong five ways in one sitting, and every one of them
is encoded here so it cannot happen again:

  * `tools/soak.py` is NOT this. It loops bench_matrix FROM THE HOST over the LAN. The on-instrument
    soak is `brun.soak()`, reached through run_bench.py, and it keeps running with no host attached.
  * `--detach` without `--start` starts NOTHING and still exits 0 -- run_bench says so in its own
    error, which is only read if you read it.
  * `--iterations N` is laps, and it also sizes the PLAN: one lap pushed 1518 rows, four pushed 6054.
    Launching with 0 pushes a single lap, so "indefinite" was over in under three hours. That row
    count is the only honest estimate of how long a run will take, which is why this prints one.
  * `--skip-vectors` must be left alone. run_bench defaults it to soakplan.HW_SKIP, and the skip is
    applied BEFORE the shuffle, so a list one name short hands every vector another's amplitude,
    offset and wait. This script does not expose the flag.
  * `--after-cycle` is needed after a smoke and ONLY then: it skips a refusal that exists because
    smoke-then-soak without a power cycle has failed every cell three times. It is opt-in here rather
    than always-on, because always-on would quietly delete the guard.

The plan is always re-pushed. It costs about 19 s for four laps and removes the one failure this
cannot otherwise detect: a targeted `--spec` from an earlier session still sitting in PLAN.CSV.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# MEASURED ON A FULL RUN, not inferred from a comment. The 2026-10-21 soak took 8.83 h for 6048
# cells, which is 5.26 s a cell. bench_run's own "a 1677-cell lap is about two hours" works out at
# 4.3, and using that under-estimated a four-lap run by about an hour and a half -- so the figure
# here is the one an actual run produced. docs/MEASUREMENTS.md splits a cell 58 % acquire and 31 %
# decode, the generator costing nothing, so it scales with CELLS and not with the rate ladder.
# An estimate, printed as one, not a promise.
SECS_PER_CELL = 5.26

# The plan file's preamble, in lines. Measured, not assumed: see the derivation where it is used.
HEADER_LINES = 6


def main():
    ap = argparse.ArgumentParser(description='Run the on-instrument soak for N laps.')
    ap.add_argument('laps', type=int, help='laps to run; each is one pass of the plan, about 2.2 h')
    ap.add_argument('--cycled', action='store_true',
                    help='the DMM has been power cycled since the last smoke. Required after a '
                         'smoke, and meaningless otherwise')
    ap.add_argument('--dry-run', action='store_true',
                    help='print the command and the estimate; touch no instrument')
    a = ap.parse_args()

    if a.laps < 1:
        raise SystemExit('REFUSING: laps must be at least 1. run_bench --iterations 0 pushes a '
                         'SINGLE lap and then stops, which is not an indefinite run.')

    argv = [sys.executable, '-u', os.path.join(ROOT, 'tools', 'run_bench.py'),
            '--start', '--detach', '--push-plan', '--iterations', str(a.laps)]
    if a.cycled:
        argv.append('--after-cycle')

    print('soak: %d lap(s) on the instrument' % a.laps)
    print('  %s' % ' '.join(argv[2:]))
    if not a.cycled:
        print('  NOTE: --cycled not given. If a smoke has run since the last power cycle, run_bench '
              'will refuse, and it is right to.')
    if a.dry_run:
        print('  dry run: nothing started')
        return 0

    # Streamed rather than captured, so a long plan push is visible while it happens, and parsed on
    # the way past for the row count -- the only figure that says how long this will take.
    rows = None
    p = subprocess.Popen(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1)
    for ln in p.stdout:
        sys.stdout.write(ln)
        m = re.search(r'plan pushed:\s*(\d+)\s*row', ln)
        if m:
            rows = int(m.group(1))
    rc = p.wait()

    if rc != 0:
        print('\nSOAK DID NOT START: run_bench exited %d. Nothing is running.' % rc)
        return rc

    # AFTER the run is up, because an estimate printed before it starts is an estimate of a run that
    # might not have started -- which is the exact shape of the --detach-without---start trap.
    if rows is None:
        print('\nSTARTED, but the plan row count was not seen, so no estimate can be given. Read the '
              'output above: a run that pushed no plan is not a run.')
        return 0

    # ROWS ARE LINES, NOT CELLS, and multiplying the line count by a per-cell figure over-states
    # the run. The plan carries HEADER_LINES of preamble: measured 2026-10-21 from two pushes of the
    # same plan, 1518 lines for one lap and 6054 for four, so `h + d = 1518` and `h + 4d = 6054` give
    # d = 1512 cells and h = 6. docs/BRUN.md warns about exactly this difference.
    cells = rows - HEADER_LINES
    if cells < 1:
        print('\nSTARTED, but %d plan row(s) is fewer than the %d header lines -- no estimate.'
              % (rows, HEADER_LINES))
        return 0
    secs = cells * SECS_PER_CELL
    end = datetime.datetime.now() + datetime.timedelta(seconds=secs)
    # NOT "running". run_bench SENDS brun.soak and does not wait for an acknowledgement, so its exit
    # code says the start was dispatched and nothing more -- the same gap as the --detach-without
    # ---start trap, which also exited 0 having started nothing. The record on the key is the only
    # thing that can confirm the loop is turning.
    print('\nstart dispatched: %d plan row(s) = %d cell(s) over %d lap(s)'
          % (rows, cells, a.laps))
    print('  NOT CONFIRMED RUNNING -- run_bench does not wait for an acknowledgement. Confirm from '
          'the record, not from this message.')
    print('  estimate %.1f h a lap, %.1f h total -- would finish about %s'
          % (secs / 3600.0 / a.laps, secs / 3600.0, end.strftime('%H:%M on %a %d %b')))
    print('  %.1f s a cell, measured, so this scales with CELLS and not with the rate ladder' %
          SECS_PER_CELL)
    print('  it closes its own record when the laps are done; the front-panel TRIGGER key stops it')
    print('  early and also closes the record. Cutting power does NOT close it.')
    print('  then: python3 tools/run_bench.py --fetch')
    return 0


if __name__ == '__main__':
    sys.exit(main())

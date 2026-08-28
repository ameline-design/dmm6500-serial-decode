#!/usr/bin/env python3
"""Run the offline suites in a loop for a wall-clock duration, on TWO trees at once: this one, and a
copy with a named fix reverted. Paired, so the result is a comparison and not an assertion.

WHY PAIRED, AND WHY IT IS THE POINT OF THE FILE. "The tests pass" is not evidence that a fix works --
the first regression test written for the r06 crash passed with the fix REMOVED, because the case it
built never reached the broken branch. The only convincing offline result is a pair: the suites clean
on the fixed tree, and the SAME suites, in the SAME run, failing on a tree that differs by exactly
the fix. Anything else leaves "the test cannot see this defect" indistinguishable from "the defect is
gone".

    python3 tools/soak_offline.py --minutes 30
    python3 tools/soak_offline.py --minutes 5 --workers 8      # a quick check
    python3 tools/soak_offline.py --laps 20 --trees fixed      # a fixed number of passes, not a clock

The reverted tree is built with `git archive HEAD` into a scratch directory and then edited by
deleting REVERT_LINE. If that deletion does not change the file the run ABORTS: a "nofix" tree that
still has the fix would quietly report that the defect never reproduces, which is the exact false
negative this file exists to prevent.

Each lap varies --seed, so successive laps of the phase sweep probe different capture placements
rather than re-running one grid. That is what makes thirty minutes worth more than one pass.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plan_sweep as PS                                        # noqa: E402
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRATCH = os.path.expanduser('~/tmp/soak_offline')

# The single line whose absence is the r06 defect -- r06 being the 7-bit random vector that exposed it.
# Matched exactly, and the abort below is what makes
# a silent mismatch impossible: if this string ever stops appearing verbatim, the pairing is broken
# and the run must stop rather than compare a tree against itself.
REVERT_FILE = 'tsp/uart_decode.tsp'
REVERT_LINE = 'r2.nbits, r2.par, r2.nstop, r2.invert = 7, par, r.nstop, r.invert'

# One entry per suite. `seeded` marks the ones that take --seed, i.e. the ones where another lap
# explores new ground instead of repeating the last.
SUITES = [
    ('unit',      ['lua', 'tools/test_serial.lua'],            False),
    ('analog',    ['lua', 'tools/test_analog.lua'],            False),
    ('patterns',  ['lua', 'tools/test_patterns.lua'],          False),
    ('stress',    ['lua', 'tools/stress_serial.lua'],          False),
    ('cancel',    ['lua', 'tools/test_cancel.lua'],            False),
    ('streamfix', ['lua', 'tools/test_streamfix.lua'],         False),
    ('ratefit',   ['lua', 'tools/test_ratefit.lua'],           False),
    ('phase',     ['lua', 'tools/sweep_startphase.lua'],       True),
    # SEEDED, because its --iteration IS the seed: each value draws a different set of baud rates,
    # amplitudes, offsets and waits, so another lap replays a soak night nobody has run yet. It is also
    # the only unit here whose sample rate is fractional and whose edge comes from a real arb file.
    ('plan',      ['lua', 'tools/sweep_plan.lua'],             True),
]


def build_nofix(dst):
    """Copy the WORKING tree to dst, then delete REVERT_LINE. -> raises if the deletion is a no-op.

    THE WORKING TREE, NOT `git archive HEAD`, because the difference produces a confidently false
    result. git archive ships COMMITTED content only, so an uncommitted detector is absent from the
    copy -- the reverted tree then passes every suite and the run reports that the defect cannot be
    reproduced. The tree under test has to be the tree you are actually editing.

    out/ is excluded because it is 91 MB of generated vectors that nothing here reads: every suite
    builds its payloads in process, and make_vectors runs in define-only mode.
    """
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    subprocess.run(['rsync', '-a',
                    '--exclude', '.git/', '--exclude', 'out/', '--exclude', '__pycache__/',
                    ROOT + '/', dst + '/'], check=True)
    path = os.path.join(dst, REVERT_FILE)
    with open(path) as f:
        before = f.read()
    hits = before.count(REVERT_LINE)
    if hits != 1:
        raise SystemExit('ABORTING: %r appears %d times in %s, expected exactly 1. The pairing '
                         'cannot be built, and a nofix tree that still has the fix would report '
                         'that the defect does not reproduce.' % (REVERT_LINE, hits, REVERT_FILE))
    after = '\n'.join(l for l in before.split('\n') if REVERT_LINE not in l)
    if after == before:
        raise SystemExit('ABORTING: deleting the fix line changed nothing')
    with open(path, 'w') as f:
        f.write(after)
    # out/vectors IS INPUT, NOT OUTPUT, and it is the only part of out/ that is. The plan suite reads
    # the arb files from there, so without this it would fail in this tree for a missing file and the
    # pairing would report the defect as unreproducible. SYMLINKED rather than copied, because both
    # trees must decode the SAME samples -- a second copy is a second thing that can drift, and the
    # only difference between the trees is meant to be REVERT_LINE.
    os.makedirs(os.path.join(dst, 'out'), exist_ok=True)
    os.symlink(os.path.join(ROOT, 'out', 'vectors'), os.path.join(dst, 'out', 'vectors'))
    return dst


def run_one(tree, name, argv, seed, shards):
    """One suite in one tree. -> dict."""
    cmd = list(argv)
    if name == 'phase':
        # The sweep shards itself; one lap here is one shard, so a lap of `phase` across the pool
        # covers the whole vector set without a nested driver competing for the same cores.
        cmd += ['--shard', '%d/%d' % (1 + (seed % shards), shards), '--offsets', '16',
                '--seed', str(seed), '--quiet']
    elif name == 'plan':
        # THE PLAN IS EMITTED, NEVER READ FROM A FILE ON DISK: a plan is a snapshot of the draw, and a
        # plan drawn under different soakplan constraints describes a different experiment with nothing
        # in its name to say so. tools/plan_sweep.py carries the measurement.
        #
        # sweep_plan.lua is run DIRECTLY rather than through plan_sweep.py, one shard per lap, for the
        # same reason as `phase`: the driver would open its own 12-wide pool inside this one.
        # The path is ABSOLUTE, so the reverted tree reads the same plan while its out/vectors symlink
        # resolves relative to its own cwd.
        plan, _ = PS.emit_plan(1 + (seed % 64))
        cmd += ['--plan', plan, '--shard', '%d/%d' % (1 + (seed % shards), shards),
                '--offsets', '8', '--quiet']
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=tree, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=900)
        rc, out = p.returncode, p.stdout.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        rc, out = 124, '<timed out after 900 s>'
    return {'suite': name, 'rc': rc, 'secs': round(time.time() - t0, 2), 'out': out, 'seed': seed}


# SUITES WHOSE EXIT CODE IS NOT A VERDICT, and this is not a convenience. sweep_plan.lua exits 1
# whenever any point behaves worse than its class allows, and on the current tree that is 16 of 1677
# cells at one offset and 221 of 13416 points at eight -- all of them #46 and #125, both open and
# deliberately unfixed. Counting rc as failure here would make the plan unit fail every lap forever,
# which is a gate that cannot pass and therefore says nothing when it goes red.
#
# So the plan unit is judged on the two things that are wrong at ANY capture placement: a decode that
# RAISED, and a run that printed no summary at all (the interpreter died before the report, and
# totalling nothing from it would turn a broken run into a clean one).
RC_NOT_A_VERDICT = {'plan'}
PLAN_LINE = re.compile(r'^PLAN \d+/\d+ iteration (\d+): (.*)$', re.M)


def plan_verdict(out):
    """(failed, counters) for a plan unit. counters is None when no summary was printed."""
    m = PLAN_LINE.search(out or '')
    if m is None:
        return True, None
    got = {}
    for k in PS.KEYS:
        mm = re.search(r'\b' + re.escape(k) + r' (\d+)', m.group(2))
        got[k] = int(mm.group(1)) if mm else 0
    got['iteration'] = int(m.group(1))
    return (got['raised'] > 0 or got['ok'] + got['bad'] == 0), got


def r06_signature(out):
    """Does this output carry the r06 defect specifically? -> bool.

    NAMED RATHER THAN 'ANY FAILURE'. A nofix tree could fail for an unrelated reason -- a flaky
    assertion, a missing file -- and counting that as "the defect reproduced" would make the pairing
    prove nothing. These are the two strings the defect itself produces.
    """
    return ('carries the format that produced it' in out
            or "bad argument #2 to 'format'" in out
            or 'NO FORMAT' in out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--minutes', type=float, default=30.0)
    # LAPS INSTEAD OF A CLOCK, for the case where the question is "run the suites N times" rather than
    # "keep busy until T". A LAP IS ONE RUN OF EVERY SUITE IN EVERY SELECTED TREE, so 20 laps is 20
    # runs of each -- and the seeded ones get a distinct seed per lap, which is the whole reason a lap
    # count means anything. --laps overrides --minutes; the deterministic-suite cap does not apply,
    # because with laps the count IS the request.
    ap.add_argument('--laps', type=int, default=None,
                    help='run every suite exactly N times instead of running for --minutes')
    ap.add_argument('--workers', type=int, default=12)
    ap.add_argument('--shards', type=int, default=12,
                    help='shard count the phase sweep divides itself into (default 12)')
    ap.add_argument('--det-runs', type=int, default=12,
                    help='runs of each DETERMINISTIC suite before the budget goes to the seeded '
                         'sweep (default 12; more only re-computes the same answer)')
    # ONCE THE PAIRING HAS BEEN DONE, THE REVERTED TREE IS SPENT. It exists to show the suites can
    # SEE the defect; after that every lap spent on it is a lap not spent looking for something new,
    # and it fails by design, which makes a long run's failure count meaningless at a glance. So a
    # long run is 'fixed' only -- and the verdict below then states plainly that it is not a pairing.
    ap.add_argument('--trees', default='fixed,nofix',
                    help="which trees to run: 'fixed', 'nofix', or both (default both). A single "
                         "tree cannot prove the fix works -- it can only fail to find a problem.")
    ap.add_argument('--outdir', default=None)
    a = ap.parse_args()

    want = [t.strip() for t in a.trees.split(',') if t.strip()]
    for t in want:
        if t not in ('fixed', 'nofix'):
            raise SystemExit('--trees takes fixed and/or nofix, not %r' % t)
    if not want:
        raise SystemExit('--trees selected nothing')

    fixed = ROOT
    nofix = None
    print('fixed tree: %s' % fixed)
    if 'nofix' in want:
        # Built only when it is going to be used: the rsync copies the whole working tree.
        nofix = build_nofix(os.path.join(SCRATCH, 'nofix'))
        print('nofix tree: %s   (%s deleted from %s)' % (nofix, REVERT_LINE, REVERT_FILE))
    else:
        print('nofix tree: not built -- --trees %s' % a.trees)

    outdir = a.outdir or os.path.join(ROOT, 'out', 'offline_soak',
                                      time.strftime('%Y-%m-%dT%H-%M-%S'))
    os.makedirs(outdir, exist_ok=True)
    deadline = time.time() + a.minutes * 60.0
    if a.laps is not None:
        # SPELLED OUT, because this file already calls one (tree, suite) run a "lap" in its own tally
        # and the two numbers differ by a factor of the suite count. A reader who takes the summary's
        # lap count for the requested one is out by 8x per tree.
        print('running %d lap(s) of %d suite(s) x %d tree(s) = %d unit run(s) on %d workers'
              % (a.laps, len(SUITES), len(want), a.laps * len(SUITES) * len(want), a.workers))
    else:
        print('running %.0f minutes on %d workers' % (a.minutes, a.workers))
    print('results in %s' % outdir)
    print()

    # HALF THE POOL EACH, so the two trees see the same machine load at the same wall-clock moment.
    # Running them in sequence would compare a cold cache against a warm one and a quiet machine
    # against a busy one, and the only number that matters here is a difference between them.
    stats = {}
    for tag in want:
        stats[tag] = {'laps': 0, 'fail': 0, 'r06': 0, 'bysuite': {}}
    jsonl = open(os.path.join(outdir, 'laps.jsonl'), 'w')
    seed = 0
    t0 = time.time()

    # ONE UNIT IS ONE (TREE, SUITE), AND A UNIT IS NEVER IN FLIGHT TWICE. Not a scheduling nicety:
    # tools/test_serial.lua wrote its arb round-trip to one fixed filename, so running it 16-ways
    # parallel made 3 runs of 16 fail on each other's bytes -- two without even reaching the summary.
    # That file is now unique per process, but the general hazard is not, and a harness that invents
    # failures is worse than a slow one. 7 suites x 2 trees = 14 units against 12 workers, so the
    # pool stays full anyway.
    # REPEATING A DETERMINISTIC SUITE ADDS NO INFORMATION, and that is what makes this a soak rather
    # than a busy loop. Two failed designs came first, both measured:
    #   round-robin        -- test_streamfix (0.0 s) ran 569 times, test_analog (13.7 s) ran 5.
    #   fewest-runs-first  -- equalised COUNTS, so 5827 laps in 3 minutes and ~416 runs of each
    #                         deterministic suite. Every one of those 416 runs computed the same
    #                         answer from the same input. Zero new coverage for thirty minutes of
    #                         twelve cores.
    # Only the phase sweep varies with --seed: a fresh seed skews the capture start offsets, so each
    # lap decodes placements no previous lap tried. So the deterministic suites run a fixed handful of
    # times -- enough to prove they are parallel-safe and stable, which is a real thing to check
    # after the scratch-file collision found earlier today -- and the entire remaining budget goes to
    # seeded laps, several at once, since separate shards and seeds share nothing.
    units = [(tag, name, argv, sd) for tag in want for (name, argv, sd) in SUITES]
    treeof = {'fixed': fixed, 'nofix': nofix}
    nrun_unit = dict(((tag, name), 0) for (tag, name, _, _) in units)
    seeded = dict(((tag, name), sd) for (tag, name, _, sd) in units)

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        inflight = {}
        busy = set()

        def submit_next():
            """Submit the next useful unit. -> True if one was submitted.

            IN LAPS MODE EVERY UNIT IS EQUAL and is eligible until it has had --laps runs: the count
            IS the request, so --det-runs does not apply and a lap of `unit` is as wanted as a lap of
            `phase`. Deterministic units are still never in flight twice at once.

            Otherwise deterministic units are eligible until they have had --det-runs runs and never
            run twice at once; seeded units are always eligible and may run concurrently, because a
            different seed is a different experiment.
            """
            nonlocal seed
            if a.laps is not None:
                elig = [u for u in units if nrun_unit[(u[0], u[1])] < a.laps
                        and (u[3] or (u[0], u[1]) not in busy)]
                if not elig:
                    return False
                tag, name, argv, _ = min(elig, key=lambda u: nrun_unit[(u[0], u[1])])
            else:
                det = [u for u in units
                       if not u[3] and (u[0], u[1]) not in busy
                       and nrun_unit[(u[0], u[1])] < a.det_runs]
                if det:
                    tag, name, argv, _ = min(det, key=lambda u: nrun_unit[(u[0], u[1])])
                else:
                    sd = [u for u in units if u[3]]
                    if not sd:
                        return False
                    tag, name, argv, _ = min(sd, key=lambda u: nrun_unit[(u[0], u[1])])
            nrun_unit[(tag, name)] += 1
            seed += 1
            # Only the deterministic units are held to one at a time. A seeded unit is a different
            # experiment per seed, and its scratch paths are per process, so it may run in parallel.
            if not seeded[(tag, name)]:
                busy.add((tag, name))
            f = ex.submit(run_one, treeof[tag], name, argv, seed, a.shards)
            inflight[f] = (tag, name)
            return True

        while len(inflight) < a.workers:
            if not submit_next():
                break

        while inflight:
            done = next(as_completed(list(inflight.keys())))
            tag, name = inflight.pop(done)
            busy.discard((tag, name))
            r = done.result()
            st = stats[tag]
            st['laps'] += 1
            bs = st['bysuite'].setdefault(name, {'runs': 0, 'fail': 0})
            bs['runs'] += 1
            counters = None
            if name in RC_NOT_A_VERDICT:
                bad, counters = plan_verdict(r['out'])
            else:
                bad = r['rc'] != 0
            if bad:
                st['fail'] += 1
                bs['fail'] += 1
            if r06_signature(r['out']):
                st['r06'] += 1
            rec = {'tree': tag, 'suite': name, 'rc': r['rc'], 'secs': r['secs'],
                   'seed': r['seed'], 'r06': r06_signature(r['out']),
                   'failed': bad,
                   # THE PLAN UNIT'S COUNTS ARE KEPT EVERY LAP, PASS OR FAIL. They are the whole point
                   # of running it repeatedly: #46 and #125 are open, so what a soak adds is the
                   # DISTRIBUTION of their counts across draws nobody has run, and a tail kept only on
                   # failure would throw exactly that away.
                   'plan': counters,
                   'tail': r['out'][-1500:] if bad else ''}
            jsonl.write(json.dumps(rec) + '\n')
            jsonl.flush()
            mark = 'ok  ' if not bad else 'FAIL'
            extra = ''
            if counters is not None:
                extra = ('  it %d: %d bad of %d, %d rate %d bytes %d nobytes'
                         % (counters['iteration'], counters['bad'], counters['points'],
                            counters['rate'], counters['bytes'], counters['nobytes']))
            print('%6.1f min  %-5s %-10s %s  %5.1fs%s%s'
                  % ((time.time() - t0) / 60.0, tag, name, mark, r['secs'],
                     '  <r06 signature>' if rec['r06'] else '', extra))

            # IN LAPS MODE THERE IS NO DEADLINE: submit_next() returns False once every unit has had
            # its --laps runs, which is what ends the run.
            if a.laps is not None or time.time() < deadline:
                while len(inflight) < a.workers:
                    if not submit_next():
                        break

    jsonl.close()
    with open(os.path.join(outdir, 'summary.json'), 'w') as f:
        json.dump({'minutes': a.minutes, 'stats': stats}, f, indent=2)

    print()
    print('%-6s %6s %6s %14s' % ('tree', 'laps', 'failed', 'r06 signature'))
    for tag in want:
        s = stats[tag]
        print('%-6s %6d %6d %14d' % (tag, s['laps'], s['fail'], s['r06']))
    print()
    for tag in want:
        parts = ['%s %d/%d' % (k, v['fail'], v['runs'])
                 for k, v in sorted(stats[tag]['bysuite'].items())]
        print('%-6s failed/runs by suite: %s' % (tag, '  '.join(parts)))
    print()

    ok = True
    if 'fixed' in stats and stats['fixed']['fail'] != 0:
        print('VERDICT: FAILED -- the fixed tree is not clean (%d of %d laps failed). The failing '
              'laps are in laps.jsonl with their output.'
              % (stats['fixed']['fail'], stats['fixed']['laps']))
        ok = False
    if 'nofix' in stats:
        # THE VERDICT IS THE PAIR, and both halves have to hold. A clean fixed tree alone is what the
        # vacuous test already gave us.
        if stats['nofix']['r06'] == 0:
            print('VERDICT: INCONCLUSIVE -- the reverted tree never showed the r06 signature in %d '
                  'laps, so these suites cannot see the defect and a clean fixed tree proves '
                  'nothing about it.' % stats['nofix']['laps'])
            ok = False
        elif ok:
            print('VERDICT: the fixed tree ran %d laps with no failure, while the tree differing by '
                  'exactly one line showed the r06 signature in %d of %d laps.'
                  % (stats['fixed']['laps'], stats['nofix']['r06'], stats['nofix']['laps']))
    elif ok:
        # SAYING WHAT THIS IS NOT is the point of this branch. One tree cannot show that a fix works;
        # it can only fail to find a problem, and those are different claims. The discrimination comes
        # from a PAIRED run, which is a different output directory -- name the distinction here rather
        # than let a large clean lap count be read as proof.
        print('VERDICT: no failure in %d laps on the fixed tree. THIS IS NOT A PAIRING: it shows '
              'these suites found nothing wrong, not that the fix works -- for that, see a run with '
              '--trees fixed,nofix, where the reverted tree has to fail.' % stats['fixed']['laps'])
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

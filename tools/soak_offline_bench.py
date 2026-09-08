#!/usr/bin/env python3
"""Soak the BENCH path offline, under the instrument's own Lua 5.0.2, with a fresh capture phase per lap.

    python3 tools/soak_offline_bench.py --hours 6 --workers 12
    python3 tools/soak_offline_bench.py --laps 4 --workers 2          # a smoke of this harness itself

WHY THIS EXISTS SEPARATELY FROM soak_offline_long.py. That one drives tools/plan_sweep.py, which captures
through the TRIGGERED path and derives its window from the plan's wait -- so it exercises neither of the
two stimulus models added on 2026-09-07. Measured: turning both on left plan_sweep's verdict at exactly
110 bad, unchanged, because it never calls dmm.digitize.read() and never asks GEN_ENVELOPE for a pair the
plan generator would have refused to emit. A soak meant to exercise them therefore has to run the bench
engine, which is what tools/offline_bench.lua does.

WHAT VARIES AND WHAT DOES NOT. One phase seed per lap, so the laps between them cover phase space while
each lap on its own replays exactly from its seed. The plan is the same one every lap: the point is the
capture window, not the draw, and holding the plan fixed is what makes a difference between laps mean
something. Every worker gets its own record file and its own seed range.

WHAT COUNTS AS AN ALARM. Not a failure count -- a healthy lap has plenty, because the plan drives seven
vectors into conditions where refusing is the documented right answer. The alarms are:

    raised          a Lua error reached the harness. Always a defect.
    nobytes         the sentinel from the anchor fix; disclosed at ~2.3e-5 per cell, so a lap or two is
                    normal and a step change is not.
    no-decode       a vector that should decode produced nothing.
    inconclusive    too few trusted bytes to judge.
    envelope        the generator envelope altered a stimulus. Expected to be ZERO on a soakplan plan,
                    since soakplan refuses out-of-envelope pairs; non-zero means the conditions moved.
    crash           the worker exited non-zero, or wrote no record at all.

Read the summary's per-lap FAIL RATE against the baseline it prints, not against zero.
"""

import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA502 = os.path.join(ROOT, 'out', 'lua502', 'bin', 'lua')
STAGE = os.path.join(ROOT, 'out', 'lua502src')


def opt(argv, name, default):
    return argv[argv.index(name) + 1] if name in argv else default


# Set once from --stress-envelope, read by harvest() to know which way to check the envelope count.
STRESS = False
# Measured on this plan with the phase draw OFF, so they are the harness's own floor and not a target.
NODECODE_BASE = 1
INCONC_BASE = 2


def main(argv):
    hours = float(opt(argv, '--hours', '0'))
    laps = int(opt(argv, '--laps', '0'))
    workers = int(opt(argv, '--workers', '12'))
    plan = opt(argv, '--plan', None)
    outdir = opt(argv, '--out', '/tmp/soak_bench')
    seed0 = int(opt(argv, '--seed0', '1'))
    # LINEAR RECONSTRUCTION BETWEEN ARB SAMPLES. Off unless asked, matching gen_serial's default, so a
    # run that does not name it is the zero-order-hold arm rather than an unlabelled mixture.
    interp = '--interp' in argv
    # THE DIGITISER'S ACTUAL RATE. Off unless asked, matching gen_serial's default.
    truefs = '--truefs' in argv
    # THE DMM'S FRONT END. Off unless asked, matching gen_serial's default.
    frontend = '--frontend' in argv
    if hours <= 0 and laps <= 0:
        print('REFUSING: pass --hours H or --laps N. A soak with no end condition is not a soak.')
        return 2

    os.makedirs(outdir, exist_ok=True)
    # STAGED ONCE, NOT PER LAP. offline502.py rebuilds the tree from scratch every call, which is right for
    # a one-shot run and wrong here: it would be rebuilt thousands of times and two workers would race on
    # the same directory. Built once up front, then treated as read-only by every worker.
    # --no-stage IS FOR A SECOND POOL SHARING THE TREE. offline502.py --stage rebuilds from scratch, so two
    # pools starting together race: one calls unstage() while the other is writing into the same directory,
    # and the loser dies in os.unlink on a file that has just gone. Stage once, then run every further pool
    # with --no-stage. The tree is read-only to the workers, so sharing it is safe.
    if '--no-stage' in argv:
        if not os.path.isdir(STAGE):
            print('REFUSING: --no-stage but %s does not exist. Stage it first.' % STAGE)
            return 2
        print('using the existing 5.0.2 tree at %s' % os.path.relpath(STAGE, ROOT))
    else:
        print('staging the 5.0.2 tree once...')
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'offline502.py'), '--stage'],
                           cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout + r.stderr)
            print('REFUSING: the 5.0.2 tree would not stage.')
            return 2
    if plan is None:
        plan = os.path.join(outdir, 'PLAN.CSV')
        # THE SKIP LIST IS READ OUT OF soakplan.HW_SKIP, never typed. soakplan.py --emit-csv does NOT skip
        # by default -- it emits all 42 vectors, 1806 cells -- and the skip is applied BEFORE the shuffle,
        # so a plan with a different skip list gives every surviving cell another vector's amplitude,
        # offset and wait. Naming two of the three by hand is what made two overnight hardware runs
        # incomparable with the archive; reading the tuple is what stops that recurring here.
        sys.path.insert(0, os.path.join(ROOT, 'tools'))
        import soakplan
        skip = ','.join(soakplan.HW_SKIP)
        print('emitting a plan, skipping %s (from soakplan.HW_SKIP)...' % skip)
        with open(plan, 'w') as fh:
            p = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'soakplan.py'),
                                '--emit-csv', '--iteration', '1', '--skip-vectors', skip],
                               cwd=ROOT, stdout=fh, text=True)
        if p.returncode != 0:
            print('REFUSING: soakplan would not emit a plan.')
            return 2
    plan = os.path.abspath(plan)

    # MAKING THE ENVELOPE ACTIVE, WHICH IT IS NOT ON A PLAN soakplan EMITS. soakplan refuses any pair with
    # |OFST| + AMP/2 past SDG_ENV_V, so a stock plan has 0 of 11739 cells outside it -- max exactly
    # 10.0000 V -- and GEN_ENVELOPE never fires. That is correct for a plan meant to reach the wire intact,
    # and useless for testing the recentring law.
    #
    # SO THE OFFSETS ARE INFLATED HERE, NOT THE ENVELOPE NARROWED. Lowering clamp_v below 10 V would also
    # make the code fire, while modelling a generator this bench does not have. Inflating the commanded
    # offset reproduces a condition the archive really ran: over the 100-lap soak's 133 301 cells, 50.8 %
    # commanded a pair outside the envelope and 12.3 % arrived recentred across ground. The default
    # fraction is that 50.8 %.
    #
    # EXPECT THE FAIL RATE TO RISE SHARPLY ON THOSE CELLS, and that is the finding, not a fault: a band
    # recentred across ground is read as RS-232 and marked at the negative level, which measured 9.55x the
    # byte failures on hardware against a rate-failure control of 0.97x.
    global STRESS
    frac = float(opt(argv, '--stress-envelope', '0.508'))
    STRESS = frac > 0
    if frac > 0:
        src = open(plan).read().splitlines()
        out, nstress, ncells = [], 0, 0
        for ln in src:
            if ln[:1] in ('#', 'i') or ln.strip() == '':
                out.append(ln)
                continue
            ncells += 1
            f = ln.split(',')
            amp, ofst = float(f[6]), float(f[7])
            # DETERMINISTIC, and spread over the lap rather than taken as a block: every 1/frac-th cell, so
            # the stressed cells fall across all 39 vectors instead of the first few.
            if frac >= 1.0 or (ncells % max(int(round(1.0 / frac)), 1)) == 0:
                room = 10.0 - amp / 2.0
                want = (10.0 - amp / 2.0) + 2.0 + amp / 4.0     # comfortably past the envelope
                if ofst < 0:
                    want = -want
                if abs(want) > abs(room):
                    f[7] = '%.3f' % want
                    nstress += 1
            out.append(','.join(f))
        stressed = os.path.join(outdir, 'PLAN_STRESS.CSV')
        with open(stressed, 'w') as fh:
            fh.write('\n'.join(out) + '\n')
        plan = stressed
        print('envelope stress: %d of %d cell(s) (%.1f %%) now command a pair outside +/-%.1f V'
              % (nstress, ncells, 100.0 * nstress / max(ncells, 1), 10.0))

    ncell = sum(1 for ln in open(plan) if ln[:1] not in ('#', 'i'))
    print('plan %s, %d cell(s) a lap, %d worker(s), 5.0.2 at %s'
          % (plan, ncell, workers, os.path.relpath(LUA502, ROOT)))

    t0 = time.time()
    deadline = t0 + hours * 3600 if hours > 0 else None
    lap, done, alarms = 0, 0, []
    running = {}
    log = open(os.path.join(outdir, 'soak.log'), 'w')

    def launch(n):
        rec = os.path.join(outdir, 'rec%d.csv' % (n % (2 * workers)))
        # ONE SEED PER LAP, and never 0 or a multiple of the Park-Miller modulus -- SRC_PHASE normalises
        # those, but keeping them out of the sequence keeps the log honest about what was drawn.
        seed = seed0 + n
        cmd = [LUA502, 'tools/offline_bench.lua', '--plan', plan, '--out', rec,
               '--iterations', '1', '--phase-seed', str(seed)]
        # RECONSTRUCTION IS STATED EXPLICITLY IN BOTH ARMS, never left to the default, because the whole
        # point of this pass-through is a paired A/B on identical seeds: an unlabelled arm cannot be
        # compared with anything later, and the default is expected to move once the A/B settles.
        cmd += ['--interp'] if interp else ['--no-interp']
        cmd += ['--truefs'] if truefs else ['--no-truefs']
        cmd += ['--frontend'] if frontend else ['--no-frontend']
        fh = open(os.path.join(outdir, 'w%d.out' % (n % (2 * workers))), 'w')
        return {'p': subprocess.Popen(cmd, cwd=STAGE, stdout=fh, stderr=subprocess.STDOUT),
                'rec': rec, 'seed': seed, 'fh': fh, 'n': n}

    def harvest(job):
        job['fh'].close()
        out = open(os.path.join(os.path.dirname(job['rec']),
                                'w%d.out' % (job['n'] % (2 * workers))), errors='replace').read()
        bad = []
        if job['p'].returncode != 0:
            bad.append('crash rc=%s' % job['p'].returncode)
        if not os.path.exists(job['rec']) or os.path.getsize(job['rec']) == 0:
            bad.append('no record written')
            return bad, None
        # THE ENVELOPE COUNT IS CHECKED IN WHICHEVER DIRECTION THE RUN EXPECTS. On a stock plan zero is
        # right and anything else means the conditions moved; on a stress run zero means the stressing
        # silently did nothing and the run tested the opposite of what it claims to.
        for line in out.splitlines():
            if line.startswith('envelope:'):
                zero = line.startswith('envelope: 0 ')
                if STRESS and zero:
                    bad.append('envelope never fired on a stress run')
                elif not STRESS and not zero:
                    bad.append(line.strip())
        j = subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'judge_bench.py'), job['rec']],
                           cwd=ROOT, capture_output=True, text=True)
        jt = j.stdout
        stats = {}
        for key, label in (('raised', 'raised'), ('no decode', 'nodecode'),
                           ('inconclusive', 'inconclusive'), ('FAIL', 'fail')):
            for line in jt.splitlines():
                s = line.strip()
                if s.startswith(key):
                    parts = s.split()
                    for w in parts[1:]:
                        if w.isdigit():
                            stats[label] = int(w)
                            break
                    break
        # THRESHOLDS FROM A MEASURED BASELINE, NOT FROM ZERO. A paired A/B on this plan -- the same lap with
        # the phase draw off and on -- gives:
        #
        #     phase off   pass 1651  FAIL 25  inconclusive 0  no decode 1
        #     phase on    pass 1645  FAIL 30  inconclusive 1  no decode 1
        #
        # So `no decode 1` is a property of the harness and this plan, present with the phase draw OFF, and
        # alarming on it fired on every lap of the first smoke -- a harness inventing a failure, which is
        # the thing this project guards hardest against. The extra FAILs and the occasional inconclusive
        # with phase on are physically right rather than pessimistic: a capture beginning mid-payload is
        # what hardware does, and mid-byte starts are on record at roughly 1 in 8.
        #
        # `raised` STAYS AT ZERO, because that is a Lua error reaching the harness and is always a defect.
        for k, base in (('raised', 0), ('nodecode', NODECODE_BASE), ('inconclusive', INCONC_BASE)):
            if stats.get(k, 0) > base:
                bad.append('%s=%d (over %d)' % (k, stats[k], base))
        if 'nobytes' in jt and 'nobytes 0' not in jt:
            bad.append('nobytes seen')
        return bad, stats

    while True:
        while len(running) < workers and (deadline is None or time.time() < deadline) \
                and (laps == 0 or lap < laps):
            lap += 1
            running[lap] = launch(lap)
        if not running:
            break
        time.sleep(0.4)
        for n in list(running):
            job = running[n]
            if job['p'].poll() is None:
                continue
            del running[n]
            bad, stats = harvest(job)
            done += 1
            fr = (stats or {}).get('fail', -1)
            line = 'lap %5d seed %-9d fail %-5s %s' % (job['n'], job['seed'], fr,
                                                       ('ALARM ' + '; '.join(bad)) if bad else 'ok')
            log.write(line + '\n')
            log.flush()
            if bad:
                alarms.append(line)
            if done % 25 == 0 or bad:
                el = time.time() - t0
                print('  %6.2f h  %5d lap(s)  %9d cell(s)  %d alarm(s)  %s'
                      % (el / 3600.0, done, done * ncell, len(alarms), line))
                sys.stdout.flush()
        if (deadline is not None and time.time() >= deadline) or (laps and lap >= laps):
            if not running:
                break

    el = time.time() - t0
    print('=== soak_offline_bench done: %.2f h, %d lap(s), %d cell(s), %d alarm(s) ==='
          % (el / 3600.0, done, done * ncell, len(alarms)))
    for a in alarms[:20]:
        print('  ' + a)
    log.close()
    return 1 if alarms else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

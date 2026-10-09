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
    tree changed    the staged 5.0.2 tree moved mid-run, so the lap read a tree that is no longer
                    there. Void, not a result -- and silent before this alarm existed, because the
                    damage shows up only as a LOWER fail count on a lap that still logs `ok`.

Read the summary's per-lap FAIL RATE against the baseline it prints, not against zero, and read the
INCONC_BASE and NODECODE_BASELINE blocks below before calling anything in the log a regression.
"""

import fcntl
import hashlib
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA502 = os.path.join(ROOT, 'out', 'lua502', 'bin', 'lua')
STAGE = os.path.join(ROOT, 'out', 'lua502src')


def opt(argv, name, default):
    return argv[argv.index(name) + 1] if name in argv else default


def tree_fingerprint():
    """A signature of the staged tree, so a rebuild underneath a running soak cannot pass as a result.

    THE LOCK IN offline502.stage() IS THE PREVENTION AND THIS IS THE DETECTION, because only one of
    those two survives a hand-rolled `rm -rf` or an override. Every entry contributes its path, kind,
    size and mtime_ns; symlinks contribute their target and whether it still resolves, since the
    failure that cost 14 laps was the out/vectors SYMLINK going away rather than any real file changing.

    Cheap enough to run every lap: 16 real files, 133 symlinks and 4 directories, against a lap that
    takes about a minute.
    """
    h = hashlib.sha256()
    if not os.path.isdir(STAGE):
        return 'MISSING'
    for root, dirs, files in os.walk(STAGE, followlinks=False):
        # EXCLUDED FOR THE SAME REASON shadow() EXCLUDES IT. A worker that popens python from cwd=STAGE
        # -- which the bench engine is documented to do for soakplan.py -- writes bytecode beside the
        # symlinked source, inside the tree. That is the harness's own footprint, not a rebuild, and
        # alarming on it would be this gate inventing a failure.
        dirs[:] = sorted(d for d in dirs if d != '__pycache__')
        for name in dirs + sorted(f for f in files if not f.endswith('.pyc')):
            p = os.path.join(root, name)
            rel = os.path.relpath(p, STAGE)
            try:
                st = os.lstat(p)
            except OSError:
                h.update(('%s|GONE\n' % rel).encode())
                continue
            if os.path.islink(p):
                h.update(('%s|link|%s|%d\n'
                          % (rel, os.readlink(p), os.path.exists(p))).encode())
            elif os.path.isdir(p):
                h.update(('%s|dir\n' % rel).encode())
            else:
                h.update(('%s|file|%d|%d\n' % (rel, st.st_size, st.st_mtime_ns)).encode())
    return h.hexdigest()[:16]


# Set once from --stress-envelope, read by harvest() to know which way to check the envelope count.
STRESS = False
# Measured on this plan with the phase draw OFF, so they are the harness's own floor and not a target.
#
# THIS GATE HAS A KNOWN, QUANTIFIED FALSE-ALARM RATE: DO NOT CHASE IT. Over 4931 laps it fired five
# times, at 3, 3, 3, 3 and 4 inconclusive. Fitting a Poisson to that exceedance gives
# lambda = 0.1915 inconclusive/lap, hence P(X > 2) = 1.014e-3 and 4931 x 1.014e-3 = 5.00 expected
# against five observed. The same lambda, fitted only to the exceedance, then predicts three things it
# was not fitted to: the 4-to-1 split of threes to fours, the phase-off arm's single observation of 1,
# and an earlier run's 3 breaches in 1529 laps. Those laps were otherwise unremarkable -- mean FAIL
# 23.20 against the run's 23.461 -- and uniform in time. Raising the threshold to silence them would
# cost the gate its sensitivity to a real step; five lines in a 4931-lap log is the designed price.
INCONC_BASE = 2

# ---------------- the no-decode alarm ----------------
# IT ALARMS ON IDENTITY, NOT ON A COUNT, because the count is permanently spoken for. `v92` cell 1177
# fails to decode in EVERY lap -- 20 of 20 with the new stimulus models on and 20 of 20 with them off, so
# it predates all of them, and the bench has that no-decode too. A per-lap threshold of "more than 1"
# therefore fires whenever anything else appears at all: measured at 27 of 101 laps on a known-good run.
# A gate that flags a known-good condition a quarter of the time is noise, and noise is how a real step
# change gets scrolled past.
#
# THIS IS A TRADE, NOT A STRICT IMPROVEMENT, and saying otherwise would be a lie in a comment. The old
# count test alarms when any TWO cells fail together; this one does not, so N already-known identities
# failing at once is a case the old test caught and this one misses. NODECODE_CEIL is the partial answer.
# What this buys instead is that ONE new identity is enough, where the old test needed two, and that the
# alarm NAMES the cell instead of printing a number nobody can act on.
#
# THE BASELINE IS DECLARED HERE, NOT LEARNED FROM THE RUN BEING JUDGED. Learning it over the first few
# laps was the first attempt and it is unsound: a defect present from lap 1 joins the baseline and is
# excused for ever, which is precisely the case the old count test caught. Worse, it prints at 100 % of
# laps and so looks exactly like the legitimate entry. Every addition here needs evidence from a run OTHER
# than the one being judged, and the evidence goes in the comment beside it.
NODECODE_BASELINE = frozenset((
    # 20 of 20 laps with --aperture, 20 of 20 with --no-aperture, and 28 of 28 in a third run at other
    # seeds, and 4931 of 4931 at 100.0 % in the long run. Hardware has this no-decode as well; it is the
    # one --interp wrongly deletes. Its `why` is `dec: no frame fits a 7.7-7.8 sample bit time`, which is
    # a DIFFERENT mechanism from the v90/v94 band below -- that distinction is the whole reason this set
    # has one member and not forty.
    'v92/1177',
))
# THE v90/v94 BAND IS ONE MECHANISM, AND IT IS MEASURED. Every band row's `why` reads
# `acq: swing only 0.000 V`: v90 is SER_Blocks256B_8N1_x10 and v94 is SER_Blocks512B_8N1_x10, both carry
# inter-block dead regions, and a capture window landing inside one sees a flat line, so acquisition
# refuses. Per-cell probability is the margin between window length and dead-region length under the
# phase draw. That margin does NOT reduce to a plan column -- Spearman(rate, bit-times in window) is
# +0.166 (p=0.28) on v90 and +0.010 (p=0.95) on v94, and baud, kind and amplitude all fail too.
#
# SO DO NOT ADD BAND MEMBERS HERE, ONE AT A TIME OR AT ALL. Membership is a function of LAP COUNT, not
# of health: 14 identities were known at 251 laps and 38 at 4931, and summing (1-(1-p_i)^L) over the
# measured rates predicts 13.50 +/- 1.64 visible at L=251 (14 seen) and 23.11 +/- 2.40 at L=1529 (24
# seen). A cell at 0.02 %/lap is invisible below ~2000 laps. Both vectors have 43 cells and 19 of each
# are members, so the extent is the whole vector: v90 603-645, v94 1377-1419 (v94's extent has never
# widened). `v94/1384` was seen only in the 1529-lap run, so the union over both is 39 cells. The
# frequency spectrum is a smooth 240x continuum from 4.8 % to 0.02 % with no gap, which is what one
# mechanism with a per-cell margin looks like and not what 38 faults look like.
#
# IF A GATE IS EVER WANTED ON THIS, GATE THE AGGREGATE RATE: 1237 events over 424 066 v90+v94 cell-laps
# = 0.2917 %. Envelope stress multiplies it 1.608x (z=+8.25) while hitting only even-numbered cell
# indices, so 23 of the 38 members are unstressed -- the stress modulates the mechanism rather than
# causing it, and stressed and unstressed runs are not interchangeable on this band.
# A mass event, in IDENTITIES not rows: many already-known cells failing together is the failure identity
# cannot see, so it needs its own trigger. Set above the 6 distinct cells a healthy long run shows.
NODECODE_CEIL = 8


# Column order of an R row, as bench/bench_run.tsp writes it.
_RCOLS = ('R,iter,cell,vid,baud,kind,amp_vpp,ofst_v,srate,wait_ms,fs,sa_bit,ran,read_baud,fmt,nf,'
          'ngood,nbad,nflag,headsusp,snapped,snapfirm,why,hex').split(',')
_R_VID, _R_CELL, _R_NF = _RCOLS.index('vid'), _RCOLS.index('cell'), _RCOLS.index('nf')
_R_RAN, _R_WHY = _RCOLS.index('ran'), _RCOLS.index('why')


def nodecode_cells(recpath):
    """No-decode cells in one lap -> (set of 'vid/cell', row count, total R rows).

    THE TEST IS THE JUDGE'S TEST, copied deliberately rather than approximated. judge_bench counts a
    no-decode when the row did NOT run, its `why` is not an SDG failure, and the vector's class is not
    'loud' -- and it checks SDG first, so an SDG failure is never a no-decode whatever else is true.
    An earlier version of this function tested `nf == 0` instead and agreed with the judge exactly, 36
    against 36, on a window that happened to contain ZERO SDG failures: an equivalence that holds only
    while the discriminating case never occurs is not an equivalence, and the sample could not see it.
    The class comes from soakplan.expect_for(), the same oracle the judge calls, so 'exact' remains the
    default for a vid absent from the table.

    The TOTAL row count is returned so the caller can check the record is a whole lap. Record files are
    reused every 2*workers laps, which does not guarantee a slow lap has finished with its slot before the
    next owner truncates it -- and a partial or mixed record would yield wrong identities that the
    cross-check against the judge cannot catch, because the judge reads the same file.
    """
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import soakplan
    cells, rows, total = set(), 0, 0
    try:
        fh = open(recpath, errors='replace')
    except OSError:
        return cells, rows, total
    with fh:
        for ln in fh:
            if not ln.startswith('R,'):
                continue
            f = ln.rstrip('\n').split(',')
            if len(f) < len(_RCOLS):
                continue
            total += 1
            why = f[_R_WHY]
            if why.startswith('SDG:'):
                continue
            if f[_R_RAN] == 'y':
                continue
            if soakplan.expect_for(f[_R_VID]) == 'loud':
                continue
            cells.add('%s/%s' % (f[_R_VID], f[_R_CELL]))
            rows += 1
    return cells, rows, total


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
    # THE DIGITISER'S ACTUAL RATE. ON unless refused, matching gen_serial's default. Read as `--no-X not
    # in argv` rather than `--X in argv`: with the default ON, presence-only would make the flag
    # unturnable-off and every arm of a paired A/B identical while claiming to differ.
    truefs = '--no-truefs' not in argv
    # THE DMM'S FRONT END. Off unless asked, matching gen_serial's default.
    frontend = '--frontend' in argv
    # THE DIGITISER'S APERTURE AS AN INTEGRAL, 0.85 us. ON unless refused, matching gen_serial's default.
    aperture = '--no-aperture' not in argv
    # A SUB-SAMPLE CAPTURE ORIGIN. ON unless refused, matching gen_serial's default.
    fracorigin = '--no-fracorigin' not in argv
    # --interp AND --frontend BOTH IMPLY --no-aperture, resolved HERE rather than at the point the command is built: the
    # aperture supersedes interpolation and offline_bench refuses the pair rather than logging a
    # reconstruction that never ran, so asking for the source model takes the instrument model off with
    # it. Doing this inside the launcher would make `aperture` a function-local and leave it unbound on
    # every call where interp is false.
    if interp or frontend:
        aperture = False
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

    # HOLD THE TREE SHARED FOR THE WHOLE RUN, so offline502.stage() refuses to rebuild it underneath
    # us. Shared and not exclusive, because several pools legitimately share one tree with --no-stage;
    # the lock only has to exclude the WRITER. Keep `tree_lock` referenced until the run ends -- the
    # lock dies with the handle, so letting it fall out of scope silently unlocks the tree.
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import offline502
    tree_lock = offline502.stage_lock(fcntl.LOCK_SH)
    if tree_lock is None:
        print('REFUSING: %s is locked exclusively -- a stage is running right now.'
              % os.path.relpath(STAGE, ROOT))
        return 2
    fp0 = tree_fingerprint()
    print('staged tree held, fingerprint %s' % fp0)

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
    # `flagged` latches an identity after its first alarm; `seen` tallies every lap it appeared in, so the
    # summary can say whether something that alarmed once is persistent or a one-off.
    ND = {'flagged': set(), 'seen': {}}
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
        cmd += ['--aperture'] if aperture else ['--no-aperture']
        cmd += ['--fracorigin'] if fracorigin else ['--no-fracorigin']
        fh = open(os.path.join(outdir, 'w%d.out' % (n % (2 * workers))), 'w')
        return {'p': subprocess.Popen(cmd, cwd=STAGE, stdout=fh, stderr=subprocess.STDOUT),
                'rec': rec, 'seed': seed, 'fh': fh, 'n': n}

    def harvest(job):
        job['fh'].close()
        out = open(os.path.join(os.path.dirname(job['rec']),
                                'w%d.out' % (job['n'] % (2 * workers))), errors='replace').read()
        bad = []
        # CHECKED FIRST AND ALWAYS REPORTED, before the early return below can swallow it. If the tree
        # moved, every other verdict in this lap is about a tree that is no longer there -- and the
        # historical failure logged `ok` with a merely LOWER fail count, so there is no symptom to
        # notice later. The one in 2026-09 cost 14 laps and a month later read as a p=0.047 regression.
        tree_ok = tree_fingerprint() == fp0
        if not tree_ok:
            bad.append('STAGED TREE CHANGED MID-RUN: this lap is void, not a result')
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
        # A RECOGNISABLE SUMMARY IS THE TEST, NOT THE EXIT CODE. judge_bench returns 1 whenever it found
        # any BAD cell -- that is its VERDICT, and a healthy lap of this plan always has some -- and its
        # REFUSING paths raise SystemExit, which also exits 1. So the return code cannot tell a verdict
        # from a refusal, and requiring rc == 0 made every single lap alarm. What only a completed judge
        # produces is the trailing 'N BAD of M judged' line, so that is what is required here.
        #
        # WHY IT IS CHECKED AT ALL: without it the lap failed OPEN. A refused or crashed judge leaves
        # `nodecode` absent from stats, the cross-check below is then skipped for want of a number to
        # compare against, and the lap is reported ok on the strength of a parse nothing corroborated.
        judged_ok = ('BAD of' in jt) and 'Traceback' not in (j.stderr or '')
        if not judged_ok:
            tailmsg = (j.stderr or jt).strip()
            bad.append('judge unusable: rc=%s %s'
                       % (j.returncode,
                          tailmsg.splitlines()[-1][:120] if tailmsg else 'no output'))
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
        # THRESHOLDS FROM A MEASURED BASELINE, NOT FROM ZERO.
        #
        # THE PHASE-ON ARM, from 4931 laps on this plan (2026-10-08, 8 269 287 cells, stress at the
        # 0.508 default). Quote THIS, not a single lap:
        #
        #     FAIL per lap   mean 23.4608  95% CI [23.3844, 23.5371]   sd 2.7365
        #                    median 23  IQR 22-25  central 95% 18-29  full range 12-33
        #     as a cell rate 1.3990 %  [1.3944, 1.4035]
        #     no decode      1 identity in every lap (v92/1177), plus the v90/v94 band below
        #
        # THE PHASE-OFF ARM IS STILL ONE LAP AND IS NOT ESTABLISHED. It measured `pass 1651 FAIL 25
        # inconclusive 0 no decode 1`, and no phase-off run exists on disk to replace it -- every soak
        # directory reports `capture phase random`. Note 25 sits ABOVE the phase-on MEAN of 23.46, so the
        # "the phase draw adds 5 FAILs" reading that the original pair invited is not supported by
        # anything measured; the two single draws are ordered the wrong way round for it.
        #
        # THE OLD PHASE-ON FIGURE OF `FAIL 30` WAS A SINGLE DRAW FROM THE UPPER TAIL -- the 99.3rd
        # percentile, +2.39 sd, P(X >= 30) = 1.68 %. It is kept here only as a warning: any eyeball
        # comparison against it reads a perfectly healthy run as an improvement.
        #
        # `no decode 1` is a property of the harness and this plan, present with the phase draw OFF, and
        # alarming on it fired on every lap of the first smoke -- a harness inventing a failure, which is
        # the thing this project guards hardest against. The occasional inconclusive with phase on is
        # physically right rather than pessimistic: a capture beginning mid-payload is what hardware
        # does, and mid-byte starts are on record at roughly 1 in 8.
        #
        # DO NOT TEST THE FAIL COUNT WITH A BINOMIAL. It is UNDER-dispersed 3.09x in variance -- observed
        # sd 2.7365 against the binomial's 4.8096 at n=1677, p=0.0140, dispersion chi2 1595.9 on df=4930
        # -- because most of a lap's failures are the `loud` vectors refusing deterministically and the
        # 1677 cells are not exchangeable. A binomial test is therefore 1.76x too lenient in the standard
        # error. In the other direction, finely-binned homogeneity tests OVER-reject, because `seed0 + n`
        # feeds consecutive integers to Park-Miller and adjacent laps share near-identical opening draws
        # (Ljung-Box Q=24.58 on df=8, p=0.0018; variance inflation 1.39-1.76). Use the empirical variance,
        # and for a trend regress block means against their own scatter.
        #
        # `raised` STAYS AT ZERO, because that is a Lua error reaching the harness and is always a defect.
        for k, base in (('raised', 0), ('inconclusive', INCONC_BASE)):
            if stats.get(k, 0) > base:
                bad.append('%s=%d (over %d)' % (k, stats[k], base))

        # NO-DECODE, BY IDENTITY. See the NODECODE_BASELINE block above for why this is not a count test.
        cells, ndrows, totrows = nodecode_cells(job['rec'])
        # A WHOLE LAP OR NOTHING. A truncated or mixed record gives wrong identities, and the cross-check
        # against the judge cannot see it because the judge reads the same bytes.
        if totrows != ncell:
            bad.append('record has %d result row(s), expected %d -- partial or reused slot'
                       % (totrows, ncell))
        # THE SHORTCUT IS CROSS-CHECKED AGAINST THE JUDGE EVERY LAP. Reading the record directly is what
        # makes per-cell detail affordable, but it is a SECOND implementation of "no decode" and two
        # implementations is exactly the failure this repo keeps writing comments about. If they diverge,
        # the divergence itself is the alarm -- silently trusting the faster one is how a gate stops
        # measuring what it claims to.
        agree = judged_ok and stats.get('nodecode') is not None and ndrows == stats['nodecode']
        if judged_ok and not agree:
            bad.append('nodecode accounting disagrees: %d row(s) here vs judge %s'
                       % (ndrows, stats.get('nodecode')))
        # NOTHING IS LEARNED FROM A LAP WE CANNOT ACCOUNT FOR. If the two counts disagree, or the judge
        # was unusable, or the record was not a whole lap, or the staged tree moved under the worker,
        # then these identities are not trustworthy -- so they must not be tallied and above all must
        # not silence a later alarm by latching an identity out of a lap that did not really run it.
        if tree_ok and agree and totrows == ncell:
            for c in cells:
                ND['seen'][c] = ND['seen'].get(c, 0) + 1
            # ONE ALARM PER IDENTITY PER RUN. Reporting the same cell as NEW on every lap thereafter is
            # what made the first attempt as noisy as the count test it replaced -- and worse, repeats
            # crowd a genuinely different identity out of the truncated summary list. A 7 % cell would
            # never have been in a 3-lap learned baseline anyway (19.6 % chance of appearing), so
            # latching is what actually removes the noise; the tally carries the frequency.
            new = cells - NODECODE_BASELINE - ND['flagged']
            if new:
                ND['flagged'] |= new
                bad.append('nodecode NEW cell(s): %s' % ' '.join(sorted(new)))
            # IDENTITIES, not rows: 'many known cells failed at once' is a statement about how many
            # DISTINCT things broke. A row ceiling would read nine iterations of one cell as a mass event.
            if len(cells) > NODECODE_CEIL:
                bad.append('nodecode=%d distinct cell(s) (mass event, ceiling %d)'
                           % (len(cells), NODECODE_CEIL))
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
    # WHAT WAS EXCUSED AND WHAT WAS SEEN, ALWAYS PRINTED, because the baseline is a declared constant and
    # the only way to notice it has gone stale is to see the frequencies beside it.
    if ND['seen']:
        print('  no-decode cells seen, %d distinct (baseline entries are excused by NODECODE_BASELINE):'
              % len(ND['seen']))
        for c in sorted(ND['seen'], key=lambda k: (-ND['seen'][k], k)):
            n = ND['seen'][c]
            tag = 'BASELINE' if c in NODECODE_BASELINE else 'alarmed'
            note = ''
            if c in NODECODE_BASELINE and n < done * 0.9:
                note = '   <- STALE BASELINE: excused but not persistent'
            print('    %-18s %5d of %d lap(s)  %5.1f %%  %-8s%s'
                  % (c, n, done, 100.0 * n / max(1, done), tag, note))
    else:
        print('  no-decode: none seen in any lap')
    for a in alarms[:20]:
        print('  ' + a)
    log.close()
    return 1 if alarms else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

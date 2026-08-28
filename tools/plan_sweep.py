#!/usr/bin/env python3
"""Run tools/sweep_plan.lua -- the offline twin of the soak's plan suite -- sharded, ratcheted, over
as many iterations as asked for.

WHAT THIS IS THE TWIN OF, AND WHY THAT MATTERS MORE THAN THE OTHER OFFLINE SUITES. Every other offline
harness names its own sample rate and renders at a whole number of samples per bit. This one replays
the SOAK'S OWN PLAN: the drawn baud rates, the drawn amplitude and offset, the drawn wait, the arb file
from out/vectors/ resampled to pick_fs(baud) exactly as the instrument digitises it. So sa/bit is
fractional the way the bench's is -- 8.68, 13.19, 8.06 -- and the edge is the arb's own edge resampled
rather than a fixed number of samples. Those two properties are what #124 records as the offline
twin's blind spots, and this file does not have them. A hardware lap is ~2.85 h; a lap here is ~4 s
across the cores.

    python3 tools/plan_sweep.py                          # iteration 1, 1 offset -- the ratcheted gate
    python3 tools/plan_sweep.py --iterations 20 --offsets 8
    python3 tools/plan_sweep.py --iteration 7 --offsets 16 --quiet
    python3 tools/plan_sweep.py --skip-vectors ""         # all 41 vectors: NOT the lap the bench runs

THE SKIPPED SET IS PART OF THE PLAN, not a filter on it, and it defaults to the bench's own v95,v96 for
that reason -- see DEFAULT_SKIP. soakplan applies it BEFORE the shuffle, so dropping two names moves
every remaining vector's index and that index keys the amplitude, the offset and the wait of every cell.

THE PLAN IS ALWAYS REGENERATED, NEVER READ FROM DISK, and that is a correctness rule rather than a
convenience. A plan file is a snapshot of the DRAW, and the draw changes whenever soakplan's
constraints do -- a plan emitted before the ground-straddle constraint reports 23 BAD at iteration 1
where the current draw gives 11, and the extra twelve are the stimulus rather than the app (#108).
Nothing in a plan's name says which rules drew it, so a file on disk silently describes a DIFFERENT
EXPERIMENT from the one the soak runs. Regenerating costs 0.4 s and makes that impossible.

EXIT 1 IF a decode RAISED, if any shard printed no summary, or if a ratcheted count rose. A raise is
never the right answer at any placement, so it gates unconditionally; the rest are known-but-unfixed
defects (#46, #125) and are bounded rather than demanded to be zero.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

import soakplan as SP                                                          # noqa: E402

PLANDIR = os.path.join(ROOT, 'out', 'plans', 'auto')

# THE SKIP LIST IS PART OF THE PLAN, and the default is the bench's own so the twin replays the lap
# that is actually run. README.md documents it:
#   python3 tools/soak.py --hours 17 --suites formats,plan --skip-vectors v95,v96
#
# WHY THE DEFAULT IS NOT EMPTY. soakplan.plan_order shuffles the list it is handed and every per-cell
# wait, amplitude and offset is keyed on a vector's POSITION in that shuffle -- so a twin that emits the
# 41-vector plan for a 39-vector lap does not test two extra vectors, it plays a DIFFERENT vector's
# amplitude, offset and capture phase in every single cell. Measured against the bench's own per-cell
# record for iteration 1, all 1677 cells disagreed:
#   python3 tools/soakplan.py --iteration 1 --skip-vectors v95,v96 --check-log <a lap log>
# An empty default is therefore the wrong experiment by default, which is the one thing an offline twin
# must not be. Both are ratcheted, so `--skip-vectors ""` is still a gated configuration.
DEFAULT_SKIP = ','.join(SP.HW_SKIP)

# The counters sweep_plan.lua prints on its PLAN line, in the order they appear there.
KEYS = ['cells', 'badcells', 'badall', 'points', 'ok', 'bad', 'skip',
        'raised', 'nobytes', 'norate', 'rate', 'flags', 'bytes', 'bleed', 'bleedworst',
        'r46b', 'rfit1', 'rstdC', 'rother', 'loudquiet', 'loudmiss', 'loudmissworst',
        # `label` and its lr* split are captures whose bytes were accepted and whose REPORTED rate is
        # wrong. The leading \b in parse() is what keeps 'r46b' from also matching 'lr46b': 'l' and 'r'
        # are both word characters, so there is no boundary between them and the two stay distinct.
        'label', 'lr46b', 'lrfit1', 'lrstdC', 'lrother']
LABEL_ROUTES = ['lr46b', 'lrfit1', 'lrstdC', 'lrother']
# THE FOUR ROUTES SUBDIVIDE `rate` AND MUST SUM TO IT. Issue #46 was one counter over three
# mechanisms -- a snapped harmonic, sig_fit's second fixed point, and a drift into a neighbouring
# standard rate's basin -- with three different fixes, so a single number could say it moved but never
# which one moved. sweep_plan.lua reconciles per shard; this reconciles the totals, because a
# subdivision that does not add up invites exactly the confident wrong reading it was built to remove.
ROUTES = ['r46b', 'rfit1', 'rstdC', 'rother']
# bleedworst is a MAXIMUM across shards, not a sum: totalling worst-cases would report a number no
# single point ever produced.
MAXKEYS = frozenset(['bleedworst', 'loudmissworst'])
LINE = re.compile(r'^PLAN (\d+)/(\d+) iteration (\d+): (.*)$')

# RATCHETS, KEYED ON (iteration, offsets, skip). Every baseline here is a measurement on a freshly drawn
# plan and is reproducible run to run; re-measure with --no-ratchet rather than editing one from memory.
#
# THE SKIP IS IN THE KEY because it is not a filter on the results, it is a different draw: dropping two
# names reshuffles the order every wait, amplitude and offset is keyed on, so a baseline measured over 41
# vectors describes no run over 39. An unmeasured combination is SKIPPED rather than gated wrongly.
#
# WHY A RATCHET AND NOT A TARGET, same reasoning as tools/sweep_all.py: these count defects that are
# UNDERSTOOD AND DELIBERATELY UNFIXED, so demanding zero would fail the gate on a known state, and
# printing them unbounded lets them grow unnoticed -- which is exactly how #46 sat at 148 of 3936 in
# the phase sweep for weeks while its issue said the offline twin could not reproduce it.
#
# ONLY AT THE CONFIGURATION EACH BASELINE DESCRIBES. A different iteration draws different rates, waits
# and amplitudes, and a different offset count draws different capture phases, so a baseline from one
# configuration does not describe another and the ratchet is SKIPPED rather than applied wrongly.
#
# `bad` is the point count and `badcells` the number of (vector, rate) cells with at least one bad
# point. Both are bounded because they move independently: a defect that spreads to new cells and one
# that becomes more likely at a cell it already affected are different regressions.
#
# WHAT THE OFFSET AXIS IS WORTH, measured rather than argued: one capture per cell finds a handful of
# affected cells, eight find an order of magnitude more, and the handful were never the interesting
# number -- they were whichever phase the plan's wait happened to draw.
#
# AND WHAT badcells IS NOT. It is a UNION over the capture phases -- at least one of the eight failed --
# so it is NOT the number to set beside a hardware lap, which takes one capture per cell and asks once.
# Measured against soak lap 1: 65 cells fail here and passed on the bench, and NONE of them fails at all
# eight phases. `badall` is the intersection, and it is bounded here for that reason: it counts the
# defects no capture placement escapes, which is a far stronger claim than badcells makes. It is
# ratcheted like every other counter rather than demanded to be zero.
# nobytes IS ZERO AT EVERY CONFIGURATION BELOW, and it is a bound rather than an absence: the class had
# 105-106 points at 8 offsets until ua_run stopped choosing a frame anchor outside the window it is
# scoring. Every one of them was v90 or v94 and no other vector, so a single number holds the whole
# family -- and if the anchor bound is ever lost, this is the counter that says so first.
#
# skip 1 AND judged ONE LOWER AT 8 OFFSETS, at the two configurations that reach it, is the price of
# that fix and is named here rather than left as a puzzle: v94 at 630 Bd digitises at 15.87 sa/bit, so
# a 20000-sample capture holds 126 bytes and the 128-byte 0x55 block is longer than the whole window.
# That point used to decode NOTHING and count as bad; it now returns 5 bytes, and 5 minus the app's own
# 3-byte head allowance leaves too few for judge() to compare. The app improved and the harness lost
# the ability to score it, which is exactly what `skip` is bounded to make visible.
RATCHET = {
    (1, 1, ()): {'bad': 14, 'badcells': 14, 'badall': 14, 'rate': 13, 'flags': 0, 'bytes': 1,
                 'nobytes': 0, 'bleed': 211, 'skip': 0, 'judged': 1763, 'loudquiet': 9,
                 'loudmiss': 131, 'label': 3},
    (1, 8, ()): {'bad': 110, 'badcells': 20, 'badall': 11, 'rate': 106, 'flags': 0, 'bytes': 4,
                 'nobytes': 0, 'bleed': 1205, 'skip': 1, 'judged': 14103, 'loudquiet': 53,
                 'loudmiss': 656, 'label': 24},
    # THE TWO CONFIGURATIONS A BENCH LAP CAN ACTUALLY BE COMPARED WITH, because every hardware soak
    # skips v95 and v96 -- v96 wedges the generator at vector 33 -- and the skip is drawn on. These are
    # the ones tools/soak_offline.py and the default CLI run.
    (1, 1, SP.HW_SKIP): {'bad': 15, 'badcells': 15, 'badall': 15, 'rate': 13, 'flags': 0, 'bytes': 2,
                         'nobytes': 0, 'bleed': 200, 'skip': 0, 'judged': 1677, 'loudquiet': 5,
                         'loudmiss': 122, 'label': 3},
    (1, 8, SP.HW_SKIP): {'bad': 110, 'badcells': 22, 'badall': 10, 'rate': 107, 'flags': 0,
                         'bytes': 3, 'nobytes': 0, 'bleed': 1050, 'skip': 1, 'judged': 13415,
                         'loudquiet': 54, 'loudmiss': 622, 'label': 24},
}
WHY = {
    'bad': 'failing points',
    'badcells': 'cells with at least one failing point -- a UNION over phases, not a bench figure',
    # THE PHASE-INDEPENDENT DEFECTS, and the one cell figure a hardware lap can be set beside. A cell
    # that fails at one of eight capture phases is a cell the bench passes seven times in eight; a cell
    # that fails at all eight is a defect no placement escapes.
    'badall': 'cells that failed at EVERY capture phase',
    'rate': 'rate misreported outside snaptol, issue #46',
    'bytes': 'right rate, bytes are not the payload, issue #125',
    'nobytes': 'nothing decoded on a vector that should decode',
    'bleed': 'bytes wrong past the head ERR excludes, issue #49',
    # BOUNDED BOTH WAYS, and this one is the trap the others are not. judge() returns "unjudgeable"
    # when the app's own head bound leaves too few bytes to compare, which counts as `skip` and NOT as
    # `bad`. So a regression that inflates ua_head_bad, shortens results or suppresses bytes moves
    # points out of `bad` into `skip`, and an unbounded `skip` would let the driver call that IMPROVED
    # and invite the baseline to be lowered. `judged` is ok+bad and pins how much was compared at all.
    'skip': 'points the app left too short to judge',
    'judged': 'points actually compared against the payload (ok + bad)',
    # A PASS THAT HAS TO STAY VISIBLE. docs/BENCH.md makes declining the correct answer for a `loud`
    # waveform, so these are not failures and must never be counted as any -- v47's spikes stack to
    # 9.3 V and decoding nothing is right. But an uncounted pass cannot be bounded, and a regression
    # that suppressed every byte on every loud vector would move nothing at all. Ratcheted upward for
    # that reason, and deliberately NOT downward: loud vectors starting to decode is not a defect.
    'loudquiet': 'loud vectors that declined -- a pass, bounded so mass suppression cannot hide',
    # THE OTHER TOLERANCE THAT HAS TO STAY VISIBLE. bench_uart allows a loud vector max(2, 3 % of body)
    # mismatched bytes, because a jitter-flipped byte in 8N1 has no parity to flag it, and this harness
    # now allows the same -- which is what stopped it failing 11 cells the bench passed. Bounded upward
    # so a regression that started losing bytes inside the allowance still moves a number.
    'loudmiss': 'bytes forgiven by the loud mismatch budget -- inside the bench\'s own allowance',
    # THE DIMENSION NO BYTE COMPARISON CAN SEE. judge() compares bytes; framing uses the unsnapped
    # bittime while the DISPLAYED rate goes through sig_snap, so a capture can be byte-perfect and still
    # name a rate 2.4-2.7 % wrong -- and be marked snapped, which removes the panel's approximate marker.
    # Uncounted, that class scored ZERO in 141040 decodes while one hardware lap found three of it. It is
    # a SUBSET of `rate` now that a misreport fails the point, as it does on the bench.
    'label': 'bytes accepted but the REPORTED RATE is still wrong (cluster C)',
    # THE APP'S OWN UNCERTAINTY, BOUNDED. bench_uart.judge_payload fails a capture that flagged more
    # interior frames than 2 % of the body or two, whichever is kinder; the offline judge had no such
    # test and read a flagged frame's value as a good byte. It measures ZERO at every configuration
    # below and at iterations 1-5, which is a finding and not a dead gate: the judge applies the bench's
    # own rule on this axis, so what still differs on v46 at 80000 Bd -- 5 interior flagged on the
    # bench, 203 bytes cyclic-exact and nothing flagged here -- is the signal chain.
    'flags': 'right bytes, more interior frames flagged than the app\'s own budget allows',
}


def parse(line):
    """A PLAN summary line -> (shard, nshard, iteration, counters). -> None if it is not one.

    EVERY KEY MUST BE PRESENT. Defaulting a missing counter to 0 reads a renamed or dropped field as a
    clean zero -- a verdict derived from absent evidence, which is this project's worst failure mode. A
    summary that does not carry all of KEYS is a MALFORMED REPORT and raises rather than totalling.
    """
    m = LINE.match(line.strip())
    if not m:
        return None
    body, out, missing = m.group(4), {}, []
    for k in KEYS:
        hits = re.findall(r'\b' + re.escape(k) + r' (\d+)', body)
        if len(hits) != 1:
            missing.append('%s x%d' % (k, len(hits)))
        else:
            out[k] = int(hits[0])
    if missing:
        raise SystemExit('MALFORMED PLAN summary -- %s not present exactly once in: %s'
                         % (', '.join(missing), body))
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), out


def emit_plan(iteration, skip=SP.HW_SKIP):
    """Regenerate the plan for `iteration` and return (path, sha256[:12]). Never reads an existing one.

    THE DEFAULT IS THE BENCH'S OWN SKIP, not an empty tuple, and that is the difference between a
    default and a trap. tools/soak_offline.py calls this with the iteration alone, so a `()` default
    would leave the LONGEST-RUNNING offline harness in the repo emitting the 41-vector plan -- the exact
    experiment this file documents as invalid -- while plan_sweep's own CLI got it right. A caller that
    has not thought about the skip should get the lap the instrument runs.

    THE SKIP IS IN THE FILENAME, not only in the file. Two skip lists give the same iteration two
    different plans, and a single plan-N.lua would let one caller's write land under another's running
    shards -- tools/soak_offline.py calls this from several threads at once, and a shard that re-read a
    replaced file would total two different experiments into one number.
    """
    os.makedirs(PLANDIR, exist_ok=True)
    tag = '-skip-' + '-'.join(skip) if skip else ''
    path = os.path.join(PLANDIR, 'plan-%d%s.lua' % (iteration, tag))
    argv = ['python3', 'tools/soakplan.py', '--emit-lua', '--iteration', str(iteration)]
    if skip:
        argv += ['--skip-vectors', ','.join(skip)]
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise SystemExit('soakplan.py --iteration %d exited %d:\n%s'
                         % (iteration, p.returncode, p.stderr.decode('utf-8', 'replace')))
    # A PLAN THAT IS SUSPICIOUSLY SMALL IS A FAILED EMIT, not a small plan. soakplan writes the whole
    # table in one go, so a truncated file would make every shard skip cells and still report cleanly.
    if len(p.stdout) < 10000:
        raise SystemExit('soakplan.py --iteration %d emitted only %d bytes; that is not a plan'
                         % (iteration, len(p.stdout)))
    # WRITTEN ATOMICALLY, because tools/soak_offline.py calls this from several worker threads at once
    # and a reader that opened the file mid-write would see a truncated Lua table -- which loads as a
    # plan with fewer cells and reports a clean shard. The content for an iteration is deterministic, so
    # two racing writers put the same bytes there; only the partial state has to be made unreachable.
    # PID AND THREAD, not pid alone: soak_offline's callers are threads of ONE process, so a pid-only
    # scratch name is shared by every one of them and they would overwrite each other's partial writes.
    tmp = '%s.%d.%d.tmp' % (path, os.getpid(), threading.get_ident())
    with open(tmp, 'wb') as fh:
        fh.write(p.stdout)
    os.replace(tmp, path)
    return path, hashlib.sha256(p.stdout).hexdigest()[:12]


def run_shard(k, n, plan, offsets):
    argv = ['lua', 'tools/sweep_plan.lua', '--plan', plan, '--shard', '%d/%d' % (k, n),
            '--offsets', str(offsets), '--quiet']
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return k, p.returncode, p.stdout.decode('utf-8', 'replace')


def one_lap(iteration, workers, offsets, quiet, skip=SP.HW_SKIP):
    """One iteration across every shard. -> (totals dict, list of failure strings, detail lines)."""
    plan, digest = emit_plan(iteration, skip)
    tot = dict((k, 0) for k in KEYS)
    failed, detail, nsummary = [], [], 0
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(run_shard, k, workers, plan, offsets) for k in range(1, workers + 1)]
        for f in futs:
            k, rc, out = f.result()
            got = 0
            for line in out.splitlines():
                p = parse(line)
                if p is not None:
                    sh, nsh, it, d = p
                    # THE SUMMARY MUST BE THE ONE THIS SHARD WAS ASKED FOR. Without checking sh/nsh a
                    # duplicate summary from one worker can stand in for a silent one from another and
                    # the count still reconciles; without checking `it` a plan file replaced under the
                    # run totals two different experiments into one number.
                    if (sh, nsh) != (k, workers):
                        failed.append('shard %d printed a summary for %d/%d' % (k, sh, nsh))
                    if it != iteration:
                        failed.append('shard %d ran iteration %d, not %d' % (k, it, iteration))
                    got = got + 1
                    nsummary += 1
                    for key in KEYS:
                        if key in MAXKEYS:
                            tot[key] = max(tot[key], d[key])
                        else:
                            tot[key] += d[key]
                elif line.startswith('  ') and line.strip():
                    # sweep_plan.lua indents per-cell rows and nothing else, so this keeps the
                    # failures and drops both its banners without matching on their wording.
                    detail.append('  [shard %d] %s' % (k, line.strip()))
            # EXACTLY ONE SUMMARY, AND AN EXPECTED EXIT CODE. rc 1 is normal for a shard that found a
            # known failure and rc 0 for a clean one; anything else -- a raise, a signal, a crash AFTER
            # the summary was flushed -- is a dead shard whose numbers must not be trusted just because
            # it managed to print a line first.
            if got == 0:
                failed.append('shard %d printed no summary (exit %d)' % (k, rc))
            elif got > 1:
                failed.append('shard %d printed %d summaries' % (k, got))
            if rc not in (0, 1):
                failed.append('shard %d exited %d, which is neither clean (0) nor known-failure (1)'
                              % (k, rc))
    if nsummary != workers:
        failed.append('%d shards ran but only %d printed a summary' % (workers, nsummary))
    if tot['raised'] > 0:
        failed.append('%d decode(s) RAISED. There is no capture placement for which that is the '
                      'right answer.' % tot['raised'])
    if tot['ok'] + tot['bad'] == 0:
        failed.append('nothing was judged at all')
    lsum = sum(tot[k] for k in LABEL_ROUTES)
    if lsum != tot['label']:
        failed.append('the %d label misreport(s) split into %d route(s) -- a subdivision that does not '
                      'reconcile with its total cannot be read as evidence' % (tot['label'], lsum))
    rsum = sum(tot[k] for k in ROUTES)
    if rsum != tot['rate']:
        failed.append('the %d rate point(s) split into %d route(s) -- a subdivision that does not '
                      'reconcile with its total cannot be read as evidence' % (tot['rate'], rsum))
    return tot, failed, detail, digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iteration', type=int, default=1, help='soak plan iteration to replay')
    ap.add_argument('--iterations', type=int, default=None,
                    help='replay iterations 1..N as N laps instead of a single one')
    ap.add_argument('--offsets', type=int, default=1,
                    help='capture start offsets per cell (default 1: the plan\'s own wait only). One '
                         'capture of a looping arb is a coin flip, so a real measurement wants 8+')
    ap.add_argument('--workers', type=int, default=12,
                    help='parallel shards, and therefore the shard count (default 12)')
    ap.add_argument('--quiet', action='store_true', help='totals only, no per-cell failure lines')
    ap.add_argument('--no-ratchet', action='store_true',
                    help='report the counts without gating on them')
    # SPELT AS THE BENCH SPELLS IT, and it must be the SAME STRING the bench lap used: the skip is
    # applied before the shuffle, so it moves every cell's amplitude, offset and wait. A twin lap run
    # without the bench's own skip set drives a different waveform in every cell.
    ap.add_argument('--skip-vectors', default=DEFAULT_SKIP,
                    help='comma list the lap does not play (default %s, the bench\'s own). Part of '
                         'the plan, not a filter: it reshuffles the order every wait, amplitude and '
                         'offset is keyed on. Pass "" to sweep all %d vectors, which is NOT the lap '
                         'the bench runs' % (DEFAULT_SKIP, len(SP._MAP_KEYS())))
    a = ap.parse_args()
    if a.workers < 1:
        raise SystemExit('--workers must be at least 1')
    if a.offsets < 1:
        raise SystemExit('--offsets must be at least 1')
    skip = SP.parse_skip(a.skip_vectors)

    laps = list(range(1, a.iterations + 1)) if a.iterations else [a.iteration]
    print('offline plan sweep: %d lap(s), %d offset(s) per cell, %d shards'
          % (len(laps), a.offsets, a.workers))
    print('plans regenerated into %s' % os.path.relpath(PLANDIR, ROOT))
    # PRINTED EVERY RUN, because two runs differing only in this produce different numbers for the same
    # iteration, and nothing else in the output names which of them a number belongs to.
    print('skipping %s -- %d vector(s) swept, as the bench sweeps them'
          % (', '.join(skip) or '(nothing)', len(SP._MAP_KEYS()) - len(skip)))
    print()

    # badall SITS NEXT TO badcell because the pair is the point: badcell is the union over capture
    # phases and badall the intersection, and only the second is comparable with a bench lap.
    # EVERY RATCHETED COUNTER IS IN THIS ROW, including the three tolerances. A counter that only appears
    # inside the ratchet block cannot be re-measured, because --no-ratchet is exactly the run you make to
    # re-measure it -- so lquiet, lmiss, flags and label are printed here or the documented workflow
    # does not work.
    hdr = ('%-5s %-13s %6s %5s %7s %6s %6s %6s %5s %5s %5s %5s %5s %5s %6s %5s %5s'
           % ('lap', 'plan', 'cells', 'bad', 'badcell', 'badall', 'raised', 'nobyte', 'skip', 'rate',
              'flags', 'bytes', 'label', 'bleed', 'worst', 'lquiet', 'lmiss'))
    print(hdr)
    print('-' * len(hdr))
    allfail, rows = [], []
    for it in laps:
        tot, failed, detail, digest = one_lap(it, a.workers, a.offsets, a.quiet, skip)
        rows.append((it, tot))
        if not a.quiet:
            for d in detail:
                print(d)
        print('%-5d %-13s %6d %5d %7d %6d %6d %6d %5d %5d %5d %5d %5d %5d %6d %5d %5d'
              % (it, digest, tot['cells'], tot['bad'], tot['badcells'], tot['badall'], tot['raised'],
                 tot['nobytes'], tot['skip'], tot['rate'], tot['flags'], tot['bytes'], tot['label'],
                 tot['bleed'], tot['bleedworst'], tot['loudquiet'], tot['loudmiss']))
        allfail.extend('lap %d: %s' % (it, x) for x in failed)

    if len(rows) > 1:
        # ACROSS LAPS, the interesting numbers are the spread and the union: a defect present in every
        # lap is a property of the decoder, one appearing in a single lap is a property of that draw.
        print()
        for key in (('bad', 'badcells', 'badall', 'rate', 'flags', 'bytes', 'nobytes', 'bleed',
                     'skip', 'loudquiet', 'loudmiss', 'label') + tuple(ROUTES)):
            vals = sorted(t[key] for _, t in rows)
            print('  %-9s per lap  min %d  median %d  max %d  total %d'
                  % (key, vals[0], vals[len(vals) // 2], vals[-1], sum(vals)))
        # THE ROUTE SHARES, which is the number worth reading: 46b at 73 % and cluster C at 14.5 % of
        # the hardware misreports are what say where to look, and a share is not recoverable from the
        # per-lap spread above once the laps are summed.
        ltot = sum(sum(t[k] for _, t in rows) for k in LABEL_ROUTES)
        if ltot > 0:
            print('  label rts   ' + ',  '.join(
                '%s %d' % (k, sum(t[k] for _, t in rows)) for k in LABEL_ROUTES))
        rtot = sum(sum(t[k] for _, t in rows) for k in ROUTES)
        if rtot > 0:
            print('  #46 routes  ' + ',  '.join(
                '%s %d (%.1f %%)' % (k, sum(t[k] for _, t in rows),
                                     100.0 * sum(t[k] for _, t in rows) / rtot)
                for k in ROUTES))

    # THE RATCHET, applied only at the configuration its baselines were measured at, and only to a
    # single-lap run: across laps the counts are per-draw and a baseline drawn from iteration 1 says
    # nothing about iteration 12.
    key = (a.iteration, a.offsets, skip)
    if a.no_ratchet:
        print('\n-- ratchet DISABLED by --no-ratchet: the counts above gate nothing --')
    elif os.environ.get('SDEC_PROBE_N'):
        # A SWEPT PROBE CAP IS A DIFFERENT DECODER. sweep_plan.lua honours SDEC_PROBE_N so the format
        # search's ranking window can be measured rather than argued about, and every count in RATCHET
        # was measured at the shipped default. Comparing a run at another cap against those baselines
        # would read a deliberate improvement as an unexplained gain -- or worse, latch it.
        print('\n-- ratchet SKIPPED: SDEC_PROBE_N=%s is set, so this is not the shipped decoder and no '
              'baseline here describes it --' % os.environ['SDEC_PROBE_N'])
    elif len(laps) > 1:
        print('\n-- ratchet SKIPPED for a multi-lap run: each lap is a different draw, so a baseline '
              'measured on one iteration does not describe the others --')
    elif not RATCHET.get(key):
        # AN EMPTY BASELINE SET IS NOT A MEASURED ONE. A configuration whose dict is `{}` gates on
        # nothing while `key in RATCHET` still reads True, so it is reported as unmeasured rather than
        # passed silently -- a gate that checks zero counters is worse than an absent one.
        print('\n-- ratchet SKIPPED: iteration %d at %d offset(s) skipping %s is not a measured '
              'configuration (%s), so no baseline describes this run --'
              % (a.iteration, a.offsets, ', '.join(skip) or '(nothing)',
                 ', '.join('iteration %d/%d offsets/skip %s' % (i, o, ','.join(s) or '(nothing)')
                           for i, o, s in sorted(RATCHET) if RATCHET[(i, o, s)])
                 or 'none are measured yet'))
    else:
        base, tot = RATCHET[key], dict(rows[0][1])
        tot['judged'] = tot['ok'] + tot['bad']
        print('\n-- ratchets (iteration %d, %d offset(s), skipping %s) --'
              % (key[0], key[1], ', '.join(key[2]) or '(nothing)'))
        for k in sorted(base):
            got, want = tot[k], base[k]
            if got > want:
                allfail.append('%s rose to %d from a measured %d (%s) -- %d new case(s). Either a '
                               'change made it worse, or it reached cells it did not affect before. '
                               'Do not raise the baseline to make this pass.'
                               % (k, got, want, WHY[k], got - want))
                print('  %-9s %4d  WORSE than %d   %s' % (k, got, want, WHY[k]))
            elif k == 'judged' and got < want:
                allfail.append('judged FELL to %d from %d -- %d point(s) are no longer compared '
                               'against the payload at all. Less evidence is not an improvement.'
                               % (got, want, want - got))
                print('  %-9s %4d  FEWER than %d   %s' % (k, got, want, WHY[k]))
            elif got < want:
                print('  %-9s %4d  IMPROVED from %d   %s' % (k, got, want, WHY[k]))
                print('            ^ set RATCHET[%r][%r] to %d in this file, or the gain is not held'
                      % (key, k, got))
            else:
                print('  %-9s %4d  unchanged        %s' % (k, got, WHY[k]))

    # LAST LINE, ONE LINE, because tools/release_sweep.py summarises an unrecognised stage by its final
    # line of output -- and without this that would be whichever ratchet counter sorted last, which
    # says nothing about the run.
    print()
    tp = sum(t['points'] for _, t in rows)
    tb = sum(t['bad'] for _, t in rows)
    print('%d lap(s), %d point(s) over %d cell(s): %d bad -- %d rate (#46), %d bytes (#125), '
          '%d nobytes, %d raised'
          % (len(rows), tp, sum(t['cells'] for _, t in rows), tb,
             sum(t['rate'] for _, t in rows), sum(t['bytes'] for _, t in rows),
             sum(t['nobytes'] for _, t in rows), sum(t['raised'] for _, t in rows)))

    if allfail:
        print()
        for x in allfail:
            print('FAILED: %s' % x)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

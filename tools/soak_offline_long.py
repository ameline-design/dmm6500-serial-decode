#!/usr/bin/env python3
"""Replay soak plan iterations offline, one lap per iteration, until a deadline.

    python3 tools/soak_offline_long.py --hours 12
    python3 tools/soak_offline_long.py --hours 12 --outdir ~/tmp/offsoak

WHY ONE INVOCATION PER LAP rather than plan_sweep.py --iterations N. Three reasons, and the third is the
one that matters. A single N-lap invocation reports once at the end, so twelve hours of work is one
result that either exists or does not; it holds every lap's totals in memory; and its ratchet is skipped
wholesale because the laps are different draws. Per lap, each result is durable the moment it is written,
the memory cost is one lap, and every lap that looks interesting is reproducible EXACTLY -- the plan for
an iteration is deterministic, so `plan_sweep.py --iteration K --offsets 8 --random-per-lap 4` replays it
with the per-cell failure lines this driver deliberately does not keep.

WHAT IT SWEEPS. Iteration K for K = 1, 2, 3 ... which is the same sequence of draws the instrument plays,
at the instrument's own configuration: v95 and v96 skipped (v96 wedges the generator) and four random
vectors a lap. So the first ~115 iterations are directly comparable with the hardware run, and everything
past that is coverage the hardware will not reach. Eight capture phases per cell, because one capture of
a looping arb is a coin flip -- and eight costs 1.5x the wall time of one, not 8x, since the shards
saturate rather than the decode.

RATCHETS ARE OFF, DELIBERATELY. Every baseline in plan_sweep.RATCHET is measured at ONE iteration, and a
baseline drawn from iteration 1 says nothing about iteration 12 -- the rates, waits and amplitudes are all
redrawn. So this aggregates instead, and the thing it looks for is not a threshold but a NOVELTY: a
counter class that has never been non-zero before, or a lap far outside the distribution of its
neighbours. `raised` and `nobytes` are the two that must stay flat at zero.

THE PLAN FILES ARE DELETED AS THEY GO. One is ~140 kB and twelve hours is thousands of laps; they are
regenerated deterministically from the iteration number, so keeping them buys nothing that the iteration
number does not already buy.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

# The summary table row plan_sweep prints per lap. Anchored on the 12-hex plan digest so a stray line of
# failure text cannot be read as a result row.
ROW = re.compile(r'^\s*(\d+)\s+([0-9a-f]{12})\s+(.*)$')
COLS = ['cells', 'bad', 'badcell', 'badall', 'raised', 'nobyte', 'skip', 'rate', 'flags', 'bytes',
        'label', 'bleed', 'worst', 'lquiet', 'lmiss']
TAIL = re.compile(r'(\d+) lap\(s\), (\d+) point\(s\) over (\d+) cell\(s\): (\d+) bad')

# THE TWO THAT MUST STAY AT ZERO. A decode that RAISED is never the right answer at any capture phase, and
# nobytes is bounded rather than absent: the class had 105 points at 8 offsets until ua_run stopped
# choosing a frame anchor outside the window it scores, so this is the counter that says the bound is lost.
FLAT = ('raised', 'nobyte')


def one(it, offsets, rkeep, workers, timeout):
    """Run iteration `it`. -> (dict or None, raw stdout, rc)."""
    argv = ['python3', os.path.join(ROOT, 'tools', 'plan_sweep.py'),
            '--iteration', str(it), '--offsets', str(offsets),
            '--random-per-lap', str(rkeep), '--workers', str(workers),
            '--quiet', '--no-ratchet']
    t0 = time.time()
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, 'TIMEOUT after %d s' % timeout, -9
    out = p.stdout.decode('utf-8', 'replace') + p.stderr.decode('utf-8', 'replace')
    rec = {'iter': it, 'rc': p.returncode, 'secs': round(time.time() - t0, 2)}
    for ln in out.split('\n'):
        m = ROW.match(ln)
        if m and int(m.group(1)) == it:
            f = m.group(3).split()
            if len(f) >= len(COLS):
                rec['plan'] = m.group(2)
                for k, v in zip(COLS, f):
                    rec[k] = int(v)
        m = TAIL.search(ln)
        if m:
            rec['points'] = int(m.group(2))
    if 'plan' not in rec:
        return None, out, p.returncode
    return rec, out, p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hours', type=float, default=12.0)
    ap.add_argument('--offsets', type=int, default=8)
    ap.add_argument('--random-per-lap', type=int, default=4)
    ap.add_argument('--workers', type=int, default=14)
    ap.add_argument('--from-iteration', type=int, default=1)
    ap.add_argument('--outdir', default=os.path.expanduser('~/tmp/offsoak'))
    ap.add_argument('--lap-timeout', type=int, default=1800,
                    help='a lap that takes this long is recorded as a hang and the sweep carries on')
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    jpath = os.path.join(a.outdir, 'laps.jsonl')
    lpath = os.path.join(a.outdir, 'soak.log')
    deadline = time.time() + a.hours * 3600

    # EVERY ALARM STRING THIS FILE CAN EMIT IS LISTED IN ITS OWN HEADER, so whoever watches the log knows
    # what to grep for without reading the source. A watcher given only 'look for problems' invents its own
    # patterns and misses the ones that matter.
    with open(lpath, 'a') as f:
        f.write('=== offline soak: %.1f h, iteration %d onward, %d offset(s), random-per-lap %d, '
                '%d shards\n' % (a.hours, a.from_iteration, a.offsets, a.random_per_lap, a.workers))
        f.write('=== started %s, deadline %s\n'
                % (time.strftime('%Y-%m-%dT%H:%M:%S'),
                   time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(deadline))))
        f.write('=== ALARMS: "ALARM raised", "ALARM nobyte", "ALARM novel", "ALARM lap failed", '
                '"ALARM hang". Anything else is progress.\n')
        f.flush()

    seen = {}                                   # counter -> laps where it was ever non-zero
    n = nbad = nalarm = 0
    it = a.from_iteration - 1
    while time.time() < deadline:
        it += 1
        rec, out, rc = one(it, a.offsets, a.random_per_lap, a.workers, a.lap_timeout)
        alarms = []
        if rec is None:
            alarms.append('ALARM lap failed: iteration %d produced no summary row, rc=%d' % (it, rc))
            if 'TIMEOUT' in out:
                alarms.append('ALARM hang: iteration %d exceeded %d s' % (it, a.lap_timeout))
            rec = {'iter': it, 'rc': rc, 'nosummary': True}
        else:
            for k in FLAT:
                if rec.get(k, 0) > 0:
                    alarms.append('ALARM %s: iteration %d has %s=%d, which is zero at every measured '
                                  'configuration' % (k, it, k, rec[k]))
            # A CLASS THAT HAS NEVER BEEN NON-ZERO IS THE INTERESTING ONE, not a class that got bigger:
            # every counter here varies lap to lap because every lap is a different draw, so a threshold
            # would fire on the draw. `flags` measures zero at every measured configuration and at
            # iterations 1-5, so the first lap that moves it is worth a line.
            for k in ('flags', 'skip'):
                if rec.get(k, 0) > 0 and k not in seen:
                    alarms.append('ALARM novel: iteration %d is the first lap with %s=%d'
                                  % (it, k, rec[k]))
            for k in COLS:
                if rec.get(k, 0) > 0:
                    seen.setdefault(k, it)
            nbad += rec.get('bad', 0)
        rec['alarms'] = alarms
        n += 1
        nalarm += len(alarms)
        with open(jpath, 'a') as f:
            f.write(json.dumps(rec) + '\n')
        with open(lpath, 'a') as f:
            if alarms:
                for s in alarms:
                    f.write(s + '\n')
                f.write('--- iteration %d raw output follows ---\n%s\n' % (it, out))
            f.write('lap %d: %s\n' % (it, json.dumps({k: rec.get(k) for k in
                                                      ['secs', 'cells', 'points', 'bad', 'badall',
                                                       'raised', 'nobyte', 'rate', 'bytes']})))
            left = (deadline - time.time()) / 3600.0
            f.write('    %d lap(s) done, %d bad point(s) total, %d alarm(s), %.2f h left\n'
                    % (n, nbad, nalarm, left))
            f.flush()
        # The plan for an iteration is deterministic, so the file is regenerable and worth no disk.
        for nm in os.listdir(os.path.join(ROOT, 'out', 'plans', 'auto')):
            if nm.startswith('plan-%d-' % it) or nm == 'plan-%d.lua' % it:
                try:
                    os.remove(os.path.join(ROOT, 'out', 'plans', 'auto', nm))
                except OSError:
                    pass

    with open(lpath, 'a') as f:
        f.write('=== FINISHED %s: %d lap(s), %d bad point(s), %d alarm(s)\n'
                % (time.strftime('%Y-%m-%dT%H:%M:%S'), n, nbad, nalarm))
        f.flush()
    print('%d lap(s), %d bad point(s), %d alarm(s) -- %s' % (n, nbad, nalarm, jpath))
    return 1 if nalarm else 0


if __name__ == '__main__':
    sys.exit(main())

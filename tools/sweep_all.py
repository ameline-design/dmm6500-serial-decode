#!/usr/bin/env python3
"""Run every shard of tools/sweep_startphase.lua in parallel and total the results.

WHY A DRIVER. The sweep is embarrassingly parallel -- each (vector, condition) unit is independent --
and this host has 16 cores while the decoder under test runs on a 2016 instrument. One shard is ~5 s;
twelve at once is the same 5 s for twelve times the coverage. The bench, by contrast, spends about a
minute per capture, so a full sweep here is worth thousands of bench points.

    python3 tools/sweep_all.py                    # one pass, 12 shards, seed 1
    python3 tools/sweep_all.py --seed 7 --offsets 32
    python3 tools/sweep_all.py --workers 4        # leave the machine usable

EXIT 1 IF ANY SHARD REPORTS A HARD FAILURE, and hard means one of the three things that are wrong
however the capture was placed: the decode raised, a result came back with an incomplete format, or a
byte the decoder presents as trustworthy is wrong at an alignment nothing explains. The softer
categories -- refusals, format ambiguity, rate misfits, head bleed -- are totalled and printed,
because they are honest outcomes or open issues, and a REGRESSION in them shows up as a number that
moved rather than as a pass or a fail.
"""
import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The counters sweep_startphase.lua prints on its SHARD line, in the order they appear there.
KEYS = ['cases', 'ok', 'refused', 'fmtdiff', 'ratediff', 'shortrun', 'headbleed',
        'redecodes', 'skipped', 'HARD']
LINE = re.compile(r'^SHARD (\d+)/(\d+) seed (\d+): (.*)$')


def parse(line):
    """A SHARD summary line -> dict of counter name to int. -> None if it is not one."""
    m = LINE.match(line.strip())
    if not m:
        return None
    out = {}
    body = m.group(4)
    for k in KEYS:
        # 'headbleed 4 (worst 2)' -- the parenthesised worst is read separately below.
        mm = re.search(re.escape(k) + r' (\d+)', body)
        out[k] = int(mm.group(1)) if mm else 0
    mw = re.search(r'worst (\d+)', body)
    out['worst'] = int(mw.group(1)) if mw else 0
    return out


def run_shard(k, n, seed, offsets, maxpts):
    argv = ['lua', 'tools/sweep_startphase.lua', '--shard', '%d/%d' % (k, n),
            '--offsets', str(offsets), '--seed', str(seed), '--maxpts', str(maxpts)]
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return k, p.returncode, p.stdout.decode('utf-8', 'replace')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--workers', type=int, default=12,
                    help='parallel shards, and therefore the shard count (default 12)')
    ap.add_argument('--seed', type=int, default=1,
                    help='skews the start offsets, so successive seeds probe different placements')
    ap.add_argument('--offsets', type=int, default=24, help='start offsets per vector x condition')
    ap.add_argument('--maxpts', type=int, default=1200000,
                    help='skip a vector whose render exceeds this many points (default 1.2 M)')
    ap.add_argument('--quiet', action='store_true', help='totals only, no per-shard lines')
    a = ap.parse_args()
    if a.workers < 1:
        raise SystemExit('--workers must be at least 1')

    n = a.workers
    tot = dict((k, 0) for k in KEYS)
    tot['worst'] = 0
    failed, detail = [], []
    # A SHARD THAT PRINTS NO SUMMARY IS A FAILURE, not a zero. It means the interpreter died before
    # the report -- a syntax error, a missing module -- and silently totalling nothing from it would
    # turn a broken run into a clean one.
    nsummary = 0

    with ThreadPoolExecutor(max_workers=n) as ex:
        futs = [ex.submit(run_shard, k, n, a.seed, a.offsets, a.maxpts) for k in range(1, n + 1)]
        for f in futs:
            k, rc, out = f.result()
            got = None
            for line in out.splitlines():
                d = parse(line)
                if d is not None:
                    got = d
                    nsummary += 1
                    for key in KEYS:
                        tot[key] += d[key]
                    tot['worst'] = max(tot['worst'], d['worst'])
                elif line.strip():
                    detail.append('  [shard %d] %s' % (k, line.rstrip()))
            if got is None:
                failed.append('shard %d printed no summary (exit %d)' % (k, rc))
            elif rc != 0:
                failed.append('shard %d exited %d' % (k, rc))

    if not a.quiet:
        for d in detail:
            print(d)
        print()
    print('%d shards, seed %d, %d offsets per vector x condition' % (nsummary, a.seed, a.offsets))
    print('  %-10s %d' % ('decodes', tot['cases']))
    print('  %-10s %d' % ('byte-exact', tot['ok']))
    print('  %-10s %d   (an honest answer on a short or badly placed window)'
          % ('refused', tot['refused']))
    print('  %-10s %d   (7E1/8N1 ambiguity -- open issue #49)' % ('fmtdiff', tot['fmtdiff']))
    print('  %-10s %d   (periodic-payload rate misfit -- open issue #46)'
          % ('ratediff', tot['ratediff']))
    print('  %-10s %d   (too few trusted bytes to judge)' % ('shortrun', tot['shortrun']))
    print('  %-10s %d   (wrong bytes past ERR\'s exclusion; worst %d)'
          % ('headbleed', tot['headbleed'], tot['worst']))
    print('  %-10s %d   (refine_parity non-strict branch -- the r06 path)' % ('redecodes',
                                                                              tot['redecodes']))
    print('  %-10s %d' % ('skipped', tot['skipped']))
    print('  %-10s %d' % ('HARD', tot['HARD']))

    if nsummary != n:
        failed.append('%d shards ran but only %d printed a summary' % (n, nsummary))
    if failed:
        print()
        for x in failed:
            print('FAILED: %s' % x)
        return 1
    if tot['HARD'] > 0:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

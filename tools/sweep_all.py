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
# EVERY ONE MUST APPEAR EXACTLY ONCE on the line; see parse(). Reading a missing counter as 0 would let
# a renamed field report a clean run, and these feed the ratchet that bounds #46 and #49.
KEYS = ['cases', 'ok', 'exact', 'refused', 'fmtdiff', 'ratediff', 'shortrun', 'headbleed',
        'redecodes', 'skipped', 'HARD']

# RATCHETS FOR THE TWO OPEN-ISSUE COUNTERS. Measured 2026-08-22 at seed 1, 24 offsets, and verified
# BIT-IDENTICAL across two consecutive runs -- 3936 decodes, both counters unmoved. The 2221 figure
# recorded here was `ok`, which is not byte-exact: see RATCHET_FLOOR below.
#
# WHY A RATCHET AND NOT A TARGET. These count defects that are UNDERSTOOD BUT NOT FIXED, so demanding
# zero would fail the gate on a known state, and printing them with no bound lets them grow unnoticed
# -- which is what happened: the sweep has been reporting the #46 rate misfit since it was written, at
# 148 of 3936, while the issue was recorded as "the offline twin does not reproduce it". A number
# nobody compares against anything is not evidence.
#
# sweep_startphase.lua's own header says turning either counter into a gate "needs its issue closed
# first". #46's mechanism is now closed -- the reported rate flips with the CAPTURE START PHASE on a
# looping periodic payload, measured at 25 of 48 phases on v63 -- so the count can be bounded even
# though the defect remains. #49 is a genuine 7E1/8N1 ambiguity and is bounded for the same reason.
#
# ONLY AT THE GATE'S OWN SETTINGS. A different seed or offset count draws different windows, so the
# baselines do not describe it and the ratchet is skipped rather than applied wrongly.
RATCHET_SEED, RATCHET_OFFSETS = 1, 24
# LOWERED 2026-08-24 by ua_minrun_absurd, which rejects the ODD sub-multiples ua_submultiple cannot
# see: ratediff 148 -> 130, and fmtdiff 533 -> 515 as a consequence, since a decode at the wrong rate
# also reads the wrong format. HARD stayed 0 and headbleed 96; shortrun rose 966 -> 977, which is the
# honest cost -- blocking a rescaling removes the frames a shorter bit time invented, so a few cells
# now have too few trusted bytes to judge instead of a confident wrong rate.
# RAISED 2026-08-28 by the frame-anchor bound in ua_run, and the arithmetic is the whole justification:
# refused fell 120 -> 94, byte-exact rose 2196 -> 2218, fmtdiff rose 515 -> 519. 26 = 22 + 4, so every
# case that moved came OUT of refused, and the four that landed on the 7E1/8N1 ambiguity are cases the
# sweep could not previously reach at all -- not cases that got worse. ratediff, headbleed, shortrun and
# HARD did not move.
RATCHET = {
    'ratediff': (130, 'periodic-payload rate misfit, issue #46'),
    'fmtdiff': (519, '7E1/8N1 ambiguity, issue #49'),
}
# AND A FLOOR, because the ratchet above is one-directional and that is a hole this very change walked
# through. A rise in fmtdiff is indistinguishable from a fall in byte-exact when only fmtdiff is
# bounded: pushing 4 correct decodes into the ambiguity, and reaching 4 windows that used to decode
# nothing, move the same counter the same way. Bounding byte-exact from below tells them apart -- the
# first drops it, the second does not.
RATCHET_FLOOR = {
    'exact': (2218, 'decodes whose bytes match the payload at zero shift'),
}
LINE = re.compile(r'^SHARD (\d+)/(\d+) seed (\d+): (.*)$')

# The BLEED line scores the two ways ua_head_bad could be wrong against the truth the sweep already
# knows. Every name here is a distinct word, so a plain 'name N' search cannot cross-match -- the
# SHARD line's 'headbleed 4 (worst 2)' taught that lesson.
BKEYS = ['bleeds', 'bleedsum', 'bleedworst', 'hsset', 'hsover', 'hsoversum', 'hsoverworst', 'hsunder']
BLINE = re.compile(r'^BLEED (\d+)/(\d+) (.*)$')


def parse_bleed(line):
    """A BLEED line -> dict of counter name to int. -> None if it is not one."""
    m = BLINE.match(line.strip())
    if not m:
        return None
    body = m.group(3)
    out, missing = {}, []
    for k in BKEYS:
        hits = re.findall(r'\b' + re.escape(k) + r' (\d+)', body)
        if len(hits) != 1:
            missing.append('%s x%d' % (k, len(hits)))
        else:
            out[k] = int(hits[0])
    if missing:
        raise SystemExit('MALFORMED BLEED line -- %s not present exactly once in: %s'
                         % (', '.join(missing), body))
    return out


def parse(line):
    """A SHARD summary line -> (shard, nshard, seed, counters). -> None if it is not one.

    THE SHARD'S OWN IDENTITY IS RETURNED, not just its numbers. Totalling counters without checking
    which shard and which seed produced them means two workers running the SAME shard reconcile
    perfectly -- n summaries for n workers -- while a third of the plan was never swept and a third
    was swept twice. parse_bleed needs no such check: it is totalled, never matched to a worker.
    """
    m = LINE.match(line.strip())
    if not m:
        return None
    out, missing = {}, []
    body = m.group(4)
    for k in KEYS:
        # 'headbleed 4 (worst 2)' -- the parenthesised worst is read separately below.
        # ANCHORED ON BOTH SIDES. Without the leading \b, 'notok 3' satisfies key 'ok' and 'ok' is
        # then reported as absent from its own line -- or worse, present twice.
        hits = re.findall(r'\b' + re.escape(k) + r' (\d+)', body)
        if len(hits) != 1:
            missing.append('%s x%d' % (k, len(hits)))
        else:
            out[k] = int(hits[0])
    if missing:
        raise SystemExit('MALFORMED SHARD line -- %s not present exactly once in: %s'
                         % (', '.join(missing), body))
    mw = re.search(r'worst (\d+)', body)
    out['worst'] = int(mw.group(1)) if mw else 0
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), out


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
    ap.add_argument('--maxpts', type=int, default=4000000,
                    help='skip a vector whose render exceeds this many points (default 4 M, which '
                         'is above v96 at 3.41 M so nothing is skipped -- measured 0.4 s, 148 MB)')
    ap.add_argument('--quiet', action='store_true', help='totals only, no per-shard lines')
    a = ap.parse_args()
    if a.workers < 1:
        raise SystemExit('--workers must be at least 1')

    n = a.workers
    tot = dict((k, 0) for k in KEYS)
    tot['worst'] = 0
    btot = dict((k, 0) for k in BKEYS)
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
            ngot = 0
            for line in out.splitlines():
                p = parse(line)
                if p is not None:
                    sh, nsh, seed, d = p
                    # THE SUMMARY MUST BE THE ONE THIS WORKER WAS ASKED FOR. A worker reporting another
                    # shard's identity means the plan was not partitioned the way the run claims: some
                    # slice was swept twice and another not at all, and every total below is drawn from
                    # a different experiment than the one named.
                    if (sh, nsh) != (k, n):
                        failed.append('shard %d printed a summary for %d/%d' % (k, sh, nsh))
                    if seed != a.seed:
                        failed.append('shard %d ran seed %d, not %d' % (k, seed, a.seed))
                    got = d
                    ngot += 1
                    nsummary += 1
                    for key in KEYS:
                        tot[key] += d[key]
                    tot['worst'] = max(tot['worst'], d['worst'])
                    continue
                b = parse_bleed(line)
                if b is not None:
                    for key in BKEYS:
                        if key.endswith('worst'):
                            btot[key] = max(btot[key], b[key])
                        else:
                            btot[key] += b[key]
                elif line.strip():
                    detail.append('  [shard %d] %s' % (k, line.rstrip()))
            if got is None:
                failed.append('shard %d printed no summary (exit %d)' % (k, rc))
            elif ngot > 1:
                # TOTALLED ONCE PER SHARD OR NOT AT ALL. Two summaries from one worker are added twice
                # above, so the counters come out inflated by a whole shard's worth of a real sweep --
                # which reads as a regression rather than as a broken run.
                failed.append('shard %d printed %d summaries, so its counters were totalled %d times'
                              % (k, ngot, ngot))
            elif rc != 0:
                failed.append('shard %d exited %d' % (k, rc))

    if not a.quiet:
        for d in detail:
            print(d)
        print()
    print('%d shards, seed %d, %d offsets per vector x condition' % (nsummary, a.seed, a.offsets))
    print('  %-10s %d' % ('decodes', tot['cases']))
    # `ok` IS NOT "byte-exact", and labelling it that hid the difference for as long as the label
    # existed. sweep_startphase.lua increments nok for three outcomes: bytes matching the payload at
    # zero shift, a right-format decode whose RATE is wrong, and a vector with no payload to compare.
    # Only the first means the decode was right, so both are printed and only the first is floored.
    print('  %-10s %d   (bytes match the payload at zero shift)' % ('exact', tot['exact']))
    print('  %-10s %d   (exact, or rate-only wrong, or nothing to match)' % ('ok', tot['ok']))
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

    # THE TWO ERROR DIRECTIONS SIDE BY SIDE, which is the whole question in #49's headbleed half:
    # narrowing to the last flagged frame under-reports by `bleedsum` bytes, and quoting headsusp
    # instead would over-report by `hsoversum` -- on the cases where headsusp is set at all, and
    # `hsunder` says how many it would still have missed.
    print('\n-- head damage: what ua_head_bad costs either way --')
    print('  narrow to the last flag  %d cases under-report, %d bytes total, worst %d'
          % (btot['bleeds'], btot['bleedsum'], btot['bleedworst']))
    print('  quote headsusp instead   %d of %d cases over-report, %d bytes total, worst %d'
          % (btot['hsover'], btot['hsset'], btot['hsoversum'], btot['hsoverworst']))
    print('  and headsusp would still miss %d case(s) -- damage outlives the first gap'
          % btot['hsunder'])

    if nsummary != n:
        failed.append('%d shards ran but only %d printed a summary' % (n, nsummary))

    # THE RATCHET. Applied only at the settings the baselines were measured at.
    if a.seed == RATCHET_SEED and a.offsets == RATCHET_OFFSETS:
        print('\n-- open-issue ratchets (seed %d, %d offsets) --' % (a.seed, a.offsets))
        for key in sorted(RATCHET):
            base, why = RATCHET[key]
            got = tot[key]
            if got > base:
                # A COUNT THAT GREW IS A REGRESSION, whatever the pass line says. The whole point of
                # bounding a known defect is that it must not spread to cases it did not affect.
                failed.append('%s rose to %d from a measured %d (%s) -- %d new case(s). '
                              'Either a change made it worse, or it reached vectors it did not touch '
                              'before. Do not raise the baseline to make this pass.'
                              % (key, got, base, why, got - base))
                print('  %-10s %4d  WORSE than %d   %s' % (key, got, base, why))
            elif got < base:
                # Not a failure -- but it must not pass silently, or the baseline stays loose enough
                # to let the defect come back later and still pass.
                print('  %-10s %4d  IMPROVED from %d   %s' % (key, got, base, why))
                print('             ^ set RATCHET[%r] to %d in this file, or the gain is not held'
                      % (key, got))
            else:
                print('  %-10s %4d  unchanged        %s' % (key, got, why))
        for key in sorted(RATCHET_FLOOR):
            base, why = RATCHET_FLOOR[key]
            got = tot[key]
            if got < base:
                # LESS CORRECTNESS IS A REGRESSION even when every bounded defect held: a decode that
                # stopped being byte-exact went somewhere, and the counter it went to may not be one
                # this file watches.
                failed.append('%s FELL to %d from a measured %d (%s) -- %d case(s) stopped being '
                              'right. A bounded defect holding does not make that a pass.'
                              % (key, got, base, why, base - got))
                print('  %-10s %4d  WORSE, below %d   %s' % (key, got, base, why))
            elif got > base:
                print('  %-10s %4d  IMPROVED from %d   %s' % (key, got, base, why))
                print('             ^ set RATCHET_FLOOR[%r] to %d in this file, or the gain is not held'
                      % (key, got))
            else:
                print('  %-10s %4d  unchanged        %s' % (key, got, why))
    else:
        print('\n-- open-issue ratchets SKIPPED: seed %d / %d offsets is not the measured '
              'configuration (%d / %d), so the baselines do not describe this run --'
              % (a.seed, a.offsets, RATCHET_SEED, RATCHET_OFFSETS))

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

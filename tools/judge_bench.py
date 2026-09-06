#!/usr/bin/env python3
"""Judge a record written by bench/bench_run.tsp on the instrument.

    python3 tools/judge_bench.py out/bench/SOAK000.csv
    python3 tools/judge_bench.py out/bench/SOAK000.csv --verbose

WHY THE INSTRUMENT DOES NOT JUDGE. The verdict rules are the accumulated argument of this project --
the loud-vector allowance, the interior flag budget, the head skip, the cyclic substring over a looping
payload, and the lorem gate that judge_payload_v exists to replace. Reimplementing that in Lua 5.0.2 on
a 2016 instrument would be a SECOND judge, and two judges is the failure this repo keeps writing
comments about: on the night they disagree, both look right. So the instrument records what it read --
including the '??' it writes for a frame it flagged, which is what stops a byte passing only because the
error was ignored -- and this reads those rows through bench_uart's own judge.

WHAT IT CANNOT SEE. Nothing here reaches the panel, so the format-ambiguity notes, the button matrix and
the display are outside its scope: this judges BYTES and RATES against the stimulus the plan commanded.
The host-driven bench remains the wider test; this is the one that can run for a week.
"""
import argparse
import csv
import math
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_uart as BU                                                  # noqa: E402
import soakplan as SP                                                    # noqa: E402
import vector_names as VN                                                # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = 'serdec-soak-1'

# The columns bench_rec.tsp writes after the 'R' tag, in order. Named here so a mismatch is a refusal
# rather than a silently shifted field -- the schema line in the file is what makes that checkable.
RCOLS = ['iter', 'cell', 'vid', 'baud', 'kind', 'amp_vpp', 'ofst_v', 'srate', 'wait_ms',
         'fs', 'sa_bit', 'ran', 'read_baud', 'fmt', 'nf', 'ngood', 'nbad', 'nflag',
         'headsusp', 'snapped', 'snapfirm', 'why', 'hex']

# THE RATE BAND CUT, AND WHY IT IS 115200. A plan lap sweeps 43 rates and the ladder has a genuine gap
# between 115200 and the next one up at 121098, so this boundary is a property of the stimulus rather than
# a threshold chosen to suit an answer. Below it every rate clears 8.68 samples/bit at the app's top
# sample rate of 1 MSa/s; above it samples/bit falls to 4.00 at 250000, against a refusal floor of
# sdec.minsabit * (1 - sdec.plaustol) = 3.92.
CLAIM_BAUD = 115200

# THE TWO RATE PAIRS A SNAP CAN CONFUSE. Adjacent entries in sdec.stdbaud are 11 % apart or more
# everywhere except 28800/31250 and 230400/250000, which are both 625/576 = 8.51 % -- the same pair scaled
# by eight. ratebad below trips at 2 %, so snapping to the wrong neighbour is a FAIL at either site, and
# one of the two sites sits BELOW the band cut where the strongest claim is made.
SNAP_PAIRS = ((28800, 31250), (230400, 250000))


def _binom_cdf(k, n, p):
    """P(X <= k) for Binomial(n, p).

    EVERY TERM IN LOG SPACE. The naive form carries p**i and (1-p)**(n-i), which underflow to zero long
    before n reaches the hundred thousand cells a fortnight judges -- and an underflowed sum does not raise,
    it silently returns a confident wrong bound. Written through lgamma, each term near the mode is O(1) at
    any n this tool will see and only the negligible tail underflows.
    """
    if k < 0:
        return 0.0
    if n <= 0 or k >= n:
        return 1.0
    if p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 0.0
    lp, lq, s = math.log(p), math.log1p(-p), 0.0
    for i in range(k + 1):
        s += math.exp(math.lgamma(n + 1.0) - math.lgamma(i + 1.0) - math.lgamma(n - i + 1.0)
                      + i * lp + (n - i) * lq)
    return min(1.0, s)


def _prop_bound(k, n, tail, upper=True):
    """Exact Clopper-Pearson bound on a PROPORTION: k of n, with one tail of probability `tail`.

    A BINOMIAL INTERVAL RATHER THAN A POISSON ONE, because this reports a proportion and a Poisson bound is
    on a count: divided by a small n it exceeds the number of cells and prints a rate above 100 %. Clamping
    that at 100 % hides the mismatch instead of removing it, and leaves the zero-failure branch printing
    '< 299 %' for a single judged cell. Clopper-Pearson is bounded by [0, 1] by construction and agrees with
    the Poisson form to three decimals at the denominators a soak produces.

    WHY EXACT RATHER THAN p +/- 1.96*sqrt(p(1-p)/n). The normal approximation is worst exactly where the
    strongest claim is made -- at zero failures it gives an interval of width nothing, which invites writing
    'no defects' as though it had been measured. Exact, a clean band becomes the claim it truly supports:
    88 000 cells and no failure is 'better than 1 in 29 000'.
    """
    if n <= 0:
        return 0.0
    if upper and k >= n:
        return 1.0
    if not upper and k <= 0:
        return 0.0
    kk = k if upper else k - 1
    target = tail if upper else 1.0 - tail
    lo, hi = 0.0, 1.0
    # THE CDF DECREASES IN p, so this brackets the crossing from below. The break is on absolute width
    # because the bracket starts at exactly [0, 1]: 50 halvings already reach 1e-15.
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if _binom_cdf(kk, n, mid) > target:
            lo = mid
        else:
            hi = mid
        if hi - lo <= 1e-15:
            break
    return 0.5 * (lo + hi)


def band_of(baud):
    """Which rate band a commanded baud falls in. An unparsable rate is its own band, never folded in."""
    try:
        return 'low' if float(baud) <= CLAIM_BAUD else 'high'
    except (TypeError, ValueError):
        return 'unparsable'


# THE APP'S OWN STANDARD FOR A RATE THAT EXPLAINS NOTHING, mirrored here rather than invented. uart_decode
# doubts a rate the OPERATOR locked once this fraction of interior frames fail -- sdec.relock_badfrac, with
# sdec.relock_minframes below it because a bad fraction over a handful of frames is not evidence, and
# sdec.ua_edge_frames head frames excluded because head resync fails on healthy captures too. The same
# numbers are used so the two cannot drift: 0.25 is the measured separation, a wrong rate running 0.34-0.50
# against ~0.004 for a healthy capture.
#
# NOTHING HERE CHANGES A VERDICT. A cell counted low-credibility is still judged exactly as before and the
# BAD total and exit code do not move -- this is a counter beside the verdict, not a stricter one. The app
# applies no such test to a rate it detected ITSELF, so these are cells whose reported rate and format are
# contradicted by their own framing, and the operator is given no sign of it.
RELOCK_BADFRAC, RELOCK_MINFRAMES, UA_EDGE_FRAMES = 0.25, 8, 3


def lowcred(r):
    """Does this row's own framing contradict the rate and format it reports? -> bool."""
    try:
        nf, nbad = int(r['nf']), int(r['nbad'])
    except (TypeError, ValueError):
        return False
    ninter = nf - UA_EDGE_FRAMES - 1
    if ninter < 1 or nf < RELOCK_MINFRAMES:
        return False
    return (nbad / float(ninter)) > RELOCK_BADFRAC


def payloads(vid):
    """The expected bytes for a vector, both legitimate readings where there are two.

    THREE VECTORS ARE FRAMED AMBIGUOUSLY BY CONSTRUCTION -- every byte of v90/v94's blocks has bit 7
    equal to the even parity of its low seven, so the payload is simultaneously valid 8N1 and valid 7E1
    and the app is right either way. Judging against one reading alone fails a correct decode.
    """
    import bench_matrix as BM
    return BM.plan_payloads(vid)


def is_lin(vid):
    """Does this vector carry LIN framing? -> bool.

    THE MANIFEST'S OWN proto COLUMN IS THE ORACLE, not a list of ids typed here. out/vectors/manifest.tsv
    is written by tools/make_vectors.lua alongside the waveform, so it says 'lin' for exactly the vectors
    rendered as LIN -- and a hand-kept copy is a copy to forget when a fourth LIN vector is added. Measured:
    v61, v62, v63.
    """
    import bench_matrix as BM
    return ((BM.manifest().get(vid) or {}).get('proto') or '') == 'lin'


def split_runs(lines):
    """-> [(tag, [lines])], one entry per RUN in the file, in the order they were written.

    ONE FILE HOLDS MANY RUNS, and that is by design rather than by accident: the record is a single fixed
    filename opened for append, because a numbered name means probing candidates for a free one and a
    probe that misses posts event 2205 -- a box on the panel of an instrument that must never show one.
    bench_rec.tsp therefore separates runs by their header line, and this is the reader that honours it.

    Judging the whole file instead merges a smoke into a soak: the counts add up, no error is raised, and
    the verdict is about a mixture nobody ran. That is exactly the kind of quietly-wrong answer this
    project keeps finding, so the default is the LAST run and everything else takes a flag.

    'tag=roll' AND 'tag=resumed' ARE CONTINUATIONS, not new runs. brec.roll writes the first when a single
    run passes the per-file byte cap; brec.reopen writes the second when recording failed and came back,
    which happens because a fault no longer ends a run -- the soak keeps measuring, retries the record, and
    carries on. Both mark a seam in one run's rows, and treating either as a new run would split a
    fortnight into pieces and judge each piece's counts on its own.
    """
    runs, cur = [], None
    for ln in lines:
        if ln.startswith('#') and SCHEMA in ln:
            tag = 'unnamed'
            for part in ln.split():
                if part.startswith('tag='):
                    tag = part[4:]
            if tag in ('roll', 'resumed') and cur is not None:
                continue                      # same run, next file or after a gap
            cur = (tag, [])
            runs.append(cur)
            continue
        if cur is not None:
            cur[1].append(ln)
    return runs


def report_bands(per_band, bybaud):
    """Print the decoder-defect rate per rate band, with the interval the count actually supports.

    'SDG failed' IS REPORTED AND EXCLUDED FROM THE RATE. A cell with no stimulus is a generator fault --
    nothing was on the wire, so the decoder was never asked -- and folding it into a decoder-defect figure
    would charge the app for the generator. It is printed rather than dropped, because a silently smaller
    denominator is the same defect in the other direction.
    """
    rows = []
    for key, label in (('low', '<= %d Bd' % CLAIM_BAUD), ('high', '>  %d Bd' % CLAIM_BAUD),
                       ('unparsable', 'unparsable Bd')):
        f, nd = per_band[(key, 'fail')], per_band[(key, 'nodec')]
        ic, pa, sd = per_band[(key, 'inc')], per_band[(key, 'pass')], per_band[(key, 'sdg')]
        judged = pa + f + nd
        if judged == 0 and ic == 0 and sd == 0:
            continue
        rows.append((label, judged, f, nd, ic, sd, per_band[(key, 'lowcred')]))
    if not rows:
        return
    print()
    print('  decoder defects by rate band:')
    print('    %-16s %8s %6s %10s %13s %11s %10s  %s'
          % ('band', 'judged', 'FAIL', 'no decode', 'inconclusive', 'SDG failed', 'low credib',
             'FAIL rate'))
    for label, judged, f, nd, ic, sd, lc in rows:
        if judged == 0:
            rate = 'nothing judged'
        elif f == 0:
            # A CLEAN BAND IS AN UPPER BOUND, NOT A ZERO, and the bound is printed so that a document cannot
            # quote the count as one. No sample size measures a zero rate; what this measures is a ceiling,
            # and at these denominators the ceiling is already a strong claim. ONE-SIDED here, because
            # 'no failure seen' has nothing below it to bound.
            hi = _prop_bound(0, judged, 0.05, upper=True)
            rate = 'none seen: < %.4f%% (1 in %d), 95%% one-sided' % (100.0 * hi, int(1.0 / hi))
        else:
            # TWO-SIDED, 2.5 % IN EACH TAIL, which is what '95 % CI' means to a reader. Quoting a bound that
            # is 95 % one-sided on each end and calling the pair a 95 % interval overstates it: that pair is
            # a 90 % interval.
            lo = _prop_bound(f, judged, 0.025, upper=False)
            hi = _prop_bound(f, judged, 0.025, upper=True)
            rate = '%.4f%%  [%.4f - %.4f%%] 95%% CI' % (100.0 * f / judged, 100.0 * lo, 100.0 * hi)
        print('    %-16s %8d %6d %10d %13d %11d %10d  %s'
              % (label, judged, f, nd, ic, sd, lc, rate))
    watch = [b for pair in SNAP_PAIRS for b in pair]
    if any(bybaud.get(b) for b in watch):
        print('    FAILs at the snap-confusable rates (%s): %s'
              % (' and '.join('%d/%d' % p for p in SNAP_PAIRS),
                 ' '.join('%d Bd %d' % (b, bybaud.get(b, 0)) for b in watch)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--verbose', action='store_true', help='one line per failing cell')
    ap.add_argument('--run', default=None,
                    help='which run in the file: a 1-based index, a tag, or "all" to merge them')
    a = ap.parse_args()

    with open(a.path) as f:
        raw = f.read()
    lines = [ln for ln in raw.split('\n') if ln.strip()]
    # THE SCHEMA IS CHECKED, not assumed. These files outlive the tool that wrote them and a reader that
    # mis-parses a column produces a verdict rather than an error, which is the worse failure.
    head = [ln for ln in lines if ln.startswith('#')]
    if not any(SCHEMA in h for h in head):
        raise SystemExit('REFUSING: %s does not declare schema %s in a header line. Its columns cannot '
                         'be trusted to be the ones this tool reads.' % (a.path, SCHEMA))

    runs = split_runs(lines)
    print('%s holds %d run(s):' % (a.path, len(runs)))
    for i, (tag, body) in enumerate(runs):
        print('  %d  tag=%-10s %5d result row(s)'
              % (i + 1, tag, len([x for x in body if x.startswith('R,')])))
    if a.run is None or a.run == 'last':
        chosen = [runs[-1]] if runs else []
    elif a.run == 'all':
        chosen = runs
    elif a.run.isdigit() and 1 <= int(a.run) <= len(runs):
        chosen = [runs[int(a.run) - 1]]
    else:
        chosen = [r for r in runs if r[0] == a.run]
        if not chosen:
            raise SystemExit('REFUSING: no run in %s matches %r. The runs above are what it holds.'
                             % (a.path, a.run))
    print('  judging: %s' % ', '.join('%s (%d rows)'
                                      % (t, len([x for x in b if x.startswith('R,')]))
                                      for t, b in chosen))
    lines = []
    for _, body in chosen:
        lines.extend(body)
    # ONLY THE FILE'S LAST ROW MAY BE TORN. A power cycle is the stop button, so the final write can be
    # half-finished -- but a short row in the MIDDLE of the file means something else went wrong, and
    # excusing it would hide that. When an earlier run is selected, its last row is followed by more data,
    # so nothing here is allowed to be short.
    torn_ok = lines[-1] if (chosen and runs and chosen[-1] is runs[-1] and lines) else None

    rrows, srows = [], []
    for ln in lines:
        if ln.startswith('#'):
            continue
        f = next(csv.reader([ln]))
        if f[0] == 'R':
            if len(f) - 1 < len(RCOLS):
                # A TORN LAST LINE IS EXPECTED, not an error: a power cycle is the stop button, so the
                # final row can be half-written. Anything earlier is a real problem and says so.
                if ln is torn_ok:
                    print('note: the last row is short (%d of %d fields) -- consistent with the power '
                          'being cut mid-write, which is how a run ends' % (len(f) - 1, len(RCOLS)))
                    continue
                raise SystemExit('REFUSING: a non-final R row has %d of %d fields'
                                 % (len(f) - 1, len(RCOLS)))
            rrows.append(dict(zip(RCOLS, f[1:1 + len(RCOLS)])))
        elif f[0] == 'S':
            srows.append(f)

    npass = nfail = ninc = nsdg = nnodec = nlow = 0
    ev = 0
    byvec = Counter()
    fails = []
    # PER BAND, ALONGSIDE THE TOTALS RATHER THAN INSTEAD OF THEM. The totals are the verdict; these are what
    # a published per-rate claim has to be derived from, and deriving it by hand from --verbose output is how
    # a number ends up in a document with nothing that recomputes it.
    per_band = Counter()
    bybaud = Counter()
    for r in rrows:
        vid = r['vid']
        band = band_of(r['baud'])
        # COUNTED FOR EVERY ROW THAT DECODED, whatever its verdict, because the question it answers is not
        # 'was this right' but 'did the app have grounds to say so'.
        if r['ran'] == 'y' and not r['why'].startswith('SDG:') and lowcred(r):
            per_band[(band, 'lowcred')] += 1
            nlow += 1
        if r['why'].startswith('SDG:'):
            nsdg += 1
            per_band[(band, 'sdg')] += 1
            continue
        if r['ran'] != 'y':
            # NOT A FAILURE BY ITSELF. A refusal on a vector whose class allows it is the documented
            # right answer; the plan's own class decides, exactly as the offline twin does it.
            if SP.expect_for(vid) == 'loud':
                npass += 1
                per_band[(band, 'pass')] += 1
            else:
                nnodec += 1
                per_band[(band, 'nodec')] += 1
                fails.append((r['iter'], r['cell'], vid, r['baud'],
                              'no decode: ' + r['why']))
            continue
        want = payloads(vid)
        got = r['hex'].upper()
        # THE MIS-FRAMED HEAD IS EXCLUDED BEFORE JUDGING, exactly as bench_matrix.py does it. A capture of
        # a gapless looping arb opens mid-stream, so the frames before the first idle gap are resync debris
        # rather than a wrong answer. judge_payload_v takes no headsusp argument -- the caller must trim --
        # and head_damage narrows the region to the frames actually unrecoverable, because headsusp itself
        # is the distance to the first gap and over-claims by up to the whole capture.
        #
        # WITHOUT THIS THE JUDGE INVENTS FAILURES, measured over a 100-lap soak: 1735 cells fail as
        # 'silently wrong' whose payload is byte-exact behind the head -- v77 1154, v78 350, v46 230, j20 1
        # -- against exactly one cell that moves the other way, and that one really does carry a wrong byte
        # (0x53 for 0x57, "Hello, Sorld!"), so the trim corrects it in both directions. 4196 BAD becomes
        # 2462 of 133 297. head_damage's own docstring measured the three regimes over a 4732-capture
        # factorial: trimming by headsusp fails 88, trimming by nothing 194, trimming by this function 6.
        #
        # THE RATE VERDICT IS UNTOUCHED BY DESIGN -- 1144 rate failures before and after -- which is the
        # check that this only ever moves a byte judgement.
        try:
            headsusp = int(r['headsusp'] or 0)
        except (TypeError, ValueError):
            headsusp = 0
        got = got[2 * BU.head_damage(got, headsusp):]
        verdict, detail = 'INCONCLUSIVE', 'no payload for %s' % vid
        # THE LIN BREAK IS FILLED IN BEFORE JUDGING, and only for a vector the manifest calls 'lin'. Every
        # LIN frame opens with a dominant interval no UART character can contain, so the app flags it and
        # the record holds '??' where the oracle holds 0x00 -- correctly on both sides, and impossible for
        # a byte comparison to reconcile. MEASURED on one lap: 129 cells ran with bytes on v61/v62/v63 and
        # ALL 129 failed, with the payload behind each break byte-exact. Over a hundred laps that is
        # ~14 000 phantom failures, which would have been the headline number of the fortnight.
        lin = bool(want) and is_lin(vid)
        for w in (want or []):
            # PER ORACLE, NOT ONCE. Where a vector has two legitimate readings the repair belongs inside
            # this loop: repairing against want[0] and then judging the MUTATED capture against want[1]
            # judges a string neither oracle describes -- bytes inserted for one reading altering the
            # verdict on the other. No LIN vector is multi-oracle today, which is exactly why this would
            # have gone unnoticed until one was.
            g, syn = (BU.lin_repair(got, w) if lin else (got, set()))
            verdict, detail = BU.judge_payload_v(g, w, SP.expect_for(vid), synth=syn)
            if verdict == 'PASS':
                break
        # THE RATE IS JUDGED TOO, and separately: a capture can be byte-exact and still name a rate
        # 2.5 % wrong, which is cluster C and is invisible to any byte comparison.
        ratebad = False
        try:
            rb, cb = float(r['read_baud']), float(r['baud'])
            ratebad = abs(rb / cb - 1) > 0.02
        except ValueError:
            ratebad = True
        if verdict == 'PASS' and not ratebad:
            npass += 1
            per_band[(band, 'pass')] += 1
        elif verdict == 'INCONCLUSIVE':
            ninc += 1
            per_band[(band, 'inc')] += 1
        else:
            nfail += 1
            per_band[(band, 'fail')] += 1
            try:
                bybaud[int(round(float(r['baud'])))] += 1
            except (TypeError, ValueError):
                pass
            byvec[vid] += 1
            fails.append((r['iter'], r['cell'], vid, r['baud'],
                          ('rate %s for %s commanded' % (r['read_baud'], r['baud'])) if ratebad
                          else detail))

    print('%s' % a.path)
    print('  %d result row(s), %d progress row(s)' % (len(rrows), len(srows)))
    print('  %-14s %d' % ('pass', npass))
    print('  %-14s %d' % ('FAIL', nfail))
    print('  %-14s %d   (too few trusted bytes to judge)' % ('inconclusive', ninc))
    print('  %-14s %d   (nothing decoded on a vector that should decode)' % ('no decode', nnodec))
    print('  %-14s %d   (the generator, not the app)' % ('SDG failed', nsdg))
    print('  %-14s %d   (reported a rate/format its own framing contradicts)' % ('low credib', nlow))
    if byvec:
        print('  failures by vector: %s' % ' '.join('%s %d' % kv for kv in byvec.most_common()))
    report_bands(per_band, bybaud)
    if srows:
        last = srows[-1]
        print('  last progress row: %s' % ','.join(last[1:]))
    if a.verbose and fails:
        print()
        # THE LAP AND CELL, ON EVERY LINE. A fortnight is two hundred laps of the same 39 vectors, so
        # 'v77 at 9600 Bd failed' names a cell that occurs two hundred times. With the lap and cell the
        # exact stimulus is reproducible -- every amplitude, offset, wait and vector order is keyed on the
        # iteration -- which is the difference between a failure that can be replayed and one that cannot.
        # LnnnCmmm IS THE PROJECT'S FORMAT for a lap and a cell -- 'C' rather than '#' because these
        # files use '#' to mean a comment line, in the plan's header and the record's own -- the same string the instrument's own
        # status log writes -- so a failure quoted from either place reads the same way.
        for it, cell, vid, baud, why in fails[:80]:
            print('  %-10s %-6s %8s Bd  %s' % ('L%sC%s' % (it, cell), vid, baud, why[:100]))
    bad = nfail + nnodec
    print()
    if bad:
        print('%d BAD of %d judged' % (bad, npass + bad))
        return 1
    print('0 BAD of %d judged' % (npass + bad))
    return 0


if __name__ == '__main__':
    sys.exit(main())

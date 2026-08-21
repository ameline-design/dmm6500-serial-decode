#!/usr/bin/env python3
"""What one sweep iteration tests, derived from its iteration number alone.

THE POINT IS THAT ITERATION 129 IS REACHABLE WITHOUT RUNNING 128 FIRST. Every choice here comes from
a KEYED substream -- mt19937 seeded with {MAGIC, iteration, purpose, index} -- rather than from one
running generator, so a plan rebuilds identically from its number and a single cell can be replayed
on its own however many cells failed or were skipped before it. A soak whose failures cannot be
replayed exactly is a soak that manufactures ghosts.

WHAT VARIES PER ITERATION, and nothing else does:
  * the ORDER vectors are loaded in, so a state leak out of one vector stops looking like a defect
    in whichever vector always follows it
  * the NON-STANDARD rate drawn in each gap between standard rates
  * the WAIT before each capture, per cell

WHAT IS FIXED: the 22 standard rates, which every iteration tests on every vector.

THE RATE RANGE IS [300, 250000] AND BOTH ENDS ARE DELIBERATE. 250000 is sdec.maxbaud, above which the
detector refuses outright; 300 is the bottom because 110 costs 8 s of capture for a rate nothing on
this bench speaks. FRAME MODE ONLY: above 165563 Bd sdec.fs_for_burst returns nil, so the streaming
paths cannot record 172800 and up at all, and only frame reaches 250000.

A UNIFORM DRAW CANNOT FIND THE LADDER CLIFFS, which is why it is not the only rule. sdec.pick_fs
snaps UP through a coarse ladder, so below 125 kBd samples/bit is a sawtooth whose MINIMUM in each
step sits at baud = floor(fs/8) -- 312, 625, 1250 ... 80000, 125000. Those are where the app is
closest to being confidently wrong, and a uniform draw lands on one with probability about zero.
So a gap containing an edge yields that edge one time in three. Above 125 kBd fs is pinned at
1 MSa/s and samples/bit falls smoothly to 4.00, so there is no cliff up there and uniform is right.

    python3 tools/soakplan.py --iteration 129              # the whole plan, no instrument
    python3 tools/soakplan.py --iteration 129 --rates      # just the rate list
    python3 tools/soakplan.py --iteration 1 --vectors 4    # a seeded subset, for a smoke lap
    python3 tools/soakplan.py --selftest                   # properties, no instrument
"""
import argparse
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mt19937 import MT19937                                      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 'SERL'. A fixed salt so iteration 1 is not simply seed 1, and so another seeded suite keyed on the
# same iteration number does not draw the same stream.
MAGIC = 0x5345524C

# One per kind of decision. Distinct purposes keep the streams independent: without them the wait for
# cell 0 and the rate for gap 0 would be the same number.
P_ORDER, P_RATE, P_WAIT, P_SUBSET = 1, 2, 3, 4

BAUD_LO, BAUD_HI = 300, 250000
# 10 byte-times, which is 100 bit-times: one continuous draw over that span randomises the byte the
# capture lands on AND the bit AND the phase within the bit, because it is not quantised to any of
# them. Scaled by baud, so it costs 0.4 min across a whole sweep where a flat 1 s costs 14.7 -- and
# it lands where it is needed: below ~20 kBd socket jitter is smaller than a byte time and cannot
# move the offset at all, while above it jitter alone already scatters the phase by tens of bytes.
WAIT_BYTE_TIMES = 10.0
BITS_PER_BYTE = 10.0

# One chance in three, so a gap with an edge still spends most iterations exploring elsewhere.
EDGE_ODDS = 3

# WHAT A VECTOR IS ENTITLED TO DO WHEN SWEPT OFF ITS NATIVE RATE.
#
# Most vectors are clean traffic and must decode byte-exact at every rate in the range. A few are
# deliberate impairments, and holding those to byte-exactness at 43 rates would paint every lap red
# and destroy the soak's signal -- but excusing them entirely would let a real defect hide behind
# "that one is allowed to fail". So there are two classes and the difference between them is the
# distinction this project cares most about:
#
#   'exact'  must decode byte-exact. Anything else is a defect.
#   'loud'   MAY fail, and MUST NOT BE SILENTLY WRONG. Refusing, or failing with flags raised, is a
#            pass. Returning confident bytes that are not the payload is a failure for these too.
#
# A vector earns 'loud' only by being built to break something:
VECTOR_EXPECT = {
    # Impulse spikes at the amplitude ceiling: +/-3.0 V stacking to 9.3 V on a 3.3 V line. Whether a
    # given rate's sampling instants land on the spikes is a function of the rate, so which rates
    # survive is not knowable in advance.
    'v47': 'loud',
    # BOTH drift vectors, and 48a is the interesting one. Its 0.6 V is inside tolerance AT ITS NATIVE
    # RATE; swept two decades away, the drift-to-window ratio changes and the two logic levels stop
    # being the two densest amplitudes -- so the app reports "baseline unstable, only 8 % of samples
    # sit at a logic level" and declines. Declining is the right answer to an unreadable signal, so it
    # counts as one; a confident wrong byte here still fails, which is the whole point of the class.
    # 48b drifts beyond tolerance by construction.
    'v48a': 'loud', 'v48b': 'loud',
    # 20 % jitter is past what the decoder claims; 2 % and 10 % are inside it and stay 'exact'.
    'j20': 'loud',
    # LIN carries deliberate framing violations -- the break field is a dominant interval no UART
    # frame can contain -- so a UART judge seeing flagged frames there is right, not wrong.
    'v61': 'loud', 'v62': 'loud', 'v63': 'loud',
}


def expect_for(vid):
    return VECTOR_EXPECT.get(vid, 'exact')


def _tsp_array(name):
    """Read a numeric table out of tsp/serial_core.tsp. THE TSP FILE IS THE ONE SOURCE: a copy of
    either list here is a copy to forget to update when the ladder changes."""
    with open(os.path.join(ROOT, 'tsp', 'serial_core.tsp')) as f:
        src = f.read()
    m = re.search(r'sdec\.%s\s*=\s*\{(.*?)\}' % name, src, re.S)
    if not m:
        raise SystemExit('soakplan: sdec.%s not found in tsp/serial_core.tsp' % name)
    return [int(x) for x in re.findall(r'\d+', m.group(1))]


def rate_ladder():
    return _tsp_array('rates')


def standard_rates():
    return [b for b in _tsp_array('stdbaud') if BAUD_LO <= b <= BAUD_HI]


def pick_fs(baud, ladder, want=8):
    """sdec.pick_fs: the lowest LISTED rate giving at least `want` samples per bit."""
    for r in ladder:
        if r >= baud * want:
            return r
    return ladder[-1]


def ladder_edges(ladder):
    """The baud in each ladder step with the FEWEST samples per bit, i.e. floor(fs/8).

    floor, not round: at fs = 2500 the exact edge is 312.5, and baud 312 still snaps to 2500 for
    8.013 samples/bit while 313 snaps up to 5000 for 15.97. The minimum of the step -- the case worth
    testing -- is the integer just below the exact edge.
    """
    return sorted({int(math.floor(r / 8.0)) for r in ladder
                   if BAUD_LO <= math.floor(r / 8.0) <= BAUD_HI})


def interstitial(iteration, gap_index, lo, hi, edges):
    """One non-standard rate strictly inside (lo, hi). -> (baud, why)

    LOG-UNIFORM, not linear. What breaks a decode is the samples/bit ratio and where the ladder
    snaps, and both are multiplicative, so a uniform draw in a wide gap sits near the top of it in
    ratio terms and under-tests the bottom.
    """
    g = MT19937([MAGIC, iteration, P_RATE, gap_index])
    inside = [e for e in edges if lo < e < hi]
    if inside and g.below(EDGE_ODDS) == 0:
        return inside[g.below(len(inside))], 'edge'
    u = g.float()
    baud = int(round(math.exp(math.log(lo) + u * (math.log(hi) - math.log(lo)))))
    # Clamped OFF the endpoints: a draw landing on a standard rate would silently test it twice and
    # report one gap as covered when it was not.
    if baud <= lo:
        baud = lo + 1
    if baud >= hi:
        baud = hi - 1
    return baud, 'rand'


def rates_for(iteration):
    """-> list of (baud, kind) sorted ascending; kind is 'std', 'rand' or 'edge'.

    THE SAME RATE LIST FOR EVERY VECTOR IN THE ITERATION, which is what makes a sweep a sweep: one
    rate list, every vector, so a rate that fails on one vector and not another says something about
    the vector rather than about which draw it happened to get.
    """
    std = standard_rates()
    edges = ladder_edges(rate_ladder())
    out = [(b, 'std') for b in std]
    for i in range(len(std) - 1):
        lo, hi = std[i], std[i + 1]
        if hi - lo < 2:
            continue
        baud, why = interstitial(iteration, i, lo, hi, edges)
        out.append((baud, why))
    return sorted(out)


def vector_order(iteration, vectors):
    """The load order for this iteration. Shuffled, so load-order effects decorrelate from vector
    identity across iterations. FREE: selecting a waveform costs the same in any order."""
    g = MT19937([MAGIC, iteration, P_ORDER, 0])
    return g.shuffle(list(vectors))


def vector_subset(iteration, vectors, k):
    """A seeded k of the vectors, for a lap that has to finish in minutes rather than hours.

    Taken from the FRONT of this iteration's own order, so a subset lap is a genuine prefix of the
    full lap and not a third thing with its own ordering to reason about.
    """
    order = vector_order(iteration, vectors)
    if k is None or k >= len(order):
        return order
    return order[:max(1, k)]


def wait_s(iteration, vi, ri, baud):
    """Seconds to idle before the capture, for cell (vector index, rate index).

    KEYED, NOT CONSUMED IN ORDER, so replaying one cell does not depend on how many ran before it.
    The value is reproducible; THE PHASE IT PRODUCES ON HARDWARE IS NOT -- scheduling jitter around
    the wait is larger than the wait itself above about 20 kBd. That is deliberate, and it is why a
    failure has to record the MEASURED head alignment: the seed reproduces the schedule, and only
    the measurement reproduces the case.
    """
    g = MT19937([MAGIC, iteration, P_WAIT, vi, ri])
    return g.float() * WAIT_BYTE_TIMES * BITS_PER_BYTE / float(baud)


def signature(iteration, vectors, nvectors=None):
    """The cheap half of a plan: the order and the rate list. -> (tuple, tuple)

    Exists because proving `plan(n)` is a pure function of n means comparing many iterations, and the
    per-cell waits are 1763 generator seedings apiece -- 0.46 s, nothing against a lap, but a minute
    if 129 iterations are walked to make the point. Order and rates carry the same property at 23
    seedings, and individual waits are checked directly instead.
    """
    return (tuple(vector_subset(iteration, vectors, nvectors)), tuple(rates_for(iteration)))


def plan(iteration, vectors, nvectors=None):
    """-> dict with the whole iteration: order, rates, and the wait for every cell."""
    order = vector_subset(iteration, vectors, nvectors)
    rates = rates_for(iteration)
    cells = []
    for vi, vid in enumerate(order):
        for ri, (baud, kind) in enumerate(rates):
            cells.append({'vi': vi, 'ri': ri, 'vector': vid, 'baud': baud, 'kind': kind,
                          'wait_s': wait_s(iteration, vi, ri, baud)})
    return {'iteration': iteration, 'magic': MAGIC, 'order': order, 'rates': rates, 'cells': cells}


def estimate_secs(rates, nvec, depth=20000, per_cell=4.9):
    """Capture time is arithmetic; per_cell is measured overhead. Reported so a lap that will not fit
    the budget is known before it starts rather than after it is truncated.

    per_cell IS MEASURED ON THIS SUITE, not borrowed from another one: 43 cells of one vector take
    239 s, which is 5.57 s a cell; net of capture and wait that is 4.9 s of overhead each.
    A cell is more than its capture -- the app probes down the rate ladder to find the traffic, which
    is one or two extra acquisitions, and then decodes twice under auto-detect.
    """
    ladder = rate_ladder()
    cap = sum(float(depth) / pick_fs(b, ladder) for b, _ in rates)
    wait = sum(0.5 * WAIT_BYTE_TIMES * BITS_PER_BYTE / b for b, _ in rates)
    return (cap + wait + per_cell * len(rates)) * nvec


# ---------------------------------------------------------------------------- self-check


def selftest():
    from vector_names import MAP
    vecs = sorted(MAP.keys())
    bad = []

    def ck(cond, what):
        if not cond:
            bad.append(what)
            print('  FAIL  %s' % what)

    std = standard_rates()
    ck(len(std) == 22, '22 standard rates in range, got %d' % len(std))
    ck(min(std) == 300 and max(std) == 250000, 'range ends are 300 and 250000')

    # Pure function of the iteration number: the whole point.
    a = plan(129, vecs)
    ck(a == plan(129, vecs), 'plan(129) rebuilds identically, cells and waits included')
    sig = signature(129, vecs)
    ck(signature(130, vecs)[1] != sig[1], 'iteration 130 draws different interstitials')
    ck(signature(130, vecs)[0] != sig[0], 'iteration 130 uses a different vector order')
    walked = None
    for it in range(1, 130):
        walked = signature(it, vecs)
    ck(walked == sig, 'walking 1..129 lands on the same plan as addressing 129 directly')
    # The waits carry the same property, spot-checked rather than walked: 129 iterations of the full
    # cell table is 227 000 generator seedings for a point three cells make just as well.
    for vi, ri in ((0, 0), (17, 22), (40, 42)):
        direct = wait_s(129, vi, ri, 9600)
        for it in range(1, 130):
            last = wait_s(it, vi, ri, 9600)
        ck(last == direct, 'cell (%d,%d): walking to 129 gives the value 129 gives directly'
           % (vi, ri))

    # Rates: inside the range, no duplicates, one per gap, and none landing on a standard rate.
    for it in (1, 7, 129, 5000):
        rs = rates_for(it)
        bauds = [x[0] for x in rs]
        ck(len(bauds) == len(set(bauds)), 'iter %d: no duplicate rates' % it)
        ck(all(BAUD_LO <= x <= BAUD_HI for x in bauds), 'iter %d: every rate in range' % it)
        ck(len(rs) == 43, 'iter %d: 22 standard + 21 interstitial = 43, got %d' % (it, len(rs)))
        ns = [x for x in rs if x[1] != 'std']
        ck(all(x[0] not in std for x in ns), 'iter %d: no interstitial landed on a standard rate' % it)
        for i in range(len(std) - 1):
            got = [x for x in ns if std[i] < x[0] < std[i + 1]]
            ck(len(got) == 1, 'iter %d: exactly one interstitial in (%d,%d), got %d'
               % (it, std[i], std[i + 1], len(got)))

    # The edge rule fires sometimes and not always.
    edges = set(ladder_edges(rate_ladder()))
    hits = [sum(1 for x in rates_for(it) if x[1] == 'edge') for it in range(1, 61)]
    ck(sum(hits) > 0, 'the ladder-edge rule fires across 60 iterations')
    ck(min(hits) < max(hits), 'the number of edges drawn varies by iteration')
    ck(all(x[0] in edges for it in range(1, 61) for x in rates_for(it) if x[1] == 'edge'),
       'every rate marked edge really is floor(fs/8)')
    # And an edge is genuinely the worst samples/bit in its step, which is why it is worth forcing.
    ladder = rate_ladder()
    for e in sorted(edges)[:6]:
        sab, sab_next = pick_fs(e, ladder) / float(e), pick_fs(e + 1, ladder) / float(e + 1)
        ck(sab < sab_next, 'baud %d has fewer samples/bit than %d (%.3f vs %.3f)'
           % (e, e + 1, sab, sab_next))

    # Order is a permutation, subsets are prefixes of it.
    order = vector_order(129, vecs)
    ck(sorted(order) == sorted(vecs), 'the order is a permutation of the vectors')
    ck(vector_subset(129, vecs, 4) == order[:4], 'a subset is a prefix of the full order')
    ck(vector_subset(129, vecs, 999) == order, 'a subset larger than the set is the whole set')

    # Waits: keyed, in range, and scaled by baud.
    ck(wait_s(129, 3, 4, 9600) == wait_s(129, 3, 4, 9600), 'a cell wait is reproducible')
    ck(wait_s(129, 3, 4, 9600) != wait_s(129, 3, 5, 9600), 'adjacent cells draw different waits')
    ck(wait_s(130, 3, 4, 9600) != wait_s(129, 3, 4, 9600), 'a new iteration redraws the wait')
    for baud in (300, 9600, 250000):
        w = [wait_s(129, 0, k, baud) for k in range(200)]
        cap = WAIT_BYTE_TIMES * BITS_PER_BYTE / baud
        ck(min(w) >= 0 and max(w) < cap, '%d Bd: waits inside [0, %.4f s)' % (baud, cap))
        ck(max(w) > 0.6 * cap, '%d Bd: the draw reaches the top of its span' % baud)

    print('\n%s' % ('%d FAILED' % len(bad) if bad else 'selftest: all properties hold'))
    return 1 if bad else 0


def emit_lua(iteration, nvectors=None):
    """The whole plan as a Lua table, for the offline twin to dofile.

    WHY EMIT RATHER THAN RECOMPUTE. mt19937.lua is proven to match the Python word for word, so the
    Lua side COULD draw its own. It must not: the plan is more than its draws -- log-uniform placement
    inside each gap, the ladder-edge substitution, the standard-rate list read out of the TSP source --
    and a second implementation of that is a second thing to get subtly different. One generator with
    two ports is a checkable claim; one plan with two implementations is a bug waiting for a night
    when the two disagree and both look right.

    Everything the offline side needs to reconstruct a cell travels with it: the amplitude and offset
    the file was encoded for, its samples per bit, and the expected bytes -- so the twin never has to
    re-derive a figure the hardware sweep took from the manifest.
    """
    import csv as _csv
    from vector_names import MAP as _MAP
    with open(os.path.join(ROOT, 'out', 'vectors', 'manifest.tsv')) as f:
        rows = {r['file'].replace('.bin', ''): r for r in _csv.DictReader(f, delimiter='\t')}
    p = plan(iteration, sorted(_MAP.keys()), nvectors)
    out = ['-- generated by tools/soakplan.py --emit-lua; do not edit', 'return {',
           '  iteration = %d,' % iteration, '  vectors = {']
    for vi, vid in enumerate(p['order']):
        r = rows.get(vid) or {}
        # BOTH legitimate readings travel, because three vectors are framed ambiguously by
        # construction and the app is right either way -- see bench_matrix.plan_payloads. exp_hex is
        # what the self-check DECODED; the .txt is what was ENCODED, and for those three they differ
        # by bit 7. hex2 is empty wherever there is only one reading.
        hexs = (r.get('exp_hex') or '').replace(' ', '').upper()
        hex2 = ''
        txt = os.path.join(ROOT, 'out', 'vectors', vid + '.txt')
        if os.path.exists(txt):
            with open(txt, 'rb') as fh:
                alt = fh.read().hex().upper()
            if alt and alt != hexs:
                hex2 = alt
        out.append("    {id = '%s', amp = %s, ofst = %s, spb = %s, npts = %s, class = '%s', "
                   "hex = '%s', hex2 = '%s'},"
                   % (vid, r.get('amp_vpp') or 10.0, r.get('ofst_v') or 0,
                      r.get('spb') or 10, r.get('npts') or 0, expect_for(vid), hexs, hex2))
    out.append('  },')
    out.append('  rates = {')
    for baud, kind in p['rates']:
        out.append("    {%d, '%s'}," % (baud, kind))
    out.append('  },')
    # waits[vi][ri], in seconds, keyed exactly as the hardware sweep keys them.
    out.append('  waits = {')
    nr = len(p['rates'])
    for vi in range(len(p['order'])):
        vals = ', '.join('%.9g' % wait_s(iteration, vi, ri, p['rates'][ri][0]) for ri in range(nr))
        out.append('    {%s},' % vals)
    out.append('  },')
    out.append('}')
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emit-lua', action='store_true',
                    help='print the plan as a Lua table for tools/sweep_plan.lua')
    ap.add_argument('--iteration', type=int, default=1)
    ap.add_argument('--vectors', type=int, default=None, help='a seeded subset of this many vectors')
    ap.add_argument('--rates', action='store_true', help='print only the rate list')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.emit_lua:
        sys.stdout.write(emit_lua(a.iteration, a.vectors))
        return 0

    from vector_names import MAP
    vecs = sorted(MAP.keys())
    p = plan(a.iteration, vecs, a.vectors)
    if a.rates:
        for baud, kind in p['rates']:
            print('%7d  %s' % (baud, kind))
        return 0
    secs = estimate_secs(p['rates'], len(p['order']))
    print('iteration %d   %d vectors x %d rates = %d cells   estimated %.1f min'
          % (a.iteration, len(p['order']), len(p['rates']), len(p['cells']), secs / 60.0))
    print('\nrates (%d standard, %d drawn, %d forced to a ladder edge):'
          % (sum(1 for _, k in p['rates'] if k == 'std'),
             sum(1 for _, k in p['rates'] if k == 'rand'),
             sum(1 for _, k in p['rates'] if k == 'edge')))
    ladder = rate_ladder()
    for baud, kind in p['rates']:
        fs = pick_fs(baud, ladder)
        print('  %7d %-5s fs %7d  %5.2f sa/bit%s'
              % (baud, kind, fs, fs / float(baud), '   <- ladder edge' if kind == 'edge' else ''))
    print('\nvector order:')
    print('  %s' % ' '.join(p['order']))
    return 0


if __name__ == '__main__':
    sys.exit(main())

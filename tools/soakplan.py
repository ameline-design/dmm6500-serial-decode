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
P_ORDER, P_RATE, P_WAIT, P_SUBSET, P_AMP, P_OFST = 1, 2, 3, 4, 5, 6

# THE VERTICAL AXES. Amplitude and DC offset are swept per cell rather than per waveform, which costs
# nothing: both are SCPI writes folded into the settle already paid, and the attenuator relay is rated
# 10 M no-load cycles against ~1700 cells a lap.
#
# Scaled against each vector's OWN reference amplitude, not a global span. The 41 vectors do not share a
# codeword span -- 35 sit at 33 % of full scale, the impairment vectors at 40-53 % because their spikes
# and drift need the room -- so one global amplitude would shrink or clip them unequally. Scaling each
# vector's validated geometry keeps every waveform the shape the scope measured.
#
# 0.5 takes a clean vector's 3.3 V swing to 1.65 V, well above the ~60 mV where the decoder fails by
# design, and 1.6 is bounded by the generator's 20 Vpp ceiling anyway (v47 is already there, so its
# scale is clamped down to 1.0).
# THE SWING IS DRAWN AS A TARGET SPAN IN VOLTS, not as a scale of each vector's own span. A scale
# bottoms out at 1.65 V p-p on the 3.3 V vectors and clusters every cell mid-range; a target span
# spreads them evenly and reaches the 0.45 V end a hardware hacker's line actually sits at.
SWING_LO, SWING_HI = 0.45, 8.0
AMP_SCALE_LO, AMP_SCALE_HI = 0.5, 1.6      # kept for signature(); the span draw supersedes them
SDG_MAX_VPP = 20.0
# Keep the whole band inside this, which is inside both the generator's +/-10 V and the DMM's fixed
# 10 V range. The margin absorbs the offset quantisation and leaves the signal unclipped at both rails.
def _tsp_number(name):
    """A scalar constant read out of the TSP source. -> float

    READ, NOT COPIED, for the same reason the standard-rate list is: a number duplicated here silently
    stops matching the decoder the day someone tunes it in tsp/, and the stimulus would then be drawn
    against a threshold the app no longer uses.
    """
    import re as _re
    with open(os.path.join(ROOT, 'tsp', 'serial_core.tsp')) as f:
        m = _re.search(r'^sdec\.' + name + r'\s*=\s*([0-9.]+)', f.read(), _re.M)
    if m is None:
        raise SystemExit('soakplan: cannot find sdec.%s in tsp/serial_core.tsp' % name)
    return float(m.group(1))


# The level below which sig_levels treats an idle level as sitting at ground. Straddling it in BOTH
# directions is what makes the app read a line as RS-232 -- see amp_ofst_for.
FLATFLOOR = _tsp_number('flatfloor')

V_RAIL = 9.5
# Decimals the amplitude and offset are written with. The values must be quantised BEFORE the safe
# interval is derived from them, or a rounded offset lands outside the interval it came from.
Q_DIGITS = 3

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


def amp_ofst_u(iteration, vi, ri):
    """The two vertical draws for cell (vector index, rate index). -> (u_amp, u_ofst), each in [0,1).

    UNIT-INTERVAL, NOT VOLTS. The clip-safe range depends on the vector's own codeword span and
    reference amplitude, which live in the manifest -- so the draw stays here where it is pure and
    replayable in Lua, and the mapping to volts stays in bench_matrix where the manifest already is.
    See amp_ofst_for() there.

    Keyed like wait_s, so one cell replays without running the cells before it.
    """
    g = MT19937([MAGIC, iteration, P_AMP, vi, ri])
    ua = g.float()
    g = MT19937([MAGIC, iteration, P_OFST, vi, ri])
    return ua, g.float()


_MROWS = None


def _manifest_rows():
    """manifest.tsv keyed by vector id, read once."""
    global _MROWS
    if _MROWS is None:
        import csv as _csv
        with open(os.path.join(ROOT, 'out', 'vectors', 'manifest.tsv')) as f:
            _MROWS = {r['file'].replace('.bin', ''): r for r in _csv.DictReader(f, delimiter='\t')}
    return _MROWS


def _cw_span(vid):
    """A vector's codeword extremes, SIGNED, derived from the manifest. -> (min_cw, max_cw)

    GEN_VOLTS is `ofst + c / 32767 * (amp / 2)`, so the words follow from min_v and max_v -- checked
    against every .bin and agreeing on all 41. Derived rather than read because reading the words
    unsigned turns a small negative excursion into a near-full-scale one: the drift vectors dip below
    zero, and 45 % of full scale then reads as 100 %, which is the difference between a vector with
    headroom and one with none.
    """
    r = _manifest_rows().get(vid) or {}
    amp = float(r.get('amp_vpp') or 10.0)
    ofst = float(r.get('ofst_v') or 0.0)
    k = 32767.0 / (amp / 2.0)
    return int(round((float(r.get('min_v') or 0.0) - ofst) * k)), \
        int(round((float(r.get('max_v') or 0.0) - ofst) * k))


def amp_ofst_for(vid, u_amp, u_ofst):
    """Map two unit draws to a CLIP-SAFE amplitude and offset. -> (amp_vpp, ofst_v, note)

    ONE IMPLEMENTATION, THREE CONSUMERS: the hardware sweep, the emitted plan the offline twin reads,
    and the bounds test. A second copy of this arithmetic is a second thing to get subtly different,
    and the difference would show up as the twin disagreeing with hardware for a reason that is neither.

    The amplitude scales the vector's OWN reference, clamped to the generator's ceiling. The offset is
    then placed inside whatever range keeps both extremes within +/-V_RAIL at that amplitude, so a
    vector already near the rail gets a narrow range rather than a clipped waveform.
    """
    lo, hi = _cw_span(vid)
    r = _manifest_rows().get(vid) or {}
    ref_amp = float(r.get('amp_vpp') or 10.0)
    ref_span = float(r.get('max_v') or 0.0) - float(r.get('min_v') or 0.0)
    target = SWING_LO + u_amp * (SWING_HI - SWING_LO)
    amp = ref_amp * target / max(ref_span, 1e-9)
    # QUANTISE BEFORE THE INTERVAL IS COMPUTED, not after. Rounding an offset that already sat exactly
    # on the rail pushes it over, and assert_unclipped then kills the whole run: measured on v48b and
    # v61 at u_ofst -> 1, which a long soak reaches. The interval must be derived from the values that
    # will actually be written.
    amp = round(min(amp, SDG_MAX_VPP), Q_DIGITS)
    note = ''
    for _ in range(2):
        half = amp / 2.0
        dlo = -V_RAIL - lo / 32767.0 * half
        dhi = V_RAIL - hi / 32767.0 * half
        if dhi >= dlo:
            break
        # No offset fits at this amplitude. Shrink rather than clip: a clipped waveform is a different
        # stimulus that still reports as the one that was asked for.
        amp = round(2.0 * V_RAIL * 2.0 * 32767.0 / max(hi - lo, 1), Q_DIGITS)
        note = 'amplitude reduced to keep the band inside +/-%.1f V' % V_RAIL
    # Quantise the offset, then pull it back inside the interval -- rounding may only ever move it
    # toward the middle, never past an edge.
    # A SINGLE-SUPPLY LINE MAY NOT BE DRAWN STRADDLING GROUND. sig_levels decides polarity from the
    # LEVELS when no run in the window reaches ten bit times, and reads lo < -flatfloor with
    # hi > +flatfloor as RS-232 at line levels, marking at its NEGATIVE level. That is correct for a
    # real ground-straddling line and wrong for a 0..6.6 V logic waveform this draw shifted there, and
    # the decode comes back inverted: right rate, right format, self-consistent bytes matching nothing.
    #
    # MEASURED before this constraint existed: 17.3 % of cells were driven straddling ground and they
    # accounted for 86.8 % of every offline failure -- v71, v76 and v92 at 100 % of theirs. The app was
    # right every time; the stimulus could not exist.
    #
    # Only vectors whose own rendering is single-supply are constrained. A vector that genuinely
    # straddles ground in the file is RS-232-shaped by construction and must keep being drawn that way.
    # A SINGLE-SUPPLY LINE MAY NOT BE DRAWN STRADDLING GROUND. sig_levels decides polarity from the
    # LEVELS when no run in the window reaches ten bit times, and reads lo < -flatfloor with
    # hi > +flatfloor as RS-232 at line levels, marking at its NEGATIVE level. That is correct for a
    # real ground-straddling line and wrong for a 0..6.6 V logic waveform this draw shifted there: the
    # decode comes back inverted -- right rate, right format, self-consistent bytes matching nothing.
    #
    # MEASURED before this constraint: 17.3 % of cells were driven straddling ground and they accounted
    # for 86.8 % of every offline failure. The app was right each time; the stimulus could not exist.
    #
    # ONLY THE STRADDLING WINDOW IS REMOVED, NOT EVERYTHING BELOW IT. Straddling needs BOTH levels
    # clear of ground, so it is the open interval (B, A) with
    #     A = -FLATFLOOR - lo/32767*half     (above this the low level is >= -FLATFLOOR)
    #     B = +FLATFLOOR - hi/32767*half     (below this the high level is <= +FLATFLOOR)
    # A wholly-negative band is legitimate and decodes -- measured, offset -6.5 V passes where -3.6 V
    # fails -- so cutting the whole range below A threw away real coverage: 57.5 % of the interval on
    # some vectors. The draw maps onto [dlo, B] + [A, dhi] instead, preserving both valid regions.
    # Vectors whose own rendering already goes negative are RS-232-shaped by construction and exempt.
    keep = None
    if float(r.get('min_v') or 0.0) >= 0.0:
        half_c = amp / 2.0
        a_edge = -FLATFLOOR - lo / 32767.0 * half_c
        b_edge = FLATFLOOR - hi / 32767.0 * half_c
        if a_edge > b_edge:                       # a straddling window exists at this amplitude
            lower = (dlo, min(b_edge, dhi))
            upper = (max(a_edge, dlo), dhi)
            keep = [seg for seg in (lower, upper) if seg[1] > seg[0]]
            if not keep:
                keep = None                       # nothing legal; fall through to the plain mapping
    if keep is not None:
        total = sum(hi_s - lo_s for lo_s, hi_s in keep)
        want = u_ofst * total
        ofst = keep[-1][1]
        for lo_s, hi_s in keep:
            if want <= hi_s - lo_s:
                ofst = lo_s + want
                break
            want = want - (hi_s - lo_s)
        ofst = round(ofst, Q_DIGITS)
    else:
        ofst = round(dlo + u_ofst * max(0.0, dhi - dlo), Q_DIGITS)
    q = 10.0 ** -Q_DIGITS
    if ofst > dhi:
        ofst = math.floor(dhi / q) * q
    if ofst < dlo:
        ofst = math.ceil(dlo / q) * q
    return amp, round(ofst, Q_DIGITS), note


def assert_unclipped(vid, amp, ofst):
    """Refuse a waveform whose band leaves the rails. -> (vmin, vmax)

    Checked against the same formula the mapping used, immediately before the write: a blind write is
    how a clipped stimulus gets filed as a clean one.
    """
    lo, hi = _cw_span(vid)
    vmin = ofst + lo / 32767.0 * (amp / 2.0)
    vmax = ofst + hi / 32767.0 * (amp / 2.0)
    if amp > SDG_MAX_VPP + 1e-6 or vmin < -V_RAIL - 1e-6 or vmax > V_RAIL + 1e-6:
        raise SystemExit('REFUSING %s at %.3f Vpp offset %.3f V: band %.3f..%.3f V leaves +/-%.1f V'
                         % (vid, amp, ofst, vmin, vmax, V_RAIL))
    return vmin, vmax


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


def _MAP_KEYS():
    from vector_names import MAP as _M
    return _M.keys()


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
    # THE VERTICAL AXES. Nothing asserted these before, and the only guard anywhere was
    # assert_unclipped at the hardware write site, which catches a clipped band but not a wrong range.
    spans, strad, nvcell = [], 0, 0
    for it in (1, 7, 41):
        pv = plan(it, sorted(_MAP_KEYS()), None)
        for vi, vid in enumerate(pv['order']):
            r = _manifest_rows()[vid]
            ref = float(r['amp_vpp'])
            rspan = float(r['max_v']) - float(r['min_v'])
            for ri in range(len(pv['rates'])):
                ua, uo = amp_ofst_u(it, vi, ri)
                amp, ofst, _note = amp_ofst_for(vid, ua, uo)
                assert_unclipped(vid, amp, ofst)
                nvcell += 1
                spans.append(rspan * amp / ref)
                if float(r['min_v']) >= 0.0:
                    lo = ofst + float(r['min_v']) / (ref / 2.0) * (amp / 2.0)
                    hi = ofst + float(r['max_v']) / (ref / 2.0) * (amp / 2.0)
                    if lo < -FLATFLOOR and hi > FLATFLOOR:
                        strad += 1
    ck(min(spans) >= SWING_LO - 0.01 and max(spans) <= SWING_HI + 0.01,
       'every drawn span is inside [%.2f, %.2f], got %.3f..%.3f'
       % (SWING_LO, SWING_HI, min(spans), max(spans)))
    # REACHES BOTH ENDS. A draw that silently collapsed to a narrow band would pass the bound above
    # while testing almost nothing, and would look like full coverage in the log.
    ck(min(spans) < SWING_LO + 0.2, 'the draw reaches the bottom of the range, got %.3f' % min(spans))
    ck(max(spans) > SWING_HI - 0.5, 'the draw reaches the top of the range, got %.3f' % max(spans))
    # NO SINGLE-SUPPLY VECTOR STRADDLES GROUND. sig_levels would read it as RS-232 and invert the
    # decode -- correctly, on a stimulus that cannot exist. Measured before the constraint: 17.3 % of
    # cells, and 86.8 % of every offline failure.
    ck(strad == 0, 'no single-supply vector is drawn straddling ground, got %d of %d cells'
       % (strad, nvcell))

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
    # amps[vi][ri] and ofsts[vi][ri]. WITHOUT THESE THE TWIN REPLAYS THE WRONG SIGNAL: the hardware
    # sweep now draws a per-cell amplitude and offset, so a twin using the reference amplitude would
    # decode a waveform the generator never played and disagree for a reason that is neither hardware
    # nor app.
    for name, idx in (('amps', 0), ('ofsts', 1)):
        out.append('  %s = {' % name)
        for vi, vid in enumerate(p['order']):
            vals = []
            for ri in range(nr):
                ua, uo = amp_ofst_u(iteration, vi, ri)
                vals.append('%.9g' % amp_ofst_for(vid, ua, uo)[idx])
            out.append('    {%s},' % ', '.join(vals))
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

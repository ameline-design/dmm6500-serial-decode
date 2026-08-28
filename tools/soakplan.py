#!/usr/bin/env python3
"""What one sweep iteration tests, derived from its iteration number and its vector set.

THE POINT IS THAT ITERATION 129 IS REACHABLE WITHOUT RUNNING 128 FIRST. Every choice here comes from
a KEYED substream -- mt19937 seeded with {MAGIC, iteration, purpose, index} -- rather than from one
running generator, so a plan rebuilds identically from its number and a single cell can be replayed
on its own however many cells failed or were skipped before it. A soak whose failures cannot be
replayed exactly is a soak that manufactures ghosts.

THE ITERATION IS NOT THE WHOLE IDENTITY, and this is the trap: the `index` in those keys is the
vector's POSITION IN THE ORDER, and the order is a shuffle of whatever vector list it was handed. So
--skip-vectors is drawn on too -- drop two waveforms and every remaining cell gets a different
amplitude, a different offset and a different wait. See plan_order, and HW_SKIP for the set every
hardware lap leaves out. --check-log measures the pairing against a finished soak's own record, which
is the only oracle available for it: the two plans are internally consistent either way.

WHAT VARIES PER ITERATION, and nothing else does:
  * the ORDER vectors are loaded in, so a state leak out of one vector stops looking like a defect
    in whichever vector always follows it
  * the NON-STANDARD rate drawn in each gap between standard rates
  * the WAIT before each capture, per cell
  * the AMPLITUDE and DC OFFSET of each cell

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
    python3 tools/soakplan.py --iteration 1 --skip-vectors v95,v96 \
            --check-log out/soak/<dir>/lap0001-FAILED.log  # does the twin replay that lap?
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
# The per-lap choice of WHICH random vectors to play. Its own purpose constant, so adding it does
# not disturb any draw that already exists -- every other stream is keyed on its own P_*.
P_RSUB = 7

# THE VECTORS THE HARDWARE LAP DOES NOT PLAY, and therefore the ones the offline twin must not play
# either. README.md documents the lap as
#   python3 tools/soak.py --hours 17 --suites formats,plan --skip-vectors v95,v96
# because v96 wedges the generator at vector 33 every time.
#
# NAMED HERE BECAUSE THE SKIP IS PART OF THE PLAN, not a detail of one night's operation. plan_order
# shuffles the list it is handed and every wait, amplitude and offset is keyed on a vector's POSITION in
# that order, so dropping two names renumbers all 39 survivors and hands each of them another vector's
# stimulus. Emitting the 41-vector plan for a 39-vector lap replayed a waveform the generator never
# played, at a phase it never started from, in 1677 of 1677 cells -- checked row by row against
# out/soak/2026-08-27T21-38-33's own per-cell record, where every single one disagreed. That is what
# --check-log now measures and what the offline twin defaults to.
HW_SKIP = ('v95', 'v96')

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


def random_vectors():
    """The twelve random-payload vectors, r00..r11, sorted. Named by pattern rather than listed because
    vector_names.MAP builds them in a loop and a hand list would go stale silently."""
    from vector_names import MAP as _M
    return sorted(v for v in _M if len(v) == 3 and v[0] == 'r' and v[1:].isdigit())


def random_drop(iteration, keep):
    """Which random vectors this iteration does NOT play, as a sorted tuple. () when keeping them all.

    WHY THIS IS WORTH DOING. The twelve random-payload vectors are 516 of a 1677-cell lap -- 31 % of it --
    and on a full offline lap they produced ZERO failures of either kind: no refusals and no byte errors,
    against 151 failures elsewhere. Playing six of them a lap costs 15 % of the lap time and, on that
    evidence, no yield; the six that sit out this lap are played in others, so nothing is dropped from
    the coverage, only from each individual lap.

    IMPLEMENTED AS A SKIP, DELIBERATELY, and that is the whole reason it is safe. plan_order applies the
    skip BEFORE the shuffle because `vi` keys the amplitude, the offset and the wait -- so a per-lap
    subset introduces no new interaction with the draw, it uses the one that is already there and already
    tested. Anything else would be a second way of choosing cells, and two ways of choosing cells is how
    1677 of 1677 cells once ran at another vector's amplitude.

    SEEDED ON THE ITERATION, so the plan is reproducible from the iteration number alone -- the same
    property every other draw in this file has, and what lets a failing cell be replayed a fortnight
    later.
    """
    rs = random_vectors()
    if keep is None or keep >= len(rs):
        return ()
    g = MT19937([MAGIC, iteration, P_RSUB, 0])
    return tuple(sorted(g.shuffle(list(rs))[max(1, keep):]))


def skip_for(iteration, skip, rkeep):
    """The skip set for ONE iteration: the run's own skip, plus the random vectors sitting this lap out.

    ONE PLACE, for the same reason plan_order exists: two call sites computing a skip themselves is
    exactly what let the hardware lap and the offline twin drive different waveforms while comparing
    their results.
    """
    if rkeep is None:
        return skip
    return tuple(sorted(set(skip or ()) | set(random_drop(iteration, rkeep))))


def parse_skip(spec):
    """A --skip-vectors comma list -> a sorted tuple of vector ids. Refuses a name that is not one.

    REFUSES RATHER THAN IGNORES, because a mistyped name does not skip a smaller set -- it skips
    NOTHING, which restores the full-list shuffle and silently changes every cell's stimulus. The
    failure that motivates this file's skip plumbing is invisible in a log, so the typo that
    reintroduces it must not be.

    A TUPLE RATHER THAN A SET, so it can key a ratchet baseline: tools/plan_sweep.py keys on
    (iteration, offsets, skip) and a set is unhashable. Sorted, so two spellings of the same skip are
    the same key.
    """
    from vector_names import MAP as _M
    out = []
    for x in (spec or '').split(','):
        x = x.strip()
        if not x:
            continue
        if x not in _M:
            raise SystemExit('REFUSING: --skip-vectors names %r, which is not in vector_names.MAP. '
                             'A name that matches nothing skips nothing, and an unskipped lap draws '
                             'a different stimulus for every cell.' % x)
        out.append(x)
    return tuple(sorted(set(out)))


def plan_order(iteration, vectors, skip=None, nvectors=None):
    """THE ONE PLACE A LAP'S VECTOR ORDER IS DECIDED, for hardware and for the offline twin alike.

    THE SKIP IS APPLIED BEFORE THE SHUFFLE, and that is not a detail: `vi` is the position in THIS
    list, and vi keys both wait_s and amp_ofst_u. Drop two vectors and every remaining vector's index
    moves, so the whole lap draws a different amplitude, a different offset and a different wait.

    WHY THIS FUNCTION EXISTS AT ALL. The hardware sweep filtered and then shuffled; --emit-lua
    shuffled the whole manifest, because it had no way to be told about a skip. Every hardware lap
    skips v95 and v96 -- v96 wedges the generator -- so EVERY offline-versus-hardware comparison drove
    a different waveform than it compared against: measured on soak lap 1, all 1677 of 1677 cells
    differed in BOTH amplitude and offset, v94 at 300 Bd being 20.000 Vpp at -8.220 V on the bench
    against 8.595 Vpp at +2.347 V offline. Two call sites doing the filter themselves is what let that
    happen, so now there is one.

    Filtering AFTER the shuffle would keep vi stable across skips, which sounds better and is not
    available: the hardware laps already on disk were drawn this way, and their receipts are the
    ground truth the twin has to reproduce.
    """
    keep = [v for v in vectors if v not in (skip or ())]
    return vector_subset(iteration, keep, nvectors)


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


def signature(iteration, vectors, nvectors=None, skip=None):
    """The cheap half of a plan: the order and the rate list. -> (tuple, tuple)

    Exists because proving `plan(n)` is a pure function of n means comparing many iterations, and the
    per-cell waits are 1763 generator seedings apiece -- 0.46 s, nothing against a lap, but a minute
    if 129 iterations are walked to make the point. Order and rates carry the same property at 23
    seedings, and individual waits are checked directly instead.
    """
    return (tuple(plan_order(iteration, vectors, skip, nvectors)), tuple(rates_for(iteration)))


def plan(iteration, vectors, nvectors=None, skip=None):
    """-> dict with the whole iteration: order, rates, and the wait for every cell."""
    order = plan_order(iteration, vectors, skip, nvectors)
    rates = rates_for(iteration)
    cells = []
    for vi, vid in enumerate(order):
        for ri, (baud, kind) in enumerate(rates):
            cells.append({'vi': vi, 'ri': ri, 'vector': vid, 'baud': baud, 'kind': kind,
                          'wait_s': wait_s(iteration, vi, ri, baud)})
    return {'iteration': iteration, 'magic': MAGIC, 'order': order, 'rates': rates, 'cells': cells,
            'skipped': sorted(skip or ())}


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

    # A SKIP IS PART OF THE PLAN'S IDENTITY, asserted in BOTH directions. The whole failure mode is that
    # a skipped lap and an unskipped one look identical in every artifact either produces, so the first
    # property is that they are NOT the same plan and the second is that emit_lua carries the
    # difference. Without the first, a skip that silently did nothing would satisfy the second.
    skip = HW_SKIP
    po = plan_order(1, vecs, skip)
    ck(po == vector_order(1, [v for v in vecs if v not in skip]),
       'plan_order is the shuffle of the FILTERED list, not the filtered shuffle')
    ck(set(po) == set(vecs) - set(skip), 'a skipped vector is absent from the order')
    ck(len(po) == len(vecs) - len(skip),
       'plan_order drops exactly the %d skipped vector(s)' % len(skip))
    ofull = vector_order(1, vecs)
    ck(po != [v for v in ofull if v not in skip],
       'skipping renumbers the survivors -- it is not the full order with names deleted')
    moved = sum(1 for v in po if po.index(v) != ofull.index(v))
    ck(moved > 0, 'skipping moves indices, so a plan is only comparable to a lap that skipped the '
                  'same set -- %d of %d vectors moved' % (moved, len(po)))
    ck(wait_s(1, po.index('v71'), 6, 1800) != wait_s(1, ofull.index('v71'), 6, 1800),
       'the same vector draws a different wait once the list it was shuffled in changes')
    ck(amp_ofst_u(1, po.index('v71'), 6) != amp_ofst_u(1, ofull.index('v71'), 6),
       'the same vector draws a different amplitude and offset once the list changes')
    a1 = amp_ofst_for(po[0], *amp_ofst_u(1, 0, 0))
    a2 = amp_ofst_for(po[0], *amp_ofst_u(1, ofull.index(po[0]), 0))
    ck(a1 != a2 or ofull.index(po[0]) == 0,
       'the first skipped-plan cell draws a different amplitude/offset than the unskipped plan gave '
       'that same vector')
    ck(plan(1, vecs, None, skip)['skipped'] == sorted(skip),
       'the plan records what it skipped, so a mismatch is visible and not merely numerical')
    # THE WHOLE PLAN, NOT A FOUR-VECTOR PREFIX, for the omission checks. v96 sits at index 32 of the
    # unfiltered order and v95 at 34, so a 4-vector subset does not contain either and would satisfy
    # "the skipped vectors are absent" no matter what emit_lua did with the skip.
    lua_skipped = emit_lua(1, None, skip)
    ck("skipped = {'v95', 'v96'}," in lua_skipped, 'emit_lua records the skip list in the plan')
    for v in skip:
        ck(("{id = '%s'," % v) not in lua_skipped, 'emit_lua omits skipped vector %s' % v)
    unskipped = emit_lua(1, None)
    ck("skipped = {}," in unskipped, 'an unskipped plan says so rather than saying nothing')
    for v in skip:
        ck(("{id = '%s'," % v) in unskipped, 'and without a skip it still carries %s' % v)
    # And the emitted vectors really are this iteration's order over the FILTERED list, so the row
    # index the waits and amps are written at is the index the bench would have used.
    ck(re.findall(r"\{id = '([^']+)'", lua_skipped) == po,
       'emit_lua emits the filtered order, in order')

    # parse_skip REFUSES, and the refusal is run rather than described. A name that matches nothing
    # skips nothing, which restores the 41-vector shuffle -- the exact silent failure this plumbing
    # exists to prevent, reached by a typo.
    ck(parse_skip('v96,v95') == skip, 'parse_skip sorts, so two spellings give one key')
    ck(parse_skip('') == () and parse_skip(None) == (), 'no skip parses to the empty tuple')
    try:
        parse_skip('v95,v9x')
        ck(False, 'parse_skip REFUSES a name that is not a vector')
    except SystemExit as e:
        ck('v9x' in str(e), 'parse_skip REFUSES a name that is not a vector, and names it')

    # Waits: keyed, in range, and scaled by baud.
    ck(wait_s(129, 3, 4, 9600) == wait_s(129, 3, 4, 9600), 'a cell wait is reproducible')
    ck(wait_s(129, 3, 4, 9600) != wait_s(129, 3, 5, 9600), 'adjacent cells draw different waits')
    ck(wait_s(130, 3, 4, 9600) != wait_s(129, 3, 4, 9600), 'a new iteration redraws the wait')
    for baud in (300, 9600, 250000):
        w = [wait_s(129, 0, k, baud) for k in range(200)]
        cap = WAIT_BYTE_TIMES * BITS_PER_BYTE / baud
        ck(min(w) >= 0 and max(w) < cap, '%d Bd: waits inside [0, %.4f s)' % (baud, cap))
        ck(max(w) > 0.6 * cap, '%d Bd: the draw reaches the top of its span' % baud)

    # THE CSV AND THE LUA TABLE MUST DESCRIBE THE SAME CELLS. They are two serialisations of one draw,
    # read by two different harnesses -- the offline twin and the on-instrument soak -- and the failure
    # this pins is the one that has already happened once in this project by another route: two
    # descriptions of the same plan that quietly disagree about a cell's amplitude, so a run measures a
    # stimulus nobody intended and every number it produces is about the wrong signal. Asserted per
    # cell rather than by row count, because a count matches while the values are shifted by one.
    csvtext = emit_csv(1, 1, None, HW_SKIP)
    luatext = emit_lua(1, None, HW_SKIP)
    crows = [ln.split(',') for ln in csvtext.strip().split('\n')
             if ln and not ln.startswith('#') and not ln.startswith('iter')]
    lamps = re.findall(r'^  amps = \{(.*?)^  \},', luatext, re.S | re.M)
    lofst = re.findall(r'^  ofsts = \{(.*?)^  \},', luatext, re.S | re.M)
    lwait = re.findall(r'^  waits = \{(.*?)^  \},', luatext, re.S | re.M)
    ck(len(lamps) == 1 and len(lofst) == 1 and len(lwait) == 1,
       'emit_lua carries exactly one amps, ofsts and waits block')
    if len(lamps) == 1 and len(lofst) == 1 and len(lwait) == 1:
        def flat(block):
            return [float(x) for row in re.findall(r'\{([^{}]*)\}', block)
                    for x in row.split(',') if x.strip()]
        fa, fo, fw = flat(lamps[0]), flat(lofst[0]), flat(lwait[0])
        ck(len(crows) == len(fa) == len(fo) == len(fw),
           'the CSV has one row per (vi, ri) the Lua table has: %d vs %d/%d/%d'
           % (len(crows), len(fa), len(fo), len(fw)))
        nmis = 0
        for i, r in enumerate(crows):
            if i >= len(fa):
                break
            # 0.5 mV and 1 us of print rounding are allowed; a real disagreement is orders larger.
            # COLUMNS BY NAME, not by remembered position: iter,cell,vid,arb,baud,kind,amp,ofst,
            # srate,wait. Inserting `arb` shifted every index after it, and the first version of this
            # check read the kind field as an amplitude.
            camp, cofst, cwait = float(r[6]), float(r[7]), float(r[9])
            if abs(camp - fa[i]) > 5e-4 or abs(cofst - fo[i]) > 5e-4:
                nmis += 1
            elif abs(cwait / 1000.0 - fw[i]) > 1e-6:
                nmis += 1
        ck(nmis == 0, 'every CSV cell carries the Lua table\'s own amplitude, offset and wait '
                      '(%d disagree)' % nmis)

    # THE DECLARED ROW COUNT MUST BE THE ROW COUNT. bench_run stops at '# rows=N' precisely so it never
    # reads past the end -- a read past EOF posts 2201 'File read error' as a popup on the panel -- so an
    # over-declared count re-creates the popup the header exists to prevent. It was computed as
    # len(out) - 3 and adding one comment line to the header broke it silently.
    for _rk in (None, 4):
        _txt = emit_csv(1, 2, None, ('v95', 'v96'), None, _rk)
        _decl = [l for l in _txt.split('\n') if l.startswith('# rows=')]
        _rows = [l for l in _txt.split('\n') if l and l[0].isdigit()]
        ck(len(_decl) == 1 and int(_decl[0].split('=')[1]) == len(_rows),
           'the plan declares exactly as many rows as it has, random-per-lap=%s (%s vs %d)'
           % (_rk, _decl[0].split('=')[1] if _decl else 'none', len(_rows)))

    # THE PER-LAP RANDOM SUBSET. Default must change nothing -- all twelve play -- and a subset must play
    # exactly what it says, differently each lap, with none of them starved over a run's worth of laps.
    _rs = set(random_vectors())
    ck(len(_rs) == 12, 'there are twelve random-payload vectors (%d)' % len(_rs))
    _full = emit_csv(1, 1, None, ('v95', 'v96'), None, None)
    _played = set(l.split(',')[2] for l in _full.split('\n') if l and l[0].isdigit())
    ck(_rs <= _played, 'by default every random vector plays every lap (%d of 12 missing)'
                       % len(_rs - _played))
    _sub = emit_csv(1, 1, None, ('v95', 'v96'), None, 4)
    _subplayed = set(l.split(',')[2] for l in _sub.split('\n') if l and l[0].isdigit()) & _rs
    ck(len(_subplayed) == 4, 'random-per-lap=4 plays exactly four of them (%d)' % len(_subplayed))
    _seen = set()
    for _it in range(1, 40):
        _seen |= (_rs - set(random_drop(_it, 4)))
    ck(_seen == _rs, 'and all twelve are reached within forty laps (%d)' % len(_seen))
    ck(random_drop(7, 4) == random_drop(7, 4), 'the choice is reproducible from the iteration alone')
    ck(random_drop(7, 4) != random_drop(8, 4), 'and differs between laps')

    # THE CAP MUST NOT BE COSTING COVERAGE, which is the failure a rate cap actually has. Asserting
    # that no cell exceeds SDG_MAX_SRATE is VACUOUS -- bench_matrix filters those cells out while
    # building the plan, so lowering the cap does not produce an illegal plan, it produces a SMALLER one:
    # measured, dropping the cap to 1 MSa/s takes the plan from 1677 cells to 1110 and every remaining
    # cell is legal. A gate that cannot fail was the first version of this check, and it passed.
    #
    # So the property is that capping at 40 MSa/s -- the SDG2042X's ceiling, chosen so any SDG2000X can
    # run this bench -- costs nothing against the 75 MSa/s the SDG2122X on this bench would allow.
    try:
        import instruments as _I
        def _rows(cap):
            was = _I.SDG_MAX_SRATE
            _I.SDG_MAX_SRATE = cap
            try:
                return [ln for ln in emit_csv(1, 1, None, (), None).split('\n')
                        if ln and ln[0].isdigit()]
            finally:
                _I.SDG_MAX_SRATE = was
        at_cap = _rows(_I.SDG_MAX_SRATE)
        at_2122x = _rows(_I.SDG_MAX_SRATE_2122X)
        ck(len(at_cap) == len(at_2122x),
           'the %.0f MSa/s cap costs no plan coverage against the %.0f MSa/s this bench could do, '
           'so any SDG2000X runs the same plan (%d vs %d cells)'
           % (_I.SDG_MAX_SRATE / 1e6, _I.SDG_MAX_SRATE_2122X / 1e6, len(at_cap), len(at_2122x)))
        worst = max(float(ln.split(',')[8]) for ln in at_cap) if at_cap else 0.0
        ck(worst <= _I.SDG_MAX_SRATE,
           'and no emitted cell exceeds it (worst %.0f of %.0f Sa/s)' % (worst, _I.SDG_MAX_SRATE))
        overv = [ln for ln in at_cap if float(ln.split(',')[6]) > _I.SDG_MAX_VPP]
        ck(not overv, 'and none exceeds SDG_MAX_VPP (%d cell(s) over %.1f Vpp)'
                      % (len(overv), _I.SDG_MAX_VPP))
    except ImportError:
        ck(False, 'tools/instruments.py must be importable to check the generator limits')

    print('\n%s' % ('%d FAILED' % len(bad) if bad else 'selftest: all properties hold'))
    return 1 if bad else 0


def emit_lua(iteration, nvectors=None, skip=None, rkeep=None):
    """The whole plan as a Lua table, for the offline twin to dofile.

    `skip` MUST BE THE SAME SET THE BENCH LAP SKIPPED. It goes through plan_order, so it moves every
    vector's vi and therefore every cell's amplitude, offset and wait -- see plan_order for what
    omitting it cost. The set travels in the emitted table so the twin can print it and a mismatch is
    visible in the log rather than only in the numbers.

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
    # THE SAME PER-LAP SKIP AS emit_csv, through the same one function. The offline twin has to play
    # the cells the hardware lap played or the comparison is between two different laps -- which is
    # the failure plan_order's own comment describes, and it was silent.
    p = plan(iteration, sorted(_MAP.keys()), nvectors, skip_for(iteration, skip, rkeep))
    out = ['-- generated by tools/soakplan.py --emit-lua; do not edit', 'return {',
           '  iteration = %d,' % iteration,
           "  skipped = {%s},"
           % ', '.join("'%s'" % v for v in p['skipped']),
           '  vectors = {']
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


# ---------------------------------------------------------------------------- the hardware receipt


# bench_matrix prints one of these per cell in the compact tail of a soak log. The two numbers this
# reads are the ones the GENERATOR was actually programmed with, so they are the ground truth for what
# amp_ofst_for produced on the night.
LOGCELL = re.compile(r'^plan (\S+)@(\S+)\s+\S+\s+(\d+) Bd \S+ '
                     r'[\d.]+ Vpp-signal \(([\d.]+) Vpp gen, ofst ([+-][\d.]+)\)')
LOGORDER = re.compile(r'^\s*order: (.+)$')


def _parse_emitted(text):
    """Pull the tables back out of an emit_lua() string. -> (vector ids, rates, amps, ofsts, waits).

    READS THE EMITTED FILE, NOT plan(), and that is the point of the whole receipt. Re-deriving the draw
    and comparing it to the bench proves the DRAW agrees; it says nothing about the artifact the twin
    actually loads. A wrong row order, a dropped row, a %.9g that lost a digit -- every one of those lives
    between plan() and the file, and only parsing the file can see them.
    """
    vids = re.findall(r"\{id = '([^']+)'", text)
    rates = [int(x) for x in re.findall(r'^\s*\{(\d+), \'\w+\'\},$', text, re.M)]

    def table(name):
        m = re.search(r'\n  ' + name + r' = \{\n(.*?)\n  \},', text, re.S)
        if m is None:
            raise SystemExit('REFUSING: the emitted plan has no %s table' % name)
        rows = []
        for line in m.group(1).split('\n'):
            line = line.strip()
            if not line.startswith('{'):
                continue
            rows.append([float(x) for x in line.strip('{},').split(', ')])
        return rows
    return vids, rates, table('amps'), table('ofsts'), table('waits')


def check_log(path, iteration, skip):
    """Assert the plan this file emits is the plan a finished soak actually played. -> 0 or 1.

    WHY A RECEIPT AND NOT A UNIT TEST. Everything about the draw is internally consistent whichever
    vector list it is given; the only thing that can tell the two apart is a record of what the
    generator was set to. A soak log carries that per cell, so it is the one available oracle for
    "the twin replays the bench", and it is checked against rather than trusted to agree.

    EVERY CELL, EXACTLY ONCE, OR IT IS NOT A RECEIPT. A count of agreeing rows is not evidence unless
    the rows COVER the plan: a single fabricated matching line satisfies a bare count. So the
    log's cells must be exactly the plan's (vector, rate) set with no duplicates and none missing, and
    the log's own order line must be present -- a soak log always prints it, so its absence means this
    is not the file it was pointed at.

    An amplitude and offset pair that matches to the quantisation soakplan writes them at (Q_DIGITS) is
    a match; anything else is not.
    """
    # `badorder` is kept apart from `bad` so the per-cell count stays a count OF CELLS: folded together
    # it prints "1678 of 1677", which is the sort of number that makes a reader distrust the whole line.
    order, nrow, bad, badorder, samples = None, 0, 0, False, []
    vids, rates, amps, ofsts, waits = _parse_emitted(emit_lua(iteration, None, skip))
    rateidx = {}
    for ri, baud in enumerate(rates):
        rateidx.setdefault(baud, ri)
    pos = dict((vid, vi) for vi, vid in enumerate(vids))
    nr = len(rates)
    if not (len(amps) == len(ofsts) == len(waits) == len(vids)) or \
       any(len(row) != nr for row in amps + ofsts + waits):
        print('REFUSING: the emitted plan\'s amps/ofsts/waits are not %d x %d'
              % (len(vids), nr))
        return 1
    want = set((v, b) for v in vids for b in rates)
    seen = {}
    with open(path, errors='replace') as fh:
        for line in fh:
            mo = LOGORDER.match(line)
            if mo is not None and order is None:
                order = mo.group(1).split()
            m = LOGCELL.match(line)
            if m is None:
                continue
            vid, _cell, baud, vgen, vofst = m.group(1), m.group(2), int(m.group(3)), \
                float(m.group(4)), float(m.group(5))
            nrow += 1
            seen[(vid, baud)] = seen.get((vid, baud), 0) + 1
            vi, ri = pos.get(vid), rateidx.get(baud)
            if vi is None or ri is None:
                bad += 1
                if len(samples) < 8:
                    samples.append('%-6s %7d Bd is not in this plan at all' % (vid, baud))
                continue
            tol = 0.5 * 10.0 ** -Q_DIGITS
            if abs(amps[vi][ri] - vgen) > tol or abs(ofsts[vi][ri] - vofst) > tol:
                bad += 1
                if len(samples) < 8:
                    samples.append('%-6s %7d Bd  bench %8.3f Vpp ofst %+7.3f   plan %8.3f Vpp '
                                   'ofst %+7.3f' % (vid, baud, vgen, vofst,
                                                    amps[vi][ri], ofsts[vi][ri]))
    ap = os.path.abspath(path)
    print('receipt: %s' % (os.path.relpath(ap, ROOT) if ap.startswith(ROOT + os.sep) else ap))
    print('  iteration %d, skipping %s -> %d vectors x %d rates, read from the emitted plan'
          % (iteration, ', '.join(skip) or '(nothing)', len(vids), nr))
    # A LOG WITH NO CELLS IN IT IS NOT A PASS. Reading nothing and printing a clean receipt is the
    # exact failure this whole check exists to make impossible.
    if nrow == 0:
        print('REFUSING: no per-cell "plan <vector>@<cell>" rows in that file, so nothing was checked.')
        return 1
    missing = want - set(seen)
    dup = [c for c, k in seen.items() if k > 1]
    if missing or dup:
        print('REFUSING: the log covers %d of the plan\'s %d cell(s); %d missing, %d duplicated'
              % (len(want) - len(missing), len(want), len(missing), len(dup)))
        for c in sorted(missing)[:6]:
            print('    missing  %-6s %7d Bd' % c)
        for c in sorted(dup)[:6]:
            print('    %d rows for %-6s %7d Bd' % (seen[c], c[0], c[1]))
        return 1
    if order is None:
        print('REFUSING: that file has no "order:" line, so it is not a plan-suite log.')
        return 1
    same = order == list(vids)
    print('  the log\'s own vector order %s this plan\'s' % ('MATCHES' if same else 'DIFFERS from'))
    if not same:
        badorder = True
        print('    log:  %s' % ' '.join(order[:8]))
        print('    plan: %s' % ' '.join(list(vids)[:8]))
    for s in samples:
        print('  MISMATCH %s' % s)
    print('  %d of %d cell(s) disagree with the bench\'s own amplitude and offset' % (bad, nrow))
    if bad or badorder:
        print('FAILED: the offline twin would replay a stimulus the generator never played. The skip '
              'list is part of the plan -- see HW_SKIP.')
        return 1
    print('OK: every cell replays the amplitude and offset the generator was set to.')
    return 0


def spec_order(spec):
    """Parse bench_matrix's --plan-spec into (order, kindmap). Same grammar, same refusals.

    THE SPEC REPLACES THE SHUFFLE, and that is the part worth stating: with a spec, bench_matrix
    enumerates the SPEC's own list, so vi is a vector's position in what was typed -- not its position
    in plan_order. vi keys the amplitude, the offset and the wait, so a smoke plan built from the
    shuffled order would drive every cell at a different amplitude than the host smoke drives it at,
    and the two would disagree for a reason that is neither hardware nor app. This project has already
    paid for that mistake once by the other route (the skip set moving vi), so the indexing is copied
    rather than re-derived.
    """
    from vector_names import MAP as _MAP
    order, kindmap = [], {}
    for item in spec.split(','):
        vid, _, kinds = item.strip().partition(':')
        vid = vid.strip()
        if vid not in _MAP:
            raise SystemExit('REFUSING: --spec names %r, which is not in vector_names.MAP' % vid)
        k = (kinds or 'all').strip()
        want = {'std': {'std'}, 'nonstd': {'rand', 'edge'},
                'all': {'std', 'rand', 'edge'}}.get(k)
        if want is None:
            raise SystemExit("REFUSING: --spec kind %r for %s; use std, nonstd or all" % (k, vid))
        order.append(vid)
        kindmap[vid] = want
    return order, kindmap


def emit_csv(first, last, nvectors=None, skip=None, spec=None, rkeep=None):
    """The plan as flat CSV for bench/bench_run.tsp to stream off the USB key.

    WHY A THIRD FORM, after the Lua table and the hardware sweep's own iteration. The on-instrument
    soak reads its plan a LINE AT A TIME: a long run is tens of thousands of cells, and the DMM6500 has
    no memory to spare for a table it visits once per entry. Flat rows also mean a soak killed by a
    power cycle resumes by reading forward rather than by reconstructing anything.

    SAME FUNCTIONS AS emit_lua, deliberately -- plan(), amp_ofst_u() and amp_ofst_for(). This adds a
    serialisation, NOT a second draw. The one number computed here that emit_lua does not carry is the
    generator's sample rate, and it comes from bench_matrix's own rule (baud x the manifest's spb),
    because that is what the hardware sweep programs and any other value would play the vector at the
    wrong speed.

    ITERATIONS ARE A RANGE because the instrument cannot draw its own: an 8-day soak is ~66 laps at
    ~2.9 h each, so the file has to cover more iterations than the run will reach. Running past the
    last row wraps to the first, which repeats stimulus already seen -- so emit generously and let it
    never wrap.
    """
    from vector_names import MAP as _MAP
    vecs = sorted(_MAP.keys())
    out = ['# generated by tools/soakplan.py --emit-csv; one row per cell, streamed by bench_run.tsp',
           '# rows=@@ROWS@@',
           # RECORDED IN THE FILE, because a reader cannot otherwise tell a lap that played six random
           # vectors from one that played twelve, and the cell count alone would look like a short plan.
           '# random-per-lap=%s' % ('all' if rkeep is None else rkeep),
           'iter,cell,vid,arb,baud,kind,amp_vpp,ofst_v,srate,wait_ms']
    import instruments as _I
    for it in range(first, last + 1):
        rates = rates_for(it)
        if spec:
            order, kindmap = spec_order(spec)
        else:
            # THE SKIP IS PER ITERATION when --random-per-lap is in force: the run's own skip plus
            # whichever random vectors sit this lap out. skip_for is the only place that is decided.
            order, kindmap = plan_order(it, vecs, skip_for(it, skip, rkeep), nvectors), None
        n = 0
        for vi, vid in enumerate(order):
            row = _manifest_rows().get(vid) or {}
            # THE SAME TWO SKIPS bench_matrix APPLIES, and each changes the cell COUNT rather than only
            # an outcome: a vector with no expected bytes cannot be judged, and a sample rate past the
            # generator's ceiling cannot be played. Emitting either would put a row on the key that the
            # host bench never runs, so the two would not be the same cells.
            if not (row.get('exp_hex') or '').strip():
                continue
            spb = int(row.get('spb') or 10)
            for ri, (baud, kind) in enumerate(rates):
                if kindmap is not None and kind not in kindmap[vid]:
                    continue
                srate = int(round(baud * spb))
                if srate > _I.SDG_MAX_SRATE:
                    continue
                ua, uo = amp_ofst_u(it, vi, ri)
                amp, ofst = amp_ofst_for(vid, ua, uo)[0:2]
                n += 1
                # THE GENERATOR'S OWN NAME TRAVELS WITH THE CELL, from vector_names.MAP -- the same
                # place bench_matrix gets it. The instrument must not derive it: ARWV NAME takes the
                # stored waveform's name, and sending a local id like 'v77' does NOTHING while the
                # PREVIOUS waveform keeps playing, so the measurement would be attributed to a
                # waveform that never played. vector_names.arb() raises rather than guessing and this
                # keeps that property on the instrument side.
                out.append('%d,%d,%s,%s,%d,%s,%.4f,%.4f,%d,%.3f'
                           % (it, n, vid, _MAP[vid], baud, kind, amp, ofst, srate,
                              1000.0 * wait_s(it, vi, ri, baud)))
    # THE ROW COUNT IN THE HEADER, so the instrument can stop at the last row instead of discovering the
    # end by reading past it -- which posts event 2201, 'File read error', as a popup on the panel once
    # per pass. Substituted at the end because it is not known until the rows are built.
    # COUNTED, NOT len(out) MINUS THE NUMBER OF HEADER LINES I HAPPEN TO REMEMBER. That subtraction was
    # `- 3` and adding one comment line to this header made it over-declare by one -- which sends
    # bench_run past the last row, and a read past the end posts 2201 'File read error' as a popup on the
    # panel. The count is the thing the instrument trusts to never do that, so it is derived from the rows.
    nrows = len([x for x in out if x and x[0] != '#' and not x.startswith('iter,')])
    return '\n'.join(out).replace('@@ROWS@@', str(nrows)) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emit-lua', action='store_true',
                    help='print the plan as a Lua table for tools/sweep_plan.lua')
    ap.add_argument('--emit-csv', action='store_true',
                    help='print the plan as flat CSV for the on-instrument soak (bench/bench_run.tsp)')
    ap.add_argument('--iterations', type=int, default=None,
                    help='with --emit-csv: emit iterations --iteration..N inclusive')
    ap.add_argument('--spec', default=None,
                    help='with --emit-csv: bench_matrix\'s --plan-spec grammar (vid:std|nonstd|all, '
                         'comma separated), for the smoke\'s 86-cell subset')
    ap.add_argument('--random-per-lap', type=int, default=None, metavar='N',
                    help='play only N of the twelve random-payload vectors each lap, drawn from the '
                         'iteration seed. They are 31 %% of a lap and produced zero failures of either '
                         'kind on a full offline lap, so six saves ~15 %% of the lap time and every one '
                         'of them is still played across laps. Default: all twelve')
    ap.add_argument('--iteration', type=int, default=1)
    ap.add_argument('--vectors', type=int, default=None, help='a seeded subset of this many vectors')
    ap.add_argument('--rates', action='store_true', help='print only the rate list')
    # SPELT AND PARSED EXACTLY AS bench_matrix.py --skip-vectors, because the two values have to be
    # the same string for the two plans to be the same plan. Applied BEFORE the order is shuffled,
    # exactly where bench_matrix applies it, because every wait, amplitude and offset is keyed on a
    # vector's position in that order.
    ap.add_argument('--skip-vectors', default='',
                    help='comma-separated vector ids to leave out, as the bench lap left them out '
                         '(the lap runs %s); this MOVES every remaining cell\'s amplitude, offset '
                         'and wait' % ','.join(HW_SKIP))
    ap.add_argument('--check-log', default=None,
                    help='a finished soak log: assert this plan is the one it played')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    skip = parse_skip(a.skip_vectors)
    if a.check_log:
        return check_log(a.check_log, a.iteration, skip)
    if a.emit_lua:
        sys.stdout.write(emit_lua(a.iteration, a.vectors, skip))
        return 0
    if a.emit_csv:
        last = a.iterations if a.iterations is not None else a.iteration
        if last < a.iteration:
            print('REFUSING: --iterations %d is below --iteration %d, so the range is empty and the '
                  'instrument would read a plan with no cells in it.' % (last, a.iteration))
            return 2
        sys.stdout.write(emit_csv(a.iteration, last, a.vectors, skip, a.spec,
                                  a.random_per_lap))
        return 0

    from vector_names import MAP
    vecs = sorted(MAP.keys())
    p = plan(a.iteration, vecs, a.vectors, skip)
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
    if p['skipped']:
        print('  SKIPPED BY REQUEST, and the reason every remaining index moved: %s'
              % ' '.join(p['skipped']))
    return 0


if __name__ == '__main__':
    sys.exit(main())

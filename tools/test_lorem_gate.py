#!/usr/bin/env python3
"""Offline test for a corrected lorem gate. No instruments; the payload comes off disk.

WHAT IS WRONG WITH THE SHIPPED GATE. bench_matrix.py:456 judges a lorem point on
`longest_clean_run / body >= 0.95`, and BU.analyse validates only the SINGLE LONGEST run
(bench_uart.py:375-377). That has two independent faults:

  1. It is a fragile ORDER STATISTIC. With k bytes flagged, the score depends on WHERE they
     land, not how many there are, so the same signal quality passes or fails on luck. Measured:
     143 lorem points across 13 runs, longest run byte-exact 141 of 141 times it was reported,
     yet 1.4 % fell below the gate. 600 Bd scored 0.94979 and failed; 38400 Bd scored 0.95000
     and passed, in the same lap.
  2. Every run except the longest is NEVER COMPARED TO THE PAYLOAD. A wrong byte in a shorter
     run is invisible today. test_short_run_corruption below is a case the shipped gate passes
     and the replacement catches -- which is the whole reason the replacement is stricter, not
     laxer.

THE REPLACEMENT separates the two questions the one threshold conflates:
  correctness   -- every run long enough to be diagnostic must be byte-exact in the payload AND
                   all such runs must agree on ONE alignment (the arb loops, so a single capture
                   has a single offset; disagreeing runs mean a decode slipped)
  signal quality-- bound the FLAG COUNT, a stable count statistic that does not move when a flag
                   changes position, plus a floor on how much of the capture was positively
                   verified

Usage:  python3 tools/test_lorem_gate.py
"""
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAYLOAD_PATH = os.path.join(ROOT, 'out', 'vectors', 'v71.txt')

# A run shorter than this matches a 1 kB payload by chance often enough to prove nothing, so it
# is neither validated nor counted as verified coverage. 4 bytes is ~1024/2**32.
MINVAL = 4
# Flag budget. A real analog capture of back-to-back 8N1 bytes with no idle to resync on will
# flag the odd frame; 2 % or two bytes, whichever is kinder, is what 143 recorded points do.
FLAG_FRAC = 0.02
FLAG_FLOOR = 2
# How much of the capture must be POSITIVELY VERIFIED byte-exact. Deliberately below the flag
# budget's implied coverage so that short unvalidatable runs do not by themselves fail a point.
COVER_MIN = 0.90


def runs_of(frames):
    """Every maximal run of non-flagged frames, as (start_index, [frames])."""
    out, cur, start = [], [], 0
    for i, f in enumerate(frames):
        if f == '??':
            if cur:
                out.append((start, cur))
            cur, start = [], i + 1
        else:
            if not cur:
                start = i
            cur.append(f)
    if cur:
        out.append((start, cur))
    return out


def judge(got_hex, payload):
    """-> (ok, detail). got_hex is the concatenated 2-char-per-frame string, '??' for flagged."""
    frames = [got_hex[i:i + 2] for i in range(0, len(got_hex), 2)]
    body = len(frames)
    if not body:
        return False, 'no bytes decoded'
    bad = [i for i, f in enumerate(frames) if f == '??']
    interior = [i for i in bad if i != 0 and i != body - 1]
    rr = runs_of(frames)

    # --- correctness: every diagnostic run byte-exact, all agreeing on one alignment ----------
    # ONE alignment is established for the whole capture and every run is then checked at the
    # position it predicts -- NOT by searching for each run independently. A 4-8 byte run of
    # lorem text really does occur more than once in 1 kB (repeated words, spaces), so a plain
    # find() per run lands on the wrong copy and fakes a misalignment. Found by the position
    # sweep below, which failed until this was rewritten.
    hay = payload + payload           # the arb loops, so a window may straddle the wrap
    diag = [(s, f) for s, f in rr if len(f) >= MINVAL]
    if not diag:
        return False, 'nothing long enough to validate (%d B in runs under %d)' % (body, MINVAL)
    try:
        asbytes = [(s, bytes(int(x, 16) for x in f)) for s, f in rr]
    except ValueError:
        return False, 'capture is not hex'
    anchor_start, anchor = max(diag, key=lambda r: len(r[1]))
    anchor_b = bytes(int(x, 16) for x in anchor)

    # Every place the anchor could sit. Usually one; a short anchor may have several, and any of
    # them is allowed to be the true one, so all are tried before the capture is called wrong.
    cands, at = [], hay.find(anchor_b)
    while at >= 0 and at < len(payload):
        cands.append((at - anchor_start) % len(payload))
        at = hay.find(anchor_b, at + 1)
    if not cands:
        return False, ('run of %d B at index %d is NOT in the payload -- silently wrong'
                       % (len(anchor_b), anchor_start))

    align, verified, whynot = None, 0, ''
    for cand in cands:
        v, ok_all = 0, True
        for start, gb in asbytes:
            if len(gb) < MINVAL:
                continue                      # too short to prove anything either way
            exp = (cand + start) % len(payload)
            if hay[exp:exp + len(gb)] != gb:
                ok_all = False
                whynot = ('run of %d B at index %d does not match the payload at the alignment '
                          'the rest of the capture agrees on -- silently wrong' % (len(gb), start))
                break
            v += len(gb)
        if ok_all:
            align, verified = cand, v
            break
    if align is None:
        return False, whynot

    # --- signal quality: a COUNT, not an order statistic --------------------------------------
    budget = max(FLAG_FLOOR, int(math.ceil(FLAG_FRAC * body)))
    if len(interior) > budget:
        return False, '%d interior flagged, budget %d' % (len(interior), budget)
    cover = float(verified) / body
    if cover < COVER_MIN:
        return False, 'only %.1f %% positively verified (need %.0f %%)' % (100 * cover, 100 * COVER_MIN)
    return True, ('%d B verified of %d (%.1f %%) at offset %d, %d flagged (budget %d)'
                  % (verified, body, 100 * cover, align, len(interior), budget))


# ==============================================================================
# tests
# ==============================================================================
FAILED = []


def ck(cond, what):
    print('  %-4s %s' % ('ok' if cond else 'FAIL', what))
    if not cond:
        FAILED.append(what)


def hexs(bs):
    return ''.join('%02x' % b for b in bs)


def capture(payload, offset, n, flag_at=(), corrupt_at=()):
    """A synthetic capture of n bytes starting at `offset` in the looping payload, with the given
    indices flagged '??' and the given indices' VALUES corrupted (still decoded, silently wrong).
    """
    hay = payload + payload
    frames = ['%02x' % hay[offset + i] for i in range(n)]
    for i in corrupt_at:
        frames[i] = '%02x' % (hay[offset + i] ^ 0x20)     # one bit flip, a plausible slip
    for i in flag_at:
        frames[i] = '??'
    return ''.join(frames)


def main():
    if not os.path.exists(PAYLOAD_PATH):
        print('missing %s -- run the vector generator first' % PAYLOAD_PATH)
        return 2
    with open(PAYLOAD_PATH, 'rb') as f:
        payload = f.read()
    print('payload %d bytes from %s' % (len(payload), PAYLOAD_PATH))

    print('\n-- the artifact must now PASS: honest flags, unlucky position --')
    # lap 5/6 of the 8 h V1.03 soak, exactly: 239 B, 2 interior flags, longest clean run 227.
    # Flags at 3 and 10 leave runs 3 / 6 / 229 -- longest 229, so 0.958; place them to land 227.
    got = capture(payload, 421, 239, flag_at=(5, 11))
    ok, det = judge(got, payload)
    ck(ok, 'lap5-shaped 239 B, 2 flags -> pass  [%s]' % det)
    # the historical 2400 Bd BAD: 238 B, 2 flags, longest run 224 = 0.9412
    got = capture(payload, 92, 238, flag_at=(7, 13))
    ok, det = judge(got, payload)
    ck(ok, '2400-shaped 238 B, 2 flags -> pass  [%s]' % det)

    print('\n-- a wrong byte in a SHORT run: the shipped gate passes this, the new one must not --')
    # Flags at 3 and 10 -> runs 0..2 (3 B, too short to validate), 4..9 (6 B, CORRUPTED),
    # 11..238 (228 B, clean). Shipped gate: longest = 228, 228/239 = 0.954 >= 0.95, and it only
    # ever checks the longest run -> PASSES with a silently wrong byte in the capture.
    got = capture(payload, 200, 239, flag_at=(3, 10), corrupt_at=(6,))
    ok, det = judge(got, payload)
    ck(not ok, 'corrupt byte in a 6 B run -> FAIL  [%s]' % det)
    shipped_run = 228
    ck(shipped_run / 239.0 >= 0.95,
       'and the shipped gate really would have passed it (%d/239 = %.4f >= 0.95)'
       % (shipped_run, shipped_run / 239.0))

    print('\n-- genuine garbage must still fail --')
    # V1.01's v44e: 153 B, longest clean run 9, 35 interior flagged.
    got = capture(payload, 0, 153, flag_at=tuple(range(10, 150, 4)))
    ok, det = judge(got, payload)
    ck(not ok, 'v44e-shaped 153 B, 35 flags -> FAIL  [%s]' % det)

    got = hexs(bytes((i * 37 + 11) & 0xFF for i in range(200)))
    ok, det = judge(got, payload)
    ck(not ok, 'wholly unrelated bytes -> FAIL  [%s]' % det)

    print('\n-- a decode that slips mid-capture must fail on alignment --')
    # Two clean runs that are each individually byte-exact but come from DIFFERENT offsets: that
    # is a decoder that lost and regained sync, which the shipped gate cannot see at all because
    # it validates one run in isolation.
    a = capture(payload, 100, 120)
    b = capture(payload, 700, 119)
    ok, det = judge(a + '??' + b, payload)
    ck(not ok, 'two byte-exact runs from different offsets -> FAIL  [%s]' % det)

    print('\n-- a clean capture must pass, wrap included --')
    ok, det = judge(capture(payload, 0, 240), payload)
    ck(ok, 'perfect 240 B -> pass  [%s]' % det)
    ok, det = judge(capture(payload, len(payload) - 100, 240), payload)
    ck(ok, 'perfect 240 B straddling the loop wrap -> pass  [%s]' % det)

    print('\n-- clipped first/last frame is not an error --')
    ok, det = judge(capture(payload, 300, 239, flag_at=(0, 238)), payload)
    ck(ok, 'both edges flagged, interior clean -> pass  [%s]' % det)

    print('\n-- the flag budget is a count, so position must not change the verdict --')
    # The same THREE flags, swept across the capture. Every placement must give the same verdict.
    # k + 80 is the last flag, so k must stop at 238 - 80 for all three to land inside the
    # capture. capture() raises on an out-of-range index rather than dropping it, so a sweep
    # that overran would be a silently weaker test.
    SWEEP = list(range(0, 239 - 80, 7))
    verdicts = set()
    for k in SWEEP:
        got = capture(payload, 421, 239, flag_at=(k + 1, k + 40, k + 80))
        verdicts.add(judge(got, payload)[0])
    ck(len(verdicts) == 1 and True in verdicts,
       '3 flags at %d different positions -> one verdict, pass (%s)' % (len(SWEEP), verdicts))
    # And the shipped gate on those same captures would swing wildly:
    fracs = []
    for k in SWEEP:
        frames = ['x'] * 239
        for i in (k + 1, k + 40, k + 80):
            frames[i] = '??'
        best = max((len(r[1]) for r in runs_of(frames)), default=0)
        fracs.append(best / 239.0)
    # Three honest flags spread across the capture cap the longest run near a third of it, so the
    # shipped gate rejects EVERY one of these captures -- 3 flagged bytes in 239, all of which the
    # decoder declared, and 236 bytes that are byte-exact. That is the artifact at its starkest.
    ck(max(fracs) < 0.95,
       'while the shipped longest-run gate scores them %.3f..%.3f and so fails ALL %d -- '
       'on 3 flagged bytes in 239' % (min(fracs), max(fracs), len(SWEEP)))

    print('\n-- the lap 7 case: ONE flagged byte, 11 B in, fails the shipped gate --')
    # Observed 2026-08-18 lap 7: lorem 19200, 239 B, 1 bad (1 interior), longest clean run 227.
    # A single flag at index p leaves runs of p and 238-p, so the shipped gate needs p <= 10 or
    # p >= 228: only 22 of 239 positions (9.2 %) pass. One honest flag anywhere else fails.
    got = capture(payload, 200, 239, flag_at=(11,))
    ok, det = judge(got, payload)
    ck(ok, 'one flag at index 11 -> pass  [%s]' % det)
    windows = [p for p in range(239) if max(p, 238 - p) >= 0.95 * 239]
    ck(len(windows) == 22 and 11 not in windows,
       'and the shipped gate passes only %d of 239 single-flag positions, not including 11'
       % len(windows))

    print('\n-- one flag too many must fail, and the boundary must be exact --')
    body = 239
    budget = max(FLAG_FLOOR, int(math.ceil(FLAG_FRAC * body)))
    at_budget = tuple(20 + 30 * i for i in range(budget))
    over = tuple(20 + 30 * i for i in range(budget + 1))
    ck(judge(capture(payload, 421, body, flag_at=at_budget), payload)[0],
       'exactly the budget (%d flags) -> pass' % budget)
    ok, det = judge(capture(payload, 421, body, flag_at=over), payload)
    ck(not ok, 'budget + 1 (%d flags) -> FAIL  [%s]' % (budget + 1, det))

    print()
    if FAILED:
        print('%d FAILED:' % len(FAILED))
        for w in FAILED:
            print('  - %s' % w)
        return 1
    print('all lorem-gate tests passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())

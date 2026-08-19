#!/usr/bin/env python3
"""Gates BU.judge_payload, the long-payload verdict. No instruments; the payload comes off disk.

WHAT IT GUARDS AGAINST is a judging rule that returns the wrong verdict, which is as dangerous as
a decoder bug because it HIDES them. Three real ones are pinned here, each with the case that
caught it:

  1. A fragile ORDER STATISTIC. The old rule scored a capture on `longest_clean_run/body >= 0.95`,
     so the verdict tracked WHERE flags landed, not how many. For one flag at index p in 239
     frames the runs are p and 238-p, needing p <= 10 or p >= 228 -- 22 of 239 positions, 9.2 %.
     Measured across 143 recorded points: the longest run was byte-exact 141 of 141 times it was
     reported, yet 1.4 % fell below the gate. In one soak lap 600 Bd scored 0.94979 and failed
     while 38400 Bd scored 0.95000 and passed.
  2. ONLY THE LONGEST RUN WAS CHECKED against the payload, so a wrong byte in a shorter run was
     invisible. The 'corrupt byte in a 6 B run' case below is one the old rule passed.
  3. TWO COPIES OF THE PAYLOAD were assumed enough to search. False for a capture off a payload
     SHORTER than the window: 234 bytes off a 133-byte loop is one contiguous run spanning 1.76
     periods, and only 33 of 133 start offsets could be found. v78 decoded with ZERO bad frames
     and was reported MISMATCH. That assumption was invisible until a short vector existed.

THE RULE separates the two questions the single threshold conflated:
  correctness    -- every run long enough to be diagnostic is byte-exact in the payload AND all
                    such runs agree on ONE alignment (the arb loops, so a capture has a single
                    offset; disagreeing runs mean a decode slipped mid-capture)
  signal quality -- bound the FLAG COUNT, which does not move when a flag changes position, plus
                    a floor on how much of the capture was positively verified

Usage:  python3 tools/test_lorem_gate.py
"""
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
PAYLOAD_PATH = os.path.join(ROOT, 'out', 'vectors', 'v71.txt')

# THE TEST GATES THE SHIPPED CODE, not a copy of it. This file used to carry its own duplicate of
# the judging logic, and the copies diverged the moment cyclic_find's short-payload bug was fixed in
# bench_uart and not here -- the test then passed a rule nothing shipped. Import instead.
import bench_uart as BU

judge = BU.judge_payload
runs_of = BU.runs_of
MINVAL, FLAG_FRAC = BU.JP_MINVAL, BU.JP_FLAG_FRAC
FLAG_FLOOR, COVER_MIN = BU.JP_FLAG_FLOOR, BU.JP_COVER_MIN


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

    Repeats the payload enough times for offset+n rather than assuming two copies -- the same
    assumption that broke cyclic_find, and it broke this helper too the moment a 133-byte payload
    met a 234-byte window.
    """
    hay = payload * ((offset + n) // len(payload) + 2)
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
    # MID-CAPTURE, deliberately. An earlier version corrupted frame 6, and that case had to be
    # retired: JP_HEADSKIP excludes the first frames because a wrong byte three frames in is
    # genuinely indistinguishable from the resync debris a real capture carries (measured on
    # hardware -- a v41 capture opened '?? ?? ?? ?? DD 3B ?? ?? 76 C8' before repeating cleanly).
    # What the judge must still catch is a wrong byte in a SHORT RUN well inside the capture, which
    # the old longest-run gate passed: flags at 120 and 127 leave 13..119 (107 B, clean),
    # 121..126 (6 B, CORRUPTED) and 128..237 (110 B, clean), so the longest run is clean and
    # 110/239 of the capture -- but the 6-byte run is a lie and must fail.
    got = capture(payload, 200, 239, flag_at=(120, 127), corrupt_at=(123,))
    ok, det = judge(got, payload)
    ck(not ok, 'corrupt byte in a 6 B run, mid-capture -> FAIL  [%s]' % det)

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

    print('\n-- a SHORT looping payload: a capture longer than the payload must still pass --')
    # The bug a 133-byte vector exposed on 2026-08-19. Both cyclic_find and judge_payload assumed
    # two copies of the payload were enough, which is only true while every payload is LONGER than
    # a capture. v77/v78 are 133 B and the window is ~234 B, so a window starting at offset k spans
    # k..k+234 and fits in want+want only when k <= 32 -- 25 % of offsets. The other 75 % were
    # called MISMATCH having decoded byte-perfectly.
    import bench_uart as BU_
    short = open(os.path.join(ROOT, 'out', 'vectors', 'v77.txt'), 'rb').read()
    ck(len(short) == 133, 'the short vector is 133 B  [%d]' % len(short))
    every = True
    for k in range(len(short)):
        got = capture(short, k, 234)
        if not judge(got, short)[0]:
            every = False
            ck(False, 'short payload, 234 B window at offset %d -> should pass' % k)
            break
    ck(every, 'a 234 B window passes at ALL %d start offsets of a 133 B payload' % len(short))
    # and the underlying primitive, directly
    misses = [k for k in range(len(short))
              if BU_.cyclic_find(short, (short + short + short)[k:k + 234]) < 0]
    ck(not misses,
       'cyclic_find finds a 234 B needle at all %d offsets of a 133 B loop  [%d missed]'
       % (len(short), len(misses)))

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

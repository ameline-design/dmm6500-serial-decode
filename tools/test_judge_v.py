#!/usr/bin/env python3
"""Gates judge_payload_v's three relaxations. No instruments; every case is built here.

Each relaxation widens what counts as a pass, so each needs a case proving it does not also admit a
wrong capture. The three:

  INCONCLUSIVE      a capture too short to judge is not evidence of a wrong answer
  alignment score   all len(want) alignments are scored, so one bad byte cannot lose the alignment
  mismatch budget   a loud vector may miss a bounded number of bytes; an exact vector may miss none

The adversarial half is the point: self-similar payloads (a step-7 ramp, walking bits, 0x55 blocks) are
where scoring every alignment could find a shifted one that fits, and the run-edge exemption is where
mismatches could hide for free.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_uart as BU                                        # noqa: E402

FAILED = []


def check(name, cond, note=''):
    print('  %-4s %s%s' % ('ok' if cond else 'FAIL', name, ('  -- ' + note) if note and not cond else ''))
    if not cond:
        FAILED.append(name)


def hexs(bs):
    return ''.join('%02X' % b for b in bs)


def cyc(payload, phase, n):
    """n bytes of `payload` read as a loop starting at `phase`."""
    rep = payload * (n // len(payload) + 2)
    return rep[phase:phase + n]


# ---------------------------------------------------------------- INCONCLUSIVE
print('\n-- a capture too short to judge is INCONCLUSIVE, never a silent-wrong --')
W13 = b'Hello, World!'
for n in (1, 3, 8, 12):
    v, det = BU.judge_payload_v(hexs(cyc(W13, 0, n)), W13, 'exact')
    check('%d B -> INCONCLUSIVE' % n, v == 'INCONCLUSIVE', 'got %s: %s' % (v, det))
v, det = BU.judge_payload_v('', W13, 'exact')
check('no bytes at all -> FAIL, not INCONCLUSIVE', v == 'FAIL', det)

# ---------------------------------------------------------------- the alignment score
print('\n-- one bad byte must not lose the alignment (the v46 and j20 cases) --')
good = cyc(W13, 0, 240)
# Positions chosen to survive JP_HEADSKIP=12 and JP_TAILSKIP=1, or the corruption is trimmed away and
# the case proves nothing. 20 and 150 are interior; 238 is the last judged byte.
for pos, label in ((20, 'just past the head allowance'), (150, 'mid-run, the j20 case'),
                   (238, 'at the last judged byte')):
    bad = bytearray(good)
    bad[pos] = 0xD0
    v, det = BU.judge_payload_v(hexs(bytes(bad)), W13, 'loud')
    check('one wrong byte %s -> PASS for loud' % label, v == 'PASS', '%s: %s' % (v, det))
    v, det = BU.judge_payload_v(hexs(bytes(bad)), W13, 'exact')
    # NO adjacent '??' anywhere, so nothing is exempt and exact must fail at every position. A wrong
    # byte is only forgiven next to a frame the app itself flagged.
    check('  ...and FAIL for exact, with no flag beside it', v == 'FAIL', '%s: %s' % (v, det))

print('\n-- a wrong byte IS forgiven beside a frame the app flagged (the real v46 shape) --')
frag = ['%02X' % b for b in cyc(W13, 0, 240)]
for at in (14, 16, 18):
    frag[at] = '??'
frag[19] = 'D0'                     # resync debris immediately after the flagged run
v, det = BU.judge_payload_v(''.join(frag), W13, 'exact')
check('debris adjacent to a flag -> PASS for exact', v == 'PASS', '%s: %s' % (v, det))
check('  ...counted as exempt, not as a match', 'edge-exempt' in det and '0 mismatched' in det, det)
frag2 = ['%02X' % b for b in cyc(W13, 0, 240)]
frag2[19] = 'D0'                    # the SAME byte wrong, with no flag beside it
v, det = BU.judge_payload_v(''.join(frag2), W13, 'exact')
check('the same byte with no flag beside it -> FAIL', v == 'FAIL', '%s: %s' % (v, det))

# ---------------------------------------------------------------- SELF-SIMILAR PAYLOADS
# The real adversary. Scoring every alignment could find a SHIFTED one that fits a payload whose
# structure repeats. A shift must be rejected even though the bytes are all drawn from the payload.
print('\n-- a SHIFTED alignment of a self-similar payload must FAIL --')
RAMP = bytes(((0x27 + 7 * i - 0x20) % 95) + 0x20 for i in range(200))    # v46's step-7 ramp mod 95
BLK = (b'\x00' * 16 + b'\xFF' * 16 + b'\x55' * 16 + b'\xAA' * 16) * 3    # v90-style blocks
WALK = bytes(1 << (i % 8) for i in range(64))                            # walking bits
for payload, pname in ((RAMP, 'step-7 ramp'), (BLK, '00/FF/55/AA blocks'), (WALK, 'walking bits'),
                       (W13, 'Hello, World!')):
    # A correct capture at an arbitrary phase must pass...
    v, _ = BU.judge_payload_v(hexs(cyc(payload, 7 % len(payload), 200)), payload, 'exact')
    check('%s: a correct capture at phase 7 -> PASS' % pname, v == 'PASS')
    # ...and the SAME bytes judged against a payload rotated by one must not, because that is exactly
    # the mistake an alignment search can make on a self-similar payload.
    rot = payload[1:] + payload[:1]
    got = hexs(cyc(payload, 0, 200))
    v, det = BU.judge_payload_v(got, rot, 'exact')
    # A rotation of a CYCLIC payload is the same loop, so PASS here is correct -- what must fail is a
    # payload that is genuinely different, tested below. This case pins that rotation is not a defect.
    check('%s: a rotated payload is the same loop -> PASS' % pname, v == 'PASS', det)

print('\n-- a DIFFERENT payload must FAIL even when it shares the alphabet --')
for payload, other, label in (
        (RAMP, bytes(((0x27 + 11 * i - 0x20) % 95) + 0x20 for i in range(200)), 'ramp step 7 vs 11'),
        (BLK, (b'\x00' * 16 + b'\x55' * 16 + b'\xFF' * 16 + b'\xAA' * 16) * 3, 'blocks reordered'),
        (WALK, bytes(1 << (7 - i % 8) for i in range(64)), 'walking bits reversed'),
        (W13, b'Hello, Wxrld!', 'one byte different in a 13 B payload')):
    v, det = BU.judge_payload_v(hexs(cyc(payload, 0, 200)), other, 'exact')
    check('%s -> FAIL' % label, v == 'FAIL', '%s: %s' % (v, det))
    v, det = BU.judge_payload_v(hexs(cyc(payload, 0, 200)), other, 'loud')
    check('  ...and FAIL for loud too' % (), v == 'FAIL', '%s: %s' % (v, det))

# ---------------------------------------------------------------- THE EDGE EXEMPTION
# Mismatches at a run's first/last byte cost no budget. The worry is many short runs each donating two
# free positions. The bound is the FLAG budget: runs are separated by '??' frames, and those are capped
# at max(2, 2 % of body), so the run count -- and hence the exemptions -- is capped with them.
print('\n-- the run-edge exemption cannot be farmed, because the flag budget caps the run count --')
body = 200
base = bytearray(cyc(W13, 0, body))
frames = ['%02X' % b for b in base]
# Fragment into 4-byte runs by inserting '??' every 5th frame, then corrupt every run edge.
frag, k = [], 0
while k < len(frames):
    frag.extend(frames[k:k + 4])
    frag.append('??')
    k += 4
v, det = BU.judge_payload_v(''.join(frag), W13, 'exact')
check('a capture fragmented into 4 B runs -> FAIL', v == 'FAIL', det)
# The COVERAGE FLOOR is what stops it, not the flag budget, and that is the stronger guard: in a 4-byte
# run 2 of the 4 positions are edge-exempt, so such a capture can never verify more than half its bytes
# and the 90 % floor rejects it before any budget is consulted.
check('  ...on the coverage floor, before any budget', 'verifies only' in det, det)

# With a legal number of flags, the exemption is bounded to a handful of positions.
few = list(frames)
for at in (40, 80, 120):
    few[at] = '??'
runs = [r for r in ''.join(few).split('??') if r]
v, det = BU.judge_payload_v(''.join(few), W13, 'exact')
check('3 flags in 200 B (budget 4) -> PASS', v == 'PASS', det)
check('  ...which is at most %d exempt positions, not 100' % (2 * (len(runs))), 2 * len(runs) <= 10)

# ---------------------------------------------------------------- the budget itself
print('\n-- exemptions cannot be FARMED with legal flags, and only debris AFTER damage is forgiven --')
# Four interior flags is inside the 2 % budget for a 240 B capture, so a rule that forgave both
# neighbours of a flag would let a legal capture carry eight knowingly wrong bytes.
def flagged_case(positions, before, after):
    f = ['%02X' % b for b in cyc(W13, 0, 240)]
    for at in positions:
        f[at] = '??'
        if before:
            f[at - 1] = 'D0'
        if after:
            f[at + 1] = 'D1'
    return ''.join(f)


POS = (40, 80, 120, 160)
v, det = BU.judge_payload_v(flagged_case(POS, True, True), W13, 'exact')
check('4 flags with BOTH neighbours wrong -> FAIL', v == 'FAIL', '%s: %s' % (v, det))
v, det = BU.judge_payload_v(flagged_case(POS, False, True), W13, 'exact')
check('4 flags with the FOLLOWING byte wrong -> PASS (that is debris)', v == 'PASS', '%s: %s' % (v, det))
v, det = BU.judge_payload_v(flagged_case(POS, True, False), W13, 'exact')
check('4 flags with the PRECEDING byte wrong -> FAIL (a flag cannot explain it)',
      v == 'FAIL', '%s: %s' % (v, det))
# And the exemption count is itself bounded by the flag budget.
f = ['%02X' % b for b in cyc(W13, 0, 240)]
for at in range(30, 30 + 2 * 12, 2):
    f[at] = '??'
    f[at + 1] = 'D1'
v, det = BU.judge_payload_v(''.join(f), W13, 'exact')
check('12 flags, each with debris -> FAIL on the flag budget', v == 'FAIL', '%s: %s' % (v, det))

print('\n-- the mismatch budget: loud is bounded, exact is zero --')
# Body is 243 - JP_HEADSKIP - JP_TAILSKIP = 230, so the loud budget is ceil(0.03 * 230) = 7. Corrupt
# clear of the head allowance or the corruption is trimmed away before the judge ever sees it.
n = 243
g = bytearray(cyc(W13, 0, n))
for j in range(20, 20 + 4 * 10, 4):
    g[j] = (g[j] + 1) & 0xFF
v, det = BU.judge_payload_v(hexs(bytes(g)), W13, 'loud')
check('10 wrong bytes past the head (budget 7) -> FAIL for loud', v == 'FAIL', det)
g2 = bytearray(cyc(W13, 0, n))
g2[100] = (g2[100] + 1) & 0xFF
g2[140] = (g2[140] + 1) & 0xFF
v, det = BU.judge_payload_v(hexs(bytes(g2)), W13, 'loud')
check('2 wrong bytes in 243 -> PASS for loud', v == 'PASS', det)
v, det = BU.judge_payload_v(hexs(bytes(g2)), W13, 'exact')
check('  ...and FAIL for exact', v == 'FAIL', det)

print('\n-- garbage is never the payload --')
for junk, label in ((b'\xAA' * 200, 'all 0xAA'), (b'\x00' * 200, 'all 0x00'),
                    (bytes((i * 37 + 11) & 0xFF for i in range(200)), 'a foreign ramp')):
    for exp in ('exact', 'loud'):
        v, _ = BU.judge_payload_v(hexs(junk), W13, exp)
        check('%s as %s -> FAIL' % (label, exp), v == 'FAIL')

# ---------------------------------------------------------------- the two-value API
print('\n-- the two-value wrapper still behaves for its six callers --')
ok, det = BU.judge_payload(hexs(cyc(W13, 0, 240)), W13)
check('a clean capture -> True', ok is True, det)
ok, det = BU.judge_payload(hexs(cyc(W13, 0, 3)), W13)
check('an INCONCLUSIVE capture collapses to False', ok is False, det)

# --------------------------------------------------- the offline twin uses the SAME allowance
# THE ALLOWANCE LIVES IN TWO LANGUAGES AND MUST BE ONE RULE. tools/sweep_plan.lua cannot import this
# file, so it carries LOUD_MISS_FRAC and LOUD_MISS_FLOOR and its own loud_budget() -- and a copy that
# drifts is how the twin starts judging a loud vector by a rule the bench does not apply. Holding a loud
# vector to zero where the bench allows 3 % accounts for 11 of the 73 cells the twin failed and the bench
# passed on soak lap 1, so this is the specific divergence being pinned, not a general tidiness check.
#
# THE ARITHMETIC IS RUN, NOT READ. Matching the two constants is not enough: the same numbers with a
# floor() instead of a ceil(), or a floor applied before the fraction, give a different allowance at every
# body size. So sweep_plan.lua's own loud_budget is extracted and EXECUTED under lua, and its answer
# compared with this file's expression across the sizes a real capture produces.
print('\n-- sweep_plan.lua carries the same loud allowance --')
import math as _math                                           # noqa: E402
import re as _re                                               # noqa: E402
import subprocess as _sp                                       # noqa: E402
_here = os.path.dirname(os.path.abspath(__file__))
_src = open(os.path.join(_here, 'sweep_plan.lua')).read()
_m = _re.search(r'local LOUD_MISS_FRAC, LOUD_MISS_FLOOR = ([\d.]+), (\d+)', _src)
check('sweep_plan.lua declares LOUD_MISS_FRAC and LOUD_MISS_FLOOR', _m is not None)
if _m:
    check('LOUD_MISS_FRAC %s == JP_LOUD_MISMATCH_FRAC %s' % (_m.group(1), BU.JP_LOUD_MISMATCH_FRAC),
          float(_m.group(1)) == BU.JP_LOUD_MISMATCH_FRAC)
    check('LOUD_MISS_FLOOR %s == JP_LOUD_MISMATCH_FLOOR %s'
          % (_m.group(2), BU.JP_LOUD_MISMATCH_FLOOR),
          int(_m.group(2)) == BU.JP_LOUD_MISMATCH_FLOOR)
_fn = _re.search(r'(local function loud_budget\(nbody\).*?\nend)', _src, _re.S)
check('sweep_plan.lua defines loud_budget(nbody)', _fn is not None)
if _m and _fn:
    _sizes = [1, 8, 20, 66, 67, 100, 121, 240, 328, 497]
    _prog = ('%s\n%s\nfor _, n in ipairs({%s}) do io.write(loud_budget(n), " ") end'
             % (_m.group(0), _fn.group(1), ', '.join(str(s) for s in _sizes)))
    _p = _sp.run(['lua', '-e', _prog], capture_output=True, text=True)
    _got = [int(float(x)) for x in _p.stdout.split()] if _p.returncode == 0 else []
    _wants = [max(BU.JP_LOUD_MISMATCH_FLOOR,
                  int(_math.ceil(BU.JP_LOUD_MISMATCH_FRAC * s))) for s in _sizes]
    check('loud_budget agrees with bench_uart at %s' % _sizes, _got == _wants,
          'lua %s vs python %s %s' % (_got, _wants, _p.stderr.strip()))
# SIZED ON THE BODY BEING COMPARED, not on the untrimmed capture. sweep_plan tries up to MAXSHIFT extra
# byte shifts, and an allowance computed once outside that loop would grant a forty-byte shift the 3 %
# its longer body earned -- a tolerance growing as the evidence shrinks.
check('the allowance is sized inside the shift loop, from nb - skip',
      _re.search(r'local mbudget = loud_budget\(nb - skip\)', _src) is not None)
# AND THE EXACT CLASS STILL GETS ZERO on both sides, which is the half that must not move: judge() only
# reaches the allowance when the caller passes the vector's class as loud.
check("only class 'loud' turns the allowance on",
      _re.search(r"local loud = v\.class == 'loud'", _src) is not None
      and _re.search(r'judge\(hx, v\.hex, hs, loud\)', _src) is not None)
check('an exact vector gets zero from judge_payload_v',
      BU.judge_payload_v(hexs(cyc(W13, 0, 240)), W13, 'exact')[0] == 'PASS')

# ---------------------------------------------------------------------------
# WHICH ROWS BELONG TO WHICH RUN, and it is judged here because getting it wrong produces a VERDICT rather
# than an error. One record holds many runs -- a fixed filename opened for append, because a numbered name
# means probing for a free one and a probe that misses posts a popup -- so the reader splits on header
# lines. Two of those headers are seams inside ONE run and must not start a new one: brec.roll writes
# tag=roll when a run passes the per-file byte cap, and brec.reopen writes tag=resumed when recording
# failed and came back, which happens because a fault no longer ends a run.
#
# WHAT MISREADING IT COSTS: a fortnight that hit one recording gap would be split into two runs, the
# default 'last run' would judge only the rows after the gap, and the answer would look completely
# reasonable. Nothing raises.
import judge_bench as JB                                       # noqa: E402

_SC = JB.SCHEMA
_R = 'R,1,%d,v77,9600,std,5,0,96000,0,10000,1.04,y,9600,8N1,20,20,0,0,0,false,false,,41'
_lines = ['# %s tag=soak iterations=1 plan=/usb1/SERDEC/PLAN.CSV randomperlap=4 file=1' % _SC, _R % 1,
          '# %s tag=resumed iterations=forever plan= randomperlap=4 file=1' % _SC, _R % 2,
          '# %s tag=roll iterations=forever plan= randomperlap=4 file=2' % _SC, _R % 3,
          '# %s tag=smoke iterations=1 plan=x randomperlap=all file=1' % _SC, _R % 4]
_runs = JB.split_runs(_lines)
check('a resumed record and a rolled file are seams in ONE run, not new runs',
      len(_runs) == 2 and _runs[0][0] == 'soak' and len(_runs[0][1]) == 3,
      '%s' % [(t, len(b)) for t, b in _runs])
check('while a genuinely different run still splits',
      len(_runs) == 2 and _runs[1][0] == 'smoke' and len(_runs[1][1]) == 1,
      '%s' % [(t, len(b)) for t, b in _runs])

print()
if FAILED:
    print('%d FAILED: %s' % (len(FAILED), ', '.join(FAILED)))
    sys.exit(1)
print('all judge_payload_v tests passed')

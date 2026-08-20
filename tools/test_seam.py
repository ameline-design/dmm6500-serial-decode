#!/usr/bin/env python3
"""The arb loop seam must not make the judge discard a correct capture.

WHAT THIS PINS, AND WHY THE EXISTING GATE DID NOT. On 2026-08-19, five laps of 58 failed as
`capture too short to judge (1 B, 0 judged) after a FLAGGED 226-byte head` on lorem at 115200 and
250000. Every one was a CORRECT decode: the surviving hex read "Lorem ipsum dolor s". The bench had
been trimming `r.headsusp` bytes before judging, and headsusp is the distance to the first idle gap --
which, on a payload longer than one capture, is the ARB LOOP SEAM. When the seam landed late in the
window the judge threw the whole capture away and then failed the point for being short.

The gate written alongside the fix pinned `head_damage()` with hand-built hex. **That would not have
caught this bug**, because the defect was never in the helper -- it was in the CALLER'S ARGUMENT to
judge_payload. So this file drives the real path: the real payload and render options taken from the
vector table, the real TSP decoder, a real capture window at every start offset across one arb period,
and then BOTH judging rules applied to the identical captures.

THE TEST IS THE DIFFERENCE BETWEEN THE TWO RULES, not the absence of failures under one of them. A
regression test that cannot fail against the code as it was is not a regression test -- the first
attempt at one for the r06 crash passed with the fix removed. So this REQUIRES the old rule to fail:
if trimming by headsusp ever stops failing here, the reproduction has drifted and the gate is empty.

    python3 tools/test_seam.py            # ~2 s, no instrument
"""
import binascii
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_uart as BU                                                  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRIDE = 4          # payload bytes between capture offsets; the failure band is ~20 bytes wide
LINE = re.compile(r'^S (\d+) nf=(\d+) headsusp=(\S+) head_bad=(\d+) nbad=(\d+) hex=([0-9A-F?]+)$')

npass = nfail = 0


def ck(cond, what):
    global npass, nfail
    if cond:
        npass += 1
        print('  ok   %s' % what)
    else:
        nfail += 1
        print('  FAIL %s' % what)


def main():
    p = subprocess.run(['lua', 'tools/seam_capture.lua', str(STRIDE), 'v71'],
                       cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode('utf-8', 'replace')
    if p.returncode != 0:
        print(out[-2000:])
        print('seam_capture.lua exited %d' % p.returncode)
        return 1

    payload = None
    caps = []
    exposed = None
    for line in out.splitlines():
        if line.startswith('# payloadhex='):
            payload = binascii.unhexlify(line.split('=', 1)[1])
        elif line.startswith('# cap_bytes='):
            exposed = 'exposed=true' in line
        m = LINE.match(line)
        if m:
            off, nf, hs, hb, nbad, hexs = m.groups()
            caps.append({'off': int(off), 'nf': int(nf),
                         'headsusp': 0 if hs == 'nil' else int(hs),
                         'head_bad': int(hb), 'nbad': int(nbad), 'hex': hexs})

    if payload is None or not caps:
        print(out[-2000:])
        print('could not parse the capture dump')
        return 1

    print('%d captures, payload %d B' % (len(caps), len(payload)))
    # THE PRECONDITION, ASSERTED NOT ASSUMED: this failure class needs the payload to be LONGER than
    # one capture, so the window holds at most one seam and idle1 can be late. If a future change to
    # sdec.n or the vector makes the capture longer than the payload, the class becomes unreachable
    # and every check below would pass while testing nothing.
    ck(exposed is True, 'the payload is longer than one capture, so the seam CAN land late')

    old_fail, new_fail, seam_seen = [], [], 0
    for c in caps:
        if c['headsusp'] > 0:
            seam_seen += 1
        # OLD rule: trim by the suspect region.
        ok_old, det_old = BU.judge_payload(c['hex'][2 * c['headsusp']:], payload)
        # NEW rule: trim by the damage the hex actually shows.
        hd = BU.head_damage(c['hex'], c['headsusp'])
        ok_new, det_new = BU.judge_payload(c['hex'][2 * hd:], payload)
        if not ok_old:
            old_fail.append((c['off'], c['headsusp'], det_old))
        if not ok_new:
            new_fail.append((c['off'], c['headsusp'], hd, det_new))

    print('  captures whose head is inside the seam region: %d of %d' % (seam_seen, len(caps)))
    ck(seam_seen > 0, 'the sweep actually reaches the seam (headsusp > 0 somewhere)')

    # DISCRIMINATION. Without this the gate is decoration.
    ck(len(old_fail) > 0,
       'trimming by headsusp FAILS %d of %d captures -- the bug is reproduced'
       % (len(old_fail), len(caps)))
    if old_fail:
        off, hs, det = old_fail[0]
        print('       e.g. offset %d, headsusp %d: %s' % (off, hs, det))

    ck(len(new_fail) == 0,
       'trimming by head_damage fails NONE of %d captures' % len(caps))
    for off, hs, hd, det in new_fail[:5]:
        print('       offset %d headsusp %d head_damage %d: %s' % (off, hs, hd, det))

    # AND THE DECODES THEMSELVES WERE FINE ALL ALONG, which is the fact that makes the old failures
    # false rather than merely harsh: no capture in the sweep carried many flagged frames.
    worst = max(c['nbad'] for c in caps)
    ck(worst <= 8, 'no capture has more than 8 flagged frames (worst %d) -- the decoder was never '
                   'the problem' % worst)
    hbmax = max(c['head_bad'] for c in caps)
    hsmax = max(c['headsusp'] for c in caps)
    ck(hbmax < hsmax,
       'head_damage stays far below headsusp (max %d vs %d) -- the two are not the same quantity'
       % (hbmax, hsmax))

    print()
    print('%d passed, %d failed' % (npass, nfail))
    return 1 if nfail else 0


if __name__ == '__main__':
    sys.exit(main())

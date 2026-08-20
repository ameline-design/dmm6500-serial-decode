#!/usr/bin/env python3
"""Reproduce the SDG2122X remote-interface hang, minimally and on demand.

THE FAILURE, on firmware 2.01.01.38R4:
repeated C1:WVDT waveform uploads of 170-210 kB stopped the generator answering on BOTH
5025 and 5024. Connections were still ACCEPTED and nothing was ever answered, including
*IDN?. It went on playing the loaded waveform correctly and indefinitely -- the DMM
confirmed 3.31 V of signal while the LAN was dead -- so the failure is invisible from the
signal side. Waiting did not clear it (45 s), and it progressed from "touchscreen
responsive, LAN dead" to the front-panel Output button not responding either. Recovery was
a power cycle, and this generator has no smart plug.

SINCE RE-MEASURED ON 39R7, AND THE VARIABLE IS THE COUNT, NOT THE SIZE: the third over-ceiling
write wedged it after 533 kB in total, while a 1.63 MB and then a 6.51 MB write on one power
cycle -- 8.14 MB together -- left it answering and playing correctly. So this script's own
--kb is the less interesting knob; --max is the one that reproduces.

WHY A SCRIPT: the hang was found while doing something else, so the trigger is only known
to within "several large uploads". A one-purpose script turns that into a number -- how
many uploads, at what size -- which is what a firmware bug report needs and what tells us
whether a new firmware actually fixed it.

USAGE (deliberately explicit -- this is a script whose success is an instrument you have to
power cycle):

    python3 tools/sdg_hang_repro.py --dry              # show the plan, touch nothing
    python3 tools/sdg_hang_repro.py --arm              # actually try to hang it
    python3 tools/sdg_hang_repro.py --arm --kb 64      # smaller payloads
    python3 tools/sdg_hang_repro.py --check            # is it answering right now?

It stops at the FIRST unresponsive query and reports the upload count and total bytes, so
the answer is a number rather than "it eventually died". Between uploads it re-queries,
which is what distinguishes "N uploads" from "N bytes in flight".
"""
import argparse
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import instruments as I
# For the size floor ONLY -- the socket work here stays raw on purpose (see upload()).
import siglent as S

PORTS = (5025, 5024)


def alive(ip, port=5025, timeout=6):
    """Does it answer *IDN?  Returns the reply, or None."""
    try:
        s = socket.socket()
        s.settimeout(timeout)
        s.connect((ip, port))
        s.sendall(b'*IDN?\n')
        try:
            r = s.recv(4096)
        except socket.timeout:
            r = b''
        try:
            s.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        s.close()
        r = r.decode(errors='replace').strip()
        return r if r else None
    except Exception:
        return None


def ramp(npts):
    """A triangle. Content is irrelevant to the bug; only the byte count matters, and a
    ramp makes a truncated upload obvious on the scope if anyone looks."""
    half = npts // 2
    up = [int(-32000 + 64000 * i / max(1, half - 1)) for i in range(half)]
    return up + up[::-1][:npts - half]


def upload(ip, name, codewords, port=5025, settle=0.0):
    """One C1:WVDT. Raw socket rather than tools/siglent.py on purpose: siglent.py now
    settles in proportion to payload size and retries its read-back, which are the
    mitigations -- this has to be able to reproduce the ORIGINAL behaviour."""
    payload = struct.pack('<%dh' % len(codewords), *codewords)
    # THE SIZE FLOOR IS NOT ONE OF THE MITIGATIONS, so bypassing the driver must not bypass it.
    # This script's whole purpose is to hammer the generator with WVDT writes until its LAN service
    # wedges, and `--kb 0` produced a ZERO-LENGTH waveform on a raw socket with nothing in the way --
    # which does not wedge the instrument, it BRICKS it at the next power-up, and the power cycle that
    # this script's own recovery step calls for is what detonates it.
    S.sdg_check_wave_payload(payload)
    s = socket.socket()
    s.settimeout(20)
    s.connect((ip, port))
    s.sendall(('C1:WVDT WVNM,%s,WAVEDATA,' % name).encode() + payload + b'\n')
    if settle:
        time.sleep(settle)
    try:
        s.shutdown(socket.SHUT_RDWR)
    except Exception:
        pass
    s.close()
    return len(payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', default=I.SDG_IP)
    ap.add_argument('--kb', type=int, default=200, help='payload size per upload, kB')
    ap.add_argument('--max', type=int, default=12, help='give up after this many uploads')
    ap.add_argument('--settle', type=float, default=0.0,
                    help='seconds to wait after each upload (0 reproduces the original)')
    ap.add_argument('--arm', action='store_true',
                    help='REQUIRED to upload anything. Without it, nothing is sent.')
    ap.add_argument('--check', action='store_true', help='just report responsiveness')
    ap.add_argument('--dry', action='store_true', help='print the plan and exit')
    a = ap.parse_args()

    npts = (a.kb * 1024) // 2
    plan = ('%d uploads of %d kB (%d points) to %s, re-querying *IDN? between each'
            % (a.max, a.kb, npts, a.ip))

    if a.dry:
        print('PLAN: ' + plan)
        print('would send C1:WVDT WVNM,hang<N>,WAVEDATA,<%d bytes>' % (npts * 2))
        print('\nnothing sent -- pass --arm to actually run it')
        return 0

    print('firmware / identity check first, so a hang is attributable:')
    for p in PORTS:
        print('  port %d: %s' % (p, alive(a.ip, p) or '<no reply>'))
    if a.check:
        return 0

    if not a.arm:
        print('\nrefusing to upload without --arm.')
        print('A successful reproduction leaves an instrument that needs a POWER CYCLE,')
        print('and this generator has no smart plug -- it costs a human. ' + plan)
        return 2

    print('\n' + plan)
    total, n = 0, 0
    for i in range(a.max):
        try:
            total += upload(a.ip, 'hang%d' % i, ramp(npts), settle=a.settle)
            n += 1
        except Exception as e:
            print('  upload %d FAILED to send: %s' % (i + 1, e))
            print('  -> the socket itself broke, which is a different symptom '
                  'from "accepted and silent"')
            break
        r = alive(a.ip)
        print('  upload %2d  %6.1f kB total  *IDN? -> %s'
              % (n, total / 1024.0, r or 'NO REPLY'))
        if r is None:
            print('\nHUNG after %d uploads / %.1f kB.' % (n, total / 1024.0))
            for p in PORTS:
                print('  port %d: %s' % (p, alive(a.ip, p) or '<no reply>'))
            print('The signal is probably still playing -- check with the DMM or the scope;')
            print('that asymmetry (output fine, LAN dead) is the distinguishing symptom.')
            print('Recovery: POWER CYCLE the generator.')
            return 1
    print('\nSurvived %d uploads / %.1f kB without hanging.' % (n, total / 1024.0))
    print('38R4 hung within a handful of 170-210 kB uploads and 39R7 on the THIRD over-ceiling')
    print('write, so a clean run here is evidence only for the count reached -- raise --max')
    print('rather than --kb before concluding anything is fixed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Report 3: find the exact statement length at which the execute path raises -363, and separate
length from cumulative bytes.

    python3 docs/vendor/repro-03-buffer-overrun.py --ip 10.0.1.151
    python3 docs/vendor/repro-03-buffer-overrun.py --ip 10.0.1.151 --soak 2000

Standard library only: no app, no signal, no second instrument. The USB key is not touched.

THE HANDSHAKE IS THE POINT. Every statement prints its own acknowledgement and the host reads that reply
before sending anything else, so the host is never more than one statement ahead of the interpreter. A
buffer overrun under those conditions cannot be a rate problem.

A FRESH SOCKET PER ATTEMPT during the bisect. A statement that overruns may leave the parser holding a
fragment, and the next attempt on the same connection would then measure the fragment rather than the
length under test.
"""
import argparse
import socket
import sys
import time

PROBE = 'do local s = "%s" print("LEN=" .. tostring(string.len(s))) end'


class Sess:
    def __init__(self, ip, port=5025, timeout=10):
        self.s = socket.create_connection((ip, port), timeout=timeout)
        self.buf = b''

    def ask(self, stmt, timeout=10):
        """Send one statement, return its reply line, or None if nothing came back."""
        self.s.sendall(stmt.encode() + b'\n')
        self.s.settimeout(timeout)
        while b'\n' not in self.buf:
            try:
                chunk = self.s.recv(4096)
            except (socket.timeout, TimeoutError):
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b'\n')
        return line.decode(errors='replace').strip()

    def send(self, stmt):
        self.s.sendall(stmt.encode() + b'\n')

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def attempt(ip, pad_n):
    """One statement of a known length on a fresh socket. -> (sent_bytes, reply, events, log)"""
    se = Sess(ip)
    se.ask('eventlog.clear() print("CLR")')
    stmt = PROBE % ('x' * pad_n)
    sent = len(stmt) + 1                       # the newline is part of what the parser is fed
    reply = se.ask(stmt)
    ev = se.ask('print("EV=" .. tostring(eventlog.getcount()))')
    first = ''
    if ev is not None and ev != 'EV=0':
        first = se.ask('print(eventlog.next())') or ''
    se.close()
    ok = (reply == 'LEN=%d' % pad_n) and ev == 'EV=0'
    return sent, reply, ev, first, ok


def bisect(ip, lo, hi):
    """Largest length that works, smallest that does not. lo must work and hi must fail."""
    print('bisecting between %d (expected ok) and %d (expected to fail)' % (lo, hi))
    sent, reply, ev, first, ok = attempt(ip, lo)
    print('  %5d pad, %5d bytes sent -> %-12s %-6s %s' % (lo, sent, reply, ev, first))
    if not ok:
        print('  the low end already fails; lower it')
        return None
    sent, reply, ev, first, hifail = attempt(ip, hi)
    print('  %5d pad, %5d bytes sent -> %-12s %-6s %s' % (hi, sent, reply, ev, first))
    if hifail:
        print('  the high end does not fail; raise it')
        return None
    while hi - lo > 1:
        mid = (lo + hi) // 2
        sent, reply, ev, first, ok = attempt(ip, mid)
        print('  %5d pad, %5d bytes sent -> %-12s %-6s %s' % (mid, sent, reply, ev, first))
        if ok:
            lo = mid
        else:
            hi = mid
        time.sleep(0.05)
    return lo, hi


def soak(ip, n, pad_n):
    """Many statements at a length known to work, to tell length from cumulative bytes."""
    se = Sess(ip)
    se.ask('eventlog.clear() print("CLR")')
    stmt = PROBE % ('x' * pad_n)
    per = len(stmt) + 1
    t0 = time.time()
    bad = 0
    for i in range(n):
        if se.ask(stmt) != 'LEN=%d' % pad_n:
            bad = i + 1
            break
    el = time.time() - t0
    ev = se.ask('print("EV=" .. tostring(eventlog.getcount()))')
    se.close()
    total = per * (bad or n)
    print('%d statement(s) of %d bytes = %d bytes in %.1f s (%.0f stmt/s), %s, first bad %s'
          % (bad or n, per, total, el, (bad or n) / el, ev, bad or 'none'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', default='10.0.1.151')
    ap.add_argument('--lo', type=int, default=600)
    ap.add_argument('--hi', type=int, default=2000)
    ap.add_argument('--soak', type=int, default=0,
                    help='send this many statements at the largest working length')
    a = ap.parse_args()
    r = bisect(a.ip, a.lo, a.hi)
    if r is None:
        return 1
    lo, hi = r
    print('LARGEST WORKING pad %d (%d bytes sent), SMALLEST FAILING pad %d (%d bytes sent)'
          % (lo, lo + len(PROBE) - 2 + 1, hi, hi + len(PROBE) - 2 + 1))
    if a.soak:
        soak(a.ip, a.soak, lo)
    return 0


if __name__ == '__main__':
    sys.exit(main())

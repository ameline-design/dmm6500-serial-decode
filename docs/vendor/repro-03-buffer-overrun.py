#!/usr/bin/env python3
"""Report 3: at what statement length does the execute path raise -363, with a strict handshake?

DMM6500, firmware 1.7.17a, LAN raw socket on port 5025. Nothing need be connected.

THE HANDSHAKE IS THE POINT. Every statement prints its own answer and the host reads that answer before
sending the next, so the host is never more than ONE statement ahead of the interpreter. If -363 still
appears, the input buffer is smaller than a single statement of that size -- which is not something a
throttle, a drain or an acknowledgement can fix.

    python3 repro-03-buffer-overrun.py 10.0.1.151
"""
import socket
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else '10.0.1.151'
PORT = 5025


def main():
    s = socket.create_connection((IP, PORT), timeout=30)
    rd = s.makefile('rb')

    def ask(stmt):
        s.sendall(stmt.encode() + b'\n')
        ln = rd.readline()
        return ln.decode('ascii', 'replace').strip()

    print('%s  %s' % (IP, ask('print(localnode.model, localnode.version)')))
    s.sendall(b'eventlog.clear()\n')

    # A LITERAL, NOT A COMMENT, because a comment might be discarded before the parser sees its length.
    # The statement does something with the string so it cannot be optimised away.
    prev_ok = 0
    for n in (200, 400, 600, 800, 1000, 1200, 1400, 1600, 2000, 2500, 3000, 4000):
        pad = 'x' * n
        try:
            r = ask('do local s = "%s" print("LEN=" .. tostring(string.len(s))) end' % pad)
            ev = ask('print("EV=" .. tostring(eventlog.getcount()))')
        except (socket.timeout, OSError) as e:
            print('%5d chars -> transport died: %s' % (n, e))
            break
        ok = r.startswith('LEN=%d' % n) and ev == 'EV=0'
        print('%5d chars -> %-16s %-8s %s' % (n, r[:16], ev, 'ok' if ok else 'FAILED'))
        if not ok:
            print('')
            print('First failure between %d and %d characters.' % (prev_ok, n))
            print('Read the reason:  print(eventlog.next())   -- expect -363 input buffer overrun')
            print(ask('print(eventlog.next())'))
            break
        prev_ok = n
    else:
        print('')
        print('No failure up to 4000 characters -- then the limit is elsewhere, and the 19 MB transfer')
        print('that raised -363 at ~1960 characters needs re-examining as a cumulative effect instead.')

    # THE CONTRAST THAT MAKES IT A REPORT: the STORE path takes far more, with no handshake at all.
    print('')
    print('For comparison, loadscript with no flow control moved 805285 bytes / 14686 lines in 1.0 s')
    print('on this instrument, event log 0.')
    s.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

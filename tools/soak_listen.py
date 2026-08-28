#!/usr/bin/env python3
"""Listen for the instrument's own progress lines during an unattended soak.

    python3 tools/soak_listen.py                       # log to stdout and out/bench/listen.log
    python3 tools/soak_listen.py --port 5099 --quiet

WHY PUSHED RATHER THAN POLLED. While a TSP script runs it holds the instrument's interpreter, so the LAN
command interface cannot answer a question about the run's progress -- a query mid-lap gets nothing, and
opening a second control socket corrupts both sessions. So the run announces itself instead:
bench/bench_run.tsp opens a tspnet connection to this listener once per cell, writes one line, and closes
it, all inside a pcall.

THAT pcall IS THE WHOLE DESIGN. If nothing is listening the connect fails, the failure is swallowed, and
the soak carries on -- so this tool is a window, never a dependency. Start it, stop it, restart it
mid-run: the instrument neither knows nor cares, and an eight-day run does not become contingent on a
laptop staying awake.

WHAT IT IS NOT. Not the record. The record is the CSV on the USB key, written cell by cell and readable
after a power cycle; these lines are a convenience for watching. If the two ever disagree, the key is
right -- it was written by the instrument at the moment of measurement, and this was written by whatever
managed to cross the network.
"""
import argparse
import os
import socket
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=5099)
    ap.add_argument('--out', default=os.path.join(ROOT, 'out', 'bench', 'listen.log'))
    ap.add_argument('--quiet', action='store_true', help='log to the file only')
    a = ap.parse_args()

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('', a.port))
    srv.listen(8)
    # A TIMEOUT ON accept, so ^C is answered promptly rather than after the next cell -- which at 300
    # baud can be forty seconds away.
    srv.settimeout(1.0)
    print('listening on :%d -- logging to %s' % (a.port, a.out))
    print('(the soak does not depend on this: it connects inside a pcall and ignores a refusal)')
    n = 0
    with open(a.out, 'a') as f:
        f.write('# soak_listen started %s\n' % time.strftime('%Y-%m-%dT%H:%M:%S'))
        f.flush()
        try:
            while True:
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                conn.settimeout(5.0)
                try:
                    data = b''
                    while b'\n' not in data:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                except (socket.timeout, OSError):
                    pass
                finally:
                    conn.close()
                for ln in data.decode('utf-8', 'replace').splitlines():
                    if not ln.strip():
                        continue
                    n += 1
                    stamp = time.strftime('%H:%M:%S')
                    f.write('%s %s\n' % (stamp, ln))
                    f.flush()
                    if not a.quiet:
                        print('%s  %s' % (stamp, ln))
        except KeyboardInterrupt:
            print('\n%d line(s) received' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())

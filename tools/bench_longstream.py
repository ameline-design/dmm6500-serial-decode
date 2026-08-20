#!/usr/bin/env python3
"""Does 4800 baud really deliver the longest stream the app offers, complete and in order?

The app describes the STREAM mode as "no byte cap -- runs until Stop or the buffer fills", and
neither "unlimited" nor "until a quiet line" would be true. At 4800 Bd it is bounded by
`ck_bufmax` = 2 800 000 readings at 20 kS/s, which is 140 s -- and 4800 Bd is
under the ~100 000 readings/s buffer-write ceiling, so those are real-time seconds. This tool settles
all of that on the bench instead of by arithmetic:

  1. How long does the buffer actually take to stop filling, and does it stop at nsmp?
  2. Does the recording end ITSELF, or does the app only notice when the operator presses?
  3. Are the decoded bytes ONE UNBROKEN RUN over the whole recording -- not a 400-byte sample?

(3) is the one that matters and the one that has not been done properly before. It uses the 1024-byte
NON-REPEATING `v71` payload, reconstructs every byte from the log file the app wrote, and looks for
the longest contiguous slice. A repeating payload cannot detect a splice; this can.

Needs the app already built -- run straight after a release sweep, which leaves it up.

    python3 tools/bench_longstream.py                 # 4800 Bd, the full 140 s
    python3 tools/bench_longstream.py --baud 9600 --cap 60
"""
import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_matrix as BM                                  # noqa: E402
import bench_uart as BU                                    # noqa: E402
from dmmrun import DMM                                     # noqa: E402
from siglent import SDG                                    # noqa: E402
import vector_names as VN                                     # noqa: E402

ROW = re.compile(r'^(\d{4})\s+((?:[0-9A-F]{2}|--|\s{2})(?:\s+(?:[0-9A-F]{2}|--))*)\s*\|')

DUMP_TSP = r'''
function ls_dump(p, skip)
  local f = file.open(p, file.MODE_READ)
  if f == nil then print('L NOFILE') print('===EOF===') return end
  local n = 0
  while true do
    local ln = nil
    local ok = pcall(function() ln = file.read(f, file.READ_LINE) end)
    if not ok or ln == nil or ln == '' then break end
    n = n + 1
    if n > skip then print('L ' .. ln) end
    if n > skip + 1200 then break end
  end
  file.close(f)
  print('===EOF===')
end
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=4800)
    ap.add_argument('--cap', type=float, default=170.0,
                    help='give up waiting for the buffer to stop filling after this many seconds')
    ap.add_argument('--max-steps', type=int, default=200)
    a = ap.parse_args()

    d = DMM()
    if (d.q('print(tostring(sdec ~= nil and sdec.built == true))') or '').strip() != 'true':
        print('REFUSING: no app on the panel. Run this after a sweep, which leaves it built.')
        return 2
    for ln in d.load_script('lsmod', DUMP_TSP + "\nprint('===DONE===')\n", timeout=120):
        if ln and ln not in ('===DONE===',):
            print('  load: %s' % ln)

    with open(os.path.join(BU.VECDIR, BM.LOREM_ARB + '.txt'), 'rb') as f:
        payload = f.read()
    print('payload: %d bytes, non-repeating (%r...)' % (len(payload), payload[:20]))

    g = SDG()
    g.select_arb(VN.arb(BM.LOREM_ARB), 10.0, int(round(a.baud * BM.LOREM_SPB)))
    g.write('C1:OUTP ON,LOAD,HZ,PLRT,NOR')
    time.sleep(0.5)

    d.exec('eventlog.clear()', timeout=10)
    d.exec('sdec.force_baud, sdec.force_nbits = %d, nil' % a.baud, timeout=10)
    d.exec("sdec.capmode = 'med'", timeout=10)
    d.exec('sdec.ck_job, sdec.strm_recording, sdec.ck_running = nil, nil, false', timeout=10)
    why = (d.q('print(tostring(sdec.mode_why(sdec.mode_cur())))') or '').strip()
    mode = (d.q('print(tostring(sdec.mode_cur().name))') or '').strip()
    if why != 'nil':
        print('mode refused at %d Bd: %s' % (a.baud, why))
        return 2
    nsmp = (d.q('print(tostring(sdec.stream_samples(sdec.mode_cur(), '
                'sdec.fs_for_burst(%d))))' % a.baud) or '').strip()
    fsq = (d.q('print(tostring(sdec.fs_for_burst(%d)))' % a.baud) or '').strip()
    print('mode %s at %d Bd: target %s readings at %s S/s -> %.1f s of signal'
          % (mode, a.baud, nsmp, fsq, float(nsmp) / float(fsq)))

    print('\n--- start press, then watch the buffer WITHOUT pressing stop ---')
    d.exec('pcall(function() sdec.capture() end)', timeout=60)
    t0 = time.time()
    last, plateau_at, samples = -1, None, []
    while time.time() - t0 < a.cap:
        n = (d.q('print(tostring(sdec.buf and sdec.buf.n))') or '').strip()
        el = time.time() - t0
        if n.isdigit():
            n = int(n)
            samples.append((el, n))
            if n == last and plateau_at is None and n > 0:
                plateau_at = el
                print('  buffer stopped growing at %.1f s with %d readings' % (el, n))
                break
            last = n
            if el % 20 < 1.2:
                print('  %6.1f s  buf.n = %d' % (el, n))
        time.sleep(1.0)
    if plateau_at is None:
        print('  did not plateau within %.0f s (last buf.n = %s)' % (a.cap, last))

    stat = (d.q('print(tostring(sdec.strm_recording) .. "|" .. tostring(sdec.ui_status) '
                '.. "|" .. tostring(sdec.ck_endwhy))') or '').strip()
    print('  app state while the hardware sits full: strm_recording|ui_status|endwhy = %s' % stat)

    print('\n--- stop press, then step the decode ---')
    d.exec('pcall(function() sdec.capture() end)', timeout=300)
    steps = 0
    while (d.q('print(tostring(sdec.ck_job ~= nil))') or '').strip() == 'true' \
            and steps < a.max_steps:
        d.exec('pcall(function() sdec.capture() end)', timeout=180)
        steps += 1
    tot = (d.q('print(tostring(sdec.ck_tot and sdec.ck_tot.nf) .. "|" .. '
               'tostring(sdec.ck_tot and sdec.ck_tot.nbad) .. "|" .. '
               'tostring(sdec.flog_path))') or '').strip()
    nf, nbad, path = (tot.split('|') + ['?'] * 3)[:3]
    ev = (d.q('print(tostring(eventlog.getcount()))') or '').strip()
    print('  decode finished in %d presses: %s bytes, %s bad, file %s, events %s'
          % (steps, nf, nbad, path, ev))

    if path in ('nil', '?', ''):
        print('  no log path -- cannot check contiguity')
        return 1

    print('\n--- reconstructing every byte from %s ---' % path)
    rows, skip = {}, 0
    while True:
        d.drain()
        d.send('ls_dump(%r, %d)' % (path, skip))
        got = 0
        while True:
            ln = d.line(180)
            if ln is None or ln == '===EOF===':
                break
            if ln.startswith('L '):
                got += 1
                m = ROW.match(ln[2:].strip())
                if m:
                    off = int(m.group(1))
                    hx = [b for b in m.group(2).split() if b != '--']
                    try:
                        rows[off] = bytes.fromhex(''.join(hx))
                    except ValueError:
                        pass
        if got == 0:
            break
        skip += got
        if got < 1200:
            break
    if not rows:
        print('  parsed no data rows -- log format may have changed')
        return 1
    blob = b''.join(rows[k] for k in sorted(rows))
    print('  %d rows parsed -> %d bytes reconstructed' % (len(rows), len(blob)))

    hay = payload * (len(blob) // len(payload) + 3)
    best, bi, i = 0, 0, 0
    while i < len(blob):
        if blob[i:i + 1] not in hay:
            i += 1
            continue
        L = 1
        while i + L <= len(blob) and blob[i:i + L] in hay:
            L += 1
        L -= 1
        if L > best:
            best, bi = L, i
        i += max(L, 1)
    print('  longest contiguous slice of the payload: %d of %d bytes (%.1f%%)'
          % (best, len(blob), 100.0 * best / max(len(blob), 1)))
    print('\n' + '-' * 74)
    ok = True
    if plateau_at is None:
        print('INCONCLUSIVE  the buffer never stopped filling inside %.0f s' % a.cap)
        ok = False
    elif nsmp.isdigit() and abs(last - int(nsmp)) > 200:
        print('FAIL  stopped at %d readings, not the %s it asked for' % (last, nsmp))
        ok = False
    if best >= 0.98 * len(blob):
        print('PASS  the recording is ONE UNBROKEN RUN: %d of %d bytes contiguous against a '
              'non-repeating payload' % (best, len(blob)))
    else:
        print('FAIL  the record is SPLICED -- longest unbroken run is %d of %d bytes'
              % (best, len(blob)))
        ok = False
    if ev not in ('0', ''):
        print('FAIL  %s instrument event(s) logged' % ev)
        ok = False
    print('-' * 74)
    d.exec('pcall(function() sdec.mode_exit("test done") end)', timeout=60)
    try:
        g.output(False, ch=1)
    except Exception:
        pass
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Why does the same line give 70 bytes on one capture and 240 on the next?

The detected BAUD was exact on all 32 matrix points, so this is not a rate error reaching the panel.
Something in the two-pass auto-detect picks a sample rate an octave high, and the window is a fixed
number of SAMPLES -- so twice the sample rate is half the bytes. This prints, for a run of identical
unlocked captures, every quantity the byte count could depend on, so the one that actually moves is
visible rather than inferred.

    python3 tools/diag_yield.py --baud 9600 --repeat 12
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
from siglent import SDG
import bench_matrix as MX

YIELD_TSP = r'''
-- The PROBE pass's answer, which nothing normally keeps: autoset() overwrites sdec.baud on the
-- second pass, so the octave error -- if that is what this is -- is invisible by the time the
-- capture returns. Wrapping pick_fs is the cheapest way to see what it was ASKED for.
dg_seen = nil
if dg_pick_orig == nil then dg_pick_orig = sdec.pick_fs end
function sdec.pick_fs(baud, minsab)
  local fs = dg_pick_orig(baud, minsab)
  if dg_seen == nil then dg_seen = {} end
  dg_seen[table.getn(dg_seen) + 1] = string.format('%s->%s', tostring(baud), tostring(fs))
  return fs
end

function dg_yield(nrep)
  local k
  for k = 1, nrep do
    eventlog.clear()
    dg_seen = {}
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
    local ok = sdec.capture()
    local r = sdec.res
    local wb = nil
    if r ~= nil then
      pcall(function() wb = sdec.window_bytes(sdec.baud, r.nbits, r.par, r.nstop) end)
    end
    print(string.format('Y %d ok=%s baud=%s fs=%s acq_fs=%s n=%s nread=%s nf=%s ' ..
                        'sabit=%s win=%s pick=%s',
                        k, tostring(ok), tostring(sdec.baud), tostring(sdec.fs),
                        tostring(sdec.acq_fs), tostring(sdec.n), tostring(sdec.nread),
                        tostring(r and r.nf),
                        tostring(sdec.acq_fs and sdec.baud and sdec.acq_fs / sdec.baud),
                        tostring(wb), table.concat(dg_seen, ' ')))
  end
  print('Y end')
end
print('===DONE===')
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--repeat', type=int, default=12)
    ap.add_argument('--arb', default='v80')
    a = ap.parse_args()

    g, d = SDG(), DMM()
    try:
        g.select_arb(a.arb, MX.amp_for(3.3), int(a.baud * MX.RATE_SPB))
        g.output(True, ch=1)
        time.sleep(0.4)
        d.send('print("SYNC")')
        for _ in range(8):
            if d.line(5) == 'SYNC':
                break
        for ln in d.load_script('dgymod', YIELD_TSP, timeout=120):
            if ln and ln != '===DONE===':
                print('  dgymod: ' + ln)
        d.drain()
        d.send('dg_yield(%d)' % a.repeat)
        rows = []
        while True:
            ln = d.line(300)
            if ln is None:
                print('  timeout')
                break
            if ln.startswith('Y ') and ln != 'Y end':
                print('  ' + ln)
                rows.append(ln)
            if ln == 'Y end':
                break
    finally:
        try:
            g.output(False, ch=1)
        except Exception:
            pass
        g.close()
        d.close()

    nfs = {}
    for ln in rows:
        f = dict(kv.split('=', 1) for kv in ln.split() if '=' in kv)
        nfs.setdefault(f.get('acq_fs', '?')[:6], []).append(f.get('nf'))
    print('\nbytes decoded, grouped by the sample rate the capture ran at:')
    for fs, nf in sorted(nfs.items()):
        print('  %-8s S/s : %s' % (fs, ', '.join(str(x) for x in nf)))
    return 0


if __name__ == '__main__':
    sys.exit(main())

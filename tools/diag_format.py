#!/usr/bin/env python3
"""Why does a hardware capture of v44a disagree with the offline decode of the same file?

Isolates the two candidates separately, on the app already running:
  * FORMAT CHOICE   -- force 7E1 and see whether the bytes come out exact. If they do, the
                       signal is fine and only ua_autoformat's verdict is in question.
  * SIGNAL QUALITY  -- print every frame with its error flag and the edge/level statistics, so a
                       recurring error at one position in the looping payload is visible as such.
Repeated, because a capture starts at a random phase of the loop and a fault that moves is a
different fault from one that does not.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
from siglent import SDG
import bench_matrix as MX
import vector_names as VN                                     # noqa: E402

DIAG_TSP = r'''
function dg_point(vid, nb, par)
  eventlog.clear()
  sdec.force_baud = nil
  sdec.force_nbits, sdec.force_par = nb, par
  sdec.force_nstop, sdec.force_invert = nil, nil
  local ok = sdec.capture()
  local r = sdec.res
  print(string.format('D ok=%s baud=%s fmt=%s nf=%s nbad=%s ne=%s nread=%s fs=%s ' ..
                      'lo=%s hi=%s thr=%s hyst=%s bittime=%s fit=%s modal=%s',
                      tostring(ok), tostring(sdec.baud), tostring(sdec.fmt_text()),
                      tostring(r and r.nf), tostring(r and r.nbad), tostring(sdec.ne),
                      tostring(sdec.nread), tostring(sdec.acq_fs), tostring(sdec.lo),
                      tostring(sdec.hi), tostring(sdec.thr), tostring(sdec.hyst),
                      tostring(sdec.bittime), tostring(sdec.fitq), tostring(sdec.modal)))
  if r ~= nil and r.nf ~= nil then
    local i, seg, n = nil, {}, 0
    for i = 1, r.nf do
      n = n + 1
      if r.errs[i] == nil then
        seg[n] = string.format('%02X', r.vals[i])
      else
        seg[n] = string.format('[%02X:%s]', r.vals[i] or 0, tostring(r.errs[i]))
      end
      if n >= 24 then print('F ' .. table.concat(seg, ' ')); seg, n = {}, 0 end
    end
    if n > 0 then print('F ' .. table.concat(seg, ' ')) end
  end
  -- The first 40 edges as GAPS IN BIT TIMES. A capture that begins mid-byte has no 1.5-bit mark
  -- run to anchor on, and ua_run's fallback then takes the first candidate edge -- which inside a
  -- byte is a data transition. If that is what happens, it is visible here as a first gap that is
  -- not a whole number of bit times.
  local T = sdec.bittime
  if sdec.ne ~= nil and sdec.ne > 1 and T ~= nil and T > 0 then
    local m = sdec.ne
    if m > 40 then m = 40 end
    local seg, n, j = {}, 0, nil
    for j = 1, m do
      n = n + 1
      if j == 1 then
        seg[n] = string.format('@%.1f/%d', sdec.ei[1], sdec.es[1])
      else
        seg[n] = string.format('%.2f/%d', (sdec.ei[j] - sdec.ei[j - 1]) / T, sdec.es[j])
      end
    end
    print('E ' .. table.concat(seg, ' '))
    -- Where each of the first frames was anchored, in BIT TIMES from the start of the capture.
    -- A frame pitch that is not a whole number of bit times is a misanchored frame.
    if r ~= nil and r.tpos ~= nil then
      local m2, s2, n2 = r.nf, {}, 0
      if m2 > 14 then m2 = 14 end
      for j = 1, m2 do
        n2 = n2 + 1
        s2[n2] = string.format('%.2f', r.tpos[j] / T)
      end
      print('P ' .. table.concat(s2, ' '))
    end
  end
  print('D end')
end
print('===DONE===')
'''


def run(d, vid, nb, par, timeout=240):
    d.drain()
    d.send('dg_point(%r, %s, %s)' % (vid, nb or 'nil', par or 'nil'))
    out = []
    while True:
        ln = d.line(timeout)
        if ln is None:
            out.append('D timeout')
            break
        out.append(ln)
        if ln == 'D end':
            break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vectors', default='v44a,v44d,v44e,v41')
    ap.add_argument('--repeat', type=int, default=2)
    a = ap.parse_args()

    g, d = SDG(), DMM()
    try:
        out = d.load_script('dgmod', DIAG_TSP, timeout=120)
        for ln in out:
            if ln and ln != '===DONE===':
                print('  dgmod: ' + ln)
        for vid in a.vectors.split(','):
            g.select_arb(VN.arb(vid), MX.amp_for(3.3), MX.FORMAT_SRATE)
            g.output(True, ch=1)
            time.sleep(0.4)
            # auto, then the format the file was WRITTEN in -- forced, so the choice is out of it
            forced = {'v44a': (7, 'sdec.PAR_EVEN'), 'v44b': (7, 'sdec.PAR_ODD'),
                      'v44c': (8, 'sdec.PAR_EVEN'), 'v44d': (8, 'sdec.PAR_ODD'),
                      'v44e': (8, 'sdec.PAR_NONE'), 'v41': (8, 'sdec.PAR_NONE')}[vid]
            for label, nb, par in (('auto', None, None), ('forced', forced[0], forced[1])):
                for k in range(a.repeat):
                    print('\n--- %s %s run %d ---' % (vid, label, k + 1))
                    for ln in run(d, vid, nb, par):
                        print('  ' + ln)
        print('\n--- event log ---')
        for m in d.errors():
            print('  ' + str(m))
    finally:
        g.close()
        d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

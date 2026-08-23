#!/usr/bin/env python3
"""Rear TRIGGER IN: does an external pulse start a decode, and is it the SOLE source?

Two questions, and the second is the one with teeth. sdec.trigext OR's the rear input with the analog
start-bit trigger, so on a line that never stops transmitting the start bit always wins and the
external pulse cannot decide where the window opens. sdec.trigext_only makes the rear BNC exclusive.

FOUR CASES. The negatives are the evidence: acq_triggered() falls back to a FREE-RUNNING capture when
no trigger arrives, and a free-run still returns samples -- so "it completed" proves nothing by itself.

    quiet line, OR mode,   marker ON   -> completes fast
    quiet line, OR mode,   marker OFF  -> refuses, naming the source
    live  line, ONLY mode, marker OFF  -> MUST TIME OUT: proves the comparator is excluded
    live  line, ONLY mode, marker ON   -> completes fast, armed by the marker

BENCH WIRING: SDG CH2 -> DMM rear TRIGGER IN, split to scope CH3. The marker is a built-in PULSE, not
an arb, so no WVDT upload is involved.

    python3 tools/bench_trigin.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM              # noqa: E402
from siglent import SDG             # noqa: E402

WAIT = 6.0

SCRIPT_TMPL = """
sdec.lasterr = nil
local keep = {tm = sdec.trigmode, tx = sdec.trigext, xo = sdec.trigext_only, thr = sdec.thr,
              fs = sdec.fs, n = sdec.n, pre = sdec.pretrig, tw = sdec.trigwait_ext}
sdec.trigmode = 'edge'
sdec.trigext = true
sdec.trigext_only = ONLY
sdec.thr = 0.0            -- mid-swing for a +/-5 V line, so the start bit CAN fire in OR mode
sdec.trigwait_ext = WAITS
sdec.fs = 100000
sdec.n = 2000
sdec.pretrig = 5
local nread = -1
local ok, err = pcall(function() nread = sdec.acq_triggered(sdec.n, dmm.SLOPE_FALLING) end)
print(string.format('RESULT nread=%s ok=%s blended=%s lasterr=%s',
                    tostring(nread), tostring(ok), tostring(sdec.trigblended),
                    tostring(sdec.lasterr)))
sdec.trigmode, sdec.trigext, sdec.trigext_only = keep.tm, keep.tx, keep.xo
sdec.thr, sdec.fs, sdec.n, sdec.pretrig, sdec.trigwait_ext = keep.thr, keep.fs, keep.n, keep.pre, keep.tw
pcall(function() trigger.blender[1].reset() end)
pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
print('===DONE===')
"""


def run_case(d, only, label):
    body = SCRIPT_TMPL.replace('ONLY', 'true' if only else 'false').replace('WAITS', str(WAIT))
    t0 = time.time()
    out = d.load_script('extonly', body, run=True, timeout=60)
    el = time.time() - t0
    line = next((str(l).strip() for l in out if str(l).startswith('RESULT')), '')
    print('  %-34s %5.1f s  %s' % (label, el, line or ('RAW %r' % (out,))))
    return el, line


def main():
    g = d = None
    try:
        g = SDG()
        print('SDG:', g.idn())
        g.write('C2:CMBN OFF')
        g.write('C2:BSWV WVTP,PULSE,FRQ,100,AMP,5,OFST,2.5,WIDTH,5e-05,RISE,1e-07,FALL,1e-07')
        # LIVE signal line for every case below -- that is the whole point.
        g.write('C1:OUTP ON,LOAD,HZ')
        print('CH1 (signal):', g.query('C1:OUTP?'))
        print('CH1 arb     :', g.query('C1:ARWV?'))

        d = DMM()
        print('DMM:', d.q('*IDN?'))
        print()

        g.write('C2:OUTP OFF'); time.sleep(0.3)
        el_or, ln_or = run_case(d, False, 'OR mode,   marker OFF, live line')

        g.write('C2:OUTP OFF'); time.sleep(0.3)
        el_xo, ln_xo = run_case(d, True, 'ONLY mode, marker OFF, live line')

        g.write('C2:OUTP ON,LOAD,HZ'); time.sleep(0.3)
        el_on, ln_on = run_case(d, True, 'ONLY mode, marker ON,  live line')

        print()
        print('=== verdict ===')
        or_fast = el_or < WAIT and 'lasterr=nil' in ln_or
        only_timed_out = el_xo >= WAIT * 0.8 and 'trigger unavailable' in ln_xo
        only_fired = el_on < WAIT and 'lasterr=nil' in ln_on
        print('  OR mode fired on the start bit          : %s  (%.1f s)'
              % ('YES' if or_fast else 'NO', el_or))
        print('  ONLY mode IGNORED the busy line         : %s  (%.1f s)'
              % ('YES' if only_timed_out else 'NO', el_xo))
        print('  ONLY mode fired on the marker           : %s  (%.1f s)'
              % ('YES' if only_fired else 'NO', el_on))
        print()
        if or_fast and only_timed_out and only_fired:
            print('  PASS -- trigext_only makes the rear BNC the sole trigger source')
        else:
            print('  NOT PROVEN -- read the three RESULT lines above')
        g.write('C2:OUTP OFF')
    finally:
        for h in (d, g):
            try:
                if h is not None:
                    h.close()
            except Exception:
                pass


if __name__ == '__main__':
    main()

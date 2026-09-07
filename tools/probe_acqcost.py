#!/usr/bin/env python3
"""How long does a cell's fixed cost actually take, phase by phase, on the instrument itself?

WHY. A soak cell costs ~4 s and ~2.95 s of that is charged to cells that never decode at all, so it is
not the decode. The generator conversation was measured at -0.097 s a cell -- zero -- so it is not the
SCPI either. That leaves the acquisition path, and serial_core.tsp:1733 carries a note proposing exactly
this measurement and calling it 'worth doing early':

    timer.cleartime(); local rd = buf.readings; local s = 0
    for i = 1, 20000 do s = s + rd[i] end
    print(timer.gettime() / 20000)        -- seconds per proxy read

sdec.acq_copy() does that loop for real, 20000 indexed reads through a buffer proxy, once per cell. If a
proxy read costs 100 us this is 2 s and it IS the fixed cost; if it costs 2 us it is 40 ms and the time
is somewhere else entirely. Those two answers demand opposite work, which is why guessing is expensive.

WHAT IT MEASURES, each timed on the instrument with its own timer rather than over the socket, so LAN
latency is not in any figure:

  proxy read      the acq_copy loop, per sample and in total
  bulk read       printbuffer over the same range, which returns the whole span in ONE firmware call.
                  If the proxy loop is slow and this is not, acq_copy can be replaced and the samples
                  are IDENTICAL -- the measurement does not change at all, only the time around it.
  digitize        dmm.digitize.read for the same count: the irreducible part, n/fs plus overhead
  record append   one row to the FAT key, and the syncrows cycle that periodically flushes
  table build     building a 20000-entry Lua table with no buffer involved, as the floor

THE INSTRUMENT MUST BE IDLE. This takes the control socket and clears the global timer, so it cannot run
against a live soak -- brun.soak owns the interpreter and the connect or the exec simply fails.

DISARMS THE RECORDING ABSORB FIRST. There is ONE timer; strm_absorb_arm() uses it as a timestamp, and an
unrelated cleartime() makes an arm from minutes ago look current -- which once made a host tool file good
vectors as BAD for a whole soak. tools/bench_matrix.py's mx_point() takes it in the same order.

    python3 tools/probe_acqcost.py [--n 20000]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM                                                     # noqa: E402

# ONE STATEMENT PER MEASUREMENT, each printing a tagged line. Tagged because a bare sequence of prints
# desynchronises by one the moment anything unexpected arrives on the socket, and then every number is
# plausible and attributed to the wrong phase -- which is exactly how a generator snapshot came back with
# its fields shifted earlier today.
STEPS = [
    ('table-build', """
        local t = os.time()
        sdec.strm_stopped_by_press = nil
        timer.cleartime()
        local x = {}
        for i = 1, %(n)d do x[i] = i end
        print('ACQCOST table-build ' .. tostring(timer.gettime()))
    """),
    ('digitize', """
        sdec.strm_stopped_by_press = nil
        sdec.fs, sdec.fs_want = 1000000, 1000000
        sdec.trigmode = 'free'
        timer.cleartime()
        local ok, why = sdec.acquire()
        print('ACQCOST digitize ' .. tostring(timer.gettime()) .. ' ok=' .. tostring(ok)
              .. ' n=' .. tostring(sdec.nsmp or 0))
    """),
    ('proxy-read', """
        sdec.strm_stopped_by_press = nil
        local rd = sdec.buf.readings
        local s = 0
        timer.cleartime()
        for i = 1, %(n)d do s = s + rd[i] end
        local el = timer.gettime()
        print('ACQCOST proxy-read ' .. tostring(el) .. ' per=' .. tostring(el / %(n)d))
    """),
    ('acq-copy', """
        sdec.strm_stopped_by_press = nil
        timer.cleartime()
        local t = sdec.acq_copy(sdec.buf, %(n)d)
        print('ACQCOST acq-copy ' .. tostring(timer.gettime()) .. ' got=' .. tostring(table.getn(t)))
    """),
    # printbuffer FORMATS THE WHOLE RANGE IN ONE FIRMWARE CALL. Written to a discarded string rather than
    # printed, because printing 20000 values would flood the control socket and the point is the read cost.
    ('bulk-read', """
        sdec.strm_stopped_by_press = nil
        timer.cleartime()
        local ok = pcall(function()
          local s = printbuffer(1, %(n)d, sdec.buf.readings)
          BULKLEN = string.len(s)
        end)
        print('ACQCOST bulk-read ' .. tostring(timer.gettime()) .. ' ok=' .. tostring(ok)
              .. ' bytes=' .. tostring(BULKLEN or 0))
    """),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=20000, help='samples per measurement')
    a = ap.parse_args()

    d = DMM()
    try:
        # print() IS MANDATORY HERE. d.q sends the statement RAW and reads one line; it does not wrap the
        # argument. A bare expression is not a Lua statement, so it comes back as -285 TSP syntax error --
        # which reads exactly like a missing app, and pops on the panel of an instrument nobody asked.
        built = d.q('print(type(sdec) .. " " .. tostring(sdec ~= nil and sdec.built))')
        print('sdec: %s' % built)
        if built is None or not built.startswith('table'):
            raise SystemExit('the app is not loaded -- run tools/run_app.py --captures 0 first. '
                             'A power cycle leaves sdec and brun nil.')
        print('\n%-14s %12s %14s  %s' % ('phase', 'seconds', 'per sample', 'note'))
        for name, body in STEPS:
            stmt = ('do ' + (body % {'n': a.n}).strip() + ' end').replace('\n', ' ')
            d.send(stmt)
            line = None
            for _ in range(40):
                line = d.line(timeout=30)
                # TAGGED, so an unsolicited event line cannot be read as a measurement. The DMM prints
                # error-severity events onto this same socket unasked.
                if line is not None and 'ACQCOST' in line:
                    break
            if line is None or 'ACQCOST' not in line:
                print('%-14s %12s %14s  no reply' % (name, '-', '-'))
                continue
            f = line.strip().split()
            try:
                secs = float(f[2])
            except (IndexError, ValueError):
                print('%-14s  unparsable: %r' % (name, line.strip()))
                continue
            print('%-14s %12.4f %14.3f us  %s'
                  % (name, secs, 1e6 * secs / a.n, ' '.join(f[3:])))
        print('\nIf proxy-read is a large share of a cell, acq_copy can be replaced with a bulk read and')
        print('the samples are IDENTICAL -- same frames, same verdicts, same ratchets, less time.')
        print('If it is small, the fixed cost is the digitize or the record write and this is a dead end.')
    finally:
        # RESTORED, because the next tool must not have to trust that this one tidied up. fs and trigmode
        # were changed by the digitize step and a soak started afterwards would inherit them.
        d.exec('do sdec.fs, sdec.fs_want = sdec.fs_default, nil sdec.trigmode = nil end')
        d.close()


if __name__ == '__main__':
    main()

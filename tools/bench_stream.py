#!/usr/bin/env python3
"""Drive a recording to a FULL BUFFER on real hardware, in ONE PRESS, and check what the buffer's
end does. The gap this fills is named in the source itself.

`stream_arm()` applies two defences against event **4915** "attempting to store past the capacity of
a reading buffer": `fillmode = 1` per capture, and 100 readings of capacity past the count SimpleLoop
is asked for. 4915 is ERROR severity, which the front panel shows as a MODAL DIALOG over the app
whatever `localnode.showevents` says -- so it is not a cosmetic event, it is a box the operator has to
dismiss on top of their dump.

NEITHER DEFENCE CAN BE TESTED OFFLINE. The mock buffer enforces no capacity and never posts 4915, so
`test_streamfix.lua` can only assert that the two calls were MADE with the right arguments -- it
cannot observe the firmware's behaviour without them. And bench_panel.py runs the 8 kB window, which
at its rates does not reach the end of the largest buffer.

THE END OF THE BUFFER IS THE WHOLE POINT. The overshoot happens when the trigger model stores its
last readings before `abort()` takes effect, so the case that needs the headroom is a recording that
reaches `nsmp` -- its NORMAL ending, not an error path. This tool records past that point on purpose.

Rates are chosen so a full buffer arrives quickly: at 115200 Bd the 32 kB mode fills 1.82 M readings
in 2.8 s, where the same test at 9600 Bd takes 34 s. Slow rates take much longer -- 4800 Bd is 140 s
of recording -- so that case is opt-in via --slow.

ONE PRESS DOES THE WHOLE JOB, which is why this file does not count presses. Under a press-per-slice
path -- start, sleep, stop, then one press per decode slice -- the per-press latency bound is the thing
under test. The panel path records, decodes and files everything inside a single handler,
stoppable with the front-panel TRIGGER key, so what is under test here is that the press RETURNS,
that the buffer's end posts no 4915, and that no decode job is left open behind it.

    python3 tools/bench_stream.py              # the fast full-buffer cases
    python3 tools/bench_stream.py --slow       # adds 4800 Bd, a much longer recording
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM                                     # noqa: E402
from siglent import SDG
import bench_sync as BS                                    # noqa: E402
import vector_names as VN                                     # noqa: E402

# Informational trigger-model notices, excluded by number exactly as bench_panel.py does.
INFO_EVENTS = ('2731', '2732', '2728', '4917')

STREAM_TSP = r'''
function st_point(tag)
  eventlog.clear()
  -- DISARM THE QUEUED-PRESS ABSORB BEFORE TAKING THE TIMER. strm_absorb_arm() records WHEN a recording
  -- ended by clearing this same global timer, and strm_stopped_by_press is only a boolean -- so resetting
  -- the clock here makes an arm from minutes ago look current, capture() returns WITHOUT CAPTURING, and
  -- this function reports the PREVIOUS result as this point's. Measured in bench_matrix, where it filed
  -- good vectors as BAD for a whole soak.
  sdec.strm_stopped_by_press = nil
  timer.cleartime()
  -- BOTH VERDICTS. `pcall`'s result only says capture() did not RAISE; capture() returns its own boolean
  -- and a polite refusal returns false without raising. Reading the pcall alone let a refused recording
  -- PASS on whatever ck_tot the previous run had left behind.
  local cok = false
  local pok, err = pcall(function() cok = sdec.capture() end)
  local ok = (pok and cok)
  local t = timer.gettime()
  local ec, emsg = eventlog.getcount(), ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
  end
  local bn = nil
  if sdec.buf ~= nil then bn = sdec.buf.n end
  print(string.format('S %s|%s|%.3f|%s|%s|%s|%s|%s|%s|%s|%s',
        tostring(tag), tostring(ok), t,
        tostring(sdec.strm_recording), tostring(sdec.ck_job ~= nil),
        tostring(sdec.ck_nbytes), tostring(sdec.ck_endwhy), tostring(bn),
        tostring(sdec.flog_bytes), tostring(sdec.lasterr), emsg))
end
print('===DONE===')
'''


def real_events(blob):
    if not blob:
        return 0, ''
    parts = [c for c in blob.split('][') if c.strip('[] ')]
    keep = [c for c in parts if not any(n in c for n in INFO_EVENTS)]
    return len(keep), ''.join(keep)


def n4915(blob):
    return (blob or '').count('4915')


def press(d, tag, timeout=180):
    d.drain()
    d.send('st_point(%r)' % tag)
    while True:
        ln = d.line(timeout)
        if ln is None:
            return {'fail': 'timeout'}
        if ln.startswith('S ') and '|' in ln:
            f = ln[2:].split('|')
            return {'tag': f[0], 'ok': f[1] == 'true', 'secs': float(f[2]),
                    'recording': f[3] == 'true', 'job': f[4] == 'true',
                    'nbytes': f[5], 'endwhy': f[6], 'bufn': f[7],
                    'logbytes': f[8], 'lasterr': f[9], 'events': f[10]}


def case(g, d, a, baud, capmode, record_s, label):
    """ONE PRESS: record to the end of the buffer, decode all of it, file it, and return.

    record_s is not a sleep between two presses -- one press does the whole job -- so it serves only
    as the expectation of how long that press should take, which is what the report compares
    against.
    """
    print('\n' + '=' * 78)
    print('%s -- %d Bd, capmode %r, one press (expect roughly %g s of recording)'
          % (label, baud, capmode, record_s))
    print('=' * 78)

    g.select_arb(VN.arb('v80'), 10.0, int(baud * 10.0), offset_v=0.0)
    g.write('C1:OUTP ON,LOAD,HZ,PLRT,NOR')
    time.sleep(0.4)
    d.exec('sdec.force_baud, sdec.force_nbits = %d, nil' % baud, timeout=10)
    # THE SHARED PREFLIGHT: align, refuse a live run, unwind a resting streaming mode through mode_exit(),
    # clear the previous result, disarm the absorb, verify. Nilling ck_job/strm_recording/ck_running
    # instead is not a reset but a leak -- a live recording keeps filling a buffer nobody will read and an
    # open decode job is never closed nor flushed -- and it would then test a setup it had just corrupted.
    # st_point() resets the global timer, so the absorb disarm is mandatory here. See tools/bench_sync.py.
    BS.preflight(d, 'bench_stream')
    d.exec("sdec.capmode = %r" % capmode, timeout=10)

    why = (d.q('print(tostring(sdec.mode_why(sdec.mode_cur())))') or '').strip()
    nsmp = (d.q('print(tostring(sdec.stream_samples(sdec.mode_cur(), '
                'sdec.fs_for_burst(sdec.force_baud))))') or '').strip()
    print('mode refuses? %s     buffer target: %s readings' % (why, nsmp))
    if why != 'nil':
        print('SKIPPED: the mode declined at this rate')
        return None

    ev4915, realev, rows = 0, [], []

    # ONE PRESS FOR THE WHOLE JOB, rather than start, sleep, stop and a press per decode slice --
    # 12 presses for a full buffer. The press-driven path is still in the app (sdec.strm_press = true)
    # and tools/test_streamfix.lua covers it; what ships on the panel is this: the handler records,
    # decodes and files everything before it returns.
    print('  ... one press: recording and decoding, no interaction (up to %d s) ...'
          % a.press_timeout)
    r = press(d, '%s-oneshot' % label, timeout=a.press_timeout)
    if 'fail' in r:
        print('  THE PRESS NEVER RETURNED in %d s -- that is the failure a hang looks like'
              % a.press_timeout)
        return {'label': label, 'ok': False, 'why': 'press timeout'}
    rows.append(r)
    ev4915 += n4915(r['events'])
    nre, txt = real_events(r['events'])
    if nre:
        realev.append(txt)
    worst, worst_tag, steps = r['secs'], r['tag'], 1
    print('  one press    %6.3f s  buf.n=%s  endwhy=%s  bytes=%s  job=%s  4915=%d  events=%s'
          % (r['secs'], r['bufn'], r['endwhy'], r['nbytes'], r['job'],
             n4915(r['events']), txt or 'none'))
    # A JOB LEFT OPEN MEANS THE PRESS DID NOT FINISH THE WORK, which is the whole regression this
    # rewrite is guarding: it would mean the panel is back to a press per slice.
    if r.get('job'):
        print('  FAIL  a decode job is still open after the press returned')
        realev.append('[decode job left open]')
    # THE APP'S OWN VERDICT IS PART OF THE TEST, not just collected. A capture that REFUSED -- no
    # locked rate, no buffer, a mode that cannot run -- returns false without raising, and every other
    # check here can still pass on the previous run's leftovers.
    if not r.get('ok'):
        print('  FAIL  the app refused or failed the capture: %s' % (r.get('lasterr') or 'no reason given'))
        realev.append('[capture returned false]')
    # AND IT HAS TO HAVE ENDED AT THE BUFFER, which is what "full buffer recorded" claims. 'quiet' or
    # 'stopped' here is a shorter recording than the test says it measured.
    if r.get('endwhy') != 'full':
        print('  FAIL  the recording ended %r, not at the full buffer -- this test claims a full one'
              % r.get('endwhy'))
        realev.append('[ended %s]' % r.get('endwhy'))

    final = d.q('print(tostring(sdec.ck_tot and sdec.ck_tot.nf) .. "|" .. '
                'tostring(sdec.ck_tot and sdec.ck_tot.nbad) .. "|" .. '
                'tostring(sdec.ck_tot and sdec.ck_tot.stopped) .. "|" .. '
                'tostring(sdec.flog_path))') or ''
    nf, nbad, stopped, path = (final.strip().split('|') + ['?'] * 4)[:4]
    print('  done in %d press; it took %.3f s (%s)' % (steps, worst, worst_tag))
    print('  result: %s bytes, %s err, ended %r, file %s' % (nf, nbad, stopped, path))

    ok = True
    if ev4915:
        print('  FAIL  4915 posted %d time(s) -- a store past the buffer capacity. That is a modal\n'
              '        dialog over the operator\'s dump, and the headroom is supposed to prevent it.'
              % ev4915)
        ok = False
    if realev:
        print('  FAIL  real instrument event(s) logged: %s' % ' '.join(realev))
        ok = False
    # NO PER-PRESS LATENCY BOUND, deliberately: a press is a whole recording, so its duration is the
    # window size the operator chose. What IS a failure is a press that never returns, which the
    # timeout above catches.
    try:
        if int(nf) <= 0:
            print('  FAIL  no bytes decoded')
            ok = False
    except ValueError:
        print('  FAIL  byte count unreadable: %r' % nf)
        ok = False
    if ok:
        print('  PASS  full buffer recorded and fully decoded: 0 x 4915, no real events, '
              'worst press %.3f s' % worst)

    d.exec('pcall(function() sdec.mode_exit("test done") end)', timeout=30)
    return {'label': label, 'ok': ok, 'presses': steps + 2, 'worst': worst,
            'nf': nf, '4915': ev4915, 'endwhy': r.get('endwhy')}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--slow', action='store_true',
                    help='also run 4800 Bd -- a much longer recording')
    ap.add_argument('--press-timeout', type=int, default=900,
                    help='seconds to wait for the one press to return before calling it a hang')
    a = ap.parse_args()

    d = DMM()
    print('DMM: %s' % (d.q('print(localnode.model .. "  " .. localnode.version)') or '').strip())
    if (d.q('print(tostring(sdec ~= nil and sdec.built == true))') or '').strip() != 'true':
        print('REFUSING: no app on the panel. Run this straight after a sweep, which leaves it up.')
        return 2
    for ln in d.load_script('stmod', STREAM_TSP, timeout=120):
        if ln and ln != '===DONE===':
            print('  load: %s' % ln)
    g = SDG()

    out = []
    # 2.8 s to a full buffer at 115200; 34 s at 9600. Both recorded 30% past the end so the
    # recording ends by FILLING rather than by the stop press.
    out.append(case(g, d, a, 115200, 'med', 4.0, '32kB@115200'))
    out.append(case(g, d, a, 9600, 'med', 40.0, '32kB@9600'))
    if a.slow:
        out.append(case(g, d, a, 4800, 'med', 150.0, '32kB@4800'))

    try:
        g.output(False, ch=1)
    except Exception:
        pass

    out = [o for o in out if o]
    print('\n' + '=' * 78)
    bad = [o for o in out if not o['ok']]
    for o in out:
        print('  %-14s %-4s  %4s presses  worst %.3f s  %s bytes  4915=%s  ended %s'
              % (o['label'], 'ok' if o['ok'] else 'BAD', o.get('presses', '?'),
                 o.get('worst', 0.0), o.get('nf', '?'), o.get('4915', '?'),
                 o.get('endwhy')))
    print('%d of %d streaming cases clean' % (len(out) - len(bad), len(out)))
    resid = (d.q('print(eventlog.getcount())') or '').strip()
    print('residual event log (must be 0): %s' % resid)
    return 1 if (bad or resid not in ('0', '')) else 0


if __name__ == '__main__':
    sys.exit(main())

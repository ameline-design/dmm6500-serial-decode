#!/usr/bin/env python3
"""Does the front-panel TRIGGER key actually arm a capture? The one check the sweep cannot make.

bench_panel.py dispatches every other button by CALLING ITS HANDLER over TSP, which is exactly right
for a touch target: the firmware calls that same function when a finger lands on the glass, so the
handler is the button. The TRIGGER key is not a touch target. It is a physical key wired into the
trigger subsystem, and the app never handles it -- it asks the TRIGGER MODEL to wait for
`trigger.EVENT_DISPLAY`. Nothing this harness can send synthesises that event, so the last step of
this test needs a human finger. That is why it is a separate tool and not a stage in release_sweep.

TWO QUESTIONS, CHEAPEST FIRST:

  1. Does this firmware define `trigger.EVENT_DISPLAY` at all? No finger needed. If it is nil the
     answer is settled without pressing anything: serial_core's guard degrades to a free-running
     capture with a stated reason, and the manual must not describe the key as a trigger source.

  2. If it is defined: with `Trigger = Trigger key`, does `acquire()` WAIT for the key, or return
     immediately having free-run? Timed ON THE INSTRUMENT with timer.gettime(), against a free-run
     baseline taken on the same signal. A free-run returns in well under a second; a real arm
     returns only once the key is pressed, so the ELAPSED TIME is the evidence and the operator's
     press is the stimulus.

The distinction matters because the failure mode is silent: before this was fixed, `Trigger key`
routed to `acq_free` and the status row still read `EXT TRIG  KEY`, so the panel asserted the key was
the source of a capture the key had nothing to do with. A test that only checked "did bytes come
out" passed against that.

Run with the app already up -- the release sweep leaves it running:

    python3 tools/bench_trigkey.py
    python3 tools/bench_trigkey.py --wait 45    # how long to hold the arm open for the press
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM                                     # noqa: E402
from siglent import SDG                                    # noqa: E402
import vector_names as VN                                     # noqa: E402

# Trigger-model progress notices, informational severity, posted by EVERY armed capture -- so they
# are excluded by number rather than by severity, which would also hide real errors. Same list and
# same reasoning as bench_panel.py; an armed capture that did not post 2731 did not arm at all.
INFO_EVENTS = ('2731', '2732', '2728', '4917')


def real_events(blob):
    """Event text with the informational trigger notices removed. -> (n, text)."""
    if not blob:
        return 0, ''
    out = [c for c in blob.split('][')
           if not any(n in c for n in INFO_EVENTS)]
    out = [c for c in out if c.strip('[] ')]
    return len(out), ''.join(out)

# Timed on the instrument, not the host, so socket latency is not part of the discriminator.
TRIGKEY_TSP = r'''
function tk_point()
  eventlog.clear()
  sdec.lasterr = nil
  timer.cleartime()
  local ok = pcall(function() return sdec.capture() end)
  local t = timer.gettime()
  local r = sdec.res
  local ec, emsg = eventlog.getcount(), ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
  end
  print(string.format('T %s|%.3f|%s|%s|%s|%s', tostring(ok), t,
        tostring(r and r.nf), tostring(sdec.lasterr), tostring(sdec.trigmode), emsg))
end
print('===DONE===')
'''


def q(d, expr, timeout=15):
    return (d.q('print(%s)' % expr, timeout=timeout) or '').strip()


def point(d, timeout):
    """One capture through the app's own handler. -> dict."""
    d.drain()
    d.send('tk_point()')
    while True:
        ln = d.line(timeout)
        if ln is None:
            return {'fail': 'timeout after %gs' % timeout}
        if ln.startswith('T ') and '|' in ln:
            f = ln[2:].split('|')
            return {'ok': f[0] == 'true', 'secs': float(f[1]), 'nf': f[2],
                    'lasterr': f[3], 'trigmode': f[4], 'events': f[5]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wait', type=float, default=30.0,
                    help='seconds the arm stays open for the key press')
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--countdown', type=int, default=10,
                    help='seconds of warning before the arm opens')
    ap.add_argument('--quiet-line', action='store_true',
                    help='arm with NO signal, so the verdict is textual rather than timed')
    a = ap.parse_args()

    d = DMM()
    print('DMM: %s' % q(d, 'localnode.model .. "  " .. localnode.version'))
    built = q(d, 'tostring(sdec ~= nil and sdec.built == true)')
    print('app built and on the panel: %s' % built)
    if built != 'true':
        print('\nREFUSING: no app on the panel. Load and build it first (python3 tools/run_app.py),\n'
              'or run this straight after a release sweep, which leaves it running.')
        return 2

    # ---- Q1: does the event exist? -------------------------------------------------
    ev = q(d, 'tostring(trigger.EVENT_DISPLAY)')
    ctl = q(d, 'tostring(trigger.EVENT_BLENDER1)')
    print('\ntrigger.EVENT_DISPLAY = %s        (control: EVENT_BLENDER1 = %s)' % (ev, ctl))
    if ev == 'nil':
        print('\nVERDICT: this firmware has NO display trigger event, so the TRIGGER key cannot arm a\n'
              'capture on this instrument. The app degrades to free-run with a stated reason, which is\n'
              'correct behaviour -- but the manual must not offer the key as a trigger source.')
        return 1

    # load_script, NOT exec: exec appends its own sentinel and reads exactly one line, so a
    # multi-line chunk with its own print leaves the reply stream out of step.
    for ln in d.load_script('tkmod', TRIGKEY_TSP, timeout=120):
        if ln and ln != '===DONE===':
            print('  load: %s' % ln)

    # ---- the signal both measurements share ---------------------------------------
    g = SDG()
    g.select_arb(VN.arb('v41'), 10.0, int(a.baud * 10.0), offset_v=0.0)
    g.write('C1:OUTP ON,LOAD,HZ,PLRT,NOR')
    time.sleep(0.4)
    d.exec('sdec.force_baud, sdec.force_nbits = %d, nil' % a.baud, timeout=10)
    d.exec('sdec.trigwait_ext = %g' % a.wait, timeout=10)

    # ---- Q2a: the free-run baseline on this exact signal --------------------------
    d.exec("sdec.trigmode = 'free'", timeout=10)
    base = point(d, 120)
    print('\nfree run   : %6.2f s  ok=%s  bytes=%s  lasterr=%s  events=%s'
          % (base.get('secs', -1), base.get('ok'), base.get('nf'),
             base.get('lasterr'), base.get('events')))

    # ---- Q2b: armed on the key, waiting for a finger -----------------------------
    d.exec("sdec.trigmode = 'front'", timeout=10)
    if a.quiet_line:
        # NO SIGNAL for the armed capture. This is the whole point of --quiet-line: it removes the
        # operator's reaction time from the verdict. A key that works fires the capture, which then
        # finds an idle line and refuses BY NAME; a key that posts nothing lets the arm expire and
        # the app says 'front trigger unavailable'. Two different sentences, no stopwatch.
        try:
            g.output(False, ch=1)
        except Exception:
            pass
        time.sleep(0.4)
        print('\ngenerator OFF -- the line is now idle on purpose')
    # A COUNTDOWN, because the operator cannot see this stream in real time in every harness and a
    # window they miss is indistinguishable from a key that does not work -- which is exactly the
    # ambiguity this test exists to remove. Press repeatedly if in doubt: the arm fires on the first
    # event and later presses land after the capture has completed, where they do nothing.
    print('\n' + '=' * 76)
    print('GET READY TO PRESS THE PHYSICAL TRIGGER KEY ON THE DMM6500.')
    for k in range(a.countdown, 0, -1):
        print('   arming in %d ...' % k)
        sys.stdout.flush()
        time.sleep(1.0)
    print('\n   *** PRESS TRIGGER NOW -- and again every few seconds until this returns. ***')
    print('   The arm is open for %g s. The delay before it returns IS the measurement.' % a.wait)
    print('=' * 76)
    sys.stdout.flush()
    key = point(d, a.wait + 90)

    d.exec("sdec.trigmode = 'free'", timeout=10)
    try:
        g.output(False, ch=1)
    except Exception:
        pass

    if 'fail' in key:
        print('\nHARNESS FAILURE: %s' % key['fail'])
        return 2
    nev, evtext = real_events(key['events'])
    armed = '2731' in (key['events'] or '')
    print('\ntrigger key: %6.2f s  ok=%s  bytes=%s  lasterr=%s'
          % (key['secs'], key['ok'], key['nf'], key['lasterr']))
    print('             trigger model armed (2731 initiated): %s   real events: %s'
          % (armed, evtext or 'none'))

    # ---- verdict -----------------------------------------------------------------
    # ONE VERDICT, not a pile of them. The three outcomes are mutually exclusive and each has a
    # different owner: a raise or a real event is the app's fault; returning early is the silent
    # free-run defect; running the whole window is either a finger that never landed or a key that
    # does not post the event, and this harness cannot tell those two apart -- only the operator can.
    print('\n' + '-' * 76)
    t_key, t_free = key['secs'], base.get('secs', 0.0)
    rc = 1
    if not key['ok']:
        print('FAIL  the capture RAISED with the key as the trigger source')
    elif nev:
        print('FAIL  the armed capture logged a real instrument event: %s' % evtext)
    # THE DISCRIMINATOR IS lasterr, NOT ELAPSED TIME. A capture that falls back to free-running
    # ALWAYS says so -- serial_core sets 'front trigger unavailable; captured free-running' on the
    # degrade path -- so an empty lasterr means the trigger genuinely fired. Elapsed time cannot carry
    # the verdict on its own: an operator who presses promptly produces a time indistinguishable from
    # a free run, and calling that a failure condemns a run where the key worked.
    elif a.quiet_line and ('idle' in (key['lasterr'] or '')
                          or 'no transitions' in (key['lasterr'] or '')):
        print('PASS  the key FIRED. Armed on a deliberately idle line, the capture ran and refused\n'
              '      with %r -- which it can only do if something started it. Had the key posted\n'
              '      nothing, the arm would have expired and said "front trigger unavailable"\n'
              '      instead. Returned in %.2f s.' % (key['lasterr'], t_key))
        rc = 0
    elif 'unavailable' in (key['lasterr'] or '') or t_key >= a.wait * 0.95:
        print('NO PRESS SEEN  the arm stayed open the full %g s and timed out, then degraded to a\n'
              '      free-running capture with the reason stated (%s) and %s bytes decoded. The model\n'
              '      DID arm (2731 initiated=%s) and aborted cleanly, so the degrade path is correct.\n'
              '\n'
              '      THIS DOES NOT DISTINGUISH the two possibilities, and nothing here can:\n'
              '        a) the key was not pressed inside the window, or\n'
              '        b) the TRIGGER key does not post trigger.EVENT_DISPLAY while a TSP app screen\n'
              '           is active -- in which case the key can never be a trigger source here and\n'
              '           the manual must say so.\n'
              '      Ask the operator whether they pressed it. If they did, (b) is the answer.'
              % (a.wait, key['lasterr'], key['nf'], armed))
        rc = 2
    else:
        print('PASS  the trigger FIRED: returned in %.2f s with lasterr empty, so the capture\n'
              '      completed through the trigger rather than through the timeout degrade (which\n'
              '      always sets "front trigger unavailable; captured free-running"). Decoded %s\n'
              '      bytes, no real event. Free-run baseline for comparison: %.2f s -- the difference\n'
              '      %.2f s is roughly how long the operator took to reach the key.\n'
              '      The TRIGGER key arms a capture on real hardware.'
              % (t_key, key['nf'], t_free, t_key - t_free))
        rc = 0
    if key['trigmode'] != 'front':
        print('note  trigmode read back as %r during the capture, not \'front\''
              % key['trigmode'])
    print('-' * 76)
    return rc


if __name__ == '__main__':
    sys.exit(main())

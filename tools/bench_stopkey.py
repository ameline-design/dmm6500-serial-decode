#!/usr/bin/env python3
"""DOES THE TRIGGER KEY REACH A RUNNING RECORDING? One press, at a moment the host chooses.

WHY THIS EXISTS. The app polls for a cancel and the polling demonstrably works: a firmware trigger
timer blended in as blender 2's stimulus 2, fired 8 s into an 8 kB run, ends it inside one poll and
keeps every byte decoded. What does not work is a FINGER -- pressed 20 % into a 32 kB decode, the run
finishes 'full' with the latch EMPTY afterwards, so the press never reaches the blender.

WHAT IS STILL UNKNOWN, AND IT IS THE WHOLE POINT OF THIS FILE. Two measurements disagree and neither
covers the case that matters:

  bench_cancelkey.py   key press during a HOST-initiated busy loop        -> LATCHED (twice)
  the owner's runs     key press during a PANEL-initiated recording       -> nothing
  this file            key press during a HOST-initiated recording        -> ?

If this LATCHES, the blocker is the display-handler execution context: work started from a button's
event string cannot see the key, and the design rule becomes "do not do long work inside a handler".
If it does NOT latch, the recording state itself suppresses the key -- the trigger model's aftermath --
and bench_cancelkey's busy loop differs for some other reason. Either answer decides whether an
interruptible recording is reachable at all on this firmware.

IT DOES NOT NEED PERFECT TIMING. The run is ~20 s at 19200 baud and the poll granularity is about a
second, so any press in the middle third is decisive. The script says when to press and waits.

    python3 tools/bench_stopkey.py                  # 8 kB at whatever rate is locked
    python3 tools/bench_stopkey.py --mode med       # 32 kB, a longer window to press in
    python3 tools/bench_stopkey.py --timer 8        # no finger: fire a firmware event instead,
                                                   # which is the control case that already passes
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def q(d, expr):
    return (d.q('print(tostring(%s))' % expr) or '').strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', default='sml', choices=('sml', 'med'),
                    help="sml = 8 kB (~20 s), med = 32 kB (~80 s and more room to press)")
    ap.add_argument('--timer', type=float, default=None,
                    help='seconds; deliver the cancel from a firmware trigger timer instead of a '
                         'finger. This is the CONTROL case -- it is known to work, and a failure '
                         'here means something has changed in the app rather than in the key')
    ap.add_argument('--wait', type=float, default=6.0,
                    help='seconds to wait before telling you to press, so the press lands mid-run')
    a = ap.parse_args()

    from dmmrun import DMM, release_single_instance
    d = DMM(timeout=400)
    try:
        d.drain()
        if q(d, 'sdec ~= nil and sdec.built') != 'true':
            print('REFUSING: no app on the panel. Load it with tools/run_app.py first.')
            return 2
        if q(d, 'sdec.cancel_ok') != 'true':
            print('REFUSING: sdec.cancel_ok is false -- the blender latch was never armed, so this '
                  'would measure the absence of wiring rather than the key.')
            return 2
        baud = q(d, 'sdec.force_baud')
        if baud in ('nil', '0', ''):
            print('REFUSING: no locked baud rate. Streaming modes need one; lock it in Options.')
            return 2
        print('app built, cancel_ok true, locked at %s baud, mode -> %s' % (baud, a.mode))

        # A LATCHED PRESS FROM BEFORE WOULD FAKE A PASS, so the latch is emptied first and the
        # emptiness is CHECKED rather than assumed.
        d.exec('sdec.cancel_clear()', timeout=20)
        if q(d, 'sdec.cancel_pressed()') != 'false':
            print('REFUSING: the latch still reports a press after cancel_clear() -- it would be '
                  'read as this run\'s cancel.')
            return 2

        d.exec("sdec.capmode = '%s' "
               'sdec.ck_cancel, sdec.ck_endwhy, sdec.fc_end = nil, nil, nil' % a.mode, timeout=20)

        if a.timer is not None:
            print('CONTROL CASE: a firmware trigger timer will fire %.1f s in, no finger needed.'
                  % a.timer)
            d.exec('trigger.timer[1].reset() '
                   'trigger.timer[1].delay = %g '
                   'trigger.timer[1].count = 1 '
                   'trigger.timer[1].start.generate = trigger.OFF '
                   'trigger.timer[1].start.seconds = 0 '
                   'trigger.timer[1].start.fractionalseconds = 0 '
                   'trigger.blender[sdec.cancel_blender].stimulus[2] = trigger.EVENT_TIMER1 '
                   'trigger.timer[1].clear() '
                   'trigger.timer[1].enable = trigger.ON' % a.timer, timeout=30)
        else:
            print('')
            print('  ============================================================')
            print('  PRESS THE FRONT-PANEL TRIGGER KEY ONCE, about %.0f s from now.' % a.wait)
            print('  Anywhere in the middle of the run will do.')
            print('  ============================================================')
            print('')

        t0 = time.time()
        # THE RUN IS STARTED FROM THE HOST, which is the entire variable under test: sdec.capture()
        # called over the socket rather than from a button's event string.
        d.exec('sdec.capture()', timeout=380)
        el = time.time() - t0

        cancel = q(d, 'sdec.ck_cancel')
        endwhy = q(d, 'sdec.ck_endwhy')
        stopped = q(d, 'sdec.ck_tot ~= nil and sdec.ck_tot.stopped')
        nbytes = q(d, 'sdec.ck_nbytes')
        latch = q(d, 'sdec.cancel_pressed()')
        print('run returned after %.1f s' % el)
        for k, v in (('ck_cancel', cancel), ('ck_endwhy', endwhy), ('tot.stopped', stopped),
                     ('bytes', nbytes), ('latch holds a press NOW', latch)):
            print('  %-24s %s' % (k, v))

        # THE VERDICT IS SPELLED OUT, because "ck_cancel = nil" invites the reader to supply the
        # wrong reason for it. Three outcomes, and the latch is what separates the last two.
        print('')
        if cancel == 'true':
            print('  CANCELLED. The cancel reached a host-initiated run.')
            if a.timer is None:
                print('  => The KEY works when the run did NOT start from a button handler. The')
                print('     blocker is the display-handler execution context, and the design rule')
                print('     is: do not do long work inside a button handler.')
            else:
                print('  => Control case only. It says the app-side plumbing still works; it says')
                print('     NOTHING about the key.')
        elif a.timer is not None:
            print('  CONTROL CASE FAILED -- the app-side cancel path is broken, which is a')
            print('  regression in the app rather than anything about the key. Fix that first;')
            print('  every key measurement is meaningless until it passes.')
        elif latch == 'true':
            print('  NOT CANCELLED, BUT THE PRESS IS IN THE LATCH. It arrived after the last poll --')
            print('  most likely pressed too late. Re-run and press earlier before concluding')
            print('  anything; this outcome measures your timing, not the instrument.')
        else:
            print('  NOT CANCELLED AND THE LATCH IS EMPTY. The press generated no blender event even')
            print('  though the run was host-initiated -- so the display handler is NOT the')
            print('  distinguishing factor, and what suppresses the key is the recording state')
            print('  itself. Next place to look: the trigger model, which stream_arm() initiates and')
            print('  stream_settle() aborts, and what that leaves the TRIGGER key bound to.')
            print('  (If you did not actually press, this says nothing -- press and re-run.)')
        return 0
    finally:
        # RESTORE, ALWAYS. A timer stimulus left wired makes the NEXT run cancel itself, and the app
        # would be reported as spontaneously stopping.
        try:
            if a.timer is not None:
                d.exec('trigger.timer[1].enable = trigger.OFF '
                       'trigger.blender[sdec.cancel_blender].stimulus[2] = trigger.EVENT_NONE '
                       'trigger.timer[1].reset()', timeout=30)
            d.exec("sdec.capmode = 'frame' sdec.cancel_clear() "
                   'sdec.strm_stopped_by_press = nil', timeout=30)
            print('\nrestored: frame mode, latch clear, no timer stimulus')
        except Exception as e:
            print('\nRESTORE FAILED (%s) -- power cycle before trusting the next measurement' % e)
        d.close()
        release_single_instance()


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""WHAT STATE DOES A MODEL REPORT WHILE IT WAITS, and does the canned template differ from a
hand-built program?

WHAT PROMPTED IT. An armed 8 kB recording ends as 'quiet' with nothing recorded, and the poll loop
decides "the trigger has fired" from `trigger.model.state() ~= trigger.STATE_WAITING`. A probe that
drove `stream_arm()` directly and then watched from the host read **STATE_RUNNING at 97 readings and
STATE_ABORTED half a second later**, never WAITING -- and if a waiting LoopUntilEvent reports RUNNING
rather than WAITING, that test is wrong for every armed recording.

TWO CONFOUNDS THAT PROBE HAD, BOTH REMOVED HERE.

  THE APP'S PANEL TICK. A resident app aborts trigger models it does not believe in, and the tick is
  dispatched between socket reads -- so a model armed from the host and then watched from the host is
  watched across dozens of opportunities for the app to tidy it away. sdec.ui_tick_off() first.

  THE APP ITSELF. This drives trigger.model directly rather than through sdec, so nothing the app
  does to its own state can explain the answer.

THE COMPARATOR IS ARMED WHERE THE LINE CANNOT REACH -- 8 V on a 0-3.3 V line -- so the wait is
guaranteed unsatisfied for the whole watch. That is the state under test: waiting, not fired.

FOUR PROGRAMS, because the question is which shape reports what:

  1  LoopUntilEvent, position 5     the canned template an armed recording loads
  2  LoopUntilEvent, position 0     the same without a pre-trigger reserve
  3  hand-built INFINITE/WAIT/COUNT the four-block shape, section 7 of docs/TRIGGER.md
  4  hand-built WAIT/COUNT          the two-block reduction, which is known never to fire

    python3 tools/probe_waitstate.py          # the app may be loaded; its tick is suspended
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
from siglent import SDG

WATCH_S = 4.0
STEP_S = 0.5
FS = 100000
NSMP = 20000
LEVEL = 8.0            # outside a 0-3.3 V line's range, so the wait cannot be satisfied


def tq(d, tag, expr, timeout=40):
    s = str(d.q('print("%s|" .. tostring((function() local ok, r = pcall(function() return %s end) '
                'if not ok then return "RAISED:" .. tostring(r) end return r end)()))' % (tag, expr),
                timeout=timeout) or '')
    k = '%s|' % tag
    if k not in s:
        raise RuntimeError('DESYNC asking %s: got %r' % (tag, s))
    return s.split(k, 1)[1].strip()


def watch(d, name):
    print('  %7s  %9s  %-26s %s' % ('t', 'PB.n', 'state', 'events'))
    t0 = time.time()
    seen = []
    while time.time() - t0 < WATCH_S:
        el = time.time() - t0
        n = tq(d, 'W1', 'PB.n')
        st = tq(d, 'W2', '(function() local a = trigger.model.state() return a end)()')
        ev = tq(d, 'W3', 'eventlog.getcount(eventlog.SEV_ALL)')
        print('  %7.2f  %9s  %-26s %s' % (el, n, st, ev))
        seen.append(st)
        time.sleep(STEP_S)
    return seen


def drain(d, label):
    ev = tq(d, 'D1', 'eventlog.getcount(eventlog.SEV_ALL)')
    try:
        k = int(float(ev))
    except (TypeError, ValueError):
        k = 0
    if k > 0:
        print('  %s: %s event(s) pending' % (label, k))
        for _ in range(min(k, 8)):
            print('    %s' % tq(d, 'D2',
                  '(function() local c, m = eventlog.next(eventlog.SEV_ALL) '
                  'return tostring(c) .. ", " .. tostring(m) end)()'))


def main():
    g = SDG()
    print('SDG : %s' % g.idn())
    g.output(False, ch=1)          # a quiet line: the comparator must not fire for other reasons

    d = DMM()
    print('DMM : %s fw %s' % (tq(d, 'M', 'localnode.model'), tq(d, 'V', 'localnode.version')))
    loaded = tq(d, 'L', 'tostring(sdec ~= nil and sdec.built == true)')
    print('app : built=%s' % loaded)
    d.exec('localnode.showevents = 0')
    # THE TICK GOES OFF FIRST, and it is the whole reason the earlier probe read ABORTED: with the app
    # resident, its tick runs between socket reads and tidies away a model it did not start.
    if loaded == 'true':
        d.exec('pcall(sdec.ui_tick_off)')
        print('      panel tick suspended')
    print('    trigger.STATE_WAITING = %s   STATE_RUNNING = %s   STATE_IDLE = %s' %
          (tq(d, 'C1', 'tostring(trigger.STATE_WAITING)'),
           tq(d, 'C2', 'tostring(trigger.STATE_RUNNING)'),
           tq(d, 'C3', 'tostring(trigger.STATE_IDLE)')))

    d.exec('pcall(trigger.model.abort)')
    d.exec('pcall(trigger.model.load, "Empty")')
    d.exec('if PB ~= nil then pcall(function() PB.delete() end) PB = nil end')
    d.exec('PB = buffer.make(%d)' % (NSMP + 1100))
    d.exec('pcall(function() PB.fillmode = 1 end)')
    d.exec('dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE')
    d.exec('dmm.digitize.range = 10')
    d.exec('dmm.digitize.samplerate = %d' % FS)
    d.exec('dmm.digitize.analogtrigger.mode = dmm.MODE_EDGE')
    d.exec('dmm.digitize.analogtrigger.edge.level = %f' % LEVEL)
    d.exec('dmm.digitize.analogtrigger.edge.slope = dmm.SLOPE_RISING')
    d.exec('eventlog.clear()')

    try:
        # ---- CASE 0: NOBODY TOUCHES IT. One chunk arms the model, sleeps inside the instrument, and
        # reports -- so no socket command arrives between initiate() and the answer.
        #
        # THIS IS THE CONTROL FOR THE WHOLE PROBE. A model that survives here and dies when watched
        # from the host says the WATCHING is what kills it, which is a fact about this instrument
        # worth more than anything else in this file: the frame path's armed capture blocks inside a
        # single Lua call for its whole wait and works, while an armed RECORDING arms and returns, so
        # only the recording is exposed to whatever arrives next.
        print()
        print('=== case 0: initiate, delay 4 s INSIDE the instrument, then report ===')
        d.exec('pcall(trigger.model.abort)')
        d.exec('pcall(function() PB.clear() end)')
        d.exec('pcall(function() PB.fillmode = 1 end)')
        d.exec('dmm.digitize.count = %d' % NSMP)
        d.exec('eventlog.clear()')
        one = ('pcall(trigger.model.load, "LoopUntilEvent", trigger.EVENT_ANALOGTRIGGER, 5, '
               'trigger.CLEAR_ENTER, 0, PB) '
               'pcall(trigger.model.initiate) '
               'local s0 = trigger.model.state() local n0 = PB.n '
               'delay(4) '
               'local s1 = trigger.model.state() local n1 = PB.n '
               'print(string.format("CASE0|%s|%s|%s|%s|%s", tostring(s0), tostring(n0), '
               'tostring(s1), tostring(n1), tostring(eventlog.getcount(eventlog.SEV_ALL))))')
        r = str(d.q(one, timeout=30) or '')
        print('  at initiate / after 4 s: %s' % r)
        drain(d, 'case 0')
        d.exec('pcall(trigger.model.abort)')

        for pos in (5, 0):
            print()
            print('=== LoopUntilEvent, position %d ===' % pos)
            d.exec('pcall(trigger.model.abort)')
            d.exec('pcall(function() PB.clear() end)')
            d.exec('pcall(function() PB.fillmode = 1 end)')
            d.exec('dmm.digitize.count = %d' % NSMP)
            d.exec('pcall(trigger.model.load, "LoopUntilEvent", trigger.EVENT_ANALOGTRIGGER, %d, '
                   'trigger.CLEAR_ENTER, 0, PB)' % pos)
            d.exec('pcall(trigger.model.initiate)')
            watch(d, 'LoopUntilEvent %d' % pos)
            drain(d, 'LoopUntilEvent %d' % pos)
            print('  blocks: %s' % tq(d, 'B1',
                  '(function() local s = trigger.model.getblocklist() '
                  'return (string.gsub(s, "\\n", " ;; ")) end)()', timeout=60)[:300])
            d.exec('pcall(trigger.model.abort)')

        for nblk in (3, 2):
            print()
            print('=== hand-built, %d blocks ===' % nblk)
            d.exec('pcall(trigger.model.abort)')
            d.exec('pcall(trigger.model.load, "Empty")')
            d.exec('pcall(function() PB.clear() end)')
            d.exec('pcall(function() PB.fillmode = 1 end)')
            b = 1
            if nblk == 3:
                # ONE exec PER setblock: a one-line probe past about 1024 bytes dies with -363, which
                # reads as a hung instrument rather than as a refused line.
                d.exec('pcall(function() trigger.model.setblock(1, '
                       'trigger.BLOCK_MEASURE_DIGITIZE, PB, trigger.COUNT_INFINITE) end)')
                b = 2
            d.exec('pcall(function() trigger.model.setblock(%d, trigger.BLOCK_WAIT, '
                   'trigger.EVENT_ANALOGTRIGGER, trigger.CLEAR_ENTER) end)' % b)
            d.exec('pcall(function() trigger.model.setblock(%d, trigger.BLOCK_MEASURE_DIGITIZE, '
                   'PB, %d) end)' % (b + 1, NSMP))
            d.exec('pcall(trigger.model.initiate)')
            watch(d, 'hand-built %d' % nblk)
            drain(d, 'hand-built %d' % nblk)
            print('  blocks: %s' % tq(d, 'B2',
                  '(function() local s = trigger.model.getblocklist() '
                  'return (string.gsub(s, "\\n", " ;; ")) end)()', timeout=60)[:300])
            d.exec('pcall(trigger.model.abort)')
    finally:
        print()
        print('=== restore ===')
        d.exec('pcall(trigger.model.abort)')
        d.exec('pcall(trigger.model.load, "Empty")')
        d.exec('dmm.digitize.analogtrigger.mode = dmm.MODE_OFF')
        d.exec('if PB ~= nil then pcall(function() PB.delete() end) PB = nil end')
        d.exec('dmm.digitize.count = 1')
        if loaded == 'true':
            d.exec('pcall(sdec.ui_tick_on)')
            print('  panel tick resumed')
        drain(d, 'restore')
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        print('  model=%s' % tq(d, 'Z1', 'trigger.model.state()'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Is reading an options field before writing it faster than just writing it?

NO DIFFERENCE. Both arms cost the same, so the change this was written to judge
was reverted as buying nothing -- not as being slower.

    arm                        no change    one field changed
    write unconditionally       0.860 ms         0.942 ms
    read first, write on diff   0.827 ms         0.868 ms

n=12 and n=6 per arm, six alternating laps, one session. The 4 % edge to
read-first is inside the session drift and is not a reason to prefer it.

AND THE REASON THE FIRST RUN OF THIS SAID OTHERWISE, which is the lesson worth
keeping: an earlier design reported read-first at 2.345 ms against 0.896 ms,
apparently damning. Those means were carried entirely by two single calls of
19.003 and 32.796 ms in LAP 0 of the read-first arm -- the first two
options_seed() calls of that session, cold. The steady-state values in that same
run were 0.81-0.87 read-first against 0.82-1.05 unconditional, i.e. identical.
Whichever arm is measured first absorbs the session's warm-up and loses.
So: alternate the arms, discard nothing, and look at the SPREAD, not the mean.

What the change was defended by was an ISOLATED microbenchmark of
display.setvalue at 1.100-2.512 ms, and that premise is what is actually false:
options_seed() does SEVEN of them for 0.86 ms, i.e. 0.12 ms each. An unchanged
setvalue is already cheap in this firmware. See tools/probe_panellag.py
finding 5 -- a single-shot display timing on this instrument charges the
previous operation's drain to whoever asks next.

HOW IT MEASURES. One cold sdec.options_seed() per data point, both arms
alternating in ONE session: the per-call cost of a display write drifts over a
session (setvalue measured 1.100, 1.541 then 2.512 ms in three successive rounds
of probe_panellag), so two numbers taken minutes apart say nothing.

The arm is selected by wrapping display.setvalue GLOBALLY rather than by editing
a copy of options_seed into the probe: that way it tests the real shipped
function, and it cannot rot as that function changes. display.setvalue is
restored unconditionally before this exits -- a patched one left behind would
poison every tool that ran next.

Assumes the app is ALREADY LOADED -- it does not reload, because a reload on this
instrument has been costing 301 s to a stranded interface. CHECK WHAT IS LOADED:
a load_script that loses its opening line leaves the PREVIOUS app in place and
says almost nothing, so a probe can silently measure a tree that is not the one
on disk.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402

# Stashed once and only once, or a second run wraps the wrapper.
STASH = ('if _psv_real == nil then _psv_real = display.setvalue end '
         'display.setvalue = _psv_real')
# The read-first arm: exactly the change that was tried in options_seed.
WRAP = ('display.setvalue = function(h, v) '
        'local cur = nil '
        'pcall(function() cur = display.getvalue(h) end) '
        'if cur ~= v then return _psv_real(h, v) end end')
RESTORE = 'if _psv_real ~= nil then display.setvalue = _psv_real end'


def one_seed(d, changed):
    """One cold options_seed(), in ms. `changed` forces exactly one field stale."""
    pre = ''
    if changed:
        # Parity alternates between Even and auto, so one field differs and six do not.
        pre = ('if sdec.force_par == nil then sdec.force_par = sdec.PAR_EVEN '
               'else sdec.force_par = nil end ')
    src = ("sdec.strm_stopped_by_press = nil " + pre +
           "timer.cleartime() local _r = sdec.options_seed() "
           "print(string.format('%.3f', timer.gettime() * 1000))")
    r = d.q(src, timeout=60)
    try:
        return float(r)
    except (TypeError, ValueError):
        return None


def main():
    d = DMM()
    try:
        alive = d.q('print(tostring(sdec ~= nil), tostring(sdec.optscr ~= nil))')
        print('app loaded (sdec / optscr):', alive)
        if alive is None or 'true\ttrue' not in str(alive):
            raise SystemExit('REFUSING: load the app first (tools/run_app.py)')
        d.exec(STASH)
        d.exec('display.changescreen(sdec.optscr)')

        rows = []
        for lap in range(6):
            for tag, arm in (('readfirst', WRAP), ('uncond', RESTORE)):
                d.exec(arm)
                # NOTHING CHANGED: the common case -- re-opening the form, or
                # Cancel re-seeding it. read-first writes 0 fields, uncond 7.
                same = one_seed(d, False)
                same2 = one_seed(d, False)
                # ONE FIELD CHANGED: read-first writes 1, uncond still writes 7.
                diff = one_seed(d, True)
                rows.append((lap, tag, same, same2, diff))
                print('  lap %d %-10s  no-change %7s %7s   one-change %7s'
                      % (lap, tag, same, same2, diff))
            time.sleep(0.2)

        print('\n== means, ms ==')
        for tag in ('readfirst', 'uncond'):
            sel = [r for r in rows if r[1] == tag]
            nc = [v for r in sel for v in (r[2], r[3]) if v is not None]
            oc = [r[4] for r in sel if r[4] is not None]
            if nc and oc:
                print('  %-10s no-change %.3f (n=%d)   one-change %.3f (n=%d)'
                      % (tag, sum(nc) / len(nc), len(nc),
                         sum(oc) / len(oc), len(oc)))
    finally:
        # UNCONDITIONAL, and on the way out of a failure too: a wrapped
        # display.setvalue left on the instrument breaks every later tool
        # silently, because it still works -- just differently.
        try:
            d.exec(RESTORE)
            d.exec('sdec.force_par = nil')
            d.exec('sdec.options_seed()')
            d.exec('display.changescreen(sdec.ui_scr)')
            d.exec('sdec.strm_stopped_by_press = nil')
            print('\n  setvalue restored; events:',
                  d.q('print(tostring(eventlog.getcount()))'))
        finally:
            d.close()


if __name__ == '__main__':
    main()

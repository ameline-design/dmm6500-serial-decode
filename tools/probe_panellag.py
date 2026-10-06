#!/usr/bin/env python3
"""What the app costs the front panel, and what it does not.

Written to answer one operator report -- "the settings in the option screen
seem slow to respond, sometimes" -- and kept because three of its five
measurements REFUTE a plausible cause, which is the expensive kind of thing to
have to re-derive.

WHAT IT ESTABLISHED on firmware 1.7.17a.

READ THIS FIRST ABOUT THE FIGURES IN 1-5: they were collected in a run whose
load silently failed, so they describe the app from the run BEFORE it, not the
tree on disk (that is finding 6, which is how it was caught). The conclusions
survive, and here is why each one does: the key tick exists in both trees; the
display-call and buffer timings are firmware, not app; options_apply's capture
and ulog.line's flush are untouched by what differed. Re-measure before quoting
any of them as a figure FOR a particular version.

  1. The 2 Hz USB-key tick does NOT run while another screen is in front. 6
     ticks in 3 s on the main screen, 0 with the Options form up, 0 on
     SCREEN_HOME. So the tick cannot be competing with a field touch.

  2. A large reading buffer does NOT slow the panel. Every display call is
     within noise across no buffer / 2.6 M readings / deleted. The app holds
     sdec.buf from a streaming capture until sdec.stop(), and that is not a
     responsiveness cost.

  3. NO APP CODE RUNS ON A FIELD TOUCH AT ALL. This one is READ, not measured:
     sdec.build_options() in tsp/serial_ui.tsp creates the seven OBJ_EDIT_*
     fields with no display.setevent on any of them, and only the four buttons
     in its `odef` loop get one. So the responsiveness of a setting itself is
     the firmware's and nothing here can change it. (A stage that claimed to
     test this was deleted: it printed whether a display API function existed,
     which is not the same question.)

  4. The one multi-second press on that screen is Apply, because Apply ends in
     a capture by design: 4.0 s with nothing locked against 1.9 s locked. That
     ratio is the reported "sometimes slow, sometimes very responsive".

  5. A single-shot timing of a display call runs 10 to 50 times its
     steady-state figure -- options() 68 ms single-shot against 2.7 ms averaged
     over ten. That pair comes from a separate throwaway probe, not from here:
     the CALLS table below runs options() at n=5 and cannot reproduce it. THE OBSERVATION IS SOLID; the mechanism is not. "A drain being
     charged to whoever asks next" is a guess, and tools/probe_seedv.py found
     the better description without needing it: whichever arm is measured first
     absorbs the session's warm-up. What matters either way is that an isolated
     display microbenchmark on this instrument does NOT predict the cost of the
     same call in context, and the two figures below are the warning:

         display.setvalue, measured alone        1.100 - 2.512 ms
         options_seed(), which does SEVEN            0.84 ms total

     An unchanged setvalue is already cheap in firmware. `options_seed` reading
     each field and writing only on a difference was tried on the strength of
     the isolated figure and REVERTED -- see tools/probe_seedv.py, which pairs
     the two over six alternating laps and finds no difference at all: 0.860 ms
     unconditional against 0.827 ms read-first. There is nothing to win here.

  6. A LOAD THAT FAILS LEAVES THE PREVIOUS APP RUNNING, and says very little.
     One run of this probe reported its load as
     "FAILURE: A command from another interface is running" followed by a
     timeout, then probed sdec/start/built as true true true -- because the
     sdecapp from the run BEFORE it was still there. Every figure it printed was
     of a tree that was not on disk. Check a function you have just added, not
     that `sdec` exists: `print(tostring(sdec.<new thing> ~= nil))`.

WHAT IS LEFT UNFIXED, DELIBERATELY: ulog.line() spends 89 to 97 % of itself in
its per-line file.flush to the key, and that cost is wildly variable -- 4.6 ms
per line on one run and 16.1 ms on the next, against 0.46 ms with autoflush off.
A capture logs tens of lines, so this is 0.12 to 0.47 s per capture. It is NOT
batched, because the gain is under 12 % of a capture the operator already waits
seconds for, and the cost would be losing that capture's trace on a power cut --
which is the one thing the log exists for. ulog.autoflush = false is there for
anyone who measures a case where it matters.

Run from the repo root. Leaves the app loaded with the main screen in front.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402
import run_app as RA            # noqa: E402

CALLS = (
    ('changescreen opt->main', 'display.changescreen(sdec.optscr) '
                               'display.changescreen(sdec.ui_scr)', 10),
    ('setvalue EDIT_OPTION', 'display.setvalue(sdec.opt_par, 1)', 20),
    ('getvalue EDIT_OPTION', 'local _v = display.getvalue(sdec.opt_par)', 20),
    ('settext OBJ_TEXT', 'display.settext(sdec.ui_log_t, "x")', 20),
    ('ui_refresh', 'sdec.ui_refresh()', 5),
    ('options_seed (no change)', 'sdec.options_seed()', 10),
    ('options()', 'sdec.options()', 5),
)


def t_ms(d, stmt, n=1, timeout=180):
    """Wall time of `stmt` on the instrument in ms, averaged over n runs.

    timer.cleartime()/gettime() is the instrument's ONE global timer and the app
    arms its queued-press absorb from it, so this disarms first -- see
    bench_sync.disarm_absorb.
    """
    src = ("sdec.strm_stopped_by_press = nil timer.cleartime() "
           "for _i = 1, %d do %s end "
           "print(string.format('%%.3f', timer.gettime() * 1000 / %d))" % (n, stmt, n))
    r = d.q(src, timeout=timeout)
    try:
        return float(r)
    except (TypeError, ValueError):
        return r


def ticks_over(d, secs, where):
    """Tick handler calls over `secs` of HOST sleep with `where` in front.

    The host sleeps, not the instrument: delay() inside Lua holds the
    interpreter, and a held interpreter DEFERS ticks rather than dropping them,
    so counting across one measures the backlog instead of the rate.
    """
    d.exec('sdec.tickn = 0')
    d.exec("display.setevent(sdec.ui_tick_obj, display.EVENT_PRESS, "
           "'sdec.tickn = (sdec.tickn or 0) + 1')")
    d.exec('display.changescreen(%s)' % where)
    time.sleep(secs)
    n = d.q('print(tostring(sdec.tickn))')
    d.exec('display.changescreen(sdec.ui_scr)')
    d.exec("display.setevent(sdec.ui_tick_obj, display.EVENT_PRESS, 'sdec.ui_tick()')")
    return n


def round_of(d, tag):
    print('\n-- %s --' % tag)
    out = {}
    for lbl, stmt, n in CALLS:
        v = t_ms(d, stmt, n)
        out[lbl] = v
        print('  %-26s %s' % (lbl, ('%8.3f ms' % v) if isinstance(v, float) else v))
    d.exec('display.changescreen(sdec.ui_scr)')
    return out


def main():
    # Set before the socket is touched: the finally reads it, and a NameError there would mask
    # whatever actually went wrong.
    snap = None
    d = DMM()
    try:
        # ABORT is for the OTHER thing that gives the same message: a tool killed
        # mid-press, where something really is hung. It does NOT clear the refusal
        # this probe cares about -- see dmmrun.load_script, where the remedy is to
        # send the panel HOME, because nothing is hung and there is nothing to abort.
        # Sent anyway, cheaply, in case a previous run was killed.
        d.send('ABORT')
        time.sleep(0.5)
        print(d.q('print(localnode.model, localnode.version)'))
        RA.load_app(d)
        d.exec('sdec.start()')

        # 1. 6 / 0 / 0 -- a timer runs only while its own screen is active.
        print('\n== 1. does the key tick run with another screen in front ==')
        print('  main screen,    3 s:', ticks_over(d, 3.0, 'sdec.ui_scr'))
        print('  OPTIONS screen, 3 s:', ticks_over(d, 3.0, 'sdec.optscr'))
        print('  SCREEN_HOME,    3 s:', ticks_over(d, 3.0, 'display.SCREEN_HOME'))

        a = round_of(d, '3. per-call cost, no streaming buffer')

        # 2. The buffer A/B/C. 2.6 M readings is a 32 kB capture at 8 sa/bit.
        big = 2600000
        print('\n  allocating %d readings through the app\'s own path...' % big)
        print('  made:', d.q('print(tostring(pcall(function() '
                             'sdec.acq_make_buffer(%d) end)), '
                             'tostring(sdec.buf ~= nil))' % big))
        b = round_of(d, '4. the same calls with a 2.6 M reading buffer')
        # Deleted BEFORE dropped: sdec.buf = nil strands it in firmware until a
        # power cycle.
        print('\n  del:', d.q('print(tostring(pcall(function() '
                              'buffer.delete(sdec.buf) end)))'))
        d.exec('sdec.buf = nil')
        c = round_of(d, '5. and with it deleted again')

        print('\n== the comparison that refuted the buffer ==')
        print('  %-26s %10s %10s %10s' % ('call', 'none', 'big', 'deleted'))
        for lbl, _s, _n in CALLS:
            def f(v):
                return ('%8.3f' % v) if isinstance(v, float) else str(v)[:10]
            print('  %-26s %10s %10s %10s' % (lbl, f(a[lbl]), f(b[lbl]), f(c[lbl])))

        # 4. Apply, which ends in a capture by design.
        #
        # SNAPSHOTTED FIRST. This stage locks the rate and never unlocks it, so without this the
        # probe hands the next tool an app pinned to whatever that capture found -- and forcing
        # autolock back ON regardless would be a second silent change. Same rule as capmode/fc_*.
        print('\n== 6. Apply, unlocked against locked ==')
        snap = d.q('print(string.format("%s|%s|%s|%s|%s",'
                   ' tostring(sdec.force_baud), tostring(sdec.force_nbits),'
                   ' tostring(sdec.force_par), tostring(sdec.force_invert),'
                   ' tostring(sdec.autolock)))')
        print('  saved force_baud|nbits|par|invert|autolock:', snap)
        d.exec('sdec.force_baud = nil sdec.snapped = false sdec.autolock = false')
        d.exec('display.changescreen(sdec.optscr) sdec.options_seed()')
        t0 = time.time()
        d.exec('sdec.options_apply()', timeout=300)
        print('  apply, UNLOCKED  wall: %.2f s' % (time.time() - t0))
        d.exec('sdec.options_lock()')
        d.exec('display.changescreen(sdec.optscr) sdec.options_seed()')
        t0 = time.time()
        d.exec('sdec.options_apply()', timeout=300)
        print('  apply, LOCKED    wall: %.2f s' % (time.time() - t0))

        # The per-line USB flush, which is 89 % of ulog.line.
        print('\n== 7. the debug log, the only I/O on that screen ==')
        print('  line, autoflush on :', t_ms(d, "ulog.line('p')", 20))
        d.exec('ulog.autoflush = false')
        print('  line, autoflush off:', t_ms(d, "ulog.line('p')", 20))
        d.exec('ulog.autoflush = true')

        print('\n  events:', d.q('print(tostring(eventlog.getcount()))'))
    finally:
        # RESTORED WHATEVER HAPPENED, because a probe that dies mid-stage otherwise hands the next
        # tool an app with no key polling, no log flushing, and a lock it did not set. Each is
        # pcall'd on the instrument and guarded here, so a dead socket cannot turn a stage failure
        # into a traceback that hides it.
        #
        # THE FORCED RATE GOES BACK FROM THE SNAPSHOT, not from an assumption about the app's
        # defaults -- and from HERE rather than from the end of the happy path, because stage 6's
        # two options_apply() calls are the likeliest thing in this probe to time out, and the
        # state it would leave behind is a locked rate the next tool did not set.
        try:
            if snap is not None and '|' in str(snap):
                fld = str(snap).split('|')
                d.exec('sdec.force_baud, sdec.force_nbits, sdec.force_par, sdec.force_invert = '
                       '%s, %s, %s, %s sdec.autolock = %s'
                       % (fld[0], fld[1], fld[2], fld[3], fld[4]))
                print('  forced settings restored:',
                      d.q('print(string.format("%s|%s|%s|%s|%s",'
                          ' tostring(sdec.force_baud), tostring(sdec.force_nbits),'
                          ' tostring(sdec.force_par), tostring(sdec.force_invert),'
                          ' tostring(sdec.autolock)))'))
        except Exception as e:                                   # noqa: BLE001
            print('  FORCED-SETTING RESTORE FAILED (%s) -- reload the app' % e)
        try:
            d.exec("if sdec ~= nil and sdec.ui_tick_on ~= nil then "
                   "  pcall(function() sdec.ui_tick_on() end) end "
                   "if ulog ~= nil then ulog.autoflush = true end "
                   "if sdec ~= nil then sdec.strm_stopped_by_press = nil end")
            d.exec('if sdec ~= nil and sdec.ui_scr ~= nil then '
                   'display.changescreen(sdec.ui_scr) end')
            print('  tick, autoflush and screen restored')
        except Exception as e:                                   # noqa: BLE001
            print('  RESTORE FAILED (%s) -- reload the app before the next tool' % e)
        d.close()


if __name__ == '__main__':
    main()

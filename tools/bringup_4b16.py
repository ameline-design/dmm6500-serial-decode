#!/usr/bin/env python3
"""BRINGUP 4b.16 -- CAN A RUNNING LUA SCRIPT SEE A FRONT-PANEL PRESS?

This is the question the whole long-capture architecture rests on, and it has been answered
only from the documentation so far -- which said no, twice, for two different primitives:

  * display.setevent() presses are dispatched by the FIRMWARE calling an event string, and the
    firmware cannot do that while the interpreter is inside a Lua chunk. Measured (4b.7):
    presses do not arrive during a script, and they QUEUE.
  * display.waitevent() was read as "waits for a response to display.prompt() and returns
    BUTTON_YES/NO/OK/CANCEL", i.e. a dialog primitive, not a poll of a custom screen.

The consequence, if both hold, is that a 20 s stream cannot be stopped and a press cannot be
answered inside 1 s -- because there is no moment in the run at which Lua can ASK whether a
button was touched. Every fix for that is architectural, so it is worth 5 minutes to check the
second bullet on the instrument rather than believing a manual that is older than the firmware
and known to contain errors.

FOUR PROBES, cheapest first:

  A  display.waitevent(0) with a custom screen up and a button on it. Does it return the
     button's event string / id when the button is touched? Does it return promptly with
     nothing when it is not? A non-blocking poll is all the stream loop needs.
  B  the same with a short timeout (0.2 s), which is what the loop would actually call.
  C  trigger.wait(trigger.EVENT_DISPLAY, 0) -- the hardware TRIGGER key as a POLLABLE event.
     The key cannot be a display event, but it IS a trigger-model event source, and
     trigger.wait() with a zero timeout is a non-blocking test of whether it has fired. If
     this works the TRIGGER key becomes a Stop that works mid-run, which is the user's
     "make TRIGGER do what Capture does" in the only form the firmware can support.
  D  how long one Lua-side pass over 20 000 samples actually takes, since the window size is
     what press latency is quantised to once a poll exists.

It builds its OWN minimal screen, not the app, and tears it down at the end -- so it costs a
UI build but leaves the budget for the app intact if the teardown verifies (see HANDOFF:
repeat builds are safe when teardown is clean).

    python3 tools/bringup_4b16.py            # A, B, D -- no human needed
    python3 tools/bringup_4b16.py --keys     # adds C, and prompts you to press TRIGGER
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM

# One screen, one button, and a global the button's event handler sets. If the handler ever
# runs we know the press was dispatched the ORDINARY way, which is the control for probe A:
# a press that sets the global but is never returned by waitevent tells us waitevent is not a
# poll, rather than that the press never happened.
BUILD = r'''
function p16_build()
p16 = {}
p16.hits = 0
function p16_press() p16.hits = p16.hits + 1 end
p16.scr = display.create(display.ROOT, display.OBJ_SCREEN, 'BRINGUP 4b.16')
p16.btn = display.create(p16.scr, display.OBJ_BUTTON, 20, 60, 'PRESS ME', 200)
display.setevent(p16.btn, display.EVENT_PRESS, 'p16_press()')
p16.txt = display.create(p16.scr, display.OBJ_TEXT, 20, 160,
                         'waiting', display.FONT_MEDIUM, display.JUST_LEFT)
display.changescreen(p16.scr)
print(string.format('BUILD scr=%s btn=%s txt=%s',
                    tostring(p16.scr), tostring(p16.btn), tostring(p16.txt)))
end
'''

# Probe E, the user's suggestion: does delay() give the firmware a chance to dispatch a queued
# press? A press handler that runs DURING this loop would increment p16.hits before the loop
# reports it -- which is the whole difference between "delay yields" and "delay busy-waits".
DELAYPROBE = r'''
function p16_delayprobe(n, dt)
  local i
  local h0 = p16.hits
  for i = 1, n do
    delay(dt)
    if p16.hits ~= h0 then
      print(string.format('DELAY dispatched DURING the script at iteration %d (hits %d -> %d)',
                          i, h0, p16.hits))
      return
    end
  end
  print(string.format('DELAY %d x %g s = %g s elapsed, hits still %d -- no dispatch',
                      n, dt, n * dt, p16.hits))
end
'''

# Probe A/B. Deliberately reports the TYPE of every return value: waitevent's contract is
# unknown here, so "it returned something" is not the finding -- what it returned is.
POLL = r'''
function p16_poll(timeout, n)
  local i
  for i = 1, n do
    local a, b, c = nil, nil, nil
    local ok, err = pcall(function() a, b, c = display.waitevent(timeout) end)
    if not ok then
      print(string.format('POLL %d RAISED %s', i, tostring(err)))
      return
    end
    print(string.format('POLL %d a=%s(%s) b=%s(%s) c=%s(%s) hits=%d',
                        i, tostring(a), type(a), tostring(b), type(b),
                        tostring(c), type(c), p16.hits))
  end
end
'''

# Probe C. trigger.wait() on the TRIGGER key. Cleared first, or a press from before the probe
# started would come back and read as a success that proves nothing.
TRIGWAIT = r'''
function p16_trigpoll(timeout, n)
  local ok, err = pcall(function() trigger.clear() end)
  print('trigger.clear ok=' .. tostring(ok) .. ' ' .. tostring(err))
  local i
  for i = 1, n do
    local got = nil
    local pok, perr = pcall(function()
      got = trigger.wait(trigger.EVENT_DISPLAY, timeout)
    end)
    if not pok then
      print(string.format('TRIGPOLL %d RAISED %s', i, tostring(perr)))
      return
    end
    print(string.format('TRIGPOLL %d got=%s(%s)', i, tostring(got), type(got)))
    if got == true then return end
    delay(0.4)
  end
end
'''

# Probe D. What a window of Lua-side work costs, which is the quantum press latency comes in.
# sig_edges is the per-sample pass the chunked decoder runs once per window, so timing it on a
# synthetic 20 000-sample table is the honest measure -- no acquisition, no I/O.
WINDOW = r'''
function p16_windowcost(n)
  local t = {}
  local i
  for i = 1, n do
    if math.mod(math.floor(i / 8), 2) == 0 then t[i] = 0.2 else t[i] = 3.0 end
  end
  sdec.thr, sdec.hyst = 1.6, 0.3
  timer.cleartime()
  sdec.sig_edges(t, n)
  local te = timer.gettime()
  timer.cleartime()
  local r = sdec.ua_run(t, n, 8.0, 8, 'none', 1, false, nil)
  local td = timer.gettime()
  print(string.format('WINDOW n=%d edges=%.3f s decode=%.3f s nf=%s total=%.3f s',
                      n, te, td, tostring(r and r.nf), te + td))
end
'''

TEARDOWN = r'''
function p16_teardown()
  local ok1 = pcall(function() display.changescreen(display.SCREEN_HOME) end)
  local ok2 = pcall(function() display.delete(p16.scr) end)
  p16.btn, p16.txt, p16.scr = nil, nil, nil
  p16 = nil
  collectgarbage()
  print(string.format('TEARDOWN home=%s delete=%s', tostring(ok1), tostring(ok2)))
end
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--keys', action='store_true',
                    help='include probe C, which needs a human to press TRIGGER')
    ap.add_argument('--window', type=int, default=20000)
    a = ap.parse_args()

    d = DMM()
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        # Clear whatever a previous run left on screen. A stale modal swallows presses, which
        # would make every probe here read as "no press ever arrived".
        d.exec('eventlog.clear()')

        # EVERY DEFINITION GOES THROUGH loadscript. send() writes ONE line to the socket, so a
        # multi-line function body arrives as a single line and the parser sees `function f()
        # local i ... end` collapsed -- which is how the first run of this script produced eight
        # different syntax errors from correct Lua. Definitions are loaded; only single-line
        # CALLS are sent.
        body = ('sdec = sdec or {}\n'
                + open('tsp/serial_core.tsp').read()
                + open('tsp/uart_decode.tsp').read()
                + BUILD + POLL + TRIGWAIT + WINDOW + DELAYPROBE + TEARDOWN
                # load_script() reads until this exact line. A body that does not print it
                # blocks for the whole timeout and looks like a hung instrument -- which is
                # what the second failed run of this script actually was.
                + "\nprint('===DONE===')\n")
        out = d.load_script('p16', body, timeout=180)
        for ln in out:
            if ln and ln != '===DONE===':
                print('  load: ' + ln)

        print('--- probe D: what one window of Lua work costs ---')
        d.drain()
        d.send('p16_windowcost(%d)' % a.window)
        print('   ' + str(d.line(300)))

        print('\n--- build a minimal custom screen ---')
        d.drain()
        d.send('p16_build()')
        print('   ' + str(d.line(60)))

        print('\n--- probe A: display.waitevent(0), nothing pressed ---')
        d.drain()
        d.send('p16_poll(0, 3)')
        for _ in range(3):
            print('   ' + str(d.line(30)))

        print('\n--- probe B: display.waitevent(0.2) x5. PRESS THE ON-SCREEN BUTTON NOW ---')
        d.drain()
        d.send('p16_poll(0.2, 5)')
        for _ in range(5):
            print('   ' + str(d.line(30)))
        print('   hits (ordinary dispatch, counted AFTER the loop returned): %s'
              % d.q('print(p16.hits)'))

        print('\n--- probe E: delay() x20 of 0.1 s = 2 s. PRESS THE ON-SCREEN BUTTON NOW ---')
        d.drain()
        d.send('p16_delayprobe(20, 0.1)')
        print('   ' + str(d.line(30)))
        print('   hits after the loop returned: %s' % d.q('print(p16.hits)'))

        if a.keys:
            print('\n--- probe C: trigger.wait(EVENT_DISPLAY, 0.5) x8. '
                  'PRESS THE HARDWARE TRIGGER KEY NOW ---')
            d.drain()
            d.send('p16_trigpoll(0.5, 8)')
            for _ in range(10):
                ln = d.line(20)
                if ln is None:
                    break
                print('   ' + str(ln))

        print('\n--- teardown ---')
        d.drain()
        d.send('p16_teardown()')
        print('   ' + str(d.line(60)))
        print('   p16 now: %s' % d.q('print(tostring(p16))'))

        print('\n--- event log ---')
        for m in d.errors():
            print('   ' + str(m))
    finally:
        d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

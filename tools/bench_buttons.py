#!/usr/bin/env python3
"""Press every button in the app, on the instrument, and check three things per press.

  1. IT DOES NOT RAISE.       A touch handler that throws leaves a dead button and no
     explanation. Every handler here is called through pcall on the instrument so a raise is
     reported rather than silently killing the panel.
  2. IT LOGS NOTHING.         Any new event-log entry at severity ERROR raises a MODAL dialog over
     the app -- localnode.showevents = SEV_ERROR suppresses warnings and info, so ERROR is exactly
     the severity that still interrupts the operator. A press that logs an error is a defect even
     if it otherwise works. The event-log count is read before and after each press.
  3. IT RETURNS FAST ENOUGH.  A press is not dispatched while Lua runs and presses QUEUE
     (BRINGUP 4b.16), so the handler's own duration IS the press latency -- there is nothing to
     poll and nothing to interrupt. sdec.ui_latency_s (0.5 s) is the budget; anything over it is
     reported as OVER.

WHY OVER THE SOCKET AND NOT BY HAND. The handlers are exactly what display.setevent invokes -- the
strings in serial_ui.tsp are 'sdec.capture()' and so on -- so calling them by name exercises the
shipped code path. What it does NOT test is the firmware's dispatch of a physical touch, which is
why the panel still wants a human pass; this covers the fourteen handlers and their timing.

Buttons are pressed in a deliberate ORDER, twice over. Many handlers are only interesting once
state exists -- Save with nothing captured must refuse politely, Save after a capture must write a
file, page buttons only mean something with more than one page -- so the sequence runs the
empty-state pass first and the populated pass second, and both are reported.

    python3 tools/bench_buttons.py                 # needs the SDG playing; --no-sdg to skip
    python3 tools/bench_buttons.py --no-start      # load only, do not spend the UI build
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
import bench_uart as BU

MODULES = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
           'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp']

PRELUDE = '''
if sdec ~= nil then
  pcall(function() if sdec.buf ~= nil then buffer.delete(sdec.buf) end end)
  pcall(function() trigger.model.abort() end)
end
sdec = nil
ulog = nil
collectgarbage()
eventlog.clear()
'''

# One press. Everything the check needs comes back on one line so the parser cannot desync.
PRESS = r'''
function press(name, fn)
  eventlog.clear()
  local t0, t1 = 0, 0
  timer.cleartime()
  local ok, err = pcall(fn)
  t1 = timer.gettime()
  local ec = eventlog.getcount()
  local emsg = ''
  if ec > 0 then
    -- Read them out, which also CLEARS them -- an accumulating log is what raises the modal
    -- "Multiple errors have occurred" box, so leaving them would poison later presses.
    local i
    for i = 1, ec do
      local n, m = eventlog.next()
      if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
    end
  end
  print(string.format('PRESS %s|%s|%.4f|%d|%s|%s', name, tostring(ok), t1, ec, emsg,
                      tostring(sdec.ui_status)))
end
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--no-start', action='store_true')
    ap.add_argument('--no-sdg', action='store_true')
    ap.add_argument('--baud', type=int, default=9600)
    a = ap.parse_args()

    if not a.no_sdg:
        from siglent import SDG
        g = SDG()
        print('SDG: ' + g.idn())
        g.select_arb('v80', 10.0, a.baud * 10)
        g.output(True, ch=1)
        print('playing v80 at %d baud (SRATE %d)' % (a.baud, a.baud * 10))
        g.close()
        time.sleep(0.4)

    d = DMM()
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        body = [PRELUDE]
        for m in MODULES:
            body.append('-- ==== %s ====' % m)
            body.append(open(m).read())
        body.append(PRESS)
        body.append("print('===DONE===')")
        src = '\n'.join(body)
        print('loading %d bytes...' % len(src))
        for ln in d.load_script('sdecbtn', src, timeout=300):
            if ln and ln != '===DONE===':
                print('  load: ' + ln)
        d.exec('localnode.showevents = eventlog.SEV_ERROR')

        if a.no_start:
            print('loaded, not started (--no-start)')
            return 0

        print('\n--- sdec.start()  [the one UI build] ---')
        d.drain()
        d.send('local ok, why = sdec.start() '
               'print(string.format("START %s %s", tostring(ok), tostring(why)))')
        print('  ' + str(d.line(120)))

        # Order matters: empty-state pass first, then a capture, then the populated pass.
        SEQ = [
            ('view_toggle/empty', 'sdec.view_toggle'),
            ('page_next/empty', 'sdec.page_next'),
            ('page_prev/empty', 'sdec.page_prev'),
            ('save/empty', 'sdec.save'),
            ('lock_toggle/on', 'sdec.lock_toggle'),
            ('lock_toggle/off', 'sdec.lock_toggle'),
            ('log_new', 'sdec.log_new'),
            ('capture/1', 'sdec.capture'),
            ('capture/2', 'sdec.capture'),
            ('view_toggle/1', 'sdec.view_toggle'),
            ('view_toggle/2', 'sdec.view_toggle'),
            ('page_next/full', 'sdec.page_next'),
            ('page_prev/full', 'sdec.page_prev'),
            ('save/full', 'sdec.save'),
            ('mode_cycle/1', 'sdec.mode_cycle'),
            ('mode_cycle/2', 'sdec.mode_cycle'),
            ('mode_cycle/3', 'sdec.mode_cycle'),
            ('options/open', 'sdec.options'),
            ('options_lock', 'sdec.options_lock'),
            ('options_auto', 'sdec.options_auto'),
            ('options_apply', 'sdec.options_apply'),
            ('options/open2', 'sdec.options'),
            ('options_cancel', 'sdec.options_cancel'),
            ('capture/after-opts', 'sdec.capture'),
        ]

        budget = float(d.q('print(sdec.ui_latency_s)') or 0.5)
        print('\nbudget %.2f s per press\n' % budget)
        print('%-22s %-6s %8s %4s %-9s %s'
              % ('button', 'ok', 'secs', 'log', 'status', 'events / verdict'))
        print('-' * 96)
        rows = []
        for label, fn in SEQ:
            d.drain()
            d.send('press(%r, %s)' % (label, fn))
            ln = d.line(300)
            if ln is None or not ln.startswith('PRESS '):
                print('%-22s TIMEOUT/BAD: %s' % (label, ln))
                rows.append((label, False, 0.0, 0, 'timeout'))
                continue
            f = ln[6:].split('|')
            name, ok, secs, ec, emsg = f[0], f[1] == 'true', float(f[2]), int(f[3]), f[4]
            status = f[5] if len(f) > 5 else '?'
            verdict = []
            if not ok:
                verdict.append('RAISED')
            if ec:
                verdict.append('LOGGED %d' % ec)
            if secs > budget:
                verdict.append('OVER by %.2fs' % (secs - budget))
            print('%-22s %-6s %8.4f %4d %-9s %s %s'
                  % (name, ok, secs, ec, status, emsg[:34],
                     ' '.join(verdict) if verdict else 'ok'))
            rows.append((name, ok, secs, ec, ' '.join(verdict)))

        print('\n--- summary ---')
        nraise = sum(1 for r in rows if not r[1])
        nlog = sum(1 for r in rows if r[3])
        nover = [r for r in rows if r[2] > budget]
        print('%d presses: %d raised, %d logged an event, %d over the %.2f s budget'
              % (len(rows), nraise, nlog, len(nover), budget))
        if nover:
            print('over budget: ' + ', '.join('%s %.2fs' % (r[0], r[2]) for r in nover))
        slowest = max(rows, key=lambda r: r[2]) if rows else None
        if slowest:
            print('slowest: %s at %.3f s' % (slowest[0], slowest[2]))

        print('\n--- residual event log (should be empty) ---')
        for m in d.errors():
            print('  ' + str(m))
    finally:
        d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

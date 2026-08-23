#!/usr/bin/env python3
"""Load the app onto the DMM6500 over the socket and start it. Then drive it.

WHY NOT THE .tspa: installing the archive is a front-panel operation off a USB key.
This loads exactly the same concatenated module bodies over the LAN and calls
sdec.start() itself, which is what the archive's entry point does -- so it exercises
the shipping code path without a physical visit.

THIS SPENDS THE ONE UI BUILD THIS POWER CYCLE. sdec.start() refuses a second build
because rebuilding crashes the firmware hard enough to need a power cycle, and there
is no smart plug, so it costs a human. Hence:

  * every module is syntax-checked offline first (luac -p, tools/lint_tsp.py)
  * tools/verify_tspa.lua builds BOTH screens against a mock front end and asserts
    the object counts, so a build that would fail here has already failed there
  * sdec is cleared before loading, with its capture buffer deleted first -- nil'ing
    a table that owns a buffer handle strands the buffer until a power cycle

--capture presses Capture N times afterwards and reports what the panel would show,
which is the part worth having: the first press auto-detects and auto-locks, and the
second onward should be markedly faster and hold more bytes.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM

MODULES = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
           'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp']

# Clearing before the load. The capture buffer goes FIRST: sdec.buf is the only
# reference to a firmware object, so dropping the table without deleting it leaks the
# buffer until the next power cycle -- the same accumulation the object-lifetime rule
# in serial_app.tsp exists to prevent.
PRELUDE = '''
if sdec ~= nil then
  pcall(function() if sdec.buf ~= nil then buffer.delete(sdec.buf) end end)
  pcall(function() trigger.model.abort() end)
end
sdec = nil
ulog = nil
eventlog.clear()
print('PRE cleared')
'''

REPORT = '''
function app_report()
  local r = sdec.res
  print(string.format('R status=%s built=%s err=%s',
                      tostring(sdec.ui_status), tostring(sdec.built),
                      tostring(sdec.lasterr)))
  print(string.format('R baud=%s fmt=%s fs=%s acq_fs=%s nread=%s',
                      tostring(sdec.baud), tostring(sdec.fmt_text and sdec.fmt_text()),
                      tostring(sdec.fs), tostring(sdec.acq_fs),
                      tostring(sdec.nread)))
  print(string.format('R bytes=%s good=%s bad=%s forced=%s mode=%s view=%s',
                      tostring(r and r.nf), tostring(r and r.ngood),
                      tostring(r and r.nbad), tostring(sdec.force_baud),
                      tostring(sdec.capmode), tostring(sdec.ui_mode)))
  print(string.format('R window=%s delfails=%s fillfails=%s errcount=%s log=%s',
                      tostring(sdec.window_bytes and r and
                               sdec.window_bytes(sdec.baud, r.nbits, r.par, r.nstop)),
                      tostring(sdec.delfails), tostring(sdec.fillfails),
                      tostring(sdec.errcount), tostring(sdec.flog_bytes)))
  local nt, nn = sdec.ui_notes()
  local i
  for i = 1, nn do print('R note: ' .. tostring(nt[i])) end
  if r ~= nil and r.nf > 0 then
    print('R text: ' .. tostring(sdec.ua_text_line(1, 60)))
  end
  print('R end')
end
'''


def load_app(d, verbose=True):
    body = ["-- ==== %s ====\n%s" % (m, open(m).read()) for m in MODULES]
    src = PRELUDE + '\n'.join(body) + REPORT + "\nprint('===DONE===')"
    if verbose:
        print('loading %d bytes / %d lines' % (len(src), src.count('\n') + 1))
    t0 = time.time()
    out = d.load_script('sdecapp', src, timeout=300)
    if verbose:
        print('  %.1f s' % (time.time() - t0))
    for ln in out:
        if ln and ln != '===DONE===':
            print('  load: ' + ln)
    probe = d.q('print(tostring(sdec ~= nil), tostring(sdec.start ~= nil), '
                'tostring(sdec.built), tostring(sdec.autolock))')
    print('  probe (sdec / start / built / autolock): %s' % probe)
    return probe


def read_until(d, sentinel='R end', timeout=180, echo=True):
    lines = []
    while True:
        ln = d.line(timeout)
        if ln is None:
            lines.append('<timeout>')
            break
        lines.append(ln)
        if echo:
            print('   ' + ln)
        if ln == sentinel:
            break
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--captures', type=int, default=2,
                    help='Capture presses after the build')
    ap.add_argument('--no-start', action='store_true',
                    help='load only, do not spend the UI build')
    a = ap.parse_args()

    d = DMM()
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        load_app(d)
        if a.no_start:
            print('\nloaded but NOT started (--no-start): build budget untouched')
            return 0

        print('\n--- sdec.start()  [this is the one UI build this power cycle] ---')
        d.drain()
        d.send('local ok, why = sdec.start() '
               'print(string.format("START ok=%s why=%s", tostring(ok), tostring(why)))')
        print('   ' + str(d.line(120)))
        d.drain()
        d.send('app_report()')
        read_until(d)

        for k in range(a.captures):
            print('\n--- Capture press %d ---' % (k + 1))
            d.drain()
            d.send('timer.cleartime() local ok = sdec.capture() '
                   'print(string.format("CAP ok=%s t=%.3f", tostring(ok), '
                   'timer.gettime()))')
            print('   ' + str(d.line(180)))
            d.drain()
            d.send('app_report()')
            read_until(d)

        print('\n--- event log ---')
        for m in d.errors():
            print('   ' + str(m))
    finally:
        d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

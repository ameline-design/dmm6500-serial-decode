#!/usr/bin/env python3
"""Write a .tspa onto the instrument's USB key over the LAN, byte for byte.

WHY NOT JUST loadscript IT. Sending the script over the control socket and calling
scriptVar.save() does put it in internal memory, but it is NOT the same artefact or the
same install path:

  * the firmware STRIPS every '\\r' it receives, so the stored source comes back about
    7 kB smaller than the archive -- fatal when the quantity under test is size
  * the icon after `endscript` is never registered, so the app appears only under
    MENU > Scripts and not under Manage Apps

Writing the file to the key instead leaves the instrument's own installer to do the
install, so a result can be compared with every result obtained by carrying the key
across the room. The only thing this replaces is the walk.

Verified by reading it back, because a silent short write is the exact failure this must
not have, and neither front end reports one at the write. file.write returned success and
posted a popup; an io write to a dead-key handle returns success and posts nothing at all,
measured. So the length and the CR/LF counts are compared against the local file
afterwards, with only the counts coming back over the socket, never the content.

    python3 tools/push_tspa.py --file ~/tmp/sdec-versions/C_ca93c8f.tspa
    python3 tools/push_tspa.py --file build.tspa --dest /usb1/Serial_Decode.tspa
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM          # noqa: E402

END = '===PUSH-END==='

# Either app, because this tool pushes either one and what each ticks from is different.
# sdec drives a display timer whose handler string is the only off switch -- clearing the
# object does not stop it (tsp/serial_ui.tsp:269-273) -- and it exposes ui_tick_off/on for
# exactly this. fftsa drives a frame function the timer resolves by name, so emptying the
# field stops the body.
#
# The reply reports WHAT IT SAW and WHAT IT PARKED, as two lists, rather than answering
# true. A park that found no app has to be distinguishable from a park that worked: a form
# that answered true when the app's table was absent reported success for having done
# nothing, which is the whole hazard this exists to remove.
#
# fftsa.frame is saved before it is replaced and only when it is a function, so a second
# park cannot save the empty stub over the real body and leave no way back.
PARK = ("do local saw, got = '', '' "
        "if sdec ~= nil then saw = saw .. 'sdec ' "
        "local ok, r = pcall(sdec.ui_tick_off) if ok and r then got = got .. 'sdec ' end end "
        "if fftsa ~= nil then saw = saw .. 'fftsa ' "
        "if type(fftsa.frame) == 'function' then "
        "if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end "
        "fftsa.frame = function() end got = got .. 'fftsa ' end end "
        "print('PK|' .. saw .. '|' .. got) end")
UNPARK = ("do local got = '' "
          "if sdec ~= nil then local ok, r = pcall(sdec.ui_tick_on) "
          "if ok and r then got = got .. 'sdec ' end end "
          "if fftsa ~= nil and fftsa.saved_frame ~= nil then "
          "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil got = got .. 'fftsa ' end "
          "print('UP|' .. got) end")
# The execute path accepts exactly 1024 bytes on a line, terminator included; one more
# raises -363. Everything below budgets against that, with room for the wrapper.
LINE_BUDGET = 1024
WRAP = len('fh:write("")') + 8     # the io form is 5 bytes shorter than file.write(fh,"")
SYNC_EVERY = 25


def lua_quote(chunk):
    """A Lua 5.0.2 double-quoted literal for arbitrary bytes."""
    out = []
    for b in chunk:
        if b == 0x5C:
            out.append('\\\\')
        elif b == 0x22:
            out.append('\\"')
        elif b == 0x0A:
            out.append('\\n')
        elif b == 0x0D:
            out.append('\\r')
        elif 32 <= b <= 126:
            out.append(chr(b))
        else:
            # Decimal escape. NOT padded to three digits blindly -- \\ddd stops at three
            # digits, so a following literal digit would be absorbed into the escape.
            out.append('\\%03d' % b)
    return ''.join(out)


def chunks(data, budget):
    """Split so that each chunk's ESCAPED length fits the budget.

    Measured per byte rather than assumed: an escaped byte is 1 to 4 characters, so a
    fixed raw chunk size would overrun the line limit on a run of escapes.
    """
    out, cur, curlen = [], bytearray(), 0
    for b in data:
        esc = len(lua_quote(bytes([b])))
        if curlen + esc > budget and cur:
            out.append(bytes(cur))
            cur, curlen = bytearray(), 0
        cur.append(b)
        curlen += esc
    if cur:
        out.append(bytes(cur))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--dest', default=None,
                    help='path on the instrument; defaults to /usb1/<basename>')
    a = ap.parse_args()

    with open(a.file, 'rb') as fh:
        data = fh.read()
    dest = a.dest or ('/usb1/' + os.path.basename(a.file))
    print('%s -> %s' % (a.file, dest))
    print('  %d bytes, cr=%d lf=%d' % (len(data), data.count(b'\r'), data.count(b'\n')))

    parts = chunks(data, LINE_BUDGET - WRAP)
    print('  %d write statements' % len(parts))

    # recover=False. The default constructor calls clear_dead_sockets() when its first alive()
    # probe fails, and that connects to the DST port -- which aborts the running script. That
    # has not been observed from here, but writing a file to the key must not be ABLE to do it.
    d = DMM(timeout=120, recover=False)
    parked = ''
    try:
        print(' ', d.q('print(localnode.model, localnode.version)'))
        # PARK THE APP'S FRAMES. DO NOT GO HOME.
        #
        # This used to switch to SCREEN_HOME, for two good reasons: a live app's frame holds
        # the interpreter about three quarters of the time, so statements come back "a command
        # from another interface is running", and the app's own timer would be touching the
        # same filesystem mid-write. Going HOME fixes both and breaks something worse.
        #
        # Measured 2026-11-09, twice: the HOME screen is a LIVE MEASUREMENT -- DIGITIZE
        # VOLTAGE, taking its own readings -- so the front panel reconfigures the digitizer
        # under the app, and the app's next capture fails with rc=-5 ECAPTURE. It halts, says
        # so on the glass, and only a relaunch clears it. Restoring the screen afterwards does
        # not help: the damage is to the measurement subsystem, not to which screen shows.
        #
        # Parking does both jobs without touching the panel: the tick's handler is cleared and
        # the frame body becomes empty, so neither files nor holds the interpreter. Unparked in
        # the finally, which is where it has to be -- four exits below raise past this point,
        # and an app left with an empty frame body renders nothing and looks exactly like the
        # dead app this tool exists to stop producing.
        #
        # The reply lists what it SAW and what it PARKED. Seeing an app and failing to park it
        # is the refusal; seeing none is not, because pushing to a key with nothing running is
        # the ordinary case. A form that answered true when the app's table was absent reported
        # success for having done nothing, which is the hazard itself.
        for _ in range(40):
            r = d.q(PARK, timeout=30)
            if r is not None and str(r).startswith('PK|'):
                f = str(r)[3:].split('|')
                saw = f[0].strip() if len(f) > 0 else ''
                got = f[1].strip() if len(f) > 1 else ''
                if saw and not got:
                    raise SystemExit('saw %s running and could not park it; refusing to '
                                     'write while it runs' % saw)
                parked = got
                print('  parked: %s' % (got if got else 'nothing running to park'))
                break
            time.sleep(0.5)
        else:
            raise SystemExit('the app did not answer the park; refusing to write')
        d.exec('eventlog.clear()', timeout=30)

        # Mode 'w' truncates, which is what a replacement wants. Opened once and held: one open per
        # chunk would be 600 opens and would also lose the truncation semantics.
        #
        # io, not file.*: a write that fails reported itself only as a popup on the panel, and an io
        # write to a dead-key handle is silent -- measured. Neither is detectable at the write, which
        # is why the read-back below is the verification and not a formality.
        r = d.q('fh = io.open("%s", "w") '
                'print(tostring(fh ~= nil))' % dest, timeout=60)
        if r != 'true':
            raise SystemExit('could not open %s for writing (reply %r)' % (dest, r))

        t0 = time.time()
        for i, part in enumerate(parts):
            d.send('fh:write("%s")' % lua_quote(part))
            if (i + 1) % SYNC_EVERY == 0:
                # SYNCED PERIODICALLY, not fired blind: a few hundred unread statements can
                # overrun the instrument's input buffer, and a sync also gives a progress point
                # that is a real acknowledgement rather than a hope.
                if d.q('print("SYNC")', timeout=60) != 'SYNC':
                    raise SystemExit('lost sync after %d of %d statements' % (i + 1, len(parts)))
                sys.stdout.write('\r  %d/%d statements' % (i + 1, len(parts)))
                sys.stdout.flush()
        d.exec('fh:flush() fh:close() fh = nil', timeout=60)
        print('\r  %d/%d statements, %.1f s' % (len(parts), len(parts), time.time() - t0))

        d.drain()
        d.send('local g = io.open("%s", "r") '
               'if g == nil then print("NO-FILE") else '
               '  local raw = g:read("*a") '
               '  g:close() '
               '  if raw == nil or raw == "" then print("NO-READ") else '
               '    local _, ncr = string.gsub(raw, "\\r", "") '
               '    local _, nlf = string.gsub(raw, "\\n", "") '
               '    print("ONKEY len=" .. string.len(raw) .. " cr=" .. ncr .. " lf=" .. nlf) '
               '  end end '
               'print("EV " .. tostring(eventlog.getcount())) '
               'print("%s")' % (dest, END))
        got = None
        while True:
            ln = d.line(120)
            if ln is None or ln == END:
                break
            print('  ' + ln)
            if ln.startswith('ONKEY '):
                got = dict(kv.split('=') for kv in ln[6:].split())

        print()
        if got is None:
            print('  COULD NOT READ THE FILE BACK')
            raise SystemExit(1)
        same = (int(got['len']) == len(data) and int(got['cr']) == data.count(b'\r')
                and int(got['lf']) == data.count(b'\n'))
        print('  local len=%d cr=%d lf=%d' % (len(data), data.count(b'\r'), data.count(b'\n')))
        print('  onkey len=%s cr=%s lf=%s' % (got['len'], got['cr'], got['lf']))
        print('  -> %s' % ('IDENTICAL: install it from Manage Apps as usual'
                           if same else 'MISMATCH: do not install this'))
        if not same:
            raise SystemExit(1)
    finally:
        # THE UNPARK, where every exit above reaches it. Four of them raise -- the open
        # failing, a lost sync, an unreadable read-back, and any socket error in the write
        # loop -- and one of those has fired on this bench before. Skipping it leaves the app
        # ticking with its handler cleared and its frame body empty: nothing on the glass
        # moves, which is the symptom this tool is supposed to stop causing.
        #
        # Checked and not merely attempted: DMM.q returns None on a timeout and after
        # exhausting its refusal retries rather than raising, so an except branch alone never
        # fires and the operator reads "IDENTICAL" over a frame-dead app.
        if parked:
            back = None
            try:
                back = d.q(UNPARK, timeout=30)
            except Exception as exc:                                 # noqa: BLE001
                print('  unpark FAILED -- %s' % exc)
            if back is not None and str(back).startswith('UP|'):
                print('  unpark: %s' % str(back)[3:].strip())
            else:
                print('  UNPARK UNCONFIRMED (reply %r) -- the app is still parked.' % back)
                print('  Run on the instrument: sdec.ui_tick_on()')
                print('  and, for the FFT app: fftsa.frame = fftsa.saved_frame '
                      'fftsa.saved_frame = nil')
        d.close()


if __name__ == '__main__':
    main()

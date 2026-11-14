#!/usr/bin/env python3
"""Set a Lua global in the running FFT app, and make it take effect, without a rebuild.

The pixel path's experiments are knobs: FFTSA_HDRDERIVE arms the derived cursor offsets,
FFTSA_PXSEED carries the learned ring span. nl.init reads them, and nl.init runs from
fftsa.apply() -- so setting a global alone changes nothing until the next Apply.

Rather than press Apply through the panel, this sets fftsa.retune_pending, which is the flag
the app's own frame loop uses to install a new plan BETWEEN frames. That is the supported path:
apply() cannot run inside a frame, and the frame loop is what knows when it is not in one.

Frames are parked for the socket's visit and unparked in the finally, the same discipline
push_tspa.py uses -- a socket session kills display event dispatch, so an app left parked
stops drawing. recover=False throughout: clear_dead_sockets() connects to the DST port and
aborts the running script, and nothing here is worth that risk.

    python3 -I tools/set_fftsa_global.py FFTSA_HDRDERIVE true
    python3 -I tools/set_fftsa_global.py FFTSA_HDRDERIVE nil      # back to the model default
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM          # noqa: E402

PARK = ("do local got = '' if fftsa ~= nil and type(fftsa.frame) == 'function' then "
        "if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end "
        "fftsa.frame = function() end got = 'fftsa' end print('PK|' .. got) end")
UNPARK = ("do local got = '' if fftsa ~= nil and fftsa.saved_frame ~= nil then "
          "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil got = 'fftsa' end "
          "print('UP|' .. got) end")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    name, value = sys.argv[1], sys.argv[2]
    if not name.replace('_', '').isalnum():
        print('refused: %r is not a plain identifier' % name)
        return 2
    # Only the literals this is for. An arbitrary expression here would be a statement sent to
    # an instrument running an app, which is not what a knob-setter should be able to do.
    if value not in ('true', 'false', 'nil'):
        print('refused: value must be true, false or nil')
        return 2

    d = DMM(timeout=60, recover=False)
    parked = ''
    try:
        print(' ', d.q('print(localnode.model, localnode.version)'))
        parked = d.q(PARK, timeout=30)
        print(' ', parked)
        print(' ', d.q('do %s = %s print("SET|%s=" .. tostring(%s)) end'
                       % (name, value, name, name), timeout=30))
        # Retune between frames, which is what re-runs nl.init and re-reads the global.
        print(' ', d.q('do if fftsa ~= nil then fftsa.retune_pending = true '
                       'print("RT|armed") else print("RT|no app") end end', timeout=30))
    finally:
        try:
            print(' ', d.q(UNPARK, timeout=30))
        finally:
            d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())

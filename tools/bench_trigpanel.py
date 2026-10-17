#!/usr/bin/env python3
"""The trigger-manual claims that need a finger, and cannot be reached any other way.

    A  a WAIT on EVENT_DISPLAY as the FIRST block        SETTLED -- see below
    B  switching between local and remote control        OPEN: needs the front panel touched
       aborts a running model                            while the instrument is in remote

Case A is settled and this tool is a second opinion on it, not the only route. `docs/UNDOCUMENTED.md`
carries the four-arm table -- no press, key enabled, key disabled, key enabled again -- and the
key-enable crossover in it is what makes the press the cause. That press went in through the HTTP
virtual panel (POST /ajax_proc, function=7/8, button=8), which the owner has since confirmed may stand
as evidence. Two things about that path are NOT open: an agent does not take it on its own initiative,
and the disabled arm of that table is not repeatable here, because `display.KEY_TRIGGER` must never be
turned off -- it is the operator's escape route out of a running model.

So case B is what this still asks a human for, and it measures the press with the timing taken INSIDE
the instrument.

WHY INSIDE. A host-side poll of a parked model is the subject of docs/TRIGGER.md, 'Poll from inside
the instrument', and cannot be used to measure it: its own numbers show a parked model dying at
427-441 ms under host traffic. Here the whole window is one chunk -- initiate, poll, report -- so
the host sends nothing between the arm and the verdict and the socket is silent for the operator's
entire window.

    python3 tools/bench_trigpanel.py            # both cases
    python3 tools/bench_trigpanel.py --case a   # just the TRIGGER key
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM              # noqa: E402

WINDOW = 40          # seconds the model will sit there waiting for a finger
CAP = 200000         # 5 s of samples at 40 kS/s, so capacity is never the limit

# Abort first: a model left running makes this firmware refuse load() and post 2727 on any
# dmm.digitize write, out of band, and the chunk then raises before it can print.
SETUP = """
pcall(function() trigger.model.abort() end)
delay(0.05)
dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.samplerate = 40000
dmm.digitize.count = 1
pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
if TPBUF == nil then
  local mok, nb = pcall(buffer.make, %d, buffer.STYLE_STANDARD)
  if mok then TPBUF = nb end
end
if TPBUF == nil then print('TP0 FATAL buffer.make refused') end
pcall(function() TPBUF.clear() end)
pcall(function() trigger.model.load('Empty') end)
local function st_now()
  local ok, s = pcall(trigger.model.state)
  if not ok then return nil end
  return s
end
local function running(s)
  return s == trigger.STATE_WAITING or s == trigger.STATE_RUNNING
end
""" % CAP

# Case A: the wait is block 1. Nothing is sampling ahead of it, which is the whole question -- the
# established restriction is specific to EVENT_ANALOGTRIGGER, which is derived from the sample stream.
CASE_A = SETUP + """
trigger.model.setblock(1, trigger.BLOCK_WAIT, trigger.EVENT_DISPLAY)
trigger.model.setblock(2, trigger.BLOCK_BUFFER_CLEAR, TPBUF)
trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, TPBUF, 100)
trigger.model.initiate()
timer.cleartime()
local st, el = st_now(), 0
local seen = ''
while el < %d do
  st = st_now()
  el = timer.gettime()
  local nm = tostring(st)
  if string.find(seen, nm, 1, true) == nil then seen = seen .. nm .. ' ' end
  if not running(st) then break end
end
print(string.format('TPA elapsed=%%.3f state=%%s readings=%%d states=[%%s]',
                    el, tostring(st), TPBUF.n, seen))
pcall(function() trigger.model.abort() end)
pcall(function() trigger.model.load('Empty') end)
print('TPADONE')
""" % WINDOW

# Case B: parked on the rear BNC with no marker, so nothing but an abort can end it. A press that
# returns the instrument to local control either aborts the model or it does not.
CASE_B = SETUP + """
trigger.model.setblock(1, trigger.BLOCK_BUFFER_CLEAR, TPBUF)
trigger.model.setblock(2, trigger.BLOCK_MEASURE_DIGITIZE, TPBUF, trigger.COUNT_INFINITE)
trigger.model.setblock(3, trigger.BLOCK_WAIT, trigger.EVENT_EXTERNAL)
trigger.model.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, TPBUF, 100)
trigger.model.initiate()
timer.cleartime()
local st, el = st_now(), 0
local seen = ''
while el < %d do
  st = st_now()
  el = timer.gettime()
  local nm = tostring(st)
  if string.find(seen, nm, 1, true) == nil then seen = seen .. nm .. ' ' end
  if not running(st) then break end
end
print(string.format('TPB elapsed=%%.3f state=%%s readings=%%d states=[%%s]',
                    el, tostring(st), TPBUF.n, seen))
for i = 1, 6 do
  local ev, msg = eventlog.next()
  if ev == nil or ev == 0 then break end
  print(string.format('TPB event %%s %%s', tostring(ev), tostring(msg)))
end
pcall(function() trigger.model.abort() end)
pcall(function() trigger.model.load('Empty') end)
print('TPBDONE')
""" % WINDOW


def run(d, body, label):
    out = d.load_script('tpanel', body, run=True, timeout=WINDOW + 40)
    lines = [str(l).strip() for l in out if str(l).strip()]
    for l in lines:
        if l.startswith('TP'):
            print('    ' + l)
    if not any(l.startswith('TP') for l in lines):
        print('    RAW %r' % (lines[:6],))
    return ' | '.join(l for l in lines if l.startswith('TP'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--case', default='ab', help='a, b or ab')
    a = ap.parse_args()

    d = None
    try:
        d = DMM()
        print('DMM:', str(d.q('*IDN?')).strip())
        print()
        res = {}

        if 'a' in a.case:
            print('  [A] WAIT on EVENT_DISPLAY as the FIRST block')
            print('      >>> PRESS THE FRONT-PANEL TRIGGER KEY ONCE, within %d s <<<' % WINDOW)
            print('      (if the key does nothing the model sits the whole window -- that is the'
                  ' answer too)')
            res['a'] = run(d, CASE_A, 'A')
            print()

        if 'b' in a.case:
            print('  [B] does returning to LOCAL control abort a running model?')
            print('      >>> TOUCH THE SCREEN or press HOME, within %d s. NOT the TRIGGER key. <<<'
                  % WINDOW)
            res['b'] = run(d, CASE_B, 'B')
            print()

        print('=== verdicts ===')
        if 'a' in res:
            fired = 'readings=100' in res['a'] or 'STATE_IDLE' in res['a'].upper()
            print('  [A] EVENT_DISPLAY as block 1 is satisfiable : %s'
                  % ('YES -- the key ended the wait' if fired
                     else 'NO -- it sat the whole window'))
        if 'b' in res:
            aborted = 'ABORT' in res['b'].upper()
            print('  [B] local control aborts a running model    : %s'
                  % ('YES' if aborted else 'NO -- it stayed parked through the press'))
        for k in sorted(res):
            print('  raw %s: %s' % (k.upper(), res[k]))
    finally:
        try:
            if d is not None:
                d.close()
        except Exception:
            pass


if __name__ == '__main__':
    main()

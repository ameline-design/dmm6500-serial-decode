#!/usr/bin/env python3
"""Report 1, driven: how many display objects can exist, and does display.delete give any back?

    python3 docs/vendor/repro-01-object-pool.py none      # never delete  -> the pool size
    python3 docs/vendor/repro-01-object-pool.py both       # delete child and screen
    python3 docs/vendor/repro-01-object-pool.py screen     # delete the screen only
    python3 docs/vendor/repro-01-object-pool.py both --changescreen

EVERY RUN NEEDS ITS OWN POWER CYCLE. The pool does not reset any other way, so a second run in one
power cycle measures whatever the first left behind -- which is the finding, and also the trap.

The three modes together are the whole report. `none` bounds the pool. If `both` fails at the same
cycle as `none`, display.delete gave nothing back; if it fails later, it gave part of it back. If
`screen` matches `both`, a child is freed with its parent; if it matches `none`, it is not.

The loop is sent with loadscript rather than as a statement, because a statement this size is the
subject of report 3.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), 'tools'))
from dmmrun import DMM                                                  # noqa: E402

# 16777215 rather than 0xFFFFFF: the instrument lexes hex, stock 5.0.2 luac does not, and this file is
# meant to survive being pasted anywhere.
BODY = """
local MODE, MAX, CHG = '%(mode)s', %(max)d, %(chg)s
eventlog.clear()
-- IT KEEPS GOING PAST THE FIRST NIL ON PURPOSE. The ceiling is one half of the report and the SILENCE is
-- the other: every failure after the first has to be counted against the event log to show that 1701 is
-- logged once and the rest say nothing at all.
local n, nok, nnil, firstnil, what = 0, 0, 0, 0, 'none'
while n < MAX do
  n = n + 1
  local scr = display.create(display.ROOT, display.OBJ_SCREEN, 'P' .. tostring(n))
  -- WHAT A HANDLE IS, printed once: if they are small sequential numbers then an app that has lost its
  -- handles -- which is what reloading a script does -- could in principle delete them by value, and the
  -- pool would be recoverable without a power cycle. Nothing in the reference says whether that is so.
  if n == 1 then print('  first screen handle: ' .. tostring(scr) .. '  type ' .. type(scr)) end
  if scr == nil then
    nnil = nnil + 1
    if firstnil == 0 then firstnil, what = n, 'screen' end
  else
    local txt = display.create(scr, display.OBJ_TEXT, 12, 20, 'x', 16777215,
                               display.FONT_MEDIUM, display.JUST_LEFT)
    if n == 1 then print('  first text handle:   ' .. tostring(txt) .. '  type ' .. type(txt)) end
    if txt == nil then
      nnil = nnil + 1
      if firstnil == 0 then firstnil, what = n, 'child' end
    else
      nok = nok + 1
    end
    if CHG then pcall(function() display.changescreen(display.SCREEN_HOME) end) end
    -- txt is only deleted when it exists: display.delete(nil) raises, which would end the run at the
    -- first failure and hide the count this loop exists to take.
    if MODE == 'both' then
      if txt ~= nil then display.delete(txt) end
      display.delete(scr)
    elseif MODE == 'screen' then
      display.delete(scr)
    end
  end
end
print('MODE=' .. MODE .. '  changescreen=' .. tostring(CHG))
print('  first nil at cycle ' .. tostring(firstnil) .. ', on the ' .. what)
print('  objects created before it: ' .. tostring((firstnil - 1) * 2))
print('  cycles that fully succeeded: ' .. tostring(nok) .. ' of ' .. tostring(n))
print('  create() returned nil: ' .. tostring(nnil) .. ' time(s)')
print('  events logged for those ' .. tostring(nnil) .. ' failures: '
      .. tostring(eventlog.getcount()))
print('===DONE===')
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['none', 'both', 'screen'])
    ap.add_argument('--max', type=int, default=2000, help='cycles to try before giving up')
    ap.add_argument('--changescreen', action='store_true',
                    help='switch away from the screen before deleting it')
    a = ap.parse_args()

    d = DMM()
    print('model/fw  ' + d.q('print(localnode.model, localnode.version)'))
    print('events at start  ' + d.q('print(eventlog.getcount())')
          + '   <- must be 0: a nonzero count means this is not a fresh power cycle')
    body = BODY % {'mode': a.mode, 'max': a.max, 'chg': 'true' if a.changescreen else 'false'}
    for ln in d.load_script('repro01', body, timeout=600):
        print(ln)
    # THE LOG ITSELF, because the second half of the report is that 1701 is logged once and every later
    # failure is silent. A count of 1 beside hundreds of failures is the evidence.
    print('event log:')
    for e in d.errors():
        print('  ' + e)
    # THE PANEL IS PUT BACK, because deleting a screen does not revert to the one before it: after a run
    # that deletes 2000 screens the display is BLACK, with no way back from the front panel. Observed.
    d.close(restore=True)


if __name__ == '__main__':
    main()

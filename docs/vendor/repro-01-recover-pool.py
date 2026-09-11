#!/usr/bin/env python3
"""Can an exhausted display-object pool be recovered without a power cycle?

    python3 docs/vendor/repro-01-recover-pool.py

WHY IT MATTERS MORE THAN THE POOL SIZE. Reloading a TSP script replaces the table its handles were in,
so the objects the previous load created become unreachable: nothing can delete them and the pool
shrinks by one build per reload. That is the whole reason a panel app needs a power cycle per
development iteration. But display.create returns a small sequential NUMBER -- 49 for the first object
this app creates on a freshly booted DMM6500 -- so a lost handle is guessable, and deleting by value
would return the pool without a power cycle. Nothing in the reference says whether that is allowed.

WHAT IT DOES. Exhausts the pool, sweeps handles from FIRST upward calling display.delete on each,
then tries to create again and reports whether the pool came back.

HANDLES BELOW 49 ARE LEFT ALONE. They belong to the firmware's own home screen, and deleting those is
not a recovery, it is vandalism -- the panel has no way back except the power cycle this is trying to
avoid. FIRST is therefore a floor, not a guess.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), 'tools'))
from dmmrun import DMM                                                  # noqa: E402

BODY = """
local FIRST, LAST = %(first)d, %(last)d
eventlog.clear()
-- 1. EXHAUST IT, the way a run of reloads does: create and never delete.
local n, hfirst, hlast = 0, 0, 0
while n < 400 do
  n = n + 1
  local h = display.create(display.ROOT, display.OBJ_SCREEN, 'X' .. tostring(n))
  if h == nil then break end
  if hfirst == 0 then hfirst = h end
  hlast = h
  local t = display.create(h, display.OBJ_TEXT, 12, 20, 'x', 16777215,
                           display.FONT_MEDIUM, display.JUST_LEFT)
  if t == nil then break end
  hlast = t
end
print('exhausted after ' .. tostring(n) .. ' cycle(s); handles ran ' .. tostring(hfirst)
      .. '..' .. tostring(hlast) .. '; events=' .. tostring(eventlog.getcount()))

-- 2. CONFIRM IT IS EXHAUSTED, so the recovery below is measured against a known nil.
local probe = display.create(display.ROOT, display.OBJ_SCREEN, 'PROBE A')
print('create while exhausted -> ' .. tostring(probe))

-- 3. SWEEP BY VALUE. pcall each one: a handle that was never issued, or was issued and freed, may
-- raise rather than return, and one raise must not end the sweep.
local nfreed, nraised = 0, 0
local h
for h = FIRST, LAST do
  local ok = pcall(function() display.delete(h) end)
  if ok then nfreed = nfreed + 1 else nraised = nraised + 1 end
end
print('swept ' .. tostring(FIRST) .. '..' .. tostring(LAST) .. ': ' .. tostring(nfreed)
      .. ' accepted, ' .. tostring(nraised) .. ' raised')

-- 4. IS THE POOL BACK? One create, then a screen with a child, which is what an app needs.
local after = display.create(display.ROOT, display.OBJ_SCREEN, 'PROBE B')
print('create after the sweep -> ' .. tostring(after))
if after ~= nil then
  local kid = display.create(after, display.OBJ_TEXT, 12, 20, 'back', 16777215,
                             display.FONT_MEDIUM, display.JUST_LEFT)
  print('  and a child on it   -> ' .. tostring(kid))
  -- 5. HOW MUCH CAME BACK, which is the number that decides whether this is a workaround or a curiosity.
  local m = 0
  while m < 400 do
    m = m + 1
    local h2 = display.create(display.ROOT, display.OBJ_SCREEN, 'Y' .. tostring(m))
    if h2 == nil then break end
    local t2 = display.create(h2, display.OBJ_TEXT, 12, 20, 'y', 16777215,
                              display.FONT_MEDIUM, display.JUST_LEFT)
    if t2 == nil then break end
  end
  print('  cycles available after recovery: ' .. tostring(m - 1))
end
print('events at the end: ' .. tostring(eventlog.getcount()))
print('===DONE===')
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--first', type=int, default=49,
                    help='lowest handle to sweep; below this belongs to the firmware')
    ap.add_argument('--last', type=int, default=700)
    a = ap.parse_args()
    d = DMM()
    print('model/fw  ' + d.q('print(localnode.model, localnode.version)'))
    for ln in d.load_script('recover01', BODY % {'first': a.first, 'last': a.last}, timeout=900):
        print(ln)
    print('event log:')
    for e in d.errors():
        print('  ' + e)
    d.close(restore=True)


if __name__ == '__main__':
    main()

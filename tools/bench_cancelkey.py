#!/usr/bin/env python3
"""CAN THE FRONT-PANEL TRIGGER KEY CANCEL A LONG DECODE? The one question blocking one-press decode.

A press on a touch button is NOT DISPATCHED while a Lua script runs -- presses queue until the
handler returns. That is why the decode is chunked into one press per slice: the app hands the panel
back so the firmware can deliver the next press. Take the chunking inside a loop and there is no
longer any way for the operator to say stop.

`display.waitevent()` is eliminated: it BLOCKS and wedges the instrument (see
DMM_WAITEVENT_WEDGES_THE_INSTRUMENT). `trigger.wait()` is the wrong subsystem -- it retrieves *TRG
from the command queue, not front-panel events.

WHAT IS LEFT is the trigger subsystem, which is firmware and does not need the interpreter. The
front-panel TRIGGER key generates `trigger.EVENT_DISPLAY` (ref 14-331), and an EVENT BLENDER is a
latching event detector: "If one or more trigger events were detected since the last time
trigger.blender[N].wait() or .clear() was called, this function returns immediately" (14-334). If the
latch is set by firmware while Lua is busy, then a cheap `wait(small)` between decode windows is a
Cancel button that costs no display API at all.

FOUR QUESTIONS, in the order that makes each one cheap:

  1. Does the key generate EVENT_DISPLAY with NOTHING ARMED? Every previous confirmation of this key
     had a trigger model waiting on it. A cancel poll has no model.
  2. Does `wait(t)` with a small t RETURN, rather than block? This is the waitevent trap, and it is
     the reason nothing here ever calls wait(0): a zero timeout meaning "wait forever" is exactly how
     the display API behaves, and one wedge costs a power cycle.
  3. Does the latch SURVIVE A BUSY INTERPRETER? The decisive one. The instrument spins in a Lua loop
     for several seconds; the operator presses the key in the middle of it; the poll afterwards must
     see it. If this fails, the whole approach fails, and it fails for the same reason touch presses
     do.
  4. What does a poll COST? It runs once per decode window, so anything under a few ms is free.

Needs a human finger, which is why it is a tool and not a sweep stage. It does NOT build the app, so
it does not spend the one UI build of a power cycle -- run it BEFORE the sweep.

    python3 tools/bench_cancelkey.py
    python3 tools/bench_cancelkey.py --wait 45      # longer window to reach the key
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
import bench_sync as BS                                     # noqa: E402

# The blender the app does not use. Blender 1 carries the rear-BNC + edge combination in
# serial_core.acq_triggered(), so a cancel latch on it would fight the trigger source.
BLENDER = 2

CANCEL_TSP = r'''
-- Arm the latch. reset() first: a blender carries stimulus and orenable across scripts, and this
-- one may have been left combining something else.
function ck_arm()
  local ok, err = pcall(function()
    trigger.blender[%(B)d].reset()
    trigger.blender[%(B)d].orenable = true
    trigger.blender[%(B)d].stimulus[1] = trigger.EVENT_DISPLAY
    trigger.blender[%(B)d].clear()
  end)
  print(string.format('ARM %%s|%%s|%%s', tostring(ok), tostring(err),
        tostring(trigger.EVENT_DISPLAY)))
end

-- One poll, timed ON THE INSTRUMENT so the socket is not in the measurement.
function ck_poll(t)
  timer.cleartime()
  local got, ok = false, true
  ok = pcall(function() got = trigger.blender[%(B)d].wait(t) end)
  print(string.format('P %%s|%%s|%%.4f', tostring(ok), tostring(got), timer.gettime()))
end

-- THE DECISIVE TEST. Spin in Lua for `secs`, with the interpreter unable to dispatch anything, then
-- poll. A press during the spin must be visible afterwards.
function ck_busy(secs)
  trigger.blender[%(B)d].clear()
  print('BUSY')
  timer.cleartime()
  local x = 0
  while timer.gettime() < secs do
    local i
    for i = 1, 4000 do x = x + i * 0.5 end
  end
  local spent = timer.gettime()
  local got, ok = false, true
  ok = pcall(function() got = trigger.blender[%(B)d].wait(0.01) end)
  -- A SECOND poll: the detector auto-resets after a wait, so one press must latch exactly once.
  local again = false
  pcall(function() again = trigger.blender[%(B)d].wait(0.01) end)
  print(string.format('B %%s|%%s|%%s|%%.3f|%%s', tostring(ok), tostring(got),
        tostring(again), spent, tostring(x ~= nil)))
end

-- What a poll costs, amortised over n of them with no press pending.
function ck_cost(n, t)
  trigger.blender[%(B)d].clear()
  timer.cleartime()
  local i
  for i = 1, n do
    pcall(function() trigger.blender[%(B)d].wait(t) end)
  end
  print(string.format('C %%.4f|%%d|%%g', timer.gettime(), n, t))
end

-- CONFIGURATION B: the key with a MODEL WAITING ON IT. Every previous confirmation of this key had
-- one, and the reference hints the two are linked -- "if the TRIGGER key has already been pressed,
-- the trigger-model execution will continue" is written about a model that reaches a wait block, not
-- about a global event source. A model that loops back to its own wait block keeps consuming presses,
-- so several can be tested without re-arming.
function ck_model_arm()
  local ok, err = pcall(function()
    trigger.model.abort()
    trigger.model.setblock(1, trigger.BLOCK_WAIT, trigger.EVENT_DISPLAY)
    trigger.model.setblock(2, trigger.BLOCK_BRANCH_ALWAYS, 1)
    trigger.model.initiate()
  end)
  trigger.blender[%(B)d].clear()
  local s1, s2, n = nil, nil, nil
  pcall(function() s1, s2, n = trigger.model.state() end)
  print(string.format('MA %%s|%%s|%%s|%%s', tostring(ok), tostring(err), tostring(s1),
        tostring(n)))
end

-- Poll BOTH detectors at once: the blender latch is what the app would use, and the model's block
-- number is independent evidence that the press happened at all.
function ck_model_poll(t)
  local got = false
  pcall(function() got = trigger.blender[%(B)d].wait(t) end)
  local s1, s2, n = nil, nil, nil
  pcall(function() s1, s2, n = trigger.model.state() end)
  print(string.format('M %%s|%%s|%%s', tostring(got), tostring(s1), tostring(n)))
end

function ck_model_done()
  pcall(function() trigger.model.abort() end)
  print('MD')
end

function ck_events()
  local ec, emsg = eventlog.getcount(), ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%%s %%s]', tostring(n), tostring(m)) end
  end
  print(string.format('E %%d|%%s', ec, emsg))
end
print('===DONE===')
''' % {'B': BLENDER}


def wait_line(d, prefix, timeout):
    """Next printed line starting with prefix, or None."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        ln = d.line(min(5, timeout))
        if ln is None:
            continue
        if ln.startswith(prefix):
            return ln
        if ln.strip():
            print('    (%s)' % ln.strip())
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wait', type=float, default=40.0,
                    help='seconds to hold each question open for the press')
    ap.add_argument('--busy', type=float, default=10.0,
                    help='seconds to spin the interpreter in the busy-latch test')
    ap.add_argument('--no-armed', dest='armed', action='store_false',
                    help='skip configuration B (a trigger model waiting on the key)')
    ap.add_argument('--armed-only', action='store_true',
                    help='configuration B only -- when A is already known to fail')
    ap.add_argument('--no-busy', dest='busy_test', action='store_false',
                    help='skip the busy-interpreter test')
    a = ap.parse_args()

    d = DMM()
    # ALIGN THE STREAM BEFORE ASKING ANYTHING. This file's whole method is reading printed lines by
    # PREFIX, which cannot tell this question's answer from a previous conversation's line that happens
    # to start the same way -- and a stale 'LATCH ...' read as the answer to a press that never came is
    # precisely the false PASS this test must not produce. See tools/bench_sync.py.
    if not BS.resync(d):
        raise SystemExit('REFUSING: the DMM reply stream will not resync. Another client may be '
                         'connected, or a previous run was killed mid-command.')
    st = BS.tagged(d, [('model', 'localnode.model'), ('ver', 'localnode.version'),
                       ('built', 'sdec ~= nil and sdec.built == true')])
    if st is None:
        raise SystemExit('REFUSING: could not read the instrument identity in one tagged reply.')
    print('DMM: %s  %s' % (st.get('model', '?'), st.get('ver', '?')))
    built = st.get('built', '?')
    print('app built on this power cycle: %s%s' % (built,
          '   (fine -- this test does not build one)' if built != 'true' else ''))
    d.exec('eventlog.clear()', timeout=10)
    for ln in d.load_script('ckmod', CANCEL_TSP, timeout=120):
        if ln and ln != '===DONE===':
            print('  load: %s' % ln)

    verdict = {}

    # ---- Q1/Q2: is the event defined, and does a small timeout return? -------------------
    d.drain()
    d.send('ck_arm()')
    ln = wait_line(d, 'ARM', 20) or 'ARM ?|?|?'
    ok, err, evid = (ln[4:].split('|') + ['?'] * 3)[:3]
    print('\nEVENT_DISPLAY = %s   blender %d armed: %s%s'
          % (evid, BLENDER, ok, '' if err == 'nil' else '  err=' + err))
    if evid == 'nil' or ok != 'true':
        print('REFUSED: this firmware cannot latch the TRIGGER key on a blender.')
        return 2

    for t in (0.001, 0.05):
        d.send('ck_poll(%g)' % t)
        ln = wait_line(d, 'P ', 20)
        if ln is None:
            print('  poll(%g) NEVER RETURNED -- the instrument may be wedged. Power cycle.' % t)
            return 2
        pok, got, secs = ln[2:].split('|')
        print('  poll(%-5g) returned in %.4f s, latched=%s   (no press yet, so false is right)'
              % (t, float(secs), got))
        verdict['returns'] = True
        if got == 'true':
            print('  UNEXPECTED: latched with no press. Something else drives EVENT_DISPLAY.')

    # ---- Q3a: does an IDLE press latch at all? ------------------------------------------
    if not a.armed_only:
        print('\n' + '=' * 78)
        print('PRESS THE FRONT-PANEL **TRIGGER** KEY NOW  (nothing armed; %g s window)' % a.wait)
        print('=' * 78)
        t0, seen = time.time(), False
        while time.time() - t0 < a.wait and not seen:
            d.send('ck_poll(0.2)')
            ln = wait_line(d, 'P ', 10)
            if ln is None:
                break
            pok, got, secs = ln[2:].split('|')
            if got == 'true':
                seen = True
                print('  LATCHED after %.1f s -- the key generates EVENT_DISPLAY with nothing '
                      'armed.' % (time.time() - t0))
        verdict['idle_press'] = seen
        if not seen:
            print('  NOT LATCHED in %g s. Either the key was not pressed, or an idle press '
                  'generates no event.' % a.wait)

    # ---- CONFIGURATION B: the same key, with a model waiting on it -----------------------
    # Run whether or not A latched: if A worked this shows the two coexist, and if it did not this
    # separates "needs an armed model" from "the key does nothing" -- the model's own block number
    # is proof the press happened, independent of any blender.
    if a.armed:
        d.drain()
        d.send('ck_model_arm()')
        ln = wait_line(d, 'MA', 20) or 'MA ?|?|?|?'
        mok, merr, st, blk = (ln[3:].split('|') + ['?'] * 4)[:4]
        print('\ndummy model armed on EVENT_DISPLAY: %s  state=%s block=%s%s'
              % (mok, st, blk, '' if merr == 'nil' else '  err=' + merr))
        if mok == 'true':
            print('=' * 78)
            print('PRESS **TRIGGER** AGAIN -- this time a trigger model is waiting on it (%g s)'
                  % a.wait)
            print('=' * 78)
            t0, blat, madv = time.time(), False, False
            blk0 = blk
            while time.time() - t0 < a.wait and not (blat or madv):
                d.send('ck_model_poll(0.2)')
                ln = wait_line(d, 'M ', 10)
                if ln is None:
                    break
                got, st, blk = ln[2:].split('|')
                if got == 'true':
                    blat = True
                if blk != blk0 or st.find('WAITING') < 0:
                    # The model left the wait block, or came back round to it: either way the key
                    # was pressed, which is the fact the blender result has to be judged against.
                    if st.find('RUNNING') >= 0 or blk != blk0:
                        madv = True
            print('  blender latched: %s     model advanced: %s  (state=%s block=%s)'
                  % (blat, madv, st, blk))
            verdict['armed_blender'] = blat
            verdict['armed_model'] = madv
            if madv and not blat:
                print('  THE PRESS HAPPENED but the blender did not see it -- so EVENT_DISPLAY '
                      'does not feed a blender on this firmware. The model state is the detector.')
            if blat:
                print('  THE BLENDER SAW IT with a model armed -- so the key needs a waiting '
                      'model, and a dummy model plus a blender poll is the cancel mechanism.')
        d.send('ck_model_done()')
        wait_line(d, 'MD', 20)

    # ---- Q3b: THE DECISIVE ONE -- a press while the interpreter is busy ------------------
    if not a.busy_test or not (verdict.get('idle_press') or verdict.get('armed_blender')):
        if not a.busy_test:
            print('\n(busy-interpreter test skipped)')
        else:
            print('\nSKIPPING the busy test: nothing latched even with the interpreter free, so '
                  'there is nothing for it to prove.')
        return report(verdict, d)
    # In whichever configuration latched. If it was B, the dummy model has to be back on the key
    # before the spin, or the busy test would be testing configuration A.
    if verdict.get('armed_blender') and not verdict.get('idle_press'):
        d.send('ck_model_arm()')
        wait_line(d, 'MA', 20)
    print('\n' + '=' * 78)
    print('NOW THE ONE THAT MATTERS. The instrument is about to spin in Lua for %g s with the'
          % a.busy)
    print('panel unable to dispatch anything. PRESS **TRIGGER** WHILE IT IS SPINNING.')
    print('=' * 78)
    time.sleep(1.0)
    d.drain()
    d.send('ck_busy(%g)' % a.busy)
    if wait_line(d, 'BUSY', 20) is None:
        print('  the busy loop never started')
        return 2
    print('  ... spinning, press TRIGGER now ...')
    ln = wait_line(d, 'B ', a.busy + 30)
    if ln is None:
        print('  the busy loop never finished -- the instrument may be wedged.')
        return 2
    bok, got, again, spent, alive = ln[2:].split('|')
    print('  spun %.1f s, latched=%s, second poll=%s' % (float(spent), got, again))
    verdict['busy_press'] = (got == 'true')
    verdict['autoreset'] = (again == 'false')
    if got == 'true':
        print('  CONFIRMED: the latch is set by FIRMWARE while the interpreter is busy.')
        if again == 'false':
            print('  and one press latches exactly once -- wait() auto-resets, as documented.')
        else:
            print('  WARNING: the second poll also returned true. The latch is not self-clearing, '
                  'or the key was pressed twice.')
    else:
        print('  NOT SEEN. If the key was pressed during the spin, this approach is dead and '
              'the decode cannot be cancelled from the front panel.')

    return report(verdict, d)


def report(verdict, d):
    """What a poll costs, what the event log says, and the verdict. -> exit status."""
    d.send('ck_cost(200, 0.001)')
    ln = wait_line(d, 'C ', 60)
    if ln is not None:
        secs, n, t = ln[2:].split('|')
        per = float(secs) / int(n)
        print('\npoll cost: %.2f ms each over %s polls at timeout %s s' % (per * 1e3, n, t))
        verdict['poll_ms'] = per * 1e3

    d.send('ck_events()')
    ln = wait_line(d, 'E ', 20) or 'E ?|'
    ec, emsg = (ln[2:].split('|') + [''])[:2]
    print('event log after all of it: %s entries %s' % (ec, emsg or ''))

    print('\n' + '=' * 78)
    good = verdict.get('busy_press') and verdict.get('returns')
    if good:
        armed = verdict.get('armed_blender') and not verdict.get('idle_press')
        print('VERDICT: the TRIGGER key CAN cancel a running decode. Poll '
              'trigger.blender[%d].wait(0.001) between windows; clear() before each run so the '
              'press that started it is not read as a cancel.' % BLENDER)
        if armed:
            print('         AND a dummy trigger model must be armed on EVENT_DISPLAY for the '
                  'duration, because the key only generates the event when something waits on it.')
    elif verdict.get('armed_model') and not verdict.get('armed_blender'):
        print('VERDICT: the key works but does not reach a blender. Use trigger.model.state() as '
              'the detector instead -- a looping WAIT block, polled for its block number.')
    else:
        print('VERDICT: no cancel mechanism yet. Do not ship an unbounded in-handler loop.')
    print('=' * 78)
    return 0 if good else 1


if __name__ == '__main__':
    sys.exit(main())

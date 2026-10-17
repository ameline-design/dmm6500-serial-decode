#!/usr/bin/env python3
"""The claims docs/TRIGGER.md states without a measurement -- measured.

Five of them, four of which the manual names NOT ESTABLISHED outright. Each case is paired with a
control, because every one of these questions has an answer that looks the same as "nothing happened":
a model sitting in WAITING proves nothing unless the same model fires when it should.

    1  EVENT_EXTERNAL as the FIRST block         marker ON must fire, marker OFF must sit
    2  a FINISHED counted pre-roll ahead of a    does the comparator evaluate once the
       WAIT on EVENT_ANALOGTRIGGER               counted block has stopped?
    3  STATE_ABORTING observable                 poll in the tightest loop after abort()
    4  STATE_PAUSED observable                   pause() a RUNNING model -- the manual
                                                 only ever refused one that was not
    5  WHY a host-side watch kills a parked      clean room: no app loaded, ONE socket
       model

Cases 1 and 2 are docs/TRIGGER.md, 'Pre-trigger, and what the comparator needs'; 3 and 4 are 'The
machine'; 5 is 'Poll from inside the instrument'. Headings rather than numbers, because a number
redirects silently when the document is reordered and a name fails visibly.

CASE 5 IS THE ONE WITH A CONFOUND TO REMOVE, so it runs first and wants a freshly started instrument:
the original measurement had a second client holding a socket throughout, so "no traffic from the
measuring socket" could not separate the host's own readback from something periodic in the app. With
nothing loaded and one connection, a death at ~430 ms indicts the readback and survival indicts the app.

THREE THINGS THIS FIRMWARE DOES THAT COST A RUN, all three from its own event log:

  * `buffer.STYLE_COMPACT` IS NIL on 1.7.17a. buffer.make() then takes nil as a style and raises
    1138, every block built on the result fails 2703, and the model reaches STATE_FAILED. The app uses
    buffer.STYLE_STANDARD and so does this.
  * `trigger.model.state()` RETURNS FIVE VALUES AND THE FIRST IS USERDATA, not a string. It concatenates
    and prints as `trigger.STATE_WAITING`, which is what makes string.find() on it look reasonable --
    it raises -286 'string expected, got userdata'. Compare with == against trigger.STATE_*.
  * A QUERY WHOSE STATEMENT RAISES PRINTS NOTHING, so the host blocks for its whole socket timeout.
    One nil buffer cost 8 minutes of bench time at 0 % CPU. Every statement here prints on both paths,
    and the host poll runs on a short-timeout connection so silence is DATA rather than a hang.

EVENT_DISPLAY as a first block is NOT here: it needs the front-panel TRIGGER key, the HTTP panel path
is denied by policy, and there is no programmatic source for that event.

WIRING: SDG CH1 -> DMM front terminals (the signal), SDG CH2 -> DMM rear TRIGGER IN (the marker), as
bench_trigin.py describes. CH1 is driven as a built-in 1 kHz 0-3 V square rather than an arb, to match
the control the manual's own comparator measurements used.

    python3 tools/bench_trigclaims.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM              # noqa: E402
from siglent import SDG             # noqa: E402

# The parked wait's patience, whole seconds because the in-instrument loop bound is os.time().
PARK = 4

# Short enough that a statement which prints nothing is a measurement and not a wedge.
POLL_TIMEOUT = 8

# 200 000 readings is 5 s at 40 kS/s, so the buffer CANNOT fill inside the poll window.
#
# This is a confound, not a convenience. A 20 000-reading buffer was full at the first query of the
# first attempt, and the manual's own numbers for the thing being measured here -- deaths at 17 654,
# 17 442 and 17 104 readings -- are close enough to a small capacity that "the model died" and "the
# buffer stopped accepting" would read identically. The original run reached 39 400 readings from
# inside, so capacity has to clear that too.
CAP = 200000

PRELUDE = """
local function st_now()
  local ok, s = pcall(trigger.model.state)
  if not ok then return nil end
  return s
end
local function running(s)
  return s == trigger.STATE_WAITING or s == trigger.STATE_RUNNING
end
"""

# ABORT BEFORE ANYTHING ELSE, and that ordering is the whole preamble.
#
# A model left RUNNING by the previous case makes this firmware refuse both the store and the
# digitizer: `load()` has nothing to do with a running program and `dmm.digitize.func = ...` posts
# 2727, 'Command prohibited while trigger model is running' -- which docs/TRIGGER.md, 'Nothing under
# `trigger.` reports failure', establishes as an OUT OF BAND refusal, pcall true and the write
# dropped. Building on top of that raises mid-chunk, the chunk dies before its print, and the host
# then waits out its whole socket timeout on a statement that will never answer. Two runs were lost
# that way before the abort moved up.
SETUP = """
pcall(function() trigger.model.abort() end)
delay(0.05)
do
  local ok, s = pcall(trigger.model.state)
  if ok and (s == trigger.STATE_RUNNING or s == trigger.STATE_WAITING) then
    print('TCWARN model still ' .. tostring(s) .. ' after abort()')
  end
end
dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.samplerate = 40000
dmm.digitize.count = 1
pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
-- A GLOBAL SURVIVES BETWEEN CHUNKS, so a buffer made by an earlier run of this tool is still here --
-- at ITS capacity, not this one's. Reusing it silently saturated the reading count at 20 000 and made
-- the inside control incomparable with the 39 400 readings the manual quotes. Deleted before being
-- dropped, because assigning nil over the handle strands the readings instead of freeing them.
if TCBUF ~= nil then
  local cok, cap = pcall(function() return TCBUF.capacity end)
  if (not cok) or cap ~= TCCAP then
    pcall(function() buffer.delete(TCBUF) end)
    TCBUF = nil
  end
end
if TCBUF == nil then
  local mok, nb = pcall(buffer.make, TCCAP, buffer.STYLE_STANDARD)
  if mok then TCBUF = nb end
end
if TCBUF == nil then print('TC0 FATAL buffer.make refused') end
pcall(function() TCBUF.clear() end)
pcall(function() trigger.model.load('Empty') end)
"""

# COUNT_INFINITE ahead of the wait because docs/TRIGGER.md, 'Pre-trigger, and what the comparator
# needs', establishes that the infinite digitize is what keeps samples flowing and the downstream
# wait is what lets it run at all.
PARKED_MODEL = SETUP + """
trigger.model.setblock(1, trigger.BLOCK_BUFFER_CLEAR, TCBUF)
trigger.model.setblock(2, trigger.BLOCK_MEASURE_DIGITIZE, TCBUF, trigger.COUNT_INFINITE)
trigger.model.setblock(3, trigger.BLOCK_WAIT, trigger.EVENT_EXTERNAL)
trigger.model.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, TCBUF, 100)
trigger.model.initiate()
"""

CLEANUP = """
pcall(function() trigger.model.abort() end)
pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
pcall(function() trigger.blender[1].reset() end)
pcall(function() trigger.model.load('Empty') end)
print('TCCLEAN ' .. tostring(trigger.model.state()))
"""

# Always prints, on both paths, so the host can never be left waiting on a raise.
POLL_STMT = ("local ok, s = pcall(trigger.model.state) "
             "local n = -1 pcall(function() n = TCBUF.n end) "
             "if ok then print(tostring(s) .. ',' .. tostring(n)) "
             "else print('RAISED,' .. tostring(n)) end")


def run(d, body, timeout=40):
    out = d.load_script('tclaim', body.replace('TCCAP', str(CAP)), run=True, timeout=timeout)
    lines = [str(l).strip() for l in out if str(l).strip()]
    tagged = [l for l in lines if l.startswith('TC')]
    for l in tagged:
        print('    ' + l)
    if not tagged:
        print('    RAW %r' % (lines[:6],))
    return ' | '.join(tagged)


def case_host_watch(d):
    """Does a HOST-SIDE poll kill a parked model with no app loaded and one socket open?"""
    print('  [5] why a host-side watch kills a parked wait -- clean room')
    print('    loaded state (sdec,brun): %s'
          % str(d.q('print(tostring(sdec) .. "," .. tostring(brun))')).strip())

    run(d, PRELUDE + PARKED_MODEL + "print('TC5 armed=' .. tostring(st_now()))", timeout=60)

    # BOUNDED IN TIME, NOT IN QUERIES. A 300-query cap ran out after 0.477 s, which only just clears
    # the 427-441 ms window the deaths were measured in -- so it could not tell "survived" from
    # "stopped asking". The queries are continuous for PARK seconds, an order of magnitude past it.
    t0 = time.time()
    hist = []
    while time.time() - t0 < PARK:
        try:
            st = str(d.q(POLL_STMT)).strip()
        except Exception as e:
            st = 'NOREPLY(%s)' % type(e).__name__
        el = time.time() - t0
        hist.append((el, st))
        if 'WAITING' not in st.upper() or st.startswith('NOREPLY'):
            break
    last = hist[-1] if hist else (0.0, '?')
    print('    TC5 host-poll: %d queries over %.3f s, final %s' % (len(hist), last[0], last[1]))
    for i in (0, 1, 2):
        if len(hist) > i:
            print('    TC5   q%d %.3f s  %s' % (i + 1, hist[i][0], hist[i][1]))
    died = ('WAITING' not in last[1].upper()) or last[1].startswith('NOREPLY')

    inside = run(d, PRELUDE + PARKED_MODEL + """
local t0 = os.time()
local seen, nmax = '', 0
local st = st_now()
while os.time() - t0 < %d do
  st = st_now()
  local n = TCBUF.n
  if n > nmax then nmax = n end
  local nm = tostring(st)
  if string.find(seen, nm, 1, true) == nil then seen = seen .. nm .. ' ' end
  if not running(st) then break end
end
print(string.format('TC5 inside: %%d s states=[%%s] readings=%%d final=%%s',
                    os.time() - t0, seen, nmax, tostring(st)))
""" % PARK)
    run(d, CLEANUP, timeout=30)
    return died, inside, len(hist), last


def case_external_first(d, g):
    """Is a WAIT on EVENT_EXTERNAL as block 1 satisfiable with nothing sampling ahead of it?"""
    print('  [1] EVENT_EXTERNAL as the FIRST block')
    body = PRELUDE + SETUP + """
trigger.model.setblock(1, trigger.BLOCK_WAIT, trigger.EVENT_EXTERNAL)
trigger.model.setblock(2, trigger.BLOCK_BUFFER_CLEAR, TCBUF)
trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, TCBUF, 100)
pcall(function() trigger.extin.clear() end)
trigger.model.initiate()
local t0 = os.time()
local st = st_now()
while os.time() - t0 < %d do
  st = st_now()
  if not running(st) then break end
end
print(string.format('TCLBL secs=%%d state=%%s readings=%%d', os.time() - t0, tostring(st), TCBUF.n))
""" % PARK

    g.write('C2:OUTP OFF')
    off = run(d, body.replace('TCLBL', 'TC1off'))
    run(d, CLEANUP, timeout=30)

    g.write('C2:OUTP ON,LOAD,HZ')
    on = run(d, body.replace('TCLBL', 'TC1on'))
    g.write('C2:OUTP OFF')
    run(d, CLEANUP, timeout=30)
    return off, on


def case_finished_preroll(d):
    """A counted pre-roll that has STOPPED, then a WAIT on the comparator. Does it still fire?

    The manual already publishes two thirds of this: a bare wait never fires, and the same wait behind
    a COUNT_INFINITE block fires in under 0.01 s. This asks the remaining third.
    """
    print('  [2] a FINISHED counted pre-roll ahead of WAIT(EVENT_ANALOGTRIGGER)')
    body = PRELUDE + SETUP + """
dmm.digitize.analogtrigger.mode = dmm.MODE_EDGE
dmm.digitize.analogtrigger.edge.level = 1.5
dmm.digitize.analogtrigger.edge.slope = dmm.SLOPE_RISING
trigger.model.setblock(1, trigger.BLOCK_BUFFER_CLEAR, TCBUF)
trigger.model.setblock(2, trigger.BLOCK_MEASURE_DIGITIZE, TCBUF, NPRE)
trigger.model.setblock(3, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)
trigger.model.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, TCBUF, 100)
trigger.model.initiate()
local t0 = os.time()
local st = st_now()
while os.time() - t0 < %d do
  st = st_now()
  if not running(st) then break end
end
print(string.format('TCLBL secs=%%d state=%%s readings=%%d', os.time() - t0, tostring(st), TCBUF.n))
""" % PARK

    # 100 samples at 40 kS/s is 2.5 ms of pre-roll: finished long before the wait block is reached.
    fin = run(d, body.replace('NPRE', '100').replace('TCLBL', 'TC2fin'))
    run(d, CLEANUP, timeout=30)
    inf = run(d, body.replace('NPRE', 'trigger.COUNT_INFINITE').replace('TCLBL', 'TC2inf'))
    run(d, CLEANUP, timeout=30)

    # THE MECHANISM, because "it fired" has two readings and they differ in what you may conclude.
    #
    # 100 samples at 40 kS/s spans 2.5 ms of a 1 kHz square, so a rising edge through 1.5 V certainly
    # occurred DURING the pre-roll. The wait may therefore be consuming an event latched while the
    # block ran, rather than the comparator evaluating after it stopped -- and only the second would
    # mean the acquisition need not be live. WAIT's own clear parameter separates them: entering with
    # the event detector cleared throws away anything latched, so if it still fires the comparator is
    # live, and if it now sits for ever the pre-roll's latch was the whole answer.
    latch = run(d, body.replace('NPRE', '100').replace('TCLBL', 'TC2clr').replace(
        'trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)',
        'trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER, trigger.CLEAR_ENTER)'))
    run(d, CLEANUP, timeout=30)
    return fin, inf, latch


def case_unseen_states(d):
    """STATE_ABORTING and STATE_PAUSED: does the constant exist, and can the state be caught?"""
    print('  [3][4] STATE_ABORTING and STATE_PAUSED')
    # The arity goes here because it is the reason a string test on the state raises: state() hands
    # back several values and the first is userdata that merely PRINTS as its own constant's name.
    names = run(d, """
print(string.format('TC34 constants aborting=%s paused=%s', tostring(trigger.STATE_ABORTING),
                    tostring(trigger.STATE_PAUSED)))
do
  local a, b, c, e, f, g = trigger.model.state()
  print(string.format('TC34 state() -> %s | %s | %s | %s | %s | %s',
                      tostring(a), tostring(b), tostring(c), tostring(e), tostring(f), tostring(g)))
  print(string.format('TC34 first value type=%s equals_constant=%s',
                      type(a), tostring(a == trigger.STATE_EMPTY or a == trigger.STATE_IDLE)))
end
""")
    aborting = run(d, PRELUDE + PARKED_MODEL + """
local s = {}
trigger.model.abort()
for i = 1, 200 do s[i] = tostring(st_now()) end
local seen = ''
for i = 1, 200 do
  if string.find(seen, s[i], 1, true) == nil then seen = seen .. s[i] .. ' ' end
end
print('TC3 states sampled after abort(): ' .. seen)
""")
    paused = run(d, PRELUDE + PARKED_MODEL + """
local before = tostring(st_now())
local ok, err = pcall(function() trigger.model.pause() end)
local after = tostring(st_now())
local ok2 = pcall(function() trigger.model.resume() end)
local after2 = tostring(st_now())
print(string.format('TC4 before=%s pause_ok=%s err=%s after=%s resume_ok=%s then=%s',
                    before, tostring(ok), tostring(err), after, tostring(ok2), after2))
local n = 0
for i = 1, 6 do
  local ev, msg = eventlog.next()
  if ev == nil or ev == 0 then break end
  print(string.format('TC4 event %s %s', tostring(ev), tostring(msg)))
  n = n + 1
end
if n == 0 then print('TC4 event log empty') end
""")
    run(d, CLEANUP, timeout=30)
    return names, aborting, paused


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='12345',
                    help='case digits to run, e.g. --only 2 for the pre-roll question alone')
    a = ap.parse_args()

    g = d = None
    died = inside = nq = None
    last = (0.0, 'not run')
    off = on = fin = inf = latch = names = aborting = paused = ''
    try:
        d = DMM(timeout=POLL_TIMEOUT)
        print('DMM:', str(d.q('*IDN?')).strip())
        g = SDG()
        print('SDG:', g.idn())
        g.write('C2:CMBN OFF')
        g.write('C2:BSWV WVTP,PULSE,FRQ,100,AMP,5,OFST,2.5,WIDTH,5e-05,RISE,1e-07,FALL,1e-07')
        g.write('C2:OUTP OFF')
        g.write('C1:BSWV WVTP,SQUARE,FRQ,1000,AMP,3,OFST,1.5,DUTY,50')
        g.write('C1:OUTP ON,LOAD,HZ')
        print()

        if '5' in a.only:
            died, inside, nq, last = case_host_watch(d)
            print()
        if '1' in a.only:
            off, on = case_external_first(d, g)
            print()
        if '2' in a.only:
            fin, inf, latch = case_finished_preroll(d)
            print()
        if '3' in a.only or '4' in a.only:
            names, aborting, paused = case_unseen_states(d)

        print()
        print('=== verdicts ===')
        ext_ok = ('readings=100' in on) or ('STATE_IDLE' in on.upper())
        # THE CONTROL IS READINGS=0 AND A FULL WINDOW, not the word WAITING. With the wait as block 1
        # this firmware reports STATE_RUNNING while parked on it, so a state test called a passing
        # control a failure and printed "case 1 proves nothing" under a result that was clean.
        ext_ctl = ('readings=0' in off) and ('secs=%d' % PARK in off)
        fin_ok = 'STATE_IDLE' in fin.upper()
        inf_ok = 'STATE_IDLE' in inf.upper()
        latch_fired = 'STATE_IDLE' in latch.upper()
        print('  [1] EVENT_EXTERNAL as block 1 fires on a marker  : %s'
              % ('YES' if ext_ok else 'NO'))
        print('      control -- no marker: sat, nothing sampled   : %s'
              % ('YES' if ext_ctl else 'NO, so case 1 proves nothing'))
        print('  [2] a FINISHED counted pre-roll satisfies it     : %s'
              % ('YES' if fin_ok else 'NO -- the acquisition must be live'))
        print('      control -- COUNT_INFINITE ahead of the wait  : %s'
              % ('YES' if inf_ok else 'NO, so case 2 proves nothing'))
        print('      mechanism -- same model, CLEAR_ENTER on wait : %s'
              % ('fires anyway, so the comparator is LIVE' if latch_fired
                 else 'sits, so case 2 is a LATCH from the pre-roll'))
        print('  [3] STATE_ABORTING ever observed                 : %s'
              % ('YES' if 'ABORTING' in aborting.upper() else 'NO'))
        print('  [4] STATE_PAUSED ever observed                   : %s'
              % ('YES' if 'PAUSED' in paused.upper() else 'NO'))
        if nq is None:
            print('  [5] not run')
        else:
            print('  [5] a host poll kills a parked model with NO app : %s'
                  % ('YES -- the readback itself is the killer' if died
                     else 'NO -- it survived, which indicts the app tick'))
            print('      %d queries, final %s' % (nq, last[1]))
        print()
        print('  constants     : %s' % names)
        print('  inside control: %s' % inside)
    finally:
        for h in (d, g):
            try:
                if h is not None:
                    h.close()
            except Exception:
                pass


if __name__ == '__main__':
    main()

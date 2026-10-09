#!/usr/bin/env python3
"""ARMING FROM SILENCE, on the instrument: press Capture before the device starts talking.

WHAT THIS DECIDES THAT NO OFFLINE TEST CAN. The feature's whole claim is about a moment in time --
the window opens on the device's FIRST start bit rather than on a buffer of silence -- and the thing
that makes it work is the instrument's analog comparator feeding a trigger model whose pre-trigger
phase is running. The mock reproduces the shape of that; it cannot reproduce the comparator.

THE STIMULUS IS THE GENERATOR'S OUTPUT SWITCH. Output off leaves the front terminals at ground with
nothing on them, which is exactly what a DUT that has not been powered up looks like -- an idle level
under sdec.minswing, so the level probe refuses it and the capture arms instead of recording it.
Switching the output on, from a thread, is the device starting to transmit.

SEVEN CASES, and the first is the one that was BROKEN at V1.40:

  A  Baud Rate 0 (the DEFAULT), silent line     -- must ARM and wait, not return in 3.5 s
  B  Baud Rate 0, generator on mid-wait         -- must fire early and decode from the first byte
  C  Baud Rate LOCKED, silent line              -- the pre-existing path, unchanged
  D  a line idling HIGH at 3.3 V, then traffic  -- Arm At on the side the start bit travels
  E  the arm EXPIRES                            -- names the two settings, and the armed level
  F  an 8 kB RECORDING armed on silence         -- the canned waiting template, not SimpleLoop
  G  a recording whose arm expires              -- its own ending, not 'full' and not 'quiet'

A IS THE REGRESSION TEST. Measured at V1.40: with the rate automatic a press on a silent line
returned in 3.55 s saying 'line is idle (no transitions)' and never armed, while the identical press
with the rate LOCKED armed and waited the full 10 s. autoset() ran its probe ladder with trigmode
forced to 'free', found no baud rate, and returned before the real capture.

    python3 tools/bench_arm.py                  # load the app, run every case
    python3 tools/bench_arm.py --no-load        # the app is already loaded and built
    python3 tools/bench_arm.py --only A,B       # one case at a time
"""
import argparse
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
import vector_names as VN
from siglent import SDG
import run_app

BAUD = 9600
SPB = 10                     # arb samples per bit, so SRATE is baud * SPB
ARMWAIT = 10.0
RESULTS = []


def tq(d, tag, expr, timeout=40):
    """One tagged read. Tagged because eight bare reads desynced by one and every value looked
    plausible -- the tag is what makes a desync an error instead of a wrong number."""
    s = str(d.q('print("%s|" .. tostring((function() local ok, r = pcall(function() return %s end) '
                'if not ok then return "RAISED:" .. tostring(r) end return r end)()))' % (tag, expr),
                timeout=timeout) or '')
    k = '%s|' % tag
    if k not in s:
        raise RuntimeError('DESYNC asking %s: got %r' % (tag, s))
    return s.split(k, 1)[1].strip()


def check(name, cond, detail=''):
    RESULTS.append((name, bool(cond), detail))
    print('  %-4s %s%s' % ('PASS' if cond else 'FAIL', name, ('   ' + detail) if detail else ''))


def num(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def press(d, tag, timeout=240):
    """One Capture press through the REAL app path, timed on the host.

    THE DISCRIMINATOR IS ELAPSED TIME, not a stub: an arm that engages blocks for its wait, and a
    press that never armed returns in a second or two. Those two outcomes are seconds apart and need
    no instrumentation of the app."""
    d.exec('sdec.lasterr = nil sdec.probe_note = nil')
    t0 = time.time()
    res = tq(d, tag, '(function() local ok, why = pcall(sdec.capture) '
                     'return tostring(ok) .. " / " .. tostring(why) end)()', timeout=timeout)
    el = time.time() - t0
    # hw_config re-arms showevents, and an unsolicited event line desyncs every later read.
    d.exec('localnode.showevents = 0')
    return el, res


def start_later(g, delay_s, hit, how):
    """The device starts transmitting after delay_s. In a THREAD, so the session is never blocked."""
    def body():
        time.sleep(delay_s)
        try:
            how(g)
            hit['on'] = time.time()
        except Exception as e:                        # noqa: BLE001 -- reported, not raised
            hit['err'] = str(e)
    th = threading.Thread(target=body, daemon=True)
    th.start()
    return th


def arb_on(g):
    g.output(True, ch=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--no-load', action='store_true', help='the app is already loaded and built')
    ap.add_argument('--only', default='', help='comma-separated case letters')
    ap.add_argument('--baud', type=int, default=BAUD)
    a = ap.parse_args()
    only = [c.strip().upper() for c in a.only.split(',') if c.strip()]

    def want(c):
        return not only or c in only

    g = SDG()
    print('SDG : %s' % g.idn())
    # THE VECTOR IS A REAL 8N1 WAVEFORM, not a square wave: a square wave has no start bits, so a
    # capture of one reports 'no frame format fits' and says nothing about whether the bytes at the
    # beginning survived -- which is the whole question here.
    g.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)
    g.output(False, ch=1)
    print('arb : v41 at %d baud (SRATE %d), output OFF -- a device that has not started' %
          (a.baud, a.baud * SPB))

    d = DMM()
    if not a.no_load:
        print(d.q('print(localnode.model, localnode.version)'))
        run_app.load_app(d)
        print(d.q('local ok, why = sdec.start() print(string.format("START %s %s", tostring(ok), '
                  'tostring(why)))', timeout=120))
    built = tq(d, 'B', 'tostring(sdec ~= nil and sdec.built == true)')
    print('app : built=%s   fw %s   terminals %s' %
          (built, tq(d, 'F', 'localnode.version'), tq(d, 'T', 'dmm.terminals')))
    if built != 'true':
        print('REFUSING: the app is not loaded and built. Drop --no-load, or run tools/run_app.py.')
        return 2
    d.exec('localnode.showevents = 0')
    print('arm : fs=%s Hz  arm_baud=%s  try=%s' %
          (tq(d, 'AF', 'sdec.arm_fs()'), tq(d, 'AB', 'sdec.arm_baud'),
           tq(d, 'AT', 'table.concat(sdec.arm_try, ",")')))

    try:
        d.exec('sdec.trigmode = "edge" sdec.trigext = false sdec.trigext_only = false '
               'sdec.fc_out = false sdec.armkey = true sdec.capmode = "frame"')
        d.exec('sdec.armlevel = 1.0 sdec.armwait = %g' % ARMWAIT)

        # ---- A: the regression. Rate automatic, silent line: it must ARM. ----
        if want('A'):
            print('\n=== A: silent line, Baud Rate 0 (THE DEFAULT) ===')
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil')
            el, res = press(d, 'A')
            err = tq(d, 'Ae', 'sdec.lasterr')
            fs = tq(d, 'Af', 'sdec.fs')
            note = tq(d, 'An', 'sdec.probe_note')
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  lasterr: %s' % err)
            print('  fs=%s  note=%s' % (fs, note))
            check('A the default configuration ARMS on a silent line', el >= ARMWAIT * 0.7,
                  '%.2f s against an Arm Wait of %g (V1.40: 3.55 s, never armed)' % (el, ARMWAIT))
            check('A ...at the blind rate rather than the top of the probe ladder',
                  num(fs) == num(tq(d, 'Af2', 'sdec.arm_fs()')),
                  'fs=%s, arm_fs=%s' % (fs, tq(d, 'Af3', 'sdec.arm_fs()')))
            check('A ...and the panel says what it did and what beats it',
                  'lock the baud rate' in note, note[:90])

        # ---- B: THE WORKFLOW. Rate automatic, device starts mid-wait. ----
        if want('B'):
            print('\n=== B: THE WORKFLOW -- silent at the press, transmitting 3 s later ===')
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil')
            hit = {}
            t0 = time.time()
            th = start_later(g, 3.0, hit, arb_on)
            el, res = press(d, 'B')
            th.join(timeout=1)
            baud = tq(d, 'Bb', 'sdec.baud')
            nread = tq(d, 'Bn', 'sdec.nread')
            nf = tq(d, 'Bf', 'sdec.res ~= nil and sdec.res.nf or -1')
            nbad = tq(d, 'Bx', 'sdec.res ~= nil and sdec.res.nbad or -1')
            txt = tq(d, 'Bt', 'sdec.res ~= nil and sdec.ua_text_line(1, 40) or "-"')
            fs = tq(d, 'Bfs', 'sdec.fs')
            # HOW MUCH QUIET LINE CAME BACK AHEAD OF THE SIGNAL, which is what the pre-trigger
            # reserve is FOR: the window has to open before the first start bit or the first byte is
            # a fragment. Counted on the instrument over the Lua copy, |v| < 1 V being quiet for a
            # 10 Vpp stimulus. The reserve is 5 % of capacity -- about 1055 samples at 21 100 -- and
            # it has been filling since initiate(), so a fired arm should come back with most of it.
            lead = tq(d, 'Bl', '(function() local n, i = sdec.nread, 1 '
                               'while i <= n and math.abs(sdec.smp[i]) < 1.0 do i = i + 1 end '
                               'return i - 1 end)()')
            print('  generator on at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  baud=%s fs=%s nread=%s bytes=%s bad=%s' % (baud, fs, nread, nf, nbad))
            print('  text: %s' % txt)
            check('B the arm fired when the line started, before the wait ran out',
                  2.0 < el < ARMWAIT * 0.95, 'returned at %.2f s, generator on at +3.0 s' % el)
            # ONE BAD FRAME IS THE STIMULUS, NOT THE APP, and the allowance is bounded rather than
            # waived: the generator's output switch opens wherever the arb happens to be, so the
            # frame it opens in the middle of is a fragment by construction. A device powering up
            # does not do that -- it starts at a start bit -- but nothing on this bench can emulate
            # one. Two or more bad frames would be a decode fault and still fails.
            check('B ...and the capture decoded real bytes',
                  num(nf, -1) > 20 and num(nbad, 99) <= 1,
                  '%s bytes, %s bad (<=1: the output switch opens mid-frame)' % (nf, nbad))
            check('B ...at the rate on the wire', abs(num(baud, 0) - a.baud) < a.baud * 0.02,
                  'baud=%s against %d on the generator' % (baud, a.baud))
            check('B ...and the window is the one the blind rate chose',
                  num(nread, 0) > 19000, 'nread=%s' % nread)
            check('B ...and it holds the vector\'s own text, so the bytes are the line\'s',
                  'Hello' in txt, txt[:50])
            # THE REQUIREMENT, IN ONE NUMBER: the record begins in the quiet line, so no edge of the
            # device's first byte is outside the window.
            print('  leading quiet samples: %s (reserve is ~%s)' %
                  (lead, tq(d, 'Br', 'math.floor(sdec.acq_cap(sdec.n) * sdec.pretrig / 100)')))
            check('B ...opening BEFORE the signal started, not on its first edge',
                  num(lead, 0) >= 50, 'leading quiet samples = %s' % lead)

        # ---- C: the locked-rate path, which worked at V1.40 and must still. ----
        if want('C'):
            print('\n=== C: silent line, Baud Rate LOCKED ===')
            g.output(False, ch=1)
            d.exec('sdec.force_baud = %d' % a.baud)
            el, res = press(d, 'C')
            err = tq(d, 'Ce', 'sdec.lasterr')
            print('  elapsed %.2f s   lasterr: %s' % (el, err))
            check('C a locked rate still arms and waits', el >= ARMWAIT * 0.7,
                  '%.2f s against an Arm Wait of %g' % (el, ARMWAIT))
            check('C ...and the expiry names the two settings and the armed level',
                  'raise Arm Wait or lower Arm At' in err and 'crossed' in err, err[:110])
            d.exec('sdec.force_baud = nil')

        # ---- D: a line idling HIGH, which is every normal TTL UART. ----
        if want('D'):
            print('\n=== D: a line idling HIGH at 3.3 V, then traffic ===')
            # A DC WAVEFORM IS THE ONLY WAY TO HOLD A QUIET LINE AWAY FROM GROUND: switching the
            # output off leaves the terminals at ground, which is the other branch. The generator is
            # put back on the arb afterwards by the restore block.
            g.output(False, ch=1)
            g.write('C1:BSWV WVTP,DC,OFST,3.3')
            g.output(True, ch=1)
            time.sleep(0.5)
            d.exec('sdec.force_baud = nil sdec.armlevel = 1.0')
            hit = {}
            t0 = time.time()

            def to_arb(gg):
                gg.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)

            th = start_later(g, 3.0, hit, to_arb)
            el, res = press(d, 'D')
            th.join(timeout=20)
            thr = tq(d, 'Dthr', 'dmm.digitize.analogtrigger.edge.level')
            slope = tq(d, 'Dsl', 'tostring(dmm.digitize.analogtrigger.edge.slope)')
            nf = tq(d, 'Df', 'sdec.res ~= nil and sdec.res.nf or -1')
            err = tq(d, 'De', 'sdec.lasterr')
            print('  generator switched to the arb at +%.2f s%s' %
                  (hit.get('on', t0) - t0, (' ERR ' + hit['err']) if 'err' in hit else ''))
            print('  elapsed %.2f s  comparator level=%s slope=%s  bytes=%s' %
                  (el, thr, slope, nf))
            print('  lasterr: %s' % err)
            # 3.3 V idle less a 1 V Arm At is 2.3 V, and the start bit travels DOWN from idle.
            check('D the comparator armed one Arm At below a 3.3 V idle, not at its midpoint',
                  num(thr) is not None and abs(num(thr, 0) - 2.3) < 0.35,
                  'level=%s, want 2.30 (midpoint would be 1.65)' % thr)
            check('D ...and on the falling edge the start bit takes', 'fall' in slope.lower(),
                  'slope=%s' % slope)
            # NO DECODE ASSERTION HERE, and the reason is the generator rather than the app. Moving
            # from DC to the arb is not a switch: select_arb reselects the waveform, rewrites AMP and
            # OFST, sets TrueArb and verifies it, so the line during this window is a transition and
            # not a UART signal -- measured, the capture fitted a 175.7 sample bit time, which is
            # 1138 Bd at 200 kS/s. What this case exists to prove is WHERE THE COMPARATOR ARMED on a
            # line idling away from ground, and the two assertions above prove exactly that. The
            # decode on an idle-high line is covered by hw-matrix, which drives one properly.
            check('D ...and the arm fired at the transition rather than timing out',
                  el < ARMWAIT * 0.95, 'returned at %.2f s against an Arm Wait of %g' % (el, ARMWAIT))
            g.output(False, ch=1)
            g.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)

        # ---- E: the arm expires, with the rate automatic. ----
        if want('E'):
            print('\n=== E: the arm expires ===')
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.armwait = 3.0 sdec.armlevel = 1.0')
            el, res = press(d, 'E')
            err = tq(d, 'Ee', 'sdec.lasterr')
            print('  elapsed %.2f s   lasterr: %s' % (el, err))
            check('E an expired arm waits the operator\'s Arm Wait and no longer',
                  2.0 <= el <= 12.0, '%.2f s at an Arm Wait of 3' % el)
            check('E ...and says what did not happen, naming the level and both settings',
                  'crossed' in err and 'raise Arm Wait or lower Arm At' in err, err[:110])
            d.exec('sdec.armwait = %g' % ARMWAIT)

        # ---- F: an 8 kB RECORDING armed on silence. ----
        if want('F'):
            print('\n=== F: an 8 kB recording armed on silence, device starts at +3 s ===')
            # A RECORDING NEEDS A LOCKED RATE -- it sizes its buffer from it -- so this case tests the
            # armed recording, not the blind rate.
            g.output(False, ch=1)
            time.sleep(1.5)                           # the absorb window, as in G below
            # A CHUNKED JOB LEFT OPEN MAKES THE NEXT PRESS CONTINUE IT rather than start a recording,
            # which is a three-way dispatch in capture_run() and not something a test should inherit.
            d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil')
            d.exec('sdec.capmode = "sml" sdec.force_baud = %d sdec.armwait = %g' % (a.baud, ARMWAIT))
            hit = {}
            t0 = time.time()
            th = start_later(g, 3.0, hit, arb_on)
            el, res = press(d, 'F', timeout=600)
            th.join(timeout=1)
            endwhy = tq(d, 'Fw', 'sdec.ck_endwhy')
            armed = tq(d, 'Fa', 'tostring(sdec.strm_armed)')
            nb = tq(d, 'Fb', 'sdec.ck_nbytes')
            nread = tq(d, 'Fn', 'sdec.nread')
            err = tq(d, 'Fe', 'sdec.lasterr')
            print('  generator on at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  endwhy=%s armed=%s bytes=%s nread=%s' % (endwhy, armed, nb, nread))
            print('  lasterr: %s' % err)
            check('F the press was not swallowed by the absorb window', el > 1.0,
                  'returned in %.2f s' % el)
            check('F the recording ARMED rather than recording the silence', armed == 'true',
                  'strm_armed=%s' % armed)
            check('F ...and it waited for the device rather than ending on its own clock',
                  el > 3.0 and endwhy != 'noarm', 'elapsed %.2f s, endwhy=%s' % (el, endwhy))
            check('F ...and collected bytes from the line', num(nb, 0) > 20, '%s bytes' % nb)

        # ---- G: a recording whose arm expires. ----
        if want('G'):
            print('\n=== G: a recording whose arm expires ===')
            # WAIT OUT THE ABSORB WINDOW FIRST. A Capture press within sdec.strm_absorb_s of a
            # recording ending is taken as the Stop press for that recording and returns immediately
            # -- by design, because a press aimed at stopping a stream is only dispatched once the
            # run's Lua has returned. Measured: without this the case returned in 0.01 s carrying
            # case F's ending, and read as a defect in the arm.
            time.sleep(1.5)
            g.output(False, ch=1)
            d.exec('sdec.capmode = "sml" sdec.force_baud = %d sdec.armwait = 3.0' % a.baud)
            el, res = press(d, 'G', timeout=600)
            endwhy = tq(d, 'Gw', 'sdec.ck_endwhy')
            why = tq(d, 'Gy', 'sdec.strm_exit_why(sdec.ck_endwhy, true, nil)')
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  endwhy=%s  note=%s' % (endwhy, why))
            check('G the press was not swallowed by the absorb window', el > 1.0,
                  'returned in %.2f s -- under a second means absorbed, not armed' % el)
            check('G an expired recording arm has its own ending, not full and not quiet',
                  endwhy == 'noarm', 'endwhy=%s' % endwhy)
            check('G ...and the note names the two settings that govern the wait',
                  'raise Arm Wait or lower Arm At' in why, why[:110])

    finally:
        print('\n=== restore ===')
        # LEFTOVER APP STATE POISONS THE NEXT TOOL, and capmode is the one that costs a diagnosis:
        # a recording mode left set makes the next tool's Capture press record for half a minute.
        try:
            g.output(False, ch=1)
            g.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)
        except Exception as e:                        # noqa: BLE001
            print('  SDG restore failed: %s' % e)
        d.exec('sdec.capmode = "frame" sdec.force_baud = nil sdec.autolock_set = nil')
        d.exec('sdec.armwait = 10.0 sdec.armlevel = 1.0 sdec.armkey = true')
        d.exec('pcall(trigger.model.abort)')
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        print('  capmode=%s force_baud=%s armwait=%s errcount=%s' %
              (tq(d, 'Z1', 'sdec.capmode'), tq(d, 'Z2', 'sdec.force_baud'),
               tq(d, 'Z3', 'sdec.armwait'), tq(d, 'Z4', 'sdec.errcount')))
        ev = tq(d, 'Z5', 'eventlog.getcount(eventlog.SEV_ALL)')
        print('  events pending=%s' % ev)
        if num(ev, 0) > 0:
            for _ in range(min(int(num(ev, 0)), 8)):
                print('   %s' % tq(d, 'Z6',
                      '(function() local c, m = eventlog.next(eventlog.SEV_ALL) '
                      'return tostring(c) .. ", " .. tostring(m) end)()'))

    print()
    npass = len([1 for _, ok, _ in RESULTS if ok])
    print('==== %d passed, %d FAILED ====' % (npass, len(RESULTS) - npass))
    for name, ok, detail in RESULTS:
        if not ok:
            print('   FAILED: %s   %s' % (name, detail))
    return 0 if npass == len(RESULTS) else 1


if __name__ == '__main__':
    sys.exit(main())

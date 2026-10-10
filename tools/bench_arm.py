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

SIXTEEN CASES IN TWO HALVES. A-G are the feature's own claims, and the first of those is the one
that was BROKEN at V1.40. H-O are the hostile half: both settings at their limits, a sign reversal, a
leak between captures, a promise that has to be backed by instrument state, a rate the blind window
cannot resolve, and the largest recording the app offers -- which is the one whose buffer made the
arm a coin toss at the settle budget this feature shipped with.

  A  Baud Rate 0 (the DEFAULT), silent line     -- must ARM and wait, not return in 3.5 s
  B  Baud Rate 0, generator on mid-wait         -- must fire early and decode from the first byte
  C  Baud Rate LOCKED, silent line              -- the pre-existing path, unchanged
  D  a line idling HIGH at 3.3 V, then traffic  -- Arm At on the side the start bit travels
  E  the arm EXPIRES                            -- names the two settings, and the armed level
  F  an 8 kB RECORDING armed on silence         -- the canned waiting template, not SimpleLoop
  G  a recording whose arm expires              -- its own ending, not 'full' and not 'quiet'

  H  Arm At at its 0.33 V FLOOR                 -- must not fire on the digitizer's own noise
  I  Arm At at its 6 V CEILING                  -- the firmware must ADOPT the level, not refuse it
  J  Arm Wait at its 2 s FLOOR, device late     -- expires on its own clock, does not catch it
  K  the TRIGGER key's promise                  -- blender slot 3 must really hold the event
  L  an arm, then a BUSY line                   -- the guessed level must not outlive its capture
  M  a line idling at -5 V                      -- the other sign, where the start bit goes UP
  N  a 57 600 Bd device caught blind            -- must REFUSE, not publish 38 400
  O  the 32 kB recording, armed                 -- the largest buffer the settle budget must cover

A IS THE REGRESSION TEST. Measured at V1.40: with the rate automatic a press on a silent line
returned in 3.55 s saying 'line is idle (no transitions)' and never armed, while the identical press
with the rate LOCKED armed and waited the full 10 s. autoset() ran its probe ladder with trigmode
forced to 'free', found no baud rate, and returned before the real capture.

    python3 tools/bench_arm.py                  # load the app, run every case
    python3 tools/bench_arm.py --no-load        # the app is already loaded and built
    python3 tools/bench_arm.py --only A,B       # one case at a time
"""
import argparse
import math
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
CAPS = {}                    # buffer sizes one case measures and another case's claim is about


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


def clear_absorb(d):
    """Disarm the queued-press absorb, so the NEXT press is not taken as this run's Stop.

    A Capture press within sdec.strm_absorb_s of a recording ending is absorbed BY DESIGN, and the
    absorb's age lives only in the shared timer -- so a recording case leaves the next case's press
    liable to vanish and return in 0.01 s, which reads as a broken arm. Two cases waited out the
    window with a host-side sleep instead; this clears the state, which is both faster and honest
    about what it is doing."""
    d.exec('sdec.strm_stopped_by_press = nil sdec.strm_nabsorbed = 0 sdec.strm_absorbed = nil')


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
    # THE OPERATOR'S OWN SETTINGS, READ RATHER THAN ASSUMED, because the restore block used to write
    # the defaults back as literals -- so a run on an instrument configured at 2.5 V and 30 s handed
    # it back at 1 V and 10 s and called that a restore.
    entry_lvl = tq(d, 'E1', 'sdec.armlevel')
    entry_wait = tq(d, 'E2', 'sdec.armwait')
    print('ent : armlevel=%s armwait=%s   (restored on the way out)' % (entry_lvl, entry_wait))

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
            # a fragment. Counted on the instrument over the Lua copy, with |v| < 1 V as the test for
            # quiet.
            #
            # 1 V IS THE RIGHT TEST BECAUSE OF WHERE THE BAND SITS, not because the stimulus straddles
            # ground -- it does not. v41 occupies codewords 0..21626 of a 16-bit full scale, so on the
            # wire low = OFST and high = OFST + 0.330 * AMP, which makes AMP 10 Vpp at OFST 0 a
            # 0.00..3.30 V line idling POSITIVE. Its low level IS 0 V, so the switched-off line and the
            # space level coincide and the first sample above 1 V is the rise into the 3.30 V idle. On a
            # band lifted off ground -- a 1.8 V logic line at OFST 0.9, say -- this would count
            # something else. docs/VECTORS.md carries the mapping.
            #
            # The reserve is 5 % of capacity -- about 1055 samples at 21 100 -- and it has been filling
            # since initiate(), so a fired arm should come back with most of it.
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
            # STASHED FOR CASE O, which claims to record several times this much. A claim about two
            # cases has to be settled against both of their measurements, not against a literal.
            CAPS['F'] = num(tq(d, 'Fc', 'sdec.buf ~= nil and sdec.buf.capacity or nil'))
            CAPS['Fn'] = num(tq(d, 'Fs', 'sdec.strm_nsmp'))
            print('  generator on at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  endwhy=%s armed=%s bytes=%s nread=%s' % (endwhy, armed, nb, nread))
            print('  nsmp=%s buffer capacity=%s' % (CAPS['Fn'], CAPS['F']))
            print('  lasterr: %s' % err)
            check('F the press was not swallowed by the absorb window', el > 1.0,
                  'returned in %.2f s' % el)
            check('F the recording ARMED rather than recording the silence', armed == 'true',
                  'strm_armed=%s' % armed)
            check('F ...and it waited for the device rather than ending on its own clock',
                  el > 3.0 and endwhy != 'noarm', 'elapsed %.2f s, endwhy=%s' % (el, endwhy))
            check('F ...and collected bytes from the line', num(nb, 0) > 20, '%s bytes' % nb)
            # AND THAT THEY ARE THE RIGHT WAY UP, which a count cannot see. An armed recording took
            # its polarity prior from the pre-trigger reserve and returned 2110 of 5484 bytes bad
            # with the COUNT correct, so this case passed on it. The reserve is the wire before the
            # device started; see ck_prime_step.
            finv = tq(d, 'Fi', 'sdec.res ~= nil and tostring(sdec.res.invert) or "?"')
            fbad = tq(d, 'Fx', 'sdec.res ~= nil and sdec.res.nbad or -1')
            ftxt = tq(d, 'Ft', 'sdec.res ~= nil and sdec.ua_text_line(1, 30) or "-"')
            fidle = tq(d, 'Fd', 'sdec.idle')
            print('  invert=%s nbad=%s idle=%s text=%r' % (finv, fbad, fidle, ftxt[:34]))
            check('F ...the right way up, not an inverted reading of the reserve',
                  finv == 'false' and num(fidle, -1) == 1,
                  'invert=%s idle=%s' % (finv, fidle))
            check('F ...and they are the line\'s own bytes, nearly all of them clean',
                  'Hello' in ftxt and num(fbad, 1e9) <= num(nb, 0) * 0.02,
                  'nbad=%s of %s text=%r' % (fbad, nb, ftxt[:34]))

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
            d.exec('sdec.capmode = "frame" sdec.armwait = %g' % ARMWAIT)
            clear_absorb(d)

        # ---- H: Arm At at its FLOOR, on a line with nothing on it at all. ----
        if want('H'):
            print('\n=== H: Arm At at its 0.33 V floor, on an open grounded line ===')
            # THE FLOOR IS WHAT AN OPERATOR WINDS TO FOR A SMALL-SWING DEVICE, and the question it
            # raises is whether the comparator then fires on the digitizer's OWN noise rather than on
            # a start bit. A false fire is worse than an expiry: the window closes on silence and the
            # panel reports 'line is idle', which is the exact outcome arming exists to prevent, so
            # the operator would be told the feature does not work by the feature working wrongly.
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil '
                   'sdec.armlevel = 0.33 sdec.armwait = 4.0')
            el, res = press(d, 'H')
            thr = tq(d, 'Hthr', 'dmm.digitize.analogtrigger.edge.level')
            err = tq(d, 'He', 'sdec.lasterr')
            print('  elapsed %.2f s  comparator level=%s' % (el, thr))
            print('  lasterr: %s' % err)
            check('H the floor arms 0.33 V above a grounded line, not at some midpoint',
                  num(thr) is not None and abs(num(thr, 0) - 0.33) < 0.08,
                  'level=%s, want 0.33' % thr)
            check('H ...and the digitizer\'s own noise does not fire a 0.33 V comparator early',
                  el >= 4.0 * 0.7, '%.2f s against an Arm Wait of 4' % el)

        # ---- I: Arm At at its CEILING, in the one branch that does not clamp. ----
        if want('I'):
            print('\n=== I: Arm At at its 6 V ceiling, on a grounded line ===')
            # THE GROUND-IDLE BRANCH OF arm_threshold() DELIBERATELY DOES NOT CLAMP -- a line idling at
            # ground is as tall as its part, so 6 V is a legitimate arm for a 24 V industrial line --
            # which makes this the one configuration that asks the digitizer for a trigger level near
            # the top of its 10 V range. AND A REFUSED ATTRIBUTE WRITE IS OUT OF BAND on this
            # instrument: it returns success and merely files an event, so arm_comparator()'s pcall
            # cannot see it. If the firmware declined a 6 V level the operator would wait out Arm Wait
            # at a level the comparator never adopted, while the note quoted the level that was asked
            # for. THE READBACK IS THE ONLY THING THAT CAN TELL THOSE TWO APART.
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil '
                   'sdec.armlevel = 6.0 sdec.armwait = 4.0')
            el, res = press(d, 'I')
            thr = tq(d, 'Ithr', 'dmm.digitize.analogtrigger.edge.level')
            rng = tq(d, 'Irg', 'dmm.digitize.range')
            err = tq(d, 'Ie', 'sdec.lasterr')
            print('  elapsed %.2f s  comparator level=%s  digitize range=%s' % (el, thr, rng))
            print('  lasterr: %s' % err)
            check('I the firmware ADOPTS a 6 V trigger level rather than refusing it out of band',
                  num(thr) is not None and abs(num(thr, 0) - 6.0) < 0.1,
                  'readback=%s against 6.00 asked, on a %s V range' % (thr, rng))
            check('I ...and a part that cannot reach 6 V expires instead of firing',
                  el >= 4.0 * 0.7, '%.2f s against an Arm Wait of 4' % el)
            # NOT A LITERAL. The arm sits Arm At above the MEASURED idle, and a grounded line measures
            # a few millivolts rather than zero -- so the honest number is 6.01 V, and the thing worth
            # asserting is that the note quotes the level the comparator actually holds. Tying the two
            # together is also the only form of this check that cannot pass while they disagree.
            check('I ...and the expiry quotes the level the comparator is actually holding',
                  num(thr) is not None and ('%.2f V' % num(thr, 0)) in err,
                  'note vs readback %.2f: %s' % (num(thr, 0), err[-60:]))

        # ---- J: Arm Wait at its FLOOR, against a device that starts too late. ----
        if want('J'):
            print('\n=== J: Arm Wait at its 2 s floor, device starts at +4 s ===')
            # THE FLOOR IS A NO-OP BY DESIGN, AND THAT IS WHAT THIS CASE PINS. Arm Wait is taken only
            # where it EXCEEDS the mode's own wait, and 'edge' already waits sdec.trigwait = 3 s -- so
            # a form wound all the way down to 2 cannot make any pre-existing capture fail faster than
            # it used to, which is the whole reason the floor is 2 and not 0. The operator-visible
            # consequence is that a 2 s setting reports "no trigger in 3 s", and the note is right:
            # 3 s is what the capture actually waited. Asserting the 3 here is what stops a future
            # reader filing the disagreement as a defect. MANUAL.md says the same thing in prose.
            #
            # The device starts AFTER the wait is over, so the capture must come back on its own clock
            # -- and the proof is the expiry REASON, not the elapsed time, because the free-running
            # fallback and the probe ladder put a second or two on either side of the wait.
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil '
                   'sdec.armlevel = 1.0 sdec.armwait = 2.0')
            hit = {}
            t0 = time.time()
            th = start_later(g, 4.0, hit, arb_on)
            el, res = press(d, 'J')
            th.join(timeout=20)
            err = tq(d, 'Je', 'sdec.lasterr')
            print('  generator on at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   lasterr: %s' % (el, err))
            check('J the 2 s floor returns on its own clock rather than the 10 s default',
                  1.0 <= el <= 7.0, '%.2f s at an Arm Wait of 2' % el)
            check('J ...and reports the expiry, which is what proves it did not catch the device',
                  'crossed' in err, err[:110])
            check('J ...and the floor is the no-op it was designed to be, not a shorter wait',
                  'in 3 s' in err, 'Arm Wait 2 against the edge mode\'s own 3 s: %s' % err[:70])
            g.output(False, ch=1)

        # ---- K: the TRIGGER key's promise, and whether instrument state backs it. ----
        if want('K'):
            print('\n=== K: is the TRIGGER key actually wired into the arm? ===')
            # THE PANEL PROMISES THE OPERATOR AN ESCAPE from a wait of up to two minutes, and the only
            # thing behind that promise is blender slot 3. A blender write the firmware refuses is OUT
            # OF BAND -- the pcall returns true and an event is filed -- so sdec.armkeyed can be true
            # with nothing wired: a promise with nothing behind it, which is this app's dominant shape
            # of defect and the one armkeyed itself shipped in.
            #
            # NO FINGER IS NEEDED TO CHECK THE WIRING. bench_trigkey.py already establishes that
            # nothing this harness can send synthesises EVENT_DISPLAY, so pressing the key is not
            # testable -- but whether the slot HOLDS the event is, and that is the half that can be
            # wrong silently. arm_source() is called DIRECTLY rather than through a capture because the
            # app releases the blender when a capture ends, so a post-capture readback would show the
            # released state and pass for the wrong reason.
            d.exec('sdec.probe_idle = 0 sdec.fc_out = false sdec.armkey = true '
                   'sdec.trigmode = "edge" sdec.trigext = false sdec.trigext_only = false')
            src = tq(d, 'Ksrc', '(function() local ev, ua, bl = sdec.arm_source() return '
                                'tostring(ev) .. "/" .. tostring(ua) .. "/" .. tostring(bl) end)()')
            keyed = tq(d, 'Kk', 'tostring(sdec.armkeyed)')
            slot1 = tq(d, 'Ks1', 'tostring(trigger.blender[1].stimulus[1])')
            slot3 = tq(d, 'Ks3', 'tostring(trigger.blender[1].stimulus[3])')
            evdisp = tq(d, 'Ked', 'tostring(trigger.EVENT_DISPLAY)')
            evan = tq(d, 'Kea', 'tostring(trigger.EVENT_ANALOGTRIGGER)')
            oren = tq(d, 'Ko', 'tostring(trigger.blender[1].orenable)')
            print('  arm_source -> ev/useanalog/blended = %s' % src)
            print('  armkeyed=%s  orenable=%s' % (keyed, oren))
            print('  stimulus[1]=%s (ANALOGTRIGGER=%s)   stimulus[3]=%s (DISPLAY=%s)'
                  % (slot1, evan, slot3, evdisp))
            check('K the arm claims the TRIGGER key is blended in', keyed == 'true',
                  'armkeyed=%s' % keyed)
            check('K ...and slot 3 really holds the display event, so the promise is backed',
                  slot3 == evdisp and evdisp != 'nil',
                  'stimulus[3]=%s against EVENT_DISPLAY=%s' % (slot3, evdisp))
            check('K ...and the SIGNAL survived the blend rather than being displaced by the key',
                  slot1 == evan and evan != 'nil',
                  'stimulus[1]=%s against EVENT_ANALOGTRIGGER=%s' % (slot1, evan))
            check('K ...and the blender ORs, so either source alone is enough', oren == 'true',
                  'orenable=%s' % oren)
            d.exec('sdec.probe_idle = nil pcall(function() trigger.blender[1].reset() end)')

        # ---- L: an arm must not leave its guessed level behind for the next capture. ----
        if want('L'):
            print('\n=== L: the arm level must not outlive its own capture ===')
            # arm_thr IS idle PLUS Arm At, which is a GUESS, while a normal capture's threshold is a
            # MEASURED midpoint. The recording path reuses a measured threshold between windows -- the
            # right economy, since that is this wire minutes ago -- and that reuse is exactly what let
            # a previous capture's midpoint arm the comparator at 1.63 V on a 0-3.29 V line. THIS IS
            # THE INVERSE LEAK: an arm's guessed level surviving into a capture of a line that IS
            # transmitting, where the measured midpoint is the only right answer. An inverted line
            # caught it offline the moment the fields were cleared per acquisition.
            g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil sdec.capmode = "frame" '
                   'sdec.armlevel = 1.0 sdec.armwait = 2.0')
            el0, _ = press(d, 'L0')                       # an arm that expires, leaving a level set
            g.output(True, ch=1)
            time.sleep(0.5)
            el1, res = press(d, 'L1')                     # ...and now a line that is talking
            athr = tq(d, 'Lat', 'tostring(sdec.arm_thr)')
            thr = tq(d, 'Lt', 'sdec.thr')
            nf = tq(d, 'Lf', 'sdec.res ~= nil and sdec.res.nf or -1')
            baud = tq(d, 'Lb', 'tostring(sdec.baud)')
            print('  arm expired in %.2f s, then a busy-line press returned in %.2f s' % (el0, el1))
            print('  arm_thr=%s  thr=%s  baud=%s  bytes=%s' % (athr, thr, baud, nf))
            check('L a busy-line capture clears the arm level instead of inheriting it',
                  athr == 'nil', 'arm_thr=%s' % athr)
            check('L ...and decodes the line at its measured midpoint',
                  num(nf, 0) > 20 and num(baud, 0) > 0,
                  '%s bytes at %s Bd, thr=%s' % (nf, baud, thr))
            g.output(False, ch=1)

        # ---- M: a line idling NEGATIVE, which is what RS-232 looks like. ----
        if want('M'):
            print('\n=== M: a line idling at -5 V, so the start bit travels UP ===')
            # THE SIGN IS A SEPARATE BRANCH of arm_threshold(), and getting it wrong cannot fire at
            # all: arming the far side of a level the line is already sitting on means the comparator
            # never sees a crossing, which looks exactly like a device that never started. An RS-232
            # line idles at its MARK level, which is negative, and the start bit is the only thing
            # that takes it positive. -5 V with Arm At at 1 V is inside the half-idle clamp (2.5 V),
            # so the expected level is -4.00 V and the expected slope is RISING.
            g.output(False, ch=1)
            g.write('C1:BSWV WVTP,DC,OFST,-5')
            g.output(True, ch=1)
            time.sleep(0.5)
            d.exec('sdec.force_baud = nil sdec.autolock_set = nil '
                   'sdec.armlevel = 1.0 sdec.armwait = 4.0')
            el, res = press(d, 'M')
            thr = tq(d, 'Mthr', 'dmm.digitize.analogtrigger.edge.level')
            slope = tq(d, 'Msl', 'tostring(dmm.digitize.analogtrigger.edge.slope)')
            err = tq(d, 'Me', 'sdec.lasterr')
            print('  elapsed %.2f s  comparator level=%s slope=%s' % (el, thr, slope))
            print('  lasterr: %s' % err)
            check('M the comparator arms one Arm At ABOVE a negative idle',
                  num(thr) is not None and abs(num(thr, 0) + 4.0) < 0.45,
                  'level=%s, want -4.00' % thr)
            check('M ...and on the RISING edge a start bit takes out of a mark',
                  'ris' in slope.lower(), 'slope=%s' % slope)
            g.output(False, ch=1)
            g.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)

        # ---- N: a rate the blind window cannot resolve must REFUSE, not invent one. ----
        if want('N'):
            print('\n=== N: a 57 600 Bd device caught blind -- refuse, do not publish 38 400 ===')
            # 200 kS/s is 3.47 samples per bit at 57 600, which cannot be decoded at all, and the
            # measured failure is specific rather than hypothetical: at a slack bad-fraction gate this
            # line was published as 38 400 Bd on a bad fraction of 0.239, and UNIQUENESS ALONE DID NOT
            # STOP IT, because 38 400 was the only candidate that framed cleanly. So the assertion here
            # is a NEGATIVE -- that no ladder rate is published -- which is the only form that
            # distinguishes a working gate from a lucky one.
            g.output(False, ch=1)
            d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil')
            d.exec('sdec.capmode = "frame" sdec.force_baud = nil sdec.autolock_set = nil '
                   'sdec.armlevel = 1.0 sdec.armwait = %g' % ARMWAIT)
            hit = {}
            t0 = time.time()

            def to_fast(gg):
                gg.select_arb(VN.arb('v41'), 10.0, 57600 * SPB)
                gg.output(True, ch=1)

            th = start_later(g, 3.0, hit, to_fast)
            el, res = press(d, 'N')
            th.join(timeout=25)
            baud = tq(d, 'Nb', 'tostring(sdec.baud)')
            fb = tq(d, 'Nfb', 'tostring(sdec.force_baud)')
            note = tq(d, 'Nn', 'tostring(sdec.probe_note)')
            err = tq(d, 'Ne', 'tostring(sdec.lasterr)')
            print('  generator on at 57600 Bd at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   baud=%s  force_baud=%s' % (el, baud, fb))
            print('  note: %s' % note)
            print('  lasterr: %s' % err)
            check('N a rate the window cannot resolve is not published as one that nearly fits',
                  num(baud, 0) not in (9600, 19200, 28800, 31250, 38400),
                  'baud=%s -- 38400 here is the measured false positive' % baud)
            check('N ...and the operator\'s Auto is not left converted into a lock at a guess',
                  fb == 'nil', 'force_baud=%s' % fb)
            check('N ...and the panel still says what the operator can do about it',
                  'lock the baud rate' in note or 'lock the rate' in note, note[:110])
            g.output(False, ch=1)
            g.select_arb(VN.arb('v41'), 10.0, a.baud * SPB)

        # ---- O: the LARGEST recording, armed. The buffer the settle budget has to cover. ----
        if want('O'):
            print('\n=== O: a 32 kB recording armed on silence, device starts at +3 s ===')
            # THE 32 kB MODE IS THE WIDEST RECORDING THE APP OFFERS, and until now nothing covered it.
            # Its size follows from the FORMAT, not from sdec.ck_bufmax: stream_samples() asks for
            # md.cap bytes x framebits x (fs/baud), so 32 768 x 10 x (40 000/9600) = 1 365 334
            # readings, and the armed buffer is that plus the 5 % pre-trigger reserve and 100 readings
            # of abort headroom -- ceil(nsmp*100/95) + 100 = 1 437 294. ck_bufmax binds only a mode
            # whose md.cap is nil. Four times case F's buffer, which is what the check below compares
            # against rather than a literal.
            #
            # THE BUFFER IS NOT WHAT THE SETTLE BUDGET IS SPENT ON. Time to STATE_WAITING is flat at
            # ~0.19 s from 21 100 to 2 800 000 readings -- slope +1.6e-9 +/- 5.7e-9 s/reading, t = 0.28
            # -- and buffer.make() runs in acq_make_buffer() BEFORE stream_arm() spins, so it cannot be
            # in that interval at all. What the budget covers is the PRIOR acquisition: aborting a
            # model that was sitting in STATE_WAITING costs 0.228 s, and sdec.trig_settle() aborts
            # before every capture, so the app always pays that row. Hence a 10 s budget and not 0.25.
            #
            # IT IS THE SLOW CASE: about 30 s of capture and two minutes of decoding, which is why the
            # press gets its own timeout rather than the default.
            g.output(False, ch=1)
            d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil')
            clear_absorb(d)
            d.exec('sdec.capmode = "med" sdec.force_baud = %d sdec.armwait = %g' % (a.baud, ARMWAIT))
            hit = {}
            t0 = time.time()
            th = start_later(g, 3.0, hit, arb_on)
            el, res = press(d, 'O', timeout=900)
            th.join(timeout=1)
            armed = tq(d, 'Oa', 'tostring(sdec.strm_armed)')
            endwhy = tq(d, 'Ow', 'tostring(sdec.ck_endwhy)')
            nb = tq(d, 'Ob', 'tostring(sdec.ck_nbytes)')
            cap = tq(d, 'Oc', 'tostring(sdec.buf ~= nil and sdec.buf.capacity or nil)')
            nsmp = tq(d, 'On', 'tostring(sdec.strm_nsmp)')
            fsx = tq(d, 'Of', 'tostring(sdec.fs)')
            err = tq(d, 'Oe', 'tostring(sdec.lasterr)')
            print('  generator on at +%.2f s' % (hit.get('on', t0) - t0))
            print('  elapsed %.2f s   capture=%s' % (el, res))
            print('  armed=%s endwhy=%s bytes=%s' % (armed, endwhy, nb))
            print('  nsmp=%s buffer capacity=%s  fs=%s' % (nsmp, cap, fsx))
            print('  lasterr: %s' % err)
            check('O the largest recording arms rather than recording the silence', armed == 'true',
                  'strm_armed=%s at capacity %s' % (armed, cap))
            # DERIVED FROM CASE F'S OWN MEASUREMENT, not from a threshold. Skipped rather than
            # asserted when F did not run, because --only O would otherwise compare against nothing
            # and a comparison against nothing passes.
            if CAPS.get('F'):
                check('O ...and the arm survives a buffer several times case F\'s',
                      num(cap, 0) >= 3 * CAPS['F'],
                      'capacity=%s against case F\'s %s -- %.1fx'
                      % (cap, CAPS['F'], num(cap, 0) / CAPS['F']))
            # THE CAPACITY IS AN ARITHMETIC CONSEQUENCE OF nsmp, so assert the relation and the two
            # numbers check each other. A bare floor cannot tell a correctly sized buffer from a
            # mode that silently fell back to a smaller one.
            pre = num(tq(d, 'Op', 'sdec.pretrig'), 0)
            want_cap = math.ceil(num(nsmp, 0) * 100.0 / (100.0 - pre)) + 100 if pre else None
            check('O ...and the armed buffer is nsmp plus the reserve and the abort headroom',
                  want_cap is not None and num(cap, 0) == want_cap,
                  'capacity=%s, nsmp=%s at pretrig=%g%% wants %s' % (cap, nsmp, pre, want_cap))
            check('O ...and it collected bytes from the line', num(nb, 0) > 20, '%s bytes' % nb)
            # THE WIDEST RECORDING, THE SAME QUESTION AS CASE F. Its reserve is 3.6 priming windows,
            # so it is the mode where a reserve-derived prior is hardest to escape.
            oinv = tq(d, 'Oi', 'sdec.res ~= nil and tostring(sdec.res.invert) or "?"')
            obad = tq(d, 'Ox', 'sdec.res ~= nil and sdec.res.nbad or -1')
            otxt = tq(d, 'Ot', 'sdec.res ~= nil and sdec.ua_text_line(1, 30) or "-"')
            oidle = tq(d, 'Od', 'sdec.idle')
            print('  invert=%s nbad=%s idle=%s text=%r' % (oinv, obad, oidle, otxt[:34]))
            check('O ...the right way up, not an inverted reading of the reserve',
                  oinv == 'false' and num(oidle, -1) == 1,
                  'invert=%s idle=%s' % (oinv, oidle))
            check('O ...and they are the line\'s own bytes, nearly all of them clean',
                  'Hello' in otxt and num(obad, 1e9) <= num(nb, 0) * 0.02,
                  'nbad=%s of %s text=%r' % (obad, nb, otxt[:34]))
            d.exec('sdec.capmode = "frame" sdec.force_baud = nil')
            clear_absorb(d)
            g.output(False, ch=1)

        # ---- P: THE RESERVE IS NOT THE LINE'S IDLE. Four lock states, armed on silence. ----
        if want('P'):
            print('\n=== P: armed on silence, the polarity prior must not come from the reserve ===')
            # AN ARMED CAPTURE OPENS IN ITS PRE-TRIGGER RESERVE, which is the wire before the device
            # started -- ground, and on a single-supply line ground is the SPACE level. sig_idle's
            # longest-run rule read that as the idle level and set the prior to 'idles LOW', so the
            # decode came back inverted: self-consistent, plausible error count, every byte wrong.
            #
            # THE AUTOLOCK ROW IS THE ONE THAT MATTERS. sdec.autolock is true by default and
            # autolock_try() sets nbits/par/nstop while deliberately leaving force_invert nil. In
            # that state decode_from takes the forced-format branch, which reads
            # `inv = (sdec.idle == 0)` with NO second polarity searched and no margin -- so a wrong
            # prior has nothing to overturn it. The other three rows have ua_autoformat's contest as
            # a backstop; this one does not, which is why a pass here is the real assertion.
            #
            # MEASURED BEFORE THE FIX: 0/6 readable at a locked rate, 158 bytes with 62 bad.
            #
            # AND MEASURED WITH THE GUARD DISABLED ON THE INSTRUMENT, which is what decides the
            # shape of these assertions: the `run0 == leadrun` check fails in ALL THREE rows, while
            # the BYTE check fails only in the autolock one -- the other two were rescued by
            # ua_autoformat's contest on that run. So the mechanism assertion is the reliable
            # detector and the byte assertion is the one that says the defect reached the operator.
            # Both are kept, and the autolock row is why the byte assertion is worth having.
            locks = [
                ('nothing locked', 'sdec.force_baud = nil sdec.force_nbits = nil '
                                   'sdec.force_par = nil sdec.force_nstop = nil '
                                   'sdec.force_invert = nil sdec.autolock_set = nil'),
                ('rate locked', 'sdec.force_baud = %d sdec.force_nbits = nil '
                                'sdec.force_par = nil sdec.force_nstop = nil '
                                'sdec.force_invert = nil sdec.autolock_set = nil' % a.baud),
                ('autolock', 'sdec.force_baud = %d sdec.force_nbits = 8 '
                             'sdec.force_par = sdec.PAR_NONE sdec.force_nstop = 1 '
                             'sdec.force_invert = nil sdec.autolock_set = '
                             '{baud = true, nbits = true, par = true, nstop = true}' % a.baud),
            ]
            for li, (lname, setup) in enumerate(locks):
                g.output(False, ch=1)
                d.exec('sdec.capmode = "frame" sdec.trigmode = "edge" sdec.armlevel = 1.0 '
                       'sdec.armwait = %g' % ARMWAIT)
                d.exec(setup)
                clear_absorb(d)
                hit = {}
                t0 = time.time()
                th = start_later(g, 3.0, hit, arb_on)
                el, res = press(d, 'P%d' % li)
                th.join(timeout=1)
                idle = tq(d, 'Pi%d' % li, 'sdec.idle')
                lead = tq(d, 'Pl%d' % li, 'sdec.leadrun')
                r0 = tq(d, 'Pr%d' % li, 'sdec.run0')
                ptf = tq(d, 'Pp%d' % li, 'tostring(sdec.acq_pretrig)')
                inv = tq(d, 'Pv%d' % li, 'sdec.res ~= nil and tostring(sdec.res.invert) or "?"')
                nf = tq(d, 'Pf%d' % li, 'sdec.res ~= nil and sdec.res.nf or -1')
                nbad = tq(d, 'Px%d' % li, 'sdec.res ~= nil and sdec.res.nbad or -1')
                txt = tq(d, 'Pt%d' % li, 'sdec.res ~= nil and sdec.ua_text_line(1, 30) or "-"')
                print('  %-15s %5.2f s  pretrig=%-5s lead=%-8s run0=%-8s idle=%-4s inv=%-5s '
                      'bytes=%-4s bad=%-4s' % (lname, el, ptf, lead[:7], r0[:7], idle, inv,
                                               nf, nbad))
                # THE PREMISE FIRST: an assertion about the reserve is vacuous if there was no
                # reserve. A fired arm must report one, and the leading run must be most of it.
                check('P %s: the record opens in a pre-trigger reserve' % lname,
                      ptf == 'true' and num(lead, 0) > 500,
                      'acq_pretrig=%s leadrun=%s' % (ptf, lead))
                check('P %s: ...and the reserve is NOT counted as the longest low run' % lname,
                      num(r0, 0) < num(lead, 1) / 2,
                      'run0=%s against a %s-sample reserve' % (r0, lead))
                check('P %s: ...so the prior is the line, not the switched-off wire' % lname,
                      num(idle, -1) == 1, 'idle=%s (0 means it read the reserve as idle)' % idle)
                check('P %s: ...and the bytes are the right way up' % lname,
                      inv == 'false' and num(nbad, 99) == 0 and 'Hello' in txt,
                      'invert=%s nbad=%s text=%r' % (inv, nbad, txt[:34]))
                g.output(False, ch=1)
            d.exec('sdec.force_baud = nil sdec.force_nbits = nil sdec.force_par = nil '
                   'sdec.force_nstop = nil sdec.force_invert = nil sdec.autolock_set = nil')

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
        d.exec('sdec.armwait = %s sdec.armlevel = %s sdec.armkey = true'
               % (num(entry_wait, 10.0), num(entry_lvl, 1.0)))
        # THE QUEUED-PRESS ABSORB IS APP STATE TOO, and it is the one that makes the NEXT tool look
        # broken rather than this one: a press it swallows returns in 0.01 s with the previous run's
        # verdict attached. Left armed by every recording case here.
        clear_absorb(d)
        # probe_idle is what arm_silent() answers from, and case K writes it by hand to reach
        # arm_source() without a capture. Left set, it tells the next tool the line is silent.
        d.exec('sdec.probe_idle = nil sdec.arm_thr = nil sdec.arm_idle = nil')
        d.exec('pcall(function() trigger.blender[1].reset() end)')
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

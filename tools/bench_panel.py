#!/usr/bin/env python3
"""Press every button the app has, in every state that changes what it should do, and check both
that each one DID ITS JOB and that the PANEL SHOWS it -- not merely that the handler returned.

THIRTEEN HANDLERS. Nine on the main screen (six along the bottom, three down the right margin) and
four on the options screen:

    Capture  View  Mode  NewLog  Save  Options          bottom row
    Page Up  Lock Rate  Page Dn                         right margin, shown conditionally
    Auto Detect  Lock Detected  Apply  Cancel           options screen

SIX CHECKS PER PRESS:

  1. IT DOES NOT RAISE.      A handler that throws leaves a dead button and no explanation. Every
     press goes through pcall on the instrument, so a raise is reported rather than killing the panel.
  2. IT LOGS NOTHING.        The front panel shows error-severity events whatever localnode.showevents
     says, so an event logged by a press is a modal dialog the operator saw. The trigger model's own
     initiated/aborted notices are informational and excluded by number; everything else counts.
  3. IT RETURNS FAST ENOUGH. A press is not dispatched while Lua runs and presses QUEUE, so the
     handler's own duration IS the press latency. sdec.ui_latency_s is the budget for every handler
     except the ones that deliberately take a capture -- see CAPTURE_BUDGET_S.
  4. IT SAYS WHAT IT DID.    The handler's own return value is recorded, so a press that declined
     is distinguishable from one that worked. A silent false is a defect when the panel shows nothing.
  5. IT HAD THE INTENDED EFFECT ON STATE. Every press names the state it must change and by how
     much. A button that returns quietly having done nothing passes checks 1-3 and is still broken.
  6. THE PANEL SHOWS IT. The screen is grabbed BEFORE and AFTER each press and differenced by
     region. A press whose state changed while its region did not is a stale display: the app is
     right and the operator is reading something false. This is a distinct failure from 5 and has
     to be measured separately, because ui_refresh's shadow caches exist precisely to skip writes.

CONDITIONAL BUTTONS ARE CHECKED BY LOOKING AT THEM. Page Up, Lock Rate and Page Dn hide themselves,
and whether they are on the glass is not visible in any state variable -- so their rectangles are
measured in the grab directly (a button is ~90 % mid-grey, an empty margin ~0 %).

A PRESS THAT MUST DO NOTHING IS ALSO TESTED, in both senses: Page Up on page 1, Save with nothing
captured, Lock Rate with nothing decoded. Each must decline without raising, without logging, and
WITHOUT repainting -- a no-op that redraws is how a flicker gets shipped.

    python3 tools/bench_panel.py --reuse --shots ~/tmp/btn   # the normal run
    python3 tools/bench_panel.py --reuse                     # no grabs, state checks only
    python3 tools/bench_panel.py                     # load + build first (one per power cycle)
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
import run_app as RA
import bench_sync as BS
import screenshot as SS
import vector_names as VN                                     # noqa: E402

# Trigger-model progress notices. Informational severity, posted by every armed capture, and not
# something a press can avoid -- so they are excluded by number rather than by severity, which
# would also hide real errors.
INFO_EVENTS = ('2731', '2732', '2728', '4917')

# The press-latency budget does not apply to a handler that takes a CAPTURE. FRAME mode is a
# documented, deliberate exception to the 500 ms rule -- one press does the whole job rather than
# splitting it across several. Measured on the instrument: 1.7 s with the rate locked, 5.1 s
# unlocked at 9600, and 8.4 s unlocked at 2400, where the probe has to step its sample rate down
# to catch a frame at all. lock_toggle and options_apply both end in a capture on purpose, so they
# carry the same bound.
#
# 12 s, NOT 9 s, AND THE MARGIN IS SIZED TO THE SPREAD RATHER THAN TO ONE SAMPLE. A 9 s bound sat
# 7% above that single 8.4 s measurement and a sweep crossed it at 9.086 s -- a gate that fails at
# random is worse than no gate, because the next real regression gets read as flakiness. The
# quantity varies because the probe steps its sample rate down until it catches traffic and how many
# looks that takes depends on where the traffic is when the capture starts: 12 unlocked captures at
# 2400 baud measured min 4.891 s, mean 5.358 s, max 7.253 s -- a 2.36 s spread, 33% of the max --
# and the sweep's own worst observation is 9.086 s. 12 s is the observed worst case plus that spread.
# It is a LATENCY ceiling, not a target: the numbers above are what the app actually costs, and a
# press that genuinely took 12 s would still be a defect worth chasing.
CAPTURE_BUDGET_S = 12.0
CAPTURES = ('Capture', 'LockRate', 'Opt:Apply', 'Opt:AutoDetect', 'Opt:LockDetected')

# A RECORDING PRESS IS IN A THIRD CLASS, and folding it into the ordinary bound either fails every
# sweep or raises that bound until it means nothing. One press records a whole window and decodes it:
# 8 kB at 2400 baud is ~34 s of recording plus ~30 s of decoding, and the operator is told so on the
# status row. What makes a minutes-long press acceptable is that it is BOUNDED and states its cost
# beforehand -- NOT that TRIGGER stops it, which it does not: the key's event does not reach the
# blender while a panel-initiated run executes. The cancel case below passes because it delivers the
# event from a firmware timer rather than a finger -- worth knowing when reading its verdict.
#
# 300 s is a HANG DETECTOR, not a latency budget. It is sized to catch a press that never returns --
# the failure that costs a power cycle -- and deliberately not to police the duration, which is the
# window size the operator chose.
RECORD_BUDGET_S = 300.0
RECORDS = ('Capture/8kB', 'Capture/32kB', 'Capture/cancelled', 'Capture/fc')

# One press, and the state around it, on one line so the parser cannot desync. The state probe is
# a single function so that "before" and "after" are read the same way -- a probe that differs
# between the two turns a formatting difference into a behavioural verdict.
PRESS_TSP = r'''
function bp_state()
  local r = sdec.res
  local npg, lock, suits = 0, '?', '?'
  pcall(function() npg = sdec.ui_npages() end)
  pcall(function() lock = tostring(sdec.lock_state()) end)
  pcall(function() suits = tostring(sdec.mode_suits()) end)
  -- A FINGERPRINT OF THE BYTES, so "the dump did not repaint" can be told apart from "the dump had
  -- nothing new to show". Two captures of a LOOPING payload that land on the same phase decode the
  -- same bytes, and writing the same text to the same objects changes no pixel -- correct behaviour
  -- that is indistinguishable from a dead dump without this. 'Hello, World!' repeats every 13 bytes,
  -- so a matching pair comes up about one press in thirteen.
  --
  -- math.mod, NOT math.fmod: 5.0.2 has only the former, and a shim makes this pass every offline
  -- test and die on the instrument.
  local vsum = 'nil'
  if r ~= nil and r.vals ~= nil then
    local h, i = 0, nil
    for i = 1, (r.nf or 0) do
      h = math.mod(h * 31 + (r.vals[i] or 0), 1000000007)
    end
    vsum = string.format('%d', h)
  end
  -- No 'which screen is showing' field is reported because the app does not keep one: the
  -- firmware owns that and nothing in the app needs to ask. A screen SWAP is therefore verified
  -- from the grabs -- it repaints every region -- not from a state variable.
  return string.format('view=%s mode=%s page=%s npg=%s nf=%s baud=%s force=%s saved=%s '
                       .. 'log=%s logn=%s status=%s lock=%s suits=%s fcwin=%s vsum=%s err=%s',
                       tostring(sdec.ui_mode), tostring(sdec.capmode),
                       tostring(sdec.ui_page), tostring(npg),
                       tostring(r and r.nf), tostring(sdec.baud),
                       tostring(sdec.force_baud), tostring(sdec.savedas),
                       tostring(sdec.flog_path), tostring(sdec.flog_n),
                       tostring(sdec.ui_status), lock, suits,
                       tostring(sdec.fc_win), vsum, tostring(sdec.lasterr))
end

function bp_press(name, fn)
  eventlog.clear()
  print('BEFORE ' .. bp_state())
  timer.cleartime()
  local ok, ret = pcall(fn)
  local t = timer.gettime()
  local ec = eventlog.getcount()
  local emsg = ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
  end
  print('AFTER ' .. bp_state())
  print(string.format('PRESS %s|%s|%.4f|%d|%s|%s', name, tostring(ok), t, ec, emsg,
                      tostring(ret)))
  local nt, nn = sdec.ui_notes()
  for i = 1, nn do print('NOTE ' .. tostring(nt[i])) end
  print('P end')
end
print('===DONE===')
'''


def parse_state(s):
    out = {}
    for kv in s.split():
        if '=' in kv:
            k, v = kv.split('=', 1)
            out[k] = v
    return out


def count_real_events(emsg):
    """Events that are NOT trigger-model progress notices. emsg is '[num text][num text]...'."""
    n = 0
    for part in emsg.split(']'):
        part = part.strip('[').strip()
        if not part:
            continue
        num = part.split()[0] if part.split() else ''
        if num not in INFO_EVENTS:
            n += 1
    return n


# THE PANEL, BY REGION. Coordinates are the app's own layout constants from serial_ui.tsp offset by
# the 49 px firmware title bar, so a diff can be attributed to the thing that owns those pixels
# rather than reported as "something changed somewhere".
#
# The LEFT cell of the note row is the TRIGGER SOURCE, not the mode. It held mode names once, and this
# map still called it 'mode' with a stale ui_note_val_x = 92 long after serial_ui.tsp moved the
# boundary to 112 to fit 'Trigger key' (serial_ui.tsp:175). That drift made three checks demand
# repainted pixels in a cell Mode does not own, and every Mode press then reports
# 'STALE DISPLAY: mode did not repaint (0 px)' while the handler returns true and the mode DOES
# advance. A region map naming the wrong owner reports a defect in the app for a defect in itself.
# The mode is shown in the SCREEN TITLE ('SERIAL DECODE - 240B FRAME', ui_title_text), so that is the
# region a Mode press must repaint. `a3['mode']` elsewhere is the parsed STATE, a different namespace.
REGIONS = [
    ('title',   0,   0,  800,  49),
    ('fields',  0,  49,  800,  85),   # BAUD FORMAT IDLE LOGIC THRESH SA/BIT RATE BYTES ERR FIT
    ('trigsrc', 0,  85,  103, 107),   # Start bit / Free run / Trigger key, up to the rule at 103
    ('note',  112,  85,  800, 107),   # the one-note cell and its (+N more) marker
    ('dump',    0, 107,  800, 377),   # decoded bytes, whichever view is showing
    ('status',  0, 377,  800, 400),   # view, page x/n, byte range, window, log file, EXT TRIG
    ('buttons', 0, 415,  800, 480),   # the six along the bottom: static within a screen
]

# The three conditional buttons down the right margin, as rectangles in grab coordinates. Each rect
# is the button's OWN face -- serial_ui.tsp's pdef x/y plus the 49 px title bar -- not a shared strip.
#
# THEY ARE NOT THE SAME WIDTH, which is why. 'Up' and 'Dn' are 56 px faces at x = 729 and Lock Rate
# is 140 at 645, so one shared 185 px rect over 600..785 measures a 56 px button as 30 % grey --
# under BTN_GREY_PCT, reporting a button plainly on the glass as ABSENT.
#
# The KEYS stay 'PageUp' and 'PageDn' -- they name the control, not the label on it, and eight press
# cases below pass them as identifiers.
MARGIN_BTNS = {'PageUp': (729, 107, 785, 165),
               'LockRate': (645, 209, 785, 267),
               'PageDn': (729, 311, 785, 369)}

# A drawn button fills its rect with a mid-grey gradient; an empty margin is the near-black panel
# background. Measured: 90 % grey when present, at most 6 % when absent (dump text can reach into
# the margin), so the threshold has an enormous gap either side.
BTN_GREY_PCT = 40

# How many changed pixels count as a repaint. A single digit in the small face is ~40 lit pixels,
# so 20 is under one character and far above the framebuffer's dither.
REPAINT_PX = 20


def _same_bytes(a, b):
    try:
        with open(a, 'rb') as fa, open(b, 'rb') as fb:
            return fa.read() == fb.read()
    except OSError:
        return False


def _load(path):
    from PIL import Image
    return Image.open(path).convert('RGB')


def region_diff(path_a, path_b, thresh=24):
    """Changed-pixel count per named region. -> {name: count}, total."""
    ia, ib = _load(path_a), _load(path_b)
    if ia.size != ib.size:
        return {'size': -1}, -1
    pa, pb = ia.load(), ib.load()
    out, total = {}, 0
    for name, x0, y0, x1, y1 in REGIONS:
        n = 0
        for y in range(y0, min(y1, ia.size[1])):
            for x in range(x0, min(x1, ia.size[0])):
                ra, ga, ba = pa[x, y]
                rb, gb, bb = pb[x, y]
                if abs(ra - rb) + abs(ga - gb) + abs(ba - bb) > thresh:
                    n += 1
        out[name] = n
        total += n
    return out, total


def margin_buttons(path):
    """Which of the three conditional buttons are actually on the glass. -> {name: bool}."""
    im = _load(path)
    px = im.load()
    out = {}
    for name, (x0, y0, x1, y1) in MARGIN_BTNS.items():
        n = 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                r, g, b = px[x, y]
                if (r + g + b) / 3 > 90 and abs(r - g) < 30 and abs(g - b) < 30:
                    n += 1
        out[name] = (100.0 * n / ((x1 - x0) * (y1 - y0))) >= BTN_GREY_PCT
    return out


class Panel:
    def __init__(self, d, shots=None):
        self.d = d
        self.shots = shots
        self.n = 0
        self.rows = []
        self.budget = float(d.q('print(sdec.ui_latency_s)') or 0.5)

    def _budget_for(self, label):
        # RECORDS FIRST: every one of them also starts with 'Capture', so testing CAPTURES first
        # would give a whole-window recording the 12 s frame-capture bound.
        for pfx in RECORDS:
            if label.startswith(pfx):
                return RECORD_BUDGET_S
        for pfx in CAPTURES:
            if label.startswith(pfx):
                return CAPTURE_BUDGET_S
        return self.budget

    def press(self, label, fn, expect=None, timeout=300, paints=None,
              quiet_screen=False, swap=False, buttons=None, buttons_before=None):
        """One press, screen-grabbed either side of it.

        expect        (description, predicate(before, after)) -- the state requirement
        paints        region names that MUST show changed pixels
        quiet_screen  the display must NOT change at all
        swap          this press changes SCREEN, so the button row legitimately differs
        buttons       {'LockRate': True, ...} -- which margin buttons must be on the glass AFTER
        buttons_before the same, checked BEFORE the press: the right assertion when the press
                      itself changes the state that decides whether the button is shown
        """
        slug = ''.join(c if c.isalnum() else '_' for c in label)
        self.n += 1
        shot_b = shot_a = None
        if self.shots:
            # SETTLE FIRST. Whatever ran before this press -- a setup, or the previous press --
            # issued display writes the LCD has not necessarily finished. Grabbing mid-repaint
            # makes the pair differ for a reason that has nothing to do with the press.
            time.sleep(0.3)
            shot_b = os.path.join(self.shots, '%03d_%s_before.png' % (self.n, slug))
            try:
                SS.capture(shot_b)
            except Exception as e:
                print('    before-grab failed: %s' % e)
                shot_b = None
                # A MISSING GRAB DISABLES EVERY DISPLAY ASSERTION FOR THIS PRESS, so it cannot pass
                # quietly. The pixel checks are skipped when a grab is absent -- which is right, they
                # would be meaningless -- but the press then reports on strictly less than it claims.
                self.grabfails = getattr(self, 'grabfails', 0) + 1

        self.d.drain()
        # HOST WALL CLOCK AS WELL AS THE INSTRUMENT'S. The instrument figure is the better one --
        # it excludes socket latency -- but it is not trustworthy for every press: there is ONE
        # timer on a DMM6500, timer.cleartime() is global, and the app itself calls it inside
        # sdec.strm_absorb_arm() at the end of a recording. bp_press then measures the time since
        # THAT stamp and reports 0.025 s for a press that really took half a minute, which would
        # make the hang detector blind exactly where a hang would be worst.
        t_host = time.time()
        self.d.send('bp_press(%r, %s)' % (label, fn))
        before, after, res, notes = {}, {}, None, []
        while True:
            ln = self.d.line(timeout)
            if ln is None:
                res = (label, False, 0.0, 0, 'timeout', 'timeout')
                break
            if ln.startswith('BEFORE '):
                before = parse_state(ln[7:])
            elif ln.startswith('AFTER '):
                after = parse_state(ln[6:])
            elif ln.startswith('NOTE '):
                notes.append(ln[5:])
            elif ln.startswith('PRESS '):
                f = ln[6:].split('|')
                res = (f[0], f[1] == 'true', float(f[2]), int(f[3]), f[4],
                       f[5] if len(f) > 5 else '')
            elif ln == 'P end':
                break
        name, ok, secs, ec, emsg, ret = res
        host_secs = time.time() - t_host
        nreal = count_real_events(emsg)
        # WHEN THEY DISAGREE, BELIEVE THE LONGER ONE AND SAY SO. The host figure includes the socket
        # round trip, which is milliseconds; the instrument figure can only be too SHORT, and only by
        # a clobbered timer. So a host time well past the instrument's is not noise, it is evidence.
        clobbered = host_secs > secs * 2 + 0.25
        if clobbered:
            secs = host_secs

        if shot_b:
            # The handler returns before the firmware has necessarily pushed the last settext to
            # the LCD, so settle before grabbing.
            time.sleep(0.25)
            shot_a = os.path.join(self.shots, '%03d_%s_after.png' % (self.n, slug))
            try:
                SS.capture(shot_a)
            except Exception as e:
                print('    after-grab failed: %s' % e)
                shot_a = None
                self.grabfails = getattr(self, 'grabfails', 0) + 1

        budget = self._budget_for(label)
        verdict, effect = [], 'n/a'
        if not ok:
            verdict.append('RAISED %s' % str(ret)[:44])
        if nreal:
            verdict.append('LOGGED %d: %s' % (nreal, emsg[:56]))
        if secs > budget:
            verdict.append('OVER %.1f s budget by %.2f s' % (budget, secs - budget))
        if clobbered:
            print('      the instrument timer was reset inside this press (%s does it at the end of '
                  'a recording); timed on the host instead: %.2f s'
                  % ('strm_absorb_arm', host_secs))
        if expect is not None:
            desc, pred = expect
            try:
                got = bool(pred(before, after))
            except Exception as e:
                got, desc = False, '%s (predicate error %s)' % (desc, e)
            effect = desc
            if not got:
                verdict.append('NO EFFECT: expected %s' % desc)

        painted, seen_btns, dump_excused = {}, {}, False
        if shot_b and shot_a:
            painted, total = region_diff(shot_b, shot_a)
            # A BYTE-IDENTICAL PAIR IS A GRAB FAULT, NOT A STALE DISPLAY, and the two must never be
            # confused: the instrument freezes its framebuffer if the front-panel session is
            # churned, and every press then reports a repaint failure against an app that is
            # painting perfectly. If the state changed but not one pixel did, distrust the camera.
            # ...but only where a CHANGE was expected. On a press whose whole point is that the
            # panel must not move, an identical pair is the pass condition, not a fault.
            if total == 0 and paints and _same_bytes(shot_b, shot_a):
                verdict.append('GRAB FAULT: before/after are byte-identical -- the instrument '
                               'froze its framebuffer; no display conclusion can be drawn')
                paints = None
            hot = sorted([(k, v) for k, v in painted.items() if v >= REPAINT_PX],
                         key=lambda kv: -kv[1])
            if quiet_screen and hot:
                verdict.append('REPAINTED on a no-op: '
                               + ', '.join('%s %d px' % kv for kv in hot))
            # AN IDENTICAL DUMP IS ONLY EXCUSED WHEN THE BYTES ARE IDENTICAL TOO, which is what vsum
            # decides. A capture of a looping payload that lands on the phase the previous one did
            # decodes the same bytes, and writing the same text changes no pixel -- so demanding a
            # repaint fails a correct app about one press in thirteen on 'Hello, World!'. Gating on
            # vsum keeps the check's teeth: if the bytes CHANGED and the dump did not move, that is
            # still a stale display, which is the defect this exists to catch.
            same_bytes = (before.get('vsum') not in (None, 'nil')
                          and before.get('vsum') == after.get('vsum'))
            dump_excused = False
            for want in (paints or []):
                if painted.get(want, 0) >= REPAINT_PX:
                    continue
                if want == 'dump' and same_bytes:
                    dump_excused = True
                    continue
                verdict.append('STALE DISPLAY: %s did not repaint (%d px)'
                               % (want, painted.get(want, 0)))
            if not swap and painted.get('buttons', 0) >= REPAINT_PX:
                verdict.append('the button row repainted (%d px) on the same screen'
                               % painted['buttons'])
            seen_btns = margin_buttons(shot_a)
            for bname, want in (buttons or {}).items():
                if seen_btns.get(bname) != want:
                    verdict.append('%s is %s on the glass after, expected %s'
                                   % (bname, 'shown' if seen_btns.get(bname) else 'hidden',
                                      'shown' if want else 'hidden'))
            if buttons_before:
                was = margin_buttons(shot_b)
                for bname, want in buttons_before.items():
                    if was.get(bname) != want:
                        verdict.append('%s was %s on the glass before, expected %s'
                                       % (bname, 'shown' if was.get(bname) else 'hidden',
                                          'shown' if want else 'hidden'))

        print('  %-24s %-5s %7.3f s  ev %d  ret %-5s %-30s %s'
              % (label, 'ok' if not verdict else 'BAD', secs, nreal, str(ret)[:5],
                 effect[:30], ' | '.join(verdict) if verdict else 'ok'))
        if painted:
            hot = ['%s %d' % (k, v) for k, v in
                   sorted(painted.items(), key=lambda kv: -kv[1]) if v >= REPAINT_PX]
            shown = [k for k, v in seen_btns.items() if v]
            print('      repainted: %-56s margin: %s'
                  % (', '.join(hot) if hot else 'nothing',
                     ', '.join(sorted(shown)) if shown else 'none shown'))
            # SAID OUT LOUD, because a silently excused check reads as a check that passed. The
            # operator needs to know the dump was compared and had nothing to redraw.
            if dump_excused:
                print('      dump held still because the bytes are identical (vsum %s) -- '
                      'a repaint would have had nothing to show' % after.get('vsum'))
        for n in notes[:2]:
            print('      note: %s' % n[:104])
        self.rows.append({'label': label, 'ok': ok, 'secs': secs, 'events': nreal,
                          'emsg': emsg, 'ret': str(ret), 'verdict': verdict,
                          'before': before, 'after': after, 'painted': painted,
                          'margin': seen_btns, 'notes': notes,
                          'shots': [shot_b, shot_a]})
        return before, after

    def fail(self, label, why):
        """Record a failure detected by a check the press wrapper cannot make itself.

        Some requirements are about state the predicate cannot see at press time -- whether a decode
        job was left open, whether a cancel was actually SEEN rather than the run having finished on
        its own. Those are read after the press and reported here, into the same rows the summary
        counts, so they fail the sweep exactly as an over-budget press does.
        """
        print('      FAILED: %s' % why)
        self.rows.append({'label': label + '/check', 'ok': True, 'secs': 0.0, 'events': 0,
                          'emsg': '', 'ret': '', 'verdict': [why],
                          'before': {}, 'after': {}, 'painted': {},
                          'margin': {}, 'notes': [], 'shots': [None, None]})

    def state(self):
        self.d.drain()
        self.d.send('print("S " .. bp_state())')
        ln = self.d.line(60)
        return parse_state(ln[2:]) if ln and ln.startswith('S ') else {}

    def setup(self, stmt, timeout=300):
        """A state change made over the socket rather than by a press -- getting the app INTO a
        condition is not itself a button test, and doing it by pressing would confound the two.

        REPORTED IF IT FAILS. A setup that silently did nothing turns the next press into a test of
        a condition that was never established, and the app then fails a check it should never have
        been given -- which is indistinguishable from a real defect until someone reads the grabs.
        """
        ok = self.d.exec(stmt, timeout=timeout)
        if not ok:
            print('      SETUP FAILED, the next check is not meaningful: %s' % stmt[:70])
            # AND IT FAILS THE SWEEP. Printing alone left the run green: the press that followed tested a
            # condition that was never established, so it either passed for the wrong reason or failed
            # for one -- and neither is a fact about the app. Recorded through fail() so it lands in the
            # same rows the summary counts.
            self.fail('setup', 'a setup statement did not complete, so the next check tested an '
                               'unestablished condition: %s' % stmt[:80])
        return ok

    def note(self, msg):
        print('      %s' % msg)

    def drain_job(self, limit=200):
        """Step a chunked decode to completion.

        Capture has a FOURTH meaning the state machine makes unambiguous but a test must model:
        with a decode job open it advances ONE window, so the panel stays inside its latency
        budget. A test that pressed Capture expecting fresh bytes would be reading a press that
        correctly did something else.
        """
        n = 0
        while n < limit:
            open_job = self.d.q('print(tostring(sdec.ck_job ~= nil))')
            if open_job != 'true':
                break
            self.d.exec('sdec.capture()', timeout=120)
            n += 1
        if n:
            print('      stepped %d decode window(s) to finish the job' % n)
        return n

    def to_frame(self):
        """Put the app in idle FRAME mode with nothing pinned -- the condition most blocks want."""
        self.drain_job()
        # ck_tot GOES TOO, and it is not housekeeping: while a recording's totals are set, the status
        # row shows the STREAM summary instead of the frame row -- so a View press changes no pixels
        # there, and the stale-display check fails on an app that is behaving correctly. It only bites
        # under --reuse, where a previous run's recording is still on screen, which is exactly how this
        # file is normally run.
        # THE SHARED PREFLIGHT does the part that must not be improvised: align the socket, read the state
        # in one tagged reply, REFUSE a live run rather than steer it, unwind a resting streaming mode
        # through mode_exit(), clear the previous result and disarm the queued-press absorb -- the last
        # because this file resets the instrument's single global timer to time its presses, and that
        # timer is the only record of WHEN a recording ended, so a stale arm swallows the first press it
        # measures. See tools/bench_sync.py.
        BS.preflight(self.d, 'bench_panel')
        # What is left is this harness's own resting condition: nothing pinned, page 0.
        self.setup("sdec.ui_page = 0 "
                   "sdec.force_baud, sdec.force_nbits = nil, nil "
                   "sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil "
                   "pcall(function() sdec.ui_refresh() end)")


def num(v, default=None):
    if v is None or v == 'nil':
        return default
    try:
        return float(v)
    except ValueError:
        return default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reuse', action='store_true',
                    help='drive the app already running; do NOT reload the modules. Required '
                         'once the one UI build of this power cycle has been spent -- reloading '
                         'nils sdec and strands every display object it owns.')
    ap.add_argument('--shots', help='directory for a front-panel PNG either side of every press')
    ap.add_argument('--json', help='write the full per-press record here')
    ap.add_argument('--no-sdg', action='store_true')
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--slow-baud', type=int, default=2400,
                    help='a second, much slower rate -- the mode cycle and a recording press must '
                         'behave identically at both')
    ap.add_argument('--page-baud', type=int, default=250000,
                    help='a rate whose capture spans more than one hex page')
    a = ap.parse_args()

    shots = None
    if a.shots:
        shots = os.path.expanduser(a.shots)
        os.makedirs(shots, exist_ok=True)
        print('panel grabs -> %s' % shots)

    g = None
    if not a.no_sdg:
        from siglent import SDG
        g = SDG()
        print('SDG: %s' % g.idn())
        g.select_arb(VN.arb('v41'), 10.0, a.baud * 10)
        g.output(True, ch=1)
        print('playing v41 at %d baud (SRATE %d)' % (a.baud, a.baud * 10))
        time.sleep(0.4)

    d = DMM()
    rc = 0
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        if not a.reuse:
            RA.load_app(d)
            d.drain()
            d.send('local ok, why = sdec.start() '
                   'print(string.format("START ok=%s why=%s", tostring(ok), tostring(why)))')
            print('  ' + str(d.line(120)))
        else:
            live = d.q('print(tostring(sdec ~= nil and sdec.built))')
            print('reusing the running app (sdec.built = %s)' % live)
            if live != 'true':
                print('REFUSED: no built app on the instrument. Drop --reuse to load one.')
                return 2
        for ln in d.load_script('bpmod', PRESS_TSP, timeout=120):
            if ln and ln != '===DONE===':
                print('  bpmod: ' + ln)
        d.exec('localnode.showevents = eventlog.SEV_ERROR')

        p = Panel(d, shots)
        print('\n%.2f s budget per press, %.1f s for the handlers that take a capture\n'
              % (p.budget, CAPTURE_BUDGET_S))
        run_sequence(p, g, a)

        print('\n--- summary ---')
        # A GRAB THAT DID NOT HAPPEN IS COVERAGE THAT DID NOT HAPPEN. The pixel assertions are skipped
        # when a screenshot is missing -- correctly, they would be meaningless -- so those presses report
        # on strictly less than the sweep claims. Recorded as a failure rather than left as a printed
        # line, because the whole value of this harness is that a green run means every check ran.
        if getattr(p, 'grabfails', 0):
            p.fail('screenshots', '%d panel grab(s) failed, so the display assertions for those presses '
                                  'did not run -- this sweep does not cover what it claims'
                                  % p.grabfails)
        bad = [r for r in p.rows if r['verdict']]
        print('%d presses: %d raised, %d logged an event, %d over budget, %d with no effect, '
              '%d with a stale display'
              % (len(p.rows),
                 sum(1 for r in p.rows if not r['ok']),
                 sum(1 for r in p.rows if r['events']),
                 sum(1 for r in p.rows if any('OVER' in v for v in r['verdict'])),
                 sum(1 for r in p.rows if any('NO EFFECT' in v for v in r['verdict'])),
                 sum(1 for r in p.rows if any('STALE' in v for v in r['verdict']))))
        if bad:
            print('\nFAILURES:')
            for r in bad:
                print('  %-24s %s' % (r['label'], ' | '.join(r['verdict'])))
            rc = 1
        else:
            print('every press behaved as designed and the panel showed it')
        slow = max(p.rows, key=lambda r: r['secs']) if p.rows else None
        if slow:
            print('slowest: %s at %.3f s' % (slow['label'], slow['secs']))
        if shots:
            print('%d presses grabbed before and after in %s' % (p.n, shots))
        if a.json:
            with open(os.path.expanduser(a.json), 'w') as fh:
                json.dump({'presses': p.rows, 'budget': p.budget,
                           'capture_budget': CAPTURE_BUDGET_S}, fh, indent=1)
            print('record -> %s' % a.json)

        print('\n--- residual event log (must be empty) ---')
        # THE CONTENT, NOT JUST THE COUNT. A run once ended '16' with nothing to say what they were,
        # which is a finding that cannot be acted on -- and the next stage cleared the log before
        # anyone could look.
        resid = d.q('print(tostring(eventlog.getcount()))') or '?'
        print('  count: %s' % resid)
        dump = d.q('do local s = "" local i for i = 1, eventlog.getcount() do '
                   'local n, m = eventlog.next() '
                   's = s .. string.format("[%s %s]", tostring(n), tostring(m)) end print(s) end')
        if dump and dump.strip():
            print('  %s' % dump.strip()[:600])
        for m in d.errors():
            print('  ' + str(m))
    finally:
        d.close()
        if g is not None:
            try:
                g.close()
            except Exception:
                pass
    return rc


def run_sequence(p, g, a):
    """The conditions matrix. Ordered so each block sets up the next, and every block says which
    CONDITION it is testing rather than just which button."""

    def play(baud):
        if g is None:
            return
        g.select_arb(VN.arb('v41'), 10.0, baud * 10)
        g.output(True, ch=1)
        time.sleep(0.4)

    # ---- empty state: nothing captured yet ----------------------------------------------------
    print('--- EMPTY STATE (no capture behind the panel) ---')
    p.setup('sdec.clear_result() sdec.ui_page = 0 sdec.savedas = nil '
            'sdec.force_baud, sdec.force_nbits = nil, nil '
            'sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil')
    # The status row names the view, so a View press must repaint it even with no data. And with
    # nothing decoded there is nothing to lock and nowhere to page: all three margin buttons hidden.
    p.press('View/empty', 'sdec.view_toggle',
            ('view advances', lambda b, a2: a2['view'] != b['view']),
            paints=['status'],
            buttons={'PageUp': False, 'LockRate': False, 'PageDn': False})
    p.press('PageDn/empty', 'sdec.page_next',
            ('page stays at 0 (one page)', lambda b, a2: a2['page'] == '0'),
            quiet_screen=True)
    p.press('PageUp/empty', 'sdec.page_prev',
            ('page stays at 0', lambda b, a2: a2['page'] == '0'),
            quiet_screen=True)
    # A refusal is only useful if it is VISIBLE, so this one must write the note row.
    p.press('Save/empty', 'sdec.save',
            ('declines: nothing saved', lambda b, a2: a2['saved'] == 'nil'),
            paints=['note'])
    p.press('LockRate/empty', 'sdec.lock_toggle',
            ('nothing to lock, so no rate pinned', lambda b, a2: a2['force'] == 'nil'),
            paints=['note'])

    # ---- capture, then the populated pass -----------------------------------------------------
    print('\n--- CAPTURE (the press everything else depends on) ---')
    p.to_frame()
    p.press('Capture/1-autodetect', 'sdec.capture',
            ('bytes decoded', lambda b, a2: num(a2['nf'], 0) > 0),
            paints=['fields', 'dump', 'status'])
    p.press('Capture/2-locked', 'sdec.capture',
            ('bytes decoded again', lambda b, a2: num(a2['nf'], 0) > 0),
            paints=['dump'])

    # ---- views, with data behind them ---------------------------------------------------------
    # v1 ships without midi_decode.tsp and lin_decode.tsp, so the MIDI and LIN entries in
    # ui_views are unavailable and the cycle is text <-> hex. Both must be reachable and the
    # cycle must return to where it started.
    print('\n--- VIEW cycles through every AVAILABLE view and returns ---')
    seen = [p.state()['view']]
    for k in range(4):
        _, a2 = p.press('View/%d' % (k + 1), 'sdec.view_toggle',
                        ('view advances', lambda b, a3: a3['view'] != b['view']),
                        paints=['dump', 'status'])
        seen.append(a2['view'])
    nview = len(set(seen))
    print('      views visited: %s  (%d distinct)' % (' -> '.join(seen), nview))
    if seen[nview] != seen[0]:
        print('      BAD: %d presses of a %d-view cycle did not return to %s'
              % (nview, nview, seen[0]))

    # ---- paging, at a rate whose capture really spans several pages ---------------------------
    print('\n--- PAGING (hex view at %d Bd, where a capture spans several pages) ---'
          % a.page_baud)
    play(a.page_baud)
    p.to_frame()
    p.press('Capture/for-paging', 'sdec.capture',
            ('bytes decoded', lambda b, a2: num(a2['nf'], 0) > 0))
    p.setup("sdec.ui_mode = 'hex' sdec.ui_page = 0 "
            "pcall(function() sdec.ui_refresh() end)")
    st = p.state()
    print('      hex view: %s pages for %s bytes' % (st.get('npg'), st.get('nf')))
    if num(st.get('npg'), 1) > 1:
        # With more than one page BOTH page buttons must appear -- they are shown as a pair.
        p.press('PageDn/multi', 'sdec.page_next',
                ('page advances', lambda b, a2: num(a2['page'], 0) == num(b['page'], 0) + 1),
                paints=['dump', 'status'],
                buttons={'PageUp': True, 'PageDn': True})
        p.press('PageUp/multi', 'sdec.page_prev',
                ('page goes back', lambda b, a2: num(a2['page'], 0) == num(b['page'], 0) - 1),
                paints=['dump', 'status'])
        p.press('PageUp/at-first', 'sdec.page_prev',
                ('clamps at page 0', lambda b, a2: a2['page'] == '0'),
                quiet_screen=True)
        # WALK TO THE LAST PAGE BY PRESSING, then read back where we actually are -- setting
        # ui_page from the host and trusting it is how this check ended up asserting "must not
        # repaint" while sitting on page 1 of 2, and then blaming the app for paging correctly.
        for _ in range(int(num(st.get('npg'), 1) or 1) + 1):
            p.setup('sdec.page_next() ')
        last = p.state()
        onlast = num(last.get('page'), 0) == num(last.get('npg'), 1) - 1
        print('      walked to page %s of %s%s' % (last.get('page'), last.get('npg'),
              '' if onlast else ' -- NOT the last page, so the clamp check is skipped'))
        if onlast:
            p.press('PageDn/at-last', 'sdec.page_next',
                    ('clamps at the last page',
                     lambda b, a2: num(a2['page'], 0) == num(b['page'], 0)),
                    quiet_screen=True)
    else:
        print('      only one page at this rate -- paging covered by the empty-state block only')
    p.setup("sdec.ui_mode = 'text' sdec.ui_page = 0 "
            "pcall(function() sdec.ui_refresh() end)")

    # ---- lock, in each of its three states ----------------------------------------------------
    print('\n--- LOCK RATE, in each of its three lock states ---')
    play(a.baud)
    st = p.state()
    print('      lock state is %r, force_baud %s' % (st.get('lock'), st.get('force')))
    if st.get('lock') == 'locked':
        # Reachable over the socket but NOT from the panel: the button hides itself when locked,
        # precisely so a control labelled 'Lock Rate' can never unlock. That the handler toggles
        # is by design; that the button is absent is what makes it safe, and the grab checks it.
        p.press('LockRate/locked-hidden', 'sdec.lock_toggle',
                ('the handler unlocks (only reachable off-panel)',
                 lambda b, a2: a2['force'] == 'nil'),
                buttons_before={'LockRate': False})
    p.setup('sdec.force_baud = nil')
    p.press('LockRate/auto', 'sdec.lock_toggle',
            ('pins the detected rate', lambda b, a2: a2['force'] != 'nil'),
            paints=['fields'])

    # ---- NewLog and Save, with data ------------------------------------------------------------
    print('\n--- NEWLOG / SAVE with a capture behind them ---')
    p.press('NewLog', 'sdec.log_new',
            ('the log file changes', lambda b, a2: a2['log'] != b['log'] or a2['logn'] == '0'),
            paints=['note'])
    p.press('Save/full', 'sdec.save',
            ('a file is written', lambda b, a2: a2['saved'] != 'nil'),
            paints=['note'])
    b, a2 = p.press('Save/twice', 'sdec.save',
                    ('a SECOND file, under a different name',
                     lambda b2, a3: a3['saved'] != 'nil' and a3['saved'] != b2['saved']))

    # ---- mode, at BOTH rates -------------------------------------------------------------------
    # THE CYCLE IS THE SAME AT EVERY RATE, and that is the property worth pinning. Nothing here is
    # rate-dependent: the two recording modes differ only in window size and both work wherever a
    # rate is locked, so a cycle that skips one, or offers a fourth, is the regression to catch.
    #
    # STILL RUN AT TWO RATES, because "the same everywhere" is only worth asserting somewhere it
    # could differ.
    for baud in (a.baud, a.slow_baud):
        p.to_frame()
        play(baud)
        p.press('Capture/lock-%d' % baud, 'sdec.capture',
                ('bytes decoded and the rate locked',
                 lambda b2, a3: num(a3['nf'], 0) > 0 and a3['force'] != 'nil'))
        st = p.state()
        print('\n--- MODE cycle at %s Bd locked (expects frame -> sml -> med -> frame) ---'
              % st.get('force'))
        p.setup("sdec.capmode = 'frame' pcall(function() sdec.ui_refresh() end)")
        modes = ['frame']
        for k in range(3):
            _, a3 = p.press('Mode/%d@%d' % (k + 1, baud), 'sdec.mode_cycle',
                            ('mode advances', lambda b2, a4: a4['mode'] != b2['mode']),
                            paints=['title'])
            modes.append(a3['mode'])
        print('      modes visited: %s' % ' -> '.join(modes))
        if modes != ['frame', 'sml', 'med', 'frame']:
            p.fail('Mode/cycle@%d' % baud,
                   'the cycle visited %s -- every rate must offer both windows and return to FRAME'
                   % ' -> '.join(modes))
        else:
            print('      ok: both windows offered, and FRAME is two presses away at worst')

    # ---- the run flag that no run owns --------------------------------------------------------
    # ck_running is cleared by the run that owns it, so a run that died over the LAN leaves it
    # set with nothing to clear it -- and every Capture press is then absorbed as a stop for a
    # stream that has gone. Reachable only from a fault, which is exactly why the way out has to
    # be a press: the alternative is a power cycle.
    print('\n--- A RUN FLAG LEFT BY A DEAD RUN (fault recovery) ---')
    p.to_frame()
    p.setup('sdec.ck_running, sdec.ck_stop = true, false '
            'sdec.ck_job, sdec.strm_recording = nil, nil '
            "sdec.capmode = 'med' pcall(function() sdec.ui_refresh() end)")
    p.press('Capture/latched-1', 'sdec.capture',
            ('first press asks the run to stop',
             lambda b2, a3: a3['status'] == 'stopping'))
    # The mode here is a streaming one, so the press that clears the latch carries on down the
    # streaming path rather than producing a frame decode. What must be true is that the panel is
    # not absorbing every press as a stop, and that it SAYS a fault was detected.
    p.press('Capture/latched-2', 'sdec.capture',
            ('the unanswered request clears the latch',
             lambda b2, a3: a3['status'] != 'stopping'),
            paints=['note'])
    p.to_frame()
    p.setup('sdec.stickyerr = nil')
    p.setup('sdec.ck_running, sdec.ck_stop = true, false '
            'sdec.ck_job, sdec.strm_recording = nil, nil '
            "sdec.capmode = 'med' pcall(function() sdec.ui_refresh() end)")
    # STOPPING A RUN KEEPS THE MODE, so this asserts the stop and NOT a mode change. Expecting
    # mode == 'frame' contradicts mode_cycle's contract: its running branch stops the capture and
    # deliberately leaves capmode alone. And because the mode does not
    # change, the TITLE cannot change either -- so this one case paints the STATUS row (measured 2910 px
    # against the title's 0) while the idle transitions above paint the title. Both were reported as app
    # defects by an obsolete expectation and a mis-owned region.
    p.press('Mode/latched', 'sdec.mode_cycle',
            ('Mode stops the run and stays in its selected mode',
             lambda b2, a3: a3['mode'] == 'med' and a3['status'] == 'stopped'),
            paints=['status'])
    p.setup('sdec.stickyerr = nil pcall(function() sdec.ui_refresh() end)')

    # ---- Capture in a recording mode: ONE press does the whole job ------------------------------
    # One press records, decodes, files it and returns -- not START, STOP and a slice per press, which
    # costs twelve presses for a full buffer. A bounded press is not the only way to stay stoppable,
    # because the front-panel TRIGGER key can stop a running handler (sdec.cancel_setup). So what this
    # checks is not "each press is small" but "one press finishes the job and leaves nothing for a
    # second press to do".
    print('\n--- CAPTURE in a recording mode: one press, whole job ---')
    p.to_frame()
    play(a.slow_baud)
    p.press('Capture/relock', 'sdec.capture',
            ('bytes decoded and the rate locked',
             lambda b2, a3: num(a3['nf'], 0) > 0 and a3['force'] != 'nil'))
    # THE SMALL WINDOW, because this is a latency test and 8 kB is a quarter of the work. The large
    # window is exercised by tools/bench_stream.py, which is about completeness rather than presses.
    p.setup("sdec.capmode = 'sml' pcall(function() sdec.ui_refresh() end)")
    st = p.state()
    p.note('8 kB: mode_suits = %s at %s Bd' % (st.get('suits'), st.get('force')))
    # THE MODE STAYS WHERE IT WAS PUT, so do not expect mode == 'frame' afterwards. A finished
    # recording that moves the operator to a mode they did not choose is a large caption in the TITLE
    # BAR changing itself. A recording mode is a SETTING; the Mode button is the only thing that moves
    # it. So the assertion is that the press recorded and filed without error and left the mode alone.
    p.press('Capture/8kB-oneshot', 'sdec.capture',
            ('one press recorded, decoded and filed it, leaving the mode as set',
             lambda b2, a3: a3['status'] != 'error' and a3['mode'] == 'sml'),
            timeout=600)
    nb = p.d.q('print(tostring(sdec.ck_tot and sdec.ck_tot.nf))')
    job = p.d.q('print(tostring(sdec.ck_job ~= nil))')
    p.note('one press produced %s bytes; job left open: %s' % (nb, job))
    if job == 'true':
        p.fail('Capture/8kB-oneshot', 'a decode job was left open -- that is a press per slice again')

    # DISARM THE ABSORB BEFORE THE NEXT CAPTURE PRESS -- and note that WAITING does not work here.
    #
    # After a recording that ended by itself, the app deliberately eats one Capture press as "the Stop
    # you queued while it was running" (sdec.strm_absorb_due). That is right for an operator and fatal
    # for this harness: the press returns in 25 ms having done nothing, and whatever it was meant to
    # test is silently untested -- which is how the cancel case below fails without a real defect.
    #
    # The window is measured with timer.gettime(), the instrument's ONE global timer -- and bp_press
    # calls timer.cleartime() at the start of every press to time it. So from the app's point of view
    # every press arrives 0 ms after the recording ended, and sleeping does not help: the sleep is
    # erased by the next press's own stopwatch. Clearing the flag is the only way through.
    p.setup('sdec.strm_stopped_by_press = nil')
    p.note('absorb disarmed (bp_press resets the shared timer, so waiting it out cannot work)')

    # ---- THE CANCEL, WITHOUT A FINGER ----------------------------------------------------------
    # The stop control is a physical key, so the honest test needs a hand -- tools/bench_cancelkey.py
    # is that test, and it is where the mechanism is measured. What can be automated is the REST of
    # the path: a firmware event reaching the blender latch mid-handler, the poll seeing it, and the
    # run winding up cleanly with the bytes it had.
    #
    # A trigger TIMER supplies that event. Measured firing 2.019 s into a 6 s busy loop, where a *TRG
    # sent at the same moment never arrived -- the command queue waits for an idle interpreter. The
    # timer is wired as a SECOND stimulus for this case only and removed afterwards, so the app's own
    # wiring is the one that ships.
    print('\n--- CANCEL: a firmware event mid-handler stops the run and keeps the bytes ---')
    p.setup("sdec.capmode = 'med' pcall(function() sdec.ui_refresh() end)")
    armed = p.setup(
        "trigger.timer[1].reset() "
        "trigger.timer[1].delay = 4 "
        "trigger.timer[1].count = 1 "
        "trigger.timer[1].start.generate = trigger.OFF "
        "trigger.timer[1].start.seconds = 0 "
        "trigger.timer[1].start.fractionalseconds = 0 "
        "trigger.blender[sdec.cancel_blender].stimulus[2] = trigger.EVENT_TIMER1 "
        "trigger.timer[1].clear() "
        "trigger.timer[1].enable = trigger.ON")
    if armed:
        p.press('Capture/cancelled', 'sdec.capture',
                ('a cancel 4 s in ended the run rather than the app',
                 lambda b2, a3: a3['status'] != 'error'), timeout=600)
        cancelled = p.d.q('print(tostring(sdec.ck_cancel))')
        cnb = p.d.q('print(tostring(sdec.ck_tot and sdec.ck_tot.nf))')
        p.note('cancel seen: %s;  bytes kept: %s' % (cancelled, cnb))
        if cancelled != 'true':
            p.fail('Capture/cancelled',
                   'the run did not see the cancel -- it finished on its own, so this press '
                   'tested nothing')
        elif num(cnb, 0) < 1:
            p.fail('Capture/cancelled',
                   'the cancel threw away every byte -- a stop must keep what it captured')
    p.setup("trigger.timer[1].enable = trigger.OFF "
            "trigger.blender[sdec.cancel_blender].stimulus[2] = trigger.EVENT_NONE "
            "trigger.timer[1].reset()")
    p.press('Mode/rec-exit', 'sdec.mode_cycle',
            ('no run flag survives the press',
             lambda b2, a3: a3['status'] != 'stopping'), paints=['title'])
    p.to_frame()

    # ---- options screen ------------------------------------------------------------------------
    # A screen SWAP is verified from the grabs: it replaces the whole content area, so the dump
    # and status regions must both change. There is no state field to ask (see bp_state).
    #
    # WHICH BUTTONS LEAVE THE SCREEN IS PART OF THE CONTRACT. Apply and Cancel leave; Auto Detect
    # leaves too, because it ends in options_apply; Lock Detected STAYS, so the form can be read
    # after it. Each is re-opened only where the previous press actually left.
    print('\n--- OPTIONS SCREEN: open, each of its four buttons, and back ---')
    play(a.baud)
    p.press('Options/open', 'sdec.options', None, paints=['dump', 'status'], swap=True)
    p.press('Opt:Cancel', 'sdec.options_cancel', None, paints=['dump', 'status'], swap=True)
    p.press('Options/open2', 'sdec.options', None, paints=['dump', 'status'], swap=True)
    p.press('Opt:Apply', 'sdec.options_apply',
            ('applies and captures', lambda b2, a3: num(a3['nf'], 0) > 0),
            paints=['dump'], swap=True)
    # Lock Detected needs a decode to lock ONTO. Apply has just taken one, so the rate is there.
    p.press('Options/open3', 'sdec.options', None, paints=['dump', 'status'], swap=True)
    p.press('Opt:LockDetected', 'sdec.options_lock',
            ('pins the detected rate', lambda b2, a3: a3['force'] != 'nil'))
    # Still on the options screen: Lock Detected does not leave. Auto Detect does.
    p.press('Opt:AutoDetect', 'sdec.options_auto',
            ('re-derives the rate from a fresh capture, so nothing stale is pinned',
             lambda b2, a3: a3['force'] == a3['baud'] and a3['baud'] != 'nil'), swap=True)

    # ---- and a capture after all that, to prove the panel is still usable ----------------------
    print('\n--- AFTER EVERYTHING: the app must still capture ---')
    p.to_frame()
    p.press('Capture/final', 'sdec.capture',
            ('bytes decoded', lambda b2, a3: num(a3['nf'], 0) > 0),
            paints=['dump', 'fields'])
    p.press('View/final', 'sdec.view_toggle',
            ('view advances', lambda b2, a3: a3['view'] != b2['view']),
            paints=['dump', 'status'])


if __name__ == '__main__':
    sys.exit(main())

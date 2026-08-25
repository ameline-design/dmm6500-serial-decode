#!/usr/bin/env python3
"""Regrab every front-panel PNG the manual ships, in one pass over ONE app build.

WHY IT IS A TOOL. The manual's ten images are the app's own screen, so every panel change makes all
ten stale at once -- and the S/N cell added a column to the top line of eight of them. Reaching those
states by hand costs a bench visit each time and lands on whatever the app happened to show; here the
state is driven, checked, and the same states come back on the next build.

THE PANEL STATE IS PRINTED BESIDE EVERY SHOT, and that is the point rather than a convenience. The
captions quote numbers off the screen -- 'ERR reads 15', 'page 4 of 35' -- so a caption carried over
to a regrabbed image is a claim about a picture nobody read. Write the captions from this log.

TWO SHOTS ARE STOCHASTIC. A capture that begins mid-byte is what panel-text and panel-errors are
for, and the app arms on a busy line, so it lands wherever the traffic is: roughly one capture in
eight starts mid-byte. Both are retried until the capture has the shape the caption needs, and a shot
that never gets it is reported as missing rather than filled with the wrong screen.

ORDERED BY VALUE, BECAUSE THE WINDOW IS SHORT. The frame shots are seconds each and cover the top
line, which is what changed; the recordings cost about 30 s and 2 minutes of decode. --budget-min
stops before starting a shot it cannot finish, so a cut-off loses the cheapest information last.

IT RESTORES capmode AND ui_mode ON THE WAY OUT. A recording mode left set is inherited by the next
tool on this socket, and the next tool has no reason to check -- see notes on leftover app state.

    python3 tools/doc_shots.py                          # every shot, into docs/img
    python3 tools/doc_shots.py --only panel-hex,options  # just these
    python3 tools/doc_shots.py --out ~/tmp/shots --budget-min 8
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_matrix as BM
import screenshot as SS
import vector_names as VN
from dmmrun import DMM
from siglent import SDG

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMGDIR = os.path.join(ROOT, 'docs', 'img')

# The clean 1 kB non-repeating text payload the manual's captures are of, at the rate its captions
# quote. Non-repeating matters for a screenshot the same way it matters for a test: a decode that
# resynchronised in the wrong place cannot accidentally look right.
SHOT_ARB = 'v71'
SHOT_BAUD = 9600
SHOT_SWING = 3.3

# One shot per manual image. `mode` is sdec.capmode, `view` is sdec.ui_mode, `want` is the capture
# shape the caption needs: 'clean' = framed from the start with nothing flagged, 'head' = began
# mid-byte, None = whatever this capture gave.
SHOTS = [
    ('panel-hex',              'frame', 'hex',  'clean', 'the main screen, hex view'),
    ('panel-text',             'frame', 'text', 'head',  'text view, a mid-byte start'),
    ('panel-errors',           'frame', 'hex',  'head',  'hex view of a mid-byte start'),
    ('panel-hex-note',         'frame', 'hex',  'head',  'the note row naming the head'),
    ('options',                'frame', None,   None,    'the options form'),
    ('panel-recording',        'sml',   'text', None,    'an 8 kB recording, part way through'),
    ('panel-after-recording',  'sml',   'text', None,    'after an 8 kB recording, Mode pressed once'),
    ('panel-paged',            'med',   'hex',  None,    'a finished 32 kB recording, hex, paged in'),
    ('panel-paged-text',       'med',   'text', None,    'the same recording in text view'),
]

# What each shot costs once the app is up, measured on the bench: a frame capture and its grab is a
# few seconds, an 8 kB recording ~35 s of decode, a 32 kB one about two minutes. Used only to decide
# whether to START a shot, so the budget cannot be overrun by a shot already running.
COST_S = {'frame': 12.0, 'sml': 45.0, 'med': 150.0}

DS_TSP = r'''
-- One panel action, then the state the captions are written from. The state read is the app's own,
-- not a re-derivation: a caption has to agree with what the operator sees.
--
-- EVERY DERIVED FIGURE COMES OUT OF A pcall INTO A LOCAL, which is the same idiom mx_point uses. Lua
-- 5.0.2 has no select(), so pcall's second return cannot be picked off inline, and these are exactly
-- the calls that can raise on a capture that refused -- which is a state worth being able to grab.
function ds_state(tag)
  local r = sdec.res
  local fmt, errn, npg = '?', '?', '?'
  pcall(function() fmt = sdec.fmt_text() end)
  pcall(function() errn = sdec.ui_err_n() end)
  pcall(function() npg = sdec.ui_npages() end)
  print(string.format('DS %s baud=%s fmt=%s nf=%s nbad=%s err=%s head=%s fit=%s sn=%s ' ..
                      'view=%s capmode=%s page=%s npages=%s paged=%s',
                      tostring(tag), tostring(sdec.baud), tostring(fmt),
                      tostring(r and r.nf), tostring(r and r.nbad), tostring(errn),
                      tostring(r and r.headsusp), tostring(sdec.fitq), tostring(sdec.snr_db),
                      tostring(sdec.ui_mode), tostring(sdec.capmode),
                      tostring(sdec.ui_page), tostring(npg), tostring(sdec.ui_paged)))
  -- THE NOTE LINE ITSELF, on its own line: it contains spaces, and the caption quotes it verbatim.
  -- ui_note is the display OBJECT; ui_note_text() is the string, and it is built rather than stored.
  local note = ''
  pcall(function() note = sdec.ui_note_text() end)
  print('DSNOTE ' .. tostring(note))
  print('DS end')
end

function ds_call(tag, fn)
  local ok, err = pcall(fn)
  print('DS call ' .. tostring(tag) .. ' ok=' .. tostring(ok) .. ' err=' .. tostring(err))
  ds_state(tag)
end

-- FORCED SETTINGS CLEARED ONCE, at the start. This file may run after bench_smoke, whose rate cases
-- deliberately leave a lock the wire contradicts -- and a screenshot taken under one of those is a
-- picture of a wrong answer captioned as an ordinary capture. Cleared rather than assumed: the app
-- then auto-detects and locks by itself, which is the flow the manual describes.
function ds_unforce()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  print('DS unforce')
  ds_state('unforce')
end

-- capmode AND ui_mode SET DIRECTLY rather than by cycling the buttons. Mode and View are cycles, so
-- reaching '32 kB hex' by pressing is 2 and 1 presses from wherever the app happens to be -- and a
-- miscount lands on a different mode and grabs a screen captioned as another one. bench_panel.py
-- tests the cycling; this file needs the destination.
function ds_setmode(m, v)
  sdec.capmode = m
  if v ~= nil and v ~= '' then sdec.ui_mode = v end
  local ok, err = pcall(function() sdec.ui_refresh() end)
  print('DS setmode ' .. tostring(m) .. '/' .. tostring(v) .. ' ok=' .. tostring(ok))
  ds_state('setmode')
end
'''


def read_state(d, timeout=300):
    """Everything the instrument printed for one ds_call. -> (fields dict, note, lines)."""
    fields, note, lines = {}, '', []
    while True:
        ln = d.line(timeout)
        if ln is None:
            return fields, note, lines + ['<timeout>']
        lines.append(ln)
        if ln.startswith('DSNOTE '):
            note = ln[7:].strip()
        elif ln.startswith('DS ') and '=' in ln:
            for kv in ln.split()[2:]:
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    fields[k] = v
        elif ln == 'DS end':
            return fields, note, lines


def num(fields, key):
    v = fields.get(key)
    if v is None or v == 'nil':
        return None
    try:
        return float(v)
    except ValueError:
        return None


def call(d, tag, fn, timeout=300):
    d.drain()
    d.send('ds_call(%r, %s)' % (tag, fn))
    return read_state(d, timeout)


def shape_ok(want, fields):
    """Does this capture have the shape the caption needs? -> bool."""
    head, nf = num(fields, 'head'), num(fields, 'nf')
    if nf is None or nf < 1:
        return False
    if want == 'clean':
        # NOTHING FLAGGED AND NO HEAD. err is what the ERR cell shows, which is the number a caption
        # would quote, so it is the one checked -- not r.nbad, which excludes the head region.
        return (head is None or head == 0) and (num(fields, 'err') or 0) == 0
    if want == 'head':
        return head is not None and head > 0
    return True


def grab(path, tries=3):
    """One PNG. -> True if written. The LCD lags the handler's return, hence the settle."""
    time.sleep(0.35)
    for k in range(tries):
        try:
            SS.capture(path)
            return True
        except Exception as e:                                       # noqa: BLE001
            print('      grab failed (%d/%d): %s' % (k + 1, tries, e))
            time.sleep(1.0)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=IMGDIR)
    ap.add_argument('--only', help='comma-separated shot names')
    ap.add_argument('--budget-min', type=float, default=20.0)
    ap.add_argument('--retries', type=int, default=12,
                    help='attempts at a stochastic capture shape (default 12; a mid-byte start is '
                         'about one capture in eight)')
    ap.add_argument('--settle', type=float, default=0.6)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    want = [s.strip() for s in a.only.split(',')] if a.only else [s[0] for s in SHOTS]
    todo = [s for s in SHOTS if s[0] in want]
    unknown = [w for w in want if w not in [s[0] for s in SHOTS]]
    if unknown:
        raise SystemExit('unknown shot(s): %s; have %s'
                         % (', '.join(unknown), ', '.join(s[0] for s in SHOTS)))

    g, d = SDG(), DMM()
    deadline = time.time() + a.budget_min * 60.0
    got, missed = [], []
    try:
        d.load_script('dsdefs', DS_TSP)
        d.drain()
        d.send('ds_unforce()')
        read_state(d, timeout=60)
        g.select_arb(VN.arb(SHOT_ARB), BM.amp_for(SHOT_SWING), BM._srate(SHOT_ARB, SHOT_BAUD))
        g.output(True, ch=1)
        time.sleep(a.settle)
        print('stimulus: %s at %d Bd, %.1f V swing\n' % (SHOT_ARB, SHOT_BAUD, SHOT_SWING))

        for name, mode, view, shape, why in todo:
            left = deadline - time.time()
            if left < COST_S[mode]:
                # SAID OUT LOUD. A shot silently skipped for time reads afterwards as a shot that
                # was not needed, and the stale image stays in the manual with nobody knowing.
                print('%-22s SKIPPED -- %.0f s left, this shot needs about %.0f'
                      % (name, left, COST_S[mode]))
                missed.append((name, 'out of budget'))
                continue
            print('=== %-20s %s' % (name, why))
            d.drain()
            d.send('ds_setmode(%r, %r)' % (mode, view or ''))
            read_state(d)

            if name == 'options':
                # NO CAPTURE. The form is reached from whatever is on screen, and it is grabbed and
                # then CANCELLED rather than applied -- Apply ends in a capture (options_apply), so
                # applying here would leave the next shot's state decided by this one.
                call(d, 'options', 'sdec.options')
                ok = grab(os.path.join(a.out, name + '.png'))
                call(d, 'options-cancel', 'sdec.options_cancel')
                (got if ok else missed).append((name, 'grabbed' if ok else 'grab failed'))
                continue

            if mode == 'frame':
                fields, note, _ = {}, '', None
                for attempt in range(a.retries):
                    fields, note, _ = call(d, name, 'sdec.capture')
                    if shape_ok(shape, fields):
                        break
                    print('      attempt %d: head=%s err=%s nf=%s -- not the shape wanted (%s)'
                          % (attempt + 1, fields.get('head'), fields.get('err'),
                             fields.get('nf'), shape))
                if not shape_ok(shape, fields):
                    print('%-22s NO SUITABLE CAPTURE in %d attempts' % (name, a.retries))
                    missed.append((name, 'never got a %r capture' % shape))
                    continue
                ok = grab(os.path.join(a.out, name + '.png'))
                print('      nf=%s err=%s head=%s fit=%s S/N=%s dB  note: %s'
                      % (fields.get('nf'), fields.get('err'), fields.get('head'),
                         fields.get('fit'), fields.get('sn'), note))
                (got if ok else missed).append((name, 'nf=%s err=%s head=%s sn=%s'
                                                % (fields.get('nf'), fields.get('err'),
                                                   fields.get('head'), fields.get('sn'))))
                continue

            # A RECORDING. panel-recording has to be grabbed WHILE the decode runs, so the call is
            # sent and the grab taken over the LXI interface without waiting for the reply -- the
            # screen grab does not travel on this socket, which is what makes that possible at all.
            if name == 'panel-recording':
                d.drain()
                d.send('ds_call(%r, %s)' % (name, 'sdec.capture'))
                time.sleep(min(12.0, COST_S[mode] / 3.0))
                ok = grab(os.path.join(a.out, name + '.png'))
                fields, note, _ = read_state(d, timeout=600)
                print('      mid-run grab; the run then finished nf=%s' % fields.get('nf'))
                (got if ok else missed).append((name, 'mid-run, nf=%s' % fields.get('nf')))
                continue

            fields, note, _ = call(d, name, 'sdec.capture', timeout=600)
            if name == 'panel-after-recording':
                # ONE Mode PRESS, which is what the caption says: it lines up the next recording and
                # is the state an operator is actually left looking at.
                fields, note, _ = call(d, name + '-mode', 'sdec.mode_cycle')
                ok = grab(os.path.join(a.out, name + '.png'))
                (got if ok else missed).append((name, 'capmode now %s' % fields.get('capmode')))
                continue

            # PAGED IN, not page 1: the caption is about the page indicator, and page 1 of n does not
            # show that paging happened. Three presses in, or as far as the capture allows.
            npg = num(fields, 'npages') or 1
            for _ in range(min(3, int(npg) - 1)):
                fields, note, _ = call(d, name + '-page', 'sdec.page_next')
            ok = grab(os.path.join(a.out, name + '.png'))
            print('      page %s of %s, nf=%s' % (fields.get('page'), fields.get('npages'),
                                                  fields.get('nf')))
            (got if ok else missed).append((name, 'page %s of %s'
                                            % (fields.get('page'), fields.get('npages'))))
    finally:
        # BOTH BACK, WHATEVER HAPPENED. A 32 kB capmode left behind makes the next tool's first
        # Capture a two-minute recording it never asked for.
        try:
            d.drain()
            d.send("ds_setmode('frame', 'text')")
            read_state(d, timeout=60)
        except Exception as e:                                        # noqa: BLE001
            print('COULD NOT RESTORE capmode/ui_mode: %s -- the next tool inherits %s' % (e, 'them'))
        d.close()

    print()
    for name, det in got:
        print('  ok      %-22s %s' % (name, det))
    for name, det in missed:
        print('  MISSING %-22s %s' % (name, det))
    print('\n%d of %d shots in %s' % (len(got), len(todo), a.out))
    return 1 if missed else 0


if __name__ == '__main__':
    sys.exit(main())

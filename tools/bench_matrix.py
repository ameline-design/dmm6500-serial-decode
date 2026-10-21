#!/usr/bin/env python3
"""Characterise the app THROUGH ITS OWN Capture button: formats, rates, logic levels, DC offsets.

WHY NOT bench_uart.py. That harness calls sdec.acquire() and sdec.decode() directly, which is the
decoder but not the application: it never exercises pick_fs, the two-pass auto-detect, autolock, the
notes or the panel fields. Everything the operator actually reads comes from sdec.capture(), so
that is what this presses -- once per test point, with the UI built exactly as it ships.

FOUR SUITES, and each answers a question the offline suite cannot:

  formats   7E1 / 7O1 / 8E1 / 8O1 / 8N2 off the wire, with 8N1 as the both-sides control for the
            7E1 ambiguity (same frame length; only whether bit 7 is data or parity differs).
            8N2 must decode byte-exact and REPORT 8N1 -- a second stop bit is a bit time of idle.
  rates     one waveform replayed at N sample rates (baud = SRATE / samples_per_bit), unlocked
            before each point so every rate is a fresh in-app auto-detect.
  levels    5 V TTL, 3V3 CMOS and a 1.6 V swing. amp = 10 x Vlogic/3.3, since the vectors are
            rendered 0..3.3 V against a 5 V full scale. Checks the LOGIC and THRESH cells as well
            as the bytes -- a wrong family name is how a probe on the wrong pin gets spotted.
  offsets   the same swings riding on a DC offset, which is the case a bench signal actually
            presents. Bounded by BOTH instruments: |OFST| + AMP/2 <= 10 V at the generator, and
            the DMM is fixed on the 10 V range so the whole band must sit inside +/-10 V.

    python3 tools/bench_matrix.py --suites formats,rates,levels,offsets
    python3 tools/bench_matrix.py --suites formats --upload    # first run of a power cycle
    python3 tools/bench_matrix.py --no-start                   # reuse the app already on screen
    python3 tools/bench_matrix.py --shots ~/tmp/appshots       # PNG of the panel per point
"""
import argparse
import csv
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG
import bench_uart as BU
import soakplan as SP                                       # noqa: E402
import bench_sync as BS
import run_app as RA
import screenshot as SS
import vector_names as VN                                     # noqa: E402

# The vectors are rendered 0..3.3 V against a 5 V full scale, so AMP scales the swing linearly and
# the low level stays at 0 V. amp = 10 * swing / 3.3.
FS_VOLTS = 5.0
NOMINAL_SWING = 3.3


def amp_for(swing):
    return round(10.0 * swing / NOMINAL_SWING, 3)


# Generator ceiling: the DAC spans AMP centred on OFST, so |OFST| + AMP/2 must fit 10 V (Hi-Z).
# DMM ceiling: fixed 10 V range, so the signal band [OFST, OFST+swing] must fit inside +/-10 V.
def offset_limit(swing):
    return min(10.0 - amp_for(swing) / 2.0, 10.0 - swing)


FORMATS = [('v41', '8N1', 'the control -- must NOT be called 7E1'),
           ('v44a', '7E1', 'same frame length as 8N1'),
           ('v44b', '7O1', ''),
           ('v44c', '8E1', ''),
           ('v44d', '8O1', ''),
           ('v44e', '8N1', 'sent as 8N2 -- the extra stop bit is idle')]
FORMAT_BAUD = 9600
# How far the app's REPORTED baud may sit from the commanded one. Matches sdec.snaptol, which is the
# app's own promise: it snaps a measured rate to its ladder only within 2 %. Exceeding it is a REAL
# failure and counts as one -- byte-exact content does not prove the rate was right, because
# uart_decode.tsp records that 9600 7N1 can be bit-identical to 4800 8N1. It is reported as its own
# verdict (BAUD) rather than as a wrong decode, so the two faults stay distinguishable.
RATE_TOL = 0.02
# How much of a waveform may be inconclusive before the waveform itself counts as a failure. An
# individual undecidable cell is neutral, but a vector that is never READ has produced no evidence and
# must not read as health. Measured over four laps: only v48a and v48b are ever undecidable, 12 cells
# each across 172, and no more than 12 of a single lap's 43 -- so 28 % is the observed ceiling and 0.75
# leaves it wide room while still catching a vector that has gone silent at nearly every rate.
INCONC_MAX_FRAC = 0.75
# DERIVED FROM THE MANIFEST, NOT WRITTEN DOWN. Every clean vector renders at 10 samples per bit
# and every impairment vector at 100, so a rate copied into this file is a rate that goes stale
# the next time the render regime changes -- and it goes stale QUIETLY: a hard-coded 100000 plays
# a 10-samples-per-bit vector at 10000 Bd while every label still says 9600, which is 4.2 % off
# and past the 2 % the suites themselves demand. Read it instead.
def _srate(vid, baud):
    return int(round(baud * int((manifest().get(vid) or {}).get('spb') or 10)))


def _spb(vid):
    return float(int((manifest().get(vid) or {}).get('spb') or 10))


def vspan(vid):
    """The vector's rendered p-p span in volts at its reference amplitude, from the manifest.

    Paired with _amp so a cell's DRIVEN span is vspan(vid) * camp / _amp(vid) -- what a scope reads,
    which is the figure a failure has to be correlated against. The generator amplitude alone does not
    say it: the same 20 Vpp gives 9.3 V on the spike vector and 6.6 V on a 3.3 V line.
    """
    r = manifest().get(vid) or {}
    return float(r.get('max_v') or 0.0) - float(r.get('min_v') or 0.0)


def _amp(vid):
    """The AMP a vector is rendered for, from the manifest.

    NOT A CONSTANT, and four of the 41 prove it: the spike vector wants 20 Vpp because its transients
    stack to 9.3 V, and the three LIN vectors want 15 for a 6 V bus. Playing those at the nominal 10
    halves or two-thirds their swing, so the decoder is judged on a signal it was never shown -- and
    it fails honestly, which makes the harness look like the app.
    """
    return float((manifest().get(vid) or {}).get('amp_vpp') or 10.0)

RATE_ARB = 'v41'             # 'Hello, World!' 8N1, x10 like every clean vector
RATE_SPB = 10.0
RATES = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 250000]

# The family names sig_family() gives. 1.6 V sits exactly ON its 1V8 boundary (hi >= 1.6), and the
# measured high comes in at 1.59, so BOTH names are correct answers there -- the fallback '1.6Vpp'
# states the swing, which is the honest thing to say about a level that is not a named family.
#
# THE THREE LOW ENTRIES ARE THE CLAIMED FLOOR AND THE MARGIN UNDER IT. The docs claim 0.5 V to 8 V, so
# 1.0 and 0.5 test the claim and 0.25 tests that it has room beneath it -- a floor with nothing below it
# measured is a guess. Offline the app decodes byte-exact down to 0.12 V, which is what makes 0.25 a
# reasonable thing to demand of the bench rather than a stunt.
#
# BELOW 1.6 V sig_family HAS NO NAME and falls through to its '%.1fVpp' fallback, so the expected
# string IS the measured swing to one decimal -- and the analog path does not deliver the requested
# swing exactly, so each entry accepts the neighbouring tenth on either side. Accepting a wider set
# than that would stop the check being a check: at these levels the family cell is the only thing
# asserting the app measured the swing it was given.
LEVELS = [(5.0, ['5V TTL']), (3.3, ['3V3 CMOS']), (1.6, ['1V8 CMOS', '1.6Vpp']),
          (1.0, ['0.9Vpp', '1.0Vpp', '1.1Vpp']),
          (0.5, ['0.4Vpp', '0.5Vpp', '0.6Vpp']),
          # THE PUBLISHED FLOOR ITSELF. 0.25 already passes below it, which is the margin, but a claimed
          # limit should be a tested point rather than an interpolation between two tested ones.
          (0.33, ['0.3Vpp', '0.4Vpp']),
          (0.25, ['0.2Vpp', '0.3Vpp'])]

# THE LOREM SWEEP. SER_Lorem1kB_8N1 (v71) is a 1024-byte non-repeating payload rendered at 10 samples
# per bit like every other clean vector, so replaying it at SRATE = baud * 10 gives any rate off ONE
# stored waveform. The samples-per-bit figure is READ FROM THE MANIFEST rather than written here; see
# the note on _srate for what a copied one costs. No upload, which is the point: large WVDT writes are
# the wedge hazard and the budget is about two per power cycle.
#
# Better than the 13-byte 'Hello, World!' in two ways that matter: a 240-byte capture is a SUBSTRING
# of the payload rather than eighteen repeats of it, so a decode that resynchronised in the wrong
# place cannot accidentally match; and the byte values are real varied text, which is what the
# format search and the parity refinement actually have to cope with.
LOREM_ARB = 'v71'
# LOREM_SPB comes from _spb(LOREM_ARB); see the note on _srate.

PAYLOAD = 'Hello, World!'

# One press, reported as the panel reports it. force_* is cleared per point so each is a real
# auto-detect: autolock latches the rate after a capture, and a stale lock would make every later
# point a measurement of the FIRST point's rate.
MATRIX_TSP = r'''
function mx_point(unlock, tag)
  -- A TAGGED OPENER, BEFORE ANY PAYLOAD LINE. The A/H/N lines carry no tag of their own, and they are
  -- printed BEFORE the M result line that names the point -- so on their own the host cannot tell which
  -- conversation they belong to. A previous call that the host abandoned mid-block leaves such lines with
  -- no terminator, and they would be accumulated into the NEXT point's hex and notes. With a begin marker
  -- the host can discard everything until its own opener appears.
  print('M begin ' .. tostring(tag))
  eventlog.clear()
  if unlock then
    sdec.force_baud, sdec.force_nbits = nil, nil
    sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  end
  -- DISARM THE QUEUED-PRESS ABSORB BEFORE TAKING THE TIMER, and this is not tidiness. The instrument has
  -- ONE global timer, and strm_absorb_arm() uses it as the TIMESTAMP for "a recording just ended, so the
  -- next Capture press is that run's Stop" -- while strm_stopped_by_press is only a boolean saying armed.
  -- Clearing the timer here therefore makes an arm from MINUTES ago look like it happened just now:
  -- strm_absorb_due() reads ~0, capture() returns WITHOUT CAPTURING, and this function then reports the
  -- panel's PREVIOUS result as this point's answer.
  --
  -- That is measured, not hypothetical: it filed a good vector (v41) as BAD -- "no bytes decoded", then
  -- "720 B, 8N1, 0 bad" -- on the lap after each soak recording lap, quoting the recording's own tail. The
  -- gap between laps is many seconds, which is why the 1 s absorb window seemed to exonerate it; the gap
  -- is irrelevant when the host resets the clock the window is measured against.
  sdec.strm_stopped_by_press = nil
  timer.cleartime()
  local ok = sdec.capture()
  local t = timer.gettime()
  local r = sdec.res
  local fmt = '?'
  pcall(function() fmt = sdec.fmt_text() end)
  -- fam and idle can CONTAIN A SPACE ('5V TTL', '3V3 CMOS'), and the M line is whitespace-split
  -- on the host, so they go on their own lines. Reading '5V TTL' as fam='5V' made every level
  -- point fail against a correct panel.
  print('A fam ' .. tostring(sdec.family))
  print('A idle ' .. tostring(sdec.idle))
  print('A err ' .. tostring(sdec.lasterr))
  -- sn AND nv TRAVEL WITH EVERY POINT, not just the levels suite. They are the app's own measurement
  -- of the noise on the line it just decoded, so carrying them here is what makes a soak lap a
  -- measurement of S/N against swing against outcome rather than three separate runs.
  -- nread TRAVELS TOO, because with fs it is the CAPTURE GEOMETRY the offline twin has to assume.
  -- Without it the twin's window length can only be inferred from the app's autolock note, and that note
  -- forecasts the NEXT capture rather than describing this one -- so a disagreement was attributable to
  -- nothing. acq_cap asks for sdec.n plus the pre-trigger reserve plus headroom, so a completed capture
  -- delivers about sdec.n on either path and the interesting case is the one that does not.
  --
  -- trigreq IS THE MODE THAT WAS ASKED FOR, NOT THE PATH THAT RAN, and the distinction matters here: an
  -- armed capture that never triggers falls back to acq_free and does NOT clear sdec.trigmode, so a row
  -- reading 'edge' may be a free-running capture. sdec.lasterr is where that shows, and it carries
  -- spaces, so it is not put in this key=value line.
  print(string.format('M %s ok=%s t=%.3f baud=%s fmt=%s thr=%s ' ..
                      'fs=%s nread=%s trigreq=%s ' ..
                      'nf=%s ngood=%s nbad=%s fit=%s vmin=%s vmax=%s lo=%s hi=%s ' ..
                      'head=%s ec=%s sn=%s nv=%s',
                      tostring(tag), tostring(ok), t, tostring(sdec.baud), tostring(fmt),
                      tostring(sdec.thr),
                      tostring(sdec.acq_fs), tostring(sdec.nread), tostring(sdec.trigmode),
                      tostring(r and r.nf), tostring(r and r.ngood),
                      tostring(r and r.nbad), tostring(sdec.fitq), tostring(sdec.vmin),
                      tostring(sdec.vmax), tostring(sdec.lo), tostring(sdec.hi),
                      tostring(r and r.headsusp), tostring(eventlog.getcount()),
                      tostring(sdec.snr_db), tostring(sdec.noise_v)))
  -- EVENTS PER POINT, 4915 counted separately. The panel shows error-severity events whatever
  -- localnode.showevents says, so a non-zero count here is a popup the operator would have seen.
  local n4915, nother = 0, 0
  while eventlog.getcount() > 0 do
    local en = eventlog.next()
    if en == 4915 then n4915 = n4915 + 1
    elseif en ~= 2731 and en ~= 2732 and en ~= 2728 then
      nother = nother + 1
      print('A ev ' .. tostring(en))
    end
  end
  print('A e4915 ' .. tostring(n4915))
  local nt, nn = sdec.ui_notes()
  local i
  for i = 1, nn do print('N ' .. tostring(nt[i])) end
  if r ~= nil and r.nf ~= nil and r.nf > 0 then
    local i0 = 1
    while i0 <= r.nf do
      local i1 = i0 + 47
      if i1 > r.nf then i1 = r.nf end
      local seg, k = {}, nil
      for k = i0, i1 do
        if r.errs[k] == nil then
          seg[table.getn(seg) + 1] = string.format('%02X', r.vals[k])
        else
          seg[table.getn(seg) + 1] = '??'
        end
      end
      print('H ' .. table.concat(seg))
      i0 = i1 + 1
    end
  end
  -- THE TERMINATOR CARRIES THE TAG, so the host can tell THIS point's conversation from a previous
  -- point's that arrived late. Untagged, a host that timed out while the instrument was still working
  -- left its reply in the stream and the next point read it as its own answer -- a false PASS or a
  -- false FAIL against the wrong stimulus, with no symptom either way.
  print('M end ' .. tostring(tag))
end
print('===DONE===')
'''


# PANEL GRABS. The socket reports what the app COMPUTED; only a screenshot shows what it DREW, and
# the two have diverged before (a correct decode behind a stale status row). Grabbed over the LXI
# web interface, which is a second connection to the instrument but not a second CONTROL socket --
# it cannot steal replies from the 5025 session.
SHOTS = {'dir': None, 'n': 0, 'fails': 0}


def shot(tag):
    if SHOTS['dir'] is None:
        return None
    SHOTS['n'] += 1
    path = os.path.join(SHOTS['dir'], '%03d_%s.png' % (SHOTS['n'], _slug(tag)))
    try:
        SS.capture(path)
        return path
    except Exception as e:
        SHOTS['fails'] += 1
        print('      screenshot failed: %s' % e)
        return None


def _slug(s):
    return ''.join(c if (c.isalnum() or c in '.+-') else '_' for c in str(s))


def press(d, tag, unlock=True, timeout=240):
    """One Capture press. Returns (fields dict, hex string, notes list).

    NONCE'D, so a late reply cannot be scored against the wrong stimulus. The tag sent to the instrument
    is unique to this call and echoed on both the result line and the terminator; anything arriving with
    a different tag is a previous point's conversation and is discarded rather than parsed. Without it a
    host-side timeout leaves a whole reply in the stream and the NEXT point reads it as its own answer.
    """
    want = '%s#%s' % (tag, BS.nonce('p'))
    d.drain()
    d.send('mx_point(%s, %r)' % ('true' if unlock else 'false', want))
    res, hexs, notes, aux, evs = None, [], [], {}, []
    stale, mine = 0, False
    while True:
        ln = d.line(timeout)
        if ln is None:
            return {'fail': 'timeout'}, '', notes
        f = ln.split()
        if not f:
            continue
        # NOTHING COUNTS UNTIL OUR OWN OPENER. The payload lines (A/H/N) carry no tag and are printed
        # before the M result line, so an abandoned earlier block's leftovers are indistinguishable from
        # ours by content alone -- and merging them corrupts this point's hex and notes.
        if f[0] == 'M' and len(f) > 2 and f[1] == 'begin':
            if f[2] == want:
                mine = True
                res, hexs, notes, aux, evs = None, [], [], {}, []
            else:
                stale += 1
                mine = False
            continue
        if not mine:
            stale += 1 if f[0] == 'M' else 0
            continue
        if f[0] == 'M' and len(f) > 2 and f[1] == 'end':
            if f[2] != want:
                stale += 1
                mine = False
                continue
            if stale:
                print('      (discarded %d stale reply line(s)/block(s) before this point)' % stale)
            break
        if f[0] == 'M' and len(f) > 2 and f[1] != want:
            continue                      # a stale result line inside our block should not happen
        if f[0] == 'M' and len(f) > 2:
            res = {}
            for kv in f[2:]:
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    res[k] = v
        elif f[0] == 'H' and len(f) == 2:
            hexs.append(f[1])
        elif f[0] == 'A' and f[1] == 'ev':
            # EVERY unexpected event, not just the last. aux is a flat dict, so a second
            # 'A ev' overwrote the first and a point that logged three errors reported one.
            evs.append(' '.join(f[2:]))
        elif f[0] == 'A' and len(f) > 1:
            aux[f[1]] = ' '.join(f[2:])
        elif f[0] == 'N':
            notes.append(' '.join(f[1:]))
    out = res or {'fail': 'no result'}
    out.update(aux)
    out['evs'] = evs
    out['shot'] = shot(tag)
    return out, ''.join(hexs), notes


def num(res, key, default=None):
    """One field as a number. TSP prints an absent value as the string 'nil', which int() does
    not accept -- and a failed capture reports every field that way, so this is the normal path
    for a refused point rather than an edge case."""
    v = res.get(key)
    if v is None or v == 'nil':
        return default
    try:
        return float(v)
    except ValueError:
        return default


def want(nf):
    """Expected bytes for a capture off the LOOPING payload, as bytes for BU.analyse."""
    if nf <= 0:
        return b''
    return (PAYLOAD * (int(nf / len(PAYLOAD)) + 2)).encode()


def verdict(res, hexs):
    """Byte-exactness of one capture against the looping payload. -> (ok, detail).

    A MISALIGNED HEAD IS JUDGED AGAINST WHAT THE PANEL CLAIMS, not ignored. On a continuously
    busy line the trigger fires mid-byte and the framer cannot anchor until the first gap; the
    app detects that and says so in the note row. So when it reports headsusp = h, the test is
    that bytes h+1.. are exact -- which is precisely the claim being made. An unreported
    misalignment still fails, because then the panel is showing garbage silently.
    """
    if 'fail' in res:
        return False, 'FAIL %s' % res['fail']
    # THE APP'S OWN VERDICT IS THE FIRST TEST, and it is in the M line whether or not anything reads
    # it. sdec.capture() returns FALSE without raising when it refuses -- no locked rate for a streaming
    # mode, a buffer it could not allocate, a mode that cannot run -- and on that path the panel keeps
    # the PREVIOUS capture's bytes. So every check below could pass on leftovers that happen to match the
    # stimulus, which is exactly how a refused point reads as a byte-exact one.
    if res.get('ok') != 'true':
        return False, 'the app refused the capture (ok=%s): %s' % (
            res.get('ok'), (res.get('err') or 'no reason given'))
    nf = int(num(res, 'nf', 0))
    if nf <= 0:
        return False, 'no bytes decoded'
    # RAW headsusp HERE, DELIBERATELY, AND NOT head_damage. This function tests the APP'S OWN CLAIM:
    # it says headsusp = h, so bytes h+1.. must be exact, and the pass condition below is that the
    # whole remaining body is ONE unbroken clean run (`run >= nb`). Substituting the narrower
    # head_damage leaves the head's resync debris inside the body, which breaks that run and fails a
    # perfectly healthy capture: 'format v44e: 8N1 153 B (head 7), longest clean run 146, 0 bad
    # (0 interior)' -- zero bad bytes and still BAD. head_damage belongs at the judge_payload call
    # sites, where the judge does its own
    # alignment search and bounds a flag COUNT rather than demanding one perfect run.
    head = int(num(res, 'head', 0))
    body, nb = hexs[2 * head:], nf - head
    pos, run, bad, interior = BU.analyse(body, want(nb))
    if pos >= 0 and run >= nb and nb > 0:
        if head:
            return True, 'exact %d B after a FLAGGED %d-byte head' % (nb, head)
        return True, 'exact %d B' % nf
    return False, '%d B (head %d), longest clean run %d, %d bad (%d interior)' % (
        nf, head, run, len(bad), len(interior))


EVENTS = {'e4915': 0, 'other': 0, 'points': 0}


def note_events(res):
    n = int(num(res, 'e4915', 0) or 0)
    EVENTS['e4915'] += n
    EVENTS['points'] += 1
    evs = res.get('evs') or []
    EVENTS['other'] += len(evs)
    for e in evs:
        print('      *** unexpected event %s ***' % e)
    return n


def show(label, res, hexs, notes, extra=''):
    ok, det = verdict(res, hexs)
    print('  %-26s %-5s %-6s %-9s thr %-6s %5s Bd  %-28s %s'
          % (label, 'ok' if ok else 'BAD', res.get('fmt', '?'),
             res.get('fam', '?'), fmt_num(res.get('thr'), '%.2f'),
             fmt_num(res.get('baud'), '%.0f'), det, extra))
    n4915 = note_events(res)
    if n4915:
        print('      *** %d x event 4915 ***' % n4915)
    for n in notes:
        print('      note: %s' % n)
    return ok, det


def fmt_num(s, f):
    if s is None or s == 'nil':
        return '-'
    try:
        return f % float(s)
    except (TypeError, ValueError):
        return str(s)


def suite_formats(d, g, a, rows):
    print('\n=== FORMATS -- %d Bd, %.1f V swing, one in-app Capture each ==='
          % (FORMAT_BAUD, NOMINAL_SWING))
    for vid, expect, why in FORMATS:
        g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), _srate(vid, FORMAT_BAUD))
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, vid)
        ok, det = show('%s want %s' % (vid, expect), res, hexs, notes, why)
        got = res.get('fmt', '?')
        # The FORMAT cell may carry a stop-bit count the wire cannot show; compare the
        # data-bits-and-parity prefix, which is what is actually observable.
        fmtok = got[:3] == expect[:3]
        if not fmtok:
            print('      FORMAT MISMATCH: panel says %s, sent %s' % (got, expect))
        rows.append(('format ' + vid, ok and fmtok, '%s %s' % (got, det)))


def suite_rates(d, g, a, rows):
    rates = [int(x) for x in a.rates.split(',')] if a.rates else RATES
    print('\n=== RATES -- %s replayed at %d sample rates, auto-detect each time ==='
          % (RATE_ARB, len(rates)))
    for baud in rates:
        srate = int(baud * RATE_SPB)
        if srate > I.SDG_MAX_SRATE:
            print('  %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling' % (baud, srate))
            continue
        g.select_arb(VN.arb(RATE_ARB), amp_for(NOMINAL_SWING), srate)
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, '%dBd' % baud)
        got = fmt_num(res.get('baud'), '%.0f')
        gb = num(res, 'baud')
        err = '?' if gb is None else '%+.1f %%' % (100.0 * (gb / baud - 1.0))
        ok, det = show('%d Bd' % baud, res, hexs, notes, 'detected %s (%s)' % (got, err))
        # The detected rate has to be the rate PLAYED, not merely a decodable one.
        close = gb is not None and abs(gb / baud - 1.0) <= 0.02
        rows.append(('rate %d' % baud, ok and close, '%s %s' % (got, det)))


def suite_levels(d, g, a, rows):
    """v41 at every swing in LEVELS. LOGIC, THRESH and the reported S/N.

    THE SWING IS THE POINT, so the row carries the measured one and not the requested one: the analog
    path between the generator and the digitiser is what decides it, and a stage that only ever
    reported what it asked for could not tell a delivered 0.25 V from a delivered 0.4 V.
    """
    print('\n=== LEVELS -- v41 at %d logic swings, LOGIC / THRESH / S/N checked ===' % len(LEVELS))
    for swing, families in LEVELS:
        amp = amp_for(swing)
        g.select_arb(VN.arb('v41'), amp, _srate('v41', FORMAT_BAUD))
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, '%.2fV' % swing)
        ok, det = show('%.2f V swing (AMP %.2f)' % (swing, amp), res, hexs, notes,
                       'want %s' % '/'.join(families))
        famok = res.get('fam') in families
        if not famok:
            print('      LOGIC cell says %r, expected one of %s' % (res.get('fam'), families))
        # The threshold must land near mid-swing, which is the whole basis of the decode.
        th = num(res, 'thr')
        throk = th is not None and abs(th - swing / 2.0) <= 0.25 * swing
        # THE MEASURED SWING AND S/N, REPORTED WHETHER OR NOT THEY GATE. A small swing that fails is
        # only interesting beside the noise that was on it -- without the figure the row cannot
        # distinguish "the app cannot read 0.25 V" from "this bench cannot deliver a clean 0.25 V".
        lo, hi, sn = num(res, 'lo'), num(res, 'hi'), num(res, 'sn')
        got = None if (lo is None or hi is None) else hi - lo
        print('      measured swing %s V, S/N %s dB, noise %s V'
              % (fmt_num(got, '%.3f'), fmt_num(sn, '%.1f'), fmt_num(num(res, 'nv'), '%.4f')))
        rows.append(('level %.2fV' % swing, ok and famok and throk,
                     '%s thr %s swing %s S/N %s %s'
                     % (res.get('fam'), fmt_num(res.get('thr'), '%.2f'), fmt_num(got, '%.3f'),
                        fmt_num(sn, '%.0f'), det)))


def suite_lorem(d, g, a, rows):
    """One 1 kB non-repeating payload replayed across the rate ladder."""
    with open(os.path.join(BU.VECDIR, LOREM_ARB + '.txt'), 'rb') as f:
        payload = f.read()
    rates = [int(x) for x in a.rates.split(',')] if a.rates else RATES
    print('\n=== LOREM -- %s (%d bytes, %.4f sa/bit) at %d rates ==='
          % (LOREM_ARB, len(payload), _spb(LOREM_ARB), len(rates)))
    for baud in rates:
        srate = _srate(LOREM_ARB, baud)
        if srate > I.SDG_MAX_SRATE:
            print('  %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling' % (baud, srate))
            continue
        g.select_arb(VN.arb(LOREM_ARB), amp_for(NOMINAL_SWING), srate)
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, 'lorem%d' % baud)
        # Judged against the 1 kB payload as a CYCLIC substring -- the arb loops, so a window may
        # straddle the wrap, and a head the panel flagged as misaligned is skipped as elsewhere.
        nf = int(num(res, 'nf', 0))
        # headsusp is the SUSPECT REGION, not the damage; trim by what is actually hurt.
        # See BU.head_damage -- trimming by the raw region failed five soak laps on correct decodes.
        head = BU.head_damage(hexs, int(num(res, 'head', 0)))
        ok, det = False, 'no bytes decoded'
        if 'fail' in res:
            det = 'FAIL %s' % res['fail']
        elif nf > head:
            # A FLAGGED framing error is not a wrong answer. What must hold is that the bytes the
            # decoder STANDS BEHIND are right, and that it did not decline too many.
            #
            # "r.idle1 stays nil on a gapless vector, so headsusp does" IS FALSE, and believing it is
            # what makes the headsusp byte-skip look harmless -- it costs five soak laps on correct
            # decodes. Measured false on 495 of 1024 capture offsets. lorem IS
            # rendered gap = 0, so there is no inter-BYTE idle; but the ARB LOOPS, and
            # make_vectors.lua renders it with lead = 10, tail = 10, which leaves a 20-BIT IDLE AT THE
            # LOOP SEAM. uart_decode.tsp:437 sets r.idle1 on "a pitch of two frame times or more", and
            # 20 bits clears that bar, so the seam is a genuine idle and headsusp = idle1 - 1 becomes
            # the DISTANCE TO THE SEAM -- up to 496 frames on a 1024-byte payload. Hence the skip
            # below is head_damage(), not head: see BU.head_damage.
            #
            # NOT `longest_clean_run/body >= 0.95`, which fails a point on WHERE a flag lands rather
            # than how many there are -- one honest flag more than ten bytes from an edge fails
            # outright, only 22 of 239 single-flag positions can pass, and every run but the longest
            # goes unchecked against the payload. BU.judge_payload validates
            # every diagnostic run at one agreed alignment and bounds the flag COUNT; see its
            # docstring and tools/test_lorem_gate.py.
            ok, det = BU.judge_payload(hexs[2 * head:], payload)
            if head:
                det = det + ' after a FLAGGED %d-byte head' % head
        gb = num(res, 'baud')
        close = gb is not None and abs(gb / baud - 1.0) <= 0.02
        print('  %-26s %-5s %-6s %5s Bd  %-46s %s'
              % ('%d Bd' % baud, 'ok' if (ok and close) else 'BAD', res.get('fmt', '?'),
                 fmt_num(res.get('baud'), '%.0f'), det, 'srate %d' % srate))
        n4915 = note_events(res)
        if n4915:
            print('      *** %d x event 4915 ***' % n4915)
        for n in notes:
            print('      note: %s' % n)
        # DUMP THE BYTES ON A FAILURE. Without this the record of a failed point is its summary line
        # and nothing else, so the verdict can never be re-derived -- and a gate later found to be
        # wrong cannot be re-run against the laps it condemned. Only on failure: 480 hex chars per
        # passing point would bury the log.
        if not (ok and close):
            print('      hex head %d: %s' % (head, hexs[2 * head:][:512]))
        rows.append(('lorem %d' % baud, ok and close, det))


def suite_offsets(d, g, a, rows):
    print('\n=== DC OFFSETS -- the same signal displaced, to both instruments\' limits ===')
    for swing in [float(x) for x in a.offset_swings.split(',')]:
        amp = amp_for(swing)
        lim = offset_limit(swing)
        offs = [0.0]
        k = 1
        while True:
            v = round(lim * k / 3.0, 2)
            if v > lim + 1e-9:
                break
            offs.extend([v, -v])
            k += 1
            if k > 3:
                break
        offs = sorted(set(offs))
        print('  %.1f V swing (AMP %.2f): |OFST| <= %.2f V  -> %s'
              % (swing, amp, lim, ', '.join('%+.2f' % o for o in offs)))
        for ofst in offs:
            g.select_arb(VN.arb('v41'), amp, _srate('v41', FORMAT_BAUD), offset_v=ofst)
            g.output(True, ch=1)
            time.sleep(a.settle)
            # READ THE OFFSET BACK. The generator clamps rather than refusing, and a clamped
            # offset reported as the one asked for would look exactly like a decoder result.
            bswv = g.query('C1:BSWV?') or ''
            res, hexs, notes = press(d, 'ofst%+.2f' % ofst)
            vmn, vmx = num(res, 'vmin'), num(res, 'vmax')
            band = '?' if vmn is None or vmx is None else '%.2f..%.2f V' % (vmn, vmx)
            ok, det = show('%.1f V @ %+.2f V' % (swing, ofst), res, hexs, notes, band)
            # THE GENERATOR'S REPLY IS PART OF THE VERDICT, not a diagnostic printed beside it. The SDG
            # CLAMPS rather than refusing, so an offset it would not apply comes back as a decoder result
            # for the offset that was ASKED for -- and a point that never presented the stimulus it names
            # cannot pass, whatever the decoder said about whatever was actually on the wire.
            #
            # Unparseable counts as failure too: a reply this tool cannot read is not a reply confirming
            # the setting, and treating it as one is how a stale or truncated line becomes a PASS.
            if 'OFST,%g' % ofst not in bswv.replace(' ', ''):
                print('      GENERATOR DID NOT APPLY %+.2f V -- reports: %s'
                      % (ofst, bswv.strip()[:110] or '<no reply>'))
                ok = False
                det = 'generator did not apply the %+.2f V offset; %s' % (ofst, det)
            rows.append(('offset %.1fV %+.2fV' % (swing, ofst), ok,
                         '%s %s' % (band, det)))


# THE HARD VECTORS: patterns built to attack the decoder rather than to look like traffic.
#
#   v90  64 each of 0x00, 0xFF, 0x55, 0xAA -- the extremes of edge density, and the boundaries
#        between the blocks are the largest possible step in it
#   v91  256 uniform random bytes 0-255 from a known seed -- the only stimulus that catches a decode
#        depending on a byte's VALUE rather than its timing
#   v92  walking-one then walking-zero -- a single 1 (then a single 0) in each bit position, so a
#        mis-sampled bit shows as ONE wrong byte whose position names the bit
#
# THE FORMAT IS FORCED TO 8N1 HERE, and that is the whole reason this suite exists separately.
# v90 and v92 are simultaneously valid 7E1 and 7O1: in every one of those bytes, bit 7 happens to
# equal the parity of the low seven. The app is RIGHT to report 7E1 as a candidate and right to say
# so -- that is the documented ambiguity -- but a byte-exactness test must not depend on which of two
# correct answers it picks. So the wire parameters are pinned and the question narrows to the one this
# suite can settle: are the BYTES right on hostile patterns.
HARD = [('v90', 'blocks of 00/FF/55/AA'),
        ('v91', 'uniform random bytes'),
        ('v92', 'walking one and zero')]
HARD_SPB = 100000.0 / 9600.0          # as built: 10.41667 samples/bit


def hard_compare(hexs, payload):
    """Best cyclic alignment, then mismatches split into LEADING, INTERIOR-WRONG and FLAGGED.

    BU.analyse() is right for the lorem sweep and wrong here: it breaks a run only on '??' -- a byte
    the decoder could not recover -- so a run of bytes with WRONG VALUES counts as "clean" and the
    verdict reads '238 of 238 B, 100 % clean, 0 bad' for a capture that does not match the payload.
    A failure whose detail line describes a success is the most dangerous shape a bench result takes.

    But comparing values alone is too strict. These vectors are
    rendered gap = 0 -- bytes back to back, which is what a device dumping a buffer does -- so a
    capture STARTS MID-BYTE and has no idle to resynchronise on. Measured: 2 of 239 wrong at 9600 and
    1 of 229 at 57600, at indices 0 and 1 both times. That is the documented mid-capture head, not a
    decode defect, and the manual states it.

    So the question is WHERE a mismatch is, not how many there are:
      leading   a contiguous run of wrong bytes at the very start -- expected, reported, not a failure
      wrong     a value mismatch AFTER the first correct byte -- SILENT CORRUPTION, the one
                unacceptable outcome
      flagged   a '??' the decoder itself declined to stand behind -- honest, counted, not a failure

    Returns (offset, nlead, wrong, flagged, nbytes) where wrong/flagged are [(index, want, got), ...].
    """
    hexs = ''.join(hexs) if isinstance(hexs, list) else (hexs or '')
    frames = [hexs[i:i + 2] for i in range(0, len(hexs) - 1, 2)]
    got = [None if f == '??' else int(f, 16) for f in frames]
    n, m = len(got), len(payload)
    if n == 0 or m == 0:
        return -1, 0, [], [], n
    want = list(payload) + list(payload)          # cyclic: the arb repeats seamlessly
    best, bestoff = -1, 0
    for off in range(m):
        hit = 0
        for i in range(n):
            if got[i] is not None and got[i] == want[off + i]:
                hit += 1
        if hit > best:
            best, bestoff = hit, off
    # The leading run: every byte before the FIRST one that matches.
    lead = 0
    while lead < n and (got[lead] is None or got[lead] != want[bestoff + lead]):
        lead += 1
    wrong, flagged = [], []
    for i in range(lead, n):
        if got[i] is None:
            flagged.append((i, want[bestoff + i], None))
        elif got[i] != want[bestoff + i]:
            wrong.append((i, want[bestoff + i], got[i]))
    return bestoff, lead, wrong, flagged, n


def suite_hard(d, g, a, rows):
    """The adversarial patterns, format pinned, judged as a cyclic substring."""
    rates = [int(x) for x in a.rates.split(',')] if a.rates else [2400, 9600, 57600]
    print('\n=== HARD PATTERNS -- %d vectors, 8N1 PINNED, at %d rates ==='
          % (len(HARD), len(rates)))
    for vid, desc in HARD:
        with open(os.path.join(BU.VECDIR, vid + '.txt'), 'rb') as f:
            payload = f.read()
        for baud in rates:
            srate = int(round(baud * HARD_SPB))
            if srate > I.SDG_MAX_SRATE:
                print('  %-5s %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling' % (vid, baud, srate))
                continue
            g.select_arb(VN.arb(vid), _amp(vid), srate)
            g.output(True, ch=1)
            time.sleep(a.settle)
            # PINNED, and pinned per point: press() clears the forced values when unlock is true, so
            # the pin has to be re-applied rather than set once for the suite.
            d.exec('sdec.force_baud, sdec.force_nbits = %d, 8 '
                   'sdec.force_par, sdec.force_nstop = sdec.PAR_NONE, 1 '
                   'sdec.force_invert = false' % baud, timeout=20)
            res, hexs, notes = press(d, '%s@%d' % (vid, baud), unlock=False)
            nf = int(num(res, 'nf', 0))
            # headsusp is the SUSPECT REGION, not the damage; see BU.head_damage.
            head = BU.head_damage(hexs, int(num(res, 'head', 0)))
            ok, det = False, 'no bytes decoded'
            if 'fail' in res:
                det = 'FAIL %s' % res['fail']
            elif nf > head:
                # THE HEAD IS SKIPPED IN CHARACTERS, not bytes: hexs is one string of hex pairs, so a
                # flagged head of N bytes is 2N characters. The lorem suite's `hexs[2 * head:]` reads
                # as a byte slice and is a character slice, which is right by accident there and worth
                # being explicit about here.
                off, lead, wrong, flagged, nb = hard_compare(hexs[2 * head:], payload)
                # INTERIOR VALUE MISMATCHES ARE THE ONLY FAILURE. A leading run is the mid-byte start
                # this gapless stimulus guarantees, and a '??' is the decoder declining to guess --
                # both honest. A wrong value after a correct one is not.
                ok = len(wrong) == 0 and nb > lead
                tail = nb - lead
                if ok:
                    det = '%d B exact at offset %d%s%s' % (
                        tail, off,
                        '' if lead == 0 else ' after a %d-byte mid-capture head' % lead,
                        '' if not flagged else ' (%d flagged)' % len(flagged))
                else:
                    # WITH VALUES. A count cannot tell a mis-sampled bit from a lost frame;
                    # 'want 55 got 51' names the bit.
                    shown = ', '.join('[%d] want %02X got %02X' % (i, w, gv)
                                      for i, w, gv in wrong[:4])
                    det = ('%d of %d B SILENTLY WRONG in the interior at offset %d: %s%s'
                           % (len(wrong), tail, off, shown,
                              '' if len(wrong) <= 4 else ' ...'))
            print('  %-5s %-22s %-5s %7d Bd  %s' % (vid, desc, 'ok' if ok else 'BAD', baud, det))
            for n in notes[:2]:
                print('      note: %s' % n)
            rows.append(('hard %s@%d' % (vid, baud), ok, det))
    d.exec('sdec.force_baud, sdec.force_nbits = nil, nil '
           'sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil', timeout=20)


# The fourteen. Coveyou's line -- "random number generation is too important to be left to chance"
# (Oak Ridge, 1969) -- is why r00-r11 are SHUFFLES rather than uniform draws: a uniform 250-byte
# draw leaves each value's presence to a Poisson tail, and about one value in 256 would have been
# missing. Shuffling guarantees the coverage and keeps the ORDER random, which was the useful part.
PAYLOAD_VECS = (['v77', 'v78'] + ['r%02d' % k for k in range(12)])
# ALL FOURTEEN AT 9600, TWO OF THEM ALSO DRIVEN HIGH. Sweeping every vector over every rate is 154
# captures and takes a lap from ~5 minutes to over 20, cutting the laps per night by four -- and most
# of it re-measures the middle of a ladder the `rates` suite already walks. Two high-rate points are
# what this payload family needs, because without any the claim "the high-rate failures only happen on
# lorem" is untested rather than established.
#
# WHY v77 AND r00. The v41-passes / v71-fails contrast has three candidate variables -- rendered
# points-per-bit, payload length, content -- and PAYLOAD LENGTH alone accounts for it. The DMM's own samples-per-bit is NOT a variable here at all: fs_for_baud (serial_core.tsp:958)
# takes baud and nothing else, so both suites sample at the same 8.68 / 4.00 sa/bit at 115200 / 250000,
# and the same 20 capture offsets fail at 4.0 and at 8.0. What differs is the LOOP SEAM: Hello (v41) is
# 13 B so a ~334 B capture spans ~26 seams and idle1 records only the first, bounding headsusp at 12;
# Lorem1kB (v71) is
# 1024 B, longer than any capture, so it holds at most one seam wherever the arb phase puts it.
# These two are still the right additions -- they were never driven above 9600, they bracket the
# length axis (133 B of text, 256 B of shuffled bytes), and r00's 256 B makes it 7.8 % exposed to the
# seam band per point where v77's 133 B is immune. Same class of gap as #29.
PAYLOAD_BASE_RATE = 9600
PAYLOAD_HIRATE_VECS = ['v77', 'r00']
# 115200 is where three of the five lorem failures landed; 250000 is the 4.0-samples-per-bit wall the
# app itself warns about. The rungs between are the `rates` suite's job.
PAYLOAD_HIRATES = [115200, 250000]


def suite_payloads(d, g, a, rows):
    """The full-glyph pair and the twelve shuffled vectors, one capture each.

    WHY THESE AND NOT MORE LOREM. Every other suite replays ONE payload, so a long run measures
    repeatability: the same bit patterns at the same phases, over and over. These fourteen are
    fourteen different payloads, and between them they carry every byte value 0..255 -- the six
    8N1 vectors are each a shuffle of 0..255 (every value exactly once) and the six 7E1 ones a
    shuffle of 0..127 twice over, so coverage is guaranteed rather than sampled. v77/v78 add all
    94 visible ASCII glyphs in both 8N1 and 7E1.

    THE 7E1 HALF IS THE POINT, not symmetry. A uniformly shuffled 7-bit payload sets the parity
    bit in about half its frames, which is the strongest available input to the 7E1-versus-8N1
    disambiguation -- the ambiguity that read v78 as 8N1 on four captures in eight until
    ua_refine_parity stopped letting one misaligned frame veto the vote. A decoder that cannot
    tell the two apart has nowhere to hide here.

    Every vector is 256 bytes at 9600 8N1/7E1, ~53.8 kB as a file: inside SDG_UPLOAD_SAFE_BYTES
    with 18 % margin, so all fourteen are safe LAN uploads rather than USB-key transfers.
    """
    vecs = PAYLOAD_VECS
    # SWEPT UP TO 250 kBd, WHICH IS WHAT SEPARATES CONTENT AND LENGTH FROM RATE. Run only at 9600,
    # the fox and the twelve random payloads leave the v41-passes/v71-fails contrast confounded three
    # ways: points-per-bit (10.0 vs 10.41667), payload length (3884 B vs 213750 B) and content. These
    # vectors break that tie, because they are 256-byte shuffles and 94-glyph text rendered at the
    # SAME 10.41667 sa/bit as v71.
    # Same class of gap as #29, where the suites tested rates the app never selects.
    hirates = ([int(x) for x in a.payload_rates.split(',')]
               if getattr(a, 'payload_rates', None) else PAYLOAD_HIRATES)
    print('\n=== PAYLOADS -- %d payloads at %d Bd, every byte value 0-255 covered; %s also at %s ==='
          % (len(vecs), PAYLOAD_BASE_RATE, '/'.join(PAYLOAD_HIRATE_VECS),
             '/'.join(str(x) for x in hirates)))
    for vid in vecs:
        try:
            with open(os.path.join(BU.VECDIR, vid + '.txt'), 'rb') as f:
                payload = f.read()
        except IOError:
            print('  %-6s SKIPPED -- no %s.txt; run tools/make_vectors.lua' % (vid, vid))
            continue
        # SELECT ONCE, THEN SWEEP SRATE. Selecting costs 0.5 s plus the payload at a measured
        # 311 kB/s across the CPU-board-to-FPGA serial link; an SRATE change is ~0.01 s of FPGA
        # register writes. Since the waveform is constant across this vector's rates, re-selecting
        # per rate would pay the expensive half N times for nothing -- which is what suite_rates and
        # suite_lorem still do (see the note on SUITES below).
        first = True
        rlist = [PAYLOAD_BASE_RATE]
        if vid in PAYLOAD_HIRATE_VECS:
            rlist = rlist + hirates
        for baud in rlist:
            srate = _srate(LOREM_ARB, baud)
            if srate > I.SDG_MAX_SRATE:
                print('  %-6s %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling' % (vid, baud, srate))
                continue
            if first:
                g.select_arb(VN.arb(vid), _amp(vid), srate)
                g.output(True, ch=1)
                first = False
            else:
                g.truearb(srate)          # same waveform, new playback clock
                g.assert_truearb()
            time.sleep(a.settle)
            res, hexs, notes = press(d, 'pay_%s_%d' % (vid, baud))
            nf = int(num(res, 'nf', 0))
            # headsusp is the SUSPECT REGION, not the damage; trim by what is actually hurt.
            # See BU.head_damage -- trimming by the raw region failed five soak laps on correct decodes.
            head = BU.head_damage(hexs, int(num(res, 'head', 0)))
            ok, det = False, 'no bytes decoded'
            if 'fail' in res:
                det = 'FAIL %s' % res['fail']
            elif nf > head:
                ok, det = BU.judge_payload(hexs[2 * head:], payload)
                if head:
                    det = det + ' after a FLAGGED %d-byte head' % head
            gb = num(res, 'baud')
            close = gb is not None and abs(gb / float(baud) - 1.0) <= 0.02
            print('  %-6s %7d Bd %-5s %-6s %5s Bd  %-52s %d B payload srate %d'
                  % (vid, baud, 'ok' if (ok and close) else 'BAD', res.get('fmt', '?'),
                     fmt_num(res.get('baud'), '%.0f'), det, len(payload), srate))
            n4915 = note_events(res)
            if n4915:
                print('      *** %d x event 4915 ***' % n4915)
            for n in notes:
                print('      note: %s' % n)
            if not (ok and close):
                print('      hex head %d: %s' % (head, hexs[2 * head:][:512]))
            # THE POINT NAME CARRIES THE RATE, or soak.py merges every rate of a vector into one
            # point and a rate-specific intermittent averages away into nothing.
            rows.append(('payload %s@%d' % (vid, baud), ok and close, det))


_MANIFEST = {}


def manifest():
    """out/vectors/manifest.tsv, keyed by vector id. Read once."""
    if not _MANIFEST:
        with open(os.path.join(BU.VECDIR, 'manifest.tsv')) as f:
            for r in csv.DictReader(f, delimiter='\t'):
                _MANIFEST[r['file'].replace('.bin', '')] = r
    return _MANIFEST


def plan_payload(vid):
    """The expected bytes for a vector. -> bytes, or None if the manifest has none.

    exp_hex, NEVER THE .txt, AND THE DIFFERENCE IS NOT COSMETIC. The .txt holds the bytes that were
    ENCODED; exp_hex holds the bytes make_vectors' own self-check DECODED off the rendered waveform,
    and exp_fmt beside it is the format that decode reported. Those two agree with each other. The
    .txt agrees with neither whenever the framing is ambiguous.

    THREE VECTORS MAKE THAT CONCRETE. v90 and v94 are blocks of 0x00/0xFF/0x55/0xAA and v92 is
    walking bits -- and EVERY byte value in them is a valid frame in 8N1 AND in 7E1, because bit 7
    happens to track the parity its 7-bit reading would carry. So the wire genuinely says both things,
    the app votes 7E1/7O1, and the manifest records that: v92's exp_hex is the .txt with bit 7
    stripped, 80 -> 00 and FE -> 7E. Judging those bytes against the .txt while requiring exp_fmt's
    format asks for two things that cannot both be true, and fails a correct decode at every rate.
    exp_hex covers all 41 rows in full, so there is nothing to fall back to.
    """
    hx = (manifest().get(vid) or {}).get('exp_hex') or ''
    parts = hx.split()
    if not parts:
        return None
    return bytes(int(x, 16) for x in parts)


def plan_payloads(vid):
    """EVERY byte reading the wire legitimately supports. -> list of bytes, commonest first.

    Usually one, and then this is just plan_payload. It is a list because three vectors are framed
    ambiguously BY CONSTRUCTION and the ambiguity is not resolvable from the signal: with 0x00, 0xFF,
    0x55, 0xAA and walking bits, bit 7 tracks exactly the parity a 7-bit reading would carry, so 8N1
    and 7E1 describe the same wire equally well. Which one the app votes for shifts with the rate --
    v94 reads 8N1 at some and 7E1 at others, both correctly -- so pinning either expectation fails a
    right answer at the rates that chose the other. Demanding either ONE of them is what turns an
    ambiguous vector into 43 false failures a lap.

    The .txt is the bytes as ENCODED; exp_hex is what the self-check DECODED, which for these three is
    the same bytes with bit 7 stripped. For every other vector the two are identical and this returns
    one entry.
    """
    out = []
    dec = plan_payload(vid)
    if dec:
        out.append(dec)
    p = os.path.join(BU.VECDIR, vid + '.txt')
    if os.path.exists(p):
        with open(p, 'rb') as f:
            src = f.read()
        if src and src not in out:
            out.append(src)
    return out


def beat(a, msg):
    """One flushed progress line. Best effort: a monitoring aid must never fail a run."""
    path = getattr(a, 'heartbeat', None)
    if not path:
        return
    try:
        with open(path, 'a') as f:
            f.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), msg))
            f.flush()
    except Exception:                                              # noqa: BLE001
        pass


def suite_plan(d, g, a, rows):
    """Every vector, at every standard rate plus one drawn rate per gap, in a seeded order.

    THE MOST DEMANDING SUITE HERE, and the only one whose content changes from lap to lap. What it
    tests comes from --iteration AND --skip-vectors together: see tools/soakplan.py for the draws, and
    plan_order for why the skip is drawn on -- it is applied before the shuffle, so it moves every
    cell's amplitude, offset and wait. A failure prints the iteration, and the header prints the skip
    set and the offline replay line, so the case can be rebuilt without running the laps before it.

    ONE SELECT PER VECTOR, THEN SRATE ONLY. Selecting costs 0.5 s plus the payload over the
    CPU-to-FPGA link; an SRATE change is FPGA register writes. Across 43 rates that is the difference
    between one upload per vector and 43 of them, and the waveform does not change between rates.

    THE POINT NAME IS STABLE ACROSS LAPS, THE RATE IS NOT. A standard rate is named by its baud; a
    drawn rate is named by its GAP INDEX, because the baud in that gap is different every iteration
    and naming points by baud would give every lap a fresh set of names -- so nothing could be tallied
    across laps and a rate-specific intermittent would never accumulate. The actual baud is in the
    detail, where it belongs.
    """
    it = a.iteration
    # SP.soak_vectors(), NOT sorted(VN.MAP.keys()), and for the same reason the offline plan uses it:
    # this is the hardware twin of that draw, so a vector the soak excludes but this enumerates would
    # make the two laps different populations -- and vi keys the amplitude, the offset and the wait, so
    # every surviving vector's conditions would shift too. BENCH_ONLY in tools/vector_names.py says why
    # those vectors are out. --plan-spec below still validates against the whole of VN.MAP, because
    # naming one of them deliberately is exactly what they exist for.
    vecs = SP.soak_vectors()
    skip = SP.parse_skip(a.skip_vectors)
    rates = SP.rates_for(it)
    kindmap = None
    if getattr(a, 'plan_spec', None):
        order, kindmap = [], {}
        for item in a.plan_spec.split(','):
            vid, _, kinds = item.strip().partition(':')
            vid = vid.strip()
            if vid not in VN.MAP:
                raise SystemExit('REFUSING: --plan-spec names %r, which is not in vector_names.MAP'
                                 % vid)
            k = (kinds or 'all').strip()
            want = {'std': {'std'}, 'nonstd': {'rand', 'edge'},
                    'all': {'std', 'rand', 'edge'}}.get(k)
            if want is None:
                raise SystemExit("REFUSING: --plan-spec kind %r for %s; use std, nonstd or all"
                                 % (k, vid))
            order.append(vid)
            kindmap[vid] = want
    else:
        # SP.plan_order, NOT a filter here plus a shuffle there. The skip has to be applied before the
        # shuffle and the offline twin has to apply it identically, because vi keys the amplitude, the
        # offset and the wait -- see soakplan.plan_order for the 1677 cells this cost.
        order = SP.plan_order(it, vecs, skip, a.plan_vectors)
    std = set(SP.standard_rates())
    ladder = SP.rate_ladder()
    gapno = {}
    for baud, kind in rates:
        if kind != 'std':
            gapno[baud] = sum(1 for b in std if b < baud)
    # THE COUNT AFTER THE FILTER, not before it. With --plan-spec most cells are skipped, and a header
    # claiming 172 where 86 will run is a wrong number in the one line an operator reads.
    if kindmap is None:
        ncells = len(order) * len(rates)
        est = SP.estimate_secs(rates, len(order)) / 60.0
    else:
        ncells, secs = 0, 0.0
        for v in order:
            sub = [r for r in rates if r[1] in kindmap[v]]
            ncells += len(sub)
            secs += SP.estimate_secs(sub, 1)
        est = secs / 60.0
    print('\n=== PLAN iteration %d -- %d vectors x %d rates (%d standard, %d drawn, %d ladder edge) '
          '= %d cells, est %.0f min ==='
          % (it, len(order), len(rates), sum(1 for _, k in rates if k == 'std'),
             sum(1 for _, k in rates if k == 'rand'), sum(1 for _, k in rates if k == 'edge'),
             ncells, est))
    if kindmap is None:
        print('    order: %s' % ' '.join(order))
    else:
        print('    cells: %s' % '  '.join('%s:%s' % (v, '+'.join(sorted(kindmap[v]))) for v in order))
    if skip:
        print('    SKIPPED BY REQUEST, and therefore untested this lap: %s' % ' '.join(sorted(skip)))
    print('    FRAME mode only: above 165563 Bd sdec.fs_for_burst returns nil, so the streaming '
          'paths cannot record 172800 and up at all.')
    # THE OFFLINE REPLAY LINE, PRINTED, because getting it wrong is silent. The skip moves every vi,
    # and vi keys the amplitude, the offset and the wait -- so a twin run without this flag drives a
    # different waveform in every cell and disagrees for a reason that is neither hardware nor app.
    print('    replay offline: python3 tools/plan_sweep.py --iteration %d%s --offsets 8'
          % (it, (' --skip-vectors ' + ','.join(sorted(skip))) if skip else ''))

    for vi, vid in enumerate(order):
        payloads = plan_payloads(vid)
        if not payloads:
            print('  %-6s SKIPPED -- no exp_hex in the manifest' % vid)
            continue
        row = manifest().get(vid) or {}
        # SPB PER VECTOR, FROM THE MANIFEST. The clean vectors render at 10 samples per bit and the
        # impairment ones at 100, so srate = baud * spb differs by 100x between them. Assuming 10
        # would play every x100 vector at a tenth of the intended baud and blame the decoder.
        spb = int(row.get('spb') or 10)
        want_fmt = (row.get('exp_fmt') or '').strip()
        expect = SP.expect_for(vid)
        t_vec, ncell, nbadcell, ninconc, nbaud, firstcell = time.time(), 0, 0, 0, 0, True
        # EVENTS['other'] IS CUMULATIVE over the run, so the per-vector count is a delta against a
        # snapshot taken here. Surfaced in the heartbeat below because the count of unexpected INSTRUMENT
        # events is the number a live monitor most wants and could not see at all: the child's stdout is
        # captured by soak.py and not printed until the lap ends, so the `*** unexpected event 2208 ***`
        # lines stay invisible for up to three hours.
        ev0 = EVENTS['other']
        beat(a, 'iter %d START %d/%d %s (%s, %.1f Vpp, spb %d)'
             % (it, vi + 1, len(order), vid, expect, _amp(vid), spb))
        for ri, (baud, kind) in enumerate(rates):
            if kindmap is not None and kind not in kindmap[vid]:
                continue
            srate = baud * spb
            if srate > I.SDG_MAX_SRATE:
                print('  %-6s %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling (spb %d)'
                      % (vid, baud, srate, spb))
                continue
            # SELECT ON THE FIRST CELL ACTUALLY RUN, not on rate index 0. With --plan-spec the first
            # rates are filtered out, so keying the select on ri == 0 means it never happens: every
            # cell takes the truearb branch and the generator keeps playing the PREVIOUS waveform at
            # this one's rates. Measured -- two waveforms failed 21 of 21 cells each while the two
            # that happened to include rate index 0 passed everything.
            # THE VERTICAL AXES, per cell. Amplitude and offset are drawn from the iteration exactly as
            # the wait and the rate are, then mapped to a band that provably fits the rails -- and
            # asserted, because a blind write is how a clipped stimulus gets filed as a clean one.
            ua, uo = SP.amp_ofst_u(it, vi, ri)
            camp, cofst, cnote = SP.amp_ofst_for(vid, ua, uo)
            vmin_c, vmax_c = SP.assert_unclipped(vid, camp, cofst)
            if firstcell:
                g.select_arb(VN.arb(vid), camp, srate, offset_v=cofst)
                g.output(True, ch=1)
                firstcell = False
            else:
                g.truearb(srate)
                g.write('C1:BSWV AMP,%g,OFST,%g' % (camp, cofst))
                g.assert_truearb()
            time.sleep(a.settle)
            # THE SEEDED WAIT, on top of settle and for a different reason: settle lets the generator
            # take the new clock, this lands the capture on a different byte, bit and sub-bit phase.
            # Uniform over 10 byte-times, so it scales with the rate.
            wait = SP.wait_s(it, vi, ri, baud)
            time.sleep(wait)
            label = 'std%d' % baud if kind == 'std' else 'gap%02d' % gapno[baud]
            res, hexs, notes = press(d, 'plan_%s_%s' % (vid, label))
            nf = int(num(res, 'nf', 0))
            head = BU.head_damage(hexs, int(num(res, 'head', 0)))
            ok, det = False, 'no bytes decoded'
            if 'fail' in res:
                det = 'FAIL %s' % res['fail']
            verdict = 'FAIL'
            if 'fail' not in res and nf > head:
                # ANY legitimate reading of the wire passes. One candidate for all but the three
                # ambiguously framed vectors; see plan_payloads.
                for cand in payloads:
                    verdict, det = BU.judge_payload_v(hexs[2 * head:], cand, expect)
                    if verdict == 'PASS':
                        break
                ok = verdict == 'PASS'
                if head:
                    det = det + ' after a FLAGGED %d-byte head' % head
            gb = num(res, 'baud')
            got_fmt = res.get('fmt', '?')
            # THE FORMAT IS ONLY CHECKED WHERE THERE IS ONE ANSWER. With two legitimate readings the
            # app is right either way, and requiring the manifest's one fails it at every rate that
            # chose the other -- so for those vectors the bytes carry the whole verdict.
            if len(payloads) > 1:
                fmtok = True
            else:
                fmtok = bool(want_fmt) and got_fmt[:3] == want_fmt[:3]
            # THREE INDEPENDENT VERDICTS, because a baud report that disagrees with the commanded rate
            # is not a decode fault. The app snaps a measured rate to its ladder within sdec.snaptol,
            # so a drawn rate 2.4 % from a ladder entry is reported as that entry and every byte still
            # decodes byte-exact. Folding that into the cell's verdict fails a correct decode; the
            # discrepancy is real and stays REPORTED, just not as a wrong answer.
            content_ok = ok
            rate_ok = gb is not None and abs(gb / float(baud) - 1.0) <= RATE_TOL
            decode_ok = content_ok and fmtok
            # SILENTLY WRONG keys on CONTENT alone: bytes came back, the app raised nothing and flagged
            # nothing, and they are not the payload. INCONCLUSIVE is excluded -- the judge declining to
            # read a 3-byte capture says nothing about whether those bytes are right.
            nbad = int(num(res, 'nbad', 0))
            silent = (not content_ok) and verdict != 'INCONCLUSIVE' and nf > 0 \
                and 'fail' not in res and nbad == 0
            # INCONCLUSIVE PASSES ONLY FOR A LOUD VECTOR. A drift vector genuinely may not return enough
            # bytes to judge, and that is the vector doing its job. An EXACT vector returning one byte
            # where two hundred belong is a defect, and treating it as neutral would let the app return
            # nothing judgeable at every rate while the suite exited zero.
            if verdict == 'INCONCLUSIVE':
                good = expect == 'loud'
            elif expect == 'loud':
                good = decode_ok or not silent
            else:
                good = decode_ok
            # A REPORTED BAUD OUTSIDE snaptol IS ITS OWN FAILURE, not a wrong decode and not nothing.
            # Byte-exact content does NOT prove the rate was right: uart_decode.tsp records that 9600
            # 7N1 can be bit-identical to 4800 8N1, and a periodic payload frames cleanly at rescaled
            # rates. So the two verdicts are kept apart and BOTH count.
            # SET INDEPENDENTLY OF `good`, so a cell that already failed on content still REPORTS its
            # baud error -- tallying it only when everything else passed loses the data on exactly the
            # cells that have two faults. A rate claim is only meaningful where bytes were judged, so
            # INCONCLUSIVE is exempt: nothing was read, so nothing was claimed.
            # ONLY WHERE A RATE WAS ACTUALLY CLAIMED. A capture that returned nothing claims no rate, and
            # declining is the correct answer to an unreadable signal -- so requiring a baud there would
            # fail every honest refusal a loud vector is entitled to make. INCONCLUSIVE is out for the
            # same reason.
            baudbad = False
            if nf > 0 and verdict != 'INCONCLUSIVE':
                if gb is None:
                    # Bytes came back with NO reported rate. The panel shows a rate; absent is not right.
                    baudbad = True
                    det = det + ' [bytes returned with no baud reported]'
                elif not rate_ok:
                    baudbad = True
                    det = det + ' [baud reported %.0f vs %d commanded, %+.2f %% -- outside snaptol]' % (
                        gb, baud, 100.0 * (gb / float(baud) - 1.0))
            good = good and not baudbad
            ncell += 1
            # INCONCLUSIVE is its own token, never 'ok'. It is not a pass -- it is a cell that produced
            # no evidence either way, and a run of them means the capture window is too short at this
            # rate, which is worth seeing rather than counting as health.
            tok = 'ok' if good else 'BAD'
            if baudbad:
                tok, nbaud = 'BAUD', nbaud + 1
            elif verdict == 'INCONCLUSIVE':
                tok, ninconc = ('skip' if good else 'BAD'), ninconc + 1
            print('  %-6s %7d Bd %-5s %-5s %-5s %-6s %7s Bd  %-46s %5.2f sa/bit  wait %6.2f ms'
                  % (vid, baud, kind, expect, tok, got_fmt,
                     fmt_num(res.get('baud'), '%.0f'), det,
                     SP.pick_fs(baud, ladder) / float(baud), wait * 1000.0))
            n4915 = note_events(res)
            if n4915:
                print('      *** %d x event 4915 ***' % n4915)
            for n in notes:
                print('      note: %s' % n)
            if not good:
                # EVERYTHING NEEDED TO REBUILD THE CASE, on the failure and not in a summary. The
                # iteration gives the rates, the order and the commanded wait; the MEASURED head is
                # what the seed cannot reproduce, because on hardware the capture phase is a race the
                # wait only perturbs. Without the measured value a replay is a coin toss.
                print('      REPRO iteration %d vector %s rate %d Bd (%s) srate %d spb %d '
                      'wait %.4f ms measured-head %s nf %d fmt %s want %s'
                      % (it, vid, baud, kind, srate, spb, wait * 1000.0,
                         fmt_num(res.get('head'), '%.0f'), nf, got_fmt, want_fmt))
                print('      hex head %d: %s' % (head, hexs[2 * head:][:512]))
            # THE DRIVEN SWING TRAVELS WITH THE RESULT, on every row and not just the failures.
            # Without it, correlating failure against voltage means recomputing the draw from the
            # iteration afterwards -- doable, since it is deterministic, but the vi index has to come
            # from the printed `order:` line and getting that wrong mislabels every cell silently.
            # The span is what a scope reads p-p; camp/cofst are what the generator was told.
            span_v = vspan(vid) * camp / _amp(vid)
            # AND THE APP'S OWN S/N, for the same reason and one more: the swing is what the harness
            # DROVE, while this is what the instrument RECEIVED. A cell that fails at a large swing and
            # a poor S/N is a different finding from one that fails at a large swing and a clean one.
            # AND THE CAPTURE GEOMETRY THE INSTRUMENT ACTUALLY USED, which is the pair the offline twin
            # has to assume. The twin digitises at SP.pick_fs(the COMMANDED baud) for sdec.n samples; the
            # app digitises at pick_fs(the baud its own PROBE measured) for however many an armed capture
            # delivers. Both can differ, and printed here they are attributable per cell instead of being
            # inferred from the app's autolock note -- which forecasts the NEXT capture, not this one.
            fs_want = SP.pick_fs(baud, ladder)
            fs_got = num(res, 'fs')
            geom = 'fs %s/%d' % (fmt_num(fs_got, '%.0f'), fs_want)
            if fs_got is not None and abs(float(fs_got) - fs_want) > 1:
                geom = geom + ' DIFFERS'
            geom = geom + ' n %s trig-req %s' % (fmt_num(num(res, 'nread'), '%.0f'),
                                                 res.get('trigreq', '?'))
            rows.append(('plan %s@%s' % (vid, label), good,
                         '%d Bd %s %.3f Vpp-signal (%.3f Vpp gen, ofst %+.3f) S/N %s %s %s%s'
                         % (baud, kind, span_v, camp, cofst,
                            fmt_num(num(res, 'sn'), '%.0f'), geom, det,
                            ' [SILENTLY WRONG]' if silent else '')))
            if not good:
                nbadcell += 1

        # A WAVEFORM THAT PRODUCED NO EVIDENCE AT ALL IS A FAILURE, however entitled to fail it is.
        # An individual inconclusive cell is neutral, which is right -- but a loud vector returning two
        # bytes at every rate would otherwise be 43 neutral cells and a clean exit, indistinguishable
        # from a working one. Being allowed to decline is not the same as never being read.
        if ncell > 0 and ninconc >= INCONC_MAX_FRAC * ncell:
            print('  %-6s %s: NO USABLE EVIDENCE -- %d of %d cells were inconclusive (limit %.0f %%)'
                  % (vid, expect, ninconc, ncell, 100.0 * INCONC_MAX_FRAC))
            rows.append(('plan %s@evidence' % vid, False,
                         '%d of %d cells inconclusive -- the vector was never actually read'
                         % (ninconc, ncell)))
            nbadcell += 1

        # AFTER EVERY WAVEFORM, NOT ONLY AT THE END OF THE LAP. 43 cells is minutes; the lap is hours.
        # Two questions get asked here, and both are cheap:
        #
        #   IS THE BENCH STILL THERE. A LUA round trip, not *IDN?: the SCPI parser can keep answering
        #   after the app is gone, so a reply to *IDN? would prove the wrong thing. The generator gets
        #   the same question, THROUGH THE OPEN SOCKET -- it serves one SCPI session, so probing it on
        #   a second connection reports a wedge that is not there.
        #
        #   IS IT STILL RIGHT. A vector that has started failing is worth knowing about now rather
        #   than after another 40 waveforms. Vectors ENTITLED to fail never stop anything: an
        #   impairment vector missing bytes is the vector doing its job.
        vsec = time.time() - t_vec
        alive = d.alive()
        sdg_ok, sdg_why = BS.sdg_alive(sdg=g)
        # ninconc IS PRINTED EVEN WHEN ZERO. A cell the judge declined is neither a pass nor a defect,
        # so it must not vanish into the pass count -- a rate where every capture is too short to read
        # would otherwise look like 43 clean cells.
        print('  %-6s %s: %d cells in %.0f s (%.2f s/cell) at %.1f Vpp, %d not as expected, '
              '%d inconclusive, %d baud-misreported  DMM %s  SDG %s'
              % (vid, expect, ncell, vsec, vsec / max(1, ncell), _amp(vid), nbadcell, ninconc, nbaud,
                 'alive' if alive else 'NOT ANSWERING', 'alive' if sdg_ok else 'NO: %s' % sdg_why))
        # `badcells`, NOT `unexpected`. This field is nbadcell -- cells that did not decode as expected,
        # the same number the print above words as "not as expected". Calling it "unexpected" collided
        # with the established meaning of an unexpected INSTRUMENT event, and the two readings differ by
        # orders of magnitude in what they imply: v96's 22 known-bad cells read as 22 instrument events,
        # and a loud impairment vector doing its job read as an alarm. `events` below is the instrument
        # count, and it is the one that must be zero.
        beat(a, 'iter %d DONE  %d/%d %s %d cells %.0fs %.2fs/cell %d badcells %d inconc %d baud '
                '%d events DMM=%s SDG=%s'
             % (it, vi + 1, len(order), vid, ncell, vsec, vsec / max(1, ncell), nbadcell, ninconc,
                nbaud, EVENTS['other'] - ev0,
                'alive' if alive else 'SILENT', 'alive' if sdg_ok else 'SILENT'))
        if not alive or not sdg_ok:
            # EXIT 3, NOT 1, AND THE DIFFERENCE MATTERS TO A SOAK. Exit 1 is "some cell failed", which
            # a soak should tally and carry on from. This is "there is no bench any more", and the
            # generator's SCPI port cannot be recovered without a power cycle at the front panel --
            # so every later lap would run against a dead instrument and produce laps of nothing.
            print('STOPPING after %s: the bench stopped answering (DMM %s, SDG %s). Nothing after '
                  'this point would mean anything, and the remaining waveforms would each wait for a '
                  'timeout. The app may be mid-capture and the generator is still driving its output.'
                  % (vid, 'alive' if alive else 'silent', 'alive' if sdg_ok else sdg_why))
            raise SystemExit(3)
        if nbadcell and a.fail_fast:
            raise SystemExit(
                'STOPPING after %s: %d of %d cells did not behave as a %r vector must, and --fail-fast '
                'is set. Iteration %d rebuilds this exactly; the REPRO lines above carry the rate and '
                'the measured head for each one.' % (vid, nbadcell, ncell, expect, it))


# ---------------------------------------------------------------------------- arming from silence
#
# THE OPERATOR PRESSES CAPTURE WHILE THE LINE IS QUIET. The app arms the digitizer's analog
# comparator and waits; when the device under test starts transmitting the window opens, and it opens
# BEFORE the first start bit because the trigger model holds a pre-trigger reserve of sdec.pretrig per
# cent of capacity. On this bench "the device starts" is the generator's output switch, thrown from a
# host thread while the press is still blocked inside the instrument.
#
# WHY A SUITE HERE AND NOT ONLY tools/bench_arm.py. bench_arm is the GATE -- sixteen cases, run once a
# release from release_sweep's hw-arm stage. Three defects in this path were all of the shape a single
# green run licenses: one was 0 of 6 captures readable at a locked 9600, and the other two returned
# the RIGHT BYTE COUNT with the bytes inverted. The honest measurement of that class is a RATE, and a
# rate needs laps. The on-instrument soak cannot supply them: bench/bench_run.tsp sets
# sdec.trigmode = 'free' deliberately, so nothing it runs ever arms. A host-driven soak lap is the
# only lap that does.
#
# A BYTE COUNT IS NOT AN ASSERTION HERE, because that is exactly what the second defect passed: 2110
# of 5484 bytes bad with the count correct. Every cell checks the polarity the capture CHOSE
# (sdec.res.invert, sdec.idle), the evidence it chose it FROM (sdec.leadrun against sdec.run0) and the
# vector's own text among the bytes.
#
# IT IS ITS OWN SUITE AND IT TOUCHES NOTHING IN suite_plan. The plan's lap is 1677 cells, docs/BENCH.md
# derives that number and every ratchet in tools/plan_sweep.py is calibrated on it, so a cell added
# there invalidates all of it. This is additive and costs the plan nothing.

ARM_BAUD = 9600
# 9600 IS NOT AN ARBITRARY BENCH RATE HERE. At a locked 9600 the app picks the locked rate's own fs,
# where the pre-trigger reserve is LONGER than the vector's inter-byte idle gap -- so the reserve is
# the longest run in the record and a polarity prior taken from run length reads the switched-off wire
# as the line's idle level. That is the regime the first defect lived in: 0 of 6 readable. At the blind
# rate the app samples faster, the gap wins, and the same defect was only intermittent.
ARM_LEVEL = 1.0              # Arm At: the shipped default, inside sdec.armlevel_min..max (0.33..6.0)
ARM_WAIT = 10.0              # Arm Wait for a cell whose device DOES start
# AND A SHORT ONE FOR THE CELL WHOSE DEVICE NEVER STARTS, because that cell's cost IS its wait. Three
# seconds is what bench_arm case E uses and it is comfortably above the 2 s floor the panel allows.
ARM_EXPIRE_WAIT = 3.0
ARM_START_AT = 3.0           # when the thread throws the output switch, i.e. when the device starts
# SIXTY COLUMNS OF THE DECODED TEXT, so 'Hello, World!' fits four times over. One occurrence can be a
# coincidence of a mis-sampled bit; the test below asks for two, which no inverted reading produces.
ARM_TEXT_COLS = 60

# THE BIPOLAR BAND. A real RS-232 line straddles ground, and that is the OPPOSITE polarity direction of
# the same defect: its correct answer is invert = TRUE and idle = 0, which is what makes it a control
# rather than a repeat of the cells above.
#
# IT MUST BE v45 AND NOT v41, AND THAT IS A TRAP THIS REPO HAS FALLEN INTO. Both span codewords
# 0..21626, but v41 idles at 21626 -- its mark is the HIGH level -- while v45 is the inverted rendering
# and idles at 0. So v45 at a negative offset puts the MARK on the negative level, which is a line a
# wire can carry; v41 there gives idle positive and space negative, which sig_levels reads as RS-232
# marking at the SPACE level and decodes inverted. That is this repo's own harness artefact, not a
# decoder defect -- see the straddling-window arithmetic in soakplan.amp_ofst_for, which exists to keep
# the plan's draw out of exactly that region. This suite drives INTO it on purpose, on the one vector
# for which it is physical.
#
# AND NOT AT THE CAP. The generator's envelope is |OFST| + AMP/2 <= 10 on the NOMINAL pair and it
# clamps silently, so a symmetric band of +/-X costs X + amp_for(2X)/2 = 4.0303 X, capping X at
# 2.4812 V. A pair commanded exactly at the limit turns a float comparison into the experiment, so the
# band is +/-2.45: 31 mV below the cap, which spends 9.874 V of the 10 V envelope. assert_unclipped
# checks it before the write rather than after the verdict.
ARM_BIPOLAR_SWING = 4.90
ARM_BIPOLAR_OFST = -2.45

# THE FOUR LOCK STATES, as TSP. @BAUD@ is substituted at the call site so one table serves any rate.
#
# 'autolock' IS THE HARD ONE AND IT IS THE APP'S DEFAULT AFTER ONE AUTO-LOCK. autolock_try() sets
# nbits/par/nstop and deliberately leaves force_invert nil, and in that state decode_from takes the
# forced-format branch, which reads `inv = (sdec.idle == 0)` with no second polarity searched and no
# margin -- so a wrong prior has nothing to overturn it. The other states have ua_autoformat's contest
# as a backstop. Measured with the guard disabled on the instrument: the mechanism check fails in all
# three states, the BYTE check only in this one.
ARM_LOCKS = {
    'blind': 'sdec.force_baud = nil sdec.force_nbits = nil sdec.force_par = nil '
             'sdec.force_nstop = nil sdec.force_invert = nil sdec.autolock_set = nil',
    'rate': 'sdec.force_baud = @BAUD@ sdec.force_nbits = nil sdec.force_par = nil '
            'sdec.force_nstop = nil sdec.force_invert = nil sdec.autolock_set = nil',
    'autolock': 'sdec.force_baud = @BAUD@ sdec.force_nbits = 8 '
                'sdec.force_par = sdec.PAR_NONE sdec.force_nstop = 1 '
                'sdec.force_invert = nil sdec.autolock_set = '
                '{baud = true, nbits = true, par = true, nstop = true}',
}

# THE CELLS, IN AN ORDER THAT IS PART OF THE TEST. Six of the seven vary exactly one thing against the
# first; the seventh varies only WHAT RAN BEFORE IT, which is the whole of the third defect.
#
#   idle/invert are the CORRECT answers for the band, not hopes: a single-supply line marks HIGH
#   (idle 1, invert false) and the bipolar line marks at its negative level (idle 0, invert true).
ARM_CELLS = [
    # THE CELL THAT WAS 0 OF 6 READABLE. Most sensitive of the set, in every lap: at a locked 9600 the
    # reserve out-runs the vector's real idle gap, so run length alone points the prior at the
    # switched-off wire.
    {'name': 'frame locked', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'frame', 'lock': 'rate', 'starts': True, 'wait': ARM_WAIT,
     'idle': 1, 'invert': False, 'fs': 'locked',
     'why': 'the locked-rate fs, where the reserve is longer than the idle gap'},
    # THE OTHER REGIME, AND CHEAP. The blind armed capture samples at sdec.arm_fs(), where the gap wins
    # and the same defect was only intermittent. A pass here with a failure above is the signature of a
    # reserve-derived prior rather than of a broken comparator.
    {'name': 'frame auto', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'frame', 'lock': 'blind', 'starts': True, 'wait': ARM_WAIT,
     'idle': 1, 'invert': False, 'fs': 'blind',
     'why': "the blind rate's own fs, where the idle gap out-runs the reserve"},
    # THE STATE THE APP RESTS IN AFTER ONE AUTO-LOCK, which is to say the state most presses are made
    # in. Hardest cell to pass: no polarity contest at all. See ARM_LOCKS.
    {'name': 'frame autolock', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'frame', 'lock': 'autolock', 'starts': True, 'wait': ARM_WAIT,
     'idle': 1, 'invert': False, 'fs': 'locked',
     'why': 'the forced-format branch, where a wrong prior has nothing to overturn it'},
    # THE HONESTY OF THE FAILURE PATH, and the only cell where ELAPSED TIME is the discriminator: the
    # device never starts, so a press that never armed cannot hide behind a device that did.
    {'name': 'expiry', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'frame', 'lock': 'blind', 'starts': False, 'wait': ARM_EXPIRE_WAIT,
     'idle': None, 'invert': None, 'fs': None,
     'why': 'a device that never starts must say so and must not claim a trigger'},
    # THE CHUNKED PATH, WHERE THE SECOND DEFECT LIVED: ck_prime_step took its polarity prior from the
    # reserve and returned 2110 of 5484 bytes bad with the count right. A recording needs a locked rate
    # -- it sizes its buffer from one -- so this is the armed recording, not the blind rate.
    #
    # AND IT IS THE CONTROL FOR THE CELL BELOW. The levels it reuses at the press are the ones a
    # single-supply frame capture left, i.e. a mid-swing threshold, which strm_relevel is required to
    # KEEP. The stale cell differs only in what preceded it.
    {'name': 'rec8k locked', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'sml', 'lock': 'rate', 'starts': True, 'wait': ARM_WAIT,
     'idle': 1, 'invert': False, 'fs': None, 'lvlthr': 'mid',
     'why': 'ck_prime_step, reusing a mid-swing threshold it must keep'},
    # THE OPPOSITE POLARITY DIRECTION, on the one vector for which a negative offset is physical. Its
    # correct answer is invert TRUE, so a decoder that simply always inverts fails here while passing
    # every cell above. It also leaves lvl_thr near ground, which is the cell below's premise.
    {'name': 'bipolar', 'vid': 'v45', 'swing': ARM_BIPOLAR_SWING, 'ofst': ARM_BIPOLAR_OFST,
     'mode': 'frame', 'lock': 'autolock', 'starts': True, 'wait': ARM_WAIT,
     'idle': 0, 'invert': True, 'fs': 'locked',
     'why': 'a ground-straddling line, where the right answer is INVERTED'},
    # THE THIRD DEFECT, WHICH IS A CELL ORDER AND NOT A SETTING. Arming from silence CANNOT measure the
    # line -- that is the premise -- so stream_begin reuses the last levels it trusted. After the
    # bipolar cell those are a threshold of about -0.012 V, which on a 0.00..3.30 V line sits six
    # millivolts from the bottom rail: inside the band, and inside the hysteresis sig_edges needs to
    # call a crossing, so no sample ever crosses it. Measured before the fix: a transmitting device
    # read as silent and an 8 kB recording ended 'quiet' with 0 bytes, blaming the frame format.
    {'name': 'rec8k stale', 'vid': 'v41', 'swing': NOMINAL_SWING, 'ofst': 0.0,
     'mode': 'sml', 'lock': 'rate', 'starts': True, 'wait': ARM_WAIT,
     'idle': 1, 'invert': False, 'fs': None, 'lvlthr': 'rail',
     'why': 'the reused threshold is uncrossable and must be replaced mid-run'},
]

# fmt_text() CAN RAISE -- it formats fields a refused capture never set -- so it is asked for inside a
# pcall. Every other expression below is nil-safe by construction: `sdec.res ~= nil and X or default`
# is the shape the probes use, and it is right for 0 as well, because Lua counts 0 as true.
ARM_FMT = "(function() local ok, v = pcall(sdec.fmt_text) if ok then return v end return '?' end)()"

# THE EVENT LOG, DRAINED IN ONE EXPRESSION. Drained rather than cleared, because the CODES are what
# say whether a 4915 or a 2208 stood behind a failure, and drained per cell so a popup the operator
# would have seen cannot be attributed to the wrong one.
#
# 2728/2731/2732 ARE THIS SUITE'S OWN TRAFFIC and are filtered out here as they are in mx_point. An
# armed capture runs a trigger model and the teardown aborts one, and a socket command against a
# running model files 2728 by design -- so reporting them would make every clean cell look eventful.
# The RAW count travels separately as `ec`, so a filtered-empty string beside a non-zero count says
# the events were all expected rather than that there were none.
ARM_EVS = ("(function() local s, n = '', eventlog.getcount() "
           "for i = 1, n do local c = eventlog.next() "
           "if c ~= 2728 and c ~= 2731 and c ~= 2732 then s = s .. tostring(c) .. ' ' end end "
           "return s end)()")

# EVERY FIELD AN ARM CELL IS JUDGED ON OR REPORTED BY, read back after the press.
ARM_FIELDS = [
    # Did the press raise, and what did sdec.capture() itself return. pcall succeeding is NOT the app
    # accepting: capture() returns false without raising when it refuses, and on that path the panel
    # keeps the PREVIOUS capture's bytes -- so every check below could otherwise pass on leftovers.
    ('pok', 'tostring(armpok)'),
    ('cret', 'tostring(armwhy)'),
    # THE RAW EVENT COUNT, READ BEFORE ARM_EVS DRAINS THE LOG and therefore in an earlier reply. A
    # tagged read that has to be retried would drain the log on its lost attempt and come back empty,
    # so a count taken only there could report zero events over a press that filed several.
    ('ec', 'eventlog.getcount()'),
    # THE PREMISE. An assertion about the reserve is vacuous if there was no reserve: acq_pretrig is
    # set only on the exit that actually triggered, and leadrun is how much of it reached the record.
    ('pretrig', 'tostring(sdec.acq_pretrig)'),
    ('lead', 'sdec.leadrun'),
    ('run0', 'sdec.run0'),
    ('run1', 'sdec.run1'),
    ('st0', 'sdec.st0'),
    # THE VERDICT ON THE PRIOR, and the flag saying which branch reached it. sig_idle counts RECURRING
    # interior runs: two or more and the run branch decides, fewer and the level branch does and sets
    # idle_weak. A cell that flips branch between laps is worth seeing even when it still passes.
    ('idle', 'sdec.idle'),
    ('weak', 'tostring(sdec.idle_weak)'),
    ('fs', 'sdec.fs'),
    ('nread', 'sdec.nread'),
    # THE MODE THAT WAS ASKED FOR, NOT THE PATH THAT RAN. An armed capture that never triggers falls
    # back to acq_free and does NOT clear sdec.trigmode, so this reading 'edge' does not mean the
    # comparator fired. lasterr is where that shows.
    ('trigreq', 'tostring(sdec.trigmode)'),
    ('err', 'tostring(sdec.lasterr)'),
    ('note', 'tostring(sdec.probe_note)'),
    ('baud', 'sdec.baud'),
    ('fmt', ARM_FMT),
    ('thr', 'sdec.thr'),
    ('lo', 'sdec.lo'),
    ('hi', 'sdec.hi'),
    ('hyst', 'sdec.hyst'),
    ('fam', 'tostring(sdec.family)'),
    ('sn', 'sdec.snr_db'),
    ('nf', 'sdec.res ~= nil and sdec.res.nf or -1'),
    ('nbad', 'sdec.res ~= nil and sdec.res.nbad or -1'),
    ('ngood', 'sdec.res ~= nil and sdec.res.ngood or -1'),
    ('head', 'sdec.res ~= nil and sdec.res.headsusp or -1'),
    ('inv', 'sdec.res ~= nil and tostring(sdec.res.invert) or "?"'),
    ('text', 'sdec.res ~= nil and sdec.ua_text_line(1, %d) or "-"' % ARM_TEXT_COLS),
    # The recording path's own ending, byte count, arm flag and whether it reused a threshold.
    ('endwhy', 'tostring(sdec.ck_endwhy)'),
    ('ckn', 'sdec.ck_nbytes'),
    ('armed', 'tostring(sdec.strm_armed)'),
    ('reuse', 'tostring(sdec.strm_lvlreuse)'),
    ('lvlthr', 'sdec.lvl_thr'),
    ('job', 'tostring(sdec.ck_job ~= nil)'),
    ('evs', ARM_EVS),
]

# WHAT THE NEXT CELL'S PREMISE IS READ FROM, BEFORE THE PRESS RATHER THAN AFTER IT. lvl_thr is kept
# across captures on purpose, so the only moment it says what THIS press will reuse is before it runs.
ARM_BEFORE = [('lvlthr', 'sdec.lvl_thr'), ('lvlswing', 'sdec.lvl_swing'),
              ('minswing', 'sdec.minswing')]

# HOW LONG AN ASSEMBLED TAGGED STATEMENT MAY GET. A one-line probe past about 1 kB comes back as -363
# with no sentinel, which reads as a hung instrument -- so the field list is SPLIT into statements
# that fit, rather than trusted to fit. 700 leaves a third of the measured limit spare, because the
# limit is a measurement rather than a documented number.
ARM_STMT_MAX = 700
# AND THE BUDGET IS THE LIMIT LESS WHAT bench_sync.tagged ADDS, measured off its own escaping helper
# rather than guessed: the wrapper, the format string and the nonce are most of a short statement, so
# a budget that counted only the expressions would be out by a factor of two. Reading BS._ENC here
# means a rename raises at import rather than letting the two drift.
ARM_STMT_FIXED = len(BS._ENC) + 60
# '__bse()' plus the ', ' separator plus the '|%s' the format string grows by, per field.
ARM_FIELD_FIXED = 12


def arm_read(d, pairs, timeout=90):
    """Several instrument values, in as few tagged replies as the line limit allows. -> dict or None.

    bench_sync.tagged() rather than one d.q() per field: it carries a nonce inside the reply, escapes
    the delimiters, and checks the FIELD COUNT -- so a stale line or an unsolicited event line is
    skipped instead of being handed back as data. Eight bare reads once desynced by one and every
    value still looked plausible, which is the failure this exists to make impossible.

    GROUPED RATHER THAN ONE REPLY, only because of ARM_STMT_MAX. Values inside a group are mutually
    consistent, which is what matters; across groups nothing moves, because the press has returned
    and the app is at rest.
    """
    budget = ARM_STMT_MAX - ARM_STMT_FIXED
    out, group, n = {}, [], 0
    for name, expr in pairs:
        cost = len(expr) + ARM_FIELD_FIXED
        if cost > budget:
            raise SystemExit('REFUSING: the expression for %r is %d characters, which leaves no room '
                             'for the %d bytes bench_sync.tagged adds inside the %d-byte probe limit'
                             % (name, len(expr), ARM_STMT_FIXED, ARM_STMT_MAX))
        if group and n + cost > budget:
            got = BS.tagged(d, group, timeout=timeout)
            if got is None:
                return None
            out.update(got)
            group, n = [], 0
        group.append((name, expr))
        n += cost
    if group:
        got = BS.tagged(d, group, timeout=timeout)
        if got is None:
            return None
        out.update(got)
    return out


def arm_start_later(g, delay_s, hit):
    """The device starts transmitting after delay_s: the generator's output switch, from a THREAD.

    A THREAD BECAUSE THE PRESS BLOCKS. sdec.capture() does not return until the arm fires or expires,
    so the session cannot throw the switch itself. The generator is a second socket, so the two never
    contend. Daemon, so a lap that abandons a press cannot be held open by it.

    WHETHER IT ACTUALLY THREW IS PART OF THE VERDICT, which is why `hit` comes back: a generator that
    refused the write leaves a capture that correctly found nothing, and reading that as an arm defect
    is how a wedged SDG gets filed against the app.
    """
    def body():
        time.sleep(delay_s)
        try:
            g.output(True, ch=1)
            hit['on'] = time.time()
        except Exception as e:                      # noqa: BLE001 -- reported, not raised
            hit['err'] = str(e)
    th = threading.Thread(target=body, daemon=True)
    th.start()
    return th


def arm_press(d, tag, timeout):
    """One Capture press through the real app path, timed on the HOST. -> (elapsed, raised_text).

    THE ELAPSED TIME IS A DISCRIMINATOR NOTHING ELSE SUPPLIES, and it needs no instrumentation of the
    app: an arm that engaged blocks until the device starts or the wait runs out, a press that never
    armed returns in a second or two, and a press the queued-press absorb swallowed returns in about
    0.01 s carrying the PREVIOUS run's verdict.

    TIMED ON THE HOST, NOT WITH timer.gettime(). The instrument has ONE global timer and
    strm_absorb_arm() uses it as the TIMESTAMP for 'a recording just ended, so the next press is its
    Stop' -- so clearing it in order to time a press makes an arm from minutes ago look current,
    capture() returns WITHOUT CAPTURING, and the panel's previous result is reported as this press's
    answer. arm_setup disarms that flag instead and never touches the timer.

    BRACKETED BY A NONCE RATHER THAN READ AS ONE LINE. hw_config re-arms localnode.showevents and this
    instrument then volunteers event lines on the control socket, so a single read can return an event
    line instead of the answer -- which is a desync rather than a wrong number, and it cascades into
    every later read. The result line carries the nonce; anything else is skipped.
    """
    want = '%s#%s' % (_slug(tag), BS.nonce('arm'))
    d.drain()
    t0 = time.time()
    d.send("armpok, armwhy = pcall(sdec.capture) print('AR %s ' .. tostring(armpok))" % want)
    raised = None
    while True:
        left = timeout - (time.time() - t0)
        if left <= 0:
            return time.time() - t0, None
        slice_s = min(300.0, left)
        t1 = time.time()
        ln = d.line(slice_s)
        if ln is None:
            # d.line RETURNS None FOR TWO DIFFERENT THINGS and they need opposite handling: a read
            # timeout (the instrument is still working -- keep waiting) and a CLOSED socket (nothing
            # will ever arrive). Telling them apart by how long the read took is crude and exact
            # enough; without it the closed case spins on a non-blocking read for the whole timeout.
            if time.time() - t1 < slice_s * 0.5:
                return time.time() - t0, None
            continue
        f = ln.split()
        if len(f) >= 3 and f[0] == 'AR' and f[1] == want:
            raised = f[2]
            break
    el = time.time() - t0
    # hw_config re-arms showevents inside the capture, and an unsolicited event line desyncs every
    # later read. Set back to SEV_ERROR by the suite's teardown, not left at 0.
    d.exec('localnode.showevents = 0')
    return el, raised


def arm_setup(d, cell, baud):
    """Put the app in this cell's state, with every leftover from the last cell cleared."""
    # A CHUNKED JOB LEFT OPEN MAKES THE NEXT PRESS CONTINUE IT rather than start a capture, which is a
    # three-way dispatch in capture_run() and not something a cell should inherit from its neighbour.
    d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil '
           'sdec.ck_stop, sdec.ck_tot, sdec.ck_nbytes, sdec.ck_endwhy = false, nil, nil, nil')
    # THE QUEUED-PRESS ABSORB, CLEARED RATHER THAN SLEPT OUT. A Capture press within
    # sdec.strm_absorb_s of a recording ending is taken as that run's Stop and returns immediately --
    # by design, because a press aimed at stopping a stream is only dispatched once the run's Lua has
    # returned. Two of the three defects here are recordings, so without this the cell after each one
    # returns in 0.01 s carrying its predecessor's verdict, which reads as a broken arm.
    d.exec('sdec.strm_stopped_by_press = nil sdec.strm_nabsorbed = 0 sdec.strm_absorbed = nil')
    d.exec('sdec.capmode = %r sdec.trigmode = "edge" sdec.trigext = false '
           'sdec.trigext_only = false sdec.fc_out = false sdec.armkey = true '
           'sdec.armlevel = %g sdec.armwait = %g sdec.lasterr = nil '
           'sdec.probe_note = nil sdec.probe_idle = nil sdec.acq_pretrig = nil '
           'armpok, armwhy = nil, nil'
           % (cell['mode'], ARM_LEVEL, cell['wait']))
    d.exec(ARM_LOCKS[cell['lock']].replace('@BAUD@', str(baud)))
    d.exec('eventlog.clear() localnode.showevents = 0')


def arm_lua_literal(s, default='nil'):
    """One entry value as a Lua literal, for handing the operator's own setting back.

    THE OPERATOR'S VALUES, NOT THE DEFAULTS WRITTEN BACK AS LITERALS. A run on an instrument
    configured at 2.5 V and 30 s used to hand it back at 1 V and 10 s and call that a restore.
    """
    if s is None or s == 'nil':
        return default
    if s in ('true', 'false'):
        return s
    try:
        float(s)
        return s
    except ValueError:
        return repr(s)


def arm_claims(cell, r, el, hit, fsmap, before):
    """Every claim this cell makes about its own result. -> [(text, bool), ...]

    ONE LIST PER CELL RATHER THAN ONE BOOLEAN, so a failing row NAMES the claim that broke. The row's
    verdict is the conjunction; the detail carries the fields either way.
    """
    cl = []
    nf, nbad = num(r, 'nf', -1), num(r, 'nbad', -1)
    text = r.get('text') or ''
    lead, run0 = num(r, 'lead', 0), num(r, 'run0', 0)

    if not cell['starts']:
        # THE EXPIRY. It must wait the operator's Arm Wait and no longer, name the degrade and the two
        # settings that govern it, and -- the part a message cannot fake -- NOT claim a trigger.
        cl.append(('waits the operator Arm Wait and no longer',
                   2.0 <= el <= cell['wait'] + 9.0))
        cl.append(('says the arm expired and the capture degraded to free-running',
                   'trigger unavailable; captured free-running' in (r.get('err') or '')))
        cl.append(('names the armed level and both settings that govern the wait',
                   'crossed' in (r.get('err') or '')
                   and 'raise Arm Wait or lower Arm At' in (r.get('err') or '')))
        cl.append(('does NOT report a pre-trigger reserve it never had',
                   r.get('pretrig') != 'true'))
        cl.append(('publishes no bytes out of the silence', nf <= 0))
        return cl

    # THE GENERATOR FIRST. A switch that never got thrown leaves a capture that correctly found
    # nothing, and charging that to the app is how a wedged SDG becomes a decoder defect.
    cl.append(('the generator threw its output switch',
               'on' in hit and 'err' not in hit))
    # NOT ABSORBED, and this is the only time bound a starting cell can carry: a fired arm returns at
    # about ARM_START_AT, which is indistinguishable BY TIME from the V1.40 press that never armed and
    # returned in 3.55 s. What separates those two is the reserve, asserted next.
    cl.append(('the press was not swallowed by the absorb window', el > 1.0))
    cl.append(('the app accepted the capture', r.get('pok') == 'true' and r.get('cret') != 'false'))

    if cell['mode'] == 'frame':
        # THE PREMISE, BEFORE ANYTHING ABOUT THE PRIOR. acq_pretrig is set only on the exit that
        # really triggered, and leadrun is how much of the reserve reached the record. 500 samples is
        # well under the reserve at either fs and well over anything a UART gap can make.
        cl.append(('the record opens in a pre-trigger reserve',
                   r.get('pretrig') == 'true' and lead > 500))
        cl.append(('the arm fired rather than running out its wait', el < cell['wait'] * 0.95))
        if cell['idle'] == 1:
            # THE MECHANISM, and only where the reserve has a level to be confused with. On a
            # single-supply line the switched-off wire sits at ground, which IS the space level, so a
            # reserve counted as a run would be the longest run at level 0. On the bipolar cell ground
            # sits BETWEEN the levels and lands in whichever run millivolts decide, so the same test
            # there would be a coin toss rather than a check.
            cl.append(('the reserve is not counted as the longest low run',
                       lead > 0 and run0 < lead / 2.0))
    else:
        # A RECORDING HAS NO acq_pretrig TO READ -- it arms through the streaming path -- so its
        # premise is strm_armed, and the proof it waited for the device rather than ending on its own
        # clock is that it outlasted the switch and did not end as 'noarm'.
        cl.append(('the recording ARMED rather than recording the silence',
                   r.get('armed') == 'true'))
        cl.append(('it waited for the device rather than ending on its own clock',
                   el > ARM_START_AT and r.get('endwhy') != 'noarm'))
        # THE THIRD DEFECT'S OWN OUTCOME. 'quiet' with 0 bytes on a transmitting device is what a
        # threshold the signal cannot cross produces, and it blamed the frame format when it happened.
        cl.append(('the recording ran to its bound rather than reading a live line as quiet',
                   r.get('endwhy') == 'full'))
        cl.append(('and left no job open', r.get('job') == 'false'))
        # AND THE PREMISE OF THE REUSE, taken BEFORE the press because lvl_thr is kept across captures
        # and this press overwrites it. Without it the cell is a pass whatever ran before it, which is
        # the whole of what it was supposed to measure.
        pre = num(before, 'lvlthr')
        if cell.get('lvlthr') == 'rail':
            cl.append(('the threshold it inherited really was the bipolar cell\'s, near ground',
                       pre is not None and abs(pre) < 0.25))
        elif cell.get('lvlthr') == 'mid':
            cl.append(('the threshold it inherited really was mid-swing',
                       pre is not None and 0.5 < pre < 3.0))

    # THE PRIOR, THE POLARITY AND THE BYTES. These three are what the defects reached the operator as.
    cl.append(('the prior is the line, not the switched-off wire', num(r, 'idle', -1) == cell['idle']))
    cl.append(('the bytes are the right way up',
               r.get('inv') == ('true' if cell['invert'] else 'false')))
    # TWICE, NOT ONCE. One occurrence of a 13-byte payload in 60 columns can survive a mis-sampled
    # bit; two cannot, and an inverted reading produces none at all.
    cl.append(("and they are the line's own text, at least twice over",
               text.count(PAYLOAD) >= 2))
    if cell['mode'] == 'frame':
        # ONE BAD FRAME IS THE STIMULUS, NOT THE APP, and the allowance is bounded rather than waived:
        # the generator's output switch opens wherever the arb happens to be, so the frame it opens in
        # the middle of is a fragment by construction. A device powering up does not do that -- it
        # starts at a start bit -- but nothing on this bench can emulate one. Two or more is a decode
        # fault and still fails.
        cl.append(('nearly every frame clean', 0 <= nbad <= 1))
    else:
        cl.append(('nearly every frame clean', 0 <= nbad <= max(1.0, 0.02 * num(r, 'ckn', 0))))
    gb = num(r, 'baud')
    cl.append(('the rate reported is the rate on the wire',
               gb is not None and abs(gb / float(ARM_BAUD) - 1.0) <= RATE_TOL))
    if cell['fs'] is not None:
        # THE REGIME, CHECKED AGAINST THE APP'S OWN ARITHMETIC rather than against 80000 and 200000
        # written here. A locked rate skips the probe ladder and samples at that rate's own fs; a blind
        # armed capture samples at sdec.arm_fs(). Reading them off the instrument is what keeps this
        # cell honest when either constant moves.
        want_fs = fsmap.get(cell['fs'])
        got_fs = num(r, 'fs')
        cl.append(('sampled in the %s-rate regime it was set up for' % cell['fs'],
                   want_fs is not None and got_fs is not None and abs(got_fs - want_fs) <= 1.0))
    return cl


def arm_detail(cell, r, el, before):
    """The fields a failure has to be diagnosed from, on every row and not only the failures."""
    bits = ['%.2f s' % el,
            'fs %s' % fmt_num(r.get('fs'), '%.0f'),
            'n %s' % fmt_num(r.get('nread'), '%.0f'),
            'lead %s' % fmt_num(r.get('lead'), '%.0f'),
            'run0/1 %s/%s' % (fmt_num(r.get('run0'), '%.0f'), fmt_num(r.get('run1'), '%.0f')),
            'pretrig %s' % r.get('pretrig', '?'),
            'idle %s%s' % (r.get('idle', '?'), ' WEAK' if r.get('weak') == 'true' else ''),
            'inv %s' % r.get('inv', '?'),
            'thr %s' % fmt_num(r.get('thr'), '%.3f'),
            'band %s..%s' % (fmt_num(r.get('lo'), '%.2f'), fmt_num(r.get('hi'), '%.2f')),
            '%s B' % fmt_num(r.get('nf'), '%.0f'),
            '%s bad' % fmt_num(r.get('nbad'), '%.0f'),
            '%s' % r.get('fmt', '?'),
            '%s Bd' % fmt_num(r.get('baud'), '%.0f')]
    if cell['mode'] != 'frame':
        bits += ['endwhy %s' % r.get('endwhy', '?'),
                 'ck %s B' % fmt_num(r.get('ckn'), '%.0f'),
                 'armed %s' % r.get('armed', '?'),
                 'reuse %s' % r.get('reuse', '?'),
                 'lvl_thr %s -> %s' % (fmt_num(before.get('lvlthr'), '%.4f'),
                                       fmt_num(r.get('lvlthr'), '%.4f'))]
    bits.append('text %r' % (r.get('text') or '')[:40])
    return '  '.join(bits)


def suite_arm(d, g, a, rows):
    """Arming from silence: press Capture on a quiet line, switch the device on mid-wait.

    SEVEN CELLS AND THE ORDER IS PART OF THE TEST -- see ARM_CELLS. Six vary one thing against the
    first; the seventh varies only what ran before it, which is the whole of the third defect.
    """
    print('\n=== ARM -- %d cells, Capture pressed on a silent line, the device switched on at +%.1f s '
          '===' % (len(ARM_CELLS), ARM_START_AT))
    # THE OPERATOR'S OWN SETTINGS AND THE APP'S OWN ARITHMETIC, READ RATHER THAN ASSUMED. The entry
    # values are handed back by the teardown; arm_fs and the locked rate's fs are what the regime
    # claims are checked against, so that a changed constant moves the expectation with it.
    entry = arm_read(d, [('capmode', 'sdec.capmode'), ('trigmode', 'sdec.trigmode'),
                         ('armlevel', 'sdec.armlevel'), ('armwait', 'sdec.armwait'),
                         ('armkey', 'tostring(sdec.armkey)'),
                         ('trigext', 'tostring(sdec.trigext)'),
                         ('trigextonly', 'tostring(sdec.trigext_only)'),
                         ('fcout', 'tostring(sdec.fc_out)'),
                         ('blind', 'sdec.arm_fs()'),
                         ('locked', 'sdec.fs_for_baud(%d)' % ARM_BAUD),
                         ('pretrigpct', 'sdec.pretrig'),
                         ('absorb', 'sdec.strm_absorb_s')])
    if entry is None:
        rows.append(('arm preflight', False,
                     'the app state would not come back on a tagged read -- no cell was run'))
        print('  REFUSING the arm suite: the app state would not come back on a tagged read')
        return
    fsmap = {'blind': num(entry, 'blind'), 'locked': num(entry, 'locked')}
    print('    entry: capmode=%s trigmode=%s armlevel=%s armwait=%s   (handed back on the way out)'
          % (entry.get('capmode'), entry.get('trigmode'), entry.get('armlevel'),
             entry.get('armwait')))
    print('    arm:   Arm At %.2f V, Arm Wait %.1f s, reserve %s %% of capacity, absorb %s s; '
          'fs blind %s / locked %s'
          % (ARM_LEVEL, ARM_WAIT, entry.get('pretrigpct'), entry.get('absorb'),
             fmt_num(fsmap['blind'], '%.0f'), fmt_num(fsmap['locked'], '%.0f')))
    try:
        for cell in ARM_CELLS:
            amp = amp_for(cell['swing'])
            # THE BAND IS CHECKED AGAINST BOTH INSTRUMENTS BEFORE THE WRITE, not after the verdict.
            # The SDG clamps rather than refusing, so an out-of-envelope pair reaches the wire as a
            # band nothing recorded -- and the bipolar cell is the one that goes near the envelope.
            SP.assert_unclipped(cell['vid'], amp, cell['ofst'])
            g.output(False, ch=1)
            g.select_arb(VN.arb(cell['vid']), amp, _srate(cell['vid'], ARM_BAUD),
                         offset_v=cell['ofst'])
            # OFF AGAIN AFTER THE SELECT, because a device that has not started is what this suite
            # presses Capture against. select_arb never touches the output relay, so this is belt and
            # braces against a reordering rather than a redundancy.
            g.output(False, ch=1)
            time.sleep(a.settle)
            arm_setup(d, cell, ARM_BAUD)
            before = arm_read(d, ARM_BEFORE) or {}
            hit = {}
            th = None
            if cell['starts']:
                th = arm_start_later(g, ARM_START_AT, hit)
            # A RECORDING IS THE WHOLE 8 kB WINDOW PLUS ITS DECODE, which is tens of seconds; a frame
            # is the wait plus a decode. Generous rather than tight: this is a hang detector, not a
            # latency budget, and a press abandoned early would leave the app mid-capture.
            el, raised = arm_press(d, 'arm_' + cell['name'],
                                   600 if cell['mode'] != 'frame' else 120)
            if th is not None:
                # JOINED PAST THE THREAD'S OWN SCHEDULE, not for a courtesy second. A press the absorb
                # window swallowed returns in about 0.01 s, so the thread has not thrown the switch
                # yet -- and a 1 s join leaves it to fire into the NEXT cell's select_arb, two writers
                # interleaving SCPI on one generator socket. The thread cannot outlive its sleep plus
                # one write, so this always finds it finished unless the generator itself is hung.
                th.join(timeout=max(2.0, ARM_START_AT + 5.0 - el))
                if th.is_alive():
                    hit['err'] = ('the output-switch thread is still running %.1f s after the press '
                                  'returned -- the generator is not answering' % el)
                    print('      *** %s ***' % hit['err'])
            r = arm_read(d, ARM_FIELDS)
            if r is None:
                rows.append(('arm %s' % cell['name'], False,
                             'the result fields would not come back on a tagged read after a '
                             '%.2f s press' % el))
                print('  %-16s %-5s the result fields would not come back after %.2f s'
                      % (cell['name'], 'BAD', el))
                continue
            cl = arm_claims(cell, r, el, hit, fsmap, before)
            ok = all(c for _, c in cl)
            det = arm_detail(cell, r, el, before)
            print('  %-16s %-5s %s' % (cell['name'], 'ok' if ok else 'BAD', det))
            print('      %s' % cell['why'])
            if r.get('err') not in (None, 'nil', ''):
                print('      lasterr: %s' % r['err'][:110])
            # THROUGH note_events, so an arm cell's events land in the same run-level tally main()
            # prints for every other suite rather than in a counter only this suite knows about. 4915
            # is split out here rather than in ARM_EVS because the log can only be drained once: the
            # instrument returns every code it had, and the partition is cheaper on this side.
            codes = [x for x in (r.get('evs') or '').split() if x]
            n4915 = codes.count('4915')
            note_events({'e4915': n4915, 'evs': [c for c in codes if c != '4915']})
            if n4915:
                print('      *** %d x event 4915 ***' % n4915)
            elif num(r, 'ec', 0) and not codes:
                print('      (%s instrument event(s) logged, all of them trigger-model traffic this '
                      'suite causes itself)' % fmt_num(r.get('ec'), '%.0f'))
            if not ok:
                for text, got in cl:
                    if not got:
                        print('      BROKEN CLAIM: %s' % text)
                print('      REPRO %s: %s at %.3f Vpp offset %+0.3f V, %s, %s lock, device %s, '
                      'Arm At %.2f V Arm Wait %.1f s'
                      % (cell['name'], cell['vid'], amp, cell['ofst'], cell['mode'], cell['lock'],
                         ('on at +%.1f s' % ARM_START_AT) if cell['starts'] else 'never starts',
                         ARM_LEVEL, cell['wait']))
                print('      raised=%s cret=%s note=%s' % (raised, r.get('cret'), r.get('note')))
            # THE DRIVEN BAND TRAVELS WITH THE ROW, because the bipolar cell's whole point is its
            # offset and a row that only named the vector could not be told from a single-supply one.
            rows.append(('arm %s' % cell['name'], ok,
                         '%s %.3f Vpp ofst %+0.3f %s/%s  %s'
                         % (cell['vid'], amp, cell['ofst'], cell['mode'], cell['lock'], det)))
    finally:
        # LEFTOVER APP STATE POISONS THE NEXT TOOL, and two of these cost a whole suite: capmode left
        # at 'sml' makes every later point a 27-second recording, and trigmode left at 'edge' makes
        # every later point an armed capture. The operator's own entry values go back, not defaults.
        print('    restore:')
        d.exec('sdec.capmode = %s sdec.trigmode = %s sdec.armlevel = %s sdec.armwait = %s '
               'sdec.armkey = %s sdec.trigext = %s sdec.trigext_only = %s sdec.fc_out = %s'
               % (arm_lua_literal(entry.get('capmode'), "'frame'"),
                  arm_lua_literal(entry.get('trigmode'), "'edge'"),
                  arm_lua_literal(entry.get('armlevel'), '1.0'),
                  arm_lua_literal(entry.get('armwait'), '10.0'),
                  arm_lua_literal(entry.get('armkey'), 'true'),
                  arm_lua_literal(entry.get('trigext'), 'false'),
                  arm_lua_literal(entry.get('trigextonly'), 'false'),
                  arm_lua_literal(entry.get('fcout'), 'false')))
        # EVERY FORCE AND autolock_set, because press() in this file clears the force_* fields per
        # point and does NOT clear autolock_set -- so an autolock left latched would make every later
        # point a measurement of this suite's lock state.
        d.exec(ARM_LOCKS['blind'])
        d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil '
               'sdec.ck_stop, sdec.ck_tot, sdec.ck_nbytes, sdec.ck_endwhy = false, nil, nil, nil')
        # THE QUEUED-PRESS ABSORB IS APP STATE TOO, and it is the one that makes the NEXT tool look
        # broken rather than this one: a press it swallows returns in 0.01 s with the previous run's
        # verdict attached. Armed by every recording cell above.
        d.exec('sdec.strm_stopped_by_press = nil sdec.strm_nabsorbed = 0 sdec.strm_absorbed = nil')
        # probe_idle is what arm_silent() answers from; left set it tells the next tool the line is
        # silent. arm_thr/arm_idle are the comparator's own published pair, and armpok/armwhy are this
        # suite's two globals.
        d.exec('sdec.probe_idle = nil sdec.arm_thr = nil sdec.arm_idle = nil '
               'sdec.acq_pretrig = nil armpok, armwhy = nil, nil')
        d.exec('pcall(function() trigger.blender[1].reset() end) pcall(trigger.model.abort)')
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        # AND THE GENERATOR BACK ON THE NOMINAL STIMULUS, OUTPUT ON. Every other suite selects and
        # switches on per point, so this is not strictly required -- but leaving the bipolar band
        # selected with the output off makes this suite's position in a lap visible in the next
        # suite's first row, and an order-dependent result is the hardest kind to read.
        try:
            g.select_arb(VN.arb('v41'), amp_for(NOMINAL_SWING), _srate('v41', ARM_BAUD))
            g.output(True, ch=1)
        except Exception as e:                      # noqa: BLE001
            print('      SDG restore failed: %s' % e)
        back = arm_read(d, [('capmode', 'sdec.capmode'), ('trigmode', 'sdec.trigmode'),
                            ('armwait', 'sdec.armwait'), ('armlevel', 'sdec.armlevel'),
                            ('force', 'tostring(sdec.force_baud)'),
                            ('autolock', 'tostring(sdec.autolock_set ~= nil)'),
                            ('absorbed', 'tostring(sdec.strm_stopped_by_press)'),
                            ('ev', 'eventlog.getcount(eventlog.SEV_ALL)')]) or {}
        print('      capmode=%s trigmode=%s armwait=%s armlevel=%s force_baud=%s autolock=%s '
              'absorb-armed=%s events=%s'
              % (back.get('capmode'), back.get('trigmode'), back.get('armwait'),
                 back.get('armlevel'), back.get('force'), back.get('autolock'),
                 back.get('absorbed'), back.get('ev')))


SUITES = {'formats': suite_formats, 'rates': suite_rates, 'lorem': suite_lorem,
          'levels': suite_levels, 'offsets': suite_offsets, 'hard': suite_hard,
          'payloads': suite_payloads, 'plan': suite_plan, 'arm': suite_arm}


# ---------------------------------------------------------------------------- the offline self-check
#
# WHAT IT IS FOR, AND IT IS NOT COVERAGE FOR ITS OWN SAKE. The arm suite's judging is the part that
# cannot be checked by running it: a cell that passes proves the app works OR that the claim is
# unsatisfiable in the other direction, and on hardware those two are indistinguishable. So each of
# the three defects is replayed here as the field dict it actually produced, and each must FAIL -- the
# second one twice over, because it returned the right byte COUNT and a count-only assertion passes it.
#
# NO INSTRUMENT AND NO SUBPROCESS, which is the whole point: it is runnable while a soak has the bench.
#
#     python3 tools/bench_matrix.py --selftest

def _arm_before(cell):
    """What lvl_thr held at the press, for the cell order the suite relies on."""
    if cell.get('lvlthr') == 'rail':
        # What the bipolar cell leaves: the midpoint of a +/-2.45 V line. Measured -0.0123 V.
        return {'lvlthr': '-0.0123', 'lvlswing': '4.900', 'minswing': '0.1'}
    return {'lvlthr': '1.6500', 'lvlswing': '3.300', 'minswing': '0.1'}


def _arm_clean(cell, fsmap):
    """A field dict describing a CORRECT result for this cell -- the pass side of every claim."""
    if not cell['starts']:
        return {'pok': 'true', 'cret': 'false', 'ec': '0', 'evs': '',
                'pretrig': 'false', 'lead': 'nil', 'run0': 'nil', 'run1': 'nil', 'st0': 'nil',
                'idle': 'nil', 'weak': 'nil', 'fs': '200000', 'nread': '20000',
                'trigreq': 'edge', 'note': 'nil',
                'err': 'edge trigger unavailable; captured free-running (no trigger in 3 s (edge) '
                       '-- nothing crossed 1.00 V; raise Arm Wait or lower Arm At)',
                'baud': 'nil', 'fmt': '?', 'thr': 'nil', 'lo': 'nil', 'hi': 'nil', 'hyst': 'nil',
                'fam': 'nil', 'sn': 'nil', 'nf': '-1', 'nbad': '-1', 'ngood': '-1', 'head': '-1',
                'inv': '?', 'text': '-', 'endwhy': 'nil', 'ckn': 'nil', 'armed': 'nil',
                'reuse': 'nil', 'lvlthr': '1.6500', 'job': 'false'}
    nb = 5484 if cell['mode'] != 'frame' else 334
    r = {'pok': 'true', 'cret': 'true', 'ec': '0', 'evs': '',
         'pretrig': 'true', 'lead': '1057', 'run0': '42', 'run1': '480', 'st0': '0',
         'idle': str(cell['idle']), 'weak': 'false',
         'fs': '%.0f' % (fsmap.get(cell['fs']) or fsmap['locked']),
         'nread': '21053', 'trigreq': 'edge', 'err': 'nil', 'note': 'nil',
         'baud': '9600', 'fmt': '8N1', 'thr': '1.650', 'lo': '0.00', 'hi': '3.30',
         'hyst': '0.495', 'fam': '3V3 CMOS', 'sn': '46',
         'nf': str(nb), 'nbad': '0', 'ngood': str(nb), 'head': '0',
         'inv': 'true' if cell['invert'] else 'false',
         'text': (PAYLOAD * 6)[:ARM_TEXT_COLS],
         'endwhy': 'full' if cell['mode'] != 'frame' else 'nil',
         'ckn': str(nb) if cell['mode'] != 'frame' else 'nil',
         'armed': 'true' if cell['mode'] != 'frame' else 'nil',
         'reuse': 'true' if cell['mode'] != 'frame' else 'nil',
         'lvlthr': '1.650', 'job': 'false'}
    if cell['idle'] == 0:
        # THE BIPOLAR FIXTURE PUTS run0 ABOVE HALF THE RESERVE ON PURPOSE. Ground sits between the
        # levels there, so which run the reserve lands in is decided by millivolts and the
        # longest-low-run check must not be applied -- this is what proves it is skipped rather than
        # passing by luck.
        r.update({'run0': '900', 'run1': '42', 'thr': '-0.012', 'lo': '-2.45', 'hi': '2.45',
                  'fam': '4.9Vpp', 'lvlthr': '-0.012'})
    return r


def arm_selftest():
    """Replay the three defects and the cell table through the suite's own judging. -> 0 or 1."""
    bad, tot = [], [0]

    def ck(cond, what):
        tot[0] += 1
        print('  %-4s %s' % ('ok' if cond else 'BAD', what))
        if not cond:
            bad.append(what)

    fsmap = {'blind': 200000.0, 'locked': 80000.0}
    cells = {c['name']: c for c in ARM_CELLS}
    names = [c['name'] for c in ARM_CELLS]

    print('--- the cell table')
    ck(len(set(names)) == len(names), '%d cells, every name distinct' % len(names))
    ck(all(c['lock'] in ARM_LOCKS for c in ARM_CELLS), "every cell's lock state is in ARM_LOCKS")
    ck(all(c['fs'] in (None, 'blind', 'locked') for c in ARM_CELLS),
       "every cell's fs regime is one this suite can look up")
    # THE ORDER IS THE THIRD DEFECT'S TEST. 'rec8k stale' measures what the bipolar cell left behind,
    # so a reordering silently turns it into a duplicate of 'rec8k locked' -- passing, and testing
    # nothing. Its control must come BEFORE the bipolar cell for the same reason.
    ck(names.index('rec8k locked') < names.index('bipolar') < names.index('rec8k stale'),
       "the order is rec8k locked -> bipolar -> rec8k stale, which is what makes the stale cell a test")
    ck(cells['rec8k stale']['lvlthr'] == 'rail' and cells['rec8k locked']['lvlthr'] == 'mid',
       'the two recordings assert OPPOSITE inherited thresholds, so neither is vacuous')
    # THE VECTOR TRAP, ASSERTED. v41 idles at the HIGH level, so v41 at a negative offset is a
    # stimulus no wire can carry and sig_levels reads it as marking at the SPACE level.
    ck(all(c['ofst'] >= 0.0 for c in ARM_CELLS if c['vid'] != 'v45'),
       'only v45 is ever driven at a negative offset')
    ck(all(c['vid'] == 'v45' for c in ARM_CELLS if c['ofst'] < 0.0)
       and any(c['ofst'] < 0.0 for c in ARM_CELLS),
       'and the bipolar cell really is at a negative offset')
    ck(all(c['invert'] is (c['idle'] == 0) for c in ARM_CELLS if c['idle'] is not None),
       'invert and idle agree in every cell: a line marking LOW decodes inverted')

    print('--- the bands, against both instruments')
    amp = amp_for(ARM_BIPOLAR_SWING)
    env = abs(ARM_BIPOLAR_OFST) + amp / 2.0
    cap = 10.0 / (1.0 + 10.0 / NOMINAL_SWING)
    ck(abs(cap - 2.4812) < 5e-4, 'a symmetric band caps at %.4f V on the generator envelope' % cap)
    ck(ARM_BIPOLAR_OFST < 0 and abs(ARM_BIPOLAR_OFST) < cap - 0.02,
       'the commanded %+0.2f V is %.3f V inside that cap, so no float comparison decides the test'
       % (ARM_BIPOLAR_OFST, cap - abs(ARM_BIPOLAR_OFST)))
    ck(env <= SP.SDG_ENV_V, '|OFST| + AMP/2 = %.4f V of the %.1f V envelope' % (env, SP.SDG_ENV_V))
    vmin, vmax = SP.assert_unclipped('v45', amp, ARM_BIPOLAR_OFST)
    ck(abs(vmin + 2.45) < 0.01 and abs(vmax - 2.45) < 0.01,
       'the band on the wire is %.4f .. %.4f V, symmetric about ground' % (vmin, vmax))
    for c in ARM_CELLS:
        SP.assert_unclipped(c['vid'], amp_for(c['swing']), c['ofst'])
    ck(True, 'every cell passes assert_unclipped, so none can reach the wire clamped')

    print('--- the tagged reads fit the probe limit')
    worst = 0
    for pairs in (ARM_FIELDS, ARM_BEFORE):
        n, g = 0, 0
        for _, expr in pairs:
            cost = len(expr) + ARM_FIELD_FIXED
            if g and n + cost > ARM_STMT_MAX - ARM_STMT_FIXED:
                g, n = 0, 0
            g, n = g + 1, n + cost
            worst = max(worst, n + ARM_STMT_FIXED)
    ck(worst <= ARM_STMT_MAX, 'the widest assembled statement is %d bytes, inside the %d budget'
       % (worst, ARM_STMT_MAX))
    ck(max(len(e) for _, e in ARM_FIELDS) + ARM_FIELD_FIXED <= ARM_STMT_MAX - ARM_STMT_FIXED,
       'and no single expression is too wide to send on a statement of its own')

    print('--- every cell passes on a correct result')
    for c in ARM_CELLS:
        el = 3.2 if c['mode'] == 'frame' else 27.0
        if not c['starts']:
            el = 3.4
        cl = arm_claims(c, _arm_clean(c, fsmap), el, {'on': 1.0}, fsmap, _arm_before(c))
        ck(all(v for _, v in cl) and len(cl) >= 5,
           '%-14s %d claims, all satisfied by a correct result' % (c['name'], len(cl)))

    print('--- and each defect FAILS, as the field dict it actually produced')

    def broken(cell, mutate, el=3.2, hit=None, before=None, what=''):
        r = _arm_clean(cell, fsmap)
        r.update(mutate)
        cl = arm_claims(cell, r, el, hit if hit is not None else {'on': 1.0}, fsmap,
                        before if before is not None else _arm_before(cell))
        failed = [t for t, v in cl if not v]
        ck(bool(failed), '%s -> %s' % (what, '; '.join(failed)[:96] or 'NOTHING FAILED'))
        return failed

    # DEFECT 1, as measured at a locked 9600: 158 bytes of which 62 bad, every byte inverted, the
    # prior taken from the pre-trigger reserve. Self-consistent, plausible error count, 0 of 6 readable.
    broken(cells['frame locked'],
           {'idle': '0', 'inv': 'true', 'nf': '158', 'nbad': '62', 'ngood': '96',
            'run0': '1050', 'text': '\x00' * 20 + '?' * 40},
           what='defect 1, the armed frame prior taken from the reserve (158 B, 62 bad, inverted)')
    # DEFECT 2, in the chunked path: 2110 of 5484 bytes bad with the COUNT CORRECT. The count is left
    # right on purpose -- a suite that asserted only bytes-collected passed this.
    f2 = broken(cells['rec8k locked'],
                {'idle': '0', 'inv': 'true', 'nbad': '2110', 'ngood': '3374',
                 'text': '?' * ARM_TEXT_COLS},
                el=27.0,
                what='defect 2, ck_prime_step inverted (2110 of 5484 bad, count correct)')
    ck(not any('ARMED' in t or 'collected' in t for t in f2),
       '...and it is NOT the byte count that catches it: the count was right')
    # DEFECT 3: a reused threshold six millivolts from the rail is uncrossable, so a transmitting
    # device reads as silent. 'quiet', 0 bytes, 9.7 s, and a lasterr naming the frame format.
    broken(cells['rec8k stale'],
           {'endwhy': 'quiet', 'nf': '-1', 'nbad': '-1', 'ckn': '0', 'inv': '?', 'idle': 'nil',
            'text': '-', 'err': 'no frame format fits the capture'},
           el=9.7, what='defect 3, the uncrossable reused threshold (quiet, 0 bytes)')
    # AND ITS PREMISE, WHICH IS THE CELL ORDER. If the bipolar cell did not run, the stale cell
    # inherits a mid-swing threshold and measures nothing -- that must not read as a pass.
    broken(cells['rec8k stale'], {}, el=27.0, before=_arm_before(cells['rec8k locked']),
           what='the stale cell reached with a mid-swing threshold, i.e. out of order')

    print('--- and the ways a cell can lie about itself')
    # THE V1.40 REGRESSION: the press never armed and returned in 3.55 s. The bytes are fine, because
    # the device had been transmitting for half a second -- so only the reserve catches it.
    broken(cells['frame auto'], {'pretrig': 'false', 'lead': 'nil', 'run0': 'nil'}, el=3.55,
           what='a press that never armed but decoded anyway (V1.40, 3.55 s, no reserve)')
    # THE ABSORB, which returns in ~0.01 s carrying the previous run's verdict -- every field right.
    broken(cells['frame locked'], {}, el=0.01,
           what='a press swallowed by the queued-press absorb, reporting the last run')
    # A WEDGED GENERATOR. Nothing reached the wire, so the capture correctly found nothing; charging
    # that to the app is how an instrument fault becomes a decoder defect.
    f = broken(cells['frame locked'],
               {'pretrig': 'false', 'nf': '-1', 'nbad': '-1', 'text': '-', 'idle': 'nil',
                'inv': '?'},
               el=10.1, hit={'err': 'C1:OUTP ON refused'},
               what='a generator that never threw its output switch')
    ck(any('output switch' in t for t in f),
       '...and the generator is named first, not the decode')
    # A REFUSED CAPTURE. capture() returns false without raising, and the panel then keeps the
    # PREVIOUS capture's bytes -- so every byte check below it can pass on leftovers.
    broken(cells['rec8k locked'], {'cret': 'false'}, el=27.0,
           what='a capture the app refused (ok=false) while the panel still showed good bytes')
    # AN EXPIRY THAT CLAIMS A TRIGGER, and one whose message has lost the two settings.
    broken(cells['expiry'], {'pretrig': 'true'}, el=3.4,
           what='an expiry reporting a pre-trigger reserve it never had')
    broken(cells['expiry'], {'err': 'line is idle (no transitions)'}, el=3.4,
           what='an expiry whose message names neither the degrade nor the two settings')
    broken(cells['expiry'], {'nf': '240', 'nbad': '0'}, el=3.4,
           what='an expiry that published bytes out of the silence')
    broken(cells['expiry'], {}, el=0.02,
           what='an expiry that returned at once instead of waiting its Arm Wait')
    # THE BIPOLAR CONTROL IN BOTH DIRECTIONS: a decoder that always inverts, and one that never does.
    broken(cells['bipolar'], {'idle': '1', 'inv': 'false'}, what='the bipolar line read as idle-HIGH')
    broken(cells['frame autolock'], {'idle': '0', 'inv': 'true'},
           what='a single-supply line read as idle-LOW')
    # THE REGIME. A locked cell that sampled at the blind rate's fs has not tested the locked path.
    broken(cells['frame locked'], {'fs': '200000'},
           what='a locked-rate cell that sampled at the blind arm_fs instead')
    broken(cells['frame auto'], {'fs': '80000'},
           what="a blind cell that sampled at the locked rate's fs instead")
    # AND THE TEXT, which is the only check that sees bytes that are neither flagged nor the payload.
    broken(cells['frame locked'], {'text': 'Hello, World!' + 'x' * 47},
           what='one copy of the payload and then noise, with nothing flagged')

    print('--- the row shape soak.py has to parse')
    import soak as SK
    ok_rows = 0
    for c in ARM_CELLS:
        name = 'arm %s' % c['name']
        for tok in ('ok', 'BAD'):
            ln = '%-28s %-4s %s' % (name, tok, 'v41 10.000 Vpp ofst +0.000 frame/rate  3.20 s')
            m = SK.ROW.match(ln)
            if m and m.group(1).strip() == name and m.group(2) == tok:
                ok_rows += 1
    ck(ok_rows == 2 * len(ARM_CELLS),
       "all %d point names survive soak.py's ROW regex intact, both verdicts" % len(ARM_CELLS))
    # THE FAILURE TOKEN IS THE ONE soak.py COUNTS, not one invented here. judge_lap tallies a
    # failure on the exact string 'BAD', and main() below is what emits it.
    ck('BAD' in SK.ROW.pattern and 'ok' in SK.ROW.pattern,
       "and the verdict tokens are soak.py's own ok/BAD, so a failure is counted and named")
    ck(not any(SK.ROW.match('  ' + ln) for ln in ['arm bipolar ok something']),
       'and an indented BODY line is not mistaken for a point')

    print('--- handing the operator back their own settings')
    ck(arm_lua_literal('2.5') == '2.5' and arm_lua_literal('30') == '30',
       'a number goes back as a number')
    ck(arm_lua_literal('frame') == "'frame'" and arm_lua_literal('sml') == "'sml'",
       'a mode goes back quoted')
    ck(arm_lua_literal('true') == 'true' and arm_lua_literal('false') == 'false',
       'a boolean goes back unquoted, not as the string "false"')
    ck(arm_lua_literal('nil', "'frame'") == "'frame'" and arm_lua_literal(None) == 'nil',
       'and only a MISSING value takes the default')

    print('SELFTEST %s' % ('OK -- all %d checks hold' % tot[0] if not bad
                           else 'FAILED: %d of %d checks' % (len(bad), tot[0])))
    for b in bad:
        print('   FAILED: %s' % b)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suites', default='formats,rates,lorem,levels,offsets')
    ap.add_argument('--upload', action='store_true',
                    help='upload the vectors these suites need. Large writes wedge it after '
                         'about two per power cycle, so this is a once-per-cycle flag.')
    ap.add_argument('--settle', type=float, default=0.35)
    ap.add_argument('--offset-swings', default='3.3,1.6')
    ap.add_argument('--rates', help='comma-separated subset of the rate ladder')
    # Everything the plan suite tests -- vector order, the drawn rate in each gap, the amplitude,
    # offset and wait for every cell -- comes from this number through tools/soakplan.py.
    # THE ITERATION ALONE IS NOT THE LAP: --skip-vectors is drawn on too, because the skip is applied
    # before the shuffle and vi keys the vertical draws. Quote both or the replay is a different lap.
    ap.add_argument('--iteration', type=int, default=1,
                    help='sweep iteration for the plan suite; picks every seeded choice')
    ap.add_argument('--fail-fast', action='store_true',
                    help='plan suite: stop at the end of the first waveform with an unexpected '
                         'failure, rather than sweeping the remaining 40. For a gating sweep; a soak '
                         'wants the whole lap so it can count rates')
    # NAMED AND LOGGED, never silent. A waveform dropped without a word turns into a suite that
    # reports full coverage of a set it did not test.
    # A PROGRESS FILE, because a plan lap is two and a half hours and soak.py captures the child's
    # output rather than streaming it -- so from outside, a healthy lap and a stalled one look
    # identical for the whole run. Written and flushed as each waveform starts and ends, which turns
    # monitoring from a guess about CPU time into reading a timestamp. CPU time is a bad proxy twice
    # over: the work is I/O bound on the instrument at about 0.6 s of CPU an hour, and the child's pid
    # changes at every lap boundary with its counter resetting to zero, so a monotonic check fires an
    # alarm exactly when a lap finishes.
    # AN EXPLICIT CELL SPEC, for a smoke run that has to finish in minutes rather than hours. Each
    # entry is vector:kinds, kinds being std, nonstd or all -- so two waveforms can take the standard
    # ladder while two others take only the drawn rates, at a quarter of the cells. The wait for a cell
    # is still keyed on its index in the FULL rate list, so a cell reached this way is the same cell
    # the soak would run and reproduces from the same iteration number.
    ap.add_argument('--plan-spec', default=None,
                    help='explicit cells, e.g. v77:std,r06:std,v78:nonstd,r00:nonstd')
    ap.add_argument('--heartbeat', default=None,
                    help='append per-waveform progress to this file, flushed, for a monitor to read')
    ap.add_argument('--skip-vectors', default='',
                    help='comma-separated vector ids to leave out of the plan, with the omission '
                         'printed in the header')
    ap.add_argument('--plan-vectors', type=int, default=None,
                    help='a seeded subset of this many vectors, for a lap that must finish in '
                         'minutes (the full 41 is about 2 h)')
    ap.add_argument('--payload-rates', default=None,
                    help='HIGH rates for %s in the payloads suite (default %s); all fourteen always '
                         'run at %d. Until 2026-08-20 they ran at %d only, so the fox and every '
                         'random payload were never driven high.'
                         % ('/'.join(PAYLOAD_HIRATE_VECS),
                            ','.join(str(x) for x in PAYLOAD_HIRATES),
                            PAYLOAD_BASE_RATE, PAYLOAD_BASE_RATE))
    ap.add_argument('--no-start', action='store_true',
                    help='use the app already running rather than loading and rebuilding')
    ap.add_argument('--no-output-off', action='store_true')
    ap.add_argument('--keep-combine', action='store_true',
                    help='leave CH2 summed into CH1 as an impairment rather than clearing the merge')
    ap.add_argument('--shots', help='directory for a front-panel PNG per test point')
    # THE WIRING IS A CONDITION, AND AN UNRECORDED CONDITION IS AN UNREPEATABLE RESULT. The S/N the
    # app reports is a property of the whole path -- generator, leads, loop area, whatever is coupling
    # into it -- so a run on 6 ft of unshielded lead draped over the mains cord and a run on matched
    # RG316 differ in a way no field of the result mentions. This puts it in the log's own header.
    ap.add_argument('--note', default='',
                    help='free text describing the physical setup, printed in the header')
    # THE ONE MODE THAT NEEDS NO BENCH. The arm suite's judging is what cannot be checked by running
    # it -- a cell that passes proves either that the app works or that the claim is unsatisfiable the
    # other way -- so the three defects are replayed through it here. Safe while a soak holds the bench.
    ap.add_argument('--selftest', action='store_true',
                    help="replay the arm suite's judging against the three defects it exists to "
                         'catch, and exit. Touches no instrument and opens no socket')
    a = ap.parse_args()

    # BEFORE ANYTHING ELSE, and before require_sdg probes the generator: this mode is for a busy bench.
    if a.selftest:
        return arm_selftest()

    if a.note:
        print('SETUP: %s' % a.note)
    if a.shots:
        SHOTS['dir'] = os.path.expanduser(a.shots)
        os.makedirs(SHOTS['dir'], exist_ok=True)
        print('panel grabs -> %s' % SHOTS['dir'])

    suites = [s for s in a.suites.split(',') if s]
    for s in suites:
        if s not in SUITES:
            print('unknown suite %r; have %s' % (s, ', '.join(sorted(SUITES))))
            return 2

    # FAIL FAST ON A WEDGED GENERATOR, before anything else touches it. The SDG2122X's LAN service
    # wedges while its network stack stays up -- it pings normally and REFUSES the SCPI port -- and
    # without this the run dies in whichever call happened to reach it first, with a traceback that
    # names neither the instrument nor the remedy.
    BS.require_sdg('bench_matrix')
    g, d, rows = SDG(), DMM(), []
    try:
        print(g.idn())
        if a.upload:
            # ONLY WHAT IS MISSING. Waveforms survive a power cycle, and every avoided upload is
            # avoided exposure to the wedge -- so the stored list decides, not the flag.
            have = (g.query('STL? USER') or '')
            need = [v for v, _, _ in FORMATS] + [RATE_ARB, LOREM_ARB] + [v for v, _ in HARD]
            # EXACT NAMES. A substring test would report a present vector as missing after the rename
            # -- or worse, a missing one as present -- and this branch UPLOADS what it thinks is
            # missing, which is the path that wedges the generator.
            need = VN.missing(have, need)
            print('missing from the generator: %s' % (', '.join(need) or 'nothing'))
            for vid in need:
                cw = BU.codewords(vid)
                print('uploading %s (%d points, %d bytes)' % (vid, len(cw), 2 * len(cw)))
                if 2 * len(cw) > I.SDG_UPLOAD_SAFE_BYTES:
                    print('  REFUSED: %d bytes is over the %d-byte safe ceiling'
                          % (2 * len(cw), I.SDG_UPLOAD_SAFE_BYTES))
                    continue
                g.upload_arb(VN.arb(vid), cw, amp_for(NOMINAL_SWING), _srate(vid, FORMAT_BAUD))
                time.sleep(0.3)
        if a.keep_combine:
            # CH2 is this run's impairment, summed into CH1 at the generator. Written here rather than
            # left to whatever the front panel last did, and echoed, so the log says which stimulus
            # every verdict below describes.
            g.combine_pair(sum_ch=1)
            g.output(True, ch=2)
            print('CH2 merged into CH1: %s' % g.query('C2:BSWV?'))
            print('  %s   %s   %s' % (g.query('C1:CMBN?'), g.query('C2:CMBN?'), g.query('C2:OUTP?')))
        else:
            # CMBN OFF is what actually removes CH2 from the sum. C2:OUTP OFF does NOT: the merge is
            # taken ahead of the output relay, measured 2026-08-21 -- CH1 kept the spike to the last
            # millivolt while CH2's own port went dead. So the order here is not interchangeable.
            g.impair_off(ch=2)
            g.combine(False, ch=1)

        print(d.q('print(localnode.model, localnode.version)'))
        # --no-start MEANS 'DO NOT REBUILD THE UI', NOT 'ASSUME THE APP IS LOADED'. It skipped the load as
        # well, so on a freshly power cycled instrument sdec does not exist, there is nothing to reuse, and
        # every cell raises -286 'attempt to index global sdec' -- on the panel. bench_smoke.py passes
        # --no-start unconditionally, which made the 13-minute gate unrunnable in exactly the state its own
        # instructions ask the operator to create.
        have = str(d.q('print(type(sdec))') or '').strip()
        if not a.no_start or have != 'table':
            if a.no_start:
                print('  sdec is %s, so there is nothing to reuse -- loading the app' % (have or 'absent'))
            RA.load_app(d)
            d.drain()
            d.send('local ok, why = sdec.start() '
                   'print(string.format("START ok=%s why=%s", tostring(ok), tostring(why)))')
            print('  ' + str(d.line(120)))
        out = d.load_script('mxmod', MATRIX_TSP, timeout=120)
        for ln in out:
            if ln and ln != '===DONE===':
                print('  mxmod: ' + ln)
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        # ONE PREFLIGHT, SHARED BY EVERY HARNESS -- see tools/bench_sync.py for what each step guards.
        # In short: align the socket with a sentinel, read the app state in ONE tagged reply, REFUSE if a
        # run is in flight, unwind a resting streaming mode through mode_exit() rather than by assigning
        # capmode, clear the previous result, disarm the queued-press absorb, and verify all of it.
        #
        # --no-start inherits whatever the last client left, and every suite here is a FRAME capture: an
        # app resting in a streaming mode runs the first point as a recording, which needs a locked baud
        # rate and files a perfectly good vector as 'no bytes decoded'.
        BS.preflight(d, 'bench_matrix')

        for s in suites:
            SUITES[s](d, g, a, rows)

        print('\n--- event log ---')
        for m in d.errors():
            print('  ' + str(m))
    finally:
        try:
            if not a.no_output_off:
                g.output(False, ch=1)
        except Exception as e:
            print('cleanup: %s' % e)
        g.close()
        d.close()

    print('\n%-28s %-4s %s' % ('POINT', '', 'RESULT'))
    print('-' * 96)
    for name, ok, det in rows:
        print('%-28s %-4s %s' % (name, 'ok' if ok else 'BAD', det))
    nok = sum(1 for _, ok, _ in rows if ok)
    print('\n%d of %d points fully correct' % (nok, len(rows)))
    print('events: %d x 4915, %d other, over %d points'
          % (EVENTS['e4915'], EVENTS['other'], EVENTS['points']))
    if SHOTS['dir']:
        print('%d panel grabs in %s (%d failed)'
              % (SHOTS['n'], SHOTS['dir'], SHOTS['fails']))
    return 0 if nok == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())

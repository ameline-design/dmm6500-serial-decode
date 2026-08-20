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
# DERIVED FROM THE MANIFEST, NOT WRITTEN DOWN. Every clean vector renders at 10 samples per bit
# and every impairment vector at 100, so a rate copied into this file is a rate that goes stale
# the next time the render regime changes -- and it goes stale QUIETLY: a hard-coded 100000 plays
# a 10-samples-per-bit vector at 10000 Bd while every label still says 9600, which is 4.2 % off
# and past the 2 % the suites themselves demand. Read it instead.
def _srate(vid, baud):
    return int(round(baud * int((manifest().get(vid) or {}).get('spb') or 10)))


def _spb(vid):
    return float(int((manifest().get(vid) or {}).get('spb') or 10))

RATE_ARB = 'v41'             # 'Hello, World!' 8N1, x10 like every clean vector
RATE_SPB = 10.0
RATES = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 250000]

# The family names sig_family() gives. 1.6 V sits exactly ON its 1V8 boundary (hi >= 1.6), and the
# measured high comes in at 1.59, so BOTH names are correct answers there -- the fallback '1.6Vpp'
# states the swing, which is the honest thing to say about a level that is not a named family.
LEVELS = [(5.0, ['5V TTL']), (3.3, ['3V3 CMOS']), (1.6, ['1V8 CMOS', '1.6Vpp'])]

# THE LOREM SWEEP. SER_Lorem1kB_8N1 (v71) is a 1024-byte non-repeating payload rendered at 100 kSa/s
# for 9600 baud, i.e. 10.41667 samples per bit -- so replaying it at SRATE = baud * 10.41667 gives any
# rate off ONE stored waveform. No upload, which is the point: large WVDT writes are the wedge hazard
# and the budget is about two per power cycle.
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
  print(string.format('M %s ok=%s t=%.3f baud=%s fmt=%s thr=%s ' ..
                      'fs=%s nf=%s ngood=%s nbad=%s fit=%s vmin=%s vmax=%s lo=%s hi=%s ' ..
                      'head=%s ec=%s',
                      tostring(tag), tostring(ok), t, tostring(sdec.baud), tostring(fmt),
                      tostring(sdec.thr),
                      tostring(sdec.acq_fs), tostring(r and r.nf), tostring(r and r.ngood),
                      tostring(r and r.nbad), tostring(sdec.fitq), tostring(sdec.vmin),
                      tostring(sdec.vmax), tostring(sdec.lo), tostring(sdec.hi),
                      tostring(r and r.headsusp), tostring(eventlog.getcount())))
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
    print('\n=== LEVELS -- v41 at three logic swings, LOGIC and THRESH checked ===')
    for swing, families in LEVELS:
        amp = amp_for(swing)
        g.select_arb(VN.arb('v41'), amp, _srate('v41', FORMAT_BAUD))
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, '%.1fV' % swing)
        ok, det = show('%.1f V swing (AMP %.2f)' % (swing, amp), res, hexs, notes,
                       'want %s' % '/'.join(families))
        famok = res.get('fam') in families
        if not famok:
            print('      LOGIC cell says %r, expected one of %s' % (res.get('fam'), families))
        # The threshold must land near mid-swing, which is the whole basis of the decode.
        th = num(res, 'thr')
        throk = th is not None and abs(th - swing / 2.0) <= 0.25 * swing
        rows.append(('level %.1fV' % swing, ok and famok and throk,
                     '%s thr %s %s' % (res.get('fam'), fmt_num(res.get('thr'), '%.2f'), det)))


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
            g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), srate)
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
                g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), srate)
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
    """The expected bytes for a vector. -> bytes, or None if neither source has them.

    PREFERS THE .txt AND FALLS BACK TO THE MANIFEST'S exp_hex. Fifteen of the 41 vectors have no
    .txt -- the short fixed-payload ones, v41 and the v44 family among them -- but every manifest row
    carries exp_hex, so an oracle exists for all 41 and no vector is skipped for want of a file.
    """
    p = os.path.join(BU.VECDIR, vid + '.txt')
    if os.path.exists(p):
        with open(p, 'rb') as f:
            return f.read()
    hx = (manifest().get(vid) or {}).get('exp_hex') or ''
    parts = hx.split()
    if not parts:
        return None
    return bytes(int(x, 16) for x in parts)


def suite_plan(d, g, a, rows):
    """Every vector, at every standard rate plus one drawn rate per gap, in a seeded order.

    THE MOST DEMANDING SUITE HERE, and the only one whose content changes from lap to lap. What it
    tests comes entirely from --iteration: see tools/soakplan.py for the draws. A failure prints the
    iteration, so the case can be rebuilt without running the laps before it.

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
    vecs = sorted(VN.MAP.keys())
    order = SP.vector_subset(it, vecs, a.plan_vectors)
    rates = SP.rates_for(it)
    std = set(SP.standard_rates())
    ladder = SP.rate_ladder()
    gapno = {}
    for baud, kind in rates:
        if kind != 'std':
            gapno[baud] = sum(1 for b in std if b < baud)
    est = SP.estimate_secs(rates, len(order)) / 60.0
    print('\n=== PLAN iteration %d -- %d vectors x %d rates (%d standard, %d drawn, %d ladder edge) '
          '= %d cells, est %.0f min ==='
          % (it, len(order), len(rates), sum(1 for _, k in rates if k == 'std'),
             sum(1 for _, k in rates if k == 'rand'), sum(1 for _, k in rates if k == 'edge'),
             len(order) * len(rates), est))
    print('    order: %s' % ' '.join(order))
    print('    FRAME mode only: above 165563 Bd sdec.fs_for_burst returns nil, so the streaming '
          'paths cannot record 172800 and up at all.')

    for vi, vid in enumerate(order):
        payload = plan_payload(vid)
        if payload is None:
            print('  %-6s SKIPPED -- no .txt and no exp_hex in the manifest' % vid)
            continue
        row = manifest().get(vid) or {}
        # SPB PER VECTOR, FROM THE MANIFEST. The clean vectors render at 10 samples per bit and the
        # impairment ones at 100, so srate = baud * spb differs by 100x between them. Assuming 10
        # would play every x100 vector at a tenth of the intended baud and blame the decoder.
        spb = int(row.get('spb') or 10)
        want_fmt = (row.get('exp_fmt') or '').strip()
        expect = SP.expect_for(vid)
        t_vec, ncell, nbadcell = time.time(), 0, 0
        for ri, (baud, kind) in enumerate(rates):
            srate = baud * spb
            if srate > I.SDG_MAX_SRATE:
                print('  %-6s %7d Bd SKIPPED -- %g Sa/s over the SDG ceiling (spb %d)'
                      % (vid, baud, srate, spb))
                continue
            if ri == 0:
                g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), srate)
                g.output(True, ch=1)
            else:
                g.truearb(srate)
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
            elif nf > head:
                ok, det = BU.judge_payload(hexs[2 * head:], payload)
                if head:
                    det = det + ' after a FLAGGED %d-byte head' % head
            gb = num(res, 'baud')
            close = gb is not None and abs(gb / float(baud) - 1.0) <= 0.02
            got_fmt = res.get('fmt', '?')
            fmtok = bool(want_fmt) and got_fmt[:3] == want_fmt[:3]
            exact = ok and close and fmtok
            # SILENTLY WRONG, computed rather than read out of the judge's prose: bytes came back, the
            # app raised nothing and flagged nothing, and they are not the payload. That is the one
            # outcome no vector is allowed, impairment vectors included -- a decode that fails loudly
            # costs an operator a retry, and one that lies costs them the measurement.
            nbad = int(num(res, 'nbad', 0))
            silent = (not exact) and nf > 0 and 'fail' not in res and nbad == 0
            if expect == 'loud':
                good = exact or not silent
            else:
                good = exact
            ncell += 1
            print('  %-6s %7d Bd %-5s %-5s %-5s %-6s %7s Bd  %-46s %5.2f sa/bit  wait %6.2f ms'
                  % (vid, baud, kind, expect, 'ok' if good else 'BAD', got_fmt,
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
            rows.append(('plan %s@%s' % (vid, label), good,
                         '%d Bd %s %s%s' % (baud, kind, det,
                                            ' [SILENTLY WRONG]' if silent else '')))
            if not good:
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
        print('  %-6s %s: %d cells in %.0f s (%.2f s/cell), %d not as expected  DMM %s  SDG %s'
              % (vid, expect, ncell, vsec, vsec / max(1, ncell), nbadcell,
                 'alive' if alive else 'NOT ANSWERING', 'alive' if sdg_ok else 'NO: %s' % sdg_why))
        if not alive or not sdg_ok:
            raise SystemExit(
                'STOPPING after %s: the bench stopped answering (DMM %s, SDG %s). Nothing after this '
                'point would mean anything, and the remaining waveforms would each wait for a timeout. '
                'The app may be mid-capture and the generator is still driving its output.'
                % (vid, 'alive' if alive else 'silent', 'alive' if sdg_ok else sdg_why))
        if nbadcell and a.fail_fast:
            raise SystemExit(
                'STOPPING after %s: %d of %d cells did not behave as a %r vector must, and --fail-fast '
                'is set. Iteration %d rebuilds this exactly; the REPRO lines above carry the rate and '
                'the measured head for each one.' % (vid, nbadcell, ncell, expect, it))


SUITES = {'formats': suite_formats, 'rates': suite_rates, 'lorem': suite_lorem,
          'levels': suite_levels, 'offsets': suite_offsets, 'hard': suite_hard,
          'payloads': suite_payloads, 'plan': suite_plan}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suites', default='formats,rates,lorem,levels,offsets')
    ap.add_argument('--upload', action='store_true',
                    help='upload the vectors these suites need. Large writes wedge it after '
                         'about two per power cycle, so this is a once-per-cycle flag.')
    ap.add_argument('--settle', type=float, default=0.35)
    ap.add_argument('--offset-swings', default='3.3,1.6')
    ap.add_argument('--rates', help='comma-separated subset of the rate ladder')
    # THE ONLY INPUT THE plan SUITE TAKES. Everything it tests -- vector order, the drawn rate
    # in each gap, the wait before every capture -- comes from this number through
    # tools/soakplan.py, so quoting it is enough to rebuild the lap.
    ap.add_argument('--iteration', type=int, default=1,
                    help='sweep iteration for the plan suite; picks every seeded choice')
    ap.add_argument('--fail-fast', action='store_true',
                    help='plan suite: stop at the end of the first waveform with an unexpected '
                         'failure, rather than sweeping the remaining 40. For a gating sweep; a soak '
                         'wants the whole lap so it can count rates')
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
    ap.add_argument('--shots', help='directory for a front-panel PNG per test point')
    a = ap.parse_args()

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
        g.impair_off(ch=2)
        g.combine(False, ch=1)

        print(d.q('print(localnode.model, localnode.version)'))
        if not a.no_start:
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

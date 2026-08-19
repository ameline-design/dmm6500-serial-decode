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
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG
import bench_uart as BU
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
FORMAT_SRATE = 100000        # from the manifest; these vectors are 10.42 samples/bit

RATE_ARB = 'v80'             # 'Hello, World!' 8N1 at 10 samples/bit
RATE_SPB = 10.0
RATES = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 250000]

# The family names sig_family() gives. 1.6 V sits exactly ON its 1V8 boundary (hi >= 1.6), and the
# measured high comes in at 1.59, so BOTH names are correct answers there -- the fallback '1.6Vpp'
# states the swing, which is the honest thing to say about a level that is not a named family.
LEVELS = [(5.0, ['5V TTL']), (3.3, ['3V3 CMOS']), (1.6, ['1V8 CMOS', '1.6Vpp'])]

# THE LOREM SWEEP. v71 is a 1024-byte non-repeating payload rendered at 100 kSa/s for 9600 baud,
# i.e. 10.41667 samples per bit -- so replaying it at SRATE = baud * 10.41667 gives any rate off one
# waveform, and no upload (it is already on the generator; a 210 kB upload is the wedge hazard).
#
# Better than the 13-byte 'Hello, World!' in two ways that matter: a 240-byte capture is a SUBSTRING
# of the payload rather than eighteen repeats of it, so a decode that resynchronised in the wrong
# place cannot accidentally match; and the byte values are real varied text, which is what the
# format search and the parity refinement actually have to cope with.
LOREM_ARB = 'v71'
LOREM_SPB = 100000.0 / 9600.0        # 10.41667 samples/bit, from the manifest

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
    # THE APP'S OWN VERDICT IS THE FIRST TEST, and it was collected in the M line and never looked at.
    # sdec.capture() returns FALSE without raising when it refuses -- no locked rate for a streaming
    # mode, a buffer it could not allocate, a mode that cannot run -- and on that path the panel keeps
    # the PREVIOUS capture's bytes. So every check below could pass on leftovers that happen to match the
    # stimulus, which is exactly how a refused point reads as a byte-exact one.
    if res.get('ok') != 'true':
        return False, 'the app refused the capture (ok=%s): %s' % (
            res.get('ok'), (res.get('err') or 'no reason given'))
    nf = int(num(res, 'nf', 0))
    if nf <= 0:
        return False, 'no bytes decoded'
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
        g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), FORMAT_SRATE)
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
        g.select_arb(VN.arb('v41'), amp, FORMAT_SRATE)
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
          % (LOREM_ARB, len(payload), LOREM_SPB, len(rates)))
    for baud in rates:
        srate = int(round(baud * LOREM_SPB))
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
        head = int(num(res, 'head', 0))
        ok, det = False, 'no bytes decoded'
        if 'fail' in res:
            det = 'FAIL %s' % res['fail']
        elif nf > head:
            # A FLAGGED framing error is not a wrong answer. lorem is rendered with gap = 0 -- bytes
            # back to back, which is what a device dumping a buffer does -- so a capture that began
            # mid-byte has no idle to resynchronise on and cannot report its own misaligned head
            # (r.idle1 stays nil, so headsusp does). What must hold is that the bytes the decoder
            # STANDS BEHIND are right, and that it did not decline too many.
            #
            # This used to be `longest_clean_run/body >= 0.95`, which failed a point on WHERE a flag
            # landed rather than how many there were -- one honest flag more than ten bytes from an
            # edge failed outright, and only 22 of 239 single-flag positions could pass. It also left
            # every run but the longest unchecked against the payload. BU.judge_payload validates
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
        # and nothing else, so the verdict can never be re-derived -- eleven soak laps were judged
        # BAD by the old gate and none of them could be re-tested afterwards, because the hex was
        # gone. Only on failure: 480 hex chars per passing point would bury the log.
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
            g.select_arb(VN.arb('v41'), amp, FORMAT_SRATE, offset_v=ofst)
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

    But comparing values alone is too strict, and the first version of this was. These vectors are
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
            head = int(num(res, 'head', 0))
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
    print('\n=== PAYLOADS -- %d distinct payloads, every byte value 0-255 covered ===' % len(vecs))
    for vid in vecs:
        try:
            with open(os.path.join(BU.VECDIR, vid + '.txt'), 'rb') as f:
                payload = f.read()
        except IOError:
            print('  %-6s SKIPPED -- no %s.txt; run tools/make_vectors.lua' % (vid, vid))
            continue
        srate = int(round(9600 * LOREM_SPB))
        g.select_arb(VN.arb(vid), amp_for(NOMINAL_SWING), srate)
        g.output(True, ch=1)
        time.sleep(a.settle)
        res, hexs, notes = press(d, 'pay_%s' % vid)
        nf = int(num(res, 'nf', 0))
        head = int(num(res, 'head', 0))
        ok, det = False, 'no bytes decoded'
        if 'fail' in res:
            det = 'FAIL %s' % res['fail']
        elif nf > head:
            ok, det = BU.judge_payload(hexs[2 * head:], payload)
            if head:
                det = det + ' after a FLAGGED %d-byte head' % head
        gb = num(res, 'baud')
        close = gb is not None and abs(gb / 9600.0 - 1.0) <= 0.02
        print('  %-6s %-5s %-6s %5s Bd  %-58s %d B payload'
              % (vid, 'ok' if (ok and close) else 'BAD', res.get('fmt', '?'),
                 fmt_num(res.get('baud'), '%.0f'), det, len(payload)))
        n4915 = note_events(res)
        if n4915:
            print('      *** %d x event 4915 ***' % n4915)
        for n in notes:
            print('      note: %s' % n)
        if not (ok and close):
            print('      hex head %d: %s' % (head, hexs[2 * head:][:512]))
        rows.append(('payload %s' % vid, ok and close, det))


SUITES = {'formats': suite_formats, 'rates': suite_rates, 'lorem': suite_lorem,
          'levels': suite_levels, 'offsets': suite_offsets, 'hard': suite_hard,
          'payloads': suite_payloads}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suites', default='formats,rates,lorem,levels,offsets')
    ap.add_argument('--upload', action='store_true',
                    help='upload the vectors these suites need. Once per generator power '
                         'cycle: repeated uploads are what wedge its LAN service.')
    ap.add_argument('--settle', type=float, default=0.35)
    ap.add_argument('--offset-swings', default='3.3,1.6')
    ap.add_argument('--rates', help='comma-separated subset of the rate ladder')
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
                g.upload_arb(VN.arb(vid), cw, amp_for(NOMINAL_SWING), FORMAT_SRATE)
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

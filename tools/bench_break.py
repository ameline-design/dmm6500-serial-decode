#!/usr/bin/env python3
"""TRY TO MAKE IT CONFIDENTLY WRONG. Degenerate signals and contradictory settings.

The other harnesses ask "does it decode this correctly?". This one asks the more important
question: **when it cannot, does it say so?** A refusal with a reason is a pass. Bytes on the
panel that are not on the wire is the only real failure -- and a raised error is a defect
regardless of the answer, because an ERROR-severity event puts a modal dialog over the app.

SO EVERY CASE DECLARES WHICH OUTCOMES ARE ACCEPTABLE, not what the answer should be:

    refuse      no bytes, and sdec.lasterr says why. Correct for a dead line.
    exact       the payload, byte for byte.
    flagged     wrong bytes are fine IF ERR is non-zero or a note warns. The decoder saw
                trouble and said so.
    any         only "did not raise and logged nothing" is being checked here.

NO WAVEFORM UPLOADS. Every stimulus is a generator built-in or an arb already on the box. Large
WVDT writes are the wedge hazard and the budget is about two per power cycle -- the count, not the
size -- and a wedge costs a human with a power switch. The degenerate cases need no files at all --

    all-0x00 8N1   is a 10 %-duty square at baud/10 -- SDG duty is the HIGH fraction, so that
                   is one high bit and nine low: the start bit plus eight zeros
    all-0xFF 8N1   is a 90 %-duty square: start bit low, eight ones, stop high
    all-0x55       is a plain 50 % square at baud/2 -- every bit alternating
    a break        is a very low duty cycle at a low frequency: line low far longer than a frame
    idle only      is DC, or the output switched off
    inverted       is the output polarity switch, so an RS-232 sense costs no new file

    python3 tools/bench_break.py --reuse
    python3 tools/bench_break.py --reuse --only no-signal,dc-mid,ff-payload
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG
import screenshot as SS
import vector_names as VN                                     # noqa: E402

INFO_EVENTS = ('2731', '2732', '2728', '4917')

BREAK_TSP = r'''
function bk_point(tag)
  eventlog.clear()
  sdec.stickyerr = nil
  timer.cleartime()
  -- THE TAG CHOOSES THE ACTION, so answering a refused forced rate is measured through exactly the
  -- same snapshot as a Capture press. sdec.rate_accept/rate_decline take no display event and no
  -- operator, which is the property under test: the offer must be answerable with nobody at the panel.
  local ok, err
  if string.sub(tostring(tag), 1, 7) == 'accept-' then
    ok, err = pcall(function() return sdec.rate_accept() end)
  elseif string.sub(tostring(tag), 1, 8) == 'decline-' then
    ok, err = pcall(function() return sdec.rate_decline() end)
  else
    ok, err = pcall(function() return sdec.capture() end)
  end
  local t = timer.gettime()
  local r = sdec.res
  local ec, emsg = eventlog.getcount(), ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
  end
  print(string.format('K %s|%s|%.3f|%s|%s|%s|%s|%s|%s|%s|%s',
        tostring(tag), tostring(ok), t,
        tostring(r and r.nf), tostring(r and r.nbad), tostring(sdec.baud),
        tostring(sdec.fmt_text and sdec.fmt_text()), tostring(sdec.ui_status),
        emsg, tostring(sdec.lasterr), tostring(sdec.rate_offer)))
  local nt, nn = sdec.ui_notes()
  for i = 1, nn do print('KN ' .. tostring(nt[i])) end
  if r ~= nil and r.nf ~= nil and r.nf > 0 then
    local i0 = 1
    while i0 <= r.nf and i0 <= 96 do
      local i1 = i0 + 47
      if i1 > r.nf then i1 = r.nf end
      local seg, k = {}, nil
      for k = i0, i1 do
        if r.errs[k] == nil then seg[table.getn(seg) + 1] = string.format('%02X', r.vals[k])
        else seg[table.getn(seg) + 1] = '??' end
      end
      print('KH ' .. table.concat(seg))
      i0 = i1 + 1
    end
  end
  print('K end')
end
print('===DONE===')
'''


def press(d, tag, timeout=300):
    d.drain()
    d.send('bk_point(%r)' % tag)
    res, notes, hexs = None, [], []
    while True:
        ln = d.line(timeout)
        if ln is None:
            return {'fail': 'timeout'}, [], ''
        if ln.startswith('K ') and '|' in ln:
            f = ln[2:].split('|')
            res = {'tag': f[0], 'ok': f[1] == 'true', 'secs': float(f[2]),
                   'nf': f[3], 'nbad': f[4], 'baud': f[5], 'fmt': f[6],
                   'status': f[7], 'events': f[8], 'lasterr': f[9],
                   # OPTIONAL, so a run against an older build parses instead of raising IndexError
                   # and reporting a harness fault for a field that app simply does not publish.
                   'offer': f[10] if len(f) > 10 else 'nil'}
        elif ln.startswith('KN '):
            notes.append(ln[3:])
        elif ln.startswith('KH '):
            hexs.append(ln[3:])
        elif ln == 'K end':
            break
    return res or {'fail': 'no result'}, notes, ''.join(hexs)


def real_events(emsg):
    n = 0
    for part in emsg.split(']'):
        part = part.strip('[').strip()
        if part and part.split()[0] not in INFO_EVENTS:
            n += 1
    return n


def num(v, dflt=None):
    if v is None or v == 'nil':
        return dflt
    try:
        return float(v)
    except ValueError:
        return dflt


def judge(res, notes, hexs, accept, want_bytes=None, want_baud=None):
    """-> (ok, verdict). `accept` is a set of the outcomes this case tolerates."""
    if 'fail' in res:
        return False, 'HARNESS %s' % res['fail']
    if not res['ok']:
        return False, 'RAISED'

    # 'adopted' IS CHECKED ON THE STATE, NOT ON THE BYTES, and that distinction is why this exists.
    # Demanding byte-exactness after Use Detected Rate failed on the first hardware run for a reason
    # that had nothing to do with the feature: the re-capture opened mid-byte, so three head bytes were
    # misaligned and 2 frames flagged -- an ordinary capture artefact every other case here tolerates.
    # What must be true is that the question was retired and the app really did move to the rate it
    # offered; the byte outcome is then judged by the same rules as any other capture.
    if 'adopted' in accept:
        if res['offer'] != 'nil':
            return False, 'still asking after Use Detected Rate (offer %s)' % res['offer']
        got = num(res['baud'], 0) or 0
        if want_baud is None or abs(got - want_baud) > want_baud * 0.01:
            return False, 'accepted but decoded at %s, not the offered %s' % (res['baud'], want_baud)
    nev = real_events(res['events'])
    if nev:
        return False, 'LOGGED %d: %s' % (nev, res['events'][:60])

    nf = int(num(res['nf'], 0) or 0)
    nbad = int(num(res['nbad'], 0) or 0)
    # WHAT COUNTS AS A WARNING. The app's ambiguity notes are the important ones here: 'also
    # fits: 7E1' and '19200 baud also fits this waveform' are it telling the operator the
    # evidence does not single out one answer, which is exactly the honesty being tested for.
    warned = nbad > 0 or res['lasterr'] != 'nil' or any(
        w in ' '.join(notes).lower() for w in
        ('warning', 'uncertain', 'suspect', 'mid-byte', 'unstable', 'lost', 'idle',
         'no transitions', 'ceiling', 'disagree', 'also fits', 'not the', 'false start',
         'may be wrong', 'assumed'))

    if nf == 0:
        # REFUSED, AND IT HANDED OVER THE ANSWER. Stronger than 'refuse': a bare refusal on a capture the
        # app could read is not much better than adopting silently, because the operator is left to guess
        # the rate. The condition is that the refusal NAMES the rate the wire carries and publishes it as
        # an answerable offer -- so a regression to a silent refusal fails here rather than passing as
        # "well, it refused".
        if 'offer' in accept:
            if res['offer'] == 'nil':
                return False, 'refused WITHOUT offering the detected rate: %s' % res['lasterr'][:44]
            said = ' | '.join(notes) + ' ' + res['lasterr']
            if res['offer'].split('.')[0] not in said:
                return False, 'offered %s but never said so on the panel' % res['offer']
            return True, 'refused, offered %s Bd, and said so' % res['offer'].split('.')[0]
        if 'refuse' in accept:
            if res['lasterr'] == 'nil' and not notes:
                return False, 'no bytes and NO REASON GIVEN'
            return True, 'refused: %s' % (res['lasterr'][:56] if res['lasterr'] != 'nil'
                                          else notes[0][:56])
        return False, 'no bytes decoded (%s)' % res['lasterr'][:40]

    # Bytes came out. If the case knows what they should be, check them.
    if want_bytes is not None:
        got = bytes.fromhex(hexs.replace('?', '0')) if hexs else b''
        exact = want_bytes and got and _cyclic(got, want_bytes)
        if exact:
            if 'exact' in accept:
                return True, 'exact %d B' % nf
            # A THIRD HONEST OUTCOME: the app NOTICES that a forced rate the wire contradicts explains
            # nothing, drops it and re-detects -- so a case demanding 'flag or refuse' gets correct
            # bytes instead. That is better than either and must not read as a failure. But it is only
            # better BECAUSE IT SAYS SO: exact bytes with the wrong rate silently still in force is
            # the confident-and-wrong outcome this file exists to catch, so the note is the condition,
            # not the byte match.
            if 'relocked' in accept:
                # EITHER OF THE TWO WAYS THE APP SAYS IT. sdec.decode() drops a contradicted lock and
                # says "N baud fit nothing -- unlocked"; autoset() re-captures at the measured rate and
                # says "probe fitted N Bd, wire is M". Both tell the operator their forced rate lost,
                # which is the condition. Silence is not.
                joined = ' | '.join(notes)
                if ('fit nothing' in joined or 'unlocked' in joined or 'wire is' in joined):
                    return True, 'exact %d B, forced rate overridden and said so' % nf
                return False, ('EXACT with nothing said about the forced rate: %d B' % nf)
            return False, 'EXACT, but this case must not decode: %d B' % nf
        if 'flagged' in accept and warned:
            return True, 'wrong bytes but FLAGGED (%d err, %s)' % (
                nbad, (res['lasterr'] if res['lasterr'] != 'nil' else notes[0] if notes
                       else 'note')[:44])
        # THE TWO WAYS OF BEING WRONG ARE DIFFERENT FAULTS AND MUST NOT SHARE A MESSAGE. If the app
        # warned, the app did its job and it is this case's `accept` set that is refusing the
        # outcome -- a harness question. Only silence is the app's fault, and only that is the
        # failure this file exists to catch. Reporting both as 'SILENTLY WRONG ... no warning' sent
        # a reader looking for a decoder bug that was not there.
        if warned:
            return False, 'wrong bytes, FLAGGED (%d err) -- case demands exact' % nbad
        return False, 'SILENTLY WRONG: %d B, %d err, no warning' % (nf, nbad)

    if 'any' in accept:
        return True, '%d B, %d err%s' % (nf, nbad, ', flagged' if warned else '')
    if 'flagged' in accept and warned:
        return True, '%d B, flagged (%d err)' % (nf, nbad)
    if 'refuse' in accept:
        return False, 'DECODED %d BYTES off a signal that carries none' % nf
    return False, '%d B, %d err, unclassified' % (nf, nbad)


def _cyclic(got, want):
    """Is `got` a contiguous run inside the repeating `want`?"""
    if not got or not want:
        return False
    hay = want * (len(got) // len(want) + 2)
    return got in hay


# ---------------------------------------------------------------------------
# The cases. Each sets up the generator, then names what it will accept.
# ---------------------------------------------------------------------------
def cases(g, d, a):
    AMP = 10.0            # 3.3 V swing on these vectors
    FF = b'\xff'
    ZERO = b'\x00'

    def arb(baud, spb=10.0, amp=AMP, ofst=0.0, invert=False):
        g.select_arb(VN.arb('v41'), amp, int(baud * spb), offset_v=ofst)
        g.write('C1:OUTP %s,LOAD,HZ,PLRT,%s' % ('ON', 'INVT' if invert else 'NOR'))
        time.sleep(a.settle)

    def sq(freq, duty, amp=AMP, ofst=None):
        # The vectors sit 0..3.3 V, so a square must too: offset = half the swing.
        swing = 3.3 * amp / 10.0
        g.square(freq, swing, swing / 2.0 if ofst is None else ofst, duty=duty, ch=1)
        g.write('C1:OUTP ON,LOAD,HZ,PLRT,NOR')
        time.sleep(a.settle)

    def dc(volts):
        g.write('C1:BSWV WVTP,DC,OFST,%g' % volts)
        g.write('C1:OUTP ON,LOAD,HZ,PLRT,NOR')
        time.sleep(a.settle)

    def off():
        g.output(False, ch=1)
        time.sleep(a.settle)

    def unlock():
        d.exec('sdec.force_baud, sdec.force_nbits = nil, nil '
               'sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil '
               "sdec.capmode = 'frame' sdec.stickyerr = nil")

    C = []

    # ---- nothing on the wire -----------------------------------------------------------
    C.append(('no-signal', 'output OFF -- an unconnected probe',
              lambda: (off(), unlock()), {'refuse'}, None))
    C.append(('dc-0v', 'DC at 0 V -- a line stuck low',
              lambda: (dc(0.0), unlock()), {'refuse'}, None))
    C.append(('dc-mid', 'DC at 1.65 V -- stuck exactly at the threshold',
              lambda: (dc(1.65), unlock()), {'refuse'}, None))
    C.append(('dc-high', 'DC at 3.3 V -- an idle line with no traffic at all',
              lambda: (dc(3.3), unlock()), {'refuse'}, None))
    C.append(('dc-10v', 'DC at 9.9 V -- at the top of the range',
              lambda: (dc(9.9), unlock()), {'refuse'}, None))

    # ---- a real signal, but degenerate content -----------------------------------------
    # SDG DUTY IS THE HIGH FRACTION, so the mapping is the opposite of the intuition: a 10 %
    # duty square is one high bit and nine low, i.e. start bit + eight zero data bits = 0x00.
    # 90 % duty is start bit + eight ones = 0xFF. Confirmed on the instrument, and worth stating
    # because getting it backwards makes a correct decode look like a defect.
    #
    # These are the payloads the rate detector has least to work with: a constant byte gives one
    # edge pair per frame, and 0xFF gives the narrowest pulse of all.
    C.append(('zero-payload-9600', 'all-0x00 at 9600 8N1 (10 % duty: 1 high bit, 9 low)',
              lambda: (sq(960.0, 10.0), unlock()), {'exact', 'flagged'}, ZERO))
    C.append(('ff-payload-9600', 'all-0xFF at 9600 8N1 (90 % duty: start bit + 8 ones)',
              lambda: (sq(960.0, 90.0), unlock()), {'exact', 'flagged'}, FF))
    C.append(('ff-payload-1200', 'all-0xFF at 1200 8N1',
              lambda: (sq(120.0, 90.0), unlock()), {'exact', 'flagged'}, FF))
    C.append(('alt-55-9600', 'all-0x55 at 9600 -- a 50 % square, every bit alternating',
              lambda: (sq(4800.0, 50.0), unlock()), {'exact', 'flagged'}, b'\x55'))
    # A CONTINUOUS BREAK IS GENUINELY AMBIGUOUS and the test says so rather than pretending
    # otherwise. 2 % duty is low for ~49 bit times and high for one: identical, sample for
    # sample, to an idle-LOW line carrying 0xFF. Levels are all the decoder has, and the line
    # rests low 98 % of the time, so inferring idle = LOW is the better reading of the evidence.
    # What is checked is that it does not RAISE and does not claim a rate it cannot support.
    C.append(('break-continuous', 'line low ~49 bit times per cycle -- indistinguishable from '
                                  'an idle-low line carrying 0xFF',
              lambda: (sq(192.0, 2.0), unlock()), {'exact', 'flagged', 'refuse', 'any'}, None))

    # ---- amplitude at and past the edges ----------------------------------------------
    C.append(('tiny-swing', '60 mV swing -- at the noise floor of the 10 V range',
              lambda: (arb(9600, amp=0.18), unlock()), {'refuse', 'flagged'}, b'Hello, World!'))
    C.append(('over-range', '19 Vpp -- past the +/-10 V range on both peaks',
              lambda: (arb(9600, amp=19.0, ofst=0.0), unlock()),
              {'refuse', 'flagged', 'exact'}, b'Hello, World!'))

    # ---- rates at and past the declared ceiling ---------------------------------------
    C.append(('over-ceiling-500k', '500 kBd -- twice the declared 250 kBd ceiling',
              lambda: (arb(500000), unlock()), {'refuse', 'flagged'}, b'Hello, World!'))
    C.append(('under-floor-110', '110 Bd -- below the 300 Bd floor',
              lambda: (arb(110), unlock()), {'refuse', 'flagged', 'exact'}, b'Hello, World!'))

    # ---- inverted line: RS-232 sense, no new waveform needed ---------------------------
    C.append(('inverted-9600', 'output polarity INVERTED -- an RS-232 sense line',
              lambda: (arb(9600, invert=True), unlock()),
              {'exact', 'flagged'}, b'Hello, World!'))

    # ---- contradictory forced settings: the dangerous class ----------------------------
    # A forced rate the device is not using is the one way this decoder can be confidently
    # wrong, so each of these must either decode correctly or FLAG.
    def force(**kw):
        stmt = ["sdec.capmode = 'frame'", 'sdec.stickyerr = nil']
        for k, v in kw.items():
            stmt.append('sdec.force_%s = %s' % (k, v))
        d.exec(' '.join(stmt))

    C.append(('force-2x-rate', '9600 wire, rate FORCED to 19200 (+100 %)',
              lambda: (arb(9600), force(baud='19200', nbits='nil', par='nil',
                                       nstop='nil', invert='nil')),
              {'flagged', 'offer'}, b'Hello, World!'))
    # 'relocked' IS NOT ACCEPTED, and that is the decision in #61 rather than a tightening for its
    # own sake. Adopting the detected rate and decoding with it put bytes on the panel at a rate nobody
    # chose, with one note line as the only trace. The app now REFUSES and hands over the rate it
    # measured, which the operator answers with Use Detected Rate or Cancel.
    #
    # 'flagged' STAYS, because the app does not always have proof. The relock needs an interior-bad
    # fraction over 0.25, and a 2-bit gap at half rate tiles so cleanly that the measured fraction is
    # 0.074 -- there the app warns and decodes, which is right: it has a suspicion, not evidence. So the
    # rule this pair encodes is "warn, or refuse and offer -- never adopt in silence". Confident garbage
    # still fails: every accepted outcome is an honest one, and a wrong ANSWER is not among them.
    C.append(('force-half-rate', '9600 wire, rate FORCED to 4800 (-50 %)',
              lambda: (arb(9600), force(baud='4800', nbits='nil', par='nil',
                                       nstop='nil', invert='nil')),
              {'flagged', 'offer'}, b'Hello, World!'))

    # ---- ANSWERING THE OFFER, WITH NOBODY AT THE PANEL ---------------------------------
    # The setup forces a wrong rate and takes the capture that raises the offer; the measured press is
    # the ANSWER, dispatched by the tag prefix in bk_point. No display event is involved in either --
    # which is the point, because a dialog that only a finger can answer would wedge every soak lap.
    def refuse_first(baud):
        arb(9600)
        force(baud=baud, nbits='nil', par='nil', nstop='nil', invert='nil')
        d.exec('sdec.capture()')

    # 19200, NOT 4800, AND THAT IS MEASURED ON THIS BENCH. Only a rate the app can PROVE wrong raises an
    # offer, and the two directions are not symmetric on the v41 waveform: forcing 2x relocks, while
    # forcing half stays under the 0.25 interior-bad gate and merely warns ('bytes may be WRONG if the
    # device runs at 9600 baud, 2x the 4800 you set'). With 4800 first, both cases below answer a
    # question that was never asked and fail for that reason rather than a real one.
    #
    # USE DETECTED RATE -> the lock is dropped, detection runs, and the bytes are exact -- the same
    # end state 'adopt' reaches on its own, except that a person chose it.
    C.append(('accept-detected-rate', 'wrong forced rate REFUSED, then Use Detected Rate',
              lambda: refuse_first('19200'), {'exact', 'flagged', 'adopted'}, b'Hello, World!',
              9600))
    # CANCEL -> the operator's rate stands and so does the refusal. 'refuse' rather than 'offer'
    # because answering retires the offer: the sentence must survive, the question must not.
    C.append(('decline-detected-rate', 'wrong forced rate REFUSED, then Cancel',
              lambda: refuse_first('19200'), {'refuse'}, None))
    C.append(('force-7bit-on-8', '8N1 wire, width FORCED to 7',
              lambda: (arb(9600), force(baud='nil', nbits='7', par='nil',
                                        nstop='nil', invert='nil')),
              {'flagged', 'refuse', 'any'}, None))
    C.append(('force-even-on-none', '8N1 wire, parity FORCED even',
              lambda: (arb(9600), force(baud='nil', nbits='nil', par='sdec.PAR_EVEN',
                                        nstop='nil', invert='nil')),
              {'flagged', 'refuse'}, b'Hello, World!'))
    C.append(('force-inverted', 'normal wire, polarity FORCED inverted',
              lambda: (arb(9600), force(baud='nil', nbits='nil', par='nil',
                                        nstop='nil', invert='true')),
              {'flagged', 'refuse'}, b'Hello, World!'))
    C.append(('force-6pct-fast', '9600 wire, rate FORCED to 10176 (+6 %) -- the documented '
                                 'silent-corruption edge',
              lambda: (arb(9600), force(baud='10176', nbits='nil', par='nil',
                                        nstop='nil', invert='nil')),
              {'flagged', 'refuse', 'relocked'}, b'Hello, World!'))

    # ---- THE CEILING CLIFF, and the alias that makes it dangerous ----------------------
    # Above 250 kBd the instrument cannot reach 4 samples/bit, so the decode must be refused.
    # The failure mode to hunt is not a refusal but a CONFIDENT SUBMULTIPLE: every edge interval
    # that is a multiple of T is also a multiple of 2T, so a 260 kBd line can be framed as a
    # perfectly clean 130 kBd one. That would be silently wrong at full confidence.
    for r in (249000, 250000, 251000, 255000, 260000, 300000):
        C.append(('ceiling-%d' % r,
                  '%d Bd -- must refuse or flag, and must NOT report a submultiple' % r,
                  (lambda rr: lambda: (arb(rr), unlock()))(r),
                  {'refuse', 'flagged', 'exact'}, b'Hello, World!'))

    # ---- one edge, and nothing else ----------------------------------------------------
    # A single transition carries no bit time, so there is nothing to frame. Anything other
    # than a refusal here is invention. 0.02 Hz means one edge every 25 s: the capture window
    # sees at most one.
    C.append(('one-edge', 'a single transition in the whole window -- no bit time exists',
              lambda: (sq(0.02, 50.0), unlock()), {'refuse', 'flagged'}, None))

    # ---- does a FAILED capture leave the previous one on screen as if it were current? ----
    # The dangerous version of a refusal: bytes from the last good capture still displayed,
    # with the header cells still describing them, after a capture that found nothing. Run
    # immediately after a good one, so there IS something stale to leak.
    # A SETUP STEP, not a decode test: its job is to leave something on the panel for the case
    # below to find. A flagged mid-byte head is the normal result on a continuously busy line, so
    # it is accepted here as it is everywhere else -- the assertion that matters is the next one.
    C.append(('good-then-dead', 'a good capture, so the next case has something stale to leak',
              lambda: (arb(9600), unlock()), {'exact', 'flagged'}, b'Hello, World!'))
    C.append(('contamination', 'the dead line straight after it -- must show nothing, not the '
                               'previous bytes',
              lambda: (off(), None), {'refuse'}, None))

    if a.only:
        keep = set(a.only.split(','))
        C = [c for c in C if c[0] in keep]
    return C


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reuse', action='store_true', help='drive the app already running')
    ap.add_argument('--settle', type=float, default=0.45)
    ap.add_argument('--only', help='comma-separated case names')
    ap.add_argument('--shots', help='directory for a panel grab per case')
    a = ap.parse_args()

    shots = None
    if a.shots:
        shots = os.path.expanduser(a.shots)
        os.makedirs(shots, exist_ok=True)

    g, d = SDG(), DMM()
    rows = []
    try:
        print(g.idn())
        print(d.q('print(localnode.model, localnode.version)'))
        if a.reuse:
            live = d.q('print(tostring(sdec ~= nil and sdec.built))')
            print('reusing the running app (built = %s)' % live)
            if live != 'true':
                print('REFUSED: no built app. Load one first.')
                return 2
        else:
            import run_app as RA
            RA.load_app(d)
            d.drain()
            d.send('local ok, why = sdec.start() print("START " .. tostring(ok) .. " " '
                   '.. tostring(why))')
            print('  ' + str(d.line(120)))
        for ln in d.load_script('bkmod', BREAK_TSP, timeout=120):
            if ln and ln != '===DONE===':
                print('  bkmod: ' + ln)
        d.exec('localnode.showevents = eventlog.SEV_ERROR')

        C = cases(g, d, a)
        print('\n%d degenerate cases. A REFUSAL WITH A REASON IS A PASS; confident garbage is '
              'not.\n' % len(C))
        print('%-20s %-5s %7s %-46s %s' % ('CASE', '', 'secs', 'VERDICT', 'accepts'))
        print('-' * 108)
        # A CASE MAY CARRY A SIXTH FIELD, the rate it expects the app to have moved to. Optional rather
        # than added to all thirty, so one case that needs it does not churn twenty-nine that do not.
        for case in C:
            name, desc, setup, accept, want = case[:5]
            want_baud = case[5] if len(case) > 5 else None
            setup()
            res, notes, hexs = press(d, name)
            ok, verdict = judge(res, notes, hexs, accept, want, want_baud)
            print('%-20s %-5s %7s %-46s %s'
                  % (name, 'ok' if ok else 'BAD',
                     '%.2f' % res.get('secs', 0) if 'fail' not in res else '-',
                     verdict[:46], '/'.join(sorted(accept))))
            print('      %s' % desc)
            for n in notes[:2]:
                print('      note: %s' % n[:96])
            if shots:
                try:
                    SS.capture(os.path.join(shots, '%s.png' % name))
                except Exception as e:
                    print('      grab failed: %s' % e)
            rows.append((name, ok, verdict, desc))

        print('\n--- summary ---')
        bad = [r for r in rows if not r[1]]
        print('%d of %d cases behaved acceptably' % (len(rows) - len(bad), len(rows)))
        if bad:
            print('\nFAILURES -- these are either silently wrong, raised, or logged an event:')
            for n, _, v, desc in bad:
                print('  %-20s %s' % (n, v))
                print('      (%s)' % desc)
        # THE COUNT IS PRINTED, NOT IMPLIED BY SILENCE. Iterating and printing nothing leaves an empty
        # log looking exactly like a check that never ran -- and "must be empty" above then reads as a
        # claim nobody verified. bench_panel.py states its count for the same reason.
        print('\n--- residual event log (must be empty) ---')
        resid = list(d.errors())
        print('  count: %d' % len(resid))
        for m in resid:
            print('  ' + str(m))
    finally:
        try:
            g.write('C1:OUTP OFF,LOAD,HZ,PLRT,NOR')
            g.close()
        except Exception:
            pass
        d.close()
    return 1 if [r for r in rows if not r[1]] else 0


if __name__ == '__main__':
    sys.exit(main())

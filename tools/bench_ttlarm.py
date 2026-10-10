#!/usr/bin/env python3
"""ARMING FROM SILENCE AT TTL LEVELS, blind rate against a locked one.

WHY THIS EXISTS, AND WHY bench_arm.py DOES NOT COVER IT. Every armed case in bench_arm drives the
v41 arb at AMP 10 Vpp and OFST 0, so the line swings -5 V to +5 V and idles NEGATIVE -- RS-232
polarity, straddling ground. An operator reported the same workflow failing on a 0 V to +5 V TTL
line: output off, press Capture, switch the device on three seconds later, and the decode comes back
wrong at an automatic rate while a locked rate decodes it correctly. Those are two different level
classes and the app chooses its threshold and its polarity from the samples, so a pass at one says
nothing about the other.

THE CONFOUND THIS IS BUILT AROUND. The stimulus is a LOOPING arb, so the output switch opens at an
arbitrary phase of the waveform and one capture per condition is a coin flip -- that confound has
already faked a field leak in this repository once. Every condition here is run --n times and
reported as a distribution, never as a single capture. The reported discriminator is the share of
captures whose text holds the vector's own string, because 'wrong data' is the operator's complaint
and byte count alone cannot see it.

WHAT IS VARIED, one axis at a time:

    levels    pm5 u5 pm33 u33 pm18 u18 pm1 u1   four swings x bipolar/unipolar, see LEVELS
    rate      blind   force_baud = nil         arms at sdec.arm_fs(), one window of about 105 ms
              locked  force_baud = baud        arms at pick_fs(baud), a longer window in bit times
    armlevel  volts above or below the measured idle that the comparator is set to

Output off is GROUND in every class, which is why the two polarities are not symmetric: on a
unipolar line ground IS the low level, so the quiet line before the device starts is
indistinguishable from a held zero bit and the first thing the comparator sees is the line rising
into idle. On a bipolar line ground sits between the two, so the arm fires on a data edge instead.
"""

import argparse
import json
import os
import statistics
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
import vector_names as VN
from siglent import SDG

BAUD = 9600
SPB = 10
ARMWAIT = 10.0
START_AT = 3.0

# EIGHT LEVEL CLASSES, FOUR SWINGS x TWO POLARITIES. The pairs are matched in swing so polarity is
# the only difference within a pair, which is what makes 'ground is the space level' testable: a
# bipolar line puts ground BETWEEN mark and space, a unipolar one puts it ON the space level, and the
# output switch parks the line at ground either way.
#
# THE ARM LEVEL IS NOT SCALED WITH THE SWING, deliberately. sdec.armlevel is an operator setting in
# volts and the point of arming from silence is that the app has not seen the signal yet, so it
# CANNOT know the swing when it chooses the comparator level. The default 1.0 V therefore sits above
# the whole of the 0..1 V class and at the very top of the +/-1 V one -- if those fail to arm, that
# is the honest behaviour of the feature and the question becomes whether it says so. Sweep
# --armlevel to separate 'cannot arm at this setting' from 'armed and decoded wrong'.
LEVELS = {
    # name: (amp_vpp, offset_v, low_v, high_v, mid_v)
    'pm5': (10.0, 0.0, -5.0, 5.0, 0.0),
    'u5': (5.0, 2.5, 0.0, 5.0, 2.5),
    'pm33': (6.6, 0.0, -3.3, 3.3, 0.0),
    'u33': (3.3, 1.65, 0.0, 3.3, 1.65),
    'pm18': (3.6, 0.0, -1.8, 1.8, 0.0),
    'u18': (1.8, 0.9, 0.0, 1.8, 0.9),
    'pm1': (2.0, 0.0, -1.0, 1.0, 0.0),
    'u1': (1.0, 0.5, 0.0, 1.0, 0.5),
}
ORDER = ['pm5', 'u5', 'pm33', 'u33', 'pm18', 'u18', 'pm1', 'u1']


def tq(d, tag, expr, timeout=60):
    """One tagged read. Tagged because bare sequential reads desync by one and every value still
    looks plausible."""
    s = str(d.q('print("%s|" .. tostring((function() local ok, r = pcall(function() return %s end) '
                'if not ok then return "RAISED:" .. tostring(r) end return r end)()))' % (tag, expr),
                timeout=timeout) or '')
    k = '%s|' % tag
    if k not in s:
        raise RuntimeError('DESYNC asking %s: got %r' % (tag, s))
    return s.split(k, 1)[1].strip()


def num(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def start_later(g, delay_s, hit):
    """Switch the output on delay_s from now, in a thread, so the session is never blocked."""
    def body():
        time.sleep(delay_s)
        try:
            g.output(True, ch=1)
            hit['on'] = time.time()
        except Exception as e:                        # noqa: BLE001 -- reported, not raised
            hit['err'] = str(e)
    th = threading.Thread(target=body, daemon=True)
    th.start()
    return th


def set_levels(g, lv, baud):
    """Park the generator on one level class, output off. HOISTED OUT OF THE CAPTURE LOOP: select_arb
    reads the name back with a long timeout and re-asserts TrueArb, which is seconds of work that
    says nothing new when the class has not changed."""
    amp, ofst = LEVELS[lv][0], LEVELS[lv][1]
    g.output(False, ch=1)
    g.select_arb(VN.arb('v41'), amp, baud * SPB, offset_v=ofst)
    g.output(False, ch=1)
    st = g.state(ch=1)
    print('   arb : %s  AMP %g OFST %g -> %g..%g V   %s'
          % (lv, amp, ofst, LEVELS[lv][2], LEVELS[lv][3],
             str(st.get('bswv', ''))[:70] if isinstance(st, dict) else ''))


def one(d, g, lv, locked, baud, tag, armlevel=1.0):
    """One capture of the operator's workflow. Returns a dict, never raises on a bad decode."""
    amp, ofst, low, high, mid = LEVELS[lv]
    g.output(False, ch=1)
    # A CHUNKED JOB LEFT OPEN MAKES THE NEXT PRESS CONTINUE IT rather than start a capture.
    d.exec('sdec.ck_job, sdec.ck_running, sdec.strm_recording = nil, false, nil')
    d.exec('sdec.strm_stopped_by_press = nil sdec.strm_nabsorbed = 0 sdec.strm_absorbed = nil')
    d.exec('sdec.capmode = "frame" sdec.trigmode = "edge" sdec.armlevel = 1.0 '
           'sdec.armwait = %g sdec.lasterr = nil sdec.probe_note = nil' % ARMWAIT)
    d.exec('sdec.armlevel = %g' % armlevel)
    # THE EVENT LOG IS DRAINED BEFORE EACH CAPTURE so the count read after it belongs to this
    # capture alone. showevents is 0 throughout, which is what makes the count trustworthy: at 1 the
    # firmware echoes error events to the socket and the log reads zero no matter what happened.
    d.exec('eventlog.clear()')
    if locked:
        d.exec('sdec.force_baud = %d sdec.autolock_set = nil' % baud)
    else:
        d.exec('sdec.force_baud = nil sdec.autolock_set = nil')

    hit = {}
    t0 = time.time()
    th = start_later(g, START_AT, hit)
    res = tq(d, tag, '(function() local ok, why = pcall(sdec.capture) '
                     'return tostring(ok) .. " / " .. tostring(why) end)()', timeout=240)
    el = time.time() - t0
    th.join(timeout=1)
    # hw_config re-arms showevents, and an unsolicited event line desyncs every later read.
    d.exec('localnode.showevents = 0')

    r = {'levels': lv, 'locked': locked, 'elapsed': el, 'res': res,
         'on_at': hit.get('on', t0) - t0}
    r['baud'] = num(tq(d, tag + 'b', 'sdec.baud'))
    r['baud_raw'] = num(tq(d, tag + 'r', 'sdec.baud_raw'))
    r['fs'] = num(tq(d, tag + 'f', 'sdec.fs'))
    r['nread'] = num(tq(d, tag + 'n', 'sdec.nread'), 0)
    r['thr'] = num(tq(d, tag + 'h', 'sdec.thr'))
    r['nf'] = num(tq(d, tag + 'c', 'sdec.res ~= nil and sdec.res.nf or -1'), -1)
    r['nbad'] = num(tq(d, tag + 'x', 'sdec.res ~= nil and sdec.res.nbad or -1'), -1)
    r['text'] = tq(d, tag + 't', 'sdec.res ~= nil and sdec.ua_text_line(1, 40) or "-"')
    r['err'] = tq(d, tag + 'e', 'sdec.lasterr')
    r['note'] = tq(d, tag + 'p', 'sdec.probe_note')
    # THE WINDOW'S OWN EXTREMES, so a claim about levels is made against the samples and not against
    # what the generator was asked for.
    r['vmin'] = num(tq(d, tag + 'm', '(function() local v = sdec.smp[1] for i = 1, sdec.nread do '
                                     'if sdec.smp[i] < v then v = sdec.smp[i] end end return v end)()'))
    r['vmax'] = num(tq(d, tag + 'M', '(function() local v = sdec.smp[1] for i = 1, sdec.nread do '
                                     'if sdec.smp[i] > v then v = sdec.smp[i] end end return v end)()'))
    # LEADING SAMPLES BEFORE THE DEVICE EXISTED. Measured as samples below the level midpoint, which
    # at TTL levels is also what a held zero bit looks like -- that ambiguity is the subject here, so
    # the number is reported rather than asserted on.
    r['lead'] = num(tq(d, tag + 'l',
                       '(function() local n = sdec.nread local i = 1 '
                       'while i <= n and sdec.smp[i] < %g do i = i + 1 end return i - 1 end)()'
                       % mid), 0)
    r['nev'] = num(tq(d, tag + 'v', 'eventlog.getcount(eventlog.SEV_ALL)'), 0)
    r['armthr'] = num(tq(d, tag + 'a', 'sdec.arm_thr'))
    r['good'] = 'Hello' in (r['text'] or '')
    return r


def summarise(rows, title):
    if not rows:
        return
    n = len(rows)
    good = sum(1 for r in rows if r['good'])
    clean = sum(1 for r in rows if r['nbad'] == 0)
    nf = [r['nf'] for r in rows if r['nf'] is not None]
    bauds = {}
    for r in rows:
        k = 'nil' if r['baud'] is None else '%g' % r['baud']
        bauds[k] = bauds.get(k, 0) + 1
    print('\n-- %s --' % title)
    print('   captures            %d' % n)
    print('   text holds "Hello"  %d/%d' % (good, n))
    print('   nbad == 0           %d/%d' % (clean, n))
    print('   bytes               min %g  median %g  max %g'
          % (min(nf), statistics.median(nf), max(nf)))
    print('   baud published      %s' % ', '.join('%s x%d' % (k, v) for k, v in sorted(bauds.items())))
    print('   fs                  %s'
          % (', '.join(sorted({'%g' % r['fs'] for r in rows if r['fs']})) or '-'))
    print('   window              %g samples, lead %g..%g below midpoint'
          % (statistics.median([r['nread'] for r in rows]),
             min(r['lead'] for r in rows), max(r['lead'] for r in rows)))
    vmins = [r['vmin'] for r in rows if r['vmin'] is not None]
    vmaxs = [r['vmax'] for r in rows if r['vmax'] is not None]
    print('   swing seen          %s .. %s V, thr %s'
          % ('%.3f' % min(vmins) if vmins else '-', '%.3f' % max(vmaxs) if vmaxs else '-',
             ', '.join(sorted({'%.3f' % r['thr'] for r in rows if r['thr'] is not None})) or '-'))
    print('   events filed        %s' % ', '.join(sorted({'%g' % r['nev'] for r in rows})))
    print('   arm_thr             %s'
          % (', '.join(sorted({'%.3f' % r['armthr'] for r in rows if r['armthr'] is not None}))
             or 'nil throughout'))
    for r in rows:
        print('   %-6s %-6s  %6.2f s  on+%.2f  baud=%-7s bytes=%-5g bad=%-4g %s  %r'
              % (r['levels'], 'locked' if r['locked'] else 'blind', r['elapsed'], r['on_at'],
                 'nil' if r['baud'] is None else '%g' % r['baud'], r['nf'], r['nbad'],
                 'OK ' if r['good'] else 'BAD', (r['text'] or '')[:34]))
        if not r['good']:
            print('          lasterr: %s' % r['err'])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=8, help='captures per condition')
    ap.add_argument('--baud', type=int, default=BAUD)
    ap.add_argument('--levels', default=','.join(ORDER),
                    help='comma-separated: ' + ' '.join(ORDER))
    ap.add_argument('--rates', default='blind,locked', help='comma-separated: blind, locked')
    ap.add_argument('--armlevel', type=float, default=1.0, help='sdec.armlevel, volts')
    ap.add_argument('--out', default='', help='append one line of JSON per capture to this file')
    a = ap.parse_args()
    lvs = [x.strip() for x in a.levels.split(',') if x.strip()]
    rates = [x.strip() for x in a.rates.split(',') if x.strip()]
    for lv in lvs:
        if lv not in LEVELS:
            print('unknown level class %r -- want one of %s' % (lv, ', '.join(LEVELS)))
            return 2

    g = SDG()
    print('SDG : %s' % g.idn())
    d = DMM()
    built = tq(d, 'B0', 'tostring(sdec ~= nil and sdec.built == true)')
    if built != 'true':
        print('REFUSING: the app is not loaded and built. Run tools/run_app.py first.')
        return 2
    d.exec('localnode.showevents = 0')
    print('app : built=true  fw %s  arm_fs=%s  arm_baud=%s'
          % (tq(d, 'B1', 'localnode.version'), tq(d, 'B2', 'sdec.arm_fs()'),
             tq(d, 'B3', 'sdec.arm_baud')))
    # THE OPERATOR'S OWN SETTINGS, READ RATHER THAN ASSUMED, and written back in the finally below.
    entry = {k: tq(d, 'E' + k, 'sdec.' + k)
             for k in ('armlevel', 'armwait', 'capmode', 'trigmode')}
    print('cfg : armlevel=%g armwait=%g baud=%d  device on at +%.1f s  n=%d'
          % (a.armlevel, ARMWAIT, a.baud, START_AT, a.n))
    print('ent : %s   (restored on the way out)'
          % '  '.join('%s=%s' % (k, v) for k, v in sorted(entry.items())))

    rows = []
    try:
        for lv in lvs:
            for rate in rates:
                locked = rate == 'locked'
                print('\n=== %s levels, %s rate: output off, press, device on at +%.0f s (x%d) ==='
                      % (lv, rate, START_AT, a.n))
                set_levels(g, lv, a.baud)
                got = []
                for i in range(a.n):
                    r = one(d, g, lv, locked, a.baud, 'T%s%s%d' % (lv, rate[0], i),
                            armlevel=a.armlevel)
                    if a.out:
                        with open(a.out, 'a') as fh:
                            fh.write(json.dumps(r) + '\n')
                    got.append(r)
                    print('   %2d/%-2d  %6.2f s  baud=%-7s bytes=%-5g bad=%-4g %s'
                          % (i + 1, a.n, r['elapsed'],
                             'nil' if r['baud'] is None else '%g' % r['baud'],
                             r['nf'], r['nbad'], 'OK' if r['good'] else 'BAD'))
                rows.extend(got)
                summarise(got, '%s levels, %s rate' % (lv, rate))
    finally:
        print('\n=== restore ===')
        try:
            g.output(False, ch=1)
            g.select_arb(VN.arb('v41'), LEVELS['pm5'][0], a.baud * SPB,
                         offset_v=LEVELS['pm5'][1])
            g.output(False, ch=1)
        except Exception as e:                        # noqa: BLE001
            print('  SDG restore failed: %s' % e)
        d.exec('sdec.force_baud = nil sdec.autolock_set = nil')
        for k, v in sorted(entry.items()):
            d.exec('sdec.%s = %s' % (k, v if num(v) is not None else '%r' % v))
        d.exec('localnode.showevents = eventlog.SEV_ERROR')
        print('  %s  events=%s'
              % ('  '.join('%s=%s' % (k, tq(d, 'R' + k, 'sdec.' + k))
                           for k in sorted(entry)),
                 tq(d, 'Rev', 'eventlog.getcount(eventlog.SEV_ALL)')))

    print('\n==== the comparison ====')
    for lv in lvs:
        for rate in rates:
            sel = [r for r in rows if r['levels'] == lv and r['locked'] == (rate == 'locked')]
            if sel:
                print('  %-6s %-6s   text OK %d/%d   nbad==0 %d/%d   median bytes %g'
                      % (lv, rate, sum(1 for r in sel if r['good']), len(sel),
                         sum(1 for r in sel if r['nbad'] == 0), len(sel),
                         statistics.median([r['nf'] for r in sel])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

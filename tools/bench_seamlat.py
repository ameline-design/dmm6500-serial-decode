#!/usr/bin/env python3
"""Measure the elision seam's resume latency L, and whether the fast path moves it.

WHY L IS THE NUMBER TO BRING BACK. An elided record resumes recording L after the comparator
crossing that released the wait block, so the first L of the burst's first start bit is missing
from the record. The framer has no edge at the true start, anchors on the splice instead, and
every sample runs late by L. Under half a bit that is still inside the cell and the seam costs
nothing; over it the stop sample lands in the next start bit and the resync walks three to eight
bytes. So L divided by the bit time decides the whole behaviour, and from the 2026-10-17 record
it is only BOUNDED, at 156 to 208 us, by what the seam debris strings can be.

WHAT MAKES IT MEASURABLE AT ALL. Block 1 digitizes the gap into the scratch with COUNT_INFINITE
and fillmode = 1, and it keeps storing until block 3 takes over -- so the samples the record is
missing are not lost by the instrument, they are the TAIL OF THE SCRATCH. At 9600 Bd and
100 kS/s, L is 16 to 21 readings inside a 2000-reading ring. Only the last gap survives, the ring
being reused every pass, which is enough to calibrate L and not enough to repair every seam.

  python3 tools/bench_seamlat.py                  # both arms, 9600 Bd
  python3 tools/bench_seamlat.py --baud 19200
  python3 tools/bench_seamlat.py --no-load        # the app and engine are already up

Reads nothing destructive: one elided capture per arm, no upload, no plan written.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM              # noqa: E402
from siglent import SDG             # noqa: E402
import run_bench as RB              # noqa: E402
import vector_names as VN           # noqa: E402

VEC = 'v98a'
SPB = 10                 # v98a renders at 10 arb samples a bit; see tools/make_vectors.lua
AMP_VPP = 3.0
OFST_V = 1.5
TAIL = 60                # scratch readings to dump: L is 16-21 at 100 kS/s, so this is 3x headroom
# The swing below which the line is not carrying anything. Measured either side: 0.019 V with the
# generator output off, 0.992 V with it on.
SWING_MIN_V = 0.20


# ONE SCRIPT PER ARM, and every value printed on a tagged line. A bare print stream desynchronises
# the moment one statement raises, and a raising statement prints NOTHING while the host blocks for
# its whole timeout -- so each line names itself and the reader keys on the name.
TRIAL = r"""
sdec.gap_fastpath = %(fast)s
sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
sdec.force_invert = false
local fs = sdec.fs_for_burst(%(baud)d)
print('SL fs=' .. tostring(fs))
local p = brun.point(fs, %(baud)d, true, %(win)g, '%(vec)s')
print('SL ran=' .. tostring(p.ran) .. ' nf=' .. tostring(p.nf) .. ' nbad=' .. tostring(p.nbad))
print('SL elided=' .. tostring(p.elided) .. ' win=' .. tostring(p.elidewin))
print('SL blend=' .. tostring(sdec.gap_fastblend) .. ' segfs=' .. tostring(p.elidefs)
      .. ' spanfs=' .. tostring(p.elidespanfs))
-- The state AFTER the cell, because brun.point restores trigmode and gapelide on its way out and the
-- blend guard reads both: a flag cleared by the restore would read as a blend that never happened.
print('SL after fp=' .. tostring(sdec.gap_fastpath) .. ' tm=' .. tostring(sdec.trigmode)
      .. ' ge=' .. tostring(sdec.gapelide) .. ' tb=' .. tostring(sdec.trigblended))

-- The low-latency warning, read from the store rather than inferred from the block list: the
-- firmware appends it to getblocklist() whenever the program is off the fast path, which is the
-- only observable the boundary has. docs/TRIGGER.md, 'The low-latency flag'.
local bl = nil
if pcall(function() bl = trigger.model.getblocklist() end) and bl ~= nil then
  print('SL warn=' .. tostring(string.find(bl, 'low latency', 1, true) ~= nil))
else
  print('SL warn=unreadable')
end

-- The scratch's tail. Unwound by ring position, newest LAST, because block 1 wrote continuously and
-- the ring has almost certainly lapped: the oldest reading is at startindex, so the newest is the
-- one before it. docs/MEASUREMENTS.md, 'A record can come back rotated'.
local g = sdec.gapbuf
if g == nil then
  print('SL gerr=no scratch')
else
  local gn, gcap, gstart = nil, nil, nil
  pcall(function() gn = g.n end)
  pcall(function() gcap = g.capacity end)
  pcall(function() gstart = g.startindex end)
  print('SL gn=' .. tostring(gn) .. ' gcap=' .. tostring(gcap) .. ' gstart=' .. tostring(gstart))
  if gn ~= nil and gn > 0 then
    local first = 1
    if gcap ~= nil and gn >= gcap and gstart ~= nil and gstart >= 1 then first = gstart end
    local n = %(tail)d
    if n > gn then n = gn end
    -- The last n readings in TIME order: positions first+gn-n .. first+gn-1, wrapped.
    local out, i = '', nil
    for i = gn - n + 1, gn do
      local pos = first + i - 1
      if gn > 0 and pos > gn then pos = pos - gn end
      local v = nil
      pcall(function() v = g.readings[pos] end)
      out = out .. string.format('%%.5f ', v or 0/0)
    end
    print('SL gtail=' .. out)
  end
end

-- And the levels this capture decided on, so a reading can be called mark or space without guessing.
print('SL lv vmin=' .. tostring(sdec.vmin) .. ' vmax=' .. tostring(sdec.vmax)
      .. ' thr=' .. tostring(sdec.thr) .. ' idle=' .. tostring(sdec.idle))
sdec.gap_fastpath = false
print('===DONE===')
"""


def tagged(lines, key):
    """The value of one 'SL key=...' line, or None. Tagged because a bare stream desynchronises."""
    for ln in lines:
        s = str(ln).strip()
        if s.startswith('SL ') and (key + '=') in s:
            tail = s.split(key + '=', 1)[1]
            return tail.split(' ')[0] if key != 'gtail' else tail
    return None


def run_arm(d, baud, win, fast):
    body = TRIAL % {'fast': 'true' if fast else 'false', 'baud': baud, 'win': win,
                    'vec': VEC, 'tail': TAIL}
    out = d.load_script('seamlat', body, timeout=180)
    return [str(x) for x in out]


def analyse(lines, baud, fs):
    """-> (L seconds, how many trailing readings were space, note)

    THE PREMISE IS CHECKED FIRST, because every failure mode of this measurement looks like a
    number. A dead line gives readings scattered within a few mV of ground, the midpoint then
    falls inside the noise, and classifying "space" against it is a coin toss per reading --
    which is how the first run of this probe reported a free seam from a generator whose output
    was never enabled.
    """
    ran = tagged(lines, 'ran')
    if ran != 'true':
        return None, None, 'the capture did not run (ran=%s) -- nothing to measure' % ran
    try:
        vmin = float(tagged(lines, 'vmin'))
        vmax = float(tagged(lines, 'vmax'))
    except (TypeError, ValueError):
        return None, None, 'no levels came back'
    # LIVE AGAINST DEAD, not swing against commanded Vpp. A stored arb does not use the full
    # normalised range, so 3.0 Vpp commanded reaches the line as about 1 V of logic swing and a
    # fraction-of-commanded test rejects a perfectly good capture. Measured: a dead line gives 0.019 V
    # of swing and a live one 0.992, so the threshold only has to separate those.
    if (vmax - vmin) < SWING_MIN_V:
        return None, None, ('the line is dead: %.3f V of swing, under the %.2f V floor -- check the '
                            'generator output' % (vmax - vmin, SWING_MIN_V))
    tail = tagged(lines, 'gtail')
    if tail is None:
        return None, None, 'no scratch tail came back'
    vals = []
    for tok in tail.split():
        try:
            vals.append(float(tok))
        except ValueError:
            pass
    if not vals:
        return None, None, 'scratch tail held no numbers'
    mid = 0.5 * (vmin + vmax)
    idle = tagged(lines, 'idle')
    # IDLE DECIDES WHICH SIDE IS SPACE, and it is read from the capture rather than assumed: an
    # inverted line idles low, and counting "readings below the midpoint" would then measure the mark.
    mark_high = (idle != '0')
    run = 0
    for v in reversed(vals):
        below = (v < mid)
        if below == mark_high:          # a space reading on a mark-high line, or vice versa
            run += 1
        else:
            break
    if run == 0:
        return 0.0, 0, 'the scratch ends on idle, so block 3 took over before the start bit'
    if run >= len(vals):
        return None, run, 'the whole tail is space -- raise TAIL, L is past %d readings' % len(vals)
    return run / float(fs), run, ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--win', type=float, default=0.010, help='elision window, seconds')
    ap.add_argument('--no-load', action='store_true', help='app and engine already loaded')
    ap.add_argument('--arms', default='off,on', help='which fast-path arms to run')
    a = ap.parse_args()

    d = g = None
    rc = 1
    try:
        d = DMM(timeout=240)
        print('DMM:', str(d.q('*IDN?')).strip())
        if not a.no_load:
            print('loading the app and the bench engine')
            RB.load_modules(d, RB.APP + RB.ENGINE)
        g = SDG()
        print('SDG:', g.idn())
        srate = a.baud * SPB
        g.select_arb(VN.arb(VEC), AMP_VPP, srate, OFST_V, 1)
        # SELECT IS NOT ENABLE, and the first version of this probe left it off: every reading came back
        # within 20 mV of ground, the midpoint classification then ran on noise, and it reported "L = 0.0
        # us, the seam is free" from a dead line. Enabled here and asserted below.
        g.write('C1:OUTP ON,LOAD,HZ')
        print('stimulus: %s at %d Bd, %d Sa/s, %.1f Vpp @ %.1f V, output ON' %
              (VEC, a.baud, srate, AMP_VPP, OFST_V))
        print()

        got = {}
        for arm in [x.strip() for x in a.arms.split(',') if x.strip()]:
            fast = (arm == 'on')
            print('=== fast path %s ===' % arm.upper())
            lines = run_arm(d, a.baud, a.win, fast)
            for ln in lines:
                if ln.startswith('SL ') and 'gtail' not in ln:
                    print('  ' + ln[3:])
            fs = tagged(lines, 'fs')
            try:
                fsv = float(fs)
            except (TypeError, ValueError):
                fsv = None
            L, run, note = (None, None, 'no rate') if fsv is None else analyse(lines, a.baud, fsv)
            got[arm] = (L, run, tagged(lines, 'warn'), note, fsv)
            if note:
                print('  NOTE: ' + note)
            if L is not None:
                bits = L * a.baud
                print('  L = %.1f us  (%d reading(s) of space at %.0f S/s) = %.2f bit(s) at %d Bd'
                      % (L * 1e6, run, fsv, bits, a.baud))
                print('  seam is %s' % ('FREE -- under the half-bit sampling margin' if bits < 0.5
                                        else 'COSTLY -- past the half-bit margin, bytes will die'))
            print()

        print('=== verdicts ===')
        # THE WARNING IS THE CONTROL FOR THE LEVER. If it reads the same in both arms the blend did
        # not change the fast-path status and any difference in L is something else.
        for arm in ('off', 'on'):
            if arm in got:
                L, run, warn, note, fsv = got[arm]
                print('  fast path %-3s : low-latency warning present = %-9s  L = %s'
                      % (arm, warn, ('%.1f us' % (L * 1e6)) if L is not None else 'unmeasured'))
        if 'off' in got and 'on' in got:
            w0, w1 = got['off'][2], got['on'][2]
            if w0 == w1:
                print('  the blend did NOT change fast-path status, so it is not the lever')
            elif w0 == 'true' and w1 == 'false':
                print('  the blend DID clear the warning -- the program is on the fast path')
            L0, L1 = got['off'][0], got['on'][0]
            if L0 is not None and L1 is not None:
                print('  L moved %+.1f us (%+.0f %%)' % ((L1 - L0) * 1e6,
                                                         100.0 * (L1 - L0) / L0 if L0 else 0))
                print('  %s' % ('the fast path is the fix' if L1 * a.baud < 0.5
                                else 'still past the half-bit margin -- the fast path is NOT enough'))
        rc = 0
    finally:
        if g is not None:
            try:
                g.write('C1:OUTP OFF')
            except Exception:
                pass
        if d is not None:
            d.close()
    return rc


if __name__ == '__main__':
    sys.exit(main())

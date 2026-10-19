#!/usr/bin/env python3
"""Measure the HOLE at the elision handover: the samples neither buffer holds.

WHY THIS IS NOT bench_seamlat.py. That tool measures L, how far into the start bit the scratch
reaches, by counting the trailing space run. L bounds the latency and CANNOT SEE A HOLE: if block 3
opens later than block 1 stopped, the missing samples are in neither buffer, so no count taken
inside one buffer can find them. The seam analysis assumes the handover is continuous -- TRIG_ELIDE
charges a resume cost and then splices the two halves edge to edge -- and the splice measurement
says otherwise: every seam at 100 kS/s is displaced +2..+5 readings, and in the model a hole of half
a bit collapses the alignment while an OVERLAP of the same width costs nothing. That asymmetry is
what makes it a hole and not a latency.

WHAT MAKES IT MEASURABLE: A PERIODIC STIMULUS. The two buffers have no common timebase -- the
in-block timestamps follow the nominal sample period, so differencing them returns the nominal
period and nothing about the handover. A 1 kHz square puts an absolute clock ON THE WIRE instead.
Its crossings are a grid 500 us apart, both buffers see the same grid, and the phase of the
scratch's last sample against it plus the phase of the record's first sample against it add up to
the gap between them, modulo the half period:

    hole = k * 500 us  -  (crossing -> scratch end)  -  (record start -> crossing)  -  one sample

k = 1 whenever the hole is under half a period, which 70-90 us is by a wide margin.

WHAT THIS MEASURES IS NOT YET THE HOLE A GAP VECTOR SUFFERS, and the 2026-10-19 run is the reason
to say so up front. A continuously crossing line never gives the detector an idle window, so block 5
keeps extending the burst and blocks 1 and 3 ping-pong -- the program is in a different regime from
the one a real gap puts it in, where the scratch fills with 10 ms of genuine silence and the handover
happens at a burst's first crossing. The figures came out 220 us median at a 1 kHz grid and 183-471
at 500 Hz, and in the second run the value tracked the SCRATCH LENGTH at 98 us + 1.77 us per reading,
within 5 us on all seven trials. A firmware handover cost cannot depend on how much the scratch
happened to hold, so that correlation says the stimulus regime is in the measurement. It is checked
for and reported at the end of every run rather than left to be noticed.

The faithful stimulus is an arb that is flat for longer than the elision window and then carries a
crossing grid -- a gap vector with a square wave in place of its serial data. SDG burst mode is NOT
the way to get it: this bench has it recorded that BTWV STATE,ON fails all four stages, faking an
idle line.

THE SCRATCH IS SHORT, AND THAT SETS THE SHAPE OF THE RUN. Block 1 digitizes until the comparator
fires, and on a continuously crossing line it fires at the first crossing -- so the scratch holds at
most one half period, about 50 readings at 100 kS/s, with one crossing in it or none depending on
where the arm landed. Two consequences. The sample interval has to come from the RECORD, which has
hundreds of crossings, and the scratch is assumed to share it; `segfs` and `spanfs` are printed
beside it so that assumption can be checked. And a single capture is a coin flip on whether the
scratch caught a crossing at all, so this repeats and reports the spread -- which is worth having
regardless, the arm phase being the thing this bench has been caught by most often.

AND IT CALIBRATES ITSELF, which matters more than it looks. digitize.samplerate reads back the rate
it was asked for and delivers something else -- 640 000 asked, 634 615 delivered -- so a hole
expressed as "readings / fs" inherits that lie. Here the crossing spacing IS the sample interval:
500 us divided by the mean spacing in readings, measured separately in each buffer, so the figures
below never consult fs at all. If the two spacings disagree the two blocks ran at different rates,
which is itself worth knowing and is printed.

A SLOW-EDGED PULSE AND NOT A SQUARE, which is the one place this departs from the measurement as
specified, and it is forced by two requirements pulling opposite ways.

Interpolation wants a slow edge. A square's edge is ~40 ns against a 10 us sample interval, so no
reading ever lands on it: two consecutive readings sit at the two rails, and interpolating between
them puts the crossing at their midpoint whatever the truth was -- up to half a sample of bias on
each phase. The two biases cancel exactly while both buffers share a sample interval, which is why
the square still measures a hole correctly in the ordinary case, and they stop cancelling the moment
the blocks run at different rates, which is one of the things being tested for.

The CAPTURE wants two separable rails. sig_levels is a bimodal test, and the arm cannot be built
without it -- stream_arm refuses elision with no sdec.arm_thr -- so a triangle, whose readings are
uniformly distributed, would be refused before it reached a handover at all.

A 1 kHz pulse with 100 us edges satisfies both: 80 % of readings sit at the rails, so the levels
separate, and the edge spans ten readings at 100 kS/s, so the crossing is located to a few per cent
of a sample against millivolt noise. docs/TRIGGER.md section 7 took the comparator latency against a
slow ramp for this same reason. `--wave square` and `--wave triangle` are kept as cross-checks: all
three must agree on the hole, and the square's agreement is the evidence that the half-sample bias
really does cancel.

    python3 tools/bench_seamhole.py                    # 9600 Bd, the app's own burst rate
    python3 tools/bench_seamhole.py --fs 50000         # the second point the prediction names
    python3 tools/bench_seamhole.py --wave square      # the cross-check
    python3 tools/bench_seamhole.py --no-load          # app and engine already up

Prediction under test: 70-90 us at 100 kS/s, and under 104 us at 50 kS/s. A hole that scales with
the sample interval is a sample-count effect in the blocks; one fixed in time is a firmware
handover cost, and only the second explains a defect that keys on baud.

Reads nothing destructive: one elided capture per rate, no upload, no plan written, output off at
the end.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM              # noqa: E402
from siglent import SDG             # noqa: E402
import run_bench as RB              # noqa: E402

ARB_SPB = 10             # v98a renders at 10 arb samples a bit; tools/make_vectors.lua
VEC = 'v98a'             # names the elide branch in brun.point; the wire carries the ramp, not this
SQ_HZ = 1000.0           # default; --hz moves it, and the unambiguous range moves with it
AMP_VPP = 3.0
OFST_V = 1.5
HALF_US = 500.0          # half period of a 1 kHz stimulus, the crossing grid spacing
# WHY THE FREQUENCY IS A LEVER AND NOT A CONSTANT. The grid resolves the hole only modulo its half
# period, so the unambiguous range is +-half of that -- +-250 us at 1 kHz. The hole measured on
# 2026-10-19 is ~220 us, which sits AT that edge: two of the first eight trials aliased to -237 and
# -227 before the frequency was dropped. And the range cannot simply be widened, because the scratch
# is only 29-78 readings long and needs a crossing inside it, which a long half period will not
# supply. So the two requirements are read off the run rather than assumed: --hz sets the range and
# the per-trial scratch crossing count says whether that frequency still reaches the scratch.
NDUMP = 300              # readings per buffer: 6 half periods at 100 kS/s, 3 at 50
CHUNK = 50               # readings per printed line; one long line is a desync waiting to happen
SWING_MIN_V = 0.20       # dead line is 0.019 V, live is 0.992; this only has to separate those


# The dump is TAGGED PER LINE and chunked. A bare print stream desynchronises the moment one
# statement raises, and a raising TSP statement prints nothing at all while the host blocks for the
# whole timeout -- so each line names its buffer and its offset and the reader keys on the name.
TRIAL = r"""
sdec.force_nbits, sdec.force_par, sdec.force_nstop = 8, sdec.PAR_NONE, 1
sdec.force_invert = false
local fs = %(fs)s
if fs == nil then pcall(function() fs = sdec.fs_for_burst(%(baud)d) end) end
print('SH fsask=' .. tostring(fs))
-- elide_appfs would override the rate with fs_for_burst's choice, which is the whole point at the
-- app's own rate and defeats --fs. Saved and restored so the engine is left as it was found.
local keepapp = brun.elide_appfs
if %(pinfs)s then brun.elide_appfs = false end
local p = brun.point(fs, %(baud)d, true, %(win)g, '%(vec)s')
brun.elide_appfs = keepapp
print('SH ran=' .. tostring(p.ran) .. ' why=' .. tostring(p.why))
print('SH segfs=' .. tostring(p.elidefs) .. ' spanfs=' .. tostring(p.elidespanfs)
      .. ' nrd=' .. tostring(p.elidenrd) .. ' cap=' .. tostring(p.elidecap))
print('SH elided=' .. tostring(p.elided) .. ' win=' .. tostring(p.elidewin)
      .. ' spl=' .. tostring(p.splran) .. '/' .. tostring(p.splseam))
print('SH lv vmin=' .. tostring(sdec.vmin) .. ' vmax=' .. tostring(sdec.vmax)
      .. ' thr=' .. tostring(sdec.thr) .. ' idle=' .. tostring(sdec.idle))

-- One dumper for both buffers, because the rotation rule is the same rule and writing it twice is
-- how the two halves come to disagree. `head` picks which end: a record is read from its oldest
-- reading forward, a scratch ring from its newest backward.
local function dump(tag, b, n, head, want)
  if b == nil then print('SH ' .. tag .. 'err=nil buffer') return end
  local bn, bcap, bstart = nil, nil, nil
  pcall(function() bn = b.n end)
  pcall(function() bcap = b.capacity end)
  pcall(function() bstart = b.startindex end)
  print(string.format('SH %%sn=%%s %%scap=%%s %%sstart=%%s', tag, tostring(bn), tag, tostring(bcap),
                      tag, tostring(bstart)))
  if n ~= nil and bn ~= nil and n > bn then n = bn end
  if n == nil then n = bn end
  if n == nil or n < 1 then print('SH ' .. tag .. 'err=empty') return end
  -- The oldest reading is at startindex ONLY when the buffer has lapped; below capacity it is at 1
  -- and startindex is not meaningful. docs/MEASUREMENTS.md, 'A record can come back rotated'.
  local first = 1
  if bcap ~= nil and n >= bcap and bstart ~= nil and bstart >= 1 then first = bstart end
  local lo, hi
  if head then lo, hi = 1, want else lo, hi = n - want + 1, n end
  if lo < 1 then lo = 1 end
  if hi > n then hi = n end
  local i = lo
  while i <= hi do
    local j, out = i, ''
    while j <= hi and j < i + %(chunk)d do
      local pos = first + j - 1
      if pos > n then pos = pos - n end
      local v = nil
      pcall(function() v = b.readings[pos] end)
      if v == nil then out = out .. 'nan ' else out = out .. string.format('%%.5f ', v) end
      j = j + 1
    end
    -- The offset is ABSOLUTE in time order from the buffer's oldest reading, so the host can
    -- reassemble out of order and still know where a chunk sits.
    print(string.format('SH %%sd %%d %%s', tag, i - 1, out))
    i = j
  end
  -- AND THE TIMESTAMPS, WHICH NOTHING IN THIS REPO HAS EVER READ ON A SCRATCH. The seam analysis
  -- reads relativetimestamps on the record only, and the note at gap_blockstore claiming the pairing
  -- was by timestamp was wrong about its own code. If the two buffers share a time origin then the
  -- handover gap is their difference and the whole crossing-phase construction is unnecessary; if
  -- they do not, this says so in one line instead of leaving it assumed. Six from each end is enough
  -- to see both the origin and the step.
  local tout, tn = '', nil
  for tn = 1, 6 do
    local q
    if head then q = tn else q = n - 6 + tn end
    if q >= 1 and q <= n then
      local pos = first + q - 1
      if pos > n then pos = pos - n end
      local tv = nil
      pcall(function() tv = b.relativetimestamps[pos] end)
      if tv == nil then tout = tout .. 'nan ' else tout = tout .. string.format('%%.9f ', tv) end
    end
  end
  print('SH ' .. tag .. 'ts=' .. tout)
end

-- THE SCRATCH IS FOUND, NOT NAMED. sdec.gapbuf is the PANEL's single scratch and is nil on this path;
-- the recording program builds a set, and which member holds the opening handover's head depends on how
-- many bursts ran. So every candidate is offered and the fullest one wins. First attempt read gapbuf and
-- reported 'nil buffer' beside a perfectly good capture.
local best, bestn, bi = nil, 0, nil
local function offer(b)
  if b == nil then return end
  local bn = nil
  pcall(function() bn = b.n end)
  if type(bn) == 'number' and bn > bestn then best, bestn = b, bn end
end
offer(sdec.gapbuf)
if sdec.gap_used ~= nil then for bi = 1, table.getn(sdec.gap_used) do offer(sdec.gap_used[bi]) end end
if sdec.gapbufs ~= nil then for bi = 1, table.getn(sdec.gapbufs) do offer(sdec.gapbufs[bi]) end end
print('SH scratch=' .. tostring(bestn) .. ' readings')

-- nil for the count on BOTH, so each buffer's own n is used. sdec.nread is 0 by the time this runs:
-- brun.point's exit calls clear_measured(), which zeroes it, and passing it dumped nothing while the
-- record sat there holding 54 178 readings.
dump('g', best, nil, false, %(ndump)d)
dump('r', sdec.buf, nil, true, %(ndump)d)
print('===DONE===')
"""


def tagged(lines, key):
    """The value of one 'SH key=...' line, or None."""
    for ln in lines:
        s = str(ln).strip()
        if s.startswith('SH ') and (key + '=') in s:
            return s.split(key + '=', 1)[1].split(' ')[0]
    return None


def samples(lines, tag):
    """The dumped readings of one buffer, in time order, with gaps left as None.

    Keyed on the printed offset rather than on arrival order: a chunk that never arrived has to
    read as a hole in the array and not as a shift of everything after it.
    """
    got = {}
    pre = 'SH %sd ' % tag
    for ln in lines:
        s = str(ln).strip()
        if not s.startswith(pre):
            continue
        body = s[len(pre):].split()
        if not body:
            continue
        try:
            off = int(body[0])
        except ValueError:
            continue
        for k, tok in enumerate(body[1:]):
            try:
                got[off + k] = float(tok)
            except ValueError:
                got[off + k] = None
    if not got:
        return []
    return [got.get(i) for i in range(min(got), max(got) + 1)]


def crossings(vals, thr):
    """Fractional indices where the signal crosses thr, by linear interpolation.

    Interpolated rather than quantised because the quantity being measured is a fraction of a
    sample interval: at 100 kS/s one reading is 10 us against a hole of 70-90, so rounding each
    crossing to its sample would put +-10 us on each of the two phases.
    """
    out = []
    for i in range(1, len(vals)):
        a, b = vals[i - 1], vals[i]
        if a is None or b is None:
            continue
        if (a < thr) == (b < thr):
            continue
        if b == a:
            continue
        out.append((i - 1) + (thr - a) / (b - a))
    return out


def spacing(cross):
    """Mean half-period in readings, and the worst deviation from it.

    The deviation is the measurement's own error bar. A square wave's crossings are evenly spaced
    by construction, so scatter here is sample jitter plus any rate drift inside the block, and a
    hole quoted without it would look more exact than it is.
    """
    if len(cross) < 2:
        return None, None
    gaps = [cross[i] - cross[i - 1] for i in range(1, len(cross))]
    mean = sum(gaps) / len(gaps)
    worst = max(abs(g - mean) for g in gaps)
    return mean, worst


def analyse(lines, baud, half_us=HALF_US):
    """One trial -> (hole us, detail dict) or (None, why).

    THE INTERVAL COMES FROM THE RECORD AND THE SCRATCH BORROWS IT. The scratch is at most one half
    period long, so it cannot carry two crossings to measure its own spacing from; the record
    carries hundreds. Where the scratch does hold two, its own figure is reported beside the
    record's as a check and is NOT substituted, so the two trials are comparable.
    """
    # ONE RETURN SHAPE ON EVERY PATH: (hole or None, det). The reason for a refusal lives in
    # det['why'], so a trial that cannot give a hole still hands back the timestamps and the counts
    # -- which is the whole point on the arb arm, where no hole is expected and the timestamps are
    # the measurement.
    det = {'why': None}
    if tagged(lines, 'ran') != 'true':
        det['why'] = ('the capture did not run (ran=%s why=%s)'
                      % (tagged(lines, 'ran'), tagged(lines, 'why')))
        return None, det
    try:
        vmin, vmax = float(tagged(lines, 'vmin')), float(tagged(lines, 'vmax'))
    except (TypeError, ValueError):
        det['why'] = 'no levels came back'
        return None, det
    if (vmax - vmin) < SWING_MIN_V:
        det['why'] = ('the line is dead -- %.3f V of swing, under the %.2f V floor'
                      % (vmax - vmin, SWING_MIN_V))
        return None, det
    # The midpoint of the measured rails, not sdec.thr: thr is placed for a serial line, where the
    # mark is the resting level, and on a 50 % duty stimulus the two rails are equally occupied.
    thr = 0.5 * (vmin + vmax)
    gv, rv = samples(lines, 'g'), samples(lines, 'r')
    gc, rc = crossings(gv, thr), crossings(rv, thr)
    det.update({'thr': thr, 'ngv': len(gv), 'nrv': len(rv), 'ngc': len(gc), 'nrc': len(rc),
                'segfs': tagged(lines, 'segfs'), 'spanfs': tagged(lines, 'spanfs'),
                'nrd': tagged(lines, 'nrd'), 'scratch': tagged(lines, 'scratch')})
    # THE TWO BUFFERS' OWN TIMESTAMPS. Read because nothing in this repo ever has on a scratch --
    # gap_seams reads relativetimestamps on the record only, and the note at gap_blockstore claiming
    # the pairing was by timestamp was wrong about its own code. If the origins are shared the
    # handover gap is a subtraction and the whole crossing construction is unnecessary; if they are
    # not, this says so instead of leaving it assumed.
    for tag, key in (('gts', 'ts_scratch'), ('rts', 'ts_record')):
        raw = None
        for ln in lines:
            s = str(ln).strip()
            if s.startswith('SH ' + tag + '='):
                raw = s.split('=', 1)[1]
        vals = []
        for tok in (raw or '').split():
            try:
                vals.append(float(tok))
            except ValueError:
                vals.append(None)
        det[key] = vals
    if len(rc) < 2:
        det['why'] = ('the record holds %d crossing(s); two are needed for the interval' % len(rc))
        return None, det
    if not gc:
        det['why'] = ('the scratch caught no crossing -- the arm landed inside a rail. This is the '
                      'coin flip the retries are for, not a fault')
        return None, det
    sr, wr = spacing(rc)
    dtr = half_us / sr
    det['dtr'], det['sr'], det['wr'] = dtr, sr, wr
    if len(gc) >= 2:
        sg, wg = spacing(gc)
        det['dtg'], det['wg'] = half_us / sg, wg
    t_s = (len(gv) - 1 - gc[-1]) * dtr
    t_r = rc[0] * dtr
    det['t_s'], det['t_r'] = t_s, t_r
    base = t_s + t_r + dtr
    for k in range(0, 4):
        h = k * half_us - base
        if h >= -0.5 * half_us:
            det['k'] = k
            det['bits'] = h * 1e-6 * baud
            return h, det
    det['why'] = 'no k puts the handover inside half a period'
    return None, det


def slope(xs, ys):
    """Least-squares slope of ys on xs, or None where xs does not vary.

    Returned rather than a correlation coefficient because the units are the point: us of apparent
    hole per reading of scratch is directly comparable with the sample interval, and a coefficient
    would be large and alarming for a slope of no consequence.
    """
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / float(n), sum(ys) / float(n)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx <= 0:
        return None
    return sum((xs[i] - mx) * (ys[i] - my) for i in range(n)) / sxx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--tries', type=int, default=8,
                    help='captures to take. The arm phase decides whether the scratch caught a '
                         'crossing at all, so one capture is a coin flip')
    ap.add_argument('--fs', type=float, default=None,
                    help="capture rate; absent, the app's own fs_for_burst choice stands")
    ap.add_argument('--win', type=float, default=0.010, help='elision window, seconds')
    ap.add_argument('--no-load', action='store_true', help='app and engine already loaded')
    ap.add_argument('--wave', default='pulse', choices=('pulse', 'square', 'triangle', 'arb'),
                    help="stimulus shape; pulse locates the crossings far better while keeping the "
                         "rails separable, square and triangle are cross-checks, and `arb` plays the "
                         "gap vector itself -- the FAITHFUL regime, with real idle windows, where the "
                         "crossing grid is meaningless and only the timestamps can answer")
    ap.add_argument('--hz', type=float, default=SQ_HZ, metavar='HZ',
                    help='stimulus frequency. The hole is resolved only modulo half a period, so '
                         'this sets the unambiguous range to +-250000/HZ us -- and lowering it '
                         'eventually empties the scratch of crossings, which the per-trial counts '
                         'report')
    ap.add_argument('--edge', type=float, default=100e-6, metavar='SECONDS',
                    help='rise and fall time of the pulse; 100 us is ten readings at 100 kS/s')
    ap.add_argument('--raw', action='store_true', help='print every dumped reading')
    a = ap.parse_args()

    half_us = 0.5e6 / a.hz
    print('unambiguous range: +-%.0f us, at %.0f Hz' % (0.5 * half_us, a.hz))
    d = g = None
    rc = 1
    try:
        d = DMM(timeout=300)
        print('DMM:', str(d.q('*IDN?')).strip())
        if not a.no_load:
            print('loading the app and the bench engine')
            RB.load_modules(d, RB.APP + RB.ENGINE)
        g = SDG()
        print('SDG:', g.idn())
        # A PERIODIC SHAPE, NOT THE VECTOR'S ARB. select_arb would put serial traffic on the wire,
        # whose edges are at the data's mercy; the grid has to be unconditional for the phases to add.
        # BSWV is written directly for the triangle: siglent.py carries sine and square helpers only,
        # and TRIANGLE takes the same parameter set.
        if a.wave == 'arb':
            # THE VECTOR ITSELF, which is the only stimulus that puts the program in the regime the
            # defect lives in: v98a is silent for 610 bit times of every 1910, so the detector really
            # does see an idle window and the handover really is a burst's first crossing. The
            # crossing-grid construction cannot be used here -- serial edges are at the data's mercy
            # and carry no uniform period -- so this arm reports the TIMESTAMPS and nothing else.
            srate = a.baud * ARB_SPB
            g.select_arb(VN.arb(VEC), AMP_VPP, srate, OFST_V, 1)
            print('stimulus: %s at %d Bd, %d Sa/s, %.1f Vpp @ %.1f V'
                  % (VEC, a.baud, srate, AMP_VPP, OFST_V))
        elif a.wave == 'square':
            g.square(a.hz, AMP_VPP, OFST_V)
        elif a.wave == 'triangle':
            g.write('C1:BSWV WVTP,TRIANGLE,FRQ,%g,AMP,%g,OFST,%g,PHSE,0'
                    % (a.hz, AMP_VPP, OFST_V))
        else:
            # Symmetric edges, so the midpoint crossings stay 500 us apart. The spacing is not
            # trusted either way: the worst deviation from it is printed below and is this
            # measurement's own error bar.
            g.write('C1:BSWV WVTP,PULSE,FRQ,%g,AMP,%g,OFST,%g,DUTY,50,RISE,%g,FALL,%g'
                    % (a.hz, AMP_VPP, OFST_V, a.edge, a.edge))
        g.output(True)
        if a.wave != 'arb':
            print('stimulus: %.0f Hz %s, %.1f Vpp @ %.1f V, output ON  (half period %.0f us%s)'
                  % (a.hz, a.wave, AMP_VPP, OFST_V, half_us,
                     ', edges %.0f us' % (a.edge * 1e6) if a.wave == 'pulse' else ''))
        # READ BACK, because a parameter the generator rejected is not reported: BSWV takes what it
        # understands and leaves the rest, so an unsupported RISE would run as a hard square and the
        # crossings would quietly go back to being half a sample uncertain.
        print('readback: %s' % str(g.query('C1:BSWV?')).strip())
        print('output ON')
        print()

        body = TRIAL % {'fs': ('%g' % a.fs) if a.fs else 'nil',
                        'pinfs': 'true' if a.fs else 'false',
                        'baud': a.baud, 'win': a.win, 'vec': VEC,
                        'ndump': NDUMP, 'chunk': CHUNK}
        holes, dets, whys = [], [], []
        for t in range(a.tries):
            lines = [str(x) for x in d.load_script('seamhole', body, timeout=300)]
            # A SCRIPT FAULT IS NOT A HARDWARE REFUSAL, and conflating them cost 24 trials: a dropped
            # `end` in the block above is a PARSE error, so the instrument printed nothing at all, and
            # every tagged read came back None -- which analyse() reported as 'the capture did not
            # run', twelve times, in the voice of a refusal. A script that produced no tagged line at
            # all has not run, so stop rather than retry.
            if not [x for x in lines if x.startswith('SH ')]:
                print('REFUSING: the embedded script printed no tagged line. That is a fault in the')
                print('script and not in the capture -- a TSP parse error prints nothing. Output was:')
                for x in lines[:12]:
                    print('  %s' % x)
                return 1
            # THE ARB ARM MUST NOT REACH THE GRID, and this is a guard against the worst failure the
            # tool could have: serial edges give plenty of crossings, so spacing() would return a
            # mean of unrelated intervals, dtr would be meaningless, and a confident hole would print
            # from a grid that does not exist. The timestamps are the only thing this arm can say.
            if a.wave == 'arb':
                _, det = analyse(lines, a.baud, half_us)
                if not isinstance(det, dict):
                    print('try %d/%d: %s' % (t + 1, a.tries, det))
                    continue
                ts, tr = det.get('ts_scratch') or [], det.get('ts_record') or []
                gap = None
                if ts and tr and ts[-1] is not None and tr[0] is not None:
                    gap = (tr[0] - ts[-1]) * 1e6
                print('try %d/%d: scratch %d rd, record %d rd, spl=%s, '
                      'record_first - scratch_last = %s'
                      % (t + 1, a.tries, det['ngv'], det['nrv'], tagged(lines, 'spl'),
                         ('%+.2f us' % gap) if gap is not None else 'unreadable'))
                print('         scratch ts [... %s]  record ts [%s ...]'
                      % (' '.join('%.6f' % v for v in ts[-3:] if v is not None) or 'none',
                         ' '.join('%.6f' % v for v in tr[:3] if v is not None) or 'none'))
                if gap is not None:
                    holes.append(gap)
                    det['hole'] = gap
                    dets.append(det)
                continue
            h, det = analyse(lines, a.baud, half_us)
            if h is None:
                whys.append(det.get('why') or 'unstated')
                print('try %d/%d: %s' % (t + 1, a.tries, det.get('why')))
                continue
            holes.append(h)
            det['hole'] = h
            dets.append(det)
            # BOTH PHASES ON THE LINE, not just the hole they combine into. Each should be nearly
            # constant on its own -- the scratch ends at the firing crossing plus the comparator's
            # fixed 7.3 us, and the record opens one hole later -- so scatter in the total has to be
            # attributable to one of them or the pair is not measuring what it is named for.
            print('try %d/%d: hole %+8.2f us = %+.3f bit   t_s=%7.2f t_r=%7.2f k=%d   '
                  'scratch %d rd / %d xing, record %d rd / %d xing, dt %.4f us'
                  % (t + 1, a.tries, h, det['bits'], det['t_s'], det['t_r'], det['k'],
                     det['ngv'], det['ngc'], det['nrv'], det['nrc'], det['dtr']))
            if a.raw:
                gv, rv = samples(lines, 'g'), samples(lines, 'r')
                print('  scratch:', ' '.join('%.4f' % x if x is not None else 'nan' for x in gv))
                print('  record: ', ' '.join('%.4f' % x if x is not None else 'nan' for x in rv))
        print()
        if not holes:
            print('REFUSING: no trial produced a measurement.')
            for w in sorted(set(whys)):
                print('  %s' % w)
            return 1

        d0 = dets[0]
        print('stimulus and capture, from the last good trial:')
        print('  levels         : threshold %.4f V' % d0['thr'])
        print('  sample interval: %.4f us -> %.0f S/s, from the crossing grid alone'
              % (d0['dtr'], 1e6 / d0['dtr']))
        print('  worst crossing deviation in the record: %.3f readings = %.2f us'
              % (d0['wr'], d0['wr'] * d0['dtr']))
        print('  segfs=%s spanfs=%s nrd=%s   (segfs is what the scratch is assumed to share)'
              % (d0['segfs'], d0['spanfs'], d0['nrd']))
        # THE TIMESTAMP QUESTION, ANSWERED ON THE ROW RATHER THAN ASSUMED. Printed for every trial
        # because a shared origin would make this whole measurement a subtraction, and a per-buffer
        # origin is itself the finding -- it is what makes the scratch's time base unusable.
        print('timestamps, scratch tail then record head:')
        for i, x in enumerate(dets):
            ts, tr = x.get('ts_scratch') or [], x.get('ts_record') or []
            fs = ' '.join('%.6f' % v for v in ts[-3:] if v is not None) or 'none'
            fr = ' '.join('%.6f' % v for v in tr[:3] if v is not None) or 'none'
            d = ''
            if ts and tr and ts[-1] is not None and tr[0] is not None:
                d = '   record_first - scratch_last = %+.2f us' % ((tr[0] - ts[-1]) * 1e6)
            print('  try %d: scratch [... %s]  record [%s ...]%s' % (i + 1, fs, fr, d))
        # THE SCRATCH'S OWN INTERVAL WHERE IT HAD ENOUGH CROSSINGS TO GIVE ONE. It is reported and
        # not substituted: substituting on the trials that happen to have two crossings would make
        # the trials incomparable, and the point of the comparison is the spread.
        dtgs = [x['dtg'] for x in dets if 'dtg' in x]
        if dtgs:
            print('  scratch interval, where measurable: %s us'
                  % ' '.join('%.4f' % x for x in dtgs))
            if max(abs(x - d0['dtr']) / d0['dtr'] for x in dtgs) > 0.02:
                print('  NOTE: the two blocks ran at DIFFERENT rates. That alone breaks a splice')
                print('        assuming one timebase, and is a finding in its own right.')
        else:
            print('  scratch interval: not measurable, no trial caught two crossings in it')

        holes.sort()
        med = holes[len(holes) // 2] if len(holes) % 2 else \
            0.5 * (holes[len(holes) // 2 - 1] + holes[len(holes) // 2])
        bits = med * 1e-6 * a.baud
        kind = 'HOLE' if med > 0 else ('OVERLAP' if med < 0 else 'CONTINUOUS')
        print()
        print('=== verdict over %d of %d trials ===' % (len(holes), a.tries))
        print('  median %s of %.2f us = %.3f bit times at %d Bd'
              % (kind, abs(med), abs(bits), a.baud))
        print('  spread %+.2f .. %+.2f us, %.2f us wide'
              % (holes[0], holes[-1], holes[-1] - holes[0]))
        print('  per trial: %s' % ' '.join('%+.1f' % x for x in holes))
        # THE SPREAD IS THE VERDICT'S OWN GATE. A handover cost is a firmware constant, so trials
        # that disagree by more than a sample are not measuring one quantity and the median of them
        # means nothing. Said here rather than left to the reader, because a median always prints.
        if holes[-1] - holes[0] > 2.0 * d0['dtr']:
            print('  NOT A CONSTANT: the spread is over two sample intervals, so these trials are')
            print('  not measuring one handover cost. Treat the median as a range, not a figure.')
        # AND THE CONFOUND NAMED IN THE DOCSTRING, TESTED. A firmware handover cost cannot depend on
        # how many readings the scratch happened to hold, so a slope here means the stimulus regime is
        # inside the figure. Checked because it was missed by eye for two runs and is obvious once
        # printed: the 500 Hz run fitted 1.77 us per reading and the number still looked plausible.
        sl = slope([x['ngv'] for x in dets], [x['hole'] for x in dets])
        if sl is not None:
            print('  hole against scratch length: %+.3f us per reading' % sl)
            if abs(sl) > 0.05 * d0['dtr']:
                print('  CONFOUNDED: the figure TRACKS the scratch length, so it is not a handover')
                print('  cost. A continuously crossing line never gives the detector an idle window,')
                print('  which is a different regime from the gap this is meant to describe. The')
                print('  stimulus needs a flat stretch longer than the elision window -- see the')
                print('  module docstring. Do not quote the median above.')
                rc = 2
        if kind == 'HOLE':
            print('  TRIG_ELIDE splices the two halves edge to edge, so the model is short by this'
                  ' much at every seam.')
            if abs(bits) >= 0.5:
                print('  Past the half-bit sampling margin: the framer re-anchors and the bytes after'
                      ' the seam are confidently wrong.')
            else:
                print('  Under the half-bit margin at this baud; it crosses half a bit at %.0f Bd.'
                      % (0.5 / (med * 1e-6)))
            print('  To put it in the twin:  TRIG_HOLE(%.6g)' % (med * 1e-6))
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

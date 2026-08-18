#!/usr/bin/env python3
"""BRINGUP 4b.11 -- which sample rates off the 1/2/5 ladder actually exist.

WHY THIS EXISTS AS A FILE rather than a pasted one-liner: 4b.11 was attempted
twice with a SimpleLoop trigger model and produced -4.9% on rates FINDINGS
records as EXACT. Both attempts looked like a hardware result and were a harness
artifact. The fix is not care, it is CONTROLS -- so this sweep interleaves nine
rates whose true value is already on record (1000/10000/20000/50000/100000/
200000/500000/1000000 exact, and 102400 known-inexact at 102325.5) with the
seventeen candidates. If the controls do not come back at their recorded values,
the run is thrown away and nothing is written down. A candidate rate is only
believable in a sweep that reproduces the rates already known.

Two capture methods per rate, because they are different questions:

  digitize.read()  -- dmm.digitize.count = n; dmm.digitize.read(buf)
                      what the HARDWARE can synthesise. This is 4b.11 proper.
  SimpleLoop       -- trigger.model.load('SimpleLoop', n, 0, buf)
                      what THIS APP delivers. FINDINGS claims a constant
                      +0.510 us per sample interval from four points; twenty-six
                      rates spanning 900 -> 1 M either confirm that or kill it.

Both are timed off buffer.relativetimestamps, and the span is taken TWICE --
once as t[n]-t[1] and once as t[n-1]-t[2] -- so a first- or last-sample offset
cannot masquerade as a rate error. Arithmetic is done here in full double
precision, not on the instrument.

Reads only. No calibration command is issued, no UI object is created, so this
does not consume the one-build-per-power-cycle budget.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM

# --------------------------------------------------------------------------
# The rates. CANDIDATES are 4b.11's question; CONTROLS are the answer key.
# --------------------------------------------------------------------------
CANDIDATES = [900, 1250, 2500, 5000, 15000, 30000, 40000, 60000, 80000,
              120000, 160000, 250000, 300000, 320000, 350000, 400000, 640000]

# From FINDINGS "Sample rates: only some are exact". 102400 is the valuable one:
# it is the only rate on record that the hardware CANNOT make, so reproducing
# 102325.5 proves this harness has both the accuracy and the resolution to tell
# an inexact rate from an exact one.
CONTROLS = {
    1000: 1000.0,
    10000: 10000.0,
    20000: 20000.0,
    50000: 50000.0,
    100000: 100000.0,
    102400: 102325.5,
    200000: 200000.0,
    500000: 500000.0,
    1000000: 1000000.0,
}

# A control is met if it lands this close to its recorded value. The exact rates
# were recorded to 7 digits; 0.02% is far looser than that and still 250x tighter
# than the -4.9% the bad attempts produced, so it cannot pass a broken harness.
CONTROL_TOL = 2e-4

RATES = sorted(set(CANDIDATES) | set(CONTROLS))

TSP = r'''
-- loadscript only STORES this chunk; dmmrun runs it by calling the SCRIPT name,
-- which executes the chunk. So the chunk must CALL the work itself -- defining a
-- function and stopping produces a silent timeout with no output at all.
function run4b11()
  local rates = {%(rates)s}
  local nr = table.getn(rates)

  -- Digitize function FIRST. Setting dmm.digitize.samplerate while the
  -- instrument is on a DC measure function raises 2800; that cost a whole
  -- attempt last session.
  dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range = 10
  -- 1 us is the legal minimum AND is <= 1/fs for every rate here, so aperture
  -- never needs to move with the rate and cannot be the thing that changes.
  dmm.digitize.aperture = 1e-6

  -- delete -> nil -> create, never create over a live handle.
  if CAP ~= nil then
    pcall(function() buffer.delete(CAP) end)
    CAP = nil
  end
  CAP = buffer.make(%(cap)d, buffer.STYLE_STANDARD)
  print(string.format('SETUP cap=%%d ap=%%.9g rng=%%.9g',
                      CAP.capacity, dmm.digitize.aperture, dmm.digitize.range))

  local function report(r, mode, nn)
    local got = CAP.n
    if got < 4 then
      print(string.format('E %%d %%s short got=%%d', r, mode, got))
      return
    end
    if got > nn then got = nn end
    local ts = CAP.relativetimestamps
    print(string.format('R %%d %%s %%.12g %%d %%d %%.12g %%.12g %%.12g %%.12g',
                        r, mode, dmm.digitize.samplerate, nn, got,
                        ts[1], ts[2], ts[got - 1], ts[got]))
  end

  local i
  for i = 1, nr do
    local r = rates[i]
    local nn = math.floor(r * %(dur)g)
    if nn < %(nmin)d then nn = %(nmin)d end
    if nn > %(cap)d then nn = %(cap)d end

    eventlog.clear()
    local ok = pcall(function() dmm.digitize.samplerate = r end)
    local ec = eventlog.getcount()
    if not ok or ec > 0 then
      local msg = ''
      if ec > 0 then msg = tostring(eventlog.next()) end
      print(string.format('E %%d set rejected raise=%%s ec=%%d %%s',
                          r, tostring(not ok), ec, msg))
    else
      -- (1) what the hardware can do, with nothing of ours in the loop
      dmm.digitize.count = nn
      CAP.clear()
      local okr = pcall(function() dmm.digitize.read(CAP) end)
      if okr then report(r, 'read', nn) else
        print(string.format('E %%d read raised', r)) end

      -- (2) what this app's own capture path delivers at the same rate
      trigger.model.abort()
      CAP.clear()
      local okl = pcall(function()
        trigger.model.load('SimpleLoop', nn, 0, CAP)
        trigger.model.initiate()
      end)
      if okl then
        local guard = 0
        while CAP.n < nn and guard < 4000 do
          delay(0.01)
          guard = guard + 1
        end
        trigger.model.abort()
        report(r, 'loop', nn)
      else
        print(string.format('E %%d loop raised', r))
      end

      local ec2 = eventlog.getcount()
      if ec2 > 0 then
        print(string.format('E %%d after ec=%%d %%s', r, ec2,
                            tostring(eventlog.next())))
      end
    end
  end

  -- Leave it tidy: model idle, scratch buffer gone, back on a measure function.
  trigger.model.abort()
  pcall(function() buffer.delete(CAP) end)
  CAP = nil
  dmm.measure.func = dmm.FUNC_DC_VOLTAGE
  eventlog.clear()
  print('===DONE===')
end

run4b11()
'''


def build_tsp(cap, dur, nmin):
    return TSP % {
        'rates': ', '.join(str(r) for r in RATES),
        'cap': cap,
        'dur': dur,
        'nmin': nmin,
    }


def parse(lines):
    """Turn the instrument's lines into rows, doing every division here."""
    rows, errs, setup = [], [], None
    for ln in lines:
        f = ln.split()
        if not f:
            continue
        if f[0] == 'SETUP':
            setup = ln
            continue
        if f[0] == 'E':
            errs.append(ln)
            continue
        if f[0] != 'R' or len(f) != 10:
            errs.append('UNPARSED: ' + ln)
            continue
        r = int(f[1])
        mode = f[2]
        readback = float(f[3])
        nn, got = int(f[4]), int(f[5])
        t1, t2, tp, tn = (float(x) for x in f[6:10])
        # Two independent spans. The inner one drops the first and last sample,
        # so a start-up or shutdown offset shows as a disagreement between them
        # rather than quietly biasing the answer.
        span_out = tn - t1
        span_in = tp - t2
        fs_out = (got - 1) / span_out if span_out > 0 else float('nan')
        fs_in = (got - 3) / span_in if span_in > 0 and got > 3 else float('nan')
        rows.append(dict(
            rate=r, mode=mode, readback=readback, n=nn, got=got,
            fs_out=fs_out, fs_in=fs_in,
            first_dt=t2 - t1, span=span_out,
            disagree=abs(fs_out - fs_in) / fs_out if fs_out > 0 else float('nan'),
        ))
    return setup, rows, errs


def check_controls(rows):
    """The gate. Returns (ok, lines) -- if not ok, write nothing down."""
    out, ok = [], True
    for row in rows:
        if row['mode'] != 'read' or row['rate'] not in CONTROLS:
            continue
        want = CONTROLS[row['rate']]
        got = row['fs_out']
        err = (got - want) / want
        good = abs(err) <= CONTROL_TOL
        ok = ok and good
        out.append('  %-9s want %12.1f  got %12.1f  %+.4f%%  %s'
                   % (row['rate'], want, got, err * 100.0,
                      'ok' if good else '*** MISMATCH ***'))
    if not out:
        return False, ['  no control rates returned at all']
    return ok, out


def fmt(rows):
    by = {}
    for row in rows:
        by.setdefault(row['rate'], {})[row['mode']] = row
    lines = ['', '%-9s %-4s %13s %8s %13s %8s %9s %8s'
             % ('requested', 'kind', 'digitize.read', 'err', 'SimpleLoop',
                'err', 'offset_us', 'sa/bit')]
    lines.append('-' * 88)
    for r in RATES:
        d = by.get(r)
        if not d:
            continue
        kind = 'ctl' if r in CONTROLS else 'cand'
        rd, lp = d.get('read'), d.get('loop')

        def cell(row):
            if not row:
                return '%13s %8s' % ('--', '--')
            e = (row['fs_out'] - r) / r * 100.0
            return '%13.1f %+7.3f%%' % (row['fs_out'], e)

        # The per-sample interval the trigger model adds: the whole of claim 2.
        off = ''
        if rd and lp and rd['fs_out'] > 0 and lp['fs_out'] > 0:
            off = '%9.3f' % ((1.0 / lp['fs_out'] - 1.0 / rd['fs_out']) * 1e6)
        else:
            off = '%9s' % '--'
        lines.append('%-9s %-4s %s %s %s' % (r, kind, cell(rd), cell(lp), off))
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', default=I.DMM_IP)
    ap.add_argument('--cap', type=int, default=20000,
                    help='scratch buffer size, also the max samples per capture')
    ap.add_argument('--dur', type=float, default=0.05,
                    help='target seconds of signal per capture')
    ap.add_argument('--nmin', type=int, default=500,
                    help='floor on samples, so a slow rate still gives a long span')
    ap.add_argument('--dry', action='store_true', help='print the TSP and exit')
    a = ap.parse_args()

    body = build_tsp(a.cap, a.dur, a.nmin)
    if a.dry:
        print(body)
        return 0

    d = DMM(ip=a.ip)
    try:
        print(I.firmware(d) if False else d.q('print(localnode.model, localnode.version)'))
        lines = d.load_script('b4b11', body, timeout=300)
    finally:
        d.close()

    for ln in lines:
        print(ln)
    setup, rows, errs = parse(lines)
    print('\n' + (setup or 'NO SETUP LINE'))
    if errs:
        print('\nrejections and errors:')
        for e in errs:
            print('  ' + e)

    print('\nCONTROLS (the gate -- these must reproduce FINDINGS):')
    ok, cl = check_controls(rows)
    for ln in cl:
        print(ln)
    print(fmt(rows))

    worst = max((r['disagree'] for r in rows
                 if not math.isnan(r['disagree'])), default=float('nan'))
    print('\nworst outer/inner span disagreement: %.2e '
          '(a first-sample offset would show here)' % worst)

    if not ok:
        print('\nCONTROLS FAILED -- the harness is wrong, not the hardware. '
              'Nothing here goes into FINDINGS.')
        return 1
    print('\ncontrols met -- candidate rows are believable')
    return 0


if __name__ == '__main__':
    sys.exit(main())

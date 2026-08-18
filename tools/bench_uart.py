#!/usr/bin/env python3
"""End-to-end characterisation: real UART from the SDG, decoded on the DMM.

WHAT THIS ANSWERS that no offline test can. Everything up to now has been the
decoder run against arrays this repo generated itself, which proves the logic and
proves nothing about the instrument. This plays the SAME arrays through the
SDG's DAC, into the DMM's front end, captures them with the app's OWN acquisition
path (sdec.acquire, analog edge trigger, SimpleLoop) and decodes them with the
app's OWN decoder. So a disagreement here is a fact about hardware.

Four things get measured per baud rate, and they are the whole "what can we
deliver" question:

  correctness   decoded bytes must be a CONTIGUOUS CYCLIC SUBSTRING of the
                1024-byte payload the manifest says was transmitted. Cyclic
                because a TrueArb waveform LOOPS -- the capture window lands
                wherever it lands, and may straddle the wrap.
  acquire time  seconds for sdec.acquire(), which includes the probe capture,
                the level learning and the armed capture
  decode time   seconds for sdec.decode() -- bit timing, format search, framing
  yield         bytes recovered per capture, and bytes/second end to end

It also incidentally settles a question serial_core.tsp flags in a comment as
UNVERIFIED ON HARDWARE: whether trigger.model.load() accepts the buffer object
and whether the analog trigger re-arms per capture. If the edge path silently
falls back to free-run, that shows up here as trigmode disagreeing with what was
asked for.

Reads and captures only. No calibration command on either instrument, and no
display object is created, so the one-build-per-power-cycle budget is untouched.
"""
import argparse
import csv
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG

VECDIR = 'out/vectors'

# The sweep. These five vectors are the 1024-byte lorem stream, which is the only
# payload long enough that a capture window is a substring rather than the whole
# thing -- i.e. the only one that measures YIELD rather than just correctness.
# v71/72/73 are deliberately the same file at three sample rates, so if baud
# detection tracked the file instead of the playback rate it would show up as
# three identical answers.
SWEEP = ['v75', 'v71', 'v72', 'v73', 'v74']    # 1200 9600 19200 57600 115200

# The measurement function is appended to the module load so it exists once and
# is called per point. Keeping it here rather than sending it per point avoids a
# script.delete() per measurement, each of which logs a cosmetic -104 into the
# same event log this run uses to judge health.
BENCH_TSP = r'''
-- Appended by tools/bench_uart.py. One capture+decode, one line of result.
function bench_point(baud, fs, trig, lock, fmt)
  eventlog.clear()
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  if lock then sdec.force_baud = baud end
  -- fmt='8N1' bypasses the polarity and format search entirely, which is how the
  -- polarity question gets isolated from everything downstream of it.
  if fmt then
    sdec.force_nbits, sdec.force_par = 8, sdec.PAR_NONE
    sdec.force_nstop, sdec.force_invert = 1, false
  end
  sdec.fs = fs
  sdec.trigmode = trig

  timer.cleartime()
  local ok, why = sdec.acquire()
  local tacq = timer.gettime()
  if not ok then
    print(string.format('P fail acq %s', tostring(why)))
    print('P end')
    return
  end

  timer.cleartime()
  local okd, whyd = sdec.decode()
  local tdec = timer.gettime()
  if not okd then
    print(string.format('P faildec %s afs=%.9g n=%d vmin=%s vmax=%s ne=%s',
                        tostring(whyd), sdec.acq_fs or 0, sdec.nread or 0,
                        tostring(sdec.vmin), tostring(sdec.vmax),
                        tostring(sdec.ne)))
    print('P end')
    return
  end

  local r = sdec.res
  -- trigmode is echoed back because acquire() may fall back to free-run without
  -- failing, and a silent fallback would otherwise be invisible here.
  print(string.format('P ok %.9g %d %.9g %d %d %d %.9g %.9g %d %s %d %s %s',
                      sdec.acq_fs or 0, sdec.nread or 0, sdec.baud or 0,
                      r.nf, r.ngood, r.nbad, tacq, tdec,
                      eventlog.getcount(), tostring(sdec.trigmode),
                      r.framebits, tostring(sdec.vmin), tostring(sdec.vmax)))
  print(string.format('D nread=%s ne=%s idle=%s thr=%s bittime=%s lasterr=%s',
                      tostring(sdec.nread), tostring(sdec.ne),
                      tostring(sdec.idle), tostring(sdec.thr),
                      tostring(sdec.bittime), tostring(sdec.lasterr)))

  local i0 = 1
  while i0 <= r.nf do
    local i1 = i0 + 63
    if i1 > r.nf then i1 = r.nf end
    local seg, k = {}, nil
    for k = i0, i1 do
      -- A frame with an error still has a value; flag it so a byte that only
      -- matches because the error was ignored cannot pass the substring check.
      if r.errs[k] == nil then
        seg[table.getn(seg) + 1] = string.format('%02X', r.vals[k])
      else
        seg[table.getn(seg) + 1] = '??'
      end
    end
    print('B ' .. table.concat(seg, ''))
    i0 = i1 + 1
  end
  print('P end')
end

-- Step through acquire() one stage at a time, reporting the sample count each
-- stage actually produced. Written because a capture came back 139 samples long
-- when every path in acquire() should yield either 2000 or 20000, and reading the
-- code twice did not explain it.
function bench_diag(baud, fs)
  sdec.force_baud, sdec.force_nbits = baud, nil
  sdec.fs, sdec.trigmode = fs, 'edge'
  sdec.hw_config()
  print(string.format('D1 hw_config  fs=%s  digitize.count=%s  samplerate_rb=%s',
                      tostring(sdec.fs), tostring(dmm.digitize.count),
                      tostring(dmm.digitize.samplerate)))
  sdec.acq_make_buffer(sdec.n)
  print(string.format('D2 buffer     asked=%s capacity=%s n=%s',
                      tostring(sdec.n), tostring(sdec.buf.capacity),
                      tostring(sdec.buf.n)))
  local g1 = sdec.acq_free(sdec.probe_n)
  print(string.format('D3 probe      asked=%s got=%s buf.n=%s fs=%.9g',
                      tostring(sdec.probe_n), tostring(g1),
                      tostring(sdec.buf.n), sdec.acq_fs or 0))
  local ok, why = sdec.sig_levels(sdec.smp, sdec.nread)
  print(string.format('D4 levels     ok=%s why=%s vmin=%s vmax=%s thr=%s idle=%s',
                      tostring(ok), tostring(why), tostring(sdec.vmin),
                      tostring(sdec.vmax), tostring(sdec.thr),
                      tostring(sdec.idle)))
  local slope = dmm.SLOPE_FALLING
  if sdec.idle == 0 then slope = dmm.SLOPE_RISING end
  local g2 = sdec.acq_triggered(sdec.n, slope)
  print(string.format('D5 triggered  asked=%s got=%s buf.n=%s cap=%s fs=%.9g '
                      .. 'lasterr=%s', tostring(sdec.n), tostring(g2),
                      tostring(sdec.buf.n), tostring(sdec.buf.capacity),
                      sdec.acq_fs or 0, tostring(sdec.lasterr)))
  local g3 = sdec.acq_free(sdec.n)
  print(string.format('D6 free       asked=%s got=%s fs=%.9g',
                      tostring(sdec.n), tostring(g3), sdec.acq_fs or 0))
  print(string.format('D7 eventlog   count=%s', tostring(eventlog.getcount())))
  while eventlog.getcount() > 0 do
    print('D8 event      ' .. tostring(eventlog.next()))
  end
  print('P end')
end

-- The armed-capture path on its own, with nothing of the app around it. Answers
-- three things serial_core.tsp could only assume: does trigger.model.load()
-- accept the buffer OBJECT or does it want the name; does the analog trigger
-- actually fire on a live line; and does abort() really stop the model, or does
-- it keep filling the buffer underneath the next capture.
function trig_diag(fs, thr, rising)
  dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range = 10
  dmm.digitize.samplerate = fs
  dmm.digitize.aperture = 1e-6
  dmm.digitize.count = 20000
  trigger.model.abort()
  if TB ~= nil then
    pcall(function() buffer.delete(TB) end)
    TB = nil
  end
  TB = buffer.make(20000, buffer.STYLE_STANDARD)
  eventlog.clear()

  local ok1, e1 = pcall(function()
    dmm.digitize.analogtrigger.mode       = dmm.MODE_EDGE
    dmm.digitize.analogtrigger.edge.level = thr
    if rising then
      dmm.digitize.analogtrigger.edge.slope = dmm.SLOPE_RISING
    else
      dmm.digitize.analogtrigger.edge.slope = dmm.SLOPE_FALLING
    end
  end)
  print(string.format('T1 analogtrigger ok=%s err=%s mode=%s level=%s slope=%s',
                      tostring(ok1), tostring(e1),
                      tostring(dmm.digitize.analogtrigger.mode),
                      tostring(dmm.digitize.analogtrigger.edge.level),
                      tostring(dmm.digitize.analogtrigger.edge.slope)))

  local ok2, e2 = pcall(function()
    trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5,
                       trigger.CLEAR_ENTER, 0, TB)
  end)
  print(string.format('T2 load(OBJECT) ok=%s err=%s', tostring(ok2),
                      tostring(e2)))
  if not ok2 then
    local ok3, e3 = pcall(function()
      trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5,
                         trigger.CLEAR_ENTER, 0, 'TB')
    end)
    print(string.format('T3 load(NAME) ok=%s err=%s', tostring(ok3),
                        tostring(e3)))
  end

  TB.clear()
  trigger.model.initiate()
  local i
  for i = 1, 25 do
    delay(0.1)
    print(string.format('T5 t=%.1f TB.n=%s def1.n=%s state=%s',
                        i * 0.1, tostring(TB.n), tostring(defbuffer1.n),
                        tostring(trigger.model.state())))
    if (TB.n or 0) >= 20000 then break end
  end
  trigger.model.abort()
  print(string.format('T6 abort   TB.n=%s state=%s', tostring(TB.n),
                      tostring(trigger.model.state())))
  delay(0.5)
  print(string.format('T7 +0.5s   TB.n=%s state=%s', tostring(TB.n),
                      tostring(trigger.model.state())))
  dmm.digitize.analogtrigger.mode = dmm.MODE_OFF
  print(string.format('T8 eventlog=%s', tostring(eventlog.getcount())))
  while eventlog.getcount() > 0 do
    print('T9 ' .. tostring(eventlog.next()))
  end
  print('P end')
end

-- Ground truth on POLARITY, straight off the samples, with no decoder involved.
-- A continuous ASCII stream is high most of the time -- stop bits plus the 1 bits
-- of lowercase letters -- so frac_high and the longest runs settle idle level
-- without any scoring heuristic having an opinion about it.
function pol_diag(baud, fs)
  sdec.force_baud, sdec.force_nbits = baud, nil
  sdec.fs, sdec.trigmode = fs, 'edge'
  local ok, why = sdec.acquire()
  if not ok then
    print('L fail ' .. tostring(why))
    print('P end')
    return
  end
  local s, n, thr = sdec.smp, sdec.nread, sdec.thr
  local nhi, runhi, runlo, cur, curlvl = 0, 0, 0, 0, nil
  local i
  for i = 1, n do
    local lvl = 0
    if s[i] > thr then lvl = 1; nhi = nhi + 1 end
    if lvl == curlvl then
      cur = cur + 1
    else
      cur, curlvl = 1, lvl
    end
    if lvl == 1 then
      if cur > runhi then runhi = cur end
    else
      if cur > runlo then runlo = cur end
    end
  end
  print(string.format('L n=%d thr=%.4f frac_high=%.4f runhi=%d runlo=%d '
                      .. 'sig_idle=%s st0=%s ne=%s bittime=%s',
                      n, thr, nhi / n, runhi, runlo, tostring(sdec.idle),
                      tostring(sdec.st0), tostring(sdec.ne),
                      tostring(fs / baud)))
  -- The first 48 samples, so the idle level and the first start bit are visible
  -- as numbers rather than inferred from statistics.
  local parts = {}
  for i = 1, 48 do
    parts[i] = string.format('%.2f', s[i])
  end
  print('L head ' .. table.concat(parts, ' '))
  print('P end')
end

function bench_rates(baud)
  print(string.format('FS %d %s %s %s', baud,
                      tostring(sdec.fs_for_baud(baud)),
                      tostring(sdec.fs_for_burst(baud)),
                      tostring(sdec.minsabit)))
end
'''


def load_modules(d, modules, verbose=True):
    """Load the decoder onto the instrument as one chunk and prove it is there."""
    body = []
    for m in modules:
        with open(m) as f:
            body.append('-- ==== %s ====' % m)
            body.append(f.read())
    body.append(BENCH_TSP)
    # The chunk defines things and prints nothing, so give load_script its
    # sentinel or it waits out the whole timeout and reports a timeout instead.
    body.append("print('===DONE===')")
    src = '\n'.join(body)
    if verbose:
        print('loading %d bytes / %d lines of TSP...'
              % (len(src), src.count('\n') + 1))
    t0 = time.time()
    out = d.load_script('sdecmod', src, timeout=300)
    if verbose:
        print('  %.1f s' % (time.time() - t0))
    for ln in out:
        if ln and ln != '===DONE===':
            print('  module load said: ' + ln)
    probe = d.q('print(tostring(sdec ~= nil), tostring(sdec.decode ~= nil), '
                'tostring(bench_point ~= nil), tostring(sdec.minsabit))')
    if probe is None or 'nil' in probe.split():
        raise RuntimeError('module load did not define the decoder: %r' % probe)
    return probe


def manifest():
    with open(os.path.join(VECDIR, 'manifest.tsv')) as f:
        return {r['file'].replace('.bin', ''): r
                for r in csv.DictReader(f, delimiter='\t')}


def codewords(vid):
    with open(os.path.join(VECDIR, vid + '.bin'), 'rb') as f:
        raw = f.read()
    return list(struct.unpack('<%dh' % (len(raw) // 2), raw))


def cyclic_find(hay, needle):
    """Is `needle` a contiguous run of `hay` treated as a loop? -> offset or -1.

    The waveform repeats, so the honest test is against hay+hay rather than hay.
    Anything longer than hay itself cannot be a single contiguous run.
    """
    if not needle:
        return -1
    if len(needle) > len(hay):
        return -1
    return (hay + hay).find(needle)


def analyse(got, want):
    """Compare a capture against the transmitted payload, tolerating CLIPPED frames.

    A capture of a continuously busy line begins and ends wherever the trigger and
    the buffer end put it, so the FIRST and LAST frames can be sliced through the
    middle. Those are not decode errors and must not be counted as any -- but an
    error in the interior is a real one, so the position matters and a bare count
    would throw exactly the information needed to tell them apart.

    Returns (offset, longest_clean_run, bad_positions, interior_bad).
    """
    frames = [got[i:i + 2] for i in range(0, len(got), 2)]
    bad = [i for i, f in enumerate(frames) if f == '??']
    interior = [i for i in bad if i != 0 and i != len(frames) - 1]
    runs, cur = [], []
    for i, f in enumerate(frames):
        if f == '??':
            if cur:
                runs.append(cur)
            cur = []
        else:
            cur.append(f)
    if cur:
        runs.append(cur)
    best = max(runs, key=len) if runs else []
    gb = bytes(int(x, 16) for x in best)
    return cyclic_find(want, gb), len(best), bad, interior


def parse_point(lines):
    res, byts = None, []
    for ln in lines:
        f = ln.split()
        if not f:
            continue
        if f[0] == 'B' and len(f) == 2:
            byts.append(f[1])
        elif f[0] == 'P' and len(f) > 1 and f[1] == 'ok':
            res = dict(acq_fs=float(f[2]), nread=int(f[3]), baud=float(f[4]),
                       nf=int(f[5]), ngood=int(f[6]), nbad=int(f[7]),
                       tacq=float(f[8]), tdec=float(f[9]), ec=int(f[10]),
                       trig=f[11], framebits=int(f[12]),
                       vmin=f[13], vmax=f[14])
        elif f[0] == 'P' and f[1:] != ['end'] and res is None:
            # 'P end' is the terminator, not a result -- letting it through here
            # overwrote the real reason with the word "end".
            res = dict(fail=' '.join(f[1:]))
    return res, ''.join(byts)


def run_point(d, baud, fs, trig, lock, timeout=180, raw=False, fmt=False):
    d.drain()
    d.send('bench_point(%d, %d, %r, %s, %s)'
           % (baud, fs, trig, 'true' if lock else 'false',
              'true' if fmt else 'false'))
    lines = []
    while True:
        ln = d.line(timeout)
        if ln is None:
            lines.append('P timeout')
            break
        lines.append(ln)
        if raw and not ln.startswith('B '):
            print('    raw| %s' % ln)
        if ln == 'P end':
            break
    return parse_point(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vectors', default=','.join(SWEEP),
                    help='comma-separated vector ids from out/vectors')
    ap.add_argument('--trig', default='edge', choices=['edge', 'free'])
    ap.add_argument('--rate', default='baud', choices=['baud', 'burst'],
                    help="'baud' is fs_for_baud (8 sa/bit, what FRAME mode picks); "
                         "'burst' is fs_for_burst (4 sa/bit, longest window)")
    ap.add_argument('--auto', action='store_true',
                    help='do NOT lock the baud rate -- exercise auto-detect')
    ap.add_argument('--settle', type=float, default=0.4,
                    help='seconds after the SDG starts playing before capturing')
    ap.add_argument('--repeat', type=int, default=1,
                    help='captures per vector; >1 shows capture-to-capture spread')
    ap.add_argument('--reuse', action='store_true',
                    help='select waveforms already on the generator instead of '
                         'uploading them. Repeated 170-210 kB uploads WEDGE the '
                         'SDG (see siglent.write_raw); use this after the first '
                         'run of a power cycle has put the vectors up.')
    ap.add_argument('--fmt8n1', action='store_true',
                    help='force 8N1 non-inverted, bypassing the format search')
    ap.add_argument('--poldiag', action='store_true',
                    help='report idle level straight off the samples')
    ap.add_argument('--trigdiag', action='store_true',
                    help='exercise the armed-capture path in isolation')
    ap.add_argument('--diag', action='store_true',
                    help='step through acquire() stage by stage on one vector')
    ap.add_argument('--raw', action='store_true',
                    help='echo every non-byte line the instrument prints')
    ap.add_argument('--no-output-off', action='store_true',
                    help='leave the SDG driving at the end')
    a = ap.parse_args()

    man = manifest()
    vids = [v.strip() for v in a.vectors.split(',') if v.strip()]
    for v in vids:
        if v not in man:
            print('unknown vector %r -- have %s' % (v, ','.join(sorted(man))))
            return 2

    sdg = SDG()
    print(sdg.idn())
    d = DMM()
    print(d.q('print(localnode.model, localnode.version)'))
    rows = []
    try:
        load_modules(d, ['tsp/serial_core.tsp', 'tsp/uart_decode.tsp'])
        print()
        for v in vids:
            m = man[v]
            baud = int(m['baud'])
            srate = float(m['srate_sa_s'])
            amp = float(m['amp_vpp'])
            want = bytes(int(x, 16) for x in m['exp_hex'].split())

            if a.reuse:
                print('%s: SELECTING already-uploaded waveform at %g Sa/s, '
                      '%s Vpp, %d baud %s, %d expected bytes'
                      % (v, srate, amp, baud, m['exp_fmt'], len(want)))
                sdg.select_arb(v, amp, srate, offset_v=float(m['ofst_v']), ch=1)
            else:
                cw = codewords(v)
                print('%s: %d pts at %g Sa/s, %s Vpp, %d baud %s, %d expected '
                      'bytes' % (v, len(cw), srate, amp, baud, m['exp_fmt'],
                                 len(want)))
                sdg.upload_arb(v, cw, amp, srate,
                               offset_v=float(m['ofst_v']), ch=1)
            sdg.output(True, ch=1, load='HZ')
            time.sleep(a.settle)

            fsl = d.q('bench_rates(%d)' % baud)
            print('  app rate choice: %s   (FS baud fs_for_baud fs_for_burst '
                  'minsabit)' % fsl)
            fld = fsl.split()
            pick = fld[3] if a.rate == 'burst' else fld[2]
            if pick == 'nil':           # fs_for_burst refuses above ~115200
                pick = fld[2]
            fs = int(float(pick))

            if a.poldiag:
                d.drain()
                d.send('pol_diag(%d, %d)' % (baud, fs))
                while True:
                    ln = d.line(180)
                    if ln is None or ln == 'P end':
                        break
                    print('  ' + ln)
                continue

            if a.trigdiag:
                d.drain()
                d.send('trig_diag(%d, 1.63, false)' % 100000)
                while True:
                    ln = d.line(180)
                    if ln is None or ln == 'P end':
                        break
                    print('  ' + ln)
                continue

            if a.diag:
                d.drain()
                d.send('bench_diag(%d, %d)' % (baud, fs))
                while True:
                    ln = d.line(180)
                    if ln is None or ln == 'P end':
                        break
                    print('  ' + ln)
                continue

            for k in range(a.repeat):
                res, got = run_point(d, baud, fs, a.trig, not a.auto,
                                     raw=a.raw, fmt=a.fmt8n1)
                if res is None or 'fail' in res:
                    print('  FAILED: %s' % (res or {}).get('fail', 'no result'))
                    rows.append(dict(v=v, baud=baud, fs=fs, fail=True,
                                     why=(res or {}).get('fail', '?')))
                    continue
                off, runlen, bad, interior = analyse(got, want)
                clean = not interior
                res.update(v=v, baud=baud, fs=fs, off=off, clean=clean,
                           nbytes=len(got) // 2, runlen=runlen,
                           bad=bad, interior=interior, fail=False)
                rows.append(res)
                print('  acq_fs %10.1f  sa/bit %5.2f  baud %8.0f  bytes %4d '
                      'bad %3d  acq %6.3f s  dec %6.3f s  %s'
                      % (res['acq_fs'], res['acq_fs'] / baud, res['baud'],
                         res['nf'], res['nbad'], res['tacq'], res['tdec'],
                         'MATCH %d/%d @%d' % (runlen, res['nf'], off)
                         if off >= 0 else 'MISMATCH'))
                if bad:
                    print('    bad frames at %s of %d%s' %
                          (bad[:8], res['nf'],
                           '' if not interior else
                           '  <-- %d INTERIOR, not clipping' % len(interior)))
                if off < 0 and got:
                    print('    got   %s' % got[:96])
                    print('    want  %s' % want.hex().upper()[:96])
                else:
                    txt = bytes(want[(off + i) % len(want)]
                                for i in range(min(runlen, 60)))
                    print('    text  %r' % txt.decode('latin-1'))
                if res['trig'] != a.trig:
                    print('    NOTE: trigmode fell back to %r' % res['trig'])
                if res['ec']:
                    print('    event log: %s' % d.q('print(eventlog.next())'))
    finally:
        if not a.no_output_off:
            try:
                sdg.output(False, ch=1)
            except Exception:
                pass
        sdg.close()
        try:
            d.q('trigger.model.abort() print("__OK__")', timeout=20)
        finally:
            d.close()

    # ---------------- the table ----------------
    print('\n%-5s %7s %8s %7s %8s %6s %5s %8s %8s %9s %s'
          % ('vec', 'baud', 'fs', 'sa/bit', 'det.baud', 'bytes', 'bad',
             'acq s', 'dec s', 'wire B/s', 'payload'))
    print('-' * 104)
    for r in rows:
        if r.get('fail'):
            print('%-5s %7d %8d  FAILED: %s' % (r['v'], r['baud'], r['fs'],
                                                r['why']))
            continue
        # Bytes per second the LINE was carrying, versus how long the instrument
        # took to hand them over. The ratio is the duty cycle the design predicts.
        wire = r['baud'] / (r['framebits'] + 0.0)
        print('%-5s %7d %8d %7.2f %8.0f %6d %5d %8.3f %8.3f %9.1f %s'
              % (r['v'], r['baud'], r['fs'], r['acq_fs'] / r['baud'],
                 r['baud'], r['nf'], r['nbad'], r['tacq'], r['tdec'], wire,
                 'match @%d' % r['off'] if r['off'] >= 0 else
                 ('MISMATCH' if r['clean'] else 'FRAMING ERRORS')))

    ok = [r for r in rows if not r.get('fail')]
    good = [r for r in ok if r.get('off', -1) >= 0]
    print('\n%d/%d captures decoded, %d/%d byte-exact against the manifest'
          % (len(ok), len(rows), len(good), len(rows)))
    if ok:
        print('duty cycle (capture seconds / total seconds), per capture:')
        for r in ok:
            span = r['nread'] / r['acq_fs']
            tot = r['tacq'] + r['tdec']
            print('  %-5s %7d baud: %8.4f s of signal in %7.3f s  '
                  '-> duty %.4f, %6.1f decoded B/s'
                  % (r['v'], r['baud'], span, tot, span / tot,
                     r['nf'] / tot if tot > 0 else 0))
    return 0 if len(good) == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())

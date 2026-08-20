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

  correctness   judge_payload: EVERY run of bytes the decoder stood behind must be
                byte-exact against the transmitted payload at ONE agreed alignment,
                and the count of frames it declined must stay inside a budget.
                Cyclic, because a TrueArb waveform LOOPS -- the window lands
                wherever it lands and may straddle the wrap -- and the payload may
                be SHORTER than the window, so it can span more than one period.
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
import math
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I
from dmmrun import DMM
from siglent import SDG
import vector_names as VN                                     # noqa: E402

VECDIR = 'out/vectors'

# The sweep. These five vectors are the 1024-byte lorem stream, which is the only
# payload long enough that a capture window is a substring rather than the whole
# thing -- i.e. the only one that measures YIELD rather than just correctness.
# v71/72/73 are deliberately the same file at three sample rates, so if baud
# detection tracked the file instead of the playback rate it would show up as
# three identical answers.
# ONE FILE, FIVE PLAYBACK RATES, written as vid@baud. This used to be five separate vectors -- v75, v71,
# v72, v73, v74 -- and three of those were BYTE-IDENTICAL, which was the point: if detection tracked the
# file instead of the playback rate, the identical ones would give identical answers. The experiment is
# unchanged and now needs one waveform, because the rate comes from srate at selection time.
#
# It also has to be this way: v72-v75 were retired in the 2026-08-19 rename as duplicate renders and are
# not on the instrument. And selecting a 213 kB arb costs ~1 s of flash-to-FPGA copy against ~0.01 s to
# change srate (tools/instruments.py), so re-selecting per rate was paying for nothing.
SWEEP = ['v71@1200', 'v71@9600', 'v71@19200', 'v71@57600', 'v71@115200']

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
    """Is `needle` a contiguous run of `hay` treated as a loop? -> offset into hay, or -1.

    ENOUGH COPIES FOR THE NEEDLE, not two. This used to test against hay+hay and reject any
    needle longer than hay outright, on the reasoning that "anything longer than hay itself
    cannot be a single contiguous run". That is false for a LOOPING waveform: a 234-byte capture
    off a 133-byte arb is one contiguous run spanning 1.76 periods.

    The cost was a wrong verdict on a correct capture. Measured 2026-08-19 with v77/v78 (133-byte
    payload, ~234-byte window): a window starting at offset k spans k..k+234, so it only fits in
    hay+hay when k <= 32 -- only 33 of 133 start offsets, 25 %. The other 75 % were reported
    MISMATCH having decoded byte-perfectly, v78 with zero bad frames.

    The old form was safe only because every payload had been LONGER than a capture. It broke the
    moment a short vector was added, which is worth remembering: this assumption was invisible
    until the data changed.
    """
    if not needle or not hay:
        return -1
    reps = len(needle) // len(hay) + 2
    return (hay * reps).find(needle)


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


# Judging thresholds for judge_payload(). A run shorter than MINVAL matches a 1 kB payload by
# chance often enough to prove nothing, so it is neither validated nor counted as coverage.
JP_MINVAL = 4
JP_FLAG_FRAC = 0.02      # flag budget, as a fraction of the capture...
JP_FLAG_FLOOR = 2        # ...or this many, whichever is kinder
JP_COVER_MIN = 0.90      # how much of the capture must be positively verified byte-exact
# Boundary frames are NOT judged, because they cannot be. uart_decode.tsp says a gapless stream
# "RESYNCHRONISES a few frames in"; measured 2026-08-19, a v41 capture opened
# '?? ?? ?? ?? DD 3B ?? ?? 76 C8' then repeated 'Hello, World!' byte-exact. DD 3B and 76 C8 are
# unflagged resync debris contiguous with good data, so a run-based check condemns the whole run.
# A wrong byte three frames in is indistinguishable from debris; one at frame 40 is not. Keep this
# small and never raise it to silence a failure.
JP_HEADSKIP = 12
JP_TAILSKIP = 1          # the buffer end slices the last frame the same way
# The smallest body the short-capture test can still accept. head_damage clamps to it, so a TRIM can
# never be why a capture is called too short -- that verdict must mean the capture really was short.
JP_MINBODY = JP_HEADSKIP + JP_TAILSKIP + JP_MINVAL * 2
# How much of the capture must reach the judge. JP_COVER_MIN is measured against the body that survived
# trimming, so a big trim shrinks the denominator and 90 % becomes trivial: measured 2026-08-19, a point
# validated 61 of 236 bytes and reported ok. Half is generous -- an honest head plus tail is ~13 of ~180
# -- so this fires only when the trim has gone wrong.
JP_BODY_FRAC = 0.5


def head_damage(hexs, headsusp):
    """How far a misaligned head ACTUALLY reaches: the last unrecoverable frame inside headsusp.

    WHY THIS EXISTS, AND WHY TRIMMING BY headsusp WAS WRONG. Every caller used to slice
    `hexs[2 * headsusp:]` before judging. But headsusp is the region BEFORE THE FIRST IDLE GAP, not a
    count of damage -- uart_decode.tsp:506 says so in as many words: "headsusp itself is the region
    before the first gap, not a count of damage, so quoting it over-claims." The app learned this in
    session 19b, when the panel printed 'the first 4 bytes are misaligned' beside ERR 1, and
    sdec.ua_head_bad() was added as the ONE place that narrows headsusp to the frames actually hurt.
    The panel got that correction. The bench judge did not, and kept trimming by the raw region.

    WHAT THAT COST, measured on the 2026-08-19 soak: five laps of 55 failed as
    'capture too short to judge (1 B, 0 judged) after a FLAGGED 226-byte head' on lorem at 115200 and
    250000. The decode was CORRECT in every one of them -- the surviving hex reads 4C6F72656D20697073
    756D20646F6C6F722073, "Lorem ipsum dolor s" -- and the app's own note said only 3 to 5 bytes were
    misaligned. The judge had thrown away 226 of 230 good bytes and then failed the point for being
    too short. A harness that invents failures is worse than no harness, because it spends the next
    morning being investigated.
    (v71 is gapless, so its first idle gap is the arb LOOP SEAM ~1024 bytes away and headsusp can be
    the whole capture; v80 loops every 13 bytes, so its headsusp is bounded. That is the entire reason
    the same baud rate passed on one vector and failed on the other.)

    COMPUTED HOST-SIDE rather than read from the instrument, deliberately: ua_head_bad's definition is
    "the last flagged frame at or before headsusp", and an unrecoverable frame is already reported as
    '??' in the hex dump. So the figure is derivable from what the bench already has, and no app
    change or reload is needed to fix a harness defect.

    THE ONE WAY THIS DIFFERS FROM ua_head_bad, stated because it matters: a frame can be FLAGGED and
    still carry a value -- a parity error, say -- and such a frame prints its hex rather than '??'.
    So this can under-count relative to the instrument's own figure. It is still strictly closer than
    headsusp, which over-counts by up to the whole capture, and under-trimming is the safe direction:
    a damaged byte left inside the body is judged and can fail the point, whereas an over-trim
    silently discards good evidence. -> int, 0 if nothing in the head is unrecoverable.

    THE RULE THAT PREDICTS THE WHOLE FAILURE CLASS, measured over a 4732-capture factorial:
    **a point is exposed iff len(payload) > nf**, i.e. iff the payload is longer than one capture.
    Once a capture spans more than one arb period it always contains an EARLY seam, and idle1 records
    only the first, so headsusp can never be late. The cleanest demonstration holds content, gap and
    rendering all fixed and varies only the capture length: r00 (256 B) at 115200 has nf ~= 227 and
    fails 12 of 256 start offsets; the SAME vector at 250000 has nf ~= 494 and fails 0 of 256.
    Grid: hello 13 B 0/13, v77 133 B 0/133, r00 256 B 12/256 at 115200 and 0/256 at 250000,
    v71 1024 B 10/512 at both rates. So v77/v78 are structurally immune at any rate, and the RANDOM
    vectors are where high-rate coverage actually lands.

    AND WHY 'JUST DO NOT TRIM' IS NOT THE ANSWER, since it is the obvious alternative: real damage
    reaches 35 frames on v77, past JP_HEADSKIP's 12. Over the same factorial, trimming by headsusp
    fails 88, trimming by nothing fails 194, trimming by this function fails 6. Removing the trim
    would have traded one false-failure class for a bigger one.
    (The 6 residuals are a separate defect -- see task #59, a pre-trim flag count against a post-trim
    budget in judge_payload -- and are not reachable while the shipped vectors use gap = 0.)
    """
    if not headsusp or headsusp < 1:
        return 0
    frames = [hexs[i:i + 2] for i in range(0, len(hexs), 2)]
    last = 0
    for i in range(min(headsusp, len(frames))):
        if frames[i] == '??':
            last = i + 1
    # CLAMPED, so our own allowance can never produce 'capture too short to judge'. ua_head_bad reached
    # 31 on v77 and 27 on v78 in the 2026-08-19 logs, and v77 now runs at 115200/250000 where captures
    # are shorter. If damage really reaches that far the surviving bytes fail on CONTENT instead, which
    # names the payload and is honest.
    return min(last, max(0, len(frames) - JP_MINBODY))


def runs_of(frames):
    """Every maximal run of non-flagged frames, as (start_index, [frames])."""
    out, cur, start = [], [], 0
    for i, f in enumerate(frames):
        if f == '??':
            if cur:
                out.append((start, cur))
            cur, start = [], i + 1
        else:
            if not cur:
                start = i
            cur.append(f)
    if cur:
        out.append((start, cur))
    return out


def judge_payload(got, want):
    """Judge a capture of a LOOPING payload. -> (ok, detail).

    REPLACES the `longest_clean_run/body >= 0.95` test for the long-payload suites, which had two
    independent faults. It is STRICTER than what it replaces, not laxer -- see tools/test_lorem_gate.py,
    which holds the cases proving both.

    1. The old gate was a fragile ORDER STATISTIC. With k bytes flagged the score depended on WHERE
       they landed, not how many: for a single flag at index p in 239 frames the runs are p and
       238-p, so it needed p <= 10 or p >= 228 -- only 22 of 239 positions (9.2 %) could pass. One
       honestly-flagged byte more than ten from an edge failed the point outright. Measured across
       143 recorded lorem points: the longest run was byte-exact 141 of 141 times it was reported,
       yet 1.4 % of points fell below the gate. Those verdicts described flag position, not
       correctness. Here the signal-quality test is a COUNT, which does not move when a flag does.
    2. analyse() validates ONLY the longest run, so a wrong byte in a shorter run was invisible.
       Here EVERY run long enough to be diagnostic is checked.

    ONE alignment is established for the whole capture and every run is checked at the position it
    predicts -- NOT by searching for each run independently. A 4-8 byte run of prose really does
    occur more than once in 1 kB, so a per-run find() lands on the wrong copy and fakes a
    misalignment. All candidate anchor positions are tried before a capture is called wrong.
    """
    frames = [got[i:i + 2] for i in range(0, len(got), 2)]
    body = len(frames)
    if not body:
        return False, 'no bytes decoded'
    # Judge only the interior. The head allowance is resync debris (see JP_HEADSKIP); trimming it
    # from the FRAMES means a run that straddles the boundary is cut, not condemned whole.
    captured = body                       # frames handed in, before any of our own exclusions
    lo = JP_HEADSKIP
    hi = body - JP_TAILSKIP
    if hi - lo < JP_MINVAL * 2:
        return False, 'capture too short to judge (%d B, %d judged)' % (body, max(0, hi - lo))
    frames = frames[lo:hi]
    body = len(frames)
    # COUNTED ON THE TRIMMED FRAMES. This used to count the untrimmed ones against a budget sized on the
    # trimmed body -- a double penalty, since a flag inside JP_HEADSKIP is excluded from the correctness
    # test above yet still spent budget. It explained every residual failure that survived the headsusp
    # fix across a 4732-capture factorial. Both quantities now come from one list.
    bad = [i for i, f in enumerate(frames) if f == '??']
    interior = [i for i in bad if i != 0 and i != body - 1]
    rr = runs_of(frames)
    # ENOUGH COPIES, for the same reason as cyclic_find: a capture off a SHORT looping payload can
    # be longer than the payload, and a run is checked at (alignment + start) % len(want), so the
    # haystack must reach len(want) + body. Two copies silently truncated the slice compare and
    # reported a byte-perfect capture as silently wrong.
    hay = want * (body // len(want) + 2)

    diag = [(s, f) for s, f in rr if len(f) >= JP_MINVAL]
    if not diag:
        return False, 'nothing long enough to validate (%d B in runs under %d)' % (body, JP_MINVAL)
    try:
        asbytes = [(s, bytes(int(x, 16) for x in f)) for s, f in rr]
    except ValueError:
        return False, 'capture is not hex'
    anchor_start, anchor = max(diag, key=lambda r: len(r[1]))
    anchor_b = bytes(int(x, 16) for x in anchor)

    cands, at = [], hay.find(anchor_b)
    while 0 <= at < len(want):
        cands.append((at - anchor_start) % len(want))
        at = hay.find(anchor_b, at + 1)
    if not cands:
        return False, ('run of %d B at index %d is NOT in the payload -- silently wrong'
                       % (len(anchor_b), anchor_start))

    align, verified, whynot = None, 0, ''
    for cand in cands:
        v, ok_all = 0, True
        for start, gb in asbytes:
            if len(gb) < JP_MINVAL:
                continue                 # too short to prove anything either way
            exp = (cand + start) % len(want)
            if hay[exp:exp + len(gb)] != gb:
                ok_all = False
                whynot = ('run of %d B at index %d does not match the payload at the alignment the '
                          'rest of the capture agrees on -- silently wrong' % (len(gb), start))
                break
            v += len(gb)
        if ok_all:
            align, verified = cand, v
            break
    if align is None:
        return False, whynot

    budget = max(JP_FLAG_FLOOR, int(math.ceil(JP_FLAG_FRAC * body)))
    if len(interior) > budget:
        return False, '%d interior flagged, budget %d' % (len(interior), budget)
    cover = float(verified) / body
    if cover < JP_COVER_MIN:
        return False, ('only %.1f %% positively verified (need %.0f %%)'
                       % (100 * cover, 100 * JP_COVER_MIN))
    # AND HOW MUCH OF THE CAPTURE REACHED THE JUDGE. cover above is relative to what survived our own
    # exclusions, so a big trim makes it easy to satisfy. head_damage and the JP_MINBODY clamp make that
    # hard to reach now, but nothing STATED the loss, so it was invisible in a passing line. It is in the
    # pass message too: a number nobody prints is a number nobody checks.
    if body < JP_BODY_FRAC * captured:
        return False, ('only %d of %d captured B reached the judge (need %.0f %%) -- the head '
                       'allowance is discarding the capture'
                       % (body, captured, 100 * JP_BODY_FRAC))
    return True, ('%d of %d B verified byte-exact at offset %d (%d flagged, budget %d, '
                  'head %d skipped, %d of %d captured judged)'
                  % (verified, body, align, len(interior), budget, lo, body, captured))


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
        for spec in vids:
            # vid@baud overrides the manifest's rate, keeping the vector's OWN points-per-bit so the
            # rendered fidelity is unchanged -- only the playback clock moves.
            v, _, at = spec.partition('@')
            m = man[v]
            if at:
                spb = float(m['srate_sa_s']) / float(m['baud'])
                baud = int(at)
                srate = baud * spb
            else:
                baud = int(m['baud'])
                srate = float(m['srate_sa_s'])
            amp = float(m['amp_vpp'])
            want = bytes(int(x, 16) for x in m['exp_hex'].split())

            if a.reuse:
                print('%s: SELECTING already-uploaded waveform at %g Sa/s, '
                      '%s Vpp, %d baud %s, %d expected bytes'
                      % (v, srate, amp, baud, m['exp_fmt'], len(want)))
                sdg.select_arb(VN.arb(v), amp, srate, offset_v=float(m['ofst_v']), ch=1)
            else:
                cw = codewords(v)
                print('%s: %d pts at %g Sa/s, %s Vpp, %d baud %s, %d expected '
                      'bytes' % (v, len(cw), srate, amp, baud, m['exp_fmt'],
                                 len(want)))
                sdg.upload_arb(VN.arb(v), cw, amp, srate,
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
                # THE LONGEST-RUN MATCH IS NOT THE VERDICT, only a diagnostic. analyse() takes the
                # longest unflagged run and searches for it whole, so ONE unflagged junk byte next to
                # a flagged head poisons the run and the whole capture reads MISMATCH. Measured
                # 2026-08-19: v41 captures whose bytes were '??FE' then 'Hello, World!' repeating
                # byte-exact were reported MISMATCH on that basis alone.
                #
                # judge_payload decides instead: every diagnostic run checked at one agreed alignment,
                # and the FLAG COUNT bounded rather than the run length. Same rule the long-payload
                # suite in bench_matrix uses, and it is stricter, not laxer -- it also catches a wrong
                # byte inside a short run, and a decode that lost and regained sync mid-capture.
                jok, jdet = judge_payload(got, want)
                clean = not interior
                res.update(v=v, baud=baud, fs=fs, off=off, clean=clean,
                           nbytes=len(got) // 2, runlen=runlen, jok=jok, jdet=jdet,
                           bad=bad, interior=interior, fail=False)
                rows.append(res)
                print('  acq_fs %10.1f  sa/bit %5.2f  baud %8.0f  bytes %4d '
                      'bad %3d  acq %6.3f s  dec %6.3f s  %s'
                      % (res['acq_fs'], res['acq_fs'] / baud, res['baud'],
                         res['nf'], res['nbad'], res['tacq'], res['tdec'],
                         ('OK  ' + jdet) if jok else ('BAD  ' + jdet)))
                if bad:
                    print('    bad frames at %s of %d%s' %
                          (bad[:8], res['nf'],
                           '' if not interior else
                           '  <-- %d INTERIOR, not clipping' % len(interior)))
                if not jok and got:
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
                 # The judge's verdict, not the longest-run search's -- see judge_payload at the
                 # capture site. 'flagged N' is how many frames the DECODER declined to stand
                 # behind, which is honest uncertainty and not a failure on its own.
                 ('ok' if r.get('jok') else 'BAD') +
                 ('' if not r['bad'] else '  flagged %d' % len(r['bad']))))

    ok = [r for r in rows if not r.get('fail')]
    good = [r for r in ok if r.get('jok')]
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

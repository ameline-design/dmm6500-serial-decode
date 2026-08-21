#!/usr/bin/env python3
"""RUN THE BENCH SUITES FOR HOURS AND COUNT WHAT FAILS, per point. The tool for intermittents.

A release sweep answers "does it pass?" once. That is the wrong question for a point that fails one
run in ten: a single green sweep licenses a defect, and a single red one reads as a regression that
cannot be reproduced. This runs the same suites over and over and reports a FAILURE RATE per point,
which is the number an intermittent actually has.

WHAT PROVOKED IT: the 22:38 sweep failed one point of 43 -- v44d, an 8O1 stream detected as 19200 Bd
when the wire was 9600, a 2x rate misfit that then read the format as 7N1 with 41 bad frames. Three
immediate re-runs of the same point were byte-exact. So the question is not "is it broken" but "how
often, and does it always announce itself".

HOW IT KEEPS ITSELF HONEST:

  * IT REUSES THE APP ALREADY ON THE PANEL and never builds one. sdec.start() cannot build twice in a
    power cycle, so a soak that tried would die on its second iteration -- every child runs with
    --no-start / --reuse.
  * IT NEVER UPLOADS A WAVEFORM. Large WVDT writes wedge the SDG2122X after about two per power
    cycle (see tools/instruments.py); selecting a stored arb never does, and since the baud rate
    comes from the sample rate, selecting is all a rate sweep needs. The suites here only select.
  * IT KEEPS THE EVIDENCE FOR EVERY FAILURE. A run with a BAD point has its whole output saved, so the
    app's own notes -- rival formats, probe misfits, flagged heads -- are there in the morning. A
    frequency with no cause attached is only half an answer.
  * IT STOPS IF THE INSTRUMENT STOPS ANSWERING, rather than hammering a wedged meter until dawn.

    python3 tools/soak.py --hours 8
    python3 tools/soak.py --hours 1 --suites formats        # just the format arbitration
    python3 tools/soak.py --hours 8 --record-every 10       # add a one-press recording every 10th lap
    python3 tools/soak.py --selftest                        # replay a saved lap; no instrument at all
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_sync as BS  # noqa: E402
import vector_names as VN                                     # noqa: E402
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# THE SUMMARY BLOCK IS THE AUTHORITY ON WHICH POINTS EXIST, and these four patterns bracket it.
# bench_matrix ends every run with (bench_matrix.py:744-751):
#
#     POINT                             RESULT
#     ------------------------------------------------------------------------------------------------
#     format v44e                  BAD  7N1 153 B (head 0), longest clean run 9, 35 bad (35 interior)
#     <blank>
#     16 of 17 points fully correct
#     events: 0 x 4915, 0 other, over 17 points
#
# -- a header, a rule, one row per point starting at COLUMN 0, then a blank line. Anchoring on that
# structure is what keeps a BODY line out, and the body is not a hypothetical hazard: the rates suite
# prints '  300 Bd  ok  8N1 ...' per point as it goes (bench_matrix.py:342), which is indented but
# otherwise the same shape. A parser that reads the whole output instead produces 28 keys where the
# summary counts 17, '300 Bd' sitting beside 'rate 300' for all eleven rates -- so the count test
# below fires on EVERY lap, clean ones included, and a run of these two suites tallies nothing.
HEAD = re.compile(r'^POINT\s+RESULT\s*$')
RULE = re.compile(r'^-{20,}\s*$')
# The name can itself contain spaces -- 'offset 3.3V +0.20V' (bench_matrix.py:516) is three words -- so
# it runs up to the first STANDALONE verdict token instead of being a fixed two words. A two-word
# pattern matches none of the offsets suite's rows at all, which makes every lap of --suites offsets
# incomplete for the opposite reason: too few points, not too many.
ROW = re.compile(r'^(\S.*?)\s+(ok|BAD|skip)\s*(.*?)\s*$')
FINAL = re.compile(r'(\d+) of (\d+) points fully correct')

# A recording press, driven exactly as the panel would: one press, whole job. Timed on the HOST,
# because the instrument's single timer is reset inside the app at the end of a recording (see
# bench_panel.py) and would report milliseconds for a minute of work.
#
# IT LOCKS THE RATE FIRST, WITH A FRAME CAPTURE, exactly as an operator's first press does. A streaming
# mode REFUSES outright without a locked baud rate -- 'lock the baud rate in Options -- streaming picks
# the sample rate from it' -- and bench_matrix leaves force_baud nil (suite_hard's teardown clears the
# pin). Without it a recording lap returns `nil` bytes in 0.02 s -- a silent no-op that reads as a
# recording having happened. The frame capture is not scaffolding: it is
# the documented workflow, press Capture, then Mode, then Capture.
RECORD_TSP = r'''
function sk_record(cap)
  eventlog.clear()
  -- AUTO-DETECT AND AUTO-LOCK, WHICH MEANS nil AND NOT 0. force_baud = 0 is the OPTIONS FIELD's way of
  -- saying "re-detect" -- options_apply() turns it into nil -- but internally `force_baud ~= nil` is the
  -- test for "already locked" (serial_app.tsp:1461), so setting 0 here made autolock skip and the
  -- capture came back with baud nil after 25 s of trying. The format pins go too: suite_hard leaves
  -- nbits/par/nstop/invert forced to 8N1, and a detection with the answer pre-supplied is not one.
  sdec.capmode = 'frame'
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  local lok = pcall(function() return sdec.capture() end)
  if not lok or sdec.baud == nil then
    print(string.format('REC false|nil|nolock|false|could not lock a rate to record at (baud=%s)|',
          tostring(sdec.baud)))
    return
  end
  eventlog.clear()
  sdec.capmode = cap
  sdec.strm_stopped_by_press = nil
  local ok = pcall(function() return sdec.capture() end)
  local ec, emsg = eventlog.getcount(), ''
  local i
  for i = 1, ec do
    local n, m = eventlog.next()
    if m ~= nil then emsg = emsg .. string.format('[%s %s]', tostring(n), tostring(m)) end
  end
  -- fc_end AND THE BAUD RATE ARE PART OF THE RECORD. Without the rate a byte count cannot be judged
  -- (8192 bytes is a full window at 9600 and an undersampled mess at 57600); without fc_end a run that
  -- stopped on a bound is indistinguishable from one that ran out of traffic.
  print(string.format('REC %s|%s|%s|%s|%s|%s|%s|%s', tostring(ok),
        tostring(sdec.ck_tot and sdec.ck_tot.nf), tostring(sdec.ck_endwhy),
        tostring(sdec.ck_job ~= nil), tostring(sdec.lasterr), emsg,
        tostring(sdec.baud), tostring(sdec.fc_end)))
  -- HAND THE APP BACK IN THE STATE A FRAME LAP EXPECTS, which a finished recording does NOT do on its
  -- own. Two flags survive it and both make the NEXT Capture press return early instead of capturing:
  -- strm_stopped_by_press (armed by strm_absorb_arm, so the press is eaten as the Stop for the run that
  -- just ended) and any ck_running/ck_stop left latched (the press is read as a stop REQUEST). Either
  -- way the panel keeps the recording's result, and the next lap's first point measures the recording's
  -- 720-byte tail instead of its own vector: MEASURED, v41 filed BAD with 'all 8192 are in bytesNNN.txt'
  -- on the lap after every recording lap.
  --
  -- THE ABSORB IS FOR A FINGER, AND THERE IS NO FINGER HERE. It exists so a press aimed at stopping a
  -- stream is not honoured as a new capture once the run's Lua returns -- a host-driven run has no
  -- queued press to protect, so disarming it is correct rather than merely convenient.
  sdec.strm_stopped_by_press = nil
  sdec.ck_running, sdec.ck_stop = false, false
  sdec.ck_tot, sdec.ck_nbytes, sdec.ck_endwhy = nil, nil, nil
  pcall(function() sdec.clear_result() end)
end
print('===DONE===')
'''


def judge_lap(out, rc, expect=None):
    """Read one child's output. -> ({point: (verdict, detail)}, why_incomplete).

    A LAP THAT DID NOT FINISH IS NOT A LAP THAT PASSED, and `why` is what says so: the tally counts
    per-point failures, so a child that stops partway enters a 'run' for every point it reached and
    none for the points it never got to -- and absence is indistinguishable from success.

    BUT A LAP THAT FAILED A POINT DID FINISH. bench_matrix exits 1 whenever any point is BAD, so
    treating `rc != 0` as incomplete files exactly the laps this tool exists to count as unmeasured,
    drops them from the tally, and reports "0 laps had at least one bad point" while
    lapNNNN-INCOMPLETE.log files pile up beside it. `expect` is taken
    after that test too, so once laps started failing it stayed None forever.

    So completeness is judged on the SUMMARY ALONE, and all three tests are about its self-consistency:
    the 'N of M points fully correct' line is present, M matches the number of rows actually parsed, and
    that count matches what previous laps produced. The exit code is recorded and quoted where it is
    evidence -- when there is no summary -- and never overrides one. A real crash keeps its old verdict
    for free: an unknown suite (bench_matrix.py:677, rc 2), a traceback, and a child killed by a signal
    all print no summary to be consistent with.
    """
    points = {}
    lines = out.splitlines()
    # The LAST such block, so a child that somehow printed twice is read at its end rather than its start.
    at = [i for i in range(len(lines) - 1)
          if HEAD.match(lines[i]) and RULE.match(lines[i + 1])]
    if at:
        for ln in lines[at[-1] + 2:]:
            if not ln.strip() or FINAL.search(ln):
                break
            m = ROW.match(ln)
            if m:
                points[m.group(1).strip()] = (m.group(2), m.group(3).strip())
    # THE COMPLETENESS TESTS, all three of them.
    fin = None
    for m in FINAL.finditer(out):
        fin = m
    why = None
    if fin is None:
        why = ('no "N of N points fully correct" line -- the suite did not reach its summary (exit %d)'
               % rc)
    elif int(fin.group(2)) != len(points):
        why = 'the summary counts %s points but %d were parsed' % (fin.group(2), len(points))
    elif expect is not None and len(points) != expect:
        why = 'produced %d points, previous laps produced %d' % (len(points), expect)
    return points, why


# How much longer than the estimate a lap may take before it is declared hung. 2.0 is a 100 % margin,
# against a floor of 50 %: the estimate is built from a measured per-cell cost, and a lap that needs
# twice it is not slow, it is stuck.
LAP_DEADLINE_MARGIN = 2.0


def run_suite(suites, rates=None, timeout=1200, expect=None, iteration=None, plan_vectors=None,
              skip_vectors='', heartbeat=None, keep_combine=False):
    """One lap of bench_matrix. -> (rc, stdout, {point: (verdict, detail)}, why_incomplete).

    The judging is judge_lap()'s and needs no instrument and no subprocess, which is what makes it
    testable against a saved lap -- see --selftest.

    THE LAP NUMBER IS THE ITERATION, and passing it is what makes a soak vary rather than repeat. The
    plan suite derives its vector order, its drawn rates and every capture wait from it through
    tools/soakplan.py, and the SAME number offline picks the same draws -- so a lap that fails on the
    instrument and passes on the Mac at the same iteration has isolated the difference to hardware.
    """
    argv = ['python3', 'tools/bench_matrix.py', '--suites', suites,
            '--no-start', '--no-output-off']
    if iteration is not None:
        argv += ['--iteration', str(iteration)]
    if plan_vectors is not None:
        argv += ['--plan-vectors', str(plan_vectors)]
    if skip_vectors:
        argv += ['--skip-vectors', skip_vectors]
    if heartbeat:
        argv += ['--heartbeat', heartbeat]
    if keep_combine:
        argv += ['--keep-combine']
    if rates:
        argv += ['--rates', rates]
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    out = p.stdout.decode('utf-8', errors='replace')
    points, why = judge_lap(out, p.returncode, expect)
    return p.returncode, out, points, why


# THE LAP THE CLASSIFICATION WAS FIXED AGAINST: a real child, exit 1, seventeen points, one of them BAD
# -- 'format v44e', an 8N1 vector at 9600 Bd read as 7N1 at 19200 Bd. Both defects are visible in this
# one file, so it is the fixture. out/ is not published (see .gitignore), which is why the path is an
# argument; every check below is about THIS lap, so another log fails on the names rather than passing
# vacuously.
SELFTEST_LOG = os.path.join(ROOT, 'out', 'soak', '2026-08-18T18-45-46', 'lap0001-INCOMPLETE.log')
SELFTEST_POINTS = ['format v41', 'format v44a', 'format v44b', 'format v44c', 'format v44d',
                   'format v44e', 'rate 300', 'rate 600', 'rate 1200', 'rate 2400', 'rate 4800',
                   'rate 9600', 'rate 19200', 'rate 38400', 'rate 57600', 'rate 115200',
                   'rate 250000']


def selftest(path):
    """Replay a saved lap through judge_lap(). -> 0 if every check holds, 1 otherwise.

    NO INSTRUMENT AND NO SUBPROCESS, which is the whole point. The lap classification is what has been
    wrong twice -- a failing lap read as a lap that never ran, and a body line read as a point -- and in
    both cases the tool went on looking busy for hours. A check that needed the bench could only run
    while the bench was free, which is never during the run it exists to protect.
    """
    bad, tot = [], [0]

    def ck(cond, what):
        tot[0] += 1
        print('  %-4s %s' % ('ok' if cond else 'BAD', what))
        if not cond:
            bad.append(what)

    print('--- replaying %s' % path)
    if not os.path.exists(path):
        print('  BAD  no such log -- give one as `--selftest PATH`; out/ is not in the repo')
        return 1
    full = open(path, encoding='utf-8', errors='replace').read()

    # 1. THE REAL LAP AS IT WAS, exit 1 because one of its points was BAD.
    pts, why = judge_lap(full, 1)
    ck(sorted(pts) == sorted(SELFTEST_POINTS),
       '%d points parsed, exactly the seventeen the summary names' % len(pts))
    ck(not [k for k in pts if k.endswith(' Bd')],
       'no rates BODY line among them -- "300 Bd" ... "250000 Bd" are not points')
    ck(pts.get('format v44e', ('?',))[0] == 'BAD', 'format v44e is BAD')
    ck(sum(1 for v in pts.values() if v[0] == 'ok') == 16, 'the other sixteen are ok')
    ck(why is None, 'exit 1 with a self-consistent summary -> COMPLETE, so the lap IS tallied')

    # 2. THE SAME CHILD CUT OFF BEFORE ITS SUMMARY, exit 0. The whole body is still there, eleven
    #    matching rates lines included, so this is also the check that a body line is never taken for
    #    a point: it must yield NOTHING.
    lines = full.splitlines(True)
    cut = [i for i, l in enumerate(lines) if HEAD.match(l.rstrip('\n'))]
    pts2, why2 = judge_lap(''.join(lines[:cut[0]]) if cut else '', 0)
    ck(bool(cut) and not pts2 and why2 is not None,
       'the body alone, exit 0 -> INCOMPLETE, 0 points: %s' % why2)

    # 3. A CHILD THAT REFUSED ITS ARGUMENTS -- bench_matrix.py:677 prints this and returns 2.
    pts3, why3 = judge_lap("unknown suite 'formats2'; have formats, hard, levels, lorem, offsets, "
                           "rates\n", 2)
    ck(not pts3 and why3 is not None and 'exit 2' in why3,
       'exit 2 with no summary -> INCOMPLETE: %s' % why3)

    # 4. THE COUNT DISAGREEING WITH PREVIOUS LAPS, the third completeness test.
    _, why4 = judge_lap(full, 1, expect=16)
    ck(why4 is not None, 'seventeen points where previous laps made sixteen -> INCOMPLETE: %s' % why4)

    # 5. AND A CLEAN LAP IS STILL A CLEAN LAP: the same log with v44e ok and exit 0.
    clean = []
    for l in full.splitlines():
        if l.startswith('format v44e'):
            l = '%-28s %-4s %s' % ('format v44e', 'ok', '8N1 exact 152 B')
        elif FINAL.search(l):
            l = '17 of 17 points fully correct'
        clean.append(l)
    pts5, why5 = judge_lap('\n'.join(clean), 0)
    ck(why5 is None and len(pts5) == 17 and pts5.get('format v44e', ('?',))[0] == 'ok',
       'the same lap with v44e ok, exit 0 -> COMPLETE with 17 points')

    print('SELFTEST %s' % ('OK -- all %d checks hold' % tot[0] if not bad
                           else 'FAILED: %d of %d checks' % (len(bad), tot[0])))
    return 1 if bad else 0


def hold_awake():
    """Stop the host sleeping for the life of this process. -> a note for the log.

    THE ONE FAILURE THAT COST A WHOLE RUN, and it was not the instrument. A 5-hour soak ran 54 laps at
    ~150 s each and then one lap took 19 710 s -- 5.47 HOURS -- and returned nothing. The instrument was
    innocent: `pmset -g log` shows the Mac entered Idle Sleep at 03:43:21, about two minutes into that
    lap, and spent the rest of the night cycling Sleep/DarkWake. The app's own worst case for that job is
    ~21 minutes (strm_maxsec 1200 s plus a decode), which is how the hours were known to be host-side.

    A wall-clock deadline does not fix this -- it would abandon a lap that was never actually stuck -- and
    an overnight soak that silently stops measuring after two hours is worthless in a way that is hard to
    notice, because every lap it DID run looks fine.

    `caffeinate -i -w <pid>` holds an idle-sleep assertion until this process exits, and exits by itself
    if this one dies, so nothing is left pinning the machine awake. A DISPLAY sleep is fine and is left
    alone; it is idle SYSTEM sleep that suspends the interpreter.
    """
    if sys.platform != 'darwin':
        return 'no sleep guard on %s -- make sure the host cannot suspend' % sys.platform
    try:
        subprocess.Popen(['caffeinate', '-i', '-w', str(os.getpid())])
        return 'holding an idle-sleep assertion (caffeinate -i) for the life of this run'
    except Exception as e:
        return 'COULD NOT HOLD THE HOST AWAKE (%s) -- a suspend will silently stop measuring' % e


def record_wire(g):
    """Put a KNOWN line on the wire for a recording lap. -> a label for the record.

    bench_matrix leaves the generator wherever its last point put it -- the hard suite's last selection
    is v92 at 57600 baud -- and 57600 is precisely the rate a stream cannot sustain (see the streaming
    ceiling in notes/HANDOFF.md). Recording whatever happens to be playing would measure a different
    thing every lap and would sometimes measure the known-bad case, so the lap picks its own line: the
    1024-byte non-repeating lorem vector at 9600 baud, which is the configuration the one-press
    recording was demonstrated on.
    """
    # THE CONVENTIONS COME FROM bench_matrix, not from numbers retyped here. amp_for(3.3) is 10.0 Vpp,
    # not 6.6 -- the vectors' codewords span a fraction of the DAC range, so a swing is not an amplitude,
    # and guessing it wrong would put the wrong voltage on the operator's wire.
    from bench_matrix import amp_for, NOMINAL_SWING, LOREM_ARB, LOREM_SPB
    srate = int(round(9600 * LOREM_SPB))
    g.select_arb(VN.arb(LOREM_ARB), amp_for(NOMINAL_SWING), srate)
    g.output(True, ch=1)
    time.sleep(0.6)
    return '%s@9600' % LOREM_ARB


def record_lap(d, cap, wall_s=1800):
    """One one-press recording. -> dict, or None if the press never returned inside wall_s.

    A HARD HOST DEADLINE, because a per-read timeout is not a bound on the CALL. d.line(t) restarts its
    timeout on every chunk that arrives, so any dribble of output keeps the loop alive indefinitely: one
    lap of a five-hour soak can consume 5.5 h and then return None. Whatever the instrument is doing, a
    recording lap must cost one lap, not the run.

    wall_s is generous on purpose: the job is a frame capture to lock the rate, then a recording, then its
    decode, and under a bound the recording alone may run 20 minutes. It is a hang detector, not a
    latency budget.
    """
    t0 = time.time()
    vol = []                 # unsolicited lines: event messages, errors, anything not ours
    d.drain()
    d.send('sk_record(%r)' % cap)
    while True:
        left = wall_s - (time.time() - t0)
        if left <= 0:
            print('    RECORDING LAP ABANDONED after %.0f s -- no REC line, %d volunteered line(s)'
                  % (time.time() - t0, len(vol)))
            for v in vol[-6:]:
                print('      last: %s' % v[:100])
            return None
        want = min(300, left)
        t1 = time.time()
        ln = d.line(want)
        if ln is None:
            # d.line RETURNS None FOR TWO DIFFERENT THINGS, and they need opposite handling: a read
            # timeout (the instrument is still working -- keep waiting until the WALL deadline, which is
            # the bound that actually holds) and a CLOSED socket (nothing will ever arrive). Telling them
            # apart by how long the read took is crude but exact enough: a closed socket returns at once,
            # a timeout returns after the timeout. Without this the closed case spins on a non-blocking
            # read until wall_s, burning a core for half an hour to reach the same answer.
            if time.time() - t1 < want * 0.5:
                print('    RECORDING LAP: the socket closed after %.0f s' % (time.time() - t0))
                return None
            if time.time() - t0 >= wall_s:
                return None
            continue
        if ln.startswith('REC '):
            f = (ln[4:].split('|') + [''] * 8)[:8]
            return {'ok': f[0] == 'true', 'nf': f[1], 'endwhy': f[2],
                    'job': f[3] == 'true', 'lasterr': f[4], 'events': f[5],
                    'baud': f[6], 'fc_end': f[7], 'volunteered': vol,
                    'secs': round(time.time() - t0, 2)}
        # EVERY OTHER LINE IS EVIDENCE, AND DISCARDING IT WAS THE REAL DEFECT HERE.
        #
        # localnode.showevents is set to SEV_ERROR by bench_matrix and PERSISTS on the instrument, so
        # error-severity events arrive UNSOLICITED on this socket -- verified: posting one yields
        # '1005, User: ...' with nothing having asked for it. This loop read those lines, saw they were
        # not 'REC ', and waited again -- restarting its read timeout each time. One lap therefore ran
        # 19 710 s (5.5 h) and then returned None, and the lines that said WHY were thrown away.
        #
        # The wall deadline above now bounds the damage; keeping the lines is what makes the next
        # occurrence diagnosable instead of merely survivable.
        vol.append(ln)
        if len(vol) <= 6:
            print('    instrument volunteered: %s' % ln[:100])
        elif len(vol) == 7:
            print('    (further volunteered lines kept but not printed)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hours', type=float, default=8.0)
    # A LAP BOUND AS WELL AS A CLOCK, for the "did we break anything obvious" run. Expressing N laps as
    # hours is a guess -- a lap is ~294 s measured over 89 of them, but that is the CURRENT suite set --
    # and guessing low silently measures less than asked. Whichever bound is reached first wins, so
    # --hours still protects an over-running lap. Counts ATTEMPTS, so a timed-out lap spends one.
    ap.add_argument('--laps', type=int, default=None,
                    help='stop after this many laps (default: run until --hours)')
    # payloads included by default: it is the only suite where each lap's fourteen points are
    # fourteen DIFFERENT payloads covering every byte value 0-255, so a long run accumulates
    # pattern coverage instead of just repeating one stimulus.
    ap.add_argument('--suites', default='formats,rates,lorem,payloads',
                    help='bench_matrix suites to loop; formats is where the intermittent lives')
    ap.add_argument('--rates', default=None, help='override the rate ladder')
    # THE PLAN SUITE'S SIZE. All 41 vectors is about 2 h a lap, right for an overnight run and useless
    # for a ten-minute smoke -- so a subset is selectable, and it is a seeded PREFIX of the same order
    # rather than a separate selection with its own behaviour.
    ap.add_argument('--plan-vectors', type=int, default=None,
                    help='plan suite: a seeded subset of this many vectors (default all 41)')
    ap.add_argument('--skip-vectors', default='',
                    help='plan suite: vector ids to leave out, printed in every lap header')
    ap.add_argument('--record-every', type=int, default=0,
                    help='also take a one-press recording every Nth lap (0 = never). Each costs '
                         'about a minute, so it trades laps for coverage of the recording path')
    ap.add_argument('--keep-combine', action='store_true',
                    help='leave SDG CH2 summed into CH1 as an impairment for every lap')
    ap.add_argument('--out', default=os.path.join(ROOT, 'out', 'soak'))
    ap.add_argument('--selftest', nargs='?', const=SELFTEST_LOG, default=None, metavar='LOG',
                    help='replay a saved lap log through the completeness tests and exit. Touches no '
                         'instrument and spawns no child, so it is safe while a soak is running')
    a = ap.parse_args()

    # BEFORE ANYTHING ELSE, and before a record directory exists: this mode is for a bench that is busy.
    if a.selftest:
        return selftest(a.selftest)

    stamp = time.strftime('%Y-%m-%dT%H-%M-%S')
    outdir = os.path.join(os.path.expanduser(a.out), stamp)
    os.makedirs(outdir, exist_ok=True)
    jl = open(os.path.join(outdir, 'laps.jsonl'), 'w')

    print('=' * 78)
    print('SOAK  %s   suites=%s   for %.1f h' % (stamp, a.suites, a.hours))
    print('sleep guard: %s' % hold_awake())
    print('record -> %s' % outdir)
    print('=' * 78)

    d = None
    if a.record_every > 0:
        from dmmrun import DMM
        d = DMM()
        # RESYNC BEFORE ASKING ANYTHING. A previous client killed mid-conversation leaves unread
        # output on the instrument, and the next connection's replies then run one behind its
        # questions: 'sdec ~= nil' answers with the PREVIOUS command's line, so a healthy app reads as
        # absent and this refuses to start. A sentinel is the only way to know the stream is aligned,
        # because every stale line is itself a plausible answer.
        # THE SHARED PREFLIGHT (tools/bench_sync.py): sentinel alignment, one tagged state read, refuse a
        # live run, unwind a resting streaming mode through mode_exit(), clear the previous result, disarm
        # the queued-press absorb, and verify. Every one of those guards a false verdict this tool has
        # actually produced -- a probe's leftover capmode filing a good vector as BAD, and a previous
        # recording's ck_tot reported as the first lap's own bytes.
        BS.preflight(d, 'soak')
        d.exec('sdec.errcount, sdec.stickyerr = 0, nil eventlog.clear()')
        for ln in d.load_script('skmod', RECORD_TSP, timeout=120):
            if ln and ln != '===DONE===':
                print('  load: %s' % ln)
        # THE LOCK GOES BACK between laps, or every bench_matrix child refuses its own instrument.
        from dmmrun import release_single_instance
        d.close()
        release_single_instance()
        d = None

    deadline = time.time() + a.hours * 3600
    laps, bad_laps, dead, odd_rc = 0, 0, 0, 0
    tally = {}            # point -> [runs, failures]
    recs = []
    # THE POINT COUNT THE FIRST COMPLETE LAP PRODUCED, so a later lap that quietly produces fewer is
    # caught. Learned rather than configured: the count depends on which suites and rates were asked for.
    expect = None
    incomplete = 0
    # A LAP DEADLINE DERIVED FROM THE PLAN, not a constant. A fixed 1200 s kills a plan lap twenty
    # minutes into a two-hour job and reports a healthy instrument as a wedged one. Estimated from the
    # rate list and the measured per-cell cost, then doubled: loose enough that a slow lap survives,
    # tight enough that a hang costs one lap rather than half the run -- a lap has run 5.47 h once,
    # and a deadline above that would not have caught it.
    lap_timeout = 1200
    if 'plan' in a.suites.split(','):
        import soakplan as SP
        from vector_names import MAP as VMAP
        nskip = len([x for x in (a.skip_vectors or '').split(',') if x.strip()])
        nvec = a.plan_vectors or (len(VMAP) - nskip)
        est = SP.estimate_secs(SP.rates_for(1), nvec)
        lap_timeout = int(max(1200, LAP_DEADLINE_MARGIN * est))
        print('plan suite: %d vectors x %d rates, estimated %.0f min a lap, deadline %.0f min'
              % (nvec, len(SP.rates_for(1)), est / 60.0, lap_timeout / 60.0))
    t_start = time.time()

    # A LAP TARGET THAT CAN CHANGE WHILE THE RUN IS UP. --hours and --laps are both decided before the
    # first lap, so changing your mind about three laps versus four otherwise costs a restart -- and a
    # restart throws away the laps already banked, which is the opposite of what "one more lap" means.
    # Writing an integer into <record dir>/LAPS is read here, before each lap, and honoured; writing
    # STOP ends the run cleanly after the lap in flight. Neither interrupts a lap: a lap is the unit of
    # evidence, and half of one is not worth having.
    def lap_target():
        try:
            with open(os.path.join(outdir, 'LAPS')) as f:
                return int(f.read().strip())
        except Exception:                                          # noqa: BLE001
            return a.laps

    while True:
        want = lap_target()
        if os.path.exists(os.path.join(outdir, 'STOP')):
            print('STOP file present: ending after %d lap(s) as asked.' % laps)
            break
        if want is not None and laps >= want:
            print('lap target %d reached; ending.' % want)
            break
        # THE WALL DEADLINE ONLY GATES STARTING A LAP, never a lap in flight -- so a lap that begins
        # inside the budget always runs to completion. That is deliberate: a truncated lap is not
        # tallied, so cutting one wastes every minute already spent on it.
        if want is None and time.time() >= deadline:
            break
        laps += 1
        try:
            rc, out, points, why = run_suite(a.suites, a.rates, timeout=lap_timeout,
                                             expect=expect, iteration=laps,
                                             plan_vectors=a.plan_vectors,
                                             skip_vectors=a.skip_vectors,
                                             heartbeat=os.path.join(outdir, 'heartbeat.txt'),
                                             keep_combine=a.keep_combine)
        except subprocess.TimeoutExpired:
            dead += 1
            print('lap %-4d TIMED OUT -- the suite did not finish' % laps)
            if dead >= 3:
                print('three laps in a row failed to complete; stopping rather than hammering a '
                      'possibly wedged instrument')
                break
            continue
        # AN INCOMPLETE LAP IS EVIDENCE OF NOTHING, and must not be tallied. Counting its partial point
        # set would enter a 'run' for every point it reached and none for the points it never got to --
        # so the missing ones silently improve their own pass rate, which is the opposite of what a soak
        # is for. Kept as evidence and counted separately.
        # EXIT 3 MEANS THE BENCH IS GONE, and no later lap can mean anything. The generator's SCPI
        # port needs a power cycle at the front panel, which an unattended run cannot do -- so
        # continuing turns one wedge into a night of laps against a dead instrument.
        if rc == 3:
            print('lap %-4d STOPPED: the bench stopped answering. Ending the soak rather than '
                  'running further laps against a dead instrument -- the generator needs a power '
                  'cycle at the front panel.' % laps)
            incomplete += 1
            break
        if why is not None:
            incomplete += 1
            print('lap %-4d INCOMPLETE -- %s (not tallied)' % (laps, why))
            with open(os.path.join(outdir, 'lap%04d-INCOMPLETE.log' % laps), 'w') as fh:
                fh.write(out)
            jl.write(json.dumps({'lap': laps, 'secs': round(time.time() - t_start, 1),
                                 'rc': rc, 'npoints': len(points), 'incomplete': why}) + '\n')
            jl.flush()
            # A LAP THAT PRODUCED NO POINTS AT ALL is the one this tool stops for: a meter that has
            # stopped answering, rather than a suite whose summary merely disagreed with itself. Its
            # output is kept either way: the laps whose evidence matters most are exactly the ones a
            # 'produced no points' branch prints one line about and drops.
            if not points:
                dead += 1
                if dead >= 3:
                    print('three laps in a row reached no summary; stopping rather than hammering a '
                          'possibly wedged instrument')
                    break
            continue
        dead = 0
        if expect is None:
            expect = len(points)

        fails = []
        for name, (verdict, detail) in points.items():
            t = tally.setdefault(name, [0, 0])
            t[0] += 1
            if verdict == 'BAD':
                t[1] += 1
                fails.append('%s: %s' % (name, detail[:70]))
        # A NONZERO EXIT WITH NOTHING BAD IN IT IS A CONTRADICTION, and the one the summary is now
        # blind to. bench_matrix returns 1 exactly when a point is BAD (bench_matrix.py:755), so this
        # combination means the child died AFTER printing a consistent summary -- a teardown that
        # raised, most likely, which is precisely the thing that poisons the next lap. The points were
        # genuinely measured, so the lap is still tallied; what must not happen is it printing ALL OK
        # and discarding the traceback, which is what judging completeness on the summary alone buys
        # at this one spot.
        if rc != 0 and not fails:
            odd_rc += 1
            fails.append('the child exited %d with every point ok -- output kept' % rc)
        if fails:
            bad_laps += 1
            # THE WHOLE OUTPUT, kept per failing lap. The frequency is one half of the answer and the
            # app's own notes are the other -- which format it chose, what else fitted, whether the
            # probe misfitted the rate.
            with open(os.path.join(outdir, 'lap%04d-FAILED.log' % laps), 'w') as fh:
                fh.write(out)

        rec = None
        if a.record_every > 0 and laps % a.record_every == 0:
            from dmmrun import DMM, release_single_instance
            from siglent import SDG
            g = SDG()
            wire = record_wire(g)
            g.close()
            d = DMM()
            # THE RESYNC'S VERDICT MATTERS HERE TOO. Unaligned, sk_record's reply is read from the
            # previous conversation and the lap records a recording that never ran.
            if not BS.resync(d):
                rec = {'ok': False, 'nf': 'nil', 'endwhy': 'desync', 'job': False,
                       'lasterr': 'the reply stream would not resync', 'events': '',
                       'baud': '?', 'fc_end': 'nil', 'secs': 0.0}
            else:
                rec = record_lap(d, 'sml')
            d.close()
            release_single_instance()
            # A TIMEOUT IS A FAILURE, NOT AN ABSENCE. record_lap returns None when the press never came
            # back, and dropping it left no trace at all -- so the worst outcome a recording can have was
            # the one the summary could not see.
            if rec is None:
                rec = {'ok': False, 'nf': 'nil', 'endwhy': 'timeout', 'job': False,
                       'lasterr': 'the recording never returned', 'events': '',
                       'baud': '?', 'fc_end': 'nil', 'secs': 0.0}
            rec['wire'] = wire
            recs.append(rec)

        row = {'lap': laps, 'secs': round(time.time() - t_start, 1), 'rc': rc,
               'npoints': len(points), 'fails': fails, 'record': rec}
        jl.write(json.dumps(row) + '\n')
        jl.flush()
        el = (time.time() - t_start) / 3600.0
        # THE RECORDING'S VERDICT, not just its byte count. A recording that REFUSED reports nf=nil in a
        # fraction of a second, and printing only the count made that read as though a recording had
        # happened, which hides a silent no-op on every lap.
        rtxt = ''
        if rec is not None:
            # nf MUST BE A POSITIVE NUMBER. A truthiness test passes 'nil', '0' and any non-numeric
            # text alike, so a polite refusal counts as a clean recording.
            bad = ((not rec['ok']) or rec['job'] or not rec['nf'].isdigit()
                   or int(rec['nf']) < 1)
            rtxt = '   [rec %s%s B in %.0f s @%s]' % ('FAILED ' if bad else '',
                                                     rec['nf'], rec['secs'], rec.get('baud', '?'))
            if bad and rec.get('lasterr'):
                rtxt += ' %s' % rec['lasterr'][:60]
            # AND IT COUNTS AS A FAILING LAP. A recording that refused is exactly the kind of silent
            # regression this tool exists to catch; leaving it out of `fails` meant the summary could
            # report zero bad laps over a run whose every recording no-op'd.
            if bad:
                # COUNTED ONCE. bad_laps was already incremented above if a POINT failed, so this only
                # adds a lap that would otherwise have read as clean.
                if not fails:
                    bad_laps += 1
                fails.append('recording: %s (%s)' % (rec['endwhy'], (rec['lasterr'] or '')[:50]))
        print('lap %-4d %5.2f h  %2d points  %s%s'
              % (laps, el, len(points),
                 'ALL OK' if not fails else 'BAD: ' + '; '.join(fails)[:90], rtxt))

    jl.close()

    # ---- the summary that is the point of the exercise -------------------------------------------
    print('\n' + '=' * 78)
    print('%d laps in %.2f h; %d laps had at least one bad point; %d laps INCOMPLETE (not tallied)' %
          (laps, (time.time() - t_start) / 3600.0, bad_laps, incomplete))
    if odd_rc:
        print('%d lap(s) exited nonzero with every point ok -- a child that died after its summary; '
              'their output is kept' % odd_rc)
    print('%-26s %6s %6s  %s' % ('POINT', 'RUNS', 'FAILS', 'RATE'))
    print('-' * 78)
    flaky = sorted(tally.items(), key=lambda kv: -kv[1][1])
    for name, (runs, f) in flaky:
        if f:
            print('%-26s %6d %6d  %.1f %%  (1 in %.0f)'
                  % (name, runs, f, 100.0 * f / runs, runs / float(f)))
    clean = [n for n, (r, f) in flaky if f == 0]
    print('%d point(s) never failed: %s' % (len(clean), ', '.join(sorted(clean))[:400]))
    if recs:
        # A RECORDING THAT REFUSED IS NOT A CLEAN ONE, and nf must be a real count. 'nil' passed the old
        # `ok and not job` test, because pcall succeeded -- the app refused politely.
        okrec = [r for r in recs if r['ok'] and not r['job']
                 and r['nf'] not in ('nil', '') and r['nf'].isdigit() and int(r['nf']) > 0]
        print('\nrecordings: %d taken, %d clean; bytes %s'
              % (len(recs), len(okrec), ', '.join(r['nf'] for r in recs[:12])))
        for r in recs:
            if r not in okrec:
                print('  REFUSED/FAILED on a recording lap: nf=%s endwhy=%s job=%s %s'
                      % (r['nf'], r['endwhy'], r['job'], (r['lasterr'] or '')[:80]))
        for r in recs:
            if r['events']:
                print('  events on a recording lap: %s' % r['events'][:120])
    with open(os.path.join(outdir, 'SUMMARY.json'), 'w') as fh:
        json.dump({'stamp': stamp, 'laps': laps, 'bad_laps': bad_laps,
                   'hours': round((time.time() - t_start) / 3600.0, 3),
                   'incomplete_laps': incomplete, 'odd_exit_laps': odd_rc,
                   'tally': {k: {'runs': v[0], 'fails': v[1]} for k, v in tally.items()},
                   'records': recs}, fh, indent=1)
    print('\nrecord: %s' % outdir)
    # THE EXIT CODE SAYS WHAT HAPPENED. It was always 0, so a soak that found a hard fault every lap
    # reported success to whatever ran it -- and this tool exists precisely to be believed about failures.
    # 1 = something failed, 2 = the run could not be trusted to have measured anything.
    if incomplete >= max(3, laps // 4):
        print('REFUSING TO CALL THIS A CLEAN RUN: %d of %d laps were incomplete.' % (incomplete, laps))
        return 2
    return 1 if bad_laps else 0


if __name__ == '__main__':
    sys.exit(main())

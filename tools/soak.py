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
  * IT NEVER UPLOADS A WAVEFORM. Repeated large uploads wedge the SDG2122X's LAN service (see
    tools/instruments.py); selecting an already-loaded arb does not. The suites here only select.
  * IT KEEPS THE EVIDENCE FOR EVERY FAILURE. A run with a BAD point has its whole output saved, so the
    app's own notes -- rival formats, probe misfits, flagged heads -- are there in the morning. A
    frequency with no cause attached is only half an answer.
  * IT STOPS IF THE INSTRUMENT STOPS ANSWERING, rather than hammering a wedged meter until dawn.

    python3 tools/soak.py --hours 8
    python3 tools/soak.py --hours 1 --suites formats        # just the format arbitration
    python3 tools/soak.py --hours 8 --record-every 10       # add a one-press recording every 10th lap
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
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The per-point verdict lines bench_matrix prints in its summary: "format v44d  ok  8O1 exact 150 B".
POINT = re.compile(r'^\s*(\S+\s+\S+)\s+(ok|BAD|skip)\s+(.*)$')

# A recording press, driven exactly as the panel would: one press, whole job. Timed on the HOST,
# because the instrument's single timer is reset inside the app at the end of a recording (see
# bench_panel.py) and would report milliseconds for a minute of work.
#
# IT LOCKS THE RATE FIRST, WITH A FRAME CAPTURE, exactly as an operator's first press does. A streaming
# mode REFUSES outright without a locked baud rate -- 'lock the baud rate in Options -- streaming picks
# the sample rate from it' -- and bench_matrix leaves force_baud nil (suite_hard's teardown clears the
# pin). Measured: the first attempt at this soak returned `nil` bytes in 0.02 s on every recording lap,
# a silent no-op that looked like a recording had happened. The frame capture is not scaffolding: it is
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


def run_suite(suites, rates=None, timeout=1200, expect=None):
    """One lap of bench_matrix. -> (rc, stdout, {point: (verdict, detail)}, why_incomplete).

    A LAP THAT DID NOT FINISH IS NOT A LAP THAT PASSED, and the fourth return value is what says so. The
    tally below counts per-point failures, so a child that printed a few summary-looking lines and then
    crashed used to have its PARTIAL point set tallied and the lap printed as ALL OK -- every point it
    never reached simply absent, and absence indistinguishable from success. Three independent things have
    to hold: the child exited 0, its final 'N of N points fully correct' line is present and parseable,
    and the point count matches what previous laps produced.
    """
    argv = ['python3', 'tools/bench_matrix.py', '--suites', suites,
            '--no-start', '--no-output-off']
    if rates:
        argv += ['--rates', rates]
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    out = p.stdout.decode('utf-8', errors='replace')
    points = {}
    # Only the SUMMARY block carries one line per point; the body repeats them with more detail, and
    # parsing both would double-count. The summary follows the last '=== ' banner.
    tail = out.split('points fully correct')[0]
    for ln in tail.splitlines():
        m = POINT.match(ln.rstrip())
        if m and not ln.startswith('==='):
            name, verdict, detail = m.group(1).strip(), m.group(2), m.group(3).strip()
            points[name] = (verdict, detail)
    # THE COMPLETENESS TESTS, all three of them.
    why = None
    if p.returncode != 0:
        why = 'the suite exited %d' % p.returncode
    else:
        fin = re.search(r'(\d+) of (\d+) points fully correct', out)
        if fin is None:
            why = 'no "N of N points fully correct" line -- the suite did not reach its summary'
        elif int(fin.group(2)) != len(points):
            why = ('the summary counts %s points but %d were parsed'
                   % (fin.group(2), len(points)))
        elif expect is not None and len(points) != expect:
            why = 'produced %d points, previous laps produced %d' % (len(points), expect)
    return p.returncode, out, points, why


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
    g.select_arb(LOREM_ARB, amp_for(NOMINAL_SWING), srate)
    g.output(True, ch=1)
    time.sleep(0.6)
    return '%s@9600' % LOREM_ARB


def record_lap(d, cap, wall_s=1800):
    """One one-press recording. -> dict, or None if the press never returned inside wall_s.

    A HARD HOST DEADLINE, because a per-read timeout is not a bound on the CALL. d.line(t) restarts its
    timeout on every chunk that arrives, so any dribble of output keeps the loop alive indefinitely -- and
    one lap of a five-hour soak once consumed 5.5 h here and then returned None, which the old code
    silently dropped. Whatever the instrument was doing, a recording lap must cost one lap, not the run.

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
    ap.add_argument('--suites', default='formats,rates',
                    help='bench_matrix suites to loop; formats is where the intermittent lives')
    ap.add_argument('--rates', default=None, help='override the rate ladder')
    ap.add_argument('--record-every', type=int, default=0,
                    help='also take a one-press recording every Nth lap (0 = never). Each costs '
                         'about a minute, so it trades laps for coverage of the recording path')
    ap.add_argument('--out', default=os.path.join(ROOT, 'out', 'soak'))
    a = ap.parse_args()

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
        # questions: 'sdec ~= nil' answers with the PREVIOUS command's line. Measured tonight -- a
        # healthy app read as absent and this refused to start. A sentinel is the only way to know
        # the stream is aligned, because every stale line is itself a plausible answer.
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
    laps, bad_laps, dead = 0, 0, 0
    tally = {}            # point -> [runs, failures]
    recs = []
    # THE POINT COUNT THE FIRST COMPLETE LAP PRODUCED, so a later lap that quietly produces fewer is
    # caught. Learned rather than configured: the count depends on which suites and rates were asked for.
    expect = None
    incomplete = 0
    t_start = time.time()

    while time.time() < deadline:
        laps += 1
        try:
            rc, out, points, why = run_suite(a.suites, a.rates, expect=expect)
        except subprocess.TimeoutExpired:
            dead += 1
            print('lap %-4d TIMED OUT -- the suite did not finish' % laps)
            if dead >= 3:
                print('three laps in a row failed to complete; stopping rather than hammering a '
                      'possibly wedged instrument')
                break
            continue
        if not points:
            dead += 1
            print('lap %-4d produced no points (instrument unreachable?)' % laps)
            if dead >= 3:
                print('three laps in a row produced nothing; stopping.')
                break
            continue
        dead = 0
        # AN INCOMPLETE LAP IS EVIDENCE OF NOTHING, and must not be tallied. Counting its partial point
        # set would enter a 'run' for every point it reached and none for the points it never got to --
        # so the missing ones silently improve their own pass rate, which is the opposite of what a soak
        # is for. Kept as evidence and counted separately.
        if why is not None:
            incomplete += 1
            print('lap %-4d INCOMPLETE -- %s (not tallied)' % (laps, why))
            with open(os.path.join(outdir, 'lap%04d-INCOMPLETE.log' % laps), 'w') as fh:
                fh.write(out)
            jl.write(json.dumps({'lap': laps, 'secs': round(time.time() - t_start, 1),
                                 'rc': rc, 'npoints': len(points), 'incomplete': why}) + '\n')
            jl.flush()
            continue
        if expect is None:
            expect = len(points)

        fails = []
        for name, (verdict, detail) in points.items():
            t = tally.setdefault(name, [0, 0])
            t[0] += 1
            if verdict == 'BAD':
                t[1] += 1
                fails.append('%s: %s' % (name, detail[:70]))
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
        # happened -- which is how the first attempt at this soak hid a silent no-op on every lap.
        rtxt = ''
        if rec is not None:
            # nf MUST BE A POSITIVE NUMBER. 'nil' and '0' both passed the old test, and so did any
            # non-numeric text -- so a polite refusal counted as a clean recording.
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
                   'incomplete_laps': incomplete,
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

#!/usr/bin/env python3
"""Hand a soak to the DMM6500 and walk away. The instrument drives the generator itself.

WHY. Every bench run so far has needed a Mac in the critical path, which caps a soak at as long as
someone is watching. bench/ moves the loop onto the instrument: it selects vectors over tspnet, captures
with the app's own acquisition, and appends every cell to the USB key as it goes. This tool loads that,
starts it, and gets out of the way.

    python3 tools/run_bench.py --smoke                 # the 86-cell spec, ~9 min, then judge it
    python3 tools/run_bench.py --iterations 0          # indefinite: runs until the power is cut
    python3 tools/run_bench.py --fetch                 # pull the newest record off the key
    python3 tools/run_bench.py --judge out/bench/SOAK000.csv

THE HOST MUST NOT BE CONNECTED WHILE IT RUNS. The DMM accepts one controlling socket and a running TSP
script holds the interpreter, so a query mid-run gets nothing and the flock in dmmrun.py exists to stop
two clients trying. --start therefore disconnects immediately after starting the loop; progress is
readable two ways, neither of which needs the command interface:

  * the record on the key, tagged 'S,' per cell, read afterwards with --fetch
  * a live push, if --listen gave the instrument somewhere to send it (tools/soak_listen.py)

WHY THE PLAN GOES OVER THE SOCKET FOR A SMOKE AND BY HAND FOR A SOAK. 86 rows is ~6 kB and writes in
seconds. A week's plan is ~167 000 rows and ~10 MB, which is minutes of TSP string handling on a 2016
instrument for data that could be copied onto the key in one drag. --push-plan refuses above
PUSH_MAX_ROWS rather than appearing to hang.
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I                                                  # noqa: E402
from dmmrun import DMM                                                   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The app, then the bench engine on top of it. ORDER MATTERS TWICE: the app's modules have their own
# dependency order, and bench/ reads ulog.next_free out of usb_log.tsp, so it cannot load first.
APP = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
       'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp']
ENGINE = ['bench/sdg_net.tsp', 'bench/bench_rec.tsp', 'bench/bench_run.tsp']

# The smoke's own subset, from bench_smoke.py rather than repeated here: the two have to be the same 86
# cells for the instrument-driven run to be comparable with the host-driven one.
SMOKE_SPEC = 'v77:std,r06:std,v78:nonstd,r00:nonstd'

USBDIR = '/usb1/SERDEC'
PLAN = USBDIR + '/PLAN.CSV'
PUSH_MAX_ROWS = 4000


def load_modules(d, paths, timeout=300):
    """Load each file as its own TSP script, as run_app.py does.

    ONE SCRIPT PER MODULE rather than one concatenation, because a syntax error then names the file it
    is in. The instrument reports a line number against the script it compiled, so a single 13 000-line
    blob makes every error a hunt.
    """
    for p in paths:
        with open(os.path.join(ROOT, p)) as f:
            body = f.read()
        name = os.path.basename(p).replace('.tsp', '').replace('.', '_')
        out = d.load_script(name, body, run=True, timeout=timeout)
        if out and 'LOAD FAILED' in out:
            raise SystemExit('%s did not load:\n%s' % (p, out))
        print('  loaded %-28s %d lines' % (p, body.count('\n') + 1))


def push_plan(d, rows):
    """Write the plan onto the key over the socket, in chunks, verifying the row count afterwards.

    VERIFIED BY COUNTING, not by the absence of an error. file.write on this instrument posts an event
    rather than raising, so a truncated plan would leave the soak running a shorter lap than intended
    and nothing would say so -- and a short plan does not fail, it just wraps sooner and quietly
    repeats stimulus.
    """
    if len(rows) > PUSH_MAX_ROWS:
        raise SystemExit(
            'REFUSING: %d rows is too many to push over the socket (limit %d). Copy PLAN.CSV onto the '
            'key directly -- a week\'s plan is ~10 MB and belongs on the key, not in TSP strings.'
            % (len(rows), PUSH_MAX_ROWS))
    d.exec('do local fh = file.open("%s", file.MODE_WRITE) '
           'if fh == nil then print("PLANOPENFAIL") else _plan_fh = fh print("PLANOPEN") end end'
           % PLAN)
    CH = 20
    for i in range(0, len(rows), CH):
        chunk = rows[i:i + CH]
        # Escaped as a Lua long string would not help: a row can contain no ']]' but can contain a
        # quote, so each line is written as its own short string with quotes doubled out.
        body = ' '.join('file.write(_plan_fh, %s)'
                        % lua_str(r + '\n') for r in chunk)
        d.exec('do ' + body + ' end')
    d.exec('do file.close(_plan_fh) _plan_fh = nil end')
    n = d.q('do local fh = file.open("%s", file.MODE_READ) local n = 0 '
            'if fh ~= nil then while true do local l = file.read(fh, file.READ_LINE) '
            'if l == nil then break end n = n + 1 end file.close(fh) end print(n) end' % PLAN)
    got = int((n or '0').strip() or 0)
    want = len(rows)
    if got != want:
        raise SystemExit('REFUSING to start: the key holds %d plan line(s), not the %d pushed. A short '
                         'plan wraps sooner and repeats stimulus without saying so.' % (got, want))
    print('  plan pushed: %d row(s) verified on the key' % got)


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def fetch(d, out_dir):
    """Pull the newest SOAKnnn.CSV off the key, in line batches.

    READ IN BATCHES, not READ_ALL: the file is tens of MB after a week, and one string that size is
    more than the instrument will hand over in a single reply.
    """
    os.makedirs(out_dir, exist_ok=True)
    # The newest is the highest-numbered name that opens. Probed rather than listed, because the FAT
    # listing on this instrument is a UTF-16 blob that usb_log.tsp only searches for one exact name.
    newest = None
    for i in range(999, -1, -1):
        p = '%s/SOAK%03d.csv' % (USBDIR, i)
        r = d.q('do local fh = file.open("%s", file.MODE_READ) '
                'if fh == nil then print("no") else file.close(fh) print("yes") end end' % p)
        if (r or '').strip() == 'yes':
            newest = p
            break
    if newest is None:
        raise SystemExit('no SOAKnnn.csv on the key -- has a run started?')
    print('  fetching %s' % newest)
    local = os.path.join(out_dir, os.path.basename(newest))
    d.exec('do _rd_fh = file.open("%s", file.MODE_READ) end' % newest)
    nline = 0
    with open(local, 'w') as f:
        while True:
            batch = d.q('do local t, n = {}, 0 for i = 1, 200 do '
                        'local l = file.read(_rd_fh, file.READ_LINE) if l == nil then break end '
                        'n = n + 1 t[n] = l end '
                        'if n == 0 then print("===EOF===") else io.write(table.concat(t)) '
                        'print("===MORE===") end end', timeout=120)
            if batch is None:
                break
            body = batch.replace('===MORE===', '').replace('===EOF===', '')
            f.write(body)
            nline += body.count('\n')
            if '===EOF===' in batch:
                break
    d.exec('do file.close(_rd_fh) _rd_fh = nil end')
    print('  %d line(s) -> %s' % (nline, local))
    return local


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--smoke', action='store_true',
                    help='the 86-cell smoke subset, one iteration, then fetch and judge')
    ap.add_argument('--iterations', type=int, default=1,
                    help='0 means indefinitely -- ended by a power cycle or STOP.TXT')
    ap.add_argument('--iteration', type=int, default=1, help='first plan iteration')
    ap.add_argument('--spec', default=None, help='bench_matrix --plan-spec grammar for a subset')
    ap.add_argument('--skip-vectors', default=','.join(I.__dict__.get('HW_SKIP', ()) or ('v95', 'v96')))
    ap.add_argument('--push-plan', action='store_true', help='write the plan onto the key first')
    ap.add_argument('--no-load', action='store_true', help='the app and engine are already loaded')
    ap.add_argument('--start', action='store_true', help='start the loop and disconnect')
    ap.add_argument('--fetch', action='store_true', help='pull the newest record off the key')
    ap.add_argument('--judge', default=None, help='judge a fetched record')
    ap.add_argument('--listen', default=None, metavar='IP',
                    help='host address for live progress pushes (see tools/soak_listen.py)')
    ap.add_argument('--out', default=os.path.join(ROOT, 'out', 'bench'))
    a = ap.parse_args()

    if a.judge:
        return subprocess.call(['python3', os.path.join(ROOT, 'tools', 'judge_bench.py'), a.judge])

    if a.smoke:
        a.spec = a.spec or SMOKE_SPEC
        a.iterations = 1
        a.push_plan = True
        a.start = True

    if not (a.push_plan or a.start or a.fetch):
        ap.error('nothing to do: pass --smoke, --start, --push-plan or --fetch')

    rows = None
    if a.push_plan:
        argv = ['python3', os.path.join(ROOT, 'tools', 'soakplan.py'), '--emit-csv',
                '--iteration', str(a.iteration)]
        if a.spec:
            argv += ['--spec', a.spec]
        else:
            argv += ['--iterations', str(max(a.iteration, a.iteration + max(a.iterations, 1) - 1)),
                     '--skip-vectors', a.skip_vectors]
        text = subprocess.check_output(argv, cwd=ROOT).decode()
        rows = [ln for ln in text.split('\n') if ln.strip()]
        print('plan: %d line(s)%s' % (len(rows), (' spec %s' % a.spec) if a.spec else ''))

    d = DMM()
    try:
        if not a.no_load:
            print('loading the app and the bench engine')
            load_modules(d, APP)
            load_modules(d, ENGINE)
        if a.push_plan:
            push_plan(d, rows)
        if a.fetch and not a.start:
            fetch(d, a.out)
            return 0
        if a.start:
            if a.listen:
                d.exec('do brun.listenip = %s end' % lua_str(a.listen))
            # STARTED AND LEFT. The call does not return until the loop ends, so it is sent without
            # waiting for a reply -- and for --iterations 0 there is no reply to wait for at all.
            print('starting brun.soak(%d) on the instrument' % a.iterations)
            d.send('brun.soak(%d, "%s")' % (a.iterations, 'smoke' if a.smoke else 'soak'))
            if a.iterations == 0:
                print('  running indefinitely. The instrument holds the socket now:')
                print('    end it by dropping %s/STOP.TXT on the key, or by cutting the power' % USBDIR)
                print('    then: python3 tools/run_bench.py --fetch --no-load')
                return 0
            # A FINITE RUN IS WAITED FOR, because the point of --smoke is a verdict now. 86 cells at
            # ~6 s is ~9 min; the timeout is generous because a slow cell is not a failure.
            secs = 60 + 12 * (len(rows) if rows else 1700)
            print('  waiting up to %.0f min for %d iteration(s)' % (secs / 60.0, a.iterations))
            line = d.line(timeout=secs)
            print('  instrument said: %s' % (line or '(nothing)'))
            local = fetch(d, a.out)
            d.close(restore=True)
            return subprocess.call(['python3', os.path.join(ROOT, 'tools', 'judge_bench.py'), local])
    finally:
        try:
            d.close()
        except Exception:
            pass
    return 0


if __name__ == '__main__':
    sys.exit(main())

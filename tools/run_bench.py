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
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import instruments as I                                                  # noqa: E402
import lint_tsp                                                          # noqa: E402
from dmmrun import DMM                                                   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The Lua 5.0.2 parser, if this machine has built one. None means send_lua checks less; it says so.
LUAC = os.path.join(ROOT, lint_tsp.LUAC)
if not os.path.exists(LUAC):
    print('NOTE: no Lua 5.0.2 parser (sh tools/get_lua502.sh) -- statements go unparsed to the panel')
    LUAC = None

# The app, then the bench engine on top of it. ORDER MATTERS TWICE: the app's modules have their own
# dependency order, and bench/ reads ulog.next_free out of usb_log.tsp, so it cannot load first.
APP = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
       'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp']
ENGINE = ['bench/arb_names.tsp', 'bench/sdg_net.tsp', 'bench/bench_rec.tsp',
          'bench/bench_run.tsp']

# The smoke's own subset, from bench_smoke.py rather than repeated here: the two have to be the same 86
# cells for the instrument-driven run to be comparable with the host-driven one.
SMOKE_SPEC = 'v77:std,r06:std,v78:nonstd,r00:nonstd'

USBDIR = '/usb1/SERDEC'
PLAN = USBDIR + '/PLAN.CSV'
# THE ROW CEILING IS NOW ABOUT TIME, NOT SAFETY. With one acknowledged batch in flight the transfer
# cannot overrun the input buffer at any size, so this bounds how long a push may take rather than
# whether it works: a fortnight is ~272 000 rows, which is ~13 600 round trips. Raised from 200 000,
# which predated the handshake and was a guess at where the old unbounded push would break.
PUSH_MAX_ROWS = 400000
# One chunk of the plan push, in bytes. 780 kB is what the app itself loads in 1.0 s and the only
# load size this instrument has been measured at.
# Rows per acknowledged batch. ~1.5 kB a statement, and the handshake means the host is never
# more than one statement ahead of the interpreter -- so this trades round trips for a bound
# that holds at any plan size, rather than a throttle that only moves the overrun.
PUSH_BATCH_ROWS = 20


# CLEARED BEFORE THE LOAD, run_app.py's own prelude: sdec.buf is the only reference to a firmware
# buffer object, so dropping the table without deleting it leaks it until the next power cycle.
PRELUDE = """
if sdec ~= nil then
  pcall(function() if sdec.buf ~= nil then buffer.delete(sdec.buf) end end)
  pcall(function() trigger.model.abort() end)
end
sdec = nil
ulog = nil
bsdg = nil
brec = nil
brun = nil
barb = nil
eventlog.clear()
print('PRE cleared')
"""


def load_modules(d, paths, timeout=300):
    """Load the app and the engine as ONE script, which is how run_app.py does it.

    NOT ONE SCRIPT PER FILE. That reads better -- a syntax error would name the file it is in -- and it
    cost 300 s per module here, because load_script(run=True) waits for a '===DONE===' sentinel that a
    module body never prints. Ten modules is fifty minutes of waiting for output that was never coming.
    One script with the sentinel appended loads in about 25 s.
    """
    body = ['-- ==== %s ====\n%s' % (p, open(os.path.join(ROOT, p)).read()) for p in paths]
    src = PRELUDE + '\n'.join(body) + "\nprint('===DONE===')"
    print('  %d bytes / %d lines' % (len(src), src.count('\n') + 1))
    t0 = time.time()
    out = d.load_script('sdecbench', src, timeout=timeout)
    print('  %.1f s' % (time.time() - t0))
    for ln in out:
        if ln and ln != '===DONE===':
            print('  load: ' + ln)
    # THE INSTRUMENT'S OWN ACCOUNT OF THE LOAD, ALWAYS, AND THIS IS NOT OPTIONAL POLISH. A chunk that
    # will not compile posts the reason -- WITH THE LINE NUMBER -- into the event log and prints nothing
    # at all; loadscript stores lines and endscript is where the parse happens, so the failure never
    # comes back down the socket as output. Not reading it here is how a session ended with "syntax error
    # on the dmm" and no idea where, on a build that a host luac accepted, having burned the last of the
    # instrument time available. One query per entry, and a clean load has none.
    ev = [m for m in d.errors() if m]
    for m in ev:
        print('  EVENT: %s' % m)
    # AND WHAT ACTUALLY ARRIVED, MEASURED. scriptVar.source hands back the stored text, so the bytes on
    # the instrument can be compared with the bytes sent. This exists because a build that a real Lua
    # 5.0.2 parses cleanly -- checked, not assumed -- was still rejected by the instrument as a syntax
    # error, and the only remaining explanation is the transfer: load_script pushes 13 000-odd lines with
    # no flow control, and an input buffer that overruns loses one, which turns into a parse error at a
    # line number nobody sent. This tells the two apart in one query instead of by guesswork.
    got = qtag(d, 'print("SRCLEN=" .. tostring(sdecbench ~= nil and string.len(sdecbench.source) or -1))',
               'SRCLEN=', timeout=60)
    print('  stored source: %s byte(s) of %d sent' % (got, len(src)))
    # PROVED, not assumed: a loadscript that failed to compile leaves the names absent and every later
    # call fails with something less informative than this line.
    probe = d.q('print(tostring(sdec ~= nil), tostring(sdec.acquire ~= nil), '
                'tostring(brun ~= nil), tostring(bsdg ~= nil), tostring(brec ~= nil), '
                'tostring(barb ~= nil and barb.n))')
    print('  probe (sdec/acquire/brun/bsdg/brec/barb.n): %s' % probe)
    if probe is None or 'nil' in (probe or '').split()[:5]:
        raise SystemExit('the app or the bench engine did not load: %s\n  %s'
                         % (probe, '\n  '.join(ev) or 'the event log said nothing'))


def keysize(d, name):
    """The byte length of one file on the key, out of the FAT directory entry. -> int, or None.

    THE SAME TRICK keyfiles() USES, for the same reason: a 32-byte directory entry carries the file's
    length little-endian at offset 28, so 'is it there and how long is it' costs one read of a directory
    that exists -- no event, and no pulling the file itself back through a socket. Verifying a 9 MB plan
    by READ_ALL would mean holding 9 MB in a Lua string on a 2016 instrument and then sending it back
    over the wire to be counted.
    """
    n83 = name83(name.split('.')[0], name.split('.')[-1])
    out = qtag(d, 'do local fh = file.open("%s", file.MODE_READ) local raw = nil '
                  'if fh ~= nil then raw = file.read(fh, file.READ_ALL) file.close(fh) end '
                  'local n = -1 '
                  'if raw ~= nil then local a = string.find(raw, "%s", 1, true) '
                  '  if a ~= nil then n = string.byte(raw, a+28) + string.byte(raw, a+29)*256 '
                  '      + string.byte(raw, a+30)*65536 + string.byte(raw, a+31)*16777216 end end '
                  'print("KEYSIZE=" .. tostring(n)) end' % (USBDIR, n83), 'KEYSIZE=', timeout=90)
    if out is None:
        return None
    try:
        v = int(out)
    except ValueError:
        return None
    return v if v >= 0 else None


def push_plan(d, rows):
    """Write the plan onto the key over the LAN, in batches the instrument ACKNOWLEDGES one at a time.

    ALL COMMUNICATION WITH THE DMM IS OVER THE LAN. The key is never touched by hand, so a 19 MB plan for
    a fortnight has to arrive down this socket, and neither of the two obvious ways survives that size.

    NOT AS EXECUTED STATEMENTS WITHOUT FLOW CONTROL, which is what was tried first: '-363 input buffer
    overrun' on the panel, CUMULATIVELY -- row 21 at forty rows a statement, row 921 with ten and a pause,
    row 921 again with a DRAIN between chunks. A drain discards what has arrived; it does not make the
    host wait. The limit is not any one statement's length, it is how much unexecuted text the input
    buffer holds while the interpreter works through what it already has, and nothing that only throttles
    the sender can bound that.

    NOT AS loadscript EITHER, at this size. loadscript stores rather than executes and has no buffer
    limit -- 780 kB of app arrives in 1.0 s that way -- but a plan this big has to be split, and every
    reload of a script name calls script.delete first, which logs '-104 Data type error'. Twenty-five
    chunks is twenty-five chances of putting a box on the panel of an instrument that must never show one.
    Giving each chunk its own name avoids the delete and leaves 19 MB of orphaned scripts in the
    instrument's memory instead.

    SO: ONE HANDSHAKE PER BATCH. Each statement writes its rows and prints a tagged acknowledgement
    carrying the running total; the host reads that line before sending the next. The host therefore
    cannot get ahead of the interpreter by more than one statement, whatever the plan's size, and the
    running total is checked as it goes rather than only at the end. 20 rows a batch is ~1.5 kB a line,
    and a fortnight's 272 000 rows is ~13 600 round trips.

    The row text cannot contain a double quote -- it is digits, commas, letters, dots and dashes -- so it
    goes inside a Lua string literal as-is, with the row separator written as the two characters
    backslash-n so the STATEMENT stays one line while the FILE gets real newlines. send_lua refuses any
    statement carrying a real control character, which is the mistake that form invites.
    """
    text = '\n'.join(rows) + '\n'
    for bad in ('"', '\\'):
        if bad in text:
            raise SystemExit('REFUSING: the plan contains %r, which cannot go inside a Lua string '
                             'literal unescaped.' % bad)
    if len(rows) > PUSH_MAX_ROWS:
        raise SystemExit('REFUSING: %d rows is past PUSH_MAX_ROWS (%d).' % (len(rows), PUSH_MAX_ROWS))
    t0 = time.time()
    if not d.exec('do _pw = file.open("%s", file.MODE_WRITE) _pn = 0 end' % PLAN):
        raise SystemExit('the instrument would not open %s for writing' % PLAN)
    sent, nb = 0, 0
    while sent < len(rows):
        batch = rows[sent:sent + PUSH_BATCH_ROWS]
        payload = '\\n'.join(batch) + '\\n'
        stmt = ('do if _pw == nil then print("PW=-1") else file.write(_pw, "%s") '
                '_pn = _pn + %d print("PW=" .. tostring(_pn)) end end' % (payload, len(batch)))
        got = qtag(d, stmt, 'PW=', timeout=120)
        if got is None:
            raise SystemExit('the instrument stopped acknowledging the plan after %d row(s)' % sent)
        if int(got) < 0:
            raise SystemExit('the plan file handle closed under us after %d row(s)' % sent)
        sent += len(batch)
        nb += sum(len(r) + 1 for r in batch)
        if int(got) != sent:
            raise SystemExit('REFUSING: the instrument has written %s row(s) where %d were sent'
                             % (got, sent))
        if len(rows) > 20000 and sent % 20000 < PUSH_BATCH_ROWS:
            print('    %d/%d rows (%.0f kB) %.0f s' % (sent, len(rows), nb / 1024.0,
                                                      time.time() - t0))
    d.exec('do file.flush(_pw) file.close(_pw) _pw = nil end')
    print('  plan pushed: %d row(s) in %.1f s (%d batch(es) of %d)'
          % (sent, time.time() - t0, (sent + PUSH_BATCH_ROWS - 1) // PUSH_BATCH_ROWS,
             PUSH_BATCH_ROWS))
    # VERIFIED FROM THE DIRECTORY ENTRY, not by reading the plan back. Counting lines would mean reading
    # until file.read returns nil -- a read PAST THE END, which posts 2201 'File read error' on this
    # instrument: a box on the panel, from the verification step itself. READ_ALL avoids that and would
    # hold the whole plan in a Lua string, which at 19 MB it will not.
    got = keysize(d, os.path.basename(PLAN))
    if got is None:
        raise SystemExit('the instrument did not report the plan size on the key')
    if got != len(text):
        raise SystemExit('REFUSING to start: the key holds %d plan byte(s), not the %d sent.'
                         % (got, len(text)))
    print('  plan on the key: %d byte(s) verified, %d row(s)' % (got, len(rows)))


def send_lua(d, stmt):
    """Send ONE Lua statement, refusing to send anything that is not one line.

    EVERY STATEMENT THIS TOOL SENDS IS ONE LINE, and the instrument treats a newline as the end of a
    statement -- so a control character that leaks into the text does not produce a wrong result, it
    produces a SYNTAX ERROR ON THE PANEL. That happened: '[\\r\\n]' written as '[\r\n]' in a Python
    string put a real CR and LF inside a Lua string literal, and the DMM answered '-285 TSP Syntax error
    at line 1' in a box in front of the operator. Checked here rather than remembered, because the
    mistake is invisible in the source -- the Python and the Lua look identical.
    """
    bad = [c for c in stmt if ord(c) < 32]
    if bad:
        raise SystemExit('REFUSING to send a statement containing %r: the instrument would read it as '
                         'two statements and answer with a syntax error on the panel.\n  %r'
                         % (''.join(bad), stmt[:160]))
    # AND PARSED BY A REAL LUA 5.0.2 BEFORE IT LEAVES THE HOST, when one is built (tools/get_lua502.sh).
    # The statements in this file are Lua assembled by Python, which is the one kind of source no linter
    # in the repo ever looked at -- tsp/ and bench/ are checked, and these were not. A few milliseconds
    # here is the difference between a refusal in a terminal and a box on the instrument's panel.
    errs = lint_tsp.parse502('<statement>', stmt, LUAC) if LUAC else []
    if errs:
        raise SystemExit('REFUSING: Lua 5.0.2 will not parse this statement.\n  %s\n  %r'
                         % ('\n  '.join(errs), stmt[:200]))
    d.send(stmt)


def qtag(d, cmd, tag, timeout=60):
    """Send `cmd` and read until a line carrying `tag`. -> the text after the tag, or None.

    NOT d.q(), WHICH READS EXACTLY ONE LINE. Every d.exec() before this one appends its own __OK__
    sentinel, so a single missed read leaves one in the buffer and the next q() returns THAT instead of
    the answer -- which is how a plan-length check came back as the literal string '__OK__' and the
    verification died on int(). Scanning for a tag is immune to a stray line, and cannot silently accept
    the wrong one.
    """
    d.drain()
    send_lua(d, cmd)
    t_end = time.time() + timeout
    while time.time() < t_end:
        ln = d.line(timeout=max(1, t_end - time.time()))
        if ln is None:
            continue
        if ln.startswith(tag):
            return ln[len(tag):].strip()
    return None


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def name83(base, ext):
    """A FAT short name as it appears in a directory entry: 8 characters of name, space padded, then
    the extension, all upper case. '/usb1/SERDEC/SOAK.csv' is stored as 'SOAK    CSV'."""
    return (base.upper() + '        ')[:8] + ext.upper()


def keyfiles(d):
    """-> {name: size} for the record files on the key, WITHOUT OPENING ANY OF THEM.

    NOTHING HERE MAY PROBE FOR A FILE, and that is the whole design of this function. file.open on a
    path that is not there posts event 2205 -- a box on the front panel of an instrument whose one
    inviolable rule is that it never shows one. The previous version of this fetch probed SOAK000.csv
    upward until a miss ended the search, which is one guaranteed popup per fetch: it fired the moment a
    run finished, in front of the operator, and it also found a STALE numbered file from an older session
    instead of the record the run had just written.

    THE DIRECTORY IS READ INSTEAD, which costs nothing -- measured in the attribution table: reading
    /usb1/SERDEC is 0 events, because the directory is there. It hands back the raw FAT table, and a
    32-byte entry carries the file's length little-endian at offset 28. So both questions -- is it there,
    and how long is it -- are answered by one read of something that exists. Measured on the key:
    'SOAK    CSV' at offset 7425 of a 16384-byte table, size 76514.

    Rolled files (SOAK2.csv and up, which brec.roll only writes if one run passes 256 MB) are looked for
    the same way, so a long run's continuation is never missed and never probed for.
    """
    cands = [('SOAK.csv', name83('SOAK', 'csv'))]
    cands += [('SOAK%d.csv' % i, name83('SOAK%d' % i, 'csv')) for i in range(2, 10)]
    tbl = ','.join('{"%s","%s"}' % c for c in cands)
    out = qtag(d, 'do local fh = file.open("%s", file.MODE_READ) local raw = nil '
                  'if fh ~= nil then raw = file.read(fh, file.READ_ALL) file.close(fh) end '
                  'local s = "" '
                  'if raw ~= nil then local c = {%s} local k '
                  '  for k = 1, table.getn(c) do '
                  '    local a = string.find(raw, c[k][2], 1, true) '
                  '    if a ~= nil then '
                  '      s = s .. c[k][1] .. ":" .. tostring(string.byte(raw, a+28) '
                  '          + string.byte(raw, a+29)*256 + string.byte(raw, a+30)*65536 '
                  '          + string.byte(raw, a+31)*16777216) .. " " end end end '
                  'print("KEYFILES=" .. s) end' % (USBDIR, tbl), 'KEYFILES=', timeout=90)
    if out is None:
        raise SystemExit('the instrument did not report the directory listing on the key')
    found = {}
    for tok in out.split():
        n, _, sz = tok.partition(':')
        try:
            found[n] = int(sz)
        except ValueError:
            pass
    return found


def fetch(d, out_dir):
    """Pull the record off the key, in line batches, reading not one byte past the end.

    READ IN BATCHES, not READ_ALL: the file is tens of MB after a week, and one string that size is more
    than the instrument will hand over in a single reply -- or hold.

    AND BOUNDED BY THE LENGTH FROM THE DIRECTORY, because 'read until it returns nil' means READING PAST
    THE END, and that posts 2201 'File read error' -- one popup per fetch, at the end, where it looks
    like the run failed. file.read(READ_LINE) hands back the newline (measured: a 72-character header line
    with a trailing byte 10), so summing the lengths counts bytes exactly and the loop can stop on the
    last line instead of discovering the end by falling off it.
    """
    os.makedirs(out_dir, exist_ok=True)
    found = keyfiles(d)
    if not found:
        raise SystemExit('no SOAK record on the key at %s -- has a run started?' % USBDIR)
    print('  on the key: %s' % ', '.join('%s %d byte(s)' % (k, v) for k, v in sorted(found.items())))
    local = os.path.join(out_dir, 'SOAK.csv')
    nline, nbyte = 0, 0
    with open(local, 'w') as f:
        for name in sorted(found):
            size = found[name]
            path = '%s/%s' % (USBDIR, name)
            d.exec('do _rd_fh = file.open("%s", file.MODE_READ) _rd_n = 0 end' % path)
            # ONE print PER LINE, and a tagged sentinel to end each batch. The first version used
            # io.write(table.concat(t)) to avoid the per-line overhead -- and TSP has no `io` table, so
            # the statement raised, nothing came back, and the fetch wrote a 0-line file that the judge
            # then correctly refused. print is the only output primitive here.
            while True:
                d.drain()
                send_lua(d, 'do local n = 0 local i for i = 1, 200 do '
                       'if _rd_n >= %d then break end '
                       'local l = file.read(_rd_fh, file.READ_LINE) '
                       'if l == nil then break end '
                       '_rd_n = _rd_n + string.len(l) n = n + 1 '
                       # \\r\\n, ESCAPED FOR PYTHON SO LUA RECEIVES THE ESCAPES. Written '[\r\n]' in a
                       # plain Python string, the interpreter substitutes a real CR and LF -- which lands
                       # INSIDE a Lua string literal, splits this one-line statement in two, and the
                       # instrument answers '-285 TSP Syntax error at line 1'. On the panel. It is the
                       # kind of bug that only ever shows up on hardware, and send_lua below now refuses
                       # any statement carrying a control character rather than letting it reach the box.
                       'print("L|" .. string.gsub(l, "[\\r\\n]", "")) end '
                       'print("===BATCH=== " .. tostring(n) .. " " .. tostring(_rd_n)) end' % size)
                got, at, done = 0, 0, False
                while True:
                    ln = d.line(timeout=120)
                    if ln is None:
                        done = True
                        break
                    if ln.startswith('===BATCH==='):
                        parts = ln.split()
                        got, at = int(parts[-2] or 0), int(parts[-1] or 0)
                        break
                    if ln.startswith('L|'):
                        f.write(ln[2:] + '\n')
                        nline += 1
                if done or got == 0 or at >= size:
                    nbyte += at
                    break
            d.exec('do file.close(_rd_fh) _rd_fh = nil end')
    print('  %d line(s), %d byte(s) -> %s' % (nline, nbyte, local))
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
    ap.add_argument('--random-per-lap', type=int, default=None, metavar='N',
                    help='play only N of the twelve random-payload vectors each lap (they are 31 %% of '
                         'a lap and produced no failures of either kind on a full offline lap). N=4 '
                         'takes a lap from 2.07 h to 1.64 h')
    ap.add_argument('--push-plan', action='store_true', help='write the plan onto the key first')
    ap.add_argument('--no-load', action='store_true', help='the app and engine are already loaded')
    ap.add_argument('--start', action='store_true', help='start the loop and disconnect')
    ap.add_argument('--detach', action='store_true',
                    help='start and let go of the socket, whatever the iteration count')
    ap.add_argument('--fetch', action='store_true', help='pull the newest record off the key')
    ap.add_argument('--judge', default=None, help='judge a fetched record')
    ap.add_argument('--resume', action='store_true',
                    help='carry on after the last cell the record on the key already holds, instead of '
                         'starting at the top of the plan. Refuses if the plan does not contain that '
                         'cell, because that means it is not the plan that produced the record')
    ap.add_argument('--sdg-hold', type=int, default=None, metavar='SECS',
                    help='seconds between retries when the generator goes silent. The engine already '
                         'holds -- a fault reports itself and the run carries on until it is stopped -- '
                         'so this only changes the PERIOD. 0 restores the old behaviour of parking the '
                         'run, which a multi-day soak should never ask for: a wedge on day 2 then costs '
                         'every day after it')
    ap.add_argument('--listen', default=None, metavar='IP',
                    help='host address for live progress pushes (see tools/soak_listen.py)')
    # A PLAN ALREADY GENERATED, because generating 210 laps takes ~5 minutes of CPU and needs no
    # instrument -- so it must not sit inside a limited access window. The file is soakplan --emit-csv's
    # own output, header lines included.
    ap.add_argument('--plan-file', default=None, metavar='PATH',
                    help='push this already-generated plan instead of regenerating it')
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
    if a.push_plan and a.plan_file:
        # REFUSES A PLAN THAT DOES NOT DECLARE ITS OWN ROW COUNT, because the instrument stops reading at
        # the declared count: without it the loop reads past EOF and posts 2201 on the panel.
        with open(a.plan_file) as f:
            rows = [ln for ln in f.read().split('\n') if ln.strip()]
        ndecl = None
        for ln in rows[:8]:
            m = re.search(r'rows=(\d+)', ln)
            if m:
                ndecl = int(m.group(1))
        ndata = len([x for x in rows if x and x[0].isdigit()])
        if ndecl is None or ndecl != ndata:
            raise SystemExit('REFUSING: %s declares rows=%s but holds %d data row(s).'
                             % (a.plan_file, ndecl, ndata))
        print('plan: %d line(s) from %s (%d data rows, declared %d)'
              % (len(rows), a.plan_file, ndata, ndecl))
    elif a.push_plan:
        argv = ['python3', os.path.join(ROOT, 'tools', 'soakplan.py'), '--emit-csv',
                '--iteration', str(a.iteration)]
        if a.spec:
            argv += ['--spec', a.spec]
        else:
            argv += ['--iterations', str(max(a.iteration, a.iteration + max(a.iterations, 1) - 1)),
                     '--skip-vectors', a.skip_vectors]
            if a.random_per_lap is not None:
                argv += ['--random-per-lap', str(a.random_per_lap)]
        text = subprocess.check_output(argv, cwd=ROOT).decode()
        rows = [ln for ln in text.split('\n') if ln.strip()]
        print('plan: %d line(s)%s' % (len(rows), (' spec %s' % a.spec) if a.spec else ''))

    d = DMM()
    try:
        if not a.no_load:
            print('loading the app and the bench engine')
            load_modules(d, APP + ENGINE)
        if a.push_plan:
            push_plan(d, rows)
        if a.fetch and not a.start:
            fetch(d, a.out)
            return 0
        if a.start:
            if a.resume:
                if not d.exec('do brun.resume = true end'):
                    raise SystemExit('the instrument would not accept the resume flag')
                print('  resuming after the last cell the record holds')
            if a.sdg_hold is not None:
                # SET BEFORE THE RUN STARTS, because brun.soak reads it at the give-up point and nothing
                # can reach the instrument once the loop holds the interpreter.
                #
                # `is not None` AND NOT TRUTHINESS, so that --sdg-hold 0 is honoured rather than silently
                # dropped. It is the one value that changes the CONTRACT rather than a period -- it puts
                # the run back to parking on a fault -- so it is said out loud instead of ignored.
                if not d.exec('do brun.holdsecs = %d end' % a.sdg_hold):
                    raise SystemExit('the instrument would not accept the generator hold interval')
                if a.sdg_hold > 0:
                    print('  generator hold: retry every %d s' % a.sdg_hold)
                else:
                    print('  generator hold DISABLED: a silent generator will PARK this run, and a '
                          'parked run cannot be restarted by anyone who is not standing there')
            if a.listen:
                d.exec('do brun.listenip = %s end' % lua_str(a.listen))
            # STARTED AND LEFT. The call does not return until the loop ends, so it is sent without
            # waiting for a reply -- and for --iterations 0 there is no reply to wait for at all.
            print('starting brun.soak(%d) on the instrument' % a.iterations)
            # A SENTINEL, because brun.soak prints nothing: it writes to the key. Without one the host
            # waits the full timeout for a line that is never coming and then reports "(nothing)" on a
            # run that finished perfectly well.
            d.send('brun.soak(%d, "%s") print("===SOAKDONE=== " .. tostring(brun.stopwhy))'
                   % (a.iterations, 'smoke' if a.smoke else 'soak'))
            # LET GO OF THE SOCKET, WHATEVER THE COUNT. A finite run is normally waited for because the
            # point of --smoke is a verdict now -- but a 1677-cell lap is about two hours, and holding the
            # instrument's one control socket for two hours is the opposite of what this engine is for.
            # The run does not care: the statement is already executing on the instrument, and closing the
            # socket does not abort it. Its output simply goes nowhere, which is why the record is on the
            # key rather than in this terminal.
            if a.iterations == 0 or a.detach:
                print('  running on the instrument. The host is out of the way now:')
                print('    stop it with the front-panel TRIGGER key -- the run ends after the current')
                print('    waveform and CLOSES the record, which is what commits it on a FAT key')
                print('    (or cut the power, which costs at most the last row)')
                print('    then: python3 tools/run_bench.py --fetch --no-load')
                return 0
            # A FINITE RUN IS WAITED FOR, because the point of --smoke is a verdict now. 86 cells at
            # ~6 s is ~9 min; the timeout is generous because a slow cell is not a failure.
            secs = 60 + 12 * (len(rows) if rows else 1700)
            print('  waiting up to %.0f min for %d iteration(s)' % (secs / 60.0, a.iterations))
            line = None
            t_end = time.time() + secs
            while time.time() < t_end:
                line = d.line(timeout=min(60, max(5, t_end - time.time())))
                if line is None:
                    continue
                if '===SOAKDONE===' in line:
                    break
                # Anything else the instrument says is worth seeing: a raise inside the loop arrives
                # here rather than on the key.
                print('  %s' % line.strip())
            print('  instrument said: %s' % (line or '(nothing -- timed out)'))
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

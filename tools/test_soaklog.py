#!/usr/bin/env python3
"""soak.py must keep every lap's per-cell output, ESPECIALLY the lap the bench died under.

WHAT IS AT STAKE. A lap the generator wedges under can have measured 33 of its 41 vectors x 43 rates
first, about 1400 cells, and the exit-3 path is the one that ends the run -- so it is also the path
whose evidence is easiest to lose. An unwritten log is indistinguishable from a clean one: `grep -c
2208` over text that was never written answers 0, and 0 reads as "the app filed no instrument events".

So every assertion here is paired with its negative. Checking that the log FILE EXISTS is not enough --
a zero-byte file passes that and is the bug again -- so each case also asserts the per-cell content is
in it, and the no-evidence case asserts the run refuses to call itself clean.

Touches no instrument: main() only opens one when --record-every > 0, which none of these pass.

    python3 tools/test_soaklog.py
"""
import glob
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

import soak                                                                    # noqa: E402

PASS, FAIL = [0], []


def ck(what, got, want):
    if got == want:
        PASS[0] += 1
    else:
        FAIL.append('%s: got %r, wanted %r' % (what, got, want))


def ck_in(what, needle, hay):
    if needle in hay:
        PASS[0] += 1
    else:
        FAIL.append('%s: %r not found in %r' % (what, needle, hay[:200]))


def ck_not_in(what, needle, hay):
    if needle not in hay:
        PASS[0] += 1
    else:
        FAIL.append('%s: %r should NOT be in %r' % (what, needle, hay[:200]))


# A LAP'S OUTPUT AS THE CHILD WOULD HAVE PRINTED IT: per-cell rows, and an instrument event of exactly
# the kind that has to survive to disk to be greppable afterwards.
LAP_OUT = '\n'.join([
    '  v47    exact: 43 cells in 235 s (5.46 s/cell) at 10.0 Vpp, 0 not as expected',
    '  r11    9600 Bd    ok    8N1    thr 1.55   9600 Bd  38 B, longest clean run 38',
    '      *** unexpected event 2208 ***',
    '  v63    19200 Bd   BAD   8N1    thr 1.55  19200 Bd  0 B, line is idle (no transitions)',
]) + '\n'


def run_soak(argv, stub):
    """Drive main() with run_suite stubbed. Returns (exit code, stdout, record dir)."""
    out = tempfile.mkdtemp(prefix='soaklog-')
    real_suite, real_awake = soak.run_suite, soak.hold_awake
    real_argv, real_stdout = sys.argv, sys.stdout

    class Cap:
        def __init__(self):
            self.buf = []

        def write(self, s):
            self.buf.append(s)

        def flush(self):
            pass

    cap = Cap()
    try:
        soak.run_suite = stub
        # NOT THE REAL ONE: hold_awake spawns caffeinate, and a test must not leave a process behind.
        soak.hold_awake = lambda: 'stubbed, no sleep guard'
        sys.argv = ['soak.py', '--out', out, '--suites', 'formats'] + argv
        sys.stdout = cap
        rc = soak.main()
    finally:
        soak.run_suite, soak.hold_awake = real_suite, real_awake
        sys.argv, sys.stdout = real_argv, real_stdout
    rec = sorted(glob.glob(os.path.join(out, '*')))
    return rc, ''.join(cap.buf), (rec[0] if rec else out), out


def logs_in(rec):
    return sorted(os.path.basename(p) for p in glob.glob(os.path.join(rec, 'lap*.log')))


def jsonl_rows(rec):
    p = os.path.join(rec, 'laps.jsonl')
    if not os.path.exists(p):
        return []
    with open(p) as fh:
        return [json.loads(ln) for ln in fh if ln.strip()]


print('=== 1. THE BENCH DIES (exit 3): the lap output must survive ===')
# The regression case. Points ARE returned: the lap measured plenty before the wedge, which is exactly
# why throwing its output away was so costly.
rc, so, rec, tmp = run_soak(
    ['--laps', '3'],
    lambda *args, **kw: (3, LAP_OUT, {'v63@std': ('ok', 'fine'), 'r11@std': ('ok', 'fine')}, None))
names = logs_in(rec)
ck('one lap log written', names, ['lap0001-STOPPED.log'])
body = open(os.path.join(rec, names[0])).read() if names else ''
# NOT MERELY NON-EMPTY. A zero-byte file would satisfy "exists", and that is the defect restated.
ck('the log is not empty', len(body) > 0, True)
ck_in('per-cell rows survived', 'r11    9600 Bd    ok', body)
ck_in('the instrument event survived to disk', '*** unexpected event 2208 ***', body)
ck_in('a BAD cell survived', 'line is idle (no transitions)', body)
# THE POINT OF ALL OF IT: the grep that returned a false 0 must now return a true 1.
ck('grepping the kept log for 2208 finds it', body.count('2208'), 1)
rows = jsonl_rows(rec)
ck('a jsonl row was written for the dead lap', len(rows), 1)
if rows:
    ck('the row says the bench stopped', rows[0].get('incomplete'), 'the bench stopped answering')
    ck('the row names its log', os.path.basename(rows[0].get('log', '')), 'lap0001-STOPPED.log')
    ck('the row keeps the point count', rows[0].get('npoints'), 2)
ck_in('the summary says where the evidence is', 'output kept in', so)
ck_in('the summary lists the per-lap logs', 'per-cell output, every lap: lap0001-STOPPED.log', so)
# A RUN THAT TALLIED NOTHING MUST NOT REPORT SUCCESS. This returned 0 before: the incomplete-fraction
# test is `1 >= max(3, 1 // 4)`, which is false, so both wedged nights exited 0 to their caller.
ck('exit 2, not 0 -- nothing was tallied', rc, 2)
ck_in('and it says so', 'REFUSING TO CALL THIS A CLEAN RUN', so)
# IT MUST ALSO STOP. Running further laps against a dead bench is what exit 3 exists to prevent.
ck('it stopped after the dead lap despite --laps 3', len(names), 1)
shutil.rmtree(tmp, ignore_errors=True)

print('=== 2. A CLEAN LAP: still logged, still exit 0 ===')
# THE NEGATIVE DIRECTION. A fix that wrote the log only on the failure path, or that broke the healthy
# path's verdict, would pass case 1 and be useless.
rc, so, rec, tmp = run_soak(
    ['--laps', '2'],
    lambda *args, **kw: (0, LAP_OUT, {'v63@std': ('ok', 'fine')}, None))
names = logs_in(rec)
ck('both clean laps kept their output', names, ['lap0001-ok.log', 'lap0002-ok.log'])
body = open(os.path.join(rec, names[0])).read() if names else ''
ck_in('a clean lap keeps its per-cell rows too', 'r11    9600 Bd    ok', body)
# WHY A CLEAN LAP'S LOG MATTERS: issue #118 is stages reporting 0 BAD while filing instrument events.
# Auditing that after the fact is only possible if the clean laps kept their text.
ck_in('a clean lap keeps its instrument events, for #118', '2208', body)
ck('a clean run exits 0', rc, 0)
ck_not_in('and does not refuse', 'REFUSING', so)
ck('no lap was called incomplete', jsonl_rows(rec) and rows is not None, True)
shutil.rmtree(tmp, ignore_errors=True)

print('=== 3. A BAD POINT: tagged FAILED, exit 1 ===')
rc, so, rec, tmp = run_soak(
    ['--laps', '1'],
    lambda *args, **kw: (1, LAP_OUT, {'v63@std': ('BAD', 'line is idle')}, None))
ck('the failing lap is tagged FAILED', logs_in(rec), ['lap0001-FAILED.log'])
body = open(os.path.join(rec, 'lap0001-FAILED.log')).read()
ck_in('with its output', 'line is idle (no transitions)', body)
ck('a bad point exits 1', rc, 1)
shutil.rmtree(tmp, ignore_errors=True)

print('=== 4. INCOMPLETE (a summary that disagreed with itself): kept and named ===')
rc, so, rec, tmp = run_soak(
    ['--laps', '1'],
    lambda *args, **kw: (0, LAP_OUT, {}, 'the summary counted 0 points'))
ck('the incomplete lap is tagged INCOMPLETE', logs_in(rec), ['lap0001-INCOMPLETE.log'])
body = open(os.path.join(rec, 'lap0001-INCOMPLETE.log')).read()
ck_in('with its output', '*** unexpected event 2208 ***', body)
rows = jsonl_rows(rec)
ck('its row names its log', os.path.basename(rows[0].get('log', '')) if rows else '',
   'lap0001-INCOMPLETE.log')
ck_in('the summary says where it is', 'output in', so)
shutil.rmtree(tmp, ignore_errors=True)

print('=== 5. THE HEARTBEAT: every field formats, and "unexpected" means only an instrument event ===')
# THE HEARTBEAT IS THE ONLY LIVE SIGNAL a monitor has: the child's stdout is captured by soak.py and not
# printed until the lap ends, so these lines are all anyone can see for up to three hours.
#
# THE FAILURE MODE THIS GUARDS is a %-argument mismatch. beat() swallows exceptions by design -- "a
# monitoring aid must never fail a run" -- so a miscounted format string does not crash the soak, it
# silently stops writing heartbeats, and the run goes dark for the night with no error anywhere. Every
# beat() call is therefore formatted here with dummy arguments, which is the only way to prove the
# specifiers and the tuple agree.
import ast                                                                     # noqa: E402

BM = os.path.join(ROOT, 'tools', 'bench_matrix.py')
with open(BM) as fh:
    src = fh.read()
tree = ast.parse(src)

DUMMY = {int: 7, float: 1.5, str: 'x'}


def fmt_of(node):
    """The format string and argument count of a `beat(a, FMT % (args))` call, or None."""
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'beat'):
        return None
    if len(node.args) < 2 or not isinstance(node.args[1], ast.BinOp):
        return None
    if not isinstance(node.args[1].op, ast.Mod):
        return None
    left, right = node.args[1].left, node.args[1].right
    try:
        f = ast.literal_eval(left)                      # handles implicit string concatenation
    except ValueError:
        return None
    n = len(right.elts) if isinstance(right, ast.Tuple) else 1
    return f, n


beats = [r for r in (fmt_of(n) for n in ast.walk(tree)) if r]
ck('both heartbeat lines found', len(beats) >= 2, True)
for f, n in beats:
    # %% is a literal percent and consumes no argument; none are used here, but count honestly.
    spec = f.count('%') - 2 * f.count('%%')
    ck('specifiers match arguments in %r' % f[:34], spec, n)
    # AND ACTUALLY FORMAT IT. Counting specifiers cannot catch %d against a string.
    args = []
    i = 0
    while i < len(f):
        if f[i] == '%' and i + 1 < len(f):
            j = i + 1
            while j < len(f) and f[j] not in 'diouxXeEfFgGcrsa%':
                j += 1
            c = f[j] if j < len(f) else 's'
            if c != '%':
                args.append(DUMMY[float] if c in 'eEfFgG' else DUMMY[int] if c in 'diouxX' else 'x')
            i = j + 1
        else:
            i += 1
    try:
        line = f % tuple(args)
        PASS[0] += 1
    except (TypeError, ValueError) as e:
        line = ''
        FAIL.append('the heartbeat format raises: %s -- %r' % (e, f[:60]))
    if 'DONE' in f:
        # THE RENAME. nbadcell is "cells that did not decode as expected"; "unexpected" is this
        # project's word for an unexpected INSTRUMENT event, and the two readings differ by orders of
        # magnitude. v96's 22 known-bad cells read as 22 instrument events, and a loud impairment
        # vector doing its job read as an alarm -- it mis-briefed a monitor once already.
        ck_in('the DONE line reports badcells', 'badcells', f)
        ck_not_in('and never calls them "unexpected"', 'unexpected', f)
        # THE FIELD A MONITOR ACTUALLY NEEDS, which the heartbeat could not show at all before.
        ck_in('the DONE line reports the instrument-event count', 'events', f)
        ck_in('and still carries both liveness footers', 'DMM=', f)
        ck_in('SDG footer present', 'SDG=', f)
        ck_in('a formatted DONE line looks right', 'badcells', line)

print()
if FAIL:
    for f in FAIL:
        print('  BAD  %s' % f)
    print('\n%d passed, %d BAD' % (PASS[0], len(FAIL)))
    sys.exit(1)
print('%d passed, 0 BAD' % PASS[0])
sys.exit(0)

#!/usr/bin/env python3
"""Gates run_bench.push_plan: does the acknowledged-batch handshake put the plan on the key intact?

A fortnight needs ~280 000 plan rows on the key, and all communication with the DMM is over the LAN. Two
ways were tried on hardware and failed: executed statements overran the input buffer CUMULATIVELY (-363 at
row 21, then 921, then 921 again -- a throttle bounds the sender, not the gap to the interpreter), and
loadscript needs 25 chunks whose reloads each log -104. So every batch is acknowledged with a running row
total before the next is sent.

TESTED HERE BECAUSE IT IS A PROTOCOL, and the failures worth catching are disagreements between the two
ends -- a batch silently short, an acknowledgement that skips, a handle that closed. None can be provoked
on hardware on purpose, and the first real 19 MB push carries the fortnight.

    python3 tools/test_pushplan.py
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

import run_bench as RB                                                  # noqa: E402
import soakplan as SP                                                    # noqa: E402

PASS, FAIL = [], []


def check(what, cond, detail=''):
    (PASS if cond else FAIL).append(what)
    print('  %s %s%s' % ('ok  ' if cond else 'FAIL', what, ('   ' + detail) if detail else ''))


class FakeDMM:
    """The instrument side of the push, as the Lua in push_plan would behave.

    `_pw`/`_pn` are the interpreter's globals; the acknowledgement carries `_pn`, the count of rows IT
    believes it has. lose / miscount / closehandle each model a real failure: bytes that did not land, a
    count that drifts from the host's, and a handle that went away mid-push.
    """

    def __init__(self, lose=None, miscount=None, closehandle=None):
        self.files = {}
        self.pw = None
        self.pn = 0
        self.out = []
        self.stmts = 0
        self.lose = lose or set()          # batch indices (1-based) whose rows do not land
        self.miscount = miscount or {}     # batch index -> the count to report instead
        self.closehandle = closehandle     # batch index at which _pw becomes nil
        self.nbatch = 0

    # -- the transport ------------------------------------------------------
    def drain(self):
        self.out = []

    def line(self, timeout=None):
        return self.out.pop(0) if self.out else None

    def send(self, cmd):
        self.stmts += 1
        self._run(cmd)

    def exec(self, cmd, timeout=30):
        self._run(cmd)
        return True

    # -- the interpreter ---------------------------------------------------
    def _run(self, cmd):
        m = re.search(r'_pw = file\.open\("([^"]+)", file\.MODE_WRITE\)', cmd)
        if m:
            self.pw = m.group(1)
            self.files[self.pw] = ''
            self.pn = 0
            return
        m = re.search(r'file\.write\(_pw, "(.*)"\) _pn = _pn \+ (\d+)', cmd, re.S)
        if m:
            self.nbatch += 1
            if self.closehandle is not None and self.nbatch >= self.closehandle:
                self.pw = None
            if self.pw is None:
                self.out.append('PW=-1')
                return
            payload, n = m.group(1), int(m.group(2))
            if self.nbatch not in self.lose:
                # THE TWO CHARACTERS BACKSLASH-N BECOME ONE REAL NEWLINE, which is the whole point of
                # writing them that way: the STATEMENT stays a single line so nothing splits it in the
                # input buffer, and the FILE gets real line endings.
                self.files[self.pw] += payload.replace('\\n', '\n')
                self.pn += n
            self.out.append('PW=%d' % self.miscount.get(self.nbatch, self.pn))
            return
        if 'file.close(_pw)' in cmd:
            self.pw = None
            return
        # keysize(): the FAT directory entry, which is where the length really comes from.
        if 'KEYSIZE=' in cmd:
            path = RB.PLAN
            n = len(self.files.get(path, '')) if path in self.files else -1
            self.out.append('KEYSIZE=%d' % n)
            return


def plan_rows(n):
    """Real rows from the real generator, not invented ones: the push refuses quotes and backslashes, and
    only soakplan.py can say whether its own output contains any."""
    out = subprocess.check_output(
        ['python3', os.path.join(ROOT, 'tools', 'soakplan.py'), '--emit-csv',
         # FROM soakplan.HW_SKIP, NOT A COPY OF IT. A hardcoded skip list here silently measures a
         # different lap the moment a vector is added to vector_names.MAP -- the assertion below is on
         # the ROW COUNT of a 210-lap plan, so it fails with a size complaint that says nothing about
         # the actual change. Deriving it means this test tracks the bench's own definition.
         '--iteration', '1', '--iterations', str(n), '--skip-vectors', ','.join(SP.HW_SKIP),
         '--random-per-lap', '4'], cwd=ROOT).decode()
    return [ln for ln in out.split('\n') if ln.strip()]


print('test_pushplan: the acknowledged-batch plan push, offline')
print('')

ROWS = plan_rows(2)
print('-- the plan arrives intact --')
d = FakeDMM()
RB.push_plan(d, ROWS)
got = d.files[RB.PLAN]
want = '\n'.join(ROWS) + '\n'
check('every row lands, exactly once, in order', got == want,
      '%d byte(s) on the key, %d sent' % (len(got), len(want)))
check('and the key holds as many lines as the host sent',
      got.count('\n') == len(ROWS), '%d vs %d' % (got.count('\n'), len(ROWS)))
# THE BATCH SIZE IS PART OF THE CONTRACT, not an implementation detail: it is what bounds how far ahead of
# the interpreter the host can get, and 20 rows was chosen because working statements measured ~700 chars.
nb = (len(ROWS) + RB.PUSH_BATCH_ROWS - 1) // RB.PUSH_BATCH_ROWS
check('one acknowledged batch per %d rows' % RB.PUSH_BATCH_ROWS, d.nbatch == nb,
      '%d batch(es) for %d row(s)' % (d.nbatch, len(ROWS)))
longest = max(len(r) for r in ROWS)
stmt = longest * RB.PUSH_BATCH_ROWS + 200
# MEASURED ON THE INSTRUMENT, AND IT SETTLED THE QUESTION THIS COMMENT USED TO LEAVE OPEN. A 20-row batch
# is a ~1960-character statement and the DMM6500 answers -363 'input buffer overrun' on the panel within
# seconds -- even though the handshake means the host is never more than ONE statement ahead, so the buffer
# is smaller than a single statement of that size. At 5 rows (~640 chars) the identical code pushed 279 934
# rows / 18.9 MB clean at 571 rows/s. Only the statement size changed between the two.
#
# 1024 IS THE GATE, not 2048: it is above the ~640 that works and well below the ~1960 that does not, so
# raising PUSH_BATCH_ROWS back toward 20 fails here instead of on the panel.
check('a batch statement stays under the size the instrument answered -363 at',
      stmt < 1024, 'longest row %d -> ~%d char statement (640 works, 1960 overruns)' % (longest, stmt))

print('')
print('-- what the handshake is FOR: it must refuse, not report success --')


def refuses(what, **kw):
    """-> the SystemExit message, or None if the push claimed success."""
    d = FakeDMM(**kw)
    try:
        RB.push_plan(d, ROWS)
    except SystemExit as e:
        return str(e)
    return None


# A BATCH WHOSE BYTES DID NOT LAND is the failure the whole handshake exists to catch, and the one a
# throttle cannot: the host sent them, the statement executed, and the file is short. The interpreter's
# own count is what gives it away.
why = refuses('lost batch', lose={3})
check('a batch that did not land is refused', why is not None and 'written' in (why or ''),
      (why or 'THE PUSH REPORTED SUCCESS')[:96])
# AN ACKNOWLEDGEMENT THAT DRIFTS from the host's count means the two disagree about what is on the key,
# and continuing would build the rest of the plan on top of that disagreement.
why = refuses('miscount', miscount={2: 999999})
check('an acknowledgement that disagrees with the host is refused',
      why is not None and 'written' in (why or ''),
      (why or 'THE PUSH REPORTED SUCCESS')[:96])
# THE HANDLE CLOSING UNDER THE PUSH is what a pulled key looks like from here, and PW=-1 is the
# instrument saying so rather than the host inferring it from silence.
why = refuses('handle closed', closehandle=4)
check('a write handle that closed is refused, by its own report',
      why is not None and 'handle closed' in (why or ''),
      (why or 'THE PUSH REPORTED SUCCESS')[:96])


# THE SIZE CHECK IS THE LAST LINE OF DEFENCE, and it has to be able to fail: it reads the FAT directory
# entry rather than counting lines, because a read past the end posts 2201 on the panel.
class ShortKey(FakeDMM):
    def _run(self, cmd):
        if 'KEYSIZE=' in cmd:
            self.out.append('KEYSIZE=%d' % (len(self.files.get(RB.PLAN, '')) - 1))
            return
        FakeDMM._run(self, cmd)


d = ShortKey()
try:
    RB.push_plan(d, ROWS)
    why = None
except SystemExit as e:
    why = str(e)
check('a key whose directory entry is one byte short refuses the start',
      why is not None and 'plan byte' in (why or ''),
      (why or 'THE PUSH REPORTED SUCCESS')[:96])

print('')
print('-- the size the fortnight will actually push --')
# MEASURED FROM THE REAL GENERATOR at the real setting, so the numbers in notes/SOAK-14DAY.md are
# checked rather than remembered.
n14 = 210 * len([r for r in ROWS if r and r[0].isdigit()]) // 2
bytes14 = int(210 * sum(len(r) + 1 for r in ROWS if r and r[0].isdigit()) / 2.0)
check('a 210-lap plan is the size the design says', 279000 < n14 < 281000 and bytes14 < 22 * 1024 * 1024,
      '%d rows, %.1f MB, %d batches' % (n14, bytes14 / 1048576.0,
                                        (n14 + RB.PUSH_BATCH_ROWS - 1) // RB.PUSH_BATCH_ROWS))
check('and it is inside PUSH_MAX_ROWS', n14 < RB.PUSH_MAX_ROWS,
      '%d of %d' % (n14, RB.PUSH_MAX_ROWS))

print('')
print('-- the header tag, which decides whether a resumed soak is one run or two --')
# judge_bench.split_runs TREATS 'roll' AND 'resumed' AS CONTINUATIONS and everything else as a new run,
# because the record is one append-only file and the header is all that separates runs in it. So this
# one string decides whether a hundred-lap soak stopped and resumed halfway is judged as a hundred laps
# or as the fifty after the seam -- the judge's default being the LAST run. It was 'soak' either way.


class _A(object):
    def __init__(self, **kw):
        self.smoke = False
        self.resume = False
        for k, v in kw.items():
            setattr(self, k, v)


check('a plain soak is tagged soak', RB.run_tag(_A()) == 'soak', RB.run_tag(_A()))
check('a resumed soak is tagged resumed, which the judge reads as a CONTINUATION',
      RB.run_tag(_A(resume=True)) == 'resumed', RB.run_tag(_A(resume=True)))
# AND THE TAG IS ONE THE JUDGE ACTUALLY HONOURS. Asserting the literal 'resumed' against a hand-typed
# copy would pass while split_runs looked for something else -- so the judge's own list is the oracle.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge_bench as JB                                                        # noqa: E402
_seam = JB.split_runs(['# %s tag=soak' % JB.SCHEMA, 'R,1,1,x', 'R,1,2,x',
                       '# %s tag=%s' % (JB.SCHEMA, RB.run_tag(_A(resume=True))), 'R,1,3,x'])
check('and the judge merges the resumed rows into the run above them, rather than splitting',
      len(_seam) == 1 and len(_seam[0][1]) == 3,
      '%d run(s), %s row(s)' % (len(_seam), [len(b) for _, b in _seam]))
_split = JB.split_runs(['# %s tag=soak' % JB.SCHEMA, 'R,1,1,x', 'R,1,2,x',
                        '# %s tag=%s' % (JB.SCHEMA, RB.run_tag(_A())), 'R,1,3,x'])
check('while a plain soak start after one really is a second run -- the check can fail',
      len(_split) == 2, '%d run(s)' % len(_split))

# ---------------------------------------------------------------------------- the smoke-poison refusal
#
# A soak started after a smoke fails EVERY cell with "acq: line is idle (no transitions)" until the DMM
# is power cycled -- three occurrences, the last one 705 of 705 cells. refuse_smoke_poison blocks that
# combination, and what is tested here is the DECISION TABLE rather than the message: the refusal has to
# fire on "a smoke ran and nothing was cycled", and has to stay silent on everything else, because a
# guard that refuses a legitimate soak would be worse than the defect it prevents.
#
# THE PROBE CALL IS COUNTED, NOT JUST THE VERDICT. The instrument is only asked about sdec when the
# receipt is recent enough to matter; a stale receipt must not open a socket conversation at all. A
# verdict test alone would pass on an implementation that probed every time and then ignored it.
import json as _json                                                            # noqa: E402
import shutil as _shutil                                                        # noqa: E402
import tempfile as _tmp                                                         # noqa: E402
import time as _time                                                            # noqa: E402

_real_root, _real_qtag = RB.ROOT, RB.qtag
_probes = []


class _Args(object):
    def __init__(self, after_cycle=False):
        self.start, self.after_cycle = True, after_cycle


def _poison_case(hours_ago, sdec_type, after_cycle=False, receipt=True):
    """-> ('refused'|'allowed', probe_count). Builds a receipt of a chosen age in a temp ROOT."""
    root = _tmp.mkdtemp()
    try:
        if receipt:
            os.makedirs(os.path.join(root, 'out'))
            stamp = _time.strftime('%Y-%m-%dT%H:%M:%S',
                                   _time.localtime(_time.time() - hours_ago * 3600.0))
            with open(os.path.join(root, 'out', 'smoke-receipt.json'), 'w') as fh:
                _json.dump({'stamp': stamp, 'tree': 'f' * 16}, fh)
        del _probes[:]
        RB.ROOT = root
        RB.qtag = lambda d, cmd, tag, timeout=60: (_probes.append(cmd), sdec_type)[1]
        try:
            RB.refuse_smoke_poison(None, _Args(after_cycle=after_cycle))
            return 'allowed', len(_probes)
        except SystemExit as e:
            return ('refused' if 'power cycle' in str(e).lower() else 'refused-wrong-reason',
                    len(_probes))
    finally:
        RB.ROOT, RB.qtag = _real_root, _real_qtag
        _shutil.rmtree(root, ignore_errors=True)


_v, _n = _poison_case(1.0, 'table')
check('a soak started 1 h after a smoke with the app still loaded is REFUSED, naming the power cycle',
      _v == 'refused', '%s, %d probe(s)' % (_v, _n))
_v, _n = _poison_case(1.0, 'nil')
check('and the same receipt passes once the DMM has been cycled -- sdec nil is the evidence',
      _v == 'allowed', '%s, %d probe(s)' % (_v, _n))
_v, _n = _poison_case(1.0, 'table', after_cycle=True)
check('--after-cycle overrides it, for a cycle followed by a non-smoke load',
      _v == 'allowed', '%s, %d probe(s)' % (_v, _n))
_v, _n = _poison_case(13.0, 'table')
check('a smoke 13 h old does not block a soak, AND does not even ask the instrument',
      _v == 'allowed' and _n == 0, '%s, %d probe(s)' % (_v, _n))
_v, _n = _poison_case(0, 'table', receipt=False)
check('no receipt is not evidence of a smoke, so it passes without a probe',
      _v == 'allowed' and _n == 0, '%s, %d probe(s)' % (_v, _n))
check('and the guard was restored: ROOT and qtag are the real ones again',
      RB.ROOT == _real_root and RB.qtag is _real_qtag)

print('')
if FAIL:
    print('%d FAILED: %s' % (len(FAIL), ', '.join(FAIL)))
    sys.exit(1)
print('%d passed, 0 failed' % len(PASS))

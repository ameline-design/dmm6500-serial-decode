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
         '--iteration', '1', '--iterations', str(n), '--skip-vectors', 'v95,v96',
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
if FAIL:
    print('%d FAILED: %s' % (len(FAIL), ', '.join(FAIL)))
    sys.exit(1)
print('%d passed, 0 failed' % len(PASS))

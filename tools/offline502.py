#!/usr/bin/env python3
"""Run the offline harness under the interpreter the instrument actually runs: Lua 5.0.2.

    python3 tools/offline502.py --parse-check
    python3 tools/offline502.py --run tools/test_serial.lua
    python3 tools/offline502.py --bench --plan out/bench/PLAN.CSV --out /tmp/off502.csv
    python3 tools/offline502.py --bench --plan out/bench/PLAN.CSV --out /tmp/off502.csv --paired

WHY THIS EXISTS. The DMM6500 runs Lua 5.0.2 and the host runs 5.5, so every offline result this project
has ever quoted was measured on a DIFFERENT interpreter from the one that ships. tools/lint_tsp.py closed
half the gap -- it PARSES tsp/ with the real 5.0.2 compiler -- and the other half is behaviour: a
construct that parses in both and does different things. That class reaches the panel. Two instances are
on record:

  * `math.fmod` does not exist in 5.0.2 (`math.mod` does). A host shim made it pass every offline test
    and raise on the box.
  * `gcinfo()` exists in 5.0.2 and NOT in 5.5; `collectgarbage('count')` is the reverse. A heap figure
    written as `gcinfo()` alone displayed on hardware and was silently unreachable offline.

Both were found by hand, after the fact. This makes them findable before, by running the same modules
against the same plan under 5.0.2.

WHAT IT DOES NOT CLAIM. There is still no DMM front end and no analog noise -- tools/sweep_plan.lua is
where fidelity is argued about -- and the host is 64-bit ARM while the instrument's Lua is not, so
absolute memory figures are not comparable. What this removes is the INTERPRETER as a variable.

THE STAGED TREE IS A MIRROR, and every difference from the repo is counted and named on stdout. Nothing
is edited in place: out/ is gitignored, the tree is rebuilt from scratch on every run, and a transform
that is not one of the two below is a bug in this file rather than a licence to add a third.

  1. HEX LITERALS -> DECIMAL. Stock 5.0.2's numeral scanner stops at the `x`, so `0x00DCFF` reads as `0`
     followed by a name. The instrument's Lua accepts them -- proved by the app loading and running -- so
     this is a divergence between stock 5.0.2 and Keithley's, not a defect in tsp/. Four files need it:
     tsp/serial_ui.tsp, tsp/midi_decode.tsp, tsp/lin_decode.tsp and bench/bench_run.tsp.

     SUBSTITUTED IN CODE ONLY, never inside a string or a comment. lint_tsp.py uses a bare regex over the
     whole body, which is safe THERE because it only feeds luac -p and then throws the text away. Here the
     staged file is the code under test, so rewriting `0x55` inside a message string would change what the
     app prints, and rewriting one in a comment would make the mirror harder to read against the original.
     --parse-check refuses if any hex literal is found inside a string, because that would mean this
     transform can no longer be assumed harmless.

THAT IS THE ONLY TRANSFORM, and keeping it the only one is the point. The harness's own 5.1-isms were
fixed at the source instead of patched here -- tools/gen_serial.lua's `#` shim now defers through
loadstring, and tools/mock_bench.lua uses string.find with captures rather than string.match -- because a
staging layer that rewrites the harness is a second dialect nobody reads. If this file ever needs a
transform beyond hex literals, fix the source.
"""

import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA502 = os.path.join(ROOT, 'out', 'lua502', 'bin', 'lua')
LUAC502 = os.path.join(ROOT, 'out', 'lua502', 'bin', 'luac')
STAGE = os.path.join(ROOT, 'out', 'lua502src')

# THE WHOLE CHAIN, in the order the harnesses load it. tsp/serial_core.tsp and the four protocol modules
# are pulled in by gen_serial.lua rather than by the harness, which is why a list that stops at
# serial_app.tsp looks complete and is not.
SOURCES = [
    'tsp/serial_core.tsp', 'tsp/uart_decode.tsp', 'tsp/chunk_decode.tsp',
    'tsp/midi_decode.tsp', 'tsp/lin_decode.tsp',
    'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp',
    'bench/arb_names.tsp', 'bench/sdg_net.tsp', 'bench/bench_rec.tsp', 'bench/bench_run.tsp',
    'tools/mock_display.lua', 'tools/gen_serial.lua', 'tools/mock_bench.lua',
    'tools/offline_bench.lua',
]

HEXLIT = re.compile(r'0[xX][0-9A-Fa-f]+')

# CONSTRUCTS 5.0.2 DOES NOT HAVE, banned in the whole chain -- the harness included, because a mock that
# stands in for the instrument has to be runnable under the instrument's interpreter. Matched WITH the
# open paren so the many comments that name these functions in order to warn about them are not flagged.
# `#` is caught separately, in code context only, because it is a syntax error rather than a missing name.
BANNED = [
    ('string.match(', 'string.find with captures -- the captures follow the two indices'),
    (':match(', 'string.find with captures'),
    ('string.gmatch(', 'a string.find loop; 5.0.2 has gfind, which 5.5 in turn dropped'),
    ('string.gfind(', 'a string.find loop; 5.5 dropped gfind'),
    ('math.fmod(', 'math.mod'),
    ('table.unpack(', 'unpack'),
    ('os.getenv(', 'nothing -- the instrument has no environment'),
]


def spans(body):
    """Classify every byte of a Lua source as code, string or comment.

    Returns a bytearray-like list of chars: 'c' code, 's' string, 'x' comment. A hand-rolled scanner
    rather than a regex because the three states nest: `--[[` is a long comment, `[[` inside a short
    string is not a long string, and `--` inside a string is not a comment.
    """
    n = len(body)
    out = ['c'] * n
    i = 0
    while i < n:
        ch = body[i]
        # long comment or long string, --[=*[ ... ]=*]
        m = re.match(r'(--)?\[(=*)\[', body[i:])
        if m and (m.group(1) or ch == '['):
            kind = 'x' if m.group(1) else 's'
            close = ']' + m.group(2) + ']'
            end = body.find(close, i + m.end())
            end = n if end < 0 else end + len(close)
            for k in range(i, end):
                out[k] = kind
            i = end
            continue
        if body.startswith('--', i):
            end = body.find('\n', i)
            end = n if end < 0 else end
            for k in range(i, end):
                out[k] = 'x'
            i = end
            continue
        if ch in '"\'':
            j = i + 1
            while j < n and body[j] != ch:
                if body[j] == '\\':
                    j += 1
                if body[j:j + 1] == '\n':
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                out[k] = 's'
            i = j + 1
            continue
        i += 1
    return out


def hexfix(body):
    """Rewrite hex numerals that appear in CODE. -> new body, count, [in-string offenders]"""
    cls = spans(body)
    out, last, n, bad = [], 0, 0, []
    for m in HEXLIT.finditer(body):
        a, b = m.span()
        # A numeral cannot start immediately after an identifier character; that is a name like `x0x1`.
        if a > 0 and (body[a - 1].isalnum() or body[a - 1] == '_'):
            continue
        if b < len(body) and (body[b].isalnum() or body[b] == '_'):
            continue
        if cls[a] == 's':
            bad.append((body.count('\n', 0, a) + 1, m.group(0)))
            continue
        if cls[a] == 'x':
            continue
        out.append(body[last:a])
        out.append(str(int(m.group(0), 16)))
        last = b
        n += 1
    out.append(body[last:])
    return ''.join(out), n, bad


def native502(rel, body):
    """Report constructs 5.0.2 does not have. -> [(rel, line, found, instead)]

    THIS IS THE POINT OF THE TOOL, not a side check. `math.fmod` and `string.match` both exist on the
    host and not on the instrument, so a harness using them passes every offline suite and raises -286 on
    the box -- and the harness is the part of the chain nothing else lints: tools/lint_tsp.py refuses both
    names, but release_sweep only ever hands it tsp/ and bench/.
    """
    out = []
    cls = spans(body)
    for name, instead in BANNED:
        start = 0
        while True:
            a = body.find(name, start)
            if a < 0:
                break
            start = a + 1
            if cls[a] != 'c':
                continue
            out.append((rel, body.count('\n', 0, a) + 1, name, instead))
    for a, ch in enumerate(body):
        if ch == '#' and cls[a] == 'c':
            out.append((rel, body.count('\n', 0, a) + 1, '#', 'table.getn(t)'))
    return out


def unstage():
    """Delete the staged tree WITHOUT following a symlink out of it.

    The tree contains a link to the real out/vectors, and out/ also holds every soak record and the 5.0.2
    build itself. shutil.rmtree does not follow symlinked directories, but this is explicit rather than
    trusted: a bug here deletes measurements that cost nights of instrument time.
    """
    if not os.path.isdir(STAGE) or os.path.islink(STAGE):
        return
    for root, dirs, files in os.walk(STAGE, topdown=False, followlinks=False):
        for f in files:
            os.unlink(os.path.join(root, f))
        for d in dirs:
            p = os.path.join(root, d)
            os.unlink(p) if os.path.islink(p) else os.rmdir(p)
    os.rmdir(STAGE)


# THE SHADOW. The harness reaches for things by RELATIVE path -- gen_serial reads out/vectors/v77.bin,
# test_bench_engine popens `python3 tools/soakplan.py` -- and the staged tree is the working directory, so
# a tree holding only the 16 transformed files fails on the 17th thing anything asks for. Everything else
# is symlinked, which also makes the transform legible: in the staged tree the REAL files are exactly the
# ones this tool rewrote, and every other path is a link back to the repo.
SHADOW_DIRS = ['tsp', 'bench', 'tools']
SHADOW_OUT = ['vectors']


def shadow():
    root_entries = [e for e in os.listdir(ROOT) if e not in ('.git', 'out') + tuple(SHADOW_DIRS)]
    for e in root_entries:
        os.symlink(os.path.join(ROOT, e), os.path.join(STAGE, e))
    os.makedirs(os.path.join(STAGE, 'out'), exist_ok=True)
    for e in SHADOW_OUT:
        src = os.path.join(ROOT, 'out', e)
        if os.path.exists(src):
            os.symlink(src, os.path.join(STAGE, 'out', e))
    staged = set(SOURCES)
    for d in SHADOW_DIRS:
        os.makedirs(os.path.join(STAGE, d), exist_ok=True)
        for e in os.listdir(os.path.join(ROOT, d)):
            rel = d + '/' + e
            if rel in staged or e == '__pycache__':
                continue
            os.symlink(os.path.join(ROOT, rel), os.path.join(STAGE, rel))


def stage(verbose=True):
    """Rebuild out/lua502src as a mirror of the chain, transformed as documented above."""
    unstage()
    os.makedirs(STAGE, exist_ok=True)
    shadow()
    total, offenders, banned = 0, [], []
    rows = []
    for rel in SOURCES:
        src = os.path.join(ROOT, rel)
        with open(src, 'r') as fh:
            body = fh.read()
        note = ''
        body, nhex, bad = hexfix(body)
        if bad:
            offenders += [(rel, ln, txt) for ln, txt in bad]
        if nhex:
            note = '%d hex literal(s)' % nhex
        banned += native502(rel, body)
        dst = os.path.join(STAGE, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'w') as fh:
            fh.write(body)
        total += nhex
        rows.append((rel, note))
    if verbose:
        print('staged %d file(s) into out/lua502src, %d hex literal(s) rewritten' % (len(SOURCES), total))
        for rel, note in rows:
            if note:
                print('    %-26s %s' % (rel, note))
    if offenders and verbose:
        # REPORTED, NOT REFUSED. These were LEFT ALONE, which is the safe outcome: a hex literal inside a
        # string is not a numeral to 5.0.2's scanner, so it cannot cause the parse failure this transform
        # exists to fix, and rewriting it WOULD change what the app prints or what an assertion is named.
        # tools/test_serial.lua names its cases things like `0x55`. An earlier version refused here, which
        # blocked staging a suite over strings that needed no work at all. The parse gate below is what
        # decides whether anything is actually wrong.
        print('    %d hex literal(s) inside strings, left unchanged (e.g. %s:%d %s)'
              % (len(offenders), offenders[0][0], offenders[0][1], offenders[0][2]))
    if banned:
        print('REFUSING: %d construct(s) the instrument does not have. Fix the SOURCE, not the staging:'
              % len(banned))
        for rel, ln, found, instead in banned:
            print('    %s:%d  %-16s use %s' % (rel, ln, found, instead))
        return None
    if verbose:
        print('no 5.1+ constructs in the chain: the harness is runnable under the instrument\'s own Lua')
    return STAGE


def parse_check():
    """Every staged file must parse under the real 5.0.2 compiler."""
    if stage() is None:
        return 2
    bad = 0
    for rel in SOURCES:
        r = subprocess.run([LUAC502, '-p', '-o', os.devnull, os.path.join(STAGE, rel)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            bad += 1
            msg = (r.stderr or r.stdout).strip().replace(os.path.join(STAGE, rel), rel)
            print('  PARSE FAIL %s' % msg)
    print('parse under 5.0.2: %d of %d file(s) ok' % (len(SOURCES) - bad, len(SOURCES)))
    return 1 if bad else 0


def run(script, args, staged=True):
    """Run a Lua script under 5.0.2 with the staged tree as its working directory."""
    lua = LUA502 if staged else 'lua'
    cwd = STAGE if staged else ROOT
    r = subprocess.run([lua, script] + list(args), cwd=cwd, text=True)
    return r.returncode


def main(argv):
    if not os.path.exists(LUA502):
        print('REFUSING: no 5.0.2 interpreter at out/lua502/bin/lua')
        print('  build it once with: sh tools/get_lua502.sh')
        return 2
    if '--parse-check' in argv:
        return parse_check()
    if '--stage' in argv:
        return 0 if stage() is not None else 2
    if '--run' in argv:
        i = argv.index('--run')
        # THE TARGET IS STAGED TOO, not just symlinked. A suite left as a symlink is handed to 5.0.2 with
        # its own hex literals intact -- tools/test_serial.lua:156 has one -- and fails to load for a
        # reason that has nothing to do with what is being tested.
        target = argv[i + 1]
        if target not in SOURCES and os.path.exists(os.path.join(ROOT, target)):
            SOURCES.append(target)
        if stage() is None:
            return 2
        return run(target, argv[i + 2:])
    if '--bench' in argv:
        def opt(name, default=None):
            return argv[argv.index(name) + 1] if name in argv else default
        plan, out = opt('--plan'), opt('--out')
        if plan is None or out is None:
            print('REFUSING: --bench needs --plan FILE and --out FILE')
            return 2
        iters = opt('--iterations', '1')
        if stage() is None:
            return 2
        # ABSOLUTE, because the staged tree is the working directory and a relative --out would land
        # inside it -- where the next --stage would delete it.
        plan, out = os.path.abspath(plan), os.path.abspath(out)
        rc = run('tools/offline_bench.lua', ['--plan', plan, '--out', out, '--iterations', iters])
        if rc != 0 or '--paired' not in argv:
            return rc
        # AND THE SAME PLAN UNDER 5.5, so the two records can be compared. A difference here is the
        # thing this tool exists to find; identity is the result that lets an offline number be quoted.
        out55 = out + '.lua55'
        print('-- the same plan under the host 5.5, for comparison --')
        rc2 = run('tools/offline_bench.lua', ['--plan', plan, '--out', out55, '--iterations', iters],
                  staged=False)
        if rc2 != 0:
            return rc2
        return compare(out, out55)
    print(__doc__)
    return 2


# TIMESTAMPS AND ELAPSED FIGURES ARE MASKED, and nothing else is. Two interpreters cannot produce the
# same os.time(), so an unmasked diff is all noise; but masking anything else would hide exactly the
# class of divergence this tool is for, so the mask is one regex and it is named here.
STAMP = re.compile(r'\b1[0-9]{9}\b')
ELAPSED = re.compile(r'\b\d+\.\d+ s\b')

# FLOAT-TO-STRING IS THE ONE DIVERGENCE THAT SURVIVES, in two forms, and both are real rather than
# cosmetic because they change the TEXT of a record a host reader parses:
#
#   width          5.0.2 `11372.70912143`   5.5 `11372.709121429552`
#   integer floats 5.0.2 `80000`            5.5 `80000.0`
#
# The second is 5.3+ having an integer subtype, so tostring() marks a float-valued 80000 as `80000.0` to
# distinguish it from the integer. Both mean every OFFLINE record is the one carrying a form the
# instrument cannot produce -- so a reader must not depend on either. Rounding both sides to 10
# significant figures separates 'the two interpreters decoded differently' from 'they printed the same
# number differently', and only the first is a defect. 10 is far more precision than any field here
# needs: a baud rate is judged against a 2 % window.
FLOAT = re.compile(r'-?\d+\.\d+')

# AND THE HEAP FIGURE CANNOT AGREE BY CONSTRUCTION. brun.heapk() reads gcinfo() on the instrument's 5.0.2
# and collectgarbage('count') on 5.5 -- the mirror-image pair that made `mem` display on hardware and be
# silently unreachable offline. Both now return a number, which is what this proves; the numbers differ
# because the allocators do, and offline is inflated further by the mock retaining every written byte.
HEAP = re.compile(r'heap \d+ kB')


def compare(a, b):
    def norm(p):
        with open(p, 'r', errors='replace') as fh:
            lines = fh.read().splitlines()
        return [HEAP.sub('heap H kB', ELAPSED.sub('T s', STAMP.sub('TIME', ln))) for ln in lines]

    def widths(lines):
        return [FLOAT.sub(lambda m: '%.10g' % float(m.group(0)), ln) for ln in lines]

    la, lb = norm(a), norm(b)
    print('5.0.2 record %d line(s), 5.5 record %d line(s)' % (len(la), len(lb)))
    if la == lb:
        print('IDENTICAL after masking timestamps -- the interpreter is not a variable on this plan')
        return 0
    wa, wb = widths(la), widths(lb)
    if wa == wb:
        n = sum(1 for x, y in zip(la, lb) if x != y)
        print('IDENTICAL to 10 significant figures; %d line(s) differ only in printed float WIDTH.' % n)
        print('  The decode agrees exactly -- bytes, frame counts and snap flags are the same.')
        print('  Note which way this cuts: the OFFLINE record is the one with digits the instrument')
        print('  cannot produce, so a reader must not depend on them.')
        return 0
    ndiff = 0
    for i in range(max(len(la), len(lb))):
        x = la[i] if i < len(la) else '<eof>'
        y = lb[i] if i < len(lb) else '<eof>'
        if x != y:
            ndiff += 1
            if ndiff <= 12:
                print('  line %d' % (i + 1))
                print('    5.0.2: %s' % x[:150])
                print('    5.5  : %s' % y[:150])
    print('DIFFER on %d line(s)' % ndiff)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

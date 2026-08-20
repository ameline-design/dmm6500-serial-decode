#!/usr/bin/env python3
"""Hold mt19937.py, mt19937.lua and THE INSTRUMENT'S OWN LUA to one sequence, and to the reference.

WHY THIS IS A GATE AND NOT A SPOT CHECK. A soak whose iterations vary is only debuggable if an
iteration can be replayed alone, and that rests entirely on the generators agreeing. If they drift,
the offline suites explore different cases from the ones the hardware sweep reported and every replay
comes back clean -- a harness that manufactures ghosts instead of catching them.

THREE LEGS, BECAUSE TWO IS NOT ENOUGH:

  CPython random  ->  mt19937.py  ->  host Lua  ->  DMM Lua 5.0.2

CPython's random module IS this algorithm seeded through init_by_array, so it is an independent
implementation rather than a table of numbers pasted in here -- a pasted table only records what some
earlier run produced. random.Random(int) reads the integer as 32-bit words little-endian, so a key
array maps to sum(k << 32*i), WITH THE TOP WORD NON-ZERO or the conversion drops it and the keys are
not the same key.

MUTUAL AGREEMENT ALONE WOULD NOT BE ENOUGH: two ports of the same misreading agree perfectly. So the
Lua arithmetic primitives are also checked against Lua's OWN native operators, which the module may
not use, and the instrument is checked because its Lua is a different implementation on different
hardware -- 5.0.2, no bitwise operators, no '%', no '#'.

    python3 tools/test_soakrand.py            # the two offline legs; no instrument
    python3 tools/test_soakrand.py --dmm      # all three; takes the DMM socket
    python3 tools/test_soakrand.py -v         # show each check
"""
import argparse
import os
import random
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

from mt19937 import MT19937, TWO32                              # noqa: E402

MODULE = os.path.join(ROOT, 'tools', 'mt19937.lua')

VERBOSE = False
FAILED = []

# Keys with a NON-ZERO TOP WORD, so the CPython integer conversion keeps every word.
KEYS = [[0x123, 0x234, 0x345, 0x456],
        [1],
        [19650218],
        [0xffffffff],
        [7, 0xdeadbeef],
        [2026, 129, 3, 40, 22]]

# n where the rejection tail is HALF the range, so below() cannot agree by accident. At n = 2^31+1,
# 2^32 mod n = 2^31-1, so about one draw in two is thrown away and the loop is exercised on nearly
# every call. At n = 41 the tail is 37 values in 2^32 and rejection effectively never happens, which
# is why a small n proves nothing about that branch.
BIG_N = (1 << 31) + 1


def ck(cond, what):
    if cond:
        if VERBOSE:
            print('  ok    %s' % what)
    else:
        FAILED.append(what)
        print('  FAIL  %s' % what)


def module_source():
    with open(MODULE) as f:
        src = f.read()
    tail = '\nreturn M\n'
    if not src.endswith(tail):
        raise RuntimeError('mt19937.lua does not end in "return M"; the driver cannot be appended')
    return src[:-len(tail)]


def lua(src):
    """Run a Lua snippet with tools/ on the module path. -> stdout lines. Raises on failure."""
    body = "package.path = '%s/tools/?.lua;' .. package.path\n%s" % (ROOT, src)
    p = subprocess.run(['lua', '-e', body], capture_output=True, text=True, cwd=ROOT)
    if p.returncode != 0:
        raise RuntimeError('lua exited %d: %s%s' % (p.returncode, p.stdout[-400:], p.stderr[-400:]))
    return [x for x in p.stdout.strip().split('\n') if x != '']


# ---------------------------------------------------------------- the driver both Luas run
#
# ONE DRIVER FOR BOTH LUAS, so the host leg and the instrument leg are not two different questions.
# Every data line is TAGGED and every reply is filtered on the tag: this instrument volunteers event
# lines into the same stream when showevents is on, and an untagged parse would read one as a number.
#
# Words go ten to a line rather than one, because the instrument leg pays a socket round trip per
# line and 700 of them is the difference between a second and a minute.
DRIVER = """
local function emit(tag, t)
  local i, n, out = 1, 0, {}
  n = 0
  while t[n + 1] ~= nil do n = n + 1 end
  i = 1
  while i <= n do
    local chunk, j = {}, 0
    j = 0
    while j < 10 and (i + j) <= n do chunk[j + 1] = t[i + j]; j = j + 1 end
    print(tag .. ' ' .. table.concat(chunk, ' '))
    i = i + 10
  end
end

local KEYS = {{0x123, 0x234, 0x345, 0x456}, {1}, {19650218}, {0xffffffff},
              {7, 0xdeadbeef}, {2026, 129, 3, 40, 22}}

-- 700 words on the first key: past the 624-word block, so the twist refill runs.
local g = M.new(KEYS[1])
local w, i = {}, nil
for i = 1, 700 do w[i] = string.format('%.0f', g:u32()) end
emit('MTW', w)

-- Eight words from every key, so a seeding bug that only shows for short keys is not missed.
local ki
for ki = 1, 6 do
  local h = M.new(KEYS[ki])
  local t = {}
  for i = 1, 8 do t[i] = string.format('%.0f', h:u32()) end
  print('MTK ' .. ki .. ' ' .. table.concat(t, ' '))
end

-- float(): %.17g so the comparison is on the double, not on a rounded rendering.
local f = M.new{4242}
local ft = {}
for i = 1, 40 do ft[i] = string.format('%.17g', f:float()) end
emit('MTF', ft)

-- below(): a small n, then one where half the draws are rejected.
local b = M.new{5}
local bt = {}
for i = 1, 60 do bt[i] = string.format('%d', b:below(41)) end
emit('MTB', bt)
local b2 = M.new{5}
local b2t = {}
for i = 1, 60 do b2t[i] = string.format('%.0f', b2:below(2147483649)) end
emit('MTR', b2t)

-- shuffle(): the vector order.
local s = M.new{2026, 129, 1}
local perm = {}
for i = 1, 41 do perm[i] = i end
s:shuffle(perm)
local pt = {}
for i = 1, 41 do pt[i] = string.format('%d', perm[i]) end
emit('MTS', pt)

print('MTV ' .. string.format('%.0f %.0f %.0f', M.bxor(0, 0), M.bxor(4294967295, 0),
                              M.mul32(1812433253, 4294967295)))
"""


def parse_tagged(lines):
    """-> {tag: [fields...]}, plus anything untagged. Untagged lines are REPORTED, not skipped
    silently: on the instrument they are volunteered event lines and they mean something."""
    out, stray = {}, []
    for ln in lines:
        parts = ln.strip().split()
        if not parts or parts[0] not in ('MTW', 'MTK', 'MTF', 'MTB', 'MTR', 'MTS', 'MTV'):
            if ln.strip():
                stray.append(ln.strip())
            continue
        out.setdefault(parts[0], []).extend(parts[1:])
    return out, stray


def expected():
    """What the driver must produce, computed here. -> dict of tag -> list of strings."""
    exp = {}
    g = MT19937(KEYS[0])
    exp['MTW'] = ['%d' % g.u32() for _ in range(700)]
    mtk = []
    for ki, key in enumerate(KEYS):
        h = MT19937(key)
        mtk.append('%d' % (ki + 1))
        mtk.extend('%d' % h.u32() for _ in range(8))
    exp['MTK'] = mtk
    f = MT19937([4242])
    exp['MTF'] = ['%.17g' % f.float() for _ in range(40)]
    b = MT19937([5])
    exp['MTB'] = ['%d' % b.below(41) for _ in range(60)]
    b2 = MT19937([5])
    exp['MTR'] = ['%d' % b2.below(BIG_N) for _ in range(60)]
    s = MT19937([2026, 129, 1])
    exp['MTS'] = ['%d' % x for x in s.shuffle(list(range(1, 42)))]
    exp['MTV'] = ['0', '4294967295', '%d' % ((1812433253 * 4294967295) & 0xffffffff)]
    return exp


def compare_driver(where, lines):
    got, stray = parse_tagged(lines)
    exp = expected()
    ck(not stray, '%s: no untagged lines in the reply (%d)%s'
       % (where, len(stray), (' -- first: %r' % stray[0]) if stray else ''))
    for tag in ('MTW', 'MTK', 'MTF', 'MTB', 'MTR', 'MTS', 'MTV'):
        g, e = got.get(tag, []), exp[tag]
        if g == e:
            ck(True, '%s: %s matches (%d values)' % (where, tag, len(e)))
            continue
        first = next((i for i in range(max(len(g), len(e)))
                      if i >= len(g) or i >= len(e) or g[i] != e[i]), None)
        ck(False, '%s: %s DIFFERS -- %d values vs %d expected, first at index %s (%r vs %r)'
           % (where, tag, len(g), len(e), first,
              g[first] if first is not None and first < len(g) else None,
              e[first] if first is not None and first < len(e) else None))


# ---------------------------------------------------------------- offline checks


def t_reference():
    """mt19937.py reproduces CPython's MT19937. This settles init_genrand too: init_by_array's first
    act is init_genrand(19650218), so an error in the multiplicative fill perturbs what it mixes."""
    for key in KEYS:
        x = sum(k << (32 * i) for i, k in enumerate(key))
        r = random.Random(x)
        want = [r.getrandbits(32) for _ in range(64)]
        g = MT19937(key)
        ck([g.u32() for _ in range(64)] == want, 'mt19937.py matches CPython for key %s' % (key,))


def t_reference_is_not_vacuous():
    """The comparison above can fail. Without this, a bug making both sides constant reads as
    agreement."""
    key = KEYS[0]
    x = sum(k << (32 * i) for i, k in enumerate(key))
    ck(random.Random(x).getrandbits(32) != random.Random(x + 1).getrandbits(32),
       'a different key gives a different first word, so the check has teeth')
    g = MT19937(key)
    ck(len({g.u32() for _ in range(8)}) == 8, 'eight successive words are eight distinct values')


def t_lua_driver():
    """The host Lua runs the SAME driver the instrument will, so a disagreement on the box is not
    also the first time that driver has been exercised."""
    compare_driver('host lua', lua("%s\n%s" % (module_source(), DRIVER)))


def t_lua_int_seed():
    """A bare integer and a one-element key are the same stream, in both languages."""
    src = ("local M = require 'mt19937'\n"
           "local a, b = M.new(12345), M.new{12345}\n"
           "for i = 1, 8 do print(string.format('%.0f %.0f', a:u32(), b:u32())) end")
    pairs = [x.split() for x in lua(src)]
    ck(all(p[0] == p[1] for p in pairs), 'lua: new(n) and new{n} are the same stream')
    g = MT19937(12345)
    ck([int(p[0]) for p in pairs] == [g.u32() for _ in range(8)],
       'python: new(n) agrees with lua new(n)')


def t_lua_primitives_vs_native():
    """THE PART WITH NO PRIOR ART. bxor, band and mul32 are arithmetic on doubles because 5.0.2 has
    no bitwise operators; here they are checked against the host Lua's native ones, which the module
    itself must not use."""
    src = ("local M = require 'mt19937'\n"
           "local g = M.new{99}\n"
           "local bad = 0\n"
           "for i = 1, 4000 do\n"
           "  local a, b = g:u32(), g:u32()\n"
           "  local ia, ib = math.tointeger(a), math.tointeger(b)\n"
           "  if M.bxor(a, b) ~= (ia ~ ib) then bad = bad + 1 end\n"
           "  if M.band(a, b) ~= (ia & ib) then bad = bad + 1 end\n"
           "  if M.mul32(a, b) ~= ((ia * ib) & 0xffffffff) then bad = bad + 1 end\n"
           "end\n"
           "print(bad)")
    ck(lua(src)[0] == '0', 'lua bxor/band/mul32 match native operators over 4000 random pairs')


def t_module_is_502_clean():
    """5.0.2 SYNTAX, checked here rather than discovered on the instrument. '#', '%', '//' and the
    bitwise operators are parse errors there, so ONE occurrence anywhere stops the whole module
    loading -- taken branch or not -- and the failure arrives as a script that does not exist."""
    with open(MODULE) as f:
        code = [ln.split('--', 1)[0] for ln in f]
    banned = [('#', "'#' length operator"), ('//', 'floor division'), ('&', 'bitwise and'),
              ('|', 'bitwise or'), ('math.fmod', 'math.fmod'), ('goto ', 'goto'), ('::', 'label')]
    for tok, why in banned:
        hits = [i + 1 for i, ln in enumerate(code) if tok in ln]
        ck(not hits, 'mt19937.lua has no %s (5.0.2 parse error)%s'
           % (why, (' -- line %s' % hits[:4]) if hits else ''))
    # '~=' IS 5.0.2's not-equal and is correct; a LONE '~' is the 5.3 bitwise operator and is not.
    tilde = [i + 1 for i, ln in enumerate(code) if re.search(r'~(?!=)', ln)]
    ck(not tilde, "mt19937.lua has no bare '~' bitwise operator (5.0.2 parse error)%s"
       % ((' -- line %s' % tilde[:4]) if tilde else ''))
    pct = [i + 1 for i, ln in enumerate(code)
           if '%' in ln.replace("'%", '#').replace('"%', '#')]
    ck(not pct, "mt19937.lua uses no '%%' operator outside format strings%s"
       % ((' -- line %s' % pct[:4]) if pct else ''))


def t_below_range_and_bias():
    g = MT19937([5])
    for n in (2, 3, 7, 10, 41, 1000):
        vals = [g.below(n) for _ in range(4000)]
        ck(min(vals) >= 0 and max(vals) < n, 'below(%d) stays inside [0,%d)' % (n, n))
    g = MT19937([5])
    counts = [0] * 7
    for _ in range(70000):
        counts[g.below(7)] += 1
    ck(max(counts) - min(counts) < 1200,
       'below(7) is flat over 70000 draws (spread %d, mean 10000)' % (max(counts) - min(counts)))
    ck(g.below(1) == 0, 'below(1) is 0')
    for bad in (0, -1, 2.5):
        try:
            g.below(bad)
            ck(False, 'below(%r) refuses' % (bad,))
        except (ValueError, TypeError):
            ck(True, 'below(%r) refuses' % (bad,))


def t_below_rejection_is_exercised():
    """below() at an n where HALF the range is rejected. At n = 41 the tail is 37 values in 2^32, so
    a run that never rejects proves nothing about the branch; here it rejects constantly, and the two
    languages only agree if they discard the same draws in the same order."""
    g = MT19937([5])
    vals = [g.below(BIG_N) for _ in range(2000)]
    ck(min(vals) >= 0 and max(vals) < BIG_N, 'below(2^31+1) stays in range')
    plain = MT19937([5])
    naive = [plain.u32() % BIG_N for _ in range(2000)]
    ck(vals != naive, 'below(2^31+1) is NOT a bare modulus of the same stream, so rejection happened')
    ck(sum(1 for v in vals if v >= (1 << 30)) > 400, 'the high half of [0,2^31+1) is reachable')


def t_shuffle():
    """The vector order. A permutation, and the SAME permutation in both languages -- the loop
    direction and the below() bound are load-bearing, not stylistic."""
    n = 41
    g = MT19937([2026, 129, 1])
    perm = g.shuffle(list(range(1, n + 1)))
    ck(sorted(perm) == list(range(1, n + 1)), 'shuffle of 41 is a permutation, nothing lost or doubled')
    ck(perm != list(range(1, n + 1)), 'shuffle of 41 actually moves things')
    seen = {tuple(MT19937([2026, it, 1]).shuffle(list(range(1, n + 1)))) for it in range(1, 21)}
    ck(len(seen) == 20, 'twenty iterations give twenty distinct orders')


def t_iteration_is_a_pure_function():
    """THE REQUIREMENT THE MODULE EXISTS FOR: iteration 129 is reachable without running 128 first,
    so a failure is replayed directly rather than waited for."""
    a = [MT19937([2026, 129, 2, g]).float() for g in range(21)]
    ck(a == [MT19937([2026, 129, 2, g]).float() for g in range(21)],
       'iteration 129 rebuilds identically from its key alone')
    walked = None
    for it in range(1, 130):
        walked = [MT19937([2026, it, 2, g]).float() for g in range(21)]
    ck(walked == a, 'walking 1..129 lands on the same values as addressing 129 directly')
    ck([MT19937([2026, 130, 2, g]).float() for g in range(21)] != a,
       'iteration 130 differs from 129, so the iteration number reaches the draw')


def t_substream_independence():
    """Decisions are keyed, not drawn from one running stream, so replaying a single cell does not
    depend on how many cells ran before it -- including any that failed or were skipped."""
    n = 30
    waits = [MT19937([2026, 129, 3, vi, ri]).float() for vi in range(n) for ri in range(n)]
    ck(len(set(waits)) > 0.99 * len(waits),
       'keyed per-cell draws are distinct across %d cells' % len(waits))
    ck(MT19937([2026, 129, 3, 17, 22]).float() == waits[17 * n + 22],
       'one cell is addressable on its own and matches its place in the sweep')
    ck(MT19937([2026, 129, 3, 17, 22]).float() != MT19937([2026, 129, 3, 17, 23]).float(),
       'adjacent cells draw independently, so the key mixes rather than concatenates')


# ---------------------------------------------------------------- the instrument leg


def t_dmm():
    """THE THIRD LEG: the instrument's own Lua 5.0.2, on its own hardware.

    Runs the identical driver. Nothing here touches the app: no display object, no capture, no dmm.*
    call -- it is arithmetic and print only, so it cannot leave state behind for the next tool.
    """
    import time
    from dmmrun import DMM
    d = DMM()
    try:
        # DRAIN THE LOG FIRST, and say what was in it. A power cycle leaves informational entries
        # behind -- 4917 "Reading buffer defbufferN is 0% filled" is there on every cold start -- so
        # reading the log AFTER the driver without a baseline reports the instrument's history as
        # this script's doing. The check is only worth making against an empty starting point.
        pre = d.errors()
        if pre:
            print('        (log held %d entry(ies) before the driver ran: %s)'
                  % (len(pre), '; '.join(x.split('\t')[1] for x in pre[:3])))
        t0 = time.time()
        out = d.load_script('mtcheck', "%s\n%s\nprint('===DONE===')"
                            % (module_source(), DRIVER), timeout=300)
        secs = time.time() - t0
        ck(not any('TIMEOUT' in x for x in out), 'the instrument ran the driver to completion')
        compare_driver('DMM 5.0.2', out)
        errs = d.errors()
        ck(not errs, 'the driver logged no events of its own%s'
           % ((' -- %s' % errs[:2]) if errs else ''))
        print('        (upload, run and read-back of ~900 draws took %.1f s on the instrument)' % secs)
    finally:
        # DROP THE SCRIPT AGAIN. A loaded script holds instrument memory until it is deleted or the
        # box is power-cycled, and this one is 220 lines of table-driven arithmetic. Leaving it
        # resident would charge a soak that runs afterwards for memory this check borrowed, and the
        # next tool must not have to know that.
        try:
            d.q('if mtcheck ~= nil then pcall(function() script.delete(mtcheck) end) '
                'mtcheck = nil eventlog.clear() end print("__GONE__")', timeout=30)
            left = d.q('print(tostring(mtcheck))', timeout=15)
            ck('nil' in (left or ''), 'the check script is removed from the instrument (got %r)' % left)
        except Exception as e:                                    # noqa: BLE001
            ck(False, 'could not remove the check script from the instrument: %s' % str(e)[:120])
        d.close()


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--dmm', action='store_true',
                    help="also run the driver on the instrument's own Lua (takes the DMM socket)")
    a = ap.parse_args()
    VERBOSE = a.verbose

    checks = [t_module_is_502_clean, t_reference, t_reference_is_not_vacuous, t_lua_driver,
              t_lua_int_seed, t_lua_primitives_vs_native, t_below_range_and_bias,
              t_below_rejection_is_exercised, t_shuffle, t_iteration_is_a_pure_function,
              t_substream_independence]
    if a.dmm:
        checks.append(t_dmm)

    for fn in checks:
        print(fn.__name__)
        # CAUGHT PER CHECK. A Lua that fails to load raises, and letting that propagate would abort
        # every later check -- so a single syntax error would hide the state of everything else.
        try:
            fn()
        except Exception as e:                                    # noqa: BLE001
            FAILED.append('%s raised' % fn.__name__)
            print('  FAIL  %s raised: %s' % (fn.__name__, str(e)[:300]))

    print()
    if FAILED:
        print('%d FAILED' % len(FAILED))
        for f in FAILED:
            print('  %s' % f)
        return 1
    print('all checks passed%s' % ('' if a.dmm else '  (offline legs only; --dmm adds the instrument)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Structural linter for the TSP (Lua 5.0.2) modules and the packaged .tspa.

There is no Lua interpreter on the host and none on the instrument's front panel,
so a syntax error costs a whole power cycle to discover (see the one-build-per-
power-cycle crash rule). This checks the things that are cheap to get wrong in a
hand edit and expensive to find on hardware:

  * block nesting -- every function/if/for/while/do closed by the right `end`,
    tracked on a stack so a MISPLACED end is caught, not just a missing one
  * Lua 5.0.2 compatibility -- constructs the instrument's old parser rejects
    ('#' length operator, integer division, goto, bitwise ops, '::' labels)
  * accidental globals -- assignments at file scope that are neither `local` nor
    fields of the single app table (e.g. `sdec`)
  * the pcall budget -- the packaged .tspa's count of pcall SITES, which this
    firmware bluescreens above; nothing else in the repo enforced it

Comments and string literals are blanked out first so keywords inside them do not
count. Usage: lint_tsp.py <file> [...]   (exit 1 if any file fails)
"""
import os
import re
import sys

# Keywords that open a block needing `end`.
OPENERS = ('function', 'if', 'for', 'while')
INCOMPAT = [
    (r'#\s*[A-Za-z_({]', "'#' length operator (Lua 5.0.2 has none -- use table.getn)"),
    (r'//', 'integer division // (not in 5.0.2)'),
    (r'\bgoto\b', 'goto (not in 5.0.2)'),
    (r'::', 'label :: (not in 5.0.2)'),
    (r'[^<>=~!]&[^&]|\|[^|]|>>|<<', 'bitwise operator (not in 5.0.2)'),
    (r'\bmath\.log\s*\(\s*[^,)]+,', 'math.log with a base argument (5.0.2 takes one arg)'),
    (r'%b\b', 'string.format %b (not in 5.0.2)'),
    # select() is a 5.1 vararg helper and raises "attempt to call global 'select'" here, at error
    # severity -- which on the panel is a modal box. The lookbehind is what keeps sdec.fs_select()
    # and any other name ending in select from matching.
    (r'(?<![\w.])select\s*\(', "select() (Lua 5.1 vararg helper -- not in 5.0.2)"),
    # THE ONE THE OFFLINE SUITES CANNOT CATCH. 5.0.2 has math.mod and no math.fmod; the host Lua has
    # math.fmod and no math.mod, and gen_serial.lua:22 shims `math.mod = math.mod or math.fmod` so
    # every suite passes either way. So math.fmod in tsp/ is invisible offline and fatal on the box:
    # measured, a build using it refused every capture with "attempt to call field `fmod' (a nil
    # value)" after 368640 clean offline decodes.
    (r'math\.fmod\s*\(', "math.fmod (5.1+; 5.0.2 has math.mod -- and the offline shim hides this)"),
    # KEITHLEY'S file.* IS BANNED, and the reason is the panel. It is a wrapper over Lua's own io,
    # and the wrapper is what posts events: file.read answers nil at the end of a file AND posts 2201
    # 'File read error', which on this instrument is a modal box nothing can suppress. On a plan read
    # once per lap that is one dialog per pass -- the operator had to power-cycle a running soak
    # because the box kept coming back. Measured on 1.7.17a 2026-10-24: io.open/read/write/close/
    # flush/seek all work, f:seek('end') IS the file length, a read at the end returns nil and posts
    # NOTHING, and a file written through io reads back through file.* -- one filesystem, two front
    # ends. os.remove and os.rename work; fs.is_file, fs.is_dir, fs.mkdir and fs.rmdir exist.
    #
    # file.usbdriveexists IS THE ONE EXCEPTION and is excluded below. It is the only SILENT
    # 'is a key present' question -- with no key even file.open('/usb1') posts 2205 -- and it is
    # specific to this instrument, so io and os have no equivalent.
    # io.lines IS ABSENT ON THE INSTRUMENT -- measured 2026-10-24: io.open, read, write,
    # close, flush, input and output are all functions, io.lines is NIL. The host Lua HAS
    # it, so a module using it passes every offline suite and raises on the box. Exactly
    # the math.fmod shape of trap, which is why it belongs here and not in a comment.
    # BOTH PATTERNS ALLOW SPACES AND THE BRACKET FORM, because the dotted spelling was not the only
    # way to write them: `file['read']`, `file . read(p)` and `io['lines'](p)` all passed, and so did
    # `local f = file` followed by `f.read(...)`. The alias is the only one a hand edit would
    # plausibly produce, and it is the one still not caught -- an alias cannot be seen without
    # tracking assignment, so it is left to review.
    (r'\bio\s*\.\s*lines\b', "io.lines (ABSENT on the instrument -- iterate with h:read('*l'))"),
    (r'\bfile\s*\.\s*(?!usbdriveexists)[A-Za-z_]',
     "Keithley file.* (use io.*/os.*/fs.*; file.read posts 2201 at the end of a file, which is a "
     "modal box. Only file.usbdriveexists is allowed)"),
    # THE BRACKET FORM IS BANNED WHOLE, name and all, because the name cannot be read: strip() blanks
    # string bodies before these patterns run, so `file['read']` arrives as `file['']` and no pattern
    # on the field can see it. Neither table is ever indexed that way in this tree, so banning the
    # shape costs nothing and closes the hole. What is still not caught is an alias -- `local f = file`
    # then `f.read(...)` -- which needs assignment tracking, and is left to review.
    (r'\bfile\s*\[', "file.* by bracket index (the field name is unreadable here, so the form is refused)"),
    (r'\bio\s*\[', "io by bracket index (io.lines is absent and the field name is unreadable here)"),
    # THE SAME TRAP AS math.fmod, AND IT COST A RUN. string.match and string.gmatch arrived in 5.1;
    # 5.0.2 has string.find (which returns its captures after the two indices) and string.gfind. The
    # host Lua has all four, so a module using string.match passes every offline suite and then dies on
    # the instrument -- measured: '-286 TSP Runtime error attempt to call field `match` (a nil value)'
    # killed an 86-cell run at its first plan line, after 51 offline assertions had gone green.
    (r'string\.match\s*\(', "string.match (5.1+; 5.0.2 has string.find with captures)"),
    # LONG-STRING LEVELS ARE 5.1 TOO. 5.0.2 has [[ ]] and nothing else, so [=[ or [==[ is a syntax
    # error on the instrument -- measured, it refused a whole script that loaded fine on the host.
    (r'\[=+\[', "long-string level [=[ (5.1+; 5.0.2 has only [[ ]])"),
    (r'string\.gmatch\s*\(', "string.gmatch (5.1+; 5.0.2 has string.gfind)"),
    # Method-call syntax on a string value is 5.1+ too, and reads so naturally that it is easy to write.
    (r'\)\s*:\s*(format|match|gmatch|gsub|find|sub|rep|byte|upper|lower)\s*\(',
     "string method syntax s:format(...) (5.1+; 5.0.2 needs string.format(s, ...))"),
]


def strip(src):
    """Blank comments and string bodies, preserving line structure."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == '--':                                   # comment
            if src[i + 2:i + 4] == '[[':                   # long comment
                j = src.find(']]', i + 4)
                j = n if j < 0 else j + 2
                out.append(re.sub(r'[^\n]', ' ', src[i:j]))
                i = j
            else:
                j = src.find('\n', i)
                j = n if j < 0 else j
                out.append(' ' * (j - i))
                i = j
            continue
        if two == '[[':                                    # long string
            j = src.find(']]', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
            continue
        if c in '"\'':                                     # short string
            j, q = i + 1, c
            while j < n and src[j] != q:
                j += 2 if src[j] == '\\' else 1
            out.append(' ' * (min(j + 1, n) - i))
            i = min(j + 1, n)
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check_blocks(code, name):
    errs, stack = [], []
    for lineno, line in enumerate(code.split('\n'), 1):
        for m in re.finditer(r'\b[a-z]+\b', line):
            w = m.group(0)
            if w in OPENERS:
                stack.append((w, lineno))
            elif w == 'do':
                # `do` belonging to for/while is already accounted for by that
                # opener; a bare `do` opens its own block.
                if not (stack and stack[-1][0] in ('for', 'while')):
                    stack.append(('do', lineno))
            elif w == 'repeat':
                stack.append(('repeat', lineno))
            elif w == 'until':
                if not stack or stack[-1][0] != 'repeat':
                    errs.append(f'{name}:{lineno}: `until` with no matching `repeat`')
                else:
                    stack.pop()
            elif w == 'end':
                if not stack:
                    errs.append(f'{name}:{lineno}: `end` with nothing open')
                elif stack[-1][0] == 'repeat':
                    errs.append(f'{name}:{lineno}: `end` closing a `repeat` '
                                f'(opened line {stack[-1][1]}) -- needs `until`')
                    stack.pop()
                else:
                    stack.pop()
    for kind, lineno in stack:
        errs.append(f'{name}:{lineno}: `{kind}` never closed by `end`')
    return errs


def check_compat(code, name):
    errs = []
    for lineno, line in enumerate(code.split('\n'), 1):
        for pat, why in INCOMPAT:
            if re.search(pat, line):
                errs.append(f'{name}:{lineno}: {why}')
    return errs


def app_namespaces(code, default='sdec'):
    """Every global table this file hangs things off, as a set.

    Detected from the idempotent declaration each module opens with,
    `<ns> = <ns> or {}`, rather than hardcoded: `usb_log.tsp` deliberately uses
    `ulog` so it can be shared with other apps, and a linter that only knew one
    name would report every correct line in the other module as an error.

    ALL OF THEM, NOT THE FIRST. A .tspa is six modules concatenated, and it
    declares both `ulog` and `sdec` -- so taking the first match called every
    `sdec.*` assignment in the other five modules a bare global: 249 of them,
    rc=1, on a package that is perfectly correct. That is worse than not checking,
    because a real bare global would have been the 250th line of a wall nobody
    reads. The check stays strict: a name that was never declared with the
    idempotent idiom is still refused, and a single-module file still has exactly
    one namespace, so nothing about linting tsp/*.tsp changes.
    """
    ns = set(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\1\s+or\s+\{\}', code, re.M))
    return ns or {default}


def file_locals(code):
    """Every name declared `local` at column 0, as a set.

    A FIELD OF A LOCAL TABLE IS NOT A GLOBAL, and without this the check cannot tell the two apart.
    bench/plan_rand.tsp holds the MT19937 in a do-block with `local M = bplan.mt` and `local MT = {}`,
    so `M.TWO32` and `MT.__index` were reported as bare globals -- two correct lines in the one module
    that has file-scope locals at all. Narrow on purpose: it allows a root that the file DECLARED
    local, and nothing else, so a genuinely bare global is still refused.
    """
    out = set()
    for line in code.split('\n'):
        m = re.match(r'local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if m:
            out.add(m.group(1))
            continue
        m = re.match(r'local\s+([A-Za-z_][A-Za-z0-9_,\s]*)', line)
        if m:
            for nm in m.group(1).split(','):
                nm = nm.strip()
                if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', nm):
                    out.add(nm)
    return out


def check_globals(code, name):
    """Assignments at column 0 (file scope) must be local or <ns>.* fields.

    The DMM6500 does NOT isolate app namespaces: every TTI app and the firmware
    share one Lua global environment, and event command strings resolve names
    there too, so a generic global is a real collision risk.
    """
    ns = app_namespaces(code) | file_locals(code)
    shown = '/'.join(sorted(app_namespaces(code)))
    errs = []
    for lineno, line in enumerate(code.split('\n'), 1):
        m = re.match(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=[^=]', line)
        if m and m.group(1).split('.')[0] not in ns:
            errs.append(f'{name}:{lineno}: bare global assignment `{m.group(1)}` '
                        f'(everything must hang off the {shown} table)')
        m = re.match(r'function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', line)
        if m:
            errs.append(f'{name}:{lineno}: bare global function `{m.group(1)}` '
                        f'(must be {shown}.{m.group(1)})')
    return errs


def check_dupes(code, name):
    """One name, one definition, and no named function nested inside another.

    NEITHER SHAPE IS A SYNTAX ERROR, which is why this exists: a 57-line block of three functions was
    duplicated into brun.ui_destroy's body, and the 5.0.2 parser, the nesting check and 127 assertions
    all passed on it. The later copy wins, but only once the enclosing function runs -- so ui_destroy
    silently cleared brun.msgs, and the next edit to brun.msg would have been reverted on a rebuild.

    THE INDENTATION HALF IS WHAT GENERALISES: the duplicate was byte-identical, so the name test caught
    it, but a nested DIFFERENT function would only trip the indentation. `local function` is how a real
    helper is written here and does not match.

    AND THE ASSIGNMENT FORM, added after one shipped. 65 lines of chunk_decode.tsp's ck_sink_file --
    `local sink = function(...)`, `local finished = false`, `local finish = function()` -- were
    duplicated into the same function body by a commit whose message said it rewrote three comments.
    The pattern above cannot see it: there is no `function NAME(` anywhere in it. luac 5.0.2 accepts
    it, the nesting check does not apply, 2810 assertions passed, and it reached both shipping
    archives. The later copy wins, so the dead copy is the one a reader is most likely to edit.
    """
    seen, errs = {}, []
    lines = code.split('\n')
    for lineno, line in enumerate(lines, 1):
        m = re.match(r'(\s+)?function\s+([A-Za-z_][A-Za-z0-9_.:]*)\s*\(', line)
        if not m:
            continue
        indent, fn = m.group(1), m.group(2)
        if indent:
            errs.append(f'{name}:{lineno}: `function {fn}` is indented, so it is defined INSIDE another '
                        f'function body -- redefined on every call, and invisible until that call. Use '
                        f'`local function` for a helper, or move it to file scope')
        if fn in seen:
            errs.append(f'{name}:{lineno}: `function {fn}` is already defined at line {seen[fn]} -- the '
                        f'later one silently wins, and only when its enclosing scope runs')
        else:
            seen[fn] = lineno

    # `local NAME = function`, scoped to the enclosing top-level function. Scope is tracked by column
    # alone -- a `function` at column 0 opens one and an `end` at column 0 closes it -- which is exact
    # for this tree because every file-scope definition here is unindented.
    scope, lseen = False, {}
    for lineno, line in enumerate(lines, 1):
        if re.match(r'(local\s+)?function\s+[A-Za-z_]', line):
            scope, lseen = True, {}
            continue
        if re.match(r'end\s*$', line):
            scope, lseen = False, {}
            continue
        if not scope:
            continue
        m = re.match(r'\s+local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\b', line)
        if not m:
            continue
        fn = m.group(1)
        if fn in lseen:
            errs.append(f'{name}:{lineno}: `local {fn} = function` is already defined at line '
                        f'{lseen[fn]} in the same function body -- the later one wins and the earlier '
                        f'is dead code that reads as live')
        else:
            lseen[fn] = lineno
    return errs


# THE pcall BUDGET IS A SHIPPING CONSTRAINT, NOT A STYLE PREFERENCE. Above some number of pcall
# SITES in the loaded script the firmware bluescreens on load. Measured ladder: 227 sites crash, 191
# crash, 132 run -- so the boundary is somewhere in (132, 191] and 132 is the largest count observed
# to work. The ceiling is set there rather than at today's count, so ordinary work has room and only
# a walk back toward the cliff trips the gate.
#
# COUNTED ON THE ARTEFACT, because that is what the instrument loads. Per-module counts are not the
# constraint and six modules each under a share of the budget can still sum past it.
#
# A LITERAL COUNT OF `pcall(`, which is why it runs on the STRIPPED body: a pcall named in a comment
# is not a site, and this file's own comments would otherwise inflate the app's figure.
PCALL_CEILING = 132


def check_pcall_budget(code, name):
    if not name.endswith('.tspa'):
        return []
    n = len(re.findall(r'\bpcall\s*\(', code))
    if n <= PCALL_CEILING:
        return []
    return [f'{name}: {n} pcall sites, over the {PCALL_CEILING} ceiling -- 191 sites bluescreened '
            f'this firmware on load and 132 is the largest count measured to run. Remove guards '
            f'rather than raising the ceiling; a guard on our own code is the first to go, and '
            f'`pcall(f, x)` beats `pcall(function() f(x) end)` on allocation but counts the same']


# A REAL LUA 5.0.2 PARSER, WHICH THE DOCSTRING ABOVE USED TO SAY DID NOT EXIST. It does: 5.0.2 is a
# 150 kB tarball that builds in seconds, and tools/get_lua502.sh puts luac in out/lua502/bin. Everything
# in INCOMPAT above is a hand-written approximation of what that parser does exactly, and the parser also
# catches the constructs nobody thought to add -- it found the one that mattered on its first run.
#
# HEX LITERALS ARE NORMALISED FIRST, and this is a MEASURED divergence rather than a convenience. Stock
# 5.0.2 does not lex 0x00DCFF: its numeral scanner stops at the 'x', so the colour constants throughout
# serial_ui.tsp read as `0` followed by a name and the parse fails. The instrument's Lua accepts them --
# proved by the app loading and running -- so refusing them here would be the gate contradicting the
# hardware. Every other 5.0.2 rule is enforced as written.
LUAC = 'out/lua502/bin/luac'
HEXLIT = re.compile(r'\b0[xX][0-9A-Fa-f]+\b')


def parse502(path, body, luac):
    import subprocess
    import tempfile
    src = HEXLIT.sub(lambda m: str(int(m.group(0), 16)), body)
    fh = tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False)
    fh.write(src)
    fh.close()
    try:
        r = subprocess.run([luac, '-p', fh.name], capture_output=True, text=True)
        if r.returncode == 0:
            return []
        # The parser names ITS temporary file; rewrite that to the real path so the line is clickable.
        msg = (r.stderr or r.stdout or 'parse failed').strip().replace(fh.name, path)
        return [m.replace(luac + ': ', '') for m in msg.split('\n') if m.strip()]
    finally:
        os.unlink(fh.name)


def main(paths):
    # NO PATHS IS NOT A CLEAN RUN. `python3 tools/lint_tsp.py` with no arguments linted zero files and
    # exited 0, which reads in a transcript exactly like every file passing -- a verdict derived from no
    # evidence, which is this project's worst failure mode and the one it keeps writing comments about.
    # release_sweep.py passes tsp_files(); anyone invoking this by hand has to as well.
    if not paths:
        print('REFUSING: no files given, and linting nothing is not passing.')
        print('  python3 tools/lint_tsp.py tsp/*.tsp')
        return 2
    require = '--require-parser' in paths
    paths = [p for p in paths if not p.startswith('--')]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    luac = os.path.join(root, LUAC)
    if not os.path.exists(luac):
        # SAID OUT LOUD, because a gate that quietly covers less than it says it does is how a syntax
        # error reached the instrument twice. --require-parser makes this fatal, which is what anything
        # about to spend instrument time should pass.
        print('NOTE: no Lua 5.0.2 parser at %s -- structural checks only.' % LUAC)
        print('      build it once with: sh tools/get_lua502.sh')
        if require:
            return 2
        luac = None
    bad = 0
    for p in paths:
        src = open(p).read()
        body = src
        # For a .tspa, lint only the script body between loadscript/endscript.
        if p.endswith('.tspa'):
            lines = src.replace('\r\n', '\n').split('\n')
            try:
                a = next(i for i, l in enumerate(lines) if l.startswith('loadscript '))
                b = next(i for i, l in enumerate(lines) if l.strip() == 'endscript')
            except StopIteration:
                print(f'{p}: FAIL -- no loadscript/endscript wrapper')
                bad += 1
                continue
            body = '\n'.join(lines[a + 1:b])
        code = strip(body)
        errs = (check_blocks(code, p) + check_compat(code, p) + check_globals(code, p)
                + check_dupes(code, p) + check_pcall_budget(code, p))
        # THE PARSER RUNS ON THE UNSTRIPPED BODY, because a string or a comment that opens a long
        # bracket and never closes it is a syntax error the blanking pass would have hidden.
        if luac is not None:
            errs = errs + parse502(p, body, luac)
        if errs:
            bad += 1
            print(f'{p}: {len(errs)} problem(s)')
            for e in errs:
                print('   ', e)
        else:
            print(f'{p}: OK')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

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


def app_namespace(code, default='sdec'):
    """The single global table this module hangs everything off.

    Detected from the idempotent declaration every module opens with,
    `<ns> = <ns> or {}`, rather than hardcoded: `usb_log.tsp` deliberately uses
    `ulog` so it can be shared with other apps, and a linter that only knew one
    name would report every correct line in the other module as an error.
    """
    m = re.search(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\1\s+or\s+\{\}', code, re.M)
    return m.group(1) if m else default


def check_globals(code, name):
    """Assignments at column 0 (file scope) must be local or <ns>.* fields.

    The DMM6500 does NOT isolate app namespaces: every TTI app and the firmware
    share one Lua global environment, and event command strings resolve names
    there too, so a generic global is a real collision risk.
    """
    ns = app_namespace(code)
    errs = []
    for lineno, line in enumerate(code.split('\n'), 1):
        m = re.match(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=[^=]', line)
        if m and m.group(1).split('.')[0] != ns:
            errs.append(f'{name}:{lineno}: bare global assignment `{m.group(1)}` '
                        f'(everything must hang off the {ns} table)')
        m = re.match(r'function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', line)
        if m:
            errs.append(f'{name}:{lineno}: bare global function `{m.group(1)}` '
                        f'(must be {ns}.{m.group(1)})')
    return errs


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
        errs = check_blocks(code, p) + check_compat(code, p) + check_globals(code, p)
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

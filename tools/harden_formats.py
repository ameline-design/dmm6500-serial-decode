#!/usr/bin/env python3
"""Make every string.format() in tsp/ tolerate a nil argument.

WHY. `%d` on a nil RAISES, and so does `%s`. A pcall at the CALL SITE absorbs that -- a guard
around our own formatting rather than around a firmware boundary -- so a latent nil behind one
is invisible. Taking those guards off surfaces them, and one is real: ck_summary formats
tot.nsmp, which is nil on the cancelled path. This closes the class rather than that instance.

THE TRANSFORM, per argument, decided by its own conversion specifier:

    numeric (d i o u x X e E f g G)   ->  `arg or 0`
    string  (s q)                     ->  `tostring(arg)`

WHAT IT DELIBERATELY DOES NOT DO:

  * It does not touch an argument that already reads `... or ...` at the top level, or that is
    already a tostring(...) call, or a literal. Those are handled.
  * `or 0` protects a plain field read, NOT an arithmetic expression: `x * 2 or 0` still raises
    on a nil x, because the multiply happens first. Those are reported rather than rewritten,
    because the fix there is to defend the variable, not the format call.
  * It skips a call whose format string is not a literal, since the specifiers cannot be paired
    with arguments without one.

Run from the repo root. --check reports and writes nothing.
"""
import argparse
import glob
import re
import sys

SPEC = re.compile(r'%[-+ #0]*[0-9]*(?:\.[0-9]+)?([diouxXeEfgGqs])')
NUMERIC = set('diouxXeEfgG')
STRINGY = set('sq')
# An argument that already defends itself, or cannot be nil.
SAFE = re.compile(r'^\s*(?:tostring\(.*\)|[\'"].*[\'"]|-?[0-9.]+(?:e-?\d+)?)\s*$', re.S)
ARITH = re.compile(r'[+\-*/%^]|\.\.')


def find_calls(src):
    """Yield (start, end) spans of each string.format( ... ) call, parens balanced."""
    for m in re.finditer(r'string\.format\(', src):
        i = m.end()
        depth, in_str, q, esc = 1, False, '', False
        while i < len(src) and depth:
            c = src[i]
            if in_str:
                if esc:
                    esc = False
                elif c == '\\':
                    esc = True
                elif c == q:
                    in_str = False
            elif c in '\'"':
                in_str, q = True, c
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            i += 1
        if depth == 0:
            yield m.start(), i


def split_args(s):
    """Top-level comma split, ignoring commas inside parens, braces or strings."""
    out, cur, depth, in_str, q, esc = [], [], 0, False, '', False
    for c in s:
        if in_str:
            cur.append(c)
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == q:
                in_str = False
            continue
        if c in '\'"':
            in_str, q = True, c
            cur.append(c)
        elif c in '([{':
            depth += 1
            cur.append(c)
        elif c in ')]}':
            depth -= 1
            cur.append(c)
        elif c == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
        else:
            cur.append(c)
    out.append(''.join(cur))
    return out


def top_level_or(s):
    """True if `s` has an `or` outside any bracket -- i.e. it already defends itself."""
    depth, in_str, q, esc = 0, False, '', False
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == q:
                in_str = False
        elif c in '\'"':
            in_str, q = True, c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif depth == 0 and s.startswith(' or ', i):
            return True
        i += 1
    return False


def harden(src, report):
    out, pos, changed = [], 0, 0
    for a, b in find_calls(src):
        call = src[a:b]
        inner = call[len('string.format('):-1]
        args = split_args(inner)
        fmt = args[0].strip()
        if not (len(fmt) >= 2 and fmt[0] == fmt[-1] and fmt[0] in '\'"'):
            continue                      # not a literal: cannot pair specifiers
        specs = SPEC.findall(fmt)
        rest = args[1:]
        if not rest or len(specs) != len(rest):
            continue                      # mismatched: leave alone rather than guess
        newargs, touched = [], False
        for spec, arg in zip(specs, rest):
            lead = arg[:len(arg) - len(arg.lstrip())]
            body = arg.strip()
            if SAFE.match(body) or top_level_or(body):
                newargs.append(arg)
                continue
            if ARITH.search(body):
                report.append((body, spec))
                newargs.append(arg)
                continue
            if spec in NUMERIC:
                newargs.append(lead + body + ' or 0')
                touched = True
            elif spec in STRINGY:
                newargs.append(lead + 'tostring(' + body + ')')
                touched = True
            else:
                newargs.append(arg)
        if touched:
            out.append(src[pos:a])
            out.append('string.format(' + ','.join([args[0]] + newargs) + ')')
            pos = b
            changed += 1
    out.append(src[pos:])
    return ''.join(out), changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    total, report = 0, []
    for f in sorted(glob.glob('tsp/*.tsp')):
        src = open(f, newline='').read()
        new, n = harden(src, report)
        if n and not a.check:
            open(f, 'w', newline='').write(new)
        if n:
            print('  %-24s %3d format call(s) hardened' % (f, n))
        total += n
    print('total: %d' % total)
    if report:
        print('\nNOT rewritten -- an arithmetic expression, where `or 0` would not help:')
        for body, spec in report[:20]:
            print('   %%%s  %s' % (spec, body[:84]))
        print('   (%d total)' % len(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())

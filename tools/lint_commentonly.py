#!/usr/bin/env python3
"""Prove an edit touched only comments: the code is unchanged against a git revision.

A comment cut that silently drops a line of arithmetic is the failure this guards. Strips
whole-line comments and blank lines from both sides and demands the remainder match, so a
moved comment is invisible here and a deleted statement is not.

WHAT IT DOES NOT PROVE, because a false clean bill is worse than no check:

  * IT IS A LEXICAL FILTER, NOT A PARSER. Lines are stripped on their leading '#' or '--'
    with no idea of string context, so a '#' line inside a Python triple-quoted string or a
    '--' line inside a Lua long string is treated as a comment and its changes are invisible.
    --check-strings reports whether either construct is present, and the packager refuses Lua
    long comments outright, but this file cannot see through them.
  * TRAILING COMMENTS ARE NOT STRIPPED. Cutting the tail off `local n = 3  -- why` changes a
    code line, and normalising that away would bless it. Such an edit is a code change.
  * NEITHER ARE STRING LITERALS, so editing prose inside one reports as CODE. A docstring, an
    assertion label and a report line are all prose a reader would call a comment, and all
    three are code to a parser -- so they are shown, not hidden. Reading such a hit means
    checking the string is descriptive and not a condition; this cannot make that call.

Comparison is byte-exact on the surviving lines, including trailing whitespace and line
endings: files are read as bytes and split on b'\\n', so a CRLF change fails rather than
passing silently.

Exit status is 0 only when every named file was compared and matched. A file with no version
at `rev` cannot be compared, so it is UNVERIFIED and exits non-zero -- otherwise a typo in a
path reports success from a run that checked nothing.

Usage:  python3 tools/lint_commentonly.py [--rev HEAD] [--check-strings] [FILE ...]
        with no FILE, checks every modified .lua/.py/.tsp in the working tree
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The constructs this filter cannot see through. Reported, never guessed at.
OPAQUE = {'.py': [b'"""', b"'''"], '.lua': [b'--[[', b'--]]', b'--[=['],
          '.tsp': [b'--[[', b'--]]', b'--[=[']}


def code_lines(raw, mark):
    out = []
    for ln in raw.split(b'\n'):
        s = ln.strip()
        if s == b'' or s.startswith(mark):
            continue
        out.append(ln)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rev', default='HEAD')
    ap.add_argument('--check-strings', action='store_true',
                    help='also report multi-line string constructs this filter cannot see through')
    ap.add_argument('files', nargs='*')
    args = ap.parse_args()

    files = args.files
    if not files:
        out = subprocess.run(['git', 'diff', '--name-only', args.rev], cwd=ROOT,
                             capture_output=True, text=True).stdout
        files = [f for f in out.split('\n') if f.endswith(('.lua', '.py', '.tsp'))]
    if not files:
        print('nothing to check')
        return 0

    bad, unverified, opaque = 0, 0, []
    for f in sorted(files):
        rel = os.path.relpath(os.path.join(ROOT, f), ROOT)
        old = subprocess.run(['git', 'show', '%s:%s' % (args.rev, rel)], cwd=ROOT,
                             capture_output=True)
        if old.returncode != 0:
            unverified += 1
            print('  UNVERIFIED  %s   no %s version to compare against' % (rel, args.rev))
            continue
        with open(os.path.join(ROOT, rel), 'rb') as fh:
            new = fh.read()
        ext = os.path.splitext(rel)[1]
        mark = b'#' if ext == '.py' else b'--'
        a, b = code_lines(old.stdout, mark), code_lines(new, mark)
        if args.check_strings:
            for d in OPAQUE.get(ext, []):
                if d in new:
                    opaque.append('%s contains %s' % (rel, d.decode()))
        if a == b:
            print('  ok     %s   code unchanged (%d lines)' % (rel, len(b)))
            continue
        bad += 1
        print('  CODE   %s   %d -> %d code lines' % (rel, len(a), len(b)))
        sa, sb = set(a), set(b)
        for ln in a:
            if ln not in sb:
                print('      -%s' % ln.decode('utf-8', 'replace')[:110])
        for ln in b:
            if ln not in sa:
                print('      +%s' % ln.decode('utf-8', 'replace')[:110])

    if opaque:
        print('\nmulti-line strings this filter cannot see through:')
        for o in sorted(set(opaque)):
            print('  %s' % o)

    if bad or unverified:
        print('\n%d file(s) changed code, %d unverified' % (bad, unverified))
        return 1
    print('\ncomment-only: %d file(s)' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())

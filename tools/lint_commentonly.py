#!/usr/bin/env python3
"""Prove an edit touched only comments: the code is byte-identical to a git revision.

A comment cut that silently drops a line of arithmetic is the failure this guards. Strips
whole-line comments and blank lines from both sides and demands the remainder match exactly,
so a moved comment is invisible here and a deleted statement is not.

TRAILING COMMENTS ARE NOT STRIPPED. Cutting the tail off `local n = 3  -- why` changes a code
line, and a checker that normalised that away would bless it. Such an edit must be reviewed as
a code change, and this refuses to call it comment-only.

NEITHER ARE STRING LITERALS, so editing prose inside one reports as CODE. A Python docstring, a
test's assertion label and a report line are all prose that a reader would call a comment, and
all three are code to a parser -- so they are shown, not hidden. Reading such a hit means
checking the string is descriptive and not a condition; the tool cannot make that call.

Usage:  python3 tools/lint_commentonly.py [--rev HEAD] [FILE ...]
        with no FILE, checks every modified .lua/.py/.tsp in the working tree
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def code_lines(text, py):
    mark = '#' if py else '--'
    out = []
    for ln in text.split('\n'):
        s = ln.strip()
        if s == '' or s.startswith(mark):
            continue
        out.append(ln.rstrip())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rev', default='HEAD')
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

    bad = 0
    for f in sorted(files):
        rel = os.path.relpath(os.path.join(ROOT, f), ROOT)
        old = subprocess.run(['git', 'show', '%s:%s' % (args.rev, rel)], cwd=ROOT,
                             capture_output=True, text=True)
        if old.returncode != 0:
            print('  NEW    %s (no %s version)' % (rel, args.rev))
            continue
        with open(os.path.join(ROOT, rel)) as fh:
            new = fh.read()
        py = rel.endswith('.py')
        a, b = code_lines(old.stdout, py), code_lines(new, py)
        if a == b:
            print('  ok     %s   code identical (%d lines)' % (rel, len(b)))
            continue
        bad += 1
        print('  CODE   %s   %d -> %d code lines' % (rel, len(a), len(b)))
        sa, sb = set(a), set(b)
        for ln in a:
            if ln not in sb:
                print('      -%s' % ln[:110])
        for ln in b:
            if ln not in sa:
                print('      +%s' % ln[:110])
    if bad:
        print('\n%d file(s) changed code, not just comments' % bad)
        return 1
    print('\ncomment-only: %d file(s)' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())

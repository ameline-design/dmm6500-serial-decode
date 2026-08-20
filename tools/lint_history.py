#!/usr/bin/env python3
"""Find comments that talk about the past instead of the code.

The standing rule: a comment states what the code does NOW. No dates, no "used to", no
"no longer", no session numbers, no crediting who found a defect. Where a comment both
records a fixed defect and stops it being reintroduced, it keeps the CONSTRAINT and drops
the story -- "Z, because otherwise X" rather than "X broke, so now Z".

DOCSTRINGS ARE SCANNED, NOT JUST '#' AND '--' LINES, and that is the whole reason this
exists as a tool rather than a grep. A Python docstring carries no comment marker, so a
prefix-matching sweep skips every one of them -- and this repo keeps its longest prose
there: cyclic_find, head_damage and judge_payload in bench_uart.py explain the judging
rules a bench verdict depends on. Matching CASE-INSENSITIVELY matters for the same reason:
the emphatic forms this codebase favours ("IT USED TO", "NO LONGER") slip past a
lower-case pattern.

    python3 tools/lint_history.py                 # every .lua/.py in tools/, every .tsp
    python3 tools/lint_history.py FILE ...
    python3 tools/lint_history.py --count         # one line per file

Exit 1 if anything is found, so it can gate a release.
"""
import argparse
import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Each entry is (pattern, what it is). Deliberately narrow: a phrase earns a place here only
# if a present-tense rewrite always exists, so a hit is a defect rather than a discussion.
PATTERNS = [
    (r'\bused to\b',                    'past tense'),
    (r'\bno longer\b',                  'past tense'),
    (r'\bpreviously\b',                 'past tense'),
    (r'\bformerly\b',                   'past tense'),
    (r'\bhad been\b',                   'past tense'),
    (r'\bup until\b|\buntil now\b',     'chronology'),
    (r'\bthe old \w+',                  'past tense'),
    (r'\bfirst version\b|\bfirst attempt\b|\bfirst draft\b', 'chronology'),
    (r'\bearlier version\b',            'chronology'),
    (r'\bfor a while\b',                'chronology'),
    (r'\bthis session\b|\blast session\b', 'chronology'),
    (r'\bsession ?\d+\w*\b',            'session number'),
    (r'\b20\d\d-\d\d-\d\d\b',           'date'),
    (r'\b(mon|tues|wednes|thurs|fri|satur|sun)day\b', 'day of the week'),
    (r'\byesterday\b|\btonight\b|\bthis morning\b', 'relative day'),
    (r'\b(caught|found|spotted|reported) by\b', 'credited catcher'),
    (r'\bwas measured\b|\bwas wrong\b|\bwas safe\b|\bwas built\b', 'past tense'),
    (r'\bit was \d',                    'past tense'),
]
COMPILED = [(re.compile(p, re.I), why) for p, why in PATTERNS]

# Prose that is ABOUT the past and cannot be rewritten out of it: provenance of external
# evidence, and a datestamp inside a cited document title. A hit on one of these lines is
# not a defect, so they are skipped by exact text rather than by weakening a pattern.
ALLOW = (
    '2021-12-07',   # the Siglent application note's own publication date
)


def hits(text, kind):
    out = []
    for i, ln in enumerate(text.split('\n')):
        if any(a in ln for a in ALLOW):
            continue
        for rx, why in COMPILED:
            m = rx.search(ln)
            if m:
                out.append((i, kind, why, m.group(0), ln.strip()))
                break
    return out


def scan(path):
    """-> list of (line number or None, kind, why, matched text, the line)."""
    with open(path, errors='replace') as f:
        src = f.read()
    ext = os.path.splitext(path)[1]
    mark = '#' if ext == '.py' else '--'
    found = []
    # comment lines, by prefix
    for i, ln in enumerate(src.split('\n')):
        if not ln.lstrip().startswith(mark):
            continue
        if any(a in ln for a in ALLOW):
            continue
        for rx, why in COMPILED:
            m = rx.search(ln)
            if m:
                found.append((i + 1, 'comment', why, m.group(0), ln.strip()))
                break
    # docstrings, which carry no marker
    if ext == '.py':
        try:
            tree = ast.parse(src)
        except SyntaxError:
            tree = None
        if tree is not None:
            for node in ast.walk(tree):
                if not isinstance(node, (ast.Module, ast.FunctionDef,
                                         ast.AsyncFunctionDef, ast.ClassDef)):
                    continue
                doc = ast.get_docstring(node, clean=False)
                if not doc:
                    continue
                name = getattr(node, 'name', '<module>')
                base = getattr(node, 'lineno', 1)
                for off, kind, why, txt, ln in hits(doc, 'docstring'):
                    found.append((base, 'docstring %s' % name, why, txt, ln))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--count', action='store_true', help='one line per file, no detail')
    ap.add_argument('files', nargs='*')
    args = ap.parse_args()

    files = args.files or (sorted(glob.glob(os.path.join(ROOT, 'tools', '*.lua')))
                           + sorted(glob.glob(os.path.join(ROOT, 'tools', '*.py')))
                           + sorted(glob.glob(os.path.join(ROOT, 'tsp', '*.tsp'))))
    total = 0
    for f in files:
        rel = os.path.relpath(f, ROOT)
        if os.path.basename(rel) == os.path.basename(__file__):
            continue                      # its own PATTERNS table is not prose
        found = scan(f)
        if not found:
            continue
        total += len(found)
        if args.count:
            print('%4d  %s' % (len(found), rel))
            continue
        print('\n%s  (%d)' % (rel, len(found)))
        for line, kind, why, txt, ln in found:
            print('  %-6s %-18s %-16s %s' % (line, kind[:18], why, ln[:96]))

    print('\n%d line(s) talking about the past' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())

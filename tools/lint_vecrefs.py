#!/usr/bin/env python3
"""Every vector id named in tools/ must exist in MAP or be listed in RETIRED.

THE BUG THIS EXISTS TO CATCH, stated as a rule rather than a story: retiring a vector by deleting its
row from MAP leaves every other reference to it dangling, and nothing notices. The references do not
fail at import -- they fail when the harness runs, as `VN.arb('vNN')` raising deep inside a bench
stage, or as a release preflight refusing the whole hardware half over one name.

RETIRED IS THE POINT OF THE FILE. An id in neither MAP nor RETIRED is the error: it means either a
typo, or a vector that was dropped without anyone saying so. Listing it in RETIRED is a positive
statement that the id is gone on purpose, which is exactly what a deletion cannot express.

WHAT IT SCANS AND WHAT IT CANNOT. Quoted ids in .py and .lua under tools/, so an id built by string
concatenation ('v' .. n) is invisible here -- and so is one in a comment, deliberately: a comment
naming a retired vector is a documentation question, not a broken call. Both limits are why this is
narrow rather than clever.

    python3 tools/lint_vecrefs.py          # exit 1 if anything dangles
    python3 tools/lint_vecrefs.py --list   # every id found, and where
"""
import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))

from vector_names import MAP, RETIRED                            # noqa: E402

# The shapes the manifest actually uses: vNN with an optional letter (v41, v44a, v48b), rNN for the
# random family, jNN for the jitter family. Anchored inside quotes so a bare word in prose is not a
# reference, and bounded so 'v1' or a version string cannot match.
ID_RE = re.compile(r"""['"]((?:v\d{2}[a-z]?|r\d{2}|j\d{2}))['"]""")


def scan():
    """-> {vid: [(relpath, lineno), ...]} for ids in code, comments excluded."""
    found = {}
    files = sorted(glob.glob(os.path.join(ROOT, 'tools', '*.py'))
                   + glob.glob(os.path.join(ROOT, 'tools', '*.lua')))
    for path in files:
        rel = os.path.relpath(path, ROOT)
        if os.path.basename(rel) in ('lint_vecrefs.py', 'vector_names.py'):
            continue                       # the table itself, and this file's own pattern
        mark = '#' if path.endswith('.py') else '--'
        with open(path, errors='replace') as f:
            for n, line in enumerate(f, 1):
                code = line.split(mark, 1)[0] if mark in line else line
                if not code.strip():
                    continue
                for vid in ID_RE.findall(code):
                    found.setdefault(vid, []).append((rel, n))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true', help='show every id found and where')
    a = ap.parse_args()

    found = scan()
    known = set(MAP) | set(RETIRED)
    dangling = {v: w for v, w in found.items() if v not in known}

    if a.list:
        for vid in sorted(found):
            where = ' '.join('%s:%d' % (f, n) for f, n in found[vid][:6])
            tag = 'MAP' if vid in MAP else ('RETIRED' if vid in RETIRED else 'DANGLING')
            print('  %-6s %-9s %s' % (vid, tag, where))
        print()

    print('%d id(s) referenced, %d in MAP, %d retired, %d dangling'
          % (len(found), sum(1 for v in found if v in MAP),
             sum(1 for v in found if v in RETIRED), len(dangling)))
    if not dangling:
        return 0
    print()
    for vid in sorted(dangling):
        print('DANGLING %s -- referenced but in neither MAP nor RETIRED:' % vid)
        for f, n in dangling[vid]:
            print('    %s:%d' % (f, n))
    print('\nAdd it to MAP if it should exist, or to RETIRED if it is gone on purpose. A deletion '
          'from MAP alone leaves these references to fail when the harness runs.')
    return 1


if __name__ == '__main__':
    sys.exit(main())

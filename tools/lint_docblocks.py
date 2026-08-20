#!/usr/bin/env python3
"""Find doc blocks that the packager will attach to the WRONG symbol.

WHY. package_tspa.py ships the comment block ADJACENT to each definition. That is only correct if one
block describes one symbol -- and in these modules two doc blocks are sometimes run together with no
blank line, so the pair attaches to whichever symbol follows and the archive documents it with someone
else's text. Three were found this way and fixed: the q-gate paragraph sat above `ratemargin`,
`sdec.decode`'s above the relock constants, and `ua_submultiple`'s was destroyed by two assignments.

THE SIGNATURE is a new ALL-CAPS topic opener immediately after a line that ends a sentence, with no `--`
separator between them. This codebase legitimately uses ALL-CAPS for emphasis INSIDE a block, so the
`--` separator is what distinguishes emphasis from a new block -- which is why the check requires its
absence and a finished sentence before it.

IT REPORTS, IT DOES NOT FAIL. The signature is a heuristic and a comment is not a contract, so this is a
reading aid rather than a gate: it exits 0 with a count. Only the hits whose following line is a
DEFINITION change the archive; the rest are inline comments the packager drops anyway, and they are
marked so.

    python3 tools/lint_docblocks.py            # every module the packager ships
    python3 tools/lint_docblocks.py --archive  # only the hits that reach the archive
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import package_tspa as P                                        # noqa: E402

ROOT = P.ROOT
CAPS = re.compile(r"^--\s+[A-Z][A-Z0-9 ,'()/%-]{18,}")


def scan(path):
    """-> list of (line_no, opener, new_topic, following_code, reaches_archive)."""
    lines = [l.rstrip('\r') for l in open(path).read().split('\n')]
    hits, cur = [], []
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith('--'):
            cur.append((i + 1, ln))
            continue
        if cur:
            for k in range(1, len(cur)):
                prev = cur[k - 1][1].strip()
                if CAPS.match(cur[k][1].strip()) and prev.endswith('.') and prev != '--':
                    # A definition consumes the block; an assignment carries it on to the next one, so
                    # both reach the archive. Anything else drops it.
                    reaches = P.is_definition(s) or P.DEF_ASSIGN.match(s) is not None
                    hits.append((cur[k][0], cur[0][1].strip(), cur[k][1].strip(), s, reaches))
            cur = []
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--archive', action='store_true',
                    help='only hits that reach the shipped archive')
    a = ap.parse_args()

    total, shipped = 0, 0
    for m in P.MODULES:
        for no, opener, topic, after, reaches in scan(os.path.join(ROOT, m)):
            total += 1
            if reaches:
                shipped += 1
            elif a.archive:
                continue
            print('%s:%d%s' % (m, no, '' if reaches else '   (inline -- not shipped)'))
            print('   block opens : %s' % opener[:94])
            print('   new topic   : %s' % topic[:94])
            print('   attaches to : %s' % after[:94])
            print()
    print('%d run-together blocks, %d of them reach the archive' % (total, shipped))
    return 0


if __name__ == '__main__':
    sys.exit(main())

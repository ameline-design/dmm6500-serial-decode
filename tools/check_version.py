#!/usr/bin/env python3
"""One release version, stated the same way in every place that states it.

THE DEFECT THIS EXISTS FOR: V1.20 was tagged in git while the manifest, all three shipped documents
and all three shipped PDFs still said 1.11. Every one of those artefacts was individually consistent
and correct-looking, nothing in the gate compared them with each other, and the mismatch was found by
a human opening a PDF. tools/verify_tspa.lua checks only that a Version field EXISTS.

The places a version is asserted, and what each one is:

    tools/package_tspa.py MANIFEST   THE SOURCE OF TRUTH -- the only one edited by hand
    Serial_Decode.tspa               generated from it; what the instrument's installer reads
    README.md, docs/*.md             the byline under each title
    README.pdf, docs/*.pdf           WHAT THE READER ACTUALLY OPENS, generated from the markdown
    the git tag                      V<version>, which is how a release is named everywhere else

THE PDFs ARE CHECKED, not inferred from the markdown, because the whole failure was a PDF disagreeing
with its own source: they are tracked binaries rebuilt by a separate stage, so a markdown edit that
never reached tools/mkpdf.sh leaves the shipped document saying something else.

Usage:  python3 tools/check_version.py
Exit 1 on any disagreement.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import package_tspa                                                    # noqa: E402

TSPA = os.path.join(ROOT, 'Serial_Decode.tspa')
# EVERY SHIPPED DOCUMENT AND ITS PDF, paired. docs/BENCH.md carries the byline for this reason: a
# tracked PDF that names no version cannot be checked against anything, and a reader cannot tell which
# build it describes. The vendor PDFs under docs/ are not ours and are not listed.
DOCS = ['README.md', 'docs/MANUAL.md', 'docs/REFERENCE.md', 'docs/BENCH.md']
# The byline sits under the title, so a handful of lines is the whole search. Bounded rather than
# whole-file: 'version 1.20' occurring in body prose is not the byline and must not satisfy this.
HEAD_LINES = 12
# TWO DIGITS AFTER THE DOT, which is not cosmetic: the installer's compares cannot be assumed numeric,
# and as strings '1.10' < '1.4' -- so a one-digit release reads as a downgrade at the next one. See the
# comment on MANIFEST's Version entry in tools/package_tspa.py.
VERSION_RE = re.compile(r'^\d+\.\d\d$')
# Release tags are V<major>.<minor>, either case. Anything else -- a branch name, an annotated
# milestone -- is not a release tag and is not compared. Compared as (int, str) so the major is
# numeric: as pure strings 'V10.00' would sort below 'V9.20', which is the same trap two digits after
# the dot exists to close one level down.
TAG_RE = re.compile(r'^[Vv](\d+)\.(\d+)$')
MANIFEST_RE = re.compile(r"\(\s*'Version'\s*,\s*'([^']+)'\s*\)")


def git(*args):
    """git output, or None if git has nothing to say. Never raises: no repo is a SKIP, not a crash."""
    try:
        p = subprocess.run(('git',) + args, cwd=ROOT, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode('utf-8', 'replace')


def pdf_page1(path):
    """Page 1 of a PDF as text, or None if pdftotext is not installed."""
    try:
        p = subprocess.run(['pdftotext', '-f', '1', '-l', '1', '-layout', path, '-'],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode('utf-8', 'replace')


def main():
    want = dict(package_tspa.MANIFEST)['Version']
    fails, skips, nchecked = [], [], 0
    print('tools/package_tspa.py MANIFEST declares version %s' % want)

    if not VERSION_RE.match(want):
        fails.append('the version %r is not <major>.<two digits>, which is what keeps a string '
                     'compare monotonic across releases' % want)
    nchecked += 1

    # THE ARCHIVE. Read as bytes and strip the CR: the .tspa ships with CRLF line endings, so a text
    # compare against a stripped line is the only one that matches on either.
    with open(TSPA, 'rb') as fh:
        head = fh.read(4096).decode('utf-8', 'replace')
    m = re.search(r'^--\s*\$Version:\s*(.+?)\s*$', head, re.M)
    got = m.group(1).strip() if m else None
    if got is None:
        fails.append('Serial_Decode.tspa has no -- $Version: line in its manifest header')
    elif got != want:
        fails.append('Serial_Decode.tspa says %r, not %r -- rerun tools/package_tspa.py' % (got, want))
    else:
        print('  Serial_Decode.tspa           %s  ok' % got)
    nchecked += 1

    # THE MARKDOWN, then the PDF built from it. Both, in that order, so a failure says which of the two
    # is stale -- markdown alone means the byline was never edited, PDF alone means mkpdf never ran.
    for rel in DOCS:
        path = os.path.join(ROOT, rel)
        with open(path) as fh:
            lines = [fh.readline() for _ in range(HEAD_LINES)]
        stated = [l.strip() for l in lines if re.search(r'\bversion\s+\d', l, re.I)]
        nchecked += 1
        if not stated:
            fails.append('%s states no version in its first %d lines' % (rel, HEAD_LINES))
        elif not any(re.search(r'\bversion\s+' + re.escape(want) + r'\b', s, re.I) for s in stated):
            fails.append('%s says %r, not version %s' % (rel, stated[0], want))
        else:
            print('  %-28s %s  ok' % (rel, want))

        pdf = os.path.join(ROOT, re.sub(r'\.md$', '.pdf', rel))
        nchecked += 1
        if not os.path.exists(pdf):
            fails.append('%s does not exist, so no shipped document was checked for %s'
                         % (os.path.relpath(pdf, ROOT), rel))
            continue
        text = pdf_page1(pdf)
        if text is None:
            # A FAILURE, NOT A SKIP. This is the one check the defect actually needed -- a PDF saying
            # 1.11 under a V1.20 tag -- and a skip that only prints a line is indistinguishable from a
            # pass to anything reading the exit code. The gate already needs pandoc and Chrome to build
            # these files, so needing poppler to read them back is the same class of dependency.
            fails.append('%s could not be read: pdftotext is not installed, so the shipped PDF was '
                         'never checked. brew install poppler' % os.path.relpath(pdf, ROOT))
            continue
        # THE BYLINE, NOT THE PAGE. Searching all of page 1 would accept a stale byline on any document
        # whose body happens to mention the new version -- and REFERENCE.md's body discusses versions.
        head = [l.strip() for l in text.splitlines() if l.strip()][:HEAD_LINES]
        stated = [l for l in head if re.search(r'\bversion\s+\d', l, re.I)]
        if any(re.search(r'\bversion\s+' + re.escape(want) + r'\b', l, re.I) for l in stated):
            print('  %-28s %s  ok  (byline, page 1)' % (os.path.relpath(pdf, ROOT), want))
        else:
            fails.append('%s does not state version %s in its byline%s -- rerun tools/mkpdf.sh'
                         % (os.path.relpath(pdf, ROOT), want,
                            ('; it says %r' % stated[0]) if stated else ''))

    # THE TAG, in both directions.
    #
    # DOWNWARD: no release tag may sort ABOVE the declared version. That is the exact shape of the
    # defect -- a V1.20 tag standing over a tree that says 1.11 -- and it is catchable without knowing
    # what the next release will be called.
    #
    # AND THE TREE THE TAG POINTS AT: if this version's own tag exists, the version recorded THERE must
    # be this one. A tag is a claim about a tree, and moving the version without moving the tag makes
    # the claim false in the direction nobody checks.
    tags = git('tag', '-l')
    if tags is None:
        skips.append('git has no tag list here, so nothing was compared against a release tag')
    else:
        wmaj, wmin = want.split('.', 1)
        wkey = (int(wmaj), wmin)
        rel = []
        for t in tags.split():
            m = TAG_RE.match(t)
            if m:
                rel.append(((int(m.group(1)), m.group(2)), '%s.%s' % m.groups(), t))
        if not rel:
            skips.append('no V<version> tags exist yet, so nothing was compared against one')
        else:
            top = max(rel)
            nchecked += 1
            if top[0] > wkey:
                fails.append('tag %s sorts ABOVE the declared version %s. Either the version was '
                             'never bumped or the tag names a release this tree is not.'
                             % (top[2], want))
            else:
                print('  highest release tag          %s  <= %s  ok' % (top[2], want))
            mine = [t for k, v, t in rel if v == want]
            if not mine:
                print('  version %s is not tagged yet -- tag it after this commit' % want)
            else:
                for t in mine:
                    nchecked += 1
                    blob = git('show', '%s:tools/package_tspa.py' % t)
                    if blob is None:
                        skips.append('tag %s has no tools/package_tspa.py to read a version from' % t)
                        nchecked -= 1
                        continue
                    mm = MANIFEST_RE.search(blob)
                    at = mm.group(1) if mm else None
                    if at != want:
                        fails.append('tag %s points at a tree declaring version %r, not %r. Move the '
                                     'tag to the commit that carries %s.' % (t, at, want, want))
                    else:
                        print('  tag %-24s declares %s  ok' % (t, at))

    print()
    for s in skips:
        print('SKIPPED: %s' % s)
    for f in fails:
        print('WRONG: %s' % f)
    if fails:
        print('%d of %d version statement(s) disagree with tools/package_tspa.py -- version %s'
              % (len(fails), nchecked, want))
        return 1
    print('version %s agrees in %d place(s) checked%s'
          % (want, nchecked, ', %d skipped' % len(skips) if skips else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())

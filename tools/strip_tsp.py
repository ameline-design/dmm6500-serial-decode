#!/usr/bin/env python3
"""Strip comments from TSP source before it goes down the socket.

WHY. tools/run_bench.py pushes the app and the bench engine as ONE loadscript chunk, and this tree
comments heavily on purpose -- so the LAN load was 944 kB over 18 268 lines against a packaged archive
of 514 kB. Every byte of that is pushed with no flow control. On 2026-10-22 a load of that size never
returned its sentinel and the instrument then reset the connection; the last load that worked was
16 334 lines. Comments cannot affect a compiled chunk, so they are the one half of the payload that
can be removed without changing what runs.

WHAT IT MUST NOT DO is break a string. `--` inside a quoted string is not a comment, and this tree has
plenty of them -- format strings, note text, the pattern `'rows=(%d+)'`. A stripper that treats them
as comments truncates a statement and produces a parse error at a line nobody wrote, which is exactly
the failure it is meant to prevent. So this is a scanner over quoting state, not a regular expression.

LINE NUMBERS ARE KEPT. A chunk that will not compile posts its reason WITH A LINE NUMBER and prints
nothing at all, so that number is the only diagnostic there is. Dropping comment-only lines would
renumber everything after the first one and make every future parse error point at the wrong place.
A comment-only line therefore becomes an EMPTY line: the byte count collapses, the line count does
not, and a reported line number still names the real source line.

    python3 tools/strip_tsp.py tsp/serial_core.tsp        # to stdout
    python3 tools/strip_tsp.py --selftest                 # properties, no instrument
"""
import sys


def _scan(src):
    """The scanner: comments gone, newlines inside long strings fenced as NUL."""
    out = []
    i, n = 0, len(src)
    # QUOTING STATE, tracked across the whole file: a long string can span lines, and a `--` inside
    # one is data.
    while i < n:
        c = src[i]
        if c == '-' and src.startswith('--', i):
            # A COMMENT. Long form first: --[[ ... ]] and --[=[ ... ]=] span lines.
            j = i + 2
            if j < n and src[j] == '[':
                k = j + 1
                eqs = 0
                while k < n and src[k] == '=':
                    eqs += 1
                    k += 1
                if k < n and src[k] == '[':
                    close = ']' + '=' * eqs + ']'
                    end = src.find(close, k + 1)
                    if end == -1:
                        end = n
                        body = src[i:end]
                    else:
                        body = src[i:end + len(close)]
                        end = end + len(close)
                    # KEEP THE NEWLINES the block spanned, so nothing after it moves.
                    out.append('\n' * body.count('\n'))
                    i = end
                    continue
            # A line comment: drop to the newline, keep the newline itself.
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '"' or c == "'":
            # A SHORT STRING. Copy verbatim, honouring backslash escapes, and stop at the newline so
            # an unterminated literal cannot swallow the rest of the file.
            q = c
            out.append(c)
            i += 1
            while i < n and src[i] != q and src[i] != '\n':
                if src[i] == '\\' and i + 1 < n:
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i])
                i += 1
            if i < n and src[i] == q:
                out.append(q)
                i += 1
            continue
        if c == '[':
            # A LONG STRING, [[ ... ]] or [=[ ... ]=]. Copied whole.
            k = i + 1
            eqs = 0
            while k < n and src[k] == '=':
                eqs += 1
                k += 1
            if k < n and src[k] == '[':
                close = ']' + '=' * eqs + ']'
                end = src.find(close, k + 1)
                end = n if end == -1 else end + len(close)
                # NEWLINES INSIDE A LONG STRING ARE FENCED. squeeze() drops blank lines, and a blank
                # line inside [[ ... ]] is part of the string's VALUE -- dropping it silently changes
                # what the program says. There are none in tsp/ or bench/ today (checked), so this
                # protects a future edit rather than present code. NUL cannot occur in TSP source.
                out.append(src[i:end].replace('\n', '\x00'))
                i = end
                continue
        out.append(c)
        i += 1
    return ''.join(out)


def strip(src):
    """-> source with comments removed, every line kept, long strings untouched."""
    # TRAILING WHITESPACE GOES, which is most of what a stripped comment line leaves behind -- but
    # never on a line holding a long string, where the trailing spaces are part of its value.
    out = []
    for ln in _scan(src).split('\n'):
        out.append(ln if '\x00' in ln else ln.rstrip())
    return '\n'.join(out).replace('\x00', '\n')


def squeeze(src):
    """Strip comments AND drop the blank lines they leave. -> (text, linemap)

    WHY THE BLANK LINES GO TOO, on the operator's instruction of 2026-10-22: the loadscript push is
    line-based with no flow control, so the LINE COUNT is a cost of its own and not just the bytes.
    Stripping comments alone left 18 268 lines because most of them had been comment-only; dropping
    the empties is what actually brings the line count down.

    AND WHY THE MAP EXISTS. Dropping lines renumbers everything after the first one, and a chunk that
    will not compile posts its reason WITH A LINE NUMBER and prints nothing at all -- so without a map
    that number would point at the wrong line forever. linemap[i] is the ORIGINAL 1-based line number
    of the i-th line of the output, so a reported number can be translated back.
    """
    kept, linemap = [], [0]
    orig = 1
    for ln in _scan(src).split('\n'):
        if ln.strip() != '':
            kept.append(ln.replace('\x00', '\n'))
            linemap.append(orig)
        # A LINE HOLDING A LONG STRING SPANS SEVERAL ORIGINAL LINES, so the counter advances by the
        # fenced newlines as well -- otherwise every mapping after such a string would be short.
        orig += 1 + ln.count('\x00')
    return '\n'.join(kept), linemap


def where(linemap, n):
    """Translate a line number reported against the squeezed text back to the original. -> int or None"""
    if n is None or n < 1 or n >= len(linemap):
        return None
    return linemap[n]


def selftest():
    bad = 0

    def ck(got, want, what):
        nonlocal bad
        if got != want:
            bad += 1
            print('  FAIL %s\n    got  %r\n    want %r' % (what, got, want))
        else:
            print('  ok   %s' % what)

    ck(strip('x = 1 -- a comment'), 'x = 1', 'a trailing comment goes')
    ck(strip('-- whole line\nx = 1'), '\nx = 1', 'a comment-only line becomes empty, keeping the line')
    ck(strip("s = '-- not a comment'"), "s = '-- not a comment'", 'a -- inside a string survives')
    ck(strip('s = "a -- b"'), 's = "a -- b"', 'and inside a double-quoted string')
    ck(strip("p = 'rows=(%d+)'"), "p = 'rows=(%d+)'", 'a pattern is untouched')
    ck(strip('--[[ block\nspanning ]]\nx = 1'), '\n\nx = 1', 'a block comment keeps its newlines')
    ck(strip('s = [[long\nstring]] -- c'), 's = [[long\nstring]]', 'a long string survives')
    ck(strip("s = 'it\\'s' -- c"), "s = 'it\\'s'", 'an escaped quote does not end the string')
    ck(strip('x = 1 - -2'), 'x = 1 - -2', 'a lone minus is not a comment')
    # LINE COUNT IS THE INVARIANT THAT MATTERS, because a parse error reports a line number.
    src = '-- a\n-- b\nx = 1\n-- c\ny = 2\n'
    ck(strip(src).count('\n'), src.count('\n'), 'the line count is preserved exactly')

    # SQUEEZE: comments gone AND the blank lines they left.
    txt, lm = squeeze(src)
    ck(txt, 'x = 1\ny = 2', 'squeeze drops the blank lines a stripped comment leaves')
    ck(where(lm, 1), 3, 'and maps its first line back to the original line 3')
    ck(where(lm, 2), 5, 'and its second back to line 5')
    ck(where(lm, 99), None, 'a line number past the end maps to nothing rather than lying')
    # A BLANK LINE THAT WAS ALWAYS BLANK goes too -- the point is the count, not the provenance.
    t2, m2 = squeeze('x = 1\n\n\ny = 2\n')
    ck(t2, 'x = 1\ny = 2', 'pre-existing blank lines go as well')
    ck(where(m2, 2), 4, 'and the map still points at the real line')
    # NOTHING INSIDE A LONG STRING IS TOUCHED, including its blank lines, or the string changes value.
    t3, _ = squeeze('s = [[a\n\nb]]\n')
    ck(t3, 's = [[a\n\nb]]', 'a blank line INSIDE a long string survives')
    return bad


def main(argv):
    if '--selftest' in argv:
        return 1 if selftest() else 0
    if not argv:
        print('usage: strip_tsp.py FILE [FILE ...]   |   --selftest')
        return 2
    for p in argv:
        sys.stdout.write(strip(open(p).read()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

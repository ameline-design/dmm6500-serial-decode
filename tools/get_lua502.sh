#!/bin/sh
# Build the interpreter the instrument actually runs, so a syntax error costs seconds instead of a
# session. Puts lua and luac in out/lua502/bin; tools/lint_tsp.py picks them up from there.
#
# WHY THIS EXISTS. The DMM6500's TSP is Lua 5.0.2, and the host has 5.5. Every gate this project had was
# therefore an approximation: luac 5.5 accepts constructs 5.0.2 rejects, and lint_tsp.py's INCOMPAT list
# is a hand-written guess at which ones. Twice that guess was wrong and the instrument answered with
# "syntax error" and a line number nobody read -- the second time it cost the last of an evening's
# instrument access. 5.0.2 is 150 kB of C that builds in about five seconds, and it answers exactly.
#
# TWO KNOWN DIVERGENCES FROM THE INSTRUMENT, both measured rather than assumed:
#
#   * HEX LITERALS. Stock 5.0.2 does not lex 0x00DCFF -- its numeral scanner stops at the 'x'. The
#     instrument's Lua does accept them: serial_ui.tsp is full of hex colours and the app loads and runs.
#     lint_tsp.py normalises them to decimal before parsing for exactly this reason.
#   * THE FIRMWARE'S OWN GLOBALS. luac -p only parses, so it never looks up display, file, tspnet or
#     smu -- which is what makes it usable as a pure syntax gate against modules it cannot execute.
#
# It is not committed as a binary: out/ is gitignored, and a checked-in Mach-O would be both unportable
# and unreviewable. Run this once per machine.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/out/lua502"
TMP="$DEST/src"
mkdir -p "$TMP" "$DEST/bin"
cd "$TMP"
if [ ! -f lua-5.0.2.tar.gz ]; then
  curl -sSL -o lua-5.0.2.tar.gz https://www.lua.org/ftp/lua-5.0.2.tar.gz
fi
rm -rf lua-5.0.2
tar xzf lua-5.0.2.tar.gz
cd lua-5.0.2
# THE DEFAULT TARGET, not 'linux': 5.0.2's Makefile has no platform targets (5.1 introduced those), and
# asking for one fails with "No rule to make target `linux'".
#
# -w BECAUSE A 2004 CODEBASE WARNS ABOUT EVERYTHING under a 2026 clang, and -O1 because this parses a few
# hundred kB of Lua and is never the slow part of anything.
make MYCFLAGS="-O1 -w" >/dev/null 2>&1 || make MYCFLAGS="-O1 -w"
cp bin/lua bin/luac "$DEST/bin/"
"$DEST/bin/luac" -v
echo "installed in out/lua502/bin -- lint_tsp.py will use it from here"

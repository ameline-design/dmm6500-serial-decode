#!/bin/sh
# Render the shipped docs to PDF THROUGH HTML rather than typst.
#
# pandoc -> standalone HTML with tools/pdf.css, then Chrome headless --print-to-pdf. Chrome is the
# only HTML engine on this machine (no weasyprint, wkhtmltopdf or prince).
#
# THE HTML IS WRITTEN BESIDE ITS SOURCE, not in a temp directory: MANUAL.md refers to docs/img/*.png
# by relative path, and Chrome resolves those against the HTML's own location. Rendering from /tmp
# silently drops every image.
#
#   sh tools/mkpdf.sh                 all three
#   sh tools/mkpdf.sh README.md       just one
set -e
ROOT="$HOME/Work/GitHub/dmm6500-serial-decode"
CSS="$ROOT/tools/pdf.css"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

cd "$ROOT"
# EVERY TRACKED .pdf MUST BE IN THIS DEFAULT LIST. release_sweep.py's `manual` stage runs this script
# with no arguments, so a shipped PDF left out of the default is never rebuilt by the gate and rots
# silently against its own source.
DOCS="${*:-README.md docs/MANUAL.md docs/REFERENCE.md docs/BENCH.md}"

for md in $DOCS; do
  base=$(echo "$md" | sed 's/\.md$//')
  html="$base.pdf.html"
  pdf="$base.pdf"
  # --resource-path IS REQUIRED, and its absence is silent apart from a warning: --embed-resources
  # resolves a relative src against the WORKING DIRECTORY, not against the input file, so
  # docs/MANUAL.md's `img/options.png` is looked for at ./img and every one of the 20 images is
  # dropped from the PDF. Point it at the document's own directory.
  dir=$(dirname "$md")
  # NO --metadata title. --standalone wants one and warns without it, but supplying it makes pandoc
  # print a <h1 class="title"> above the document -- so README.pdf opened with the word "README"
  # above its real title. An empty <title> satisfies the template and prints nothing.
  pandoc "$md" -o "$html" --standalone --embed-resources --css="$CSS" \
         --resource-path="$dir:$ROOT" \
         --metadata title="" --from gfm
  "$CHROME" --headless --disable-gpu --no-pdf-header-footer --virtual-time-budget=10000 \
            --print-to-pdf="$pdf" "file://$ROOT/$html" >/dev/null 2>&1
  rm -f "$html"
  printf '%-22s %8s bytes  %s pages\n' "$pdf" "$(wc -c < "$pdf" | tr -d ' ')" \
         "$(pdftotext "$pdf" - 2>/dev/null | grep -c '\f' || echo '?')"
done

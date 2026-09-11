# docs/ — what to read, and what is not ours to publish

Four documents ship with the app, each with a tracked PDF beside it. The repository's
[README](../README.md) is the front page; these are the detail.

| | |
|---|---|
| [MANUAL.md](MANUAL.md) · [PDF](MANUAL.pdf) | using it: hooking up, the screen, the buttons, what it copes with, where it fails |
| [REFERENCE.md](REFERENCE.md) · [PDF](REFERENCE.pdf) | every measured number, and the firmware limit behind it |
| [BENCH.md](BENCH.md) · [PDF](BENCH.pdf) | the harness: the seeded sweep, the release gate stage by stage, the soak results |
| [BETA.md](BETA.md) · [PDF](BETA.pdf) | hand this to anyone testing on their own bench — the four behaviours that **look** like defects and are not |

Also here:

| | |
|---|---|
| [VECTORS.md](VECTORS.md) | the stimulus set's naming scheme, and the coverage it still lacks |
| [vendor/](vendor/) | three firmware reports written for Keithley, each reproducible with the standard library alone |
| [img/](img/) | the ten front-panel figures the manual embeds |
| `pixel-drawing.html`, `pixel-drawing.pdf` | a standalone article on drawing pixels from TSP. Hand-written HTML, not generated from any markdown here |

## The mockup gallery

`index.html` and the `mockup-*.png` files are every panel state drawn at exact panel pixels, with no
instrument involved. It is two stages: `tools/mockup.lua` runs the real `tsp/serial_ui.tsp` and dumps
what it built to `mockup-objects-*.tsv`, then `tools/render_png.py` draws those dumps. Change the panel
and both stages have to run, or the gallery shows the previous layout.

`lin-divider-panel.png` is the divider artwork the app asks for. `sdec_icon.png` is the app icon,
written by `tools/package_tspa.py --icon-png` for review. `panel-ref-chrome.png` and `panel-ref-rows.png`
are grabs of a *different* TSP app on the same glass, kept as references for the firmware's own chrome —
the title bar, the End App button, the row pitch. Nothing generates or reads those two.

## Regenerating

```sh
sh tools/mkpdf.sh                 # every tracked PDF: pandoc -> HTML -> headless Chrome
python3 tools/doc_shots.py        # re-grab the manual's panel figures in one pass
python3 tools/check_version.py    # one version, stated the same way in every place that states it
```

**Every tracked PDF must be in `mkpdf.sh`'s default list.** `release_sweep.py`'s `manual` stage runs the
script with no arguments, so one left out of that list is never rebuilt by the gate and rots silently
against its own source. `check_version.py` is what catches the other half of that: it reads the version
byline out of the first 12 lines of each document **and out of page 1 of each PDF**, because the defect it
exists for was a shipped PDF disagreeing with the markdown it was built from.

## The vendor manuals are here, and are not published

Keithley's DMM6500 manuals and TSP app examples, Siglent's generator and scope programming guides and a
couple of processor references sit in this directory locally and are excluded by `.gitignore` — listed by
vendor rather than by a blanket `docs/*.txt` rule, so that a document *we* write here is published by
default instead of silently disappearing. They are what the measurements were made against; every number
they established is quoted, with its source named, in [REFERENCE.md](REFERENCE.md).

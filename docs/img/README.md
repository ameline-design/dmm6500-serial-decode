# docs/img/ — the manual's front-panel figures

Twelve images, eleven of them 800x480 grabs of an instrument screen taken over the LXI web interface.
**Ten are `tools/doc_shots.py`'s `SHOTS`** and are embedded by [../MANUAL.md](../MANUAL.md);
`panel-backlog-dialog.jpg` is a photograph of the physical panel showing the firmware's *"Processing
reading backlog…"* box over a 32 kB recording — the one figure here no tool can reproduce; and
`brun-panel.png` is the bench app's own screen, which has its own recipe below.

```sh
python3 tools/doc_shots.py                            # all ten, one app build, into this directory
python3 tools/doc_shots.py --only panel-hex,options
```

**They are regrabbed together because they go stale together.** They are the app's own screen, so one
panel change makes all ten wrong at once — adding the S/N cell moved the top line of eight of them. The
tool drives each state, checks it, and prints the state it reached beside every shot.

**Three of the ten are embedded somewhere other than the manual**, so a regrab reaches further than it
looks: `options.png` and `panel-msgs.png` are figures in [../MEASUREMENTS.md](../MEASUREMENTS.md), and
`panel-hex.png` leads [../../README.md](../../README.md). Check the captions there too.

## brun-panel.png, the one `doc_shots` cannot take

It is the soak settings screen from `Serial_brun.tspa`, embedded by [../BRUN.md](../BRUN.md), and it is
outside `SHOTS` because the bench engine has to be loaded **in place of** the app — `doc_shots` drives
`sdec` and this screen belongs to `brun`. Load `run_bench.py`'s `APP + ENGINE` through
`load_modules`, call `brun.panel()`, which builds the form and switches to it without starting
anything, then grab with `tools/screenshot.py`.

**Count the fields; do not trust the picture.** A trailing nil option makes `display.create` refuse, and
that is how **Lap Type left the screen** while BRUN.md still documented it in a subsection of its own —
for weeks, because nothing here said how to regrab this figure and nothing counted what it held. The
form is thirteen objects: ten fields, two plan lines and Run Soak. Read `table.getn(brun.pn_obj)` and
each `brun.pn_*` handle by name, because thirteen can be the right count with the wrong thirteen in it.

**A caption is a claim about a picture.** The captions quote numbers off the screen — `ERR reads 15`,
`page 4 of 35` — so a caption carried over to a regrabbed image describes a screen nobody looked at. Write
them from the tool's log. Two shots need a capture that starts mid-byte, which happens about one capture in
eight; the tool retries those and reports a shot it never got rather than filling it with the wrong screen.

The rendered mockups are not here. They are one level up in [../](../) and need no instrument at all.

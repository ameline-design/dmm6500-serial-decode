# docs/img/ — the manual's front-panel figures

Ten images, every one embedded by [../MANUAL.md](../MANUAL.md). Nine are 800x480 grabs of the app's own
screen taken over the LXI web interface. `panel-backlog-dialog.jpg` is a photograph of the physical panel
showing the firmware's *"Processing reading backlog…"* box over a 32 kB recording — the one figure here no
tool can reproduce.

```sh
python3 tools/doc_shots.py                            # all nine, one app build, into this directory
python3 tools/doc_shots.py --only panel-hex,options
```

**They are regrabbed together because they go stale together.** They are the app's own screen, so one
panel change makes all nine wrong at once — adding the S/N cell moved the top line of eight of them. The
tool drives each state, checks it, and prints the state it reached beside every shot.

**A caption is a claim about a picture.** The captions quote numbers off the screen — `ERR reads 15`,
`page 4 of 35` — so a caption carried over to a regrabbed image describes a screen nobody looked at. Write
them from the tool's log. Two shots need a capture that starts mid-byte, which happens about one capture in
eight; the tool retries those and reports a shot it never got rather than filling it with the wrong screen.

The rendered mockups are not here. They are one level up in [../](../) and need no instrument at all.

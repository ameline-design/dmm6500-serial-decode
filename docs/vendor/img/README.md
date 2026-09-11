# docs/vendor/img/ — the panel as evidence

Three grabs of the DMM6500's front panel, each a modal dialog that appeared **with
`localnode.showevents = 0` in force**. That setting not preventing them is the whole of report 2's claim,
and a picture of the glass is the form of it a reader cannot argue with.

| | what it shows | report |
|---|---|---|
| `4915-dialog.png` | `4915` *attempting to store past the capacity of a reading buffer*, over the running app, offering only **Details** and **OK** | [2](../02-event-4915-unmutable.md) |
| `2874-warning-dialog.png` | `2874` *analog trigger condition may no longer be valid* — a **warning**, and it carries a **Suppress** button that the error above does not | [2](../02-event-4915-unmutable.md) |
| `104-script-delete-dialog.png` | `-104` posted by a `script.delete` that **returned true** | [3](../03-input-buffer-overrun.md) |

Taken with `python3 tools/screenshot.py <out.png>`, which reads the panel over the LXI web interface in
about a second with nothing loaded on the instrument.

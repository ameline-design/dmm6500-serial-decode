# Firmware reports for Keithley TSP

Three findings from building a TSP app that runs on the instrument's own front panel — a UART decoder
that digitizes a serial line, recovers the baud rate and format, and shows the bytes on the panel. Each
is reproducible with the standard library alone; none needs the app or any bench equipment.

**They are ordered by what they cost an app developer**, not by severity as an instrument fault. All three
are **characterised**: every figure in them is a measurement on the instrument, and what remains unknown is
named at the end of each. What is open is listed there, not here.

| | report | one line | repro |
|---|---|---|---|
| 1 | [Display object pool](01-display-object-pool.md) | there are **463** objects, `display.create` returns **nil** past that, and nothing can query the limit or free an object whose handle is lost | `repro-01-object-pool.py`, `.tsp`, and `repro-01-recover-pool.py` to get an exhausted pool back |
| 2 | [Event 4915 cannot be muted](02-event-4915-unmutable.md) | arming a trigger model puts a **modal dialog over the app** that `localnode.showevents = 0` does not prevent, while the same setting does suppress other error-severity events | `repro-02-4915.tsp` |
| 3 | [-363 on the execute path](03-input-buffer-overrun.md) | a line over **1024 bytes** overruns the input buffer even with a strict handshake, the figure is undocumented, and a successful `script.delete` posts an error dialog | `repro-03-buffer-overrun.py`, which bisects the limit |

[img/](img/) holds the panel screenshots the reports rely on — a dialog caught in a picture is the form of
that claim a reader cannot argue with. `eevblog-display-pool.md` is a short write-up of report 1 for a
public forum, drafted and not posted.

## The instrument

| | |
|---|---|
| model | **DMM6500** |
| firmware | **1.7.17a** |
| interface | LAN, raw socket, port 5025 |
| embedded Lua | **5.0.2** (`math.mod`, no `string.match`, no `#`) |
| storage | USB key in the front port, FAT, 8.3 names |

Nothing here depends on a signal being connected, on the USB key, or on any second instrument.

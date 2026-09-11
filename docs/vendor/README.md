# Firmware reports for Keithley TSP

Three findings from building a TSP app that runs on the instrument's own front panel — a UART decoder
that digitizes a serial line, recovers the baud rate and format, and shows the bytes on the panel. Each
is reproducible with the standard library alone; none needs the app or any bench equipment.

**They are ordered by what they cost an app developer**, not by severity as an instrument fault.

| | report | one line |
|---|---|---|
| 1 | [Display object pool](01-display-object-pool.md) | there are **463** objects, `display.create` returns **nil** past that, and nothing can query the limit or free an object whose handle is lost |
| 2 | [Event 4915 cannot be muted](02-event-4915-unmutable.md) | arming a trigger model puts a **modal dialog over the app** that `localnode.showevents = 0` does not prevent, while the same setting does suppress other error-severity events |
| 3 | [-363 on the execute path](03-input-buffer-overrun.md) | ~2 kB statements overrun the input buffer even with a strict handshake, while `loadscript` takes 805 kB with none |

## The instrument

| | |
|---|---|
| model | **DMM6500** |
| firmware | **1.7.17a** |
| interface | LAN, raw socket, port 5025 |
| embedded Lua | **5.0.2** (`math.mod`, no `string.match`, no `#`) |
| storage | USB key in the front port, FAT, 8.3 names |

Nothing below depends on a signal being connected, on the USB key, or on any second instrument.

## Status of these reports

Report 1 is **characterised**: every figure in it is a measurement on the instrument, and the pool size is
confirmed twice over -- by exhaustion, and by the firmware's own statement of its handle space.

Report 2 is **characterised**: the panel behaviour is captured in a screenshot under `img/`, the event
count is measured against sample rate, and `FILL_CONTINUOUS` is identified as a workaround that costs
nothing in depth. What remains open is named at the end of it.

Report 3 ends with a **Not yet characterised** section naming the measurement that would turn it from
"this happens" into "this happens at exactly N". That needs instrument time and is left open rather than
guessed at: the numbers quoted are the ones measured, and where a bound is unknown it says so.

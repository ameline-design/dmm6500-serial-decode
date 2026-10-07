# 4. `file.write` reports a failed write only as a pop-up, so an application cannot detect it

**DMM6500, firmware 1.7.17a.** A USB key and one physical action — pulling it out. Nothing connected to
the inputs, no second instrument.

## Summary

With a file open for append on a USB key, pulling the key leaves the handle in a state where
`file.write` **returns normally** — `pcall` reports `ok = true`, `err = nil` — while writing nothing and
posting event **2200 *File write error*** instead. One event per call, for as long as the application
keeps writing.

So the failure is delivered **only** to the operator, as a modal pop-up, and never to the program. An
application that logs a few lines per operation puts a box on the panel per operation and has no way to
know it is doing so.

Measured, key out, handle still open:

| call | `pcall` | returns | event |
|---|---|---|---|
| `file.write(fh, s)` | **ok = true, err = nil** | — | **2200 *File write error*, once per call** |
| `file.flush(fh)` | ok | — | none |
| `file.close(fh)` | ok | — | none |
| `file.open(path, MODE_APPEND)` | ok | **nil** | 2224 *USB flash device not present* |
| `file.open('/usb1', MODE_READ)` | ok | nil | 2205 *File not found* |
| `fs.is_file(path)` | ok | `false` | none |
| `file.usbdriveexists()` | ok | `0` | none |

The `open` path is fine: it returns `nil`, which is checkable. `write` is the outlier — it is the only
one of these that fails without saying so in-band.

`repro-04-file-write.tsp` prints that table as it measures it.

## Why it costs an application developer

The documented contract for these calls is a return value. `file.write` has none, so the only defence an
application has is `pcall`, and `pcall` cannot see this. The result is a class of bug that is invisible
to every test that does not involve a human pulling a key:

* **The operator gets a pop-up per write.** On this instrument a 2200 is a modal dialog, and events
  arriving behind it collapse into *"Multiple errors have occurred"* — so the panel is blocked and the
  rest is hidden. (See [report 2](02-event-4915-unmutable.md): `localnode.showevents` does not prevent
  this, and severity is not the rule.)
* **The application reports success.** Byte counters advance, a status row says a file was written, and
  the file on the key is short. A log that claims 23 lines can have 2.

## What makes it worse than a missing return value

There is **no notification for the key arriving or leaving**. Measured: removing the key posts nothing,
and inserting it posts nothing — `eventlog.getcount()` stays 0 across both while `file.usbdriveexists()`
moves 1 → 0 → 1. There is no `EVENT_*` for it, and the reference documents no callback. So an
application cannot be told, and cannot ask cheaply except by polling `usbdriveexists` (111 µs, silent),
which is what the reference's own example for that call does.

That combination — a write that fails silently, and no event for the cause — means the only correct
pattern is to poll `usbdriveexists` *before* every write and treat its answer as authoritative.

## Suggested fix, in order of usefulness

1. **Give `file.write` a return value**, or raise. Either is checkable; a pop-up is not.
2. **Post an event when the key is inserted or removed**, so an application can react without polling.
3. Failing both, document that `file.write` cannot report failure, and that `usbdriveexists` must gate
   every write.

## What remains unknown

* Whether a **full** or **write-protected** key fails the same way. Only the pulled key was measured;
  the app that found this treats a raising write as a separate, unmeasured case and does not assume.
  **The two differ in the one way that matters to an application: `usbdriveexists` answers 0 for a
  pulled key and 1 for a full one**, so the quiet gate that stops every write on the measured case
  passes on the unmeasured one. `repro-04b-full-key.tsp` runs the same four rows against a key
  filled from the host; it also measures `file.read`, which this report never exercised in any state.
* Whether 2200 is posted for reasons other than absent media.
* Whether anything is buffered and later flushed to a key reinserted before `close` — not tested, and
  the reinsertion case is treated as a new key regardless.

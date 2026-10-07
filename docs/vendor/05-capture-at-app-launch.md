# 5. A digitize capture reached from a TSP app's entry point bluescreens the instrument when the app is run from internal memory

**DMM6500, firmware 1.7.17a.** Nothing connected to the inputs. A USB key is used only to install the
app; the fault is on the internally stored copy.

## Summary

An app installed in internal memory that takes a digitize capture **from its own entry point**
bluescreens the instrument at the end of that capture. The conditions are narrow and all of them are
necessary:

* the app must be run from **internal memory**. The **same archive, byte for byte, run from the USB
  key never fails** — many attempts, no crash.
* the instrument must have been **restarted** since the app was installed. A freshly installed app
  runs correctly once; the crash begins after the next restart and is then reproducible every time.
* the capture must be reached from the **entry point**. A capture started by a **button press** after
  launch is unaffected, in the same build, in the same session.

Removing that one call is sufficient to stop it. `NOAUTO` below is the V1.37 application with only
`pcall(function() sdec.capture() end)` deleted from the end of its `start()` function — same code,
same comments, body within 112 bytes — and it runs clean where the build carrying that call crashes
every time.

**The installed copy is not corrupt.** Read back with `scriptVar.source`, the installed script is
byte-identical to the archive that was installed: 271343 bytes, 7164 lines, the same CRLF endings,
zero differing bytes.

## The evidence

Each row is a `.tspa` installed to internal memory, run once, **restarted**, then run again. `body`
is the stored script in bytes; `bytecode` is that body compiled by a host `luac` — a relative figure,
used only to compare rows.

| build | body | bytecode | capture at launch | result |
|---|---|---|---|---|
| V1.30 | 260420 | 180657 | yes | **runs** |
| V1.31 | 269650 | 186661 | yes | crashes |
| V1.37 | 271343 | 187665 | yes | **crashes, 3 of 3** |
| V1.30 + 13 kB of comments | 273661 | 180657 | yes | **runs, 2 of 2** |
| V1.37 − 58 kB of comments | 213673 | 187649 | yes | crashes, 2 of 2 |
| V1.37, timer handler blanked | 271308 | 187653 | yes | crashes |
| V1.37 − comments, − launch capture | 213630 | 187581 | **no** | **runs, 3 of 3** |
| **V1.37, − launch capture only** | **271455** | **187597** | **no** | **runs, 2 of 2** |
| generated app, no capture | 147083 | 190113 | n/a | **runs** |
| generated app, no capture, larger still | 278366 | 190205 | n/a | **runs** |

Reading down the `capture at launch` column against the results: every build that takes one, on code
from V1.31 or later, crashes. Every build that does not, runs. No size column predicts any outcome.

## What is refuted, and by which row

* **App size, compiled.** A generated app with a **larger** compiled chunk — 190113 bytes against the
  crashing application's 187665 — installs, restarts and runs cleanly.
* **App size, stored source.** A generated app with **more** stored source — 278366 bytes against
  271343 — likewise. And stripping 58 kB of comments out of the real application, which leaves its
  compiled chunk within 16 bytes, does **not** stop the crash (row 5).
* **Allocation volume.** The generated app above allocates a 40000-entry table, builds a table per
  10 entries and formats dump strings, four times over, which is the shape of what the real
  application does after a capture. It runs cleanly.
* **A corrupt stored copy.** Byte-identical `source`, as above. Reinstalling is also **not** a
  reliable cure: one reinstall appeared to fix it and the crash returned after the next restart.
* **A display timer firing.** The application arms a `display.OBJ_TIMER` at 0.5 s. Blanking its
  `EVENT_PRESS` handler string, so it fires nothing, still crashes (row 6).
* **The signal.** Content, baud rate and frame format make no difference. A capture against a quiet
  pin does not crash, which is consistent with the application's analog trigger never firing and the
  capture therefore moving almost no data.

## THE FAULT ADDRESS MOVES WITH NESTING DEPTH, WHICH IS THE EVIDENCE

The bluescreen reports a PC, and it is not one value:

| PC | what reaches it | needs |
|---|---|---|
| **`001CF3C8`** | **the application's launch capture**, and a build differing from a working one by ONE pcall layer | internal memory, a restart |
| `0021B9C0` | a generated script, **36** nested pcall layers | 9 kB, nothing connected, faults from USB too |
| `00223E44` | the same script at **48** and at **64** layers | 11-13 kB, nothing connected, faults from USB too |
| `0042B248` | the same script at **32** layers, on relaunch via the APP key | 9 kB, nothing connected |

An address that varies with depth is what **memory corruption from stack exhaustion** looks like:
execution dies wherever it happens to be when the stack runs out. A guard-check trap would report
the same address every time. So this is most likely ONE defect -- unbounded pcall nesting -- rather
than four, and the generated script reproduces the CLASS with nothing connected, even though it
does not land on the application's own address.

### The application's fault, `001CF3C8`, reduces to ONE pcall layer

Two builds of the same application, identical but for a single `pcall`, installed to internal
memory, run once, restarted, run again:

    local a, b = sdec.capture_run()                                   clean, 2 of 2
    local ok, a, b = pcall(function() return sdec.capture_run() end)  bluescreen, PC 001CF3C8

So one `pcall` layer either way decides it, and reaching the capture from the entry point is
deeper than reaching it from a button press -- which is why a press is always safe, why removing
any single layer from a build carrying several never helped, and why neither a one-second `delay()`
nor a 58 kB size change made any difference.

**BUT THE LIMIT IS NOT THE DEPTH OF THE PATH TO THE ACQUISITION.** Flattening it does not rescue a
launch capture:

| build | code | pcall layers on the path to the acquisition | launch capture |
|---|---|---|---|
| V1.30 + one added layer | V1.30 | 3 | crashes, `001CF3C8` |
| V1.30 base | V1.30 | **2** | **runs** |
| flattened current build | V1.37 | **1** -- `autoset`, `acquire`, `decode` all bare | **crashes, `001CF3C8`** |

One layer in the later build fails where two in the earlier one succeed. So what matters is the
**peak** stack depth reached anywhere during a launch-initiated capture, not the chain on the way
in -- and most of this application's peak is in its decode and panel refresh. The build measured
here ships 227 `pcall` sites, 31 of them inside the function that captures.

In that build, the only safe configuration is **not capturing from the entry point at all.**

**THAT VERDICT IS A PROPERTY OF A 227-SITE BUILD, AND THE SHIPPED ONE NOW CARRIES 95.** The
entry-point capture has not been retried at the lower count, so nothing here says whether it is
still unsafe -- only that it was unsafe at 227. Retrying costs one install and one power cycle, and
the crash is immediate, so it is a cheap experiment. Note that 191 sites also bluescreened and 132
ran, which brackets the threshold well above 95; `tools/lint_tsp.py` fails the build above 132 so
the count cannot drift back toward the cliff without the gate saying so.

**A MATCHING PC IS STRONG EVIDENCE; A DIFFERING ONE IS WEAK.** `001CF3C8` appearing both for the
application and for a build one pcall layer away from a working one is what pins the mechanism,
because that is the same path at the same depth. Reading the PC on every crash is still essential
-- a bisection that treats "it bluescreens" as a single outcome can chain unrelated results
together, and this one did for hours -- but a DIFFERENT address must not be taken as a different
bug on the strength of the number alone.

## THE RELAUNCH ROUTE, which crosses the threshold at a lower depth

**`PC 0042B248`**, reached without any capture at launch and without anything connected:

    install a ~9 kB script with 32 nested pcall layers -> run it -> exit to the home screen
    -> press the APP key -> bluescreen at PC 0042B248

Clean at 8 and 16 pcall layers, reproducible at 32. **The address differs from the one the
launch-capture fault reports**, which is the instrument's own evidence that these are two
defects rather than one at two depths. `tools/repro_launchcap.py --pcalls N` generates the
ladder; the archives are 5 kB to 13 kB and need nothing attached.

This one is the better report of the two: a small generated script, no signal, no second
instrument, a named fault address, and a threshold in a single integer.

## What is open

1. **Why V1.30 survives a launch capture and V1.31 does not** is not established. The commit between
   them changes 539 lines across four files. Its most suspicious content is that `capture()` gained a
   wrapper calling `display.setevent` on the timer object either side of every capture; a build with
   those two calls removed, and everything else intact, is prepared but not yet run.
2. **Whether it is a race against the app launcher.** The capture is the last statement of the entry
   point, so it begins while the firmware may still be finishing the launch — and that would explain
   the one observation nothing else does, that the USB-key copy is immune, if launching from the key
   simply takes longer to reach the same statement. Two builds that yield before capturing —
   `delay(0.1)` and `delay(1.0)`, the launch capture otherwise intact — are prepared but not yet run.
   `delay()` on this instrument yields to the firmware rather than busy-waiting, so it is the right
   instrument for the question.
3. **Whether `repro-05-capture-at-launch.tsp` reproduces it** — see below.
4. **Why running from the USB key is immune.** If the firmware keeps a compiled image for an
   internally stored app and restores it at boot, that would fit every observation here, but nothing
   in the public API appears able to confirm or deny it.

## Repro

`repro-05-capture-at-launch.tsp` — a standalone script, about 60 lines, that builds a screen and then
takes three free-running digitize captures **from its entry point**, reading the samples out of the
buffer each time. Free running, so **nothing need be connected**: it fills its buffer from whatever
the open input reads rather than waiting for a trigger.

    install to internal memory -> run (prints DONE) -> RESTART -> run again

**This script is a candidate and has not yet been shown to reproduce the fault.** Everything above is
measured on a 13 500-line application; the standalone script is the attempt to reduce it. If it does
not reproduce, the difference between it and the application is the next evidence, and the most
likely missing ingredient is the number of display objects created before the capture — about 145 in
the application against 2 in the script.

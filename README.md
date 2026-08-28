# Serial Decode — Keithley DMM6500, DAQ6510, DMM7510, SMU2461

A UART decoder that runs **on** a Keithley bench instrument. It digitizes the line with the
instrument's own digitizer, recovers the baud rate, frame format and idle polarity from the signal,
and shows the bytes on the front panel as text or hex. No host, no logic analyser, one probe.

Ian Ameline · **version 1.11** · MIT licence (see [LICENSE](LICENSE))

| | |
|---|---|
| [docs/MANUAL.md](docs/MANUAL.md) | using it: hooking up, the screen, the buttons, what it copes with, where it fails |
| [docs/REFERENCE.md](docs/REFERENCE.md) | every measured number, and the firmware limits behind them |
| [docs/BENCH.md](docs/BENCH.md) | the harness: the seeded sweep, the release gate stage by stage, reproducing a failure |

Ships as `Serial_Decode.tspa`, installed from a USB key through the instrument's own **Manage Apps**
screen. Written in TSP — Lua **5.0.2** embedded in the firmware, so the sources avoid `#`, `%`,
`string.gmatch` and bitwise operators throughout.

## What to know before trusting it

**Tested on a DMM6500 and nothing else.** Every measured number in these documents came off that one
instrument. See [Which instruments](#which-instruments).

**Flow control is verified electrically but never closed as a loop.** One credit pulse per armed
capture, measured on a scope, with nothing that waits for it ever on the other end. The width is not
settable on this firmware, so a receiver needs an edge-triggered input rather than a polling loop.
Figures and the gate-by-gate account of where it fails are under **Triggering, in both directions** in
[REFERENCE.md](docs/REFERENCE.md).

**Automatic rate detection has two known failures**, both rare — **8 points in 860** on a full bench plan
— and both fixed by typing the rate in: a short pattern repeated over and over can measure at a small
multiple of its true rate, and a logic low near **−2 V** can misdetect. **Neither reaches an ordinary
payload at a standard baud rate:** across 171 600 captures at standard rates, opened from 200 different
points in the waveform, the fox, the 1 kB text payload, twelve random payloads and the walking-bit
patterns are clean at every rate from 300 to 250 000 baud. Both are characterised with their numbers under
**Known failures of automatic rate detection** in the [manual](docs/MANUAL.md).

**Nothing stops a long job early.** A touch press cannot be delivered while a script runs, and the
front-panel TRIGGER key does **not** deliver `trigger.EVENT_DISPLAY` during a panel-initiated run, so a
recording runs to its stated size. That key does still *gate* an armed capture under
`Options ▸ Trigger = Trigger key`.

**One press is the whole interaction.** A screenful is ~240 bytes; a recording holds 8 192 or 32 768
bytes to a file, decoded and filed without stepping; beyond that, flow control makes the window a chunk
size and credits the device until it stops sending. Ceilings and arithmetic are in the
[manual](docs/MANUAL.md).

## Endurance, measured — and reproduced

**Three independent 17-hour soaks**, each **6 laps of the full 1 683-point matrix, 10 098
capture-and-decode cycles on one power cycle**, with **no instrument event logged, no buffer or display
object leaked and no error left behind**. Different cabling, and changes to the app's state handling
between them:

| | duration | failures of 10 098 | rate |
|---|---|---|---|
| first | 17.14 h | 318 | 3.15 % |
| second | 17.17 h | 313 | 3.10 % |
| third | 17.18 h | 301 | 2.98 % |

**30 294 capture-and-decode cycles, and the failure rate reproduces inside 0.17 percentage points.** Lap
time did not rise in any of the three — the measurement that catches a leak, since a leak wedges the
instrument without failing a point.

**Around 3 % of those points fail, against a matrix built to attack the decoder.** That failure set
concentrates in four vectors, is mostly intermittent, and matches across runs more closely than any one
run matches itself. A third, 7-hour soak covers the recording path with zero failures. The numbers
are under **Endurance** in [REFERENCE.md](docs/REFERENCE.md).

## Which instruments

The app needs a digitizer reachable as **`dmm.digitize`** or **`smu.digitize`**, the **touchscreen app
API** (`display.create` and friends), and **Lua 5.0.2**. Every digitizer below runs at **1 MS/s**, and the
**panel is pixel-identical across the whole TSP range**, so the app's screens carry over as they are.

| | |
|---|---|
| **DMM6500** | **Tested**, firmware 1.7.17a — three 17-hour soaks, and the namespace resolver verified here. 16-bit digitizer, *"maximum resolution 16 bits"*, specifications, April 2018 |
| **DAQ6510** | Should run unmodified, on the strongest grounds of any untested model: it **shares the UI board and the acquisition board** with the DMM6500, only the channel-board plugin differing. Untested |
| **DMM7510** | Should run unmodified: 18-bit digitizer, better acquisition boards. Untested |
| **SMU2461** | **Will install and try; may or may not work.** Dual 18-bit digitizers, reached as `smu.digitize` by a namespace the app resolves at load. That mechanism is verified on the DMM6500; no SMU has ever run it. Three unknowns below |
| **2470 SMU** | **No.** *"Digitized measurements are not a feature on the 2470"* — its reference manual, rev D, October 2024 |
| **2450 / 2460 SMU** | Almost certainly not, by absence rather than denial: neither claims a digitizer, and the 2450 reference (rev D, May 2015) documents `smu.measure.*` with no digitize function |

**The timing figures transfer; the analog ones may not.** Every rate figure in REFERENCE descends from
the sample rate and the reading buffer's throughput. Resolution is the one axis this app is indifferent
to, thresholding each sample into a one or a zero. What is measured *through the acquisition board* —
the tolerance envelope, the level and offset limits, the −2 V band — is the part to re-measure: the
DAQ6510 shares that board, so a deviation there is a real finding, while the DMM7510's differs and those
figures may move either way. **Porting is an acquisition question only** — the panel is identical, so the
display layer carries over untouched, and the app resolves `dmm.digitize` or `smu.digitize` once at load
with no test on any capture path. The panel constants are under **Firmware limits worth knowing** in
[REFERENCE.md](docs/REFERENCE.md).

**On an SMU2461 the app will install and try. Three things are unverified, and any of them could stop
it.** *What the reading buffer holds* — a 2461 digitizes voltage and current **simultaneously**, and the
decoder trusts consecutive indices, so a buffer carrying current or source values alongside voltage would
be read as a waveform and surface as garbage bytes rather than an error. *The range* — the app pins
**10 V**, a DMM range chosen for having the widest digitize bandwidth, which a 2461 may not offer. *The
source output* — an SMU sources as well as measures, so the app sets the output off before every capture
and **reads it back, refusing the capture if it cannot confirm it**; those constant names are unverified,
and that refusal is the failure it is designed for.

**The `.tspa` header decides where it installs**, independently of whether the code would run. The build
declares `$Product: DMM6500, DAQ6510, DMM7510, SMU2461`. The other three SMUs are absent because they
have no digitizer to reach. Neither `DMM7510` nor `SMU2461` appears in the value set Keithley's
app-header spec publishes, though Keithley ship TSP apps of their own declaring DMM7510 — an install
failure is the symptom if a firmware validates the field strictly, and this field is the first thing to
revert.

**If you run this on anything but a DMM6500, please say so** — [open an
issue](https://github.com/ameline-design/dmm6500-serial-decode/issues). Every row above except the first
is inference from API surfaces and vendor documents, and one report from real hardware outweighs all of
it. What makes a report useful: `localnode.model` and `localnode.version`, whether **Manage Apps**
offered the app at all, whether both screens built, and whether a capture decoded. If it works, the
figures worth re-measuring are the acquisition-board ones above rather than the rate ladder — those
should already hold.

## Before releasing it to anyone

Three gates, each about ten times the cost of the one before it. Run them in order.

```sh
python3 tools/release_sweep.py --offline   #  ~1 min, no instruments
python3 tools/bench_smoke.py               #  13 min, both instruments
python3 tools/soak.py --hours 17 --suites formats,plan --skip-vectors v95,v96
python3 tools/release_sweep.py             #  the whole thing, instruments included
```

**The smoke gate covers the whole rate range in 13 minutes.** Four waveforms — the fox and a random
payload, each in 8N1 and 7E1 — paired crosswise, so one pair takes the 22 standard baud rates and the
other the 21 drawn ones, and each rate family faces both formats and both content classes. Then all 45
button presses, then seven logic swings from 5 V down to 0.25 V, then eight wrong-locked-rate cases.
Four stages, measured: 86 cells in 9.7 min, 45 presses in 1.9, 7 levels in 0.7, 8 rate cases in 0.9.

**No version is tagged without at least 8 hours of soak**, and the last two took 17. A soak reports a
**failure rate per test point**; a sweep reports one pass or one failure. A lap is 1 683 cells and about
2.9 hours, so 8 hours is the least that separates "fails every lap" from "failed once", and 17 gives six
laps.

**Code changes do not get pushed without passing the smoke gate.** On a pass, `bench_smoke.py` writes a
receipt holding a hash of `tsp/` and `tools/`; a `pre-push` hook recomputes it and refuses if either
tree has moved since.

```sh
ln -sf ../../tools/hooks/pre-push .git/hooks/pre-push
```

Documentation-only pushes are unaffected; neither tree is hashed. When the bench is unavailable —
mid-soak, say — `SMOKE_OVERRIDE="reason" git push` proceeds and prints the reason.

Every lap draws its waveform order, its non-standard rates and the wait before each capture from the lap
number, so `--iteration N` rebuilds any lap exactly without running the ones before it, and a failure
replays offline in seconds.

**[docs/BENCH.md](docs/BENCH.md) has the rest**: every stage of the release gate and what it checks, the
auditable record a full sweep leaves behind, what state the instruments have to be in before it will
start, how to replay a failing cell offline, and the hazards worth knowing.

## Layout

| | |
|---|---|
| `tsp/` | the app. `serial_core` acquisition, `uart_decode` framing, `chunk_decode` resumable decode, `serial_ui` panel, `serial_app` orchestration |
| `tools/` | harnesses. `release_sweep.py` is the entry point; the rest are the authorities it calls |
| `docs/` | the manual, instrument references, panel mockups |
| `notes/` | bring-up log, findings, handoffs |

`tsp/midi_decode.tsp` and `tsp/lin_decode.tsp` are complete and tested but **not shipped** in version 1
— the LIN checksum has never been checked against a real frame. Re-adding either is one line in
`tools/package_tspa.py`; the app discovers what it has at runtime.

## Bench

Three instruments over LAN: the DMM6500 under test, an SDG2122X generating the stimulus, an SDS1204X-E
verifying the stimulus is what it claims to be. `tools/instruments.py` holds the addresses and the
hazards — repeated large waveform uploads wedge the generator's LAN service, and calibration state is
off limits on both.

## Fixed since V1.10

Each row is the defect, not the repair. The harness rows are here because a gate that cannot fail is a
defect in the same sense: it makes every result after it worth less than it looks.

**Decoder**

| | |
|---|---|
| Odd sub-multiples were invisible to the rate detector | MIDI's 31250 Bd read as **153600**. The probe free-runs at 32 samples/bit, where `Tfit/6` still clears the plausibility floor, and 5 × 31250 snaps inside `snaptol` — so a sub-multiple looked standard, and a mid-byte start made a fit exact to 32.0000 look like the failing one. |
| A refusal named a limit that had not fired | Built from constants that do not match the test that refuses, so the baud-ceiling sentence was unreachable and the one that fired claimed "faster than the 250 kBd ceiling" for lines **under** it — false at 7477 of 9177 points, worst case a 251 baud line. |
| A panel warning contradicted the decode beside it | 4.0 samples/bit is 250 kBd only at 1 MS/s. At 20 kS/s it is a 5000 baud line, yet a correct 5000 Bd result was annotated "at or past the 250 kBd ceiling" — a warning on a **successful** decode, naming a limit fifty times away. |

**Signal quality**

| | |
|---|---|
| An amplitude-windowed S/N measured slew, not noise | A sample partway up an edge is indistinguishable from a noisy one by amplitude. A noiseless capture read 24.8 dB and 38.4 dB by two windows, and neither moved when real noise was injected 40 dB below. |
| The noise cliff was a unit error | 8 dB came from comparing a peak amplitude ratio against an RMS measurement. The documented 40 % peak tolerance is 23 % rms — **12.7 dB** — so the reported bands sat below the real cliff. |
| The 6 dB-per-halving trend had no stated cause | It reads as a generator artefact, and the evidence points the other way: the generator's ladder attenuates its own DAC noise, so a generator-dominated figure would stay flat. A source constant in volts and downstream of the attenuator — the instrument's front end — fits, though this is inference from the trend rather than an isolating measurement. |

**USB logging**

| | |
|---|---|
| An 11-character directory has no *predictable* FAT entry | `/usb1/SerialFiles` existed and the app still could not find it: no plain 8.3 entry, a non-contiguous UTF-16 long name, and only a `SERIAL~1` tilde alias whose number cannot be relied on. The smoke caught it — panel 16 BAD, rates 7 BAD, while plan 86/86 and levels 7/7 passed, because decode never touches the key and logging does. |
| `file.mkdir` posts an event instead of raising | It never raises, but pops event 2208 — so creating a directory the obvious way puts an instrument error dialog in front of the operator. |
| Files scattered across a shared key | Byte log, Save reports and both event logs went to the root of `/usb1`, with their paths written in four places that could drift. |
| `NewLog` stayed pressable with no key | `Save` was already hidden. A control whose only possible outcome is a failure report is worse than no control. |

**Panel**

| | |
|---|---|
| The mid rule read as an underline | Dropping the two headline cells by a row put their medium ink at y 34 while the rest of the value row ends at 32, and the rule at y 35 then sat one row beneath them. |
| An out-of-range display object returns nil rather than raising | So a mis-placed element goes silently missing instead of failing loudly. `mockup.lua` compounded it by reading a rect's extent as `x + w`, one pixel wide of the truth, which would have put the right-hand vertical off-screen at x 798. |
| Labels and grid were too dim on the LCD | 44 % and 50 % grey are legible in a screen grab and hard to read on a 5-inch panel across a bench. A renderer cannot settle that question. |

**Documentation that described something that never happened**

| | |
|---|---|
| The manual's page counts were unreachable | It claimed a 32 768-byte capture pages 137 and 28. The panel's retained tail is bounded at 8192 bytes, so nothing pages past 35. |
| Screenshots were gated on the capture, never the action | A **refused** press was photographed and filed under a caption describing what it was supposed to have done — a declined `options()` filed whatever screen was already up. |
| The swing row documented a ladder, not the bench | "1.6 V to 5 V TTL" against a hardware lap covering 1.652 to 9.300 V p-p. |
| The app introduced itself by two names | `$Title` said "Serial Protocol Decode" in the app list while its own screen read SERIAL DECODE, and the menu description was 255 characters against a documented 240 ceiling. |

**Test harness**

| | |
|---|---|
| The plan judge trimmed a fixed 12-byte head | The app's own bound reaches 34 on v77, so byte-exact decodes were failed at every one of 43 rates — **3377 invented failures over 20 laps**, 82 % of them attributed to one issue. The soak's offline twin also gated nothing at all. |
| A `loud` vector that declined moved no counter at all | Declining *is* the correct answer for a `loud` waveform, so it rightly passes — but it was counted nowhere, which left it unbounded. A regression that suppressed every byte on those vectors would have read as a completely unchanged run. Measured at 17 declines a lap at one offset and 90 at eight. |
| A `loud` vector that RAISED was counted as a pass | The same licence to fail swallowed a decoder exception: a raise arrives with no result, which is indistinguishable from a decline unless the raise flag itself is checked — so `raised`, the one counter that gates unconditionally at every capture placement, could sit at zero while the decoder was throwing. |
| #46 was one counter over three mechanisms | It could say the rate was wrong, never which of three unrelated mechanisms did it. Split and measured, **cluster C is 14.5 % of hardware misreports and 0 of 141 040 offline decodes** — it has no offline counterpart at all. |
| `test_ratefit` asserted a floor of one, and dropped its own `pcall` result | Five of six reproducing cells could go quiet, or the decoder could raise on all 640 captures, with every assertion still green. |
| `sweep_all` discarded shard identity | Two workers on the same shard reconcile perfectly — n summaries for n workers — while a third of the plan is never swept. |
| Per-function coverage was misattributed | An indented four-line nested `giveup` owned 195 lines of `sdec.decode_from`, so every per-function figure for the decoder was wrong. |

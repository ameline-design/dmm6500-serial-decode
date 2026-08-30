# bench/ — the soak that runs on the instrument

Four TSP modules loaded onto the DMM6500 **alongside** the app. With these in place the instrument
selects its own stimulus over the LAN, captures with the app's own acquisition, decodes, and appends
every cell to its own USB key — with no host connected. That is what makes a multi-day soak possible.

| | |
|---|---|
| `arb_names.tsp` | **generated** — vector id to the generator's stored waveform name, plus which vectors are allowed to refuse |
| `sdg_net.tsp` | the DMM driving the SDG2122X over `tspnet` |
| `bench_rec.tsp` | the append-only record on the DMM's USB key |
| `bench_run.tsp` | the loop, the status screen, and the TRIGGER-key stop |

**None of this ships in `Serial_Decode.tspa`** — `tools/package_tspa.py`'s module list is explicit.
The release gate, stage by stage, is in [../docs/BENCH.md](../docs/BENCH.md); this file is the runbook
for getting a soak started.

---

## 0. Before anything

### Addresses go in two places, and both matter

| where | what | who reads it |
|---|---|---|
| `tools/instruments.py` | `DMM_IP`, `SDG_IP`, `SCOPE_IP` | the **host** tools |
| `bench/sdg_net.tsp` | `bsdg.ip`, `bsdg.port` | the **DMM**, dialling the generator itself |

`instruments.py` takes environment overrides, so a moved instrument needs no code change on the host:

```sh
DMM_IP=10.0.1.151 SDG_IP=10.0.1.79 python3 tools/run_bench.py --smoke
```

**`bsdg.ip` is not one of them.** Nothing pushes it from the host — the DMM connects to the generator
on its own, so the literal in `sdg_net.tsp` is what an unattended run uses. Change the generator's
address and you must edit that line too, or the soak loads and then reports `SDG UNREACHABLE`.

The port is **5025** and must stay 5025. Probing 5024 is a suspect in two LAN deaths on this
generator; see `SDG_SHUTDOWN_SUSPECTED_HAZARD` in `tools/instruments.py`.

### A USB key must be in the DMM6500

Everything the soak reads and writes lives on it, under `/usb1/SERDEC/`:

| | |
|---|---|
| `PLAN.CSV` | the plan, pushed over the LAN before the run starts |
| `SOAK.CSV` | the record, appended cell by cell as the run goes |

With no key, `file.open` returns nil, the run has nowhere to record, and the panel goes red with
`NOT RECORDING`. The directory name is 8.3 (`SERDEC`) because only an 8.3 name can be found by
searching the FAT table, which is how the run checks the key without opening a file that is not
there — an open on a missing name posts an event, and an event is a box on the panel.

**Nothing is ever copied to the key by hand.** All communication with the DMM is over the LAN.

### What state the instruments have to be in

* **The app does not need to be installed.** `run_bench.py` loads `tsp/` and then `bench/` from source
  over the socket, in that order — `bench/` reads `ulog.next_free` out of `usb_log.tsp`, so it cannot load
  first. A Manage Apps install is for an operator using the app by hand, not for a soak.
* **Only one client may be connected to the DMM,** and a previous run killed mid-command leaves the reply
  stream out of step. The preflight refuses rather than guess.
* **Display object ids are never reclaimed on this firmware.** The status screen builds six objects, and
  `display.create` returns nil once the pool is out — silently, after the first time. That bounds how many
  times the app can be reloaded onto a running instrument to roughly four; power cycle rather than push
  past it. The app's own `sdec.start()` will not build its UI twice in one power cycle either.
* **A power cycle leaves `sdec` and `brun` nil**, so `--no-load` after one finds nothing loaded. Load
  first, or check `type(sdec)` before trusting `--no-load`.
* **Take the scope out of Bode mode before an unattended run.** The scope also drives the SDG over USB
  for its Bode-plot function, and left in that mode it will reprogram the generator underneath a run.
  The symptom is a stimulus that silently stops matching the manifest — see `SCOPE_BODE_HAZARD` in
  `tools/instruments.py`. This is the one way the *optional* scope can invalidate a soak.

### Wiring

Only the first line is needed for a soak; the scope legs are the optional oracle. `tools/instruments.py`
holds the authoritative version of this diagram.

```
    SDG2122X CH1 out --+--coax--> DMM6500 front INPUT HI     the decoder under test
                       +--coax--> SDS1204X-E CH1             the oracle (optional)

    SDG2122X CH2 out --+--coax--> DMM6500 rear TRIGGER IN     anchor marker
                       +--coax--> SDS1204X-E CH3

    SDG2122X rear In/Out <-+--coax-- DMM6500 rear TRIGGER OUT credit pulse
                           +--coax-- SDS1204X-E CH4
```

Each output is split at its own connector into two matched 5 ft RG316 runs, so all three can be read in
one timing context. **SDS CH2 is deliberately not connected**, so CH1 sits alone in the CH1+CH2 ADC pair
and the signal channel is never halved by watching a trigger. All three instruments are on one gigabit
switch at 100 Mbit.

The DMM must have its **front** terminals selected, since that is where CH1 lands. The generator drives
into **high impedance**: the vectors are built for a 20 Vpp part into high-Z (`bsdg.maxvpp`), the run sets
`C1:OUTP ON,LOAD,HZ` itself, and it verifies C1 is in **TrueArb** before every capture — a silent fall
back to DDS resamples the stored points and corrupts the sub-sample edge timing this bench exists to
measure.

---

## 1. Build the vectors

```sh
lua tools/make_vectors.lua            # -> out/vectors/, plus manifest.tsv
```

For each vector this writes the `.bin`, reads it back with an independent decoder, and decodes both
the quantised and unquantised forms to check that 16-bit quantisation has not damaged the decode. Any
row whose two decodes disagree must not be trusted as a bench oracle. `out/` is generated and
gitignored, so this step is required on a fresh clone.

## 2. Upload the vectors to the SDG — over the LAN

**Everything goes over the LAN. No USB key is used to get data into either instrument.** All 41
waveforms end up in the generator's **internal flash** under their `SER_` names, which is what lets the
soak select one with a bare `ARWV NAME` and no transfer.

```sh
python3 tools/upload_vectors.py --dry-run     # what would go. Opens no socket at all
python3 tools/upload_vectors.py               # the 36 under the ceiling
```

Names come from `tools/vector_names.py`, the single source — the tool refuses a malformed or duplicated
name rather than uploading one, and verifies each landed by reading its stored length back. That
read-back matters: a **zero-length** stored waveform bricks this generator at its next power-up, and
the only window to delete it is while the box is still answering. Uploads go smallest first, so if the
generator does stop answering the most work is already banked.

### The five above the ceiling

`upload_vectors.py` **refuses these** — they are past `SDG_UPLOAD_SAFE_BYTES` (65 536) in
`tools/instruments.py`:

| | bytes | over the ceiling |
|---|---|---|
| `v94` SER_Blocks512B_8N1_x10 | 102 800 | 1.6x |
| `v71` SER_Lorem1kB_8N1_x10 | 205 200 | 3.1x |
| `v93` SER_Random1kB_8N1_x10 | 205 200 | 3.1x |
| `v95` SER_Random8kB_8N1_x10 | 1 638 800 | 25x |
| `v96` SER_Random32kB_8N1_x10 | 6 554 000 | 100x |

That ceiling is a scar rather than a spec number, and **the hazard is the NUMBER of large writes, not
their size** — measured both ways: the *third* over-ceiling upload wedged firmware 39R7 after only 533 kB
in total, while a single 1.63 MB followed by a 6.51 MB write on one power cycle — 8.14 MB together — left
it answering and playing correctly. A wedge leaves the generator playing the loaded waveform forever while
accepting TCP on both 5024 and 5025 and answering nothing, `*IDN?` included. Only a power cycle recovers
it, and it has no smart plug, so it costs a human.

**The rule is therefore: fewer than three over-ceiling writes between power cycles.** So these five go
over the LAN in batches of at most two, naming each one explicitly:

```sh
# 1. raise SDG_UPLOAD_SAFE_BYTES in tools/instruments.py far enough to admit the ones you want
# 2. name them -- never let a raised ceiling sweep the whole set back up again
python3 tools/upload_vectors.py --only SER_Blocks512B_8N1_x10,SER_Lorem1kB_8N1_x10
# 3. let the generator rest, then confirm each stored length came back right
# 4. power cycle before the next pair. Put the ceiling back when the set is complete
```

**`--only` is not optional here.** With the ceiling raised and no `--only`, the tool schedules every
mapped file below the new ceiling — including the large ones already uploaded — which is how a
"careful" second pass performs three over-ceiling writes in one power cycle and wedges the box.

The read-back in step 3 is `siglent.stored_wave_length()`: it asks `WVDT?` for the `LENGTH` field and
allows 180 s for the reply. `upload_vectors.py` does it per upload, and it is what catches a zero-length
or truncated waveform **while the box is still alive to delete it from** — a zero-length stored waveform
bricks this generator at its *next power-up*, and there is no telnet on stock firmware to recover through.
If a length comes back wrong, delete that waveform before anything power-cycles.

Do none of this while a run is going.

`out/vectors/USB-TRANSFER.md`, written by `make_vectors.lua`, carries the per-file sizes and checksums;
it is generated and gitignored, and its title predates the LAN path.

**Nothing on the instrument side can upload.** `bsdg.cmd()` refuses any string containing `WVDT`
outright, so a soak cannot do it even if a caller asks.

## 3. Check the names table is current

```sh
python3 tools/gen_arb_names.py --check    # exit 1 if stale
python3 tools/gen_arb_names.py            # regenerate
```

`bench/arb_names.tsp` is generated from `tools/vector_names.py`. A vector renamed in one and not the
other leaves the instrument playing the **previous** waveform with nothing said — `ARWV NAME` with an
unknown name does nothing at all. `tools/test_bench_engine.lua` asserts this file is current, so the
offline gate catches it, but check it here before a long run rather than after one.

## 4. Start the soak

The host loads the app and the engine, pushes the plan, starts the loop, and lets go of the socket.
**Only one client may control the DMM**, so nothing may connect again while the run is going.

```sh
# the 86-cell smoke first: ~9 min, then fetched and judged automatically
python3 tools/run_bench.py --smoke

# a real soak: N laps, plan pushed, started, socket released
python3 tools/run_bench.py --iterations 100 --push-plan --start --detach \
        --skip-vectors v95,v96 --random-per-lap 4

# indefinite: runs until the TRIGGER key or the power stops it
python3 tools/run_bench.py --iterations 0 --push-plan --start
```

**`--skip-vectors v95,v96` is the default and should stay.** `v96` wedges the SDG partway through a
lap, every time; two nights of bench time have been lost to omitting it. Note that the skip is applied
**before** the plan is shuffled, and the shuffled position keys each cell's amplitude, offset and wait
— so a lap run with a different skip is *different stimulus under the same lap number*. The plan
records both the skip and `--random-per-lap` in its header for that reason.

With `v95,v96` skipped a lap is **1 677 cells**, estimated at 2.07 h. `--random-per-lap 4` plays four of
the twelve random-payload vectors each lap, which is **1 333 cells** and estimated at 1.64 h — every
vector is still played, just across laps rather than within one.

**Budget from a measured lap, not from the estimate.** A 210-lap run at `--random-per-lap 4` measures
**1.96 h a lap** on this bench, not 1.64 — the estimate does not carry the per-cell plan wait or the
generator's own latency. Cell counts, unlike times, are exact, and the plan declares its own:

```sh
# grep, not head: soakplan.py writes the whole plan and does not handle a closed pipe,
# so `| head` ends in a BrokenPipeError after printing the right answer
python3 tools/soakplan.py --emit-csv --iterations 1 --skip-vectors v95,v96 --random-per-lap 4 \
  | grep '^# rows='
```

Useful additions:

| | |
|---|---|
| `--listen <host-ip>` | push one progress line per cell to `tools/soak_listen.py` |
| `--resume` | carry on after the last cell the record already holds; refuses if the plan on the key is not the plan that produced that record |
| `--plan-file PATH` | push an already-generated plan instead of regenerating it (210 laps is ~5 min of CPU) |
| `--no-load` | the app and engine are already on the instrument |

The plan goes over the socket at every size, one acknowledged batch at a time, and is verified against
the key's own directory entry before the run is allowed to start.

## 5. Watch it, stop it, judge it

**Watching.** A running TSP script holds the interpreter, so the DMM cannot answer a query about its
own progress — the run pushes instead:

```sh
python3 tools/soak_listen.py          # a window, never a dependency
```

If nothing is listening the connect fails inside a `pcall` and the soak carries on. Start it, stop it,
restart it mid-run; the instrument neither knows nor cares.

The front panel is the other window, and needs no host at all: a **SOAK HEALTH** headline, lap and
cell with both elapsed and remaining, what is playing, the refusal counts, and a five-line log of
state changes. Green is better than a good lap; amber is worse than one; **red means someone should
walk over.**

**Stopping.** Press the front-panel **TRIGGER** key. A touch button cannot do this — presses are not
dispatched while Lua runs — but the key is latched by firmware and read once per cell. The run ends
after the current cell and **closes** the record, which is what commits its length on a FAT volume.
Cutting the power also works and costs at most `brec.syncrows` cells off the end of the file.

**Fetching and judging.**

```sh
python3 tools/run_bench.py --fetch --no-load      # writes out/bench/SOAK.csv
python3 tools/judge_bench.py out/bench/SOAK.csv
```

`--fetch` reads in line batches bounded by the length in the key's directory entry, because reading until
`nil` means reading *past* the end, and that posts a popup at the end of a fetch where it looks like the
run failed.

The instrument does not judge bytes, deliberately: the verdict rules are the accumulated argument of
this project, and a second implementation of them in Lua 5.0.2 would be a second judge — on the night
the two disagree, both look right. The instrument records what it read, including the `??` it writes
for a frame it flagged, and the host decides.

Read three numbers, in this order:

1. **`nevtot` = 0.** A nonzero count means the run *instigated* an instrument event. The run mutes the
   panel for its duration, so it may not have popped — but the requirement is that nothing is instigated
   at all, because muting governs the remote interface and is not something to rely on. `nevpanel`, in the
   same line, is the subset caused by the panel writes themselves.
2. **Bytes per cell**, ~590 in a healthy record.
3. **Health**, and the split between allowed and unexpected refusals beneath it.

---

## Hazards

* **One controlling socket.** Connecting to the DMM mid-run gets nothing and risks corrupting the
  session. `tools/dmmrun.py` holds a lock to stop two clients trying.
* **Never upload a waveform to the generator during a soak,** and never `*RST` it. `bsdg.forbidden()`
  refuses both, because either one loses the run from that moment.
* **Calibration is off limits** on both instruments.
* **A fault does not end a run.** A wedged generator, an unwritable key or a missing plan all go red,
  write the reason to the key, and keep retrying — parking on day 2 of a fortnight throws away twelve
  days nobody is there to restart. Only the iteration count, the TRIGGER key or the cell cap end one.
* **`STOP.TXT` is not armed by default,** despite the file existing on the key path. `brun.stopevery` is
  0 and `run_bench.py` exposes no flag to change it, because *looking* for a file that is not there posts
  an event per cell — about 1.4 million across eight days, each one a box on the panel. The TRIGGER key
  is the stop control; treat the stop file as available only to something that sets `brun.stopevery`
  itself.
* **The backlight is dimmed to 25 %** for the duration and not restored. The firmware has no 30 %:
  the steps are 100/75/50/25/off.
* **Events are the measurement, not diagnostics.** The loop watches its own per-cell event count and
  sheds optional machinery — the progress push first — if cells keep posting them.

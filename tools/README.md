# tools/ — the harnesses

Everything that tests, measures, packages or drives the app. `release_sweep.py` is the entry point; the
rest are the authorities it calls. Nothing here ships inside `Serial_Decode.tspa`.

Two instruments over LAN: a **DMM6500** under test and an **SDG2000X**-series generator for the stimulus.
A scope is optional. Addresses live in `instruments.py` and take environment overrides
(`DMM_IP`, `SDG_IP`, `SCOPE_IP`). Only **one client may control the DMM** at a time — `dmmrun.py` holds a
lock to stop two trying. Calibration is off limits on both.

For the soak that runs *on* the instrument see [../bench/README.md](../bench/README.md); for the release
gate stage by stage see [../docs/BENCH.md](../docs/BENCH.md).

---

## Generating and uploading the vectors

The stimulus set is 41 waveforms built from the same arrays the offline suite decodes, so a hardware
result is comparable with an offline one byte for byte.

```sh
lua tools/make_vectors.lua                    # -> out/vectors/*.bin + manifest.tsv
python3 tools/upload_vectors.py --dry-run      # what would go. Opens no socket
python3 tools/upload_vectors.py                # the 36 under the size ceiling
python3 tools/gen_arb_names.py --check         # is bench/arb_names.tsp current?
```

`make_vectors.lua` does not just encode: for each vector it writes the `.bin`, reads it back with an
independent decoder, and decodes both the quantised and unquantised forms. A row whose two decodes
disagree must not be trusted as an oracle. `out/` is generated and gitignored, so this is required on a
fresh clone.

**Everything goes over the LAN — no USB key is used to get data into either instrument.** All 41 land in
the generator's internal flash under their `SER_` names, which is what lets a run select one with a bare
`ARWV NAME`.

**Uploading is a setup step, done once and then not again.** A lap selects from flash 1 677 times and a
fortnight's soak about 230 000 times, without a single upload — so the hazards below are paid once, which
is why the tool is deliberately slow and verifies everything. Re-upload only when a vector's bytes change.

**Five vectors exceed `SDG_UPLOAD_SAFE_BYTES` (65 536) and `upload_vectors.py` refuses them:** `v94`,
`v71`, `v93`, `v95`, `v96`. The hazard is **the number of large writes, not their size** — the third
over-ceiling upload wedged firmware 39R7 after only 533 kB, while 1.63 MB then 6.51 MB on one power cycle
was fine. The rule is **fewer than three over-ceiling writes between power cycles**; raise the ceiling,
name the files with `--only`, rest the generator, read each stored length back, then power cycle. The
full procedure is in [../bench/README.md](../bench/README.md#the-five-above-the-ceiling).

`vector_names.py` is the single source for id → name. `lint_vecrefs.py` proves every id named anywhere in
`tools/` exists in it or is explicitly retired.

## Running the tests

Three gates, each about ten times the cost of the one before. Run them in order.

```sh
python3 tools/release_sweep.py --offline   #  ~1 min, no instruments at all
python3 tools/bench_smoke.py              #  13 min, both instruments
python3 tools/soak.py --hours 17 --suites formats,plan --skip-vectors v95,v96
python3 tools/release_sweep.py            #  the whole thing, instruments included
```

`release_sweep.py` runs every check in one pass and records the result. `--offline` skips only the stages
that need hardware (`hw-*`, and `soakrand-dmm`, which holds the instrument's own Lua to a sequence); an
offline failure aborts before any hardware stage, because a hardware run would be measuring code already
known to be wrong.

Individual suites run standalone, which is what you want while fixing something:

```sh
lua tools/test_serial.lua                 # the decoder's unit tests
lua tools/test_bench_engine.lua           # the on-instrument soak engine, offline
python3 tools/test_pushplan.py            # the plan-push handshake
sh tools/get_lua502.sh                    # build Lua 5.0.2 first -- see below
```

**Build the interpreter the instrument actually runs.** `get_lua502.sh` puts `lua` and `luac` in
`out/lua502/bin`, and `lint_tsp.py` picks them up there. The host has Lua 5.5; the DMM6500 has **5.0.2**,
and a construct the host accepts can die on the box — `string.match` and `math.fmod` both exist on the
host and not on the instrument, so a module using either passes every offline suite and then fails at the
first line that runs. `lint_tsp.py` refuses both names.

**A code change does not get pushed without the smoke gate.** `bench_smoke.py` writes a receipt hashing
`tsp/` and `tools/`; the `pre-push` hook recomputes it and refuses if either tree moved. Documentation-only
pushes are exempt automatically. When the bench is unavailable, `SMOKE_OVERRIDE="reason" git push` proceeds
and prints the reason, which puts it on the record.

```sh
ln -sf ../../tools/hooks/pre-push .git/hooks/pre-push
```

---

## What each file is

### Drivers and addresses

| | |
|---|---|
| `instruments.py` | one place for the bench's addresses and the facts about it that code needs, hazards included |
| `dmmrun.py` | load and run TSP on the DMM6500 over raw socket 5025; holds the single-client lock |
| `siglent.py` | SCPI driver for the SDG2122X generator. Refuses out-of-spec waveform payloads in the driver, not the caller |
| `scope.py` | SCPI driver for the SDS1000X-E scopes — the bench's independent oracle |
| `screenshot.py` | grab the front-panel display over the LXI web interface |
| `find_dmm.sh` | sweep the subnet for a Keithley: port 80 + 5025, plus the Tektronix OUI in ARP |
| `run_app.py` | load the app onto the DMM6500 and start it, then drive it |
| `hotpatch.py` | replace named functions on the live app without rebuilding the UI |

### Packaging and release

| | |
|---|---|
| `package_tspa.py` | build `Serial_Decode.tspa`; the module list and the version live here |
| `verify_tspa.lua` | check the SHIPPED archive, not the sources it was built from |
| `check_version.py` | one release version, stated the same way in every place that states it |
| `release_sweep.py` | **the gate before the app goes to anyone else.** Every check, one run, recorded |
| `smoke_receipt.py` | record that the smoke gate passed against an exact tree, and refuse a push that outran it |
| `hooks/pre-push` | enforces that receipt |
| `mkpdf.sh` | render the shipped docs to PDF via pandoc + headless Chrome |
| `pdf.css` | the stylesheet those PDFs use |
| `doc_shots.py` | regrab every front-panel PNG the manual ships, in one pass over one app build |

### Linters

| | |
|---|---|
| `lint_tsp.py` | structural linter for the TSP modules and the packaged archive; enforces the 5.0.2 subset |
| `lint_history.py` | find comments that talk about the past instead of the code |
| `lint_commentonly.py` | prove an edit touched only comments — the code is unchanged against a git revision |
| `lint_docblocks.py` | find doc blocks the packager would attach to the wrong symbol |
| `lint_vecrefs.py` | every vector id named in `tools/` must exist in the mapping or be listed as retired |

### The stimulus set

| | |
|---|---|
| `make_vectors.lua` | build the bench stimulus set as SDG arb files, with the offline answer recorded beside each |
| `vector_names.py` | the one mapping from a local vector id to its name on the generator |
| `upload_vectors.py` | upload the vectors under their `SER_` names, verifying each landed |
| `gen_arb_names.py` | emit `bench/arb_names.tsp` — those names as a table the instrument can read |
| `gen_serial.lua` | synthetic UART waveform generator and mocked DMM6500 |
| `mt19937.py`, `mt19937.lua` | the same PRNG in both languages, held to the reference sequence |
| `soakplan.py` | what one sweep iteration tests, derived from its iteration number and vector set |

### Hardware harnesses

| | |
|---|---|
| `bench_smoke.py` | **the thirteen-minute gate:** four waveforms across the rate range, then every button |
| `bench_matrix.py` | characterise the app through its own Capture button: formats, rates, levels, offsets |
| `bench_uart.py` | end-to-end characterisation: real UART from the SDG, decoded on the DMM |
| `bench_sweep.py` | sweep every standard rate to 250 kBd by replaying one waveform at different speeds |
| `bench_panel.py` | press every button in every state that changes what it should do |
| `bench_buttons.py` | press every button and check three things per press |
| `bench_stream.py` | drive a recording to a full buffer on real hardware, in one press |
| `bench_longstream.py` | does 4800 baud deliver the longest stream the app offers, complete and in order? |
| `bench_priming.py` | time every step of a streaming decode, priming phases included |
| `bench_break.py` | **try to make it confidently wrong:** degenerate signals and contradictory settings |
| `bench_trigin.py` | rear TRIGGER IN — does an external pulse start a decode, and is it the sole source? |
| `bench_trigkey.py` | does the front-panel TRIGGER key actually arm a capture? |
| `bench_stopkey.py` | does that key reach a *running* recording? |
| `bench_cancelkey.py` | can it cancel a long decode? |
| `bench_sync.py` | alignment and resting-state checks shared by every bench harness |

### The on-instrument soak

| | |
|---|---|
| `run_bench.py` | hand a soak to the DMM6500 and walk away; the instrument drives the generator itself |
| `soak_listen.py` | listen for the instrument's own progress lines during an unattended run |
| `judge_bench.py` | judge a record written by `bench/bench_run.tsp` — the host decides bytes, never the instrument |
| `rejudge_soak.py` | re-judge a finished or running soak from its records |
| `offline_bench.lua` | run that same soak engine on the Mac against a real plan |
| `mock_bench.lua` | the instrument-side APIs `bench/` needs, so the whole soak runs on the Mac |
| `mock_display.lua` | a deliberately **hostile** mock of the display and file APIs |

### Long-running offline

| | |
|---|---|
| `soak.py` | run the bench suites for hours and count what fails, per point — the tool for intermittents |
| `soak_offline.py` | run the offline suites in a loop for a duration, on two trees at once |
| `soak_offline_long.py` | replay soak plan iterations offline, one lap per iteration, to a deadline |
| `plan_sweep.py` | run the offline twin of the soak's plan suite, sharded and ratcheted |
| `sweep_plan.lua` | that twin: the same cells as the bench, on the Mac |
| `sweep_all.py` | run every shard of `sweep_startphase.lua` in parallel and total it |
| `sweep_startphase.lua` | every vector, decoded from an arbitrary capture start, under noise |
| `sweep_rates.lua` | what would extra sample rates be worth? |
| `stress_serial.lua` | push the real decoder at deliberately bad signals |
| `tolerance.lua` | how much of each impairment the decoder survives, per baud rate |

### Offline test suites

| | |
|---|---|
| `test_serial.lua` | unit tests running the real `tsp/*.tsp` decoder |
| `test_bench_engine.lua` | the soak engine, including the paths a session on the box will not reach |
| `test_usblog.lua` | the filename allocator, `ulog.next_free()` |
| `test_cancel.lua` | one press decodes a whole transmission, and the TRIGGER key stops it |
| `test_analog.lua` | the same cases the bench runs, swept over phase, jitter and level |
| `test_patterns.lua` | the pathological byte patterns at both ends of the rate range |
| `test_ratefit.lua` | the hardware rate misfit, and silently-wrong-at-a-correct-rate |
| `test_forcerate.lua` | a forced rate the wire does not carry must refuse and name the truth |
| `test_frontrig.lua` | the trigger sources, driven through `sdec.acquire()` |
| `test_streamfix.lua` | three streaming defects, one test each |
| `test_octave.lua` | the probe is an octave out and nothing catches it |
| `test_snapbias.lua` | does jitter alone bias the width fit enough to relabel a rate? |
| `test_pushplan.py` | does the acknowledged-batch handshake put the plan on the key intact? |
| `test_sdg_guard.py` | every route by which an out-of-spec waveform could reach the SDG must refuse it |
| `test_seam.py` | the arb loop seam must not make the judge discard a correct capture |
| `test_judge_v.py` | gates the payload judge's three relaxations |
| `test_lorem_gate.py` | gates the long-payload verdict |
| `test_soaklog.py` | `soak.py` must keep every lap's output, especially the lap the bench died under |
| `test_soakrand.py` | hold both PRNGs *and the instrument's own Lua* to one sequence |

### Coverage, diagnosis, repro

| | |
|---|---|
| `cov.lua` | line coverage of `tsp/` during an offline suite, no dependencies beyond the debug library |
| `covreport.py` | report that coverage from the hit file |
| `covfunc.py` | per-**function** coverage, so a gap can be designed against by name |
| `debug_serial.lua` | diagnostic dump of the decoder's decision making |
| `diag_format.py` | why does a hardware capture disagree with the offline decode of the same file? |
| `diag_yield.py` | why does the same line give 70 bytes on one capture and 240 on the next? |
| `repro_v44.lua` | reproduce the intermittent 8O1/8N2 format misreads offline |
| `repro_startoff.lua` | the start-offset recipe, with the best-progress path instrumented |
| `seam_capture.lua` | reproduce a capture at every start offset across one arb period |
| `sdg_hang_repro.py` | reproduce the generator's remote-interface hang, minimally and on demand |
| `bringup_4b11.py` | which sample rates off the 1/2/5 ladder actually exist |
| `bringup_4b16.py` | can a running Lua script see a front-panel press? |

### Rendering and misc

| | |
|---|---|
| `mockup.lua` | record what the real `serial_ui.tsp` builds, for rendering |
| `render_png.py` | render panel artwork to PNG at exact panel pixels |
| `get_lua502.sh` | build the Lua 5.0.2 interpreter the instrument runs |

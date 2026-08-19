# Bench test vectors — naming plan

The stimulus waveforms stored on the SDG2122X. Current names (`v41`, `r07`, `v44c`) encode nothing, so
picking one at the bench means consulting `out/vectors/manifest.tsv`. This is the proposed rename.

**Nothing here has been applied.** Renaming a stored waveform on this generator means re-writing it
under the new name — there is no rename command — so see the constraints at the end before doing any
of it.

## Scheme

    SER_<Content>[_<NN>]_<Format>

* `SER_` prefix on everything, so the serial-decode vectors group together and sort apart from any
  other work on the instrument.
* `<Content>` names the payload, not the test. `Hello`, `Fox`, `Lorem1k`, `Random`, `Walk`, `Blocks64`.
* `<NN>` only for a numbered series, two digits, 1-based: `SER_Random_01_8N1`.
* `<Format>` is what is **on the wire**: `8N1`, `7E1`, `7O1`, `8E1`, `8O1`, `8N2`.

**The baud rate is deliberately absent.** It is set by the generator's sample rate at selection time
(`select_arb(name, amp, srate)`), so one waveform serves every rate. Putting a rate in the name would
imply five waveforms where there is one — see the duplicate groups below, which are byte-identical
files that exist only because they were rendered for a target rate.

## The 33 vectors currently on the instrument

From `STL? USER`, 2026-08-19. Fourteen further manifest vectors are **not** on the generator at all
(listed after).

| now | new name | payload | wire fmt | pts/bit | note |
|---|---|---|---|---|---|
| `v41` | `SER_Hello_8N1` | `Hello, World!` | 8N1 | 10.42 | |
| `v44a` | `SER_Hello_7E1` | `Hello, World!` | 7E1 | 10.42 | |
| `v44b` | `SER_Hello_7O1` | `Hello, World!` | 7O1 | 10.42 | |
| `v44c` | `SER_Hello_8E1` | `Hello, World!` | 8E1 | 10.42 | |
| `v44d` | `SER_Hello_8O1` | `Hello, World!` | 8O1 | 10.42 | |
| `v44e` | `SER_Hello_8N2` | `Hello, World!` | **8N2** | 10.42 | decodes *as* 8N1; see trap 1 |
| `v77` | `SER_Fox_8N1` | pangram + all 94 glyphs, 133 B | 8N1 | 10.42 | |
| `v78` | `SER_Fox_7E1` | pangram + all 94 glyphs, 133 B | 7E1 | 10.42 | |
| `v71` | `SER_Lorem1k_8N1` | lorem ipsum, 1024 B | 8N1 | 10.42 | |
| `v72` | — | *byte-identical to `v71`* | | 10.42 | retire |
| `v73` | — | *byte-identical to `v71`* | | 10.42 | retire |
| `v74` | — | same payload, re-rendered | 8N1 | 8.68 | redundant; see decision 2 |
| `v75` | — | same payload, re-rendered | 8N1 | 8.33 | redundant; see decision 2 |
| `v80` | `SER_Hello_8N1_sp10` | `Hello, World!` | 8N1 | 10.00 | collides with `v41`; see decision 1 |
| `v81` | — | *byte-identical to `v80`* | | 10.00 | retire |
| `v82` | — | *byte-identical to `v80`* | | 10.00 | retire |
| `v83` | — | *byte-identical to `v80`* | | 10.00 | retire |
| `v84` | — | *byte-identical to `v80`* | | 10.00 | retire |
| `v90` | `SER_Blocks64_8N1` | 64 each of `00 FF 55 AA` | 8N1 | 10.42 | reads as 7E1; see trap 2 |
| `v91` | `SER_Random_Ref_8N1` | 256 random, seed 20260818 | 8N1 | 10.42 | exact prefix of `v93` |
| `v92` | `SER_Walk_8N1` | walking-one / walking-zero | 8N1 | 10.42 | reads as 7O1; see trap 2 |
| `r00` | `SER_Random_01_8N1` | 256 random | 8N1 | 10.42 | |
| `r01` | `SER_Random_02_8N1` | 256 random | 8N1 | 10.42 | |
| `r02` | `SER_Random_03_8N1` | 256 random | 8N1 | 10.42 | |
| `r03` | `SER_Random_04_8N1` | 256 random | 8N1 | 10.42 | |
| `r04` | `SER_Random_05_8N1` | 256 random | 8N1 | 10.42 | |
| `r05` | `SER_Random_06_8N1` | 256 random | 8N1 | 10.42 | |
| `r06` | `SER_Random_07_7E1` | 256 random | 7E1 | 10.42 | |
| `r07` | `SER_Random_08_7E1` | 256 random | 7E1 | 10.42 | |
| `r08` | `SER_Random_09_7E1` | 256 random | 7E1 | 10.42 | |
| `r09` | `SER_Random_10_7E1` | 256 random | 7E1 | 10.42 | |
| `r10` | `SER_Random_11_7E1` | 256 random | 7E1 | 10.42 | |
| `r11` | `SER_Random_12_7E1` | 256 random | 7E1 | 10.42 | |

The `Random` index runs 01..12 unbroken across both formats, so no two vectors share an index. Splitting
it per format would give two different waveforms both called `01`.

## Not on the instrument

In `manifest.tsv` but absent from `STL? USER`. Names proposed for consistency; several would need
uploading before they could be used at all, which is presumably why they are missing.

| now | new name | payload | wire fmt |
|---|---|---|---|
| `v42` | — | `Hello, World!` re-rendered for 115200 | 8N1 |
| `v43` | — | `Hello, World!` re-rendered for 250000 | 8N1 |
| `v45` | `SER_Hello_8N1_Inv` | `Hello, World!`, inverted (RS-232 sense) | 8N1 |
| `v46` | `SER_Page200_8N1` | 200 B, sized for the paging boundary | 8N1 |
| `v47` | `SER_Hello_8N1_Spike` | `Hello` + impulse spikes at the amplitude ceiling | 8N1 |
| `v48a` | `SER_Hello_8N1_Drift06` | `Hello` + 0.6 V drift (inside tolerance) | 8N1 |
| `v48b` | `SER_Hello_8N1_Drift10` | `Hello` + 1.0 V drift (beyond tolerance) | 8N1 |
| `v51` | `SER_MIDI_8N1` | MIDI Note On / Note Off, 31250 | 8N1 |
| `v61` | `SER_LIN_01` | LIN: two frames, enhanced checksum | LIN |
| `v62` | `SER_LIN_02` | LIN: diagnostic 0x3C/0x3D, classic checksum | LIN |
| `v63` | `SER_LIN_03` | LIN: header with no response, then a good frame | LIN |
| `v76` | `SER_Lorem300_8N1` | lorem 300 B, loop-exact sweep vector | 8N1 |
| `v93` | `SER_Random_1k_8N1` | 1024 random, seed 20260818 | 8N1 |
| `v94` | `SER_Blocks128_8N1` | 128 each of `00 FF 55 AA` | 8N1 |

`v42`, `v43`, `v74` and `v75` get no name: they are the same payload as a vector that already has one,
re-rendered at a different points-per-bit. If the rate comes from `srate`, they carry no information.

## Two traps in the source data

**1. `exp_fmt` is what the DECODER should report, not what is on the wire.** `v44e` is generated with
**two stop bits** and the manifest's `exp_fmt` says `8N1` — correctly, because a second stop bit is
indistinguishable from idle, so 8N1 is the right answer for a decode. Naming it from that column would
lose the only thing that makes the vector worth having.

**2. Three vectors decode as a format they were not generated as, by construction.** `v90` and `v94`
(blocks of `00 FF 55 AA`) carry `exp_fmt = 7E1`, and `v92` (walking bits) carries `7O1`, while
`make_vectors.lua` generates all three as **8N1**. These payloads are format-ambiguous on purpose —
that ambiguity is the open issue #49. Naming them `7E1`/`7O1` would bake a known decoder ambiguity into
the vector names, and then a future fix to #49 would make every one of those names a lie. The table
above names them `8N1`, the stimulus.

## Two decisions left

**1. `v41` vs `v80`.** Both are `Hello, World!` 8N1; they differ only in render density, 10.42 against
10.00 points per bit, and they are different files. `SER_Hello_8N1_sp10` above is a placeholder. Either
keep both with the suffix, or retire one — `v41` is the plan's canonical row 4.1, `v80`..`v84` are the
rate-ladder vectors (`RATE_ARB` in `bench_matrix.py`), so they are both load-bearing today.

**2. Whether to retire the re-rendered duplicates** (`v72`, `v73`, `v74`, `v75`, `v81`–`v84`, `v42`,
`v43`). Nine of the 33 names on the instrument are duplicate or redundant renderings. Retiring them
means the code that names them must select the survivor and set `srate` for the rate it wants;
`bench_matrix.py` already does exactly that for the rate ladder via `RATE_ARB` + `RATE_SPB`.

## What renaming actually costs

There is no rename command on this generator: `ARWV NAME,x` selects, `WVDT` writes. A rename is a
re-write under the new name, and then a delete of the old one.

* **`SDG_UPLOAD_SAFE_BYTES` is 65536** (`tools/instruments.py`), and it is described there as a scar
  rather than a spec: repeated large `WVDT` uploads have wedged this generator's LAN service.
* **Seven vectors exceed it**: `v71` `v72` `v73` (213 750 B), `v74` (178 750), `v75` (171 000),
  `v93` (213 750), `v94` (107 250). These **cannot go over the LAN**. `out/vectors/USB-TRANSFER.md`
  covers `v93`/`v94` by USB key and does not mention the other five, so that document is incomplete.
* Retiring the duplicates helps here more than anywhere: of those seven, `v72`, `v73`, `v74` and `v75`
  are all redundant with `v71`, so the large-vector work drops from seven uploads to three.
* **The name-length limit is unverified.** Every name currently on the instrument is 3–4 characters.
  The longest proposed is `SER_Hello_8N1_Drift06` at 21, and `SER_Random_01_8N1` at 17. Establish the
  limit with **one** upload before committing to the scheme.

Renaming also touches every harness that names a vector: `bench_matrix.py` (`RATE_ARB`, `LOREM_ARB`,
and the suite tables), `bench_break.py`, `bench_panel.py`, `bench_priming.py`, `bench_longstream.py`,
`bench_buttons.py`, plus `manifest.tsv` and `make_vectors.lua`, which is what produces the files and
their names in the first place. Doing it as a mapping table in one place, rather than by find-and-
replace, keeps the old names usable until the instrument catches up.

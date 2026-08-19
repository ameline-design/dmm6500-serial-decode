# Bench test vectors — naming and coverage plan

The stimulus waveforms stored on the SDG2122X. Current names (`v41`, `r07`, `v44c`) encode nothing, so
choosing one at the bench means consulting `out/vectors/manifest.tsv`. This is the proposed rename plus
the coverage the set is missing.

**Nothing here has been applied.** Renaming a stored waveform on this generator means re-writing it
under the new name — there is no rename command — so read "What this costs" at the end first.

## Scheme

    SER_<Content>[_<NN>]_<Format>[_<Variant>]

* `SER_` on everything, so these group together and sort apart from other work on the instrument.
* `<Content>` names the payload, not the test: `Hello`, `Fox`, `Lorem1kB`, `Random`, `Walk`,
  `Blocks256B`. **Any size in a name carries its unit** — `Lorem300B`, `Lorem1kB`, `Blocks512B` — so no
  bare number can be mistaken for a baud rate. `300` and `600` are both payload lengths *and* standard
  baud rates, and `v80` is literally "hello 300 8N1", so `SER_Lorem300` would have read as a rate.
* `<NN>` only for a numbered series, two digits, 1-based: `SER_Random_01_8N1`.
* `<Format>` is what is **on the wire**: `8N1`, `7E1`, `7O1`, `8E1`, `8O1`, `8N2`, `5N1`, `6O1`, `9N1`.
* `<Variant>` for a deliberate impairment: `PErr8`, `Inv`, `Spike`, `Drift10`, `Gap2`.
* **`^[A-Za-z0-9_]+$` and nothing else.** Stated as a whitelist, because a list of banned characters
  always misses one: no `!` `~` `@` `#` `$` `%` `^` `&` `*` `(` `)` `-` `+` `/` `\` `,` `:` `;` `'` `"`,
  no spaces, and no dot. The underscore is the only separator, and it is *verified* on this instrument —
  names round-tripped through store, list, select and readback at 27, 28, 31 and 40 characters.
  The **dot is the one that would actively break**: `ARWV?` appends `.bin` to whatever it echoes and
  `select_arb` strips a trailing `.bin` from the name it asks for, so a dot in a name collides with that
  logic. Several of the others are SCPI or shell metacharacters — `,` terminates the `WVDT WVNM` field
  outright — so this is a constraint, not a style preference. `make_vectors.lua` should reject a name
  that fails the pattern rather than leave it to review.

**The baud rate is deliberately absent.** It is set by the generator's sample rate at selection time
(`select_arb(name, amp, srate)`), so one waveform serves every rate. Putting a rate in the name would
imply five waveforms where there is one — and there really is one: `v80`–`v84` are five names for a
byte-identical file, and `v71`/`v72`/`v73` are three more. Nine of the 33 names now on the instrument
are duplicate or redundant renderings.

## Payload width rules

A frame carries `<nbits>` data bits, so a payload has to fit the width. Measured ranges:

| payload family | range | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|
| Hello / Fox / Lorem (ASCII) | `0D`–`7E` | no | no | **yes** | yes | yes |
| Random (uniform) | `00`–`FF` | no | no | no | **yes** | yes |
| Blocks (`00 FF 55 AA`) | `00`–`FF` | no | no | no | **yes** | yes |
| Walk (`01`..`80`, `FE`..`7F`) | `01`–`FE` | no | no | no | **yes** | yes |

Three rules follow, and they are not the same rule:

1. **Random and Blocks: discard the high-order bits.** `v & (2^w - 1)`. A 7-bit `Random` is the same
   payload with bit 7 dropped; the vector keeps its purpose, which is that every decode path meets byte
   values it cannot have been tuned for.
2. **Walking patterns must be built AT the width, not masked.** Masking a walking-one to 7 bits turns
   `80` into `00`, which duplicates an existing entry and destroys the one property the vector has —
   each byte putting a single 1 in a *distinct* position. A 7-bit walk is `01 02 04 08 10 20 40`.
3. **Text cannot go below 7 bits at all.** `H` is `0x48`; masked to 6 bits it is `0x08`. There is no
   6-bit "Hello". The narrow-width vectors need purpose-built low-value payloads — `Low5`, `Low6`.

### One collision to know about

Blocks masked to 7 bits is `00 7F 55 2A`. That is **byte-for-byte what a 7E1 mis-decode of the 8-bit
Blocks vector produces** — it is the `exp_hex` the manifest already records for `v90`. So
`SER_Blocks256B_7E1` and a wrong-format decode of `SER_Blocks256B_8N1` yield identical bytes. That is
useful — it is a matched pair for open issue #49 — but it has to be written down, because a bench
result that cannot distinguish them will otherwise read as a decoder bug.

## Renaming what already exists

24 distinct waveforms behind 33 names, from `STL? USER` on 2026-08-19.

| now | new name | payload | wire fmt | pts/bit |
|---|---|---|---|---|
| `v41` | `SER_Hello_8N1` | `Hello, World!` | 8N1 | 10.42 |
| `v44a` | `SER_Hello_7E1` | `Hello, World!` | 7E1 | 10.42 |
| `v44b` | `SER_Hello_7O1` | `Hello, World!` | 7O1 | 10.42 |
| `v44c` | `SER_Hello_8E1` | `Hello, World!` | 8E1 | 10.42 |
| `v44d` | `SER_Hello_8O1` | `Hello, World!` | 8O1 | 10.42 |
| `v44e` | `SER_Hello_8N2` | `Hello, World!` | **8N2** | 10.42 |
| `v77` | `SER_Fox_8N1` | pangram + 94 glyphs, 133 B | 8N1 | 10.42 |
| `v78` | `SER_Fox_7E1` | pangram + 94 glyphs, 133 B | 7E1 | 10.42 |
| `v71` | `SER_Lorem1kB_8N1` | lorem ipsum, 1024 B | 8N1 | 10.42 |
| `v90` | `SER_Blocks256B_8N1` | 64 each of `00 FF 55 AA` | 8N1 | 10.42 |
| `v91` | `SER_RandomRef_8N1` | 256 random, seed 20260818 | 8N1 | 10.42 |
| `v92` | `SER_Walk_8N1` | walking one / walking zero | 8N1 | 10.42 |
| `r00`–`r05` | `SER_Random_01_8N1` … `SER_Random_06_8N1` | 256 random each | 8N1 | 10.42 |
| `r06`–`r11` | `SER_Random_07_7E1` … `SER_Random_12_7E1` | 256 random each | 7E1 | 10.42 |
| `v80` | `SER_Hello_8N1_sp10` | `Hello, World!` | 8N1 | 10.00 |
| `v72` `v73` | — | byte-identical to `v71` | | retire |
| `v81`–`v84` | — | byte-identical to `v80` | | retire |
| `v74` `v75` | — | `Lorem1k` re-rendered, 8.68 / 8.33 | | retire |

The `Random` index runs 01..12 unbroken across formats, so no two share an index. `v41` vs `v80` is
unresolved: both are `Hello, World!` 8N1 differing only in render density, and both are load-bearing
(`v41` is the plan's canonical row, `v80` is `RATE_ARB` in `bench_matrix.py`). `SER_Hello_8N1_sp10` is a
placeholder, not a recommendation — and `sp10` is **samples per bit, not a baud rate**; if that reads as
a rate to anyone it is the wrong suffix and the two vectors should be resolved by retiring one instead.

**Two traps in the source data.** `manifest.tsv`'s `exp_fmt` is *what the decoder should report*, not
what is on the wire. `v44e` is generated with two stop bits and its `exp_fmt` is `8N1` — correctly, a
second stop bit being indistinguishable from idle — so naming it from that column would lose the only
reason the vector exists. And `v90`, `v92`, `v94` carry `exp_fmt` of `7E1`/`7O1` while the `vec{}` calls
pass no format at all and therefore render **8N1**: those payloads are format-ambiguous by construction,
which is issue #49. Naming them `7E1` would freeze a decoder ambiguity into the vector set and a fix to
#49 would make the names lies.

## Filling out to 7E1 / 7O1 / 8N1 for every content

Nine new renders, plus four re-renders that cost no extra names.

| new name | from | note |
|---|---|---|
| `SER_Fox_7O1` | Fox payload | |
| `SER_Lorem1kB_7E1` | lorem 1 kB | **~213 kB, over the LAN ceiling** |
| `SER_Lorem1kB_7O1` | lorem 1 kB | **~213 kB, over the LAN ceiling** |
| `SER_Blocks256B_7E1` | masked to `00 7F 55 2A` | see the collision above |
| `SER_Blocks256B_7O1` | masked to `00 7F 55 2A` | |
| `SER_Walk_7E1` | walk built at 7 bits | not masked — rule 2 |
| `SER_Walk_7O1` | walk built at 7 bits | not masked — rule 2 |
| `SER_RandomRef_7E1` | masked, bit 7 dropped | |
| `SER_RandomRef_7O1` | masked, bit 7 dropped | |

**The `Random` series regroups rather than triples.** Twelve payloads across three formats, four each:
`01`–`04` 8N1, `05`–`08` 7E1, `09`–`12` 7O1. That keeps twelve distinct random payloads and all three
formats for the same twelve uploads — only four need re-rendering, against 24 new vectors if every
payload got every format.

## A smattering of 5, 6 and 9 bits

These widths are exactly the ones the decoder deliberately does **not** search: 5 and 6 only under
"Auto (any width)" and heavily biased against, 9 reachable only by forcing. So they test the forced and
rare-width paths, which nothing else does.

| new name | payload | why this one |
|---|---|---|
| `SER_Low5_5N1` | 0–31, purpose-built | the rare-width path at all |
| `SER_Low5_5E1` | 0–31 | parity on a rare width |
| `SER_Low6_6N1` | 0–63, purpose-built | |
| `SER_Low6_6O1` | 0–63 | |
| `SER_Low6_6N1_Gap2` | 0–63, 2-bit gap | **the documented collision**: `uart_decode.tsp` notes that 6 data bits plus a stop plus two idle bits is exactly a 10-cell 8N1 frame, so both score equally and the loser's bytes are silently wrong |
| `SER_Random_9N1` | 0–511 | catches the `+256` laundering the format search warns about — a 9-bit rival absorbs 8N1 stop-bit damage into a data bit and reports *fewer* errors while every byte is 256 too large |
| `SER_Hello_9N1` | `Hello, World!` | the forced-width path on a payload with a known answer |

## Parity-error vectors

**Purpose: prove a flagged byte reddens its row in the MIDDLE of the dump and reads `?` in the ASCII
gutter.** Today's red-row work was verified only on *head* errors from a mid-byte start. An interior
parity error has never been checked on hardware, and it is a different code path — the head is counted
by extent, interior failures are counted individually.

Two constraints:

* **8N1 has no parity bit**, so a parity error is impossible there. These only exist on `7E1`, `7O1`,
  `8E1`, `8O1`.
* **Injections must be interior.** `sdec.ua_edge_frames` is 3 and the final frame is always excluded, so
  an error in the first three bytes or the last one is treated as a windowing artefact and does not
  count. An injection at byte 2 would prove nothing about the interior path.

**Spacing makes the count assertable.** For a looping payload, if the injection interval divides the
capture window the error count is the same wherever the capture lands. Computed over all 300 start
offsets: a **300-byte payload with a parity error every 30 bytes yields exactly 8 errors in a 240-byte
window, invariantly**. Nearby choices do not — every 25 bytes gives 9 or 10, and a 256-byte payload
every 32 gives 7 or 8. The real window wanders a byte or two, so assert `8 ± 1`, or better, assert that
`ERR` equals the number of `?` in the gutter, which is self-consistent at any window.

| new name | payload | injected | note |
|---|---|---|---|
| `SER_Fox_7E1_PErr1` | Fox, 133 B | 1, mid-payload | the minimum honest signal: `ERR 1`, one red row |
| `SER_Lorem300B_7E1_PErr8` | lorem 300 B | 8, every 30 B | the invariant-count vector; 8 red rows spread down the dump |
| `SER_Lorem300B_7O1_PErr8` | lorem 300 B | 8, every 30 B | same, odd parity |
| `SER_Random_05_7E1_PErr8` | 256 random, masked | 8 | parity errors on a payload with no ASCII structure to lean on |
| `SER_Hello_8E1_PErr1` | `Hello, World!` | 1 | 8-bit parity, so the width is not what is under test |
| `SER_Fox_7E1_PErr64` | Fox, 133 B | ~half | deliberately unarbitrable: checks the search does not silently pick a laundering format rather than reporting a mess |

**This needs a renderer change.** `tools/gen_serial.lua` accepts only `nbits` and `par` (lines 67–68);
there is no injection option in it or in `make_vectors.lua`. It needs something like
`perr = {frame indices}` threaded through the frame builder, and `make_vectors.lua` has to expose it and
record the injected positions in `manifest.tsv` so the expected bytes stay derivable rather than stored.

## Other injections worth building

Ordered by what each one catches. The strongest are the ones that turn a documented weakness or an open
issue into a single named stimulus, so the answer stops depending on whether the bench happens to
reproduce it. `<Variant>` carries the injection and its count or parameter.

### Framing, and the two exclusions we rely on

| name | injection | what it catches |
|---|---|---|
| `SER_Fox_8N1_StopErr8` | stop bit driven to space, 8 frames | **the only error vector 8N1 can have.** Parity errors are impossible without a parity bit, so today 8N1 has no error coverage at all — and the stop bit is what the whole format search leans on |
| `SER_Lorem300B_7E1_PErrHead3` | parity errors in frames 1–3 only | the **head exclusion**, deliberately. With no misaligned head, `ERR` must read 0 while the row is still **red** — the exact divergence pinned in `test_serial.lua` today. A vector makes it checkable on glass |
| `SER_Lorem300B_7E1_PErrTail1` | parity error in the final frame only | the **tail exclusion**: the capture boundary halves the last frame, so it must not count. Currently asserted offline only |
| `SER_Fox_8N1_Runt4` | start bit, then idle before the frame completes | a glitch that looks like a frame opening. Nothing tests this; the framer's behaviour is unstated |
| `SER_Fox_8N1_Break1` | line held at space > 10 bit times | a real UART break. The app has **no stated handling** — it should not report a break as a run of garbage bytes, and nobody knows which it does |

### The failure mode the app itself calls its worst

| name | injection | what it catches |
|---|---|---|
| `SER_Fox_8N1_BitFlip8` | narrow spike inside a **data** bit, framing intact | `serial_ui.tsp` says it outright: "Impulse noise on a data bit flips it undetectably — the start and stop bits are still in place, so the frame passes." This vector produces **wrong bytes with `ERR 0`**, which is the one thing the panel cannot warn about. It is a known-limitation vector: the pass condition is that the bytes differ from the payload and `ERR` is 0, documenting the hole rather than pretending it is closed |

### Timing, including a gap with no task yet

| name | injection | what it catches |
|---|---|---|
| `SER_Lorem300B_8N1_RateStep` | first half 9600, second half 19200 | **the padlock gap seen on 2026-08-19**: the generator went 19.2 k → 76.8 k, 4×, and the locked rate was not abandoned despite the "abandon a locked rate the wire contradicts" defence. That has no repro and no task. One vector turns it into a bench point |
| `SER_Fox_8N1_Sub2x` | bit pattern making the half-rate fit plausible | regression vector for **issue #29** — 9600 detected as 19200, which then reads as 7N1. Fixed in `ua_submultiple`, and `v44e`'s wrong-answer regression came back once already |
| `SER_Fox_8N1_NoIdle` | zero gap at the loop seam | **issue #49**, open: 7E1 with no idle gap read as 8N1. It also forces the mid-byte start that today's `headbad` work is all about, on demand instead of one capture in eight |
| `SER_Fox_8N1_Skew2pc` | payload 2 % fast of nominal | the sampling phase walks across the frame. Tests `FIT` and `refine_width` — and issue #40 is a width collapse on a forced wrong rate |
| `SER_Fox_8N1_Jitter5pc` | per-edge random jitter | edge-timing tolerance, which `FIT` claims to measure |

### Analogue, extending what `v47`/`v48` started

| name | injection | what it catches |
|---|---|---|
| `SER_Fox_8N1_SlowEdge` | RC-limited transitions | threshold crossing away from the ideal point; nothing tests slew today |
| `SER_Fox_8N1_LowSwing` | swing collapses mid-capture | the auto-threshold following a signal that stops separating. `Drift06`/`Drift10` move the whole band; this shrinks it |

### Naming rule for these

`<Injection><Count>` where the count is the number injected (`PErr8`, `StopErr8`, `Break1`), or
`<Injection><Parameter>` where a magnitude is the point (`Skew2pc`, `Jitter5pc`). The count in the name
is the assertion: `SER_Lorem300B_7E1_PErr8` must produce `ERR 8`, so a bench result that disagrees with
the vector's own name is a finding without anyone writing a test for it. That is the whole reason not to
call it `v22` — the name is the expected value.

Where a count is only invariant for a particular window, the invariance is a property of the spacing,
not the name: see the 300 B / every 30 B calculation above.

## Excluded from the "every format" rule, with reasons

* **MIDI** (`v51`) is 8N1 at 31250 **by specification**. A 7E1 MIDI stream is not MIDI, so the variants
  would be fiction dressed as coverage.
* **LIN** (`v61`–`v63`) is likewise 8N1 by specification.
* **The impairment vectors** — `Inv`, `Spike`, `Drift06`, `Drift10` — test analogue damage, which is
  orthogonal to framing. Tripling them adds uploads and no information. One parity-format drift vector
  would be worth having if parity-under-drift is ever a question.

## Not on the instrument at all

In `manifest.tsv` but absent from `STL? USER`, consistent with `select_arb`'s own note about twelve
vectors added to a suite and never uploaded: `v42` `v43` `v45` `v46` `v47` `v48a` `v48b` `v51` `v61`
`v62` `v63` `v76` `v93` `v94`. Proposed names: `SER_Hello_8N1_Inv`, `SER_Page200B_8N1`,
`SER_Hello_8N1_Spike`, `SER_Hello_8N1_Drift06`, `SER_Hello_8N1_Drift10`, `SER_MIDI_8N1`, `SER_LIN_01`
`SER_LIN_02` `SER_LIN_03`, `SER_Lorem300B_8N1`, `SER_Random1kB_8N1`, `SER_Blocks512B_8N1`. `v42`, `v43`
get none — same payload as `SER_Hello_8N1`, re-rendered for a rate that `srate` now supplies.

## What this costs

There is no rename command: `ARWV NAME,x` selects, `WVDT` writes. A rename is a re-write plus a delete
of the old name.

* **`SDG_UPLOAD_SAFE_BYTES` is 65536** (`tools/instruments.py`), described there as a scar rather than a
  spec: repeated large `WVDT` uploads have wedged this generator's LAN service.
* **Over the ceiling today**: `v71` `v72` `v73` (213 750 B), `v74` (178 750), `v75` (171 000), `v93`
  (213 750), `v94` (107 250) — seven. `out/vectors/USB-TRANSFER.md` covers only `v93`/`v94`, so that
  document is incomplete. Retiring the redundant renders takes the seven to three.
* **The additions add two more over the ceiling**: `SER_Lorem1kB_7E1` and `_7O1`, ~213 kB each. Every
  other new vector is under it — Blocks/Walk/Random ~50–54 kB, Fox ~28 kB, Hello ~4 kB.
* **Name length: measured 2026-08-19, not a problem.** Probed on the instrument with 16-point (32-byte)
  uploads, three orders of magnitude under the ceiling, so the naming question was tested without going
  near the failure mode.

  | length | stored in `STL? USER` | selects | reads back |
  |---|---|---|---|
  | 27 | full | yes | `…PErrHead30.bin` |
  | 28 | full | yes | full + `.bin` |
  | 31 | full | yes | full + `.bin` |
  | 40 | full | yes | full + `.bin` |

  **No truncation up to at least 40 characters**, and `ARWV?` appends `.bin` to whatever it echoes, so a
  40-character name reads back as 44. `select_arb` already strips a trailing `.bin` from the name it
  asks for, so its readback check passes at every length tested.

  **`.bin` does NOT count against the limit** — the hypothesis that 31 was the ceiling *including* the
  suffix is refuted: a 31-character name reads back at 35 and selects correctly.

  **Discrimination checked, not just storage.** Two names differing only in the final character before
  `.bin`, at 31 and at 40, stored as two distinct entries and each selected itself. Storable is not the
  same as distinguishable: had the firmware truncated internally, a pair like that would have collapsed
  into one entry and silently played the wrong waveform, which `select_arb`'s substring check could not
  have caught for the shorter of the two.

  The longest name in this plan is 26, so nothing here is near any limit.

Rough totals: 24 renames, 9 format fills, 4 re-renders, 7 narrow/wide, 6 parity-error — about 50
waveform writes, four of which cannot go over the LAN.

Renaming also touches every harness that names a vector: `bench_matrix.py` (`RATE_ARB`, `LOREM_ARB`, the
suite tables), `bench_break.py`, `bench_panel.py`, `bench_priming.py`, `bench_longstream.py`,
`bench_buttons.py`, plus `manifest.tsv` and `make_vectors.lua`, which produces the files and their names
in the first place. Doing it as a mapping table in one place, rather than find-and-replace, keeps the old
names working until the instrument catches up.

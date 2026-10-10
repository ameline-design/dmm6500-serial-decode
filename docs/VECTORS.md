# Bench test vectors — naming and coverage plan

The stimulus waveforms stored on the generator — an SDG2122X here, though any SDG2000X will do and
`docs/BENCH.md` says why. Current names (`v41`, `r07`, `v44c`) encode nothing, so
choosing one at the bench means consulting `out/vectors/manifest.tsv`. This is the proposed rename plus
the coverage the set is missing.

**Status 2026-08-19: APPLIED for 35 of 37 vectors.** They are uploaded to the SDG under these names and
every one is verified selectable — `tools/upload_vectors.py` holds the mapping and does the work. Still
outstanding: `SER_Random1kB_8N1` and `SER_Blocks512B_8N1`, both over the LAN ceiling, going one at a time
with a power cycle between. The additions in "Filling out", "A smattering" and "Parity errors" are still
plans; the renderer support for the parity ones is written and tested (`GEN opts.perr`).

There is no rename command on this generator, so applying a name means writing the waveform under it and
deleting the old one from the front panel.

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

## What a vector puts on the wire

**The file carries shape only.** `GEN_WRITE` encodes 16-bit signed codewords against a full scale of
`fsv` volts, which is `AMP/2` — so `fsv = 5.0` means AMP 10 Vpp — and `GEN_RENDER` takes its logic
levels from `opts.lo or 0` and `opts.hi or 3.3`. Every clean vector takes those defaults, so on the
wire

    low  = OFST
    high = OFST + K * AMP,     K = 21626 / 65534 = 0.33000

where 21626 is `GEN_CODE(3.3, 5.0, 0)` and 65534 is two codeword full scales, one per half of AMP.
**AMP 10 Vpp at OFST 0 is therefore a 0.00…3.30 V line and not a ±5 V one.** The generator reads about
0.27 % high: `K` fits to 0.3309 ± 0.0002 across eight AMP/OFST settings measured on the instrument, and
`docs/BENCH.md`'s ground-truth capture gives 6.6186 V at 20 Vpp, a ratio of 0.33093.
`out/vectors/manifest.tsv` records each vector's band in volts, and `bench_matrix.amp_for` inverts the
formula as `amp = 10 * swing / 3.3`, which is the route every tool that asks for a swing in volts takes.

`_x10` and `_x100` in a name are **samples per bit**, not amplitude: `SRATE = baud * mult`.

### Codeword range per family

Read from `out/vectors/*.bin` as int16 little-endian. Volts are at each family's reference AMP.

| family | ids | cw lo | cw hi | ref AMP | band at ref | K lo | K hi | peak % of FS |
|---|---|---|---|---|---|---|---|---|
| clean | `v41` `v44a`–`v44e` `v45` `v46` `v51` `v71` `v76`–`v78` `v90`–`v97` `r00`–`r11` `j02` `j10` `j20` | 0 | 21626 | 10.0 | 0.000…3.300 | 0.00000 | **0.33000** | 66.0 % |
| LIN | `v61`–`v63` | 0 | 26214 | 15.0 | 0.000…6.000 | 0.00000 | **0.40001** | 80.0 % |
| spike | `v47` | −9830 | 20643 | 20.0 | −3.000…6.300 | −0.15000 | 0.31500 | 63.0 % |
| drift 0.6 | `v48a` | −3932 | 25558 | 10.0 | −0.600…3.900 | −0.06000 | 0.39000 | 78.0 % |
| drift 1.0 | `v48b` | −6553 | 28180 | 10.0 | −1.000…4.300 | −0.09999 | 0.43001 | **86.0 %** |

**The three vectors that go negative are not bipolar in the useful sense.** In all three the negative
excursion is the impairment riding on an unchanged logic pair: `v47`'s logic levels are codewords 0 and
10813, and `v48a`/`v48b` keep `v41`'s 0 and 21626 exactly. So `K` for a LOGIC level is 0.16500 on `v47`
and 0.33000 on both drift vectors, whatever the extremes in the table say.

**None of these reaches the DAC's full scale, and nothing enforces that.** It follows from each `vec{}`
entry's `fsv` and from `GEN_RENDER`'s `lo`/`hi` defaults, so an entry that passes its own `lo`/`hi` is
not bound by it. The largest peak in the set is `v48b` at 86.0 % of +FS, and that is a drift excursion
rather than a logic level.

### The generator envelope, and what a symmetric bipolar band costs

`|OFST| + AMP/2 ≤ 10` is the SDG's own limit. `soakplan.assert_unclipped` raises on it and
`bench_matrix.offset_limit` keeps the draw inside it, and it is checked **nowhere else**:
`siglent.select_arb`, `siglent.load_arb_file` and `bsdg.select` in `bench/sdg_net.tsp` all bound AMP
alone. An out-of-envelope pair is therefore clamped silently, the band arrives recentred, and nothing
records what reached the wire — so read `C1:BSWV?` back after any hand-written offset.

For a symmetric ±S band from a vector whose low level is codeword 0, `OFST = −S` and `AMP = 2S/K`, so
`S + S/K ≤ 10` and **S ≤ 10K/(1+K)**:

| family | K | symmetric cap | AMP | OFST |
|---|---|---|---|---|
| clean | 0.33000 | **±2.4812 V** | 15.0376 | −2.4812 |
| LIN | 0.40001 | **±2.8572 V** | 14.2857 | −2.8572 |

The LIN family buys 15 % more symmetric swing and costs LIN framing and a different baud. `v47` is
worse rather than better: a logic `K` of 0.16500 caps its symmetric swing at ±1.4163 V.

### `v41` AT A NEGATIVE OFFSET IS THE HARNESS BUG, NOT A BIPOLAR LINE

`v41` and `v45` both span codewords 0…21626 and both render 0.000…3.300 V at their reference AMP. The
difference is which codeword is the IDLE, and it decides whether a negative offset produces a real
RS-232 line or a stimulus no wire could carry.

* **`v45` idles at codeword 0.** It is rendered inverted — `GEN_RENDER` flips the logical cell before
  mapping it to `lo`/`hi`, so the inversion happens inside 0…3.3 V — and it is on the generator as
  `SER_Hello_8N1_Inv_x10`. A negative offset puts the MARK at the negative level, which is RS-232, and
  `sdec.sig_levels` reads it correctly.
* **`v41` idles at codeword 21626.** The same negative offset puts idle POSITIVE and space NEGATIVE.
  Both levels still clear `sdec.flatfloor`, so `sig_levels` still reads RS-232 and still marks at the
  negative level — which is the SPACE. The decode comes back inverted: right rate, right format,
  self-consistent bytes matching nothing. That is this repo's own harness bug and not a decoder defect.
  `soakplan.py` records what it cost — 17.3 % of cells driven straddling ground, accounting for 86.8 %
  of every offline failure.

**A bipolar line therefore needs no new vector and no upload.** `v45` is already stored, so one call
does it:

    g.select_arb(VN.arb('v45'), 15.038, 96000, offset_v=-2.481)   # -2.481 .. +2.481 V, idling LOW

`select_arb` writes `C1:ARWV` and `C1:BSWV AMP,…,OFST,…` and transfers nothing, so none of the WVDT
upload budget is spent.

## The full-scale family, `f00`–`f16`

**These are the vectors that reach ±FS**, and they exist because the section above shows nothing else
does. An `f` vector renders `lo = −fsv` and `hi = +fsv`, so its codewords span **−32767…+32767**,
`K` is −0.5 and +0.5 on the two rails, and on the wire

    low  = OFST − AMP/2
    high = OFST + AMP/2

exactly. AMP 10 / OFST 0 is a true −5.000…+5.000 V line and AMP 20 / OFST 0 reaches ±10.000 V, the
generator's ceiling — **4.03× the clean family's ±2.4812 V symmetric cap**. The same file still gives
an ordinary logic line: AMP 3.3 / OFST 1.65 is 0.000…3.300 V. `min_v`/`max_v` in
`out/vectors/manifest.tsv` record −5.000/+5.000 for all fifteen.

| ids (normal / inverted) | payload | formats | npts | bytes |
|---|---|---|---|---|
| `f00` / `f10` | `Hello, World!`, 13 B | 8N1 | 1 942 | 3 884 |
| `f01`–`f03` / `f11`–`f13` | `ASCII94`, 133 B | 8N1, 7E1, 7O1 | 13 500 | 27 000 |
| `f04`–`f06` / `f14`–`f16` | 256 random, seed 20261010 | 8N1, 7E1, 7O1 | 25 800 | 51 600 |
| `f07` | 1024 random, same seed | 8N1 | 102 600 | 205 200 — **over the upload ceiling** |

`f1x` is the inverted counterpart of `f0x` and there is deliberately no `f17`. Geometry is copied from
the vector each row pairs with — `f00`/`f10` from `v41`, the fox rows from `v77`/`v78`, the 256-byte
rows from `r00` — so a new row differs from its pair in the CODEWORD SPAN and nothing else. Because
the span is symmetric each `f1x` file is the **exact codeword-for-codeword negation** of its `f0x`
pair, which `v41`/`v45` cannot be: theirs is `c_inv = 21626 − c`, a reflection about a non-zero
midpoint. `f04`'s 256 bytes are the exact prefix of `f07`'s 1024, and `f05`/`f06` are `f04` masked to
7 bits.

### `f1x` IS AN RS-232 LINE AND `f0x` IS NOT — the same trap as `v41` vs `v45`

At AMP 10 / OFST 0 **both** families straddle ground, so `sig_levels` reads RS-232 and marks at the
NEGATIVE level for both. Which codeword that is decides everything, exactly as above:

* **`f1x` idles at codeword −32767.** Mark IS the negative rail, so the prior is right. Measured over
  48 window phases: correct in **34 of 34** (fox) and **41 of 41** (random) windows holding no idle.
* **`f0x` idles at codeword +32767.** Mark is the POSITIVE rail, so the prior is upside-down —
  correct in **0 of 34** and **0 of 41**. `ua_autoformat` overturns it wherever a parity bit or a
  random bit 7 stops the inverted reading framing cleanly, and `f02`–`f06` do decode the same at every
  band. **8N1 ASCII cannot**: `f01` goes from 5 of 34 payload-exact on a single-rail band to **0 of
  34** across ground, because ASCII's always-clear bit 7 puts a rising edge exactly nine bit times
  after every start bit.

**So for a bipolar line use `f1x`.** `f0x` at a symmetric band is the `v41`-at-a-negative-offset
stimulus with more swing, and AMP 3.3 / OFST 1.65 is what it is for. Three ways to get one, cheapest
first:

| want | use | cost |
|---|---|---|
| ±2.481 V | `v45`, AMP 15.038 OFST −2.481 | already stored, no upload |
| ±5.000 V | `f10` / `f11` / `f14`, AMP 10 OFST 0 | one 3.9–51.6 kB upload |
| ±10.000 V | the same, AMP 20 OFST 0 | the same upload |

### Two rules this family added

**A name's content-plus-variant part has 16 characters.** `brun.cellline` puts `id baud fmt wave` on
TEXT2, where `brun.wave` is the stored name less `SER_`, `_x10` and the format token.
`display.settext` caps TEXT2 at 32 and the firmware warns and shortens anything longer — for a soak, a
panel event per cell. At the widest baud the bench drives (250000, six digits) and a four-character id
(`v44a`–`v44e`) the fixed part is 16, so **abbreviate the CONTENT token, not the variant**: the variant
is what tells two rows apart. Hence `Full` over `FullScale` and `Rnd256B` over `Random256B`, with the
size keeping its unit either way. `tools/test_bench_engine.lua` asserts this over every name in `MAP`;
the widest is now 31 of 32, and the old names all fit but `v48a`/`v48b` have only 3 characters spare.

**They are declared out of every draw.** `vector_names.BENCH_ONLY` lists all fifteen and
`soakplan.soak_vectors()` is the one place that applies it. `bench/arb_names.tsp` carries
`barb.benchonly` so `sweep_startphase.lua` — which enumerates `VEC_LIST`, a **second population
independent of `MAP`** — reads the same judgement rather than restating it. `--spec`, `--plan-spec`
and `--skip-vectors` still accept them by name: the exclusion governs the DRAW, which is the thing
nobody asks for explicitly. Drawing them would do two unwanted things at once — drive the full-scale
ones across ground at the plan's own offsets, manufacturing the artefact above at scale, and change
the population every per-cell ratchet is calibrated on.

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
| `v80` | `SER_Hello_8N1_Sp10` | `Hello, World!` | 8N1 | 10.00 |
| `v72` `v73` | — | byte-identical to `v71` | | retire |
| `v81`–`v84` | — | byte-identical to `v80` | | retire |
| `v74` `v75` | — | `Lorem1k` re-rendered, 8.68 / 8.33 | | retire |

The `Random` index runs 01..12 unbroken across formats, so no two share an index. `v41` vs `v80` is
unresolved: both are `Hello, World!` 8N1 differing only in render density, and both are load-bearing
(`v41` is both the plan's canonical row and `RATE_ARB` in `bench_matrix.py`). `SER_Hello_8N1_Sp10` is a
placeholder, not a recommendation — and `Sp10` is **samples per bit, not a baud rate**; if that reads as
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


## Two things measured while uploading, 2026-08-19

**A waveform in a subdirectory cannot be selected. Store flat.** 34 vectors were written as
`SERIAL\name` -- forward slashes are accepted by the write and then appear nowhere, a silent no-op --
and every one was listed by `STL? USER`. `ARWV NAME` then refused all of them: by full path
(`SERIAL\name`), by the other separator, and by basename alike, leaving the previous selection playing.
So the store is effectively flat, and a name with a separator in it is a name that will never work.

`select_arb` is what found it, and the first probe was a **false positive**: `WVDT` leaves its own write
selected, so reading `ARWV?` straight after an upload reports the upload rather than the select. Park the
selection on a known root vector first or the test proves nothing.

**One large upload at a time is safe.** `SER_Lorem1kB_8N1` at 213 750 B -- 3.3x `SDG_UPLOAD_SAFE_BYTES` --
wrote in 2.3 s, appeared in `STL? USER`, selected through `select_arb`, and decoded on the DMM at 9600.
The SCPI service answered `*IDN?` immediately afterwards. The wedge recorded in `tools/instruments.py`
took **four consecutive** 170-210 kB uploads, so the ceiling is a bound on a RUN of large writes rather
than on one. Protocol for the remaining two: one upload, power-cycle the generator, next upload.

That makes `out/vectors/USB-TRANSFER.md` less necessary than it looked -- the USB key is a convenience
for a batch, not the only route for a single vector.

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

### Byte budget

What is on the instrument today, from `manifest.tsv` for the 33 names `STL? USER` reports:

| | bytes | |
|---|---|---|
| 33 vector waveforms | **1 895 000** | 1850 kB |
| — of which 8 redundant duplicates | 792 786 | 774 kB — **42 % of everything stored** |
| — of which 7 exceed the LAN ceiling | 991 000 | 968 kB |
| 7 probe waveforms from the name-length test | 304 | negligible |
| **total stored now** | **1 895 304** | **1.81 MB** |
| after deleting the duplicates and probes | 1 102 214 | 1.08 MB |

The five largest are `v71`, `v72`, `v73` (213 750 B each), `v74` (178 750) and `v75` (171 000) — and
four of those five are the redundant renders.

Projected for the 22 additions in this plan, from a cell-count model calibrated against the real files
(exact on `v71`, `v90` and `v92`; within 0.4 % on `v77`; it over-predicts a 13-byte payload by ~23 %,
where lead and tail dominate):

| | bytes | |
|---|---|---|
| 22 additions | 1 288 580 | 1258 kB |
| **projected total once built** | **2 390 794** | **2.28 MB** |

**Only two additions exceed the 64 kB LAN ceiling**: `SER_Lorem1kB_7E1` and `SER_Lorem1kB_7O1`, at
213 750 B each. Everything else fits the network path — `Blocks256B` and `RandomRef` land at 53 750,
`Lorem300B` variants at ~63 000, `Random_9N1` at ~59 000. An earlier estimate here wrongly flagged six as
over the ceiling; it assumed a 2-bit inter-frame gap, and the real `vec{}` calls pass `gap = 0`.

The instrument's total internal capacity is **not known** — nothing in the repo records it and no query
for it was found. 2.28 MB is the figure to check against it before starting.

### Internal flash is limited, so the order of work matters

Measured 2026-08-19: **an upload overwrites in place.** Re-writing an existing name left the `STL? USER`
count unchanged at 40, so a rename never *duplicates* — but it does leave the old name behind, because
the new name is a different entry.

**No SCPI delete was found.** `ARWV` selects, `WVDT` writes, `STL?` lists; nothing in the guide sections
this repo already uses deletes a stored waveform. Deletion appears to be front-panel only
(Utility → Store/Recall). Treat that as the current state of knowledge, not a proven absence.

So a rename holds **both copies resident** until the old one is deleted by hand, and the flash is not
large. Do it in this order:

1. **Delete the nine redundant duplicates first — biggest win, no new uploads.** `v72` and `v73`
   (213 750 B each), `v74` (178 750), `v75` (171 000) are all redundant with `v71`; `v81`–`v84` are
   redundant with `v80`. That frees roughly **760 kB** and removes four of the seven over-ceiling
   vectors before anything is written.
2. **Then rename in batches**, deleting each old name as its replacement lands, rather than uploading
   all ~50 and deleting afterwards — which would need peak space for both sets at once.
3. **Do the two over-ceiling additions by USB key**, with the `Lorem1kB` renames, in one trip:
   `SER_Lorem1kB_8N1`, `_7E1`, `_7O1` at ~213 kB each.

**Probe waveforms left by the name-length testing, to delete from the front panel.** Seven, all 16–32
points, so a few hundred bytes in total — but they should not outlive the measurement:

    SER_Zabcdefghijklmnopqrstuvwxyz
    SER_Lorem300_7E1_PErrHead30
    SER_Lorem300_7E1_PErrHead300
    SER_DiscrimxxxxxxxxxxxxxxxxxxxA
    SER_DiscrimxxxxxxxxxxxxxxxxxxxB
    SER_DiscrimxxxxxxxxxxxxxxxxxxxxxxxxxxxxA
    SER_DiscrimxxxxxxxxxxxxxxxxxxxxxxxxxxxxB

Renaming also touches every harness that names a vector: `bench_matrix.py` (`RATE_ARB`, `LOREM_ARB`, the
suite tables), `bench_break.py`, `bench_panel.py`, `bench_priming.py`, `bench_longstream.py`,
`bench_buttons.py`, plus `manifest.tsv` and `make_vectors.lua`, which produces the files and their names
in the first place. Doing it as a mapping table in one place, rather than find-and-replace, keeps the old
names working until the instrument catches up.

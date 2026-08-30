# tsp/ — the app itself

A UART decoder that runs **on** a Keithley DMM6500, written in TSP — Lua **5.0.2** embedded in the
firmware, so these modules avoid `#`, `%`, `string.gmatch`, `string.match`, `math.fmod` and bitwise
operators throughout. **Six of the eight ship**; MIDI and LIN are complete but held back.

`tools/package_tspa.py` builds `Serial_Decode.tspa` from this directory and decides which modules ship.
Each module is a script *body* populating one shared table, `sdec` (plus `ulog` for the logger), so load
order barely matters — except that `usb_log` goes first, because `serial_app` calls `ulog.line()` during
`start()`, and `serial_app` goes last, because it is the entry point. Usage is in
[../docs/MANUAL.md](../docs/MANUAL.md); measured numbers and firmware limits are in
[../docs/REFERENCE.md](../docs/REFERENCE.md).

| module | lines | what it is |
|---|---|---|
| `usb_log.tsp` | 528 | best-effort debug logging to the USB key, and the single-write-handle allocator every other writer has to respect |
| `serial_core.tsp` | 2205 | acquisition, signal conditioning and bit-timing recovery — the digitizer, the sample-rate ladder, thresholding and baud estimation |
| `uart_decode.tsp` | 2179 | asynchronous serial framing: start/stop/parity arbitration, format fitting and the per-frame error flags |
| `chunk_decode.tsp` | 1183 | decode of a capture **longer than Lua memory**, one window at a time, resumable across windows |
| `serial_ui.tsp` | 3193 | the front-panel screens — the main readout, Options, the button matrix, glyph-width text fitting |
| `serial_app.tsp` | 3061 | lifecycle, touch handlers and capture orchestration; the entry point `sdec.start()` lives here |
| `midi_decode.tsp` | 303 | MIDI 1.0 message layer on top of the UART frames. **Complete and tested, not shipped in version 1** |
| `lin_decode.tsp` | 468 | LIN (ISO 17987) frame layer, break/sync/PID and checksum. **Complete, not shipped** — the checksum has never been checked against a real frame |

Re-adding either unshipped module is one line in `tools/package_tspa.py`; the app discovers what it has
at runtime.

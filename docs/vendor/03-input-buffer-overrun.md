# 3. `-363 input buffer overrun` on the execute path, at a size `loadscript` handles 800× faster

**DMM6500, firmware 1.7.17a.** LAN raw socket, port 5025. No signal or second instrument needed; the USB
key is used only as somewhere to write to.

## Summary

Sending executed statements of roughly **2 kB** raises **-363 "input buffer overrun"** on the panel —
**even when the host waits for a printed acknowledgement from each statement before sending the next**,
so the host can never be more than one statement ahead of the interpreter.

That last clause is what makes this a report rather than a rate-limit question. If a strict
request/response handshake still overruns, the input buffer is smaller than a single statement of that
size, or it is not drained before the next write is accepted.

Meanwhile `loadscript` accepts **805 285 bytes / 14 686 lines in 1.0 s** with **no flow control at all**
and an empty event log.

## What was measured

Transferring a 19 MB data file to the USB key by writing it in batches, each batch one statement of the
form `do file.write(_pw, "<rows>") _pn = _pn + N print("PW=" .. tostring(_pn)) end`, with the host
reading the `PW=` reply before sending the next:

| rows per statement | statement size | result |
|---|---|---|
| 20 | ~1960 chars | **-363 input buffer overrun** on the panel, within seconds |
| 5 | ~640 chars | **279 934 rows / 18 815 142 bytes clean**, 571 rows/s, 55 987 statements |

Only the statement size changed between those two runs — same code, same handshake, same socket, same
file. And for contrast, on the same instrument in the same session:

| transport | payload | flow control | time | events |
|---|---|---|---|---|
| `loadscript` … `endscript` | 805 285 B / 14 686 lines | **none** | **1.0 s** | 0 |
| executed statements | 18 815 142 B / 55 987 statements | one ack per statement | 488 s | 0 |

So the working execute path is roughly **800× lower effective throughput** than the store path, and the
failing execute path fails at a size the store path does not notice.

## Reproduction

`repro-03-buffer-overrun.py` — find the statement length at which -363 appears. Each statement is
self-acknowledging and the host waits for the reply, so nothing is ever queued.

```python
import socket, time
s = socket.create_connection(('<dmm-ip>', 5025), timeout=30)
def ask(stmt):
    s.sendall(stmt.encode() + b'\n')
    buf = b''
    while b'\n' not in buf:
        buf += s.recv(4096)
    return buf.decode().strip()

s.sendall(b'eventlog.clear()\n')
for n in (200, 400, 600, 800, 1000, 1200, 1600, 2000, 3000, 4000):
    pad = 'x' * n
    r = ask('do local s = "%s" print("LEN=" .. tostring(string.len(s))) end' % pad)
    ev = ask('print("EV=" .. tostring(eventlog.getcount()))')
    print('%5d chars -> %-14s %s' % (n, r, ev))
    if not r.startswith('LEN=') or not ev.endswith('EV=0'):
        print('  ^ first failure at ~%d characters' % n)
        break
```

## Expected

Either a documented maximum statement length for the execute path, or a supported way to flow-control
it. A handshake that waits for each statement's own output ought to be sufficient by construction.

## Actual

-363 on the panel at ~2 kB per statement despite the handshake, with no documented limit to design
against.

## Impact

Moving bulk data to the instrument's USB key over the LAN is the only option when the key must not be
handled by hand. The workaround — 5 rows per statement — costs **55 987 round trips and 8.1 minutes**
for 19 MB, where the store path moves comparable volume in about a second.

It also makes the failure mode unpleasant: -363 lands on the panel as an error, so a transfer that is
merely too ambitious puts a message in front of the operator.

## Questions

1. **What is the input buffer's size, and what is the maximum statement length the execute path
   accepts?** Neither appears in the reference manual.
2. **Is there a supported flow-control mechanism for the execute path** beyond waiting for output?
3. **Is `loadscript` the sanctioned transport for bulk data?** If so it deserves saying, and we will
   build on it. The one drawback we have found is that reloading a script name calls `script.delete`
   first, which logs `-104 Data type error` every time even though the name really is freed — so a
   chunked transfer either accumulates that event once per chunk or leaks a script name per chunk.

## Not yet characterised

1. **The exact failing length.** The loop above bisects it; the two known points are 640 (works) and
   1960 (fails).
2. **Whether it depends on statement length or on total bytes in flight.** Repeat at a safe length for
   many thousands of statements — the 279 934-statement run says length, but that is one data point at
   one length.
3. **Whether the `-104` from `script.delete` reaches the panel** or is log-only. Roughly a dozen reloads
   in one session produced no panel dialog, which suggests log-only, but that is absence of evidence.

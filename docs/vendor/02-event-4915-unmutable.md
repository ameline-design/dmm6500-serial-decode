# 2. Event 4915 puts a modal dialog over a running app, and nothing can prevent it

**DMM6500, firmware 1.7.17a.** No signal, no USB key, no second instrument needed.

## Summary

Arming a `LoopUntilEvent` trigger model over a digitize buffer posts event **4915** *"attempting to
store past the capacity of a reading buffer"* — **ten times per capture** at 1 MS/s. 4915 is ERROR
severity, and the front panel displays error-severity events as a **modal dialog on top of the running
app**, whatever `localnode.showevents` is set to.

`localnode.showevents` governs the **remote** interface only. There is no documented setting that
suppresses panel display of an event, so an app whose requirement is "never put a message in front of
the operator" has no mechanism available — the event has to not be *instigated*.

## Why it fires

`LoopUntilEvent` reserves a pre-trigger fraction of the buffer — 5 % by default. At 1 MS/s over a
20 000-sample buffer that reserve is **1.05 ms**, which is shorter than the wait for the next qualifying
edge on a slow signal. The reserve therefore wraps, and on a `FILL_ONCE` buffer every overwrite is a
discard that posts the event.

Measured at 1200 baud:

| requested rate | samples returned | 4915 events |
|---|---|---|
| 1 MS/s | 21 100 (the whole buffer) | **10 per capture** |
| 10 kS/s | 20 085 (the depth asked for) | **0** |

**Raising `position` does not help.** The firmware computes post-trigger count as
`count - count × position/100`, so a reserve long enough to cover the edge wait at 1 MS/s costs roughly
two thirds of the capture depth.

## Reproduction

`repro-02-4915.tsp` — arm a trigger model at 1 MS/s with events muted on the remote interface, then
report the event count. Watch the panel while it runs.

```lua
localnode.showevents = 0            -- remote interface only, as it turns out
eventlog.clear()
local buf = buffer.make(20000, buffer.STYLE_STANDARD)
buf.fillmode = buffer.FILL_ONCE
dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.samplerate = 1000000
dmm.digitize.count = 20000
-- Arm on an analog edge that will not come quickly with nothing connected.
dmm.digitize.aperture = dmm.APERTURE_AUTO
trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5, buf)
trigger.model.initiate()
delay(3)
trigger.model.abort()
print('events after ONE armed capture = ' .. tostring(eventlog.getcount()))
print('LOOK AT THE FRONT PANEL: a modal dialog is over whatever screen was showing.')
```

## Expected

One of:

* an app-visible way to suppress panel display of an event, so an unattended instrument stays silent; or
* 4915 not being ERROR severity, since discarding pre-trigger samples is normal operation for a wrapping
  reserve rather than an error; or
* the pre-trigger reserve not discarding into a `FILL_ONCE` buffer at all while waiting to trigger.

## Actual

Ten error-severity events per capture, each shown as a modal dialog over the app, with no setting that
prevents it.

## Impact

**This app abandoned edge-triggered acquisition entirely because of it.** The unattended soak now
captures free-running (`trigmode = 'free'`), which costs real capability: a free-run capture opens at an
arbitrary phase of the signal, so head alignment is not comparable with an edge-armed capture and the
harness has to compensate by sampling many phases.

For any TSP app intended to be left running — a logger, a monitor, a production test fixture — a modal
dialog that cannot be suppressed is disqualifying, because it blocks the panel until someone dismisses
it and there is nobody there.

## Not yet characterised

1. **Whether 4915 appears at every rate or only where the reserve is shorter than the trigger wait.**
   Sweep `samplerate` from 10 kS/s to 1 MS/s with the same buffer and count events at each.
2. **Whether `buffer.FILL_CONTINUOUS` avoids it** while still giving a usable pre-trigger window.
3. **Whether any `position` value avoids it without an unacceptable depth cost** — measure events and
   returned sample count against `position` from 5 to 66.
4. **Whether other error-severity events behave the same way**, i.e. whether this is 4915 specifically or
   the general rule for ERROR severity on the panel. If it is the general rule, that is the report.

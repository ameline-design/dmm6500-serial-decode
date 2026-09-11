# 1. `display.create` fails silently at 463 objects, and the pool cannot be enumerated or recovered by any documented means

**DMM6500, firmware 1.7.17a.** No signal, no USB key, no second instrument needed.

## Summary

There are **463 display objects available per power cycle**. Past that, `display.create` returns **nil**:
it does not raise, and event **1701** *"The maximum number of objects have already been created"* is
logged for the failure but there is no return value to distinguish "pool full" from any other nil.

An app that hits the ceiling builds a screen whose children are all nil, `pcall` around the build reports
success, and the panel comes up blank. That is the defect: **a resource limit that a program cannot
query, cannot recover through any documented call, and learns about only by checking every single
`display.create` result for nil.**

`display.delete` is sound and is **not** part of this report.

## Measured

Each row is one run on a freshly power-cycled instrument, creating a screen plus one text child per
cycle. `repro-01-object-pool.py` drives all of them.

| run | deletes | result |
|---|---|---|
| `none` | none | **first nil at cycle 232, on the CHILD** — 462 objects created, so the 463rd call fails |
| `both` | child, then screen, every cycle | **2000 of 2000 cycles clean**, 0 nil, 0 events |
| `screen` | screen only, child left | **2000 of 2000 cycles clean**, 0 nil, 0 events |

Three facts follow, none of which the reference states:

1. **The ceiling is 463 objects.** For scale: this app's panel is 134 objects, so three builds fit in one
   power cycle and the fourth cannot.
2. **The failure lands on the child.** The screen at cycle 232 was created and its text object was not,
   so the app-visible symptom is a screen that exists with nothing on it.
3. **A screen takes its children with it.** Deleting only the parent freed both, for 2000 cycles.

## The handle is a plain number, and that is the whole problem

```
first screen handle: 49   type number
first text handle:   50   type number
```

Handles are small sequential integers; 0..48 belong to the firmware's own home screen on a freshly
booted DMM6500. **The space is 512 slots, and the firmware states it**: `display.delete(9999)` answers

```
1130   Parameter id, expected value from 0 to 511
```

512 slots less the 49 the firmware holds is **463**, which is the figure the exhaustion run measures
independently. In-range handles that were never issued answer 1703 instead, so the two failures are
distinguishable: 1130 means no such slot exists, 1703 means the slot is empty.

Because a handle is a **number**, it carries no finalizer — so when a program loses its
handles, nothing anywhere can free those objects. There is no `display.deleteall()`, no way to enumerate
live objects, and no way to ask how many remain.

**`collectgarbage()` cannot help, and this was tested rather than assumed.** With the pool exhausted:

```
after collectgarbage() x3:  create -> nil     Lua heap 1211 -> 502 kB
after collectgarbage(1):    create -> nil     (threshold forced to its floor)
display.delete(49):         accepted   ->     create -> 49
```

Four collections freed 709 kB of Lua heap and zero display objects. The control on the last line is what
makes it conclusive: one `display.delete` by value returned a slot immediately, so the pool was
recoverable the whole time — garbage collection simply is not the mechanism. The display subsystem and
the Lua heap are separate allocators.

## Deleting by value does recover the pool, undocumented

```lua
-- Exhausted pool, then:
local h
for h = 49, 511 do pcall(function() display.delete(h) end) end   -- 511 is the top of the space
```

```
exhausted after 232 cycle(s); handles ran 49..511
create while exhausted   -> nil
swept 49..511: every call accepted, none raised
create after the sweep   -> 49
cycles available again:  230   of the original 231
```

Full recovery, no power cycle. **Two costs make this a rescue procedure rather than something an app
should do:**

* `display.delete` on a handle that was never issued does not raise. It logs **1703 "The object ID was
  never created or has been destroyed"** — one entry per call, 383 from a single sweep, and each one is a
  dialog on the front panel. The panel flickers throughout.
* Handles 0..48 are the firmware's. A sweep that starts lower than 49 vandalises the home screen.

## `display.delete` is not the problem

Deleting frees correctly, including children when only their screen is deleted -- the `both` and `screen`
runs above are 2000 cycles each with no failure. An app that deletes what it creates never meets any of
this. The report is about the limit being invisible and unrecoverable once a handle is gone.

## Also observed

**Deleting the screen that is currently displayed leaves the panel black**, with no way back from the
front panel: there is no fallback to the home screen. `display.changescreen` away from it first. Creating
a screen also switches to it, so a create/delete loop leaves the panel black for as long as it runs.

## What would fix it, in order of value

1. **A way to ask.** `display.count()` or `display.max()` — any query for how many objects exist and how
   many remain. Every problem above is downstream of a limit a program cannot see.
2. **A distinguishable failure.** Raise on exhaustion, or return a second value naming the reason. nil
   alone is indistinguishable from every other nil, and the app has to test every create to survive.
3. **A documented way to free objects whose handles are gone** — `display.deleteall()`, or a statement in
   the reference that deleting by integer handle is supported, since it demonstrably works.
4. **Do not leave the panel black** when the displayed screen is deleted.
5. **Say the number.** 463 is not in the reference, and an app developer needs it to budget a UI.

## Reproduction

| file | what it does |
|---|---|
| `repro-01-object-pool.py` | the three runs in the table — `none`, `both`, `screen`. One power cycle each |
| `repro-01-recover-pool.py` | exhausts the pool, sweeps by value, reports how much came back |
| `repro-01-object-pool.tsp` | the same loop as a plain TSP script, for pasting into a session |

Every one is standard library only: no app, no USB key, no signal, no second instrument.

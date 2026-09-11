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

`display.delete` is sound and is **not** part of this report — see *What is not wrong* below.

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

Handles are small sequential integers; 1..48 belong to the firmware's own home screen on a freshly
booted DMM6500. Because a handle is a **number**, it carries no finalizer — so when a program loses its
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
for h = 49, 511 do pcall(function() display.delete(h) end) end
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
* Handles 1..48 are the firmware's. A sweep that starts lower than 49 vandalises the home screen.

## What is not wrong

An earlier version of this report claimed `display.delete` does not free objects. **That was wrong**, and
the `both` and `screen` runs above disprove it: 2000 create/delete cycles, no failure. The
"few reloads then a power cycle" behaviour that prompted that claim was **our own defect** — three host
loader scripts did

```lua
if sdec ~= nil then ... buffer.delete(sdec.buf) ... end
sdec = nil                 -- the only reference to 134 live display objects, dropped
```

which handed the reading buffer back and stranded every display object. Calling the app's own teardown
before dropping the table fixed it: **six consecutive load-and-build cycles now run with no power cycle
and 300 objects still free**, where the fourth used to fail. It is recorded here because anyone reading
this report is likely to have the same bug.

## Also observed

**Deleting the screen that is currently displayed leaves the panel black**, with no way back from the
front panel — no fallback to the home screen. `display.changescreen` away from it first. Seen twice:
after a run that deleted 2000 screens, and again at the moment a create/delete loop deleted the screen it
had just switched to.

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

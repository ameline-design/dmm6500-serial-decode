# DMM6500 TSP: the display object pool is 463, and you can get it back without a power cycle

*Draft for EEVblog. Code fences map to `[code]` tags. Measured on a DMM6500, firmware 1.7.17a,
embedded Lua 5.0.2.*

---

If you write TSP apps that draw on the DMM6500's own front panel, you have probably met this: after a
few reloads during development, `display.create` starts returning **nil**. It does not raise. Your app
builds a screen, every child is nil because the parent was, `pcall` reports success, and the panel comes
up blank. Event **1701** *"The maximum number of objects have already been created"* is in the log, and
that is all you get.

I finally measured it instead of working around it.

**The pool is 463 objects per power cycle.** Creating a screen plus one text child, never deleting:

```
first nil at cycle 232, on the CHILD
objects created before it: 462
```

So 231 screens + 231 children succeed, and call 463 fails. The failure lands on the *child*, which is
why the symptom is a screen that exists with nothing on it. For scale, my app builds 134 objects, so
three builds fit in one power cycle and the fourth cannot — which matches the "about four reloads" folk
rule exactly.

**`display.delete` is not the problem.** 2000 create/delete cycles ran clean, 0 failures. Deleting only
the *parent* also ran 2000 clean, so children are freed with their screen. If you delete what you
create, you will never see this.

**The real trap is losing your handles.** Reloading a TSP script replaces the table they were in, so the
previous build's objects become unreachable — nothing can delete them, and the pool shrinks by one build
per reload.

**`collectgarbage()` does not help.** Pool exhausted, then four collections including one with the
threshold forced to its floor:

```
after collectgarbage() x3:  create -> nil     Lua heap 1211 -> 502 kB
after collectgarbage(1):    create -> nil
display.delete(49):         accepted -> create -> 49
```

709 kB of Lua heap freed, zero display objects. The reason is that a handle is a plain **number** — 49,
50, 51 … — with no finalizer, so dropping it tells the firmware nothing. The display subsystem and the
Lua heap are separate allocators.

**But that also means the handles are guessable, and deleting by value works:**

```lua
-- Recover an exhausted pool without a power cycle.
-- 49 is the first handle issued after boot; 1..48 belong to the firmware's own home screen.
-- Stop at the highest handle you have seen: display.delete on a handle that was never issued
-- does not raise, it logs 1703 "Object id is invalid", and each of those is a dialog on the panel.
local h
for h = 49, 511 do pcall(function() display.delete(h) end) end
eventlog.clear()
```

After that sweep, `display.create` returned 49 again and **230 of the original 231 cycles were
available**. Full recovery, no power cycle.

Two smaller things found on the way:

* **Deleting the screen that is currently displayed leaves the panel black**, with no way back from the
  front panel. Call `display.changescreen` away from it first.
* `display.delete` on an invalid handle is silent to Lua but noisy in the log — 383 entries of 1703 from
  one sweep, each one a popup. Bound your sweep, and clear the log after it.

Firmware 1.7.17a. If anyone has a different pool size on another model or firmware — 2450, 2460, DAQ6510
— I would like to know whether 463 is a DMM6500 number or a TSP-wide one.

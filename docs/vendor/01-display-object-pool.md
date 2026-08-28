# 1. `display.delete` does not free display objects, and `display.create` then fails silently

**DMM6500, firmware 1.7.17a.** No signal, no USB key, no second instrument needed.

## Summary

Display objects created with `display.create` are **not returned to the allocation pool by
`display.delete`**. After enough create/delete cycles in one power cycle, `display.create` returns
**nil** — it does not raise, and event **1701** *"the maximum number of objects have already been
created"* is logged **only the first time**. Every subsequent failure is completely silent.

The silence is the actual defect. A nil parent makes every child nil too, so an app builds a screen
with no controls on it, `pcall` around the build reports success, and there is nothing in the event log
to explain it.

## Reproduction

`repro-01-object-pool.tsp` — build a screen, delete it, repeat, and report the cycle at which
`display.create` first returns nil.

```lua
-- Build and delete one screen with one child, repeatedly. Print the cycle where create() fails.
local n = 0
while n < 500 do
  n = n + 1
  local scr = display.create(display.ROOT, display.OBJ_SCREEN, 'POOL ' .. tostring(n))
  if scr == nil then
    print('create returned NIL at cycle ' .. tostring(n)
          .. '  eventlog.getcount()=' .. tostring(eventlog.getcount()))
    break
  end
  local txt = display.create(scr, display.OBJ_TEXT, 12, 20, 'x',
                             0xFFFFFF, display.FONT_MEDIUM, display.JUST_LEFT)
  if txt == nil then
    print('CHILD returned nil at cycle ' .. tostring(n) .. ' while the screen did not')
    break
  end
  display.delete(txt)
  display.delete(scr)
  if math.mod(n, 10) == 0 then
    print('cycle ' .. tostring(n) .. ' ok, events=' .. tostring(eventlog.getcount()))
  end
end
print('done at cycle ' .. tostring(n))
```

## Expected

Either `display.delete` returns the object to the pool so the loop runs indefinitely, or
`display.create` reports the exhaustion **every time** it happens — by raising, or at minimum by
logging 1701 on each failure rather than once.

## Actual

The loop terminates at a finite cycle count. `display.create` returns nil with no raise and, after the
first occurrence, no event.

## Impact

**An app that builds a UI can only be started a few times per power cycle.** For this app the build is
**122 live objects** after the main screen and **134** once the options screen is built too — counted,
not estimated. In practice a few dozen rebuild cycles exhaust the pool, so:

* developing a panel app needs a **power cycle per iteration** once the count is reached;
* every automated hardware test suite has to demand a fresh power cycle as a precondition, because a
  failure from an exhausted pool is indistinguishable from a failure in the code under test;
* an app cannot defensively rebuild its screen after an error, which is the obvious recovery.

The workaround is to create every object **once** and only ever `settext`/`setcolor` afterwards, and to
check every single `display.create` result for nil and raise on it. That is what this app does, and it
is why it refuses to build rather than coming up with missing controls.

## Not yet characterised

1. **The pool size.** How many objects can exist at once, and does the limit count objects or
   allocations? The loop above answers this directly.
2. **Whether `display.delete` frees anything at all.** Compare the failure cycle for the loop above
   against the same loop with the two `display.delete` calls removed. If the counts match, delete is
   inert; if the first is larger, it frees partially.
3. **Whether children are freed with their parent.** Delete only the screen, not the text, and compare.
4. **Whether a `display.changescreen` away from a screen before deleting it changes the outcome.**

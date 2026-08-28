-- Report 1: does display.delete return objects to the pool, and does display.create say when it fails?
--
-- DMM6500, firmware 1.7.17a. Nothing connected. Paste into a TSP session, or send over the socket.
-- RUN THIS ON A FRESHLY POWER CYCLED INSTRUMENT: the pool does not reset any other way, so a second run
-- in one power cycle measures whatever the first left behind.
--
-- Set FREE = false for the comparison run: if the failure cycle is the same either way, display.delete
-- is inert. That comparison is the point of the script.

local FREE = true
local MAX = 500

eventlog.clear()
print('FREE=' .. tostring(FREE) .. '  events at start=' .. tostring(eventlog.getcount()))

local n = 0
while n < MAX do
  n = n + 1
  local scr = display.create(display.ROOT, display.OBJ_SCREEN, 'POOL ' .. tostring(n))
  if scr == nil then
    print('display.create returned NIL for the SCREEN at cycle ' .. tostring(n)
          .. '   events=' .. tostring(eventlog.getcount()))
    break
  end
  local txt = display.create(scr, display.OBJ_TEXT, 12, 20, 'x',
                             16777215, display.FONT_MEDIUM, display.JUST_LEFT)  -- white, decimal:
                             -- stock 5.0.2 luac does not lex 0xFFFFFF, though the instrument does
  if txt == nil then
    print('display.create returned NIL for the CHILD at cycle ' .. tostring(n)
          .. ' while the screen succeeded   events=' .. tostring(eventlog.getcount()))
    break
  end
  if FREE then
    display.delete(txt)
    display.delete(scr)
  end
  -- The event count is printed as it goes because 1701 is logged ONCE: a count that stops rising while
  -- create() keeps failing is the silent-failure half of the report.
  if math.mod(n, 10) == 0 then
    print('cycle ' .. tostring(n) .. ' ok   events=' .. tostring(eventlog.getcount()))
  end
end

print('stopped at cycle ' .. tostring(n) .. '   events=' .. tostring(eventlog.getcount()))
print('read the log: eventlog.next() -- expect 1701 ONCE, not once per failure')

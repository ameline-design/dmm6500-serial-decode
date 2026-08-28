-- Report 2: can event 4915 be kept off the front panel?
--
-- DMM6500, firmware 1.7.17a. Nothing need be connected -- with no signal the analog trigger simply does
-- not fire, which is the condition that makes the pre-trigger reserve wrap.
--
-- WATCH THE PANEL while this runs. The events are the measurement; the modal dialog over whatever screen
-- was showing is the report.

localnode.showevents = 0        -- documented as suppressing events; governs the REMOTE interface only
eventlog.clear()

local buf = buffer.make(20000, buffer.STYLE_STANDARD)
buf.fillmode = buffer.FILL_ONCE

dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.count = 20000

-- ONE ARMED CAPTURE AT EACH RATE. The reserve is 5 % of the buffer, so at 1 MS/s it is ~1.05 ms -- far
-- shorter than the wait for an edge that never comes -- and every overwrite of it is a discard.
local rates = {10000, 100000, 1000000}
local k
for k = 1, table.getn(rates) do
  eventlog.clear()
  dmm.digitize.samplerate = rates[k]
  trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5, buf)
  trigger.model.initiate()
  delay(3)
  trigger.model.abort()
  delay(0.5)
  print(string.format('samplerate %-9d  readings %-7s  events %s',
                      rates[k], tostring(buf.n), tostring(eventlog.getcount())))
end

print('')
print('Expected from the measurement made while writing this: 10 kS/s -> 0 events,')
print('1 MS/s -> 10 events, each shown on the panel as a modal dialog despite showevents = 0.')
print('')
print('THE SECOND HALF OF THE QUESTION: is this 4915 specifically, or every ERROR-severity event?')
print('If the latter, then no TSP app can guarantee a quiet panel, which is the real report.')

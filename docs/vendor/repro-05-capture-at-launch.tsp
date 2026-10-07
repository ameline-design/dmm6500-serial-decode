-- ============================================================================
-- repro 05: a digitize capture taken from a TSP app's own entry point
--           bluescreens the instrument when the app runs from INTERNAL MEMORY
--
-- DMM6500, firmware 1.7.17a. NOTHING NEED BE CONNECTED: the capture is free
-- running, so it fills its buffer from whatever the open input reads and never
-- waits for a trigger. No signal, no second instrument, no USB key.
--
-- HOW TO RUN IT
--   1. Save this as a .tspa with any $Title and INSTALL IT TO INTERNAL MEMORY
--      (MENU > Manage Apps, from a USB key).
--   2. Run it once. It prints DONE.
--   3. RESTART THE INSTRUMENT.  <-- this step is required
--   4. Run it again.
--
-- WHAT THE APP UNDER OBSERVATION DOES
-- The same archive placed on a USB key and run from there is unaffected, and a
-- capture started by a BUTTON PRESS after launch is unaffected. Only a capture
-- reached from the entry point, on a build held in internal memory, after a
-- restart.
--
-- STATUS: CANDIDATE, NOT YET CONFIRMED. The behaviour above is measured against
-- a 13 500-line application (3 of 3 crashes with the launch-time capture
-- present, 2 of 2 clean with only that call removed, everything else identical).
-- THIS standalone script has NOT yet been shown to reproduce it. If it does not,
-- the difference between it and the real app is the remaining evidence, and the
-- most likely missing ingredient is the number of display objects the real app
-- builds before capturing -- about 145, against 2 here.
--
-- WHAT IS NOT THE CAUSE, each refuted by a purpose-built artefact:
--   * app size. A generated app with a LARGER compiled chunk (190113 bytes
--     against the real app's 187613) and MORE stored source (278366 against
--     271345) runs cleanly through the same install/restart/run cycle.
--   * stored source size. Stripping 58 kB of comments from the real app, which
--     leaves the compiled chunk within 16 bytes, does not help.
--   * a corrupt stored copy. The installed script's own `.source` is
--     byte-identical to the archive that was installed: 271345 bytes, 7164
--     lines, same CRLF endings.
--   * a display timer firing. Blanking the timer's EVENT_PRESS handler string
--     still crashes.
-- ============================================================================

rc = {}
rc.nsmp = 20000           -- readings per capture
rc.fs   = 1000000         -- 1 MS/s
rc.caps = 3               -- captures per run

-- The namespace is `dmm` on this instrument; resolved rather than assumed so the
-- script also runs on a model that exposes it as `localnode`.
rc.ns = dmm
if rc.ns == nil or rc.ns.digitize == nil then rc.ns = localnode end

function rc.capture(n)
  local dig = rc.ns.digitize
  dig.func       = rc.ns.FUNC_DIGITIZE_VOLTAGE
  dig.range      = 10
  dig.samplerate = rc.fs
  dig.aperture   = 1e-6

  -- A fresh buffer per capture, deleted before being replaced. buffer.make()
  -- gives a FILL_ONCE buffer; its minimum is 10.
  if rc.buf ~= nil then
    pcall(function() buffer.delete(rc.buf) end)
    rc.buf = nil
  end
  rc.buf = buffer.make(n)

  dig.count = n
  rc.buf.clear()
  dig.read(rc.buf)                 -- free running: returns when count is reached

  -- READ THE SAMPLES OUT INTO LUA, which is what the real application does next
  -- and the heaviest thing a capture does.
  local rd, t = rc.buf.readings, {}
  local got, i = rc.buf.n or 0, nil
  for i = 1, got do t[i] = rd[i] end
  rc.last = got
  return got
end

function rc.start()
  rc.scr = display.create(display.ROOT, display.OBJ_SCREEN, 'REPRO05')
  rc.txt = display.create(rc.scr, display.OBJ_TEXT, 20, 60, 'capturing...')
  display.changescreen(rc.scr)

  -- THE CAPTURE IS REACHED FROM THE ENTRY POINT. That is the whole point of the
  -- script: moving these calls behind a button makes the fault go away.
  local i
  for i = 1, rc.caps do
    print('CAPTURE ' .. i .. ' of ' .. rc.caps)
    pcall(function() display.settext(rc.txt, 'capture ' .. i) end)
    local ok, err = pcall(function() rc.capture(rc.nsmp) end)
    if not ok then
      pcall(function() display.settext(rc.txt, 'raised: ' .. tostring(err)) end)
      print('RAISED ' .. tostring(err))
      return
    end
    print('  got ' .. tostring(rc.last) .. ' readings')
  end
  pcall(function() display.settext(rc.txt, 'DONE, ' .. rc.caps .. ' captures') end)
  print('DONE')
end

rc.start()

-- bench_run.tsp -- the soak loop, running on the instrument with nobody connected.
--
-- brun.soak(n) runs n iterations of the plan; brun.soak() or brun.soak(0) runs until the power is cut.
-- Every cell is written to the USB key as it completes, because a power cycle is the stop button and
-- there is no graceful exit to save anything at.
--
-- THE MEASUREMENT SEQUENCE IS NOT INVENTED HERE. brun.point() below is the same sequence as
-- bench_point() in tools/bench_uart.py's BENCH_TSP string, which is what every bench result this
-- project has ever recorded came through: clear the event log, clear every force, set fs and trigmode,
-- acquire, decode, read the same fields off sdec. If the two drift apart then this soak stops measuring
-- what the bench measures, which is its whole justification -- so tools/test_bench_engine.lua loads
-- BOTH and compares them on one capture rather than trusting this comment.
--
-- THE PLAN IS READ, NEVER DRAWN. tools/soakplan.py emits it and the key carries it. Re-deriving the
-- draw here would mean a second implementation of the log-uniform placement, the ladder-edge
-- substitution and -- worst -- the skip-before-shuffle indexing, where the positional index keys the
-- amplitude, the offset AND the wait. That last one has already cost this project 1677 mis-driven
-- cells in a single lap, silently, and it looked exactly like a working run.
--
-- STREAMED, NOT LOADED. The plan for a long soak is tens of thousands of rows; reading it whole would
-- spend instrument memory on data used once each. It is read a line at a time and, at end of file,
-- reopened from the start -- so an indefinite run wraps around the emitted iterations and says so in
-- the status log rather than stopping or pretending the iteration number is new.

brun = brun or {}

brun.dir      = brun.dir or '/usb1/SERDEC'
brun.planpath = brun.planpath or (brun.dir .. '/PLAN.CSV')
brun.stoppath = brun.stoppath or (brun.dir .. '/STOP.TXT')
brun.listenip   = brun.listenip or nil    -- optional host listener for live progress; nil = none
brun.listenport = brun.listenport or 5099

brun.pfh      = nil      -- plan handle while streaming
brun.nwrap    = 0        -- times the plan file has been re-read from the start
brun.ncell    = 0        -- cells attempted this run
brun.nbadsdg  = 0        -- consecutive generator failures
brun.stopwhy  = nil

-- HOW MANY GENERATOR FAILURES IN A ROW BEFORE PARKING. With nobody to power cycle the SDG, a wedged
-- generator means every remaining cell is stimulus-free -- and thousands of rows recording "no bytes"
-- against a dead wire would read, to anyone judging later, exactly like a decoder that had collapsed.
-- Better to stop with a reason on the key than to fill it with evidence for a false conclusion.
brun.maxsdgfail = brun.maxsdgfail or 20

-- ---------------------------------------------------------------------------
-- The plan file
-- ---------------------------------------------------------------------------
-- Split one CSV line on commas. No quoting is honoured, deliberately: soakplan.py emits plain numbers
-- and short ids, and a parser that pretends to handle quoting it never receives is a parser whose
-- failure mode nobody has seen.
function brun.split(s)
  local out, n, i0 = {}, 0, 1
  while true do
    local a = string.find(s, ',', i0, true)
    if a == nil then
      n = n + 1; out[n] = string.sub(s, i0)
      break
    end
    n = n + 1; out[n] = string.sub(s, i0, a - 1)
    i0 = a + 1
  end
  return out, n
end

function brun.planopen()
  brun.planclose()
  local fh = nil
  pcall(function() fh = file.open(brun.planpath, file.MODE_READ) end)
  if fh == nil then return false, 'cannot open ' .. brun.planpath end
  brun.pfh = fh
  return true
end

function brun.planclose()
  if brun.pfh == nil then return end
  pcall(function() file.close(brun.pfh) end)
  brun.pfh = nil
end

-- One cell, or nil at end of file. Header and blank lines are skipped here so callers never see them.
--
-- THE HANDLE IS CLOSED OUTSIDE THE pcall, matching usb_log.tsp's own note: a file.read that raises --
-- the key pulled mid-line -- must not leave the handle open, because the allocator then cannot reuse it.
function brun.nextrow()
  if brun.pfh == nil then return nil end
  local ln = nil
  local ok = pcall(function() ln = file.read(brun.pfh, file.READ_LINE) end)
  if not ok then brun.planclose(); return nil end
  if ln == nil or ln == '' then return nil end
  ln = string.gsub(ln, '[\r\n]', '')
  if ln == '' then return brun.nextrow() end
  if string.sub(ln, 1, 1) == '#' then return brun.nextrow() end
  local f, nf = brun.split(ln)
  -- iter,cell,vid,baud,kind,amp_vpp,ofst_v,srate,wait_ms -- nine fields. A row with fewer is a
  -- truncated or foreign file, and guessing at the missing ones would drive the generator from
  -- whatever happened to be in the next column.
  if nf < 9 then return brun.nextrow() end
  if tonumber(f[1]) == nil or tonumber(f[4]) == nil then return brun.nextrow() end
  return {iter = tonumber(f[1]), cell = tonumber(f[2]), vid = f[3], baud = tonumber(f[4]),
          kind = f[5], amp = tonumber(f[6]), ofst = tonumber(f[7]),
          srate = tonumber(f[8]), wait = tonumber(f[9])}
end

-- ---------------------------------------------------------------------------
-- One measurement
-- ---------------------------------------------------------------------------
-- MIRRORS bench_point() IN tools/bench_uart.py. Changing one without the other makes this soak
-- incomparable to every bench result on record; test_bench_engine.lua compares them.
function brun.point(fs, baud, lock)
  local r = {ran = false, why = nil}
  pcall(function() eventlog.clear() end)
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  if lock then sdec.force_baud = baud end
  sdec.fs = fs
  sdec.trigmode = sdec.trigmode or 'edge'

  local ok, why = false, nil
  local okc = pcall(function() ok, why = sdec.acquire() end)
  if not okc then r.why = 'acquire raised'; return r end
  if not ok then r.why = 'acq: ' .. tostring(why); return r end

  local okd, whyd = false, nil
  local okc2 = pcall(function() okd, whyd = sdec.decode() end)
  if not okc2 then r.why = 'decode raised'; return r end
  if not okd then
    r.why = 'dec: ' .. tostring(whyd)
    -- THE RETRACTED RATE IS STILL EVIDENCE. decode_from moves sdec.baud into sdec.baud_probe when it
    -- gives up, and 'no frame fits' with a measured bit time behind it is a different fact from a dead
    -- wire. Recording only the failure would throw that away.
    r.probe = sdec.baud_probe
    r.fs = sdec.acq_fs
    r.nread = sdec.nread
    r.nev = brun.eventcount()
    return r
  end

  local res = sdec.res
  r.ran     = true
  r.fs      = sdec.acq_fs
  r.nread   = sdec.nread
  r.baud    = sdec.baud
  r.snapped = sdec.snapped
  r.snapfirm = sdec.snapfirm
  r.nf      = (res ~= nil and res.nf) or 0
  r.ngood   = (res ~= nil and res.ngood) or 0
  r.nbad    = (res ~= nil and res.nbad) or 0
  r.headsusp = (res ~= nil and res.headsusp) or 0
  r.fmt     = brun.fmtname(res)
  r.nev     = brun.eventcount()
  r.hex     = brun.hex(res)
  r.nflag   = brun.flagcount(res)
  return r
end

-- EVENTS ARE A RESULT, not diagnostics. The app's hardest rule is that it must never put a message in
-- front of the operator, and a count of what it filed is the only way a soak can police that.
function brun.eventcount()
  local n = 0
  pcall(function() n = eventlog.getcount() or 0 end)
  return n
end

function brun.fmtname(res)
  if res == nil or res.nbits == nil then return '' end
  local p = 'N'
  if res.par == sdec.PAR_EVEN then p = 'E' elseif res.par == sdec.PAR_ODD then p = 'O' end
  return string.format('%d%s%d', res.nbits, p, res.nstop or 1)
end

function brun.flagcount(res)
  if res == nil or res.errs == nil then return 0 end
  local n, k = 0, nil
  for k = 1, (res.nf or 0) do
    if res.errs[k] ~= nil then n = n + 1 end
  end
  return n
end

-- '??' FOR A FLAGGED FRAME, and this is not cosmetic. bench_uart.py emits the same, with the reason:
-- a frame with an error still has a value, so printing that value lets a byte pass the host's substring
-- check only because the error was ignored. Writing plain hex here would silently weaken the judge --
-- which is a bug this project has already had, and fixed, in the offline twin.
function brun.hex(res)
  if res == nil or (res.nf or 0) < 1 then return '' end
  local s, k, n = {}, nil, 0
  for k = 1, res.nf do
    n = n + 1
    if res.errs[k] == nil then
      s[n] = string.format('%02X', res.vals[k] or 0)
    else
      s[n] = '??'
    end
  end
  return table.concat(s, '')
end

-- ---------------------------------------------------------------------------
-- Live progress, when someone is listening
-- ---------------------------------------------------------------------------
-- PUSHED, NOT POLLED, and that is forced rather than chosen: while a TSP script runs it holds the
-- interpreter, so the LAN command interface cannot answer a query about the run's progress. So the run
-- announces itself instead -- one short line per cell to a listener on the host -- wrapped so that the
-- listener being absent costs a failed connect and nothing else. That is the whole mechanism behind
-- "monitorable when connected, self-completing when not".
function brun.announce(s)
  if brun.listenip == nil then return end
  pcall(function()
    local id = tspnet.connect(brun.listenip, brun.listenport, nil)
    if id ~= nil then
      tspnet.write(id, s .. '\n')
      tspnet.disconnect(id)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Stopping on purpose
-- ---------------------------------------------------------------------------
-- A FILE, checked between cells, so a run can be ended cleanly by dropping STOP.TXT on the key without
-- a power cycle -- which matters when the alternative is losing the last unflushed rows.
function brun.stopped()
  local fh = nil
  pcall(function() fh = file.open(brun.stoppath, file.MODE_READ) end)
  if fh == nil then return false end
  pcall(function() file.close(fh) end)
  return true
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
function brun.soak(iterations, tag)
  if sdec == nil or sdec.acquire == nil then
    return false, 'the app is not loaded, so there is nothing to soak'
  end
  local forever = (iterations == nil or iterations == 0)
  brun.ncell, brun.nwrap, brun.nbadsdg, brun.stopwhy = 0, 0, 0, nil

  if not brec.begin(tag or 'soak', forever and 0 or iterations, brun.planpath) then
    return false, 'cannot record: ' .. tostring(brec.why)
  end
  if not brun.planopen() then
    brec.finish('no plan file at ' .. brun.planpath)
    return false, 'no plan file at ' .. brun.planpath
  end

  bsdg.reset()
  local live, idn = bsdg.alive()
  brec.note(0, 0, 0, 'start: sdg ' .. (live and tostring(idn) or ('UNREACHABLE ' .. tostring(idn))))
  brun.announce(string.format('START iterations=%s sdg=%s', tostring(iterations or 'forever'),
                              tostring(live)))

  local lastiter, nbadtot = nil, 0
  while true do
    local c = brun.nextrow()
    if c == nil then
      -- END OF PLAN. Wrap unless a finite iteration count says we are done.
      brun.nwrap = brun.nwrap + 1
      if not forever and lastiter ~= nil and lastiter >= iterations then
        brun.stopwhy = string.format('%d iteration(s) complete', iterations)
        break
      end
      brec.note(lastiter or -1, -1, 0, string.format('plan wrapped, pass %d', brun.nwrap + 1))
      if not brun.planopen() then
        brun.stopwhy = 'plan file will not reopen'
        break
      end
      c = brun.nextrow()
      if c == nil then brun.stopwhy = 'plan file is empty'; break end
    end
    if not forever and c.iter > iterations then
      brun.stopwhy = string.format('%d iteration(s) complete', iterations)
      break
    end
    lastiter = c.iter

    if brun.stopped() then brun.stopwhy = 'STOP.TXT found'; break end
    if brec.stopped then brun.stopwhy = 'recording stopped: ' .. tostring(brec.why); break end

    -- THE GENERATOR FIRST. A cell measured against the previous cell's waveform is worse than no cell
    -- at all: it is a wrong answer that looks like a right one, which is the failure mode the whole
    -- amplitude-index bug turned out to be.
    local sok, swhy = bsdg.select(c.vid, c.amp, c.ofst, c.srate)
    if not sok then
      brun.nbadsdg = brun.nbadsdg + 1
      brec.row(string.format('%d,%d,%s,%d,%s,%.4f,%.4f,%.6f,%.3f,,,,,,,,,,,,SDG:%s,',
                             c.iter, c.cell, brec.q(c.vid), c.baud, brec.q(c.kind),
                             c.amp or 0, c.ofst or 0, c.srate or 0, c.wait or 0, brec.q(swhy)))
      brec.note(c.iter, c.cell, brun.ncell, 'sdg failed: ' .. tostring(swhy), nbadtot, brun.nbadsdg)
      if brun.nbadsdg >= brun.maxsdgfail then
        brun.stopwhy = string.format('the generator failed %d cells in a row: %s',
                                     brun.nbadsdg, tostring(swhy))
        break
      end
      brun.ncell = brun.ncell + 1
      -- Nothing to measure, so do not spend a capture on it.
      -- luacheck: ignore
    else
      brun.nbadsdg = 0
      -- THE WAIT IS PART OF THE PLAN, not a settling delay: it moves the capture's phase within the
      -- looping arb, which is the variable that decides the answer on a periodic payload.
      if c.wait ~= nil and c.wait > 0 then delay(c.wait / 1000) end

      local fs = sdec.pick_fs(c.baud, 8)
      local p = brun.point(fs, c.baud, false)
      if not p.ran then nbadtot = nbadtot + 1 end
      brec.row(string.format('%d,%d,%s,%d,%s,%.4f,%.4f,%.6f,%.3f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s',
                             c.iter, c.cell, brec.q(c.vid), c.baud, brec.q(c.kind),
                             c.amp or 0, c.ofst or 0, c.srate or 0, c.wait or 0,
                             brun.fsnum(p.fs), brun.num(p.fs, c.baud),
                             p.ran and 'y' or 'n', tostring(p.baud or ''), brec.q(p.fmt),
                             tostring(p.nf or ''), tostring(p.ngood or ''), tostring(p.nbad or ''),
                             tostring(p.nflag or ''), tostring(p.headsusp or ''),
                             tostring(p.snapped), tostring(p.snapfirm),
                             brec.q(p.why)) .. ',' .. (p.hex or ''))
      brun.ncell = brun.ncell + 1
      -- ONE STATUS LINE PER CELL. At ~6 s a cell this is a trickle, and it is the file that answers
      -- "how far did it get" after a power cycle.
      brec.note(c.iter, c.cell, brun.ncell, p.ran and 'ok' or ('FAIL ' .. tostring(p.why)),
                nbadtot, 0)
      brun.announce(string.format('CELL %d/%d %s@%d %s nf=%s ev=%s', c.iter, c.cell,
                                  tostring(c.vid), c.baud, p.ran and 'ok' or 'FAIL',
                                  tostring(p.nf or 0), tostring(p.nev or 0)))
    end
  end

  brun.planclose()
  bsdg.output(false)
  bsdg.reset()
  brec.finish(brun.stopwhy or 'ended')
  brun.announce('END ' .. tostring(brun.stopwhy))
  return true, brun.stopwhy
end

-- samples per bit, for the row. Written as a helper because a division by a plan field that arrived
-- as text would otherwise raise inside string.format and lose the whole cell.
function brun.num(fs, baud)
  if fs == nil or baud == nil or baud <= 0 then return '' end
  return string.format('%.3f', fs / baud)
end

-- THE CAPTURE RATE, ROUNDED. tostring() on a float here writes 1000000.0000000001 -- seventeen digits
-- of noise over the one fact that matters. Three of the app's ladder rates are genuinely fractional
-- (66e6/413 is 159806.295), so it is not truncated to an integer either.
function brun.fsnum(fs)
  if fs == nil then return '' end
  return string.format('%.4f', fs)
end

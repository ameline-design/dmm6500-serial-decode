-- test_forcerate.lua -- a forced baud rate the wire does not carry must REFUSE and name the truth.
--
-- WHAT THIS GATES. A forced baud rate the wire contradicts must REFUSE, publish the rate the wire does
-- carry as an OFFER, and leave the choice to the operator. Substituting a detected rate and decoding
-- with it would put bytes on the panel at a rate nobody chose; a refusal with a reason is the contract.
--
-- NO HUMAN IN THE LOOP, BY CONSTRUCTION. The offer is plain state and the two answers are plain
-- functions, so both branches are driven here with ordinary calls -- no dialog, no event wait, nothing
-- that could hang an unattended lap. That is the property this file exists to keep: if answering ever
-- comes to require a display event, these tests stop compiling rather than quietly start hanging.
--
--   lua tools/test_forcerate.lua

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

local pass, fail, failed = 0, 0, {}
local function check(what, cond, detail)
  if cond then
    pass = pass + 1
    print('  ok   ' .. what)
  else
    fail = fail + 1
    failed[table.getn(failed) + 1] = what
    print('  FAIL ' .. what .. '   ' .. tostring(detail or ''))
  end
end

-- ---------------------------------------------------------------------------
-- A 9600 8N1 capture, decoded under a rate the wire does not carry.
--
-- 4800 IS HALF, WHICH IS THE CASE THE BENCH RUNS as force-half-rate, and it is the one that must not
-- pass by luck: a halved bit time frames twice as many "bytes" and every one of them is wrong, so a
-- gate that only looked at whether SOMETHING decoded would call this a success.
--
-- gap = 1 AND THAT IS NOT ARBITRARY. Swept 9600/19200/38400 against half and double, gaps 0-2 and
-- three sample rates: the refusal fires on 41 of those combinations but NOT on a 2-bit gap at half
-- rate, where a halved bit time tiles the frame plus its gap so cleanly that the interior-bad
-- fraction is 0.074 -- under the 0.25 the relock demands. The app is right to keep quiet there: it
-- has a warning but no proof. Written with gap = 2 first, this whole file passed while testing
-- nothing, which is why the offer assertions below double as the reached-the-branch guard.
local FS, BAUD = 100000, 9600
local function fresh(force)
  local by, nb = {}, 0
  local s = 'The quick brown fox jumps over the lazy dog. 0123456789. '
  local i
  for i = 1, string.len(s) do nb = nb + 1; by[nb] = string.byte(s, i) end
  local rd, ts, nc, ns = GEN({bytes = by, nbits = 8, par = 0, baud = BAUD, fs = FS,
                              gap = 1, lead = 6, tail = 6, loop = false})
  sdec.force_nbits, sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil, nil
  sdec.proto, sdec.ui_mode = 'uart', 'text'
  sdec.relocked, sdec.rate_offer, sdec.rate_offer_from, sdec.rate_refused = nil, nil, nil, nil
  sdec.force_baud = force
  sdec.acq_fs = FS
  sdec.smp, sdec.nread = rd, ns
  sdec.sig_levels(rd, ns)
  sdec.sig_edges(rd, ns)
  sdec.sig_idle(rd, ns)
  return rd, ns
end

print('\n-- a forced rate the wire does not carry: refuse, and name what it does carry --')
sdec.force_conflict = 'ask'
fresh(4800)
local ok, why = sdec.decode()
check('the decode is REFUSED rather than answered', ok == false, 'ok=' .. tostring(ok))
-- THE REASON MUST CARRY BOTH NUMBERS. "It did not decode" is useless to the operator; the whole value
-- of refusing here is that the app already knows the answer and can hand it over.
check('the reason names the forced rate and the detected one',
      ok == false and why ~= nil and string.find(why, '4800', 1, true) ~= nil
      and string.find(why, '9600', 1, true) ~= nil, tostring(why))
-- NO BYTES. res still held the decode that PROVED the rate wrong -- correct bytes at a rate we are
-- declining -- and leaving them up would be adopting by another route.
check('no result is presented, so the panel shows no bytes', sdec.res == nil,
      'res=' .. tostring(sdec.res))
check('the detected rate is offered', sdec.rate_offer == 9600, tostring(sdec.rate_offer))
check('the offer records the rate it displaces', sdec.rate_offer_from == 4800,
      tostring(sdec.rate_offer_from))
-- THE OPERATOR'S SETTING IS STILL THEIRS. Refusing must not edit it behind them; that was the whole
-- objection to adopting.
check('the forced rate is left exactly as the operator set it', sdec.force_baud == 4800,
      tostring(sdec.force_baud))
check('the note row states the refusal and names a control that exists',
      sdec.rate_refused ~= nil and string.find(sdec.rate_refused, 'Options > Baud 0', 1, true) ~= nil,
      tostring(sdec.rate_refused))
-- THE NOTE ROW MUST ACTUALLY CARRY IT, not merely have the string available: ui_notes ranks seventeen
-- sources and an unranked one is invisible. Tested through the app's own builder, not by reading state.
local notes = sdec.ui_notes()
local onrow = false
if notes ~= nil then
  local i
  for i = 1, table.getn(notes) do
    if string.find(tostring(notes[i]), '9600', 1, true) ~= nil then onrow = true end
  end
end
check('ui_notes() carries the refusal, so it reaches the panel', onrow,
      'notes=' .. tostring(notes and table.concat(notes, ' | ')))

print('\n-- Use Detected Rate --')
-- capture() is stubbed because this is the OFFLINE suite: there is no instrument to re-acquire from, so
-- what is checked here is the CONTRACT -- the lock is already gone by the time capture is called, and it
-- is called exactly once. It deliberately does NOT prove the re-capture then decodes at the offered
-- rate; a stub that always succeeds cannot. That half is gated on hardware by bench_break's
-- accept-detected-rate, which requires the offer retired AND sdec.baud within 1 % of the rate offered.
--
-- ORDER IS PART OF THE CONTRACT: capture() must not run with the wrong rate still forced, or the
-- re-capture repeats the refusal. The stub asserts that, which the call count alone cannot.
local realcap, ncap, lockatcap = sdec.capture, 0, 'unset'
sdec.capture = function()
  ncap = ncap + 1
  lockatcap = tostring(sdec.force_baud)
  return true, 'stubbed'
end
local aok, awhy = sdec.rate_accept()
sdec.capture = realcap
check('accept returns the re-capture verdict', aok == true, tostring(awhy))
check('accept clears the lock, so detection runs again', sdec.force_baud == nil,
      tostring(sdec.force_baud))
check('accept re-captures exactly once', ncap == 1, tostring(ncap))
check('...and the lock was already cleared when it re-captured', lockatcap == 'nil', lockatcap)
check('accept retires the offer', sdec.rate_offer == nil and sdec.rate_refused == nil,
      tostring(sdec.rate_offer))

print('\n-- Cancel --')
fresh(4800)
sdec.decode()
local dok, dwhy = sdec.rate_decline()
check('decline succeeds and hands back the reason', dok == true and dwhy ~= nil, tostring(dwhy))
check('decline KEEPS the operator rate', sdec.force_baud == 4800, tostring(sdec.force_baud))
check('decline retires the question', sdec.rate_offer == nil, tostring(sdec.rate_offer))
-- THE REFUSAL SURVIVES THE ANSWER. An empty dump under a locked rate looks like a dead wire, so the
-- sentence explaining it must not vanish just because the question was dismissed.
check('decline leaves the refusal on the note row', sdec.rate_refused ~= nil,
      tostring(sdec.rate_refused))

print('\n-- a Mode press retires the offer, because it discards the capture --')
-- capture() clears the offer once per press, and Mode is the other way out of a result: both its
-- branches discard one. An offer that survived would let accept drop the operator's
-- lock on the strength of a capture that no longer exists -- and into a streaming mode, which needs a
-- lock and would refuse immediately after.
fresh(4800)
sdec.decode()
local hadoffer = (sdec.rate_offer ~= nil)
sdec.mode_cycle()
check('the offer was raised, so this case is not vacuous', hadoffer, 'no offer to retire')
check('Mode retires the offer', sdec.rate_offer == nil, tostring(sdec.rate_offer))
local mok, mwhy = sdec.rate_accept()
check('...so accept can no longer act on it', mok == false and mwhy == 'no rate was offered',
      tostring(mwhy))

print('\n-- answering nothing --')
-- A stale press or a repeated remote call must not act on an offer already answered.
local nok, nwhy = sdec.rate_accept()
check('accept with no offer refuses politely', nok == false and nwhy == 'no rate was offered',
      tostring(nwhy))
nok, nwhy = sdec.rate_decline()
check('decline with no offer refuses politely', nok == false and nwhy == 'no rate was offered',
      tostring(nwhy))

print('\n-- a CORRECT forced rate is untouched --')
-- THE GATE THAT KEEPS THIS HONEST. If refusal fired on a right rate the app would be unusable, and a
-- suite that only tested the wrong rate could not tell.
fresh(9600)
local gok = sdec.decode()
check('a correct forced rate decodes', gok == true and sdec.res ~= nil, tostring(gok))
check('and raises no offer', sdec.rate_offer == nil, tostring(sdec.rate_offer))
check('and keeps the lock', sdec.force_baud == 9600, tostring(sdec.force_baud))

print('\n-- force_conflict = adopt restores the older behaviour --')
-- KEPT REACHABLE ON PURPOSE, so the change is one setting rather than a code edit, and so the bench can
-- prove both policies on the same capture.
sdec.force_conflict = 'adopt'
fresh(4800)
local pok = sdec.decode()
check('adopt decodes instead of refusing', pok == true and sdec.res ~= nil, tostring(pok))
check('adopt clears the lock', sdec.force_baud == nil, tostring(sdec.force_baud))
check('adopt says so on the note row', sdec.relocked ~= nil, tostring(sdec.relocked))
check('adopt raises no offer', sdec.rate_offer == nil, tostring(sdec.rate_offer))
sdec.force_conflict = 'ask'

print(string.format('\n%d passed, %d failed', pass, fail))
if fail > 0 then
  local i
  for i = 1, table.getn(failed) do print('  - ' .. failed[i]) end
  os.exit(1)
end

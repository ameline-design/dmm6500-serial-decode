-- verify_tspa.lua -- check the SHIPPED .tspa, not the sources it is built from.
--
-- tools/test_serial.lua loads tsp/*.tsp module by module. That is not what the
-- instrument does: opening an App runs one concatenated chunk, so anything that only
-- breaks when the modules are joined -- a duplicated local at file scope, a module
-- depending on load order, a stray `endscript` inside a string -- is invisible to the
-- unit tests and fatal on the panel, where the failure costs a power cycle.
--
-- So this extracts the body between `loadscript` and `endscript`, runs it as ONE chunk
-- against the hostile display mock and a deliberately DEAD digitizer, and checks that
-- the entry point survives it. A dead front end is the realistic worst case for a fresh
-- launch, and the app has to come up saying so rather than not coming up.
--
-- Run from the repo root:  lua tools/verify_tspa.lua [path.tspa]

local PATH = (arg and arg[1]) or 'Serial_Decode.tspa'

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (detail and ('   ' .. detail) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (detail and ('   ' .. detail) or ''))
  end
end

-- ---------- read and split the archive ----------
local fh = io.open(PATH, 'rb')
if fh == nil then print('cannot open ' .. PATH); os.exit(1) end
local text = fh:read('*a')
fh:close()

local body, nbody = {}, 0
local manifest = {}
local b64, nb64 = {}, 0
local state = 'pre'
local sname, iname = nil, nil
for line in string.gmatch(text, '([^\r\n]*)\r?\n') do
  if state == 'pre' then
    local s = string.match(line, '^loadscript%s+(%S+)')
    if s ~= nil then sname = s; state = 'script' end
  elseif state == 'script' then
    if line == 'endscript' then
      state = 'mid'
    else
      local k, v = string.match(line, '^%-%-%s+%$(%w+):%s*(.*)$')
      if k ~= nil then
        manifest[k] = v
      else
        nbody = nbody + 1
        body[nbody] = line
      end
    end
  elseif state == 'mid' then
    local i = string.match(line, '^loadimage%s+(%S+)')
    if i ~= nil then iname = i; state = 'image' end
  elseif state == 'image' then
    if line == 'endimage' then
      state = 'done'
    else
      nb64 = nb64 + 1
      b64[nb64] = line
    end
  end
end

print('archive structure')
check('the file is ' .. PATH, text ~= nil and string.len(text) > 1000,
      string.len(text) .. ' bytes')
check('loadscript / endscript found', sname ~= nil and nbody > 100,
      tostring(sname) .. ', ' .. nbody .. ' lines of body')
check('loadimage / endimage found and closed', iname ~= nil and state == 'done',
      tostring(iname) .. ', ' .. nb64 .. ' base64 lines')
check('the manifest names the icon that loadimage defines', manifest.Icon == iname,
      '$Icon=' .. tostring(manifest.Icon) .. ' loadimage=' .. tostring(iname))
-- $Product: IS A LIST, so this is a per-token whitelist and not an equality. An equality on
-- 'DMM6500' fails the moment a second model is declared, and a bare not-nil would let a typo like
-- DMM7150 ship -- where the symptom is an app that installs on NOTHING, discovered on a bench with a
-- USB key in hand.
--
-- THE SET HERE IS NARROWER THAN THE ONE THE SPEC PERMITS, deliberately. Keithley's app-header spec
-- allows 2450, 2460, 2461, 2470, DMM6500 and DAQ6510. Every SMU in that list is rejected here because
-- they reach their measurement subsystem as smu.*, not dmm.*, so the app would install on one and fail
-- at the first capture -- and $Product: means "can run the script without errors", which makes listing
-- one a false claim rather than an untested one. Rejecting them turns that into a gate failure instead
-- of a support question.
--
-- NOT because the SMUs lack digitizers, which was the first answer here and was wrong: the 2461 has
-- dual 18-bit 1 MS/s digitizers, while the 2470 manual denies the feature and the 2450 reference shows
-- none. The series splits and the family spec sheet prints the 2461's number as a family capability.
-- So 2461 is the one to allow WHEN the smu.* port lands, and it stays rejected until then.
--
-- DMM7510 is included although the published list omits it; Keithley ship apps of their own
-- declaring it.
--
-- DMM6500 MUST BE PRESENT. It is the only model the app is tested on, so a build that dropped it
-- would leave every measured claim in docs/ describing an instrument the package does not target.
local PRODUCT_OK = {['DMM6500'] = true, ['DAQ6510'] = true, ['DMM7510'] = true}
local prodn, prodbad, prodtested = 0, '', false
if manifest.Product ~= nil then
  -- The loop variable is CONST under the host's Lua 5.5, so the trim goes to a fresh local.
  for raw in string.gmatch(manifest.Product, '[^,%s][^,]*') do
    local tok = string.gsub(raw, '%s+$', '')
    prodn = prodn + 1
    if not PRODUCT_OK[tok] then prodbad = prodbad .. ' ' .. tok end
    if tok == 'DMM6500' then prodtested = true end
  end
end
check('the manifest carries a title, a version and only known products',
      manifest.Title ~= nil and manifest.Version ~= nil
        and prodn > 0 and prodbad == '' and prodtested,
      tostring(manifest.Title) .. ' / ' .. tostring(manifest.Product)
        .. ' / ' .. prodn .. ' model(s)'
        .. (prodbad == '' and '' or ('  UNKNOWN:' .. prodbad))
        .. (prodtested and '' or '  MISSING DMM6500'))
-- A stray 'endscript' or 'endimage' inside the TSP would truncate the archive silently.
local stray = 0
local i
for i = 1, nbody do
  if body[i] == 'endscript' or body[i] == 'endimage' then stray = stray + 1 end
end
check('no line of TSP would be mistaken for an archive delimiter', stray == 0,
      stray .. ' stray delimiters')

-- ---------- run the body as one chunk ----------
dofile('tools/mock_display.lua')
math.mod = math.mod or math.fmod
table.getn = table.getn or function(t) return #t end

local nbuf = 0
buffer = {STYLE_STANDARD = 'std', STYLE_WRITABLE_FULL = 'wf', UNIT_VOLT = 'V'}
function buffer.make()
  nbuf = nbuf + 1
  return {alive = true, n = 0, readings = {}, relativetimestamps = {},
          clear = function() end}
end
function buffer.delete() nbuf = nbuf - 1 end

-- A DEAD front end: the digitizer returns nothing at all. This is what probing an
-- unpowered board looks like, and it is the likeliest thing on a fresh launch.
dmm = {FUNC_DIGITIZE_VOLTAGE = 'digv', MODE_EDGE = 'edge', MODE_WINDOW = 'window',
       MODE_OFF = 'off', SLOPE_RISING = 'rise', SLOPE_FALLING = 'fall',
       digitize = {analogtrigger = {edge = {}}}}
function dmm.digitize.read(b) b.n = 0 end
trigger = {EVENT_ANALOGTRIGGER = 'atrig', CLEAR_ENTER = 'enter',
           CLEAR_NEVER = 'never', model = {}}
function trigger.model.load() end
function trigger.model.initiate() end
function trigger.model.abort() end
function waitcomplete() end
function delay() end

local src = table.concat(body, '\n')
local chunk, err = (loadstring or load)(src, 'tspa')
print('\nthe concatenated body')
check('compiles as ONE chunk', chunk ~= nil, tostring(err))
if chunk == nil then
  print(string.format('\n%d passed, %d failed', pass, fail))
  os.exit(1)
end

local ok, perr = pcall(chunk)
check('runs to completion, entry point included', ok, tostring(perr))
check('no sig_/ua_/acq_/mi_ helper escaped to a global',
      (function()
         local extra, k = {}, nil
         for k in pairs(_G) do
           if type(k) == 'string' and (string.find(k, '^sig_') or string.find(k, '^ua_')
              or string.find(k, '^acq_') or string.find(k, '^mi_')) then
             extra[table.getn(extra) + 1] = k
           end
         end
         return table.getn(extra) == 0 end)())

print('\nlaunch against a dead front end')
-- Report sdec.lasterr, not just the count. start() catches its own failures and tears
-- its objects back down, so a build that raised presents here as "0 screens" with the
-- reason sitting unread in sdec.lasterr -- which is a diagnosis withheld by the very
-- harness whose job is to give one.
check('both screens were built', MD.live('screen') == 2,
      MD.live('screen') .. ' screens, ' .. MD.live() .. ' objects'
      .. (sdec.lasterr and ('  lasterr: ' .. tostring(sdec.lasterr)) or ''))
check('the screen title is the app title, under the 31-char limit',
      MD.obj(sdec.ui_scr).title ~= nil
      and string.len(MD.obj(sdec.ui_scr).title) <= 31,
      tostring(MD.obj(sdec.ui_scr).title))
check('the app is alive and reports the failure rather than dying',
      sdec.ui_status ~= nil and sdec.ui_status ~= 'ready',
      'status=' .. tostring(sdec.ui_status))
check('the note line explains what went wrong',
      MD.text(sdec.ui_note) ~= nil and string.len(MD.text(sdec.ui_note)) > 0,
      tostring(MD.text(sdec.ui_note)))
check('no stale measurement is shown for a capture that failed',
      sdec.res == nil and sdec.baud == nil,
      'res=' .. tostring(sdec.res) .. ' baud=' .. tostring(sdec.baud))
check('End App is hooked on the main screen',
      MD.events(sdec.ui_scr) ~= nil and MD.events(sdec.ui_scr)['endapp'] ~= nil)
check('and on the options screen too',
      MD.events(sdec.optscr) ~= nil and MD.events(sdec.optscr)['endapp'] ~= nil)

-- Every button's event string must be a callable that exists, or the panel gets a
-- button that does nothing and says nothing.
local nbtn, bad = 0, {}
for i = 1, table.getn(sdec.ui_btn) do
  local ev = MD.events(sdec.ui_btn[i])
  local cmd = ev and ev['press']
  if cmd == nil then
    bad[table.getn(bad) + 1] = 'button ' .. i .. ' has no handler'
  else
    nbtn = nbtn + 1
    local f = (loadstring or load)('return ' .. string.gsub(cmd, '%(%)$', ''))
    local okf, fn = pcall(f)
    if not okf or type(fn) ~= 'function' then
      bad[table.getn(bad) + 1] = cmd
    end
  end
end
-- The COUNT is pinned as well as the handlers, deliberately: the bar spans x = 8..774 of a
-- 798 px limit, so an eighth button does not fit and adding one must fail here rather than be
-- discovered as an object display.create() silently refused.
--
-- NINE: Capture, View, Mode, NewLog, Save, Options along the bottom bar, plus Page Up,
-- Lock Rate and Page Dn down the dump area's RIGHT MARGIN. Lock Rate is there because the
-- padlock GLYPH cannot be pressed -- EVENT_PRESS on an OBJ_RECT is refused (1717) -- so the
-- most useful action on the panel had no control on the main screen at all -- which is why the count could rise past the bar's
-- capacity. The comment above still holds for the bar itself: it spans x = 8..774 of a 798 px
-- limit and a seventh button on that row would not fit.
--
-- The two page buttons sit right-aligned at 785 and carry the only paging control there is: a hex
-- page holds 240 bytes, the whole frame in FRAME mode, but a 32 kB streaming capture is 137 pages.
-- Labelled 'Up' and 'Dn' on 56 px faces -- the width they do not use is width the dump rows get.
-- They hide themselves when the capture fits one page (sdec.ui_page_btns).
check('every main-screen button calls a function that exists',
      table.getn(bad) == 0 and nbtn == 9,
      nbtn .. ' buttons; bad: ' .. table.concat(bad, ' '))
local obad = {}
for i = 1, table.getn(sdec.opt_btn) do
  local ev = MD.events(sdec.opt_btn[i])
  local cmd = ev and ev['press']
  local f = cmd and (loadstring or load)('return ' .. string.gsub(cmd, '%(%)$', ''))
  local okf, fn = false, nil
  if f ~= nil then okf, fn = pcall(f) end
  if not okf or type(fn) ~= 'function' then
    obad[table.getn(obad) + 1] = tostring(cmd)
  end
end
-- Four now: Auto Detect, Lock Detected, Apply, Cancel. Auto Detect went into the empty left
-- half of the row, opposite its inverse.
check('every options-form button calls a function that exists',
      table.getn(obad) == 0 and table.getn(sdec.opt_btn) == 4,
      table.getn(sdec.opt_btn) .. ' buttons; bad: ' .. table.concat(obad, ' '))

print('\nEnd App teardown')
local ev = MD.events(sdec.ui_scr)['endapp']
;(loadstring or load)(ev)()
check('every display object is freed', MD.live() == 0, 'live=' .. MD.live())
check('every buffer is freed', nbuf == 0, 'buffers=' .. nbuf)
check('nothing relied on the parent cascade', (select(1, MD.cascaded())) == 0,
      select(2, MD.cascaded()))
check('no deletion was refused', sdec.delfails == 0,
      'delfails=' .. tostring(sdec.delfails))
check('no fill was refused', sdec.fillfails == 0,
      'fillfails=' .. tostring(sdec.fillfails))

print()
-- ===========================================================================
-- A POOL THAT RAN OUT MUST REFUSE, NOT SHOW A SCREEN WITH NO BUTTONS
-- ===========================================================================
-- Measured on the instrument: display.create returns NIL once the display object pool is exhausted,
-- posts nothing (1701 is logged the first time only), and does not raise. So start()'s pcall reports
-- success, `built` is set, and the panel shows a screen with no buttons and nothing saying why --
-- every child created against a nil parent.
sdec.stop()
sdec.built = false
sdec.delfails = 0

-- Nothing at all: the root screen itself cannot be created.
MD.poolcap(0)
local pok, pwhy = sdec.start()
check('a launch with no display objects left REFUSES rather than half-building',
      pok == false, tostring(pok))
check('and says the pool is exhausted, naming the remedy',
      pwhy ~= nil and string.find(tostring(pwhy), 'pool exhausted') ~= nil and
      string.find(tostring(pwhy), 'ower cycle') ~= nil, tostring(pwhy))
check('and does NOT claim to be built afterwards', sdec.built == false,
      tostring(sdec.built))
check('and the reason reached the USB log, the only place it can be read',
      string.find(MD.logtext(), 'start failed') ~= nil)

-- Enough for the screen and the rules, not enough for the buttons: the partial case, which the
-- screen check alone would let through.
MD.poolcap(nil)
sdec.stop()
sdec.built = false
sdec.delfails = 0
local nbefore = MD.nobj()
MD.poolcap(nbefore + 40)
local qok, qwhy = sdec.start()
MD.poolcap(nil)
check('a pool that runs out PART WAY through refuses too', qok == false, tostring(qok))
check('and counts the buttons it could not make',
      qwhy ~= nil and string.find(tostring(qwhy), 'buttons could be created') ~= nil,
      tostring(qwhy))
check('and still does not claim to be built', sdec.built == false, tostring(sdec.built))

-- SWEEP THE WHOLE LANDING BAND, not just two points either side of it.
--
-- The two caps above die long before the button row. The interesting band is the one where the
-- pool has room for the main screen but not for all of the buttons or the options form -- about
-- fifteen objects wide out of ~133 -- and in it a PARTIAL button row is built. That matters
-- because sdec.ui_btn is POSITIONAL: the three right-margin buttons go to [7..9] before the bottom
-- row fills [1..6], so a partial bottom row leaves a hole, and table.getn stops at a hole. A
-- teardown walking ui_btn therefore never reached 7, 8 or 9, and nil'ing the table dropped the
-- last reference to three live firmware objects -- collected only by the parent cascade, which
-- this app never relies on.
--
-- So the assertion at every cap in the band is the same one the whole file exists for: refuse,
-- say why, and leave NOTHING behind.
do
  MD.poolcap(nil)
  sdec.stop()
  sdec.built = false
  sdec.delfails = 0
  local full = MD.nobj()
  local worst, nbad = nil, 0
  local slack
  for slack = 1, 20 do
    MD.poolcap(nil)
    sdec.stop()
    sdec.built = false
    sdec.delfails = 0
    -- OBJ accumulates across iterations, so the cascade count is a DELTA rather than a total --
    -- as a total, every later cap inherits the earlier ones' verdict.
    local casc0 = MD.cascaded()
    MD.poolcap(full - slack)
    local bok, bwhy = sdec.start()
    MD.poolcap(nil)
    pcall(function() sdec.stop() end)
    local leftover = MD.live()
    local casc = MD.cascaded() - casc0
    if bok ~= false or leftover ~= 0 or casc ~= 0 then
      nbad = nbad + 1
      if worst == nil then
        worst = string.format('cap %d (full - %d): ok=%s live=%d cascaded=%d why=%s',
                              full - slack, slack, tostring(bok), leftover, casc,
                              tostring(bwhy))
      end
    end
  end
  check('every pool size in the partial-build band refuses and leaves nothing undeleted',
        nbad == 0, nbad == 0 and '20 caps clear' or worst)
  MD.poolcap(nil)
  sdec.stop()
  sdec.built = false
  sdec.delfails = 0
end

-- And a normal launch is unaffected by any of it.
sdec.stop()
sdec.built = false
sdec.delfails = 0
local rok, rwhy = sdec.start()
check('with objects available the app builds normally again', rok == true, tostring(rwhy))
check('and it has all nine buttons again',
      sdec.ui_btn ~= nil and table.getn(sdec.ui_btn) == 9,
      tostring(sdec.ui_btn and table.getn(sdec.ui_btn)))

print(string.format('%d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end

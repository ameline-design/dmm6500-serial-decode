-- lin_decode.tsp -- LIN (Local Interconnect Network, ISO 17987) frame layer for the
-- DMM6500 serial decoder (TSP / Lua 5.0.2).
--
-- NOT SHIPPED IN V1: tools/package_tspa.py MODULES omits this module, so the Options form offers
-- no LIN and the View button never reaches the frame list.
--
-- THE CHECKSUM HAS NEVER BEEN CHECKED AGAINST A REAL FRAME -- hand-computed cases only
-- (notes/COVERAGE-session17.md). Shipping this module ships an unverified decode.
--
-- Works entirely on the BYTE STREAM that uart_decode.tsp already produced. LIN is
-- ordinary 8N1 underneath -- no parity, one stop bit, idle recessive (high) -- so
-- selecting LIN on the options form forces 8N1 and normal polarity and leaves the
-- BAUD RATE to the auto-detector, because LIN does not specify one: 1 to 20 kBd, in
-- practice 9600 or 19200. That is the one difference from MIDI, which is 31250 by
-- specification and so can be forced outright.
--
-- WIRING: LIN is a 12 V single-wire bus, and this instrument's best digitize range is
-- 10 V (see sdec.range). So it needs a 2:1 DIVIDER -- 47 k + 47 k, nothing below
-- 20 k per leg or the pull-up of a slave-only segment reads recessive as dominant.
-- docs/lin-divider-panel.png is the drawing. sdec.li_levelnote() below says so on the
-- panel when the measured levels look like an undivided bus, because "no decode" with
-- no explanation is the failure mode that wastes an afternoon.
--
-- THE FRAME, which is what this module adds:
--
--   BREAK      >= 13 dominant bits from a master, >= 11 accepted by a slave. Longer
--              than any byte can be, which is the whole point -- 8N1 can hold at most
--              9 consecutive dominant bits (start + eight zero data bits).
--   DELIMITER  >= 1 recessive bit.
--   SYNC       0x55 exactly. Alternates every cell, so a slave measures the bit rate
--              across it; here it serves as a CHECK on the bit rate already measured.
--   PID        6-bit frame ID plus two parity bits (sdec.li_pid).
--   DATA       1..8 bytes.
--   CHECKSUM   inverted sum with carry, over the data (classic, LIN 1.x and
--              diagnostic frames) or over the PID and the data (enhanced, LIN 2.x).
--
-- The frame LENGTH is not on the wire. A passive analyser recovers it by counting the
-- bytes between one break and the next and taking the last as the checksum, which is
-- what this does. (LIN 1.3 also had a length convention in ID bits 5:4 -- 2, 4 or 8
-- bytes. LIN 2.x dropped it, so reporting a disagreement would fire on most of a
-- modern bus and say nothing. Deliberately not implemented.)
--
-- THE BREAK ARRIVES AS A FRAMING ERROR, and that is expected rather than a fault: the
-- UART layer reads the break's first ten cells as 0x00 with the stop bit still
-- dominant. So a healthy LIN capture shows one framing error per frame, the header ERR
-- field goes red, and the note line has to explain it -- see sdec.li_breaknote().
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.LI_SYNC = 0x55

-- Bit times from the break's start edge to the next byte's. A break plus its delimiter is
-- at least 12; a byte butted against the next is 10, so 11 separates them either way.
--
-- CORROBORATION, not an independent test -- li_break() also requires value 0x00 and a
-- failed stop bit, which no ordinary 0x00 has. What survives all three is a 0x00 whose stop
-- bit noise flipped, inside a stream with 2+ bit times of inter-byte space. That splits one
-- frame in two and both halves then fail their checksum: loud, not silent.
sdec.li_minbreak = 11

-- The four reserved frame IDs. 0x3C and 0x3D carry diagnostics and are the reason the
-- checksum style cannot simply be assumed: the specification requires the CLASSIC
-- checksum on both, whatever the rest of the bus uses.
sdec.li_name = {}
sdec.li_name[0x3C] = 'MasterReq'
sdec.li_name[0x3D] = 'SlaveResp'
sdec.li_name[0x3E] = 'user-def'
sdec.li_name[0x3F] = 'reserved'

-- sdec.lin -- {n, msg[], kind[], bad, nframes, nbreak, nenh, ncls, ndiag, nids}.
-- Declared, not assigned: see serial_core.tsp on why a reload must not clobber it.

-- ============================================================================
-- Protected identifier
-- ============================================================================
-- Bit k of v. No bitwise operators in 5.0.2, so this is the divide-and-mod form.
function sdec.li_bit(v, k)
  return math.mod(math.floor(v / (2 ^ k)), 2)
end

-- The PID for a 6-bit frame ID: the ID in bits 0..5, then
--   P0 = ID0 xor ID1 xor ID2 xor ID4        (even parity)
--   P1 = not (ID1 xor ID3 xor ID4 xor ID5)  (odd parity)
--
-- Checked against the two PIDs everyone knows: ID 0x3C gives PID 0x3C and ID 0x3D
-- gives PID 0x7D, which are the master-request and slave-response headers on every
-- LIN bus. ID 0x00 gives 0x80 and ID 0x01 gives 0xC1.
function sdec.li_pid(id)
  local b = sdec.li_bit
  local i = math.mod(id, 64)
  local p0 = math.mod(b(i, 0) + b(i, 1) + b(i, 2) + b(i, 4), 2)
  local p1 = 1 - math.mod(b(i, 1) + b(i, 3) + b(i, 4) + b(i, 5), 2)
  return i + 64 * p0 + 128 * p1
end

-- Returns ok, id. Both are wanted even when the parity fails: a frame with a corrupt
-- PID is still worth showing, and its low six bits are still the best guess at the ID.
function sdec.li_pid_ok(pid)
  if pid == nil then return false, nil end
  local id = math.mod(pid, 64)
  return sdec.li_pid(id) == pid, id
end

-- ============================================================================
-- Checksum
-- ============================================================================
-- The inverted eight-bit sum with the CARRY ADDED BACK -- modulo-255, not modulo-256. Pass
-- pid for the enhanced checksum (LIN 2.x), nil for the classic one (LIN 1.x, and diagnostic
-- frames at any version). NEVER CHECKED AGAINST A REAL FRAME: hand-computed cases only.
--
-- sum stays <= 255 before every add and a byte is <= 255, so one subtraction restores the
-- invariant; 255 - sum is the one's complement of a value in 0..255, which is what
-- "inverted" means and needs no bitwise operator. The receiver-side property worth
-- remembering: summing the data AND the received checksum this way gives 255.
--
-- ITS BLIND SPOT, which callers must respect: modulo-255 makes 0xFF congruent to 0x00, so
-- swapping one for the other is INVISIBLE in every byte position -- measured, 0 of 256
-- detected across all 64 IDs and 4 positions. With PID 0x11, data 0xFF and data 0x00 both
-- give checksum 0xEE. A checksum that agrees is therefore not proof that a byte the UART
-- layer flagged came through intact, and li_parse() below does not treat it as proof.
function sdec.li_csum(vals, i0, n, pid)
  local sum = 0
  if pid ~= nil then sum = math.mod(pid, 256) end
  local i
  for i = i0, i0 + n - 1 do
    local v = vals[i]
    if v == nil then return nil end
    -- Masked because a 9-bit width would hand this values above 255. LIN forces 8
    -- data bits, so this only matters when the LIN view is opened on a capture that
    -- was decoded some other way.
    sum = sum + math.mod(v, 256)
    if sum > 255 then sum = sum - 255 end
  end
  return 255 - sum
end

-- ============================================================================
-- Break detection
-- ============================================================================
-- Bit times from byte i's start edge to the next byte's start edge, or to the end of
-- the capture for the last byte. nil when the timing is not available -- a hand-built
-- result, or a decode that produced no bit time.
function sdec.li_gapbits(r, i)
  local T = sdec.bittime
  if T == nil or T <= 0 or r == nil or r.tpos == nil then return nil end
  local a = r.tpos[i]
  if a == nil then return nil end
  local b = r.tpos[i + 1]
  if b == nil then
    b = sdec.nread
    if b == nil or b < 1 then return nil end
  end
  return (b - a) / T
end

-- Is byte i the break field? Value 0, a flagged stop or parity bit, and a dominant period longer
-- than any BYTE can be (sdec.li_minbreak bit times) -- not longer than a frame, which is ~34 bit
-- times header-only and ~124 with eight data bytes.
function sdec.li_break(r, i)
  if r == nil or r.vals == nil then return false end
  if r.vals[i] ~= 0 then return false end
  if r.errs == nil or r.errs[i] == nil then return false end
  local g = sdec.li_gapbits(r, i)
  if g == nil then return true end       -- no timing: the value and the error alone
  return g >= sdec.li_minbreak
end

-- ============================================================================
-- Parse the byte stream into frames
-- ============================================================================
-- Returns ok, reason. Fills sdec.lin.
--
-- kind[] is 'frame', 'err' or 'note', so the UI can colour a row without re-parsing
-- it. A frame whose checksum or PID parity failed is 'err' and carries the detail on
-- its OWN line rather than in a second one: one frame to one row keeps the list
-- scannable, and the row colour is what raises the alarm.
function sdec.li_parse()
  local r = sdec.res
  sdec.lin = {n = 0, msg = {}, kind = {}, bad = 0, nframes = 0, nbreak = 0,
              nenh = 0, ncls = 0, ndiag = 0, nids = 0}
  if r == nil or r.nf == 0 then return false, 'no bytes to parse' end
  local L = sdec.lin
  local seenid = {}

  local function emit(kind, text)
    local k = L.n + 1
    L.n = k
    L.kind[k] = kind
    L.msg[k] = text
    if kind == 'err' then L.bad = L.bad + 1 end
  end

  local function hex(v)
    if v == nil then return '--' end
    return string.format('%02X', math.mod(v, 256))
  end

  local st = 'pre'                 -- 'pre', 'sync', 'pid', 'resp'
  local pid, id = nil, nil
  local d0, nd = nil, 0            -- response bytes: first index, count
  local npre, presaid = 0, false

  -- Close whatever is open. Every exit from a frame goes through here, so a frame
  -- ended by the next break and one ended by the capture running out produce the
  -- same line.
  local function finish()
    if st == 'sync' then
      emit('note', '-- break with no sync byte after it')
    elseif st == 'pid' then
      emit('err', '-- break and sync but no PID byte')
    elseif st == 'resp' then
      local nm = sdec.li_name[id]
      local head = string.format('ID %02X', id or 0)
      if nm ~= nil then head = head .. ' ' .. nm end
      local pidbad = not (sdec.li_pid_ok(pid))
      -- A BYTE THE UART LAYER FLAGGED IS NOT A BYTE TO BUILD A CONCLUSION ON. Sync was
      -- already checked this way and the PID was not, which matters because a damaged PID
      -- can still pass parity and then names the WRONG ID: 0x11 damaged into 0xE2 is a
      -- valid PID for ID 0x22. The PID sits at d0 - 1, the response starting just after it.
      local piderr = (r.errs[d0 - 1] ~= nil)
      local pidtxt = ''
      if pidbad then
        pidtxt = string.format('  PID %s parity BAD', hex(pid))
      end
      if piderr then
        pidtxt = pidtxt .. '  PID byte damaged -- the ID may be wrong'
      end

      -- Before the response/no-response split, so a header the schedule reached still
      -- counts its ID. Counting it only for frames WITH a response made nframes and nids
      -- disagree: the mockup read "6 frames 4 ID(s)" over five distinct IDs.
      if id ~= nil and seenid[id] == nil then
        seenid[id] = true
        L.nids = L.nids + 1
      end

      if nd == 0 then
        -- Header with nothing after it. Legal -- the schedule reached this ID and
        -- nothing published -- and also exactly what a silent or missing slave looks
        -- like. Stated, not judged.
        local k = 'note'
        if pidbad or piderr then k = 'err' end
        emit(k, head .. '  header only, no response' .. pidtxt)
        L.nframes = L.nframes + 1
      else
        local ndata = nd - 1
        local cs = r.vals[d0 + nd - 1]
        local we = sdec.li_csum(r.vals, d0, ndata, pid)
        local wc = sdec.li_csum(r.vals, d0, ndata, nil)
        local diag = (id == 0x3C or id == 0x3D)

        -- Diagnostic frames are specified as classic whatever the rest of the bus does, so
        -- they are tested that way round; everything else tries enhanced first, LIN 2.x
        -- being the common case.
        --
        -- BOTH SIDES OF EVERY COMPARISON MUST EXIST, because in Lua `nil == nil` is TRUE
        -- and both sides can legitimately be nil -- r.vals[] holds nil for a byte the
        -- capture lost, li_csum returns nil when a byte it must sum is missing. A response
        -- missing both a data byte and its checksum was reported as `csum -- ok enh`,
        -- kind 'frame', bad = 0: a frame validated out of two absences.
        local csok, style = false, nil
        if cs ~= nil then
          if diag then
            if wc ~= nil and cs == wc then csok, style = true, 'cls'
            elseif we ~= nil and cs == we then csok, style = true, 'enh' end
          else
            if we ~= nil and cs == we then csok, style = true, 'enh'
            elseif wc ~= nil and cs == wc then csok, style = true, 'cls' end
          end
        end

        -- Damaged bytes change what a checksum failure MEANS: "the checksum is wrong" and
        -- "a byte arrived broken, so of course it is" are different faults. MISSING is
        -- counted apart from damaged, being the case that makes the checksum unverifiable
        -- rather than merely wrong.
        local nerr, nmiss, i = 0, 0, nil
        for i = d0, d0 + nd - 1 do
          if r.errs[i] ~= nil then nerr = nerr + 1 end
          if r.vals[i] == nil then nmiss = nmiss + 1 end
        end

        local t, m = {}, 0
        local lim = ndata
        if lim > 8 then lim = 8 end
        for i = d0, d0 + lim - 1 do
          m = m + 1
          t[m] = hex(r.vals[i])
        end
        local dtxt = table.concat(t, ' ', 1, m)
        if ndata > 8 then dtxt = dtxt .. ' ...' end

        local tail
        if csok then
          tail = string.format('csum %s ok %s', hex(cs), style)
        else
          tail = string.format('csum %s BAD (enh %s cls %s)', hex(cs), hex(we), hex(wc))
        end
        if nerr > 0 then
          tail = tail .. string.format('  %d damaged byte(s)', nerr)
          -- A checksum that agrees does NOT clear a flagged byte: see li_csum's blind spot
          -- above. Arithmetic, not caution.
          if csok then tail = tail .. ' -- the checksum match is not proof' end
        end
        if nmiss > 0 then
          tail = tail .. string.format('  %d byte(s) missing -- checksum unverifiable',
                                       nmiss)
        end
        -- A checksum that only validates as enhanced on a diagnostic ID is a real
        -- specification violation and worth naming, because it is the sort of thing a
        -- half-migrated LIN 1.x stack does.
        if csok and diag and style == 'enh' then
          tail = tail .. '  (spec wants classic here)'
        end

        local k = 'frame'
        if not csok or pidbad or piderr or nerr > 0 or nmiss > 0 then k = 'err' end
        -- 1..8 data bytes is the whole legal range. More than 8 usually means a break
        -- was missed and two frames ran together, which is worth saying outright
        -- because the checksum failure it causes otherwise looks like bus corruption.
        local lentxt = string.format('%d data', ndata)
        if ndata < 1 then
          lentxt = '0 data (a LIN frame carries 1 to 8)'
          k = 'err'
        elseif ndata > 8 then
          lentxt = string.format('%d data (over the 8-byte maximum -- a missed break?)',
                                 ndata)
          k = 'err'
        end

        emit(k, string.format('%s  %s  %s  %s%s', head, lentxt, dtxt, tail, pidtxt))
        L.nframes = L.nframes + 1
        -- The style census EXCLUDES diagnostic frames. They are classic by
        -- specification whatever version the bus is, so counting them made every
        -- perfectly ordinary LIN 2.x bus with a 0x3C frame on it report "mixed csum" --
        -- which is the one thing that summary is for. Among the rest, a mixture is
        -- genuinely worth reporting: it means either a half-migrated stack, or a
        -- corrupted enhanced checksum that landed on the classic value by luck, which
        -- happens once in 256 frames.
        -- An untrusted frame does not get to decide what the bus is, either.
        if csok and not diag and nerr == 0 and nmiss == 0 and not piderr then
          if style == 'enh' then L.nenh = L.nenh + 1 end
          if style == 'cls' then L.ncls = L.ncls + 1 end
        end
        if diag then L.ndiag = L.ndiag + 1 end
      end
    end
    st, pid, id, d0, nd = 'pre', nil, nil, nil, 0
  end

  local i
  for i = 1, r.nf do
    local v = r.vals[i]
    if sdec.li_break(r, i) then
      finish()
      -- Said once, for all of them, and BEFORE the first frame line so the list reads
      -- in capture order.
      if npre > 0 and not presaid then
        presaid = true
        emit('note', string.format('-- %d byte(s) before the first break (capture started mid-frame)',
                                   npre))
      end
      L.nbreak = L.nbreak + 1
      st, pid, id, d0, nd = 'sync', nil, nil, nil, 0
    elseif st == 'pre' then
      npre = npre + 1
    elseif st == 'sync' then
      if v == sdec.LI_SYNC and r.errs[i] == nil then
        st = 'pid'
      else
        -- The sync field is 0x55 by definition, so anything else means either this is
        -- not LIN or the bit rate is wrong -- and 0x55 read at the wrong bit rate is
        -- exactly how a wrong bit rate shows itself here.
        emit('err', string.format('-- sync field is %s, not 55 (wrong bit rate, or not LIN)',
                                  hex(v)))
        st = 'pre'
      end
    elseif st == 'pid' then
      pid = v
      local _
      _, id = sdec.li_pid_ok(v)
      if id == nil then id = 0 end
      st, d0, nd = 'resp', i + 1, 0
    else
      nd = nd + 1
    end
  end
  finish()

  if npre > 0 and not presaid then
    emit('note', string.format('-- %d byte(s) and no break field: no LIN frame here', npre))
  end
  if L.n == 0 then return false, 'no LIN frames found' end
  return true
end

-- ============================================================================
-- Presentation
-- ============================================================================
function sdec.li_line(i)
  local L = sdec.lin
  if L == nil or i < 1 or i > L.n then return '' end
  return L.msg[i]
end

function sdec.li_nrows()
  local L = sdec.lin
  if L == nil then return 0 end
  return L.n
end

-- What the capture contained. The checksum style is in here because it identifies the
-- BUS -- classic throughout is a LIN 1.x segment, enhanced is 2.x -- which is not
-- otherwise discoverable from a passive probe.
function sdec.li_summary()
  local L = sdec.lin
  if L == nil or L.nframes == 0 then return 'no LIN frames' end
  local style = ''
  if L.nenh > 0 and L.ncls == 0 then style = '  enhanced csum'
  elseif L.ncls > 0 and L.nenh == 0 then style = '  classic csum'
  elseif L.nenh > 0 and L.ncls > 0 then style = '  mixed csum' end
  local diag = ''
  if L.ndiag > 0 then diag = string.format('  %d diag', L.ndiag) end
  local bad = ''
  if L.bad > 0 then bad = string.format('  %d bad', L.bad) end
  return string.format('%d frames  %d ID(s)%s%s%s', L.nframes, L.nids, style, diag, bad)
end

-- ============================================================================
-- Notes for the panel
-- ============================================================================
-- Every break costs one framing error at the UART layer, so a perfectly healthy LIN
-- capture lights the ERR field red. Without this line that reads as a bad wire.
function sdec.li_breaknote()
  local L, r = sdec.lin, sdec.res
  if L == nil or r == nil then return nil end
  if L.nbreak < 1 or r.nbad < 1 then return nil end
  if L.nbreak >= r.nbad then
    return string.format('all %d framing error(s) are LIN break fields, which is normal',
                         r.nbad)
  end
  return string.format('%d of the %d framing errors are LIN break fields (normal); %d are not',
                       L.nbreak, r.nbad, r.nbad - L.nbreak)
end

-- The divider check. A LIN bus idles at Vbat, so an undivided 12 V one puts 12 V into a
-- 10 V range: the recessive level lands at or past the top of the range, and nothing
-- about the resulting mess says "you need a divider". A 2:1 divider puts a 12 V bus at
-- 6 V, comfortably inside; a 24 V commercial-vehicle bus needs more than 2:1.
--
-- ONE test, on the recessive level, because that is the only thing here that can be
-- decided soundly. The tempting second check -- "this swing is too small to be a divided
-- bus, so it must be a transceiver TTL pin" -- does not work: a divided 12 V bus is 6 V
-- and 5 V TTL is 5 V, one volt apart, and both decode perfectly well anyway. A warning
-- that cannot separate its two cases is worse than no warning.
--
-- Only ever a note. 12 V is far inside the front end's 1000 V DC rating, so nothing here
-- is a safety interlock -- it is a measurement-quality remark.
function sdec.li_levelnote()
  local hi = sdec.hi
  if hi == nil then return nil end
  if hi > 9.5 then
    return string.format('recessive is %.1f V, at the 10 V range limit -- divide the bus 2:1 (more for 24 V)',
                         hi)
  end
  return nil
end

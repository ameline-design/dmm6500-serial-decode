-- lin_decode.tsp -- LIN (ISO 17987) frame layer for the Keithley TSP serial decoder (Lua 5.0.2).
--
-- Not shipped in V1: package_tspa.py MODULES omits it, and the checksum has never been checked
-- against a real frame, so shipping it ships an unverified decode.
--
-- Works on the byte stream uart_decode.tsp produced. LIN is 8N1 underneath, idle recessive, and
-- specifies no baud rate, so the rate is left to the auto-detector. A 12 V bus needs a 2:1 divider:
-- docs/MEASUREMENTS.md, 'Wiring'.
--
-- The frame: BREAK (>= 13 dominant bits, against the 9 an 8N1 byte can hold), DELIMITER, SYNC 0x55,
-- PID, 1..8 DATA bytes, CHECKSUM. The length is not on the wire, so a passive analyser counts bytes
-- between breaks and takes the last as the checksum. The break arrives as a framing error, the UART
-- layer reading its first ten cells as 0x00, so li_breaknote() explains the red ERR field.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.LI_SYNC = 0x55

-- Bit times from the break's start edge to the next byte's. A break plus delimiter is at least 12
-- and a byte butted against the next is 10, so 11 separates them. Corroboration, not an independent
-- test: li_break() also requires value 0x00 and a failed stop bit. What survives all three is a 0x00
-- whose stop bit flipped inside a stream with 2+ bit times of space, which splits one frame in two
-- and fails both checksums.
sdec.li_minbreak = 11

-- The four reserved frame IDs. 0x3C and 0x3D carry diagnostics and require the classic checksum
-- whatever the rest of the bus uses, which is why the style cannot be assumed.
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
-- Checked against the known headers: ID 0x3C -> 0x3C, 0x3D -> 0x7D, 0x00 -> 0x80, 0x01 -> 0xC1.
function sdec.li_pid(id)
  local b = sdec.li_bit
  local i = math.mod(id, 64)
  local p0 = math.mod(b(i, 0) + b(i, 1) + b(i, 2) + b(i, 4), 2)
  local p1 = 1 - math.mod(b(i, 1) + b(i, 3) + b(i, 4) + b(i, 5), 2)
  return i + 64 * p0 + 128 * p1
end

-- ok, id. Both are wanted even when parity fails: the low six bits remain the best guess at the ID.
function sdec.li_pid_ok(pid)
  if pid == nil then return false, nil end
  local id = math.mod(pid, 64)
  return sdec.li_pid(id) == pid, id
end

-- ============================================================================
-- Checksum
-- ============================================================================
-- Inverted eight-bit sum with the carry added back: modulo-255, not 256. Pass pid for the enhanced
-- checksum (LIN 2.x), nil for the classic one. Never checked against a real frame.
--
-- Modulo-255 makes 0xFF congruent to 0x00, so an agreeing checksum is no proof that a flagged byte
-- arrived intact, and li_parse() does not treat it as proof.
-- docs/MEASUREMENTS.md, "The checksum's blind spot" and 'The LIN checksum'.
function sdec.li_csum(vals, i0, n, pid)
  local sum = 0
  if pid ~= nil then sum = math.mod(pid, 256) end
  local i
  for i = i0, i0 + n - 1 do
    local v = vals[i]
    if v == nil then return nil end
    -- Masked because a 9-bit width hands this values above 255, which happens only when the LIN
    -- view is opened on a capture decoded some other way.
    sum = sum + math.mod(v, 256)
    if sum > 255 then sum = sum - 255 end
  end
  return 255 - sum
end

-- ============================================================================
-- Break detection
-- ============================================================================
-- Bit times from byte i's start edge to the next's, or to the end of the capture for the last byte.
-- nil when no bit time is available, as in a hand-built result.
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
-- than any byte can be (sdec.li_minbreak), not longer than a frame -- ~34 bit times header-only,
-- ~124 with eight data bytes.
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
-- ok, reason. Fills sdec.lin. kind[] is 'frame', 'err' or 'note', so the UI colours a row without
-- re-parsing it. A frame failing its checksum or PID parity is 'err' and carries the detail on its
-- own line: one frame to one row keeps the list scannable.
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
    return string.format('%02X', math.mod(v, 256) or 0)
  end

  local st = 'pre'                 -- 'pre', 'sync', 'pid', 'resp'
  local pid, id = nil, nil
  local d0, nd = nil, 0            -- response bytes: first index, count
  local npre, presaid = 0, false

  -- Close whatever is open. Every exit routes here, so a frame ended by the next break and one
  -- ended by the capture running out produce the same line.
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
      -- A damaged PID can still pass parity and then names the wrong ID: 0x11 damaged into 0xE2 is
      -- a valid PID for ID 0x22. Sync was already checked this way. The PID sits at d0 - 1.
      local piderr = (r.errs[d0 - 1] ~= nil)
      local pidtxt = ''
      if pidbad then
        pidtxt = string.format('  PID %s parity BAD', tostring(hex(pid)))
      end
      if piderr then
        pidtxt = pidtxt .. '  PID byte damaged -- the ID may be wrong'
      end

      -- Before the response/no-response split, so a header the schedule reached counts its ID.
      -- Counting only frames with a response makes nframes and nids disagree.
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

        -- Diagnostic IDs are classic by spec, so they are tried that way round. Both sides of every
        -- comparison must exist: `nil == nil` is true, so a missing byte would validate an absence.
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

        -- Damaged bytes change what a failure means: a wrong checksum and a broken byte are
        -- different faults. Missing is counted apart, being unverifiable rather than merely wrong.
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
          tail = string.format('csum %s ok %s', tostring(hex(cs)), tostring(style))
        else
          tail = string.format('csum %s BAD (enh %s cls %s)', tostring(hex(cs)), tostring(hex(we)), tostring(hex(wc)))
        end
        if nerr > 0 then
          tail = tail .. string.format('  %d damaged byte(s)', nerr or 0)
          -- An agreeing checksum does not clear a flagged byte; see li_csum's blind spot.
          if csok then tail = tail .. ' -- the checksum match is not proof' end
        end
        if nmiss > 0 then
          tail = tail .. string.format('  %d byte(s) missing -- checksum unverifiable',
                                       nmiss or 0)
        end
        -- Enhanced on a diagnostic ID violates the spec, and is what a half-migrated stack does.
        if csok and diag and style == 'enh' then
          tail = tail .. '  (spec wants classic here)'
        end

        local k = 'frame'
        if not csok or pidbad or piderr or nerr > 0 or nmiss > 0 then k = 'err' end
        -- 1..8 is the legal range. More than 8 usually means a missed break ran two frames
        -- together, and the resulting checksum failure otherwise looks like bus corruption.
        local lentxt = string.format('%d data', ndata or 0)
        if ndata < 1 then
          lentxt = '0 data (a LIN frame carries 1 to 8)'
          k = 'err'
        elseif ndata > 8 then
          lentxt = string.format('%d data (over the 8-byte maximum -- a missed break?)',
                                 ndata or 0)
          k = 'err'
        end

        emit(k, string.format('%s  %s  %s  %s%s', tostring(head), tostring(lentxt), tostring(dtxt), tostring(tail), tostring(pidtxt)))
        L.nframes = L.nframes + 1
        -- Diagnostic frames are excluded, being classic at any version, and an untrusted frame does
        -- not vote. docs/MEASUREMENTS.md, 'The LIN checksum'.
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
      -- Said once, before the first frame line, so the list reads in capture order.
      if npre > 0 and not presaid then
        presaid = true
        emit('note', string.format('-- %d byte(s) before the first break (capture started mid-frame)',
                                   npre or 0))
      end
      L.nbreak = L.nbreak + 1
      st, pid, id, d0, nd = 'sync', nil, nil, nil, 0
    elseif st == 'pre' then
      npre = npre + 1
    elseif st == 'sync' then
      if v == sdec.LI_SYNC and r.errs[i] == nil then
        st = 'pid'
      else
        -- Sync is 0x55 by definition, so anything else means this is not LIN or the bit rate is
        -- wrong. 0x55 read at the wrong rate is how a wrong rate shows itself.
        emit('err', string.format('-- sync field is %s, not 55 (wrong bit rate, or not LIN)',
                                  tostring(hex(v))))
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
    emit('note', string.format('-- %d byte(s) and no break field: no LIN frame here', npre or 0))
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

-- What the capture contained. The checksum style identifies the bus -- classic throughout is a LIN
-- 1.x segment, enhanced is 2.x -- which a passive probe cannot otherwise discover.
function sdec.li_summary()
  local L = sdec.lin
  if L == nil or L.nframes == 0 then return 'no LIN frames' end
  local style = ''
  if L.nenh > 0 and L.ncls == 0 then style = '  enhanced csum'
  elseif L.ncls > 0 and L.nenh == 0 then style = '  classic csum'
  elseif L.nenh > 0 and L.ncls > 0 then style = '  mixed csum' end
  local diag = ''
  if L.ndiag > 0 then diag = string.format('  %d diag', L.ndiag or 0) end
  local bad = ''
  if L.bad > 0 then bad = string.format('  %d bad', L.bad or 0) end
  return string.format('%d frames  %d ID(s)%s%s%s', L.nframes or 0, L.nids or 0, tostring(style), tostring(diag), tostring(bad))
end

-- ============================================================================
-- Notes for the panel
-- ============================================================================
-- Every break costs one framing error at the UART layer, so a healthy capture lights ERR red.
-- Without this line that reads as a bad wire.
function sdec.li_breaknote()
  local L, r = sdec.lin, sdec.res
  if L == nil or r == nil then return nil end
  if L.nbreak < 1 or r.nbad < 1 then return nil end
  if L.nbreak >= r.nbad then
    return string.format('all %d framing error(s) are LIN break fields, which is normal',
                         r.nbad or 0)
  end
  return string.format('%d of the %d framing errors are LIN break fields (normal); %d are not',
                       L.nbreak or 0, r.nbad or 0, r.nbad - L.nbreak)
end

-- The divider check. A LIN bus idles at Vbat, so an undivided 12 V one puts the recessive level at
-- or past the top of the 10 V range, and nothing about the resulting mess says 'you need a divider'.
-- 2:1 puts a 12 V bus at 6 V; a 24 V commercial-vehicle bus needs more.
--
-- One test, on the recessive level, because it is the only sound one. Distinguishing a divided bus
-- from a transceiver TTL pin cannot work: 6 V against 5 V, and both decode anyway.
--
-- A measurement-quality note, not an interlock: 12 V is far inside the front end's 1000 V rating.
function sdec.li_levelnote()
  local hi = sdec.hi
  if hi == nil then return nil end
  if hi > 9.5 then
    return string.format('recessive is %.1f V, at the 10 V range limit -- divide the bus 2:1 (more for 24 V)',
                         hi or 0)
  end
  return nil
end

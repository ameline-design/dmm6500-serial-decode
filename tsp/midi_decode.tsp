-- midi_decode.tsp -- MIDI 1.0 message layer for the Keithley TSP serial decoder
-- (TSP / Lua 5.0.2).
--
-- Works entirely on the BYTE STREAM that uart_decode.tsp already produced. MIDI is
-- 31250 baud 8N1, so the wire layer needs nothing new: forcing sdec.force_baud =
-- 31250, force_nbits = 8 and force_par = PAR_NONE also removes every format
-- ambiguity the auto-detector would otherwise have to report.
--
-- WIRED IN via the options form's Protocol field: selecting MIDI sets sdec.proto, forces
-- 31250 / 8N1 / 1 stop, and switches to the message view. sdec.proto_parse() in
-- serial_app.tsp is the only caller, dispatching through the sdec.ui_views entry that names
-- mi_parse; the View button also cycles into the message list for any capture, so "is this
-- MIDI?" can be asked of an arbitrary stream.
--
-- Probing: either side works. On the TTL side of the opto-isolator it is ordinary
-- idle-high UART; across the DIN current loop, current ON is a logical 0, so the
-- polarity is inverted. sdec.sig_idle detects which, so neither needs declaring.
--
-- THREE THINGS MAKE A NAIVE MIDI PARSER WRONG, all handled below:
--   * RUNNING STATUS. A channel message may omit its status byte when it repeats,
--     so a bare pair of data bytes continues the previous message. A parser that
--     requires a status byte drops most of a dense stream.
--   * REAL-TIME BYTES (0xF8-0xFF) may appear ANYWHERE -- between the data bytes of
--     a channel message, or inside a SysEx block. They must be emitted without
--     disturbing either.
--   * System Common (0xF1-0xF7) CLEARS running status; real-time does not.
--
-- Lua 5.0.2: no '#', no bitwise operators, math.mod for modulo.

sdec = sdec or {}

sdec.MI_NOTES = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'}

-- Controllers worth naming. Sparse on purpose: an unnamed controller still prints
-- its number, and a wrong name is worse than none.
sdec.mi_ctl = {}
sdec.mi_ctl[0]   = 'Bank Select'
sdec.mi_ctl[1]   = 'Mod Wheel'
sdec.mi_ctl[7]   = 'Volume'
sdec.mi_ctl[10]  = 'Pan'
sdec.mi_ctl[11]  = 'Expression'
sdec.mi_ctl[64]  = 'Sustain'
sdec.mi_ctl[65]  = 'Portamento'
sdec.mi_ctl[71]  = 'Resonance'
sdec.mi_ctl[74]  = 'Cutoff'
sdec.mi_ctl[91]  = 'Reverb'
sdec.mi_ctl[93]  = 'Chorus'
sdec.mi_ctl[120] = 'All Sound Off'
sdec.mi_ctl[121] = 'Reset All Ctl'
sdec.mi_ctl[123] = 'All Notes Off'

-- sdec.midi   -- {n, msg[], kind[], bad}, declared not assigned (see serial_core)

-- Note 60 is middle C, and A4 = note 69 = 440 Hz, which fixes the octave numbering
-- at floor(n/12) - 1. (Yamaha's convention calls the same note C3; this uses the
-- scientific one that matches A440.)
function sdec.mi_note_name(n)
  if n == nil then return '?' end
  local oct = math.floor(n / 12) - 1
  return sdec.MI_NOTES[math.mod(n, 12) + 1] .. tostring(oct)
end

-- How many data bytes a status byte expects.
function sdec.mi_datacount(st)
  if st >= 0xF8 then return 0 end                  -- real-time: status only
  if st >= 0xF0 then
    if st == 0xF1 or st == 0xF3 then return 1 end  -- MTC quarter frame, song select
    if st == 0xF2 then return 2 end                -- song position pointer
    return 0                                        -- F0/F4/F5/F6/F7
  end
  local hi = math.floor(st / 16)
  if hi == 0xC or hi == 0xD then return 1 end      -- program change, chan aftertouch
  return 2
end

function sdec.mi_rtname(st)
  if st == 0xF8 then return 'Clock' end
  if st == 0xFA then return 'Start' end
  if st == 0xFB then return 'Continue' end
  if st == 0xFC then return 'Stop' end
  if st == 0xFE then return 'Active Sensing' end
  if st == 0xFF then return 'Reset' end
  return string.format('Undefined %02X', st)
end

-- Render one channel or system-common message.
function sdec.mi_format(st, d)
  local hi = math.floor(st / 16)
  local ch = math.mod(st, 16) + 1                  -- channels are 1-16 to a musician
  local chs = string.format('ch%-2d ', ch)

  if hi == 0x8 then
    return chs .. string.format('Note Off   %-4s vel %d', sdec.mi_note_name(d[1]), d[2] or 0)
  end
  if hi == 0x9 then
    -- Note On with velocity 0 is the conventional Note Off, and saying so avoids
    -- a reader wondering why nothing ever stops.
    if (d[2] or 0) == 0 then
      return chs .. string.format('Note On    %-4s vel 0  (= Note Off)',
                                  sdec.mi_note_name(d[1]))
    end
    return chs .. string.format('Note On    %-4s vel %d', sdec.mi_note_name(d[1]), d[2])
  end
  if hi == 0xA then
    return chs .. string.format('Aftertouch %-4s %d', sdec.mi_note_name(d[1]), d[2] or 0)
  end
  if hi == 0xB then
    local name = sdec.mi_ctl[d[1] or -1]
    if name == nil then name = string.format('CC %d', d[1] or 0) end
    return chs .. string.format('%-14s = %d', name, d[2] or 0)
  end
  if hi == 0xC then
    return chs .. string.format('Program    %d', (d[1] or 0) + 1)
  end
  if hi == 0xD then
    return chs .. string.format('Chan Press %d', d[1] or 0)
  end
  if hi == 0xE then
    -- 14-bit, LSB first, centre 8192. The signed offset is what a player feels.
    local v = (d[1] or 0) + 128 * (d[2] or 0)
    return chs .. string.format('Pitch Bend %+d', v - 8192)
  end

  if st == 0xF1 then return '     MTC Quarter Frame ' .. tostring(d[1] or 0) end
  if st == 0xF2 then
    return string.format('     Song Position %d', (d[1] or 0) + 128 * (d[2] or 0))
  end
  if st == 0xF3 then return '     Song Select ' .. tostring(d[1] or 0) end
  if st == 0xF6 then return '     Tune Request' end
  return string.format('     Status %02X', st)
end

-- Well-known SysEx manufacturer / universal IDs, enough to make a dump readable.
function sdec.mi_sysex_who(b, n)
  if n < 1 then return 'empty' end
  local id = b[1]
  if id == 0x7E then return 'Universal Non-Real Time' end
  if id == 0x7F then return 'Universal Real Time' end
  if id == 0x43 then return 'Yamaha' end
  if id == 0x41 then return 'Roland' end
  if id == 0x42 then return 'Korg' end
  if id == 0x47 then return 'Akai' end
  if id == 0x00 then return 'extended ID' end
  return string.format('mfr %02X', id)
end

-- ============================================================================
-- Parse the byte stream into messages
-- ============================================================================
-- Returns ok, reason. Fills sdec.midi = {n, msg[], kind[], bad, nrt}.
--
-- kind[] is 'chan', 'rt', 'sys', 'sysex' or 'err', so the UI can colour a line
-- without re-parsing it.
function sdec.mi_parse()
  local r = sdec.res
  sdec.midi = {n = 0, msg = {}, kind = {}, bad = 0, nrt = 0}
  if r == nil or r.nf == 0 then return false, 'no bytes to parse' end
  local m = sdec.midi

  local function emit(kind, text)
    local k = m.n + 1
    m.n = k
    m.kind[k] = kind
    m.msg[k] = text
    if kind == 'err' then m.bad = m.bad + 1 end
    if kind == 'rt' then m.nrt = m.nrt + 1 end
  end

  -- A channel or system-common message that never got all its data bytes.
  --
  -- Reported for the same reason SysEx truncation is: the alternative is that a Note
  -- On which lost its velocity byte simply is not in the list, so the message count
  -- disagrees with the byte dump and nothing says why. There are TWO ways it happens
  -- -- the capture ended mid-message, or a fresh status byte arrived and abandoned it
  -- (a byte lost on the wire) -- and the second is the common one.
  local function trunc(s, g, nd)
    emit('err', string.format('     -- status %02X truncated (%d of %d data bytes)',
                              s, g, nd))
  end

  local running = nil       -- status byte still in force for running status
  local need, got = 0, 0
  local d = {}
  local st = nil            -- status the pending data belongs to
  local sx, sxn = {}, 0     -- SysEx accumulator
  local insysex = false
  local i

  for i = 1, r.nf do
    local v = r.vals[i]
    if v == nil or r.errs[i] ~= nil then
      emit('err', string.format('     -- framing error at byte %d', i))
    elseif v >= 0xF8 then
      -- Real-time. Interleaves anywhere, including mid-message and mid-SysEx, and
      -- must not disturb running status, the pending data, or the SysEx block.
      emit('rt', '     ' .. sdec.mi_rtname(v))
    elseif v >= 0x80 then
      if insysex and v ~= 0xF7 then
        -- A status byte other than F7 aborts an unterminated SysEx; the device
        -- either reset or bytes were lost.
        emit('err', string.format('     -- SysEx truncated after %d bytes', sxn))
        insysex = false
      end
      -- Abandon any half-collected channel message BEFORE the new status replaces it.
      if st ~= nil and got < need then
        trunc(st, got, need)
        st, got = nil, 0
      end
      if v == 0xF0 then
        insysex, sx, sxn = true, {}, 0
        running = nil
      elseif v == 0xF7 then
        if insysex then
          local t = {}
          local j
          local lim = sxn
          if lim > 8 then lim = 8 end
          for j = 1, lim do t[j] = string.format('%02X', sx[j]) end
          local tail = ''
          if sxn > 8 then tail = string.format(' ... (%d bytes)', sxn) end
          emit('sysex', '     SysEx ' .. sdec.mi_sysex_who(sx, sxn) .. '  '
                        .. table.concat(t, ' ') .. tail)
          insysex = false
        else
          emit('err', '     -- stray SysEx End (F7)')
        end
        running = nil
      else
        -- System Common clears running status; channel status sets it.
        need = sdec.mi_datacount(v)
        got, d, st = 0, {}, v
        if v >= 0xF0 then running = nil else running = v end
        if need == 0 then
          emit('sys', sdec.mi_format(v, d))
          st = nil
        end
      end
    else
      -- Data byte.
      if insysex then
        sxn = sxn + 1
        sx[sxn] = v
      else
        if st == nil then
          -- No status pending: this is running status if one is in force.
          if running ~= nil then
            st = running
            need = sdec.mi_datacount(running)
            got, d = 0, {}
          else
            emit('err', string.format('     -- orphan data byte %02X', v))
          end
        end
        if st ~= nil then
          got = got + 1
          d[got] = v
          if got >= need then
            local kind = 'chan'
            if st >= 0xF0 then kind = 'sys' end
            emit(kind, sdec.mi_format(st, d))
            -- Running status stays in force, so the next bare data byte starts a
            -- fresh message of the same type.
            st, got, d = nil, 0, {}
          end
        end
      end
    end
  end

  if insysex then
    emit('err', string.format('     -- SysEx unterminated after %d bytes', sxn))
  elseif st ~= nil and got < need then
    trunc(st, got, need)         -- the capture simply ended mid-message
  end
  if m.n == 0 then return false, 'no MIDI messages found' end
  return true
end

-- ============================================================================
-- Presentation
-- ============================================================================
function sdec.mi_line(i)
  local m = sdec.midi
  if m == nil or i < 1 or i > m.n then return '' end
  return m.msg[i]
end

function sdec.mi_nrows()
  local m = sdec.midi
  if m == nil then return 0 end
  return m.n
end

-- Summary line for the panel: what the stream contained, not just how many bytes.
function sdec.mi_summary()
  local m = sdec.midi
  if m == nil or m.n == 0 then return 'no MIDI messages' end
  local extra = ''
  if m.bad > 0 then extra = string.format('  %d bad', m.bad) end
  local rt = ''
  if m.nrt > 0 then rt = string.format('  %d real-time', m.nrt) end
  return string.format('%d messages%s%s', m.n, rt, extra)
end

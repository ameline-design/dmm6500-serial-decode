-- seam_capture.lua -- reproduce a capture at every start offset across one arb period, and dump what
-- the bench's judge would be handed. Offline; no instrument.
--
-- WHY IT EXISTS. The lorem "capture too short to judge" failure was a JUDGING bug: the bench trimmed
-- r.headsusp bytes before judging, but headsusp is the distance to the first idle gap, and on a
-- payload longer than one capture that gap is the ARB LOOP SEAM -- so when the seam landed late in
-- the capture the judge threw away everything and failed a correct decode. Five laps of 58.
--
-- The gate written alongside the fix pinned head_damage() itself, with hand-built hex. That is not
-- the failure mode: the defect was in the CALLER'S ARGUMENT to judge_payload, which hand-built hex
-- never exercises. So this script produces the real thing -- real payload, real render, real windowing
-- at real offsets, real TSP decoder -- and tools/test_seam.py applies both judging rules to it and
-- requires the unfixed one to FAIL. A regression test that cannot fail against the defect it names
-- is not a regression test.
--
-- THE PAYLOAD AND THE RENDER OPTIONS COME FROM THE VECTOR TABLE, not from out/vectors/ and not from
-- literals here. make_vectors.lua is loaded in define-only mode and v71's own build() hands back both
-- its bytes and the exact opts it is rendered with, so this cannot drift from the vector the bench
-- plays, and it works on a fresh clone where out/vectors/ does not exist yet.
--
--   lua tools/seam_capture.lua [stride] [vid]        # stride in payload bytes, default 4

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end
MD.usb(false)

VEC_DEFINE_ONLY = true
dofile('tools/make_vectors.lua')

local STRIDE = tonumber(arg[1]) or 4
local WANTID = arg[2] or 'v71'

local v = nil
local i
for i = 1, table.getn(VEC_LIST) do
  if VEC_LIST[i].id == WANTID then v = VEC_LIST[i] end
end
if v == nil then print('no such vector: ' .. WANTID); os.exit(1) end

GEN_RESEED(12345)
local opts, want, nwant, post, payload = v.build()
if payload == nil then print(WANTID .. ' carries no payload string'); os.exit(1) end
local rd, ts, nc, nsmp = GEN(opts)
if post ~= nil then rd = post(rd, nsmp) end

local nb = string.len(payload)
local fs = opts.fs or v.fs
local baud = opts.baud or 9600
local spb = fs / baud
local gap = opts.gap or 0
local sbyte = (10 + gap) * spb                 -- samples per 8N1 byte, plus any inter-frame idle
local NCAP = sdec.n_deliv(sdec.n) or 19000     -- what an armed capture really returns

print(string.format('# %s payload=%d B baud=%d fs=%d sa/bit=%.5f arb=%d samples cap=%d stride=%d',
                    WANTID, nb, baud, fs, spb, nsmp, NCAP, STRIDE))
-- THE CONDITION THAT MATTERS, printed so the host side can assert it rather than assume it: the
-- failure class needs the payload to be LONGER than one capture, so that the arb holds at most one
-- seam inside the window and idle1 can be late. cap_bytes below is that capture length in bytes.
print(string.format('# cap_bytes=%d payload_bytes=%d exposed=%s',
                    math.floor(NCAP / sbyte), nb,
                    tostring(nb > math.floor(NCAP / sbyte))))

-- The payload itself, so the host side judges against the SAME bytes this render was built from
-- rather than re-reading a file that may not exist or may have been regenerated.
local ph, pk = {}, nil
for pk = 1, nb do ph[pk] = string.format('%02X', string.byte(payload, pk)) end
print('# payloadhex=' .. table.concat(ph))

local off0 = math.floor((opts.lead or 10) * spb)
for i = 0, nb - 1, STRIDE do
  local off = off0 + math.floor(i * sbyte)
  local w, k = {}, nil
  for k = 1, NCAP do
    w[k] = rd[math.mod(off + k - 1, nsmp) + 1]
  end
  -- NOTHING FORCED. The bench's lorem and payload suites auto-detect and then auto-lock, so forcing
  -- the rate here would test a path the failure never came through.
  sdec.force_baud, sdec.force_nbits = nil, nil
  sdec.force_par, sdec.force_nstop, sdec.force_invert = nil, nil, nil
  sdec.proto = 'uart'
  sdec.acq_fs = fs
  sdec.sig_levels(w, NCAP)
  sdec.sig_edges(w, NCAP)
  sdec.sig_idle(w, NCAP)
  local ok, why = pcall(function() return sdec.decode_from(w, NCAP) end)
  local r = sdec.res
  if not ok then
    print(string.format('S %d RAISED %s', i, tostring(why)))
  elseif r == nil or r.nf == nil or r.nf < 1 then
    print(string.format('S %d REFUSED', i))
  else
    -- The hex exactly as bench_matrix prints it: '??' for any frame carrying an err.
    local seg, m = {}, nil
    for m = 1, r.nf do
      if r.errs[m] == nil then seg[m] = string.format('%02X', r.vals[m]) else seg[m] = '??' end
    end
    print(string.format('S %d nf=%d headsusp=%s head_bad=%d nbad=%d hex=%s',
                        i, r.nf, tostring(r.headsusp), sdec.ua_head_bad(r), r.nbad,
                        table.concat(seg)))
  end
end
print('# done')

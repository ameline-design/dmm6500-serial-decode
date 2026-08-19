-- repro_fmtnote.lua -- the 7E1-promotion crash, swept over capture offsets.
--
-- ua_refine_parity's NON-STRICT path re-decodes at 7 bits and returned a result with nbits/par/nstop/invert
-- all nil, so ua_note_fmt's %d raised inside capture() while describing a decode that had succeeded.
-- Before the fix: 14 of 256 offsets raised. After: 0. Identical at c7ca3e9, so it long predates the
-- session that found it.
--
-- NOT IN test_serial.lua, AND THAT IS THE HONEST REASON: a synthetic 7-bit random payload does NOT
-- reproduce it. Cleanly generated 7E1 data gives a UNANIMOUS parity vote, which takes the strict in-place
-- branch where the fields already exist. Provoking the non-strict branch needs r06's construction
-- (a shuffle of 0..127 twice, per make_vectors.lua). A gated test wants that payload built in-process --
-- until then this script is the proof, and it needs out/vectors/r06.txt, which make_vectors.lua writes.
--
--   lua tools/repro_fmtnote.lua        # expect: 0 raised

dofile('tools/mock_display.lua')
dofile('tools/gen_serial.lua')
for _, m in ipairs({'tsp/usb_log.tsp','tsp/serial_core.tsp','tsp/uart_decode.tsp'}) do
  local c = loadfile(m); if c == nil then print('LOAD FAIL '..m); os.exit(1) end; c()
end
-- r06's payload, as the oracle records it
local f = io.open('out/vectors/r06.txt','rb'); local raw = f:read('*a'); f:close()
local pay, n = {}, 0
for i = 1, string.len(raw) do n = n + 1; pay[n] = string.byte(raw, i) end
print(string.format('payload %d bytes, max %d', n, (function() local m=0 for i=1,n do if pay[i]>m then m=pay[i] end end return m end)()))

-- Sweep where the capture lands in the loop: rotate the payload, lead=0 like a mid-stream capture.
local nilfmt, zerob, bad, tried = 0, 0, 0, 0
local firstnil = nil
for off = 0, n - 1, 1 do
  local rot, k = {}, 0
  for i = 1, n do k = k + 1; rot[k] = pay[((off + i - 1) % n) + 1] end
  local rd, ts, nc, nsmp = GEN({bytes = rot, nbits = 7, par = 1, baud = 9600, fs = 100000,
                                gap = 0, lead = 0, tail = 10, n = 20000})
  sdec.force_baud, sdec.force_nbits, sdec.force_par = nil, nil, nil
  sdec.force_nstop, sdec.force_invert = nil, nil
  sdec.acq_fs = 100000
  sdec.sig_levels(rd, nsmp)
  sdec.sig_edges(rd, nsmp)
  sdec.sig_idle(rd, nsmp)
  tried = tried + 1
  local ok, why = pcall(function() return sdec.decode_from(rd, nsmp) end)
  local r = sdec.res
  if not ok then
    bad = bad + 1
    if firstnil == nil then firstnil = string.format('offset %d RAISED: %s', off, tostring(why)) end
  elseif r ~= nil and r.nbits == nil then
    nilfmt = nilfmt + 1
    if firstnil == nil then firstnil = string.format('offset %d: res with NIL nbits, nf=%s', off, tostring(r.nf)) end
  elseif r ~= nil and (r.nf == nil or r.nf == 0) then
    zerob = zerob + 1
    if firstnil == nil then firstnil = string.format('offset %d: res with nf=%s, nbits=%s', off, tostring(r.nf), tostring(r.nbits)) end
  end
end
print(string.format('tried %d offsets: %d raised, %d res-with-nil-nbits, %d res-with-0-bytes', tried, bad, nilfmt, zerob))
print('first anomaly: ' .. tostring(firstnil))

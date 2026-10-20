-- chunk_decode.tsp -- decode a capture longer than Lua memory, one window at a time.
--
-- Frame mode holds a whole capture as a plain Lua array, which caps it at 20 000 samples, 192-500
-- bytes. The reading buffer holds the long capture instead -- up to sdec.ck_bufmax samples -- and the
-- decode walks it in overlapping windows, appending each window's bytes to a file and reusing one
-- window table. Memory stays at one window whatever the length, and the buffer bounds the length.
-- Real-time extraction instead needs a per-sample read cost the instrument does not have:
-- docs/MEASUREMENTS.md, 'Streaming by real-time extraction is not possible'. Acquisition belongs to
-- serial_app; everything here is logic over a sample source, exercised offline against
-- tools/gen_serial.lua. Lua 5.0.2: no '#', math.mod for modulo, table.getn for length.

sdec = sdec or {}

-- ---------- configuration ----------
-- sdec.n, the size frame mode already uses, so the memory high-water mark is one the app survives.
sdec.ck_win_n = 20000

-- Overlap in frames: one for correctness, two for margin. ck_overlap() derives the floor.
sdec.ck_ovframes = 3

-- Samples the level measurement decimates the recording down to: past sig_levels' bin saturation and
-- equal to frame mode's own population. docs/MEASUREMENTS.md, 'Why ck_level_n is 20 000'.
sdec.ck_level_n = 20000

-- Contiguous windows the level fallback tries, spaced across the recording. docs/MEASUREMENTS.md,
-- 'Why the contiguous fallback is spaced across the recording'.
sdec.ck_probes = 8

-- Medium mode's cap, one number for every baud rate. docs/MEASUREMENTS.md, 'ck_maxbytes = 32768'.
sdec.ck_maxbytes = 32768

-- ============================================================================
-- Sample sources
-- ============================================================================
-- A reader is reader(dst, from, count, step) filling dst[1..m] with the samples at absolute 1-based
-- positions from, from+step, ... and returning m, short only at the end of the data. step defaults to
-- 1 and exists so the levels can be measured over the whole recording while the edges are measured
-- window by window -- see ck_levels(). dst is the caller's, reused for every window and never cleared,
-- so entries past m are stale: safe, sig_levels, sig_edges and ua_bit each being bounded by their n.


-- Over a plain Lua array: the test path, and the way to chunk a capture already in memory.
function sdec.ck_reader_table(rd, ntotal)
  return function(dst, from, count, step)
    if step == nil then step = 1 end
    local m = 0
    if step == 1 then
      local last = from + count - 1
      if last > ntotal then last = ntotal end
      local a
      for a = from, last do
        local v = rd[a]
        if v == nil then break end
        m = m + 1
        dst[m] = v
      end
      return m
    end
    local last = from + (count - 1) * step
    if last > ntotal then last = ntotal end
    local a
    for a = from, last, step do
      local v = rd[a]
      if v == nil then break end
      m = m + 1
      dst[m] = v
    end
    return m
  end
end

-- Over a reading buffer. buf.readings is a firmware proxy, so each index is an IPC round trip at
-- 21.73 us. docs/MEASUREMENTS.md, 'Reading a sample out of a reading buffer'.
function sdec.ck_reader_buffer(buf, ntotal)
  local rdp = buf.readings
  -- The ring's logical start, read once per reader so `from` means the n-th reading in time to both
  -- sides: a wrapped FILL_CONTINUOUS buffer holds its oldest reading part-way up the array, as does an
  -- armed recording rotated by its pre-trigger phase. The buffer is sized to fill exactly once.
  local off = 0
  if sdec.acq_first ~= nil then off = sdec.acq_first(buf, ntotal) - 1 end
  return function(dst, from, count, step)
    if step == nil then step = 1 end
    local m = 0
    if step == 1 then
      local last = from + count - 1
      if last > ntotal then last = ntotal end
      local a
      for a = from, last do
        local p = a + off
        if p > ntotal then p = p - ntotal end
        local v = rdp[p]
        if v == nil then break end
        m = m + 1
        dst[m] = v
      end
      return m
    end
    local last = from + (count - 1) * step
    if last > ntotal then last = ntotal end
    local a
    for a = from, last, step do
      local p = a + off
      if p > ntotal then p = p - ntotal end
      local v = rdp[p]
      if v == nil then break end
      m = m + 1
      dst[m] = v
    end
    return m
  end
end

-- ============================================================================
-- Window geometry
-- ============================================================================
-- How much the windows must overlap. Getting it wrong loses one byte per seam, and a byte lost
-- mid-file is hard to notice. The floor is one frame, framebits * T; the extra two frames and maxback
-- cover sig_cross's truncated back-walk. docs/MEASUREMENTS.md, 'Overlap'.
function sdec.ck_overlap(T, framebits)
  if T == nil or framebits == nil then return nil end
  return math.ceil(sdec.ck_ovframes * framebits * T) + sdec.maxback
end

-- Window size, overlap and stride for a bit time, or nil plus a reason. Refuses rather than clamps
-- when the window cannot hold enough frames: at 1200 baud with fs at 1 MSa/s, T is 833 samples and
-- three 12-bit frames do not fit, so the stride would go negative. The refusal names the sample rate.
function sdec.ck_geometry(T, framebits)
  local W = sdec.ck_win_n
  local ov = sdec.ck_overlap(T, framebits)
  if ov == nil then return nil, nil, nil, 'no bit time' end
  local need = math.ceil((sdec.ck_ovframes + 2) * framebits * T) + sdec.maxback
  if W < need then
    return nil, nil, nil,
           string.format('%.0f samples/frame needs a window of %d, not %d -- ' ..
                         'sample slower', framebits * T, need or 0, W or 0)
  end
  local stride = W - ov
  return W, ov, stride, nil
end

-- How many windows a capture takes at this stride. Exact, because the stride is constant, which buys
-- a window count known before the run starts. docs/MEASUREMENTS.md, 'Constant stride'.
function sdec.ck_nwin(ntotal, W, stride)
  if ntotal == nil or W == nil or stride == nil or stride < 1 then return nil end
  if ntotal <= W then return 1 end
  return 1 + math.ceil((ntotal - W) / stride)
end

-- ============================================================================
-- Priming: measure the line once
-- ============================================================================
-- Levels are an amplitude statistic and edges a time statistic, so levels may be decimated over the
-- whole recording while edges stay window by window. They must not be re-measured per window.
-- docs/MEASUREMENTS.md, 'Levels are an amplitude statistic; edges are a time statistic'.
--
-- The decimated attempt alone, so priming can spend one press on it. Returns ok, why, fatal; fatal
-- means the source gave nothing, so the contiguous probes cannot help either.
function sdec.ck_levels_dec(reader, ntotal, win)
  if reader == nil then return false, 'no sample source', true end
  -- Not clamped to ck_win_n: the window is a Lua table, so it grows to the larger of the two. Clamping
  -- would put the window size back into the accept/refuse decision, and only in the offline suite.
  local N = sdec.ck_level_n
  -- ck_level_max is the latency cap, set by the panel path from its budget; nil off the panel, so the
  -- one-shot callers and the offline suite keep the full decimated view.
  if sdec.ck_level_max ~= nil and sdec.ck_level_max < N then N = sdec.ck_level_max end
  local step = 1
  if ntotal ~= nil and ntotal > N then step = math.ceil(ntotal / N) end
  local cnt = reader(win, 1, N, step)
  if cnt == nil or cnt < 2 then return false, 'nothing captured', true end
  local ok, why = sdec.sig_levels(win, cnt)
  if ok then sdec.ck_levelsrc = 'decimated' end
  return ok, why, false
end

-- One contiguous level probe, k = 0..ck_probes-1. Decimation can alias past a sparse burst, so the
-- fallback reads whole windows spaced across the recording; the decimated view is still tried first.
-- docs/MEASUREMENTS.md, 'Why the contiguous fallback is spaced across the recording'.
function sdec.ck_levels_probe(reader, ntotal, win, k)
  if reader == nil then return false end
  local W = sdec.ck_win_n
  if ntotal ~= nil and ntotal < W then W = ntotal end
  local nprobe = sdec.ck_probes or 1
  local total = ntotal or W
  local span = total - W
  if span < 0 then span = 0 end
  local from = 1
  if nprobe > 1 and span > 0 then
    from = 1 + math.floor(span * k / (nprobe - 1))
  end
  local c2 = reader(win, from, W, 1)
  if c2 == nil or c2 < 2 then return false end
  if not sdec.sig_levels(win, c2) then return false end
  sdec.ck_levelsrc, sdec.ck_levelat = 'contiguous', from
  return true
end

-- Levels for a whole recording: decimated first, then contiguous probes. Returns ok, reason.
function sdec.ck_levels(reader, ntotal, win)
  local ok, why, fatal = sdec.ck_levels_dec(reader, ntotal, win)
  if ok then return true end
  if fatal then return false, why end
  local k
  for k = 0, (sdec.ck_probes or 1) - 1 do
    if sdec.ck_levels_probe(reader, ntotal, win, k) then return true end
  end
  sdec.ck_levelsrc, sdec.ck_levelat = nil, nil
  return false, why
end

-- Format, on a contiguous lead-in window, with the levels already established. The format must not be
-- re-searched per window: ua_autoformat can legitimately choose between formats indistinguishable on
-- the wire and its tie-breaks are statistical, so per window it could change its mind halfway through
-- a file with nothing in the file to say so.
--
-- Priming is phased, one bounded sub-operation per call, because unphased it is the longest thing a
-- front-panel press can reach: eight level probes, a lead-in read, edge extraction and the format
-- search, seconds of Lua in one call. pr.label names the phase for the status row. In order, each one
-- window's work or less: lvd decimated levels, lvp one contiguous probe (at most ck_probes), read the
-- lead-in window from pr.at, edge sig_edges and sig_idle, fmt the format search -- and read, edge and
-- fmt repeat together on the window after one that found no format, at most ck_prime_tries times.

-- How many windows the format search may spend, from the silence an armed record opens with: the first
-- window can be entirely the pre-trigger wait, so a search that looks there and nowhere else refuses a
-- recording whose bytes are all present. leadmax is the caller's and cannot be derived from ntotal,
-- the reserve coming out of the buffer's capacity; nil means no reserve. docs/MEASUREMENTS.md, 'An
-- armed record opens on silence' and 'ck_prime_tries = floor(leadmax / W) + 2'.
-- skip is a SECOND source of silence the search may have to cross, and it is separate from leadmax because the
-- two answer different questions about the same record. An elided recording has no reserve at all, so leadmax
-- must be nil there or sig_idle treats a genuine leading run as the wire before the device started -- but it
-- carries one detector window of idle at the END of every burst, and a short first burst leaves the search
-- looking at traffic, then idle, then giving up with 'no format' while every byte is present.
function sdec.ck_prime_tries(leadmax, skip)
  local W = sdec.ck_win_n
  if W == nil or W < 1 then return 1 end
  if leadmax == nil or leadmax < 0 then leadmax = 0 end
  if skip == nil or skip < 0 then skip = 0 end
  local lead = leadmax
  if skip > lead then lead = skip end
  return math.floor(lead / W) + 2
end

function sdec.ck_prime_new(reader, ntotal, win, leadmax, skip)
  if reader == nil then return nil, 'no sample source' end
  -- leadmax is kept, not just consumed: the 'edge' phase needs to know this record has a pre-trigger
  -- reserve, and leadmax being non-nil is that fact. One source, so the two cannot disagree.
  return {reader = reader, ntotal = ntotal, win = win, phase = 'lvd', probe = 0,
          cnt = 0, at = 1, try = 1, tries = sdec.ck_prime_tries(leadmax, skip),
          leadmax = leadmax,
          why = nil, label = 'levels'}, nil
end

-- One priming sub-operation. Returns done, fmt, err; fmt is set only on the last call.
function sdec.ck_prime_step(pr)
  if pr == nil then return true, nil, 'no priming state' end

  if pr.phase == 'lvd' then
    local ok, why, fatal = sdec.ck_levels_dec(pr.reader, pr.ntotal, pr.win)
    if ok then
      pr.phase, pr.label = 'read', 'reading'
      return false, nil, nil
    end
    if fatal then return true, nil, why end
    pr.why, pr.phase, pr.probe = why, 'lvp', 0
    pr.label = string.format('levels 1/%d', sdec.ck_probes or 1)
    return false, nil, nil
  end

  if pr.phase == 'lvp' then
    if sdec.ck_levels_probe(pr.reader, pr.ntotal, pr.win, pr.probe) then
      pr.phase, pr.label = 'read', 'reading'
      return false, nil, nil
    end
    pr.probe = pr.probe + 1
    if pr.probe >= (sdec.ck_probes or 1) then
      sdec.ck_levelsrc, sdec.ck_levelat = nil, nil
      return true, nil, pr.why or 'no clear logic levels'
    end
    pr.label = string.format('levels %d/%d', pr.probe + 1, sdec.ck_probes or 1)
    return false, nil, nil
  end

  if pr.phase == 'read' then
    -- From pr.at, which is not always 1: a try that found no format advances by the whole width it
    -- read, and the only question asked here is which format fits, not which frame straddles a seam.
    local W = sdec.ck_win_n
    local left = nil
    if pr.ntotal ~= nil then left = pr.ntotal - pr.at + 1 end
    if left ~= nil and left < W then W = left end
    local cnt = nil
    if W >= 2 then cnt = pr.reader(pr.win, pr.at, W, 1) end
    -- pr.fmtwhy first: a short read after a try ends a record whose earlier windows did not frame.
    if cnt == nil or cnt < 2 then return true, nil, pr.fmtwhy or 'nothing captured' end
    -- W and the position recorded beside cnt, so ck_decode can check this window is the one its own
    -- geometry wants. docs/MEASUREMENTS.md, 'Window reuse between priming and decode'.
    pr.cnt, pr.W, pr.phase, pr.label = cnt, W, 'edge', 'edges'
    return false, nil, nil
  end

  -- From here it is the frame-mode chain on the shipped functions, minus the sig_levels call that
  -- ck_levels has done better -- so priming leaves sdec.res and the panel summary describing the line.
  if pr.phase == 'edge' then
    sdec.sig_edges(pr.win, pr.cnt)
    -- Set for every try: the reserve is the wire before the device started, and the polarity prior
    -- taken from it inverts the whole recording. docs/MEASUREMENTS.md, 'Why sig_idle must exclude the
    -- leading run on an armed record'.
    sdec.acq_pretrig = (pr.leadmax ~= nil and pr.leadmax > 0)
    sdec.sig_idle(pr.win, pr.cnt)
    pr.phase, pr.label = 'fmt', 'format'
    return false, nil, nil
  end

  local ok, why = sdec.decode_from(pr.win, pr.cnt)
  local r = sdec.res
  if ok and (r == nil or sdec.bittime == nil) then ok, why = false, 'no format' end
  if not ok then
    -- No format here is not yet a verdict: the window may be the pre-trigger reserve, which carries no
    -- frames. Advance a whole window, at most ck_prime_tries times; the levels are not re-measured.
    local nxt = pr.at + pr.W
    if pr.try < (pr.tries or 1) and pr.ntotal ~= nil and nxt < pr.ntotal then
      pr.try, pr.at, pr.fmtwhy = pr.try + 1, nxt, why
      pr.phase = 'read'
      pr.label = string.format('format %d/%d', pr.try, pr.tries)
      return false, nil, nil
    end
    return true, nil, why
  end
  local parbits = 0
  if r.par ~= sdec.PAR_NONE then parbits = 1 end
  pr.phase, pr.label = 'done', nil
  return true, {T = sdec.bittime, nbits = r.nbits, par = r.par, nstop = r.nstop,
                invert = r.invert, framebits = 1 + r.nbits + parbits + r.nstop}, nil
end

-- The one-shot form: prime to completion in one call. Returns fmt, reason. The guard is a backstop on
-- the phase machine, not on the signal, so exceeding it is a coding fault. Derived rather than
-- constant: one sized for ck_bufmax's reserve is no backstop at the ck_win_min floor, where the same
-- reserve asks for an order of magnitude more tries. bufmax_for() can lower the cap at runtime.
function sdec.ck_prime(reader, ntotal, win, leadmax, skip)
  local pr, perr = sdec.ck_prime_new(reader, ntotal, win, leadmax, skip)
  if pr == nil then return nil, perr end
  local done, fmt, err, guard = false, nil, nil, 0
  local gmax = 4 + (sdec.ck_probes or 1) + 3 * (pr.tries or 1)
  while not done do
    done, fmt, err = sdec.ck_prime_step(pr)
    guard = guard + 1
    if guard > gmax then return nil, 'priming did not converge' end
  end
  if fmt == nil then return nil, err end
  return fmt, nil
end

-- ============================================================================
-- The chunked decode
-- ============================================================================
-- Walk the capture in windows, emitting each window's new bytes to a sink.
--
-- One carried number -- the position where the last emitted frame ended -- does continuation and
-- de-duplication at once. Comparing byte values instead would be unsound, repeated bytes being common.
-- docs/MEASUREMENTS.md, 'The seam: one carried number does continuation and de-duplication'.
--
-- A sink is sink(vals, errs, m, base) -> ok, receiving one window's new frames with base = how many
-- bytes preceded them, and returning false to stop the run. It must not retain vals/errs.
--
-- A slice is bounded in windows rather than seconds, the instrument having one timer and a window
-- count being deterministic. docs/MEASUREMENTS.md, 'Why a slice is bounded in windows',
-- 'Decode phase timings' and 'ck_smp_us = 73'.
sdec.ck_smp_us = 73               -- worst-phase cost per sample, microseconds, MEASURED at 4 sa/bit
sdec.ck_win_max = 20000           -- and never wider than this, whatever the budget allows
sdec.ck_win_min = 2000            -- nor narrower: below this the per-window seam overhead dominates
sdec.ck_win_ref = 20000           -- the width the phase timings above were taken at

-- Fraction of the budget for the phase itself; the rest pays for the sink's writes and the repaint.
sdec.ck_budget_frac = 0.9

-- What a decode window costs per sample, against ck_smp_us for the worst priming phase. One constant
-- for both pins a slice at one window. docs/MEASUREMENTS.md, 'ck_win_us = 48'.
sdec.ck_win_us = 48
-- Decode windows a slice should spend, as a bound on the width, the count following from it.
-- docs/MEASUREMENTS.md, 'ck_slice_n = 1'.
sdec.ck_slice_n = 1

-- The widest window whose every phase fits `budget_s`; nil means the fixed maximum, no panel to protect.
function sdec.ck_win_for(budget_s)
  local wmax = sdec.ck_win_max or 20000
  if budget_s == nil or budget_s <= 0 then return wmax end
  -- ck_budget_frac is applied here and nowhere else: every phase's cost is proportional to the width,
  -- so trimming W once covers the priming phases and the decode slices together.
  local b = budget_s * (sdec.ck_budget_frac or 1)
  local w = math.floor(b / ((sdec.ck_smp_us or 52) * 1e-6))
  -- Narrow enough that ck_slice_n decode windows also fit. Two bounds on one job, the smaller wins.
  local wd = math.floor(b / ((sdec.ck_slice_n or 1) *
                             (sdec.ck_win_us or sdec.ck_smp_us or 52) * 1e-6))
  if wd < w then w = wd end
  if w > wmax then w = wmax end
  if w < (sdec.ck_win_min or 2000) then w = sdec.ck_win_min or 2000 end
  return w
end

-- How many windows fit in a latency budget, never fewer than one. per_us defaults to the worst phase.
function sdec.ck_slice_win(budget_s, W, per_us)
  if budget_s == nil or budget_s <= 0 then return nil end       -- nil = unlimited
  local per = (W or sdec.ck_win_ref or 20000) * ((per_us or sdec.ck_smp_us or 52) * 1e-6)
  if per <= 0 then return nil end
  local n = math.floor(budget_s / per)
  if n < 1 then n = 1 end
  return n
end

-- Walk a capture window by window, emitting bytes to a sink; resumable via opts.resume. Returns a
-- totals table, or nil plus a reason.
function sdec.ck_decode(reader, ntotal, fmt, sink, opts)
  if reader == nil then return nil, 'no sample source' end
  if fmt == nil or fmt.T == nil then return nil, 'no format' end
  if opts == nil then opts = {} end
  local win = opts.win
  if win == nil then return nil, 'no window table' end

  local T, framebits = fmt.T, fmt.framebits
  local W, ov, stride, why = sdec.ck_geometry(T, framebits)
  if W == nil then return nil, why end

  -- `opts.nocap` exists because Lua cannot tell "key absent" from "key = nil": plain
  -- `opts.maxbytes or sdec.ck_maxbytes` would cap a caller that meant unlimited.
  local maxbytes = opts.maxbytes
  if maxbytes == nil and not opts.nocap then maxbytes = sdec.ck_maxbytes end
  local progress = opts.progress
  local nwin = sdec.ck_nwin(ntotal, W, stride)

  local tot = {nf = 0, ngood = 0, nbad = 0, nfalse = 0, nwin = 0, nwin_est = nwin,
               nsmp = 0, stopped = nil, W = W, overlap = ov, stride = stride}

  -- Absolute position where the last emitted frame ended; nil tells the first window to anchor.
  local endpos = nil
  local off = 0                 -- absolute 0-based offset of the current window

  -- Resuming a suspended run: the loop's whole carried state is window cursor, seam and totals. The
  -- sink is not part of it -- it holds an open handle and a partial row, so it must be the same one.
  if opts.resume ~= nil then
    off = opts.resume.off or 0
    endpos = opts.resume.endpos
    if opts.resume.tot ~= nil then tot = opts.resume.tot end
    tot.suspended = nil
    tot.nwin_est = nwin
  end

  local slice = sdec.ck_slice_win(opts.budget_s, W, sdec.ck_win_us)
  local spent = 0

  -- Reuse the window priming read, saving 0.435 s; cleared before the loop so a resumed slice cannot
  -- inherit it. All four conditions are load-bearing: docs/MEASUREMENTS.md, 'The four window-reuse
  -- conditions' and 'Window reuse between priming and decode'.
  local primed = opts.primed
  opts.primed = nil
  local reuse = (primed ~= nil and off == 0 and opts.resume == nil and primed.W == W and
                 primed.at == 1)

  while true do
    local cnt
    if reuse then
      cnt, reuse = primed.cnt, false
    else
      cnt = reader(win, off + 1, W)
    end
    if cnt == nil or cnt < 2 then break end

    -- Edges are per window and levels are not: sig_edges reads sdec.thr and sdec.hyst, which ck_prime
    -- set once. ei and es are the one per-window allocation, ~900 edges against 20 000 samples.
    sdec.sig_edges(win, cnt)

    local tmin0 = nil
    if endpos ~= nil then tmin0 = endpos - off end
    local r = sdec.ua_run(win, cnt, T, fmt.nbits, fmt.par, fmt.nstop, fmt.invert,
                          tmin0)

    tot.nwin = tot.nwin + 1
    tot.nsmp = off + cnt
    tot.nfalse = tot.nfalse + r.nfalse

    local m = r.nf
    -- Clip at the cap, mid-window if need be: emitting the whole window and then noticing overshoots.
    if m > 0 and maxbytes ~= nil and tot.nf + m > maxbytes then
      m = maxbytes - tot.nf
      if m < 0 then m = 0 end
      tot.stopped = 'cap'
    end

    if m > 0 then
      local i
      for i = 1, m do
        if r.errs[i] == nil then tot.ngood = tot.ngood + 1
        else tot.nbad = tot.nbad + 1 end
      end
      -- The window that produced the first bytes is the only one whose head can be a misaligned start,
      -- and tot.nf == 0 here -- inside the emit, before the increment -- identifies it. Tested outside
      -- this block it stays true into window 2, whose head is a seam the overlap already handles.
      if tot.nf == 0 and r.headsusp ~= nil and r.headsusp > 0 then
        tot.headsusp = r.headsusp
        -- headsusp is a region, not a count of bad bytes, and only here has the head.
        -- docs/MEASUREMENTS.md, 'headsusp is a region, not a count'.
        local hb, hn, hi = 0, 0, nil
        for hi = 1, r.headsusp do
          if r.errs[hi] ~= nil then
            hb = hi
            hn = hn + 1
          end
        end
        if hb > 0 then
          tot.headbad = hb
          tot.headnbad = hn
        end
      end
      local sok = true
      if sink ~= nil then sok = sink(r.vals, r.errs, m, tot.nf) end
      tot.nf = tot.nf + m
      if sok == false then
        tot.stopped = 'sink'
        break
      end
      -- Only advance the seam over frames emitted: carrying the unclipped window's end would
      -- leave the seam past bytes the file never received, a silent hole in a run that resumes.
      endpos = off + r.tpos[m] + (framebits - 0.5) * T
    end

    if tot.stopped == 'cap' then break end

    -- The window is the progress tick, so no clock is needed: a window is a few hundred milliseconds of
    -- decoding, already about the 1 Hz the panel wants, and it is one settext rather than a ui_refresh()
    -- over ~20 objects. It is also the stop check, which only a host-driven caller can reach.
    if progress ~= nil then
      if progress(tot.nf, tot.nwin, nwin) == false then
        tot.stopped = 'stopped'
        break
      end
    end

    -- Not 'exhausted' here: running out of samples is also how a short stream ends, and ck_decode
    -- cannot tell the two apart. stream_decode() and decode_step() know, and set it.
    if ntotal ~= nil and off + cnt >= ntotal then break end
    if cnt < W then
      tot.stopped = 'short read'
      break
    end
    off = off + stride

    -- Suspend, after the cursor advances and after every termination test, so a resume starts on a
    -- window not yet decoded and the loop's own conditions, not the budget, decide that a run is done.
    spent = spent + 1
    if slice ~= nil and spent >= slice then
      tot.suspended = {off = off, endpos = endpos, tot = tot}
      return tot, nil
    end
  end

  -- `maxbytes ~= nil` first, and not `(maxbytes or 0)`: with no cap that reads `nf >= 0`, true of every
  -- run including an empty one, and every stream would report itself truncated.
  if tot.stopped == nil and maxbytes ~= nil and tot.nf >= maxbytes then
    tot.stopped = 'cap'
  end
  return tot, nil
end

-- ============================================================================
-- Sinks
-- ============================================================================
-- Accumulate into caller-supplied arrays, for a dry run and for the offline suite. Positions come from
-- `base`, the offset ck_decode has committed to, so a mis-stepped seam is a wrong byte at a known index.
function sdec.ck_sink_collect(vals, errs)
  return function(v, e, m, base)
    local i
    for i = 1, m do
      vals[base + i] = v[i]
      if errs ~= nil then errs[base + i] = e[i] end
    end
    return true
  end
end

-- Append to a file on the USB key, as the same hex+ASCII rows the panel and the debug log use, so a row
-- compares across all three. Rows are 16 bytes and a window boundary is not, so leftover bytes are
-- carried rather than emitted short, which would skew every offset after the seam. Returns sink, finish.
function sdec.ck_sink_file(path, ncol)
  if ncol == nil then ncol = 16 end
  -- MODE_APPEND, not MODE_WRITE: this sink writes to the shared byte log that frame mode also appends
  -- to, so opening for write silently truncates it. ulog.open_write, for its no-key gate and reason.
  local fh, owhy = ulog.open_write(path, file.MODE_APPEND)
  if fh == nil then return nil, nil, 'cannot append to ' .. tostring(path) end
  -- A header, so a stream's rows are distinguishable from a frame capture's in one file -- and the
  -- sink's first write, so its failure is the sink's: an unlabelled stream is what it exists to stop.
  local hdr = string.format('---- stream  %s %s\r\n',
                            sdec.baud_text and sdec.baud_text() or '?',
                            sdec.fmt_text and sdec.fmt_text() or '?')
  -- Bare, the refusal moving to the gate below: no file call transfers control, so a pcall here always
  -- returns true. docs/MEASUREMENTS.md, 'No file call raises'.
  file.write(fh, hdr)
  if ulog ~= nil and ulog.keyok ~= nil and not ulog.keyok() then
    file.close(fh)
    return nil, nil, 'cannot write the stream header to ' .. tostring(path)
  end

  local cv, ce, cn = {}, {}, 0     -- carry: bytes not yet a full row
  local cbase = 0                  -- stream offset of cv[1]
  local dead = false

  -- ua_hexrow pads ncol - nrow, so the file's last row keeps its ASCII gutter in column.
  local function emit(nrow)
    local line = sdec.ua_hexrow(cv, ce, nrow, 1, ncol, cbase)
    -- Before the write, and per row: a key pulled mid-recording does not fail a write in Lua, so
    -- without this a 32 kB recording wrote 2048 rows into nothing and put 2048 modal boxes on the
    -- panel. 237 us a row. docs/MEASUREMENTS.md, 'A key pulled from under a running app'.
    if not dead and ulog ~= nil and ulog.keyok ~= nil and not ulog.keyok() then dead = true end
    -- The write is bare and nothing here can set `dead`, so the carry shift below always runs: cn and
    -- cbase must never describe rows the file never got, and flog_bytes is counted on acceptance. Nor
    -- can ua_hexrow fail, so sink's loop calls emit bare.
    if not dead then file.write(fh, line .. '\r\n') end
    local i
    for i = nrow + 1, cn do
      cv[i - nrow] = cv[i]
      ce[i - nrow] = ce[i]
    end
    cn = cn - nrow
    cbase = cbase + nrow
  end

  local sink = function(v, e, m, base)
    if dead then return false end
    if cn == 0 then cbase = base end
    local i
    for i = 1, m do
      cn = cn + 1
      cv[cn] = v[i]
      ce[cn] = e[i]
    end
    -- Counted on acceptance, not emit: a byte in the carry is in the log's charge, and finish() flushes.
    sdec.flog_bytes = (sdec.flog_bytes or 0) + m
    while cn >= ncol and not dead do emit(ncol) end
    return not dead
  end

  -- Idempotent: a normal finish, a Mode press and a raised step all call this, and the raise path
  -- cannot know whether the normal path did. A double close is not harmless here, nor a double flush.
  local finished = false
  local finish = function()
    if finished then return not dead end
    finished = true
    -- The final row is guarded so the close is reached -- the exception to "no pcall on app code",
    -- because a stranded handle needs a power cycle, while a lost row is what `dead` reports.
    if not dead and cn > 0 then
      if not pcall(emit, cn) then dead = true end
    end
    -- Both bare: neither can transfer control (docs/MEASUREMENTS.md, 'No file call raises').
    file.flush(fh)
    file.close(fh)
    fh = nil
    -- A key pulled mid-stream posts 2200 and returns, so `dead` never saw it and the run reported a
    -- complete file. This presence check does, and it latches logging off. See ulog.keylost().
    if not dead and ulog ~= nil and ulog.keyok ~= nil and not ulog.keyok() then dead = true end
    return not dead
  end

  return sink, finish, nil
end

-- ============================================================================
-- The tail of a stream, kept so the panel has something to show when it ends
-- ============================================================================
-- A streaming run's product is a file, and for the length of the run that is right: 200 kB of decoded
-- bytes does not fit in this instrument's RAM. But the moment a run ends the operator is looking at a
-- blank panel and the bytes are on a key they would have to unplug, so a bounded tail is retained in a
-- fixed-size ring whose cost is the same whether the stream was 240 bytes or 240 kB. The tail and not
-- the head: a stream stopped by hand was stopped because of something that had just happened, one that
-- went quiet ended with the device's last word, and one that hit the cap has its most recent bytes
-- there. docs/MEASUREMENTS.md, 'ck_keep = 8192' for the size and the RAM it was measured against.
sdec.ck_keep = 8192

-- A fixed-size ring for the last bytes of a stream, so RAM does not grow with the run.
function sdec.ck_tail_new(cap)
  if cap == nil then cap = sdec.ck_keep end
  if cap == nil or cap < 1 then return nil end
  return {v = {}, e = {}, n = 0, w = 0, cap = cap}
end

-- Tee, not replacement: called alongside the run's own sink, so a write failure still propagates.
function sdec.ck_tail_push(tl, vals, errs, m, base)
  if tl == nil or m == nil or m < 1 then return end
  -- Skip straight to the last cap bytes of an over-long batch. The skip must still count: tl.w is the
  -- total ever pushed, not a ring cursor, and ck_tail_result() derives the absolute start from it.
  local i = 1
  if m > tl.cap then
    i = m - tl.cap + 1
    tl.w = tl.w + (i - 1)
    tl.n = tl.cap                      -- the skipped bytes are 'seen', and the ring is now full
  end
  while i <= m do
    local j = math.mod(tl.w, tl.cap) + 1
    tl.v[j], tl.e[j] = vals[i], errs[i]
    tl.w = tl.w + 1
    if tl.n < tl.cap then tl.n = tl.n + 1 end
    i = i + 1
  end
  if base ~= nil then tl.base = base end
end

-- Linearise into the shape sdec.res has, so every byte-view function works on it unchanged. `first` is
-- absolute, so the dump labels offsets truthfully; tpos is empty because lin_decode still indexes it.
function sdec.ck_tail_result(tl, fmt, ntotal)
  if tl == nil or tl.n < 1 then return nil end
  local r = {nf = tl.n, ngood = 0, nbad = 0, nfalse = 0,
             vals = {}, errs = {}, tpos = {}}
  local start = tl.w - tl.n                 -- 0-based index of the oldest kept byte
  local i
  for i = 1, tl.n do
    local j = math.mod(start + i - 1, tl.cap) + 1
    r.vals[i], r.errs[i] = tl.v[j], tl.e[j]
    if tl.e[j] == nil then r.ngood = r.ngood + 1 else r.nbad = r.nbad + 1 end
  end
  r.first = start + 1
  r.ntotal = ntotal                         -- how many the whole run decoded
  if fmt ~= nil then
    r.nbits, r.par, r.nstop = fmt.nbits, fmt.par, fmt.nstop
    r.invert, r.framebits = fmt.invert, fmt.framebits
  end
  return r
end

-- ============================================================================
-- One call, for the app to hang a button on
-- ============================================================================
-- Prime, then decode, then finish, with one window table shared by both halves so two 20 000-sample
-- arrays are never alive at once. A resumable run, because a 32 kB stream is over half a minute in one
-- button handler and nothing can interrupt it.
-- docs/MEASUREMENTS.md, 'Why ck_job is resumable'.
function sdec.ck_job_new(reader, ntotal, path, opts)
  if opts == nil then opts = {} end
  sdec.smp, sdec.nread = nil, 0

  local win = {}
  -- opts.leadmax is the acquisition's statement of the pre-trigger reserve. See ck_prime_tries.
  local pr, perr = sdec.ck_prime_new(reader, ntotal, win, opts.leadmax, opts.primeskip)
  if pr == nil then return nil, perr end
  opts.win = win

  return {reader = reader, ntotal = ntotal, path = path, opts = opts,
          prime = pr, phase = pr.label, fmt = nil, sink = nil, finish = nil,
          tail = nil, state = nil, done = false, tot = nil}, nil
end

-- The sink chain, built once priming has succeeded and not before: a recording with no findable format
-- must not have created its file first, leaving an empty numbered log on the key. opts.sink is an extra
-- destination chained ahead of the file, not a replacement, so the offline suite can collect the bytes
-- while the key gets them too; assigning over job.sink would discard the tail tee. Either may stop it.
function sdec.ck_job_sinks(job)
  local opts = job.opts
  local sink = opts.sink
  if job.path ~= nil then
    local fsink, ffin, fe = sdec.ck_sink_file(job.path, opts.ncol)
    if fsink == nil then return false, fe end
    job.finish = ffin
    if sink == nil then
      sink = fsink
    else
      local extra = sink
      sink = function(vals, errs, m, base)
        local a = extra(vals, errs, m, base)
        local b = fsink(vals, errs, m, base)
        return a ~= false and b ~= false
      end
    end
  end

  local tail = sdec.ck_tail_new(opts.keep)
  job.tail = tail
  if tail ~= nil then
    local inner = sink
    sink = function(vals, errs, m, base)
      sdec.ck_tail_push(tail, vals, errs, m, base)
      if inner == nil then return true end
      return inner(vals, errs, m, base)
    end
  end
  job.sink = sink
  return true, nil
end

-- One slice. Returns done, tot, err; done false means call again, repainting the panel in between.
function sdec.ck_job_step(job)
  if job == nil then return true, nil, 'no job' end
  if job.done then return true, job.tot, nil end

  -- Priming first, one phase per step. Nothing is decoded and no file is open yet, so a failure here
  -- needs no cleanup -- but it must still mark the job done, or the caller's loop steps it forever.
  if job.prime ~= nil then
    -- On a raise the first return is the message rather than a value, so copy out only when pok.
    local pok, pa, pb, pc = pcall(sdec.ck_prime_step, job.prime)
    local pdone, fmt, perr = true, nil, nil
    if pok then
      pdone, fmt, perr = pa, pb, pc
    else
      perr = tostring(pa)
    end
    job.phase = job.prime.label
    if not pdone then return false, nil, nil end
    -- The primed window, handed over before the priming state is dropped: both share the win table, so
    -- the count lets ck_decode skip re-reading it, and the position travels with it to be checked.
    if job.prime.W ~= nil then
      job.opts.primed = {cnt = job.prime.cnt, W = job.prime.W, at = job.prime.at}
    end
    job.prime = nil
    if fmt == nil then
      job.done, job.tot = true, nil
      return true, nil, tostring(perr or 'cannot prime the decode')
    end
    job.fmt = fmt
    local sok, serr = sdec.ck_job_sinks(job)
    if not sok then
      job.done, job.tot = true, nil
      return true, nil, tostring(serr or 'cannot open the log file')
    end
    job.phase = nil
    return false, nil, nil
  end

  -- Through pcall: ck_decode calls out to a reader, a progress callback, an extra sink, ua_run and the
  -- tail, and an escaping error would skip the cleanup below, stranding the USB handle until a cycle.
  job.opts.resume = job.state
  local tot, terr, praise = nil, nil, nil
  local pok, pa, pb = pcall(sdec.ck_decode, job.reader, job.ntotal, job.fmt, job.sink, job.opts)
  local perr = nil
  if pok then tot, terr = pa, pb else perr = pa end
  job.opts.resume = nil               -- unconditionally: a raise must not leave it set
  -- A mid-byte start belongs to the run, and tot does not survive a step: the headsusp from the first
  -- window a step emits is overwritten by the next step's, so job keeps the first non-nil answer.
  if tot ~= nil then
    if job.headsusp == nil then job.headsusp = tot.headsusp end
    if job.headbad == nil then job.headbad = tot.headbad end
    if job.headnbad == nil then job.headnbad = tot.headnbad end
    tot.headsusp, tot.headbad = job.headsusp, job.headbad
    tot.headnbad = job.headnbad
  end
  if not pok then
    tot, praise = nil, perr
  end

  if tot == nil then
    -- A raise or refusal mid-run still has to close the file, or the handle leaks to the next cycle.
    if job.finish ~= nil then pcall(job.finish) end
    job.done, job.tot, job.state = true, nil, nil
    return true, nil, tostring(praise or terr or 'chunked decode failed')
  end

  if tot.suspended ~= nil then
    job.state = tot.suspended
    job.tot = tot                     -- partial totals, so the panel can show real progress
    return false, tot, nil
  end

  -- done is set before finish() can raise: finish() flushes the carry through ua_hexrow, and with the
  -- job still unfinished the caller's loop would step it again and re-emit windows already written.
  job.done, job.tot, job.state = true, tot, nil
  tot.suspended = nil                 -- and drop the self-referential checkpoint
  if job.finish ~= nil then
    local fpok, fv = pcall(job.finish)
    local fok = fpok and fv
    if not fpok or not fok then tot.stopped = 'write failed' end
  end
  tot.fmt = job.fmt
  tot.path = job.path
  tot.tail = sdec.ck_tail_result(job.tail, job.fmt, tot.nf)
  -- The head verdict travels with the tail: bench_run reads res.headsusp off whatever sdec.res is, and
  -- the tail is now what the one-shot stream_decode publishes there.
  if tot.tail ~= nil then tot.tail.headsusp = tot.headsusp end
  return true, tot, nil
end

-- Abandon a job that will not be finished -- a Mode press, a stop, a mode change. Closes the file so
-- the rows already decoded survive, and returns the tail so they can still be shown.
function sdec.ck_job_abandon(job)
  if job == nil then return nil end
  if job.finish ~= nil and not job.done then pcall(job.finish) end
  -- prime goes too: a job abandoned mid-priming must not be resumable. It does not free the window
  -- table -- job.opts.win holds it as well -- so only dropping the job itself releases either.
  job.done, job.state, job.prime = true, nil, nil
  local tot = job.tot
  if tot ~= nil then
    -- Clear the checkpoint: tot.suspended.tot is tot, so returning it hands back a result that both
    -- claims to be finished and carries a self-referential offer of more work.
    tot.suspended = nil
    tot.stopped = tot.stopped or 'stopped'
    tot.fmt = job.fmt
    tot.path = job.path
    tot.tail = sdec.ck_tail_result(job.tail, job.fmt, tot.nf)
  end
  return tot
end

-- The unchunked form, kept because most callers want it: with no opts.budget_s, one slice runs.
function sdec.ck_run(reader, ntotal, path, opts)
  local job, jerr = sdec.ck_job_new(reader, ntotal, path, opts)
  if job == nil then return nil, jerr end
  local done, tot, err = false, nil, nil
  while not done do
    done, tot, err = sdec.ck_job_step(job)
  end
  if tot == nil then return nil, err end
  return tot, nil
end

-- One line for the panel and the log. A file that stopped at the cap is a window onto a longer stream.
function sdec.ck_summary(tot)
  if tot == nil then return 'no stream' end
  local extra = ''
  if tot.stopped == 'cap' then
    extra = string.format(' -- stopped at the %d byte cap; the stream may continue',
                          tot.nf or 0)
  elseif tot.stopped == 'exhausted' then
    extra = ' -- the CAPTURE BUFFER ran out before the cap; sample slower for more bytes'
  elseif tot.stopped == 'short read' then
    extra = ' -- the sample source ended early; part of the capture was never scanned'
  elseif tot.stopped == 'stopped' then
    -- A run with no path keeps only its tail, so citing a file would name something that does not exist.
    if tot.path == nil then
      extra = ' -- STOPPED by the operator; nothing was recorded, the panel holds the tail'
    else
      extra = ' -- STOPPED by the operator; the file holds what was decoded so far'
    end
  elseif tot.stopped == 'sink' or tot.stopped == 'write failed' then
    extra = ' -- WRITE FAILED part-way through'
  end
  -- Every counter defaulted, because a summary must not be able to raise: %d on a nil costs the whole
  -- line rather than one field. tot.nsmp is genuinely absent on the cancelled path.
  return string.format('%d bytes  %d err  %d win  %d samples%s',
                       tot.nf or 0, tot.nbad or 0, tot.nwin or 0, tot.nsmp or 0, tostring(extra))
end

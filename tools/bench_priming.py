#!/usr/bin/env python3
"""Time every step of a streaming decode on the instrument, priming phases included.

THIS IS THE VERIFICATION FOR THE PHASED PRIMING. `ck_prime` used to run inside the handler that
STOPS a recording -- up to eight contiguous 20 000-sample level probes plus a lead-in read plus edge
extraction plus the format search -- so that one press was unbounded while every slice after it was
bounded. Splitting it is only worth anything if each phase really lands inside sdec.ui_latency_s,
and that is a fact about the instrument, not about the code.

Needs no UI build: ck_job_* touch no display object, so this runs against the modules already
loaded and does not spend against the display-object pool (event 1701).

    python3 tools/bench_priming.py --baud 9600 --samples 400000
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dmmrun import DMM
from siglent import SDG
import bench_matrix as MX
import vector_names as VN                                     # noqa: E402

PRIME_TSP = r'''
function pr_run(baud, nsmp, budget)
  eventlog.clear()
  sdec.force_baud = baud
  sdec.force_nbits, sdec.force_par = nil, nil
  sdec.force_nstop, sdec.force_invert = nil, nil

  -- One long free-running capture, which is what a streaming recording leaves behind. acq_free
  -- with ncopy = 0 keeps the samples in the reading buffer rather than copying them into Lua --
  -- the whole point of ck_reader_buffer.
  -- fs_want as well as fs: hw_config() -> fs_select() resets the rate from the lock state, and
  -- nothing is locked on this path, so setting sdec.fs alone is silently undone.
  sdec.fs = sdec.fs_for_baud(baud)
  sdec.fs_want = sdec.fs
  sdec.n = nsmp
  sdec.hw_config()                      -- returns nothing; it configures and cannot refuse
  -- A recording needs a buffer that HOLDS it. The app's FRAME buffer is 20 000 readings, so
  -- without this the capture stops there and the run being timed is not the run of interest.
  if sdec.acq_make_buffer(nsmp) == nil then print('P fail buf') print('P end') return end
  timer.cleartime()
  local got = sdec.acq_free(nsmp, 0, true)
  print(string.format('P acq %d samples in %.3f s at %s S/s',
                      got or 0, timer.gettime(), tostring(sdec.acq_fs)))
  if got == nil or got < 2 then print('P fail acq') print('P end') return end

  -- The panel path's own width choice, so what is timed here is what a press actually pays.
  local W = sdec.ck_win_for(budget)
  sdec.ck_win_n, sdec.ck_level_max = W, W
  print(string.format('P win %d samples (%.3f s at %g us/sample)', W,
                      W * sdec.ck_smp_us * 1e-6, sdec.ck_smp_us))
  local job, jerr = sdec.ck_job_new(sdec.ck_reader_buffer(sdec.buf, got), got, nil,
                                    {budget_s = budget})
  if job == nil then print('P fail job ' .. tostring(jerr)) print('P end') return end

  local k, done, tot, err = 0, false, nil, nil
  while not done and k < 400 do
    local phase = job.phase
    if job.prime == nil and phase == nil then phase = 'window' end
    timer.cleartime()
    done, tot, err = sdec.ck_job_step(job)
    local dt = timer.gettime()
    k = k + 1
    print(string.format('S %d %s %.4f %s %s', k, tostring(phase), dt,
                        tostring(tot and tot.nf), tostring(err)))
  end
  print(string.format('P done steps=%d nf=%s ec=%d', k, tostring(tot and tot.nf),
                      eventlog.getcount()))
  print('P end')
end
print('===DONE===')
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--samples', type=int, default=400000,
                    help='recording length. Big enough that priming is a small part of it, '
                         'which is the case the phasing exists for.')
    ap.add_argument('--budget', type=float, default=0.5)
    ap.add_argument('--arb', default='v80')
    ap.add_argument('--load', action='store_true',
                    help='load the current decoder modules first. Needed after editing them; the '
                         'app on screen keeps its own copy until something reloads it.')
    a = ap.parse_args()

    g, d = SDG(), DMM()
    try:
        g.select_arb(VN.arb(a.arb), MX.amp_for(3.3), int(a.baud * MX.RATE_SPB))
        g.output(True, ch=1)
        time.sleep(0.4)
        # Resync: a harness that died mid-reply leaves one line in the socket, and every later
        # query then answers the question before it.
        d.send('print("SYNC")')
        for _ in range(8):
            if d.line(5) == 'SYNC':
                break
        if a.load:
            # The four modules ck_job_* actually need. NOT serial_ui/serial_app, and NO prelude
            # clearing sdec: every module opens with `sdec = sdec or {}`, so this redefines
            # functions in place and the screen already built stays live. Loading the UI modules
            # or rebuilding would spend against the display-object pool (event 1701).
            mods = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
                    'tsp/chunk_decode.tsp']
            body = ['-- ==== %s ====\n%s' % (m, open(m).read()) for m in mods]
            src = '\n'.join(body) + "\nprint('===DONE===')"
            print('loading %d bytes of decoder (no UI, no rebuild)...' % len(src))
            for ln in d.load_script('ckmod', src, timeout=300):
                if ln and ln != '===DONE===':
                    print('  load: ' + ln)
            probe = d.q('print(tostring(sdec.ck_win_for ~= nil), tostring(sdec.ck_smp_us))')
            print('  ck_win_for / ck_smp_us: %s' % probe)

        out = d.load_script('prmod', PRIME_TSP, timeout=120)
        for ln in out:
            if ln and ln != '===DONE===':
                print('  prmod: ' + ln)

        d.drain()
        d.send('pr_run(%d, %d, %g)' % (a.baud, a.samples, a.budget))
        steps = []
        while True:
            ln = d.line(600)
            if ln is None:
                print('  timeout')
                break
            f = ln.split()
            if f and f[0] == 'S' and len(f) >= 4:
                steps.append((int(f[1]), f[2], float(f[3]), f[4]))
            elif ln.startswith('P '):
                print('  ' + ln)
            if ln == 'P end':
                break
    finally:
        try:
            g.output(False, ch=1)
        except Exception:
            pass
        g.close()
        d.close()

    if not steps:
        return 1
    print('\n%-5s %-10s %8s  %s' % ('step', 'phase', 'seconds', 'bytes'))
    print('-' * 44)
    for k, phase, dt, nf in steps:
        flag = '  <-- OVER BUDGET' if dt > a.budget else ''
        if k <= 12 or dt > a.budget or k == len(steps):
            print('%-5d %-10s %8.4f  %s%s' % (k, phase, dt, nf, flag))
    worst = max(steps, key=lambda s: s[2])
    over = [s for s in steps if s[2] > a.budget]
    print('\n%d steps, worst %.4f s in phase %r' % (len(steps), worst[2], worst[1]))
    prime = [s for s in steps if s[1] not in ('window', 'nil')]
    if prime:
        print('priming: %d phases, worst %.4f s (%s)'
              % (len(prime), max(s[2] for s in prime),
                 ', '.join('%s %.3f' % (s[1], s[2]) for s in prime)))
    print('over the %.2f s budget: %d' % (a.budget, len(over)))
    return 0 if not over else 1


if __name__ == '__main__':
    sys.exit(main())

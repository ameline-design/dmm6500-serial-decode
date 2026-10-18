#!/usr/bin/env python3
"""Does the six-block elision program record a bursty line, on hardware?

WHY THIS IS NOT A SOAK CELL. Elision is gated on sdec.arm_silent(), which needs sdec.probe_idle, and
acquire() sets that only when the level probe finds NO transitions. The armed elision path exists for a
line that is quiet and then starts talking -- a device that has not spoken yet. A soak drives a
continuously looping arb, so the probe always lands on traffic, the gate never opens and every cell
falls back to the canned template: measured, 76 of 76 cells reading `elide=FELLBACK`.

So the stimulus has to be sequenced the way a real device behaves:

    1  hold CH1 at the MARK level as DC          an idle line, which is what the probe must see
    2  load the app, lock the rate, set the window, arm
    3  switch CH1 to the gap arb                 the device starts talking
    4  poll, then read the record back

Step 1 is DC at the mark rather than output OFF: off leaves the input floating and the threshold would
come from noise, where a real idle line sits at mark. Burst mode is not an option either -- BTWV
STATE,ON fakes an idle line and fails every stage of the existing stimulus checks.

WHAT A PASS LOOKS LIKE, and every one of these is checked rather than assumed:

    acq_elided true         the hand-built program ran, not the canned fallback. Without this the
                            capture can be perfect and prove nothing about elision.
    six blocks, no clear    the shape sdec.gap_model() builds since the clear moved to Lua
    more than one burst     the record holds traffic from several passes, which is the whole point:
                            a single burst is what a plain armed capture would have given
    bytes decode            the payload comes back, so the splices land between frames

    python3 tools/bench_elide.py                 v98a, 9600 8N1
    python3 tools/bench_elide.py --vector v99a   the 1000-bit-time lead, 7E1
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MARK_V = 3.0            # idle level of a 0-3 V logic line
ARB_AMP = 3.0
ARB_OFST = 1.5

# The window an operator would type. gap_elide() raises it to the two-frame floor for the locked rate,
# so this is a threshold and not the amount discarded.
WINDOW = 0.1


def main():
    # QUARANTINED, because this harness reports success by construction and its premise is gone.
    #
    # It cannot fail. The only SystemExits are "no arb mapped" and "gap_model is not a function"; the
    # four things the docstring above says are "checked rather than assumed" are printed and never
    # compared, "more than one burst" is never computed, and there is no decode call anywhere. main()
    # ends `return 0` on every path. A hardware harness that always passes is worse than none: it
    # answers a question it never asked.
    #
    # It also cannot work. Step 4 calls sdec.stream_poll(), which exists nowhere in this tree, so the
    # expression is `nil and ... or nil` and the record is never read back. The arb's envelope is never
    # commanded either -- `if False` makes the select_arb call dead, so ARB_AMP and ARB_OFST go unused
    # and the waveform plays at whatever amplitude was last set, on top of the +3.0 V DC offset from the
    # idle step. Both rails above ground is the exact condition the rest of this work exists to
    # characterise. --settle is declared and never referenced.
    #
    # And its reason for existing has been overtaken. The docstring argues a soak can never reach the
    # elision path -- "the gate never opens and every cell falls back: measured, 76 of 76". That was
    # true when it was written and is not now: bench/bench_run.tsp opens the gate itself, and the last
    # three laps elided 396 cells of 396. The soak is strictly better coverage than this file was for.
    #
    # Left in place rather than deleted so the sequencing argument in the docstring -- hold DC at mark,
    # arm, then switch to the arb -- is not lost, since that reasoning is still sound and is the thing
    # worth keeping. Repair it or delete it; do not run it.
    raise SystemExit(
        'REFUSING: tools/bench_elide.py is quarantined. It checks none of the four things its '
        'docstring claims, calls a sdec.stream_poll() that does not exist, and returns 0 on every '
        'path -- so a green result from it means nothing. Its premise is also stale: the soak now '
        'reaches the elision path by itself, 396 cells of 396. See the comment at the top of main().')

    ap = argparse.ArgumentParser()
    ap.add_argument('--vector', default='v98a')
    ap.add_argument('--baud', type=int, default=9600)
    ap.add_argument('--samples', type=int, default=20000)
    ap.add_argument('--settle', type=float, default=1.0,
                    help='seconds to hold the idle line before arming')
    a = ap.parse_args()

    import vector_names as VN
    from dmmrun import DMM, release_single_instance
    from siglent import SDG
    import run_app

    arb = (getattr(VN, 'MAP', {}) or {}).get(a.vector)
    if arb is None:
        raise SystemExit('REFUSING: no generator arb is mapped for %r' % a.vector)

    g = SDG()
    d = DMM(timeout=120)
    try:
        print('DMM:', str(d.q('*IDN?')).strip())
        print('SDG:', str(g.idn()).strip())

        # STEP 1, BEFORE THE APP LOADS. The probe runs inside the arm and has to see an idle line, so the
        # mark level must already be there -- not switched on afterwards.
        print('\nholding CH1 at %.1f V DC (idle at mark)' % MARK_V)
        g.write('C1:BTWV STATE,OFF')
        g.write('C1:BSWV WVTP,DC,OFST,%.3f' % MARK_V)
        g.output(True, ch=1)

        print('loading the app')
        run_app.load_app(d, verbose=False)
        # READ A FIELD THIS TREE ADDED, not type(sdec): a stale app answers 'table' just as well, and
        # the whole question here is whether the SIX-block program is the one running.
        chk = str(d.q('print(tostring(type(sdec.gap_model)) .. "," .. tostring(sdec.gapelide_frames))')
                  or '').strip()
        print('  gap_model, gapelide_frames = %s' % chk)
        if not chk.startswith('function'):
            raise SystemExit('REFUSING: sdec.gap_model is not a function on this instrument (%s)' % chk)

        # STEP 2. The rate is locked because gap_elide() refuses without one, and the trigger is armed
        # because free run cannot elide at all.
        setup = """
sdec.force_baud = %d
sdec.gapelide = %r
sdec.trigmode = 'edge'
sdec.clear_measured()
sdec.hw_config()
-- PERMANENT, as brun.point's elide branch asks for it. Without the second argument this probe
-- allocates a capture-sized record and reproduces the wrap the permanent buffer exists to stop,
-- which would make the dedicated elision probe the one tool that cannot see the fix.
sdec.acq_make_buffer(sdec.acq_cap(%d), true)
local pn = sdec.probe_n
if pn > %d then pn = %d end
local got = sdec.acq_free(pn, nil, true)
local lok, lwhy = sdec.sig_levels(sdec.smp, sdec.nread)
-- THE IDLE MARKER IS THE GATE. sig_levels FAILING for want of transitions is the normal and wanted
-- outcome here, and it is what sets probe_idle; a success would mean the line was still talking and
-- arm_silent() would refuse the arm.
if not lok then
  if sdec.arm_threshold() then sdec.probe_idle = lwhy end
end
print(string.format('ELPROBE got=%%d levels=%%s why=%%s thr=%%s idle=%%s',
                    got, tostring(lok), tostring(lwhy), tostring(sdec.arm_thr),
                    tostring(sdec.probe_idle)))
print('ELSILENT ' .. tostring(sdec.arm_silent()))
""" % (a.baud, WINDOW, a.samples, a.samples, a.samples)
        for ln in (d.load_script('elsetup', setup, run=True, timeout=120) or []):
            s = str(ln).strip()
            if s.startswith('EL'):
                print('  ' + s)

        # STEP 3 and 4 in ONE instrument chunk, because the arm must be live before the arb starts and
        # the host cannot be in the middle of that: a socket command to a parked model kills it.
        # The generator is switched from here, which is the one thing the host must do in between -- so
        # the arm is left running and the switch happens while it waits.
        print('\narming, then starting the arb')
        d.send("""
ELREC = nil
local ok = sdec.stream_arm(%d)
print('ELARM armed=' .. tostring(ok) .. ' elide=' .. tostring(sdec.strm_elide)
      .. ' elided=' .. tostring(sdec.acq_elided))
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local _, nb = string.gsub(bl, '%%d+%%)', '')
local clear = 'no'
if string.find(bl, 'BUFFER_CLEAR', 1, true) ~= nil then clear = 'yes' end
print('ELBLOCKS n=' .. tostring(nb) .. ' bufferclear=' .. clear)
""" % a.samples)

        g.select_arb(arb, ARB_AMP, None, offset_v=ARB_OFST, ch=1) \
            if False else g.write('C1:ARWV NAME,%s' % arb)
        print('  switched CH1 to %s' % arb)

        out = d.load_script('elpoll', """
local n = sdec.stream_poll and sdec.stream_poll() or nil
print('ELPOLL ' .. tostring(n))
""", run=True, timeout=180) or []
        for ln in out:
            s = str(ln).strip()
            if s.startswith('EL'):
                print('  ' + s)
    finally:
        try:
            g.output(False, ch=1)
        finally:
            g.close()
            d.close()
            release_single_instance()
    return 0


if __name__ == '__main__':
    sys.exit(main())

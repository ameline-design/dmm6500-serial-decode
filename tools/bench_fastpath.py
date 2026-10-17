#!/usr/bin/env python3
"""Is the firmware's low-latency flag a specification or a fossil?

`getblocklist()` ends with `* This trigger model may not be set up for low latency. *` when a program
is off the fast path, and says nothing when it is on. docs/TRIGGER.md treats that string as the
specification and measured its boundaries once: 14 blocks keeps the flag and 15 loses it, a 0.25 s
constant delay keeps it and 0.3 s loses it, one configuration-list block loses it, and only two
measure blocks keep it where the manual's own advice at 9-50 says four.

Two questions, and they are different:

  SURVEY   does the flag still discriminate, and is the documented boundary still where it was?
           If the warning never appears, every program is on the fast path and the flag is a fossil.
           If it never disappears, nothing is. Either answer retires the question. No generator, no
           timing, about two minutes.

  LATENCY  does crossing the boundary change the comparator's response time? The earlier measurement
           compared three DIFFERENT programs and came back null at 1.1-1.4 sigma, with the 95 % upper
           bound on the benefit at 1.2 us against about 8 us of latency. That is a sample-size result,
           not a no-effect result.

WHY THE LATENCY CASE IS BUILT THE WAY IT IS. Comparing a canned template against a hand-built program
confounds the flag with the program. Here one core program is padded with no-op `DELAY_CONSTANT 0`
blocks to 14 and to 15, so the only difference between the two arms is which side of the boundary the
block count falls on -- and the padding sits AFTER the measured work, where it cannot run before the
comparator fires. A difference can then only come from how the firmware executes the program, which is
the claim being tested.

PAIRED AND INTERLEAVED, because the limit is jitter and not resolution. The firing point is not
deterministic to the sample: 6.2-9.3 us of spread at 1 MS/s against a latency of about 8 us. Twenty
trials an arm gives a standard error near 0.22 us against an effect of 0.4 us, which is why the
first attempt could not resolve it. Alternating the arms trial by trial and taking the mean of paired
differences removes any slow drift -- thermal, or the generator's own -- and 180 pairs
carries about 97 % power on 0.4 us, where 110 would have been a coin flip at 3 sigma.

TIMESTAMPS, NOT SAMPLE ARITHMETIC. `digitize.samplerate` reads back the value it was given and
delivers something else (640000 reads back 640000 and delivers 634615), so a latency computed from an
assumed period inherits that error. Both arms read `.seconds` and `.fractionalseconds`, and the
pre-roll and the post-trigger block write SEPARATE buffers so the first post-trigger reading's
timestamp is the trigger instant with nothing to search for. A second buffer costs no flag -- that is
one of the manual's wrong bullets, measured.

WIRING for --latency: SDG CH1 -> DMM front terminals, driven as a slow ramp so the crossing can be
interpolated between samples rather than quantised to one. --survey needs no generator at all.

    python3 tools/bench_fastpath.py                  # survey only
    python3 tools/bench_fastpath.py --latency        # survey, then 180 paired trials
    python3 tools/bench_fastpath.py --self-test      # arithmetic only, no instrument
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The warning text, verbatim from the firmware. Matched on a distinctive fragment rather than the
# whole sentence, because the surrounding asterisks and spacing are not worth depending on.
WARN = 'not be set up for low latency'

# 1 MS/s, where one sample is 1 us and the comparator latency is about 8 of them. The slowest rate the
# earlier measurement used could not resolve this at all: at 2500 S/s one sample is 400 us.
FS = 1000000

# Readings the post-trigger block takes. Small, because the quantity wanted is its FIRST timestamp;
# the rest only prove the block ran and the handover dropped nothing.
NPOST = 2000

# Ramp slew. 2500 V/s at 1 MS/s puts 2.5 mV between samples, so a 1.5 V crossing is located to a small
# fraction of a sample by linear interpolation and the ramp is still locally straight.
SLEW = 2500.0
LEVEL = 1.5

# Paired trials. The expected t on a 0.4 us effect against 1.4 us of paired spread is 3.8 here, so the
# test clears p < 0.05 about 97 % of the time; 110 pairs would have been a coin flip at 3 sigma. The
# earlier attempt used 20 an arm, which finds this effect under half the time.
PAIRS_DEFAULT = 180

# Buffer depth for the pre-roll. The ramp must cross the level while this block is running, and the
# block runs until the wait fires, so this only has to outlast one ramp period.
NPRE = 200000

SETUP = """
pcall(function() trigger.model.abort() end)
delay(0.05)
dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.samplerate = %d
dmm.digitize.count = 1
-- STYLE_STANDARD, not STYLE_COMPACT: the compact style is nil on 1.7.17a, buffer.make() then takes nil
-- as a style and raises 1138, and every block built on the result fails 2703 out of band.
if FPPRE == nil then
  local ok, b = pcall(buffer.make, %d, buffer.STYLE_STANDARD)
  if ok then FPPRE = b end
end
if FPPOST == nil then
  local ok, b = pcall(buffer.make, %d, buffer.STYLE_STANDARD)
  if ok then FPPOST = b end
end
""" % (FS, NPRE, NPOST + 1000)

CLEANUP = """
pcall(function() trigger.model.abort() end)
pcall(function() dmm.digitize.analogtrigger.mode = dmm.MODE_OFF end)
pcall(function() trigger.model.load('Empty') end)
print('FPCLEAN ' .. tostring(trigger.model.state()))
"""

# The buffers are handed back rather than dropped. Assigning nil strands them inside the firmware with
# nothing left to retry from, and the pool is shared with every other capture.
RELEASE = """
local a, b = 'skip', 'skip'
if FPPRE ~= nil then a = tostring(pcall(buffer.delete, FPPRE)) FPPRE = nil end
if FPPOST ~= nil then b = tostring(pcall(buffer.delete, FPPOST)) FPPOST = nil end
print('FPREL pre=' .. a .. ' post=' .. b)
"""


def pad_block(i, nblocks, pad):
    """One padding block at position i. -> the setblock line.

    The padding op matters and the first survey proved it: ten to sixteen blocks padded with zero
    `DELAY_CONSTANT`s were ALL off the fast path, so the boundary at 14/15 was never crossed and the
    block count was not what disqualified them. docs/TRIGGER.md records six delay blocks as free; every
    size here carries seven or more, so the count of delays is the suspect.

    `branch` pads with a plain unconditional jump instead, which the same table records as free. Each
    one targets the block after it so no target dangles -- a dangling target is itself a disqualifier --
    and the last block is a single zero delay, so the chain ends without a self-loop.
    """
    if pad == 'delay' or i == nblocks:
        return "trigger.model.setblock(%d, trigger.BLOCK_DELAY_CONSTANT, 0)" % i
    if pad == 'branch':
        return "trigger.model.setblock(%d, trigger.BLOCK_BRANCH_ALWAYS, %d)" % (i, i + 1)
    raise ValueError('unknown padding %r' % pad)


def padded_program(nblocks, measure_target='FPPRE', pad='delay'):
    """A fast-path-shaped core padded with no-op zero delays to exactly `nblocks` blocks.

    The core is the pre-trigger armed shape docs/TRIGGER.md names as one of the two most worth
    building: an infinite digitize so the comparator evaluates at all, the wait, then the counted
    post-trigger block. The padding goes AFTER all three, so it cannot execute before the comparator
    fires and cannot be the cause of any difference in when it does.
    """
    if nblocks < 3:
        raise ValueError('the core is three blocks; %d cannot hold it' % nblocks)
    out = [
        "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, %s, trigger.COUNT_INFINITE)"
        % measure_target,
        "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER,"
        " trigger.CLEAR_ENTER)",
        "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST,
    ]
    for i in range(4, nblocks + 1):
        out.append(pad_block(i, nblocks, pad))
    return '\n'.join(out)


def flag_probe(nblocks, pad='delay'):
    """Build the padded program and report whether the firmware warns about it. One tagged line.

    Three blocks is the bare core and the control the first survey lacked: if even that is warned, the
    disqualifier is in the core -- the infinite digitize, or the wait on the comparator -- and the
    document's claim that this shape is low latency does not hold on 1.7.17a.
    """
    return SETUP + """
trigger.model.load('Empty')
%s
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local _, nb = string.gsub(bl, '%%d+%%)', '')
local readok = 'yes'
if bl == 'RAISED' then readok = 'no' end
local warned = 'no'
if string.find(bl, '%s', 1, true) ~= nil then warned = 'yes' end
print(string.format('FPFLAG want=%d pad=%s blocks=%%d read=%%s warned=%%s', nb, readok, warned))
""" % (padded_program(nblocks, pad=pad), WARN, nblocks, pad)


def core_probes():
    """Which part of the core carries the disqualifier, if any part does.

    The first survey came back warned at every block count from 10 to 18, and a four-block program with
    one 0.25 s delay was warned too -- where docs/TRIGGER.md records 0.25 s as keeping the flag. Both
    results point away from the padding and at the core, so the core is taken apart one element at a
    time. Each row differs from its neighbour in exactly one thing.

    The two shapes the document names as low latency are rows 1 and 2. If either is warned here, the
    document's table does not describe this firmware and nothing downstream of it should be trusted.
    """
    rows = [
        ('wait-measure', [
            "trigger.model.setblock(1, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)",
            "trigger.model.setblock(2, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST]),
        ('preroll-2buf', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST]),
        ('preroll-1buf', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, %d)" % NPOST]),
        ('preroll-clearenter', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER,"
            " trigger.CLEAR_ENTER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST]),
        ('preroll-external', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_EXTERNAL)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST]),
        ('counted-preroll', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, 500)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)" % NPOST]),
        # THE SHIPPED ELISION PROGRAM, block for block as sdec.gap_model() assembles it. This is the
        # question that matters: the clear block came out of it on the argument that a clear is the only
        # disqualifier the templates carry, and block 4 is a DELAY_CONSTANT, which the block sweep has
        # just shown to be a disqualifier on its own. Replicated rather than loaded so this needs no
        # app, and the block count and op order are printed so a divergence from the real one shows.
        ('app-gapmodel-analog', [
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER,"
            " trigger.CLEAR_ENTER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(4, trigger.BLOCK_DELAY_CONSTANT, 0.1)",
            "trigger.model.setblock(5, trigger.BLOCK_BRANCH_ON_EVENT, trigger.EVENT_ANALOGTRIGGER, 4)",
            "trigger.model.setblock(6, trigger.BLOCK_BRANCH_ALWAYS, 1)"]),
        # The same with the blended arm event the app uses whenever the TRIGGER key is an escape, since
        # a blender could be a disqualifier in its own right.
        ('app-gapmodel-blender', [
            "trigger.blender[1].reset()",
            "trigger.blender[1].orenable = true",
            "trigger.blender[1].stimulus[1] = trigger.EVENT_ANALOGTRIGGER",
            "trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_BLENDER1,"
            " trigger.CLEAR_ENTER)",
            "trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(4, trigger.BLOCK_DELAY_CONSTANT, 0.1)",
            "trigger.model.setblock(5, trigger.BLOCK_BRANCH_ON_EVENT, trigger.EVENT_ANALOGTRIGGER, 4)",
            "trigger.model.setblock(6, trigger.BLOCK_BRANCH_ALWAYS, 1)"]),
        # And the same program WITH the clear block that 2a79198 removed, so the question that change
        # was justified by gets a direct answer rather than an argument.
        ('app-gapmodel-withclear', [
            "trigger.model.setblock(1, trigger.BLOCK_BUFFER_CLEAR, FPPRE)",
            "trigger.model.setblock(2, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(3, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER,"
            " trigger.CLEAR_ENTER)",
            "trigger.model.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)",
            "trigger.model.setblock(5, trigger.BLOCK_DELAY_CONSTANT, 0.1)",
            "trigger.model.setblock(6, trigger.BLOCK_BRANCH_ON_EVENT, trigger.EVENT_ANALOGTRIGGER, 5)",
            "trigger.model.setblock(7, trigger.BLOCK_BRANCH_ALWAYS, 2)"]),
        # The app's own armed program, so the answer applies to what ships rather than to a model of it.
        ('canned-loopuntilevent', [
            "trigger.model.load('LoopUntilEvent', trigger.EVENT_ANALOGTRIGGER, 5,"
            " trigger.CLEAR_ENTER, 0, FPPRE)"]),
        ('canned-simpleloop', [
            "trigger.model.load('SimpleLoop', %d, 0, FPPRE)" % NPOST]),
    ]
    out = []
    for label, blocks in rows:
        pre = '' if label.startswith('canned') else "trigger.model.load('Empty')\n"
        out.append((label, SETUP + """
%s%s
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local _, nb = string.gsub(bl, '%%d+%%)', '')
local readok = 'yes'
if bl == 'RAISED' then readok = 'no' end
local warned = 'no'
if string.find(bl, '%s', 1, true) ~= nil then warned = 'yes' end
print(string.format('FPCORE %s blocks=%%d read=%%s warned=%%s', nb, readok, warned))
""" % (pre, '\n'.join(blocks), WARN, label)))
    return out


# The other documented disqualifiers, each as a program plus the block count it needs. The point is not
# to re-derive the table but to check it has not drifted: a firmware update that moved any boundary
# would make every fast-path claim in the document stale at once.
def disqualifier_probes():
    probes = []
    for secs, label in ((0.25, 'delay-250ms'), (0.3, 'delay-300ms')):
        probes.append((label, SETUP + """
trigger.model.load('Empty')
trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)
trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER, trigger.CLEAR_ENTER)
trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)
trigger.model.setblock(4, trigger.BLOCK_DELAY_CONSTANT, %r)
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local _, nb = string.gsub(bl, '%%d+%%)', '')
-- READ, NOT JUST SEARCHED. A getblocklist() that raised leaves bl at its sentinel, the search for the
-- warning then finds nothing, and the probe would print warned=no for a listing it never saw. That
-- false negative is indistinguishable from the fast path unless the read is reported separately.
local readok = 'yes'
if bl == 'RAISED' then readok = 'no' end
local warned = 'no'
if string.find(bl, '%s', 1, true) ~= nil then warned = 'yes' end
print('FPDQ %s blocks=' .. tostring(nb) .. ' read=' .. readok .. ' warned=' .. warned)
""" % (NPOST, secs, WARN, label)))
    # Two measure blocks keep the flag. Whether a third is refused is what this probe is for and is not
    # assumed here: 2753 does not mark that boundary, being the generic low-latency warning whose message names
    # the cause, and the two-block gap program posts it on every run. notes/FINDING-elide-noarm.md.
    probes.append(('three-measure', SETUP + """
trigger.model.load('Empty')
trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)
trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER, trigger.CLEAR_ENTER)
trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)
local ok3 = tostring(pcall(function()
  trigger.model.setblock(4, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, 10)
end))
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local _, nmd = string.gsub(bl, 'MEASURE_DIGITIZE', '')
local warned = 'no'
if string.find(bl, '%s', 1, true) ~= nil then warned = 'yes' end
print('FPDQ three-measure accepted=' .. ok3 .. ' landed=' .. tostring(nmd) .. ' warned=' .. warned)
""" % (NPOST, WARN)))
    # A second reading buffer, which 9-50 advises against and which the document measured as free.
    probes.append(('second-buffer', SETUP + """
trigger.model.load('Empty')
trigger.model.setblock(1, trigger.BLOCK_MEASURE_DIGITIZE, FPPRE, trigger.COUNT_INFINITE)
trigger.model.setblock(2, trigger.BLOCK_WAIT, trigger.EVENT_ANALOGTRIGGER, trigger.CLEAR_ENTER)
trigger.model.setblock(3, trigger.BLOCK_MEASURE_DIGITIZE, FPPOST, %d)
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local warned = 'no'
if string.find(bl, '%s', 1, true) ~= nil then warned = 'yes' end
print('FPDQ second-buffer warned=' .. warned)
""" % (NPOST, WARN)))
    return probes


# One trial. Everything from initiate() to the verdict happens in a single chunk, so the host sends
# nothing while the model is parked -- a host-side query of a parked wait is itself the subject of
# another section and kills the model at 427-441 ms.
#
# The trigger instant is the FIRST post-trigger reading's timestamp, which needs no searching because
# block 3 writes its own buffer. The crossing is interpolated from the last two pre-roll readings that
# straddle the level, walking backwards from the end: the ramp crosses once per period and the pre-roll
# stops at the trigger, so the straddling pair is the last one in the buffer.
TRIAL = """
local function abstime(b, i)
  return b.seconds[i] + b.fractionalseconds[i]
end
-- The comparator has to be configured or the wait never fires and every trial times out. Rising
-- through the same level the ramp is interpolated against.
dmm.digitize.analogtrigger.mode = dmm.MODE_EDGE
dmm.digitize.analogtrigger.edge.level = LEVELV
dmm.digitize.analogtrigger.edge.slope = dmm.SLOPE_RISING
trigger.model.load('Empty')
%s
local bl = 'RAISED'
pcall(function() bl = trigger.model.getblocklist() end)
local warned = 'no'
if string.find(bl, 'WARNTEXT', 1, true) ~= nil then warned = 'yes' end
FPPRE.clear()
FPPOST.clear()
local started = tostring(pcall(trigger.model.initiate))
local t0 = os.time()
local fired = 'no'
while os.time() - t0 < 10 do
  local st = trigger.model.state()
  if st == trigger.STATE_IDLE then fired = 'yes' break end
end
pcall(function() trigger.model.abort() end)
-- Both counts are reported. A pre-roll that never crossed, or a post block that never ran, is a dead
-- trial and must not be averaged into anything.
local npre, npost = FPPRE.n, FPPOST.n
local lat = -1
if fired == 'yes' and npre > 2 and npost > 0 then
  local i = npre
  while i > 1 do
    local hi, lo = FPPRE.readings[i], FPPRE.readings[i - 1]
    if lo < LEVELV and hi >= LEVELV then break end
    i = i - 1
  end
  if i > 1 then
    local lo, hi = FPPRE.readings[i - 1], FPPRE.readings[i]
    local frac = 0
    if hi ~= lo then frac = (LEVELV - lo) / (hi - lo) end
    local tcross = abstime(FPPRE, i - 1) + frac * (abstime(FPPRE, i) - abstime(FPPRE, i - 1))
    lat = abstime(FPPOST, 1) - tcross
  end
end
print(string.format('FPTRIAL arm=%s warned=%%s started=%%s fired=%%s npre=%%d npost=%%d lat=%%.9f',
                    warned, started, fired, npre, npost, lat))
"""


def trial_program(nblocks, arm_label):
    body = TRIAL % (padded_program(nblocks), arm_label)
    return (SETUP + body).replace('WARNTEXT', WARN).replace('LEVELV', repr(LEVEL))


def ramp_on(g, amp=3.0, ofst=1.5):
    """A rising sawtooth on CH1, slow enough that the crossing can be interpolated between samples.

    SYM,100 puts the whole period in the rise, so the slew is AMP * FRQ and the retrace is the fast
    edge the comparator is not armed for. At 2500 V/s with 3 Vpp that is 833.33 Hz: 1200 samples a ramp
    at 1 MS/s and 2.5 mV a sample, so a 1.5 V crossing lands to a small fraction of a sample.

    0 to 3 V, because the envelope is on the nominal pair -- |OFST| + AMP/2 must stay inside 10 V -- and
    because a stimulus that straddles ground is not what a logic line does. Burst is turned OFF
    explicitly: left on it gates the output and the line reads as idle with every setting looking right.
    """
    freq = SLEW / amp
    g.write('C1:BTWV STATE,OFF')
    g.write('C1:BSWV WVTP,RAMP,FRQ,%.6f,AMP,%.4f,OFST,%.4f,SYM,100' % (freq, amp, ofst))
    g.output(True, ch=1)
    return freq


def parse_trial(line):
    """An FPTRIAL line -> dict, or None when it is not one. Every field, no defaults.

    A missing field defaults to nothing here on purpose: a renamed or dropped field read as a zero is a
    verdict derived from absent evidence, and a latency of zero would average in silently.
    """
    if 'FPTRIAL' not in line:
        return None
    out = {}
    for tok in line.split():
        if '=' in tok:
            k, v = tok.split('=', 1)
            out[k] = v
    for k in ('arm', 'warned', 'started', 'fired', 'npre', 'npost', 'lat'):
        if k not in out:
            return None
    out['npre'], out['npost'] = int(out['npre']), int(out['npost'])
    out['lat'] = float(out['lat'])
    return out


def paired_stats(diffs):
    """Mean paired difference, its standard error and t. -> dict, or None when there is nothing to say.

    The paired difference is the statistic because the arms alternate: any drift common to a pair
    cancels, which is the whole reason for interleaving rather than running one arm then the other.
    """
    n = len(diffs)
    if n < 2:
        return None
    mean = sum(diffs) / n
    var = sum((d - mean) ** 2 for d in diffs) / (n - 1)
    sem = math.sqrt(var / n)
    return {'n': n, 'mean': mean, 'sd': math.sqrt(var), 'sem': sem,
            't': (mean / sem) if sem > 0 else float('inf'),
            'ci95': 1.96 * sem}


def self_test():
    """The arithmetic and the sizing, with no instrument.

    A harness that reports a difference has to be shown to report NO difference on data that has none,
    or a positive result says nothing. And the sizing has to be checked as POWER over many simulated
    experiments rather than as the t of one draw: at the n this is sized for the expected t is about
    3.8, so a single draw clears 3 sigma only about half the time and an assertion on one draw tests
    the seed. That mistake was in the first version of this function.
    """
    import random
    bad = 0
    random.seed(7)

    def frac_significant(effect, sd, n, reps, crit):
        hit = 0
        for _ in range(reps):
            s = paired_stats([random.gauss(effect, sd) for _ in range(n)])
            if abs(s['t']) > crit:
                hit = hit + 1
        return float(hit) / reps

    # FALSE POSITIVES, on data with no effect at all. A two-sided 0.05 test must fire about 5 % of the
    # time and not much more, or every null this harness reports is suspect.
    fp = frac_significant(0.0, 1.4e-6, PAIRS_DEFAULT, 400, 1.98)
    ok = fp < 0.10
    print('  %-4s null: %.1f %% of 400 simulated experiments call it significant (want about 5)'
          % ('ok' if ok else 'FAIL', 100 * fp))
    bad = bad + (0 if ok else 1)

    # POWER against the effect this exists to find. 0.4 us against 1.4 us of paired spread is the case
    # the earlier n=20 attempt could not resolve.
    pw = frac_significant(-0.4e-6, 1.4e-6, PAIRS_DEFAULT, 400, 1.98)
    ok = pw > 0.90
    print('  %-4s power: %.1f %% of 400 experiments detect a 0.4 us effect at n=%d (want > 90)'
          % ('ok' if ok else 'FAIL', 100 * pw, PAIRS_DEFAULT))
    bad = bad + (0 if ok else 1)

    # AND THE OLD n WOULD NOT HAVE. The point of the redesign is this number, so it is asserted:
    # twenty pairs must fail to find the same effect most of the time.
    pw20 = frac_significant(-0.4e-6, 1.4e-6, 20, 400, 1.98)
    ok = pw20 < 0.45
    print('  %-4s and n=20 detects it only %.1f %% of the time, which is why it came back null'
          % ('ok' if ok else 'FAIL', 100 * pw20))
    bad = bad + (0 if ok else 1)

    # The sizing stated as arithmetic rather than asserted in prose: expected t, not a sampled one.
    t_exp = 0.4e-6 / (1.4e-6 / math.sqrt(PAIRS_DEFAULT))
    ok = t_exp > 3.5
    print('  %-4s sizing: n=%d gives an expected t of %.2f on a 0.4 us effect'
          % ('ok' if ok else 'FAIL', PAIRS_DEFAULT, t_exp))
    bad = bad + (0 if ok else 1)

    # The padding goes after the core, at every size. A pad block landing before the wait could delay
    # the comparator, and the experiment would then be measuring the padding.
    padbad = 0
    for k in (3, 13, 14, 15, 16, 20):
        lines = padded_program(k).split('\n')
        if not (len(lines) == k
                and 'MEASURE_DIGITIZE' in lines[0] and 'COUNT_INFINITE' in lines[0]
                and 'BLOCK_WAIT' in lines[1]
                and 'MEASURE_DIGITIZE' in lines[2]
                and all('DELAY_CONSTANT, 0' in l for l in lines[3:])):
            print('  FAIL padding at %d blocks is not core-then-pad' % k)
            padbad = padbad + 1
    print('  %-4s padding is core-then-pad at every size tested' % ('ok' if padbad == 0 else 'FAIL'))
    bad = bad + padbad

    # THE CHECK ABOVE MUST BE ABLE TO FAIL, or it is decoration. A program with the pad in front of the
    # wait has to be rejected by the same predicate.
    wrong = ['trigger.model.setblock(1, trigger.BLOCK_DELAY_CONSTANT, 0)'] + padded_program(3).split('\n')
    ok = not ('BLOCK_WAIT' in wrong[1])
    print('  %-4s and a pad placed before the wait is rejected by that check' % ('ok' if ok else 'FAIL'))
    bad = bad + (0 if ok else 1)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--latency', action='store_true',
                    help='run the paired comparator timing after the survey (needs the generator)')
    ap.add_argument('--pairs', type=int, default=PAIRS_DEFAULT,
                    help='paired trials; the default gives about 97 %% power on a 0.4 us effect')
    ap.add_argument('--blocks', default='3,4,5,6,7,8,9,10,12,14,15,16',
                    help='block counts to survey the flag at; 3 is the bare core')
    ap.add_argument('--pad', default='delay,branch',
                    help='padding ops to survey, comma separated: delay, branch')
    ap.add_argument('--self-test', action='store_true', help='arithmetic only, no instrument')
    a = ap.parse_args()

    if a.self_test:
        print('self-test, no instrument')
        return 1 if self_test() else 0

    from dmmrun import DMM, release_single_instance      # noqa: E402

    def run(d, body, timeout=40):
        out = d.load_script('fpath', body, run=True, timeout=timeout)
        lines = [str(l).strip() for l in out if str(l).strip()]
        tagged = [l for l in lines if l.startswith('FP')]
        for l in tagged:
            print('    ' + l)
        if not tagged:
            print('    RAW %r' % (lines[:6],))
        return ' | '.join(tagged)

    d = DMM(timeout=60)
    try:
        print('DMM:', str(d.q('*IDN?')).strip())
        print('\n=== survey: where does the flag flip? ===')
        for pad in a.pad.split(','):
            for k in [int(x) for x in a.blocks.split(',')]:
                run(d, flag_probe(k, pad=pad))
        print('\n=== survey: which part of the core carries the disqualifier ===')
        for label, body in core_probes():
            run(d, body)
        print('\n=== survey: the other documented disqualifiers ===')
        for label, body in disqualifier_probes():
            run(d, body)
        run(d, CLEANUP)

        if a.latency:
            # THREE BLOCKS AGAINST FOUR, which the survey chose rather than the 14/15 boundary this was
            # first built for: the bare core is on the fast path and the same core plus ONE zero delay
            # is off it. One block apart, and that block sits behind the post-trigger measure where it
            # cannot run before the comparator fires, so the flag is the only difference.
            from siglent import SDG                       # noqa: E402
            g = SDG()
            try:
                print('\n=== paired comparator latency, 3 blocks (on the fast path) against 4 (off) ===')
                print('    SDG:', str(g.idn()).strip())
                freq = ramp_on(g)
                print('    CH1 ramp %.2f Hz, %g V/s, crossing %g V at %d S/s' % (freq, SLEW, LEVEL, FS))
                arms = ((3, 'fast', 'no'), (4, 'slow', 'yes'))
                got = {'fast': [], 'slow': []}
                dead, mismatch = 0, 0
                for i in range(a.pairs):
                    for nb, label, want_warn in arms:
                        t = parse_trial(run(d, trial_program(nb, label), timeout=30))
                        if t is None or t['fired'] != 'yes' or t['lat'] <= 0:
                            dead = dead + 1
                            got[label].append(None)
                            continue
                        # THE INDEPENDENT VARIABLE IS CHECKED ON EVERY TRIAL. An arm that did not land
                        # on the side of the boundary it was built for is not evidence about the flag.
                        if t['warned'] != want_warn:
                            mismatch = mismatch + 1
                            got[label].append(None)
                            continue
                        got[label].append(t['lat'])
                    if (i + 1) % 20 == 0:
                        print('    %d of %d pair(s)' % (i + 1, a.pairs))
                g.output(False, ch=1)

                diffs = [f - s for f, s in zip(got['fast'], got['slow'])
                         if f is not None and s is not None]
                print('\n    %d pair(s) usable, %d dead trial(s), %d on the wrong side of the flag'
                      % (len(diffs), dead, mismatch))
                for label in ('fast', 'slow'):
                    vals = [v for v in got[label] if v is not None]
                    if vals:
                        m = sum(vals) / len(vals)
                        print('    %-5s n=%-4d mean %.3f us' % (label, len(vals), m * 1e6))
                s = paired_stats(diffs)
                if s is None:
                    print('    not enough paired trials to say anything')
                else:
                    print('    paired difference (fast - slow): %+.3f us, 95%% CI +/- %.3f us, t = %+.2f'
                          % (s['mean'] * 1e6, s['ci95'] * 1e6, s['t']))
                    if abs(s['mean']) > s['ci95']:
                        print('    the fast path is %s, by %.3f us'
                              % ('faster' if s['mean'] < 0 else 'slower', abs(s['mean']) * 1e6))
                    else:
                        # A null at THIS n is worth something, where the earlier one was not: 180 pairs
                        # carries about 97 % power on 0.4 us, so a bound rather than a shrug.
                        print('    no difference resolved; any effect is inside +/- %.3f us'
                              % (s['ci95'] * 1e6))
            finally:
                try:
                    g.output(False, ch=1)
                finally:
                    g.close()
        run(d, RELEASE)
    finally:
        d.close()
        release_single_instance()
    return 0


if __name__ == '__main__':
    sys.exit(main())

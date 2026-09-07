#!/usr/bin/env python3
"""What each message of a bench cell's generator conversation actually costs, and whether the last
blocking query can go.

WHY THIS EXISTS. A soak cell takes ~5.3 s of which only ~1.8 s is capture and decode; the rest is fixed
overhead, and the biggest identified piece is the SCPI conversation bsdg.select() holds with the
generator. That conversation was measured on the HOST side as traffic -- 7 messages per cell, 2 of them
blocking queries, now 5 and 1 -- but traffic is not time. Only the generator can be asked how long it
takes to answer, and this asks it.

TWO QUESTIONS, both cheap, both needing the bench to itself:

  1. HOW LONG DOES EACH MESSAGE TAKE? A write is fire-and-forget and should be sub-millisecond; a query
     blocks on the generator's ARM CPU and its slow link to the signal FPGA. If a query is ~1 s then the
     two queries were most of the fixed overhead and removing one is worth ~1 s a cell -- roughly 25 %
     more cells per hour. If a query is ~20 ms, the overhead is somewhere else entirely and the SDG was
     the wrong suspect.

  2. DOES BSWV RESET THE SAMPLE-RATE MODE? bsdg.select sets `C1:SRATE MODE,TARB` and then VERIFIES it
     with a blocking `C1:SRATE?` on every single cell, because neither manual says whether ARWV or BSWV
     resets the mode and a silent fall back to DDS resamples the stored points -- corrupting the
     sub-sample edge timing this project exists to measure, with nothing on the panel to say so. That
     unknown is the reason for the one round trip the waveform-selection cache deliberately kept.
     MEASURE IT: set TARB, confirm, send BSWV, ask again. If the mode survives, the write and the verify
     can both drop to periodic and a cell falls to 2 messages with NO blocking query.

     A NEGATIVE RESULT IS THE USEFUL ONE TO GET RIGHT. If BSWV does reset the mode, that is worth
     knowing in the documentation and the verify stays exactly where it is.

THE BENCH MUST BE FREE. The SDG2122X has a single SCPI client slot and a running soak holds it for the
whole run, so this cannot be run against a live soak -- the connect simply fails, which is the correct
outcome rather than something to work around.

RESTORES WHAT IT FOUND. Amplitude, offset, sample rate and mode are read before anything is written and
put back at the end: the next tool must not have to trust that this one tidied up.

    python3 tools/probe_sdg_cost.py [--reps 50]
"""
import argparse
import os
import re
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from siglent import SDG                                                   # noqa: E402


def field(reply, key):
    """Pull KEY,VALUE out of a Siglent parameter reply. -> str or None

    A BSWV? reply is one flat comma list -- 'C1:BSWV WVTP,ARB,AMP,5V,OFST,0V,...' -- so a value is the
    element after its own name rather than anything positional.

    SPLIT ON WHITESPACE TOO, not only on ':' and ','. The header and the first key are separated by a
    SPACE -- 'C1:SRATE MODE,TARB' -- so splitting on punctuation alone leaves 'SRATE MODE' as one token
    and every lookup of the first key in a reply silently returns None. MODE is exactly the field this
    probe exists to read, so that would have made the whole TrueArb question answer 'None' and look
    like the mode had not survived.
    """
    if not reply:
        return None
    parts = [p for p in re.split(r'[,:\s]+', reply.strip()) if p]
    for i, p in enumerate(parts):
        if p.upper() == key.upper() and i + 1 < len(parts):
            return parts[i + 1]
    return None


def num(s):
    """Strip a Siglent unit suffix and float it. -> float or None ('5V' -> 5.0, '1e+06Sa/s' -> 1e6)"""
    if s is None:
        return None
    t = ''
    for ch in s:
        if ch.isdigit() or ch in '+-.eE':
            t += ch
        else:
            break
    try:
        return float(t)
    except ValueError:
        return None


def timed(fn, *a, **k):
    """-> (seconds, result)"""
    t0 = time.perf_counter()
    r = fn(*a, **k)
    return time.perf_counter() - t0, r


def stat(name, v):
    if not v:
        print('  %-28s (none)' % name)
        return
    print('  %-28s n=%-4d median %8.2f ms   mean %8.2f ms   p90 %8.2f ms   max %8.2f ms'
          % (name, len(v), 1000 * statistics.median(v), 1000 * statistics.fmean(v),
             1000 * sorted(v)[int(len(v) * 0.9)], 1000 * max(v)))


def selftest():
    """The reply parser, against the shapes this generator actually sends. -> exit code

    IT EARNS A GATE STAGE BECAUSE IT HAD A BUG THAT THE INSTRUMENT WOULD NOT HAVE REVEALED AS A BUG.
    Splitting only on ':' and ',' left 'SRATE MODE' as one token, so field(reply, 'MODE') returned None
    for every reply -- and a None mode reads exactly like a mode that did not survive a BSWV write,
    which is the conclusion this probe exists to draw. A wrong answer that looks like a real answer is
    worse than a crash, and only a case with a KNOWN answer catches it.
    """
    cases = [
        ('C1:BSWV WVTP,ARB,FRQ,1000HZ,AMP,5V,OFST,0.5V,PHSE,0', 'AMP', '5V', 5.0),
        ('C1:BSWV WVTP,ARB,FRQ,1000HZ,AMP,5V,OFST,-0.5V,PHSE,0', 'OFST', '-0.5V', -0.5),
        # THE FIRST KEY AFTER THE HEADER, which is the one the punctuation-only split lost.
        ('C1:SRATE MODE,TARB,VALUE,1000000Sa/s,INTER,LINE', 'MODE', 'TARB', None),
        ('C1:SRATE MODE,TARB,VALUE,1e+06Sa/s,INTER,LINE', 'VALUE', '1e+06Sa/s', 1000000.0),
        # THE NEGATIVE THAT MATTERS: a mode that really is DDS must read as DDS, not as None.
        ('C1:SRATE MODE,DDS,VALUE,1000Sa/s', 'MODE', 'DDS', None),
        ('C1:ARWV NAME,SER_Fox_8N1_x10.bin', 'NAME', 'SER_Fox_8N1_x10.bin', None),
    ]
    bad = 0
    for reply, key, want, wantnum in cases:
        got = field(reply, key)
        ok = got == want
        if wantnum is not None:
            gn = num(got)
            ok = ok and gn is not None and abs(gn - wantnum) < 1e-9
        if not ok:
            bad += 1
            print('  FAIL  %s of %r -> %r, wanted %r' % (key, reply, got, want))
    if field(cases[0][0], 'NOPE') is not None:
        bad += 1
        print('  FAIL  a key that is absent must read None, not a neighbouring value')
    if num(None) is not None:
        bad += 1
        print('  FAIL  num(None) must be None')
    print('%s' % ('%d FAILED' % bad if bad else
                  'selftest: %d reply shapes parse, including a DDS mode and an absent key'
                  % len(cases)))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reps', type=int, default=50)
    ap.add_argument('--selftest', action='store_true',
                    help='check the reply parser against known replies; touches no instrument')
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    # SETTLE ZERO, because self.settle sleeps after every write and would be measured as the
    # generator's cost. The point is the generator's latency, not this script's politeness.
    d = SDG(settle=0.0)
    idn = d.query('*IDN?')
    if not idn or 'SDG' not in idn.upper():
        raise SystemExit('no SDG on the far end (got %r). If a soak is running it holds the single '
                         'client slot, which is why this refuses rather than interferes.' % idn)
    print('%s\n' % idn.strip())

    # ---- what we found, so we can put it back ---------------------------------------------------
    arwv0 = d.query('C1:ARWV?')
    bswv0 = d.query('C1:BSWV?')
    srate0 = d.query('C1:SRATE?')
    amp0, ofst0 = num(field(bswv0, 'AMP')), num(field(bswv0, 'OFST'))
    sr0, mode0 = num(field(srate0, 'VALUE')), field(srate0, 'MODE')
    print('found: ARWV %s  AMP %s  OFST %s  SRATE %s MODE %s'
          % (field(arwv0, 'NAME'), amp0, ofst0, sr0, mode0))
    if None in (amp0, ofst0, sr0) or mode0 is None:
        raise SystemExit('could not read the current state back, so it could not be restored: '
                         'refusing to change anything. ARWV=%r BSWV=%r SRATE=%r'
                         % (arwv0, bswv0, srate0))

    try:
        # ---- 1. per-message cost ----------------------------------------------------------------
        print('\n== what each message of a cell costs (%d reps) ==' % a.reps)
        tw_bswv, tw_mode, tw_val, tw_outp, tq_arwv, tq_srate = [], [], [], [], [], []
        for i in range(a.reps):
            amp = amp0 if i % 2 else max(amp0 * 0.99, 0.01)
            tw_bswv.append(timed(d.write, 'C1:BSWV AMP,%.4f,OFST,%.4f' % (amp, ofst0))[0])
            tw_mode.append(timed(d.write, 'C1:SRATE MODE,TARB')[0])
            tw_val.append(timed(d.write, 'C1:SRATE VALUE,%.6f' % sr0)[0])
            tw_outp.append(timed(d.write, 'C1:OUTP ON,LOAD,HZ')[0])
            tq_arwv.append(timed(d.query, 'C1:ARWV?')[0])
            tq_srate.append(timed(d.query, 'C1:SRATE?')[0])
        stat('WRITE BSWV AMP,OFST', tw_bswv)
        stat('WRITE SRATE MODE,TARB', tw_mode)
        stat('WRITE SRATE VALUE', tw_val)
        stat('WRITE OUTP ON', tw_outp)
        stat('QUERY ARWV?   (blocking)', tq_arwv)
        stat('QUERY SRATE?  (blocking)', tq_srate)
        wmed = sum(statistics.median(v) for v in (tw_bswv, tw_mode, tw_val, tw_outp))
        qmed = statistics.median(tq_arwv) + statistics.median(tq_srate)
        print('\n  a 7-message cell, medians:  4 writes %.0f ms + 2 queries %.0f ms = %.0f ms'
              % (1000 * wmed, 1000 * qmed, 1000 * (wmed + qmed)))
        print('  the ARWV write and its verify are what the cache removes: %.0f ms a cell'
              % (1000 * (statistics.median(tq_arwv) + statistics.median(tw_bswv))))
        print('  NOTE: the ARWV write is NOT timed above -- it changes the stimulus, so it is measured')
        print('        only as part of a real switch. Its verify (ARWV?) is the blocking half.')

        # ---- 2. does BSWV reset the sample-rate mode? -------------------------------------------
        print('\n== does BSWV reset the sample-rate mode? ==')
        d.write('C1:SRATE MODE,TARB')
        before = field(d.query('C1:SRATE?'), 'MODE')
        d.write('C1:BSWV AMP,%.4f,OFST,%.4f' % (amp0, ofst0))
        after = field(d.query('C1:SRATE?'), 'MODE')
        print('  mode with TARB set:      %s' % before)
        print('  mode after a BSWV write: %s' % after)
        if before and after and before.upper() == after.upper() == 'TARB':
            print('  -> BSWV DOES NOT RESET THE MODE. The MODE,TARB write and its SRATE? verify can '
                  'both\n     drop to periodic, taking a same-waveform cell to 2 messages and ZERO '
                  'blocking queries.')
        else:
            print('  -> THE MODE DID NOT SURVIVE. The verify stays exactly where it is; this is the '
                  'result\n     that justifies the round trip bsdg.select keeps on every cell.')
        # AND THE SAME QUESTION FOR ARWV, which is the other half of the unknown the comment names.
        d.write('C1:SRATE MODE,TARB')
        b2 = field(d.query('C1:SRATE?'), 'MODE')
        nm = field(arwv0, 'NAME')
        if nm:
            d.write('C1:ARWV NAME,%s' % nm)
            time.sleep(0.5)
            a2 = field(d.query('C1:SRATE?'), 'MODE')
            print('  mode after re-selecting the SAME waveform: %s (was %s)' % (a2, b2))
    finally:
        # ---- restore -----------------------------------------------------------------------------
        print('\nrestoring: AMP %s OFST %s SRATE %s MODE %s' % (amp0, ofst0, sr0, mode0))
        d.write('C1:BSWV AMP,%.4f,OFST,%.4f' % (amp0, ofst0))
        d.write('C1:SRATE MODE,%s' % mode0)
        d.write('C1:SRATE VALUE,%.6f' % sr0)
        back = d.query('C1:SRATE?')
        print('  reads back: MODE %s VALUE %s' % (field(back, 'MODE'), num(field(back, 'VALUE'))))
        d.close()


if __name__ == '__main__':
    # THE EXIT CODE IS THE GATE'S VERDICT, so --selftest's return value must reach the shell rather
    # than being dropped by a bare main().
    sys.exit(main() or 0)

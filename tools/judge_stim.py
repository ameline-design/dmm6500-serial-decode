#!/usr/bin/env python3
"""Read a mkplan_stim run: did the stimulus arrive, what did the generator say when it did not, and
where does a cell's time actually go?

THREE QUESTIONS, ONE RECORD.

1. THE STIMULUS. 663 of 2746 cells in the hot1 lap (24.1 %) produced no usable capture -- 457 'line is
   idle (no transitions)', 196 'no clear logic levels' -- and that is 18x the whole decoder defect rate.
   The plan pairs each suspect (vector, rate) with CONTROL rates on the same vector, so a pair that fails
   everywhere is a broken vector and a pair that fails at one rate is a broken rate. Reported side by
   side because neither number means anything alone.

2. WHAT THE GENERATOR SAID. brun.sdgverify writes bsdg.snapshot() on exactly the cells that produced
   nothing: ARWV?/BSWV?/SRATE?/OUTP?, asked on the spot. The ARWV name is checked against the name the
   PLAN asked for -- that is the one check that can catch the waveform-selection cache serving a stale
   name, and it is the reason the cache is safe to run at all.

   THE REPLIES CAN STILL BE TRUNCATED. bsdg.ask returns after one tspnet.read, so a long BSWV? reply is
   cut off; snapshot() drains between queries so nothing is MISATTRIBUTED, but a field can be short. A
   missing field is reported as missing rather than guessed at.

3. WHERE THE TIME GOES. Two independent readings, and they answer different questions:

   * brun.timing writes t=sel/acq/dec/row, cumulative seconds from the top of the cell on the
     instrument's own timer. Sub-millisecond, so it can see a 0.2 s effect that os.time() cannot.
   * THE REPEAT SPLIT works without it. The plan looks at each operating point N times in a row, and
     bsdg.select sends the generator NOTHING for the 2nd..Nth -- same waveform, amplitude, offset and
     rate. So mean(rep 0) - mean(rep > 0) IS the cost of the SCPI conversation, paired within one run on
     the same pairs, and averaging beats the 1 s quantisation of os.time().

    python3 tools/judge_stim.py [out/bench/stim1/SOAK.csv] [--plan out/bench/stim1/PLAN.csv]
"""
import argparse
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import judge_bench as JB                                                  # noqa: E402
import soakplan as SP                                                     # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TIMING = re.compile(r' t=(\S+)/(\S+)/(\S+)/(\S+)')
RATE = re.compile(r'rawbaud=(\S+) fitratio=(\S+) fitq=(\S+) snap=(\S+)/(\S+)')
NOSTIM = re.compile(r'nostim (.*?): (.*)$')
SNAPF = re.compile(r'(arwv|bswv|srate|outp)=(\S+(?: \S+)*?)(?= (?:arwv|bswv|srate|outp)=|$)')


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def cls_why(w):
    w = w or ''
    if 'line is idle' in w:
        return 'line is idle (no transitions)'
    if 'no clear logic levels' in w:
        return 'no clear logic levels'
    if 'swing only' in w:
        return 'swing only <threshold>'
    if w.startswith('SDG:'):
        return 'SDG: ' + w[4:40]
    return (w[:40] or '(decoded)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?',
                    default=os.path.join(ROOT, 'out', 'bench', 'stim1', 'SOAK.csv'))
    ap.add_argument('--plan', default=os.path.join(ROOT, 'out', 'bench', 'stim1', 'PLAN.csv'))
    a = ap.parse_args()

    # ---- the plan, so ARWV can be checked against what was ASKED for -----------------------------
    want_arb, reps = {}, 1
    if os.path.exists(a.plan):
        for ln in open(a.plan, errors='replace'):
            if ln.startswith('# repeats='):
                reps = int(ln.split('=')[1])
            if ln.startswith('#') or ln.startswith('iter,'):
                continue
            f = ln.rstrip('\n').split(',')
            if len(f) >= 5:
                want_arb[(f[0], f[1])] = f[3]
    print('%s\n  plan declares repeats=%d, %d row(s)' % (a.path, reps, len(want_arb)))

    lines = open(a.path, errors='replace').read().splitlines()
    runs = JB.split_runs(lines)
    body = runs[-1][1]
    R, notes = {}, collections.defaultdict(list)
    stamps = collections.defaultdict(list)
    for ln in body:
        f = ln.split(',')
        if ln.startswith('R,') and len(f) - 1 >= len(JB.RCOLS):
            d = dict(zip(JB.RCOLS, f[1:1 + len(JB.RCOLS)]))
            R[(d['iter'], d['cell'])] = d
        elif ln.startswith('S,') and len(f) > 8:
            notes[(f[2], f[3])].append(','.join(f[8:]))
            try:
                t, it, cl = int(f[1]), int(f[2]), int(f[3])
            except ValueError:
                continue
            if it >= 0 and cl >= 0 and t > 0:
                stamps[it].append((cl, t))
    if not R:
        raise SystemExit('no cells: an empty record is a FAILURE, not an empty file')
    print('  %d run(s); last run %d cell(s), %d lap(s)'
          % (len(runs), len(R), len({k[0] for k in R})))

    # ---- 1. the stimulus, suspect against control ------------------------------------------------
    print('\n' + '=' * 100)
    print('1) DID THE STIMULUS ARRIVE?  per (vector, rate)')
    print('=' * 100)
    per = collections.defaultdict(lambda: collections.Counter())
    for k, d in R.items():
        per[(d['vid'], int(float(d['baud'])))][cls_why(d['why'])] += 1
    tot = sum(sum(c.values()) for c in per.values())
    nostim = sum(n for c in per.values() for w, n in c.items() if w != '(decoded)')
    print('  %d cell(s), %d with no usable capture = %.1f %%   (hot1 was 24.1 %%)'
          % (tot, nostim, 100.0 * nostim / max(tot, 1)))
    print('\n%-6s %8s %6s %6s %7s  %s' % ('vid', 'baud', 'cells', 'dead', 'rate', 'why'))
    for key in sorted(per, key=lambda x: -(sum(n for w, n in per[x].items() if w != '(decoded)')
                                          / max(sum(per[x].values()), 1))):
        c = per[key]
        n = sum(c.values())
        bad = sum(v for w, v in c.items() if w != '(decoded)')
        detail = ', '.join('%s x%d' % (w, v) for w, v in c.most_common() if w != '(decoded)')
        print('%-6s %8d %6d %6d %6.1f%%  %s' % (key[0], key[1], n, bad, 100.0 * bad / max(n, 1),
                                                detail or 'all decoded'))

    # ---- 2. what the generator said on a dead cell ------------------------------------------------
    print('\n' + '=' * 100)
    print('2) WHAT THE GENERATOR SAID on cells that produced nothing')
    print('=' * 100)
    nsnap = nmatch = nmismatch = 0
    shown = 0
    for k in sorted(R, key=lambda kv: (int(kv[0]), int(kv[1]))):
        for note in notes.get(k, []):
            m = NOSTIM.search(note)
            if not m:
                continue
            nsnap += 1
            fields = dict(SNAPF.findall(m.group(2)))
            arwv = fields.get('arwv', '')
            wanted = want_arb.get(k, '?')
            # THE ONE CHECK THAT CATCHES A STALE WAVEFORM CACHE.
            ok = wanted != '?' and wanted.upper() in arwv.upper()
            if ok:
                nmatch += 1
            else:
                nmismatch += 1
            if shown < 12 or not ok:
                shown += 1
                print('  L%sC%-4s %-34s ARWV %s' % (k[0], k[1], m.group(1)[:34],
                                                    'MATCHES plan' if ok else
                                                    'MISMATCH: wanted %s got %r' % (wanted, arwv)))
                for f in ('bswv', 'srate', 'outp'):
                    if f in fields:
                        print('           %-5s %s' % (f, fields[f][:100]))
                    else:
                        print('           %-5s (no reply / truncated away)' % f)
    if not nsnap:
        print('  no snapshots in this record -- either nothing failed, or --sdg-verify was not passed')
    else:
        print('\n  %d snapshot(s): %d name the waveform the plan asked for, %d DO NOT'
              % (nsnap, nmatch, nmismatch))
        if nmismatch:
            print('  A MISMATCH IS THE WAVEFORM CACHE SERVING A STALE NAME -- set bsdg.arwvevery = 0 '
                  '(run_bench.py --no-sdg-skip) and re-run before trusting anything else in this record.')

    # ---- 3a. the repeat split: what the SCPI conversation costs -----------------------------------
    print('\n' + '=' * 100)
    print('3a) WHAT THE GENERATOR CONVERSATION COSTS  (rep 0 sends 7 messages, rep>0 sends none)')
    print('=' * 100)
    dt = {}
    for it, lst in stamps.items():
        seen = {}
        for cl, t in sorted(lst):
            if cl not in seen:
                seen[cl] = t
        seq = sorted(seen.items())
        for i in range(len(seq) - 1):
            d = seq[i + 1][1] - seq[i][1]
            if 0 < d <= 120:
                dt[(str(it), str(seq[i][0]))] = d
    byrep = collections.defaultdict(list)
    for k, d in dt.items():
        r = R.get(k)
        if r is None:
            continue
        # rep index within the group of consecutive identical rows
        byrep[((int(k[1]) - 1) % reps, r['ran'])].append(d)
    if reps < 2:
        print('  plan has repeats=1, so there is no split to make')
    else:
        for ran in ('y', 'n'):
            rows = [(rp, v) for (rp, rr), v in byrep.items() if rr == ran]
            if not rows:
                continue
            print('  cells with ran=%s:' % ran)
            base = None
            for rp, v in sorted(rows):
                m = sum(v) / len(v)
                if rp == 0:
                    base = m
                print('    rep %d  n=%-5d mean %.3f s%s'
                      % (rp, len(v), m, '' if base is None or rp == 0
                         else '   delta %+.3f s vs rep 0' % (m - base)))
            others = [x for rp, v in rows if rp > 0 for x in v]
            first = [x for rp, v in rows if rp == 0 for x in v]
            if others and first:
                print('    => the conversation costs %+.3f s a cell (%d vs %d cells)'
                      % (sum(first) / len(first) - sum(others) / len(others), len(first), len(others)))

    # ---- 3b. the phase timing --------------------------------------------------------------------
    print('\n' + '=' * 100)
    print('3b) WHERE A CELL\'S TIME GOES  (brun.timing; cumulative, so phases are differences)')
    print('=' * 100)
    ph = collections.defaultdict(list)
    nt = 0
    for k, d in R.items():
        for note in notes.get(k, []):
            m = TIMING.search(note)
            if not m:
                continue
            nt += 1
            sel, acq, dec, row = [fnum(x) for x in m.groups()]
            if sel is None:
                continue
            ph[(d['ran'], 'select+wait')].append(sel)
            if acq is not None:
                ph[(d['ran'], 'acquire')].append(acq - sel)
            if acq is not None and dec is not None:
                ph[(d['ran'], 'decode')].append(dec - acq)
            last = dec if dec is not None else acq
            if row is not None and last is not None:
                ph[(d['ran'], 'record+panel')].append(row - last)
    if not nt:
        print('  no timing on any cell -- pass --timing to run_bench.py for this section')
    else:
        print('  %d cell(s) carry phase timing' % nt)
        for ran in ('y', 'n'):
            keys = [p for (rr, p) in ph if rr == ran]
            if not keys:
                continue
            print('  ran=%s:' % ran)
            tot_ = 0.0
            for p in ('select+wait', 'acquire', 'decode', 'record+panel'):
                v = ph.get((ran, p))
                if not v:
                    continue
                v = sorted(v)
                mean = sum(v) / len(v)
                tot_ += mean
                print('    %-14s n=%-5d mean %6.3f s   median %6.3f   p90 %6.3f'
                      % (p, len(v), mean, v[len(v) // 2], v[int(len(v) * 0.9)]))
            print('    %-14s      %6.3f s' % ('TOTAL', tot_))

    # ---- the rate mechanisms, carried along --------------------------------------------------------
    print('\n' + '=' * 100)
    print('4) THE CONFIRMED RATE MECHANISMS, with fitratio')
    print('=' * 100)
    print('%-6s %8s %10s %10s %9s %-7s %s' % ('vid', 'baud', 'read_baud', 'RAWBAUD', 'raw/cmd',
                                              'fitratio', 'snap/firm'))
    seenm = set()
    for k in sorted(R, key=lambda kv: (int(kv[0]), int(kv[1]))):
        d = R[k]
        for note in notes.get(k, []):
            m = RATE.search(note)
            if not m:
                continue
            cmd, rd, raw = fnum(d['baud']), fnum(d['read_baud']), fnum(m.group(1))
            if None in (cmd, rd, raw) or cmd <= 0 or abs(rd / cmd - 1) <= 0.02:
                continue
            key = (d['vid'], int(cmd))
            if key in seenm:
                continue
            seenm.add(key)
            print('%-6s %8d %10.0f %10.1f %9.4f %-7s %s/%s'
                  % (d['vid'], cmd, rd, raw, raw / cmd, m.group(2), m.group(4), m.group(5)))
    if not seenm:
        print('  no wrong-rate cells in this record')


if __name__ == '__main__':
    main()

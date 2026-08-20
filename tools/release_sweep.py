#!/usr/bin/env python3
"""THE GATE BEFORE THE APP GOES TO ANYONE ELSE. Every check, in one run, recorded.

Nothing here is new work: each stage is a harness that already exists and is already the
authority on its own question. What this adds is that they run TOGETHER, in an order where a
cheap failure stops an expensive one, and that the run leaves an AUDITABLE RECORD -- so
"release 1 passed" is a directory someone can open in a year, not a memory.

    out/release/<stamp>/
        REPORT.md        the summary, per stage, with the numbers that matter
        summary.json     the same, machine-readable
        <stage>.log      every stage's full output, verbatim
        shots/           every front-panel grab taken, before and after each press
        Serial_Decode.tspa + .sha256    the exact artifact these results describe

TWO GROUPS, and the split is about what they need rather than what they check:

  OFFLINE   lint, both parse checks, the unit suite, the adversarial stress run, the package
            step and the archive verifier. No instruments. Runs in about a minute, and it is
            what catches a change that cannot possibly work -- so it runs first, always.

  HARDWARE  the app driven through its own Capture button across formats, standard and
            non-standard baud rates, a 1 kB non-repeating payload, three logic swings and
            twelve DC offsets; then every button in every state, with the panel grabbed either
            side of each press. Needs the DMM, the generator and a FRESH POWER CYCLE.

WHY THE POWER CYCLE IS A GATE AND NOT ADVICE. sdec.start() builds the display objects, and the
firmware does not fully return the pool -- so the app refuses a second build in one power cycle
and the hardware stages would fail for a reason that has nothing to do with the code. Checked up
front, and refused with the remedy, rather than discovered forty minutes in.

    python3 tools/release_sweep.py                 # everything (needs a fresh power cycle)
    python3 tools/release_sweep.py --offline        # no instruments; pre-flight for a code change
    python3 tools/release_sweep.py --skip stress    # drop a stage by name
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TSPA = os.path.join(ROOT, 'Serial_Decode.tspa')
MANUAL_PDF = os.path.join(ROOT, 'docs', 'MANUAL.pdf')

# Non-standard rates. A device with a crystal divided by an awkward number does not sit on the
# ladder, and the decoder measures rather than assumes -- so the rates that are NOT standard are
# the ones that test that claim. Seven deliberate awkward values plus twelve arbitrary ones.
ODD_RATES = ('900,1500,2800,3600,7200,12000,16000,'
             '1379,2731,5333,8123,13333,21600,29127,41666,53333,71111,89123,104857')


class Stage:
    def __init__(self, name, argv, hardware=False, gate=True, note=''):
        self.name = name
        self.argv = argv
        self.hardware = hardware
        self.gate = gate            # False: recorded, but does not fail the release
        self.note = note
        self.rc = None
        self.secs = 0.0
        self.out = ''
        self.summary = ''


def stages(outdir, shots):
    S = [
        Stage('lint', ['python3', 'tools/lint_tsp.py'] + tsp_files(),
              note='Lua 5.0.2 incompatibilities: #, %, gmatch, string args to collectgarbage'),
        Stage('parse', ['bash', '-c',
                        'for f in tsp/*.tsp; do luac -p "$f" || exit 1; done; echo "all parse"'],
              note='luac -p on every module'),
        Stage('unit', ['lua', 'tools/test_serial.lua'],
              note='the offline suite: decoder, UI, state machine, file paths'),
        # ONE STAGE PER DEFECT CLASS, not one merged regression stage. Each of these three files
        # was written against a specific HIGH defect that shipped once, and each check in them
        # fails against the code as it was -- so a failure here names the defect that came back
        # rather than just saying a regression suite went red.
        Stage('unit-frontrig', ['lua', 'tools/test_frontrig.lua'],
              note='Trigger key and rear-BNC arming THROUGH acquire() -- the routing that used '
                   'to drop to free-run while the status row claimed the key was the source'),
        Stage('unit-usblog', ['lua', 'tools/test_usblog.lua'],
              note='USB log name allocation and the persistent index -- name exhaustion must '
                   'refuse, not loop forever and hang the panel'),
        Stage('unit-stream', ['lua', 'tools/test_streamfix.lua'],
              note='the streaming arm: both 4915 defences, one press per slice not per window, '
                   'and a press-driven recording that states the control that works'),
        Stage('unit-cancel', ['lua', 'tools/test_cancel.lua'],
              note='the TRIGGER-key cancel latch, one press for a whole transmission, the two '
                   'window sizes, and flow control looping with no interaction at all'),
        # THE HOSTILE PAYLOADS, as opposed to the hostile SIGNALS the stress stage covers. Every check
        # here is a byte-exactness assertion against a payload chosen to break a value-dependent
        # decoder -- blocks of 00/FF/55/AA, walking ones and zeros, and 1024 uniform random bytes from
        # a fixed seed. Lorem ipsum cannot catch that class: its bytes are all 0x20-0x7A, so bit 7 is
        # constant and the extremes of edge density never appear.
        Stage('unit-patterns', ['lua', 'tools/test_patterns.lua'],
              note='byte-exactness on the hard payloads -- edge-density extremes, walking bits and '
                   'known random data, at the sample rates the panel actually picks'),
        Stage('stress', ['lua', 'tools/stress_serial.lua'],
              note='hostile signals -- must never be silently WRONG and never RAISE'),
        # THE GAP EVERY STAGE ABOVE SHARED: they all name a round sample rate by hand and all start
        # on the generator's clean lead idle. #29 -- 9600 read as 19200, then as 7N1 -- failed two
        # bench laps in seven while 884 assertions stayed green, because the app runs 9600 at
        # pick_fs(9600,8) = 80 kS/s and a triggered capture opens mid-pulse. This stage takes fs from
        # the app and sweeps what the bench actually varies: sampling phase, edge jitter, noise,
        # window length, and where the window opens. It reproduced #29 in 10 s.
        Stage('unit-analog', ['lua', 'tools/test_analog.lua'],
              note='the bench cases at the app\'s OWN sample rates, swept over sampling phase, '
                   'jitter, noise and where the capture window opens -- and the 7-bit shuffled '
                   'payloads, where a mid-byte start makes the parity vote 232 of 233 and takes '
                   'refine_parity\'s re-decode branch'),
        # Gates the HARNESS's own long-payload verdict, not the app. It earns a gate because the
        # gate it replaces passed a capture containing a silently wrong byte, and a judging rule
        # that can do that is as dangerous as a decoder bug -- it hides them.
        # THE ONE GATE WHOSE SUBJECT IS AN UNRECOVERABLE HARDWARE FAILURE. A zero-length or undersized
        # waveform bricks the SDG at its next power-up with no shell to recover through, and review
        # found THREE live bypasses of the guard that was supposed to prevent it -- including
        # write(), which had no check at all. Cheap, hermetic (transport='dry', no instrument), and
        # it fails against the code as it was.
        Stage('unit-sdgguard', ['python3', 'tools/test_sdg_guard.py'],
              note='every route to an out-of-spec waveform refuses it -- the three bypasses found '
                   'in review, plus the legitimate uploads still working'),
        # The phase sweep across every bench vector, sharded over the cores. Its subject is the
        # variable that both shipped decoder defects had in common: where the capture opened.
        Stage('unit-phasesweep', ['python3', 'tools/sweep_all.py', '--quiet'],
              note='every vector x capture start x phase/jitter/noise -- no raise, no result '
                   'without a format, no wrong byte among the ones ERR calls trustworthy'),
        Stage('unit-loremgate', ['python3', 'tools/test_lorem_gate.py'],
              note='the long-payload judging rule: every clean run validated, flag COUNT bounded, '
                   'and the cases the old longest-run gate got wrong'),
        Stage('tolerance', ['lua', 'tools/tolerance.lua'], gate=False,
              note='the envelope table in the manual, recomputed'),
        Stage('package', ['python3', 'tools/package_tspa.py'],
              note='rebuild the archive from the sources just checked'),
        Stage('archive', ['lua', 'tools/verify_tspa.lua'],
              note='builds both screens from the ARCHIVE against a mock front end'),
        # Run from docs/, or pandoc resolves img/ against the repo root and the screenshots
        # silently drop out of the PDF.
        # EVERY SHIPPED DOCUMENT, not just the manual. They were being built by hand, which is how a
        # PDF ends up describing a build that no longer exists -- the whole point of doing it in the
        # gate is that a stale PDF becomes impossible rather than merely unlikely.
        # README.pdf is built from the repo root because its links are repo-relative; the two in
        # docs/ are built from docs/ or pandoc resolves img/ against the root and the screenshots
        # silently drop out.
        Stage('manual', ['bash', '-c',
                         'cd docs && pandoc MANUAL.md -o MANUAL.pdf --pdf-engine=typst '
                         '&& pandoc REFERENCE.md -o REFERENCE.pdf --pdf-engine=typst '
                         '&& cd .. && pandoc README.md -o README.pdf --pdf-engine=typst '
                         '&& ls -l docs/MANUAL.pdf docs/REFERENCE.pdf README.pdf'],
              note='rebuild every shipped PDF: the manual, the measured reference, and the README'),

        Stage('hw-matrix',
              ['python3', 'tools/bench_matrix.py',
               '--suites', 'formats,rates,lorem,levels,offsets',
               '--shots', os.path.join(shots, 'matrix'), '--no-output-off'],
              hardware=True,
              note='formats, the standard rate ladder, lorem, logic swings, DC offsets. '
                   'THIS STAGE SPENDS THE ONE UI BUILD.'),
        # SEPARATE FROM hw-matrix on purpose. Fourteen more captures is ~100 s, and keeping it its
        # own stage means a payload failure is named as one in the report instead of being buried in
        # a 43-point matrix -- and it can be re-run alone with --no-start while diagnosing.
        Stage('hw-payloads',
              ['python3', 'tools/bench_matrix.py', '--suites', 'payloads', '--no-start',
               '--shots', os.path.join(shots, 'payloads'), '--no-output-off'],
              hardware=True,
              note='every byte value 0-255: all 94 visible glyphs in 8N1 and 7E1, plus twelve '
                   'shuffled 256-byte payloads, six 8N1 and six 7E1'),
        Stage('hw-odd-rates',
              ['python3', 'tools/bench_matrix.py', '--suites', 'rates', '--no-start',
               '--rates', ODD_RATES,
               '--shots', os.path.join(shots, 'odd'), '--no-output-off'],
              hardware=True, note='nineteen non-standard baud rates'),
        Stage('hw-panel',
              ['python3', 'tools/bench_panel.py', '--reuse',
               '--shots', os.path.join(shots, 'panel'),
               '--json', os.path.join(outdir, 'panel.json')],
              hardware=True,
              note='every button in every state, panel grabbed before and after each press'),
        Stage('hw-break',
              ['python3', 'tools/bench_break.py', '--reuse',
               '--shots', os.path.join(shots, 'break')],
              hardware=True,
              note='degenerate signals and contradictory settings -- a refusal with a reason '
                   'passes, confident garbage does not'),
    ]
    return S


def tsp_files():
    d = os.path.join(ROOT, 'tsp')
    return [os.path.join('tsp', f) for f in sorted(os.listdir(d)) if f.endswith('.tsp')]


def summarise(name, out, rc):
    """The one line worth putting in the report for each stage."""
    lines = [l.rstrip() for l in out.splitlines() if l.strip()]
    def find(pred):
        for l in reversed(lines):
            if pred(l):
                return l.strip()
        return ''
    if name in ('unit', 'stress', 'archive', 'unit-analog'):
        s = find(lambda l: 'passed' in l and 'failed' in l)
        return s or (lines[-1] if lines else '')
    if name == 'lint':
        bad = [l for l in lines if ': OK' not in l]
        return 'all %d modules clean' % len(lines) if not bad else '; '.join(bad[:3])
    if name in ('hw-matrix', 'hw-odd-rates', 'hw-payloads'):
        pts = find(lambda l: 'points fully correct' in l)
        ev = find(lambda l: l.startswith('events:'))
        return ' | '.join(x for x in (pts, ev) if x)
    if name == 'hw-panel':
        s = find(lambda l: l.startswith(('every press behaved', 'FAILURES:')))
        cnt = find(lambda l: 'presses:' in l)
        return ' | '.join(x for x in (cnt, s) if x)
    if name == 'hw-break':
        return find(lambda l: 'behaved acceptably' in l)
    if name == 'package':
        return find(lambda l: 'bytes,' in l)
    return lines[-1] if lines else ''


def run(st, outdir, env):
    t0 = time.time()
    p = subprocess.run(st.argv, cwd=ROOT, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    st.secs = time.time() - t0
    st.rc = p.returncode
    # errors='replace': the unit suite prints decoded bytes, which are not valid UTF-8.
    st.out = p.stdout.decode('utf-8', errors='replace')
    st.summary = summarise(st.name, st.out, st.rc)
    with open(os.path.join(outdir, st.name + '.log'), 'w') as fh:
        fh.write('$ %s\n\n' % ' '.join(st.argv))
        fh.write(st.out)
    return st


def instrument_check():
    """Are the instruments there, and has the DMM been power-cycled since the last build?

    Returns (ok, lines). Never raises: an absent instrument is a message, not a traceback.
    """
    out, ok = [], True
    try:
        import instruments as I
        from dmmrun import DMM
        d = DMM()
        try:
            # SENTINEL FIRST, THEN ONE TAGGED REPLY FOR EVERYTHING. These three questions decide whether
            # forty minutes of hardware stages run at all, and successive untagged q() calls cannot tell
            # this conversation's answer from the last one's -- so a stream one line behind would report a
            # built app as absent (and spend the power cycle's only UI build), or an absent one as built
            # (and refuse a perfectly good bench). See tools/bench_sync.py.
            import bench_sync as BS
            if not BS.resync(d):
                ok = False
                out.append('REFUSED: the DMM reply stream will not resync -- another client may be '
                           'connected, or a previous run was killed mid-command.')
            st = BS.tagged(d, [('model', 'localnode.model'), ('ver', 'localnode.version'),
                               ('serial', 'localnode.serialno'),
                               ('built', 'sdec ~= nil and sdec.built == true'),
                               ('events', 'eventlog.getcount()')])
            if st is None:
                ok = False
                out.append('REFUSED: could not read the DMM preflight state in one tagged reply.')
                st = {}
            out.append('DMM6500: %s  %s  %s' % (st.get('model', '?'), st.get('ver', '?'),
                                                st.get('serial', '?')))
            if st.get('built') == 'true':
                ok = False
                out.append('REFUSED: an app is already built on this instrument. sdec.start() '
                           'cannot build twice in one power cycle -- power cycle the DMM and '
                           'run this again.')
            elif st:
                out.append('no app built yet: the one UI build of this power cycle is available')
            out.append('event log holds %s entries at the start' % st.get('events', '?'))
        finally:
            d.close()
            # GIVE THE SINGLE-CLIENT LOCK BACK. It is held per PROCESS, so this parent holding it
            # blocks every stage it is about to spawn -- which reads as the app refusing its own
            # hardware tests, in 0.1 s, with a traceback about a second control socket.
            from dmmrun import release_single_instance
            release_single_instance()
    except Exception as e:
        ok = False
        out.append('REFUSED: cannot talk to the DMM6500 (%s)' % e)
        try:
            from dmmrun import release_single_instance
            release_single_instance()
        except Exception:
            pass
    try:
        from siglent import SDG
        g = SDG()
        out.append('SDG: %s' % (g.idn() or '?').strip())
        stl = g.query('STL? USER') or ''
        need = ['v41', 'v44a', 'v44b', 'v44c', 'v44d', 'v44e', 'v80', 'v71']
        # THROUGH VN.missing(): the ids here are local, the instrument holds SER_ names, and an exact
        # membership test is required rather than a substring one -- SER_Hello_8N1 is a prefix of
        # SER_Hello_8N1_Sp10, so the old test read a missing vector as present.
        missing = VN.missing(stl, need)
        if missing:
            ok = False
            out.append('REFUSED: waveforms missing from the generator: %s. Upload them with '
                       'tools/bench_matrix.py --upload first.' % ', '.join(missing))
        else:
            out.append('all %d stimulus waveforms present on the generator' % len(need))
        g.close()
    except Exception as e:
        ok = False
        out.append('REFUSED: cannot talk to the SDG2122X (%s)' % e)
    return ok, out


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for blk in iter(lambda: fh.read(1 << 16), b''):
            h.update(blk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', action='store_true',
                    help='skip every stage needing an instrument')
    ap.add_argument('--skip', default='', help='comma-separated stage names to skip')
    ap.add_argument('--out', default=os.path.join(ROOT, 'out', 'release'),
                    help='parent directory for the timestamped record')
    ap.add_argument('--stamp', help='use this name instead of the current time')
    a = ap.parse_args()

    stamp = a.stamp or time.strftime('%Y-%m-%dT%H-%M-%S')
    outdir = os.path.join(os.path.expanduser(a.out), stamp)
    shots = os.path.join(outdir, 'shots')
    os.makedirs(shots, exist_ok=True)
    skip = set(s for s in a.skip.split(',') if s)

    print('=' * 78)
    print('RELEASE SWEEP  %s' % stamp)
    print('record -> %s' % outdir)
    print('=' * 78)

    env = dict(os.environ)
    S = [s for s in stages(outdir, shots) if s.name not in skip]
    if a.offline:
        S = [s for s in S if not s.hardware]

    inst_ok, inst_lines = True, ['--offline: instruments not contacted']
    if any(s.hardware for s in S):
        print('\n-- instruments --')
        inst_ok, inst_lines = instrument_check()
        for l in inst_lines:
            print('  ' + l)
        if not inst_ok:
            print('\nhardware stages will be SKIPPED. The offline gate still runs.')
            S = [s for s in S if not s.hardware]
    else:
        print('\n' + inst_lines[0])

    print('\n%-14s %-6s %8s  %s' % ('STAGE', '', 'secs', 'RESULT'))
    print('-' * 78)
    done, failed_names = [], set()
    for st in S:
        # hw-panel drives the app hw-matrix built. If the build stage failed there is no app to
        # press, so running it would report a second failure with one cause.
        if (st.name in ('hw-odd-rates', 'hw-payloads', 'hw-panel', 'hw-break')
                and 'hw-matrix' in failed_names):
            print('%-14s %-6s %8s  skipped: hw-matrix failed, so there is no built app to drive'
                  % (st.name, 'skip', '-'))
            continue
        run(st, outdir, env)
        done.append(st)
        verdict = 'ok' if st.rc == 0 else ('BAD' if st.gate else 'warn')
        print('%-14s %-6s %8.1f  %s' % (st.name, verdict, st.secs, st.summary[:60]))
        if st.rc != 0:
            failed_names.add(st.name)
        if st.rc != 0 and st.gate:
            print('               ^ gate failed; see %s.log' % st.name)
            # An offline failure invalidates the hardware run: it would be measuring code that
            # is already known to be wrong. Stop before spending forty minutes on it.
            if not st.hardware:
                print('\nstopping before the hardware stages -- fix this first.')
                S = [s for s in S if not s.hardware]

    digest = None
    for art in (TSPA, MANUAL_PDF):
        if not os.path.exists(art):
            continue
        shutil.copy2(art, os.path.join(outdir, os.path.basename(art)))
        d = sha256(art)
        with open(os.path.join(outdir, os.path.basename(art) + '.sha256'), 'w') as fh:
            fh.write('%s  %s\n' % (d, os.path.basename(art)))
        if art == TSPA:
            digest = d

    nshots = sum(len(f) for _, _, f in os.walk(shots))
    failed = [s for s in done if s.rc != 0 and s.gate]
    warned = [s for s in done if s.rc != 0 and not s.gate]
    hw_ran = any(s.hardware for s in done)
    # A GATE THAT DID NOT RUN IS NOT A GATE THAT PASSED, and --skip could silence any of them. `released`
    # was `not failed and hw_ran`, so skipping every hardware stage but one, or skipping an offline gate
    # outright, still printed RELEASABLE -- the word this tool exists to be trusted about. Absence of a
    # failure is not evidence when the check was never made.
    #
    # Compared against the FULL stage list rather than a written-down set, so a stage added later is
    # mandatory by default: forgetting to add it here would otherwise make it optional and silent.
    allgates = set(s.name for s in stages(outdir, shots) if s.gate)
    rangates = set(s.name for s in done if s.gate)
    missing = sorted(allgates - rangates)

    rec = {
        'stamp': stamp,
        'artifact': os.path.basename(TSPA),
        'sha256': digest,
        'instruments': inst_lines,
        'hardware_ran': hw_ran,
        'shots': nshots,
        'released': (not failed) and hw_ran and not missing,
        'gates_not_run': missing,
        'stages': [{'name': s.name, 'rc': s.rc, 'secs': round(s.secs, 1),
                    'gate': s.gate, 'hardware': s.hardware,
                    'note': s.note, 'summary': s.summary} for s in done],
    }
    with open(os.path.join(outdir, 'summary.json'), 'w') as fh:
        json.dump(rec, fh, indent=1)

    write_report(outdir, rec, done)

    print('-' * 78)
    if failed:
        print('NOT RELEASABLE: %d gate(s) failed -- %s'
              % (len(failed), ', '.join(s.name for s in failed)))
    elif missing:
        print('INCOMPLETE, NOT RELEASABLE: %d gate(s) never ran -- %s'
              % (len(missing), ', '.join(missing)))
        print('A gate that was skipped has not passed. Rerun without --skip/--offline for a release.')
    elif not hw_ran:
        print('OFFLINE GATE PASSED. The hardware stages did not run, so this is NOT a release '
              'result -- rerun on the bench with a freshly power-cycled DMM.')
    else:
        print('RELEASABLE: every gate passed, on the bench, against %s' % (digest or '?')[:16])
    if warned:
        print('non-gating warnings: %s' % ', '.join(s.name for s in warned))
    print('%d panel grabs recorded' % nshots)
    print('REPORT: %s' % os.path.join(outdir, 'REPORT.md'))
    return 1 if (failed or missing) else 0


def write_report(outdir, rec, done):
    L = []
    L.append('# Release sweep — %s' % rec['stamp'])
    L.append('')
    if rec['released']:
        L.append('**RELEASABLE.** Every gate passed, on the bench.')
    elif rec.get('gates_not_run'):
        L.append('**INCOMPLETE — not releasable.** These gates never ran: `%s`. A skipped gate has '
                 'not passed.' % '`, `'.join(rec['gates_not_run']))
    elif not rec['hardware_ran']:
        L.append('**Offline gate only.** The hardware stages did not run, so this is not a '
                 'release result.')
    else:
        L.append('**NOT RELEASABLE.** At least one gate failed; see the table.')
    L.append('')
    L.append('| | |')
    L.append('|---|---|')
    L.append('| Artifact | `%s` |' % rec['artifact'])
    L.append('| SHA-256 | `%s` |' % (rec['sha256'] or '—'))
    L.append('| Panel grabs | %d |' % rec['shots'])
    L.append('')
    L.append('## Instruments')
    L.append('')
    for l in rec['instruments']:
        L.append('- %s' % l)
    L.append('')
    L.append('## Stages')
    L.append('')
    L.append('| Stage | Result | Secs | What it checks | Outcome |')
    L.append('|---|---|---|---|---|')
    for s in done:
        v = 'ok' if s.rc == 0 else ('**BAD**' if s.gate else 'warn')
        L.append('| `%s` | %s | %.0f | %s | %s |'
                 % (s.name, v, s.secs, s.note, s.summary.replace('|', '/')))
    L.append('')
    L.append('Full output for each stage is in `<stage>.log` beside this file.')
    L.append('')
    bad = [s for s in done if s.rc != 0]
    if bad:
        L.append('## Failures')
        L.append('')
        for s in bad:
            L.append('### `%s` (exit %s)' % (s.name, s.rc))
            L.append('')
            L.append('```')
            tail = [l for l in s.out.splitlines() if l.strip()][-25:]
            L.extend(tail)
            L.append('```')
            L.append('')
    with open(os.path.join(outdir, 'REPORT.md'), 'w') as fh:
        fh.write('\n'.join(L) + '\n')


if __name__ == '__main__':
    sys.exit(main())

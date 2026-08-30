#!/usr/bin/env python3
"""Upload the bench vectors to the SDG2122X under their SER_ names.

WHY A TOOL RATHER THAN A ONE-OFF. The names are the contract -- see docs/VECTORS.md -- and a rename done
by hand is a rename done differently next time. This holds the mapping in one place, refuses anything past
the upload ceiling, and VERIFIES each name landed rather than trusting a write that reports nothing.

RUN THIS RARELY -- IDEALLY ONCE. The waveforms then live in internal flash and are reused indefinitely:
a bench lap selects from them 1677 times and a fortnight's soak about 230 000 times, every one of those an
ARWV by name with no transfer. So the hazards guarded below are a one-off setup cost, not something a run
can trip over, and being slow and paranoid here is cheap. Re-upload only when a vector's bytes change.

THE 65536-BYTE CEILING IS NOT ABOUT SPACE. The generator reports ~80 MB of internal flash free and the
whole planned set is ~2.3 MB, so capacity is irrelevant. SDG_UPLOAD_SAFE_BYTES exists because a few
consecutive WVDT uploads over it WEDGE this generator's LAN service (tools/instruments.py): it keeps
answering pings and refuses the SCPI port until power-cycled. So the ceiling stands however much flash
is free, and this tool refuses rather than warns.

    python3 tools/upload_vectors.py --dry-run     # what would go, and what cannot
    python3 tools/upload_vectors.py               # do it
"""
import argparse
import csv
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_sync as BS                                        # noqa: E402
from instruments import SDG_UPLOAD_SAFE_BYTES                  # noqa: E402
from siglent import SDG                                        # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECDIR = os.path.join(ROOT, 'out', 'vectors')

# THE MAPPING LIVES IN tools/vector_names.py, because the harnesses need it too -- an id is the local
# file and the point label, while the value is the name on the instrument, and a second copy of that
# table is a second thing to forget to update.
from vector_names import MAP, RETIRED                       # noqa: E402

NAME_RE = re.compile(r'^SER_[A-Za-z0-9_]+$')


def check_names():
    """Every mapped name is well formed and unique. -> list of complaints."""
    bad, seen = [], {}
    for vid, name in sorted(MAP.items()):
        if not NAME_RE.match(name):
            bad.append('%s -> %r is not SER_ + [A-Za-z0-9_]' % (vid, name))
        # A DOT WOULD ACTIVELY BREAK: ARWV? appends '.bin' and select_arb strips a trailing '.bin',
        # so a dot in a name collides with that logic. A comma terminates the WVDT WVNM field outright.
        if '.' in name or ',' in name:
            bad.append('%s -> %r contains a dot or comma' % (vid, name))
        if name in seen:
            bad.append('%s and %s both map to %r' % (seen[name], vid, name))
        seen[name] = vid
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--pace', type=float, default=0.4,
                    help='seconds between uploads (default 0.4)')
    # FOR REPAIRING A GAP without re-writing the set. A front-panel delete can take a neighbour by
    # accident, and re-uploading all 36 under-ceiling vectors to replace one is ~1.2 MB of writes for
    # 54 kB of need. IT IS ALSO THE ONLY WAY TO SEND AN OVER-CEILING VECTOR SAFELY: raising the ceiling
    # without --only sweeps every large file back into one batch, which is the wedge.
    ap.add_argument('--only', default=None,
                    help='comma-separated SER_ names to upload, instead of everything')
    # A BACKSLASH, AND ONLY A BACKSLASH. 'SERIAL\\name' stores and selects; 'SERIAL/name' and
    # '/SERIAL/name' are accepted by the write and then appear nowhere in STL? USER -- a silent
    # no-op, the worst of the three outcomes. Empty means the root.
    # ROOT BY DEFAULT, AND A FOLDER IS REFUSED WITHOUT --force-folder. A waveform in a subdirectory
    # CANNOT BE SELECTED AT ALL: STL? USER lists it, and ARWV NAME then refuses every form of the
    # request -- by path, by basename -- and leaves the PREVIOUS waveform playing, so every later
    # measurement is attributed to the wrong stimulus. WVDT? returns no LENGTH for one either, which
    # disables the read-back that would otherwise catch a zero-length file before it bricks the
    # generator at its next power-up. See siglent.select_arb. A tidy directory is worth neither.
    ap.add_argument('--folder', default='',
                    help='internal-flash folder. EMPTY IS CORRECT: a waveform in a subdirectory '
                         'can never be selected. Needs --force-folder to be non-empty.')
    ap.add_argument('--force-folder', action='store_true',
                    help='permit a non-empty --folder, which produces unselectable waveforms')
    a = ap.parse_args()
    if a.folder and not a.force_folder:
        raise SystemExit(
            'REFUSING: --folder %r would store waveforms in a subdirectory, and those can never be '
            'selected -- ARWV NAME refuses every form of the name and the previous waveform keeps '
            'playing, so a whole bench run measures the wrong stimulus. WVDT? also returns no LENGTH '
            'for them, which silently disables the zero-length check that protects the generator. '
            'Use the root (omit --folder), or --force-folder if you truly mean it.' % a.folder)

    bad = check_names()
    if bad:
        raise SystemExit('REFUSING: the name table is malformed:\n  ' + '\n  '.join(bad))

    with open(os.path.join(VECDIR, 'manifest.tsv')) as f:
        rows = {r['file'].replace('.bin', ''): r for r in csv.DictReader(f, delimiter='\t')}

    todo, toobig, unmapped = [], [], []
    for vid, r in sorted(rows.items()):
        if vid in RETIRED:
            continue
        if vid not in MAP:
            unmapped.append(vid)
            continue
        path = os.path.join(VECDIR, vid + '.bin')
        if not os.path.exists(path):
            raise SystemExit('REFUSING: %s is mapped but %s is missing' % (vid, path))
        n = os.path.getsize(path)
        # SIZE 0 IS NOT A SMALL UPLOAD. Reported on EEVblog, on earlier firmware: a stored zero-length
        # waveform crashes the generator at STARTUP. Recovery reportedly needs a key built from a disk
        # image Siglent does NOT publish and you have to ask for -- see the note in siglent.write_raw --
        # so treat it as unrecoverable. Sorting by size alone puts an empty or truncated .bin straight
        # into the upload list, so the length is checked here.
        if n == 0:
            raise SystemExit('REFUSING: %s is ZERO BYTES. Storing an empty waveform has been reported '
                             '(EEVblog, earlier firmware) to crash the generator at STARTUP; recovery '
                             'then needs a recovery-key image Siglent does not publish. Regenerate the '
                             'vectors with tools/make_vectors.lua.' % path)
        if n % 2:
            raise SystemExit('REFUSING: %s is %d bytes, an ODD length. Waveform data is 16-bit codewords, '
                             'so the file is truncated.' % (path, n))
        # The manifest is the second opinion: a file that does not match its recorded size is not the
        # vector the oracle describes, whatever its contents are.
        want = int(r.get('nbytes') or 0)
        if want and want != n:
            raise SystemExit('REFUSING: %s is %d bytes but manifest.tsv records %d. Regenerate rather '
                             'than upload a vector whose expected bytes are for a different file.'
                             % (path, n, want))
        (toobig if n > SDG_UPLOAD_SAFE_BYTES else todo).append((vid, MAP[vid], n, r))

    # SMALLEST FIRST. A wedge costs a power cycle and a human, so the cheap files go first: if the
    # generator stops answering, the most work is already banked and the failure is learned on a
    # 20 kB write rather than a 200 kB one. It also front-loads the read-back check, so a broken
    # verification path shows up in seconds instead of after the batch.
    todo.sort(key=lambda t: t[2])
    toobig.sort(key=lambda t: t[2])

    if a.only:
        keep = set(x.strip() for x in a.only.split(',') if x.strip())
        unknown = keep - set(MAP.values())
        if unknown:
            raise SystemExit('REFUSING: --only names nothing in the mapping: %s' % ' '.join(sorted(unknown)))
        todo = [t for t in todo if t[1] in keep]
        toobig = [t for t in toobig if t[1] in keep]
        unmapped = []
        if not todo and not toobig:
            raise SystemExit('REFUSING: --only matched nothing uploadable')

    if unmapped:
        raise SystemExit('REFUSING: in the manifest, neither mapped nor retired: %s\n'
                         'Add a name to MAP or list it in RETIRED -- silently skipping a vector is how '
                         'a suite ends up measuring the previous waveform.' % ' '.join(unmapped))

    print('%d to upload, %d over the %d-byte ceiling, %d retired'
          % (len(todo), len(toobig), SDG_UPLOAD_SAFE_BYTES, len(RETIRED)))
    print()
    for vid, name, n, r in todo:
        print('  %-5s -> %-24s %7d B  %s %s' % (vid, name, n, r['baud'], r['exp_fmt']))
    if toobig:
        print()
        print('  OVER THE CEILING, so refused here -- these are uploaded DELIBERATELY, not by this run.')
        print('  They still go over the LAN into internal flash: raise SDG_UPLOAD_SAFE_BYTES, name them')
        print('  with --only, pace them, verify each length, and keep it under three per power cycle.')
        print('  See bench/README.md. There is no USB-key path in use on this bench.')
        for vid, name, n, r in toobig:
            print('  %-5s -> %-24s %7d B  (%.1fx the ceiling)'
                  % (vid, name, n, float(n) / SDG_UPLOAD_SAFE_BYTES))
    print()
    if a.dry_run:
        print('--dry-run: nothing sent')
        return 0

    BS.require_sdg('upload_vectors')
    g = SDG()

    def user_list():
        r = g.query('STL? USER') or ''
        body = r.split('WVNM,', 1)[1] if 'WVNM,' in r else ''
        return set(x.strip() for x in body.strip().split(',') if x.strip())

    before = user_list()
    done, failed = [], []
    for k, (vid, name, n, r) in enumerate(todo):
        # The folder is a STORAGE path, not part of the name: STL? USER reports the stored string
        # verbatim ('SERIAL\SER_Hello_8N1') while ARWV? echoes the basename only. select_arb compares
        # basenames for exactly that reason.
        stored = ('%s\\%s' % (a.folder, name)) if a.folder else name
        with open(os.path.join(VECDIR, vid + '.bin'), 'rb') as f:
            payload = f.read()
        # WVDT ONLY -- no ARWV select, no BSWV, no TrueArb. Selecting each in turn would churn the output
        # 34 times for nothing; the harnesses select what they need. Uploading is the whole job here.
        g.write_raw('C1:WVDT WVNM,%s,WAVEDATA,' % stored, payload)
        time.sleep(a.pace)
        # VERIFIED PER UPLOAD, not once at the end. A write reports nothing, and a name that did not land
        # is indistinguishable from one that did until something tries to select it -- at which point the
        # PREVIOUS waveform keeps playing and the measurement is attributed to the wrong stimulus.
        if stored in user_list():
            # ASK THE INSTRUMENT WHAT IT ACTUALLY HAS, not just whether the name appeared. A name in
            # STL? USER proves a file exists, not that it holds the bytes we sent -- and a ZERO-LENGTH
            # file is the shape that bricks this generator at its NEXT POWER-UP. Which means there is
            # a window, right now, while it is still alive and answering: read the length back, and if
            # it is wrong, delete the file before anything power-cycles.
            got = g.stored_wave_length(stored)
            if got is None:
                print('  ok?  %-30s %7d B  (%d/%d)  -- WVDT? gave no LENGTH, size unverified'
                      % (stored, n, k + 1, len(todo)))
                done.append(stored)
            elif got == n:
                done.append(stored)
                print('  ok   %-30s %7d B  (%d/%d)  size confirmed' % (stored, n, k + 1, len(todo)))
            else:
                # 0 IS THE DANGEROUS ONE and it gets deleted rather than reported. Any other mismatch
                # is also deleted: a truncated waveform is not the stimulus the oracle describes, and
                # leaving it named correctly is how a bench run measures the wrong thing.
                failed.append(stored)
                print('  FAIL %-30s sent %d B, generator reports %d B' % (stored, n, got))
                try:
                    fn = g.delete_stored_wave(stored)
                    gone = stored not in user_list()
                    print('       deleted %s -- %s' % (fn, 'confirmed gone' if gone else
                                                       'STILL LISTED, delete did not take'))
                    if got == 0 and not gone:
                        raise SystemExit(
                            'STOPPING: a ZERO-LENGTH waveform is stored as %r and DEL_STORE_FILE did '
                            'not remove it. DO NOT POWER-CYCLE THE GENERATOR -- that is what turns '
                            'this into a dead instrument. Delete it from the front panel with '
                            'Store/Recall while the box is still up.' % stored)
                except SystemExit:
                    raise
                except Exception as e:
                    print('       delete FAILED: %s' % e)
                    if got == 0:
                        raise SystemExit(
                            'STOPPING: a ZERO-LENGTH waveform is stored as %r and it could not be '
                            'deleted. DO NOT POWER-CYCLE THE GENERATOR. Remove it from the front '
                            'panel with Store/Recall first.' % stored)
        else:
            failed.append(stored)
            print('  FAIL %-30s did not appear in STL? USER' % stored)

    print()
    print('%d uploaded, %d failed' % (len(done), len(failed)))
    after = user_list()
    print('USER waveforms on the instrument: %d before, %d after' % (len(before), len(after)))
    # EVERY name must end up SER_-prefixed, folder or not: split off the path before checking.
    def base(x):
        for sep in ('\\', '/'):
            if sep in x:
                x = x.rsplit(sep, 1)[-1]
        return x
    stray = sorted(x for x in after if not base(x).startswith('SER_'))
    if stray:
        print('NOT named SER_: %s' % ' '.join(stray))
    inroot = sorted(x for x in after if '\\' not in x and '/' not in x)
    if inroot and a.folder:
        print()
        print('%d still in the ROOT, needing front-panel deletion once these verify:' % len(inroot))
        for x in inroot:
            print('    %s' % x)
    if failed:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

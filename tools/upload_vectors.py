#!/usr/bin/env python3
"""Upload the bench vectors to the SDG2122X under their SER_ names.

WHY A TOOL RATHER THAN A ONE-OFF. The names are the contract -- see docs/VECTORS.md -- and a rename done
by hand is a rename done differently next time. This holds the mapping in one place, refuses anything that
cannot go over the LAN, and VERIFIES each name landed rather than trusting a write that reports nothing.

THE 65536-BYTE CEILING IS NOT ABOUT SPACE. The generator reports ~80 MB of internal flash free and the
whole planned set is ~2.3 MB, so capacity is irrelevant. SDG_UPLOAD_SAFE_BYTES exists because four
consecutive WVDT uploads of 170-210 kB WEDGED this generator's LAN service (tools/instruments.py, measured
2026-08-16): it keeps answering pings and refuses the SCPI port until power-cycled. So the ceiling stands
however much flash is free, and this tool refuses rather than warns.

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

# THE MAPPING, and it is the whole point of the file. Keyed by the id in manifest.tsv.
#
# The name states the payload and the WIRE format, never the baud rate -- the rate comes from the sample
# rate at selection time, so one waveform serves every rate. See docs/VECTORS.md for why v44e is 8N2 when
# the manifest's exp_fmt says 8N1, and why the pattern vectors are 8N1 when it says 7E1/7O1.
MAP = {
    'v41':  'SER_Hello_8N1',
    'v44a': 'SER_Hello_7E1',
    'v44b': 'SER_Hello_7O1',
    'v44c': 'SER_Hello_8E1',
    'v44d': 'SER_Hello_8O1',
    'v44e': 'SER_Hello_8N2',          # two stop bits; nothing but this name records that
    'v45':  'SER_Hello_8N1_Inv',
    'v46':  'SER_Page200B_8N1',
    'v47':  'SER_Hello_8N1_Spike',
    'v48a': 'SER_Hello_8N1_Drift06',
    'v48b': 'SER_Hello_8N1_Drift10',
    'v51':  'SER_MIDI_8N1',
    'v61':  'SER_LIN_01',
    'v62':  'SER_LIN_02',
    'v63':  'SER_LIN_03',
    'v76':  'SER_Lorem300B_8N1',
    'v77':  'SER_Fox_8N1',
    'v78':  'SER_Fox_7E1',
    'v80':  'SER_Hello_8N1_Sp10',     # 10.00 samples/bit; v41 is 10.42. See RETIRED note below.
    'v90':  'SER_Blocks256B_8N1',
    'v91':  'SER_RandomRef_8N1',
    'v92':  'SER_Walk_8N1',
    'v71':  'SER_Lorem1kB_8N1',       # over the ceiling -- USB key only, refused here
    'v93':  'SER_Random1kB_8N1',      # over the ceiling
    'v94':  'SER_Blocks512B_8N1',     # over the ceiling
}
for _i in range(6):
    MAP['r%02d' % _i] = 'SER_Random_%02d_8N1' % (_i + 1)
for _i in range(6, 12):
    MAP['r%02d' % _i] = 'SER_Random_%02d_7E1' % (_i + 1)

# DELIBERATELY UNNAMED, so they are not uploaded: same payload as a vector that already has a name,
# re-rendered at a different points-per-bit. With the rate set by srate they carry no information.
#   v42 v43         Hello re-rendered for 115200 / 250000
#   v72 v73         BYTE-IDENTICAL to v71 (checked: same Fletcher-32)
#   v74 v75         Lorem1kB re-rendered at 8.68 / 8.33 points per bit
#   v81 v82 v83 v84 BYTE-IDENTICAL to v80
RETIRED = {'v42', 'v43', 'v72', 'v73', 'v74', 'v75', 'v81', 'v82', 'v83', 'v84'}

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
    # A BACKSLASH, AND ONLY A BACKSLASH. Measured 2026-08-19: 'SERIAL\\name' stores and selects;
    # 'SERIAL/name' and '/SERIAL/name' were accepted by the write and then appeared nowhere in
    # STL? USER -- a silent no-op, which is the worst of the three outcomes. Empty means the root.
    ap.add_argument('--folder', default='SERIAL',
                    help=r'internal-flash folder, joined with a backslash (default SERIAL; "" = root)')
    a = ap.parse_args()

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
        (toobig if n > SDG_UPLOAD_SAFE_BYTES else todo).append((vid, MAP[vid], n, r))

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
        print('  CANNOT GO OVER THE LAN -- USB key only (see out/vectors/USB-TRANSFER.md):')
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
            done.append(stored)
            print('  ok   %-30s %7d B  (%d/%d)' % (stored, n, k + 1, len(todo)))
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

#!/usr/bin/env python3
"""The one mapping from a local vector id to its name on the generator.

WHY THIS IS A SEPARATE MODULE. A vector id like `v41` is used for THREE different things across the
harnesses, and after the 2026-08-19 rename they are no longer the same string:

    1. the name of the waveform ON THE INSTRUMENT      -> 'SER_Hello_8N1'
    2. the local oracle file the capture is checked against -> out/vectors/v41.txt
    3. the POINT LABEL in a soak log or a bench report  -> 'format v41'

So a find-and-replace of the ids would have quietly broken every oracle lookup and renamed every point,
making historical soak logs incomparable and rejudge_soak.py's matching fail. Instead the id stays
canonical -- files and labels keep working, soak history stays comparable -- and it is translated to the
instrument's name at exactly one place: the select_arb() call.

The names themselves, and why they carry no baud rate, are in docs/VECTORS.md.
"""

# Local id -> name on the SDG. Nothing here may contain anything but [A-Za-z0-9_]: a dot collides with
# the '.bin' that ARWV? appends and select_arb strips, and a comma terminates the WVDT WVNM field.
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
    'v71':  'SER_Lorem1kB_8N1',
    'v76':  'SER_Lorem300B_8N1',
    'v77':  'SER_Fox_8N1',
    'v78':  'SER_Fox_7E1',
    'v80':  'SER_Hello_8N1_Sp10',     # 10.00 samples/bit; v41 is 10.42
    'v90':  'SER_Blocks256B_8N1',
    'v91':  'SER_RandomRef_8N1',
    'v92':  'SER_Walk_8N1',
    'v93':  'SER_Random1kB_8N1',
    'v94':  'SER_Blocks512B_8N1',
    'v95':  'SER_Random8kB_8N1',
    'v96':  'SER_Random32kB_8N1',
}
for _i in range(6):
    MAP['r%02d' % _i] = 'SER_Random_%02d_8N1' % (_i + 1)
for _i in range(6, 12):
    MAP['r%02d' % _i] = 'SER_Random_%02d_7E1' % (_i + 1)

# DELIBERATELY UNNAMED, therefore not on the instrument: the same payload as a vector that already has a
# name, re-rendered at a different points-per-bit. With the rate set by srate at selection time they carry
# no information, and four of them were the largest files in the set.
#   v42 v43          Hello re-rendered for 115200 / 250000
#   v72 v73          BYTE-IDENTICAL to v71 (same Fletcher-32)
#   v74 v75          Lorem1kB re-rendered at 8.68 / 8.33 points per bit
#   v81 v82 v83 v84  BYTE-IDENTICAL to v80
RETIRED = {'v42', 'v43', 'v72', 'v73', 'v74', 'v75', 'v81', 'v82', 'v83', 'v84'}

# Over SDG_UPLOAD_SAFE_BYTES, so these reached the instrument the slow way and must not be re-uploaded
# casually -- three over-ceiling WVDT writes in one session wedge the LAN service.
BIG = {'v71', 'v93', 'v94', 'v95', 'v96'}


def arb(vid):
    """The generator's name for a local vector id. Raises rather than guessing.

    A KeyError here is the right outcome: a silent fallback to `vid` would send 'v41' to the instrument,
    where ARWV NAME does nothing, and the PREVIOUS waveform would keep playing while the measurement was
    attributed to this one. select_arb's readback catches that, but only after a wasted point.
    """
    try:
        return MAP[vid]
    except KeyError:
        if vid in RETIRED:
            raise KeyError('%r is retired and is not on the instrument -- it is a duplicate render of a '
                           'vector that has a name. See tools/vector_names.py.' % vid)
        raise KeyError('%r has no name on the generator. Add it to MAP in tools/vector_names.py, or to '
                       'RETIRED if it is a redundant render.' % vid)


def stored(stl_reply):
    """Parse an `STL? USER` reply into a set of stored names. -> set of str.

    EXACT NAMES, NOT A SUBSTRING TEST, and the rename is what makes that mandatory. Both presence checks
    in this repo used `(',' + vid) in reply`, which was safe for three-character ids and is not safe now:
    'SER_Hello_8N1' is a PREFIX of 'SER_Hello_8N1_Sp10', so a missing vector reads as present whenever its
    longer sibling exists. A false "present" is the dangerous direction -- the suite then selects a name
    that is not there, ARWV NAME does nothing, and every measurement is attributed to whatever was playing
    before.

    A stored name may carry a folder prefix; the basename is what ARWV can select, and only the root is
    selectable at all (see the folder note in tools/instruments.py), so a foldered entry is deliberately
    NOT reported as stored.
    """
    body = stl_reply.split('WVNM,', 1)[1] if 'WVNM,' in stl_reply else ''
    out = set()
    for x in body.strip().split(','):
        x = x.strip()
        if x and '\\' not in x and '/' not in x:
            out.add(x)
    return out


def missing(stl_reply, vids):
    """Which of `vids` are not on the instrument. -> list of local ids, order preserved."""
    have = stored(stl_reply)
    return [v for v in vids if arb(v) not in have]

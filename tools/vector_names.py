#!/usr/bin/env python3
"""The one mapping from a local vector id to its name on the generator.

WHY THIS IS A SEPARATE MODULE. A vector id like `v41` names THREE different things across the
harnesses, and they are not the same string:

    1. the name of the waveform ON THE INSTRUMENT      -> 'SER_Hello_8N1'
    2. the local oracle file the capture is checked against -> out/vectors/v41.txt
    3. the POINT LABEL in a soak log or a bench report  -> 'format v41'

So a find-and-replace of the ids quietly breaks every oracle lookup and renames every point, making
soak logs incomparable across the change and rejudge_soak.py's matching fail. Instead the id stays
canonical -- files and labels keep working, soak history stays comparable -- and it is translated to the
instrument's name at exactly one place: the select_arb() call.

The names themselves, and why they carry no baud rate, are in docs/VECTORS.md.
"""

# Local id -> name on the SDG. Nothing here may contain anything but [A-Za-z0-9_]: a dot collides with
# the '.bin' that ARWV? appends and select_arb strips, and a comma terminates the WVDT WVNM field.
MAP = {
    'v41':  'SER_Hello_8N1_x10',
    'v44a': 'SER_Hello_7E1_x10',
    'v44b': 'SER_Hello_7O1_x10',
    'v44c': 'SER_Hello_8E1_x10',
    'v44d': 'SER_Hello_8O1_x10',
    'v44e': 'SER_Hello_8N2_x10',          # two stop bits; nothing but this name records that
    'v45':  'SER_Hello_8N1_Inv_x10',
    'v46':  'SER_Page200B_8N1_x10',
    'v47':  'SER_Hello_8N1_Spike_x100',
    'v48a': 'SER_Hello_8N1_Drift06_x10',
    'v48b': 'SER_Hello_8N1_Drift10_x10',
    'v51':  'SER_MIDI_8N1_x10',
    'v61':  'SER_LIN_01_x10',
    'v62':  'SER_LIN_02_x10',
    'v63':  'SER_LIN_03_x10',
    'v71':  'SER_Lorem1kB_8N1_x10',
    'v76':  'SER_Lorem300B_8N1_x10',
    'v77':  'SER_Fox_8N1_x10',
    'v78':  'SER_Fox_7E1_x10',
    'v90':  'SER_Blocks256B_8N1_x10',
    'v91':  'SER_RandomRef_8N1_x10',
    'v92':  'SER_Walk_8N1_x10',
    'v93':  'SER_Random1kB_8N1_x10',
    'v94':  'SER_Blocks512B_8N1_x10',
    'v95':  'SER_Random8kB_8N1_x10',
    'v96':  'SER_Random32kB_8N1_x10',
    # v93's own bytes with bit 7 cleared. '7bit' is in the name because that is the ONE thing that
    # distinguishes it from v93, and the pair is only worth having if the difference is legible here.
    'v97':  'SER_Random1kB7bit_8N1_x10',
    # ---------------------------------------------------------------------------------------------
    # FULL SCALE: the data band spans -32767..+32767 instead of the 0..21626 every vector above
    # renders, so the band on the wire is OFST +/- AMP/2 exactly and AMP 10 OFST 0 is a true
    # -5..+5 V line.
    #
    # THE NAME LENGTH IS A HARD BUDGET, NOT A STYLE QUESTION, and it is 16 characters of
    # CONTENT-PLUS-VARIANT rather than of the whole name. The soak panel's bottom line is
    # brun.cellline() -- id, baud, format, then brun.wave(), which is the stored name with 'SER_',
    # '_x10' and the format token stripped. display.settext caps TEXT2 at 32 characters and the
    # firmware posts a warning event and shortens anything longer, which for a soak is a box on the
    # panel once per cell. At the widest baud the bench drives (250000, six digits) and a
    # four-character id (v44a-v44e) the fixed part is 16, so brun.wave() must be <= 16.
    #
    # THE RULE FOR THE NEXT VECTOR: measure id + ' ' + baud + ' ' + fmt + ' ' + brun.wave(name)
    # against 32, and abbreviate the CONTENT token, not the variant -- the variant is what the row
    # exists to tell you apart. 'FullScale' (9) therefore became 'Full' (4) and 'Random256B' (10)
    # became 'Rnd256B' (7), which puts the widest of these at 16: 'Rnd256B_Inv_Full'.
    # tools/test_bench_engine.lua asserts the budget over every name in this table.
    #
    # STILL NOT 'FS', even though it is shorter: fs means SAMPLE RATE everywhere else in this repo
    # (sdec.fs, acq_fs, srate_sa_s), so 'SER_Fox_8N1_FS_x10' would read as a rate. 'Full' is four
    # characters and cannot.
    #
    # THE SIZE KEEPS ITS UNIT through the abbreviation -- 'Rnd256B', not 'Rnd256' -- because a bare
    # number in a name is exactly what docs/VECTORS.md forbids: 256 and 1024 are payload lengths here
    # but 300 and 600 would be baud rates.
    #
    # f00/f01/f02 are levels-only pairs for v41/v77/v78: same payload, same baud, same samples per
    # bit, same point count, same byte count, and the codeword span is the only difference.
    'f00':  'SER_Hello_8N1_Full_x10',
    'f01':  'SER_Fox_8N1_Full_x10',
    'f02':  'SER_Fox_7E1_Full_x10',
    'f03':  'SER_Fox_7O1_Full_x10',
    'f04':  'SER_Rnd256B_8N1_Full_x10',
    'f05':  'SER_Rnd256B_7E1_Full_x10',
    'f06':  'SER_Rnd256B_7O1_Full_x10',
    # The only one over the upload ceiling. Its length exists to defeat the loop seam at a matched
    # sdec.fs, where a capture is 20000 arb samples and a 256-byte payload holds the seam in 78 % of
    # them; see the comment on f07 in tools/make_vectors.lua. f04's 256 bytes are its exact prefix.
    'f07':  'SER_Rnd1kB_8N1_Full_x10',
    # INVERTED, i.e. RS-232 sense: idle is the LOW codeword, so AMP 10 OFST 0 is a true -5/+5 V line.
    # f1x is the counterpart of f0x. 'Inv' sits straight after the format, as v45's
    # SER_Hello_8N1_Inv_x10 does. No f17: an inverted f07 is not wanted, and the gap says so.
    # No AMP/OFST pair turns an f0x file into one of these -- amplitude and offset scale and shift the
    # band, they cannot flip it, so the sense is a property of the FILE.
    'f10':  'SER_Hello_8N1_Inv_Full_x10',
    'f11':  'SER_Fox_8N1_Inv_Full_x10',
    'f12':  'SER_Fox_7E1_Inv_Full_x10',
    'f13':  'SER_Fox_7O1_Inv_Full_x10',
    'f14':  'SER_Rnd256B_8N1_Inv_Full_x10',
    'f15':  'SER_Rnd256B_7E1_Inv_Full_x10',
    'f16':  'SER_Rnd256B_7O1_Inv_Full_x10',
    # x100, because a 2 % edge displacement cannot be rendered at x10 -- the sample grid there is
    # +-5 % of a bit, so the quantisation would be larger than the impairment. The percentage is in
    # the name: it is the one number that distinguishes these three from each other.
    'j02':  'SER_Jitter02pct_x100',
    'j10':  'SER_Jitter10pct_x100',
    'j20':  'SER_Jitter20pct_x100',
}
for _i in range(6):
    MAP['r%02d' % _i] = 'SER_Random_%02d_8N1_x10' % (_i + 1)
for _i in range(6, 12):
    MAP['r%02d' % _i] = 'SER_Random_%02d_7E1_x10' % (_i + 1)

# EMPTY, and kept so that a future redundant render has somewhere to go. Baud comes from srate at
# selection time, so ONE waveform serves every rate and a per-rate re-render carries no information --
# the ten that existed are deleted rather than listed here.
RETIRED = {}

# Over SDG_UPLOAD_SAFE_BYTES, so these reached the instrument the slow way and must not be re-uploaded
# casually -- three over-ceiling WVDT writes in one power cycle wedge the LAN service.
BIG = {'v71', 'v93', 'v94', 'v95', 'v96', 'v97', 'f07'}

# ---------------------------------------------------------------------------------------------------
# NOT SOAK MATERIAL. On the instrument, selectable by name, and deliberately OUT of the soak's draw --
# tools/soakplan.soak_vectors() is the one place that applies this, and every draw site goes through it.
#
# These drive the ARM feature at CHOSEN levels. The soak draws its own amplitude and offset per cell,
# and that is exactly what these must not be handed:
#
#   1. THE f0x SET AT THE SOAK'S OWN AMPLITUDES WOULD POISON IT. A full-scale file straddles ground at
#      any symmetric band, and sdec.sig_levels reads a ground-straddling band as RS-232 -- marking at
#      its NEGATIVE level -- which is upside-down for a vector that idles positive. Measured over 48
#      window phases: the prior is wrong in 34 of 34 no-idle windows and f01 decodes 0 of 34
#      payload-exact against 5 of 34 on a single-rail band. This repo already carries that mechanism as
#      a HARNESS artefact rather than a defect: 17.3 % of offline cells driven across ground accounted
#      for 86.8 % of a whole class of failure, and the app was right every time. Drawing f0x into the
#      soak would manufacture that at scale and the failures would all be the stimulus.
#   2. THE POPULATION IS WHAT THE RATCHETS ARE CALIBRATED ON. plan_order applies the skip BEFORE the
#      shuffle, so adding a vector gives every surviving vector a different amplitude, offset and wait
#      -- see the HW_SKIP comment in tools/soakplan.py, which records the same trap for v97. Lap size
#      is load-bearing too: 6 x 1683 = 10098 appears in the gate and must never be "fixed".
#   3. They are bench instruments. A soak measures repeatability over the standard lap; these answer a
#      specific question about levels, and the two jobs want different stimulus.
#
# NOT A REFUSAL: --spec and --skip-vectors still accept any id in MAP, so naming one of these
# deliberately works. This governs the DRAW only, which is the thing nobody asks for explicitly.
BENCH_ONLY = {'f00', 'f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07',
              'f10', 'f11', 'f12', 'f13', 'f14', 'f15', 'f16'}


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

    EXACT NAMES, NOT A SUBSTRING TEST, and the SER_ names are what make that mandatory. A check of the
    form `(',' + vid) in reply` is safe for three-character ids and unsafe for these:
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

#!/usr/bin/env python3
"""Every route by which an out-of-spec waveform could reach the SDG2122X must refuse it.

WHY THIS FILE IS A GATE AND NOT A COMMENT. A zero-length or undersized waveform stored on this
generator BRICKS IT AT THE NEXT POWER-UP, stock firmware has no shell to recover through, and there is
one instrument with no replacement. The refusal therefore has to be tested, not asserted in prose --
and it has to be tested against the specific bypasses that were found, because the guard it replaces
looked completely adequate while three of them existed.

Reviewed 2026-08-19; the three that worked before this gate:
  1. write_raw('C1:', b'WVDT WVNM,x,WAVEDATA,' + b'\\x00\\x00')  -- the check keyed on `'WVDT' in
     prefix`, and this prefix has none, so a valid two-byte upload went out unexamined.
  2. write('C1:WVDT WVNM,x,WAVEDATA,')  -- write() had no check at all. One line, empty waveform,
     which is the exact reported brick. query() identically.
  3. sdg_hang_repro.upload(..., codewords=[])  -- a raw socket, deliberately not using the driver.

transport='dry' throughout: no socket is opened and no instrument is contacted. The refusals happen
BEFORE the dry-run return on purpose, so this proves what a real socket would do.

    python3 tools/test_sdg_guard.py
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sdg_hang_repro as HR                                             # noqa: E402
import siglent as S                                                    # noqa: E402
from instruments import SDG_MIN_WAVE_BYTES, SDG_MAX_WAVE_BYTES          # noqa: E402

npass, nfail = 0, 0


def refuses(what, fn):
    """fn() must raise ValueError. A TypeError or a silent success both fail."""
    global npass, nfail
    try:
        fn()
    except ValueError:
        npass += 1
        print('  PASS  refused: %s' % what)
        return
    except Exception as e:
        nfail += 1
        print('  FAIL  %s raised %s, not ValueError: %s' % (what, type(e).__name__, e))
        return
    nfail += 1
    print('  FAIL  ACCEPTED: %s' % what)


def accepts(what, fn):
    """The converse, and it earns its place: a guard that refuses everything is not a guard, it is
    an outage, and it would be discovered at the bench rather than here."""
    global npass, nfail
    try:
        fn()
    except Exception as e:
        nfail += 1
        print('  FAIL  refused a LEGITIMATE case: %s -- %s: %s' % (what, type(e).__name__, e))
        return
    npass += 1
    print('  PASS  accepted: %s' % what)


def g():
    return S.SDG(transport='dry')


GOOD = b'\x00\x10\x00\x20'          # 4 bytes, even, the manual's floor exactly
PREFIX = 'C1:WVDT WVNM,t,WAVEDATA,'

print('the payload check itself')
for n in (0, 1, 2, 3):
    refuses('%d bytes via sdg_check_wave_payload' % n,
            lambda n=n: S.sdg_check_wave_payload(b'\x00' * n))
refuses('5 bytes -- odd, so a truncated file',
        lambda: S.sdg_check_wave_payload(b'\x00' * 5))
refuses('one byte over the 16 MiB ceiling',
        lambda: S.sdg_check_wave_payload(b'\x00' * (SDG_MAX_WAVE_BYTES + 2)))
refuses('a str payload, whose encoded length need not match',
        lambda: S.sdg_check_wave_payload('\x00\x00\x00\x00'))
refuses('None', lambda: S.sdg_check_wave_payload(None))
refuses('a list of ints', lambda: S.sdg_check_wave_payload([0, 0, 0, 0]))
refuses('a generator, which has no length to check',
        lambda: S.sdg_check_wave_payload(x for x in b'\x00\x00\x00\x00'))
accepts('exactly %d bytes' % SDG_MIN_WAVE_BYTES, lambda: S.sdg_check_wave_payload(GOOD))
accepts('a bytearray of 4', lambda: S.sdg_check_wave_payload(bytearray(GOOD)))
accepts('a memoryview of 4', lambda: S.sdg_check_wave_payload(memoryview(GOOD)))

print()
print('BYPASS 1 -- the command smuggled into the payload, so the prefix has no WVDT')
refuses("write_raw('C1:', b'WVDT ... WAVEDATA,' + 2 bytes)",
        lambda: g().write_raw('C1:', b'WVDT WVNM,bad,WAVEDATA,' + b'\x00\x00'))
refuses('the same padded to an even, in-range payload length',
        lambda: g().write_raw('C1:', b'WVDT WVNM,bad,WAVEDATA,' + b'\x00' * 41))
refuses('a prefix that names WVDT but not WAVEDATA,',
        lambda: g().write_raw('C1:WVDT WVNM,bad,', GOOD))
refuses('an empty prefix', lambda: g().write_raw('', GOOD))
accepts('the real upload prefix with a 4-byte payload',
        lambda: g().write_raw(PREFIX, GOOD))

print()
print('BYPASS 2 -- the text methods, which had no check of any kind')
refuses("write('C1:WVDT WVNM,x,WAVEDATA,') -- an EMPTY waveform",
        lambda: g().write('C1:WVDT WVNM,bad,WAVEDATA,'))
refuses('the same with one trailing character, an odd 1-byte waveform',
        lambda: g().write('C1:WVDT WVNM,bad,WAVEDATA,\x00'))
refuses('lower case, since SCPI does not care',
        lambda: g().write('c1:wvdt wvnm,bad,wavedata,'))
refuses('query() on the same command -- it sends before it reads',
        lambda: g().query('C1:WVDT WVNM,bad,WAVEDATA,'))
accepts('C1:WVDT? -- a READ, which carries no data', lambda: g().query('C1:WVDT?'))
accepts('an ordinary command naming no WVDT', lambda: g().write('C1:ARWV NAME,SER_Hello_8N1'))
accepts('STL? USER', lambda: g().query('STL? USER'))

print()
print('BYPASS 3 -- the raw socket in sdg_hang_repro, which does not use the driver')
# NO SOCKET IS OPENED: the guard is the first statement in upload(), before socket(), so a refusal
# happens without touching the network. An accepted call would try to connect and fail on the
# unreachable address -- which is why these assert ValueError specifically and not "any exception".
refuses('upload() with no codewords at all -- --kb 0',
        lambda: HR.upload('192.0.2.1', 'bad', []))
refuses('upload() with one codeword, a 2-byte waveform',
        lambda: HR.upload('192.0.2.1', 'bad', [0]))

print()
print('the delete path -- vendor-documented, destructive, wildcard-capable')
refuses('DEL_STORE_FILE with a * wildcard, which would take every stored vector',
        lambda: g().delete_stored_wave('SER_*'))
refuses('a bare * ', lambda: g().delete_stored_wave('*'))
refuses('a ? wildcard', lambda: g().delete_stored_wave('SER_Random_0?_8N1'))
accepts('a literal name', lambda: g().delete_stored_wave('SER_Hello_8N1'))
accepts('a wildcard WHEN FORCED, since that has to remain possible',
        lambda: g().delete_stored_wave('SER_*', force=True))


def _sent(name, **kw):
    """The command a delete actually puts on the wire, via the dry log."""
    d = g()
    d.delete_stored_wave(name, **kw)
    return d.log[-1]


# THE .bin SUFFIX IS THE WHOLE TRAP HERE: STL? USER reports 'SER_Hello_8N1' and the vendor note
# deletes 'Test1.bin', so a delete built from a listed name would silently address a file that does
# not exist -- and a delete that quietly does nothing is worse than an error, because the caller then
# believes a zero-length waveform is gone.
for nm, want in (('SER_Hello_8N1', 'DEL_STORE_FILE SER_Hello_8N1.bin'),
                 ('SER_Hello_8N1.bin', 'DEL_STORE_FILE SER_Hello_8N1.bin'),
                 ('SER_Hello_8N1.BIN', 'DEL_STORE_FILE SER_Hello_8N1.BIN')):
    got = _sent(nm)
    if got == want:
        npass += 1
        print('  PASS  %-22r -> %s' % (nm, got))
    else:
        nfail += 1
        print('  FAIL  %-22r -> %s, expected %s' % (nm, got, want))

print()
print('the constants still agree with the manual')
if SDG_MIN_WAVE_BYTES == 4 and SDG_MAX_WAVE_BYTES == 16 * 1024 * 1024:
    npass += 1
    print('  PASS  4 bytes .. 16 MiB, as the SDG2000-series programming guide states')
else:
    nfail += 1
    print('  FAIL  range is %d..%d, not the manual\'s 4..16 MiB'
          % (SDG_MIN_WAVE_BYTES, SDG_MAX_WAVE_BYTES))

print()
print('%d passed, %d failed' % (npass, nfail))
sys.exit(1 if nfail else 0)

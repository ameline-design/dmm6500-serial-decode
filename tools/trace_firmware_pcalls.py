#!/usr/bin/env python3
"""Build a .tspa that logs every firmware pcall it is about to make, and every one it survived.

WHAT IT IS FOR. A bluescreen leaves no stack, only a PC. But ulog.line() FLUSHES EVERY LINE to
the USB key -- that is where 89-97 % of its 4.6 ms goes -- so a line written before a call is on
the key even if the instrument dies inside that call. The LAST unmatched `>` in the log therefore
names the firmware call that killed it, which no amount of bisecting builds can do.

TRACED: firmware pcalls in serial_core, serial_ui, serial_app and chunk_decode.
NOT TRACED: tsp/usb_log.tsp, because the trace writer goes through ulog.line, which goes through
file.write -- tracing that recurses. sdec.tr also carries its own reentrancy flag, belt and
braces, since a traced call inside the log path would otherwise spin.

GATED AT RUNTIME, not at build time. sdec.trace_on is false until something sets it, and the
generated archive sets it around the LAUNCH capture only. So the panel behaves normally and the
volume is bounded to one capture: about 65 call sites, 130 lines, well under a second of flushing.
sdec.trace_max caps it regardless, because a traced call inside a per-sample loop would otherwise
fill the key.

    python3 tools/trace_firmware_pcalls.py --out ~/tmp/TRACE.tspa

Read the log afterwards from /usb1/SERDEC/serial_decode_log.txt -- the tail is the answer.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FW_SDEC = ('sdec.dig', 'sdec.atrig', 'sdec.atedge', 'sdec.meas', 'sdec.buf', 'sdec.k.')
FW = ('display.', 'file.', 'buffer.', 'dmm.', 'trigger.', 'localnode.', 'eventlog.',
      'script.', 'fs.', 'os.', 'collectgarbage', 'delay(', 'waitcomplete', 'timer.') + FW_SDEC
TRACE_FILES = ['tsp/serial_core.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp',
               'tsp/chunk_decode.tsp']

# Injected into serial_core.tsp right after the sdec table exists.
TRACER = """
-- ==================== firmware-call trace (generated build only) ====================
sdec.trace_on  = false
sdec.trace_n   = 0
sdec.trace_max = 4000
sdec.tr_busy   = false

-- Log one side of a firmware call. Written through ulog.line, which flushes every line, so a
-- line survives a bluescreen inside the call that follows it.
--
-- REENTRANCY GUARDED: the writer itself reaches file.write, and a traced call on that path would
-- recurse without this. CAPPED: a traced call inside a per-sample loop would fill the key.
function sdec.tr(s)
  if not sdec.trace_on then return false end
  if sdec.tr_busy then return false end
  if sdec.trace_n >= sdec.trace_max then return false end
  sdec.tr_busy = true
  sdec.trace_n = sdec.trace_n + 1
  ulog.line('TR ' .. tostring(s))
  sdec.tr_busy = false
  return true
end
"""


def firmware(s):
    return any(t in s for t in FW)


def symbol(s):
    m = re.search(r'\b((?:display|file|buffer|dmm|trigger|localnode|eventlog|script|fs|os|timer)'
                  r'\.[A-Za-z_]\w*|collectgarbage|delay|waitcomplete'
                  r'|sdec\.(?:dig|atrig|atedge|meas|buf)\.[A-Za-z_]\w*)', s)
    return m.group(1) if m else 'fw'


def instrument(path, rel):
    lines = open(path, newline='').read().split('\n')
    out, n = [], 0
    i = 0
    while i < len(lines):
        L = lines[i]
        raw = L.rstrip('\r')
        cr = '\r' if L.endswith('\r') else ''
        stripped = raw.lstrip()
        ind = raw[:len(raw) - len(stripped)]
        # A pcall that both opens and closes on this line.
        if 'pcall(function()' in raw and raw.rstrip().endswith('end)') and firmware(raw) \
                and not stripped.startswith('--'):
            lab = '%s:%d %s' % (rel, i + 1, symbol(raw))
            out.append(ind + "sdec.tr('>" + lab + "')" + cr)
            out.append(L)
            # NO 'AFTER' LINE ON A return. Lua requires `return` to be the LAST statement
            # in its block, so a trace line following it is a syntax error, not dead code.
            # The 'before' line is what names a crash anyway; a missing 'after' only means
            # the call returned into a tail position.
            if not re.match(r'^\s*return\b', raw):
                out.append(ind + "sdec.tr('<" + lab + "')" + cr)
            n += 1
            i += 1
            continue
        # A pcall opened on this line and closed by `end)` at the same indent.
        if re.match(r'^.*pcall\(function\(\)\s*$', raw) and not stripped.startswith('--'):
            close = None
            for j in range(i + 1, min(i + 60, len(lines))):
                if lines[j].rstrip('\r') == ind + 'end)':
                    close = j
                    break
            if close is not None:
                block = '\n'.join(x.rstrip('\r') for x in lines[i:close + 1])
                if firmware(block):
                    lab = '%s:%d %s' % (rel, i + 1, symbol(block))
                    out.append(ind + "sdec.tr('>" + lab + "')" + cr)
                    out.extend(lines[i:close + 1])
                    if not re.match(r'^\s*return\b', raw):
                        out.append(ind + "sdec.tr('<" + lab + "')" + cr)
                    n += 1
                    i = close + 1
                    continue
        out.append(L)
        i += 1
    return '\n'.join(out), n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--name', default='TRACE')
    a = ap.parse_args()

    stage = tempfile.mkdtemp(prefix='trace_')
    try:
        shutil.copytree(os.path.join(ROOT, 'tsp'), os.path.join(stage, 'tsp'))
        shutil.copytree(os.path.join(ROOT, 'tools'), os.path.join(stage, 'tools'))
        total = 0
        for rel in TRACE_FILES:
            p = os.path.join(stage, rel)
            new, n = instrument(p, rel.split('/')[-1].replace('.tsp', ''))
            open(p, 'w', newline='').write(new)
            print('  %-24s %3d call sites traced' % (rel, n))
            total += n
        print('total traced: %d' % total)

        # The tracer itself, after `sdec = sdec or {}` in serial_core.
        p = os.path.join(stage, 'tsp/serial_core.tsp')
        s = open(p, newline='').read()
        anchor = 'sdec = sdec or {}'
        k = s.index(anchor) + len(anchor)
        k = s.index('\n', k) + 1
        nl = '\r\n' if '\r\n' in s else '\n'
        open(p, 'w', newline='').write(
            s[:k] + (TRACER.replace('\n', nl) if nl != '\n' else TRACER) + s[k:])

        # Launch capture, traced: the whole point. Tracing is switched on immediately before it
        # and off after, so nothing else in the session writes trace lines.
        p = os.path.join(stage, 'tsp/serial_app.tsp')
        s = open(p, newline='').read()
        # LINE ENDING DETECTED, NOT ASSUMED: tsp/ sources are LF and only the packaged archive
        # is CRLF, so a hard-coded '\r\n' anchor finds nothing here.
        nl = '\r\n' if '\r\n' in s else '\n'
        anchor = '  return true' + nl + 'end' + nl
        k = s.rindex(anchor)
        ins = ''.join(x + nl for x in (
            "  sdec.trace_on = true",
            "  ulog.line('TR ==== launch capture begins ====')",
            "  sdec.capture()",
            "  ulog.line('TR ==== launch capture returned ====')",
            "  sdec.trace_on = false"))
        s = s[:k] + ins + s[k:]
        open(p, 'w', newline='').write(s)

        r = subprocess.run([sys.executable, 'tools/package_tspa.py',
                            '--out', os.path.abspath(a.out),
                            '--icon-png', os.path.join(stage, 'icon.png')],
                           cwd=stage, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit('packaging failed:\n' + r.stdout + r.stderr)
        print(r.stdout.strip().split('\n')[-2] if r.stdout else '')

        b = open(a.out, newline='').read()
        for o, rep in (('loadscript Serial_Decode', 'loadscript ' + a.name),
                       ('loadimage sdec_icon Serial_Decode', 'loadimage sdec_icon ' + a.name),
                       ('-- $Title: Serial Decode', '-- $Title: ' + a.name)):
            b = b.replace(o, rep)
        open(a.out, 'w', newline='').write(b)
        print('wrote %s as script %s' % (a.out, a.name))
    finally:
        shutil.rmtree(stage, ignore_errors=True)


if __name__ == '__main__':
    main()

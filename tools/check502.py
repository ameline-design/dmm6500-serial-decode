#!/usr/bin/env python3
"""Run a statement under the instrument's own Lua BEFORE sending it to the DMM6500.

    python3 tools/check502.py 'do local a,b = string.byte("abcd", 1, 2) print(a, b) end'
    python3 tools/check502.py --file probe.lua
    python3 tools/check502.py --self-test
    echo 'print(math.fmod(7,3))' | python3 tools/check502.py -

WHY THIS EXISTS. tools/lint_tsp.py parses tsp/ with the real 5.0.2 compiler, which catches SYNTAX that 5.5
accepts. It cannot catch a construct that parses in both and BEHAVES differently, and that is the class
that actually reaches the panel:

    string.byte(s, i, j)   5.1+ returns j-i+1 values; 5.0.2 returns ONE, so the extra names are nil and
                           the next arithmetic raises -286 on the instrument
    math.fmod              absent in 5.0.2 (it is math.mod), and tools/gen_serial.lua shims it, so every
                           offline suite passes while the box dies -- see math-mod-not-fmod-in-tsp
    string.match/gmatch    absent in 5.0.2 (it has string.gfind)
    #t                     no length operator in 5.0.2 at all
    s:upper()              no string metatable methods in 5.0.2

So this RUNS the statement under out/lua502/bin/lua and under the host interpreter, and reports both. A
difference between them is the warning; a 5.0.2 error is the answer.

THE FIRMWARE GLOBALS ARE STUBBED, because 5.0.2 has no display, file, tspnet, localnode, eventlog or timer
and a probe statement is mostly made of those. The stubs are deliberately dumb -- they record the call and
return a plausible shape -- since the point is to exercise the LUA, not to simulate the instrument.

HEX LITERALS ARE NORMALISED for the 5.0.2 run only, exactly as lint_tsp.parse502 does it: stock 5.0.2 does
not lex 0x00DCFF but the instrument's Lua does, so leaving them in would report a syntax error the DMM
would not give. Same regex, imported rather than copied.
"""
import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lint_tsp import HEXLIT, LUAC                                        # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA502 = os.path.join(ROOT, os.path.dirname(LUAC), 'lua')

# Enough of the firmware surface for a probe statement to run. Written in 5.0.2-compatible Lua itself --
# no #, no string methods, no fmod -- or the stubs would fail the very check they exist to enable.
STUBS = r'''
local _calls = {}
file = {
  MODE_READ = 1, MODE_WRITE = 2, MODE_APPEND = 3,
  READ_LINE = 10, READ_ALL = 11, READ_NUMBER = 12,
  usbdriveexists = function() return 1 end,
  mkdir = function(p) return nil end,
  flush = function(h) return nil end,
  close = function(h) return nil end,
  write = function(h, s) return nil end,
}
-- ONE REGISTERED FILE, whose contents come from --content. Anything else opens as nil, which is what the
-- instrument does for a missing path (and it posts 2205 rather than raising -- see
-- dmm-file-api-posts-events-not-errors).
local _fpath, _fbody, _fpos = nil, nil, 1
function _register(p, body) _fpath, _fbody, _fpos = p, body, 1 end
file.open = function(p, mode)
  if _fpath ~= nil and p == _fpath then _fpos = 1 return 1 end
  return nil
end
file.read = function(h, what)
  if _fbody == nil then return nil end
  if what == file.READ_ALL then local s = string.sub(_fbody, _fpos) _fpos = string.len(_fbody) + 1 return s end
  if _fpos > string.len(_fbody) then return nil end
  local nl = string.find(_fbody, '\n', _fpos, true)
  local s
  if nl == nil then s = string.sub(_fbody, _fpos) _fpos = string.len(_fbody) + 1
  else s = string.sub(_fbody, _fpos, nl) _fpos = nl + 1 end
  return s
end
localnode = {model = 'DMM6500', showevents = 0, serialno = '04641142'}
eventlog  = {getcount = function() return 0 end, next = function() return nil end,
             post = function(s, sev) return nil end, clear = function() return nil end}
display   = {create = function() return 1 end, delete = function() return nil end,
             setvalue = function() return nil end, settext = function() return nil end,
             STATE_INVISIBLE = 0, STATE_LCD_25 = 25}
timer     = {cleartime = function() return nil end, gettime = function() return 0.0 end}
tspnet    = {}
delay     = function(s) return nil end
'''


def run(interp, body, content, hexfix):
    src = STUBS
    if content is not None:
        src += "_register(%s, %s)\n" % (lua_str(content[0]), lua_str(content[1]))
    src += "\n" + body + "\n"
    if hexfix:
        src = HEXLIT.sub(lambda m: str(int(m.group(0), 16)), src)
    fh = tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False)
    fh.write(src)
    fh.close()
    try:
        r = subprocess.run([interp, fh.name], capture_output=True, text=True, timeout=20)
        out = (r.stdout or '').strip()
        err = (r.stderr or '').strip().replace(fh.name, '<stmt>')
        return r.returncode, out, err
    except FileNotFoundError:
        return None, '', 'interpreter not found: %s' % interp
    except subprocess.TimeoutExpired:
        return None, '', 'TIMED OUT'
    finally:
        os.unlink(fh.name)


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def check(body, content=None, quiet=False):
    """-> 0 if the statement is safe to send, 1 otherwise."""
    rc5, out5, err5 = run(LUA502, body, content, hexfix=True)
    rch, outh, errh = run('lua', body, content, hexfix=False)
    if rc5 is None:
        print('REFUSING: no 5.0.2 interpreter at %s -- run sh tools/get_lua502.sh' % LUA502)
        return 1
    bad = False
    if not quiet:
        print('  5.0.2  rc=%s  %s%s' % (rc5, out5 or '(no output)', ('\n         ERR ' + err5) if err5 else ''))
        print('  host   rc=%s  %s%s' % (rch, outh or '(no output)', ('\n         ERR ' + errh) if errh else ''))
    if rc5 != 0:
        print('  UNSAFE: this raises on the instrument -- %s' % (err5.split('\n')[-1] if err5 else 'rc %s' % rc5))
        bad = True
    elif out5 != outh:
        print('  DIFFERS: 5.0.2 gives %r where the host gives %r -- the host is not the oracle'
              % (out5, outh))
        bad = True
    elif not quiet:
        print('  OK: same result on both')
    return 1 if bad else 0


CASES = [
    # (label, statement, expect_bad)
    ('string.byte range (the -286 of 2026-09-06)',
     'do local b1,b2,b3,b4 = string.byte("abcd", 1, 4) print(b1 + b2*256 + b3*65536 + b4*16777216) end', True),
    ('string.byte single index', 'print(string.byte("abcd", 2))', False),
    ('math.fmod', 'print(math.fmod(7, 3))', True),
    ('math.mod', 'print(math.mod(7, 3))', False),
    ('length operator', 'do local t = {1,2,3} print(#t) end', True),
    ('table.getn', 'do local t = {1,2,3} print(table.getn(t)) end', True),
    ('string.match', 'print(string.match("ab12", "%d+"))', True),
    ('string method call', 'print(("ab"):upper())', True),
    ('plain arithmetic and format', 'print(string.format("%d %.2f", 7, 1.5))', False),
    ('file stub read', 'do local fh = file.open("/usb1/X", file.MODE_READ) print(tostring(fh)) end', False),
]


def self_test():
    print('check502 self-test: each case must be classified correctly')
    npass = nfail = 0
    for label, stmt, want_bad in CASES:
        got_bad = bool(check(stmt, quiet=True))
        ok = (got_bad == want_bad)
        npass, nfail = npass + (1 if ok else 0), nfail + (0 if ok else 1)
        print('  %-4s %-42s %s' % ('ok' if ok else 'FAIL', label,
                                   'flagged' if got_bad else 'clean'))
    print('')
    print('%d passed, %d failed' % (npass, nfail))
    return 1 if nfail else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('stmt', nargs='?', help='the Lua to check, or - for stdin')
    ap.add_argument('--file', help='read the statement from a file')
    ap.add_argument('--content', nargs=2, metavar=('PATH', 'TEXT'),
                    help='register one openable file for the file.* stub')
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.file:
        body = open(a.file).read()
    elif a.stmt == '-' or a.stmt is None:
        body = sys.stdin.read()
    else:
        body = a.stmt
    if not body.strip():
        ap.error('nothing to check')
    return check(body, content=a.content)


if __name__ == '__main__':
    sys.exit(main())

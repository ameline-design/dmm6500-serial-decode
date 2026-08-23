#!/usr/bin/env python3
"""REPLACE NAMED FUNCTIONS ON THE LIVE APP, without rebuilding the UI.

WHY THIS EXISTS. sdec.start() can build the panel ONCE per power cycle -- a second build crashes the
firmware hard enough to need a power cycle, which costs a human -- and tools/run_app.py's prelude CLEARS sdec before
loading, which strands every display handle the running app owns. So the usual "edit, reload, retest"
loop costs a power cycle per iteration, and overnight there is nobody to press the button.

A function is not a display object. Sending `function sdec.stream() ... end` over the socket rebinds
one field of a live table and touches nothing else: the buttons, screens and the reading buffer all
keep working. That makes a source fix testable on the instrument in seconds instead of a power cycle.

IT EXTRACTS FROM THE FILE, NEVER FROM A PROMPT OR A RETYPED BODY. The whole value is that the live app
ends up running exactly what the repo says, so the text is sliced out of tsp/*.tsp between
`function <name>(` and the next column-0 `end`. Retyping a body by hand is how a live app and its
source silently diverge, and then every later measurement is of code nobody has.

WHAT IT IS NOT. It is not a deployment mechanism, and it does not make the app match the archive: a
function whose SIGNATURE or call graph changed may need its callers patched too, and anything at file
scope (constants, `sdec.foo = 1`, new fields) is not a function and will not be picked up. After a
soak or a measurement session, power-cycle and install the .tspa to be sure.

    python3 tools/hotpatch.py sdec.stream sdec.stream_acquire
    python3 tools/hotpatch.py --list                    # what looks patchable
    python3 tools/hotpatch.py --check sdec.stream        # print the slice, send nothing
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODULES = ['tsp/usb_log.tsp', 'tsp/serial_core.tsp', 'tsp/uart_decode.tsp',
           'tsp/chunk_decode.tsp', 'tsp/serial_ui.tsp', 'tsp/serial_app.tsp']


def slice_function(name):
    """The verbatim source of `function <name>(...)` through its closing column-0 `end`.

    -> (module, text), or (None, None). The column-0 `end` is what bounds it: every function in these
    modules is at file scope, so the first line that is exactly 'end' closes it -- nested blocks are
    all indented. Cheaper and more predictable here than counting block keywords.
    """
    for m in MODULES:
        src = open(os.path.join(ROOT, m)).read()
        pat = re.compile(r'^function\s+' + re.escape(name) + r'\s*\(', re.M)
        mo = pat.search(src)
        if mo is None:
            continue
        endmo = re.compile(r'^end\s*$', re.M).search(src, mo.start())
        if endmo is None:
            return m, None
        return m, src[mo.start():endmo.end()]
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('names', nargs='*', help='e.g. sdec.stream sdec.stream_acquire')
    ap.add_argument('--list', action='store_true', help='list functions found in the modules')
    ap.add_argument('--check', action='store_true', help='print the slices, send nothing')
    ap.add_argument('--new', action='append', default=[],
                    help='a name the live app does not have yet and SHOULD gain. Named one at a time on '
                         'purpose: a patch set that renames or adds a helper must install it, or its '
                         'callers raise on a nil -- but silently creating whatever is asked for would '
                         'turn every typo into a function nothing calls')
    a = ap.parse_args()

    if a.list:
        for m in MODULES:
            fns = re.findall(r'^function\s+([\w.]+)\s*\(', open(os.path.join(ROOT, m)).read(), re.M)
            print('%s: %d functions' % (m, len(fns)))
            for f in fns:
                print('   %s' % f)
        return 0

    if not a.names:
        print('nothing to do: name at least one function, or pass --list')
        return 2

    bodies, missing = [], []
    for n in a.names:
        mod, text = slice_function(n)
        if text is None:
            missing.append(n)
            print('NOT FOUND: %s%s' % (n, '' if mod is None else ' (no closing end in %s)' % mod))
            continue
        print('%-28s %-22s %5d B  %3d lines' % (n, mod, len(text), text.count('\n') + 1))
        bodies.append('-- ==== hotpatch %s from %s ====\n%s' % (n, mod, text))
    if missing:
        print('\nREFUSING: %d name(s) could not be sliced. Nothing was sent.' % len(missing))
        return 2

    if a.check:
        print('\n--- %d slice(s), not sent (--check) ---' % len(bodies))
        for b in bodies:
            print(b)
        return 0

    from dmmrun import DMM, release_single_instance
    d = DMM()
    try:
        d.drain()
        built = (d.q('print(tostring(sdec ~= nil and sdec.built == true))') or '').strip()
        print('\napp on the panel (built): %s' % built)
        if built != 'true':
            print('REFUSING: no built app to patch. Load it with tools/run_app.py first.')
            return 2
        # EVERY NAME MUST EXIST BEFORE IT IS REPLACED. Patching a name the app does not have would
        # CREATE it, which silently installs a function nothing calls and reads as success.
        for n in a.names:
            ex = (d.q('print(tostring(%s ~= nil))' % n) or '').strip()
            if ex != 'true' and n not in a.new:
                print('REFUSING: %s does not exist on the live app (got %r).' % (n, ex))
                print('          If it is a new helper this patch set must install, pass --new %s' % n)
                return 2
            if ex == 'true' and n in a.new:
                print('note: %s was listed as --new but already exists; replacing it.' % n)
        src = '\n'.join(bodies) + "\nprint('===DONE===')"
        out = d.load_script('hotpatch', src, timeout=120)
        for ln in out:
            if ln and ln != '===DONE===':
                print('  load: %s' % ln)
        errs = d.errors()
        print('event log after the patch: %s' % (errs if errs else 'clean'))
        for n in a.names:
            ex = (d.q('print(tostring(%s ~= nil))' % n) or '').strip()
            print('  %-28s live: %s' % (n, ex))
        return 0 if not errs else 1
    finally:
        d.close()
        release_single_instance()


if __name__ == '__main__':
    sys.exit(main())

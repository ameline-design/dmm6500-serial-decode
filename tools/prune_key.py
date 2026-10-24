#!/usr/bin/env python3
"""Delete the capture artefacts off /usb1/SERDEC, because a full directory costs press latency.

A file create scans the directory for a free slot and extends it, and the app writes a new numbered
file per capture, so the cost grows with every run. Measured on the shipped key, a SanDisk 8 GB: 509
entries, a 49152-byte directory table, and the panel stage's `Save/twice` press went from 0.089 s to
0.809 s, past its 0.5 s budget, on nothing but directory growth. 506 of those 509 entries were bench
artefacts worth 51.6 MB.

The rule is a whitelist of deletable names rather than a list of keepers, so a new file type defaults
to surviving:

    bytes<digits>.txt    deleted   the byte log a capture writes
    serial*              deleted   a Save press's output, and the app's own log
    everything else      kept      PLAN.CSV, SOAK*.CSV, bytesidx.txt
    any subdirectory     kept      checked with fs.is_dir, so a name match cannot remove one

SOAK.csv is never touched. It is the bench record and deleting it unfetched loses a run; archive and
fetch it first, which `run_bench.py --fetch` does.

The listing comes from fs.readdir, which hands back real long names and costs no events on a
directory that exists. It replaced a parse of the raw FAT table, read by opening the directory as a
file and decoding 32-byte entries. That parse tied this tool to FAT32 and read 8.3 names only, so
`serial_decode_log.txt` arrived as `SERIAL~1.TXT`.

readdir's table is indexed from 0, so it is walked with pairs(). table.getn reports one less than the
entry count and `for i = 1, table.getn(t)` drops whichever name sits at index 0 -- measured: SOAK.csv
on this key, and a directory holding one file reports getn 0 and reads as empty. Keithley's example
at Ref 14-264 has the same defect.

One instrument-side loop, not one round trip per file: 506 removes over the socket is minutes of
latency for work the box can do in one pass. Every name removed came out of the listing just read, so
none of them is absent and none of them can post 2203. A size costs one open of a file the listing
reported, for the same reason.

    python3 tools/prune_key.py --dry-run     # list what would go, remove nothing
    python3 tools/prune_key.py               # do it
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

from dmmrun import DMM                                                     # noqa: E402

DIR = '/usb1/SERDEC'

# pairs(), not `for i = 1, table.getn(t)`: readdir is 0-based and getn would drop one name.
BODY = """
local t = fs.readdir("%(dir)s")
if t == nil then
  print("PRUNE open-failed")
else
  local ndel, nkeep, nby = 0, 0, 0
  for k, nm in pairs(t) do
    local path = "%(dir)s/" .. nm
    local up = string.upper(nm)
    local del = false
    if string.find(up, "^BYTES") ~= nil and string.find(up, "^BYTESIDX") == nil then del = true end
    if string.find(up, "^SERIA") ~= nil then del = true end
    -- A subdirectory can match either pattern, and os.remove would not take it anyway.
    if del and fs.is_dir(path) then del = false end
    if del then
      -- The length before the remove, from a file the listing just named.
      local sz = 0
      local fh = io.open(path, "r")
      if fh ~= nil then sz = fh:seek("end") fh:close() end
      if %(act)s then
        local ok = pcall(function() os.remove(path) end)
        if ok then ndel = ndel + 1 nby = nby + sz end
      else
        ndel = ndel + 1 nby = nby + sz
      end
    else
      nkeep = nkeep + 1
    end
  end
  print("PRUNE removed=" .. ndel .. " bytes=" .. nby .. " kept=" .. nkeep)
end
print('===DONE===')
"""


def prune(d, act=True, quiet=False):
    """-> (nremoved, nbytes, nkept), or None if the directory could not be read."""
    body = BODY % {'dir': DIR, 'act': 'true' if act else 'false'}
    got = None
    for ln in d.load_script('prunekey', body, timeout=600):
        if ln and ln.startswith('PRUNE'):
            got = ln.strip()
    if got is None or 'open-failed' in (got or ''):
        if not quiet:
            print('  prune: %s could not be read -- nothing removed' % DIR)
        return None
    f = dict(p.split('=', 1) for p in got.split()[1:])
    n, by, keep = int(f['removed']), int(f['bytes']), int(f['kept'])
    if not quiet:
        print('  prune: %s %d file(s), %.1f MB, keeping %d'
              % ('would remove' if not act else 'removed', n, by / 1048576.0, keep))
    return n, by, keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='list the count, remove nothing')
    a = ap.parse_args()
    d = DMM()
    try:
        r = prune(d, act=not a.dry_run)
    finally:
        d.close(restore=False)
    raise SystemExit(0 if r is not None else 1)


if __name__ == '__main__':
    main()

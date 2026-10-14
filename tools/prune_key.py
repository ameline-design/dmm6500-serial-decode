#!/usr/bin/env python3
"""Delete the capture artefacts off /usb1/SERDEC, because a full FAT directory costs press latency.

WHY. A file CREATE on FAT scans the directory for a free slot and extends it, and the app writes a
new numbered file per capture -- so the cost grows with every run. Measured on the shipped key, a
SanDisk 8 GB: 509 entries, a 49152-byte directory table, and the panel stage's `Save/twice` press went
from 0.089 s to 0.809 s, past its 0.5 s budget, on nothing but directory growth. 506 of those 509
entries were bench artefacts worth 51.6 MB.

WHAT IT KEEPS, and the list is a whitelist of DELETABLE names rather than a list of keepers, because
a new file type must default to surviving:

    BYTES<digits>.TXT   deleted   the byte log a capture writes
    SERIA~<digits>.TXT  deleted   a Save press's output, under its mangled FAT short name
    SERIAL~<digit>.TXT  deleted   the same, before the name needed two digits
    everything else     kept      PLAN.CSV, SOAK*.CSV, BYTESIDX.TXT, '.', '..'

SOAK.csv IS NEVER TOUCHED. It is the bench record and deleting it unfetched loses a run; archive and
fetch it first, which `run_bench.py --fetch` does.

THE DIRECTORY IS READ AS A FILE, not through fs.readdir. Two reasons. `file.open` on a path that is
not there posts event 2205 -- a dialog on the front panel of an instrument whose one inviolable rule
is that it never shows one -- so nothing here may probe for a name. And fs.readdir on 1.7.17a yields
an index per iteration rather than a name, so it cannot list anything. Opening '/usb1/SERDEC' hands
back the raw FAT table, and a 32-byte entry carries the 8.3 name at offset 0, the attribute byte at
11 and the length little-endian at 28. run_bench.py's keyfiles() reads SOAK.csv's size the same way.

ONE INSTRUMENT-SIDE LOOP, not one round trip per file: 506 removes over the socket is minutes of
latency for work the box can do in one pass. Every name removed came out of the table that was just
read, so none of them is absent and none of them can post 2205.

    python3 tools/prune_key.py --dry-run     # list what would go, remove nothing
    python3 tools/prune_key.py               # do it
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

from dmmrun import DMM                                                     # noqa: E402

DIR = '/usb1/SERDEC'

# attr 0x0F is a long-name fragment, 0x10 a directory, 0x08 the volume label: none is a file.
BODY = """
local fh = file.open("%(dir)s", file.MODE_READ)
if fh == nil then
  print("PRUNE open-failed")
else
  local raw = file.read(fh, file.READ_ALL)
  file.close(fh)
  local n = string.len(raw)
  local i, ndel, nkeep, nby = 1, 0, 0, 0
  while i + 31 <= n do
    local a0 = string.byte(raw, i)
    local attr = string.byte(raw, i + 11)
    if a0 ~= 0 and a0 ~= 229 and attr ~= 15 and attr ~= 16 and attr ~= 8 then
      local nm = string.gsub(string.sub(raw, i, i + 7), " +$", "")
      local ex = string.gsub(string.sub(raw, i + 8, i + 10), " +$", "")
      local full = nm
      if ex ~= "" then full = nm .. "." .. ex end
      local sz = string.byte(raw, i + 28) + string.byte(raw, i + 29) * 256
                 + string.byte(raw, i + 30) * 65536 + string.byte(raw, i + 31) * 16777216
      local del = false
      if string.find(nm, "^BYTES") and nm ~= "BYTESIDX" then del = true end
      if string.find(nm, "^SERIA") then del = true end
      if del and %(act)s then
        local ok = pcall(function() os.remove("%(dir)s/" .. full) end)
        if ok then ndel = ndel + 1 nby = nby + sz end
      elseif del then
        ndel = ndel + 1 nby = nby + sz
      else
        nkeep = nkeep + 1
      end
    end
    i = i + 32
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

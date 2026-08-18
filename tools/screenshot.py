#!/usr/bin/env python3
"""Grab the DMM6500 front-panel display over the LXI web interface.

Reverse-engineered from the instrument's own virtual-front-panel JavaScript
(/script/ajax_inc.js, /script/vfplib.js):

  POST /ajax_proc   function=9            -> "session=<id>"   (FP_SESSION_FUNCTION)
  GET  /images/fp.tga?<session>:<ms>      -> uncompressed TGA, 800x480
  GET  /images/fplow.tga?<session>:<ms>   -> half-res 400x240

The TGA is decoded here and written as PNG so the app UI can be inspected
directly. Requires HTTP basic auth (factory default admin/admin).
"""
import argparse
import struct
import sys
import time
import urllib.request

HOST = '10.0.1.151'
USER = 'admin'
PASSWORD = 'admin'
FP_SESSION_FUNCTION = 9


def _opener(host, user, password):
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, f'http://{host}/', user, password)
    return urllib.request.build_opener(urllib.request.HTTPBasicAuthHandler(mgr))


def start_session(host=HOST, user=USER, password=PASSWORD):
    op = _opener(host, user, password)
    body = f'function={FP_SESSION_FUNCTION}'.encode()
    req = urllib.request.Request(
        f'http://{host}/ajax_proc', data=body,
        headers={'Content-Type': 'application/x-www-form-urlencoded',
                 'Cache-Control': 'no-cache'})
    txt = op.open(req, timeout=10).read().decode(errors='replace')
    import re
    m = re.search(r'session=(\d+)', txt)
    if not m:
        raise RuntimeError(f'no session in response: {txt!r}')
    return int(m.group(1)), op


def grab_tga(session, op, host=HOST, lowres=False):
    path = '/images/fplow.tga' if lowres else '/images/fp.tga'
    url = f'http://{host}{path}?{session}:{int(time.time() * 1000)}'
    return op.open(url, timeout=15).read()


def tga_to_png(data, out_path):
    """Decode the instrument's TGA (type 2 raw or type 10 RLE, 24bpp BGR) to PNG.

    Mirrors the decoder the instrument ships in /script/tga_decode.js: rows are
    stored bottom-up, samples are BGR, and for RLE the packets run continuously
    across scanline boundaries (so decode the whole pixel stream, not per row).
    """
    (idlen, _cmaptype, imgtype, _cmapstart, _cmaplen, _cmapdepth,
     _x0, _y0, width, height, depth, descriptor) = struct.unpack_from(
        '<BBBHHBHHHHBB', data, 0)
    if imgtype not in (2, 10):
        raise RuntimeError(f'unsupported TGA image type {imgtype}')
    nbytes = depth // 8
    if nbytes not in (3, 4):
        raise RuntimeError(f'unsupported TGA depth {depth}')

    src = 18 + idlen
    npix = width * height
    rgb = bytearray(npix * 3)

    if imgtype == 10:
        i = 0
        while i < npix:
            cmd = data[src]
            src += 1
            count = 1 + (cmd & 0x7f)
            if cmd & 0x80:                      # run-length packet
                b, g, r = data[src], data[src + 1], data[src + 2]
                src += nbytes
                px = bytes((r, g, b))
                end = min(i + count, npix)
                rgb[i * 3:end * 3] = px * (end - i)
                i = end
            else:                               # raw packet
                for _ in range(count):
                    if i >= npix:
                        break
                    b, g, r = data[src], data[src + 1], data[src + 2]
                    src += nbytes
                    rgb[i * 3:i * 3 + 3] = bytes((r, g, b))
                    i += 1
    else:
        for i in range(npix):
            p = src + i * nbytes
            rgb[i * 3:i * 3 + 3] = bytes((data[p + 2], data[p + 1], data[p]))

    stride = width * 3
    rows = [bytes(rgb[y * stride:(y + 1) * stride]) for y in range(height)]
    # TGA origin: bit 5 of descriptor set => top-left, else bottom-left.
    if not (descriptor & 0x20):
        rows.reverse()

    import zlib
    raw = b''.join(b'\x00' + r for r in rows)

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    with open(out_path, 'wb') as fh:
        fh.write(png)
    return width, height


# ONE SESSION, REUSED. Opening a new front-panel session per grab is what the naive reading of
# the AJAX protocol suggests, and it FREEZES the instrument's framebuffer: after a couple of
# hundred sessions every /images/fp.tga returns the same frame, byte for byte, while the panel
# itself carries on updating. That failure is silent and it looks exactly like an application
# that has stopped repainting -- which is worse than a visible error, because it accuses the
# code under test. The instrument's own virtual front panel opens one session and then polls
# the image, so this does the same.
_SESSION = {}


def session_for(host, user, password, fresh=False):
    key = (host, user)
    if fresh:
        _SESSION.pop(key, None)
    if key not in _SESSION:
        _SESSION[key] = start_session(host, user, password)
    return _SESSION[key]


def reset_session(host=HOST, user=USER):
    _SESSION.pop((host, user), None)


def capture(out_path, host=HOST, lowres=False, user=USER, password=PASSWORD):
    session, op = session_for(host, user, password)
    try:
        tga = grab_tga(session, op, host, lowres)
    except Exception:
        # A session the instrument has dropped: get a new one and try once more, so a long run
        # recovers instead of failing every grab from that point on.
        session, op = session_for(host, user, password, fresh=True)
        tga = grab_tga(session, op, host, lowres)
    w, h = tga_to_png(tga, out_path)
    return out_path, w, h, len(tga)


def main():
    ap = argparse.ArgumentParser(description='Capture the DMM6500 screen as PNG')
    ap.add_argument('out', nargs='?', default='/tmp/dmm_screen.png')
    ap.add_argument('--host', default=HOST)
    ap.add_argument('--low', action='store_true', help='half-resolution grab')
    a = ap.parse_args()
    path, w, h, n = capture(a.out, a.host, a.low)
    print(f'wrote {path}  {w}x{h}  (tga {n} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())

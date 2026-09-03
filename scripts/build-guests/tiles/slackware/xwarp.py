#!/usr/bin/env python3
"""xwarp.py — raw-X11 WarpPointer + QueryPointer over a TCP display, no Xlib.

The x11warp proof for XFree86 3.3-era guests: xdotool segfaults against those
servers and python-xlib is not on labhost, so this speaks the core protocol
itself (auth-less: the guest session runs `xhost +<slirp gateway>`).

usage: xwarp.py HOST:DISPLAYNUM X Y [X Y ...]     e.g. xwarp.py 127.0.0.1:84 100 700 900 100
prints the QueryPointer readback after each warp; exit 1 on any mismatch.
"""
import socket
import struct
import sys


def connect(host, dpy):
    s = socket.create_connection((host, 6000 + dpy), timeout=5)
    s.sendall(struct.pack("<BxHHHHxx", 0x6C, 11, 0, 0, 0))  # little-endian, no auth
    hdr = s.recv(8)
    status, _, _, _, length = struct.unpack("<BBHHH", hdr)
    body = b""
    while len(body) < length * 4:
        body += s.recv(length * 4 - len(body))
    if status != 1:
        raise SystemExit("X setup refused: %r" % body[:80])
    # setup: release(4) ridbase(4) ridmask(4) motionbuf(4) vlen(2) maxreq(2)
    # nscreens(1) nformats(1) imgorder(1) bmporder(1) scanunit(1) scanpad(1)
    # minkc(1) maxkc(1) pad(4) vendor(vlen, padded) formats(8*n) screens...
    vlen = struct.unpack("<H", body[16:18])[0]
    nscreens, nformats = body[20], body[21]
    off = 32 + ((vlen + 3) & ~3) + 8 * nformats
    root = struct.unpack("<I", body[off:off + 4])[0]
    w, h = struct.unpack("<HH", body[off + 20:off + 24])
    return s, root, w, h


def warp(s, root, x, y):
    # WarpPointer: opcode 41, src=None, dst=root, src rect 0, dst x,y
    s.sendall(struct.pack("<BxHIIhhHHhh", 41, 6, 0, root, 0, 0, 0, 0, x, y))


def query(s, root):
    s.sendall(struct.pack("<BxHI", 38, 2, root))  # QueryPointer
    r = s.recv(32)
    _, same, _, _, root_, child, rx, ry, wx, wy, mask = struct.unpack("<BBHIIIhhhhH", r[:26])
    return rx, ry


def main():
    host, dpy = sys.argv[1].split(":")
    pts = [int(v) for v in sys.argv[2:]]
    s, root, w, h = connect(host, int(dpy))
    print("root 0x%x %dx%d" % (root, w, h))
    bad = 0
    for x, y in zip(pts[::2], pts[1::2]):
        warp(s, root, x, y)
        rx, ry = query(s, root)
        ok = (rx, ry) == (x, y)
        bad += not ok
        print("warp (%d,%d) -> readback (%d,%d) %s" % (x, y, rx, ry, "OK" if ok else "MISMATCH"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Raw-X11 warp proof: connect to host:port (an x11warp loopback forward into the
guest's XFree86 :0), XWarpPointer to each target, XQueryPointer it back.
usage: xwarp.py HOST PORT X,Y [X,Y ...]"""
import socket, struct, sys

host, port = sys.argv[1], int(sys.argv[2])
s = socket.create_connection((host, port), timeout=10)
s.sendall(struct.pack("<BxHHHHxx", ord("l"), 11, 0, 0, 0))
hdr = s.recv(8)
if hdr[0] != 1:
    n = hdr[1]
    print("REFUSED:", s.recv(64)[:n].decode(errors="replace"))
    sys.exit(2)
length = struct.unpack("<H", hdr[6:8])[0] * 4
body = b""
while len(body) < length:
    body += s.recv(length - len(body))
vlen = struct.unpack("<H", body[16:18])[0]
nfmt = body[21]
off = 32 + ((vlen + 3) & ~3) + 8 * nfmt
root = struct.unpack("<I", body[off:off + 4])[0]
print("root window 0x%x" % root)
ok = True
for t in sys.argv[3:]:
    x, y = (int(v) for v in t.split(","))
    s.sendall(struct.pack("<BxHIIhhHHhh", 41, 6, 0, root, 0, 0, 0, 0, x, y))
    s.sendall(struct.pack("<BxHI", 38, 2, root))
    r = b""
    while len(r) < 32:
        r += s.recv(32 - len(r))
    rx, ry = struct.unpack("<hh", r[16:20])
    print("warp (%d,%d) -> readback (%d,%d) %s" % (x, y, rx, ry, "OK" if (rx, ry) == (x, y) else "MISMATCH"))
    ok = ok and (rx, ry) == (x, y)
sys.exit(0 if ok else 1)

#!/usr/bin/env python3
"""NSPTR cursor-position agent.

Runs in the Debian-12 kiosk NEXT TO the Previous emulator -- never inside
NeXTSTEP, and it never writes: it opens /proc/<previous>/mem read-only and
reads the cursor location straight out of the emulated NeXT RAM buffer. The
guest and the emulator are both untouched.

Three RAM offsets carry the location (kernel event globals plus two shadows).
All three are read and the majority value is served, so one shadow going stale
cannot fabricate a position -- the failure that a single-offset first cut
produced on 4 of 12 validation points.

Protocol, one line per request:
  P                        -> "<x> <y>"
  Q                        -> "<x> <y> <read_us>"
  A                        -> "<x0> <y0> <x1> <y1> <x2> <y2>"  (all offsets)
  W <x> <y> <timeout_ms>   -> "<x> <y> <ms>"  block until it differs
"""

import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, "/root")
from mem import Mem  # noqa: E402

OFFS = [int(v) for v in os.environ.get("NSPTR_OFFS", "32660712,33136672,33139950").split(",")]
PORT = int(os.environ.get("NSPTR_PORT", "7799"))

m = Mem()
RAM = m.ptr("NEXTRam")
LO = min(OFFS)
SPAN = max(OFFS) + 4 - LO
fh_mem = m.f


def readall():
    fh_mem.seek(RAM + LO)
    blob = fh_mem.read(SPAN)
    return [struct.unpack_from(">hh", blob, o - LO) for o in OFFS]


def pos():
    v = readall()
    if v[0] == v[1] or v[0] == v[2]:
        return v[0]
    if v[1] == v[2]:
        return v[1]
    return v[0]


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen(8)
sys.stderr.write("nsagent port=%d offs=%s ram=%#x\n" % (PORT, OFFS, RAM))


def serve(c):
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    f = c.makefile("rwb", buffering=0)
    try:
        for line in f:
            p = line.split()
            if not p:
                continue
            k = p[0]
            if k == b"P":
                f.write(b"%d %d\n" % pos())
            elif k == b"Q":
                t0 = time.perf_counter()
                x, y = pos()
                f.write(b"%d %d %d\n" % (x, y, int((time.perf_counter() - t0) * 1e6)))
            elif k == b"A":
                f.write(b" ".join(b"%d %d" % v for v in readall()) + b"\n")
            elif k == b"W":
                ox, oy, tmo = int(p[1]), int(p[2]), float(p[3]) / 1000.0
                t0 = time.perf_counter()
                while True:
                    x, y = pos()
                    el = time.perf_counter() - t0
                    if (x, y) != (ox, oy) or el > tmo:
                        break
                f.write(b"%d %d %.3f\n" % (x, y, el * 1000))
            elif k == b"X":
                break
    except Exception as e:
        sys.stderr.write(f"err {e}\n")
    finally:
        c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()

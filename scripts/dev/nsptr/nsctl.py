#!/usr/bin/env python3
"""NSPTR closed-loop harness (host side).

Three independent views of the same pointer, so no claim rests on one of them:
  * Qmp.rel()      - inject relative motion on the PRODUCTION wire
                     (QMP input-send-event rel -> QEMU PS/2 -> kiosk X -> SDL
                     xrel -> Previous -> NeXT KMS).
  * Agent.pos()    - the cursor location read out of the emulated NeXT RAM by
                     the in-kiosk agent (nsagent.py). ~20 us, no guest changes.
  * shot_locate()  - ground truth: a QEMU screendump plus a template match of
                     the NeXTSTEP arrow. Slow but independent.
"""

import json
import socket
import time

QMP_SOCK = "/data/vms/soltest/NSPTR-closed-loop/qmp.sock"
AGENT = ("127.0.0.1", 5993)
W, H = 1120, 832

# The NeXTSTEP arrow, extracted from the framebuffer by differencing two frames
# whose cursor sat in a plain-grey desktop region. Rows are relative to the
# sprite box; the HOTSPOT (black tip) is one pixel in from its top-left.
# '#' black, 'O' white, '.' transparent.
ARROW = [
    "OO.........",
    "O#O........",
    "O##O.......",
    "O###O......",
    "O####O.....",
    "O#####O....",
    "O######O...",
    "O#######O..",
    "O########O.",
    "O#####OOOOO",
    "O##O##O....",
    "O#O.O##O...",
    "OO..O##O...",
    "O....O##O..",
    ".....O##O..",
    "......OO...",
]
HOT = (1, 1)


class Qmp:
    def __init__(self, path=QMP_SOCK):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rwb", buffering=0)
        self._read()
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise OSError("qmp closed")
            m = json.loads(line)
            if "event" not in m:
                return m

    def cmd(self, ex, **args):
        self.f.write((json.dumps({"execute": ex, "arguments": args}) + "\n").encode())
        return self._read()

    def rel(self, dx, dy):
        ev = []
        if dx:
            ev.append({"type": "rel", "data": {"axis": "x", "value": int(dx)}})
        if dy:
            ev.append({"type": "rel", "data": {"axis": "y", "value": int(dy)}})
        if ev:
            self.cmd("input-send-event", events=ev)

    def dump(self, path):
        self.cmd("screendump", filename=path)


class Agent:
    def __init__(self, addr=AGENT):
        self.s = socket.create_connection(addr, 5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.f = self.s.makefile("rwb", buffering=0)

    def pos(self):
        self.f.write(b"P\n")
        x, y = self.f.readline().split()
        return int(x), int(y)

    def wait_change(self, x, y, timeout_ms=250):
        self.f.write(b"W %d %d %d\n" % (x, y, timeout_ms))
        a, b, ms = self.f.readline().split()
        return int(a), int(b), float(ms)


def read_ppm(path):
    d = open(path, "rb").read()
    i = d.index(b"255\n") + 4
    return d[i:]


PAT = [
    (dx, dy, ARROW[dy][dx] == "#") for dy in range(len(ARROW)) for dx in range(len(ARROW[0])) if ARROW[dy][dx] != "."
]


def locate_ppm(px, near=None, radius=None):
    """Exact template match of the arrow. Returns the hotspot, or None."""
    rows, cols = len(ARROW), len(ARROW[0])
    if near and radius:
        x0 = max(0, near[0] - HOT[0] - radius)
        x1 = min(W - cols, near[0] - HOT[0] + radius)
        y0 = max(0, near[1] - HOT[1] - radius)
        y1 = min(H - rows, near[1] - HOT[1] + radius)
    else:
        x0, x1, y0, y1 = 0, W - cols, 0, H - rows
    hits = []
    for oy in range(y0, y1 + 1):
        base = oy * W
        for ox in range(x0, x1 + 1):
            ok = True
            for dx, dy, black in PAT:
                if (px[((base + dy * W) + ox + dx) * 3] < 128) != black:
                    ok = False
                    break
            if ok:
                hits.append((ox + HOT[0], oy + HOT[1]))
    return hits


def shot_locate(q, path="/data/vms/soltest/NSPTR-closed-loop/loc.ppm", **kw):
    q.dump(path)
    hits = locate_ppm(read_ppm(path), **kw)
    return hits


def slam(q, sx=-1, sy=-1, n=40, step=60):
    for _ in range(n):
        q.rel(sx * step, sy * step)


if __name__ == "__main__":
    q = Qmp()
    a = Agent()
    print("agent", a.pos())
    t1 = time.time()
    print("shot ", shot_locate(q), "%.0f ms" % ((time.time() - t1) * 1000))

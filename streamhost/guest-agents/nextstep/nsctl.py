#!/usr/bin/env python3
"""nsctl.py — clone-side driver for the NeXTSTEP (Previous-in-kiosk) tile.

Runs ON the lab box against a CLONE's qmp.sock. Provides:
  * QMP screendump -> raw P6 parse (no PIL on the box)
  * NeXT arrow-cursor locator (template match, with an ambiguity margin)
  * relative pointer motion (the tile's production input path)
  * closed-loop "park the NeXT cursor here" helper, for SETUP ONLY
  * HMP sendkey typing

The locator is a MEASUREMENT INSTRUMENT: it never remembers a previous frame,
it re-captures every call, and it reports the score margin between the best and
second-best match so a weak/ambiguous hit is visible rather than silent.
"""
import json
import os
import socket
import subprocess
import sys
import time

W, H = 1120, 832

# NeXT arrow cursor, sampled from a golden framebuffer. Offsets are relative to
# the hotspot (the arrow tip = top-left black pixel). Values are 8-bit grey as
# QEMU's -vga std screendump renders the kiosk's 2-bit greyscale NeXT display.
CURSOR = [
    (0, 0, 0), (1, 0, 85),
    (0, 1, 0), (2, 1, 85), (3, 1, 85),
    (0, 2, 0), (4, 2, 85), (5, 2, 85),
    (0, 3, 0), (6, 3, 255),
    (0, 4, 0), (4, 4, 255), (5, 4, 255),
    (0, 5, 0), (2, 5, 255), (3, 5, 255),
    (0, 6, 0), (1, 6, 255),
]
CW = 7
CH = 7


def parse_ppm(path):
    d = open(path, "rb").read()
    i, tok = 0, []
    while len(tok) < 4:
        while d[i : i + 1].isspace():
            i += 1
        j = i
        while not d[j : j + 1].isspace():
            j += 1
        tok.append(d[i:j])
        i = j
    i += 1
    w, h = int(tok[1]), int(tok[2])
    return w, h, d[i:]


class Qmp:
    def __init__(self, sock):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(120)
        self.s.connect(sock)
        self.buf = b""
        self._rl()
        self.cmd({"execute": "qmp_capabilities"})

    def _rl(self):
        while b"\n" not in self.buf:
            self.buf += self.s.recv(65536)
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, o):
        self.s.sendall((json.dumps(o) + "\r\n").encode())
        while True:
            m = self._rl()
            if "return" in m or "error" in m:
                return m

    def hmp(self, line):
        return self.cmd(
            {"execute": "human-monitor-command", "arguments": {"command-line": line}}
        )["return"]

    def shot(self, path):
        try:
            os.unlink(path)
        except OSError:
            pass
        self.hmp("screendump %s" % path)
        for _ in range(80):
            if os.path.exists(path) and os.path.getsize(path) > W * H * 3:
                return parse_ppm(path)
            time.sleep(0.05)
        raise RuntimeError("screendump never appeared: %s" % path)

    def rel(self, dx, dy):
        ev = []
        if dx:
            ev.append({"type": "rel", "data": {"axis": "x", "value": int(dx)}})
        if dy:
            ev.append({"type": "rel", "data": {"axis": "y", "value": int(dy)}})
        if ev:
            self.cmd({"execute": "input-send-event", "arguments": {"events": ev}})

    def click(self, btn="left"):
        for down in (True, False):
            self.cmd(
                {
                    "execute": "input-send-event",
                    "arguments": {
                        "events": [
                            {"type": "btn", "data": {"down": down, "button": btn}}
                        ]
                    },
                }
            )
            time.sleep(0.05)


DECOYS = "/data/vms/sandbox/NSPTR-guest-daemon/decoys.json"


def raw_hits(px, w=W, h=H):
    """Every place the arrow template matches (>= len-2 of its pixels)."""
    hits = []
    need = len(CURSOR)
    for y in range(0, h - CH):
        row = y * w
        for x in range(0, w - CW):
            if px[(row + x) * 3] != 0:
                continue
            s = 0
            for dx, dy, v in CURSOR:
                if px[((y + dy) * w + x + dx) * 3] == v:
                    s += 1
            if s >= need - 2:
                hits.append((s, x, y))
    hits.sort(reverse=True)
    return hits


def load_decoys():
    try:
        return {tuple(t) for t in json.load(open(DECOYS))}
    except (OSError, ValueError):
        return set()


def locate(px, w=W, h=H, decoys=None):
    """Find the NeXT arrow, rejecting known static look-alikes.

    NeXTSTEP draws submenu indicators with the SAME glyph as the arrow cursor,
    so bitmap matching alone is ambiguous (9 perfect hits on the golden frame).
    Every match that also occurs in a cursor-free reference frame is a decoy and
    is subtracted. The result must then be UNIQUE: 0 or >1 survivors is a loud
    failure, never a guess.
    """
    if decoys is None:
        decoys = load_decoys()
    hits = [h for h in raw_hits(px, w, h) if (h[1], h[2]) not in decoys]
    # collapse adjacent duplicates of one glyph
    keep = []
    for s, x, y in hits:
        if any(abs(x - kx) <= 2 and abs(y - ky) <= 2 for _, kx, ky in keep):
            continue
        keep.append((s, x, y))
    if len(keep) != 1:
        raise RuntimeError("locator ambiguous: %d candidates %r" % (len(keep), keep[:6]))
    s, x, y = keep[0]
    return (x, y, s)


def where(q, tmp, decoys=None):
    _, _, px = q.shot(tmp)
    return locate(px, decoys=decoys)


def park(q, tmp, tx, ty, tries=40):
    """SETUP ONLY: iteratively walk the NeXT cursor to (tx,ty) with rel deltas."""
    for _ in range(tries):
        got = where(q, tmp)
        if not got:
            raise RuntimeError("cursor not found while parking")
        x, y = got[0], got[1]
        if x == tx and y == ty:
            return got
        dx, dy = tx - x, ty - y
        # Previous scales host deltas by fLinScale=1.3333; step conservatively and
        # stay under the NeXT KMS signed-6-bit (63 px) per-event limit.
        sx = max(-40, min(40, int(round(dx / 1.3333))))
        sy = max(-40, min(40, int(round(dy / 1.3333))))
        if sx == 0 and dx:
            sx = 1 if dx > 0 else -1
        if sy == 0 and dy:
            sy = 1 if dy > 0 else -1
        q.rel(sx, sy)
        time.sleep(0.12)
    raise RuntimeError("park did not converge on (%d,%d)" % (tx, ty))


def main():
    sock = sys.argv[1]
    op = sys.argv[2]
    tmp = "/tmp/nsctl-%d.ppm" % os.getpid()
    q = Qmp(sock)
    if op == "where":
        print(where(q, tmp))
    elif op == "park":
        print(park(q, tmp, int(sys.argv[3]), int(sys.argv[4])))
    elif op == "rel":
        q.rel(int(sys.argv[3]), int(sys.argv[4]))
    elif op == "click":
        q.click()
    elif op == "shot":
        q.shot(sys.argv[3])
        subprocess.run(
            ["pnmtopng", sys.argv[3]], stdout=open(sys.argv[3] + ".png", "wb"), check=True
        )
        print(sys.argv[3] + ".png")
    elif op == "type":
        for k in sys.argv[3:]:
            q.hmp("sendkey %s" % k)
            time.sleep(0.06)
    else:
        raise SystemExit("unknown op %s" % op)


if __name__ == "__main__":
    main()

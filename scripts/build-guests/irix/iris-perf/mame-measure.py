#!/usr/bin/env python3
"""mame-measure.py — the pointer half of measure.py for the MAME irix station:
MOVE via mamectl/1 ctl.sock, frames read straight from fb.shm (IFB1 header,
seqlock at +24). Cursor = saturated red arrow left of the icon column; if the
frame carries no red cursor, falls back to the diff bounding box vs the pre-frame.
Runs ON labhost. Read-only for the station apart from pointer motion."""

import json
import mmap
import os
import socket
import struct
import time
from pathlib import Path

import numpy as np

SHM = "/data/vms/streamhost/stations/irix/fb.shm"
CTL = "/data/vms/streamhost/stations/irix/ctl.sock"


class Ctl:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(10)
        self.s.connect(CTL)
        self.buf = b""
        self.n = 0
        try:
            self.banner = self.s.recv(4096).decode(errors="replace")
        except TimeoutError:
            self.banner = "(no banner)"

    def _line(self):
        while b"\n" not in self.buf:
            self.buf += self.s.recv(4096)
        l, self.buf = self.buf.split(b"\n", 1)
        return l.decode(errors="replace").strip()

    def cmd(self, line):
        self.n += 1
        self.s.sendall(f"{self.n} {line}\n".encode())
        while True:
            r = self._line()
            if r.startswith(f"{self.n} "):
                return r


class Shm:
    def __init__(self):
        fd = os.open(SHM, os.O_RDONLY)
        self.m = mmap.mmap(fd, 0, prot=mmap.PROT_READ)
        magic, ver, self.w, self.h, self.stride, self.bpp = struct.unpack_from("<6I", self.m, 0)
        assert magic == 0x31424649, hex(magic)

    def seq(self):
        return struct.unpack_from("<Q", self.m, 24)[0]

    def frame(self):
        a = None
        for _ in range(200):
            s0 = self.seq()
            if s0 & 1:
                time.sleep(0.001)
                continue
            a = (
                np.frombuffer(self.m, dtype=np.uint8, count=self.stride * self.h, offset=64)
                .reshape(self.h, self.stride)[:, : self.w * 4]
                .reshape(self.h, self.w, 4)
                .copy()
            )
            if self.seq() == s0:
                return a, s0
        if a is None:
            a = (
                np.frombuffer(self.m, dtype=np.uint8, count=self.stride * self.h, offset=64)
                .reshape(self.h, self.stride)[:, : self.w * 4]
                .reshape(self.h, self.w, 4)
                .copy()
            )
        return a, s0


def locate(cur, pre=None):
    a = cur[:, :1150, :3].astype(int)
    m = (a[:, :, 2] > 200) & (a[:, :, 1] < 80) & (a[:, :, 0] < 80)  # BGRA order
    ys, xs = np.nonzero(m)
    if len(xs) >= 10:
        return (int(xs.min()), int(ys.min()), int(len(xs)), "red")
    if pre is not None:
        d = np.any(cur != pre, axis=2)
        ys, xs = np.nonzero(d)
        if len(xs):
            return (int(xs.min()), int(ys.min()), int(len(xs)), "diff")
    return None


def main():
    out = {
        "tag": "mame-irix",
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "load": Path("/proc/loadavg").read_text().split()[0],
    }
    c = Ctl()
    sh = Shm()
    out["shm"] = [sh.w, sh.h, sh.stride]
    out["banner"] = c.banner[:120]
    out["stat"] = c.cmd("STAT")[:200]
    out["cur0"] = c.cmd("CUR")[:120]
    for _ in range(40):
        c.cmd("MOVE -50 -50")
    for _ in range(60):
        c.cmd("MOVE 5 5")
        time.sleep(0.02)
    time.sleep(1.0)
    base, _ = sh.frame()
    out["park"] = locate(base)
    out["cur_park"] = c.cmd("CUR")[:80]
    lats = []
    frames = []
    for i in range(5):
        pre, s0 = sh.frame()
        p = locate(pre)
        t0 = time.monotonic()
        c.cmd(f"MOVE {5 if i % 2 == 0 else -5} 0")
        while True:
            cur, s1 = sh.frame()
            t = time.monotonic() - t0
            l = locate(cur, pre)
            if l and (p is None or l[:2] != p[:2]):
                lats.append(round(t * 1000))
                frames.append(int(s1 - s0))
                break
            if t > 3:
                lats.append(None)
                frames.append(None)
                break
        time.sleep(0.4)
    out["mouse_single_latency_ms"] = lats
    out["frames_until_change"] = frames
    base, _ = sh.frame()
    track = []
    t0 = time.monotonic()

    def sample():
        cur, s = sh.frame()
        track.append((round(time.monotonic() - t0, 3), locate(cur, base)))

    n = 60
    for i in range(n):
        c.cmd("MOVE 1 0")
        time.sleep(0.02)
        if i % 5 == 4:
            sample()
    t_last = time.monotonic() - t0
    while time.monotonic() - t0 < t_last + 3.0:
        sample()
        time.sleep(0.03)
    pos = [(t, l) for t, l in track if l]
    settle = None
    if pos:
        fx, fy = pos[-1][1][0], pos[-1][1][1]
        for t, l in pos:
            if abs(l[0] - fx) < 1.5 and abs(l[1] - fy) < 1.5:
                settle = t
                break
    out["mouse_stream"] = {
        "events": n,
        "last_event_s": round(t_last, 3),
        "settled_s": settle,
        "lag_after_last_ms": None if settle is None else round((settle - t_last) * 1000),
        "distinct_positions": len({(l[0], l[1]) for _, l in pos}),
        "samples": len(track),
        "first": pos[0][1][:2] if pos else None,
        "final": pos[-1][1][:2] if pos else None,
    }
    out["cur_end"] = c.cmd("CUR")[:80]
    out["track"] = [(t, None if l is None else l[:2]) for t, l in track]
    print(json.dumps(out))


main()

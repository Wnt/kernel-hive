#!/usr/bin/env python3
"""Input-to-photon latency A/B for the Previous absolute-pointer patch.

Runs INSIDE the kiosk guest (it talks to the abspointer control socket over a
unix socket, so no host round trip is in the measured window).

  arm REL  rel(20,0)          -- the relative path the tile ships today
  arm ABS  abs(start+200, y)  -- the absolute path this patch adds

Both arms are queued on the same control channel, drained on the same
Main_EventHandler tick, and call the same kms_mouse_move(); both move the
cursor the same 200 guest px. Everything upstream of Previous and everything
downstream of the KMS is therefore common to both and cancels; what is left is
what the absolute mechanism itself adds.

'Photon' is the emulated NeXT framebuffer: NEXTVideo is hashed in C through the
control channel until the hash changes.
"""
import socket
import statistics
import sys
import time

SOCK = "/tmp/previous-abs.sock"
VRAM_LEN = 280 * 832


class Ctl:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(SOCK)
        self.f = self.s.makefile("rw")

    def cmd(self, c):
        self.f.write(c + "\n")
        self.f.flush()
        return self.f.readline().rstrip("\n")

    def vhash(self):
        return self.cmd("vsum 0 %d" % VRAM_LEN)


def trial(c, arm, sx, sy):
    c.cmd("abs %d %d" % (sx, sy))
    time.sleep(0.40)
    base = c.vhash()
    if base != c.vhash():
        return None                      # screen not quiet, discard
    t0 = time.perf_counter()
    c.cmd("rel 20 0" if arm == "REL" else "abs %d %d" % (sx + 200, sy))
    while True:
        if c.vhash() != base:
            return (time.perf_counter() - t0) * 1000.0
        if time.perf_counter() - t0 > 0.8:
            return None


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    c = Ctl()

    # poller cost, so the sampling resolution is on the record
    t = time.perf_counter()
    for _ in range(200):
        c.vhash()
    print("poll period %.3f ms (full-VRAM hash through the control channel)"
          % ((time.perf_counter() - t) * 1000.0 / 200))

    for _ in range(4):                   # warm the plant, discard
        trial(c, "REL", 300, 650)
        trial(c, "ABS", 300, 650)

    res = {"REL": [], "ABS": []}
    for i in range(n):
        for arm in (("REL", "ABS") if i % 2 == 0 else ("ABS", "REL")):
            v = trial(c, arm, 300 if i % 2 == 0 else 320, 650)
            if v is not None:
                res[arm].append(v)
    for arm in ("REL", "ABS"):
        v = sorted(res[arm])
        print("%s n=%d median %.2f ms  p25 %.2f  p75 %.2f  min %.2f  max %.2f"
              % (arm, len(v), statistics.median(v), v[len(v) // 4], v[3 * len(v) // 4],
                 v[0], v[-1]))
    print("ABS - REL median delta %.2f ms"
          % (statistics.median(res["ABS"]) - statistics.median(res["REL"])))
    print("RAW REL " + " ".join("%.2f" % x for x in res["REL"]))
    print("RAW ABS " + " ".join("%.2f" % x for x in res["ABS"]))


if __name__ == "__main__":
    main()

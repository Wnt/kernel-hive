#!/usr/bin/env python3
"""fb-wait.py — block until a QEMU guest's framebuffer SETTLES or CHANGES, not for a fixed sleep.

WHY. netbsd14 golden stream (2026-09-03): the installed kernel hung in the ISA
probe after `lpt0`. The agent's loop was `sleep 15; screendump; look`, then
`sleep 40; look`, then a relaunch where it MISSED the 5-second boot prompt because
the next look came too late. Every wait was a guess: too short (nothing yet,
look again) or too long (the window passed, or 40 s spent staring at a hang that
was recognisable after 5). A bring-up agent spends most of its wall-clock in
these guesses (docs/lab/ADD-NEW-OS-PLAYBOOK.md §0: pcgeos was 67 % model time).

WHAT. Polls `screendump` over QMP once a second and returns as soon as the
condition holds:

    --settle S     the framebuffer has not changed for S seconds  (exit 0)
                   -> "the guest stopped doing things": a menu is up, a hang is a
                      hang, the desktop finished painting. Sized by the guest's
                      own cadence: 3 s for a curses installer, 8 s for a kernel
                      probe (some probes legitimately pause 5 s), 15 s for X start.
    --change       the framebuffer differs from the FIRST frame taken (exit 0)
                   -> "the keystroke landed", "the boot prompt appeared".
    --timeout T    give up after T seconds                          (exit 2)

Both conditions may be given: --change --settle S returns when the screen has
changed AND then settled (the normal "type, then wait for the result" shape).
`--out PNG` writes the final frame (needs PIL, present on labhost). Prints one
line: `settled after 12.0s (last change at 4.1s)` / `changed after 0.9s` /
`timeout after 60.0s (last change at 0.0s)`. Runs ON THE BOX (unix socket):

    ssh lab 'python3 /data/vms/sandbox/<x>/repo/scripts/dev/fb-wait.py \
             --qmp /data/vms/sandbox/netbsd14/race/wdc/qmp.sock --settle 8 --timeout 90 \
             --out /data/vms/sandbox/netbsd14/race/wdc/fb.png'

Frames are compared pixel-wise; a change smaller than --tolerance pixels
(default 400 = a couple of text cells) is ignored, because a BLINKING CURSOR
otherwise counts as change every second — measured on netbsd14's kernel hang:
exact hashing reported "last change at 120.1s" on a screen that was frozen.
A paused guest never changes: this tool does NOT hold a wake lease (it must not
resume a station somebody paused); use it on rigs and clones (SH_IDLE_PAUSE_SECS=0)
or check `query-status` first.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import tempfile
import time


class Qmp:
    def __init__(self, path: str):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(30)
        self.s.connect(path)
        self.buf = b""
        self._readline()
        self.cmd({"execute": "qmp_capabilities"})

    def _readline(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("fb-wait: QMP connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, obj: dict) -> dict:
        self.s.sendall((json.dumps(obj) + "\r\n").encode())
        while True:
            m = self._readline()
            if "error" in m:
                raise SystemExit(f"fb-wait: {obj} -> {m['error']}")
            if "return" in m:
                return m

    def screendump(self, path: str):
        self.cmd({"execute": "screendump", "arguments": {"filename": path}})
        from PIL import Image  # labhost has it

        return Image.open(path).convert("RGB")


def differs(a, b, tolerance: int) -> bool:
    """True when more than `tolerance` pixels differ (cursor blink stays below it)."""
    from PIL import ImageChops

    if a.size != b.size:
        return True
    box = ImageChops.difference(a, b).getbbox()
    if box is None:
        return False
    return (box[2] - box[0]) * (box[3] - box[1]) > tolerance


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--qmp", required=True, help="QMP unix socket of the guest")
    ap.add_argument("--settle", type=float, default=None, metavar="S", help="return once unchanged for S seconds")
    ap.add_argument("--change", action="store_true", help="return once the frame differs from the first one")
    ap.add_argument("--timeout", type=float, default=120.0, metavar="T")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument(
        "--tolerance", type=int, default=400, metavar="PX", help="ignore changes within this many pixels (cursor blink)"
    )
    ap.add_argument("--out", help="write the final frame as PNG (PIL)")
    a = ap.parse_args()
    if a.settle is None and not a.change:
        ap.error("give --settle S and/or --change")

    q = Qmp(a.qmp)
    fd, ppm = tempfile.mkstemp(prefix="fb-wait-", suffix=".ppm")
    os.close(fd)
    t0 = time.monotonic()
    first = last = None
    last_change = 0.0
    changed = not a.change
    status = "timeout"
    try:
        while True:
            frame = q.screendump(ppm)
            now = time.monotonic() - t0
            if first is None:
                first = last = frame
            elif differs(frame, last, a.tolerance):
                last, last_change = frame, now
            if a.change and not changed and differs(frame, first, a.tolerance):
                changed = True
                last_change = now
                if a.settle is None:
                    status = "changed"
                    break
            if (
                changed
                and a.settle is not None
                and now - last_change >= a.settle
                and first is not None
                and now >= a.settle
            ):
                status = "settled"
                break
            if now >= a.timeout:
                break
            time.sleep(a.interval)
        now = time.monotonic() - t0
        if a.out and last is not None:
            last.save(a.out)
    finally:
        os.unlink(ppm)
    if status == "changed":
        print(f"changed after {now:.1f}s")
        return 0
    print(f"{status} after {now:.1f}s (last change at {last_change:.1f}s)")
    return 0 if status == "settled" else 2


if __name__ == "__main__":
    sys.exit(main())

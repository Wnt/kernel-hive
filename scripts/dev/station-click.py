#!/usr/bin/env python3
"""station-click.py — click or move an ABSOLUTE pointer on a LIVE station, safely.

WHY. qmp-type.py drives the keyboard and a RELATIVE mouse (HMP `mouse_move`),
which is a no-op on several usb-tablet guests, so curating a live scene meant
sending raw `input-send-event` by hand — and a raw sender does not hold
streamhost's wake lease. A station with no browser session is idle-paused, and
a paused guest ACCEPTS every click and reacts to none: on 2026-09-24 that ate
three clicks in a row on win2000 and the screendump afterwards looked like the
click had simply missed. This is the same lesson qmp-type.py learned for keys,
applied to the absolute pointer.

    station-click.py win2000 879 756            # double-click at 879,756
    station-click.py win2000 879 756 --single   # single click
    station-click.py winxp  604 22 --move       # park the pointer, no click
    station-click.py winxp  37 100 --size 1920x1200

Coordinates are FRAMEBUFFER pixels, the same ones you read off a screendump.
--size is the framebuffer geometry (default: read from the guest's own
screendump, so you rarely pass it).

Runs ON THE BOX (the QMP socket is a unix socket). Exits non-zero, loudly, if
the guest could not be woken or was re-frozen part-way, rather than leaving you
with a screenshot that means nothing.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

from guest_wake import WakeLease, assert_running, wake  # noqa: E402

STATIONS = Path("/data/vms/streamhost/stations")
ABS_MAX = 32767


class Qmp:
    def __init__(self, sock_path: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(sock_path))
        self.io = self.sock.makefile("rw")
        self.io.readline()  # greeting
        self.execute("qmp_capabilities")

    def execute(self, cmd: str, **args: object) -> object:
        payload: dict[str, object] = {"execute": cmd}
        if args:
            payload["arguments"] = args
        self.io.write(json.dumps(payload) + "\n")
        self.io.flush()
        while True:
            reply = json.loads(self.io.readline())
            if "event" in reply:  # events interleave with replies
                continue
            if "error" in reply:
                raise RuntimeError(f"{cmd} failed: {reply['error']}")
            return reply.get("return")

    def send(self, events: list[dict]) -> None:
        self.execute("input-send-event", events=events)

    def framebuffer_size(self) -> tuple[int, int]:
        """Screendump once and read the geometry out of the PPM header."""
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "size.ppm"
            self.execute("screendump", filename=str(shot))
            for _ in range(50):
                if shot.exists() and shot.stat().st_size > 32:
                    break
                time.sleep(0.1)
            head = shot.read_bytes()[:64].split()
            if len(head) < 3 or head[0] != b"P6":
                raise RuntimeError("screendump did not produce a P6 PPM")
            return int(head[1]), int(head[2])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("station", help="station dir name under /data/vms/streamhost/stations")
    ap.add_argument("x", type=int, help="framebuffer x")
    ap.add_argument("y", type=int, help="framebuffer y")
    ap.add_argument("--single", action="store_true", help="single click (default: double)")
    ap.add_argument("--move", action="store_true", help="move only, no click")
    ap.add_argument("--button", default="left", choices=("left", "middle", "right"))
    ap.add_argument("--size", help="framebuffer geometry WxH (default: ask the guest)")
    args = ap.parse_args()

    sock_path = STATIONS / args.station / "qmp.sock"
    if not sock_path.exists():
        print(f"station-click: no QMP socket at {sock_path}", file=sys.stderr)
        return 2
    q = Qmp(sock_path)

    if args.size:
        w, h = (int(v) for v in args.size.lower().split("x", 1))
    else:
        w, h = q.framebuffer_size()
    if not (0 <= args.x < w and 0 <= args.y < h):
        print(f"station-click: {args.x},{args.y} is outside the {w}x{h} framebuffer", file=sys.stderr)
        return 2

    def move(px: int, py: int) -> None:
        q.send(
            [
                {"type": "abs", "data": {"axis": "x", "value": px * ABS_MAX // (w - 1)}},
                {"type": "abs", "data": {"axis": "y", "value": py * ABS_MAX // (h - 1)}},
            ]
        )

    def click() -> None:
        q.send([{"type": "btn", "data": {"down": True, "button": args.button}}])
        time.sleep(0.05)
        q.send([{"type": "btn", "data": {"down": False, "button": args.button}}])

    # Hold the lease around EVERYTHING: a guest re-frozen mid-sequence discards
    # an unknown part of it, and the screendump afterwards proves nothing.
    with WakeLease(args.station):
        wake(q.execute, args.station)
        assert_running(q.execute, args.station, "the pointer input")
        # A short approach move first: some guests only latch an absolute
        # position after a motion event that actually changes it.
        move(max(args.x - 40, 0), max(args.y - 40, 0))
        time.sleep(0.2)
        move(args.x, args.y)
        time.sleep(0.4)
        if not args.move:
            click()
            if not args.single:
                time.sleep(0.18)
                click()
        time.sleep(1.0)
        assert_running(q.execute, args.station, "the pointer input")

    what = "moved to" if args.move else ("clicked" if args.single else "double-clicked")
    print(f"station-click: {what} {args.x},{args.y} on {args.station} ({w}x{h})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

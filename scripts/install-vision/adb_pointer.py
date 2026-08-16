#!/usr/bin/env python3
"""Closed-loop pointer driving for guests with a RELATIVE mouse.

The rest of install-vision assumes an absolute tablet: `QMPClient.tap` converts
a pixel to QEMU's 0..0x7fff absolute axes and the guest lands exactly there.
A machine with no absolute pointer at all — the m68k `q800`, whose mouse and
keyboard are ADB and which has no USB bus to hang a tablet off — cannot use any
of that. This module is the missing half: it drives such a guest by MEASURING
the cursor on the framebuffer and correcting, so a caller still gets to say
"click at (x, y)".

Four properties of a relative guest that each cost a debugging session on the
macos753 build, and are handled here so the next one does not pay again:

* **Gain is not 1.** The guest applies its own units-to-pixels factor (Mac OS
  7.5.3 at "Very Slow" tracking: exactly 0.36). It is measurable and stable —
  `measure_gain` reports it, and it is the same number a station's
  `cursor_scale` is derived from (1/gain).
* **The corner pin must exceed the screen IN GUEST UNITS**, i.e.
  `extent / gain`, not `extent`. A pin sized for a gain-1 guest silently falls
  short and leaves the cursor somewhere unknown.
* **A screendump right after motion can be STALE.** With `-display dbus,p2p=on`
  and no peer attached there is no display listener driving refreshes, so the
  first frame back can still show the cursor where it used to be — which puts a
  ghost in the diff and drags the estimate backwards. Every capture here
  discards one frame first.
* **A dropped icon lands offset from the cursor.** Measured at ~(+31, +11) on
  System 7: dropping *onto* a target means aiming up-left of it, or the item
  lands beside the target and the drop silently does nothing.

Clone-only, exactly like `flow.py`: the QMP socket must resolve below
`/data/vms/soltest` (`CLONE_GUARD_CLONE_ROOT` to override) so this can never be
pointed at a live station.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np
from qmp import QMPClient

# How far a nudge moves the cursor when locating it. Large enough that every
# cursor pixel changes, small enough that no guest treats it as a real gesture.
NUDGE = 6
# Per-send delta ceiling. Deltas are chunked so a large move never arrives as
# one packet the guest's mouse queue can clamp or drop.
CHUNK = 8
CHUNK_PACE_S = 0.012
# Settle after the corner pin, before anything is walked from the origin.
PIN_SETTLE_S = 1.2
# Where a dropped icon lands relative to the cursor (System 7, measured).
DROP_OFFSET = (31, 11)


def assert_clone_socket(path: str | Path) -> Path:
    """Fail closed unless the QMP socket is inside the clone sandbox."""
    root = Path(os.environ.get("CLONE_GUARD_CLONE_ROOT", "/data/vms/soltest")).resolve()
    resolved = Path(path).resolve()
    if root not in resolved.parents:
        raise SystemExit(f"adb_pointer: REFUSED: {resolved} is not below {root}")
    return resolved


class AdbPointer:
    """Drive a relative-mouse guest to absolute framebuffer coordinates."""

    def __init__(self, qmp: QMPClient, gain: float = 0.36, extent: int = 1200):
        self.qmp = qmp
        self.gain = gain
        # Guest units needed to cross the whole screen, plus generous margin:
        # the guest clamps at its own edge, so overshoot is free.
        self.pin = int(extent / max(gain, 0.01) * 1.5)

    # -- primitives ------------------------------------------------------

    def send(self, events: list[dict]) -> None:
        self.qmp.execute("input-send-event", events=events)

    def rel(self, dx: int, dy: int) -> None:
        """Send a delta in sub-clamp chunks that sum exactly to (dx, dy)."""
        while dx or dy:
            sx = max(-CHUNK, min(CHUNK, dx))
            sy = max(-CHUNK, min(CHUNK, dy))
            events = []
            if sx:
                events.append({"type": "rel", "data": {"axis": "x", "value": sx}})
            if sy:
                events.append({"type": "rel", "data": {"axis": "y", "value": sy}})
            if not events:
                break
            self.send(events)
            dx -= sx
            dy -= sy
            time.sleep(CHUNK_PACE_S)

    def button(self, down: bool, button: str = "left") -> None:
        self.send([{"type": "btn", "data": {"down": down, "button": button}}])

    def key(self, qcode: str) -> None:
        for down in (True, False):
            self.send([{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}])
            time.sleep(0.05)
        time.sleep(0.1)

    def chord(self, modifier: str, qcode: str) -> None:
        """Hold a modifier across one key.

        The reason this exists: double-clicks are unreliable over an emulated
        ADB mouse (the two clicks can straddle the guest's double-click window),
        so opening things is done as select-then-Command-O instead.
        """
        self.send([{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": modifier}}}])
        self.key(qcode)
        self.send([{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": modifier}}}])
        time.sleep(0.2)

    # -- framebuffer -----------------------------------------------------

    def frame(self) -> np.ndarray:
        """Grab the framebuffer as greyscale, discarding one stale frame."""
        with tempfile.TemporaryDirectory() as tmp:
            ppm = Path(tmp) / "f.ppm"
            png = Path(tmp) / "f.png"
            for _ in range(2):
                self.qmp.screendump(ppm)
            subprocess.run(["convert", str(ppm), str(png)], check=True)
            return cv2.imread(str(png), cv2.IMREAD_GRAYSCALE).astype(np.int16)

    def locate(self) -> tuple[int, int] | None:
        """Find the cursor hotspot by nudging it and diffing the framebuffer."""
        before = self.frame()
        self.rel(NUDGE, NUDGE)
        time.sleep(0.25)
        after = self.frame()
        self.rel(-NUDGE, -NUDGE)
        time.sleep(0.25)
        ys, xs = np.where(np.abs(before - after) > 24)
        if len(xs) == 0:
            return None
        # Both positions are in the diff; the pre-nudge one is the top-left of
        # the union, and the arrow's hotspot is its own top-left pixel.
        return int(xs.min()), int(ys.min())

    # -- targeting -------------------------------------------------------

    def home(self) -> None:
        """Slam into the top-left corner so the origin is KNOWN, not assumed."""
        self.rel(-self.pin, -self.pin)
        time.sleep(PIN_SETTLE_S)

    def goto(self, x: int, y: int, tolerance: int = 2, tries: int = 30) -> tuple[int, int]:
        self.home()
        current = (0, 0)
        for _ in range(tries):
            dx, dy = x - current[0], y - current[1]
            if abs(dx) <= tolerance and abs(dy) <= tolerance:
                break
            self.rel(dx, dy)
            time.sleep(0.2)
            found = self.locate()
            if found is None:
                break
            current = found
        return current

    def click(self, x: int, y: int, count: int = 1) -> tuple[int, int]:
        landed = self.goto(x, y)
        for _ in range(count):
            self.button(True)
            time.sleep(0.08)
            self.button(False)
            time.sleep(0.08)
        time.sleep(0.4)
        return landed

    def open(self, x: int, y: int) -> tuple[int, int]:
        """Select an icon and open it — the reliable stand-in for a double-click."""
        landed = self.click(x, y)
        self.chord("meta_l", "o")
        return landed

    def drag(self, x1: int, y1: int, x2: int, y2: int, onto: bool = False) -> tuple[int, int]:
        """Drag an item. `onto=True` corrects for the drop offset.

        Without the correction a drop aimed at the Trash lands the item BESIDE
        the Trash and nothing is deleted — it looks like the drag failed when it
        actually succeeded at the wrong place.
        """
        if onto:
            x2 -= DROP_OFFSET[0]
            y2 -= DROP_OFFSET[1]
        self.goto(x1, y1)
        self.button(True)
        time.sleep(0.3)
        landed = self.goto(x2, y2)
        time.sleep(0.5)
        self.button(False)
        time.sleep(0.6)
        return landed

    def menu_pick(self, title_x: int, title_y: int, item_x: int, item_y: int) -> tuple[int, int]:
        """Pull down a menu and choose an item.

        Classic Mac menus track the mouse while the button is HELD; a
        click-release on the title leaves nothing on screen at all, so the walk
        to the item has to happen mid-press — closed-loop, like any other move.
        """
        self.goto(title_x, title_y)
        self.button(True)
        time.sleep(0.5)
        current = (title_x, title_y)
        for _ in range(10):
            dx, dy = item_x - current[0], item_y - current[1]
            if abs(dx) <= 2 and abs(dy) <= 2:
                break
            self.rel(dx, dy)
            time.sleep(0.25)
            found = self.locate()
            if found is None:
                break
            current = found
        time.sleep(0.4)
        self.button(False)
        time.sleep(0.8)
        return current

    def measure_gain(self, distances: tuple[int, ...] = (1000, 2000, 3000)) -> float:
        """Measure guest units-to-pixels. A station's cursor_scale is 1/gain."""
        samples = []
        for units in distances:
            self.home()
            self.rel(units, 0)
            time.sleep(1.2)
            found = self.locate()
            if found and found[0] > 0:
                samples.append(found[0] / units)
        if not samples:
            raise RuntimeError("could not measure pointer gain: cursor never located")
        return sum(samples) / len(samples)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--qmp", required=True)
    parser.add_argument("--gain", type=float, default=0.36)
    parser.add_argument("--extent", type=int, default=1200)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("where")
    sub.add_parser("gain")
    for name in ("goto", "click", "open"):
        p = sub.add_parser(name)
        p.add_argument("x", type=int)
        p.add_argument("y", type=int)
    p = sub.add_parser("drag")
    p.add_argument("coords", type=int, nargs=4)
    p.add_argument("--onto", action="store_true")
    p = sub.add_parser("menu")
    p.add_argument("coords", type=int, nargs=4)
    p = sub.add_parser("chord")
    p.add_argument("qcode")
    p.add_argument("--modifier", default="meta_l")
    p = sub.add_parser("key")
    p.add_argument("qcodes", nargs="+")
    p = sub.add_parser("shot")
    p.add_argument("path")

    args = parser.parse_args()
    socket_path = assert_clone_socket(args.qmp)
    with QMPClient(socket_path) as qmp:
        pointer = AdbPointer(qmp, gain=args.gain, extent=args.extent)
        if args.command == "where":
            print(pointer.locate())
        elif args.command == "gain":
            gain = pointer.measure_gain()
            print(f"gain={gain:.4f} cursor_scale={1 / gain:.4f}")
        elif args.command == "goto":
            print(pointer.goto(args.x, args.y))
        elif args.command == "click":
            print(pointer.click(args.x, args.y))
        elif args.command == "open":
            print(pointer.open(args.x, args.y))
        elif args.command == "drag":
            print(pointer.drag(*args.coords, onto=args.onto))
        elif args.command == "menu":
            print(pointer.menu_pick(*args.coords))
        elif args.command == "chord":
            pointer.chord(args.modifier, args.qcode)
        elif args.command == "key":
            for qcode in args.qcodes:
                pointer.key(qcode)
        elif args.command == "shot":
            qmp.screendump(Path(args.path).with_suffix(".ppm"))
            subprocess.run(["convert", str(Path(args.path).with_suffix(".ppm")), args.path], check=True)
            print(args.path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

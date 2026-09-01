#!/usr/bin/env python3
"""Locate a guest's pointer cursor on a LIVE station, without disturbing it.

WHY NOT measure-golden-cursor.py. That tool is for a GOLDEN checkpoint: it
restores the snapshot first, so the screen is frozen and a two-frame diff is the
cursor and nothing else. Point it at a live station (`--no-reset`) and any
animation lands in the same diff. Measured on live win311 it returned a bbox of
134x135 px -- a cursor is nearer 12x20 -- because Notepad's caret blinked
between the two screendumps. The number it printed was the corner of the CARET's
change region, not the cursor, and nothing in the output said so.

It also issues `cont`, which on a live station RESUMES A PAUSED GUEST. That is an
intervention, not an observation.

WHAT THIS DOES INSTEAD. Three-frame differential with an animation control:

    A0 --settle--> A1        anything that differs is MOVING BY ITSELF -> mask
    A1 --nudge--> B          differs, minus the mask, is the CURSOR

The mask is dilated by a few pixels so a caret that also drifts a little does not
leak a rim of false positives. The nudge is then undone. A down-right nudge puts
the ORIGINAL hotspot at the diff bbox top-left, same convention as the golden
tool, so the two agree on a still screen.

HONEST FAILURE. A cursor has a plausible size. If the surviving bbox is larger
than --max-span the screen is too busy to measure and this says NO_MATCH rather
than printing a confident corner of a text caret. A locator that cannot fail
loudly turns every busy screen into a fake station finding.

OBSERVER TRAP. One extra QMP client can stall a station, so this opens exactly
one short-lived connection, sends no `cont`, and closes it in a finally.

  locate-live-cursor.py <station> [--nudge N] [--settle MS] [--max-span PX]
prints:  <station> AT=<gx>,<gy>      (or <station> NO_MATCH reason=...)
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time

from PIL import Image, ImageChops, ImageFilter

STATIONS = "/data/vms/streamhost/stations"


def qmp_connect(sock: str, tries: int = 40):
    last = None
    for _ in range(tries):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(10)
            s.connect(sock)
            f = s.makefile("rwb")
            f.readline()  # greeting
            f.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\r\n")
            f.flush()
            f.readline()
            return s, f
        except OSError as e:  # single-client socket: retry around transient polls
            last = e
            time.sleep(0.3)
    sys.exit(f"qmp refused after {tries} tries: {sock} ({last})")


def q(f, obj):
    f.write(json.dumps(obj).encode() + b"\r\n")
    f.flush()
    return json.loads(f.readline())


def screendump(f, path):
    q(f, {"execute": "human-monitor-command", "arguments": {"command-line": f"screendump {path}"}})
    time.sleep(0.15)
    return Image.open(path).convert("L")


def rel(f, dx, dy):
    q(
        f,
        {
            "execute": "input-send-event",
            "arguments": {
                "events": [
                    {"type": "rel", "data": {"axis": "x", "value": dx}},
                    {"type": "rel", "data": {"axis": "y", "value": dy}},
                ]
            },
        },
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("station")
    ap.add_argument("--nudge", type=int, default=10)
    ap.add_argument("--settle", type=int, default=400)
    ap.add_argument("--max-span", type=int, default=64, help="largest believable cursor bbox edge")
    ap.add_argument("--dilate", type=int, default=5, help="animation-mask dilation in px")
    # Accepted and ignored: this tool NEVER resets, so --no-reset is already its
    # only behaviour. scripts/e2e/locate-relay.sh forces the flag on every call
    # so that the golden tool can never be made to restore a live exhibit, and
    # that guarantee is worth more than the tidiness of rejecting it here.
    ap.add_argument("--no-reset", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()
    sock = f"{STATIONS}/{args.station}/qmp.sock"

    s, f = qmp_connect(sock)
    try:
        tmp = f"/tmp/livecur-{args.station}"
        settle = args.settle / 1000.0
        # Animation control: same interval as the measurement, so a blink of the
        # same period is caught rather than aliased past.
        a0 = screendump(f, tmp + "-a0.ppm")
        time.sleep(settle)
        a1 = screendump(f, tmp + "-a1.ppm")
        rel(f, args.nudge, args.nudge)
        time.sleep(settle)
        b = screendump(f, tmp + "-b.ppm")
        rel(f, -args.nudge, -args.nudge)  # put it back

        moving = ImageChops.difference(a0, a1).point(lambda v: 255 if v > 8 else 0)
        mask = moving.filter(ImageFilter.MaxFilter(2 * args.dilate + 1))
        changed = ImageChops.difference(a1, b).point(lambda v: 255 if v > 8 else 0)
        # Cursor = changed by the nudge AND not moving on its own.
        cursor = ImageChops.subtract(changed, mask)

        raw_bb = changed.getbbox()
        bb = cursor.getbbox()
        anim = mask.getbbox()
        sys.stderr.write(f"[raw]  {raw_bb}\n[anim] {anim}\n[cursor] {bb}\n")
        if not bb:
            print(
                f"{args.station} NO_MATCH reason=no-change-outside-animation "
                f"raw={raw_bb} anim={anim} FB={a1.width}x{a1.height}"
            )
            return 2
        x0, y0, x1, y1 = bb
        w, h = x1 - x0, y1 - y0
        if w > args.max_span or h > args.max_span:
            print(
                f"{args.station} NO_MATCH reason=span-too-large span={w}x{h} "
                f"bbox={bb} anim={anim} FB={a1.width}x{a1.height}"
            )
            return 3
        sys.stderr.write(f"[bbox] x[{x0}-{x1}] y[{y0}-{y1}] span=({w}x{h})\n")
        print(f"{args.station} AT={x0},{y0} span={w}x{h} FB={a1.width}x{a1.height}")
        return 0
    finally:
        try:
            f.close()
        finally:
            s.close()


if __name__ == "__main__":
    raise SystemExit(main())

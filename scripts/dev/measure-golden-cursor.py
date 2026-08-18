#!/usr/bin/env python3
"""Measure a relative-pointer station's cursor position in its golden checkpoint.

The value is SH_REL_HOME_TO (guest px): on a reset the abs->rel bridge seeds its
model straight there with no corner pin, so the guest cursor snaps under the
visitor's pointer on the first move (see
docs/lab/research/rel-pointer-rehome-and-rate-cap.md).

OS-agnostic: it does NOT shape-match the cursor (that differs per guest). It
resets the station to golden, then nudge-diffs -- screendump, inject a small
relative nudge, screendump, diff -- and the changed pixels bound the cursor. A
down-right nudge puts the ORIGINAL (golden) hotspot at the bbox top-left.

Runs on labhost (QMP + PIL). Reads the LIVE station's qmp.sock, which is
single-client, so it retries around the idle-pauser's transient polls. Leaves the
station reset to golden.

  measure-golden-cursor.py <station> [--nudge N] [--settle MS]
prints:  <station> HOME_TO=<gx>,<gy>   (bbox and confidence on stderr)
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import time

from PIL import Image, ImageChops

STATIONS = "/data/vms/streamhost/stations"
RESET = "/data/vms/streamhost/serve/reset-tile.sh"


def qmp_connect(sock: str, tries: int = 40):
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
        except OSError:
            time.sleep(0.3)
    sys.exit(f"qmp refused after {tries} tries: {sock}")


def q(f, obj):
    f.write(json.dumps(obj).encode() + b"\r\n")
    f.flush()
    return json.loads(f.readline())


def screendump(f, path):
    q(f, {"execute": "human-monitor-command", "arguments": {"command-line": f"screendump {path}"}})
    time.sleep(0.12)
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
    ap.add_argument("--nudge", type=int, default=10, help="nudge size in guest delta units")
    ap.add_argument("--settle", type=int, default=400, help="ms to settle after each nudge")
    ap.add_argument("--no-reset", action="store_true", help="skip the golden restore (measure current state)")
    args = ap.parse_args()
    sock = f"{STATIONS}/{args.station}/qmp.sock"

    if not args.no_reset:
        r = subprocess.run(["/bin/bash", RESET, args.station], capture_output=True, text=True, timeout=180)
        sys.stderr.write(f"[reset] {r.stdout.strip() or r.stderr.strip()}\n")
        time.sleep(1.0)

    s, f = qmp_connect(sock)
    q(f, {"execute": "cont"})  # golden is saved -S; wake it so the nudge applies
    time.sleep(0.5)
    tmp = f"/tmp/goldcur-{args.station}"
    a = screendump(f, tmp + "-a.ppm")
    rel(f, args.nudge, args.nudge)
    time.sleep(args.settle / 1000.0)
    b = screendump(f, tmp + "-b.ppm")
    rel(f, -args.nudge, -args.nudge)  # restore
    bb = ImageChops.difference(a, b).getbbox()
    if not bb:
        sys.stderr.write("no cursor change detected -- raise --nudge, or the guest ignored input\n")
        return 2
    x0, y0, x1, y1 = bb
    # down-right nudge => original (golden) hotspot at the bbox top-left corner
    sys.stderr.write(f"[bbox] x[{x0}-{x1}] y[{y0}-{y1}]  span=({x1 - x0}x{y1 - y0})\n")
    print(f"{args.station} HOME_TO={x0},{y0}")
    # leave the station clean at golden
    if not args.no_reset:
        subprocess.run(["/bin/bash", RESET, args.station], capture_output=True, text=True, timeout=180)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

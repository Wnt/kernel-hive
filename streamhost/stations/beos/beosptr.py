#!/usr/bin/env python3
"""beosptr — closed-loop pointer driver for the `beos` station (BeOS R5).

WHY THIS EXISTS. R5 has no absolute pointing device, and it applies its own
acceleration on top of the raw PS/2 delta stream. The gain is not a constant:
it depends on *how fast* the deltas arrive, not only on their size, so there is
no open-loop "send N unit deltas" formula that lands on a target twice in a row
(measured on this guest, the same 668-px request landed at 776 px at one event
rate and at 670 px at another).

So targeting has to be CLOSED LOOP, and it needs an absolute reference. A
relative device has exactly one: the corner. The guest clamps the cursor at
(0,0), so a burst of large negative deltas is a reliable "go home".

    slam to (0,0) -> screendump (reference frame)
      -> step toward the target -> screendump
      -> locate the cursor by frame diff -> repeat on the residual

Two iterations converge to within a few pixels, which is enough for any BeOS
control.

QMP DISCIPLINE. Every command is a MOMENTARY connect -> send -> close. This
QEMU build serves a limited number of concurrent QMP clients and the streamhost
daemon already holds one; a persistent extra connection makes `labctl shot` and
pointer calls fail with EAGAIN. Never hold the socket open across a step.

Usage:
    beosptr.py where                       # slam home, report the cursor
    beosptr.py move <x> <y>                # closed-loop move to (x, y)
    beosptr.py click <x> <y> [--double]    # move, then click there
    beosptr.py shot <out.ppm>              # screendump only

    --sock PATH   QMP socket (default /data/vms/streamhost/stations/beos/qmp.sock)
"""

import argparse
import json
import os
import socket
import sys
import tempfile
import time

DEFAULT_SOCK = "/data/vms/streamhost/stations/beos/qmp.sock"

# Slam: enough large negative deltas to clamp at the corner from anywhere on a
# 1024x768 screen even at the lowest observed gain.
SLAM_STEPS = 24
SLAM_DELTA = -200

# A step is split into chunks: R5's acceleration rewards a steady stream over
# one huge jump, and a huge jump can overshoot past the far edge and clamp.
CHUNK = 40

# The drip is the motion primitive that is REPEATABLE on this guest: one unit
# every FINE_GAP seconds. It is not 1:1 -- R5 still applies a fixed multiplier,
# measured at ~2.0 px per unit here -- but unlike the coarse train that
# multiplier is stable, so it can be calibrated once and divided out. That makes
# the drip the thing the loop actually converges with, and the coarse train only
# has to get within DRIP_CEILING px, deliberately undershooting.
DRIP_CEILING = 260
COARSE_AIM = 0.5
DRIP_GAIN_GUESS = 2.0
FINE_GAP = 0.030

# Converged once we are this close, or after this many iterations.
TOLERANCE = 4
MAX_ITERS = 12

# The station's fixed mode; the clamp edges live here.
SCREEN_W = 1024
SCREEN_H = 768


class Qmp:
    """Momentary QMP client — one connect per command, never held open."""

    def __init__(self, sock_path):
        self.sock_path = sock_path

    def cmd(self, execute, arguments=None, timeout=10.0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
            f = s.makefile("rwb")
            f.readline()  # greeting
            self._rpc(f, "qmp_capabilities")
            return self._rpc(f, execute, arguments)
        finally:
            s.close()

    @staticmethod
    def _rpc(f, execute, arguments=None):
        req = {"execute": execute}
        if arguments:
            req["arguments"] = arguments
        f.write((json.dumps(req) + "\r\n").encode())
        f.flush()
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("QMP closed mid-command")
            msg = json.loads(line)
            if "event" in msg:  # asynchronous, not our reply
                continue
            if "error" in msg:
                raise RuntimeError("QMP error: %s" % msg["error"])
            return msg.get("return")


def send_rel(q, dx, dy):
    events = []
    if dx:
        events.append({"type": "rel", "data": {"axis": "x", "value": int(dx)}})
    if dy:
        events.append({"type": "rel", "data": {"axis": "y", "value": int(dy)}})
    if events:
        q.cmd("input-send-event", {"events": events})


def send_click(q, double=False, button="left"):
    for _ in range(2 if double else 1):
        q.cmd(
            "input-send-event",
            {"events": [{"type": "btn", "data": {"down": True, "button": button}}]},
        )
        q.cmd(
            "input-send-event",
            {"events": [{"type": "btn", "data": {"down": False, "button": button}}]},
        )
        if double:
            time.sleep(0.08)


def read_ppm(path):
    """Minimal binary-PPM (P6) reader -> (w, h, bytes). QEMU writes P6."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise RuntimeError("not a P6 PPM: %s" % path)
    fields, idx = [], 2
    while len(fields) < 3:
        while idx < len(data) and data[idx : idx + 1].isspace():
            idx += 1
        if data[idx : idx + 1] == b"#":
            while data[idx : idx + 1] not in (b"\n", b""):
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx : idx + 1].isspace():
            idx += 1
        fields.append(int(data[start:idx]))
    idx += 1  # single whitespace after maxval
    w, h, _maxval = fields
    return w, h, data[idx : idx + w * h * 3]


def screendump(q, path):
    q.cmd("screendump", {"filename": path}, timeout=30.0)
    # QEMU writes asynchronously on some builds; wait for a complete file.
    for _ in range(60):
        if os.path.exists(path) and os.path.getsize(path) > 1024:
            try:
                return read_ppm(path)
            except (RuntimeError, ValueError, IndexError):
                pass
        time.sleep(0.1)
    raise RuntimeError("screendump did not produce a readable PPM: %s" % path)


# A BeOS R5 arrow cursor fits inside this box; used both to mask the blob the
# cursor VACATED and to reject specks of unrelated repaint.
CURSOR_BOX = 40

# The Deskbar clock repaints once a minute. A frame diff taken across that tick
# would otherwise read as "the cursor is over there". Keep this box TIGHT around
# the clock text: anything masked here is a place the cursor cannot be found, so
# an over-wide mask makes the Deskbar tray unclickable.
CLOCK_ZONE = (962, 22, 1020, 44)

# How far to jiggle when locating the cursor. Two pixels is enough to show up
# in a frame diff and small enough not to cross a hover boundary.
JIGGLE = 2


def diff_bbox(a, b, ignore=()):
    """Bounding box of differing pixels, skipping `ignore` rectangles.

    `ignore` exists because a diff against the slam-home reference always shows
    TWO blobs: the cursor's current position, and the corner it vacated (those
    pixels repainted back to background). Masking the vacated corner -- and the
    Deskbar clock, which ticks on its own -- leaves just the cursor.
    """
    wa, ha, pa = a
    wb, hb, pb = b
    if (wa, ha) != (wb, hb):
        raise RuntimeError("frame size changed mid-measurement")

    def masked(x, y):
        for x0, y0, x1, y1 in ignore:
            if x0 <= x <= x1 and y0 <= y <= y1:
                return True
        return False

    minx, miny, maxx, maxy = wa, ha, -1, -1
    for y in range(ha):
        row = y * wa * 3
        ra = pa[row : row + wa * 3]
        rb = pb[row : row + wa * 3]
        if ra == rb:
            continue
        for x in range(wa):
            o = x * 3
            if ra[o : o + 3] != rb[o : o + 3] and not masked(x, y):
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    if maxx < 0:
        return None
    return minx, miny, maxx, maxy


# COARSE MOTION is a train of identical, rate-limited events, never one jump
# and never a fast burst. R5's acceleration is a function of BOTH the size of a
# delta and how fast deltas arrive, so the only way to get a predictable
# displacement is to hold both constant and calibrate the result: one event of
# COARSE_MAG, every COARSE_GAP seconds, moves a fixed number of pixels.
COARSE_MAG = 20
COARSE_GAP = 0.050


def push(q, n, axis, sign):
    """Send n identical coarse events along one axis."""
    for _ in range(n):
        send_rel(q, COARSE_MAG * sign if axis == "x" else 0, COARSE_MAG * sign if axis == "y" else 0)
        time.sleep(COARSE_GAP)
    time.sleep(0.30)


def drip(q, dx, dy):
    """Place the last few pixels: one unit at a time, slowly enough that the
    guest's acceleration stays out of it, so the request is ~1:1."""
    while dx or dy:
        ux = (1 if dx > 0 else -1) if dx else 0
        uy = (1 if dy > 0 else -1) if dy else 0
        send_rel(q, ux, uy)
        dx -= ux
        dy -= uy
        time.sleep(FINE_GAP)
    time.sleep(0.30)


def cursor_sized(box):
    """A real cursor jiggle changes a region no bigger than the cursor plus the
    jiggle distance. Anything larger is some other repaint."""
    minx, miny, maxx, maxy = box
    return (maxx - minx) <= CURSOR_BOX + JIGGLE and (maxy - miny) <= CURSOR_BOX


def locate(q, tmpdir, tag):
    """Find the cursor by JIGGLING it two pixels and diffing the two frames.

    The obvious method -- diff against the slam-home reference -- does not work
    on this desktop: moving the cursor across a NetPositive page repaints the
    window's status bar with the imagemap URL under the pointer, so the diff
    reports a large changed region nowhere near the cursor and the loop chases
    it. A two-pixel jiggle changes essentially nothing EXCEPT the cursor: hover
    state does not flip over two pixels, so whatever moved is the cursor.

    Returns the position AFTER the jiggle, or None if nothing moved (the cursor
    is in a clamp and could not travel).
    """
    before = screendump(q, os.path.join(tmpdir, "%s-a.ppm" % tag))
    for direction in (1, -1):
        drip(q, JIGGLE * direction, 0)
        after = screendump(q, os.path.join(tmpdir, "%s-b%d.ppm" % (tag, direction)))
        box = diff_bbox(before, after, (CLOCK_ZONE,))
        if box is not None and not cursor_sized(box):
            # Something bigger than a cursor repainted between the two frames
            # (a blinking Terminal caret, a browser status bar reacting to
            # hover). Believing it sends the loop chasing a fixed point that is
            # not the pointer, so reject it rather than average it in.
            box = None
        if box is not None:
            # The changed span covers the cursor before AND after the jiggle.
            # Moving right, the span's left edge is where it started; moving
            # left, the left edge is where it ended.
            return (box[0] + JIGGLE, box[1]) if direction > 0 else (box[0], box[1])
        # Nothing moved: the cursor is pinned against that edge. Try the other
        # direction before giving up -- "did not move" is a clamp, not home.
        before = after
    return None


def clamped(x, y):
    """True if the cursor is on a screen edge, where "how far did it travel"
    is not a measurement of anything."""
    return x <= 1 or y <= 1 or x >= SCREEN_W - 2 or y >= SCREEN_H - 2


def slam_home(q, tmpdir):
    """Drive the cursor into the (0,0) clamp — the only absolute reference a
    relative pointing device has."""
    for _ in range(SLAM_STEPS):
        send_rel(q, SLAM_DELTA, SLAM_DELTA)
        time.sleep(0.01)
    time.sleep(0.4)
    return screendump(q, os.path.join(tmpdir, "home.ppm"))


def move_to(q, tx, ty, verbose=True):
    """Closed-loop move to (tx, ty); returns the measured landing position.

    Slam into the (0,0) clamp for an absolute reference, calibrate
    pixels-per-coarse-event with a short safe probe, walk each axis with that
    many events, then drip the residual. Axes are walked one at a time so each
    measurement attributes cleanly to one of them.
    """
    with tempfile.TemporaryDirectory(prefix="beosptr.") as tmpdir:
        os.chmod(tmpdir, 0o777)  # QEMU may run as a different uid
        slam_home(q, tmpdir)

        # Calibrate: a short train, well clear of the far clamp.
        probe = 5
        push(q, probe, "x", 1)
        pos = locate(q, tmpdir, "cal")
        px, py = pos if pos else (0, 0)
        per_event = max(1.0, px / float(probe)) if px < SCREEN_W - 2 else 40.0
        drip_gain = DRIP_GAIN_GUESS
        if verbose:
            print("calibrated %.1f px per coarse event (probe landed x=%d)" % (per_event, px), file=sys.stderr)

        for i in range(MAX_ITERS):
            rx, ry = tx - px, ty - py
            if abs(rx) <= TOLERANCE and abs(ry) <= TOLERANCE:
                break
            if max(abs(rx), abs(ry)) <= DRIP_CEILING:
                ax = int(round(rx / drip_gain))
                ay = int(round(ry / drip_gain))
                if (ax, ay) == (0, 0):
                    break
                drip(q, ax, ay)
                what = "drip"
            else:
                # Walk the longer axis first; short hops go to the drip.
                # Aim for HALF the residual, not all of it. per_event is only
                # ever an estimate of a rate-dependent acceleration curve, and
                # an overshoot lands in a screen clamp -- which costs a re-slam
                # and loses the position entirely. Halving converges in a couple
                # of rounds and cannot run past the target.
                if abs(rx) >= abs(ry):
                    n = int(round(abs(rx) * COARSE_AIM / per_event))
                    push(q, max(1, n), "x", 1 if rx > 0 else -1)
                    what = "x*%d" % n
                else:
                    n = int(round(abs(ry) * COARSE_AIM / per_event))
                    push(q, max(1, n), "y", 1 if ry > 0 else -1)
                    what = "y*%d" % n
            pos = locate(q, tmpdir, "i%d" % i)
            if pos is None:
                # Pinned in a clamp and unable to jiggle: re-establish the
                # absolute reference rather than guessing where we are.
                slam_home(q, tmpdir)
                px, py = 0, 0
                if verbose:
                    print("iter %d: pinned in a clamp, re-slammed home" % i, file=sys.stderr)
                continue
            nx, ny = pos
            # Re-measure pixels-per-event from any clean coarse move.
            if what.startswith("x*") and not clamped(nx, ny) and n:
                moved = abs(nx - px)
                if moved > 2:
                    per_event = max(per_event, moved / float(n))
            elif what.startswith("y*") and not clamped(nx, ny) and n:
                moved = abs(ny - py)
                if moved > 2:
                    per_event = max(per_event, moved / float(n))
            if what == "drip" and not clamped(nx, ny):
                # Re-measure the drip multiplier off whichever axis travelled
                # further; the short axis is dominated by rounding.
                moved, asked = ((nx - px), ax) if abs(ax) >= abs(ay) else ((ny - py), ay)
                if asked and abs(moved) > 4:
                    drip_gain = max(0.3, min(6.0, abs(moved) / float(abs(asked))))
            px, py = nx, ny
            if verbose:
                print(
                    "iter %d: %s -> (%d,%d) residual (%d,%d) %.1f px/ev drip %.2f"
                    % (i, what, px, py, tx - px, ty - py, per_event, drip_gain),
                    file=sys.stderr,
                )
        return px, py


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sock", default=DEFAULT_SOCK)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("where")
    m = sub.add_parser("move")
    m.add_argument("x", type=int)
    m.add_argument("y", type=int)
    c = sub.add_parser("click")
    c.add_argument("x", type=int)
    c.add_argument("y", type=int)
    c.add_argument("--double", action="store_true")
    c.add_argument("--button", default="left", choices=("left", "right", "middle"))
    s = sub.add_parser("shot")
    s.add_argument("out")
    args = ap.parse_args()

    q = Qmp(args.sock)

    if args.cmd == "shot":
        w, h, _ = screendump(q, args.out)
        print("%s %dx%d" % (args.out, w, h))
        return 0

    if args.cmd == "where":
        with tempfile.TemporaryDirectory(prefix="beosptr.") as tmpdir:
            os.chmod(tmpdir, 0o777)
            slam_home(q, tmpdir)
            push(q, 5, "x", 1)
            pos = locate(q, tmpdir, "probe")
            print("slam home, then 5 coarse x events -> cursor at %s" % (pos,))
        return 0

    px, py = move_to(q, args.x, args.y)
    if args.cmd == "click":
        send_click(q, double=args.double, button=args.button)
    print("landed (%d,%d) target (%d,%d)" % (px, py, args.x, args.y))
    return 0


if __name__ == "__main__":
    sys.exit(main())

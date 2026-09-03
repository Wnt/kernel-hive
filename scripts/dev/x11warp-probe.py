#!/usr/bin/env python3
"""x11warp-probe.py — drive a guest's X11 pointer from the host, with no X
client libraries, and optionally click through QMP to drive a GUI wizard.

Consolidates three per-wave copies that each reinvented this (and each got
held by ruff on it): scripts/build-guests/tiles/slackware/xwarp.py,
scripts/build-guests/tiles/debian22/xwarp.py, scripts/dev/x11ptr.py
(sunos414's original). All three spoke the SAME two raw X11 requests over the
loopback forward an x11warp station publishes — WarpPointer as the ACTUATOR,
QueryPointer as the SENSOR — because labhost has no python-xlib and the guest
is usually an X11R4/R5-era server with no XTEST. This is that probe, once.

    x11warp-probe.py --display 127.0.0.1:84 --warp 100,700 --warp 900,100
    x11warp-probe.py --display 127.0.0.1:84 --warp 400,300 --shot --station suse64
    x11warp-probe.py --display 127.0.0.1:84 --warp 400,300 \\
        --click --qmp /data/vms/streamhost/stations/suse64/qmp.sock --station suse64

Each --warp target is warped to, then read back with QueryPointer; a mismatch
is printed and makes the exit code 1. --shot takes a `labctl shot` of the
STATION (not the raw display) afterwards, over the one door (`ssh lab`), and
copies it back to --out, so the cursor's on-screen visibility is checked the
same way every other proof in this lab is: the framebuffer, not a readback.
--click sends a BUTTON-ONLY QMP `input-send-event` (press then release, no
motion) so a click lands exactly where the warp put the guest's own pointer —
see docs/lab/INPUT-DEBUGGING.md's "wizard-driving" section for why this beats
an absolute click on a station whose X server has no XTEST.

--station arms a scripts/lib/guest_wake.py WakeLease for the whole probe: a
station idle-paused by streamhost accepts every one of these requests and
reacts to none of them, which reads exactly like a wedged pointer. Omit
--station only against a rig/clone that streamhost never manages.

Raw protocol on purpose (see x11ptr.py's original note): the two requests are
8 and 24 bytes, a dependency would cost more than the code, and this is NOT
station-specific — any unauthenticated X server reachable over TCP answers it.
If the connection is refused with "Internal error during connection
authorization check", that is a REVERSE-LOOKUP failure, not an authorization
decision: the server resolves names for its access list, so the SLIRP peer
must be named in the guest's /etc/hosts before `xhost +<addr>` can match it.
"""

from __future__ import annotations

import argparse
import socket
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

SETUP = struct.Struct(">ccHHHHH")
SCREEN0 = struct.Struct(">IIIIIHH")


class XPointer:
    """One connection to an unauthenticated X server."""

    def __init__(self, host: str, port: int, timeout: float = 10.0) -> None:
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.sendall(SETUP.pack(b"B", b"\0", 11, 0, 0, 0, 0))
        head = self._recv(8)
        extra = struct.unpack(">H", head[6:8])[0] * 4
        body = self._recv(extra)
        if head[0] != 1:
            raise RuntimeError(f"X setup refused: {body[: head[1]].decode('latin-1')}")
        vendor_len, _maxreq = struct.unpack(">HH", body[16:20])
        formats = body[21]
        offset = 32 + ((vendor_len + 3) // 4) * 4 + 8 * formats
        self.root, _cmap, _white, _black, _masks, self.width, self.height = SCREEN0.unpack(
            body[offset : offset + SCREEN0.size]
        )

    def _recv(self, count: int) -> bytes:
        buf = b""
        while len(buf) < count:
            chunk = self.sock.recv(count - len(buf))
            if not chunk:
                raise RuntimeError("X server closed the connection")
            buf += chunk
        return buf

    def query(self) -> tuple[int, int]:
        """QueryPointer: the guest's OWN answer, in root coordinates."""
        self.sock.sendall(struct.pack(">BBHI", 38, 0, 2, self.root))
        reply = self._recv(32)
        x, y = struct.unpack(">hh", reply[16:20])
        return x, y

    def warp(self, x: int, y: int) -> None:
        """WarpPointer to an absolute root coordinate (src None, no bounding box)."""
        self.sock.sendall(struct.pack(">BBHIIhhHHhh", 41, 0, 6, 0, self.root, 0, 0, 0, 0, x, y))

    def close(self) -> None:
        self.sock.close()


def readback_matches(target: tuple[int, int], actual: tuple[int, int]) -> bool:
    """The one comparison every warp result is judged by. A pure function so
    the exit-code logic is testable with no X server anywhere."""
    return target == actual


def parse_display(display: str) -> tuple[str, int]:
    """'host:N' -> (host, 6000+N), the standard X display-number convention."""
    if ":" not in display:
        raise ValueError(f"--display must be HOST:N, got {display!r}")
    host, _, num = display.rpartition(":")
    if not host or not num.lstrip("-").isdigit():
        raise ValueError(f"--display must be HOST:N, got {display!r}")
    return host, 6000 + int(num)


def parse_point(text: str) -> tuple[int, int]:
    parts = text.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(f"expected X,Y, got {text!r}")
    try:
        return int(parts[0]), int(parts[1])
    except ValueError as e:
        raise argparse.ArgumentTypeError(f"expected X,Y, got {text!r}") from e


def _press(q, button: str, down: bool) -> None:
    q.execute("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": button}}])


def send_click(qmp_path: str, button: str, station: str | None) -> None:
    """A BUTTON-ONLY input-send-event: press then release, no motion, so the
    click lands wherever the guest's own pointer already is (the warp target,
    once QueryPointer confirmed it)."""
    from labqmp import QMPClient  # local import: only needed when --click is used

    q = QMPClient(qmp_path)
    try:
        if station:
            from guest_wake import GuestPaused, WakeLease, assert_running, wake

            with WakeLease(station):
                try:
                    wake(q.execute, station)
                except GuestPaused as e:
                    raise SystemExit(f"x11warp-probe: {e}") from e
                _press(q, button, True)
                _press(q, button, False)
                assert_running(q.execute, station, "the click")
        else:
            _press(q, button, True)
            _press(q, button, False)
    finally:
        q.close()


def take_shot(station: str, out: Path, lab: str) -> Path:
    """`labctl shot` over the one door, then pull the PNG back. Rule 9: the
    framebuffer is the only proof the cursor is actually visible — a readback
    can agree with a warp and still be a sprite drawn off-screen or hidden."""
    remote = f"/tmp/x11warp-probe-{station}.png"
    subprocess.run(["ssh", lab, "labctl", "shot", station, remote], check=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["scp", "-q", f"{lab}:{remote}", str(out)], check=True)
    return out


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--display", required=True, help="X display to probe, HOST:N (port = 6000+N)")
    ap.add_argument(
        "--warp",
        dest="warps",
        action="append",
        type=parse_point,
        default=[],
        metavar="X,Y",
        help="warp to X,Y and read it back; repeatable, applied in order",
    )
    ap.add_argument("--timeout", type=float, default=10.0, help="X connect timeout, seconds")
    ap.add_argument("--shot", action="store_true", help="labctl shot the station after warping")
    ap.add_argument("--click", action="store_true", help="send a button-only QMP click after the last warp")
    ap.add_argument("--qmp", help="QMP unix socket path (required with --click)")
    ap.add_argument("--button", default="left", help="button for --click (default left)")
    ap.add_argument("--station", help="station id — labctl shot target, and arms a wake lease around --click")
    ap.add_argument("--out", help="local path for --shot's PNG (default /tmp/x11warp-probe/<station>.png)")
    ap.add_argument("--lab", default="lab", help="ssh host for the one door (default 'lab')")
    return ap


def main(argv: list[str]) -> int:
    ap = build_parser()
    a = ap.parse_args(argv[1:])

    if a.click and not a.qmp:
        ap.error("--click requires --qmp")
    if a.shot and not a.station:
        ap.error("--shot requires --station (the labctl shot target)")

    host, port = parse_display(a.display)
    conn = XPointer(host, port, a.timeout)
    print(f"root=0x{conn.root:x} screen={conn.width}x{conn.height}")

    bad = 0
    for target in a.warps:
        conn.warp(*target)
        actual = conn.query()
        ok = readback_matches(target, actual)
        bad += not ok
        print(f"warp {target} -> readback {actual} {'OK' if ok else 'MISMATCH'}")
    conn.close()

    if a.click:
        send_click(a.qmp, a.button, a.station)
        print(f"click: button={a.button} sent")

    if a.shot:
        out = Path(a.out) if a.out else Path(f"/tmp/x11warp-probe/{a.station}.png")
        take_shot(a.station, out, a.lab)
        print(f"shot: {out}")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

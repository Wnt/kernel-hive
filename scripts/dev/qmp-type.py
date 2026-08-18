#!/usr/bin/env python3
"""qmp-type.py — drive a QEMU guest's keyboard/mouse over QMP and screendump the result.

The install-phase driver for stations that have no exec channel yet (HP-UX,
Mac OS, ...): the streamhost daemon only injects input while a browser client
is attached, and the operator's browser should stay a read-only monitor, so
the agent types through QMP instead. Born as /data/vms/sandbox/hpuxvue/hpt.py
during the hpuxvue install (docs/lab/simultaneous-OS-install.md section 5).

Runs ON THE BOX (the QMP socket is a unix socket). One QMP connection per
invocation, one HMP command per key — slow (about 8 keys/s) but reliable, and
it works with the daemon attached to the same guest.

    qmp-type.py --station hpuxvue "text to type\\n"          # \\n = Enter
    qmp-type.py --qmp /path/qmp.sock --keys ret tab f5 ctrl-c  # raw sendkey names
    qmp-type.py --station X --mouse 130 -84 --click            # move, then left click
    qmp-type.py --station X --shot                             # screendump only

Every run ends with a screendump to --out (default /tmp/qmp-type/<station>/cur.png
plus cur.ppm) after --wait seconds, because the framebuffer is the only proof.
Set --out to your sandbox dir. Read the PNG from the client (`chmod a+r` is
done for you).

Text goes through a char -> sendkey map: letters, digits, space, punctuation
and the shifted variants; uppercase letters send shift-<x>. Anything unmapped
is a hard error (no silent drops).
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

STATIONS = Path("/data/vms/streamhost/stations")

CHAR_KEYS = {
    " ": "spc",
    "/": "slash",
    "-": "minus",
    ".": "dot",
    ",": "comma",
    ";": "semicolon",
    "'": "apostrophe",
    "=": "equal",
    "[": "bracket_left",
    "]": "bracket_right",
    "\\": "backslash",
    "`": "grave_accent",
    "\n": "ret",
    "\t": "tab",
    "_": "shift-minus",
    ":": "shift-semicolon",
    ">": "shift-dot",
    "<": "shift-comma",
    "|": "shift-backslash",
    '"': "shift-apostrophe",
    "$": "shift-4",
    "(": "shift-9",
    ")": "shift-0",
    "*": "shift-8",
    "&": "shift-7",
    "?": "shift-slash",
    "!": "shift-1",
    "#": "shift-3",
    "@": "shift-2",
    "%": "shift-5",
    "^": "shift-6",
    "+": "shift-equal",
    "{": "shift-bracket_left",
    "}": "shift-bracket_right",
    "~": "shift-grave_accent",
}


def key_for(ch: str) -> str:
    if ch in CHAR_KEYS:
        return CHAR_KEYS[ch]
    if ch.isascii() and ch.isalpha():
        return f"shift-{ch.lower()}" if ch.isupper() else ch
    if ch.isdigit():
        return ch
    raise SystemExit(f"qmp-type: no sendkey mapping for {ch!r}")


class Qmp:
    def __init__(self, path: str):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(60)
        self.s.connect(path)
        self.buf = b""
        self._readline()  # greeting
        self.cmd({"execute": "qmp_capabilities"})

    def _readline(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("qmp-type: QMP connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, obj: dict) -> dict:
        self.s.sendall((json.dumps(obj) + "\r\n").encode())
        while True:
            m = self._readline()
            if "return" in m or "error" in m:
                if "error" in m:
                    raise SystemExit(f"qmp-type: {obj} -> {m['error']}")
                return m

    def hmp(self, line: str) -> str:
        r = self.cmd({"execute": "human-monitor-command", "arguments": {"command-line": line}})
        return r.get("return", "")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--station", help="station dir name under /data/vms/streamhost/stations (uses its qmp.sock)")
    src.add_argument("--qmp", help="explicit QMP unix socket path (a clone or a rig)")
    ap.add_argument("text", nargs="?", help="text to type; \\n and \\t escapes are honoured")
    ap.add_argument("--keys", nargs="*", default=[], help="raw sendkey names, sent after the text")
    ap.add_argument("--mouse", nargs=2, type=int, metavar=("DX", "DY"), help="relative mouse_move before any click")
    ap.add_argument("--click", action="store_true", help="left click (mouse_button 1 then 0)")
    ap.add_argument("--button", type=int, default=1, help="button mask for --click (1 left, 2 middle, 4 right)")
    ap.add_argument("--gap", type=float, default=0.12, help="seconds between keys")
    ap.add_argument("--wait", type=float, default=3.0, help="seconds to wait before the screendump")
    ap.add_argument("--out", help="output dir for cur.ppm/cur.png (default /tmp/qmp-type/<station>)")
    ap.add_argument("--shot", action="store_true", help="screendump only (no input)")
    a = ap.parse_args()

    qmp_path = a.qmp or str(STATIONS / a.station / "qmp.sock")
    name = a.station or Path(qmp_path).parent.name
    out = Path(a.out or f"/tmp/qmp-type/{name}")
    out.mkdir(parents=True, exist_ok=True)

    q = Qmp(qmp_path)
    if not a.shot:
        text = (a.text or "").encode().decode("unicode_escape")
        for ch in text:
            q.hmp(f"sendkey {key_for(ch)}")
            time.sleep(a.gap)
        for k in a.keys:
            q.hmp(f"sendkey {k}")
            time.sleep(a.gap * 3)
        if a.mouse:
            q.hmp(f"mouse_move {a.mouse[0]} {a.mouse[1]}")
            time.sleep(0.5)
        if a.click:
            q.hmp(f"mouse_button {a.button}")
            time.sleep(0.15)
            q.hmp("mouse_button 0")
        time.sleep(a.wait)
    ppm = out / "cur.ppm"
    png = out / "cur.png"
    q.hmp(f"screendump {ppm}")
    subprocess.run(["convert", str(ppm), str(png)], check=True)
    for p in (ppm, png):
        p.chmod(0o644)
    print(png)
    return 0


if __name__ == "__main__":
    sys.exit(main())

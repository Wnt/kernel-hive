#!/usr/bin/env python3
"""Drive and MEASURE the Alto tile over its QMP socket.

Everything here is a press/release pair with explicit timing: QEMU's `send-key`
releases asynchronously and overlapping calls lose characters on their own
(ADD-NEW-OS-PLAYBOOK.md 5.1). Modifiers lead by a full gap, because pressing
shift and the letter in one event loses the capital every time -- the Alto
samples its keyboard once a field and saw both in the same sample.

  type <hold_ms> <gap_ms> <text>   key <hold_ms> <qcode...>
  abs <x> <y>                      click <x> <y> <left|middle|right> [dwell_ms]
  ink <l> <t> <w> <h>              -> count of dark pixels in that rect
"""

import json
import os
import socket
import sys
import tempfile
import time

W, H = 608, 808

PLAIN = {
    " ": "spc",
    "-": "minus",
    ".": "dot",
    ",": "comma",
    "/": "slash",
    ";": "semicolon",
    "'": "apostrophe",
    "[": "bracket_left",
    "]": "bracket_right",
    "=": "equal",
    "\\": "backslash",
    "\n": "ret",
}
SHIFT = {
    "!": "1",
    "@": "2",
    "#": "3",
    "$": "4",
    "%": "5",
    "^": "6",
    "&": "7",
    "*": "8",
    "(": "9",
    ")": "0",
    "_": "minus",
    "+": "equal",
    ":": "semicolon",
    '"': "apostrophe",
    "<": "comma",
    ">": "dot",
    "?": "slash",
}


def chord(ch):
    if ch.isdigit() or (ch.isascii() and ch.islower()):
        return [ch]
    if ch.isascii() and ch.isupper():
        return ["shift", ch.lower()]
    if ch in PLAIN:
        return [PLAIN[ch]]
    if ch in SHIFT:
        return ["shift", SHIFT[ch]]
    raise SystemExit("unmappable character %r" % ch)


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(30)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **args):
        payload = {"execute": execute}
        if args:
            payload["arguments"] = args
        self.f.write((json.dumps(payload) + "\n").encode())
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            if "error" in msg:
                raise SystemExit("QMP error: %s" % msg["error"])
            return msg.get("return")

    def keys(self, qcodes, down):
        self.cmd(
            "input-send-event",
            events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": q}}} for q in qcodes],
        )

    def press(self, qcodes, hold_ms, gap_ms):
        mods, key = qcodes[:-1], qcodes[-1:]
        if mods:
            self.keys(mods, True)
            time.sleep(gap_ms / 1000.0)
        self.keys(key, True)
        time.sleep(hold_ms / 1000.0)
        self.keys(key, False)
        if mods:
            time.sleep(gap_ms / 1000.0)
            self.keys(list(reversed(mods)), False)
        time.sleep(gap_ms / 1000.0)

    def move(self, x, y):
        self.cmd(
            "input-send-event",
            events=[
                {"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
                {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}},
            ],
        )

    def ink(self, left, top, w, h):
        """Dark pixels in a rect of the captured framebuffer."""
        path = tempfile.mktemp(suffix=".ppm", dir="/tmp")
        try:
            self.cmd("screendump", filename=path)
            for _ in range(80):
                if os.path.exists(path) and os.path.getsize(path) > 1024:
                    break
                time.sleep(0.1)
            with open(path, "rb") as fh:
                data = fh.read()
            parts = data.split(b"\n", 3)
            if parts[0].strip() != b"P6":
                raise SystemExit("screendump is not a P6 PPM")
            fw, fh_ = (int(v) for v in parts[1].split())
            pix = parts[3] if len(parts) > 3 else b""
            n = 0
            for y in range(top, min(top + h, fh_)):
                row = y * fw * 3
                for x in range(left, min(left + w, fw)):
                    i = row + x * 3
                    if pix[i] + pix[i + 1] + pix[i + 2] < 384:
                        n += 1
            return n
        finally:
            if os.path.exists(path):
                os.unlink(path)


def main():
    q = Qmp(sys.argv[1])
    op = sys.argv[2]
    if op == "type":
        hold, gap = int(sys.argv[3]), int(sys.argv[4])
        for ch in sys.argv[5]:
            q.press(chord(ch), hold, gap)
    elif op == "key":
        hold = int(sys.argv[3])
        q.press(sys.argv[4:], hold, hold)
    elif op == "abs":
        q.move(int(sys.argv[3]), int(sys.argv[4]))
    elif op == "click":
        dwell = int(sys.argv[6]) if len(sys.argv) > 6 else 400
        q.move(int(sys.argv[3]), int(sys.argv[4]))
        time.sleep(0.2)
        q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": sys.argv[5]}}])
        time.sleep(dwell / 1000.0)
        q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": sys.argv[5]}}])
    elif op == "ink":
        print(q.ink(*(int(v) for v in sys.argv[3:7])))
    else:
        raise SystemExit(__doc__)


main()

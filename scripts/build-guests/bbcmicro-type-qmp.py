#!/usr/bin/env python3
"""Type BBC BASIC into this tile over QMP, with explicit pacing.

Usage: type-qmp.py <qmp.sock> <hold_ms> <gap_ms> <text>   (\\n = RETURN)

CHARMAP: thirteen characters live on different keys on a BBC than on a US PC
(derived from the driver with scripts/dev/mame-keymap.py). The value is the
US-keyboard character whose KEY produces the wanted BBC character.
LETTERS ARE SENT UNSHIFTED: the MOS turns CAPS LOCK on at reset, so unshifted
letters arrive upper case, which is what BASIC's tokeniser needs.
"""

import json
import socket
import sys
import time

CHARMAP = {
    '"': "@",
    "'": "&",
    "&": "^",
    "(": "*",
    ")": "(",
    "=": "_",
    "@": "\\",
    "+": ":",
    "^": "=",
    "~": "+",
    "_": "`",
    ":": "'",
    "*": '"',
}
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
    "\\": "backslash",
    "`": "grave_accent",
    "=": "equal",
    "\n": "ret",
}
SHIFTED = {
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
    "{": "bracket_left",
    "}": "bracket_right",
    "|": "backslash",
    "~": "grave_accent",
}

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(30)
sock.connect(sys.argv[1])
conn = sock.makefile("rwb")
conn.readline()
hold, gap = int(sys.argv[2]) / 1000.0, int(sys.argv[3]) / 1000.0


def cmd(payload):
    conn.write((json.dumps(payload) + "\n").encode())
    conn.flush()
    while True:
        msg = json.loads(conn.readline())
        if "error" in msg:
            raise SystemExit(f"QMP error: {msg}")
        if "return" in msg:
            return


def send(qcode, down):
    cmd(
        {
            "execute": "input-send-event",
            "arguments": {"events": [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}]},
        }
    )


cmd({"execute": "qmp_capabilities"})
for raw in " ".join(sys.argv[4:]).replace("\\n", "\n"):
    ch = CHARMAP.get(raw, raw)
    shift, code = False, None
    if ch.isdigit() or (ch.isalpha() and ch.isascii()):
        code = ch.lower()
    elif ch in PLAIN:
        code = PLAIN[ch]
    elif ch in SHIFTED:
        shift, code = True, SHIFTED[ch]
    if code is None:
        raise SystemExit(f"no qcode for {raw!r}")
    if shift:
        send("shift", True)
        time.sleep(hold)
    send(code, True)
    time.sleep(hold)
    send(code, False)
    if shift:
        time.sleep(hold)
        send("shift", False)
    time.sleep(gap)

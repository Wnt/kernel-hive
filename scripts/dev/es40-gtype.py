#!/usr/bin/env python3
"""es40-gtype.py <ctl.sock> — type stdin into an es40 guest over mamectl/1.

ctltest.py only emits letters/digits and a handful of punctuation, which is
not enough to write a shell script inside the guest. This maps the full US
layout onto the key fields the es40 ctlsock table actually accepts, using
Left Shift for the shifted glyphs.
"""

import socket
import sys
import time

UNSHIFTED = {
    " ": "Space",
    "\t": "Tab",
    "\n": "Enter",
    "-": "-",
    ",": ",",
    ".": ".",
    "/": "/",
    ";": ";",
    "'": "'",
    "[": "[",
    "]": "]",
    "\\": "\\",
    "=": "=",
    "`": "`",
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
    "_": "-",
    "+": "=",
    "{": "[",
    "}": "]",
    "|": "\\",
    ":": ";",
    '"': "'",
    "<": ",",
    ">": ".",
    "?": "/",
    "~": "`",
}

sock_path = sys.argv[1]
text = sys.stdin.read()

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(sock_path)
f = s.makefile("rw")
f.readline()  # HELLO
seq = 0
bad = []


def send(verb):
    global seq
    seq += 1
    f.write(f"{seq} {verb}\n")
    f.flush()
    line = f.readline()
    return line.strip().endswith("OK") or " OK" in line


def key(field, shift=False):
    if shift:
        send("KEY 1 P0.0 Left Shift")
    ok = send(f"KEY 1 P0.0 {field}")
    send(f"KEY 0 P0.0 {field}")
    if shift:
        send("KEY 0 P0.0 Left Shift")
    return ok


for ch in text:
    if ch == "\r":
        continue
    if ch.isalpha():
        ok = key(ch.upper(), ch.isupper())
    elif ch.isdigit():
        ok = key(ch)
    elif ch in UNSHIFTED:
        ok = key(UNSHIFTED[ch])
    elif ch in SHIFTED:
        ok = key(SHIFTED[ch], True)
    else:
        bad.append(ch)
        continue
    if not ok:
        bad.append(ch)
    time.sleep(0.045)

print(f"typed {len(text)} chars; unmapped/failed: {sorted(set(bad))!r}")

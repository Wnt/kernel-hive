#!/usr/bin/env python3
"""mamectl/1 client for the host-native `indyr4400` station (Iris).

Sibling of `stations/nextstep/ctl.py`, and the same reason for existing: the
launcher, the bake script and any bring-up rig need to say a word to the running
emulator's control socket, and bash cannot speak to a unix socket. streamhost's
own `mamesock` sink is the daemon's and never sends these verbs.

Two modes, deliberately, because the difference is load-bearing:

    ctl.py <socket> <verb> [<verb> ...]      ACKING: one verb, wait for its ack
    ctl.py <socket> --type <text>            PIPELINED: every KEY edge written
                                             back-to-back at ZERO spacing

An acking client paces the edges for you and hides exactly the loss a browser
produces — an acking rig once typed 26 of 26 while the live station lost nine in
ten (docs/lab/DEBRIDGE-CONVERSION-BRIEF.md §non-matrix guest). So a typing claim
made with the acking mode is not evidence; use `--type`.

Exit 0 only when every verb was acknowledged OK. `EV ` lines are asynchronous
events, never acks, and are printed but not counted.
"""

import socket
import sys

# Printable ASCII -> (KeyCode name, needs Shift). Only what a bring-up script
# types; the station's real map is streamhost/stations/indyr4400/indy.keymap.
_UNSHIFTED = {
    " ": "Space",
    "\n": "Enter",
    "\t": "Tab",
    "-": "Minus",
    "=": "Equal",
    "[": "BracketLeft",
    "]": "BracketRight",
    "\\": "Backslash",
    ";": "Semicolon",
    "'": "Quote",
    ",": "Comma",
    ".": "Period",
    "/": "Slash",
    "`": "Backquote",
}
_SHIFTED = {
    "_": "Minus",
    "+": "Equal",
    "{": "BracketLeft",
    "}": "BracketRight",
    "|": "Backslash",
    ":": "Semicolon",
    '"': "Quote",
    "<": "Comma",
    ">": "Period",
    "?": "Slash",
    "~": "Backquote",
    "!": "Digit1",
    "@": "Digit2",
    "#": "Digit3",
    "$": "Digit4",
    "%": "Digit5",
    "^": "Digit6",
    "&": "Digit7",
    "*": "Digit8",
    "(": "Digit9",
    ")": "Digit0",
}


def key_for(ch):
    """(KeyCode name, shifted) for one character, or None."""
    if ch.isalpha() and ch.isascii():
        return ("Key" + ch.upper(), ch.isupper())
    if ch.isdigit():
        return ("Digit" + ch, False)
    if ch in _UNSHIFTED:
        return (_UNSHIFTED[ch], False)
    if ch in _SHIFTED:
        return (_SHIFTED[ch], True)
    return None


def connect(path, timeout=60.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(path)
    f = s.makefile("rwb", buffering=0)
    hello = f.readline().decode().strip()
    if not hello.startswith("HELLO mamectl/1 "):
        sys.exit(f"not a mamectl/1 socket: {hello!r}")
    print(hello)
    return f


def read_ack(f, want):
    """Return the ack line for `want`, printing D data and EV events."""
    while True:
        line = f.readline().decode().rstrip("\n")
        if not line:
            sys.exit("EOF before ack")
        if line.startswith("EV "):
            print(" ", line)
            continue
        tok = line.split(" ", 2)
        if tok[0] != str(want):
            continue
        if tok[1] == "D":
            print("   D", tok[2] if len(tok) > 2 else "")
            continue
        return line


def do_verbs(f, verbs):
    bad = 0
    for n, v in enumerate(verbs, start=1):
        f.write(f"{n} {v}\n".encode())
        line = read_ack(f, n)
        print(f"{v} -> {line.split(' ', 1)[1]}")
        bad += 0 if " OK" in line else 1
    return bad


def do_type(f, text):
    """PIPELINED: no ack is read between edges. This is the browser's shape."""
    seq = 0
    for ch in text:
        k = key_for(ch)
        if k is None:
            sys.exit(f"no key for {ch!r}")
        name, shift = k
        edges = []
        if shift:
            edges.append("KEY 1 kbd ShiftLeft")
        edges += [f"KEY 1 kbd {name}", f"KEY 0 kbd {name}"]
        if shift:
            edges.append("KEY 0 kbd ShiftLeft")
        for e in edges:
            seq += 1
            f.write(f"{seq} {e}\n".encode())
    bad = 0
    got = 0
    while got < seq:
        line = f.readline().decode().rstrip("\n")
        if line.startswith("EV "):
            continue
        tok = line.split(" ", 2)
        if not tok[0].isdigit():
            continue
        got += 1
        if tok[1] != "OK":
            bad += 1
            print(" ", line)
    print(f"typed {len(text)} char(s) as {seq} edge(s), pipelined at zero spacing; {bad} not OK")
    return bad


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    f = connect(path)
    if sys.argv[2] == "--type":
        return 1 if do_type(f, " ".join(sys.argv[3:])) else 0
    return 1 if do_verbs(f, sys.argv[2:]) else 0


if __name__ == "__main__":
    sys.exit(main())

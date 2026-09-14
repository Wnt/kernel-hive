#!/usr/bin/env python3
"""station-drive.py — drive a LIVE station's pointer and keyboard without stopping it.

WHY THIS EXISTS. Every absolute-pointer backend (`ramabs`, `mgactl`, `artistctl`)
reaches its guest over `ptr.sock`, a QEMU *chardev* owned by the guest device and
single-client BY DESIGN — each launcher says so: "SINGLE INJECTOR (BINDING)".
While `streamhost@<x>` runs it holds that one connection, and a second `connect()`
does not fail, it HANGS with no HELLO. So curating a scene, measuring a pointer or
debugging input used to mean `systemctl stop streamhost@<x>`, re-running
`qemu-streamhost.sh` by hand on the same sockets, driving, recapturing, and
starting the unit again — the exhibit off the air throughout, and a hand-rolled
launcher running next to a live golden.

WHAT IT DOES INSTEAD. It does not take a second connection to the guest. It talks
to the DAEMON, which stays the single injector, over the root-only drive ingress
(`streamhost/src/drive_ingress.rs`) and feeds the very same input pipeline the
browser feeds — so abs->rel bridging, `cseq` ordering, key pacing and the router
all still apply, and there is no second way for a record to mean something.

THE LEASE. Nothing is injected until the daemon grants an expiring, auditable,
one-at-a-time drive lease. You must say who you are (`--holder`, defaulting to
`$KH_SESSION`) and why (`--reason`). A second driver is refused and told who
holds it. The lease expires on its own: an agent that dies mid-drive does not
leave a live exhibit held. `--who` reads the lease without taking one.

RUNS ON THE BOX (the socket is root-only under /run — rule 2's one door):

    ssh lab 'python3 /data/vms/sandbox/<x>/repo/scripts/dev/station-drive.py os213 \\
             --reason "curate the scene" -- move 400 300 click 400 300'

Verbs (consumed left to right after `--`):
    move X Y              absolute move
    click X Y [BTN]       move + press + release at that point (BTN 0=L 1=M 2=R)
    dblclick X Y [BTN]    two clicks inside the guest's double-click window
    down X Y [BTN]        press and hold at a point      (up X Y [BTN] releases)
    wheel DY              wheel up (+) / down (-) notches
    key NAME[+NAME...]    one chord by name: enter, esc, f1, ctrl+alt+del, a, 1
    type TEXT             US-ASCII text, paced
    pause MS              inter-event pacing ONLY. Never use it to wait for the
                          guest — that is fb-wait.py's job (rule 14).

The guest's REACTION is proved with the framebuffer, never from this tool's exit
code: it reports what it sent, which is not evidence anything happened.
See docs/lab/INPUT-DEBUGGING.md.
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

MAGIC = b"OSGDRV1"
DEFAULT_DIR = "/run/osgallery-drive"

# XT set 1 make codes — the `u16 qemu_keycode` the daemon's record wire takes
# (streamhost/src/input.rs, type=3). The browser sends these same numbers, so a
# key driven here travels the identical path a visitor's key travels.
XT = {
    "esc": 0x01,
    "1": 0x02,
    "2": 0x03,
    "3": 0x04,
    "4": 0x05,
    "5": 0x06,
    "6": 0x07,
    "7": 0x08,
    "8": 0x09,
    "9": 0x0A,
    "0": 0x0B,
    "minus": 0x0C,
    "equal": 0x0D,
    "backspace": 0x0E,
    "tab": 0x0F,
    "q": 0x10,
    "w": 0x11,
    "e": 0x12,
    "r": 0x13,
    "t": 0x14,
    "y": 0x15,
    "u": 0x16,
    "i": 0x17,
    "o": 0x18,
    "p": 0x19,
    "bracketleft": 0x1A,
    "bracketright": 0x1B,
    "enter": 0x1C,
    "ctrl": 0x1D,
    "a": 0x1E,
    "s": 0x1F,
    "d": 0x20,
    "f": 0x21,
    "g": 0x22,
    "h": 0x23,
    "j": 0x24,
    "k": 0x25,
    "l": 0x26,
    "semicolon": 0x27,
    "apostrophe": 0x28,
    "grave": 0x29,
    "shift": 0x2A,
    "backslash": 0x2B,
    "z": 0x2C,
    "x": 0x2D,
    "c": 0x2E,
    "v": 0x2F,
    "b": 0x30,
    "n": 0x31,
    "m": 0x32,
    "comma": 0x33,
    "dot": 0x34,
    "slash": 0x35,
    "rshift": 0x36,
    "alt": 0x38,
    "space": 0x39,
    "capslock": 0x3A,
    "f1": 0x3B,
    "f2": 0x3C,
    "f3": 0x3D,
    "f4": 0x3E,
    "f5": 0x3F,
    "f6": 0x40,
    "f7": 0x41,
    "f8": 0x42,
    "f9": 0x43,
    "f10": 0x44,
    "f11": 0x57,
    "f12": 0x58,
    "home": 0x47,
    "up": 0x48,
    "pgup": 0x49,
    "left": 0x4B,
    "right": 0x4D,
    "end": 0x4F,
    "down": 0x50,
    "pgdn": 0x51,
    "insert": 0x52,
    "delete": 0x53,
}
XT["ret"] = XT["enter"]
XT["spc"] = XT["space"]
XT["del"] = XT["delete"]

PLAIN = {
    " ": "space",
    "\n": "enter",
    "\t": "tab",
    "-": "minus",
    "=": "equal",
    "[": "bracketleft",
    "]": "bracketright",
    "\\": "backslash",
    ";": "semicolon",
    "'": "apostrophe",
    "`": "grave",
    ",": "comma",
    ".": "dot",
    "/": "slash",
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
    "{": "bracketleft",
    "}": "bracketright",
    "|": "backslash",
    ":": "semicolon",
    '"': "apostrophe",
    "~": "grave",
    "<": "comma",
    ">": "dot",
    "?": "slash",
}


def chord_for(ch):
    """The (modifiers, key) chord that types one ASCII character, or None."""
    if ch in PLAIN:
        return [], PLAIN[ch]
    if ch in SHIFTED:
        return ["shift"], SHIFTED[ch]
    if ch.isupper():
        return ["shift"], ch.lower()
    if ch.lower() in XT:
        return [], ch.lower()
    return None


class Drive:
    """One drive lease, and the records sent under it.

    `cseq` is the monotonic client stamp the daemon's ordering gate reads: a move
    older than what has already been applied is DROPPED rather than rewinding the
    cursor under a held button (input.rs). We own it, so we must keep it moving.
    """

    def __init__(self, sock, hold_ms, gap_ms):
        self.s = sock
        self.cseq = 1
        self.hold = hold_ms / 1000.0
        self.gap = gap_ms / 1000.0
        self.sent = 0

    def _send(self, rec):
        # A broken pipe here means the DAEMON dropped us, and the overwhelmingly
        # likely reason is that the lease deadline passed — it is enforced on the
        # daemon side, not by this client's manners. Say so instead of dying in a
        # traceback that reads like a bug in the wire format.
        try:
            self.s.sendall(struct.pack("<I", len(rec)) + rec)
        except (BrokenPipeError, ConnectionResetError):
            raise SystemExit(
                f"station-drive: the daemon closed the connection after {self.sent} "
                "record(s) — the drive lease almost certainly expired. Re-take it "
                "with a longer --ttl (max 900s)."
            ) from None
        self.sent += 1

    def _next(self):
        self.cseq += 1
        return self.cseq

    def move(self, x, y):
        self._send(struct.pack("<BHHI", 1, x, y, self._next()))

    def button(self, btn, down, x, y):
        self._send(struct.pack("<BBBHHI", 2, btn, 1 if down else 0, x, y, self._next()))

    def key(self, code, down):
        self._send(struct.pack("<BBH", 3, 1 if down else 0, code))

    def wheel(self, dy):
        self._send(struct.pack("<Bhh", 5, 0, dy))

    def click(self, x, y, btn=0):
        self.move(x, y)
        time.sleep(self.gap)
        self.button(btn, True, x, y)
        time.sleep(self.hold)
        self.button(btn, False, x, y)

    def chord(self, names):
        """Press every key in order, release in reverse — a real chord, not a burst.

        The hold and the RELEASE->PRESS gap are both honoured: an emulator samples
        its keyboard once per emulated frame, so a chord sent with no gap arrives
        as one continuous press and the second key never registers (measured on
        mpf2: gap 0 ms -> 0/16 keys landed, 16 ms -> 16/16).
        """
        codes = []
        for n in names:
            if n not in XT:
                raise SystemExit(f"station-drive: unknown key name {n!r}")
            codes.append(XT[n])
        for c in codes:
            self.key(c, True)
            time.sleep(self.gap)
        time.sleep(self.hold)
        for c in reversed(codes):
            self.key(c, False)
            time.sleep(self.gap)

    def type_text(self, text):
        for ch in text:
            c = chord_for(ch)
            if c is None:
                raise SystemExit(f"station-drive: cannot type {ch!r} on a US layout")
            mods, key = c
            self.chord(mods + [key])


def sock_path(tile, directory):
    return os.path.join(directory, f"drive-{tile}.sock")


def lease_file(tile, directory):
    return os.path.join(directory, f"drive-{tile}.lease.json")


def read_line(s):
    out = bytearray()
    while True:
        b = s.recv(1)
        if not b:
            raise SystemExit("station-drive: daemon closed before answering")
        if b == b"\n":
            return out.decode("utf-8", "replace")
        out += b


def run_verbs(d, verbs):
    i = 0

    def num(label):
        nonlocal i
        if i >= len(verbs):
            raise SystemExit(f"station-drive: {label} expects a number")
        v = verbs[i]
        i += 1
        return int(v)

    def maybe_btn():
        nonlocal i
        if i < len(verbs) and verbs[i].isdigit() and len(verbs[i]) == 1:
            v = int(verbs[i])
            if v <= 2:
                i += 1
                return v
        return 0

    while i < len(verbs):
        v = verbs[i]
        i += 1
        if v == "move":
            d.move(num("move x"), num("move y"))
        elif v in ("click", "dblclick", "down", "up"):
            x, y = num(f"{v} x"), num(f"{v} y")
            btn = maybe_btn()
            if v == "click":
                d.click(x, y, btn)
            elif v == "dblclick":
                d.click(x, y, btn)
                time.sleep(0.08)
                d.click(x, y, btn)
            elif v == "down":
                d.move(x, y)
                time.sleep(d.gap)
                d.button(btn, True, x, y)
            else:
                d.button(btn, False, x, y)
        elif v == "wheel":
            d.wheel(num("wheel dy"))
        elif v == "key":
            if i >= len(verbs):
                raise SystemExit("station-drive: key expects a chord")
            d.chord(verbs[i].split("+"))
            i += 1
        elif v == "type":
            if i >= len(verbs):
                raise SystemExit("station-drive: type expects text")
            d.type_text(verbs[i])
            i += 1
        elif v == "pause":
            time.sleep(num("pause ms") / 1000.0)
        else:
            raise SystemExit(f"station-drive: unknown verb {v!r}")


def main():
    ap = argparse.ArgumentParser(description="drive a live station without stopping it")
    ap.add_argument("station")
    ap.add_argument(
        "--holder",
        default=os.environ.get("KH_SESSION", ""),
        help="who is driving (default $KH_SESSION) — recorded in the lease",
    )
    ap.add_argument("--reason", default="", help="why — recorded in the lease")
    ap.add_argument("--ttl", type=int, default=300, help="seconds; the daemon clamps it (max 900) and enforces it")
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--hold-ms", type=int, default=40)
    ap.add_argument("--gap-ms", type=int, default=40)
    ap.add_argument("--who", action="store_true", help="print the current lease and exit without taking one")
    ap.add_argument("verbs", nargs="*")
    a = ap.parse_args()

    if a.who:
        try:
            with open(lease_file(a.station, a.dir)) as fh:
                print(fh.read().strip())
        except FileNotFoundError:
            print(f"{a.station}: nobody is driving")
        return 0

    if not a.holder.strip():
        print("station-drive: --holder is required (or set KH_SESSION)", file=sys.stderr)
        return 2

    path = sock_path(a.station, a.dir)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(path)
    except OSError as e:
        print(f"station-drive: cannot reach {path}: {e}", file=sys.stderr)
        print("  the daemon may predate the drive ingress, or be stopped", file=sys.stderr)
        return 3
    s.sendall(MAGIC)
    s.sendall(json.dumps({"holder": a.holder, "reason": a.reason, "ttl": a.ttl}).encode() + b"\n")
    reply = json.loads(read_line(s))
    if not reply.get("ok"):
        print(f"station-drive: REFUSED — {reply.get('error')}", file=sys.stderr)
        if reply.get("holder"):
            print(f"  held by {reply['holder']} until unix {reply.get('expires_unix')}", file=sys.stderr)
        return 4
    left = reply["expires_unix"] - reply["since_unix"]
    print(f"lease granted: {a.station} holder={a.holder} ttl={left}s", file=sys.stderr)

    d = Drive(s, a.hold_ms, a.gap_ms)
    try:
        run_verbs(d, a.verbs)
        # Records are queued into the daemon; let it drain before the close that
        # releases the lease, or the last click can be dropped on the floor.
        time.sleep(0.3)
    finally:
        s.close()
    print(
        f"sent {d.sent} record(s); lease released. PROVE IT ON THE FRAMEBUFFER — this line is not evidence.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Derive a tile's `keyboard.charMap` from a MAME driver's keyboard matrix.

WHY THIS EXISTS
---------------
The SPA types into a guest with `typeText()`, which maps ASCII to US set1
scancodes -- it presses the key a US PC keyboard would press. A guest whose
keyboard is laid out differently then receives a different character, silently.

The MPF-II cost a session's worth of confusion this way. Its 8x8 matrix puts
'=' on Shift+O and '-' on Shift+I -- a PC's own '=' and '-' keys do not exist in
it at all, so those characters simply VANISHED -- and its shifted number row is
offset by one (Shift+8/9/0 give "( ) *" where a PC gives "* ( )"), so every
bracket in a BASIC listing landed one key over. The symptom reads like dropped
keystrokes, which sends you hunting for a timing bug that is not there.

The answer is already in the driver. MAME declares each matrix key as a
PORT_CODE (the HOST key that drives it) plus one or two PORT_CHARs (what the
GUEST produces unshifted and shifted). Comparing that against a US layout gives
the translation table exactly, in seconds, instead of by inference from a
corrupted screenshot.

USAGE
-----
    scripts/dev/mame-keymap.py tk2000            # fetch the driver by machine
    scripts/dev/mame-keymap.py --file tk2000.cpp # or read a local copy
    scripts/dev/mame-keymap.py tk2000 --json     # paste-ready registry block

Paste the map as the tile's top-level `keyboard.charMap` in
registry/tiles/<id>.json AND mirror it into `runtime.tileEnv.SH_KEY_MAP` as
comma-separated `guest:host` pairs (labctl drives QMP directly and cannot read
the registry; `validate_keyboard_env` fails the build if the two drift). Then
run `make tile-registry-generate`. Characters the guest agrees with a PC about
are omitted -- the map should be as small as the machine's actual differences.

ONE MATRIX AT A TIME. Some driver files declare several INPUT_PORTS_START
blocks for machine variants that share a source file (bbc_kbd.cpp carries the
Model B, the Master, the Compact and more), and this tool reads whatever it is
given. Feeding it the whole file merges incompatible matrices and prints
nonsense; slice out the one port block your machine uses first, e.g.
`sed -n '36,157p' bbc_kbd.cpp > modelb.cpp`, then pass that with --file.

The mapping is `guest character` -> `host character to send`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request

# A US keyboard, as `typeText()` assumes: KEYCODE -> (unshifted, shifted).
US_LAYOUT: dict[str, tuple[str, str]] = {
    **{k: (k.lower(), k) for k in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"},
    "1": ("1", "!"),
    "2": ("2", "@"),
    "3": ("3", "#"),
    "4": ("4", "$"),
    "5": ("5", "%"),
    "6": ("6", "^"),
    "7": ("7", "&"),
    "8": ("8", "*"),
    "9": ("9", "("),
    "0": ("0", ")"),
    "MINUS": ("-", "_"),
    "EQUALS": ("=", "+"),
    "OPENBRACE": ("[", "{"),
    "CLOSEBRACE": ("]", "}"),
    "BACKSLASH": ("\\", "|"),
    "COLON": (";", ":"),
    "QUOTE": ("'", '"'),
    "TILDE": ("`", "~"),
    "COMMA": (",", "<"),
    "STOP": (".", ">"),
    "SLASH": ("/", "?"),
    "SPACE": (" ", " "),
}

KEY_RE = re.compile(
    r"PORT_CODE\(KEYCODE_(?P<code>[A-Z0-9_]+)\)"
    r"(?P<chars>(?:\s*PORT_CHAR\((?:'(?:\\?.)'|[A-Z_]+\([^)]*\)|[^)]*)\))*)"
)
CHAR_RE = re.compile(r"PORT_CHAR\('(\\?.)'\)")

MAME_RAW = "https://raw.githubusercontent.com/mamedev/mame/master/src/mame/"
# Machines whose driver file is not guessable from the machine name.
DRIVER_HINTS = {"tk2000": "apple/tk2000.cpp", "mpf2": "apple/tk2000.cpp"}


def fetch_driver(machine: str) -> str:
    path = DRIVER_HINTS.get(machine)
    if not path:
        sys.exit(
            f"unknown driver path for '{machine}'. Pass --file with a local copy, or add it\n"
            f"to DRIVER_HINTS (find it with: grep -rl 'COMP(.*{machine}' src/mame)."
        )
    with urllib.request.urlopen(MAME_RAW + path, timeout=30) as r:  # noqa: S310
        return r.read().decode("utf-8", "replace")


def unescape(c: str) -> str:
    return {"\\'": "'", '\\"': '"', "\\\\": "\\"}.get(c, c)


def derive(source: str) -> tuple[dict[str, str], list[tuple[str, str, str]]]:
    """Return (keyMap, rows) where rows are (keycode, unshifted, shifted)."""
    keymap: dict[str, str] = {}
    rows: list[tuple[str, str, str]] = []
    for m in KEY_RE.finditer(source):
        code = m.group("code")
        chars = [unescape(c) for c in CHAR_RE.findall(m.group("chars"))]
        if not chars or code not in US_LAYOUT:
            continue
        host_un, host_sh = US_LAYOUT[code]
        guest_un = chars[0]
        guest_sh = chars[1] if len(chars) > 1 else ""
        rows.append((code, guest_un, guest_sh))
        # To type `guest_un`, press the key a US keyboard labels `host_un`.
        if guest_un and guest_un != host_un and guest_un not in keymap:
            keymap[guest_un] = host_un
        if guest_sh and guest_sh != host_sh and guest_sh not in keymap:
            keymap[guest_sh] = host_sh
    return keymap, rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("machine", nargs="?", help="MAME machine short name, e.g. tk2000")
    ap.add_argument("--file", help="read a local driver .cpp instead of fetching")
    ap.add_argument("--json", action="store_true", help="print only the charMap JSON")
    args = ap.parse_args()

    if args.file:
        with open(args.file, encoding="utf-8", errors="replace") as fh:
            source = fh.read()
    elif args.machine:
        source = fetch_driver(args.machine)
    else:
        ap.error("give a machine name or --file")

    keymap, rows = derive(source)

    if args.json:
        print(json.dumps({"charMap": keymap}, indent=2, ensure_ascii=False))
        return 0

    if not rows:
        print("no PORT_CODE/PORT_CHAR keyboard matrix found in this driver.", file=sys.stderr)
        return 2

    print(f"{'HOST KEY':14} {'GUEST':8} {'GUEST+SHIFT'}")
    for code, un, sh in rows:
        host_un, host_sh = US_LAYOUT[code]
        flag = "  <-- differs" if (un != host_un or (sh and sh != host_sh)) else ""
        print(f"{code:14} {un!r:8} {sh!r:8}{flag}")

    print()
    if keymap:
        print(f"{len(keymap)} character(s) need translating. Add as the tile's keyboard.charMap:")
        print(json.dumps({"charMap": keymap}, indent=2, ensure_ascii=False))
    else:
        print("No translation needed: this guest agrees with a US keyboard.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

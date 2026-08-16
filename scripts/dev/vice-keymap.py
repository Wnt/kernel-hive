#!/usr/bin/env python3
"""Generate the ONE browser-scancode -> X11-keysym table every VICE station uses.

The VICE wave of the de-bridging campaign (docs/lab/DEBRIDGE-HANDOVER.md,
docs/lab/research/vice-input-plane.md) deliberately does NOT do what the MAME
wave did. MAME's `KEY` verb names a matrix CELL, so every station needed its own
map dumped out of its own machine (scripts/dev/mame-keymap.py). VICE's `vicectl`
`KEY` verb carries an **X11 keysym**, and VICE resolves keysym -> keyboard
matrix through the machine's own `.vkm` keymap — the same file the bridged
kiosk used. So there is exactly ONE table, shared by all seven stations
(vic20, plus4, pet2001, cbm8032, cbm2, c128, c64), and it describes the HOST
layout, not any Commodore machine:

    XT set1 scancode  ->  (plain keysym, shifted keysym)

The host layout must be applied BEFORE the wire (vice-input-plane.md §2d): the
bridged station produced `@` for the visitor's Shift+2 because X applied the US
layout before VICE saw it. The daemon therefore substitutes the shift level for
character keys and forwards Shift_L/Shift_R as themselves, so `.vkm` entries
flagged MAP_MOD_SHIFT keep working.

SOURCE OF TRUTH — this file is the ONE hand-written home of the table
(repo rule: a generated file is never hand-edited). Its output is
`streamhost/stations/vice-native/us-layout.keysyms`, deployed to each VICE
station as `SH_VICESOCK_KEYMAP`. The scancode VOCABULARY is not invented here:
it is the SPA's own `CODE_TO_SCANCODE` in `spa/src/three/guestQuirks.ts`, and
`--check` fails loudly when the two drift apart.

usage:
    vice-keymap.py                 # write the generated file (default path)
    vice-keymap.py --out -         # to stdout
    vice-keymap.py --check         # byte-compare + SPA-vocabulary parity (CI)

NOT YET IMPLEMENTED, on purpose: validation against a running machine's own
`KEYDUMP` (vice-input-plane.md §5 — "the list the exhibit needs, not every
field the emulator exposes"). The fork's KEYDUMP reply format is not frozen
yet, and guessing a wire format is the failure this pipeline exists to end.
It belongs in this script, as `--validate <ctl.sock>`, the day the fork lands.
"""

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO / "streamhost/stations/vice-native/us-layout.keysyms"
SPA_QUIRKS = REPO / "spa/src/three/guestQuirks.ts"

# X11 keysym VALUES, from <X11/keysymdef.h>. Baked in rather than parsed off the
# host: this table must generate identically on a box with no X11 headers, and
# the values are frozen by the protocol. Latin-1 keysyms are their own code
# point (0x20..0xff), so only the named function keys need listing.
NAMED: dict[str, int] = {
    "BackSpace": 0xFF08,
    "Tab": 0xFF09,
    "Return": 0xFF0D,
    "Escape": 0xFF1B,
    "Delete": 0xFFFF,
    "Home": 0xFF50,
    "Left": 0xFF51,
    "Up": 0xFF52,
    "Right": 0xFF53,
    "Down": 0xFF54,
    "Prior": 0xFF55,
    "Next": 0xFF56,
    "End": 0xFF57,
    "Insert": 0xFF63,
    "Menu": 0xFF67,
    "Num_Lock": 0xFF7F,
    "Scroll_Lock": 0xFF14,
    "Print": 0xFF61,
    "Caps_Lock": 0xFFE5,
    "Shift_L": 0xFFE1,
    "Shift_R": 0xFFE2,
    "Control_L": 0xFFE3,
    "Control_R": 0xFFE4,
    "Alt_L": 0xFFE9,
    "Alt_R": 0xFFEA,
    "Super_L": 0xFFEB,
    "Super_R": 0xFFEC,
    "KP_Enter": 0xFF8D,
    "KP_Multiply": 0xFFAA,
    "KP_Add": 0xFFAB,
    "KP_Subtract": 0xFFAD,
    "KP_Decimal": 0xFFAE,
    "KP_Divide": 0xFFAF,
    "KP_0": 0xFFB0,
    "KP_1": 0xFFB1,
    "KP_2": 0xFFB2,
    "KP_3": 0xFFB3,
    "KP_4": 0xFFB4,
    "KP_5": 0xFFB5,
    "KP_6": 0xFFB6,
    "KP_7": 0xFFB7,
    "KP_8": 0xFFB8,
    "KP_9": 0xFFB9,
    "F1": 0xFFBE,
    "F2": 0xFFBF,
    "F3": 0xFFC0,
    "F4": 0xFFC1,
    "F5": 0xFFC2,
    "F6": 0xFFC3,
    "F7": 0xFFC4,
    "F8": 0xFFC5,
    "F9": 0xFFC6,
    "F10": 0xFFC7,
    "F11": 0xFFC8,
    "F12": 0xFFC9,
}

# Latin-1 keysym NAMES for the printable characters this layout uses. The value
# is the character's own code point; the name is what a `.vkm` line calls it,
# and is carried in the generated file's comment column so the table can be read
# against `data/*/gtk3_sym.vkm` by eye.
LATIN1: dict[str, str] = {
    " ": "space",
    "!": "exclam",
    '"': "quotedbl",
    "#": "numbersign",
    "$": "dollar",
    "%": "percent",
    "&": "ampersand",
    "'": "apostrophe",
    "(": "parenleft",
    ")": "parenright",
    "*": "asterisk",
    "+": "plus",
    ",": "comma",
    "-": "minus",
    ".": "period",
    "/": "slash",
    ":": "colon",
    ";": "semicolon",
    "<": "less",
    "=": "equal",
    ">": "greater",
    "?": "question",
    "@": "at",
    "[": "bracketleft",
    "\\": "backslash",
    "]": "bracketright",
    "^": "asciicircum",
    "_": "underscore",
    "`": "grave",
    "{": "braceleft",
    "|": "bar",
    "}": "braceright",
    "~": "asciitilde",
}

EXT = 0xE000  # the SPA's extended-key marker, identical to QEMU's convention

# THE TABLE. XT set1 scancode -> (plain, shifted), each side either a character
# (Latin-1 keysym) or a NAMED keysym. US layout, because that is the layout the
# bridged kiosks' X server applied before VICE saw a key — reproducing their
# character behaviour is the whole point of this wave.
US_LAYOUT: list[tuple[int, str, str]] = [
    (0x01, "Escape", "Escape"),
    (0x02, "1", "!"),
    (0x03, "2", "@"),
    (0x04, "3", "#"),
    (0x05, "4", "$"),
    (0x06, "5", "%"),
    (0x07, "6", "^"),
    (0x08, "7", "&"),
    (0x09, "8", "*"),
    (0x0A, "9", "("),
    (0x0B, "0", ")"),
    (0x0C, "-", "_"),
    (0x0D, "=", "+"),
    (0x0E, "BackSpace", "BackSpace"),
    (0x0F, "Tab", "Tab"),
    (0x10, "q", "Q"),
    (0x11, "w", "W"),
    (0x12, "e", "E"),
    (0x13, "r", "R"),
    (0x14, "t", "T"),
    (0x15, "y", "Y"),
    (0x16, "u", "U"),
    (0x17, "i", "I"),
    (0x18, "o", "O"),
    (0x19, "p", "P"),
    (0x1A, "[", "{"),
    (0x1B, "]", "}"),
    (0x1C, "Return", "Return"),
    (0x1D, "Control_L", "Control_L"),
    (0x1E, "a", "A"),
    (0x1F, "s", "S"),
    (0x20, "d", "D"),
    (0x21, "f", "F"),
    (0x22, "g", "G"),
    (0x23, "h", "H"),
    (0x24, "j", "J"),
    (0x25, "k", "K"),
    (0x26, "l", "L"),
    (0x27, ";", ":"),
    (0x28, "'", '"'),
    (0x29, "`", "~"),
    (0x2A, "Shift_L", "Shift_L"),
    (0x2B, "\\", "|"),
    (0x2C, "z", "Z"),
    (0x2D, "x", "X"),
    (0x2E, "c", "C"),
    (0x2F, "v", "V"),
    (0x30, "b", "B"),
    (0x31, "n", "N"),
    (0x32, "m", "M"),
    (0x33, ",", "<"),
    (0x34, ".", ">"),
    (0x35, "/", "?"),
    (0x36, "Shift_R", "Shift_R"),
    (0x37, "KP_Multiply", "KP_Multiply"),
    (0x38, "Alt_L", "Alt_L"),
    (0x39, " ", " "),
    (0x3A, "Caps_Lock", "Caps_Lock"),
    (0x3B, "F1", "F1"),
    (0x3C, "F2", "F2"),
    (0x3D, "F3", "F3"),
    (0x3E, "F4", "F4"),
    (0x3F, "F5", "F5"),
    (0x40, "F6", "F6"),
    (0x41, "F7", "F7"),
    (0x42, "F8", "F8"),
    (0x43, "F9", "F9"),
    (0x44, "F10", "F10"),
    (0x45, "Num_Lock", "Num_Lock"),
    (0x46, "Scroll_Lock", "Scroll_Lock"),
    (0x47, "KP_7", "KP_7"),
    (0x48, "KP_8", "KP_8"),
    (0x49, "KP_9", "KP_9"),
    (0x4A, "KP_Subtract", "KP_Subtract"),
    (0x4B, "KP_4", "KP_4"),
    (0x4C, "KP_5", "KP_5"),
    (0x4D, "KP_6", "KP_6"),
    (0x4E, "KP_Add", "KP_Add"),
    (0x4F, "KP_1", "KP_1"),
    (0x50, "KP_2", "KP_2"),
    (0x51, "KP_3", "KP_3"),
    (0x52, "KP_0", "KP_0"),
    (0x53, "KP_Decimal", "KP_Decimal"),
    (0x57, "F11", "F11"),
    (0x58, "F12", "F12"),
    (EXT | 0x1C, "KP_Enter", "KP_Enter"),
    (EXT | 0x1D, "Control_R", "Control_R"),
    (EXT | 0x35, "KP_Divide", "KP_Divide"),
    (EXT | 0x37, "Print", "Print"),
    (EXT | 0x38, "Alt_R", "Alt_R"),
    (EXT | 0x47, "Home", "Home"),
    (EXT | 0x48, "Up", "Up"),
    (EXT | 0x49, "Prior", "Prior"),
    (EXT | 0x4B, "Left", "Left"),
    (EXT | 0x4D, "Right", "Right"),
    (EXT | 0x4F, "End", "End"),
    (EXT | 0x50, "Down", "Down"),
    (EXT | 0x51, "Next", "Next"),
    (EXT | 0x52, "Insert", "Insert"),
    (EXT | 0x53, "Delete", "Delete"),
    (EXT | 0x5B, "Super_L", "Super_L"),
    (EXT | 0x5C, "Super_R", "Super_R"),
    (EXT | 0x5D, "Menu", "Menu"),
]


def resolve(token: str) -> tuple[int, str]:
    """One US_LAYOUT token -> (keysym value, keysym name)."""
    if token in NAMED:
        return NAMED[token], token
    if len(token) == 1 and 0x20 <= ord(token) <= 0xFF:
        name = LATIN1.get(token)
        if name is None:
            if not token.isalnum():
                sys.exit(f"no Latin-1 keysym name for {token!r} — add it to LATIN1")
            name = token
        return ord(token), name
    sys.exit(f"unknown keysym token {token!r} — add it to NAMED")


def spa_vocabulary() -> set[int]:
    """The scancodes the SPA actually puts on the wire (CODE_TO_SCANCODE).

    Read, not assumed: `spa/src/three/guestQuirks.ts` is the browser side's ONE
    hand-written home for the vocabulary, and `EXT | 0x..` there is the same
    0xE0xx encoding this table uses.
    """
    text = SPA_QUIRKS.read_text()
    body = text.split("export const CODE_TO_SCANCODE", 1)
    if len(body) != 2:
        sys.exit(f"{SPA_QUIRKS}: CODE_TO_SCANCODE not found")
    body = body[1].split("};", 1)[0]
    codes: set[int] = set()
    for plain in re.finditer(r":\s*(0x[0-9a-fA-F]+)\s*[,}]", body):
        codes.add(int(plain.group(1), 16))
    for ext in re.finditer(r":\s*EXT\s*\|\s*(0x[0-9a-fA-F]+)", body):
        codes.add(EXT | int(ext.group(1), 16))
    return codes


def render() -> str:
    seen: set[int] = set()
    rows: list[str] = []
    for code, plain, shifted in US_LAYOUT:
        if code in seen:
            sys.exit(f"duplicate scancode {code:#06x} in US_LAYOUT")
        seen.add(code)
        pv, pn = resolve(plain)
        sv, sn = resolve(shifted)
        legend = pn if pn == sn else f"{pn} {sn}"
        rows.append(f"{code:#06x}\t{pv:#06x}\t{sv:#06x}\t# {legend}")
    head = [
        "# SH_VICESOCK_KEYMAP — GENERATED by scripts/dev/vice-keymap.py. Do not edit.",
        "# One shared table for every VICE station: browser XT set1 scancode ->",
        "# (plain X11 keysym, shifted X11 keysym), US layout. VICE resolves the",
        "# keysym to the machine's own matrix through its .vkm keymap, so there is",
        "# nothing per-station here. Columns: scancode, plain, shifted, # legend.",
        f"# keys: {len(rows)}",
    ]
    return "\n".join(head + rows) + "\n"


def check(text: str, out: pathlib.Path) -> int:
    rc = 0
    missing = sorted(spa_vocabulary() - {code for code, _, _ in US_LAYOUT})
    if missing:
        rc = 1
        print(
            "DRIFT: the SPA sends scancodes this table has no keysym for: " + ", ".join(f"{c:#06x}" for c in missing),
            file=sys.stderr,
        )
    if not out.exists():
        print(f"DRIFT: {out} is missing — run scripts/dev/vice-keymap.py", file=sys.stderr)
        return 1
    if out.read_text() != text:
        print(
            f"DRIFT: {out} is stale — run scripts/dev/vice-keymap.py and commit",
            file=sys.stderr,
        )
        rc = 1
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="output path, or - for stdout")
    ap.add_argument("--check", action="store_true", help="verify parity, write nothing")
    args = ap.parse_args()

    text = render()
    if args.check:
        return check(text, pathlib.Path(args.out))
    if args.out == "-":
        sys.stdout.write(text)
        return 0
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"wrote {out}: {len(US_LAYOUT)} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())

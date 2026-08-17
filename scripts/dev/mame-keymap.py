#!/usr/bin/env python3
"""Generate an SH_MAMESOCK_KEYMAP file from a running MAME's own keyboard.

Phase 0 of the de-bridging conversion campaign
(docs/lab/DEBRIDGE-CONVERSION-BRIEF.md): the map is DUMPED from the machine
via the ctlsock module's KEYDUMP verb — the same rule the IRIX matrix was
built under — never hand-guessed. Matching is deliberately conservative,
in two exact tiers:

  1. DEFAULT-ASSIGNMENT TOKEN (KEYDUMP's third column, when the module is
     new enough to emit it): a field whose PORT_CODE is KEYCODE_MINUS binds
     to XT 0x0C, full stop. PORT_CODE-positional drivers (the CoCo/Dragon
     family) encode the exhibit's real layout there — the Dragon's ':'/'*'
     key IS the key a PC labels '-', and that binding, not the legend, is
     what the kiosk chain the SPA charMaps were calibrated against used.
  2. NAME/ALIAS: exact (case-insensitive) hit on the field's display name,
     for drivers that name their keys but assign no positional code.

Everything that does not match is listed LOUDLY at the end; the
per-tile answer to that list is an --override file, not a looser matcher —
a key that lands on the wrong field is precisely the failure this pipeline
exists to end.

usage:
    mame-keymap.py <ctl.sock> [--tags SUBSTR] [--out FILE] [--override FILE]

  --tags      KEYDUMP port-tag filter (default the verb's own ":kbd:";
              pass ":" to dump every port and let the matcher choose)
  --override  extra/replacement rows in the output format
              (scancode-hex<TAB>port<TAB>field), applied last
  --out       write the keymap here (default stdout)

Run it ON the box, against a tile's running host-native binary.
"""

import argparse
import socket
import sys

# XT set1 canonical names (the UI's wire scancodes), plus the aliases a
# vintage machine's MAME driver plausibly uses for the same physical intent.
# Order matters only for readability; matching is exact per entry.
XT_KEYS: list[tuple[int, list[str]]] = [
    (0x01, ["Esc", "Escape"]),
    (0x02, ["1"]),
    (0x03, ["2"]),
    (0x04, ["3"]),
    (0x05, ["4"]),
    (0x06, ["5"]),
    (0x07, ["6"]),
    (0x08, ["7"]),
    (0x09, ["8"]),
    (0x0A, ["9"]),
    (0x0B, ["0"]),
    (0x0C, ["-", "Minus"]),
    (0x0D, ["=", "Equals"]),
    (0x0E, ["Backspace", "Back Space"]),
    (0x0F, ["Tab"]),
    (0x10, ["Q"]),
    (0x11, ["W"]),
    (0x12, ["E"]),
    (0x13, ["R"]),
    (0x14, ["T"]),
    (0x15, ["Y"]),
    (0x16, ["U"]),
    (0x17, ["I"]),
    (0x18, ["O"]),
    (0x19, ["P"]),
    (0x1A, ["[", "Left Bracket"]),
    (0x1B, ["]", "Right Bracket"]),
    (0x1C, ["Enter", "Return", "New Line"]),
    (0x1D, ["Left Ctrl", "Ctrl", "Control", "CTL"]),
    (0x1E, ["A"]),
    (0x1F, ["S"]),
    (0x20, ["D"]),
    (0x21, ["F"]),
    (0x22, ["G"]),
    (0x23, ["H"]),
    (0x24, ["J"]),
    (0x25, ["K"]),
    (0x26, ["L"]),
    (0x27, [";", "Semicolon"]),
    (0x28, ["'", "Quote", "Apostrophe"]),
    (0x29, ["`", "Tilde", "Backquote"]),
    (0x2A, ["Left Shift", "Shift Left", "Shift"]),
    (0x2B, ["\\", "Backslash"]),
    (0x2C, ["Z"]),
    (0x2D, ["X"]),
    (0x2E, ["C"]),
    (0x2F, ["V"]),
    (0x30, ["B"]),
    (0x31, ["N"]),
    (0x32, ["M"]),
    (0x33, [",", "Comma"]),
    (0x34, [".", "Period", "Full Stop"]),
    (0x35, ["/", "Slash"]),
    (0x36, ["Right Shift", "Shift Right", "Shift"]),
    (0x37, ["Keypad *"]),
    (0x38, ["Left Alt", "Alt", "Alternate"]),
    (0x39, ["Space", "Space Bar", "Spacebar"]),
    (0x3A, ["Caps Lock", "Caps Shift", "Shift Lock"]),
    (0x3B, ["F1"]),
    (0x3C, ["F2"]),
    (0x3D, ["F3"]),
    (0x3E, ["F4"]),
    (0x3F, ["F5"]),
    (0x40, ["F6"]),
    (0x41, ["F7"]),
    (0x42, ["F8"]),
    (0x43, ["F9"]),
    (0x44, ["F10"]),
    (0x47, ["Keypad 7"]),
    (0x48, ["Keypad 8"]),
    (0x49, ["Keypad 9"]),
    (0x4A, ["Keypad -"]),
    (0x4B, ["Keypad 4"]),
    (0x4C, ["Keypad 5"]),
    (0x4D, ["Keypad 6"]),
    (0x4E, ["Keypad +"]),
    (0x4F, ["Keypad 1"]),
    (0x50, ["Keypad 2"]),
    (0x51, ["Keypad 3"]),
    (0x52, ["Keypad 0"]),
    (0x53, ["Keypad ."]),
    (0x57, ["F11"]),
    (0x58, ["F12"]),
    (0xE01C, ["Keypad Enter"]),
    (0xE01D, ["Right Ctrl"]),
    (0xE035, ["Keypad /"]),
    (0xE038, ["Right Alt"]),
    (0xE047, ["Home", "Clr Home", "Home Clr"]),
    (0xE048, ["Cursor Up", "Up", "Up Arrow", "Crsr Up", "\u2191"]),
    (0xE049, ["Page Up"]),
    (0xE04B, ["Cursor Left", "Left", "Left Arrow", "Crsr Left", "\u2190"]),
    (0xE04D, ["Cursor Right", "Right", "Right Arrow", "Crsr Right", "\u2192"]),
    (0xE04F, ["End"]),
    (0xE050, ["Cursor Down", "Down", "Down Arrow", "Crsr Down", "\u2193"]),
    (0xE051, ["Page Down"]),
    (0xE052, ["Insert", "Ins"]),
    (0xE053, ["Delete", "Del"]),
]

# XT scancode -> MAME default-assignment token (tier 1). This is the mechanical
# mirror of MAME's own KEYCODE_* naming: the ';' key is COLON, the '.' key is
# STOP, the "'" key is QUOTE and the '`' key is TILDE. A field whose PORT_CODE
# carries one of these tokens is bound to the XT code a PC keyboard sends from
# that physical position — the same binding the bridge kiosk chain (PS/2 -> X
# -> SDL -> MAME) produced, which is what the SPA charMaps were tuned against.
XT_TOKENS: dict[int, str] = {
    0x01: "KEYCODE_ESC",
    0x02: "KEYCODE_1",
    0x03: "KEYCODE_2",
    0x04: "KEYCODE_3",
    0x05: "KEYCODE_4",
    0x06: "KEYCODE_5",
    0x07: "KEYCODE_6",
    0x08: "KEYCODE_7",
    0x09: "KEYCODE_8",
    0x0A: "KEYCODE_9",
    0x0B: "KEYCODE_0",
    0x0C: "KEYCODE_MINUS",
    0x0D: "KEYCODE_EQUALS",
    0x0E: "KEYCODE_BACKSPACE",
    0x0F: "KEYCODE_TAB",
    0x10: "KEYCODE_Q",
    0x11: "KEYCODE_W",
    0x12: "KEYCODE_E",
    0x13: "KEYCODE_R",
    0x14: "KEYCODE_T",
    0x15: "KEYCODE_Y",
    0x16: "KEYCODE_U",
    0x17: "KEYCODE_I",
    0x18: "KEYCODE_O",
    0x19: "KEYCODE_P",
    0x1A: "KEYCODE_OPENBRACE",
    0x1B: "KEYCODE_CLOSEBRACE",
    0x1C: "KEYCODE_ENTER",
    0x1D: "KEYCODE_LCONTROL",
    0x1E: "KEYCODE_A",
    0x1F: "KEYCODE_S",
    0x20: "KEYCODE_D",
    0x21: "KEYCODE_F",
    0x22: "KEYCODE_G",
    0x23: "KEYCODE_H",
    0x24: "KEYCODE_J",
    0x25: "KEYCODE_K",
    0x26: "KEYCODE_L",
    0x27: "KEYCODE_COLON",
    0x28: "KEYCODE_QUOTE",
    0x29: "KEYCODE_TILDE",
    0x2A: "KEYCODE_LSHIFT",
    0x2B: "KEYCODE_BACKSLASH",
    0x2C: "KEYCODE_Z",
    0x2D: "KEYCODE_X",
    0x2E: "KEYCODE_C",
    0x2F: "KEYCODE_V",
    0x30: "KEYCODE_B",
    0x31: "KEYCODE_N",
    0x32: "KEYCODE_M",
    0x33: "KEYCODE_COMMA",
    0x34: "KEYCODE_STOP",
    0x35: "KEYCODE_SLASH",
    0x36: "KEYCODE_RSHIFT",
    0x37: "KEYCODE_ASTERISK",
    0x38: "KEYCODE_LALT",
    0x39: "KEYCODE_SPACE",
    0x3A: "KEYCODE_CAPSLOCK",
    0x3B: "KEYCODE_F1",
    0x3C: "KEYCODE_F2",
    0x3D: "KEYCODE_F3",
    0x3E: "KEYCODE_F4",
    0x3F: "KEYCODE_F5",
    0x40: "KEYCODE_F6",
    0x41: "KEYCODE_F7",
    0x42: "KEYCODE_F8",
    0x43: "KEYCODE_F9",
    0x44: "KEYCODE_F10",
    0x47: "KEYCODE_7_PAD",
    0x48: "KEYCODE_8_PAD",
    0x49: "KEYCODE_9_PAD",
    0x4A: "KEYCODE_MINUS_PAD",
    0x4B: "KEYCODE_4_PAD",
    0x4C: "KEYCODE_5_PAD",
    0x4D: "KEYCODE_6_PAD",
    0x4E: "KEYCODE_PLUS_PAD",
    0x4F: "KEYCODE_1_PAD",
    0x50: "KEYCODE_2_PAD",
    0x51: "KEYCODE_3_PAD",
    0x52: "KEYCODE_0_PAD",
    0x53: "KEYCODE_DEL_PAD",
    0x57: "KEYCODE_F11",
    0x58: "KEYCODE_F12",
    0xE01C: "KEYCODE_ENTER_PAD",
    0xE01D: "KEYCODE_RCONTROL",
    0xE035: "KEYCODE_SLASH_PAD",
    0xE038: "KEYCODE_RALT",
    0xE047: "KEYCODE_HOME",
    0xE048: "KEYCODE_UP",
    0xE049: "KEYCODE_PGUP",
    0xE04B: "KEYCODE_LEFT",
    0xE04D: "KEYCODE_RIGHT",
    0xE04F: "KEYCODE_END",
    0xE050: "KEYCODE_DOWN",
    0xE051: "KEYCODE_PGDN",
    0xE052: "KEYCODE_INSERT",
    0xE053: "KEYCODE_DEL",
}

# The third KEYDUMP column is only trusted when it looks like an input token;
# a field NAME that happens to contain " | " must never be split as one.
TOKEN_PREFIXES = ("KEYCODE_", "JOYCODE_", "MOUSECODE_", "GUNCODE_")


def keydump(sock_path: str, tags: str) -> list[tuple[str, str, str]]:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(10)
    buf = b""

    def line() -> str:
        nonlocal buf
        while b"\n" not in buf:
            d = s.recv(4096)
            if not d:
                sys.exit("ctl.sock closed mid-dump")
            buf += d
        raw, buf = buf.split(b"\n", 1)
        return raw.decode()

    banner = line()
    if not banner.startswith("HELLO "):
        sys.exit(f"not a ctlsock endpoint: {banner!r}")
    s.sendall(f"1 KEYDUMP {tags}".rstrip().encode() + b"\n")
    rows: list[tuple[str, str, str]] = []
    while True:
        reply = line()
        if reply.startswith("1 D "):
            body = reply[len("1 D ") :]
            port, sep, field = body.partition(" | ")
            if not sep:
                sys.exit(f"unparsable KEYDUMP row: {reply!r}")
            # Newer modules append " | <default-assignment token>"; older ones
            # (and fields with no assignment) emit two columns. Only a tail
            # that LOOKS like a token is split off — see TOKEN_PREFIXES.
            token = ""
            head, sep, tail = field.rpartition(" | ")
            if sep and tail.startswith(TOKEN_PREFIXES):
                field, token = head, tail
            rows.append((port, field, token))
        elif reply.startswith("1 OK "):
            return rows
        elif reply.startswith("1 ERR"):
            sys.exit(f"KEYDUMP refused: {reply!r}")
        # EV broadcasts interleave; ignore them.


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sock")
    ap.add_argument("--tags", default="")
    ap.add_argument("--out")
    ap.add_argument("--override")
    args = ap.parse_args()

    fields = keydump(args.sock, args.tags)
    if not fields:
        sys.exit("KEYDUMP returned no fields — wrong --tags for this machine?")
    by_name: dict[str, list[tuple[str, str]]] = {}
    by_token: dict[str, list[tuple[str, str]]] = {}
    for port, field, token in fields:
        by_name.setdefault(field.strip().upper(), []).append((port, field))
        if token:
            by_token.setdefault(token, []).append((port, field))

    # Dual-legend fields — MAME's `<unshifted>  <shifted>` PORT_NAMEs
    # ("1  !", "; +") — additionally index under their unshifted token. Still
    # exact matching: two tokens only, and the shifted legend must be a single
    # non-alphanumeric glyph, so "Left Shift" can never alias to "Left".
    for port, field, _token in fields:
        toks = field.split()
        if len(toks) == 2 and len(toks[1]) == 1 and not toks[1].isalnum():
            by_name.setdefault(toks[0].upper(), []).append((port, field))

    def prefer_keyboard(hits: list[tuple[str, str]]) -> tuple[str, str]:
        """A driver often declares the SAME default assignment twice: once on
        the real keyboard matrix and once as a joystick alias (the QL carries
        KEYCODE_SPACE on both :Y1 SPACE and :JOY1 'P2 Button 1'). The joystick
        row types nothing — and, sitting outside the MAME_CTL_KEY_EXCL port
        class, its edge lands in the same drain pass as the letter it rides
        with: two new keys in one IPC scan, BOTH dropped (sinclairql,
        2026-08-17, every space and its neighbouring letter). Prefer the
        non-joystick port; ambiguity within a class still takes the first."""
        kb = [h for h in hits if "JOY" not in h[0].upper()]
        return kb[0] if kb else hits[0]

    entries: dict[int, tuple[str, str]] = {}
    used: set[tuple[str, str]] = set()
    ambiguous: list[str] = []
    for code, names in XT_KEYS:
        # Tier 1: the field's own default assignment. When a driver says
        # PORT_CODE(KEYCODE_MINUS), that field IS the PC's '-' key regardless
        # of what its legend reads (the Dragon's ':'/'*'). Names never override
        # a token hit.
        tok = XT_TOKENS.get(code)
        hits = by_token.get(tok) if tok else None
        if hits:
            pick = prefer_keyboard(hits)
            if len(hits) > 1:
                ambiguous.append(f"  {tok} -> {hits} (took {pick}; override to pin)")
            entries[code] = pick
            used.add(pick)
            continue
        # Tier 2: exact display-name/alias match.
        for name in names:
            hits = by_name.get(name.strip().upper())
            if not hits:
                continue
            pick = prefer_keyboard(hits)
            if len(hits) > 1:
                ambiguous.append(f"  {name!r} -> {hits} (took {pick}; override to pin)")
            entries[code] = pick
            used.add(pick)
            break

    if args.override:
        with open(args.override) as ov:
            override_rows = ov.readlines()
        for n, raw in enumerate(override_rows):
            row = raw.rstrip("\n")
            if not row or row.startswith("#"):
                continue
            parts = row.split("\t", 2)
            if len(parts) != 3:
                sys.exit(f"{args.override}:{n + 1}: want scancode<TAB>port<TAB>field")
            code = int(parts[0], 16)
            entries[code] = (parts[1], parts[2])
            used.add((parts[1], parts[2]))

    out_lines = [
        "# SH_MAMESOCK_KEYMAP — generated by scripts/dev/mame-keymap.py from KEYDUMP",
        f"# source socket: {args.sock}   fields dumped: {len(fields)}   mapped: {len(entries)}",
    ]
    for code in sorted(entries):
        port, field = entries[code]
        out_lines.append(f"{code:#04x}\t{port}\t{field}")
    text = "\n".join(out_lines) + "\n"
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"wrote {args.out}: {len(entries)} keys")
    else:
        sys.stdout.write(text)

    unmatched = [f"  {port} | {field}" for port, field, _token in fields if (port, field) not in used]
    if ambiguous:
        print("AMBIGUOUS field names (first match taken):", file=sys.stderr)
        print("\n".join(ambiguous), file=sys.stderr)
    if unmatched:
        print(
            f"UNMATCHED machine fields ({len(unmatched)}) — reachable only via an "
            "--override row; decide per tile which matter:",
            file=sys.stderr,
        )
        print("\n".join(unmatched), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Generate an SH_MAMESOCK_KEYMAP file from a running MAME's own keyboard.

Phase 0 of the de-bridging conversion campaign
(docs/lab/DEBRIDGE-CONVERSION-BRIEF.md): the map is DUMPED from the machine
via the ctlsock module's KEYDUMP verb — the same rule the IRIX matrix was
built under — never hand-guessed. Matching is deliberately conservative:
a field binds to an XT scancode only on an exact (case-insensitive) name or
alias hit. Everything that does not match is listed LOUDLY at the end; the
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


def keydump(sock_path: str, tags: str) -> list[tuple[str, str]]:
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
    rows: list[tuple[str, str]] = []
    while True:
        reply = line()
        if reply.startswith("1 D "):
            body = reply[len("1 D ") :]
            port, sep, field = body.partition(" | ")
            if not sep:
                sys.exit(f"unparsable KEYDUMP row: {reply!r}")
            rows.append((port, field))
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
    for port, field in fields:
        by_name.setdefault(field.strip().upper(), []).append((port, field))

    # Dual-legend fields — MAME's `<unshifted>  <shifted>` PORT_NAMEs
    # ("1  !", "; +") — additionally index under their unshifted token. Still
    # exact matching: two tokens only, and the shifted legend must be a single
    # non-alphanumeric glyph, so "Left Shift" can never alias to "Left".
    for port, field in fields:
        toks = field.split()
        if len(toks) == 2 and len(toks[1]) == 1 and not toks[1].isalnum():
            by_name.setdefault(toks[0].upper(), []).append((port, field))

    entries: dict[int, tuple[str, str]] = {}
    used: set[tuple[str, str]] = set()
    ambiguous: list[str] = []
    for code, names in XT_KEYS:
        for name in names:
            hits = by_name.get(name.strip().upper())
            if not hits:
                continue
            if len(hits) > 1:
                ambiguous.append(f"  {name!r} -> {hits} (took the first; override to pin)")
            entries[code] = hits[0]
            used.add(hits[0])
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

    unmatched = [f"  {port} | {field}" for port, field in fields if (port, field) not in used]
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

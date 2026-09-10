#!/usr/bin/env python3
"""Generate `SH_MAMESOCK_KEYMAP` for a host-native Iris station (`indyr4400`).

Sibling of `mame-keymap.py`, and deliberately a different shape, because the
two emulators present different keyboards.

MAME's Indy keyboard is a SCANNED MATRIX: a key is a `(port, field)` pair, the
names are driver prose ("Left Shift"), and the only trustworthy source is the
running machine's own `KEYDUMP`. Iris's is a PS/2 CONTROLLER: `Ps2::push_kb`
takes a `winit::keyboard::KeyCode` and encodes the scancode itself
(`ps2.rs:map_keycode_set1`), and the guest applies its own `keybd=` layout on
top. So there is exactly ONE port (`kbd`) and the "field" is a KeyCode name.

Which makes this generator's job narrow and checkable: the browser sends XT
set-1 make/break codes, W3C UI Events already defines the code -> `KeyboardEvent.code`
mapping, and `KeyCode`'s variant names ARE those `code` values. The table below
is that mapping, written out; the generator's real work is to VERIFY every row
against the binary that will consume it, by asking the running station's
`mamectl/1` socket for `KEYDUMP` — which prints the module's `NAMES` table,
i.e. exactly the key names `Ps2::push_kb` can encode. A row whose name the
binary does not know is a hard error, never a silently dropped key: the 2026-08-12
typing investigation could not see an unmapped reject in any counter, and that
is the failure this pipeline exists to end.

usage:
    iris-keymap.py <ctl.sock> [--out FILE] [--override FILE] [--no-verify]

  --override  extra/replacement rows in the output format
              (scancode-hex<TAB>port<TAB>field), applied last
  --out       write the keymap here (default stdout)
  --no-verify emit the table without asking a running binary (for a station
              that is not up yet; the next run with a socket is the real gate)

Run it ON the box, against the station's own `ctl.sock`.
"""

import argparse
import socket
import sys

PORT = "kbd"

# XT set-1 scancode -> winit `KeyCode` variant name (== the W3C UI Events
# `KeyboardEvent.code` value the SPA already speaks). Every entry must exist in
# `Ps2Controller::map_keycode_set1`, which `--verify` checks against the binary.
XT_TO_CODE: list[tuple[int, str]] = [
    (0x01, "Escape"),
    (0x02, "Digit1"),
    (0x03, "Digit2"),
    (0x04, "Digit3"),
    (0x05, "Digit4"),
    (0x06, "Digit5"),
    (0x07, "Digit6"),
    (0x08, "Digit7"),
    (0x09, "Digit8"),
    (0x0A, "Digit9"),
    (0x0B, "Digit0"),
    (0x0C, "Minus"),
    (0x0D, "Equal"),
    (0x0E, "Backspace"),
    (0x0F, "Tab"),
    (0x10, "KeyQ"),
    (0x11, "KeyW"),
    (0x12, "KeyE"),
    (0x13, "KeyR"),
    (0x14, "KeyT"),
    (0x15, "KeyY"),
    (0x16, "KeyU"),
    (0x17, "KeyI"),
    (0x18, "KeyO"),
    (0x19, "KeyP"),
    (0x1A, "BracketLeft"),
    (0x1B, "BracketRight"),
    (0x1C, "Enter"),
    (0x1D, "ControlLeft"),
    (0x1E, "KeyA"),
    (0x1F, "KeyS"),
    (0x20, "KeyD"),
    (0x21, "KeyF"),
    (0x22, "KeyG"),
    (0x23, "KeyH"),
    (0x24, "KeyJ"),
    (0x25, "KeyK"),
    (0x26, "KeyL"),
    (0x27, "Semicolon"),
    (0x28, "Quote"),
    (0x29, "Backquote"),
    (0x2A, "ShiftLeft"),
    (0x2B, "Backslash"),
    (0x2C, "KeyZ"),
    (0x2D, "KeyX"),
    (0x2E, "KeyC"),
    (0x2F, "KeyV"),
    (0x30, "KeyB"),
    (0x31, "KeyN"),
    (0x32, "KeyM"),
    (0x33, "Comma"),
    (0x34, "Period"),
    (0x35, "Slash"),
    (0x36, "ShiftRight"),
    (0x37, "NumpadMultiply"),
    (0x38, "AltLeft"),
    (0x39, "Space"),
    (0x3B, "F1"),
    (0x3C, "F2"),
    (0x3D, "F3"),
    (0x3E, "F4"),
    (0x3F, "F5"),
    (0x40, "F6"),
    (0x41, "F7"),
    (0x42, "F8"),
    (0x43, "F9"),
    (0x44, "F10"),
    (0x45, "NumLock"),
    (0x46, "ScrollLock"),
    (0x47, "Numpad7"),
    (0x48, "Numpad8"),
    (0x49, "Numpad9"),
    (0x4A, "NumpadSubtract"),
    (0x4B, "Numpad4"),
    (0x4C, "Numpad5"),
    (0x4D, "Numpad6"),
    (0x4E, "NumpadAdd"),
    (0x4F, "Numpad1"),
    (0x50, "Numpad2"),
    (0x51, "Numpad3"),
    (0x52, "Numpad0"),
    (0x53, "NumpadDecimal"),
    (0x56, "IntlBackslash"),
    (0x57, "F11"),
    (0x58, "F12"),
    (0xE01C, "NumpadEnter"),
    (0xE01D, "ControlRight"),
    (0xE035, "NumpadDivide"),
    (0xE038, "AltRight"),
    (0xE047, "Home"),
    (0xE048, "ArrowUp"),
    (0xE049, "PageUp"),
    (0xE04B, "ArrowLeft"),
    (0xE04D, "ArrowRight"),
    (0xE04F, "End"),
    (0xE050, "ArrowDown"),
    (0xE051, "PageDown"),
    (0xE052, "Insert"),
    (0xE053, "Delete"),
    (0xE05B, "SuperLeft"),
    (0xE05C, "SuperRight"),
    (0xE05D, "ContextMenu"),
]

# Deliberately absent, with the reason, so a later reader does not "fix" it:
#   0x3A Caps Lock  — `map_keycode_set1` has no CapsLock arm, so the byte would
#                     be dropped silently. The guest's own layout handles case
#                     from a real Shift, which every SPA burst already sends.
#   0x54 SysRq / 0x46 Pause — not reachable through the SPA's key path.


def keydump(path: str) -> set[str]:
    """Ask the running module which key names it can actually encode."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    f = s.makefile("rwb", buffering=0)
    hello = f.readline().decode().rstrip("\n")
    if not hello.startswith("HELLO mamectl/1 "):
        sys.exit(f"not a mamectl/1 socket: {hello!r}")
    f.write(b"1 KEYDUMP\n")
    names: set[str] = set()
    while True:
        line = f.readline().decode().rstrip("\n")
        if not line:
            sys.exit("EOF during KEYDUMP")
        if line.startswith("EV "):
            continue
        tok = line.split(" ", 2)
        if tok[1] == "D":
            port, _, field = tok[2].partition(" | ")
            if port.strip() == PORT:
                names.add(field.strip())
            continue
        if tok[1] == "ERR":
            sys.exit(f"KEYDUMP: {line}")
        return names


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("sock", nargs="?")
    ap.add_argument("--out")
    ap.add_argument("--override")
    ap.add_argument("--no-verify", action="store_true")
    a = ap.parse_args()

    rows = {code: (PORT, name) for code, name in XT_TO_CODE}

    if not a.no_verify:
        if not a.sock:
            sys.exit("give a ctl.sock path, or pass --no-verify")
        known = keydump(a.sock)
        missing = sorted(
            {n for _, n in XT_TO_CODE if n not in known},
        )
        if missing:
            sys.exit(
                "the running binary does not know these key names, so they would\n"
                "be rejected at run time — fix the table or the fork, do NOT ship\n"
                "the map: " + ", ".join(missing)
            )
        print(f"verified {len(rows)} names against the running module", file=sys.stderr)

    if a.override:
        with open(a.override) as fh:
            for n, raw in enumerate(fh):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) != 3:
                    sys.exit(f"override line {n + 1}: want scancode<TAB>port<TAB>field")
                rows[int(parts[0], 16)] = (parts[1], parts[2])

    out = []
    out.append("# SH_MAMESOCK_KEYMAP for the host-native `indyr4400` station (Iris).")
    out.append("#")
    out.append("# GENERATED by scripts/dev/iris-keymap.py — do not hand-edit; regenerate.")
    out.append("#")
    out.append("# Columns: browser XT set-1 scancode <TAB> port <TAB> field.")
    out.append("#")
    out.append("# Iris's keyboard is a PS/2 controller, not a scanned matrix, so there is")
    out.append("# exactly ONE port (`kbd`) and the field is a `winit::keyboard::KeyCode`")
    out.append("# variant name — which is also the W3C `KeyboardEvent.code` the SPA sends,")
    out.append("# so this file is very nearly an identity map. `Ps2::push_kb` encodes the")
    out.append("# scancode itself and the guest applies its own `keybd=` layout on top;")
    out.append("# nothing here is IRIX-specific.")
    out.append("#")
    out.append("# Shift/Ctrl/Alt are ordinary rows, not special cases — which is what makes")
    out.append("# both `_` and Ctrl-C work. Caps Lock is deliberately absent (the fork's")
    out.append("# set-1 encoder has no arm for it and would drop the byte silently).")
    out.append("")
    for code in sorted(rows):
        port, field = rows[code]
        out.append(f"{code:02x}\t{port}\t{field}" if code < 0x100 else f"{code:04x}\t{port}\t{field}")
    text = "\n".join(out) + "\n"
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text)
        print(f"wrote {a.out} ({len(rows)} keys)", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()

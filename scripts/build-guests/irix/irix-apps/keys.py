#!/usr/bin/env python3
"""Reliable keyboard injection for IRIX-in-MAME, straight into the key matrix.

MAME's natkeyboard is unusable on this machine: the emulated keyboard is a PC
"Microsoft Natural" behind an SGI keymap, so every SHIFTED character is lost --
uppercase silently arrives lowercase and `_ | ~ " < > ? :` never arrive at all.
Only Caps Lock happens to work. That makes `inst` unusable (subsystem names are
full of underscores) and shell redirection impossible.

The fix: drive `:ioc2:kbd:ms_naturl`'s ioport fields directly, holding Left
Shift across the keypress ourselves. Verified: Shift + `-` produces `_`.

Because every command line the agent reads is consumed inside a single frame,
timing has to live in the guest: this installs a Lua key QUEUE (one extra
`emu.register_periodic`) that presses and releases one field per N frames. The
whole string is enqueued with a single LUA command.

  keys.py install                 (re-)install the Lua key queue -- do this once
  keys.py type "text"             type text (no Enter)
  keys.py line "text"             type text + Enter
  keys.py chord ctrl c            send a modifier chord, e.g. Ctrl-C
  keys.py key Enter               press one named key
"""

import os
import sys
import time

PORT = ":ioc2:kbd:ms_naturl:"
D = os.environ.get("IRIX_APPS_DIR", "/data/vms/sandbox/irix-apps")
CMD = os.path.join(D, "irix_cmd")
HOLD = int(os.environ.get("IRIX_KEY_HOLD", "7"))  # frames a key stays down
GAP = int(os.environ.get("IRIX_KEY_GAP", "5"))  # frames between keys

# field name -> matrix port, read out of the live machine with a Lua dump.
FIELD_PORT = {
    "Left Win": "P1.0",
    "Scroll Lock": "P1.0",
    "Keypad Enter": "P1.0",
    "Caps Lock": "P1.1",
    "Left Ctrl": "P1.1",
    "Right Ctrl": "P1.1",
    "2": "P1.2",
    "F1": "P1.2",
    "F2": "P1.2",
    "X": "P1.2",
    "W": "P1.2",
    "Page Down": "P1.2",
    "S": "P1.2",
    "Page Up": "P1.2",
    "Num Lock": "P1.3",
    "Left Alt": "P1.3",
    "Right Alt": "P1.3",
    ",": "P1.4",
    "K": "P1.4",
    "8": "P1.4",
    "I": "P1.4",
    "D": "P1.4",
    "3": "P1.4",
    "C": "P1.4",
    "E": "P1.4",
    "R": "P1.5",
    "G": "P1.5",
    "T": "P1.5",
    "V": "P1.5",
    "4": "P1.5",
    "B": "P1.5",
    "F": "P1.5",
    "5": "P1.5",
    "`": "P1.6",
    "Esc": "P1.6",
    "A": "P1.6",
    "Tab": "P1.6",
    "Z": "P1.6",
    "Q": "P1.6",
    "1": "P1.6",
    "Break": "P1.7",
    "Left Shift": "P1.7",
    "Right Shift": "P1.7",
    "N": "P2.0",
    "M": "P2.0",
    "H": "P2.0",
    "7": "P2.0",
    "J": "P2.0",
    "Y": "P2.0",
    "6": "P2.0",
    "U": "P2.0",
    "F6": "P2.1",
    "F5": "P2.1",
    "]": "P2.1",
    "Cursor Left": "P2.1",
    "=": "P2.1",
    "\\": "P2.1",
    "Backspace": "P2.1",
    "Enter": "P2.1",
    "O": "P2.2",
    "F7": "P2.2",
    "F8": "P2.2",
    "L": "P2.2",
    "[": "P2.2",
    ".": "P2.2",
    "-": "P2.2",
    "9": "P2.2",
    "0": "P2.3",
    "/": "P2.3",
    "F10": "P2.3",
    ";": "P2.3",
    "'": "P2.3",
    "Cursor Down": "P2.3",
    "F9": "P2.3",
    "P": "P2.3",
    "Cursor Right": "P2.4",
    "Cursor Up": "P2.4",
    "Space": "P2.4",
    "F12": "P2.5",
    "End": "P2.5",
    "F11": "P2.5",
    "Home": "P2.5",
    "F4": "P2.6",
    "F3": "P2.6",
    "Delete": "P2.6",
    "Insert": "P2.6",
}

# US-layout shifted characters.
SHIFTED = {
    "~": "`",
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
}

MODIFIERS = {"ctrl": "Left Ctrl", "shift": "Left Shift", "alt": "Left Alt"}

LUA_QUEUE = (
    "if not KQ then KQ={} KCUR=nil "
    "function KADD(p,n,v,t) KQ[#KQ+1]={p=p,n=n,v=v,t=t} end "
    "emu.register_periodic(function() "
    "if not KCUR and #KQ>0 then KCUR=table.remove(KQ,1) "
    "local pt=manager.machine.ioport.ports[KCUR.p] "
    "if pt then local f=pt.fields[KCUR.n] if f then f:set_value(KCUR.v) end end end "
    "if KCUR then KCUR.t=KCUR.t-1 if KCUR.t<=0 then KCUR=nil end end end) end "
    "function KSTR(s) local n=0 "
    "for a,b,c,d in string.gmatch(s,'([^#~]+)#([^#~]+)#([01])#([0-9]+)') do "
    "KADD('" + PORT + "'..a,b,tonumber(c),tonumber(d)) n=n+1 end "
    "return 'queued '..n end "
    "return 'key queue ready'"
)


def send(line):
    with open(CMD, "a") as f:
        f.write(line + "\n")


def field_for(ch):
    """Return (field, needs_shift) for a printable character."""
    if ch == " ":
        return "Space", False
    if ch in SHIFTED:
        return SHIFTED[ch], True
    if ch.isupper():
        return ch, True
    if ch.islower():
        return ch.upper(), False
    if ch in FIELD_PORT:
        return ch, False
    return None, False


def events_for(text):
    """Turn a string into (port, field, value, frames) key events."""
    ev = []
    shift = "Left Shift"
    for ch in text:
        field, need_shift = field_for(ch)
        if field is None or field not in FIELD_PORT:
            raise SystemExit(f"no key for character {ch!r}")
        if need_shift:
            ev.append((FIELD_PORT[shift], shift, 1, 2))
        ev.append((FIELD_PORT[field], field, 1, HOLD))
        ev.append((FIELD_PORT[field], field, 0, GAP))
        if need_shift:
            ev.append((FIELD_PORT[shift], shift, 0, 2))
    return ev


def emit(ev):
    """Enqueue the whole burst in ONE agent command.

    It must be a single line: the agent reads the command file and then
    truncates it, so a second write landing in that window is silently lost.
    The burst is therefore encoded compactly as port|field|value|frames records
    and expanded by KSTR inside the guest.
    """
    if not ev:
        return
    # "#" and "~" are the separators because neither is a KEY NAME -- ";" and
    # "|" are (";" is a real key, so it must survive the encoding).
    blob = "~".join(f"{p}#{n}#{v}#{t}" for p, n, v, t in ev)
    # The backslash KEY is literally named "\\", which would be an invalid
    # escape inside the Lua string literal we are building.
    send('LUA KSTR("' + blob.replace("\\", "\\\\") + '")')
    # Wait out the burst: each event costs its frames at ~60 fps, and the guest
    # runs slower than realtime, so be generous.
    time.sleep(1.0 + sum(e[3] for e in ev) / 25.0)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "install":
        send("LUA " + LUA_QUEUE)
        time.sleep(1.5)
        print("key queue installed")
    elif cmd in ("type", "line"):
        ev = events_for(argv[2])
        if cmd == "line":
            ev += [
                (FIELD_PORT["Enter"], "Enter", 1, HOLD),
                (FIELD_PORT["Enter"], "Enter", 0, GAP),
            ]
        emit(ev)
    elif cmd == "key":
        name = argv[2]
        emit([(FIELD_PORT[name], name, 1, HOLD), (FIELD_PORT[name], name, 0, GAP)])
    elif cmd == "chord":
        mod = MODIFIERS[argv[2].lower()]
        field, _ = field_for(argv[3])
        emit(
            [
                (FIELD_PORT[mod], mod, 1, 2),
                (FIELD_PORT[field], field, 1, HOLD),
                (FIELD_PORT[field], field, 0, GAP),
                (FIELD_PORT[mod], mod, 0, 2),
            ]
        )
    else:
        print(f"unknown subcommand {cmd}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Type keys into this tile over QMP with explicit hold/gap pacing.

Exercises the exhibit's only input path below the browser: QEMU PS/2 keyboard
-> X -> MAME -> the emulated ZX81 keyboard matrix, which MAME samples once per
emulated frame (50.655 Hz => 19.74 ms).

`labctl type` is NOT a fair substitute: it drives QMP with no pacing at all and
drops characters while printing "ok". Press/release are sent as explicit
input-send-event pairs rather than send-key + hold-time, because send-key
releases ASYNCHRONOUSLY and overlapping calls lose characters on their own.

An argument may be a bare qcode (`p`, `ret`, `spc`) or a CHORD written with
`+` (`shift+0`, `shift+ret`): modifiers go down in order, the final key is
held and released, then the modifiers come up in reverse. Chords matter on
this machine — nearly everything the ZX81 keyboard can do beyond its keywords
is on SHIFT (RUBOUT is shift+0, EDIT is shift+1, the cursor keys are
shift+5..8, and FUNCTION is shift+NEWLINE).

Usage: type-qmp.py <qmp.sock> <hold_ms> <gap_ms> <key|chord> [key|chord ...]
"""

import json, socket, sys, time  # noqa: E401

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
            raise SystemExit("QMP error: %s" % msg)
        if "return" in msg:
            return


def key(code, down):
    cmd(
        {
            "execute": "input-send-event",
            "arguments": {"events": [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}]},
        }
    )


cmd({"execute": "qmp_capabilities"})
for arg in sys.argv[4:]:
    parts = arg.split("+")
    mods, code = parts[:-1], parts[-1]
    for m in mods:
        key(m, True)
        time.sleep(hold)
    key(code, True)
    time.sleep(hold)
    key(code, False)
    for m in reversed(mods):
        time.sleep(hold)
        key(m, False)
    time.sleep(gap)

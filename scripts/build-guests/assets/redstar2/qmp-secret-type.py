#!/usr/bin/env python3
"""Type a secret from stdin through QMP without writing it to argv or logs."""

from __future__ import annotations

import json
import socket
import sys


def main() -> int:
    no_enter = "--no-enter" in sys.argv[1:]
    paths = [arg for arg in sys.argv[1:] if arg != "--no-enter"]
    if len(paths) != 1:
        return 2
    secret = sys.stdin.read()
    if not secret:
        return 3

    sock = socket.socket(socket.AF_UNIX)
    sock.connect(paths[0])
    stream = sock.makefile("rwb", buffering=0)
    stream.readline()
    stream.write(b'{"execute":"qmp_capabilities"}\n')
    stream.readline()

    def event(events: list[dict[str, object]]) -> None:
        request = {"execute": "input-send-event", "arguments": {"events": events}}
        stream.write((json.dumps(request) + "\n").encode())
        while True:
            reply = json.loads(stream.readline())
            if "return" in reply:
                return
            if "error" in reply:
                raise RuntimeError("QMP rejected a secret key event")

    def key(code: str, down: bool) -> None:
        event([{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}])

    shifted = "_@!#$%^&*()"
    qcodes = {
        "-": "minus",
        "_": "minus",
        ".": "dot",
        "/": "slash",
        " ": "spc",
        ";": "semicolon",
        "=": "equal",
        "@": "2",
        "!": "1",
        "#": "3",
        "$": "4",
        "%": "5",
        "^": "6",
        "&": "7",
        "*": "8",
        "(": "9",
        ")": "0",
    }
    for char in secret:
        shift = char.isupper() or char in shifted
        if char.isalpha():
            code = char.lower()
        elif char.isdigit():
            code = char
        elif char in qcodes:
            code = qcodes[char]
        else:
            return 4
        if shift:
            key("shift", True)
        key(code, True)
        key(code, False)
        if shift:
            key("shift", False)

    if not no_enter:
        key("ret", True)
        key("ret", False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

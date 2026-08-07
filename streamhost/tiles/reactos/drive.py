#!/usr/bin/env python3
"""Small QMP input/screendump driver for the ReactOS golden bake."""

import json
import socket
import sys
import time


WIDTH = 800
HEIGHT = 600
ABS_MAX = 32767


def command(sock_path, execute, arguments=None):
    request = {"execute": execute}
    if arguments is not None:
        request["arguments"] = arguments
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(sock_path)
        stream = sock.makefile("rwb", buffering=0)

        def receive():
            while True:
                line = stream.readline()
                if not line:
                    raise RuntimeError("QMP disconnected")
                message = json.loads(line)
                if "return" in message or "error" in message or "QMP" in message:
                    return message

        if "QMP" not in receive():
            raise RuntimeError("missing QMP greeting")
        stream.write(b'{"execute":"qmp_capabilities"}\r\n')
        response = receive()
        if "error" in response:
            raise RuntimeError(response["error"])
        stream.write((json.dumps(request) + "\r\n").encode())
        response = receive()
        if "error" in response:
            raise RuntimeError(response["error"])
        return response.get("return")


def absolute(axis, value, extent):
    value = max(0, min(extent - 1, int(value)))
    return {
        "type": "abs",
        "data": {"axis": axis, "value": round(value * ABS_MAX / (extent - 1))},
    }


def move_events(x, y):
    return [absolute("x", x, WIDTH), absolute("y", y, HEIGHT)]


def key_event(qcodes):
    return command(
        sock_path,
        "send-key",
        {"keys": [{"type": "qcode", "data": code} for code in qcodes]},
    )


CHAR_KEYS = {
    " ": ("spc", False),
    ".": ("dot", False),
    ":": ("semicolon", True),
    "\\": ("backslash", False),
    "-": ("minus", False),
    "_": ("minus", True),
}


def type_text(text):
    for char in text:
        if "a" <= char <= "z" or "0" <= char <= "9":
            keys = [char]
        elif "A" <= char <= "Z":
            keys = ["shift", char.lower()]
        elif char in CHAR_KEYS:
            qcode, shifted = CHAR_KEYS[char]
            keys = ["shift", qcode] if shifted else [qcode]
        else:
            raise RuntimeError(f"no qcode mapping for {char!r}")
        key_event(keys)
        time.sleep(0.025)


if len(sys.argv) < 3:
    raise SystemExit(f"usage: {sys.argv[0]} QMP-SOCKET COMMAND [ARGS...]")

sock_path, action, *args = sys.argv[1:]
if action == "shot":
    result = command(sock_path, "screendump", {"filename": args[0]})
elif action == "move":
    result = command(sock_path, "input-send-event", {"events": move_events(*args)})
elif action == "click":
    button = args[2] if len(args) > 2 else "left"
    command(sock_path, "input-send-event", {"events": move_events(args[0], args[1])})
    command(sock_path, "input-send-event", {"events": [
        {"type": "btn", "data": {"button": button, "down": True}},
    ]})
    time.sleep(0.08)
    result = command(sock_path, "input-send-event", {"events": [
        {"type": "btn", "data": {"button": button, "down": False}},
    ]})
elif action == "key":
    result = key_event(args)
elif action == "type":
    result = type_text(" ".join(args))
elif action == "hmp":
    result = command(sock_path, "human-monitor-command", {"command-line": " ".join(args)})
    if result:
        print(result, end="" if result.endswith("\n") else "\n")
else:
    raise SystemExit(f"unknown command: {action}")

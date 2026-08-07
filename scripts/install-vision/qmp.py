#!/usr/bin/env python3
"""Small synchronous QMP client used by the install-vision driver."""

from __future__ import annotations

import json
import socket
import time
from pathlib import Path
from typing import Any


class QMPError(RuntimeError):
    pass


class QMPClient:
    def __init__(self, path: str | Path, timeout: float = 30):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(timeout)
        self.socket.connect(str(path))
        self.buffer = b""
        greeting = self._read()
        if "QMP" not in greeting:
            raise QMPError(f"invalid QMP greeting: {greeting}")
        self.execute("qmp_capabilities")

    def close(self) -> None:
        self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        self.close()

    def _read(self) -> dict[str, Any]:
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise QMPError("QMP socket closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def execute(self, command: str, **arguments: Any) -> Any:
        message: dict[str, Any] = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        self.socket.sendall((json.dumps(message) + "\r\n").encode())
        while True:
            response = self._read()
            if "event" in response:
                continue
            if "error" in response:
                raise QMPError(f"{command}: {response['error']}")
            if "return" in response:
                return response["return"]

    def hmp(self, command: str) -> str:
        return self.execute("human-monitor-command", **{"command-line": command})

    def screendump(self, path: str | Path) -> None:
        self.execute("screendump", filename=str(path))

    def tap(self, x: int, y: int, width: int, height: int, hold: float = 0.12) -> None:
        if not (0 <= x < width and 0 <= y < height):
            raise QMPError(f"tap {x},{y} lies outside {width}x{height} framebuffer")
        # QEMU normalizes QMP absolute axes over 0..0x7fff.
        abs_x = round(x * 0x7FFF / max(1, width - 1))
        abs_y = round(y * 0x7FFF / max(1, height - 1))
        move = [
            {"type": "abs", "data": {"axis": "x", "value": abs_x}},
            {"type": "abs", "data": {"axis": "y", "value": abs_y}},
        ]
        self.execute("input-send-event", events=move)
        # Let the absolute tablet motion reach the guest before button-down.
        # Without this, a long jump can click the previous cursor position.
        time.sleep(0.5)
        self.execute("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "left"}}])
        time.sleep(hold)
        self.execute("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])

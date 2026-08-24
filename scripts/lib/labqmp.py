#!/usr/bin/env python3
"""Build-time QMP console/input helpers for reproducible guest builders.

This is deliberately separate from the box-side ``/root/cdrv.py`` used by
``labctl``.  Builders import this module (or use its compatible CLI) while a
guest is being assembled; cdrv remains the operator/runtime driver.
"""

from __future__ import annotations

import argparse
import base64
import json
import socket
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

PLAIN_KEYMAP = {
    " ": "spc",
    "\n": "ret",
    "\t": "tab",
    "-": "minus",
    "=": "equal",
    "[": "bracket_left",
    "]": "bracket_right",
    "\\": "backslash",
    ";": "semicolon",
    "'": "apostrophe",
    "`": "grave_accent",
    ",": "comma",
    ".": "dot",
    "/": "slash",
}

# The formerly copy-pasted shift map.  Keep it defined in exactly one place.
SHIFT_KEYMAP = {
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
    "_": "minus",
    "+": "equal",
    "{": "bracket_left",
    "}": "bracket_right",
    "|": "backslash",
    ":": "semicolon",
    '"': "apostrophe",
    "~": "grave_accent",
    "<": "comma",
    ">": "dot",
    "?": "slash",
}


class QMPError(RuntimeError):
    """A QMP transport or command failed."""


class QMPClient:
    """Small synchronous QMP client intended for build-time automation."""

    def __init__(
        self,
        path: str | Path,
        *,
        timeout: float = 180,
        connect_timeout: float = 30,
    ) -> None:
        self.path = Path(path)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout)
        deadline = time.monotonic() + connect_timeout
        while True:
            try:
                self.socket.connect(str(self.path))
                break
            except OSError as exc:
                if time.monotonic() >= deadline:
                    self.socket.close()
                    raise QMPError(f"cannot connect to {self.path}: {exc}") from exc
                time.sleep(0.5)
        self.buffer = b""
        greeting = self._read()
        if "QMP" not in greeting:
            self.close()
            raise QMPError(f"invalid QMP greeting from {self.path}: {greeting!r}")
        self.execute("qmp_capabilities")

    def close(self) -> None:
        self.socket.close()

    def __enter__(self) -> QMPClient:
        return self

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> None:
        self.close()

    def _read(self) -> dict[str, Any]:
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise QMPError(f"QMP socket closed: {self.path}")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise QMPError(f"invalid QMP JSON: {line!r}") from exc
        if not isinstance(value, dict):
            raise QMPError(f"invalid QMP response: {value!r}")
        return value

    def execute(self, command: str, **arguments: Any) -> Any:
        message: dict[str, Any] = {"execute": command}
        if arguments:
            message["arguments"] = arguments
        self.socket.sendall((json.dumps(message) + "\r\n").encode())
        while True:
            response = self._read()
            if "event" in response and "return" not in response and "error" not in response:
                continue
            if "error" in response:
                raise QMPError(f"{command}: {response['error']}")
            if "return" in response:
                return response["return"]

    def hmp(self, command: str) -> str:
        return self.execute("human-monitor-command", **{"command-line": command})

    def sendkey(self, *qcodes: str, delay: float = 0.08) -> None:
        if not qcodes:
            raise QMPError("sendkey requires at least one qcode")
        keys = [{"type": "qcode", "data": key} for key in qcodes]
        self.execute("send-key", keys=keys)
        time.sleep(delay)

    def type(self, text: str, delay: float = 0.045) -> None:
        for character in text:
            if character.isascii() and character.isalpha() and character.isupper():
                self.sendkey("shift", character.lower(), delay=delay)
            elif character.isascii() and (character.isalpha() or character.isdigit()):
                self.sendkey(character.lower(), delay=delay)
            elif character in PLAIN_KEYMAP:
                self.sendkey(PLAIN_KEYMAP[character], delay=delay)
            elif character in SHIFT_KEYMAP:
                self.sendkey("shift", SHIFT_KEYMAP[character], delay=delay)
            else:
                raise QMPError(f"no QMP key mapping for {character!r}")

    def screendump(self, path: str | Path, *, flush_timeout: float = 5) -> Path:
        output = Path(path)
        output.unlink(missing_ok=True)
        self.execute("screendump", filename=str(output))
        deadline = time.monotonic() + flush_timeout
        while time.monotonic() < deadline:
            if output.is_file() and output.stat().st_size:
                return output
            time.sleep(0.05)
        raise QMPError(f"screendump did not create {output}")

    def vm_stop(self) -> None:
        """Halt the vCPUs.  A stopped guest writes nothing, which is what makes a
        byte-copy backup of its disk hashable (checkpoint-guard depends on this)."""
        self.execute("stop")

    def vm_cont(self) -> None:
        self.execute("cont")

    def vm_status(self) -> str:
        return str(self.execute("query-status").get("status", "unknown"))

    def block_files(self, drv: str | None = None) -> list[str]:
        """Image files backing the guest's block devices, newest layer first.

        The launcher is not a reliable source for these: most stations build the
        path from a shell variable, so only the running QEMU knows it.
        """
        files = []
        for entry in self.execute("query-block") or []:
            inserted = entry.get("inserted") or {}
            name = inserted.get("file")
            if not name:
                continue
            if drv and inserted.get("drv") != drv:
                continue
            files.append(str(name))
        return files

    def savevm(self, name: str = "golden") -> str:
        return self.hmp(f"savevm {name}")

    def loadvm(self, name: str = "golden") -> str:
        return self.hmp(f"loadvm {name}")

    def delvm(self, name: str = "golden") -> str:
        return self.hmp(f"delvm {name}")

    def hostfwd_add(self, rule: str) -> str:
        return self.hmp(f"hostfwd_add {rule}")

    def assert_idle_deterministic(
        self,
        first: str | Path,
        second: str | Path,
        *,
        interval: float = 5,
    ) -> tuple[Path, Path]:
        a = self.screendump(first)
        time.sleep(interval)
        b = self.screendump(second)
        if a.read_bytes() != b.read_bytes():
            raise QMPError(f"idle framebuffer is not byte-deterministic: {a} != {b}")
        return a, b

    # Compatibility operations retained for the two first migrated builders.
    def mouse_relative_from_origin(self, x: int, y: int) -> None:
        for _ in range(12):
            self.hmp("mouse_move -300 -300")
            time.sleep(0.01)
        for axis, distance in (("x", x), ("y", y)):
            moved = 0
            while moved < distance:
                step = min(100, distance - moved)
                dx, dy = (step, 0) if axis == "x" else (0, step)
                self.hmp(f"mouse_move {dx} {dy}")
                moved += step
                time.sleep(0.008)

    def mouse_button(self, mask: str) -> None:
        self.hmp(f"mouse_button {mask}")


def _emit(value: Any) -> None:
    print(json.dumps(value))


def run_actions(client: QMPClient, actions: Sequence[str]) -> None:
    """Run the historical qdrv action stream used by shell builders."""
    index = 0
    while index < len(actions):
        action = actions[index]
        if action in {"shot", "screendump"}:
            _emit(str(client.screendump(actions[index + 1])))
            index += 2
        elif action in {"key", "sendkey"}:
            client.sendkey(actions[index + 1])
            index += 2
        elif action == "type":
            client.type(actions[index + 1])
            index += 2
        elif action == "typeb64":
            client.type(base64.b64decode(actions[index + 1]).decode())
            index += 2
        elif action == "sleep":
            time.sleep(float(actions[index + 1]))
            index += 2
        elif action == "blocks":
            nxt = actions[index + 1] if index + 1 < len(actions) else None
            # Only swallow the next token when it names a format, so `blocks` can
            # sit mid-stream without eating the action that follows it.
            drv = nxt if nxt in {"qcow2", "raw", "file", "vmdk", "qed"} else None
            for name in client.block_files(drv):
                print(name)
            index += 2 if drv else 1
        elif action == "stop":
            client.vm_stop()
            index += 1
        elif action == "cont":
            client.vm_cont()
            index += 1
        elif action == "status":
            _emit(client.vm_status())
            index += 1
        elif action == "savevm":
            _emit(client.savevm(actions[index + 1]))
            index += 2
        elif action == "loadvm":
            _emit(client.loadvm(actions[index + 1]))
            index += 2
        elif action == "delvm":
            _emit(client.delvm(actions[index + 1]))
            index += 2
        elif action in {"hostfwd", "hostfwd_add"}:
            _emit(client.hostfwd_add(actions[index + 1]))
            index += 2
        elif action == "querysnap":
            _emit(client.hmp("info snapshots"))
            index += 1
        elif action == "mouserel":
            client.mouse_relative_from_origin(int(actions[index + 1]), int(actions[index + 2]))
            index += 3
        elif action == "button":
            client.mouse_button(actions[index + 1])
            index += 2
        elif action == "assert-idle":
            interval = float(actions[index + 3]) if index + 3 < len(actions) else 5
            client.assert_idle_deterministic(actions[index + 1], actions[index + 2], interval=interval)
            index += 4 if index + 3 < len(actions) else 3
        else:
            raise QMPError(f"unknown action: {action}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket", help="QMP Unix socket")
    parser.add_argument("actions", nargs=argparse.REMAINDER, help="qdrv-compatible action stream")
    args = parser.parse_args()
    if not args.actions:
        parser.error("at least one action is required")
    try:
        with QMPClient(args.socket) as client:
            run_actions(client, args.actions)
        return 0
    except (QMPError, OSError, ValueError, IndexError) as exc:
        print(f"labqmp: ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

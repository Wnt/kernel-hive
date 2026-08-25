"""A minimal QMP client — enough to pause, resume and take a framebuffer shot.

Deliberately not an import of `scripts/lib/labqmp.py`: that module is the
build-time driver for guest builders, it carries keymaps and a CLI, and reaching
across trees to pull it into a long-lived serving process couples the gallery's
uptime to a builder helper. Sixty lines of socket code is the cheaper dependency.

`screendump` is here for one reason: **the framebuffer is the only proof a guest
reacted** (rule 9). A resumed clone that logs nothing wrong and shows a black
screen is a broken clone, and only this call can tell the difference.
"""

from __future__ import annotations

import json
import socket
import time
from pathlib import Path


class QMPError(RuntimeError):
    pass


class QMP:
    def __init__(self, path, timeout: float = 10.0):
        self.path = str(path)
        self.timeout = timeout
        self._sock = None
        self._file = None

    def __enter__(self) -> QMP:
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.path)
        except OSError as exc:
            raise QMPError(f"QMP {self.path}: {exc}") from exc
        self._sock = sock
        self._file = sock.makefile("rw", encoding="utf-8", newline="\n")
        self._read()  # the greeting
        self.execute("qmp_capabilities")

    def close(self) -> None:
        for handle in (self._file, self._sock):
            try:
                if handle:
                    handle.close()
            except OSError:
                pass
        self._file = self._sock = None

    def _read(self) -> dict:
        while True:
            line = self._file.readline()
            if not line:
                raise QMPError(f"QMP {self.path}: connection closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def execute(self, command: str, **args) -> dict:
        payload = {"execute": command}
        if args:
            payload["arguments"] = args
        self._file.write(json.dumps(payload) + "\n")
        self._file.flush()
        reply = self._read()
        if "error" in reply:
            raise QMPError(f"QMP {command}: {reply['error'].get('desc', reply['error'])}")
        return reply.get("return", {})

    def status(self) -> str:
        return str(self.execute("query-status").get("status", "unknown"))

    def resume(self) -> None:
        self.execute("cont")

    def pause(self) -> None:
        self.execute("stop")

    def screendump(self, out: Path, settle: float = 0.4) -> Path:
        """A PPM of the live framebuffer. `settle` covers the async write: QMP
        returns before the file is flushed, and reading it too early is how a
        capture campaign manufactures 'evidence' of a blank screen."""
        out = Path(out)
        self.execute("screendump", filename=str(out))
        deadline = time.time() + self.timeout
        size = -1
        while time.time() < deadline:
            if out.exists() and out.stat().st_size == size and size > 0:
                break
            size = out.stat().st_size if out.exists() else -1
            time.sleep(settle)
        if not out.exists() or out.stat().st_size == 0:
            raise QMPError(f"screendump produced nothing at {out}")
        return out

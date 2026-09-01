#!/usr/bin/env python3
"""Read and set a guest's X11 pointer from the host, with no X client libraries.

The debugging counterpart to the `x11warp` input backend (sunos414). That sink's
whole mechanism is two X requests -- QueryPointer as the SENSOR and WarpPointer
as the ACTUATOR -- so this tool issues exactly those two, against the same
loopback forward the station publishes, and answers the only question that
matters when the pointer misbehaves: does the GUEST agree about where its
pointer is?

Raw protocol on purpose. labhost has no python-xlib, the guest is an X11R5-era
server with no XTEST, and the two requests are 8 and 24 bytes; a dependency
would cost more than the code. It is NOT sunos414-specific -- any unauthenticated
X server reachable over TCP will answer it.

    x11ptr.py 127.0.0.1 6047 q               # where does the guest think it is
    x11ptr.py 127.0.0.1 6047 400,300 q       # warp there, then read it back

Three observers, not two: compare what you COMMANDED against what this reads
back against where scripts/dev/cursor-locate.py finds the sprite. A sensor
agreeing with the framebuffer is not the same claim as the pointer being where
you aimed -- only the commanded value separates them.

If the connection is refused with "Internal error during connection
authorization check", that is a REVERSE-LOOKUP failure, not an authorization
decision: the server resolves names for its access list, so the SLIRP peer must
be named in the guest's /etc/hosts before `xhost +<addr>` can match it. See
docs/guests/sunos414.md.
"""

from __future__ import annotations

import socket
import struct
import sys

SETUP = struct.Struct(">ccHHHHH")
SCREEN0 = struct.Struct(">IIIIIHH")


class XPointer:
    """One connection to an unauthenticated X server."""

    def __init__(self, host: str, port: int, timeout: float = 10.0) -> None:
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.sendall(SETUP.pack(b"B", b"\0", 11, 0, 0, 0, 0))
        head = self._recv(8)
        extra = struct.unpack(">H", head[6:8])[0] * 4
        body = self._recv(extra)
        if head[0] != 1:
            raise RuntimeError(f"X setup refused: {body[: head[1]].decode('latin-1')}")
        vendor_len, _maxreq = struct.unpack(">HH", body[16:20])
        formats = body[21]
        offset = 32 + ((vendor_len + 3) // 4) * 4 + 8 * formats
        self.root, _cmap, _white, _black, _masks, self.width, self.height = SCREEN0.unpack(
            body[offset : offset + SCREEN0.size]
        )

    def _recv(self, count: int) -> bytes:
        buf = b""
        while len(buf) < count:
            chunk = self.sock.recv(count - len(buf))
            if not chunk:
                raise RuntimeError("X server closed the connection")
            buf += chunk
        return buf

    def query(self) -> tuple[int, int, int]:
        """QueryPointer: the guest's OWN answer, in root coordinates."""
        self.sock.sendall(struct.pack(">BBHI", 38, 0, 2, self.root))
        reply = self._recv(32)
        x, y = struct.unpack(">hh", reply[16:20])
        return x, y, struct.unpack(">H", reply[24:26])[0]

    def warp(self, x: int, y: int) -> None:
        """WarpPointer to an absolute root coordinate (src None, no bounding box)."""
        self.sock.sendall(struct.pack(">BBHIIhhHHhh", 41, 0, 6, 0, self.root, 0, 0, 0, 0, x, y))


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__)
        return 2
    conn = XPointer(argv[1], int(argv[2]))
    print(f"root=0x{conn.root:x} screen={conn.width}x{conn.height}")
    for arg in argv[3:]:
        if arg == "q":
            print(f"pointer: {conn.query()}")
            continue
        x, y = (int(v) for v in arg.split(","))
        conn.warp(x, y)
        print(f"warp -> {x},{y} readback: {conn.query()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

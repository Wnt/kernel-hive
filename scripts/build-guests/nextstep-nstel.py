#!/usr/bin/env python3
"""Minimal telnet client for the NeXTSTEP guest inside the `nextstep` tile.

Runs ON THE DEBIAN KIOSK (installed by scripts/build-guests/nextstep.sh as
`/usr/local/bin/nstel.py`). Previous publishes a fixed SLIRP redirection from
the kiosk's 127.0.0.1:42323 to the emulated NeXTcube's telnet port, so this is
the only captured-output exec channel into NeXTSTEP itself -- `labctl exec
nextstep` reaches the kiosk around it, not the NeXT.

  ssh lab 'labctl exec nextstep "python3 /usr/local/bin/nstel.py me \\"uname -a\\""'

`root` is refused by NeXTSTEP on a pseudo-terminal, so log in as the console
user `me` (no password) and let the client `su` to root, which needs none
either. Pass --nosu to stay as `me`.
"""

import socket
import sys
import time

HOST, PORT = "127.0.0.1", 42323
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


def _negotiate(sock: socket.socket, data: bytes, out: bytearray) -> None:
    """Answer the server's telnet option negotiation; append payload to `out`."""
    i = 0
    while i < len(data):
        byte = data[i]
        if byte == IAC and i + 1 < len(data):
            cmd = data[i + 1]
            if cmd in (DO, DONT, WILL, WONT) and i + 2 < len(data):
                opt = data[i + 2]
                if cmd == DO:
                    # agree to suppress-go-ahead only; refuse everything else
                    sock.sendall(bytes([IAC, WILL if opt == 3 else WONT, opt]))
                elif cmd == WILL:
                    # let the server echo and suppress go-ahead
                    sock.sendall(bytes([IAC, DO if opt in (1, 3) else DONT, opt]))
                i += 3
                continue
            if cmd == SB:
                end = data.find(bytes([IAC, SE]), i)
                i = len(data) if end < 0 else end + 2
                continue
            i += 2
            continue
        out.append(byte)
        i += 1


def read(sock: socket.socket, seconds: float = 3.0) -> str:
    out = bytearray()
    deadline = time.time() + seconds
    sock.settimeout(0.5)
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        _negotiate(sock, chunk, out)
    return bytes(out).decode("latin-1")


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: nstel.py <user> [--nosu] <command> [command...]")
    user = sys.argv[1]
    sock = socket.create_connection((HOST, PORT), timeout=20)
    sys.stdout.write(read(sock, 10))
    sock.sendall(user.encode() + b"\r\n")
    sys.stdout.write(read(sock, 10))
    sock.sendall(b"\r\n")  # empty password
    sys.stdout.write(read(sock, 15))
    if user != "root" and "--nosu" not in sys.argv:
        sock.sendall(b"su\r\n")
        sys.stdout.write(read(sock, 10))
        sock.sendall(b"\r\n")
        sys.stdout.write(read(sock, 10))
    for cmd in [a for a in sys.argv[2:] if a != "--nosu"]:
        sock.sendall(cmd.encode() + b"\r\n")
        sys.stdout.write(f"\n=== {cmd}\n")
        sys.stdout.write(read(sock, len(cmd) / 40.0 + 8))
    sock.sendall(b"exit\r\n")
    read(sock, 2)
    sock.close()


main()

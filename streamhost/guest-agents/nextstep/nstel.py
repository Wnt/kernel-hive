#!/usr/bin/env python3
"""nstel.py — minimal telnet exec channel into NeXTSTEP 3.3 under Previous.

Runs INSIDE the Debian kiosk (Debian 12 has no telnet client, but it has
python3). Previous's SLIRP stack already publishes fixed inbound redirections
from the kiosk to the emulated NeXT machine -- see enet_slirp.c:

    host 42320 -> guest 20   (ftp-data)      host 42322 -> guest 22 (ssh)
    host 42321 -> guest 21   (ftp)           host 42323 -> guest 23 (telnet)
                                             host 42380 -> guest 80 (http)

so no emulator patch, no extra device and no QEMU change is needed to get a
real shell (and later a daemon port) into NeXTSTEP.

Usage:  nstel.py <user> <pass> <command...>
Prints the command's stdout+stderr and exits with the guest's exit status.
"""
import socket
import sys
import time
import uuid

IAC, DONT, DO, WONT, WILL, SB, SE = (bytes([c]) for c in (255, 254, 253, 252, 251, 250, 240))
PORT = 42323


class Telnet:
    def __init__(self, host="127.0.0.1", port=PORT, timeout=25):
        self.s = socket.create_connection((host, port), timeout)
        self.s.settimeout(timeout)
        self.buf = b""

    def _negotiate(self, data):
        out = b""
        i = 0
        while i < len(data):
            c = data[i : i + 1]
            if c != IAC:
                out += c
                i += 1
                continue
            cmd = data[i + 1 : i + 2]
            if cmd in (DO, DONT):
                self.s.sendall(IAC + WONT + data[i + 2 : i + 3])
                i += 3
            elif cmd in (WILL, WONT):
                self.s.sendall(IAC + DONT + data[i + 2 : i + 3])
                i += 3
            elif cmd == SB:
                j = data.find(IAC + SE, i)
                i = len(data) if j < 0 else j + 2
            else:
                i += 2
        return out

    def read_until(self, marker, deadline=40):
        end = time.time() + deadline
        while marker not in self.buf:
            if time.time() > end:
                raise RuntimeError("timeout waiting for %r; got %r" % (marker, self.buf[-400:]))
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                raise RuntimeError("connection closed; got %r" % self.buf[-400:])
            self.buf += self._negotiate(d)
        out, self.buf = self.buf.split(marker, 1)
        return out + marker

    def send(self, line):
        self.s.sendall(line.encode() + b"\r\n")

    def login(self, user, pw):
        self.read_until(b"login:")
        self.send(user)
        time.sleep(0.4)
        # NeXTSTEP asks for a password only when the account has one.
        end = time.time() + 12
        while time.time() < end:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            self.buf += self._negotiate(d)
            if b"Password:" in self.buf:
                self.send(pw)
                break
            if b"%" in self.buf or b"#" in self.buf or b"$" in self.buf:
                break
        # settle on a deterministic prompt
        self.tag = "NSX%s" % uuid.uuid4().hex[:8]
        self.send("set prompt='%s> '" % self.tag)
        self.send("stty -echo")
        self.read_until(("%s> " % self.tag).encode())
        self.read_until(("%s> " % self.tag).encode())

    def run(self, cmd, deadline=120):
        self.send("%s; echo RC=$status" % cmd)
        out = self.read_until(("%s> " % self.tag).encode(), deadline)
        body = out.rsplit(b"RC=", 1)
        text = body[0].decode("latin-1")
        rc = 0
        if len(body) > 1:
            try:
                rc = int(body[1].split()[0])
            except (ValueError, IndexError):
                rc = -1
        return text, rc


def main():
    user, pw = sys.argv[1], sys.argv[2]
    cmd = " ".join(sys.argv[3:])
    t = Telnet()
    t.login(user, pw)
    text, rc = t.run(cmd)
    sys.stdout.write(text)
    sys.exit(rc)


if __name__ == "__main__":
    main()

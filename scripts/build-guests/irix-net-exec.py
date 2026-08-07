#!/usr/bin/env python3
"""Minimal telnet client for the IRIX guest over the host-only tap.

Python dropped telnetlib in 3.13, and this needs to be scriptable evidence
rather than an interactive session, so it speaks just enough of the protocol:
refuse every DO/WILL, log in, run a command, print what came back.

  gtel.py <host> <user> "<command>"
"""

import contextlib
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


def negotiate(sock, data, buf):
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == IAC and i + 1 < len(data):
            cmd = data[i + 1]
            if cmd in (DO, DONT) and i + 2 < len(data):
                sock.sendall(bytes([IAC, WONT, data[i + 2]]))
                i += 3
                continue
            if cmd in (WILL, WONT) and i + 2 < len(data):
                sock.sendall(bytes([IAC, DONT, data[i + 2]]))
                i += 3
                continue
            if cmd == SB:
                j = data.find(bytes([IAC, SE]), i)
                i = len(data) if j < 0 else j + 2
                continue
            i += 2
            continue
        out.append(b)
        i += 1
    buf.extend(out)
    return buf


def expect(sock, buf, needles, timeout=45):
    end = time.time() + timeout
    while time.time() < end:
        for n in needles:
            if n in bytes(buf):
                return n
        sock.settimeout(2.0)
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        negotiate(sock, chunk, buf)
    return None


def main():
    host, user = sys.argv[1], sys.argv[2]
    push = None
    if sys.argv[3] == "--push":
        # Upload a local script and run it. ftpd refuses root (/etc/ftpusers),
        # so the file goes over this same shell as a quoted here-document.
        push = sys.argv[4]
        cmd = "sh /tmp/gtel-push.sh"
    else:
        cmd = sys.argv[3]
    s = socket.create_connection((host, 23), timeout=30)
    buf = bytearray()
    if not expect(s, buf, [b"login:"]):
        print("no login prompt; got:\n" + bytes(buf).decode("latin1"))
        return 1
    s.sendall(user.encode() + b"\r\n")
    hit = expect(s, buf, [b"Password:", b"# ", b"$ "])
    if hit == b"Password:":
        s.sendall(b"\r\n")
        expect(s, buf, [b"# ", b"$ "])
    # IRIX root's login shell is csh, where `RC=$?` is a syntax error. Drop into
    # a Bourne shell first so the marker (and any command sent through here)
    # means what it says.
    s.sendall(b"exec /bin/sh\r\n")
    time.sleep(1.5)
    buf.clear()
    s.sendall(b"PS1=XXPROMPT; export PS1\r\n")
    expect(s, buf, [b"XXPROMPT"], timeout=30)
    if push:
        with open(push) as fh:
            body = fh.read()
        assert "XXPUSHEOF" not in body
        s.sendall(b"cat > /tmp/gtel-push.sh <<'XXPUSHEOF'\r\n")
        for line in body.splitlines():
            s.sendall(line.encode() + b"\r\n")
            time.sleep(0.02)
        s.sendall(b"XXPUSHEOF\r\n")
        buf.clear()
        expect(s, buf, [b"XXPROMPT"], timeout=60)
    marker = "RC=$?; echo XX_DONE_$RC"
    s.sendall(f"{cmd}; {marker}\r\n".encode())
    buf.clear()
    if not expect(s, buf, [b"XX_DONE_"], timeout=120):
        print("command did not complete; got:\n" + bytes(buf).decode("latin1"))
        return 1
    time.sleep(1.0)
    with contextlib.suppress(OSError):
        negotiate(s, s.recv(65536), buf)
    text = bytes(buf).decode("latin1")
    s.sendall(b"exit\r\n")
    s.close()
    print(text.replace("\r\n", "\n").strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())

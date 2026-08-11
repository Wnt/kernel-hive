#!/usr/bin/env python3
"""w2ktelnetexec — captured command exec over the Windows 2000 (Alpha) Telnet
Server, for `labctl exec w2kalpha`.

The W2K telnet server speaks a VT100 *console* stream (absolute cursor moves +
erase-line), not a clean line stream, so a naive read interleaves control
sequences with text. This client refuses all telnet option negotiation, logs in
(blank Administrator by default), wraps the command between unique sentinels with
a trailing %errorlevel%, then renders the console stream back to plain text by
turning cursor-position / erase-line escapes into line breaks and dropping the
rest. It prints the command's stdout and exits with the guest's errorlevel — the
labctl-exec contract (the guest's exit code becomes yours).

The channel exists only while the tile is up: es40's dec21143 (pcap backend on
the host-only veth w2kalpha-g) carries it, the guest has a static IP, and the
Telnet Server auto-starts. It is reachable ONLY from the box.

    w2ktelnetexec.py <host> <cmd...>              # blank Administrator password
    W2K_USER=... W2K_PASS=... w2ktelnetexec.py <host> <cmd...>
"""

import os
import re
import socket
import sys
import time
import uuid

IAC = 255
CSI = re.compile(rb"\x1b\[([0-9;]*)([A-Za-z])")


def _render(raw: bytes) -> str:
    # Absolute cursor moves (H/f) and erase-line (K) become newlines so each
    # positioned write lands on its own line; every other CSI escape is dropped.
    out = CSI.sub(lambda m: b"\n" if m.group(2) in (b"H", b"f", b"K") else b"", raw)
    return out.replace(b"\r", b"").decode("latin1")


def _negotiate(sock: socket.socket, data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == IAC and i + 2 < len(data):
            cmd, opt = data[i + 1], data[i + 2]
            if cmd == 253:  # DO   -> WONT
                sock.sendall(bytes([IAC, 252, opt]))
            elif cmd == 251:  # WILL -> DONT
                sock.sendall(bytes([IAC, 254, opt]))
            i += 3
            continue
        if b == IAC and i + 1 < len(data):  # 2-byte IAC command, drop
            i += 2
            continue
        out.append(b)
        i += 1
    return bytes(out)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: w2ktelnetexec.py <host> <cmd...>\n")
        return 2
    host = sys.argv[1]
    cmd = " ".join(sys.argv[2:])
    user = os.environ.get("W2K_USER", "Administrator")
    passwd = os.environ.get("W2K_PASS", "")
    tag = uuid.uuid4().hex[:12].upper()
    begin, end = f"BX{tag}", f"EX{tag}"

    s = socket.socket()
    s.settimeout(10)
    s.connect((host, 23))
    buf = bytearray()

    def pump(seconds: float) -> None:
        s.settimeout(seconds)
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                d = s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            buf.extend(_negotiate(s, d))

    def send(line: str) -> None:
        s.sendall(line.encode("latin1") + b"\r\n")
        time.sleep(0.3)

    def pump_until(pattern: str, timeout: float) -> bool:
        # Read until `pattern` appears in the rendered console or timeout. Prompt-
        # driven so rapid back-to-back execs don't race the (single-threaded) W2K
        # telnet server's login, the failure mode fixed sleeps hit intermittently.
        s.settimeout(1.0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if re.search(pattern, _render(bytes(buf)), re.I):
                return True
            try:
                d = s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                break
            buf.extend(_negotiate(s, d))
        return bool(re.search(pattern, _render(bytes(buf)), re.I))

    pump_until(r"login:", 20)
    send(user)
    pump_until(r"password:", 12)
    send(passwd)
    pump_until(r"[A-Za-z]:\\[^\n]*>", 20)  # a cmd.exe shell prompt (e.g. C:\>)
    # The W2K telnet server presents the prompt a beat before it can take input,
    # so leading characters of a command sent immediately are dropped — which
    # silently corrupts the wrapped line and yields no sentinel. Settle first,
    # then send; if the END sentinel never lands, the line was eaten — retry once.
    line = f"echo {begin}& {cmd} &echo {end}%errorlevel%"
    end_re = re.compile(end.encode() + rb"\d")
    for attempt in range(2):
        time.sleep(0.7)
        send(line)
        s.settimeout(1.5)
        idle = 0
        while idle < 12:
            try:
                d = s.recv(4096)
            except socket.timeout:
                if end_re.search(bytes(buf)):
                    break
                idle += 1
                continue
            if not d:
                break
            buf.extend(_negotiate(s, d))
        if end_re.search(bytes(buf)):
            break
    try:
        send("exit")
        pump(1)
    except OSError:
        pass
    s.close()

    text = _render(bytes(buf))
    m = re.search(re.escape(begin) + r"\s*\n(.*?)\n?\s*" + re.escape(end) + r"(\d+)", text, re.S)
    if not m:
        sys.stderr.write("w2ktelnetexec: sentinels not found; raw console:\n")
        sys.stderr.write(text)
        return 125
    body, rc = m.group(1), int(m.group(2))
    lines = [ln for ln in body.split("\n") if begin not in ln and end not in ln]
    sys.stdout.write("\n".join(lines).strip("\n") + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main())

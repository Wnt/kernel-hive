#!/usr/bin/env python3
"""Prove the DZ visitor line: telnet in, log in, and cross to the console.

Usage: dzprobe.py <port>   (the port SIMH's `att dz <port>` is listening on)

This is a BUILD-TIME probe on labhost, not a station proof: the station's proof
is the framebuffer of the xterm that runs this same telnet session inside the
container.
"""

import socket
import sys
import time

s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 30)
s.settimeout(30)
buf = b""


def until(tok, t=60):
    global buf
    end = time.time() + t
    while time.time() < end:
        try:
            d = s.recv(4096)
        except socket.timeout:
            break
        if not d:
            break
        buf += d
        if tok in buf:
            return True
    return False


print("login prompt:", until(b"login:", 90))
s.sendall(b"root\r\n")
time.sleep(3)
print("shell prompt:", until(b"#", 60))
s.sendall(b"hostname; who; echo VAXDZPROOFOK > /dev/console\r\n")
time.sleep(5)
until(b"ZZZ", 8)
print("---- transcript ----")
print(buf.decode("latin1"))

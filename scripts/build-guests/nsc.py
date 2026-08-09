#!/usr/bin/env python3
"""Client for the Previous abspointer control socket (runs inside the kiosk guest)."""

import socket
import sys
import time

SOCK = "/tmp/previous-abs.sock"


def run(cmds, delay=0.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(SOCK)
    f = s.makefile("rw")
    out = []
    for c in cmds:
        f.write(c + "\n")
        f.flush()
        out.append(f.readline().rstrip("\n"))
        if delay:
            time.sleep(delay)
    s.close()
    return out


if __name__ == "__main__":
    for line in run([a for a in sys.argv[1:]]):
        print(line)

#!/usr/bin/env python3
# qmp_hmp.py <qmp.sock> "<hmp command>"   run an HMP command via QMP human-monitor-command.
import json
import socket
import sys

sock = sys.argv[1]
hmp = sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(180)
s.connect(sock)
buf = b""


def rl():
    global buf
    while b"\n" not in buf:
        buf += s.recv(65536)
    l, buf2 = buf.split(b"\n", 1)
    buf = buf2
    return json.loads(l)


rl()  # greeting


def cmd(o):
    s.sendall((json.dumps(o) + "\r\n").encode())
    while True:
        m = rl()
        if "return" in m or "error" in m:
            return m


print("CAPS:", cmd({"execute": "qmp_capabilities"}))
r = cmd({"execute": "human-monitor-command", "arguments": {"command-line": hmp}})
print(f"HMP({hmp}) ->")
print(json.dumps(r, indent=2))

#!/usr/bin/env python3
# gexec.py <port> <cmd...>  -- host-side client for warpd's 'E' exec verb.
# Connects to warpd on 127.0.0.1:<port> (the QEMU hostfwd to the guest's :7777),
# sends 'E <cmd...>', reads the framed reply
#     O <base64 stdout+stderr>\n X <exitcode>\n .\n
# prints the guest stdout/stderr verbatim, and exits with the guest's exit code.
# labctl calls: python3 /root/gexec.py <port> <cmd...>
import socket, sys, base64
if len(sys.argv) < 3:
    sys.stderr.write("usage: gexec.py <port> <cmd...>\n"); sys.exit(2)
port = int(sys.argv[1]); cmd = " ".join(sys.argv[2:])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(120)
s.connect(("127.0.0.1", port))
s.sendall(("E " + cmd + "\n").encode())
buf = b""
while b"\n.\n" not in buf:
    d = s.recv(65536)
    if not d: break
    buf += d
s.close()
out = b""; rc = 0
for line in buf.split(b"\n"):
    if line == b".": break
    if line.startswith(b"O "): out = base64.b64decode(line[2:])
    elif line.startswith(b"X "):
        try: rc = int(line[2:])
        except ValueError: rc = 1
sys.stdout.buffer.write(out); sys.stdout.flush()
sys.exit(rc)

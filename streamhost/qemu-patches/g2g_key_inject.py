#!/usr/bin/env python3
# g2g_key_inject.py <qmp.sock> <n> <gap_s>
# Keystroke glass-to-glass stimulus: from a clean FreeCom prompt ("C:\>",
# cursor at col 4), type n distinct printable chars (no Enter), one per gap.
# Each char's glyph lands at a NEW cell (col 4+i); the cursor moves to the
# next cell, so the glyph cell is blink-immune. t0 = CLOCK_REALTIME ns stamped
# immediately before the send-key. Output: TRIAL <i> <t0_ns> <char>
import json, socket, sys, time
sock, n, gap = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock)
buf = b""
def rl():
    global buf
    while b"\n" not in buf:
        buf += s.recv(65536)
    l, buf = buf.split(b"\n", 1)
    return json.loads(l)
rl()
def cmd(o):
    s.sendall((json.dumps(o) + "\r\n").encode())
    while True:
        m = rl()
        if "return" in m or "error" in m:
            return m
cmd({"execute": "qmp_capabilities"})
def wall():
    return time.clock_gettime_ns(time.CLOCK_REALTIME)

chars = list("abcdefghijklmnopqrstuvwxyz0123456789")[:n]
print("INJECT_START_NS", wall(), flush=True)
time.sleep(1.0)
for i, ch in enumerate(chars):
    time.sleep(gap)
    t0 = wall()
    r = cmd({"execute": "send-key",
             "arguments": {"keys": [{"type": "qcode", "data": ch}]}})
    if "error" in r:
        print("TRIAL_ERR", i, r, flush=True)
    else:
        print("TRIAL", i, t0, ch, flush=True)
print("INJECT_END_NS", wall(), flush=True)

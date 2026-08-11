#!/usr/bin/env python3
# Persistent serial multiplexer for a QEMU -serial unix socket (sailfishos tile).
#
# SOURCE OF TRUTH: streamhost/stations/sailfishos/seriald.py (osgallery repo)
# LIVE COPY:       /data/vms/streamhost/stations/sailfishos/seriald.py (lab box)
# Keep byte-identical (same rule as scripts/labctl).
#
# Holds ONE connection (QEMU serialsock server allows a single client).
#  - everything read from the socket is appended to <base>/serial.out
#  - lines written to the FIFO <base>/serial.in are sent to the socket (with \r)
#  - a line "__RAW__ <text>" is sent verbatim (no CR)
# Run in background:  python3 seriald.py <sock> <base> &
#
# EOF FIX (2026-07-12): when QEMU closes the serial chardev (tile restart,
# daemon-side hiccup), recv() returns b'' and select() reports the fd readable
# FOREVER. The original reader ignored the b'' (`if c:`) and re-entered
# select() immediately -> a tight spin that burned ~100% of one core for days.
# Now b'' (and fatal socket errors) tear the connection down and reconnect
# with a 2 s backoff; the FIFO writer drops lines while disconnected.
import socket, sys, os, select, time, threading

SOCK = sys.argv[1]
BASE = sys.argv[2]
OUT = os.path.join(BASE, "serial.out")
INF = os.path.join(BASE, "serial.in")

_lock = threading.Lock()
_sock = None


def connect_sock():
    """(Re)connect to the QEMU serial socket, retrying every 2 s forever."""
    global _sock
    while True:
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(SOCK)
            s.setblocking(False)
            with _lock:
                _sock = s
            return s
        except OSError:
            time.sleep(2)


def cur_sock():
    with _lock:
        return _sock


connect_sock()

if os.path.exists(INF):
    os.remove(INF)
os.mkfifo(INF)
open(OUT, "wb").close()


def reader():
    s = cur_sock()
    with open(OUT, "ab", buffering=0) as f:
        while True:
            r, _, _ = select.select([s], [], [], 0.5)
            if not r:
                continue
            try:
                c = s.recv(65536)
            except (BlockingIOError, InterruptedError):
                continue
            except OSError:
                c = b""  # fatal socket error -> treat as EOF
            if c:
                f.write(c)
            else:
                # EOF: QEMU side closed. Reconnect with backoff — NEVER spin.
                try:
                    s.close()
                except OSError:
                    pass
                time.sleep(2)
                s = connect_sock()


threading.Thread(target=reader, daemon=True).start()

# open FIFO for reading (blocks until a writer connects, reopen each EOF)
while True:
    with open(INF, "r") as fifo:
        for line in fifo:
            line = line.rstrip("\n")
            if line.startswith("__RAW__ "):
                data = line[len("__RAW__ "):].encode()
            else:
                data = (line + "\r").encode()
            try:
                cur_sock().sendall(data)
            except OSError:
                pass  # disconnected; reader thread is reconnecting — drop line
            time.sleep(0.05)

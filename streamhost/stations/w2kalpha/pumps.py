# pumps.py <ser0-port> <ser1-port> — serial-port pump for the w2kalpha tile.
#
# es40 BLOCKS on startup until BOTH emulated serial ports have a TCP client;
# this connects to the two listen ports from es40.cfg and drains whatever the
# guest prints into per-port logs (ser0-live.log / ser1-live.log next to this
# file). It dies WITH es40: any socket EOF or error exits the whole process,
# so a relaunch can never strand a stale pump holding old ports.
import os
import socket
import sys
import threading
import time

D = os.path.dirname(os.path.abspath(__file__))
ports = (int(sys.argv[1]), int(sys.argv[2]))


def pump(port, name):
    while True:
        try:
            s = socket.socket()
            s.connect(("127.0.0.1", port))
            break
        except OSError:
            time.sleep(0.5)
    with open(f"{D}/{name}-live.log", "ab", 0) as f:
        while True:
            try:
                d = s.recv(4096)
            except OSError:
                os._exit(0)  # es40 went away; die with it
            if not d:
                os._exit(0)
            f.write(d)


for port, name in ((ports[0], "ser0"), (ports[1], "ser1")):
    threading.Thread(target=pump, args=(port, name), daemon=True).start()

while True:
    time.sleep(60)

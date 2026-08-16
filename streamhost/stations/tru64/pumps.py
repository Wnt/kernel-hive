# pumps.py <ser0-port> <ser1-port> — serial pump + exec relay for the tru64 tile.
#
# es40 BLOCKS on startup until BOTH emulated serial ports have a TCP client, so
# this connects to both listen ports from es40.cfg the moment it starts.
#
#   ser0 (console side)  — drained to ser0-live.log, exactly like w2kalpha.
#   ser1 (exec channel)  — drained to ser1-live.log UNTIL a client connects to
#                          the unix socket serial-exec.sock next to this file;
#                          then it is a byte pipe between that client and the
#                          guest's getty on /dev/tty01, and back to draining
#                          when the client leaves.
#
# The relay exists because the TCP port cannot be lent directly: es40 accepts
# ONE client per serial port and needs it held from boot, so whoever holds it
# has to be the one that also hands it out. Holding it here means the exec
# channel survives relaunches at a FIXED path (the station dir), with no port
# scraping and no second connection racing es40's accept.
#
# One client at a time (the socket backlog queues the rest): two shells
# interleaved on one console produce garbage that looks like guest corruption.
#
# It dies WITH es40: any socket EOF or error on a serial port exits the whole
# process, so a relaunch can never strand a stale pump holding old ports.
import os
import socket
import sys
import threading
import time

D = os.path.dirname(os.path.abspath(__file__))
ports = (int(sys.argv[1]), int(sys.argv[2]))
EXEC_SOCK = f"{D}/serial-exec.sock"

# Set while an exec client owns ser1; the pump thread hands it every guest byte
# instead of writing the log, and stops the moment the client goes away.
_client_lock = threading.Lock()
_client = None


def _connect(port):
    while True:
        try:
            s = socket.socket()
            s.connect(("127.0.0.1", port))
            return s
        except OSError:
            time.sleep(0.5)


def pump(port, name, lend):
    s = _connect(port)
    if lend:
        threading.Thread(target=exec_relay, args=(s,), daemon=True).start()
    with open(f"{D}/{name}-live.log", "ab", 0) as f:
        while True:
            try:
                d = s.recv(4096)
            except OSError:
                os._exit(0)  # es40 went away; die with it
            if not d:
                os._exit(0)
            c = _client
            if c is not None:
                try:
                    c.sendall(d)
                    continue  # lent: the client sees it, the log does not
                except OSError:
                    pass  # client died mid-write; fall through and log it
            f.write(d)


def exec_relay(ser):
    """Serve serial-exec.sock: hand ser1 to one client at a time."""
    global _client
    try:
        os.unlink(EXEC_SOCK)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(EXEC_SOCK)
    os.chmod(EXEC_SOCK, 0o600)
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        with _client_lock:
            _client = conn
            try:
                while True:
                    d = conn.recv(4096)
                    if not d:
                        break
                    ser.sendall(d)  # client -> guest; guest -> client is in pump()
            except OSError:
                pass
            finally:
                _client = None
                try:
                    conn.close()
                except OSError:
                    pass


for port, name, lend in ((ports[0], "ser0", False), (ports[1], "ser1", True)):
    threading.Thread(target=pump, args=(port, name, lend), daemon=True).start()

while True:
    time.sleep(60)

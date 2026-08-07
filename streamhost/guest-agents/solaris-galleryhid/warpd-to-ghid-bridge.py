#!/usr/bin/env python3
"""Translate streamhost's warpd TCP protocol to gallery-hid pointer frames."""

import argparse
import socket
import socketserver
import struct
import sys
import threading
import time

SCREEN_WIDTH = 1920
SCREEN_HEIGHT = 1200
GHID_RECORD_BYTES = 16


def normalized(pixel, extent):
    pixel = max(0, min(extent - 1, int(pixel)))
    return (pixel * 32767 + (extent - 1) // 2) // (extent - 1)


class GhidBackend:
    def __init__(self, path):
        self.path = path
        self.sock = None

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def connect(self):
        self.close()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1.0)
        sock.connect(self.path)
        hello = bytearray(GHID_RECORD_BYTES)
        hello[0:4] = b"GHIN"
        struct.pack_into("<HHH", hello, 4, 1, 0, GHID_RECORD_BYTES)
        sock.sendall(hello)
        reply = bytearray()
        while len(reply) < GHID_RECORD_BYTES:
            chunk = sock.recv(GHID_RECORD_BYTES - len(reply))
            if not chunk:
                raise ConnectionError("EOF waiting for GHOK")
            reply.extend(chunk)
        if reply[0:4] != b"GHOK" or struct.unpack_from("<H", reply, 4)[0] != 1:
            raise ConnectionError("incompatible gallery-hid handshake")
        sock.settimeout(None)
        self.sock = sock

    def send_pointer(self, x, y, buttons, wheel_v=0, wheel_h=0):
        record = bytearray(GHID_RECORD_BYTES)
        record[0] = 0x01
        struct.pack_into(
            "<HHHbbI",
            record,
            4,
            normalized(x, SCREEN_WIDTH),
            normalized(y, SCREEN_HEIGHT),
            buttons,
            wheel_v,
            wheel_h,
            (time.monotonic_ns() // 1000) & 0xFFFFFFFF,
        )
        for attempt in range(2):
            try:
                if self.sock is None:
                    self.connect()
                self.sock.sendall(record)
                return
            except (ConnectionError, OSError) as error:
                self.close()
                if attempt:
                    raise error


class PointerState:
    BUTTON_BITS = {1: 0x01, 2: 0x02, 3: 0x04}

    def __init__(self, backend):
        self.backend = backend
        self.lock = threading.Lock()
        self.x = SCREEN_WIDTH // 2
        self.y = SCREEN_HEIGHT // 2
        self.buttons = 0

    def emit(self, x, y, buttons=None, wheel=0):
        with self.lock:
            self.x = max(0, min(SCREEN_WIDTH - 1, int(x)))
            self.y = max(0, min(SCREEN_HEIGHT - 1, int(y)))
            if buttons is not None:
                self.buttons = buttons
            self.backend.send_pointer(self.x, self.y, self.buttons, wheel)

    def press(self, number, x, y):
        bit = self.BUTTON_BITS.get(number)
        if bit is None:
            raise ValueError("press supports buttons 1..3")
        self.emit(x, y, self.buttons | bit)

    def release(self, number, x, y):
        bit = self.BUTTON_BITS.get(number)
        if bit is None:
            raise ValueError("release supports buttons 1..3")
        self.emit(x, y, self.buttons & ~bit)

    def click(self, number, x, y):
        if number == 4:
            self.emit(x, y, wheel=1)
        elif number == 5:
            self.emit(x, y, wheel=-1)
        else:
            self.press(number, x, y)
            self.release(number, x, y)

    def release_all(self):
        with self.lock:
            if self.buttons:
                self.buttons = 0
                try:
                    self.backend.send_pointer(self.x, self.y, 0)
                except OSError:
                    pass


class WarpdHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            while True:
                raw = self.rfile.readline(4096)
                if not raw:
                    break
                if len(raw) == 4096 and not raw.endswith(b"\n"):
                    raise ValueError("command line too long")
                line = raw.decode("ascii", "strict").strip()
                if not line:
                    continue
                fields = line.split()
                verb = fields[0].upper()
                if verb == "QUIT":
                    break
                if verb in ("M", "W", "C", "D", "U") and len(fields) >= 3:
                    x, y = int(fields[1]), int(fields[2])
                    if verb in ("M", "W"):
                        self.server.state.emit(x, y)
                    elif verb == "C":
                        self.server.state.click(1, x, y)
                    elif verb == "D":
                        self.server.state.press(1, x, y)
                    else:
                        self.server.state.release(1, x, y)
                elif verb in ("B", "P", "R") and len(fields) >= 4:
                    number, x, y = int(fields[1]), int(fields[2]), int(fields[3])
                    if verb == "B":
                        self.server.state.click(number, x, y)
                    elif verb == "P":
                        self.server.state.press(number, x, y)
                    else:
                        self.server.state.release(number, x, y)
                else:
                    raise ValueError("unsupported or malformed command")
        except (UnicodeError, ValueError, OSError) as error:
            print(f"bridge: client {self.client_address}: {error}", file=sys.stderr)
        finally:
            self.server.state.release_all()


class WarpdServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, state):
        self.state = state
        super().__init__(address, WarpdHandler)


def parse_listen(value):
    host, separator, port = value.rpartition(":")
    if not separator or not host:
        raise argparse.ArgumentTypeError("listen address must be HOST:PORT")
    return host, int(port)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=parse_listen, default=("127.0.0.1", 57812))
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    backend = GhidBackend(args.socket)
    state = PointerState(backend)
    with WarpdServer(args.listen, state) as server:
        print(f"bridge: listening on {args.listen[0]}:{args.listen[1]} -> {args.socket}")
        try:
            server.serve_forever()
        finally:
            state.release_all()
            backend.close()


if __name__ == "__main__":
    main()

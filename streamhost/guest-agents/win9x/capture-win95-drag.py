#!/usr/bin/env python3
"""Capture real QMP framebuffers while warpnet drags a Win95 window.

The route returns to the starting title-bar coordinate before button release, so
it leaves the tested window where it started. This helper is intended for an
isolated clone launched by launch-win95-paint-clone.sh.
"""
import argparse
import json
import os
import socket
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument("qmp")
    p.add_argument("warpnet_port", type=int)
    p.add_argument("out_dir")
    p.add_argument("start_x", type=int)
    p.add_argument("start_y", type=int)
    p.add_argument("--settle-ms", type=int, default=45)
    args = p.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    qmp = socket.socket(socket.AF_UNIX)
    qmp.connect(args.qmp)
    qbuf = b""

    def read_reply():
        nonlocal qbuf
        while b"\n" not in qbuf:
            qbuf += qmp.recv(65536)
        line, qbuf = qbuf.split(b"\n", 1)
        return json.loads(line)

    def command(execute, **arguments):
        msg = {"execute": execute}
        if arguments:
            msg["arguments"] = arguments
        qmp.sendall((json.dumps(msg) + "\n").encode("ascii"))
        while True:
            reply = read_reply()
            if "return" in reply or "error" in reply:
                return reply

    read_reply()  # greeting
    command("qmp_capabilities")
    command("human-monitor-command", **{"command-line": "cont"})

    warp = socket.create_connection(("127.0.0.1", args.warpnet_port), 2)

    def send(line):
        warp.sendall((line + "\n").encode("ascii"))

    def shot(frame, label):
        path = os.path.join(args.out_dir, "%03d-%s.ppm" % (frame, label))
        result = command("screendump", filename=path)
        if "error" in result:
            raise RuntimeError(result["error"])

    sx, sy = args.start_x, args.start_y
    route = [
        (sx + 20, sy + 22), (sx + 50, sy + 52),
        (sx + 80, sy + 82), (sx + 110, sy + 112),
        (sx + 140, sy + 142), (sx + 110, sy + 122),
        (sx + 80, sy + 92), (sx + 50, sy + 62),
        (sx + 20, sy + 32), (sx - 10, sy + 12),
        (sx - 40, sy + 32), (sx - 10, sy + 22), (sx, sy),
    ]
    delay = args.settle_ms / 1000.0
    send("M %d %d" % (sx, sy))
    time.sleep(0.15)
    send("P 1 %d %d" % (sx, sy))
    time.sleep(0.08)
    for frame, (x, y) in enumerate(route):
        send("M %d %d" % (x, y))
        time.sleep(delay)
        shot(frame, "x%d-y%d" % (x, y))
    send("R 1 %d %d" % (sx, sy))
    time.sleep(0.25)
    shot(len(route), "released-origin")
    warp.sendall(b"QUIT\n")
    warp.close()
    qmp.close()
    print("captured %d real framebuffers in %s" % (len(route) + 1, args.out_dir))


if __name__ == "__main__":
    main()

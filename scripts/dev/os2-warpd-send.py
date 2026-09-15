#!/usr/bin/env python3
"""os2-warpd-send.py — talk directly to the os2warp in-guest warpd agent over
its COM1 unix-socket serial chardev, using the same newline-delimited M/P/R/B
protocol the streamhost daemon's warpd.rs client speaks (see
streamhost/streamhost/src/warpd.rs and streamhost/guest-agents/os2/warpd_os2.c).

Coordinates are TOP-LEFT guest pixels (the agent flips to PM's bottom-left
origin itself). This is a throwaway dev tool for driving/testing a station's
pointer directly against its serial.sock, without the Rust daemon attached —
used to prove window-drag geometry changes on a sandbox clone before landing
them on the live station.

usage:
  os2-warpd-send.py <serial.sock> move X Y
  os2-warpd-send.py <serial.sock> down BTN X Y
  os2-warpd-send.py <serial.sock> up BTN X Y
  os2-warpd-send.py <serial.sock> drag BTN X0 Y0 X1 Y1 [--steps N] [--step-ms MS]
  os2-warpd-send.py <serial.sock> dblclick BTN X Y
"""

import socket
import sys
import time


def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    return s


def send(s, line):
    s.sendall((line + "\n").encode("ascii"))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    sock_path = sys.argv[1]
    cmd = sys.argv[2]
    args = sys.argv[3:]
    s = connect(sock_path)
    try:
        if cmd == "move":
            x, y = int(args[0]), int(args[1])
            send(s, f"M {x} {y}")
        elif cmd == "down":
            btn, x, y = int(args[0]), int(args[1]), int(args[2])
            send(s, f"M {x} {y}")
            time.sleep(0.05)
            send(s, f"P {btn} {x} {y}")
        elif cmd == "up":
            btn, x, y = int(args[0]), int(args[1]), int(args[2])
            send(s, f"R {btn} {x} {y}")
        elif cmd == "dblclick":
            btn, x, y = int(args[0]), int(args[1]), int(args[2])
            send(s, f"M {x} {y}")
            time.sleep(0.05)
            send(s, f"P {btn} {x} {y}")
            time.sleep(0.05)
            send(s, f"R {btn} {x} {y}")
            time.sleep(0.12)
            send(s, f"P {btn} {x} {y}")
            time.sleep(0.05)
            send(s, f"R {btn} {x} {y}")
        elif cmd == "drag":
            btn = int(args[0])
            x0, y0, x1, y1 = int(args[1]), int(args[2]), int(args[3]), int(args[4])
            steps = 20
            step_ms = 15
            rest = args[5:]
            i = 0
            while i < len(rest):
                if rest[i] == "--steps":
                    steps = int(rest[i + 1])
                    i += 2
                elif rest[i] == "--step-ms":
                    step_ms = int(rest[i + 1])
                    i += 2
                else:
                    i += 1
            send(s, f"M {x0} {y0}")
            time.sleep(0.08)
            send(s, f"P {btn} {x0} {y0}")
            time.sleep(0.08)
            for k in range(1, steps + 1):
                x = x0 + (x1 - x0) * k // steps
                y = y0 + (y1 - y0) * k // steps
                send(s, f"M {x} {y}")
                time.sleep(step_ms / 1000.0)
            time.sleep(0.08)
            send(s, f"R {btn} {x1} {y1}")
        else:
            print(f"unknown cmd {cmd}", file=sys.stderr)
            return 1
    finally:
        time.sleep(0.1)
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""movemouse.py — write Mouse Systems (msys) protocol packets straight onto
PCE's COM1 pty, bypassing PCE's X11 terminal mouse path entirely (THEORY B,
docs/lab/VISION-WAVE.md). Run INSIDE the vision sandbox's mount namespace
(via `nsenter --mount=... --pid=...`) so the symlink at /work/com1.pty
resolves in the CONTAINER's devpts, not the host's.

Packet format copied EXACTLY from PCE's own encoder,
src/drivers/char/char-mouse.c:chr_mouse_add_packet_msys() —
  byte0 = 0x80 | (button1 ? 0 : 0x04) | (button2 ? 0 : 0x01) | (button3 ? 0 : 0x02)
          (buttons are ACTIVE LOW on the wire)
  byte1 = dx   (signed 8-bit, -127..127)
  byte2 = -dy  (PCE writes ~v + 1 of the dy magnitude: screen-down is negative
                on the wire)
  byte3 = 0, byte4 = 0 (the second delta pair PCE's own accumulator only
                        fills on overflow; we never overflow because we chunk)
Mouse Systems is 5-byte binary at 1200 8N1.

Usage:
  movemouse.py <pty-path> move <dx> <dy> [b1 b2 b3]
  movemouse.py <pty-path> click <dx> <dy> <button 1|2|3> [hold_s]
      moves by dx,dy then presses+releases the given button (1=left).
  movemouse.py <pty-path> raw <b1> <b2> <b3> <b4> <b5>   (send exact 5 bytes)

dx/dy larger than 127 in magnitude are chunked into multiple 5-byte packets,
each within -127..127, same as PCE's own clamp-and-carry-remainder loop.
"""
import sys
import os
import termios
import time


def open_pty(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    # raw: no echo, no line editing, no signal chars, 8N1, no flow control
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0
    oflag = 0
    cflag &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
    cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL
    lflag = 0
    termios.tcsetattr(
        fd, termios.TCSANOW,
        [iflag, oflag, cflag, lflag, termios.B1200, termios.B1200, cc],
    )
    return fd


def clamp127(v):
    if v > 127:
        return 127, v - 127
    if v < -127:
        return -127, v + 127
    return v, 0


def encode_packet(dx, dy, buttons):
    b1, b2, b3 = buttons
    v = 0x80
    v |= 0x00 if b1 else 0x04
    v |= 0x00 if b2 else 0x01
    v |= 0x00 if b3 else 0x02
    byte1 = dx & 0xFF
    byte2 = ((-dy) & 0xFF)
    return bytes([v, byte1, byte2, 0, 0])


def send_move(fd, dx, dy, buttons=(False, False, False)):
    """chunk dx/dy into <=127-magnitude packets, one packet minimum so a
    (0,0) button-only change is still delivered."""
    packets = []
    rx, ry = dx, dy
    first = True
    while first or rx != 0 or ry != 0:
        first = False
        px, rx = clamp127(rx)
        py, ry = clamp127(ry)
        packets.append(encode_packet(px, py, buttons))
    for p in packets:
        os.write(fd, p)
        time.sleep(0.02)  # let PCE's UART poll drain each packet
    return len(packets)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    pty_path = sys.argv[1]
    cmd = sys.argv[2]
    fd = open_pty(pty_path)
    try:
        if cmd == "move":
            dx = int(sys.argv[3])
            dy = int(sys.argv[4])
            b = (
                sys.argv[5] == "1" if len(sys.argv) > 5 else False,
                sys.argv[6] == "1" if len(sys.argv) > 6 else False,
                sys.argv[7] == "1" if len(sys.argv) > 7 else False,
            )
            n = send_move(fd, dx, dy, b)
            print(f"move dx={dx} dy={dy} buttons={b} -> {n} packet(s)")
        elif cmd == "click":
            dx = int(sys.argv[3])
            dy = int(sys.argv[4])
            btn = int(sys.argv[5])
            hold = float(sys.argv[6]) if len(sys.argv) > 6 else 0.15
            b = [False, False, False]
            if dx or dy:
                send_move(fd, dx, dy, (False, False, False))
                time.sleep(0.05)
            b[btn - 1] = True
            send_move(fd, 0, 0, tuple(b))
            time.sleep(hold)
            b[btn - 1] = False
            send_move(fd, 0, 0, tuple(b))
            print(f"click dx={dx} dy={dy} button={btn} hold={hold}")
        elif cmd == "raw":
            data = bytes(int(x) & 0xFF for x in sys.argv[3:8])
            os.write(fd, data)
            print(f"raw {data.hex()}")
        else:
            print(f"unknown command {cmd}", file=sys.stderr)
            sys.exit(2)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()

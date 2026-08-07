#!/usr/bin/env python3
# Emulate an Elo SmartSet serial touch controller for devi-elo.
# - Connects to the QEMU serial unix socket (guest /dev/ser1).
# - Reads 10-byte 'U'-framed commands devi-elo sends; replies with an ACK
#   ('U','A',<cmd>,...), so the driver's reset/config handshake succeeds.
# - Listens on a control unix socket for "T <status> <x> <y>" to inject touches.
# Logs all bytes the driver sends to <ctrl>.log for protocol inspection.
import socket, sys, threading, os
ser_path, ctrl_path = sys.argv[1], sys.argv[2]
ser = socket.socket(socket.AF_UNIX); ser.connect(ser_path)
logf = open(ctrl_path + ".log", "wb")

def cksum(b9): return (0xAA + sum(b9)) & 0xFF
def frame(nine): return bytes(nine) + bytes([cksum(nine)])

def send_ack(cmd):
    # Elo SmartSet ACK: 'U','A' + seven ASCII '0' (no-error) status bytes + checksum
    ser.sendall(frame([0x55, 0x41, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30]))

def reader():
    buf = b""
    while True:
        try: d = ser.recv(64)
        except OSError: break
        if not d: break
        logf.write(d); logf.flush()
        buf += d
        while True:
            i = buf.find(b"\x55")
            if i < 0: buf = b""; break
            if len(buf) - i < 10: buf = buf[i:]; break
            pkt = buf[i:i+10]; buf = buf[i+10:]
            send_ack(pkt[1])

threading.Thread(target=reader, daemon=True).start()

def touch(status, x, y):
    ser.sendall(frame([0x55, 0x54, status & 0xFF,
                        x & 0xFF, (x >> 8) & 0xFF,
                        y & 0xFF, (y >> 8) & 0xFF, 0, 0]))

if os.path.exists(ctrl_path): os.unlink(ctrl_path)
cs = socket.socket(socket.AF_UNIX); cs.bind(ctrl_path); cs.listen(5)
sys.stderr.write("elo_ctrl ready\n"); sys.stderr.flush()
while True:
    c, _ = cs.accept()
    data = c.recv(128).decode(errors="replace").split(); c.close()
    if not data: continue
    if data[0] == "T":
        touch(int(data[1]), int(data[2]), int(data[3]))
    elif data[0] == "Q":
        break

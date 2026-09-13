#!/usr/bin/env python3
"""apple2gs-ramprobe.py — PEEK/POKE helpers over a mamectl/1 socket for the apple2gs
abs-ram derivation.  Sub-commands:

  snap  <sock> <out.bin> <bank-hex>     dump one 64 KB bank via PEEK (64 B/call)
  diff  <a.bin> <b.bin> <bank> <ax> <ay> <bx> <by>
        report offsets whose 16-bit LE (and BE) word went from A's coords to B's
  cmd   <sock> <verb...>                one-shot verb

The $xxC000-$xxCFFF window is the IIGS soft-switch/IO shadow: reading it
through the CPU program space has SIDE EFFECTS (it is how the guest talks to
its own hardware), so the sweep skips it and the diff treats it as unknown.
"""
import socket
import struct
import sys

IO_LO, IO_HI = 0xC000, 0xD000   # skipped, per bank

class Ctl:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(60)
        self.s.connect(path); self.f = self.s.makefile("rwb"); self.n = 0
    def cmd(self, c):
        self.n += 1; i = self.n
        self.f.write(f"{i} {c}\n".encode()); self.f.flush()
        while True:
            line = self.f.readline()
            if not line: raise RuntimeError("EOF on ctl socket")
            t = line.decode().rstrip()
            if t.startswith(f"{i} "): return t[len(f"{i} "):]

def snap(sock, out, bank):
    c = Ctl(sock)
    buf = bytearray(b"\x00" * 0x10000)
    for off in range(0, 0x10000, 64):
        if IO_LO <= off < IO_HI: continue
        r = c.cmd(f"PEEK {(bank<<16)|off} 64")
        parts = r.split()
        hexs = parts[-1] if parts else ""
        if not r.startswith("OK") or len(hexs) != 128:
            raise RuntimeError(f"PEEK {off:04x} -> {r!r}")
        buf[off:off+64] = bytes.fromhex(hexs)
    with open(out, "wb") as fh:
        fh.write(bytes(buf))
    print(f"wrote {out} bank ${bank:02x} (IO window ${IO_LO:04x}-${IO_HI-1:04x} skipped)")

def diff(a, b, bank, ax, ay, bx, by):
    with open(a, "rb") as fh:
        A = fh.read()
    with open(b, "rb") as fh:
        B = fh.read()
    ax, ay, bx, by = int(ax), int(ay), int(bx), int(by)
    print(f"# bank ${int(bank,0):02x}: A=({ax},{ay}) B=({bx},{by})")
    for enc, fmt in (("LE", "<H"), ("BE", ">H")):
        for off in range(0, 0x10000 - 1):
            if IO_LO <= off < IO_HI: continue
            va = struct.unpack_from(fmt, A, off)[0]
            vb = struct.unpack_from(fmt, B, off)[0]
            if va == vb: continue
            for name, pa, pb in (("x", ax, bx), ("y", ay, by)):
                if abs(va - pa) <= 2 and abs(vb - pb) <= 2:
                    print(f"{enc} ${int(bank,0):02x}/{off:04x} {name}: {va}->{vb} "
                          f"(want {pa}->{pb})")

if __name__ == "__main__":
    m = sys.argv[1]
    if m == "snap": snap(sys.argv[2], sys.argv[3], int(sys.argv[4], 0))
    elif m == "diff": diff(*sys.argv[2:])
    else:
        c = Ctl(sys.argv[2])
        for v in sys.argv[3:]: print(v, "->", c.cmd(v))

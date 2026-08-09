#!/usr/bin/env python3
"""Read Previous emulator state from the kiosk host side (no guest changes).

Resolves the PIE load base of /usr/local/bin/previous, then the NEXTRam /
NEXTVideo pointers, and exposes raw reads of emulated NeXT memory.
"""

import contextlib
import os
import struct

SYMS = {}


def load_syms(binpath):
    import subprocess

    out = subprocess.run(["nm", "-S", binpath], capture_output=True, text=True).stdout
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3:
            with contextlib.suppress(ValueError):
                SYMS[p[-1]] = int(p[0], 16)


def pid_of(name="previous"):
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                if os.path.basename(os.readlink(f"/proc/{d}/exe")) == name:
                    return int(d)
            except OSError:
                pass
    raise SystemExit("previous not running")


def load_base(pid, binpath):
    st = os.stat(binpath)
    "%02x:%02x %d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    best = None
    for line in open("/proc/%d/maps" % pid):
        if binpath in line:
            a = int(line.split("-")[0], 16)
            off = int(line.split()[2], 16)
            if off == 0:
                return a
            if best is None:
                best = a
    return best


class Mem:
    def __init__(self, binpath="/usr/local/bin/previous"):
        self.bin = binpath
        load_syms(binpath)
        self.pid = pid_of()
        self.base = load_base(self.pid, binpath)
        self.f = open("/proc/%d/mem" % self.pid, "rb", 0)

    def raw(self, addr, n):
        self.f.seek(addr)
        return self.f.read(n)

    def sym(self, name):
        return self.base + SYMS[name]

    def ptr(self, name):
        return struct.unpack("<Q", self.raw(self.sym(name), 8))[0]


if __name__ == "__main__":
    m = Mem()
    print("pid", m.pid, "base", hex(m.base))
    for s in ("NEXTRam", "NEXTRom", "NEXTVideo", "NEXTIo"):
        print(s, hex(m.sym(s)), "->", hex(m.ptr(s)))
    r = m.ptr("NEXTRam")
    print("ram[0:16]", m.raw(r, 16).hex())

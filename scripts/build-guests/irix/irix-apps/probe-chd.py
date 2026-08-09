#!/usr/bin/env python3
"""Read-only probe of an IRIX SGI-disklabel raw image: partitions + XFS space.

Usage: probe-chd.py <raw-image>

Works on a CHD extracted with `chdman extractraw` and on the SGI install CDs
(which are EFS volumes behind the same disk label). Never opens for writing.
"""

import struct
import sys

MIB = 1048576
PT_TYPES = {
    0: "volhdr",
    1: "trkrepl",
    2: "secrepl",
    3: "raw/swap",
    4: "bsd",
    5: "sysv",
    6: "volume(whole disk)",
    7: "efs",
    8: "lvol",
    9: "rlvol",
    10: "xfs",
    11: "xfslog",
    12: "xlv",
    13: "xvm",
}


def dump_volume_directory(vh):
    print("\nvolume directory (bootable files in the volume header):")
    for i in range(15):
        off = 72 + i * 16
        name = vh[off : off + 8].split(b"\0")[0].decode(errors="replace")
        lbn, nbytes = struct.unpack(">ii", vh[off + 8 : off + 16])
        if name:
            print(f"  {name:<8} lbn={lbn:<8} bytes={nbytes}")


def dump_partitions(vh):
    print("\npartition table:")
    parts = []
    for i in range(16):
        off = 312 + i * 12
        nblks, first, ptype = struct.unpack(">iii", vh[off : off + 12])
        if nblks == 0:
            continue
        parts.append((i, nblks, first, ptype))
        kind = PT_TYPES.get(ptype, "?")
        print(f"  {i:2d}  first={first:<10} blocks={nblks:<10} ({nblks * 512 / MIB:9.1f} MiB)  type={ptype} {kind}")
    return parts


def dump_xfs(f, parts):
    print("\nXFS superblocks:")
    for i, _nblks, first, ptype in parts:
        if ptype not in (10, 7):
            continue
        f.seek(first * 512)
        sb = f.read(208)
        if sb[0:4] != b"XFSB":
            print(f"  part {i}: no XFS magic (type {ptype})")
            continue
        bsize = struct.unpack(">I", sb[4:8])[0]
        dblocks = struct.unpack(">Q", sb[8:16])[0]
        fdblocks = struct.unpack(">Q", sb[144:152])[0]
        icount = struct.unpack(">Q", sb[128:136])[0]
        ifree = struct.unpack(">Q", sb[136:144])[0]
        ver = struct.unpack(">H", sb[100:102])[0]
        isize = struct.unpack(">H", sb[104:106])[0]
        agcount = struct.unpack(">I", sb[88:92])[0]
        print(f"  part {i}: blocksize={bsize}  version=0x{ver:04x}  inodesize={isize}  agcount={agcount}")
        print(f"    total  = {dblocks * bsize / MIB:10.1f} MiB")
        print(f"    free   = {fdblocks * bsize / MIB:10.1f} MiB")
        print(f"    used   = {(dblocks - fdblocks) * bsize / MIB:10.1f} MiB")
        print(f"    inodes = {icount} allocated / {ifree} free")


def main(path: str) -> int:
    with open(path, "rb") as f:
        vh = f.read(512)
        if struct.unpack(">I", vh[0:4])[0] != 0x0BE5A941:
            print("not an SGI volume header")
            return 1
        bootfile = vh[4:20].split(b"\0")[0].decode()
        print(f"SGI volume header OK  bootfile={bootfile}")
        dump_volume_directory(vh)
        dump_xfs(f, dump_partitions(vh))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

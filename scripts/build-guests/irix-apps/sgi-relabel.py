#!/usr/bin/env python3
"""Grow the root partition of an IRIX SGI-disklabel raw image, in place.

The image must already have been truncated (extended) to the new total size.
This rewrites the volume header: sectors/track, capacity, partition 0 (root
XFS) length, partition 10 (whole volume) length, and the header checksum.

It does NOT touch the filesystem -- grow that afterwards, preferably IN-GUEST
(`xfs_growfs /` under IRIX), because Linux cannot replay IRIX's XFS log.

Usage: sgi-relabel.py <raw-image> <new-sectors-per-track>

Offsets derived empirically from irix65.chd's volume header
(cyls=128 trks=16 secs=2000 secbytes=512, capacity 4096000):
  vh+0x00 magic 0x0BE5A941
  vh+0x1c u16 cyls        vh+0x20 u16 trks/cyl
  vh+0x26 u16 secs/trk    vh+0x28 u16 bytes/sec
  vh+0x44 u32 capacity in sectors
  vh+0x48 volume directory (15 x 16 bytes)
  vh+0x138 partition table (16 x 12 bytes: nblks, first, type, all be32)
  vh+0x1f8 be32 checksum (all 128 be32 words of the header sum to 0)
"""

import struct
import sys

MAGIC = 0x0BE5A941
MIB = 1048576
OFF_CYLS = 0x1C
OFF_TRKS = 0x20
OFF_SECS = 0x26
OFF_SECBYTES = 0x28
OFF_CAPACITY = 0x44
OFF_PT = 0x138
OFF_CSUM = 0x1F8
PT_XFS = 10
PT_VOLUME = 6


def partitions(vh):
    out = []
    for i in range(16):
        off = OFF_PT + i * 12
        nblks, first, ptype = struct.unpack(">iii", vh[off : off + 12])
        out.append((i, nblks, first, ptype))
    return out


def u16(vh, off):
    return struct.unpack(">H", vh[off : off + 2])[0]


def relabel(f, new_secs):
    vh = bytearray(f.read(512))
    if struct.unpack(">I", vh[0:4])[0] != MAGIC:
        print("not an SGI volume header", file=sys.stderr)
        return 1
    cyls, trks = u16(vh, OFF_CYLS), u16(vh, OFF_TRKS)
    secs, secbytes = u16(vh, OFF_SECS), u16(vh, OFF_SECBYTES)
    cap = struct.unpack(">I", vh[OFF_CAPACITY : OFF_CAPACITY + 4])[0]
    print(f"old geometry: cyls={cyls} trks={trks} secs={secs} bytes/sec={secbytes} capacity={cap}")
    if cap != cyls * trks * secs:
        print("capacity field does not match CHS -- refusing", file=sys.stderr)
        return 1
    if new_secs <= secs:
        print(f"new sectors/track must be larger than {secs}", file=sys.stderr)
        return 1

    new_cap = cyls * trks * new_secs
    f.seek(0, 2)
    filesize = f.tell()
    if filesize != new_cap * secbytes:
        print(
            f"image is {filesize} bytes, expected {new_cap * secbytes} (truncate it first)",
            file=sys.stderr,
        )
        return 1

    root = [p for p in partitions(vh) if p[3] == PT_XFS and p[1]]
    vol = [p for p in partitions(vh) if p[3] == PT_VOLUME and p[1]]
    if len(root) != 1 or len(vol) != 1:
        print("expected exactly one xfs and one whole-volume partition", file=sys.stderr)
        return 1
    ri, rblks, rfirst, _ = root[0]
    vi, vblks, _, _ = vol[0]
    new_rblks = new_cap - rfirst
    print(
        f"root part {ri}: {rblks} -> {new_rblks} blocks "
        f"({rblks * secbytes / MIB:.1f} -> {new_rblks * secbytes / MIB:.1f} MiB)"
    )
    print(f"volume part {vi}: {vblks} -> {new_cap} blocks")

    struct.pack_into(">H", vh, OFF_SECS, new_secs)
    struct.pack_into(">I", vh, OFF_CAPACITY, new_cap)
    struct.pack_into(">i", vh, OFF_PT + ri * 12, new_rblks)
    struct.pack_into(">i", vh, OFF_PT + vi * 12, new_cap)

    struct.pack_into(">i", vh, OFF_CSUM, 0)
    total = sum(struct.unpack(">128i", bytes(vh)))
    struct.pack_into(">I", vh, OFF_CSUM, (-total) & 0xFFFFFFFF)
    check = sum(struct.unpack(">128i", bytes(vh))) & 0xFFFFFFFF
    if check != 0:
        print(f"checksum recompute failed ({check:08x})", file=sys.stderr)
        return 1

    f.seek(0)
    f.write(bytes(vh))
    f.flush()
    print(f"volume header rewritten; now grow the filesystem on partition {ri} (offset {rfirst * secbytes} bytes)")
    return 0


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    with open(argv[1], "r+b") as f:
        return relabel(f, int(argv[2]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))

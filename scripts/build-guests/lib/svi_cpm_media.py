#!/usr/bin/env python3
"""Compose the hash-pinned SVI CP/M 2.24 native ImageDisk system image.

MAME's SVI layout preserves track 0/head 0 as 18x128 FM bytes, then
79 heads of 17x256 MFM bytes. This disk's CP/M directory begins at
cylinder 3/head 0, contains 64 entries, and allocates 2048-byte blocks
with EXM=1. CP/M traverses head 0 cylinders 3..39, then head 1 cylinders
0..39; MAME raw SVI images interleave heads per cylinder. The ImageDisk
sector IDs establish the physical order before this logical overlay.
The output retains ImageDisk track headers and the physical sector interleave.
"""

import argparse
import hashlib
from pathlib import Path

SYSTEM_SHA1 = "2326ad4de147638194645df82ea9e803cea4eb79"
BASIC_SHA256 = "29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157"
BASE = 0
BLOCK = 2048


def decode_imd(image: bytes) -> dict[tuple[int, int], bytes]:
    """Decode the pinned sector IDs, density and compressed sectors."""
    cursor = image.index(0x1A) + 1
    tracks = {}
    while cursor < len(image):
        mode, cylinder, head, count, size_code = image[cursor : cursor + 5]
        cursor += 5
        if mode not in (2, 5) or size_code not in (0, 1) or head & 0xC0:
            raise ValueError("unexpected ImageDisk geometry")
        identifiers = image[cursor : cursor + count]
        cursor += count
        size = 128 << size_code
        sectors = {}
        for identifier in identifiers:
            kind = image[cursor]
            cursor += 1
            if kind == 1:
                data = image[cursor : cursor + size]
                cursor += size
            elif kind == 2:
                data = bytes([image[cursor]]) * size
                cursor += 1
            else:
                raise ValueError("missing, deleted or damaged ImageDisk sector")
            sectors[identifier] = data
        tracks[cylinder, head] = b"".join(sectors[key] for key in sorted(sectors))
    if set(tracks) != {(track, head) for track in range(40) for head in range(2)}:
        raise ValueError("incomplete double-sided image")
    return tracks


def encode_imd(system: bytes, tracks: dict[tuple[int, int], bytes]) -> bytes:
    """Retain the native physical sector interleave and density headers."""
    cursor = system.index(0x1A) + 1
    output = bytearray(system[:cursor])
    while cursor < len(system):
        _, cylinder, head, count, size_code = system[cursor : cursor + 5]
        output.extend(system[cursor : cursor + 5 + count])
        cursor += 5
        identifiers = system[cursor : cursor + count]
        cursor += count
        size = 128 << size_code
        for identifier in identifiers:
            kind = system[cursor]
            cursor += 1 + (size if kind == 1 else 1)
            start = (identifier - 1) * size
            data = tracks[cylinder, head][start : start + size]
            if data == data[:1] * size:
                output.extend(b"\x02" + data[:1])
            else:
                output.extend(b"\x01" + data)
    return bytes(output)


def compose(system: bytes, basic: bytes) -> bytes:
    if hashlib.sha1(system).hexdigest() != SYSTEM_SHA1:
        raise ValueError("system disk differs from the pinned MAME cpm224dd ImageDisk image")
    if hashlib.sha256(basic).hexdigest() != BASIC_SHA256:
        raise ValueError("MBASIC.COM differs from the pinned acquisition")
    tracks = decode_imd(system)
    order = [(track, 0) for track in range(3, 40)] + [(track, 1) for track in range(40)]
    disk = bytearray(b"".join(tracks[key] for key in order))
    used = {0}
    free_entries = []
    for index in range(64):
        off = BASE + index * 32
        entry = disk[off : off + 32]
        if entry[0] == 0xE5:
            free_entries.append(off)
        else:
            used.update(block for block in entry[16:32] if block)
    files = {
        "MBASIC.COM": basic,
        "WELCOME.TXT": (
            b"SPECTRAVIDEO SV-328: CP/M-80 2.24\r\n"
            b"80 columns, SV-601 expander, SV-801 disks, SV-806 display.\r\n"
            b"Type mbasic, then enter numbered lines and RUN. SYSTEM returns to CP/M.\r\n"
            b"The Type demo program button enters an original BASIC program. Press Enter to RUN.\r\n"
            b"DIR lists files. TYPE WELCOME.TXT reads this page. Reset clears edits.\r\n\x1a"
        ),
    }
    for filename, data in files.items():
        if len(data) > 32768 or not free_entries:
            raise ValueError("file or directory capacity exceeded")
        stem, suffix = filename.split(".")
        count = (len(data) + BLOCK - 1) // BLOCK
        blocks = [n for n in range(1, (len(disk) - BASE) // BLOCK) if n not in used][:count]
        if len(blocks) != count:
            raise ValueError("disk full")
        off = free_entries.pop(0)
        entry = bytearray(32)
        entry[1:12] = (stem.ljust(8) + suffix.ljust(3)).encode("ascii")
        records = (len(data) + 127) // 128
        entry[12] = (records - 1) // 128
        entry[15] = records - entry[12] * 128
        entry[16 : 16 + count] = bytes(blocks)
        disk[off : off + 32] = entry
        for i, block in enumerate(blocks):
            payload = data[i * BLOCK : (i + 1) * BLOCK].ljust(BLOCK, b"\x1a")
            disk[BASE + block * BLOCK : BASE + (block + 1) * BLOCK] = payload
        used.update(blocks)
    for index, key in enumerate(order):
        tracks[key] = bytes(disk[index * 4352 : (index + 1) * 4352])
    return encode_imd(system, tracks)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system", type=Path)
    parser.add_argument("basic", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(compose(args.system.read_bytes(), args.basic.read_bytes()))
    print(hashlib.sha256(args.output.read_bytes()).hexdigest(), args.output)


if __name__ == "__main__":
    main()

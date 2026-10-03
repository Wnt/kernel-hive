#!/usr/bin/env python3
"""Prepare a stock SVI-738 CP/M disk with MBASIC and museum-authored examples.

Input is the independently converted 80-track, single-sided release 2.1 disk.
Its DPB uses 2K allocation blocks, EXM=1, 64 directory entries and 3 boot tracks.
Keep the system/utility files; replace the archive owner's personal applications.
"""

import hashlib
import sys
from pathlib import Path

SOURCE_SHA256 = "211ece6190bb9beb09fcfb03d7f008efe87f33cf32f1de60ba6cf480b3899dda"
BASIC_SHA256 = "29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157"
BASE = 3 * 9 * 512
BLOCK = 2048
KEEP = {
    "PIP.COM",
    "DDT.COM",
    "DUMP.COM",
    "DDT80.COM",
    "XSUB.COM",
    "SUBMIT.COM",
    "STAT.COM",
    "COLOR.COM",
    "RS232.COM",
    "BACKUP.COM",
    "FILECOPY.COM",
    "FORMAT.COM",
    "EDITFKEY.COM",
    "ASM.COM",
    "TERMTYPE.COM",
    "SYSGEN.COM",
    "LOADFKEY.COM",
    "LOAD.COM",
    "ED.COM",
    "CBIOS.ASM",
}


def verified(path, digest):
    data = Path(path).read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"unexpected source hash: {path}")
    return data


def compose(source, basic):
    image = bytearray(source)
    if len(image) != 368640:
        raise ValueError("expected 80x1x9x512 disk")
    used = {0}
    free_entries = []
    for offset in range(BASE, BASE + BLOCK, 32):
        entry = image[offset : offset + 32]
        name = bytes(x & 127 for x in entry[1:9]).decode("ascii").rstrip()
        ext = bytes(x & 127 for x in entry[9:12]).decode("ascii").rstrip()
        if entry[0] == 0 and f"{name}.{ext}" in KEEP:
            used.update(x for x in entry[16:32] if x)
        else:
            image[offset : offset + 32] = b"\xe5" * 32
            free_entries.append(offset)
    free = [b for b in range(1, 173) if b not in used]
    files = {
        "MBASIC.COM": basic,
        "HELLO.BAS": (
            b'10 PRINT "HELLO FROM SPECTRAVIDEO CP/M"\r\n'
            b"20 FOR I=1 TO 8\r\n"
            b"30 PRINT I;I*I\r\n"
            b"40 NEXT I\r\n"
            b"50 END\r\n"
            b"\x1a"
        ),
        "WELCOME.TXT": (
            b"SPECTRAVIDEO SVI-738 / CP/M 2.2\r\n"
            b"\r\n"
            b"Try: DIR, TYPE WELCOME.TXT, STAT CON:=UC1:\r\n"
            b'MBASIC starts Microsoft BASIC. RUN "HELLO" loads an example.\r\n'
            b"SYSTEM returns to CP/M. Reset restores this working disk.\r\n"
            b"This system disk uses the International CP/M keyboard.\r\n"
            b"\x1a"
        ),
    }
    for name, data in files.items():
        records = (len(data) + 127) // 128
        count = (len(data) + BLOCK - 1) // BLOCK
        if count > 16 or len(free) < count or not free_entries:
            raise ValueError("fixture file exceeds supported extent or disk capacity")
        blocks, free = free[:count], free[count:]
        stem, ext = name.split(".")
        entry = bytearray(32)
        entry[1:12] = (stem.ljust(8) + ext.ljust(3)).encode("ascii")
        entry[12] = (records - 1) // 128
        entry[15] = (records - 1) % 128 + 1
        entry[16 : 16 + count] = bytes(blocks)
        offset = free_entries.pop(0)
        image[offset : offset + 32] = entry
        for i, block in enumerate(blocks):
            payload = data[i * BLOCK : (i + 1) * BLOCK].ljust(BLOCK, b"\x1a")
            offset = BASE + block * BLOCK
            image[offset : offset + BLOCK] = payload
    return image


def main():
    source, basic, output = sys.argv[1:]
    image = compose(verified(source, SOURCE_SHA256), verified(basic, BASIC_SHA256))
    Path(output).write_bytes(image)
    print(hashlib.sha256(image).hexdigest(), output)


if __name__ == "__main__":
    main()

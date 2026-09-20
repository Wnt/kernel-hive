#!/usr/bin/env python3
"""Build the 4.3BSD SIMH distribution tape (43.tap) from the TUHS files.

Block sizes and file order are the 4.3BSD distribution's own (see FORMAT in the
TUHS directory, and mkdisttap.pl on the Computer History Wiki): `stand` is a
512-byte-record file, everything after it is 10240. Each record is written as
<LE32 length><data><LE32 length>; a zero-length record is a tape mark (EOF), and
two in a row are end of tape.

Run in a directory holding the DECOMPRESSED stand/miniroot/rootdump/usr.tar.
"""

import struct
import sys

SPECS = [("stand", 512), ("miniroot", 10240), ("rootdump", 10240), ("usr.tar", 10240)]


def main(dest):
    with open(dest, "wb") as out:
        for name, bs in SPECS:
            with open(name, "rb") as f:
                while True:
                    b = f.read(bs)
                    if not b:
                        break
                    if len(b) < bs:
                        b += b"\x00" * (bs - len(b))
                    h = struct.pack("<I", len(b))
                    out.write(h)
                    out.write(b)
                    out.write(h)
            out.write(b"\x00\x00\x00\x00")  # tape mark
        out.write(b"\x00\x00\x00\x00")  # second mark = end of tape


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "43.tap")

#!/usr/bin/env python3
"""Screendump a shm-capture tile: read the published framebuffer, write a PPM.

Tiles with SH_CAPTURE=shm (today: irix) run their emulator with `-video none`.
There is no window, no X server and no QMP monitor — MAME's Newport device
publishes each finished frame straight into SH_SHM_PATH and the daemon maps it.
Nothing in the usual screenshot toolbox can see that: a QMP screendump has no
monitor to talk to, and an x11spike GetImage against the tile's (unused)
SH_X11_DISPLAY succeeds and returns an entirely black image. That last one is
the dangerous case — a valid PNG of nothing, exit code 0 — and it is why this
tool exists.

WIRE FORMAT (producer: MAME src/devices/bus/gio64/newport.cpp, env-gated on
IRIX_SHM_PATH; consumer: streamhost/src/capture/shm.rs, which documents it):

    off  type  field
      0  u32   magic 'IFB1' (0x31424649 little-endian)
      4  u32   version (1)
      8  u32   width
     12  u32   height
     16  u32   stride (bytes per row)
     20  u32   bpp (32)
     24  u64   sequence (seqlock)
     32  u32   dirty_x0   36 u32 dirty_y0   40 u32 dirty_x1   44 u32 dirty_y1
     64        pixels, host-endian XRGB8888 (B,G,R,X in memory on x86)

SYNCHRONISATION is a seqlock with one producer and any number of readers. The
sequence goes ODD before pixels are touched and EVEN after, so a reader takes it
before and after copying and retries while it was odd or changed. A torn frame
is never accepted.

This writes a PPM rather than a PNG so that the one PPM->PNG converter cascade
(PIL / pnmtopng / ffmpeg) stays in labctl instead of being duplicated here.

Usage: shmshot.py <fb.shm> <out.ppm>
"""

import mmap
import os
import struct
import sys
import time

HEADER = 64
MAGIC = 0x31424649  # 'IFB1'
VERSION = 1
MAX_TEARS = 16
TEAR_WAIT = 0.005
# A sanity bound on the geometry a header may claim, so a corrupt or
# partially-written header cannot make us allocate wildly.
MAX_DIM = 16384


def die(msg):
    sys.stderr.write(f"shmshot: {msg}\n")
    raise SystemExit(1)


def read_frame(path):
    """Return (width, height, stride, pixels) for one untorn frame.

    Every failure here is loud. The whole point of this tool is that the
    previous screenshot path answered "success, black image" when it was in
    fact looking at the wrong thing entirely.
    """
    if not os.path.exists(path):
        die(f"no framebuffer at {path} — is the tile running?")
    with open(path, "rb") as fh:
        size = os.fstat(fh.fileno()).st_size
        if size < HEADER:
            die(f"{path} is {size} bytes, shorter than the {HEADER}-byte header")
        mm = mmap.mmap(fh.fileno(), 0, prot=mmap.PROT_READ)
    try:
        magic, version, w, h, stride, bpp = struct.unpack_from("<IIIIII", mm, 0)
        if magic != MAGIC:
            die(
                f"bad magic 0x{magic:08x} at {path} (want 0x{MAGIC:08x} 'IFB1') — the producer "
                "has not published a frame, or this is not a framebuffer file"
            )
        if version != VERSION:
            die(f"unsupported wire version {version} at {path} (this tool speaks {VERSION})")
        if bpp != 32:
            die(f"unsupported bpp {bpp} at {path} (expected 32)")
        if not (0 < w <= MAX_DIM and 0 < h <= MAX_DIM):
            die(f"implausible geometry {w}x{h} at {path}")
        if stride < w * 4:
            die(f"stride {stride} cannot hold {w} pixels at {path}")
        need = HEADER + stride * h
        if size < need:
            die(f"{path} is {size} bytes, needs {need} for a {w}x{h} frame")

        for _ in range(MAX_TEARS):
            before = struct.unpack_from("<Q", mm, 24)[0]
            if before % 2:  # producer is mid-write
                time.sleep(TEAR_WAIT)
                continue
            pixels = mm[HEADER:need]
            after = struct.unpack_from("<Q", mm, 24)[0]
            if after == before:
                return w, h, stride, pixels
            time.sleep(TEAR_WAIT)
        die(f"could not read an untorn frame from {path} in {MAX_TEARS} tries")
    finally:
        mm.close()


def to_rgb(w, h, stride, pixels):
    """XRGB8888 (B,G,R,X in memory) -> packed RGB, dropping any stride padding.

    Done with strided slice assignment rather than a per-pixel loop: a 1288x1024
    frame is 1.3M pixels and the naive version takes seconds.
    """
    row_bytes = w * 4
    if stride != row_bytes:
        packed = bytearray(row_bytes * h)
        for y in range(h):
            src = y * stride
            packed[y * row_bytes : (y + 1) * row_bytes] = pixels[src : src + row_bytes]
        pixels = bytes(packed)
    rgb = bytearray(w * h * 3)
    rgb[0::3] = pixels[2::4]
    rgb[1::3] = pixels[1::4]
    rgb[2::3] = pixels[0::4]
    return bytes(rgb)


def main(argv):
    if len(argv) != 2:
        die("usage: shmshot.py <fb.shm> <out.ppm>")
    path, out = argv
    w, h, stride, pixels = read_frame(path)
    rgb = to_rgb(w, h, stride, pixels)
    tmp = out + ".part"
    with open(tmp, "wb") as fh:
        fh.write(f"P6\n{w} {h}\n255\n".encode())
        fh.write(rgb)
    os.replace(tmp, out)
    print(f"{w}x{h}")


if __name__ == "__main__":
    main(sys.argv[1:])

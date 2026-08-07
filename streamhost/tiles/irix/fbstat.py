#!/usr/bin/env python3
"""Largest per-channel mean of the framebuffer MAME publishes into a shm mapping.

The IRIX tile's boot watchdog (`x11-runtime.sh --bootwatch`) decides "is the
framebuffer pure black" from the REAL framebuffer, never from log inference —
that is what makes it safe to relaunch a wedged boot. In `IRIX_CAPTURE=x11` mode
it grabs the Xvfb root with ImageMagick `import` + `identify`. In
`IRIX_CAPTURE=shm` mode MAME runs `-video none`: there is no window and no X
server to grab, so the same number has to come from the published mapping.

Prints one float, normalised 0..1, matching
`identify -format '%[fx:max(mean.r,max(mean.g,mean.b))]'` so `IRIX_BLACK_EPS`
keeps its meaning across both modes. Exits non-zero (printing nothing) when the
mapping is absent or has no valid header yet, which the watchdog reads as "could
not look" — never as "black".

With `--sig` it prints a second field: a hash of the sampled pixels, i.e. a
cheap "has this frame changed at all" signature (the same role
`identify -format '%#'` plays on the x11 path). The liveness watchdog uses it to
tell a frozen guest from a merely idle one — see `x11-runtime.sh --livewatch`.

With `--cursor` it prints `x y npix` for the IRIX pointer instead: the guest's
cursor is the only bright red object on an SGI-blue desktop, so a colour mask
locates it exactly. That is what the liveness probe actually wants to know —
"did the pointer I just nudged move" — and it is the one question the `--sig`
signature cannot answer reliably, because that signature samples every 64th
pixel and a ~50-pixel cursor can move right through it without changing a single
sampled byte. `--cursor` scans the WHOLE frame; it costs ~10 ms and runs only
when the watchdog is probing, not on the 15 s black-screen sample.

Every 64th pixel is sampled (for the mean and the signature): ample to decide
pure-black, and cheap enough for a check that runs every 15 s for the life of
the exhibit.

Wire format is documented in streamhost/streamhost/src/capture/shm.rs.
"""

import hashlib
import mmap
import struct
import sys

MAGIC = 0x31424649  # 'IFB1'
HEADER = 64
STRIDE = 64 * 4  # sample one pixel in every 64
# The pointer is the only saturated red on this desktop; the SGI blue root, the
# grey panels and the icons all fail this test.
CUR_R, CUR_GB = 180, 90


def cursor(m, w: int, h: int) -> int:
    """Print `x y npix` for the red pointer. numpy is imported here, not at
    module scope, so the black-screen path this file exists for keeps working on
    a host without it."""
    import numpy as np

    a = np.frombuffer(m, dtype=np.uint8, count=w * h * 4, offset=HEADER)
    a = a.reshape(h, w, 4)
    # Pixels are BGRA (see capture/shm.rs).
    mask = (a[:, :, 2] > CUR_R) & (a[:, :, 1] < CUR_GB) & (a[:, :, 0] < CUR_GB)
    ys, xs = np.nonzero(mask)
    n = int(len(xs))
    if not n:
        print("-1 -1 0")
    else:
        print("%d %d %d" % (int(xs.mean()), int(ys.mean()), n))
    del a, mask, ys, xs
    return 0


def main() -> int:
    flags = {"--sig", "--cursor"}
    args = [a for a in sys.argv[1:] if a not in flags]
    want_sig = "--sig" in sys.argv[1:]
    want_cursor = "--cursor" in sys.argv[1:]
    if len(args) != 1:
        return 2
    try:
        with open(args[0], "rb") as f:
            m = mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ)
    except OSError:
        return 1
    try:
        magic, _ver, w, h = struct.unpack_from("<IIII", m, 0)
        if magic != MAGIC or w == 0 or h == 0:
            return 1
        need = HEADER + w * h * 4
        if len(m) < need:
            return 1
        if want_cursor:
            return cursor(m, w, h)
        acc = [0, 0, 0]
        n = 0
        digest = hashlib.blake2b(digest_size=8) if want_sig else None
        # A memoryview would avoid the per-sample slice, but it keeps an exported
        # pointer alive and then `mmap.close()` raises BufferError — which turned
        # a perfectly good reading into exit 1, i.e. "could not look".
        for off in range(HEADER, need - 4, STRIDE):
            acc[0] += m[off]
            acc[1] += m[off + 1]
            acc[2] += m[off + 2]
            n += 1
            if digest is not None:
                digest.update(m[off : off + 3])
        if n == 0:
            return 1
        out = "%.6f" % (max(acc) / (n * 255.0))
        if digest is not None:
            out += " " + digest.hexdigest()
        print(out)
        return 0
    finally:
        m.close()


if __name__ == "__main__":
    sys.exit(main())

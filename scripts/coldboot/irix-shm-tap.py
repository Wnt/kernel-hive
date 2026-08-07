#!/usr/bin/env python3
"""Constant-rate BGRA sampler for the IRIX tile's fb.shm — the boot-video tap.

The boot-video recorder (scripts/coldboot/record-boot.sh) feeds ffmpeg from a
producer honouring the SH_DBUS_TAP contract: constant-size raw BGRA frames at a
constant fps, clean EOF on SIGTERM. The IRIX exhibit has no QEMU dbus display
to tap — MAME runs `-video none` and publishes finished frames into a
file-backed mapping (wire format + seqlock:
streamhost/streamhost/src/capture/shm.rs; proven minimal reader:
scripts/build-guests/irix-bench/shmpng.py). This sampler bridges the two, so
the downstream `-f rawvideo` encode line stays the house one, unchanged.

  irix-shm-tap.py <fb.shm> <WxH> <fps>        # e.g. fb.shm 1288x1024 30

Contract points (mirroring the SH_DBUS_TAP producer, record-boot.sh header):
  * emits from the very first tick — a black canvas until MAME publishes a
    valid frame (the black lead-in is wanted: recording starts before MAME
    paints anything);
  * a frame goes out on EVERY tick even when the sampler falls behind (skip
    the sleeps, never the frames) — CFR is what `-framerate` expects;
  * the producer file appearing, growing or being recreated is handled by
    remapping (MAME re-ftruncates when IRIX reprograms the VC2 mid-boot:
    1280x1024 -> 1288x1024, see shm.rs); geometry smaller than the canvas is
    centre-letterboxed onto black;
  * SIGTERM/SIGINT finish the in-flight frame, flush and exit 0 — the closed
    pipe is ffmpeg's EOF, which finalizes the recording.
"""

import contextlib
import mmap
import os
import signal
import struct
import sys
import time

import numpy as np

MAGIC = 0x31424649  # 'IFB1'
HEADER = 64
SEQ_OFF = 24  # u64 seqlock (shm.rs wire format)
MAX_DIM = 4096
MAX_TEARS = 6  # bounded seqlock retries per tick; then keep the last good frame

_stop = []


def _on_signal(signum, _frame):
    # Only flag it: the emit loop finishes the in-flight frame (the write is
    # EINTR-retried around the handler), then flushes and returns 0 so ffmpeg
    # finalizes on a clean EOF instead of a mid-frame truncation.
    _stop.append(signum)


class Mapping:
    """A read-only mapping of the producer file, keyed by (inode, size).

    MAME recreates the file on relaunch and re-ftruncates it on the VC2
    reprogram, so mapping identity is stat-based: any inode or size change
    means this mapping is stale and must be reopened before its header can be
    trusted — a consumer that kept the old, smaller mapping and then trusted
    the new header would read straight off the end of its map (shm.rs).
    """

    def __init__(self, path):
        fd = os.open(path, os.O_RDONLY)
        try:
            st = os.fstat(fd)
            self.ino, self.size = st.st_ino, st.st_size
            self.mm = mmap.mmap(fd, self.size, access=mmap.ACCESS_READ)
        finally:
            os.close(fd)  # POSIX keeps the mapping alive past the fd

    def close(self):
        # A stray numpy export would keep the map alive until GC; harmless
        # (read-only), so suppress rather than crash the sampler mid-recording.
        with contextlib.suppress(BufferError):
            self.mm.close()

    def seq(self):
        return struct.unpack_from("<Q", self.mm, SEQ_OFF)[0]

    def geometry(self):
        """(w, h, stride) if the header is valid AND this mapping can back it.

        The header is written by ANOTHER process; geometry the mapping cannot
        back (mid-resize — the producer ftruncates before it publishes) must
        yield None rather than an out-of-bounds read, exactly as shm.rs
        refuses rather than faults.
        """
        magic, ver, w, h, stride, bpp = struct.unpack_from("<6I", self.mm, 0)
        if magic != MAGIC or ver != 1 or bpp != 32:
            return None
        if not (0 < w <= MAX_DIM and 0 < h <= MAX_DIM) or stride < w * 4:
            return None
        if HEADER + (h - 1) * stride + w * 4 > self.size:
            return None
        return w, h, stride


def ensure_mapping(path, m):
    """Return a mapping matching the file's current (inode, size), or None.

    ENOENT, a header-less stub and a failed open all yield None — the caller
    keeps re-emitting its last frame, per the contract. A held mapping is
    dropped on ANY stat mismatch (same-inode truncation would otherwise leave
    reads SIGBUS-able).
    """
    try:
        st = os.stat(path)
    except OSError:
        if m is not None:
            m.close()
        return None
    if st.st_size < HEADER:
        if m is not None:
            m.close()
        return None
    if m is not None and st.st_ino == m.ino and st.st_size == m.size:
        return m
    if m is not None:
        m.close()
    try:
        return Mapping(path)
    except (OSError, ValueError):
        return None  # lost a race with the producer; next tick retries


def read_frame(m, w, h, stride):
    """Tear-free copy of one frame as (seq, HxWx4 array), or None.

    The seqlock protocol is shm.rs's: accept only a copy bracketed by the SAME
    even sequence number; bounded retries, then the caller keeps its last good
    frame so a fast producer cannot spin us past the tick.
    """
    # The last row is only w*4 wide, not a full stride (shm.rs pixel_bytes_needed).
    need = (h - 1) * stride + w * 4
    for _ in range(MAX_TEARS):
        seq = m.seq()
        if seq & 1:
            continue  # producer mid-write
        flat = np.frombuffer(m.mm, dtype=np.uint8, count=need, offset=HEADER)
        rows = np.lib.stride_tricks.as_strided(flat, shape=(h, w * 4), strides=(stride, 1))
        px = np.array(rows)  # THE copy — everything after this is our own memory
        if m.seq() == seq:
            return seq, px.reshape(h, w, 4)
    return None


def log(msg):
    print(f"[irix-shm-tap] {msg}", file=sys.stderr, flush=True)


def blit(canvas, px):
    """Centre px onto canvas: letterbox on black (centre-crop if ever larger)."""
    ch, cw = canvas.shape[0], canvas.shape[1]
    h, w = px.shape[0], px.shape[1]
    bh, bw = min(h, ch), min(w, cw)
    canvas[(ch - bh) // 2 : (ch - bh) // 2 + bh, (cw - bw) // 2 : (cw - bw) // 2 + bw] = px[
        (h - bh) // 2 : (h - bh) // 2 + bh, (w - bw) // 2 : (w - bw) // 2 + bw
    ]


def main():
    try:
        path, wh, fps_s = sys.argv[1:4]
        cw, ch = (int(v) for v in wh.split("x"))
        fps = float(fps_s)
        if len(sys.argv) != 4 or cw <= 0 or ch <= 0 or fps <= 0:
            raise ValueError
    except ValueError:
        print("usage: irix-shm-tap.py <fb.shm> <WxH> <fps>", file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    out = sys.stdout.buffer
    canvas = np.zeros((ch, cw, 4), dtype=np.uint8)
    log(f"canvas {cw}x{ch} @{fps:g}fps <- {path} (black until the producer publishes)")

    m = None
    geom = None  # accepted (w, h, stride)
    last_seq = None  # seqlock value of the frame currently on the canvas
    period = 1.0 / fps
    next_t = time.monotonic()
    while not _stop:
        m = ensure_mapping(path, m)
        if m is not None:
            g = m.geometry()
            if g is not None and g != geom:
                # One line per remap/geometry change, NEVER per frame. The
                # stat check above already reopened the mapping for the size
                # change that accompanies a resize; here the canvas state
                # resets so old letterbox bars re-blacken.
                old = "unmapped" if geom is None else f"{geom[0]}x{geom[1]} stride {geom[2]}"
                log(f"geometry {old} -> {g[0]}x{g[1]} stride {g[2]}")
                geom = g
                last_seq = None
                canvas.fill(0)
            if g is not None and m.seq() != last_seq:
                # seq unchanged == pixels unchanged (one writer, bumps per
                # publish): skip the 5 MB copy and re-emit the canvas as-is.
                got = read_frame(m, *g)
                if got is not None:
                    last_seq, px = got
                    blit(canvas, px)
        try:
            out.write(canvas)  # C-contiguous uint8 => raw BGRA bytes, no copy
        except BrokenPipeError:
            log("downstream closed the pipe (ffmpeg died?) — aborting")
            # Repoint stdout at /dev/null so interpreter-exit flushing cannot
            # raise a second BrokenPipeError over the real cause.
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            return 1
        next_t += period
        delay = next_t - time.monotonic()
        if delay > 0:
            time.sleep(delay)  # behind schedule => skip the sleep, never the frame
    out.flush()  # process exit closes the fd -> ffmpeg sees EOF and finalizes
    log(f"signal {_stop[0]} -> clean EOF after flush")
    return 0


if __name__ == "__main__":
    sys.exit(main())

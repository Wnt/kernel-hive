#!/usr/bin/env python3
"""NSPTR-flatten-accel measurement instrument.

Subcommands
  blobs A B          - bounding boxes of the connected changed regions between
                       two PPM screendumps (used to find the cursor by motion)
  mktemplate A B OUT - build a cursor template + opacity mask from two frames
                       that differ only by the cursor having moved on a plain
                       background
  locate T FRAME     - exact-match the template in FRAME; prints every hit
"""

import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def changed(a, b):
    return (a != b).any(axis=2)


def blobs(mask, gap=6):
    """Group changed pixels into rectangles; merge boxes closer than `gap`."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return []
    boxes = []
    for x, y in zip(xs.tolist(), ys.tolist()):
        for b in boxes:
            if b[0] - gap <= x <= b[2] + gap and b[1] - gap <= y <= b[3] + gap:
                b[0] = min(b[0], x)
                b[1] = min(b[1], y)
                b[2] = max(b[2], x)
                b[3] = max(b[3], y)
                break
        else:
            boxes.append([x, y, x, y])
    merged = True
    while merged:
        merged = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                if a[0] - gap <= b[2] and b[0] - gap <= a[2] and a[1] - gap <= b[3] and b[1] - gap <= a[3]:
                    boxes[i] = [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
                    boxes.pop(j)
                    merged = True
                    break
            if merged:
                break
    return boxes


def cmd_blobs(argv):
    a, b = load(argv[0]), load(argv[1])
    m = changed(a, b)
    for x0, y0, x1, y1 in sorted(blobs(m), key=lambda r: (r[1], r[0])):
        print(f"blob x[{x0}..{x1}] y[{y0}..{y1}] size {x1 - x0 + 1}x{y1 - y0 + 1}")
    print(f"changed_px {int(m.sum())}")


def cmd_mktemplate(argv):
    """A and B differ only by the cursor moving on a uniform background.

    Every pixel that belongs to the cursor in B is a pixel that changed OR is
    inside the cursor's B-box; we take the B-box, and the mask is the set of
    pixels in that box that differ from the surrounding background colour.
    """
    a, b, out = load(argv[0]), load(argv[1]), argv[2]
    bx = sorted(blobs(changed(a, b)), key=lambda r: -(r[2] - r[0]) * (r[3] - r[1]))
    if len(bx) != 2:
        print(f"ERROR: expected 2 blobs, got {len(bx)}: {bx}", file=sys.stderr)
        sys.exit(1)
    for x0, y0, x1, y1 in bx:
        print(f"cand x[{x0}..{x1}] y[{y0}..{y1}]")
    # the cursor in B is the blob whose content differs from A's content there
    for x0, y0, x1, y1 in bx:
        patch = b[y0 : y1 + 1, x0 : x1 + 1]
        bg = np.bincount(a[y0 : y1 + 1, x0 : x1 + 1].reshape(-1, 3)[:, 0]).argmax()
        mask = patch[:, :, 0] != bg
        if mask.sum() < 20:
            continue
        np.savez(out, patch=patch, mask=mask, x0=x0, y0=y0, bg=bg)
        print(f"template {x1 - x0 + 1}x{y1 - y0 + 1} opaque={int(mask.sum())} at x[{x0}..{x1}] y[{y0}..{y1}] bg={bg}")
        return
    print("ERROR: no usable cursor blob", file=sys.stderr)
    sys.exit(1)


def locate(tpl, frame, tol=0, regions=None):
    """Exact-match the cursor template anywhere in FRAME, including partially
    clipped at the four edges. Returns (mismatch, n_scored, hits).

    The frame is padded with a sentinel colour so an origin outside the visible
    area is legal; template pixels that fall on padding are not scored, and a
    candidate with fewer than MINPX visible opaque pixels is rejected outright.
    """
    MINPX = 4
    d = np.load(tpl)
    patch, mask = d["patch"].astype(np.int16), d["mask"]
    th, tw = mask.shape
    f = load(frame) if isinstance(frame, str) else frame
    H, W = f.shape[:2]
    SENT = -999
    g = np.full((H + 2 * th, W + 2 * tw, 3), SENT, dtype=np.int16)
    g[th : th + H, tw : tw + W] = f
    ys, xs = np.nonzero(mask)
    vals = patch[ys, xs]
    oh, ow = H + th, W + tw  # origins from (-th,-tw) to (H-1,W-1)
    order = np.argsort(-np.abs(vals[:, 0] - int(d["bg"])))
    bad = np.zeros((oh, ow), dtype=np.int32)
    for k in order[:12]:
        sub = g[ys[k] : ys[k] + oh, xs[k] : xs[k] + ow]
        pad = sub[:, :, 0] == SENT
        bad += (~pad & (np.abs(sub - vals[k]).max(axis=2) > tol)).astype(np.int32)
    if regions is not None:
        sel = np.zeros((oh, ow), dtype=bool)
        for x0, y0, x1, y1 in regions:
            sel[max(0, y0 + th) : y1 + th + 1, max(0, x0 + tw) : x1 + tw + 1] = True
        bad = np.where(sel, bad, 10**6)
    keep = np.argwhere(bad <= bad.min() + 4)
    res = []
    for oy, ox in keep:
        sub = g[oy : oy + th, ox : ox + tw][ys, xs]
        pad = sub[:, 0] == SENT
        vis = int((~pad).sum())
        if vis < MINPX:
            continue
        miss = int(((~pad) & (np.abs(sub - vals).max(axis=1) > tol)).sum())
        res.append((miss, vis, int(ox) - tw, int(oy) - th))
    if not res:
        return None
    res.sort(key=lambda r: (r[0], -r[1]))
    best, vis = res[0][0], res[0][1]
    hits = [(r[2] + 1, r[3] + 1) for r in res if r[0] == best and r[1] == vis]
    return best, vis, hits


def track(tpl, ref, frame, prev=None):
    """Locate the cursor in FRAME, considering only places where FRAME differs
    from REF. That is the whole trick that makes the instrument trustworthy: the
    cursor can only be somewhere that changed, so no amount of desktop artwork
    that happens to resemble an arrow can produce a false positive, and a
    cursor clipped to four pixels in a screen corner is still found."""
    d = np.load(tpl)
    th, tw = d["mask"].shape
    a, b = load(ref), load(frame)
    regions = []
    for x0, y0, x1, y1 in blobs(changed(a, b)):
        if prev is not None and x0 - 2 <= prev[0] <= x1 + 2 and y0 - 2 <= prev[1] <= y1 + 2:
            continue  # this blob is where the cursor CAME FROM
        regions.append((x0 - tw + 1, y0 - th + 1, x1, y1))
    if not regions:
        return "UNCHANGED", []
    r = locate(tpl, b, regions=regions)
    if r is None:
        return "NOTFOUND", []
    miss, vis, hits = r
    return ("OK" if miss == 0 and len(hits) == 1 else "UNSURE"), hits


def cmd_track(argv):
    prev = (int(argv[3]), int(argv[4])) if len(argv) > 4 else None
    st, hits = track(argv[0], argv[1], argv[2], prev)
    print(f"{st} {hits[:4]}")


def cmd_locate(argv):
    r = locate(argv[0], argv[1])
    if r is None:
        print("CURSOR-NOT-FOUND")
        return
    best, n, hits = r
    ok = "OK" if best <= 2 and len(hits) == 1 else "UNSURE"
    print(f"{ok} pos={hits[0] if len(hits) == 1 else hits[:4]} mismatch={best}/{n} hits={len(hits)}")


if __name__ == "__main__":
    {"blobs": cmd_blobs, "mktemplate": cmd_mktemplate, "locate": cmd_locate, "track": cmd_track}[sys.argv[1]](
        sys.argv[2:]
    )

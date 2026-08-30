#!/usr/bin/env python3
"""Find the guest's pointer in a framebuffer capture, without a human looking.

WHY THIS AND NOT OpenCV. A guest cursor is not a photograph: it is a hard-edged
sprite with a 1-bit mask, blitted at integer coordinates, with no scaling, no
antialiasing and no resampling anywhere between the guest and the PPM. So the
match is EXACT -- every opaque pixel of the sprite equals the template, or this
is not the sprite -- and an exact test is both simpler and strictly better than
a correlation score. It cannot report a confident wrong answer the way a
best-peak matcher can: it says NOTFOUND, or AMBIGUOUS, or one position. That
matters, because the whole point of the framebuffer rule (AGENTS.md rule 9) is
that the picture is EVIDENCE, and evidence that quietly guesses is worse than
none. numpy is also already on every box here; OpenCV is not.

The one thing a correlation matcher buys -- tolerance of lossy encoding -- is
not wanted either. Point this at screendumps (QMP `screendump`, PPM), not at
the H.264 stream, or the encoder's ringing will break the exact match and it
will honestly tell you it found nothing.

    learn  A.ppm B.ppm            two frames where ONLY the cursor moved;
                                  writes/updates a template bank
    learn  A.ppm B.ppm --at X,Y   ... or say where the sprite is in B, when the
                                  guest repaints behind it (see below)
    find   FRAME.ppm              prints "x y id" for the cursor in one frame
    track  FRAME.ppm...           prints CSV: frame,x,y,id
    check  FRAME.ppm X Y          exit 0 if the cursor is within --tol of X,Y

LEARNING NEEDS NO ORACLE, on an idle guest. The cursor is then the only thing
that moved, so the pixels that differ inside its new bounding box ARE its opaque
pixels -- mask and colours both, exactly, with no hand-cropping and no
per-station tuning. The bank is keyed by content, so re-learning is idempotent.

A REAL DESKTOP IS RARELY IDLE, though, and that is not a corner case: the first
attempt here drowned in 16385 changed pixels because Netscape repainted between
the two frames, and one 820x381 cluster is not a cursor. So `learn` says which
cluster defeated it rather than shrugging, and `--at X,Y` learns from a box at a
position the CALLER already knows -- any harness that commanded the pointer
knows where it aimed, which makes this the normal path on a busy exhibit.

WHAT IS REPORTED is the sprite's ORIGIN (its top-left corner), because that is
what a framebuffer can see. It is NOT the pointer: the guest draws the sprite
at `pointer - hotspot`, and the hotspot is per-glyph software state that no
picture contains (see docs/guests/aix432.md). Pass --hotspot to add a known one.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

DEFAULT_BANK = Path("cursor-bank.json")


def load(path: str) -> np.ndarray:
    """One frame as H*W*3 uint8. PPM, PNG, anything PIL opens."""
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def _bboxes(diff: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Bounding boxes of the connected clusters of changed pixels.

    Grid-clustered rather than truly connected: a cursor is a compact blob and
    the two blobs (old position, new position) are what matter, so grouping
    changed pixels by proximity is enough and needs no scipy.
    """
    ys, xs = np.nonzero(diff)
    if not len(ys):
        return []
    order = np.argsort(xs)
    xs, ys = xs[order], ys[order]
    groups: list[list[int]] = [[0]]
    for i in range(1, len(xs)):
        if xs[i] - xs[groups[-1][-1]] > 8:
            groups.append([i])
        else:
            groups[-1].append(i)
    out = []
    for g in groups:
        gx, gy = xs[g], ys[g]
        out.append((int(gx.min()), int(gy.min()), int(gx.max()), int(gy.max())))
    return out


def learn_at(a: np.ndarray, b: np.ndarray, bank: dict, at: tuple[int, int], size: int) -> list[str]:
    """Learn the sprite in B at a caller-supplied origin, ignoring the rest."""
    x0, y0 = at
    y1, x1 = min(b.shape[0], y0 + size) - 1, min(b.shape[1], x0 + size) - 1
    sub_a, sub_b = a[y0 : y1 + 1, x0 : x1 + 1], b[y0 : y1 + 1, x0 : x1 + 1]
    mask = np.any(sub_a != sub_b, axis=2)
    if mask.sum() < 8:
        return []
    # Trim to the opaque pixels: the caller's box is a bound, not the sprite.
    ys, xs = np.nonzero(mask)
    sub_b = sub_b[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
    mask = mask[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
    tid = _ident(sub_b, mask)
    h, w = mask.shape
    bank[tid] = {
        "w": w,
        "h": h,
        "ox": int(xs.min()),
        "oy": int(ys.min()),
        "mask": base64.b64encode(np.packbits(mask).tobytes()).decode(),
        "rgb": base64.b64encode(np.ascontiguousarray(sub_b).tobytes()).decode(),
    }
    return [tid]


def learn(a: np.ndarray, b: np.ndarray, bank: dict, max_side: int) -> list[str]:
    """Extract every sprite visible in B but not in A. Returns the ids added."""
    diff = np.any(a != b, axis=2)
    added = []
    boxes = _bboxes(diff)
    for x0, y0, x1, y1 in boxes:
        w, h = x1 - x0 + 1, y1 - y0 + 1
        if w > max_side or h > max_side:
            print(
                f"cursor-locate: ignoring a {w}x{h} changed cluster at {x0},{y0} "
                f"-- that is a repaint, not a cursor; use --at X,Y",
                file=sys.stderr,
            )
            continue
        sub_a = a[y0 : y1 + 1, x0 : x1 + 1]
        sub_b = b[y0 : y1 + 1, x0 : x1 + 1]
        mask = np.any(sub_a != sub_b, axis=2)
        if mask.sum() < 8:
            continue  # too little to identify anything
        tid = _ident(sub_b, mask)
        bank[tid] = {
            "w": w,
            "h": h,
            "ox": 0,
            "oy": 0,
            "mask": base64.b64encode(np.packbits(mask).tobytes()).decode(),
            "rgb": base64.b64encode(np.ascontiguousarray(sub_b).tobytes()).decode(),
        }
        added.append(tid)
    return added


def _ident(rgb: np.ndarray, mask: np.ndarray) -> str:
    import hashlib

    h = hashlib.sha256()
    h.update(np.ascontiguousarray(rgb[mask]).tobytes())
    h.update(np.packbits(mask).tobytes())
    return h.hexdigest()[:12]


def _unpack(entry: dict) -> tuple[np.ndarray, np.ndarray]:
    w, h = entry["w"], entry["h"]
    mask = (
        np.unpackbits(np.frombuffer(base64.b64decode(entry["mask"]), dtype=np.uint8), count=w * h)
        .reshape(h, w)
        .astype(bool)
    )
    rgb = np.frombuffer(base64.b64decode(entry["rgb"]), dtype=np.uint8).reshape(h, w, 3)
    return rgb, mask


def find(frame: np.ndarray, bank: dict) -> list[tuple[int, int, str]]:
    """Every exact placement of every template. Usually length 0 or 1."""
    fh, fw = frame.shape[:2]
    hits: list[tuple[int, int, str]] = []
    for tid, entry in bank.items():
        rgb, mask = _unpack(entry)
        h, w = mask.shape
        # Anchor on the template's rarest opaque pixel: only offsets where that
        # exact colour appears can possibly match, which turns a full sweep into
        # a handful of candidates.
        ay, ax = np.argwhere(mask)[0]
        colour = rgb[ay, ax]
        cand = np.argwhere(np.all(frame == colour, axis=2))
        want_rgb = rgb[mask]
        for cy, cx in cand:
            y0, x0 = int(cy) - int(ay), int(cx) - int(ax)
            if y0 < 0 or x0 < 0 or y0 + h > fh or x0 + w > fw:
                continue
            window = frame[y0 : y0 + h, x0 : x0 + w]
            if np.array_equal(window[mask], want_rgb):
                hits.append((x0 - entry.get("ox", 0), y0 - entry.get("oy", 0), tid))
    return sorted(set(hits))


def _bank_load(p: Path) -> dict:
    return json.loads(p.read_text()) if p.exists() else {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", choices=("learn", "find", "track", "check"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--bank", type=Path, default=DEFAULT_BANK)
    ap.add_argument("--hotspot", default="0,0", help="added to the sprite origin")
    ap.add_argument("--tol", type=int, default=1, help="check: pixels of slack")
    ap.add_argument("--max-side", type=int, default=64, help="learn: sprite cap")
    ap.add_argument("--at", help="learn: sprite origin X,Y in the second frame")
    ap.add_argument("--size", type=int, default=64, help="learn --at: box side")
    o = ap.parse_args()
    hx, hy = (int(v) for v in o.hotspot.split(","))
    bank = _bank_load(o.bank)

    if o.cmd == "learn":
        if len(o.args) != 2:
            ap.error("learn needs exactly two frames")
        a, b = load(o.args[0]), load(o.args[1])
        if o.at:
            at = tuple(int(v) for v in o.at.split(","))
            added = learn_at(a, b, bank, at, o.size)
        else:
            added = learn(a, b, bank, o.max_side)
        o.bank.write_text(json.dumps(bank, indent=1))
        print(f"{len(added)} template(s) learned, bank now {len(bank)}: {' '.join(added)}")
        return 0 if added else 1

    if not bank:
        print(f"cursor-locate: bank {o.bank} is empty; run `learn` first", file=sys.stderr)
        return 2

    if o.cmd == "find":
        hits = find(load(o.args[0]), bank)
        if not hits:
            print("NOTFOUND")
            return 1
        if len(hits) > 1:
            print("AMBIGUOUS " + " ".join(f"{x + hx},{y + hy}:{t}" for x, y, t in hits))
            return 1
        x, y, tid = hits[0]
        print(f"{x + hx} {y + hy} {tid}")
        return 0

    if o.cmd == "track":
        print("frame,x,y,id")
        for path in o.args:
            hits = find(load(path), bank)
            if len(hits) == 1:
                x, y, tid = hits[0]
                print(f"{path},{x + hx},{y + hy},{tid}")
            else:
                print(f"{path},,,{'AMBIGUOUS' if hits else 'NOTFOUND'}")
        return 0

    # check
    if len(o.args) != 3:
        ap.error("check needs FRAME X Y")
    hits = find(load(o.args[0]), bank)
    want = (int(o.args[1]), int(o.args[2]))
    if len(hits) != 1:
        print(f"FAIL {'AMBIGUOUS' if hits else 'NOTFOUND'} want={want[0]},{want[1]}")
        return 1
    x, y, tid = hits[0]
    got = (x + hx, y + hy)
    ok = abs(got[0] - want[0]) <= o.tol and abs(got[1] - want[1]) <= o.tol
    print(
        f"{'OK' if ok else 'FAIL'} cursor={got[0]},{got[1]} want={want[0]},{want[1]} "
        f"err={got[0] - want[0]:+d},{got[1] - want[1]:+d} id={tid}"
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

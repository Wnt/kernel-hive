#!/usr/bin/env python3
"""Find an XOR/INVERTING cursor in a framebuffer capture, with OpenCV.

WHY THIS TOOL EXISTS. `cursor-locate.py` (same directory) is the DEFAULT and
should stay the default: it assumes a hard-edged sprite with a 1-bit mask
whose opaque pixels are content-independent, so it can do an EXACT match and
say NOTFOUND / AMBIGUOUS / one position with no guessing. The `vision`
station (VisiCorp Visi On 1.0 under PCE) breaks that assumption: its arrow
cursor is XOR/INVERTING -- it toggles whatever is already under it instead of
blitting fixed colours. Over a uniform background `cursor-locate.py` sees
"a small blob changed" at every candidate position and returns AMBIGUOUS
everywhere; see docs/lab/VISION-WAVE.md Sec 4 for the readback that proved it.
This tool exists ONLY for that class of cursor. Reach for it when
`cursor-locate.py learn` reports the sprite is ambiguous / the guest's
own docs say the pointer is XOR-drawn -- otherwise use `cursor-locate.py`.

THE TRICK. Because the sprite's colours depend on the background, matching on
colour is meaningless, and it turns out matching on raw edge energy is too:
the vision desktop's background is itself a fine dithered/striped fill, so a
Laplacian-edge or direct/inverted-intensity correlation (the first thing
tried here) is swamped by the background's own high-frequency texture and
peaks at unrelated locations -- see the dead end recorded below. What DOES
work, because the paint is XOR: "un-inverting" the pixels under a HYPOTHESIZED
sprite position must reproduce whatever was really drawn there, and the one
thing every hypothesis can be checked against without knowing the background
in advance is the SAME COLUMN some rows away, past the sprite's own height, in
BOTH directions (above and below). At the true position, the row-shifted
comparison landing above agrees with the one landing below (both recover the
same real background); at a wrong position, at least one direction is fighting
real page content and disagrees. `cost_map` sums both directions; the unique
minimum is the sprite. Checked against the whole test set (six frames, three
X positions, one Y move) this is exact -- see the acceptance run in the
report/commit that added this file.

REQUIRES A VENV -- OpenCV is installed nowhere on labhost's or CT950's system
python, and it must stay that way (AGENTS.md rule: no apt/pip into a system
python). `scripts/dev/cv-venv.sh` builds a per-host venv at
`/data/vms/tools/cv-venv/$(hostname)` (labhost and CT950 have different
pythons; /data/vms is shared and durable, so the same path rule resolves on
both). Run `scripts/dev/cv-venv.sh` once per host before using this tool.
This script then bootstraps ITSELF into that venv -- run it with plain
`python3` from either host's system python and it re-execs into the venv
python automatically. If the venv is missing it prints
`run scripts/dev/cv-venv.sh first` and exits 2.

Example:

    ssh lab 'python3 /data/vms/sandbox/vision-list/repo/scripts/dev/cursor-locate-cv.py \\
        learn s-000.png s-x1.png --out cursor.npz'
    ssh lab 'python3 /data/vms/sandbox/vision-list/repo/scripts/dev/cursor-locate-cv.py \\
        find cursor.npz s-x2.png'

    learn A.png B.png --out T.npz     two frames differing ONLY by cursor
                                       position; stores the cursor's binary
                                       mask (shape only, no colours)
    find  T.npz FRAME.png             locate the cursor in one frame
    check T.npz FRAME.png --expect X,Y [--tol N]
                                       find, then PASS/FAIL vs. an expectation
    react A.png B.png [--ignore-bbox x0,y0,x1,y1] [--threshold N]
                                       did the GUEST react (changed pixels
                                       outside the ignored cursor region),
                                       independent of cursor motion
"""

from __future__ import annotations

import argparse
import os
import platform
import sys
from pathlib import Path

try:
    import cv2
except ImportError:
    # Not on the system python (by design -- AGENTS.md forbids installing
    # OpenCV there). Re-exec into this host's per-host venv, built by
    # scripts/dev/cv-venv.sh at /data/vms/tools/cv-venv/$(hostname) -- the
    # same path rule that script uses, so no per-caller configuration is
    # needed. Keeps the CLI unchanged: `python3 cursor-locate-cv.py ...`
    # just works once the venv exists.
    venv_python = Path("/data/vms/tools/cv-venv") / platform.node() / "bin" / "python3"
    if not venv_python.is_file():
        print("run scripts/dev/cv-venv.sh first", file=sys.stderr)
        raise SystemExit(2) from None
    os.execv(str(venv_python), [str(venv_python), *sys.argv])

import numpy as np
from PIL import Image

MIN_BLOB_AREA = 8


def load(path: str) -> np.ndarray:
    """One frame as H*W*3 uint8. PNG, PPM, anything PIL opens."""
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def _crop_mask(labels: np.ndarray, stats: np.ndarray, diff: np.ndarray, i: int) -> np.ndarray:
    """The TRUE (undilated) diff pixels inside cluster i's bounding box."""
    x, y, w, h = (int(stats[i, k]) for k in (cv2.CC_STAT_LEFT, cv2.CC_STAT_TOP, cv2.CC_STAT_WIDTH, cv2.CC_STAT_HEIGHT))
    region_label = labels[y : y + h, x : x + w] == i
    region_diff = diff[y : y + h, x : x + w] > 0
    return region_label & region_diff


def learn(a: np.ndarray, b: np.ndarray, out: Path, min_area: int = MIN_BLOB_AREA) -> int:
    """Two frames differing ONLY by cursor position -> a binary shape mask.

    The XOR sprite paints two blobs of changed pixels: where it USED to be
    (now reverted) and where it now IS. Both carry the same silhouette, so
    either one is a valid template; take the larger bounding box as the
    canonical shape. More or fewer than two significant blobs means the
    frames differ for some other reason (a repaint, a clock, a typo) --
    fail loudly rather than guess which blob is the cursor.
    """
    diff = (np.any(a != b, axis=2).astype(np.uint8)) * 255
    # The XOR diff is an anti-aliased outline, not a solid blob: pixels inside
    # one cursor glyph can be 8-disconnected from each other. Dilate first so
    # each glyph merges into ONE component, cluster on that, then read the
    # true (undilated) diff pixels back out per cluster.
    dilated = cv2.dilate(diff, np.ones((5, 5), np.uint8))
    num, labels, stats, _ = cv2.connectedComponentsWithStats(dilated, connectivity=8)
    sig = [i for i in range(1, num) if stats[i, cv2.CC_STAT_AREA] >= min_area]
    if len(sig) != 2:
        areas = [int(stats[i, cv2.CC_STAT_AREA]) for i in range(1, num)]
        print(
            f"cursor-locate-cv: learn expected exactly 2 moved blobs (old cursor "
            f"cleared, new cursor drawn), found {len(sig)} significant blob(s) "
            f"(>= {min_area}px) out of {num - 1} total; areas={areas}. Pass two "
            f"frames that differ ONLY by the cursor's position.",
            file=sys.stderr,
        )
        return 1
    i1, i2 = sig
    m1, m2 = _crop_mask(labels, stats, diff, i1), _crop_mask(labels, stats, diff, i2)
    mask = m1 if m1.sum() >= m2.sum() else m2
    ys, xs = np.nonzero(mask)
    mask = mask[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
    h, w = mask.shape
    np.savez(out, mask=mask, w=w, h=h)
    print(f"cursor-locate-cv: learned a {w}x{h} mask -> {out}")
    return 0


def _edge_map(gray: np.ndarray) -> np.ndarray:
    return np.abs(cv2.Laplacian(gray, cv2.CV_32F, ksize=3)).astype(np.float32)


def _edge_score_map(mask: np.ndarray, frame: np.ndarray) -> np.ndarray:
    """DEAD END, kept only as a documented cross-check (see module docstring).

    Matches the doc'd idea literally: mask against an edge/gradient image,
    and/or against the frame and its inverse, best score wins. On this
    station's dithered background it is not discriminating (its peak on the
    real test frames lands 300+px from the true cursor, at ~0.02-0.39 score
    with no separation from the runner-up) -- kept here, unused by
    `find`/`check`, so the finding is reproducible rather than just asserted.
    """
    gray = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY).astype(np.float32)
    template = mask.astype(np.float32)
    edge = _edge_map(gray)
    scores = [
        cv2.matchTemplate(edge, template, cv2.TM_CCOEFF_NORMED),
        cv2.matchTemplate(gray, template, cv2.TM_CCOEFF_NORMED),
        cv2.matchTemplate(255.0 - gray, template, cv2.TM_CCOEFF_NORMED),
    ]
    return np.maximum(np.maximum(scores[0], scores[1]), scores[2])


def _shift_cost(gray: np.ndarray, mask: np.ndarray, shift: int) -> np.ndarray:
    """Cost of "the sprite covers mask-shaped pixels here", from one direction.

    Un-invert (255 - pixel) every masked pixel and compare it to the same
    column `shift` rows away -- far enough that the sprite's own height
    cannot also be covering that row. A correct hypothesis recovers the real
    background there; a wrong one is comparing an un-inverted, unrelated
    pixel to whatever real content sits `shift` rows off, which only zeroes
    out by construction, not by coincidence over the WHOLE mask. `shift` is
    signed: positive looks downward, negative upward.
    """
    h, w = mask.shape
    height, width = gray.shape
    s = abs(shift)
    ref = np.zeros_like(gray)
    if shift > 0:
        ref[: height - s, :] = gray[s:, :]
        y_lo, y_hi = 0, height - s - h
    else:
        ref[s:, :] = gray[: height - s, :]
        y_lo, y_hi = s, height - h
    term = (255.0 - gray - ref) ** 2
    cost = cv2.filter2D(term, -1, mask.astype(np.float32), anchor=(0, 0), borderType=cv2.BORDER_CONSTANT)
    valid = np.zeros((height, width), dtype=bool)
    x_hi = width - w
    if y_hi >= y_lo and x_hi >= 0:
        valid[y_lo : y_hi + 1, 0 : x_hi + 1] = True
    return np.where(valid, cost, np.inf)


def cost_map(mask: np.ndarray, frame: np.ndarray) -> np.ndarray:
    """Lower is a better match. See `_shift_cost`. Combines both directions
    so a background that is only constant one way (up OR down, not both)
    cannot fake a zero-cost tie the way a single direction can."""
    gray = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY).astype(np.float32)
    h = mask.shape[0]
    shift = min(h + max(8, h // 4), gray.shape[0] // 2 - 1)
    return _shift_cost(gray, mask, shift) + _shift_cost(gray, mask, -shift)


def _to_score(cost: float) -> float:
    """Monotonic, bounded transform of the cost (higher is better) purely for
    display -- ambiguity is judged on the raw cost, see `find_peaks`."""
    return 1.0 / (1.0 + cost / (255.0**2)) if np.isfinite(cost) else float("-inf")


def find_peaks(cost: np.ndarray, w: int, h: int) -> tuple[tuple[int, int], float, float, float]:
    """Best origin (x,y), its score, and whether a second, DISTINCT candidate
    (outside a suppression radius of the best) is within `margin` of it --
    compared as a RELATIVE gap on the raw cost, not on the bounded score: cost
    can span many orders of magnitude between an easy and a hard frame, and a
    fixed score-space margin would call a confident-but-expensive match
    ambiguous just because its cost is nominally larger."""
    if not np.isfinite(cost).any():
        return (0, 0), float("-inf"), float("inf"), float("inf")
    best_flat = int(np.argmin(cost))
    y0, x0 = np.unravel_index(best_flat, cost.shape)
    best_cost = float(cost[y0, x0])
    radius = max(w, h)
    ys, xs = np.ogrid[: cost.shape[0], : cost.shape[1]]
    dist2 = (ys - y0) ** 2 + (xs - x0) ** 2
    masked = np.where(dist2 <= radius * radius, np.inf, cost)
    second_cost = float(np.min(masked)) if np.isfinite(masked).any() else float("inf")
    return (int(x0), int(y0)), _to_score(best_cost), second_cost, best_cost


def _is_ambiguous(best_cost: float, second_cost: float, margin: float) -> bool:
    if not np.isfinite(second_cost):
        return False
    return (second_cost - best_cost) <= margin * max(best_cost, 1.0)


def find(template: Path, frame_path: str, margin: float) -> int:
    data = np.load(template)
    mask, w, h = data["mask"].astype(bool), int(data["w"]), int(data["h"])
    frame = load(frame_path)
    cost = cost_map(mask, frame)
    (x0, y0), score, second_cost, best_cost = find_peaks(cost, w, h)
    cx, cy = x0 + w / 2, y0 + h / 2
    ambiguous = _is_ambiguous(best_cost, second_cost, margin)
    print(f"origin=({x0},{y0}) centroid=({cx},{cy}) score={score:.4f}")
    if ambiguous:
        print(f"AMBIGUOUS second_score={_to_score(second_cost):.4f} margin={margin}")
        return 1
    print("FOUND")
    return 0


def _find_centroid(template: Path, frame_path: str, margin: float) -> tuple[tuple[float, float] | None, float, float]:
    data = np.load(template)
    mask, w, h = data["mask"].astype(bool), int(data["w"]), int(data["h"])
    frame = load(frame_path)
    cost = cost_map(mask, frame)
    (x0, y0), score, second_cost, best_cost = find_peaks(cost, w, h)
    if _is_ambiguous(best_cost, second_cost, margin):
        return None, score, _to_score(second_cost)
    return (x0 + w / 2, y0 + h / 2), score, _to_score(second_cost)


def check(template: Path, frame_path: str, expect: tuple[float, float], tol: int, margin: float) -> int:
    centroid, best, second = _find_centroid(template, frame_path, margin)
    if centroid is None:
        print(f"FAIL AMBIGUOUS score={best:.4f} second={second:.4f} want={expect[0]},{expect[1]}")
        return 1
    cx, cy = centroid
    ok = abs(cx - expect[0]) <= tol and abs(cy - expect[1]) <= tol
    print(
        f"{'OK' if ok else 'FAIL'} centroid=({cx},{cy}) want=({expect[0]},{expect[1]}) "
        f"err=({cx - expect[0]:+.1f},{cy - expect[1]:+.1f}) score={best:.4f}"
    )
    return 0 if ok else 1


def react(a: np.ndarray, b: np.ndarray, ignore_bbox: tuple[int, int, int, int] | None, threshold: int) -> int:
    diff = np.any(a != b, axis=2)
    if ignore_bbox is not None:
        x0, y0, x1, y1 = ignore_bbox
        diff[y0 : y1 + 1, x0 : x1 + 1] = False
    changed = int(diff.sum())
    ys, xs = np.nonzero(diff)
    bbox = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())) if len(xs) else None
    reacted = changed > threshold
    print(f"changed_pixels={changed} bbox={bbox} threshold={threshold}")
    print("REACTED" if reacted else "NO REACTION")
    return 0 if reacted else 1


def _parse_xy(s: str) -> tuple[float, float]:
    x, y = s.split(",")
    return float(x), float(y)


def _parse_bbox(s: str) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = (int(v) for v in s.split(","))
    return x0, y0, x1, y1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("learn", "find", "check", "react"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--out", type=Path, help="learn: template file to write")
    ap.add_argument("--expect", type=_parse_xy, help="check: expected centroid X,Y")
    ap.add_argument("--tol", type=float, default=3.0, help="check: pixels of slack")
    ap.add_argument("--margin", type=float, default=0.15, help="find/check: AMBIGUOUS margin")
    ap.add_argument("--ignore-bbox", type=_parse_bbox, help="react: cursor bbox to ignore, x0,y0,x1,y1")
    ap.add_argument("--threshold", type=int, default=0, help="react: changed-pixel count that counts as REACTED")
    o = ap.parse_args()

    if o.cmd == "learn":
        if len(o.args) != 2 or not o.out:
            ap.error("learn needs A.png B.png --out template.npz")
        return learn(load(o.args[0]), load(o.args[1]), o.out)

    if o.cmd == "find":
        if len(o.args) != 2:
            ap.error("find needs template.npz FRAME.png")
        return find(Path(o.args[0]), o.args[1], o.margin)

    if o.cmd == "check":
        if len(o.args) != 2 or o.expect is None:
            ap.error("check needs template.npz FRAME.png --expect X,Y")
        return check(Path(o.args[0]), o.args[1], o.expect, o.tol, o.margin)

    # react
    if len(o.args) != 2:
        ap.error("react needs A.png B.png")
    return react(load(o.args[0]), load(o.args[1]), o.ignore_bbox, o.threshold)


if __name__ == "__main__":
    sys.exit(main())

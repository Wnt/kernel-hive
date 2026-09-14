#!/usr/bin/env python3
"""cpg-mask — checkpoint-guard's DECLARED exclusion rectangles.

WHY THIS EXISTS. checkpoint-guard refuses to bake a checkpoint whose idle
framebuffer is not stable (two shots CPG_IDLE_SECONDS apart must agree), because
without a stable reference "restored == reference" proves nothing. That check is
correct and stays. But it makes a whole class of period-correct scenes
unbakeable: www.apple.com's 1998 homepage carries a ~37-frame animated GIF
ticker, so that framebuffer NEVER idles, and `rhapsody` had to settle for
www.wired.com instead of the thematically exact page.

A mask lets a scene that is stable EVERYWHERE EXCEPT a known animating region be
proven stable anyway. Four rules make that an exemption you can trust:

  * DECLARED, never inferred. There is deliberately no "ignore whatever moves"
    mode: that would delete the check rather than narrow it.
  * Every rectangle carries a REASON, and refusing a mask without one is the
    point -- the next person must be able to read why this golden was baked with
    a region excluded.
  * The remaining area is held to the SAME threshold. Masking narrows the area
    compared; it must never lower the bar. That is why this module CROPS rather
    than blanks: painting the masked region black in both frames would make it
    match perfectly and INFLATE a whole-frame SSIM, quietly buying slack for the
    rest of the picture. Here the masked pixels are not compared at all, and the
    score is the area-weighted mean of ffmpeg's own SSIM over the tiles that
    remain -- the same engine and the same number as an unmasked run.
  * A mask that covers most of the screen is refused.

DECLARATION FORM (one line, shell-quotable), in station.env or $CPG_MASK:

    CPG_MASK="632,214,120x60 home/images/ticker.gif animates forever; 8,8,96x16 clock"

entries separated by ';', each `X,Y,WxH` followed by whitespace and free-text
reason. Coordinates are guest pixels in the station's own framebuffer, so a
guest that changes resolution makes its declaration fail loudly rather than
silently mask the wrong place.

Run as a CLI by checkpoint-guard-proof.sh; also importable for tests.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

# Snap every mask edge outward to this grid. ffmpeg's ssim filter works on 8x8
# blocks, so an 8-aligned tile is scored the way the unmasked frame's blocks are
# and no tile is a sliver too thin to score at all. Snapping OUTWARD enlarges the
# excluded region slightly, which is the conservative direction for the mask's
# own size budget and is reported as such.
GRID = 8

# "Most of the screen" is refused. A quarter is already a lot of exhibit to stop
# looking at, and the number is in one place so a future change is a decision
# rather than a drift.
DEFAULT_MAX_FRACTION = 0.25

ENTRY_RE = re.compile(r"^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*x\s*(\d+)\s+(\S.*?)\s*$")


class MaskError(Exception):
    """A declaration the guard must REFUSE, with the sentence to print."""


class Rect:
    __slots__ = ("x", "y", "w", "h", "reason")

    def __init__(self, x: int, y: int, w: int, h: int, reason: str) -> None:
        self.x, self.y, self.w, self.h, self.reason = x, y, w, h, reason

    def as_dict(self) -> dict:
        return {"x": self.x, "y": self.y, "w": self.w, "h": self.h, "reason": self.reason}

    def text(self) -> str:
        return f"{self.x},{self.y},{self.w}x{self.h} {self.reason}"


def parse(decl: str) -> list[Rect]:
    """Parse a declaration into rectangles, refusing anything ambiguous."""
    rects: list[Rect] = []
    for raw in decl.split(";"):
        if not raw.strip():
            continue
        m = ENTRY_RE.match(raw)
        if not m:
            raise MaskError(
                f"mask entry {raw.strip()!r} is not 'X,Y,WxH <reason>'. Every rectangle "
                "needs a geometry AND a reason: an exemption nobody can read the reason "
                "for is how this check quietly stops meaning anything."
            )
        x, y, w, h = (int(g) for g in m.group(1, 2, 3, 4))
        reason = m.group(5).strip()
        if w < 1 or h < 1:
            raise MaskError(f"mask entry {raw.strip()!r} has a zero/negative size")
        if len(reason) < 3:
            raise MaskError(
                f"mask entry {raw.strip()!r} has reason {reason!r}, which says nothing. "
                "Name what animates there and why it cannot be parked."
            )
        rects.append(Rect(x, y, w, h, reason))
    if not rects:
        raise MaskError("mask declaration is empty")
    return rects


def _snap(rects: list[Rect], fw: int, fh: int) -> list[tuple[int, int, int, int]]:
    """Clip to the frame and snap each edge outward to the GRID."""
    out = []
    for r in rects:
        x0 = max(0, (r.x // GRID) * GRID)
        y0 = max(0, (r.y // GRID) * GRID)
        x1 = min(fw, -(-(r.x + r.w) // GRID) * GRID)
        y1 = min(fh, -(-(r.y + r.h) // GRID) * GRID)
        if x1 > x0 and y1 > y0:
            out.append((x0, y0, x1, y1))
    return out


def tiles(rects: list[Rect], fw: int, fh: int) -> tuple[list[tuple[int, int, int, int]], int]:
    """Decompose frame-minus-mask into scorable tiles.

    Returns (tiles as x,y,w,h, excluded_pixels). A tile thinner than GRID in
    either axis cannot be scored, so its area is counted as excluded too -- the
    reported exclusion is then the whole truth, not just what was declared.
    """
    blocks = _snap(rects, fw, fh)
    xs = sorted({0, fw} | {v for b in blocks for v in (b[0], b[2])})
    ys = sorted({0, fh} | {v for b in blocks for v in (b[1], b[3])})
    kept: list[tuple[int, int, int, int]] = []
    excluded = 0
    for yi in range(len(ys) - 1):
        y0, y1 = ys[yi], ys[yi + 1]
        run: list[tuple[int, int]] = []
        for xi in range(len(xs) - 1):
            x0, x1 = xs[xi], xs[xi + 1]
            covered = any(b[0] <= x0 and x1 <= b[2] and b[1] <= y0 and y1 <= b[3] for b in blocks)
            if covered:
                excluded += (x1 - x0) * (y1 - y0)
                continue
            # Merge with the cell to the left: fewer, bigger tiles to score.
            # Do NOT clear `run` on a covered cell -- the runs already completed
            # in this band are tiles that still have to be scored, and dropping
            # them left a strip of the framebuffer silently uncompared. The
            # adjacency test below is what separates runs; a covered cell breaks
            # contiguity on its own.
            if run and run[-1][1] == x0:
                run[-1] = (run[-1][0], x1)
            else:
                run.append((x0, x1))
        for x0, x1 in run:
            if (x1 - x0) < GRID or (y1 - y0) < GRID:
                excluded += (x1 - x0) * (y1 - y0)
                continue
            # Merge with the tile directly above when the x-span matches.
            if kept and kept[-1][0] == x0 and kept[-1][2] == x1 - x0 and kept[-1][1] + kept[-1][3] == y0:
                px, py, pw, ph = kept[-1]
                kept[-1] = (px, py, pw, ph + (y1 - y0))
            else:
                kept.append((x0, y0, x1 - x0, y1 - y0))
    return kept, excluded


def ppm_size(path: str) -> tuple[int, int]:
    """Width/height of a binary PPM, skipping header comments."""
    with open(path, "rb") as fh:
        if fh.read(2) not in (b"P6", b"P5"):
            raise MaskError(f"{path} is not a binary PPM/PGM screendump")
        vals: list[int] = []
        token = b""
        while len(vals) < 2:
            ch = fh.read(1)
            if not ch:
                raise MaskError(f"{path} has a truncated PPM header")
            if ch == b"#":
                while fh.read(1) not in (b"\n", b""):
                    pass
                continue
            if ch.isspace():
                if token:
                    vals.append(int(token))
                    token = b""
                continue
            token += ch
    return vals[0], vals[1]


def _ffmpeg_ssim(a: str, b: str, tile: tuple[int, int, int, int]) -> float:
    """ffmpeg's own SSIM over one crop -- the same engine an unmasked run uses."""
    x, y, w, h = tile
    crop = f"crop={w}:{h}:{x}:{y}"
    try:
        proc = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-nostats", "-i", a, "-i", b,
                "-lavfi",
                f"[0:v]format=gray,{crop}[x];[1:v]format=gray,{crop}[y];[x][y]ssim",
                "-f", "null", "-",
            ],
            capture_output=True,
            text=True,
        )  # fmt: skip
    except OSError as exc:
        raise MaskError(f"could not run ffmpeg, so nothing was compared: {exc}") from exc
    found = re.findall(r"All:([0-9.]+)", proc.stderr)
    if not found:
        raise MaskError(f"ffmpeg produced no SSIM for tile {tile}: {proc.stderr[-400:]}")
    return float(found[-1])


def score(a: str, b: str, decl: str, max_fraction: float = DEFAULT_MAX_FRACTION) -> dict:
    """Area-weighted SSIM over the UNMASKED pixels of two screendumps."""
    rects = parse(decl)
    fw, fh = ppm_size(a)
    bw, bh = ppm_size(b)
    if (fw, fh) != (bw, bh):
        raise MaskError(f"frames differ in size ({fw}x{fh} vs {bw}x{bh})")
    for r in rects:
        if r.x + r.w > fw or r.y + r.h > fh:
            raise MaskError(
                f"mask rectangle '{r.text()}' does not fit this station's {fw}x{fh} "
                "framebuffer. A declaration written for another resolution would mask "
                "the wrong place, so this REFUSES instead of clamping it."
            )
    kept, excluded = tiles(rects, fw, fh)
    fraction = excluded / float(fw * fh)
    if fraction > max_fraction:
        raise MaskError(
            f"this mask excludes {fraction:.1%} of the {fw}x{fh} framebuffer (limit "
            f"{max_fraction:.0%}). A mask that covers most of the screen is not a "
            "narrowed stability check, it is no stability check: the golden could be "
            "half-drawn everywhere that matters and still pass. Park the scene instead."
        )
    if not kept:
        raise MaskError("this mask leaves no scorable area at all")
    total = sum(w * h for _, _, w, h in kept)
    acc = 0.0
    per_tile = []
    for tile in kept:
        v = _ffmpeg_ssim(a, b, tile)
        per_tile.append({"tile": list(tile), "ssim": v})
        acc += v * (tile[2] * tile[3])
    return {
        "ssim": acc / total,
        "excluded_fraction": fraction,
        "tiles": per_tile,
        "frame": [fw, fh],
        "rects": [r.as_dict() for r in rects],
    }


def _cmd_check(args: argparse.Namespace) -> int:
    """Print the unmasked-area SSIM; exit 1 when it is below --min."""
    res = score(args.a, args.b, args.mask, args.max_fraction)
    worst = min(t["ssim"] for t in res["tiles"])
    print(
        f"{res['ssim']:.6f} (masked {res['excluded_fraction']:.1%}, {len(res['tiles'])} tiles, worst tile {worst:.6f})"
    )
    return 0 if res["ssim"] >= args.min else 1


def _cmd_validate(args: argparse.Namespace) -> int:
    """Refuse a bad declaration before anything is captured."""
    rects = parse(args.mask)
    if args.frame:
        fw, fh = (int(v) for v in args.frame.lower().split("x"))
        _, excluded = tiles(rects, fw, fh)
        fraction = excluded / float(fw * fh)
        if fraction > args.max_fraction:
            raise MaskError(
                f"this mask excludes {fraction:.1%} of the {fw}x{fh} framebuffer (limit {args.max_fraction:.0%})."
            )
    print(json.dumps([r.as_dict() for r in rects], separators=(",", ":")))
    return 0


def _cmd_describe(args: argparse.Namespace) -> int:
    """The human-readable form printed by `checkpoint-guard status`."""
    for r in parse(args.mask):
        print(f"    rect {r.x},{r.y} {r.w}x{r.h}  -- {r.reason}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--max-fraction", type=float, default=DEFAULT_MAX_FRACTION)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="area-weighted SSIM over the unmasked pixels")
    c.add_argument("a")
    c.add_argument("b")
    c.add_argument("--mask", required=True)
    c.add_argument("--min", type=float, required=True)
    c.set_defaults(fn=_cmd_check)
    v = sub.add_parser("validate", help="refuse a bad declaration")
    v.add_argument("--mask", required=True)
    v.add_argument("--frame", default="")
    v.set_defaults(fn=_cmd_validate)
    d = sub.add_parser("describe", help="human-readable rectangles")
    d.add_argument("--mask", required=True)
    d.set_defaults(fn=_cmd_describe)
    args = ap.parse_args(argv)
    # EXIT CODES ARE LOAD-BEARING. checkpoint-guard-proof.sh reads 0 as "these
    # frames match" and 1 as "they differ" -- and "they differ" is what licenses
    # the guard to believe the framebuffer moved. Anything that is not an actual
    # comparison must therefore exit >1, never 1, or a broken ffmpeg would read
    # as proof. That is why nothing here is allowed to escape as a traceback.
    try:
        return args.fn(args)
    except MaskError as exc:
        print(f"cpg-mask: REFUSED: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001 - see the exit-code note above
        print(f"cpg-mask: FAILED to compare ({type(exc).__name__}: {exc})", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

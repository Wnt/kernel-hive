#!/usr/bin/env python3
# =============================================================================
# frame-compare.py — a NUMBER for the "open both PNGs and squint" step.
#
# WHY THIS EXISTS
#   Every bookworm -> trixie wave ends with scripts/dev/migrate-tile.sh printing
#   two PNG paths and a HUMAN REQUIRED banner. Three waves ran that way on
#   2026-08-10 and their results were typed into the wave write-up by hand —
#   "BEFORE and AFTER framebuffer shots are 0 differing pixels of 1024x768".
#   Nothing computed that number; it was a person's claim about a pair of
#   images, with no record of what was measured or against which band.
#
# THE FAILURE THIS MUST NEVER PASS
#   A station that loses its graphics stack renders BLACK — trixie's fs-uae has no
#   Recommends:, so without libgl1-mesa-dri amiga draws a perfectly healthy,
#   perfectly empty frame with exit 0 in every log. A black AFTER frame DIFFERS
#   from its BEFORE, so any "changed pixels < X%" threshold waves it through;
#   and if the BEFORE came from an already-broken station, "changed == 0" waves it
#   through too. So EMPTINESS IS JUDGED ON EACH FRAME ALONE, before any
#   comparison is attempted, and no comparison result can rescue a frame that
#   fails it. A baseline that is itself empty is a refusal, not a pass: there is
#   nothing left to compare against.
#
# WHY THE FLOOR IS NON-DOMINANT PIXEL COUNT
#   Measured over the 24 frames the three waves left behind. Both obvious floors
#   reject LIVE, ACCEPTED exhibits:
#     * "at least N distinct colours" — bbcmicro, zx81, mpf2, kc854 and
#       oricatmos each render exactly 2 colours;
#     * "non-black pixels >= N% of the frame" — mpf2's accepted golden is
#       99.71% black (2248 lit pixels of 786432).
#   Non-dominant pixel count is the one measure that separates every real frame
#   from an empty one, and it GENERALISES non-black: on a black frame the
#   dominant colour IS black, so the two are the same number. On a flood of any
#   colour it is exactly 0. Measured minimum on a real accepted frame: 2248
#   (mpf2); the default floor of 1000 clears it by 2.2x and is unreachable by a
#   flood. All four numbers are PRINTED every run — non-black, distinct colours,
#   entropy, non-dominant — so a human can sanity-check the gate that fired
#   instead of trusting the verdict word.
#
# WHY A NON-ZERO DIFF IS NOT A FAILURE
#   5 of the 12 real BEFORE/AFTER pairs differ, and every one of them differs
#   inside a SINGLE box of at most 33x19 px (165..575 changed pixels, <=0.12% of
#   the frame): one character cell, the blinking cursor. Max channel delta
#   reaches 255 on those, so amplitude proves nothing — the change's GEOMETRY is
#   the discriminator. Hence three verdicts, and a human still owes the last
#   judgement: this tool measures pixels, it cannot tell a Workbench desktop
#   from a GRUB console, so it NEVER prints ACCEPTED.
#
#     UNCHANGED  no pixel differs
#     LOCALISED  every changed pixel fits in one small box (cursor / clock cell)
#     DIFFERS    a human must look — NOT an error, it has its own exit code
#
# usage:
#   frame-compare.py <before.png> <after.png> [options]
#   frame-compare.py --frame <one.png> [options]      # emptiness floor only
#
# options:
#   --min-nondominant N   emptiness floor, non-dominant pixels (default 1000)
#   --motion-box WxH      largest change box still called LOCALISED (default 48x48)
#   --tol N               per-channel delta ignored as noise (default 0; PNG
#                         screendumps are lossless, so 0 is the honest default)
#   --black-level N       max channel value still counted as black (default 8)
#   --expect WxH          require this exact geometry (else exit 1)
#   --label TEXT          what this pair is called in the report
#   --json                machine-readable object on stdout, report on stderr
#
# exit: 0  UNCHANGED or LOCALISED, and every frame cleared the floor
#       1  FAIL-CLOSED: a frame is too empty to be a running machine, or the two
#          frames have different geometry (not comparable, and a resolution
#          change is itself a known regression class — nextstep's resampled
#          desktop screenshots as a perfectly plausible NeXT desktop)
#       2  usage / unreadable input
#      10  DIFFERS — a human must look. Deliberately not 1: "I cannot decide
#          this" and "this is broken" are different answers.
# =============================================================================

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover - environment problem, not logic
    sys.stderr.write(
        f"frame-compare: needs numpy + Pillow ({exc}).\n"
        "  Both are present on the lab box, so run it there — that is also where\n"
        "  the frames already are:\n"
        "    ssh lab 'python3 - a.png b.png' < scripts/dev/frame-compare.py\n"
    )
    raise SystemExit(2) from exc

FLOOR_NONDOMINANT = 1000
MOTION_BOX = (48, 48)
CELL = 16  # grid used to say "one blob" vs "scattered all over the frame"


def load(path: str):
    """RGB uint8 array, or exit 2. A frame we cannot read is never a pass."""
    try:
        with Image.open(path) as img:
            return np.asarray(img.convert("RGB"))
    except Exception as exc:  # noqa: BLE001 - every read failure has one answer
        sys.stderr.write(f"frame-compare: cannot read {path}: {exc}\n")
        raise SystemExit(2) from exc


def frame_metrics(arr, black_level: int) -> dict:
    """Everything we know about ONE frame, with no reference to any other."""
    height, width, _ = arr.shape
    total = int(height) * int(width)
    packed = (
        (arr[:, :, 0].astype(np.uint32) << 16) | (arr[:, :, 1].astype(np.uint32) << 8) | arr[:, :, 2].astype(np.uint32)
    )
    values, counts = np.unique(packed, return_counts=True)
    top = int(counts.argmax())
    dominant = int(counts[top])
    share = counts / float(total)
    nonblack = int((arr.max(axis=2) > black_level).sum())
    return {
        "width": int(width),
        "height": int(height),
        "pixels": total,
        "colours": int(values.size),
        "dominant_rgb": f"#{int(values[top]):06x}",
        "dominant_px": dominant,
        "dominant_frac": dominant / float(total),
        "nondominant_px": total - dominant,
        "nondominant_frac": (total - dominant) / float(total),
        "nonblack_px": nonblack,
        "nonblack_frac": nonblack / float(total),
        # + 0.0 turns IEEE's -0.0 (a single-colour frame) into a printable 0.0.
        "entropy_bits": float(-(share * np.log2(share)).sum()) + 0.0,
    }


def count_of(px: int, total: int) -> str:
    return f"{px} of {total} ({100 * px / float(total):.4f}%)"


def floor_gates(m: dict, floor: int, expect: tuple | None) -> list:
    """The emptiness gates as (name, measured, band, ok) — every one reported.

    A gate whose number is not printed is a gate nobody can check, which is how
    this repo has twice ended up with a step that reported success while doing
    nothing.
    """
    size = (m["width"], m["height"])
    gates = [
        (
            "geometry",
            f"{m['width']}x{m['height']}",
            f"== {expect[0]}x{expect[1]}" if expect else "(not declared)",
            expect is None or size == expect,
        ),
        ("distinct colours", str(m["colours"]), ">= 2", m["colours"] >= 2),
        ("entropy", f"{m['entropy_bits']:.4f} bits", "> 0", m["entropy_bits"] > 0.0),
        (
            "non-dominant px",
            count_of(m["nondominant_px"], m["pixels"]),
            f">= {floor}",
            m["nondominant_px"] >= floor,
        ),
    ]
    return gates


def compare(before, after, tol: int) -> dict:
    """Changed-pixel count, its bounding box, and how spread out it is."""
    delta = np.abs(before.astype(np.int16) - after.astype(np.int16)).max(axis=2)
    mask = delta > tol
    changed = int(mask.sum())
    result = {
        "changed_px": changed,
        "pixels": int(mask.size),
        "changed_frac": changed / float(mask.size),
        "max_channel_delta": int(delta.max()),
        "tolerance": tol,
        "box": None,
        "cells_touched": 0,
        "cells_total": int(math.ceil(mask.shape[0] / CELL) * math.ceil(mask.shape[1] / CELL)),
        "cell_px": CELL,
    }
    if changed:
        rows = np.nonzero(mask.any(axis=1))[0]
        cols = np.nonzero(mask.any(axis=0))[0]
        x0, y0 = int(cols[0]), int(rows[0])
        result["box"] = {"x": x0, "y": y0, "w": int(cols[-1]) - x0 + 1, "h": int(rows[-1]) - y0 + 1}
        grid = np.pad(mask, ((0, (-mask.shape[0]) % CELL), (0, (-mask.shape[1]) % CELL)))
        grid = grid.reshape(grid.shape[0] // CELL, CELL, grid.shape[1] // CELL, CELL)
        result["cells_touched"] = int(grid.any(axis=(1, 3)).sum())
    return result


def classify(diff: dict, motion_box: tuple) -> tuple:
    """(verdict, why). LOCALISED is a judgement about SHAPE, not about amount."""
    if diff["changed_px"] == 0:
        return "UNCHANGED", "not one pixel differs"
    box = diff["box"]
    if box["w"] <= motion_box[0] and box["h"] <= motion_box[1]:
        return (
            "LOCALISED",
            f"all {diff['changed_px']} changed px fit in one {box['w']}x{box['h']} box at "
            f"({box['x']},{box['y']}) — the shape of a cursor or clock cell, but only a "
            "human can say it IS one",
        )
    return (
        "DIFFERS",
        f"changed px span a {box['w']}x{box['h']} box across {diff['cells_touched']} of "
        f"{diff['cells_total']} {diff['cell_px']}px cells",
    )


def row(out, kind: str, name: str, measured: str, note: str) -> None:
    out.write(f"  {kind:<7} {name:<18} {measured:<34} {note}\n")


def print_frame(out, heading: str, m: dict, gates: list) -> bool:
    out.write(f"{heading}\n")
    ok = True
    for name, measured, band, passed in gates:
        ok = ok and passed
        row(out, "FLOOR", name, measured, f"{band:<14} {'PASS' if passed else 'FAIL'}")
    row(
        out,
        "report",
        "non-black px",
        count_of(m["nonblack_px"], m["pixels"]),
        "(not gated — mpf2's accepted golden is 99.71% black)",
    )
    row(
        out,
        "report",
        "dominant colour",
        f"{m['dominant_rgb']} {100 * m['dominant_frac']:.4f}%",
        "(not gated — 2-colour exhibits are normal)",
    )
    return ok


def print_diff(out, diff: dict, motion_box: tuple) -> None:
    box = diff["box"]
    out.write("BEFORE vs AFTER\n")
    row(out, "DIFF", "changed px", count_of(diff["changed_px"], diff["pixels"]), f"(tolerance {diff['tolerance']})")
    row(
        out,
        "DIFF",
        "max channel delta",
        str(diff["max_channel_delta"]),
        "(not gated — a cursor flip is already 255)",
    )
    row(
        out,
        "DIFF",
        "change box",
        "none" if box is None else f"x={box['x']} y={box['y']} {box['w']}x{box['h']}",
        f"LOCALISED if <= {motion_box[0]}x{motion_box[1]}",
    )
    row(
        out,
        "DIFF",
        f"{diff['cell_px']}px cells",
        f"{diff['cells_touched']} of {diff['cells_total']} touched",
        "(how spread out, not how much)",
    )


def parse_wh(text: str, flag: str) -> tuple:
    try:
        w, h = text.lower().split("x", 1)
        return int(w), int(h)
    except ValueError:
        sys.stderr.write(f"frame-compare: {flag} wants WxH, got {text!r}\n")
        raise SystemExit(2) from None


def finish(out, report: dict, verdict: str, why: str, code: int, as_json: bool) -> int:
    report["verdict"] = verdict
    report["why"] = why
    out.write(f"\nVERDICT {verdict} — {why}\n")
    if code != 1:
        out.write("A human still owes the identity judgement: is that the MACHINE's own screen?\n")
    if as_json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return code


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="compare two tile framebuffer PNGs, with an emptiness floor")
    p.add_argument("frames", nargs="*", metavar="PNG", help="before.png after.png")
    p.add_argument("--frame", metavar="PNG", help="single frame: run the emptiness floor only")
    p.add_argument("--min-nondominant", type=int, default=FLOOR_NONDOMINANT, metavar="N")
    p.add_argument("--motion-box", default=f"{MOTION_BOX[0]}x{MOTION_BOX[1]}", metavar="WxH")
    p.add_argument("--tol", type=int, default=0, metavar="N")
    p.add_argument("--black-level", type=int, default=8, metavar="N")
    p.add_argument("--expect", metavar="WxH", help="require this exact geometry")
    p.add_argument("--label", default="", metavar="TEXT")
    p.add_argument("--json", action="store_true", dest="as_json")
    return p


def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    out = sys.stderr if args.as_json else sys.stdout
    motion_box = parse_wh(args.motion_box, "--motion-box")
    expect = parse_wh(args.expect, "--expect") if args.expect else None

    if args.frame and args.frames:
        sys.stderr.write("frame-compare: --frame takes the place of the two positional PNGs\n")
        return 2
    if args.frame:
        paths, names = [args.frame], ["FRAME"]
    elif len(args.frames) == 2:
        paths, names = list(args.frames), ["BEFORE", "AFTER"]
    else:
        sys.stderr.write("frame-compare: need <before.png> <after.png>, or --frame <one.png>\n")
        return 2

    label = args.label or Path(paths[-1]).parent.name or Path(paths[-1]).stem
    report = {"label": label, "frames": {}, "floor": {"min_nondominant": args.min_nondominant}}
    out.write(f"frame-compare: {label}\n")

    broken = []
    arrays = []
    for name, path in zip(names, paths):
        arr = load(path)
        arrays.append(arr)
        metrics = frame_metrics(arr, args.black_level)
        gates = floor_gates(metrics, args.min_nondominant, expect)
        if not print_frame(out, f"{name}  {path}", metrics, gates):
            broken += [f"{name}/{g[0]}" for g in gates if not g[3]]
        metrics["path"] = path
        metrics["floor_gates"] = [{"gate": g[0], "measured": g[1], "band": g[2], "pass": bool(g[3])} for g in gates]
        report["frames"][name] = metrics

    if broken:
        empty = [g for g in broken if not g.endswith("/geometry")]
        return finish(
            out,
            report,
            "EMPTY-FRAME" if empty else "GEOMETRY",
            f"failed: {', '.join(broken)}. "
            + (
                "A frame this empty is not a running machine — it is the black-screen failure mode"
                if empty
                else "The frame is not the declared geometry, which is itself a regression class"
            )
            + ". No comparison was attempted: none can rescue it",
            1,
            args.as_json,
        )

    if len(arrays) == 1:
        return finish(
            out, report, "FLOOR-ONLY", "one frame given, so only the emptiness floor was evaluated", 0, args.as_json
        )

    before, after = arrays
    if before.shape != after.shape:
        b, a = report["frames"]["BEFORE"], report["frames"]["AFTER"]
        return finish(
            out,
            report,
            "GEOMETRY",
            f"BEFORE is {b['width']}x{b['height']}, AFTER is {a['width']}x{a['height']} — not "
            "comparable, and a resolution change is itself a regression class",
            1,
            args.as_json,
        )

    diff = compare(before, after, args.tol)
    verdict, why = classify(diff, motion_box)
    print_diff(out, diff, motion_box)
    report["diff"] = diff
    report["motion_box"] = {"w": motion_box[0], "h": motion_box[1]}
    return finish(out, report, verdict, why, 0 if verdict in ("UNCHANGED", "LOCALISED") else 10, args.as_json)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

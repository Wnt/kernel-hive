#!/usr/bin/env python3
"""Compare framebuffer captures for steady-state and unexpected-region motion."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from vision_common import emit_json, load_image, parse_box


def compare_frames(
    before_path: str | Path,
    after_path: str | Path,
    *,
    pixel_threshold: int = 18,
    steady_threshold: float = 0.001,
    expected_region: tuple[int, int, int, int] | str | None = None,
    unexpected_threshold: float = 0.0002,
) -> dict[str, Any]:
    before = load_image(before_path)
    after = load_image(after_path)
    if before.shape != after.shape:
        return {
            "steady": False,
            "unexpected_change": True,
            "reason": "dimension-change",
            "changed_fraction": 1.0,
            "steady_fraction": 1.0,
            "outside_expected_fraction": 1.0,
            "before_shape": list(before.shape),
            "after_shape": list(after.shape),
        }
    expected_region = parse_box(expected_region, (before.shape[1], before.shape[0]))
    first = cv2.GaussianBlur(cv2.cvtColor(before, cv2.COLOR_BGR2GRAY), (3, 3), 0)
    second = cv2.GaussianBlur(cv2.cvtColor(after, cv2.COLOR_BGR2GRAY), (3, 3), 0)
    delta = cv2.absdiff(first, second)
    changed = delta > pixel_threshold
    changed_fraction = float(np.count_nonzero(changed) / changed.size)
    points = cv2.findNonZero(changed.astype(np.uint8))
    change_box = list(cv2.boundingRect(points)) if points is not None else None

    outside_fraction = 0.0
    unexpected = False
    steady_fraction = changed_fraction
    if expected_region is not None:
        expected = np.zeros_like(changed, dtype=bool)
        x, y, width, height = expected_region
        x1, y1 = max(0, x), max(0, y)
        x2, y2 = min(changed.shape[1], x + width), min(changed.shape[0], y + height)
        expected[y1:y2, x1:x2] = True
        outside = np.logical_and(changed, np.logical_not(expected))
        outside_fraction = float(np.count_nonzero(outside) / outside.size)
        unexpected = outside_fraction > unexpected_threshold
        # Motion in the declared region is allowed (for example a progress
        # strip); stability and the watchdog are measured everywhere else.
        steady_fraction = outside_fraction
    return {
        "steady": steady_fraction <= steady_threshold,
        "unexpected_change": unexpected,
        "changed_fraction": round(changed_fraction, 8),
        "outside_expected_fraction": round(outside_fraction, 8),
        "steady_fraction": round(steady_fraction, 8),
        "mean_delta": round(float(delta.mean()), 4),
        "max_delta": int(delta.max()),
        "change_box": change_box,
        "pixel_threshold": pixel_threshold,
        "steady_threshold": steady_threshold,
        "expected_region": list(expected_region) if expected_region else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--pixel-threshold", type=int, default=18)
    parser.add_argument("--steady-threshold", type=float, default=0.001)
    parser.add_argument("--expected-region", help="x,y,width,height; changes outside are unexpected")
    parser.add_argument("--unexpected-threshold", type=float, default=0.0002)
    args = parser.parse_args()
    result = compare_frames(
        args.before,
        args.after,
        pixel_threshold=args.pixel_threshold,
        steady_threshold=args.steady_threshold,
        expected_region=args.expected_region,
        unexpected_threshold=args.unexpected_threshold,
    )
    emit_json(result)
    return 0 if result["steady"] and not result["unexpected_change"] else 2


if __name__ == "__main__":
    raise SystemExit(main())

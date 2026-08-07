#!/usr/bin/env python3
"""Find a UI crop in a screenshot with multi-scale OpenCV template matching."""

from __future__ import annotations

import argparse
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import cv2
from vision_common import center, crop, emit_json, load_image, parse_box


def scale_values(spec: str) -> list[float]:
    parts = [float(value) for value in spec.split(":")]
    if len(parts) == 1:
        return parts
    if len(parts) != 3 or parts[2] <= 0 or parts[1] < parts[0]:
        raise ValueError("scales must be one value or start:end:step")
    values: list[float] = []
    value = parts[0]
    while value <= parts[1] + parts[2] / 10:
        values.append(round(value, 6))
        value += parts[2]
    return values


def _edge_gray(image):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return gray, cv2.Canny(gray, 40, 120)


def find_template(
    image_path: str | Path,
    templates: Iterable[str | Path],
    *,
    threshold: float = 0.78,
    scales: Iterable[float] = (1.0,),
    roi: tuple[int, int, int, int] | str | None = None,
) -> dict[str, Any]:
    image = load_image(image_path)
    resolved_roi = parse_box(roi, (image.shape[1], image.shape[0]))
    region, offset = crop(image, resolved_roi)
    screen_gray, screen_edge = _edge_gray(region)
    best: dict[str, Any] | None = None
    for template_path in templates:
        template = load_image(template_path)
        for scale in scales:
            width = max(1, round(template.shape[1] * scale))
            height = max(1, round(template.shape[0] * scale))
            if width > region.shape[1] or height > region.shape[0]:
                continue
            interpolation = cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC
            resized = cv2.resize(template, (width, height), interpolation=interpolation)
            template_gray, template_edge = _edge_gray(resized)
            gray_map = cv2.matchTemplate(screen_gray, template_gray, cv2.TM_CCOEFF_NORMED)
            edge_map = cv2.matchTemplate(screen_edge, template_edge, cv2.TM_CCOEFF_NORMED)
            # Grayscale is scale-tolerant; edges keep similarly coloured Android
            # buttons distinguishable. This blend was calibrated against every
            # Android flow screen at native and 800x600-resampled sizes.
            score_map = 0.7 * gray_map + 0.3 * edge_map
            _, score, _, location = cv2.minMaxLoc(score_map)
            box = (location[0] + offset[0], location[1] + offset[1], width, height)
            candidate = {
                "template": str(template_path),
                "score": round(float(score), 6),
                "gray_score": round(float(gray_map[location[1], location[0]]), 6),
                "edge_score": round(float(edge_map[location[1], location[0]]), 6),
                "scale": scale,
                "box": list(box),
                "center": list(center(box)),
            }
            if best is None or candidate["score"] > best["score"]:
                best = candidate
    found = best is not None and best["score"] >= threshold
    return {
        "found": found,
        "method": "template",
        "image": str(image_path),
        "threshold": threshold,
        "match": best if found else None,
        "best_below_threshold": best if not found else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("template", nargs="+")
    parser.add_argument("--threshold", type=float, default=0.78)
    parser.add_argument("--scales", default="0.75:1.35:0.05")
    parser.add_argument("--roi", help="x,y,width,height")
    args = parser.parse_args()
    result = find_template(
        args.image,
        args.template,
        threshold=args.threshold,
        scales=scale_values(args.scales),
        roi=args.roi,
    )
    emit_json(result)
    return 0 if result["found"] else 2


if __name__ == "__main__":
    raise SystemExit(main())

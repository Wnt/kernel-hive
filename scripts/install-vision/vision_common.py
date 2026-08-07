#!/usr/bin/env python3
"""Shared image and CLI helpers for install-vision."""

from __future__ import annotations

import json
import re
from collections.abc import Iterable, Sequence
from pathlib import Path

import cv2
import numpy as np

Box = tuple[int, int, int, int]


def load_image(path: str | Path, flags: int = cv2.IMREAD_COLOR) -> np.ndarray:
    image = cv2.imread(str(path), flags)
    if image is None:
        raise ValueError(f"cannot decode image: {path}")
    return image


def parse_box(
    value: str | Box | None,
    image_size: tuple[int, int] | None = None,
) -> Box | None:
    if not value:
        return None
    if isinstance(value, tuple):
        return value
    if value.startswith("rel:"):
        if image_size is None:
            raise ValueError("relative region requires image dimensions")
        fractions = [float(part) for part in value[4:].split(",")]
        if len(fractions) != 4 or any(part < 0 or part > 1 for part in fractions):
            raise ValueError("relative region must be rel:x,y,width,height using 0..1")
        width, height = image_size
        parts = [
            round(fractions[0] * width),
            round(fractions[1] * height),
            round(fractions[2] * width),
            round(fractions[3] * height),
        ]
    else:
        parts = [int(part) for part in value.split(",")]
    if len(parts) != 4 or parts[2] <= 0 or parts[3] <= 0:
        raise ValueError("region must be x,y,width,height with positive dimensions")
    return tuple(parts)  # type: ignore[return-value]


def crop(image: np.ndarray, box: Box | None) -> tuple[np.ndarray, tuple[int, int]]:
    if box is None:
        return image, (0, 0)
    x, y, width, height = box
    ih, iw = image.shape[:2]
    x1, y1 = max(0, x), max(0, y)
    x2, y2 = min(iw, x + width), min(ih, y + height)
    if x1 >= x2 or y1 >= y2:
        raise ValueError(f"region {box} does not intersect {iw}x{ih} image")
    return image[y1:y2, x1:x2], (x1, y1)


def normalize_text(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def center(box: Sequence[int]) -> tuple[int, int]:
    x, y, width, height = box
    return round(x + width / 2), round(y + height / 2)


def emit_json(value: object) -> None:
    print(json.dumps(value, sort_keys=True))


def union_boxes(boxes: Iterable[Sequence[int]]) -> Box:
    boxes = list(boxes)
    x1 = min(box[0] for box in boxes)
    y1 = min(box[1] for box in boxes)
    x2 = max(box[0] + box[2] for box in boxes)
    y2 = max(box[1] + box[3] for box in boxes)
    return x1, y1, x2 - x1, y2 - y1

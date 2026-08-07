#!/usr/bin/env python3
"""Find an OCR phrase in a screenshot and return click-centre coordinates."""

from __future__ import annotations

import argparse
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

import cv2
import pytesseract
from pytesseract import Output
from vision_common import center, crop, emit_json, load_image, normalize_text, parse_box, union_boxes


def _words(image, min_confidence: float) -> list[dict[str, Any]]:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    # Upscaling small UI text and local contrast improve Tesseract on VM frames.
    if min(gray.shape[:2]) < 900:
        gray = cv2.resize(gray, None, fx=1.5, fy=1.5, interpolation=cv2.INTER_CUBIC)
        scale = 1.5
    else:
        scale = 1.0
    gray = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    data = pytesseract.image_to_data(gray, output_type=Output.DICT, config="--psm 11")
    words: list[dict[str, Any]] = []
    for index, raw in enumerate(data["text"]):
        text = raw.strip()
        try:
            confidence = float(data["conf"][index])
        except (TypeError, ValueError):
            confidence = -1
        if not normalize_text(text) or confidence < min_confidence:
            continue
        box = tuple(round(int(data[key][index]) / scale) for key in ("left", "top", "width", "height"))
        words.append(
            {
                "text": text,
                "normalized": normalize_text(text),
                "confidence": confidence,
                "box": box,
                "line": (data["block_num"][index], data["par_num"][index], data["line_num"][index]),
            }
        )
    return words


def find_text(
    image_path: str | Path,
    target: str,
    *,
    min_confidence: float = 25,
    min_similarity: float = 0.82,
    roi: tuple[int, int, int, int] | str | None = None,
) -> dict[str, Any]:
    image = load_image(image_path)
    resolved_roi = parse_box(roi, (image.shape[1], image.shape[0]))
    region, offset = crop(image, resolved_roi)
    words = _words(region, min_confidence)
    wanted = normalize_text(target)
    if not wanted:
        raise ValueError("target must contain at least one letter or digit")

    candidates: list[dict[str, Any]] = []
    # Phrase candidates stay on one OCR line. Wider n-grams tolerate a split or
    # one spurious short token while keeping unrelated screen copy out.
    for start, word in enumerate(words):
        line_words = []
        for current in words[start : start + 6]:
            if current["line"] != word["line"]:
                break
            line_words.append(current)
            combined = "".join(item["normalized"] for item in line_words)
            similarity = SequenceMatcher(None, wanted, combined).ratio()
            length_ratio = min(len(wanted), len(combined)) / max(len(wanted), len(combined))
            contains = (wanted in combined or combined in wanted) and length_ratio >= 0.8
            if similarity < min_similarity and not contains:
                continue
            local_box = union_boxes(item["box"] for item in line_words)
            box = (local_box[0] + offset[0], local_box[1] + offset[1], local_box[2], local_box[3])
            candidates.append(
                {
                    "text": " ".join(item["text"] for item in line_words),
                    "box": list(box),
                    "center": list(center(box)),
                    "confidence": round(sum(item["confidence"] for item in line_words) / len(line_words), 3),
                    "similarity": round(similarity, 4),
                }
            )

    candidates.sort(key=lambda item: (item["similarity"], item["confidence"]), reverse=True)
    return {
        "found": bool(candidates),
        "method": "ocr",
        "target": target,
        "image": str(image_path),
        "match": candidates[0] if candidates else None,
        "candidates": candidates,
        "word_count": len(words),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("target")
    parser.add_argument("--min-confidence", type=float, default=25)
    parser.add_argument("--min-similarity", type=float, default=0.82)
    parser.add_argument("--roi", help="x,y,width,height")
    args = parser.parse_args()
    result = find_text(
        args.image,
        args.target,
        min_confidence=args.min_confidence,
        min_similarity=args.min_similarity,
        roi=args.roi,
    )
    emit_json(result)
    return 0 if result["found"] else 2


if __name__ == "__main__":
    raise SystemExit(main())

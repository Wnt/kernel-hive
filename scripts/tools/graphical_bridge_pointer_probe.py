#!/usr/bin/env python3
"""Assert graphical-bridge absolute pointer landings from QMP screendumps.

The guest must be running graphical-bridge-pointer-probe, whose green 3x3 marker
exposes the X pointer in the captured framebuffer. Pointer injection uses the
same QEMU Display1 SetAbsPosition method as streamhost's dbus-abs backend.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import time
from pathlib import Path

POINTS = (
    ("top-left", 0.0, 0.0),
    ("top-mid", 0.5, 0.0),
    ("top-right", 1.0, 0.0),
    ("left-mid", 0.0, 0.5),
    ("center", 0.5, 0.5),
    ("right-mid", 1.0, 0.5),
    ("bottom-left", 0.0, 1.0),
    ("bottom-mid", 0.5, 1.0),
    ("bottom-right", 1.0, 1.0),
)


def ppm_tokens(data: bytes):
    index = 0
    while index < len(data):
        while index < len(data) and chr(data[index]).isspace():
            index += 1
        if index < len(data) and data[index] == ord("#"):
            while index < len(data) and data[index] not in (10, 13):
                index += 1
            continue
        start = index
        while index < len(data) and not chr(data[index]).isspace():
            index += 1
        if start != index:
            yield data[start:index], index


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    tokens = ppm_tokens(data)
    magic, _ = next(tokens)
    width_token, _ = next(tokens)
    height_token, _ = next(tokens)
    max_token, header_end = next(tokens)
    if magic != b"P6" or max_token != b"255":
        raise ValueError(f"{path}: expected binary 8-bit PPM, got {magic!r} max={max_token!r}")
    if header_end >= len(data) or not chr(data[header_end]).isspace():
        raise ValueError(f"{path}: missing PPM header delimiter")
    if data[header_end : header_end + 2] == b"\r\n":
        header_end += 2
    else:
        header_end += 1
    width = int(width_token)
    height = int(height_token)
    pixels = data[header_end:]
    expected = width * height * 3
    if len(pixels) != expected:
        raise ValueError(f"{path}: expected {expected} pixel bytes, got {len(pixels)}")
    return width, height, pixels


def marker_landing(path: Path, locator: Path | None = None) -> tuple[int, int, int, int]:
    width, height, pixels = read_ppm(path)
    if locator is not None:
        output = subprocess.check_output([str(locator), str(path)], text=True).split()
        if len(output) != 2:
            raise ValueError(f"{locator}: expected 'x y', got {output!r}")
        return width, height, int(output[0]), int(output[1])
    hits: list[tuple[int, int]] = []
    for offset in range(0, len(pixels), 3):
        red, green, blue = pixels[offset : offset + 3]
        if green >= 224 and red <= 32 and blue <= 32:
            pixel = offset // 3
            hits.append((pixel % width, pixel // width))
    if not hits:
        raise ValueError(f"{path}: green pointer marker not found")
    # At an edge the nominal 3x3 square is clipped to two pixels. The rounded
    # centroid still recovers the intended edge coordinate exactly.
    x = round(sum(point[0] for point in hits) / len(hits))
    y = round(sum(point[1] for point in hits) / len(hits))
    return width, height, x, y


def linear_fit(pairs: list[tuple[int, int]]) -> dict[str, float]:
    expected_mean = sum(pair[0] for pair in pairs) / len(pairs)
    landing_mean = sum(pair[1] for pair in pairs) / len(pairs)
    variance = sum((pair[0] - expected_mean) ** 2 for pair in pairs)
    slope = sum((pair[0] - expected_mean) * (pair[1] - landing_mean) for pair in pairs) / variance
    intercept = landing_mean - slope * expected_mean
    return {
        "slope": round(slope, 6),
        "intercept": round(intercept, 3),
        "suggestedScale": round(1 / slope, 6),
    }


def cdrv(driver: Path, qmp: Path, *args: str) -> None:
    subprocess.run(
        ["python3", str(driver), str(qmp), *args],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qmp", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--driver", default="/root/cdrv.py", type=Path)
    parser.add_argument("--tolerance", default=2.0, type=float)
    parser.add_argument("--settle-ms", default=120, type=int)
    parser.add_argument("--results", type=Path)
    parser.add_argument(
        "--locator",
        type=Path,
        help="optional executable receiving PPM path and printing the emulator cursor as 'x y'",
    )
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    first = args.out_dir / "dimensions.ppm"
    cdrv(args.driver, args.qmp, "dump", str(first))
    width, height, _, _ = marker_landing(first, args.locator)
    # QMP's usb-tablet input-send-event can treat the first absolute report
    # after a cold boot as device initialization. Prime both axes once so the
    # first asserted corner is a measurement, not the tablet's wake-up report.
    cdrv(args.driver, args.qmp, "abs", "16384", "16384")
    time.sleep(args.settle_ms / 1000)

    results = []
    failed = False
    for name, fraction_x, fraction_y in POINTS:
        expected_x = round(fraction_x * (width - 1))
        expected_y = round(fraction_y * (height - 1))
        # cdrv's QMP input-send-event interface uses the usb-tablet's canonical
        # 0..32767 axis range. The streamhost D-Bus method consumes pixels; both
        # routes terminate at the same tablet/X input path.
        driver_x = round(fraction_x * 32767)
        driver_y = round(fraction_y * 32767)
        cdrv(args.driver, args.qmp, "abs", str(driver_x), str(driver_y))
        time.sleep(args.settle_ms / 1000)
        shot = args.out_dir / f"{name}.ppm"
        cdrv(args.driver, args.qmp, "dump", str(shot))
        shot_width, shot_height, landing_x, landing_y = marker_landing(shot, args.locator)
        if (shot_width, shot_height) != (width, height):
            raise ValueError(f"{shot}: geometry changed from {width}x{height} to {shot_width}x{shot_height}")
        error_x = landing_x - expected_x
        error_y = landing_y - expected_y
        error = math.hypot(error_x, error_y)
        passed = abs(error_x) <= args.tolerance and abs(error_y) <= args.tolerance
        failed |= not passed
        results.append(
            {
                "name": name,
                "fraction": [fraction_x, fraction_y],
                "driver": [driver_x, driver_y],
                "expected": [expected_x, expected_y],
                "landing": [landing_x, landing_y],
                "error": [error_x, error_y],
                "euclideanError": round(error, 3),
                "pass": passed,
                "framebuffer": str(shot),
            }
        )
        verdict = "PASS" if passed else "FAIL"
        print(
            f"{verdict} {name:12} command=({expected_x:4},{expected_y:4}) "
            f"landing=({landing_x:4},{landing_y:4}) error=({error_x:+d},{error_y:+d})"
        )

    report = {
        "contract": "QEMU Display1 SetAbsPosition -> usb-tablet -> kiosk X11 -> framebuffer marker",
        "geometry": [width, height],
        "tolerancePerAxisPx": args.tolerance,
        "points": results,
        "fit": {
            "x": linear_fit([(point["expected"][0], point["landing"][0]) for point in results]),
            "y": linear_fit([(point["expected"][1], point["landing"][1]) for point in results]),
        },
        "pass": not failed,
    }
    results_path = args.results or args.out_dir / "results.json"
    results_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if not failed else 'FAIL'} {len(results)} points; report={results_path}")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())

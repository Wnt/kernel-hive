#!/usr/bin/env python3
"""Capture, detect, QMP-tap, and wait for an installer screen to settle."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import cv2
from find_template import find_template, scale_values
from find_text import find_text
from qmp import QMPClient
from settle import compare_frames
from vision_common import emit_json


def capture(qmp: QMPClient, path: Path) -> None:
    ppm = path.with_suffix(".ppm")
    qmp.screendump(ppm)
    image = cv2.imread(str(ppm))
    if image is None or not cv2.imwrite(str(path), image):
        raise RuntimeError(f"failed to convert screendump {ppm} to {path}")
    ppm.unlink(missing_ok=True)


def detect(args, image: Path) -> dict[str, Any]:
    attempts: list[dict[str, Any]] = []
    if args.text:
        result = find_text(
            image,
            args.text,
            min_confidence=args.min_confidence,
            min_similarity=args.min_similarity,
            roi=args.roi,
        )
        attempts.append(result)
        if result["found"]:
            return {"found": True, "selected": result, "attempts": attempts}
    if args.template:
        result = find_template(
            image,
            args.template,
            threshold=args.template_threshold,
            scales=scale_values(args.scales),
            roi=args.roi,
        )
        attempts.append(result)
        if result["found"]:
            return {"found": True, "selected": result, "attempts": attempts}
    return {"found": False, "selected": None, "attempts": attempts}


def settle(
    qmp: QMPClient,
    directory: Path,
    name: str,
    args,
    *,
    initial_frame: Path | None = None,
    require_change: bool = False,
) -> dict[str, Any]:
    deadline = time.monotonic() + args.timeout
    if initial_frame is None:
        prior = directory / f"{name}-settle-00.png"
        capture(qmp, prior)
    else:
        prior = initial_frame
    steady_runs = 0
    transition_seen = not require_change
    watchdog_armed = not require_change or args.expected_region is None
    comparisons: list[dict[str, Any]] = []
    index = 1
    while time.monotonic() < deadline:
        time.sleep(args.interval)
        current = directory / f"{name}-settle-{index:02d}.png"
        capture(qmp, current)
        result = compare_frames(
            prior,
            current,
            pixel_threshold=args.pixel_threshold,
            steady_threshold=args.steady_threshold,
            expected_region=args.expected_region,
            unexpected_threshold=args.unexpected_threshold,
        )
        comparisons.append(result)
        if result["unexpected_change"] and watchdog_armed:
            return {
                "settled": False,
                "transition_seen": transition_seen,
                "watchdog": True,
                "comparisons": comparisons,
                "frame": str(current),
            }
        if result["changed_fraction"] >= args.transition_threshold:
            transition_seen = True
        if transition_seen and result["steady"] and not watchdog_armed:
            watchdog_armed = True
            steady_runs = 0
            prior = current
            index += 1
            continue
        steady_runs = steady_runs + 1 if transition_seen and result["steady"] else 0
        if transition_seen and steady_runs >= args.steady_frames:
            return {
                "settled": True,
                "transition_seen": transition_seen,
                "watchdog": False,
                "comparisons": comparisons,
                "frame": str(current),
            }
        prior = current
        index += 1
    return {
        "settled": False,
        "transition_seen": transition_seen,
        "watchdog": False,
        "timeout": True,
        "comparisons": comparisons,
        "frame": str(prior),
    }


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--qmp", required=True, help="Unix QMP socket for the task's clone")
    parser.add_argument("--work-dir", required=True)


def add_settle(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--steady-frames", type=int, default=2)
    parser.add_argument("--pixel-threshold", type=int, default=18)
    parser.add_argument("--steady-threshold", type=float, default=0.001)
    parser.add_argument("--transition-threshold", type=float, default=0.01)
    parser.add_argument("--expected-region", help="x,y,width,height; change outside triggers watchdog")
    parser.add_argument("--unexpected-threshold", type=float, default=0.0002)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    shot = sub.add_parser("shot")
    add_common(shot)
    shot.add_argument("name")

    tap = sub.add_parser("tap")
    add_common(tap)
    tap.add_argument("x", type=int)
    tap.add_argument("y", type=int)

    wait = sub.add_parser("settle")
    add_common(wait)
    add_settle(wait)
    wait.add_argument("name")

    step = sub.add_parser("step")
    add_common(step)
    add_settle(step)
    step.add_argument("name")
    step.add_argument("--text")
    step.add_argument("--template", action="append")
    step.add_argument("--roi", help="detector region x,y,width,height")
    step.add_argument("--min-confidence", type=float, default=25)
    step.add_argument("--min-similarity", type=float, default=0.82)
    step.add_argument("--template-threshold", type=float, default=0.78)
    step.add_argument("--scales", default="0.75:1.35:0.05")
    step.add_argument("--detect-timeout", type=float, default=90)
    step.add_argument("--detect-interval", type=float, default=2)
    step.add_argument("--checkpoint", help="savevm name created after detection and before the tap")
    step.add_argument("--click-retries", type=int, default=2)
    step.add_argument("--input-timeout", type=float, default=2)
    step.add_argument("--input-interval", type=float, default=0.5)
    args = parser.parse_args()
    if args.command == "step":
        if args.click_retries < 1:
            parser.error("--click-retries must be at least 1")
        if args.input_timeout <= 0 or args.input_interval <= 0:
            parser.error("--input-timeout and --input-interval must be positive")

    directory = Path(args.work_dir)
    directory.mkdir(parents=True, exist_ok=True)
    with QMPClient(args.qmp) as qmp:
        if args.command == "shot":
            path = directory / f"{args.name}.png"
            capture(qmp, path)
            result = {"captured": True, "frame": str(path)}
        elif args.command == "tap":
            path = directory / "tap-frame.png"
            capture(qmp, path)
            image = cv2.imread(str(path))
            qmp.tap(args.x, args.y, image.shape[1], image.shape[0])
            result = {"tapped": True, "center": [args.x, args.y], "frame": str(path)}
        elif args.command == "settle":
            result = settle(qmp, directory, args.name, args)
        else:
            before = directory / f"{args.name}-before.png"
            detect_deadline = time.monotonic() + args.detect_timeout
            while True:
                capture(qmp, before)
                detection = detect(args, before)
                if detection["found"] or time.monotonic() >= detect_deadline:
                    break
                time.sleep(args.detect_interval)
            if not detection["found"]:
                result = {"clicked": False, "detection": detection, "frame": str(before)}
            else:
                image = cv2.imread(str(before))
                x, y = detection["selected"]["match"]["center"]
                if args.checkpoint:
                    checkpoint_result = qmp.hmp(f"savevm {args.checkpoint}")
                    if checkpoint_result.strip():
                        raise RuntimeError(f"savevm {args.checkpoint} failed: {checkpoint_result.strip()}")
                click_attempts: list[dict[str, Any]] = []
                transition_seen = False
                for attempt in range(1, args.click_retries + 1):
                    qmp.tap(x, y, image.shape[1], image.shape[0])
                    input_deadline = time.monotonic() + args.input_timeout
                    while time.monotonic() < input_deadline:
                        time.sleep(args.input_interval)
                        probe = directory / f"{args.name}-input-{attempt}.png"
                        capture(qmp, probe)
                        comparison = compare_frames(
                            before,
                            probe,
                            pixel_threshold=args.pixel_threshold,
                            steady_threshold=args.steady_threshold,
                        )
                        transition_seen = comparison["changed_fraction"] >= args.transition_threshold
                        if transition_seen:
                            break
                    click_attempts.append(
                        {
                            "attempt": attempt,
                            "transition_seen": transition_seen,
                            "comparison": comparison,
                        }
                    )
                    if transition_seen:
                        break
                settled = (
                    settle(
                        qmp,
                        directory,
                        args.name,
                        args,
                        initial_frame=before,
                        require_change=True,
                    )
                    if transition_seen
                    else {
                        "settled": False,
                        "transition_seen": False,
                        "watchdog": False,
                        "reason": "input-not-accepted",
                    }
                )
                result = {
                    "clicked": True,
                    "center": [x, y],
                    "method": detection["selected"]["method"],
                    "checkpoint": args.checkpoint,
                    "click_attempts": click_attempts,
                    "detection": detection,
                    "settle": settled,
                    "frame": str(before),
                }
    log = directory / f"{getattr(args, 'name', args.command)}.json"
    log.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    emit_json(result)
    if args.command == "step":
        return 0 if result.get("clicked") and result.get("settle", {}).get("settled") else 2
    if args.command == "settle":
        return 0 if result.get("settled") else 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

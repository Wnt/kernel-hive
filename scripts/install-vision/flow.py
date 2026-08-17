#!/usr/bin/env python3
"""Run declarative framebuffer/QMP install flows and capture template crops."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

import cv2
import yaml
from driver import capture, settle
from find_template import find_template, scale_values
from find_text import find_text
from qmp import QMPClient
from vision_common import crop, load_image, parse_box

ACTIONS = {"tap_text", "tap_template", "type", "key", "wait_text", "wait_template", "settle", "sleep", "screenshot"}
ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SETTLE_DEFAULTS = {
    "timeout": 30,
    "interval": 1,
    "steady_frames": 2,
    "pixel_threshold": 18,
    "steady_threshold": 0.001,
    "transition_threshold": 0.01,
    "expected_region": None,
    "unexpected_threshold": 0.0002,
}
CHAR_KEYS = {
    " ": "spc",
    "-": "minus",
    "_": "shift-minus",
    "=": "equal",
    "+": "shift-equal",
    "[": "bracket_left",
    "{": "shift-bracket_left",
    "]": "bracket_right",
    "}": "shift-bracket_right",
    "\\": "backslash",
    "|": "shift-backslash",
    ";": "semicolon",
    ":": "shift-semicolon",
    "'": "apostrophe",
    '"': "shift-apostrophe",
    "`": "grave_accent",
    "~": "shift-grave_accent",
    ",": "comma",
    "<": "shift-comma",
    ".": "dot",
    ">": "shift-dot",
    "/": "slash",
    "?": "shift-slash",
    "!": "shift-1",
    "@": "shift-2",
    "#": "shift-3",
    "$": "shift-4",
    "%": "shift-5",
    "^": "shift-6",
    "&": "shift-7",
    "*": "shift-8",
    "(": "shift-9",
    ")": "shift-0",
}


class FlowError(RuntimeError):
    pass


class Secrets:
    def __init__(self) -> None:
        self.values: list[str] = []

    def expand(self, value: Any) -> Any:
        if isinstance(value, str):

            def replace(match: re.Match[str]) -> str:
                name = match.group(1)
                if name not in os.environ:
                    raise FlowError(f"required environment variable {name} is not set")
                secret = os.environ[name]
                if not secret:
                    raise FlowError(f"required environment variable {name} is empty")
                self.values.append(secret)
                return secret

            return ENV_REF.sub(replace, value)
        if isinstance(value, list):
            return [self.expand(item) for item in value]
        if isinstance(value, dict):
            return {key: self.expand(item) for key, item in value.items()}
        return value

    def redact(self, value: str) -> str:
        for secret in sorted(set(self.values), key=len, reverse=True):
            value = value.replace(secret, "<secret>")
        return value


def load_flow(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        raise FlowError(f"cannot load flow {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("version") != 1:
        raise FlowError("flow must be a mapping with version: 1")
    if not isinstance(value.get("steps"), list) or not value["steps"]:
        raise FlowError("flow steps must be a non-empty list")
    return value


def assert_clone_qmp(value: str) -> None:
    root = Path(os.environ.get("CLONE_GUARD_CLONE_ROOT", "/data/vms/sandbox")).resolve()
    path = Path(value).resolve()
    if path == root or root not in path.parents:
        raise FlowError(f"QMP socket must be inside clone root {root}/")


def action_config(value: Any, scalar_key: str) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    return {scalar_key: value}


def public_match(result: dict[str, Any]) -> dict[str, Any]:
    match = result.get("match") or result.get("best_below_threshold") or {}
    return {key: match[key] for key in ("center", "box", "score", "scale", "confidence", "similarity") if key in match}


class Runner:
    def __init__(self, flow_path: Path, flow: dict[str, Any], qmp: QMPClient, work: Path):
        self.flow_path, self.flow, self.qmp, self.work = flow_path, flow, qmp, work
        self.fixtures = (flow_path.parent / flow.get("fixtures_dir", ".")).resolve()
        self.defaults = flow.get("defaults", {})
        self.secrets = Secrets()
        self.records: list[dict[str, Any]] = []
        self.work.mkdir(parents=True, exist_ok=True)

    def shot(self, name: str) -> Path:
        path = self.work / f"{name}.png"
        capture(self.qmp, path)
        return path

    def template_paths(self, value: Any) -> list[Path]:
        values = value if isinstance(value, list) else [value]
        paths = [(self.fixtures / str(item)).resolve() for item in values]
        if any(self.fixtures not in path.parents for path in paths):
            raise FlowError("template path escapes fixtures_dir")
        missing = [str(path) for path in paths if not path.is_file()]
        if missing:
            raise FlowError(f"template fixture not found: {', '.join(missing)}")
        return paths

    def detect(self, kind: str, config: dict[str, Any], frame: Path) -> dict[str, Any]:
        roi = config.get("roi")
        if kind.endswith("text"):
            return find_text(
                frame,
                str(config["text"]),
                min_confidence=float(config.get("min_confidence", self.defaults.get("min_confidence", 25))),
                min_similarity=float(config.get("min_similarity", self.defaults.get("min_similarity", 0.82))),
                roi=roi,
            )
        return find_template(
            frame,
            self.template_paths(config["template"]),
            threshold=float(config.get("threshold", self.defaults.get("template_threshold", 0.72))),
            scales=scale_values(str(config.get("scales", self.defaults.get("scales", "1.0")))),
            roi=roi,
        )

    def wait_detect(
        self, kind: str, config: dict[str, Any], stem: str, optional: bool = False
    ) -> tuple[dict[str, Any], Path]:
        timeout = float(config.get("timeout", self.defaults.get("detect_timeout", 90)))
        if optional:
            timeout = float(config.get("timeout", self.defaults.get("optional_timeout", 0)))
        interval = float(config.get("interval", self.defaults.get("detect_interval", 2)))
        deadline = time.monotonic() + max(0, timeout)
        attempt = 0
        while True:
            attempt += 1
            frame = self.shot(f"{stem}-probe-{attempt:03d}")
            result = self.detect(kind, config, frame)
            if result["found"] or time.monotonic() >= deadline:
                return result, frame
            time.sleep(interval)

    def send_key(self, value: str) -> None:
        result = self.qmp.hmp(f"sendkey {value}")
        if result.strip():
            raise FlowError(f"QMP rejected a key action: {result.strip()}")
        time.sleep(float(self.defaults.get("key_delay", 0.12)))

    def type_text(self, value: str) -> None:
        for char in value:
            if char.isascii() and char.isalpha():
                key = char.lower() if char.islower() else f"shift-{char.lower()}"
            elif char.isascii() and char.isdigit():
                key = char
            elif char in CHAR_KEYS:
                key = CHAR_KEYS[char]
            else:
                raise FlowError("typed value contains a character without a QEMU qcode mapping")
            try:
                self.send_key(key)
            except Exception:
                # Even a rejected qcode can disclose one character of a secret.
                raise FlowError("QMP rejected typed input") from None

    def checkpoint(self, index: int, name: str, raw: Any) -> dict[str, Any]:
        config = self.secrets.expand(raw)
        if not isinstance(config, dict) or ("text" in config) == ("template" in config):
            raise FlowError("checkpoint requires exactly one of text or template")
        kind = "wait_text" if "text" in config else "wait_template"
        result, frame = self.wait_detect(kind, config, f"{index:02d}-{name}-checkpoint")
        record = {
            "frame": str(frame),
            "assertion": kind.removeprefix("wait_"),
            "matched": bool(result["found"]),
            "match": public_match(result),
        }
        if not result["found"]:
            raise FlowError(f"checkpoint assertion failed (frame: {frame})")
        return record

    def execute(self, index: int, raw_step: Any) -> None:
        if not isinstance(raw_step, dict):
            raise FlowError("step must be a mapping")
        name = str(raw_step.get("name", f"step-{index}"))
        if not SAFE_NAME.fullmatch(name):
            raise FlowError("step name must use only letters, digits, dot, underscore, and dash")
        actions = ACTIONS.intersection(raw_step)
        if len(actions) != 1:
            raise FlowError("step must contain exactly one supported action")
        action = actions.pop()
        optional = raw_step.get("optional", False)
        if not isinstance(optional, bool):
            raise FlowError("optional must be true or false")
        if optional and action not in {"tap_text", "tap_template", "wait_text", "wait_template"}:
            raise FlowError("optional is valid only for detect/wait actions")
        value = self.secrets.expand(raw_step[action])
        record: dict[str, Any] = {"index": index, "name": name, "action": action, "status": "passed"}
        stem = f"{index:02d}-{name}"

        if action in {"tap_text", "wait_text"}:
            config = action_config(value, "text")
            result, frame = self.wait_detect(action, config, stem, optional)
            record.update({"frame": str(frame), "matched": bool(result["found"]), "match": public_match(result)})
        elif action in {"tap_template", "wait_template"}:
            config = action_config(value, "template")
            result, frame = self.wait_detect(action, config, stem, optional)
            record.update({"frame": str(frame), "matched": bool(result["found"]), "match": public_match(result)})
        elif action == "type":
            self.type_text(str(value))
        elif action == "key":
            for key in value if isinstance(value, list) else [value]:
                self.send_key(str(key))
        elif action == "sleep":
            time.sleep(float(value))
        elif action == "screenshot":
            label = str(value)
            if not SAFE_NAME.fullmatch(label):
                raise FlowError("screenshot label contains unsafe characters")
            record["frame"] = str(self.shot(f"{stem}-{label}"))
        else:
            config = value if isinstance(value, dict) else {}
            args = argparse.Namespace(**{**SETTLE_DEFAULTS, **self.defaults, **config})
            settled = settle(self.qmp, self.work, stem, args)
            record["settle"] = {
                key: settled.get(key)
                for key in ("settled", "transition_seen", "watchdog", "timeout", "frame")
                if key in settled
            }
            if not settled.get("settled"):
                raise FlowError(f"framebuffer did not settle (frame: {settled.get('frame')})")

        if action.startswith("tap_"):
            if not result["found"]:
                if optional:
                    record["status"] = "skipped"
                else:
                    raise FlowError(f"target not found (frame: {frame})")
            else:
                image = load_image(frame)
                point = config.get("at", result["match"]["center"])
                if not isinstance(point, list) or len(point) != 2:
                    raise FlowError("tap at must be [x, y]")
                self.qmp.tap(int(point[0]), int(point[1]), image.shape[1], image.shape[0])
                record["tap"] = [int(point[0]), int(point[1])]
        elif action.startswith("wait_") and not result["found"]:
            if optional:
                record["status"] = "skipped"
            else:
                raise FlowError(f"state not found (frame: {frame})")

        if "checkpoint" in raw_step and record["status"] != "skipped":
            record["checkpoint"] = self.checkpoint(index, name, raw_step["checkpoint"])
        self.records.append(record)
        print(f"[{index}/{len(self.flow['steps'])}] {name}: {record['status']} ({action})", file=sys.stderr)

    def run(self) -> dict[str, Any]:
        for index, step in enumerate(self.flow["steps"], 1):
            name = step.get("name", f"step-{index}") if isinstance(step, dict) else f"step-{index}"
            try:
                self.execute(index, step)
            except Exception as exc:
                safe_name = str(name) if SAFE_NAME.fullmatch(str(name)) else f"step-{index}"
                failed = self.shot(f"{index:02d}-{safe_name}-FAILED")
                message = self.secrets.redact(str(exc))
                self.records.append(
                    {"index": index, "name": name, "status": "failed", "error": message, "frame": str(failed)}
                )
                return {
                    "flow": self.flow.get("name", self.flow_path.stem),
                    "status": "failed",
                    "failed_step": {"index": index, "name": name},
                    "error": message,
                    "frame": str(failed),
                    "steps": self.records,
                }
        return {"flow": self.flow.get("name", self.flow_path.stem), "status": "passed", "steps": self.records}


def select_region(path: Path) -> tuple[int, int, int, int]:
    try:
        import tkinter as tk

        from PIL import Image, ImageTk

        root = tk.Tk()
        root.title("install-vision capture — drag a rectangle, Enter accepts, Esc cancels")
        source = Image.open(path)
        photo = ImageTk.PhotoImage(source)
        canvas = tk.Canvas(root, width=source.width, height=source.height, cursor="cross")
        canvas.pack()
        canvas.create_image(0, 0, anchor="nw", image=photo)
        state: dict[str, Any] = {"start": None, "rect": None, "box": None}

        def press(event):
            state["start"] = (event.x, event.y)

        def drag(event):
            if state["start"] is None:
                return
            if state["rect"] is not None:
                canvas.delete(state["rect"])
            x, y = state["start"]
            state["rect"] = canvas.create_rectangle(x, y, event.x, event.y, outline="#ff006e", width=2)
            state["box"] = (min(x, event.x), min(y, event.y), abs(event.x - x), abs(event.y - y))

        canvas.bind("<Button-1>", press)
        canvas.bind("<B1-Motion>", drag)
        root.bind("<Return>", lambda _e: root.destroy())
        root.bind("<Escape>", lambda _e: (state.update(box=None), root.destroy()))
        root.mainloop()
    except Exception as exc:
        raise FlowError(f"interactive crop picker unavailable ({exc}); use --region x,y,width,height") from exc
    if not state["box"] or state["box"][2] <= 0 or state["box"][3] <= 0:
        raise FlowError("no capture region selected")
    return state["box"]


def capture_command(args: argparse.Namespace) -> dict[str, Any]:
    flow = load_flow(args.flow)
    fixtures = (args.flow.parent / flow.get("fixtures_dir", ".")).resolve()
    fixtures.mkdir(parents=True, exist_ok=True)
    name = args.state if args.state.endswith(".png") else f"{args.state}.png"
    if not SAFE_NAME.fullmatch(name):
        raise FlowError("state name contains unsafe characters")
    destination = fixtures / name
    if destination.exists() and not args.replace:
        raise FlowError(f"fixture already exists: {destination} (use --replace)")
    with QMPClient(args.qmp) as qmp:
        frame = args.work_dir / f"capture-{Path(name).stem}-frame.png"
        args.work_dir.mkdir(parents=True, exist_ok=True)
        capture(qmp, frame)
    image = load_image(frame)
    box = parse_box(args.region, (image.shape[1], image.shape[0])) if args.region else select_region(frame)
    selected, _ = crop(image, box)
    if not cv2.imwrite(str(destination), selected):
        raise FlowError(f"failed to write fixture {destination}")
    return {"status": "captured", "fixture": str(destination), "source": str(frame), "region": list(box)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("flow", type=Path)
    run.add_argument("--qmp", required=True)
    run.add_argument("--work-dir", type=Path, required=True)
    cap = sub.add_parser("capture")
    cap.add_argument("state")
    cap.add_argument("--flow", type=Path, required=True)
    cap.add_argument("--qmp", required=True)
    cap.add_argument("--work-dir", type=Path, default=Path("install-vision-captures"))
    cap.add_argument("--region")
    cap.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        assert_clone_qmp(args.qmp)
        if args.command == "capture":
            result = capture_command(args)
        else:
            flow = load_flow(args.flow)
            with QMPClient(args.qmp) as qmp:
                result = Runner(args.flow.resolve(), flow, qmp, args.work_dir.resolve()).run()
            (args.work_dir / "run.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True))
        return 0 if result["status"] in {"passed", "captured"} else 2
    except Exception as exc:
        print(f"install-vision: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

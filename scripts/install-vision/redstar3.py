#!/usr/bin/env python3
"""Legacy bounded machine-vision driver for Red Star OS 3.0.

Every transition is confirmed against a cropped reference template captured
from the genuine preservation ISO.  On failure the last real framebuffer is
retained in the evidence directory; elapsed time is never treated as success.

The install mode is superseded by redstar3.flow.yaml and is retained as a
known-working fallback. Rescue, curation, parking, and input proof still use
this driver until those non-installer workflows are separately generalized.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import cv2
from qmp import QMPClient

KEYS = {" ": "spc", "/": "slash", ".": "dot", "-": "minus", "_": "shift-minus", ":": "shift-semicolon"}


class Driver:
    def __init__(self, qmp: Path, templates: Path, evidence: Path):
        self.qmp_path = qmp
        self.templates = templates
        self.evidence = evidence
        evidence.mkdir(parents=True, exist_ok=True)

    def shot(self, name: str) -> Path:
        path = self.evidence / f"{name}.ppm"
        with QMPClient(self.qmp_path) as q:
            q.screendump(path)
        return path

    def score(self, frame: Path, name: str) -> float:
        image = cv2.imread(str(frame), cv2.IMREAD_COLOR)
        templ = cv2.imread(str(self.templates / f"redstar3-{name}.png"), cv2.IMREAD_COLOR)
        if image is None or templ is None:
            raise RuntimeError(f"missing frame/template for {name}")
        if templ.shape[0] > image.shape[0] or templ.shape[1] > image.shape[1]:
            return 0.0
        return float(cv2.minMaxLoc(cv2.matchTemplate(image, templ, cv2.TM_CCOEFF_NORMED))[1])

    def wait(self, name: str, timeout: int, threshold: float = 0.72) -> Path:
        deadline = time.monotonic() + timeout
        best = 0.0
        attempt = 0
        while time.monotonic() < deadline:
            attempt += 1
            frame = self.shot(f"wait-{name}-{attempt:03d}")
            best = max(best, self.score(frame, name))
            if self.score(frame, name) >= threshold:
                return frame
            time.sleep(3)
        failed = self.shot(f"FAILED-{name}-best-{best:.3f}")
        raise RuntimeError(f"state {name!r} not reached in {timeout}s (best={best:.3f}; {failed})")

    def tap(self, x: int, y: int) -> None:
        with QMPClient(self.qmp_path) as q:
            q.tap(x, y, 1024, 768)

    def transition(self, current: str, following: str, x: int, y: int, timeout: int = 60) -> Path:
        """Click only while the current state remains visible; confirm next."""
        deadline = time.monotonic() + timeout
        attempt = 0
        while time.monotonic() < deadline:
            attempt += 1
            before = self.shot(f"transition-{current}-to-{following}-{attempt:02d}-before")
            if self.score(before, following) >= 0.72:
                return before
            if self.score(before, current) < 0.62:
                time.sleep(2)
                continue
            self.tap(x, y)
            for poll in range(5):
                time.sleep(2)
                after = self.shot(f"transition-{current}-to-{following}-{attempt:02d}-{poll:02d}")
                if self.score(after, following) >= 0.72:
                    return after
        failed = self.shot(f"FAILED-transition-{current}-to-{following}")
        raise RuntimeError(f"transition {current}->{following} failed ({failed})")

    @staticmethod
    def _axis(x: int, y: int) -> list[dict]:
        return [
            {"type": "abs", "data": {"axis": "x", "value": round(x * 0x7FFF / 1023)}},
            {"type": "abs", "data": {"axis": "y", "value": round(y * 0x7FFF / 767)}},
        ]

    def move(self, x: int, y: int) -> None:
        with QMPClient(self.qmp_path) as q:
            q.execute("input-send-event", events=self._axis(x, y))
        time.sleep(0.5)

    def button(self, down: bool) -> None:
        with QMPClient(self.qmp_path) as q:
            q.execute("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])
        time.sleep(0.25)

    def qkey(self, name: str, down: bool) -> None:
        event = {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": name}}}
        with QMPClient(self.qmp_path) as q:
            q.execute("input-send-event", events=[event])
        time.sleep(0.2)

    def key(self, key: str) -> None:
        with QMPClient(self.qmp_path) as q:
            q.hmp(f"sendkey {key}")
        time.sleep(0.12)

    def text(self, value: str) -> None:
        for char in value:
            if char.isalpha():
                key = char.lower() if char.islower() else f"shift-{char.lower()}"
            elif char.isdigit():
                key = char
            elif char in KEYS:
                key = KEYS[char]
            else:
                raise RuntimeError(f"unsupported key character: {char!r}")
            self.key(key)

    def install(self, password: str) -> None:
        self.wait("welcome", 180)
        self.transition("welcome", "disk-init", 715, 561)
        self.transition("disk-init", "partition", 657, 423)
        self.tap(350, 280)
        self.transition("partition", "account", 715, 561)
        self.tap(480, 285)
        self.text("gallery")
        self.key("tab")
        self.text("gallery")
        self.key("tab")
        self.text(password)
        self.key("tab")
        self.text(password)
        self.key("tab")
        # From the optional password-hint field, Tab lands on the enabled Next
        # button.  Keyboard activation is more reliable here than a pointer
        # click immediately after the password typing burst.
        self.key("tab")
        self.key("ret")
        self.wait("zone", 60)
        self.transition("zone", "timezone", 715, 561)
        self.transition("timezone", "confirm", 715, 561)
        self.transition("confirm", "progress", 715, 561)
        self.wait("done", 1200)
        self.shot("install-complete")

    def rescue(self) -> None:
        self.wait("welcome", 180)
        self.key("ctrl-alt-f2")
        time.sleep(4)
        for command in (
            "mkdir -p /mnt/target /mnt/helper",
            "mount /dev/sda1 /mnt/target",
            "mount /dev/sdb /mnt/helper",
            "sh /mnt/helper/apply.sh /mnt/target",
            "sync",
        ):
            self.text(command)
            self.key("ret")
            time.sleep(2)
        self.shot("offline-helper-applied")

    def proof(self) -> None:
        self.wait("desktop", 120, 0.68)
        for label, x, y in (("nw", 2, 2), ("ne", 1021, 2), ("sw", 2, 765), ("se", 1021, 765), ("center", 512, 384)):
            self.move(x, y)
            self.shot(f"pointer-{label}")
        self.tap(12, 12)
        time.sleep(2)
        self.shot("pointer-click-menu")
        self.tap(12, 12)
        self.move(500, 710)
        self.button(True)
        self.move(700, 650)
        self.button(False)
        self.shot("pointer-drag-dock")
        self.qkey("alt", True)
        self.qkey("f2", True)
        self.qkey("f2", False)
        self.qkey("alt", False)
        time.sleep(2)
        self.shot("keyboard-alt-f2-make-break")
        self.qkey("esc", True)
        self.qkey("esc", False)
        self.shot("keyboard-escape-make-break")

    def curate(self) -> None:
        self.wait("desktop", 300, 0.68)
        deadline = time.monotonic() + 90
        stable_since: float | None = None
        poll = 0
        while time.monotonic() < deadline:
            poll += 1
            frame = self.shot(f"curate-poll-{poll:02d}")
            if self.score(frame, "integrity-warning") >= 0.70:
                raise RuntimeError("delayed integrity warning remains over the fixture")
            if self.score(frame, "audio-warning") >= 0.70:
                # Persist the dialog's own "do not show again" preference,
                # then accept it.  This warning can arrive well after the dock.
                self.tap(300, 427)
                self.tap(680, 462)
                stable_since = None
                time.sleep(4)
                continue
            if self.score(frame, "desktop") >= 0.68:
                stable_since = stable_since or time.monotonic()
                if time.monotonic() - stable_since >= 25:
                    self.shot("curate-ready")
                    return
            else:
                stable_since = None
            time.sleep(3)
        raise RuntimeError("desktop did not remain modal-free for 25 seconds")

    def park(self) -> None:
        # Red Star's dock auto-hides unless the absolute pointer rests at its
        # lower reveal edge.  Capture that input state so reset visibly restores
        # the complete menubar + wallpaper + dock scene.
        self.move(890, 765)
        time.sleep(3)
        frame = self.shot("fixture-pointer-parked")
        if self.score(frame, "desktop") < 0.68:
            raise RuntimeError("parking pointer did not reveal the dock")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("install", "rescue", "wait-desktop", "curate", "park", "proof"))
    parser.add_argument("--qmp", type=Path, required=True)
    parser.add_argument("--templates", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    driver = Driver(args.qmp, args.templates, args.evidence)
    if args.mode == "install":
        password = sys.stdin.readline().rstrip("\n")
        if not password:
            raise RuntimeError("password must be supplied on stdin")
        driver.install(password)
    elif args.mode == "rescue":
        driver.rescue()
    elif args.mode == "wait-desktop":
        driver.wait("desktop", 300, 0.68)
        driver.shot("desktop-ready")
    elif args.mode == "curate":
        driver.curate()
    elif args.mode == "park":
        driver.park()
    else:
        driver.proof()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

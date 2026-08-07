#!/usr/bin/env python3
"""Focused tests for the declarative install-vision runner."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import cv2
import flow
import numpy as np


class FakeQMP:
    def __init__(self, frame: np.ndarray):
        self.frame = frame
        self.keys: list[str] = []
        self.taps: list[tuple[int, int]] = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def screendump(self, path):
        if not cv2.imwrite(str(path), self.frame):
            raise RuntimeError("test screendump failed")

    def hmp(self, command):
        self.keys.append(command)
        return ""

    def tap(self, x, y, _width, _height):
        self.taps.append((x, y))


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        rng = np.random.default_rng(7)
        self.template = rng.integers(0, 256, (24, 36, 3), dtype=np.uint8)
        self.other = rng.integers(0, 256, (24, 36, 3), dtype=np.uint8)
        self.frame = np.zeros((120, 180, 3), dtype=np.uint8)
        self.frame[40:64, 70:106] = self.template
        cv2.imwrite(str(self.fixtures / "present.png"), self.template)
        cv2.imwrite(str(self.fixtures / "absent.png"), self.other)

    def tearDown(self):
        self.tmp.cleanup()

    def write_flow(self, steps):
        path = self.root / "test.flow.yaml"
        path.write_text("version: 1\nname: test\nfixtures_dir: fixtures\nsteps:\n" + steps)
        return path

    def test_mixed_actions_optional_checkpoint_and_secret_redaction(self):
        path = self.write_flow(
            "  - name: tap\n    tap_template: present.png\n    checkpoint: {template: present.png, timeout: 0}\n"
            "  - name: branch\n    optional: true\n    wait_template: {template: absent.png, timeout: 0}\n"
            "  - name: secret\n    type: '${TEST_FLOW_SECRET}'\n"
            "  - name: keys\n    key: [tab, ret]\n"
            "  - name: stable\n    settle: {timeout: 0.2, interval: 0.01, steady_frames: 1}\n"
            "  - name: proof\n    screenshot: final\n"
        )
        qmp = FakeQMP(self.frame)
        old = os.environ.get("TEST_FLOW_SECRET")
        os.environ["TEST_FLOW_SECRET"] = "S3cret-Value!"
        try:
            runner = flow.Runner(path, flow.load_flow(path), qmp, self.root / "evidence")
            result = runner.run()
        finally:
            if old is None:
                os.environ.pop("TEST_FLOW_SECRET", None)
            else:
                os.environ["TEST_FLOW_SECRET"] = old
        self.assertEqual("passed", result["status"])
        self.assertEqual("skipped", result["steps"][1]["status"])
        self.assertTrue(qmp.taps)
        self.assertNotIn("S3cret-Value!", json.dumps(result))
        self.assertTrue((self.root / "evidence" / "06-proof-final.png").is_file())

    def test_failure_names_step_and_retains_frame(self):
        path = self.write_flow("  - name: expected-state\n    wait_template: {template: absent.png, timeout: 0}\n")
        result = flow.Runner(path, flow.load_flow(path), FakeQMP(self.frame), self.root / "failure").run()
        self.assertEqual("failed", result["status"])
        self.assertEqual({"index": 1, "name": "expected-state"}, result["failed_step"])
        self.assertTrue(Path(result["frame"]).is_file())

    def test_rejected_secret_input_does_not_log_a_qcode(self):
        path = self.write_flow("  - name: secret\n    type: '${TEST_FLOW_SECRET}'\n")
        qmp = FakeQMP(self.frame)
        qmp.hmp = lambda _command: "shift-s rejected"
        with patch.dict(os.environ, {"TEST_FLOW_SECRET": "S"}):
            result = flow.Runner(path, flow.load_flow(path), qmp, self.root / "rejected").run()
        audit = json.dumps(result)
        self.assertNotIn("shift-s", audit)
        self.assertNotIn('"S"', audit)
        self.assertEqual("QMP rejected typed input", result["error"])

    def test_headless_capture_writes_flow_fixture(self):
        path = self.write_flow("  - name: unused\n    sleep: 0\n")
        args = argparse.Namespace(
            state="crop", flow=path, qmp="fake", work_dir=self.root / "captures", region="70,40,36,24", replace=False
        )
        with patch.object(flow, "QMPClient", return_value=FakeQMP(self.frame)):
            result = flow.capture_command(args)
        self.assertEqual("captured", result["status"])
        captured = cv2.imread(str(self.fixtures / "crop.png"))
        self.assertTrue(np.array_equal(self.template, captured))

    def test_cli_qmp_target_must_stay_in_clone_root(self):
        clone = self.root / "clones"
        with patch.dict(os.environ, {"CLONE_GUARD_CLONE_ROOT": str(clone)}):
            flow.assert_clone_qmp(str(clone / "task" / "qmp.sock"))
            with self.assertRaises(flow.FlowError):
                flow.assert_clone_qmp(str(self.root / "live" / "qmp.sock"))


if __name__ == "__main__":
    unittest.main()

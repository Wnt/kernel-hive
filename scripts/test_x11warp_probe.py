"""Tests for scripts/dev/x11warp-probe.py — argument parsing and the readback
comparison, both of which need no X server: connecting to a real display is
exactly the part this suite must NOT require, since it runs in CI far from
labhost. The X11 wire code itself (XPointer) is exercised on the box, by the
station docs that consolidated into this tool.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))


def _load(name: str, path: Path):
    """Import a dashed script by path — `x11warp-probe` is not an identifier."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


probe = _load("x11warp_probe", ROOT / "scripts" / "dev" / "x11warp-probe.py")


class ParseDisplayTest(unittest.TestCase):
    def test_host_and_number(self):
        self.assertEqual(probe.parse_display("127.0.0.1:84"), ("127.0.0.1", 6084))

    def test_display_zero(self):
        self.assertEqual(probe.parse_display("localhost:0"), ("localhost", 6000))

    def test_hostname_with_dots(self):
        self.assertEqual(probe.parse_display("sandbox.local:12"), ("sandbox.local", 6012))

    def test_missing_colon_rejected(self):
        with self.assertRaises(ValueError):
            probe.parse_display("127.0.0.1")

    def test_non_numeric_display_rejected(self):
        with self.assertRaises(ValueError):
            probe.parse_display("127.0.0.1:abc")


class ParsePointTest(unittest.TestCase):
    def test_simple_point(self):
        self.assertEqual(probe.parse_point("400,300"), (400, 300))

    def test_negative_and_zero(self):
        self.assertEqual(probe.parse_point("0,-5"), (0, -5))

    def test_missing_comma_rejected(self):
        with self.assertRaises(argparse.ArgumentTypeError):
            probe.parse_point("400")

    def test_non_integer_rejected(self):
        with self.assertRaises(argparse.ArgumentTypeError):
            probe.parse_point("x,y")


class ReadbackMatchesTest(unittest.TestCase):
    def test_exact_match_is_ok(self):
        self.assertTrue(probe.readback_matches((100, 700), (100, 700)))

    def test_any_mismatch_fails(self):
        self.assertFalse(probe.readback_matches((100, 700), (100, 701)))
        self.assertFalse(probe.readback_matches((100, 700), (99, 700)))

    def test_corner_teleport_is_a_mismatch(self):
        # docs/lab/INPUT-DEBUGGING.md: a fabricated (0,0) must never read as OK
        # just because it happens to be a valid pair.
        self.assertFalse(probe.readback_matches((512, 384), (0, 0)))


class ArgumentParsingTest(unittest.TestCase):
    def test_display_required(self):
        parser = probe.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])

    def test_warp_repeatable_and_ordered(self):
        parser = probe.build_parser()
        a = parser.parse_args(["--display", "127.0.0.1:84", "--warp", "100,700", "--warp", "900,100"])
        self.assertEqual(a.warps, [(100, 700), (900, 100)])

    def test_no_warp_defaults_to_empty_list(self):
        parser = probe.build_parser()
        a = parser.parse_args(["--display", "127.0.0.1:84"])
        self.assertEqual(a.warps, [])

    def test_click_without_qmp_is_rejected_by_main(self):
        with self.assertRaises(SystemExit):
            probe.main(["x11warp-probe.py", "--display", "127.0.0.1:84", "--click"])

    def test_shot_without_station_is_rejected_by_main(self):
        with self.assertRaises(SystemExit):
            probe.main(["x11warp-probe.py", "--display", "127.0.0.1:84", "--shot"])

    def test_defaults(self):
        parser = probe.build_parser()
        a = parser.parse_args(["--display", "127.0.0.1:84"])
        self.assertEqual(a.button, "left")
        self.assertEqual(a.lab, "lab")
        self.assertFalse(a.click)
        self.assertFalse(a.shot)


if __name__ == "__main__":
    unittest.main()

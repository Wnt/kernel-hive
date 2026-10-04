"""keyboard.charMap, its SH_KEY_MAP copy, and the keyboard.physical opt-in
(scripts/stations_registry/validate_rules.py validate_keyboard_env).

charMap is the single source; SH_KEY_MAP is how labctl consumes it, so the two
must agree. `physical: true` applies the charMap to a visitor's own keys
(spa/src/three/physicalCharMap.ts), which means nothing without a charMap.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stations_registry import validate_rules as vr


def station(keyboard: dict | None, env_map: str | None) -> dict:
    row: dict = {"id": "kaypro", "_path": "registry/stations/kaypro.json"}
    row["runtime"] = {"stationEnv": {} if env_map is None else {"SH_KEY_MAP": env_map}}
    if keyboard is not None:
        row["keyboard"] = keyboard
    return row


def errors_for(row: dict) -> list[str]:
    errors: list[str] = []
    vr.validate_keyboard_env([row], errors)
    return errors


class KeyboardEnvTest(unittest.TestCase):
    def test_physical_with_matching_map_passes(self) -> None:
        kb = {"charMap": {"y": "z", ":": ">"}, "physical": True}
        self.assertEqual(errors_for(station(kb, "y:z,%3A:>")), [])

    def test_physical_without_charmap_fails(self) -> None:
        errs = errors_for(station({"physical": True}, None))
        self.assertEqual(len(errs), 1)
        self.assertIn("keyboard.physical without a keyboard.charMap", errs[0])

    def test_map_drift_fails(self) -> None:
        errs = errors_for(station({"charMap": {"y": "z"}, "physical": True}, "y:x"))
        self.assertTrue(any("does not match" in e for e in errs))

    def test_no_keyboard_no_env_passes(self) -> None:
        self.assertEqual(errors_for(station(None, None)), [])


if __name__ == "__main__":
    unittest.main()

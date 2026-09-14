"""The per-station landing addresses `/walkin/<station>` (scripts/serve/auth/gate.py).

`/` claims whichever machine the broker has — walkin/routes.py picks "uniformly at
random among enabled pools" — so the front door used to be a DIFFERENT station on
every load, and a refresh took away the machine the visitor was using. The landing
page now publishes the station it actually got into the URL
(spa/src/landing/stationUrl.ts) and that address claims the same one on the way
back in.

A stranger arrives signed out by definition, so those addresses have to be open —
and nothing deeper than them may be.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(ROOT / "scripts" / "serve" / "auth"))

import gate  # noqa: E402

WALKIN_REGISTRY = ROOT / "registry" / "walkin"


class TestEachStationLandingPageIsOpen(unittest.TestCase):
    def test_a_signed_out_stranger_reaches_every_station_address(self):
        for station in gate.WALKIN_LANDING_STATIONS:
            with self.subTest(station=station):
                self.assertTrue(gate.is_open(f"/walkin/{station}"))

    def test_the_rest_of_the_door_is_unchanged(self):
        self.assertTrue(gate.is_open("/"))
        self.assertTrue(gate.is_open("/walkin"))
        self.assertTrue(gate.is_open("/walkin/exhibits"))


class TestNothingDeeperWasOpened(unittest.TestCase):
    """Why this is a per-station exact match and not a `/walkin/` prefix."""

    def test_the_account_play_surface_stays_gated(self):
        self.assertFalse(gate.is_open("/walkin/play/win311"))

    def test_the_broker_api_stays_gated(self):
        for path in ("/walkin/claim", "/walkin/release", "/walkin/engage", "/walkin/reset"):
            with self.subTest(path=path):
                self.assertFalse(gate.is_open(path))

    def test_a_path_below_a_station_is_not_open(self):
        self.assertFalse(gate.is_open("/walkin/win311/clone"))
        self.assertFalse(gate.is_open("/walkin/win311/"))

    def test_an_unknown_station_is_not_open(self):
        self.assertFalse(gate.is_open("/walkin/amiga4000"))
        self.assertFalse(gate.is_open("/walkin/"))

    def test_a_station_name_is_matched_exactly(self):
        self.assertFalse(gate.is_open("/walkin/win311 "))
        self.assertFalse(gate.is_open("/walkin/WIN311"))
        self.assertFalse(gate.is_open("/walkinwin311"))


class TestTheListCannotDriftFromTheRegistry(unittest.TestCase):
    """Enabling a fourth walk-in station must not leave its landing page behind a login form."""

    def test_every_enabled_walkin_station_has_an_open_landing_page(self):
        if not WALKIN_REGISTRY.is_dir():
            self.skipTest(f"no walk-in registry at {WALKIN_REGISTRY}")
        enabled = set()
        for path in sorted(WALKIN_REGISTRY.glob("*.json")):
            doc = json.loads(path.read_text())
            if doc.get("enabled"):
                enabled.add(doc.get("station", path.stem))
        self.assertEqual(
            enabled,
            set(gate.WALKIN_LANDING_STATIONS),
            "gate.WALKIN_LANDING_STATIONS has drifted from registry/walkin/*.json",
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""A walk-in clone must not make `labctl gen` refuse fleet-wide.

WHY THIS EXISTS. `gen_tiles_json.py` guards against a real fault: a station
directory on the box that the registry does not declare (or vice versa) means
someone hand-made a station, and the capability matrix would silently describe
a fleet that is not the one running. That guard is correct and stays.

What it did not know is that a **walk-in pool clone** is not a station. Clones
(`walkin-<os>-<n>`, docs/lab/walkin/CONTRACT-LEDGER.md §5.1) get a station dir
and a unit so `/signal/<clone>.json` resolves, but the registry never declares
them — `stations-registry.py` would refuse an id that is not a real station.
So merely ENABLING walk-in put the generator into permanent refusal.

The cost was not theoretical. With nine clones live (and five dirs left over
from a larger pool), `stations.json` froze on 2026-08-31; `labctl` therefore
did not know `ravynos` or `amix`, and `labctl shot` answered "unknown tile" for
both — two healthy stations invisible to every framebuffer check, including the
fleet rollout's health gate, which is the one thing that proves a guest
survived a restart.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SPEC = Path(__file__).resolve().parent / "gen_tiles_json.py"


def _load():
    spec = importlib.util.spec_from_file_location("kh_gen_tiles_json", SPEC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["kh_gen_tiles_json"] = mod
    spec.loader.exec_module(mod)
    return mod


class WalkinCloneExclusionTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load()
        self.rx = self.mod.WALKIN_CLONE

    def test_it_matches_every_live_clone_shape(self):
        """The three pools that exist, plus a slot number above 9."""
        for name in (
            "walkin-os2warp-1",
            "walkin-os2warp-6",
            "walkin-rhapsody-3",
            "walkin-win311-1",
            "walkin-win311-12",
        ):
            self.assertIsNotNone(self.rx.match(name), f"{name} should be recognised as a clone")

    def test_it_does_not_swallow_a_real_station(self):
        """The guard must keep firing for genuine declared/live drift.

        A station id is a fixed registry name; none of these is a clone, and
        treating one as a clone would hide exactly the fault the guard exists
        for. `walkin` as a bare id is included deliberately: were someone to
        add a station actually called that, it must NOT be filtered out.
        """
        for name in (
            "win311",
            "os2warp",
            "rhapsody",
            "ravynos",
            "amix",
            "walkin",
            "walkin-win311",
            "walkin-win311-",
            "walkinwin311-1",
            "notwalkin-win311-1",
        ):
            self.assertIsNone(self.rx.match(name), f"{name} must NOT be treated as a clone")

    def test_the_live_set_drops_clones_and_keeps_stations(self):
        """The set comprehension the guard compares, in miniature."""
        on_disk = [
            "win95",
            "ravynos",
            "amix",
            "walkin-os2warp-1",
            "walkin-os2warp-4",
            "walkin-rhapsody-5",
            "walkin-win311-3",
        ]
        live = {t for t in on_disk if not self.rx.match(t)}
        self.assertEqual(live, {"win95", "ravynos", "amix"})


class RuntimeResidueExclusionTest(unittest.TestCase):
    """A directory of runtime residue is not a station either.

    On 2026-09-03 nine station waves ran in parallel; each dark-launched smoke
    rig ran a hand daemon with `SH_PROBES_JSON` / `SH_TRACE_DIR` unset, so the
    daemon planted `<id>/probes.json` + `<id>/traces/` under the fleet tree for
    eight undeclared ids, and the first landing's `station-up` step 5 refused
    `labctl gen` fleet-wide — the new station was invisible to every framebuffer
    check. A station is a directory that carries `station.env`.
    """

    def setUp(self):
        self.mod = _load()

    def test_only_dirs_with_station_env_are_live(self):
        import tempfile

        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "win95").mkdir()
            (root / "win95" / "station.env").write_text("SH_STATION=win95\n")
            (root / "walkin-win311-3").mkdir()
            (root / "walkin-win311-3" / "station.env").write_text("SH_STATION=walkin-win311-3\n")
            (root / "debian22").mkdir()
            (root / "debian22" / "probes.json").write_text("{}")
            (root / "debian22" / "traces").mkdir()
            (root / "zzsmoke").mkdir()
            (root / "stations.json").write_text("{}")
            self.assertEqual(self.mod.live_station_dirs(str(root)), {"win95"})


if __name__ == "__main__":
    unittest.main()

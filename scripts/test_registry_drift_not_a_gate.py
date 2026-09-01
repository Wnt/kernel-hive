"""The live-box comparison must stay OUT of the push gate — and must still work.

Two properties, both learned the hard way on 2026-08-30 (see
docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md §2):

1. `stations-registry.py check` — the pre-push gate's generated-file drift
   stage — must not read live box state. It used to, and three stations
   declared ahead of their cutover made `main` unpushable for every session in
   the lab, including agents whose commit touched one docs file. A gate may
   test only properties of the commit being pushed.
2. The comparison itself must still catch a real disagreement. Deleting a check
   is only safe if it is genuinely re-homed, so this asserts the moved code
   still finds drift that is really there.
"""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stations_registry import cli, drift  # noqa: E402
from stations_registry.generate import generated  # noqa: E402


def _live_roster_from_declarations() -> dict:
    """A live roster that agrees with the registry perfectly."""
    declared = json.loads(generated()["registry/generated/labctl-declarations.json"])
    return {"tiles": {name: dict(fields) for name, fields in declared["tiles"].items()}}


class DriftIsNotInTheGate(unittest.TestCase):
    def test_check_source_does_not_read_the_live_roster(self):
        source = Path(cli.__file__).read_text()
        self.assertNotIn("streamhost/stations.json", source)
        self.assertNotIn("compare_live_labctl", source)

    def test_drift_skips_and_passes_when_the_roster_is_absent(self):
        """A public clone, an offline laptop and CI have no live roster: exit 0."""
        with mock.patch.object(drift, "LIVE_ROSTER", Path("/nonexistent/stations.json")):
            self.assertEqual(drift.cmd_drift(), 0)


class DriftStillDetectsDrift(unittest.TestCase):
    def _with_roster(self, roster, tmpdir):
        path = Path(tmpdir) / "stations.json"
        path.write_text(json.dumps(roster))
        return mock.patch.object(drift, "LIVE_ROSTER", path)

    def test_agreeing_roster_is_clean(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp, self._with_roster(_live_roster_from_declarations(), tmp):
            self.assertEqual(drift.live_labctl_mismatches(), [])
            self.assertEqual(drift.cmd_drift(), 0)

    def test_a_changed_field_is_reported_and_exits_1(self):
        import tempfile

        roster = _live_roster_from_declarations()
        station = sorted(roster["tiles"])[0]
        key = sorted(roster["tiles"][station])[0]
        roster["tiles"][station][key] = "kh-test-sentinel-value"
        with tempfile.TemporaryDirectory() as tmp, self._with_roster(roster, tmp):
            mismatches = drift.live_labctl_mismatches()
            self.assertTrue(any(line.startswith(f"{station}.{key}:") for line in mismatches), mismatches)
            self.assertEqual(drift.cmd_drift(), 1)

    def test_a_missing_station_is_reported(self):
        import tempfile

        roster = _live_roster_from_declarations()
        roster["tiles"].pop(sorted(roster["tiles"])[0])
        with tempfile.TemporaryDirectory() as tmp, self._with_roster(roster, tmp):
            self.assertTrue(any(line.startswith("tile set ") for line in drift.live_labctl_mismatches()))


if __name__ == "__main__":
    unittest.main()

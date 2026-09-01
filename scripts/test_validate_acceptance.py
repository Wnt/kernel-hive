"""A half-specified acceptance spec must fail at commit time, not at cutover.

`station-accept.sh` refuses to invent a watched rectangle, a control station or
a sampling interval. Without these rules that refusal would surface as a
mysterious exit 2 during a cutover; with them it is a named error on the push
that introduced it.
"""

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stations_registry.validate_acceptance import validate_acceptance  # noqa: E402

GOOD = {
    "watchRect": [900, 700, 40, 16],
    "controlStation": "other",
    "sessions": 3,
    "abandonAt": 2,
    "sampleIntervalMs": 1000,
    "sampleFloorMs": 400,
    "sampleCeilingMs": 3000,
}


OTHER_SPEC = {
    "watchRect": [10, 10, 20, 20],
    "controlStation": "cand",
    "sampleIntervalMs": 1000,
    "sampleFloorMs": 400,
    "sampleCeilingMs": 3000,
}


def check(spec, station="cand", control_spec=OTHER_SPEC):
    errors = []
    other = {"id": "other", "_path": "other"}
    if control_spec:
        other["acceptance"] = control_spec
    rows = [{"id": station, "_path": station, "acceptance": spec}, other]
    validate_acceptance(rows, errors)
    return [e for e in errors if e.startswith(station)]


class Accepts(unittest.TestCase):
    def test_a_complete_spec(self):
        self.assertEqual(check(GOOD), [])

    def test_absence_is_fine(self):
        """Most stations have no spec yet; authoring them is the ongoing cost."""
        errors = []
        validate_acceptance([{"id": "a", "_path": "a"}], errors)
        self.assertEqual(errors, [])

    def test_a_probe_point_with_its_guest_size(self):
        self.assertEqual(check({**GOOD, "probePoint": [100, 100], "guestSize": [1024, 768]}), [])


class Refuses(unittest.TestCase):
    def one(self, spec, needle):
        errors = check(spec)
        self.assertTrue(errors, f"expected an error mentioning {needle!r}")
        self.assertTrue(any(needle in e for e in errors), errors)

    def test_typo_in_a_key(self):
        self.one({**GOOD, "watchRekt": [1, 2, 3, 4]}, "unknown key")

    def test_missing_control_station(self):
        spec = {k: v for k, v in GOOD.items() if k != "controlStation"}
        self.one(spec, "controlStation is required")

    def test_control_that_is_the_candidate_itself(self):
        self.one({**GOOD, "controlStation": "cand"}, "DIFFERENT station")

    def test_control_that_does_not_exist(self):
        self.one({**GOOD, "controlStation": "nosuch"}, "not a station in this registry")

    def test_control_without_an_acceptance_stanza_of_its_own(self):
        """A control that cannot pass makes every verdict "harness suspect"."""
        errors = check(GOOD, control_spec=None)
        self.assertTrue(any("no acceptance stanza of its own" in e for e in errors), errors)

    def test_single_session_run(self):
        self.one({**GOOD, "sessions": 1}, ">= 2")

    def test_abandoning_the_last_session_tests_nothing(self):
        self.one({**GOOD, "sessions": 3, "abandonAt": 3}, "nothing runs after the churn")

    def test_missing_sampling_bounds(self):
        spec = {k: v for k, v in GOOD.items() if k != "sampleCeilingMs"}
        self.one(spec, "both bounds are required")

    def test_interval_outside_its_own_bounds(self):
        self.one({**GOOD, "sampleIntervalMs": 5000}, "must sit between")

    def test_probe_point_without_guest_size(self):
        self.one({**GOOD, "probePoint": [10, 10]}, "guestSize")

    def test_degenerate_watch_rect(self):
        self.one({**GOOD, "watchRect": [10, 10, 0, 5]}, "positive width")


class CursorBankTraps(unittest.TestCase):
    """Each of these has cost a real run: encode them, do not re-learn them."""

    def setUp(self):
        import json
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        # The shape of tests/cursor-banks/rhapsody.json: a MIXED bank, whose
        # largest glyph is 14x16.
        bank = {
            "e63fa3be82bc": {"w": 11, "h": 16},
            "98f480249409": {"w": 11, "h": 16},
            "c10b0ab605bc": {"w": 13, "h": 13},
            "3759b1ce8de5": {"w": 14, "h": 16},
        }
        self.bank = Path(self._tmp.name) / "bank.json"
        self.bank.write_text(json.dumps(bank))

    def tearDown(self):
        self._tmp.cleanup()

    def spec(self, **over):
        base = {
            **GOOD,
            "probePoint": [400, 300],
            "guestSize": [1024, 768],
            "cursorBank": str(self.bank),
            "cursorBankBoundTo": "golden 2026-08-23, 1024x768 RGB:555/16",
        }
        base.update(over)
        return base

    def test_a_bank_needs_its_binding_written_down(self):
        spec = self.spec()
        del spec["cursorBankBoundTo"]
        errors = check(spec)
        self.assertTrue(any("cursorBankBoundTo" in e for e in errors), errors)

    def test_the_largest_glyph_sets_the_edge_margin(self):
        """1024-14 = 1010, 768-16 = 752 for this bank."""
        self.assertEqual(check(self.spec(probePoint=[1010, 752])), [])
        errors = check(self.spec(probePoint=[1011, 752]))
        self.assertTrue(any("leaves no room" in e for e in errors), errors)

    def test_a_point_too_low_is_caught_too(self):
        errors = check(self.spec(probePoint=[400, 760]))
        self.assertTrue(any("y <= 752" in e for e in errors), errors)

    def test_a_bank_that_has_not_landed_yet_is_not_an_error(self):
        """Banks may live on an unmerged branch; a missing one is INCONCLUSIVE."""
        self.assertEqual(check(self.spec(cursorBank="tests/cursor-banks/nothere.json")), [])

    def test_binding_without_a_bank_is_a_mistake(self):
        spec = self.spec()
        del spec["cursorBank"]
        errors = check(spec)
        self.assertTrue(any("without acceptance.cursorBank" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()

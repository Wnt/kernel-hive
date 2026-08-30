"""A half-specified acceptance spec must fail at commit time, not at cutover.

`station-accept.sh` refuses to invent a watched rectangle, a control station or
a sampling interval. Without these rules that refusal would surface as a
mysterious exit 2 during a cutover; with them it is a named error on the push
that introduced it.
"""

import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()

"""The acceptance verdict must be exactly right, so it is tested exhaustively.

Every case below is a shape that really occurred on 2026-08-30, or a shape the
design forbids. The point of the suite is that a gate which cannot tell "broken"
from "I could not look" will eventually roll back a healthy release.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dev"))

from station_accept_verdict import verdict  # noqa: E402


def run(sessions, abandoned_at=2):
    return {"station": "x", "abandonedAt": abandoned_at, "sessions": sessions}


def good(index, distinct=3, repaint=True):
    s = {"index": index, "abandoned": False, "negotiated": True, "idle": {"distinctRect": distinct}}
    if repaint is not None:
        s["repaint"] = {"changed": repaint, "ms": 900}
    return s


ABANDONED = {"index": 2, "abandoned": True, "negotiated": None}


class Passes(unittest.TestCase):
    def test_session_after_churn_negotiates_moves_and_repaints(self):
        state, why = verdict(run([good(1), ABANDONED, good(3)]))
        self.assertEqual(state, "PASS", why)

    def test_motion_only_passes_when_no_probe_point_was_declared(self):
        state, why = verdict(run([good(1), ABANDONED, good(3, repaint=None)]))
        self.assertEqual(state, "PASS", why)
        self.assertIn("no probe point", why)


class Fails(unittest.TestCase):
    def test_the_rhapsody_shape_no_session_after_the_churn_negotiates(self):
        """Perfect first session, every later one times out negotiating."""
        later = {"index": 3, "abandoned": False, "negotiated": False}
        state, why = verdict(run([good(1), ABANDONED, later]))
        self.assertEqual(state, "FAIL")
        self.assertIn("negotiated", why)

    def test_a_stopped_stream_that_passes_every_surface_check(self):
        """Sized, ready, non-black — and one distinct frame. Must not pass."""
        state, why = verdict(run([good(1), ABANDONED, good(3, distinct=1)]))
        self.assertEqual(state, "FAIL")
        self.assertIn("stopped stream", why)

    def test_live_picture_but_input_never_arrives(self):
        state, why = verdict(run([good(1), ABANDONED, good(3, repaint=False)]))
        self.assertEqual(state, "FAIL")
        self.assertIn("no repaint", why)


class NotAFailure(unittest.TestCase):
    """NORUN must never be collapsed into FAIL — only FAIL may roll back."""

    def test_probe_crashed(self):
        self.assertEqual(verdict(run([good(1)]), returncode=1)[0], "NORUN")

    def test_unreadable_output(self):
        self.assertEqual(verdict({}, 0)[0], "NORUN")
        self.assertEqual(verdict("not a dict", 0)[0], "NORUN")

    def test_a_run_with_no_abandoned_session_cannot_certify(self):
        """A single clean session certifies the rhapsody defect by construction."""
        state, why = verdict(run([good(1), good(3)], abandoned_at=0))
        self.assertEqual(state, "NORUN")
        self.assertIn("churn", why)

    def test_nothing_ran_after_the_abandoned_session(self):
        state, why = verdict(run([good(1), ABANDONED]))
        self.assertEqual(state, "NORUN")
        self.assertIn("nothing was actually tested", why)


def counters(before, after):
    return {"before": before, "after": after}


CLEAN = counters(
    {"accepted": 100, "dropped": 0, "overflow": 0, "backend-down": 0},
    {"accepted": 140, "dropped": 0, "overflow": 0, "backend-down": 0},
)


class TelemetryOnlySubtractsConfidence(unittest.TestCase):
    """The rule that reconciles "counters are not evidence" with "assert mechanism".

    A healthy counter may never rescue a failing framebuffer — that is the
    substitution the design forbids. A sick counter MAY sink a passing one,
    because it names a mechanism fault the pixels happened not to show.
    """

    def test_healthy_counters_cannot_rescue_a_stopped_stream(self):
        state, _ = verdict(run([good(1), ABANDONED, good(3, distinct=1)]), 0, CLEAN)
        self.assertEqual(state, "FAIL")

    def test_healthy_counters_cannot_rescue_a_missing_repaint(self):
        state, _ = verdict(run([good(1), ABANDONED, good(3, repaint=False)]), 0, CLEAN)
        self.assertEqual(state, "FAIL")

    def test_clean_mechanism_is_reported_on_a_pass(self):
        state, why = verdict(run([good(1), ABANDONED, good(3)]), 0, CLEAN)
        self.assertEqual(state, "PASS", why)
        self.assertIn("mechanism clean", why)

    def test_absent_counters_leave_the_mechanism_unasserted_not_failed(self):
        state, why = verdict(run([good(1), ABANDONED, good(3)]), 0, None)
        self.assertEqual(state, "PASS")
        self.assertIn("UNASSERTED", why)


class MechanismNotJustOutcome(unittest.TestCase):
    """The symptom being gone is not the mechanism being fixed."""

    def sick(self, key):
        before = {"accepted": 100, "dropped": 0, "overflow": 0, "backend-down": 0}
        after = {**before, "accepted": 140, key: 7}
        return verdict(run([good(1), ABANDONED, good(3)]), 0, counters(before, after))

    def test_dropped_events_sink_an_otherwise_passing_run(self):
        state, why = self.sick("dropped")
        self.assertEqual(state, "FAIL")
        self.assertIn("dropped+7", why)

    def test_overflow_sinks_it(self):
        self.assertEqual(self.sick("overflow")[0], "FAIL")

    def test_give_ups_sink_it(self):
        state, why = self.sick("backend-down")
        self.assertEqual(state, "FAIL")
        self.assertIn("repeatable", why)


class DisagreementIsRed(unittest.TestCase):
    """A gate that silently prefers the passing check reproduces the bug."""

    def test_repaint_seen_but_the_router_accepted_nothing(self):
        frozen = counters(
            {"accepted": 100, "dropped": 0, "overflow": 0, "backend-down": 0},
            {"accepted": 100, "dropped": 0, "overflow": 0, "backend-down": 0},
        )
        state, why = verdict(run([good(1), ABANDONED, good(3)]), 0, frozen)
        self.assertEqual(state, "DISAGREE")
        self.assertIn("framebuffer", why)
        self.assertIn("accepted zero", why)

    def test_disagree_is_not_pass(self):
        frozen = counters(
            {"accepted": 5, "dropped": 0, "overflow": 0, "backend-down": 0},
            {"accepted": 5, "dropped": 0, "overflow": 0, "backend-down": 0},
        )
        self.assertNotEqual(verdict(run([good(1), ABANDONED, good(3)]), 0, frozen)[0], "PASS")


class MissingTemplatesAreInconclusive(unittest.TestCase):
    def test_a_missing_cursor_bank_never_fails_the_station(self):
        state, why = verdict(run([good(1), ABANDONED, good(3)]), 0, CLEAN, templates="missing")
        self.assertEqual(state, "NORUN")
        self.assertIn("harness gap", why)

    def test_and_it_does_not_fail_even_when_the_run_looks_bad(self):
        """A harness gap must not be able to roll a station back, ever."""
        state, _ = verdict(run([good(1), ABANDONED, good(3, distinct=1)]), 0, CLEAN, templates="missing")
        self.assertEqual(state, "NORUN")


if __name__ == "__main__":
    unittest.main()

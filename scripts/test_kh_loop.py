"""The loop's trigger semantics: what woke it, and what a hint may do.

The design change the operator asked for is "push-triggered, not polled", and
the risk it introduces is a trigger that dies quietly while the backstop keeps
everything looking healthy at a coarser latency. Most of these tests are about
making that state visible rather than invisible.
"""

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "host"))

from kh_reconciler.loop import (  # noqa: E402
    backstop_report,
    classify_wake,
    hint_is_trustworthy,
    read_wakeup,
    selectable_units,
)


class WhatWokeUs(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.wakeup = Path(self._tmp.name) / "wakeup"

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, source, ts, hint=None):
        self.wakeup.write_text(json.dumps({"source": source, "ts": ts, "hint": hint}))

    def test_no_wakeup_is_the_backstop_tick(self):
        self.assertEqual(classify_wake(self.wakeup, 0, time.time())[0], "timer")

    def test_a_fresh_hint_names_its_own_verified_source(self):
        self.write("actions", 100)
        self.assertEqual(classify_wake(self.wakeup, 50, 200)[0], "actions")

    def test_a_hint_older_than_the_last_convergence_is_already_handled(self):
        self.write("webhook", 50)
        self.assertEqual(classify_wake(self.wakeup, 100, 200)[0], "timer")

    def test_a_malformed_wakeup_cannot_stop_the_loop(self):
        """The timer converges anyway; a bad file must never wedge convergence."""
        self.wakeup.write_text("{ not json")
        self.assertIsNone(read_wakeup(self.wakeup))
        self.assertEqual(classify_wake(self.wakeup, 0, time.time())[0], "timer")

    def test_an_unknown_source_is_not_trusted_as_a_new_trigger_name(self):
        self.write("something-else", 100)
        self.assertEqual(classify_wake(self.wakeup, 0, 200)[0], "webhook")


class AHintIsNeverAnInstruction(unittest.TestCase):
    """The property that makes a public endpoint acceptable at all."""

    def fake_git(self, ancestor: bool):
        return lambda *a, **k: ancestor

    def test_no_hint_is_fine(self):
        ok, why = hint_is_trustworthy(self.fake_git(True), Path("."), None, "abc1234")
        self.assertTrue(ok)

    def test_an_ancestor_hint_corroborates(self):
        ok, why = hint_is_trustworthy(self.fake_git(True), Path("."), "a" * 40, "b" * 40)
        self.assertTrue(ok)
        self.assertIn("ancestor", why)

    def test_a_NON_ancestor_hint_is_an_anomaly_and_changes_nothing(self):
        ok, why = hint_is_trustworthy(self.fake_git(False), Path("."), "a" * 40, "b" * 40)
        self.assertFalse(ok)
        self.assertIn("ANOMALY", why)
        self.assertIn("Converging to what we fetched", why)

    def test_a_hint_that_is_not_even_a_sha(self):
        for junk in ("; rm -rf /", "refs/heads/main", "zzzz", "../../etc/passwd"):
            ok, why = hint_is_trustworthy(self.fake_git(True), Path("."), junk, "b" * 40)
            self.assertFalse(ok, junk)
            self.assertIn("not a sha", why)


class RolloutIsOptIn(unittest.TestCase):
    def test_default_is_hold_not_auto(self):
        """A unit nobody opted in must be VISIBLY not converged."""
        auto, held = selectable_units({"station:a": [], "station:b": []}, {})
        self.assertEqual(auto, [])
        self.assertEqual(held, ["station:a", "station:b"])

    def test_only_explicit_auto_is_selected(self):
        auto, held = selectable_units({"station:a": [], "station:b": []}, {"station:a": "auto", "station:b": "hold"})
        self.assertEqual(auto, ["station:a"])
        self.assertEqual(held, ["station:b"])


class ADeadTriggerIsVisible(unittest.TestCase):
    def test_nothing_has_ever_run(self):
        self.assertIn("NO LOOP HAS EVER RUN", backstop_report([], time.time())[0])

    def test_a_webhook_that_has_never_fired_is_called_out(self):
        rows = [{"ts": time.time(), "trigger": "timer", "commit": "abc"}]
        text = " ".join(backstop_report(rows, time.time()))
        self.assertIn("WEBHOOK HAS NEVER FIRED", text)

    def test_running_on_the_backstop_is_named(self):
        now = time.time()
        rows = [
            {"ts": now - 100000, "trigger": "webhook", "commit": "abc"},
            {"ts": now, "trigger": "timer", "commit": "abc"},
        ]
        text = " ".join(backstop_report(rows, now))
        self.assertIn("RUNNING ON THE BACKSTOP", text)
        self.assertIn("how a dead trigger hides", text)

    def test_a_healthy_webhook_is_quiet(self):
        now = time.time()
        rows = [{"ts": now - 60, "trigger": "webhook", "commit": "abc"}]
        text = " ".join(backstop_report(rows, now))
        self.assertNotIn("RUNNING ON THE BACKSTOP", text)
        self.assertIn("last webhook-sourced", text)


if __name__ == "__main__":
    unittest.main()

"""Tail sampling at the vendor leg: keep every error, every slow action, and a
random share of the rest.

The property that matters most here is what it must NEVER do — sample away a
failure, or sample away the slow action that is the entire reason the input
plane is instrumented. A rate that loses those is worse than no export at all,
because it reads as a rate rather than as an absence.
"""

from __future__ import annotations

import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "observability"))

import tail_sampler  # noqa: E402


def action(dur_ms: int, *, error: bool = False, root_name: str = "input.edge") -> dict:
    return {
        "traceId": "a" * 32,
        "spans": [
            {
                "spanId": "b" * 16,
                "parentId": None,
                "name": root_name,
                "durMs": dur_ms,
                "startedMs": 1,
                "status": "error" if error else "ok",
                "attributes": {},
            },
            {
                "spanId": "c" * 16,
                "parentId": "b" * 16,
                "name": "input.dispatch.key",
                "durMs": 1,
                "startedMs": 2,
                "status": "unset",
                "attributes": {},
            },
        ],
    }


class Decisions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.tail.json"

    def sampler(self, seed: int = 1) -> tail_sampler.TailSampler:
        return tail_sampler.TailSampler(self.path, rng=random.Random(seed))

    def test_an_errored_action_is_always_kept(self):
        """A failure is never sampled away, however fast it was."""
        s = self.sampler()
        for _ in range(200):
            keep, reason, factor = s.decide(action(1, error=True))
            self.assertTrue(keep)
            self.assertEqual(reason, "error")
            self.assertEqual(factor, 1)

    def test_a_slow_action_is_always_kept(self):
        s = self.sampler()
        for _ in range(200):
            keep, reason, _ = s.decide(action(tail_sampler.SLOW_FLOOR_MS + 1))
            self.assertTrue(keep)
            self.assertEqual(reason, "slow")

    def test_a_fast_action_is_kept_only_at_random_and_carries_the_factor(self):
        s = self.sampler()
        kept = [s.decide(action(5))[1] for _ in range(2000)]
        self.assertIn("random", kept)
        self.assertIn("dropped", kept)
        keeps = kept.count("random")
        # Roughly 1 in RANDOM_KEEP_FACTOR — generous bounds, this is a coin.
        self.assertGreater(keeps, 2000 / tail_sampler.RANDOM_KEEP_FACTOR / 2)
        self.assertLess(keeps, 2000 / tail_sampler.RANDOM_KEEP_FACTOR * 2)

    def test_a_non_action_trace_is_always_forwarded_untouched(self):
        """Page loads, connects and restores are rare and individually
        interesting; this module has no opinion about them."""
        s = self.sampler()
        keep, reason, _ = s.decide(action(1, root_name="station.connect"))
        self.assertTrue(keep)
        self.assertEqual(reason, "not-an-action")

    def test_it_fails_OPEN_on_a_trace_it_cannot_classify(self):
        """A dropped trace is unrecoverable; a forwarded one costs a row."""
        s = self.sampler()
        self.assertTrue(s.decide({"spans": []})[0])
        broken = action(1)
        broken["spans"][0]["durMs"] = None
        self.assertTrue(s.decide(broken)[0])


class Threshold(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.tail.json"

    def test_the_floor_stands_alone_until_the_window_is_warm(self):
        s = tail_sampler.TailSampler(self.path)
        self.assertEqual(s.slow_ms(), tail_sampler.SLOW_FLOOR_MS)

    def test_the_percentile_takes_over_once_the_fleet_is_slower_than_the_floor(self):
        s = tail_sampler.TailSampler(self.path)
        for _ in range(tail_sampler.WINDOW):
            s.observe(2000)
        self.assertEqual(s.slow_ms(), 2000)

    def test_the_floor_holds_when_the_fleet_is_fast(self):
        """Without the floor a good hour would push the rolling p95 down to a
        few tens of milliseconds and ordinary actions would start being
        forwarded as "slow" — which is the noise this exists to remove."""
        s = tail_sampler.TailSampler(self.path)
        for _ in range(tail_sampler.WINDOW):
            s.observe(5)
        self.assertEqual(s.slow_ms(), tail_sampler.SLOW_FLOOR_MS)

    def test_the_window_observes_every_action_not_only_the_kept_ones(self):
        """A percentile fed only by its own keeps ratchets upward forever."""
        s = tail_sampler.TailSampler(self.path, rng=random.Random(7))
        for _ in range(300):
            s.decide(action(10))
        self.assertEqual(len(s.window), 300)

    def test_the_window_is_bounded_and_survives_a_restart(self):
        s = tail_sampler.TailSampler(self.path)
        for i in range(tail_sampler.WINDOW * 2):
            s.observe(i)
        s.save()
        self.assertEqual(len(s.window), tail_sampler.WINDOW)
        again = tail_sampler.TailSampler(self.path)
        self.assertEqual(len(again.window), tail_sampler.WINDOW)

    def test_a_corrupt_window_file_is_a_cold_start_not_a_crash(self):
        self.path.write_text("{not json", encoding="utf-8")
        self.assertEqual(tail_sampler.TailSampler(self.path).slow_ms(), tail_sampler.SLOW_FLOOR_MS)


class Stamping(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "state.tail.json"

    def test_every_span_of_a_kept_action_carries_the_factor_and_the_reason(self):
        s = tail_sampler.TailSampler(self.path)
        kept, counts = tail_sampler.apply(s, [action(tail_sampler.SLOW_FLOOR_MS + 50)])
        self.assertEqual(counts["slow"], 1)
        for span in kept[0]["spans"]:
            self.assertEqual(span["attributes"]["kh.sampling.factor"], 1)
            self.assertEqual(span["attributes"]["kh.sampling.reason"], "slow")

    def test_a_randomly_kept_action_declares_what_it_stands_for(self):
        s = tail_sampler.TailSampler(self.path, rng=random.Random(0))
        seen = []
        for _ in range(500):
            kept, _ = tail_sampler.apply(s, [action(5)])
            if kept:
                seen.append(kept[0]["spans"][0]["attributes"]["kh.sampling.factor"])
        self.assertTrue(seen)
        self.assertEqual(set(seen), {tail_sampler.RANDOM_KEEP_FACTOR})

    def test_a_passthrough_trace_is_not_stamped_at_all(self):
        """Stamping a factor on something that was never sampled would be a
        false claim about it."""
        s = tail_sampler.TailSampler(self.path)
        kept, _ = tail_sampler.apply(s, [action(1, root_name="station.connect")])
        self.assertNotIn("kh.sampling.factor", kept[0]["spans"][0]["attributes"])

"""Tests for the server-side reach probes (scripts/serve/probes.py).

Everything here defends ONE property, and it is not accuracy: a probe may lose a
count and nobody is harmed, but a probe that raises turns an observation into an
outage. `hit()` is called from inside `except` handlers, from the walk-in
watchdog and from the fence in front of every gated request, so the tests below
attack it with a store that raises, a store that is absent, and ids that are not
declared, and require silence from all three.

The second property is the one that makes a ZERO readable: the declared set is
the report's denominator, so a declaration with no call site is a zero that means
"I forgot", and the build gate that catches it (scripts/analytics/catalogue.mjs)
is asserted here to be more than a comment.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))

import probes  # noqa: E402

import analytics  # noqa: E402


class Raises:
    """A store that fails every way a store can fail."""

    def record_server(self, counts):
        raise RuntimeError("the disk is gone")


class Counting:
    def __init__(self):
        self.calls = []

    def record_server(self, counts):
        self.calls.append(dict(counts))
        return len(counts)


class ProbeFoldTest(unittest.TestCase):
    def setUp(self):
        probes.reset_for_tests()

    def tearDown(self):
        probes.reset_for_tests()

    # ---- the never-raises property -----------------------------------------

    def test_hit_never_raises_when_the_store_is_broken(self):
        probes.bind(Raises())
        probes._next_flush = 0.0  # force the flush on the very next hit
        # No assertRaises: the assertion IS that this line returns.
        probes.hit("auth.gate.invited")
        self.assertEqual(probes.stats()["droppedFlushes"], 1)

    def test_hit_never_raises_with_no_store_bound(self):
        probes.hit("auth.gate.invited")
        self.assertEqual(probes.stats()["pending"], {"auth.gate.invited": 1})

    def test_hit_never_raises_on_a_junk_id(self):
        for junk in (None, 17, "", "not.declared", object(), b"bytes"):
            probes.hit(junk)  # type: ignore[arg-type]
        self.assertEqual(probes.stats()["pending"], {})

    def test_flush_never_raises_when_the_store_is_broken(self):
        probes.bind(Raises())
        probes.hit("auth.gate.walkin")
        self.assertEqual(probes.flush(), 1)
        self.assertEqual(probes.stats()["droppedFlushes"], 1)

    def test_a_failed_flush_does_not_retry_on_every_hit(self):
        """The throttle is re-armed BEFORE the write, so a store that is down
        costs one attempt a minute rather than one attempt a request."""
        store = Raises()
        probes.bind(store)
        probes._next_flush = 0.0
        for _ in range(500):
            probes.hit("auth.gate.invited")
        self.assertEqual(probes.stats()["droppedFlushes"], 1)

    # ---- the fold ----------------------------------------------------------

    def test_counts_fold_in_memory_and_write_nothing_until_flushed(self):
        store = Counting()
        probes.bind(store)
        for _ in range(3):
            probes.hit("walkin.reap.ttl")
        probes.hit("walkin.reap.idle")
        self.assertEqual(store.calls, [])
        probes.flush()
        self.assertEqual(store.calls, [{"walkin.reap.ttl": 3, "walkin.reap.idle": 1}])

    def test_the_fold_is_bounded_by_the_catalogue_not_by_traffic(self):
        for i in range(5000):
            probes.hit("auth.gate.invited")
            probes.hit(f"made.up.{i}")
        self.assertEqual(len(probes.stats()["pending"]), 1)

    def test_flush_empties_the_fold(self):
        probes.bind(Counting())
        probes.hit("auth.gate.blocked")
        probes.flush()
        self.assertEqual(probes.stats()["pending"], {})
        self.assertEqual(probes.flush(), 0)

    def test_the_throttle_holds_writes_back(self):
        store = Counting()
        probes.bind(store)
        for _ in range(50):
            probes.hit("auth.gate.invited")
        # FLUSH_SECS is a minute; nothing in a tight loop may have escaped.
        self.assertEqual(store.calls, [])
        probes._next_flush = time.monotonic() - 1
        probes.hit("auth.gate.invited")
        self.assertEqual(store.calls, [{"auth.gate.invited": 51}])


class ServerClassTest(unittest.TestCase):
    """The store side: a real database, and the boundary around class=server."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = analytics.AnalyticsStore(Path(self.tmp.name) / "a.db")
        probes.reset_for_tests()

    def tearDown(self):
        probes.reset_for_tests()
        self.store.close()
        self.tmp.cleanup()

    def test_probes_land_under_class_server_with_grade_auto(self):
        probes.bind(self.store)
        probes.hit("signal.ticket.identityDiffers")
        probes.flush()
        self.assertEqual(
            self.store.report(days=1, klass="server")["probes"],
            {"signal.ticket.identityDiffers": {"auto": 1}},
        )

    def test_server_rows_are_invisible_to_the_human_report(self):
        # The same protection the `probe` class gives: a server branch count
        # must never move a keep/drop decision about the SPA.
        self.store.record_server({"auth.gate.invited": 9})
        self.assertEqual(self.store.report(days=1, klass="human")["probes"], {})

    def test_a_client_cannot_forge_the_server_class(self):
        # THE SECURITY BOUNDARY. `record()` takes its class from a posted body.
        # If `server` were reachable from there, a browser could claim a dead
        # refusal branch is alive and get code kept that should be deleted.
        self.store.record({"class": "server", "probes": [{"id": "auth.gate.invited", "grade": "auto", "n": 5}]})
        self.assertEqual(self.store.report(days=1, klass="server")["probes"], {})
        self.assertEqual(self.store.report(days=1, klass="unknown")["probes"]["auth.gate.invited"]["auto"], 5)

    def test_record_server_validates_ids_and_counts(self):
        taken = self.store.record_server(
            {"auth.gate.invited": 2, "Not An Id": 4, "auth.gate.walkin": 0, "auth.gate.blocked": -1}
        )
        self.assertEqual(taken, 1)
        self.assertEqual(list(self.store.report(days=1, klass="server")["probes"]), ["auth.gate.invited"])

    def test_counts_accumulate_across_flushes(self):
        probes.bind(self.store)
        probes.hit("walkin.claim.queued")
        probes.flush()
        probes.hit("walkin.claim.queued")
        probes.flush()
        self.assertEqual(self.store.report(days=1, klass="server")["probes"]["walkin.claim.queued"]["auto"], 2)


class CatalogueTest(unittest.TestCase):
    def test_every_id_is_storable(self):
        # An id the store's ID_RE rejects is a probe that can only read zero,
        # for a reason that has nothing to do with the branch being dead.
        for pid in probes.PROBES:
            self.assertIsNotNone(analytics.ID_RE.match(pid), pid)

    def test_every_owner_exists_and_is_not_the_declaration(self):
        for pid, spec in probes.PROBES.items():
            self.assertTrue((ROOT / spec.owner).is_file(), f"{pid}: {spec.owner}")
            self.assertNotEqual(spec.owner, "scripts/serve/probes.py", pid)

    def test_every_consumes_names_a_declared_probe(self):
        for pid, spec in probes.PROBES.items():
            if spec.consumes:
                self.assertIn(spec.consumes, probes.PROBES, pid)

    def test_the_call_site_gate_is_not_a_comment(self):
        """The load-bearing half, asserted rather than trusted: every declared
        probe has a literal `hit(...)` in the file it names as its owner."""
        for pid, spec in probes.PROBES.items():
            source = (ROOT / spec.owner).read_text()
            self.assertTrue(
                f'hit("{pid}")' in source or f"hit('{pid}')" in source,
                f"{pid}: no call site in {spec.owner}",
            )

    def test_the_module_prints_its_catalogue_as_json(self):
        # This is how scripts/analytics/catalogue.mjs reads the declaration;
        # if it stops being valid JSON the build gate cannot run at all.
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "serve" / "probes.py")],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(set(json.loads(out.stdout)), set(probes.PROBES))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests for the interaction counters (scripts/serve/usage.py) and the session
`lastSeenAt` touch (scripts/serve/auth/store.py).

Two properties carry the whole feature and are stated directly here:

* **A viewer's counts never reach another viewer.** The document served openly
  (`stations()`) is asserted to contain no user id under any key, at any depth —
  not "the UI does not draw it", but "the bytes do not contain it".
* **A tab cannot inflate a total without limit.** The per-report clamp is
  exercised with the numbers a forger would actually send.

The lastSeenAt tests pin the throttle, because a touch on every gated request
would rewrite (and snapshot, and fsync) the account database per image fetched.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SERVE = Path(__file__).resolve().parent / "serve"
sys.path.insert(0, str(SERVE))

import usage  # noqa: E402


def _load(name: str, path: Path):
    """Import one module by path.

    `auth/store.py` is loaded this way rather than as `auth.store` because the
    package's __init__ pulls in the WebAuthn ceremonies, and therefore fido2 —
    a dependency this file has no use for. The state file's bookkeeping should
    be testable wherever python runs.
    """
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


store_mod = _load("auth_store_under_test", SERVE / "auth" / "store.py")
AuthStore = store_mod.AuthStore


class TestUsageStore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "usage-stats.json"
        self.store = usage.UsageStore(self.path)

    def tearDown(self):
        self.tmp.cleanup()

    def report(self, user, stations):
        return self.store.record(user, stations)

    def test_counts_land_on_both_the_person_and_the_machine(self):
        self.report("u1", {"win95": {"clicks": 3, "keys": 7}})
        win95 = self.store.stations()["stations"]["win95"]
        self.assertEqual((win95["clicks"], win95["keys"]), (3, 7))
        self.assertTrue(win95["lastAt"].endswith("Z"))
        board = self.store.scoreboard([{"id": "u1", "name": "Jukka", "role": "viewer"}])
        row = board["users"][0]
        self.assertEqual((row["clicks"], row["keys"]), (3, 7))
        self.assertEqual(row["stations"]["win95"]["clicks"], 3)

    def test_reports_accumulate(self):
        self.report("u1", {"win95": {"clicks": 2, "keys": 0}})
        self.report("u1", {"win95": {"clicks": 5, "keys": 1}})
        self.assertEqual(self.store.stations()["stations"]["win95"]["clicks"], 7)

    def test_an_unauthenticated_report_still_counts_for_the_machine(self):
        """The LAN listener has no sessions; the machine was still used."""
        self.report(None, {"beos": {"clicks": 4, "keys": 0}})
        self.assertEqual(self.store.stations()["stations"]["beos"]["clicks"], 4)
        self.assertEqual(self.store.scoreboard([])["users"], [])

    def test_the_open_document_carries_no_identity_anywhere_in_it(self):
        self.report("u1", {"win95": {"clicks": 3, "keys": 7}})
        self.report("u2", {"beos": {"clicks": 1, "keys": 2}})
        blob = json.dumps(self.store.stations())
        self.assertNotIn("u1", blob)
        self.assertNotIn("u2", blob)
        self.assertNotIn("users", blob)

    def test_a_forged_report_is_clamped_per_report(self):
        self.report("u1", {"win95": {"clicks": 10_000_000, "keys": 10_000_000}})
        row = self.store.scoreboard([{"id": "u1", "name": "x", "role": "viewer"}])["users"][0]
        self.assertEqual(row["clicks"], usage.MAX_EDGES_PER_REPORT)
        self.assertEqual(row["keys"], usage.MAX_EDGES_PER_REPORT)

    def test_junk_is_ignored_rather_than_stored(self):
        for junk in (
            {"../../etc/passwd": {"clicks": 1}},
            {"WIN95": {"clicks": 1}},
            {"win95": {"clicks": -5, "keys": "many"}},
            {"win95": {"clicks": True}},
            {"win95": "not-an-object"},
        ):
            self.report("u1", junk)
        self.assertEqual(self.store.stations()["stations"], {})

    def test_a_flood_of_unknown_ids_cannot_grow_the_file_without_bound(self):
        for i in range(usage.MAX_STATIONS_TRACKED + 50):
            self.report(None, {f"junk{i}": {"clicks": 1}})
        self.assertEqual(len(self.store.stations()["stations"]), usage.MAX_STATIONS_TRACKED)

    def test_only_the_first_stations_of_an_oversized_report_are_read(self):
        big = {f"s{i}": {"clicks": 1} for i in range(usage.MAX_STATIONS_PER_REPORT + 10)}
        self.report("u1", big)
        self.assertEqual(len(self.store.stations()["stations"]), usage.MAX_STATIONS_PER_REPORT)

    def test_removing_a_person_removes_their_counters_but_not_the_machines(self):
        self.report("u1", {"win95": {"clicks": 3, "keys": 0}})
        self.store.forget_user("u1")
        self.assertEqual(self.store.scoreboard([{"id": "u1", "name": "x", "role": "viewer"}])["users"][0]["clicks"], 0)
        self.assertEqual(self.store.stations()["stations"]["win95"]["clicks"], 3)

    def test_somebody_who_never_clicked_is_on_the_scoreboard_with_a_zero(self):
        rows = self.store.scoreboard([{"id": "ghost", "name": "Nobody", "role": "viewer"}])["users"]
        self.assertEqual(rows[0]["clicks"], 0)
        self.assertIsNone(rows[0]["lastAt"])

    def test_counts_survive_a_restart(self):
        self.report("u1", {"win95": {"clicks": 3, "keys": 0}})
        self.store.flush()
        self.assertEqual(usage.UsageStore(self.path).stations()["stations"]["win95"]["clicks"], 3)

    def test_a_corrupt_counter_file_starts_over_instead_of_refusing_to_serve(self):
        self.path.write_text("{not json")
        self.assertEqual(usage.UsageStore(self.path).stations()["stations"], {})


class TestLastSeen(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = AuthStore(Path(self.tmp.name) / "auth-state.json")
        self.user = self.store.add_user_with_id("u1", "Jukka", "viewer")
        self.token = self.store.new_session("u1", "127.0.0.1", "agent")

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_new_user_has_never_been_seen(self):
        self.assertIsNone(self.user["lastSeenAt"])

    def test_resolving_a_session_stamps_the_user(self):
        self.assertIsNotNone(self.store.session_user(self.token))
        self.assertIsNotNone(self.store.user("u1")["lastSeenAt"])

    def test_the_stamp_is_throttled(self):
        """Every gated request resolves a session, and every write rewrites the
        whole account database with an fsync. Only the first touch may write."""
        self.store.session_user(self.token)
        stamped = self._session()["lastSeenTs"]
        self._session()["lastSeenTs"] = stamped - 5  # inside the window
        self.store.session_user(self.token)
        self.assertEqual(self._session()["lastSeenTs"], stamped - 5)

    def test_the_stamp_moves_once_the_throttle_window_passes(self):
        self.store.session_user(self.token)
        stale = self._session()["lastSeenTs"] - store_mod.SEEN_TOUCH_SECS - 1
        self._session()["lastSeenTs"] = stale
        self.store.session_user(self.token)
        self.assertGreater(self._session()["lastSeenTs"], stale)

    def _session(self):
        return self.store._doc["sessions"][0]

    def test_a_bad_token_stamps_nothing(self):
        self.assertIsNone(self.store.session_user("not-a-token"))
        self.assertIsNone(self.store.user("u1")["lastSeenAt"])


if __name__ == "__main__":
    unittest.main()

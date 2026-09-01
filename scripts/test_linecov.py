"""Tests for the production line-coverage store (scripts/serve/linecov.py).

The cases that are here because they were wrong first:

  * A file with ZERO executed lines must be STORED, not dropped. The encoder
    emits the empty string for the empty set, an early version rejected it as
    malformed, and the row it silently dropped was "this module shipped and
    never ran" — the one finding the whole plane exists to produce.
  * The executed set is clamped to the instrumented set, so a forged or mangled
    payload cannot invent covered lines the build never had.
  * Two builds never merge. Line numbers move; a union would report a line as
    covered because a different revision of the file once had a live line there.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import linecov  # noqa: E402


def payload(build="abc123def456", klass="human", files=None):
    return {"build": build, "class": klass, "files": files or []}


class RoundTripTest(unittest.TestCase):
    def test_encode_decode_is_lossless(self):
        for case in ({1}, {1, 2, 3}, {5, 6, 9, 40, 41, 42}, set(range(1, 500)), set()):
            self.assertEqual(linecov.decode_lines(linecov.encode_lines(case)), case)

    def test_empty_set_is_the_empty_string(self):
        self.assertEqual(linecov.encode_lines(set()), "")
        self.assertEqual(linecov.decode_lines(""), set())

    def test_malformed_decodes_to_nothing_rather_than_raising(self):
        for bad in ("...", "1.", "zz.!", "1.2.3", "-1.2", "1.0"):
            self.assertEqual(linecov.decode_lines(bad), set(), bad)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = linecov.CoverageStore(Path(self.dir.name) / "coverage.db")

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def one(self, name="src/a.ts", every="1.5", hit="1.2"):
        return {"f": name, "a": every, "h": hit}

    def test_a_file_that_never_ran_is_kept(self):
        self.assertEqual(self.store.record(payload(files=[self.one(hit="")])), 1)
        report = self.store.report()
        self.assertEqual(report["files"]["src/a.ts"]["lines"], 5)
        self.assertEqual(report["files"]["src/a.ts"]["executed"], 0)
        self.assertEqual(report["files"]["src/a.ts"]["pct"], 0.0)

    def test_sessions_union_rather_than_add(self):
        self.store.record(payload(files=[self.one(hit="1.2")]))
        self.store.record(payload(files=[self.one(hit="2.2")]))
        entry = self.store.report()["files"]["src/a.ts"]
        # lines 1,2 then 2,3 -> three distinct lines, not four hits.
        self.assertEqual(entry["executed"], 3)
        self.assertEqual(linecov.decode_lines(entry["never"]), {4, 5})

    def test_executed_is_clamped_to_the_instrumented_set(self):
        self.store.record(payload(files=[self.one(every="1.2", hit="1.900")]))
        entry = self.store.report()["files"]["src/a.ts"]
        self.assertEqual(entry["lines"], 2)
        self.assertLessEqual(entry["executed"], entry["lines"])

    def test_builds_are_never_unioned(self):
        self.store.record(payload(build="aaaaaa", files=[self.one(hit="1.5")]))
        self.store.record(payload(build="bbbbbb", files=[self.one(hit="")]))
        newest = self.store.report()
        self.assertEqual(newest["window"]["build"], "bbbbbb")
        self.assertEqual(newest["files"]["src/a.ts"]["executed"], 0)
        older = self.store.report(build="aaaaaa")
        self.assertEqual(older["files"]["src/a.ts"]["executed"], 5)

    def test_class_separates_the_probe_fleet_from_people(self):
        self.store.record(payload(klass="probe", files=[self.one(hit="1.5")]))
        self.assertEqual(self.store.report(klass="human")["files"]["src/a.ts"]["executed"], 0)
        self.assertEqual(self.store.report(klass="probe")["files"]["src/a.ts"]["executed"], 5)

    def test_junk_is_dropped_without_raising(self):
        for bad in (
            payload(build="not a build"),
            payload(files=[{"f": "../../etc/passwd", "a": "1.5", "h": ""}]),
            payload(files=[{"f": "src/a.ts", "a": "x" * (linecov.MAX_RLE + 1), "h": ""}]),
            payload(files=[{"f": "src/a.ts", "a": "", "h": ""}]),
            payload(files="not a list"),
            {},
        ):
            self.assertEqual(self.store.record(bad), 0, bad)

    def test_no_identity_column_exists(self):
        """The privacy guarantee is structural, not a habit: assert there is
        nowhere in the schema an id could be put by a later careless caller."""
        cur = self.store._db.cursor()
        for table in ("covmap", "covhit", "covbuild"):
            cols = {r[1].lower() for r in cur.execute(f"PRAGMA table_info({table})")}
            self.assertFalse(cols & {"user", "userid", "user_id", "session", "sessionid", "ip"})
        self.store.record(payload(files=[self.one()]) | {"sessionId": "s1", "user": "wnt"})
        blob = json.dumps(self.store.report())
        self.assertNotIn("wnt", blob)
        self.assertNotIn("s1", blob)

    def test_build_count_is_bounded(self):
        for i in range(linecov.MAX_BUILDS + 4):
            self.store.record(payload(build=f"{i:06x}", files=[self.one()]))
        self.assertLessEqual(len(self.store.report()["builds"]), linecov.MAX_BUILDS)


if __name__ == "__main__":
    unittest.main()

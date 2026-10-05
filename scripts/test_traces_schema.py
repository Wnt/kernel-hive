"""Tests for the trace store's schema against stores that already exist.

Split from test_traces.py by subject: everything here opens a db that was
NOT created by today's `SCHEMA` — an older shape, or the live shape with
columns today's code no longer names — because a fresh-db test is exactly the
test that cannot see the failure these exist for.
"""

from __future__ import annotations

import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import traces  # noqa: E402

from test_traces import S1, S2, S3, T1, batch, span  # noqa: E402


class PreMigrationStoreTest(unittest.TestCase):
    """Opening a store whose db predates the columns today's code writes.

    This is the case that took the serving plane down on 2026-09-01: every
    test built a FRESH db, where `CREATE TABLE` makes the new columns and
    nothing noticed that `SCHEMA` also indexed one of them. On a db that
    already had a `trace` table, `CREATE TABLE IF NOT EXISTS` is a no-op, so
    the index in SCHEMA ran against a column the migration had not added yet
    and the process exited 1 on startup, in a restart loop, with the gallery
    serving 502.
    """

    #: The SPAN table as it stood before span LINKS — the shape a live
    #: traces.db still has at the instant the new code first opens it.
    OLD_SPAN_TABLE = """
    CREATE TABLE span (
      trace_id TEXT NOT NULL, span_id TEXT NOT NULL, parent_id TEXT,
      name TEXT NOT NULL, kind TEXT NOT NULL,
      started_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL, hidden_ms INTEGER NOT NULL,
      status TEXT NOT NULL, status_msg TEXT,
      attrs TEXT, events TEXT,
      PRIMARY KEY (trace_id, span_id)) WITHOUT ROWID;
    """

    OLD_TRACE_TABLE = """
    CREATE TABLE trace (
      trace_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL, class TEXT NOT NULL,
      root_name TEXT NOT NULL,
      started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL,
      span_count INTEGER NOT NULL, error_count INTEGER NOT NULL,
      status TEXT NOT NULL, day TEXT NOT NULL) WITHOUT ROWID;
    """

    def _old_db(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "traces.db"
        db = sqlite3.connect(str(path))
        db.executescript(self.OLD_TRACE_TABLE)
        db.executescript(self.OLD_SPAN_TABLE)
        db.execute(
            "INSERT INTO trace VALUES(?,'s','human','r',100,200,100,1,0,'ok','2026-09-01')",
            ("a" * 32,),
        )
        db.commit()
        db.close()
        return path

    def test_a_pre_migration_store_opens(self):
        store = traces.TraceStore(self._old_db())
        self.assertEqual(len(store.search(limit=10)["traces"]), 1)

    def test_opening_twice_is_stable(self):
        path = self._old_db()
        traces.TraceStore(path)
        traces.TraceStore(path)  # every migration already ran; must not raise

    def test_a_store_written_before_build_identity_gets_the_column(self):
        """A live traces.db keeps its old columns forever unless somebody says
        otherwise, and the FIRST batch to arrive after the deploy would
        otherwise fail its INSERT against a column that is not there — with
        the gallery in a restart loop, which is exactly how this class was
        born."""
        path = self._old_db()
        store = traces.TraceStore(path)
        self.addCleanup(store.close)
        # The pre-existing row reads `unknown`, which is the truth about it.
        self.assertEqual(store.search(limit=10)["traces"][0]["build"], "unknown")
        self.assertEqual(store.record(batch([span(S1)], build="main@abc1234")), 1)
        self.assertEqual(store.trace(T1)["build"], "main@abc1234")


class RetiredColumnsStoreTest(unittest.TestCase):
    """The LIVE shape as of 2026-10-05: a `trace` table still carrying
    `ingest_seq` / `updated_ms` and their index, from the retired incremental
    export (traces_schema.py, "RETIRED COLUMNS"). Today's code names neither,
    so it must open that store, write to it and read it back unchanged."""

    LIVE_TRACE_TABLE = """
    CREATE TABLE trace (
      trace_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL, class TEXT NOT NULL,
      root_name TEXT NOT NULL,
      started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL,
      span_count INTEGER NOT NULL, error_count INTEGER NOT NULL,
      status TEXT NOT NULL, day TEXT NOT NULL,
      ingest_seq INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER NOT NULL DEFAULT 0,
      build TEXT NOT NULL DEFAULT 'unknown') WITHOUT ROWID;
    CREATE INDEX trace_ingest ON trace(ingest_seq);
    """

    def test_a_store_with_the_retired_columns_opens_writes_and_reads(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "traces.db"
        db = sqlite3.connect(str(path))
        db.executescript(self.LIVE_TRACE_TABLE)
        db.executescript(PreMigrationStoreTest.OLD_SPAN_TABLE)
        db.close()
        store = traces.TraceStore(path)
        self.addCleanup(store.close)
        self.assertEqual(store.record(batch([span(S1), span(S2, parent=S1)])), 2)
        self.assertEqual(store.search(limit=10)["total"], 1)
        self.assertEqual(len(store.trace(T1)["spans"]), 2)
        # A second batch into the same trace takes the UPDATE path of the upsert.
        self.assertEqual(store.record(batch([span(S3, parent=S1)])), 1)
        self.assertEqual(store.search(limit=10)["traces"][0]["spanCount"], 3)


if __name__ == "__main__":
    unittest.main()

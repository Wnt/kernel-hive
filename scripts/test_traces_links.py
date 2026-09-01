"""Span LINKS in the store: "caused by, but not nested under".

Split out of `test_traces.py` when that file crossed its size budget, and it is
a clean seam: since 2026-09-01 a trace here means ONE ACTION, so the relation
between a keystroke and the page load it happened on is no longer a parent — it
is a link, and it has to survive intake and export intact or the causal edge is
simply gone. `spa/src/analytics/pageLoadLink.ts` has the reasoning;
`docs/lab/TRACE-CONTEXT.md` §7.1 is the contract. This pins the store's half.
"""

from __future__ import annotations

import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
# ...and `scripts` itself, so the shared fixtures below import the same way
# whether this runs under `unittest discover -s scripts` (which puts the start
# directory on the path for you) or as a named module, which does not.
sys.path.insert(0, str(ROOT / "scripts"))

import traces  # noqa: E402
import traces_otlp  # noqa: E402

from test_traces import S1, S3, T1, T2, PreMigrationStoreTest, batch, span  # noqa: E402


class SpanLinkTest(unittest.TestCase):
    """Span LINKS: "caused by, but not nested under".

    Since 2026-09-01 a trace here means ONE ACTION, so the relation between a
    keystroke and the page load it happened on is no longer a parent — it is a
    link, and it has to survive intake and export intact or the causal edge is
    simply gone. `spa/src/analytics/pageLoadLink.ts` has the reasoning; this
    pins the store's half.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    LINK = {"t": T2, "s": S3, "a": {"kh.link.kind": "page.load"}}

    def test_a_link_is_stored_and_read_back(self):
        self.store.record(batch([span(S1, name="input.edge", kind="client", l=[self.LINK])]))
        spans = self.store.trace(T1)["spans"]
        self.assertEqual(spans[0]["links"], [self.LINK])

    def test_a_span_with_no_links_reads_back_as_an_empty_list(self):
        """Never `None`: a consumer that has to test for two kinds of "nothing"
        eventually tests for one of them."""
        self.store.record(batch([span(S1)]))
        self.assertEqual(self.store.trace(T1)["spans"][0]["links"], [])

    def test_a_malformed_link_is_dropped_rather_than_stored(self):
        """A link that does not name real ids would render as a dead end in the
        admin view, which is worse than no link at all."""
        bad = [
            {"t": "nope", "s": S3},
            {"t": T2, "s": "nope"},
            {"s": S3},
            {"t": T2},
            "not-a-dict",
        ]
        self.store.record(batch([span(S1, l=bad)]))
        self.assertEqual(self.store.trace(T1)["spans"][0]["links"], [])

    def test_links_are_bounded(self):
        many = [{"t": T2, "s": S3} for _ in range(traces.LINK_MAX + 20)]
        self.store.record(batch([span(S1, l=many)]))
        self.assertEqual(len(self.store.trace(T1)["spans"][0]["links"]), traces.LINK_MAX)

    def test_a_secret_on_a_link_is_refused_like_any_other_attribute(self):
        """The one content rule has to hold on EVERY path into the store, not on
        most of them — a new field is exactly where a leak gets in."""
        self.store.record(batch([span(S1, l=[{"t": T2, "s": S3, "a": {"kh.ticket": "v1|beos|9|n|sig"}}])]))
        self.assertEqual(self.store.trace(T1)["spans"][0]["links"][0]["a"], {})

    def test_export_renders_links_as_otlp(self):
        self.store.record(batch([span(S1, name="input.edge", kind="client", l=[self.LINK])]))
        doc = traces_otlp.export([self.store.trace(T1)])
        out = doc["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
        self.assertEqual(out["links"][0]["traceId"], T2)
        self.assertEqual(out["links"][0]["spanId"], S3)
        self.assertEqual(
            out["links"][0]["attributes"],
            [{"key": "kh.link.kind", "value": {"stringValue": "page.load"}}],
        )

    def test_export_omits_links_entirely_when_there_are_none(self):
        self.store.record(batch([span(S1)]))
        doc = traces_otlp.export([self.store.trace(T1)])
        self.assertNotIn("links", doc["resourceSpans"][0]["scopeSpans"][0]["spans"][0])

    def test_a_READ_ONLY_reader_on_an_unmigrated_store_degrades_rather_than_dies(self):
        """A report must never be the thing that breaks on a deploy.

        A read-only opener cannot migrate the file it is reading, so between
        `box-deploy.sh --apply` writing the new code and the serving plane
        restarting to run the migration, `scripts/observability/
        trace-orphans.py` would select a column that is not there yet. It reads
        an empty link list instead."""
        # The realistic mid-deploy shape: a store the PREVIOUS release wrote,
        # so everything before links is there and links is not.
        path = Path(self.tmp.name) / "old.db"
        writer = traces.TraceStore(path)
        writer.record(batch([span(S1, name="input.edge", kind="client")]))
        writer.close()
        db = sqlite3.connect(str(path))
        db.execute("ALTER TABLE span DROP COLUMN links")
        db.commit()
        db.close()
        reader = traces.TraceStore(path, read_only=True)
        self.addCleanup(reader.close)
        self.assertEqual(reader.trace(T1)["spans"][0]["links"], [])

    def test_a_store_written_before_span_links_takes_a_linked_span(self):
        """The deploy-ordering trap, third instance. The FIRST batch after the
        deploy names a `links` column, and on a live db that column only exists
        if a migration put it there — without which the whole serving plane
        502s on the next span, in a restart loop. `PreMigrationStoreTest` in
        test_traces.py was born of exactly that outage."""
        path = Path(self.tmp.name) / "premigration.db"
        db = sqlite3.connect(str(path))
        db.executescript(PreMigrationStoreTest.OLD_TRACE_TABLE)
        db.executescript(PreMigrationStoreTest.OLD_SPAN_TABLE)
        db.commit()
        db.close()
        store = traces.TraceStore(path)
        self.addCleanup(store.close)
        self.assertEqual(store.record(batch([span(S1, name="input.edge", l=[self.LINK])])), 1)
        self.assertEqual(store.trace(T1)["spans"][0]["links"], [self.LINK])

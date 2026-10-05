"""The traces store's schema, and the migrations that reshape an existing one.

SPLIT OUT OF `traces.py`, not invented here: that file crossed its size budget
once two features landed in it on the same day, and schema-plus-migrations is
the seam that comes away whole. Everything below moved verbatim, comments
included — those comments record an outage and are the reason this is careful.

THE RULE THIS FILE EXISTS TO ENFORCE. `executescript(SCHEMA)` runs on EVERY
open, and `CREATE TABLE IF NOT EXISTS` does not reshape a table that already
exists. So SCHEMA may never name a column a migration adds — an index over a
not-yet-added column takes the serving plane down on the next restart, in a
crash loop, which is exactly what happened on 2026-09-01. Indexes over migrated
columns are created by the migration, after the ALTER, on every path.

RETIRED COLUMNS. A traces.db created before 2026-10-05 also carries `trace`
columns `ingest_seq` and `updated_ms` and a `trace_ingest` index, left by a
since-removed incremental export that walked the store in ingest order. Nothing
reads or writes them any more; both are `NOT NULL DEFAULT 0`, so an INSERT that
does not name them still succeeds, and leaving them costs less than rebuilding a
live table to drop them.
"""

from __future__ import annotations

SCHEMA = """
CREATE TABLE IF NOT EXISTS span (
  trace_id TEXT NOT NULL, span_id TEXT NOT NULL, parent_id TEXT,
  name TEXT NOT NULL, kind TEXT NOT NULL,
  started_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL, hidden_ms INTEGER NOT NULL,
  status TEXT NOT NULL, status_msg TEXT,
  attrs TEXT, events TEXT,
  PRIMARY KEY (trace_id, span_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS span_trace ON span(trace_id);

-- One row per trace, maintained as spans arrive. It exists so the trace LIST
-- never touches the span table: listing is the query the UI runs constantly
-- (filter, paginate, sort by time) and it must not scan every span to answer.
CREATE TABLE IF NOT EXISTS trace (
  trace_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL, class TEXT NOT NULL,
  root_name TEXT NOT NULL,
  started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL,
  span_count INTEGER NOT NULL, error_count INTEGER NOT NULL,
  status TEXT NOT NULL, day TEXT NOT NULL,
  -- WHICH BUNDLE THE CLIENT WAS RUNNING, off the batch's RESOURCE envelope
  -- (spa/src/analytics/index.ts) — not off a span, because it is one fact about
  -- the tab, not about a moment in it. It is here, on the trace, for the
  -- question it exists to answer: "was this client on the shell we think we
  -- deployed?" Reachable with one SQL statement and no vendor; before it, the
  -- only record of a client's build was a third-party beacon's meta, which is
  -- the wrong place for a dependency we intend to drop.
  build TEXT NOT NULL DEFAULT 'unknown')
  WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS trace_started ON trace(started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_session ON trace(session_id, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_name ON trace(root_name, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_errors ON trace(error_count, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_day ON trace(day);
"""


def migrate_links(db) -> None:
    """Give a store written before span LINKS existed the column anyway.

    Same reason `migrate_build` exists: `CREATE TABLE IF NOT EXISTS` does not
    reshape a table that is already there. And the same rule as the module
    docstring's — the column is added HERE and never named in SCHEMA, because
    SCHEMA runs first on every open and would then fail on every store written
    before this migration.

    WHAT A LINK IS, and why the store needed a new column rather than an
    attribute. A link is OpenTelemetry's spelling of "this span was caused by
    that one, WITHOUT being nested under it" — which is exactly the relation
    an input action has to the page load it happened on. Since 2026-09-01 a
    trace here means ONE ACTION, so the page load is no longer an ancestor of
    the keystroke; the causal edge still exists and it is drawn with a link.
    Existing rows read `[]`, which is the truth about them: they were recorded
    when a visit was one trace and nothing needed linking.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(span)")}
    if "links" not in have:
        cur.execute("ALTER TABLE span ADD COLUMN links TEXT")


def migrate_build(db) -> None:
    """Give a store written before build identity existed the column anyway.

    `CREATE TABLE IF NOT EXISTS` does not reshape a table that is already
    there, so a live traces.db would keep the old shape forever. Existing rows read `unknown`, which is
    the truth about them — they were recorded when nobody was told.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(trace)")}
    if "build" not in have:
        cur.execute("ALTER TABLE trace ADD COLUMN build TEXT NOT NULL DEFAULT 'unknown'")


# ---- intake ------------------------------------------------------------

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
  build TEXT NOT NULL DEFAULT 'unknown',
  -- INGEST ORDER, not trace time. Bumped to (max+1) every time a span lands in
  -- this trace, so "what changed since I last looked" is answerable without
  -- guessing how long a tab will keep contributing to a trace it opened
  -- minutes ago. `updated_ms` is the wall clock of that same moment, which is
  -- what a "has this trace been quiet for a while?" question needs; the client
  -- clocks in started_ms/ended_ms cannot answer it because they are not ours.
  -- Both exist for scripts/observability/instana-forward.py — see the watermark
  -- comment there for the data-loss bug that bought them.
  ingest_seq INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER NOT NULL DEFAULT 0)
  WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS trace_started ON trace(started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_session ON trace(session_id, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_name ON trace(root_name, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_errors ON trace(error_count, started_ms DESC);
CREATE INDEX IF NOT EXISTS trace_day ON trace(day);
"""


def migrate_ingest_order(db) -> None:
    """Give a store written before ingest ordering existed one anyway.

    `CREATE TABLE IF NOT EXISTS` does not add columns to a table that is
    already there, so a live traces.db keeps the old shape forever unless
    somebody says otherwise. The backfill numbers existing traces by
    `started_ms`, which is the order the only consumer (the Instana
    forwarder) previously walked them in — so its old `lastTraceStartedMs`
    watermark converts to a sequence watermark exactly, with neither a gap
    nor a replay of a fortnight of history on the first run afterwards.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(trace)")}
    if "ingest_seq" not in have:
        cur.execute("ALTER TABLE trace ADD COLUMN ingest_seq INTEGER NOT NULL DEFAULT 0")
        cur.execute("ALTER TABLE trace ADD COLUMN updated_ms INTEGER NOT NULL DEFAULT 0")
        cur.execute(
            "UPDATE trace SET ingest_seq=(SELECT n FROM (SELECT trace_id,"
            "ROW_NUMBER() OVER (ORDER BY started_ms) AS n FROM trace) o "
            "WHERE o.trace_id=trace.trace_id), updated_ms=ended_ms"
        )
    # Indexed here and NOT in SCHEMA: SCHEMA runs first and `CREATE TABLE IF
    # NOT EXISTS` does not reshape a table that already exists, so an index
    # naming `ingest_seq` in SCHEMA fails on every store written before this
    # migration -- which took the serving plane down once already.
    cur.execute("CREATE INDEX IF NOT EXISTS trace_ingest ON trace(ingest_seq)")


def migrate_links(db) -> None:
    """Give a store written before span LINKS existed the column anyway.

    Same reason the two migrations either side of this one exist: `CREATE
    TABLE IF NOT EXISTS` does not reshape a table that is already there. And
    the same rule as `migrate_ingest_order`'s closing comment — the column is
    added HERE and never named in SCHEMA, because SCHEMA runs first on every
    open and would then fail on every store written before this migration.

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

    Same reason `_migrate_ingest_order` exists: `CREATE TABLE IF NOT EXISTS`
    does not reshape a table that is already there, so a live traces.db
    would keep the old shape forever. Existing rows read `unknown`, which is
    the truth about them — they were recorded when nobody was told.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(trace)")}
    if "build" not in have:
        cur.execute("ALTER TABLE trace ADD COLUMN build TEXT NOT NULL DEFAULT 'unknown'")


def heal_unsequenced(db) -> None:
    """Number any trace still sitting at ingest_seq 0, at the HEAD of the order.

    DEPLOY ORDERING, made harmless. The column arrives with this file, but
    the serving plane is a long-running process: between `box-deploy.sh
    --apply` and its restart, the OLD code is still writing trace rows, and
    its INSERT names no ingest_seq, so those rows default to 0 — below every
    watermark, and therefore invisible to the forwarder forever. That is the
    same silent-loss shape this whole change exists to remove, so it is
    healed rather than documented as a caveat: every open of the store (the
    restarted plane, and the forwarder itself, which opens it each run)
    sweeps them to the head of the sequence, which is exactly what "arrived
    since the last watermark" means for them.
    """
    cur = db.cursor()
    if not cur.execute("SELECT 1 FROM trace WHERE ingest_seq=0 LIMIT 1").fetchone():
        return
    base = next_ingest_seq(cur) - 1
    cur.execute(
        "UPDATE trace SET ingest_seq=?+(SELECT n FROM (SELECT trace_id,"
        "ROW_NUMBER() OVER (ORDER BY started_ms) AS n FROM trace WHERE ingest_seq=0) o "
        "WHERE o.trace_id=trace.trace_id), updated_ms=MAX(updated_ms,ended_ms) "
        "WHERE ingest_seq=0",
        (base,),
    )


def next_ingest_seq(cur) -> int:
    """The next ingest sequence number. Derived from the table, not from a
    counter in this process: the store is opened by the serving plane and
    by every offline tool, and two processes holding private counters would
    hand out the same number twice — which is silent data loss for anything
    watermarking on it."""
    return int(cur.execute("SELECT IFNULL(MAX(ingest_seq),0)+1 FROM trace").fetchone()[0])


# ---- intake ------------------------------------------------------------

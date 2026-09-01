"""The log store's schema, and the migrations that reshape an existing one.

SPLIT OUT OF `logs.py` for the same reason `traces_schema.py` is split out of
`traces.py`, and it inherits that file's hard-won rule verbatim:

    `executescript(SCHEMA)` runs on EVERY open, and `CREATE TABLE IF NOT
    EXISTS` does not reshape a table that already exists. So SCHEMA may never
    name a column a migration adds — an index over a not-yet-added column
    takes the serving plane down on the next restart, in a crash loop, which
    is exactly what happened on 2026-09-01. Indexes over migrated columns are
    created by the migration, after the ALTER, on every path.

WHY `seq INTEGER PRIMARY KEY AUTOINCREMENT` AND NOT A PLAIN ROWID. `seq` is the
watermark the Instana forwarder resumes from. A plain rowid is "one more than
the current maximum", so deleting the newest rows (which `prune()` never does,
but a size backstop or a manual repair might) hands the same number out twice —
and a duplicate watermark is silent data loss, the exact defect the trace
store's `ingest_seq` was invented to fix. AUTOINCREMENT costs one extra table
(`sqlite_sequence`) and buys monotonicity that survives any delete.
"""

from __future__ import annotations

SCHEMA = """
CREATE TABLE IF NOT EXISTS log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  -- WHEN THE PRODUCER SAYS IT HAPPENED (its own clock) and WHEN WE SAW IT
  -- (ours). Both, always. The browser's clock is not ours and the daemon's
  -- spool can be minutes late; a store with one timestamp cannot tell a slow
  -- carrier from a slow event, which is the question a stall investigation
  -- opens with. OTel calls the pair Timestamp / ObservedTimestamp.
  ts_ms INTEGER NOT NULL, observed_ms INTEGER NOT NULL,
  -- OTel severity, both halves: the text is what a human filters on, the
  -- number is what sorts and what Instana falls back to (0307:333).
  severity TEXT NOT NULL, sev_num INTEGER NOT NULL,
  -- WHO. service is the producer plane; instance is the station, the tab or
  -- the host within it. Together they are the resource identity an OTLP
  -- export needs and the two columns every triage query groups by.
  service TEXT NOT NULL, instance TEXT NOT NULL,
  session_id TEXT NOT NULL, build TEXT NOT NULL,
  -- THE WHOLE POINT. A log row with these is joinable to a span; a log row
  -- without them is a line in a file with extra steps. Nullable because some
  -- records genuinely have no span in scope (a boot line, a timer tick), and
  -- pretending otherwise would mean inventing ids that join to nothing.
  trace_id TEXT, span_id TEXT,
  body TEXT NOT NULL, attrs TEXT,
  day TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS log_ts ON log(ts_ms DESC);
CREATE INDEX IF NOT EXISTS log_trace ON log(trace_id, ts_ms);
CREATE INDEX IF NOT EXISTS log_sev ON log(sev_num DESC, ts_ms DESC);
CREATE INDEX IF NOT EXISTS log_service ON log(service, ts_ms DESC);
CREATE INDEX IF NOT EXISTS log_session ON log(session_id, ts_ms DESC);
CREATE INDEX IF NOT EXISTS log_day ON log(day);

-- IDEMPOTENCY, which the span table gets for free and this one cannot.
-- `traces.py` inserts `ON CONFLICT(trace_id,span_id) DO NOTHING`, so a batch
-- shipped twice is stored once — and `trace-ship.py` leans on exactly that
-- when it says "a file that fails to ship is LEFT WHERE IT IS". A log record
-- has no such natural key (two identical lines a millisecond apart are two
-- real events, not a duplicate), so the BATCH carries an id — its spool
-- filename, unique by construction: millisecond stamp, pid, sequence — and a
-- second sight of that id stores nothing. Without this, the documented
-- off-box run (`--apply --keep`, or root wrote the spool and the shipper is
-- not root so the unlink is refused) duplicates every record on every tick.
CREATE TABLE IF NOT EXISTS log_batch (
  batch_id TEXT PRIMARY KEY, seen_ms INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS log_batch_seen ON log_batch(seen_ms);
"""


def migrate(db) -> None:
    """Reshape a store written by an earlier version of this file.

    There is nothing to do yet: this schema shipped whole. The function exists
    anyway, called on every open, so that the FIRST migration is an edit to a
    tested seam rather than a new call site added under time pressure — which
    is how the 2026-09-01 crash loop got written. Add columns here with an
    `ALTER`, guarded by a `PRAGMA table_info` check, and create their indexes
    here too, never in SCHEMA.
    """
    cur = db.cursor()
    have = {r[1] for r in cur.execute("PRAGMA table_info(log)")}
    if not have:  # pragma: no cover - SCHEMA ran first, so this cannot be empty
        raise RuntimeError("log table missing after SCHEMA")

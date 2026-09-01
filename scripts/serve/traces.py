"""Traces: OpenTelemetry spans, stored whole, queryable, admin-only to read.

WHAT THIS CHANGES ABOUT THE PLANE. `analytics.py` stores no identity by
construction and says so as a feature. A trace is a correlated per-session
record — that is precisely what makes drilldown work — so this file is where
that guarantee stops, deliberately and visibly rather than by drift. Three
things keep it honest:

  * READS ARE ADMIN-ONLY. The aggregates stay open on both listeners; nothing
    here is reachable without an admin session (auth/routes.py).
  * RETENTION IS DAYS, NOT YEARS. Counters keep 730 days; spans keep 14 by
    default. The durable record of this gallery is still the anonymous one, and
    the correlated one is a working set that expires.
  * THE CONTENT RULES DID NOT RELAX. No typed text, no stacks, no credential
    handles, no per-keystroke series. A span is a name, a duration, a bounded
    attribute set and its events. `exception.stacktrace` is part of the OTel
    convention and is deliberately NOT accepted here — stacks stay in
    clientlog.jsonl, which prunes itself by age.

THIS IS OTEL DATA IN A COMPACT ENCODING. The span model is OpenTelemetry's —
128-bit trace ids, 64-bit span ids, span kinds, status codes, span events,
semantic-convention attribute names. What is not OTLP is the JSON spelling: a
browser uploading `{"key":"x","value":{"stringValue":"y"}}` on pagehide pays
three to five times the bytes for no gain at the point of upload. So the wire
and the store are compact, and `otlp_export()` renders faithful OTLP/JSON
ResourceSpans for anything downstream. The mapping is 1:1 and documented at that
function; nothing is lost in either direction.

WHY SQLITE AND NOT A TIME-SERIES ENGINE. The whole point of this lab is that it
runs on one box with no external service, and a trace store for a private
gallery is thousands of spans a day, not millions. SQLite with the right indexes
answers every query this UI asks in milliseconds, and it is already how the
counters are stored.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

# W3C Trace Context: 128-bit trace id, 64-bit span id, lowercase hex.
TRACE_RE = re.compile(r"^[0-9a-f]{32}$")
SPAN_RE = re.compile(r"^[0-9a-f]{16}$")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,79}$")
SESSION_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
STATUSES = ("unset", "ok", "error")
KINDS = ("internal", "client", "server", "producer", "consumer")
CLASSES = ("human", "probe", "unknown")

#: Per-batch caps. A tab flushes every ~20 s; a session that honestly produced
#: more spans than this in that window has an instrumentation bug.
MAX_SPANS_PER_BATCH = 512
#: A body larger than this is not one tab's spans.
BODY_MAX = 512 * 1024
#: Attribute and event caps, mirroring spa/src/analytics/trace.ts.
ATTR_MAX = 24
ATTR_STR_MAX = 120
EVENT_MAX = 16
#: Days of spans kept. Deliberately short — see the module docstring.
RETENTION_DAYS = 14
#: Hard ceiling on stored spans, so a runaway client cannot fill the disk
#: between prunes. Oldest traces are dropped whole, never half a trace.
MAX_SPANS = 2_000_000

#: Attributes refused outright regardless of who sends them. `stacktrace` is the
#: one OTel convention field deliberately not accepted (see the docstring); the
#: rest are fields no browser span has any business carrying.
BANNED_ATTRS = frozenset(
    {
        "exception.stacktrace",
        "code.stacktrace",
        "url.full",
        "url.query",
        "user.email",
        "user.name",
        "enduser.id",
    }
)

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


def _day(ts_ms: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts_ms / 1000.0))


def _clean_attrs(raw) -> dict:
    """Attributes, capped and type-narrowed exactly as the tab promised."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for k, v in raw.items():
        if len(out) >= ATTR_MAX:
            break
        if not isinstance(k, str) or len(k) > 64 or k in BANNED_ATTRS:
            continue
        if isinstance(v, (bool, int, float)):
            out[k] = v
        elif isinstance(v, str):
            out[k] = v[:ATTR_STR_MAX]
    return out


def _clean_events(raw) -> list:
    if not isinstance(raw, list):
        return []
    out = []
    for e in raw[:EVENT_MAX]:
        if not isinstance(e, dict):
            continue
        name = e.get("n")
        ts = e.get("t")
        if not isinstance(name, str) or not NAME_RE.match(name):
            continue
        if not isinstance(ts, int) or ts <= 0:
            continue
        out.append({"n": name, "t": ts, "a": _clean_attrs(e.get("a"))})
    return out


class TraceStore:
    """Spans and their trace summaries. Safe from any thread."""

    def __init__(self, path: Path, read_only: bool = False):
        """`read_only` is for a REPORT, and it is not a nicety: opening the
        live store the normal way runs `executescript(SCHEMA)` and two
        migrations against the file the serving plane is writing, which is a
        lot of trust to place in a script whose whole job is to print a
        number. A read-only reader takes none of it, and cannot be the reason
        a deploy has to be rolled back."""
        self.path = Path(path)
        self._lock = threading.RLock()
        if read_only:
            self._db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, check_same_thread=False)
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(SCHEMA)
        self._migrate_ingest_order()
        self._heal_unsequenced()
        self._db.commit()

    def _migrate_ingest_order(self) -> None:
        """Give a store written before ingest ordering existed one anyway.

        `CREATE TABLE IF NOT EXISTS` does not add columns to a table that is
        already there, so a live traces.db keeps the old shape forever unless
        somebody says otherwise. The backfill numbers existing traces by
        `started_ms`, which is the order the only consumer (the Instana
        forwarder) previously walked them in — so its old `lastTraceStartedMs`
        watermark converts to a sequence watermark exactly, with neither a gap
        nor a replay of a fortnight of history on the first run afterwards.
        """
        cur = self._db.cursor()
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

    def _heal_unsequenced(self) -> None:
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
        cur = self._db.cursor()
        if not cur.execute("SELECT 1 FROM trace WHERE ingest_seq=0 LIMIT 1").fetchone():
            return
        base = self._next_ingest_seq(cur) - 1
        cur.execute(
            "UPDATE trace SET ingest_seq=?+(SELECT n FROM (SELECT trace_id,"
            "ROW_NUMBER() OVER (ORDER BY started_ms) AS n FROM trace WHERE ingest_seq=0) o "
            "WHERE o.trace_id=trace.trace_id), updated_ms=MAX(updated_ms,ended_ms) "
            "WHERE ingest_seq=0",
            (base,),
        )

    def _next_ingest_seq(self, cur) -> int:
        """The next ingest sequence number. Derived from the table, not from a
        counter in this process: the store is opened by the serving plane and
        by every offline tool, and two processes holding private counters would
        hand out the same number twice — which is silent data loss for anything
        watermarking on it."""
        return int(cur.execute("SELECT IFNULL(MAX(ingest_seq),0)+1 FROM trace").fetchone()[0])

    # ---- intake ------------------------------------------------------------

    def record(self, batch: dict) -> int:
        """Fold one tab's spans in. Returns how many were accepted.

        Spans of one trace can arrive across SEVERAL batches — a long journey
        outlives a 20-second flush — so the trace summary is recomputed from
        whatever has arrived rather than written once. A trace that is still
        open simply reads as shorter than it will finally be, which is the
        correct thing for a live view to show.
        """
        resource = batch.get("resource") or {}
        session = resource.get("session.id")
        if not isinstance(session, str) or not SESSION_RE.match(session):
            session = "unknown"
        klass = resource.get("kh.class")
        if klass not in CLASSES:
            klass = "unknown"

        spans = batch.get("spans")
        if not isinstance(spans, list):
            return 0

        taken = 0
        touched: set[str] = set()
        with self._lock:
            cur = self._db.cursor()
            for raw in spans[:MAX_SPANS_PER_BATCH]:
                if not isinstance(raw, dict):
                    continue
                trace_id, span_id = raw.get("t"), raw.get("s")
                if not isinstance(trace_id, str) or not TRACE_RE.match(trace_id):
                    continue
                if not isinstance(span_id, str) or not SPAN_RE.match(span_id):
                    continue
                parent = raw.get("p")
                if parent is not None and (not isinstance(parent, str) or not SPAN_RE.match(parent)):
                    parent = None
                name = raw.get("n")
                if not isinstance(name, str) or not NAME_RE.match(name):
                    continue
                started = raw.get("st")
                dur = raw.get("d")
                if not isinstance(started, int) or started <= 0:
                    continue
                if not isinstance(dur, int) or dur < 0:
                    continue
                hidden = raw.get("h") if isinstance(raw.get("h"), int) else 0
                status = raw.get("k") if raw.get("k") in STATUSES else "unset"
                kind = raw.get("kd") if raw.get("kd") in KINDS else "internal"
                msg = raw.get("m")
                msg = msg[:200] if isinstance(msg, str) else None
                cur.execute(
                    "INSERT INTO span(trace_id,span_id,parent_id,name,kind,started_ms,dur_ms,"
                    "hidden_ms,status,status_msg,attrs,events) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
                    "ON CONFLICT(trace_id,span_id) DO NOTHING",
                    (
                        trace_id,
                        span_id,
                        parent,
                        name,
                        kind,
                        started,
                        dur,
                        max(0, hidden),
                        status,
                        msg,
                        json.dumps(_clean_attrs(raw.get("a")), separators=(",", ":")),
                        json.dumps(_clean_events(raw.get("e")), separators=(",", ":")),
                    ),
                )
                if cur.rowcount:
                    taken += 1
                    touched.add(trace_id)
            for trace_id in touched:
                self._resummarise(cur, trace_id, session, klass, self._next_ingest_seq(cur))
            if taken:
                self._db.commit()
        return taken

    @staticmethod
    def _resummarise(cur, trace_id: str, session: str, klass: str, ingest_seq: int) -> None:
        """Rebuild one trace's summary row from the spans now present.

        The ROOT is the span with no parent; when several batches are in flight
        a trace can briefly have none, in which case the earliest span stands in
        so the trace is still listable. A trace you cannot see until it finishes
        is a trace you cannot use to watch something happening.
        """
        rows = cur.execute(
            "SELECT span_id,parent_id,name,started_ms,dur_ms,status FROM span WHERE trace_id=?",
            (trace_id,),
        ).fetchall()
        if not rows:
            return
        ids = {r[0] for r in rows}
        roots = [r for r in rows if r[1] is None or r[1] not in ids]
        root = min(roots or rows, key=lambda r: r[3])
        started = min(r[3] for r in rows)
        ended = max(r[3] + r[4] for r in rows)
        errors = sum(1 for r in rows if r[5] == "error")
        cur.execute(
            "INSERT INTO trace(trace_id,session_id,class,root_name,started_ms,ended_ms,dur_ms,"
            "span_count,error_count,status,day,ingest_seq,updated_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(trace_id) DO UPDATE SET root_name=excluded.root_name,"
            "started_ms=excluded.started_ms,ended_ms=excluded.ended_ms,dur_ms=excluded.dur_ms,"
            "span_count=excluded.span_count,error_count=excluded.error_count,status=excluded.status,"
            # A trace that just took a span is NEWLY CHANGED, so it moves to the
            # head of the ingest order — that is the whole point: a consumer
            # that walked past this trace an hour ago sees it again.
            "ingest_seq=excluded.ingest_seq,updated_ms=excluded.updated_ms,"
            # A batch that KNOWS the session names it; one that does not never
            # erases one. The serving plane (serve/tracing.py) emits spans into
            # traces the browser also contributes to, and it never learns the
            # tab's session id — `traceparent` carries a trace, not an identity.
            # Its batches therefore land as `unknown`, and they usually land
            # FIRST, because a server span ends in milliseconds while a tab
            # flushes every twenty seconds. Without this the server would win
            # the race and every browser trace would list as session `unknown`,
            # which is the one column the trace list is filtered by.
            "session_id=CASE WHEN excluded.session_id='unknown' THEN trace.session_id "
            "ELSE excluded.session_id END,"
            "class=CASE WHEN excluded.class='unknown' THEN trace.class ELSE excluded.class END",
            (
                trace_id,
                session,
                klass,
                root[2],
                started,
                ended,
                ended - started,
                len(rows),
                errors,
                root[5],
                _day(started),
                ingest_seq,
                int(time.time() * 1000),
            ),
        )

    # ---- reading -----------------------------------------------------------

    def search(self, **f) -> dict:
        """The trace LIST, filtered. Every filter is optional and ANDed."""
        where, args = ["1=1"], []
        if f.get("session"):
            where.append("session_id=?")
            args.append(f["session"])
        if f.get("name"):
            where.append("root_name=?")
            args.append(f["name"])
        if f.get("klass"):
            where.append("class=?")
            args.append(f["klass"])
        if f.get("errors_only"):
            where.append("error_count>0")
        if f.get("status"):
            where.append("status=?")
            args.append(f["status"])
        if f.get("since_ms"):
            where.append("started_ms>=?")
            args.append(int(f["since_ms"]))
        if f.get("until_ms"):
            where.append("started_ms<=?")
            args.append(int(f["until_ms"]))
        if f.get("min_dur_ms"):
            where.append("dur_ms>=?")
            args.append(int(f["min_dur_ms"]))
        # The two INGEST-ORDER filters. They are not "since_ms with better
        # units": `since_seq` asks what has CHANGED since a marker, which
        # includes a trace that started before it, and `quiet_before_ms` asks
        # what has stopped changing. Both are meaningless against started_ms,
        # and both are what a forwarder needs — see instana-forward.py.
        if f.get("since_seq"):
            where.append("ingest_seq>?")
            args.append(int(f["since_seq"]))
        if f.get("quiet_before_ms"):
            where.append("updated_ms<=?")
            args.append(int(f["quiet_before_ms"]))
        limit = max(1, min(500, int(f.get("limit") or 100)))
        offset = max(0, int(f.get("offset") or 0))
        # The UI wants newest first; a catch-up consumer wants the order things
        # were ingested in, oldest first, so that a watermark it advances can
        # never skip a row it has not seen.
        order = "ingest_seq ASC" if f.get("order") == "ingest" else "started_ms DESC"
        sql = (
            "SELECT trace_id,session_id,class,root_name,started_ms,dur_ms,span_count,"
            "error_count,status,ingest_seq,updated_ms FROM trace WHERE "  # noqa: S608 - fixed names
            + " AND ".join(where)
            + f" ORDER BY {order} LIMIT ? OFFSET ?"
        )
        cols = (
            "traceId",
            "sessionId",
            "class",
            "name",
            "startedMs",
            "durMs",
            "spanCount",
            "errorCount",
            "status",
            "ingestSeq",
            "updatedMs",
        )
        with self._lock:
            cur = self._db.cursor()
            rows = [dict(zip(cols, r)) for r in cur.execute(sql, (*args, limit, offset))]
            total = cur.execute("SELECT count(*) FROM trace WHERE " + " AND ".join(where), args).fetchone()[0]
        return {"traces": rows, "total": total, "limit": limit, "offset": offset}

    def trace(self, trace_id: str) -> dict | None:
        """One trace, with every span — what the flame graph renders."""
        if not TRACE_RE.match(trace_id or ""):
            return None
        with self._lock:
            cur = self._db.cursor()
            head = cur.execute(
                "SELECT trace_id,session_id,class,root_name,started_ms,dur_ms,span_count,"
                "error_count,status FROM trace WHERE trace_id=?",
                (trace_id,),
            ).fetchone()
            if not head:
                return None
            spans = [
                {
                    "spanId": r[0],
                    "parentId": r[1],
                    "name": r[2],
                    "kind": r[3],
                    "startedMs": r[4],
                    "durMs": r[5],
                    "hiddenMs": r[6],
                    "status": r[7],
                    "statusMessage": r[8],
                    "attributes": json.loads(r[9] or "{}"),
                    "events": json.loads(r[10] or "[]"),
                }
                for r in cur.execute(
                    "SELECT span_id,parent_id,name,kind,started_ms,dur_ms,hidden_ms,status,"
                    "status_msg,attrs,events FROM span WHERE trace_id=? ORDER BY started_ms",
                    (trace_id,),
                )
            ]
        cols = ("traceId", "sessionId", "class", "name", "startedMs", "durMs", "spanCount", "errorCount", "status")
        return {**dict(zip(cols, head)), "spans": spans}

    def facets(self, since_ms: int) -> dict:
        """The distinct values a filter UI offers, with counts. Driven by the
        DATA rather than by the catalogue: a trace name that stopped being
        emitted should drop out of the filter, and one that appeared without
        anybody declaring it is exactly what you want to notice."""
        with self._lock:
            cur = self._db.cursor()

            def group(col):
                return [
                    {"value": v, "n": n}
                    for v, n in cur.execute(
                        f"SELECT {col},count(*) FROM trace WHERE started_ms>=? "  # noqa: S608 - fixed names
                        f"GROUP BY {col} ORDER BY count(*) DESC LIMIT 100",
                        (since_ms,),
                    )
                ]

            return {"names": group("root_name"), "classes": group("class"), "statuses": group("status")}

    def orphans(self, since_ms: int, settle_ms: int = 3_600_000) -> dict:
        """How many stored spans name a parent that is not in the store.

        THE REGRESSION THIS EXISTS TO MAKE VISIBLE. A span whose `parent_id`
        names nothing renders in Instana as "the root call of the trace is
        missing or has not yet arrived", and there is no other way to notice:
        every individual span looks perfect, the request it describes
        succeeded, and only the JOIN is broken. It went unmeasured until
        2026-09-01, when a hand-written query found 42.9% of the six-hour
        window in that state. Both producers were in the browser (the tab
        emitting a `traceparent` naming a span it had already decided not to
        record, and a root span that never left because its flow never ended);
        both are fixed in `spa/src/analytics/`, and this is what proves they
        stay fixed.

        `settle_ms` excludes the RECENT edge on purpose. A parent that is
        merely still open — a flow the visitor has not finished — is a
        transient orphan that resolves the moment the root ends, so counting
        it would make the number a measure of how busy the box is right now
        rather than of whether the contract holds. An hour is far longer than
        any honest journey and far shorter than the retention window.
        """
        with self._lock:
            cur = self._db.cursor()
            rows = cur.execute(
                "SELECT s.name,count(*) FROM span s "
                "WHERE s.started_ms>=? AND s.started_ms<=? AND s.parent_id IS NOT NULL "
                "AND NOT EXISTS (SELECT 1 FROM span p WHERE p.span_id=s.parent_id) "
                "GROUP BY s.name ORDER BY count(*) DESC",
                (since_ms, int(time.time() * 1000) - settle_ms),
            ).fetchall()
            total = cur.execute(
                "SELECT count(*) FROM span WHERE started_ms>=? AND started_ms<=? AND parent_id IS NOT NULL",
                (since_ms, int(time.time() * 1000) - settle_ms),
            ).fetchone()[0]
        orphaned = sum(n for _, n in rows)
        return {
            "withParent": total,
            "orphaned": orphaned,
            "rate": (orphaned / total) if total else 0.0,
            "byName": [{"name": n, "n": c} for n, c in rows],
        }

    def prune(self, keep_days: int = RETENTION_DAYS) -> int:
        """Drop whole traces older than the window. Never half a trace: a trace
        missing its middle is worse than an absent one, because it looks
        complete."""
        cutoff = _day(int((time.time() - keep_days * 86400) * 1000))
        with self._lock:
            cur = self._db.cursor()
            old = [r[0] for r in cur.execute("SELECT trace_id FROM trace WHERE day<?", (cutoff,))]
            for tid in old:
                cur.execute("DELETE FROM span WHERE trace_id=?", (tid,))
            cur.execute("DELETE FROM trace WHERE day<?", (cutoff,))
            self._db.commit()
        return len(old)

    def close(self) -> None:
        with self._lock:
            self._db.close()

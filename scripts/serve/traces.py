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
  status TEXT NOT NULL, day TEXT NOT NULL) WITHOUT ROWID;
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

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(SCHEMA)
        self._db.commit()

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
                self._resummarise(cur, trace_id, session, klass)
            if taken:
                self._db.commit()
        return taken

    @staticmethod
    def _resummarise(cur, trace_id: str, session: str, klass: str) -> None:
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
            "span_count,error_count,status,day) VALUES(?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(trace_id) DO UPDATE SET root_name=excluded.root_name,"
            "started_ms=excluded.started_ms,ended_ms=excluded.ended_ms,dur_ms=excluded.dur_ms,"
            "span_count=excluded.span_count,error_count=excluded.error_count,status=excluded.status,"
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
        limit = max(1, min(500, int(f.get("limit") or 100)))
        offset = max(0, int(f.get("offset") or 0))
        sql = (
            "SELECT trace_id,session_id,class,root_name,started_ms,dur_ms,span_count,"
            "error_count,status FROM trace WHERE " + " AND ".join(where) + " ORDER BY started_ms DESC LIMIT ? OFFSET ?"
        )
        cols = ("traceId", "sessionId", "class", "name", "startedMs", "durMs", "spanCount", "errorCount", "status")
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

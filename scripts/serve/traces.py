"""Traces: OpenTelemetry spans, stored whole, queryable, admin-only to read.

WHAT THIS PLANE IS FOR: RICH TELEMETRY. The operator's standing instruction is
that this lab submits **as rich a record as possible** to both its own
observability plane and to Instana — stacks, URLs, the identity of the account
that hit a fault. `docs/ANALYTICS.md` §0 is the data policy this file
implements; read it before adding any restriction here. Only three reasons
refuse anything, and every one of them is named at the constant that enforces
it: SECRETS (security — a stored credential is a replayable one), VOLUME (one
box, one disk, caps sized against measured traffic), and typed keystroke
CONTENT, which is off behind `KH_TRACE_TYPED_TEXT` pending an operator answer.

Reads stay ADMIN-ONLY (auth/routes.py); the aggregates are open, this is not.

Until 2026-09-01 this file also refused `exception.stacktrace`,
`code.stacktrace`, `url.full`, `url.query`, `user.email`, `user.name` and
`enduser.id`, truncated every value at 120 characters and kept 14 days. None of
that was an operator decision — an AI session invented it, argued it in prose,
and later sessions read it back as settled policy. It is gone; do not restore it
from a code comment quoted somewhere else.

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

import traces_policy
import traces_schema

# The content policy lives in `traces_policy`, but it is re-exported here so
# callers and tests keep ONE import site for "what may enter the store". The
# split was a size-budget move, not a change of interface.
BANNED_ATTRS = traces_policy.BANNED_ATTRS
SECRET_KEY_RE = traces_policy.SECRET_KEY_RE
SECRET_PARAM_RE = traces_policy.SECRET_PARAM_RE
TYPED_TEXT_ATTRS = traces_policy.TYPED_TEXT_ATTRS
TYPED_TEXT_ALLOWED = traces_policy.TYPED_TEXT_ALLOWED
URL_VALUE_ATTRS = traces_policy.URL_VALUE_ATTRS
refused = traces_policy.refused
redact_url_value = traces_policy.redact_url_value

# W3C Trace Context: 128-bit trace id, 64-bit span id, lowercase hex.
TRACE_RE = re.compile(r"^[0-9a-f]{32}$")
SPAN_RE = re.compile(r"^[0-9a-f]{16}$")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,79}$")
SESSION_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
#: The client build id — `<branch>@<short-sha>`, optionally `-dirty`, or the
#: honest literal `unknown-build` (spa/src/analytics/build.ts). Branch names may
#: carry `/`, so the class is deliberately wider than SESSION_RE; everything
#: outside it lands as "unknown" rather than being stored.
BUILD_RE = re.compile(r"^[A-Za-z0-9._@/+-]{1,64}$")
STATUSES = ("unset", "ok", "error")
KINDS = ("internal", "client", "server", "producer", "consumer")
CLASSES = ("human", "probe", "unknown")

#: Per-batch caps. A tab flushes every ~20 s; a session that honestly produced
#: more spans than this in that window has an instrumentation bug. Raised from
#: 512 on 2026-09-01: a sampled input trace plus a page-load burst can legitimately
#: crowd one window, and a batch clipped at the cap loses the tail SILENTLY.
MAX_SPANS_PER_BATCH = 2048
#: A body larger than this is not one tab's spans. 4 MiB is 2048 spans at ~2 KiB
#: each — the worst honest case once stacks are carried (measured: the live store
#: averages 179 bytes of attributes per span, so this is ~10x headroom).
BODY_MAX = 4 * 1024 * 1024
#: Attribute and event caps, mirroring spa/src/analytics/trace.ts. Measured on
#: the live store 2026-09-01: the busiest span carries 9 attributes and no value
#: reached even the old 120-character cap, so these bound a runaway client and
#: nothing an honest one does.
ATTR_MAX = 64
ATTR_STR_MAX = 2048
#: Attributes allowed a much longer value because the whole point of them is a
#: long one. A stack truncated to 120 characters is one frame, which is worse
#: than useless: it looks like a stack and cannot be read as one.
ATTR_STR_MAX_LONG = 16384
LONG_ATTRS = frozenset(
    {
        "exception.stacktrace",
        "code.stacktrace",
        "exception.message",
        "url.full",
        "url.query",
    }
)
EVENT_MAX = 64
#: Days of spans kept. 90, raised from 14 on 2026-09-01. MEASURED cost: the live
#: store held 39_612 spans in 34 h (~28 MB including the WAL) — ~710 bytes per
#: stored span, ~20 k spans/day, ~14 MB/day. 90 days is therefore ~1.3 GB against
#: 168 GB free on /data. Retention here is a DISK question and nothing else; if
#: it ever needs lowering again, lower it with a df number, not with a principle.
RETENTION_DAYS = 90
#: Hard ceiling on stored spans, so a runaway client cannot fill the disk
#: between prunes. Oldest traces are dropped whole, never half a trace. 8 M at
#: the measured ~710 B/span is ~5.7 GB, comfortably above 90 days of honest
#: traffic and still bounded.
MAX_SPANS = 8_000_000


def _day(ts_ms: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts_ms / 1000.0))


def _clean_attrs(raw) -> dict:
    """Attributes, capped and type-narrowed exactly as the tab promised.

    The SHAPE checks here (a string key, a scalar value, a length bound) are
    validation and stay. What is NOT here any more is a judgement about which
    facts are too rich to keep — see the module docstring.
    """
    if not isinstance(raw, dict):
        return {}
    out = {}
    for k, v in raw.items():
        if len(out) >= ATTR_MAX:
            break
        if not isinstance(k, str) or len(k) > 64 or traces_policy.refused(k):
            continue
        if isinstance(v, (bool, int, float)):
            out[k] = v
        elif isinstance(v, str):
            if k in traces_policy.URL_VALUE_ATTRS:
                v = traces_policy.redact_url_value(v)
            out[k] = v[: (ATTR_STR_MAX_LONG if k in LONG_ATTRS else ATTR_STR_MAX)]
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
        self._db.executescript(traces_schema.SCHEMA)
        traces_schema.migrate_ingest_order(self._db)
        traces_schema.migrate_build(self._db)
        traces_schema.heal_unsequenced(self._db)
        self._db.commit()

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
        build = resource.get("kh.bundle")
        if not isinstance(build, str) or not BUILD_RE.match(build):
            build = "unknown"

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
                # 1024, not 200: a status message is where an error's own words
                # land, and the first 200 characters of a Rust or Python message
                # is routinely the boilerplate prefix rather than the fault.
                msg = msg[:1024] if isinstance(msg, str) else None
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
                self._resummarise(cur, trace_id, session, klass, build, traces_schema.next_ingest_seq(cur))
            if taken:
                self._db.commit()
        return taken

    @staticmethod
    def _resummarise(cur, trace_id: str, session: str, klass: str, build: str, ingest_seq: int) -> None:
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
            "span_count,error_count,status,day,ingest_seq,updated_ms,build) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
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
            "class=CASE WHEN excluded.class='unknown' THEN trace.class ELSE excluded.class END,"
            # The build id follows the SAME rule and for the same reason: the
            # serving plane's own batches carry no `kh.bundle` (a Python request
            # handler has no bundle), they land first, and without this they
            # would erase the browser's answer to the one question this column
            # exists for.
            "build=CASE WHEN excluded.build='unknown' THEN trace.build ELSE excluded.build END",
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
                build,
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
        if f.get("build"):
            where.append("build=?")
            args.append(f["build"])
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
            "error_count,status,ingest_seq,updated_ms,build FROM trace WHERE "  # noqa: S608 - fixed names
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
            "build",
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
                "error_count,status,build FROM trace WHERE trace_id=?",
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
            "build",
        )
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

            return {
                "names": group("root_name"),
                "classes": group("class"),
                "statuses": group("status"),
                # "which builds are out there right now" is a filter AND an
                # answer on its own: two builds in one window means a client is
                # running something the box no longer serves.
                "builds": group("build"),
            }

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

"""The log store: severity-bearing records, correlated to trace context.

WHAT MAKES THIS WORTH BUILDING. We had traces and metrics on two planes and no
logs on either. The value is not "log files somewhere" — it is a log record
that carries `trace_id`/`span_id`, so an operator looking at a slow
`station.restore` span can ask what the daemon printed *during that span*, and
from a stack in the browser can walk back to the request that caused it. Both
our own store and Instana join on exactly those two fields (see
`docs/lab/research/instana-logs.md` for the quoted Instana behaviour), so the
ids are the product and everything else here is plumbing around them.

POSTURE. Reads are admin-only, like the trace store's. Content rules do NOT
inherit the trace store's `BANNED_ATTRS`: a stack trace is the single most
useful thing a log record can carry and refusing it is what kept
`clientlog.jsonl` alive as a parallel store. Stacks land here as the `body` or
as `exception.stacktrace` in `attrs`, which is the attribute name Instana
documents support for (0307:337).

RETENTION is 7 days (`LOG_RETENTION_DAYS`), deliberately half the trace store's
14. A log row is roughly an order of magnitude more voluminous than a trace at
our traffic, and 7 days is also Instana's own default log retention, so the two
stores answer a question for the same window. See `docs/ANALYTICS.md` for the
measured cost per day on this box.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

import logs_schema

TRACE_RE = re.compile(r"^[0-9a-f]{32}$")
SPAN_RE = re.compile(r"^[0-9a-f]{16}$")
IDENT_RE = re.compile(r"^[A-Za-z0-9._@/+-]{1,64}$")

#: OTel SeverityNumber, the four levels we promise plus the two ends. The
#: number is what Instana falls back to when the text is unrecognised, and what
#: makes "at least WARN" a range query instead of an IN list.
SEVERITY = {"TRACE": 1, "DEBUG": 5, "INFO": 9, "WARN": 13, "ERROR": 17, "FATAL": 21}
DEFAULT_SEVERITY = "INFO"

#: A body is a message, not a payload. 8 KiB holds any stack we have ever seen
#: in clientlog.jsonl (whose own cap was 4 KiB) with room for the message above
#: it, and still bounds a runaway producer.
BODY_STR_MAX = 8 * 1024
ATTR_MAX = 32
ATTR_STR_MAX = 512
MAX_RECORDS_PER_BATCH = 1024
BODY_MAX = 1024 * 1024
RETENTION_DAYS = 7
#: How long a shipped batch's id is remembered, so a re-ship is refused rather
#: than duplicated. Longer than the shipper's retry horizon (its timer is 2
#: minutes and its spool cap is 200 files) by a wide margin, and short enough
#: that the table is a rounding error beside the records themselves.
BATCH_MEMORY_DAYS = 2
#: Runaway backstop, checked on prune. At the measured ~20 MB/day this is about
#: five times the 7-day window, so it only ever fires on a producer fault.
MAX_ROWS = 4_000_000


def _day(ts_ms: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts_ms / 1000))


def _str(v, cap: int) -> str:
    if isinstance(v, str):
        return v[:cap]
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return json.dumps(v, separators=(",", ":"))[:cap] if v is not None else ""


def _ident(v, default: str = "unknown") -> str:
    return v if isinstance(v, str) and IDENT_RE.match(v) else default


def severity_of(raw, default: str = DEFAULT_SEVERITY) -> tuple[str, int]:
    """Normalise anything a producer calls a level into (text, SeverityNumber).

    Accepts our six names, python's `logging` names (WARNING, CRITICAL), the
    browser's console names (log, warn) and a bare SeverityNumber. Anything
    else reads as the default rather than being refused: a record with an
    unrecognised level is still evidence, and dropping it to punish its label
    is how you lose the one line that mattered.
    """
    if isinstance(raw, bool):
        raw = None
    if isinstance(raw, int):
        # An OTel SeverityNumber names a BAND (17..20 are all ERROR), so the
        # text is the highest of our names at or below it, and the number is
        # kept exactly as sent rather than snapped to the band floor.
        best = "TRACE"
        for name, num in SEVERITY.items():
            if num <= raw and num >= SEVERITY[best]:
                best = name
        return (best, raw) if raw >= 1 else (default, SEVERITY[default])
    name = (raw or "").strip().upper() if isinstance(raw, str) else ""
    alias = {"WARNING": "WARN", "CRITICAL": "FATAL", "ERR": "ERROR", "LOG": "INFO", "VERBOSE": "DEBUG"}
    name = alias.get(name, name)
    if name not in SEVERITY:
        name = default
    return name, SEVERITY[name]


def _clean_attrs(raw) -> dict:
    if not isinstance(raw, dict):
        return {}
    out = {}
    for k, v in raw.items():
        if len(out) >= ATTR_MAX:
            break
        if not isinstance(k, str) or not k or len(k) > 64:
            continue
        if isinstance(v, (bool, int, float)):
            out[k] = v
        elif v is not None:
            out[k] = _str(v, ATTR_STR_MAX)
    return out


class LogStore:
    """Log records. Safe from any thread."""

    def __init__(self, path: Path, read_only: bool = False):
        """`read_only` is for a REPORT. Opening the live store the normal way
        runs DDL and migrations against the file the serving plane is writing;
        a script whose whole job is to print a number should take none of that
        risk. Same reasoning, same seam, as `traces.TraceStore`."""
        self.path = Path(path)
        self._lock = threading.RLock()
        if read_only:
            self._db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, check_same_thread=False)
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(logs_schema.SCHEMA)
        logs_schema.migrate(self._db)
        self._db.commit()

    # ---- intake --------------------------------------------------------

    def record(self, batch: dict) -> int:
        """Fold one producer's records in. Returns how many were accepted.

        The envelope mirrors `POST /traces`: a `resource` naming the producer
        once, and a list whose entries carry only what varies. Compact wire
        keys, for the same reason the span wire is compact — these travel over
        a mobile radio in a keepalive beacon.

          {"resource": {"service.name","service.instance.id","session.id",
                        "kh.bundle"},
           "logs": [{"t": ms, "sv": "ERROR", "b": body,
                     "tr": <32hex>, "sp": <16hex>, "a": {...}}]}
        """
        res = batch.get("resource") if isinstance(batch.get("resource"), dict) else {}
        service = _ident(res.get("service.name"), "unknown")
        instance = _ident(res.get("service.instance.id"), "unknown")
        session = _ident(res.get("session.id"), "unknown")
        build = _ident(res.get("kh.bundle"), "unknown")
        raw = batch.get("logs")
        if not isinstance(raw, list):
            return 0
        observed = int(time.time() * 1000)
        # A batch that names itself is stored at most once, however many times
        # the shipper offers it. Claimed BEFORE the rows are built so two
        # concurrent ships of the same file cannot both pass the check — the
        # PRIMARY KEY is the lock, not a preceding SELECT.
        batch_id = batch.get("batchId")
        if isinstance(batch_id, str) and batch_id:
            with self._lock:
                cur = self._db.cursor()
                cur.execute(
                    "INSERT OR IGNORE INTO log_batch(batch_id,seen_ms) VALUES(?,?)",
                    (batch_id[:128], observed),
                )
                self._db.commit()
                if cur.rowcount == 0:
                    return 0
        rows = []
        for rec in raw[:MAX_RECORDS_PER_BATCH]:
            if not isinstance(rec, dict):
                continue
            body = _str(rec.get("b"), BODY_STR_MAX)
            if not body:
                continue
            ts = rec.get("t")
            # A producer clock we cannot read is replaced by ours rather than
            # refused: an undateable record still belongs to this batch, and
            # `observed_ms` records that we substituted.
            ts = int(ts) if isinstance(ts, (int, float)) and not isinstance(ts, bool) and ts > 0 else observed
            sev, num = severity_of(rec.get("sv"))
            tr = rec.get("tr") if isinstance(rec.get("tr"), str) and TRACE_RE.match(rec.get("tr") or "") else None
            sp = rec.get("sp") if isinstance(rec.get("sp"), str) and SPAN_RE.match(rec.get("sp") or "") else None
            # A span id without a trace id joins to nothing and would read as
            # correlated in a UI that only checks one of them.
            if tr is None:
                sp = None
            attrs = _clean_attrs(rec.get("a"))
            rows.append(
                (
                    ts,
                    observed,
                    sev,
                    num,
                    _ident(rec.get("svc"), service),
                    _ident(rec.get("inst"), instance),
                    _ident(rec.get("sid"), session),
                    build,
                    tr,
                    sp,
                    body,
                    json.dumps(attrs, separators=(",", ":")) if attrs else None,
                    _day(ts),
                )
            )
        if not rows:
            return 0
        with self._lock:
            self._db.executemany(
                "INSERT INTO log(ts_ms,observed_ms,severity,sev_num,service,instance,session_id,"
                "build,trace_id,span_id,body,attrs,day) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rows,
            )
            self._db.commit()
        return len(rows)

    # ---- reads ---------------------------------------------------------

    def search(self, **f) -> dict:
        """Filtered page of records, newest first — or in ingest order when
        `order="ingest"`, which is what the forwarder walks."""
        where, args = [], []
        for col, key in (
            ("service", "service"),
            ("instance", "instance"),
            ("session_id", "session"),
            ("build", "build"),
            ("trace_id", "trace_id"),
            ("span_id", "span_id"),
        ):
            if f.get(key):
                where.append(f"{col}=?")
                args.append(str(f[key])[:64])
        if f.get("min_sev"):
            _, num = severity_of(f["min_sev"])
            where.append("sev_num>=?")
            args.append(num)
        for col, key, op in (("ts_ms", "since_ms", ">="), ("ts_ms", "until_ms", "<="), ("seq", "since_seq", ">")):
            if f.get(key) is not None:
                where.append(f"{col}{op}?")
                args.append(int(f[key]))
        if f.get("contains"):
            where.append("body LIKE ?")
            args.append("%" + str(f["contains"])[:120].replace("%", r"\%").replace("_", r"\_") + "%")
        sql = " WHERE " + " AND ".join(where) if where else ""
        limit = max(1, min(int(f.get("limit") or 100), 500))
        offset = max(0, int(f.get("offset") or 0))
        order = "seq ASC" if f.get("order") == "ingest" else "ts_ms DESC, seq DESC"
        with self._lock:
            cur = self._db.cursor()
            total = cur.execute(f"SELECT COUNT(*) FROM log{sql}", args).fetchone()[0]
            rows = cur.execute(
                "SELECT seq,ts_ms,observed_ms,severity,sev_num,service,instance,session_id,build,"
                f"trace_id,span_id,body,attrs FROM log{sql} ORDER BY {order} LIMIT ? OFFSET ?",
                (*args, limit, offset),
            ).fetchall()
        return {"logs": [self._row(r) for r in rows], "total": total, "limit": limit, "offset": offset}

    @staticmethod
    def _row(r) -> dict:
        return {
            "seq": r[0],
            "tsMs": r[1],
            "observedMs": r[2],
            "severity": r[3],
            "severityNumber": r[4],
            "service": r[5],
            "instance": r[6],
            "sessionId": r[7],
            "build": r[8],
            "traceId": r[9],
            "spanId": r[10],
            "body": r[11],
            "attributes": json.loads(r[12]) if r[12] else {},
        }

    def for_trace(self, trace_id: str, limit: int = 500) -> dict:
        """THE PIVOT, in one query: every record recorded under this trace, in
        time order, whichever plane emitted it. This is the read the whole
        design exists to make answerable — a span is slow, so show me what the
        three producers said while it ran."""
        if not TRACE_RE.match(trace_id or ""):
            return {"logs": [], "total": 0}
        with self._lock:
            rows = self._db.execute(
                "SELECT seq,ts_ms,observed_ms,severity,sev_num,service,instance,session_id,build,"
                "trace_id,span_id,body,attrs FROM log WHERE trace_id=? ORDER BY ts_ms, seq LIMIT ?",
                (trace_id, max(1, min(limit, 2000))),
            ).fetchall()
        return {"logs": [self._row(r) for r in rows], "total": len(rows)}

    def facets(self, since_ms: int) -> dict:
        """What is in the window, by the two columns triage starts from."""
        with self._lock:
            cur = self._db.cursor()

            def group(col):
                return [
                    {"value": v, "n": n}
                    for v, n in cur.execute(
                        f"SELECT {col},COUNT(*) FROM log WHERE ts_ms>=? GROUP BY {col} "
                        "ORDER BY COUNT(*) DESC LIMIT 100",
                        (since_ms,),
                    )
                ]

            correlated = cur.execute(
                "SELECT SUM(trace_id IS NOT NULL),COUNT(*) FROM log WHERE ts_ms>=?", (since_ms,)
            ).fetchone()
            return {
                "services": group("service"),
                "severities": group("severity"),
                "instances": group("instance"),
                # The health number for this whole feature: what fraction of
                # records can actually be pivoted from a span. A plane that
                # ships logs but correlates none of them has shipped files.
                "correlated": {"withTrace": correlated[0] or 0, "total": correlated[1] or 0},
            }

    def prune(self, keep_days: int = RETENTION_DAYS, max_rows: int = MAX_ROWS) -> int:
        """Drop records older than the window; then, only if the store is still
        over the runaway backstop, drop the oldest rows regardless of age.

        Unlike a trace, a log record is whole on its own, so there is no
        "never half of one" rule to honour here — which is why the size
        backstop can be a plain oldest-first delete.
        """
        cutoff = _day(int((time.time() - keep_days * 86400) * 1000))
        with self._lock:
            cur = self._db.cursor()
            cur.execute("DELETE FROM log WHERE day<?", (cutoff,))
            dropped = cur.rowcount
            cur.execute(
                "DELETE FROM log_batch WHERE seen_ms<?",
                (int((time.time() - BATCH_MEMORY_DAYS * 86400) * 1000),),
            )
            over = cur.execute("SELECT COUNT(*) FROM log").fetchone()[0] - max_rows
            if over > 0:
                cur.execute("DELETE FROM log WHERE seq IN (SELECT seq FROM log ORDER BY seq LIMIT ?)", (over,))
                dropped += cur.rowcount
            self._db.commit()
        return dropped

    def close(self) -> None:
        with self._lock:
            self._db.close()

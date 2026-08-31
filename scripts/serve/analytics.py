"""Feature reach, flow funnels and grouped errors: the third telemetry plane.

WHAT THIS ANSWERS THAT THE OTHER TWO DO NOT. `clientlog.jsonl` is a rolling
window of raw session evidence pruned by AGE — right for debugging one stream,
wrong for "has anybody used this since March", which needs an aggregate that
outlives the window. `usage-stats.json` counts clicks and keystrokes PER
STATION — the museum's exhibit-popularity question, which says nothing about
the software and cannot tell you the fleet table's filter row is dead code.
This file answers the third question: which parts of the CODE earn their keep.

DURABLE AGGREGATE, DISPOSABLE RAW. Counts go into SQLite keyed by day, and days
are what get pruned — so a probe reached twice in 2026 still reads 2 in 2028,
long after every raw event is gone. The raw JSONL beside it is a debugging
convenience with a short window, not the record.

NO IDENTITIES, BY CONSTRUCTION. Unlike usage.py this plane has no per-person
half at all: no user id is accepted, none is stored, and there is nothing for a
future careless render to leak. That is not squeamishness, it is what makes the
aggregate safe to keep forever — the only durable privacy guarantee is the data
you never wrote down. "Which feature is dead" never needed to know who.

THE CLASS DIMENSION IS LOAD-BEARING. This lab drives its own SPA with a fleet
of browser probes (scripts/e2e/*.mjs). They click and type for real, so every
heuristic says "human"; unclassified they would be the MAJORITY of traffic on a
63-station private gallery, and every keep/drop decision would silently be a
decision about what the test fleet exercises. Every row is therefore keyed by
class and the report defaults to `human` alone.

THESE ARE THE TAB'S OWN ACCOUNT. Same caveat as usage.py, same reason: the
report comes from the client, so it is good enough to decide what to build and
not an audit trail. The caps below bound how far one forged batch can move a
total; nothing bounds a patient liar and nothing needs to.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

# Catalogue/probe ids and flow/step names as the SPA declares them
# (spa/src/analytics/catalogue.ts). Client-supplied, therefore validated.
ID_RE = re.compile(r"^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*){0,4}$")
FP_RE = re.compile(r"^[0-9a-f]{8}$")
GRADES = ("auto", "show", "act")
OUTCOMES = ("enter", "ok", "fail")
CLASSES = ("human", "probe", "unknown")
SOURCES = ("window", "promise", "react", "fetch", "stream")
# Bucket names as spa/src/analytics/catalogue/types.ts writes them: a ladder
# EDGE rendered as text, or the overflow. Validated as a shape rather than
# against a copy of the ladder — a ladder step added on the client must be able
# to start landing without a server deploy, and an old row must keep meaning
# what it meant. That is the whole reason buckets are named by edge and not by
# index (types.ts LADDERS).
BUCKET_RE = re.compile(r"^(inf|[0-9]{1,9})$")

#: Per-batch caps. A tab flushes every ~20 s and folds repeats into counters, so
#: an honest batch is a handful of rows; these bound a forged one.
MAX_ROWS = 512
MAX_COUNT = 100_000
#: A body larger than this is not one tab's batch of counters.
BODY_MAX = 64 * 1024
#: Longest error message kept. Enough to recognise a fault, not a log line.
MESSAGE_MAX = 200
#: Days of per-day detail kept. Two years: the question this plane exists for
#: ("does anyone still use this") is asked across seasons, not across hours.
RETENTION_DAYS = 730

SCHEMA = """
CREATE TABLE IF NOT EXISTS probe (
  day TEXT NOT NULL, probe TEXT NOT NULL, grade TEXT NOT NULL,
  class TEXT NOT NULL, n INTEGER NOT NULL,
  PRIMARY KEY (day, probe, grade, class)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS flow (
  day TEXT NOT NULL, flow TEXT NOT NULL, step TEXT NOT NULL,
  outcome TEXT NOT NULL, class TEXT NOT NULL, n INTEGER NOT NULL,
  PRIMARY KEY (day, flow, step, outcome, class)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS metric (
  day TEXT NOT NULL, metric TEXT NOT NULL, bucket TEXT NOT NULL,
  class TEXT NOT NULL, n INTEGER NOT NULL,
  PRIMARY KEY (day, metric, bucket, class)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS error (
  day TEXT NOT NULL, fp TEXT NOT NULL, flow TEXT NOT NULL, step TEXT NOT NULL,
  source TEXT NOT NULL, class TEXT NOT NULL, n INTEGER NOT NULL,
  message TEXT NOT NULL,
  PRIMARY KEY (day, fp, flow, step, class)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def _day(ts: float | None = None) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts if ts is not None else time.time()))


def _one_of(value, allowed: tuple[str, ...]) -> str | None:
    return value if isinstance(value, str) and value in allowed else None


def _ident(value) -> str | None:
    return value if isinstance(value, str) and ID_RE.match(value) else None


def _count(value) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return 0
    return min(value, MAX_COUNT)


class AnalyticsStore:
    """The durable counters. Every public method is safe from any thread."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # check_same_thread=False + one lock: ThreadingHTTPServer runs a thread
        # per connection, and one connection is all this ever needs.
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(SCHEMA)
        self._db.commit()

    # ---- intake ------------------------------------------------------------

    def record(self, batch: dict) -> int:
        """Fold one tab's batch in. Returns how many rows were accepted.

        Anything unrecognised is DROPPED SILENTLY rather than rejecting the
        batch: a tab running an older bundle still has valid counts for the
        probes that did not change, and refusing the whole report would lose
        them to make a point about the one that did.
        """
        klass = _one_of(batch.get("class"), CLASSES) or "unknown"
        day = _day()
        taken = 0
        with self._lock:
            cur = self._db.cursor()
            taken += self._fold_probes(cur, day, klass, batch.get("probes"))
            taken += self._fold_flows(cur, day, klass, batch.get("flows"))
            taken += self._fold_metrics(cur, day, klass, batch.get("metrics"))
            taken += self._fold_errors(cur, day, klass, batch.get("errors"))
            if taken:
                cur.execute(
                    "INSERT INTO meta(key,value) VALUES('lastAt',?) "
                    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),),
                )
                self._db.commit()
        return taken

    def _fold_probes(self, cur, day: str, klass: str, rows) -> int:
        taken = 0
        for row in _rows(rows):
            probe = _ident(row.get("id"))
            grade = _one_of(row.get("grade"), GRADES)
            n = _count(row.get("n"))
            if not probe or not grade or not n:
                continue
            cur.execute(
                "INSERT INTO probe(day,probe,grade,class,n) VALUES(?,?,?,?,?) "
                "ON CONFLICT(day,probe,grade,class) DO UPDATE SET n=n+excluded.n",
                (day, probe, grade, klass, n),
            )
            taken += 1
        return taken

    def _fold_flows(self, cur, day: str, klass: str, rows) -> int:
        taken = 0
        for row in _rows(rows):
            flow = _ident(row.get("flow"))
            step = _ident(row.get("step"))
            outcome = _one_of(row.get("outcome"), OUTCOMES)
            n = _count(row.get("n"))
            if not flow or not step or not outcome or not n:
                continue
            cur.execute(
                "INSERT INTO flow(day,flow,step,outcome,class,n) VALUES(?,?,?,?,?,?) "
                "ON CONFLICT(day,flow,step,outcome,class) DO UPDATE SET n=n+excluded.n",
                (day, flow, step, outcome, klass, n),
            )
            taken += 1
        return taken

    def _fold_metrics(self, cur, day: str, klass: str, rows) -> int:
        """Fold one batch of metric buckets in.

        The server never sees a raw sample — bucketing happens in the tab
        (spa/src/analytics/metrics.ts) so a behavioural timing trace never
        reaches a store that is kept for years. This end therefore validates a
        bucket NAME and cannot re-derive it; that is the trade, and it is the
        right way round.
        """
        taken = 0
        for row in _rows(rows):
            metric = _ident(row.get("id"))
            bucket = row.get("bucket")
            n = _count(row.get("n"))
            if not metric or not isinstance(bucket, str) or not BUCKET_RE.match(bucket) or not n:
                continue
            cur.execute(
                "INSERT INTO metric(day,metric,bucket,class,n) VALUES(?,?,?,?,?) "
                "ON CONFLICT(day,metric,bucket,class) DO UPDATE SET n=n+excluded.n",
                (day, metric, bucket, klass, n),
            )
            taken += 1
        return taken

    def _fold_errors(self, cur, day: str, klass: str, rows) -> int:
        taken = 0
        for row in _rows(rows):
            fp = row.get("fp")
            n = _count(row.get("n"))
            if not isinstance(fp, str) or not FP_RE.match(fp) or not n:
                continue
            source = _one_of(row.get("source"), SOURCES) or "window"
            # An error outside every flow is attributed to the empty flow rather
            # than dropped: "faults nobody's flow owns" is itself a finding, and
            # it is where an unattributed crash on the landing page lands.
            flow = _ident(row.get("flow")) or ""
            step = _ident(row.get("step")) or ""
            message = str(row.get("message") or "")[:MESSAGE_MAX]
            cur.execute(
                "INSERT INTO error(day,fp,flow,step,source,class,n,message) VALUES(?,?,?,?,?,?,?,?) "
                "ON CONFLICT(day,fp,flow,step,class) DO UPDATE SET n=n+excluded.n",
                (day, fp, flow, step, source, klass, n, message),
            )
            taken += 1
        return taken

    # ---- reading -----------------------------------------------------------

    def report(self, days: int = 30, klass: str = "human") -> dict:
        """Everything the reach report needs, for one class over one window.

        The catalogue is NOT joined here — the server has no business reading
        the SPA's source of truth. `scripts/dev/reach-report.py` does the join,
        which is what turns "these probes reported" into "these probes did not".
        """
        since = _day(time.time() - max(1, days) * 86400)
        with self._lock:
            cur = self._db.cursor()
            probes: dict[str, dict[str, int]] = {}
            for probe, grade, n in cur.execute(
                "SELECT probe,grade,SUM(n) FROM probe WHERE day>=? AND class=? GROUP BY probe,grade",
                (since, klass),
            ):
                probes.setdefault(probe, {})[grade] = n
            flows: dict[str, dict[str, dict[str, int]]] = {}
            for flow, step, outcome, n in cur.execute(
                "SELECT flow,step,outcome,SUM(n) FROM flow WHERE day>=? AND class=? GROUP BY flow,step,outcome",
                (since, klass),
            ):
                flows.setdefault(flow, {}).setdefault(step, {})[outcome] = n
            errors = [
                {"fp": fp, "flow": flow, "step": step, "source": src, "n": n, "message": msg}
                for fp, flow, step, src, n, msg in cur.execute(
                    "SELECT fp,flow,step,source,SUM(n),MAX(message) FROM error "
                    "WHERE day>=? AND class=? GROUP BY fp,flow,step,source ORDER BY SUM(n) DESC LIMIT 200",
                    (since, klass),
                )
            ]
            metrics: dict[str, dict[str, int]] = {}
            for metric, bucket, n in cur.execute(
                "SELECT metric,bucket,SUM(n) FROM metric WHERE day>=? AND class=? GROUP BY metric,bucket",
                (since, klass),
            ):
                metrics.setdefault(metric, {})[bucket] = n
            last = cur.execute("SELECT value FROM meta WHERE key='lastAt'").fetchone()
        return {
            "window": {"days": days, "since": since, "class": klass},
            "lastAt": last[0] if last else None,
            "probes": probes,
            "flows": flows,
            "metrics": metrics,
            "errors": errors,
        }

    def prune(self, keep_days: int = RETENTION_DAYS) -> int:
        """Drop day-buckets older than the window. Returns rows removed."""
        cutoff = _day(time.time() - keep_days * 86400)
        with self._lock:
            cur = self._db.cursor()
            removed = 0
            for table in ("probe", "flow", "metric", "error"):
                cur.execute(f"DELETE FROM {table} WHERE day<?", (cutoff,))  # noqa: S608 - fixed names
                removed += cur.rowcount
            self._db.commit()
        return removed

    def close(self) -> None:
        with self._lock:
            self._db.close()


def _rows(value) -> list:
    """The first MAX_ROWS well-shaped entries of a client-supplied list."""
    if not isinstance(value, list):
        return []
    return [r for r in value[:MAX_ROWS] if isinstance(r, dict)]


# ---- HTTP glue -------------------------------------------------------------
# Kept beside the store for the same reason clientlog's and usage's are: the
# route is two lines of framing around one store call.


def handle_post(handler, store: AnalyticsStore) -> None:
    """POST /analytics — one tab's batch of counters."""
    from static_files import MIME

    obj, err = handler._read_json_body(BODY_MAX)
    if err:
        return handler._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
    if not isinstance(obj, dict):
        return handler._send(400, json.dumps({"error": "expected an object"}), MIME[".json"], cache=False)
    taken = store.record(obj)
    return handler._send(200, json.dumps({"ok": True, "rows": taken}), MIME[".json"], cache=False)


def serve_report(handler, store: AnalyticsStore, query: dict) -> None:
    """GET /analytics/report.json?days=30&class=human — the aggregate.

    Open to any session, like every other lab document: it carries feature
    names and counts and no identities at all, so there is nothing here an
    admin-only route would be protecting.
    """
    from static_files import MIME

    try:
        days = max(1, min(3650, int((query.get("days") or ["30"])[0])))
    except (TypeError, ValueError):
        days = 30
    klass = _one_of((query.get("class") or ["human"])[0], CLASSES) or "human"
    return handler._send(200, json.dumps(store.report(days, klass)), MIME[".json"], cache=False)

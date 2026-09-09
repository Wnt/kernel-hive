"""The vitals store: continuous stream health as a time series.

WHAT THIS IS FOR. Video and audio are CONTINUOUS. "Did the stream work" is not
a question about a call or an event, so neither the trace lane nor the log lane
answers it, and `analytics.db` cannot either — its counters have no per-sample
timestamp, only a day bucket, which is honest for "how many restores yesterday"
and a lie at any finer resolution. This store holds timestamped samples at
sub-minute resolution, and it is the thing that survives dropping Instana: an
OTLP export is a CONSUMER of it (`vitals_otlp.py`), never its purpose.

WHAT IT IS NOT FOR. Discrete degradations — a stall, a decode error, an ABR
downshift, blocked audio — are EVENTS, and they belong on the log and event
planes. What lives here is the CONTINUOUS number a threshold on such an event
would fire against, which is why `frames_dropped` is a cumulative counter here
and "the stream stalled" is not a row here at all.

POSTURE, inherited wholesale from the log lane one file over. INGEST IS OPEN
(`POST /vitals`, origin-checked on the public listener): a tab whose stream is
bad has to be able to say so without holding an admin session, and that is the
tab whose numbers matter most. READS ARE ADMIN-ONLY (`/auth/vitals/*`,
`vitals_read.py`): a sample names a station and a session.

RETENTION IS 30 DAYS (`RETENTION_DAYS`), the LONGEST window in the plane, and
that is deliberate rather than careless. The instinct with sub-minute data is
to keep a tight window because it is dense — but density is a reason to size
the DISK, not to throw the data away, and this box has ~166 GB free against a
measured worst case of a few hundred MB for the whole window (the arithmetic is
in `docs/ANALYTICS.md` §8.6). A month means "has this station always been like
this, or did it change?" is answerable, which is the question a one-visitor
gallery actually asks; three days would have answered only "is it bad now",
which the live read already answers for free.

The RUNAWAY BACKSTOP below is what handles the case retention used to: a
producer stuck in a flush loop is a fault, and a fault gets a ceiling. A
budget is not the same thing as a ceiling and should not be spelt as one.

There is NO DOWNSAMPLING. A rollup is a second schema, a second prune and a
second thing to be wrong; at this volume the full-resolution window is small
enough that buying one would be paying for a problem we do not have. If the
gallery ever has real traffic, the honest first move is a bigger disk and the
second is a rollup — in that order.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

import vitals_schema
from vitals_schema import COLUMNS

IDENT_RE = re.compile(r"^[A-Za-z0-9._@/+-]{1,64}$")

#: Samples one batch may carry. A client sampling at 1 Hz and flushing on a 20 s
#: timer offers 20; a pagehide flush after a backgrounded stretch offers up to
#: its whole 600-deep queue. 1024 clears that with room and still bounds a
#: runaway producer.
MAX_SAMPLES_PER_BATCH = 1024
BODY_MAX = 512 * 1024
RETENTION_DAYS = 30
#: Runaway backstop, checked on prune. NOT a capacity budget — a ceiling on a
#: FAULT. Legitimate saturation (every one of the 71 stations streaming
#: continuously for the whole 30-day window at 1 Hz) would be 184 M rows and is
#: not a thing that can happen in a gallery with one visitor; a client stuck in
#: a flush loop can produce arbitrarily many in an afternoon, and that is what
#: this stops. Set well above any plausible real load precisely so that hitting
#: it is diagnostic rather than routine.
MAX_ROWS = 20_000_000
#: How long a shipped batch's id is remembered so a re-ship stores nothing.
#: Same mechanism, same reason, as `logs.BATCH_MEMORY_DAYS`.
BATCH_MEMORY_DAYS = 1
#: Sane bounds for a stored value. A vital is a physical measurement, so an
#: infinity or a 1e300 is a producer bug, and sqlite would store it happily and
#: hand it to a chart that then has no y-axis. Clamped rather than refused: the
#: rest of the sample is still evidence.
VALUE_MIN, VALUE_MAX = -1e9, 1e9


def _day(ts_ms: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(ts_ms / 1000))


def _ident(v, default: str = "unknown") -> str:
    return v if isinstance(v, str) and IDENT_RE.match(v) else default


def _num(v):
    """A finite float, or None. Booleans are NOT numbers here: `True` for a
    gauge would store 1.0 and read as a measurement rather than as a flag the
    producer forgot to convert."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    f = float(v)
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return max(VALUE_MIN, min(VALUE_MAX, f))


class VitalsStore:
    """Timestamped stream-health samples. Safe from any thread."""

    def __init__(self, path: Path, read_only: bool = False):
        """`read_only` is for a REPORT or for the forwarder — same seam, same
        reason, as `traces.TraceStore` and `logs.LogStore`: opening the live
        store the normal way runs DDL and a migration against the file the
        serving plane is writing, and a script whose whole job is to read a
        number should take none of that risk."""
        self.path = Path(path)
        self._lock = threading.RLock()
        if read_only:
            self._db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, check_same_thread=False)
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(vitals_schema.SCHEMA)
        vitals_schema.migrate(self._db)
        self._db.commit()

    # ---- intake --------------------------------------------------------

    def record(self, batch: dict) -> int:
        """Fold one producer's samples in. Returns how many were accepted.

        The envelope mirrors `POST /logs` and `POST /traces` — a `resource`
        naming the producer once, and a list whose entries carry only what
        varies — because a third envelope shape for a third pillar is three
        parsers to keep in step for no gain:

          {"resource": {"service.instance.id": <station>, "session.id": ...,
                        "kh.bundle": ..., "kh.source": "spa"|"daemon"},
           "batchId": "...",
           "samples": [{"t": <ms>, "v": {"fps": 30, "rtt_ms": 12.4, ...}}]}

        A key in `v` that is not in the catalogue is IGNORED rather than
        refused. A client that shipped early, or a build that knows a vital
        this deploy does not, still lands everything it and we agree on — the
        alternative loses the whole sample to punish one field.
        """
        res = batch.get("resource") if isinstance(batch.get("resource"), dict) else {}
        station = _ident(res.get("service.instance.id"))
        session = _ident(res.get("session.id"))
        build = _ident(res.get("kh.bundle"))
        source = _ident(res.get("kh.source"), "spa")
        raw = batch.get("samples")
        if not isinstance(raw, list):
            return 0
        observed = int(time.time() * 1000)
        # Claimed BEFORE any row is built, so two concurrent ships of the same
        # spool file cannot both pass: the PRIMARY KEY is the lock, never a
        # preceding SELECT. Straight out of `logs.LogStore.record`.
        if not self._claim_batch(batch.get("batchId"), observed):
            return 0
        rows = []
        for rec in raw[:MAX_SAMPLES_PER_BATCH]:
            if not isinstance(rec, dict):
                continue
            vals = rec.get("v")
            if not isinstance(vals, dict):
                continue
            cells = [_num(vals.get(c)) for c in COLUMNS]
            # A sample with no readable value at all is not a sample. Storing
            # it would put a row on every chart's x-axis carrying nothing,
            # which reads as "we measured, and it was nothing".
            if all(c is None for c in cells):
                continue
            ts = rec.get("t")
            ts = int(ts) if isinstance(ts, (int, float)) and not isinstance(ts, bool) and ts > 0 else observed
            rows.append(
                (
                    ts,
                    observed,
                    _ident(rec.get("st"), station),
                    _ident(rec.get("sid"), session),
                    source,
                    build,
                    _day(ts),
                    *cells,
                )
            )
        if not rows:
            return 0
        cols = "ts_ms,observed_ms,station,session_id,source,build,day," + ",".join(COLUMNS)
        marks = ",".join("?" * (7 + len(COLUMNS)))
        with self._lock:
            self._db.executemany(f"INSERT INTO vital({cols}) VALUES({marks})", rows)
            self._db.commit()
        return len(rows)

    def _claim_batch(self, batch_id, observed: int) -> bool:
        """True when this batch has not been seen. An unnamed batch always
        passes — idempotency is a property a producer opts into by naming
        itself, and the browser's live sink genuinely has nothing to dedupe."""
        if not isinstance(batch_id, str) or not batch_id:
            return True
        with self._lock:
            cur = self._db.cursor()
            cur.execute("INSERT OR IGNORE INTO vital_batch(batch_id,seen_ms) VALUES(?,?)", (batch_id[:128], observed))
            self._db.commit()
            return cur.rowcount > 0

    # ---- reads ---------------------------------------------------------

    def series(self, **f) -> dict:
        """A page of samples, oldest first — which is the order a CHART wants,
        and the opposite of what the log and trace lanes default to. Those are
        read as "the most recent N"; a time series is read as a line, and a
        reader that has to reverse every page before plotting it will one day
        forget to.

        `order="ingest"` walks by `seq` instead, which is what the forwarder's
        watermark needs.
        """
        where, args = [], []
        for col, key in (("station", "station"), ("session_id", "session"), ("source", "source"), ("build", "build")):
            if f.get(key):
                where.append(f"{col}=?")
                args.append(str(f[key])[:64])
        for col, key, op in (("ts_ms", "since_ms", ">="), ("ts_ms", "until_ms", "<="), ("seq", "since_seq", ">")):
            if f.get(key) is not None:
                where.append(f"{col}{op}?")
                args.append(int(f[key]))
        sql = " WHERE " + " AND ".join(where) if where else ""
        limit = max(1, min(int(f.get("limit") or 500), 5000))
        offset = max(0, int(f.get("offset") or 0))
        order = "seq ASC" if f.get("order") == "ingest" else "ts_ms ASC, seq ASC"
        cols = "seq,ts_ms,observed_ms,station,session_id,source,build," + ",".join(COLUMNS)
        with self._lock:
            cur = self._db.cursor()
            total = cur.execute(f"SELECT COUNT(*) FROM vital{sql}", args).fetchone()[0]
            rows = cur.execute(
                f"SELECT {cols} FROM vital{sql} ORDER BY {order} LIMIT ? OFFSET ?", (*args, limit, offset)
            ).fetchall()
        return {"samples": [self._row(r) for r in rows], "total": total, "limit": limit, "offset": offset}

    @staticmethod
    def _row(r) -> dict:
        """One stored row as JSON. NULL VITALS ARE OMITTED, not sent as null:
        most of every row is the other producer's columns, and a wire that
        spelled all of them out would be mostly the word "null"."""
        return {
            "seq": r[0],
            "tsMs": r[1],
            "observedMs": r[2],
            "station": r[3],
            "sessionId": r[4],
            "source": r[5],
            "build": r[6],
            "v": {c: r[7 + i] for i, c in enumerate(COLUMNS) if r[7 + i] is not None},
        }

    def live(self, within_ms: int = 120_000) -> dict:
        """THE OPERATOR'S FIRST READ: the newest sample for every station that
        has produced one recently, one row each. It answers "is anything
        streaming right now, and is it healthy" without paging a series per
        station, and it is the read the /admin surface opens with.

        `within_ms` is what "recently" means. Default two minutes: long enough
        that a client on a 60 s flush timer is never missed, short enough that
        a station nobody is on drops off the list rather than showing a stale
        line as if it were current.
        """
        cutoff = int(time.time() * 1000) - max(1000, within_ms)
        cols = "seq,ts_ms,observed_ms,station,session_id,source,build," + ",".join(COLUMNS)
        with self._lock:
            rows = self._db.execute(
                f"SELECT {cols} FROM vital WHERE seq IN "
                "(SELECT MAX(seq) FROM vital WHERE ts_ms>=? GROUP BY station,session_id,source) "
                "ORDER BY station,session_id",
                (cutoff,),
            ).fetchall()
        return {"live": [self._row(r) for r in rows], "withinMs": within_ms}

    def facets(self, since_ms: int) -> dict:
        """What is in the window, and — the number this lane is judged on — how
        much wall-clock time is actually COVERED by samples. A vitals store
        that holds a thousand rows from one 40-second session is not
        monitoring; it is a souvenir."""
        with self._lock:
            cur = self._db.cursor()

            def group(col):
                return [
                    {"value": v, "n": n}
                    for v, n in cur.execute(
                        f"SELECT {col},COUNT(*) FROM vital WHERE ts_ms>=? "
                        f"GROUP BY {col} ORDER BY COUNT(*) DESC LIMIT 100",
                        (since_ms,),
                    )
                ]

            span = cur.execute(
                "SELECT COUNT(*),MIN(ts_ms),MAX(ts_ms),COUNT(DISTINCT session_id) FROM vital WHERE ts_ms>=?",
                (since_ms,),
            ).fetchone()
        return {
            "stations": group("station"),
            "sources": group("source"),
            "total": span[0] or 0,
            "firstMs": span[1],
            "lastMs": span[2],
            "sessions": span[3] or 0,
            "catalogue": [{"column": c, "metric": m, "unit": u, "kind": k} for c, m, u, k in vitals_schema.CATALOGUE],
        }

    def prune(self, keep_days: int = RETENTION_DAYS, max_rows: int = MAX_ROWS) -> int:
        """Drop samples older than the window; then, only if still over the
        runaway backstop, drop the oldest regardless of age. A sample is whole
        on its own, like a log record and unlike a trace, so the size backstop
        can be a plain oldest-first delete."""
        cutoff = _day(int((time.time() - keep_days * 86400) * 1000))
        with self._lock:
            cur = self._db.cursor()
            cur.execute("DELETE FROM vital WHERE day<?", (cutoff,))
            dropped = cur.rowcount
            cur.execute(
                "DELETE FROM vital_batch WHERE seen_ms<?", (int((time.time() - BATCH_MEMORY_DAYS * 86400) * 1000),)
            )
            over = cur.execute("SELECT COUNT(*) FROM vital").fetchone()[0] - max_rows
            if over > 0:
                cur.execute("DELETE FROM vital WHERE seq IN (SELECT seq FROM vital ORDER BY seq LIMIT ?)", (over,))
                dropped += cur.rowcount
            self._db.commit()
        return dropped

    def close(self) -> None:
        with self._lock:
            self._db.close()


def export_json(found: dict) -> str:
    return json.dumps(found, separators=(",", ":"))

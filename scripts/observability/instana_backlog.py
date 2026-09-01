"""The forwarder's BACKLOG: which traces have not reached Instana yet.

Split out of `instana-forward.py` for the same reason `instana_destination.py`
was — it is the part with a correctness argument in it, and it is unit-testable
against a fixture store with no tenant, no socket and no credential
(`scripts/test_instana_forward.py`). The rest of the forwarder is transport.

The whole of that argument is in `pending_traces()`. Read it before changing the
watermark, the quiet window, or the order these are walked in; each of the three
is load-bearing for a data-loss bug that ran undetected until 2026-09-01.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

#: How long a trace must go untouched before it is shipped.
#:
#: THIS NUMBER IS A FUNCTION OF `FLUSH_MS` IN spa/src/analytics/sink.ts (20 s),
#: and the two must not drift apart silently: scripts/test_instana_forward.py
#: reads that constant out of the TypeScript and fails if this one is not
#: comfortably larger. It is deliberately not "20_000 + a bit": a flush that
#: coincides with a slow upload, a retry, or a tab that was backgrounded arrives
#: later than one interval, so the margin is generous. It costs staleness, not
#: correctness — see the watermark comment below for why nothing is lost when
#: the guess is wrong.
QUIET_MS = 90_000


def read_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def write_state(path: Path, state: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=2))
        tmp.replace(path)
    except OSError as e:
        sys.stderr.write(f"instana-forward: cannot persist watermark ({e}) — next run may resend\n")


def pending_traces(cfg, after_seq: int, limit: int, now_ms: int | None = None) -> tuple[list[dict], int]:
    """Traces changed since the watermark and quiet since, in INGEST order.

    THE WATERMARK IS INGEST SEQUENCE, NOT TRACE START TIME, and that is the
    whole of the fix for a data-loss bug that ran until 2026-09-01.

    A trace has two halves that arrive at wildly different times. The serving
    plane writes its `server` span within milliseconds (`scripts/serve/
    tracing.py`); the browser buffers the SAME trace's spans and flushes them on
    a 20-second interval or on pagehide (`spa/src/analytics/sink.ts`). The old
    watermark was `max(started_ms)` of the batch just shipped, and a trace's
    `started_ms` never moves — so a run that landed in that window shipped the
    server half, advanced the watermark PAST that trace's start time, and the
    browser half, arriving later but stamped EARLIER, was never selected again
    by any future run. Nothing rescans. Those spans were lost for good, which is
    exactly what "orphaned calls with no parent" looks like from inside Instana.

    Two independent properties fix it, and both are here on purpose:

    * `since_seq` — CORRECTNESS. The store bumps a trace's `ingest_seq` to a new
      high-water value every time a span lands in it, so a late arrival pulls
      its whole trace back in front of the watermark. There is no window a span
      can arrive in and be missed, however late it is: not a 20-second flush,
      not a pagehide an hour later, not a daemon batch that `trace-ship.py`
      carried the next morning.
    * `quiet_before_ms` — QUIETNESS, i.e. fewer duplicates. Shipping a trace the
      moment its first span lands would ship most traces two or three times, so
      a trace is held until it has taken nothing new for QUIET_MS. This is an
      optimisation and NOT the correctness property: if the quiet window is too
      short, the effect is a duplicate send, never a loss.

    WHY THE ALTERNATIVES LOST. A grace window ALONE (ship a trace once it is
    older than the client flush interval) is not sound here, because a trace is
    not bounded by one flush: a tab open on a station contributes to the same
    trace for as long as the visitor stays, so the only safe grace period is
    "longer than the longest visit", which is a guess that fails silently and
    loses data when it is wrong. Rescanning a bounded recent window alone has
    the same shape — it is a grace window with extra steps, and it also loses
    anything older than the window. Sequence watermarking has no such guess in
    it, and the quiet window then only has to be good enough to keep duplicates
    down, where being wrong is cheap.

    IS RE-SENDING SAFE ON INSTANA'S SIDE? Re-sending is certainly safe on ours:
    `traces.py` inserts `ON CONFLICT(trace_id,span_id) DO NOTHING`. Instana's
    OTLP acceptor is a different question and we do not control it, so this does
    not assume it dedupes. OTLP has no idempotency key and IBM documents no
    de-duplication of re-sent spans; the honest expectation is that a span sent
    twice is a span Instana may count twice, inflating call counts and skewing
    the latency aggregates for that endpoint. That is why the quiet window
    exists at all — it makes a duplicate the rare exception (a trace still
    taking spans QUIET_MS after its previous one) rather than the common case,
    and duplicating a handful of long-visit traces is a far smaller error than
    silently dropping every browser half. If duplicates ever show up as a real
    distortion in the tenant, the next step is a per-span sent ledger, not a
    longer guess; it is not worth its complexity today, at this volume.

    Returns the traces and the highest ingest sequence in them — the caller
    must persist THAT and not `max(startedMs)`, which is the bug this docstring
    is about.
    """
    import traces  # imported here: the caller owns the sys.path that finds scripts/serve

    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    store = traces.TraceStore(cfg.traces_db)
    try:
        rows = []
        for klass in cfg.classes:
            rows += store.search(
                klass=klass,
                since_seq=after_seq,
                quiet_before_ms=now_ms - QUIET_MS,
                order="ingest",
                limit=limit,
            )["traces"]
        # One store, several class queries: re-sort into a single ingest order
        # and cut, so the watermark advanced below covers a CONTIGUOUS prefix of
        # it. Advancing past a row of another class that this batch dropped on
        # the limit is the same skip bug in a different coat.
        rows.sort(key=lambda r: r["ingestSeq"])
        rows = rows[:limit]
        batch = [t for t in (store.trace(r["traceId"]) for r in rows) if t]
        return batch, max((r["ingestSeq"] for r in rows), default=after_seq)
    finally:
        store.close()


def resume_seq(cfg, state: dict) -> int:
    """The ingest watermark to resume from, including from a legacy state file.

    A store written before ingest ordering is backfilled in `started_ms` order
    (`TraceStore._migrate_ingest_order`), so the old `lastTraceStartedMs` maps
    onto a sequence exactly: everything at or before that start time was sent,
    everything after was not. Doing this conversion once, here, is why arming
    the timer does not replay a fortnight of history into the tenant.
    """
    if state.get("lastIngestSeq") is not None:
        return int(state["lastIngestSeq"])
    legacy = int(state.get("lastTraceStartedMs") or 0)
    if not legacy:
        return 0
    db = sqlite3.connect(f"file:{cfg.traces_db}?mode=ro", uri=True)
    try:
        row = db.execute("SELECT IFNULL(MAX(ingest_seq),0) FROM trace WHERE started_ms<=?", (legacy,)).fetchone()
    except sqlite3.Error:
        return 0
    finally:
        db.close()
    return int(row[0] or 0)

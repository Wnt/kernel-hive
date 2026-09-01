#!/usr/bin/env python3
"""The VITALS leg of the Instana forwarder — `POST /v1/metrics`, OTLP/JSON.

SPLIT OUT OF `instana-forward.py` for the reason `instana_logs.py` was: that
file is at its line budget and a fourth signal does not fit in it. It takes the
forwarder's `Config`, `post()` and destination as ARGUMENTS rather than
importing them, so this module has no cycle with the script that owns them and
can be driven against a fixture store with no socket and no tenant.

WHY THIS IS A SEPARATE LEG AND NOT A SECOND CALL INSIDE `forward_metrics`.
`instana_metrics.py` projects `analytics.db`'s bucketed counters, which have NO
per-sample timestamp — only a day bucket, as its own docstring says. That lane
is honest at day resolution and would be a lie at any finer one, so it emits one
histogram point per day. This lane is the opposite in every dimension: real
samples, real timestamps, sub-minute. Merging them would force one cadence and
one watermark on two things that share only a URL. They are both correct; they
are not the same lane, and `docs/ANALYTICS.md` says which question goes to which.

============================================================================
THE CADENCE ARGUMENT — the single most important thing in this file
============================================================================

    "The metric timestamp that is recorded for OpenTelemetry metrics is the
     timestamp of ingestion into Instana."   — 0307-opentelemetry-signals.md:98

Not our `timeUnixNano`. Instana stamps a metric point when it ARRIVES. Every
consequence below follows from that one sentence.

THE EXISTING FIVE-MINUTE FORWARDER CANNOT CARRY THIS. `kh-instana-forward.timer`
fires every 5 minutes. At a 5-second client sample interval a run would hand
Instana 60 consecutive samples per stream — and all 60 would be stamped with the
SAME ingest moment. Sixty distinct measurements of a changing stream would land
as sixty points at one instant: not merely imprecise, actively wrong, because a
chart would draw a vertical line every five minutes and nothing in between. The
resolution would not be degraded; it would be destroyed, and destroyed
invisibly, since the payload we sent would look perfect in `--dry-run`.

SO THIS LEG RUNS ON ITS OWN TIMER, at `VITALS_INTERVAL_S` = 10 seconds
(`kh-instana-vitals.timer`). Ten and not five, and not sixty:

  * Instana's own floor is 10 s. Infrastructure metrics on a custom dashboard
    have "10 second resolution" (0261:178-181) and the Saturation SLO blueprint
    samples at 10 s (0262:415-424). Forwarding faster than 10 s buys resolution
    the backend will not show. Ten seconds is the finest cadence that is not
    wasted.
  * Sixty seconds would collapse a minute of stream history into one instant,
    which is the five-minute problem in miniature.
  * The cost of a 10 s tick is bounded and measured: see the volume note below.

WHAT A RUN SENDS, AND WHY IT IS NOT THE WHOLE BACKLOG. `LATEST_ONLY` is the
default and it is the honest one. Because the ingest timestamp is Instana's, the
most a run can truthfully say is "this is the value NOW", so a run ships ONE
point per (station, session, metric): the newest sample in the store. The older
samples in that tick's window are not lost — they are in OUR store at full
resolution, with the producer's own clock, which is the entire reason the store
exists and is where the design puts its trust. Shipping them too would mean
sending several values that Instana would stamp identically and then have to
pick between; it would inflate the point count by the sample:tick ratio for
nothing.

    Set `INSTANA_VITALS_ALL=1` to ship every unsent sample instead. It exists
    because a backfill after an outage is a real need, and because the choice
    should be visible rather than hardcoded. It is off by default, and what it
    costs is stated rather than discovered: the backfilled points arrive
    stamped NOW, so they land as a spike of duplicates at the current instant,
    not as history. Use it to prove a payload, never to repair a chart.

WHAT THE WATERMARK MEANS HERE, and it is NOT what it means on the other two
legs. There it guarantees no-loss: every span, every log record, exactly once.
Here, in the default mode, it only records how far this leg has looked — samples
between two ticks are deliberately skipped, because the backend cannot represent
them. Calling that "loss" would be a category error, but calling the watermark a
no-loss guarantee would be a lie, so it is called what it is:
`lastVitalsSeenSeq`, not `lastVitalsSeq`.

VOLUME — RECORDED AS A FACT, NOT USED AS A CONSTRAINT. The gallery has one
visitor, so nothing here is sized against a capacity budget; the number is
written down for whoever needs it the day that changes. Measured from the live
`clientlog.jsonl`: 10,818 stats samples over 14 days, busiest day 2,262, peak
concurrency FOUR sessions in any one minute. A 10 s run ships one point per
metric per live stream — 33 metrics x 4 streams = 132 data points, about 40 KiB
of OTLP/JSON, three orders of magnitude under the measured 5 MiB agent wall,
which is why this leg reuses `instana_batch`'s planner unchanged. Over a day
that is 8,640 runs x 132 = 1.14 M points; at a hypothetical 71-station
saturation it is 2.3 K points a run, still one request.

THE ONE LIMIT THAT IS NOT OURS TO WAIVE IS CARDINALITY, because it is the
vendor's. A series is (metric x station x session), and `session` is the only
unbounded term. It rides as a DATA-POINT attribute and never in the resource,
so it costs a dimension on a point and not a new OpenTelemetry ENTITY —
entities are what an infrastructure backend keeps forever. That containment is
enforced in `vitals_otlp.py` and pinned by a test; it is a correctness property
of the export, not a budget, and relaxing it would be the one way this lane
could do damage on the far side.

NOTE THE ASYMMETRY, and that it is deliberate. Our store samples at 1 Hz;
Instana gets one point per 10 s tick. That is not a downgrade we chose to save
anything — it is the finest thing an ingest-stamped backend can represent, and
it is exactly Instana's own documented floor. The good signal lives in our
store; Instana gets what Instana can display.
"""

from __future__ import annotations

import json
import os
import time

import vitals
import vitals_otlp
from instana_backlog import read_state, write_state
from instana_batch import drain, log_requests_for

#: Seconds between vitals forwards. The timer is the authority; this constant is
#: what the unit file is generated from and what a `--follow` run uses, so the
#: two cannot drift. See the cadence argument in the module docstring.
VITALS_INTERVAL_S = 10

#: How far back a LATEST_ONLY run looks for "the current value". Generous
#: against the 20 s client flush interval, so a stream whose batch is in flight
#: — or whose tab was briefly backgrounded — stays on the dashboard rather than
#: blinking out for a tick and reappearing. A blinking entity reads as an
#: outage; a slightly stale one reads as what it is.
LIVE_WINDOW_MS = 120_000

#: Samples read per page in backfill mode. The store's own `series()` ceiling.
PAGE_SAMPLES = 5_000


def _all_mode() -> bool:
    return (os.environ.get("INSTANA_VITALS_ALL") or "").strip().lower() in ("1", "true", "yes")


def forward_vitals(cfg, dest, post, dry_run: bool, verbose: bool) -> int:
    """Ship stream vitals to `/v1/metrics`, the fourth OTLP leg.

    Two modes, one code path for the POST. The default ships the CURRENT value
    of every live stream; `INSTANA_VITALS_ALL=1` drains the backlog instead.
    Both go through `instana_batch.drain()` — its budgets, its halve-and-retry
    on a size-shaped refusal and its advance-after-every-success rule are
    properties of shipping, not of any one signal.
    """
    store = vitals.VitalsStore(cfg.vitals_db, read_only=True)
    state = read_state(cfg.state)
    after = int(state.get("lastVitalsSeenSeq") or 0)
    first_seq = after
    every = _all_mode()

    def fetch(seq):
        if every:
            page = store.series(since_seq=seq, order="ingest", limit=PAGE_SAMPLES)["samples"]
            return page, (page[-1]["seq"] if page else seq)
        # LATEST_ONLY: one row per (station, session, source), newest first —
        # and note this ignores `seq` entirely for SELECTION. The watermark
        # still advances past everything seen, so a later switch to backfill
        # mode does not re-send a fortnight; but what leaves the box is the
        # present, because the present is all Instana's ingest clock can hold.
        page = store.live(LIVE_WINDOW_MS)["live"]
        high = max((r["seq"] for r in page), default=seq)
        return page, high

    def ship(chunk):
        doc = vitals_otlp.export(chunk, host_id=cfg.host_id if dest.stamp_host_id else None)
        if verbose or dry_run:
            print(json.dumps(doc, indent=2)[:4000])
        ok, detail = post(cfg, dest, "/v1/metrics", doc, dry_run)
        entities = len(doc.get("resourceMetrics", []))
        points = sum(
            len(next(iter(m[k]["dataPoints"] for k in ("gauge", "sum") if k in m)))
            for rm in doc.get("resourceMetrics", [])
            for sm in rm["scopeMetrics"]
            for m in sm["metrics"]
        )
        # The ENTITY count is printed on every line, not only when it is zero.
        # It is the number this whole feature is judged on: one OpenTelemetry
        # entity per station is the thing OTLP metrics buy that nothing else
        # does, and "0 entities" is the one symptom that says the export has
        # quietly become a heap of unattributed numbers.
        print(
            f"vitals [{dest.name}]: {len(chunk)} sample(s), {points} point(s), "
            f"{entities} station entity(ies) -> {detail}"
        )
        return ok, detail

    def advance(seq):
        if dry_run:
            return
        # `lastVitalsSeenSeq`, not `lastVitalsSeq`. In the default mode this is
        # how far the leg has LOOKED, not what it has delivered — see the
        # watermark note in the module docstring. Naming it after a guarantee
        # this lane does not make is exactly the mistake that cost the trace
        # lane half of every trace until 2026-09-01.
        state["lastVitalsSeenSeq"] = seq
        state["lastVitalsForwardedMs"] = int(time.time() * 1000)
        write_state(cfg.state, state)

    stat = drain(after, fetch, ship, advance, planner=log_requests_for, unit="samples")
    store.close()
    mode = "backfill" if every else "latest"
    if stat["requests"] == 0 and stat["ok"]:
        # Say enough that a SILENT lane is visible in the journal. Nothing
        # streaming is the normal state of a museum at 4 a.m., and it must not
        # look the same as a broken exporter.
        print(
            f"vitals [{dest.name}]: nothing live ({mode} mode, watermark seq {after}) — "
            f"no stream reported in the last {LIVE_WINDOW_MS // 1000}s"
        )
    else:
        print(
            f"vitals [{dest.name}]: run done ({mode}) — {stat['spans']} sample(s) in "
            f"{stat['requests']} request(s), seq {first_seq}->{stat['seq']}, stopped: {stat['stop']}"
        )
    if stat["dropped_spans"]:
        print(f"vitals [{dest.name}]: DROPPED {stat['dropped_spans']} sample(s) too large to ship — see stderr")
    return 0 if stat["ok"] else 1

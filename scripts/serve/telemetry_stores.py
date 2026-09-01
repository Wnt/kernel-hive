"""The telemetry plane's STORES, built as a group.

WHY THIS EXISTS, and it is the same answer `telemetry_routes.py` gives one line
away: `osgallery-https-server.py` sits on the 600-line hard cap
(`scripts/check-file-size.mjs`), and the analytics work put four store
constructions plus their prunes, their bindings and their comments in it. A
fourth pillar — logs — did not fit. Route groups came away first; stores are the
other half of the same seam.

BUILD ORDER MATTERS in exactly one place and it is called out below: the log
sink is bound before anything in this process logs about itself, so the boot
banner is the store's first record as well as the file's.
"""

from __future__ import annotations

import linecov
import logs
import logsink
import probes
import traces
import usage
import vitals
from auth import routes as auth_routes
from config import (
    ANALYTICS_DB,
    ANALYTICS_RETENTION_DAYS,
    LOG_RETENTION_DAYS,
    LOGS_DB,
    TRACE_RETENTION_DAYS,
    TRACES_DB,
    USAGE_STATS,
    VITALS_DB,
    VITALS_RETENTION_DAYS,
)

import analytics


def build(instance: str):
    """Open every telemetry store, prune it, and return them plus the dict the
    route group is handed. `instance` is this box's identity, stamped on every
    log record this process emits."""
    # Interaction counters. Unlike AUTH this exists on BOTH listeners: a station's
    # usage total is a fact about the machine, and the lab's own LAN traffic is as
    # real a use of it as a visitor's. Only the per-PERSON half needs a session, and
    # that half lives behind /auth/usage/report.
    USAGE = usage.UsageStore(USAGE_STATS)
    # Feature reach, flow funnels and grouped errors. On BOTH listeners for the same
    # reason as USAGE, and with one difference that is the point of the plane: it
    # takes no identity on either, so there is no per-person half to fence off.
    ANALYTICS = analytics.AnalyticsStore(ANALYTICS_DB)
    ANALYTICS.prune(ANALYTICS_RETENTION_DAYS)
    # The serving plane's OWN branch counters, into the SAME store under class
    # `server`. Until this line runs `probes.hit()` folds into memory and writes
    # nothing, which is what every unit test and every import of these modules
    # outside the server gets. `record_server` is the only door into that class and
    # no route reaches it, so a browser cannot forge a branch count.
    probes.bind(ANALYTICS)
    # Production LINE coverage, fed only by the opt-in instrumented bundle
    # (docs/ANALYTICS.md §6). Its own database beside the counters, not a table in
    # them: the rows are kilobytes rather than integers, they expire with the build
    # that produced them rather than lasting two years, and its body cap has to be
    # sixteen times the counter plane's — see serve/coverage.py. Unarmed, this is an
    # empty file and nothing ever posts to it.
    COVERAGE = linecov.CoverageStore(ANALYTICS_DB.parent / "coverage.db")
    COVERAGE.prune()
    # The stores the analytics route group reaches, passed rather than imported so
    # the dispatcher stays a pure function of what it is given.
    # The correlated trace lane. Reads are admin-only and live under /auth/traces/*
    # (auth/routes.py); only the INGEST is open here, exactly like /analytics — a
    # tab has to be able to report what it did without holding an admin session.
    TRACES = traces.TraceStore(TRACES_DB)
    TRACES.prune(TRACE_RETENTION_DAYS)
    auth_routes.bind_traces(TRACES)
    # The correlated LOG lane: same posture as TRACES, one pillar over (serve/logs.py).
    # `logsink.bind` comes BEFORE the first line this process logs about itself, so
    # the boot banner is the store's first record as well as the file's.
    LOGS = logs.LogStore(LOGS_DB)
    LOGS.prune(LOG_RETENTION_DAYS)
    auth_routes.bind_logs(LOGS)
    logsink.bind(LOGS, instance)
    # The VITALS lane: continuous stream health, sampled rather than evented.
    # Same posture as TRACES and LOGS — open ingest, admin-only reads — and the
    # same binder shape, one pillar over (serve/vitals.py). It is bound LAST
    # because nothing in the boot path produces a vital: unlike the log sink,
    # this process is not itself a producer, only a keeper.
    VITALS = vitals.VitalsStore(VITALS_DB)
    VITALS.prune(VITALS_RETENTION_DAYS)
    auth_routes.bind_vitals(VITALS)
    TELEMETRY = {"analytics": ANALYTICS, "coverage": COVERAGE, "traces": TRACES, "logs": LOGS, "vitals": VITALS}
    return USAGE, ANALYTICS, COVERAGE, TRACES, LOGS, TELEMETRY

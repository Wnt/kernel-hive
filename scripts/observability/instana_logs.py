#!/usr/bin/env python3
"""The LOGS leg of the Instana forwarder — `POST /v1/logs`, OTLP/JSON.

SPLIT OUT OF `instana-forward.py`, not designed apart from it: that file sat 15
lines under the 600-line hard cap and a third signal did not fit. It reads the
forwarder's `Config`, `post()` and destination exactly as the traces leg does,
taking them as arguments rather than importing them — so this module has no
import cycle with the script that owns them, and can be exercised against a
fixture store with no socket and no tenant.

WHAT INSTANA DOES WITH WHAT THIS SENDS, quoted rather than assumed
(`/home/wnt/instana-docs`, and see docs/lab/research/instana-logs.md):

  * "The TraceId, SpanId, and Body fields are incorporated without any
    alterations." — 0307-opentelemetry-signals.md:331. That sentence is the
    entire justification for this leg: the join we already have locally is the
    join Instana makes.
  * "The log level is determined primarily by the SeverityText field and the
    SeverityNumber field as a fallback." — 0307:333-334. We send both.
  * "Host or entity identification is required for Instana to accept
    OpenTelemetry logs." — 0307:338-352. `logs_otlp.export` puts `host.id` and
    `service.instance.id` in the resource; the forwarder additionally sets the
    `x-instana-host` header on the leg that needs it.
  * "HTTP endpoint path: /v1/logs", ports 4318 (HTTP) / 4317 (gRPC) —
    0307:285-296.
  * Retention: "All the collected logs are kept for 7 days." —
    0321-policies.md:89. Our own store keeps 7 for the same reason.

THIS TENANT REFUSES LOG INGRESS, AND THE 200 BELOW DOES NOT KNOW IT. Measured
2026-09-01, the first time this leg ever ran against the live agent: the agent
answered `POST /v1/logs` with **200 OK**, and 250 ms later its own log recorded
what the BACKEND said when it forwarded the batch on —

    | WARN | Backend | Payment required (402) for Backend
    | ingress-blue-saas.instana.io:443 and key '*** (redacted)' ...
    | HTTP/1.1 402 Payment Required
    | The current TU doesn't allow this endpoint because it needs to be paid for.

It is the only 402 in that log's entire history, at the exact minute of the
first log batch this box has ever sent, and the Logging API confirms the
outcome: `getLogs/v1` answers 200 with `totalHits: 0` for the tenant over 24
hours. It matches what the docs say to expect — on SaaS, "OpenTelemetry logs"
require a **logging add-on** (`0275-logging.md`), while on-premises deployments
include log ingestion in the standard licence.

So: **an OK from this leg means the agent took the batch, NOT that Instana
retained it.** The 402 happens on the agent-to-backend hop, which the forwarder
cannot see, and nothing here can or should paper over that — a leg that guessed
at retention would be worse than one that reports what it was actually told.
The correlated-count on every run line is the number to watch when the add-on
is bought; our own store answers the same join in the meantime, and is where
the acceptance test for this feature actually lives.

DOCS SILENT on: a per-request body cap for the acceptor, any rate limit or 429
behaviour, and the accepted methods and partial-success semantics of `/v1/logs`
(the path appears only as diagram label text; there is no prose endpoint spec
and no curl example anywhere in the tree). So this leg reuses the measured
5 MiB agent wall and `instana_batch`'s 4 MiB budget unchanged, rather than
inventing a limit the docs do not support.
"""

from __future__ import annotations

import json
import time

import logs
import logs_otlp
from instana_backlog import read_state, write_state
from instana_batch import drain, log_requests_for

#: Log records read from the store per PAGE, the sibling of PAGE_TRACES. Larger
#: because a record is small and flat: 2000 of them are a few hundred KiB, well
#: inside one request's 4 MiB budget, so a page is usually one POST.
PAGE_LOGS = 2_000


def forward_logs(cfg, dest, post, dry_run: bool, verbose: bool) -> int:
    """Ship the log backlog to `/v1/logs`, the third OTLP leg.

    `cfg`, `dest` and `post` are the forwarder's own — injected rather than
    imported, so this module has no cycle with the script that defines them and
    can be driven against a fixture store with a stub `post`.

    WHY THIS IS WORTH A LEG OF ITS OWN. Instana takes an OTLP LogRecord's
    `TraceId` and `SpanId` "without any alterations" (0307-opentelemetry-
    signals.md:331) and links the record to the call it belongs to, so a log
    shipped with those two fields is reachable from the trace we already ship —
    Analytics > Applications > Calls, then the Logs tab (0015-quick-start-
    guides.md:446-457). Shipping logs WITHOUT them would fill a pillar with
    text nobody can pivot into, which is the outcome this whole change exists
    to avoid.

    Same watermark discipline as the trace leg, under its OWN key
    (`lastLogSeq`): the two stores have independent sequences, and one shared
    watermark would silently skip whichever lane moved slower. Same `drain()`
    loop too — its budgets, its halve-and-retry on a size-shaped refusal and
    its advance-after-every-success rule are properties of shipping, not of
    spans; only the planner differs.
    """
    store = logs.LogStore(cfg.logs_db, read_only=True)
    state = read_state(cfg.state)
    after = int(state.get("lastLogSeq") or 0)
    first_seq = after

    def fetch(seq):
        page = store.search(since_seq=seq, order="ingest", limit=500)["logs"]
        # `search` caps `limit` at 500, so a page is drained in several reads
        # rather than one; the loop below asks again until it comes back empty.
        return page, (page[-1]["seq"] if page else seq)

    def ship(chunk):
        doc = logs_otlp.export(chunk, host_id=cfg.host_id if dest.stamp_host_id else None)
        if verbose or dry_run:
            print(json.dumps(doc, indent=2)[:4000])
        ok, detail = post(cfg, dest, "/v1/logs", doc, dry_run)
        joined = sum(1 for r in chunk if r.get("traceId"))
        # The correlated count is printed on EVERY line, not only when it is
        # low. A number that appears only when it is bad is a number nobody
        # learns to read, and "0 of 500 correlated" is the one symptom that
        # says this feature has quietly become a log dump.
        print(f"logs [{dest.name}]: {len(chunk)} record(s), {joined} trace-correlated -> {detail}")
        return ok, detail

    def advance(seq):
        if dry_run:
            return
        state["lastLogSeq"] = seq
        state["lastLogForwardedMs"] = int(time.time() * 1000)
        write_state(cfg.state, state)

    stat = drain(after, fetch, ship, advance, planner=log_requests_for, unit="records")
    behind = store.search(since_seq=stat["seq"], limit=1)["total"]
    store.close()
    if stat["requests"] == 0 and stat["ok"]:
        print(f"logs [{dest.name}]: nothing new (watermark seq {after})")
    else:
        print(
            f"logs [{dest.name}]: run done — {stat['spans']} record(s) in {stat['requests']} request(s), "
            f"seq {first_seq}->{stat['seq']}, stopped: {stat['stop']}"
        )
    if stat["dropped_spans"]:
        print(f"logs [{dest.name}]: DROPPED {stat['dropped_spans']} record(s) too large to ship — see stderr")
    print(f"logs [{dest.name}]: backlog: {behind} record(s) behind")
    return 0 if stat["ok"] else 1

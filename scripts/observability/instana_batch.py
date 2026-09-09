"""What fits in ONE OTLP request, and why that is a span/byte question.

SPLIT OUT OF THE WATERMARK ON PURPOSE. `instana_backlog.py` answers *which*
traces have not been sent; this answers *how many of them go in one POST*. They
were one thing until 2026-09-01, and being one thing is what produced the two
defects below, because a single number (`BATCH = 100` traces) was being asked to
mean both "how far the watermark may advance" and "how big the request is".

DEFECT ONE: A TRACE IS NOT A UNIT OF SIZE. Trace size on this box spans four
orders of magnitude — a `serve.clientcmd` poll trace holds ONE span, while a
long-lived browser session accumulates thousands of `input.edge` /
`client.frame.*` spans into a single trace. Measured on the live store on
2026-09-01: 11,359 traces held 35,447 spans, but ONE of them held 16,139 of them
(9.6 MB of OTLP/JSON on its own) and the next held 3,907. So "100 traces" was
sometimes 100 spans and sometimes 16,226, and the endpoint saw the difference:

    13:26:21 traces [agent]: 100 trace(s), 16226 span(s) -> unreachable: Broken pipe
    13:31:26 traces [agent]: 100 trace(s), 16226 span(s) -> unreachable: Broken pipe

Batching by trace count cannot express "a request Instana will accept". Batching
by span count and serialized bytes can, so that is what this module does.

WHERE THE BYTE LIMIT COMES FROM — MEASURED, NOT GUESSED. The Instana host
agent's OTLP/HTTP receiver on 127.0.0.1:4318 was probed with synthetic
`resourceSpans` documents of increasing size on 2026-09-01. It answers 200 up to
and including 5,242,880 bytes (5 MiB exactly) and closes the connection
mid-upload above it — which is what surfaces to urllib as `[Errno 32] Broken
pipe` rather than as an HTTP status, because the peer never gets as far as
writing a response:

    4194304 bytes -> 200      5242880 bytes -> 200
    5244880 bytes -> Broken pipe      6291456 bytes -> Broken pipe

`MAX_BODY_BYTES` is 4 MiB, i.e. 80% of that measured wall. The 20% is not
timidity: `export()` groups spans by session so the assembled body is a little
SMALLER than the sum of the per-trace measurements this module adds up, but the
SaaS leg's own limit has never been probed (it is a different acceptor, behind a
different proxy) and a limit discovered by breaking production is not a limit we
want to discover twice.

WHAT THE INSTANA DOCS ACTUALLY SAY, since a limit worth trusting should not
rest on one probe. The offline corpus (/home/wnt/instana-docs, 326 files) is
SILENT on any body-size limit for the SaaS otlp-acceptor, and silent on a gRPC
4 MiB default. It is not silent on the agent: `0003-agents.md` (agent 1.2.44,
Nov 2025) documents `INSTANA_AGENT_OTEL_HTTP_MAX_MESSAGE_SIZE` with "minimum:
5 MB, maximum: 49.5 MB" and does not state the default. The probe found exactly
5 MiB, i.e. this agent runs at that documented FLOOR — so 5 MiB is a real
configured value and not an accident, and an operator who ever needs bigger
requests raises that variable rather than editing this file.

IS SPLITTING ONE TRACE ACROSS TWO REQUESTS SAFE? Nothing in the corpus forbids
it — `resourceSpans` does not appear in the docs at all, and the only stated
identity rule (`0314-host-agent-rest-api.md`) is that a trace's spans share a
traceId, which says nothing about transport. Two things say splitting is
expected. First, this codebase already depends on it: a trace's server span is
written by the serving plane in milliseconds while the SAME trace's browser
spans flush up to a pagehide later, so those halves reach Instana in DIFFERENT
runs of the forwarder, minutes apart — that is exactly what
`test_late_browser_spans_are_forwarded_exactly_once` pins down, and those traces
assemble correctly in the tenant today. Second, `0315-mcp-server-for-instana.md`
answers "what is the optimal split size to send 50,000 spans" with "buffer spans
for up to one second or until 500 spans were collected, then transmit" — the
docs telling you to split a large span set across many requests.

THE HONEST CAVEAT, because it is a real one. `0280-custom-tracing.md` describes
a ~2-second batching interval in Instana's span pipeline, and says spans that
"arrive after the 2-second interval when the resulting trace has already been
processed" are still stored but may mis-correlate: "Separate traces with the
same trace-id get listed and partially present the overall trace", an exit and
entry span "might not get merged into a single call", a call "might not get
linked to the correct parent call". So the constraint is arrival TIME, not
request count. This module's pieces of one trace are sent back to back in the
same run, ~0.5-1.5 s per request measured, so a two-piece trace lands inside
that window and a four-piece one may not. The consequence for a 16,000-span
`serve.clientcmd` trace is a cosmetically split trace view; the alternative on
offer is shipping none of it, ever, and stalling everything behind it. That
trade is made deliberately and the caveat is written here rather than
discovered.

THE ONE THING THAT MUST NEVER HAPPEN is a payload that cannot be made to fit,
retried forever. Before this module, a single trace over the limit would have
been re-selected, re-sent and re-broken every five minutes until a human looked.
Termination here is structural, in two steps: an oversized TRACE is split into
per-span pieces, and a single SPAN that alone exceeds the budget is DROPPED with
a loud log rather than shipped. Dropping one span is a real loss and is stated
as one; the alternative is losing every span behind it, indefinitely, silently.
"""

from __future__ import annotations

import json
import sys
import time

#: Spans per request. The probe sent 4,000 spans in 2.69 MiB and 6,000 in
#: 4.03 MiB, both 200 OK, so this is comfortably inside what the endpoint
#: takes; at the 600-750 bytes/span this store actually produces, 4,000 spans
#: is ~2.4-3.0 MiB and `MAX_BODY_BYTES` still binds first on anything fatter.
#:
#: IT IS DELIBERATELY NOT SMALLER, and the reason is the 2-second assembly
#: window in the docstring above: every extra piece one trace is split into is
#: another chance for a piece to land after Instana has already processed the
#: trace. The live 16,139-span trace goes out in 5 pieces at 4,000 and in 9 at
#: 2,000, so the larger ceiling is the one that correlates better. Its only
#: cost is a bigger single failure to retry, which the watermark makes cheap.
MAX_SPANS = 4_000

#: Serialized body bytes per request. 80% of the 5 MiB the agent's OTLP
#: receiver was measured to accept — see the module docstring for the probe.
MAX_BODY_BYTES = 4 * 1024 * 1024


def _default_sizer(spans: list[dict]) -> int:
    """Serialized OTLP/JSON bytes for a list of stored spans.

    Deliberately measures the EXPORTED form, not the stored one: OTLP/JSON
    spells an attribute as `{"key":..,"value":{"stringValue":..}}` and is three
    to five times the bytes of what the store keeps, so sizing the stored rows
    would under-count by a factor that varies with attribute count.
    """
    import traces_otlp  # the caller owns the sys.path that finds scripts/serve

    otlp = (json.dumps(traces_otlp.span_to_otlp({**s, "traceId": "0" * 32}), separators=(",", ":")) for s in spans)
    return sum(len(o) for o in otlp)


def _piece(trace: dict, spans: list[dict]) -> dict:
    """The same trace carrying a subset of its spans."""
    return {**trace, "spans": spans}


def _split_trace(trace: dict, max_spans: int, max_bytes: int, sizer, dropped: list) -> list[dict]:
    """One over-budget trace as several under-budget pieces of itself.

    A span whose own OTLP form exceeds `max_bytes` is dropped here, loudly, and
    appended to `dropped`. That is the termination guarantee: every piece this
    returns is shippable, so no piece can be re-tried forever.
    """
    pieces, cur, cur_bytes = [], [], 0
    for s in trace.get("spans", []):
        b = sizer([s])
        if b > max_bytes:
            dropped.append((trace["traceId"], s.get("spanId"), s.get("name"), b))
            sys.stderr.write(
                f"instana-forward: DROPPING span {s.get('name')!r} ({s.get('spanId')}) of trace "
                f"{trace['traceId']}: {b} bytes exceeds the {max_bytes}-byte request budget on its own. "
                "Shipping it is impossible and retrying it would stall every trace behind it.\n"
            )
            continue
        if cur and (len(cur) + 1 > max_spans or cur_bytes + b > max_bytes):
            pieces.append(_piece(trace, cur))
            cur, cur_bytes = [], 0
        cur.append(s)
        cur_bytes += b
    if cur:
        pieces.append(_piece(trace, cur))
    return pieces


def requests_for(traces: list[dict], max_spans: int = MAX_SPANS, max_bytes: int = MAX_BODY_BYTES, sizer=None):
    """Traces, in ingest order, as a list of `(traces, watermark_seq)` requests.

    `watermark_seq` is the ingest sequence that becomes safe to persist ONCE
    THIS REQUEST HAS SUCCEEDED, or None when it has not become safe yet — which
    is exactly the case of a trace split across several requests: only the last
    piece carries the sequence, so a failure half way through one trace leaves
    the watermark behind it and the whole trace is simply re-sent next run. That
    keeps the no-loss property the watermark exists for; the cost of the rare
    failure is a duplicate, never a hole.
    """
    sizer = sizer or _default_sizer
    out: list[tuple[list[dict], int | None]] = []
    dropped: list = []
    cur: list[dict] = []
    cur_spans = cur_bytes = 0
    cur_seq = None
    for t in traces:
        spans = t.get("spans", [])
        n, b = len(spans), sizer(spans)
        if n <= max_spans and b <= max_bytes:
            if cur and (cur_spans + n > max_spans or cur_bytes + b > max_bytes):
                out.append((cur, cur_seq))
                cur, cur_spans, cur_bytes, cur_seq = [], 0, 0, None
            cur.append(t)
            cur_spans += n
            cur_bytes += b
            cur_seq = t.get("ingestSeq", cur_seq)
            continue
        # Over budget on its own. Flush whatever was accumulating first, so the
        # pieces of one trace stay contiguous in send order.
        if cur:
            out.append((cur, cur_seq))
            cur, cur_spans, cur_bytes, cur_seq = [], 0, 0, None
        pieces = _split_trace(t, max_spans, max_bytes, sizer, dropped)
        for i, piece in enumerate(pieces):
            out.append(([piece], t.get("ingestSeq") if i == len(pieces) - 1 else None))
        if not pieces:
            # Every span of it was undroppably huge. Nothing to send, but the
            # watermark MUST still move or this trace is the wedge all over
            # again — with no payload left to blame.
            out.append(([], t.get("ingestSeq")))
    if cur:
        out.append((cur, cur_seq))
    return out, dropped


def log_requests_for(rows: list[dict], max_records: int = MAX_SPANS, max_bytes: int = MAX_BODY_BYTES, sizer=None):
    """The LOG lane's planner, with the same `(page, watermark)` contract.

    Simpler than `requests_for` because a log record is atomic: there is no
    parent to keep contiguous and nothing to split, so every record either fits
    a request or is dropped alone. It carries its own `seq`, so a watermark is
    available on every request rather than only on the last piece of a trace.

    One record that is over budget on its own is DROPPED and reported, exactly
    as an oversized span is: without that, a single 4 MiB body would wedge the
    lane and every later record behind it — the failure mode the trace lane
    already paid for once.
    """
    sizer = sizer or (lambda rows: len(json.dumps(rows, separators=(",", ":")).encode()))
    out: list[tuple[list[dict], int | None]] = []
    dropped: list = []
    cur: list[dict] = []
    cur_bytes = 0
    for r in rows:
        b = sizer([r])
        if b > max_bytes:
            dropped.append(r)
            sys.stderr.write(f"[instana] DROPPED one log record of {b} bytes (over the {max_bytes}-byte request cap)\n")
            # The watermark still moves past it, or the lane wedges here.
            out.append(([], r.get("seq")))
            continue
        if cur and (len(cur) >= max_records or cur_bytes + b > max_bytes):
            out.append((cur, cur[-1].get("seq")))
            cur, cur_bytes = [], 0
        cur.append(r)
        cur_bytes += b
    if cur:
        out.append((cur, cur[-1].get("seq")))
    return out, dropped


#: How long ONE run may spend shipping, in seconds.
#:
#: The unit is `Type=oneshot` with `TimeoutStartSec=300`, fired by a timer with
#: `OnUnitActiveSec=5min`. Both numbers matter and they are the same number:
#: systemd kills the run at 300 s, AND a tick that arrives while the previous
#: run is still going is DROPPED rather than queued (a oneshot cannot overlap
#: itself). So a run that took the full 300 s would be killed mid-flight *and*
#: cost the next tick — the pipeline would lose ground at exactly the moment it
#: was trying to catch up. 120 s is 40% of both: it leaves 180 s of slack for
#: the metrics leg that runs after this one, for a slow first sqlite page on a
#: cold cache, and for the run to finish and exit well before the next tick is
#: even due. Nothing is lost when the budget bites — the watermark has advanced
#: over every request that succeeded, so the next run resumes exactly there.
RUN_BUDGET_S = 120

#: A second, independent ceiling on one run. The time budget already bounds a
#: run, so this is not really about time: it is the thing that stays true if the
#: endpoint ever becomes so fast that a runaway loop could make tens of
#: thousands of requests inside 120 s. Two cheap bounds beat one clever one.
MAX_REQUESTS = 200

#: How many times a run may HALVE its body budget after a size-shaped refusal.
#: The measured 5 MiB wall is the agent's; the SaaS acceptor's is undocumented
#: (docs silent) and could be smaller, and an endpoint whose limit drops below
#: our budget would otherwise wedge the pipeline exactly the way an oversized
#: trace used to. Three halvings take 4 MiB down to 512 KiB, which is below any
#: OTLP limit anyone has ever shipped, and the sequence terminates by
#: construction.
MAX_HALVINGS = 3

#: Refusals that mean "your body was too big" rather than "the endpoint is
#: down". The distinction is load-bearing: the first is retried SMALLER, the
#: second must stop the run WITHOUT advancing the watermark. Note that the size
#: case usually has no HTTP status at all — the acceptor closes the connection
#: mid-upload, which surfaces as a broken pipe or a reset, never as a 413.
_SIZE_SHAPED = ("broken pipe", "connection reset", "http 413", "too large", "entity too large")


def size_shaped(detail: str) -> bool:
    d = (detail or "").lower()
    return any(m in d for m in _SIZE_SHAPED)


def drain(
    after_seq,
    fetch,
    ship,
    advance,
    *,
    budget_s=RUN_BUDGET_S,
    max_requests=MAX_REQUESTS,
    max_spans=MAX_SPANS,
    max_bytes=MAX_BODY_BYTES,
    sizer=None,
    clock=None,
    planner=None,
    unit="spans",
):
    """Ship pages until caught up or out of budget. Returns a summary dict.

    ONE RUN USED TO SHIP ONE BATCH AND EXIT, and that is the throughput half of
    the 2026-09-01 defect. `BATCH = 100` traces per request was also 100 traces
    per five minutes — 20 traces/minute against a store measured taking 23
    traces/minute, so the pipeline was losing ground by construction and sat
    991 traces behind. The Applications view flatlined roughly 25 minutes behind
    reality and a visitor simulation's traces took the better part of an hour to
    appear. Draining within a run is the fix; the budgets above are what keeps
    "drain" from meaning "run forever".

    The three callbacks are injected rather than imported so that this loop is
    testable with no sqlite store, no socket and no Instana tenant:
      `fetch(seq) -> (traces, high_seq)`   the next page of the backlog
      `ship(traces) -> (ok, detail)`       one POST, already logged by the caller
      `advance(seq)`                       persist the watermark, now safe

    `planner` and `unit` are what let the LOG lane reuse this loop rather than
    grow a second one. Everything this function actually decides — the time and
    request budgets, the size-shaped halve-and-retry, the watermark-only-after-
    success rule, and the 2026-09-01 drain-within-a-run fix below — is true of
    any signal; only the shape of a page differs, and that is the planner's
    business. Both default to the trace lane, so every existing caller is
    unchanged.
    """
    planner = planner or requests_for
    clock = clock or time.monotonic
    deadline = clock() + budget_s
    seq, halvings = after_seq, 0
    stat = {"requests": 0, "traces": 0, "spans": 0, "dropped_spans": 0, "seq": seq, "stop": "caught up", "ok": True}
    while True:
        if clock() >= deadline:
            stat["stop"] = f"time budget ({budget_s}s)"
            break
        if stat["requests"] >= max_requests:
            stat["stop"] = f"request budget ({max_requests})"
            break
        page, _high = fetch(seq)
        if not page:
            break
        plan, dropped = planner(page, max_spans, max_bytes, sizer)
        stat["dropped_spans"] += len(dropped)
        shrink = False
        for chunk, watermark in plan:
            if chunk:
                ok, detail = ship(chunk)
                stat["requests"] += 1
                if not ok:
                    # Too big -> retry the SAME page smaller. Anything else is
                    # the endpoint, not the payload: stop, and leave the
                    # watermark where the last success put it so nothing is
                    # lost and the next run resumes there.
                    if size_shaped(detail) and halvings < MAX_HALVINGS:
                        halvings += 1
                        max_bytes = max(max_bytes // 2, 1)
                        max_spans = max(max_spans // 2, 1)
                        shrink = True
                        break
                    stat["stop"], stat["ok"] = f"failed: {detail}", False
                    stat["seq"] = seq
                    return stat
                stat["traces"] += len(chunk)
                stat["spans"] += sum(len(t.get("spans", [])) for t in chunk) if unit == "spans" else len(chunk)
            if watermark is not None:
                seq = watermark
                advance(seq)
            if clock() >= deadline or stat["requests"] >= max_requests:
                break
        if shrink:
            continue
    stat["seq"] = seq
    return stat

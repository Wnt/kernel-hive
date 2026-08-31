#!/usr/bin/env python3
"""Forward our OpenTelemetry data to Instana, so the in-house UI can be compared
against a commercial one on the same traces.

    scripts/observability/instana-forward.py --check      # config only, sends nothing
    scripts/observability/instana-forward.py --dry-run    # show exactly what WOULD leave
    scripts/observability/instana-forward.py --once
    scripts/observability/instana-forward.py --follow --interval 60
    scripts/observability/instana-forward.py --via-agent   # force the local Instana host agent
    scripts/observability/instana-forward.py --via-saas    # force direct-to-SaaS

TWO DESTINATIONS, ONE CODEBASE, ON PURPOSE. Since 2026-08-31 labhost also runs
an Instana HOST AGENT (`systemctl status instana-agent`), which exposes its own
OTLP receivers on `127.0.0.1:4317` (gRPC) and `127.0.0.1:4318` (HTTP) —
LOOPBACK ONLY. That is a second, and now-preferred, path to the same Instana
tenant: this still reads the stores and is still the only thing on the box that
talks to Instana over the network (the agent's SaaS leg is IBM's own binary,
not ours), so "one egress point" survives as "one thing that decides to leave
the box, with a choice of two local doors" rather than as a literal singular
URL — see docs/ANALYTICS.md §8.1 for the current topology. One place to
scrub, one credential to rotate (still only needed for the SaaS door), one
switch to turn each path off, and one place to look when somebody asks what
left the building.

WHICH DESTINATION, AND WHY THE AGENT IS PREFERRED. `--via-agent` / `--via-saas`
force a destination; with neither given this AUTO-DETECTS by probing whether
the agent's loopback port answers a TCP connect. The agent wins when reachable:
it adds host correlation for free (IBM's OTLP receiver attaches host identity
itself — see "host.id" below), and it keeps the egress hop on the box instead
of over the internet to a third party. Direct-to-SaaS remains a legitimate,
fully supported fallback for a box with no agent installed, or to compare the
two paths deliberately.

THIS SENDS DATA TO A THIRD PARTY. Nothing else in this repo does. The stores it
reads are already scrubbed at intake — `traces.py` refuses `exception.stacktrace`
and every other free-text field, so a stack, a typed string or a credential
handle cannot be in the database to be forwarded — but "already scrubbed" is a
property worth re-stating at the boundary rather than assumed. `--dry-run`
exists so the exact bytes can be read before any of them are sent, and it is the
recommended first run.

INSTANA ONLY BUILDS A TRACE FROM AN ENTRY SPAN — confirmed empirically on
2026-08-31, and it is the difference between "ingested" and "visible". Spans of
OTel kind `internal` are accepted (200, and the service `kernel-hive-spa`
appears under technology `openTelemetry`) and then produce NO trace, NO endpoint
and `calls.sum = 0`. A single hand-sent span of kind SERVER surfaced in
`/api/application-monitoring/analyze/traces` immediately. The browser plane is
internal-kind throughout, so on its own it registers a service and nothing else.

The fix is not to relabel browser spans — a UI span is not a server span and
saying so to every OTel consumer to satisfy one of them is how a vendor
accommodation becomes a lie in the data. It is that the SERVING PLANE emits
`server`-kind spans (serve.signal, serve.request), which are the honest entry
points of these traces; once those are deployed the browser spans hang beneath
them and Instana models the whole journey. Until then, expect a service with no
calls and do not read it as a broken exporter.

A SECOND, RELATED FAMILY: the sampled `input.edge` traces (docs/lab/
TRACE-CONTEXT.md §3.2) have no serving-plane span in them at all — they never
touch an HTTP request, only browser->daemon WebTransport — so the fix above
does not reach them. Verified separately, 2026-08-31, against the SAME API:
every `input.edge` trace (`Client` root, `Internal` children) came back
`service: "Unspecified"` in `analyze/traces`, while every `serve.*` trace
(which HAS a `Server`-kind entry span) came back correctly labelled
`kernel-hive-serve`. The daemon's `input.dispatch` span — the receiving side of
the browser's `Client`-kind `input.edge` — was `Internal` when it should always
have been `Server`: it IS the request/response boundary, the same client/server
RPC pairing this repo already uses for `http.client.request` / `serve.signal`.
Fixed in `streamhost/src/trace_session.rs`; requires the daemon binary to be
rebuilt and rolled out to take effect (this forwarder cannot do that, and
re-running it against old data will keep showing `Unspecified` for
`input.edge` until a station with the new binary produces fresh spans).

ALSO FIXED THE SAME DAY: daemon spans (`input.dispatch`, `guest.frame.next`,
`transport.frame.next`, `streamhost.session`, ...) carried NO `kh.service`
attribute at all — only `scripts/serve/tracing.py`'s Python spans stamped one.
`traces_otlp.export()`'s fallback (`svc = attrs.get("kh.service") or
"kernel-hive-spa"`) therefore filed every daemon span under the BROWSER's
service name, which is a mislabel independent of the entry-span problem above
— confirmed by exporting a real `input.edge` trace and reading its
`resource.attributes["service.name"]` before this fix: `"kernel-hive-spa"` for
all four spans, daemon-origin ones included. `streamhost/src/trace/mod.rs`'s
`render()` now stamps `kh.service: "kernel-hive-daemon"` on every span it
writes, the same "one place, no way to forget" pattern `tracing.py` already
uses for the Python plane. Also requires a daemon rebuild + rollout.

THE AGENT KEY CANNOT BE FETCHED FROM THE API — checked, 2026-08-31, so nobody
re-derives it. A personal API token authenticates fine against
`/api/instana/health`, `/api/instana/version`, `/api/settings/api-tokens` and
the event-specification endpoints, but every plausible agent-key path 404s
(`/api/instana/agentKeys`, `/api/settings/agent/keys`, `/api/settings/agentKeys`,
`/api/settings/agents/keys`, `/api/instana/settings/agentKeys`, and the
lower-cased variants); the tenant exposes no OpenAPI document to enumerate from
either. IBM's own community answer agrees: there is no REST call for the
download/agent key. It is a UI-only value — Instana → Settings → Agents — and
must be pasted into INSTANA_TOKEN_FILE by hand, once.

THE LOCAL AGENT DOES NOT WANT THE KEY EITHER — checked, 2026-08-31, by curling
its OTLP/HTTP receiver directly on the box: an empty `{"resourceSpans":[]}`
POST to `http://127.0.0.1:4318/v1/traces` returns 200 with no `x-instana-key`
header at all, and returns the same 200 when a deliberately bogus one is
attached. The agent authenticates the box to Instana once, itself, over the
connection the agent.log shows as `Connected using HTTP/2 to
ingress-blue-saas.instana.io:443`; nothing an OTLP client sends it is checked
against a tenant credential. So the agent leg of `post()` omits the header
entirely — sending it would not be wrong exactly, but it would be a credential
attached to a request that never inspects it, which is worse than pointless
because it invites the next reader to believe the agent needs one.

That is why INSTANA_AUTH_MODE exists at all: `api-token` is genuinely useful for
reading configuration out of Instana, and genuinely useless for ingesting spans
into it, and the two failure modes look identical from the outside (a 401) until
somebody has read this paragraph.

OFF UNLESS CONFIGURED. No endpoint in registry/local.env means this does
nothing, loudly. It is never wired into a timer or the serving plane by this
commit; forwarding is a thing somebody runs, or arms deliberately.

WHAT IT SENDS. Traces as OTLP/JSON (`traces_otlp.py` — the same export the admin
UI offers, so what Instana sees and what the operator sees cannot disagree) and
the metric aggregates as OTLP histograms. The bucket boundaries ARE our ladder
(spa/src/analytics/catalogue/types.ts), so an Instana histogram of
`station.open.toFirstFrameMs` has exactly the resolution our own report has —
neither more nor less, which is the point of a comparison.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(HERE))

import traces  # noqa: E402
import traces_otlp  # noqa: E402
from instana_destination import DEFAULT_AGENT_ENDPOINT, Destination, choose_destination, scheme_problem  # noqa: E402

DEFAULT_TRACES_DB = Path("/data/vms/streamhost/serve/traces.db")
DEFAULT_ANALYTICS_DB = Path("/data/vms/streamhost/serve/analytics.db")
DEFAULT_TOKEN = ROOT / "scripts" / "serve" / "pki" / "instana.token"
#: Where the watermark lives, so a re-run does not re-send what already went.
DEFAULT_STATE = Path("/data/vms/streamhost/serve/instana-forward.state.json")

#: Traces per request. Instana's acceptor, like every OTLP endpoint, has a body
#: limit; a private gallery never approaches it, but a first run against a
#: fortnight of history would.
BATCH = 100

#: Destination selection (agent-vs-SaaS, the loopback http exception, the
#: DEFAULT_AGENT_ENDPOINT/Destination types) lives in instana_destination.py —
#: split out so it is unit-testable without a trace store, a socket, or a real
#: Instana tenant. See scripts/test_instana_destination.py.


class Config:
    """Everything this needs, and a clear account of what is missing.

    Read from registry/local.env (gitignored, where every deployment-local
    operator value in this repo lives) with environment overrides, so nothing
    tenant-specific is ever committed — AGENTS.md rule 1.
    """

    def __init__(self, env: dict):
        self.endpoint = (env.get("INSTANA_ENDPOINT") or "").rstrip("/")
        # The local host agent's OTLP receiver. Has a real default (see
        # DEFAULT_AGENT_ENDPOINT) because, unlike the SaaS endpoint, it is not
        # tenant-specific — only whether anything is listening there varies.
        self.agent_endpoint = (env.get("INSTANA_OTLP_AGENT_ENDPOINT") or DEFAULT_AGENT_ENDPOINT).rstrip("/")
        # `agent-key` is Instana's DATA INGESTION credential and is what an OTLP
        # acceptor expects. `api-token` is the REST/config credential and CANNOT
        # ingest spans — a distinction worth failing loudly on, because sending
        # one where the other is wanted produces a 401 that reads like a
        # networking problem for an afternoon.
        self.auth_mode = env.get("INSTANA_AUTH_MODE") or "agent-key"
        self.token_file = Path(env.get("INSTANA_TOKEN_FILE") or DEFAULT_TOKEN)
        self.traces_db = Path(env.get("TRACES_DB") or DEFAULT_TRACES_DB)
        self.analytics_db = Path(env.get("ANALYTICS_DB") or DEFAULT_ANALYTICS_DB)
        self.state = Path(env.get("INSTANA_STATE") or DEFAULT_STATE)
        # Which client classes to forward. Defaulting to everything is right for
        # a COMPARISON — the point is to see the same population in both UIs —
        # but it is stated rather than assumed, and `human` alone is one edit.
        # Instana REQUIRES a host identity: the backend wants a `host.id`,
        # `faas.id` or `device.id` resource attribute, or the `x-instana-host`
        # header, and uses it to link OpenTelemetry entities to a host. Without
        # one, data is refused or lands orphaned — which would have looked like
        # a broken exporter rather than a missing field. Defaults to the box's
        # own hostname; override for a deployment where that is not stable.
        self.host_id = env.get("INSTANA_HOST_ID") or socket.gethostname()
        self.classes = tuple(
            c.strip() for c in (env.get("INSTANA_CLASSES") or "human,probe,unknown").split(",") if c.strip()
        )

    @property
    def token(self) -> str:
        try:
            return self.token_file.read_text().strip()
        except OSError:
            return ""

    def saas_problems(self) -> list[str]:
        """Problems that only matter if the SaaS leg is (or might be) used.
        Kept separate from `agent_problems` so choosing the agent destination
        does not fail `--check`/`--once` over a missing SaaS token nobody
        needs for that run.
        """
        out = []
        if not self.endpoint:
            out.append(
                "INSTANA_ENDPOINT is not set in registry/local.env. Instana has no universal "
                "host: it is per-tenant and per-region (an OTLP acceptor, e.g. "
                "https://serverless-<region>.instana.io). Nothing can be guessed here."
            )
        else:
            problem = scheme_problem(self.endpoint, "INSTANA_ENDPOINT")
            if problem:
                out.append(problem)
        if self.auth_mode not in ("agent-key", "api-token"):
            out.append(f"INSTANA_AUTH_MODE must be agent-key or api-token (got {self.auth_mode!r})")
        if not self.token_file.exists():
            out.append(f"token file {self.token_file} does not exist")
        elif not self.token:
            out.append(f"token file {self.token_file} is empty")
        return out

    def agent_problems(self) -> list[str]:
        """Problems with the agent leg. Deliberately does NOT include
        reachability — an unreachable agent is "not installed here", handled
        by `choose_destination` falling back to SaaS, not a config error. A
        bad scheme IS a config error regardless of reachability: refusing it
        must not depend on whether anything happens to be listening.
        """
        problem = scheme_problem(self.agent_endpoint, "INSTANA_OTLP_AGENT_ENDPOINT")
        return [problem] if problem else []

    def common_problems(self) -> list[str]:
        """Problems that apply no matter which leg is used."""
        out = []
        if not self.traces_db.exists():
            out.append(f"no trace store at {self.traces_db} — has the plane been deployed?")
        return out

    def headers(self, dest: Destination) -> dict:
        """Headers for ONE destination. Deliberately not a fixed dict: the two
        doors want different things, and building one dict for both is how a
        credential ends up on a request that never inspects it (the agent, see
        the module docstring) or a request meant for the agent silently loses
        the header the SaaS acceptor requires.
        """
        h = {"Content-Type": "application/json"}
        if dest.stamp_host_id:
            h["x-instana-host"] = self.host_id
        if dest.send_key:
            if self.auth_mode == "api-token":
                h["Authorization"] = f"apiToken {self.token}"
            else:
                h["x-instana-key"] = self.token
        return h


def load_env() -> dict:
    """registry/local.env, then the real environment on top."""
    env = {}
    path = ROOT / "registry" / "local.env"
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    # INSTANA_* plus the two store paths this reads. The store paths matter
    # because they are how anyone tests this against a fixture instead of the
    # live databases — filtering them out made `Config` claim to honour an
    # override it never saw, which is worse than not offering one.
    passthrough = ("TRACES_DB", "ANALYTICS_DB")
    env.update({k: v for k, v in os.environ.items() if k.startswith("INSTANA_") or k in passthrough})
    return env


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


def pending_traces(cfg: Config, after_ms: int, limit: int) -> list[dict]:
    """Finished traces newer than the watermark, oldest first.

    Ordered OLDEST first, unlike the UI: a forwarder is catching up, and
    advancing the watermark past a trace it has not sent is how a gap appears
    that nothing will ever go back for.
    """
    store = traces.TraceStore(cfg.traces_db)
    try:
        rows = []
        for klass in cfg.classes:
            rows += store.search(klass=klass, since_ms=after_ms + 1, limit=limit)["traces"]
        rows.sort(key=lambda r: r["startedMs"])
        return [t for t in (store.trace(r["traceId"]) for r in rows[:limit]) if t]
    finally:
        store.close()


def post(cfg: Config, dest: Destination, path: str, doc: dict, dry_run: bool) -> tuple[bool, str]:
    url = f"{dest.endpoint}{path}"
    body = json.dumps(doc, separators=(",", ":")).encode()
    if dry_run:
        return True, f"DRY RUN [{dest.name}]: would POST {len(body)} bytes to {url}"
    req = urllib.request.Request(url, data=body, headers=cfg.headers(dest), method="POST")
    try:
        # scheme_problem() enforces https, with the one narrow, explicit
        # exception of plain http to a loopback host (the agent leg); a
        # non-loopback http endpoint never reaches this line.
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - https enforced above
            return True, f"{resp.status} {resp.reason}"
    except urllib.error.HTTPError as e:
        detail = e.read(2000).decode("utf-8", "replace")
        # Acceptors answer errors with an HTML page. Printing 400 characters of
        # markup buries the one line that matters under a <table>.
        if "<html" in detail.lower():
            text = re.sub(r"<[^>]+>", " ", detail)
            detail = " ".join(text.split())[:160] or f"HTML error page ({e.code})"
        else:
            detail = detail[:300]
        hint = ""
        if e.code in (401, 403):
            hint = (
                "  <- an auth refusal. If INSTANA_AUTH_MODE=api-token, note that an API token "
                "is the REST/config credential and CANNOT ingest spans; OTLP ingestion needs "
                "the tenant's AGENT KEY."
            )
        return False, f"HTTP {e.code}: {detail}{hint}"
    except (urllib.error.URLError, OSError) as e:
        return False, f"unreachable: {e}"


def forward_traces(cfg: Config, dest: Destination, dry_run: bool, verbose: bool) -> int:
    state = read_state(cfg.state)
    after = int(state.get("lastTraceStartedMs") or 0)
    batch = pending_traces(cfg, after, BATCH)
    if not batch:
        print(f"traces [{dest.name}]: nothing new")
        return 0
    # host.id: stamped by US only on the SaaS leg, which has no other way to
    # learn the host. The agent leg supplies host identity itself (IBM's
    # docs: sending to the local agent means host.id is not needed, and
    # sending it anyway to the direct SaaS backend IS needed) — passing
    # host_id=None here is that difference made explicit, not an omission.
    doc = traces_otlp.export(batch, host_id=cfg.host_id if dest.stamp_host_id else None)
    spans = sum(len(t.get("spans", [])) for t in batch)
    if verbose or dry_run:
        print(json.dumps(doc, indent=2)[:4000])
    ok, detail = post(cfg, dest, "/v1/traces", doc, dry_run)
    print(f"traces [{dest.name}]: {len(batch)} trace(s), {spans} span(s) -> {detail}")
    if ok and not dry_run:
        state["lastTraceStartedMs"] = max(t["startedMs"] for t in batch)
        write_state(cfg.state, state)
    return 0 if ok else 1


def metric_histograms(cfg: Config, since_day: str) -> dict:
    """Our bucketed metrics as OTLP histograms.

    The bucket BOUNDARIES are our ladder, unchanged. Re-bucketing to something
    prettier would make Instana's histogram disagree with our own report, and
    the entire reason this exists is to compare the two on identical data.

    A caveat worth carrying: the counters have no per-sample timestamps, only a
    day bucket. So each day's histogram is emitted with that day's end as its
    time, which is honest at day resolution and would be a lie at any finer one.
    """
    db = sqlite3.connect(f"file:{cfg.analytics_db}?mode=ro", uri=True)
    try:
        rows = db.execute(
            "SELECT day,metric,bucket,class,SUM(n) FROM metric WHERE day>=? AND class IN "
            f"({','.join('?' * len(cfg.classes))}) GROUP BY day,metric,bucket,class",
            (since_day, *cfg.classes),
        ).fetchall()
    finally:
        db.close()

    by_key: dict[tuple, dict] = {}
    for day, metric, bucket, klass, n in rows:
        by_key.setdefault((day, metric, klass), {})[bucket] = n

    points = []
    for (day, metric, klass), buckets in sorted(by_key.items()):
        edges = sorted((b for b in buckets if b != "inf"), key=int)
        counts = [buckets.get(e, 0) for e in edges] + [buckets.get("inf", 0)]
        total = sum(counts)
        end_ns = str(int(time.mktime(time.strptime(day, "%Y-%m-%d")) + 86400) * 1_000_000_000)
        points.append(
            {
                "metric": metric,
                "point": {
                    "startTimeUnixNano": str(int(time.mktime(time.strptime(day, "%Y-%m-%d"))) * 1_000_000_000),
                    "timeUnixNano": end_ns,
                    "count": str(total),
                    "explicitBounds": [float(e) for e in edges],
                    "bucketCounts": [str(c) for c in counts],
                    "attributes": traces_otlp._attrs({"kh.class": klass}),
                },
            }
        )

    grouped: dict[str, list] = {}
    for p in points:
        grouped.setdefault(p["metric"], []).append(p["point"])
    return (
        {
            "resourceMetrics": [
                {
                    "resource": {"attributes": traces_otlp._attrs({"service.name": "kernel-hive-spa"})},
                    "scopeMetrics": [
                        {
                            "scope": {"name": "kernel-hive"},
                            "metrics": [
                                {
                                    "name": name,
                                    "unit": "ms" if name.endswith("Ms") else ("%" if name.endswith("Pct") else "1"),
                                    "histogram": {"aggregationTemporality": 2, "dataPoints": pts},
                                }
                                for name, pts in sorted(grouped.items())
                            ],
                        }
                    ],
                }
            ]
        }
        if grouped
        else {}
    )


def forward_metrics(cfg: Config, dest: Destination, dry_run: bool, verbose: bool, days: int) -> int:
    since = time.strftime("%Y-%m-%d", time.gmtime(time.time() - days * 86400))
    doc = metric_histograms(cfg, since)
    if not doc:
        print(f"metrics [{dest.name}]: nothing to send")
        return 0
    n = sum(len(m["histogram"]["dataPoints"]) for m in doc["resourceMetrics"][0]["scopeMetrics"][0]["metrics"])
    if verbose or dry_run:
        print(json.dumps(doc, indent=2)[:4000])
    ok, detail = post(cfg, dest, "/v1/metrics", doc, dry_run)
    print(f"metrics [{dest.name}]: {n} data point(s) -> {detail}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="validate configuration and exit")
    ap.add_argument("--dry-run", action="store_true", help="print what would be sent; send nothing")
    ap.add_argument("--once", action="store_true", help="one pass")
    ap.add_argument("--follow", action="store_true", help="keep forwarding")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--metric-days", type=int, default=2)
    ap.add_argument("--no-metrics", action="store_true")
    ap.add_argument("--no-traces", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the OTLP document")
    ap.add_argument("--via-agent", action="store_true", help="force the local Instana host agent (127.0.0.1)")
    ap.add_argument("--via-saas", action="store_true", help="force direct-to-SaaS (INSTANA_ENDPOINT)")
    args = ap.parse_args()

    cfg = Config(load_env())
    dest, dest_problems = choose_destination(cfg.agent_endpoint, cfg.endpoint, args.via_agent, args.via_saas)
    # The token is never printed, in any mode. Its presence and length are the
    # most that is ever said about it.
    print(f"destination  {dest.name} -> {dest.endpoint}")
    print(f"saas endpoint  {cfg.endpoint or '(unset)'}")
    print(f"agent endpoint {cfg.agent_endpoint}")
    print(
        f"auth      {cfg.auth_mode}, token {'present' if cfg.token else 'MISSING'} "
        f"({len(cfg.token)} chars) from {cfg.token_file}"
        + ("  [not sent — the agent leg does not use it, see module docstring]" if not dest.send_key else "")
    )
    print(f"classes   {', '.join(cfg.classes)}")
    print(
        f"host.id   {cfg.host_id}"
        + ("  [stamped by us]" if dest.stamp_host_id else "  [supplied by the agent, not stamped]")
    )

    # Problems are scoped to the leg actually chosen, plus whichever leg's
    # config is invalid regardless of choice (a bad agent scheme is refused
    # even while running via SaaS) and whatever applies no matter what.
    problems = list(dest_problems) + cfg.common_problems() + cfg.agent_problems()
    if dest.name == "saas":
        problems += cfg.saas_problems()
    if problems:
        print("\nNOT READY:")
        for p in problems:
            print(f"  - {p}")
        # A dry run is still useful without a live/configured destination: it
        # shows the operator exactly what the payload would be before they go
        # and arrange one. Only non-ENDPOINT problems (missing trace store, a
        # scheme refusal, a bad/missing token) still block a dry run, same
        # filter as before this destination split.
        if not (args.dry_run and len([p for p in problems if "ENDPOINT" not in p]) == 0):
            return 2

    if args.check:
        # A check that only reads local config is not a check. Everything above
        # was true of a credential Instana rejects — the wrong TYPE of token is
        # locally indistinguishable from the right one, and only the acceptor
        # can settle it. So ask it, with a well-formed but EMPTY document: this
        # proves the endpoint (and, on the SaaS leg, the key) without sending
        # one span of telemetry.
        ok, detail = post(cfg, dest, "/v1/traces", {"resourceSpans": []}, dry_run=False)
        print(f"\nlive check [{dest.name}] -> {detail}")
        if ok:
            reason = "endpoint reachable and the key was accepted" if dest.send_key else "agent endpoint reachable"
            print(f"configuration OK — {reason}")
            return 0
        if dest.name == "saas" and ("HTTP 401" in detail or "HTTP 403" in detail):
            # Only 401/403 is a credential answer. An empty `resourceSpans` is
            # a legal OTLP document that Instana's acceptor nonetheless 500s
            # on, and reading that as "bad key" sent somebody hunting for a
            # second key they already had. Auth happens before payload
            # handling, so ANY other status means the credential was accepted
            # and the complaint is about the body.
            print(
                "configuration NOT usable — this is the CREDENTIAL.\n"
                "  Instana's OTLP acceptor takes the AGENT KEY, which is UI-only:\n"
                "  Instana -> More -> Agents -> Install Agents.\n"
                f"  Put it in {cfg.token_file} and re-run."
            )
            return 1
        print(
            f"[{dest.name}] endpoint reachable — the refusal above is about the empty probe\n"
            "  document, not credentials. This check deliberately sends no spans; use\n"
            "  --dry-run to inspect a real batch, then --once."
        )
        return 0

    rc = 0
    while True:
        if not args.no_traces:
            rc |= forward_traces(cfg, dest, args.dry_run, args.verbose)
        if not args.no_metrics:
            rc |= forward_metrics(cfg, dest, args.dry_run, args.verbose, args.metric_days)
        if not args.follow:
            return rc
        time.sleep(max(10, args.interval))


if __name__ == "__main__":
    sys.exit(main())

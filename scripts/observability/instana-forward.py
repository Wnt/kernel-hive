#!/usr/bin/env python3
"""Forward our OpenTelemetry data to Instana, so the in-house UI can be compared
against a commercial one on the same traces.

    scripts/observability/instana-forward.py --check      # config only, sends nothing
    scripts/observability/instana-forward.py --dry-run    # show exactly what WOULD leave
    scripts/observability/instana-forward.py --once
    scripts/observability/instana-forward.py --follow --interval 60

ONE EGRESS POINT, ON PURPOSE. Every component could have been given an exporter
and its own credential; this reads the stores instead and is the only thing on
the box that talks to Instana. That is worth saying because it is the whole
security argument: one place to scrub, one credential to rotate, one switch to
turn the whole thing off, and one place to look when somebody asks what left the
building. N exporters would be N of each.

THIS SENDS DATA TO A THIRD PARTY. Nothing else in this repo does. The stores it
reads are already scrubbed at intake — `traces.py` refuses `exception.stacktrace`
and every other free-text field, so a stack, a typed string or a credential
handle cannot be in the database to be forwarded — but "already scrubbed" is a
property worth re-stating at the boundary rather than assumed. `--dry-run`
exists so the exact bytes can be read before any of them are sent, and it is the
recommended first run.

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
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))

import traces  # noqa: E402
import traces_otlp  # noqa: E402

DEFAULT_TRACES_DB = Path("/data/vms/streamhost/serve/traces.db")
DEFAULT_ANALYTICS_DB = Path("/data/vms/streamhost/serve/analytics.db")
DEFAULT_TOKEN = ROOT / "scripts" / "serve" / "pki" / "instana.token"
#: Where the watermark lives, so a re-run does not re-send what already went.
DEFAULT_STATE = Path("/data/vms/streamhost/serve/instana-forward.state.json")

#: Traces per request. Instana's acceptor, like every OTLP endpoint, has a body
#: limit; a private gallery never approaches it, but a first run against a
#: fortnight of history would.
BATCH = 100


class Config:
    """Everything this needs, and a clear account of what is missing.

    Read from registry/local.env (gitignored, where every deployment-local
    operator value in this repo lives) with environment overrides, so nothing
    tenant-specific is ever committed — AGENTS.md rule 1.
    """

    def __init__(self, env: dict):
        self.endpoint = (env.get("INSTANA_ENDPOINT") or "").rstrip("/")
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
        self.classes = tuple(
            c.strip() for c in (env.get("INSTANA_CLASSES") or "human,probe,unknown").split(",") if c.strip()
        )

    @property
    def token(self) -> str:
        try:
            return self.token_file.read_text().strip()
        except OSError:
            return ""

    def problems(self) -> list[str]:
        out = []
        if not self.endpoint:
            out.append(
                "INSTANA_ENDPOINT is not set in registry/local.env. Instana has no universal "
                "host: it is per-tenant and per-region (an OTLP acceptor, e.g. "
                "https://serverless-<region>.instana.io). Nothing can be guessed here."
            )
        elif not self.endpoint.startswith("https://"):
            # Refused rather than warned: this is a credential plus behavioural
            # data, and downgrading that to cleartext is not a choice a config
            # typo should be able to make.
            out.append(f"INSTANA_ENDPOINT must be https:// (got {self.endpoint.split(':')[0]}://)")
        if self.auth_mode not in ("agent-key", "api-token"):
            out.append(f"INSTANA_AUTH_MODE must be agent-key or api-token (got {self.auth_mode!r})")
        if not self.token_file.exists():
            out.append(f"token file {self.token_file} does not exist")
        elif not self.token:
            out.append(f"token file {self.token_file} is empty")
        if not self.traces_db.exists():
            out.append(f"no trace store at {self.traces_db} — has the plane been deployed?")
        return out

    def headers(self) -> dict:
        if self.auth_mode == "api-token":
            return {"Authorization": f"apiToken {self.token}", "Content-Type": "application/json"}
        return {"x-instana-key": self.token, "Content-Type": "application/json"}


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


def post(cfg: Config, path: str, doc: dict, dry_run: bool) -> tuple[bool, str]:
    url = f"{cfg.endpoint}{path}"
    body = json.dumps(doc, separators=(",", ":")).encode()
    if dry_run:
        return True, f"DRY RUN: would POST {len(body)} bytes to {url}"
    req = urllib.request.Request(url, data=body, headers=cfg.headers(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - https enforced above
            return True, f"{resp.status} {resp.reason}"
    except urllib.error.HTTPError as e:
        detail = e.read(400).decode("utf-8", "replace")
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


def forward_traces(cfg: Config, dry_run: bool, verbose: bool) -> int:
    state = read_state(cfg.state)
    after = int(state.get("lastTraceStartedMs") or 0)
    batch = pending_traces(cfg, after, BATCH)
    if not batch:
        print("traces: nothing new")
        return 0
    doc = traces_otlp.export(batch)
    spans = sum(len(t.get("spans", [])) for t in batch)
    if verbose or dry_run:
        print(json.dumps(doc, indent=2)[:4000])
    ok, detail = post(cfg, "/v1/traces", doc, dry_run)
    print(f"traces: {len(batch)} trace(s), {spans} span(s) -> {detail}")
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


def forward_metrics(cfg: Config, dry_run: bool, verbose: bool, days: int) -> int:
    since = time.strftime("%Y-%m-%d", time.gmtime(time.time() - days * 86400))
    doc = metric_histograms(cfg, since)
    if not doc:
        print("metrics: nothing to send")
        return 0
    n = sum(len(m["histogram"]["dataPoints"]) for m in doc["resourceMetrics"][0]["scopeMetrics"][0]["metrics"])
    if verbose or dry_run:
        print(json.dumps(doc, indent=2)[:4000])
    ok, detail = post(cfg, "/v1/metrics", doc, dry_run)
    print(f"metrics: {n} data point(s) -> {detail}")
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
    args = ap.parse_args()

    cfg = Config(load_env())
    problems = cfg.problems()
    # The token is never printed, in any mode. Its presence and length are the
    # most that is ever said about it.
    print(f"endpoint  {cfg.endpoint or '(unset)'}")
    print(
        f"auth      {cfg.auth_mode}, token {'present' if cfg.token else 'MISSING'} "
        f"({len(cfg.token)} chars) from {cfg.token_file}"
    )
    print(f"classes   {', '.join(cfg.classes)}")
    if problems:
        print("\nNOT READY:")
        for p in problems:
            print(f"  - {p}")
        # A dry run is still useful without an endpoint: it shows the operator
        # exactly what the payload would be before they go and find a URL.
        if not (args.dry_run and len([p for p in problems if "ENDPOINT" not in p]) == 0):
            return 2
    if args.check:
        print("\nconfiguration OK")
        return 0

    rc = 0
    while True:
        if not args.no_traces:
            rc |= forward_traces(cfg, args.dry_run, args.verbose)
        if not args.no_metrics:
            rc |= forward_metrics(cfg, args.dry_run, args.verbose, args.metric_days)
        if not args.follow:
            return rc
        time.sleep(max(10, args.interval))


if __name__ == "__main__":
    sys.exit(main())

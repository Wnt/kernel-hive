# Instana view inventory — what each view would need from us

**The question this answers is NOT "which Instana views should we rebuild".**
That judgement is premature, and this document exists because it is. The
operator put it plainly: *Instana has tons of views and we don't yet populate
the data in there in a way that I could tell which views are going to be useful
for us in long term.*

So this is the INPUT to that judgement. For each view: what it consumes, whether
we feed it today, and what feeding it would cost. A view nobody can see data in
cannot be judged; a view that is structurally impossible here should stop taking
up room in the decision.

Read [`docs/ANALYTICS.md` §8.2](../ANALYTICS.md) first for WHY Instana is here at
all — a **benchmark, not a dependency, and a temporary one**. Nothing below is an
argument for keeping it.

**The clock.** The Instana UI reported on 2026-08-31 that this tenant is a trial
expiring in 14 days. Every EMPTY row is a view the operator can only evaluate if
data lands inside that window, which is why §6 orders the fixable rows by cost
rather than by how interesting they sound.

**This is a living document.** Rewrite rows as things land; never append a dated
annex that contradicts the table.

**Every number below is a POINT-IN-TIME OBSERVATION, not a standing fact.**
Unless a row says otherwise it was read from the live tenant on **2026-08-31
~22:05 UTC, against the fleet as deployed at `main@4d031882`**, and it may
already be wrong — the durable part of a row is its CLASSIFICATION, the count
is evidence for that classification on one day. Two things move these numbers
without anybody editing this file: the trial window ages data out from under
them, and until 2026-09-01 the only path that fed half of them was run by hand
(§2), so a "0 in 24 h" could as easily mean "nobody forwarded" as "nothing
happened. That exact confusion has already been read back as current fact once:
the Custom-events row's "0 CUSTOM/24 h, the served bundle contains zero
occurrences of `reportEvent`" was true of the bundle deployed on 2026-08-31 and
was contradicted by a later run that observed **16 CUSTOM beacons**, once the
SPA carrying that call had been deployed. **Re-read before quoting; do not cite
a count in a measurement doc without repeating the measurement.**

## 1. How each row is classified

| | Means |
|---|---|
| **POPULATED** | We already feed it. The operator can judge its usefulness today, in the UI, with no work first. |
| **EMPTY, FIXABLE** | The view would work for this lab; our data is missing or mislabelled. The actionable rows — each states what is missing and roughly what supplying it costs. |
| **N/A** | Cannot apply to a single-box museum gallery. Say so and stop; ruling these out shrinks the surface, which is itself the point. |
| **POPULATED BUT UNINFORMATIVE** | We feed it and it still tells us nothing. **The highest-value rows here** — views we never need to rebuild in `/admin/observability`, where the work is already done and the answer is "don't". |

## 2. What actually reaches Instana — four paths, not one

`docs/ANALYTICS.md` §8.1 calls `instana-forward.py` "one controlled thing that
decides to leave the box". True of the *box*, and not the whole picture of what
this repo sends IBM. Knowing which path a view depends on is most of knowing
what fixing it costs:

| # | Path | Carries | Runs |
|---|---|---|---|
| 1 | **Browser EUM agent** → IBM SaaS, direct from each visitor's tab | page loads, page transitions, HTTP calls, resource loads, JS errors, sessions, identity, geo/browser/OS | continuously, every visit |
| 2 | **`instana-forward.py`** → host-agent loopback (`127.0.0.1:4318`) or SaaS | OTel spans from `traces.db` **and** metric histograms from `analytics.db`'s `metric` table | `kh-instana-forward.timer`, every 5 min, **once the operator enables it** (§2.1) |
| 2b | **`trace-ship.py`** → the box's own `/traces` | the daemon's spooled spans, out of `stations/<id>/traces/` and into `traces.db`, so path 2 has anything to forward | `kh-trace-ship.timer`, every 2 min, same enable step |
| 3 | **`scripts/serve-https-spa.sh`** → Instana Web REST API, from the deploy machine | built SPA **source maps** (`PUT …/sourcemap-upload/…`), and republishing the pinned EUM agent JS self-hosted | every SPA deploy |
| 4 | **IBM's host agent on labhost** → SaaS, IBM's own binary | host, process, LXC and agent infrastructure data | continuously, and **not this repo's to switch off** |

Path 2 forwards metrics as well as spans, so `analytics.db` is not purely local,
contrary to how §8's "third telemetry plane" framing reads at a glance. Path 3
is not mentioned in §8.1/§8.2 at all.

**Path 2 was manual until 2026-09-01, and that is the health warning on every
count in this document.** Any view it feeds was stale by default — including
while the observations in §4 were being taken. It carried a second, quieter
fault: the watermark was the highest `started_ms` it had shipped, so a trace
whose browser half flushed after a run (up to a `sink.ts` 20 s interval later,
carrying an EARLIER start time) was never selected again, and those spans were
lost for good. That is a direct cause of orphaned calls with no parent in the
tenant, and it means **span and call counts read before 2026-09-01 are floors,
not measurements.** Both are fixed: the watermark is now the store's ingest
sequence (`traces.py`'s `ingest_seq`), and the two carriers run on timers.

### 2.1 Arming the two timers — the operator's step

Landing the code does not start anything (AGENTS.md rule 11). `box-deploy.sh
--apply` installs the four unit files; enabling them is a deliberate act,
because path 2 is the one thing in this repo that sends data to a third party.

```sh
scripts/dev/box-deploy.sh --apply                       # installs the units + daemon-reload
ssh lab 'systemctl restart osgallery-https'             # picks up traces.py's ingest_seq column
ssh lab 'systemctl enable --now kh-trace-ship.timer kh-instana-forward.timer'
ssh lab 'systemctl list-timers kh-*'                    # next/last fire times
ssh lab 'journalctl -u kh-instana-forward -n 40 --no-pager'   # watermark + backlog per run
```

The restart is a **separate decision and not a precondition** — the serving
plane is long-running, so between the deploy and a restart the old code keeps
writing trace rows with no ingest sequence, and rather than leave that as a
caveat somebody has to remember, `TraceStore` sweeps any unsequenced row to the
head of the order every time the store is opened (which the forwarder does on
every run). The restart just stops that healing being needed. A first run is
worth doing by hand — `--dry-run` shows the exact bytes, `--once` sends them —
before the timer is armed.

Turning it back off: `ssh lab 'systemctl disable --now kh-instana-forward.timer
kh-trace-ship.timer'`. Clearing `INSTANA_ENDPOINT` in `registry/local.env` also
works for the egress half alone — `--scheduled` treats an unconfigured box as a
logged no-op with exit 0, so an unarmed feature never presents as a failing
unit. Nothing needs restarting for either change; the timers are independent of
the serving plane.

**Never sent:** `probes.json` (the Rust feature-reach counters),
`clientlog.jsonl`, `usage-stats.json`, and every log line this system produces.
There is no OTLP `/v1/logs` exporter, syslog forwarder or journald shipper in the
tree; journald keeps logs on the box.

**Filtered on purpose, in the tab only.** The browser agent ignores our own
telemetry endpoints (`/traces`, `/analytics`, `/coverage`, `/clientlog`,
`/usage`, `/clientcmd`) so Instana never reports a beacon about a beacon. The
Python plane still opens `server` spans for `/clientcmd` and `/clientlog` and
path 2 forwards them: on 2026-08-31 they were the **largest single family of
traces in the tenant** (74 + 8 of a 200-trace sample). Circular monitoring is
closed in the browser and open on the server.

## 3. Three facts that decide most of the table

1. **Instana only builds a trace from an ENTRY span.** IBM's own definition —
   the first span of a service, the Dapper "server span"
   (`0279-tracing-in-instana.md:192-193`). Established here by experiment, not
   inference (commit `2bb51d06`): `internal`-kind spans ingest with a 200,
   register a service, and produce no trace and no endpoint. A trace with no
   `Server` span has no owning service and lands under **`Unspecified`**.
2. **Services and endpoints are auto-discovered from calls, never declared**
   (`0251-monitoring-applications.md:490-491`), each endpoint typed
   automatically as BATCH / SHELL / DATABASE / HTTP / MESSAGING / RPC
   (`0251:639`). We declare nothing; what Instana shows is what our span names
   happen to make.
3. **Geo works because we do not proxy visitors** — it is derived from the
   visitor IP against MaxMind (`0250-monitoring-websites.md:236-240`).

## 4. The inventory

Counts are **24-hour windows read 2026-08-31 ~22:05 UTC**, fleet at
`main@4d031882`, unless a row states otherwise. They are observations of that
moment and several are known to have moved since — read the point-in-time
warning in §1's preamble and §7's window caveat (a 7-day window returns *fewer*
rows than a 1-hour one) before quoting any of them anywhere.

### 4.1 Website Monitoring — the richest surface we have

Beacon types are page loads, HTTP requests, resources and JavaScript errors
(`0250:175-177`); the API's own 400 body gives the full enum as `PAGELOAD,
RESOURCELOAD, HTTPREQUEST, ERROR, CUSTOM, PAGE_CHANGE`.

| View | Us | Class | Cost to fix |
|---|---|---|---|
| Page loads | 15 PAGELOAD/24 h | **POPULATED** | — |
| ↳ page NAME on page loads | **blank or `*` on 14 of 15**; only one carried `/os/:osId` | **EMPTY, FIXABLE** | small — the bootstrap's `ineum('page', …)` is losing the race with the page-load beacon |
| ↳ join keys on page loads | **`meta: {}` on all 15.** `kh.sessionId`/`kh.bundle` are set in stage 2, after the beacon has gone | **EMPTY, FIXABLE** | small, same change: move the two `meta` calls into `index.html`'s inline bootstrap. Without them a page-load beacon cannot be joined to our own store |
| Page transitions | 14 PAGE_CHANGE/24 h with route patterns (`/os/:osId`, `/`) and **full meta** (`kh.sessionId`, `kh.bundle`, `kh.page.transitionMs`, `kh.route.param.osId`) | **POPULATED** | — |
| HTTP calls | **4001 HTTPREQUEST/24 h**, full meta on all sampled | **POPULATED** | — |
| ↳ backend correlation | `backendTraceId` on **200 of 200** sampled HTTP calls and 7 of 15 page loads, from the `<meta name="traceparent">` tag (`TRACE-CONTEXT.md` §4) | **POPULATED** | — |
| Resource loads | 61 RESOURCELOAD/24 h | **POPULATED** | — |
| Sessions | `trackSessions`; a `localStorage` id (`0250:472-477`); `sessionId` on every beacon sampled | **POPULATED** | — |
| Users / Impacted Users | real account id **and display name** on 10 of 14 page transitions and 200 of 200 HTTP calls — never on a page load | **POPULATED** | small: the page-load gap is the bootstrap race above |
| JS errors | **0 ERROR/24 h**, though `wrapEventHandlers` and `wrapTimers` are both ON — deliberately, because a WebGL/RAF/pointer app throws where `window.onerror` never looks | **EMPTY** — and we cannot tell "nothing threw" from "nothing arrives" | ~zero: provoke one error on staging and look |
| ↳ unminified stacks | source maps uploaded every deploy (path 3) | **POPULATED BUT UNEXERCISED** — with 0 error beacons the upload has never been read | — |
| Custom events | **POPULATED since the SPA carrying it was deployed.** 0 CUSTOM/24 h on 2026-08-31 because `inputTrace.ts`'s `ineum('reportEvent','kh.input.sampled', …)` (commit `4d031882`) was written but not yet in the served bundle; a later run observed **16 CUSTOM beacons**. The 2026-08-31 reading and its "the served bundle contains zero occurrences of `reportEvent`" are both **superseded** — kept here only because that pair of figures was quoted as current fact after it stopped being true | **POPULATED** | — (done: the deploy) |
| Geo / browser / OS | every beacon: **the same one city**, Chrome or HeadlessChrome, Mac OS X, `4g`; visitor IP truncated to `/24` | **POPULATED BUT UNINFORMATIVE** — §5 | — |
| Human vs. our own probe fleet | **6 of 15 page loads were `HeadlessChrome`** — this lab's own browser probes, counted as visitors | **POPULATED BUT WRONG** — our plane separates this with its client-class dimension (`ANALYTICS.md` §9); Instana structurally cannot | medium, and no clean vendor answer: a `meta` flag plus manual Analyze filtering, which still does not fix Smart Alerts or Impacted Users |

**A budget worth knowing before loading this surface up:** 128 beacons/10 s,
4096/10 min, 8096/page, XHR-fetch 32/10 s per tab. That budget is why circular
monitoring is filtered rather than tolerated.

### 4.2 Application Monitoring

| View | Us | Class | Cost to fix |
|---|---|---|---|
| Services | exactly 3: `kernel-hive-spa` (openTelemetry), `kernel-hive-serve` (openTelemetry + pythonRuntimePlatform), and one literally named **`Unspecified`** | **POPULATED, and a third of it is wrong** | see the next row |
| ↳ the `Unspecified` third | **96 `input.edge` traces in 24 h, all `Unspecified`**, carrying 145 calls. Both fixes are **in source and not in the running binary**: `trace/mod.rs:338` stamps `kh.service: kernel-hive-daemon`, `trace_session.rs:223` makes `input.dispatch` `Kind::Server`. Our own store proves the fleet predates them — every stored `input.dispatch` is still `internal` and no span anywhere carries `kh.service: kernel-hive-daemon` | **EMPTY, FIXABLE — the top row here** | the expensive one: `cargo build --release`, canary, risk-ordered `fleet_rollout.py` promotion, then `trace-ship.py` and `instana-forward.py` by hand. Converts a whole third of the traces from an unattributable bucket into a named service |
| Traces / trace view | 200 traces/24 h: `input.edge` 96, `serve.clientcmd` 74, `serve.page` 8, `serve.clientlog` 8, `serve.kh.deploy-hint` 7, `serve.signal` 3, `serve.walkin.state` 3, `serve.restore` 1 | **POPULATED** | — |
| **Endpoints** | **13 endpoints exist** — `serve.clientcmd`, `serve.analytics`, `input.edge`, `http.client.request` … one per span name, confirmed by grouping calls on `endpoint.name` | **POPULATED — but named after our span names, not HTTP routes** | small-to-medium if route-level endpoints are wanted: give entry spans an `http.route`. Judge whether span names are good enough FIRST — they may be better than routes here |
| Calls / latency per service | `kernel-hive-serve` 43→99 calls/h at 1.3 ms mean; `Unspecified` 145 calls at 2.6-4.2 ms; **`kernel-hive-spa` 6 calls** | **POPULATED** | — |
| Service map / dependencies | three services, one of them `Unspecified`; no database, no queue, no third-party call, no second host | **POPULATED BUT UNINFORMATIVE** — §5 | — |
| Analyze / Unbounded Analytics | `analyze/traces` and `analyze/call-groups` both return real rows; grouping works on `service.name`, `endpoint.name`, `call.name` | **POPULATED** | — |
| Application Perspectives | only the default "All Services" exists | **EMPTY, FIXABLE** | minutes of operator UI — a mutating tenant change, deliberately not done by this read-only pass |
| Metric histograms from `analytics.db` | forwarded by path 2 with our own bucket ladder — whose counters carry only a **day** bucket | **POPULATED BUT UNINFORMATIVE** — any Instana series over them is one point per day, strictly less than `reach-report.py` already shows. Nobody has yet found where they surface in the UI, and it does not matter much | — |

### 4.3 Infrastructure — populated by IBM's agent, not by us

| View | Us (read 2026-08-31) | Class |
|---|---|---|
| Hosts | exactly 1 host node — labhost itself — with its Instana agent beside it | **POPULATED** |
| Processes | 27 process entities | **POPULATED** |
| Containers (LXC) | 4 (`950`, `951`, `952`, `210`) | **POPULATED** |
| Topology / Dynamic Graph | 49 nodes across 9 plugin kinds | **POPULATED** |
| Host ↔ trace correlation | the agent supplies `host.id` itself on path 2's agent leg | **POPULATED** |
| **eBPF / native profiling of the Rust daemon** | not enabled. Instana profiles native processes with `INSTANA_PROFILING=1` at process start, kernel ≥5.10 and glibc ≥2.26 (`0258-profile-processes.md:257-278`) | **EMPTY, FIXABLE — the most interesting row in the document.** This is the **one place a vendor could tell us something about `streamhost` we did not tell it first**; everything else Instana knows about the daemon, we sent it. It bears directly on the open keyboard-lag investigation. **Cost: one systemd drop-in and a restart on ONE canary station**, plus checking the two floors. Do not fleet-wide it to find out |
| Docker / container dashboards | no Docker on the box | **N/A** |
| vSphere | that sensor monitors VMware; this is Proxmox | **N/A** |
| A sensor for the thing this lab is about | **there is no Instana sensor for QEMU or any emulator**, and the guests are deliberately not traced from inside (`TRACE-CONTEXT.md` §6) | **N/A — permanently.** Emulator-internal visibility was never something a vendor could shortcut; it is `streamhost`'s own span plane's job and always will be |

### 4.4 Synthetics — N/A here, and blocked anyway

A synthetic test runs from a **PoP** — an agent deployed somewhere that registers
itself as a location (`0257-synthetic-monitoring.md:99-101`) — to test
availability "in the absence of real user traffic" (`0257:35-36`).

- `GET /api/synthetics/settings/locations` → `200 []`: no PoP exists.
- `GET /api/synthetics/settings/tests` → **403**: this trial does not entitle
  Synthetics. An access failure, not a measured zero.

**Class: N/A for this tenant.** An uptime check against the public gallery
domain is the one genuinely applicable use, and the tenant will not let us try.

### 4.5 Events, Alerting, SLO

| View | Us | Class | Cost |
|---|---|---|---|
| Events feed | **81 events in 7 days**, all `entityType: INFRASTRUCTURE`: `online` 51, `offline` 19, `Change detected` 5, `System load too high` 3, `Abnormal termination` 3 — an honest reflection of a lab whose stations are routinely stopped, paused and rolled | **POPULATED** | — |
| Application / website events | zero of either kind | **EMPTY, FIXABLE** | tenant configuration only, no instrumentation |
| Smart Alerts | none configured; would derive entirely from planes already ingested | **EMPTY, FIXABLE (config only)** | minutes — but see the next two rows before spending them |
| ↳ their value here | 15 page loads a day, 6 of them our own probes. IBM's own rule: no beacon for 3 h closes any active alert (`0250:1153-1154`) — which describes this gallery most nights | **would be UNINFORMATIVE if filled** | — |
| SLOs | `GET /api/settings/slo` → `{"items":[],"totalHits":0}`. SLOs bind to entity types that already exist — applications, websites, infrastructure (`0262:97,132-133`) | **EMPTY, FIXABLE (config only)** | minutes; a website-Apdex SLO needs only beacons we already send |
| Adaptive thresholds | require **≥14 days of continuous history** before the forecast is trusted (`0266:38-40`) | **N/A for this tenant** — the trial expires in 14 days, so this view cannot be evaluated in the window that exists, whatever we feed it | don't spend the window trying |

### 4.6 Log management — nothing to see, on purpose

Instana collects logs via tracers, container sensors or OpenTelemetry, the last
needing explicit configuration (`0248-logging.md:16-26`).

We ship no logs anywhere. No log-query endpoint we tried answered
(`/api/logs/analyze/entries`, `/api/logs`, `/api/logs-monitoring/analyze/entries`,
`/api/logs/entries` — all 404), so the zero is established from the repo side,
not the API side.

**Class: EMPTY.** Fixable by enabling log collection in the labhost agent — a
box-level operator action, not a repo change. Worth doing only to evaluate
log↔trace correlation, a real Instana strength this lab has never tested.

### 4.7 The N/A block — most of the product

Ruling these out is the cheapest value here: it is the bulk of Instana's surface
area, and none of it needs a decision.

| Surface | Why not |
|---|---|
| Kubernetes, OpenShift, Cloud Foundry/Tanzu | no orchestrator; one Proxmox box with LXC and QEMU |
| Serverless — Lambda, Azure Functions, Cloud Run | nothing runs off-box |
| AWS / Azure / GCP / Alibaba sensors (~150 doc sections) | no cloud account is monitored |
| Managed databases, message queues, Kafka, JMS | none exist; the stores are SQLite files on the box |
| Mobile app monitoring | needs an iOS/Android agent as an app dependency (`0249:20-22`); this is a web SPA |
| Business processes, Business metrics, Business view dashboards | no business transactions |
| GenAI / LLM observability, AI gateway | nothing here calls a model at runtime |
| IBM Concert / Turbonomic / Kubecost / DBmarlin | no such products |
| Prometheus, JMX, Java/.NET trace SDKs | no JVM, no CLR, no Prometheus |
| Custom dashboards | not a data need — a UI over the rows above; anything POPULATED can be dashboarded today |

## 5. Populated and still uninformative — the rows we never rebuild

- **Geo, city, country, connection type.** Every beacon resolves to the same
  single city — this gallery is one household and its invited guests, so a world
  map is decoration. `/admin/observability` should not grow one.
- **Browser/OS breakdown.** Two entries, one of which is our own headless probe
  fleet.
- **The service map.** Three nodes, one of them `Unspecified`, and it becomes a
  clean graph of three after the daemon row lands. Its whole value is dependency
  discovery in a system too large to hold in one head; this system is 61 copies
  of one binary behind one serving plane. Enjoy it for five minutes; never
  rebuild it.
- **Impacted Users and Smart-Alert baselines.** At ~15 page loads a day, 40 % of
  them synthetic, every statistical feature is measuring noise.

The pattern: Instana's population-scale features need a population. This lab has
a handful of humans and a fleet of 61 machines, and its interesting variance is
per-station, not per-visitor. That is a real finding about **which half of a
commercial APM is worth copying** — the trace and flame-graph half, not the RUM
aggregate half.

## 6. The EMPTY-FIXABLE queue, cheapest first

1. ~~**Deploy the SPA.**~~ **DONE.** The custom-event call (`reportEvent`) is
   shipped and CUSTOM beacons now arrive (§4.1). The bootstrap change in row 2
   still wants a deploy of its own.
2. **Move page name, `kh.sessionId` and `kh.bundle` into the inline bootstrap.**
   Today 14 of 15 page loads are unnamed and unjoinable. **Cost: a small SPA
   change**, riding the same deploy.
3. **Provoke one JavaScript error on staging.** **Cost: ~zero**, and until an
   ERROR beacon exists we cannot tell an empty view from a broken pipe — nor has
   the source-map upload we run on every deploy ever been read.
4. **Turn on eBPF profiling for `streamhost` on ONE canary station.** **Cost: a
   systemd drop-in and a restart**, plus checking kernel ≥5.10 / glibc ≥2.26.
   The only row where a vendor can tell us something we did not tell it first.
5. **Rebuild and roll the daemon** so `input.edge` stops being `Unspecified`.
   **Cost: build + canary + a risk-ordered fleet promotion** — the most
   expensive row, and the one that finally puts the input→pixel flame graph in
   front of a commercial APM. It used to end in "and then two hand-run
   scripts"; since 2026-09-01 the two carriers are on timers (§2.1), so the
   fresh spans reach the tenant on their own within ~7 minutes of the rollout.
6. Then, if the trial still has days: one Application Perspective and one SLO
   (operator UI, minutes each).

## 7. Traps found while measuring

- **`analyze/*` `totalHits` is NOT comparable across window sizes.** Measured
  within one minute on 2026-08-31: `windowSize` 1 h → 95 traces, 24 h → 270,
  **7 d → 48**. A longer window returning fewer rows means this number answers
  "is there data" and never "how much". A ~14-day window returns zero outright.
  Read 24 h, and never quote a multi-day count as a volume.
- **The same applies to beacons.** A 7-day query reported PAGE_CHANGE 0 while
  the 24-hour query reported 14. An "empty" view read over a long window may
  simply be the wrong question — this is how somebody concludes the whole
  integration is broken.
- **`endpoint: null` in `analyze/traces` does not mean "no endpoints".** It is
  an unfilled response field; grouping `analyze/call-groups` on `endpoint.name`
  returns 13 real endpoints for the same data. Two hours can go into "fixing"
  an endpoint model that was never broken.
- **`scripts/serve/pki/` is gitignored and per-checkout**, so a fresh `wt.sh
  new` sandbox has **no Instana token**. Read it from the shared clone at
  `/home/wnt/kernel-hive/scripts/serve/pki/instana.token`; the credential is not
  missing.

## 7a. `backendTraceId` — how a beacon joins a backend trace, from the agent's own bytes

This is the mechanism every RUM↔trace row in §4 depends on, and **the vendor's
documentation of it is wrong twice over**, so the authority here is the pinned
agent build, read out of the self-hosted
`/data/vms/streamhost/serve/webroot/vendor/instana-eum.min.js` (v1.8.1), and
beacons captured off the wire with `scripts/visitor-sim/beacon-probe.mjs`.

The two contradicting doc passages, both in `0250-monitoring-websites.md`:

> (a) "If `enableW3CHeaders` is enabled … First, extract the **tracestate**
> value from the current page's metadata traceparent and use it. If you cannot
> retrieve tracestate, a 16-character long string … is generated."
>
> (b) "the Instana website monitoring script … parses the traceparent and
> extracts the **parent-id** as backendTraceId."

Neither is a usable spec. What the agent actually does, at init, in this order:

```
backendTraceId = <whatever ineum('traceId', …) set>
              || <the 'intid' Server-Timing entry on the NAVIGATION timing entry>
if (enableW3CHeaders && <meta name="traceparent"> parses)
    backendTraceId = the meta's PARENT-ID          // 16 hex — the SPAN id
```

Three consequences worth more than either doc passage:

1. **`tracestate` is never read.** The whole shipped bundle contains exactly one
   occurrence of the string, inside the function that *writes* request headers.
   Passage (a) is fiction for this build: injecting a
   `<meta name="tracestate" content="in=…">`, or sending a `tracestate` response
   header, changes nothing at all. Do not spend a day on it, as was nearly spent.
2. **`ineum('traceId', …)` is not "ignored when W3C headers are on"** — it *is*
   honoured, and then unconditionally overwritten two lines later by the meta
   tag. Same outcome, different reason, and the difference matters if you are
   trying to reason about a future agent build.
3. **Passage (b) is right, and that is the bug.** Our traces are keyed by the
   32-hex TRACE id — `SELECT COUNT(*) FROM span WHERE length(trace_id)=16`
   returns 0, and structurally always will — so a page-load beacon carrying a
   16-hex span id resolves to nothing, forever. Measured before the fix:
   `ty pl` with `bt=7a0c8fb357f0a61f`, against a page whose meta traceparent was
   `00-cefd3b7a93434c60151ea2ee6c2ad496-7a0c8fb357f0a61f-01`. Zero rows.

**The fix is `ineum('enableW3CHeaders', false)`** in spa/index.html's bootstrap,
which lets the `Server-Timing: intid;desc=<32-hex trace id>` fallback win — a
header `scripts/serve/tracing_http.py` already emits on the very response that
served the document. After: `ty pl` carries
`bt=38ab72035bb1f7894e6ecb7ba49020a5`, the meta's trace id, resolving to that
page load's own `serve.page` span.

**XHR correlation does not depend on that flag**, which is the thing the docs
make you fear changing. An `xhr` beacon's `bt` comes from the RESOURCE timing
entry's `Server-Timing: intid`, on a code path that never consults it — verified
unchanged across the flip in the same captures. The flag governs only whether
the agent *also* appends `traceparent`/`tracestate` to outbound requests, which
for us was pure harm: those appends collided with `khFetch`'s own real
`traceparent` (see that module's "THE INSTANA COLLISION"). A beacon whose `bt`
is absent entirely — `gallery-manifest.json`, `boot/index.json` — is correct, not
a fault: those routes are outside the tracing allowlist, so there is no server
span and no `Server-Timing` to read.

**Nothing on our side was added for the vendor.** The meta tag, `traceresponse`
and `Server-Timing` are all pre-existing parts of our own trace-context plane
(`docs/lab/TRACE-CONTEXT.md` §4, §8). The fix removed a vendor flag; it did not
introduce a dependency on vendor behaviour.

### Re-measuring this

`scripts/visitor-sim/beacon-probe.mjs` drives one real credentialed page load,
captures every beacon POST to the vendor's reporting host, and resolves each
`bt` against `traces.db` itself. It exits non-zero when a page-load beacon
carries no `bt`, when any `bt` resolves to nothing, or when an outbound
`traceparent` arrives comma-joined. Run it after ANY change to the traceparent
meta injection, the `Server-Timing` header, the `ineum(...)` bootstrap, or the
pinned agent version:

```sh
cd scripts/visitor-sim && node beacon-probe.mjs          # public gallery
node beacon-probe.mjs --url https://<SH_HOST_IP>:8443 --insecure   # the LAN origin
```

It needs a credentialed session (the gallery answers 401 to an anonymous `/`);
`docs/lab/VISITOR-SIM.md` covers making one.

## 7b. The trap that silently ships ZERO telemetry

**A bare `npm run build` in `spa/` produces a bundle with Instana entirely
disabled, and `serve-https-spa.sh deploy` does not rebuild.** Only
`serve-https-spa.sh build` exports `VITE_INSTANA_WEBSITE_KEY` /
`VITE_INSTANA_EUM_REPORTING_URL` (from `registry/local.env`) around its `vite
build`. Without them Vite leaves the raw placeholders in the emitted HTML and
`spa/index.html`'s bootstrap takes its documented no-key path: no `ineum` stub,
no vendor script tag, no beacon at all.

So the sequence **"run the quality gate, then deploy"** — and the gate runs
`npm run build` — publishes a keyless bundle over a keyed deployment, with no
error anywhere. That happened on 2026-09-01 and cost a full debugging cycle
chasing beacons that were never sent, while every server-side header was
provably correct.

`deploy` now refuses this (`check_dist_is_publishable` in
`scripts/serve-https-spa.sh`), on two independent questions:

| Condition | Behaviour |
|---|---|
| `dist/index.html` still holds a `%VITE_…%` placeholder **and** `INSTANA_WEBSITE_KEY` is set here | **refuses**, naming the placeholders and the one command that fixes it |
| placeholders present, **no** key configured | deploys, with a loud NOTE. The keyless build is a documented, legitimate fallback for a contributor without `registry/local.env` — it just may never be published *silently* by a machine that has the key |
| `dist/` older than `spa/src`, `index.html`, `package.json` or `vite.config.ts` | **refuses**; `ALLOW_STALE_DIST=1` overrides for a deliberate rollback |

**The correct incantation remains `serve-https-spa.sh build && serve-https-spa.sh
deploy`.** If you ran `npm run build` for any reason — a gate, a type check, a
test — you must rebuild through the script before deploying.

## 8. Two things in this repo that these measurements contradict

Landed here rather than left in a transcript, since a caveat stated only in chat
is assumed away:

- **The browser↔daemon trace join HAS now been exercised.**
  `docs/lab/TRACE-CONTEXT.md` §3.1 and `docs/ANALYTICS.md` §8.1 both still say no
  visit has ever used it. On 2026-08-31 the store holds 8 `streamhost.session`
  spans, **3 of them with `kh.trace.joined = 1`**. The hop works; those two
  sections are stale and should be corrected by whoever next edits them.
- **`instana-forward.py`'s docstring says the browser service reports
  `calls.sum = 0` forever.** It no longer does — `kernel-hive-spa` shows 6 calls
  in the sampled window. The mechanism it describes (only entry spans build
  traces) still holds; the specific consequence has moved on.

## 9. How to re-measure this (read-only)

```bash
TOKEN=$(cat /home/wnt/kernel-hive/scripts/serve/pki/instana.token)
BASE=$(grep '^INSTANA_API_BASE=' registry/local.env | cut -d= -f2- | tr -d '"')
NOW=$(($(date +%s)*1000))

# traces — which services and span names exist, 24 h
curl -s -X POST "$BASE/api/application-monitoring/analyze/traces" \
  -H "authorization: apiToken $TOKEN" -H 'content-type: application/json' \
  -d "{\"timeFrame\":{\"windowSize\":86400000,\"to\":$NOW}}"

# calls grouped by service / endpoint / call name (granularity is SECONDS,
# and windowSize must be at least twice it)
curl -s -X POST "$BASE/api/application-monitoring/analyze/call-groups" \
  -H "authorization: apiToken $TOKEN" -H 'content-type: application/json' \
  -d "{\"timeFrame\":{\"windowSize\":86400000,\"to\":$NOW},
       \"group\":{\"groupbyTag\":\"endpoint.name\"},
       \"metrics\":[{\"metric\":\"calls\",\"aggregation\":\"SUM\",\"granularity\":3600}]}"

# beacons — one call per type: PAGELOAD RESOURCELOAD HTTPREQUEST ERROR CUSTOM PAGE_CHANGE
curl -s -X POST "$BASE/api/website-monitoring/analyze/beacons" \
  -H "authorization: apiToken $TOKEN" -H 'content-type: application/json' \
  -d "{\"timeFrame\":{\"windowSize\":86400000,\"to\":$NOW},\"type\":\"PAGELOAD\"}"

# infrastructure, events, SLOs
curl -s -H "authorization: apiToken $TOKEN" "$BASE/api/infrastructure-monitoring/topology"
curl -s -H "authorization: apiToken $TOKEN" "$BASE/api/events?from=$((NOW-604800000))&to=$NOW"
curl -s -H "authorization: apiToken $TOKEN" "$BASE/api/settings/slo"
```

**Mutating calls are out of bounds** unless the operator asks: creating a
website, a perspective, an SLO or a synthetic test changes the tenant. This
inventory is a reading exercise.

## 10. Tally

Classifications, current; the counts they were derived from are the 2026-08-31
point-in-time readings (§1). One row has moved since that date: Custom events,
from EMPTY, FIXABLE to POPULATED, once the SPA carrying `reportEvent` shipped.

| Class | Rows | Where |
|---|---|---|
| POPULATED | 21 | §4.1 (10), §4.2 (6), §4.3 (5) |
| EMPTY, FIXABLE | 8 | §4.1 (2), §4.2 (2), §4.3 (1), §4.5 (3) |
| POPULATED BUT UNINFORMATIVE | 5 | geo, browser/OS, the service map, the unexercised source maps, the forwarded metric histograms |
| N/A | 14 | Synthetics, adaptive thresholds, the emulator sensor gap, Docker, vSphere, and §4.7's ten surfaces |
| EMPTY, nothing to fix yet | 2 | ERROR beacons (until one is provoked), log collection |

The shape of that tally is the finding. Instana's RUM and infrastructure halves
are well fed and mostly tell us what we already know. Its application half is
genuinely populated too — services, endpoints, calls and latency all exist —
with one real hole: a third of our traces are unattributed because a committed
fix has not been rolled. And the single capability worth the most is the one we
have not tried at all: eBPF profiling of the daemon, which is the only place in
this whole surface where the vendor knows something we did not hand it.

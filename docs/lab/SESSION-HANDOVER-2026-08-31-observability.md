# Session handover — observability, 2026-08-31

**Read this before touching anything under `spa/src/analytics/`,
`scripts/serve/tra*`, `scripts/observability/`, or `docs/ANALYTICS.md`.**

One session built the analytics plane, then an APM plane on top of it, then
started extending OpenTelemetry into the other three layers. Roughly half of the
last part is unfinished and **two agents were still running when the session
ended** (§7). This is what is true, what is in flight, and what will bite.

---

## 1. What is LIVE on main and deployed

| Plane | State |
|---|---|
| Feature reach, flows, metrics (browser) | live, collecting real human data |
| Server-side branch probes (Python) | live |
| Line coverage lane | built, **not armed** (opt-in instrumented bundle) |
| OTel traces (browser) | live |
| OTel traces (Python serving plane) | **live as of `6e11f26e`** |
| Observability UI `/admin/observability` | live, admin-only |
| Rust `streamhost` probes | **deployed as SOURCE and INERT** — the binary has never been rebuilt |
| Instana forwarding | works, run by hand, **not on a timer** |

Deployed rev at handover: `main@6e11f26e` plus the serve-plane deploy after it.
`box-deploy.sh --status` is the authority.

Data lives in three SQLite stores beside the server:
`analytics.db` (counters, 730-day retention), `traces.db` (spans, **14 days**,
admin-only to read), `coverage.db` (line coverage, 120 days).

## 2. The design in four sentences

Aggregates answer *whether* and *how often*, are anonymous, and are kept for
years. Traces answer *why*, carry a session id, are admin-only, and expire in a
fortnight. The catalogue (`spa/src/analytics/catalogue/`) is the **denominator**:
a gate fails the build if a declared probe/flow/metric has no call site, which
is what makes a zero mean "unused" rather than "uninstrumented" — never weaken
that gate. `docs/ANALYTICS.md` is the long form; `docs/lab/TRACE-CONTEXT.md` is
the cross-process contract.

## 3. The privacy line, and where it moved

The analytics plane stored **no identities by construction** and said so as a
feature. Traces reversed that deliberately: a trace is a correlated per-session
record, which is what makes drilldown work. What replaced the guarantee is
narrower and is enforced, not asserted — admin-only reads, 14-day retention, and
**the content rules did not relax**. `exception.stacktrace` is refused at intake
with a test; stacks stay in `clientlog.jsonl`. No typed text, no credential
handles, no per-keystroke series. Do not quietly widen this; the reasoning is in
the headers of `trace.ts` and `traces.py`.

## 4. Instana — where the investigation actually stands

Working: the forwarder authenticates, ingests (200 OK), and Instana shows the
service `kernel-hive-spa` under technology `openTelemetry`.

**Not working: almost nothing is visible as a trace.** Established by
experiment, not inference:

- **Instana only builds a trace from an ENTRY span.** `internal`-kind spans
  ingest and produce no trace, no endpoint, `calls.sum = 0`. One hand-sent
  `SPAN_KIND_SERVER` span (`kindtest.server`) surfaced in
  `/api/application-monitoring/analyze/traces` within minutes.
- The browser plane is `internal` throughout, which is why forwarding "worked"
  and showed nothing.
- **The serving plane now emits `server`-kind roots** (`serve.clientcmd`,
  `serve.walkin.state`) and they were forwarded — and after five minutes they
  had **still not appeared**. That is the open thread.

**A real bug was found while chasing it and is fixed but NOT yet verified
against Instana:** the OTLP export labelled *every* span
`service.name: kernel-hive-spa` with `telemetry.sdk.language: webjs`, including
Python handler spans. Spans now carry `kh.service` and the export groups by
(session, service). Whether that is what Instana was rejecting is **unknown** —
that is the next experiment.

Do NOT "fix" this by relabelling browser spans as `server`. A UI span is not a
server span, and saying so to every OTel consumer to satisfy one of them puts a
lie in the data.

### Credentials and endpoint (all gitignored)

| Thing | Where | Note |
|---|---|---|
| Agent key (ingest) | `scripts/serve/pki/instana-agent.key` | mode 600, `**/pki/` ignored |
| Personal API token (REST) | `scripts/serve/pki/instana.token` | different credential, not interchangeable |
| Endpoint / tenant | `registry/local.env` | `INSTANA_ENDPOINT`, `INSTANA_API_BASE` |

- Region is **blue**, established from the tenant's own DNS CNAME
  (`teal-glacier0ozeyn.instana.io` → `blue.instana.io`). **The colour in a
  tenant name is not the region** — guessing "teal" sends a credential to the
  wrong host.
- There is **no REST endpoint for agent keys** — eight paths probed, all 404, no
  OpenAPI document, and IBM's community answer agrees. UI-only:
  Instana → More → Agents → Install Agents.
- Instana **requires** a host identity (`host.id` resource attribute or
  `x-instana-host`). Without it, data is refused or orphaned — and it looks like
  a broken exporter. Both are now sent.
- `instana-forward.py --check` posts an **empty** OTLP document: it proves
  endpoint and credential without sending telemetry. Only 401/403 is a
  credential answer; anything else means the key was accepted.
- The offline IBM docs are split at **`/home/wnt/instana-docs/`** (325 markdown
  files + `INDEX.md`), deliberately **outside the repo** — kernel-hive is public
  and those are IBM's. Both findings above came from grepping them.
- **The agent key was pasted into a chat transcript.** Worth rotating.

## 5. What is NOT built

- **Rust/`streamhost` OTel spans** — an agent was mid-flight (§7).
- **The Rust counter probes have never run.** They are deployed as source; the
  binary was never rebuilt. Until it is, every Rust probe reads zero and that
  zero means nothing.
- **Trace id does not reach the daemon.** The contract (`TRACE-CONTEXT.md` §3)
  says it rides the signalling exchange because the input plane is raw
  WebTransport with no headers. The serving plane records
  `kh.session.traceId`; nothing carries it onward yet. The Python agent
  deliberately left the ticket format alone because it is the Rust half.
- **The browser does not send `traceparent` on the `/signal/*` fetch** — only on
  the two telemetry POSTs. That is the hop that would join browser and server
  traces, and it is a small, high-value piece of work.
- Emulator spans (guest start / `loadvm` / first frame) — part of the Rust task.
- Instana forwarding on a timer. It is run by hand on purpose.

## 6. Traps that cost this session time

- **`wt.sh` sandboxes cannot build Rust** (`yuv-sys` C build fails). Use
  `scripts/dev/labrun` against the box's warm target; it is green there. This is
  why several pushes used `SKIP_GATE=1` — with every other gate verified by hand.
- **`spa/node_modules` is a symlink to the shared clone.** The coverage lane
  added `vite-plugin-istanbul`; never `npm install` through that symlink while
  other agents are live.
- **Publish a contract BEFORE launching agents that read it.** Launching first
  cost one agent a full wasted run, and pushing a commit that predated the
  shared `types.ts` cost another.
- **SQLite's double-quote fallback**: the `probe` table has a column named
  `probe`, so `class="probe"` compares class to that *column* and matches
  nothing — silently, including in the query written to verify the fix. Single
  quotes for string literals, always.
- **`window.__kernelHiveErrorSessionId` is assigned in `spa/index.html`**, by a
  pre-React inline error reporter. `clientDebug` now adopts it. Do not
  reintroduce a second generator — one tab had two identities and early errors
  never joined late ones.
- **React StrictMode invokes `setState` updaters twice.** Never call `reach()` /
  `recordMetric()` inside one.

## 7. IN FLIGHT — two agents were running at handover

Their branches may or may not exist. **Check `git branch -r` first.**

| Agent | Branch | Task |
|---|---|---|
| Rust + emulator OTel | `otel-rust` (from `origin/otel-context`) | spans in `streamhost`, guest lifecycle spans, build on the box. Told **not** to deploy or restart. |
| Fleet rollout tooling | `fleet-roll` (from `origin/main`) | staggered restart tool, waves of 3–5, framebuffer health gate, skip claimed/paused stations, `--dry-run` only. Told **not** to run a rollout. |

The operator's instruction, verbatim: *"it's OK to restart all the stations, but
do avoid restarting them all at once."* The rollout is **supervised, not
delegated** — 61 live stations with a fresh binary. Sequence: land `otel-rust` →
build on the box → canary one station → staggered waves.

## 8. Known-red, and not ours

`scripts/test_published_form_drift.py` fails on a clean tree. Bisected: green at
`93c0204c`, broken by `b1f18364` (the `e2e-smoke` merge). `--fork /nonexistent`
no longer means unreadable input — the tool falls back to the submodule gitlink,
reads it, and returns 1 on **real drift it then finds**: `hpuxvue`'s
`0008-artist-closed-loop-pointer.patch` has diverged from the published fork.
Both the stale test premise and the genuine drift belong to the QEMU-fork
stream. It **skips** inside a `wt.sh` worktree (the box clone is unpacked, not a
repo), so a sandbox run looks green and the shared clone does not.

## 9. Sandboxes held at handover

`otel-prop` (this branch), plus whatever `otel-rust` and `fleet-roll` hold.
Release with `scripts/dev/wt.sh rm <name>` once merged — the guard refuses while
commits are not on `origin/main`, which is the behaviour you want.

## 10. If you do one thing next

Send `traceparent` on the `/signal/*` fetch and re-run the Instana forward. It
is a few lines, it joins the browser and server traces into one, and it is the
most likely reason Instana still shows a service with no calls — a `server`-kind
root with real children is the shape its model wants.

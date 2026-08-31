# Session handover — observability, 2026-08-31

**Read this before touching anything under `spa/src/analytics/`,
`scripts/serve/tra*`, `scripts/observability/`, or `docs/ANALYTICS.md`.**

One session built the analytics plane, an APM plane on top of it, and extended
OpenTelemetry across the browser, the Python serving plane and the Rust daemon.
Everything is merged to `main`. This is what is true, what is not yet running,
and what will bite.

**Start here, in this order:**

1. §7 and §10 — the Rust plane has never executed, and rolling it is the task.
2. §1's deploy-state note — `main` is one commit ahead of the box, deliberately.
3. §6 — the traps. Two of them cost this session an hour each.
4. §8 — a red test that is not ours and IS reporting a real defect.

The work was paused at the operator's request with the docs finished; nothing
is half-applied and no agents are running.

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
| Rust `streamhost` probes + spans | merged, **INERT** — the binary has never been rebuilt or rolled |
| Fleet rollout tool | merged, **never run** — this is the next task |
| Instana forwarding | works, run by hand, **not on a timer** |

### Deploy state at handover — there is a one-commit gap, on purpose

Box is at **`main@0931a6ca`**; `main` is one commit ahead at **`95b4997b`**.
`box-deploy.sh --status` is the authority, not this paragraph.

That one commit is a fix to `signal_route.py`: it appended the trace context as
`?00-<traceid>-…` instead of `?traceparent=00-<traceid>-…`, so the daemon —
which looks for a query parameter *named* `traceparent`
(`trace/context.rs::QUERY_KEY`) — would never have found it. **The deployed
serving plane emits the malformed form right now.**

It is harmless as things stand and must be deployed before the Rust rollout:
the running daemon binary predates the trace work and never reads the query at
all, and `session_ticket.rs::verify` has always split the path on `?` before
verifying, so nothing today is affected. It would matter the moment the new
binary ships — which is exactly the next task (§7, §10).

Found by reading the signalling document the running server actually produced,
rather than the code that produces it. Worth repeating as a method: this class
of bug survives every gate in the repo.

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

- **Nothing in the Rust plane has ever executed.** The counter probes and now
  the daemon/emulator spans are all merged and none has run, because the binary
  has never been rebuilt. Every Rust probe and every daemon span reads zero, and
  that zero means nothing. Fixing this is §7 and §10.
- **Instana forwarding on a timer.** Run by hand on purpose; the forwarder is
  the only thing in this repo that sends data to a third party.
- **The line-coverage lane is not armed.** It needs the instrumented bundle
  served deliberately for a window; see `docs/ANALYTICS.md`.

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

## 7. The three parallel streams all LANDED — and what is left

All merged to `main`. Nothing is in flight.

| Stream | State |
|---|---|
| Python serving-plane spans | merged, **deployed**, emitting |
| Rust daemon + emulator spans | merged, **NOT deployed** — needs a binary build + rollout |
| Fleet rollout tool | merged, **never run** |

### The rollout is the next real task, and it is supervised

`scripts/dev/fleet_rollout.py`. Plan-only by default; nothing moves without
`--apply`. Sequence: build the release binary on the box (`scripts/dev/labrun`,
**not** in a sandbox — see §6), canary the one safe tile, then risk-ordered
waves gated on a real screendump.

The operator's instruction, verbatim: *"it's OK to restart all the stations, but
do avoid restarting them all at once."*

Two things the tool found that are worth knowing before you read its output:

- **Paused is not parked.** 36 of 71 live stations are paused at any moment —
  the daemon idle-auto-pauses an unwatched exhibit after ~60 s. Skipping paused
  would skip half the fleet, so paused stations ARE rolled; `--skip-paused` is
  opt-in.
- **Walk-in clones are not their stations.** `walkin-<os>-<n>` is an ephemeral
  daemon identity, and live walk-in port claims were parking `os2warp` and
  `win311` out of every rollout by name collision until clone identities were
  masked out of claim matching.

One judgement call left for the operator: the default DEFERS a station with a
visitor connected (`--include-busy` overrides). The dry run caught a live
visitor on `irix`.

### The trace now joins across all three processes

`signal_route.py` appends `?traceparent=…` to the ticket path (TRACE-CONTEXT
§3.1), which was the one hop left open. Browser → serving plane → daemon is one
trace id. **This is deployed for the serving plane but the daemon half only
takes effect once the new binary ships**, so until the rollout every daemon
session span is still a root reading `kh.trace.joined=false`.

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

`otel-prop`, `otel-python`, `otel-rust`, `fleet-roll`. All four branches are
merged to `main`, so `scripts/dev/wt.sh rm <name>` will now release them; the
guard refuses while commits are not on `origin/main`, which is the behaviour you
want and is why they were not released earlier.

`otel-rust` holds a **built release binary** — worth keeping until the rollout
runs, since it saves a rebuild.

No agents are running. No station was restarted, no golden touched, no binary
deployed by this session.

## 10. If you do one thing next

**Build the Rust binary and run the rollout.** Everything else is landed and the
Rust plane is the one part of this system that has never executed — every Rust
probe and every daemon span reads zero today, and in a design whose whole point
is that a zero means "unused", that is the most misleading state in the tree.

After that, re-run the Instana forward and see whether traces finally appear:
the daemon and serving plane both emit `server`-kind entry spans with real
children, which is the shape §4 says Instana's model wants and which nothing has
yet been able to test.

# Analytics — which code earns its keep, and where flows die

**Status: phase 1 shipped, not yet deployed.** The client plane, the sink, the
catalogue gate and the report tool are in the tree and green. Nothing is on the
box until `box-deploy.sh --apply` runs and the https service is restarted; §7
lists what is deliberately still open.

Everything is inside kernel-hive. No external service, no third-party script, no
account anywhere. That is not only a privacy preference here — the gallery's
public edge is a loopback-bound listener behind a forwarder, the LAN listener
uses the lab's own CA, and stations are reached over WebTransport straight from
the tab. There is no point in the request path where a hosted analytics SDK
would see anything useful without being handed it deliberately.

---

## 1. The three questions, and why they need three different answers

The ask was: *"test-coverage-style information about each feature, error rates
per user flow, and the ability to tell 'this endpoint is called on every page
load' apart from 'somebody actually used the data'."* Those are three questions
and they fail in three different ways if you fuse them into one hit counter.

| Question | What it needs that a counter does not have |
|---|---|
| **Which features are unused?** | A **denominator**. You cannot count code that did not run, so the instrumented set has to be *declared* and the report has to be a LEFT JOIN onto it. |
| **Where do flows break?** | **Attribution**. An error log knows what broke and not what the person was trying to do; the same exception is a different finding in a connect than in a page turn. |
| **Is this call earning its answer?** | **Intent**. `called 907 times` and `used 64 times` are two facts about one endpoint, and a single number destroys both. |

## 2. The shape

```
 tab                                  server                         operator
 ───                                  ──────                         ────────
 reach('fleet.usage.fetch','auto') ┐
 reach('fleet.usage.shown','show') ├─ POST /analytics ─► analytics.db ─► reach-report.py
 beginFlow('station.connect')      │  (counters, 20 s   (SQLite, per-day  (joins the catalogue
 reportError({...})                ┘   batches)          aggregate)        + vitest coverage)
```

Three files carry the whole client side: `spa/src/analytics/{intent,flows,errors}.ts`,
with `catalogue.ts` as the declaration and `sink.ts` as the transport.

### This is the THIRD telemetry plane, on purpose

The repo already had two, and neither can answer these questions:

| Plane | What it is | Why it is not this |
|---|---|---|
| `clientlog.jsonl` (`serve/clientlog.py`) | raw per-session evidence, rolling window **pruned by age** | right for debugging one broken stream; a feature nobody used in March is gone from it by April |
| `usage-stats.json` (`serve/usage.py`) | clicks + keystrokes **per station** | the museum's exhibit-popularity question; says nothing about the software, and cannot tell you the fleet table's filter row is dead |
| `analytics.db` (`serve/analytics.py`) | per-**feature** counters, durable, day-bucketed | this |

They are kept apart rather than merged because their retention rules are
opposite: one must forget (raw session evidence), one must not (a two-year
"has anyone used this"). A single store would have to pick, and picking wrong
in either direction is what makes the data useless.

## 3. The intent ladder — the answer to "auto vs actually used"

Every observation carries a grade. They only ever grade **down**.

| Grade | Means | Established by |
|---|---|---|
| `auto` | ran because a page loaded, a poll fired, a component mounted, a retry came round. Nobody asked. | the call site says so |
| `show` | the result was **put in front of a human** — rendered, in a **visible** tab | `document.visibilityState`; a hidden tab silently downgrades to `auto` |
| `act` | a human **deliberately operated it** | a **trusted** (`isTrusted`) pointer/key edge witnessed in the capture phase within the last second |

Two narrowings apply, both one-way, and between them a call site cannot lie
about intent even by accident:

1. **Evidence clamp.** The call site says what it *believes* it saw; `gradeFor`
   returns what the evidence *supports*. A table rendered in a background tab
   reports `auto` without the call site knowing it was hidden.
2. **Catalogue clamp.** A probe declared `grades: ['auto']` can never report an
   `act`, however the call site moves. It falls to the strongest declared grade
   below what was observed, and is dropped if there is none.

**The pair is where the insight lives.** A probe may declare `consumes: <an
auto probe>`, and the report divides one by the other. Real numbers from the
seeded example run:

```
boot.index.fetch     called   907  ->  boot.video.played    used    64   (7.1%)
fleet.usage.fetch    called   412  ->  fleet.usage.sorted   used     3   (0.7%)
stream.stats.polled  called   388  ->  stream.overlay.shown used     0   (0.0%)
```

That last row is the shape the question was asked about: `useStreamSession`
polls `control.getStats()` **once a second for the entire life of every station
session**, feeding an overlay that is hidden until somebody presses Ctrl+N. The
counter says the poll ran; only the pair says nobody ever looked.

### Synthetic input gets no credit

A type-in demo puts hundreds of key edges on the wire from one click, and the
win9x boot-modal auto-dismiss types Esc and Enter on every connect with nobody
touching anything. `withSyntheticInput` (already used by the usage scoreboard
for the same reason) now brackets **both** planes through one call, so those
edges cannot be graded `act`. `station.key.used` declares `['act']` only, so
they are dropped entirely rather than counted as typing.

## 4. Client class — the trap this lab would have fallen into

This lab **drives its own SPA with a fleet of browser probes**
(`scripts/e2e/*.mjs`, the CT950 typing-pace probe, the scene-shot rigs). They
click and type for real, so every heuristic above says "human". Unclassified,
they would not merely add noise — on a 63-station private gallery they would be
the **majority** of traffic, and every keep/drop decision made from this data
would silently be a decision about what the *test fleet* exercises.

So `class` is a first-class dimension on every stored row:

- `navigator.webdriver === true` → `probe`. Puppeteer, Playwright and every
  remote-debugging attach set it, which covers the existing fleet with **no
  probe script needing to be edited**.
- `window.__khClientClass` overrides it, for a rig that wants to declare itself.
- The report **defaults to `human` only**. `--class probe` is a separate and
  genuinely useful view: it is a map of what the e2e suite actually touches.

## 5. Flows and errors

A flow is opened around an *attempt*, its steps are reported as they are passed,
and any error raised while it is open is attributed to the flow **and the step
it was standing on**.

- **Steps are monotonic.** Reporting step N implies 1..N-1, and backwards or
  repeated moves are ignored, so a funnel is a funnel — counts that only
  decrease — rather than a bag of counters that can read more `firstFrame`s
  than `transport`s.
- **One flow per attempt-sequence, not per retry.** `useStreamhostSession`
  retries with backoff; a funnel that counted retries would report a station
  that connected on the fourth try as three failures and a success.
- **No timeouts and no "abandoned" event.** Drop-off is already the funnel:
  388 entered `open`, 344 reached `firstFrame`. Synthesising an abandonment on a
  timer would invent a number the funnel already states, and would have to guess
  a threshold to do it.
- **`close()` is not `fail()`.** A visitor navigating away mid-connect leaves
  the flow through `close()` — it reports nothing, because the abandonment is
  the drop-off and reporting it as a failure would double-count it as a fault.
- **A flow does not measure time** — it counts attempts. Journey timing is its
  own lane (`metrics.ts`), and the two are deliberately not fused: a flow's
  steps are funnel edges, and making them clock edges too would mean neither
  could be changed without moving the other. What still belongs on neither is
  STREAM latency — the Ctrl+N overlay, clientlog's 5-second stats line and the
  daemon's journal already measure encode/transport/decode, and a fourth number
  that disagrees with all three is worse than none.

### The station and stream flows — opening one, coming back to one, watching one freeze

Three of the flows are about a single machine, and they exist as three rather
than one because the code behind them shares almost nothing.

**`station.connect`** is arriving: click a machine, wait, see a desktop. It ends
at the first PAINTED FRAME rather than at `phase === 'live'`, because the phase
has gone live on a session that stayed a spinner — the phase is the gallery's
opinion, the frame is the visitor's. Beyond the wait itself it now carries two
numbers the funnel could not state. `station.open.attemptCount` says what the
connect COST as opposed to whether it worked: the funnel already reports that a
station connected, and this reports that it took four goes to do it, which is a
station one bad week from falling back to its poster. It counts ATTEMPTS, not
retries, because the `count` ladder's smallest bucket is 1 and as retries a
clean connect and a one-retry connect would both land in it — the commonest case
in the gallery, unreadable. It is committed only on a painted frame; committing
on a give-up would deposit the full ladder length into every failure and quietly
turn the metric into a restatement of the failure rate.
`station.open.toFirstInputMs` is the other half, and it is not a performance
number at all: measured from the first frame to the first TRUSTED input edge, it
is how long somebody looks at a machine that already works before daring to use
it. A high value on one station and not another is a **discoverability**
problem — same stream, same latency, and visitors can tell what to do with one
exhibit and not the other — answered by a caption or a coachmark, never by the
pipeline. It is necessarily conditioned on the visitor touching at all, since
you cannot time an event that never happens; the proportion who never touch is a
different question that `station.pointer.used` and `station.key.used` already
answer, and reading this distribution as though it covered everyone is the one
way to misuse it.

**There is no cold-vs-warm split on the connect, and the absence is a finding.**
A station that was idle-paused and had to be resumed is a genuinely different
wait from one already streaming, and merging them does make the p95 partly a
statement about how often the fleet is asleep. The browser simply cannot tell:
the signaling document carries host, port, cert hash and encoder params and no
run state at all, so an idle-paused station's response is byte-identical to a
running one's. The bit **exists** — `was_paused` in `streamhost/src/idle.rs`,
`Freezer::session_started` — but it is computed after the transport is already
accepted and goes only to the journal, so it could not reach the signaling fetch
even in principle. Nothing else is an honest proxy: `coldBoot` in the registry
is station metadata ("this machine has no vmstate to resume into"), constant on
every connect; retry counts are dominated by network, cert rotation and decoder
fallback. Under this document's own boundary rule — *if the daemon could answer
it, this plane does not ask it* — the split is the **daemon's to publish**, not
the tab's to guess, and the minimal honest fix is one additive `KIND_PARAMS`
subtype pushed at session start. Until that exists the split stays unmeasured
and is said to be unmeasured, which is the difference between a gap and a lie.
(Note also that cold/warm is already spoken for in that subtree:
`MAX_COLD_ATTEMPTS` and `markWarm()` mean "has this client painted yet".)

**`session.resume`** is coming BACK, which is not the same code as arriving.
The resume path is `resumeSignals` (four different events, because in an
installed PWA a return from another app is not one event), `resumePolicy` (is
the session dead, or merely quiet?), `sessionResume` (the grace window and the
parked-error recovery probe) and `videoResume` (the paused `<video>` that pulls
nothing and makes a healthy transport look broken). Every one of those exists
because of a field failure and none of them is visible in today's numbers: a
resume that takes eight seconds and one that takes eighty milliseconds are the
same single `station.connect` entry, or no entry at all. Its outcome is **two**
metrics rather than one, because a resume ends in one of two different
engineering problems — the session was still there and the picture only had to
start pulling again, or it was gone and the whole transport had to be rebuilt.
Fused, the distribution is bimodal, its p95 describes only how often the
expensive case happens, and no action follows. Split into
`session.resume.toLiveMs` and `session.resume.reconnectToLiveMs` — disjoint by
construction, so one resume is one sample in exactly one of them — the pair says
plainly whether the fix is "keep sessions alive longer while backgrounded" or
"make the rebuild faster".

`session.resume.awayMs` is **the one legitimate `countsHiddenTime` in the whole
catalogue**, and it must not spread. Every other duration stops its clock while
the tab is hidden because it describes a person's PATIENCE and hidden time is
not patience; this one describes their ABSENCE, so visible time would return
zero on every sample — a tautology, not a distribution. It earns the exception
by driving a decision nothing else can reach: the daemon pauses an idle guest
after a grace window and holds a wake lease for 90 s, and how long visitors are
actually away is what says whether either window is set anywhere near right.

**`stream.recover`** is a stall from the visitor's point of view, and it is the
most delicate flow in the catalogue because the stream is already measured three
ways. So the boundary is enforced literally: this flow measures **no** loss, RTT,
tier or bitrate, a rule with a test behind it rather than only a comment. What
is left is the part no encoder can see — how long a person sat looking at a
picture that had stopped moving, and whether they gave up — and it is derived
from the PAINT side, frames that reached the glass, never from the encoder's
account of what it sent, because the failure worth catching is exactly the one
where those two disagree. `stream.recover.abandonedAfterMs` is the most valuable
number in this group: it is the only place in the system that records a visitor
**giving up**. Everything else measures how long something took for the people
who stayed. It and `stream.recover.stallMs` are disjoint — a freeze ends either
because the picture moved or because the visitor stopped looking — so one freeze
is one sample, and the two populations can be read against each other.

Two traps sit under that, and a fixed freeze threshold walks into both. A static
desktop paints only on the keyframe heartbeat (~2.5 s), and several exhibits run
at a couple of frames per second **by design**, so "no new frame for two
seconds" is the normal, healthy behaviour of a large part of the fleet — a fixed
threshold would report those stations as permanently stalled and the metric's
largest signal would be a property of the exhibit rather than a fault. The
threshold is therefore derived from the station's OWN advertised heartbeat, in
the same shape `abr.ts` already uses for its staleness window, so this number and
the client's existing watchdog move together instead of drifting apart. It sits
deliberately BELOW the reconnect staleness window: the visitor perceives the
freeze well before the client decides the session is dead, and the gap between
those two moments is precisely how long somebody is asked to look at a frozen
machine before the software does anything about it.

The subtler trap is that a gap is not automatically a freeze. On an idle station
showing a motionless desktop a missed heartbeat is **not perceptible** — the
picture looks identical whether frames are arriving or not — so counting it
would be measuring something nobody experienced. A gap only counts when the
picture was MOVING (painting faster than the heartbeat alone would deliver, so
its stopping is visible) or the visitor was ASKING it to move (a trusted input
edge after the last paint, so they are waiting on a reaction). Neither is
knowable from the wire, which is exactly why the rule lives in the tab.

Errors are **fingerprinted and counted**, not logged. `/clientlog` keeps the
stack and the component stack so one session can be read; this keeps the count,
so a fault that happened four hundred times is one row that says four hundred.
The fingerprint scrubs urls, hex, uuids and every number, which deliberately
collapses `Failed to fetch …/signal/beos.json` and `…/signal/irix.json` into one
row — the per-station split you then want comes from the **flow**, not the
message. The full stack, the href and the IP stay on the clientlog lane, which
prunes itself; this lane is durable, and a durable aggregate must not be where a
visitor's browsing history lives forever.

## 6. The coverage cross — "test coverage style info"

`scripts/dev/reach-report.py` joins the catalogue, production reach and the
SPA's vitest coverage:

```
                | reached in production | never reached
 ---------------+-----------------------+---------------------------------
 covered by     | HEALTHY               | PAYING TWICE — tests maintained
 unit tests     |                       | for something nobody uses
 ---------------+-----------------------+---------------------------------
 not covered    | EXPOSED — used, and   | DEAD — the cheapest deletion in
                | nothing catches a     | the repo, and the first place to
                | regression            | look for one
```

**The first run already produced a finding:** all 13 probes live in files
outside vitest's `coverage.include`, so every one lands in a "no unit scope"
row. That is a true statement about this repo — the unit-test scope is
deliberately narrow (pure-logic modules only; `spa/coverage-exclusions.json`
carries the written reason per module) — and the report says it out loud rather
than printing a column of em-dashes.

Two ways to fill that column, in increasing cost:

1. **Widen `coverage.include`** as DOM-testable modules get a render harness.
   Free, incremental, and the direction the SPA is already going.
2. **A line-level production coverage lane** (`vite-plugin-istanbul` on a second
   bundle, `window.__coverage__` POSTed on pagehide, merged with
   `istanbul-lib-coverage`). This gives genuine per-line production reach, at the
   cost of shipping an instrumented bundle. **Deliberately not built yet**: it
   should be opt-in and off by default, and the probe catalogue answers the
   feature-level question at a fraction of the cost. Phase 2.

## 7. What is NOT built yet

Named so nobody re-derives them as gaps:

- **Rust (`streamhost`) probes.** Same catalogue idea, different mechanism: a
  `probe!()` macro over a static relaxed-atomic counter array, dumped to a
  per-station file. Feature-level only — line coverage in a latency-critical
  daemon is not worth an instrumented production binary. `cargo llvm-cov` covers
  the "tested" axis today.
- **Python serve-plane probes.** The route table is small enough that journald
  answers most of it; worth doing when a route's *purpose* rather than its
  volume is in question.
- **A UI for the report.** It is a CLI and a JSON endpoint. An `/admin` view is
  a straightforward next step, and consistent with the operator's standing
  preference for eyeballing over automation, it should not be built before
  somebody has actually wanted it twice.
- **Deployment.** `box-deploy.sh --apply` plus an https restart; `analytics.db`
  is created on first start beside the server.

## 8. Adding a probe

Two steps, in **one commit**, and the gate enforces it:

1. Add the entry to `PROBES` in `spa/src/analytics/catalogue.ts` — `area`,
   `owner` (the file that will hold the call site), `what` (finish the sentence
   *"this fired, therefore we know that…"*), `grades`, optional `consumes`.
2. Call `reach('<id>', '<grade>')` in that file. `make analytics-catalogue`
   re-renders `registry/analytics-catalogue.json`.

`make analytics-catalogue-check` (part of `quality-gate`) fails if a declared
probe has no call site in its owner file. **That gate is the load-bearing
half.** Without it the report has two zeros that look identical and mean
opposite things — "nobody uses this feature" and "I declared a probe and never
called it" — and the second kind is what gets working code deleted.

Traps worth knowing, each of which was hit while writing this:

- **Never call `reach` inside a `setState` updater.** React StrictMode invokes
  updaters twice and every count doubles.
- **One use is one use.** The free-text filter reports only the empty →
  non-empty transition; per-keystroke it would have been the most-used feature
  in the gallery by a factor of twenty.
- **Report the pair at the same granularity.** `stream.stats.polled` fires once
  per *session*, not per one-second tick, so its ratio against
  `stream.overlay.shown` reads "sessions that paid" over "sessions that looked"
  rather than being a function of how long a tab stayed open.

## 9. Privacy and honesty

- **No identities at all, by construction.** Unlike `usage.py` this plane has no
  per-person half: no user id is accepted, none is stored, and there is no
  column a future caller could put one into (asserted by a test). The only
  durable privacy guarantee is the data you never wrote down, and *"which
  feature is dead"* never needed to know who.
- **These are the tab's own account of what it did.** Same caveat as `usage.py`,
  same reason: the counters come from the client. Right for deciding what to
  build; not an audit trail. The per-batch caps bound how far one forged report
  can move a total; nothing bounds a patient liar, and nothing needs to.
- **`never reached` is not `unreachable`.** It means no tab reported it in the
  window. Read the window before the verdict.

## 10. Files

| Path | What |
|---|---|
| `spa/src/analytics/catalogue.ts` | the declaration — the report's denominator |
| `spa/src/analytics/intent.ts` | the grade ladder, the human-edge witness, client class |
| `spa/src/analytics/flows.ts` | flow spans and the funnel rules |
| `spa/src/analytics/errors.ts` | fingerprinting and grouping |
| `spa/src/analytics/sink.ts` | batching transport (counts, not events) |
| `spa/src/analytics/index.ts` | `reach` / `beginFlow` / `reportError` / `initAnalytics` |
| `scripts/serve/analytics.py` | `POST /analytics`, `GET /analytics/report.json`, the SQLite aggregate |
| `scripts/analytics/catalogue.mjs` | renders the registry document; **gates the call sites** |
| `scripts/dev/reach-report.py` | the joined report |
| `registry/analytics-catalogue.json` | generated; byte-parity gated |
| `scripts/test_analytics.py`, `spa/src/analytics/analytics.test.ts` | 19 + 23 tests |

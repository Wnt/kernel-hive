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

Four files carry the whole client side: `spa/src/analytics/{intent,flows,metrics,errors}.ts`,
with `catalogue/` as the declaration (one file per area, so parallel
instrumentation streams share no editing surface) and `sink.ts` as the
transport.

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
- **A flow counts attempts; it does not time them.** Journey timing is its own
  lane (§6) so that a step boundary is a funnel edge only. Fuse them and every
  step has to be both, and neither can be changed without moving the other.

Errors are **fingerprinted and counted**, not logged. `/clientlog` keeps the
stack and the component stack so one session can be read; this keeps the count,
so a fault that happened four hundred times is one row that says four hundred.
The fingerprint scrubs urls, hex, uuids and every number, which deliberately
collapses `Failed to fetch …/signal/beos.json` and `…/signal/irix.json` into one
row — the per-station split you then want comes from the **flow**, not the
message. The full stack, the href and the IP stay on the clientlog lane, which
prunes itself; this lane is durable, and a durable aggregate must not be where a
visitor's browsing history lives forever.

## 6. Metrics — how long it took, and how much effort it cost

A probe says a path ran. A flow says how far an attempt got and where it died.
Neither answers *"was it any good"*, which is most of what anyone wants to know
about a user flow — so timings and effort counts are a third kind of
declaration, gated exactly like the other two.

**This reverses something this document used to say**: that nothing in this
plane measures time, because latency already has three better sources. That
reasoning was sound and about the wrong thing. The Ctrl+N overlay, clientlog's
stats line and the daemon's journal all measure the **stream** — encode,
transport, decode. None of them measures the **visitor**. "How long from
choosing a machine to seeing its desktop" is not derivable from any of them: it
starts before the stream exists and ends when a human's eyes are satisfied. The
boundary is now explicit, and it is the rule for adding any metric:

> If the daemon could answer it, this plane does not ask it.

### Buckets, not samples

A value becomes a bucket **in the tab**; only the bucket travels. In order of
importance: a raw timing series is a behavioural trace of one person's session
and this store is a durable years-long aggregate, which is the wrong place for
one to live; p95 needs a distribution and a mean hides exactly the sessions
worth fixing; and a bucketed metric costs one counter per bucket per day
however many samples land in it.

The cost is stated rather than hidden — the report prints `p95 <= 3.2s`, never a
precise number the data cannot support. Buckets are named by their **edge**,
never by index, so inserting a ladder step cannot silently re-point history: an
old row keeps meaning what it meant and a changed ladder shows up as new bucket
names beside the old ones.

### The clock stops when nobody is looking

A duration accumulates **visible time only**. A connect that took four minutes
because the tab was backgrounded for three of them is not a four-minute wait,
and a handful of those is enough to move a p95 into fiction. `countsHiddenTime`
exists for the one quantity that genuinely is about absence — how long a PWA
session was away before it came back — and the gate refuses it on any non-`ms`
metric. Timings use `performance.now()`, never the wall clock: an NTP step or a
laptop suspend mid-timing produces a negative or hour-long duration, and both
survive bucketing to poison the distribution.

### The three shapes, and the traps

| Call | For |
|---|---|
| `startTiming(id)` | a duration. `stop()` records; `abandon()` records **nothing** |
| `recordMetric(id, v)` | a value the call site computed itself |
| `accumulator(id)` | an effort total: `add()` as you go, `commit()` once per episode |

- **`abandon()` is not a zero.** A torn-down React effect must record nothing —
  a zero is a real, very fast sample, and inventing one per abandonment drags
  every p50 to the floor. A genuinely zero-effort *episode* is the opposite: it
  is committed, because a visitor who found what they wanted without scrolling
  at all is the outcome the feature is for.
- **One episode is one sample.** Reported per event, an effort metric is a
  distribution of ones that says nothing.
- **Report a pair at the same granularity.** `stream.stats.polled` fires once
  per session, not per one-second tick, so its ratio against
  `stream.overlay.shown` reads "sessions that paid" over "sessions that looked"
  rather than being a function of how long a tab stayed open.
- **Units live in the id.** The gate requires an `ms` metric to end in `Ms` and
  a `pct` metric in `Pct`. A durable column reading `hScroll 4200` is a number
  two readers will interpret differently, and it will outlive both.

### Device-independent units

`fleet.find.hScrollScreens` counts **screen widths**, not pixels. The same hunt
for a column reads as 400 px on a phone and 4000 on the operator's monitor, and
a number you cannot compare across the devices that produced it cannot be acted
on. It is also already the unit the answer wants to be in: *"two screens of
sideways scrolling to reach the codec column"*. Distance alone cannot tell a
confident sweep from a hunt, so `fleet.find.hScrollReversals` counts direction
changes beside it — high distance with no reversals is a layout that is merely
wide; high reversals is a layout nobody can hold in their head.

### Effort proxies are proxies

Several metrics here — hesitation before a first interaction, backtracking,
correction rates, scroll oscillation, steps-to-goal — are **behavioural proxies
for effort**. They are not measurements of cognition and are not described as
such anywhere in this system. Each one states what it observes and what it is
evidence *for*. A metric that overclaims gets a wrong decision made from it, and
these are durable enough to be quoted back years later.


## 7. The coverage cross — "test coverage style info"

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

## 8. What is NOT built yet

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

## 9. Adding a probe

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

## 10. Privacy and honesty

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

## 11. Files

| Path | What |
|---|---|
| `spa/src/analytics/catalogue/index.ts` | the declaration — the report's denominator |
| `spa/src/analytics/intent.ts` | the grade ladder, the human-edge witness, client class |
| `spa/src/analytics/flows.ts` | flow spans and the funnel rules |
| `spa/src/analytics/metrics.ts` | timings, effort accumulators, the visible-time clock |
| `spa/src/analytics/catalogue/` | the declarations, one file per area |
| `spa/src/three/connectTelemetry.ts` | the reference call site: one flow + one timing |
| `spa/src/analytics/errors.ts` | fingerprinting and grouping |
| `spa/src/analytics/sink.ts` | batching transport (counts, not events) |
| `spa/src/analytics/index.ts` | `reach` / `beginFlow` / `reportError` / `initAnalytics` |
| `scripts/serve/analytics.py` | `POST /analytics`, `GET /analytics/report.json`, the SQLite aggregate |
| `scripts/analytics/catalogue.mjs` | renders the registry document; **gates the call sites** |
| `scripts/dev/reach-report.py` | the joined report |
| `registry/analytics-catalogue.json` | generated; byte-parity gated |
| `scripts/test_analytics.py`, `spa/src/analytics/analytics.test.ts` | 19 + 23 tests |

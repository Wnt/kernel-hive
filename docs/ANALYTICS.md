# Analytics — which code earns its keep, and where flows die

**Status: phase 1 shipped, plus the Rust probe plane (§7.1); nothing deployed.**
The client plane, the sink, the catalogue gate, the report tool and the
`streamhost` probes are in the tree and green. Nothing is on the
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
- **Nothing here measures time.** Latency already has three better sources (the
  Ctrl+N overlay, clientlog's 5-second stats line, the daemon's journal); a
  fourth number that disagrees with all of them is worse than none.

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

- **Python serve-plane probes.** The route table is small enough that journald
  answers most of it; worth doing when a route's *purpose* rather than its
  volume is in question.
- **A UI for the report.** It is a CLI and a JSON endpoint. An `/admin` view is
  a straightforward next step, and consistent with the operator's standing
  preference for eyeballing over automation, it should not be built before
  somebody has actually wanted it twice.
- **Deployment.** `box-deploy.sh --apply` plus an https restart; `analytics.db`
  is created on first start beside the server.

### 7.1 The Rust plane — `streamhost` feature-reach probes

**Built.** `streamhost/streamhost/src/probes.rs` declares the catalogue,
`probe!(NAME)` increments it, and each station dumps
`/data/vms/streamhost/stations/<id>/probes.json` every 60 s and once more on
shutdown.

The question is the same one §1 asks, and the reason it needed asking again on
the box is that **61 stations share ONE binary**. Every input backend, every
keyboard quirk and every ABR rung is compiled into every station, and the only
thing that varies is `SH_*`. Config can tell you what a station is *allowed* to
do. Nothing in the tree could tell you what any of it ever *did* — whether a
visitor has ever taken the WebRTC fallback, whether the pre-1986 keyboard quirk
has fired since the machine that motivated it was listed, whether ABR has ever
stepped down on a LAN.

**The mechanism is different because the constraints are.** No grades, no flows,
no errors: by the time a record reaches `input.rs` the SPA has already graded
it, and inventing a second grade from a byte on a datagram would be a guess
wearing the same word. journald already carries flows and faults, and §2's rule
— a durable aggregate must not become a second copy of the debugging lane —
applies here exactly as it does to `clientlog.jsonl`. So this plane carries hit
counts and nothing else.

**Declared, not registered.** `ALL` is the denominator, built by the same
`probes!` macro that declares the statics so it cannot drift the way a
hand-written array would. A `HashMap<String, u64>` filled in at call time was
the obvious shape and is the wrong one twice over: it cannot list what never
fired, which is the only row worth having, and it cannot be grepped, which is
what the gate depends on.

**Cost, measured rather than asserted.** One relaxed `fetch_add` on a
`&'static AtomicU64` — no lock, no allocation, no formatting, no branch on an
enable flag. `hit_cost_is_negligible` measures it in the test suite and prints
the number. On the lab build box, 2 000 000 back-to-back hits:

| profile | per hit |
|---|---|
| `--release` (opt-level 2 — what ships) | **8.5 ns** |
| default `cargo test` (debug, unoptimised) | 95 ns |

A station taking 250 pointer samples a second therefore spends about **two
microseconds a second** here, which is why probes are left unconditionally on:
an `SH_PROBES=off` switch would cost a branch to save a few nanoseconds and
would then make every dumped zero ambiguous between "never fired" and "never
enabled here".

Two caveats stated rather than glossed, because "zero-cost" would be wrong in
both directions. The loop is the *worst* case a single thread can build — a
dependent chain of `lock xadd` on one cache line with no work in between —
while a real call site pays it once per input record with a syscall on either
side. And the **contended** cost is higher and is *not* measured. It does not
need to be: every probe here is per-session or per-input-record, never
per-pixel, so two hot tasks sharing one probe's line is not the regime any of
them runs in.

**The gate is the load-bearing half**, as on the SPA side, and it lives in
`cargo test --workspace` rather than a script — the CI exit rule already runs
that, and a `#[test]` cannot be forgotten the way a `make` target can.
`catalogue_has_no_orphan_probes` reads each probe's `owner` file and fails
unless it contains a literal `probe!(IDENT)`. The identifier is *derived* from
the dotted id rather than declared a fourth time, so there is one less field to
drift.

**Traps hit while building it, each of which shaped the result:**

- **`input.rs` is at its hard line cap (800/800),** so the most obvious call
  site — the abs/dbus/rel fork in `apply_move_abs` — could not take a probe
  without breaching `check-file-size`, and silencing that with a
  `size-exclusions.json` entry is exactly what AGENTS.md rule 10 forbids. The
  probes moved one frame deeper instead, into `rel_bridge::set_target` and the
  three sink implementations, which is where the fork's *consequences* are
  anyway. Same for `config/mod.rs`, also at 800: this module reads its two env
  knobs itself, following `ram_abs::socket_from_env`'s precedent, rather than
  growing the config struct.
- **The shutdown dump must not change the exit disposition.**
  `streamhost@.service` is `Restart=on-failure`, so handling SIGTERM and calling
  `exit(0)` would silently reclassify every stop in the fleet. The handler dumps,
  restores `SIG_DFL` and re-raises, so systemd sees precisely what it saw before.
- **An identity remap is not a quirk firing.** `remap_key` counts only a rewrite
  that actually changed the code; otherwise every keystroke on a station that
  merely *declares* a table would read as a hit and the quirk would look alive
  everywhere.
- **A connected bridge is not a viewer.** The WebRTC feed socket connects on
  every station boot whether or not anyone uses WebRTC, so the probe sits on the
  session-lease `S` command, not on the connect.

**Line coverage is deliberately not in scope, and will not be.** The SPA can
ship a second instrumented bundle (§6); a daemon with a ~16 ms budget per frame
cannot ship an instrumented production binary, and one built only for the lab
would measure the lab. `cargo llvm-cov` covers the "tested" axis on the test
binary, at no cost to the fleet.

**Probes today (11)** — the pairs are where the insight is, as on the SPA side:

| id | the decision it informs |
|---|---|
| `input.abs.ramWrite` / `input.abs.x11Warp` / `input.abs.warpd` | which pointer backend any visitor's hand ever reached. A backend at zero fleet-wide is a station list to re-check and then a module to delete |
| `input.abs.relBridge` | how much of the fleet still rides the abs→rel dead-reckoning hack — the oldest and most expensive pointer path in the daemon |
| `input.rel.rehomed` | how often re-homing actually runs. Unobservable from outside, and half of why `mgactl-home-records-a-bogus-hotspot` is still open |
| `key.quirk.remap` | whether `SH_KEY_REMAP` rewrites anything on any live station |
| `key.quirk.legacyCursor` | whether the pre-1986 bare-keypad cursor quirk has fired since the Win 1.x/2.x station that motivated it |
| `abr.tier.down` / `abr.tier.up` | down-only means the upshift hysteresis is mis-tuned; equal counts mean a flapping link; both zero on the LAN is the controller behaving as designed, and is the row that says so |
| `transport.wt.session` / `transport.webrtc.session` | whether the fallback transport — a whole sidecar process and a second egress — has ever carried a real viewer |

**Adding one** is the §8 rule with Rust nouns: one entry in the `probes!` block
naming the file that will hold the call site, one `probe!(NAME)` in that file,
in one commit. `cargo test --workspace` fails otherwise.

**Not deployed.** A dumped `probes.json` is a file on the box and nothing reads
it yet; wiring it into `reach-report.py` alongside the SPA catalogue is the next
step, and belongs with the §7 deployment item rather than ahead of it.

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
| `streamhost/streamhost/src/probes.rs` | the Rust declaration, the `probe!()` macro and the per-station dump |
| `streamhost/streamhost/src/probes_tests.rs` | the Rust drift gate + the measured per-hit cost; runs under `cargo test --workspace` |

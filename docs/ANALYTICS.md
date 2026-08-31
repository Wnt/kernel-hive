# Analytics — which code earns its keep, and where flows die

**Status: phase 1 and the phase-2 line-coverage lane are in the tree, not yet
deployed.** The client plane, the sink, the
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

## 6. The coverage cross — three axes, and why they are three

`scripts/dev/reach-report.py` crosses three facts that are routinely confused
for one:

| Axis | Source | Denominator | Blind spot |
|---|---|---|---|
| **covered by unit tests** | `spa/coverage/coverage-final.json` (vitest) | the modules in `vitest.config.ts`'s `coverage.include` | deliberately narrow — pure-logic modules only |
| **reached in production** | the probe counters (`analytics.db`) | `catalogue.ts`, written by hand | only ever sees code somebody thought to declare |
| **executed in production** | line coverage (`coverage.db`, this section) | the compiler's — every instrumented statement | needs the opt-in instrumented bundle to have been served |

The report keeps them in adjacent columns and never adds them together. A file
can be 90% unit-covered and have run no line in front of a visitor since the
bundle was built; one number for both is how that file keeps its budget.

### The quadrants, now per FILE

The grid used to be per PROBE, and every probe in this repo landed in a "no unit
scope" row because all thirteen live in DOM-heavy modules that vitest does not
measure. With the line axis it is per file, over the whole `src/` tree rather
than the thirteen declared points:

```
                | executed in production | never executed
 ---------------+------------------------+---------------------------------
 covered by     | HEALTHY                | PAYING TWICE — tests maintained
 unit tests     |                        | for something nobody uses
 ---------------+------------------------+---------------------------------
 not covered    | EXPOSED — used, and    | DEAD — the cheapest deletion in
                | nothing catches a      | the repo, and the first place to
                | regression             | look for one
```

Two states are NOT in the grid and are printed as themselves, because folding
either into `DEAD` is how working code gets deleted:

- **`no line data`** — the instrumented build had no statement map for this
  file at all (not instrumented, or renamed since). Not the same as "never
  executed".
- **`(no unit scope)`** — the file is outside vitest's `include` and
  `coverage-exclusions.json` says why. A documented decision, not a gap.

A first real run (one probe-class session that loaded the grid and clicked
about) placed 183 files: **8,177 instrumented lines, 2,025 executed (25%)**,
with **47 modules at exactly zero** — `src/admin/AdminPage.tsx`,
`src/three/streamClient/*`, `src/scene/ExhibitInfoCard.tsx` and the rest of the
stream path, which that session never opened. Read that as the report intends:
`never executed` is a fact about the window and the sessions in it, not a
verdict, and one session is not a window.

### How it works

```
 instrumented tab                      server                     operator
 ────────────────                      ──────                     ────────
 window.__coverage__  ── reduce ──►  POST /coverage ─► coverage.db ─► reach-report.py
   (2.3 MB of counts)   in the tab     (22 KB, once,    (per build,     (third column,
                        to line SETS    at pagehide)     day-bucketed)   + per-file table)
```

- **The bundle is a second artefact and off by default.** `npm run
  build:coverage` arms it; `npm run build` is byte-identical to what ships
  today, verified by rebuilding and comparing all 447 output files' SHA-256
  after this lane landed.
- **The arming value is a string, not a flag.** `VITE_KH_COVERAGE` must equal
  `instrument-this-build` exactly. `1`, `true` and every other value build the
  normal bundle — a leftover `export` or a CI matrix cell must not be able to
  ship an instrumented gallery, and an accidentally instrumented gallery is a
  silent regression nobody would go looking for.
- **The default bundle does not contain the collector at all.**
  `src/analytics/coverage.ts` has exactly one importer and it is the build
  plugin, which injects it into `main.tsx` only when armed. A runtime `if` would
  still ship the module, and "byte-identical" would quietly become "identical
  apart from the bit I added".
- **Counts are thrown away in the tab.** What travels is two run-length LINE
  SETS per file — instrumented, and the executed subset. Sets union losslessly
  across sessions, which is the whole merge; and how many times a branch ran is
  a behavioural trace a durable aggregate has no business keeping.
- **Its own store, `coverage.db`.** Argued in `scripts/serve/linecov.py`: the
  rows are kilobytes not integers, they expire with their build (120 days) where
  the counters last two years, and the body cap has to be 1 MiB where the
  counter plane's 64 KiB is a security property. Sharing would loosen the
  counter cap sixteenfold to admit something that is not a counter.
- **Never unioned across builds.** Line numbers move on the next commit. Every
  map is keyed by a build id and the report answers for one build.

### What it costs, measured

| | default bundle | instrumented |
|---|---|---|
| `index-*.js` | 1,652,106 B | 3,972,943 B (**+140%**) |
| gzipped (`gzip -c`) | 473,008 B | 930,308 B (**+97%**) |
| build time | 2.6 s | 18.6 s |
| per-session upload | none | **22,156 B** (5,908 B gzipped), once, at `pagehide` |
| `window.__coverage__` if sent raw | — | 2,331,560 B (the reduction is 99.0%) |

Runtime overhead is a counter increment per statement — unmeasurable against
this SPA's three.js frame cost, but the +2.3 MB of parse and the counter arrays
are not free on a first load, and the gallery's own first-paint budget is the
reason this is not the default.

### Sampling policy: operator-armed, and that is the recommendation

There is no client-side sampling fraction, on purpose. The three candidates and
why one wins:

1. **All sessions of the instrumented bundle** — the recommended default, and
   what is implemented. Coverage is a UNION, so it converges: the tenth session
   adds almost nothing, and a fraction would only make it converge more slowly
   for no saving that matters (22 KB per session on a private gallery).
2. **A fraction of sessions.** Buys nothing here. The payload is already small
   and the merge is idempotent; the only thing a fraction changes is how long
   you must wait before a zero means anything, which is precisely the number the
   report is most easily misread on.
3. **Operator-armed, which is the real gate** — and it is the BUILD, not a
   runtime dice roll. The instrumented bundle is served deliberately, for a
   window, when somebody wants to answer a deletion question; then the normal
   bundle goes back. That keeps the cost inside a decision somebody made, rather
   than as a permanent tax on every visitor, and it is why the arming lives in
   the build flag and not in a config the box could drift into.

So: **armed by the operator per investigation, every session sampled while
armed, 120-day retention, and the normal bundle the rest of the time.**

The cheaper axis has not gone away: widening `coverage.include` as DOM-testable
modules get a render harness is still free and still the direction the SPA is
going. This lane answers the question the catalogue cannot — code nobody
declared — and it is not a replacement for either of the other two axes.

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
  and `coverage.db` are created on first start beside the server.
- **Serving the instrumented bundle.** The lane is built and tested; nothing
  automates PUTTING it in front of visitors and back again. That is deliberate
  — it is the operator-armed decision above, and a script that swaps the live
  gallery's bundle is a script nobody dares run. Stage it
  (`scripts/dev/stage.sh`) or deploy it by hand for the window you want.
- **A line-level UI.** Same answer as the report's: the CLI prints the file
  table; nobody has wanted an annotated source view twice yet.

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
| `spa/src/analytics/coverage.ts` | production LINE coverage collector; in the instrumented bundle only |
| `spa/vite-plugins/coverage.ts` | the arming flag, the istanbul transform, the collector injection |
| `spa/src/analytics/index.ts` | `reach` / `beginFlow` / `reportError` / `initAnalytics` |
| `scripts/serve/analytics.py` | `POST /analytics`, `GET /analytics/report.json`, the SQLite aggregate |
| `scripts/serve/linecov.py` | `POST /coverage`, `GET /coverage/report.json`, the line-set merge |
| `scripts/analytics/catalogue.mjs` | renders the registry document; **gates the call sites** |
| `scripts/dev/reach-report.py` | the joined report |
| `registry/analytics-catalogue.json` | generated; byte-parity gated |
| `scripts/test_analytics.py`, `spa/src/analytics/analytics.test.ts` | 19 + 23 tests |
| `scripts/test_linecov.py`, `spa/src/analytics/coverage.test.ts` | 11 + 9 tests |

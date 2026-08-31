# Analytics — which code earns its keep, and where flows die

**Status: phase 1 shipped, plus all three phase-2 planes — Rust probes, Python
serve-plane probes and the line-coverage lane. Nothing is deployed.** The client
plane, the sink, the metrics lane, the catalogue gate, the report tool, the
`streamhost` probes (§8) and the serving plane's own branch probes (§9) are in
the tree and green. Nothing is on the
box until `box-deploy.sh --apply` runs and the https service is restarted; §10
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
                                          ▲
                     hit('walkin.reap.idle') │ serve/probes.py, folded in
                     hit('auth.gate.walkin') ┘ memory, flushed once a minute
                                               (class='server' — §9)
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

### 5.1 Three journeys: the fleet table, the WebGL hall, the posters

Three surfaces of the gallery had no account of themselves at all. Each gets a
flow (where the journey dies) and a small set of metrics (what it cost to get
that far). The declarations are in `spa/src/analytics/catalogue/fleet.ts`; the
episode logic is in one module per journey, next to the surface it measures.

| Flow | Steps | The decision it is for |
|---|---|---|
| `fleet.find` | `open` → `narrow` → `chooseStation` | A table nobody ever leaves BY OPENING A MACHINE is a table that answers no question. The drop-off between `open` and `chooseStation` is the whole verdict on the fleet view. |
| `hall.navigate` | `enter` → `approach` → `open` | The hall is the most expensive thing in the UI. If the flow rarely completes, it is scenery, and that is a budget decision somebody should get to make on evidence. |
| `poster.read` | `open` → `scrolled` → `reachedEnd` | ~450 kB of curatorial prose exists and nothing has ever reported whether a word of it is read. |

| Metric | Scale | A high value means… |
|---|---|---|
| `fleet.find.toFirstActionMs` | ms | People land on the table and cannot tell what to do with it — the controls do not suggest the first move. |
| `fleet.find.actionsToStation` | count | It takes many sorts and filters to isolate one machine — the default order and the column set are wrong for the questions people ask. |
| `hall.navigate.toFirstStationMs` | ms | The hall is wandered rather than used to reach a machine. |
| `hall.navigate.stationsApproached` | count | Visitors stand in front of machine after machine without opening any — the placards are not telling people what they are looking at. |
| `poster.read.dwellMs` | ms | (Read LOW.) A low value means posters are opened and dismissed unread. |
| `poster.read.scrollDepthPct` | pct | (Read low.) People stop part way down — the essays are longer than the audience they are written for. |
| `poster.read.scrollReversals` | count | People scroll back up mid-poster — a passage they had to read twice, and the first place to look when rewriting. |

The four fleet metrics — these two and the existing `hScrollScreens` /
`hScrollReversals` pair — share ONE episode, opened when the table mounts and
settled when it unmounts. That is deliberate and load-bearing: the diagnosis is
in the pairing. Many actions with LITTLE sideways scrolling is a visitor who
could see the columns and still could not express the question; many actions
with a LOT of it is a visitor who spent the visit hunting for where the answer
lives. Those are different repairs, and only two numbers about the same episode
can tell them apart. Move one boundary and the pair stops being comparable.

**`hall.entered` is the ratio worth having.** It is paired with
`boot.index.fetch`, which every visit fetches once, so the report divides them
into "of the visits that loaded the gallery, how many entered the 3D hall".
That pairing is not a convenience: the hall genuinely consumes that document —
`entriesForHall` carries `bootVideo` through and `ScreenPlane` decodes those
loops onto the CRTs. What it is NOT is a head-to-head against the 2D grid,
which is not separately instrumented; read it as a floor on how much of the
audience the hall ever reaches.

**What "approached" is, exactly.** Not a proximity model invented for the
metric — it is the scene's OWN focus state (`spa/src/scene/screenTiers.ts`): the
nearest visible screen to the centre of the view, inside the focus window, held
there for the full `SCREEN_FOCUS_DWELL_MS` dwell. Three things make that the
honest choice rather than the convenient one. It is already load-bearing (the
same edge decides whether to spend a live WebTransport texture on that screen).
It is the UI's own gate for opening a machine (clicking a screen that is *not*
focused walks the camera over instead of opening it, so "approached but not
opened" is literally "they were in the one state from which opening was
possible, and did not"). And the dwell is what keeps it from counting the
corridor — desks swept past during a rail move never become the active focus.
Its limit, stated beside it: it is a CAMERA fact, not an attention fact. It says
a machine was centred in the view for a second and a half. It does not say
anybody looked at it, read its placard, or considered it.

### 5.2 These are behavioural proxies, not measurements of cognition

The question behind §5.1 was which stages take the most effort. Hesitation
before a first action, steps to a goal, backtracking, re-reading oscillation —
every one of those is a **proxy**, and the word matters more here than anywhere
else on this plane, because these are the numbers most likely to be quoted in a
sentence they cannot support.

What they observe is what a pointer and a scroll container did. A reversal is a
scroll direction change; it is produced identically by a reader checking a date,
a trackpad that overshot, and a reader defeated by a sentence. A long
`toFirstActionMs` is produced identically by a confused visitor and one who
answered the phone in a tab that was still visible. None of them measures
attention, difficulty or cognitive load, and none of them ever will.

What they are good for is comparison and ranking: this poster against that one,
this month against last, the fleet table before a column change against after.
That is enough to decide what to fix, which is all that was ever asked of them.
Describing them as a measure of cognitive effort would put a confident word on
evidence that cannot carry it, and this repo's rule is that a measurement's
limits travel beside it.

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
for effort**, and §5.2 sets out at length what that does and does not license
you to say about them. The short version, because it is the thing most likely to
be forgotten when a number is quoted: they observe what a pointer and a scroll
container did. They do not measure attention, difficulty or cognitive load.

## 7. The coverage cross — three axes, and why they are three

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

## 8. The Rust plane — `streamhost` feature-reach probes

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
ship a second instrumented bundle (§7); a daemon with a ~16 ms budget per frame
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

**Adding one** is the §11 rule with Rust nouns: one entry in the `probes!` block
naming the file that will hold the call site, one `probe!(NAME)` in that file,
in one commit. `cargo test --workspace` fails otherwise.

**Not deployed.** A dumped `probes.json` is a file on the box and nothing reads
it yet; wiring it into `reach-report.py` alongside the SPA catalogue is the next
step, and belongs with the §10 deployment item rather than ahead of it.

## 9. The Python serving plane — branches, not routes

**Shipped.** `scripts/serve/probes.py` declares twelve branches; the call sites
are in the five files that own them; the counts fold into the same
`analytics.db` under a new `class`.

**It is deliberately not a route counter.** journald and the access log already
say how much traffic `/signal/<tile>.json` gets, and a fourth place to read that
number would be worse than none. The question no log answers is what happens
*inside* a route: of the refusals, fallbacks and reap reasons the serving plane
carries, which have ever been taken? Every one of those is a branch somebody
would otherwise keep working forever on the strength of a comment, and every
interesting answer is a row reading **zero**.

So the same two halves as the client plane, for the same reason. `PROBES` in
`probes.py` is the denominator; `make analytics-catalogue-check` — still the one
command — fails if a declared id has no literal `hit()` in the file it names as
`owner`. Without that gate a zero means either "this branch is dead" or "I
declared a probe and never called it", and the second kind is what gets working
code deleted.

### The twelve, and what a zero would settle

| Probe | A zero would mean |
|---|---|
| `auth.gate.invited` | the invited plane's fence never ran — every public request was open, or there were none |
| `auth.gate.walkin` | no stranger with an account has ever made a gated request |
| `auth.gate.walkinOwn` | walk-ins browse and never reach a **machine**; the plane is reachable and not used (declared `consumes` the row above, so the report gives the fraction) |
| `auth.gate.blocked` | nothing browser-reachable has ever asked for the command enqueue — the block is theoretical, and any other number is worth the access log |
| `walkin.claim.queued` | the queue-and-position machinery has never once been needed on a pool of three |
| `walkin.claim.resumeFailed` | the `_abandon` path — the thing that keeps "a used clone is never re-listed" true under a failure — has never been exercised |
| `walkin.reap.ttl` | nobody has ever held a clone for twenty minutes |
| `walkin.reap.idle` | the 3-minute window never wins; the TTL always gets there first, and the idle timer is not doing what it was added to do |
| `walkin.reap.died` | no pool member's QEMU has died under the watchdog. Non-zero is a fleet-health fact nothing else on the box reports |
| `clientlog.prune.age` | the clientlog has never reached its size backstop |
| `clientlog.rotate.generational` | **the suspected-dead one.** Reachable only when a prune has already run *and* left the file oversized. Declared `consumes: clientlog.prune.age`, because its zero alone cannot separate "unreachable" from "the log never got big" |
| `signal.ticket.identityDiffers` | no station's own `signaling.json` disagrees with the key its document is fetched under. Non-zero means one does **right now**, and the fallback is the only thing hiding it — this exact divergence locked `solaris` and `aros` out for four hours on 2026-08-05 |

### `class='server'`, not a second table

`CLASSES` gains a fourth value rather than the store gaining a fifth table, and
the argument is that **nothing about the row differs**. A server probe is a name
and a count in a day bucket, which is the `probe` table exactly; it wants the
same two-year retention, so it wants the same `prune`; and the report tool wants
the same LEFT JOIN. A second table would duplicate the schema, the prune and the
read path to add no column, and would give the box a second thing to remember to
back up.

What actually needs separating is the **population**, and `class` is the
dimension that already exists for precisely that job — it is there because the
lab's own browser probes would otherwise be the majority of "human" traffic. A
server branch count summed with a client feature count would be a worse version
of the same mistake, and the existing default (`human` only) already prevents it
with no new code.

Two consequences worth knowing:

- **Grade is `auto` on every server row, and that is honest rather than a
  placeholder.** The ladder grades whether a *human* asked for something; on
  this side nobody did. A branch was taken because a request arrived or a
  watchdog ticked, which is the definition of `auto`.
- **`CLASSES` had to be split in two.** `record()` reads its class out of a body
  a browser posted, so the moment `server` joined that tuple a client could
  forge branch counts for code it never ran — and forged evidence that a dead
  refusal is alive gets code *kept*, which is the harder error to notice.
  `CLIENT_CLASSES` is what the POST route validates against; the server class is
  reachable only through `record_server()`, which no route calls. A test asserts
  the hole is shut.

### Zero risk to the request path

Three properties, and the third is the one that took thought:

1. **`hit()` never raises.** It is called from inside `except` handlers, from
   the walk-in watchdog and from the fence in front of every gated request. The
   body is wrapped and `test_probes.py` attacks it with a store that raises on
   every call, a store that is absent, and six kinds of junk id.
2. **`hit()` never writes.** It folds into a dict. The dict is bounded by the
   **catalogue**, not by traffic — an undeclared id is dropped, so twelve keys is
   the whole memory cost however many requests arrive.
3. **The flush is lazy and re-arms *before* the write.** No thread, no timer:
   the first `hit()` after `FLUSH_SECS` folds the accumulated counts in, so the
   cost amortises to one small commit a minute under any load and a quiet box
   does nothing at all. Re-arming the throttle before attempting the write is
   what stops a store that has gone bad from turning every subsequent request
   into another attempt — the failure is counted, never logged per occurrence
   and never retried per request.

**Measured cost** (labhost, Python 3.12, best of five 300 000-call runs; the box
is shared, so the spread across runs was roughly 1.4–2.5 µs):

- `hit()` on a **declared** id: **~1.4 µs**, of which the lock and the
  `time.monotonic()` throttle check are almost all of it.
- `hit()` on an undeclared id: ~0.26 µs (the membership test, then return).
- One flush: ~0.3 ms, at most once a minute.

The gate path takes at most two hits per gated request, so the ceiling is under
3 µs against a request that costs milliseconds in TLS alone. Nothing on the LAN
listener's static-asset path is probed at all.

### Deliberately not probed

- **LAN-anonymous traffic.** It is the highest-frequency path in the server, its
  volume is exactly what the access log already reports, and "the LAN gate is
  open" is a constant, not an observation.
- **`restore.py`'s refusals and `/signal`'s 410.** Both are good candidates and
  both were left for a later commit; twelve is what could be read and verified
  branch by branch in one pass, and a probe declared without reading the branch
  is how the catalogue starts lying.
- **`static_files.py`'s "era-browser bare Content-Type" path.** It does not
  exist. Every entry in `MIME` carries `charset=utf-8` unconditionally, so the
  Mosaic trap recorded elsewhere is not handled in this file, and declaring a
  probe for it would have manufactured a permanent zero for a branch that was
  never there.

## 10. What is NOT built yet

Named so nobody re-derives them as gaps:

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

## 11. Adding a probe

Two steps, in **one commit**, and the gate enforces it:

1. Add the entry to `PROBES` in `spa/src/analytics/catalogue.ts` — `area`,
   `owner` (the file that will hold the call site), `what` (finish the sentence
   *"this fired, therefore we know that…"*), `grades`, optional `consumes`.
2. Call `reach('<id>', '<grade>')` in that file. `make analytics-catalogue`
   re-renders `registry/analytics-catalogue.json`.

On the **server** side the shape is the same and the file is different: declare
in `PROBES` in `scripts/serve/probes.py` (`area`, `owner` — repo-relative this
time, `what`, optional `consumes`; there are no grades, because nobody asked)
and call `hit('<id>')` in that owner. The generator runs `probes.py` to read the
declaration rather than parsing it, so there is never a second reader that can
disagree with Python's.

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
- **A server probe belongs inside the branch, not at the call site.**
  `auth.gate.blocked` is counted inside `is_blocked()` itself: put it at the
  three callers instead and a caller that forgot becomes indistinguishable from
  a refusal that never happens, which is the one zero the catalogue cannot
  explain.
- **Two module names, one module.** The serving process imports
  `scripts/serve/probes.py` as `probes`; the unit-test runner reaches it as
  `serve.probes`. Left alone those are two module objects with two counter
  dicts, silently halving every fold, so `probes.py` aliases itself into both
  names in `sys.modules` on import.

## 12. Privacy and honesty

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

## 13. Files

| Path | What |
|---|---|
| `spa/src/analytics/catalogue/` | the declaration — the report's denominator, one file per area so parallel instrumentation streams share no editing surface |
| `spa/src/analytics/intent.ts` | the grade ladder, the human-edge witness, client class |
| `spa/src/analytics/flows.ts` | flow spans and the funnel rules |
| `spa/src/analytics/metrics.ts` | the metrics lane — bucketing, the visible-time clock, effort accumulators |
| `spa/src/three/connectTelemetry.ts` | the reference call site: one flow + one timing |
| `spa/src/ui/fleetFindEpisode.ts` | the `fleet.find` episode |
| `spa/src/scene/hallEngagement.ts` | the `hall.navigate` episode, and what "approached" means |
| `spa/src/ui/posterReadEpisode.ts` | the `poster.read` episode and the reversal counter |
| `spa/src/analytics/errors.ts` | fingerprinting and grouping |
| `spa/src/analytics/sink.ts` | batching transport (counts, not events) |
| `spa/src/analytics/coverage.ts` | production LINE coverage collector; in the instrumented bundle only |
| `spa/vite-plugins/coverage.ts` | the arming flag, the istanbul transform, the collector injection |
| `spa/src/analytics/index.ts` | `reach` / `beginFlow` / `reportError` / `initAnalytics` |
| `scripts/serve/analytics.py` | `POST /analytics`, `GET /analytics/report.json`, the SQLite aggregate |
| `scripts/serve/probes.py` | the SERVER catalogue, the in-memory fold, and `hit()` |
| `scripts/analytics/catalogue.mjs` | renders the registry document for BOTH planes; **gates the call sites** |
| `scripts/dev/reach-report.py` | the joined report |
| `registry/analytics-catalogue.json` | generated; byte-parity gated |
| `scripts/test_analytics.py`, `scripts/test_probes.py`, `spa/src/analytics/analytics.test.ts`, `spa/src/analytics/metrics.test.ts` | 31 + 19 + 23 + 17 tests |
| `streamhost/streamhost/src/probes.rs` | the Rust declaration, the `probe!()` macro and the per-station dump |
| `streamhost/streamhost/src/probes_tests.rs` | the Rust drift gate + the measured per-hit cost; runs under `cargo test --workspace` |
| `scripts/serve/linecov.py` | `POST /coverage`, `GET /coverage/report.json`, the line-set merge |
| `spa/vite-plugins/coverage.ts`, `spa/src/analytics/coverage.ts` | the armed-only instrumentation plugin and its collector |
| `scripts/test_linecov.py`, `spa/src/analytics/coverage.test.ts` | 11 + 9 tests |

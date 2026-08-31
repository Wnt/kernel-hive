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

---

## 11. The walk-in door and the touch keyboard

Three flows in one area, because they are one question asked three times: **how
much work is this software to use for somebody with nobody to ask?** The walk-in
plane is where a stranger meets the gallery cold, and the on-screen keyboard is
where they meet a machine from 1993 through a phone. Both were built on
judgement and neither has ever been measured.

| Flow | Steps | The half the funnel answers for free |
|---|---|---|
| `walkin.register` | landing → passkey → account → machine | how many strangers who arrive end up at a machine |
| `walkin.play` | claim → held → driven | how many claims become a machine somebody actually drives |
| `keyboard.compose` | shown → firstKey → text | how often the keyboard comes up and nothing is typed |

### These are behavioural proxies, and the doc says so where the numbers are

The ask behind this wave was *"which stages take the most cognitive capacity"*.
Hesitation, retries, corrections and layer switches are the closest a tab can
honestly get to that, and they are **not measurements of cognition**. They
observe what a visitor's hands did. A long hesitation is evidence that the page
does not say what to do next; it is equally consistent with somebody who put the
phone down, which is why the clock counts **visible time only** (§ metrics) and
why every `what:` in `catalogue/walkin.ts` finishes with a decision about the
*interface* — "reorder this layout", "rewrite this lede" — and never with a
sentence about the person. A metric that overclaims gets a wrong decision made
from it, and these are the metrics most likely to be quoted out of the table.

### Refusal is not abandonment, and it gets its own counter

The operator can close the walk-in plane. A stranger who arrives then is shown a
frozen sentence instead of three machines (`walkin/reasons.ts`), and **no
`walkin.register` flow is opened for them at all** — `walkin.register.refused`
counts them instead. Had they entered the funnel, the drop-off at `landing`
would read as a landing page nobody understands and somebody would go and
rewrite copy to fix an operator switch. Two more fences get the same treatment
for the same reason: a browser with no WebAuthn fails the flow as `nopasskey`,
and a claim refused because access closed mid-session fails `walkin.play` as
`closed`. Only genuine drop-off is left to be read as drop-off.

A visitor who **already has an account opens no flow either**. They are not
registering, and a population that legitimately skips three of the four steps
does not make the funnel bigger — it makes it wrong.

### Per stage, not per journey

`walkin.register` reports four stage clocks, not one total. A total says the
door is slow and gives nobody anything to do; split it says which stage to work
on and — just as usefully — which stage is not ours: `passkeyMs` is mostly the
platform's own sheet, and no copy change on this side moves it.
`hesitationMs` and `landingMs` are deliberately both measured on the landing
stage and are different quantities: hesitation ends at the visitor's first touch
of anything, dwell ends when they leave. Read together they separate *"could not
tell what to do"* from *"read all three cards carefully"*, and the second is the
page working.

`exhibitPickMs` is recorded **only on the path where the stage exists**. There
are two ways through this door — make a passkey and then choose a machine, or
press *Play it* and get the passkey on the way — and on the second the machine
was chosen before the account, so there is no picking stage. Recording a zero
would invent one, and the invention would be most of the distribution.

### The queue split is the whole poolSize argument

Every walk-in station keeps a warm pool of three clones and there has never been
any evidence for or against that number. Two facts are needed and neither is the
other: **how often** a visitor meets a full pool (the `walkin.play.claimInstant`
/ `claimQueued` probe pair) and **how long** the ones who do end up waiting
(`walkin.play.queueMs`). 30% queued for four seconds is a healthy pool; 2%
queued for four minutes is not; either number alone cannot tell you which you
have. `queueMs` is recorded only for visitors who were actually told to wait —
an instant claim is not a zero-length queue, it is the absence of one, and the
instants are numerous and all sub-second, so folding them in would make an
exhausted pool and a healthy one produce the same picture.

`walkin.play.toPlayableMs` ends at the visitor's **first deliberate input on the
clone**, not at a painted frame. The frame is already
`station.open.toFirstFrameMs`, and a clone that paints perfectly and is never
touched is one the pool spent for nothing. A **reset** is explicitly not a
`claimRetry`: it is the visitor asking for a fresh machine and getting one, and
counting a working feature as friction is how a good feature gets "fixed".

### The keyboard question is a budget question

`keyboardProfiles.data.exotic.ts` is 400+ lines of per-machine key layout
maintained by hand. `keyboard.osk.used` says the keyboard is pressed; it cannot
say whether the layout it presents is any good. `toFirstKeyMs`,
`correctionsPct` and `layerSwitches` can — and their conclusion is about the
*layout data*, since on a layout this lab wrote itself a high correction rate is
a key in the wrong place, not a visitor who cannot type.

Three limits are stated rather than hidden. **`correctionsPct` is null, not
zero, when nothing was committed**: corrections over an empty denominator is not
a small percentage, it is not a percentage. **A rate over 100 is allowed
through** to the `inf` bucket — clearing a field the guest already had text in is
real, and clamping would merge it with the merely-terrible episodes. **A held
Backspace is one press and several deletions**, so both halves undercount a held
key; reaching into the repeat timer to fix that would put an instrumentation
requirement inside the send path, and the rate is read as a comparison between
layouts rather than as an absolute.

`layerSwitches` observes **navigation cost, not confusion**. Switching to `?123`
for a digit is a correct use of the layer split and it still cost a round trip.
Shift is deliberately excluded: shift is how you type a capital and cycling to
caps lock is two deliberate presses, so counting either as hunting would report
ordinary typing as a defect.

All three are scoped to the **mobile sheet**. The desktop inline footer has no
layers, is always on screen so nothing ever "appears", and its free-text field is
driven by a physical keyboard through a keydown proxy — measuring it alongside
would glue two unlike populations into one distribution and call the result a
number. `keyboard.osk.used` still covers both and is unchanged, so the
`osk.used : station.key.used` ratio — how much of the gallery's typing goes
through the touch keyboard at all — is untouched: everything added here is
per-episode and declares no probe on either side of that pair.

### The privacy line, which is tighter here than anywhere else in this plane

This is a stranger typing, sometimes their own name, into a form and into a
guest. **Nothing about the content leaves the tab.** Not the text; not its
length; not a per-keystroke timing series; not a handle, a credential id or a
clone identity; not which of the three machines a given visitor took. Characters
are counted only as the *denominator* of a percentage that is bucketed into
deciles before it is queued, so the count itself never travels and cannot be
recovered from what does. `scripts/serve/analytics.py` stores no identity by
construction, and the walk-in door is the last place that sentence should
acquire an exception. The rule the call sites are written to: **if a change here
would need one more field to make a number better, that is the signal to stop.**

### Files

| Path | What |
|---|---|
| `spa/src/analytics/catalogue/walkin.ts` | the declarations, with the privacy line and the proxy caveat at the top |
| `spa/src/walkin/registerTelemetry.ts` | the door: funnel, four stage clocks, the retry count, the refusal probe |
| `spa/src/walkin/playTelemetry.ts` | the claim: funnel, the queue/instant split, `toPlayableMs`, retries |
| `spa/src/ui/keyboard/composeTelemetry.ts` | the keyboard: funnel, first-key clock, the correction rate, layer switches |
| `spa/src/walkin/telemetry.test.ts`, `spa/src/ui/keyboard/composeTelemetry.test.ts` | 38 tests, one per rule above that could otherwise silently invert |

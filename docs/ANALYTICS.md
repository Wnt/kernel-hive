# Analytics — which code earns its keep, and where flows die

**Status: phase 1 shipped, plus all three phase-2 planes — Rust probes, Python
serve-plane probes and the line-coverage lane — in the tree and green.** The
client plane, the sink, the metrics lane, the catalogue gate, the report tool,
the `streamhost` probes (§8) and the serving plane's own branch probes (§9) are
built. The SPA and Python halves ship the way any other change here does —
`box-deploy.sh --apply` plus an https restart; §10 lists what is deliberately
still open. **The Rust half ships differently, and started shipping on
2026-08-31**: the rebuilt `streamhost` binary was canaried on `helenos` and is
being promoted across the fleet in risk-ordered waves by
`scripts/dev/fleet_rollout.py --mode promote` — see §8 for what that binary now
really does on a station that has it.

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
- **A flow does not measure time** — it counts attempts. Journey timing is its
  own lane (`metrics.ts`), and the two are deliberately not fused: a flow's
  steps are funnel edges, and making them clock edges too would mean neither
  could be changed without moving the other. What still belongs on neither is
  STREAM latency — the Ctrl+N overlay, clientlog's 5-second stats line and the
  daemon's journal already measure encode/transport/decode, and a fourth number
  that disagrees with all three is worse than none.


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

### 5.3 The walk-in door and the touch keyboard

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

#### These are behavioural proxies, and the doc says so where the numbers are

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

#### Refusal is not abandonment, and it gets its own counter

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

#### Per stage, not per journey

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

#### The queue split is the whole poolSize argument

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

#### The keyboard question is a budget question

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

#### The privacy line, which is tighter here than anywhere else in this plane

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

### 5.4 The station and stream flows: opening one, coming back to one, watching one freeze

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

**Deployed; not yet read.** The binary that owns this catalogue was rebuilt and
shipped for the first time on 2026-08-31 — canaried on `helenos`, then promoted
across the fleet in risk-ordered waves by `scripts/dev/fleet_rollout.py --mode
promote`. A station running the new binary really dumps
`/data/vms/streamhost/stations/<id>/probes.json` every 60 s and on shutdown now,
read directly off a live station. What is still true is the reading half:
`scripts/dev/reach-report.py` does not open `probes.json` and has no code path
that does. Wiring it in alongside the SPA catalogue, so a probe's fleet-wide
count sits next to its browser-side sibling, is the remaining step — the
deployment half it used to wait on is done.

## 8.1 The Rust plane, second half — `streamhost` SPANS

**Built.** `streamhost/streamhost/src/trace/` is the emitter,
`trace_session.rs` and `trace_guest.rs` are the call sites, and each station
spools batch files into `/data/vms/streamhost/stations/<id>/traces/`. The
contract every layer implements is [`docs/lab/TRACE-CONTEXT.md`](lab/TRACE-CONTEXT.md).

**Why a second plane on the same box.** §8's probes answer "has this code ever
run" and cannot answer "why was that slow": a count has no start, no end and no
parent. A visitor who waits four seconds for a station to appear is asking about
an interval, and the interval that explains it usually belongs to a different
process than the one they are looking at. Spans make one visit one flame graph
across four processes, which is the only shape in which "was it slow because the
guest was asleep" is a lookup rather than a timestamp-correlation exercise.

**The two planes do not overlap and both stay.** Per-frame and per-record data
belongs in counters; spans mark transitions and one-offs. **There is no span per
frame and no span per input edge** — at 60 fps that would be 3600 spans a minute
per station and 219 600 across the fleet. Every mark is a one-shot
`AtomicBool::swap`, so the encoder relay and the datagram loop pay one relaxed
load and nothing else.

**The spans, and the decision each informs:**

| span | kind | the question it settles |
|---|---|---|
| `streamhost.start` | internal | the daemon's own boot, and the root of the startup trace no visitor is present for |
| `guest.launch` | internal | how long the emulator process had been alive before the daemon could see it. On the `-loadvm golden -S` stations that window IS the checkpoint restore |
| `guest.attach` | client | the QMP getfd/add_client handshake plus dbus-display registration — the daemon's own cost of getting a picture |
| `guest.first_frame` | internal | when a framebuffer with real geometry first existed. AGENTS.md rule 9 in span form |
| `streamhost.session` | server | one visitor's session: how long, on which transport, and whether the daemon's half joined the browser's trace (`kh.trace.joined`) |
| `guest.resume` | internal | **was it slow because the machine was asleep.** `kh.guest.was_paused` is the daemon's belief read BEFORE the resume — without it every session would show a resume and none would mean anything |
| `capture.first_frame` | internal | how long after the session opened the guest produced a frame this daemon could see |
| `encode.first_key` | internal | how much of that wait was the forced IDR the join gate needs, rather than the guest |
| `transport.first_frame` | internal | when a byte of video reached the wire — the daemon's twin of the browser's `station.open.toFirstFrameMs` |
| `input.first_edge` | internal | when the visitor's first click or key reached the guest, and on which input class |
| `transport.webrtc_fallback` | server | the fallback transport being TAKEN — a second egress and a sidecar process, for a browser with no `VideoDecoder` |

The four session stages are all measured from the session's own start, so they
read side by side: `capture.first_frame` short and `transport.first_frame` long
is egress; `guest.resume` dominating both is a guest that was idle-paused, and
no other layer can say that.

**Collection is a spool directory, not a POST.** Each file in
`<station>/traces/` is byte-for-byte the body `POST /traces` accepts, written
tmp+rename like `probes.json` and `signaling.json`, capped at
`SH_TRACE_SPOOL_MAX` files with the oldest dropped. Three reasons it is not an
HTTP client, in order: a station that cannot reach the collector must keep
streaming, and a `rename(2)` has no failure mode that can reach the encoder,
while a POST has several; this binary has no HTTP client and the collector is
HTTPS, so posting means adding a TLS stack to a daemon that deliberately carries
none; and the file being the request body means the shipper needs nothing
server-side beyond reading a file and making the request — which is exactly
what `scripts/observability/trace-ship.py` (below) turned out to be.

**Cost, measured rather than asserted** (`span_cost_is_small`, 20 000 spans
back-to-back on the lab build box):

| profile | disabled | enabled (1 attribute) |
|---|---|---|
| `--release` (opt-level 2 — what ships) | **50-70 ns** | **3.2 us** |
| default `cargo test` (debug) | 214 ns | 9.3 us |

A session emits at most seven spans, so a visitor costs about 22 us of daemon
time. Rendering is hand-written rather than `serde_json::Value` because the
`Value` version measured 8.3 us per span against 0.6 us for the same bytes; the
schema is eleven fixed keys and building a `BTreeMap` to walk it again was
paying fourteen times over for nothing. **Not measured, and stated rather than
glossed:** the flush (a string join plus one `rename`, once every 30 s on its own
task), the CONTENDED buffer lock (no per-frame span exists, so that regime does
not), and the sub-breakdown of the 3.2 us — attempted, and the shared build box
was too noisy to attribute it honestly.

**There IS an off switch (`SH_TRACE=off`), unlike the probes.** A probe hit is a
`fetch_add`, so a branch to skip it would have cost more than it saved and would
have made every dumped zero ambiguous. A span allocates, formats and writes
files, so the branch pays for itself — and a disabled station publishes no spool
directory at all, which reads as "off" rather than as "nothing happened".

**Joining the browser's trace: both ends are now live, and no trace has used
them yet.** The input plane is raw WebTransport with no headers, so the id rides
the session path's query string beside the ticket
([TRACE-CONTEXT §3.1](lab/TRACE-CONTEXT.md)). The daemon parses it on every
session and degrades to a ROOT span when it is absent, malformed, or from a
future version — never to a fabricated parent, and never to a refused session.
`signal_route.py` appends it and is deployed; the daemon that reads it shipped
on 2026-08-31. What has not happened is a VISIT: `kh.trace.joined` is an
attribute of `streamhost.session`, which exists only once a real visitor
connects, so the 100 daemon spans in the store are all boot-time roots
(`streamhost.start` and its three children) and carry the attribute not as
`false` but not at all. The first visitor to a rolled station is what will
prove the hop, and nothing else can.

**Traps hit while building it:**

- **A span that is its own parent looks perfectly well-formed.** Folding "my id"
  and "my parent's id" into one context object made every span point at itself,
  which renders as a trace with no root and no edges and passes every shape
  check. `a_child_span_points_at_its_parent_not_at_itself` exists for it.
- **The shutdown flush is not a second signal handler.** `probes::spawn` already
  owns SIGTERM/SIGINT and the exit disposition `streamhost@.service`'s
  `Restart=on-failure` depends on; a second handler would race the re-raise and
  sometimes lose the last batch. It calls `trace::flush_now` instead — one
  owner, one exit.
- **`transport/mod.rs` had 78 lines of headroom** under the 800-line Rust cap and
  `input.rs`/`config/mod.rs` had none, so the state machine lives in
  `trace_session.rs` and every call site is one line. Same constraint that shaped
  §8's probes, same answer, and no `size-exclusions.json` entry (rule 10).
- **`resource.session.id` is `"unknown"`, deliberately.** That field is the TAB's
  analytics session and a daemon batch spans every visitor in the flush window.
  Putting the station id there would fill a column meaning "one tab" with a
  machine name.

**Shipped, by hand, not on a timer.** `scripts/observability/trace-ship.py` is
the carrier the paragraph above predicted: it reads each finished batch file in
a station's spool, `POST`s it verbatim to `/traces`, and deletes it only on a
200. It is run ON the box, via `scripts/dev/labrun`, because the spool is
root-owned by the daemon and the tool needs to delete what it ships as root; run
from CT950 instead with `--apply --keep` and it can still ship, just never
clean up after itself. It is invoked by hand, the same as
`instana-forward.py`, on purpose: the spool is bounded
(`SH_TRACE_SPOOL_MAX`, oldest dropped) so nothing overflows while nobody ships,
and a daemon span is a one-off per session or per daemon start rather than a
stream with a rate that would justify a timer. Re-running it is always safe —
`scripts/serve/traces.py` inserts spans `ON CONFLICT(trace_id,span_id) DO
NOTHING`, so a batch shipped twice, or left in place after a failed POST and
retried on the next run, is stored once.

**`instana-forward.py` is one controlled thing that decides to leave the box,
not one URL any more.** Since 2026-08-31 labhost also runs an Instana HOST
AGENT (`systemctl status instana-agent`), a separate IBM-supplied process that
collects its own infrastructure/process data and maintains its own connection
out to the SaaS tenant (`ingress-blue-saas.instana.io:443`) independently of
anything in this repo — so "the forwarder is the only thing that talks to
Instana" stopped being literally true the day that agent was installed. What
is still true, and is the part of the old claim worth keeping: this script
remains the only thing **this repo** hands data to Instana through, and it
still has one credential, one `--dry-run`, one off switch. It now has a choice
of two local doors rather than one hardcoded URL — `--via-agent` POSTs OTLP to
the host agent's loopback receiver (`127.0.0.1:4318`), `--via-saas` POSTs
straight to the SaaS tenant as before, and with neither flag it auto-detects,
preferring the agent when its port answers because that keeps the network hop
on the box and gets host correlation for free (the agent supplies `host.id`
itself; the direct SaaS leg still needs this script to stamp one). The
`x-instana-key` ingest credential is sent on the SaaS leg only — confirmed
empirically that the local agent's receiver does not check it at all, so
sending it there would be a credential attached to a request that ignores it.
Full detail, including the empirical checks, is in the script's own
docstring.

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
- **Deployment of the SPA and Python planes.** `box-deploy.sh --apply` plus an
  https restart; `analytics.db` and `coverage.db` are created on first start
  beside the server. The Rust plane does not wait on this — it ships as part of
  the `streamhost` binary itself, via `scripts/dev/fleet_rollout.py`, and that
  rollout is what made §8 and §8.1 true on the box (started 2026-08-31).
- **`reach-report.py` reading the Rust probes.** The catalogue table in §1 has
  three axes and the report only ever crosses two of them (SPA feature reach
  against SPA line coverage); `probes.json`'s fleet-wide counts are not in it.
  Wiring that in, next to the SPA catalogue, is unstarted.
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
| `scripts/test_analytics.py`, `scripts/test_probes.py`, `scripts/test_linecov.py` | the Python side of all three planes |
| `streamhost/streamhost/src/probes.rs` | the Rust declaration, the `probe!()` macro and the per-station dump |
| `streamhost/streamhost/src/probes_tests.rs` | the Rust drift gate + the measured per-hit cost; runs under `cargo test --workspace` |
| `streamhost/streamhost/src/trace/` | the daemon's span emitter: `context.rs` (W3C parse + id mint), `mod.rs` (the span model, the buffer, the flush), `spool.rs` (the batch files), `tests.rs` (the shape gate + the measured cost) |
| `streamhost/streamhost/src/trace_session.rs` | the per-session spans and the one-shot marks |
| `streamhost/streamhost/src/trace_guest.rs` | the guest-lifecycle spans, measured from outside the guest |
| `scripts/serve/traces.py`, `scripts/serve/tracecontext.py` | the span store and the shared `traceparent` rule |
| `scripts/observability/trace-ship.py` | ships daemon spool batches to the box's own `/traces` route |
| `scripts/observability/instana-forward.py`, `scripts/observability/instana_destination.py` | forwards traces + metric histograms to Instana; agent-vs-SaaS destination choice, the narrow loopback-http exception |
| `scripts/serve/linecov.py` | `POST /coverage`, `GET /coverage/report.json`, the line-set merge |
| `spa/vite-plugins/coverage.ts`, `spa/src/analytics/coverage.ts` | the armed-only instrumentation plugin and its collector |
| `spa/src/analytics/*.test.ts`, `spa/src/walkin/telemetry.test.ts`, `spa/src/ui/keyboard/composeTelemetry.test.ts` | the client side; one test per rule that could otherwise silently invert |
| `spa/src/analytics/catalogue/walkin.ts` | the declarations, with the privacy line and the proxy caveat at the top |
| `spa/src/walkin/registerTelemetry.ts` | the door: funnel, four stage clocks, the retry count, the refusal probe |
| `spa/src/walkin/playTelemetry.ts` | the claim: funnel, the queue/instant split, `toPlayableMs`, retries |
| `spa/src/ui/keyboard/composeTelemetry.ts` | the keyboard: funnel, first-key clock, the correction rate, layer switches |
| `spa/src/walkin/telemetry.test.ts`, `spa/src/ui/keyboard/composeTelemetry.test.ts` | 38 tests, one per rule above that could otherwise silently invert |

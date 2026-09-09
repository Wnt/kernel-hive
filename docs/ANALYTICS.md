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

This plane — everything described below, client and server, Rust and Python —
is entirely inside kernel-hive: no external service, no third-party script, no
account anywhere in it. That is an ARCHITECTURE fact, not a privacy stance: the
gallery's public edge is a loopback-bound listener behind a forwarder, the LAN
listener uses the lab's own CA, and stations are reached over WebTransport
straight from the tab. There is no point in this plane's own request path
where a hosted analytics SDK would see anything useful without being handed it
deliberately — which is exactly why the Instana comparison below had to be
wired by hand. What these planes may CARRY is §0, and the answer is "as much as
is useful".

That used to be true of the whole gallery; it no longer is. Since 2026-08-31
an Instana JavaScript agent runs in every visitor's browser and beacons to
IBM's SaaS, a separate Instana host agent runs on labhost, and a signed-in
visitor's real account id and name are sent to it in cleartext — an
operator-armed, operator-known exception, not a leak (§8.2 has the detail and
the off switches). It exists as a **benchmark, not a dependency**: the
operator wants the richest data a mature commercial APM can show, in order to
find the gaps in this plane and close them, and has said plainly that the
integration is **temporary** — meant to come off once this plane's own
`/admin/observability` carries the views Instana currently supplies alone.
Every capability this plane gains for that reason has to work with Instana
entirely absent; §8.2 is where that principle is argued in full, against the
real decisions it already produced.

---

## 0. The data policy — READ THIS BEFORE ADDING A RESTRICTION

**This is the one section written to stop a recurrence.** In August 2026 a
series of AI sessions invented privacy, retention and content restrictions for
these planes, wrote them into code as enforced limits *and* into this document
as though the operator had required them, and later sessions then reasoned from
them as settled policy. Nobody chose them. On 2026-09-01 they were removed. The
policy below is what is actually true.

**1. Rich telemetry into both planes is the goal.** The operator's words:
*"we can and should submit as rich as possible data to both our to-be-fully-built
observability platform and into Instana."* Stacks, messages, full URLs and query
strings, the identity of the account involved, per-request detail — all wanted,
in our own trace store and in what the forwarder ships to Instana. A telemetry
plane that cannot tell you which account hit a fault, or what the stack was, is
not doing the job it exists for.

**2. Secrets never.** Auth tokens, session cookies, passkey material, the
Instana website key, the stream ticket. Not stored, not shipped, not logged.
This is **security**, not privacy squeamishness: a stored credential is one an
admin view, a backup or a forwarded OTLP batch can replay. Enforced at intake in
`scripts/serve/traces.py` by explicit name (`BANNED_ATTRS`) and by key shape
(`SECRET_KEY_RE`), so a name nobody anticipated still fails closed. It cannot
catch a credential that arrives as the *value* of an innocent key — the call
sites are the only defence there, and that is the honest limit of the mechanism.

**3. The public-repo rule is about COMMITTED FILES, not runtime data.**
`AGENTS.md` rule 1 — never commit a real IP, host, MAC, serial or domain to this
public repo — is real and stays. It says **nothing** about what telemetry may
contain at runtime: a span attribute holding labhost's real address is fine, a
markdown file holding it is not. Do not use rule 1 to argue for dropping a field.
(`kernelhive.madekivi.fi` is the one publishable domain, committed on purpose.)

**4. Volume is the only other reason to say no, and it must be MEASURED.**
One box, one disk. Every cap in these planes is allowed to exist for that reason
alone, and each one states its number at the constant. If you raise or lower a
retention or size limit, state the disk cost per day at current traffic, taken
from the live store — not a round number that felt safe. As measured 2026-09-01:
the trace store held **39 612 spans in 34 hours in ~28 MB** — about **710 bytes
per stored span**, **~20 k spans/day**, **~14 MB/day**. The 90-day window is
therefore **~1.3 GB** against **168 GB free** on `/data`. Retention here is a
`df` question and nothing else.

**5. One thing is genuinely undecided: typed keystroke CONTENT.** The actual
characters a visitor types, as opposed to timing, scancode class or record type.
The gallery has walk-in visitors who are real third parties, and capturing what a
stranger types is materially different in kind from everything above; it is also
genuinely useful (a stuck-key bug was debugged on 2026-09-01). It is therefore
**implemented and off**: `traces.TYPED_TEXT_ATTRS` behind the environment flag
`KH_TRACE_TYPED_TEXT`, default off, one env var away from on. **An agent must not
turn it on.** This is an operator decision and it has not been given.

**What was removed on 2026-09-01, so nobody restores it from a stale quote:**

| Restriction | Was | Now |
|---|---|---|
| `exception.stacktrace`, `code.stacktrace` | refused at intake | stored whole, 16 KiB allowance, exported to OTLP |
| `url.full`, `url.query` | refused at intake | accepted |
| `user.name`, `user.email`, `enduser.id` | refused at intake | accepted, and stamped by the SPA on the span that enters each trace |
| server-side `record_exception` | type only, no message, no stack | type + message + full traceback |
| attribute value cap | 120 chars (truncated a stack to one frame) | 2048, and 16384 for stack/URL-shaped keys |
| attributes / events per span | 24 / 16 | 64 / 64 |
| spans per batch, body cap | 512 / 512 KiB | 2048 / 4 MiB |
| trace retention | 14 days | 90 days (measured above) |

The counter plane (`analytics.py`) still holds no identity — that is a **table
shape**, not a policy: its rows are counts keyed by day, and a person has nowhere
to live in one. The correlated plane is where identity belongs, and it has it.

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

#### Typed CONTENT at the walk-in door — the one open operator question

This is a stranger typing, sometimes their own name, into a form and into a
guest, and it is the **single item §0 leaves undecided**. Today **nothing about
the content leaves the tab**: not the text, not its length, not a credential id.
Characters are counted only as the *denominator* of a percentage bucketed into
deciles before it is queued, so the count itself never travels.

That is the CURRENT state, not a principle this document is defending. §0 says
why: a walk-in visitor is a real third party, capturing what they type differs in
kind from everything else these planes carry, and **the operator has not been
asked**. The plumbing is in place — `traces.TYPED_TEXT_ATTRS` behind
`KH_TRACE_TYPED_TEXT`, default off — so the answer is one environment variable
rather than a fresh design. **An agent must not turn it on.** Everything that is
NOT content (timing, the coarse key class, the wire record type, the walk-in
handle itself) is ordinary telemetry and is governed by §0 like anything else.

**The FORM half of that sentence (name entry, the walk-in flow this section is
about) is unchanged: still zero per-keystroke telemetry of any kind.** The
GUEST half changed, deliberately, on 2026-08-31 and widened on 2026-09-01:
`three/streamClient/inputTrace.ts` traces **every** key and click edge into a
real timing span, chained across the browser, the daemon and the frame the
guest produced (§8.1, `docs/lab/TRACE-CONTEXT.md`) — an end-to-end input->pixel
flame graph the keyboard-lag investigation needed and no aggregate could draw.
This is a widening of what §8.1 already collects about the daemon side of a
visit. It stops short of the CONTENT question above and for that question's
reason only: what travels is a coarse class (`kh.key.class`:
printable/modifier/navigation/enter/function, `kh.input.class`: key/click) and
a duration, so nothing about which key it was is knowable from it — and that is
true of every edge now, not of one in ten. Dropping the old `SAMPLE_N` counter
was a **volume** decision, not a content one (§0.4): this section's own
estimate for going 1-in-1 was roughly a doubling of the store's daily span
count on a busy day, and that is the `df` decision that was taken. What
survives of sampling is a keep/drop at the **vendor export** only (§8.1), which
changes what Instana is shown and never what our own store holds or what leaves
the tab.

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

### 5.5 The stream event vocabulary — the plane that was dark

Everything in §5.4 measures the VISITOR: how long they waited, whether they gave
up. None of it measures what the streaming plane itself DID, and until
2026-09-01 nothing did. The audit that produced this section found eight holes,
and the shape of every one was the same: the fact existed in the tab, it was
sometimes written to `/clientlog`, and it never reached a durable plane.

* **Quality / bitrate / tier switches** appeared ONLY folded into the 5-second
  periodic `stats` line. That is a **sample**, not an event: it can say the tier
  was 3 at 12:04:05, and it can never say the tier CHANGED — a switch that
  happened and reverted between two samples left nothing at all. This lab has
  already been bitten by a fleet-wide ABR flap; the evidence for it had to be
  reconstructed by eye from sample lines.
* **Decode errors** were caught, so `installErrorCapture`'s window handler never
  saw them and `reportError` was never called. A decoder dying produced a
  console line inside one visitor's tab.
* **Keyframes** had no span, no metric, no flow and not even a clientlog row.
* **Audio** — `audioPlayer.ts` had zero telemetry. Autoplay block, a refused
  `AudioContext.resume()` and the first sample were all unobserved, so a station
  that is silent for every visitor and one nobody turned the sound on for were
  indistinguishable.
* **Reconnects** had no per-retry event. The only number,
  `station.open.attemptCount`, is committed on a painted frame — so a session
  that retried its budget away and never painted contributed nothing anywhere.
* **Client-internal stalls** (frame watchdog, decoder wedge, paused sink) were
  clientlog-only.
* **`transport.ts`** had zero emissions across all nine of its sites.
* **`retryBudget.ts`, `softwareDecodeLatch.ts`, `videoResume.ts` and
  `resumePolicy.ts`** were entirely uninstrumented. A visitor latched
  permanently into software decode — paying CPU for every frame of every station
  for the rest of the page's life — was invisible to us.

#### One call, four lanes

`analytics/streamEvents.ts` holds the vocabulary and is the only place it is
declared. `emitStreamEvent(name, attrs, value)` fans out to a **probe** (the
durable two-year count), a **metric** (the bucketed distribution of the event's
one number), a **span** named exactly as the event and opened as a child of
whichever flow is live, and — through a thin adapter — **Instana**. Nobody
instruments the same fact twice and the four lanes cannot disagree about it.

The event name, the span name and the probe id are the SAME STRING, so a query
written against one works against all three. `analytics/catalogue/stream.ts`
declares the probes and metrics; the taxonomy is their only call site, which is
the call-site gate working rather than a way around it — an id that fell out of
the table fails the build instead of quietly reading zero forever.

**One number per event, declared.** `customMetric` is a single number and this
plane has three ladders (`ms`, `count`, `pct`). An event carrying three numbers
would have to pick one for the vendor and invent ladders for the rest, so it
picks one HERE and everything else numeric rides as a span attribute, where it
is exact rather than bucketed. The clearest case is the quality switch:
`targetKbps` is an attribute (no honest kbps ladder exists), and the number that
gets a distribution is `stream.quality.sinceLastSwitchMs` — where a **LOW** value
is the finding, because tiers changing every few seconds is the flap signature
and a switch COUNT cannot separate it from a link that honestly degraded twice.

#### The contract

| event | fires when | attributes | number | sampling |
|---|---|---|---|---|
| `stream.quality.switch` | a KIND_PARAMS record differs in tier, CRF or target bitrate from the one in force | `tierFrom/To`, `crfFrom/To`, `targetKbps`, `width`, `height`, `fpsCap`, `reason` (`up`/`down`/`rate`) | `sinceLastSwitchMs` | 1-in-1 |
| `stream.decode.error` | every `noteDecodeFailure`, outside its 1/s console throttle | `error.type`, `consecutive`, `total`, `path`, `fatal` | `errorRun` | 1-in-1 |
| `stream.decode.rebuild` | a silently wedged decoder is dropped for a fresh one | `rebuild`, `rebuildMax` | — | 1-in-1 |
| `stream.decode.softwareLatched` | the page-lifetime hardware-decode demotion flips | `cause` | — | 1-in-1 |
| `stream.keyframe.gap` | `auGate.noteGap()` — a frame_id discontinuity | `gapFrames` | `gapFrames` | **1-in-10** |
| `stream.keyframe.timeout` | the first-frame budget expires with nothing painted | `budgetMs`, `live`, `restore` | `waitMs` | 1-in-1 |
| `stream.audio.start` | the first Opus sample scheduled onto a RUNNING context | `sampleRate`, `ctxState` | `toFirstSampleMs` | 1-in-1 |
| `stream.audio.blocked` | `resume()` rejects, or the first sample lands on a non-running context | `ctxState`, `error.type` | — | 1-in-1 |
| `stream.transport.retry` | `scheduleRetry` — per attempt | `attempt`, `limit`, `reason`, `live`, `restore` | `retryAttempt` | 1-in-1 |
| `stream.transport.exhausted` | `consumeRetry` reports the budget spent | `attempt`, `limit`, `live` | — | 1-in-1 |
| `stream.transport.closed` | `wt.closed` resolves, rejects, or `connect()` throws | `reason` (`server-finished`/`transport-down`/`connect-failed`) | — | 1-in-1 |
| `stream.stall.detected` | the frame watchdog LATCHES | `thresholdMs`, `hadDecodeError` | `sinceLastPaintMs` | 1-in-1 |
| `stream.sink.paused` | the watchdog first finds `isPausedSink()` true | `visible` | — | 1-in-1 |
| `stream.resume.decision` | `sessionNeedsReconnect` settles | `verdict` (`fresh-paint`/`ping-alive`/`ping-dead`) | `probeMs` | 1-in-1 |

Attribute names are given short above; on the wire each is `kh.<group>.<name>`
(`kh.quality.tierFrom`, `kh.retry.attempt`, …) plus the page binding, plus
whatever station dimensions the surrounding call site merged in.

#### Sampling, and the rule that is not negotiable

**The sampling decision is made once, upstream of every lane.** A sampled-away
event costs one counter increment and reaches nothing — no span, no probe, no
metric, no vendor beacon — so all four describe the identical population and
`n x sampleN` is the true count for every one of them. `kh.sample.n` rides on the
event so a reader can do that multiplication without knowing the source.

The default is **1-in-1**, and it is the right default because these events are
RARE and DIAGNOSTIC. **An error is never sampled**, and there is a test that
fails the build if an event marked `status: error` or `reportsError` declares a
rate. Exactly one event carries a rate: `stream.keyframe.gap`, at 1-in-10. It
earns it because it is the only member of the vocabulary that is a **level**
rather than an **edge** — a congested minute produces them continuously — and
because the quantity it feeds is a distribution of gap sizes, which sampling
does not bias. That rate is now this plane's own and nobody else's: the input
edges it used to borrow from (`streamClient/inputTrace.ts`) stopped sampling on
2026-09-01 and are traced 1-in-1 (§8.1).

Two other candidates for a rate were turned into edges at the call site instead,
which is the better fix every time it is available: the frame watchdog reports
its LATCH rather than its state, and the paused sink is latched in
`sessionTelemetry` and re-armed by a painted frame. Sampling a fault down is how
a report learns to under-state a fault.

#### Page binding — the capability Instana's browser agent does not have

Instana's browser `reportEvent` has **no `viewName` parameter**. The mobile SDK
has one; the browser one does not, so a custom event there correlates to a page
only implicitly, by landing in whatever page the agent's session state happened
to be naming at that instant. That is fine for a single-route page and useless
here: a visitor opens `/os/beos`, navigates to `/fleet` while the stream keeps
running, and every quality switch after that is attributed to the wrong page by
a mechanism nobody can query around.

So in our plane the binding is **explicit and travels on the event**
(`analytics/pageBinding.ts`):

* `kh.page.pattern` — the route PATTERN (`/os/:osId`, never `/os/beos`), so
  every station groups as one page. This attribute is the **roll-up key** and
  it did NOT change on 2026-09-01 when the page NAME became per-station (§8.2a):
  keeping it is exactly what made that change "both, not a swap". The concrete
  station is `kh.station.id`, and on a navigation also `kh.page.name`.
* `kh.page.loadId` — 16 hex, minted once per document. "Show me everything that
  happened on this page load" is an equality filter, not an inference.
* `kh.page.instanaLoadId` — the vendor's own `ineum('getPageLoadId')`, captured
  so the two systems can be reconciled for exactly as long as both exist.

The pattern is read from `location` at emit time rather than cached from the
router, because a cache is a second opinion about the current route that can
disagree with the address bar — and this binding exists so that it cannot be
wrong.

#### The Instana adapter is thin, isolated and deletable

`analytics/instanaStreamEvents.ts` translates an already-made decision and does
nothing else: no sampling, no naming, no defaulting, no enrichment. Deleting it
and its one call site removes Instana from the stream plane entirely and changes
nothing about what our own store receives — which is the point, since the vendor
is a benchmark the operator intends to drop.

Three vendor rules matter, and all three fail SILENTLY:

* `backendTraceId` must be **exactly 16 or 32 hex characters**. The minified
  agent validates it and drops the field otherwise; the docs state no such rule.
  Our own trace ids are already 32 lowercase hex, so nothing is reformatted —
  only checked. Unlike `inputTrace.ts`, which abandons its beacon when the id is
  unusable (there the join IS the beacon), a stream event is worth reporting
  with or without a join, so a malformed id costs the FIELD and not the event.
* `meta` values are **strings**, capped at the vendor's `maxMetadataKeys`
  default of 25. Coercion happens in the adapter, never at the call site — that
  is how our own span attributes would have silently become strings too.
* `customMetric` is **one number** at 4-decimal precision. A non-finite value is
  omitted rather than coerced to zero, because a zero is a real observation.

**No synthetic entry spans, and no span-kind changes.** A rejected design asked
for invented entry spans so Instana's UI would render something more
trace-shaped. It is not done and must not be added: it would make our own data a
function of a third party's rendering, which is the exact coupling the adapter
exists to avoid.

#### What is still not measured here, and why

There is **no keyframe REQUEST event, because the browser never makes one.** The
daemon forces an IDR on subscribe and runs a keyframe heartbeat, so no
client-side request channel exists to instrument. What a tab honestly has is two
ways of WAITING for a keyframe — the decode gate armed by a frame_id gap, and
the first-frame budget expiring — and those are the two events. Naming an event
after a mechanism that does not exist would have produced a permanent zero that
reads as "this never happens".

**`stream.recover` is still unwired on the WebRTC fallback path**, and this is
the precise reason. That flow is defined on the PAINT side — frames that reached
the glass — because the failure worth catching is exactly the one where the
encoder's account and the visitor's picture disagree. On the streamhost path the
tab decodes every frame itself and `sessionTelemetry.painted()` is a real
observation. On the WebRTC fallback the browser owns the `<video>` presentation
pipeline end to end and the app never sees a frame, so there is no honest
`painted()` to call; wiring the flow on a proxy (the element's `currentTime`
advancing, a `timeupdate`) would produce freeze durations measured against a
different definition of "moving" than every other station's, silently mixed into
the same distribution. The fallback is a WebCodecs-less browser's path and is
rare. Two things narrow the gap without lying: `station.connect` IS wired there,
so the funnel and the connect cost are not blind, and `requestVideoFrameCallback`
is the one API that would make a real `painted()` possible — that, not a proxy,
is what would unblock this.

Loss, RTT, bitrate as a distribution and encode time remain OUT of this plane
entirely. The boundary this document sets holds: *if the daemon could answer it,
this plane does not ask it.* What is in the vocabulary above is the client's own
DECISIONS and FAULTS, which the daemon cannot see.

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

### A measurement is not a span (changed 2026-09-01)

**Traces captured before 2026-09-01 are not comparable with later ones on this
point**, so the change is dated here rather than described as if it had always
been true.

Every `startTiming` used to open a **child span named after the metric**, push
it onto the active-span stack, and let the span's wall duration BE the value.
That was three mistakes wearing one design, and only the last was cosmetic.

1. **A measurement became the parent of real work.** Because the timing was
   pushed active, anything opened while the clock ran attached to it. In a
   captured operator trace (`fc4a9d74…`, win311) `station.open.toFirstFrameMs`
   was the parent of `http.client.request` -> `serve.signal`: the signaling
   fetch, and the daemon work under it, hung off a clock. That is a false edge
   in the trace graph — it asserts the HTTP call happened *because of* the
   measurement — and it misattributes real server work under a synthetic node.
2. **The duration was the value**, so a flame graph drew
   `station.open.toFirstInputMs` as 1.573 seconds of *work*. Nothing worked for
   1.573 seconds; that is the gap between two events, most of it a human
   deciding whether to touch the machine.
3. **Span counts and vendor aggregates.** One synthetic span per timing lands
   in Instana's call and latency rollups as a call that never happened.

A stopped timing now reports itself as an **OTel span event** — a timestamped
point carrying `kh.metric.ms` — on the innermost span genuinely open around it.
`station.connect` really does span the connect, so *"first frame painted at T,
260 ms in"* is a point inside it, which is what a span event is for. An event
cannot parent anything and has no duration to misread. Events have been carried
end-to-end since the intake was written (`_clean_events`, `scripts/serve/traces.py`;
exported by `traces_otlp.py`; rendered by `/admin/observability`'s span detail
pane, and surfaced by Instana in the call Details view).

**Where a timing has no open span around it** — a poster dwell, a hall
navigation, a hesitation measured after its connect flow has legitimately
closed — it falls back to a **zero-duration marker span**. That is not a
relapse: it is never pushed active, so it cannot parent real work, and its
duration is `0` rather than the measurement, so no flame graph reads it as
elapsed effort. Both defects above are gone; a drillable row is what is left.

This makes **call order load-bearing at the call site.** `Span.event()` after
`end()` is a silent no-op, so a timing must stop *before* the flow it belongs to
closes. `connectTelemetry.firstFrame`, `resumeTelemetry.painted`,
`useRestoreFlow`'s settle and `hallEngagement`'s open were all reordered for
this, and `spa/src/three/connectTelemetry.test.ts` fails if the order is put
back.

**Nothing was lost.** The bucketed sample still reaches the counter plane on
every `stop()`, unchanged — that is the durable two-year answer, and it is the
one that survives trace retention. Only the trace-plane representation moved.

#### Where each number is answerable now

| Question | Answer |
|---|---|
| the distribution / p95 of any `Ms` metric | **unchanged** — the metric plane. `/admin/observability` → Metrics, and `scripts/serve/analytics.py`'s bucketed `metric` table. Day resolution, two-year retention |
| this metric as an OTLP histogram in Instana | **unchanged** — `scripts/observability/instana_metrics.py`. Still **day resolution only**: the counters carry a day bucket and no per-sample timestamps |
| the exact value on ONE session's journey | `/admin/observability` → open the trace → select the span → the **events** pane. `kh.metric.ms` on the event, with the station dimensions repeated on it |
| when, precisely, first frame was painted | the event's own **timestamp** on `station.connect` — which the old design could not state at all, only imply from a span's end |
| why one connect was slow | `station.connect`'s real children — `http.client.request`, `serve.signal`, `streamhost.session` — which are now direct children of the connect instead of buried under a clock |

**Why nothing moved to the metric plane *only*.** That leg is day-resolution by
construction, so a latency metric living there alone would lose all sub-day
resolution and every per-session drilldown. Every `ms` metric therefore keeps
both homes: the bucketed counter for the durable aggregate, and a span event for
the exact per-session value. **The follow-up this defers, stated as the gap it
is:** there is no fine-grained metric path — no per-sample timestamped metric
export — and until one exists the span event *is* the sub-day resolution. Do not
read this as an argument that one is unnecessary.

### The three shapes, and the traps

| Call | For |
|---|---|
| `startTiming(id)` | a duration. `stop()` records a bucket AND a span event; `abandon()` records **nothing**, on either plane |
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
process than the one they are looking at. Spans make one ACTION one flame graph
across four processes, which is the only shape in which "was it slow because the
guest was asleep" is a lookup rather than a timestamp-correlation exercise. One
action, not one visit: a trace that meant "a visit" is what this plane had until
2026-09-01, and what it cost is below.

**The two planes do not overlap and both stay.** Per-frame and per-record data
belongs in counters; spans mark transitions, one-offs and ACTIONS. **There is
still no span per frame and none per pointer-motion sample** — at 60 fps that
would be 3600 spans a minute per station and 219 600 across the fleet, and
motion is a continuous signal a histogram describes better anyway. A key or a
click is neither: it is a discrete thing a visitor did, it is what the
keyboard-lag work is about, and since 2026-09-01 every one of them gets a trace.
The session marks are still one-shot `AtomicBool::swap`s, so the encoder relay
and the datagram loop pay one relaxed load and nothing else.

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
| `input.edge` | client (browser) | ONE key or click, root of its own trace, and its DURATION is the visitor's edge -> painted-pixel round trip (see below). An edge no frame ever answered still lands, with `kh.input.answered=false` |
| `input.wire` | client (browser) | the local handoff into the QUIC stream writer — where backpressure in this tab shows up. Not the hop's cost: two clocks cannot be subtracted, so the hop rides as `kh.transport.rtt_ms` |
| `input.dispatch.key` / `input.dispatch.click` | server | that record reaching the daemon's sink and the guest write it caused, as one span (`input.rs` has no headroom left to split it further — see the trap below). Named per input class; bare `input.dispatch` is the fallback for an unrecognised one |
| `guest.frame.next` | internal | the EFFECT: how long from that injection to the next frame this session's capture/encode pipeline produced. Carries `kh.encode.latency_us` (`Au::encode_us`, `worker.rs`'s snapshot->AU-ready number, formerly journal-text only) |
| `transport.frame.next` | internal | the same edge's frame reaching the wire — splits capture/encode cost from egress cost, same idea as `capture.first_frame` vs `transport.first_frame` |
| `client.frame.receive` *(browser)* | internal | the AU's bytes arriving off the wire to being handed to `VideoDecoder.decode()` |
| `client.frame.decode` *(browser)* | internal | the WebCodecs decode itself, per-frame, for THIS traced frame — not the ABR aggregate `decodeMs` already reports |
| `client.frame.paint` *(browser)* | internal | the paint sink's own synchronous cost (`drawImage`, the direct-canvas path) — closes the trace at the pixel |

The four session stages are all measured from the session's own start, so they
read side by side: `capture.first_frame` short and `transport.first_frame` long
is egress; `guest.resume` dominating both is a guest that was idle-paused, and
no other layer can say that.

**A TRACE MEANS ONE ACTION, since 2026-09-01.** One key or click edge, one
`station.connect`, one `station.restore`, one page load — each is its own trace
with its own root, never children under `streamhost.session` and never under
the page load. The shape this replaced was "a trace means a visit": a 15-second
window (`pageLoadJoin.ts`) made the tab's early traces CHILDREN of the server's
`serve.page` span. One captured trace on win311 held 43 spans from three
producers, spanned 15.7 s and was still taking writes 74 s in, with five
keystrokes sitting as siblings seconds apart — and the window made the shape
non-deterministic, since eight key edges inside it came out parented and eight
clicks fifteen seconds later came out as roots. Two shapes for one thing,
decided by a stopwatch, and every consumer had to cope with both.

**The relation to the page load is still recorded — twice, deliberately**
(`spa/src/analytics/pageLoadLink.ts`): an OTel **span LINK** on the trace's
entry span naming `serve.page`'s trace and span (`kh.link.kind=page.load`), and
the **`kh.page.loadId` attribute** already minted per document (§5.5). Neither
substitutes for the other. A link is what a UI **navigates** — one click from a
slow keystroke to the page load it happened on — and cannot be filtered or
grouped by; an attribute is what a query **groups by** ("every action on this
page load", one equality filter, in our own SQL and in Instana's Unbounded
Analytics) and cannot be navigated. The link also needs no window, no count and
no consumption: a parent claims containment, which goes stale ten minutes into
a visit, while a link claims only "this action happened on that document",
which is true for the life of the JS realm.

**Every key and click edge is traced.** The browser decides —
`three/streamClient/inputTrace.ts` — mints a fresh trace per qualifying edge and
appends its 25-byte context (a marker byte, a 128-bit trace id, a 64-bit span
id — no flags byte, since presence on the wire already means sampled) to that
record. The `SAMPLE_N` counter that used to trace one edge in ten is gone, and
it went for three faults, not for cost: it ALIASED (input is periodic — auto
repeat, a held key, a drag — so an every-Nth counter can lock onto one phase of
a burst forever), it applied one rate to populations differing by orders of
magnitude (a rare, deliberate click got the same 10% chance as the two-hundredth
sample of a drag), and it discarded precisely the interesting events — an 800 ms
keystroke had a 90% chance of never being traced, and the tail IS the signal for
latency work. That third fault is unfixable at the source at any rate, because
the decision happens BEFORE the round trip: this code cannot know which edge
will turn out to be the slow one. **Mouse motion is still not traced, and not
for volume**: motion is a continuous signal sampled at up to ~250 Hz, better
described by a rate and a latency histogram than by thousands of span trees —
you cannot read a distribution off a list of flame graphs. An exemplar belongs
beside that histogram, not before it.

The input plane is raw WebTransport records with no headers (§3 of the trace
contract), so the suffix is the only place left to carry the context, and `streamhost/streamhost/src/input_trace.rs` is where the daemon
recognises it — never invents one, exactly like every other hop in the
contract. Old browser against new daemon and new browser against old daemon
both keep working: the suffix's length is checked against every base length
either record shape has ever shipped, so an old daemon reads its fixed fields
off the FRONT exactly as before and ignores an unrecognised tail, and a new
daemon facing an old browser's exact-length record simply finds no suffix.
Measured cost of the suffix-less path (`input_trace.rs`'s own test): **~6 ns per
record**, the same league as §8's probe hits — and it is now the path a
tracing-DISABLED tab takes rather than nine edges in ten. `guest.frame.next` and
`transport.frame.next` are parented on the daemon's `input.dispatch.*` span, not
on the browser's root directly, so a flame graph reads input -> dispatch ->
effect as one chain; they fire only when a traced edge is actually pending (one
relaxed atomic load per frame otherwise — the encoder relay's existing budget,
unchanged).

**The daemon's entry span is named per input class** —
`input.dispatch.key` / `input.dispatch.click`, with bare `input.dispatch` as the
fallback (`trace_session.rs::dispatch_span_name`, an exhaustive match on
`&'static str` so a formatted name can never invent an unbounded set of
endpoints). The reason is a vendor fact, stated as one: Instana derives an OTLP
**endpoint** from the entry span's name (`{otel.operation}` —
`instana-docs/0251-monitoring-applications.md`, "Endpoints -> Predefined
rules"), so one name gave keyboard and mouse a single endpoint row and one
merged latency distribution. Two names, two rows. The vocabulary matches the
browser's `kh.input.class` word for word, which is what keeps the two ends from
disagreeing about what "click" means.

**The return leg (added 2026-08-31) closes the trace at the pixel.** Until
this, "input->pixel" was really input->frame-SENT: the daemon's own transport
send, never the bytes arriving, decoding or painting. The browser cannot know
which `frame_id` answered its own traced edge on its own — WebCodecs only
ever hands back the frame's OWN capture timestamp, never "this was the effect
of edge X" — so the daemon tells it: `transport/mod.rs`'s egress loop, right
after `effect_sent` names the answering `frame_id`, spawns a tiny out-of-band
wire message (`transport/egress.rs::spawn_frame_mark`, KIND_PARAMS subtype 3 —
the SAME additive extension point subtypes 1/2 already use for encoder-params
and HUD stats, not a new mechanism) carrying `frame_id` plus the trace/span ids
to answer with. Sent once per traced input edge, never per frame, and spawned
rather than awaited so a slow or lost mark can never hold up the video AU it
describes.

The browser (`three/streamClient/frameTrace.ts`) matches that mark against its
OWN receive/decode/paint timestamps for the SAME `frame_id`, by explicit id,
never by assuming "the next frame I painted is the answer" — the mark and the
AU it names travel on two independent uni-streams the network is free to
reorder against each other, and ordering-based correlation fails precisely
under the load and loss where this measurement matters. Two small bounded
FIFOs (capacity 64, matching the daemon's own "one pending edge" scale, not a
working set) hold whichever side arrives first; a mark or a frame that never
finds its match simply ages out — the daemon's half of the trace still stands
alone. `client.frame.receive` / `client.frame.decode` / `client.frame.paint`
are emitted only once both halves are in, as siblings of `guest.frame.next` /
`transport.frame.next` under the same `input.dispatch.*`:

```
input.edge                    (browser, ROOT — link -> serve.page,
│                              kh.page.loadId; its DURATION is the
│                              edge -> painted-pixel round trip)
├─ input.wire                 (browser — local handoff to the QUIC writer)
└─ input.dispatch.key         (daemon — .click for a button edge)
   ├─ guest.frame.next        (daemon — kh.encode.latency_us)
   ├─ transport.frame.next    (daemon)
   ├─ client.frame.receive    (browser)
   ├─ client.frame.decode     (browser)
   └─ client.frame.paint      (browser)
```

**The round trip is the ROOT's duration, not a sibling span.** `input.edge` now
stays open until the daemon names the frame that answered it and
`frameTrace.ts` ends it AT that paint, so the one number the operator actually
asks for — "how long until I saw it" — is the root's own duration, and it is
the one figure in the whole tree that needs no clock agreement: both ends are
`performance.now()` readings from the same tab. It replaced a separate span,
`client.input.roundtrip`, which carried exactly this figure beside a root whose
own duration was 0-1 ms of local enqueue — so every consumer that reads a root's
duration (a trace list, a latency percentile, Instana's endpoint view) read 1 ms
for something a visitor waited 240 ms for. An edge that no frame ever answers is
settled after 3 s and still lands, with `kh.input.answered=false`: "no frame came
back" is a value in the store, not a missing row. The timeout is generous on
purpose — the open keyboard-lag investigation is about round trips that are TOO
LONG, and a tight cap would discard exactly its evidence.

**KEEPING EVERYTHING HERE, DECIDING AT THE VENDOR LEG.** Our own store keeps
every action on purpose — one box, our own disk, our own data, and completeness
beats cleverness when nobody is short of capacity. What needs protecting is
Instana's Calls and Services views, where routine traffic drowns the traffic
worth looking at (the operator has raised that twice), so the keep/drop decision
lives at the export instead: `scripts/observability/tail_sampler.py`, run by the
forwarder. **It is not a capacity measure and must not be "optimised" as one.**

It can live there at all because we already own the collector a tail sampler
needs. Tail sampling normally requires something that buffers a COMPLETE trace
before deciding, which is hard across processes — the browser cannot decide for
spans the daemon has not emitted. `traces.db` is that buffer: all three producers
land in it, and the forwarder already waits for a trace to go quiet
(`instana_backlog.QUIET_MS`, 210 s) before shipping. This adds a decision to that
wait and no new machinery. It keeps **every error** (a 1-in-N failure record is
worse than none, because it reads as a rate), **every slow action**, and **1 in
10 of the rest, chosen by a coin** — random rather than every-Nth for the same
aliasing reason the source-side counter was deleted for. Anything it cannot
classify is FORWARDED: a dropped trace is unrecoverable, a duplicate costs a row.

"Slow" is a rolling p95 of the last 512 completed actions, with a FLOOR that is
derived rather than chosen. A constant cannot be right on this fleet:
`transport.frame.next` over 597 real samples runs p50 43 ms, p90 243 ms, p99
489 ms — an elevenfold spread inside one distribution, before a 1982 Spectrum and
a w2kalpha are even compared. The floor models the visitor-facing round trip from
the same store's measured parts at p90: 243 ms (daemon injection -> wire) + 23 ms
(client receive/decode/paint, n=27) + 13 ms (`kh.transport.rtt_ms`, n=49) =
**279 ms**. It says: never call an action slow when nine in ten of real traffic
are already at least that slow. Without it a good hour would drag the rolling p95
down to tens of milliseconds and the export would start forwarding ordinary
actions as "slow", which is the noise the mechanism exists to remove.

**The sampling factor is ours, and we claim nothing about the vendor reading
it.** Instana's call detail reads `Sampling factor: 1` whatever we do, and
under-reports accordingly. Whether an OTLP producer can DECLARE a factor is **not
documented**: the 326-file docs corpus never mentions "sampling factor",
`sampling.factor`, extrapolation, or an `x-instana-` header for one. The single
adjacent hint is a PHP-tracer release note
(`instana-docs/0006-tracers-and-autotrace-webhook.md`) about that tracer
capturing an OpenTelemetry TraceState sampling threshold and reporting it —
implying an OTEP 235 `tracestate` path that is documented for no other producer
and promised to nobody. So the exporter stamps `kh.sampling.factor` (1 when kept
for cause, 10 when kept at random) and `kh.sampling.reason` (`error`/`slow`/
`random`) on the EXPORTED spans only. `traces.db` never carries them: it kept
everything, and a sampling factor there would be a lie.

**COUNTS NEVER DEPEND ON ANY OF THIS.** "How many clicks happened" comes from the
always-on counter plane — `three/usageStats.ts` tallies every key and click per
station to `/usage`, and the `station.key.used` / `station.pointer.used` probes
land in `analytics.db` — and neither passes through the sampler. The sampler only
ever decides which actions Instana is shown a flame graph FOR.

**Numbers do not cross 2026-09-01.** Traces recorded before that date have a
different SHAPE and a different meaning: a trace was a visit (early ones parented
under `serve.page`), and an `input.edge` root measured ~1 ms of local enqueue
rather than the round trip, which lived in a sibling `client.input.roundtrip`.
Any percentile, endpoint latency or trace-count trend that spans the boundary is
comparing two different measurements. Cut the window at the date, or read the two
halves separately.

**Grouping dimensions.** A second stream landed station-type grouping
(`kh.station.emulatorFamily` / `kh.station.ui` / `kh.station.resetMode`,
`spa/src/analytics/stationAttrs.ts`, 2026-08-31) on the FLOWS plane
(`analytics/flows.ts`'s `beginFlow`/`tag`) partway through this work — this
return leg reuses its `kh.station.id` key on `client.frame.*` (the SAME id
`StreamClient.stationId` already carries, threaded through the return-path
mark into `frameTrace.ts`'s emitted spans) so a query joins the same way
across both planes. The other three dimensions were deliberately NOT threaded
this deep: `stationAttrs()` needs a resolved manifest row
(`emulatorFamily`/`uiKind`/`resetMode`), which lives a layer above the decode
pipeline (`useStreamhostSession`) and is not currently passed into
`StreamClient`'s config — wiring that through was judged out of scope for a
change about closing the return leg, not about threading a new field through
the client's constructor. Nothing on the Rust side carries any of the four:
`Config` has no registry read for emulator family, ui kind or reset mode, so
every daemon span (`guest.frame.next`, `transport.frame.next`, and everything
in the table above) still relies on its unconditional `kh.station` (bare, the
pre-existing key `trace/mod.rs::render` stamps on every span) as the join key
back to the registry for that grouping, exactly as before this change.

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
back-to-back on the lab build box; re-measured 2026-08-31 alongside the return
leg above, box variance is real and the numbers move run to run):

| profile | disabled | enabled (1 attribute) |
|---|---|---|
| `--release` (opt-level 2 — what ships) | **50-70 ns** (76 ns latest run) | **3.2 us** (3.43 us latest run) |
| default `cargo test` (debug) | 214 ns | 9.3 us |

The return leg adds no new per-frame cost: `spawn_frame_mark` only ever runs
when `effect_sent` already returned `Some` — the same "traced edge with a
pending effect" gate `guest.frame.next`/`transport.frame.next` already pay
for — so its real cost (one QUIC uni-stream open/write/finish) is bounded by
the INPUT RATE (a visitor's keys and clicks, one mark each since the sampler
went away), never by frame rate, and is spawned off the egress hot path so it
cannot add latency to the video AU it describes.

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

**Shipped by `kh-trace-ship.timer`, every two minutes.**
`scripts/observability/trace-ship.py` is the carrier the paragraph above
predicted: it reads each finished batch file in a station's spool, `POST`s it
verbatim to `/traces`, and deletes it only on a 200. It runs ON the box, as
root, because the spool is root-owned by the daemon and the tool needs to delete
what it ships; run from CT950 instead with `--apply --keep` and it can still
ship, just never clean up after itself.

It was hand-run until 2026-09-01, on an argument about the spool being bounded
(`SH_TRACE_SPOOL_MAX`, oldest dropped) so nothing overflows while nobody ships.
That was true of the spool and false of the store: an unshipped batch is a
daemon span missing from `/admin/observability` and from everything downstream,
so "nothing overflows" was never "nothing is lost". The unit and timer live
beside the script and are installed by `box-deploy.sh`; **enabling them is a
separate operator action** (§8.1). Re-running is always safe —
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

**It runs on a timer, and its watermark is INGEST ORDER, not trace start
time.** Both facts date from 2026-09-01 and both were bugs before it. Hand-
running meant every view it feeds was stale by default, which is how a
measurement doc came to be written from a tenant nobody had forwarded to in
days — `kh-instana-forward.timer` now runs `--scheduled` every five minutes,
and the run logs its watermark and backlog so staleness is visible in
`journalctl -u kh-instana-forward` instead of being invisible by construction.
The watermark bug was worse, because it lost data silently: the forwarder
selected traces by `started_ms` and advanced past the highest one it shipped,
while a trace's browser half arrives up to a `sink.ts` flush interval LATER
carrying an EARLIER start time (§8's own resummarise comment says the server
half usually wins that race). Anything that landed after a run had passed its
trace was never selected again by any future run, which is precisely what a
call with no parent looks like from inside Instana. The store now stamps each
trace with an `ingest_seq` that moves every time a span lands in it, so a late
arrival pulls its whole trace back in front of the watermark; a 90-second quiet
window on top holds a trace until it stops changing, which keeps duplicate
sends rare without ever being the thing correctness rests on. See the
`pending_traces()` docstring for why the alternatives lost and what re-sending
means on IBM's side.

**A run drains the backlog, and a request is bounded in SPANS and BYTES — not
in traces.** Landing the timer exposed two more defects the same afternoon, and
both are worth knowing because both were invisible from inside Instana (the
symptom for each is "the chart is empty"). First, a run shipped exactly ONE
batch of 100 traces and exited, which on a five-minute timer is 20 traces a
minute against a store measured taking 23 a minute: the pipeline could not
catch up from any backlog, sat 991 traces behind, and the Applications → Calls
view flatlined about 25 minutes behind reality — a visitor simulation's traces
took the better part of an hour to appear. A run now keeps shipping until it is
caught up or until a 120-second budget stops it (40% of both the unit's
`TimeoutStartSec=300` and the timer's own 5-minute period, because an
over-running oneshot is killed AND costs the next tick, which would lose ground
at exactly the moment it was catching up). Draining the 991-trace backlog takes
ten requests and about three seconds.

Second, 100 traces is not a size. Trace size here spans four orders of
magnitude — a `serve.clientcmd` poll trace holds one span while a live browser
session accumulates thousands of `input.edge` spans into a single trace — and
one such batch carried 16,226 spans in 9.6 MB, which the agent refused by
closing the connection mid-upload (`[Errno 32] Broken pipe`, no HTTP status,
twice in a row). Probing the agent's OTLP receiver put its wall at exactly
5 MiB, which is the documented *minimum* of `INSTANA_AGENT_OTEL_HTTP_MAX_MESSAGE_SIZE`
(configurable to 49.5 MB, if requests ever need to be bigger). Batching is now
by span count and serialized bytes, budgeted at 4,000 spans / 4 MiB, and a
single trace over that is SPLIT across consecutive requests. Splitting is safe:
this plane already relies on it, since a trace's server half and browser half
reach Instana in different runs minutes apart and assemble correctly. The one
real caveat is IBM's ~2-second trace-assembly window (`0280-custom-tracing.md`),
so the few pieces of a very large trace may correlate imperfectly — a
cosmetically split trace view, against the alternative of never shipping it and
stalling everything behind it. Every run now prints `backlog: N trace(s)
behind`, including `0`, so falling behind is a line in the journal rather than
something to infer from an empty chart. `instana_batch.py` holds the numbers
and the probe that produced them.

**Five minutes was re-examined and KEPT**, which is worth saying because the
throughput fix removes the reason anyone would shorten it. The period was never
the bottleneck — one batch per run was — and now that a run drains, the worst
case age of data in the tenant is one interval plus the 90-second quiet window,
i.e. under seven minutes, against a store taking ~23 traces a minute. Dropping
to one minute would buy roughly four minutes of freshness and cost five times
the runs, five times the journal, and five times the chance of a run landing
inside a trace's quiet window and shipping it twice — Instana does not
de-duplicate re-sent spans (docs silent, so assume not), and duplicates are the
one error mode the quiet window exists to keep rare. If sub-two-minute
freshness is ever wanted, `OnUnitActiveSec` is the one line to change and
`RUN_BUDGET_S` must come down with it, since the budget is defined as a
fraction of the period.

**Neither timer is armed by landing this.** `box-deploy.sh --apply` installs the
units; the operator enables them — the commands are in
`docs/lab/INSTANA-VIEW-INVENTORY.md` §2.

## 8.2 Instana: a benchmark, not a dependency — and a temporary one

**The rule.** Every capability this plane has must work correctly with
Instana entirely absent. Instana is there so this lab can see what a mature
commercial APM shows a visitor's journey, decide what of that is worth
replicating in kernel-hive's own store, and then build it here — never so
kernel-hive can lean on IBM's SaaS for something it does not do itself. The
operator has said so three times over in different words across one session,
and the decisions below are what following it actually looked like, not a
restatement of intent.

**Never bend our data model to please the vendor.** `input.dispatch` is
`Kind::Server` (`docs/lab/TRACE-CONTEXT.md` §3.1) because it genuinely IS the
daemon's receiving side of the browser's client-kind `input.edge` span — the
same RPC pairing `serve.signal` already uses — and marking it `Internal`
understated what it already was. That it also happens to be the reason
Instana's `analyze/traces` API can now attach a `service.name` to an
`input.edge` trace instead of labelling it `"Unspecified"` is a welcome side
effect of a correction, not the justification for it. Contrast the idea it
sits next to and rejects: relabelling a **browser**-kind span as `server`
purely so Instana would stitch a trace together was turned down in an earlier
session for exactly the opposite reason — it would put a lie in the data. Same
question both times ("what kind is this span"), same vendor watching, opposite
answer, because only one of the two spans actually changed kind.

**Capability parity is the goal, not admiration.** Where Instana's auto
instrumentation does something this plane's own code did not — it patches
`fetch`/`XHR` globally and propagates `traceparent` to every same-origin call
without a call site remembering to ask — the fix was to build that in
kernel-hive's own plane (`spa/src/analytics/khFetch.ts`, landed 2026-08-31,
whose own header calls out the race it had to resolve against Instana's
patch), not to depend on Instana supplying it. The alternative — leave
propagation opt-in and let Instana's agent quietly cover the gap — would have
meant that pulling Instana back out returned the plane to 2 of 24 `fetch`
call sites carrying trace context, and that the gap analysis this whole
integration exists to run would have been flattered: linked traces admired in
Instana that kernel-hive's own plane structurally could not have produced on
its own. Every capability gained this way is exactly the thing that has to be
true **before** Instana can be switched off, not merely nice to also have
while it is present.

**Where the vendor cannot help, the gap is permanent and this lab's alone.**
There is no Instana sensor for QEMU or any other emulator (§6 of
`docs/lab/TRACE-CONTEXT.md`: "the emulator is deliberately not traced from
inside"), so emulator-internal visibility — was the guest actually awake,
where did a frame stall inside the capture pipeline — was never something a
vendor integration could shortcut. It is a poor thing to prototype in Instana
and exactly the thing `streamhost`'s own span plane (§8.1) exists to build.

**Removable, checked against the code rather than assumed.** The operator's
stated intent is to drop the dependency once this plane's own tooling has the
views it needs — no removal date and no checklist of views is fixed here,
because the operator has not named the bar and this doc will not invent one.
What can be stated is how clean the off switch actually is, verified against
the three places Instana touches this repo, not asserted:

- **The browser agent is inert without configuration, and cleanly so.**
  `spa/index.html`'s inline bootstrap reads `VITE_INSTANA_WEBSITE_KEY` /
  `VITE_INSTANA_EUM_REPORTING_URL` (Vite substitutes these from
  `registry/local.env`'s gitignored `INSTANA_WEBSITE_KEY` /
  `INSTANA_EUM_REPORTING_URL` at build time) and returns before doing
  anything — no `ineum` stub, no script tag, no request to any Instana host —
  the instant either value is unset or still the raw placeholder text. Blanking
  `INSTANA_WEBSITE_KEY` in `registry/local.env` and rebuilding/redeploying the
  SPA is the whole off switch for the browser half; nothing else references
  the key. Note what the second variable now carries: since §8.4 it is
  substituted as the **first-party path** `/eum`, not the tenant's reporting
  URL, so the tenant URL is no longer in the bundle at all.
- **The beacon proxy comes off with it, and is the newest of the legs.**
  `scripts/serve/eum_proxy.py` (§8.4) exists solely because Instana does. It
  deletes as one commit — the module, its `telemetry_routes` row, its
  `gate.WALKIN_PATHS` entry, its `box-sync-pairs.sh` row, its
  `KH_TELEMETRY_PATHS` entry and `serve-https-spa.sh`'s
  `publish_instana_upstream` — and nothing else in the tree references it.
  Clearing `INSTANA_EUM_REPORTING_URL` turns it off without a code change:
  the route then 404s, exactly as it does on a fresh clone.
- **`instana-forward.py` is already the minimum-commitment shape.** It has its
  own `--dry-run` and its one credential, and since 2026-09-01 one timer
  (`kh-instana-forward.timer`, §8.1). `systemctl disable --now
  kh-instana-forward.timer` — or simply clearing `INSTANA_ENDPOINT`, which makes
  every scheduled run a logged no-op — is itself "off" for anything this repo
  ships to Instana.
- **The labhost host agent is NOT this repo's to switch off.** Unlike the two
  above, `systemctl status instana-agent` is a separate IBM-supplied install
  on labhost, started independently of anything in this repo (§8.1) — removing
  it is a box-level operator action (stop and uninstall the package), not a
  `registry/local.env` edit or a redeploy. Anyone reading "removable" as "one
  repo change" would be wrong about this third of it.

So three of the four legs come off with a config edit and a rebuild; the
remaining one is a genuinely separate install that needs its own teardown on
labhost whenever the operator decides to do it.

One fact worth recording rather than planning around: the Instana UI reported,
as read on 2026-08-31, that this tenant is a trial expiring in 14 days. That
may force the exit before this plane's own views are ready, independent of
whatever order the operator would otherwise have chosen.

## 8.2a Page names: the station, not the route pattern (changed 2026-09-01)

**The rule, as of 2026-09-01.** The page name this app reports — to Instana via
`ineum('page', ...)` and to our own store as `kh.page.name` — is the **concrete
station**: `/os/beos`, `/walkin/play/win311`. The route **pattern** (`/os/:osId`)
goes out beside it as `kh.route.pattern` — `meta` on the vendor's plane, a span
attribute on ours — and `kh.page.pattern` (§5.5, page binding) is unchanged.
Before this date the page name was the pattern alone.

**Read any page-name comparison across 2026-09-01 as two different questions.**
A "page" before that date is a route; after it, a station. Nothing rewrites
history in either store, so the dimension is genuinely discontinuous at that
timestamp — and today's data is already a construction site for several other
reasons (the beacon proxy, the log plane, the metric-span split of the same
week). Do not put a trend line through it.

### Why per-station, when the RUM convention says otherwise

Every RUM tool teaches you to template the page name, and the teaching is
correct — for the thing it is about. Templating exists to stop **unbounded
identifiers** (a user id, an order id, a cart id) from exploding the page
dimension into one row per visitor, at which point the dimension answers
nothing and costs everything.

`osId` is not one of those. It is a **fixed registry** — one file per station in
`registry/stations/`, one name each, enforced by `scripts/stations-registry.py`
— that grows by a station every few weeks, by hand, through a documented
playbook. A dimension whose value set is a curated list of exhibits is a
legitimate dimension, not a cardinality leak.

And the stations are genuinely different products. Golden-restore times measured
on this box on one day:

| station | golden restore |
|---|---|
| `win95` | 639 ms |
| `beos` | 1695 ms |
| `amiga` | 2535 ms |
| `zxspectrum` | 17.2 s |

An order of magnitude, inside one "page". Averaging a QEMU x86 guest with a
MAME-driven 8-bit micro produces a number that describes no exhibit anybody can
visit, and hides exactly the variation worth looking at. The generalised name
was answering "how is the station page doing" — a real question, and the only
one it could answer.

### Both, not a swap — and the roll-up is verified, not assumed

So the roll-up question keeps its answer. `kh.route.pattern` is emitted as
`meta` on the vendor's plane, which its page-load view filters on, and as a span
attribute on ours. A pure swap would have traded one blindness for another:
per-station detail bought at the cost of never again being able to ask how the
station page as a whole is doing.

### The bound, and where it actually is

The registry is finite, but the URL is not: anyone can request `/os/anything`.
So neither copy of the naming logic substitutes a param value blindly. A value
enters a page name only if it matches `STATION_ID` — `^[a-z][a-z0-9]{1,15}$`,
which every id in `registry/stations/` satisfies (longest today: 12 characters).
Anything else keeps its `:name` placeholder, so an unrecognised path degrades to
**exactly the old pattern-only name**. The worst case of this change is the
previous behaviour.

Be honest about what that guard is: **syntactic, not a registry-membership
check.** The browser has no synchronous list of stations — the manifest is
fetched, and `spa/index.html`'s copy of this logic runs before any module
evaluates, so neither can wait for one. A determined crawler walking
`/os/aa`, `/os/ab`, … would still mint page names. If the page dimension ever
shows ids that are not stations, the escalation is to project the registry id
list into the bundle (a generated module for `navigation.ts`, and a Vite
placeholder for `index.html`, the mechanism `%VITE_KH_BUILD_ID%` already uses)
and check membership rather than shape. That is deliberately not built yet: it
is real duplication to maintain, for a failure mode that has not happened.

### Does Instana collapse high-cardinality page names? Docs silent.

Asked because the answer would have changed the decision. For **endpoints** the
vendor documents a collapse: "When too many endpoints are detected on a given
service, calls are grouped under the special 'Others' endpoint. This safeguard
is meant to keep the set of endpoints to a reasonable size"
(`0251-monitoring-applications.md`). There is **no equivalent statement anywhere
in the corpus for website page names.** `beacon.page.name` appears once, as the
grouping tag of the page-loads view (`0250-monitoring-websites.md`), with no cap
or "Others" language near it, and none in the mobile-monitoring or
known-issues documents either.

The only adjacent documented limits are the JavaScript agent's **per-tab rate
limits** — 128 beacons/10 s, 4096/10 min, 8096/page-load; page changes 32/10 s,
128/10 min (`0250-monitoring-websites.md`). Those throttle throughput per tab
and are indifferent to how many distinct names exist across the site; naming
per-station does not change how many beacons a tab sends.

So: **docs silent on page-name cardinality**. The empirical check on this
tenant (2026-09-01, `analyze/beacon-groups` grouped by `beacon.page.name`, 7-day
window) returned **6 distinct PAGELOAD page names and 5 PAGE_CHANGE ones, with
no "Others"-style collapse bucket among them.** That is honest but weak
evidence: the site has never had 63 page names, so the observation shows no
collapse *at the sizes reached*, it does not disprove one at 63. What makes that
acceptable is the syntactic bound above — the dimension cannot grow past the
registry plus the handful of static routes without a code change — and the fact
that the failure mode, if it ever happened, would be visible in the same query
and reversible in one commit.

#### Querying the roll-up: the filter syntax that silently returns nothing

Verified against the live tenant on 2026-09-01, because "the aggregate is still
queryable" is a claim that had to be tested rather than asserted. `beacon.meta`
is a `KEY_VALUE_PAIR` tag, and the two API shapes are **not** symmetric:

| purpose | shape | result |
|---|---|---|
| **filter** to one pattern | `{name: 'beacon.meta', operator: 'EQUALS', value: 'kh.route.pattern=/os/:osId'}` | works — `key=value` in one string |
| **group** by pattern | `{groupbyTag: 'beacon.meta', groupbyTagSecondLevelKey: 'kh.route.pattern'}` | works — one row per pattern |
| filter, the shape that reads natural | `{name: 'beacon.meta', operator: 'EQUALS', value: '/os/:osId', tagSecondLevelKey: 'kh.route.pattern'}` | **HTTP 200, zero rows** |

The third form is the trap: it is accepted, it is the obvious mirror of the
grouping form, and it matches nothing. `beacon.meta.<key>` as a filter or group
name is rejected outright (HTTP 400, "Invalid or unknown tag filter name"),
which is the better failure of the two. Anyone reading a zero out of a meta
filter should check the shape before concluding the meta is not there.

Both roll-up forms were confirmed to return the expected rows after this change:
filtering PAGELOAD on `kh.route.pattern=/os/:osId` returned the per-station page
names underneath it, and grouping on the meta returned one row per pattern.

### Where the page name is decided (all of it)

Three places, and they are three because two of them physically cannot import
the third:

| where | decides | why it is separate |
|---|---|---|
| `spa/src/analytics/navigation.ts` | every SPA transition, both planes | the canonical copy: `ROUTES`, `STATION_ID`, `pageName()` |
| `spa/index.html` inline bootstrap | the FIRST beacon of every visit | runs before any module evaluates; the page-load beacon fires ~1 s after `onLoad` and cannot be retroactively updated |
| `spa/src/App.tsx` | which routes exist at all | the router itself — the authority the other two are pinned to |

`analytics/pageBinding.ts` reads `navigation.ts`'s `matchRoute`, so it is a
consumer, not a fourth copy.

**They are pinned.** `scripts/test_page_naming_in_sync.py` parses App.tsx's
route declarations, both `ROUTES` copies, both `STATION_ID` copies and the
substitution/`meta` calls in each, and fails if any two disagree — with a
vacuous-pass guard, so a restructure that defeats the parsing errors rather than
asserting nothing. It exists because the identical duplication in
`TELEMETRY_PATHS` was missed twice in one day (`/eum`, then `/logs`, each added
to some copies and not the others), and the symptom showed up in the vendor's
UI rather than in a test. That guard is
`scripts/test_telemetry_paths_complete.py`; this is the same shape for the same
reason.

### One ordering bug fixed on the way

`ineum('page', ...)` **cuts** the page-transition beacon: the vendor's own API
reference says "make sure to change the page name last as this immediately
triggers the transition". `reportPageToInstana` used to call `page` first and
`meta` after, so the route params it sent landed on the *next* transition. Both
copies now set every `meta` first and the page name last, and both have a test
asserting the order.

### Walk-in clones report as the exhibit

The walk-in pool is `walkin-<station>-1/-2/-3` (poolSize 3). The clone id never
reaches the page dimension: `/walkin/play/:os` carries the **exhibit** id, and
the clone is named only inside the claim's `signalEndpoint` (§5.3 — a walk-in is
never handed another station's signaling document). Three clones of one exhibit
are one page, which is the analytically correct answer: they are the same
software on the same golden.

`/walkin/play/win311` stays distinct from `/os/win311`, also deliberately. A
private clone with a reset button and a queue is a different product from the
shared exhibit, and their timings are not comparable.

## 8.3 Which bundle was this client running — and old shell vs blocked beacon

**Every telemetry lane this plane owns names the client's build, and the answer
does not pass through a vendor.** `<branch>@<short-sha>` (`-dirty` when the tree
was; `unknown-build` when there was no git to ask) — the same string
`box-deploy.sh --status` prints, so the two compare character-for-character:

| Lane | Where the build id sits |
|---|---|
| `/traces` | the batch's **resource** envelope, `kh.bundle` (`spa/src/analytics/index.ts`) → stored on the `trace` row (`traces.build`) → exported as the OTLP resource attribute **`service.version`** |
| `clientlog.jsonl` | the `build` field, on the **first event of a batch**, exactly like `ua` |
| the boot-time error reporter | `build` on every `client-error` / `unhandled-rejection` row, from `window.__kernelHiveBuildId` — set by its own inline script so it survives a build with no vendor key |
| Instana (while it lasts) | the `kh.bundle` beacon meta. Same value, same source, and now the *least* authoritative copy |

One value, one place: `spa/src/analytics/build.ts` reads
`import.meta.env.VITE_KH_BUILD_ID`, which `vite.config.ts` computes once. The two
inline scripts in `spa/index.html` cannot import it — they run before any bundle
evaluates — so they read the placeholder Vite substitutes into the HTML instead.

**Why this is here and not only on a beacon.** On 2026-09-01 the operator used
the installed PWA on a phone. Our own plane recorded the visit in full: three
`serve.page` + `app.page` + `station.connect` traces, `class=human`, real
`input.edge` spans, a full `clientlog` tail. Instana received **nothing** — a
three-hour window held exactly one page load, a desktop probe. The first
question — *was that phone running the bundle we think we deployed?* — could
only be asked of a beacon that did not exist. The build id was recorded
**exclusively as vendor beacon metadata**, which is precisely backwards for a
dependency §8.2 says we intend to drop.

### The differential: telling "old shell" from "beacons blocked", using only our own data

Both look identical from the vendor's side (silence). They are trivially
distinguishable from ours. Ask, in this order:

1. **What build was it?** — `SELECT build, COUNT(*) FROM trace WHERE started_ms
   > … GROUP BY build`, or `GET /auth/traces/facets`'s `builds` facet, or
   `search` with `build=`. Two builds live in one window means somebody is on a
   shell the box no longer serves. **This is the direct answer, and it is the
   one that did not exist before 2026-09-01.**
2. **Did the HTML come off the network for THAT load?** — an `app.page` whose
   page-load LINK names a `serve.page` that started a second earlier is a
   **fresh document**: the `traceparent` that link was read from was minted by
   the serving plane while answering that very request
   (`scripts/serve/static_files.py` splices the meta into the served bytes).
   A cached shell replays an OLD meta tag, so its `app.page` links a
   `serve.page` that is hours stale — or links nothing at all. Read the LINK,
   not a shared trace id: since 2026-09-01 a trace is one action (§8.1), so the
   tab's entry is its own root and never shares the page load's trace id.
3. **Did the vendor agent even load?** — it is served same-origin from
   `/vendor/instana-eum.min.js`, so a `GET` for it appears in
   `/data/vms/streamhost/serve/https-server.log` beside the document request. A
   content blocker that matches the path drops it there, visibly. If the agent
   was fetched and the beacon still never arrived, the loss is on the leg this
   lab cannot see: the client to IBM's EUM host (DNS filtering, a content
   blocker, a private relay, a captive network).

**What that answered in the 2026-09-01 case**, and it refuted the leading
hypothesis rather than confirming it:

- Each of the three phone sessions had a `serve.page` span one second before its
  `app.page`, with `kh.route.kind: "initial"`. Three fresh document loads, not
  one cached shell. **Stale shell: refuted.**
- The access log for that minute shows `GET /os/irix` 200, then the current
  hashed `/assets/index-*.js`, then `GET /vendor/instana-eum.min.js` **200**.
  The agent was served. **"The keyless bundle was still being served": refuted**
  — a shell from that window would have carried no vendor script tag at all and
  would never have requested it.
- The traces carry `kh.auth.role: admin` on a signed-in session at `/os/:osId`.
  **`signedOutAtTheDoor` suppression: refuted** — and it never fitted anyway,
  since that gate cannot explain missing beacons while our own spans exist: it
  gates *both* planes together, so it would have silenced ours too.
- `kh.route.kind: "initial"` on all three. **"A PWA start_url produced a
  transition, not a page load": refuted.**

What is left is the one leg our own data does not reach: the beacon never got
from that phone to IBM. **Unproven which of blocking, filtering or an agent-side
failure it was**, and the plane cannot prove it from here — but the useful half
is now decided by evidence rather than by argument, and the next occurrence
starts at query 1 instead of a debugging cycle.

### The staleness trap the review found anyway

The hypothesis was wrong about that visit and right about the code.
`spa/public/sw.js` named its shell cache with a hand-written `kh-shell-v1` that
had never been bumped, and `activate` deletes only caches whose key *differs*
from the current one — so the cached HTML shell survived every deploy this
gallery has ever had. The worker is network-first, so it takes a failed
navigation (one flaky moment on mobile) to start serving that shell, and nothing
at all to keep it. And an HTML shell is not inert: it carries the inline
bootstraps — vendor config, session-id minting, the boot error reporter — so an
old shell means old boot behaviour even while the hashed bundle it names is
still on the box.

**The fix**: the cache name is derived from the build id, which
`spa/src/main.tsx` passes on the registration URL (`/sw.js?build=<id>`; a
registration's scope comes from the script's path, so the query changes nothing
about scope). Every deploy is therefore a different script URL → a new worker →
an `activate` that deletes every cache but its own. That **actively retires** a
`kh-shell-v1` a client is holding today, on its first online load after this
ships; it does not merely stop creating new ones. A worker that somehow loads
with no parameter names its cache `kh-shell-unknown` rather than pretending to
be a build. Nothing else moved: no app code or data is cached, navigations stay
network-first, and the offline fallback is still one HTML document. This is not
an offline app cache and must not become one.

`spa/src/pwa/serviceWorker.test.ts` executes the real shipped `sw.js` against
stubs and pins all of that. **What no test can prove is the device**: that a
particular phone, holding a particular old registration, actually installs the
new worker and drops its cache. That is verified by looking — open the installed
app, then `builds` in the trace facets should show only the current build for
that session.

## 8.4 The beacon proxy — first-party delivery for the vendor's own beacons

**The measurement.** The operator's phone runs a private-DNS ad/tracker blocker
(Blockada). One real PWA visit produced a complete record in **our own** plane —
`/clientlog`, `/analytics`, `/traces` — and **zero Instana beacons**. Nothing
was broken. The blocker refuses to resolve the vendor's reporting host, and a
beacon whose destination will not resolve is never sent.

That is worth stating as a property of this plane and not only as an Instana
defect: **our own telemetry has enjoyed first-party delivery since its first
line**, and that is precisely why it kept working when the vendor's did not.
Every endpoint in §2 is a path on the origin the page was served from — same
host, same TLS, same cookie, no second name for anything to filter. The
Instana half was the only part of this system that depended on a third-party
hostname resolving in the visitor's own resolver, and it was the only part that
disappeared.

**What was built.** `scripts/serve/eum_proxy.py` answers `POST /eum` on our own
origin, and forwards the beacon body verbatim to the tenant from the box. The
vendor SCRIPT was already self-hosted (`/vendor/instana-eum.min.js`, fetched at
deploy time), so the beacon POST was the last third-party hop; both halves are
first-party now. `scripts/serve-https-spa.sh` substitutes `/eum` into the
bootstrap's `reportingUrl`, so the tenant's URL never enters the bundle.

**The security posture and the blocking-vs-stalling decision** are written out
in that module's docstring and summarised in
[`docs/lab/INSTANA-VIEW-INVENTORY.md` §2.2](lab/INSTANA-VIEW-INVENTORY.md).
The short forms: one destination, from a box-side file, that no request can
influence; POST only, capped, no redirect, no client headers passed through;
gated exactly like `/traces` and never traced; and **the upstream call runs on
a background worker, not the request thread**, so an unreachable Instana costs
one thread and some telemetry rather than a slow gallery. The route answers 200
for *queued*, never for *delivered*.

**The trade-off, and the part of it that was NOT avoidable.** Instana derives
geography from the beacon's source IP and browser/OS from its `User-Agent` —
neither is in the beacon body. Browser/OS survives, because we forward the
visitor's own `User-Agent` (verified live: `browser=HeadlessChrome os=Linux`).
**Geography does not.** The documented escape (`X-Forwarded-For`, or
`X-REALER-IP`) is implemented and IBM honours it — proved by a run that
forwarded `127.0.0.1` and came back geolocated to `127.0.0.0` — but the real
client IP never reaches this process: labhost's Caddy is the last hop that
writes the header and it sees only the tunnel's loopback peer, so every request
arrives as `X-Forwarded-For: 127.0.0.1`. (Same reason
`auth/routes._client_ip` has been rate-limiting on a constant.) So the proxy
refuses to assert a non-routable address and geo falls back to the box's egress
IP: populated, and wrong for the first genuinely remote visitor. **The fix is
one commit in the edge repo, not here.** Full evidence and the exact change:
[`INSTANA-VIEW-INVENTORY.md` §2.3](lab/INSTANA-VIEW-INVENTORY.md). Kept in
proportion by §4.1's own reading: geo was already POPULATED BUT UNINFORMATIVE,
one household and one city.

**It is temporary.** It exists only because Instana does, and it is listed in
§8.2's off switch as its own leg for exactly that reason.

## 8.5 The LOG plane — the third pillar, and the only one that carries a stack

Until 2026-09-01 this lab had traces and metrics on two planes and **logs on
neither**. Instana's Logs pillar was empty; the serving plane's stdout went to a
flat file with no timestamps; the daemon's 747 000 lines a day went to journald
and nowhere else; and the one queryable record of anything — `clientlog.jsonl` —
was a rolling JSONL file with no severity and no way to relate a line to the
span it happened inside.

**The value is not shipping log files somewhere. It is a log record joined to a
trace.** Every record carries `trace_id`/`span_id` where a span was in scope, so
a slow `guest.attach` and what the daemon printed during it are one query apart
— in our own store and in Instana, which takes the same two fields "without any
alterations" ([`docs/lab/research/instana-logs.md`](lab/research/instana-logs.md)).

### The model

`scripts/serve/logs_schema.py`, one table, `logs.db` beside `traces.db`:

| Column | Why it exists |
|---|---|
| `seq` | `INTEGER PRIMARY KEY AUTOINCREMENT` — the forwarder's watermark. AUTOINCREMENT, not a plain rowid, so a delete can never hand the same number out twice; a duplicate watermark is silent data loss and the trace store had to be migrated to fix exactly that. |
| `ts_ms` / `observed_ms` | The producer's clock and ours. Both, always: a store with one timestamp cannot tell a slow carrier from a slow event, which is the question a stall investigation opens with. |
| `severity` / `sev_num` | OTel text and SeverityNumber. Text is what a human filters on; the number makes "at least WARN" a range query, and is what Instana falls back to. |
| `service` / `instance` | `kernel-hive-spa` \| `-serve` \| `-daemon`, and the station, tab or box within it. Together they are the OTLP resource identity. |
| `trace_id` / `span_id` | The join. Nullable, because some records genuinely have no span in scope (a boot line, a timer tick) and inventing an id that joins to nothing is worse than admitting there is none. |
| `body`, `attrs`, `session_id`, `build`, `day` | The message, structured attributes (a stack included), and the three facts every triage query groups by. |

The trace store's `BANNED_ATTRS` do **not** apply here. A stack is the most
useful thing a log record can carry, and refusing it is precisely what kept
`clientlog.jsonl` alive as a parallel store. Stacks land as
`exception.stacktrace`, which is the attribute name Instana documents support
for.

### What each producer emits

- **Serving plane** — `scripts/serve/logsink.py`. Every line goes to stderr
  (and therefore to the file) **always**; the store is additive, so a failure
  of the new path costs queryability and never the line. `tracing.current()` is
  read at write time, so a line emitted inside a request span carries that
  span's ids. `logsink.install_logging()` routes the stdlib root logger in as
  well. Two file traps are closed on the way past: every line now carries an
  ISO-8601 UTC timestamp, and `logsink.boot_banner()` writes one `=== BOOT`
  delimiter per process start — the append-mode log had neither, and output
  written before a fix read exactly like output written after it.
  **The per-request access line is deliberately NOT stored** (`LOG_ACCESS=1`
  folds it in at DEBUG): it is ~184 000 lines a day and every one is already a
  richer span next door.
- **Station daemon** — `streamhost/src/trace/logs.rs`, `sh_log!`. Same carrier
  as the span spool: a file per batch under
  `/data/vms/streamhost/stations/<station>/logs/`, tmp+rename, shipped by the
  same `trace-ship.py` timer. `eprintln!` still happens for every line, so
  journald keeps the firehose. The floor is **WARN** (`SH_LOG_LEVEL` raises it)
  — see the cost table below for why. `Span::error()` also emits a correlated
  ERROR record automatically, so every failed daemon span has a working pivot
  with no call site able to forget.
- **Browser** — `spa/src/analytics/logSink.ts`. The trace ids are stamped at
  QUEUE time, not at flush time: by the time a batch leaves, the span that
  caused the event has ended, and resolving it late would correlate every
  record to whatever happened to be open last — a wrong answer that looks like a
  right one. `reportError` feeds it too, so window errors, unhandled rejections
  and React boundary errors arrive with their stacks.

Ingest is `POST /logs`, open like `/traces`. Reads are admin-only under
`/auth/logs/{search,trace,facets,otlp}` (`scripts/serve/logs_read.py`), leaf for
leaf with the trace lane. `/auth/logs/trace` is the pivot.

### Retention, and what it costs on this box

Measured 2026-09-01 on the live box, over a two-minute window and a 24-hour
journal:

| Producer | Raw today | Into the store | Note |
|---|---|---|---|
| Serving plane | 12.1 MB/day (`https-server.log`) | **~0.5 MB/day** | The access line stays in the file; only real log lines are stored. |
| Browser | 13.9 MB/day (`clientlog.jsonl`), ~36k records/day | **~16 MB/day** | The bulk. Includes the `stats`/`ptr` firehose at DEBUG. |
| Station daemon | 62.5 MB/day, 747k lines across 71 units | **~3 MB/day** | WARN and above only; journald keeps the rest. |

**≈20 MB/day, ≈140 MB at 7 days, ≈210 MB with indexes.** That is the real
constraint here — one box, one disk — and it is what picks the number:

- **7 days**, half the trace store's 14. A log row costs roughly ten times a
  trace row at this traffic, and 7 days is also Instana's own default log
  retention, so both stores answer a question for the same window.
- A runaway backstop at 4M rows, ~5× the honest window, so a producer fault
  drops the oldest records instead of the disk.
- `LOG_RETENTION_DAYS` overrides it. Raising the daemon to `SH_LOG_LEVEL=info`
  on one station under investigation is the intended way to pay for detail, and
  it is per-station.

Setting the daemon's floor to INFO fleet-wide would be ~90 MB/day and ~630 MB
retained, to duplicate what journald already holds — which is why WARN is the
default rather than a preference.

### The gate on retiring `clientlog.jsonl`

`/clientlog` is being replaced, not kept alongside. It writes in parallel for
one deploy so that a defect in the new path cannot lose the only record of what
happened; removal is a separate, later change. **It may not be removed until all
three of these are true:**

1. `spa/index.html`'s inline bootstrap error reporter posts to `/logs`. It runs
   before any module evaluates, so it cannot import the sink or read a span —
   it needs its own inline record shape, and doing that in the same change as
   everything else is how one big change becomes two outages.
2. `spa/src/main.tsx`'s React-boundary fallback POST (the branch taken when
   `window.__kernelHiveReportError` is absent) posts to `/logs`. The primary
   path already does, through `reportError`.
3. The `correlated` facet on a normal traffic day is not near zero — i.e. the
   lane is actually joining, not just storing. `/auth/logs/facets` reports it,
   and it is on every forwarder run line.

`docs/lab/STREAM-DEBUGGING.md` §1.1 already points operators at the new surface
and names what is not covered yet; that list and this one are the same list.

### The Instana leg

`scripts/observability/instana_logs.py` posts OTLP/JSON to `/v1/logs` after the
traces leg (so the call a record correlates to has already landed), under its
own `lastLogSeq` watermark, through the same `instana_batch.drain()` loop and
the same measured 4 MiB budget. What Instana does with it — and the four things
its docs are silent about, two of which are exactly what a batcher would want —
is quoted in [`docs/lab/research/instana-logs.md`](lab/research/instana-logs.md).

**This tenant refuses log ingress and the forwarder cannot tell.** Measured on
the first batch this box ever sent: the local agent answered **200 OK**, and
250 ms later logged the backend's answer — `402 Payment Required`, "The current
TU doesn't allow this endpoint because it needs to be paid for". It is the only
402 in that agent log's history, and the Logging API reports `totalHits: 0` for
the tenant over 24 hours. On SaaS, OpenTelemetry logs need a logging add-on
(`0275-logging.md`); traces and metrics are entitled and unaffected. The
refusal is on the agent-to-backend hop, which an OTLP exporter never sees, so
**an OK from this leg means the agent took the batch, not that Instana kept
it** — do not read the run line as proof the pillar is populated. The code side
is done; buying the add-on is the only thing that changes the outcome, and the
pivot is answered by our own store meanwhile.

---

## 8.6 The VITALS plane — the fourth pillar, and the only continuous one

**Shipped 2026-09-01.** Traces answer "what happened in this call". Logs answer
"what did a producer say while it ran". Neither can answer *"was the picture 30
fps and 2 Mbit/s for the last ten minutes, and did the audio ever run dry"* —
because a stream is **continuous**. There is no call to time, and per-frame
spans would be thousands a second. That question needs a **time series**, and
this is it: `scripts/serve/vitals.py`, `vitals.db`, `POST /vitals` in,
`/auth/vitals/*` out.

### Why there are TWO metric lanes, and which question goes to which

This is the distinction most likely to be lost, so it is stated first.

| | `instana_metrics.py` → `analytics.db` | `instana_vitals.py` → `vitals.db` |
|---|---|---|
| shape | bucketed counters | timestamped samples |
| resolution | **one day** | **5 seconds** |
| forwarded | with the 5-minute trace timer | its own **10-second** timer |
| answers | "how many restores yesterday, and how slow" | "is win311 streaming cleanly *right now*" |

The day lane is not a coarse version of the vitals lane and must not be
"improved" into one: **its counters carry no per-sample timestamp at all**, only
a day bucket, and its own docstring says emitting them at any finer resolution
would be a lie. There is no finer data underneath it. The vitals lane is a
genuinely new shape beside it.

### The single biggest win, and it was already being computed

Every video and transport number below had been computed once every five
seconds since the ABR controller was written — and rendered into a
140-character string that went to `clientlog.jsonl`. `formatStatsLine()` is
prose: nothing could plot it, alert on it, or compare two stations on it.
`spa/src/three/streamClient/vitalsSample.ts` takes **the same tick** — on its
own faster clock, see below — and emits the numbers as numbers. It adds no
measurement to the hot path; it stops throwing away the ones already there.

### The inventory — what is measured, and what is not

Thirty-three vitals, catalogued once in `scripts/serve/vitals_schema.py`
(`CATALOGUE`), which is the single source for the store column, the OTLP metric
name, its unit and its instrument kind.

- **Video** — decode fps, **paint fps** (kept separately: frames can decode and
  never reach the screen), received kbps against the encoder's peak cap, decode
  latency, decode-queue depth, loss %, window loss %, tier/crf/w/h/fps-cap, and
  the cumulative counters: frames dropped, freezes, decode errors, session
  rebuilds, key AUs.
- **Transport** — RTT, its floor, its excess over that floor, its window peak,
  and the breach-tick count. All from the application-level ping already on
  `input.wire` and from frame_id gaps.
- **The daemon's own view, relayed free** — `send_kbps`, server-side QUIC path
  RTT, skipped frames and the ABR overall score. These ride KIND_PARAMS subtype
  2, which `transport/mod.rs` has sent at 1 Hz per session all along and which
  only the ABR skip-credit and the Ctrl+N overlay ever read. **This is why the
  first cut of this lane needed no daemon change and no fleet rollout.**
  Server-measured send rate beside client-measured receive rate is the pair
  that settles "is it the network or the box" without a repro.
- **Audio** — context running, **play-head lead**, underruns, packet-sequence
  gaps, frames scheduled. Before this, audio continuity was **unfalsifiable**:
  `audioPlayer.ts` reported the first sample heard and the first sample blocked
  and nothing ever again, so a session that fell silent thirty seconds in
  looked exactly like one that played for an hour. Each counter is read off a
  value the player already had — the underrun counter is one increment inside
  the existing anti-underrun clamp, which *is* the moment the visitor heard a
  gap.
- **A/V sync — measurable, and here is why.** The Opus packet header's `ts_us`
  is, in `audioPlayer.ts`'s own words, the "server µs epoch (shared with the
  video capture ts)", and the AU header's `ts` is the same stamp. Both media
  carry a capture time off **one clock**, so their skew through our pipeline is
  a subtraction — not a clock-sync problem. Two imprecisions are stated rather
  than buried: the video operand is the last *decoded* frame, not the last
  *composited* one (up to one frame interval, ~33 ms), and the audio operand is
  the last packet *scheduled*, so `audio_lead_ms` is subtracted to bring both
  to what the visitor is experiencing now. **±40 ms is inside that noise; 500 ms
  is real.** The u32 µs counter wraps every 71.6 minutes and the difference is
  read as signed 32-bit, which is right for any true skew under ±35.8 minutes.

  **What the first live run actually showed, and what it does not prove.** On
  win311 the skew read −309 ms early and drifted to −7,510 ms, while
  `audio_frames` stayed pinned at 26,880 and `audio_lead_ms` at 0 — i.e. the
  audio pipeline delivered one buffer and stopped, and the vital tracked video
  walking away from a frozen audio clock. That is the metric behaving exactly
  as designed on a **stalled** stream, and it is a useful confirmation that
  both operands are live and on one epoch. It is **not** a calibration: the
  sim runs muted, so the absolute zero of this vital has never been checked
  against a known-good synchronised stream. Until it has been, read `av_skew_ms`
  as a **trend** — a number that walks away from where it started means audio
  and video have decoupled — and not yet as an absolute millisecond offset.

**What is NOT observable, checked rather than assumed** — this is listed in
`vitals_schema.py` too, so nobody rediscovers an absence:

- WebTransport byte/packet counters, estimated send rate, smoothed/min RTT,
  datagram loss. **`WebTransport.prototype.getStats` is undefined** in the
  Chrome this gallery serves (measured, Chrome 150).
- QUIC congestion window and lost-packet count daemon-side: the wire field
  exists and is hardcoded 0 — wtransport 0.7 exposes only `rtt()`.
- x264 QP: the wire byte exists and is hardcoded `0xFF` "unknown".
- **Encode latency and capture rate — the one real gap.** Both *are* measured
  on the box (a 120-frame window in `encode/worker.rs` prints p50/p95/max and
  fps) and both go to **journald as text and nowhere else**. Closing it needs a
  daemon change plus a fleet rollout, so it is named as follow-up rather than
  half-built; the columns are deliberately absent, because an always-NULL
  column reads as "measured, and it was nothing".
- Audio packet *loss* as distinct from *gaps*: a client cannot tell a lost
  packet from server-side silence, and does not claim to.

### The store — wide, not tall, and what that costs

The obvious shape for a metric store is `(ts, name, value)`. It was rejected on
two grounds. **One sample is one observation** — every number is measured at
the same instant by the same tick, so "what was the fps when the RTT peaked" is
a column comparison on one row rather than a self-join. And **size**: measured,
a wide row is **511 bytes** with its indexes; the same sample tall is 33 rows
each repeating a timestamp, a station, a session and a metric name.

The cost of wide is that adding a vital is a **migration**, not an insert. That
is what `vitals_schema.migrate()` is for, and it inherits verbatim the rule that
crash-looped this plane on 2026-09-01: `CREATE TABLE IF NOT EXISTS` does not
reshape a live table, and SCHEMA may never carry an index over a migrated
column. `scripts/test_vitals_plane.py` pins it by building a store missing four
catalogue columns and requiring that today's code opens it.

### The sample interval — chosen from the signal, not from a budget

**One second.** The interval is set by what the series has to make *visible*,
and the events in question are short: a freeze latches after **250 ms** without
decoded output, an ABR downshift and the recovery from it both happen inside the
controller's own **3-second** rolling window, and an audio underrun is
instantaneous. At the 5 s cadence the existing log line uses, a downshift *and*
its recovery can both fall between two samples and the series draws a flat line
straight through a fault the visitor saw. At 1 s every ABR window contains three
samples and no freeze episode can hide entirely between two.

It is **not faster than 1 s**, and the reason is information rather than cost:
four of the vitals in every row are the daemon's own view, and
`transport/mod.rs` emits those at exactly **1 Hz**. Sampling faster would repeat
half of each row verbatim.

Vitals flow for **any station with a live session**. There is no sampling,
throttling or admission layer on top of that, deliberately — the sessions most
worth having are the bad ones, and every such layer drops them first.

### What it costs — recorded as a fact, not used as a constraint

**511 bytes/row**, measured, worst case with every one of the 33 columns
populated. This gallery has one visitor; none of the numbers below is a budget
anything is sized against, and they are written down for whoever needs them the
day that changes.

| load | rows/day | MB/day | at 30-day retention |
|---|---|---|---|
| realistic (one visitor, ~1 h/day) | 3,600 | **1.8 MB** | 0.06 GB |
| the measured peak (4 concurrent, 24 h) | 345,600 | 177 MB | 5.3 GB |
| hypothetical saturation (all 71, 24 h) | 6,134,400 | 3.1 GB | 94 GB |

`/data` has ~166 GB free. The realistic row is the one that describes this box:
the measured busiest day in `clientlog.jsonl` was 2,262 five-second samples,
which at 1 Hz is a couple of megabytes.

**Cardinality** is the one limit that is *not* ours to waive, because it is the
vendor's. A series is (metric × station × session), and `session` is the only
unbounded term — which is exactly why it rides as a **data-point attribute** and
never in the resource. In the resource each session id would mint a new
OpenTelemetry *entity*, and entities are what an infrastructure backend keeps
forever. One live stream is 33 series; all 71 at once would be 2,343.

**Retention is 30 days — the longest window in the plane, not the shortest.**
The instinct with dense data is to keep a tight window, but density is a reason
to size the disk, not to throw the data away. A month makes *"has this station
always been like this, or did it change?"* answerable, which is the question
this gallery actually asks; three days would have answered only *"is it bad
now"*, which the `live` read already answers for free. The runaway backstop
(`MAX_ROWS`) is what handles the case a tight retention used to: a producer
stuck in a flush loop is a **fault**, and a fault gets a ceiling — set well
above any plausible real load so that hitting it is diagnostic rather than
routine.

**There is no downsampling.** A rollup is a second schema, a second prune and a
second thing to be wrong. If the gallery ever gets real traffic the honest first
move is a bigger disk and the second is a rollup, in that order.

### The read surface

Admin-only, mirroring the log lane's four leaves so one surface teaches the
other: `series` (the chart read — **oldest first**, because a time series is
read as a line and every other store here answers newest-first), `live` (one
row per stream reporting in the last two minutes — the triage read), `facets`
(what is in the window, the catalogue, and **coverage**: a store holding a
thousand rows from one 40-second session is a souvenir, not monitoring), and
`otlp` (the same page as OTLP/JSON, so "are the numbers Instana shows the
numbers we sent" is answerable without reading a forwarder log).

Ingest is **open**, like `/traces` and `/analytics`, and walk-ins are allowed:
the visitor whose picture is breaking up is the one whose numbers matter, and
they hold no admin session.

### The Instana leg, and the cadence constraint that shaped everything

    "The metric timestamp that is recorded for OpenTelemetry metrics is the
     timestamp of ingestion into Instana."  — 0307-opentelemetry-signals.md:98

Instana stamps a metric point when it **arrives**, not when we measured it.
Everything below follows from that one sentence.

**The five-minute forwarder could not carry this.** It would hand Instana 60
consecutive 5-second samples per stream, all stamped with one ingest moment:
sixty distinct measurements of a changing stream collapsed onto one instant.
Not a degraded chart — a wrong one, and one that would look perfect in
`--dry-run`. So the vitals leg has **its own timer at 10 seconds**
(`kh-instana-vitals.timer`), running `instana-forward.py --scheduled
--no-traces --no-logs --no-metrics`.

**Ten**, because that is Instana's own floor: infrastructure metrics on a
custom dashboard have "10 second resolution" (`0261`), and the Saturation SLO
blueprint samples at 10 s (`0262`). Faster buys resolution the backend will not
display; slower throws away resolution already collected.

Note the **asymmetry, and that it is deliberate**: our store samples at 1 Hz,
Instana gets one point per 10 s tick. That is not a resolution we traded away to
save anything — it is the finest thing an ingest-stamped backend can represent,
and it is Instana's own documented floor. The good signal lives in our store;
Instana gets what Instana can display.

A run ships **one point per (station, session, metric)** — the newest sample —
because "this is the value now" is the most a run can truthfully say when the
timestamp will be replaced on arrival. The intermediate samples are not lost:
they are in **our** store at full resolution with the producer's own clock,
which is the whole point of having one. `INSTANA_VITALS_ALL=1` ships every
unsent sample instead, for a payload proof or a backfill, with its cost stated —
backfilled points arrive stamped *now*, so they land as a spike at the current
instant, not as history.

The watermark is therefore called `lastVitalsSeenSeq`, **not** `lastVitalsSeq`:
in the default mode it records how far the leg has *looked*, not what it has
delivered. Naming it after a guarantee this lane does not make is exactly the
mistake that cost the trace lane half of every trace until 2026-09-01.

**Cost per tick, measured:** one point per metric per live stream. At the
measured peak of four streams that is 132 data points, ~40 KiB — three orders
of magnitude under the measured 5 MiB agent wall, which is why this leg reuses
`instana_batch`'s planner unchanged. With nothing streaming — the museum's
normal state — a tick runs one indexed query, sends nothing and exits.

### One station, one entity — the reason the export looks like this

> "Instana creates an OpenTelemetry entity from the metrics data. OpenTelemetry
> spans automatically link to this entity by using the `service.name` and
> `service.instance.id` resource attributes… Correlation chain: OpenTelemetry
> span > OpenTelemetry entity > Host entity"
> — `0311-…-infrastructure-correlation.md`:236-248

**OTLP metrics alone create a first-class monitored entity; no spans are
needed.** So `vitals_otlp.py` puts the **station id** in `service.instance.id`,
and that one choice turns 71 exhibits into 71 entities rather than one blurred
service with a label. They are reachable at *Infrastructure → Analyze
infrastructure → OpenTelemetry*, or by Dynamic Focus `entity.type:opentelemetry`.

The **session** id is a data-point attribute and never part of the resource:
session ids are unbounded over time, and in the resource each one would mint a
new *entity* — the thing an infrastructure backend keeps forever.

Instrument kinds are the catalogue's: Gauge and Sum are what Instana's acceptor
takes (exponential histograms are unmentioned in the corpus and treated as
unsupported). Cumulative counters export as **monotonic cumulative Sums** —
exported as a gauge, "4 frames dropped so far" renders as a level and means
nothing, and only the axis lies, which is why the test pins it.

### Out of scope, deliberately, and not foreclosed

Discrete degradations — a stall, a decode error, an ABR downshift, blocked
audio — are **events**, and they already have a lane
(`analytics/streamEvents.ts`); the planned Instana **Event SDK** integration is
a follow-up, not part of this. What this lane carries is the **continuous level
such an event would be a threshold on**, which is exactly the number that
follow-up will fire against. The same is true of SLOs: infrastructure metrics
support the Saturation blueprint at 10 s sampling, and nothing here forecloses
one.

---

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

## 12. What these numbers are, and what they are not

- **The counter plane holds no identity, because its rows are COUNTS.** Every
  row is keyed by (day, thing, class) and holds an `n`; there is no column a
  person could occupy without changing what the number means, and *"which
  feature is dead"* never needed to know who. This is a table shape, not a
  privacy policy — §0. Identity lives in the trace plane, deliberately, and the
  Instana forwarder ships it onward.
- **These are the tab's own account of what it did.** Same caveat as `usage.py`,
  same reason: the counters come from the client. Right for deciding what to
  build; not an audit trail. The per-batch caps bound how far one forged report
  can move a total; nothing bounds a patient liar, and nothing needs to.
- **`never reached` is not `unreachable`.** It means no tab reported it in the
  window. Read the window before the verdict.
- **Trace numbers do not cross 2026-09-01.** On that date a trace stopped
  meaning "a visit" and started meaning "one action" (§8.1), and an `input.edge`
  root stopped measuring ~1 ms of local enqueue and started measuring the
  edge -> painted-pixel round trip. A latency percentile, an endpoint chart or a
  traces-per-day trend drawn across that boundary is comparing two different
  measurements — the p95 will appear to explode and the trace count to multiply,
  and neither is a regression. Cut the window at the date, or read the halves
  separately.

## 12a. Is the trace plane telling the truth? The orphaned-parent rate

A trace can be broken in a way that no other number shows. Every span is well
formed, every request it describes succeeded, the latency is right — and the
`parent_id` names a span that is not in the store, so the trace has no root.
Instana renders that as *"The root call of the trace is missing or has not yet
arrived in the processing pipeline"*, and there is nothing to see in the access
log, the span list, or any latency chart.

It went unmeasured until an operator wrote the query by hand on 2026-09-01 and
found **42.9%** of a six-hour window in that state. The causes and the fix are
[`docs/lab/TRACE-CONTEXT.md`](lab/TRACE-CONTEXT.md) §4c; this is how the next
regression gets noticed instead of discovered.

**The largest single cause was a browser budget, not a tracing bug.** Six senders
posted every batch with `keepalive: true`. A document's keepalive allowance is
64 KiB spent ONCE for its whole life, not per request: measured on the live
gallery in Chrome 150 with 4 KiB bodies, ~15 posts succeed and every keepalive
fetch after that rejects `TypeError: Failed to fetch` permanently, while a plain
fetch to the same URL still succeeds. So `/traces`, `/analytics`, `/clientlog`
and `/logs` all died mid-visit — in the same second — while `/clientcmd` polling
and the vendor's `/eum` beacons kept flowing, which is why the access log showed
a healthy tab. Each caller swallowed the rejection in a bare `.catch(() => {})`,
and `/traces` had already DRAINED its buffer before posting, so the browser's
half of every affected trace — the ROOT — was destroyed while the daemon's half
kept arriving by an independent path: **175 of 459 `input.dispatch` spans over
24 h (38%) named a parent the store never had.** The fix is
`spa/src/analytics/beacon.ts`: `keepalive` only on the final pagehide/hidden
flush, the response body always drained (an unread body holds the allocation
open), and an undelivered batch requeued (`spanBuffer.ts`) rather than thrown
away — a refusal is settled and dropped, a no-answer is kept.

```sh
scripts/observability/trace-orphans.py                  # last 6 h, live store
scripts/observability/trace-orphans.py --hours 24 --json
scripts/observability/trace-orphans.py --max-rate 0.02  # exit 1 above 2%
```

```
window    last 6 h, ignoring the last 1 h
spans     5492 declaring a parent
ORPHANED  0  (0.0%)
```

It opens the store **read-only** (`TraceStore(path, read_only=True)`): a report
must never run a migration against the file the serving plane is writing.

**Read the settle gap before the number.** Spans newer than `--settle-hours`
(default 1) are excluded, because a parent that is merely still OPEN — a flow
the visitor has not finished — is a transient orphan that resolves the moment
its root span ends. Counting those would make the figure a measure of how busy
the box is rather than of whether the contract holds.

**A non-zero rate is a SENDER bug, always.** The serving plane honours whatever
context it is handed and cannot know whether a parent will be recorded; the
rule "never name a span you will not record" belongs to whoever emitted the
header. `scripts/visitor-sim/beacon-probe.mjs` checks the same invariant on the
real wire from one credentialed page load, which is where to look next.

## 13. Files

| Path | What |
|---|---|
| `spa/src/analytics/catalogue/` | the declaration — the report's denominator, one file per area so parallel instrumentation streams share no editing surface |
| `spa/src/analytics/intent.ts` | the grade ladder, the human-edge witness, client class |
| `spa/src/analytics/flows.ts` | flow spans and the funnel rules |
| `spa/src/analytics/trace.ts` | the span/id model, `traceparentOf()` (the ONLY producer of an outbound `traceparent` — TRACE-CONTEXT.md §4c) and the trace-entry flush — see [`docs/lab/TRACE-CONTEXT.md`](lab/TRACE-CONTEXT.md) §4/§7 |
| `spa/src/analytics/pageLoadLink.ts` | the `<meta name="traceparent">` seed every trace entry LINKS back to (`kh.link.kind=page.load`) beside the `kh.page.loadId` attribute — was `pageLoadJoin.ts`, which made early traces children of `serve.page` until a trace came to mean one action (§8.1) |
| `spa/src/analytics/spanBuffer.ts` | spans between `end()` and the wire: the bounded buffer, the entry-flush debounce, and the requeue that stops a failed upload deleting a trace's root |
| `spa/src/analytics/beacon.ts` | the ONE telemetry upload path, and the 64 KiB per-document keepalive budget every other path was spending (§12a) |
| `scripts/observability/tail_sampler.py` | the keep/drop for the VENDOR export only — every error, every slow action, 1 in 10 of the rest — and the derived 279 ms floor (§8.1) |
| `scripts/observability/trace-orphans.py` | the orphaned-parent rate — the one number that shows a broken trace JOIN, since every individual span still looks perfect (§12a) |
| `spa/src/analytics/khFetch.ts` | the automatic same-origin `traceparent` propagation + client-span-per-request patch, and the Instana ordering finding |
| `spa/src/analytics/metrics.ts` | the metrics lane — bucketing, the visible-time clock, effort accumulators |
| `spa/src/three/connectTelemetry.ts` | the reference call site: one flow + one timing |
| `spa/src/analytics/streamEvents.ts` | the stream event vocabulary (§5.5): the taxonomy table and the one emitter that fans it to all four lanes |
| `spa/src/analytics/catalogue/stream.ts` | the probes and metrics those events feed |
| `spa/src/analytics/pageBinding.ts` | the explicit page/page-load binding on every stream event — the capability Instana's browser agent lacks |
| `spa/src/analytics/instanaStreamEvents.ts` | the Instana mirror: thin, isolated, deletable, and the three vendor rules that fail silently |
| `spa/src/three/streamClient/analyticsEvents.ts` | the stream client's call sites, kept out of the load-bearing decode/transport modules |
| `scripts/test_stream_event_intake.py` | proves every event name and attribute survives the REAL `/traces` and `/analytics` validators |
| `scripts/serve/vitals_schema.py` | the vitals CATALOGUE — column, OTLP metric name, unit and instrument kind, in one place — plus the SCHEMA built from it and the generic add-a-column migration (§8.6) |
| `scripts/serve/vitals.py` | the time-series store: open ingest, admin reads, 3-day prune, the runaway backstop |
| `scripts/serve/vitals_read.py` | the four admin leaves — `series`, `live`, `facets`, `otlp` — and the filter whitelist beside the store it filters |
| `scripts/serve/vitals_otlp.py` | stored rows → OTLP `resourceMetrics`; the file where `service.instance.id = station` turns each exhibit into its own OpenTelemetry entity |
| `spa/src/three/streamClient/vitals.ts` | the browser sink: queue, 20 s flush, pagehide keepalive, fold-back on network failure, and the u32 capture-clock wrap |
| `spa/src/three/streamClient/vitalsSample.ts` | one ABR tick → one vitals row; the file that changes when a vital is added, with no I/O in it |
| `scripts/observability/instana_vitals.py` | the fourth OTLP leg, and the cadence argument — why 10 s, why latest-only, and why the watermark is called `Seen` |
| `scripts/observability/kh-instana-vitals.{service,timer}` | the 10-second carrier, separate from the 5-minute one because Instana ingest-stamps metrics |
| `scripts/test_vitals_plane.py` | the migration crash-loop test, the intake rules, and the OTLP entity/instrument-kind pins |
| `spa/src/ui/fleetFindEpisode.ts` | the `fleet.find` episode |
| `spa/src/scene/hallEngagement.ts` | the `hall.navigate` episode, and what "approached" means |
| `spa/src/ui/posterReadEpisode.ts` | the `poster.read` episode and the reversal counter |
| `spa/src/analytics/errors.ts` | fingerprinting and grouping |
| `spa/src/analytics/sink.ts` | batching transport (counts, not events) |
| `spa/src/analytics/coverage.ts` | production LINE coverage collector; in the instrumented bundle only |
| `spa/vite-plugins/coverage.ts` | the arming flag, the istanbul transform, the collector injection |
| `spa/src/analytics/index.ts` | `reach` / `beginFlow` / `reportError` / `initAnalytics` |
| `spa/src/analytics/build.ts` | the ONE build-id constant every lane names a bundle from (§8.3) |
| `spa/public/sw.js`, `spa/src/pwa/serviceWorker.test.ts` | the PWA worker whose shell cache is named after the build, so a deploy cannot strand a client on old HTML (§8.3) |
| `spa/src/analytics/buildIdentity.test.ts`, `scripts/test_traces.py` | the build id from the `/traces` envelope through intake to the OTLP `service.version` |
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
| `scripts/observability/instana-forward.py`, `instana_destination.py`, `instana_backlog.py`, `instana_batch.py`, `instana_metrics.py` | forwards traces + metric histograms to Instana; agent-vs-SaaS destination choice and the narrow loopback-http exception; the ingest-sequence watermark and quiet window that decide WHICH traces are still owed; how much goes in one request and how many requests one run may make; the histogram projection |
| `scripts/observability/kh-instana-forward.{service,timer}`, `kh-trace-ship.{service,timer}` | the schedules for the two carriers. Installed by `box-deploy.sh --apply`, enabled by the operator |
| `spa/src/analytics/instana.ts` | Instana EUM configuration — the pseudonymous-then-real identity upgrade, `ignoreUrls`, the fetch/XHR collision writeup (§8.2) |
| `spa/index.html` (inline bootstrap) | the earliest-possible `ineum` config; the unconfigured-checkout guard that is the browser-side off switch (§8.2); `reportingUrl` now names our own `/eum` (§8.4) |
| `spa/src/analytics/navigation.ts` | the canonical `ROUTES` table, `STATION_ID` and `pageName()` — what a page is CALLED, on both planes (§8.2a) |
| `scripts/test_page_naming_in_sync.py` | pins App.tsx's routes and both hand-duplicated copies of the naming tables equal, with a vacuous-pass guard (§8.2a) |
| `scripts/serve/eum_proxy.py`, `scripts/test_eum_proxy.py` | the beacon proxy (§8.3): one fixed destination, POST-only, gated like `/traces`, never traced, forwarded off the request thread — and the tests that pin every one of those refusals |
| `scripts/visitor-sim/beacon-probe.mjs` | the acceptance probe: where beacons went, whether we accepted them, and (`--instana-check`) whether the tenant actually received them |
| `scripts/serve/linecov.py` | `POST /coverage`, `GET /coverage/report.json`, the line-set merge |
| `spa/vite-plugins/coverage.ts`, `spa/src/analytics/coverage.ts` | the armed-only instrumentation plugin and its collector |
| `spa/src/analytics/*.test.ts`, `spa/src/walkin/telemetry.test.ts`, `spa/src/ui/keyboard/composeTelemetry.test.ts` | the client side; one test per rule that could otherwise silently invert |
| `spa/src/analytics/catalogue/walkin.ts` | the declarations, with the privacy line and the proxy caveat at the top |
| `spa/src/walkin/registerTelemetry.ts` | the door: funnel, four stage clocks, the retry count, the refusal probe |
| `spa/src/walkin/playTelemetry.ts` | the claim: funnel, the queue/instant split, `toPlayableMs`, retries |
| `spa/src/ui/keyboard/composeTelemetry.ts` | the keyboard: funnel, first-key clock, the correction rate, layer switches |
| `spa/src/walkin/telemetry.test.ts`, `spa/src/ui/keyboard/composeTelemetry.test.ts` | 38 tests, one per rule above that could otherwise silently invert |

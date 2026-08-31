# Trace context across the four layers

**The contract every layer implements to make one journey one trace.**

Browser, Python serving plane, Rust daemon and the emulated guest are four
processes on two machines. Instrumented independently they produce four
disconnected traces of the same visit, which is worse than it sounds: the whole
value of a trace is that the slow part and the failing part are visible in the
same picture, and four pictures means going back to correlating by timestamp —
which is what tracing exists to replace.

So there is one rule, and it is W3C, not ours.

## 1. The wire format is `traceparent`

```
traceparent: 00-<32 hex trace-id>-<16 hex parent-span-id>-<2 hex flags>
             ^^ version                                    ^^ 01 = sampled
```

Nothing custom. `spa/src/analytics/trace.ts` already mints ids in exactly this
shape, `scripts/serve/traces.py` already validates them with the same regexes,
and every OTel SDK and collector on earth reads this header. A private header
would have cost the same effort and closed the door on `traces_otlp.py` meaning
anything to an external system.

**Parse defensively and never fail a request over it.** A malformed
`traceparent` means *start a new trace*, never *refuse the work*. Telemetry that
can break the thing it measures is not telemetry, it is a fault injector.

## 2. Who sends it where

| Hop | Carrier | Notes |
|---|---|---|
| serving plane → browser (page load) | `<meta name="traceparent">` in `index.html` | the FIRST hop of a visit, before any JS has run — see §4 |
| browser → serving plane | `traceparent` request header | **automatic, on every same-origin request** — `spa/src/analytics/khFetch.ts` patches `window.fetch` once at boot, so this is no longer a per-call-site opt-in. See §4a |
| serving plane → its own spans | in-process | child of the inbound span |
| browser → daemon (input plane, session join) | the session ticket | the input plane is WebTransport straight to the daemon's QUIC listener and carries no headers, so the id rides the thing that is already exchanged |
| browser → daemon (input plane, per-edge) | inside the input RECORD itself, on a SAMPLED edge only | no headers here either, and no per-request exchange to piggyback on the way the ticket does — see §3.2 |
| daemon → its own spans | in-process | child of the session's root |
| daemon → emulator | **not propagated** | see §6 |

## 3. The daemon hop is the awkward one, and why

The serving plane never sees a click: input goes from the tab to the station's
own QUIC listener, and the ticket that gates it carries a station and an expiry
and no identity (this is the same fact that made `usage.py` a client-reported
counter rather than a server observation). There is no header to put a
`traceparent` in.

So the trace id travels in the **signalling document exchange** — the tab asks
the serving plane for `/signal/<station>.json`, and that request already carries
`traceparent` under §2. The serving plane mints the session's root span there
and hands the id to the daemon alongside the ticket. The daemon's spans are
children of that root.

### 3.1 The spelling, so the two ends cannot disagree

The signalling document's `path` field already carries the daemon's session
ticket (`/wt/<exp>.<nonce>.<sig>`), and `session_ticket.rs` has always split
that path on `?` before verifying — a query string is explicitly not part of
the ticket. So the id rides there, spelled exactly like the header:

```
path = /wt/<exp>.<nonce>.<sig>?traceparent=00-<32 hex>-<16 hex>-01
```

The HMAC covers `v1|<tile>|<exp>|<nonce>` and not the query, so appending this
neither invalidates a ticket nor lets a tampered query forge one — the worst a
tamperer achieves is attaching their own session to a trace id they picked,
which is a telemetry lie and not an authorisation one. The reverse is the rule
that matters and it holds: **the ticket carries the trace id, the trace never
carries the ticket** (§8).

**Status: both ends are deployed; no visit has yet exercised the hop.**
`streamhost/streamhost/src/trace/context.rs` parses this on every incoming
WebTransport session and joins the browser's trace when it is present, and
`signal_route.py` now appends it — both live as of 2026-08-31, the daemon by
the fleet rollout that put the new binary on every station. The join is
therefore untested by traffic rather than unbuilt: `kh.trace.joined` rides
`streamhost.session`, which is only emitted when a visitor actually connects,
so every daemon span recorded so far is a boot-time ROOT with no such attribute
at all. Watch the first real visit to a rolled station for the answer.

One trap this cost a session already: the query parameter must be spelled
`?traceparent=00-<traceid>-…`, with the KEY. An earlier version appended the
value alone (`?00-<traceid>-…`), which parses as a nameless pair and is skipped
by the scan in `context.rs`, so the hop silently never joined while both halves
looked correct in review.

The consequence worth stating: a station opened WITHOUT a fresh signalling fetch
— a reconnect that reuses a cached document — continues the previous trace or
starts a fresh one, and does not silently attach to an unrelated visit. When in
doubt, start a new trace. A wrong parent is worse than no parent, because it
draws a causal claim that is false.

### 3.2 The per-edge hop: SAMPLED input records carry their own context

§3.1 gets a browser's TRACE joined to a session once, at connect. It does not
get any single click or keystroke onto that trace, because the daemon
deliberately emits no span per input edge (§5's "no span per frame" sibling
rule) — a per-edge trace would either need one more span the daemon cannot
afford at 60 fps of input, or it would need to invent one, which §8 forbids.

Added 2026-08-31: for an end-to-end input→pixel flame graph (the shape the
open keyboard-lag investigation — a suspected pacing-queue floor in the
emulator ctl module — actually needs), the browser SAMPLES roughly 1 key or
click edge in `SAMPLE_N` (default 10; `three/streamClient/inputTrace.ts` is
the knob) and mints that edge its OWN trace, root span `input.edge`. Its
context — a 1-byte marker, a 128-bit trace id, a 64-bit span id, 25 bytes,
**no flags byte**: presence on the wire already means sampled — is appended
after the record's normal fixed fields, on that ONE record only:

```
[ ...the record, exactly as always... ][ 0xC5 | trace-id (16 BE) | span-id (8 BE) ]
```

**Compatibility is by construction, not by version negotiation.** Every match
arm in `streamhost/streamhost/src/input.rs` already reads a record's fixed
fields off the FRONT and tolerates trailing bytes it does not recognise (it
guards on `rec.len() >= N`, never `== N`) — this predates the sampling feature
and was not added for it. `streamhost/streamhost/src/input_trace.rs` exploits
exactly that:

- **old browser → new daemon.** A pre-sampling browser sends a record at its
  historic exact length. `input_trace::strip` finds no length that matches
  `base + 25` for that record type, returns the bytes untouched and reports no
  context. Byte-for-byte today's behaviour.
- **new browser → old daemon.** A sampled record is 25 bytes longer. The old
  daemon never heard of this module; `input::handle`'s match arms read their
  fixed fields off the front exactly as always and ignore the tail. The click
  or keystroke still lands — untraced, not dropped.

Both directions are asserted in `input_trace_tests.rs`, not merely argued for.

**What travels, and what does not.** The qemu keycode a key record carries was
ALWAYS on the wire — the guest cannot be typed at otherwise — and this feature
adds nothing to it. What the daemon and the browser each independently compute
from that keycode, LOCALLY, for their own span attributes, is a coarse bucket —
`kh.key.class` ∈ {printable, modifier, navigation, enter, function} — never
transmitted as such and never invertible back to which key it was;
`kh.input.class` ∈ {key, click} names the wire record type. Neither process
ever puts the character or the keycode itself in a span attribute. This is the
same content rule §8 has always stated, applied to a new pair of processes.

**The daemon's half of the chain**, parented on the browser's `input.edge`
context via `Ctx::child`, exactly like every other hop in this document:

```
input.edge                    (browser, root — the sampled decision)
└─ input.dispatch             (daemon: record accepted → guest write returned)
   ├─ guest.frame.next        (daemon: the EFFECT — next frame produced)
   └─ transport.frame.next    (daemon: that frame reaching the wire)
```

`input.dispatch` is one span covering both "the sink accepted it" and "the
guest write completed" rather than two, because `input.rs` sits AT its
800-line Rust file-size hard cap (`docs/lab/AGENT-CI-EXIT-RULE.md`) and cannot
grow a second boundary inside it without a split this change did not need to
force.
`guest.frame.next` / `transport.frame.next` fire only when a sampled edge is
actually pending — one relaxed atomic load costs the 60 fps encoder relay
nothing on every other frame, the same `AtomicBool` discipline §5's sibling
rule already uses for `mark_first_au` / `mark_first_input`.

**`input.dispatch` is `Kind::Server`, not `Internal`** — this is the daemon's
receiving side of the browser's `input.edge` **`Kind::Client`** span, the same
RPC pairing this codebase already uses for `http.client.request` /
`serve.signal`. Verified live 2026-08-31 against Instana's own `analyze/traces` API
(`scripts/observability/instana-forward.py`): every `serve.*` trace, which has a
`Server`-kind entry span, arrived with a real `service.name`; every
`input.edge` trace — Client root, Internal children throughout, no `Server`
span anywhere — arrived labelled service `"Unspecified"`. Instana derives a
trace's owning service from its entry span, and a trace with no `Server` span
has none. Marking `input.dispatch` Internal understated what it already is:
not merely something that happens during the session, but the request/response
boundary itself, so `Server` is a correction of an existing span, not a
vendor-pleasing relabel — the same "never call a UI span a server span" rule
this file states elsewhere cuts the other way here, because this span already
was the server side of a real client/server exchange.

## 4. The page-load hop: an HTML `<meta>` tag, read by a vendor agent

Everything in §2 assumes the browser already HAS a trace id to send. Something
has to mint the first one, for the very first request of a visit — the
document GET itself, before a byte of JavaScript has run and before there is
any tab to send a header from. That request is answered by `serve_static()` in
`scripts/serve/static_files.py`, and it is where the trace begins.

Serving `index.html`, the server mints (or joins, per §1) a real span the same
way every other traced route does, and splices

```html
<meta name="traceparent" content="00-<32 hex trace-id>-<16 hex span-id>-01">
```

into `<head>` — into the **bytes on the wire only**. `spa/index.html` on disk
is never touched, so a build or a deploy can never bake a stale id into the
artifact: the tag does not exist until a request asks for the page, and a new
one is minted on every such request. Staging (`/staging/<session>/`) is served
by the same function and gets its own tag from its own request, the same way.

**Who reads it, and why.** Two readers now, independently, off the SAME tag.
It was built for **Instana's website-monitoring agent**, embedded separately
in the SPA, whose whole job is to correlate a RUM page load with the backend
trace that served the page — via `document.querySelector('meta[name=
"traceparent"]')` and the exact `00-<32 hex>-<16 hex>-<2 hex>` shape, asserted
nowhere IBM or Instana publishes, established 2026-08-31 by reading the
vendor's own minified agent bundle (it silently ignores anything that is not
exactly that shape — never an error). That provenance still matters: a future
reader "fixing" this tag's shape to match Instana's docs will get it wrong,
because the docs never state it — this file, and the agent's own source, are
the only record.

As of the same day, `spa/src/analytics/trace.ts` reads it too —
`joinPageLoadTraceFromMeta()`, called once at boot from `main.tsx` — and uses
it to seed the FIRST trace this tab opens (§4a). This closes the gap §7 used
to describe: a visit no longer produces two disconnected trees, one rooted at
`serve.page` and one at the browser's own first flow.

**The id is real, not a prop.** The span behind the tag is opened and ended in
`static_files.py` and flows through the same buffered flush (`tracing.py`)
into the **same store** as every other span in this document — so a page load
an operator finds in Instana by this id is the identical span they can also
find in `/admin/observability`, not a parallel identity invented only to look
plausible in a tag.

**Deliberately narrow.** This is a targeted, named exception to "static asset
serving is not traced" (`tracing_http.py`'s allowlist — left unchanged by
this): only the ONE response that is the start of a visit,
`index.html` itself, gets a span and a rewritten body. Every other static
file, and every SPA client-side route change that never re-fetches the
document, stays untouched and unspanned.

**Fail safe, same rule as §1.** If tracing is unbound, an inbound header is
malformed, or anything at all raises, `index.html` is served byte-for-byte
unchanged and no tag appears. A telemetry feature must never be able to break
the gallery's front door — see §8.

## 4a. The browser hop is automatic, not opt-in — and the page-load join

Until 2026-08-31, `traceHeaders()` in `trace.ts` existed but almost nothing
called it: of 24 `fetch()` call sites in `spa/src`, only two did — both our own
telemetry posts (`analytics/index.ts`, `analytics/sink.ts`). Every user-facing
API call — the manifest, signalling, restore, walk-in auth, the fleet table —
carried no trace context. That was not 22 bugs, it was one: propagation was
opt-in per call site, which is exactly the shape that rots the moment nobody
is watching it.

**The fix is `spa/src/analytics/khFetch.ts`: a single, global `window.fetch`
patch, installed once**, at the very top of `main.tsx`, before any other
import in that module runs. It is a monkey-patch and not a `khFetch()` helper
call sites must remember to use — that alternative was rejected on the
evidence above, since a wrapper only helps the call sites that adopt it, which
is the same failure mode restated. For every same-origin request the app
makes (checked by `URL.origin`, never leaked to a third-party host) it:

- adds `traceparent`, from the current active span if one is open, a fresh
  trace otherwise — unless the caller already set one, which is respected,
  not overwritten;
- opens a **client span** — name, method, `url.pathname` (never the query
  string — the same rule `errors.ts`'s fingerprint and this file's own §8
  state), status code and duration — UNLESS the path is one of this repo's own
  telemetry endpoints (`/traces`, `/analytics`, `/coverage`, `/clientlog`,
  `/usage`, `/clientcmd`), reusing `instana.ts`'s `IGNORE_URL_PATTERNS`
  rather than a second list that could drift from it. A span about sending a
  span is the feedback loop the per-tab beacon budget exists to prevent — the
  header still goes out to those endpoints (it always did, by hand), only the
  client-side span is skipped;
- respects the same `enabled`/`allowed` gates as everything else in this
  plane (`configureTracer`, the `allowed` answer `main.tsx` computes) — spans
  fall out for free, since `makeSpan()` already no-ops when the tracer is
  off;
- never breaks the request. Every enhancement is wrapped in its own
  `try`/`catch` and falls back to the unmodified original `fetch` — this
  patch sits in front of every network call the app makes, so a bug in it is
  not a missing metric, it is a broken gallery.

**The page-load join.** `trace.ts` also exposes `joinPageLoadTraceFromMeta()`,
called once from `main.tsx` alongside the fetch patch, before the first flow
opens. It reads the §4 `<meta name="traceparent">` tag and seeds the id so
that the FIRST trace this tab opens (`startTrace()`, typically the
`station.connect` flow) **continues** `serve.page`'s trace instead of minting
an unrelated one — consumed exactly once, so a second, later flow in the same
tab (a retry, a second station) still gets its own fresh trace rather than a
stale parent from page load. Missing or malformed content on the tag (no
server injection, a stale cached document, tracing unbound) leaves the seed
unset and the first trace mints its own id exactly as it always did — the
same "malformed → new trace, never refuse the work" rule as §1.

**The Instana collision, measured rather than assumed.** Both this patch and
Instana's own agent (`enableW3CHeaders: true`) want to own the outbound
`traceparent` header. Reasoning from Instana's minified source alone is
exactly the trap §4 already avoided once by testing instead of reading docs —
so this was run, not read: the real agent
(`registry/local.env`'s pinned `INSTANA_EUM_SCRIPT_URL`) loaded into a
scripted harness with a capturing `fetch` underneath it, in both install
orders. Findings, in full in `khFetch.ts`'s own header:

- Instana's fetch patch uses `Headers.append` for every header it adds,
  `traceparent` included — written to coexist with an existing value, not to
  overwrite it.
- A monkey-patch chain is **last-installed-outermost**: whichever patch is
  installed more recently wraps the other and runs first, calling inward to
  whichever installed earlier — which sits closer to the real network call
  and therefore gets the last word.
- **When this patch installs before Instana's agent has loaded** (the common
  case — this module is the first import `main.tsx` evaluates; Instana's
  agent is a separately fetched, non-parser-inserted `<script>` and is
  therefore genuinely async regardless of its own `defer` attribute, per
  `index.html`'s comment on that tag), this patch ends up INNER. Instana's
  outer wrapper appends its headers first; this patch's `Headers.set(...)`
  then runs and OVERWRITES whatever Instana put there. Verified: the wire
  header is our clean single value, Instana's `X-INSTANA-*`/`tracestate`
  headers sit untouched beside it.
- **When the order is reversed** — Instana's agent finishes loading and
  patches first — this patch becomes OUTER, sets the header first, and
  Instana's inner `.append` turns it into `"<ours>, 00-...-03"`: two
  comma-joined values in one header, which is not a valid single
  `traceparent`. Both `tracecontext.py` and Instana's own backend then treat
  it as malformed and start a fresh trace for that one call — the request
  itself is never broken either way, only that one call's join is lost.
- No hard guarantee against the reversed order is attempted (an inline
  `<script>` ahead of Instana's own bootstrap in `index.html` would win
  unconditionally, at the cost of re-implementing trace-id minting outside
  this module in raw inline JS — a second implementation of exactly the kind
  this section exists to stop having). A best-effort win that degrades to "no
  join, never a broken request" was judged the better trade.

## 5. Sampling is all-or-nothing PER TRACE, and the browser decides

The `01` flag is set by the tab and every layer honours it. A layer that
sampled independently would produce traces with holes in them, and a hole in a
flame graph is indistinguishable from a gap in the work.

At this scale everything is sampled. The flag exists so that turning sampling
down later is a one-line change in one place rather than four.

**§3.2's per-input tracing samples WHICH TRACES EXIST, not spans within one.**
Every trace this document otherwise describes — a station connect, a daemon
boot — is minted whole and every layer honours its `01` flag exactly as this
section says. §3.2 sits one level up: the browser decides, once per input
edge and before any trace exists for it, whether THIS edge gets a trace at
all (`SAMPLE_N`, default 10). The edges that lose that coin flip are not
partially-traced — nothing is minted, nothing is sent, nothing downstream
ever hears about them. The rule that "sampling is the browser's decision" is
identical in both places; only the unit being sampled — a whole visit's trace
vs. one input edge's trace — differs.

## 6. The emulator is deliberately NOT traced from inside

No span is emitted from inside a guest. Three reasons, in order:

1. **The guests are the exhibit.** A 1993 machine running an agent that reports
   to a 2026 observability backend is no longer the artefact the museum is for.
2. **Most of them cannot.** Nothing that runs on BeOS R5, TempleOS or a
   Sinclair QL is going to speak OTLP, and the ones that could would need a
   network stack this lab deliberately keeps off most stations.
3. **The interesting boundary is outside anyway.** What anybody wants to know
   is when the guest was resumed, when it first painted, and when it reacted —
   all of which are observable from the daemon that drives it, and all of which
   are already the framebuffer-is-the-only-proof rule (AGENTS.md rule 9) in
   span form.

So "emulator spans" means **spans the daemon emits about the guest**: process
start, `loadvm` restore, first painted frame, first input reaching the guest.
That is the emulator layer as a visitor experiences it, and it is measured from
the only place that can honestly measure it.

## 7. What a complete trace looks like

```
serve.page                                       (python, root — §4/§4a: named
│                                                  in the <meta> tag the page
│                                                  was served with)
└─ station.connect                                (browser — §4a's join)
   ├─ HTTP GET /signal/<station>.json    client   (browser — khFetch.ts, automatic)
   │  └─ serve.signal                    server   (python: mints the id below)
   │     └─ serve.ticket.mint            internal
   ├─ streamhost.session                 server   (rust: joined by ticket id)
   │  ├─ guest.resume                    internal (emulator: cont / SIGCONT)
   │  ├─ capture.first_frame             internal
   │  ├─ encode.first_key                internal
   │  ├─ transport.first_frame           internal
   │  └─ input.first_edge                internal
   └─ station.open.toFirstFrameMs        internal (browser, the metric's twin)
```

The daemon emits one more trace that has no browser in it at all, because a
station boots with nobody watching — a root `streamhost.start` with
`guest.launch`, `guest.attach` and `guest.first_frame` under it (§6, and
`streamhost/streamhost/src/trace_guest.rs`). It is deliberately NOT attached to
a visitor's trace: inventing that parent would be the false causal claim §8
forbids.

Four processes, one trace id, one flame graph. The browser's own
`station.open.toFirstFrameMs` span sits beside the daemon's `guest.resume`, and
the question "was it slow because the guest was asleep" stops being a
correlation exercise.

**A sampled input edge (§3.2) is its OWN small trace, not more branches under
`station.connect`.** Roughly 1 key or click edge in `SAMPLE_N` produces:

```
input.edge                    (browser, root)
└─ input.dispatch             (daemon)
   ├─ guest.frame.next        (daemon)
   └─ transport.frame.next    (daemon)
```

This is deliberately a second family of traces alongside the one above, the
same way a page load answers a different question from a keystroke
— a session's connect trace and its visitor's individual keystrokes answer
different questions on different timescales, and folding thousands of input
edges under one connect span would make that trace impossible to read rather
than more complete.

**The §4 page-load span IS a root above this one, now.** `serve.page` is
minted when `index.html` is served, before any of the above exists;
`station.connect` used to be minted independently and unrelated the moment the
app booted, producing two disconnected trees for one visit — this trace, and a
one-span Instana trace rooted at `serve.page`. §4a's page-load join closes
that: `joinPageLoadTraceFromMeta()` seeds `station.connect` (or whichever flow
opens first) to continue `serve.page`'s trace id, with `serve.page`'s span as
its parent, so the tree above is now genuinely rooted at the page load, not
merely drawn that way.

## 8. Rules that are not negotiable

- **Never fail a request because of a header.** §1.
- **Never invent a parent.** An unknown or malformed context starts a new trace.
- **Never let the meta-tag injection break the page.** §4: any failure serves
  `index.html` unchanged, byte-for-byte.
- **Never propagate into a guest.** §6.
- **Never put a secret in a span.** The ticket carries the trace id; the trace
  never carries the ticket. Same rule as `traces.py`: no stacktraces, no typed
  text, no credential handles.
- **Never put a key's identity or any typed text in a span.** §3.2's addition:
  a key class is a coarse bucket, never the key. Absolute, with no exception
  for a "safe-looking" key.
- **A layer that cannot trace still works.** Every hop degrades to "no parent",
  never to "no service".
- **An old browser and an old daemon must both keep working against a new
  counterpart.** §3.2: the fleet rolls in canaried waves and the SPA deploys
  independently of it, so a version skew between browser and daemon is the
  NORMAL state, not an edge case — never the exception.

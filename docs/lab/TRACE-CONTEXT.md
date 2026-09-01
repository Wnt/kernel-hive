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
| serving plane → browser (every traced response) | `traceresponse` response header, plus `Server-Timing: intid;desc=` | the return leg: the reply names the span that answered it — see §4b |
| serving plane → its own spans | in-process | child of the inbound span |
| browser → daemon (input plane, session join) | the session ticket | the input plane is WebTransport straight to the daemon's QUIC listener and carries no headers, so the id rides the thing that is already exchanged |
| browser → daemon (input plane, per-edge) | inside the input RECORD itself, on a SAMPLED edge only | no headers here either, and no per-request exchange to piggyback on the way the ticket does — see §3.2 |
| daemon → its own spans | in-process | child of the session's root |
| daemon → emulator | **not propagated** | see §6 |

## 3. The daemon hop is the awkward one, and why

The serving plane never sees a click: input goes from the tab to the station's
own QUIC listener, and the ticket that gates it carries a station and an expiry
and no identity (this is the same fact that made `usage.py` a client-reported
counter rather than a server observation — a ticket shape, not a policy: the
span store carries `enduser.id` since 2026-09-01, `docs/ANALYTICS.md` §0). There is no header to put a
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

Added 2026-08-31, and made complete on 2026-09-01: for an end-to-end
input→pixel flame graph (the shape the open keyboard-lag investigation — a
suspected pacing-queue floor in the emulator ctl module — actually needs),
**every key and click edge** mints its OWN trace, root span `input.edge`
(`three/streamClient/inputTrace.ts`). Its context — a 1-byte marker, a 128-bit
trace id, a 64-bit span id, 25 bytes, **no flags byte**: presence on the wire
already means traced — is appended after the record's normal fixed fields, on
that record only:

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
ever puts the character or the keycode itself in a span attribute. That is the
typed-CONTENT question in §8, which is open pending an operator decision —
everything else about the edge (timing, class, record type) is ordinary
telemetry.

**The daemon's half of the chain**, parented on the browser's `input.edge`
context via `Ctx::child`, exactly like every other hop in this document:

```
input.edge                    (browser, root — DURATION = edge → painted pixel)
├─ input.wire                 (browser: the handoff to the QUIC stream, and
│                              the connection's own properties — §3.4)
└─ input.dispatch.<class>     (daemon: record accepted → guest write returned)
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

**The daemon's entry span is named per input CLASS** — `input.dispatch.key`,
`input.dispatch.click`, with the bare `input.dispatch` as the fallback for a
class neither end recognises (`trace_session.rs::dispatch_span_name`). Instana
derives an OTLP trace's ENDPOINT from its entry span's name, the
`{otel.operation}` rule in its predefined endpoint mapping
(`instana-docs/0251-monitoring-applications.md`, "Endpoints → Predefined
rules"), so one name meant one endpoint row for every input a visitor ever
made. A keyboard round trip and a mouse round trip have different guest work,
different damage and different latency distributions; folding them into one row
hid both. `kh.input.class` stays on the span as well, because a name cannot be
grouped away when somebody does want the whole input plane at once.

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

### 3.3 The return leg: closing the trace at the pixel

§3.2 gets the trace as far as the daemon's own transport send. Until
2026-08-31 that was the whole picture, and it made "input->pixel" a
misnomer — the number it produced was really input->frame-SENT, never the
bytes arriving in the tab, decoding, or reaching glass.

**The problem the browser cannot solve alone.** `guest.frame.next` /
`transport.frame.next` exist because the DAEMON knows which `frame_id`
answered a given sampled edge (`trace_session.rs`'s `PendingEffect`). The
browser has no such knowledge of its own: WebCodecs hands the decode output
callback the frame's own capture timestamp, never "this was caused by the
input you sent 40 ms ago". So the daemon has to say so, explicitly — the same
principle §3.2 already applies to the request/dispatch boundary, extended one
hop further downstream.

**The mechanism: a wire mark, not stream ordering.** Three options were on the
table: extend the video AU header itself, carry the association on an
existing channel, or infer it from frame arrival order. The AU header was
rejected first — it is followed immediately by an arbitrary-length Annex-B
payload with no length prefix (the uni-stream's own close IS the
end-of-payload marker), so a variable-length insertion between header and
payload is not additive: an OLD client reading the old fixed offsets would
decode the marker bytes as bitstream, corrupting or crashing that one frame's
decode. Ordering was rejected on the brief this work started from and for the
reason stated there: "the next frame painted" is an approximation that fails
precisely under load, drops and reordering — exactly when this measurement is
worth taking. That leaves the existing SERVER->CLIENT `KIND_PARAMS` channel
(`transport/egress.rs`), already used for encoder-params (subtype 1) and HUD
stats (subtype 2) and already proven additive: an old client's
`handleParamsStream` drains an unrecognised subtype
(`else { await br.readToEnd(); }`, `videoDecode.ts`) rather than
misinterpreting it. Subtype 3 carries `frame_id` (u32 LE) + trace-id (16 BE) +
span-id (8 BE) — 28 bytes, sent on its OWN uni-stream, spawned rather than
awaited so a slow or lost mark can never hold up the video AU it names. It is
minted once per sampled edge that actually produced and sent a frame — the
exact gate `effect_sent` already applies, not a new one.

**Matched by id, not by which arrived first.** The mark and the AU it names
travel on two independent uni-streams the network is free to reorder against
each other. `three/streamClient/frameTrace.ts` keeps two small bounded FIFOs
(capacity 64 — headroom for reordering and jitter, not a working set: a mark
normally names a `frame_id` within a handful of the ones already tracked) —
recent per-frame receive/decode/paint timestamps, and marks that arrived
before their frame — and matches strictly on `frame_id`, whichever side
completes second. A mark or a frame that never finds its match simply ages
out of its FIFO: the daemon's half of the trace still stands on its own, and
nothing downstream ever treats "no client spans" as an error.

**The resulting chain**, `client.frame.*` siblings of the daemon's own effect
spans under the same `input.dispatch`:

```
input.edge                    (browser, root — DURATION = edge → painted pixel)
├─ input.wire                 (browser: handoff to QUIC + transport facts)
└─ input.dispatch.<class>     (daemon: record accepted → guest write returned)
   ├─ guest.frame.next        (daemon: the EFFECT — next frame produced;
   │                            kh.encode.latency_us, promoted from a
   │                            journal-only `worker.rs` line)
   ├─ transport.frame.next    (daemon: that frame reaching the wire)
   ├─ client.frame.receive    (browser: AU bytes -> handed to the decoder)
   ├─ client.frame.decode     (browser: the WebCodecs decode itself)
   └─ client.frame.paint      (browser: the paint sink's own synchronous cost)
```

**THE ROOT'S DURATION IS THE ROUND TRIP, and that is the point of the return
leg.** `input.edge` is left OPEN when the edge is sampled and closed by
`frameTrace.ts` at the moment the answering frame finishes painting
(`inputTrace.ts::settleEdge`, which ends it AT that reading rather than at
"now", so the frame mark's own travel time is not charged to the visitor).
Until 2026-09-01 the figure lived in a SIBLING span, `client.input.roundtrip`,
beside a root whose own duration was the 0–1 ms it took to hand a record to a
stream writer — so every consumer that reads a root's duration (a trace list, a
latency percentile, Instana's endpoint view) read 1 ms for something a visitor
waited a quarter of a second for. One measurement, one span.

**An edge no frame ever answers still lands.** An idle or damage-gated guest
may legitimately never produce a frame; that edge is settled after 3 s with
`kh.input.answered=false`. It is not an error — nothing failed — and it must
not simply be absent, because an open span is never buffered and a leaked one
would delete the ROOT of its own trace.

A real one, captured on win95 2026-09-01 and reproduced here verbatim from our
own store (`+n ms` is from the edge; the trailing number is the span's own
duration):

```
input.edge                 client   +   0ms  242ms   kh.input.class=key kh.key.class=modifier
│                                                    kh.input.answered=true
│                                                    LINK -> serve.page (kh.link.kind=page.load)
├─ input.wire              client   +   0ms    0ms   quic/h3, server.port=<station UDP>,
│                                                    kh.transport.rtt_ms=6.3 (source: ping)
└─ input.dispatch.key      server   +  15ms    0ms   svc=kernel-hive-daemon
   ├─ guest.frame.next     internal +  16ms  213ms   frame 34, encode 17.7 ms
   ├─ transport.frame.next internal +  16ms  218ms   68 779 bytes
   ├─ client.frame.receive internal + 232ms    1ms
   ├─ client.frame.decode  internal + 233ms    7ms
   └─ client.frame.paint   internal + 240ms    2ms
```

**Compatibility, both directions, is the same additive-channel argument §3.2
already made for the input suffix, applied to a channel that already proves
it:**

- **old client, new daemon.** The daemon sends the subtype-3 mark; the old
  client's `handleParamsStream` does not recognise subtype 3 and drains it
  (`else { readToEnd() }`). No decode is touched, no error, no visible effect
  — the session behaves exactly as it did before this change existed.
- **new client, old daemon.** The old daemon never calls `spawn_frame_mark` —
  it does not exist in that binary — so no subtype-3 stream ever opens. The
  new client's `frameTrace.ts` FIFOs simply never receive a mark and age out
  every entry; `client.frame.*` spans are never emitted, and nothing else
  about playback changes.

Neither direction needs a version check: it is the same "additive tail /
additive subtype, unconditionally ignorable" shape every other KIND_PARAMS
extension in this file already relies on, not a new compatibility mechanism.

### 3.4 Which layers in an input trace are REAL, and which do not exist

Read a flame graph expecting the wrong four boxes and every one of them looks
broken. This is what each box in §3.3's tree actually measures, in the order
the tree draws them, and — just as important — what a reader should stop
waiting for.

| layer | span | what it really is |
|---|---|---|
| the envelope | `input.edge` (Client, ROOT) | the whole edge → painted pixel round trip, both ends read from the same tab's `performance.now()`. THE number a visitor waited. |
| transport | `input.wire` (Client) | REAL, but its DURATION is only the local handoff to the QUIC stream writer. See below. |
| daemon | `input.dispatch.<class>` (**Server**) | the record's whole journey through `input::handle` — sink accepted → guest write returned. Real, and it is the trace's ENTRY span. |
| guest | `guest.frame.next` (Internal) | the next frame the guest PRODUCED after injection. Not the same claim as "the guest reacted" — see below. |
| return | `transport.frame.next`, `client.frame.receive/decode/paint` | real, one hop each, split across the two processes. |

**There is no browser→server HTTP hop, and none is faked.** A keystroke is a
length-prefixed record on a client-opened QUIC unidirectional stream inside one
WebTransport session; pointer motion is a QUIC datagram. Both live inside an
HTTP/3 CONNECT session, which is the only sense in which HTTP is involved: no
request, no method, no status code, nothing for an `http.client.request` span
to describe. Emitting one anyway to make the tree look familiar would be
exactly the false claim §8 forbids about a span's causal shape. `input.wire` is
what exists instead.

**So `input.wire`'s duration is NOT the network hop.** It cannot be: the
daemon's clock is a different clock, and subtracting two wall clocks across two
machines yields skew, not latency. What it measures is real and worth having —
how long this tab spent getting the record into the writer, which is where
backpressure appears — and the hop's actual cost rides beside it as an
attribute:

- `server.address` / `server.port`, and the same pair as `net.peer.name` /
  `net.peer.port` — the current OTel spelling and the older one Instana's
  documented consumed-attribute list reads, emitted together, the shape the
  OTel SDKs spell `http/dup`. Our own plane's naming is the product; the vendor
  is the temporary consumer. When the HTTP side of this repo settles one
  bridging rule, `transportFacts.ts` follows it — it never invents a third.
- `network.transport=quic`, `network.protocol.name=http`,
  `network.protocol.version=3`, `network.protocol.alpn` when the UA exposes it,
  `peer.service=kernel-hive-daemon`.
- `kh.wire.reliability` ∈ {stream, datagram} — key and button records ride a
  reliable per-class stream; pointer motion rides a datagram. They have
  genuinely different loss and latency behaviour and must not read the same.
- `kh.transport.conn`, a per-connection id minted in the tab, so several
  sampled edges over one session group without any of them carrying a ticket.
- `kh.transport.rtt_ms` with `kh.transport.rtt_source` naming which kind.

**`WebTransport.getStats()` does not exist in the browser this gallery serves.**
Measured, not assumed: Chrome 150 on CT950, 2026-09-01 —
`typeof WebTransport.prototype.getStats === 'undefined'`, and the whole
prototype is `ready`/`closed`/`close`/`datagrams`/`protocol` plus the two
stream factories. So the spec'd connection stats — smoothed RTT, estimated
send rate, datagram loss counters — are simply not obtainable from a browser
here. An attribute that is always absent is worse than none, because it reads
as "the poll has not run yet" forever.

What stands in is not a consolation prize: the stream client already runs a
liveness PING over this same connection (`streamClient.ts::pingRtt`, a type-9
datagram the daemon echoes, re-taken by the ABR loop), and both ends of that
measurement are `performance.now()` readings in the same tab. It is an
APPLICATION-level round trip rather than a transport estimate — which is the
number a visitor's finger actually waits on — and `kh.transport.rtt_source`
says `ping` so nobody mistakes it for `smoothedRtt`. The day a UA ships
`getStats()`, the transport's own figure wins and the source attribute says
`getstats`, with no other change. To get the transport-level number sooner
would take either a browser that implements the API or a QUIC-level reader on
the daemon side reporting its own view of the connection back to the tab; both
are real options and neither is done.

**`guest.frame.next` is not proof the guest reacted.** Rule 9 (`AGENTS.md`) is
that the framebuffer is the only proof, and this span IS drawn from the
framebuffer — it fires on a real captured, encoded access unit, never on a
queue write. But it is the NEXT frame after injection, which on a damage-gated
station may be a frame the input had nothing to do with, and on an idle guest
may not arrive at all. The name says exactly that much and no more; it is
deliberately not called `guest.ack`. Read it as an upper bound on "how long
until something changed", and go to `labctl`/a screendump when the question is
whether the guest did the right thing.

**`input.edge`'s own duration is the one measurement that needs no clock
agreement.** Everything else in the tree is a browser reading beside a daemon
reading, so the tree's overall SHAPE depends on two machines' wall clocks
lining up. The root does not: both ends are `performance.now()` readings from
the same tab, taken when the edge was sampled and when the answering frame
finished painting. It is the envelope the daemon's spans decompose, and it is
the root, so a trace list and a latency percentile read the right number
without knowing any of this. When the daemon never names an answering frame the
root still lands, after 3 s, with `kh.input.answered=false` — a value in the
store, never a missing row.

**Two layers that do not exist at all, so nobody goes looking:**

- `net.peer.ip` and any LOCAL port. The browser cannot see the peer's resolved
  address or its own QUIC source port, and the daemon is forbidden from putting
  a peer address in a span (§8: never a secret, and the peer address is on that
  list). This is not "not yet"; it is not going to exist.
- A second input transport. `webRtcFallbackClient.ts` carries VIDEO and has no
  send path at all — every input record goes through
  `StreamClient.writeReliableClass`/`writeDatagram`, which are WebTransport
  only. `kh.transport` is recorded explicitly anyway, so the day that stops
  being true the trace says so instead of silently reading the same.

### 3.5 A missing daemon entry span is usually a DEPLOYMENT fact, not a bug

Over six hours on 2026-09-01 only 37% of sampled `input.edge` traces carried
the daemon's `input.dispatch`, and the vendor label on the rest was "To
input.edge of **Unspecified**". Both readings are correct and neither is an
instrumentation fault.

Broken down per station, every station whose daemon could emit the span joined
**100%** of its edges. The entire 63% was ONE station, win95, running a binary
from before this feature existed and doing exactly what §3.2's "new browser →
old daemon" paragraph promises: read the fixed fields off the front, ignore the
25-byte tail, land the click, emit nothing. `Unspecified` followed from the
same fact — with no daemon span there is no `Server`-kind entry span, and
Instana derives a trace's owning service from its entry. Once the two stale
stations were promoted, the same query returned `input.dispatch` /
`kernel-hive-daemon` for every new trace.

This will recur, on purpose: §8's last rule says version skew between browser
and daemon is the NORMAL state, because the fleet rolls in canaried waves and
the SPA deploys independently of it. What was missing was a way to SEE it — a
station that CANNOT trace looked identical to one that simply had no traffic.

```sh
ssh lab 'scripts/dev/labrun scripts/observability/trace-capable.py'
```

resolves every live daemon through `/proc/<pid>/exe` and reports which builds
can emit `input.dispatch` at all, exiting 1 when any cannot. **Read a low join
rate against that report before reading it as a propagation bug.**

**One related trap, and it was a real bug.** `/traces` requires an INTEGER span
start and drops anything else without a word (`traces.py`: `if not
isinstance(started, int) ... continue`). `analytics/trace.ts`'s `emitSpan`
derives its start by subtracting `performance.now()` — a fractional clock — from
`Date.now()`, so nearly every span it produced was refused at intake: 10 stored
`client.frame.paint` spans against 407 daemon `transport.frame.next` spans over
24 hours. The tab believed it had emitted; the store had nothing; the missing
return leg read as "the frame mark never arrived". Fixed by rounding at the
source. The general rule this is an instance of: **anything a new span emits
must be run through the real `traces.py` validators in a test**, which is what
`scripts/test_input_trace_intake.py` now does for this whole family.

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

**The document response carries the headers too.** The same span is handed
back in `traceresponse` and `Server-Timing` (§4b), so a page load correlates
for any reader that never touches the DOM — the tag is the vendor's channel,
the headers are everyone's. Two channels, one span: they are emitted together
or not at all, so they can never disagree about whether a span exists.

**ONE REQUEST, ONE SPAN — the tag names the request's span when there is one.**
`_traceparent_meta` calls `tracing.current()` first and mints a `serve.page`
root only when the request has none. That is not a refinement; it is the fix
for a real fault, live 2026-09-01. An allowlisted route can reach this code:
`auth_routes.dispatch` in `osgallery-https-server.py` runs only when
`self.public`, so on the **ungated LAN listener** `/auth/state`, `/auth/me`,
`/auth/walkin/status`, `/walkin/state` and `/kh/deploy-hint` are answered by
the SPA fallback — index.html. Minting a second root there gave one HTTP
request two server spans in two unrelated traces, two `traceresponse` headers
on the wire, and (when the browser had sent a `traceparent`) one client span
parenting both a `serve.page` and a `serve.auth.state` — a document navigation
and an in-page fetch that never happened. The public listener was never
affected: it answers those paths from the auth plane and never reaches
index.html. `scripts/test_serve_return_leg.py` pins all of it.

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

## 4a. The browser hop is automatic, not opt-in — and the page-load LINK

Until 2026-08-31, `traceHeaders()` in `trace.ts` (since removed — §4c) existed
but almost nothing called it: of 24 `fetch()` call sites in `spa/src`, only two
did — both our own
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

- opens a **client span** FIRST, and adds `traceparent` naming **that
  span** — so the serving plane's entry span is the client span's CHILD and
  the RPC edge exists. Unless the caller already set the header, which is
  respected, not overwritten. **On a path with no span of its own, or when
  the span comes back NOOP, NO HEADER GOES OUT AT ALL** — see §4c, which is
  the whole of the no-orphan invariant;
- names that client span `http.client.request` and records method,
  `url.pathname` (never the query string — the same rule `errors.ts`'s fingerprint and this file's own §8
  state), status code and duration — UNLESS the path is one of this repo's own
  telemetry endpoints (`/traces`, `/analytics`, `/coverage`, `/clientlog`,
  `/usage`, `/clientcmd`), reusing `instana.ts`'s `IGNORE_URL_PATTERNS`
  rather than a second list that could drift from it. A span about sending a
  span is the feedback loop the per-tab beacon budget exists to prevent. **No
  span means no header either** (§4c): those requests go out bare and the
  serving plane roots its own trace;
- reads the response's return leg (§4b) back onto the client span as
  `kh.backend.trace_id`;
- respects the same `enabled`/`allowed` gates as everything else in this
  plane (`configureTracer`, the `allowed` answer `main.tsx` computes) — spans
  fall out for free, since `makeSpan()` already no-ops when the tracer is
  off;
- never breaks the request. Every enhancement is wrapped in its own
  `try`/`catch` and falls back to the unmodified original `fetch` — this
  patch sits in front of every network call the app makes, so a bug in it is
  not a missing metric, it is a broken gallery.

**The page-load LINK.** `pageLoadLink.ts` exposes
`readPageLoadTraceFromMeta()`, called once from `main.tsx` alongside the fetch
patch, before the first flow opens. It reads the §4
`<meta name="traceparent">` tag and remembers `serve.page`'s span for the life
of the JS realm, so every trace this tab opens carries a span LINK to it and
the `kh.page.loadId` attribute beside it — **never a parent**. §7.1 has the
reasoning, and §7 has the trace-is-one-action rule it follows from.

Until 2026-09-01 this JOINED instead: for 15 seconds and 32 traces, a new
trace continued `serve.page`'s id with `serve.page`'s span as its parent. It
was built to stop a visit producing two disconnected trees, and it did — at
the price of a trace that meant "a visit", ran to 43 spans over 15.7 s, and
took its last write 74 s in. Worse, the window made the SHAPE depend on a
stopwatch: reproduced live, eight key edges inside the window came out nested
and eight click edges 15 s later came out as roots. Missing or malformed
content on the tag (no server injection, a stale cached document, tracing
unbound) leaves it unset and a trace is simply unlinked — the same "malformed
→ new trace, never refuse the work" rule as §1.

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

**The header must name the span, so the span is created first.** Until
2026-09-01 `khFetch.ts` built the header *before* opening its client span, from
`traceHeaders()` — which reads `currentSpan()`, and the client span is never
that: `childOfActive()` deliberately does not `pushActive()`. The result was two
distinct wrong parents, neither visible from the browser side:

- **inside an open flow**, the header named the FLOW ROOT, so the server's
  entry span came back a *sibling* of `http.client.request` instead of its
  child — the RPC edge simply absent from every flame graph;
- **with no active span**, `traceHeaders()` minted a fresh trace id and a span
  id belonging to no span at all, while the client span minted a *different*
  trace — one call, two unrelated traces.

The fix is in `khFetch.ts` (span first, then `traceparentOf(span)`), **not** in
the active-span model, and that is deliberate: a client span lives across an
`await`, `activeSpans` is a synchronous LIFO with no async context to hang
scope on, and pushing the client span would silently re-parent every span
opened by unrelated code while the request is in flight. `trace.ts` exports
`traceparentOf(span)` for exactly this — naming a specific span rather than
guessing at the current one — and carries the same note.

That fix left the ambient lookup in place as a FALLBACK, which kept half the
bug alive for another day: `traceHeaders()` still existed and was still what a
call with no span of its own used. §4c is what removed it, and both functions
with it. **`traceparentOf(span)` is now the only producer in the tab.**

## 4b. The return leg: `traceresponse` is ours, `Server-Timing` is the bridge

§4 gets a trace id into the page. Everything after it was, until 2026-09-01,
one-directional: the browser SENT a `traceparent` and never learned what the
server did with it. That is not a cosmetic gap. The server does not always
honour the id it was sent — a malformed or unsampled header starts a fresh
trace (§1), and the document request mints its own — so a client span's own
trace id is a *guess* about which server trace answered it, and the guess is
wrong exactly when something interesting happened.

So every **traced** response (`tracing_http.py`'s allowlist, unchanged, plus
the `index.html` document response of §4) carries two headers:

```
traceresponse: 00-<32 hex trace-id>-<16 hex span-id>-01
Server-Timing: intid;desc=<32 hex trace-id>
```

**`traceresponse` is ours, and it is a standard.** W3C Trace Context Level 2
defines it as the mirror of `traceparent`: same four fields, same spelling,
opposite direction, naming the span the server actually recorded for THIS
response. `spa/src/analytics/khFetch.ts` reads it, prefers it, and records the
trace id on its client span as `kh.backend.trace_id` — which is what lets
`/admin/observability` jump from a click to the server trace **with no vendor
in the loop**. That attribute is chosen to survive `traces.py` intake unaltered
(key ≤ 64 chars, not refused by `traces.refused()`, value ≤ `ATTR_STR_MAX`,
which is 2048 since 2026-09-01); a truncated or dropped id would look right in
the tab and join nothing in the store.

**`Server-Timing: intid;desc=` is the vendor bridge, and nothing else.**
Instana's EUM agent parses exactly that token off a response and sets the value
as the beacon's `backendTraceId`. Emitting it costs one header and buys vendor
correlation for free; nothing in this repo reads it except as a *fallback* in
`khFetch.ts`, and deleting it would cost only the Instana join. Where khFetch
has a backend trace id it also mirrors it to Instana explicitly
(`analytics/instana.ts`'s `reportBackendTrace`), under the vendor's silent
16-or-32-lowercase-hex rule — a value of any other length is dropped with no
error, which is indistinguishable from never having tried.

**Written at one choke point, so no reply shape can miss it or be broken by
it — and there is exactly one writer.** `tracing_http.set_response_trace()` is
the only way to name a response's span, and the `end_headers` wrapper is the
only thing that puts these two headers on a response; no route may add them to
its own reply. It was two writers for one day: `static_files.py` also merged
its own copy into the index.html reply's `extra` dict, which is how a single
LAN response came to carry two pairs (§4). `tracing_http.py` wraps
`end_headers`, which every reply the stdlib can produce passes through: 200, 304, 206, 416, HEAD (headers only, by definition),
an error page, and the long-lived streaming replies whose headers are written
once at the top. The values are stashed when the request span is opened and
cleared when they are written, so a keep-alive connection cannot leak one
response's ids onto the next. `tracecontext.response_headers()` returns `{}`
for a NOOP span, which is what an untraced route, an unsampled parent and an
unbound tracer all are — so **an untraced route emits neither header, by
construction** rather than by a second copy of the allowlist. The whole write
sits in a `try`: a telemetry header may never be the reason a response fails to
close its header block.

**Same-origin only.** The browser reads these headers because the request was
same-origin (`khFetch.ts` refuses anything else before it does anything at
all). No `Access-Control-Expose-Headers` is configured and none is wanted:
cross-origin correlation is out of scope, and a trace id is a correlation
handle for this box's own store.

## 4c. THE NO-ORPHAN INVARIANT: never name a span you will not record

> **A `traceparent` this tab emits names a span this tab has created and will
> record. Otherwise there is no `traceparent`.**

This is §8's "never invent a parent" seen from the SENDER's side, and it was
broken for as long as browser propagation has existed. Measured on the live
store on 2026-09-01, over six hours: **2,839 of 6,620 spans that declared a
parent — 42.9% — named a parent that was not anywhere in the store.** In
Instana every one of those renders as *"The root call of the trace is missing
or has not yet arrived in the processing pipeline"*, and nothing else shows
it: each span is well formed, each request succeeded, only the join is gone.

Three producers, all in the browser, all now removed:

1. **A minted id, on a path we had already decided not to trace.** `trace.ts`
   had a private `traceparent()` that, with no active span, returned
   `00-<new trace id>-<new span id>-01`. Nothing ever created that span.
   `traceHeaders()` handed it to every telemetry POST, and four of those six
   endpoints (`/analytics`, `/clientcmd`, `/clientlog`, `/usage`) ARE in the
   serving plane's route allowlist, so each one recorded an entry span under a
   parent that would never exist. 565 distinct such ids in the window.
2. **The ambient fallback.** `khFetch.ts` fell back to `currentSpan()`
   whenever its own client span was absent — an excluded telemetry path (by
   design) or a NOOP span (`MAX_OPEN` exhausted, tracer off). That named a
   flow ROOT, which is only written when the flow ENDS. One tab held
   `station.connect` open for seven hours and pointed 6,678 polls at an id
   the store never saw. Twelve such ids accounted for 2,274 of the 2,839.
3. **A span that never left the tab.** A span is buffered at `end()` and
   uploaded on the next flush. A visit shorter than the sink's 20 s interval,
   or a tab closed in a way `pagehide`/`visibilitychange` did not catch, lost
   the client span while the server span it had already parented survived.
   This has two halves and only the first was obvious: **(3a)** a long-lived
   flow root, which is not buffered at all until the flow ends; and **(3b)**
   the BOOT BURST, whose spans end in milliseconds and are buffered
   immediately, but which — because the page-load join gives them a parent —
   were not covered by a flush keyed on parentlessness. 3b survived the first
   fix and was caught by this document's own acceptance probe.

The fixes, in the order the data implicates them:

- **`traceparentOf(span)` is the only producer of an outbound `traceparent`.**
  `traceparent()` and `traceHeaders()` are gone. A request with no span of its
  own goes out bare and the serving plane roots its own trace.
- **The excluded telemetry paths send no header.** The alternative considered
  was sending the sampled flag OFF, which `tracing_http.begin()` turns into a
  NOOP span — that suppresses the SERVER span too, and its latency and status
  are the only record those routes have. Keeping a clean one-span
  `serve.clientcmd` root beats deleting the evidence to tidy a parent id.
- **A TRACE ENTRY flushes as soon as it ends**, debounced 250 ms so a burst
  leaves as one batch. Deliberately NOT a shorter interval: the sink's tick is
  a poll and costs a request whether or not anything happened, so a 1 s
  interval would be 60 requests a minute from every open tab across the whole
  wall. Entry-end flushing is demand-driven — an idle tab costs nothing, a
  finished journey costs exactly one request.

  **A trace entry, not a parentless span** — and the difference is the whole
  of cause 3b. The first fix keyed the flush on `parentId === null`, which
  missed the one burst that always needs it: while the page-load JOIN was live
  (§4a) `startTrace()` hung this tab's entry off `serve.page`'s span id, so a
  boot fetch's client span **had a parent** and never looked like a root.
  Measured on the deployed build with `beacon-probe.mjs`: the client spans for
  `/gallery-manifest.json` and `/boot/index.json` were absent from the store
  12 s after the load and present at 30 s — waiting for the 20 s tick, which
  is exactly the window a short visit does not survive, while the
  `traceparent` naming them had already gone out. The join is gone (§7.1), so
  an entry is a root again and the two predicates agree today; the flag is
  kept because it says what is MEANT, and the day something is parented again
  is the day `parentId === null` silently stops working. The three boot
  entries end within 18 ms of each other, so the 250 ms debounce still carries
  them in one POST.
- **`pagehide` abandons every open flow**, ending its root (`unset`, with
  `kh.abandoned`) so the root is recorded before the tab goes. Deliberately
  NOT on `visibilitychange`: hidden is not over, and ending a live flow when a
  visitor switches tab would swallow the `ok()` that follows and depress the
  connect success rate for every tab-switcher.

**The server side is unchanged, and that is deliberate.** It cannot know
whether a parent will ever be recorded, and §8's other rule — honour the
caller's context, never second-guess it — still holds. The invariant is the
sender's to keep.

**How a regression is caught.** `TraceStore.orphans()` counts stored spans
whose `parent_id` is in no span row, ignoring the last hour so a flow that is
merely still open is not miscounted as broken.
`scripts/observability/trace-orphans.py` prints it (`--max-rate` exits
non-zero over budget, so it can gate), and
`scripts/visitor-sim/beacon-probe.mjs` checks the same invariant on the real
wire from one credentialed page load: no `traceparent` on a telemetry path,
and every outbound parent id resolving in the store.

## 4d. DELIVERY: `keepalive` is for the last batch of a visit and nothing else

§4c is about never NAMING a span we will not record. This is about the span we
promised, buffered, and then destroyed in the tab.

**The measurement.** Over 24 hours on the live store, **175 of 459
`input.dispatch` spans — 38% — named a parent that was never stored** (26 of 84,
31%, over the six hours the investigation opened with). The daemon's half of a
sampled input trace always landed; the browser's `input.edge`, which is that
trace's ROOT, often did not. And it failed in long unbroken RUNS that start
mid-session and never recover: on win311, twenty consecutive edges landed
between 18:31:53 and 18:33:07 and every edge after 18:33:19 was lost. Whole
sessions exist in the store with 81 daemon spans and not one browser span of
any kind.

**The cause, and it is not in the trace plane at all.** Six senders posted
every batch with `keepalive: true` — `/traces` (`analytics/index.ts`),
`/analytics` (`sink.ts`), `/logs` (`logSink.ts`), `/clientlog`
(`three/clientDebug.ts`), `/usage` (`three/usageStats.ts`) and `/coverage`
(`analytics/coverage.ts`). `keepalive` was chosen for one real reason — the
LAST batch of a visit has to outlive the tab — and then applied to all of them
for free.

It is not free. **A document gets ONE 64 KiB keepalive allowance, and in Chrome
it is not returned when the request finishes: it is spent for the life of the
document.** Probed against the real gallery in Chrome 150 (the browser this
wall serves), posting 4 KiB keepalive bodies to `/traces`:

```
  15 succeed  ->  the 16th rejects `TypeError: Failed to fetch`
  every later keepalive fetch rejects IMMEDIATELY, forever
  a plain (non-keepalive) fetch to the same URL still succeeds, 20/20
```

~61 KiB, and the tab's telemetry is over. That is exactly what the access log
shows at the moment a run of losses begins: `/traces`, `/analytics`,
`/clientlog` and `/logs` all stop in the same second, while `/clientcmd` keeps
polling every five seconds and the vendor's `/eum` keeps beaconing — so the tab
looks perfectly healthy, and it is still minting real trace ids and putting
them on the wire for the daemon to pick up. Every sender swallowed the
rejection in a bare `.catch(() => {})`; nothing was logged, nothing retried.

**And `/traces` destroyed the batch rather than delaying it**, because
`flushSpans()` drains the buffer BEFORE the upload. A dropped counter reads
slightly low forever; a dropped span batch deletes the ROOT of a trace whose
other half is already on its way to the same store by an independent path, and
the store can then never draw the join.

**The three rules, in `spa/src/analytics/beacon.ts`, which is now the only way
this tab uploads telemetry:**

1. **`keepalive` ONLY on the final flush** — `pagehide`, or
   `visibilitychange` → hidden, which is the only one iOS Safari reliably
   gives. An interval flush has a live document to complete in and costs
   nothing from the allowance. A visit now spends a few KiB at the end instead
   of exhausting the budget in its first two minutes.
2. **The response body is ALWAYS drained.** Not politeness: an unread response
   holds its allocation open, which is what turned a per-request budget into a
   per-document one. `void fetch(...)` is banned in that module for this
   reason, and `/clientcmd` and `/eum` — which read their bodies — are why they
   never broke.
3. **A batch with NO ANSWER is kept, not deleted.** `postTelemetry` reports
   three outcomes and callers treat them differently: `sent` (2xx — drop it),
   `refused` (the server answered and said no: a settled answer, drop it, since
   re-queueing a refusal turns one lost row into an unbounded queue of them),
   and `failed` (no answer at all — the box unreachable, or the allowance gone
   — so KEEP it; `spanBuffer.requeueSpans` puts it back at the front).

**How a regression is caught.** The same `trace-orphans.py` §4c already
describes, plus `spa/src/analytics/beacon.test.ts`, which pins each of the
three rules against a stubbed fetch — including that a rejection reports
`failed` rather than being swallowed.

## 5. Sampling is all-or-nothing PER TRACE, and it is decided ONCE

The `01` flag is set by the tab and every layer honours it. A layer that
sampled independently would produce traces with holes in them, and a hole in a
flame graph is indistinguishable from a gap in the work.

At this scale everything is sampled. The flag exists so that turning sampling
down later is a one-line change in one place rather than four.

### 5.1 The source keeps everything; the VENDOR EXPORT decides — 2026-09-01

The input plane used to sample at the source: one key or click edge in
`SAMPLE_N` (default 10) got a trace and the other nine were never minted. That
had three faults, and the third is the one that mattered.

* It was **every-Nth, not random**. Input is periodic — key auto-repeat, a held
  key, a drag — so a counter firing on every tenth edge can lock onto one PHASE
  of a repeat burst and sample the same recurring moment forever. That is not a
  sample of the population.
* It applied **one rate to populations differing by orders of magnitude**, so a
  rare click — the edge a visitor thought hardest about — had the same 10%
  chance as the two-hundredth sample of a drag.
* It **discarded precisely the interesting events**. An 800 ms keystroke had a
  90% chance of never being traced, and the tail IS the signal for latency
  work.

The third fault cannot be fixed at the source at any rate, because the decision
there happens BEFORE the round trip: the browser cannot know which edge will
turn out to be the slow one. So the decision moved to where the answer exists,
and the two halves are now one design.

**SOURCE — keep everything.** Every key and click edge is traced, in full, into
`traces.db`. One box, our own disk, our own data; completeness beats cleverness
when nobody is short of capacity.

**FORWARD — decide what the vendor is shown.**
`scripts/observability/tail_sampler.py`, at the Instana leg, keeps every
errored action, every slow one, and one in ten of the rest.

**That split is NOT a capacity measure, and a future reader must not
"optimise" it as one.** Our own plane keeps everything on purpose. The tail
decision exists solely to keep Instana's Calls and Services views legible,
because routine traffic drowns the interesting traffic there.

**Why the decision can live at the forward at all** is the part worth
remembering. Tail sampling normally needs a collector that buffers a complete
trace before deciding, which is hard across processes — the browser cannot
decide for spans the daemon has not emitted, and the daemon cannot decide for
the browser's return leg. **We already have that collector: `traces.db`.** All
three producers land there, and the forwarder ALREADY holds a trace until it
has taken nothing new for `instana_backlog.QUIET_MS` (210 s, sized so a trace's
daemon half has certainly arrived). That quiet window IS the buffering a tail
sampler needs; it simply was not making a keep/drop decision yet.

**"Slow" is derived, not chosen.** A fixed threshold cannot be right on this
fleet: measured on the live store, `transport.frame.next` over 597 real samples
runs p50 = 43 ms, p90 = 243 ms, p99 = 489 ms — an eleven-fold spread inside one
distribution, before a ZX Spectrum is compared with a w2kalpha. So the line is
a rolling p95 of the last 512 completed actions, floored at 279 ms, and the
floor is the number that is derived: modelling the round trip from the same
store's measured parts at the 90th percentile gives `transport.frame.next`
243 ms + the client return leg 23 ms + the application RTT 13 ms = 279 ms.
It says "never call an action slow when nine in ten already are". Without it, a
good hour would drag the rolling p95 down to tens of milliseconds and ordinary
actions would start being forwarded as "slow", which is the noise the whole
mechanism exists to remove.

**Motion is still not traced, and not for volume.** Pointer motion is a
continuous signal at up to ~250 Hz; "how long from movement to pixel" is a rate
and a latency histogram, and thousands of eight-span trees describe a
distribution worse than one histogram does. The time-series lane owns it.

**The sampling factor: the docs are silent.** Instana's call detail shows a
"Sampling factor" field, and nothing in the 326-file corpus at
`/home/wnt/instana-docs` documents a way for an OTLP producer to declare one —
no "sampling factor", no `sampling.factor`, no extrapolation, no
`x-instana-` header. The single adjacent hint is a PHP-tracer release note
(`0006-tracers-and-autotrace-webhook.md`) that its tracer "captures the
OpenTelemetry TraceState sampling threshold value and reports it to the
backend", implying an OTEP 235 `tracestate` `ot=th:` path documented for no
other producer and promised to no one. So the sampler stamps our OWN
`kh.sampling.factor` and `kh.sampling.reason` on the EXPORTED spans — never on
the store, which kept everything and for which a factor would be a lie — and
claims nothing about the vendor reading them.

**And counts never depend on any of it.** Every input edge already increments
the always-on counter plane: `three/usageStats.ts` tallies every key and click
per station to `/usage`, and the `station.key.used` / `station.pointer.used`
probes land in `analytics.db`. Neither passes through the sampler, so "how many
clicks happened" is an exact count from an unsampled source, and the sampler
only decides which of them Instana is shown a flame graph FOR.

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

## 7. ONE TRACE MEANS ONE ACTION — 2026-09-01

**A trace used to mean a visit, and that was the defect underneath everything
else in this section.** A real operator session on win311 produced trace
`fc4a9d74…`: 43 spans, root `serve.page`, 15.7 s of wall clock, still taking
writes 74.4 s after it started, with five separate keystrokes sitting as
SIBLINGS under the page span seconds apart. Instana assembles a trace in about
two seconds, so a trace that dribbles for 74 s is fragmented by construction —
which is what its "the position of this call in the calls tree is unknown
because the parent call is missing" banner was reporting.

It was also NON-DETERMINISTIC. The page-load JOIN (§4a as it stood) attached
new traces to `serve.page` for 15 seconds. Reproduced live in one tab in one
minute: eight sampled key edges inside the window came out as children of
`serve.page`; eight click edges 15 s later came out as their own roots. Two
shapes for one thing, decided by a stopwatch, and every downstream reader had
to cope with both.

So each of these is now its OWN trace, with its own root:

| trace | root | what one of them is |
|---|---|---|
| page load | `serve.page` (python, server) | one `index.html` request |
| station connect | `station.connect` (browser) | one attempt to open a station |
| station restore | `station.restore` (browser) | one restore-to-golden |
| **input action** | `input.edge` (browser, client) | one key or click, edge → pixel |

```
station.connect                          (browser, ROOT)
├─ http.client.request            client  (khFetch.ts, automatic; GET
│  │                                        /signal/<station>.json in its
│  │                                        attributes, never its name)
│  └─ serve.signal                server  (python: a CHILD of the client span,
│     │                                     and it names itself back in
│     └─ serve.ticket.mint      internal   traceresponse)
├─ streamhost.session             server  (rust: joined by ticket id)
│  ├─ guest.resume              internal  (emulator: cont / SIGCONT)
│  ├─ capture.first_frame       internal
│  ├─ encode.first_key          internal
│  └─ transport.first_frame     internal
└─ station.connect.firstFrame   internal
```

```
input.edge                       client   (browser, ROOT — its DURATION is the
├─ input.wire                    client    edge → painted pixel round trip)
└─ input.dispatch.<class>        server   (daemon — the trace's ENTRY span)
   ├─ guest.frame.next         internal
   ├─ transport.frame.next     internal
   ├─ client.frame.receive     internal   (browser — §3.3's return leg)
   ├─ client.frame.decode      internal
   └─ client.frame.paint       internal
```

The daemon emits one more trace that has no browser in it at all, because a
station boots with nobody watching — a root `streamhost.start` with
`guest.launch`, `guest.attach` and `guest.first_frame` under it (§6, and
`streamhost/streamhost/src/trace_guest.rs`). It is deliberately NOT attached to
a visitor's trace: inventing that parent would be the false causal claim §8
forbids.

The last three return-leg spans exist only when the daemon's return-path mark
and this tab's own receive/decode/paint for the same `frame_id` both actually
happen (§3.3) — a dropped or never-marked frame leaves the daemon's spans
standing alone, which is not an error, just an incomplete return leg. **The
daemon's entry span missing entirely is a different thing, and it is usually a
deployment fact rather than a bug — read §3.5 before reading it as one.**

### 7.1 The relation to the page load: a LINK and an ATTRIBUTE, never a parent

A keystroke really was caused by a page load, and that fact is still recorded.
It is just no longer spelled as containment, because containment is a claim
about a unit of work and a keystroke thirty seconds into a visit is not part of
the request that served the HTML.

Every trace ENTRY this tab opens therefore carries **both**:

* an OTel **span LINK** naming `serve.page`'s trace and span, with
  `kh.link.kind=page.load` (`spa/src/analytics/pageLoadLink.ts`,
  `scripts/serve/traces.py`'s `links` column, `traces_otlp.py`'s `links`
  export). Instana surfaces links in the call Details view
  (`instana-docs/0307-opentelemetry-signals.md`, "OpenTelemetry span events and
  span links"), and `/admin/observability` renders them as a jump.
* the **`kh.page.loadId` attribute** (`analytics/pageBinding.ts`).

**Both, and it is not belt-and-braces.** A link is what a UI NAVIGATES — one
click from a slow keystroke to the page load it happened on — and it cannot be
filtered or grouped by. An attribute is what a QUERY GROUPS BY — "every action
on this page load", one equality filter, in our own SQL and in Instana's
Unbounded Analytics — and it cannot be navigated. Neither substitutes for the
other, and the link additionally survives a consumer that has never heard of
`kh.` anything.

**No window, no count, no consumption.** The old join was bounded by 15 seconds
and 32 joins because a JOIN goes stale: a station opened ten minutes after boot
did not happen "inside" the page load. A LINK makes only the claim that is true
for the whole life of the JS realm — this action happened on that document — so
it needs no expiry. A full navigation tears the realm down and the next load
reads a fresh tag.

### 7.2 Traces before 2026-09-01 are not comparable with traces after it

Say it out loud, because the numbers look like the same numbers.

* A trace **was** a visit and **is** an action, so span-count, trace-duration
  and traces-per-visit all changed meaning on that date. A drop in "mean spans
  per trace" from 43 to 8 is this change, not a regression.
* `input.edge`'s duration **was** ~0–1 ms of local enqueue and **is** the
  edge → painted-pixel round trip, so any input-latency series steps from
  roughly 1 ms to roughly 250 ms at the boundary.
* `client.input.roundtrip` no longer exists; its figure is the root's duration.
* The daemon's entry span split from `input.dispatch` into
  `input.dispatch.key` / `input.dispatch.click`, so a per-endpoint series in
  Instana starts over on that date.
* Before the fix in §4d, an unknown share of browser spans never reached the
  store at all (38% of `input.dispatch` spans were orphaned over the 24 h
  measured), so pre-boundary volume is an undercount of unknown size.

Do not plot across the boundary. Compare 2026-09-01 onwards with itself.

## 8. Rules that are not negotiable

- **Never fail a request because of a header.** §1.
- **Never invent a parent.** An unknown or malformed context starts a new trace.
- **Never let the meta-tag injection break the page.** §4: any failure serves
  `index.html` unchanged, byte-for-byte.
- **Never let a response header break a response.** §4b: the return leg is
  written inside a `try` at one choke point, and an untraced route emits
  nothing at all.
- **A propagated header names the span that made the call**, never the
  ambient one — and never a span that will not be recorded. When there is no
  such span there is NO HEADER. §4a, §4c.
- **Never propagate into a guest.** §6.
- **Never put a secret in a span.** The ticket carries the trace id; the trace
  never carries the ticket. Auth headers, cookies and passkey material likewise.
  `traces.py` enforces it at intake by attribute name and by key shape
  (`BANNED_ATTRS`, `SECRET_KEY_RE`), so a slip here is refused rather than
  stored. This is the ONE content rule, it is security, and it is not a proxy
  for a general "keep spans thin" instinct — stacks, messages, full URLs and
  the account identity are all wanted (`docs/ANALYTICS.md` §0).
- **Typed keystroke CONTENT stays out until the operator says otherwise.**
  §3.2: a key class is a coarse bucket, never the key. Held behind
  `KH_TRACE_TYPED_TEXT` (default off) rather than settled by an agent — the one
  open question in ANALYTICS.md §0.5.
- **A layer that cannot trace still works.** Every hop degrades to "no parent",
  never to "no service".
- **Never fake a hop that does not exist.** §3.4: input travels over
  WebTransport, not HTTP, so there is no `http.client.request` span on the
  input path and never will be. Describe the transport that IS there.
- **Never name a span for a claim the evidence does not support.** §3.4:
  `guest.frame.next` is the next frame the guest produced, which is not the
  same statement as "the guest reacted" — so it is not called `guest.ack`.
  Rule 9's framebuffer discipline, applied to a span name.
- **A span that cannot be stored is worse than no span.** §3.5: run anything
  new through `traces.py`'s real validators in a test
  (`scripts/test_input_trace_intake.py`), because intake refuses silently and a
  refused span reads downstream as a zero.
- **A trace is ONE ACTION, never a visit.** §7. A relation between two actions
  is a span LINK plus an attribute, never a parent: nesting asserts
  containment, and a keystroke thirty seconds into a visit is not part of the
  request that served the HTML.
- **A span's DURATION is elapsed time for the thing the span is named after.**
  §3.3: `input.edge` is the round trip a visitor waited, not the millisecond it
  took to hand a record to a stream writer. A root whose duration measures
  something narrower than its name is read wrong by every consumer that reads
  roots, and none of them can tell.
- **`keepalive` belongs to the LAST batch of a visit and to nothing else**, the
  response body is always drained, and a batch with no answer is kept rather
  than deleted. §4d — one 64 KiB allowance per document, spent once, and
  spending it on every flush silently killed four telemetry routes mid-visit
  and orphaned 38% of the input plane.
- **The source keeps everything; the VENDOR EXPORT decides what is forwarded.**
  §5.1. Never re-introduce sampling at the source to "protect" the store: the
  store is not what is short, and a source-side coin has to be flipped before
  the duration exists, which throws away exactly the slow actions the plane is
  for.
- **An old browser and an old daemon must both keep working against a new
  counterpart.** §3.2: the fleet rolls in canaried waves and the SPA deploys
  independently of it, so a version skew between browser and daemon is the
  NORMAL state, not an edge case — never the exception.

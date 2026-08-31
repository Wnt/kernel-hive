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
| browser → serving plane | `traceparent` request header | on `/signal/*`, `/traces`, `/analytics`, `/usage`, `/walkin/*` |
| serving plane → its own spans | in-process | child of the inbound span |
| browser → daemon (input plane) | the session ticket | the input plane is WebTransport straight to the daemon's QUIC listener and carries no headers, so the id rides the thing that is already exchanged |
| daemon → its own spans | in-process | child of the session's root |
| daemon → emulator | **not propagated** | see §5 |

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
carries the ticket** (§7).

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

## 4. Sampling is all-or-nothing, and the browser decides

The `01` flag is set by the tab and every layer honours it. A layer that
sampled independently would produce traces with holes in them, and a hole in a
flame graph is indistinguishable from a gap in the work.

At this scale everything is sampled. The flag exists so that turning sampling
down later is a one-line change in one place rather than four.

## 5. The emulator is deliberately NOT traced from inside

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

## 6. What a complete trace looks like

```
station.connect                                  (browser, root)
├─ signal.fetch                        client    (browser)
│  └─ serve.signal                     server    (python: mints the id below)
│     └─ serve.ticket.mint             internal
├─ streamhost.session                  server    (rust: joined by ticket id)
│  ├─ guest.resume                     internal  (emulator: cont / SIGCONT)
│  ├─ capture.first_frame              internal
│  ├─ encode.first_key                 internal
│  ├─ transport.first_frame            internal
│  └─ input.first_edge                 internal
└─ station.open.toFirstFrameMs         internal  (browser, the metric's twin)
```

The daemon emits one more trace that has no browser in it at all, because a
station boots with nobody watching — a root `streamhost.start` with
`guest.launch`, `guest.attach` and `guest.first_frame` under it (§5, and
`streamhost/streamhost/src/trace_guest.rs`). It is deliberately NOT attached to
a visitor's trace: inventing that parent would be the false causal claim §7
forbids.

Four processes, one trace id, one flame graph. The browser's own
`station.open.toFirstFrameMs` span sits beside the daemon's `guest.resume`, and
the question "was it slow because the guest was asleep" stops being a
correlation exercise.

## 7. Rules that are not negotiable

- **Never fail a request because of a header.** §1.
- **Never invent a parent.** An unknown or malformed context starts a new trace.
- **Never propagate into a guest.** §5.
- **Never put a secret in a span.** The ticket carries the trace id; the trace
  never carries the ticket. Same rule as `traces.py`: no stacktraces, no typed
  text, no credential handles.
- **A layer that cannot trace still works.** Every hop degrades to "no parent",
  never to "no service".

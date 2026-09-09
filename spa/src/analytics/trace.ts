// ============================================================================
//  analytics/trace — session, trace and span ids, and the spans themselves.
//  ---------------------------------------------------------------------------
//  THIS IS THE CORRELATED LANE, AND IT IS MEANT TO BE RICH. The counter plane
//  (analytics.py) is a per-day aggregate with no session column, so it can
//  never answer "show me the visit that produced that number"; this one can,
//  and the operator's standing instruction is that it carry as much as it
//  usefully can — stacks, URLs, and the identity of the account involved
//  (docs/ANALYTICS.md §0 is the policy; `startTrace` stamps the identity).
//  Reads are ADMIN-ONLY; the aggregates stay open.
//
//  ONE THING IS REFUSED HERE AND IT IS NOT A PREFERENCE: a SECRET never goes
//  in a span — no ticket, no cookie, no auth header, no passkey material.
//  `scripts/serve/traces.py` enforces the same rule at intake by name and by
//  shape, so a mistake in this file is caught there rather than stored.
//
//  Until 2026-09-01 this header instead argued for a "content rule" — no
//  stacks, no URLs, no identity, values clipped at 120 characters. That was an
//  AI-invented constraint that later sessions read back as policy, and it cost
//  the plane the stack of every fault it recorded. Do not reconstruct it.
//
//  A SECOND, DELIBERATE narrowing on 2026-08-31: `three/streamClient/
//  inputTrace.ts` collects a per-input timing series — every key and click edge
//  becomes a real `input.edge` span, chained through the daemon
//  (`streamhost/src/input_trace.rs`) to the guest write and the frame it
//  produced. This is the operator's call, made with eyes open, not erosion: it
//  exists because the open keyboard-lag investigation (a suspected pacing-queue
//  floor in the emulator ctl module) needed an end-to-end input->pixel flame
//  graph and nothing short of per-edge tracing draws one. It was 1-in-10 until
//  2026-09-01, when the sampler moved to the VENDOR EXPORT — where a trace is
//  complete and its duration is known, so the slow ones can be kept rather than
//  thrown away by a coin the source had to flip too early
//  (`scripts/observability/tail_sampler.py`).
//
//  What still never leaves the tab is TYPED KEYSTROKE CONTENT — the one item on
//  the 2026-09-01 richness pass the operator has not been asked about, held
//  behind `KH_TRACE_TYPED_TEXT` in traces.py (default off) rather than settled
//  by an agent. `kh.key.class` is a coarse bucket (printable/modifier/
//  navigation/enter/function) computed from the wire scancode the daemon was
//  already going to receive to work at all — two unrelated keys in the same
//  bucket produce the identical string, and nothing in the span can be
//  inverted back to which key was pressed.
//
//  THIS IS OPENTELEMETRY DATA, not a private format that resembles it. The
//  span model below is OTel's: 128-bit trace ids and 64-bit span ids in
//  lowercase hex as `traceparent` carries them, OTel span KINDS, OTel status
//  codes (UNSET/OK/ERROR), OTel span EVENTS, and attribute names taken from the
//  semantic conventions wherever one exists (`session.id`, `exception.type`,
//  `url.path`, `error.type`). Nothing here had to be invented, so nothing here
//  has to be translated later.
//
//  WHAT IS NOT OTLP IS THE WIRE ENCODING, and only that. OTLP/JSON spells every
//  attribute as `{"key":"x","value":{"stringValue":"y"}}`, which is three to
//  five times the bytes for data a browser is uploading over a metered link on
//  pagehide. So the wire uses short keys, the store keeps them, and
//  `GET /traces/otlp` renders faithful OTLP/JSON ResourceSpans on demand — the
//  mapping is 1:1 and lossless in both directions (scripts/serve/traces.py
//  documents it field by field). Compatibility that matters lives at the
//  BOUNDARY, where another system reads; paying for it on every upload from
//  every tab would buy nothing.
//
//  TWO CLOCKS, ON PURPOSE. A span records wall-clock duration, because a flame
//  graph that hid time is a lying flame graph — if a visitor backgrounded the
//  tab for three minutes mid-connect, the graph must show three minutes. It
//  ALSO records how much of that was hidden, so the same span can feed the
//  metric aggregates, which count visible time only (metrics.ts). One
//  observation, two honest readings; deriving either from the other after the
//  fact is impossible, which is why both are captured at the source.
// ============================================================================

import { pageLoadLink, __resetPageLoadLink } from './pageLoadLink';
import { pageLoadId } from './pageBinding';
import {
  bufferHasRoom, bufferSpan, configureSpanBuffer, scheduleEntryFlush, tracerEnabled,
  __resetSpanBuffer,
} from './spanBuffer';

// Re-exported so every existing importer keeps one import site for "the
// tracer": the buffer split (2026-09-01) was a size-budget move, not a change
// of interface.
export { flushSpans, requeueSpans, __bufferedSpans } from './spanBuffer';

/** Lowercase hex, `n` bytes. Uses crypto when it exists — not for secrecy, but
 *  because Math.random collides sooner than you would like once ids are being
 *  joined across two stores. */
function hex(bytes: number): string {
  const b = new Uint8Array(bytes);
  try {
    (globalThis.crypto as Crypto | undefined)?.getRandomValues(b);
  } catch { /* fall through to the Math.random fill below */ }
  let empty = true;
  for (const v of b) if (v !== 0) { empty = false; break; }
  if (empty) for (let i = 0; i < b.length; i += 1) b[i] = Math.floor(Math.random() * 256);
  return Array.from(b, (v) => v.toString(16).padStart(2, '0')).join('');
}

/** 128-bit, as `traceparent` carries it. */
export function newTraceId(): string { return hex(16); }
/** 64-bit, as `traceparent` carries it. */
export function newSpanId(): string { return hex(8); }

/** OTel status codes. `unset` is a span that ended without an opinion, which
 *  is the correct default — OTel reserves `ok` for a span whose success was
 *  explicitly asserted, not merely not-failed. */
type SpanStatus = 'unset' | 'ok' | 'error';

/** OTel span kinds. A browser plane is nearly all `internal`, with `client`
 *  for the spans that wait on something over the network — which is exactly
 *  the distinction that makes a flame graph readable. */
export type SpanKind = 'internal' | 'client' | 'server' | 'producer' | 'consumer';

/** An OTel span event: a timestamped point inside a span. An exception is
 *  recorded as one, per the semantic conventions, rather than as a status
 *  message — that is what lets an error keep its own attributes. */
interface SpanEvent {
  n: string;
  /** ms since epoch. */
  t: number;
  a?: Attrs;
}

/**
 * An OTel SPAN LINK: "this span was caused by that one, WITHOUT being nested
 * under it". Since 2026-09-01 a trace here means ONE ACTION, so a keystroke is
 * no longer a child of the page load it happened on — the causal edge is real
 * and is drawn with a link instead of a parent. `pageLoadLink.ts` has the
 * reasoning and why the same fact ALSO rides as an attribute.
 */
export interface SpanLink {
  t: string;
  s: string;
  a?: Attrs;
}

/** Attribute values worth carrying. Deliberately narrow: no objects, no
 *  arrays, nothing that could become a nested payload of visitor content. */
type AttrValue = string | number | boolean;
export type Attrs = Record<string, AttrValue>;

/** Longest ordinary attribute string kept. 2048, raised from 120 on
 *  2026-09-01: the old cap was a content rule dressed as a size rule, and it
 *  truncated anything worth reading. Mirrors `traces.ATTR_STR_MAX`. */
const ATTR_STR_MAX = 2048;
/** The long-value allowance, for attributes whose whole point is a long value.
 *  A stack clipped to 2 KiB is still a usable stack; clipped to 120 it is one
 *  frame. Mirrors `traces.ATTR_STR_MAX_LONG` / `traces.LONG_ATTRS`. */
const ATTR_STR_MAX_LONG = 16384;
const LONG_ATTRS = new Set([
  'exception.stacktrace', 'code.stacktrace', 'exception.message', 'url.full', 'url.query',
]);
/** Attributes per span. A bound on a runaway caller, not on richness: measured
 *  on the live store, the busiest span carries nine. Mirrors `traces.ATTR_MAX`. */
const ATTR_MAX = 64;

/** One span on the wire. Short keys: a trace is many spans and this travels
 *  per session, unlike the counters which fold. */
export interface WireSpan {
  t: string;              // traceId
  s: string;              // spanId
  p: string | null;       // parentSpanId
  n: string;              // name
  kd: SpanKind;           // OTel span kind
  st: number;             // start, ms since epoch (wall)
  d: number;              // duration ms (wall)
  h: number;              // of which hidden ms — NOT an OTel field, see header
  k: SpanStatus;          // OTel status code
  m?: string;             // OTel status message
  a?: Attrs;              // OTel attributes
  e?: SpanEvent[];        // OTel span events
  l?: SpanLink[];         // OTel span links
}

/** A live span. End it exactly once. */
export interface Span {
  readonly traceId: string;
  readonly spanId: string;
  /** Open a child of this span. */
  child(name: string, attrs?: Attrs, kind?: SpanKind): Span;
  /** Add an attribute. Ignored after the span ends. */
  attr(key: string, value: AttrValue): void;
  /** Add an OTel span event — a timestamped point inside this span. */
  event(name: string, attrs?: Attrs): void;
  /** Record a thrown value as an OTel `exception` event AND mark the span
   *  errored. Both, because they answer different questions: the status is what
   *  makes the span red in a flame graph, the event is what carries the type
   *  and message. The stack is deliberately NOT attached — see the module
   *  header; /clientlog is where stacks live. */
  recordException(err: unknown): void;
  /** Finish. Later calls are ignored, so a `fail` in a catch followed by an
   *  `ok` in a finally cannot report both — the same rule flows.ts uses. */
  end(status?: SpanStatus, attrs?: Attrs, message?: string): void;
  /**
   * Finish AT a `performance.now()` reading the caller already took, rather
   * than at "now".
   *
   * For a span whose end is learnt LATER than it happened. The live example is
   * `input.edge`: its duration is meant to be the visitor-facing edge → painted
   * pixel round trip, and the tab only finds out which frame answered the edge
   * when the daemon's frame mark arrives, which can be well after that frame
   * was painted (docs/lab/TRACE-CONTEXT.md §3.3). Ending at `now()` there would
   * charge the span for the mark's own travel time, which is not what a visitor
   * waited for.
   *
   * `atMs` is the SAME clock `now()` reads, and the caller must have taken it
   * in THIS tab — that is the whole reason this measurement needs no clock
   * agreement between the two machines. A reading in the future, or before the
   * span started, is clamped rather than trusted.
   */
  endAt(atMs: number, status?: SpanStatus, attrs?: Attrs): void;
}

/** A span that does nothing, for every path that must not throw. */
const NOOP: Span = {
  traceId: '',
  spanId: '',
  child: () => NOOP,
  attr: () => {},
  event: () => {},
  recordException: () => {},
  end: () => {},
  endAt: () => {},
};

let open = 0;
/** Open spans, so a leaking call site cannot grow the tab without bound. */
const MAX_OPEN = 128;

/** Wire the tracer to a sink. Until this is called nothing is buffered and
 *  nothing is sent — the same gate the counter sink uses, for the same reason:
 *  a signed-out stranger at the walk-in door would otherwise queue forever.
 *  The buffer and the flush rules live in `spanBuffer.ts`. */
export function configureTracer(opts: {
  enabled: boolean;
  emit: (spans: WireSpan[], final: boolean) => void;
  identity?: Attrs;
}): void {
  configureSpanBuffer({ enabled: opts.enabled, emit: opts.emit });
  identity = opts.identity && Object.keys(opts.identity).length ? opts.identity : undefined;
}

/** WHO this tab belongs to, stamped on the span that ENTERS each trace (never
 *  on every span — one copy per journey is what a query needs and 1/N the
 *  bytes). `enduser.id` / `user.name` are OTel semantic-convention names and
 *  are accepted by `scripts/serve/traces.py` since 2026-09-01: "which account
 *  hit this" is the question a support ticket opens with, and the plane could
 *  not answer it. Absent for a visitor who has no account — never a placeholder
 *  or an empty string, which would be a value that means "unknown" and reads
 *  like a user. */
let identity: Attrs | undefined;

function clean(attrs?: Attrs): Attrs | undefined {
  if (!attrs) return undefined;
  const out: Attrs = {};
  let n = 0;
  for (const [k, v] of Object.entries(attrs)) {
    if (n >= ATTR_MAX) break;
    if (typeof v === 'string') out[k] = v.slice(0, LONG_ATTRS.has(k) ? ATTR_STR_MAX_LONG : ATTR_STR_MAX);
    else if (typeof v === 'number' && Number.isFinite(v)) out[k] = v;
    else if (typeof v === 'boolean') out[k] = v;
    else continue;
    n += 1;
  }
  return n ? out : undefined;
}

function now(): number {
  try {
    return typeof performance !== 'undefined' ? performance.now() : Date.now();
  } catch { return Date.now(); }
}

function hiddenNow(): boolean {
  try {
    return typeof document !== 'undefined' && document.visibilityState === 'hidden';
  } catch { return false; }
}

/**
 * Hidden-time accounting, shared by every open span. A visibility change is a
 * single global event, so each span only has to know how much hidden time had
 * accrued when it started; the difference at `end()` is its own share.
 */
let hiddenTotal = 0;
let hiddenSince: number | null = null;
let hookInstalled = false;

function installVisibilityHook(): void {
  if (hookInstalled || typeof document === 'undefined') return;
  hookInstalled = true;
  try {
    if (hiddenNow()) hiddenSince = now();
    document.addEventListener('visibilitychange', () => {
      if (hiddenNow()) {
        if (hiddenSince === null) hiddenSince = now();
      } else if (hiddenSince !== null) {
        hiddenTotal += now() - hiddenSince;
        hiddenSince = null;
      }
    });
  } catch { /* no hook: spans then report zero hidden time, which we cannot fix */ }
}

function hiddenElapsed(): number {
  return hiddenTotal + (hiddenSince === null ? 0 : now() - hiddenSince);
}

/** Events per span, bounded for the same reason attributes are. Mirrors
 *  `traces.EVENT_MAX`. */
const EVENT_MAX = 64;

/** `traceEntry` marks a span THIS TAB opened a trace with — see `end()`. */
function makeSpan(
  traceId: string,
  parentId: string | null,
  name: string,
  attrs?: Attrs,
  kind: SpanKind = 'internal',
  traceEntry = false,
  links?: SpanLink[],
): Span {
  if (!tracerEnabled() || open >= MAX_OPEN) return NOOP;
  installVisibilityHook();
  open += 1;
  const spanId = newSpanId();
  const t0 = now();
  const wall0 = Date.now();
  const hidden0 = hiddenElapsed();
  const own = clean(attrs) ?? {};
  const events: SpanEvent[] = [];
  let ended = false;
  return {
    traceId,
    spanId,
    child(childName: string, childAttrs?: Attrs, childKind?: SpanKind) {
      // Never a trace entry: its parent is a span in THIS tab, which will
      // schedule the flush that carries this one when it ends.
      return makeSpan(traceId, spanId, childName, childAttrs, childKind);
    },
    attr(key: string, value: AttrValue) {
      if (ended) return;
      const c = clean({ [key]: value });
      if (c) Object.assign(own, c);
    },
    event(eventName: string, eventAttrs?: Attrs) {
      if (ended || events.length >= EVENT_MAX) return;
      events.push({ n: eventName.slice(0, 80), t: Date.now(), a: clean(eventAttrs) });
    },
    recordException(err: unknown) {
      if (ended) return;
      // OTel semantic conventions for an exception event: type, message AND
      // stacktrace. The stack was omitted until 2026-09-01 on an AI-invented
      // content rule; the store accepts it now with a 16 KiB allowance, and a
      // fault whose trace does not carry its stack is a fault you go and look
      // for somewhere else (docs/ANALYTICS.md §0).
      const type = err instanceof Error ? err.name : typeof err;
      const message = err instanceof Error ? err.message : String(err ?? '');
      const stack = err instanceof Error ? (err.stack ?? '') : '';
      this.event('exception', {
        'exception.type': String(type).slice(0, 80),
        'exception.message': message,
        ...(stack ? { 'exception.stacktrace': stack } : {}),
      });
      if (!('error.type' in own)) own['error.type'] = String(type).slice(0, 80);
    },
    end(status: SpanStatus = 'unset', endAttrs?: Attrs, message?: string) {
      finish(now(), status, endAttrs, message);
    },
    endAt(atMs: number, status: SpanStatus = 'unset', endAttrs?: Attrs) {
      // Clamped, not trusted: a reading before the span started, or after
      // "now", is a caller bug and must not become a negative or a fictional
      // duration in a flame graph.
      finish(Math.min(now(), Math.max(t0, atMs)), status, endAttrs);
    },
  };

  function finish(atMs: number, status: SpanStatus, endAttrs?: Attrs, message?: string): void {
    try {
      if (ended) return;
      ended = true;
      open -= 1;
      Object.assign(own, clean(endAttrs) ?? {});
      if (!bufferHasRoom()) return;
      bufferSpan({
        t: traceId,
        s: spanId,
        p: parentId,
        n: name.slice(0, 80),
        kd: kind,
        st: wall0,
        d: Math.max(0, Math.round(atMs - t0)),
        h: Math.max(0, Math.round(hiddenElapsed() - hidden0)),
        k: status,
        ...(message ? { m: message.slice(0, 200) } : {}),
        ...(Object.keys(own).length ? { a: own } : {}),
        ...(events.length ? { e: events } : {}),
        ...(links && links.length ? { l: links } : {}),
      });
      // A TRACE ENTRY that just ended is this tab's whole contribution to a
      // trace, and one nobody has uploaded is an orphan class of its own: the
      // server span naming it is already stored, so until this joins it there
      // the trace reads as rootless.
      //
      // `traceEntry`, NOT `parentId === null`. Since 2026-09-01 an entry IS
      // always a root (a trace is one action — `pageLoadLink.ts`), so the two
      // predicates now agree; the flag is kept because it says what is meant.
      // It was not always so, and that is why it exists: while the old
      // page-load JOIN was live, `startTrace()` hung the tab's entry off
      // `serve.page`'s span id, so a boot fetch's client span HAD a parent and
      // never looked like a root. Measured on the deployed build then: the
      // client spans for `/gallery-manifest.json` and `/boot/index.json` were
      // absent from the store 12 s after the load and present at 30 s — waiting
      // for the 20 s tick, which is exactly the window a short visit does not
      // survive. `scheduleEntryFlush` says why this is not a shorter interval.
      if (traceEntry) scheduleEntryFlush();
    } catch { /* instrumentation never throws into the app */ }
  }
}

/**
 * The span a new child should attach to, innermost first.
 *
 * A browser has no thread-local and no async context to hang this on, so the
 * stack is explicit and callers push/pop it. That is a real limitation and it
 * is worth stating rather than hiding: two flows genuinely interleaved in time
 * will nest by CALL ORDER, not by causality. It holds for this app because a
 * flow here is a visitor doing one thing at a time, and the alternative —
 * threading a context object through every call site — would have made the
 * instrumentation invasive enough that people stopped adding it.
 */
const activeSpans: Span[] = [];
const MAX_ACTIVE = 32;

/** The innermost open span, or null. */
export function currentSpan(): Span | null {
  return activeSpans.length ? activeSpans[activeSpans.length - 1] : null;
}

/** Push `span` as the parent for subsequent children. */
export function pushActive(span: Span): void {
  if (activeSpans.length < MAX_ACTIVE) activeSpans.push(span);
}

/** Remove `span` from the active stack wherever it sits — not necessarily the
 *  top, because a flow can outlive a timing opened inside it. */
export function popActive(span: Span): void {
  const at = activeSpans.lastIndexOf(span);
  if (at >= 0) activeSpans.splice(at, 1);
}

/** Open a child of the innermost active span, or a NEW TRACE when there is
 *  none. That fallback is what lets a lone timing still be drillable — an
 *  orphan span with no trace is a row you can count and never inspect. */
export function childOfActive(name: string, attrs?: Attrs, kind?: SpanKind): Span {
  const parent = currentSpan();
  return parent ? parent.child(name, attrs, kind) : startTrace(name, attrs, kind);
}

/**
 * Begin a new trace — a ROOT, always, and THIS TAB'S ENTRY into it.
 *
 * ONE TRACE MEANS ONE ACTION (2026-09-01). One sampled input edge, one
 * `station.connect`, one `station.restore`, one page load: each is its own
 * trace, and the relation between them is drawn with a span LINK plus the
 * `kh.page.loadId` attribute rather than by nesting. `pageLoadLink.ts` carries
 * the evidence for that decision and why both channels are used — the short
 * version is that a trace which meant "a visit" ran to 43 spans over 15.7 s
 * and was still taking writes 74 s in, which no consumer reads correctly.
 *
 * Until that date this function JOINED the page load's trace inside a 15 s
 * window, so an entry sometimes had a parent and sometimes did not, decided by
 * a stopwatch. End the returned span to close this tab's part.
 */
export function startTrace(name: string, attrs?: Attrs, kind?: SpanKind): Span {
  const page = pageLoadLink();
  const own: Attrs = { ...(identity ?? {}), 'kh.page.loadId': pageLoadId(), ...(attrs ?? {}) };
  // `kh.link.kind` names WHY the link exists, so a reader is never left
  // guessing what a bare pair of ids meant. The link rides only the ENTRY
  // span: one copy per trace is what a query and a UI each need, and one per
  // span would be N copies of one fact.
  const links: SpanLink[] | undefined = page
    ? [{ t: page.traceId, s: page.spanId, a: { 'kh.link.kind': 'page.load' } }]
    : undefined;
  return makeSpan(newTraceId(), null, name, own, kind, true, links);
}

/**
 * A span whose start and duration are ALREADY KNOWN, rather than measured
 * live — the browser twin of the daemon's `trace::emit_at`
 * (`streamhost/src/trace/mod.rs`). `Span`/`makeSpan` above assume "opened
 * now, ended later"; that does not fit the return-path frame spans
 * (`three/streamClient/frameTrace.ts`), which are only knowable in
 * hindsight — the daemon's frame-trace mark naming which `frame_id`
 * answered a sampled input can arrive well after this tab already received,
 * decoded and painted that frame (`docs/lab/TRACE-CONTEXT.md` §3.2/§8.1),
 * and by the time the two sides meet the event itself is over.
 *
 * `startAtMs`/`durMs` are `performance.now()`-domain readings a caller
 * already took (the SAME clock `now()` below reads) — never a wall clock —
 * so this converts to the wall-clock `st` the wire format wants the same
 * way `makeSpan`'s `wall0` does.
 */
export function emitSpan(
  traceId: string,
  parentSpanId: string,
  name: string,
  startAtMs: number,
  durMs: number,
  attrs?: Attrs,
  status: SpanStatus = 'ok',
  kind: SpanKind = 'internal',
): void {
  try {
    if (!tracerEnabled() || !bufferHasRoom()) return;
    // ROUNDED, and this is not cosmetic. `/traces` requires an INTEGER start
    // (`traces.py`: `if not isinstance(started, int) ... continue`) and JSON
    // has no integer type to fall back on, so a fractional millisecond is a
    // span the store silently refuses. `Date.now()` is whole but
    // `performance.now()` is not — Chrome reports it at 100 us resolution — so
    // this subtraction produced a float on almost every call and the whole
    // return leg (`client.frame.receive`/`decode`/`paint`) was being dropped
    // at intake: 10 stored paints against 407 daemon `transport.frame.next`
    // spans over 24 h, measured 2026-09-01. `makeSpan` never had the bug
    // because its `wall0` is a bare `Date.now()`. Nothing said anything: the
    // tab thought it had emitted, the store had nothing, and the missing
    // return leg read as "the frame mark never arrived".
    const wallStart = Math.round(Date.now() - (now() - startAtMs));
    const own = clean(attrs);
    bufferSpan({
      t: traceId,
      s: newSpanId(),
      p: parentSpanId,
      n: name.slice(0, 80),
      kd: kind,
      st: wallStart,
      d: Math.max(0, Math.round(durMs)),
      h: 0,
      k: status,
      ...(own ? { a: own } : {}),
    });
  } catch { /* instrumentation never throws into the app */ }
}

/**
 * The `traceparent` header naming ONE SPECIFIC span, or null when that span
 * has no ids (a NOOP span — the tracer is off, or `MAX_OPEN` is exhausted).
 *
 * THIS IS THE ONLY PRODUCER OF AN OUTBOUND `traceparent` IN THE TAB, which is
 * the whole of the no-orphan invariant (docs/lab/TRACE-CONTEXT.md §8): a
 * header names a span this tab created and will record, or there is no header.
 *
 * Two producers lived here until 2026-09-01 and both broke that rule. A
 * private `traceparent()` MINTED `00-<new trace>-<new span>-01` whenever
 * there was no active span, and `traceHeaders()` handed that to every
 * telemetry POST — an id belonging to no span, by construction, on routes the
 * serving plane DOES trace: 565 such ids in six live hours, each a one-span
 * trace Instana renders as "the root call of the trace is missing". The
 * second was `khFetch.ts`'s ambient fallback, naming `currentSpan()` when the
 * call's own span came back NOOP, which pointed thousands of polls at a flow
 * root still open — 2,274 of that window's 2,839 orphans, under twelve ids.
 *
 * Why this takes a span rather than looking one up: a caller that has just
 * OPENED the span it describes must name THAT span, not whatever
 * `currentSpan()` is. `childOfActive()` deliberately does not `pushActive()` —
 * a client span lives across an `await` and this stack is a synchronous LIFO
 * with no async context, so pushing one would re-parent every span unrelated
 * code opens while the request is in flight.
 */
export function traceparentOf(span: Span | null): string | null {
  if (!span || !span.traceId || !span.spanId) return null;
  return `00-${span.traceId}-${span.spanId}-01`;
}

/** Test seam. */
export function __resetTracer(): void {
  activeSpans.length = 0;
  open = 0;
  hiddenTotal = 0;
  hiddenSince = null;
  hookInstalled = false;
  __resetSpanBuffer();
  __resetPageLoadLink();
}

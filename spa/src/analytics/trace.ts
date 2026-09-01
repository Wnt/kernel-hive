// ============================================================================
//  analytics/trace — session, trace and span ids, and the spans themselves.
//  ---------------------------------------------------------------------------
//  THIS REVERSES A GUARANTEE. Until now this plane stored no identities at all,
//  by construction, and docs/ANALYTICS.md said so as a feature: "the only
//  durable privacy guarantee is the data you never wrote down". A trace IS a
//  correlated per-session record — that is what makes drilldown possible — so
//  the guarantee cannot survive alongside it and is not pretended to. What
//  replaces it is narrower and has to be kept honestly:
//
//    * traces are ADMIN-ONLY on the read side; the aggregates stay open;
//    * they have a SHORT retention (days, not years) while the counters keep
//      their two years, so the durable record is still the anonymous one;
//    * the content rules do NOT relax. No typed text, no lengths that could
//      identify content, no credential handles. A span is a name, a duration
//      and a bounded set of attributes.
//
//  Read that as: the plane now knows WHICH SESSION did something for a couple
//  of weeks, and still never knows what was typed into it.
//
//  A SECOND, DELIBERATE narrowing on 2026-08-31: `three/streamClient/
//  inputTrace.ts` now collects a SAMPLED per-input timing series — 1 key or
//  click edge in `SAMPLE_N` (default 10) becomes a real `input.edge` span,
//  chained through the daemon (`streamhost/src/input_trace.rs`) to the guest
//  write and the frame it produced. This is the operator's call, made with
//  eyes open, not erosion: it exists because the open keyboard-lag
//  investigation (a suspected pacing-queue floor in the emulator ctl module)
//  needed an end-to-end input->pixel flame graph and nothing short of
//  per-edge tracing draws one. What still
//  never leaves the tab is unchanged and absolute: no typed text, no key
//  IDENTITY. `kh.key.class` is a coarse bucket (printable/modifier/
//  navigation/enter/function) computed from the wire scancode the daemon was
//  already going to receive to work at all — two unrelated keys in the same
//  bucket produce the identical string, and nothing in the span can be
//  inverted back to which key was pressed. The other N-1 edges in ten cost
//  nothing beyond a counter increment: no id is minted, no span opens, no
//  wire byte changes (docs/lab/TRACE-CONTEXT.md's in-record hop).
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

import { pageLoadParent, __resetPageLoadJoin } from './pageLoadJoin';

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

/** Attribute values worth carrying. Deliberately narrow: no objects, no
 *  arrays, nothing that could become a nested payload of visitor content. */
type AttrValue = string | number | boolean;
export type Attrs = Record<string, AttrValue>;

/** Longest attribute string kept. Enough for a station id or a reason token,
 *  far too short for anything a visitor typed. */
const ATTR_STR_MAX = 120;
/** Attributes per span. A span wanting more than this is being used as a log
 *  line, which is what /clientlog is for. */
const ATTR_MAX = 24;

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
};

/** Spans held between flushes. A trace is worth having whole, so this is
 *  generous compared with the counter buffer — but still bounded, because an
 *  instrumentation bug must cost memory once and then stop. */
const MAX_BUFFERED = 2048;
let buffered: WireSpan[] = [];
let open = 0;
/** Open spans, so a leaking call site cannot grow the tab without bound. */
const MAX_OPEN = 128;
let emit: (spans: WireSpan[]) => void = () => {};
let enabled = false;

/** Wire the tracer to a sink. Until this is called nothing is buffered and
 *  nothing is sent — the same gate the counter sink uses, for the same reason:
 *  a signed-out stranger at the walk-in door would otherwise queue forever. */
export function configureTracer(opts: { enabled: boolean; emit: (spans: WireSpan[]) => void }): void {
  enabled = opts.enabled;
  emit = opts.emit;
}

function clean(attrs?: Attrs): Attrs | undefined {
  if (!attrs) return undefined;
  const out: Attrs = {};
  let n = 0;
  for (const [k, v] of Object.entries(attrs)) {
    if (n >= ATTR_MAX) break;
    if (typeof v === 'string') out[k] = v.slice(0, ATTR_STR_MAX);
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

/** Events per span, bounded for the same reason attributes are. */
const EVENT_MAX = 16;

/** `traceEntry` marks a span THIS TAB opened a trace with — see `end()`. */
function makeSpan(
  traceId: string,
  parentId: string | null,
  name: string,
  attrs?: Attrs,
  kind: SpanKind = 'internal',
  traceEntry = false,
): Span {
  if (!enabled || open >= MAX_OPEN) return NOOP;
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
      // OTel semantic conventions for an exception event. `exception.stacktrace`
      // is part of that convention and is deliberately omitted: a stack is the
      // one field here that can carry arbitrary application strings, and
      // /clientlog already stores stacks against this same session id.
      const type = err instanceof Error ? err.name : typeof err;
      const message = err instanceof Error ? err.message : String(err ?? '');
      this.event('exception', {
        'exception.type': String(type).slice(0, 80),
        'exception.message': message,
      });
      if (!('error.type' in own)) own['error.type'] = String(type).slice(0, 80);
    },
    end(status: SpanStatus = 'unset', endAttrs?: Attrs, message?: string) {
      try {
        if (ended) return;
        ended = true;
        open -= 1;
        Object.assign(own, clean(endAttrs) ?? {});
        if (buffered.length >= MAX_BUFFERED) return;
        buffered.push({
          t: traceId,
          s: spanId,
          p: parentId,
          n: name.slice(0, 80),
          kd: kind,
          st: wall0,
          d: Math.max(0, Math.round(now() - t0)),
          h: Math.max(0, Math.round(hiddenElapsed() - hidden0)),
          k: status,
          ...(message ? { m: message.slice(0, 200) } : {}),
          ...(Object.keys(own).length ? { a: own } : {}),
          ...(events.length ? { e: events } : {}),
        });
        // A TRACE ENTRY that just ended is this tab's whole contribution to
        // a trace, and one nobody has uploaded is the second orphan class:
        // the server span naming it is already stored, so until this joins it
        // there the trace reads as rootless.
        //
        // `traceEntry`, NOT `parentId === null`. That was the first attempt
        // and it missed the one burst it most needed to catch: while the
        // page-load join is live, `startTrace()` hangs the tab's entry off
        // `serve.page`'s span id, so a boot fetch's client span HAS a parent
        // and never looked like a root. Measured on the deployed build: the
        // client spans for `/gallery-manifest.json` and `/boot/index.json`
        // were absent from the store 12 s after the load and present at 30 s
        // — they were waiting for the 20 s tick, which is exactly the window
        // a short visit does not survive. `scheduleEntryFlush` says why this
        // is not a shorter interval.
        if (traceEntry) scheduleEntryFlush();
      } catch { /* instrumentation never throws into the app */ }
    },
  };
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

/** Begin a new trace — THIS TAB'S ENTRY into one, which is not the same as
 *  its root: while the page-load join is live (`pageLoadJoin.ts`) the entry
 *  continues the server's `serve.page` span and therefore HAS a parent. That
 *  distinction is load-bearing in `end()`, which flushes on a trace ENTRY
 *  and not on a parentless span, because under the join the boot burst is
 *  never parentless. End the returned span to close this tab's part. */
export function startTrace(name: string, attrs?: Attrs, kind?: SpanKind): Span {
  const joined = pageLoadParent();
  if (joined) return makeSpan(joined.traceId, joined.spanId, name, attrs, kind, true);
  return makeSpan(newTraceId(), null, name, attrs, kind, true);
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
): void {
  try {
    if (!enabled || buffered.length >= MAX_BUFFERED) return;
    const wallStart = Date.now() - (now() - startAtMs);
    const own = clean(attrs);
    buffered.push({
      t: traceId,
      s: newSpanId(),
      p: parentSpanId,
      n: name.slice(0, 80),
      kd: 'internal',
      st: wallStart,
      d: Math.max(0, Math.round(durMs)),
      h: 0,
      k: status,
      ...(own ? { a: own } : {}),
    });
  } catch { /* instrumentation never throws into the app */ }
}

/** Everything buffered, handed over and cleared. */
function drainSpans(): WireSpan[] {
  const out = buffered;
  buffered = [];
  return out;
}

/** Send whatever is buffered now. */
export function flushSpans(): void {
  try {
    if (!enabled || !buffered.length) return;
    emit(drainSpans());
  } catch { /* never throw */ }
}

/**
 * Send the buffer SOON, coalescing every trace entry that ends in one burst.
 *
 * WHY NOT SIMPLY A SHORTER INTERVAL. The sink's 20 s tick is a POLL: it costs
 * a request per tab per tick whether or not anything happened, so a 1 s worst
 * case would cost 60 requests a minute from every open tab — across a
 * 71-station wall and a gallery of visitors, thousands of mostly-empty POSTs
 * an hour, to shorten a window that only matters at the few instants a trace
 * actually completes. This is demand-driven instead: an idle tab makes NO
 * extra request, and one that finished a journey makes exactly one, when the
 * trace became complete. A root ends a handful of times per visit (one
 * `station.connect`, a `poster.read`, a sampled `input.edge`), not once per
 * poll, so the volume is bounded by what the visitor DID, not by how long they
 * stayed — and the debounce keeps a burst of roots finishing together (the
 * boot burst, ten sampled edges in fast typing) one batch.
 */
const ENTRY_FLUSH_DEBOUNCE_MS = 250;
let entryFlushTimer = 0;

function scheduleEntryFlush(): void {
  try {
    if (typeof window === 'undefined' || entryFlushTimer) return;
    entryFlushTimer = window.setTimeout(() => {
      entryFlushTimer = 0;
      flushSpans();
    }, ENTRY_FLUSH_DEBOUNCE_MS);
  } catch { entryFlushTimer = 0; /* the sink's interval is still the backstop */ }
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
  buffered = [];
  open = 0;
  enabled = false;
  hiddenTotal = 0;
  hiddenSince = null;
  hookInstalled = false;
  emit = () => {};
  if (entryFlushTimer && typeof window !== 'undefined') window.clearTimeout(entryFlushTimer);
  entryFlushTimer = 0;
  __resetPageLoadJoin();
}

/** Test seam: what is buffered but not yet sent. */
export function __bufferedSpans(): WireSpan[] { return [...buffered]; }

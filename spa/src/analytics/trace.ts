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

function makeSpan(
  traceId: string,
  parentId: string | null,
  name: string,
  attrs?: Attrs,
  kind: SpanKind = 'internal',
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

/**
 * The page-load join (docs/lab/TRACE-CONTEXT.md §4/§7): the server names a
 * real `serve.page` span in `<meta name="traceparent">` when it serves
 * index.html, minted before any JS on the page has run. Until this module
 * reads it, every trace this tab opens has no relation to that span — a
 * disconnected forest for one visit, which is exactly the thing tracing
 * exists to stop doing.
 *
 * NOT a one-shot seed consumed by whichever `startTrace()` fires first. That
 * was the original design and it shipped a real bug: `khFetch.ts`'s implicit
 * `childOfActive()` fallback ALSO calls `startTrace()` for any fetch with no
 * active parent — the manifest fetch, `/auth/state`, the signalling
 * document — and in real traffic one of those routinely wins the race
 * against the visit's actual main flow. Evidence, from the live store: a
 * `serve.page` trace containing `serve.auth.walkin.status` (an incidental
 * boot-time fetch that happened to go first) while `station.connect` — the
 * flow this join was built for — showed up as an unrelated 4-span singleton,
 * because by the time `beginFlow('station.connect')` called `startTrace()`
 * the one-shot seed was already gone.
 *
 * THE FIX: the seed is a page-scoped ROOT that MULTIPLE early callers hang
 * off as siblings — the incidental fetch AND `station.connect` both become
 * children of `serve.page`, whichever happens to run first — rather than a
 * prize exactly one of them can claim. Bounded two ways, so a station opened
 * long after boot does not retroactively attach to a stale page load and a
 * runaway caller cannot grow the trace unbounded:
 *   - a short WALL-CLOCK WINDOW from the moment the tag is read (this is a
 *     bound on the visit's OWN boot burst, not a latency measurement, so
 *     `Date.now()` — not `performance.now()` — is the right clock here);
 *   - a hard cap on how many traces may join in that window.
 * Once either bound is passed, `startTrace()` goes back to minting a fresh,
 * unrelated trace id exactly as it always did for a "second, later flow in
 * the same tab" (a retry, a second station opened minutes later).
 */
let pageLoadSeed: { traceId: string; spanId: string; deadline: number } | null = null;
let pageLoadJoins = 0;

/** How long after the tag is read a new trace may still join `serve.page`.
 *  Generous enough to cover the whole boot burst (manifest + auth/state +
 *  the first station's signalling fetch + `station.connect` itself, all of
 *  which can legitimately take a few seconds on a cold cache) without
 *  reaching into an unrelated later visit to the same tab. */
const PAGE_LOAD_JOIN_WINDOW_MS = 15_000;
/** Hard ceiling on how many traces may join one page load, independent of
 *  the time window — the same "bounded, so a leak costs memory once and then
 *  stops" discipline as `MAX_OPEN`/`MAX_ACTIVE` elsewhere in this file. Well
 *  above any honest boot burst. */
const PAGE_LOAD_JOIN_MAX = 32;

const TRACEPARENT_RE = /^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$/i;

/** Parse a `traceparent` value per §1; null for anything that is not exactly
 *  that shape. Exported so the meta-tag reader and tests share one parser
 *  rather than two regexes drifting apart. */
export function parseTraceparent(value: string | null | undefined): { traceId: string; spanId: string } | null {
  if (!value) return null;
  const m = TRACEPARENT_RE.exec(value.trim());
  if (!m) return null;
  return { traceId: m[1].toLowerCase(), spanId: m[2].toLowerCase() };
}

/** Seed the page-load join directly from a `traceparent` value. Exported for
 *  tests; `joinPageLoadTraceFromMeta` is what boot code actually calls. A
 *  malformed or missing value clears the seed — the same "malformed → start a
 *  new trace, never refuse the work" rule as everywhere else in this file. */
export function seedPageLoadTrace(traceparent: string | null | undefined): void {
  const parsed = parseTraceparent(traceparent);
  pageLoadSeed = parsed ? { ...parsed, deadline: Date.now() + PAGE_LOAD_JOIN_WINDOW_MS } : null;
  pageLoadJoins = 0;
}

/**
 * Read `<meta name="traceparent">` and seed the page-load join, if present.
 * Called once from main.tsx, early — before the first flow opens. Safe with
 * no DOM (tests, SSR-shaped tooling) and safe with no tag at all (a build
 * with tracing unbound, a dev server that never went through
 * `static_files.py`, a stale cached document): both leave the seed unset and
 * every trace mints its own id exactly as it always has.
 */
export function joinPageLoadTraceFromMeta(): void {
  try {
    if (typeof document === 'undefined') return;
    const el = document.querySelector('meta[name="traceparent"]');
    seedPageLoadTrace(el?.getAttribute('content'));
  } catch {
    pageLoadSeed = null;
  }
}

/** Begin a new trace. The returned span is its root; end it to close the
 *  trace. While a page-load join is live (see above), EVERY trace opened
 *  within its window and count bound continues `serve.page` as a sibling —
 *  not just the first one — so the visit's incidental early fetches and its
 *  actual main flow (`station.connect`) both land under the same root
 *  instead of racing for it. Once the window or the count bound passes,
 *  this mints a fresh, unrelated trace id exactly as before. */
export function startTrace(name: string, attrs?: Attrs, kind?: SpanKind): Span {
  if (pageLoadSeed && pageLoadJoins < PAGE_LOAD_JOIN_MAX && Date.now() <= pageLoadSeed.deadline) {
    pageLoadJoins += 1;
    return makeSpan(pageLoadSeed.traceId, pageLoadSeed.spanId, name, attrs, kind);
  }
  return makeSpan(newTraceId(), null, name, attrs, kind);
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
 * The `traceparent` header for an outbound request, so the serving plane can
 * make its span a child of ours (docs/lab/TRACE-CONTEXT.md).
 *
 * Takes the CURRENT span when there is one and mints a fresh trace when there
 * is not — a fetch that happens outside any journey is still worth being able
 * to follow, and returning nothing would have made those requests invisible on
 * the server side rather than merely parentless.
 */
function traceparent(): string {
  return traceparentOf(currentSpan()) ?? `00-${newTraceId()}-${newSpanId()}-01`;
}

/**
 * The `traceparent` header naming ONE SPECIFIC span, or null when that span
 * has no ids (a NOOP span — the tracer is off).
 *
 * Why this is exported and `traceparent()` is not: a caller that has just
 * OPENED the span it is about to describe must name THAT span, not whatever
 * `currentSpan()` happens to be. `childOfActive()` deliberately does not
 * `pushActive()` — a client span lives across an `await`, and this stack is a
 * synchronous LIFO with no async context, so pushing one would silently
 * re-parent every span opened by unrelated code while the request is in
 * flight. `khFetch.ts` therefore builds its header from its own span with
 * this, rather than the active-span model being bent to make an implicit
 * lookup come out right.
 */
export function traceparentOf(span: Span | null): string | null {
  if (!span || !span.traceId || !span.spanId) return null;
  return `00-${span.traceId}-${span.spanId}-01`;
}

/** Headers to merge into a same-origin fetch. Never throws: a request that
 *  cannot be traced must still be a request. */
export function traceHeaders(): Record<string, string> {
  try {
    return { traceparent: traceparent() };
  } catch {
    return {};
  }
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
  pageLoadSeed = null;
  pageLoadJoins = 0;
}

/** Test seam: what is buffered but not yet sent. */
export function __bufferedSpans(): WireSpan[] { return [...buffered]; }

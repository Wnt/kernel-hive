// ============================================================================
//  three/streamClient/inputTrace — SAMPLED per-input tracing: the browser's
//  half of the in-record hop `docs/lab/TRACE-CONTEXT.md` documents and
//  `streamhost/src/input_trace.rs` decodes.
//  ---------------------------------------------------------------------------
//  THE DECISION IS MADE HERE, ONCE, and nowhere downstream samples again
//  (`scripts/serve/tracing.py`'s "SAMPLING IS THE BROWSER'S DECISION",
//  contract §5's W3C sampled-flag semantics applied to a transport that has no
//  flag byte of its own — presence of the suffix on the wire IS the flag). A
//  UI tab decides, mints a fresh trace, and appends its ids to the ~1-in-N
//  records this module is asked about; the daemon only ever RECOGNISES that
//  decision (`input_trace.rs`'s doc comment says so explicitly) and never
//  samples independently.
//
//  EVERY KEY AND EVERY CLICK IS TRACED. There is no sampler here any more.
//
//  Until 2026-09-01 this module traced every `SAMPLE_N`-th qualifying edge
//  (default 10), and that counter had three faults. It ALIASED: input is
//  periodic — key auto-repeat, a held key, a drag — so a counter firing on
//  every tenth edge can lock onto one PHASE of a repeat burst and sample the
//  same recurring moment forever, which is not a sample of the population. It
//  applied ONE rate to populations differing by orders of magnitude, so a rare
//  click — the edge a visitor thought hardest about — got the same 10% chance
//  as the two-hundredth sample of a drag. And it discarded PRECISELY the
//  interesting events: an 800 ms keystroke had a 90% chance of never being
//  traced, and the tail IS the signal for latency work.
//
//  The third fault is unfixable at this end at any sampling rate, because the
//  decision here happens BEFORE the round trip — this code cannot know which
//  edge will turn out to be the slow one. So the decision moved to where the
//  answer exists, and the two halves are one design:
//
//     SOURCE (here)  — emit EVERYTHING for keys and clicks. Our own box, our
//                      own store, our own data; completeness beats cleverness,
//                      and every action is in the store to be queried.
//     FORWARD        — `scripts/observability/tail_sampler.py`, at the Instana
//                      leg, where the trace is COMPLETE and its duration is
//                      known: keep every error, every slow action, and a random
//                      share of the rest.
//
//  THAT SPLIT IS NOT A CAPACITY MEASURE, and a future reader must not
//  "optimise" it as one. Our own plane keeps everything on purpose. The tail
//  decision exists solely to keep the VENDOR's Calls and Services views
//  legible, because routine traffic there drowns the interesting traffic.
//
//  MOUSE MOTION IS STILL NOT TRACED, and not for volume either. Motion is a
//  CONTINUOUS SIGNAL sampled at up to ~250 Hz; "how long from movement to
//  pixel" is a rate and a latency histogram, and thousands of eight-span trees
//  describe that worse than one histogram does — you cannot read a distribution
//  off a list of flame graphs. The time-series lane owns that measurement.
//  Nothing here forbids an occasional motion EXEMPLAR, and one should be added
//  beside the histogram it is an exemplar OF, not before it.
//
//  WHAT NEVER TRAVELS. The suffix is 25 bytes: a marker and two ids. No
//  keycode, no button, no coordinate, no character is added to the record by
//  this module — those already exist in the record for the feature to work at
//  all (the guest has to be told which key), and this module never reads them
//  into a span attribute. `keyClass` below is a BUCKET the caller computes
//  from the same scancode already on its way to the wire, matching
//  `input_trace.rs::key_class` bucket-for-bucket so a browser span and a
//  daemon span drawn from the same edge agree on the word, without either
//  process ever transmitting which key it was.
// ============================================================================
import { startTrace, type Span } from '../../analytics/trace';
import { reportBackendTrace } from '../../analytics/instana';
import { transportAttrs } from './transportFacts';

// -- the EUM↔backend join (Instana `reportEvent`) ---------------------------
// A vendor beacon can name a backend trace; a backend span can never name a
// browser session — the join is one-directional and has to be driven from
// here, the ONE place a sampled `input.edge` trace is minted
// (docs/lab/TRACE-CONTEXT.md §3.2, docs/ANALYTICS.md §8.1).
//
// The mechanics — the guarded `ineum` call, the 16-or-32-hex `backendTraceId`
// rule the vendor enforces SILENTLY, the meta-key cap — now live in
// `analytics/instana.ts`, which is where facts about the vendor belong. They
// were declared here while this module was the only caller; `khFetch.ts`
// reporting the same join off a response header made a local copy a second
// opinion about what the vendor accepts, and two opinions is exactly how a
// silently-dropped field survives a green test suite.

/**
 * Tag a just-minted sampled `input.edge` trace onto the browser session via
 * Instana's EUM↔backend join. A no-op, entirely, when `window.ineum` does not
 * exist (unconfigured build — the vendor script never loaded) and when the
 * span is a NOOP (tracing off, empty trace id) — our own tracing above this
 * call is already complete and unaffected either way.
 *
 * `meta` NEVER carries a key's identity or typed text — the caller already
 * enforces that (`keyClass` is a bucket, `kh.input.class` is a wire-record
 * type), and this function only forwards what it is given.
 */
function reportSampledEdge(span: Span, meta: Record<string, string>): void {
  reportBackendTrace('kh.input.sampled', span.traceId, meta);
}

/** 0xC5 marker + 16-byte trace id + 8-byte span id, matching
 *  `input_trace::SUFFIX_MARKER` / `SUFFIX_LEN` exactly. */
const SUFFIX_MARKER = 0xc5;
const TRACE_ID_BYTES = 16;
const SPAN_ID_BYTES = 8;
export const SUFFIX_LEN = 1 + TRACE_ID_BYTES + SPAN_ID_BYTES;

/** Forget every pending edge. Test seam only — production never needs this. */
export function __resetSampleCounter(): void {
  for (const e of pendingEdges.values()) {
    try {
      if (e.timer !== null) clearTimeout(e.timer);
    } catch { /* noop */ }
  }
  pendingEdges.clear();
  pendingOrder.length = 0;
}

/** Open the `input.edge` trace for ONE qualifying edge — a key transition or a
 *  button transition, never a pointer-move sample (see the header: motion is a
 *  continuous signal and belongs in the time-series lane).
 *
 *  ALWAYS returns a span for a qualifying edge when tracing is on; the `| null`
 *  is the tracer being OFF, not a sampling decision, and there is no longer any
 *  sampling decision to make here. The "maybe" in the name now means "maybe
 *  tracing is configured" rather than "maybe this edge won the lottery".
 *
 *  NULL, NOT A NOOP SPAN, WHEN THE TRACER IS OFF — and that is a wire
 *  correctness rule, not tidiness. A NOOP span is truthy with EMPTY ids, and
 *  `inputWire.ts` reads `span ? withSuffix(...) : bare`, so returning one put a
 *  25-byte ALL-ZERO trace suffix on the record. The daemon rejects a zero
 *  context (`input_trace::strip`), so it was pure waste on every key and click
 *  a tracing-disabled tab ever sent — 1-in-10 of them while this module
 *  sampled, and ALL of them from the moment it stopped. Not sending it is the
 *  honest half of the same rule the daemon enforces from its end. */
export function maybeSampleEdge(
  name: string,
  attrs: Record<string, string>,
): Span | null {
  const span = startTrace(name, attrs, 'client');
  if (!span.traceId) return null;
  // The span stays OPEN. Its duration is the round trip to the painted pixel,
  // which this tab only learns when the daemon names the answering frame
  // (`frameTrace.ts` -> `settleEdge`), so it cannot be ended here — and every
  // path out is covered: the answer, the timeout, or eviction below.
  if (span.traceId) {
    const traceId = span.traceId;
    let timer: ReturnType<typeof setTimeout> | null = null;
    try {
      timer = setTimeout(() => closeEdge(traceId, null, false), EDGE_ANSWER_TIMEOUT_MS);
      // Node's timer would hold a test process open; a browser has no such
      // method and does not need one.
      (timer as { unref?: () => void }).unref?.();
    } catch { /* no timer: eviction below is still a hard bound */ }
    if (!pendingEdges.has(traceId)) pendingOrder.push(traceId);
    pendingEdges.set(traceId, { span, atMs: performance.now(), timer });
    while (pendingOrder.length > MAX_PENDING_EDGES) {
      const oldest = pendingOrder[0];
      if (oldest === undefined) break;
      closeEdge(oldest, null, false);
      // `closeEdge` removes it from both structures; guard against a traceId
      // that was already gone so this can never spin.
      if (pendingOrder[0] === oldest) pendingOrder.shift();
    }
  }
  // Fires only on the edges that actually mint a trace, so an untraced edge
  // pays nothing here either — `reportSampledEdge` itself no-ops below that
  // (unconfigured build, or a NOOP span because our own tracing is disabled).
  reportSampledEdge(span, attrs);
  return span;
}

// -- the transport hop, and the browser-clock round trip ---------------------
// TWO THINGS THE OLD SHAPE LEFT INVISIBLE, added here because this is the one
// module that already knows a sampled edge exists.
//
// 1. `input.wire` — the WebTransport hop as ITS OWN span rather than an
//    unexplained gap between `input.edge` (this tab) and `input.dispatch` (the
//    daemon). Its DURATION is only the local handoff: how long this tab spent
//    getting the record into the QUIC stream writer, which is where
//    backpressure shows up. The hop's actual cost is not a duration this tab
//    can measure — the daemon's clock is a different clock, and subtracting
//    two wall clocks across two machines yields skew, not latency — so it is
//    carried as the connection's own `kh.transport.rtt_ms` instead
//    (`transportFacts.ts`). A measured RTT beside a measured local enqueue is
//    an honest account of the hop; a span whose ends were read off two clocks
//    would not be.
//
// 2. `client.input.roundtrip` — edge to painted pixel, start and end BOTH read
//    from this tab's own `performance.now()`, so it is the one number in the
//    whole tree that needs no clock agreement at all. Emitted from
//    `frameTrace.ts` once the daemon names which `frame_id` answered this
//    edge. It is the operator's actual question ("how long until I saw it")
//    and it is the envelope the daemon's own spans decompose.

/** Edges still waiting for the frame that answers them: `traceId` -> the live
 *  `input.edge` span and the browser-clock reading at which it was minted.
 *  Bounded, and an entry that never gets an answer is settled by the timeout
 *  below rather than left open — an open span is never buffered, so leaking one
 *  would delete the root of its trace, which is the exact failure this whole
 *  change exists to remove. Small because the input side already samples
 *  and a frame answers within a handful of frames. */
const MAX_PENDING_EDGES = 32;

/** How long an edge waits for its answering frame before it is settled
 *  unanswered.
 *
 *  Generous on purpose: the open keyboard-lag investigation is about round
 *  trips that are TOO LONG, so a cap that quietly discarded the slow ones would
 *  delete exactly the evidence it exists to collect. 3 s is far above any
 *  healthy round trip (measured ~240 ms on win95) and far below "leaked".
 *  An idle or damage-gated guest may legitimately never produce a frame at all
 *  (`guest.frame.next` is the NEXT frame, not an acknowledgement —
 *  docs/lab/TRACE-CONTEXT.md §3.4), and that edge still deserves to land: it
 *  does, with `kh.input.answered=false`, so "no frame came back" is a value in
 *  the store and not a missing row. */
const EDGE_ANSWER_TIMEOUT_MS = 3000;

interface PendingEdge {
  span: Span;
  atMs: number;
  /** `globalThis.setTimeout`, not `window.setTimeout`: this module has to
   *  behave identically under the test runner's node environment, and a
   *  guard on `window` there quietly meant "no timeout at all" — which is
   *  the leak this timer exists to prevent. */
  timer: ReturnType<typeof setTimeout> | null;
}

const pendingEdges = new Map<string, PendingEdge>();
const pendingOrder: string[] = [];

/** End one pending edge exactly once, whatever settles it. */
function closeEdge(traceId: string, atMs: number | null, answered: boolean): void {
  const e = pendingEdges.get(traceId);
  if (!e) return;
  pendingEdges.delete(traceId);
  const at = pendingOrder.indexOf(traceId);
  if (at >= 0) pendingOrder.splice(at, 1);
  try {
    if (e.timer !== null) clearTimeout(e.timer);
  } catch { /* the span is closed below either way */ }
  const attrs = { 'kh.input.answered': answered };
  if (answered && atMs !== null) e.span.endAt(atMs, 'ok', attrs);
  else e.span.end('unset', attrs);
}

/**
 * The frame that answered `traceId` finished painting at `paintAtMs`. Ends the
 * `input.edge` span AT that moment, so the ROOT's duration IS the visitor's
 * edge → painted-pixel round trip.
 *
 * THIS IS THE ONE MEASUREMENT THAT NEEDS NO CLOCK AGREEMENT. Both ends —
 * `atMs` when the edge was sampled, `paintAtMs` when the answering frame was
 * painted — are `performance.now()` readings from THIS tab. Everything else in
 * the tree is a browser reading beside a daemon reading, so the tree's SHAPE
 * depends on two machines' wall clocks lining up; this number does not, and it
 * is the envelope the daemon's `input.dispatch` / `guest.frame.next` /
 * `transport.frame.next` decompose.
 *
 * It replaced a sibling span, `client.input.roundtrip`, which carried exactly
 * this figure next to a root whose own duration was 0–1 ms of local enqueue.
 * Two spans for one measurement meant every consumer that reads a root's
 * duration — a trace list, a latency percentile, Instana's endpoint view —
 * read 1 ms for something a visitor waited 240 ms for.
 */
export function settleEdge(traceId: string, paintAtMs: number): void {
  closeEdge(traceId, paintAtMs, true);
}

/** Run `write` inside a child `input.wire` span when this edge is sampled, and
 *  run it untouched when it is not. `reliability` is the caller's own fact —
 *  `stream` for a key/button record on its per-class QUIC stream, `datagram`
 *  for pointer motion — because the two have genuinely different loss and
 *  latency behaviour.
 *
 *  The write is in a `try/finally` so a throwing writer still closes the span:
 *  a wire span that never ends would be a hole in the tree exactly where the
 *  failure was. */
export function writeTraced(
  span: Span | null,
  reliability: 'stream' | 'datagram',
  write: () => void,
): void {
  if (!span) { write(); return; }
  const wire = span.child('input.wire', transportAttrs(reliability), 'client');
  try {
    write();
  } finally {
    wire.end('ok');
  }
}

function hexToBytes(hex: string, out: Uint8Array, offset: number, len: number): void {
  for (let i = 0; i < len; i += 1) {
    out[offset + i] = parseInt(hex.substr(i * 2, 2), 16) || 0;
  }
}

/** Encode `span`'s ids as the 25-byte wire suffix. Only called for a span
 *  `maybeSampleEdge` actually returned, so this never runs on the unsampled
 *  path. */
export function traceSuffix(span: Span): Uint8Array {
  const out = new Uint8Array(SUFFIX_LEN);
  out[0] = SUFFIX_MARKER;
  hexToBytes(span.traceId, out, 1, TRACE_ID_BYTES);
  hexToBytes(span.spanId, out, 1 + TRACE_ID_BYTES, SPAN_ID_BYTES);
  return out;
}

/** Append `suffix` after `body`'s meaningful bytes (`body` may be a larger
 *  buffer than `bodyLen` when a caller over-allocated; only the first
 *  `bodyLen` bytes are kept). */
export function withSuffix(body: Uint8Array, bodyLen: number, suffix: Uint8Array): Uint8Array {
  const out = new Uint8Array(bodyLen + suffix.length);
  out.set(body.subarray(0, bodyLen), 0);
  out.set(suffix, bodyLen);
  return out;
}

/** `kh.key.class` — mirrors `input_trace::key_class` in streamhost bucket for
 *  bucket, computed from the SAME XT set-1 wire scancode
 *  (`streamClient/keysym.ts`) that is already being sent so the guest's
 *  keyboard can be driven at all. A bucket, never the key: two different keys
 *  in the same bucket produce the identical string. */
export function keyClass(scancode: number): string {
  const base = scancode & 0x00ff;
  const extended = (scancode >> 8) === 0xe0;
  if (base === 0x1c) return 'enter'; // Return, and extended 0xE01C numpad Enter
  const modifierBases = extended
    ? [0x1d, 0x38, 0x5b, 0x5c, 0x5d] // RCtrl/RAlt/LWin/RWin/Menu
    : [0x1d, 0x2a, 0x36, 0x38, 0x3a, 0x45, 0x46]; // Ctrl/LShift/RShift/Alt/Caps/Num/Scroll
  if (modifierBases.includes(base)) return 'modifier';
  const navBases = [0x0f, 0x47, 0x48, 0x49, 0x4b, 0x4d, 0x4f, 0x50, 0x51, 0x52, 0x53];
  if (navBases.includes(base)) return 'navigation';
  if ((!extended && base >= 0x3b && base <= 0x44) || base === 0x57 || base === 0x58) {
    return 'function';
  }
  return 'printable';
}

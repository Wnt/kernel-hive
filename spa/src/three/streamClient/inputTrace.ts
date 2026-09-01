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
//  THE KNOB. `SAMPLE_N` below — one exported constant, one place, changed and
//  redeployed like any other SPA constant. Default 10: a visitor typing or
//  clicking normally produces a real span roughly once a second, enough to see
//  the input->pixel path without spending a span per keystroke.
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

/** The knob: 1 input edge in this many gets a real span and a wire context.
 *  Documented default per docs/lab/TRACE-CONTEXT.md and docs/ANALYTICS.md §8.1
 *  — changing it is a one-line SPA edit, redeployed like any other constant. */
export const SAMPLE_N = 10;

/** 0xC5 marker + 16-byte trace id + 8-byte span id, matching
 *  `input_trace::SUFFIX_MARKER` / `SUFFIX_LEN` exactly. */
const SUFFIX_MARKER = 0xc5;
const TRACE_ID_BYTES = 16;
const SPAN_ID_BYTES = 8;
export const SUFFIX_LEN = 1 + TRACE_ID_BYTES + SPAN_ID_BYTES;

let counter = 0;

/** Reset the sampling counter. Test seam only — production never needs this,
 *  the counter free-runs for the life of the tab. */
export function __resetSampleCounter(): void {
  counter = 0;
  pendingEdges.clear();
  pendingOrder.length = 0;
}

/** The browser's sampling decision for ONE qualifying edge (a key transition
 *  or a button transition — never a pointer-move sample, which arrives at up
 *  to ~250 Hz and would defeat the entire point of sampling). Returns a live
 *  span on the sampled edge, `null` on the other N-1 — which is the ENTIRE
 *  cost an unsampled edge pays here: one increment, one comparison, no
 *  allocation, no id minted (`startTrace` is not even called). */
export function maybeSampleEdge(
  name: string,
  attrs: Record<string, string>,
): Span | null {
  counter += 1;
  if (counter < SAMPLE_N) return null;
  counter = 0;
  const span = startTrace(name, attrs, 'client');
  // Remember this edge so `frameTrace.ts` can close a browser-clock round trip
  // against the frame the daemon eventually names as its answer.
  if (span.traceId) {
    if (!pendingEdges.has(span.traceId)) pendingOrder.push(span.traceId);
    pendingEdges.set(span.traceId, { spanId: span.spanId, atMs: performance.now() });
    while (pendingOrder.length > MAX_PENDING_EDGES) {
      const old = pendingOrder.shift();
      if (old !== undefined) pendingEdges.delete(old);
    }
  }
  // Fires only on the ~1-in-SAMPLE_N edges that actually mint a trace, so the
  // other N-1 pay nothing here either — `reportSampledEdge` itself no-ops
  // below that (unconfigured build, or a NOOP span because our own tracing
  // is disabled).
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

/** Edges awaiting their answering frame: `traceId` -> the edge span's id and
 *  the browser clock reading at which it was minted. Bounded, and an entry
 *  that never gets an answer simply ages out — the rest of the trace still
 *  stands. Small because the input side already samples 1-in-`SAMPLE_N` and a
 *  frame answers within a handful of frames. */
const MAX_PENDING_EDGES = 32;
const pendingEdges = new Map<string, { spanId: string; atMs: number }>();
const pendingOrder: string[] = [];

/** Consume the pending edge for `traceId`, if this tab minted one. Consuming
 *  (rather than peeking) is deliberate: exactly one round-trip span per edge,
 *  even if the daemon marks two frames against the same trace. */
export function takePendingEdge(traceId: string): { spanId: string; atMs: number } | null {
  const e = pendingEdges.get(traceId);
  if (!e) return null;
  pendingEdges.delete(traceId);
  return e;
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

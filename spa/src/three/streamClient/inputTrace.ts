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

// -- the EUM↔backend join (Instana `reportEvent`) ---------------------------
// A vendor beacon can name a backend trace; a backend span can never name a
// browser session — the join is one-directional and has to be driven from
// here, the ONE place a sampled `input.edge` trace is minted
// (docs/lab/TRACE-CONTEXT.md §3.2, docs/ANALYTICS.md §8.1). `ineum('reportEvent',
// name, { backendTraceId, ... })` is the documented mechanism; the vendor
// bundle validates `backendTraceId` as a hex string of EXACTLY 16 or 32
// characters and SILENTLY DROPS the field otherwise (established by reading
// the real minified agent, not the docs — the docs state no such length rule
// at all). Our `Span.traceId` is already 32 lowercase hex
// (`analytics/trace.ts`'s `newTraceId()`), so no reformatting happens here —
// only a defensive length check, so a future change to that format cannot
// silently start sending a value the vendor drops without anyone noticing.
//
// Declared locally (rather than importing `instana.ts`'s private `ineum`
// guard) so this module has no dependency on that file beyond its own
// judgment of what is safe to send — the same isolation `navigation.ts` and
// `khFetch.ts` already keep from it.
declare global {
  interface Window {
    ineum?: (...args: unknown[]) => void;
  }
}

function ineum(...args: unknown[]): void {
  try {
    if (typeof window === 'undefined') return;
    const fn = window.ineum;
    if (typeof fn === 'function') fn(...args);
  } catch {
    /* never throw: the vendor is a benchmark, never a dependency */
  }
}

/** Exactly what the vendor bundle accepts for `backendTraceId` — 16 or 32 hex
 *  characters. Exported so a test can assert against the SAME rule this
 *  module gates on, rather than a looser one that would pass while the
 *  feature is silently dead on the wire. */
export const BACKEND_TRACE_ID_RE = /^[0-9a-f]{16}$|^[0-9a-f]{32}$/i;

/** Attributes per `reportEvent` `meta` object. The vendor's own default is 25
 *  (`maxMetadataKeys`); this module never comes close, but the cap is
 *  enforced here rather than trusted to stay true by inspection. */
const META_MAX_KEYS = 25;

/**
 * Tag a just-minted sampled `input.edge` trace onto the browser session via
 * Instana's EUM↔backend join. A no-op, entirely, when `window.ineum` does
 * not exist (unconfigured build — the vendor script never loaded) — our own
 * tracing above this call is already complete and unaffected either way.
 *
 * `meta` NEVER carries a key's identity or typed text — the caller already
 * enforces that (`keyClass` is a bucket, `kh.input.class` is a wire-record
 * type), and this function only forwards what it is given, capped at
 * `META_MAX_KEYS`.
 */
function reportSampledEdge(span: Span, meta: Record<string, string>): void {
  if (typeof window === 'undefined' || typeof window.ineum !== 'function') return;
  if (!BACKEND_TRACE_ID_RE.test(span.traceId)) return; // NOOP span (tracing off) or malformed — never send a value the vendor would drop
  const capped: Record<string, string> = {};
  let n = 0;
  for (const [k, v] of Object.entries(meta)) {
    if (n >= META_MAX_KEYS) break;
    capped[k] = v;
    n += 1;
  }
  ineum('reportEvent', 'kh.input.sampled', {
    timestamp: Date.now(),
    backendTraceId: span.traceId,
    meta: capped,
    maxMetadataKeys: META_MAX_KEYS,
  });
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
  // Fires only on the ~1-in-SAMPLE_N edges that actually mint a trace, so the
  // other N-1 pay nothing here either — `reportSampledEdge` itself no-ops
  // below that (unconfigured build, or a NOOP span because our own tracing
  // is disabled).
  reportSampledEdge(span, attrs);
  return span;
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

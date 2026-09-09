// ============================================================================
//  analytics/spanBuffer — spans between `end()` and the wire, and the two
//  rules that decide whether a trace ever reaches the store.
//  ---------------------------------------------------------------------------
//  Split out of `trace.ts` on 2026-09-01, the same size-budget move that made
//  `pageLoadJoin.ts`: that file was at its 600-line hard cap and every real
//  change to the tracer was being paid for by deleting prose that explained it.
//  This is the second cleanly separable concern in it — a bounded array, a
//  debounce and a sink handle, which the span model calls and which calls
//  nothing back.
//
//  TWO RULES LIVE HERE, and both were bought by measured data loss.
//
//  1. **A BATCH THAT DID NOT LAND IS NOT DELETED.** `flushSpans` used to drain
//     the buffer into a `void fetch(...).catch(() => {})`. A failed upload
//     therefore destroyed the batch in the tab — and the batch is the half of
//     the trace that carries its ROOT, while the daemon's half is already on
//     its way to the same store by an independent path. `requeueSpans` puts a
//     `failed` batch back; `analytics/beacon.ts` is what tells the difference
//     between "the server said no" (settled — drop it) and "there was no
//     answer" (keep it).
//
//  2. **A TRACE ENTRY FLUSHES AS SOON AS IT ENDS**, debounced so a burst
//     leaves as one batch. Not a shorter interval: the sink's tick is a POLL
//     and costs a request whether or not anything happened, so a 1 s interval
//     would be 60 requests a minute from every open tab across a 71-station
//     wall. This is demand-driven — an idle tab costs nothing, a finished
//     journey costs exactly one request.
//
//     A trace ENTRY, not a parentless span, and the difference is load-bearing:
//     while the page-load join is live (`pageLoadJoin.ts`) this tab's entry
//     hangs off `serve.page`'s span id and therefore HAS a parent. Keying the
//     flush on parentlessness missed the whole boot burst, measured on the
//     deployed build: the client spans for `/gallery-manifest.json` and
//     `/boot/index.json` were absent from the store 12 s after the load and
//     present at 30 s — waiting for the 20 s tick, which is exactly the window
//     a short visit does not survive, while the `traceparent` naming them had
//     already gone out.
// ============================================================================

import type { WireSpan } from './trace';

/** Spans held between flushes. A trace is worth having whole, so this is
 *  generous compared with the counter buffer — but still bounded, because an
 *  instrumentation bug must cost memory once and then stop. */
const MAX_BUFFERED = 2048;
let buffered: WireSpan[] = [];

/** `final` says this is the LAST flush of a visit (`pagehide` / hidden) — the
 *  only one allowed to spend the document's keepalive allowance. See
 *  `beacon.ts` for the 64 KiB that allowance is and what it cost. */
let emit: (spans: WireSpan[], final: boolean) => void = () => {};
let enabled = false;

/** Point the buffer at a sink. Until this is called nothing is buffered and
 *  nothing is sent — the same gate the counter sink uses, for the same reason:
 *  a signed-out stranger at the walk-in door would otherwise queue forever. */
export function configureSpanBuffer(opts: {
  enabled: boolean;
  emit: (spans: WireSpan[], final: boolean) => void;
}): void {
  enabled = opts.enabled;
  emit = opts.emit;
}

/** Is the tracer wired to a sink at all? `trace.ts` asks before minting. */
export function tracerEnabled(): boolean {
  return enabled;
}

/** Hold one finished span for the next flush. Silently full is deliberate:
 *  the alternative is an unbounded tab. */
export function bufferSpan(span: WireSpan): void {
  if (buffered.length >= MAX_BUFFERED) return;
  buffered.push(span);
}

/** Room left, so a caller can decline to build a span it could not hold. */
export function bufferHasRoom(): boolean {
  return buffered.length < MAX_BUFFERED;
}

/** Everything buffered, handed over and cleared. */
function drainSpans(): WireSpan[] {
  const out = buffered;
  buffered = [];
  return out;
}

/** Send whatever is buffered now. `final` marks the ONE flush of a visit that
 *  has to outlive the document. */
export function flushSpans(final = false): void {
  try {
    if (!enabled || !buffered.length) return;
    emit(drainSpans(), final);
  } catch { /* never throw */ }
}

/**
 * Put a batch that could NOT be delivered back, so the next flush carries it.
 *
 * Bounded like everything else here: an unreachable box costs memory once and
 * then stops. When there is not room for the whole batch the NEWEST spans are
 * kept — an old span whose trace has already been summarised is the one worth
 * dropping.
 */
export function requeueSpans(spans: WireSpan[]): void {
  try {
    if (!enabled || !spans.length) return;
    const room = MAX_BUFFERED - buffered.length;
    if (room <= 0) return;
    buffered = spans.slice(Math.max(0, spans.length - room)).concat(buffered);
  } catch { /* never throw */ }
}

const ENTRY_FLUSH_DEBOUNCE_MS = 250;
let entryFlushTimer = 0;

/** Flush SOON, coalescing every trace entry that ends in one burst. */
export function scheduleEntryFlush(): void {
  try {
    if (typeof window === 'undefined' || entryFlushTimer) return;
    entryFlushTimer = window.setTimeout(() => {
      entryFlushTimer = 0;
      flushSpans();
    }, ENTRY_FLUSH_DEBOUNCE_MS);
  } catch { entryFlushTimer = 0; /* the sink's interval is still the backstop */ }
}

/** Test seam. Called by `trace.ts`'s `__resetTracer`, so a test that resets the
 *  tracer does not have to know this module exists. */
export function __resetSpanBuffer(): void {
  buffered = [];
  enabled = false;
  emit = () => {};
  if (entryFlushTimer && typeof window !== 'undefined') window.clearTimeout(entryFlushTimer);
  entryFlushTimer = 0;
}

/** Test seam: what is buffered but not yet sent. */
export function __bufferedSpans(): WireSpan[] { return [...buffered]; }

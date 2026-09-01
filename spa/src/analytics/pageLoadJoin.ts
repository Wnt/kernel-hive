// ============================================================================
//  analytics/pageLoadJoin — the tab's half of the page-load hop.
//  ---------------------------------------------------------------------------
//  Split out of trace.ts on 2026-09-01. Not cosmetic: trace.ts had been sitting
//  one line under the 600-line hard cap for weeks, so every real change to the
//  tracer was being paid for by shaving prose off an unrelated comment — which
//  is how a file stops explaining itself. This is the one genuinely separable
//  concern in it (a parsed header and two counters; it calls nothing in the
//  tracer, and the tracer asks it exactly one question), so it is the split
//  that buys the most headroom for the least seam.
//
//  WHAT IT IS. The server names a real `serve.page` span in
//  `<meta name="traceparent">` when it serves index.html
//  (scripts/serve/static_files.py), minted before any JS on the page has run.
//  Without reading it, every trace this tab opens is unrelated to that span —
//  a disconnected forest for one visit, which is the thing tracing exists to
//  stop doing.
//
//  IT IS A SHARED ROOT, NOT A ONE-SHOT SEED. That was the original design and
//  it shipped a real bug: `khFetch.ts`'s implicit `childOfActive()` fallback
//  also opens a trace for any fetch with no active parent — the manifest,
//  `/auth/state`, the signalling document — and in real traffic one of those
//  routinely won the race against the visit's actual main flow. Evidence from
//  the live store: a `serve.page` trace containing `serve.auth.walkin.status`
//  (an incidental boot fetch that happened to go first) while
//  `station.connect` — the flow the join was built for — showed up as an
//  unrelated singleton. So MULTIPLE early callers hang off it as siblings,
//  bounded two ways so a station opened long after boot does not attach to a
//  stale page load and a runaway caller cannot grow the trace without limit.
//
//  THE CONSEQUENCE THE TRACER HAS TO KNOW ABOUT: while this join is live, a
//  trace ENTRY is not a ROOT — it carries `serve.page`'s span id as its
//  parent. `trace.ts`'s eager flush keys on the entry, not on parentlessness,
//  because keying on parentlessness missed the entire boot burst (see that
//  file's `end()`).
// ============================================================================

/** The `serve.page` span every early trace in this tab hangs off, and the
 *  wall-clock deadline past which a new trace stops joining it. `Date.now()`
 *  and not `performance.now()` on purpose: this bounds the visit's own boot
 *  burst, it is not a latency measurement. */
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

/** The parent a new trace should join, or null once this page load's window
 *  or count bound has passed — at which point `startTrace()` mints a fresh,
 *  unrelated trace id exactly as it always did for a second, later flow in
 *  the same tab (a retry, a second station opened minutes later).
 *
 *  CONSUMES a join slot, so it is called once per trace and only by
 *  `startTrace()`. */
export function pageLoadParent(): { traceId: string; spanId: string } | null {
  if (!pageLoadSeed || pageLoadJoins >= PAGE_LOAD_JOIN_MAX || Date.now() > pageLoadSeed.deadline) return null;
  pageLoadJoins += 1;
  return { traceId: pageLoadSeed.traceId, spanId: pageLoadSeed.spanId };
}

/** Test seam. Called by `trace.ts`'s `__resetTracer`, so a test that resets
 *  the tracer does not have to know this module exists. */
export function __resetPageLoadJoin(): void {
  pageLoadSeed = null;
  pageLoadJoins = 0;
}

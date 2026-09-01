// ============================================================================
//  analytics/pageLoadLink — the page load every action in this tab points BACK
//  at, without being nested under it.
//  ---------------------------------------------------------------------------
//  WHAT THE SERVER GIVES US. Serving `index.html`, `scripts/serve/
//  static_files.py` mints a real `serve.page` span — recorded in the same
//  store as everything else, not a prop — and splices its context into
//  `<meta name="traceparent">` in the bytes on the wire. That happens before a
//  byte of this bundle has run, so it is the only handle a tab has on the
//  request that produced it.
//
//  WHAT WE DO WITH IT, AND WHAT CHANGED ON 2026-09-01.
//
//  This module used to make that span the PARENT of the first traces the tab
//  opened, inside a 15-second window (it was called `pageLoadJoin`). It worked,
//  and it produced the thing this whole change exists to stop: a trace that
//  means "a visit". One captured on win311 held 43 spans from three producers,
//  spanned 15.7 s of wall clock, and was still taking writes 74 s after it
//  started — with five separate keystrokes sitting as SIBLINGS under the page
//  span, seconds apart. Instana assembles a trace in about two seconds, so a
//  trace that dribbles for 74 s is fragmented by construction, and every
//  consumer that reads a trace as a unit of work reads that one wrong.
//
//  Worse, the window made the shape NON-DETERMINISTIC. Reproduced live on the
//  gallery in one tab in one minute: eight sampled key edges inside the window
//  came out as children of `serve.page`, and eight click edges 15 s later came
//  out as their own roots. Two shapes for one thing, decided by a stopwatch —
//  and every downstream reader (the orphan report, `/admin/observability`,
//  Instana's endpoint mapping) had to cope with both.
//
//  **A TRACE IS NOW ONE ACTION.** One input edge, one `station.connect`, one
//  `station.restore`, one page load. Each is its own root. The relation to the
//  page load is still real and still recorded — it is just drawn as what it is:
//
//    * an OTel SPAN LINK on the trace's entry span, naming `serve.page`'s
//      trace and span. This is OpenTelemetry's own spelling of "caused by,
//      not nested under", and Instana surfaces links in the call Details view
//      (instana-docs/0307-opentelemetry-signals.md, "OpenTelemetry span events
//      and span links");
//    * the `kh.page.loadId` ATTRIBUTE (`pageBinding.ts`), already minted per
//      document.
//
//  BOTH, deliberately, and this is not belt-and-braces. A link is what a UI
//  NAVIGATES — one click from a slow keystroke to the page load it happened on
//  — and it cannot be filtered or grouped by. An attribute is what a QUERY
//  GROUPS BY — "every action on this page load", one equality filter, in our
//  own SQL and in Instana's Unbounded Analytics — and it cannot be navigated.
//  Neither substitutes for the other, and the link also survives a consumer
//  that has never heard of `kh.` anything.
//
//  NO WINDOW, NO COUNT, NO CONSUMPTION. The old bounds existed because a JOIN
//  makes a claim about causality and containment that goes stale: a station
//  opened ten minutes after boot did not happen "inside" the page load. A LINK
//  makes only the claim that is true for the whole life of the JS realm — this
//  action happened on that document — so it needs no expiry. A full navigation
//  tears the realm down and the next load reads a fresh tag.
// ============================================================================

/** The `serve.page` span this document was served with, or null when the tag
 *  was missing or malformed. Stable for the life of the JS realm. */
let pageLoadSpan: { traceId: string; spanId: string } | null = null;

const TRACEPARENT_RE = /^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$/i;

/** Parse a `traceparent` value per the contract's §1; null for anything that is
 *  not exactly that shape. Exported so the meta-tag reader and tests share one
 *  parser rather than two regexes drifting apart. */
export function parseTraceparent(
  value: string | null | undefined,
): { traceId: string; spanId: string } | null {
  if (!value) return null;
  const m = TRACEPARENT_RE.exec(value.trim());
  if (!m) return null;
  return { traceId: m[1].toLowerCase(), spanId: m[2].toLowerCase() };
}

/** Seed directly from a `traceparent` value. Exported for tests;
 *  `readPageLoadTraceFromMeta` is what boot code actually calls. A malformed or
 *  missing value clears it — the same "malformed → start a new trace, never
 *  refuse the work" rule as everywhere else in this plane. */
export function seedPageLoadTrace(traceparent: string | null | undefined): void {
  pageLoadSpan = parseTraceparent(traceparent);
}

/**
 * Read `<meta name="traceparent">` and remember the page load's span. Called
 * once from main.tsx, early — before the first flow opens. Safe with no DOM
 * (tests, SSR-shaped tooling) and safe with no tag at all (a build with tracing
 * unbound, a dev server that never went through `static_files.py`, a stale
 * cached document): both leave it unset, and every trace then simply carries no
 * link, exactly as it did before this existed.
 */
export function readPageLoadTraceFromMeta(): void {
  try {
    if (typeof document === 'undefined') return;
    const el = document.querySelector('meta[name="traceparent"]');
    seedPageLoadTrace(el?.getAttribute('content'));
  } catch {
    pageLoadSpan = null;
  }
}

/** The span to LINK a new trace's entry to, or null when this document has no
 *  page-load context. Never consumed and never expires — see the header. */
export function pageLoadLink(): { traceId: string; spanId: string } | null {
  return pageLoadSpan;
}

/** Test seam. Called by `trace.ts`'s `__resetTracer`, so a test that resets the
 *  tracer does not have to know this module exists. */
export function __resetPageLoadLink(): void {
  pageLoadSpan = null;
}

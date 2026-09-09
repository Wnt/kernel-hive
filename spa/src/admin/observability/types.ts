// ============================================================================
//  admin/observability/types — the shapes the observability UI is built on.
//  ---------------------------------------------------------------------------
//  Mirrors what `scripts/serve/traces.py` and `scripts/serve/analytics.py`
//  actually return. Written down once, here, because three separate views read
//  the same documents and a second opinion about a field name is a bug that
//  only shows up with real data in front of an operator.
//
//  These are DESCRIPTIONS of a server contract, not a schema the server reads.
//  If they drift, the server is right and this file is wrong.
// ============================================================================

/** Who produced the telemetry. `probe` is this lab's own browser automation,
 *  which would otherwise dominate every number (docs/ANALYTICS.md §4).
 *
 *  `server` is the serving plane's own branch probes. A trace never has it —
 *  only a browser produces spans — but `/analytics/report.json?class=server` is
 *  real and `reach-report.py --class server` uses it, so a UI reading that
 *  document needs the class to exist in the type. A view that cannot render it
 *  should decline it explicitly rather than be unable to name it. */
export type ClientClass = 'human' | 'probe' | 'unknown' | 'server';

/** OTel status. `unset` is a span that ended without an opinion — which is the
 *  common case, and is NOT the same as success. */
export type SpanStatus = 'unset' | 'ok' | 'error';

type SpanKind = 'internal' | 'client' | 'server' | 'producer' | 'consumer';

type AttrValue = string | number | boolean;

/** One OTel span event. `exception` is the one that matters most: it is how an
 *  error is attached to the span it happened inside. */
export interface SpanEvent {
  n: string;
  /** ms since epoch. */
  t: number;
  a?: Record<string, AttrValue>;
}

/** One OTel span LINK: "caused by, but not nested under". Since 2026-09-01 a
 *  trace here means ONE ACTION, so an input edge is no longer a child of the
 *  page load it happened on — the causal edge is drawn with a link, and the
 *  same fact ALSO rides as the `kh.page.loadId` attribute (a link is what this
 *  view NAVIGATES, an attribute is what a query GROUPS BY). */
interface SpanLink {
  t: string;
  s: string;
  a?: Record<string, AttrValue>;
}

/** One span of a trace, as `GET /auth/traces/trace` returns it. */
export interface TraceSpan {
  spanId: string;
  parentId: string | null;
  name: string;
  kind: SpanKind;
  startedMs: number;
  durMs: number;
  /** How much of `durMs` the tab was HIDDEN for. Not an OTel concept; kept
   *  because a flame graph must show real elapsed time while the metric
   *  aggregates count only visible time, and neither can be derived from the
   *  other after the fact. */
  hiddenMs: number;
  status: SpanStatus;
  statusMessage: string | null;
  attributes: Record<string, AttrValue>;
  events: SpanEvent[];
  /** Absent on a span stored before links existed, and on every span that is
   *  not a trace entry — the link rides the entry only, one copy per trace. */
  links?: SpanLink[];
}

/** A trace's summary row — what the list shows without touching the spans. */
export interface TraceSummary {
  traceId: string;
  sessionId: string;
  class: ClientClass;
  /** The root span's name: the journey this trace is of. */
  name: string;
  startedMs: number;
  durMs: number;
  spanCount: number;
  errorCount: number;
  status: SpanStatus;
  /** Which BUNDLE the client was running — `<branch>@<short-sha>`, off the
   *  batch's resource envelope, or `unknown` for a trace recorded before the
   *  column existed / contributed only by the serving plane. This is how "was
   *  that client on the shell we think we deployed?" is answered without a
   *  vendor beacon; see docs/ANALYTICS.md. */
  build: string;
}

/** One trace with every span — what the flame graph renders. */
export type TraceDetail = TraceSummary & { spans: TraceSpan[] };

export interface TraceSearchResult {
  traces: TraceSummary[];
  total: number;
  limit: number;
  offset: number;
}

/** Every filter the trace search accepts. All optional, all ANDed. */
export interface TraceFilters {
  session?: string;
  name?: string;
  /** Exact bundle id, e.g. `main@3e6c81c4`. */
  build?: string;
  class?: ClientClass;
  status?: SpanStatus;
  errorsOnly?: boolean;
  sinceMs?: number;
  untilMs?: number;
  minDurMs?: number;
  limit?: number;
  offset?: number;
}

/** Distinct values the filter UI offers, with counts. Driven by the DATA, not
 *  the catalogue: a journey that stopped being emitted should drop out of the
 *  filter, and one nobody declared appearing is worth noticing. */
export interface TraceFacets {
  names: Array<{ value: string; n: number }>;
  classes: Array<{ value: string; n: number }>;
  statuses: Array<{ value: string; n: number }>;
  /** Which BUNDLES the window's clients were running. Two live builds at once
   *  means somebody is still on a shell the box no longer serves. */
  builds: Array<{ value: string; n: number }>;
}

// ---- the aggregate side ----------------------------------------------------

/** `GET /analytics/report.json`. Counts by name; metrics by bucket EDGE. */
export interface AnalyticsReport {
  window: { days: number; since: string; class: string };
  lastAt: string | null;
  probes: Record<string, Partial<Record<'auto' | 'show' | 'act', number>>>;
  flows: Record<string, Record<string, Partial<Record<'enter' | 'ok' | 'fail', number>>>>;
  metrics: Record<string, Record<string, number>>;
  errors: Array<{
    fp: string;
    flow: string;
    step: string;
    source: string;
    n: number;
    message: string;
  }>;
}

/** `registry/analytics-catalogue.json` — the DENOMINATOR. The report only
 *  contains what was reached; the catalogue is what could have been, which is
 *  the whole reason a zero in this system means something. */
export interface Catalogue {
  probes: Record<string, {
    area: string; owner: string; what: string;
    grades: string[]; consumes?: string;
  }>;
  flows: Record<string, { area: string; what: string; steps: string[] }>;
  metrics: Record<string, {
    area: string; owner: string; what: string;
    scale: 'ms' | 'count' | 'pct'; countsHiddenTime?: boolean;
  }>;
  serverProbes?: Record<string, { area: string; owner: string; what: string; consumes?: string }>;
}

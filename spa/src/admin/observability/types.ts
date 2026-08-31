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
 *  which would otherwise dominate every number (docs/ANALYTICS.md §4). */
export type ClientClass = 'human' | 'probe' | 'unknown';

/** OTel status. `unset` is a span that ended without an opinion — which is the
 *  common case, and is NOT the same as success. */
export type SpanStatus = 'unset' | 'ok' | 'error';

export type SpanKind = 'internal' | 'client' | 'server' | 'producer' | 'consumer';

export type AttrValue = string | number | boolean;

/** One OTel span event. `exception` is the one that matters most: it is how an
 *  error is attached to the span it happened inside. */
export interface SpanEvent {
  n: string;
  /** ms since epoch. */
  t: number;
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

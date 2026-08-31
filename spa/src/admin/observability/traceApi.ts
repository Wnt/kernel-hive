// ============================================================================
//  admin/observability/traceApi — the data layer for /auth/traces/*.
//  ---------------------------------------------------------------------------
//  Same idiom as admin/walkinAdminApi.ts: same-origin session cookie, JSON in,
//  JSON out, the server's own error text surfaced verbatim. Three things are
//  specific to this lane and worth stating here rather than at each call site.
//
//  1. EVERY ROUTE IS A POST. `auth/routes.py` answers non-POST /auth/* with 405
//     and requires an `Origin` header matching the gallery's own, which the
//     browser attaches to a same-origin POST for us. A GET would be simpler and
//     would not work.
//
//  2. A REFUSAL IS NOT AN EMPTY LIST. The trace routes sit below the admin role
//     check in `auth/routes.py`, so a viewer gets 403 and a signed-out tab gets
//     401. Both would render as "no traces" if the caller only looked at the
//     rows, and "there is nothing here" and "you may not see what is here" are
//     opposite facts. They are carried as a status on TraceApiError and turned
//     into their own UI state in useTraces.ts.
//
//  3. 503 IS A THIRD FACT AGAIN. `bind_traces` was never called — the store
//     failed to open, or this build serves no tracing. Deliberately not a 404
//     (see that function's docstring), and deliberately not merged into "error"
//     here: it is the difference between "tracing is off" and "the query broke".
// ============================================================================

import type { TraceDetail, TraceFacets, TraceFilters, TraceSearchResult } from './types';
import { toWireFilters } from './traceFilters';

// Not exported: nothing outside this module needs the class, and the two
// questions callers actually ask — "was that a refusal?", "is tracing off?" —
// are the predicates below. (An export nothing imports also fails `npx knip`.)
class TraceApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'TraceApiError';
    this.status = status;
  }
}

/** True for the two statuses that mean "you are not an admin here". 401 is
 *  "sign in", 403 is "signed in, wrong role"; the panel says both the same way
 *  because the operator's next move is identical. */
export function isForbidden(error: unknown): boolean {
  return error instanceof TraceApiError && (error.status === 401 || error.status === 403);
}

/** True when the trace store is not bound — tracing off, not tracing broken. */
export function isUnavailable(error: unknown): boolean {
  return error instanceof TraceApiError && error.status === 503;
}

async function call<T>(leaf: string, body: unknown): Promise<T> {
  const response = await fetch(`/auth/traces/${leaf}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    credentials: 'same-origin',
    cache: 'no-store',
  });
  let data: unknown = {};
  try {
    data = await response.json();
  } catch {
    // A body-less error is still an error; a body-less 200 is a broken route.
  }
  if (!response.ok) {
    const message =
      typeof data === 'object' && data !== null && 'error' in data
        && typeof (data as { error: unknown }).error === 'string'
        ? (data as { error: string }).error
        : `request failed (${response.status})`;
    throw new TraceApiError(message, response.status);
  }
  return data as T;
}

// The dev and staging servers answer an unimplemented route with the SPA shell
// (200, text/html) rather than a 404 — likely until these routes are deployed.
// So the shape is checked rather than `response.ok` trusted: a stray HTML page
// must surface as "that did not look like a trace search", never as a table of
// undefined three renders downstream.
function isSearchResult(v: unknown): v is TraceSearchResult {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return Array.isArray(r.traces) && typeof r.total === 'number' && typeof r.limit === 'number';
}

function isFacets(v: unknown): v is TraceFacets {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return Array.isArray(r.names) && Array.isArray(r.classes) && Array.isArray(r.statuses);
}

export async function searchTraces(filters: TraceFilters): Promise<TraceSearchResult> {
  const data = await call<unknown>('search', toWireFilters(filters));
  if (!isSearchResult(data)) {
    throw new TraceApiError('/auth/traces/search did not return a trace list — route not deployed?', 0);
  }
  return data;
}

/** Distinct filter values with counts.
 *
 *  `sinceMs` defaults to 1, not 0: `auth/routes.py` reads it as
 *  `_int(...) or <7 days ago>`, so a zero is falsy and would silently become a
 *  seven-day window. 1 ms after the epoch means "everything the store has",
 *  which is what the filter bar wants — the offered values should be every
 *  value that EXISTS, and a journey that ran nine days ago still exists. */
export async function fetchFacets(sinceMs = 1): Promise<TraceFacets> {
  const data = await call<unknown>('facets', { sinceMs });
  if (!isFacets(data)) {
    throw new TraceApiError('/auth/traces/facets did not return facets — route not deployed?', 0);
  }
  return data;
}

export function fetchTrace(traceId: string): Promise<TraceDetail> {
  return call<TraceDetail>('trace', { id: traceId });
}

/** The export boundary, and the answer to "can I take this elsewhere".
 *
 *  `/auth/traces/otlp` runs the SAME search this list runs and renders the
 *  matches as OTLP/JSON, so what leaves the box is exactly the slice on screen.
 *  Two limits, stated here because they are invisible in the file: the server
 *  caps the export at 200 traces (`_trace_route`), and it exports the FILTERED
 *  set, not the page — paging is a view, the export is the query. */
export const OTLP_EXPORT_CAP = 200;

export async function exportOtlp(filters: TraceFilters): Promise<{ bytes: number; filename: string }> {
  const doc = await call<unknown>('otlp', { ...toWireFilters(filters), offset: 0, limit: OTLP_EXPORT_CAP });
  const text = JSON.stringify(doc, null, 2);
  const filename = `kh-traces-${new Date().toISOString().replace(/[:.]/g, '-')}.otlp.json`;
  // Object URL rather than a data: URL — an export of 200 traces is comfortably
  // past the length some browsers will follow in an href.
  const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  try {
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
  } finally {
    // Revoked on the next tick: the click is synchronous but the fetch of the
    // blob is not, and revoking in the same statement cancels the download.
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
  return { bytes: text.length, filename };
}

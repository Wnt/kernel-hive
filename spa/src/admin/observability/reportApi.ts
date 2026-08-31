// ============================================================================
//  observability/reportApi — getting the two documents the dashboards join.
//  ---------------------------------------------------------------------------
//  The AGGREGATE half of this UI is a LEFT JOIN, exactly as
//  `scripts/dev/reach-report.py` is: the catalogue is the denominator and the
//  report is what production actually said. Two documents, fetched apart,
//  because they come from opposite places and fail in opposite ways.
//
//  THE REPORT is per-window and per-class and comes off the box
//  (`GET /analytics/report.json`, served by scripts/serve/analytics.py). The
//  server deliberately does NOT join the catalogue in — it has no business
//  reading the SPA's source of truth — so a probe that reported nothing is
//  simply ABSENT from the document. Reading the report alone would therefore
//  produce a popularity list, never the "nobody has ever used this" answer the
//  plane exists for.
//
//  THE CATALOGUE is not fetched at all, and that is the deliberate part.
//  `registry/analytics-catalogue.json` is a GENERATED artefact (see its header)
//  rendered from `spa/src/analytics/catalogue/` plus `scripts/serve/probes.py`,
//  byte-parity gated by `make analytics-catalogue-check`. The tab already has
//  the first of those two sources compiled into it, so importing it is the same
//  document by construction — with no route to add, no second copy to drift,
//  and no failure mode where the dashboard renders a denominator from a stale
//  file the box happens to be serving. What that costs is the SERVER branch
//  probes (`serverProbes`, declared in Python, class=`server`): they are not in
//  the bundle and this UI does not claim to cover them. `reach-report.py
//  --class server` is still the tool for that table.
// ============================================================================

import { FLOWS, METRICS, PROBES } from '../../analytics/catalogue';
import type { FlowSpec, MetricSpec, ProbeSpec } from '../../analytics/catalogue/types';
import type { AnalyticsReport, Catalogue, ClientClass } from './types';

/** The classes this UI offers. `server` is deliberately NOT here even though
 *  `/analytics/report.json?class=server` is a real window and `reach-report.py`
 *  has a `--class server` view: those rows are the Python serving plane's own
 *  BRANCH probes, declared in `scripts/serve/probes.py`, and nothing declaring
 *  them is in this bundle. Offering the class would render a window whose
 *  denominator this UI does not have — every row a zero, none of them true.
 *
 *  `human` is the default everywhere, for the reason in docs/ANALYTICS.md §4:
 *  this lab drives its own SPA with a fleet of browser probes, and on a
 *  63-station private gallery they would be the MAJORITY of traffic. Every view
 *  must therefore state which class it is showing. */
export const CLIENT_CLASSES: readonly ClientClass[] = ['human', 'probe', 'unknown'];

/** The catalogue the tab was BUILT with. Synchronous on purpose: a denominator
 *  that can fail to load is one that will quietly be replaced by an empty
 *  object on a bad day, and an empty denominator turns "nothing is
 *  instrumented" into "everything is fine".
 *
 *  `serverProbes` is left unset — see CLIENT_CLASSES. The three tables that are
 *  set are the same ones `registry/analytics-catalogue.json` is GENERATED from
 *  (`scripts/analytics/catalogue.mjs`, byte-parity gated by
 *  `make analytics-catalogue-check`), so this is that document by construction:
 *  no route to add, no second copy to drift, and no failure mode where the
 *  dashboard reports against a denominator the box happens to be serving from
 *  an older build than the bundle. */
export function loadCatalogue(): Catalogue {
  const probes = Object.entries(PROBES as Record<string, ProbeSpec>);
  const flows = Object.entries(FLOWS as Record<string, FlowSpec>);
  const metrics = Object.entries(METRICS as Record<string, MetricSpec>);
  return {
    probes: Object.fromEntries(probes.map(([id, s]) => [id, {
      area: s.area, owner: s.owner, what: s.what, grades: [...s.grades], consumes: s.consumes,
    }])),
    flows: Object.fromEntries(flows.map(([id, s]) => [id, {
      area: s.area, what: s.what, steps: [...s.steps],
    }])),
    metrics: Object.fromEntries(metrics.map(([id, s]) => [id, {
      area: s.area, owner: s.owner, what: s.what, scale: s.scale,
      countsHiddenTime: s.countsHiddenTime,
    }])),
  };
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Validate the SHAPE, not `response.ok`. The dev and staging servers answer an
 *  unimplemented route with the SPA shell (200, text/html); trusting the status
 *  would surface three renders later as an all-undefined report drawn as a
 *  screenful of confident zeros. Same reasoning as walkinAdminApi.ts's
 *  `isWalkinAdminStatus`, and it matters more here: a zero is this system's
 *  most load-bearing output. */
function isReport(v: unknown): v is AnalyticsReport {
  if (!isRecord(v) || !isRecord(v.window)) return false;
  const w = v.window;
  return (
    typeof w.days === 'number'
    && typeof w.class === 'string'
    && isRecord(v.probes)
    && isRecord(v.flows)
    && isRecord(v.metrics)
    && Array.isArray(v.errors)
  );
}

class ReportError extends Error {}

/**
 * Fetch one window of one class.
 *
 * Both arguments are required rather than defaulted here: the class in
 * particular must be a decision the caller made and can display, never one this
 * module quietly picked. The store's own default is `human` — a fetch layer
 * that supplied it invisibly is exactly how a `probe` window ends up on screen
 * labelled as visitors.
 */
export async function fetchReport(days: number, klass: ClientClass): Promise<AnalyticsReport> {
  const query = `days=${encodeURIComponent(String(days))}&class=${encodeURIComponent(klass)}`;
  let response: Response;
  try {
    response = await fetch(`/analytics/report.json?${query}`, {
      credentials: 'same-origin',
      cache: 'no-store',
    });
  } catch (cause) {
    throw new ReportError(`could not reach /analytics/report.json (${String(cause)})`);
  }
  if (!response.ok) throw new ReportError(`/analytics/report.json answered ${response.status}`);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new ReportError('/analytics/report.json did not answer JSON — is the route deployed?');
  }
  if (!isReport(body)) throw new ReportError('/analytics/report.json answered an unrecognised shape');
  return body;
}

// ============================================================================
//  observability/reportMath — the joins and the percentiles, as pure functions.
//  ---------------------------------------------------------------------------
//  This is the browser port of `scripts/dev/reach-report.py`, and it is pure so
//  that the numbers can be TESTED rather than eyeballed in a screenshot. Every
//  function here is a candidate for being quoted in a decision — "nobody has
//  opened this in a year, delete it" — so the semantics deliberately match the
//  reference tool rather than being re-derived. Where they differ, the comment
//  beside them says so and why.
//
//  THE ONE RULE THAT GOVERNS ALL OF IT: a zero must be a statement, never a
//  gap. That is why every table below is a LEFT JOIN from the catalogue rather
//  than a walk of the report — a probe nobody reached is ABSENT from the
//  report, and a UI built on the report alone is a popularity list that can
//  never answer the question this plane exists for. See the catalogue's own
//  header (src/analytics/catalogue/index.ts).
// ============================================================================

import type { AnalyticsReport, Catalogue } from './types';

// ---- percentiles over buckets ----------------------------------------------

/** A percentile answer: the bucket EDGE, and how many samples were behind it.
 *  `edge` is `'-'` for an empty distribution and `'inf'` for the overflow
 *  bucket; both are rendered by `formatEdge`, never printed raw. */
export interface Percentile {
  readonly edge: string;
  readonly n: number;
}

/**
 * The bucket edge at percentile `p`, and the total sample count.
 *
 * Returned as an EDGE, and rendered as "<= edge", because that is the entire
 * truth the data holds: the tab bucketed the value before sending it
 * (src/analytics/metrics.ts), deliberately, so that a durable years-long
 * aggregate never becomes a behavioural trace of one visitor's session. A UI
 * that interpolated inside a bucket to print `p95 = 2847ms` would be inventing
 * three digits nobody measured — and, being a UI, would be believed.
 *
 * Ported line for line from `reach-report.py`'s `percentile`, including the
 * `seen >= total * p` boundary, so the dashboard and the CLI cannot disagree
 * about the same store.
 */
export function percentile(buckets: Readonly<Record<string, number>>, p: number): Percentile {
  const entries = Object.entries(buckets);
  const total = entries.reduce((sum, [, n]) => sum + n, 0);
  if (!total) return { edge: '-', n: 0 };
  // `inf` MUST sort last. Sorted as text it lands between "100" and "50", and a
  // p95 would then read as FASTER than a p50 — a wrong number that looks like
  // good news. There is a Python test for exactly this and one below.
  const edges = entries
    .map(([edge]) => edge)
    .sort((a, b) => edgeValue(a) - edgeValue(b));
  const want = total * p;
  let seen = 0;
  for (const edge of edges) {
    seen += buckets[edge];
    if (seen >= want) return { edge, n: total };
  }
  return { edge: edges[edges.length - 1], n: total };
}

function edgeValue(edge: string): number {
  if (edge === 'inf') return Number.POSITIVE_INFINITY;
  const n = Number(edge);
  // A bucket name that is not a number and not `inf` cannot be placed on the
  // ladder. Sorting it FIRST would make it look like the fastest samples in the
  // distribution; last is the safe direction — beside `inf`, visibly odd.
  return Number.isFinite(n) ? n : Number.POSITIVE_INFINITY;
}

/** A bucket edge in the unit a reader thinks in. Matches `fmt_edge`. */
export function formatEdge(edge: string, scale: 'ms' | 'count' | 'pct'): string {
  if (edge === '-') return '-';
  if (edge === 'inf') return 'over max';
  if (scale === 'ms') {
    const n = Number(edge);
    return n >= 1000 ? `${(n / 1000).toFixed(1)}s` : `${n}ms`;
  }
  return scale === 'pct' ? `${edge}%` : edge;
}

// ---- how much of the report is real at all ---------------------------------

/**
 * Whether a zero on this report is a FINDING or an absence of evidence.
 *
 * `never reached` is not `unreachable`, and neither is `nothing has ever posted
 * to this store`. A dashboard that drew all three the same way would let
 * somebody delete a live feature on the strength of a box that had never had
 * the route deployed. Every view asks this before it uses the word "never".
 *
 * - `no-store`   — the store has never accepted a batch, ever (`lastAt` null).
 * - `empty-window` — batches exist, but this window and class hold nothing.
 * - `ok`         — there is data; a zero row means what it says.
 */
export type DataState = 'no-store' | 'empty-window' | 'ok';

export function dataState(report: AnalyticsReport): DataState {
  if (!report.lastAt) return 'no-store';
  const empty =
    Object.keys(report.probes).length === 0
    && Object.keys(report.flows).length === 0
    && Object.keys(report.metrics).length === 0
    && report.errors.length === 0;
  return empty ? 'empty-window' : 'ok';
}

// ---- feature reach ---------------------------------------------------------

export interface ReachRow {
  readonly probe: string;
  readonly area: string;
  readonly owner: string;
  readonly what: string;
  readonly auto: number;
  readonly show: number;
  readonly act: number;
  /** Every grade summed, including any the catalogue does not declare — the
   *  store keeps what it was sent and a row that only shows the three declared
   *  columns could total less than it reports. */
  readonly total: number;
  readonly consumes?: string;
  readonly reached: boolean;
}

/**
 * One row per DECLARED probe, in id order, whether or not it reported.
 *
 * DELIBERATE DIFFERENCE from `reach-report.py`: no `cov%` / `line%` columns and
 * so no HEALTHY / PAYING TWICE / EXPOSED / DEAD verdict. Those quadrants cross
 * production reach with vitest's `coverage-final.json` and the instrumented
 * bundle's line map — two artefacts that live on a workstation and on
 * `coverage.db`, neither of which a tab can read. Rendering a quadrant from one
 * axis would be the exact collapse the reference tool refuses to make. What is
 * left is the reach axis, honestly labelled as one axis.
 */
export function reachRows(catalogue: Catalogue, report: AnalyticsReport): ReachRow[] {
  return Object.keys(catalogue.probes).sort().map((probe) => {
    const spec = catalogue.probes[probe];
    const grades: Record<string, number> = report.probes[probe] ?? {};
    const total = Object.values(grades).reduce((sum, n) => sum + n, 0);
    return {
      probe,
      area: spec.area,
      owner: spec.owner,
      what: spec.what,
      auto: grades.auto ?? 0,
      show: grades.show ?? 0,
      act: grades.act ?? 0,
      total,
      consumes: spec.consumes,
      reached: total > 0,
    };
  });
}

export interface PairRow {
  /** The `auto` producer — the call that runs whether anybody asked or not. */
  readonly producer: string;
  /** The probe that declared it CONSUMES the producer's answer. */
  readonly consumer: string;
  /** The producer's `auto` count. Not its total: a producer that also reports a
   *  `show` is not being "called" that many more times. */
  readonly calls: number;
  /** show + act on the consumer — the answer being put in front of somebody, or
   *  operated. */
  readonly used: number;
  /** `null`, not 0, when the producer never ran: nothing over nothing is not a
   *  ratio and printing `0.0%` would read as "used by nobody" when the truth is
   *  "not called either". */
  readonly pct: number | null;
}

/** The auto-vs-act pairs — "is this request earning its answer?". */
export function pairRows(rows: readonly ReachRow[]): PairRow[] {
  const byId = new Map(rows.map((r) => [r.probe, r]));
  return rows
    .filter((r) => r.consumes)
    .map((r) => {
      const producer = byId.get(r.consumes as string);
      const calls = producer ? producer.auto : 0;
      const used = r.show + r.act;
      return {
        producer: r.consumes as string,
        consumer: r.probe,
        calls,
        used,
        pct: calls ? (100 * used) / calls : null,
      };
    });
}

// ---- flow funnels ----------------------------------------------------------

// Not exported: named only as fields of FunnelRow. An export nothing imports
// fails `npx knip`, and widening the surface to satisfy a linter is how a
// module acquires an API nobody asked for.
interface FunnelStep {
  readonly step: string;
  readonly entered: number;
  readonly ok: number;
  /** Failures reported ON this step. A `fail()` with no reason token is stored
   *  under the step name (src/analytics/flows.ts), so this is where those land. */
  readonly failed: number;
  /** entered here minus entered at the next declared step. `null` on the last
   *  step, where there is no next to fall out of. */
  readonly lost: number | null;
}

interface FailReason {
  readonly reason: string;
  readonly n: number;
}

export interface FunnelRow {
  readonly flow: string;
  readonly area: string;
  readonly what: string;
  readonly steps: FunnelStep[];
  /** Failures stored under a REASON token rather than a declared step. Most
   *  descending. */
  readonly failReasons: FailReason[];
  readonly entered: number;
  readonly completed: number;
}

/**
 * One funnel per DECLARED flow, whether or not any attempt was made.
 *
 * Counts down the declared steps only ever decrease — steps are monotonic
 * (reporting step N implies 1..N-1), which is what makes this a funnel rather
 * than a bag of counters. The order is the catalogue's, never the report's.
 *
 * DELIBERATE DIFFERENCE from `reach-report.py`: that tool prints fail counts
 * only for keys OUTSIDE the declared step list, so a `fail()` called with no
 * reason token — which the client stores under the current STEP's name — is
 * invisible in its output. Those failures are real and are shown here, per
 * step, beside the drop-off. Named reasons are still broken out separately,
 * because "died at `transport`" and "died with reason `nopasskey`" are
 * different findings.
 */
export function funnelRows(catalogue: Catalogue, report: AnalyticsReport): FunnelRow[] {
  return Object.keys(catalogue.flows).sort().map((flow) => {
    const spec = catalogue.flows[flow];
    const observed = report.flows[flow] ?? {};
    const declared = spec.steps;
    const steps: FunnelStep[] = declared.map((step, i) => {
      const counts = observed[step] ?? {};
      const next = i + 1 < declared.length ? (observed[declared[i + 1]]?.enter ?? 0) : null;
      const entered = counts.enter ?? 0;
      return {
        step,
        entered,
        ok: counts.ok ?? 0,
        failed: counts.fail ?? 0,
        lost: next === null ? null : Math.max(0, entered - next),
      };
    });
    const declaredSet = new Set(declared);
    const failReasons = Object.entries(observed)
      .filter(([key, counts]) => !declaredSet.has(key) && (counts.fail ?? 0) > 0)
      .map(([reason, counts]) => ({ reason, n: counts.fail ?? 0 }))
      .sort((a, b) => b.n - a.n || a.reason.localeCompare(b.reason));
    return {
      flow,
      area: spec.area,
      what: spec.what,
      steps,
      failReasons,
      entered: steps.length ? steps[0].entered : 0,
      completed: steps.reduce((sum, s) => sum + s.ok, 0),
    };
  });
}

// ---- metrics ---------------------------------------------------------------

export interface MetricRow {
  readonly metric: string;
  readonly area: string;
  readonly owner: string;
  /** The catalogue's own sentence. Note that several are written "a LOW value
   *  means…" — render it verbatim rather than under a "high means" heading. */
  readonly what: string;
  readonly scale: 'ms' | 'count' | 'pct';
  readonly countsHiddenTime: boolean;
  readonly n: number;
  readonly p50: Percentile;
  readonly p75: Percentile;
  readonly p95: Percentile;
  /** True where the number observes what a pointer or a scroll container DID
   *  and is read as evidence about effort. See `isProxyMetric`. */
  readonly proxy: boolean;
}

/**
 * Metrics that are BEHAVIOURAL PROXIES, matched on the quantity in the id.
 *
 * docs/ANALYTICS.md §5.2 is unusually firm about this and the UI has to be too:
 * hesitation before a first action, steps to a goal, backtracking, correction
 * rates and scroll oscillation observe what a pointer and a scroll container
 * did. A reversal is produced identically by a reader checking a date, a
 * trackpad that overshot, and a reader defeated by a sentence. None of them
 * measures attention, difficulty or cognitive load, and none ever will — they
 * are for COMPARISON and ranking, which is all that was asked of them.
 *
 * A pattern rather than a hand-kept id list so a metric added next to an
 * existing one inherits the badge. Its limit, stated beside it: a genuinely
 * new SHAPE of proxy will not match, so the caveat is also rendered once above
 * the whole table where no row can escape it.
 */
const PROXY_QUANTITY = /(Reversals|Corrections|Switches|Retries|Approached|hesitation|dwell|actionsTo|scrollDepth|hScroll|toFirst(Action|Key|Input|Station))/i;

export function isProxyMetric(id: string): boolean {
  return PROXY_QUANTITY.test(id);
}

/** One row per DECLARED metric, whether or not it recorded a sample. */
export function metricRows(catalogue: Catalogue, report: AnalyticsReport): MetricRow[] {
  return Object.keys(catalogue.metrics).sort().map((metric) => {
    const spec = catalogue.metrics[metric];
    const buckets = report.metrics[metric] ?? {};
    const p50 = percentile(buckets, 0.5);
    return {
      metric,
      area: spec.area,
      owner: spec.owner,
      what: spec.what,
      scale: spec.scale,
      countsHiddenTime: spec.countsHiddenTime === true,
      n: p50.n,
      p50,
      p75: percentile(buckets, 0.75),
      p95: percentile(buckets, 0.95),
      proxy: isProxyMetric(metric),
    };
  });
}

// ---- errors ----------------------------------------------------------------

export interface ErrorRow {
  readonly fp: string;
  /** `''` when the fault happened outside every flow — stored as the empty flow
   *  rather than dropped, because "faults nobody's flow owns" is itself a
   *  finding (scripts/serve/analytics.py `_fold_errors`). */
  readonly flow: string;
  readonly step: string;
  readonly source: string;
  readonly n: number;
  readonly message: string;
}

/**
 * Grouped faults, most frequent first.
 *
 * The store already groups by fingerprint and orders by count; this re-sorts
 * defensively so the view's promise ("most frequent first") does not depend on
 * an ORDER BY three layers away. No catalogue join: errors have no denominator
 * — nobody declares the faults they intend to have.
 */
export function errorRows(report: AnalyticsReport): ErrorRow[] {
  return [...report.errors]
    .map((e) => ({
      fp: e.fp,
      flow: e.flow ?? '',
      step: e.step ?? '',
      source: e.source ?? '',
      n: e.n,
      message: e.message,
    }))
    .sort((a, b) => b.n - a.n || a.fp.localeCompare(b.fp));
}

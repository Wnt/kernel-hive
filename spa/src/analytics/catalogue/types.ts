// ============================================================================
//  analytics/catalogue/types — what a probe, a flow and a metric are.
//  ---------------------------------------------------------------------------
//  Split out from the catalogue itself so the per-AREA files can be edited
//  independently: a parallel wave of instrumentation work otherwise turns one
//  object literal into a merge conflict per agent, and the resolution of a
//  conflict in a catalogue is exactly where a probe silently loses its call
//  site. One file per area, one shared type module, no shared editing surface.
// ============================================================================

import type { Intent } from '../intent';

/** Grouping for the report. Keep this vocabulary small — it is the report's
 *  section list, not a tagging system. */
type Area =
  | 'app'
  | 'boot'
  | 'fleet'
  | 'hall'
  | 'keyboard'
  | 'poster'
  | 'station'
  | 'stream'
  | 'walkin';

/** One instrumented thing: it ran, and we care that it ran. */
export interface ProbeSpec {
  readonly area: Area;
  /** Source file (repo-relative from spa/) holding the call site. Gated. */
  readonly owner: string;
  /** "This fired, therefore we know that…" */
  readonly what: string;
  /** The grades this probe may legitimately report. A call site asking for a
   *  grade not listed here is a bug the type system cannot catch, so the
   *  runtime clamps it — see `reach`. */
  readonly grades: readonly Intent[];
  /** The `auto` probe whose data this one consumes, if any.
   *
   *  Typed `string`, not `ProbeId`: `ProbeId` is `keyof typeof PROBES` and
   *  PROBES is checked against this interface, so naming it here is a circular
   *  reference TypeScript refuses. The constraint is real and is enforced
   *  twice instead — `scripts/analytics/catalogue.mjs check` (a build gate) and
   *  a unit test — both of which also assert the target is an `auto` producer,
   *  which the type could not have said anyway. */
  readonly consumes?: string;
}

/** One named user flow: an ordered path we care about completing. */
export interface FlowSpec {
  readonly area: Area;
  readonly what: string;
  /** In order. A flow that reaches step N is assumed to have passed 1..N-1,
   *  so the report can render a funnel without every step being reported. */
  readonly steps: readonly string[];
}

/**
 * How a metric's values are bucketed. There is no fourth: a distribution whose
 * shape you have to guess is not a measurement, and inventing a bespoke ladder
 * per metric would make two metrics incomparable for no gain.
 */
export type Scale = 'ms' | 'count' | 'pct';

/** One measured DISTRIBUTION. Not a counter — see metrics.ts for why every
 *  value here is bucketed on the way out of the tab. */
export interface MetricSpec {
  readonly area: Area;
  /** Source file (repo-relative from spa/) holding the call site. Gated. */
  readonly owner: string;
  /** "A high value here means…" — the decision this number is for. A metric
   *  whose sentence you cannot finish is a number nobody will ever act on. */
  readonly what: string;
  readonly scale: Scale;
  /**
   * For a `ms` metric: does the clock keep running while the tab is HIDDEN?
   *
   * Almost always `false`, which is the honest default — a connect that took
   * four minutes because the visitor backgrounded the tab for three of them is
   * not a four-minute wait, and a distribution polluted with those is worse
   * than no distribution. Set `true` only where the away-time IS the quantity
   * (`session.resume.awayMs`).
   */
  readonly countsHiddenTime?: boolean;
}

/** Bucket edges, smallest first. A value lands in the first bucket whose edge
 *  is >= it; anything larger lands in the overflow bucket, `inf`.
 *
 *  Buckets are stored by their EDGE (as text), never by index. An index would
 *  silently re-point every historical row the first time somebody inserted a
 *  ladder step; an edge means an old row keeps meaning what it meant, and a
 *  changed ladder shows up as new bucket names beside the old ones instead of
 *  as a quietly rewritten history. */
const LADDERS: Record<Scale, readonly number[]> = {
  // Doubling from 50 ms — below that nobody perceives a difference, above
  // ~25 s a visitor has already decided the gallery is broken.
  ms: [50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600],
  // Doubling from 1. Effort counts (corrections, reversals, retries, steps)
  // are interesting at 1 vs 2 vs 5 and stop being interesting past a hundred.
  count: [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144],
  // Deciles. For depths and rates, where the question is "how far", not "how
  // many", and eleven buckets is already more resolution than the decision needs.
  pct: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
};

/** The bucket a value falls in, named by its edge. `inf` is the overflow. */
export function bucketFor(scale: Scale, value: number): string {
  const ladder = LADDERS[scale];
  for (const edge of ladder) {
    if (value <= edge) return String(edge);
  }
  return 'inf';
}

// ============================================================================
//  analytics/catalogue/app — the router itself: what page a visitor is on.
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
//
//  ONE OBSERVER. `src/analytics/navigation.ts` is a single router-level event,
//  computed once per transition, so a navigation is visible in
//  /admin/observability as an `app.page` span beside the probe and metric
//  below.
// ============================================================================

import type { MetricSpec, ProbeSpec } from './types.ts';

export const APP_PROBES = {
  'app.page.viewed': {
    area: 'app',
    owner: 'src/analytics/navigation.ts',
    what: 'a route transition committed — the visitor is now looking at a different page',
    grades: ['auto'],
  },
} as const satisfies Record<string, ProbeSpec>;

export const APP_METRICS = {
  // Route commit to next paint (a double requestAnimationFrame — the "two
  // frames" heuristic already used elsewhere to mean "the browser actually
  // painted this"). Measured by navigation.ts itself; the `app.page` span's
  // own duration is the same number.
  'app.page.transitionMs': {
    area: 'app',
    owner: 'src/analytics/navigation.ts',
    what: 'a high value means switching routes visibly hangs the app before the new view paints',
    scale: 'ms',
  },
} as const satisfies Record<string, MetricSpec>;

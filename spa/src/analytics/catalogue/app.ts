// ============================================================================
//  analytics/catalogue/app — the router itself: what page a visitor is on.
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
//
//  ONE OBSERVER, TWO CONSUMERS. `src/analytics/navigation.ts` is a single
//  router-level event, computed once per transition, fed to BOTH this
//  plane (so a navigation is visible in /admin/observability with Instana
//  entirely absent — a standing operator requirement) and to Instana
//  (`ineum('page', ...)`, replacing `autoPageDetection` — see navigation.ts's
//  header for why driving it ourselves and leaving Instana's own detector on
//  would double-count and disagree on naming).
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
  // painted this"). This is the number `autoPageDetection` would otherwise
  // have measured for us; see navigation.ts / instana.ts for why that vendor
  // feature is off and this plane measures it instead.
  'app.page.transitionMs': {
    area: 'app',
    owner: 'src/analytics/navigation.ts',
    what: 'a high value means switching routes visibly hangs the app before the new view paints',
    scale: 'ms',
  },
} as const satisfies Record<string, MetricSpec>;

// ============================================================================
//  analytics/navigation — one router-level event per page transition.
//  ---------------------------------------------------------------------------
//  The single source of truth for "what page is this, and did we just
//  navigate": ONE observer, computed ONCE per transition, in the router itself
//  (`useNavigationTelemetry`, called from App.tsx). Each transition becomes a
//  real `app.page` span (`openNavigationSpan` + `finishNavigationSpan`), a
//  bucketed `app.page.transitionMs` metric and the `app.page.viewed` probe —
//  all through the same public API every other call site uses.
//
//  THE TRANSITION IS TIMED HERE, from route commit to next paint (a
//  double-`requestAnimationFrame` — the "two frames" heuristic browsers use
//  elsewhere to mean "painted"), and the span's own duration IS that time, so
//  there is no second clock to keep in sync with the metric.
//
//  CARDINALITY — REVISED 2026-09-01, operator decision. The page name is now
//  the CONCRETE STATION (`/os/solaris`), with the route PATTERN kept beside
//  it as `kh.route.pattern`. It used to be the pattern alone.
//
//  Why the usual RUM convention does not apply here. Templating a page name
//  exists to stop UNBOUNDED identifiers (user ids, order ids, cart ids) from
//  exploding the page dimension. `osId` is not one of those: it is a FIXED
//  REGISTRY (`registry/stations/*.json`, one name per station, enforced by
//  `scripts/stations-registry.py`), and the stations are genuinely different
//  products — measured golden-restore times on the same box the same day span
//  win95 639 ms, beos 1695 ms, amiga 2535 ms, zxspectrum 17.2 s. Averaging a
//  QEMU x86 guest with a MAME-driven 8-bit micro into one number hides the
//  order of magnitude that is the whole point of looking.
//
//  BOTH, NOT A SWAP. `kh.route.pattern` rides on the same navigation span,
//  so "how is the station page doing overall" stays one filter away — a pure
//  swap would trade one blindness for another.
//
//  THE BOUND IS STILL ENFORCED, and syntactically, because this code cannot
//  ask the registry: `STATION_ID` below. A param value that is not a plausible
//  registry id (anything a crawler or a typo produces) is NOT substituted, and
//  the page name falls back to exactly the old pattern — so the worst case is
//  the previous behaviour, never a leaked path. See docs/ANALYTICS.md for the
//  escalation if that syntactic bound ever proves too loose in practice.
//
//  WALK-IN CLONES REPORT AS THE STATION. `/walkin/play/:os` carries the
//  EXHIBIT id (`win311`), never the clone id (`walkin-win311-1`) — the clone
//  is only ever named inside the claim's `signalEndpoint`, never in the URL —
//  so a poolSize-3 exhibit is one page, not three. `/walkin/play/win311` stays
//  distinct from `/os/win311` on purpose: a private clone with a reset button
//  and a queue is a different product from the shared exhibit.
//
//  Everything else is unchanged: never the query string, never free text,
//  only short stable tokens — the same rule `trace.ts` and `errors.ts` state.
// ============================================================================

import { useEffect, useRef } from 'react';
import { useLocation, useNavigationType } from 'react-router-dom';
import { reach, recordMetric } from './index';
import { childOfActive, popActive, pushActive, type Span } from './trace';

/**
 * The router's own route table. scripts/test_page_naming_in_sync.py pins it
 * equal to the routes spa/src/App.tsx actually declares, so a new route
 * cannot silently report as the `*` bucket.
 */
const ROUTES: readonly string[] = [
  '/',
  '/os/:osId',
  '/fleet',
  '/about',
  '/admin/walkin',
  '/admin/observability',
  '/museum',
  '/museum2',
  '/walkin',
  '/walkin/exhibits',
  // Ordered AFTER the exhibits listing above: matching here is first-wins, and
  // the pinned-station route would otherwise swallow it. It reports as the
  // EXHIBIT id (win311), never a clone — the same rule the play route below
  // follows, so a pool of eight stays one page rather than eight.
  '/walkin/:os',
  '/walkin/play/:os',
];

/** The catch-all pattern for a path matching none of the above — App.tsx's
 *  own `path="*"` route (which immediately redirects to `/`), so a stray
 *  unmatched location still groups into one low-cardinality bucket instead
 *  of leaking the raw path as a "pattern". */
const UNMATCHED_PATTERN = '*';

/**
 * What a route param has to look like before it is allowed into a page NAME.
 *
 * Every id in `registry/stations/*.json` is lowercase-alphanumeric, starts
 * with a letter and is at most 12 characters (`aix432`, `zxspectrum`,
 * `msdoswin1`); this allows 16 for headroom. It is a SYNTACTIC bound, not a
 * registry-membership check — the browser has no synchronous list of stations
 * (the manifest is fetched, and a navigation cannot wait for it). What it buys
 * is that a page name can only ever be a short stable token: no path
 * traversal, no query string, no free text, no unbounded identifier shape.
 *
 * scripts/test_page_naming_in_sync.py checks every registry station id
 * passes it.
 */
const STATION_ID = /^[a-z][a-z0-9]{1,15}$/;

/**
 * The PAGE NAME for a navigation: the route pattern with each `:param`
 * replaced by its concrete value, when that value passes `STATION_ID`.
 *
 * Generic rather than special-cased on `osId`/`os`, so a future station-scoped
 * route names itself correctly with no edit here. A param that fails the guard
 * keeps its `:name` placeholder, which means an unrecognised id degrades to
 * EXACTLY the old pattern-only name (`/os/:osId`) rather than to anything new.
 *
 * Exported for tests.
 */
export function pageName(pattern: string, params: Record<string, string>): string {
  if (pattern === UNMATCHED_PATTERN) return UNMATCHED_PATTERN;
  return pattern
    .split('/')
    .map((seg) => {
      if (!seg.startsWith(':')) return seg;
      const value = params[seg.slice(1)];
      return value && STATION_ID.test(value) ? value : seg;
    })
    .join('/');
}

export interface RouteMatch {
  pattern: string;
  params: Record<string, string>;
}

/** Match a pathname against `ROUTES`, extracting `:param` segments. Exported
 *  for tests; `useNavigationTelemetry` is what the router actually calls. */
export function matchRoute(pathname: string): RouteMatch {
  const segs = (pathname || '/').split('/').filter(Boolean);
  for (const pattern of ROUTES) {
    const pSegs = pattern.split('/').filter(Boolean);
    if (pSegs.length !== segs.length) continue;
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < pSegs.length; i += 1) {
      const p = pSegs[i];
      if (p.startsWith(':')) params[p.slice(1)] = segs[i];
      else if (p !== segs[i]) { ok = false; break; }
    }
    if (ok) return { pattern, params };
  }
  return { pattern: UNMATCHED_PATTERN, params: {} };
}

type NavKind = 'initial' | 'push' | 'replace' | 'popstate';

export interface NavEvent {
  pattern: string;
  params: Record<string, string>;
  /** null only for the very first navigation this tab makes. */
  prevPattern: string | null;
  kind: NavKind;
}

/** The navigation span's attributes. Values are always short tokens — a
 *  route pattern or a station id — never free text, per this module's own
 *  header. */
function navAttrs(event: NavEvent): Record<string, string> {
  const attrs: Record<string, string> = {
    // The page NAME (`/os/beos`) and the route PATTERN (`/os/:osId`) are both
    // carried, deliberately — the "both, not a swap" rule in this module's
    // header — so the store keeps the pattern roll-up that
    // /admin/observability and pageBinding.ts's `kh.page.pattern` group by,
    // and gains the per-station view beside it.
    'kh.page.name': pageName(event.pattern, event.params),
    'kh.route.pattern': event.pattern,
    'kh.route.kind': event.kind,
  };
  if (event.prevPattern) attrs['kh.route.prevPattern'] = event.prevPattern;
  // Only ONE param is ever realistic here (`osId` / `os` — see ROUTES), but
  // this stays generic rather than special-casing those two names.
  for (const [k, v] of Object.entries(event.params)) {
    attrs[`kh.route.param.${k}`] = v;
  }
  return attrs;
}

/** Opens a span timed from NOW (route commit) to
 *  `finishNavigationSpan` (next paint), so the span's own duration IS the
 *  transition time — no separate clock to keep in sync with the metric
 *  below, the same discipline `metrics.ts`'s `startTiming` uses. */
export function openNavigationSpan(event: NavEvent): Span {
  try {
    const span = childOfActive('app.page', navAttrs(event), 'internal');
    pushActive(span);
    return span;
  } catch {
    return {
      traceId: '', spanId: '', child: () => openNavigationSpan(event),
      attr() {}, event() {}, recordException() {}, end() {}, endAt() {},
    };
  }
}

/** Ends the span opened above, records the bucketed metric, and reaches the
 *  probe. Always call exactly once per `openNavigationSpan`. Uses the SAME
 *  public API every other call site in the app uses (`reach`/`recordMetric`
 *  from analytics/index.ts and analytics/metrics.ts) rather than the sink's
 *  internals directly, so this gets the same bucketing, grading and sanity
 *  checks as every other probe and metric in the catalogue. */
export function finishNavigationSpan(span: Span, transitionMs: number): void {
  try {
    popActive(span);
    const ms = Number.isFinite(transitionMs) && transitionMs >= 0 ? Math.round(transitionMs) : 0;
    span.end('ok', { 'kh.metric.ms': ms });
    // 'app.page.transitionMs' — declared in catalogue/app.ts, scale 'ms'.
    recordMetric('app.page.transitionMs', ms);
    // 'app.page.viewed' — declared in catalogue/app.ts, grade 'auto'.
    reach('app.page.viewed');
  } catch { /* instrumentation never throws into the app */ }
}

/** Resolves after the browser has (almost certainly) painted the current
 *  frame — the standard double-`requestAnimationFrame` heuristic. Falls back
 *  to a short timeout when `requestAnimationFrame` does not exist (tests,
 *  a hidden/throttled tab where rAF may never fire) so a navigation can
 *  never leave a span open forever. */
export function nextPaint(): Promise<void> {
  return new Promise((resolve) => {
    try {
      if (typeof requestAnimationFrame !== 'function') {
        setTimeout(resolve, 0);
        return;
      }
      const timeout = setTimeout(resolve, 2000);
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          clearTimeout(timeout);
          resolve();
        });
      });
    } catch {
      resolve();
    }
  });
}

/**
 * The single navigation observer, called once from App.tsx. Watches the
 * router's OWN location, so it needs no separate history listener and can
 * never disagree with what React actually rendered.
 *
 * - The FIRST invocation (component mount) is always `kind: 'initial'`,
 *   regardless of what `useNavigationType()` reports (React Router reports
 *   `POP` for the very first load too — indistinguishable from a real
 *   browser back/forward without this ref).
 * - Every invocation after that maps `useNavigationType()` directly:
 *   `PUSH` → `push`, `REPLACE` → `replace`, `POP` → `popstate`.
 */
export function useNavigationTelemetry(): void {
  const location = useLocation();
  const navType = useNavigationType();
  const prevPatternRef = useRef<string | null>(null);
  const isFirstRef = useRef(true);

  useEffect(() => {
    try {
      const { pattern, params } = matchRoute(location.pathname);
      const kind: NavKind = isFirstRef.current
        ? 'initial'
        : navType === 'PUSH' ? 'push' : navType === 'REPLACE' ? 'replace' : 'popstate';
      const event: NavEvent = { pattern, params, prevPattern: prevPatternRef.current, kind };
      isFirstRef.current = false;
      prevPatternRef.current = pattern;

      const t0 = typeof performance !== 'undefined' ? performance.now() : Date.now();
      const span = openNavigationSpan(event);
      let done = false;
      void nextPaint().then(() => {
        if (done) return;
        done = true;
        const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
        finishNavigationSpan(span, now - t0);
      });
    } catch {
      /* instrumentation must never break navigation */
    }
    // Only the pathname identifies a distinct navigation for this purpose —
    // search/hash changes and object-identity churn on `location` itself
    // must not reopen a span for the same page.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.pathname]);
}

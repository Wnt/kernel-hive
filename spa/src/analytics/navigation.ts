// ============================================================================
//  analytics/navigation — one router-level event, two consumers.
//  ---------------------------------------------------------------------------
//  DEFECT 4, REVISED. The original brief for this defect was "call
//  ineum('page', ...) so Instana's Websites view has something to group by".
//  The operator overrode that mid-implementation: Instana is a benchmark, not
//  a dependency, and a page name our own plane cannot see without a
//  third-party vendor loaded is not acceptable. So this file is the single
//  source of truth for "what page is this, and did we just navigate" — ONE
//  observer, computed ONCE per transition, in the router itself
//  (`useNavigationTelemetry`, called from App.tsx) — and it feeds two
//  independent consumers:
//
//    A. OUR OWN PLANE (`openNavigationSpan` + `finishNavigationSpan` →
//       `reach` + `recordMetric` + a real span). Works with Instana absent
//       entirely — verified by the unit tests in this file's `.test.ts`,
//       which never touch `ineum`.
//    B. INSTANA (`reportPageToInstana` + `reportTransitionDurationToInstana`
//       → `ineum('page', ...)` + `meta`), reading the SAME event. A no-op
//       when `window.ineum` does not exist (unconfigured build), exactly
//       like every other call in instana.ts.
//
//  WHY autoPageDetection IS OFF (instana.ts sets it explicitly `false`, and
//  says why in its own comment). Short version: this file already drives
//  every transition, on the router's own knowledge of the route PATTERN —
//  duplicating that with Instana's own URL-change heuristic would produce
//  two disagreeing opinions about the same navigation and double the beacon
//  count. The cost, paid deliberately: recent Instana agent versions are
//  documented (inconsistently, like everything else about this vendor) to
//  time a transition automatically under autoPageDetection — a number this
//  integration cannot ask the agent for with it off. So this file measures
//  its own transition duration (route commit to next paint) and keeps it
//  durably in OUR plane; what it can pass back to Instana is limited to an
//  ALREADY-VERIFIED call shape (`meta`, fixed by defect 1) rather than an
//  invented, untested custom-event API — see reportPageToInstana() / reportTransitionDurationToInstana() below.
//
//  CARDINALITY. The page name Instana (and our own probe) receives is the
//  route PATTERN — `/os/:osId`, never `/os/solaris` — so every station
//  groups under one page instead of exploding into one page per exhibit.
//  The concrete station id rides as `meta`/a span attribute instead, same
//  rule `trace.ts` and `errors.ts` already state: never the query string,
//  never free text, only short stable tokens.
//
//  THE INITIAL LOAD IS NOT DOUBLE-REPORTED. Instana already emits its own
//  automatic `pageLoad` beacon for the first page (unaffected by
//  autoPageDetection, which only governs SUBSEQUENT transitions) — the
//  `page` NAME for that beacon is set once, early, in spa/index.html's
//  inline bootstrap (defect 2/3's fix; see that file for why it has to be
//  set before the beacon fires). So `useNavigationTelemetry`'s first
//  invocation (`kind: 'initial'`) reports to consumer A exactly like any
//  other transition — useful data our own plane has no separate "page load"
//  event to duplicate — but skips consumer B entirely: calling
//  `ineum('page', ...)` again for the same navigation Instana is already
//  about to name via its pageLoad beacon would be a second, redundant
//  naming call for one navigation, which is the exact double-report this
//  requirement forbids.
// ============================================================================

import { useEffect, useRef } from 'react';
import { useLocation, useNavigationType } from 'react-router-dom';
import { reach, recordMetric } from './index';
import { childOfActive, popActive, pushActive, type Span } from './trace';

/** The subset of `ineum` this module calls. Declared locally (rather than
 *  importing instana.ts's private `ineum` guard) so this module has no
 *  dependency on that file beyond its exported constants — the same
 *  isolation khFetch.ts already keeps from instana.ts. */
declare global {
  interface Window {
    ineum?: (...args: unknown[]) => void;
  }
}

function ineum(...args: unknown[]): void {
  try {
    if (typeof window === 'undefined') return;
    const fn = window.ineum;
    if (typeof fn === 'function') fn(...args);
  } catch {
    /* never throw */
  }
}

/**
 * The router's own route table, duplicated (deliberately, and minimally) in
 * spa/index.html's inline bootstrap to name the VERY FIRST page before any
 * module here has evaluated — see that file's comment. Keep both lists in
 * sync by hand; this one is canonical, the HTML one is the one that has to
 * run before this module can be. Order does not matter: no two patterns
 * here can both match a path of the same segment count.
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
  '/walkin/play/:os',
];

/** The catch-all pattern for a path matching none of the above — App.tsx's
 *  own `path="*"` route (which immediately redirects to `/`), so a stray
 *  unmatched location still groups into one low-cardinality bucket instead
 *  of leaking the raw path as a "pattern". */
const UNMATCHED_PATTERN = '*';

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

/** Attribute/meta keys shared by both consumers, so the two cannot drift on
 *  spelling. Values are always short tokens — a route pattern or a station
 *  id — never free text, per this module's own header. */
function navAttrs(event: NavEvent): Record<string, string> {
  const attrs: Record<string, string> = {
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

/** Consumer A: our own plane. Opens a span timed from NOW (route commit) to
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
      attr() {}, event() {}, recordException() {}, end() {},
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

/**
 * Consumer B: Instana, the page NAME half. A no-op when unconfigured (no
 * `window.ineum`), exactly like every call in instana.ts. Fires on the
 * route change itself — matching the timing Instana's own
 * `autoPageDetection` would have used, had it been left on — not after
 * paint, so it is a separate call from the duration half below rather than
 * waiting on `nextPaint()`. Skips the INITIAL navigation entirely — see this
 * module's header for why (Instana already names that one via its own
 * pageLoad beacon, set from spa/index.html's bootstrap).
 */
export function reportPageToInstana(event: NavEvent): void {
  if (event.kind === 'initial') return;
  ineum('page', event.pattern);
  for (const [k, v] of Object.entries(event.params)) {
    ineum('meta', `kh.route.param.${k}`, v);
  }
}

/**
 * Consumer B, the duration half — sent once the transition's own measured
 * time is known (after `nextPaint()`), for every navigation INCLUDING the
 * initial one (Instana's own pageLoad-timing mechanism is independent of
 * autoPageDetection, so this is not the double-report `reportPageToInstana`
 * guards against). Best-effort: `meta` is an already-verified call shape
 * (defect 1's fix), used here rather than an unverified custom-event API
 * this environment has no way to test against the real agent — see this
 * module's header.
 */
export function reportTransitionDurationToInstana(transitionMs: number): void {
  ineum('meta', 'kh.page.transitionMs', String(Math.round(transitionMs)));
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
      // Consumer B, page name: fires on the URL change itself (matching how
      // Instana's own autoPageDetection would time it), not after paint.
      reportPageToInstana(event);
      let done = false;
      void nextPaint().then(() => {
        if (done) return;
        done = true;
        const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
        const transitionMs = now - t0;
        finishNavigationSpan(span, transitionMs);
        // Consumer B, duration: best-effort, once it is actually known.
        reportTransitionDurationToInstana(transitionMs);
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

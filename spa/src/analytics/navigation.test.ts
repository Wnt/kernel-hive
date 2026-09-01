// Tests for analytics/navigation: the single router-level observer and its
// two consumers. Exercises the exported functions directly (matching how
// this suite already tests khFetch.ts and trace.ts) rather than rendering
// the React hook — `useNavigationTelemetry` is a thin wiring layer over
// exactly these functions.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  matchRoute,
  openNavigationSpan,
  finishNavigationSpan,
  pageName,
  reportPageToInstana,
  reportTransitionDurationToInstana,
  nextPaint,
  type NavEvent,
} from './navigation';
import { __bufferedSpans, __resetTracer, configureTracer } from './trace';
import { __pendingBatch, __resetSink, configureSink } from './sink';

type Call = [string, ...unknown[]];

function installIneum(): { calls: Call[] } {
  const calls: Call[] = [];
  const fn = (...args: unknown[]) => { calls.push(args as Call); };
  (globalThis as { window?: unknown }).window = { ineum: fn };
  return { calls };
}

beforeEach(() => {
  __resetTracer();
  __resetSink();
  configureTracer({ enabled: true, emit: () => {} });
  configureSink({ sessionId: 'sess1', allowed: true, clientClass: () => 'human' });
});

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
});

describe('matchRoute', () => {
  it('matches the root path', () => {
    expect(matchRoute('/')).toEqual({ pattern: '/', params: {} });
  });

  it('extracts the station id from /os/:osId', () => {
    expect(matchRoute('/os/solaris')).toEqual({ pattern: '/os/:osId', params: { osId: 'solaris' } });
    expect(matchRoute('/os/win2000')).toEqual({ pattern: '/os/:osId', params: { osId: 'win2000' } });
  });

  it('groups every station under the SAME pattern — the whole cardinality point', () => {
    expect(matchRoute('/os/solaris').pattern).toBe(matchRoute('/os/win2000').pattern);
  });

  it('matches every static route named in the brief', () => {
    for (const path of ['/fleet', '/about', '/admin/walkin', '/admin/observability', '/museum', '/walkin', '/walkin/exhibits']) {
      expect(matchRoute(path).pattern).toBe(path);
    }
  });

  it('extracts the exhibit id from /walkin/play/:os', () => {
    expect(matchRoute('/walkin/play/beos')).toEqual({ pattern: '/walkin/play/:os', params: { os: 'beos' } });
  });

  it('falls back to a single low-cardinality bucket for an unknown path', () => {
    expect(matchRoute('/this/does/not/exist').pattern).toBe('*');
    expect(matchRoute('/this/does/not/exist').params).toEqual({});
  });
});

describe('consumer A: our own plane, with Instana entirely absent', () => {
  it('opens and ends a real span with no window.ineum at all', () => {
    delete (globalThis as { window?: unknown }).window;
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: 'beos' }, prevPattern: '/', kind: 'push' };
    const span = openNavigationSpan(event);
    finishNavigationSpan(span, 42);
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(1);
    expect(spans[0].n).toBe('app.page');
    expect(spans[0].a).toMatchObject({
      'kh.route.pattern': '/os/:osId',
      'kh.route.kind': 'push',
      'kh.route.prevPattern': '/',
      'kh.route.param.osId': 'beos',
      'kh.metric.ms': 42,
    });
  });

  it('records the probe and the metric — visible with Instana absent', () => {
    delete (globalThis as { window?: unknown }).window;
    const event: NavEvent = { pattern: '/fleet', params: {}, prevPattern: '/', kind: 'push' };
    const span = openNavigationSpan(event);
    finishNavigationSpan(span, 120);
    const batch = __pendingBatch();
    expect(batch.probes).toContainEqual({ id: 'app.page.viewed', grade: 'auto', n: 1 });
    expect(batch.metrics.some((m) => m.id === 'app.page.transitionMs')).toBe(true);
  });
});

describe('consumer B: Instana', () => {
  it('is a no-op with no window.ineum (unconfigured build)', () => {
    delete (globalThis as { window?: unknown }).window;
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: 'beos' }, prevPattern: '/', kind: 'push' };
    expect(() => reportPageToInstana(event)).not.toThrow();
    expect(() => reportTransitionDurationToInstana(50)).not.toThrow();
  });

  it('names the STATION and keeps the route pattern as meta (both, not a swap)', () => {
    const { calls } = installIneum();
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: 'beos' }, prevPattern: '/', kind: 'push' };
    reportPageToInstana(event);
    expect(calls).toContainEqual(['page', '/os/beos']);
    expect(calls).toContainEqual(['meta', 'kh.route.pattern', '/os/:osId']);
    expect(calls).toContainEqual(['meta', 'kh.route.param.osId', 'beos']);
  });

  it('sets the page name LAST — meta after it would belong to the next transition', () => {
    const { calls } = installIneum();
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: 'solaris' }, prevPattern: null, kind: 'push' };
    reportPageToInstana(event);
    expect(calls.findIndex((c) => c[0] === 'page')).toBe(calls.length - 1);
  });

  it('never mints a page name from something that is not a plausible station id', () => {
    const { calls } = installIneum();
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: '../etc/passwd' }, prevPattern: null, kind: 'push' };
    reportPageToInstana(event);
    // Degrades to EXACTLY the old pattern-only name — the worst case is the
    // previous behaviour, never a leaked path in the page dimension.
    expect(calls.find((c) => c[0] === 'page')).toEqual(['page', '/os/:osId']);
  });

  it('skips the INITIAL navigation entirely — index.html already named that page-load beacon', () => {
    const { calls } = installIneum();
    const event: NavEvent = { pattern: '/', params: {}, prevPattern: null, kind: 'initial' };
    reportPageToInstana(event);
    expect(calls).toEqual([]);
  });

  it('forwards the measured duration as meta, for every kind including initial', () => {
    const { calls } = installIneum();
    reportTransitionDurationToInstana(77);
    expect(calls).toContainEqual(['meta', 'kh.page.transitionMs', '77']);
  });
});

describe('both consumers receive the same event', () => {
  it('the pattern/params dispatched to Instana match the attributes recorded on our own span', () => {
    const { calls } = installIneum();
    const event: NavEvent = { pattern: '/os/:osId', params: { osId: 'irix' }, prevPattern: '/fleet', kind: 'popstate' };
    const span = openNavigationSpan(event);
    reportPageToInstana(event);
    finishNavigationSpan(span, 10);
    const [ourSpan] = __bufferedSpans();
    expect(ourSpan.a?.['kh.route.pattern']).toBe('/os/:osId');
    expect(ourSpan.a?.['kh.route.param.osId']).toBe('irix');
    // Both planes agree on the page NAME as well as on the pattern — the whole
    // point of carrying `kh.page.name` beside `kh.route.pattern` on our span.
    expect(ourSpan.a?.['kh.page.name']).toBe('/os/irix');
    expect(calls).toContainEqual(['page', '/os/irix']);
    expect(calls).toContainEqual(['meta', 'kh.route.pattern', '/os/:osId']);
    expect(calls).toContainEqual(['meta', 'kh.route.param.osId', 'irix']);
  });
});

describe('pageName — the cardinality bound, stated as a function', () => {
  it('substitutes a registry-shaped id and leaves everything else alone', () => {
    expect(pageName('/os/:osId', { osId: 'zxspectrum' })).toBe('/os/zxspectrum');
    expect(pageName('/fleet', {})).toBe('/fleet');
    expect(pageName('/', {})).toBe('/');
    expect(pageName('*', {})).toBe('*');
  });

  it('collapses all three clones of a poolSize-3 walk-in exhibit to one page', () => {
    // The pool is walkin-win311-1/-2/-3, but only the EXHIBIT id is ever in
    // the URL — the clone lives in the claim's signalEndpoint. One page.
    expect(pageName('/walkin/play/:os', { os: 'win311' })).toBe('/walkin/play/win311');
  });

  it('keeps /os/<id> and /walkin/play/<id> distinct — different products', () => {
    expect(pageName('/os/win311', {})).not.toBe(pageName('/walkin/play/:os', { os: 'win311' }));
  });

  it('refuses anything that is not a short lowercase token', () => {
    for (const bad of ['', '../etc', 'Win95', 'win 95', '1win', 'a'.repeat(40), 'win95?x=1']) {
      expect(pageName('/os/:osId', { osId: bad })).toBe('/os/:osId');
    }
  });
});

describe('nextPaint', () => {
  it('resolves (falls back to a timer when requestAnimationFrame is unavailable)', async () => {
    await expect(nextPaint()).resolves.toBeUndefined();
  });
});

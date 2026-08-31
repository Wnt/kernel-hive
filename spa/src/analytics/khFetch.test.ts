// Tests for khFetch: the global fetch patch that makes propagation automatic
// instead of opt-in per call site (see the module header for why). The theme
// here is the same one as the module itself — same-origin only, never the
// query string, no span for our own telemetry posts, and a throwing
// telemetry path must never take the real request down with it.

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { installKhFetchPropagation, __resetKhFetch } from './khFetch';
import { __bufferedSpans, __resetTracer, configureTracer, seedPageLoadTrace } from './trace';
import * as traceModule from './trace';

const ORIGIN = 'https://gallery.example';

function makeWindow(realFetch: typeof fetch) {
  return {
    location: { href: `${ORIGIN}/`, origin: ORIGIN },
    fetch: realFetch,
  };
}

let calls: { url: string; init: RequestInit | undefined }[] = [];

async function realFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  calls.push({ url: typeof input === 'string' ? input : String(input), init });
  return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
}

beforeEach(() => {
  __resetTracer();
  __resetKhFetch();
  configureTracer({ enabled: true, emit: () => {} });
  calls = [];
  (globalThis as { window?: unknown }).window = makeWindow(realFetch as typeof fetch);
});

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
  vi.restoreAllMocks();
});

describe('installKhFetchPropagation', () => {
  it('adds traceparent to a same-origin request', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`, { method: 'POST' });
    expect(calls).toHaveLength(1);
    const headers = calls[0].init?.headers as Headers;
    expect(headers.get('traceparent')).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
  });

  it('does NOT touch a cross-origin request', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch('https://third-party.example/beacon');
    expect(calls).toHaveLength(1);
    const headers = calls[0].init?.headers;
    expect(headers).toBeUndefined();
  });

  it('respects a traceparent the caller already set, rather than overwriting it', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    const mine = '00-11111111111111111111111111111111-2222222222222222-01';
    await win.fetch(`${ORIGIN}/signal/beos.json`, { headers: { traceparent: mine } });
    const headers = calls[0].init?.headers as Record<string, string>;
    expect(headers.traceparent).toBe(mine);
  });

  it('creates a client span for a same-origin call, ended with the status code', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`, { method: 'POST' });
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(1);
    expect(spans[0].n).toBe('http.client.request');
    expect(spans[0].kd).toBe('client');
    expect(spans[0].a).toMatchObject({ 'url.path': '/restore/beos', 'http.request.method': 'POST' });
    expect(spans[0].a).toMatchObject({ 'http.response.status_code': 200 });
    expect(spans[0].k).toBe('ok');
  });

  it('never puts the query string in the span path', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/analytics/report.json?station=beos&secret=1`);
    // /analytics is an excluded path (see below) so use a non-excluded one instead:
    await win.fetch(`${ORIGIN}/fleet-table.json?x=1`);
    const spans = __bufferedSpans();
    const span = spans.find((s) => s.n === 'http.client.request' && s.a?.['url.path'] === '/fleet-table.json');
    expect(span).toBeTruthy();
    expect(JSON.stringify(span)).not.toContain('secret');
    expect(JSON.stringify(span)).not.toContain('x=1');
  });

  it('excludes our own telemetry endpoints from span creation, but still propagates the header', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    for (const path of ['/traces', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd']) {
      await win.fetch(`${ORIGIN}${path}`, { method: 'POST' });
    }
    expect(__bufferedSpans()).toHaveLength(0);
    for (const call of calls) {
      const headers = call.init?.headers as Headers;
      expect(headers.get('traceparent')).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
    }
  });

  it('is idempotent: installing twice patches fetch exactly once', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    const patchedOnce = win.fetch;
    installKhFetchPropagation();
    expect(win.fetch).toBe(patchedOnce);
  });

  it('a throwing telemetry path never breaks the underlying request', async () => {
    vi.spyOn(traceModule, 'traceHeaders').mockImplementation(() => { throw new Error('boom'); });
    vi.spyOn(traceModule, 'childOfActive').mockImplementation(() => { throw new Error('boom too'); });
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    const res = await win.fetch(`${ORIGIN}/restore/beos`);
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(1);
  });

  it('continues the page-load trace for the first client span opened this page', async () => {
    seedPageLoadTrace('00-33333333333333333333333333333333-4444444444444444-01');
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    const [span] = __bufferedSpans();
    expect(span.t).toBe('33333333333333333333333333333333');
    expect(span.p).toBe('4444444444444444');
  });

  // DEFECT 5 REGRESSION. The server's ingest validator (scripts/serve/
  // traces.py) silently DROPS any span whose name does not match
  // `^[A-Za-z][A-Za-z0-9._-]{0,79}$` — no space, ever. Every other test in
  // this file only proves the tab's OWN buffer got a span; none of them
  // would have caught a span the server refuses, because there was no
  // server in the loop, and that gap is exactly how the old `` `HTTP
  // ${method}` `` name (e.g. "HTTP GET") shipped, passed every one of THOSE
  // tests, and then produced zero client spans in 30 minutes of live
  // traffic. Pin the server's own rule here so this class of bug — valid
  // JSON, valid client-side buffer, silently rejected on ingest — cannot
  // recur unnoticed.
  it('every span name satisfies the server ingest validator (no spaces, ever)', async () => {
    const SERVER_NAME_RE = /^[A-Za-z][A-Za-z0-9._-]{0,79}$/;
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`, { method: 'POST' });
    await win.fetch(`${ORIGIN}/signal/beos.json`);
    const spans = __bufferedSpans();
    expect(spans.length).toBeGreaterThan(0);
    for (const span of spans) {
      expect(span.n).toMatch(SERVER_NAME_RE);
    }
  });
});

// Tests for khFetch: the global fetch patch that makes propagation automatic
// instead of opt-in per call site (see the module header for why). The theme
// here is the same one as the module itself — same-origin only, never the
// query string, no span for our own telemetry posts, and a throwing
// telemetry path must never take the real request down with it.

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { installKhFetchPropagation, __resetKhFetch } from './khFetch';
import {
  __bufferedSpans, __resetTracer, configureTracer, startTrace, pushActive, popActive,
} from './trace';
import { seedPageLoadTrace } from './pageLoadJoin';
import { BACKEND_TRACE_ID_RE } from './instana';
import * as traceModule from './trace';

const ORIGIN = 'https://gallery.example';

function makeWindow(realFetch: typeof fetch) {
  return {
    location: { href: `${ORIGIN}/`, origin: ORIGIN },
    fetch: realFetch,
  };
}

let calls: { url: string; init: RequestInit | undefined }[] = [];

/** Headers the next `realFetch` reply carries — the server's return leg. */
let responseHeaders: Record<string, string> = {};

async function realFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  calls.push({ url: typeof input === 'string' ? input : String(input), init });
  return new Response('{}', {
    status: 200,
    headers: { 'content-type': 'application/json', ...responseHeaders },
  });
}

/** The parent-id field of the outgoing `traceparent` on call `i`. */
function sentParentId(i = 0): string | undefined {
  const headers = calls[i].init?.headers as Headers;
  return headers?.get('traceparent')?.split('-')[2];
}

function sentTraceId(i = 0): string | undefined {
  const headers = calls[i].init?.headers as Headers;
  return headers?.get('traceparent')?.split('-')[1];
}

beforeEach(() => {
  __resetTracer();
  __resetKhFetch();
  configureTracer({ enabled: true, emit: () => {} });
  calls = [];
  responseHeaders = {};
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

  it('excludes our own telemetry endpoints from span creation AND from the header', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    for (const path of ['/traces', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd']) {
      await win.fetch(`${ORIGIN}${path}`, { method: 'POST' });
    }
    expect(__bufferedSpans()).toHaveLength(0);
    for (const call of calls) {
      const headers = call.init?.headers as Headers | undefined;
      expect(headers?.get('traceparent') ?? null).toBeNull();
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
    vi.spyOn(traceModule, 'traceparentOf').mockImplementation(() => { throw new Error('boom'); });
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

  // ==========================================================================
  // DEFECT 1 REGRESSION: the header has to name THIS call's client span.
  //
  // The two tests above (":adds traceparent" and ":creates a client span")
  // are exactly the pair that let this ship: one asserts the header's SHAPE,
  // the other asserts the span EXISTS, and neither ever compares the two. A
  // header whose parent-id belongs to some other span — or to no span at all
  // — passes both, forever, while the server's entry span hangs off the wrong
  // parent (or off a trace nothing else is in). So these compare them.
  // ==========================================================================

  it('the outgoing parent-id is EXACTLY the client span it created', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`, { method: 'POST' });
    const [span] = __bufferedSpans();
    expect(span.n).toBe('http.client.request');
    expect(sentParentId()).toBe(span.s);
    expect(sentTraceId()).toBe(span.t);
  });

  it('with NO active span, the client span and the header share one trace id', async () => {
    // The nastier half of the defect: `traceHeaders()` minted a fresh trace id
    // and a span id owned by nothing, while `childOfActive()` started its own
    // separate trace — one call, two unrelated traces, and no way to notice
    // from either end.
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    const [span] = __bufferedSpans();
    expect(sentTraceId()).toBe(span.t);
    expect(sentParentId()).toBe(span.s);
  });

  it('inside an open flow, the header names the client span and NOT the flow root', async () => {
    const root = startTrace('station.connect');
    pushActive(root);
    try {
      installKhFetchPropagation();
      const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
      await win.fetch(`${ORIGIN}/restore/beos`);
    } finally {
      popActive(root);
      root.end('ok');
    }
    const client = __bufferedSpans().find((s) => s.n === 'http.client.request');
    expect(client).toBeTruthy();
    expect(client!.t).toBe(root.traceId);
    expect(client!.p).toBe(root.spanId);      // the client span is the flow's child
    expect(sentTraceId()).toBe(root.traceId); // same trace, still
    expect(sentParentId()).toBe(client!.s);   // but the SERVER hangs off the CLIENT span
    expect(sentParentId()).not.toBe(root.spanId);
  });

  // ==========================================================================
  // THE NO-ORPHAN INVARIANT (docs/lab/TRACE-CONTEXT.md §8): a `traceparent`
  // this tab emits names a span this tab created and will record, or there is
  // no `traceparent`. Measured 2026-09-01 on the live store: 42.9% of the
  // spans that declared a parent named one that was never stored, and both of
  // the producers below are why.
  // ==========================================================================

  it('an excluded telemetry path emits NO traceparent, even inside an open flow', async () => {
    // The old contract propagated from the ambient span here. On a path we
    // have DECIDED not to open a span for, that names an id that will only
    // ever exist if some unrelated span happens to be recorded — and on
    // `/clientcmd`, polled every 5 s from a flow root that outlives the poll,
    // it produced 1,590 permanently rootless `serve.clientcmd` spans in six
    // hours. No span, no header.
    const root = startTrace('station.connect');
    pushActive(root);
    try {
      installKhFetchPropagation();
      const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
      await win.fetch(`${ORIGIN}/clientcmd?since=0`);
    } finally {
      popActive(root);
      root.end('ok');
    }
    expect(__bufferedSpans().filter((s) => s.n === 'http.client.request')).toHaveLength(0);
    const headers = calls[0].init?.headers as Headers | undefined;
    expect(headers?.get('traceparent') ?? null).toBeNull();
  });

  it('never emits a traceparent naming a span that was never recorded', async () => {
    // The general form, and the one an excluded-path assertion alone misses:
    // whatever the outgoing header names must appear in the buffer. Before
    // the fix this failed two ways at once — a telemetry path borrowed the
    // ambient id, and a NOOP client span (tracer off, or `MAX_OPEN`
    // exhausted) fell back to a freshly MINTED id owned by nothing at all.
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    for (const path of ['/restore/beos', '/clientcmd?since=0', '/signal/beos.json', '/analytics']) {
      await win.fetch(`${ORIGIN}${path}`, { method: 'POST' });
    }
    const recorded = new Set(__bufferedSpans().map((s) => s.s));
    for (const call of calls) {
      const sent = (call.init?.headers as Headers | undefined)?.get('traceparent');
      if (sent === null || sent === undefined) continue;
      expect(recorded.has(sent.split('-')[2])).toBe(true);
    }
  });

  it('with the tracer OFF, a traced path emits no traceparent rather than a minted one', async () => {
    // `MAX_OPEN` exhaustion reaches this same branch in production: the client
    // span comes back NOOP and there is nothing legitimate to name. One live
    // tab in that state pointed 6,678 polls at a single id that was never
    // written.
    configureTracer({ enabled: false, emit: () => {} });
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    expect(__bufferedSpans()).toHaveLength(0);
    const headers = calls[0].init?.headers as Headers | undefined;
    expect(headers?.get('traceparent') ?? null).toBeNull();
  });

  // ==========================================================================
  // The return leg: traceresponse / Server-Timing -> kh.backend.trace_id
  // ==========================================================================

  const BACKEND = 'abcdefabcdefabcdefabcdefabcdefab';

  it('records the backend trace id from traceresponse on the client span', async () => {
    responseHeaders = { traceresponse: `00-${BACKEND}-1234567890abcdef-01` };
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    const [span] = __bufferedSpans();
    expect(span.a?.['kh.backend.trace_id']).toBe(BACKEND);
  });

  it('falls back to the Server-Timing intid token when traceresponse is absent', async () => {
    responseHeaders = { 'server-timing': `intid;desc=${BACKEND}` };
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    expect(__bufferedSpans()[0].a?.['kh.backend.trace_id']).toBe(BACKEND);
  });

  it('prefers traceresponse over Server-Timing when both are present', async () => {
    responseHeaders = {
      traceresponse: `00-${BACKEND}-1234567890abcdef-01`,
      'server-timing': 'intid;desc=99999999999999999999999999999999',
    };
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    expect(__bufferedSpans()[0].a?.['kh.backend.trace_id']).toBe(BACKEND);
  });

  it('records nothing when the response carries no trace headers', async () => {
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    expect(__bufferedSpans()[0].a?.['kh.backend.trace_id']).toBeUndefined();
  });

  it('ignores a malformed traceresponse rather than recording a useless id', async () => {
    responseHeaders = { traceresponse: '00-not-a-trace-id-01' };
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    expect(__bufferedSpans()[0].a?.['kh.backend.trace_id']).toBeUndefined();
  });

  it('survives the server ingest rules: key <= 64 chars, value <= ATTR_STR_MAX, not banned', async () => {
    // scripts/serve/traces.py `_clean_attrs`: a key over 64 chars or in
    // BANNED_ATTRS is DROPPED, a string value over ATTR_STR_MAX (120) is
    // TRUNCATED — both silently. A truncated trace id looks right in the tab
    // and joins nothing in the store, which is the worst of the three
    // outcomes, so pin the server's own numbers here.
    const BANNED = ['exception.stacktrace', 'code.stacktrace', 'url.full', 'url.query',
      'user.email', 'user.name', 'enduser.id'];
    responseHeaders = { traceresponse: `00-${BACKEND}-1234567890abcdef-01` };
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    await win.fetch(`${ORIGIN}/restore/beos`);
    const attrs = __bufferedSpans()[0].a as Record<string, string>;
    const [key, value] = Object.entries(attrs).find(([k]) => k === 'kh.backend.trace_id')!;
    expect(key.length).toBeLessThanOrEqual(64);
    expect(BANNED).not.toContain(key);
    expect(value.length).toBeLessThanOrEqual(120);
    expect(value).toBe(BACKEND); // untruncated, byte for byte
  });

  it('mirrors the backend trace id to Instana as a valid backendTraceId', async () => {
    const ineumCalls: unknown[][] = [];
    const win = (globalThis as unknown as {
      window: { fetch: typeof fetch; ineum?: (...a: unknown[]) => void };
    }).window;
    win.ineum = (...args: unknown[]) => { ineumCalls.push(args); };
    responseHeaders = { traceresponse: `00-${BACKEND}-1234567890abcdef-01` };
    installKhFetchPropagation();
    await win.fetch(`${ORIGIN}/restore/beos`);
    const reported = ineumCalls.filter(([name]) => name === 'reportEvent');
    expect(reported).toHaveLength(1);
    const opts = reported[0][2] as { backendTraceId: string };
    // The vendor DROPS anything that is not 16 or 32 hex, silently — assert
    // against its own rule, not a looser one.
    expect(BACKEND_TRACE_ID_RE.test(opts.backendTraceId)).toBe(true);
    expect(opts.backendTraceId).toBe(BACKEND);
  });

  it('a response whose headers cannot be read never breaks the call', async () => {
    // The return leg reads two headers off every traced response. A Response
    // whose `headers.get` throws (a polyfill, an opaque-ish shim, a test
    // double) must still be handed to the caller unchanged — the same rule as
    // every other enhancement in this module.
    const broken = {
      ok: true,
      status: 200,
      headers: { get() { throw new Error('boom'); } },
    } as unknown as Response;
    (globalThis as unknown as { window: { fetch: typeof fetch } }).window.fetch =
      (async () => broken) as unknown as typeof fetch;
    installKhFetchPropagation();
    const win = (globalThis as unknown as { window: { fetch: typeof fetch } }).window;
    const res = await win.fetch(`${ORIGIN}/restore/beos`);
    expect(res).toBe(broken);
    expect(__bufferedSpans()[0].a?.['kh.backend.trace_id']).toBeUndefined();
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

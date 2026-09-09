// Which BUNDLE is this client running — proven end to end on our own plane.
//
// The question that bought this file: on 2026-09-01 a phone's visit was
// recorded in full by our own telemetry and not at all by the vendor's, and
// "was that phone on the shell we deployed?" had exactly one possible source of
// an answer — a vendor beacon's `kh.bundle` meta. There were no beacons, so
// there was no answer. The build id therefore now rides OUR OWN spans, on the
// RESOURCE envelope rather than on every span, which is where OTLP puts a fact
// about the producer. serve/traces.py stores it on the trace row and
// traces_otlp.py exports it as `service.version` — the Python side of the same
// contract is pinned by scripts/test_traces.py.

import { beforeEach, describe, expect, it } from 'vitest';
import { initAnalytics } from './index';
import { BUILD_ID } from './build';
import { __resetTracer, flushSpans, startTrace } from './trace';
import { __resetSink } from './sink';
import { __resetIntent } from './intent';

interface Posted { url: string; body: Record<string, unknown> }

/** Capture what the plane POSTs, and hand back the /traces bodies. */
function captureUploads(): Posted[] {
  const posted: Posted[] = [];
  (globalThis as unknown as { fetch: unknown }).fetch = (url: string, init: { body: string }) => {
    try {
      posted.push({ url, body: JSON.parse(init.body) });
    } catch {
      posted.push({ url, body: {} });
    }
    return Promise.resolve({ ok: true });
  };
  return posted;
}

function traceBodies(posted: Posted[]) {
  return posted.filter((p) => p.url === '/traces').map((p) => p.body);
}

beforeEach(() => {
  __resetIntent();
  __resetSink();
  __resetTracer();
});

describe('the /traces resource names the client build', () => {
  it('sends kh.bundle on the resource envelope', () => {
    const posted = captureUploads();
    initAnalytics({ sessionId: 'sess-abc', allowed: true });
    startTrace('app.page').end('ok');
    flushSpans();

    const [body] = traceBodies(posted);
    expect(body).toBeDefined();
    expect((body.resource as Record<string, string>)['kh.bundle']).toBe(BUILD_ID);
  });

  it('sends it ONCE, on the envelope — never repeated onto every span', () => {
    const posted = captureUploads();
    initAnalytics({ sessionId: 'sess-abc', allowed: true });
    const root = startTrace('app.page');
    root.child('step').end('ok');
    root.end('ok');
    flushSpans();

    const [body] = traceBodies(posted);
    const spans = body.spans as Array<{ a?: Record<string, unknown> }>;
    expect(spans.length).toBeGreaterThan(1);
    for (const s of spans) expect(s.a?.['kh.bundle']).toBeUndefined();
  });

  it('keeps the resource keys the store already reads, rather than replacing them', () => {
    const posted = captureUploads();
    initAnalytics({ sessionId: 'sess-abc', allowed: true });
    startTrace('app.page').end('ok');
    flushSpans();

    expect(Object.keys(traceBodies(posted)[0].resource as object).sort())
      .toEqual(['kh.bundle', 'kh.class', 'service.name', 'session.id']);
  });

  it('degrades to an honest placeholder rather than an id-shaped lie', () => {
    // vitest has no `define` substitution and no git, so this IS the
    // unconfigured path — the assertion is that it says so out loud.
    expect(BUILD_ID).toBe('unknown-build');
  });

  it('sends nothing at all for a client the plane is not allowed to speak for', () => {
    const posted = captureUploads();
    initAnalytics({ sessionId: 'sess-abc', allowed: false });
    startTrace('app.page').end('ok');
    flushSpans();
    expect(traceBodies(posted)).toEqual([]);
  });
});

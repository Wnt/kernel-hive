// ============================================================================
//  The FLUSH half of the no-orphan invariant.
//  ---------------------------------------------------------------------------
//  The other half — "never emit a traceparent naming a span we will not
//  record" — is pinned in khFetch.test.ts. This file pins the corollary: a
//  span we DID promise to record has to actually leave the tab, and the two
//  ways it used to fail to are both measurable in the live store.
//
//    * A SHORT VISIT. The sink's only cadence was a 20 s interval plus
//      pagehide/visibilitychange. A visit shorter than the interval that
//      ended in a way those events did not catch lost the client span while
//      the SERVER span it had already parented survived — a dangling parent
//      forever. Measured 2026-09-01: 9 `serve.auth.state`, 23
//      `input.dispatch` and 2 `serve.restore` spans in six hours, each a
//      one-span trace Instana renders as rootless.
//
//    * AN OPEN FLOW. Worse, and invisible to any amount of interval-shortening:
//      a root span is buffered only when it ENDS, so a station left open holds
//      its root out of every flush there will ever be. One live tab held
//      `station.connect` open for seven hours and 16,153 spans.
//
//  Both fixes are demand-driven rather than faster polling — see
//  `scheduleRootFlush` in trace.ts for the request-volume argument.
// ============================================================================

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { beginFlow, __resetFlows } from './flows';
import { configureSink, __resetSink } from './sink';
import { __bufferedSpans, __resetTracer, configureTracer, startTrace, type WireSpan } from './trace';
import { seedPageLoadTrace } from './pageLoadJoin';

let sent: WireSpan[][] = [];
let listeners: Record<string, (() => void)[]> = {};

/** The minimum of `window` these two modules touch: timers and `pagehide`. */
function installWindow(): void {
  listeners = {};
  (globalThis as { window?: unknown }).window = {
    setTimeout: (fn: () => void, ms: number) => globalThis.setTimeout(fn, ms),
    clearTimeout: (id: number) => globalThis.clearTimeout(id),
    setInterval: (fn: () => void, ms: number) => globalThis.setInterval(fn, ms),
    clearInterval: (id: number) => globalThis.clearInterval(id),
    addEventListener: (name: string, fn: () => void) => {
      (listeners[name] ??= []).push(fn);
    },
  };
}

function fire(name: string): void {
  for (const fn of listeners[name] ?? []) fn();
}

beforeEach(() => {
  vi.useFakeTimers();
  __resetTracer();
  __resetFlows();
  __resetSink();
  sent = [];
  installWindow();
  configureTracer({ enabled: true, emit: (spans) => sent.push(spans) });
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
});

afterEach(() => {
  vi.useRealTimers();
  delete (globalThis as { window?: unknown }).window;
});

describe('a completed trace leaves the tab without waiting for the interval', () => {
  it('flushes when a ROOT span ends, long before the 20 s sink tick', () => {
    const root = startTrace('station.connect');
    root.end('ok');
    // Debounced, not synchronous: a burst of roots finishing together must
    // still leave as one batch.
    expect(sent).toHaveLength(0);
    vi.advanceTimersByTime(1_000);
    expect(sent).toHaveLength(1);
    expect(sent[0].map((s) => s.n)).toEqual(['station.connect']);
    expect(__bufferedSpans()).toHaveLength(0);
  });

  it('flushes a boot fetch that JOINED the page load, whose entry is not a root', () => {
    // THE REGRESSION THIS FILE EXISTS FOR, SECOND EDITION. The first fix keyed
    // the eager flush on `parentId === null`, which is exactly wrong for the
    // one burst that always needs it: while the page-load join is live,
    // `startTrace()` hangs the tab's entry off `serve.page`'s span id, so a
    // boot fetch's client span HAS a parent. Measured on the deployed build —
    // the `/gallery-manifest.json` and `/boot/index.json` client spans were
    // absent from the store 12 s after the load and present at 30 s: they
    // were waiting for the 20 s tick, and a visit shorter than that lost them
    // while the header naming them had already gone out.
    seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
    const entry = startTrace('http.client.request', { 'url.path': '/gallery-manifest.json' }, 'client');
    expect(entry.traceId).toBe('11111111111111111111111111111111');
    entry.end('ok');
    vi.advanceTimersByTime(1_000);
    expect(sent).toHaveLength(1);
    const [span] = sent[0];
    expect(span.n).toBe('http.client.request');
    expect(span.p).toBe('2222222222222222'); // NOT a root — that is the point
  });

  it('still coalesces a seeded boot burst into ONE request', () => {
    seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
    for (const path of ['/gallery-manifest.json', '/boot/index.json', '/auth/state']) {
      startTrace('http.client.request', { 'url.path': path }, 'client').end('ok');
    }
    vi.advanceTimersByTime(1_000);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toHaveLength(3);
  });

  it('does NOT flush for every child span — only a trace entry completes one', () => {
    const root = startTrace('station.connect');
    root.child('station.connect.transport').end('ok');
    vi.advanceTimersByTime(1_000);
    expect(sent).toHaveLength(0);
    expect(__bufferedSpans()).toHaveLength(1);
  });

  it('coalesces a burst of roots into ONE request', () => {
    for (let i = 0; i < 10; i += 1) startTrace(`input.edge.${i}`).end('ok');
    vi.advanceTimersByTime(1_000);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toHaveLength(10);
  });
});

describe('an open flow is abandoned on the way out, so its root is recorded', () => {
  it('pagehide ends every open flow root and flushes it', () => {
    beginFlow('station.connect');
    // Still open: nothing about the root has been buffered, and no amount of
    // interval-shortening could change that.
    expect(__bufferedSpans().some((s) => s.n === 'station.connect')).toBe(false);

    fire('pagehide');

    const flushed = sent.flat();
    const root = flushed.find((s) => s.n === 'station.connect');
    expect(root).toBeTruthy();
    expect(root!.p).toBeNull();
    expect(root!.a?.['kh.abandoned']).toBe(true);
    // `unset`, not `error`: navigating away is a drop-off, not a fault.
    expect(root!.k).toBe('unset');
  });

  it('leaves a flow alone while the tab is merely hidden', () => {
    const flow = beginFlow('station.connect');
    // The hook is deliberately pagehide-only (see flows.ts): a tab-switcher
    // comes back, and ending the flow here would swallow the `ok()` below.
    expect(listeners.visibilitychange ?? []).toHaveLength(0);
    flow.ok();
    vi.advanceTimersByTime(1_000);
    const root = sent.flat().find((s) => s.n === 'station.connect');
    expect(root?.k).toBe('ok');
    expect(root?.a?.['kh.abandoned']).toBeUndefined();
  });
});

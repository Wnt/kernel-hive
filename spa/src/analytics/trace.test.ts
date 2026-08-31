// Tests for the tracer. The theme is that a trace must describe what actually
// happened: ids that are really unique, parents that are really parents, a
// duration that includes the time a visitor sat waiting, and a span that ends
// exactly once however many code paths try to end it.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  __bufferedSpans, __resetTracer, childOfActive, configureTracer, currentSpan,
  flushSpans, newSpanId, newTraceId, popActive, pushActive, startTrace,
} from './trace';

let sent: unknown[][] = [];

beforeEach(() => {
  __resetTracer();
  sent = [];
  configureTracer({ enabled: true, emit: (s) => sent.push(s) });
});

afterEach(() => {
  delete (globalThis as { document?: unknown }).document;
});

describe('ids', () => {
  it('are W3C Trace Context shaped: 32 and 16 lowercase hex', () => {
    expect(newTraceId()).toMatch(/^[0-9a-f]{32}$/);
    expect(newSpanId()).toMatch(/^[0-9a-f]{16}$/);
  });

  it('do not repeat', () => {
    const ids = new Set(Array.from({ length: 500 }, () => newTraceId()));
    expect(ids.size).toBe(500);
  });
});

describe('spans', () => {
  it('a root and its children share one trace id', () => {
    const root = startTrace('station.connect');
    const child = root.child('step');
    const grand = child.child('deeper');
    expect(child.traceId).toBe(root.traceId);
    expect(grand.traceId).toBe(root.traceId);
    expect(child.spanId).not.toBe(root.spanId);
  });

  it('records parentage on the wire, and null for a root', () => {
    const root = startTrace('r');
    const child = root.child('c');
    child.end('ok');
    root.end('ok');
    const [c, r] = __bufferedSpans();
    expect(c.p).toBe(root.spanId);
    expect(r.p).toBeNull();
  });

  it('ends exactly once — a fail then an ok is one span, still failed', () => {
    const s = startTrace('r');
    s.end('error');
    s.end('ok');
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(1);
    expect(spans[0].k).toBe('error');
  });

  it('carries OTel kind and status message', () => {
    const s = startTrace('r', undefined, 'client');
    s.end('error', undefined, 'gave up');
    expect(__bufferedSpans()[0].kd).toBe('client');
    expect(__bufferedSpans()[0].m).toBe('gave up');
  });

  it('defaults to `unset`, which is not the same as ok', () => {
    startTrace('r').end();
    expect(__bufferedSpans()[0].k).toBe('unset');
  });
});

describe('attributes and events', () => {
  it('keeps strings, numbers and booleans and drops anything else', () => {
    const s = startTrace('r', { a: 'x', b: 2, c: true });
    (s as unknown as { attr(k: string, v: unknown): void }).attr('d', { nested: 1 });
    s.end('ok');
    expect(__bufferedSpans()[0].a).toEqual({ a: 'x', b: 2, c: true });
  });

  it('truncates a long attribute rather than carrying a payload', () => {
    const s = startTrace('r', { long: 'x'.repeat(500) });
    s.end('ok');
    expect((__bufferedSpans()[0].a!.long as string).length).toBeLessThanOrEqual(120);
  });

  it('records an exception as an OTel event AND sets error.type', () => {
    const s = startTrace('r');
    s.recordException(new TypeError('bad thing'));
    s.end('error');
    const span = __bufferedSpans()[0];
    expect(span.e?.[0].n).toBe('exception');
    expect(span.e?.[0].a).toMatchObject({
      'exception.type': 'TypeError',
      'exception.message': 'bad thing',
    });
    expect(span.a!['error.type']).toBe('TypeError');
  });

  it('never attaches a stacktrace — stacks belong to /clientlog', () => {
    const s = startTrace('r');
    s.recordException(new Error('boom'));
    s.end('error');
    const json = JSON.stringify(__bufferedSpans()[0]);
    expect(json).not.toContain('stacktrace');
    expect(json).not.toContain('at Object');
  });

  it('ignores attributes and events added after the span ended', () => {
    const s = startTrace('r');
    s.end('ok');
    s.event('late');
    (s as unknown as { attr(k: string, v: unknown): void }).attr('late', 1);
    expect(__bufferedSpans()[0].e).toBeUndefined();
  });
});

describe('hidden time', () => {
  it('reports how much of the span the tab was hidden for, without shortening it', () => {
    // A flame graph that hid time would be lying about what the visitor sat
    // through, so `d` stays wall-clock and `h` says how much of it was hidden.
    const listeners: Array<() => void> = [];
    const doc = {
      visibilityState: 'visible',
      addEventListener: (_t: string, fn: () => void) => listeners.push(fn),
    };
    (globalThis as { document?: unknown }).document = doc;
    const s = startTrace('r');
    doc.visibilityState = 'hidden';
    for (const fn of listeners) fn();
    const until = Date.now() + 30;
    while (Date.now() < until) { /* burn a little real time while hidden */ }
    doc.visibilityState = 'visible';
    for (const fn of listeners) fn();
    s.end('ok');
    const span = __bufferedSpans()[0];
    expect(span.h).toBeGreaterThan(0);
    expect(span.d).toBeGreaterThanOrEqual(span.h);
  });
});

describe('the active stack', () => {
  it('childOfActive nests under the innermost active span', () => {
    const root = startTrace('r');
    pushActive(root);
    const child = childOfActive('c');
    expect(child.traceId).toBe(root.traceId);
    popActive(root);
    expect(currentSpan()).toBeNull();
  });

  it('starts a NEW trace when nothing is active, rather than orphaning a span', () => {
    const lone = childOfActive('lonely');
    lone.end('ok');
    expect(__bufferedSpans()[0].p).toBeNull();
    expect(__bufferedSpans()[0].t).toMatch(/^[0-9a-f]{32}$/);
  });

  it('pops a span from the middle — a flow outlives a timing opened inside it', () => {
    const a = startTrace('a');
    const b = startTrace('b');
    pushActive(a);
    pushActive(b);
    popActive(a);
    expect(currentSpan()).toBe(b);
  });
});

describe('the gate and the buffer', () => {
  it('buffers nothing at all until configured as enabled', () => {
    __resetTracer();
    startTrace('r').end('ok');
    expect(__bufferedSpans()).toEqual([]);
  });

  it('flush hands the buffer over and clears it', () => {
    startTrace('r').end('ok');
    flushSpans();
    expect(sent).toHaveLength(1);
    expect(__bufferedSpans()).toEqual([]);
  });

  it('flushing an empty buffer sends nothing', () => {
    flushSpans();
    expect(sent).toEqual([]);
  });
});

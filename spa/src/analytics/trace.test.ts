// Tests for the tracer. The theme is that a trace must describe what actually
// happened: ids that are really unique, parents that are really parents, a
// duration that includes the time a visitor sat waiting, and a span that ends
// exactly once however many code paths try to end it.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  __bufferedSpans, __resetTracer, childOfActive, configureTracer, currentSpan, emitSpan,
  flushSpans, newSpanId, newTraceId, popActive, pushActive, requeueSpans, startTrace,
} from './trace';
import { readPageLoadTraceFromMeta, parseTraceparent, seedPageLoadTrace } from './pageLoadLink';

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
    // `kh.page.loadId` rides every trace ENTRY since 2026-09-01 — the query
    // half of the page-load link (pageLoadLink.ts).
    const { 'kh.page.loadId': loadId, ...rest } = __bufferedSpans()[0].a!;
    expect(loadId).toMatch(/^[0-9a-f]{16}$/);
    expect(rest).toEqual({ a: 'x', b: 2, c: true });
  });

  it('bounds an ordinary attribute at 2 KiB — a runaway caller, not richness', () => {
    const s = startTrace('r', { long: 'x'.repeat(5000) });
    s.end('ok');
    expect((__bufferedSpans()[0].a!.long as string).length).toBe(2048);
  });

  it('gives a stack the long-value allowance instead of clipping it to a frame', () => {
    // The 2026-09-01 reversal: 120 chars was an AI-invented content rule and
    // it made every stack unreadable. docs/ANALYTICS.md §0.
    const stack = 'x'.repeat(9000);
    const s = startTrace('r', { 'exception.stacktrace': stack });
    s.end('ok');
    expect(__bufferedSpans()[0].a!['exception.stacktrace']).toBe(stack);
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

  it('attaches the stacktrace — a fault without one is a fault you go and look for', () => {
    const s = startTrace('r');
    s.recordException(new Error('boom'));
    s.end('error');
    const stack = __bufferedSpans()[0].e?.[0].a?.['exception.stacktrace'];
    expect(typeof stack).toBe('string');
    expect(stack as string).toContain('Error');
  });

  it('stamps the account identity on the span that ENTERS a trace, and only there', () => {
    configureTracer({
      enabled: true,
      emit: () => {},
      identity: { 'enduser.id': 'u-17', 'user.name': 'ada', 'enduser.role': 'viewer' },
    });
    const root = startTrace('r');
    const child = root.child('inner');
    child.end('ok');
    root.end('ok');
    const spans = __bufferedSpans();
    expect(spans[0].a?.['enduser.id']).toBeUndefined();   // the child
    expect(spans[1].a).toMatchObject({ 'enduser.id': 'u-17', 'user.name': 'ada' });
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

describe('the page-load LINK (docs/lab/TRACE-CONTEXT.md §4/§4a)', () => {
  const PAGE_TRACE = '11111111111111111111111111111111';
  const PAGE_SPAN = '2222222222222222';
  const TAG = `00-${PAGE_TRACE}-${PAGE_SPAN}-01`;

  it('parses a well-formed traceparent', () => {
    expect(parseTraceparent(TAG)).toEqual({ traceId: PAGE_TRACE, spanId: PAGE_SPAN });
  });

  it('rejects anything not exactly that shape', () => {
    expect(parseTraceparent(null)).toBeNull();
    expect(parseTraceparent(undefined)).toBeNull();
    expect(parseTraceparent('')).toBeNull();
    expect(parseTraceparent('not-a-traceparent')).toBeNull();
    expect(parseTraceparent(`01-${PAGE_TRACE}-${PAGE_SPAN}-01`)).toBeNull(); // wrong version
    expect(parseTraceparent(`00-1111-${PAGE_SPAN}-01`)).toBeNull(); // trace id too short
    expect(parseTraceparent(`00-${PAGE_TRACE},${PAGE_SPAN},01`)).toBeNull();
  });

  // THE SHAPE RULE, and the whole point of the 2026-09-01 change: a trace is
  // ONE ACTION. It used to be one VISIT — `startTrace` continued `serve.page`'s
  // trace inside a 15 s window, which produced a 43-span trace still taking
  // writes 74 s after it started, with five keystrokes as siblings under the
  // page span. The causal edge is now a LINK, which asserts "caused by" without
  // asserting "contained in".
  it('mints its OWN trace and LINKS the page load — never nests under it', () => {
    seedPageLoadTrace(TAG);
    const root = startTrace('station.connect');
    expect(root.traceId).not.toBe(PAGE_TRACE);
    expect(root.traceId).toMatch(/^[0-9a-f]{32}$/);
    root.end('ok');
    const [span] = __bufferedSpans();
    expect(span.p).toBeNull(); // a ROOT, always
    expect(span.l).toEqual([
      { t: PAGE_TRACE, s: PAGE_SPAN, a: { 'kh.link.kind': 'page.load' } },
    ]);
  });

  // The other half of the linking decision: a link is what a UI navigates, an
  // attribute is what a query GROUPS BY, and neither substitutes for the other.
  it('also stamps kh.page.loadId, so "everything on this page load" is one filter', () => {
    seedPageLoadTrace(TAG);
    const root = startTrace('station.connect');
    root.end('ok');
    const [span] = __bufferedSpans();
    expect(span.a?.['kh.page.loadId']).toMatch(/^[0-9a-f]{16}$/);
  });

  // No window and no count any more: a LINK stays true for the life of the JS
  // realm, where a JOIN went stale (a station opened ten minutes after boot did
  // not happen "inside" the page load). Two traces opened far apart are two
  // traces, and both still name the page they happened on.
  it('links every trace of the document, however late, and never merges them', () => {
    seedPageLoadTrace(TAG);
    const first = startTrace('station.connect');
    const second = startTrace('station.restore');
    expect(first.traceId).not.toBe(second.traceId);
    first.end('ok');
    second.end('ok');
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(2);
    for (const s of spans) {
      expect(s.p).toBeNull();
      expect(s.l?.[0].t).toBe(PAGE_TRACE);
      expect(s.a?.['kh.page.loadId']).toBeTruthy();
    }
  });

  it('a missing or malformed tag leaves a trace rooted and simply unlinked', () => {
    seedPageLoadTrace(null);
    const root = startTrace('station.connect');
    expect(root.traceId).toMatch(/^[0-9a-f]{32}$/);
    root.end('ok');
    expect(__bufferedSpans()[0].l).toBeUndefined();

    seedPageLoadTrace('garbage');
    const other = startTrace('station.connect');
    other.end('ok');
    expect(__bufferedSpans()[1].l).toBeUndefined();
  });

  it('readPageLoadTraceFromMeta reads the tag when present', () => {
    (globalThis as { document?: unknown }).document = {
      querySelector: (sel: string) =>
        sel === 'meta[name="traceparent"]' ? { getAttribute: () => TAG } : null,
    };
    readPageLoadTraceFromMeta();
    const root = startTrace('station.connect');
    root.end('ok');
    expect(__bufferedSpans()[0].l?.[0]).toEqual({
      t: PAGE_TRACE, s: PAGE_SPAN, a: { 'kh.link.kind': 'page.load' },
    });
  });

  it('readPageLoadTraceFromMeta is a graceful no-op with no tag, and with no document at all', () => {
    (globalThis as { document?: unknown }).document = { querySelector: () => null };
    expect(() => readPageLoadTraceFromMeta()).not.toThrow();
    const root = startTrace('station.connect');
    expect(root.traceId).toMatch(/^[0-9a-f]{32}$/);

    delete (globalThis as { document?: unknown }).document;
    expect(() => readPageLoadTraceFromMeta()).not.toThrow();
  });
});

describe('endAt — a duration learnt after the fact', () => {
  it('ends the span AT the reading the caller took, not at "now"', () => {
    const span = startTrace('input.edge', undefined, 'client');
    const at = performance.now();
    span.endAt(at, 'ok', { 'kh.input.answered': true });
    const [s] = __bufferedSpans();
    expect(s.k).toBe('ok');
    expect(s.a?.['kh.input.answered']).toBe(true);
    expect(s.d).toBeGreaterThanOrEqual(0);
  });

  it('clamps a reading from before the span started rather than reporting a negative', () => {
    const span = startTrace('input.edge', undefined, 'client');
    span.endAt(performance.now() - 10_000, 'ok');
    expect(__bufferedSpans()[0].d).toBe(0);
  });

  it('ends exactly once, whichever of end/endAt is called first', () => {
    const span = startTrace('input.edge', undefined, 'client');
    span.end('ok');
    span.endAt(performance.now(), 'error');
    expect(__bufferedSpans()).toHaveLength(1);
    expect(__bufferedSpans()[0].k).toBe('ok');
  });
});

// ---------------------------------------------------------------------------
// `/traces` requires an INTEGER `st` and drops anything else without a word
// (traces.py: `if not isinstance(started, int) ... continue`). `emitSpan`
// derives its start by subtracting two clocks, one of which is fractional, so
// the whole return leg was being refused at intake — 10 stored `client.frame.
// paint` spans against 407 daemon `transport.frame.next` spans over 24 h
// (measured 2026-09-01). Nothing reported it: the tab thought it had emitted.
// ---------------------------------------------------------------------------
describe('emitSpan start is storable', () => {
  it('emits a whole-millisecond start even from a fractional clock reading', () => {
    __resetTracer();
    configureTracer({ enabled: true, emit: () => {} });
    // A `performance.now()`-domain reading with a fraction, which is the
    // normal case: Chrome reports that clock at 100 us resolution.
    emitSpan('a'.repeat(32), 'b'.repeat(16), 'client.frame.paint', performance.now() - 3.7, 2.4);
    const buf = __bufferedSpans();
    const s = buf[buf.length - 1];
    expect(Number.isInteger(s.st)).toBe(true);
    expect(Number.isInteger(s.d)).toBe(true);
  });

  it('honours the span kind it is given, defaulting to internal', () => {
    __resetTracer();
    configureTracer({ enabled: true, emit: () => {} });
    emitSpan('a'.repeat(32), 'b'.repeat(16), 'client.input.roundtrip', 1, 1, undefined, 'ok', 'client');
    emitSpan('a'.repeat(32), 'b'.repeat(16), 'client.frame.decode', 1, 1);
    const spans = __bufferedSpans();
    expect(spans[spans.length - 2].kd).toBe('client');
    expect(spans[spans.length - 1].kd).toBe('internal');
  });
});

describe('requeueSpans — a batch that did not land is not deleted', () => {
  // `flushSpans` drains the buffer BEFORE the upload, so without this a failed
  // POST destroyed the batch in the tab. That is not a rounding error: the
  // batch carries the ROOT of a trace whose other half is already on its way
  // to the same store by an independent path, and the store can then never
  // draw the join. `analytics/beacon.ts` has the measured failure.
  it('puts a failed batch back at the front, oldest first', () => {
    const a = startTrace('one');
    a.end('ok');
    const batch = __bufferedSpans();
    flushSpans();
    expect(__bufferedSpans()).toEqual([]);

    const b = startTrace('two');
    b.end('ok');
    requeueSpans(batch);
    expect(__bufferedSpans().map((s) => s.n)).toEqual(['one', 'two']);
  });

  it('is a no-op for an empty batch and for a tracer that is off', () => {
    expect(() => requeueSpans([])).not.toThrow();
    const s = startTrace('one');
    s.end('ok');
    const batch = __bufferedSpans();
    flushSpans();
    __resetTracer();
    requeueSpans(batch);
    expect(__bufferedSpans()).toEqual([]);
  });
});

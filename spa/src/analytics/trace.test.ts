// Tests for the tracer. The theme is that a trace must describe what actually
// happened: ids that are really unique, parents that are really parents, a
// duration that includes the time a visitor sat waiting, and a span that ends
// exactly once however many code paths try to end it.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  __bufferedSpans, __resetTracer, childOfActive, configureTracer, currentSpan, emitSpan,
  flushSpans, newSpanId, newTraceId, popActive, pushActive, startTrace,
} from './trace';
import { joinPageLoadTraceFromMeta, parseTraceparent, seedPageLoadTrace } from './pageLoadJoin';

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

describe('the page-load join (docs/lab/TRACE-CONTEXT.md §4/§7)', () => {
  it('parses a well-formed traceparent', () => {
    expect(parseTraceparent('00-11111111111111111111111111111111-2222222222222222-01')).toEqual({
      traceId: '11111111111111111111111111111111'.slice(0, 32),
      spanId: '2222222222222222',
    });
  });

  it('rejects anything not exactly that shape', () => {
    expect(parseTraceparent(null)).toBeNull();
    expect(parseTraceparent(undefined)).toBeNull();
    expect(parseTraceparent('')).toBeNull();
    expect(parseTraceparent('not-a-traceparent')).toBeNull();
    expect(parseTraceparent('01-11111111111111111111111111111111-2222222222222222-01')).toBeNull(); // wrong version
    expect(parseTraceparent('00-1111-2222222222222222-01')).toBeNull(); // trace id too short
    expect(parseTraceparent('00-11111111111111111111111111111111,2222222222222222,01')).toBeNull();
  });

  it('the FIRST trace opened continues a seeded traceparent', () => {
    seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
    const root = startTrace('station.connect');
    expect(root.traceId).toBe('11111111111111111111111111111111'.slice(0, 32));
    expect(root.spanId).not.toBe('2222222222222222'); // a fresh child span id, not the server's own
    root.end('ok');
    expect(__bufferedSpans()[0].p).toBe('2222222222222222');
  });

  // DEFECT (the "ALSO" issue): a one-shot seed consumed by whichever
  // `startTrace()` fires first raced an incidental early fetch (khFetch's
  // implicit `childOfActive()` fallback, e.g. `/auth/state`) against the
  // visit's actual main flow (`station.connect`) for the ONE trace that got
  // to continue `serve.page` — live evidence: `serve.page` traces containing
  // `serve.auth.walkin.status`, `station.connect` traces as unrelated
  // singletons. Fixed: the seed is a page-scoped root BOTH callers hang off
  // as siblings, bounded by a window/count rather than consumed once.
  it('a SECOND trace opened soon after the first ALSO continues the page load, as a sibling — not a race one caller wins', () => {
    seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
    const early = startTrace('serve.auth.walkin.status'); // an incidental boot fetch
    const main = startTrace('station.connect'); // the visit's actual main flow
    expect(early.traceId).toBe('11111111111111111111111111111111'.slice(0, 32));
    expect(main.traceId).toBe('11111111111111111111111111111111'.slice(0, 32));
    expect(early.spanId).not.toBe(main.spanId); // distinct sibling spans
    early.end('ok');
    main.end('ok');
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(2);
    for (const s of spans) expect(s.p).toBe('2222222222222222');
  });

  it('stops joining once the join count bound is passed, minting a fresh unrelated trace', () => {
    seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
    const traceId = '11111111111111111111111111111111'.slice(0, 32);
    let last = startTrace('boot.burst');
    for (let i = 0; i < 40; i += 1) {
      last = startTrace('boot.burst');
    }
    // Well past PAGE_LOAD_JOIN_MAX (32): the bound must have kicked in.
    expect(last.traceId).not.toBe(traceId);
    expect(last.traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('stops joining once the time window has passed, minting a fresh unrelated trace', () => {
    const realNow = Date.now;
    try {
      let t = 1_000_000;
      Date.now = () => t;
      seedPageLoadTrace('00-11111111111111111111111111111111-2222222222222222-01');
      const early = startTrace('station.connect');
      expect(early.traceId).toBe('11111111111111111111111111111111'.slice(0, 32));
      t += 20_000; // past the 15s join window
      const late = startTrace('station.connect');
      expect(late.traceId).not.toBe(early.traceId);
    } finally {
      Date.now = realNow;
    }
  });

  it('a missing or malformed seed leaves the first trace exactly as before', () => {
    seedPageLoadTrace(null);
    const root = startTrace('station.connect');
    expect(root.traceId).toMatch(/^[0-9a-f]{32}$/);
    expect(__bufferedSpans()).toEqual([]); // not ended yet, just proving no throw

    seedPageLoadTrace('garbage');
    const other = startTrace('station.connect');
    expect(other.traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('joinPageLoadTraceFromMeta reads the tag when present', () => {
    (globalThis as { document?: unknown }).document = {
      querySelector: (sel: string) =>
        sel === 'meta[name="traceparent"]'
          ? { getAttribute: () => '00-11111111111111111111111111111111-2222222222222222-01' }
          : null,
    };
    joinPageLoadTraceFromMeta();
    const root = startTrace('station.connect');
    expect(root.traceId).toBe('11111111111111111111111111111111'.slice(0, 32));
  });

  it('joinPageLoadTraceFromMeta is a graceful no-op with no tag, and with no document at all', () => {
    (globalThis as { document?: unknown }).document = { querySelector: () => null };
    expect(() => joinPageLoadTraceFromMeta()).not.toThrow();
    const root = startTrace('station.connect');
    expect(root.traceId).toMatch(/^[0-9a-f]{32}$/);

    delete (globalThis as { document?: unknown }).document;
    expect(() => joinPageLoadTraceFromMeta()).not.toThrow();
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

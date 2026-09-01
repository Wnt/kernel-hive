// Tests for the stream event vocabulary: that each event reaches all four
// lanes, that it does NOT fire when it should not, that sampling is exactly
// what the taxonomy declares (and never applies to an error), and that the
// page binding is present on every one.
//
// The rule these exist to protect is the one that is easiest to break by
// accident: SAMPLING IS DECIDED ONCE. If probe, metric, span and vendor ever
// see different populations, every rate this plane reports becomes a number
// nobody can multiply back to a truth.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  STREAM_EVENTS, emitStreamEvent, __resetStreamEventSampling, type StreamEventSpec,
} from './streamEvents';
import { METRICS, PROBES } from './catalogue';
import { configureSink, __pendingBatch, __resetSink } from './sink';
import { __bufferedSpans, __resetTracer, configureTracer } from './trace';
import { __resetFlows } from './flows';
import { __resetIntent } from './intent';
import { __resetPageBinding } from './pageBinding';

type Call = [string, ...unknown[]];

/** `as const satisfies` narrows every row to its own literal type, which is
 *  exactly what makes the call sites type-safe and exactly what stops a loop
 *  over the table from seeing the optional fields. One widening, here. */
const SPECS = STREAM_EVENTS as unknown as Record<string, StreamEventSpec>;

function installIneum(): Call[] {
  const calls: Call[] = [];
  (globalThis as { window?: unknown }).window = {
    ineum: (...args: unknown[]) => { calls.push(args as Call); },
    location: { pathname: '/os/beos' },
  };
  return calls;
}

beforeEach(() => {
  __resetIntent();
  __resetFlows();
  __resetSink();
  __resetTracer();
  __resetStreamEventSampling();
  __resetPageBinding();
  configureTracer({ enabled: true, emit: () => {} });
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
});

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
});

describe('the taxonomy is a contract, not a suggestion', () => {
  it('declares a real probe for every event, and names the event after it', () => {
    for (const [name, spec] of Object.entries(SPECS)) {
      expect(PROBES[spec.probe], `${name} probe`).toBeDefined();
      // One vocabulary: the event name, the span name and the probe id are the
      // same string, so a query written against one works against all three.
      expect(spec.probe).toBe(name);
    }
  });

  it('declares a real metric wherever it declares a number', () => {
    for (const [name, spec] of Object.entries(SPECS)) {
      if (!spec.metric) continue;
      expect(METRICS[spec.metric], `${name} metric`).toBeDefined();
    }
  });

  it('never samples an error away', () => {
    for (const [name, spec] of Object.entries(SPECS)) {
      if (spec.status === 'error' || spec.reportsError) {
        expect(spec.sampleN, `${name} is an error and must be 1-in-1`).toBe(1);
      }
    }
  });

  it('finishes the two sentences every event owes', () => {
    for (const [name, spec] of Object.entries(SPECS)) {
      expect(spec.what.length, `${name}.what`).toBeGreaterThan(20);
      expect(spec.when.length, `${name}.when`).toBeGreaterThan(20);
      expect(spec.sampleN).toBeGreaterThanOrEqual(1);
    }
  });
});

describe('one emission, four lanes', () => {
  it('opens a span named for the event, counts a probe and buckets the metric', () => {
    emitStreamEvent('stream.quality.switch', {
      'kh.quality.tierFrom': 1,
      'kh.quality.tierTo': 3,
      'kh.quality.reason': 'down',
    }, 700);

    const spans = __bufferedSpans();
    expect(spans).toHaveLength(1);
    expect(spans[0].n).toBe('stream.quality.switch');
    expect(spans[0].kd).toBe('internal');
    expect(spans[0].a?.['kh.quality.reason']).toBe('down');
    // The number rides exact on the span AND bucketed in the aggregate.
    expect(spans[0].a?.['kh.metric.ms']).toBe(700);

    const batch = __pendingBatch();
    expect(batch.probes.some((p) => p.id === 'stream.quality.switch')).toBe(true);
    const metric = batch.metrics.find((m) => m.id === 'stream.quality.sinceLastSwitchMs');
    expect(metric?.bucket).toBe('800');
  });

  it('binds every event to the page and to this page load', () => {
    installIneum();
    emitStreamEvent('stream.transport.closed', { 'kh.transport.reason': 'server-finished' });
    const attrs = __bufferedSpans()[0].a ?? {};
    expect(attrs['kh.page.pattern']).toBe('/os/:osId');
    expect(String(attrs['kh.page.loadId'])).toMatch(/^[0-9a-f]{16}$/);
  });

  it('files an error-class event with errors.ts, so it groups and blames the open flow', () => {
    emitStreamEvent('stream.decode.error', {
      'error.type': 'EncodingError: no decoder',
      'kh.decode.consecutive': 2,
    }, 2);
    const errors = __pendingBatch().errors;
    expect(errors).toHaveLength(1);
    expect(errors[0].source).toBe('stream.decode.error');
    expect(__bufferedSpans()[0].k).toBe('error');
  });

  it('mirrors to Instana with the vendor call shape, once, with one number', () => {
    const calls = installIneum();
    emitStreamEvent('stream.decode.error', { 'error.type': 'X' }, 3);
    const reported = calls.filter((c) => c[0] === 'reportEvent');
    expect(reported).toHaveLength(1);
    const [, name, payload] = reported[0] as [string, string, Record<string, unknown>];
    expect(name).toBe('stream.decode.error');
    expect(payload.customMetric).toBe(3);
    expect((payload.meta as Record<string, string>)['error.type']).toBe('X');
  });

  it('emits nothing anywhere for an unknown event name', () => {
    installIneum();
    // Deliberately off-vocabulary: a typo must be silent, not a half-emission.
    emitStreamEvent('stream.not.a.real.event' as never, { a: 1 });
    expect(__bufferedSpans()).toHaveLength(0);
    expect(__pendingBatch().probes).toHaveLength(0);
  });

  it('drops a non-finite or negative number rather than bucketing a lie', () => {
    emitStreamEvent('stream.transport.retry', { 'kh.retry.attempt': 1 }, Number.NaN);
    expect(__pendingBatch().metrics).toHaveLength(0);
    // …and the event itself still lands: the number is optional, the fact is not.
    expect(__bufferedSpans()).toHaveLength(1);
  });
});

describe('sampling', () => {
  it('emits a 1-in-1 event every single time', () => {
    for (let i = 0; i < 5; i += 1) {
      emitStreamEvent('stream.transport.retry', { 'kh.retry.attempt': i }, i);
    }
    expect(__bufferedSpans()).toHaveLength(5);
  });

  it('emits a 1-in-N event exactly once per N, and nothing in between', () => {
    const n = STREAM_EVENTS['stream.keyframe.gap'].sampleN;
    expect(n).toBeGreaterThan(1);
    for (let i = 0; i < n - 1; i += 1) emitStreamEvent('stream.keyframe.gap', {}, 1);
    expect(__bufferedSpans()).toHaveLength(0);
    emitStreamEvent('stream.keyframe.gap', {}, 1);
    expect(__bufferedSpans()).toHaveLength(1);
    for (let i = 0; i < n; i += 1) emitStreamEvent('stream.keyframe.gap', {}, 1);
    expect(__bufferedSpans()).toHaveLength(2);
  });

  it('makes ONE decision: a sampled-away event reaches no lane at all', () => {
    const calls = installIneum();
    emitStreamEvent('stream.keyframe.gap', {}, 1);
    expect(__bufferedSpans()).toHaveLength(0);
    expect(__pendingBatch().probes).toHaveLength(0);
    expect(__pendingBatch().metrics).toHaveLength(0);
    expect(calls.filter((c) => c[0] === 'reportEvent')).toHaveLength(0);
  });

  it('stamps the rate on the event, so a count can be multiplied back', () => {
    const n = STREAM_EVENTS['stream.keyframe.gap'].sampleN;
    for (let i = 0; i < n; i += 1) emitStreamEvent('stream.keyframe.gap', {}, 1);
    expect(__bufferedSpans()[0].a?.['kh.sample.n']).toBe(n);
  });

  it('is the ONLY sampled event: everything else is an edge, not a level', () => {
    const sampled = Object.entries(SPECS)
      .filter(([, spec]) => spec.sampleN > 1)
      .map(([name]) => name);
    expect(sampled).toEqual(['stream.keyframe.gap']);
  });

  it('counts each event name separately, so a noisy one cannot starve a rare one', () => {
    for (let i = 0; i < 3; i += 1) emitStreamEvent('stream.keyframe.gap', {}, 1);
    emitStreamEvent('stream.decode.softwareLatched', { 'kh.decode.cause': 'silent-stall' });
    expect(__bufferedSpans().map((s) => s.n)).toEqual(['stream.decode.softwareLatched']);
  });
});

// The DECLARATIONS are validated against the real server-side rules by
// scripts/test_stream_event_intake.py. This validates the RUNTIME OUTPUT — the
// span each event actually produces — because the two can differ: the page
// binding, the sample stamp and the metric attribute are added by the emitter,
// not declared in the table, and it is those that push an event over a cap.
describe('what actually lands survives /traces intake', () => {
  // scripts/serve/traces.py, mirrored. Kept as literals rather than imported
  // (Python), and pinned on the Python side by that file's own tests.
  const NAME_RE = /^[A-Za-z][A-Za-z0-9._-]{0,79}$/;
  const ATTR_MAX = 24;
  const ATTR_STR_MAX = 120;
  const BANNED = new Set([
    'exception.stacktrace', 'code.stacktrace', 'url.full', 'url.query',
    'user.email', 'user.name', 'enduser.id',
  ]);

  it('emits a storable span for every event in the vocabulary', () => {
    (globalThis as { window?: unknown }).window = {
      location: { pathname: '/os/beos' },
      ineum: (verb: string) => (verb === 'getPageLoadId' ? 'vendor-load-1' : undefined),
    };
    for (const [name, spec] of Object.entries(SPECS)) {
      __resetStreamEventSampling();
      const attrs: Record<string, string | number | boolean> = {
        // Worst case: the station dimensions a real call site merges in.
        'kh.station.id': 'beos',
        'kh.station.emulatorFamily': 'qemu',
        'kh.station.ui': 'desktop',
        'kh.station.resetMode': 'loadvm',
      };
      for (const key of spec.attrs) attrs[key] = 'v';
      // The sampling counter starts at zero, so one call is enough for 1-in-1
      // and `sampleN` calls are enough for the sampled one.
      for (let i = 0; i < spec.sampleN; i += 1) emitStreamEvent(name as never, attrs, 42);
    }
    const spans = __bufferedSpans();
    expect(spans).toHaveLength(Object.keys(SPECS).length);
    for (const span of spans) {
      expect(span.n, span.n).toMatch(NAME_RE);
      const keys = Object.keys(span.a ?? {});
      expect(keys.length, `${span.n} attribute count`).toBeLessThanOrEqual(ATTR_MAX);
      for (const [k, v] of Object.entries(span.a ?? {})) {
        expect(BANNED.has(k), `${span.n} carries a banned attribute ${k}`).toBe(false);
        expect(k.length).toBeLessThanOrEqual(64);
        if (typeof v === 'string') expect(v.length).toBeLessThanOrEqual(ATTR_STR_MAX);
      }
      // The page binding must survive the cap on EVERY event — it is the
      // capability this whole design is built around.
      expect(keys, span.n).toContain('kh.page.pattern');
      expect(keys, span.n).toContain('kh.page.loadId');
    }
  });
});

describe('never throws into the app', () => {
  it('survives tracing being off, no window, and a hostile ineum', () => {
    __resetTracer();
    expect(() => emitStreamEvent('stream.audio.start', {}, 10)).not.toThrow();
    (globalThis as { window?: unknown }).window = {
      ineum: () => { throw new Error('vendor exploded'); },
    };
    configureTracer({ enabled: true, emit: () => {} });
    expect(() => emitStreamEvent('stream.audio.start', {}, 10)).not.toThrow();
  });
});

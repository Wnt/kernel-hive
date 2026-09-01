// Tests for the Instana mirror. Three of these exist because the vendor fails
// SILENTLY: a malformed backendTraceId is dropped with no error, a non-string
// meta value is stringified by the agent in whatever way it feels like, and a
// beacon over the metadata cap is truncated where you cannot see it. A test
// that only asserted "it called ineum" would pass on all three.

import { describe, expect, it, afterEach } from 'vitest';
import {
  BACKEND_TRACE_ID_RE, META_MAX_KEYS, mirrorStreamEventToInstana,
} from './instanaStreamEvents';
import { BACKEND_TRACE_ID_RE as INPUT_TRACE_RE } from '../three/streamClient/inputTrace';

type Call = [string, ...unknown[]];

function installIneum(): Call[] {
  const calls: Call[] = [];
  (globalThis as { window?: unknown }).window = {
    ineum: (...args: unknown[]) => { calls.push(args as Call); },
  };
  return calls;
}

function payloadOf(calls: Call[]): Record<string, unknown> {
  return calls[0][2] as Record<string, unknown>;
}

afterEach(() => { delete (globalThis as { window?: unknown }).window; });

const OK_TRACE = 'a'.repeat(32);

describe('the vendor rules that fail silently', () => {
  it('uses the identical backendTraceId rule inputTrace.ts established from the real bundle', () => {
    // Duplicated on purpose (analytics/ must not depend on three/), pinned here
    // so the copy cannot drift into sending values the agent discards.
    expect(BACKEND_TRACE_ID_RE.source).toBe(INPUT_TRACE_RE.source);
    expect(BACKEND_TRACE_ID_RE.flags).toBe(INPUT_TRACE_RE.flags);
  });

  it('sends the join only when the vendor would keep it — 16 or 32 hex', () => {
    for (const id of [OK_TRACE, 'b'.repeat(16)]) {
      const calls = installIneum();
      mirrorStreamEventToInstana({ name: 'x', timestamp: 1, backendTraceId: id, meta: {} });
      expect(payloadOf(calls).backendTraceId).toBe(id);
    }
  });

  it('drops the FIELD, not the event, when the id is unusable', () => {
    // Unlike inputTrace's beacon, where the join IS the point, a stream event
    // is worth reporting with or without one.
    for (const id of ['', 'zzzz', 'a'.repeat(31)]) {
      const calls = installIneum();
      mirrorStreamEventToInstana({ name: 'x', timestamp: 1, backendTraceId: id, meta: { a: 1 } });
      expect(calls).toHaveLength(1);
      expect(payloadOf(calls).backendTraceId).toBeUndefined();
    }
  });

  it('coerces every meta value to a string, because the agent takes strings only', () => {
    const calls = installIneum();
    mirrorStreamEventToInstana({
      name: 'x', timestamp: 1, backendTraceId: OK_TRACE,
      meta: { n: 3, b: true, s: 'text' },
    });
    expect(payloadOf(calls).meta).toEqual({ n: '3', b: 'true', s: 'text' });
  });

  it('caps meta at the vendor default rather than trusting it to stay true', () => {
    const calls = installIneum();
    const meta: Record<string, number> = {};
    for (let i = 0; i < META_MAX_KEYS + 10; i += 1) meta[`k${i}`] = i;
    mirrorStreamEventToInstana({ name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta });
    expect(Object.keys(payloadOf(calls).meta as object)).toHaveLength(META_MAX_KEYS);
    expect(payloadOf(calls).maxMetadataKeys).toBe(META_MAX_KEYS);
  });
});

describe('customMetric — one number, four decimals', () => {
  it('rounds to the precision the vendor keeps', () => {
    const calls = installIneum();
    mirrorStreamEventToInstana({
      name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta: {}, customMetric: 1.23456789,
    });
    expect(payloadOf(calls).customMetric).toBe(1.2346);
  });

  it('omits it entirely rather than inventing a zero', () => {
    for (const v of [undefined, Number.NaN, Number.POSITIVE_INFINITY]) {
      const calls = installIneum();
      mirrorStreamEventToInstana({
        name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta: {}, customMetric: v,
      });
      expect(payloadOf(calls)).not.toHaveProperty('customMetric');
    }
  });

  it('keeps a real zero, which is an observation and not a missing value', () => {
    const calls = installIneum();
    mirrorStreamEventToInstana({
      name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta: {}, customMetric: 0,
    });
    expect(payloadOf(calls).customMetric).toBe(0);
  });
});

describe('deletable, and never load-bearing', () => {
  it('is a silent no-op with no window.ineum — an unconfigured build', () => {
    expect(() => mirrorStreamEventToInstana({
      name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta: {},
    })).not.toThrow();
  });

  it('swallows a vendor that throws', () => {
    (globalThis as { window?: unknown }).window = {
      ineum: () => { throw new Error('vendor exploded'); },
    };
    expect(() => mirrorStreamEventToInstana({
      name: 'x', timestamp: 1, backendTraceId: OK_TRACE, meta: {},
    })).not.toThrow();
  });
});

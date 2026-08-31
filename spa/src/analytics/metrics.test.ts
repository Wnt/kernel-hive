// Tests for the metrics lane. Every one of these guards a way the report could
// state a confident number that is not true: a duration inflated by time the
// visitor was not looking, a zero invented by a torn-down effect, a stuck timer
// putting an hour-long tail on a durable distribution.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { bucketFor } from './catalogue';
import { recordMetric, startTiming, accumulator, __resetMetrics } from './metrics';
import { configureSink, __pendingBatch, __resetSink } from './sink';

/** A `document` stand-in — the tests run under plain Node (vitest.config.ts),
 *  so the visibility machinery has nothing to listen to unless we supply it. */
function installDocument(state: 'visible' | 'hidden') {
  const listeners: Array<() => void> = [];
  const doc = {
    visibilityState: state,
    addEventListener: (_type: string, fn: () => void) => { listeners.push(fn); },
  };
  (globalThis as { document?: unknown }).document = doc;
  return {
    /** Flip visibility and fire the event, as a browser would. */
    set(next: 'visible' | 'hidden') {
      doc.visibilityState = next;
      for (const fn of listeners) fn();
    },
  };
}

beforeEach(() => {
  __resetMetrics();
  __resetSink();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
});

afterEach(() => {
  delete (globalThis as { document?: unknown }).document;
});

/** The metric ids used below must be real, because recordMetric refuses an
 *  undeclared one — which is itself the first thing worth asserting. */
const A_MS = 'station.open.toFirstFrameMs';
const A_COUNT = 'fleet.find.hScrollScreens';

describe('bucketing', () => {
  it('lands a value in the first bucket whose edge is >= it', () => {
    expect(bucketFor('ms', 0)).toBe('50');
    expect(bucketFor('ms', 50)).toBe('50');
    expect(bucketFor('ms', 51)).toBe('100');
    expect(bucketFor('ms', 3200)).toBe('3200');
  });

  it('overflows to `inf` rather than inventing a top bucket', () => {
    expect(bucketFor('ms', 999_999)).toBe('inf');
    expect(bucketFor('count', 10_000)).toBe('inf');
  });

  it('names buckets by EDGE, so a ladder change cannot rewrite history', () => {
    // The stored name is the edge itself; nothing here is an index into a
    // ladder that a later edit could re-point.
    expect(bucketFor('pct', 45)).toBe('50');
    expect(Number.isNaN(Number(bucketFor('pct', 45)))).toBe(false);
  });
});

describe('recordMetric', () => {
  it('refuses an id the catalogue does not declare', () => {
    recordMetric('nope.not.real' as never, 100);
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('drops a negative value instead of clamping it to a fast sample', () => {
    recordMetric(A_MS, -5);
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('drops a non-finite value', () => {
    recordMetric(A_MS, Number.NaN);
    recordMetric(A_MS, Number.POSITIVE_INFINITY);
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('refuses an absurd duration rather than parking it in `inf` forever', () => {
    // A stuck timer is a call-site bug, and letting it land would leave a
    // permanent fictional tail on a distribution kept for years.
    recordMetric(A_MS, 7_200_000);
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('folds repeat samples in one bucket into a single counted row', () => {
    for (let i = 0; i < 4; i += 1) recordMetric(A_MS, 120);
    expect(__pendingBatch().metrics).toEqual([{ id: A_MS, bucket: '200', n: 4 }]);
  });
});

describe('timings', () => {
  it('records on stop, and only once', () => {
    installDocument('visible');
    const t = startTiming(A_MS);
    t.stop();
    t.stop();
    expect(__pendingBatch().metrics).toHaveLength(1);
    expect(__pendingBatch().metrics[0].n).toBe(1);
  });

  it('abandon() records NOTHING — an abandoned effect is not a zero', () => {
    installDocument('visible');
    const t = startTiming(A_MS);
    t.abandon();
    t.stop();
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('does not count time the tab was hidden', async () => {
    const doc = installDocument('visible');
    const t = startTiming(A_MS);
    doc.set('hidden');
    await new Promise((r) => setTimeout(r, 120));
    doc.set('visible');
    t.stop();
    // ~120 ms of real time elapsed, none of it visible, so the sample must land
    // in the smallest bucket rather than the 200 ms one.
    expect(__pendingBatch().metrics[0].bucket).toBe('50');
  });

  it('starts banked at zero when the tab is already hidden', async () => {
    const doc = installDocument('hidden');
    const t = startTiming(A_MS);
    await new Promise((r) => setTimeout(r, 120));
    doc.set('visible');
    t.stop();
    expect(__pendingBatch().metrics[0].bucket).toBe('50');
  });

  it('refuses to time a metric that is not on the ms scale', () => {
    const t = startTiming(A_COUNT);
    t.stop();
    expect(__pendingBatch().metrics).toEqual([]);
  });
});

describe('effort accumulators', () => {
  it('reports one total per episode, not one sample per event', () => {
    const acc = accumulator(A_COUNT);
    acc.add(3);
    acc.add(5);
    acc.commit();
    expect(__pendingBatch().metrics).toEqual([{ id: A_COUNT, bucket: '8', n: 1 }]);
  });

  it('records a ZERO-effort episode — finding it without scrolling is the win', () => {
    const acc = accumulator(A_COUNT);
    acc.commit();
    expect(__pendingBatch().metrics).toEqual([{ id: A_COUNT, bucket: '1', n: 1 }]);
  });

  it('commits once; a second commit and later adds are ignored', () => {
    const acc = accumulator(A_COUNT);
    acc.add(2);
    acc.commit();
    acc.add(100);
    acc.commit();
    expect(__pendingBatch().metrics).toEqual([{ id: A_COUNT, bucket: '2', n: 1 }]);
  });

  it('ignores nonsense increments rather than poisoning the total', () => {
    const acc = accumulator(A_COUNT);
    acc.add(Number.NaN);
    acc.add(-4);
    acc.add(2);
    acc.commit();
    expect(__pendingBatch().metrics).toEqual([{ id: A_COUNT, bucket: '2', n: 1 }]);
  });
});

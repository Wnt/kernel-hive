// Tests for the poster-reading episode. The rules worth guarding are the ones
// that decide whether a number means what its column heading says: what counts
// as a reversal (and what is trackpad noise), what "how far down they got"
// means for a reader who scrolled back up, and that a poster dismissed unread
// still reports — that sample IS the finding.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  beginPosterReadEpisode,
  createReversalCounter,
  scrollDepthPct,
} from './posterReadEpisode';
import { __resetMetrics } from '../analytics/metrics';
import { __resetFlows } from '../analytics/flows';
import { configureSink, __pendingBatch, __resetSink } from '../analytics/sink';

beforeEach(() => {
  __resetMetrics();
  __resetFlows();
  __resetSink();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
  (globalThis as { document?: unknown }).document = {
    visibilityState: 'visible',
    addEventListener: () => {},
  };
});

afterEach(() => {
  delete (globalThis as { document?: unknown }).document;
});

function metric(id: string) {
  return __pendingBatch().metrics.filter((row) => row.id === id);
}

describe('the reversal counter', () => {
  it('does not count a straight read as a reversal', () => {
    const c = createReversalCounter(24);
    let n = 0;
    for (let i = 0; i < 10; i += 1) if (c.push(60)) n += 1;
    expect(n).toBe(0);
  });

  it('counts one turn as one reversal, not one per event after it', () => {
    const c = createReversalCounter(24);
    let n = 0;
    for (const d of [60, 60, -60, -60, -60]) if (c.push(d)) n += 1;
    expect(n).toBe(1);
  });

  it('counts a genuine re-read: down, back up, down again', () => {
    const c = createReversalCounter(24);
    let n = 0;
    for (const d of [100, 100, -80, -80, 100, 100]) if (c.push(d)) n += 1;
    expect(n).toBe(2);
  });

  it('IGNORES jitter below the threshold — trackpad noise is not re-reading', () => {
    // Momentum wobble and a rubber-band bounce: contrary deltas of a few px
    // that never add up to a movement anybody made on purpose. Counting these
    // would make every poster look re-read and the column would be noise.
    const c = createReversalCounter(24);
    let n = 0;
    for (const d of [100, 100, -3, 2, -4, 3, -2, 100]) if (c.push(d)) n += 1;
    expect(n).toBe(0);
  });

  it('accumulates small contrary moves into one reversal once they add up', () => {
    // Deliberate but slow: eight 5 px steps back up IS going back up.
    const c = createReversalCounter(24);
    let n = 0;
    for (const d of [100, 100]) c.push(d);
    for (let i = 0; i < 8; i += 1) if (c.push(-5)) n += 1;
    expect(n).toBe(1);
  });

  it('needs a real first move before any direction is established', () => {
    // Jitter at the top of the poster must not establish "up" and turn the
    // first genuine downward scroll into a reversal.
    const c = createReversalCounter(24);
    let n = 0;
    for (const d of [-2, 3, -1, 100, 100]) if (c.push(d)) n += 1;
    expect(n).toBe(0);
  });

  it('ignores zero and non-finite deltas rather than treating them as a turn', () => {
    const c = createReversalCounter(24);
    expect(c.push(0)).toBe(false);
    expect(c.push(Number.NaN)).toBe(false);
    expect(c.push(Number.POSITIVE_INFINITY)).toBe(false);
  });
});

describe('scroll depth', () => {
  it('is the BOTTOM of the viewport, so reaching the end reads 100', () => {
    expect(scrollDepthPct(0, 500, 2000)).toBe(25);
    expect(scrollDepthPct(1500, 500, 2000)).toBe(100);
  });

  it('reports 100 for a poster shorter than the viewport', () => {
    // There was never anything below the fold; see the note in the module.
    expect(scrollDepthPct(0, 800, 400)).toBe(100);
  });

  it('clamps an overscroll bounce instead of reporting 104%', () => {
    expect(scrollDepthPct(1700, 500, 2000)).toBe(100);
  });
});

describe('a reading episode', () => {
  it('reports the DEEPEST depth, not where they happened to stop', () => {
    // A reader who reaches the end and scrolls back up to re-read a paragraph
    // read the whole thing; scoring them on their final position would file the
    // most engaged visit in the repo as an abandonment.
    const ep = beginPosterReadEpisode();
    ep.scrolled(1500, 500, 2000);
    ep.scrolled(200, 500, 2000);
    ep.end();
    expect(metric('poster.read.scrollDepthPct')).toEqual([
      { id: 'poster.read.scrollDepthPct', bucket: '100', n: 1 },
    ]);
  });

  it('reports a poster opened and dismissed UNREAD — that sample is the point', () => {
    const ep = beginPosterReadEpisode();
    ep.end();
    expect(metric('poster.read.scrollDepthPct')).toHaveLength(1);
    expect(metric('poster.read.scrollReversals')).toEqual([
      { id: 'poster.read.scrollReversals', bucket: '1', n: 1 },
    ]);
    // The dwell is stopped, not abandoned: half a second of it is exactly what
    // "opened it and did not read it" looks like.
    expect(metric('poster.read.dwellMs')).toHaveLength(1);
  });

  it('is one episode and one sample however many scroll events arrive', () => {
    const ep = beginPosterReadEpisode();
    for (let top = 0; top < 1500; top += 50) ep.scrolled(top, 500, 2000);
    ep.end();
    expect(metric('poster.read.scrollDepthPct')).toHaveLength(1);
    expect(metric('poster.read.scrollReversals')).toHaveLength(1);
  });

  it('settles once; a second end() reports nothing more', () => {
    const ep = beginPosterReadEpisode();
    ep.end();
    ep.end();
    ep.scrolled(1500, 500, 2000);
    expect(metric('poster.read.scrollDepthPct')).toHaveLength(1);
    expect(metric('poster.read.dwellMs')).toHaveLength(1);
  });

  it('walks the funnel: open -> scrolled -> reachedEnd', () => {
    const ep = beginPosterReadEpisode();
    ep.scrolled(200, 500, 2000);
    ep.scrolled(1500, 500, 2000);
    ep.end();
    const steps = __pendingBatch().flows.filter((f) => f.flow === 'poster.read');
    expect(steps.map((f) => `${f.step}:${f.outcome}`)).toEqual([
      'open:enter',
      'scrolled:enter',
      'reachedEnd:enter',
      'reachedEnd:ok',
    ]);
  });

  it('does not complete the funnel for a reader who stops part way', () => {
    // The drop-off IS the abandonment; nothing here synthesises a failure.
    const ep = beginPosterReadEpisode();
    ep.scrolled(200, 500, 2000);
    ep.end();
    const steps = __pendingBatch().flows.filter((f) => f.flow === 'poster.read');
    expect(steps.some((f) => f.outcome === 'ok' || f.outcome === 'fail')).toBe(false);
    expect(steps.some((f) => f.step === 'reachedEnd')).toBe(false);
  });
});

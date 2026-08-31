// Tests for the hall episode. The load-bearing rule here is what "approached"
// counts as — a DISTINCT machine that reached the scene's own active-focus
// state and was not opened. Every test below is a way that count could quietly
// come to mean something else, and each of those would be read as "the placards
// are failing" when it was the metric that failed.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  beginHallEpisode,
  endHallEpisode,
  noteHallApproach,
  noteHallOpen,
  __resetHallEngagement,
} from './hallEngagement';
import { __resetMetrics } from '../analytics/metrics';
import { __resetFlows } from '../analytics/flows';
import { configureSink, __pendingBatch, __resetSink } from '../analytics/sink';

beforeEach(() => {
  __resetHallEngagement();
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
  __resetHallEngagement();
  delete (globalThis as { document?: unknown }).document;
});

const APPROACHED = 'hall.navigate.stationsApproached';

function approachedBucket(): string | undefined {
  return __pendingBatch().metrics.find((m) => m.id === APPROACHED)?.bucket;
}

function hallFlow() {
  return __pendingBatch().flows.filter((f) => f.flow === 'hall.navigate');
}

describe('approached-but-not-opened', () => {
  it('counts each machine ONCE however often the camera drifts back to it', () => {
    // A visitor rocking between two desks approached two machines, not nine.
    beginHallEpisode();
    for (const id of ['beos', 'irix', 'beos', 'irix', 'beos']) noteHallApproach(id);
    endHallEpisode();
    expect(approachedBucket()).toBe('2');
  });

  it('takes the OPENED machine out of the count', () => {
    // Three approached, one of them opened: two were passed over.
    beginHallEpisode();
    noteHallApproach('beos');
    noteHallApproach('irix');
    noteHallApproach('win95');
    noteHallOpen('win95');
    endHallEpisode();
    expect(approachedBucket()).toBe('2');
  });

  it('commits a ZERO for the visitor who walked straight to a machine', () => {
    // Zero is the outcome the hall is FOR, and dropping it would leave a
    // distribution made only of the visitors who wandered.
    beginHallEpisode();
    noteHallApproach('beos');
    noteHallOpen('beos');
    endHallEpisode();
    expect(approachedBucket()).toBe('1'); // the count ladder's floor bucket
  });

  it('commits for a visitor who never got near anything either', () => {
    beginHallEpisode();
    endHallEpisode();
    expect(approachedBucket()).toBe('1');
  });

  it('ignores an approach reported with no hall open', () => {
    noteHallApproach('beos');
    noteHallOpen('beos');
    endHallEpisode();
    expect(__pendingBatch().metrics).toEqual([]);
  });
});

describe('the hall funnel and its timing', () => {
  it('walks enter -> approach -> open and completes', () => {
    beginHallEpisode();
    noteHallApproach('beos');
    noteHallOpen('beos');
    endHallEpisode();
    expect(hallFlow().map((f) => `${f.step}:${f.outcome}`)).toEqual([
      'enter:enter',
      'approach:enter',
      'open:enter',
      'open:ok',
    ]);
  });

  it('records a time to first station only when one is opened', () => {
    beginHallEpisode();
    noteHallOpen('beos');
    endHallEpisode();
    expect(__pendingBatch().metrics.some((m) => m.id === 'hall.navigate.toFirstStationMs')).toBe(true);
  });

  it('ABANDONS the timing for a visitor who never opened one — not a zero', () => {
    // A hall wandered and left has no time-to-first-station. Recording the
    // wander as one would put the hall's failures in the same distribution as
    // its successes; the funnel's drop-off is the number for "they never did".
    beginHallEpisode();
    noteHallApproach('beos');
    endHallEpisode();
    expect(__pendingBatch().metrics.some((m) => m.id === 'hall.navigate.toFirstStationMs')).toBe(false);
    expect(hallFlow().some((f) => f.outcome === 'ok' || f.outcome === 'fail')).toBe(false);
  });

  it('does not stack a second episode on a double mount (StrictMode)', () => {
    beginHallEpisode();
    beginHallEpisode();
    endHallEpisode();
    expect(hallFlow().filter((f) => f.step === 'enter')).toHaveLength(1);
    expect(__pendingBatch().metrics.filter((m) => m.id === APPROACHED)).toHaveLength(1);
  });

  it('settles once; a second end reports nothing more', () => {
    beginHallEpisode();
    endHallEpisode();
    endHallEpisode();
    expect(__pendingBatch().metrics.filter((m) => m.id === APPROACHED)).toHaveLength(1);
  });
});

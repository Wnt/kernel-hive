// Tests for the fleet-table episode. Two rules carry the meaning of these
// numbers: `toFirstActionMs` is only recorded when there WAS a first action,
// and `actionsToStation` is only recorded when a station was actually opened.
// Break either and the distribution quietly starts describing the visits that
// gave up alongside the ones that succeeded.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { beginFleetFindEpisode } from './fleetFindEpisode';
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

const ACTIONS = 'fleet.find.actionsToStation';
const HESITATION = 'fleet.find.toFirstActionMs';

function metric(id: string) {
  return __pendingBatch().metrics.filter((m) => m.id === id);
}

function findFlow() {
  return __pendingBatch().flows.filter((f) => f.flow === 'fleet.find');
}

describe('steps to a station', () => {
  it('counts each narrowing act once and reports one total', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.narrowed();
    ep.narrowed();
    ep.choseStation();
    ep.end();
    expect(metric(ACTIONS)).toEqual([{ id: ACTIONS, bucket: '3', n: 1 }]);
  });

  it('records the ZERO — the default order answered the question', () => {
    const ep = beginFleetFindEpisode();
    ep.choseStation();
    ep.end();
    expect(metric(ACTIONS)).toHaveLength(1);
  });

  it('records NOTHING when no station was ever opened', () => {
    // This is steps-to-GOAL. A visit that never reached the goal has no step
    // count for it, and committing one would blend "nine sorts to find it" with
    // "gave up after nine sorts" — opposite findings in one bucket.
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.narrowed();
    ep.end();
    expect(metric(ACTIONS)).toEqual([]);
  });

  it('ignores acts after the station was chosen, and a second choice', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.choseStation();
    ep.narrowed();
    ep.choseStation();
    ep.end();
    expect(metric(ACTIONS)).toEqual([{ id: ACTIONS, bucket: '1', n: 1 }]);
  });
});

describe('time to the first action', () => {
  it('is recorded when they finally do something', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.end();
    expect(metric(HESITATION)).toHaveLength(1);
  });

  it('is recorded once, on the FIRST act only', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.narrowed();
    ep.end();
    expect(metric(HESITATION)).toHaveLength(1);
    expect(metric(HESITATION)[0].n).toBe(1);
  });

  it('is ABANDONED, not zeroed, for a visit that never acted', () => {
    const ep = beginFleetFindEpisode();
    ep.end();
    expect(metric(HESITATION)).toEqual([]);
  });

  it('is abandoned for a visit that opened a machine without narrowing', () => {
    // There was no first NARROWING action, so there is no hesitation time —
    // and this is the fastest, best visit in the set, which is exactly the one
    // a spurious zero would be mistaken for.
    const ep = beginFleetFindEpisode();
    ep.choseStation();
    ep.end();
    expect(metric(HESITATION)).toEqual([]);
  });
});

describe('the funnel', () => {
  it('walks open -> narrow -> chooseStation and completes', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.choseStation();
    ep.end();
    expect(findFlow().map((f) => `${f.step}:${f.outcome}`)).toEqual([
      'open:enter',
      'narrow:enter',
      'chooseStation:enter',
      'chooseStation:ok',
    ]);
  });

  it('leaves an abandoned visit as a drop-off, never a failure', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.end();
    expect(findFlow().some((f) => f.outcome === 'fail')).toBe(false);
    expect(findFlow().some((f) => f.outcome === 'ok')).toBe(false);
  });

  it('settles once; a second end() changes nothing', () => {
    const ep = beginFleetFindEpisode();
    ep.narrowed();
    ep.end();
    ep.end();
    ep.narrowed();
    expect(metric(HESITATION)).toHaveLength(1);
    expect(findFlow().filter((f) => f.step === 'narrow')).toHaveLength(1);
  });
});

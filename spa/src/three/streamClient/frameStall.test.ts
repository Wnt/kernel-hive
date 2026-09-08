// Tests for the heartbeat-derived idle-frame-stall watchdog threshold. The
// load-bearing one is the ordering invariant: the DETECTOR must latch strictly
// before the reconnect-staleness window drops the session, for EVERY heartbeat
// — otherwise the watchdog and the drop race on the same tick and the "detector
// sits below the drop" contract (constants.ts / abr.ts) is a fiction.

import { describe, expect, it } from 'vitest';
import { frameStallMsFor } from './frameStall';
import {
  FRAME_STALL_MS, MIN_SESSION_STALE_MS, MAX_SESSION_STALE_MS,
} from './constants';

/** The reconnect-staleness window, replicated verbatim from abr.ts (the SAME
 *  keyframeMs expression drives both there). If abr.ts's staleMs formula
 *  changes, this must change with it — that is the point of asserting them
 *  together. */
function staleMsFor(keyframeMs: number): number {
  return Math.min(
    MAX_SESSION_STALE_MS,
    Math.max(MIN_SESSION_STALE_MS, keyframeMs * 2 + 3000),
  );
}

// A healthy heartbeat and beyond, plus the extremes where the two clamps bite.
const HEARTBEATS = [0, 500, 1000, 2500, 4000, 8000, 11000, 12000, 100000];

describe('frameStallMsFor', () => {
  it('derives the threshold from the station heartbeat — a healthy gap no longer latches', () => {
    // keyframeMs*2 + 1000, same shape as stallWatch.ts's stallThresholdMs.
    expect(frameStallMsFor(2500)).toBe(6000);
    // The whole point: a default-heartbeat repaint gap (2500 ms) is now BELOW
    // the threshold, so a perfectly static desktop stops false-latching.
    expect(frameStallMsFor(2500)).toBeGreaterThan(2500);
  });

  it('is floored at FRAME_STALL_MS for a fast/short/zero heartbeat', () => {
    expect(frameStallMsFor(0)).toBe(FRAME_STALL_MS);   // 2000, not 1000
    expect(frameStallMsFor(500)).toBe(FRAME_STALL_MS); // 500*2+1000 == 2000
    expect(frameStallMsFor(1000)).toBe(3000);
  });

  it('caps a nonsense heartbeat strictly below MAX_SESSION_STALE_MS', () => {
    const ceil = frameStallMsFor(100000);
    expect(ceil).toBe(MAX_SESSION_STALE_MS - 2000); // 23000
    expect(ceil).toBeLessThan(MAX_SESSION_STALE_MS);
  });

  it('INVARIANT: latches strictly before the reconnect staleness window for every heartbeat', () => {
    for (const kf of HEARTBEATS) {
      expect(frameStallMsFor(kf)).toBeLessThan(staleMsFor(kf));
    }
  });

  it('is monotonic non-decreasing and never below the floor', () => {
    let prev = -Infinity;
    for (let kf = 0; kf <= 30000; kf += 250) {
      const v = frameStallMsFor(kf);
      expect(v).toBeGreaterThanOrEqual(FRAME_STALL_MS);
      expect(v).toBeGreaterThanOrEqual(prev);
      prev = v;
    }
  });
});

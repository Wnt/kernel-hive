// A budget that counts past its own maximum is not a budget. These pin the
// field log that exposed it: attempt=5/4, 6/4, 7/4, 8/4 — forever, silently.
import { describe, expect, it } from 'vitest';
import {
  consumeRetry, retryLimit, MAX_COLD_ATTEMPTS, MAX_RELIVE_ATTEMPTS,
  keyframeWaitMs,
  KEYFRAME_WAIT_MS,
  RELIVE_KEYFRAME_WAIT_MS,
} from './retryBudget';

describe('retryLimit', () => {
  it('gives a proven-live session a longer ladder than a cold connect', () => {
    expect(retryLimit(false)).toBe(MAX_COLD_ATTEMPTS);
    expect(retryLimit(true)).toBe(MAX_RELIVE_ATTEMPTS);
    expect(MAX_RELIVE_ATTEMPTS).toBeGreaterThan(MAX_COLD_ATTEMPTS);
  });
});

describe('consumeRetry', () => {
  it('counts up to the cold limit and then exhausts', () => {
    expect(consumeRetry(0, false)).toEqual({ attempt: 1, limit: 4, exhausted: false });
    expect(consumeRetry(2, false)).toEqual({ attempt: 3, limit: 4, exhausted: false });
    expect(consumeRetry(3, false)).toEqual({ attempt: 4, limit: 4, exhausted: true });
  });

  it('TERMINATES a post-live ladder instead of running forever', () => {
    // The old code exhausted only when !liveReached, so this ran without end.
    expect(consumeRetry(4, true).exhausted).toBe(false);
    expect(consumeRetry(MAX_RELIVE_ATTEMPTS - 1, true).exhausted).toBe(true);
  });

  it('NEVER reports an attempt above its limit (the attempt=8/4 log)', () => {
    for (const prev of [4, 5, 6, 7, 8, 99]) {
      const v = consumeRetry(prev, false);
      expect(v.attempt).toBeLessThanOrEqual(v.limit);
      expect(v.exhausted).toBe(true);
    }
    expect(consumeRetry(99, true).attempt).toBe(MAX_RELIVE_ATTEMPTS);
  });

  it('treats a negative/garbage counter as a fresh ladder', () => {
    expect(consumeRetry(-3, false).attempt).toBe(1);
  });
});

describe('keyframeWaitMs — what THIS attempt may wait for frame #1', () => {
  it('gives a cold connect the full budget', () => {
    expect(keyframeWaitMs({ restore: false, live: false })).toBe(KEYFRAME_WAIT_MS);
  });

  it('gives a proven-live reconnect the short one', () => {
    expect(keyframeWaitMs({ restore: false, live: true })).toBe(RELIVE_KEYFRAME_WAIT_MS);
  });

  it('treats a RESTORE as cold even though the station was live', () => {
    // The 2026-09-02 sim reading: the first post-restore attempt was abandoned
    // at RELIVE_KEYFRAME_WAIT_MS (3 s) every single time, and the ladder then
    // spent 250/500/1000/2000 ms of restore backoff on top — "still mid
    // stream.recover up to ~17 s after the click". loadvm is simply slower.
    const restore = keyframeWaitMs({ restore: true, live: true });
    expect(restore).toBeGreaterThan(RELIVE_KEYFRAME_WAIT_MS);
    expect(restore).toBe(keyframeWaitMs({ restore: true, live: false }));
  });
});

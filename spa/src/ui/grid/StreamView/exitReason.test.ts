import { describe, expect, it } from 'vitest';
import { exitReasonCopy } from './exitReason';

describe('exitReasonCopy', () => {
  it('maps every known structured exit reason to human copy', () => {
    expect(exitReasonCopy('user-exit')).toBe('Session closed by you');
    expect(exitReasonCopy('transport-down')).toBe('Session ended — connection lost');
    expect(exitReasonCopy('ping-timeout')).toBe('Session ended — the tile stopped responding');
    expect(exitReasonCopy('stream-stalled')).toBe('Session ended — the video stream stalled');
    expect(exitReasonCopy('device-sleep')).toBe('Session paused — this device went to sleep');
    expect(exitReasonCopy('server-finished')).toBe('Session ended — the exhibit closed the stream');
  });

  it('returns null for null / undefined (no reason to show)', () => {
    expect(exitReasonCopy(null)).toBeNull();
    expect(exitReasonCopy(undefined)).toBeNull();
  });
});

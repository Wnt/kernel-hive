import { describe, expect, it } from 'vitest';
import { formatClock, shouldShowWall, urgencyTier } from './budget';

// The conversion gate's contract in numbers: what colour the countdown wears
// and when the wall appears. If a case here breaks, the wall showed too early
// or too late.
//
// A third rule used to live here — how long the visitor's machine was still
// theirs to walk back into — and it went with the footnote that was the only
// thing reading it. The 120-second hold is still real and still the server's
// (CONTRACT-LEDGER §3.4); the wall simply no longer makes a promise about it
// that it times in the browser.

describe('urgencyTier', () => {
  it('is calm for most of the minute', () => {
    expect(urgencyTier(60, 60)).toBe('calm');
    expect(urgencyTier(31, 60)).toBe('calm');
  });

  it('turns attentive at the halfway line, inclusive', () => {
    expect(urgencyTier(30, 60)).toBe('attentive');
    expect(urgencyTier(11, 60)).toBe('attentive');
  });

  it('turns urgent for the last sixth, inclusive', () => {
    expect(urgencyTier(10, 60)).toBe('urgent');
    expect(urgencyTier(1, 60)).toBe('urgent');
    expect(urgencyTier(0, 60)).toBe('urgent');
  });

  it('scales with the budget rather than assuming 60', () => {
    // A 120s budget: the same FRACTIONS, twice the seconds.
    expect(urgencyTier(61, 120)).toBe('calm');
    expect(urgencyTier(60, 120)).toBe('attentive');
    expect(urgencyTier(20, 120)).toBe('urgent');
  });

  it('never divides by zero, and never reads a spent budget as calm', () => {
    expect(urgencyTier(5, 0)).toBe('urgent');
    expect(urgencyTier(0, 0)).toBe('urgent');
    expect(urgencyTier(-3, 60)).toBe('urgent');
  });
});

describe('formatClock', () => {
  it('renders m:ss with a zero-padded seconds field', () => {
    expect(formatClock(60)).toBe('1:00');
    expect(formatClock(45)).toBe('0:45');
    expect(formatClock(5)).toBe('0:05');
    expect(formatClock(0)).toBe('0:00');
  });

  it('floors a fractional second rather than rounding it up past the truth', () => {
    expect(formatClock(45.9)).toBe('0:45');
  });

  it('never renders a negative clock', () => {
    expect(formatClock(-12)).toBe('0:00');
  });

  it('carries minutes past 9:59 with no fixed width', () => {
    expect(formatClock(725)).toBe('12:05');
  });
});

describe('shouldShowWall', () => {
  it('follows the server flag', () => {
    expect(shouldShowWall(30, true)).toBe(true);
    expect(shouldShowWall(30, false)).toBe(false);
  });

  it('also shows once the local countdown reaches zero, ahead of the next poll', () => {
    expect(shouldShowWall(0, false)).toBe(true);
    expect(shouldShowWall(-1, false)).toBe(true);
  });

  it('stays down for an ordinary in-progress minute', () => {
    expect(shouldShowWall(59, false)).toBe(false);
  });
});

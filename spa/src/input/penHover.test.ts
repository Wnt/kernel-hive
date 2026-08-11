// Unit coverage for the PURE S-Pen hover gate (T-5): rel stations drop pen hover
// outright; abs stations throttle it; button-down / non-pen moves are never gated.
import { describe, expect, it } from 'vitest';
import { allowPenHover } from './penHover';

describe('allowPenHover', () => {
  it('never gates a non-pen move (touch/mouse pass straight through)', () => {
    expect(allowPenHover({ pointerType: 'touch', buttons: 0, rel: true, nowMs: 100, lastMs: 100 })).toBe(true);
    expect(allowPenHover({ pointerType: 'mouse', buttons: 0, rel: true, nowMs: 100, lastMs: 0 })).toBe(true);
  });

  it('never gates a pen move with a button down (a deliberate drag)', () => {
    expect(allowPenHover({ pointerType: 'pen', buttons: 1, rel: true, nowMs: 100, lastMs: 100 })).toBe(true);
  });

  it('drops a bare pen hover on a rel tile outright (no cursor drift)', () => {
    expect(allowPenHover({ pointerType: 'pen', buttons: 0, rel: true, nowMs: 1000, lastMs: 0 })).toBe(false);
  });

  it('throttles pen hover on an abs tile to the min interval', () => {
    expect(allowPenHover({ pointerType: 'pen', buttons: 0, rel: false, nowMs: 100, lastMs: 90 })).toBe(false); // 10ms < 32
    expect(allowPenHover({ pointerType: 'pen', buttons: 0, rel: false, nowMs: 200, lastMs: 100 })).toBe(true); // 100ms ≥ 32
    expect(
      allowPenHover({ pointerType: 'pen', buttons: 0, rel: false, nowMs: 100, lastMs: 80, minIntervalMs: 10 }),
    ).toBe(true);
  });
});

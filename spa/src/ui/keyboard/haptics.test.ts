// The Vibration-API wrapper must be unconditionally safe: absent API (iOS,
// desktop) and a UA that throws from vibrate() must both be non-events, because
// every key press and every forwarded click goes through here.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { hapticTap } from './haptics';

afterEach(() => { vi.unstubAllGlobals(); });

describe('haptics', () => {
  it('never throws when the API is absent (plain node, desktop, iOS)', () => {
    expect(() => hapticTap()).not.toThrow();
  });

  it('never throws when vibrate itself throws', () => {
    vi.stubGlobal('navigator', { vibrate: () => { throw new Error('denied'); } });
    expect(() => hapticTap()).not.toThrow();
  });

  it('vibrates for the requested duration, defaulting to a short tap', () => {
    const vibrate = vi.fn();
    vi.stubGlobal('navigator', { vibrate });
    hapticTap(15);
    expect(vibrate).toHaveBeenCalledWith(15);
    hapticTap();
    expect(vibrate).toHaveBeenCalledWith(10);
  });
});

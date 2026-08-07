// The one-time touch coachmark flag: round-trips through localStorage, and —
// critically — treats a blocked/throwing storage as "already seen" so the
// coachmark can never nag a user who can't persist the dismissal.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { coachSeen, markCoachSeen } from './coachmark';

function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => { map.set(k, String(v)); },
    removeItem: (k: string) => { map.delete(k); },
    clear: () => map.clear(),
    key: (i: number) => [...map.keys()][i] ?? null,
    get length() { return map.size; },
  } as Storage;
}

describe('coachmark seen flag', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('is unseen until marked, then seen (round-trips through storage)', () => {
    vi.stubGlobal('localStorage', fakeStorage());
    expect(coachSeen()).toBe(false);
    markCoachSeen();
    expect(coachSeen()).toBe(true);
  });

  it('treats a throwing / blocked storage as already seen (never nags)', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => { throw new Error('SecurityError: storage blocked'); },
      setItem: () => { throw new Error('SecurityError: storage blocked'); },
    } as unknown as Storage);
    expect(coachSeen()).toBe(true);
    expect(() => markCoachSeen()).not.toThrow(); // swallowed, no crash
  });
});

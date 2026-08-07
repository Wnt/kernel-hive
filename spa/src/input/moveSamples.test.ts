// Unit coverage for the SHARED pointer-move sample resolution (used by both
// the StreamView input stack): coalesced
// fan-out normally, native-event-only while the page is browser-pinch-zoomed.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { pickMoveSamples, pinched, resolveMoveSamples, type MoveSample } from './moveSamples';

const s = (clientX: number, clientY: number): MoveSample => ({ clientX, clientY });

describe('pickMoveSamples (pure core)', () => {
  const native = s(10, 20);
  const coalesced = [s(1, 2), s(3, 4), s(5, 6)];

  it('returns the full coalesced fan-out when not pinched', () => {
    expect(pickMoveSamples(native, coalesced, false)).toEqual(coalesced);
  });

  it('returns only the native sample while pinched (coalesced coords are the un-reprojected surface)', () => {
    expect(pickMoveSamples(native, coalesced, true)).toEqual([native]);
  });

  it('falls back to the native sample when coalesced is null or empty', () => {
    expect(pickMoveSamples(native, null, false)).toEqual([native]);
    expect(pickMoveSamples(native, [], false)).toEqual([native]);
  });
});

describe('pinched', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('is false without a window (SSR/tests) or without visualViewport', () => {
    expect(pinched()).toBe(false);
    vi.stubGlobal('window', {});
    expect(pinched()).toBe(false);
  });

  it('is false at scale 1 and true past the 1.001 epsilon', () => {
    vi.stubGlobal('window', { visualViewport: { scale: 1 } });
    expect(pinched()).toBe(false);
    vi.stubGlobal('window', { visualViewport: { scale: 1.0005 } });
    expect(pinched()).toBe(false); // float noise around 1 is not a pinch
    vi.stubGlobal('window', { visualViewport: { scale: 2 } });
    expect(pinched()).toBe(true);
  });
});

describe('resolveMoveSamples (DOM wrapper)', () => {
  afterEach(() => vi.unstubAllGlobals());

  const fakeEvent = (coalesced: MoveSample[] | null): PointerEvent => {
    const e: MoveSample & { getCoalescedEvents?: () => MoveSample[] } = s(10, 20);
    if (coalesced) e.getCoalescedEvents = () => coalesced;
    return e as unknown as PointerEvent;
  };

  it('fans out coalesced samples when not pinched', () => {
    vi.stubGlobal('window', { visualViewport: { scale: 1 } });
    const coalesced = [s(1, 2), s(3, 4)];
    expect(resolveMoveSamples(fakeEvent(coalesced))).toEqual(coalesced);
  });

  it('maps only the native event while pinch-zoomed', () => {
    vi.stubGlobal('window', { visualViewport: { scale: 2 } });
    const e = fakeEvent([s(1, 2), s(3, 4)]);
    const out = resolveMoveSamples(e);
    expect(out).toHaveLength(1);
    expect(out[0]).toBe(e); // the native event itself, not a coalesced sample
  });

  it('handles UAs without getCoalescedEvents', () => {
    vi.stubGlobal('window', { visualViewport: { scale: 1 } });
    expect(resolveMoveSamples(fakeEvent(null))).toEqual([s(10, 20)]);
  });
});

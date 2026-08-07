import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Object3D } from 'three';
import {
  applyScreenTier,
  clearFocusedScreen,
  SCREEN_FOCUS_DWELL_MS,
  SCREEN_FOCUS_LOSS_GRACE_MS,
  type ScreenRegistration,
  updateFocusedScreen,
} from './screenTiers';

function registration(tileId: string, changes: string[]): ScreenRegistration {
  return {
    object: new Object3D(),
    tileId,
    animated: false,
    tier: 'culled',
    setTier: () => undefined,
    setLiveFocused: (focused) => changes.push(`${tileId}:${focused}`),
  };
}

describe('focused screen ownership', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal('window', globalThis);
    clearFocusedScreen();
  });

  afterEach(() => {
    clearFocusedScreen();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('waits for the full dwell before activating a viewer', () => {
    const changes: string[] = [];
    const screen = registration('helenos', changes);
    applyScreenTier(screen, 'focused');

    updateFocusedScreen(screen);
    vi.advanceTimersByTime(SCREEN_FOCUS_DWELL_MS - 1);
    expect(changes).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(changes).toEqual(['helenos:true']);
  });

  it('retires the old viewer before dwelling on a new screen', () => {
    const changes: string[] = [];
    const first = registration('helenos', changes);
    const second = registration('tinycore', changes);
    applyScreenTier(first, 'focused');
    updateFocusedScreen(first);
    vi.advanceTimersByTime(SCREEN_FOCUS_DWELL_MS);

    applyScreenTier(first, 'near');
    applyScreenTier(second, 'focused');
    updateFocusedScreen(second);
    expect(changes).toEqual(['helenos:true', 'helenos:false']);
    vi.advanceTimersByTime(SCREEN_FOCUS_DWELL_MS);
    expect(changes).toEqual([
      'helenos:true',
      'helenos:false',
      'tinycore:true',
    ]);
  });

  it('uses only the short grace for a momentary loss of visible focus', () => {
    const changes: string[] = [];
    const screen = registration('helenos', changes);
    applyScreenTier(screen, 'focused');
    updateFocusedScreen(screen);
    vi.advanceTimersByTime(SCREEN_FOCUS_DWELL_MS);

    updateFocusedScreen(null);
    vi.advanceTimersByTime(SCREEN_FOCUS_LOSS_GRACE_MS - 1);
    expect(changes).toEqual(['helenos:true']);
    vi.advanceTimersByTime(1);
    expect(changes).toEqual(['helenos:true', 'helenos:false']);
  });
});

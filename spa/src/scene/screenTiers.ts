import { invalidate } from '@react-three/fiber';
import type { Object3D } from 'three';
import { noteHallApproach } from './hallEngagement';

export type ScreenTier = 'focused' | 'near' | 'far' | 'culled';

export interface ScreenRegistration {
  object: Object3D;
  tileId: string;
  animated: boolean;
  tier: ScreenTier;
  setTier: (tier: ScreenTier) => void;
  setLiveFocused: (focused: boolean) => void;
}

export const screenRegistrations = new Map<symbol, ScreenRegistration>();

export const SCREEN_FOCUS_DWELL_MS = 1500;
export const SCREEN_FOCUS_LOSS_GRACE_MS = 180;

let candidate: ScreenRegistration | null = null;
let active: ScreenRegistration | null = null;
let dwellTimer = 0;
let lossTimer = 0;
let focusNdc: [number, number] | null = null;
let visibleDebug: Array<{
  tileId: string;
  distance: number;
  ndc: [number, number];
}> = [];

if (import.meta.env.DEV && typeof window !== 'undefined') {
  (window as typeof window & {
    __museumScreenFocusDebug?: () => {
      candidate: string | null;
      active: string | null;
      ndc: [number, number] | null;
      visible: typeof visibleDebug;
      registered: number;
    };
    __museumClearFocusDebug?: () => void;
  }).__museumScreenFocusDebug = () => ({
    candidate: candidate?.tileId ?? null,
    active: active?.tileId ?? null,
    ndc: focusNdc,
    visible: visibleDebug,
    registered: screenRegistrations.size,
  });
  (window as typeof window & {
    __museumClearFocusDebug?: () => void;
  }).__museumClearFocusDebug = clearFocusedScreen;
}

export function registerScreen(
  object: Object3D,
  tileId: string,
  animated: boolean,
  setTier: (tier: ScreenTier) => void,
  setLiveFocused: (focused: boolean) => void,
) {
  const id = Symbol('museum-screen');
  const registration = {
    object,
    tileId,
    animated,
    tier: 'culled' as ScreenTier,
    setTier,
    setLiveFocused,
  };
  screenRegistrations.set(id, registration);
  invalidate();
  return () => {
    if (candidate === registration || active === registration) clearFocusedScreen();
    screenRegistrations.delete(id);
    invalidate();
  };
}

export function applyScreenTier(registration: ScreenRegistration, tier: ScreenTier) {
  if (registration.tier === tier) return;
  registration.tier = tier;
  registration.setTier(tier);
}

export function updateFocusedScreen(next: ScreenRegistration | null) {
  if (!next) {
    if (!candidate || lossTimer) return;
    lossTimer = window.setTimeout(() => {
      lossTimer = 0;
      clearFocusedScreen();
    }, SCREEN_FOCUS_LOSS_GRACE_MS);
    return;
  }

  if (lossTimer) {
    window.clearTimeout(lossTimer);
    lossTimer = 0;
  }
  if (candidate === next) return;
  if (dwellTimer) window.clearTimeout(dwellTimer);
  dwellTimer = 0;
  if (active && active !== next) {
    active.setLiveFocused(false);
    active = null;
  }
  candidate = next;
  dwellTimer = window.setTimeout(() => {
    dwellTimer = 0;
    if (candidate !== next || next.tier !== 'focused') return;
    active = next;
    next.setLiveFocused(true);
    // The scene's definition of "the visitor is AT this machine": nearest
    // screen to the centre of the view, held there for the full dwell. This is
    // the same edge that decides to spend a live texture on it, which is why
    // hall.navigate reuses it rather than inventing a proximity rule of its own
    // — see hallEngagement.ts.
    noteHallApproach(next.tileId);
    invalidate();
  }, SCREEN_FOCUS_DWELL_MS);
}

export function clearFocusedScreen() {
  if (dwellTimer) window.clearTimeout(dwellTimer);
  if (lossTimer) window.clearTimeout(lossTimer);
  dwellTimer = 0;
  lossTimer = 0;
  candidate = null;
  focusNdc = null;
  if (active) active.setLiveFocused(false);
  active = null;
  invalidate();
}

export function setFocusedScreenNdc(ndc: [number, number] | null) {
  focusNdc = ndc;
}

export function setScreenVisibilityDebug(next: typeof visibleDebug) {
  if (import.meta.env.DEV) visibleDebug = next;
}

export function getFocusedScreenTileId() {
  return candidate?.tileId ?? null;
}

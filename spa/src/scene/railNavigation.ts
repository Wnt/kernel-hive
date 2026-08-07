export type RailTarget = [number, number, number];

type RailTargetListener = (target: RailTarget) => void;
type RailJumpListener = (railT: number) => void;
type HoverZoomListener = (target: RailTarget | null) => void;

let currentRailT = 0.13;
const targetListeners = new Set<RailTargetListener>();
const jumpListeners = new Set<RailJumpListener>();
const hoverZoomListeners = new Set<HoverZoomListener>();

if (import.meta.env.DEV && typeof window !== 'undefined') {
  (window as typeof window & {
    __museumRailDebug?: () => number;
    __museumJumpRailDebug?: (railT: number) => void;
  }).__museumRailDebug = () => currentRailT;
  (window as typeof window & {
    __museumJumpRailDebug?: (railT: number) => void;
  }).__museumJumpRailDebug = (railT) => {
    jumpListeners.forEach((listener) => listener(railT));
  };
}

export function setCurrentRailT(next: number) {
  currentRailT = ((next % 1) + 1) % 1;
}

export function getCurrentRailT() {
  return currentRailT;
}

export function requestRailApproach(target: RailTarget) {
  targetListeners.forEach((listener) => listener(target));
}

export function subscribeRailApproach(listener: RailTargetListener) {
  targetListeners.add(listener);
  return () => {
    targetListeners.delete(listener);
  };
}

export function subscribeRailDebugJump(listener: RailJumpListener) {
  jumpListeners.add(listener);
  return () => {
    jumpListeners.delete(listener);
  };
}

export function requestHoverZoom(target: RailTarget | null) {
  hoverZoomListeners.forEach((listener) => listener(target));
}

export function subscribeHoverZoom(listener: HoverZoomListener) {
  hoverZoomListeners.add(listener);
  return () => {
    hoverZoomListeners.delete(listener);
  };
}

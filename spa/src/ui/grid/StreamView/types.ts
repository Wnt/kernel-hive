// Shared value-shapes for the StreamView pointer-lock / pinch-zoom machinery.
// (Structurally identical to the inline object types the god-component used.)

export interface Vec2 { x: number; y: number }

// Item 5 local pinch-zoom CSS transform state.
export interface ZoomState { s: number; x: number; y: number; animated: boolean }

// Two-finger gesture accumulator for the local pinch-zoom + pan effect.
//   mode '2f'     = two fingers down, still ARBITRATING pinch vs scroll (T-1).
//   mode 'scroll' = arbitration resolved to a guest wheel drag (not local zoom).
export interface GestureState {
  mode: 'none' | 'pinch' | 'pan' | '2f' | 'scroll';
  s: number; x: number; y: number;
  startDist: number; startScale: number;
  startMid: { x: number; y: number };
  startTx: number; startTy: number;
  panStart: { x: number; y: number };
  passThrough: number | null;
  // Two-finger arbitration (T-1): the fingers' start positions + start time,
  // and the last centroid while scrolling. Only meaningful in mode '2f'/'scroll'.
  aStart: { x: number; y: number };
  bStart: { x: number; y: number };
  twoStartT: number;
  scrollLast: { x: number; y: number };
}

// ============================================================================
//  input/touchGestures — DIRECT touch/pen pointer model + two-finger arbitration
//  ---------------------------------------------------------------------------
//  DIRECT model (reverted from the earlier deferred recognizer, 2026-07): a touch
//  or S-Pen behaves like a MOUSE, so drawing/dragging just works — button DOWN on
//  contact, MOVE while held, button UP on release. No deferral, no long-press
//  automation and no synthetic double-tap: two quick taps are two real clicks, so
//  the GUEST's own double-click timer sees a double-click naturally.
//
//  THE PEN CAVEAT (2026-08-05). "Naturally" assumed the two taps land on the same
//  pixel. A hand does not: measured on IRIX, two taps 190 ms apart landed 4-12
//  guest px apart, and each tap itself wandered between contact and lift. So the
//  pointer is QUANTISED — a contact is held to a point until it declares itself a
//  drag, and a quick second contact is snapped onto the first. That policy lives
//  in input/tapQuantiser (shared with the STYLUS path, which never reaches this
//  recognizer); this file only feeds it samples.
//  A one-shot RIGHT-CLICK comes from the on-screen arm toggle (TouchControlBadge)
//  or an S-Pen barrel press. Pure + DOM/timer-free so it is unit-testable; the hook
//  (ui/grid/StreamView/useTouchGestures.ts) maps the emitted intents onto the
//  StreamControlHandle. Two-finger pinch-vs-scroll arbitration lives further down.
// ============================================================================
import { createTapQuantiser } from './tapQuantiser';

/** Guest-pixel coordinate (samples arrive already inverted through the letterbox). */
interface Pt {
  x: number;
  y: number;
}

/** One single-finger/pen pointer sample. `x,y` are GUEST px (what is sent);
 *  `cx,cy` are the same point in viewport CSS px, which is the space the tap
 *  quantiser measures in. `t` is a DOM timeStamp (ms). */
interface PointerSample {
  id: number;
  x: number;
  y: number;
  cx: number;
  cy: number;
  t: number;
}

/** What a single-finger/pen event resolves to; the hook expands via intentToOps(). */
export type GestureIntent =
  | { type: 'down'; button: number; x: number; y: number; reposition?: boolean }
  | { type: 'move'; x: number; y: number }
  | { type: 'up'; button: number; x: number; y: number; reposition?: boolean };

/** One-shot arm the NEXT touch should honour (the on-screen Right-click toggle). */
export type ArmMode = 'none' | 'right-click';

interface Held {
  id: number;
  button: number; // 0 = left, 2 = right (armed toggle / S-Pen barrel)
  lx: number; // last px (release target if the touch is cancelled)
  ly: number;
  ox: number; // contact point: where this press went DOWN (after any snap)
  oy: number;
  /** True once the slop was crossed: from then on every sample is forwarded and
   *  the release lands where the pointer actually is. */
  moved: boolean;
}

/** Stateful (DOM/timer-free) DIRECT pointer engine. One per stream surface. */
export interface Recognizer {
  /** Press: sends the button DOWN immediately. `right` = an S-Pen barrel press;
   *  the armed toggle also forces the right button (one-shot). */
  begin(s: PointerSample, right?: boolean): GestureIntent[];
  move(s: PointerSample): GestureIntent[];
  end(s: PointerSample): GestureIntent[];
  /** The touch was stolen (a 2nd finger began a pinch) or lost — release the held button. */
  cancel(): GestureIntent[];
  setArm(mode: ArmMode): void;
  getArm(): ArmMode;
}

export function createRecognizer(opts: { onChange?: () => void } = {}): Recognizer {
  let held: Held | null = null;
  let armMode: ArmMode = 'none';
  const tap = createTapQuantiser();
  const change = () => opts.onChange?.();

  const begin = (s: PointerSample, right = false): GestureIntent[] => {
    const button = right || armMode === 'right-click' ? 2 : 0;
    if (armMode === 'right-click') { armMode = 'none'; change(); }
    const { x, y } = tap.down(s, s.t, button);
    held = { id: s.id, button, lx: x, ly: y, ox: x, oy: y, moved: false };
    // No synthetic extra click. Two quick taps stay two real clicks — the guest
    // pairs them itself once they land on ONE pixel with nothing interleaved.
    // A brief burst was tried while the real cause was still unknown; it made a
    // double-tap send THREE clicks, which is visible to the user on anything
    // that acts on a single click.
    return [{ type: 'down', button, x, y }];
  };
  const move = (s: PointerSample): GestureIntent[] => {
    if (!held || held.id !== s.id) return [];
    if (!tap.forward(s, s.t)) return []; // wobble, or still inside the tap hold
    held.moved = true;
    held.lx = s.x; held.ly = s.y;
    return [{ type: 'move', x: s.x, y: s.y }];
  };
  const end = (s: PointerSample): GestureIntent[] => {
    if (!held || held.id !== s.id) return [];
    const { button } = held;
    held = null;
    const at = tap.up(s, s.t);
    return [{ type: 'up', button, x: at.x, y: at.y }];
  };
  const cancel = (): GestureIntent[] => {
    if (!held) return [];
    const { button, lx, ly } = held; held = null;
    tap.cancel(); // a stolen touch (pinch takeover) is not a tap to build on
    return [{ type: 'up', button, x: lx, y: ly }];
  };

  return {
    begin, move, end, cancel,
    setArm: (mode) => { armMode = mode; change(); },
    getArm: () => armMode,
  };
}

// ---- intent → StreamControlHandle primitive ops ---------------------------
//  Kept pure (no handle reference) so the 2D hook owns one semantic mapping.
export type PointerOp =
  | { kind: 'button'; button: number; down: boolean; x: number; y: number; reposition?: boolean }
  | { kind: 'move'; x: number; y: number };

export function intentToOps(i: GestureIntent): PointerOp[] {
  switch (i.type) {
    case 'down':
      return [{ kind: 'button', button: i.button, down: true, x: i.x, y: i.y, reposition: i.reposition }];
    case 'up':
      return [{ kind: 'button', button: i.button, down: false, x: i.x, y: i.y, reposition: i.reposition }];
    case 'move': return [{ kind: 'move', x: i.x, y: i.y }];
  }
}

// ============================================================================
//  TWO-FINGER ARBITRATION — pinch (local zoom) vs scroll (guest wheel)
//  ---------------------------------------------------------------------------
//  The local pinch-zoom effect claims EVERY two-finger gesture. To let a
//  two-finger DRAG reach the guest as a wheel WITHOUT ever regressing pinch, we
//  watch the first ~decideMs / ~decidePx of the second finger and classify:
//    - inter-finger DISTANCE change dominates             → PINCH  (local zoom)
//    - CENTROID translation dominates, distance ~constant → SCROLL (guest wheel)
//  BE CONSERVATIVE: anything ambiguous stays PINCH (the safe, shipped default).
// ============================================================================
export type TwoFingerKind = 'undecided' | 'pinch' | 'scroll';

const TWO_FINGER = {
  decideMs: 40, // decide by this much elapsed…
  decidePx: 12, // …or this much of EITHER signal, whichever comes first
  scrollMinPx: 10, // need at least this centroid travel to call it a scroll
  distStablePx: 16, // …and the finger separation must stay this stable
  dominance: 1.6, // …and translation must beat distance-change by this factor
  scrollGain: 1, // guest wheel px per centroid px (mouse-wheel-like)
};

const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.y - b.y);
const mid = (a: Pt, b: Pt): Pt => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });

/** Classify a two-finger gesture from its start vs current finger positions. */
export function classifyTwoFinger(
  a0: Pt, b0: Pt, a1: Pt, b1: Pt, elapsedMs: number,
  t = TWO_FINGER,
): TwoFingerKind {
  const dDist = Math.abs(dist(a1, b1) - dist(a0, b0)); // change in separation
  const dTrans = dist(mid(a1, b1), mid(a0, b0)); // centroid travel
  const decided = elapsedMs >= t.decideMs || dTrans >= t.decidePx || dDist >= t.decidePx;
  if (!decided) return 'undecided';
  // SCROLL only when translation clearly dominates AND the fingers held a
  // near-constant separation. Everything else — including ambiguous — is PINCH.
  if (dTrans >= t.scrollMinPx && dDist <= t.distStablePx && dTrans >= dDist * t.dominance) {
    return 'scroll';
  }
  return 'pinch';
}

/** Centroid delta → guest wheel delta. Mouse-wheel sense: fingers up ⇒ +deltaY
 *  (scroll down), matching how a physical wheel and native trackpad scroll read. */
export function scrollWheelDelta(prev: Pt, now: Pt, gain = TWO_FINGER.scrollGain): Pt {
  return { x: (prev.x - now.x) * gain, y: (prev.y - now.y) * gain };
}

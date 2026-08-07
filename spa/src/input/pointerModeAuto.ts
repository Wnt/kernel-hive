// ============================================================================
//  input/pointerModeAuto — WHICH touch model the surface is in, decided from the
//  device the visitor is actually holding.
//  ---------------------------------------------------------------------------
//  The two models want opposite things, and the right one depends entirely on
//  what is touching the glass:
//
//    * A FINGER is fat and it covers what it points at. On IRIX one CSS px is
//      3.13 guest px, so a fingertip spans ~90 guest px of a menu it cannot see
//      under itself. TRACKPAD mode (input/trackpad) fixes both: drag to glide a
//      cursor you can watch, tap to click it.
//    * An S-PEN is a pixel-accurate tip with nothing occluding it, and its whole
//      point is that it lands where you put it. Gliding a cursor with a stylus
//      is strictly worse than pointing with it — DIRECT mode is what a pen wants.
//
//  So the model FOLLOWS THE DEVICE, and hover is what makes that feel instant:
//  an S-Pen streams pointermove while it is still ~1 cm above the glass, so the
//  switch has already happened by the time the tip lands. Without hover the mode
//  could only flip on contact, i.e. one tap too late.
//
//  A finger flips it back — but only after a GRACE, because a stylus user rests
//  a hand on the screen and Android does not always reject it. The grace is
//  measured from the last stylus/mouse event of ANY kind, contact or hover, so a
//  pen kept near the glass holds direct mode indefinitely; only a finger arriving
//  with the pen genuinely away switches back.
//
//  PURE (no DOM, no clock of its own) so the whole rule set is unit-testable —
//  the hook (ui/grid/StreamView/useTouchControl) supplies the events and the
//  clock. It must read performance.now() in the handler rather than trusting
//  event.timeStamp: Chrome-Android stamps synthesized events with the ORIGINATING
//  event's time, which already cost this investigation a full round of wrong
//  fixes (see input/penRightClick).
// ============================================================================

/** The two single-pointer touch models. */
export type TouchModel = 'trackpad' | 'direct';

/** How long after the last stylus/mouse event a finger contact still counts as
 *  "the pen user rested a hand" rather than "they put the pen down".
 *
 *  A pen in use is never quiet for this long: in contact it streams motion, and
 *  between strokes it hovers. So the window only has to outlast the gap between
 *  a lift and the next approach, which is why it is short enough that DELIBERATE
 *  finger use switches on the very first tap. */
export const PRECISE_GRACE_MS = 1500;

/** True for pointers that aim exactly where they are: a stylus tip, a mouse.
 *  Both want DIRECT pointing; only a finger wants the trackpad. */
export function isPrecisePointer(pointerType: string): boolean {
  return pointerType === 'pen' || pointerType === 'mouse';
}

/** The model this event implies, or the current one when it implies nothing.
 *
 *  Returning the CURRENT model unchanged is the common case (every hover sample
 *  of an already-direct pen), and the caller compares by value and does nothing —
 *  so the hot path allocates nothing and never touches React state. */
export function autoModel(i: {
  pointerType: string;
  /** true for pointerdown; hover/move alone must not flip a finger's model. */
  isDown: boolean;
  /** performance.now() read in the handler — see the header. */
  nowMs: number;
  /** when a stylus/mouse was last seen, on the same clock. */
  preciseAtMs: number;
  model: TouchModel;
}): TouchModel {
  // A stylus or mouse anywhere near the glass — hovering counts — takes direct.
  if (isPrecisePointer(i.pointerType)) return 'direct';
  // Only a real finger CONTACT hands the surface back to the trackpad, and only
  // once the stylus has been away for the grace.
  if (i.pointerType === 'touch' && i.isDown && i.nowMs - i.preciseAtMs >= PRECISE_GRACE_MS) {
    return 'trackpad';
  }
  return i.model;
}

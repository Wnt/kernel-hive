// ============================================================================
//  input/penRightClick — what a native `contextmenu` MEANS during pen input.
//  ---------------------------------------------------------------------------
//  A Samsung S-Pen reports its BARREL button only as a native `contextmenu`
//  event; there is no pointer-button bit to read at pointerdown. Android ALSO
//  fires `contextmenu` for its own long-press gesture. Same event, opposite
//  intents, and getting it wrong breaks a different interaction each way:
//
//    * treat every contextmenu as a barrel press, and a long LEFT drag — grab a
//      window, hold still, move — gets a right button injected into the middle
//      of it. The guest sees buttons 1+3 held at once (mask 0x05 in the daemon
//      telemetry) and 4Dwm abandons the drag, which reads as "the pen let go".
//    * treat none of them as a barrel press and right-click is unreachable on a
//      stylus, so IRIX's spring-loaded root menu — press right, DRAG onto an
//      item, release — cannot be opened at all.
//
//  WHICH POINTER, FIRST — then which time. A FINGER has no barrel, so no
//  contextmenu a finger can produce is ever a barrel press; every one of them is
//  Android's long-press asking for a menu this app does not want. That is a
//  cheaper question than the timing one and it is answered by the event itself:
//  Chrome-Android dispatches `contextmenu` as a PointerEvent and its
//  `pointerType` is the originating pointer's, captured live on the user's
//  device (2026-08-23):
//
//      2278008  down     btn=1 pt=t (394,691)
//      2278601  ctxmenu  btn=0 pt=t (393,690)   +593 ms into a live contact
//      2279084  up       btn=0 pt=t (391,693)   held 1076 ms, 26 moves
//
//  `pt=t` is pointerType touch. Before that read existed this function saw only
//  `heldContact`, which is `penDownBtn.size > 0` in the caller — and a FINGER
//  contact never enters `penDownBtn`, because the touch recognizer owns it. So a
//  finger long-press arrived looking exactly like a hovering pen: `heldContact`
//  false, the `synth` shortcut below fired before the timing gate was ever
//  consulted, and a standalone right-click went into the guest ON TOP of the
//  left button the recognizer was still holding — the 0x05 mask above,
//  self-inflicted. The 250 ms discriminator this module is built around was
//  bypassed for precisely the input it most needs to reject.
//
//  So `pointerType` is an EXPLICIT input, not something inferred from the
//  absence of a tracked contact. The only touch route to a right button is the
//  ⊕ arm badge (ui/grid/StreamView/TouchControlBadge), which rides a real
//  pointerdown/pointerup pair through the recognizer and never comes past here.
//
//  TIME separates them — but ONLY wall-clock time read in the handler, never the
//  event's own timeStamp. Chrome-Android synthesizes the long-press contextmenu
//  from the originating pointerdown and gives it that event's timeStamp, so
//  `ctx.timeStamp - down.timeStamp` is ZERO for a half-second hold. Captured live
//  on the user's device (2026-08-05):
//
//      ["d", 131704, ..., buttons 1]   pointerdown
//      ["X", 131704, ...]              contextmenu — the SAME stamp, 3 s contact
//
//  A discriminator built on that stamp classifies every long-press as a barrel
//  press, which is exactly what shipped and exactly what the user then saw. So
//  the caller measures with performance.now() at dispatch, and a contextmenu
//  inside the window below is the barrel; anything later is the OS gesture.
//
//  And a barrel press is CONVERTED rather than synthesized: the contact keeps
//  running as a right-button hold, released when the pen actually lifts. That is
//  what makes a spring-loaded menu work — a synthetic down+up posts the menu and
//  unposts it a few tens of ms later, before it can be dragged.
// ============================================================================
import type { StreamControlHandle } from '../three/useStreamControl';
import { rightHoldMs } from './rightClickHold';

/** How long after a contact starts a `contextmenu` still counts as the BARREL.
 *
 *  A barrel-held tap fires its contextmenu as soon as the tip registers, because
 *  the barrel was already down. Android's long-press must first satisfy its own
 *  hold (~500 ms). 250 ms sits between them with room on both sides — but it is
 *  only meaningful against a HANDLER-READ clock; see the header. */
export const BARREL_WINDOW_MS = 250;

/** Ignore a contextmenu/auxclick this soon after the pointer path already sent
 *  a right button — a real MOUSE right-click fires both, and the guest must not
 *  get two. */
const RIGHT_SUPPRESS_MS = 500;

export type CtxAction =
  /** Not ours: already handled, or Android's long-press during a real contact. */
  | 'ignore'
  /** Barrel press mid-contact: turn this contact into a right-button HOLD. */
  | 'convert'
  /** Barrel press with nothing held (pen hovering): a standalone right-click. */
  | 'synth';

/** PURE decision for one contextmenu/auxclick. See the header for why time is
 *  the discriminator and not the event itself. */
export function contextMenuAction(i: {
  /** `pointerType` of the contextmenu/auxclick event itself. `'touch'` is a
   *  FINGER and is rejected outright — see the header. Undefined on a UA that
   *  dispatches these as a plain MouseEvent, which is a desktop mouse; the pen
   *  logic below is then unchanged from before this input existed. */
  pointerType?: string;
  /** A real PEN/MOUSE contact is currently holding a button. Finger contacts
   *  live in the touch recognizer, not here, so this is false for them — which
   *  is why `pointerType` has to be consulted before it. */
  heldContact: boolean;
  /** ms since that contact went down, measured on a HANDLER-READ clock
   *  (performance.now()), never from event timeStamps — see the header. */
  sinceContactMs: number;
  /** ms since the pointer path last sent a guest right button. */
  sincePointerRightMs: number;
  /** ms since a previous contextmenu synth (auxclick de-dup; 0 for contextmenu). */
  sinceCtxSynthMs?: number;
}): CtxAction {
  if (i.sincePointerRightMs < RIGHT_SUPPRESS_MS) return 'ignore';
  if ((i.sinceCtxSynthMs ?? Infinity) < RIGHT_SUPPRESS_MS) return 'ignore';
  // A finger has no barrel button, so this can only be the OS long-press. It is
  // rejected BEFORE the contact/timing gates, because a finger contact is not
  // tracked here and would otherwise fall straight through to 'synth'.
  if (i.pointerType === 'touch') return 'ignore';
  // Nothing held: a barrel press with the pen tip off the glass. A stylus is the
  // only pointer that reaches here without a contact of its own.
  if (!i.heldContact) return 'synth';
  // A barrel press during a contact converts it; a long-press is the OS asking
  // for a menu we do not want, and it must leave the contact strictly alone —
  // it is in the middle of being a drag.
  return i.sinceContactMs <= BARREL_WINDOW_MS ? 'convert' : 'ignore';
}

/** Turn a contact that is already holding the LEFT button into a RIGHT-button
 *  hold, kept down until the pen lifts.
 *
 *  The left button was pressed on contact because the barrel bit was not yet
 *  visible; releasing it takes NO coordinates, since the cursor is already there
 *  and re-stating the position only re-arms the daemon's button guard. */
export function convertContactToRight(
  control: StreamControlHandle, pressed: Set<number>, x: number, y: number,
): void {
  if (pressed.delete(0)) control.sendMouseButton(0, false);
  pressed.add(2);
  control.sendMouseButton(2, true, x, y);
}

/** A standalone right-click for a barrel press with no contact (pen hovering).
 *  HELD for a few tens of ms before release: Motif/CDE's sticky Workspace Menu
 *  only posts on a real hold, and a 0 ms down→up never posts it. */
export function synthRightClick(
  control: StreamControlHandle, pressed: Set<number>, x: number, y: number,
): void {
  if (pressed.has(2)) return; // a hold is already pending
  pressed.add(2);
  control.sendMouseButton(2, true, x, y);
  window.setTimeout(() => {
    if (pressed.delete(2)) control.sendMouseButton(2, false, x, y);
  }, rightHoldMs());
}

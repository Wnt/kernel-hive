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
  /** A real pointer contact is currently holding a button. */
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

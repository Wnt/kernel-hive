// ============================================================================
//  input/penContact — what a STYLUS press and release send to the guest.
//  ---------------------------------------------------------------------------
//  A pen does not reach the touch recognizer: `pointerType` is `'pen'`, which is
//  neither `'touch'` nor one of the touch-ARCHETYPE tiles, so on an ordinary
//  desktop exhibit useStreamInput's mouse path handles it. It still needs the
//  tap quantisation a finger gets — more, if anything, since a stylus wobbles
//  between contact and lift — so these two helpers apply the same
//  input/tapQuantiser policy on that path, and keep the wire details out of
//  the event handler.
// ============================================================================
import { logClientEvent } from '../three/clientDebug';
import type { StreamControlHandle } from '../three/useStreamControl';
import { TAP, type TapPoint, type TapQuantiser } from './tapQuantiser';

/** How long after a pen contact to stop forwarding HOVER movement. Deliberately
 *  the double-tap window itself (TAP.doubleMs): for exactly as long as the next
 *  tap could still pair with this one, hover has nothing useful to say.
 *
 *  A stylus hovers continuously — ~8 ms apart, and those samples keep flowing
 *  between the two taps of a double-tap. Moves and buttons ride SEPARATE input
 *  streams, so the daemon can apply a queued hover move in the middle of a
 *  double-click burst. Measured on win311 (2026-08-05): `atMove` advanced
 *  between every button of the burst — 1072, 1074, 1076, 1079 — which both
 *  re-arms the warpd button-guard (spreading the pair back out in time) and
 *  drags the guest cursor off the pixel the pair was aimed at. Windows 3.1
 *  allows 4 px between the halves of a double-click; that is all it takes.
 *
 *  So hover is muted around a contact. Nothing else is affected: hover only
 *  moves a cursor the user is not pressing with, and 250 ms of it is invisible.
 */
const HOVER_MUTE_MS = TAP.doubleMs;

let muteHoverUntil = 0;

/** Stylus contact: press at the quantised point, doubling it when this is the
 *  second tap of a double-tap.
 *
 *  The extra pair is sent WITHOUT a position on purpose. streamhost holds a
 *  button back until the cursor has provably caught up on tiles whose motion
 *  rides a slow agent (SH_WARPD_BUTTON_DELAY_MS), and every reposition re-arms
 *  that hold — so a burst that positioned each button would be spread straight
 *  back out to the human gap it exists to close. The cursor is already there. */
export function penPress(
  control: StreamControlHandle, tap: TapQuantiser, btn: number, at: TapPoint, t: number,
): void {
  const p = tap.down(at, t, btn);
  control.sendMouseButton(btn, true, p.x, p.y);
  // One `pen-tap` line per contact. Whether a double-tap was RECOGNISED is the
  // first thing anyone debugging "my double-click did nothing" needs, and the
  // only other way to see it is box-side daemon telemetry.
  logClientEvent('pen-tap', JSON.stringify({ btn, dbl: p.double, x: p.x, y: p.y }));
  muteHoverUntil = t + HOVER_MUTE_MS;
}

/** True while hover movement must not be forwarded — see HOVER_MUTE_MS. */
export function penHoverMuted(t: number): boolean {
  return t < muteHoverUntil;
}

/** Stylus lift: a tap releases exactly where it pressed (the quantiser holds the
 *  contact point); only a real drag releases under the pointer. */
export function penRelease(
  control: StreamControlHandle, tap: TapQuantiser, btn: number, p: TapPoint, t: number,
): void {
  const at = tap.up(p, t);
  // A clean tap releases with NO position: the cursor was placed by the press
  // and has not moved, so re-sending it only re-arms the daemon's warpd
  // button-guard and stretches the click. A drag does carry its release point.
  if (at.tapped) control.sendMouseButton(btn, false);
  else control.sendMouseButton(btn, false, at.x, at.y);
  // Hold the mute past the RELEASE, because the second tap of a double-tap
  // arrives ~160-200 ms later and anything forwarded in that gap is what
  // interleaves with its burst — but ONLY if this contact was a tap. After a
  // DRAG no double-click can follow (the anchor is cleared anyway), and that is
  // the exact moment the pen is being moved, so muting hover would strand the
  // guest cursor for no reason. Clear it instead.
  muteHoverUntil = at.tapped ? t + HOVER_MUTE_MS : 0;
}

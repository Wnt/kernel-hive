// ============================================================================
//  input/penHover — PURE S-Pen hover gate (T-5)
//  ---------------------------------------------------------------------------
//  A stylus that merely HOVERS (buttons === 0) over a lock-free surface streams a
//  flood of pointermove events. On a rel-pointer station each forwarded move becomes
//  a RelMotion, so an idle hovering pen DRIFTS the guest cursor across the screen.
//  Gate hover deterministically: drop it outright on rel stations; on abs stations keep
//  it (hover = harmless absolute repositioning) but throttle to a sane rate.
//  Non-pen or button-down moves are never gated.
//
//  Hover is ALSO muted for the whole double-tap window after a contact (see
//  penContact.penHoverMuted). Moves and buttons ride separate input streams, so
//  a hover sample queued between two taps can be applied by the daemon INSIDE
//  the double-click burst — measured on win311, `atMove` advanced between every
//  button of the burst. That re-arms the daemon's warpd button-guard (spreading
//  the pair back out in time) and shifts the guest cursor off the pixel the pair
//  was aimed at; Windows 3.1 allows all of 4 px between the halves of a
//  double-click. While a second tap could still count as a double, hover has
//  nothing useful to say.
// ============================================================================

import { penHoverMuted } from './penContact';

export interface PenHoverInput {
  pointerType: string;
  buttons: number;
  /** true on SH_POINTER=rel stations (qnx/freedos/msdoswin1). */
  rel: boolean;
  nowMs: number;
  lastMs: number;
  minIntervalMs?: number;
}

const HOVER_MIN_MS = 32; // ~30 Hz ceiling for abs-station pen hover

/** True if this move should be forwarded to the guest. A pen hover on a rel station
 *  is always dropped; on an abs station it is throttled to `minIntervalMs`. Anything
 *  that is not a bare pen hover passes straight through. */
export function allowPenHover(i: PenHoverInput): boolean {
  const hovering = i.pointerType === 'pen' && i.buttons === 0;
  if (!hovering) return true;
  if (penHoverMuted(i.nowMs)) return false;
  if (i.rel) return false;
  return i.nowMs - i.lastMs >= (i.minIntervalMs ?? HOVER_MIN_MS);
}

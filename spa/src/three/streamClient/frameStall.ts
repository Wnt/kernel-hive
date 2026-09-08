// ============================================================================
//  streamClient/frameStall — the heartbeat-derived threshold for abr.ts's
//  idle-frame-stall watchdog.
//  ---------------------------------------------------------------------------
//  A watched streamhost session repaints a STATIC desktop only on its keyframe
//  heartbeat (keyframeMs, ~2.5 s by default), and several exhibits run at 2-6
//  fps BY DESIGN. So "no decoded frame for a fixed 2 s" is the normal, healthy
//  behaviour of a large part of the fleet: the old fixed threshold false-latched
//  the watchdog on every heartbeat (weekend production: ~275 warnings, plus a
//  handful of spurious silent-stall rebuilds that permanently demoted healthy
//  ~2 fps clients — loss 0, quality ~98 — to software decode). The threshold
//  must instead track the station's OWN advertised heartbeat.
//
//  SAME shape and floor as stallWatch.ts's `stallThresholdMs` (keyframeMs*2 +
//  1000, floored at FRAME_STALL_MS) — deliberately, so this watchdog and the
//  perceptible-freeze analytics plane MOVE TOGETHER instead of drifting into a
//  fourth opinion (see stallWatch.ts's header). The one difference is the
//  ceiling: this watchdog gates the SAME session whose reconnect-staleness
//  window (`staleMs`, abr.ts) it must stay strictly below, so it caps a fixed
//  margin under MAX_SESSION_STALE_MS. stallWatch, which only MEASURES a session
//  it never drops, caps at MAX.
// ============================================================================

import { FRAME_STALL_MS, MAX_SESSION_STALE_MS } from './constants';

/**
 * Margin kept below the reconnect-staleness window so the DETECTOR always
 * latches strictly before the session is dropped. abr.ts's staleMs is
 * `clamp(keyframeMs*2 + 3000, MIN_SESSION_STALE_MS, MAX_SESSION_STALE_MS)`;
 * subtracting this margin from both the linear term (3000 → 1000) and the
 * ceiling yields `frameStallMsFor(kf) <= staleMs(kf) - MARGIN < staleMs(kf)`
 * for EVERY kf ≥ 0. The ordering invariant is asserted in frameStall.test.ts.
 */
const RECONNECT_STALL_MARGIN_MS = 2000;

/**
 * The idle-frame-stall watchdog threshold (ms) for a station advertising this
 * keyframe heartbeat:
 *   `clamp(keyframeMs*2 + 1000, FRAME_STALL_MS, MAX_SESSION_STALE_MS - MARGIN)`
 *   - floored at FRAME_STALL_MS (2 s) so a genuine freeze on a fast station is
 *     still caught, and a nonsense 0/short heartbeat cannot drop it below the
 *     old fixed value;
 *   - capped a margin below MAX_SESSION_STALE_MS so it stays strictly under the
 *     reconnect-staleness window for every possible heartbeat.
 * Pure — no StreamClient state — so it is unit-testable without an ABR client.
 */
export function frameStallMsFor(keyframeMs: number): number {
  return Math.min(
    MAX_SESSION_STALE_MS - RECONNECT_STALL_MARGIN_MS,
    Math.max(FRAME_STALL_MS, keyframeMs * 2 + 1000),
  );
}

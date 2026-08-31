// ============================================================================
//  stallWatch — a freeze as the VISITOR experiences it, not as the encoder
//  reports it.
//  ---------------------------------------------------------------------------
//  This repo already measures the stream three ways: the Cmd/Ctrl+N overlay,
//  clientlog's 5-second stats line, and `abr.rs` in the daemon. A fourth number
//  that disagreed with all three would be worse than none, so the boundary from
//  docs/ANALYTICS.md applies at full strength here: if the daemon could answer
//  it, this plane does not ask it. Loss, RTT, tier and bitrate are therefore
//  deliberately absent from this file — the daemon owns all four and is better
//  placed to say them.
//
//  What the daemon CANNOT see is the human. It knows an AU was granted, written
//  and finished; it does not know whether a person was looking at the resulting
//  rectangle, whether that rectangle appeared to move, or whether they gave up
//  and left. That is the entire subject of this module, and it is derived from
//  the PAINT side — frames that actually hit the glass — never from the
//  encoder's opinion of what it sent.
//
//  ---- WHY A FIXED THRESHOLD WOULD BE NOISE --------------------------------
//  A static desktop paints only on the keyframe heartbeat, ~2.5 s by default
//  (resumePolicy.ts says exactly this, and it is why `sessionNeedsReconnect`
//  refuses to treat silence as death). Several exhibits run at a couple of
//  frames per second BY DESIGN. So "no new frame for 2 seconds" is the normal,
//  healthy, correct behaviour of a large part of this fleet, and a fixed
//  threshold would report those stations as permanently stalled — a metric
//  whose largest signal is a property of the exhibit rather than a fault.
//
//  The threshold is therefore derived from the station's OWN advertised
//  heartbeat, in the same shape `abr.ts` already uses for its staleness
//  window (`keyframeMs * 2 + slack`, clamped). Reusing that shape is the point:
//  this number and the client's existing watchdog move together instead of
//  being a fourth opinion that drifts away from the other three.
//
//  ---- WHY A GAP IS NOT AUTOMATICALLY A FREEZE -----------------------------
//  The subtler trap, and the one that would have quietly inflated every number
//  here. On an IDLE station showing a motionless desktop, a missed heartbeat is
//  not perceptible: the picture looks identical whether frames are arriving or
//  not, so counting that as "the visitor stared at a frozen picture" would be
//  measuring something nobody experienced. A gap is only a freeze the visitor
//  can actually SEE when one of two things is true:
//
//    * the picture was MOVING — it was painting faster than the heartbeat
//      alone would deliver, so its stopping is visible (a boot animation, a
//      dragged window, a playing demo); or
//    * the visitor was ASKING it to move — a trusted input edge landed after
//      the last paint, so they are waiting on a reaction that has not come.
//
//  Neither of those is knowable from the wire, which is exactly why this lives
//  in the tab. Everything below is pure: no analytics import, no timers, no DOM
//  — the caller drives the clock, so the rules are unit-testable on their own.
// ============================================================================

import {
  FRAME_STALL_MS,
  MAX_SESSION_STALE_MS,
} from './streamClient/constants';

/** The heartbeat assumed when a station has not advertised one. Same default
 *  `abr.ts` falls back to, so the two agree on an un-advertised station. */
export const DEFAULT_KEYFRAME_MS = 2500;

/**
 * Slack added on top of two missed heartbeats.
 *
 * Two whole heartbeat windows must pass before silence means anything — one
 * missed heartbeat is a dropped GOP, which `constants.ts` already says is not
 * a stall — and the extra second absorbs scheduling jitter on a loaded phone.
 */
const STALL_SLACK_MS = 1000;

/**
 * How long a gap must be before the visitor perceives a freeze.
 *
 * Floored at `FRAME_STALL_MS` (2 s), the repo's existing statement of the
 * shortest gap that is "a genuine multi-frame stall, not a single dropped GOP",
 * and capped at `MAX_SESSION_STALE_MS` so a station advertising a nonsense
 * heartbeat cannot push the threshold somewhere no sample would ever reach.
 *
 * This sits BELOW the reconnect staleness window `abr.ts` computes (floor 8 s)
 * on purpose. The visitor perceives the freeze well before the client decides
 * the session is dead, and the gap between those two moments is precisely the
 * thing worth knowing: it is how long somebody is asked to look at a frozen
 * machine before the software does anything about it.
 */
export function stallThresholdMs(keyframeMs: number | null | undefined): number {
  const hb =
    typeof keyframeMs === 'number' && Number.isFinite(keyframeMs) && keyframeMs > 0
      ? keyframeMs
      : DEFAULT_KEYFRAME_MS;
  const derived = hb * 2 + STALL_SLACK_MS;
  return Math.min(MAX_SESSION_STALE_MS, Math.max(FRAME_STALL_MS, derived));
}

/**
 * A paint cadence this much faster than the heartbeat counts as MOTION.
 *
 * Below the heartbeat interval the station is delivering frames it was not
 * obliged to send, which only happens because something on the screen changed.
 * The 0.75 factor keeps a heartbeat that arrives slightly early from reading as
 * animation.
 */
const MOTION_FACTOR = 0.75;

/** Smoothing for the inter-paint interval. Low enough that a couple of quick
 *  frames register as motion, high enough that one stray frame does not. */
const EWMA_ALPHA = 0.3;

/** What a `tick()` observed. `null` means nothing changed. */
export type StallTransition = 'begin' | 'end' | null;

/**
 * Watches one station session's paint stream and says when a human-perceptible
 * freeze starts and stops.
 *
 * The caller supplies the clock and calls `tick()` — from a timer AND from the
 * paint path — so this class holds no timers of its own and can be driven
 * instantly in a test.
 */
export class StallWatch {
  private lastPaintAt: number | null = null;

  private lastInputAt: number | null = null;

  /** Smoothed interval between painted frames, or null before two paints. */
  private intervalMs: number | null = null;

  private keyframeMs: number | null = null;

  /** When the current perceptible stall began, or null when not stalled. */
  private stalledSince: number | null = null;

  /** Advertise the station's keyframe heartbeat as soon as it is known. */
  setHeartbeat(keyframeMs: number | null | undefined): void {
    this.keyframeMs =
      typeof keyframeMs === 'number' && Number.isFinite(keyframeMs) && keyframeMs > 0
        ? keyframeMs
        : null;
  }

  /** The threshold currently in force, for the caller's own reporting. */
  thresholdMs(): number {
    return stallThresholdMs(this.keyframeMs);
  }

  /** True while the picture is moving faster than the heartbeat alone. */
  private moving(): boolean {
    if (this.intervalMs === null) return false;
    const hb = this.keyframeMs ?? DEFAULT_KEYFRAME_MS;
    return this.intervalMs < hb * MOTION_FACTOR;
  }

  /** A decoded frame reached the glass. */
  painted(at: number): void {
    if (this.lastPaintAt !== null) {
      const gap = at - this.lastPaintAt;
      if (gap >= 0) {
        this.intervalMs =
          this.intervalMs === null
            ? gap
            : this.intervalMs * (1 - EWMA_ALPHA) + gap * EWMA_ALPHA;
      }
    }
    this.lastPaintAt = at;
  }

  /** A TRUSTED human input edge went to the guest. Synthetic input (type-in
   *  demos, the win9x boot-modal auto-dismiss) must never reach this: a demo
   *  that types for the visitor is not a visitor waiting on a reaction. */
  input(at: number): void {
    this.lastInputAt = at;
  }

  /** Whether a gap of this length is one the visitor could actually perceive.
   *  See the header: a motionless desktop looks the same either way. */
  private perceptible(): boolean {
    if (this.moving()) return true;
    return (
      this.lastInputAt !== null
      && this.lastPaintAt !== null
      && this.lastInputAt > this.lastPaintAt
    );
  }

  /**
   * Advance the clock. Returns `'begin'` on the tick a perceptible freeze is
   * first recognised, `'end'` on the tick it recovers, and `null` otherwise.
   */
  tick(at: number): StallTransition {
    if (this.lastPaintAt === null) return null; // never painted: not this metric's subject
    const silent = at - this.lastPaintAt;
    if (this.stalledSince !== null) {
      // Recovery is a PAINT, never merely the passage of time.
      if (silent < this.thresholdMs()) {
        this.stalledSince = null;
        return 'end';
      }
      return null;
    }
    if (silent >= this.thresholdMs() && this.perceptible()) {
      this.stalledSince = at;
      return 'begin';
    }
    return null;
  }

  /** True while a perceptible freeze is open. */
  stalled(): boolean {
    return this.stalledSince !== null;
  }
}

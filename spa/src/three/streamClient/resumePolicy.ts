// ============================================================================
//  resumePolicy — deciding whether a session that was backgrounded needs a
//  reconnect, without waiting on a watchdog.
//  ---------------------------------------------------------------------------
//  Backgrounding a tab throttles the client's 100 ms ABR tick to ~1/min and
//  freezes it outright in an installed PWA, so nothing that normally notices a
//  dead session runs while the tab is away. On return the old behaviour was
//  purely reactive — wait for a tick, wait out the stale threshold, wait out a
//  backoff — which is the long black area the operator sees after the banner
//  clears. This module is the decision that replaces that wait.
// ============================================================================

/** Settle window after the tab comes forward, before judging the session. */
export const RESUME_GRACE_MS = 800;
/** A frame painted this recently proves liveness outright — no round-trip. */
export const RESUME_FRESH_PAINT_MS = 1000;
/** Budget for the liveness ping that decides everything else. */
export const RESUME_PING_TIMEOUT_MS = 600;

/** The slice of StreamClient this decision needs. */
export interface ResumeProbeTarget {
  getMsSinceLastFrame(): number;
  pingRtt(timeoutMs?: number): Promise<number | null>;
}

/**
 * True when a resumed session is dead and must be rebuilt.
 *
 * Deliberately NOT "has it painted lately": a static desktop paints only on the
 * keyframe heartbeat (~2.5 s), so silence is normal and treating it as death
 * would reconnect a perfectly healthy station every time the tab came forward.
 * A recent paint is accepted as proof of life; otherwise we ASK the transport,
 * and only an unanswered ping condemns the session.
 */
export async function sessionNeedsReconnect(client: ResumeProbeTarget): Promise<boolean> {
  if (client.getMsSinceLastFrame() < RESUME_FRESH_PAINT_MS) return false;
  const rtt = await client.pingRtt(RESUME_PING_TIMEOUT_MS).catch(() => null);
  return rtt == null;
}

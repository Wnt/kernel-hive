// ============================================================================
//  retryBudget — what "attempt N of M" is allowed to mean
//  ---------------------------------------------------------------------------
//  The field log that exposed this read:
//
//      connect-retry attempt=5/4 … attempt=6/4 … attempt=7/4 … attempt=8/4
//
//  A counter past its own maximum is a budget that does not exist. The old code
//  had ONE limit and applied it only before the first paint (`!liveReached`);
//  once a station had painted, the retry ladder ran forever, never terminated
//  and never escalated — so a session that could not recover simply stayed
//  black while the log counted upwards.
//
//  A budget here means: this many attempts, then STOP and say so. There are two
//  of them because the two situations are genuinely different — a cold connect
//  that never worked falls back to the poster, while a proven-live session has
//  a station worth waiting on and earns a longer ladder before it gives up.
// ============================================================================

/** Never painted: after this the station falls back to its poster. */
export const MAX_COLD_ATTEMPTS = 4;
/** Painted at least once: a longer ladder, but still a finite one. */
export const MAX_RELIVE_ATTEMPTS = 6;

// ---- attempt pacing (moved here from useStreamhostSession so the budgets and
//      the delays they meter live in one file) --------------------------------
/** COLD budget for frame #1 — an idle station legitimately takes a while. */
export const KEYFRAME_WAIT_MS = 12000;
/** Once a station has painted it is proven warm, and the daemon forces an IDR
 *  on subscribe on top of priming its freshest cached key — so a RECONNECT that
 *  has not painted within this budget is broken, not slow. Spending the cold
 *  12 s here was the single biggest contributor to a long black area after a
 *  resume: the replacement attempt sat silent for 12 s before even retrying. */
export const RELIVE_KEYFRAME_WAIT_MS = 3000;
/** Unexpected-loss retry delays; attempt 1 uses index 0. */
export const RETRY_BACKOFF_MS = [600, 1500, 3000, 6000];
/** Restore delays: the host is EXPECTED to be briefly unavailable. */
export const RESTORE_BACKOFF_MS = [250, 500, 1000, 2000];

export interface RetryVerdict {
  /** The attempt number to act on and to LOG — never above `limit`. */
  attempt: number;
  limit: number;
  /** The budget is spent: stop retrying and show a terminal state. */
  exhausted: boolean;
}

export function retryLimit(liveReached: boolean): number {
  return liveReached ? MAX_RELIVE_ATTEMPTS : MAX_COLD_ATTEMPTS;
}

/**
 * Consume one attempt from the applicable budget.
 *
 * `attempt` is CLAMPED to the limit, so `attempt=8/4` can no longer be printed:
 * the log tells the truth about the budget or the budget is wrong.
 */
export function consumeRetry(prevAttempt: number, liveReached: boolean): RetryVerdict {
  const limit = retryLimit(liveReached);
  const raw = Math.max(0, prevAttempt) + 1;
  return { attempt: Math.min(raw, limit), limit, exhausted: raw >= limit };
}

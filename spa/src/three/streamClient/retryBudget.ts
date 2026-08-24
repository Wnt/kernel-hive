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

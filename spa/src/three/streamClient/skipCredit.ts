// ============================================================================
//  streamClient/skipCredit — L-1 server-skip loss correction (pure).
//  ---------------------------------------------------------------------------
//  A server backlog skip / broadcast-ring overrun (transport/backlog.rs) drops a
//  video AU, leaving a frame_id GAP the client counts as loss (videoDecode
//  feedVideoAU) — byte-indistinguishable from real packet loss. The server
//  reports its CUMULATIVE per-session skip count over KIND_PARAMS subtype 2 at
//  1 Hz; the client banks each delta as CREDIT and spends it against the 100 ms
//  gap misses so a server-intentional skip never inflates lossPct (which drives
//  BOTH the local 'spotty' banner AND the loss the server ABR reads back).
//
//  The credit bucket spreads the coarse 1 Hz lump across the fast ticks where the
//  gaps actually appear. Pure + injectable so the arithmetic is unit-tested with
//  no live StreamClient (auGate.ts / scoring.ts precedent). On a LAN the server
//  never skips, so skipTot stays 0 and every function here is a no-op.
// ============================================================================

/** The two mutable fields on StreamClient this correction owns. */
export interface SkipCreditState {
  /** Last cumulative server skip count folded (monotonic per server session). */
  lastServerSkipTotal: number;
  /** Banked, not-yet-spent server skips (bounded by CAP). */
  serverSkipCredit: number;
}

/** Frames of credit that may sit unspent — a burst that never matched a local gap
 *  must not suppress genuine loss indefinitely (~a few seconds at 60 fps). */
export const SKIP_CREDIT_CAP = 240;

/** Fold a fresh cumulative server-skip count into the credit bucket. A counter
 *  going BACKWARDS means the server session restarted (per-session counter reset)
 *  — rebase the baseline instead of banking a negative. */
export function bankServerSkips(s: SkipCreditState, skipTot: number | undefined): void {
  if (skipTot == null) return;
  if (skipTot < s.lastServerSkipTotal) {
    s.lastServerSkipTotal = skipTot; // server session restarted → rebase
    return;
  }
  if (skipTot > s.lastServerSkipTotal) {
    s.serverSkipCredit = Math.min(s.serverSkipCredit + (skipTot - s.lastServerSkipTotal), SKIP_CREDIT_CAP);
    s.lastServerSkipTotal = skipTot;
  }
}

/** Spend banked credit against this interval's gap misses; returns the corrected
 *  miss count (never negative). Decode-gating is unaffected — only loss accounting. */
export function spendSkipCredit(s: SkipCreditState, missed: number): number {
  if (s.serverSkipCredit > 0 && missed > 0) {
    const applied = Math.min(s.serverSkipCredit, missed);
    s.serverSkipCredit -= applied;
    return missed - applied;
  }
  return missed;
}

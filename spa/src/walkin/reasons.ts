// Why a walk-in session ended — the reason codes of CONTRACT-LEDGER §3.1, and
// the one line of copy each of them earns.
//
// The rule this module exists to enforce: a visitor ALWAYS knows why their
// session ended. A walk-in who is dropped because the operator flipped access
// to Closed must not be told "connection lost" — that is a lie about the lab
// and it invites a reload loop against a door that is shut. So every code the
// broker can emit has its own honest sentence here, and the generic
// stream-level copy (StreamView/exitReason.ts) is only ever the fallback for a
// drop that carries no walk-in code at all.

/** The broker→client codes (§3.1) plus the auth-side HTTP body error. */
export type WalkinReason = 'WALKIN_CLOSED' | 'WALKIN_TTL' | 'WALKIN_IDLE';

/** The frozen closed-state sentence (§7). Used by the landing page AND by a
 *  live session dropped with WALKIN_CLOSED — deliberately the same words, so
 *  the two ways of meeting a shut door read as one fact. */
export const WALKIN_CLOSED_COPY = 'Walk-in access is currently closed.';

const REASON_CODES: readonly WalkinReason[] = ['WALKIN_CLOSED', 'WALKIN_TTL', 'WALKIN_IDLE'];

/** Headline + detail for a reason code. */
export interface WalkinReasonCopy {
  title: string;
  detail: string;
  /** May the visitor immediately try for another clone? Closed says no. */
  retryable: boolean;
}

/**
 * Copy for one code. `ttlSeconds` / `idleSeconds` are the numbers the broker
 * actually ran with, so the sentence stays true if the windows are retuned;
 * the ledger's defaults (1200s TTL, 180s idle) are the fallback.
 */
export function walkinReasonCopy(
  reason: WalkinReason,
  windows: { ttlSeconds?: number; idleSeconds?: number } = {},
): WalkinReasonCopy {
  const ttlMinutes = Math.max(1, Math.round((windows.ttlSeconds ?? 1200) / 60));
  const idleMinutes = Math.max(1, Math.round((windows.idleSeconds ?? 180) / 60));
  switch (reason) {
    case 'WALKIN_CLOSED':
      return {
        title: WALKIN_CLOSED_COPY,
        detail:
          'The operator closed walk-in access while you were playing, so your machine was shut down. Nothing went wrong at your end.',
        retryable: false,
      };
    case 'WALKIN_TTL':
      return {
        title: `Your ${ttlMinutes} minutes are up.`,
        detail:
          'Every walk-in session is time-limited so the next visitor gets a turn. Take another machine whenever you like — you get a fresh one.',
        retryable: true,
      };
    case 'WALKIN_IDLE':
      return {
        title: `Ended after ${idleMinutes} minutes idle.`,
        detail:
          'Nothing was typed or clicked, so the machine was handed back to the pool. Claim another one to carry on.',
        retryable: true,
      };
  }
}

/**
 * Find a walk-in reason code in whatever the broker hands us.
 *
 * The code can arrive by more than one road — a transport close reason, an
 * error body, a field on a poll — and lane 1 owns which. Scanning the text for
 * the frozen code words means this UI renders the right sentence whichever
 * road it took, and returns null (⇒ fall back to the generic stream copy) when
 * the drop had nothing to do with the walk-in plane.
 */
export function parseWalkinReason(text: unknown): WalkinReason | null {
  if (typeof text !== 'string' || !text) return null;
  const upper = text.toUpperCase();
  // `walkin_closed` is the HTTP body error for a refused claim (§3.1) — the
  // same fact as the drop code, so it maps to the same sentence.
  for (const code of REASON_CODES) if (upper.includes(code)) return code;
  return null;
}

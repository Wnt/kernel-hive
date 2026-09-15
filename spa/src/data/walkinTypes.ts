// Shared walk-in types — the SPA half of the walk-in HTTP contract.
//
// VERBATIM from docs/lab/walkin/CONTRACT-LEDGER.md §7. Lane 4 (walk-in UI)
// creates this file; lane 5 (admin UI) imports it and never edits it. If a
// shape here has to change, the LEDGER changes first and both lanes follow —
// do not widen a type locally to make one call site compile.
//
// EXTENDED 2026-09-10 for the landing redesign, additively and against the
// contract rather than against another lane's tree — the same discipline
// walkin/api.ts already states. `WalkinAnonBudget` and `WalkinClaim.station`
// are frozen in docs/lab/walkin/LANDING-REDESIGN-CONTRACT.md ("Server
// contract"); the server half is another stream's, and CONTRACT-LEDGER.md §3
// is theirs to update with it. Both additions are OPTIONAL fields, so a broker
// that has not shipped them yet keeps answering this client correctly.
export type WalkinAccess = 'closed' | 'invited' | 'open';
export type WalkinPool = { os: string; free: number; size: number };
/**
 * The anonymous visitor's budget — CONNECTED time, per visitor and not per
 * session, carried across station switches, reloads and back-navigation
 * (docs/lab/walkin/LANDING-REDESIGN-CONTRACT.md, "The anonymous budget").
 * `budgetSeconds` is whatever the server is currently tuned to
 * (`auth/anon.py BUDGET_SECONDS`) — never assume a value here.
 *
 * Present on `/walkin/state` ONLY when the caller is `role === 'anon'`. It is
 * server-authoritative and keyed on the anonymous visitor cookie: the landing
 * page's countdown is a MIRROR of `remainingSeconds`, never its source
 * (landing/heroPolicy.ts `mirroredRemaining`). A signed-in visitor gets no
 * `anon` block at all, which is exactly how the same page renders without a
 * countdown and without a wall for them.
 */
export type WalkinAnonBudget = {
  budgetSeconds: number;
  remainingSeconds: number;
  expired: boolean;
  /** Whether the minute has STARTED — that is, whether the visitor has ever
   *  touched a machine (`POST /walkin/engage`). Until they have,
   *  `remainingSeconds` stands still at the full budget and the page says the
   *  minute starts when they touch it. Optional so a broker that predates the
   *  engagement rule keeps answering this client correctly. */
  engaged?: boolean;
  /** Reserved for 120s after exhaustion, so registering resumes THE SAME machine. */
  heldClone?: string;
};
/**
 * One machine the caller froze by switching away from it — server-authoritative
 * hold state, added for the switch-freezes-not-destroys change
 * (docs/lab/walkin/… the walk-in reaper now parks a left-behind clone instead
 * of killing it, so the visitor can come back to exactly what they left).
 *
 * `secondsLeft` is a SNAPSHOT at response time, not a source of truth the UI
 * can free-run forever: `/walkin/state` is polled every 15s (usePools.ts), so
 * a client that just decremented a local number between polls would drift out
 * from under the reaper's own clock — especially across a backgrounded tab,
 * where `setInterval` is throttled or paused outright and a naive counter
 * would either freeze or, worse, catch up in one big jump that reads as a
 * glitch. `useHolds` (walkin/useHolds.ts) resolves this by re-deriving an
 * absolute deadline from each poll's `secondsLeft` and ticking wall-clock time
 * against THAT, never against its own last-rendered number.
 */
export type WalkinHold = { os: string; clone: string; secondsLeft: number };

export type WalkinState = {
  access: WalkinAccess; pools: WalkinPool[]; notice?: string;
  anon?: WalkinAnonBudget;
  /**
   * Present only for a caller who currently holds frozen machines; absent and
   * `[]` mean the same thing (nothing held) and callers should treat them
   * identically rather than branching on presence. The station the visitor is
   * ACTIVELY driving is never in this list — only the ones they switched away
   * from and that are still reserved for them.
   */
  holds?: WalkinHold[];
};
/** `resumed`: the broker handed back the clone this account ALREADY held (a
 *  reload, a back-navigation); `ttlSeconds` is then what was left, not a fresh
 *  session. Ledger §7. */
export type WalkinClaim = {
  clone: string; signalEndpoint: string; ttlSeconds: number; resumed?: boolean;
  /** The station the broker CHOSE. Present since the landing page claims with
   *  no `os` and lets the server pick one at random — without this the client
   *  would have to guess what it is showing from the clone id. */
  station?: string;
};
export type WalkinQueued = { queued: true; position: number };
export type WalkinAdminStatus = {
  access: WalkinAccess; envFloor: WalkinAccess;
  sessions: number; pools: WalkinPool[]; accounts: number;
};

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
 * The anonymous visitor's budget — 60 seconds of CONNECTED time, per visitor
 * and not per session, carried across station switches, reloads and
 * back-navigation (docs/lab/walkin/LANDING-REDESIGN-CONTRACT.md, "The
 * anonymous budget").
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
  /** Reserved for 120s after exhaustion, so registering resumes THE SAME machine. */
  heldClone?: string;
};
export type WalkinState = {
  access: WalkinAccess; pools: WalkinPool[]; notice?: string;
  anon?: WalkinAnonBudget;
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

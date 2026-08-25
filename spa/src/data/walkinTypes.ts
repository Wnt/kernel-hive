// Shared walk-in types — the SPA half of the walk-in HTTP contract.
//
// VERBATIM from docs/lab/walkin/CONTRACT-LEDGER.md §7. Lane 4 (walk-in UI)
// creates this file; lane 5 (admin UI) imports it and never edits it. If a
// shape here has to change, the LEDGER changes first and both lanes follow —
// do not widen a type locally to make one call site compile.
export type WalkinAccess = 'closed' | 'invited' | 'open';
export type WalkinPool = { os: string; free: number; size: number };
export type WalkinState = { access: WalkinAccess; pools: WalkinPool[]; notice?: string };
export type WalkinClaim = { clone: string; signalEndpoint: string; ttlSeconds: number };
export type WalkinQueued = { queued: true; position: number };
export type WalkinAdminStatus = {
  access: WalkinAccess; envFloor: WalkinAccess;
  sessions: number; pools: WalkinPool[]; accounts: number;
};

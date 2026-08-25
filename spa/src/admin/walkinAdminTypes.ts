// Local stand-in for the walk-in admin slice of `spa/src/data/walkinTypes.ts`
// (docs/lab/walkin/CONTRACT-LEDGER.md §7). Lane 4 owns that file and creates it
// verbatim from the ledger's type block in its first commit; this lane may
// never edit it. At the time this file was written it had not landed yet, so
// these types are copied from the SAME ledger block rather than invented —
// delete this file and import from '../data/walkinTypes' once lane 4 lands,
// then rebase before pushing (ledger §7).

export type WalkinAccess = 'closed' | 'invited' | 'open';

type WalkinPool = { os: string; free: number; size: number };

export type WalkinAdminStatus = {
  access: WalkinAccess;
  envFloor: WalkinAccess;
  sessions: number;
  pools: WalkinPool[];
  accounts: number;
};

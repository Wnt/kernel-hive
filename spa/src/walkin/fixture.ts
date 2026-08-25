import type { WalkinClaim, WalkinPool, WalkinQueued, WalkinState } from '../data/walkinTypes';

// LOCAL DEVELOPMENT FIXTURE for the walk-in plane.
//
// Lanes 1 (broker) and 2 (auth) build the server halves in parallel with this
// UI, so until their routes are deployed nothing answers /walkin/*. Rather than
// wait — or, worse, ship a UI whose empty/error path is the only one anyone has
// ever seen — the client falls back to this in-memory stand-in (api.ts,
// `withFixture`), which implements exactly the shapes CONTRACT-LEDGER §3
// promises and nothing else. It is NOT server logic: no pooling, no lifetimes,
// no persistence. It exists so the three surfaces can be rendered and eyeballed.
//
// It also gives the smoke check its lever: `?walkin=closed` forces the closed
// access state, `?walkin=queued` forces the queue answer, so the states a real
// backend produces rarely can be looked at on demand.

// The three playable stations (WALKIN-BRIEF §3), in the landing page's order.
export const WALKIN_OS_IDS = ['win311', 'os2warp', 'rhapsody'] as const;

function query(): string {
  if (typeof location === 'undefined') return '';
  return new URLSearchParams(location.search).get('walkin') ?? '';
}

const pools = new Map<string, WalkinPool>(
  WALKIN_OS_IDS.map((os) => [os, { os, free: os === 'rhapsody' ? 0 : 2, size: 3 }]),
);

function state(): WalkinState {
  const forced = query();
  if (forced === 'closed') {
    return {
      access: 'closed',
      pools: [],
      notice: 'The walk-in machines are off while the lab is being worked on.',
    };
  }
  return { access: forced === 'invited' ? 'invited' : 'open', pools: [...pools.values()] };
}

function claim(os: string): WalkinClaim | WalkinQueued {
  if (query() === 'queued') return { queued: true, position: 2 };
  const pool = pools.get(os);
  if (pool && pool.free === 0) return { queued: true, position: 1 };
  if (pool) pool.free = Math.max(0, pool.free - 1);
  return {
    // The clone identity form is frozen in §5.1: walkin-<os>-<n>.
    clone: `walkin-${os}-1`,
    // With no broker there is no per-clone signaling document, so the fixture
    // points at the STATION's own endpoint — the same document the invited
    // gallery streams. That makes the play surface real to look at on a staged
    // build; the live plane replaces it with the clone's own endpoint.
    signalEndpoint: `/signal/${os}.json`,
    ttlSeconds: 1200,
  };
}

function reset(clone: string): WalkinClaim | WalkinQueued {
  const os = clone.replace(/^walkin-/, '').replace(/-\d+$/, '');
  return claim(os);
}

function release(clone: string): void {
  const os = clone.replace(/^walkin-/, '').replace(/-\d+$/, '');
  const pool = pools.get(os);
  if (pool) pool.free = Math.min(pool.size, pool.free + 1);
}

/** Is a preview state forced on this tab by `?walkin=…`? */
function forced(): boolean {
  return query() !== '';
}

export const walkinFixture = { state, claim, reset, release, forced };

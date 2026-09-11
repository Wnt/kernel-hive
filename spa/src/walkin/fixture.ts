import type { WalkinAnonBudget, WalkinClaim, WalkinPool, WalkinQueued, WalkinState } from '../data/walkinTypes';

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
  return {
    access: forced === 'invited' ? 'invited' : 'open',
    pools: [...pools.values()],
    // `?walkin=anon` previews the ANONYMOUS visitor: the intro-time budget
    // (`auth/anon.py BUDGET_SECONDS`), the countdown mirroring it and the wall
    // at zero. There is no other way to look at that state on a staged build,
    // which has no auth plane behind it and therefore reads every visitor as
    // already signed in. Same lever, same rule as the states above: this
    // tab's rendering, nothing else.
    anon: forced === 'anon' ? anonBudget() : undefined,
  };
}

// The preview budget ticks down in real time, so both the countdown and the
// wall at zero can be seen without editing anything. Uses the same clock the
// real one does: elapsed wall time, recomputed per poll, never accumulated —
// and, since 2026-09-10, started by the visitor's FIRST TOUCH rather than by
// the page load. A preview that started counting on arrival would show the
// exact behaviour the engagement rule exists to remove.
const ANON_BUDGET_SECONDS = 300;
let anonEngagedAt: number | null = null;

function anonBudget(): WalkinAnonBudget {
  const spent = anonEngagedAt === null ? 0 : Math.floor((Date.now() - anonEngagedAt) / 1000);
  const remainingSeconds = Math.max(0, ANON_BUDGET_SECONDS - spent);
  return {
    budgetSeconds: ANON_BUDGET_SECONDS,
    remainingSeconds,
    expired: remainingSeconds <= 0,
    engaged: anonEngagedAt !== null,
  };
}

/** The visitor touched the machine — the preview's half of `/walkin/engage`. */
function engage(_clone: string): void {
  if (anonEngagedAt === null) anonEngagedAt = Date.now();
}

function claim(os?: string): WalkinClaim | WalkinQueued {
  if (query() === 'queued') return { queued: true, position: 2 };
  // No `os` ⇒ the server picks, uniformly, among the pools with free capacity.
  // The fixture picks the same way so the landing page's random-station path is
  // the one being looked at, not a hard-wired first entry that would hide a
  // switcher that never changes anything.
  const station = os ?? randomFreeStation();
  if (station === null) return { queued: true, position: 1 };
  const pool = pools.get(station);
  if (pool && pool.free === 0) return { queued: true, position: 1 };
  if (pool) pool.free = Math.max(0, pool.free - 1);
  return {
    // The clone identity form is frozen in §5.1: walkin-<os>-<n>.
    clone: `walkin-${station}-1`,
    station,
    // With no broker there is no per-clone signaling document, so the fixture
    // points at the STATION's own endpoint — the same document the invited
    // gallery streams. That makes the play surface real to look at on a staged
    // build; the live plane replaces it with the clone's own endpoint.
    signalEndpoint: `/signal/${station}.json`,
    ttlSeconds: 1200,
  };
}

function randomFreeStation(): string | null {
  const free = [...pools.values()].filter((pool) => pool.free > 0);
  if (free.length === 0) return null;
  return free[Math.floor(Math.random() * free.length)].os;
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

export const walkinFixture = { state, claim, engage, reset, release, forced };

import type { WalkinClaim, WalkinQueued, WalkinState } from '../data/walkinTypes';
import { walkinFixture } from './fixture';

// The walk-in HTTP client — CONTRACT-LEDGER §3, and nothing but §3.
//
// Every route here is frozen in the ledger; lane 1 (broker) and lane 2 (auth)
// are building the server halves in parallel. This module therefore codes
// against the CONTRACT, never against their trees, and falls back to a local
// FIXTURE (fixture.ts) when a route is not there yet, so the three surfaces can
// be built and eyeballed before either backend lands. The fixture only ever
// answers a 404/network miss: the instant a real route exists it wins, with no
// flag to remember to turn off.

// '/' for the live gallery, '/staging/<session>/' for a staged UI. Same
// defensive read as data/galleryManifest.ts — the registry checks import SPA
// modules under plain node, where import.meta.env does not exist.
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

/** An error carrying the server's own wording, plus the body `error` code. */
export class WalkinApiError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(message: string, code: string, status: number) {
    super(message);
    this.name = 'WalkinApiError';
    this.code = code;
    this.status = status;
  }
}

/** True when the walk-in plane refused because access is Closed (§3, 403). */
export function isClosedError(error: unknown): boolean {
  return error instanceof WalkinApiError && error.code === 'walkin_closed';
}

function url(path: string): string {
  return `${RUNTIME_BASE}${path.replace(/^\//, '')}`;
}

/** A route the SPA's history fallback answered instead of the broker. Signalled
 *  with a 404 so it takes the same "not built yet" path as a real 404. */
const NOT_JSON = new WalkinApiError('route not deployed', 'not_json', 404);

/** One JSON call. GET when `body` is omitted, POST otherwise. */
async function call<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(url(path), {
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
    cache: 'no-store',
  });
  // A missing walk-in route does NOT 404 on this origin: the SPA server's
  // history fallback hands back index.html with a 200, which json() then
  // chokes on. Without this check the UI sits on "checking…" forever instead
  // of falling through to the fixture — which is exactly what the first staged
  // build did. So an OK response that is not JSON means the route is not there.
  const kind = response.headers.get('content-type') ?? '';
  if (response.ok && !kind.includes('json')) throw NOT_JSON;
  let data: Record<string, unknown> = {};
  try { data = (await response.json()) as Record<string, unknown>; } catch { /* a body-less error is still an error */ }
  if (response.ok && !data) throw NOT_JSON;
  if (!response.ok) {
    const code = typeof data.error === 'string' ? data.error : `http_${response.status}`;
    throw new WalkinApiError(code.replace(/_/g, ' '), code, response.status);
  }
  return data as T;
}

/** A route lane 1/lane 2 has not deployed yet answers 404 (or nothing at all).
 *  That is the ONLY case the fixture is allowed to cover. */
function notBuiltYet(error: unknown): boolean {
  if (error instanceof WalkinApiError) return error.status === 404;
  return error instanceof TypeError; // fetch failed outright (dev server, offline)
}

async function withFixture<T>(path: string, live: () => Promise<T>, stub: () => T): Promise<T> {
  try {
    return await live();
  } catch (error) {
    if (!notBuiltYet(error)) throw error;
    console.warn(`[walkin] ${path} is not deployed yet — using the local fixture`);
    return stub();
  }
}

export function fetchWalkinState(): Promise<WalkinState> {
  return withFixture('/walkin/state', () => call<WalkinState>('/walkin/state'), () => walkinFixture.state());
}

export function claimWalkin(os: string): Promise<WalkinClaim | WalkinQueued> {
  return withFixture(
    '/walkin/claim',
    () => call<WalkinClaim | WalkinQueued>('/walkin/claim', { os }),
    () => walkinFixture.claim(os),
  );
}

export function resetWalkin(clone: string): Promise<WalkinClaim | WalkinQueued> {
  return withFixture(
    '/walkin/reset',
    () => call<WalkinClaim | WalkinQueued>('/walkin/reset', { clone }),
    () => walkinFixture.reset(clone),
  );
}

export function releaseWalkin(clone: string): Promise<void> {
  return withFixture('/walkin/release', async () => { await call('/walkin/release', { clone }); }, () => {
    walkinFixture.release(clone);
  });
}

/** A claim response is either the clone or a queue position. */
export function isQueued(result: WalkinClaim | WalkinQueued): result is WalkinQueued {
  return (result as WalkinQueued).queued === true;
}

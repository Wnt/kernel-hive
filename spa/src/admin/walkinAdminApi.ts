// Fetch wrapper for the /auth/walkin/* admin routes (CONTRACT-LEDGER.md §3).
// Same shape as scripts/serve/authui/common.js's api(): same-origin session
// cookie, JSON in, JSON out, the server's own error text surfaced verbatim.
// A separate copy because the authui pages are plain JS with no build step
// linking them to this bundle (see the note in app.css) — this one is typed.

import type { WalkinAccess, WalkinAdminStatus } from '../data/walkinTypes';

const ACCESS_VALUES = new Set(['closed', 'invited', 'open']);
function isAccess(v: unknown): v is WalkinAccess {
  return typeof v === 'string' && ACCESS_VALUES.has(v);
}

// The dev/staging server answers an unimplemented route with the SPA shell
// (200, text/html) rather than a 404 — plausible until lane 2's routes land.
// Validate the shape rather than trusting `response.ok`, so a stray HTML page
// surfaces as "could not load walk-in status", never a crash three renders
// downstream from an all-undefined status object.
function isWalkinAdminStatus(v: unknown): v is WalkinAdminStatus {
  if (typeof v !== 'object' || v === null) return false;
  const s = v as Record<string, unknown>;
  return (
    isAccess(s.access)
    && isAccess(s.envFloor)
    && typeof s.sessions === 'number'
    && typeof s.accounts === 'number'
    && Array.isArray(s.pools)
  );
}

export class WalkinAdminError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

async function call<T>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
    cache: 'no-store',
  });
  let data: unknown = {};
  try {
    data = await response.json();
  } catch {
    // a body-less error is still an error
  }
  if (!response.ok) {
    const message =
      typeof data === 'object' && data !== null && 'error' in data && typeof (data as { error: unknown }).error === 'string'
        ? (data as { error: string }).error
        : `request failed (${response.status})`;
    throw new WalkinAdminError(message, response.status);
  }
  return data as T;
}

export async function fetchWalkinStatus(): Promise<WalkinAdminStatus> {
  const data = await call<unknown>('/auth/walkin/status');
  if (!isWalkinAdminStatus(data)) {
    throw new Error('/auth/walkin/status did not return the expected shape — route not deployed yet?');
  }
  return data;
}

export function setWalkinAccess(access: WalkinAccess): Promise<{ access: WalkinAccess; disconnected: number }> {
  return call('/auth/walkin/access', { access });
}

export function setWalkinDrain(drain: boolean): Promise<{ ok: boolean }> {
  return call('/auth/walkin/drain', { drain });
}

export function purgeWalkinAccounts(olderThanDays: number): Promise<{ purged: number }> {
  return call('/auth/walkin/purge', { olderThanDays });
}

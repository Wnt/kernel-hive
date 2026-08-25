// Fetch wrapper for the /auth/walkin/* admin routes (CONTRACT-LEDGER.md §3).
// Same shape as scripts/serve/authui/common.js's api(): same-origin session
// cookie, JSON in, JSON out, the server's own error text surfaced verbatim.
// A separate copy because the authui pages are plain JS with no build step
// linking them to this bundle (see the note in app.css) — this one is typed.

import type { WalkinAccess, WalkinAdminStatus } from './walkinAdminTypes';

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

export function fetchWalkinStatus(): Promise<WalkinAdminStatus> {
  return call<WalkinAdminStatus>('/auth/walkin/status');
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

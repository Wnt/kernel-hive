// ============================================================================
//  The DELIVERY half of the no-orphan invariant.
//  ---------------------------------------------------------------------------
//  `flushContract.test.ts` pins that a finished trace LEAVES the buffer.
//  This file pins that it survives the trip — because for months it did not,
//  and nothing in the app or the access log said so.
//
//  THE MEASURED FAULT (live gallery, Chrome 150, 2026-09-01). Six senders
//  posted every batch with `keepalive: true`. A document's keepalive allowance
//  is 64 KiB, spent once for its whole life, so ~15 four-KiB posts in and every
//  later keepalive fetch rejected `TypeError: Failed to fetch` — permanently,
//  for that tab. `/traces`, `/analytics`, `/clientlog` and `/logs` all stopped
//  in the same second while `/clientcmd` kept polling and the vendor's `/eum`
//  kept beaconing, so the tab looked perfectly healthy. Each sender swallowed
//  the rejection in a bare `.catch(() => {})`, and `/traces` had already
//  drained its buffer, so the spans were destroyed rather than delayed.
//
//  The daemon's half of an input trace travels by an entirely separate path and
//  kept landing — without its root. 175 of 459 `input.dispatch` spans over
//  24 h (38%) named a parent the store never had.
//
//  So: keepalive on the LAST flush and nothing else, the body always drained,
//  and a batch with no answer kept rather than deleted.
// ============================================================================

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';
import { postTelemetry } from './beacon';

interface Seen { url: string; init: RequestInit }

let seen: Seen[] = [];
let bodiesRead = 0;
const realFetch = globalThis.fetch;

function respond(status: number): Response {
  bodiesRead = 0;
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => { bodiesRead += 1; return ''; },
  } as unknown as Response;
}

beforeEach(() => {
  seen = [];
  bodiesRead = 0;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

function stub(handler: (url: string, init: RequestInit) => Response | Promise<Response>): void {
  globalThis.fetch = vi.fn(async (url: unknown, init: unknown) => {
    seen.push({ url: String(url), init: init as RequestInit });
    return handler(String(url), init as RequestInit);
  }) as unknown as typeof fetch;
}

describe('postTelemetry and the keepalive budget', () => {
  it('does NOT spend the allowance on an ordinary flush', async () => {
    stub(() => respond(200));
    await postTelemetry('/traces', '{}');
    expect(seen[0].init.keepalive).toBe(false);
  });

  it('spends it on the FINAL flush, which is what it is for', async () => {
    stub(() => respond(200));
    await postTelemetry('/traces', '{}', { final: true });
    expect(seen[0].init.keepalive).toBe(true);
  });

  it('always drains the response body', async () => {
    // An undrained response holds its allocation open, which is what turned a
    // per-request budget into a per-document one.
    stub(() => respond(200));
    await postTelemetry('/traces', '{}');
    expect(bodiesRead).toBe(1);
  });

  it('reports a 2xx as sent, so the caller drops the batch', async () => {
    stub(() => respond(200));
    expect(await postTelemetry('/traces', '{}')).toBe('sent');
  });

  it('reports a non-2xx as REFUSED — a settled answer, not a hiccup', async () => {
    // Re-queueing a refusal is how one lost row becomes an unbounded queue of
    // them: a signed-out tab at the walk-in door would 401 forever.
    stub(() => respond(401));
    expect(await postTelemetry('/traces', '{}')).toBe('refused');
  });

  it('reports a rejection as FAILED — the caller keeps the batch', async () => {
    // This is the exact shape of the keepalive-quota rejection, and of an
    // unreachable box. Both mean "no answer", and both must not delete data.
    globalThis.fetch = vi.fn(async () => { throw new TypeError('Failed to fetch'); }) as unknown as typeof fetch;
    expect(await postTelemetry('/traces', '{}')).toBe('failed');
  });

  it('never throws, whatever fetch does', async () => {
    globalThis.fetch = (() => { throw new Error('synchronous boom'); }) as unknown as typeof fetch;
    await expect(postTelemetry('/traces', '{}')).resolves.toBe('failed');
  });

  it('sends same-origin credentials and JSON by default, and lets a caller add headers', async () => {
    stub(() => respond(200));
    await postTelemetry('/clientlog', '[]', { headers: { 'X-Admin-Token': 't' } });
    const h = seen[0].init.headers as Record<string, string>;
    expect(seen[0].init.credentials).toBe('same-origin');
    expect(h['Content-Type']).toBe('application/json');
    expect(h['X-Admin-Token']).toBe('t');
  });
});

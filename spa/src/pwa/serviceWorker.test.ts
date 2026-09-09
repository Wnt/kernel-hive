// Tests for spa/public/sw.js — the PWA service worker, which no bundle
// imports and no other test covers.
//
// WHY THIS FILE EXISTS. On 2026-09-01 a phone ran the gallery, our own
// telemetry plane recorded the visit in full, and the vendor plane recorded
// nothing — and the leading hypothesis was "the installed app is pinned to an
// old HTML shell". It was not (see docs/ANALYTICS.md for how that was settled),
// but the code review it prompted found the trap anyway: the shell cache was
// named by a hand-written `kh-shell-v1` that had never been bumped, and
// `activate` only deletes caches whose key DIFFERS from the current one — so a
// cached shell survived every deploy this gallery has ever had. The name is now
// derived from the build id the registration carries, and these tests pin the
// three properties that makes true: a new build gets a new cache, an old cache
// is actively deleted, and none of the worker's existing virtues moved.
//
// The REAL shipped file is executed (via Vite's `?raw` import and a `new
// Function`, the same technique analytics/indexHtmlBootstrap.test.ts uses on
// index.html) rather than a retyped copy of its logic, which could drift from
// what ships and still pass. sw.js is not a module — it talks to
// `self`/`caches`/`fetch`, so those are passed in as parameters.

import { describe, expect, it } from 'vitest';

import swSource from '../../public/sw.js?raw';

type Handler = (event: FakeEvent) => void;

interface FakeEvent {
  request?: { mode: string };
  waitUntil: (p: Promise<unknown>) => void;
  respondWith: (r: Promise<unknown>) => void;
}

/** A minimal CacheStorage: enough for open/keys/delete/put/match. */
class FakeCaches {
  readonly stores = new Map<string, Map<string, unknown>>();

  async open(name: string) {
    const entries = this.stores.get(name) ?? new Map<string, unknown>();
    this.stores.set(name, entries);
    return {
      put: async (key: string, value: unknown) => { entries.set(key, value); },
      match: async (key: string) => entries.get(key),
    };
  }

  async keys() { return [...this.stores.keys()]; }

  async delete(name: string) { return this.stores.delete(name); }
}

interface Harness {
  handlers: Map<string, Handler>;
  caches: FakeCaches;
  fetched: string[];
  claimed: () => boolean;
  /** Dispatch a lifecycle event and await everything it kept alive. */
  run: (type: string) => Promise<void>;
  /** Dispatch a fetch event; resolves to the response, or undefined when the
   *  worker declined to handle it (which is the contract for everything that is
   *  not a top-level navigation). */
  fetchEvent: (mode: string) => Promise<unknown>;
}

/** Evaluate the shipped sw.js against stubs, with `?build=` on its own URL. */
function loadWorker(scriptUrl: string, online: { ok: boolean; body?: string } | null): Harness {
  const handlers = new Map<string, Handler>();
  const cacheStorage = new FakeCaches();
  const fetched: string[] = [];
  let claimed = false;

  const self = {
    location: { href: scriptUrl },
    addEventListener: (type: string, fn: Handler) => { handlers.set(type, fn); },
    skipWaiting: () => {},
    clients: { claim: async () => { claimed = true; } },
  };
  const fetchStub = async (req: unknown) => {
    fetched.push(typeof req === 'string' ? req : 'navigation');
    if (!online) throw new Error('offline');
    return { ok: online.ok, body: online.body, clone() { return { ...this }; } };
  };
  const ResponseStub = { error: () => 'network-error-response' };

  new Function('self', 'caches', 'fetch', 'Response', swSource)(
    self, cacheStorage, fetchStub, ResponseStub,
  );

  const run = async (type: string) => {
    const kept: Promise<unknown>[] = [];
    handlers.get(type)?.({
      waitUntil: (p) => { kept.push(p); },
      respondWith: () => {},
    });
    await Promise.all(kept);
  };

  const fetchEvent = async (mode: string) => {
    let answered: Promise<unknown> | undefined;
    handlers.get('fetch')?.({
      request: { mode },
      waitUntil: () => {},
      respondWith: (r) => { answered = r; },
    });
    return answered === undefined ? undefined : answered;
  };

  return { handlers, caches: cacheStorage, fetched, claimed: () => claimed, run, fetchEvent };
}

describe('sw.js — the shell cache is named after the build', () => {
  it('caches the shell under the build id the registration carried', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main%40abc1234', { ok: true });
    await w.run('install');
    expect([...w.caches.stores.keys()]).toEqual(['kh-shell-main@abc1234']);
  });

  it('names an honest `unknown` cache rather than faking a build, if the parameter is missing', async () => {
    const w = loadWorker('https://example.com/sw.js', { ok: true });
    await w.run('install');
    expect([...w.caches.stores.keys()]).toEqual(['kh-shell-unknown']);
  });

  it('gives two different builds two different caches — a deploy can no longer reuse one', async () => {
    const a = loadWorker('https://example.com/sw.js?build=main@aaaaaaa', { ok: true });
    const b = loadWorker('https://example.com/sw.js?build=main@bbbbbbb', { ok: true });
    await a.run('install');
    await b.run('install');
    expect([...a.caches.stores.keys()]).not.toEqual([...b.caches.stores.keys()]);
  });
});

describe('sw.js — activate retires every earlier shell', () => {
  it('DELETES the legacy kh-shell-v1 a client is holding today, not merely stops writing it', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', { ok: true });
    // The state of a phone that installed the app any time before this change.
    w.caches.stores.set('kh-shell-v1', new Map([['kh-app-shell', 'ANCIENT HTML']]));
    await w.run('activate');
    expect(w.caches.stores.has('kh-shell-v1')).toBe(false);
  });

  it('keeps its own cache and claims the open clients', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', { ok: true });
    await w.run('install');
    w.caches.stores.set('kh-shell-v1', new Map());
    await w.run('activate');
    expect([...w.caches.stores.keys()]).toEqual(['kh-shell-main@abc1234']);
    expect(w.claimed()).toBe(true);
  });
});

describe('sw.js — the virtues that must not have moved', () => {
  it('handles ONLY top-level navigations; a hashed asset or a POST is left to the network', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', { ok: true });
    expect(await w.fetchEvent('cors')).toBeUndefined();
    expect(await w.fetchEvent('no-cors')).toBeUndefined();
    expect(await w.fetchEvent('navigate')).toBeDefined();
  });

  it('is network-first: the fresh response is returned and becomes the new offline shell', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', { ok: true, body: 'FRESH' });
    const res = await w.fetchEvent('navigate');
    expect((res as { body: string }).body).toBe('FRESH');
    expect(w.caches.stores.get('kh-shell-main@abc1234')?.has('kh-app-shell')).toBe(true);
  });

  it('falls back to the cached shell when the network is gone', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', null);
    w.caches.stores.set('kh-shell-main@abc1234', new Map([['kh-app-shell', 'CACHED']]));
    expect(await w.fetchEvent('navigate')).toBe('CACHED');
  });

  it('never caches a 401 or 5xx as the offline shell', async () => {
    const w = loadWorker('https://example.com/sw.js?build=main@abc1234', { ok: false });
    await w.fetchEvent('navigate');
    expect(w.caches.stores.get('kh-shell-main@abc1234')?.size ?? 0).toBe(0);
  });
});

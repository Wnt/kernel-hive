// Tests for analytics/instana.ts: the config builder (secrets/ignoreUrls
// patterns), the no-key/no-window fallback, and the identity switch this file
// exists to get right — pseudonymous for an anonymous visitor, the real
// account once one exists, and the kernel-hive session id present as `meta`
// in both cases (the join key the whole integration is for).

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import {
  configureInstana,
  configureInstanaIdentity,
  IGNORE_URL_PATTERNS,
  INSTANA_IGNORE_URL_PATTERNS,
  KH_TELEMETRY_PATHS,
  SECRET_PATTERNS,
} from './instana';
import type { Session } from '../data/session';

type Call = [string, ...unknown[]];

function installIneum(): { calls: Call[] } {
  const calls: Call[] = [];
  const fn = (...args: unknown[]) => { calls.push(args as Call); };
  (globalThis as { window?: unknown }).window = { ineum: fn };
  return { calls };
}

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
});

describe('configureInstana', () => {
  it('is a silent no-op with no window.ineum (unconfigured build, or no browser)', () => {
    expect(() => configureInstana('abc123')).not.toThrow();
    expect(() => configureInstanaIdentity({ role: 'admin', name: 'wnt', id: 'u1' })).not.toThrow();
  });

  it('explicitly disables autoPageDetection (navigation.ts drives page transitions) and enables both error wrappers', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls).toContainEqual(['autoPageDetection', false]);
    expect(calls).toContainEqual(['wrapEventHandlers', true]);
    expect(calls).toContainEqual(['wrapTimers', true]);
  });

  it('does NOT set trackSessions, enableW3CHeaders or the initial user id — those moved to index.html\'s bootstrap for the page-load beacon (defect 2/3)', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    const names = calls.map((c) => c[0]);
    expect(names).not.toContain('trackSessions');
    expect(names).not.toContain('enableW3CHeaders');
    expect(calls).not.toContainEqual(['user', 'sess1']);
  });

  it('sets the kernel-hive session id as meta', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls).toContainEqual(['meta', 'kh.sessionId', 'sess1']);
  });

  // Pins the call SHAPE, not just the value: `ineum('meta', ...)` takes ONE
  // key and ONE value per call, both strings — never an object. A previous
  // version called `ineum('meta', { 'kh.sessionId': ..., 'kh.bundle': ... })`,
  // which Instana's agent cannot parse (it stringifies the object as its own
  // key, producing `{'[object Object]': 'undefined'}` on the wire — verified
  // against real production beacons). This must not silently regress.
  it('calls ineum(meta, key, value) once per entry — never an object argument', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    const metaCalls = calls.filter((c) => c[0] === 'meta');
    expect(metaCalls.length).toBeGreaterThanOrEqual(2);
    for (const call of metaCalls) {
      expect(call).toHaveLength(3);
      expect(typeof call[1]).toBe('string');
      expect(typeof call[2]).toBe('string');
    }
    expect(metaCalls).toContainEqual(['meta', 'kh.sessionId', 'sess1']);
    expect(metaCalls.map((c) => c[1])).toContain('kh.bundle');
  });

  it('passes the secrets patterns through unchanged', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls).toContainEqual(['secrets', SECRET_PATTERNS]);
  });

  it('does NOT set ignoreUrls — it moved to index.html\'s bootstrap so a pre-boot request is filtered too (see instana.ts\'s INSTANA_IGNORE_URL_PATTERNS comment)', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls.map((c) => c[0])).not.toContain('ignoreUrls');
  });
});

describe('secrets patterns', () => {
  it('secrets catches traceparent and ticket-shaped parameter names', () => {
    expect(SECRET_PATTERNS.some((re) => re.test('traceparent'))).toBe(true);
    expect(SECRET_PATTERNS.some((re) => re.test('ticket'))).toBe(true);
    expect(SECRET_PATTERNS.some((re) => re.test('unrelated'))).toBe(false);
  });
});

describe('ignoreUrls patterns — the reuse-trap regression', () => {
  // THE EXACT ASSERTION WHOSE ABSENCE LET THE BUG SHIP: the original single
  // list was anchored `^\/`, which can only ever match a bare pathname, and
  // every existing test (like the old "excludes every one of our own
  // telemetry routes" case) tested it exclusively against pathnames — so the
  // suite stayed green while `ineum('ignoreUrls', ...)` silently matched
  // nothing in production. This block pins BOTH shapes against BOTH kinds of
  // input, on purpose.
  const REALISTIC_ORIGIN = 'https://kernelhive.madekivi.fi';

  it('INSTANA_IGNORE_URL_PATTERNS matches a realistic full URL for every telemetry endpoint', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      const full = `${REALISTIC_ORIGIN}${path}${path === '/clientcmd' ? '?since=64' : ''}`;
      expect(INSTANA_IGNORE_URL_PATTERNS.some((re) => re.test(full))).toBe(true);
    }
  });

  it('INSTANA_IGNORE_URL_PATTERNS does NOT match a bare pathname (the shape khFetch uses, not Instana)', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      expect(INSTANA_IGNORE_URL_PATTERNS.some((re) => re.test(path))).toBe(false);
    }
  });

  it('IGNORE_URL_PATTERNS (khFetch\'s form) still matches a bare pathname', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(path))).toBe(true);
    }
  });

  it('IGNORE_URL_PATTERNS does NOT match a full URL — it is anchored for khFetch\'s url.pathname input, not a full string', () => {
    for (const path of KH_TELEMETRY_PATHS) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(`${REALISTIC_ORIGIN}${path}`))).toBe(false);
    }
  });

  it('neither form matches a real app route', () => {
    for (const real of ['/auth/state', '/gallery-manifest.json', '/boot/index.json', '/signal/solaris.json']) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(real))).toBe(false);
      expect(INSTANA_IGNORE_URL_PATTERNS.some((re) => re.test(`${REALISTIC_ORIGIN}${real}`))).toBe(false);
    }
  });

  it('both matcher forms are derived from the same endpoint set, so adding one endpoint covers both', () => {
    expect(IGNORE_URL_PATTERNS).toHaveLength(KH_TELEMETRY_PATHS.length);
    expect(INSTANA_IGNORE_URL_PATTERNS).toHaveLength(KH_TELEMETRY_PATHS.length);
    for (const path of KH_TELEMETRY_PATHS) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(path))).toBe(true);
      expect(INSTANA_IGNORE_URL_PATTERNS.some((re) => re.test(`${REALISTIC_ORIGIN}${path}`))).toBe(true);
    }
  });
});

describe('configureInstanaIdentity', () => {
  let calls: Call[];
  beforeEach(() => { calls = installIneum().calls; });

  it('sends nothing for an anonymous session (already on the pseudonymous id)', () => {
    const anon: Session = { role: 'anon', name: '', id: '' };
    configureInstanaIdentity(anon);
    expect(calls).toEqual([]);
  });

  it('sends nothing when the role is not anon but there is somehow no account id', () => {
    const noId: Session = { role: 'viewer', name: 'nobody', id: '' };
    configureInstanaIdentity(noId);
    expect(calls).toEqual([]);
  });

  it('upgrades to the real account id + display name for a signed-in visitor', () => {
    const admin: Session = { role: 'admin', name: 'wnt', id: 'u1' };
    configureInstanaIdentity(admin);
    expect(calls).toEqual([['user', 'u1', 'wnt']]);
  });

  it('omits the display name argument rather than sending an empty string', () => {
    const noName: Session = { role: 'walkin', name: '', id: 'w9' };
    configureInstanaIdentity(noName);
    expect(calls).toEqual([['user', 'w9', undefined]]);
  });

  it('never sends an email — this auth system has none', () => {
    const admin: Session = { role: 'admin', name: 'wnt', id: 'u1' };
    configureInstanaIdentity(admin);
    expect((calls[0] as Call).length).toBe(3);
  });
});

describe('full flow: anonymous vs signed-in, both carrying the kernel-hive session id', () => {
  // The pseudonymous `ineum('user', sessionId)` call itself now happens in
  // spa/index.html's inline bootstrap, before this module even loads (defect
  // 2/3) — not exercised by these unit tests, which have no HTML bootstrap to
  // run. What remains this module's job: never re-set the pseudonymous id,
  // and set the REAL identity only once one exists.
  it('signed-out visitor: configureInstana sends no user call, configureInstanaIdentity sends none either, meta is still present', () => {
    const { calls } = installIneum();
    const session: Session = { role: 'anon', name: '', id: '' };
    configureInstana('tabsess');
    configureInstanaIdentity(session);
    const userCalls = calls.filter((c) => c[0] === 'user');
    expect(userCalls).toEqual([]);
    expect(calls).toContainEqual(['meta', 'kh.sessionId', 'tabsess']);
  });

  it('signed-in visitor ends up on the real account id via the identity update, with meta still present', () => {
    const { calls } = installIneum();
    const session: Session = { role: 'viewer', name: 'operator', id: 'acct-42' };
    configureInstana('tabsess');
    configureInstanaIdentity(session);
    const userCalls = calls.filter((c) => c[0] === 'user');
    expect(userCalls).toEqual([['user', 'acct-42', 'operator']]);
    expect(calls).toContainEqual(['meta', 'kh.sessionId', 'tabsess']);
  });
});

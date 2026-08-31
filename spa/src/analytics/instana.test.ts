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

  it('configures sessions, explicit page detection, W3C headers and both wrappers', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    const names = calls.map((c) => c[0]);
    expect(names).toContain('trackSessions');
    expect(calls).toContainEqual(['autoPageDetection', true]);
    expect(calls).toContainEqual(['enableW3CHeaders', true]);
    expect(calls).toContainEqual(['wrapEventHandlers', true]);
    expect(calls).toContainEqual(['wrapTimers', true]);
  });

  it('sets the pseudonymous user id and the kernel-hive session id as meta', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls).toContainEqual(['user', 'sess1']);
    const meta = calls.find((c) => c[0] === 'meta');
    expect(meta).toBeTruthy();
    expect((meta as Call)[1]).toMatchObject({ 'kh.sessionId': 'sess1' });
  });

  it('passes the secrets and ignoreUrls patterns through unchanged', () => {
    const { calls } = installIneum();
    configureInstana('sess1');
    expect(calls).toContainEqual(['secrets', SECRET_PATTERNS]);
    expect(calls).toContainEqual(['ignoreUrls', IGNORE_URL_PATTERNS]);
  });
});

describe('secrets / ignoreUrls patterns', () => {
  it('secrets catches traceparent and ticket-shaped parameter names', () => {
    expect(SECRET_PATTERNS.some((re) => re.test('traceparent'))).toBe(true);
    expect(SECRET_PATTERNS.some((re) => re.test('ticket'))).toBe(true);
    expect(SECRET_PATTERNS.some((re) => re.test('unrelated'))).toBe(false);
  });

  it('ignoreUrls excludes every one of our own telemetry routes', () => {
    for (const path of ['/traces', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd']) {
      expect(IGNORE_URL_PATTERNS.some((re) => re.test(path))).toBe(true);
    }
    expect(IGNORE_URL_PATTERNS.some((re) => re.test('/signal/beos.json'))).toBe(false);
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
  it('signed-out visitor ends up on the pseudonymous id, with meta present', () => {
    const { calls } = installIneum();
    const session: Session = { role: 'anon', name: '', id: '' };
    configureInstana('tabsess');
    configureInstanaIdentity(session);
    const userCalls = calls.filter((c) => c[0] === 'user');
    expect(userCalls).toEqual([['user', 'tabsess']]);
    const meta = calls.find((c) => c[0] === 'meta') as Call;
    expect(meta[1]).toMatchObject({ 'kh.sessionId': 'tabsess' });
  });

  it('signed-in visitor ends up on the real account id, with meta still present', () => {
    const { calls } = installIneum();
    const session: Session = { role: 'viewer', name: 'operator', id: 'acct-42' };
    configureInstana('tabsess');
    configureInstanaIdentity(session);
    const userCalls = calls.filter((c) => c[0] === 'user');
    // Pseudonymous first (configureInstana), then the real identity — never
    // the other order, and never skipped.
    expect(userCalls).toEqual([
      ['user', 'tabsess'],
      ['user', 'acct-42', 'operator'],
    ]);
    const meta = calls.find((c) => c[0] === 'meta') as Call;
    expect(meta[1]).toMatchObject({ 'kh.sessionId': 'tabsess' });
  });
});

import { describe, expect, it } from 'vitest';
import { loadSession } from './session';
import { walkinShape } from '../walkin/route';

// The regression this file exists for: a signed-up walk-in browsing the ROOT
// url got a page that loaded and then sat on "Loading the collection…" for
// ever. The gate allows them `/` but refuses `/gallery-manifest.json`, and the
// app chose which half to boot from the PATH, so `/` booted the gallery and its
// first fetch was refused. The role is the question; these tests pin that it is
// the one being asked.

function jsonResponse(body: unknown, ok = true): typeof fetch {
  return (async () => ({
    ok,
    json: async () => body,
  })) as unknown as typeof fetch;
}

describe('loadSession', () => {
  it('reads the role off /auth/state', async () => {
    const session = await loadSession(jsonResponse({ authenticated: true, user: { id: 'w1', name: 'bold-turing', role: 'walkin' } }));
    expect(session).toEqual({ role: 'walkin', name: 'bold-turing', id: 'w1' });
  });

  it('carries the invited roles through unchanged', async () => {
    for (const role of ['admin', 'viewer'] as const) {
      const session = await loadSession(jsonResponse({ authenticated: true, user: { name: 'someone', role } }));
      expect(session.role).toBe(role);
    }
  });

  it('is anon when the listener does not gate — a LAN or staging load', async () => {
    // No /auth plane at all: the request 404s. The gallery must still render,
    // exactly as it does for every lab script and the Playwright suite.
    expect((await loadSession(jsonResponse({}, false))).role).toBe('anon');
    const boom = (async () => { throw new Error('no network'); }) as unknown as typeof fetch;
    expect((await loadSession(boom)).role).toBe('anon');
  });

  it('is anon for an unauthenticated answer, and for a role it does not know', async () => {
    expect((await loadSession(jsonResponse({ authenticated: false }))).role).toBe('anon');
    expect((await loadSession(jsonResponse({ authenticated: true, user: { role: 'root' } }))).role).toBe('anon');
    expect((await loadSession(jsonResponse(null))).role).toBe('anon');
  });
});

describe('walkinShape', () => {
  it('is true for a walk-in ACCOUNT on the root url — the bug this fixes', () => {
    expect(walkinShape('walkin', '/')).toBe(true);
    expect(walkinShape('walkin', '/index.html')).toBe(true);
  });

  it('is true for the signed-out stranger standing at the signup door', () => {
    // They have no role yet, and the gallery's gated fetches must not fire
    // behind the page that hands them an account.
    expect(walkinShape('anon', '/walkin')).toBe(true);
    expect(walkinShape('anon', '/walkin/exhibits')).toBe(true);
  });

  it('leaves the invited plane alone', () => {
    expect(walkinShape('admin', '/')).toBe(false);
    expect(walkinShape('viewer', '/')).toBe(false);
    expect(walkinShape('anon', '/')).toBe(false);
    expect(walkinShape('viewer', '/fleet')).toBe(false);
  });

  it('honours a staged bundle base', () => {
    expect(walkinShape('anon', '/staging/slot/walkin', '/staging/slot/')).toBe(true);
    expect(walkinShape('anon', '/staging/slot/', '/staging/slot/')).toBe(false);
  });
});

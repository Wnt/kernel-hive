import { describe, expect, it } from 'vitest';
import { parseWalkinReason, walkinReasonCopy, WALKIN_CLOSED_COPY } from './reasons';
import { accessAllows, clockText, resolveEndReason } from './sessionEnd';
import { parseExhibit, parseWalkinManifest } from './manifest';
import type { WalkinAdminStatus, WalkinClaim, WalkinQueued, WalkinState } from '../data/walkinTypes';

// Pure-logic cover for the walk-in lane: the reason-code copy (a visitor must
// always learn WHY their session ended), the end-reason resolver, and the
// exhibition-manifest allowlist (§5.3 — a field the server should not have sent
// must not render either).

describe('reason codes', () => {
  it('renders the frozen closed sentence for WALKIN_CLOSED', () => {
    expect(walkinReasonCopy('WALKIN_CLOSED').title).toBe(WALKIN_CLOSED_COPY);
    expect(walkinReasonCopy('WALKIN_CLOSED').retryable).toBe(false);
  });

  it('says how long the session was, in the numbers the broker used', () => {
    expect(walkinReasonCopy('WALKIN_TTL', { ttlSeconds: 1200 }).title).toBe('Your 20 minutes are up.');
    expect(walkinReasonCopy('WALKIN_IDLE', { idleSeconds: 180 }).title).toBe('Ended after 3 minutes idle.');
    expect(walkinReasonCopy('WALKIN_TTL', { ttlSeconds: 600 }).title).toBe('Your 10 minutes are up.');
  });

  it('finds a code whichever road it arrived by, and nothing else', () => {
    expect(parseWalkinReason('WALKIN_TTL')).toBe('WALKIN_TTL');
    expect(parseWalkinReason('session closed: walkin_closed')).toBe('WALKIN_CLOSED');
    expect(parseWalkinReason('SESSION_REJECTED')).toBeNull();
    expect(parseWalkinReason(undefined)).toBeNull();
    expect(parseWalkinReason(17)).toBeNull();
  });
});

describe('resolveEndReason', () => {
  it('lets the broker win over anything observed locally', () => {
    expect(resolveEndReason({ brokerCode: 'WALKIN_IDLE', secondsLeft: -5 })).toBe('WALKIN_IDLE');
  });

  it('falls back to the facts the client can see', () => {
    expect(resolveEndReason({ access: 'closed', allowed: false })).toBe('WALKIN_CLOSED');
    expect(resolveEndReason({ secondsLeft: 0 })).toBe('WALKIN_TTL');
    expect(resolveEndReason({ idleSeconds: 200 })).toBe('WALKIN_IDLE');
    expect(resolveEndReason({ idleSeconds: 200, idleWindowSeconds: 600 })).toBeNull();
  });

  it('claims nothing when no walk-in fact explains the drop', () => {
    expect(resolveEndReason({ access: 'open', allowed: true, secondsLeft: 400, idleSeconds: 2 })).toBeNull();
  });
});

describe('accessAllows / clockText', () => {
  it('closes for everyone at Closed and only for walk-ins at Invited', () => {
    expect(accessAllows('open', 'walkin')).toBe(true);
    expect(accessAllows('invited', 'walkin')).toBe(false);
    expect(accessAllows('invited', 'admin')).toBe(true);
    expect(accessAllows('closed', 'admin')).toBe(false);
  });

  it('never shows a negative clock', () => {
    expect(clockText(1200)).toBe('20:00');
    expect(clockText(65)).toBe('1:05');
    expect(clockText(-9)).toBe('0:00');
  });
});

describe('exhibition manifest projection', () => {
  const row = {
    id: 'os2warp', displayName: 'OS/2 Warp 4', year: 1996, era: '1990s',
    eraLabel: '1996 · OS/2 Warp 4', lineage: 'IBM', arch: 'x86', accent: '#1e5aa8',
    blurb: 'IBM takes on Windows', eraSoftware: ['Netscape'], iconicApps: ['VoiceType'],
    // Fields a walk-in may NOT see (§5.3) — present here on purpose.
    signalEndpoint: '/signal/os2warp.json', transport: 'streamhost', endpoint: 'x',
  };

  it('keeps the exhibition fields and drops the interactive ones', () => {
    const exhibit = parseExhibit(row);
    expect(exhibit?.displayName).toBe('OS/2 Warp 4');
    expect(exhibit?.eraSoftware).toEqual(['Netscape']);
    expect(Object.keys(exhibit ?? {})).not.toContain('signalEndpoint');
    expect(Object.keys(exhibit ?? {})).not.toContain('transport');
  });

  it('hides a soft-hidden station and sorts the rest chronologically', () => {
    const parsed = parseWalkinManifest({
      entries: [
        { ...row, id: 'winxp', displayName: 'Windows XP', year: 2001 },
        row,
        { ...row, id: 'secret', displayName: 'Dark launch', listed: false },
      ],
    });
    expect(parsed.map((e) => e.id)).toEqual(['os2warp', 'winxp']);
  });

  it('ignores rows that are not exhibits', () => {
    expect(parseExhibit(null)).toBeNull();
    expect(parseExhibit({ id: 'x' })).toBeNull();
    expect(parseWalkinManifest('nope')).toEqual([]);
  });
});

// The shared types are the CONTRACT (ledger §7): this asserts the shapes both
// lanes compile against, including the admin status lane 5 imports.
describe('shared walk-in types', () => {
  it('accepts the ledger examples verbatim', () => {
    const state: WalkinState = { access: 'open', pools: [{ os: 'os2warp', free: 2, size: 3 }] };
    const claim: WalkinClaim = { clone: 'walkin-os2warp-3', signalEndpoint: '/signal/walkin-os2warp-3.json', ttlSeconds: 1200 };
    const queued: WalkinQueued = { queued: true, position: 2 };
    const status: WalkinAdminStatus = { access: 'invited', envFloor: 'open', sessions: 3, pools: state.pools, accounts: 41 };
    expect([state.pools[0].free, claim.ttlSeconds, queued.position, status.accounts]).toEqual([2, 1200, 2, 41]);
  });
});

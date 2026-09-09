import { describe, expect, it } from 'vitest';
import { WalkinApiError } from './api';
import {
  phaseAfterClaim,
  phaseAfterClaimError,
  playAgainLabel,
  reclaimsOnPageShow,
  releasesCloneOnEnd,
} from './playPhase';

// The reload bug, as a contract: a reload (or a back-navigation) must land the
// visitor back on their own live cell, or on a free one — never on an ended
// card with a retry that cannot succeed.

const claim = { clone: 'walkin-win311-1', signalEndpoint: '/signal/walkin-win311-1.json', ttlSeconds: 900 };

describe('phaseAfterClaim', () => {
  it('plays a fresh claim', () => {
    expect(phaseAfterClaim(claim)).toEqual({ kind: 'playing', claim, resumed: false });
  });

  it('re-attaches to the visitor\'s own cell when the broker says resumed, clock intact', () => {
    const back = { ...claim, resumed: true };
    const phase = phaseAfterClaim(back);
    expect(phase.kind).toBe('playing');
    if (phase.kind !== 'playing') throw new Error('unreachable');
    expect(phase.resumed).toBe(true);
    expect(phase.claim.clone).toBe('walkin-win311-1');
    // The TTL is whatever was LEFT, not a new 20 minutes.
    expect(phase.claim.ttlSeconds).toBe(900);
  });

  it('queues when every cell is busy', () => {
    expect(phaseAfterClaim({ queued: true, position: 2 })).toEqual({ kind: 'queued', position: 2 });
  });
});

describe('phaseAfterClaimError', () => {
  it('names closed access by its reason code', () => {
    const closed = new WalkinApiError('walkin closed', 'walkin_closed', 403);
    expect(phaseAfterClaimError(closed)).toEqual({ kind: 'ended', reason: 'WALKIN_CLOSED' });
  });

  it('carries the broker\'s own wording for anything else', () => {
    const refused = new WalkinApiError('walkin-win311-1 would not resume: boom', 'http_400', 400);
    expect(phaseAfterClaimError(refused)).toEqual({
      kind: 'ended', reason: null, message: 'walkin-win311-1 would not resume: boom',
    });
    expect(phaseAfterClaimError('??')).toMatchObject({ kind: 'ended', reason: null });
  });
});

describe('the way back in', () => {
  it('releases a clone whose time is up so Play again gets a fresh one', () => {
    expect(releasesCloneOnEnd('WALKIN_TTL')).toBe(true);
    expect(releasesCloneOnEnd('WALKIN_IDLE')).toBe(true);
  });

  it('leaves a closed-access teardown to the broker', () => {
    expect(releasesCloneOnEnd('WALKIN_CLOSED')).toBe(false);
    expect(releasesCloneOnEnd(null)).toBe(false);
  });

  it('always has a label — closed access included', () => {
    for (const reason of ['WALKIN_CLOSED', 'WALKIN_TTL', 'WALKIN_IDLE', null] as const) {
      expect(playAgainLabel(reason).length).toBeGreaterThan(0);
    }
    expect(playAgainLabel('WALKIN_CLOSED')).toBe('Check again');
    expect(playAgainLabel('WALKIN_TTL')).toBe('Play again');
  });

  it('re-claims when the browser restores the page from the back/forward cache', () => {
    expect(reclaimsOnPageShow(true)).toBe(true);
    expect(reclaimsOnPageShow(false)).toBe(false);
  });
});

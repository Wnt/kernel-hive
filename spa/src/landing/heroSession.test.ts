import { describe, expect, it } from 'vitest';
import { WalkinApiError } from '../walkin/api';
import type { WalkinClaim } from '../data/walkinTypes';
import {
  heldClone,
  isBusy,
  liveStation,
  phaseAfterHeroClaim,
  phaseAfterHeroClaimError,
  stationOfClaim,
  stationOfClone,
  switchPlan,
  type HeroPhase,
} from './heroSession';

// The landing hero's sequencing. These are the rules that spend cells and
// throw away the visitor's work when they are wrong, and the ONLY gate on them:
// vitest runs under plain Node with no jsdom (vitest.config.ts), so there is no
// render test in this repo that could catch a switch that claims before it
// releases.

const claim = (over: Partial<WalkinClaim> = {}): WalkinClaim => ({
  clone: 'walkin-win311-2',
  signalEndpoint: '/signal/walkin-win311-2.json',
  ttlSeconds: 60,
  ...over,
});

const live = (station: string, clone: string): HeroPhase => ({
  kind: 'live',
  station,
  claim: claim({ clone, station }),
});

describe('stationOfClone', () => {
  it('reads the station out of the frozen clone form', () => {
    expect(stationOfClone('walkin-os2warp-3')).toBe('os2warp');
    expect(stationOfClone('walkin-win311-11')).toBe('win311');
  });

  it('leaves a clone id it does not recognise alone', () => {
    expect(stationOfClone('something-else')).toBe('something-else');
  });
});

describe('stationOfClaim', () => {
  it('believes the server over everything else', () => {
    // The whole reason `station` was added to the response: the page claims
    // with no `os`, so it cannot know what it asked for.
    expect(stationOfClaim(claim({ station: 'rhapsody', clone: 'walkin-win311-1' }), 'win311'))
      .toBe('rhapsody');
  });

  it('falls back to the clone id when a broker has not shipped `station` yet', () => {
    expect(stationOfClaim(claim({ clone: 'walkin-os2warp-1' }), null)).toBe('os2warp');
  });

  it('uses what we asked for only when the clone id carries nothing', () => {
    expect(stationOfClaim(claim({ clone: 'opaque' }), 'win311')).toBe('win311');
  });
});

describe('phaseAfterHeroClaim', () => {
  it('goes live on a clone, naming the station the SERVER chose', () => {
    const phase = phaseAfterHeroClaim(claim({ station: 'rhapsody' }), null);
    expect(phase.kind).toBe('live');
    expect(liveStation(phase)).toBe('rhapsody');
    expect(heldClone(phase)).toBe('walkin-win311-2');
  });

  it('keeps the queue position and what was asked for', () => {
    expect(phaseAfterHeroClaim({ queued: true, position: 3 }, 'os2warp')).toEqual({
      kind: 'queued',
      want: 'os2warp',
      position: 3,
    });
  });
});

describe('phaseAfterHeroClaimError', () => {
  it('tells an exhausted budget apart from a shut door', () => {
    const budget = phaseAfterHeroClaimError(
      new WalkinApiError('anon budget', 'WALKIN_ANON_BUDGET', 403),
    );
    expect(budget).toMatchObject({ kind: 'refused', code: 'budget' });
  });

  it('matches the budget code in either casing the wire might use', () => {
    const lower = phaseAfterHeroClaimError(new WalkinApiError('x', 'walkin_anon_budget', 403));
    expect(lower).toMatchObject({ code: 'budget' });
  });

  it('reports a closed door as closed, not as an error', () => {
    const closed = phaseAfterHeroClaimError(new WalkinApiError('closed', 'walkin_closed', 403));
    expect(closed).toMatchObject({ kind: 'refused', code: 'closed' });
  });

  it('keeps the server wording for anything else', () => {
    const other = phaseAfterHeroClaimError(new Error('pool is on fire'));
    expect(other).toMatchObject({ code: 'error', message: 'pool is on fire' });
  });

  it('survives a thrown non-Error', () => {
    expect(phaseAfterHeroClaimError('nope')).toMatchObject({ code: 'error' });
  });
});

describe('switchPlan', () => {
  it('claims and nothing else when the page holds no cell', () => {
    expect(switchPlan({ kind: 'idle' }, 'os2warp')).toEqual([{ op: 'claim', os: 'os2warp' }]);
  });

  it('releases BEFORE it claims — one clone per account', () => {
    // Claim-first retires the cell that is on screen, so the frame the visitor
    // is driving disappears before its replacement exists.
    expect(switchPlan(live('win311', 'walkin-win311-2'), 'rhapsody')).toEqual([
      { op: 'release', clone: 'walkin-win311-2' },
      { op: 'claim', os: 'rhapsody' },
    ]);
  });

  it('does NOTHING when the target is already on screen', () => {
    // On the anonymous plane a re-claim spends part of a 60-second budget to
    // arrive back where you already were, and it throws away the visitor's work.
    expect(switchPlan(live('win311', 'walkin-win311-2'), 'win311')).toEqual([]);
  });

  it('re-rolls a held cell when the target is "any machine"', () => {
    expect(switchPlan(live('win311', 'walkin-win311-2'), null)).toEqual([
      { op: 'release', clone: 'walkin-win311-2' },
      { op: 'claim', os: null },
    ]);
  });

  it('never emits a release for a phase that holds no clone', () => {
    for (const phase of [
      { kind: 'queued', want: 'win311', position: 1 },
      { kind: 'refused', code: 'error', message: 'x' },
      { kind: 'claiming', want: null },
      { kind: 'stopped', station: 'win311', reason: 'never-driven' },
      { kind: 'stopped', station: 'win311', reason: 'left' },
    ] as HeroPhase[]) {
      expect(switchPlan(phase, 'win311')).toEqual([{ op: 'claim', os: 'win311' }]);
    }
  });
});

describe('heldClone', () => {
  it('is null for every phase but a live one — a release needs a real clone', () => {
    for (const phase of [
      { kind: 'idle' },
      { kind: 'claiming', want: 'win311' },
      { kind: 'queued', want: 'win311', position: 2 },
      { kind: 'stopped', station: 'win311', reason: 'hidden' },
      { kind: 'refused', code: 'budget', message: 'x' },
    ] as HeroPhase[]) {
      expect(heldClone(phase)).toBeNull();
      expect(liveStation(phase)).toBeNull();
    }
  });
});

describe('isBusy', () => {
  it('is true only while a claim is in flight', () => {
    expect(isBusy({ kind: 'claiming', want: null })).toBe(true);
    expect(isBusy(live('win311', 'walkin-win311-1'))).toBe(false);
    expect(isBusy({ kind: 'idle' })).toBe(false);
  });
});

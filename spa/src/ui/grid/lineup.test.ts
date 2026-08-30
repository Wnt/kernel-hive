import { describe, expect, it } from 'vitest';
import { cardTarget, isPlayableByWalkin, visibleLineup } from './lineup';
import { WALKIN_OS_IDS } from '../../walkin/fixture';

// One grid now serves both visitor classes, so the rules that used to be "which
// of two apps booted" are these functions. They are the difference between a
// walk-in being offered a machine and being offered a door that slams.

const LINEUP = [
  { id: 'win311' },
  { id: 'irix' },
  { id: 'os2warp' },
  { id: 'tru64' },
  { id: 'rhapsody' },
];

describe('cardTarget', () => {
  it('sends an invited visitor to the station console, as it always did', () => {
    expect(cardTarget('irix', false)).toEqual({ kind: 'stream', to: '/os/irix' });
    // Even for a station that happens to be on walk-in duty: an invited
    // visitor drives the museum's own machine, never a pool clone.
    expect(cardTarget('win311', false)).toEqual({ kind: 'stream', to: '/os/win311' });
  });

  it('sends a walk-in to their own clone for the machines they may drive', () => {
    for (const os of WALKIN_OS_IDS) {
      expect(cardTarget(os, true)).toEqual({ kind: 'clone', to: `/walkin/play/${os}` });
    }
  });

  it('never offers a walk-in a station stream — the gate would refuse it', () => {
    for (const os of ['irix', 'tru64', 'nextstep']) {
      expect(cardTarget(os, true)).toEqual({ kind: 'placard' });
    }
  });
});

describe('visibleLineup', () => {
  it('shows an invited visitor everything, at either scope', () => {
    expect(visibleLineup(LINEUP, false, 'playable')).toHaveLength(5);
    expect(visibleLineup(LINEUP, false, 'all')).toHaveLength(5);
  });

  it('defaults a walk-in to the machines they came for', () => {
    expect(visibleLineup(LINEUP, true, 'playable').map((v) => v.id))
      .toEqual(['win311', 'os2warp', 'rhapsody']);
  });

  it('opens the whole museum to a walk-in when they ask for it', () => {
    expect(visibleLineup(LINEUP, true, 'all').map((v) => v.id)).toEqual(LINEUP.map((v) => v.id));
  });

  it('cannot widen past what it was given — the projection is the fence', () => {
    // The store holds the server's allowlist projection for a walk-in, so
    // "all" is all of THAT, never the fleet manifest.
    const projected = [{ id: 'win311' }, { id: 'irix' }];
    expect(visibleLineup(projected, true, 'all')).toEqual(projected);
  });
});

describe('isPlayableByWalkin', () => {
  it('is exactly the three stations on walk-in duty', () => {
    expect(WALKIN_OS_IDS.filter(isPlayableByWalkin)).toEqual([...WALKIN_OS_IDS]);
    expect(isPlayableByWalkin('irix')).toBe(false);
  });
});

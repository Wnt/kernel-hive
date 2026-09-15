import { describe, expect, it } from 'vitest';
import { formatHold, holdDeadlines, tickSecondsLeft } from './useHolds';
import type { WalkinHold } from '../data/walkinTypes';

// Pure-logic cover for the held-machine countdown (useHolds.ts) — the React
// wrapper is deliberately three lines of useState/useEffect around these
// functions precisely so the behaviour that matters (absent vs empty holds,
// local tick-down, re-sync from a poll, never negative) is testable without a
// DOM timer or a hook-rendering harness this repo does not otherwise use.

const NOW = 1_726_000_000_000; // arbitrary fixed epoch ms

describe('holdDeadlines', () => {
  it('is the same {} for absent holds and for []', () => {
    // The contract is explicit that these mean the same thing; a caller must
    // never be able to observe a difference by branching on `holds` being
    // undefined vs empty.
    expect(holdDeadlines(undefined, NOW)).toEqual({});
    expect(holdDeadlines([], NOW)).toEqual({});
  });

  it('projects each hold to an absolute deadline from its secondsLeft snapshot', () => {
    const holds: WalkinHold[] = [
      { os: 'win311', clone: 'walkin-win311-3', secondsLeft: 241 },
      { os: 'rhapsody', clone: 'walkin-rhapsody-1', secondsLeft: 10 },
    ];
    expect(holdDeadlines(holds, NOW)).toEqual({
      win311: NOW + 241_000,
      rhapsody: NOW + 10_000,
    });
  });

  it('never manufactures a deadline in the past from a hostile secondsLeft', () => {
    // A negative or zero secondsLeft should never push the deadline BEFORE
    // `now` — clamped to now, so a malformed snapshot reads as "about to
    // expire", never as "already held before the poll landed".
    expect(holdDeadlines([{ os: 'win311', clone: 'c', secondsLeft: -5 }], NOW)).toEqual({ win311: NOW });
  });
});

describe('tickSecondsLeft', () => {
  it('ticks a deadline down as wall time passes, without needing a new poll', () => {
    const deadlines = holdDeadlines([{ os: 'win311', clone: 'c', secondsLeft: 241 }], NOW);
    expect(tickSecondsLeft(deadlines, NOW)).toEqual({ win311: 241 });
    expect(tickSecondsLeft(deadlines, NOW + 60_000)).toEqual({ win311: 181 });
    expect(tickSecondsLeft(deadlines, NOW + 240_000)).toEqual({ win311: 1 });
  });

  it('drops a station the instant its deadline passes, rather than clamping at 0', () => {
    const deadlines = holdDeadlines([{ os: 'win311', clone: 'c', secondsLeft: 5 }], NOW);
    expect(tickSecondsLeft(deadlines, NOW + 5_000)).toEqual({});
    expect(tickSecondsLeft(deadlines, NOW + 999_000)).toEqual({});
    // Never a negative value, whatever `now` a caller passes.
    for (const [, secondsLeft] of Object.entries(tickSecondsLeft(deadlines, NOW + 999_000))) {
      expect(secondsLeft).toBeGreaterThanOrEqual(0);
    }
  });

  it('re-syncs to a fresh poll instead of continuing the old countdown', () => {
    // First poll: 241s left. 60s of local ticking passes (181s). Then a new
    // poll arrives with its own authoritative snapshot — re-deriving the
    // deadline from THAT, not from where the local clock had gotten to, is
    // the whole point: the server's reaper clock is the one that matters.
    const firstPoll = holdDeadlines([{ os: 'win311', clone: 'c', secondsLeft: 241 }], NOW);
    const afterLocalTick = tickSecondsLeft(firstPoll, NOW + 60_000);
    expect(afterLocalTick.win311).toBe(181);

    const secondPoll = holdDeadlines([{ os: 'win311', clone: 'c', secondsLeft: 200 }], NOW + 60_000);
    expect(tickSecondsLeft(secondPoll, NOW + 60_000)).toEqual({ win311: 200 });
  });

  it('handles multiple simultaneous holds independently', () => {
    const deadlines = holdDeadlines(
      [
        { os: 'win311', clone: 'c1', secondsLeft: 30 },
        { os: 'rhapsody', clone: 'c2', secondsLeft: 300 },
      ],
      NOW,
    );
    expect(tickSecondsLeft(deadlines, NOW + 40_000)).toEqual({ rhapsody: 260 });
  });
});

describe('formatHold', () => {
  it('renders minutes:seconds, zero-padded', () => {
    expect(formatHold(241)).toBe('4:01');
    expect(formatHold(5)).toBe('0:05');
    expect(formatHold(60)).toBe('1:00');
    expect(formatHold(0)).toBe('0:00');
  });

  it('never renders a negative time even if asked to', () => {
    expect(formatHold(-30)).toBe('0:00');
  });
});

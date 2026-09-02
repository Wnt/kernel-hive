import { describe, expect, it } from 'vitest';
import {
  bankServerSkips,
  spendSkipCredit,
  spendSkipCreditOverWindow,
  SKIP_CREDIT_CAP,
  type SkipCreditState,
} from './skipCredit';

const fresh = (): SkipCreditState => ({ lastServerSkipTotal: 0, serverSkipCredit: 0 });

describe('server-skip loss correction (L-1)', () => {
  it('is a no-op when the server reports no skip counter (old server)', () => {
    const s = fresh();
    bankServerSkips(s, undefined);
    expect(s.serverSkipCredit).toBe(0);
    expect(spendSkipCredit(s, 5)).toBe(5); // gap misses pass through untouched
  });

  it('is a no-op on a LAN (skip counter stays 0)', () => {
    const s = fresh();
    bankServerSkips(s, 0);
    bankServerSkips(s, 0);
    expect(s.serverSkipCredit).toBe(0);
    expect(spendSkipCredit(s, 3)).toBe(3);
  });

  it('banks the delta and spends it against gap misses', () => {
    const s = fresh();
    bankServerSkips(s, 10); // first push: cumulative jumps 0 → 10
    expect(s.serverSkipCredit).toBe(10);
    // 4 gap misses this tick are fully explained by server skips → 0 net loss.
    expect(spendSkipCredit(s, 4)).toBe(0);
    expect(s.serverSkipCredit).toBe(6); // 6 credit carried to later ticks
    expect(spendSkipCredit(s, 6)).toBe(0);
    expect(s.serverSkipCredit).toBe(0);
  });

  it('leaves genuine loss beyond the server skips intact', () => {
    const s = fresh();
    bankServerSkips(s, 2); // server skipped 2
    // 5 gap misses: 2 are server skips, 3 are real loss.
    expect(spendSkipCredit(s, 5)).toBe(3);
    expect(s.serverSkipCredit).toBe(0);
  });

  it('rebases (does not credit negative) when the server session restarts', () => {
    const s = fresh();
    bankServerSkips(s, 100);
    expect(spendSkipCredit(s, 100)).toBe(0);
    // reconnect: the new server session's counter starts low again.
    bankServerSkips(s, 3);
    expect(s.lastServerSkipTotal).toBe(3);
    expect(s.serverSkipCredit).toBe(0); // no spurious credit from the drop
  });

  it('caps the credit so an unmatched burst cannot suppress future loss forever', () => {
    const s = fresh();
    bankServerSkips(s, 10_000);
    expect(s.serverSkipCredit).toBe(SKIP_CREDIT_CAP);
  });
});

describe('retroactive skip credit across the reported-loss window', () => {
  const win = (...missed: number[]) => missed.map((m, i) => ({ at: i * 100, recv: 2, missed: m }));

  it('cancels a burst the server only admits to a second later', () => {
    // The multi-viewer shape: the backlog gate skips ~30 frames over three
    // 100 ms ticks, and the cumulative count arrives on the NEXT 1 Hz push.
    const s = fresh();
    const w = win(10, 10, 10, 0, 0);
    bankServerSkips(s, 30);
    expect(spendSkipCreditOverWindow(s, w)).toBe(30);
    expect(w.map((x) => x.missed)).toEqual([0, 0, 0, 0, 0]);
    expect(s.serverSkipCredit).toBe(0);
  });

  it('spends oldest first — the lagging report is about the past', () => {
    const s = fresh();
    const w = win(5, 5, 5);
    bankServerSkips(s, 7);
    expect(spendSkipCreditOverWindow(s, w)).toBe(7);
    expect(w.map((x) => x.missed)).toEqual([0, 3, 5]);
  });

  it('leaves genuine loss alone when there is no credit', () => {
    const s = fresh();
    const w = win(4, 4);
    expect(spendSkipCreditOverWindow(s, w)).toBe(0);
    expect(w.map((x) => x.missed)).toEqual([4, 4]);
  });

  it('keeps unspent credit for a later tick rather than discarding it', () => {
    const s = fresh();
    bankServerSkips(s, 12);
    const w1 = win(2);
    expect(spendSkipCreditOverWindow(s, w1)).toBe(2);
    expect(s.serverSkipCredit).toBe(10);
    const w2 = win(0, 6);
    expect(spendSkipCreditOverWindow(s, w2)).toBe(6);
    expect(s.serverSkipCredit).toBe(4);
  });
});

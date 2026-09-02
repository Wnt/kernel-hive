import { describe, expect, it } from 'vitest';
import { ewma, rawScores, scorerReady } from './scoring';

describe('ewma', () => {
  it('is the exact prev*(m-1)/m + next/m recurrence', () => {
    expect(ewma(100, 0, 4)).toBe(75);       // 100*3/4 + 0
    expect(ewma(100, 50, 8)).toBe(93.75);   // 100*7/8 + 50/8
    expect(ewma(0, 100, 16)).toBe(6.25);    // 0 + 100/16
  });
  it('m=1 collapses to the new sample', () => {
    expect(ewma(42, 7, 1)).toBe(7);
  });
});

describe('rawScores', () => {
  const base = { rttMs: 0, lossPct: 0, freeze: false, missed: 0, decodeQueue: 0 };

  it('latency: linear from RTT, clamped 0..100', () => {
    expect(rawScores({ ...base, rttMs: 250 }).latRaw).toBe(0);
    expect(rawScores({ ...base, rttMs: 130 }).latRaw).toBe(50);
    expect(rawScores({ ...base, rttMs: 0 }).latRaw).toBe(100); // (250/2.4)=104.16 → clamp 100
  });

  it('loss: 100 - lossPct, clamped', () => {
    expect(rawScores({ ...base, lossPct: 0 }).lossRaw).toBe(100);
    expect(rawScores({ ...base, lossPct: 40 }).lossRaw).toBe(60);
    expect(rawScores({ ...base, lossPct: 250 }).lossRaw).toBe(0);
  });

  it('GFN PLI+loss rule: a freeze WITH any loss zeroes the loss score', () => {
    expect(rawScores({ ...base, lossPct: 0, freeze: true, missed: 3 }).lossRaw).toBe(0);
    // freeze but no missed frames → loss score NOT zeroed by the rule.
    expect(rawScores({ ...base, lossPct: 0, freeze: true, missed: 0 }).lossRaw).toBe(100);
  });

  it('bandwidth: 100, penalised by decode-queue backlog and freezes', () => {
    expect(rawScores({ ...base, decodeQueue: 0 }).bwRaw).toBe(100);
    expect(rawScores({ ...base, decodeQueue: 1 }).bwRaw).toBe(100);
    expect(rawScores({ ...base, decodeQueue: 3 }).bwRaw).toBe(50);   // 100 - 2*25
    expect(rawScores({ ...base, decodeQueue: 1, freeze: true }).bwRaw).toBe(60); // 100 - 40
    expect(rawScores({ ...base, decodeQueue: 6 }).bwRaw).toBe(0);    // 100 - 5*25 = -25 → clamp 0
  });

  it('overall is the min of the three', () => {
    const r = rawScores({ rttMs: 130, lossPct: 10, freeze: false, missed: 0, decodeQueue: 3 });
    // lat=50, loss=90, bw=50 → overall 50
    expect(r.overallRaw).toBe(Math.min(r.latRaw, r.lossRaw, r.bwRaw));
    expect(r.overallRaw).toBe(50);
  });
});

describe('scorerReady', () => {
  it('refuses to score a session with no RTT sample and no frames', () => {
    expect(scorerReady({ hasRtt: false, framesSeen: false })).toBe(false);
  });
  it('refuses to score on one half of the evidence', () => {
    expect(scorerReady({ hasRtt: true, framesSeen: false })).toBe(false);
    expect(scorerReady({ hasRtt: false, framesSeen: true })).toBe(false);
  });
  it('scores once an RTT sample and a frame have both landed', () => {
    expect(scorerReady({ hasRtt: true, framesSeen: true })).toBe(true);
  });
});

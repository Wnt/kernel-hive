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
  // `received: 30` = frames ARE arriving; the idle case is its own test below.
  const base = { rttMs: 0, lossPct: 0, freeze: false, missed: 0, decodeQueue: 0, received: 30 };

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

  it('overall is the NETWORK min — latency and loss only', () => {
    // Six hardware decoders on one Intel Mac measured dec1209.0/q16 on the first
    // T-line of a tiled run: bw would be 100 - 15*25 → 0, and the old
    // min(lat, loss, bw) turned that into "Spotty connection" in 2 s with
    // loss0.0 and rtt8 on the same line. The device story is told separately.
    const r = rawScores({ rttMs: 130, lossPct: 10, freeze: false, missed: 0, decodeQueue: 16, received: 30 });
    expect(r.bwRaw).toBe(0);
    expect(r.overallRaw).toBe(Math.min(r.latRaw, r.lossRaw));
    expect(r.overallRaw).toBe(50);
  });

  it('an IDLE guest scores a clean 100 — no frames, no pressure', () => {
    // nt4, run 3: `T1 fps0 rx0.0M loss0.0/w0.0n12 rtt7.8 dr10 tier0ch spotty`.
    // Nothing was changing on screen, so the station emitted nothing; a queue
    // snapshot left over from the connect burst is stale evidence about a
    // decoder nobody is asking anything of.
    const idle = rawScores({ rttMs: 7.8, lossPct: 0, freeze: false, missed: 0, decodeQueue: 16, received: 0 });
    expect(idle.bwRaw).toBe(100);
    expect(idle.overallRaw).toBe(100);
    // …and the same queue WITH frames arriving is real pressure.
    const busy = rawScores({ rttMs: 7.8, lossPct: 0, freeze: false, missed: 0, decodeQueue: 16, received: 20 });
    expect(busy.bwRaw).toBe(0);
    expect(busy.overallRaw).toBe(100); // still not the NETWORK's fault
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

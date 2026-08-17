import { describe, it, expect } from 'vitest';
import { StreamTelemetry, type TelemetryTick } from './telemetry';

/** A quiet tick: one frame received, nothing missed, healthy LAN RTT. */
function quiet(now: number, over: Partial<TelemetryTick> = {}): TelemetryTick {
  return {
    now, received: 1, missed: 0, rttMs: 3, framesDropped: 0, freezeCount: 0, tier: 0, ...over,
  };
}

describe('StreamTelemetry', () => {
  it('reports zero loss and no peak on a clean stream', () => {
    const t = new StreamTelemetry();
    for (let i = 0; i < 30; i++) t.tick(quiet(i * 100));
    const s = t.snapshot(3000);
    expect(s.windowLossPct).toBe(0);
    expect(s.windowFrames).toBe(30);
    expect(s.peakLossAgeMs).toBeNull();
    expect(s.peakLossUntrustworthy).toBe(false);
    expect(s.tierChanges).toBe(0);
    expect(s.tierPath).toBe('');
  });

  // THE REGRESSION THIS MODULE EXISTS FOR (tru64, 2026-08-17): at ~2 fps most
  // ticks carry no frames at all, so a single missed frame lands in a tick whose
  // denominator is 1 and reports 100 % loss — over the server's 5 % downshift
  // threshold — while the 3 s window shows the truth: one loss in a handful of
  // frames. The overlay must show the sample size and flag the peak.
  it('flags a high loss peak computed from too few frames', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0));
    t.tick(quiet(100, { received: 0, missed: 1, framesDropped: 1 }));
    for (let i = 2; i < 20; i++) t.tick(quiet(i * 100, { framesDropped: 1 }));
    const s = t.snapshot(2000);
    expect(s.peakLossPct).toBe(100);
    expect(s.peakLossFrames).toBe(1);
    expect(s.peakLossUntrustworthy).toBe(true);
    expect(s.peakLossAgeMs).toBe(1900);
    // The window is honest even though the single tick was not.
    expect(s.windowLossPct).toBeCloseTo(100 / 20, 5);
    expect(s.windowFrames).toBe(20);
  });

  it('does not flag a genuine loss peak measured over enough frames', () => {
    const t = new StreamTelemetry();
    // 30 frames in the tick, 3 missed → 10 %: over threshold, but trustworthy.
    t.tick(quiet(0, { received: 27, missed: 3 }));
    const s = t.snapshot(0);
    expect(s.peakLossPct).toBe(10);
    expect(s.peakLossFrames).toBe(30);
    expect(s.peakLossUntrustworthy).toBe(false);
  });

  it('ages samples out of the rolling window', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0, { received: 0, missed: 1 }));
    for (let i = 1; i <= 40; i++) t.tick(quiet(i * 100));
    const s = t.snapshot(4000);
    expect(s.peakLossAgeMs).toBeNull(); // the lossy tick fell out of the 3 s window
    expect(s.windowLossPct).toBe(0);
  });

  it('records the tier path and change count', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0, { tier: 0 }));
    t.tick(quiet(100, { tier: 1 }));
    t.tick(quiet(200, { tier: 2 }));
    t.tick(quiet(300, { tier: 3 }));
    t.tick(quiet(400, { tier: 0 }));
    const s = t.snapshot(900);
    expect(s.tierPath).toBe('0→1→2→3→0');
    expect(s.tierChanges).toBe(4);
    expect(s.lastTierChangeAgeMs).toBe(500);
  });

  it('seeds cumulative counters so a mid-session attach reports no burst', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0, { framesDropped: 900, freezeCount: 900 }));
    const s = t.snapshot(0);
    expect(s.dropsPerMin).toBe(0);
    expect(s.freezesPerMin).toBe(0);
  });

  it('converts drop deltas into a per-minute rate over the window', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0));
    t.tick(quiet(100, { framesDropped: 3 }));
    const s = t.snapshot(200);
    // 3 drops observed in a 3 s window → 60/min.
    expect(s.dropsPerMin).toBe(60);
  });

  it('tracks the RTT floor and reports excess over it, like the server', () => {
    const t = new StreamTelemetry();
    for (let i = 0; i < 50; i++) t.tick(quiet(i * 100, { rttMs: 3 }));
    const flat = t.snapshot(5000);
    expect(flat.rttFloorMs).toBeCloseTo(3, 1);
    expect(flat.rttExcessMs).toBeCloseTo(0, 1);
    // A sustained jump lifts the smoothed RTT well clear of the learned floor.
    for (let i = 50; i < 120; i++) t.tick(quiet(i * 100, { rttMs: 200 }));
    const spiked = t.snapshot(12_000);
    expect(spiked.rttExcessMs!).toBeGreaterThan(80);
  });

  it('ignores ticks with no RTT sample', () => {
    const t = new StreamTelemetry();
    t.tick(quiet(0, { rttMs: null }));
    const s = t.snapshot(0);
    expect(s.rttFloorMs).toBeNull();
    expect(s.rttExcessMs).toBeNull();
    expect(s.rttPeakMs).toBeNull();
    expect(s.rttBreachTicks).toBe(0);
  });

  // A keyframe burst queues the RTT ping behind it: the raw RTT spikes for the
  // duration of the burst and is back to normal by the time anyone reads the
  // panel. The peak and the breach count are what survive the transient.
  it('captures an RTT spike that the instantaneous reading misses', () => {
    const t = new StreamTelemetry();
    for (let i = 0; i < 40; i++) t.tick(quiet(i * 100, { rttMs: 3 }));
    // A burst: ten ticks of badly-queued pings, then straight back to 3 ms.
    for (let i = 40; i < 50; i++) t.tick(quiet(i * 100, { rttMs: 400 }));
    for (let i = 50; i < 60; i++) t.tick(quiet(i * 100, { rttMs: 3 }));
    const s = t.snapshot(6000);
    expect(s.rttPeakMs).toBe(400);
    // The FIRST 400 ms tick (t=4000), since equal maxima keep the earliest.
    expect(s.rttPeakAgeMs).toBe(2000);
    expect(s.rttBreachTicks).toBeGreaterThan(0);

    // THE TAIL, and why a burst shorter than the server's 1.5 s persistence
    // window still trips it: the m=16 EWMA decays far more slowly than the
    // burst lasted, so a SECOND of bad pings leaves the excess above the 80 ms
    // downshift threshold for many seconds after the link is healthy again.
    expect(s.rttExcessMs!).toBeGreaterThan(80);

    // Only after a long quiet spell does it actually settle.
    for (let i = 60; i < 200; i++) t.tick(quiet(i * 100, { rttMs: 3 }));
    expect(t.snapshot(20_000).rttExcessMs!).toBeLessThan(80);
  });
});

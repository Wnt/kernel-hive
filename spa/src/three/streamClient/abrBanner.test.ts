import { describe, expect, it } from 'vitest';
import { updateBannerImpl } from './abr';
import { livenessVerdict, PING_STRIKES, SILENCE_MS } from './liveness';
import type { StreamClient } from '../streamClient';

/** The fields updateBannerImpl actually reads, plus the real liveness rule. */
function client(over: Partial<{
  banner: string; transportDown: boolean; decoderFailed: boolean;
  consecutiveTimeouts: number; msSinceServerData: number | null; sOverall: number;
  scoreInit: boolean; sBandwidth: number;
}> = {}) {
  const c = {
    banner: over.banner ?? 'good',
    transportDown: over.transportDown ?? false,
    decoderFailed: over.decoderFailed ?? false,
    exitReason: null as string | null,
    sOverall: over.sOverall ?? 100,
    scoreInit: over.scoreInit ?? true,
    sBandwidth: over.sBandwidth ?? 100,
    deviceBelowSince: 0,
    belowSince: 0,
    aboveSince: 0,
    liveness: () => livenessVerdict({
      consecutiveTimeouts: over.consecutiveTimeouts ?? 0,
      msSinceServerData: over.msSinceServerData === undefined ? 0 : over.msSinceServerData,
    }),
  };
  return c as unknown as StreamClient & typeof c;
}

describe('banner vs liveness (the 2026-09-02 ping-timeout regression)', () => {
  it('stays SOFT when echoes are lost but the tile is still sending', () => {
    // 18:39:03 on the operator's tab: RTT 12 ms, frames arriving, three lost
    // ping datagrams — and the old rule said 'reconnecting' and rebuilt the
    // transport. 'spotty' is the honest word, and it costs nothing to be wrong.
    const c = client({ consecutiveTimeouts: PING_STRIKES + 3, msSinceServerData: 40 });
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('spotty');
    expect(c.exitReason).toBeNull();
  });

  it('goes hard only once the tile has gone completely silent', () => {
    const c = client({ consecutiveTimeouts: PING_STRIKES, msSinceServerData: SILENCE_MS });
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('reconnecting');
    expect(c.exitReason).toBe('ping-timeout');
  });

  it('keeps a real transport close instant and correctly attributed', () => {
    const c = client({ transportDown: true, msSinceServerData: 5 });
    c.exitReason = 'server-finished';
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('reconnecting');
    expect(c.exitReason).toBe('server-finished'); // not clobbered by ping-timeout
  });

  it('needs the 2 s dwell before a low score is called spotty', () => {
    const c = client({ sOverall: 10 });
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('good');
    updateBannerImpl.call(c, 2999);
    expect(c.banner).toBe('good');
    updateBannerImpl.call(c, 3000);
    expect(c.banner).toBe('spotty');
  });

  it('recovers to good once pings answer again', () => {
    const c = client({ banner: 'spotty', consecutiveTimeouts: 0, sOverall: 100 });
    updateBannerImpl.call(c, 1000);
    updateBannerImpl.call(c, 3000);
    expect(c.banner).toBe('good');
  });
});

describe('a session with nothing to score is never spotty', () => {
  it('stays quiet while connecting — the reactos 2026-09-02 reading', () => {
    // reactos never completed a WebTransport handshake, so it had no RTT sample
    // and no frames; the scorer's unknown → 250 ms default scored latency 0 and
    // the banner said "Spotty connection" at +6.0 s about a link that did not
    // exist. `scoreInit` stays false until a real sample seeds the EWMAs.
    const c = client({ scoreInit: false, sOverall: 0 });
    for (let t = 0; t <= 10000; t += 100) updateBannerImpl.call(c, t);
    expect(c.banner).toBe('good'); // i.e. no banner at all
  });

  it('still reports a real hard close while unscored', () => {
    const c = client({ scoreInit: false, transportDown: true });
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('reconnecting');
  });
});

describe('device pressure never says "Spotty connection"', () => {
  const dwell = (c: ReturnType<typeof client>, from: number, to: number) => {
    for (let t = from; t <= to; t += 100) updateBannerImpl.call(c, t);
  };

  it('raises device-load, not spotty, when only the decode queue is bad', () => {
    // Six decoders on one Intel Mac: dec1209.0/q16 with loss0.0 and rtt8.
    const c = client({ sOverall: 100, sBandwidth: 0 });
    updateBannerImpl.call(c, 1000);
    expect(c.banner).toBe('good');       // the 2 s dwell still applies
    dwell(c, 1100, 2900);
    expect(c.banner).toBe('good');
    dwell(c, 3000, 3000);
    expect(c.banner).toBe('device-load');
    expect(c.exitReason).toBeNull();
  });

  it('a bad NETWORK still reads spotty and outranks device pressure', () => {
    const c = client({ sOverall: 10, sBandwidth: 0 });
    dwell(c, 1000, 3000);
    expect(c.banner).toBe('spotty');
  });

  it('an idle guest with a clean network stays good', () => {
    // nt4 run 3: fps0, rx0.0M, loss0.0, rtt7.8 — and the old banner said spotty.
    // scoring.ts scores an idle interval bw=100, so nothing dwells here at all.
    const c = client({ sOverall: 100, sBandwidth: 100 });
    dwell(c, 1000, 11000);
    expect(c.banner).toBe('good');
  });

  it('clears device-load once the decoder catches up', () => {
    const c = client({ sOverall: 100, sBandwidth: 0 });
    dwell(c, 1000, 3000);
    expect(c.banner).toBe('device-load');
    const d = client({ banner: 'device-load', sOverall: 100, sBandwidth: 100 });
    updateBannerImpl.call(d, 1000);
    expect(d.banner).toBe('good');
  });
});

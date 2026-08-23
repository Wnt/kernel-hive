// The resume decision. The trap this guards: a station showing a STILL screen
// paints only on the keyframe heartbeat (~2.5 s), so "hasn't painted lately" is
// not evidence of death — judging on it would reconnect a healthy station every
// time the tab came forward.
import { describe, expect, it, vi } from 'vitest';
import {
  sessionNeedsReconnect,
  RESUME_FRESH_PAINT_MS,
  RESUME_PING_TIMEOUT_MS,
} from './resumePolicy';

const target = (msSinceFrame: number, ping: number | null | Error) => ({
  getMsSinceLastFrame: () => msSinceFrame,
  pingRtt: vi.fn(async () => {
    if (ping instanceof Error) throw ping;
    return ping;
  }),
});

describe('sessionNeedsReconnect', () => {
  it('accepts a recent paint as proof of life without pinging', async () => {
    const t = target(RESUME_FRESH_PAINT_MS - 1, null);
    expect(await sessionNeedsReconnect(t)).toBe(false);
    expect(t.pingRtt).not.toHaveBeenCalled();
  });

  it('keeps a STILL-screen session that answers its ping', async () => {
    // No frame for 30 s — normal for a static desktop between heartbeats.
    const t = target(30_000, 12.4);
    expect(await sessionNeedsReconnect(t)).toBe(false);
    expect(t.pingRtt).toHaveBeenCalledWith(RESUME_PING_TIMEOUT_MS);
  });

  it('condemns a session whose ping goes unanswered', async () => {
    expect(await sessionNeedsReconnect(target(30_000, null))).toBe(true);
  });

  it('condemns a session whose ping throws (transport already gone)', async () => {
    expect(await sessionNeedsReconnect(target(Infinity, new Error('closed')))).toBe(true);
  });

  it('pings a session that has NEVER painted rather than assuming either way', async () => {
    const t = target(Infinity, 8);
    expect(await sessionNeedsReconnect(t)).toBe(false);
    expect(t.pingRtt).toHaveBeenCalled();
  });
});

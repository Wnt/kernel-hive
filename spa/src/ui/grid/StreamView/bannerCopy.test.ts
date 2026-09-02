import { describe, expect, it } from 'vitest';
import { bannerCopy } from './bannerCopy';

const base = {
  restoreReconnect: false,
  restoring: false,
  decoderUnsupported: false,
  deviceUnderLoad: false,
  exitReason: null,
};

describe('bannerCopy — the words a visitor actually reads', () => {
  it('says "Device under load" for the client-measured device verdict', () => {
    // The 2026-09-02 reading this exists for: six decoders on one Intel Mac,
    // loss 0.0 and RTT 8 ms, and the banner blamed the CONNECTION.
    // PressureObserver is Chrome-desktop-only, so `deviceUnderLoad` is false on
    // most machines that struggle — the banner state has to carry it itself.
    const c = bannerCopy({ ...base, bannerState: 'device-load' });
    expect(c.bannerText).toBe('Device under load');
    expect(c.bannerIsDevice).toBe(true);
  });

  it('still says "Spotty connection" for a real network verdict', () => {
    const c = bannerCopy({ ...base, bannerState: 'spotty' });
    expect(c.bannerText).toBe('Spotty connection');
    expect(c.bannerIsDevice).toBe(false);
  });

  it('keeps the PressureObserver relabel when it IS available', () => {
    const c = bannerCopy({ ...base, bannerState: 'spotty', deviceUnderLoad: true });
    expect(c.bannerText).toBe('Device under load');
    expect(c.bannerIsDevice).toBe(true);
  });

  it('never lets device wording outrank a reconnect', () => {
    const c = bannerCopy({ ...base, bannerState: 'reconnecting', deviceUnderLoad: true });
    expect(c.bannerText).not.toBe('Device under load');
    expect(c.bannerIsDevice).toBe(false);
  });

  it('shows the restore words while a restore is in flight', () => {
    expect(bannerCopy({ ...base, restoreReconnect: true, restoring: true, bannerState: 'good' }).bannerText)
      .toBe('Restoring…');
    expect(bannerCopy({ ...base, restoreReconnect: true, restoring: false, bannerState: 'good' }).bannerText)
      .toBe('Reconnecting…');
  });
});

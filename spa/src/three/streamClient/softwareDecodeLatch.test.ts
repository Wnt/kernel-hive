// Unit coverage for the page-lifetime software-decode demotion. The bug this
// guards: `hwDecodeOk`/`hwFellBack` are per-StreamClient, and every reconnect
// builds a fresh one — so a client that proved the hardware decoder silent
// threw that away on retry and reproduced the identical stall, which is how a
// resume stayed black through attempt after attempt.
import { afterEach, describe, expect, it } from 'vitest';
import {
  isSoftwareDecodeLatched,
  latchSoftwareDecode,
  resetSoftwareDecodeLatch,
} from './softwareDecodeLatch';
import { pickAccelImpl } from './videoDecode';
import type { StreamClient } from '../streamClient';

afterEach(() => resetSoftwareDecodeLatch());

/** The only three fields pickAccel reads. */
const client = (hwDecodeOk: boolean | null, hwFellBack: boolean) =>
  ({ hwDecodeOk, hwFellBack }) as unknown as StreamClient;

describe('softwareDecodeLatch', () => {
  it('starts clear so a fresh page still probes the hardware decoder', () => {
    expect(isSoftwareDecodeLatched()).toBe(false);
    expect(pickAccelImpl.call(client(true, false))).toBe('prefer-hardware');
  });

  it('is one-way and idempotent', () => {
    latchSoftwareDecode();
    latchSoftwareDecode();
    expect(isSoftwareDecodeLatched()).toBe(true);
  });

  it('outranks a fresh client’s own successful hardware probe', () => {
    // Exactly the reconnect case: the replacement client has hwDecodeOk=true
    // (its probe says yes) and hwFellBack=false (it never saw the failure).
    latchSoftwareDecode();
    expect(pickAccelImpl.call(client(true, false))).toBe('no-preference');
  });

  it('leaves the per-client demotion working on its own', () => {
    expect(pickAccelImpl.call(client(true, true))).toBe('no-preference');
    expect(pickAccelImpl.call(client(false, false))).toBe('no-preference');
    expect(pickAccelImpl.call(client(null, false))).toBe('no-preference');
  });
});

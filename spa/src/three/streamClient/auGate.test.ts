// Unit coverage for the decode-feed gate: the stale/out-of-order AU guard and
// the frame_id-gap → wait-for-keyframe state machine feedVideoAU runs every AU
// through before handing it to VideoDecoder.
import { describe, expect, it } from 'vitest';
import { isStaleAu, VideoAuGate } from './auGate';

describe('isStaleAu', () => {
  it('passes everything before the first AU (lastFrameId sentinel -1)', () => {
    expect(isStaleAu(-1, 0, false)).toBe(false);
    expect(isStaleAu(-1, 7, false)).toBe(false);
    expect(isStaleAu(-1, 0, true)).toBe(false);
  });

  it('passes in-order successors (and forward jumps)', () => {
    expect(isStaleAu(10, 11, false)).toBe(false);
    expect(isStaleAu(10, 15, false)).toBe(false); // gap — handled by the key gate
  });

  it('drops non-key AUs at or behind the newest frame_id', () => {
    expect(isStaleAu(10, 10, false)).toBe(true); // duplicate
    expect(isStaleAu(10, 9, false)).toBe(true);  // retransmit-delayed delta
    expect(isStaleAu(10, 0, false)).toBe(true);
  });

  it('always passes keys, including out-of-order/duplicate ids', () => {
    expect(isStaleAu(10, 10, true)).toBe(false);
    expect(isStaleAu(10, 9, true)).toBe(false);  // late large key AU
    expect(isStaleAu(10, 0, true)).toBe(false);  // encoder reopen restarts ids
  });
});

describe('VideoAuGate', () => {
  it('admits deltas and keys while no gap has been seen', () => {
    const g = new VideoAuGate();
    expect(g.admit(false)).toBe(true);
    expect(g.admit(true)).toBe(true);
    expect(g.admit(false)).toBe(true);
  });

  it('drops deltas after a gap until a key arrives', () => {
    const g = new VideoAuGate();
    g.noteGap();
    expect(g.admit(false)).toBe(false);
    expect(g.admit(false)).toBe(false); // stays armed across multiple deltas
  });

  it('admits keys even while armed, and clears the gate', () => {
    const g = new VideoAuGate();
    g.noteGap();
    expect(g.admit(true)).toBe(true);   // the healing IDR always decodes
    expect(g.admit(false)).toBe(true);  // reference chain is clean again
  });

  it('re-arms on a new gap after healing', () => {
    const g = new VideoAuGate();
    g.noteGap();
    expect(g.admit(true)).toBe(true);
    g.noteGap();
    expect(g.admit(false)).toBe(false);
    expect(g.admit(true)).toBe(true);
    expect(g.admit(false)).toBe(true);
  });
});

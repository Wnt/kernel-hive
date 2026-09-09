import { describe, expect, it } from 'vitest';
import { livenessVerdict, PING_STRIKES, SILENCE_MS } from './liveness';

describe('liveness verdict', () => {
  it('is ok while pings are answering', () => {
    expect(livenessVerdict({ consecutiveTimeouts: 0, msSinceServerData: 0 })).toBe('ok');
    expect(livenessVerdict({ consecutiveTimeouts: PING_STRIKES - 1, msSinceServerData: 9e9 }))
      .toBe('ok');
  });

  it('is only SUSPECT while the server is still sending — the 12 ms LAN case', () => {
    // The operator's tab at 18:39:03: video still arriving, echoes lost, and the
    // old rule rebuilt the transport anyway.
    expect(livenessVerdict({ consecutiveTimeouts: 9, msSinceServerData: 40 })).toBe('suspect');
    expect(livenessVerdict({ consecutiveTimeouts: PING_STRIKES, msSinceServerData: SILENCE_MS - 1 }))
      .toBe('suspect');
  });

  it('is LOST only when strikes AND total silence coincide', () => {
    expect(livenessVerdict({ consecutiveTimeouts: PING_STRIKES, msSinceServerData: SILENCE_MS }))
      .toBe('lost');
    expect(livenessVerdict({ consecutiveTimeouts: PING_STRIKES + 5, msSinceServerData: 30000 }))
      .toBe('lost');
  });

  it('never calls a session that has received nothing yet LOST', () => {
    // That session belongs to the connect ladder's keyframe budget, not here.
    expect(livenessVerdict({ consecutiveTimeouts: 20, msSinceServerData: null })).toBe('suspect');
  });
});

import { describe, expect, it } from 'vitest';
import {
  FIRST_INPUT_GRACE_MS,
  HIDDEN_GRACE_MS,
  graceSecondsLeft,
  heroBlockedLine,
  heroPlayable,
  mirroredRemaining,
  releaseDue,
  shouldAutoClaim,
  type AutoClaimFacts,
  type HoldFacts,
} from './heroPolicy';

// The rules that decide whether one of eight cells is spent on somebody who is
// not there. Every case below is a way the landing page can quietly hold a
// machine for a crawler.

const T0 = 1_700_000_000_000;
const hold = (over: Partial<HoldFacts> = {}): HoldFacts => ({
  now: T0,
  claimedAt: T0,
  lastInputAt: null,
  hiddenSince: null,
  ...over,
});

describe('releaseDue', () => {
  it('holds a fresh, visible, untouched cell inside the grace', () => {
    expect(releaseDue(hold({ now: T0 + FIRST_INPUT_GRACE_MS - 1 }))).toBeNull();
  });

  it('releases an untouched cell the moment the grace runs out', () => {
    expect(releaseDue(hold({ now: T0 + FIRST_INPUT_GRACE_MS }))).toBe('never-driven');
  });

  it('releases a never-driven cell IMMEDIATELY when the tab is hidden', () => {
    // The strongest signal there is: claimed and instantly backgrounded is a
    // crawler or a middle-click, and neither will ever look at the frame.
    expect(releaseDue(hold({ hiddenSince: T0, now: T0 + 1 }))).toBe('hidden');
  });

  it('never releases a visible cell the visitor has driven', () => {
    // From here the broker's TTL and idle windows own the session; a second,
    // shorter client rule would end sessions the server believes are alive.
    expect(releaseDue(hold({ lastInputAt: T0, now: T0 + 10 * 60_000 }))).toBeNull();
  });

  it('gives a driven cell the longer grace when the tab goes hidden', () => {
    const driven = { lastInputAt: T0 + 1_000, hiddenSince: T0 + 2_000 };
    expect(releaseDue(hold({ ...driven, now: T0 + 2_000 + HIDDEN_GRACE_MS - 1 }))).toBeNull();
    expect(releaseDue(hold({ ...driven, now: T0 + 2_000 + HIDDEN_GRACE_MS }))).toBe('hidden');
  });

  it('gives a hidden, never-driven cell no benefit of the doubt at all', () => {
    expect(HIDDEN_GRACE_MS).toBeGreaterThan(FIRST_INPUT_GRACE_MS);
    expect(releaseDue(hold({ hiddenSince: T0, now: T0 }))).toBe('hidden');
  });
});

describe('graceSecondsLeft', () => {
  it('counts down from the grace and never goes negative', () => {
    expect(graceSecondsLeft({ now: T0, claimedAt: T0 })).toBe(FIRST_INPUT_GRACE_MS / 1000);
    expect(graceSecondsLeft({ now: T0 + 14_200, claimedAt: T0 })).toBe(1);
    expect(graceSecondsLeft({ now: T0 + 99_000, claimedAt: T0 })).toBe(0);
  });
});

describe('heroPlayable', () => {
  const caps = (over: Partial<Parameters<typeof heroPlayable>[0]> = {}) => ({
    wt: true, vd: true, rtc: true, secure: true, ...over,
  });

  it('plays on the primary path', () => {
    expect(heroPlayable(caps({ rtc: false }))).toBe(true);
  });

  it('plays on the WebRTC fallback with NEITHER primary API', () => {
    // The lesson in three/streamTransportSelect.ts, restated as a gate: Safari
    // has no WebTransport and Firefox-Android has no VideoDecoder, and both
    // play perfectly well. A hero that demanded both would poster them.
    expect(heroPlayable(caps({ wt: false, vd: false }))).toBe(true);
  });

  it('posters a browser with no path at all', () => {
    expect(heroPlayable(caps({ wt: false, vd: false, rtc: false }))).toBe(false);
    expect(heroPlayable(caps({ wt: true, vd: false, rtc: false }))).toBe(false);
  });

  it('posters an insecure context whatever it claims to support', () => {
    expect(heroPlayable(caps({ secure: false }))).toBe(false);
  });

  it('says what is missing without blaming the visitor', () => {
    expect(heroBlockedLine(caps({ secure: false }))).toMatch(/secure/i);
    expect(heroBlockedLine(caps({ wt: false, vd: false, rtc: false }))).toMatch(/WebRTC/);
  });
});

describe('shouldAutoClaim', () => {
  const facts = (over: Partial<AutoClaimFacts> = {}): AutoClaimFacts => ({
    playable: true,
    visible: true,
    access: 'open',
    role: 'anon',
    budget: { budgetSeconds: 60, remainingSeconds: 60, expired: false },
    holding: false,
    busy: false,
    attempts: 0,
    ...over,
  });

  it('claims for a capable, visible stranger at an open door', () => {
    expect(shouldAutoClaim(facts())).toBe(true);
  });

  it('claims for a signed-in visitor, who has no budget block at all', () => {
    expect(shouldAutoClaim(facts({ role: 'viewer', budget: undefined }))).toBe(true);
  });

  it('does not claim into a background tab', () => {
    expect(shouldAutoClaim(facts({ visible: false }))).toBe(false);
  });

  it('does not claim for a browser that cannot render the picture', () => {
    expect(shouldAutoClaim(facts({ playable: false }))).toBe(false);
  });

  it('waits for the access answer instead of guessing', () => {
    expect(shouldAutoClaim(facts({ access: undefined }))).toBe(false);
  });

  it('respects a closed door, and an invited door for a stranger', () => {
    expect(shouldAutoClaim(facts({ access: 'closed' }))).toBe(false);
    expect(shouldAutoClaim(facts({ access: 'invited', role: 'anon' }))).toBe(false);
    expect(shouldAutoClaim(facts({ access: 'invited', role: 'viewer' }))).toBe(true);
  });

  it('does not claim once the anonymous budget is spent', () => {
    const spent = { budgetSeconds: 60, remainingSeconds: 0, expired: true };
    expect(shouldAutoClaim(facts({ budget: spent }))).toBe(false);
  });

  it('is a ONE-shot: never re-fires after an attempt', () => {
    // Everything after the first claim comes from a button a person pressed.
    expect(shouldAutoClaim(facts({ attempts: 1 }))).toBe(false);
  });

  it('never claims a second cell while one is held or in flight', () => {
    expect(shouldAutoClaim(facts({ holding: true }))).toBe(false);
    expect(shouldAutoClaim(facts({ busy: true }))).toBe(false);
  });
});

describe('mirroredRemaining', () => {
  it('mirrors the server number as wall time passes', () => {
    expect(mirroredRemaining(60, T0, T0)).toBe(60);
    expect(mirroredRemaining(60, T0, T0 + 12_400)).toBe(48);
  });

  it('SNAPS to a later poll instead of drifting away from it', () => {
    // The contract makes the server authoritative; a client that accumulated
    // its own ticks would disagree with the plane that enforces the budget.
    expect(mirroredRemaining(41, T0 + 20_000, T0 + 21_000)).toBe(40);
  });

  it('never shows a negative countdown', () => {
    expect(mirroredRemaining(3, T0, T0 + 90_000)).toBe(0);
  });

  it('ignores a clock that ran backwards between polls', () => {
    expect(mirroredRemaining(30, T0, T0 - 5_000)).toBe(30);
  });

  it('STANDS STILL while the visitor holds no machine', () => {
    // The budget is sixty seconds of CONNECTED time. A disconnected visitor is
    // spending nothing, and a clock that ran anyway would sprint away from the
    // server between polls and jump back up on the next one.
    expect(mirroredRemaining(45, T0, T0 + 30_000, false)).toBe(45);
    expect(mirroredRemaining(45, T0, T0 + 30_000, true)).toBe(15);
  });

  it('still refuses to render a negative number when disconnected', () => {
    expect(mirroredRemaining(-4, T0, T0, false)).toBe(0);
  });
});

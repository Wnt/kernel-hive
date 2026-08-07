// Behavioral contract of the OSK send engine: latch one-shot, danger two-tap
// arm, client-side tap-repeat, and the ownDown-only dispose discipline.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createKeySender } from './keySender';
import type { KeyDef } from './keyTypes';
import { DANGER_ARM_MS, REPEAT_DELAY_MS, REPEAT_INTERVAL_MS } from './oskConstants';

const CTRL = 0xffe3;
const ALT = 0xffe9;
const DEL = 0xffff;
const X = 0x78;
const BKSP = 0xff08;

type LogEntry = ['key', number, boolean] | ['type', string];

function rig(now?: () => number) {
  const log: LogEntry[] = [];
  const releaseAllKeys = vi.fn();
  const handle = {
    sendKey: (ks: number, down: boolean) => { log.push(['key', ks, down]); },
    typeText: (t: string) => { log.push(['type', t]); },
    // Extra method a real StreamControlHandle carries — the sender must NEVER
    // call it (it would flush keys a desktop user is physically holding).
    releaseAllKeys,
  };
  let current: typeof handle | null = handle;
  const sender = createKeySender(() => current, { now });
  return { log, sender, releaseAllKeys, unplug: () => { current = null; } };
}

const tapDef = (ks: number, extra: Partial<KeyDef> = {}): KeyDef =>
  ({ id: `tap-${ks}`, label: 'k', action: 'tap', keysym: ks, ...extra });
const latchDef = (ks: number): KeyDef =>
  ({ id: `latch-${ks}`, label: 'm', action: 'latch', keysym: ks });
const CAD: KeyDef = {
  id: 'cad', label: 'C-A-D', action: 'macro', danger: true,
  steps: [
    { keysym: CTRL, down: true }, { keysym: ALT, down: true },
    { keysym: DEL, down: true }, { keysym: DEL, down: false },
    { keysym: ALT, down: false }, { keysym: CTRL, down: false },
  ],
};

afterEach(() => { vi.useRealTimers(); });

describe('latch one-shot', () => {
  it('wraps the next tap and releases (Ctrl↓ X↓ X↑ Ctrl↑)', () => {
    const { log, sender } = rig();
    sender.press(latchDef(CTRL));
    sender.press(tapDef(X));
    expect(log).toEqual([
      ['key', CTRL, true], ['key', X, true], ['key', X, false], ['key', CTRL, false],
    ]);
    expect(sender.latchedIds().size).toBe(0);
  });

  it('tap-again releases the latch immediately', () => {
    const { log, sender } = rig();
    const d = latchDef(CTRL);
    sender.press(d);
    expect(sender.latchedIds().has(d.id)).toBe(true);
    sender.press(d);
    expect(log).toEqual([['key', CTRL, true], ['key', CTRL, false]]);
    expect(sender.latchedIds().size).toBe(0);
  });

  it('combines with a char action, then releases', () => {
    const { log, sender } = rig();
    sender.press(latchDef(CTRL));
    sender.press({ id: 'c', label: 'c', action: 'char', char: 'c' });
    expect(log).toEqual([['key', CTRL, true], ['type', 'c'], ['key', CTRL, false]]);
  });

  it('releases on noteExternalKeystroke (the free-text path)', () => {
    const { log, sender } = rig();
    sender.press(latchDef(CTRL));
    sender.noteExternalKeystroke();
    expect(log).toEqual([['key', CTRL, true], ['key', CTRL, false]]);
  });

  it('clearLatches releases in reverse-engage order', () => {
    const { log, sender } = rig();
    sender.press(latchDef(CTRL));
    sender.press(latchDef(ALT));
    sender.clearLatches();
    expect(log).toEqual([
      ['key', CTRL, true], ['key', ALT, true], ['key', ALT, false], ['key', CTRL, false],
    ]);
  });
});

describe('dispose discipline', () => {
  it('releases ONLY ownDown keys and never calls releaseAllKeys', () => {
    const { log, sender, releaseAllKeys } = rig();
    sender.press(latchDef(CTRL));
    sender.dispose();
    expect(log).toEqual([['key', CTRL, true], ['key', CTRL, false]]);
    expect(releaseAllKeys).not.toHaveBeenCalled();
    // Disposed sender is inert.
    expect(sender.press(tapDef(X))).toBe('noop');
    expect(log.length).toBe(2);
  });
});

describe('macros + danger', () => {
  it('runs macro steps in exact order', () => {
    const { log, sender } = rig();
    sender.press({ ...CAD, danger: false });
    expect(log).toEqual([
      ['key', CTRL, true], ['key', ALT, true], ['key', DEL, true],
      ['key', DEL, false], ['key', ALT, false], ['key', CTRL, false],
    ]);
  });

  it('danger keys arm on first tap and fire on a confirm inside the window', () => {
    const clock = { t: 0 };
    const { log, sender } = rig(() => clock.t);
    expect(sender.press(CAD)).toBe('armed');
    expect(log).toEqual([]);
    clock.t = DANGER_ARM_MS - 1;
    expect(sender.press(CAD)).toBe('sent');
    expect(log.length).toBe(6);
  });

  it('auto-disarms after the window (a late tap re-arms instead of firing)', () => {
    const clock = { t: 0 };
    const { log, sender } = rig(() => clock.t);
    expect(sender.press(CAD)).toBe('armed');
    clock.t = DANGER_ARM_MS + 1;
    expect(sender.press(CAD)).toBe('armed');
    expect(log).toEqual([]);
  });

  it('any other key disarms a pending danger key', () => {
    const clock = { t: 0 };
    const { log, sender } = rig(() => clock.t);
    expect(sender.press(CAD)).toBe('armed');
    sender.press(tapDef(X));
    expect(log).toEqual([['key', X, true], ['key', X, false]]);
    expect(sender.press(CAD)).toBe('armed'); // must arm afresh
  });

  it('a repeat-key press disarms a pending danger key too', () => {
    vi.useFakeTimers();
    const clock = { t: 0 };
    const { log, sender } = rig(() => clock.t);
    expect(sender.press(CAD)).toBe('armed');
    sender.startRepeat(tapDef(BKSP, { repeat: true })); // keystroke reaches guest
    sender.stopRepeat();
    expect(log).toEqual([['key', BKSP, true], ['key', BKSP, false]]);
    expect(sender.press(CAD)).toBe('armed'); // must arm afresh, never fire
    expect(log.length).toBe(2);
  });

  it('a free-text proxy keystroke disarms a pending danger key too', () => {
    const clock = { t: 0 };
    const { log, sender } = rig(() => clock.t);
    expect(sender.press(CAD)).toBe('armed');
    sender.noteExternalKeystroke(); // abc-input keystroke reached the guest
    expect(sender.press(CAD)).toBe('armed'); // must arm afresh, never fire
    expect(log.length).toBe(0);
  });
});

describe('repeat', () => {
  it('fires immediately, then repeats after the delay at the interval', () => {
    vi.useFakeTimers();
    const { log, sender } = rig();
    sender.startRepeat(tapDef(BKSP, { repeat: true }));
    expect(log.length).toBe(2); // first tap (down+up) is immediate
    vi.advanceTimersByTime(REPEAT_DELAY_MS - 1);
    expect(log.length).toBe(2);
    vi.advanceTimersByTime(1 + REPEAT_INTERVAL_MS);
    expect(log.length).toBe(4);
    vi.advanceTimersByTime(REPEAT_INTERVAL_MS * 2);
    expect(log.length).toBe(8);
    // Every beat is a full down+up pair — a lost stop can never stick a key.
    for (let i = 0; i < log.length; i += 2) {
      expect(log[i]).toEqual(['key', BKSP, true]);
      expect(log[i + 1]).toEqual(['key', BKSP, false]);
    }
    sender.stopRepeat();
    vi.advanceTimersByTime(1000);
    expect(log.length).toBe(8);
  });

  it('stopRepeat is idempotent and cancels mid-delay (pointercancel path)', () => {
    vi.useFakeTimers();
    const { log, sender } = rig();
    sender.startRepeat(tapDef(BKSP, { repeat: true }));
    vi.advanceTimersByTime(100);
    sender.stopRepeat();
    sender.stopRepeat();
    vi.advanceTimersByTime(10_000);
    expect(log.length).toBe(2);
  });

  it('only honors repeat-enabled tap defs', () => {
    vi.useFakeTimers();
    const { log, sender } = rig();
    sender.startRepeat(tapDef(BKSP)); // repeat flag absent
    sender.startRepeat({ id: 'l', label: 'l', action: 'latch', keysym: CTRL, repeat: true });
    vi.advanceTimersByTime(5000);
    expect(log).toEqual([]);
  });
});

describe('null handle', () => {
  it('press is a noop without a handle', () => {
    const { log, sender, unplug } = rig();
    unplug();
    expect(sender.press(tapDef(X))).toBe('noop');
    expect(sender.press(latchDef(CTRL))).toBe('noop');
    expect(log).toEqual([]);
  });
});

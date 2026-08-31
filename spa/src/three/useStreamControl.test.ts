// Regression coverage for the stuck-key class of bug found in production
// (clientlog.jsonl session 6a888f3d): a key's RELEASE must send the SAME
// scancode its PRESS did, from the physical KeyboardEvent.code — never one
// re-resolved from KeyboardEvent.key, which can already have changed character
// by the time the keyup arrives. See docs/lab/INPUT-DEBUGGING.md and
// createStreamController's sendCharEvent/sendKeyEvent in useStreamControl.ts.
//
// This project's vitest config runs plain Node (no jsdom — see vitest.config.ts),
// and createStreamController's stats poll reaches for `window.setInterval`
// unconditionally. Rather than pull the DOM-heavy environment in for one file,
// stub the couple of timer methods it needs onto a fake `window` and fake the
// clock underneath them, same as any other Node-only timer test.
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { createStreamController } from './useStreamControl';
import type { StreamClient } from './streamClient';

vi.mock('../analytics', () => ({ reach: vi.fn() }));
import { reach } from '../analytics';

const noMods = () => false;

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal('window', {
    setInterval: (...a: Parameters<typeof setInterval>) => setInterval(...a),
    clearInterval: (id: Parameters<typeof clearInterval>[0]) => clearInterval(id),
    setTimeout: (...a: Parameters<typeof setTimeout>) => setTimeout(...a),
  });
  vi.mocked(reach).mockClear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

function fakeClient() {
  const scancodes: { code: number; down: boolean }[] = [];
  const c = {
    isConnected: () => true,
    getBannerState: () => 'good',
    getExitReason: () => null,
    getFrameStalled: () => false,
    getLastDecodeError: () => null,
    isAudioEnabled: () => false,
    setAudioEnabled: () => {},
    getStats: () => ({}),
    getMetrics: () => null,
    tickStats: () => {},
    sendKeyScancode: (code: number, down: boolean) => { scancodes.push({ code, down }); },
    sendMoveAbs: () => {},
    sendMoveRel: () => {},
    sendRehomeHint: () => {},
    sendButton: () => {},
    sendWheel: () => {},
    moveWireSnapshot: () => ({ sent: 0, rejected: 0, desiredSizeMin: null }),
  } as unknown as StreamClient;
  return { c, scancodes };
}

function makeHandle() {
  const { c, scancodes } = fakeClient();
  const { handle } = createStreamController(c, { getResolution: () => ({ w: 640, h: 480 }) });
  return { handle, scancodes };
}

describe('sendKeyEvent — stuck-key regression (session 6a888f3d)', () => {
  it('releases the SAME scancode the press sent (Shift+/ => "?"), even when ' +
     'the keyup event reports a different character than the keydown did', () => {
    const { handle, scancodes } = makeHandle();

    // Shift down.
    handle.sendKeyEvent({ key: 'Shift', code: 'ShiftLeft', getModifierState: noMods }, true);
    // '/' pressed WHILE Shift is held: the browser resolves e.key to '?'.
    handle.sendKeyEvent({ key: '?', code: 'Slash', getModifierState: noMods }, true);
    // Shift released.
    handle.sendKeyEvent({ key: 'Shift', code: 'ShiftLeft', getModifierState: noMods }, false);
    // '/' released — but by now e.key has already flipped to '=' (Shift is up),
    // exactly the ordering hazard from clientlog.jsonl session 6a888f3d.
    handle.sendKeyEvent({ key: '=', code: 'Slash', getModifierState: noMods }, false);

    expect(scancodes).toEqual([
      { code: 0x2a, down: true },  // Shift make
      { code: 0x35, down: true },  // '/' make (SLASH)
      { code: 0x2a, down: false }, // Shift break
      { code: 0x35, down: false }, // '/' break — the fix: same scancode as the press
    ]);
    // The bug sent a break for '=' (0x0d, EQUALS) instead — must never appear.
    expect(scancodes.some((s) => s.code === 0x0d)).toBe(false);
    // A correctly paired release is not an "orphan".
    expect(reach).not.toHaveBeenCalledWith('station.key.orphanedRelease', 'auto');
  });

  it('still holds a plain letter for repeat/gaming (Shift not involved at all)', () => {
    const { handle, scancodes } = makeHandle();
    handle.sendKeyEvent({ key: 'a', code: 'KeyA', getModifierState: noMods }, true);
    handle.sendKeyEvent({ key: 'a', code: 'KeyA', getModifierState: noMods }, false);
    expect(scancodes).toEqual([
      { code: 0x1e, down: true },
      { code: 0x1e, down: false },
    ]);
  });
});

describe('sendKeyEvent — dead keys / non-ASCII fall back to the positional path', () => {
  it('ä (no ASCII scancode) is forwarded via KeyboardEvent.code, unchanged', () => {
    const { handle, scancodes } = makeHandle();
    // 'Quote' is a real set1-mapped code; the character 'ä' has no ASCII entry,
    // so sendCharEvent must decline and the positional path must take over.
    handle.sendKeyEvent({ key: 'ä', code: 'Quote', getModifierState: noMods }, true);
    handle.sendKeyEvent({ key: 'ä', code: 'Quote', getModifierState: noMods }, false);
    expect(scancodes).toEqual([
      { code: 0x28, down: true },  // Quote
      { code: 0x28, down: false },
    ]);
  });
});

describe('sendKeyEvent — tappedCodes (Shift-toggling symbol taps) unchanged', () => {
  it('a symbol needing a Shift TOGGLE is a self-contained tap; its keyup is swallowed', () => {
    const { handle, scancodes } = makeHandle();
    // '1' held down, no Shift: pressing '!' (Shift+1) must tap Shift, tap '1', restore.
    handle.sendKeyEvent({ key: '!', code: 'Digit1', getModifierState: noMods }, true);
    expect(scancodes).toEqual([
      { code: 0x2a, down: true },  // synthetic Shift make
      { code: 0x02, down: true },  // '1' make
      { code: 0x02, down: false }, // '1' break
      { code: 0x2a, down: false }, // synthetic Shift break
    ]);
    scancodes.length = 0;
    // The paired keyup must be swallowed — no further wire traffic at all.
    handle.sendKeyEvent({ key: '!', code: 'Digit1', getModifierState: noMods }, false);
    expect(scancodes).toEqual([]);
  });
});

describe('sendKeyEvent — suppressedMods (AltGr composing modifiers) unchanged', () => {
  it('swallows AltRight down+up while AltGraph is active', () => {
    const { handle, scancodes } = makeHandle();
    handle.sendKeyEvent({ key: 'Alt', code: 'AltRight', getModifierState: (k) => k === 'AltGraph' }, true);
    handle.sendKeyEvent({ key: 'Alt', code: 'AltRight', getModifierState: (k) => k === 'AltGraph' }, false);
    expect(scancodes).toEqual([]);
  });
});

describe('station.key.orphanedRelease probe', () => {
  it('counts a keyup whose physical code was never recorded as pressed', () => {
    const { handle, scancodes } = makeHandle();
    // A bare keyup for a modifier that was never seen down (e.g. focus moved
    // mid-chord) — positional path, no prior keydown recorded anywhere.
    handle.sendKeyEvent({ key: 'Control', code: 'ControlRight', getModifierState: noMods }, false);
    expect(scancodes.length).toBe(1);
    expect(scancodes[0].down).toBe(false);
    expect(reach).toHaveBeenCalledWith('station.key.orphanedRelease', 'auto');
  });
});

describe('station.key.stuckAtSessionEnd probe', () => {
  it('fires when dispose() finds keys still recorded down, and releases them', () => {
    const { handle, scancodes } = makeHandle();
    handle.sendKeyEvent({ key: 'a', code: 'KeyA', getModifierState: noMods }, true);
    // No matching keyup — the tab died mid-chord.
    scancodes.length = 0;
    handle.dispose();
    expect(reach).toHaveBeenCalledWith('station.key.stuckAtSessionEnd', 'auto');
    expect(scancodes).toEqual([{ code: 0x1e, down: false }]); // releaseAllKeys cleaned it up
  });

  it('does not fire when every key was released before dispose()', () => {
    const { handle } = makeHandle();
    handle.sendKeyEvent({ key: 'a', code: 'KeyA', getModifierState: noMods }, true);
    handle.sendKeyEvent({ key: 'a', code: 'KeyA', getModifierState: noMods }, false);
    handle.dispose();
    expect(reach).not.toHaveBeenCalledWith('station.key.stuckAtSessionEnd', 'auto');
  });
});

// Capitals typed without a physical Shift on machines whose letter keys ARE the
// capitals (registry typeIn.case 'unshifted': vic20...). See capitalsAsLetters.ts.
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { createStreamController } from './useStreamControl';
import type { StreamClient } from './streamClient';

vi.mock('../analytics', () => ({ reach: vi.fn() }));

const capsOn = (name: string) => name === 'CapsLock';
const none = () => false;

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal('window', {
    setInterval: (...a: Parameters<typeof setInterval>) => setInterval(...a),
    clearInterval: (id: Parameters<typeof clearInterval>[0]) => clearInterval(id),
    setTimeout: (...a: Parameters<typeof setTimeout>) => setTimeout(...a),
  });
});
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

function make(osId: string) {
  const scancodes: { code: number; down: boolean }[] = [];
  const c = {
    isConnected: () => true, getBannerState: () => 'good', getExitReason: () => null,
    getFrameStalled: () => false, getLastDecodeError: () => null, isAudioEnabled: () => false,
    setAudioEnabled: () => {}, getStats: () => ({}), getMetrics: () => null, tickStats: () => {},
    sendKeyScancode: (code: number, down: boolean) => { scancodes.push({ code, down }); },
    sendMoveAbs: () => {}, sendMoveRel: () => {}, sendRehomeHint: () => {}, sendButton: () => {},
    sendWheel: () => {}, moveWireSnapshot: () => ({ sent: 0, rejected: 0, desiredSizeMin: null }),
  } as unknown as StreamClient;
  const { handle } = createStreamController(c, { getResolution: () => ({ w: 640, h: 480 }), osId });
  return { handle, scancodes };
}

const A = 0x1e, SHIFT = 0x2a;
const key = (k: string, down: boolean, h: ReturnType<typeof make>['handle'], gms: (n: string) => boolean = none) =>
  h.sendKeyEvent({ key: k, code: 'KeyA', getModifierState: gms }, down);

describe('capital letter without a physical Shift', () => {
  it('vic20: Caps Lock "A" is the bare key, held and released as one make/break', () => {
    const { handle, scancodes } = make('vic20');
    key('A', true, handle, capsOn);
    expect(scancodes).toEqual([{ code: A, down: true }]);
    key('A', false, handle, capsOn);
    expect(scancodes).toEqual([{ code: A, down: true }, { code: A, down: false }]);
  });

  it('vic20: SendText-style "A" (no modifier state at all) is the bare key', () => {
    const { handle, scancodes } = make('vic20');
    key('A', true, handle);
    key('A', false, handle);
    expect(scancodes).toEqual([{ code: A, down: true }, { code: A, down: false }]);
  });

  it('vic20: physical Shift + A keeps Shift (the graphics glyph stays reachable)', () => {
    const { handle, scancodes } = make('vic20');
    handle.sendKeyEvent({ key: 'Shift', code: 'ShiftLeft', getModifierState: none }, true);
    key('A', true, handle);
    key('A', false, handle);
    handle.sendKeyEvent({ key: 'Shift', code: 'ShiftLeft', getModifierState: none }, false);
    expect(scancodes).toEqual([
      { code: SHIFT, down: true }, { code: A, down: true }, { code: A, down: false }, { code: SHIFT, down: false },
    ]);
  });

  it.each(['cbm8032', 'cbm2', 'win98', 'zxspectrum'])('%s: unchanged, still a Shift tap + A', (osId) => {
    const { handle, scancodes } = make(osId);
    key('A', true, handle);
    key('A', false, handle);
    expect(scancodes).toEqual([
      { code: SHIFT, down: true }, { code: A, down: true }, { code: A, down: false }, { code: SHIFT, down: false },
    ]);
  });

  it('vic20: a symbol that needs Shift (!) still gets its synthetic Shift', () => {
    const { handle, scancodes } = make('vic20');
    handle.sendKeyEvent({ key: '!', code: 'Digit1', getModifierState: none }, true);
    expect(scancodes[0]).toEqual({ code: SHIFT, down: true });
  });
});

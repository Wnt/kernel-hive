// The station charMap applied to the visitor's own printable keys
// (registry keyboard.physical: true). See physicalCharMap.ts.
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { createStreamController } from './useStreamControl';
import { physicalChar, physicalCharMapFor, physicalTypist } from './physicalCharMap';
import { createKeySender } from '../ui/keyboard/keySender';
import type { StreamClient } from './streamClient';

vi.mock('../analytics', () => ({ reach: vi.fn() }));

// Fixture boards, independent of the registry: a German-layout guest (y/z
// swapped, `"` on Shift+2, `+` on the unshifted `]` key), the same map WITHOUT
// the opt-in, and a capitals-are-letters machine with a map that tells the two
// composition orders apart.
const GERMAN = { y: 'z', z: 'y', Y: 'Z', Z: 'Y', '"': '@', '+': ']' };
vi.mock('../data/keyboards', () => ({
  keyboardFor: (osId: string) => ({
    german: { charMap: GERMAN, physical: true },
    typistonly: { charMap: GERMAN },
    casemap: { charMap: { a: 'b', A: 'C' }, physical: true },
  } as Record<string, unknown>)[osId],
}));
vi.mock('../data/demoPrograms', async (orig) => {
  const real = await orig<typeof import('../data/demoPrograms')>();
  return { ...real, typeInFor: (osId: string) => (osId === 'casemap' ? { case: 'unshifted' } : real.typeInFor(osId)) };
});

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
  const sent: { code: number; down: boolean }[] = [];
  const c = {
    isConnected: () => true, getBannerState: () => 'good', getExitReason: () => null,
    getFrameStalled: () => false, getLastDecodeError: () => null, isAudioEnabled: () => false,
    setAudioEnabled: () => {}, getStats: () => ({}), getMetrics: () => null, tickStats: () => {},
    sendKeyScancode: (code: number, down: boolean) => { sent.push({ code, down }); },
    sendMoveAbs: () => {}, sendMoveRel: () => {}, sendRehomeHint: () => {}, sendButton: () => {},
    sendWheel: () => {}, moveWireSnapshot: () => ({ sent: 0, rejected: 0, desiredSizeMin: null }),
  } as unknown as StreamClient;
  const { handle } = createStreamController(c, { getResolution: () => ({ w: 640, h: 480 }), osId });
  const none = () => false;
  const key = (k: string, code: string, down: boolean, gms: (n: string) => boolean = none) =>
    handle.sendKeyEvent({ key: k, code, getModifierState: gms }, down);
  const shift = (down: boolean) => key('Shift', 'ShiftLeft', down);
  return { handle, sent, key, shift };
}

const SHIFT = 0x2a, Y = 0x15, Z = 0x2c, A = 0x1e, B = 0x30, TWO = 0x03, RBRACKET = 0x1b, QUOTE = 0x28, EQUALS = 0x0d;
const dn = (code: number) => ({ code, down: true });
const up = (code: number) => ({ code, down: false });

describe('physical keys through the station charMap (keyboard.physical)', () => {
  it('mapped char with no Shift: y is the guest z key, one make/break', () => {
    const { sent, key } = make('german');
    key('y', 'KeyY', true);
    key('y', 'KeyY', false);
    expect(sent).toEqual([dn(Z), up(Z)]);
  });

  it('mapped char with no Shift, visitor holding Shift (+ on a US board): Shift is lifted around the bare ] key', () => {
    const { sent, key, shift } = make('german');
    shift(true);
    key('+', 'Equal', true);
    key('+', 'Equal', false);
    shift(false);
    expect(sent).toEqual([dn(SHIFT), up(SHIFT), dn(RBRACKET), up(RBRACKET), dn(SHIFT), up(SHIFT)]);
  });

  it('mapped char that needs Shift, visitor not holding it (Caps-style "): synthetic Shift + 2', () => {
    const { sent, key } = make('german');
    key('"', 'Quote', true);
    key('"', 'Quote', false);
    expect(sent).toEqual([dn(SHIFT), dn(TWO), up(TWO), up(SHIFT)]);
  });

  it('mapped char that needs Shift, visitor holding Shift (" on a US board): a held make/break of 2', () => {
    const { sent, key, shift } = make('german');
    shift(true);
    key('"', 'Quote', true);
    key('"', 'Quote', false);
    shift(false);
    expect(sent).toEqual([dn(SHIFT), dn(TWO), up(TWO), up(SHIFT)]);
    expect(sent).not.toContainEqual(dn(QUOTE));
  });

  it('unmapped char unchanged: a and = go to their US keys', () => {
    const { sent, key } = make('german');
    key('a', 'KeyA', true); key('a', 'KeyA', false);
    key('=', 'Equal', true); key('=', 'Equal', false);
    expect(sent).toEqual([dn(A), up(A), dn(EQUALS), up(EQUALS)]);
  });

  it('keyup symmetry: the release is the scancode the press SENT, even when e.key changes in between', () => {
    const { sent, key } = make('german');
    key('y', 'KeyY', true);
    // Caps Lock toggled mid-hold: the browser now reports Y for the same key,
    // which maps to the guest's Shift+Z. The release must still be the z key.
    key('Y', 'KeyY', false);
    expect(sent).toEqual([dn(Z), up(Z)]);
  });

  it('keyup symmetry: a tapped (Shift-toggled) mapped key swallows its keyup', () => {
    const { sent, key } = make('german');
    key('"', 'Quote', true);
    const n = sent.length;
    key('"', 'Quote', false);
    expect(sent.length).toBe(n);
  });

  it('the editor holdKeyboard pause still drops the visitor\'s mapped keys', () => {
    const { handle, sent, key } = make('german');
    const release = handle.holdKeyboard();
    key('y', 'KeyY', true); key('y', 'KeyY', false);
    release();
    expect(sent).toEqual([]);
  });

  it.each(['typistonly', 'zxspectrum', 'win98'])('%s (no keyboard.physical): unchanged, US positions', (osId) => {
    const { sent, key } = make(osId);
    key('y', 'KeyY', true); key('y', 'KeyY', false);
    key('"', 'Quote', true); key('"', 'Quote', false);
    expect(sent).toEqual([dn(Y), up(Y), dn(SHIFT), dn(QUOTE), up(QUOTE), up(SHIFT)]);
  });
});

describe('composition with capitalsAsLetters: the case rule first, then the map', () => {
  it('casemap: a bare capital A is the letter a, which the map sends as the b key', () => {
    const { sent, key } = make('casemap');
    key('A', 'KeyA', true, (n) => n === 'CapsLock');
    key('A', 'KeyA', false, (n) => n === 'CapsLock');
    // map-then-case would send A -> C -> the bare c key (0x2e)
    expect(sent).toEqual([dn(B), up(B)]);
  });

  it('casemap: physical Shift + A keeps Shift, so the map sees A', () => {
    const { sent, key, shift } = make('casemap');
    shift(true);
    key('A', 'KeyA', true);
    key('A', 'KeyA', false);
    shift(false);
    expect(sent).toEqual([dn(SHIFT), dn(0x2e), up(0x2e), up(SHIFT)]);
  });

  it('physicalChar: case rule, then map; no map is identity', () => {
    expect(physicalChar('A', true, { a: 'b', A: 'C' })).toBe('b');
    expect(physicalChar('A', false, { a: 'b', A: 'C' })).toBe('C');
    expect(physicalChar('A', true, undefined)).toBe('a');
    expect(physicalChar('q', false, { a: 'b' })).toBe('q');
  });
});

describe('the on-screen keyboard typeText paths (physicalTypist)', () => {
  const rec = () => {
    const typed: string[] = [];
    const keys: [number, boolean][] = [];
    return { typed, keys, h: { typeText: (t: string) => { typed.push(t); }, sendKey: (k: number, d: boolean) => { keys.push([k, d]); } } };
  };

  it('maps each character through the station charMap; sendKey passes through', () => {
    const { typed, keys, h } = rec();
    const t = physicalTypist(h, GERMAN)!;
    t.typeText('"');
    t.typeText('y+a');
    t.sendKey(0xff0d, true);
    expect(typed).toEqual(['@', 'z]a']);
    expect(keys).toEqual([[0xff0d, true]]);
  });

  it('no map (station without keyboard.physical): the handle itself, unchanged', () => {
    const { h } = rec();
    expect(physicalTypist(h, undefined)).toBe(h);
    expect(physicalTypist(null, GERMAN)).toBeNull();
  });

  it('a keySender char button on a physical station types the mapped character', () => {
    const { typed, h } = rec();
    const sender = createKeySender(() => physicalTypist(h, physicalCharMapFor('german')), {});
    sender.press({ id: 'quote', label: '"', action: 'char', char: '"' } as Parameters<typeof sender.press>[0]);
    expect(typed).toEqual(['@']);
  });
});

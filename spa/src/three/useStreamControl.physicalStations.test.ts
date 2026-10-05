// The keyboard.physical stations, read from the REAL registry data (keyboards.ts,
// demoPrograms.ts): what a US visitor's own keys send on each one, and the
// composition with the case rule (capitalsAsLetters) where the station has one.
// The mechanism itself is useStreamControl.physicalCharMap.test.ts; this file
// pins the per-station facts measured on the framebuffer in the physical-charmap
// wave (2026-10-05, docs/TYPE-IN-EDITOR.md "The station charMap on the visitor's
// keyboard").
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { createStreamController } from './useStreamControl';
import { physicalChar, physicalCharMapFor } from './physicalCharMap';
import { capitalsAreBareLetters } from './capitalsAsLetters';
import { asciiToScancode } from './guestQuirks';
import { keyboardFor } from '../data/keyboards';
import { typeInFor } from '../data/demoPrograms';
import type { StreamClient } from './streamClient';

vi.mock('../analytics', () => ({ reach: vi.fn() }));

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal('window', {
    setInterval: (...a: Parameters<typeof setInterval>) => setInterval(...a),
    clearInterval: (id: Parameters<typeof clearInterval>[0]) => clearInterval(id),
    setTimeout: (...a: Parameters<typeof setTimeout>) => setTimeout(...a),
  });
});
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

const PHYSICAL = [
  'amstradcpc', 'armeval', 'atari800xl', 'bbcmicro', 'cpm22', 'dragon32', 'fmtowns', 'kc854',
  'mpf2', 'msxturbor', 'samcoupe', 'svi328', 'svi328cpm', 'symbos',
];

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
  let shiftHeld = false;
  let caps = false;
  const mods = (n: string) => (n === 'Shift' ? shiftHeld : n === 'CapsLock' ? caps : false);
  const shift = (down: boolean) => {
    shiftHeld = down;
    handle.sendKeyEvent({ key: 'Shift', code: 'ShiftLeft', getModifierState: mods }, down);
  };
  const tap = (key: string, code: string) => {
    handle.sendKeyEvent({ key, code, getModifierState: mods }, true);
    handle.sendKeyEvent({ key, code, getModifierState: mods }, false);
  };
  return { sent, shift, tap, setCaps: (on: boolean) => { caps = on; } };
}

const SHIFT = 0x2a;
const dn = (code: number) => ({ code, down: true });
const up = (code: number) => ({ code, down: false });
/** The edges one guest key makes, with or without a Shift wrapped round it. */
const press = (code: number, shifted: boolean) =>
  (shifted ? [dn(SHIFT), dn(code), up(code), up(SHIFT)] : [dn(code), up(code)]);
/** What the guest sees: each non-Shift key press with the Shift level at that instant. */
const guestPresses = (sent: { code: number; down: boolean }[]) => {
  let shift = false;
  const out: { code: number; shift: boolean }[] = [];
  for (const e of sent) {
    if (e.code === SHIFT) shift = e.down;
    else if (e.down) out.push({ code: e.code, shift });
  }
  expect(shift).toBe(false); // nothing left held
  return out;
};

describe('every keyboard.physical station', () => {
  it('is the set this wave enabled (a new one gets its facts pinned here)', () => {
    const on = PHYSICAL.filter((id) => physicalCharMapFor(id));
    expect(on).toEqual(PHYSICAL);
    expect(physicalCharMapFor('domainos')).toBeUndefined();
  });

  it.each(PHYSICAL)('%s: every target is one US key, no entry maps a character to itself', (id) => {
    const map = physicalCharMapFor(id)!;
    for (const [guest, host] of Object.entries(map)) {
      expect(asciiToScancode(host), `${id} ${guest} -> ${host}`).not.toBeNull();
      expect(host, `${id} ${guest}`).not.toBe(guest);
    }
  });

  it.each(PHYSICAL)('%s: no unreachable character carries a mapping (that would be a fake)', (id) => {
    const map = physicalCharMapFor(id)!;
    for (const ch of typeInFor(id)?.unreachable ?? '') expect(map[ch], `${id} ${ch}`).toBeUndefined();
  });

  it.each(PHYSICAL.filter(capitalsAreBareLetters))(
    '%s (case: unshifted): a bare capital is still a letter key after the map',
    (id) => {
      const map = physicalCharMapFor(id);
      for (const c of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') {
        const s = asciiToScancode(physicalChar(c, true, map));
        expect(s, `${id} ${c}`).toEqual(asciiToScancode(c.toLowerCase()));
      }
    },
  );
});

describe('per station, the visitor holding Shift as on a US keyboard', () => {
  // US scancodes: 2 0x03, 6 0x07, 7 0x08, 8 0x09, - 0x0c, = 0x0d, [ 0x1a, ] 0x1b,
  // ; 0x27, ' 0x28, ` 0x29, \ 0x2b, / 0x35, A 0x1e, O 0x18
  const cases: [string, string, number, boolean][] = [
    ['bbcmicro', '"', 0x03, true], ['bbcmicro', '+', 0x27, true], ['bbcmicro', '@', 0x2b, false],
    ['armeval', '*', 0x28, true],
    ['samcoupe', '\\', 0x35, true], ['samcoupe', '=', 0x1a, false],
    ['svi328', '~', 0x2b, true], ['svi328cpm', ':', 0x27, false],
    ['msxturbor', '{', 0x1b, true], ['msxturbor', '}', 0x2b, true], ['msxturbor', '~', 0x0d, true],
    ['fmtowns', ']', 0x29, false], ['fmtowns', '}', 0x29, true], ['fmtowns', '"', 0x03, true],
    ['symbos', '"', 0x29, true], ['symbos', "'", 0x29, false],
    ['atari800xl', '*', 0x2b, false], ['atari800xl', '<', 0x0c, false], ['atari800xl', '@', 0x09, true],
    ['mpf2', '=', 0x18, true],
    ['dragon32', ':', 0x0c, false],
  ];
  const codeOf: Record<string, string> = {
    '"': 'Quote', '+': 'Equal', '@': 'Digit2', '*': 'Digit8', '\\': 'Backslash', '=': 'Equal', '~': 'Backquote',
    ':': 'Semicolon', '{': 'BracketLeft', '}': 'BracketRight', ']': 'BracketRight', "'": 'Quote', '<': 'Comma',
  };
  it.each(cases)('%s: %s goes out as scancode %d (guest Shift %s)', (id, ch, code, shifted) => {
    const kb = make(id);
    const visitorShift = asciiToScancode(ch)!.shift;
    if (visitorShift) kb.shift(true);
    kb.tap(ch, codeOf[ch]);
    if (visitorShift) kb.shift(false);
    expect(guestPresses(kb.sent), `${id} ${ch}`).toEqual([{ code, shift: shifted }]);
  });
});

describe('kc854: the case swap gives the visitor the case they typed', () => {
  // The KC's plain letter row is UPPER case and Shift gives lower case; the map
  // swaps all 52 letters. PC Caps Lock is not bound on this station
  // (kc854.keymap), so the browser alone decides the case.
  const A = 0x1e;
  it('a (no Shift) is Shift+A on the KC: lower case', () => {
    const kb = make('kc854');
    kb.tap('a', 'KeyA');
    expect(kb.sent).toEqual(press(A, true));
  });
  it('Shift+A is the bare A key: upper case (the visitor\'s Shift is lifted round it)', () => {
    const kb = make('kc854');
    kb.shift(true);
    kb.tap('A', 'KeyA');
    kb.shift(false);
    expect(kb.sent).toEqual([dn(SHIFT), up(SHIFT), dn(A), up(A), dn(SHIFT), up(SHIFT)]);
  });
  it('Caps Lock on, no Shift: the browser says A, the KC gets the bare A key', () => {
    const kb = make('kc854');
    kb.setCaps(true);
    kb.tap('A', 'KeyA');
    expect(kb.sent).toEqual(press(A, false));
  });
  it('Caps Lock on + Shift: the browser says a, the KC gets Shift+A', () => {
    const kb = make('kc854');
    kb.setCaps(true);
    kb.shift(true);
    kb.tap('a', 'KeyA');
    kb.shift(false);
    expect(kb.sent).toEqual([dn(SHIFT), dn(A), up(A), up(SHIFT)]);
  });
  it('has no case rule to compose with', () => {
    expect(capitalsAreBareLetters('kc854')).toBe(false);
    expect(keyboardFor('kc854')?.charMap?.a).toBe('A');
  });
});

describe('mpf2: upper-only, so a capital with Shift held is the letter, not its symbol', () => {
  const P = 0x19;
  it('Shift+P is the bare P key (Shift+P on the MPF-II is +)', () => {
    const kb = make('mpf2');
    kb.shift(true);
    kb.tap('P', 'KeyP');
    kb.shift(false);
    expect(kb.sent).toEqual([dn(SHIFT), up(SHIFT), dn(P), up(P), dn(SHIFT), up(SHIFT)]);
  });
  it('+ is still Shift+P', () => {
    const kb = make('mpf2');
    kb.shift(true);
    kb.tap('+', 'Equal');
    kb.shift(false);
    expect(kb.sent).toEqual([dn(SHIFT), dn(P), up(P), up(SHIFT)]);
  });
  it('Caps Lock P (no Shift): the case rule makes it p, which the map leaves as the bare key', () => {
    const kb = make('mpf2');
    kb.setCaps(true);
    kb.tap('P', 'KeyP');
    expect(kb.sent).toEqual(press(P, false));
  });
});

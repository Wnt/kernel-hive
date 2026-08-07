// Unit coverage for the streamhost keycode adapters (KeyboardEvent.code / X11
// keysym / literal ASCII -> QEMU XT set1 scancode) and the per-guest boot
// -dismiss quirk lookup.
import { describe, expect, it } from 'vitest';
import {
  CODE_TO_SCANCODE, KEYSYM_TO_SCANCODE, SHIFT_L_SCANCODE,
  asciiToScancode, codeToScancode, keysymToScancode, quirksFor,
} from './guestQuirks';

describe('scancode tables', () => {
  it('CODE_TO_SCANCODE carries the documented set1 codes', () => {
    expect(CODE_TO_SCANCODE.Escape).toBe(0x01);
    expect(CODE_TO_SCANCODE.Enter).toBe(0x1c);
    // Extended (0xE0-prefixed) keys are OR'd with 0xe000.
    expect(CODE_TO_SCANCODE.ArrowUp).toBe(0xe000 | 0x48);
  });

  it('KEYSYM_TO_SCANCODE carries the X11 keysym mappings sendKey() relies on', () => {
    expect(KEYSYM_TO_SCANCODE[0xff0d]).toBe(0x1c); // Return
    expect(KEYSYM_TO_SCANCODE[0xff1b]).toBe(0x01); // Escape
  });

  it('SHIFT_L_SCANCODE matches the Shift_L entry', () => {
    expect(SHIFT_L_SCANCODE).toBe(0x2a);
  });
});

describe('codeToScancode', () => {
  it('maps a known KeyboardEvent.code', () => {
    expect(codeToScancode('KeyA')).toBe(0x1e);
  });

  it('returns null for unknown or missing codes', () => {
    expect(codeToScancode('NotARealCode')).toBeNull();
    expect(codeToScancode(undefined)).toBeNull();
  });
});

describe('asciiToScancode', () => {
  it('maps lowercase and uppercase letters (uppercase implies shift)', () => {
    expect(asciiToScancode('a')).toEqual({ code: 0x1e, shift: false });
    expect(asciiToScancode('A')).toEqual({ code: 0x1e, shift: true });
  });

  it('maps unshifted and shifted symbol rows', () => {
    expect(asciiToScancode('1')).toEqual({ code: 0x02, shift: false });
    expect(asciiToScancode('!')).toEqual({ code: 0x02, shift: true });
  });

  it('returns null for an empty string or unmapped character', () => {
    expect(asciiToScancode('')).toBeNull();
    expect(asciiToScancode('€')).toBeNull();
  });
});

describe('keysymToScancode', () => {
  it('prefers the direct special-key table', () => {
    expect(keysymToScancode(0xff0d)).toBe(0x1c); // Return
  });

  it('falls back to printable Latin-1 -> ASCII mapping', () => {
    expect(keysymToScancode('A'.charCodeAt(0))).toBe(0x1e); // 'A' == 0x41
  });

  it('returns null outside both the special-key table and the printable range', () => {
    expect(keysymToScancode(0x1000)).toBeNull();
  });
});

describe('quirksFor', () => {
  it('flags win95/win98se for the boot-modal auto-dismiss', () => {
    expect(quirksFor('win95')).toEqual({ bootDismiss: true });
    expect(quirksFor('win98se')).toEqual({ bootDismiss: true });
  });

  it('defaults to no boot-dismiss for any other/undefined osId', () => {
    expect(quirksFor('haiku')).toEqual({ bootDismiss: false });
    expect(quirksFor(undefined)).toEqual({ bootDismiss: false });
  });
});

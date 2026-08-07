import { describe, expect, it } from 'vitest';

import { isAsciiPrintable, isComposedChar } from './composeKey';

const mac = { altHeld: true, altGr: false, isMac: true };

describe('isComposedChar', () => {
  it('treats macOS Option-composed ASCII punctuation as a character', () => {
    // The reported bug: $ is Option+4 on a Finnish Mac and reached the guest as
    // a positional Alt+4 chord instead of '$'.
    for (const ch of ['$', '@', '\\', '|', '{', '}', '[', ']', '~']) {
      expect(isComposedChar(ch, mac)).toBe(true);
    }
  });

  it('leaves Alt+letter a real chord, so guest menu accelerators still work', () => {
    // Option+<letter> on a Mac resolves to a non-ASCII glyph, never a bare letter.
    for (const ch of ['å', '∂', 'ƒ', '˙']) {
      expect(isComposedChar(ch, mac)).toBe(false);
    }
  });

  it('does not treat Alt as composing off macOS', () => {
    // Windows/Linux Alt+4 is a chord; AltGr is the composing modifier there and
    // arrives with its own flag.
    expect(isComposedChar('4', { altHeld: true, altGr: false, isMac: false })).toBe(false);
    expect(isComposedChar('$', { altHeld: true, altGr: false, isMac: false })).toBe(false);
    expect(isComposedChar('$', { altHeld: false, altGr: true, isMac: false })).toBe(true);
  });

  it('ignores multi-codepoint keys such as named keys', () => {
    expect(isComposedChar('Enter', mac)).toBe(false);
    expect(isComposedChar('ArrowLeft', mac)).toBe(false);
  });

  it('accepts printable ASCII only', () => {
    expect(isAsciiPrintable(' ')).toBe(true);
    expect(isAsciiPrintable('~')).toBe(true);
    expect(isAsciiPrintable('\n')).toBe(false);
    expect(isAsciiPrintable('å')).toBe(false);
  });
});

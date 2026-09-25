// ============================================================================
//  deviceChars — a printed legend character → the key edge that types it
//  ---------------------------------------------------------------------------
//  The wire carries PHYSICAL keys (set-1 scancodes) and the station's X server
//  applies a US keymap, so a character reaches the guest as "this key, with or
//  without Shift" on a US keyboard: '!' is Shift + the 1 key. The device then
//  reads the resulting character and types it the way its own keyboard does
//  (keymap contract rule 1), which is why a drawn legend is sent as the
//  character it shows rather than as the device key's position.
//
//  Characters a US keyboard has no key for (ä ö å æ ø € £) ride their own
//  Latin-1 / Euro keysyms, which guestQuirks maps to spare set-1 codes that
//  only the nokia9300 station table resolves; their capitals are the same
//  code under Shift.
// ============================================================================

import { asciiToScancode, keysymToScancode } from '../../three/guestQuirks';

/** What to press to type one character: a keysym, with Shift held or not. */
export interface CharWire {
  keysym: number;
  shift: boolean;
}

// US-keyboard shifted symbol → the unshifted character on the same key.
const US_UNSHIFT: Record<string, string> = {
  '!': '1', '@': '2', '#': '3', $: '4', '%': '5', '^': '6', '&': '7', '*': '8',
  '(': '9', ')': '0', _: '-', '+': '=', '{': '[', '}': ']', ':': ';', '"': "'",
  '~': '`', '|': '\\', '<': ',', '>': '.', '?': '/',
};

// Non-US characters: lowercase keysym, and the capital that is it under Shift.
const EXTRA: Record<string, CharWire> = {
  'ä': { keysym: 0x00e4, shift: false }, 'Ä': { keysym: 0x00e4, shift: true },
  'ö': { keysym: 0x00f6, shift: false }, 'Ö': { keysym: 0x00f6, shift: true },
  'å': { keysym: 0x00e5, shift: false }, 'Å': { keysym: 0x00e5, shift: true },
  'æ': { keysym: 0x00e6, shift: false }, 'Æ': { keysym: 0x00e6, shift: true },
  'ø': { keysym: 0x00f8, shift: false }, 'Ø': { keysym: 0x00f8, shift: true },
  '€': { keysym: 0x20ac, shift: false },
  '£': { keysym: 0x00a3, shift: false },
};

/** The key edge that types `ch`, or null when the wire cannot carry it. */
export function charWire(ch: string): CharWire | null {
  const extra = EXTRA[ch];
  if (extra) return keysymToScancode(extra.keysym) == null ? null : extra;
  const s = asciiToScancode(ch);
  if (!s) return null;
  if (!s.shift) return { keysym: ch.charCodeAt(0), shift: false };
  const base = ch >= 'A' && ch <= 'Z' ? ch.toLowerCase() : US_UNSHIFT[ch];
  return base ? { keysym: base.charCodeAt(0), shift: true } : null;
}

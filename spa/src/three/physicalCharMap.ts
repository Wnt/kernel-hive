import { keyboardFor } from '../data/keyboards';

// ---------------------------------------------------------------------------
//  physicalCharMap — the station's `keyboard.charMap` applied to what the
//  VISITOR types, not only to the typists (demo, type-in editor, labctl).
//
//  The charMap says which US key produces a character on the guest's own
//  layout ("guest character -> the host character whose keystroke produces
//  it"). The typists have always applied it. A visitor's printable keys go
//  through sendCharEvent instead, which resolves KeyboardEvent.key to a US
//  scancode; without this a guest with another layout gets the character the
//  US key position makes there, not the one on the visitor's keycap. cpm22 is
//  the first (2026-10-04): its CP/M is the German GMv2.72, so a US visitor's
//  `"` arrived as nothing and `y` as `z`.
//
//  OPT-IN per station (`keyboard.physical: true`). Stations whose charMap was
//  written for the typists only keep their positional physical keys until
//  each is rechecked.
//
//  ORDER, the fleet contract: the case rule first (capitalsAsLetters decides
//  WHICH character the visitor means, a bare capital being the letter key),
//  then this map (WHICH US key produces it on the guest) — the order the
//  typists apply too (applyCase, then applyKeyboard).
// ---------------------------------------------------------------------------

export const physicalCharMapFor = (osId: string | undefined): Readonly<Record<string, string>> | undefined => {
  const kb = osId ? keyboardFor(osId) : undefined;
  return kb?.physical ? kb.charMap : undefined;
};

/** The character to send for a visitor's printable key: the case rule's
 *  bare letter (when it applies), then the station's physical charMap. */
export const physicalChar = (
  key: string,
  bareLetter: boolean,
  map: Readonly<Record<string, string>> | undefined,
): string => {
  const ch = bareLetter ? key.toLowerCase() : key;
  return map?.[ch] ?? ch;
};

/** What the on-screen keyboard types through: its `char` buttons and its
 *  compose field reach the guest via typeText (synthetic Shift), which never
 *  passes sendCharEvent, so the map is applied here for them. No case rule:
 *  the OSK's shifted layer is the visitor choosing Shift. */
export interface PhysicalTypist {
  sendKey(keysym: number, down: boolean): void;
  typeText(text: string): void;
}

export const physicalTypist = (
  h: PhysicalTypist | null,
  map: Readonly<Record<string, string>> | undefined,
): PhysicalTypist | null =>
  !h || !map
    ? h
    : {
        sendKey: (keysym, down) => h.sendKey(keysym, down),
        typeText: (text) => h.typeText([...text].map((c) => map[c] ?? c).join('')),
      };

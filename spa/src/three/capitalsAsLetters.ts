import { typeInFor } from '../data/demoPrograms';

// A machine whose letter keys ARE its capitals: Shift+letter is a graphics
// glyph (VIC-20, C64, PET 2001, Plus/4, C128) or there is no lower case at
// all, so a visitor's "capital A" is the bare A key.
//
// The source is the registry's type-in case rule (`typeIn.case: 'unshifted'`),
// the same fact the editor already uses to type letters unshifted. NOT
// `keyboard.letterCase`: it is declared by a subset (it misses plus4, c128,
// bbcmicro...) and by zxspectrum, where CAPS SHIFT + letter is a real capital.
// The business PETs (code-lower), the PCs and c64 (GEOS) declare no such rule.
export const capitalsAreBareLetters = (osId: string | undefined): boolean =>
  !!osId && typeInFor(osId)?.case === 'unshifted';

/** An upper-case ASCII letter: when it arrives without the guest's Shift down
 *  it came from Caps Lock, SendText-style injection, an IME or a paste. */
export const isBareCapital = (key: string): boolean => key.length === 1 && key >= 'A' && key <= 'Z';

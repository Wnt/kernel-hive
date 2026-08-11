// ============================================================================
//  qwertyLayout — the universal full-QWERTY glyph layers for the shared OSK
//  ---------------------------------------------------------------------------
//  A phone-fit QWERTY built ENTIRELY from 'char' KeyDefs (delivered by
//  keySender → handle.typeText → asciiToScancode, which owns the correct
//  synthetic-Shift per US layout). Every printable US glyph is asciiToScancode-
//  mappable, so this layer needs ZERO new scancodes and ZERO per-station lab
//  verification — it works on all 30 stations, kiosks included.
//
//  It lives OUTSIDE keyboardProfiles.PROFILES — a SIBLING structure — so the
//  profile invariants (keyboardProfiles.test.ts) stay untouched and green.
//
//  Shift is a PARALLEL glyph table: each QKey pairs a `base` char def with its
//  `shifted` twin (a→A, 1→!). KB-3's 3-state Shift merely indexes base-vs-shifted
//  at render. There is NEVER a latched Shift here — keysymToScancode DISCARDS the
//  shift flag (keyTypes.ts), so a latched Shift + a printable tap would emit the
//  WRONG glyph ('|' → '\'). Swapping which 'char' is typed is the only correct
//  path. An optional `secondary` char def is the long-press payload (KB-3).
// ============================================================================

import type { KeyDef, KeyRow } from './keyTypes';
import { XK } from '../../three/useStreamControl';
import { ARROWS, CTRL_LATCH, ALT_LATCH } from './keyboardProfiles';

// Mirrors keyboardProfiles' ch(): a single-glyph 'char' def. id === `ch-<glyph>`
// so the SAME glyph is never rendered twice within one shift state (test-enforced).
const ch = (c: string): KeyDef => ({ id: `ch-${c}`, label: c, action: 'char', char: c });

/** One QWERTY position: the unshifted glyph, its shifted twin, and an optional
 *  long-press payload. `base`/`shifted` are indexed by the 3-state Shift. */
export interface QKey {
  base: KeyDef;
  shifted: KeyDef;
  secondary?: KeyDef;
}
export type QRow = QKey[];

const qk = (base: string, shifted: string, secondary?: string): QKey => ({
  base: ch(base),
  shifted: ch(shifted),
  ...(secondary ? { secondary: ch(secondary) } : {}),
});

// Pair equal-length base/shift strings position-by-position (+ optional
// long-press secondaries). Astral-safe via the spread iterator.
const zip = (bases: string, shifts: string, secondaries = ''): QRow => {
  const b = [...bases];
  const s = [...shifts];
  const x = [...secondaries];
  return b.map((c, i) => qk(c, s[i], x[i]));
};

// ---- the glyph layers -------------------------------------------------------
// Row 1 (10) defines the 10-column grid; digits live only on the ?123 layer
// (SYM_ROWS), not duplicated here. Home (9) and bottom (10, with punctuation)
// rows are naturally shorter/longer and, under the equal-width flex row,
// simply render as slightly narrower/wider keys.

export const ABC_ROWS: QRow[] = [
  zip('qwertyuiop', 'QWERTYUIOP'),
  zip('asdfghjkl', 'ASDFGHJKL'),
  [...zip('zxcvbnm', 'ZXCVBNM'), qk(',', '<'), qk('.', '>'), qk('/', '?')],
];

// ?123 layer: digit row (shift → the number-row symbols) + a common-symbol row
// (shift → the "more symbols" set). Every glyph is asciiToScancode-mappable and
// no glyph repeats within either shift state (test-enforced).
export const SYM_ROWS: QRow[] = [
  zip('1234567890', '!@#$%^&*()'),
  [
    qk('-', '_'), qk('/', '\\'), qk(':', '|'), qk(';', '~'), qk('(', '<'),
    qk(')', '>'), qk('$', '='), qk('&', '{'), qk('@', '}'), qk('"', '`'),
  ],
];

// ---- the shared function + action keys wrapped around the glyph grid --------
// These are NOT char glyphs (Shift is component-managed local state, the rest are
// tap defs), so they live beside the glyph grid, not inside QKey. ids are chosen
// to stay unique within a QWERTY render (no profile rows co-render there).

const tapDef = (id: string, label: string, keysym: number, extra: Partial<KeyDef> = {}): KeyDef =>
  ({ id, label, action: 'tap', keysym, ...extra });

/** Backspace / Enter / Space — reused on every QWERTY layer's bottom rows. */
export const QFUNC = {
  backspace: tapDef('q-bksp', '⌫', XK.BackSpace, { repeat: true }),
  enter: tapDef('q-ret', '⏎', XK.Return),
  space: tapDef('q-space', 'Space', 0x20, { repeat: true, wide: true }),
};

/** Persistent action row for the QWERTY layers: Ctrl · Alt · arrow cluster.
 *  Reuses the EXACT keyboardProfiles defs so one-shot latches wrap the next
 *  glyph across a layer switch (Ctrl here + C on the abc layer → ^C). */
export const ACTION_ROW: KeyRow = [CTRL_LATCH, ALT_LATCH, ...ARROWS];

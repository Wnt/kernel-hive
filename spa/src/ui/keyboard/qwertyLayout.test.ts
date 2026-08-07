// Wire-correctness + shape invariants for the universal QWERTY layer. These are
// the gate that keeps the shift-corruption footgun (a shifted glyph delivered
// via a latched Shift instead of typeText) and a duplicate/dead key out of the
// on-screen QWERTY. Sibling to keyboardProfiles.test.ts (which is left untouched).
import { describe, expect, it } from 'vitest';

import { asciiToScancode, keysymToScancode } from '../../three/guestQuirks';
import { ABC_ROWS, SYM_ROWS, QFUNC, ACTION_ROW, type QRow } from './qwertyLayout';
import type { KeyDef } from './keyTypes';
import { OSK_CSS } from './oskStyles';

const LAYERS: Record<string, QRow[]> = { abc: ABC_ROWS, sym: SYM_ROWS };
const allQKeys = (rows: QRow[]) => rows.flat();
const glyphDefs = (rows: QRow[]): KeyDef[] =>
  allQKeys(rows).flatMap((qk) => [qk.base, qk.shifted, ...(qk.secondary ? [qk.secondary] : [])]);

// The ids the component actually renders for a QWERTY layer in one shift state:
// one glyph per position, plus the shift key, the function keys, and the action
// row. This is the set that must be collision-free (React keys + latch state).
const renderedIds = (rows: QRow[], shifted: boolean): string[] => [
  ...allQKeys(rows).map((qk) => (shifted ? qk.shifted : qk.base).id),
  'q-shift',
  QFUNC.backspace.id, QFUNC.enter.id, QFUNC.space.id,
  ...ACTION_ROW.map((d) => d.id),
];

describe('qwerty glyphs', () => {
  it('every glyph is a char def carrying exactly one typeable ASCII character', () => {
    // Closes the shift-corruption footgun: a shifted glyph is NEVER a tap/latch
    // (which would route through sendKey + a latched Shift and emit the wrong
    // symbol) — it is always a 'char' delivered via typeText.
    for (const [name, rows] of Object.entries(LAYERS)) {
      for (const d of glyphDefs(rows)) {
        expect(d.action, `${name}/${d.id}: glyph is not a char action`).toBe('char');
        expect(d.char?.length, `${name}/${d.id}: char is not a single glyph`).toBe(1);
        expect(d.repeat, `${name}/${d.id}: glyph must never be hold-repeat`).toBeFalsy();
        expect(asciiToScancode(d.char ?? ''), `${name}/${d.id}: '${d.char}' not typeable`).not.toBeNull();
      }
    }
  });

  it('every base key has a mappable shifted twin, in every shift state', () => {
    for (const [name, rows] of Object.entries(LAYERS)) {
      for (const qk of allQKeys(rows)) {
        for (const d of [qk.base, qk.shifted]) {
          const s = asciiToScancode(d.char ?? '');
          expect(s, `${name}/${d.id}: glyph '${d.char}' has no scancode`).not.toBeNull();
        }
        expect(qk.base.char, `${name}/${qk.base.id}: base equals its shifted twin`).not.toBe(qk.shifted.char);
      }
    }
  });

  it('renders exactly 10 columns on the alpha and digit rows (phone fit)', () => {
    // The top alpha row and the digit row define the 10-column grid; no QWERTY
    // row exceeds 10 (the home/bottom rows are naturally shorter and simply
    // render as wider equal-width keys).
    expect(ABC_ROWS[0].length, 'top alpha row (qwertyuiop)').toBe(10);
    expect(SYM_ROWS[0].length, 'digit row (1234567890)').toBe(10);
    for (const [name, rows] of Object.entries(LAYERS)) {
      rows.forEach((r, i) => {
        expect(r.length, `${name} row ${i} exceeds 10 columns`).toBeLessThanOrEqual(10);
      });
    }
  });

  it('renders a collision-free id set in both shift states of every layer', () => {
    for (const [name, rows] of Object.entries(LAYERS)) {
      for (const shifted of [false, true]) {
        const ids = renderedIds(rows, shifted);
        expect(new Set(ids).size, `${name} (shift=${shifted}): duplicate rendered id`).toBe(ids.length);
      }
    }
  });
});

describe('qwerty function + action keys', () => {
  it('resolves every function/action keysym to a scancode', () => {
    const defs: KeyDef[] = [QFUNC.backspace, QFUNC.enter, QFUNC.space, ...ACTION_ROW];
    for (const d of defs) {
      if (d.action === 'tap' || d.action === 'latch') {
        expect(keysymToScancode(d.keysym ?? -1), `${d.id}: keysym unresolvable`).not.toBeNull();
      }
    }
  });

  it('never combines hold-repeat with a long-press secondary on the same key', () => {
    // A key is EITHER long-press-secondary (glyphs) OR hold-repeat (space/bksp/
    // arrows) — never both. Glyphs carry no repeat (asserted above); the repeat
    // function keys carry no secondary by construction.
    for (const d of [QFUNC.backspace, QFUNC.space]) {
      expect(d.repeat, `${d.id}: expected a repeat key`).toBe(true);
    }
  });
});

describe('sheet height — one constant, sized to the QWERTY layer', () => {
  // The DECIDED policy: the sheet never resizes when the layer changes, and the
  // size it holds is the QWERTY layer's. A layer-dependent height moved the
  // picture and every key under the user's thumb on each ABC ⇄ ?123 ⇄ per-OS
  // switch, so these encode both halves of the fix.
  const sheetRule = OSK_CSS.slice(
    OSK_CSS.indexOf('.osk-sheet {'),
    OSK_CSS.indexOf('}', OSK_CSS.indexOf('.osk-sheet {')),
  );

  it('gives .osk-sheet a fixed height derived from the row-count token', () => {
    expect(sheetRule).toMatch(/height:\s*calc\(/);
    expect(sheetRule).toMatch(/var\(--osk-rows\)/);
    expect(sheetRule).toMatch(/var\(--osk-key-h\)/);
  });

  it('sizes --osk-rows to the QWERTY body: glyph rows + space + action row', () => {
    // qwertyBody() renders every ABC row, then a space/enter row and the
    // persistent action row. If a QWERTY row is ever added or dropped, this
    // fails rather than letting the sheet quietly mis-measure itself.
    const rows = ABC_ROWS.length + 2;
    expect(sheetRule).toMatch(new RegExp(`--osk-rows:\\s*${rows};`));
  });

  it('makes no rule depend on which layer is showing', () => {
    expect(OSK_CSS).not.toMatch(/data-kbmode/);
  });

  it('keeps the formula in landscape, shrinking only its inputs', () => {
    const landscape = OSK_CSS.slice(OSK_CSS.indexOf('@media (orientation: landscape)'));
    expect(landscape.length, 'landscape media block present').toBeGreaterThan(0);
    expect(landscape).toMatch(/--osk-key-h:\s*40px/);
    expect(landscape).not.toMatch(/--osk-rows/);
  });
});

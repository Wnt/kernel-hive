// ============================================================================
//  nokia9300/keys — every control of the open Nokia 9300 Communicator
//  ---------------------------------------------------------------------------
//  Geometry: the drawing's viewBox units (1536 × 1024). The keyboard is a
//  13-column grid, as on the device: the application-button row on top, then
//  five key rows, Enter two rows tall, the joystick in its own well at the
//  bottom right. The four command buttons stand in a column right of the
//  display, one per quarter of the screen's height.
//
//  Keysyms: agent K1's keymap contract v3 (every key proven on the station's
//  framebuffer): F1–F4 command buttons, F5–F12 Desk … My own, Menu, F13–F17
//  the joystick centre/up/down/left/right, ISO_Level3_Shift Chr, and each
//  printable key's own base keysym. `keys.test.ts` holds the contract table
//  and checks this file against it both ways.
//
//  Legends: the Nordic (Swedish/Finnish) keyboard of the museum's reference
//  device — Å Ö Ä with Ø Æ, Shift+4 €, the Chr legends in blue — with English
//  application-button names. A char key SENDS the character it shows (see
//  deviceChars.ts), so these legends type as printed whatever keyboard layout
//  the station's firmware is set to.
// ============================================================================

import type { Box, DeviceKey } from '../deviceTypes';

export const VIEW_W = 1536;
export const VIEW_H = 1024;

// The live 640x200 panel (streamed at 2x, 1280x400): 1100x343.75 units, aspect 3.2.
export const SCREEN: Box = { x: 202, y: 100, w: 1100, h: 343.75 };

// Keyboard grid.
const KB_X = 132;
const KB_U = 102;
const APP_Y = 566;
const APP_H = 48;
const KB_Y = 614;
const KB_RH = 70;
const GAP = 0.75;

const cell = (col: number, row: number, cols = 1, rows = 1): Box => ({
  x: KB_X + col * KB_U + (col > 0 ? 4 : 0) + GAP,
  y: KB_Y + row * KB_RH + GAP,
  w: cols * KB_U + (col === 0 ? 4 : 0) - 2 * GAP,
  h: rows * KB_RH - 2 * GAP,
});

// Joystick well (bottom right, rows 4–5 beside Menu).
export const JOY = { cx: 1366, cy: 894, r: 43, knob: 25 };

const XK = {
  Escape: 0xff1b, BackSpace: 0xff08, Tab: 0xff09, Return: 0xff0d,
  Caps_Lock: 0xffe5, Shift_L: 0xffe1, Shift_R: 0xffe2, Control_L: 0xffe3,
  ISO_Level3_Shift: 0xfe03, Menu: 0xff67,
  Left: 0xff51, Up: 0xff52, Right: 0xff53, Down: 0xff54,
};
const F = (n: number): number => 0xffbe + (n - 1);

const APPS: [string, string, string][] = [
  ['app.desk', 'Desk', 'Desk — the home screen of application groups'],
  ['app.tel', 'Telephone', 'Telephone'],
  ['app.msg', 'Messaging', 'Messaging — SMS, e-mail and fax'],
  ['app.web', 'Web', 'Web — the Opera browser'],
  ['app.contacts', 'Contacts', 'Contacts'],
  ['app.docs', 'Documents', 'Documents — the word processor'],
  ['app.cal', 'Calendar', 'Calendar'],
  ['app.own', 'My own', 'My own — the application the owner put on this button'],
];

// Whole-column spans make every application seam continue into the number
// row. Wider spans accommodate Telephone, Messaging, Contacts and Documents.
// The photos' near-equal application widths are approximated to honour this
// exact seam grid; the keyboard's outer bounds and all lower rows stay fixed.
const APP_COLUMNS = [0, 1, 3, 5, 6, 8, 10, 11, 12];
const appKeys: DeviceKey[] = APPS.map(([id, label, hint], i) => ({
  id, kind: 'key', keysym: F(5 + i), label, hint, codes: [`F${5 + i}`],
  box: { ...cell(APP_COLUMNS[i], 0, APP_COLUMNS[i + 1] - APP_COLUMNS[i]), y: APP_Y, h: APP_H },
}));

// Command buttons: one per quarter of the screen height, right of the display.
const CBA_X = 1374;
const CBA_W = 90;
const cbaKeys: DeviceKey[] = [0, 1, 2, 3].map((i) => {
  const h = (SCREEN.h - 3 * 3) / 4;
  return {
    id: `cba${i + 1}`, kind: 'key', keysym: F(i + 1), codes: [`F${i + 1}`],
    hint: `Command button ${i + 1} — does what the application prints beside it on the screen`,
    outline: i === 0
      ? `M3 0Q48 0 81 9Q87 10 87 17L90 ${h - 3}Q90 ${h} 87 ${h}H3Q0 ${h} 0 ${h - 3}V3Q0 0 3 0Z`
      : i === 3
        ? `M3 0H87Q90 0 90 3L87 ${h - 17}Q87 ${h - 10} 81 ${h - 9}Q48 ${h} 3 ${h}Q0 ${h} 0 ${h - 3}V3Q0 0 3 0Z`
        : undefined,
    box: { x: CBA_X, y: SCREEN.y + i * (h + 3), w: CBA_W, h },
  };
});

// A char key: base (sent) + printed capital, Shift, Chr legends.
const ch = (
  id: string, col: number, row: number, base: string,
  extra: Partial<DeviceKey> = {},
): DeviceKey => ({
  id, kind: 'char', keysym: base.charCodeAt(0), base, box: cell(col, row), hint: base, ...extra,
});
const letter = (c: string, col: number, row: number, extra: Partial<DeviceKey> = {}): DeviceKey =>
  ch(c, col, row, c, {
    shownBase: c.toUpperCase(), shift: c.toUpperCase(), hint: c.toUpperCase(),
    codes: [`Key${c.toUpperCase()}`], ...extra,
  });

// Digit row: base, Shift (upper right), Chr (blue) — the Nordic legends.
const DIGITS: [string, string, string][] = [
  ['1', '!', "'"], ['2', '"', '@'], ['3', '#', '£'], ['4', '€', '$'], ['5', '%', '<'],
  ['6', '&', '>'], ['7', '/', '{'], ['8', '(', '['], ['9', ')', ']'], ['0', '=', '}'],
];
const digitKeys: DeviceKey[] = DIGITS.map(([d, s, c], i) =>
  ch(`k${d}`, i + 1, 0, d, { shift: s, chr: c, hint: `${d}  ${s}  ${c}`, codes: [`Digit${d}`] }));

const key = (id: string, keysym: number, box: Box, extra: Partial<DeviceKey> & { hint: string }): DeviceKey =>
  ({ id, kind: 'key', keysym, box, ...extra });

const row1: DeviceKey[] = [
  key('esc', XK.Escape, cell(0, 0), { label: 'Esc', hint: 'Esc — cancel or close', codes: ['Escape'] }),
  ...digitKeys,
  // The '+' key: the Equals scan code; Chr on it is Sync.
  ch('eq', 11, 0, '+', {
    keysym: 0x3d, shift: '?', chrGlyph: 'sync', hint: '+  ?  (Chr: Sync)', codes: ['Equal'],
  }),
  key('bksp', XK.BackSpace, cell(12, 0), {
    glyph: 'backspace', hint: 'Backspace (Shift+Backspace deletes to the right)', codes: ['Backspace'],
  }),
];

const row2: DeviceKey[] = [
  key('tab', XK.Tab, cell(0, 1), { glyph: 'tab', hint: 'Tab (Chr+Tab switches tasks)', codes: ['Tab'] }),
  ...'qwertyuiop'.split('').map((c, i) =>
    letter(c, i + 1, 1, c === 'p' ? { chr: '~', hint: 'P  (Chr: ~)' } : {})),
  // Å sits on the Hash scan code.
  ch('hash', 11, 1, 'å', {
    keysym: 0x23, shownBase: 'Å', shift: 'Å', chr: '*', hint: 'Å  (Chr: *)', codes: ['BracketLeft'],
  }),
  key('enter', XK.Return, cell(12, 1, 1, 2), { glyph: 'enter', hint: 'Enter', codes: ['Enter', 'NumpadEnter'] }),
];

const row3: DeviceKey[] = [
  key('caps', XK.Caps_Lock, cell(0, 2), { label: 'Caps', hint: 'Caps lock', codes: ['CapsLock'] }),
  ...'asdfghjkl'.split('').map((c, i) => letter(c, i + 1, 2)),
  // Ö on the SemiColon scan code, Ä on SingleQuote; Ø and Æ are their Chr legends.
  ch('semi', 10, 2, 'ö', {
    keysym: 0x3b, shownBase: 'Ö', shift: 'Ö', chr: 'ø', chrShift: 'Ø', hint: 'Ö  (Chr: Ø)', codes: ['Semicolon'],
  }),
  ch('quote', 11, 2, 'ä', {
    keysym: 0x27, shownBase: 'Ä', shift: 'Ä', chr: 'æ', chrShift: 'Æ', hint: 'Ä  (Chr: Æ)', codes: ['Quote'],
  }),
];

const row4: DeviceKey[] = [
  key('shift.l', XK.Shift_L, cell(0, 3), { kind: 'mod', glyph: 'shift', hint: 'Shift', codes: ['ShiftLeft'] }),
  ...'zxcvbnm'.split('').map((c, i) => letter(c, i + 1, 3)),
  key('up', XK.Up, cell(8, 3), { glyph: 'up', chrGlyph: 'zoomIn', hint: 'Up (Chr: zoom in)', codes: ['ArrowUp'] }),
  // The '-' key is the ForwardSlash scan code; Chr on it is '\'.
  ch('slash', 9, 3, '-', { keysym: 0x2f, shift: '_', chr: '\\', hint: '-  _  \\', codes: ['Slash', 'Minus'] }),
  key('shift.r', XK.Shift_R, cell(10, 3), { kind: 'mod', glyph: 'shift', hint: 'Shift', codes: ['ShiftRight'] }),
];

const row5: DeviceKey[] = [
  key('ctrl', XK.Control_L, cell(0, 4), { kind: 'mod', label: 'Ctrl', hint: 'Ctrl', codes: ['ControlLeft', 'ControlRight'] }),
  key('chr', XK.ISO_Level3_Shift, cell(1, 4), {
    kind: 'mod', label: 'Chr', chrColour: true, codes: ['AltRight', 'AltLeft'],
    hint: 'Chr — the blue legends; hold it alone for the character map',
  }),
  ch('comma', 2, 4, ',', { shift: ';', hint: ',  ;', codes: ['Comma'] }),
  ch('period', 3, 4, '.', { shift: ':', chrGlyph: 'help', hint: '.  :  (Chr: Help)', codes: ['Period'] }),
  key('space', 0x20, cell(4, 4, 3), { chrGlyph: 'brightness', hint: 'Space (Chr: brightness)', codes: ['Space'] }),
  key('left', XK.Left, cell(7, 4), { glyph: 'left', chrGlyph: 'bluetooth', hint: 'Left (Chr: Bluetooth)', codes: ['ArrowLeft'] }),
  key('down', XK.Down, cell(8, 4), { glyph: 'down', chrGlyph: 'zoomOut', hint: 'Down (Chr: zoom out)', codes: ['ArrowDown'] }),
  key('right', XK.Right, cell(9, 4), { glyph: 'right', chrGlyph: 'infrared', hint: 'Right (Chr: infrared)', codes: ['ArrowRight'] }),
  key('menu', XK.Menu, cell(10, 4), { label: 'Menu', hint: 'Menu — the application\'s menu bar', codes: ['ContextMenu'] }),
];

// Joystick: centre press + four directions, drawn by the outline's well.
const J = JOY;
const joyKeys: DeviceKey[] = [
  key('joy.u', F(14), { x: J.cx - J.knob, y: J.cy - J.r - 8, w: 2 * J.knob, h: J.r - J.knob + 8 },
    { cap: 'none', glyph: 'up', hint: 'Joystick up (Chr: page up)' }),
  key('joy.d', F(15), { x: J.cx - J.knob, y: J.cy + J.knob, w: 2 * J.knob, h: J.r - J.knob + 8 },
    { cap: 'none', glyph: 'down', hint: 'Joystick down (Chr: page down)' }),
  key('joy.l', F(16), { x: J.cx - J.r - 8, y: J.cy - J.knob, w: J.r - J.knob + 8, h: 2 * J.knob },
    { cap: 'none', glyph: 'left', hint: 'Joystick left (Chr: home)' }),
  key('joy.r', F(17), { x: J.cx + J.knob, y: J.cy - J.knob, w: J.r - J.knob + 8, h: 2 * J.knob },
    { cap: 'none', glyph: 'right', hint: 'Joystick right (Chr: end)' }),
  key('joy.c', F(13), { x: J.cx - J.knob, y: J.cy - J.knob, w: 2 * J.knob, h: 2 * J.knob },
    { cap: 'none', hint: 'Joystick press — select' }),
];

export const NOKIA9300_KEYS: DeviceKey[] = [
  ...cbaKeys, ...appKeys, ...row1, ...row2, ...row3, ...row4, ...row5, ...joyKeys,
];

export const NOKIA9300_MODS = {
  'shift.l': 'shift', 'shift.r': 'shift', ctrl: 'ctrl', chr: 'chr',
} as const;

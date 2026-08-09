// ============================================================================
//  keyboardProfiles — per-OS-family special-key layouts for the shared OSK
//  ---------------------------------------------------------------------------
//  Every production streamhost osId maps EXPLICITLY to a family (test-enforced
//  against the generated registry); unknown ids fall back to `generic`, same
//  pattern as guestQuirks.quirksFor.
//
//  Wire rules (see keyTypes.ts + keyboardProfiles.test.ts): every tap/latch/
//  macro keysym here must resolve through guestQuirks.keysymToScancode TODAY,
//  and printable-range keysyms must be unshifted. Keys whose end-to-end guest
//  mapping is unverified are DELIBERATELY absent until their lab-box task
//  passes (a dead key is silent through the whole pipeline):
//    - T1 amiga:  Help + Ctrl+A◀+A▶ reset (host-binding candidates unverified)
//    - T2 solaris: real Sun L-group (Stop/Front/Copy/Paste/Cut/Find/Help via
//      new KEYSYM_TO_SCANCODE rows: XK_Cancel 0xff69→0xE068, XK_Undo 0xff65→
//      0xE007, SunFront 0x1005ff72→0xE00C, SunCopy 0x1005ff73→0xE078,
//      SunPaste 0x1005ff75→0x65, SunCut 0x1005ff76→0xE03C, XK_Find 0xff68→
//      0xE041, XK_Help 0xff6a→0xE075) — until then suncde ships CDE-safe
//      Ctrl-combo equivalents (v1);
//    - T3 atarist: Help (XK_Print 0xff61→0xE037 candidate — needs the new
//      KEYSYM_TO_SCANCODE row; the running hatari 2.4.1's own manual documents
//      Print Screen → ST HELP, so only the client row is missing). Undo is
//      VERIFIED 2026-07-17 on the live tile: the running hatari 2.4.1 (ps-
//      checked invocation, no --keymap / no hatari.cfg override) documents
//      Scroll Lock → ST UNDO, and an evdev capture on the tile confirmed the
//      OSK's scancode 0x46 arrives as KEY_SCROLLLOCK on the input device
//      hatari reads;
//    - T4 android: RESOLVED for Home 2026-07-17 (live-tile framebuffer test:
//      KEY_HOME 0xE047 is MOVE_HOME — did NOT leave the search activity;
//      KEY_HOMEPAGE via scancode 0xE032 navigated to the launcher → shipped
//      as XF86HomePage). Back(Esc)/Menu keep their defensible mappings; note
//      Esc did not visibly back out of a focused search field, and qcode
//      ac_back (0xE06A → KEY_BACK) is the candidate if Back misbehaves.
// ============================================================================

import type { KeyAction, KeyDef, KeyRow, KeyboardProfile, MacroStep } from './keyTypes';
import { XK } from '../../three/useStreamControl';

export type Family =
  | 'generic' | 'linux-tty' | 'windows' | 'win3x' | 'dos' | 'os2'
  | 'suncde' | 'plan9' | 'android' | 'c64' | 'plus4' | 'c128'
  | 'pet' | 'petbusiness' | 'appleii' | 'atarist' | 'amiga'
  | 'zxspectrum' | 'zx81' | 'dragon' | 'kc854' | 'sinclairql';

// ---- row builders ---------------------------------------------------------

const key = (id: string, label: string, action: KeyAction, extra: Partial<KeyDef> = {}): KeyDef =>
  ({ id, label, action, ...extra });
const tap = (id: string, label: string, keysym: number, extra: Partial<KeyDef> = {}): KeyDef =>
  key(id, label, 'tap', { keysym, ...extra });
const latch = (id: string, label: string, keysym: number, hint?: string): KeyDef =>
  key(id, label, 'latch', { keysym, hint });
const ch = (c: string): KeyDef => key(`ch-${c}`, c, 'char', { char: c });
const macro = (id: string, label: string, steps: MacroStep[], extra: Partial<KeyDef> = {}): KeyDef =>
  key(id, label, 'macro', { steps, ...extra });

const dn = (keysym: number): MacroStep => ({ keysym, down: true });
const up = (keysym: number): MacroStep => ({ keysym, down: false });
const press = (keysym: number): MacroStep[] => [dn(keysym), up(keysym)];

// XF86HomePage — resolves to scancode 0xE032 (KEY_HOMEPAGE in a Linux guest),
// the key Android's Generic.kl binds to launcher HOME. Lab-verified 2026-07-17
// on the live android tile (KEY_HOME 0xE047 is MOVE_HOME there — wrong key).
const XF86_HOMEPAGE = 0x1008ff18;

// The XK table has NO F-key constants — F-keys are numeric XK_F1 + n − 1.
const F = (n: number): number => 0xffbe + (n - 1);
const fkeyRow = (from: number, to: number): KeyRow => {
  const row: KeyRow = [];
  for (let n = from; n <= to; n++) row.push(tap(`f${n}`, `F${n}`, F(n)));
  return row;
};

/** C= held across a C — the Plus/4 suite's "open the command prompt" chord. */
const CBM_C: MacroStep[] = [dn(XK.Tab), ...press(0x63), up(XK.Tab)];

/** ZX Spectrum SYMBOL SHIFT (host right shift) held across one unshifted key. */
const sym = (id: string, label: string, c: string): KeyDef =>
  macro(id, label, [dn(XK.Shift_R), ...press(c.charCodeAt(0)), up(XK.Shift_R)],
    { hint: `SYMBOL SHIFT + ${c.toUpperCase()}` });
/** ZX Spectrum CAPS SHIFT (host left shift) held across one unshifted key. */
const caps = (id: string, label: string, c: string): KeyDef =>
  macro(id, label, [dn(XK.Shift_L), ...press(c.charCodeAt(0)), up(XK.Shift_L)],
    { hint: `CAPS SHIFT + ${c.toUpperCase()}` });

/** mod↓ · key↓↑ · mod↑ */
const chord = (id: string, label: string, mod: number, keysym: number, hint?: string): KeyDef =>
  macro(id, label, [dn(mod), ...press(keysym), up(mod)], { hint });
/** Ctrl + lowercase letter (keysym = code point, unshifted — test-enforced). */
const ctrlChar = (id: string, label: string, c: string, hint?: string): KeyDef =>
  chord(id, label, XK.Control_L, c.charCodeAt(0), hint);

// ---- shared rows ----------------------------------------------------------
// Repeat set is EXACTLY arrows / ⌫ / Space (Delete is deliberately non-repeat
// and appears in no row).

// Exported so the shared QWERTY action row (qwertyLayout.ts) reuses the EXACT
// same defs — same keysyms, same repeat semantics, and same latch ids so a Ctrl
// latched on the QWERTY action row lights (and one-shot-wraps) identically to
// the per-OS profiles' Ctrl. Exporting them adds NOTHING to PROFILES, so the
// profile invariants (keyboardProfiles.test.ts iterates Object.values(PROFILES))
// are untouched.
export const ARROWS: KeyRow = [
  tap('up', '↑', XK.Up, { repeat: true }),
  tap('down', '↓', XK.Down, { repeat: true }),
  tap('left', '←', XK.Left, { repeat: true }),
  tap('right', '→', XK.Right, { repeat: true }),
];

// Ctrl+Alt+Del. THE ONLY WAY TO SEND IT — the stream toolbar's button is gone,
// so this key is the whole affordance, which is why it rides a BASE row (never
// moreRows, which landscape hides) in every profile that has one to put it on:
// it joins the shared MODS row below, plus the head of the dos F-key row. That
// covers every PC-style guest. The home-computer profiles (c64, appleii,
// atarist, amiga, android) and plan9 build their own rows and get none — those
// keyboards have no such combination to send. Single-tap: on DOS this reboots
// the guest.
const CAD = macro(
  'cad', 'Ctrl-Alt-Del',
  [dn(XK.Control_L), dn(XK.Alt_L), ...press(XK.Delete), up(XK.Alt_L), up(XK.Control_L)],
  { hint: 'Ctrl+Alt+Del' },
);

const NAV: KeyRow = [
  tap('esc', 'Esc', XK.Escape),
  tap('tab', 'Tab', XK.Tab),
  tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
  tap('ret', '⏎', XK.Return),
  tap('space', 'Space', 0x20, { repeat: true, wide: true }),
  ...ARROWS,
];

export const CTRL_LATCH = latch('ctrl', 'Ctrl', XK.Control_L);
export const ALT_LATCH = latch('alt', 'Alt', XK.Alt_L);

// … and onto the modifier row, where it reads as what it is and — unlike the
// tail of the NAV row — needs no horizontal scroll to reach on a phone.
const MODS: KeyRow = [latch('shift', 'Shift', XK.Shift_L), CTRL_LATCH, ALT_LATCH, CAD];

const ALT_TAB = chord('alt-tab', 'Alt+Tab', XK.Alt_L, XK.Tab, 'Switch task');
const ALT_F4 = chord('alt-f4', 'Alt+F4', XK.Alt_L, F(4), 'Close window');
const ctrlEsc = (hint: string): KeyDef => chord('ctrl-esc', 'Ctrl+Esc', XK.Control_L, XK.Escape, hint);

// ---- the profiles ---------------------------------------------------------

export const PROFILES: Record<Family, KeyboardProfile> = {
  generic: { family: 'generic', rows: [NAV, MODS], moreRows: [fkeyRow(1, 12)] },

  'linux-tty': {
    family: 'linux-tty',
    rows: [NAV, MODS],
    moreRows: [
      [
        ctrlChar('ctrl-c', '^C', 'c', 'Interrupt'),
        ctrlChar('ctrl-d', '^D', 'd', 'EOF / logout'),
        ctrlChar('ctrl-z', '^Z', 'z', 'Suspend'),
        ch('|'), ch('-'), ch('/'),
      ],
      fkeyRow(1, 12),
    ],
  },

  windows: {
    family: 'windows',
    rows: [NAV, [...MODS, tap('win', 'Win', XK.Super_L, { hint: 'Windows key' }), tap('menu', 'Menu', XK.Menu)]],
    moreRows: [[ALT_TAB, ALT_F4, ctrlEsc('Start menu')], fkeyRow(1, 12)],
  },

  // Windows 3.11 — no Win/Menu key existed; Ctrl+Esc opens the Task List.
  win3x: {
    family: 'win3x',
    rows: [NAV, MODS],
    moreRows: [[ctrlEsc('Task List'), ALT_TAB, ALT_F4], fkeyRow(1, 12)],
  },

  dos: {
    family: 'dos',
    // No modifier row in the base rows here, so C-A-D leads the F-key row (and
    // MODS in moreRows drops it, or the id would collide within the profile).
    rows: [NAV, [CAD, ...fkeyRow(1, 10)]],
    moreRows: [MODS.filter((d) => d.id !== 'cad'), fkeyRow(11, 12)],
  },

  os2: {
    family: 'os2',
    rows: [NAV, MODS],
    moreRows: [
      // Alt+F10 is the CUA MAXIMIZE shortcut (Alt+F4 close … Alt+F9 minimize,
      // Alt+F10 maximize) — label it as what it does. The system menu is
      // Alt+Space; ship it only after a live-tile verification pass.
      [ctrlEsc('Window List'), ALT_F4, chord('alt-f10', 'Maximize', XK.Alt_L, F(10), 'Alt+F10 — maximize window')],
      fkeyRow(1, 12),
    ],
  },

  // v1: verified-safe CDE equivalents; flips to the real Sun L-group after T2.
  suncde: {
    family: 'suncde',
    rows: [NAV, MODS],
    moreRows: [
      [
        tap('help', 'Help', F(1), { hint: 'CDE Help (F1)' }),
        ctrlChar('copy', 'Copy', 'c'),
        ctrlChar('cut', 'Cut', 'x'),
        ctrlChar('paste', 'Paste', 'v'),
        ctrlChar('undo', 'Undo', 'z'),
      ],
      fkeyRow(1, 12),
    ],
  },

  // rio is mouse-chord driven; chord buttons are pointer-domain, out of scope.
  plan9: { family: 'plan9', rows: [NAV] },

  android: {
    family: 'android',
    rows: [
      [
        tap('back', 'Back', XK.Escape, { hint: 'Back (Esc)' }),
        tap('home', 'Home', XF86_HOMEPAGE, { hint: 'Home — go to launcher' }),
        tap('menu', 'Menu', XK.Menu),
        tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
        tap('ret', '⏎', XK.Return),
      ],
      ARROWS,
    ],
  },

  c64: {
    family: 'c64',
    rows: [[
      tap('runstop', 'RUN/STOP', XK.Escape, { hint: 'RUN/STOP (VICE: Esc)' }),
      tap('restore', 'RESTORE', XK.Prior, { hint: 'RESTORE (VICE: PageUp)' }),
      tap('cbm', 'C=', XK.Tab, { hint: 'Commodore key (VICE: Tab)' }),
      latch('ctrl', 'Ctrl', XK.Control_L),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [fkeyRow(1, 8)],
  },

  // Plus/4: the c64 row plus the thing this machine is actually FOR — its four
  // applications in ROM. THE ORDER OF THESE BUTTONS IS THE ORDER A VISITOR USES
  // THEM. The tile rests on the machine's power-on screen, which prints
  // "3-PLUS-1 ON KEY F1", so the first button does exactly that; the next three
  // switch module once the suite is up.
  //
  // Each of those three has to open the suite's command prompt first, and that
  // needs the Commodore key — which does not exist on a Mac, a PC or a phone
  // (it is Tab under VICE's symbolic keymap, which nobody would guess). So the
  // whole documented sequence rides in one macro: C= + C, then "to Word" / "to
  // Calculator" / "to File manager", then RETURN. The sequences are the ones
  // scripts/build-guests/plus4.sh proves against the live guest on every build.
  plus4: {
    family: 'plus4',
    rows: [[
      macro('suite', '3-PLUS-1', [...press(F(1)), ...press(XK.Return)],
        { hint: 'F1 then RETURN — what the power-on screen tells you to press' }),
      macro('to-word', 'Word', [...CBM_C, ...press(0x74), ...press(0x77), ...press(XK.Return)],
        { hint: 'C= C then tw — the ROM word processor' }),
      macro('to-calc', 'Calc', [...CBM_C, ...press(0x74), ...press(0x63), ...press(XK.Return)],
        { hint: 'C= C then tc — the ROM spreadsheet' }),
      macro('to-file', 'File', [...CBM_C, ...press(0x74), ...press(0x66), ...press(XK.Return)],
        { hint: 'C= C then tf — the ROM file manager' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [[
      tap('cbm', 'C=', XK.Tab, { hint: 'Commodore key (VICE: Tab)' }),
      tap('runstop', 'RUN/STOP', XK.Escape, { hint: 'RUN/STOP (VICE: Esc)' }),
      tap('restore', 'RESTORE', XK.Prior, { hint: 'RESTORE (VICE: PageUp)' }),
      latch('ctrl', 'Ctrl', XK.Control_L),
    ], fkeyRow(1, 8)],
  },

  // C128: the c64 keys (Commodore reused the keyboard) plus the one thing no
  // other tile in the lineup can do. The fixture is the machine's untouched
  // 80-column BASIC 7.0 power-on screen with the CP/M 3.0 system disk already
  // in drive 8, so its second CPU is exactly one BASIC keyword away — but only
  // if you know the keyword, which is why it is a button. The load is slow
  // (CP/M Plus comes in through an emulated 1541) and the screen narrates it,
  // so the hint says so rather than letting it read as a hang.
  //
  // THERE IS DELIBERATELY NO C64 BUTTON. GO64 works and freezes the picture:
  // C64 mode paints the VIC-II while the visible canvas is the VDC. Measured
  // 2026-08-09 — two byte-identical frames 10 s apart, against a control pair
  // that differs as the cursor blinks — and re-measured by
  // scripts/build-guests/c128.sh on every build.
  c128: {
    family: 'c128',
    rows: [[
      macro('boot-cpm', 'CP/M',
        [...press(0x62), ...press(0x6f), ...press(0x6f), ...press(0x74), ...press(XK.Return)],
        { hint: 'BOOT — starts CP/M 3.0 on the Z80; the load takes about a minute' }),
      tap('runstop', 'RUN/STOP', XK.Escape, { hint: 'RUN/STOP (VICE: Esc)' }),
      tap('cbm', 'C=', XK.Tab, { hint: 'Commodore key (VICE: Tab)' }),
      latch('ctrl', 'Ctrl', XK.Control_L),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    // HELP and 40/80 DISPLAY are absent on purpose: neither has a verified
    // end-to-end scancode path on this tile yet, and a dead key is silent
    // through the whole pipeline.
    moreRows: [[
      tap('restore', 'RESTORE', XK.Prior, { hint: 'RESTORE (VICE: PageUp)' }),
    ], fkeyRow(1, 8)],
  },

  // PET 2001 — the 1977 chiclet machine. NOT the c64 profile: no Commodore key,
  // no RESTORE, no function keys. RUN/STOP is the key that matters, because the
  // exhibit's type-in demo is an infinite loop and without it a visitor who runs
  // the demo can only get back to READY. by resetting the tile. Verified on the
  // live tile: Esc gave "BREAK IN 30 / READY.".
  //
  // Backspace is DELIBERATELY ABSENT: it does not reach the PET's INST/DEL under
  // VICE's graphics-keyboard symbolic keymap ("PRINT 1234" survived two presses
  // unchanged), and a dead key is silent through the whole pipeline.
  pet: {
    family: 'pet',
    rows: [[
      tap('runstop', 'RUN/STOP', XK.Escape,
        { hint: 'RUN/STOP — stops a running program (VICE: Esc)' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
  },

  // CBM 8032 — the business PET, and a SEPARATE family from the 2001 above even
  // though both are PETs. VICE selects its keymap from the model's kbd_type, and
  // -model 8032 is KBD_TYPE_BUSINESS_UK: a different physical keyboard with keys
  // the chiclet machine does not have. These five are read from that keymap
  // (sdl_buuk_sym.vkm in the guest's own /usr/local/share/vice/PET/). No F-key
  // row: the business keyboard has no function keys, and the keymap spends host
  // F1/F2 on the machine's own ESC and RVS OFF instead.
  petbusiness: {
    family: 'petbusiness',
    rows: [[
      tap('runstop', 'RUN/STOP', XK.Escape, { hint: 'RUN/STOP (VICE: Esc)' }),
      tap('pet-esc', 'ESC', F(1), { hint: "the business keyboard's own ESC (VICE: F1)" }),
      tap('clrhome', 'CLR/HOME', XK.Home, { hint: 'CLR/HOME (VICE: Home)' }),
      tap('rvsoff', 'RVS OFF', XK.Prior, { hint: 'Reverse off (VICE: PageUp)' }),
      tap('rpt', 'RPT', XK.Next, { hint: 'RPT — key repeat (VICE: PageDown)' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
  },

  // Sinclair ZX81. The ZX81's 40-key membrane has no Esc, no Backspace, no
  // cursor keys and no punctuation of its own: everything beyond the letters
  // and the one-key BASIC keywords is SHIFT plus another key, and the words are
  // printed above the keys rather than anywhere a modern visitor would look.
  // MAME passes host SHIFT straight through to the emulated SHIFT, so each of
  // these is an honest chord and not a gallery invention.
  //
  // EVERY ROW HERE WAS PROVED ON THE LIVE FRAMEBUFFER (clone of the tile,
  // 2026-08-09): RUBOUT deleted the whole PRINT token and the cursor returned
  // to `K`; FUNCTION changed the cursor glyph from `K` to `F`; BREAK visibly
  // changed the screen at rest. NEWLINE is proved by the builder's own
  // keyboard proof.
  //
  // WHAT IS DELIBERATELY ABSENT, and why: the ZX81's cursor keys (SHIFT+5/6/7/8)
  // and EDIT (SHIFT+1). Not because they are believed broken — because they
  // could not be POSITIVELY verified. The ZX81 draws its cursor as an inverse
  // block sitting BETWEEN characters, so moving it left shifts the rest of the
  // line right by one cell and leaves the frame's total ink identical; the
  // framebuffer proof could not tell "moved" from "ignored", and a key that
  // might be dead does not go on the exhibit. Plain arrow keys are absent for
  // a different and firmer reason: the ZX81 has no such keys at all, so they
  // would be four buttons that cannot work.
  zx81: {
    family: 'zx81',
    rows: [[
      latch('shift', 'SHIFT', XK.Shift_L, 'SHIFT — the red symbol on each key'),
      tap('newline', 'NEWLINE', XK.Return, { hint: 'NEWLINE — the ZX81 has no Enter key' }),
      macro('rubout', 'RUBOUT', [dn(XK.Shift_L), ...press(0x30), up(XK.Shift_L)],
        { hint: 'SHIFT+0 — the only way to delete; a keyword goes whole' }),
      macro('zx-function', 'FUNCTION', [dn(XK.Shift_L), ...press(XK.Return), up(XK.Shift_L)],
        { hint: 'SHIFT+NEWLINE — then a key gives the word printed BELOW it' }),
      macro('break', 'BREAK', [dn(XK.Shift_L), ...press(0x20), up(XK.Shift_L)],
        { hint: 'SHIFT+SPACE — stops a running program' }),
    ]],
  },

  // Dragon 32. Microsoft Extended Color BASIC and nothing else, so there is no
  // shell to profile — but the machine has two keys a PC keyboard does not
  // label, and both are things a visitor will want. BREAK stops a running
  // program (the Dragon's equivalent of Ctrl+C) and CLEAR wipes the screen;
  // MAME's dragon32 matrix binds them to Esc and Home, which is what these two
  // buttons send. The arrows are the Dragon's own cursor keys.
  dragon: {
    family: 'dragon',
    rows: [[
      tap('break', 'Break', XK.Escape, { hint: 'BREAK — stops a running BASIC program' }),
      tap('clear', 'Clear', XK.Home, { hint: 'CLEAR — clears the screen' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
  },


  // KC 85/4 — a GERMAN keyboard with an East German operating system, and the
  // only exhibit here where the on-screen keyboard has to apologise for the
  // host's layout rather than just add a missing modifier.
  //
  // Base row: the two words CAOS itself is offering on the screen the tile rests
  // at. Every letter is sent UNSHIFTED on purpose — this machine's unshifted
  // letter row is UPPER case and shift gives lower case, which is the opposite
  // of every later convention (MAME's src/mame/ddr/kc_keyb.cpp declares
  // PORT_CHAR('B') PORT_CHAR('b'), in that order, for all 26). A visitor who
  // types basic in lower case gets BASIC, and one who "helpfully" holds shift
  // gets basic and an error.
  //
  // The named keys are the KC's own, read from the same matrix: Brk is Esc,
  // Stop is End, Clr is Backspace, and Shift Lock is Caps Lock.
  //
  // The symbol row is the German layout made reachable. Six of these characters
  // sit on keys a US keyboard puts something else on, so the label is what the
  // KC prints and the keysym is the host key that gets you there — ':' really
  // is the '-' key, '+' really is the ';' key. The registry's keyboard.charMap
  // does the same translation for typed text; these buttons are for the visitor
  // hunting one character on a phone. '^' (host '[') is included because CAOS
  // uses it and no visitor would ever find it.
  kc854: {
    family: 'kc854',
    rows: [[
      macro('caos-basic', 'BASIC',
        [...press(0x62), ...press(0x61), ...press(0x73), ...press(0x69), ...press(0x63),
          ...press(XK.Return)],
        { hint: 'BASIC — starts HC-BASIC from ROM (typed unshifted: this machine’s plain letters are CAPITALS)' }),
      macro('caos-menu', 'MENU',
        [...press(0x6d), ...press(0x65), ...press(0x6e), ...press(0x75), ...press(XK.Return)],
        { hint: 'MENU — brings back the CAOS command list' }),
      tap('brk', 'Brk', XK.Escape, { hint: 'BRK (the KC’s break key)' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [[
      tap('clr', 'Clr', XK.BackSpace, { repeat: true, hint: 'CLR' }),
      tap('ins', 'Ins', XK.Insert),
      tap('del', 'Del', XK.Delete),
      tap('stop', 'Stop', XK.End, { hint: 'STOP' }),
      latch('shiftlock', 'Shift Lock', XK.Caps_Lock, 'SHIFT LOCK — and remember shift gives LOWER case here'),
    ], [
      tap('kc-plus', '+', 0x3b, { hint: 'German layout: the host ; key' }),
      tap('kc-colon', ':', 0x2d, { hint: 'German layout: the host - key' }),
      tap('kc-minus', '-', 0x3d, { hint: 'German layout: the host = key' }),
      tap('kc-caret', '^', 0x5b, { hint: 'German layout: the host [ key' }),
      chord('kc-star', '*', XK.Shift_L, 0x2d, 'Shift + the host - key'),
      chord('kc-equal', '=', XK.Shift_L, 0x3d, 'Shift + the host = key'),
      chord('kc-quote', '"', XK.Shift_L, 0x32, 'Shift + 2'),
      chord('kc-at', '@', XK.Shift_L, 0x30, 'Shift + 0'),
      chord('kc-apos', '\'', XK.Shift_L, 0x37, 'Shift + 7'),
      chord('kc-amp', '&', XK.Shift_L, 0x36, 'Shift + 6'),
    ], fkeyRow(1, 6)],
  },

  // Sinclair QL. The fixture is the machine's own idle SuperBASIC screen, which
  // says nothing and offers nothing — the QL does not even print READY — so the
  // affordances have to come from here. All three macros are SuperBASIC lines
  // the machine answers immediately and visibly:
  //   MODE 8  the 256-pixel-wide eight-colour mode the QL used on a television
  //   MODE 4  back to the 512-pixel four-colour mode this exhibit rests in
  //   CLS     clears the command window, which is the only way to tidy up
  // F1..F5 are the QL's own function keys: F1/F2 are what the machine asks for
  // at power-on (monitor or TV — already answered in the golden), and QL
  // software of the period hangs its menus off all five.
  sinclairql: {
    family: 'sinclairql',
    rows: [[
      macro('mode8', 'MODE 8', [...press(0x6d), ...press(0x6f), ...press(0x64), ...press(0x65),
        ...press(0x20), ...press(0x38), ...press(XK.Return)],
      { hint: 'MODE 8 — the QL’s eight-colour television mode' }),
      macro('mode4', 'MODE 4', [...press(0x6d), ...press(0x6f), ...press(0x64), ...press(0x65),
        ...press(0x20), ...press(0x34), ...press(XK.Return)],
      { hint: 'MODE 4 — back to 512-pixel monitor mode' }),
      macro('cls', 'CLS', [...press(0x63), ...press(0x6c), ...press(0x73), ...press(XK.Return)],
        { hint: 'CLS — clear the command window' }),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [[
      chord('break', 'Break', XK.Control_L, 0x20,
        'CTRL+SPACE — the QL’s BREAK, stops a running program'),
      tap('esc', 'Esc', XK.Escape),
    ], fkeyRow(1, 5)],
  },

  appleii: {
    family: 'appleii',
    rows: [[
      latch('open-apple', '⌘open', XK.Alt_L, 'Open Apple (LinApple: Left Alt)'),
      latch('closed-apple', '⌘closed', XK.Alt_R, 'Closed Apple (LinApple: Right Alt)'),
      latch('ctrl', 'Ctrl', XK.Control_L),
      tap('esc', 'Esc', XK.Escape),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [[
      macro('reset', 'Reset', [dn(XK.Control_L), ...press(F(2)), up(XK.Control_L)],
        { danger: true, hint: 'Ctrl+Reset — cold-reboots the //e; tap twice to confirm' }),
    ]],
  },

  atarist: {
    family: 'atarist',
    rows: [[
      tap('esc', 'Esc', XK.Escape),
      tap('undo', 'Undo', XK.Scroll_Lock, { hint: 'Undo (hatari: Scroll Lock)' }),
      latch('ctrl', 'Ctrl', XK.Control_L),
      latch('alt', 'Alt', XK.Alt_L),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    // Help ships only after T3 verifies a working scancode path.
    moreRows: [fkeyRow(1, 10)],
  },

  // amiga + aros. F1..F10 ONLY — FS-UAE reserves F11/F12 for fullscreen/menu
  // (test-enforced). Help + Ctrl+A◀+A▶ reset ship only after T1.
  amiga: {
    family: 'amiga',
    rows: [[
      latch('amiga-l', 'A◀', XK.Super_L, 'Left Amiga (Super)'),
      latch('amiga-r', 'A▶', XK.Super_R, 'Right Amiga (Super-R)'),
      latch('ctrl', 'Ctrl', XK.Control_L),
      tap('esc', 'Esc', XK.Escape),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [fkeyRow(1, 10)],
  },

  // ZX Spectrum 48K — the profile that carries the most weight in this file,
  // because the machine's 40-key matrix HAS NO PUNCTUATION KEYS AT ALL. Every
  // symbol is SYMBOL SHIFT plus a letter or digit, every editing action is CAPS
  // SHIFT plus a digit, and MAME's `spectrum` driver maps SYMBOL SHIFT to the
  // host's RIGHT shift. typeText() only ever sends US scancodes with LEFT
  // shift, so a visitor with a PC keyboard cannot produce `"` `;` `=` or even a
  // cursor arrow — those characters simply do not exist on the wire. This
  // profile IS the affordance for them, which is why the symbol chords are
  // spelled out rather than left to the QWERTY row.
  //
  // Every macro is (SYMBOL|CAPS) SHIFT held across one unshifted key, taken
  // from the driver's own PORT_NAME columns in src/mame/sinclair/spectrum.cpp
  // ("p P \" TAB (c) PRINT" -> SYMBOL SHIFT + P is `"`). The letters are sent as
  // lower-case code points because the profile invariant requires printable
  // keysyms to be UNSHIFTED — CAPS SHIFT + a letter is a capital on this
  // machine, which is exactly what we must NOT send here.
  //
  // The two latches stay as well: held across a key the visitor types on the
  // QWERTY row, they reach every remaining combination the exhibit has.
  zxspectrum: {
    family: 'zxspectrum',
    rows: [[
      latch('sym', 'SYM SHIFT', XK.Shift_R, 'SYMBOL SHIFT — the red symbols under the keys'),
      latch('caps', 'CAPS SHIFT', XK.Shift_L, 'CAPS SHIFT — capitals, and the white symbols'),
      sym('quote', '"', 'p'),
      sym('semi', ';', 'o'),
      sym('comma', ',', 'n'),
      sym('stop', '.', 'm'),
      tap('ret', '⏎', XK.Return),
      // The Spectrum's cursor keys ARE CAPS SHIFT + 5/6/7/8, printed as arrows
      // on those keys. A bare Up/Down/Left/Right reaches the matrix as nothing.
      caps('sp-left', '←', '5'),
      caps('sp-down', '↓', '6'),
      caps('sp-up', '↑', '7'),
      caps('sp-right', '→', '8'),
    ]],
    moreRows: [[
      // EXTENDED MODE is both shifts at once — the E cursor, which is how you
      // reach RND, INKEY$, PI and the colour statements.
      macro('extmode', 'EXT MODE',
        [dn(XK.Shift_L), dn(XK.Shift_R), up(XK.Shift_R), up(XK.Shift_L)],
        { hint: 'CAPS SHIFT + SYMBOL SHIFT — the E cursor (RND, INKEY$, PI…)' }),
      caps('sp-delete', 'DELETE', '0'),
      caps('sp-edit', 'EDIT', '1'),
      caps('sp-capslock', 'CAPS LOCK', '2'),
      sym('sp-eq', '=', 'l'),
      sym('sp-plus', '+', 'k'),
      sym('sp-minus', '-', 'j'),
      sym('sp-star', '*', 'b'),
      sym('sp-slash', '/', 'v'),
      sym('sp-lt', '<', 'r'),
      sym('sp-gt', '>', 't'),
      sym('sp-query', '?', 'c'),
      sym('sp-colon', ':', 'z'),
      sym('sp-open', '(', '8'),
      sym('sp-close', ')', '9'),
      sym('sp-pound', '£', 'x'),
    ]],
  },
};

// Every production streamhost tile, EXPLICITLY (test-enforced vs the registry).
export const OS_FAMILY: Record<string, Family> = {
  helenos: 'generic', serenityos: 'generic', toaruos: 'generic', kolibrios: 'generic',
  tinycore: 'generic', redstar2: 'generic', redstar3: 'generic', postmarketos: 'generic',
  sailfishos: 'generic', templeos: 'generic', qnx: 'generic', haiku: 'generic',
  openvms: 'generic',
  alpine: 'linux-tty',
  win95: 'windows', win98se: 'windows', win2000: 'windows', winxp: 'windows', reactos: 'windows',
  nt4: 'windows', // Explorer shell — Win95-era shortcuts apply
  win11: 'windows', // Same Explorer shortcut family; Fluent chrome, not new chords
  win311: 'win3x', nt351: 'win3x', // NT 3.51 runs the Program Manager shell
  amstradcpc: 'generic',
  mpf2: 'generic', // BASIC prompt only; no shell chords to profile
  freedos: 'dos', msdoswin1: 'dos',
  os2warp: 'os2',
  solaris: 'suncde',
  // IRIX 6.5 under 4Dwm. Motif-derived like CDE, but the suncde profile's rows
  // are CDE's own (Help on F1, the CDE edit chords) rather than Indigo Magic's,
  // so it takes the generic Unix rows until an IRIX profile is worth writing.
  irix: 'generic',
  ninefront: 'plan9',
  android: 'android',
  c64: 'c64',
  plus4: 'plus4',
  // Same keyboard as the c64 (Commodore reused the VIC-20's), and the same VICE
  // bindings drive it: RUN/STOP is Esc, RESTORE is PageUp, C= is Tab.
  vic20: 'c64',
  // Same keyboard again, plus a CP/M button — the Z80 is what this tile is for.
  c128: 'c128',
  // The two PETs take DIFFERENT families on purpose: VICE picks the keymap from
  // each model's kbd_type, and the 1977 chiclet machine and the 1980 business
  // machine genuinely have different keys. Neither can take the c64 family —
  // the Commodore key and RESTORE are both C64-era additions, so two of that
  // row's buttons would be dead. See docs/guests/pet2001.md and cbm8032.md.
  pet2001: 'pet',
  cbm8032: 'petbusiness',
  // CBM 610: a BASIC prompt and nothing else. Unlike the c64/plus4 machines this
  // keyboard has no key a PC lacks — there is no Commodore key on a CBM-II and
  // its numeric pad is ordinary digits — so the generic rows already cover it.
  cbm2: 'generic',
  // 2.11BSD on a DL11 console: a plain 7-bit tty with no window system and no
  // chords beyond the line-editing keys the machine prints itself (erase, ^U,
  // ^C, ^D), which the generic Unix rows already carry.
  pdp11: 'generic',
  // A chooser and three DEC keyboard monitors (RT-11 KMON, MCR, DCL). The
  // exhibit's only required input is the digit 1, 2 or 3.
  decos: 'generic',
  // NOT a keyboard exhibit at all: the GT40's Lunar Lander reads the VT11 LIGHT
  // PEN and nothing else, so there is no layout to profile. This row exists to
  // satisfy the coverage test; the on-screen keyboard sends nothing the guest
  // will act on.
  gt40: 'generic',
  // Sinclair ZX81. Its keyboard is genuinely unlike a PC's, but the hard part
  // is not a mapping problem: at the `K` cursor the machine is in KEYWORD mode,
  // so one keypress enters a whole BASIC word (P gives PRINT). What a visitor
  // cannot find are the SHIFT chords — RUBOUT, EDIT, BREAK, the cursor keys —
  // which is exactly what the zx81 profile above puts on screen.
  zx81: 'zx81',
  // Dragon 32: BASIC only, but BREAK and CLEAR are real keys with no PC label,
  // so it takes its own two-button family rather than the generic rows.
  dragon32: 'dragon',
  // Oric Atmos: a BASIC prompt and nothing else, and no key a PC keyboard
  // lacks — MAME maps the host's keys onto the Oric matrix by position, and the
  // Atmos layout is ASCII-shaped. Its two extra keys (FUNCT and the Oric's own
  // CTRL) do nothing at the READY prompt, so the generic rows already cover it.
  oricatmos: 'generic',
  // The only German keyboard in the lineup, and the only machine whose plain
  // letter row is upper case. Both need their own profile.
  kc854: 'kc854',
  // The QL's own keys, and three SuperBASIC one-liners: the machine's idle
  // screen is completely mute, so the buttons are the only invitation.
  sinclairql: 'sinclairql',
  // NeXTSTEP takes the generic Unix rows. The Workspace's own chords hang off
  // the NeXT Command key, which Previous maps to Alt and which the generic rows
  // already expose; the machine's real interface is the mouse, and a bespoke
  // profile would only duplicate what the on-screen menus already show.
  nextstep: 'generic',
  apple2: 'appleii',
  atarist: 'atarist',
  amiga: 'amiga', aros: 'amiga',
  // The ZX Spectrum needs a profile of its own and could not borrow one: its
  // 40-key matrix has no punctuation, no cursor keys and no Ctrl, and its two
  // shifts do different jobs from a PC's.
  zxspectrum: 'zxspectrum',
};

export function keyboardProfileFor(osId: string): KeyboardProfile {
  return PROFILES[OS_FAMILY[osId] ?? 'generic'];
}

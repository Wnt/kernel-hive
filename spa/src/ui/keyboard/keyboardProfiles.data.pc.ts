// ============================================================================
//  keyboardProfiles.data.pc — PROFILES entries for the PC/Unix/Commodore
//  families, half of the per-machine PROFILES literal split out of
//  keyboardProfiles.ts (ts-src 600-line hard cap). See keyboardProfiles.ts
//  for the wire-rule notes that govern every keysym below, and
//  keyboardProfiles.data.ts for the other half and the assembled PROFILES.
// ============================================================================

import type { KeyboardProfile } from './keyTypes';
import { XK } from '../../three/useStreamControl';
import {
  tap, latch, macro, ch, dn, up, press, F, fkeyRow, CBM_C, chord, ctrlChar,
  ARROWS, CAD, NAV, MODS, ALT_TAB, ALT_F4, ctrlEsc, XF86_HOMEPAGE,
} from './keyboardProfiles';

export type PcFamily =
  | 'generic' | 'linux-tty' | 'windows' | 'win3x' | 'dos' | 'os2'
  | 'suncde' | 'plan9' | 'android' | 'c64' | 'plus4' | 'c128'
  | 'pet' | 'petbusiness' | 'zx81' | 'dragon';

export const PROFILES_PC: Record<PcFamily, KeyboardProfile> = {
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
      // Alt+Space; ship it only after a live-station verification pass.
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
  // THEM. The station rests on the machine's power-on screen, which prints
  // "3-PLUS-1 ON KEY F1", so the first button does exactly that; the next three
  // switch module once the suite is up.
  //
  // Each of those three has to open the suite's command prompt first, and that
  // needs the Commodore key — which does not exist on a Mac, a PC or a phone
  // (it is Tab under VICE's symbolic keymap, which nobody would guess). So the
  // whole documented sequence rides in one macro: C= + C, then "to Word" / "to
  // Calculator" / "to File manager", then RETURN. The sequences are the ones
  // scripts/build-guests/tiles/plus4.sh proves against the live guest on every build.
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
  // other station in the lineup can do. The scene is the machine's untouched
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
  // scripts/build-guests/tiles/c128.sh on every build.
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
    // end-to-end scancode path on this station yet, and a dead key is silent
    // through the whole pipeline.
    moreRows: [[
      tap('restore', 'RESTORE', XK.Prior, { hint: 'RESTORE (VICE: PageUp)' }),
    ], fkeyRow(1, 8)],
  },

  // PET 2001 — the 1977 chiclet machine. NOT the c64 profile: no Commodore key,
  // no RESTORE, no function keys. RUN/STOP is the key that matters, because the
  // exhibit's type-in demo is an infinite loop and without it a visitor who runs
  // the demo can only get back to READY. by resetting the station. Verified on the
  // live station: Esc gave "BREAK IN 30 / READY.".
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
  // EVERY ROW HERE WAS PROVED ON THE LIVE FRAMEBUFFER (clone of the station,
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

};

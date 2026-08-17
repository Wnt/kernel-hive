// ============================================================================
//  keyboardProfiles.data.exotic — PROFILES entries for the 8-bit/exotic and
//  Xerox families, the other half of the per-machine PROFILES literal split
//  out of keyboardProfiles.ts (ts-src 600-line hard cap). See
//  keyboardProfiles.ts for the wire-rule notes that govern every keysym
//  below, and keyboardProfiles.data.ts for the PC/Unix/Commodore half and
//  the assembled PROFILES.
// ============================================================================

import type { KeyboardProfile } from './keyTypes';
import { XK } from '../../three/useStreamControl';
import {
  tap, latch, macro, dn, up, press, F, fkeyRow, sym, caps, cmd, chord,
  ARROWS, levelVRow, DWARF_LEVEL_V, STAR_LEVEL_V, VP_TEXT_PROPERTIES,
} from './keyboardProfiles';

export type ExoticFamily =
  | 'kc854' | 'sinclairql' | 'bbcmicro' | 'armeval' | 'alto' | 'appleii'
  | 'atarist' | 'classicmac' | 'amiga' | 'zxspectrum' | 'xerox-dwarf'
  | 'xerox-star';

export const PROFILES_EXOTIC: Record<ExoticFamily, KeyboardProfile> = {
  // KC 85/4 — a GERMAN keyboard with an East German operating system, and the
  // only exhibit here where the on-screen keyboard has to apologise for the
  // host's layout rather than just add a missing modifier.
  //
  // Base row: the two words CAOS itself is offering on the screen the station rests
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

  // Sinclair QL. The scene is the machine's own idle SuperBASIC screen, which
  // says nothing and offers nothing — the QL does not even print READY — so the
  // affordances have to come from here. All three macros are SuperBASIC lines
  // the machine answers immediately and visibly:
  //   MODE 8  the 256-pixel-wide eight-colour mode the QL used on a television
  //   MODE 4  back to the 512-pixel four-colour mode this exhibit rests in
  //   CLS     clears the command window, which is the only way to tidy up
  // F1..F5 are the QL's own function keys: F1/F2 are what the machine asks for
  // at power-on (monitor or TV — already answered in the checkpoint), and QL
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

  // BBC Micro Model B. Three keys a visitor cannot find on their own keyboard,
  // all read from the driver's own PORT_CHAR/PORT_CODE table
  // (src/mame/acorn/bbc_kbd.cpp) and then verified on the live station:
  //
  //  * ESCAPE stops a running BASIC program — the machine prints "Escape" and
  //    returns to `>`. It is the one key a visitor who runs an accidental
  //    infinite loop actually needs.
  //  * BREAK is a separate physical key on a real Model B (top right, above
  //    RETURN) and MAME puts it on host F12, which no visitor would guess. It
  //    soft-resets the machine back to the power-on banner and loses the
  //    program, hence `danger`.
  //  * f0..f9 are the row of TEN RED KEYS along the top of the machine — its
  //    single most recognisable feature — and MAME drives them from host
  //    F1..F10, offset by one. Labelling them F1..F10 would be wrong on both
  //    counts, so this profile builds the row by hand rather than using
  //    fkeyRow().
  //
  // No Ctrl latch on the base row: BBC BASIC has no control chords a visitor
  // would reach for, and MODS is not part of a home-computer profile.
  bbcmicro: {
    family: 'bbcmicro',
    rows: [[
      tap('esc', 'ESCAPE', XK.Escape, { hint: 'ESCAPE — stops a running program' }),
      tap('ret', '⏎', XK.Return),
      tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
      ...ARROWS,
    ]],
    moreRows: [
      [
        tap('break', 'BREAK', F(12),
          { danger: true, hint: 'BREAK — soft-resets the machine to its banner; your program is lost' }),
      ],
      [
        tap('f0', 'f0', F(1)), tap('f1', 'f1', F(2)), tap('f2', 'f2', F(3)),
        tap('f3', 'f3', F(4)), tap('f4', 'f4', F(5)), tap('f5', 'f5', F(6)),
        tap('f6', 'f6', F(7)), tap('f7', 'f7', F(8)), tap('f8', 'f8', F(9)),
        tap('f9', 'f9', F(10)),
      ],
    ],
  },

  // The ARM Evaluation System has no operating system and no application — the
  // exhibit IS its 16 KB supervisor ROM, so the keyboard is the whole exhibit
  // and these four macros are its entire guided tour. Every one of them was
  // driven against the restored checkpoint by framebuffer before it shipped.
  // The exhibit rests INSIDE ARM BBC Basic V, not at the supervisor's `A*`
  // prompt, so this profile is BASIC's, not the supervisor's. Every button
  // below was driven against the restored checkpoint by framebuffer before it was
  // written down, and the supervisor's four commands were driven too and are
  // gone because they FAILED there:
  //   `*QUIT` / `*DIS 3000000` / `*SHOWREGS` -> "Bad command". DIS and SHOWREGS
  //     are supervisor built-ins, not OSCLI commands, and *QUIT proves the
  //     supervisor cannot be re-entered from BASIC at all.
  //   BREAK (F12) -> NOTHING. No reset, no banner, not one pixel changed, and
  //     no MAME snapshot appeared in the guest either. Driven twice, through
  //     both the QMP sendkey and cdrv paths.
  // `*HELP` and `*CAT` DO work on the machine and are the better facts, but a
  // macro cannot type `*` here — see cmd() above.
  armeval: {
    family: 'armeval',
    rows: [[
      cmd('ab-list', 'LIST', 'LIST',
        'LIST — the program back, re-listed from the tokens the ARM is holding'),
      cmd('ab-run', 'RUN', 'RUN', 'RUN — run the program that is in memory'),
      tap('ret', '\u23ce', XK.Return),
      tap('esc', 'ESCAPE', XK.Escape,
        { hint: 'ESCAPE \u2014 stops a running program ("Escape at line 20")' }),
      tap('bksp', '\u232b', XK.BackSpace, { repeat: true }),
      ...ARROWS,
    ]],
  },

  // Xerox Alto. The exhibit rests at the Alto Executive, the machine's own
  // command prompt, exactly as a cold boot leaves it -- so, as on plus4, the
  // choice of application lives HERE rather than inside the checkpoint. Four
  // buttons, in the order a visitor needs them: the disk's own directory, then
  // the three programs on it that are worth thirty seconds.
  //
  // The Executive is case-insensitive, so these are plain lower-case words and
  // no Shift ever has to survive the wire (a shift that arrives in the same
  // field as its letter is dropped -- see docs/lab/research/xerox-build-log.md).
  // Nothing here is a chord: the Alto's own keyboard has no Ctrl-anything worth
  // putting on screen, and its five-key chord SET is a separate device the
  // exhibit does not model.
  alto: {
    family: 'alto',
    rows: [[
      // `?` is Shift+/ and the wire rules forbid a shifted printable keysym, so
      // it is an explicit chord rather than a cmd(). Everything else on this row
      // is lower case and needs no modifier at all.
      macro('alto-dir', '?',
        [dn(XK.Shift_L), ...press(0x2f), up(XK.Shift_L), ...press(XK.Return)],
        { hint: '? — the Executive lists everything on the disk it can run' }),
      cmd('alto-bravo', 'BRAVO', 'bravo',
        'Bravo 7.5 -- the first WYSIWYG word processor. Takes about half a minute to load'),
      cmd('alto-draw', 'DRAW', 'draw',
        'Draw 5.2 -- the illustration program, with its icon palette down the left edge'),
      // NO LAUREL BUTTON, and it is a deliberate absence. Laurel is the mail
      // reader, and it is the exhibit's most tempting third program -- but it
      // wants a Grapevine mail server, this station has no Ethernet, and it
      // answers a visitor with a BLANK PAGE AND AN HOURGLASS with no way back
      // (measured on the station, 45 s, 0 ink pixels anywhere). A dead end is
      // worse than an absent button.
      tap('ret', '\u23ce', XK.Return),
      tap('bksp', '\u232b', XK.BackSpace, { repeat: true }),
      ...ARROWS,
    ]],
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

  // Classic Mac OS (macos753). The one profile in this file whose modifier is
  // not optional: System 7 has NO command line, so every verb a visitor might
  // want is either a menu item or a Command chord, and a browser cannot be
  // relied on to deliver ⌘ itself — the host swallows Meta for its own
  // shortcuts. Super_L is the right keysym: it reaches the guest as XT set1
  // 0xE05B -> QEMU qcode meta_l -> ADB 0x37, which IS Command (verified on the
  // live guest: Command-O opened a selected Finder icon, Command-W closed the
  // window).
  //
  // ⌘. is the classic Mac cancel and has no Windows equivalent, so it is spelled
  // out rather than left to the QWERTY row. Function keys are omitted on
  // purpose: the Quadra's ADB keyboard has them, but System 7 binds none of
  // them, so a row of F-keys would be twelve buttons that do nothing.
  classicmac: {
    family: 'classicmac',
    rows: [[
      latch('cmd', '⌘', XK.Super_L, 'Command'),
      latch('opt', '⌥', XK.Alt_L, 'Option'),
      latch('shift', 'Shift', XK.Shift_L),
      tap('esc', 'Esc', XK.Escape),
      tap('ret', '⏎', XK.Return),
      ...ARROWS,
    ]],
    moreRows: [[
      chord('cmd-o', '⌘O', XK.Super_L, 'o'.charCodeAt(0), 'Open the selected item'),
      chord('cmd-w', '⌘W', XK.Super_L, 'w'.charCodeAt(0), 'Close window'),
      chord('cmd-q', '⌘Q', XK.Super_L, 'q'.charCodeAt(0), 'Quit the application'),
      chord('cmd-n', '⌘N', XK.Super_L, 'n'.charCodeAt(0), 'New folder'),
      chord('cmd-period', '⌘.', XK.Super_L, '.'.charCodeAt(0), 'Cancel'),
    ]],
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

  // Xerox 6085 "Daybreak" under Dwarf/Draco. The two base rows ARE the Level-V
  // function block, because on this machine that block is not a set of
  // shortcuts — it is the interface. There are no arrows and no Ctrl latch: the
  // 6085 keyboard has no cursor keys, and Ctrl is the Xerox modifier itself, so
  // a bare Ctrl would emit nothing the guest can use.
  'xerox-dwarf': {
    family: 'xerox-dwarf',
    rows: [
      levelVRow(DWARF_LEVEL_V, ['next', 'open', 'props', 'move', 'copy', 'same']),
      levelVRow(DWARF_LEVEL_V, ['again', 'find', 'undo', 'help', 'stop', 'delete']),
    ],
    moreRows: [
      VP_TEXT_PROPERTIES,
      [
        tap('para-tab', 'PARA TAB', XK.Tab, { hint: 'The Xerox tab key' }),
        tap('new-para', 'NEW PARA', XK.Return, { hint: 'The Xerox return key — a new paragraph, not a new line' }),
        tap('bs', '⌫', XK.BackSpace, { repeat: true }),
        latch('shift', 'Shift', XK.Shift_L),
        tap('lock', 'LOCK', XK.Caps_Lock),
        tap('space', 'Space', 0x20, { repeat: true, wide: true }),
      ],
    ],
  },
  // Xerox 8010 "Dandelion" under Darkstar. The same Level-V verbs as
  // `xerox-dwarf`, bound to the plain keys Darkstar uses instead of a Ctrl
  // layer; DEFAULTS and EXPAND are present here and absent on Daybreak. There
  // is no Ctrl latch on purpose: on the Star, Ctrl IS a Level-V key (Darkstar
  // maps Left Control to OPEN and Right Control to PROPS), so a bare Ctrl
  // button would fire a verb rather than modify the next keystroke.
  'xerox-star': {
    family: 'xerox-star',
    rows: [
      levelVRow(STAR_LEVEL_V, ['next', 'open', 'props', 'move', 'copy', 'same']),
      levelVRow(STAR_LEVEL_V, ['again', 'find', 'undo', 'help', 'stop', 'delete']),
    ],
    moreRows: [
      levelVRow(STAR_LEVEL_V, ['defaults', 'expand']),
      [
        tap('para-tab', 'PARA TAB', XK.Tab, { hint: 'The Xerox tab key' }),
        tap('new-para', 'NEW PARA', XK.Return, { hint: 'The Xerox return key — a new paragraph, not a new line' }),
        tap('bs', '⌫', XK.BackSpace, { repeat: true }),
        latch('shift', 'Shift', XK.Shift_L),
        tap('lock', 'LOCK', XK.Caps_Lock),
        tap('space', 'Space', 0x20, { repeat: true, wide: true }),
      ],
    ],
  },
};

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
//      VERIFIED 2026-07-17 on the live station: the running hatari 2.4.1 (ps-
//      checked invocation, no --keymap / no hatari.cfg override) documents
//      Scroll Lock → ST UNDO, and an evdev capture on the station confirmed the
//      OSK's scancode 0x46 arrives as KEY_SCROLLLOCK on the input device
//      hatari reads;
//    - T4 android: RESOLVED for Home 2026-07-17 (live-station framebuffer test:
//      KEY_HOME 0xE047 is MOVE_HOME — did NOT leave the search activity;
//      KEY_HOMEPAGE via scancode 0xE032 navigated to the launcher → shipped
//      as XF86HomePage). Back(Esc)/Menu keep their defensible mappings; note
//      Esc did not visibly back out of a focused search field, and qcode
//      ac_back (0xE06A → KEY_BACK) is the candidate if Back misbehaves.
// ============================================================================

import type { KeyAction, KeyDef, KeyRow, MacroStep } from './keyTypes';
import { XK } from '../../three/useStreamControl';

export type Family =
  | 'generic' | 'linux-tty' | 'windows' | 'win3x' | 'dos' | 'os2'
  | 'suncde' | 'plan9' | 'android' | 'c64' | 'plus4' | 'c128'
  | 'pet' | 'petbusiness' | 'appleii' | 'atarist' | 'amiga'
  | 'zxspectrum' | 'zx81' | 'dragon' | 'kc854' | 'sinclairql'
  | 'bbcmicro' | 'armeval' | 'alto' | 'xerox-dwarf' | 'xerox-star'
  | 'classicmac';

// ---- row builders ---------------------------------------------------------

const key = (id: string, label: string, action: KeyAction, extra: Partial<KeyDef> = {}): KeyDef =>
  ({ id, label, action, ...extra });
export const tap = (id: string, label: string, keysym: number, extra: Partial<KeyDef> = {}): KeyDef =>
  key(id, label, 'tap', { keysym, ...extra });
export const latch = (id: string, label: string, keysym: number, hint?: string): KeyDef =>
  key(id, label, 'latch', { keysym, hint });
export const ch = (c: string): KeyDef => key(`ch-${c}`, c, 'char', { char: c });
export const macro = (id: string, label: string, steps: MacroStep[], extra: Partial<KeyDef> = {}): KeyDef =>
  key(id, label, 'macro', { steps, ...extra });

export const dn = (keysym: number): MacroStep => ({ keysym, down: true });
export const up = (keysym: number): MacroStep => ({ keysym, down: false });
export const press = (keysym: number): MacroStep[] => [dn(keysym), up(keysym)];

// XF86HomePage — resolves to scancode 0xE032 (KEY_HOMEPAGE in a Linux guest),
// the key Android's Generic.kl binds to launcher HOME. Lab-verified 2026-07-17
// on the live android station (KEY_HOME 0xE047 is MOVE_HOME there — wrong key).
export const XF86_HOMEPAGE = 0x1008ff18;

// The XK table has NO F-key constants — F-keys are numeric XK_F1 + n − 1.
export const F = (n: number): number => 0xffbe + (n - 1);
export const fkeyRow = (from: number, to: number): KeyRow => {
  const row: KeyRow = [];
  for (let n = from; n <= to; n++) row.push(tap(`f${n}`, `F${n}`, F(n)));
  return row;
};

/** C= held across a C — the Plus/4 suite's "open the command prompt" chord. */
export const CBM_C: MacroStep[] = [dn(XK.Tab), ...press(0x63), up(XK.Tab)];

/** ZX Spectrum SYMBOL SHIFT (host right shift) held across one unshifted key. */
export const sym = (id: string, label: string, c: string): KeyDef =>
  macro(id, label, [dn(XK.Shift_R), ...press(c.charCodeAt(0)), up(XK.Shift_R)],
    { hint: `SYMBOL SHIFT + ${c.toUpperCase()}` });
/** ZX Spectrum CAPS SHIFT (host left shift) held across one unshifted key. */
export const caps = (id: string, label: string, c: string): KeyDef =>
  macro(id, label, [dn(XK.Shift_L), ...press(c.charCodeAt(0)), up(XK.Shift_L)],
    { hint: `CAPS SHIFT + ${c.toUpperCase()}` });

/**
 * A whole BASIC keyword typed as ONE macro, then RETURN.
 *
 * Only for the armeval exhibit, and it works there for a specific reason: the
 * host BBC's MOS has CAPS LOCK on at reset — so the LOWERCASE keysyms below
 * (unshifted, as the profile invariant requires) arrive at the machine upper
 * case, which is what BASIC's tokeniser wants. The steps go out through the
 * normal sendKey path, so streamhost's per-station SH_KEY_MIN_HOLD_MS/GAP_MS
 * pacing applies to them exactly as it does to hand-typed keys.
 *
 * IT CANNOT CARRY A `*` COMMAND. On this machine `*` is not where a US PC puts
 * it (registry keyboard.charMap maps it to the `"` KEY, i.e. Shift+apostrophe),
 * and a macro step is a bare keysym: the profile invariant rightly rejects
 * shifted printables because sendKey discards the shift flag, and the charMap
 * is applied only on the demoProgram path. So `*HELP` and `*CAT` — both real,
 * both measured on the machine, both in docs/guests/armeval.md — are NOT
 * buttons here. A dead button is worse than a missing one.
 */
export const cmd = (id: string, label: string, text: string, hint: string): KeyDef =>
  macro(id, label,
    [...text.toLowerCase().split('').flatMap((c) => press(c.charCodeAt(0))), ...press(XK.Return)],
    { hint });

/** mod↓ · key↓↑ · mod↑ */
export const chord = (id: string, label: string, mod: number, keysym: number, hint?: string): KeyDef =>
  macro(id, label, [dn(mod), ...press(keysym), up(mod)], { hint });
/** Ctrl + lowercase letter (keysym = code point, unshifted — test-enforced). */
export const ctrlChar = (id: string, label: string, c: string, hint?: string): KeyDef =>
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
export const CAD = macro(
  'cad', 'Ctrl-Alt-Del',
  [dn(XK.Control_L), dn(XK.Alt_L), ...press(XK.Delete), up(XK.Alt_L), up(XK.Control_L)],
  { hint: 'Ctrl+Alt+Del' },
);

export const NAV: KeyRow = [
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
export const MODS: KeyRow = [latch('shift', 'Shift', XK.Shift_L), CTRL_LATCH, ALT_LATCH, CAD];

// ---- the Xerox Level-V function block -------------------------------------
// ViewPoint/Star are unusable without it: on a real Xerox keyboard the verbs of
// the interface are KEYS, not menu items, and `Tab` is not NEXT — the logon
// sheet cannot even be completed without NEXT.
//
// ONE family, a PER-MACHINE keycode map. The same logical buttons carry the
// same labels for the visitor, but the two Xerox machines in the lineup expose
// them through completely different host keys — Dwarf/Draco (the 6085) uses
// Ctrl+letter, while Darkstar (the 8010 Star) uses plain PC function keys. A
// single fixed key set would be silently dead on one of the two, so a machine
// contributes a BINDING table and the rows are built from it. A logical key the
// machine has no binding for is simply absent: a dead button is worse than a
// missing one.
type LevelVKey =
  | 'next' | 'open' | 'props' | 'move' | 'copy' | 'same'
  | 'again' | 'find' | 'undo' | 'help' | 'stop' | 'delete'
  | 'skip' | 'defaults' | 'expand';

const LEVEL_V_META: Record<LevelVKey, { label: string; hint: string }> = {
  next: { label: 'NEXT', hint: 'NEXT — move to the next field. The logon sheet asks for this key by name' },
  open: { label: 'OPEN', hint: 'OPEN the selected icon or document' },
  props: { label: 'PROPS', hint: 'PROPERTIES — the property sheet for the selection' },
  move: { label: 'MOVE', hint: 'MOVE the selection, then indicate where' },
  copy: { label: 'COPY', hint: 'COPY the selection, then indicate where' },
  same: { label: 'SAME', hint: 'SAME — give the selection the properties of the next thing you point at' },
  again: { label: 'AGAIN', hint: 'AGAIN — repeat the last action' },
  find: { label: 'FIND', hint: 'FIND' },
  undo: { label: 'UNDO', hint: 'UNDO the last action' },
  help: { label: 'HELP', hint: 'HELP' },
  stop: { label: 'STOP', hint: 'STOP the operation in progress' },
  delete: { label: 'DELETE', hint: 'DELETE the selection' },
  skip: { label: 'SKIP', hint: 'SKIP to the next field without filling this one' },
  defaults: { label: 'DEFAULTS', hint: 'DEFAULTS — restore this sheet to its default values' },
  expand: { label: 'EXPAND', hint: 'EXPAND / DEFN — expand the abbreviation at the caret' },
};

/** How one machine emits one Level-V key. */
type LevelVEmit = (id: string, label: string, hint: string) => KeyDef;
type LevelVBinding = Partial<Record<LevelVKey, LevelVEmit>>;

export const levelVRow = (bind: LevelVBinding, keys: readonly LevelVKey[]): KeyRow =>
  keys.flatMap((k) => {
    const emit = bind[k];
    return emit ? [emit(`lv-${k}`, LEVEL_V_META[k].label, LEVEL_V_META[k].hint)] : [];
  });

/** Level-V verb bound to Ctrl + a letter — Dwarf's documented `Ctrl!<letter>`. */
const lvCtrl = (c: string): LevelVEmit => (id, label, hint) => ctrlChar(id, label, c, hint);
/** Level-V verb bound to a bare key. */
const lvTap = (keysym: number): LevelVEmit => (id, label, hint) => tap(id, label, keysym, { hint });

// Dwarf/Draco (Xerox 6085 "Daybreak"). Ctrl is Dwarf's `xeroxControlKeyCode`,
// and these letters are exactly the rows this station's own keyboard map declares
// (scripts/build-guests/tiles/daybreak.sh writes kbd_linux_en_US.map). SKIP,
// DEFAULTS and EXPAND are deliberately unbound: Dwarf's map has no Ctrl binding
// for them, so a button would be dead.
export const DWARF_LEVEL_V: LevelVBinding = {
  next: lvCtrl('n'), open: lvCtrl('o'), props: lvCtrl('p'), move: lvCtrl('m'),
  copy: lvCtrl('c'), same: lvCtrl('s'), again: lvCtrl('a'), find: lvCtrl('f'),
  undo: lvCtrl('u'), help: lvCtrl('h'),
  stop: lvTap(XK.Escape), delete: lvTap(XK.Delete),
};

// Darkstar (Xerox 8010 "Dandelion"). The SAME Level-V verbs as the 6085, but
// the 8010 emits them as PLAIN keys, not as a Ctrl layer: Darkstar's README
// §3.2 maps the Star keyboard onto the PC function block and the navigation
// cluster. Verified on the live station — `Home` is the NEXT that wakes the
// logged-off machine and walks the Logon Option Sheet, and `F7` is the OPEN
// that opens the Directory icon. Three keys Dwarf cannot bind (SKIP, DEFAULTS,
// EXPAND) do exist here, so the Star's rows are longer than Daybreak's; that
// is `levelVRow` doing its job, not a discrepancy to reconcile.
export const STAR_LEVEL_V: LevelVBinding = {
  next: lvTap(XK.Home), open: lvTap(F(7)), props: lvTap(F(8)), move: lvTap(F(6)),
  copy: lvTap(F(4)), same: lvTap(F(5)), again: lvTap(F(1)), find: lvTap(F(3)),
  undo: lvTap(XK.Prior), help: lvTap(XK.Up),
  stop: lvTap(XK.Next), delete: lvTap(F(2)),
  // No `skip`: on the Star SKIP and NEXT are ONE key (Darkstar's table reads
  // "Skip/Next  Home"), so a second button would send the same keysym.
  defaults: lvTap(XK.Num_Lock), expand: lvTap(XK.End),
};

/**
 * The ViewPoint text-property keys. These are real keys on the 6085 keyboard's
 * top row and the only way to style text in the VP Document Editor; Dwarf maps
 * them onto F2..F11 (F1 and F12 are deliberately left free upstream).
 */
export const VP_TEXT_PROPERTIES: KeyRow = [
  tap('vp-bold', 'BOLD', F(3)), tap('vp-italic', 'ITALIC', F(4)),
  tap('vp-underline', 'UNDERLINE', F(7)), tap('vp-center', 'CENTER', F(2)),
  tap('vp-case', 'CASE', F(5)), tap('vp-strikeout', 'STRIKEOUT', F(6)),
  tap('vp-supersub', 'SUPER/SUB', F(8)), tap('vp-smaller', 'SMALLER', F(9)),
  tap('vp-margins', 'MARGINS', F(10)), tap('vp-font', 'FONT', F(11)),
];

export const ALT_TAB = chord('alt-tab', 'Alt+Tab', XK.Alt_L, XK.Tab, 'Switch task');
export const ALT_F4 = chord('alt-f4', 'Alt+F4', XK.Alt_L, F(4), 'Close window');
export const ctrlEsc = (hint: string): KeyDef => chord('ctrl-esc', 'Ctrl+Esc', XK.Control_L, XK.Escape, hint);

// ---- the profiles ---------------------------------------------------------

// PROFILES: split out to keyboardProfiles.data.ts (ts-src 600-line hard cap).

// Every production streamhost station, EXPLICITLY (test-enforced vs the registry).
export const OS_FAMILY: Record<string, Family> = {
  helenos: 'generic', serenityos: 'generic', toaruos: 'generic', kolibrios: 'generic',
  tinycore: 'generic', redstar2: 'generic', redstar3: 'generic', postmarketos: 'generic',
  sailfishos: 'generic', templeos: 'generic', qnx: 'generic', haiku: 'generic',
  beos: 'generic',
  chokanji: 'generic', // 超漢字 / B-right/V (BTRON3) — menu-driven, Japanese-IME desktop; no PC chord set to profile
  newsos: 'generic', // NEWS-OS 4.1R: sxdm login + twm/xterm — no shell chord set to profile
  openvms: 'generic',
  alpine: 'linux-tty',
  win95: 'windows', win98se: 'windows', win2000: 'windows', winxp: 'windows', reactos: 'windows',
  nt4: 'windows', // Explorer shell — Win95-era shortcuts apply
  win11: 'windows', // Same Explorer shortcut family; Fluent chrome, not new chords
  w2kalpha: 'windows', // W2K RC2 on Alpha — the same NT 5.0 Explorer shell as win2000
  hpuxvue: 'suncde', // HP VUE — the Motif desktop CDE was built from; the CDE chord set (F1 Help, edit chords) is VUE's too
  aix432: 'suncde', // AIX 4.3.3 runs CDE itself — the same Motif chord set VUE gave it
  sunos414: 'generic', // OpenWindows/OPEN LOOK, not CDE — cut/copy/paste are the Sun
  //                     L-group keys, so the suncde Ctrl-chords would be wrong here
  aux: 'classicmac', // A/UX runs the Finder as its shell — Command chords, as macos753
  rhapsody: 'generic', // Platinum Finder over NeXT Workspace — install phase; revisit once the desktop is up
  tru64: 'suncde', // CDE desktop — the same CDE chord set the Solaris profile carries
  macos753: 'classicmac', // System 7.5.3 — Command chords are the only keyboard verbs it has
  macos9: 'classicmac', // Mac OS 9.2.2 — same Finder, same Command chords, five years on
  // ravynOS 0.6.1. Command chords are the project's stated design goal, but the
  // classicmac family would be wrong here on both counts: its rows are Finder
  // verbs (⌘O open, ⌘N new folder, ⌘. cancel) and the 0.6.x build ships no file
  // manager and no browser, so they would be buttons with nothing to act on;
  // and the one Command chord that certainly works, ⌘⇧Q, quits the WindowServer
  // and takes the desktop away with no Filer left to restart it. What a visitor
  // can actually use is Terminal.app over a FreeBSD 15 userland with zsh, which
  // is what the generic Unix rows are for. Revisit if the Filer ever ships.
  ravynos: 'generic',
  win311: 'win3x', nt351: 'win3x', // NT 3.51 runs the Program Manager shell
  amstradcpc: 'generic',
  mpf2: 'generic', // BASIC prompt only; no shell chords to profile
  freedos: 'dos', msdoswin1: 'dos',
  // bootOS: a bare `$` prompt over BIOS int 16h; the dos rows lead with
  // Ctrl+Alt+Del, which is the way home from a boot-sector game.
  bootos: 'dos',
  // PC/GEOS: a full GUI over DOS, but its chords are its own (Ctrl+Esc for the
  // Express menu, F1 help) rather than Windows 3.x's, so the dos rows' Ctrl+Alt+Del
  // stays the honest common ground until a GEOS profile is worth writing.
  pcgeos: 'dos',
  // Red Hat Linux 6.2: GNOME 1.0 under Enlightenment on XFree86 3.3.6, a US
  // PC keyboard. No GNOME-1-specific chord set worth a profile; the generic
  // Unix rows are the honest common ground, at the fleet's pacing floor.
  redhat62: 'generic',
  os2warp: 'os2',
  solaris: 'suncde',
  // IRIX 6.5 under 4Dwm. Motif-derived like CDE, but the suncde profile's rows
  // are CDE's own (Help on F1, the CDE edit chords) rather than Indigo Magic's,
  // so it takes the generic Unix rows until an IRIX profile is worth writing.
  irix: 'generic',
  indyr4400: 'generic',
  ninefront: 'plan9',
  android: 'android',
  c64: 'c64',
  plus4: 'plus4',
  // Same keyboard as the c64 (Commodore reused the VIC-20's), and the same VICE
  // bindings drive it: RUN/STOP is Esc, RESTORE is PageUp, C= is Tab.
  vic20: 'c64',
  // Same keyboard again, plus a CP/M button — the Z80 is what this station is for.
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
  // Xerox Alto: its own family, because the exhibit's whole interaction is four
  // Executive commands and there is nothing generic about them.
  alto: 'alto',
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
  // BBC Micro Model B: ESCAPE, the BREAK key MAME hides on host F12, and the
  // machine's ten RED function keys, which MAME drives from F1..F10 offset by
  // one (host F1 is the BBC's f0). None of the three is findable by guessing.
  bbcmicro: 'bbcmicro',
  // ARM Evaluation System: the same BBC host keyboard, but the exhibit is the
  // ARM supervisor rather than BASIC, so the rows are its four commands.
  armeval: 'armeval',
  apple2: 'appleii',
  atarist: 'atarist',
  amiga: 'amiga', aros: 'amiga', amigaos35: 'amiga',
  // amix runs System V on Amiga hardware, so it keeps the Amiga keyboard
  // (the profile already carries Ctrl, which the Unix shell needs).
  amix: 'amiga',
  // The ZX Spectrum needs a profile of its own and could not borrow one: its
  // 40-key matrix has no punctuation, no cursor keys and no Ctrl, and its two
  // shifts do different jobs from a PC's.
  zxspectrum: 'zxspectrum',
  // Xerox 6085 under Dwarf/Draco. The only profile in this file whose base rows
  // are entirely machine-specific verbs; see the Level-V block above for why it
  // is built from a per-machine binding table rather than a fixed key set.
  daybreak: 'xerox-dwarf',
  star: 'xerox-star',
};

// keyboardProfileFor lives in keyboardProfiles.data.ts alongside PROFILES: it
// needs PROFILES, and this module must stay free of any runtime import back
// from the data module — data.ts needs these row builders already
// initialized at its own module-eval time, which a two-way import cannot
// guarantee (a genuine value-level import cycle, confirmed by a TDZ failure
// when this was tried). Import keyboardProfileFor from
// './keyboardProfiles.data', not from here.

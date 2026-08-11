// ============================================================================
//  guestQuirks — keycode maps + per-guest boot-dismiss profiles for streamhost
//  ---------------------------------------------------------------------------
//  streamhost's input.rs speaks QEMU XT set1 scancodes (u16; 0xE0xx = extended),
//  NOT the X11 keysyms exposed by the StreamControlHandle surface
//  (consumers still call sendKey(XK.*) and sendKeyEvent(e,down)), so this module
//  provides the two translations the streamhost controller needs:
//    - codeToScancode : KeyboardEvent.code → set1 (the PRIMARY, layout-correct
//      typing path — every physical key, incl. extended nav keys).
//    - keysymToScancode + asciiToScancode : X11 keysym / literal char → set1, for
//      the special-key calls (Ctrl+Alt+Del, Esc, arrows) and typeText().
//
//  It also carries one per-guest quirk profile:
//    - WIN9x BOOT-MODAL auto-dismiss: on first connect for win95/win98se, tap
//      Esc then Enter to clear the "Windows is running in… / restore settings"
//      startup dialog so the desktop is immediately usable.
//  (Cursor correction is NOT done client-side any more — the DAEMON owns the
//  abs→device pointer mapping per station, including any calibration offsets.)
// ============================================================================

// ---------------------------------------------------------------------------
//  XT set1 scancodes (QEMU number keycodes). Extended keys are encoded as a
//  single u16 with the 0xE0 prefix in the high byte (matches QEMU's number-
//  keycode convention; input.rs decodes 0xE0xx → the extended QEMU keycode).
// ---------------------------------------------------------------------------
const EXT = 0xe000; // OR into a base code to mark it 0xE0-prefixed

/** KeyboardEvent.code → set1 scancode. The authoritative, layout-independent map. */
export const CODE_TO_SCANCODE: Record<string, number> = {
  Escape: 0x01,
  Digit1: 0x02, Digit2: 0x03, Digit3: 0x04, Digit4: 0x05, Digit5: 0x06,
  Digit6: 0x07, Digit7: 0x08, Digit8: 0x09, Digit9: 0x0a, Digit0: 0x0b,
  Minus: 0x0c, Equal: 0x0d, Backspace: 0x0e, Tab: 0x0f,
  KeyQ: 0x10, KeyW: 0x11, KeyE: 0x12, KeyR: 0x13, KeyT: 0x14, KeyY: 0x15,
  KeyU: 0x16, KeyI: 0x17, KeyO: 0x18, KeyP: 0x19, BracketLeft: 0x1a, BracketRight: 0x1b,
  Enter: 0x1c, ControlLeft: 0x1d,
  KeyA: 0x1e, KeyS: 0x1f, KeyD: 0x20, KeyF: 0x21, KeyG: 0x22, KeyH: 0x23,
  KeyJ: 0x24, KeyK: 0x25, KeyL: 0x26, Semicolon: 0x27, Quote: 0x28, Backquote: 0x29,
  ShiftLeft: 0x2a, Backslash: 0x2b,
  KeyZ: 0x2c, KeyX: 0x2d, KeyC: 0x2e, KeyV: 0x2f, KeyB: 0x30, KeyN: 0x31, KeyM: 0x32,
  Comma: 0x33, Period: 0x34, Slash: 0x35, ShiftRight: 0x36,
  NumpadMultiply: 0x37, AltLeft: 0x38, Space: 0x39, CapsLock: 0x3a,
  F1: 0x3b, F2: 0x3c, F3: 0x3d, F4: 0x3e, F5: 0x3f, F6: 0x40,
  F7: 0x41, F8: 0x42, F9: 0x43, F10: 0x44, NumLock: 0x45, ScrollLock: 0x46,
  Numpad7: 0x47, Numpad8: 0x48, Numpad9: 0x49, NumpadSubtract: 0x4a,
  Numpad4: 0x4b, Numpad5: 0x4c, Numpad6: 0x4d, NumpadAdd: 0x4e,
  Numpad1: 0x4f, Numpad2: 0x50, Numpad3: 0x51, Numpad0: 0x52, NumpadDecimal: 0x53,
  F11: 0x57, F12: 0x58,
  // ---- extended (0xE0-prefixed) ----
  ControlRight: EXT | 0x1d, AltRight: EXT | 0x38,
  NumpadEnter: EXT | 0x1c, NumpadDivide: EXT | 0x35,
  Home: EXT | 0x47, ArrowUp: EXT | 0x48, PageUp: EXT | 0x49,
  ArrowLeft: EXT | 0x4b, ArrowRight: EXT | 0x4d,
  End: EXT | 0x4f, ArrowDown: EXT | 0x50, PageDown: EXT | 0x51,
  Insert: EXT | 0x52, Delete: EXT | 0x53,
  MetaLeft: EXT | 0x5b, MetaRight: EXT | 0x5c, ContextMenu: EXT | 0x5d,
  PrintScreen: EXT | 0x37,
};

export function codeToScancode(code: string | undefined): number | null {
  if (!code) return null;
  const v = CODE_TO_SCANCODE[code];
  return v == null ? null : v;
}

// ---------------------------------------------------------------------------
//  X11 keysym → set1 (only the keys consumers pass directly to sendKey()).
//  Values mirror the XK table in useStreamControl.ts. Printable keysyms fall
//  through to asciiToScancode.
// ---------------------------------------------------------------------------
export const KEYSYM_TO_SCANCODE: Record<number, number> = {
  0xff08: 0x0e,          // BackSpace
  0xff09: 0x0f,          // Tab
  0xff0d: 0x1c,          // Return
  0xff1b: 0x01,          // Escape
  0xffff: EXT | 0x53,    // Delete
  0xff63: EXT | 0x52,    // Insert
  0xff50: EXT | 0x47,    // Home
  0xff57: EXT | 0x4f,    // End
  0xff55: EXT | 0x49,    // Prior / PageUp
  0xff56: EXT | 0x51,    // Next / PageDown
  0xff51: EXT | 0x4b,    // Left
  0xff52: EXT | 0x48,    // Up
  0xff53: EXT | 0x4d,    // Right
  0xff54: EXT | 0x50,    // Down
  0xff67: EXT | 0x5d,    // Menu
  0xff7f: 0x45,          // Num_Lock
  0xff14: 0x46,          // Scroll_Lock
  // XF86HomePage → "Browser Home" (KEY_HOMEPAGE in a Linux guest). Android's
  // launcher-HOME key: lab-verified 2026-07-17 on the live android station
  // (0xE047/KEY_HOME does NOT leave a foreground activity; 0xE032 navigates
  // to the launcher — framebuffer-confirmed).
  0x1008ff18: EXT | 0x32,
  0xff8d: EXT | 0x1c,    // KP_Enter
  0xffe1: 0x2a,          // Shift_L
  0xffe2: 0x36,          // Shift_R
  0xffe3: 0x1d,          // Control_L
  0xffe4: EXT | 0x1d,    // Control_R
  0xffe5: 0x3a,          // Caps_Lock
  0xffe9: 0x38,          // Alt_L
  0xffea: EXT | 0x38,    // Alt_R
  0xffe7: 0x38,          // Meta_L → Alt_L (guests rarely map a Super key)
  0xffeb: EXT | 0x5b,    // Super_L
  0xffec: EXT | 0x5c,    // Super_R
  // F1..F12
  0xffbe: 0x3b, 0xffbf: 0x3c, 0xffc0: 0x3d, 0xffc1: 0x3e, 0xffc2: 0x3f, 0xffc3: 0x40,
  0xffc4: 0x41, 0xffc5: 0x42, 0xffc6: 0x43, 0xffc7: 0x44, 0xffc8: 0x57, 0xffc9: 0x58,
};

// ---------------------------------------------------------------------------
//  Literal ASCII char → { scancode, shift }. US layout. Used by typeText() and
//  as the fallback for printable X11 keysyms passed to sendKey().
// ---------------------------------------------------------------------------
interface ScanShift { code: number; shift: boolean; }

const LETTER_CODE: Record<string, number> = {
  a: 0x1e, b: 0x30, c: 0x2e, d: 0x20, e: 0x12, f: 0x21, g: 0x22, h: 0x23, i: 0x17,
  j: 0x24, k: 0x25, l: 0x26, m: 0x32, n: 0x31, o: 0x18, p: 0x19, q: 0x10, r: 0x13,
  s: 0x1f, t: 0x14, u: 0x16, v: 0x2f, w: 0x11, x: 0x2d, y: 0x15, z: 0x2c,
};
// Unshifted symbol row/keys.
const UNSHIFTED: Record<string, number> = {
  '1': 0x02, '2': 0x03, '3': 0x04, '4': 0x05, '5': 0x06, '6': 0x07, '7': 0x08,
  '8': 0x09, '9': 0x0a, '0': 0x0b, '-': 0x0c, '=': 0x0d, '[': 0x1a, ']': 0x1b,
  ';': 0x27, "'": 0x28, '`': 0x29, '\\': 0x2b, ',': 0x33, '.': 0x34, '/': 0x35,
  ' ': 0x39, '\t': 0x0f, '\n': 0x1c, '\r': 0x1c,
};
// Shifted symbols → same physical key + Shift.
const SHIFTED: Record<string, number> = {
  '!': 0x02, '@': 0x03, '#': 0x04, $: 0x05, '%': 0x06, '^': 0x07, '&': 0x08,
  '*': 0x09, '(': 0x0a, ')': 0x0b, _: 0x0c, '+': 0x0d, '{': 0x1a, '}': 0x1b,
  ':': 0x27, '"': 0x28, '~': 0x29, '|': 0x2b, '<': 0x33, '>': 0x34, '?': 0x35,
};

export function asciiToScancode(ch: string): ScanShift | null {
  if (ch.length === 0) return null;
  if (ch >= 'a' && ch <= 'z') return { code: LETTER_CODE[ch], shift: false };
  if (ch >= 'A' && ch <= 'Z') return { code: LETTER_CODE[ch.toLowerCase()], shift: true };
  if (ch in UNSHIFTED) return { code: UNSHIFTED[ch], shift: false };
  if (ch in SHIFTED) return { code: SHIFTED[ch], shift: true };
  return null;
}

/** X11 keysym → set1 (special keys first, then printable Latin-1 via ASCII). */
export function keysymToScancode(keysym: number): number | null {
  const direct = KEYSYM_TO_SCANCODE[keysym];
  if (direct != null) return direct;
  // Printable Latin-1 keysym == code point for 0x20..0xff.
  if (keysym >= 0x20 && keysym <= 0xff) {
    const s = asciiToScancode(String.fromCharCode(keysym));
    if (s) return s.code;
  }
  return null;
}

export const SHIFT_L_SCANCODE = 0x2a;

// ---------------------------------------------------------------------------
//  Per-guest quirk profiles
// ---------------------------------------------------------------------------
export interface GuestQuirks {
  /** Send Esc then Enter once on first connect to clear a boot modal. */
  bootDismiss: boolean;
}

const QUIRKS: Record<string, GuestQuirks> = {
  win95:   { bootDismiss: true },
  win98se: { bootDismiss: true },
};

const DEFAULT_QUIRKS: GuestQuirks = { bootDismiss: false };

export function quirksFor(osId: string | undefined): GuestQuirks {
  return (osId && QUIRKS[osId]) || DEFAULT_QUIRKS;
}

// ============================================================================
//  keyTypes — data model for the shared on-screen keyboard
//  ---------------------------------------------------------------------------
//  Pure types, no runtime. A keyboard PROFILE is a small grid of KeyDefs picked
//  per OS family (keyboardProfiles.ts); the send semantics live in keySender.ts.
//
//  Wire vocabulary: X11 keysyms (the XK table in three/useStreamControl.ts),
//  translated client-side to XT set-1 scancodes by guestQuirks.keysymToScancode.
//  INVARIANTS (test-enforced in keyboardProfiles.test.ts):
//    - every tap/latch keysym and macro-step keysym must be client-resolvable
//      (keysymToScancode !== null) — an unresolvable key is silently dead
//      end-to-end, so it must never ship in a profile;
//    - printable-range (0x20..0xff) keysyms used as tap/latch/macro steps must
//      be UNSHIFTED (keysymToScancode discards the shift flag — '|' would
//      come out as '\'); shifted printables go through 'char' + typeText.
// ============================================================================

/** How a key press is delivered to the guest. */
export type KeyAction =
  | 'tap'    // sendKey(keysym, down) + sendKey(keysym, up)
  | 'char'   // typeText(char) — correct synthetic-Shift wrapping for printables
  | 'latch'  // sendKey(keysym, down) now; released after the next non-latch key
  | 'macro'; // ordered sendKey steps (e.g. Ctrl+Alt+Del)

/** One ordered half-transition of a macro. */
export interface MacroStep {
  keysym: number;
  down: boolean;
}

export interface KeyDef {
  /** Stable id — latched/armed UI state is keyed on this. */
  id: string;
  label: string;
  /** Optional tooltip / long-form name. */
  hint?: string;
  action: KeyAction;
  /** X11 keysym for tap/latch actions. */
  keysym?: number;
  /** Literal ASCII character for 'char' actions. */
  char?: string;
  /** Ordered steps for 'macro' actions; downs/ups must balance. */
  steps?: MacroStep[];
  /** Hold-to-repeat (client-side tap-repeat; only valid on 'tap'). */
  repeat?: boolean;
  /** Render wider than a standard key (e.g. Space). */
  wide?: boolean;
  /** Destructive (reset/C-A-D): requires the two-tap arm+confirm flow. */
  danger?: boolean;
}

export type KeyRow = KeyDef[];

export interface KeyboardProfile {
  family: string;
  /** Always-visible rows (kept to <=2 for the mobile sheet's landscape mode). */
  rows: KeyRow[];
  /** Extra rows shown in portrait / desktop-inline only. */
  moreRows?: KeyRow[];
}

// ============================================================================
//  deviceTypes — the data model of a DEVICE DRAWING station page
//  ---------------------------------------------------------------------------
//  Some exhibits are a whole object in the hand, not a screen on a desk: a
//  Communicator's keys ARE its interface, and a generic on-screen keyboard
//  under a letterboxed picture says nothing about the machine. A device
//  drawing presents such a station as a line drawing of the device, with the
//  live picture composited into the drawn display and EVERY drawn key a real
//  control (press = key down, release = key up, so the guest sees a hold).
//
//  A drawing is pure data plus one static outline component: the key
//  geometry, the legends and the keysym each key sends. DeviceStage renders
//  any drawing; deviceSender turns presses into paced key edges. A new
//  handheld adds a drawing and registers it in deviceRegistry.ts — nothing in
//  the station page changes.
//
//  Wire vocabulary is the same as the on-screen keyboard's (keyTypes.ts): X11
//  keysyms, translated client-side to XT set-1 scancodes by
//  guestQuirks.keysymToScancode.
// ============================================================================

import type { ComponentType } from 'react';

/** An axis-aligned box in the drawing's viewBox units. */
export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** A small line glyph drawn on a key (arrows, the Chr function icons). */
export type Glyph =
  | 'tab' | 'enter' | 'backspace' | 'shift'
  | 'up' | 'down' | 'left' | 'right'
  | 'zoomIn' | 'zoomOut' | 'bluetooth' | 'infrared' | 'brightness' | 'sync' | 'help';

/** How a drawn key behaves.
 *  - 'char': types characters — base / Shift / Chr legends, each SENT as the
 *    character it shows (contract rule 1), so what the visitor reads is what
 *    the guest gets whatever the guest's own keyboard layout is;
 *  - 'key' : a non-printable key sent as its own keysym, held while pressed;
 *  - 'mod' : Shift / Ctrl / Chr — tap to latch for the next key, or hold it
 *    while pressing another key (multi-touch), like the device. */
type DeviceKeyKind = 'char' | 'key' | 'mod';

export interface DeviceKey {
  /** Stable id — the keymap contract's id for this key (e.g. `app.desk`, `k4`). */
  id: string;
  kind: DeviceKeyKind;
  /** The key's own keysym: what the key sends as a POSITIONAL press — for a
   *  'key' or 'mod' always, for a 'char' key while Ctrl or Chr is held (the
   *  device maps held-modifier chords by position). */
  keysym: number;
  /** Hit box; the key is drawn as a rounded rect of this box. */
  box: Box;
  /** A joystick zone is drawn by its device's outline, not as a keycap:
   *  'none' renders only the invisible hit target and the pressed highlight. */
  cap?: 'rect' | 'none';
  /** Optional silhouette in local (0…w, 0…h) coordinates, inside box. */
  outline?: string;
  /** Printed text of a named key (Esc, Ctrl, Menu, Desk…). */
  label?: string;
  /** The key's main line glyph, in place of or beside the label. */
  glyph?: Glyph;
  /** 'char' keys: the unshifted character (printed as `shownBase` when set). */
  base?: string;
  /** Printed form of the base legend when it differs (letters print capitals). */
  shownBase?: string;
  /** 'char' keys: the Shift character (upper-right legend). */
  shift?: string;
  /** The Chr character (the device prints these blue). */
  chr?: string;
  /** The character Chr+Shift types, when it differs from `chr` (Ø, Æ). */
  chrShift?: string;
  /** A Chr FUNCTION with no character (zoom, Bluetooth, brightness…): drawn
   *  as a blue glyph and sent positionally with Chr held. */
  chrGlyph?: Glyph;
  /** Long name for the tooltip / accessible label. */
  hint: string;
  /** Physical-keyboard codes (KeyboardEvent.code) that press this same key —
   *  shown in the tooltip and lit on the drawing when pressed. */
  codes?: string[];
  /** Printed in the device's Chr colour (the Chr key itself). */
  chrColour?: boolean;
}

/** A modifier's role for the send engine. */
export type ModRole = 'shift' | 'ctrl' | 'chr';

export interface DeviceDrawing {
  id: string;
  /** Accessible name of the whole device (e.g. "Nokia 9300 Communicator"). */
  name: string;
  viewBox: { w: number; h: number };
  /** Where the live picture goes, in viewBox units. Its aspect must equal the
   *  stream's (test-enforced per drawing) so the picture fills it exactly. */
  screen: Box;
  /** Every interactive key. Order is paint order. */
  keys: DeviceKey[];
  /** Which key id is which modifier role. */
  mods: Record<string, ModRole>;
  /** The static line drawing under the keys (body, hinge, bezel, grille…). */
  Outline: ComponentType;
  /** One line under the drawing naming the physical-keyboard shortcuts. */
  shortcutNote: string;
}

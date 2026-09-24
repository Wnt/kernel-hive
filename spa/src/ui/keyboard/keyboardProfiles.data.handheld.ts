// ============================================================================
//  keyboardProfiles.data.handheld — PROFILES entries for the handheld
//  exhibits whose keys are not a PC's at all, a third shard of the
//  per-machine PROFILES literal (the pc and exotic halves are at the ts-src
//  600-line cap). See keyboardProfiles.ts for the wire-rule notes that govern
//  every keysym below, and keyboardProfiles.data.ts for the assembled PROFILES.
// ============================================================================

import type { KeyboardProfile } from './keyTypes';
import { XK } from '../../three/useStreamControl';
import { tap, latch, F, ARROWS, CTRL_LATCH } from './keyboardProfiles';

export type HandheldFamily = 'nokia9300';

// Nokia 9300 Communicator — Series 80 v2 on Symbian OS 7.0s (the nokia9300
// station runs the device's own firmware in EKA2L1). Series 80 is driven by
// keys a PC keyboard does not have: the four COMMAND BUTTONS in a column to
// the right of the screen, whose meaning is whatever the running application
// prints beside them (Desk: Open / Write note / Note list), and the eight
// APPLICATION BUTTONS in a row below the screen. The two base rows echo that
// arrangement: the application row first, then the command buttons with the
// keys every dialog needs.
//
// Chr/Ctrl/Shift are in that SECOND BASE ROW, not moreRows: moreRows is
// hidden outright in the mobile sheet's landscape mode (keyTypes.ts, and the
// CAD/MODS comment above), and Chr is not a power-user extra here — it is the
// ONLY path to the blue legends (Chr+4 is €) and the task switcher (Chr+Tab),
// so a visitor who only sees landscape must not lose it. The `its` and
// `bsd-tty` profiles state the same rule for their own control characters
// ("a key that is one More tap away is a key a visitor never finds"), and
// every other family with a real Ctrl-equivalent latch (appleii, amiga,
// atarist, classicmac) ships it in a base row rather than moreRows. Row 2 is
// long as a result, but a long row scrolls on its x-axis (oskStyles'
// .osk-row-scroll) exactly like the DOS/generic F-key rows already do, so
// there is no budget reason to hide a modifier instead.
//
// Keysyms are agent K1's keymap contract v1 (2026-09-24) — FIXED, but every row
// is PROVISIONAL until the framebuffer proves it on the station:
//   F1..F4   command buttons 1..4, top to bottom
//   F5..F12  Desk, Telephone, Messaging, Web, Contacts, Documents, Calendar,
//            My own
//   Menu     the Menu key (a long press is the task list)
//   F13..F17 the joystick: centre, up, down, left, right — PROVISIONAL, and
//            kept in moreRows unlike Chr/Ctrl: joy.c/u/d/l/r deliver the SAME
//            EKeyEnter/Up/Down/Left/Right the always-visible Return/arrow
//            keys already send (contract §3), so this row is the device's own
//            labelled control, not a visitor's only path to a function.
//   Chr      ISO_Level3_Shift on the station — PROVISIONAL. The OSK sends
//            Alt_R, which the station's own scancode table (streamhost/
//            stations/nokia9300/x11test.keysyms) turns into ISO_Level3_Shift;
//            Alt_L/Alt_R are Chr aliases in the fork too. Chr is a HELD
//            modifier around a key's base keysym (Chr+4 = €, Chr+Tab = the
//            task switcher), so it is a latch; Chr tapped alone opens the
//            character map in editors.
// Shift is a latch for NON-printables only (Shift+arrows select, Shift+Tab
// goes back, Shift+Backspace deletes right): contract rule 2 — a printable is
// sent as its own character, which the fork maps back to the 9300 key.
// Printables come from the shared QWERTY layer.
const cmdButton = (n: number, where: string): ReturnType<typeof tap> =>
  tap(`s80-cmd${n}`, `Cmd ${n}`, F(n),
    { hint: `Command button ${n} (${where}) — does what the application prints beside it` });
const appButton = (id: string, label: string, n: number, hint: string): ReturnType<typeof tap> =>
  tap(`s80-app-${id}`, label, F(n), { hint });

export const PROFILES_HANDHELD: Record<HandheldFamily, KeyboardProfile> = {
  nokia9300: {
    family: 'nokia9300',
    rows: [
      [
        appButton('desk', 'Desk', 5, 'Desk — the Communicator\'s home screen of application icons'),
        appButton('tel', 'Telephone', 6, 'Telephone'),
        appButton('msg', 'Messaging', 7, 'Messaging — SMS, e-mail and fax'),
        appButton('web', 'Web', 8, 'Web — the Opera browser'),
        appButton('contacts', 'Contacts', 9, 'Contacts'),
        appButton('docs', 'Documents', 10, 'Documents — the word processor'),
        appButton('cal', 'Calendar', 11, 'Calendar'),
        appButton('own', 'My own', 12, 'My own — the application the owner assigned to this button'),
      ],
      [
        cmdButton(1, 'top'),
        cmdButton(2, 'second'),
        cmdButton(3, 'third'),
        cmdButton(4, 'bottom'),
        tap('s80-menu', 'Menu', XK.Menu, { hint: 'Menu — the application\'s menu bar' }),
        tap('esc', 'Esc', XK.Escape, { hint: 'Esc — cancel or close' }),
        tap('ret', '⏎', XK.Return),
        tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
        latch('s80-chr', 'Chr', XK.Alt_R,
          'Chr — the blue legends (Chr+4 is €), Chr+Tab switches tasks, Chr alone opens the character map'),
        CTRL_LATCH,
        latch('shift', 'Shift', XK.Shift_L, 'Shift — with an arrow key it selects text'),
        ...ARROWS,
      ],
    ],
    moreRows: [
      [
        tap('tab', 'Tab', XK.Tab),
        tap('space', 'Space', 0x20, { repeat: true, wide: true }),
      ],
      [
        tap('s80-joy-c', 'Joy ●', F(13), { hint: 'Joystick press — select' }),
        tap('s80-joy-u', 'Joy ↑', F(14), { hint: 'Joystick up' }),
        tap('s80-joy-d', 'Joy ↓', F(15), { hint: 'Joystick down' }),
        tap('s80-joy-l', 'Joy ←', F(16), { hint: 'Joystick left' }),
        tap('s80-joy-r', 'Joy →', F(17), { hint: 'Joystick right' }),
      ],
    ],
  },
};

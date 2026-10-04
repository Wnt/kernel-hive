import type { KeyChord } from '../types';
import { asciiToScancode, SHIFT_L_SCANCODE } from './guestQuirks';
import { withSyntheticInput } from './usageStats';

// ---------------------------------------------------------------------------
//  syntheticTyping — software-generated typing for StreamControlHandle: one act
//  by the visitor, many key edges, counted as the former (usageStats
//  withSyntheticInput). Split out of useStreamControl.ts (ts-src hard cap).
// ---------------------------------------------------------------------------

export function createSyntheticTyping(send: (scancode: number, down: boolean) => void, disposed: () => boolean) {
  /** ASCII → US set1 scancodes, Left Shift around the shifted characters. */
  const typeText = (text: string) => {
    if (disposed()) return;
    withSyntheticInput(() => {
      for (const ch of text) {
        const s = asciiToScancode(ch);
        if (!s) continue;
        if (s.shift) send(SHIFT_L_SCANCODE, true);
        send(s.code, true);
        send(s.code, false);
        if (s.shift) send(SHIFT_L_SCANCODE, false);
      }
    });
  };

  /** One chord: every scancode down in order, then up in reverse, back to back
   *  -- Right Shift and an E-mode CAPS+SYMBOL included, which typeText cannot
   *  express. The station's key module paces the edges (a modifier goes down
   *  with its key and up with it); the caller waits one chord's budget before
   *  the next, so chords never overlap. */
  const typeChord = (chord: KeyChord) => {
    if (disposed()) return;
    withSyntheticInput(() => {
      for (const sc of chord) send(sc, true);
      for (const sc of [...chord].reverse()) send(sc, false);
    });
  };

  return { typeText, typeChord };
}

// ============================================================================
//  keyboardProfiles.data — the per-machine PROFILES literal, assembled.
//  ---------------------------------------------------------------------------
//  Split out of keyboardProfiles.ts (ts-src 600-line hard cap): the row
//  builders and the Family/OS_FAMILY tables are one concern and live there;
//  this file (plus its two halves, keyboardProfiles.data.pc.ts and
//  keyboardProfiles.data.exotic.ts — PROFILES itself is too big for one
//  600-line file) is the other concern, the actual per-family key layouts
//  built from those builders. See keyboardProfiles.ts for the wire-rule
//  notes that govern every keysym in either half.
// ============================================================================

import type { KeyboardProfile } from './keyTypes';
import type { Family } from './keyboardProfiles';
import { OS_FAMILY } from './keyboardProfiles';
import { PROFILES_PC } from './keyboardProfiles.data.pc';
import { PROFILES_EXOTIC } from './keyboardProfiles.data.exotic';

// PcFamily and ExoticFamily partition Family; the explicit Record<Family, …>
// annotation below is what makes a missing or duplicated family a compile
// error, same guarantee the single-object literal had before the split.
export const PROFILES: Record<Family, KeyboardProfile> = {
  ...PROFILES_PC,
  ...PROFILES_EXOTIC,
};

export function keyboardProfileFor(osId: string): KeyboardProfile {
  return PROFILES[OS_FAMILY[osId] ?? 'generic'];
}

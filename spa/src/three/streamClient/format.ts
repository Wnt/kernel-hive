// ============================================================================
//  streamClient/format — pure numeric clamps + H.264 profile/level/preset
//  formatting helpers. No streamhost state; safe to unit-test in isolation.
//  codecStringFor / profileName / levelName / presetName are part of the public
//  streamClient API (re-exported from streamClient.ts, consumed by the HUD).
// ============================================================================

export const clampU16 = (n: number) => (n < 0 ? 0 : n > 0xffff ? 0xffff : Math.round(n));
export const clampI16 = (n: number) => (n < -32768 ? -32768 : n > 32767 ? 32767 : Math.round(n));

export const clamp0100 = (n: number) => (n < 0 ? 0 : n > 100 ? 100 : n);
const hex2 = (n: number) => (n & 0xff).toString(16).padStart(2, '0');

/**
 * Build the WebCodecs codec string from an H.264 profile_idc + level_idc.
 *   baseline(66) → constraint_flags e0 (constrained baseline) → avc1.42e0<lvl>
 *   main(77)     → avc1.4d00<lvl>
 *   high(100)    → avc1.6400<lvl>
 * The constraint-flags byte is the standard value each profile ships with, so the
 * resulting string matches what Chrome's VideoDecoder expects for the SPS.
 */
export function codecStringFor(profileIdc: number, levelIdc: number): string {
  const constraint = profileIdc === 66 ? 0xe0 : 0x00;
  return `avc1.${hex2(profileIdc)}${hex2(constraint)}${hex2(levelIdc)}`;
}

/** Human profile name from profile_idc. */
export function profileName(profileIdc: number): string {
  return profileIdc === 66 ? 'Baseline' : profileIdc === 77 ? 'Main' : profileIdc === 100 ? 'High' : `P${profileIdc}`;
}

/** "4.0" from level_idc 0x28; H.264 encodes level×10 in level_idc. */
export function levelName(levelIdc: number): string {
  return (levelIdc / 10).toFixed(1);
}

/** libx264 preset name from the preset_enum (0=ultrafast..8=veryslow). */
export function presetName(e: number): string {
  return ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'][e] ?? `p${e}`;
}

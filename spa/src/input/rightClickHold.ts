// ============================================================================
//  input/rightClickHold — SYNTHETIC right-button hold duration.
//  ---------------------------------------------------------------------------
//  When the S-Pen barrel arrives ONLY as a native contextmenu (Samsung S-Pen), the
//  UI synthesizes a guest right-click (button-2 down then up). Motif/CDE's sticky
//  Workspace Menu (Solaris) only POSTS if the right button is HELD a
//  few tens of ms — a 0 ms down→up click never posts it. Windows shows its context
//  menu on release regardless, so a hold is harmless there. This module owns that
//  hold for the StreamView input surface.
//
//  The Motif post/unpost timing is device-/scheduling-noisy, so the hold is tunable
//  at runtime WITHOUT a rebuild/redeploy via  window.__osgRightHoldMs = <ms>  — used
//  to calibrate against the live guest; it falls back to the verified default.
// ============================================================================

const DEFAULT_MS = 70;

/** Milliseconds to hold a synthetic guest right-button down between down and up. */
export function rightHoldMs(): number {
  try {
    const o = (window as unknown as { __osgRightHoldMs?: unknown }).__osgRightHoldMs;
    if (typeof o === 'number' && o >= 0 && o <= 2000) return o;
  } catch { /* SSR / no window */ }
  return DEFAULT_MS;
}

// StreamView environment gates + tuning constants — extracted verbatim.

// Defensive pointer-lock spike clamp. Chrome routinely emits one bogus multi-
// hundred-px movementX/Y on lock-engage/disengage and some focus transitions;
// any single-event delta larger than this (px) is dropped so the virtual cursor
// never teleports. (GFN ports a full velocity-EWMA spike filter; a hard cap is
// the pragmatic equivalent for our single-accumulator absolute path.)
export const MAX_LOCK_DELTA = 300;

// (supportsRawUpdate + the coalesced-sample handling moved to the SHARED
//  src/input/moveSamples.ts.)

// ---------------------------------------------------------------------------
//  DIRECT-CANVAS RENDER GATE (measured 2026-07-13, reactos, glass-to-glass rig)
//  ---------------------------------------------------------------------------
//  For streamhost stations we can paint decoded frames EITHER to a captureStream →
//  <video> (default) OR straight to a visible <canvas> (paint-on-decode). A
//  browser-photon A/B (N=60 Chrome, N=32 Firefox, interleaved to cancel box
//  drift) showed the two engines diverge:
//    Firefox  video 64.1ms / canvas 49.0ms median  → canvas WINS ~15ms (+p95)
//    Chrome   video 87.0ms / canvas 96.4ms median  → canvas LOSES ~9ms
//  Chrome composites a MediaStream <video> as a hardware overlay (very low
//  latency); Firefox's captureStream→<video> presentation buffers ~a frame, which
//  the direct canvas skips. So we take the direct canvas ONLY on Firefox and keep
//  Chrome on its faster overlay <video> — a strict win in both engines, no
//  regression. (Re-measure with the rig if this ever needs revisiting.)
export const isFirefoxEngine =
  typeof navigator !== 'undefined' && /firefox/i.test(navigator.userAgent);

// Coarse-pointer gate for the local pinch-zoom feature (Item 5) — a phone/tablet,
// not a per-station archetype. TouchEvent presence + a coarse pointer.
export function isTouchDevice(): boolean {
  if (typeof window === 'undefined') return false;
  const coarse = !!window.matchMedia && window.matchMedia('(any-pointer:coarse)').matches;
  return !!(window as unknown as { TouchEvent?: unknown }).TouchEvent && coarse;
}

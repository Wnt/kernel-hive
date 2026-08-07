// ============================================================================
//  input/moveSamples — pointer-move sample resolution for StreamView input.
//  ---------------------------------------------------------------------------
//  Chromium does not re-project `pointerrawupdate`/getCoalescedEvents() sample
//  clientX/Y into the layout viewport while the page is browser-pinch-zoomed
//  (visualViewport.scale > 1) — but getBoundingClientRect() IS layout-viewport
//  based, so mapping those samples mis-lands guest coordinates exactly while
//  zoomed. The proven-correct surface under zoom is the NATIVE `pointermove`
//  event coordinate (the same surface as the always-correct pointerdown/up
//  path). StreamView resolves move samples through this helper:
//    - not pinched: the full coalesced fan-out (true device sample rate)
//    - pinched:     the native event only
//  The event wiring applies the matching source gate:
//    pointermove       → forward when !supportsRawUpdate || pinched()
//    pointerrawupdate  → forward when !pinched()
//  The viewport meta (index.html) suppresses page pinch-zoom outright, but
//  accessibility-forced zoom bypasses it — so the runtime gate stays.
// ============================================================================

/** Minimal coordinate view of a PointerEvent (keeps the core pure/testable). */
export interface MoveSample { clientX: number; clientY: number; }

export const supportsRawUpdate =
  typeof window !== 'undefined' && 'onpointerrawupdate' in window;

/** True while the page is browser-pinch-zoomed (visual viewport scale > 1). */
export function pinched(): boolean {
  if (typeof window === 'undefined') return false;
  return (window.visualViewport?.scale ?? 1) > 1.001;
}

/** PURE core: pick the samples to forward for one native move event —
 *  the coalesced fan-out normally, the native event alone while pinched
 *  (coalesced coords are the un-reprojected surface) or when no coalesced
 *  samples exist. */
export function pickMoveSamples<T extends MoveSample>(
  native: T,
  coalesced: readonly T[] | null,
  isPinched: boolean,
): readonly T[] {
  if (isPinched || !coalesced || coalesced.length === 0) return [native];
  return coalesced;
}

/** DOM wrapper: resolve the samples for one native pointer event. */
export function resolveMoveSamples(native: PointerEvent): readonly MoveSample[] {
  const coalesced =
    typeof native.getCoalescedEvents === 'function' ? native.getCoalescedEvents() : null;
  return pickMoveSamples(native, coalesced, pinched());
}

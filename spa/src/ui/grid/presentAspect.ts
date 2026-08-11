// ============================================================================
//  PER-STATION PRESENTATION ASPECT  (UI-only, hand-authored — NOT generated)
//  ---------------------------------------------------------------------------
//  A handful of vintage / emulator-kiosks have NON-SQUARE-PIXEL native
//  framebuffers that, on a period 4:3 CRT, were stretched to FILL the tube edge
//  to edge (that is how they were designed to look). The UI otherwise presents
//  every station square-pixel via `object-fit: contain`, which fits the raw pixel
//  aspect and letterboxes these (side / top bands + a wrong, squished shape).
//
//  This module is the OPT-IN override: it maps an osId to the DISPLAY aspect the
//  picture should fill. StreamView presents such a station inside a box of this
//  aspect (fitted into the stage in both orientations) and STRETCHES the
//  framebuffer to fill it (object-fit:fill) — the era-correct CRT look.
//
//  DISPLAY-ONLY. Pointer mapping still uses the stream's REAL resolution
//  (letterbox.clientToGuest with fill=true maps u/v across the full display box
//  back to guest pixels), so clicks land exactly where the cursor is regardless
//  of the stretch.
//
//  Same shape as guestQuirks.quirksFor / keyboardProfiles: a plain per-id record
//  with a null fallback so every other station keeps today's `contain` behaviour.
//  Follows the "no registry-source / generated-file edit" rule — the generated
//  archetypeRegistry stays untouched.
// ============================================================================

/** A display aspect ratio expressed as width:height (a THREE-free {w,h} pair). */
export interface PresentAspect {
  w: number;
  h: number;
}

// The six non-square-pixel stations whose framebuffers filled a 4:3 CRT:
//   c64 320x200, atarist 640x400, apple2 560x192, amiga 640x256,
//   msdoswin1 640x350, freedos 720x400.
// All present at 4:3 (the historically-correct CRT display aspect); the stretch
// is intentional — it restores the era-correct pixel aspect the raw framebuffer
// only approximates with square pixels.
const PRESENT_ASPECT: Record<string, PresentAspect> = {
  c64: { w: 4, h: 3 },
  atarist: { w: 4, h: 3 },
  apple2: { w: 4, h: 3 },
  amiga: { w: 4, h: 3 },
  msdoswin1: { w: 4, h: 3 },
  freedos: { w: 4, h: 3 },
  // irix is the odd one out: not a CRT-stretch station at all, but a PIN. The SGI
  // Indy's XL graphics drove a 5:4 1280x1024 monitor, and the emulated Newport
  // framebuffer is actually **1288x1024** — IRIX programs the VC2 with eight
  // extra columns of overscan a real monitor never showed. Presenting the raw
  // 1288:1024 (1.258) would show them and stretch the desktop by 0.6%. Pinning
  // 5:4 is exactly today's picture (the x11 capture path already delivers a
  // 1280-wide window-scaled frame) and stays right when the shm capture backend
  // starts delivering the true 1288-wide framebuffer.
  irix: { w: 5, h: 4 },
};

/** The era-correct display aspect for this station, or null to keep `contain`. */
export function presentAspectFor(osId: string): PresentAspect | null {
  return PRESENT_ASPECT[osId] ?? null;
}

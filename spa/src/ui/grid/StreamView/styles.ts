import type { CSSProperties } from 'react';

export const SPIN_KEYFRAMES = '@keyframes sv-spin { to { transform: rotate(360deg); } }';

// Real `:fullscreen` rules — inline styles cannot express a pseudo-class, so the
// TRUE browser-fullscreen fill lives here. When the container is the fullscreen
// element it fills the physical screen and the video is object-fit:contain over
// black (letterbox bars are fine). Covers both the unprefixed and webkit pseudos.
export const FS_CSS = `
.sv-root:fullscreen, .sv-root:-webkit-full-screen {
  width: 100vw; height: 100vh; background: #000;
}
.sv-root:fullscreen .sv-video, .sv-root:-webkit-full-screen .sv-video {
  width: 100%; height: 100%; object-fit: contain; background: #000;
}
/* CINEMA MAT. Windowed, the letterbox around the picture is the gallery's paper
   (S.stage) — the app has one light scheme. TRUE fullscreen is the exception on
   purpose: bright bars around a dark guest screen are glare, so the mat goes
   black here. !important because S.stage carries an inline background, which a
   plain rule cannot outrank. */
.sv-root:fullscreen .sv-stage, .sv-root:-webkit-full-screen .sv-stage {
  background: #000 !important;
}
/* Neutralize any UA letterbox on the media element itself in FS. */
.sv-root:fullscreen video::-webkit-media-controls { display: none !important; }
/* WHOLE-MOUSE CAPTURE cursor hide, scoped to the state where it is TRUE: only
   while the pointer is actually locked (data-locked), which is also the only
   state where the UA hides it natively. Fullscreen alone no longer hides it —
   it used to key off [data-fs][data-capture], so every unlocked moment of a
   fullscreen session (the lock rejected, or dropped by Esc) left the picture
   with an INVISIBLE pointer. Unlocked fullscreen now keeps exactly the windowed
   crosshair (S.video), so there is never a state where you cannot see what you
   are pointing at. */
.sv-root[data-locked="1"] .sv-video { cursor: none !important; }
`;

// ---------------------------------------------------------------------------
//  COLD-BOOT CRT power-on animation (see PowerOnOverlay). Keyframes must live in
//  a stylesheet (inline styles cannot express @keyframes / pseudo-elements), so
//  the whole effect is a scoped CSS string injected next to FS_CSS.
// ---------------------------------------------------------------------------
export const POWER_ON_CSS = `
/* The tube: black raster that snaps on from a flyback line and blooms to full. */
.pw-crt .pw-tube {
  transform-origin: 50% 50%;
  animation: pw-on 1150ms cubic-bezier(0.16, 0.9, 0.32, 1) both;
}
/* Warm phosphor breathing + a faint mains flicker while connecting. */
.pw-crt .pw-vig { animation: pw-flicker 3.2s ease-in-out 1.1s infinite; }
.pw-crt .pw-scan { animation: pw-roll 8s linear 1.1s infinite; }
/* Power LED soft pulse. */
.pw-crt .pw-led { animation: pw-pulse 1.5s ease-in-out infinite; }
/* Placard fades in only after the raster has opened. */
.pw-crt .pw-card { animation: pw-cardin 700ms ease-out 620ms both; }

/* First live frame → degauss bloom + fade the whole overlay away. */
.pw-crt.pw-reveal .pw-tube { animation: pw-reveal 820ms ease-in forwards; }
.pw-crt.pw-reveal .pw-card { opacity: 0; transition: opacity 220ms ease-out; }

/* Error / no-signal: hold a dim steady raster (no reveal), red-ish LED handled inline. */
.pw-crt.pw-fault .pw-vig { animation: none; }

@keyframes pw-on {
  0%   { transform: scaleX(1.35) scaleY(0.0016); filter: brightness(3.6) saturate(1.4); opacity: 0; }
  3%   { opacity: 1; }
  9%   { transform: scaleX(1.2) scaleY(0.0042); filter: brightness(3.1); opacity: 1; }
  22%  { transform: scaleX(1) scaleY(1); filter: brightness(1.7); }
  45%  { filter: brightness(1.06); }
  100% { transform: scaleX(1) scaleY(1); filter: brightness(1); opacity: 1; }
}
@keyframes pw-reveal {
  0%   { opacity: 1; filter: brightness(1); }
  28%  { opacity: 1; filter: brightness(2.3) saturate(1.3); }
  100% { opacity: 0; filter: brightness(3.4); transform: scale(1.012); }
}
@keyframes pw-flicker {
  0%, 100% { opacity: 1; }
  47% { opacity: 0.94; }
  50% { opacity: 0.87; }
  53% { opacity: 0.96; }
}
@keyframes pw-roll {
  0% { background-position-y: 0; }
  100% { background-position-y: 100vh; }
}
@keyframes pw-pulse {
  0%, 100% { box-shadow: 0 0 4px currentColor, 0 0 10px currentColor; opacity: 1; }
  50%      { box-shadow: 0 0 2px currentColor; opacity: 0.55; }
}
@keyframes pw-cardin {
  from { opacity: 0; transform: translateY(6px); }
  to   { opacity: 1; transform: none; }
}

/* Reduced-motion: no CRT collapse/expand or roll — a calm fade only. */
@media (prefers-reduced-motion: reduce) {
  .pw-crt .pw-tube { animation: pw-fadein 400ms ease-out both; }
  .pw-crt .pw-scan, .pw-crt .pw-vig, .pw-crt .pw-card { animation: none; }
  .pw-crt.pw-reveal .pw-tube { animation: pw-fadeout 400ms ease-in forwards; }
  @keyframes pw-fadein { from { opacity: 0; } to { opacity: 1; } }
  @keyframes pw-fadeout { from { opacity: 1; } to { opacity: 0; } }
}
`;

// ---------------------------------------------------------------------------
//  ERA-CORRECT 4:3 PRESENTATION (presentAspect.ts) — scoped size-container.
//  ---------------------------------------------------------------------------
//  Only the six non-square-pixel stations opt in (data-present-fill="1"), so the
//  size containment is scoped to THOSE sessions and never touches the shared
//  stage sizing of any other station. Making the stage a `container-type: size`
//  container is what lets its <video>/<canvas> size itself in container units
//  (cqw/cqh) to an exact 4:3 box that fits the stage in BOTH orientations — the
//  robust, orientation-safe way to size a fitted box with pure CSS. The picture
//  element then object-fit:fill-stretches the framebuffer to fill that box (its
//  inline style; wins over the FS_CSS `contain` rule in fullscreen too).
// ---------------------------------------------------------------------------
export const PRESENT_CSS = `
.sv-root[data-present-fill="1"] .sv-stage { container-type: size; }
`;

// Inline size+fit for an era-correct 4:3 station: size the picture element to an
// exact display-aspect box (container units against the size-container stage, so
// it fits in BOTH orientations), then object-fit:fill-stretch the framebuffer to
// fill it. Merged AFTER S.video so it overrides width/height/object-fit; the
// element's own rect is this box, keeping the pointer map (fill mode) exact.
export function presentFillStyle(present: { w: number; h: number }): CSSProperties {
  return {
    width: `min(100cqw, calc(100cqh * ${present.w} / ${present.h}))`,
    height: `min(100cqh, calc(100cqw * ${present.h} / ${present.w}))`,
    objectFit: 'fill',
  };
}

// ---------------------------------------------------------------------------
//  Inline styles for the OS view. Layout is self-contained (no dependency on the
//  grid CSS), but the COLOURS are the museum-daylight tokens from index.css —
//  one palette for the whole site, defined in exactly one place. Dark values
//  below are never chrome: they belong to pictures of screens (the guest
//  picture, the cold-boot CRT tube), which are dark because a screen is.
// ---------------------------------------------------------------------------
export const S: Record<string, CSSProperties> = {
  root: {
    position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column',
    background: 'var(--paper)', color: 'var(--ink)', zIndex: 40,
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif',
  },
  // ---- STAGE MENU (StageMenu) — the only chrome. The back escape sits alone
  // in the stage's top-left corner; the info button and hamburger (plus the
  // panel behind it) sit in the top-right. Safe-area insets keep both clear of
  // a notch / rounded corner in iOS landscape.
  backWrap: {
    position: 'absolute', zIndex: 60,
    top: 'max(10px, env(safe-area-inset-top))',
    left: 'max(10px, env(safe-area-inset-left))',
    display: 'flex', alignItems: 'center', gap: 6,
  },
  menuWrap: {
    position: 'absolute', zIndex: 60,
    top: 'max(10px, env(safe-area-inset-top))',
    right: 'max(10px, env(safe-area-inset-right))',
    // A ROW: the info button, then the hamburger. The panel below is
    // positioned against this box, so it still hangs from the corner however
    // many buttons sit in the row.
    display: 'flex', alignItems: 'center', gap: 6,
  },
  menuBtn: {
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    minWidth: 44, minHeight: 44, padding: '6px 12px',
    borderRadius: 10, border: '1px solid var(--line)',
    background: 'rgba(251,249,243,0.9)', backdropFilter: 'blur(8px)',
    boxShadow: '0 6px 20px rgba(20,16,10,0.22)',
    color: 'var(--ink)', fontSize: 18, lineHeight: 1, cursor: 'pointer',
  },
  menuPanel: {
    position: 'absolute', top: '100%', right: 0, marginTop: 6, zIndex: 61,
    minWidth: 244, display: 'flex', flexDirection: 'column', gap: 2, padding: 6,
    borderRadius: 10, background: 'rgba(251,249,243,0.97)',
    border: '1px solid var(--line)', backdropFilter: 'blur(8px)',
    boxShadow: 'var(--shadow-2)',
  },
  menuHead: {
    display: 'flex', alignItems: 'center', gap: 8,
    padding: '6px 12px 8px', borderBottom: '1px solid var(--line)', marginBottom: 4,
  },
  menuHeadText: {
    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
    fontSize: 13, fontWeight: 700, color: 'var(--ink)',
  },
  // 44px minimum touch target (T-2) — the WCAG / platform floor for a
  // comfortable tap, and the same size a mouse wants for a menu row.
  menuItem: {
    display: 'flex', alignItems: 'center', gap: 8, minHeight: 44, width: '100%',
    padding: '6px 12px', borderRadius: 8, border: '1px solid transparent',
    background: 'transparent', color: 'var(--ink)', fontSize: 14,
    cursor: 'pointer', textAlign: 'left', whiteSpace: 'nowrap',
  },
  menuItemOff: { opacity: 0.45, cursor: 'default' },
  dot: { width: 9, height: 9, borderRadius: '50%', boxShadow: '0 0 6px currentColor' },
  btnOn: { background: 'var(--accent-wash)', borderColor: 'var(--accent-line)', color: 'var(--accent-ink)' },
  btnErr: { background: 'rgba(178,58,44,0.12)', borderColor: 'rgba(178,58,44,0.45)', color: 'var(--danger)' },
  // The mat the picture is hung on: gallery paper windowed, cinema black in true
  // fullscreen (FS_CSS). The <video>/<canvas> itself paints nothing behind the
  // frame so the mat shows through the letterbox in both modes.
  stage: {
    position: 'relative', flex: 1, minHeight: 0, display: 'flex',
    alignItems: 'center', justifyContent: 'center', background: 'var(--paper-sunken)',
    // overscrollBehavior:none kills pull-to-refresh / edge back-swipe over the
    // picture (T-2); the .sv-root mobileCss rule backstops the whole view.
    overflow: 'hidden', touchAction: 'none', overscrollBehavior: 'none',
    // A long press is the trackpad's DRAG, and Chrome-Android answers a long
    // press by starting a text selection — handles, callout and all — over the
    // exhibit. touch-action does not cover that and neither does
    // preventDefault() on pointerdown: the selection is the UA acting on the
    // touch sequence itself, and only user-select can decline it. There is
    // nothing here anyone would want to select.
    userSelect: 'none', WebkitUserSelect: 'none', WebkitTouchCallout: 'none',
  },
  video: {
    width: '100%', height: '100%', objectFit: 'contain', display: 'block',
    background: 'transparent', touchAction: 'none', cursor: 'crosshair',
    imageRendering: 'pixelated' as CSSProperties['imageRendering'],
  },
  overlay: {
    position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column',
    alignItems: 'center', justifyContent: 'center', gap: 12,
    background: 'radial-gradient(circle at 50% 45%, rgba(248,246,240,0.92), rgba(226,221,208,0.96))',
    pointerEvents: 'none', textAlign: 'center', padding: 20,
  },
  spinner: {
    width: 34, height: 34, borderRadius: '50%',
    border: '3px solid var(--tint-2)', borderTopColor: 'var(--accent)',
    animation: 'sv-spin 0.9s linear infinite',
  },
  overlayText: { margin: 0, fontSize: 15, color: 'var(--ink)' },
  overlaySub: { margin: 0, fontSize: 12, color: 'var(--ink-muted)' },
  // ---- COLD-BOOT CRT power-on overlay (PowerOnOverlay) ----
  // Deliberately dark in the light gallery: this is a picture of a monitor
  // warming up, and its whole effect is a black raster blooming into phosphor.
  // The placard type sits ON that raster, so it stays lit rather than inked.
  pwRoot: {
    position: 'absolute', inset: 0, background: '#000',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    pointerEvents: 'none', overflow: 'hidden', zIndex: 5,
  },
  pwTube: {
    position: 'absolute', inset: 0,
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    // Warm phosphor bloom from the centre — the "screen is alive" glow.
    background:
      'radial-gradient(120% 90% at 50% 48%, rgba(70,86,74,0.55) 0%, rgba(26,32,30,0.7) 34%, rgba(4,6,8,0.96) 78%)',
    willChange: 'transform, opacity, filter',
  },
  pwScan: {
    position: 'absolute', inset: 0, pointerEvents: 'none', mixBlendMode: 'overlay',
    // Fine CRT scanlines (the roll animation drifts them slowly downward).
    background:
      'repeating-linear-gradient(to bottom, rgba(0,0,0,0) 0px, rgba(0,0,0,0) 2px, rgba(0,0,0,0.28) 3px, rgba(0,0,0,0) 4px)',
    backgroundSize: '100% 4px',
    opacity: 0.6,
  },
  pwVig: {
    position: 'absolute', inset: 0, pointerEvents: 'none',
    background:
      'radial-gradient(130% 120% at 50% 50%, rgba(0,0,0,0) 52%, rgba(0,0,0,0.55) 88%, rgba(0,0,0,0.85) 100%)',
    boxShadow: 'inset 0 0 120px rgba(0,0,0,0.9)',
  },
  pwCard: {
    position: 'relative', display: 'flex', flexDirection: 'column',
    alignItems: 'center', gap: 6, textAlign: 'center', padding: '0 24px',
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    textShadow: '0 0 12px rgba(0,0,0,0.8)',
  },
  pwLed: {
    width: 9, height: 9, borderRadius: '50%', marginBottom: 4,
  },
  pwName: {
    fontSize: 17, fontWeight: 700, letterSpacing: 1.2, textTransform: 'uppercase',
    color: '#f2f5ee',
  },
  pwStatus: {
    fontSize: 13, letterSpacing: 2, textTransform: 'uppercase',
    color: 'rgba(210,224,206,0.72)',
  },
  pwEra: { fontSize: 11, letterSpacing: 0.5, color: 'rgba(210,224,206,0.42)' },
  // ---- BOOT-VIDEO REPLAY controls (BootVideoOverlay) ----
  // Keep the recorded and live media in the exact same stage-sized box. The boot
  // overlay also contains controls; absolute positioning prevents those siblings
  // from shrinking or offsetting the video in the overlay's flex layout.
  bootVideo: { position: 'absolute', inset: 0 },
  // Bottom control strip. pointerEvents auto so scrub/rate work while the root
  // stays 'none' (click-to-acquire passes through to the media beneath).
  bootControls: {
    position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 6,
    display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 16px 14px',
    pointerEvents: 'auto',
    // A paper scrim over the clip, so the controls read as gallery chrome laid
    // on the picture rather than a second, darker UI.
    background: 'linear-gradient(to top, rgba(243,240,231,0.94), rgba(243,240,231,0))',
  },
  bootRate: { display: 'flex', gap: 6, justifyContent: 'center' },
  bootRateBtn: {
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    fontSize: 12, lineHeight: 1, padding: '4px 9px', borderRadius: 6,
    border: '1px solid var(--line)', background: 'rgba(251,249,243,0.92)',
    color: 'var(--ink-soft)', cursor: 'pointer',
  },
  bootRateOn: {
    background: 'var(--accent-wash)', borderColor: 'var(--accent-line)',
    color: 'var(--accent-ink)',
  },
  // Positioning context for the floating thumbnail preview.
  bootBar: { position: 'relative', width: '100%' },
  bootScrub: {
    width: '100%', height: 18, margin: 0, cursor: 'pointer',
    accentColor: 'var(--accent)', touchAction: 'none', display: 'block',
  },
  scrubPreview: {
    position: 'absolute', bottom: 26, zIndex: 7, pointerEvents: 'none',
    backgroundRepeat: 'no-repeat', borderRadius: 4,
    border: '1px solid var(--line-strong)',
    boxShadow: '0 6px 18px rgba(20,16,10,0.35)',
  },
  // DEBUG OVERLAY — compact corner HUD, monospace. Top-left like the stage menu,
  // so it starts one hamburger below it (44px button + 10px inset + 8px gap)
  // instead of under it. Safe-area floor so it clears a notch / home-indicator
  // in fullscreen; env() resolves to 0 on non-notched devices.
  debug: {
    position: 'absolute',
    top: 'calc(max(10px, env(safe-area-inset-top)) + 52px)',
    left: 'max(10px, env(safe-area-inset-left))',
    zIndex: 70,
    minWidth: 190, padding: '10px 12px', borderRadius: 10,
    background: 'rgba(251,249,243,0.92)', border: '1px solid rgba(47,109,156,0.35)',
    backdropFilter: 'blur(8px)', boxShadow: '0 8px 30px rgba(20,16,10,0.25)',
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    fontSize: 12, color: 'var(--ink)', pointerEvents: 'none',
  },
  debugTitle: {
    fontSize: 11, letterSpacing: 0.4, textTransform: 'uppercase',
    color: 'var(--info)', marginBottom: 6, whiteSpace: 'nowrap',
  },
  debugRow: { display: 'flex', justifyContent: 'space-between', gap: 16, lineHeight: 1.6 },
  debugKey: { color: 'var(--ink-muted)' },
  debugVal: { color: 'var(--ink)', fontVariantNumeric: 'tabular-nums' },
  debugHint: { marginTop: 6, fontSize: 10, color: 'var(--ink-muted)' },
  // FULLSCREEN HINT TOAST — centered top, auto-dismissing.
  hintToast: {
    position: 'absolute', top: 18, left: '50%', transform: 'translateX(-50%)',
    zIndex: 65, padding: '8px 16px', borderRadius: 999,
    background: 'rgba(251,249,243,0.94)', border: '1px solid var(--line)',
    backdropFilter: 'blur(8px)', color: 'var(--ink)', fontSize: 13, whiteSpace: 'nowrap',
    boxShadow: '0 6px 24px rgba(20,16,10,0.28)', pointerEvents: 'none',
  },
  fsErrorToast: {
    top: 'auto', bottom: 18,
    background: 'rgba(250,238,236,0.96)', border: '1px solid rgba(178,58,44,0.5)',
    color: 'var(--danger)',
  },
  // GFN-STYLE CONNECTION BANNER — top-centre pill, distinct from the hint toast.
  banner: {
    position: 'absolute', top: 18, left: '50%', transform: 'translateX(-50%)',
    zIndex: 68, display: 'inline-flex', alignItems: 'center', gap: 8,
    padding: '7px 15px', borderRadius: 999, fontSize: 13, fontWeight: 600,
    backdropFilter: 'blur(8px)', boxShadow: '0 6px 24px rgba(20,16,10,0.28)',
    pointerEvents: 'none', whiteSpace: 'nowrap',
  },
  bannerSpotty: {
    background: 'rgba(250,243,225,0.96)', border: '1px solid rgba(143,100,7,0.55)', color: 'var(--warn)',
  },
  bannerReconnecting: {
    background: 'rgba(250,238,236,0.96)', border: '1px solid rgba(178,58,44,0.55)', color: 'var(--danger)',
  },
  bannerDecoderUnsupported: {
    maxWidth: 'min(520px, calc(100vw - 28px))', whiteSpace: 'normal', textAlign: 'center',
    lineHeight: 1.35,
  },
  bannerFallbackDot: {
    flex: '0 0 auto', animation: 'none',
  },
  // Device-caused "spotty" (Item 6 disambiguation) — a cool violet, visually
  // distinct from the amber NETWORK spotty so the cause reads at a glance.
  bannerDevice: {
    background: 'rgba(242,238,250,0.96)', border: '1px solid rgba(96,70,168,0.5)', color: '#5a3f9e',
  },
  // DISTINCT DEVICE/STALL CHIP STACK (Items 4 + 6) — top-right, away from the
  // top-centre network banner and the top-left debug HUD.
  chipStack: {
    position: 'absolute', top: 'max(14px, env(safe-area-inset-top))',
    right: 'max(14px, env(safe-area-inset-right))', zIndex: 69,
    display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 6,
    pointerEvents: 'none',
  },
  chip: {
    display: 'inline-flex', alignItems: 'center', gap: 7,
    padding: '6px 12px', borderRadius: 999, fontSize: 12.5, fontWeight: 600,
    backdropFilter: 'blur(8px)', boxShadow: '0 6px 20px rgba(20,16,10,0.22)',
    whiteSpace: 'nowrap',
  },
  chipDot: {
    width: 7, height: 7, borderRadius: '50%', background: 'currentColor',
    boxShadow: '0 0 7px currentColor',
  },
  chipLoad: {
    background: 'rgba(242,238,250,0.94)', border: '1px solid rgba(96,70,168,0.45)', color: '#5a3f9e',
  },
  chipBattery: {
    background: 'rgba(250,243,225,0.94)', border: '1px solid rgba(143,100,7,0.45)', color: 'var(--warn)',
  },
  chipStall: {
    background: 'rgba(233,241,248,0.94)', border: '1px solid rgba(47,109,156,0.45)', color: 'var(--info)',
  },
  // Explicit LOCAL decoder failure (WebCodecs configure/decode loop) — red so
  // it never reads as the blue network-ish stall chip.
  chipDecoderFail: {
    background: 'rgba(250,238,236,0.96)', border: '1px solid rgba(178,58,44,0.5)', color: 'var(--danger)',
  },
  bannerDot: {
    width: 8, height: 8, borderRadius: '50%', background: 'currentColor',
    boxShadow: '0 0 6px currentColor', animation: 'sv-spin 1.4s linear infinite',
  },
  // Manual RECONNECT button inside the reconnecting banner (T-5). The banner
  // itself stays pointerEvents:none (display-only); only this button is tappable,
  // with a comfortable 44px touch target.
  bannerReconnectBtn: {
    pointerEvents: 'auto', marginLeft: 6, minHeight: 34, padding: '5px 12px',
    borderRadius: 999, border: '1px solid currentColor',
    background: 'rgba(255,255,255,0.55)', color: 'inherit', font: 'inherit',
    fontWeight: 700, cursor: 'pointer', whiteSpace: 'nowrap',
  },
  // CLICK-TO-RESUME overlay — a full-stage transparent button so a click anywhere
  // re-acquires the pointer lock. Centered card gives the affordance a target.
  resumeOverlay: {
    // Below the floating bar (z60) so revealed Exit/Fullscreen buttons stay
    // clickable; above the picture so a click anywhere else re-acquires the lock.
    position: 'absolute', inset: 0, zIndex: 55,
    display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
    gap: 6, cursor: 'pointer', textAlign: 'center',
    background: 'radial-gradient(circle at 50% 45%, rgba(248,246,240,0.72), rgba(226,221,208,0.86))',
    border: 'none', color: 'var(--ink)', font: 'inherit',
    padding: 0, width: '100%', height: '100%',
  },
  resumeBadge: {
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    width: 64, height: 64, borderRadius: '50%', marginBottom: 8,
    background: 'var(--accent-wash)', border: '1px solid var(--accent-line)',
    fontSize: 24, color: 'var(--accent-ink)',
  },
  resumeSub: { marginTop: 4, fontSize: 13, color: 'var(--ink-muted)' },
  poster: {
    display: 'flex', flexDirection: 'column', alignItems: 'center',
    justifyContent: 'center', gap: 10, textAlign: 'center', padding: 32,
    width: '100%', height: '100%',
  },
  posterBadge: {
    padding: '3px 10px', borderRadius: 999, border: '1px solid',
    fontSize: 12, letterSpacing: 1, textTransform: 'uppercase',
  },
  posterTitle: { margin: '6px 0 0', fontSize: 30, fontWeight: 700, color: 'var(--ink)' },
  posterEra: { margin: 0, fontSize: 14, color: 'var(--ink-muted)' },
  posterNote: { margin: '10px 0 0', maxWidth: 460, fontSize: 13.5, lineHeight: 1.5, color: 'var(--ink-soft)' },
  // COMPACT (mobile) toolbar: a THIN single row that never wraps; position
  // context for the ⋯ overflow dropdown. Safe-area paddings as barFloating.
  barCompact: {
    flexWrap: 'nowrap', minHeight: 48, position: 'relative',
    paddingTop: 'max(8px, env(safe-area-inset-top))',
    paddingLeft: 'max(10px, env(safe-area-inset-left))',
    paddingRight: 'max(10px, env(safe-area-inset-right))',
  },
  // Status pill in the compact bar: ellipsize instead of wrapping the bar.
  statusTrunc: { maxWidth: '34vw', overflow: 'hidden', minWidth: 0 },
};

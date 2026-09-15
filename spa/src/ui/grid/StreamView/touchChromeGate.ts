// touchChromeGate — whether the right-click arm (TouchControlBadge) and the
// keyboard opener (KeyboardToggleBadge) should mount at all.
//
// On the full station view (`mobile`, not `docked`) they are the only route
// to right-click and the on-screen keyboard on a touch exhibit, so they stay.
// On the landing page's mini display (`docked`) a DESKTOP visitor has a real
// mouse (right-click works natively) and a real keyboard (keys go straight
// through) — the badges are pure clutter there, so they render only when the
// device actually has a coarse pointer to arm (touchCapable, env.ts). A
// touch-capable device that is docked but not `mobile` (an S-Pen tablet, say:
// fine primary pointer, coarse touch surface) still needs the arm.
export function showsTouchChrome(i: {
  mobile: boolean;
  docked: boolean;
  touchCapable: boolean;
}): boolean {
  return i.mobile || (i.docked && i.touchCapable);
}

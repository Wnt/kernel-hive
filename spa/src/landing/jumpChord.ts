// The chord chip on the landing header's jump-to-the-collection button.
//
// It read ⌘K on every device, and that is a claim about the visitor's keyboard.
// An Android phone has no Command key — the chip named a chord that could not
// be pressed at all, on the device the page is most often first seen on. A
// Linux or Windows desktop has no Command key either, though the shortcut does
// work there, on Ctrl (LandingHeader accepts metaKey OR ctrlKey).
//
// `null` means this device has no chord to offer. The caller then shows the
// button's own words instead, so the button is never an empty pill.

export function jumpChord(i: { platform: string; coarsePrimary: boolean }): string | null {
  // A coarse primary pointer is a finger: the affordance is a tap, not a chord,
  // whatever keyboard might also be attached.
  if (i.coarsePrimary) return null;
  return /mac|iphone|ipad|ipod/i.test(i.platform) ? '⌘K' : 'Ctrl K';
}

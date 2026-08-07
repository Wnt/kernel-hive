// Which keyboard events carry a COMPOSED character rather than a modifier chord.
//
// Extracted from useStreamControl so the rule is unit-testable: it is layout- and
// platform-dependent, invisible in code review, and its failure mode is a
// character that silently never reaches the guest.

/** A character the US-layout guest can be made to type with Shift at most. */
export function isAsciiPrintable(ch: string): boolean {
  const c = ch.codePointAt(0);
  return c != null && c >= 0x20 && c <= 0x7e;
}

/**
 * macOS treats Option as a compose modifier rather than a shortcut modifier, and
 * unlike Windows/Linux AltGr it never sets the AltGraph modifier state — so an
 * Option-composed character is indistinguishable from a real Alt chord without
 * knowing the platform. Prefers userAgentData (unfrozen) over the deprecated
 * navigator.platform, and answers false where there is no navigator (tests, SSR).
 */
export function isMacPlatform(): boolean {
  if (typeof navigator === 'undefined') return false;
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  const platform = nav.userAgentData?.platform ?? nav.platform ?? nav.userAgent ?? '';
  return /mac/i.test(platform);
}

/**
 * True when Alt is held but the event is a composed CHARACTER, so it must go down
 * the printable path (resolved char -> US scancode + synthetic Shift) instead of
 * out as a positional Alt chord.
 *
 * A Finnish Mac puts $ @ \ | { } [ ] ~ behind Option ($ is Option+4); every one of
 * those used to arrive as Alt+<digit> and reach the guest as a menu accelerator.
 *
 * Limited to ASCII results on purpose: Option+<letter> on a Mac resolves to a
 * non-ASCII glyph (å, ∂, ƒ) that the US scancode table cannot express anyway, so
 * Alt+letter menu shortcuts keep the positional path untouched.
 */
export function isComposedChar(
  key: string,
  opts: { altHeld: boolean; altGr: boolean; isMac: boolean },
): boolean {
  if (opts.altGr) return true;
  if (!opts.isMac || !opts.altHeld) return false;
  return Array.from(key).length === 1 && isAsciiPrintable(key);
}

// Shared on-screen-keyboard constants. These live in the keyboard package so
// the layering stays strictly keyboard <- StreamView, never the reverse.

/** Width (px) the stage-menu hamburger claims in the stage's top-left corner:
 *  its 44px button plus an 8px gap. The docked free-text input parks BESIDE the
 *  button rather than under it — it has to stay at the very top of the view to
 *  dodge Android's IME overlay, which is the whole reason it is docked.
 *  Mirrors S.menuBtn/S.menuWrap in StreamView/styles.ts; the layering rule
 *  forbids importing that from here, so the two are kept in step by hand. */
export const STAGE_MENU_BAND = 52;

/** Hold-to-repeat: delay before the first repeat beat (ms). */
export const REPEAT_DELAY_MS = 380;

/** Hold-to-repeat: interval between repeat beats (ms). */
export const REPEAT_INTERVAL_MS = 55;

/** Danger keys: how long a first tap stays armed awaiting the confirming tap (ms). */
export const DANGER_ARM_MS = 2000;

/** Long-press: how long a QWERTY glyph must be held before its secondary 'char'
 *  fires instead of the normal tap (the press is then suppressed on release). */
export const LONGPRESS_MS = 450;

/** Zero-width-space sentinel kept in the sheet free-text proxy input so mobile
 *  IMEs always have something to delete (Backspace on an "empty" field emits no
 *  usable event on Gboard — the sentinel turns it into a real value mutation). */
export const PROXY_SENTINEL = '​';

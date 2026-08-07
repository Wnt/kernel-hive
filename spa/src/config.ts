// Central config. Rename the museum here — it flows through the whole UI.
export const MUSEUM_NAME = 'The Kernel Hive';

// Rotated in the app bar (see .appbar-tag in index.css) — order matches the
// nth-child animation-delay rules there, so add/remove/reorder in both places.
export const MUSEUM_TAGLINES = [
  'Thirty operating systems. One hive.',
  'Explore · Experience · Break · Restore to golden',
  "The internet's weirdest server room.",
  'Vintage systems you can actually play with.',
  'Your granpa\'s favourite OS. Still running.',
] as const;

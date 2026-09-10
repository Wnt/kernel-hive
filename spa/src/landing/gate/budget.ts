// Pure logic behind the conversion gate — the 60-second free look a
// signed-out stranger gets and the wall at zero that turns it into a passkey
// (docs/lab/walkin/LANDING-REDESIGN-CONTRACT.md "the anonymous budget"). No
// DOM, no fetch, no Date.now(): every number this module returns is a
// DISPLAY or a DECISION over a number the caller already has, never a second
// clock racing the server's. That is what keeps it testable under plain Node
// — this repo's Vitest runs with no jsdom (see spa/vitest.config.ts) — and it
// is also the product rule: "Countdown mirrors the server's remainingSeconds,
// never the source of truth" applies just as much to the math around it.

/** calm -> attentive -> urgent, the escalation `Countdown` paints as the
 *  budget drains (tokens: --ink-muted -> --warn -> --danger, AGENTS.md — no
 *  colour outside that set). Boundaries are FRACTIONS of the budget, not
 *  fixed seconds, so a retuned budget keeps the same feel: the last sixth of
 *  the minute reads urgent, the last half reads at least attentive. */
export type UrgencyTier = 'calm' | 'attentive' | 'urgent';

const URGENT_FRACTION = 1 / 6; // last 10s of a 60s budget
const ATTENTIVE_FRACTION = 1 / 2; // last 30s of a 60s budget

export function urgencyTier(remainingSeconds: number, budgetSeconds: number): UrgencyTier {
  if (remainingSeconds <= 0 || budgetSeconds <= 0) return 'urgent';
  const fraction = remainingSeconds / budgetSeconds;
  if (fraction <= URGENT_FRACTION) return 'urgent';
  if (fraction <= ATTENTIVE_FRACTION) return 'attentive';
  return 'calm';
}

/** m:ss, never negative. Same shape as walkin/sessionEnd.ts's `clockText`,
 *  kept as its own three-line copy rather than an import across lanes — the
 *  landing gate's directory stays self-contained, and the algorithm is short
 *  enough that "one obvious place to look" beats "one place to import from". */
export function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes}:${String(secs).padStart(2, '0')}`;
}

/**
 * Show the wall once the visitor's free minute is gone.
 *
 * `expired` is the server's own word (`WalkinState.anon.expired`) and is
 * always right eventually, but a visitor who watches the countdown hit 0:00
 * client-side should not sit looking at a live-looking machine for up to one
 * more poll interval waiting for the server to agree — so a countdown that has
 * already reached zero shows the wall immediately too. The two are expected to
 * agree within a second; this is a display nicety, not a second authority.
 */
export function shouldShowWall(remainingSeconds: number, expired: boolean): boolean {
  return expired || remainingSeconds <= 0;
}

/** How long the broker holds an exhausted visitor's last clone
 *  (LANDING-REDESIGN-CONTRACT.md "hold their last clone reserved for 120s")
 *  so that registering — or signing in — resumes the SAME machine instead of
 *  a fresh one. */
export const HELD_CLONE_WINDOW_SECONDS = 120;

/**
 * Whether registering or signing in RIGHT NOW still lands the visitor back on
 * the machine they were just driving. `secondsSinceExpiry` is how long the
 * wall has been up for THIS visitor — a client-timed approximation, since the
 * gate's props carry no expiry timestamp. It answers "should the copy still
 * promise the same machine", never "does the hold exist" — that fact belongs
 * to the server (`WalkinState.anon.heldClone`) and this function does not
 * invent it.
 */
export function canResumeHeldClone(secondsSinceExpiry: number): boolean {
  return secondsSinceExpiry < HELD_CLONE_WINDOW_SECONDS;
}

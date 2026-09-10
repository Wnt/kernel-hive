import type { JSX } from 'react';
import { formatClock, urgencyTier } from './budget';
import './gate.css';

// The visible half of the anonymous budget (LANDING-REDESIGN-CONTRACT.md
// "Countdown mirrors the server's remainingSeconds"). This component holds no
// clock of its own and starts no timer: every second it paints is whatever
// `remainingSeconds` the caller last got back from /walkin/state. The server
// is the authority on the visitor's free minute; this is a display of it, not
// a second vote.
//
// The one thing it decides for itself is COLOUR — calm -> attentive -> urgent
// as the budget drains (budget.ts `urgencyTier`, tokens only: --ink-muted,
// --warn, --danger). `ConversionGate` also renders this, frozen at zero, as
// the wall's own header clock — one component, one set of rules, for both the
// ticking version and the moment it stops.

export function Countdown({
  remainingSeconds,
  budgetSeconds,
}: {
  remainingSeconds: number;
  budgetSeconds: number;
}): JSX.Element {
  const tier = urgencyTier(remainingSeconds, budgetSeconds);
  return (
    <div
      className={`gate-countdown gate-countdown--${tier}`}
      // A number that changes every second is noise to a screen reader if
      // announced live; the visitor can already see it, and the wall that
      // follows (ConversionGate) is announced on its own terms when it opens.
      aria-hidden="true"
    >
      <span className="gate-countdown-clock">{formatClock(remainingSeconds)}</span>
      <span className="gate-countdown-label">free minute</span>
    </div>
  );
}

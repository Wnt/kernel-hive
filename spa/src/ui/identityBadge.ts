import type { Session } from '../data/session';

/** IdentityBadge.tsx's text, pulled out as a pure function so it is testable
 *  under plain node (spa/vitest.config.ts runs no DOM) — the same split
 *  adminNavVisibility.ts uses for the admin nav's render predicate.
 *
 *  `anon` renders nothing: there is no account to name, and the badge must
 *  not show on the LAN listener or a `/staging/*` preview (session.ts's
 *  `loadSession` deliberately fails open to `anon` there).
 *
 *  A walk-in is the account the operator report is about — a visitor who
 *  just minted a handle like `tidy-noyce` and then never saw it again
 *  anywhere but the landing page's own sign-up copy. So walk-in gets a short
 *  hint alongside the handle (WalkinLanding.tsx's own words: "that is the
 *  whole account" — the handle IS the identity, not a username attached to
 *  one). `viewer`/`admin` get the plain form: those accounts are the
 *  operator's own invited people, who already know what the name means. */
export function identityBadgeText(session: Pick<Session, 'role' | 'name'>): string | null {
  if (session.role === 'anon') return null;
  if (!session.name) return null;
  if (session.role === 'walkin') return `signed in as ${session.name} — that's your handle here`;
  return `signed in as ${session.name}`;
}

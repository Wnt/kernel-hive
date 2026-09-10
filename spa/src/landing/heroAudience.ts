import type { Session } from '../data/session';

// ============================================================================
//  landing/heroAudience — does THIS session get the landing hero at `/`?
//  ---------------------------------------------------------------------------
//  The hero (LandingTop -> HeroStage: a driveable machine, the station
//  switcher, the free-minute countdown, the conversion pitch) is a device
//  aimed at a stranger with no account. It is noise to anyone the server
//  already vouches for — an admin or viewer mid-review did not ask for a
//  countdown, and a walk-in who already claimed their account does not need
//  to be sold on making one. Those three roles get `/` exactly as it
//  rendered before this session existed: the plain grid behind the app's own
//  TopBar (App.tsx's `<>{TopBar}<GridView .../></>` composition, unchanged
//  since before commit b93500ab — `git show d9476c3e:spa/src/App.tsx`).
//
//  `anon` is the ONLY role this says yes to, and it is one role covering two
//  different visitors on purpose, not a hostname check in disguise:
//    - a real stranger on the public gated origin, who has not signed in —
//      the visitor the hero exists to convert;
//    - anyone on the unauthenticated LAN origin (no `/auth/*` served there at
//      all — see data/session.ts's `loadSession` header), which every lab
//      script and the Playwright e2e suite depend on staying open.
//  `anon` already means "nothing to show off, nothing the server vouches
//  for" on EITHER listener — session.ts's own contract is that `anon`
//  "selects a UI SHAPE, never an access decision" — so collapsing both into
//  one role here is the existing design this predicate inherits, not a new
//  risk it takes on.
// ============================================================================
export function showsLandingHero(role: Session['role']): boolean {
  return role === 'anon';
}

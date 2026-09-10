import { useEffect, useState } from 'react';
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
//
//  ROLE IS NOT THE WHOLE ANSWER, THOUGH: `anon` also covers a LAN visitor —
//  and the walk-in PLANE (broker + auth) only runs behind the public
//  listener. On the LAN origin `/walkin/state` never reaches a broker at
//  all: the SPA's own history fallback answers with `index.html` (200,
//  `text/html`), and `/walkin/claim` 404s the instant anything tries to use
//  the hero it renders. That is docs/PUBLIC-GALLERY.md's "unchanged and
//  unauthenticated" LAN promise broken by a machine nobody can actually
//  claim — not a role question, an AVAILABILITY one, so it needs its own
//  answer rather than a second guess folded into `showsLandingHero`.
//
//  `walkinPlaneAvailable` asks it the same way `walkin/api.ts`'s own
//  `call()` already does (a 200 that is not JSON, a non-2xx status or a
//  network throw all mean "no plane here") — independently of that module
//  on purpose: `walkin/api.ts`, `heroPolicy.ts` and `useHeroSession.ts` are
//  the session-lifecycle agent's live tree, and `fetchWalkinState()` there
//  swallows exactly this distinction into its fixture fallback (by design,
//  for a different reason — see fixture.ts), so it cannot answer THIS
//  question without changing what it returns to callers this predicate
//  must not touch. One extra same-origin GET beside their poll is the cost
//  of that isolation.
//
//  FIRST PAINT is deliberately optimistic: `useWalkinPlaneAvailable` starts
//  `true` and only ever flips to `false` once the check confirms there is no
//  plane, never the other way around (the role cannot change mid-document,
//  and neither does an origin's capability). A stranger on the museum's real
//  front door — the audience the whole redesign exists for — gets the hero
//  on the very first frame, with no grid-then-hero flash to protect an
//  audience that does not exist there. The cost lands only on the LAN
//  origin, where a brief hero-then-grid settle is a tooling visitor's
//  problem, not a lost conversion — and it settles on the SAME grid+TopBar
//  `showsLandingHero(role) === false` already renders (App.tsx unmounts
//  LandingPage outright), never a hero with its stage merely hidden.
// ============================================================================
export function showsLandingHero(role: Session['role']): boolean {
  return role === 'anon';
}

/** Does `/walkin/state` answer from a real broker on THIS origin? False for
 *  anything that is not actually JSON (the SPA's own HTML shell on a plane
 *  that isn't there), a non-2xx status, or a network failure. Takes an
 *  injectable fetcher for the same reason `data/session.ts`'s `loadSession`
 *  does: a Node test can hand it a fake response with no DOM/network at all. */
export async function walkinPlaneAvailable(fetcher: typeof fetch = fetch): Promise<boolean> {
  try {
    const response = await fetcher('/walkin/state', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) return false;
    return (response.headers.get('content-type') ?? '').includes('json');
  } catch {
    return false;
  }
}

/** Optimistic until proven otherwise — see the FIRST PAINT note above.
 *  `enabled=false` (every role but `anon`) never fires the check at all;
 *  `showsLandingHero` already refuses those roles regardless of this value. */
export function useWalkinPlaneAvailable(enabled: boolean): boolean {
  const [available, setAvailable] = useState(true);
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    walkinPlaneAvailable().then((ok) => {
      if (alive && !ok) setAvailable(false);
    });
    return () => { alive = false; };
  }, [enabled]);
  return available;
}

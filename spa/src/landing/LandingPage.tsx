import GridView from '../ui/grid/GridView';
import { LandingTop } from './LandingTop';
import './landing.css';

// ============================================================================
//  landing/LandingPage — `/`, the museum's front door for a STRANGER.
//  ---------------------------------------------------------------------------
//  App.tsx mounts this route element only when role 'anon' — nobody the
//  server vouches for, on either listener (App.tsx ->
//  landing/heroAudience.ts's showsLandingHero()). `admin`, `viewer` and
//  `walkin` get `/` exactly as it rendered before this page existed: the
//  plain grid behind the app's own TopBar. A conversion pitch and a
//  free-minute countdown are for someone who does not have a seat yet;
//  everyone who does gets the museum, not the funnel.
//
//  ABOVE THE FOLD is one live machine (LandingTop → HeroStage). BELOW it is the
//  existing GridView, grouped by decade off `museum.era` with its own fold
//  state, which is composed rather than rebuilt: it is the collection's index
//  and it already works.
//
//  ── WHAT THE SERVING PLANE STILL OWES THIS PAGE ───────────────────────────
//  This is the SPA half. A stranger only ever reaches it if the gate lets them,
//  and as of this commit it does not. The server half is another stream's, and
//  these are the three things it must land for the page above to be true for
//  somebody with no account (docs/lab/walkin/LANDING-REDESIGN-CONTRACT.md):
//
//    1. `/` joins `OPEN_PATHS` in scripts/serve/auth/gate.py. Today a
//       session-less request to `/` is a 302 to `/login`, so the front door is
//       shut before this component renders a single element.
//    2. The documents this page then fetches must be readable by that same
//       session — `/gallery-manifest.json` for the collection below the fold
//       (without it the grid stays on "Loading the collection…" forever) and
//       `/boot/index.json`, which is already best-effort.
//    3. `POST /walkin/claim` accepts an anonymous caller and an ABSENT `os`,
//       and `GET /walkin/state` carries the `anon` budget block. Until then the
//       page runs against walkin/fixture.ts, which answers only a 404 and is
//       therefore silently correct the moment the real routes exist.
// ============================================================================

export default function LandingPage({ onOpenPlacard }: { onOpenPlacard?: (osId: string) => void }) {
  return (
    <div className="landing">
      <GridView header={<LandingTop />} onOpenPlacard={onOpenPlacard} />
    </div>
  );
}

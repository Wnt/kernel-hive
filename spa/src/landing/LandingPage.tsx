import GridView from '../ui/grid/GridView';
import { LandingTop } from './LandingTop';
import './landing.css';

// ============================================================================
//  landing/LandingPage — `/`, the museum's front door, for EVERYONE.
//  ---------------------------------------------------------------------------
//  One page for a stranger, a walk-in and an invited visitor. The differences
//  between them are two, and both come from the server rather than from a
//  branch here: an anonymous caller's `/walkin/state` carries an `anon` budget,
//  which is what puts a countdown on the page and a wall at the end of it, and
//  a signed-in caller's does not. Everything else — the running machine, the
//  switcher, the collection — is identical, because it should be.
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

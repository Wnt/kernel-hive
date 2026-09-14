// ============================================================================
//  landing/stationUrl — the address bar tells you which machine you are on.
//  ---------------------------------------------------------------------------
//  The landing page auto-claims, and the broker picks the station when the page
//  asks for "whichever you have" (useHeroSession's `take(null)`). That made `/`
//  a DIFFERENT machine on every load: a visitor who refreshed — or restored the
//  tab, or followed their own back button — got a station they had not chosen
//  and lost the one they were using, with nothing in the URL to explain why.
//
//  So the first claim publishes itself: `/` becomes `/walkin/<station>` the
//  moment a machine is actually on screen, and that address claims THAT station
//  on the next load. The station is now in the one piece of state a browser
//  keeps by itself.
//
//  THE REWRITE IS A REPLACE, NEVER A PUSH. The visitor did not navigate — the
//  page answered a question they never asked — so it must not cost them a back
//  button press to leave. A push here would trap a stranger on the landing page
//  behind as many history entries as stations they tried, which is exactly the
//  shape of a page people report as "the back button is broken".
//
//  IT ONLY PUBLISHES WHAT IS REALLY THERE. No machine on screen, no rewrite:
//  a refused claim, a closed door or a spent budget leaves the URL alone rather
//  than minting an address that promises a machine the visitor was not given.
// ============================================================================

/** The path that names one station's landing page. */
export function stationPath(station: string): string {
  return `/walkin/${station}`;
}

/**
 * The station a `/walkin/<os>` URL pins, or null when it names none we serve.
 *
 * Validated against the door's own list rather than trusted: the param is
 * visitor-controlled text, it reaches `POST /walkin/claim` as an `os`, and a
 * stale bookmark for a station that has since left the pool should quietly fall
 * back to "whichever the broker has" instead of asking for a machine that is
 * not there and rendering the refusal.
 */
export function pinnedStation(param: string | undefined, known: readonly string[]): string | null {
  if (!param) return null;
  return known.includes(param) ? param : null;
}

/**
 * The pathname the address bar SHOULD read, or null to leave it alone.
 *
 * `current` is the pathname as it stands; `station` is what is actually on
 * screen (null while nothing is held). The caller keeps the query string —
 * losing `?walkin=closed` to a URL correction would silently disarm the
 * fixture's own switch-position override mid-session.
 */
export function urlCorrection(current: string, station: string | null): string | null {
  if (station === null) return null;
  // Only the two addresses this page is ever mounted at. A correction fired
  // from anywhere else would be this module rewriting somebody else's route.
  if (current !== '/' && !current.startsWith('/walkin/')) return null;
  const want = stationPath(station);
  return current === want ? null : want;
}

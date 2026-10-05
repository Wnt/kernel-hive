// ============================================================================
//  analytics/telemetryPaths — the telemetry plane's OWN endpoints.
//  ---------------------------------------------------------------------------
//  Every path below is this tab talking to our own box about itself: span
//  uploads, the log lane, vitals, reach counters, coverage, the boot-time error
//  sink, the usage scoreboard and the operator's /clientcmd poll. Paths
//  verified against scripts/serve/telemetry_routes.py (`/analytics`,
//  `/coverage`, `/traces`, `/logs`, `/vitals`) and
//  scripts/serve/osgallery-https-server.py (`/clientlog`, `/usage`,
//  `/clientcmd`) rather than assumed.
//
//  ONE CONSUMER IN THE TAB: `khFetch.ts` opens no client span and sends no
//  `traceparent` for any of them. A span about sending a span is a feedback
//  loop — every upload would manufacture the next one — and a header naming a
//  span nobody records leaves the server's entry span rootless forever.
//
//  ONE MIRROR ON THE SERVER: `scripts/serve/telemetry_paths.py` keeps the same
//  set for the serving plane, and `scripts/test_telemetry_paths_complete.py`
//  pins the two equal and fails when the dispatcher grows an ingest route that
//  is in neither. Adding an endpoint here is the only edit the tab needs; the
//  matcher below is derived from this list mechanically.
// ============================================================================

export const KH_TELEMETRY_PATHS = [
  '/traces',
  '/logs',
  '/vitals',
  '/analytics',
  '/coverage',
  '/clientlog',
  '/usage',
  '/clientcmd',
] as const;

/** Escape a literal path for embedding in a RegExp source string. None of
 *  the paths above contain regex metacharacters today, but a future
 *  endpoint might, and a silently-broken pattern is worse than a verbose one. */
function escapeForRegExp(literal: string): string {
  return literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** PATH form — anchored at the start of a bare pathname (`/clientcmd`, no
 *  origin, no query). The form `khFetch.ts`'s `isExcludedPath` tests a
 *  `url.pathname` against; it can never match a full URL, which starts with a
 *  scheme rather than a slash. */
export const IGNORE_URL_PATTERNS: RegExp[] = KH_TELEMETRY_PATHS.map(
  (path) => new RegExp(`^${escapeForRegExp(path)}\\b`),
);

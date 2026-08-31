// Is this page a walk-in surface? — the question that decides which machinery
// the app starts.
//
// It matters because the gallery boots machinery a walk-in has no business
// starting and no permission to use: the full-fleet /gallery-manifest.json
// (gated by design — a walk-in reads the /walkin/manifest.json allowlist
// projection instead), /boot/index.json, the /clientcmd operator poller and
// /clientlog telemetry. On the live plane every one of those answers 401, which
// produced ten failed POSTs per page load — noise that hides a real error later.
//
// The PATH test alone used to answer it, and that was the bug: a signed-up
// walk-in browsing the ROOT url is allowed `/` by the gate, so the shell
// loaded, `isWalkinPath('/')` said "not a walk-in", the gallery booted, and its
// first fetch — the fleet manifest — was refused. The page sat on "Loading the
// collection…" forever. The role is the real question; the path is still asked
// alongside it for the one visitor who has no role yet, the stranger arriving
// at /walkin to sign up.

/** True for /walkin and everything under it, honouring the bundle's base. */
export function isWalkinPath(pathname: string, base = '/'): boolean {
  const prefix = base.endsWith('/') ? base : `${base}/`;
  const rest = pathname.startsWith(prefix) ? pathname.slice(prefix.length - 1) : pathname;
  return rest === '/walkin' || rest.startsWith('/walkin/');
}

/**
 * Should this page wear the walk-in shape — the projected lineup, and none of
 * the gallery's gated machinery?
 *
 * True for a `walkin` ACCOUNT wherever it is, and for the signed-out stranger
 * standing on a `/walkin` page, who has no account yet and must still reach
 * signup without the gallery firing fetches their session will be refused.
 */
export function walkinShape(role: string, pathname: string, base = '/'): boolean {
  return role === 'walkin' || isWalkinPath(pathname, base);
}

// Is this page a walk-in surface? — the one question main.tsx asks before it
// decides which app to boot.
//
// It matters because the two visitor classes are not the same session. The
// gallery app boots machinery an anonymous walk-in has no business starting
// and no permission to use: the full-fleet /gallery-manifest.json (gated by
// design — a walk-in reads the /walkin/manifest.json allowlist projection
// instead), /boot/index.json, the /clientcmd operator poller and /clientlog
// telemetry. On the live plane every one of those answers 401, which produced
// ten failed POSTs per page load — noise that hides a real error later.
//
// So a walk-in route boots WalkinApp directly, and the gallery's own
// machinery is never started at all. The consequence is deliberate: a walk-in
// page and a gallery page are separate document loads, not two branches of one
// router. Nothing in the walk-in UI links into the gallery, so no visitor ever
// crosses that line inside a single page life.

/** True for /walkin and everything under it, honouring the bundle's base. */
export function isWalkinPath(pathname: string, base = '/'): boolean {
  const prefix = base.endsWith('/') ? base : `${base}/`;
  const rest = pathname.startsWith(prefix) ? pathname.slice(prefix.length - 1) : pathname;
  return rest === '/walkin' || rest.startsWith('/walkin/');
}

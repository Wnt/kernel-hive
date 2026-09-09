/* The Kernel Hive PWA service worker.
 *
 * Its ONLY job is to make the installed gallery behave like a real app: it
 * satisfies the browser's installability check (a registered worker with a
 * fetch handler) and gives a graceful offline shell instead of a dinosaur page.
 *
 * It is deliberately NETWORK-FIRST and never caches app code or data. This lab
 * lives and dies by "a box deploy must be seen on the very next load", so hashed
 * JS/CSS, the rendered JSON manifests, the /clientlog POST and the live
 * WebTransport/WebCodecs media all go straight to the network, untouched — the
 * worker only ever handles top-level navigations, and even those it fetches
 * fresh first. The tiny cache holds a single copy of the last HTML shell, served
 * ONLY when the device is fully offline (the gallery cannot stream offline
 * anyway; this just avoids a blank page).
 *
 * THE CACHE NAME CARRIES THE BUILD ID, and that is not decoration. Until
 * 2026-09-01 it was the hand-written constant `kh-shell-v1`, unchanged across
 * every deploy this gallery has ever had, and `activate` deletes only caches
 * whose key DIFFERS from the current one — so the cached shell entry survived
 * every deploy indefinitely and a single failed navigation on a flaky mobile
 * network could pin a client to an HTML shell from any earlier build, forever.
 * (An HTML shell is not inert: it carries the inline bootstraps — the vendor
 * telemetry config, the session-id minting, the boot error reporter — so an old
 * shell means old boot behaviour even when the hashed bundle it names is still
 * on the box.) The name is now derived from the `?build=` the registration
 * carries (spa/src/main.tsx passes the bundle id vite baked in), so:
 *
 *   * every deploy registers a DIFFERENT script URL, which installs a new
 *     worker, whose activate deletes every cache but its own — including a
 *     `kh-shell-v1` entry a client is holding today. The stale shell is
 *     actively retired on the first online load after this ships, not merely
 *     left uncreated.
 *   * a worker that somehow loads without the parameter names its cache
 *     `kh-shell-unknown` rather than pretending to be a build.
 *
 * What did NOT change: no app code or data is ever cached, navigations are
 * still network-first, and the offline fallback is still one HTML document.
 * This is not an offline app cache and must not become one.
 *
 * To retire the PWA later, replace this file with a self-unregistering stub —
 * a live worker cannot be removed just by deleting the file it was served from.
 */
const BUILD_ID = (() => {
  try {
    return new URL(self.location.href).searchParams.get('build') || 'unknown';
  } catch {
    // A worker that cannot read its own URL still gets a usable, honest name.
    return 'unknown';
  }
})();
const SHELL_CACHE = `kh-shell-${BUILD_ID}`;
const SHELL_KEY = 'kh-app-shell';

self.addEventListener('install', (event) => {
  // Take over as soon as installed rather than waiting for every tab to close,
  // so a returning visitor is controlled on the next load.
  self.skipWaiting();
  event.waitUntil(
    (async () => {
      try {
        const cache = await caches.open(SHELL_CACHE);
        const res = await fetch('/', { cache: 'no-store' });
        if (res.ok) await cache.put(SHELL_KEY, res);
      } catch {
        // Offline at install — the shell fills in on the first online navigation.
      }
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Drop every cache this origin holds except this build's. That is what
      // retires a shell cached by ANY earlier build, `kh-shell-v1` included —
      // and the sweep is deliberately not limited to a name pattern, because
      // this origin has exactly one worker and anything else in it is debris.
      const keys = await caches.keys();
      await Promise.all(keys.filter((key) => key !== SHELL_CACHE).map((key) => caches.delete(key)));
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  // Only top-level navigations are ever handled here. Everything else — hashed
  // assets, JSON documents, POSTs, media transport — is left to the network so
  // this worker can never serve a stale byte.
  if (req.mode !== 'navigate') return;
  event.respondWith(
    (async () => {
      try {
        const fresh = await fetch(req);
        // Only an OK shell is worth keeping — never cache a 401 login redirect
        // (the gallery is session-gated) or a 5xx as the offline fallback.
        if (fresh.ok) {
          try {
            const cache = await caches.open(SHELL_CACHE);
            await cache.put(SHELL_KEY, fresh.clone());
          } catch {
            // A failed clone/put just keeps the previous shell; not fatal.
          }
        }
        return fresh;
      } catch {
        // Offline: hand back the last shell we saw so the app can at least paint.
        const cache = await caches.open(SHELL_CACHE);
        const cached = await cache.match(SHELL_KEY);
        return cached ?? Response.error();
      }
    })(),
  );
});

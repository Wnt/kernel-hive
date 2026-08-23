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
 * To retire the PWA later, replace this file with a self-unregistering stub —
 * a live worker cannot be removed just by deleting the file it was served from.
 */
const SHELL_CACHE = 'kh-shell-v1';
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
      // Drop any cache a previous shell version left behind.
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

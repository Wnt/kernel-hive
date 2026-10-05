// ============================================================================
//  analytics/pageBinding — WHICH PAGE, and WHICH LOAD OF IT.
//  ---------------------------------------------------------------------------
//  An event that correlates to a page only IMPLICITLY — by landing in
//  whatever page some session state happened to be naming at that instant —
//  is fine for a page whose whole life is one route, and useless for this app:
//  a visitor opens `/os/beos`, navigates to `/fleet` while the stream keeps
//  running in a background tile, and every quality switch after that moment is
//  attributed to the wrong page by a mechanism nobody can query around.
//
//  So the binding is EXPLICIT and travels ON the event:
//
//    kh.page.pattern   the route PATTERN (`/os/:osId`, never `/os/beos`)
//    kh.page.loadId    this DOCUMENT's identity, minted once
//
//  "Show me everything that happened on this page load" is then one equality
//  filter on `kh.page.loadId`, not an inference from beacon ordering.
//
//  WHY A PATTERN AND NOT A PATH, EVEN AFTER 2026-09-01. The operator's page-name
//  decision that day changed what the PAGE NAME is (`navigation.ts`'s
//  `kh.page.name` now carries the concrete station); it deliberately did NOT
//  change this attribute. `kh.page.pattern` is the
//  ROLL-UP key — the "how is the station page doing overall" grouping every
//  stream event on this plane is already joined by — and the whole point of
//  doing that decision as BOTH rather than a swap was to keep it. The concrete
//  station rides beside it as `kh.station.id` (analytics/stationAttrs.ts) and,
//  for a navigation, as `kh.page.name`.
//
//  WHY READ `location` AT EMIT TIME rather than caching what the router last
//  said. A cached value is a second opinion about the current route that can
//  disagree with the address bar (a redirect, a `replace`, a route committed
//  between the cache write and the event), and this file exists precisely so
//  that the binding cannot be wrong. `matchRoute` is pure and costs a split
//  and a loop over eleven patterns.
// ============================================================================

import { matchRoute } from './navigation';
import type { Attrs } from './trace';

/** Lowercase hex, 8 bytes — the same shape and the same reasoning as
 *  `trace.ts`'s span ids (crypto when it exists, because Math.random collides
 *  sooner than you would like once ids are joined across two stores). */
function hex8(): string {
  const b = new Uint8Array(8);
  try {
    (globalThis.crypto as Crypto | undefined)?.getRandomValues(b);
  } catch { /* fall through */ }
  let empty = true;
  for (const v of b) if (v !== 0) { empty = false; break; }
  if (empty) for (let i = 0; i < b.length; i += 1) b[i] = Math.floor(Math.random() * 256);
  return Array.from(b, (v) => v.toString(16).padStart(2, '0')).join('');
}

let loadId = '';

/**
 * This document's identity, minted on first use and stable for the life of the
 * JS realm. A full navigation tears the realm down and the next load mints a
 * fresh one, which is exactly the boundary the word "page load" means.
 */
export function pageLoadId(): string {
  if (!loadId) loadId = hex8();
  return loadId;
}

/** The current route pattern, or `'*'` outside a browser / for an unmatched
 *  path (the same catch-all bucket `navigation.ts` uses, so a stray path
 *  cannot leak in as a high-cardinality "pattern"). */
export function pagePattern(): string {
  try {
    if (typeof window === 'undefined' || !window.location) return '*';
    return matchRoute(window.location.pathname).pattern;
  } catch {
    return '*';
  }
}

/**
 * The binding, as span attributes. Merged onto EVERY event this plane emits —
 * see `streamEvents.ts` — so no consumer ever has to infer which page an event
 * belongs to from when it arrived.
 */
export function pageBindingAttrs(): Attrs {
  return {
    'kh.page.pattern': pagePattern(),
    'kh.page.loadId': pageLoadId(),
  };
}

/** Test seam: forget this document's minted id. */
export function __resetPageBinding(): void {
  loadId = '';
}

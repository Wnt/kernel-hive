// ============================================================================
//  analytics/pageBinding — WHICH PAGE, and WHICH LOAD OF IT.
//  ---------------------------------------------------------------------------
//  This is the capability gap we are beating, stated plainly.
//
//  Instana's BROWSER agent has no `viewName` on `reportEvent`. Its MOBILE SDK
//  does; the browser one does not — a custom event there correlates to a page
//  only IMPLICITLY, by landing in whatever page the agent's own session state
//  happened to be naming at that instant. That is fine for a page whose whole
//  life is one route, and useless for this app: a visitor opens `/os/beos`,
//  navigates to `/fleet` while the stream keeps running in a background tile,
//  and every quality switch after that moment is attributed to the wrong page
//  by a mechanism nobody can query around.
//
//  So in OUR plane the binding is EXPLICIT and travels ON the event:
//
//    kh.page.pattern        the route PATTERN (`/os/:osId`, never `/os/beos`)
//    kh.page.loadId         this DOCUMENT's identity, minted once, ours
//    kh.page.instanaLoadId  Instana's own `getPageLoadId`, when it is loaded
//
//  "Show me everything that happened on this page load" is then one equality
//  filter on `kh.page.loadId`, not an inference from beacon ordering.
//
//  WHY A PATTERN AND NOT A PATH. The same cardinality rule `navigation.ts`
//  already states: 63 stations must group under ONE page, or the dimension is
//  unusable for exactly the grouping it exists for. The concrete station rides
//  as `kh.station.id` (analytics/stationAttrs.ts), which is a different
//  question with a different answer.
//
//  WHY READ `location` AT EMIT TIME rather than caching what the router last
//  said. A cached value is a second opinion about the current route that can
//  disagree with the address bar (a redirect, a `replace`, a route committed
//  between the cache write and the event), and this file exists precisely so
//  that the binding cannot be wrong. `matchRoute` is pure and costs a split
//  and a loop over eleven patterns.
//
//  WHY OUR OWN LOAD ID AT ALL, given Instana mints one. Because the operator's
//  standing rule for this whole plane is that Instana is a benchmark we intend
//  to drop, and a page-load identity that only exists while a third-party
//  bundle is loaded is not an identity we own. `kh.page.instanaLoadId` is
//  captured ALONGSIDE ours, for exactly as long as the two systems have to be
//  reconciled, and its absence changes nothing about our own binding.
// ============================================================================

import { matchRoute } from './navigation';
import type { Attrs } from './trace';

/** The subset of `ineum` this module reads. Declared locally rather than
 *  imported from `instana.ts`, the same isolation `navigation.ts`,
 *  `khFetch.ts` and `streamClient/inputTrace.ts` each keep: this module must
 *  keep working, unchanged, on the day the vendor is deleted. */
declare global {
  interface Window {
    ineum?: (...args: unknown[]) => void;
  }
}

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
 * fresh one, which is exactly the boundary the word "page load" means — the
 * same reasoning `instana.ts` gives for not needing a `terminateSession` call.
 */
export function pageLoadId(): string {
  if (!loadId) loadId = hex8();
  return loadId;
}

/**
 * Instana's own page-load id, or null. Read at EMIT time, never cached: the
 * vendor bundle loads asynchronously, so an early event legitimately has no
 * answer and a later one on the same document does.
 *
 * `ineum('getPageLoadId')` is the documented getter and is the ONE `ineum`
 * call in this repo whose RETURN value matters, which is why it does not go
 * through the void-returning guard every other call site uses.
 */
export function instanaPageLoadId(): string | null {
  try {
    if (typeof window === 'undefined') return null;
    const fn = window.ineum;
    if (typeof fn !== 'function') return null;
    const id: unknown = (fn as (...a: unknown[]) => unknown)('getPageLoadId');
    return typeof id === 'string' && id ? id.slice(0, 120) : null;
  } catch {
    return null;
  }
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
  const out: Attrs = {
    'kh.page.pattern': pagePattern(),
    'kh.page.loadId': pageLoadId(),
  };
  const instana = instanaPageLoadId();
  if (instana) out['kh.page.instanaLoadId'] = instana;
  return out;
}

/** Test seam: forget this document's minted id. */
export function __resetPageBinding(): void {
  loadId = '';
}
